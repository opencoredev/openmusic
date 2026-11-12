using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;
using OpenMusic.Core;
using OpenMusic.Core.Sync;
using OpenMusic.Sync.Keys;

namespace OpenMusic.Sync;

// C# mirrors of the validators in sync/convex/model.ts (and Sources/OpenMusicSync/Model/SyncModels.swift). Field names
// match the wire exactly.

/// <summary>JSON options for everything sent to or read from the sync server: camelCase, nulls left out (as Swift's
/// JSONEncoder leaves out nil optionals), enums as their camelCase names, UUIDs uppercase.</summary>
public static class Wire
{
    public static readonly JsonSerializerOptions Options = Make();

    private static JsonSerializerOptions Make()
    {
        var o = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        };
        o.Converters.Add(new UppercaseGuidJsonConverter());
        // Before the general enum converter, which would otherwise win over the type's own converter and fail a whole
        // device list on a platform this build doesn't know.
        o.Converters.Add(new DevicePlatformJsonConverter());
        o.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase));
        o.MakeReadOnly(populateMissingResolver: true);
        return o;
    }
}

/// <summary>UUIDs as Swift writes them: uppercase, hyphenated.</summary>
public sealed class UppercaseGuidJsonConverter : JsonConverter<Guid>
{
    public override Guid Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        Guid.Parse(reader.GetString() ?? throw new JsonException("uuid"));
    public override void Write(Utf8JsonWriter writer, Guid value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToString("D").ToUpperInvariant());
}

/// <summary>A device's id in the sync backend (a Convex document id).</summary>
[JsonConverter(typeof(DeviceIdConverter))]
public readonly record struct DeviceId(string Value)
{
    public override string ToString() => Value;
}

[JsonConverter(typeof(LibraryIdConverter))]
public readonly record struct LibraryId(string Value)
{
    public override string ToString() => Value;
}

[JsonConverter(typeof(CommandIdConverter))]
public readonly record struct CommandId(string Value)
{
    public override string ToString() => Value;
}

internal sealed class DeviceIdConverter : JsonConverter<DeviceId>
{
    public override DeviceId Read(ref Utf8JsonReader r, Type t, JsonSerializerOptions o) => new(r.GetString() ?? throw new JsonException("device id"));
    public override void Write(Utf8JsonWriter w, DeviceId v, JsonSerializerOptions o) => w.WriteStringValue(v.Value);
}
internal sealed class LibraryIdConverter : JsonConverter<LibraryId>
{
    public override LibraryId Read(ref Utf8JsonReader r, Type t, JsonSerializerOptions o) => new(r.GetString() ?? throw new JsonException("library id"));
    public override void Write(Utf8JsonWriter w, LibraryId v, JsonSerializerOptions o) => w.WriteStringValue(v.Value);
}
internal sealed class CommandIdConverter : JsonConverter<CommandId>
{
    public override CommandId Read(ref Utf8JsonReader r, Type t, JsonSerializerOptions o) => new(r.GetString() ?? throw new JsonException("command id"));
    public override void Write(Utf8JsonWriter w, CommandId v, JsonSerializerOptions o) => w.WriteStringValue(v.Value);
}

/// <summary>Whether a device holds the account's vault key (the key YouTube Music and Spotify sign-ins are sealed with).</summary>
public enum KeyStateKind { Holder, Requested, Denied, Granted }

/// <summary>One of the account's devices (<c>devices:list</c>).</summary>
public sealed record SyncDevice
{
    public required DeviceId Id { get; init; }
    public required string Name { get; init; }
    public required DevicePlatform Platform { get; init; }
    public required string Model { get; init; }
    public required string AppVersion { get; init; }
    public double CreatedAt { get; init; }
    public double LastSeenAt { get; init; }
    /// <summary>Null only for devices from before accounts.</summary>
    public KeyStateKind? KeyState { get; init; }
    /// <summary>Its X25519 public key (base64). Holders wrap the vault key to it.</summary>
    public string? PublicKey { get; init; }
    /// <summary>Its verification exchange, while it asks for the vault key.</summary>
    public KeyExchangeRow? Exchange { get; init; }

