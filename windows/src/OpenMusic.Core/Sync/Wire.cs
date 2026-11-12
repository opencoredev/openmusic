using System.Text.Json;
using System.Text.Json.Serialization;
using OpenMusic.Core.Support;

namespace OpenMusic.Core.Sync;

// The sync backend's shared shapes (sync/convex/model.ts, docs/sync-design.md "Shared shapes"), ported from
// Sources/OpenMusicSync/Model/SyncModels.swift so OpenMusic.Sync and the app build against one definition. Field names match the
// wire exactly. Track, QueueEntry and PlaybackContext come from OpenMusic.Core.

/// <summary>The platform a device runs. One this build doesn't know (an app made after it) reads as <see cref="Unknown"/>,
/// shown as a generic computer, so a new kind of device in the list never breaks the app.</summary>
[JsonConverter(typeof(DevicePlatformJsonConverter))]
public enum DevicePlatform
{
    Mac,
    Ios,
    Windows,
    Android,
    Linux,
    /// <summary>Read only: never sent (the backend refuses it).</summary>
    Unknown,
}

public static class DevicePlatformExtensions
{
    /// <summary>Whether the app on it sets its own volume from a remote command (phones play at the system volume).</summary>
    public static bool TakesVolumeCommands(this DevicePlatform platform) =>
        platform is DevicePlatform.Mac or DevicePlatform.Windows or DevicePlatform.Linux;
}

public sealed class DevicePlatformJsonConverter : JsonConverter<DevicePlatform>
{
    public override DevicePlatform Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => reader.GetString() switch
    {
        "mac" => DevicePlatform.Mac,
        "ios" => DevicePlatform.Ios,
        "windows" => DevicePlatform.Windows,
        "android" => DevicePlatform.Android,
        "linux" => DevicePlatform.Linux,
        _ => DevicePlatform.Unknown,
    };

    public override void Write(Utf8JsonWriter writer, DevicePlatform value, JsonSerializerOptions options) => writer.WriteStringValue(value switch
    {
        DevicePlatform.Mac => "mac",
        DevicePlatform.Ios => "ios",
        DevicePlatform.Windows => "windows",
        DevicePlatform.Android => "android",
        DevicePlatform.Linux => "linux",
        _ => "unknown",
    });
}

/// <summary>What a device says about itself when it joins.</summary>
public sealed record DeviceInfo(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("platform")] DevicePlatform Platform,
    /// Hardware model identifier, e.g. "Mac16,10".
    [property: JsonPropertyName("model")] string Model,
    [property: JsonPropertyName("appVersion")] string AppVersion);

public static class SyncLimits
{
    public static readonly TimeSpan OnlineWindow = TimeSpan.FromSeconds(90);
    public const int QueueBefore = 20;
    public const int QueueAfter = 100;
    public static readonly TimeSpan CommandTtl = TimeSpan.FromSeconds(120);
    public static readonly TimeSpan InviteTtl = TimeSpan.FromSeconds(600);
    /// <summary>A paused device is suggested for "Continue from …" this long after it paused.</summary>
    public static readonly TimeSpan ContinueWindow = TimeSpan.FromMinutes(30);
}

/// <summary>Where playback is, as an anchor: <see cref="PositionMs"/> was true at server time <see cref="PositionAt"/>
/// (ms since 1970, the server clock).</summary>
public sealed record PlaybackAnchor
{
    [JsonPropertyName("positionMs")] public double PositionMs { get; init; }
    [JsonPropertyName("positionAt")] public double PositionAt { get; init; }
    [JsonPropertyName("isPlaying")] public bool IsPlaying { get; init; }
    [JsonPropertyName("rate")] public double Rate { get; init; } = 1;
    [JsonPropertyName("durationMs")] public double? DurationMs { get; init; }
    /// <summary>0…1</summary>
    [JsonPropertyName("volume")] public double Volume { get; init; }
    [JsonPropertyName("shuffle")] public bool Shuffle { get; init; }
    [JsonPropertyName("repeat")] public RepeatMode Repeat { get; init; }

    /// <summary>Live position in seconds at server time <paramref name="serverNow"/>, clamped to the track's length.</summary>
    public double Position(double serverNow)
    {
        var ms = PositionMs;
        if (IsPlaying) ms += Math.Max(0, serverNow - PositionAt) * Rate;
        if (DurationMs is > 0 and var d) ms = Math.Min(ms, d);
        return Math.Max(0, ms) / 1000;
    }
}

