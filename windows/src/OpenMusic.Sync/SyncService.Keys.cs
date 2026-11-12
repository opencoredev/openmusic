using System.Text.Json;
using OpenMusic.Core;
using OpenMusic.Sync.Convex;
using OpenMusic.Sync.Keys;

namespace OpenMusic.Sync;

// How the vault key reaches and leaves devices (docs/accounts-design.md, "Sign-in vault key"); a port of
// SyncService+Keys.swift. The server relays everything here and is trusted with none of it:
// - A device without the key asks with a commitment, reveals its nonce only after a holder answered, shows the code from
//   its own record, and takes a key only from a grant that opens under that exchange and only after the listener
//   confirmed the code here. Until then it uploads nothing.
// - A holder answers each commitment once (a deterministic nonce per request), checks the revealed nonce against the
//   commitment, and asks the listener only about exchanges that checked out; limited per hour, paused after failures.
// - A held key is pinned: no grant replaces it. It changes only by a rotation wrapped with it, or a claim of its own.
public sealed partial class SyncService
{
    /// <summary>Answers a holder gives per hour, to anyone. More wait.</summary>
    public const int AnswersPerHour = 6;
    /// <summary>Failed or refused exchanges in a day after which a holder stops answering until the day has passed.</summary>
    public const int FailuresBeforePause = 5;
    /// <summary>Requests an asking device starts by itself per hour. Ask Again doesn't count.</summary>
    public const int AutomaticAttemptsPerHour = 3;

    // MARK: Ledger

    internal void LoadLedger()
    {
        var scope = Credentials is { } c ? Scope(c) : null;
        var saved = Store.StateAs<KeyLedger>(KeyLedger.StateName);
        if (saved is not null && scope is not null && saved.Scope == scope) Ledger = saved;
        else
        {
            Ledger = new KeyLedger { Scope = scope };
            SaveLedger();
        }
        PendingGrantKey = null;
    }

    internal void SaveLedger()
    {
        Ledger.Prune(Now());
        Store.SetState(KeyLedger.StateName, SyncCredentialStore.Encode(Ledger));
        Raise(nameof(KeyRequests));
        Raise(nameof(KeyWarning));
    }

    /// <summary>
    /// Queues <paramref name="work"/> as an account operation unless one with the same id is still queued or running. It
    /// runs only for the session it was queued in (the same device token) and in the same epoch.
    /// </summary>
    internal void Once(string id, Func<AccountOperations.Ticket, Task> work)
    {
        var token = Credentials?.Token;
        Operations.Enqueue(id, async ticket =>
        {
            if (Credentials?.Token != token) return;
            await work(ticket);
        });
    }

    // MARK: The device list

    /// <summary>
    /// A devices:list result arrived. It is applied as an account operation, after whatever runs now. While one waits, a
    /// newer one replaces it; an older one never replaces a newer one. A list for another session is dropped.
    /// </summary>
    internal void Apply(DeviceListResult list, string? token = null)
    {
        token ??= Credentials?.Token;
        if (PendingList is { } waiting && waiting.Token == token && (waiting.List.KeyRevision ?? 0) > (list.KeyRevision ?? 0)) return;
        PendingList = (list, token);
        Operations.Enqueue("apply", _ =>
        {
            if (PendingList is not { } next) return;
            PendingList = null;
            if (next.Token is null || next.Token != Credentials?.Token) return;
            ApplyNow(next.List);
        }, AccountOperations.Dedup.Started);
    }

    /// <summary>
    /// Everything a new devices:list result moves along, in order. Observations are monotonic: a list older than one this
    /// session already applied is ignored whole.
    /// </summary>
    internal void ApplyNow(DeviceListResult list)
    {
        if (Credentials is not { } credentials || list.SelfId != credentials.DeviceId) return;
        var revision = list.KeyRevision ?? 0;
        if (revision < AppliedKeyRevision) return;
        AppliedKeyRevision = revision;
        Devices = list.Devices;
        var keyChanged = ServerKeyId != list.KeyId;
        ServerKeyId = list.KeyId;
        var rotation = list.RotationNeeded ?? false;
        var rotationChanged = RotationNeeded != rotation;
        RotationNeeded = rotation;
        SettleSavedRotation(list.Rekey, revision);
        SettleSavedClaim(list.Rekey, revision);
        ReceiveRekey(list.Rekey);
        RetryAcceptIfNeeded(list.Grant);
        AnswerKeyRequests();
        CheckRevealedRequests();
        AdvanceOwnRequest(list.Grant);
        ClaimLibraryKeyIfNeeded(list.KeyId);
        RotateKeyIfNeeded();
        ReleaseKeyIfStranded(list.Rekey);
        UpdateKeyStatus();
        if (keyChanged || rotationChanged) SignIns.ReconcileAll();
    }

    /// <summary>Answers requests that waited for the hourly limit (the heartbeat calls it, as an operation).</summary>
    internal void ResumeKeyRequests()
    {
        AnswerKeyRequests();
        UpdateKeyStatus();
    }

    /// <summary>Whether this device holds the key the account uses now.</summary>
    internal bool HoldsCurrentKey => Credentials?.LibraryKey is { } key && ServerKeyId is { } server && key.Id == server;

