import Foundation

public enum RemotePlayerState: String, Sendable, Hashable {
    case playing, paused, stopped
}

/// One reading of a remote Spotify player (Spotify.app or a Connect device).
public struct RemoteSample: Sendable, Hashable {
    public var state: RemotePlayerState
    /// `spotify:track:<id>` of what the player has loaded, nil when nothing is.
    public var trackURI: String?
    /// Seconds into the track.
    public var position: TimeInterval
    /// Track length in seconds, when known.
    public var duration: TimeInterval?
    /// Monotonic seconds when the sample was taken.
    public var timestamp: TimeInterval

    public init(state: RemotePlayerState, trackURI: String?, position: TimeInterval, duration: TimeInterval?, timestamp: TimeInterval) {
        self.state = state
        self.trackURI = trackURI
        self.position = position
        self.duration = duration
        self.timestamp = timestamp
    }
}

/// Decides, from successive samples, whether the track OpenMusic asked Spotify to play is still playing,
/// was paused, ended on its own, or was replaced by the user.
///
/// Spotify keeps going after our track ends (into its own queue or autoplay) or stops, so "the end" shows up as:
/// the loaded track changes, or the player stops/pauses back at 0, or the position jumps back (repeat-one),
/// in each case right after a sample that put us near the end of our track.
public struct EndOfTrackDetector: Sendable {
    public enum Verdict: Sendable, Hashable {
        /// Our track hasn't shown up yet (Spotify is still switching).
        case waiting
        case playing
        /// Paused or stopped partway through, by us or the user.
        case paused
        /// Our track played to its end.
        case finished
        /// Something else is playing that didn't follow on from the end of our track.
        case replaced
    }

    public private(set) var expectedURI: String
    public let expectedDuration: TimeInterval?
    /// How close (seconds) the projected position must be to the end for a change to count as "finished".
    public let endWindow: TimeInterval
    public private(set) var hasStarted = false
    public private(set) var last: RemoteSample?

    public init(expectedURI: String, expectedDuration: TimeInterval?, endWindow: TimeInterval = 2.5) {
        self.expectedURI = expectedURI
        self.expectedDuration = expectedDuration
        self.endWindow = endWindow
    }

    public mutating func ingest(_ sample: RemoteSample) -> Verdict {
        guard hasStarted, let last else {
            if sample.trackURI == expectedURI {
                hasStarted = true
                self.last = sample
                return sample.state == .playing ? .playing : .paused
            }
            // Track relinking: Spotify may play an equivalent track with another id in the listener's market.
            if let uri = sample.trackURI, sample.state == .playing, sample.position < 10,
               let expected = expectedDuration, let actual = sample.duration, abs(expected - actual) <= 2 {
                expectedURI = uri
                hasStarted = true
                self.last = sample
                return .playing
            }
            return .waiting
        }
        defer { self.last = sample }

        let wasNearEnd = Self.isNearEnd(last: last, now: sample.timestamp, fallbackDuration: expectedDuration, window: endWindow)
        guard sample.trackURI == expectedURI else {
            return wasNearEnd ? .finished : .replaced
        }
        switch sample.state {
        case .stopped:
            return wasNearEnd ? .finished : .paused
        case .paused:
            // Spotify rewinds to 0 and pauses when nothing follows. Paused anywhere else is a real pause.
            if wasNearEnd, sample.position < 1 { return .finished }
            return .paused
        case .playing:
            // Jumped back to the start right at the end: Spotify's repeat-one looped it.
            if wasNearEnd, sample.position + 5 < last.position { return .finished }
            return .playing
        }
    }

    /// Where `last` projects the playhead to be at `now`, compared against the end of the track.
    static func isNearEnd(last: RemoteSample, now: TimeInterval, fallbackDuration: TimeInterval?, window: TimeInterval) -> Bool {
        guard let duration = last.duration ?? fallbackDuration, duration > 0 else { return false }
        let elapsed = last.state == .playing ? max(0, now - last.timestamp) : 0
        return duration - (last.position + elapsed) <= window
    }

    /// Seconds until the next sample: `base` normally, faster near the end so Spotify's next track is cut quickly.
    public static func nextPollInterval(position: TimeInterval, duration: TimeInterval?, base: TimeInterval) -> TimeInterval {
        guard let duration, duration > 0 else { return base }
        let remaining = duration - position
        if remaining <= 1.5 { return 0.25 }
        // Land a sample shortly before the end instead of overshooting it by a whole interval.
        if remaining - base < 1.0 { return max(0.25, remaining - 1.0) }
        return base
    }
}