    /// <summary>Seen in the last 90 s, judged on the server clock.</summary>
    public bool IsOnline(double serverNow) => serverNow - LastSeenAt < SyncLimits.OnlineWindow.TotalMilliseconds;
}

public enum ExchangePhase { Committed, Answered, Revealed }

/// <summary>
/// A device's verification exchange as the server relays it. Every field is public. Devices never trust it for anything
/// but transport: each keeps its own record of what it sent and first received.
/// </summary>
[JsonConverter(typeof(KeyExchangeRowConverter))]
public sealed record KeyExchangeRow(ExchangePhase Phase, string Commitment, DeviceId? Holder = null, string? HolderKey = null,
                                    string? HolderNonce = null, string? Nonce = null)
{
    public static KeyExchangeRow Committed(string commitment) => new(ExchangePhase.Committed, commitment);
    public bool HasAnswer => Phase != ExchangePhase.Committed;
    /// <summary>The revealed nonce, once revealed.</summary>
    public string? RevealedNonce => Phase == ExchangePhase.Revealed ? Nonce : null;
}

internal sealed class KeyExchangeRowConverter : JsonConverter<KeyExchangeRow>
{
    public override KeyExchangeRow Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var o = doc.RootElement;
        string Req(string key) => o.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString()! : throw new JsonException($"exchange.{key}");
        var commitment = Req("commitment");
        return Req("phase") switch
        {
            "committed" => KeyExchangeRow.Committed(commitment),
            "answered" => new KeyExchangeRow(ExchangePhase.Answered, commitment, new DeviceId(Req("holder")), Req("holderKey"), Req("holderNonce")),
            "revealed" => new KeyExchangeRow(ExchangePhase.Revealed, commitment, new DeviceId(Req("holder")), Req("holderKey"), Req("holderNonce"), Req("nonce")),
            var other => throw new JsonException($"unknown exchange phase {other}"),
        };
    }

    public override void Write(Utf8JsonWriter w, KeyExchangeRow v, JsonSerializerOptions options)
    {
        w.WriteStartObject();
        w.WriteString("phase", v.Phase switch { ExchangePhase.Committed => "committed", ExchangePhase.Answered => "answered", _ => "revealed" });
        w.WriteString("commitment", v.Commitment);
        if (v.Phase != ExchangePhase.Committed)
        {
            w.WriteString("holder", v.Holder!.Value.Value);
            w.WriteString("holderKey", v.HolderKey);
            w.WriteString("holderNonce", v.HolderNonce);
        }
        if (v.Phase == ExchangePhase.Revealed) w.WriteString("nonce", v.Nonce);
        w.WriteEndObject();
    }
}

/// <summary>Whether a playback row's content opened here.</summary>
public enum PlaybackContentState
{
    /// <summary>Opened with this device's key.</summary>
    Open,
    /// <summary>Sealed under a key this device doesn't hold (none yet, or a retired one).</summary>
    Sealed,
    /// <summary>The device publishes no content (it has no key).</summary>
    None,
}

/// <summary>One device's published playback (<c>playback:list</c>), opened. The anchor (where and how it plays) is always
/// there; what plays only when this device holds the key it was sealed with. Otherwise <see cref="Track"/>,
/// <see cref="Index"/> and <see cref="QueueLength"/> are null: show "Playing on Riley's Mac · 2:13" without a title.</summary>
public sealed record RemotePlayback
{
    public required DeviceId DeviceId { get; init; }
    public Track? Track { get; init; }
    /// <summary>Index of the track within the device's queue window.</summary>
    public int? Index { get; init; }
    public int? QueueLength { get; init; }
    public int QueueVersion { get; init; }
    public required PlaybackAnchor Anchor { get; init; }
    public double UpdatedAt { get; init; }
    public PlaybackContentState Content { get; init; }

    /// <summary>"Title · Artist" when this device can read it; null while it's sealed from this device.</summary>
    public string? TrackLine => Track is { } t ? $"{t.Title} · {string.Join(", ", t.Artists.Select(a => a.Name))}" : null;
}

/// <summary>A playback row as the server has it (<c>playback:list</c>).</summary>
internal sealed record PlaybackRow(DeviceId DeviceId, SealedContent? Content, int QueueVersion, PlaybackAnchor Anchor, double UpdatedAt);