    /// <summary>Sign-ins don't upload while this device can't be sure its key is the account's.</summary>
    public bool VaultWritesPaused => Actor.Read(() => !HoldsCurrentKey || RotationNeeded);

    internal void UpdateKeyStatus()
    {
        if (Credentials is not { } credentials) { KeyStatus = KeyStatus.NoneStatus; Raise(nameof(VaultWritesPaused)); return; }
        Raise(nameof(VaultWritesPaused));
        Raise(nameof(LibraryKey));
        if (credentials.LibraryKey is { } key)
        {
            KeyStatus = ServerKeyId is null || ServerKeyId == key.Id ? KeyStatus.AvailableStatus : KeyIsOutdated ? KeyStatus.OutdatedStatus : KeyStatus.MismatchStatus;
            return;
        }
        if (Ledger.Attempt?.Outcome is { } outcome) { KeyStatus = new KeyStatus.Failed(Message(outcome)); return; }
        if (SelfDevice?.KeyState == KeyStateKind.Denied) { KeyStatus = KeyStatus.DeniedStatus; return; }
        if (Ledger.Attempt is not { Revealed: true, Answer: { } answer } attempt || RequesterTranscript(attempt, credentials) is not { } transcript)
        {
            KeyStatus = KeyStatus.WaitingStatus;
            return;
        }
        var name = Devices.FirstOrDefault(d => d.Id == answer.Holder)?.Name ?? "your other device";
        KeyStatus = new KeyStatus.Comparing(new KeyComparison(transcript.Code, answer.Holder, name, PendingGrantKey is not null, attempt.Confirmed));
    }

    internal static string Message(KeyLedgerOutcome outcome) => outcome switch
    {
        KeyLedgerOutcome.CodesDidNotMatch => "The codes didn't match, so this device didn't take your sign-ins. Ask again, and allow it only when both devices show the same code.",
        KeyLedgerOutcome.GrantDidNotOpen => "What your other device sent didn't open here, so this device didn't take it. Ask again.",
        _ => $"{ProductInfo.Name} stopped asking for your sign-ins after several tries. Open {ProductInfo.Name} on your other device, then ask again.",
    };

    internal string? KeyExchangeWarning()
    {
        var at = Now();
        var recent = Ledger.FailuresSince(at.AddHours(-24)).ToList();
        if (recent.Any(f => f.Kind == KeyFailureKind.Tampered))
            return $"A request for your sign-ins was changed on its way to this device, so {ProductInfo.Name} refused it. If this happens again, your sync server may not be trustworthy.";
        if (recent.Count >= 2)
            return $"{recent.Count} requests for your sign-ins failed or were refused today. If they weren't yours, remove devices you don't know and sign out of your account's other sessions.";
        if (HoldsCurrentKey && !AnsweringAllowed())
            return $"{ProductInfo.Name} paused answering requests for your sign-ins after several tries. It answers again later.";
        return null;
    }

    // MARK: Asking for the key

    /// <summary>Codes Match: the key is taken once the holder's grant is here too, whichever comes first.</summary>
    public void ConfirmKeyCode() => Actor.Post(() => Operations.Perform(ConfirmKeyCodeNow));

    /// <summary>
    /// Codes Match for the comparison the listener saw: confirmed only while it is still the one being compared (same
    /// code, same holder) when the operation runs. A dialog left open across a restarted exchange can't confirm the new
    /// one, whose code nobody compared.
    /// </summary>
    public void ConfirmKeyCode(KeyComparison shown) => Actor.Post(() => Operations.Perform(() =>
    {
        if (!IsShown(shown)) return;
        ConfirmKeyCodeNow();
    }));

    /// <summary>Codes Don't Match for the comparison the listener saw (nothing happens when another one is current).</summary>
    public void RejectKeyCode(KeyComparison shown) => Actor.Post(() => Operations.Perform(() =>
    {
        if (!IsShown(shown)) return;
        RejectKeyCodeNow();
    }));

    private bool IsShown(KeyComparison shown) =>
        KeyStatus is KeyStatus.Comparing { Comparison: var current } && current.Code == shown.Code && current.HolderId == shown.HolderId;

    private void ConfirmKeyCodeNow()
    {
        if (Ledger.Attempt is not { Outcome: null, Answer: not null, Revealed: true } attempt) return;
        attempt.Confirmed = true;
        SaveLedger();
        if (PendingGrantKey is not null) CommitGrantedKey(); else UpdateKeyStatus();
    }

    /// <summary>Codes Don't Match: this attempt ends and no key from it is ever used.</summary>
    public void RejectKeyCode() => Actor.Post(() => Operations.Perform(RejectKeyCodeNow));

    private void RejectKeyCodeNow()
    {
        if (Ledger.Attempt is not { Outcome: null } attempt) return;
        attempt.Outcome = KeyLedgerOutcome.CodesDidNotMatch;
        Ledger.Failures.Add(new KeyLedgerFailure(Now(), KeyFailureKind.CodesDidNotMatch));
        PendingGrantKey = null;
        SaveLedger();
        UpdateKeyStatus();
    }

