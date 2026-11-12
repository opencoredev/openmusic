using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Medley.Core;
using Medley.Providers.YouTube.Auth;
using Medley.Providers.YouTube.Json;

namespace Medley.Providers.YouTube.Sync;

/// <summary>
/// The blob that travels between devices, sealed by Medley Sync (Swift: <c>YouTubeMusicSignInPayload</c>, version 1):
/// <c>{"account":{…},"credentials":{"authUser":…,"cookies":{…},"datasyncId":…},"version":1}</c>, keys sorted and
/// escaped the way Swift's <c>JSONEncoder(.sortedKeys)</c> writes them, so the bytes match a Mac's for the same sign-in.
/// </summary>
public sealed record YouTubeMusicSignInPayload(YouTubeMusicCredentials Credentials, AccountInfo? Account, int Version = 1)
{
    public const string TestCookie = "MEDLEY_TEST_SIGNIN";

    /// <summary>Stable bytes for the same sign-in (sorted keys), so an unchanged sign-in is never uploaded twice.</summary>
    public byte[] Encode()
    {
        var o = new JsonObject { ["credentials"] = Credentials.ToJsonNode(), ["version"] = Version };
        if (Account != null) o["account"] = AccountJson.ToNode(Account);
        return SwiftJson.SerializeToUtf8(o);
    }

    /// <summary>Reads a payload from any device. Throws <see cref="FormatException"/> on anything else or another version.</summary>
    public static YouTubeMusicSignInPayload Decode(ReadOnlySpan<byte> data)
    {
        JsonObject root;
        try { root = JsonNav.Parse(data) as JsonObject ?? throw new FormatException("expected a JSON object"); }
        catch (JsonException e) { throw new FormatException(e.Message, e); }
        if (root.I("version") is not { } version) throw new FormatException("version missing");
        if (version != 1) throw new FormatException("unknown version");
        if (root.Get("credentials") is not JsonObject creds) throw new FormatException("credentials missing");
        AccountInfo? account = null;
        if (root.Get("account") is { } a)
        {
            account = AccountJson.FromNode(a as JsonObject) ?? throw new FormatException("account unreadable");
        }
        return new YouTubeMusicSignInPayload(YouTubeMusicCredentials.FromJsonNode(creds), account, version);
    }

    /// <summary>Never prints cookies.</summary>
    public override string ToString() => $"YouTubeMusicSignInPayload(account: {Account?.Name ?? "-"}, cookies: <redacted>)";
}

/// <summary>The exact payload bytes last exported or imported, and when.</summary>
public sealed record YouTubeMusicTransferSnapshot(byte[] Payload, DateTimeOffset TakenAt);

/// <summary>Where the snapshot lives (Swift: Keychain item <c>ytm.transfer</c>). Windows: DPAPI-protected file.</summary>
public interface IYouTubeMusicTransferStore
{
    YouTubeMusicTransferSnapshot? Load();
    void Save(YouTubeMusicTransferSnapshot? snapshot);
}

public sealed class MemoryTransferStore : IYouTubeMusicTransferStore
{
    readonly Lock _lock = new();
    YouTubeMusicTransferSnapshot? _snapshot;
    public YouTubeMusicTransferSnapshot? Load() { lock (_lock) return _snapshot; }
    public void Save(YouTubeMusicTransferSnapshot? snapshot) { lock (_lock) _snapshot = snapshot; }
}

public enum TransferErrorKind
{
    /// <summary>Not a payload this version understands.</summary>
    Unreadable,
    /// <summary>Google no longer accepts these cookies.</summary>
    Rejected,
    /// <summary>YouTube couldn't be asked (offline, or it didn't answer). Retryable.</summary>
    Unverified,
}

public sealed class TransferException(TransferErrorKind kind) : Exception(Describe(kind))
{
    public TransferErrorKind Kind { get; } = kind;