/// <summary>A queue window: up to 20 entries before the current one and 100 after it.</summary>
public sealed record QueueWindow
{
    [JsonPropertyName("entries")] public IReadOnlyList<QueueEntry> Entries { get => _entries; init => _entries = value ?? []; }
    private readonly IReadOnlyList<QueueEntry> _entries = [];
    [JsonPropertyName("index")] public int Index { get; init; }

    /// <summary>The window of <paramref name="queue"/> around <paramref name="current"/>, null when it isn't a valid index.</summary>
    public static QueueWindow? Around(IReadOnlyList<QueueEntry> queue, int? current)
    {
        if (current is not { } c || c < 0 || c >= queue.Count) return null;
        var start = Math.Max(0, c - SyncLimits.QueueBefore);
        var end = Math.Min(queue.Count, c + 1 + SyncLimits.QueueAfter);
        return new QueueWindow { Entries = queue.Skip(start).Take(end - start).ToArray(), Index = c - start };
    }

    [JsonIgnore] public QueueEntry Current => Entries[Index];

    public bool Equals(QueueWindow? o) => o is not null && Index == o.Index && Entries.SequenceEqual(o.Entries);
    public override int GetHashCode() => HashCode.Combine(Index, Entries.Count);
}

/// <summary>What <c>takeOver</c> carries: everything needed to continue playback elsewhere.</summary>
public sealed record HandoffState
{
    [JsonPropertyName("queue")] public IReadOnlyList<QueueEntry> Queue { get => _queue; init => _queue = value ?? []; }
    private readonly IReadOnlyList<QueueEntry> _queue = [];
    [JsonPropertyName("index")] public int Index { get; init; }
    [JsonPropertyName("anchor")] public required PlaybackAnchor Anchor { get; init; }

    public bool Equals(HandoffState? o) => o is not null && Index == o.Index && Anchor == o.Anchor && Queue.SequenceEqual(o.Queue);
    public override int GetHashCode() => HashCode.Combine(Index, Anchor, Queue.Count);
}

[JsonConverter(typeof(JsonStringEnumConverter<SyncCommandKind>))]
public enum SyncCommandKind
{
    [JsonStringEnumMemberName("play")] Play,
    [JsonStringEnumMemberName("pause")] Pause,
    [JsonStringEnumMemberName("toggle")] Toggle,
    [JsonStringEnumMemberName("next")] Next,
    [JsonStringEnumMemberName("previous")] Previous,
    [JsonStringEnumMemberName("stop")] Stop,
    [JsonStringEnumMemberName("seek")] Seek,
    [JsonStringEnumMemberName("setVolume")] SetVolume,
    [JsonStringEnumMemberName("takeOver")] TakeOver,
}

/// <summary>A remote command, discriminated by <c>kind</c>: <c>{"kind":"seek","positionMs":…}</c>,
/// <c>{"kind":"setVolume","volume":…}</c>, <c>{"kind":"takeOver","state":{…}}</c>.</summary>
[JsonConverter(typeof(SyncCommandJsonConverter))]
public sealed record SyncCommand(SyncCommandKind Kind, double? PositionMs = null, double? Volume = null, HandoffState? State = null)
{
    public static SyncCommand Play { get; } = new(SyncCommandKind.Play);
    public static SyncCommand Pause { get; } = new(SyncCommandKind.Pause);
    public static SyncCommand Toggle { get; } = new(SyncCommandKind.Toggle);
    public static SyncCommand Next { get; } = new(SyncCommandKind.Next);
    public static SyncCommand Previous { get; } = new(SyncCommandKind.Previous);
    public static SyncCommand Stop { get; } = new(SyncCommandKind.Stop);
    public static SyncCommand Seek(double positionMs) => new(SyncCommandKind.Seek, PositionMs: positionMs);
    public static SyncCommand SetVolumeTo(double volume) => new(SyncCommandKind.SetVolume, Volume: volume);
    public static SyncCommand TakeOver(HandoffState state) => new(SyncCommandKind.TakeOver, State: state);
}

/// <summary>Why a command failed, from a fixed list: the server takes no free text. A message with details (it may name a
/// song) travels sealed beside it, and only from a device holding the key.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<CommandFailure>))]
public enum CommandFailure
{
    [JsonStringEnumMemberName("expired")] Expired,
    [JsonStringEnumMemberName("unavailable")] Unavailable,
    [JsonStringEnumMemberName("nothingToPlay")] NothingToPlay,
    [JsonStringEnumMemberName("needsKey")] NeedsKey,
    [JsonStringEnumMemberName("unreadable")] Unreadable,
    [JsonStringEnumMemberName("providerUnavailable")] ProviderUnavailable,
    [JsonStringEnumMemberName("playbackFailed")] PlaybackFailed,
    [JsonStringEnumMemberName("failed")] Failed,
}