    /// <summary>
    /// This device holds a key, the account uses another one, and the server lists this device as asking. The held key is
    /// kept until the listener asks again; the server saying so is never enough to drop it.
    /// </summary>
    internal bool KeyIsOutdated
    {
        get
        {
            if (Credentials?.LibraryKey is not { } key || ServerKeyId is not { } server || server == key.Id
                || Credentials.NextLibraryKey?.Id == server || Credentials.ClaimingLibraryKey?.Id == server) return false;
            return SelfDevice?.KeyState is KeyStateKind.Requested or KeyStateKind.Denied;
        }
    }

    /// <summary>
    /// Asks the devices that have the vault key again, with a new exchange. On a device whose key is out of date, this is
    /// what drops the old key first; the current one then comes only through the code comparison.
    /// </summary>
    public async Task RequestKeyAgainAsync()
    {
        await Actor.Switch();
        await Operations.Run(null, PerformRequestKeyAgain);
    }

    private async Task PerformRequestKeyAgain(AccountOperations.Ticket ticket)
    {
        if (Credentials is not { } credentials) return;
        if (credentials.LibraryKey is not null)
        {
            if (!KeyIsOutdated) return;
            credentials = credentials with { LibraryKey = null, NextLibraryKey = null, NextLibraryKeyRevision = null };
            Credentials = credentials;
            Store.Save(credentials);
            Ledger.Attempt = null;
            PendingGrantKey = null;
        }
        if (StartAttempt(automatic: false) is not { } attempt) return;
        UpdateKeyStatus();
        await Call<ServerNowResult>("keys:request", new RequestKeyArgs(credentials.Token, attempt.Commitment), ticket);
    }

    /// <summary>A new exchange: a fresh nonce and its commitment. Null when the automatic limit is reached.</summary>
    internal KeyLedgerAttempt? StartAttempt(bool automatic)
    {
        if (Credentials is not { } credentials) return null;
        var at = Now();
        if (automatic)
        {
            if (Ledger.AutomaticAttempts.Count(a => a > at.AddHours(-1)) >= AutomaticAttemptsPerHour)
            {
                if (Ledger.Attempt is null || Ledger.Attempt.Outcome is null)
                {
                    Ledger.Attempt = new KeyLedgerAttempt { Nonce = KeyExchange.Nonce(), Commitment = "", StartedAt = at, Outcome = KeyLedgerOutcome.TooManyAttempts };
                    SaveLedger();
                }
                return null;
            }
            Ledger.AutomaticAttempts.Add(at);
        }
        var nonce = KeyExchange.Nonce();
        if (KeyExchange.Commitment(credentials.DeviceKey.PublicKey, nonce) is not { } commitment) return null;
        var attempt = new KeyLedgerAttempt { Nonce = nonce, Commitment = commitment, StartedAt = at };
        Ledger.Attempt = attempt;
        PendingGrantKey = null;
        SaveLedger();
        return attempt;
    }

    internal static KeyExchange.Transcript? RequesterTranscript(KeyLedgerAttempt attempt, SyncCredentials credentials) =>
        attempt.Answer is { } answer
            ? new KeyExchange.Transcript(credentials.LibraryId, credentials.DeviceId, credentials.DeviceKey.PublicKey, attempt.Nonce,
                                         answer.Holder, answer.HolderKey, answer.HolderNonce)
            : null;

    /// <summary>Moves this device's own request along: commit, record the first answer, reveal, open the grant.</summary>
    private void AdvanceOwnRequest(KeyGrantRow? grant)
    {
        if (Credentials is not { LibraryKey: null } credentials || ServerKeyId is null || SelfDevice is not { } own) return;
        switch (own.KeyState)
        {
            case KeyStateKind.Holder or KeyStateKind.Denied:
                return;   // a holder without a key here can do nothing; a denied device waits for Ask Again
            case KeyStateKind.Granted:
                ReceiveGrant(grant, credentials);
                break;
            default:
                ContinueRequest(own);
                break;
        }
    }

    private void ContinueRequest(SyncDevice own)
    {
        KeyLedgerAttempt attempt;
        if (Ledger.Attempt is { } current)
        {
            if (current.Outcome is not null) return;
            attempt = current;
        }
        else
        {
            if (StartAttempt(automatic: true) is not { } started) { UpdateKeyStatus(); return; }
            attempt = started;
        }
        var exchange = own.Exchange;
        if (exchange?.Commitment != attempt.Commitment)
        {
            if (attempt.Answer is null) SendRequest(attempt.Commitment);
            else if (StartAttempt(automatic: true) is { } restarted) SendRequest(restarted.Commitment);   // dropped after an answer: start over
            return;
        }
        if (!exchange.HasAnswer) return;
        if (attempt.Answer is null)
        {
            if (Base64Url.TryDecodeStandard(exchange.HolderNonce) is not { Length: 32 } nonce) return;
            attempt.Answer = new KeyLedgerAnswered(exchange.Holder!.Value, exchange.HolderKey!, nonce);
            SaveLedger();
        }
        // Reveal only after an answer was recorded, and only for this attempt's first answer.
        if (attempt.Revealed) return;
        var commitment = attempt.Commitment;
        var revealNonce = Convert.ToBase64String(attempt.Nonce);
        Once($"reveal:{commitment}", async ticket =>
        {
            if (Credentials?.Token is not { } token || Ledger.Attempt?.Commitment != commitment) return;
            try
            {
                await Call<ServerNowResult>("keys:reveal", new RevealKeyArgs(token, commitment, revealNonce), ticket);
                if (Ledger.Attempt?.Commitment != commitment) return;
                Ledger.Attempt.Revealed = true;
                SaveLedger();
                UpdateKeyStatus();
            }
            catch (OperationCanceledException) { }
            catch (Exception e) { LastError = SyncException.From(e); }
        });
    }

