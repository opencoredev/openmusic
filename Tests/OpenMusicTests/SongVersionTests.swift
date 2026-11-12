import Foundation
import OpenMusicCore
import Testing
@testable import OpenMusic

private func song(_ id: String, _ title: String = "You Need To Calm Down", artists: [String] = ["Taylor Swift"],
                  album: String? = nil, duration: TimeInterval? = nil, video: Bool = false) -> Track {
    Track(providerID: id, provider: .youtubeMusic, title: title, artists: artists.map { ArtistRef(name: $0) },
          album: album.map { AlbumRef(id: "MPREb_\($0)", title: $0) }, duration: duration,
          extra: ["musicVideoType": video ? "MUSIC_VIDEO_TYPE_OMV" : "MUSIC_VIDEO_TYPE_ATV"])
}

/// Top Results lists each recording once and says which version each one is.
@Suite struct TopResultsDuplicates {
    @Test func sameTitleArtistsAndLengthIsOneRecording() {
        let a = song("a", duration: 171), b = song("b", duration: 172.5)
        #expect(SongVersions.isSameRecording(a, b))
        #expect(SongVersions.consolidated([a, b]).map(\.providerID) == ["a"])
    }

    @Test func lengthsMoreThanTwoSecondsApartAreDifferentRecordings() {
        let a = song("a", duration: 171), b = song("b", duration: 174)
        #expect(!SongVersions.isSameRecording(a, b))
        #expect(SongVersions.consolidated([a, b]).count == 2)
    }

    @Test func aSongAndItsVideoStayApart() {
        let audio = song("audio", duration: 172), video = song("video", duration: 172, video: true)
        #expect(!SongVersions.isSameRecording(audio, video))
    }

    @Test func titleAndArtistsCompareWithoutCaseOrAccents() {
        let a = song("a", "Beyoncé Song", artists: ["Beyoncé"], duration: 200)
        let b = song("b", "beyonce song", artists: ["BEYONCE"], duration: 201)
        #expect(SongVersions.isSameRecording(a, b))
    }

    @Test func differentArtistsAreDifferentRecordings() {
        let a = song("a", artists: ["Taylor Swift"], duration: 172)
        let b = song("b", artists: ["Taylor Swift", "Someone"], duration: 172)
        #expect(!SongVersions.isSameRecording(a, b))
    }

    @Test func unknownLengthsStayApart() {
        let a = song("a", "Anti-Hero", album: "Midnights"), b = song("b", "Anti-Hero", album: "Midnights (3am Edition)")
        #expect(!SongVersions.isSameRecording(a, b))
        // A missing length may hide a different edit (a radio edit next to a seven-minute version).
        #expect(!SongVersions.isSameRecording(song("c", "Anti-Hero"), song("d", "Anti-Hero", duration: 200)))
        #expect(!SongVersions.isSameRecording(song("c", "Anti-Hero"), song("d", "Anti-Hero")))
    }

    @Test func keepsTheFirstCopyInPlace() {
        let list = [song("x", "Other", duration: 100), song("a", duration: 171), song("y", "Third", duration: 90), song("b", duration: 171)]
        #expect(SongVersions.consolidated(list).map(\.providerID) == ["x", "a", "y"])
    }

    @Test func detailLineNamesTheVersion() {
        // Top Results cards: kind and artist only (the length follows separately); the album is in the tooltip.
        #expect(SongVersions.detailLine(for: song("a", album: "Lover")) == "Song · Taylor Swift")
        #expect(SongVersions.detailLine(for: song("a")) == "Song · Taylor Swift")
        #expect(SongVersions.detailLine(for: song("v", album: "Lover", video: true)) == "Video · Taylor Swift")
        // The song grid's second line: the artist only.
        #expect(SongVersions.rowLine(for: song("v", video: true)) == "Video · Taylor Swift")
        #expect(SongVersions.rowLine(for: song("a", album: "Lover")) == "Taylor Swift")
        #expect(SongVersions.helpLine(for: song("a", album: "Lover")) == "You Need To Calm Down — Taylor Swift · Lover")
    }

    @Test func spotifyTracksAreSongs() {
        let t = Track(providerID: "s", provider: .spotify, title: "x")
        #expect(RecordingKind(t) == .song)
    }
}

/// The tooltip on a row whose listing is off by more than 10 s.
@MainActor
@Suite struct DurationNotes {
    @Test func noteText() {
        #expect(AppModel.durationNote(service: "YouTube Music", real: 406, listed: 346, onAlbum: true)
            == "YouTube Music plays a 6:46 version of this song (the album lists 5:46).")
        #expect(AppModel.durationNote(service: "YouTube Music", real: 406, listed: 346, onAlbum: false)
            == "YouTube Music plays a 6:46 version of this song (its listing says 5:46).")
    }

    @Test func modelShowsTheRealLengthOnceKnown() {
        let model = AppModel(environment: ["OPENMUSIC_MOCK": "1"])
        let t = song("hz", "Veridis Quo", artists: ["Daft Punk"], album: "Discovery", duration: 346)
        #expect(model.displayDuration(for: t) == 346)
        #expect(model.durationNote(for: t) == nil)
        model.player.knownLengths.learn(406, for: t.id)
        #expect(model.displayDuration(for: t) == 406)
        #expect(model.durationNote(for: t) == "YouTube Music plays a 6:46 version of this song (the album lists 5:46).")
    }
}

/// The search field's suggestion popover closes on navigation and stays closed until the text is edited.
@MainActor
@Suite struct SuggestionDismissal {
    func makeModel() -> AppModel {
        let model = AppModel(environment: ["OPENMUSIC_MOCK": "1"])
        model.clearRecentSearches()
        return model
    }

    @Test func typingKeepsSuggestionsOpen() {
        let model = makeModel()
        model.select(.home)
        model.searchText = "d"
        model.searchText = "da"
        #expect(model.isShowingSearchResults)
        #expect(!model.suggestionsDismissed)
    }

    @Test func openingAResultClosesThemAndKeepsTheQuery() {
        let model = makeModel()
        model.searchText = "daft punk"
        model.open(.album(.youtubeMusic, id: "album-1", preview: nil))
        #expect(model.suggestionsDismissed)
        #expect(model.searchText == "daft punk")
    }

    @Test func editingReopensThem() {
        let model = makeModel()
        model.searchText = "daft punk"
        model.submitSearch()
        #expect(model.suggestionsDismissed)
        model.searchText = "daft punk d"
        #expect(!model.suggestionsDismissed)
    }

    @Test func scopeBackAndSidebarCloseThem() {
        let model = makeModel()
        model.searchText = "taylor"
        model.searchScope = .albums
        #expect(model.suggestionsDismissed)

        model.searchText = "taylor s"
        #expect(!model.suggestionsDismissed)
        model.open(.artist(.youtubeMusic, id: "artist-1", preview: nil))
        model.goBack()
        model.searchText = "taylor sw"
        #expect(!model.suggestionsDismissed)
        model.goForward()
        #expect(model.suggestionsDismissed)

        model.searchText = "taylor swi"
        model.select(.home)
        #expect(model.suggestionsDismissed)
    }

    @Test func pickingACompletionClosesThem() {
        let model = makeModel()
        model.searchText = "daft"
        model.offeredSuggestions = SearchFieldSuggestions(queries: ["daft punk get lucky"])
        model.searchText = "daft punk get lucky"
        #expect(model.suggestionsDismissed)
    }
}