/// <summary>A command as it travels: every kind but takeOver carries only numbers; a takeover's queue window is sealed
/// (kind command, the target in the authenticated data) and its anchor not.</summary>
internal sealed record WireCommand(
    SyncCommandKind Kind,
    [property: JsonPropertyName("positionMs")] double? PositionMs = null,
    [property: JsonPropertyName("volume")] double? Volume = null,
    [property: JsonPropertyName("anchor")] PlaybackAnchor? Anchor = null,
    [property: JsonPropertyName("content")] SealedContent? Content = null)
{
    public static WireCommand Plain(SyncCommand command) => command.Kind switch
    {
        SyncCommandKind.TakeOver => throw new InvalidOperationException("A takeover is sealed, never sent in the clear."),
        SyncCommandKind.Seek => new(command.Kind, PositionMs: command.PositionMs ?? 0),
        SyncCommandKind.SetVolume => new(command.Kind, Volume: command.Volume ?? 0),
        _ => new(command.Kind),
    };
}

/// <summary>A result as it travels (<c>commands:ack</c>, <c>commands:outgoing</c>).</summary>
internal sealed record WireResult(bool Ok, CommandFailure? Reason = null, SealedContent? Content = null);

internal sealed record WireIncomingCommand(CommandId Id, DeviceId FromDeviceId, WireCommand Command, double CreatedAt, double ExpiresAt);

internal sealed record WireOutgoingCommand(CommandId Id, DeviceId ToDeviceId, SyncCommandKind Kind, double CreatedAt, double ExpiresAt,
                                           double? AckedAt, WireResult? Result);

/// <summary>A settings row as the server has it: the value sealed (kind setting, the key and <c>updatedBy</c> bound in).</summary>
internal sealed record SealedSettingEntry(string Key, SealedContent Value, double UpdatedAt, string UpdatedBy, string? WriteId);

/// <summary>A command waiting for this device (<c>commands:incoming</c>).</summary>
public sealed record IncomingCommand
{
    public required CommandId Id { get; init; }
    public required DeviceId FromDeviceId { get; init; }
    public required SyncCommand Command { get; init; }
    public double CreatedAt { get; init; }
    public double ExpiresAt { get; init; }
}

/// <summary>A command this device sent (<c>commands:outgoing</c>), and whether it was acked.</summary>
public sealed record OutgoingCommand
{
    public required CommandId Id { get; init; }
    public required DeviceId ToDeviceId { get; init; }
    public required SyncCommandKind Kind { get; init; }
    public double CreatedAt { get; init; }
    public double ExpiresAt { get; init; }
    public double? AckedAt { get; init; }
    public CommandResult? Result { get; init; }
}

/// <summary>A provider's row in the vault (<c>vault:list</c>).</summary>
public sealed record VaultEntry
{
    public required ProviderId Provider { get; init; }
    /// <summary>Base64 AES-GCM ciphertext; null after "sign out everywhere", or when <see cref="Cleared"/>.</summary>
    public string? Sealed { get; init; }
    /// <summary>The account lost its vault key and this sign-in with it. Not a sign-out.</summary>
    public bool Cleared { get; init; }
    public required string KeyId { get; init; }
    /// <summary>Counts every write of this row, sign-outs included (0 for rows from before revisions).</summary>
    public int Revision { get; init; }
    public double UpdatedAt { get; init; }
    public required DeviceId UpdatedBy { get; init; }
}

/// <summary>A vault write the server accepted.</summary>
public readonly record struct VaultWrite(double UpdatedAt, int Revision);

/// <summary>The server refused a write based on an older revision than the stored one (code <c>conflict</c>).</summary>
public sealed class SyncConflictException(int? revision) : Exception("Another device changed this first.")
{
    /// <summary>The stored revision, when the server said.</summary>
    public int? Revision { get; } = revision;
}

// MARK: - Function argument and result shapes

internal interface IServerTimed { double ServerNow { get; } }

internal sealed record TokenArgs(string Token);
internal sealed record ServerNowResult(double ServerNow) : IServerTimed;