public static class CommandFailureExtensions
{
    /// <summary>What the sender shows when no sealed message came (the same words as the Swift apps').</summary>
    public static string Message(this CommandFailure reason, string device) => reason switch
    {
        CommandFailure.Expired => $"The command expired before it reached {device}.",
        CommandFailure.Unavailable => $"{device} can't run commands right now.",
        CommandFailure.NothingToPlay => $"Nothing is loaded on {device}.",
        CommandFailure.NeedsKey => $"{device} doesn't have your sign-in key yet. Allow it on a device that has your sign-ins, then try again.",
        CommandFailure.Unreadable => $"{device} couldn't open what this device sent. Try again in a moment.",
        CommandFailure.ProviderUnavailable => $"That service isn't signed in on {device}.",
        CommandFailure.PlaybackFailed => $"{device} couldn't play it.",
        _ => $"That didn't work on {device}.",
    };
}

/// <summary>What a command did. On the wire a failure is its <see cref="Reason"/> plus, from a device holding the key, its
/// <see cref="Message"/> sealed; never the message in the clear.</summary>
public sealed record CommandResult(
    [property: JsonPropertyName("ok")] bool Ok,
    [property: JsonPropertyName("message")] string? Message = null,
    [property: JsonPropertyName("reason")] CommandFailure? Reason = null)
{
    public static CommandResult Success { get; } = new(true);
    public static CommandResult Failure(CommandFailure reason, string? message = null) => new(false, message, reason);
    /// <summary>The failure reason (Failed when none was given); null on success.</summary>
    [JsonIgnore] public CommandFailure? EffectiveReason => Ok ? null : Reason ?? CommandFailure.Failed;
}

/// <summary>A synced setting (<c>settings:list</c>): JSON text per key, last write wins.</summary>
public sealed record SettingEntry(
    [property: JsonPropertyName("key")] string Key,
    [property: JsonPropertyName("value")] string Value,
    [property: JsonPropertyName("updatedAt")] double UpdatedAt,
    [property: JsonPropertyName("updatedBy")] string UpdatedBy,
    [property: JsonPropertyName("writeId")] string? WriteId = null);

/// <summary>Setting keys shared with the Swift apps (<c>SettingsSync.PlaybackKey</c>, <c>recentSearchesKey</c>).
/// Values are JSON text as Swift's JSONEncoder writes them: use <see cref="OpenMusicJson.EncodeSetting{T}"/>.</summary>
public static class SettingKeys
{
    public const string NormalizeVolume = "playback.normalizeVolume";
    public const string CrossfadeSeconds = "playback.crossfadeSeconds";
    public const string Autoplay = "playback.autoplay";
    public const string SleepTimerMinutes = "playback.sleepTimerMinutes";
    public const string RecentSearches = "search.recent";
}

internal sealed class SyncCommandJsonConverter : JsonConverter<SyncCommand>
{
    public override SyncCommand Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var root = doc.RootElement;
        var kindText = root.GetProperty("kind").GetString() ?? throw new JsonException("command kind");
        var kind = JsonSerializer.Deserialize($"\"{kindText}\"", OpenMusicJsonContext.Default.SyncCommandKind);
        return kind switch
        {
            SyncCommandKind.Seek => SyncCommand.Seek(root.GetProperty("positionMs").GetDouble()),
            SyncCommandKind.SetVolume => SyncCommand.SetVolumeTo(root.GetProperty("volume").GetDouble()),
            SyncCommandKind.TakeOver => SyncCommand.TakeOver(
                root.GetProperty("state").Deserialize(OpenMusicJsonContext.Default.HandoffState) ?? throw new JsonException("state")),
            _ => new SyncCommand(kind),
        };
    }

    public override void Write(Utf8JsonWriter writer, SyncCommand value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WritePropertyName("kind");
        JsonSerializer.Serialize(writer, value.Kind, OpenMusicJsonContext.Default.SyncCommandKind);
        switch (value.Kind)
        {
            case SyncCommandKind.Seek:
                writer.WriteNumber("positionMs", value.PositionMs ?? 0);
                break;
            case SyncCommandKind.SetVolume:
                writer.WriteNumber("volume", value.Volume ?? 0);
                break;
            case SyncCommandKind.TakeOver:
                writer.WritePropertyName("state");
                JsonSerializer.Serialize(writer, value.State!, OpenMusicJsonContext.Default.HandoffState);
                break;
        }
        writer.WriteEndObject();
    }
}
