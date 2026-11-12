using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using OpenMusic.Sync.Convex;

namespace OpenMusic.Sync.Keys;

/// <summary>
/// Where secrets live: small named blobs. The Windows app implements it with DPAPI (CurrentUser scope); tests and the
/// Linux probe use <see cref="FileSecretStore"/> or <see cref="MemorySecretStore"/>. Names are ASCII
/// (<c>sync.credentials</c>, <c>sync.credentials.state.keys.v1</c>, …), never secret themselves.
/// </summary>
public interface ISecretStore
{
    /// <summary>The blob saved under <paramref name="name"/>, or null.</summary>
    byte[]? Read(string name);
    /// <summary>Saves (or with null deletes) the blob. Returns whether it is stored now; false leaves the old value.</summary>
    bool Write(string name, byte[]? data);
}

/// <summary>One file per name in a directory only the owner can read (0700 directory, 0600 files on Unix).</summary>
public sealed class FileSecretStore : ISecretStore
{
    private readonly string _directory;
    private readonly object _lock = new();

    public FileSecretStore(string directory)
    {
        _directory = directory;
        Directory.CreateDirectory(directory);
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(directory, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
    }

    private string PathFor(string name)
    {
        foreach (var c in name)
            if (!(char.IsAsciiLetterOrDigit(c) || c is '.' or '-' or '_')) throw new ArgumentException($"unsupported secret name {name}");
        return Path.Combine(_directory, name);
    }

    public byte[]? Read(string name)
    {
        lock (_lock)
        {
            var path = PathFor(name);
            try { return File.Exists(path) ? File.ReadAllBytes(path) : null; }
            catch (IOException) { return null; }
        }
    }

    public bool Write(string name, byte[]? data)
    {
        lock (_lock)
        {
            var path = PathFor(name);
            try
            {
                if (data is null)
                {
                    File.Delete(path);
                    return true;
                }
                var temp = path + ".tmp";
                var options = new FileStreamOptions { Mode = FileMode.Create, Access = FileAccess.Write };
                if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
                using (var stream = new FileStream(temp, options)) stream.Write(data);
                File.Move(temp, path, overwrite: true);
                return true;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
        }
    }
}

/// <summary>For tests and previews. <see cref="RefuseWrites"/> makes every write fail (a store that refuses, as a locked keychain would).</summary>
public sealed class MemorySecretStore : ISecretStore
{
    private readonly Dictionary<string, byte[]> _items = new();
    private readonly object _lock = new();
    public bool RefuseWrites { get; set; }
    /// <summary>Names whose writes fail.</summary>
    public HashSet<string> RefusedNames { get; } = new();

    public byte[]? Read(string name) { lock (_lock) return _items.TryGetValue(name, out var v) ? v.ToArray() : null; }

    public bool Write(string name, byte[]? data)
    {
        lock (_lock)
        {
            if (RefuseWrites || RefusedNames.Contains(name)) return false;
            if (data is null) _items.Remove(name); else _items[name] = data.ToArray();
            return true;
        }
    }

    public IReadOnlyCollection<string> Names { get { lock (_lock) return _items.Keys.ToList(); } }

    /// <summary>A copy of everything stored now (a relaunch from what was saved at this moment).</summary>
    public MemorySecretStore Copy()
    {
        var copy = new MemorySecretStore();
        lock (_lock) foreach (var (k, v) in _items) copy._items[k] = v.ToArray();
        return copy;
    }
}

/// <summary>
/// This device's registration with the signed-in account: its id, the account's library, its own secret token and key
/// pair, and the vault key once it has it. Never logged: <see cref="ToString"/> redacts.
/// </summary>
public sealed record SyncCredentials
{
    public required DeviceId DeviceId { get; init; }
    public required LibraryId LibraryId { get; init; }
    /// <summary>32 random bytes (base64url) the device made when it registered. Only its hash is on the server.</summary>
    public required string Token { get; init; }
    /// <summary>The deployment the token belongs to; a token from another deployment is ignored.</summary>
    public required Uri DeploymentUrl { get; init; }
    public required DeviceKeyPair DeviceKey { get; init; }
    /// <summary>The Clerk user this registration belongs to.</summary>
    public string? UserId { get; init; }
    /// <summary>The account's vault key, when this device has it. Pinned: changes only by a rotation made with it, or a claim.</summary>
    public LibraryKey? LibraryKey { get; init; }
    /// <summary>A key this device is rotating to (<c>keys:rotate</c> sent, not confirmed). Saved first.</summary>
    public LibraryKey? NextLibraryKey { get; init; }
    /// <summary>The key revision applied when <see cref="NextLibraryKey"/> was saved; only a newer list settles it.</summary>
    public int? NextLibraryKeyRevision { get; init; }
    /// <summary>A fresh key this device is claiming for an account without one. Saved before the claim is sent.</summary>
    public LibraryKey? ClaimingLibraryKey { get; init; }
    public int? ClaimingLibraryKeyRevision { get; init; }

    public bool Equals(SyncCredentials? o) => o is not null && DeviceId == o.DeviceId && LibraryId == o.LibraryId && Token == o.Token
        && DeploymentUrl == o.DeploymentUrl && DeviceKey.PublicKey == o.DeviceKey.PublicKey && UserId == o.UserId
        && LibraryKey == o.LibraryKey && NextLibraryKey == o.NextLibraryKey && ClaimingLibraryKey == o.ClaimingLibraryKey
        && NextLibraryKeyRevision == o.NextLibraryKeyRevision && ClaimingLibraryKeyRevision == o.ClaimingLibraryKeyRevision;
    public override int GetHashCode() => HashCode.Combine(DeviceId, Token);
    public override string ToString() => $"SyncCredentials(device: {DeviceId}, library: {LibraryId}, token: <redacted>, key: {LibraryKey?.Id ?? "none"})";

    /// <summary>A new device token: 32 random bytes, base64url.</summary>
    public static string NewDeviceToken() => Base64Url.Encode(RandomNumberGenerator.GetBytes(32));

    // Stored form (local to this device; not a cross-platform format).
    internal sealed record Stored(string DeviceId, string LibraryId, string Token, string DeploymentUrl, string DeviceKey, string? UserId,
                                  string? LibraryKey, string? NextLibraryKey, int? NextLibraryKeyRevision, string? ClaimingLibraryKey, int? ClaimingLibraryKeyRevision);

    internal byte[] Serialize() => JsonSerializer.SerializeToUtf8Bytes(new Stored(DeviceId.Value, LibraryId.Value, Token, DeploymentUrl.AbsoluteUri,
        DeviceKey.EncodedPrivateKey, UserId, LibraryKey?.Encoded, NextLibraryKey?.Encoded, NextLibraryKeyRevision, ClaimingLibraryKey?.Encoded,
        ClaimingLibraryKeyRevision), Wire.Options);

    /// <summary>Null for anything that doesn't decode (credentials from before accounts have no key pair and are dropped).</summary>
    internal static SyncCredentials? Deserialize(byte[]? data)
    {
        if (data is null) return null;
        try
        {
            var s = JsonSerializer.Deserialize<Stored>(data, Wire.Options);
            if (s is null || DeviceKeyPair.FromEncoded(s.DeviceKey) is not { } key) return null;
            LibraryKey? K(string? text) => text is null ? null : Keys.LibraryKey.FromEncoded(text) ?? throw new JsonException("bad key");
            return new SyncCredentials
            {
                DeviceId = new DeviceId(s.DeviceId), LibraryId = new LibraryId(s.LibraryId), Token = s.Token, DeploymentUrl = new Uri(s.DeploymentUrl),
                DeviceKey = key, UserId = s.UserId, LibraryKey = K(s.LibraryKey), NextLibraryKey = K(s.NextLibraryKey),
                NextLibraryKeyRevision = s.NextLibraryKeyRevision, ClaimingLibraryKey = K(s.ClaimingLibraryKey), ClaimingLibraryKeyRevision = s.ClaimingLibraryKeyRevision,
            };
        }
        catch (Exception e) when (e is JsonException or UriFormatException or ArgumentException) { return null; }
    }
}

/// <summary>
/// The sync credentials and their small state blobs inside an <see cref="ISecretStore"/>, under the same names the Swift
/// apps use in the Keychain: <c>sync.credentials</c> and <c>sync.credentials.state.&lt;name&gt;</c>.
/// </summary>
public sealed class SyncCredentialStore(ISecretStore secrets, string account = "sync.credentials")
{
    public ISecretStore Secrets { get; } = secrets;

    public SyncCredentials? Load() => SyncCredentials.Deserialize(Secrets.Read(account));
    public void Save(SyncCredentials? credentials) => Secrets.Write(account, credentials?.Serialize());

    /// <summary>Saves and reads back. Used before telling the server about a key only this device has.</summary>
    public bool Persist(SyncCredentials? credentials) => Secrets.Write(account, credentials?.Serialize()) && Load() == credentials;

    public byte[]? State(string name) => Secrets.Read($"{account}.state.{name}");
    public void SetState(string name, byte[]? data) => Secrets.Write($"{account}.state.{name}", data);

    /// <summary>Saves and reads back.</summary>
    public bool PersistState(string name, byte[]? data)
    {
        if (!Secrets.Write($"{account}.state.{name}", data)) return false;
        var back = State(name);
        return data is null ? back is null : back is not null && back.AsSpan().SequenceEqual(data);
    }

    public T? StateAs<T>(string name) where T : class
    {
        var data = State(name);
        if (data is null) return null;
        try { return JsonSerializer.Deserialize<T>(data, Wire.Options); } catch (JsonException) { return null; }
    }

    public static byte[] Encode<T>(T value) => JsonSerializer.SerializeToUtf8Bytes(value, Wire.Options);
}

/// <summary>
/// What this device recorded of its key exchanges (<c>sync.credentials.state.keys.v1</c>) for one deployment, library and
/// device. Each side computes the code from its own copy, never from what the server shows later.
/// </summary>
public sealed record KeyLedger
{
    public string? Scope { get; set; }
    /// <summary>This device's own request for the key (while it has none).</summary>
    public KeyLedgerAttempt? Attempt { get; set; }
    /// <summary>Answers this device gave as a holder, by the asking device's commitment.</summary>
    public Dictionary<string, KeyLedgerAnswer> Answers { get; set; } = new();
    /// <summary>Failed or refused exchanges, on either side, for the warning and the pause.</summary>
    public List<KeyLedgerFailure> Failures { get; set; } = new();
    /// <summary>When this device started requests by itself (not Ask Again), for its own limit.</summary>
    public List<DateTimeOffset> AutomaticAttempts { get; set; } = new();

    public const string StateName = "keys.v1";

    public IEnumerable<KeyLedgerFailure> FailuresSince(DateTimeOffset date) => Failures.Where(f => f.At >= date);

    /// <summary>Drops what is too old to matter for any limit or warning.</summary>
    public void Prune(DateTimeOffset now)
    {
        var day = now.AddHours(-24);
        Failures.RemoveAll(f => f.At < day);
        AutomaticAttempts.RemoveAll(a => a < day);
        foreach (var key in Answers.Where(a => a.Value.At < day).Select(a => a.Key).ToList()) Answers.Remove(key);
    }

    public KeyLedger DeepCopy() => JsonSerializer.Deserialize<KeyLedger>(JsonSerializer.SerializeToUtf8Bytes(this, Wire.Options), Wire.Options)!;
}

public enum KeyLedgerOutcome { CodesDidNotMatch, GrantDidNotOpen, TooManyAttempts }
public enum KeyAnswerState { Waiting, Verified, Tampered, Allowed, Denied }
public enum KeyFailureKind { Tampered, Denied, CodesDidNotMatch, DidNotOpen }

public sealed record KeyLedgerAttempt
{
    /// <summary>The secret this device committed to. Revealed only after a holder answered.</summary>
    public required byte[] Nonce { get; set; }
    public required string Commitment { get; set; }
    public DateTimeOffset StartedAt { get; set; }
    /// <summary>The answer as this device first received it. A different answer shown later is ignored.</summary>
    public KeyLedgerAnswered? Answer { get; set; }
    public bool Revealed { get; set; }
    /// <summary>The listener tapped Codes Match here.</summary>
    public bool Confirmed { get; set; }
    public KeyLedgerOutcome? Outcome { get; set; }
}

public sealed record KeyLedgerAnswered(DeviceId Holder, string HolderKey, byte[] HolderNonce);

public sealed record KeyLedgerAnswer
{
    public required DeviceId Device { get; set; }
    /// <summary>The asking device's public key when this device answered (the commitment covers it).</summary>
    public required string RecipientKey { get; set; }
    public required byte[] Nonce { get; set; }
    public DateTimeOffset At { get; set; }
    public bool Sent { get; set; }
    /// <summary>The nonce the asking device revealed, once it matched its commitment.</summary>
    public byte[]? RevealedNonce { get; set; }
    public KeyAnswerState State { get; set; } = KeyAnswerState.Waiting;
}

public sealed record KeyLedgerFailure(DateTimeOffset At, KeyFailureKind Kind);
