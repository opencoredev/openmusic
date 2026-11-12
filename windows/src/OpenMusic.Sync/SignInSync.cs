using System.ComponentModel;
using System.Security.Cryptography;
using OpenMusic.Core;
using OpenMusic.Sync.Convex;
using OpenMusic.Sync.Keys;

namespace OpenMusic.Sync;

/// <summary>
/// One provider's sign-in, as the app stores it (YouTube Music: cookie and channel; Spotify: refresh token). OpenMusic.Sync
/// seals what <see cref="ExportSignInAsync"/> returns with the vault key and never looks inside. Called on the sync actor.
/// </summary>
public interface ISignInTransfer
{
    ProviderId Provider { get; }
    /// <summary>The current sign-in, or null when signed out.</summary>
    Task<byte[]?> ExportSignInAsync();
    /// <summary>Replaces this device's sign-in with one from another device.</summary>
    Task ImportSignInAsync(byte[] data);
    /// <summary>Signs this device out. Throws when the saved sign-in couldn't be deleted; the sign-out then stays pending.</summary>
    Task SignOutAsync();
    /// <summary>Set by <see cref="SignInSync.Register"/>. Call it whenever the local sign-in changes.</summary>
    Action? SignInDidChange { get; set; }
}

public abstract record SignInStatus
{
    public sealed record Unavailable : SignInStatus;
    /// <summary>This device lacks the vault key: a device that has it must allow this one.</summary>
    public sealed record NeedsKey : SignInStatus;
    public sealed record Waiting : SignInStatus;
    public sealed record NotSignedIn : SignInStatus;
    /// <summary>Local and vault agree as of this server time.</summary>
    public sealed record Synced(double At) : SignInStatus;
    public sealed record SignedOutHere : SignInStatus;
    public sealed record SignedOutEverywhere : SignInStatus;
    public sealed record Failed(string Message) : SignInStatus;
}

/// <summary>One import, for diagnostics: when the entry was written and how long it took to arrive and import. Never the sign-in.</summary>
public sealed record SignInImport(ProviderId Provider, double UpdatedAt, double LatencyMs, bool SignedOut, int Bytes = 0);

