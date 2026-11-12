import Foundation
import Observation

/// The real length of each song, learned from its stream (by `Track.id`), for rows anywhere in the app.
///
/// A service's listing can be wrong about a song: YouTube Music lists Veridis Quo at 5:46 on its album
/// while the video it links to plays for 6:46. Once a song's stream has said how long it is, album,
/// playlist, search and queue rows show that length, so no row contradicts the player.
///
/// Observation is per song: each id has its own small observable slot, so a row re-renders only when the
/// length of its own song is learned, never on the player's time ticks and never because another song
/// resolved. Lengths are learned only from streams, never from listings. Session only.
@MainActor
public final class KnownLengths {
    /// Beyond this a listed length and the real one are different recordings worth explaining.
    public nonisolated static let noteThreshold: TimeInterval = 10

    @Observable
    final class Slot {
        var seconds: TimeInterval?
        init() {}
    }

    private var slots: [String: Slot] = [:]

    public init() {}

    /// The stream length learned for `trackID`, nil until one is. Reading it in a view body makes that view
    /// follow this one song.
    public func length(for trackID: String) -> TimeInterval? {
        slot(trackID).seconds
    }

    /// Records the stream length for `trackID`. Repeats and sub-second jitter (a player item refining its
    /// length) don't count as a change, so they don't redraw anything.
    public func learn(_ seconds: TimeInterval, for trackID: String) {
        guard seconds.isFinite, seconds > 0 else { return }
        let slot = slot(trackID)
        if let known = slot.seconds, abs(known - seconds) < 0.5 { return }
        slot.seconds = seconds
    }

    /// The length a row should show for `track`: the listing's while the stream agrees with it (within
    /// `PlayerController.durationTolerance`) or hasn't been heard from, otherwise the stream's.
    public func displayDuration(for track: Track) -> TimeInterval? {
        PlayerController.reconciledDuration(catalog: track.duration, stream: length(for: track.id))
    }

    /// When the stream is more than `noteThreshold` away from the listing, the two lengths, for a tooltip
    /// such as "YouTube Music plays a 6:46 version of this song (the album lists 5:46)". nil otherwise.
    public func mismatch(for track: Track) -> (listed: TimeInterval, real: TimeInterval)? {
        guard let listed = track.duration, listed.isFinite, listed > 0,
              let real = length(for: track.id), abs(real - listed) > Self.noteThreshold else { return nil }
        return (listed, real)
    }

    private func slot(_ trackID: String) -> Slot {
        if let s = slots[trackID] { return s }
        let s = Slot()
        slots[trackID] = s
        return s
    }
}