    private void SendRequest(string commitment)
    {
        Once($"request:{commitment}", async ticket =>
        {
            if (Credentials?.Token is not { } token || Ledger.Attempt?.Commitment != commitment) return;
            try { await Call<ServerNowResult>("keys:request", new RequestKeyArgs(token, commitment), ticket); }
            catch (OperationCanceledException) { }
            catch (Exception e) { LastError = SyncException.From(e); }
        });
    }

    /// <summary>A grant counts only if it belongs to this device's current exchange and opens under its own transcript.</summary>
    private void ReceiveGrant(KeyGrantRow? grant, SyncCredentials credentials)
    {
        if (Ledger.Attempt is not { Outcome: null } attempt) return;
        if (grant is null || grant.Commitment != attempt.Commitment || !attempt.Revealed || RequesterTranscript(attempt, credentials) is not { } transcript)
        {
            // A grant that belongs to no exchange of this device (an old one, or made up): ask anew.
            if (StartAttempt(automatic: true) is { } started) SendRequest(started.Commitment);
            return;
        }
        if (PendingGrantKey is null)
        {
            if (FailedKeyBlobs.Contains(grant.Wrapped)) return;
            try
            {
                PendingGrantKey = KeyExchange.Unwrap(grant.Wrapped, transcript, credentials.DeviceKey, grant.KeyId);
            }
            catch (Exception e)
            {
                FailedKeyBlobs.Add(grant.Wrapped);
                attempt.Outcome = KeyLedgerOutcome.GrantDidNotOpen;
                Ledger.Failures.Add(new KeyLedgerFailure(Now(), KeyFailureKind.DidNotOpen));
                SaveLedger();
                LastError = SyncException.From(e);
                return;
            }
        }
        if (attempt.Confirmed) CommitGrantedKey();
    }

    /// <summary>
    /// Keeps the key from a grant that opened and whose code the listener confirmed, and tells the server. Saved before
    /// anything else changes; when the save fails nothing is acknowledged and the next list tries again.
    /// </summary>
    private void CommitGrantedKey()
    {
        if (PendingGrantKey is not { } key || Credentials is not { LibraryKey: null } credentials) return;
        var updated = credentials with { LibraryKey = key };
        if (!Store.Persist(updated))
        {
            LastError = SyncException.Server($"{ProductInfo.Name} couldn't save the key for your sign-ins. It tries again in a moment.");
            return;
        }
        Credentials = updated;
        PendingGrantKey = null;
        Ledger.Attempt = null;
        SaveLedger();
        UpdateKeyStatus();
        SignIns.ReconcileAll();
        AcceptKey(key.Id);
    }

    private void AcceptKey(string keyId)
    {
        Once($"accept:{keyId}", async ticket =>
        {
            if (Credentials?.Token is not { } token) return;
            try { await Call<ServerNowResult>("keys:accept", new AcceptKeyArgs(token, keyId), ticket); } catch (Exception) { }
        });
    }

    /// <summary>This device took a granted key but the server still shows the grant: say it again.</summary>
    private void RetryAcceptIfNeeded(KeyGrantRow? grant)
    {
        if (grant is null || Credentials?.LibraryKey is not { } key || key.Id != grant.KeyId || SelfDevice?.KeyState != KeyStateKind.Granted) return;
        AcceptKey(key.Id);
    }

    // MARK: Answering as a holder

    private bool AnsweringAllowed()
    {
        var at = Now();
        var lastHour = Ledger.Answers.Values.Count(a => a.At > at.AddHours(-1));
        var failures = Ledger.FailuresSince(at.AddHours(-24)).Count();
        return lastHour < AnswersPerHour && failures < FailuresBeforePause;
    }

    /// <summary>
    /// Answers each new commitment once, while this device holds the account's key. Every answer stays in the ledger and
    /// counts toward the hourly limit, whatever the server replies.
    /// </summary>
    private void AnswerKeyRequests()
    {
        if (!HoldsCurrentKey || Credentials is not { } credentials) return;
        foreach (var device in OtherDevices)
        {
            if (device.KeyState != KeyStateKind.Requested || device.Exchange is not { Phase: ExchangePhase.Committed } exchange || device.PublicKey is not { } publicKey) continue;
            var commitment = exchange.Commitment;
            if (Ledger.Answers.TryGetValue(commitment, out var known))
            {
                if (!known.Sent && known.Device == device.Id) SendAnswer(commitment, known);
                continue;
            }
            if (!AnsweringAllowed()) continue;
            if (KeyExchange.AnswerNonce(credentials.DeviceKey, credentials.DeviceId, credentials.LibraryId, device.Id, publicKey, commitment) is not { } nonce) continue;
            var answer = new KeyLedgerAnswer { Device = device.Id, RecipientKey = publicKey, Nonce = nonce, At = Now() };
            // Recorded before it is sent: this nonce is the only one this device ever uses for this request.
            Ledger.Answers[commitment] = answer;
            SaveLedger();
            SendAnswer(commitment, answer);
        }
    }