    static string Describe(TransferErrorKind kind) => kind switch
    {
        TransferErrorKind.Unreadable => $"The YouTube Music sign-in from your other device couldn't be read. Update {ProductInfo.Name} on both devices.",
        TransferErrorKind.Rejected => "YouTube Music no longer accepts the sign-in from your other device. Sign in again there or here.",
        _ => $"Couldn't check the YouTube Music sign-in from your other device with YouTube. {ProductInfo.Name} tries again shortly.",
    };
}

/// <summary>
/// What the provider tells the sign-in transfer about its account, from inside its account operations.
/// </summary>
internal interface ISignInTransferSink
{
    /// <summary>
    /// Inside the commit that changed the account, under the provider's commit lock, so the snapshot changes together
    /// with the status and the saved credentials. <paramref name="payload"/>: the exact bytes an import brought.
    /// </summary>
    void Committed(YouTubeMusicCredentials? credentials, AccountInfo? account, byte[]? payload);

    /// <summary>After the operation, outside every lock: the sync uploads the change.</summary>
    void Changed();
}

/// <summary>
/// Moves the YouTube Music sign-in between devices for Medley Sync (Swift: <c>YouTubeMusicSignInTransfer</c>).
/// What travels: the session cookies, the Google account index and the selected channel, plus the account name and
/// photo. Google rotates a few cookies every few minutes, so the export is a snapshot taken at the last sign-in,
/// channel switch or import, retaken from the live cookies at most once a day.
/// </summary>
/// <remarks>
/// Import and export are account operations of the provider: they run one at a time with its sign-ins, sign-outs and
/// restores, and the snapshot is written in the same commit as the account it describes.
/// </remarks>
public sealed class YouTubeMusicSignInTransfer : ISignInTransferSink
{
    public static readonly TimeSpan SnapshotMaxAge = TimeSpan.FromHours(24);

    /// <summary>Checks transferred cookies before they replace this device's session. Returns their account.</summary>
    public delegate Task<AccountInfo> Verifier(YouTubeMusicCredentials credentials, AccountInfo? claimedAccount, CancellationToken ct);

    readonly YouTubeMusicProvider _youtube;
    readonly IYouTubeMusicTransferStore _store;
    readonly Verifier _verify;
    readonly bool _persist;
    readonly TimeProvider _time;

    /// <summary>Called on every sign-in, channel switch, import and sign-out here, so the sync uploads the change.</summary>
    public Action? SignInDidChange { get; set; }

    public ProviderId Provider => ProviderId.YouTubeMusic;

    /// <param name="verify">Default: the account menu on a throwaway client.</param>
    /// <param name="persist">False keeps imported sign-ins out of the credential store (tests, the probe).</param>
    public YouTubeMusicSignInTransfer(YouTubeMusicProvider provider, IYouTubeMusicTransferStore store, Verifier? verify = null, bool persist = true,
        TimeProvider? time = null)
    {
        _youtube = provider;
        _store = store;
        _persist = persist;
        _time = time ?? TimeProvider.System;
        _verify = verify ?? CheckWithYouTube;
        provider.AttachTransfer(this);
    }

    public static async Task<AccountInfo> CheckWithYouTube(YouTubeMusicCredentials credentials, AccountInfo? claimed, CancellationToken ct)
    {
        using var probe = new InnerTube.InnerTubeClient();
        probe.SetCredentials(credentials);
        return await probe.AccountAsync(ct).ConfigureAwait(false);
    }

    /// <summary>The snapshot when it still describes the live sign-in and is under a day old; otherwise a new one.</summary>
    public Task<byte[]?> ExportSignInAsync() => _youtube.ReadAccountAsync<byte[]?>((status, live) =>
    {
        if (!status.IsSignedIn || live is null) return null;
        if (_store.Load() is { } snapshot && _time.GetUtcNow() - snapshot.TakenAt < SnapshotMaxAge)
        {
            try
            {
                if (SameSession(YouTubeMusicSignInPayload.Decode(snapshot.Payload).Credentials, live)) return snapshot.Payload;
            }
            catch (FormatException)
            {
            }
        }
        return TakeSnapshot(live, status.Account);
    });