internal sealed record RegisterArgs(string Token, DeviceInfo Device, string PublicKey, string? KeyId, double CreatedAt);
internal sealed record RegisterResult(DeviceId DeviceId, LibraryId LibraryId, string? KeyId, KeyStateKind KeyState, int? KeyRevision, double ServerNow) : IServerTimed;
internal sealed record UnregisterResult(bool Removed, bool? Cancelled, double ServerNow) : IServerTimed
{
    /// <summary>Whether the token's registration is settled for good: removed, or refused from now on.</summary>
    public bool Settled => Removed || Cancelled == true;
}
internal sealed record ClaimKeyArgs(string Token, string KeyId, int KeyRevision);
internal sealed record ClaimKeyResult(string KeyId, int? KeyRevision, double ServerNow) : IServerTimed;
internal sealed record RotateKeyResult(int? KeyRevision, double ServerNow) : IServerTimed;
internal sealed record GrantKeyArgs(string Token, DeviceId DeviceId, string KeyId, string Wrapped, string Commitment);
internal sealed record AcceptKeyArgs(string Token, string KeyId);
/// <summary><c>keys:release</c>: the nulls are sent as null (the server requires the fields).</summary>
internal sealed record ReleaseKeyArgs(
    string Token, string KeyId,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.Never)] string? AccountKeyId,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.Never)] string? RekeyKeyId,
    int KeyRevision);
internal sealed record RequestKeyArgs(string Token, string Commitment);
internal sealed record AnswerKeyArgs(string Token, DeviceId DeviceId, string Commitment, string Nonce);
internal sealed record RevealKeyArgs(string Token, string Commitment, string Nonce);
internal sealed record RotateWrap(DeviceId DeviceId, string Wrapped);
/// <summary>A re-sealed vault row; <c>sealed</c> is sent as null for a row the rotating device couldn't open.</summary>
internal sealed record RotateReseal(ProviderId Provider, int BaseRevision, [property: JsonIgnore(Condition = JsonIgnoreCondition.Never)] string? Sealed);
/// <summary>A settings row re-sealed under the new key at the time it was read; <c>value</c> null (sent as null) deletes it.</summary>
internal sealed record RotateSetting(string Key, double BaseUpdatedAt, [property: JsonIgnore(Condition = JsonIgnoreCondition.Never)] SealedContent? Value);
internal sealed record RotateKeyArgs(string Token, string FromKeyId, string KeyId, IReadOnlyList<RotateWrap> Wraps, IReadOnlyList<RotateReseal> Vault,
                                     IReadOnlyList<RotateSetting> Settings);
internal sealed record VaultPutArgs(string Token, ProviderId Provider, string Sealed, string KeyId, int BaseRevision);
internal sealed record VaultSignOutArgs(string Token, ProviderId Provider, int BaseRevision);
internal sealed record UpdatedResult(double UpdatedAt, double ServerNow) : IServerTimed;
internal sealed record VaultWriteResult(double UpdatedAt, int Revision, double ServerNow) : IServerTimed;
internal sealed record SettingPutArgs(string Token, string Key, SealedContent Value, string? WriteId, bool? IfAbsent);

/// <summary>The vault key wrapped to this device by another, waiting for it to open and accept it.</summary>
public sealed record KeyGrantRow(string KeyId, string Wrapped, DeviceId FromDeviceId, string? Commitment);
/// <summary>A rotated vault key wrapped to this device (a holder), made with the key it replaces.</summary>
public sealed record RekeyRow(string KeyId, string FromKeyId, string Wrapped, DeviceId FromDeviceId);

public sealed record DeviceListResult
{
    public required DeviceId SelfId { get; init; }
    public required LibraryId LibraryId { get; init; }
    public string? KeyId { get; init; }
    public bool? RotationNeeded { get; init; }
    /// <summary>The account's key revision: grows with every change to the key state. Absent from older servers (0).</summary>
    public int? KeyRevision { get; init; }
    public IReadOnlyList<SyncDevice> Devices { get; init; } = [];
    public KeyGrantRow? Grant { get; init; }
    public RekeyRow? Rekey { get; init; }
}

internal sealed record RenameArgs(string Token, DeviceId DeviceId, string Name);
internal sealed record DeviceArgs(string Token, DeviceId DeviceId);
/// <summary><c>playback:publish</c>. <see cref="Content"/>: what plays, sealed (<c>Replace</c>); none because this device has no
/// key (<c>Drop</c>, sent as null); or unchanged (<c>Keep</c>, left out).</summary>
[JsonConverter(typeof(PublishArgsConverter))]
internal sealed record PublishArgs(string Token, PlaybackAnchor Anchor, PublishContent Content);