    private void SendAnswer(string commitment, KeyLedgerAnswer answer)
    {
        Once($"answer:{commitment}", async ticket =>
        {
            if (Credentials?.Token is not { } token || !Ledger.Answers.TryGetValue(commitment, out var current) || current.Sent) return;
            var args = new AnswerKeyArgs(token, answer.Device, commitment, Convert.ToBase64String(answer.Nonce));
            try
            {
                await Call<ServerNowResult>("keys:answer", args, ticket);
                if (Ledger.Answers.TryGetValue(commitment, out var a)) a.Sent = true;
                SaveLedger();
            }
            catch (SyncConflictException)
            {
                // Another holder answered first, or the server says so after reading the nonce: the record stays (it
                // counts toward the hourly limit and keeps this commitment's one nonce) and isn't sent again.
                if (Ledger.Answers.TryGetValue(commitment, out var a)) a.Sent = true;
                SaveLedger();
            }
            catch (Exception) { }
        });
    }

    /// <summary>
    /// An exchange this device answered was revealed: check the nonce against the commitment (and that this device's own
    /// nonce came back unchanged). One that doesn't check out is refused and never shown.
    /// </summary>
    private void CheckRevealedRequests()
    {
        if (SelfId is not { } me) return;
        foreach (var device in OtherDevices)
        {
            if (device.Exchange is not { Phase: ExchangePhase.Revealed } exchange || exchange.Holder != me) continue;
            var commitment = exchange.Commitment;
            if (!Ledger.Answers.TryGetValue(commitment, out var answer) || answer.Device != device.Id || answer.State != KeyAnswerState.Waiting) continue;
            var revealed = Base64Url.TryDecodeStandard(exchange.Nonce);
            if (exchange.HolderNonce != Convert.ToBase64String(answer.Nonce) || revealed is not { Length: 32 }
                || KeyExchange.Commitment(answer.RecipientKey, revealed) != commitment)
            {
                answer.State = KeyAnswerState.Tampered;
                Ledger.Failures.Add(new KeyLedgerFailure(Now(), KeyFailureKind.Tampered));
                SaveLedger();
                var target = device.Id;
                Once($"deny:{commitment}", async ticket =>
                {
                    if (Credentials?.Token is not { } token) return;
                    try { await Call<ServerNowResult>("keys:deny", new DeviceArgs(token, target), ticket); } catch (Exception) { }
                });
                continue;
            }
            answer.RevealedNonce = revealed;
            answer.State = KeyAnswerState.Verified;
            SaveLedger();
        }
    }

    internal static KeyExchange.Transcript HolderTranscript(KeyLedgerAnswer answer, byte[] revealed, SyncCredentials credentials) =>
        new(credentials.LibraryId, answer.Device, answer.RecipientKey, revealed, credentials.DeviceId, credentials.DeviceKey.PublicKey, answer.Nonce);

    internal IReadOnlyList<KeyRequest> VerifiedKeyRequests()
    {
        if (Credentials is not { } credentials || !HoldsCurrentKey || SelfId is not { } me) return [];
        var requests = new List<KeyRequest>();
        foreach (var device in OtherDevices)
        {
            if (device.KeyState != KeyStateKind.Requested || device.Exchange is not { Phase: ExchangePhase.Revealed } exchange || exchange.Holder != me) continue;
            if (!Ledger.Answers.TryGetValue(exchange.Commitment, out var answer) || answer.Device != device.Id || answer.State != KeyAnswerState.Verified
                || answer.RevealedNonce is not { } revealed) continue;
            requests.Add(new KeyRequest(device, HolderTranscript(answer, revealed, credentials).Code, exchange.Commitment));
        }
        return requests;
    }

    /// <summary>
    /// Gives the vault key to a device whose code the listener compared: sealed for the exchange, so only that device opens
    /// it. Replaces the key first when a device that could open the vault left.
    /// </summary>
    public async Task AllowKeyAsync(KeyRequest request)
    {
        await Actor.Switch();
        await Operations.Run(null, t => PerformAllowKey(request, t));
    }

    private async Task PerformAllowKey(KeyRequest request, AccountOperations.Ticket ticket)
    {
        if (!Ledger.Answers.TryGetValue(request.Commitment, out var answer) || answer.State != KeyAnswerState.Verified || answer.RevealedNonce is not { } revealed)
            throw SyncException.KeyGrantFailed("that request changed; check its code again");
        if (RotationNeeded) await PerformRotation(ticket);
        if (Credentials is not { LibraryKey: { } key } credentials || key.Id != ServerKeyId) throw SyncException.LibraryKeyMismatch;
        var transcript = HolderTranscript(answer, revealed, credentials);
        var wrapped = KeyExchange.Wrap(key, transcript, credentials.DeviceKey);
        await Call<ServerNowResult>("keys:grant", new GrantKeyArgs(credentials.Token, answer.Device, key.Id, wrapped, request.Commitment), ticket);
        if (Ledger.Answers.TryGetValue(request.Commitment, out var a)) a.State = KeyAnswerState.Allowed;
        SaveLedger();
    }

