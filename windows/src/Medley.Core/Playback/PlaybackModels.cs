using System.Text.Json.Serialization;
using Medley.Core.Support;

namespace Medley.Core;

// Port of Sources/MedleyCore/Playback/PlaybackModels.swift.

[JsonConverter(typeof(JsonStringEnumConverter<RepeatMode>))]
public enum RepeatMode
{
    [JsonStringEnumMemberName("off")] Off,
    [JsonStringEnumMemberName("all")] All,
    [JsonStringEnumMemberName("one")] One,
}

[JsonConverter(typeof(JsonStringEnumConverter<PlaybackContextKind>))]
public enum PlaybackContextKind
{
    [JsonStringEnumMemberName("album")] Album,
    [JsonStringEnumMemberName("playlist")] Playlist,
    [JsonStringEnumMemberName("artist")] Artist,
    [JsonStringEnumMemberName("radio")] Radio,
    [JsonStringEnumMemberName("search")] Search,
    [JsonStringEnumMemberName("library")] Library,
    [JsonStringEnumMemberName("likedSongs")] LikedSongs,
    [JsonStringEnumMemberName("autoplay")] Autoplay,
    [JsonStringEnumMemberName("other")] Other,
}

/// <summary>Where the music in the queue came from. Drives the "Playing from …" label.</summary>
public sealed record PlaybackContext
{
    [JsonPropertyName("kind")] public required PlaybackContextKind Kind { get; init; }
    /// <summary>Provider-native id of the album, playlist or artist, when there is one.</summary>
    [JsonPropertyName("id")] public string? Id { get; init; }
    [JsonPropertyName("title")] public required string Title { get; init; }
    [JsonPropertyName("provider")] public ProviderId? Provider { get; init; }

    public PlaybackContext() { }

    [System.Diagnostics.CodeAnalysis.SetsRequiredMembers]
    public PlaybackContext(PlaybackContextKind kind, string title, string? id = null, ProviderId? provider = null)
    {
        Kind = kind;
        Title = title;
        Id = id;
        Provider = provider;
    }

    public static PlaybackContext ForAlbum(Album album) => new(PlaybackContextKind.Album, album.Title, album.ProviderID, album.Provider);
    public static PlaybackContext ForPlaylist(Playlist p) => new(PlaybackContextKind.Playlist, p.Title, p.ProviderID, p.Provider);
    public static PlaybackContext ForArtist(Artist a) => new(PlaybackContextKind.Artist, a.Name, a.ProviderID, a.Provider);
    public static PlaybackContext Radio(string title, string? seedId = null, ProviderId? provider = null) =>
        new(PlaybackContextKind.Radio, title, seedId, provider);
    public static PlaybackContext Autoplay { get; } = new(PlaybackContextKind.Autoplay, "Autoplay");

    /// <summary>"Playing from Discovery", "Playing from Daft Punk Radio", "Autoplay".</summary>
    [JsonIgnore]
    public string Label => Kind switch
    {
        PlaybackContextKind.Autoplay => "Autoplay",
        PlaybackContextKind.Radio => Title.EndsWith("Radio", StringComparison.Ordinal) ? $"Playing from {Title}" : $"Playing from {Title} Radio",
        _ => $"Playing from {Title}",
    };
}

/// <summary>One entry in the play queue. <see cref="Uid"/> keeps duplicates of the same track distinct.</summary>
public sealed record QueueEntry
{
    [JsonPropertyName("uid")] [JsonRequired] public Guid Uid { get; init; }
    [JsonPropertyName("track")] public required Track Track { get; init; }
    /// <summary>True when autoplay or radio added the entry rather than the user.</summary>
    [JsonPropertyName("isAutoplay")] public bool IsAutoplay { get; init; }
    /// <summary>True when the user added it with Play Next, Add to Queue or insert. User-queued entries are never
    /// shuffled, matching Apple Music's "Playing Next".</summary>
    [JsonPropertyName("isUserQueued")] public bool IsUserQueued { get; init; }
    /// <summary>The album, playlist or radio this entry came from.</summary>
    [JsonPropertyName("context")] public PlaybackContext? Context { get; init; }

    public QueueEntry() { }

    [System.Diagnostics.CodeAnalysis.SetsRequiredMembers]
    public QueueEntry(Track track, bool isAutoplay = false, bool isUserQueued = false, PlaybackContext? context = null, Guid? uid = null)
    {
        Uid = uid ?? Guid.NewGuid();
        Track = track;
        IsAutoplay = isAutoplay;
        IsUserQueued = isUserQueued;
        Context = context;
    }
}