internal abstract record PublishContent
{
    public sealed record Keep : PublishContent;
    public sealed record Drop : PublishContent;
    public sealed record Replace(SealedContent Playback, SealedContent Queue) : PublishContent;
}

internal sealed class PublishArgsConverter : JsonConverter<PublishArgs>
{
    public override PublishArgs Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        throw new NotSupportedException("PublishArgs is only sent");

    public override void Write(Utf8JsonWriter w, PublishArgs v, JsonSerializerOptions options)
    {
        w.WriteStartObject();
        w.WriteString("token", v.Token);
        w.WritePropertyName("anchor");
        JsonSerializer.Serialize(w, v.Anchor, options);
        switch (v.Content)
        {
            case PublishContent.Drop:
                w.WriteNull("content");
                break;
            case PublishContent.Replace r:
                w.WritePropertyName("content");
                w.WriteStartObject();
                w.WritePropertyName("playback");
                JsonSerializer.Serialize(w, r.Playback, options);
                w.WritePropertyName("queue");
                JsonSerializer.Serialize(w, r.Queue, options);
                w.WriteEndObject();
                break;
        }
        w.WriteEndObject();
    }
}
internal sealed record PublishResult(double ServerNow, double PositionAt, int QueueVersion) : IServerTimed;
/// <summary>A queue window, sealed (kind queue).</summary>
internal sealed record QueueResult(SealedContent Content, int Version);
internal sealed record SendCommandArgs(string Token, DeviceId ToDeviceId, WireCommand Command, string ClientId);
internal sealed record SendCommandResult(CommandId CommandId, double ExpiresAt, double ServerNow) : IServerTimed;
internal sealed record AckArgs(string Token, CommandId CommandId, WireResult Result);

// MARK: - Server clock

/// <summary>
/// Estimates the server clock from <c>serverNow</c> in mutation results. Each sample assumes the server stamped it halfway
/// through the round trip; the estimate uses the sample with the shortest round trip among the last 8.
/// </summary>
public sealed class ServerClock
{
    public readonly record struct Sample(double OffsetMs, double RoundTripMs);
    private readonly List<Sample> _samples = new();
    private readonly object _lock = new();
    public const int MaxSamples = 8;

    public IReadOnlyList<Sample> Samples { get { lock (_lock) return _samples.ToList(); } }

    /// <summary>server - local in ms; 0 until the first sample.</summary>
    public double OffsetMs { get { lock (_lock) return _samples.Count == 0 ? 0 : _samples.MinBy(s => s.RoundTripMs).OffsetMs; } }

    public bool HasSample { get { lock (_lock) return _samples.Count > 0; } }

    public void Record(double serverNow, DateTimeOffset sentAt, DateTimeOffset receivedAt)
    {
        var sent = sentAt.ToUnixTimeMilliseconds() + sentAt.Ticks % TimeSpan.TicksPerMillisecond / (double)TimeSpan.TicksPerMillisecond;
        var received = receivedAt.ToUnixTimeMilliseconds() + receivedAt.Ticks % TimeSpan.TicksPerMillisecond / (double)TimeSpan.TicksPerMillisecond;
        var roundTrip = Math.Max(0, received - sent);
        lock (_lock)
        {
            _samples.Add(new Sample(serverNow - (sent + received) / 2, roundTrip));
            if (_samples.Count > MaxSamples) _samples.RemoveRange(0, _samples.Count - MaxSamples);
        }
    }

    /// <summary>The server time now (ms).</summary>
    public double Now(DateTimeOffset? local = null)
    {
        var l = local ?? DateTimeOffset.UtcNow;
        return l.ToUnixTimeMilliseconds() + l.Ticks % TimeSpan.TicksPerMillisecond / (double)TimeSpan.TicksPerMillisecond + OffsetMs;
    }

    /// <summary>The local time of a server time.</summary>
    public DateTimeOffset LocalTime(double server) => DateTimeOffset.FromUnixTimeMilliseconds((long)(server - OffsetMs));
}