    /// <summary>Says no to a device asking for the vault key. It stops asking until it asks again.</summary>
    public async Task DenyKeyAsync(KeyRequest request)
    {
        await Actor.Switch();
        await Operations.Run(null, async ticket =>
        {
            await Call<ServerNowResult>("keys:deny", new DeviceArgs(RequireToken(), request.Device.Id), ticket);
            if (Ledger.Answers.TryGetValue(request.Commitment, out var a)) a.State = KeyAnswerState.Denied;
            Ledger.Failures.Add(new KeyLedgerFailure(Now(), KeyFailureKind.Denied));
            SaveLedger();
        });
    }

    // MARK: Rotation

    private void RotateKeyIfNeeded()
    {
        if (!RotationNeeded || !HoldsCurrentKey || VaultEntries is null || SealedSettings is null) return;
        Once("rotate", async ticket =>
        {
            if (!RotationNeeded || !HoldsCurrentKey) return;
            try { await PerformRotation(ticket); } catch (Exception) { }
        });
    }

    /// <summary>Replaces the account's vault key (rotation), as an account operation.</summary>
    public async Task RotateKeyAsync()
    {
        await Actor.Switch();
        await Operations.Run(null, PerformRotation);
    }

    internal async Task PerformRotation(AccountOperations.Ticket ticket)
    {
        if (Credentials is not { LibraryKey: { } old } credentials || ServerKeyId != old.Id) throw SyncException.LibraryKeyMismatch;
        if (VaultEntries is not { } entries || SealedSettings is not { } settingRows || SelfId is not { } me)
            throw SyncException.Server("Your sign-ins haven't loaded yet. Try again in a moment.");
        var next = credentials.NextLibraryKey ?? Keys.LibraryKey.Generate();
        if (credentials.NextLibraryKey is null)
        {
            // Settled only by a list newer than this one (SettleSavedRotation).
            credentials = credentials with { NextLibraryKey = next, NextLibraryKeyRevision = AppliedKeyRevision };
            if (!Store.Persist(credentials)) throw SyncException.Server($"{ProductInfo.Name} couldn't save a new key for your sign-ins. Try again in a moment.");
            Credentials = credentials;
        }
        var wraps = new List<RotateWrap>();
        foreach (var device in OtherDevices.Where(d => d.KeyState == KeyStateKind.Holder))
        {
            if (device.PublicKey is not { } publicKey) continue;
            wraps.Add(new RotateWrap(device.Id, KeyRotation.Wrap(next, old, publicKey, credentials.LibraryId, device.Id)));
        }
        var vault = entries.Where(e => e.Sealed is not null).Select(entry =>
        {
            byte[]? opened = null;
            if (entry.KeyId == old.Id)
            {
                try
                {
                    opened = entry.Revision == 0
                        ? SignInSealing.OpenLegacy(entry.Sealed!, entry.Provider, old)
                        : SignInSealing.Open(entry.Sealed!, entry.Provider, entry.Revision, old);
                }
                catch (SyncException) { }
            }
            var resealed = opened is null ? null : SignInSealing.Seal(opened, entry.Provider, entry.Revision + 1, next);
            return new RotateReseal(entry.Provider, entry.Revision, resealed);
        }).ToList();
        // Every settings value, re-sealed under the new key in the same transaction (the server makes this device the
        // row's writer, so it seals as itself); a row that doesn't open with the old key is deleted.
        var settings = settingRows.Select(row =>
        {
            byte[]? opened = null;
            try { opened = ContentSealing.Open(row.Value, ContentKind.Setting, credentials.LibraryId, new DeviceId(row.UpdatedBy), row.Key, old); }
            catch (ContentSealingException) { }
            var resealed = opened is null ? null : ContentSealing.Seal(opened, ContentKind.Setting, credentials.LibraryId, me, row.Key, next);
            return new RotateSetting(row.Key, row.UpdatedAt, resealed);
        }).ToList();
        var args = new RotateKeyArgs(credentials.Token, old.Id, next.Id, wraps, vault, settings);
        var decidedAt = AppliedKeyRevision;
        RotateKeyResult result;
        try
        {
            result = await Call<RotateKeyResult>("keys:rotate", args, ticket);
        }
        catch (SyncException e) when (e.Kind == SyncErrorKind.Server && (e.Detail ?? "").Contains("new key", StringComparison.Ordinal))
        {
            // Refused outright (a key the account used before): it never landed, so the next rotation makes a new one.
            if (Credentials is { } current && current.NextLibraryKey == next)
            {
                Credentials = current with { NextLibraryKey = null, NextLibraryKeyRevision = null };
                Store.Save(Credentials);
            }
            throw;
        }
        // The answer counts only if newer than the state the rotation was decided on; else the saved key stays for a list.
        if (!Observe(result.KeyRevision, decidedAt)) return;
        AdoptRotatedKey(next);
    }