    /// <summary>Cookies Google doesn't rotate: the snapshot is of the live sign-in when these and the account selectors match.</summary>
    static readonly string[] SessionCookies = ["SID", "__Secure-1PSID", "__Secure-3PSID", "SAPISID", "__Secure-3PAPISID"];

    /// <summary>
    /// Whether <paramref name="snapshot"/> is the live sign-in, rotated cookies aside: same account selectors and the same
    /// session cookies. A snapshot that wasn't rewritten (its store refused) never passes for another account.
    /// </summary>
    internal static bool SameSession(YouTubeMusicCredentials snapshot, YouTubeMusicCredentials live) =>
        snapshot.AuthUser == live.AuthUser && snapshot.DatasyncId == live.DatasyncId &&
        SessionCookies.All(name => snapshot.Cookies.GetValueOrDefault(name) == live.Cookies.GetValueOrDefault(name));

    /// <summary>
    /// Checks the sign-in another device sent, then signs in with it. A sign-in or sign-out here while it is checked
    /// supersedes it: it throws <see cref="OperationCanceledException"/> and changes nothing.
    /// </summary>
    public async Task ImportSignInAsync(byte[] data, CancellationToken ct = default)
    {
        YouTubeMusicSignInPayload payload;
        try { payload = YouTubeMusicSignInPayload.Decode(data); }
        catch (FormatException) { throw new TransferException(TransferErrorKind.Unreadable); }
        if (!payload.Credentials.IsUsable) throw new TransferException(TransferErrorKind.Unreadable);
        await _youtube.ImportSignInAsync(payload.Credentials, async token =>
        {
            try
            {
                return await _verify(payload.Credentials, payload.Account, token).ConfigureAwait(false);
            }
            catch (ProviderException e) when (e.Kind == ProviderErrorKind.NotSignedIn)
            {
                // Google no longer accepts these cookies. Keep this device's own session untouched.
                throw new TransferException(TransferErrorKind.Rejected);
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception)
            {
                // Offline, or YouTube didn't answer: nothing is committed until Google accepts the cookies.
                throw new TransferException(TransferErrorKind.Unverified);
            }
        }, _persist, data, ct).ConfigureAwait(false);
    }

    /// <summary>Throws when the saved cookies couldn't be deleted; the provider then stays signed in.</summary>
    public Task SignOutAsync(CancellationToken ct = default) => _youtube.TrySignOutAsync();

    void ISignInTransferSink.Committed(YouTubeMusicCredentials? credentials, AccountInfo? account, byte[]? payload)
    {
        if (credentials == null) _store.Save(null);
        // Export exactly what arrived, so the echo of an import isn't uploaded again.
        else if (payload != null) _store.Save(new YouTubeMusicTransferSnapshot(payload, _time.GetUtcNow()));
        else TakeSnapshot(credentials, account);
    }

    void ISignInTransferSink.Changed() => SignInDidChange?.Invoke();

    /// <summary>The live sign-in's payload, saved as the snapshot when the store takes it (a copy, never the only one).</summary>
    byte[] TakeSnapshot(YouTubeMusicCredentials credentials, AccountInfo? account)
    {
        var data = new YouTubeMusicSignInPayload(credentials, account).Encode();
        try { _store.Save(new YouTubeMusicTransferSnapshot(data, _time.GetUtcNow())); } catch (Exception) { }
        return data;
    }

    /// <summary>A payload with fake cookies, for sync self-tests without real credentials. YouTube rejects it.</summary>
    public static byte[] TestPayload(string accountName) =>
        new YouTubeMusicSignInPayload(
            new YouTubeMusicCredentials(new Dictionary<string, string> { ["SAPISID"] = "medley-test", ["SID"] = "medley-test", [YouTubeMusicSignInPayload.TestCookie] = "1" }),
            new AccountInfo(accountName, detail: "Test sign-in")).Encode();
}
