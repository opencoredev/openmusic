import Foundation

public enum RepeatMode: String, CaseIterable, Sendable, Codable {
    case off, all, one
}

/// Where the music in the queue came from. Drives the "Playing from …" label.
public struct PlaybackContext: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case album, playlist, artist, radio, search, library, likedSongs, autoplay, other
    }

    public var kind: Kind
    /// Provider-native id of the album/playlist/artist, when there is one.
    public var id: String?
    public var title: String
    public var provider: ProviderID?

    public init(kind: Kind, id: String? = nil, title: String, provider: ProviderID? = nil) {
        self.kind = kind
        self.id = id
        self.title = title
        self.provider = provider
    }

    public static func album(_ album: Album) -> PlaybackContext {
        PlaybackContext(kind: .album, id: album.providerID, title: album.title, provider: album.provider)
    }

    public static func playlist(_ playlist: Playlist) -> PlaybackContext {
        PlaybackContext(kind: .playlist, id: playlist.providerID, title: playlist.title, provider: playlist.provider)
    }

    public static func artist(_ artist: Artist) -> PlaybackContext {
        PlaybackContext(kind: .artist, id: artist.providerID, title: artist.name, provider: artist.provider)
    }

    public static func radio(title: String, seedID: String? = nil, provider: ProviderID? = nil) -> PlaybackContext {
        PlaybackContext(kind: .radio, id: seedID, title: title, provider: provider)
    }

    public static let autoplay = PlaybackContext(kind: .autoplay, title: "Autoplay")

    /// "Playing from Discovery", "Playing from Daft Punk Radio", "Autoplay".
    public var label: String {
        switch kind {
        case .autoplay: "Autoplay"
        case .radio: title.hasSuffix("Radio") ? "Playing from \(title)" : "Playing from \(title) Radio"
        default: "Playing from \(title)"
        }
    }
}

/// One entry in the play queue. `uid` keeps duplicates of the same track distinct.
public struct QueueEntry: Identifiable, Hashable, Sendable, Codable {
    public var uid: UUID
    public var track: Track
    /// True when the entry was added by autoplay/radio rather than by the user.
    public var isAutoplay: Bool
    /// True when the user added it with Play Next / Add to Queue / insert, rather than it coming from the played context.
    /// User-queued entries are never shuffled, matching Apple Music's "Playing Next".
    public var isUserQueued: Bool
    /// The album/playlist/radio this entry came from.
    public var context: PlaybackContext?

    public var id: UUID { uid }

    public init(track: Track, isAutoplay: Bool = false, isUserQueued: Bool = false, context: PlaybackContext? = nil, uid: UUID = UUID()) {
        self.uid = uid
        self.track = track
        self.isAutoplay = isAutoplay
        self.isUserQueued = isUserQueued
        self.context = context
    }

    private enum CodingKeys: String, CodingKey { case uid, track, isAutoplay, isUserQueued, context }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uid = try c.decode(UUID.self, forKey: .uid)
        track = try c.decode(Track.self, forKey: .track)
        isAutoplay = try c.decodeIfPresent(Bool.self, forKey: .isAutoplay) ?? false
        isUserQueued = try c.decodeIfPresent(Bool.self, forKey: .isUserQueued) ?? false
        context = try c.decodeIfPresent(PlaybackContext.self, forKey: .context)
    }
}

/// A track the listener actually heard (30 s, or half its length if shorter).
public struct PlayedTrack: Hashable, Sendable, Codable, Identifiable {
    public var track: Track
    public var playedAt: Date
    public var context: PlaybackContext?

    public var id: String { "\(track.id)@\(playedAt.timeIntervalSince1970)" }

    public init(track: Track, playedAt: Date, context: PlaybackContext? = nil) {
        self.track = track
        self.playedAt = playedAt
        self.context = context
    }
}

public enum SleepTimer: Hashable, Sendable {
    case off
    /// Pause at this wall-clock time.
    case at(Date)
    /// Pause when the current track finishes.
    case endOfTrack

    public var isActive: Bool { self != .off }
}

/// Coarse change notifications for system integrations (Now Playing, persistence).
/// Not sent for every time tick; SwiftUI should observe `PlayerController` directly.
public enum PlayerChange: Hashable, Sendable {
    /// The current entry changed (or was loaded).
    case track
    /// `state` changed.
    case state
    /// Entries were added, removed or reordered, or shuffle/repeat changed.
    case queue
    /// The position jumped (seek, restore) or the duration became known.
    case timing
}

/// Everything needed to put the player back where it was. Written by `QueuePersistence`.
public struct PlayerSnapshot: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var queue: [QueueEntry]
    public var currentIndex: Int?
    public var position: TimeInterval
    public var shuffle: Bool
    public var repeatMode: RepeatMode
    /// Pre-shuffle order of the queue (uids), so unshuffle still works after a relaunch.
    public var originalOrder: [UUID]?
    public var recentlyPlayed: [PlayedTrack]
    public var savedAt: Date

    public init(
        queue: [QueueEntry],
        currentIndex: Int?,
        position: TimeInterval,
        shuffle: Bool,
        repeatMode: RepeatMode,
        originalOrder: [UUID]?,
        recentlyPlayed: [PlayedTrack],
        savedAt: Date
    ) {
        self.version = Self.currentVersion
        self.queue = queue
        self.currentIndex = currentIndex
        self.position = position
        self.shuffle = shuffle
        self.repeatMode = repeatMode
        self.originalOrder = originalOrder
        self.recentlyPlayed = recentlyPlayed
        self.savedAt = savedAt
    }
}

/// Optional engine features. `AVPlaybackEngine` implements all of them; engines that drive
/// another app (Spotify) don't conform and the controller skips them.
@MainActor
public protocol ConfigurableAudioEngine: PlaybackEngine {
    /// Apply `PlayableStream.loudnessDB` so tracks play at a similar level.
    var normalizationEnabled: Bool { get set }
    /// Seconds to overlap the end of a track with the start of the next one. 0 disables.
    var crossfadeDuration: TimeInterval { get set }
    /// CoreAudio device UID to play through, nil for the system default.
    var outputDeviceUID: String? { get set }
}

/// Optional engine feature: reporting a song's real length as soon as its stream is resolved, before it
/// plays. `AVPlaybackEngine` reports the length the service gives with the stream, both for the song it
/// loads and for the next one it prepares, so the queue can show it without another request.
@MainActor
public protocol DurationReportingEngine: PlaybackEngine {
    /// Set by `PlayerController`: the stream for the song with this `Track.id` is this many seconds long.
    var onDurationResolved: (@MainActor (_ trackID: String, _ seconds: TimeInterval) -> Void)? { get set }
}
