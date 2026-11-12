import Foundation

public enum PlaybackState: String, Hashable, Sendable {
    case idle, loading, playing, paused, buffering, ended, failed
}

/// Events an engine reports to its owner (`PlayerController`).
public enum PlaybackEvent: Sendable {
    case state(PlaybackState)
    /// Periodic progress, at least every 0.5s while playing.
    case time(current: TimeInterval, duration: TimeInterval?)
    /// The current item played to the end on its own.
    case finished
    case failed(String)
}

/// Plays tracks for one provider.
///
/// `AVPlaybackEngine` (in OpenMusicCore) covers providers that can resolve a direct stream URL.
/// Providers that can't (Spotify) supply their own engine.
@MainActor
public protocol PlaybackEngine: AnyObject {
    /// Set by `PlayerController`. Engines call it on the main actor.
    var onEvent: (@MainActor (PlaybackEvent) -> Void)? { get set }

    /// Load and (optionally) start a track. Throws if the track can't be resolved.
    func load(_ track: Track, startAt: TimeInterval, autoplay: Bool) async throws
    func play()
    func pause()
    func stop()
    func seek(to seconds: TimeInterval)
    /// 0...1
    var volume: Float { get set }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval? { get }
    /// Hint for gapless playback / preloading. Engines may ignore it.
    func prepareNext(_ track: Track?)
}

/// A resolved, directly playable stream.
public struct PlayableStream: Sendable, Hashable {
    public var url: URL
    public var httpHeaders: [String: String]
    public var expiresAt: Date?
    /// Loudness normalization in dB if the provider reports it (YouTube `loudnessDb`).
    public var loudnessDB: Double?
    public var mimeType: String?
    public var bitrate: Int?
    /// The stream's length in seconds if the service reports it (YouTube `videoDetails.lengthSeconds`).
    /// It can differ from the catalog's when the service plays another cut of the song.
    public var duration: TimeInterval?

    public init(url: URL, httpHeaders: [String: String] = [:], expiresAt: Date? = nil, loudnessDB: Double? = nil, mimeType: String? = nil, bitrate: Int? = nil, duration: TimeInterval? = nil) {
        self.duration = duration
        self.url = url
        self.httpHeaders = httpHeaders
        self.expiresAt = expiresAt
        self.loudnessDB = loudnessDB
        self.mimeType = mimeType
        self.bitrate = bitrate
    }
}

/// Turns a track into a playable stream. Implemented by providers that use `AVPlaybackEngine`.
public protocol StreamResolver: Sendable {
    func resolveStream(for track: Track) async throws -> PlayableStream
    /// `forceRefresh: true` skips any cached stream and asks the service again. Recovery after a stream
    /// failed uses it, so a URL revoked before its nominal expiry isn't handed back.
    func resolveStream(for track: Track, forceRefresh: Bool) async throws -> PlayableStream
}

public extension StreamResolver {
    /// For resolvers without a cache.
    func resolveStream(for track: Track, forceRefresh: Bool) async throws -> PlayableStream {
        try await resolveStream(for: track)
    }
}