    /// <summary>
    /// An answer reporting the key revision after a change this device made (claim, rotate): counts only if newer than the
    /// revision the change was decided on and not older than what this session applied.
    /// </summary>
    internal bool Observe(int? revision, int decidedAt)
    {
        if (revision is not { } r) return true;
        if (r <= decidedAt || r < AppliedKeyRevision) return false;
        AppliedKeyRevision = r;
        return true;
    }

    private void AdoptRotatedKey(LibraryKey next)
    {
        if (Credentials is not { } credentials) return;
        Credentials = credentials with { LibraryKey = next, NextLibraryKey = null, NextLibraryKeyRevision = null };
        Store.Save(Credentials);
        ServerKeyId = next.Id;
        RotationNeeded = false;
        UpdateKeyStatus();
        SignIns.ReconcileAll();
    }

    /// <summary>
    /// A rotation this device started whose answer didn't arrive: the server's key says whether it landed. The saved key is
    /// dropped only on proof from a newer list that it can no longer matter.
    /// </summary>
    private void SettleSavedRotation(RekeyRow? rekey, int revision)
    {
        if (Credentials is not { NextLibraryKey: { } next } credentials) return;
        if (ServerKeyId == next.Id) { AdoptRotatedKey(next); return; }
        if (rekey?.FromKeyId == next.Id) return;
        var fresh = revision > (credentials.NextLibraryKeyRevision ?? int.MaxValue);
        if (!fresh || ServerKeyId == credentials.LibraryKey?.Id) return;
        Credentials = credentials with { NextLibraryKey = null, NextLibraryKeyRevision = null };
        Store.Save(Credentials);
    }

    /// <summary>
    /// Another holder replaced the key: open the new key with this device's key pair and the key it was made from (the
    /// held key, or one it rotated to itself and never heard back about). A wrap that doesn't open is refused.
    /// </summary>
    private void ReceiveRekey(RekeyRow? rekey)
    {
        if (rekey is null || Credentials is not { } credentials || SelfId is not { } me) return;
        if (credentials.LibraryKey?.Id == rekey.KeyId) { AcceptKey(rekey.KeyId); return; }
        if (HeldKeys(credentials).FirstOrDefault(k => k.Id == rekey.FromKeyId) is not { } old || rekey.KeyId != ServerKeyId || FailedKeyBlobs.Contains(rekey.Wrapped)) return;
        try
        {
            var opened = KeyRotation.Unwrap(rekey.Wrapped, credentials.DeviceKey, old, credentials.LibraryId, me, rekey.KeyId);
            var updated = credentials with { LibraryKey = opened, NextLibraryKey = null, NextLibraryKeyRevision = null };
            // Saved before it's acknowledged.
            if (!Store.Persist(updated))
            {
                LastError = SyncException.Server($"{ProductInfo.Name} couldn't save the new key for your sign-ins. It tries again in a moment.");
                return;
            }
            Credentials = updated;
            UpdateKeyStatus();
            SignIns.ReconcileAll();
            AcceptKey(opened.Id);
        }
        catch (Exception e)
        {
            FailedKeyBlobs.Add(rekey.Wrapped);
            Ledger.Failures.Add(new KeyLedgerFailure(Now(), KeyFailureKind.DidNotOpen));
            SaveLedger();
            LastError = SyncException.From(e);
        }
    }

    /// <summary>
    /// The server lists this device as a holder, but the key it holds isn't the account's and nothing here can reach the
    /// current one. It looks again (a fresh list, applied) and only if still stranded calls keys:release, a compare-and-swap
    /// on what it examined. Runs as one operation.
    /// </summary>
    private void ReleaseKeyIfStranded(RekeyRow? rekey)
    {
        if (Credentials is not { LibraryKey: { } held } credentials || ServerKeyId is not { } server || server == held.Id
            || SelfDevice?.KeyState != KeyStateKind.Holder || Operations.IsPending("rotate") || credentials.NextLibraryKey?.Id == server
            || credentials.ClaimingLibraryKey is not null || Operations.IsPending("claim")) return;
        if (rekey is not null && CanOpen(rekey, server)) return;
        Once($"release:{held.Id}", ticket => ReleaseAfterLookingAgain(held, ticket));
    }

    private bool CanOpen(RekeyRow rekey, string accountKey) =>
        Credentials is { } credentials && rekey.KeyId == accountKey && !FailedKeyBlobs.Contains(rekey.Wrapped)
        && HeldKeys(credentials).Any(k => k.Id == rekey.FromKeyId);

    private static IEnumerable<LibraryKey> HeldKeys(SyncCredentials credentials) =>
        new[] { credentials.LibraryKey, credentials.NextLibraryKey }.OfType<LibraryKey>();