/// <summary>A track the listener actually heard (30 s, or half its length if shorter).</summary>
public sealed record PlayedTrack
{
    [JsonPropertyName("track")] public required Track Track { get; init; }
    /// <summary>Encoded as Swift's default <c>Date</c>: seconds since 2001-01-01.</summary>
    [JsonPropertyName("playedAt")] [JsonConverter(typeof(SwiftDateConverter))] public DateTimeOffset PlayedAt { get; init; }
    [JsonPropertyName("context")] public PlaybackContext? Context { get; init; }

    public PlayedTrack() { }

    [System.Diagnostics.CodeAnalysis.SetsRequiredMembers]
    public PlayedTrack(Track track, DateTimeOffset playedAt, PlaybackContext? context = null)
    {
        Track = track;
        PlayedAt = playedAt;
        Context = context;
    }

    [JsonIgnore] public string Id => $"{Track.Id}@{PlayedAt.ToUnixTimeMilliseconds() / 1000.0}";
}

public enum SleepTimerKind { Off, At, EndOfTrack }

public readonly record struct SleepTimer(SleepTimerKind Kind, DateTimeOffset? Deadline = null)
{
    public static SleepTimer Off => default;
    /// <summary>Pause when the current track finishes.</summary>
    public static SleepTimer EndOfTrack => new(SleepTimerKind.EndOfTrack);
    /// <summary>Pause at this wall-clock time.</summary>
    public static SleepTimer At(DateTimeOffset deadline) => new(SleepTimerKind.At, deadline);

    public bool IsActive => Kind != SleepTimerKind.Off;
}

/// <summary>Coarse change notifications for system integrations (media controls, persistence, sync). Not sent for every
/// time tick; UI binds to <see cref="PlayerController"/>'s property changes.</summary>
public enum PlayerChange
{
    /// <summary>The current entry changed (or was loaded).</summary>
    Track,
    /// <summary><see cref="PlayerController.State"/> changed.</summary>
    State,
    /// <summary>Entries were added, removed or reordered, or shuffle or repeat changed.</summary>
    Queue,
    /// <summary>The position jumped (seek, restore) or the duration became known.</summary>
    Timing,
}

/// <summary>Everything needed to put the player back where it was. Written by <see cref="QueueStore"/>; the same JSON as
/// the Swift app's queue.json.</summary>
public sealed record PlayerSnapshot
{
    public const int CurrentVersion = 1;

    [JsonPropertyName("version")] public int Version { get; init; } = CurrentVersion;
    [JsonPropertyName("queue")] public IReadOnlyList<QueueEntry> Queue { get => _queue; init => _queue = value ?? []; }
    private readonly IReadOnlyList<QueueEntry> _queue = [];
    [JsonPropertyName("currentIndex")] public int? CurrentIndex { get; init; }
    [JsonPropertyName("position")] public double Position { get; init; }
    [JsonPropertyName("shuffle")] public bool Shuffle { get; init; }
    [JsonPropertyName("repeatMode")] public RepeatMode RepeatMode { get; init; }
    /// <summary>Pre-shuffle order of the queue (uids), so unshuffle still works after a relaunch.</summary>
    [JsonPropertyName("originalOrder")] public IReadOnlyList<Guid>? OriginalOrder { get; init; }
    [JsonPropertyName("recentlyPlayed")] public IReadOnlyList<PlayedTrack> RecentlyPlayed { get => _recentlyPlayed; init => _recentlyPlayed = value ?? []; }
    private readonly IReadOnlyList<PlayedTrack> _recentlyPlayed = [];
    [JsonPropertyName("savedAt")] [JsonConverter(typeof(SwiftDateConverter))] public DateTimeOffset SavedAt { get; init; }

    public bool Equals(PlayerSnapshot? o) =>
        o is not null && Version == o.Version && Queue.SequenceEqual(o.Queue) && CurrentIndex == o.CurrentIndex
        && Position.Equals(o.Position) && Shuffle == o.Shuffle && RepeatMode == o.RepeatMode
        && Eq.SeqOrNull(OriginalOrder, o.OriginalOrder) && RecentlyPlayed.SequenceEqual(o.RecentlyPlayed) && SavedAt == o.SavedAt;

    public override int GetHashCode() => HashCode.Combine(Queue.Count, CurrentIndex, Position, SavedAt);
}
