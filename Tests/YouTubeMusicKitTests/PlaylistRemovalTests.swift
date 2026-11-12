import Foundation
import OpenMusicCore
import Testing
@testable import YouTubeMusicKit

/// Remove from Playlist on YouTube Music takes a song entirely: one edit per entry (`setVideoId`) the playlist holds
/// for it, every copy, whichever row asked (a playlist page lists the song once).
@Suite struct PlaylistRemovalTests {
    private func entry(_ videoId: String, _ setId: String) -> Track {
        Track(providerID: videoId, provider: .youtubeMusic, title: videoId, extra: ["setVideoId": setId])
    }

    @Test func everyCopyOfEachSongIsRemoved() throws {
        let entries = [entry("a", "s1"), entry("b", "s2"), entry("a", "s3"), entry("c", "s4"), entry("a", "s5")]
        // The row (or a queue track without an entry id) names the song once.
        let row = Track(providerID: "a", provider: .youtubeMusic, title: "a", extra: ["setVideoId": "s1"])
        #expect(try YouTubeMusicProvider.removalEdits(for: [row], entries: entries)
                == [.remove(videoId: "a", setVideoId: "s1"), .remove(videoId: "a", setVideoId: "s3"), .remove(videoId: "a", setVideoId: "s5")])
        let fromQueue = Track(providerID: "c", provider: .youtubeMusic, title: "c")
        #expect(try YouTubeMusicProvider.removalEdits(for: [fromQueue, row], entries: entries).count == 4)
        // A song not in the playlist: nothing to remove.
        #expect(try YouTubeMusicProvider.removalEdits(for: [Track(providerID: "z", provider: .youtubeMusic, title: "z")], entries: entries).isEmpty)
    }

    /// A copy without an entry id can't be removed: the whole removal is refused before anything is written, rather
    /// than taking the other copies and saying every copy went. Songs whose copies all have ids are unaffected.
    @Test func aCopyWithoutAnEntryIDRefusesTheRemoval() throws {
        let missing = Track(providerID: "a", provider: .youtubeMusic, title: "a")
        let entries = [entry("a", "s1"), entry("b", "s2"), missing, entry("c", "s4")]
        #expect(throws: PlaylistEditError.unidentifiedCopies(1)) {
            try YouTubeMusicProvider.removalEdits(for: [Track(providerID: "a", provider: .youtubeMusic, title: "a")], entries: entries)
        }
        // Mixed: one song fully identified, one not; still refused as a whole.
        #expect(throws: PlaylistEditError.unidentifiedCopies(1)) {
            try YouTubeMusicProvider.removalEdits(for: [Track(providerID: "b", provider: .youtubeMusic, title: "b"),
                                                        Track(providerID: "a", provider: .youtubeMusic, title: "a")], entries: entries)
        }
        // The songs without a missing id go as before.
        #expect(try YouTubeMusicProvider.removalEdits(for: [Track(providerID: "b", provider: .youtubeMusic, title: "b"),
                                                            Track(providerID: "c", provider: .youtubeMusic, title: "c")], entries: entries)
                == [.remove(videoId: "b", setVideoId: "s2"), .remove(videoId: "c", setVideoId: "s4")])
    }
}