    private async Task ReleaseAfterLookingAgain(LibraryKey held, AccountOperations.Ticket ticket)
    {
        if (Credentials?.Token is not { } token || Credentials.LibraryKey != held) return;
        DeviceListResult fresh;
        try
        {
            fresh = await FetchDeviceList(token, ticket.Token);
            ticket.Check(Operations);
        }
        catch (OperationCanceledException) { return; }
        catch (Exception e)
        {
            if (!ticket.IsValid(Operations)) return;
            LastError = SyncException.From(e);
            Report(e, token);
            return;
        }
        if (Credentials?.Token != token || fresh.SelfId != SelfId) return;
        if ((fresh.KeyRevision ?? 0) < AppliedKeyRevision) return;   // older than what was applied: decides nothing
        ApplyNow(fresh);   // fresher than the list that brought this device here: a rotated key it can open is taken now
        if (Credentials is not { } credentials || credentials.LibraryKey != held || fresh.KeyId is not { } account || account == held.Id
            || fresh.Devices.FirstOrDefault(d => d.Id == fresh.SelfId)?.KeyState != KeyStateKind.Holder || Operations.IsPending("rotate")
            || credentials.NextLibraryKey is not null || credentials.ClaimingLibraryKey is not null || Operations.IsPending("claim")) return;
        if (fresh.Rekey is { } r && CanOpen(r, account)) return;
        var args = new ReleaseKeyArgs(token, held.Id, account, fresh.Rekey?.KeyId, fresh.KeyRevision ?? 0);
        try { await Call<ServerNowResult>("keys:release", args, ticket); }
        catch (SyncConflictException) { }   // the next list decides again
        catch (OperationCanceledException) { }
        catch (Exception e) { LastError = SyncException.From(e); }
    }

    // MARK: An account without a key

    /// <summary>
    /// An account whose vault key is gone gets one from the first device that notices: a fresh key, saved before the claim
    /// is sent (a retry sends the same key and the revision it was decided on).
    /// </summary>
    private void ClaimLibraryKeyIfNeeded(string? serverKey)
    {
        if (serverKey is not null || Credentials is null) return;
        Once("claim", async ticket =>
        {
            if (Credentials is not { } credentials || ServerKeyId is not null) return;
            var token = credentials.Token;
            LibraryKey key;
            if (credentials.ClaimingLibraryKey is { } saved) key = saved;
            else
            {
                key = Keys.LibraryKey.Generate();
                credentials = credentials with { ClaimingLibraryKey = key, ClaimingLibraryKeyRevision = AppliedKeyRevision };
                if (!Store.Persist(credentials))
                {
                    LastError = SyncException.Server($"{ProductInfo.Name} couldn't save a new key for your sign-ins. It tries again later.");
                    return;
                }
                Credentials = credentials;
            }
            var decidedAt = credentials.ClaimingLibraryKeyRevision ?? 0;
            try
            {
                var result = await CallReportingCodes<ClaimKeyResult>("keys:claim", new ClaimKeyArgs(token, key.Id, decidedAt), ticket);
                if (result.KeyId != key.Id || Credentials?.Token != token) return;
                Observe(result.KeyRevision, decidedAt);
                AdoptClaimedKey(key);
            }
            catch (OperationCanceledException) { }   // overtaken: the key stays saved for whoever settles it
            catch (ConvexClientException e) when (e.Code is "forbidden" or "conflict")
            {
                // Refused: it didn't land, and no copy of it can land later.
                DropClaimingKey(key);
                UpdateKeyStatus();
            }
            catch (Exception e)
            {
                // Not known to have landed: the key stays saved, and the next list settles it.
                if (SyncException.From(e).Kind == SyncErrorKind.RemovedFromLibrary) Report(e, token);
                UpdateKeyStatus();
            }
        });
    }

    private void AdoptClaimedKey(LibraryKey key, string? serverKey = null)
    {
        if (Credentials is not { } credentials) return;
        Credentials = credentials with
        {
            LibraryKey = key, NextLibraryKey = null, NextLibraryKeyRevision = null, ClaimingLibraryKey = null, ClaimingLibraryKeyRevision = null,
        };
        Store.Save(Credentials);
        ServerKeyId = serverKey ?? key.Id;
        Ledger.Attempt = null;
        PendingGrantKey = null;
        SaveLedger();
        UpdateKeyStatus();
        SignIns.ReconcileAll();
    }

    private void DropClaimingKey(LibraryKey key)
    {
        if (Credentials is not { } credentials || credentials.ClaimingLibraryKey != key) return;
        Credentials = credentials with { ClaimingLibraryKey = null, ClaimingLibraryKeyRevision = null };
        Store.Save(Credentials);
    }

    /// <summary>
    /// A claim this device sent whose answer didn't arrive: a list newer than the revision it was decided on settles it
    /// (naming the key, it landed; naming another or none, it never can), except a rotation made from it waiting here.
    /// </summary>
    private void SettleSavedClaim(RekeyRow? rekey, int revision)
    {
        if (Credentials is not { ClaimingLibraryKey: { } claiming } credentials || Operations.IsPending("claim")) return;
        if (ServerKeyId == claiming.Id || rekey?.FromKeyId == claiming.Id) AdoptClaimedKey(claiming, ServerKeyId);
        else if (credentials.ClaimingLibraryKeyRevision is { } decidedAt && revision > decidedAt) DropClaimingKey(claiming);
    }
}
