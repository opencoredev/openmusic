import Foundation
import OpenMusicCore
import Testing
@testable import OpenMusic

/// One row per song, with its copies named: the row's "2×" and what VoiceOver reads, and the Remove item that says
/// how many copies it takes (single and multiple selection).
@MainActor
@Suite struct RepeatedSongTests {
    @Test func theRemoveItemNamesTheCopies() {
        #expect(TrackMenu.removeTitle(songs: 1, copies: 1) == "Remove from Playlist")
        #expect(TrackMenu.removeTitle(songs: 1, copies: 2) == "Remove Both Copies")
        #expect(TrackMenu.removeTitle(songs: 1, copies: 3) == "Remove All 3 Copies")
        // A selection: its copies in all, named only when some song repeats.
        #expect(TrackMenu.removeTitle(songs: 3, copies: 3) == "Remove from Playlist")
        #expect(TrackMenu.removeTitle(songs: 3, copies: 5) == "Remove All 5 Copies")
    }

    @Test func theMarkerReadsAsWords() {
        #expect(CopiesMarker.spoken(2) == "in this playlist twice")
        #expect(CopiesMarker.spoken(3) == "in this playlist 3 times")
    }

    /// The lyrics panel's long top fade comes on past 4 pt and goes under 1 pt: an offset wobbling between them keeps
    /// the state it had.
    @Test func theLyricsFadeHasHysteresis() {
        var on = false
        for offset: CGFloat in [0, 2, 3.9] { on = TopFadeBand(offset).scrolled(was: on) }
        #expect(!on, "under 4 pt from rest: still off")
        on = TopFadeBand(4.5).scrolled(was: on)
        #expect(on)
        for offset: CGFloat in [3, 1.5, 2.5, 1] { on = TopFadeBand(offset).scrolled(was: on) }
        #expect(on, "down to 1 pt: still on")
        on = TopFadeBand(0.5).scrolled(was: on)
        #expect(!on)
    }
}