/// <summary>
/// Keeps provider sign-ins the same on every device of the account, end-to-end encrypted (port of <c>SignInSync.swift</c>):
/// compare-and-swap writes on the revision this device last saw, imports of newer revisions opened for exactly their
/// revision, tombstones honored with or without the key, unreadable entries treated as a sign-out, legacy (v1) entries
/// migrated once, sign-outs retried until the local deletion succeeds, and state kept per deployment, library and device.
/// <para>
/// Identity: every piece of work belongs to the session (registration scope) current when it was asked for, captured
/// before its first await. A provider sign-out or a reconcile asked for under one registration never acts under the next:
/// each local deletion, import, vault write and status change checks the session at that moment, on the actor, with
/// nothing awaited between the check and the effect, and stale work stops (a sign-out with
/// <see cref="SyncErrorKind.AuthChanged"/>).
/// </para>
/// </summary>
public sealed class SignInSync : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    public event Action<SignInImport>? Imported;

    private readonly SyncCredentialStore _store;
    private readonly IVaultEndpoint _endpoint;
    private readonly SyncActor _actor;
    private readonly Dictionary<ProviderId, ISignInTransfer> _transfers = new();
    private Dictionary<ProviderId, ProviderState> _state;
    private Task? _tail;
    private string? _scope;
    private int _session;
    private readonly Dictionary<ProviderId, string> _importing = new();
    private readonly Dictionary<ProviderId, (int Revision, double RetryAt)> _failedImports = new();
    private readonly Dictionary<ProviderId, (double RetryAt, string Message)> _failedSignOuts = new();
    private readonly Dictionary<ProviderId, CancellationTokenSource> _signOutRetries = new();
    private Dictionary<ProviderId, SignInStatus> _status = new();

    internal TimeSpan ImportRetryDelay { get; set; } = TimeSpan.FromSeconds(30);
    internal TimeSpan SignOutRetryDelay { get; set; } = TimeSpan.FromSeconds(30);

    public IReadOnlyDictionary<ProviderId, SignInStatus> Status => _status;
    public SignInImport? LastImport { get; private set; }

    internal sealed record ProviderState
    {
        /// <summary>Vault revision this device last wrote or applied.</summary>
        public int Revision { get; set; }
        public double AppliedAt { get; set; }
        /// <summary>SHA-256 (hex) of the sign-in last synced.</summary>
        public string? Digest { get; set; }
        public bool SignedOutHere { get; set; }
        public int? UnreadableRevision { get; set; }
        public bool HoldsForeignSignIn { get; set; }
    }

    private sealed record Saved(string? Scope, Dictionary<ProviderId, ProviderState> Providers);
    internal const string StateName = "signins.v2";

    internal SignInSync(SyncCredentialStore store, SyncService service)
    {
        _store = store;
        _endpoint = service;
        _actor = service.Actor;
        var saved = store.StateAs<Saved>(StateName);
        _scope = saved?.Scope;
        _state = saved?.Providers ?? new();
    }

    /// <summary>A standalone instance for tests (any endpoint).</summary>
    internal SignInSync(SyncCredentialStore store, IVaultEndpoint endpoint, SyncActor actor)
    {
        _store = store;
        _endpoint = endpoint;
        _actor = actor;
        var saved = store.StateAs<Saved>(StateName);
        _scope = saved?.Scope;
        _state = saved?.Providers ?? new();
    }

    private void SetStatus(ProviderId provider, SignInStatus status)
    {
        _actor.AssertCurrent();
        if (_status.TryGetValue(provider, out var old) && old == status) return;
        _status = new Dictionary<ProviderId, SignInStatus>(_status) { [provider] = status };
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Status)));
    }

    /// <summary>Starts over when the registration changed: forgets what was applied; work already queued drops its results.</summary>
    internal void BeginSession(string? scope)
    {
        _actor.AssertCurrent();
        if (scope == _scope) return;
        _scope = scope;
        _session++;
        _state = new();
        _importing.Clear();
        _failedImports.Clear();
        _failedSignOuts.Clear();
        foreach (var retry in _signOutRetries.Values) retry.Cancel();
        _signOutRetries.Clear();
        LastImport = null;
        _status = _status.ToDictionary(kv => kv.Key, _ => (SignInStatus)new SignInStatus.Waiting());
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Status)));
        Persist();
        if (scope is not null) ReconcileAllNow();
    }

    /// <summary>Starts syncing one provider. Call once per provider at launch, after the provider restored its session.</summary>
    public async Task RegisterAsync(ISignInTransfer transfer)
    {
        await _actor.Switch();
        Register(transfer);
    }

    internal void Register(ISignInTransfer transfer)
    {
        _actor.AssertCurrent();
        var provider = transfer.Provider;
        _transfers[provider] = transfer;
        transfer.SignInDidChange = () => _actor.Post(() => Reconcile(provider));
        Reconcile(provider);
    }

    /// <summary>Signs out of <paramref name="provider"/> here, and with <paramref name="everywhere"/> on every device of the account.</summary>
    /// <remarks>
    /// It is for the account this device syncs with when it is called. If the device moved to another registration before
    /// it ran or while it ran, it stops there (<see cref="SyncErrorKind.AuthChanged"/>): it never deletes the sign-in the
    /// next account brought, and never signs the next account out.
    /// </remarks>
    public async Task SignOutAsync(ProviderId provider, bool everywhere)
    {
        await _actor.Switch();
        var session = _session;   // the ticket, captured before anything is awaited
        await Serial(async () =>
        {
            CheckSession(session);
            if (!_transfers.TryGetValue(provider, out var transfer)) return;
            await transfer.SignOutAsync();
            CheckSession(session);
            var s = Copy(provider);
            s.Digest = null;
            s.HoldsForeignSignIn = false;
            if (everywhere)
            {
                var stored = _endpoint.VaultEntries?.FirstOrDefault(e => e.Provider == provider)?.Revision ?? 0;
                var baseRevision = Math.Max(s.Revision, stored);
                VaultWrite write;
                try { write = await _endpoint.SignOutVaultAsync(provider, baseRevision); }
                catch (SyncConflictException conflict)
                {
                    // Another device wrote first: sign out on top of what is there now. The user asked for it.
                    CheckSession(session);
                    baseRevision = conflict.Revision ?? baseRevision + 1;
                    write = await _endpoint.SignOutVaultAsync(provider, baseRevision);
                }
                CheckSession(session);
                s.Revision = Math.Max(s.Revision, write.Revision);
                s.AppliedAt = write.UpdatedAt;
                s.SignedOutHere = false;
                SetStatus(provider, new SignInStatus.SignedOutEverywhere());
            }
            else
            {
                s.SignedOutHere = true;
                SetStatus(provider, new SignInStatus.SignedOutHere());
            }
            Save(provider, s);
        });
    }

    private void CheckSession(int session)
    {
        _actor.AssertCurrent();
        if (session != _session) throw SyncException.AuthChanged;
    }

    /// <summary>Re-runs the sync for every registered provider (the service calls it when vault entries or the key change).</summary>
    public void ReconcileAll() => _actor.Perform(ReconcileAllNow);

    internal void ReconcileAllNow()
    {
        _actor.AssertCurrent();
        foreach (var provider in _transfers.Keys.ToList()) Reconcile(provider);
    }

    /// <summary>Retries pending sign-outs now (the app came back to the foreground).</summary>
    public void RetryNow() => _actor.Perform(RetryNowOnActor);

    internal void RetryNowOnActor()
    {
        _actor.AssertCurrent();
        if (_failedSignOuts.Count == 0) return;
        _failedSignOuts.Clear();
        ReconcileAllNow();
    }

    /// <summary>
    /// Queues a sync of <paramref name="provider"/> for the session current now. When it comes up, it runs only if that is
    /// still the session (a new session queues its own).
    /// </summary>
    internal void Reconcile(ProviderId provider)
    {
        _actor.AssertCurrent();
        var session = _session;
        var previous = _tail;
        _tail = Chain(previous, () => session == _session ? Sync(provider, session) : Task.CompletedTask);
    }

    private static async Task Chain(Task? previous, Func<Task> work)
    {
        AccountOperations.Current.Value = null;
        await Task.Yield();
        if (previous is not null) { try { await previous; } catch (Exception) { } }
        try { await work(); } catch (Exception e) { Console.Error.WriteLine($"[sync] sign-in sync failed: {e.Message}"); }
    }

    internal ProviderState SavedState(ProviderId provider) => _state.TryGetValue(provider, out var s) ? s with { } : new ProviderState();

    /// <summary>Waits for queued work (tests).</summary>
    internal async Task Settle()
    {
        while (_tail is { } current)
        {
            await current;
            if (ReferenceEquals(current, _tail)) return;
        }
    }

    private async Task Serial(Func<Task> work)
    {
        _actor.AssertCurrent();
        var previous = _tail;
        var task = Run();
        _tail = Swallow(task);
        await task;

        async Task Run()
        {
            await Task.Yield();
            if (previous is not null) { try { await previous; } catch (Exception) { } }
            await work();
        }
    }

    private static async Task Swallow(Task task) { try { await task; } catch (Exception) { } }

    internal const string UnreadableMessage = "A sign-in in the library couldn't be opened, so this device signed out of it. Sign in again here to replace it.";
    internal const string ForeignMessage = "This sign-in came from the library this device left, so it isn't shared here. Sign in again to share one.";

    private ProviderState Copy(ProviderId provider) => _state.TryGetValue(provider, out var s) ? s with { } : new ProviderState();

    private async Task Sync(ProviderId provider, int session)
    {
        _actor.AssertCurrent();
        if (!_transfers.TryGetValue(provider, out var transfer)) { SetStatus(provider, new SignInStatus.Unavailable()); return; }
        if (_endpoint.SelfId is not { } me) { SetStatus(provider, new SignInStatus.Waiting()); return; }
        if (_endpoint.VaultEntries is not { } entries) { SetStatus(provider, new SignInStatus.Waiting()); return; }
        var s = Copy(provider);
        var entry = entries.FirstOrDefault(e => e.Provider == provider);

        // The account lost its key: note the revision and forget what was synced, so this sign-in is uploaded again.
        if (entry is { Cleared: true } && entry.Revision > s.Revision)
        {
            s.Revision = entry.Revision;
            s.AppliedAt = entry.UpdatedAt;
            s.Digest = null;
            s.UnreadableRevision = null;
            Save(provider, s);
        }

        // Sign out everywhere: honored with or without the vault key.
        if (entry is { Sealed: null, Cleared: false } && entry.Revision > s.Revision)
        {
            var latency = _endpoint.Clock.Now() - entry.UpdatedAt;
            if (!s.SignedOutHere && !await DeleteSignIn(provider, transfer, session)) return;
            if (session != _session) return;
            s.Revision = entry.Revision;
            s.AppliedAt = entry.UpdatedAt;
            s.Digest = null;
            s.SignedOutHere = false;
            s.UnreadableRevision = null;
            s.HoldsForeignSignIn = false;
            Save(provider, s);
            SetStatus(provider, _endpoint.LibraryKey is null ? new SignInStatus.NeedsKey() : new SignInStatus.SignedOutEverywhere());
            if (entry.UpdatedBy != me) Record(new SignInImport(provider, entry.UpdatedAt, latency, true));
            return;
        }
        if (_endpoint.LibraryKey is not { } key) { SetStatus(provider, new SignInStatus.NeedsKey()); return; }

        // Remote → local.
        if (entry is { Sealed: { } sealedText } && (entry.Revision > s.Revision || IsLegacy(entry, s)))
        {
            if (s.SignedOutHere)
            {
                s.Revision = entry.Revision;
                s.AppliedAt = entry.UpdatedAt;
                Save(provider, s);
                SetStatus(provider, new SignInStatus.SignedOutHere());
                return;
            }
            if (entry.KeyId != key.Id)
            {
                // While the key is being replaced the entry may already be sealed with the new one.
                SetStatus(provider, _endpoint.VaultWritesPaused ? new SignInStatus.Waiting() : new SignInStatus.Failed("This sign-in was sealed with another library key."));
                return;
            }
            byte[]? opened = null;
            try
            {
                opened = entry.Revision == 0 ? SignInSealing.OpenLegacy(sealedText, provider, key) : SignInSealing.Open(sealedText, provider, entry.Revision, key);
            }
            catch (SyncException) { }
            if (opened is null)
            {
                await SignOutForUnreadable(provider, entry, transfer, session, s);
                return;
            }
            var digest = Digest(opened);
            if (entry.UpdatedBy == me || digest == s.Digest)
            {
                s.Revision = entry.Revision;
                s.AppliedAt = entry.UpdatedAt;
                s.Digest = digest;
                s.UnreadableRevision = null;
                Save(provider, s);
                SetStatus(provider, new SignInStatus.Synced(entry.UpdatedAt));
            }
            else
            {
                if (_failedImports.TryGetValue(provider, out var failure) && failure.Revision == entry.Revision && MonoClock.NowMs < failure.RetryAt) return;
                if (session != _session) return;
                _importing[provider] = digest;
                try
                {
                    await transfer.ImportSignInAsync(opened);
                }
                catch (Exception e)
                {
                    if (session != _session) return;
                    _importing.Remove(provider);
                    _failedImports[provider] = (entry.Revision, MonoClock.NowMs + ImportRetryDelay.TotalMilliseconds);
                    SetStatus(provider, new SignInStatus.Failed(SyncException.From(e).Message));
                    return;
                }
                if (session != _session)
                {
                    // The device joined another account while this import ran: what it installed isn't shared there.
                    var current = Copy(provider);
                    current.HoldsForeignSignIn = true;
                    Save(provider, current);
                    return;
                }
                _importing.Remove(provider);
                _failedImports.Remove(provider);
                s.Revision = entry.Revision;
                s.AppliedAt = entry.UpdatedAt;
                s.Digest = digest;
                s.UnreadableRevision = null;
                s.HoldsForeignSignIn = false;
                Save(provider, s);
                SetStatus(provider, new SignInStatus.Synced(entry.UpdatedAt));
                Record(new SignInImport(provider, entry.UpdatedAt, _endpoint.Clock.Now() - entry.UpdatedAt, false, opened.Length));
                if (entry.Revision != 0) return;
            }
            if (entry.Revision == 0)
            {
                if (_endpoint.VaultWritesPaused) { SetStatus(provider, new SignInStatus.Waiting()); return; }
                if (!await MigrateLegacy(provider, opened, key, session, s)) return;
            }
        }

        // Local → remote.
        var data = await transfer.ExportSignInAsync();
        if (data is null)
        {
            if (session != _session) return;
            if (s.HoldsForeignSignIn)
            {
                s.HoldsForeignSignIn = false;
                Save(provider, s);
            }
            if (s.SignedOutHere) SetStatus(provider, new SignInStatus.SignedOutHere());
            else if (s.UnreadableRevision is { } unreadable && unreadable == entry?.Revision) SetStatus(provider, new SignInStatus.Failed(UnreadableMessage));
            else if (entry is { Sealed: null }) SetStatus(provider, new SignInStatus.SignedOutEverywhere());
            else SetStatus(provider, new SignInStatus.NotSignedIn());
            return;
        }
        if (session != _session) return;
        if (s.HoldsForeignSignIn) { SetStatus(provider, new SignInStatus.Failed(ForeignMessage)); return; }
        var localDigest = Digest(data);
        if (localDigest == s.Digest || (_importing.TryGetValue(provider, out var importing) && localDigest == importing))
        {
            SetStatus(provider, new SignInStatus.Synced(s.AppliedAt));
            return;
        }
        // Never seal for a key this device isn't sure is the account's.
        if (_endpoint.VaultWritesPaused) { SetStatus(provider, new SignInStatus.Waiting()); return; }
        var baseRevision = Math.Max(s.Revision, entry?.Revision ?? 0);
        try
        {
            var sealedNew = SignInSealing.Seal(data, provider, baseRevision + 1, key);
            if (session != _session) return;
            var write = await _endpoint.PutVaultAsync(provider, sealedNew, key.Id, baseRevision);
            if (session != _session) return;
            s.Revision = Math.Max(s.Revision, write.Revision);
            s.AppliedAt = write.UpdatedAt;
            s.Digest = localDigest;
            s.SignedOutHere = false;
            s.UnreadableRevision = null;
            Save(provider, s);
            SetStatus(provider, new SignInStatus.Synced(write.UpdatedAt));
        }
        catch (SyncConflictException)
        {
            if (session != _session) return;
            SetStatus(provider, new SignInStatus.Waiting());   // another device wrote first; its entry is on the way
        }
        catch (Exception e)
        {
            if (session != _session) return;
            SetStatus(provider, new SignInStatus.Failed(SyncException.From(e).Message));
        }
    }

    private static bool IsLegacy(VaultEntry entry, ProviderState s) =>
        entry.Revision == 0 && s.Revision == 0 && !s.SignedOutHere && s.UnreadableRevision is null;

    private async Task SignOutForUnreadable(ProviderId provider, VaultEntry entry, ISignInTransfer transfer, int session, ProviderState s)
    {
        if (session != _session) return;
        var signedIn = await transfer.ExportSignInAsync() is not null;
        if (session != _session) return;
        if (signedIn && !await DeleteSignIn(provider, transfer, session)) return;
        if (session != _session) return;
        s.Revision = entry.Revision;
        s.AppliedAt = entry.UpdatedAt;
        s.Digest = null;
        s.UnreadableRevision = entry.Revision;
        s.HoldsForeignSignIn = false;
        Save(provider, s);
        SetStatus(provider, new SignInStatus.Failed(UnreadableMessage));
    }

    private async Task<bool> DeleteSignIn(ProviderId provider, ISignInTransfer transfer, int session)
    {
        // The deletion is the effect: only for the session it was decided in.
        if (session != _session) return false;
        if (_failedSignOuts.TryGetValue(provider, out var failure) && MonoClock.NowMs < failure.RetryAt)
        {
            SetStatus(provider, new SignInStatus.Failed(failure.Message));
            return false;
        }
        try
        {
            await transfer.SignOutAsync();
        }
        catch (Exception e)
        {
            if (session != _session) return false;
            var message = DeletionFailedMessage(e);
            _failedSignOuts[provider] = (MonoClock.NowMs + SignOutRetryDelay.TotalMilliseconds, message);
            SetStatus(provider, new SignInStatus.Failed(message));
            ScheduleSignOutRetry(provider);
            return false;
        }
        if (session != _session) return false;
        _failedSignOuts.Remove(provider);
        if (_signOutRetries.Remove(provider, out var retry)) retry.Cancel();
        return true;
    }

    private void ScheduleSignOutRetry(ProviderId provider)
    {
        if (_signOutRetries.TryGetValue(provider, out var old)) old.Cancel();
        var cts = new CancellationTokenSource();
        _signOutRetries[provider] = cts;
        _ = Task.Delay(SignOutRetryDelay, cts.Token).ContinueWith(t =>
        {
            if (t.IsCanceled) return;
            _actor.Post(() =>
            {
                // Cancelled by BeginSession: the retry belonged to the previous session.
                if (cts.IsCancellationRequested) return;
                _signOutRetries.Remove(provider);
                Reconcile(provider);
            });
        }, TaskScheduler.Default);
    }

    internal static string DeletionFailedMessage(Exception error) =>
        $"This device was signed out from the library, but its saved sign-in couldn't be deleted ({error.Message}). {ProductInfo.Name} keeps trying and shares nothing from this device until it's gone.";

    private async Task<bool> MigrateLegacy(ProviderId provider, byte[] data, LibraryKey key, int session, ProviderState s)
    {
        try
        {
            var sealedNew = SignInSealing.Seal(data, provider, 1, key);
            if (session != _session) return false;
            var write = await _endpoint.PutVaultAsync(provider, sealedNew, key.Id, 0);
            if (session != _session) return false;
            s.Revision = Math.Max(s.Revision, write.Revision);
            s.AppliedAt = write.UpdatedAt;
            s.Digest = Digest(data);
            Save(provider, s);
            SetStatus(provider, new SignInStatus.Synced(write.UpdatedAt));
            return true;
        }
        catch (SyncConflictException)
        {
            if (session != _session) return false;
            SetStatus(provider, new SignInStatus.Waiting());
            return false;
        }
        catch (Exception e)
        {
            if (session != _session) return false;
            SetStatus(provider, new SignInStatus.Failed(SyncException.From(e).Message));
            return false;
        }
    }

    private void Record(SignInImport import)
    {
        _actor.AssertCurrent();
        LastImport = import;
        Imported?.Invoke(import);
    }

    private void Save(ProviderId provider, ProviderState s)
    {
        _actor.AssertCurrent();
        _state[provider] = s;
        Persist();
    }

    private void Persist() => _store.SetState(StateName, SyncCredentialStore.Encode(new Saved(_scope, _state)));

    internal static string Digest(byte[] data) => Convert.ToHexStringLower(SHA256.HashData(data));
}
