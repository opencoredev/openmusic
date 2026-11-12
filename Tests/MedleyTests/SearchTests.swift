import Foundation
import MedleyCore
import Testing
@testable import Medley

/// A model on the offline sample catalog. Mock runs never read or write the real recent searches.
@MainActor
private func makeModel() -> AppModel {
    let model = AppModel(environment: ["MEDLEY_MOCK": "1"])
    model.clearRecentSearches()
    return model
}

private let sampleAlbum = Route.album(.youtubeMusic, id: "album-1", preview: nil)
private let sampleArtist = Route.artist(.youtubeMusic, id: "artist-1", preview: nil)

// MARK: - Search from any page

@MainActor
@Suite struct SearchNavigation {
    /// The judge's repro: search, open the artist, open an album, type a new query. The new results must show.
    @Test func newQueryFromPushedPageShowsResults() {
        let model = makeModel()
        model.searchText = "Daft Punk"
        #expect(model.isShowingSearchResults)
        model.open(sampleArtist)
        model.open(sampleAlbum)
        #expect(!model.isShowingSearchResults)

        model.searchText = "Taylor Swift"
        #expect(model.sidebarSelection == .search)
        #expect(model.path.isEmpty)
        #expect(model.isShowingSearchResults)
        #expect(!model.canGoForward)
    }

    /// Return with an unchanged query on a pushed page also brings the results back.
    @Test func submitFromPushedPageShowsResults() {
        let model = makeModel()
        model.searchText = "Daft Punk"
        model.open(sampleAlbum)
        model.submitSearch()
        #expect(model.isShowingSearchResults)
    }

    @Test func typingFromAnotherSidebarPageShowsResults() {
        let model = makeModel()
        model.select(.explore)
        model.open(sampleAlbum)
        model.searchText = "lofi"
        #expect(model.sidebarSelection == .search)
        #expect(model.path.isEmpty)
    }

    /// A search started away from the results page starts on Top Results; refining on the page keeps the scope.
    @Test func scopeResetsOnlyForSearchesStartedElsewhere() {
        let model = makeModel()
        model.searchText = "Daft"
        model.searchScope = .playlists
        model.searchText = "Daft Punk"
        #expect(model.searchScope == .playlists)

        model.open(sampleAlbum)
        model.searchText = "Kendrick"
        #expect(model.searchScope == .all)
    }

    /// Clearing the field or adding a trailing space never navigates.
    @Test func emptyOrWhitespaceEditsStay() {
        let model = makeModel()
        model.searchText = "Daft Punk"
        model.open(sampleAlbum)
        model.searchText = "Daft Punk "
        #expect(model.path == [sampleAlbum])
        model.searchText = ""
        #expect(model.path == [sampleAlbum])
    }

    /// Picking the direct artist suggestion opens the artist on top of that query's results.
    @Test func artistSuggestionOpensArtist() {
        let model = makeModel()
        let artist = Artist(providerID: "UCdp", provider: .youtubeMusic, name: "Daft Punk")
        model.searchText = "daft"
        model.offeredSuggestions = SearchFieldSuggestions(artist: artist, queries: ["daft punk"])
        model.open(sampleAlbum)

        model.searchText = SearchFieldSuggestions.completion(for: artist)
        #expect(model.searchText == "Daft Punk")
        #expect(model.sidebarSelection == .search)
        #expect(model.path == [.artist(.youtubeMusic, id: "UCdp", preview: artist)])
        #expect(model.recentSearches.first == "Daft Punk")
        // The field may report the pick as a submit too; the artist page stays.
        model.submitSearch()
        #expect(model.path.count == 1)
        model.goBack()
        #expect(model.isShowingSearchResults)
    }

    /// With Spotify signed out, "All services" searches only YouTube Music and offers one Connect link.
    @Test func signedOutServicesAreSkipped() async {
        let model = makeModel()
        #expect(model.searchProviders.map(\.id) == [.youtubeMusic, .spotify])
        await model.provider(.spotify)?.signOut()
        #expect(model.searchProviders.map(\.id) == [.youtubeMusic])
        #expect(model.searchProvidersNeedingSignIn.map(\.id) == [.spotify])
        #expect(model.searchKey(for: "x").services == [.youtubeMusic])
    }
}

// MARK: - Recent searches

@MainActor
@Suite struct RecentSearches {
    @Test func submitRecords() {
        let model = makeModel()
        model.searchText = "Daft Punk"
        #expect(model.recentSearches.isEmpty)
        model.submitSearch()
        #expect(model.recentSearches == ["Daft Punk"])
        model.searchText = "daft punk"
        model.submitSearch()
        #expect(model.recentSearches == ["daft punk"])
    }

    @Test func pickingACompletionRecords() {
        let model = makeModel()
        model.searchText = "daft"
        model.offeredSuggestions = SearchFieldSuggestions(queries: ["daft punk get lucky", "daft punk"])
        model.searchText = "daft punk get lucky"
        #expect(model.recentSearches == ["daft punk get lucky"])
    }

    /// Typing the last letter of a completion is typing, not picking.
    @Test func typingDoesNotRecord() {
        let model = makeModel()
        model.searchText = "daft pun"
        model.offeredSuggestions = SearchFieldSuggestions(queries: ["daft punk"])
        model.searchText = "daft punk"
        #expect(model.recentSearches.isEmpty)
    }

    /// Opening or playing a result remembers the query even without Return.
    @Test func usingAResultRecords() {
        let model = makeModel()
        model.searchText = "lofi"
        #expect(model.recentSearches.isEmpty)
        model.searchResultUsed()
        #expect(model.recentSearches == ["lofi"])
    }

    @Test func clearEmpties() {
        let model = makeModel()
        model.searchText = "a"
        model.submitSearch()
        model.clearRecentSearches()
        #expect(model.recentSearches.isEmpty)
    }
}

// MARK: - Results by key

/// Fetches that finish only when the test says so, to force answers to arrive out of order.
@MainActor
private final class Gates {
    var pending: [SearchKey: CheckedContinuation<Void, Never>] = [:]
    var calls: [SearchKey] = []

    func fetch(_ key: SearchKey) async -> SearchResultsStore.Results {
        calls.append(key)
        await withCheckedContinuation { pending[key] = $0 }
        let track = Track(providerID: "\(key.query)-\(key.scope.rawValue)", provider: .youtubeMusic, title: key.query)
        return [ProviderResult(provider: .youtubeMusic, value: SearchResults(tracks: [track]), error: nil)]
    }

    func waitFor(_ key: SearchKey) async {
        while pending[key] == nil { await Task.yield() }
    }

    func release(_ key: SearchKey) {
        pending.removeValue(forKey: key)?.resume()
    }
}

@MainActor
@Suite struct SearchResultsByKey {
    private func key(_ q: String, _ scope: SearchScope = .all, _ services: [ProviderID] = [.youtubeMusic]) -> SearchKey {
        SearchKey(query: q, scope: scope, services: services)
    }

    @Test func keyIgnoresCaseAndOuterSpaces() {
        #expect(key(" Daft Punk ") == key("daft punk"))
        #expect(key("daft punk", .songs) != key("daft punk"))
        #expect(key("daft punk", .all, [.youtubeMusic, .spotify]) != key("daft punk"))
    }

    /// An answer for an older query that arrives after the newer one is dropped.
    @Test func lateAnswerForOlderQueryIsDropped() async {
        let gates = Gates()
        let store = SearchResultsStore(cache: PageCache(), debounce: .zero) { await gates.fetch($0) }
        let a = key("taylor swift"), b = key("kendrick lamar")

        let first = Task { await store.load(a) }
        await gates.waitFor(a)
        let second = Task { await store.load(b) }
        await gates.waitFor(b)
        #expect(store.results(for: b) == nil) // skeleton, not Taylor Swift's rows

        gates.release(b)
        await second.value
        gates.release(a)
        await first.value

        #expect(store.key == b)
        #expect(store.results(for: a) == nil)
        #expect(store.results(for: b)?.first?.value?.tracks.first?.title == "kendrick lamar")
    }

    /// A refresh of the same key wins over the original request, even when the original answers last.
    @Test func olderLoadOfSameKeyIsDropped() async {
        @MainActor final class Ordered {
            var waiting: [CheckedContinuation<Void, Never>] = []
            var count = 0
            func fetch(_ key: SearchKey) async -> SearchResultsStore.Results {
                count += 1
                let n = count
                await withCheckedContinuation { waiting.append($0) }
                let track = Track(providerID: "t\(n)", provider: .youtubeMusic, title: "load \(n)")
                return [ProviderResult(provider: .youtubeMusic, value: SearchResults(tracks: [track]), error: nil)]
            }
        }
        let gates = Ordered()
        let store = SearchResultsStore(cache: PageCache(), debounce: .zero) { await gates.fetch($0) }
        let a = key("daft punk")

        let first = Task { await store.load(a) }
        while gates.waiting.count < 1 { await Task.yield() }
        let refresh = Task { await store.load(a, force: true) }
        while gates.waiting.count < 2 { await Task.yield() }

        gates.waiting[1].resume()
        await refresh.value
        gates.waiting[0].resume()
        await first.value

        #expect(store.results(for: a)?.first?.value?.tracks.map(\.title) == ["load 2"])
    }

    /// Switching scope or service shows nothing from the previous key while the new one loads.
    @Test func scopeAndServiceChangesNeverShowOldRows() async {
        let gates = Gates()
        let store = SearchResultsStore(cache: PageCache(), debounce: .zero) { await gates.fetch($0) }
        let all = key("lofi"), songs = key("lofi", .songs), both = key("lofi", .songs, [.youtubeMusic, .spotify])

        let t1 = Task { await store.load(all) }
        await gates.waitFor(all)
        gates.release(all)
        await t1.value
        #expect(store.results(for: all) != nil)

        let t2 = Task { await store.load(songs) }
        await gates.waitFor(songs)
        #expect(store.results(for: songs) == nil)
        #expect(store.results(for: all) == nil)

        let t3 = Task { await store.load(both) }
        await gates.waitFor(both)
        #expect(store.results(for: both) == nil)
        gates.release(songs)
        await t2.value
        // t2's answer belongs to `songs`, which is no longer current.
        #expect(store.key == both)
        #expect(store.results(for: both) == nil)
        gates.release(both)
        await t3.value
        #expect(store.results(for: both) != nil)
    }

    /// Coming back to a key that already loaded shows the cached rows without asking again.
    @Test func cachedKeyShowsInstantly() async {
        let gates = Gates()
        let store = SearchResultsStore(cache: PageCache(), debounce: .zero) { await gates.fetch($0) }
        let a = key("daft punk"), b = key("air")
        let t1 = Task { await store.load(a) }
        await gates.waitFor(a); gates.release(a); await t1.value
        let t2 = Task { await store.load(b) }
        await gates.waitFor(b); gates.release(b); await t2.value

        await store.load(a)
        #expect(store.results(for: a) != nil)
        #expect(gates.calls.count == 2)
    }

    /// A fuller answer for the same key keeps the rows on screen in place and adds new ones after them.
    @Test func sameKeyReloadKeepsOrder() {
        func track(_ id: String, album: String? = nil) -> Track {
            Track(providerID: id, provider: .youtubeMusic, title: id, album: album.map { AlbumRef(id: $0, title: $0) })
        }
        let old = [ProviderResult(provider: .youtubeMusic, value: SearchResults(tracks: [track("a"), track("b"), track("c")]), error: nil)]
        let fresh = [ProviderResult(provider: .youtubeMusic, value: SearchResults(tracks: [track("d"), track("c", album: "x"), track("a")]), error: nil)]
        let merged = SearchResultsStore.stabilized(fresh, keeping: old)
        let tracks = merged.first?.value?.tracks ?? []
        #expect(tracks.map(\.providerID) == ["a", "c", "d"])
        #expect(tracks[1].album?.id == "x")
    }
}

// MARK: - Artists and suggestions

@MainActor
@Suite struct ArtistMatching {
    @Test func splitsNamedFromRelated() {
        func artist(_ name: String) -> Artist { Artist(providerID: name, provider: .youtubeMusic, name: name) }
        let split = ArtistMatch.split([artist("Taylor Swift"), artist("Sabrina Carpenter"), artist("Taylor Swift Piano Covers"), artist("Ed Sheeran")], query: "taylor swift")
        #expect(split.matches.map(\.name) == ["Taylor Swift", "Taylor Swift Piano Covers"])
        #expect(split.related.map(\.name) == ["Sabrina Carpenter", "Ed Sheeran"])
        #expect(ArtistMatch.matches("Beyoncé", query: "beyonce"))
        #expect(ArtistMatch.matches("Daft Punk", query: "daft"))
        #expect(!ArtistMatch.matches("SZA", query: "kendrick lamar"))
    }

    @Test func suggestionsPutTheMatchingArtistFirst() {
        let daft = Artist(providerID: "UCdp", provider: .youtubeMusic, name: "Daft Punk")
        let song = Track(providerID: "v", provider: .youtubeMusic, title: "One More Time")
        let lists = [SearchSuggestions(queries: ["daft", "daft punk", "Daft Punk"], items: [.track(song), .artist(daft)])]
        let s = SearchFieldSuggestions.make(query: "daft", from: lists)
        #expect(s.artist == daft)
        #expect(s.queries == ["daft punk"])
        #expect(SearchFieldSuggestions.make(query: "one more time", from: lists).artist == nil)
    }
}

@MainActor
@Suite struct AlbumRankingTests {
    func album(_ title: String, _ artists: [ArtistRef]) -> Album {
        Album(providerID: title, provider: .youtubeMusic, title: title, artists: artists)
    }

    @Test func putsTheArtistsOwnReleasesFirstWithoutDroppingAny() {
        let daft = ArtistRef(id: "UCdp", name: "Daft Punk")
        let albums = [
            album("Random Access Memories", [daft]),
            album("Daft Punk Is Playing at My House", [ArtistRef(name: "LCD Soundsystem")]),
            album("Discovery", [daft]),
            album("Daft Punk (Tribute)", [ArtistRef(name: "Daft Punk Tribute Band")]),
            album("Random Access Memories (Drumless Edition)", [ArtistRef(name: "Daft Punk")]),
            album("Get Lucky", [daft, ArtistRef(name: "Pharrell Williams")]),
        ]
        let split = AlbumRanking.split(albums, query: "daft punk")
        #expect(split.byArtist.map(\.title) == ["Random Access Memories", "Discovery", "Random Access Memories (Drumless Edition)", "Get Lucky"])
        #expect(split.others.map(\.title) == ["Daft Punk Is Playing at My House", "Daft Punk (Tribute)"])
    }

    @Test func anExactArtistBeatsAPrefixMatch() {
        let daft = Artist(providerID: "UCdp", provider: .youtubeMusic, name: "Daft Punk")
        let tribute = Artist(providerID: "UCtb", provider: .youtubeMusic, name: "Daft Punk Tribute Band")
        let albums = [album("Tribute", [ArtistRef(id: "UCtb", name: "Daft Punk Tribute Band")]), album("Discovery", [ArtistRef(id: "UCdp", name: "Daft Punk")])]
        let split = AlbumRanking.split(albums, query: "daft punk", artists: [tribute, daft])
        #expect(split.byArtist.map(\.title) == ["Discovery"])
        #expect(split.others.map(\.title) == ["Tribute"])
    }

    @Test func usesTheMatchedArtistForAPartialQuery() {
        let daft = Artist(providerID: "UCdp", provider: .youtubeMusic, name: "Daft Punk")
        let albums = [album("Alive 2007", [ArtistRef(id: "UCdp", name: "Daft Punk")]), album("Daft Hands", [ArtistRef(name: "Other")])]
        let split = AlbumRanking.split(albums, query: "daft", artists: [daft])
        #expect(split.byArtist.map(\.title) == ["Alive 2007"])
        #expect(split.others.map(\.title) == ["Daft Hands"])
        // No artist named like the query: nothing is promoted, the order stays.
        #expect(AlbumRanking.split(albums, query: "hands").byArtist.isEmpty)
    }
}

@MainActor
@Suite struct AlbumFootnoteTests {
    @Test func dropsTheCatalogTotalTheHeaderAlreadyShows() {
        #expect(AlbumFootnote.cleaned("14 songs • 1 hour, 1 minute · 2001") == nil)
        #expect(AlbumFootnote.cleaned("1 song • 4 minutes, 35 seconds · 2024") == nil)
        #expect(AlbumFootnote.cleaned("March 12, 2001\n14 songs, 61 minutes\n℗ 2001 Daft Life") == "March 12, 2001\n℗ 2001 Daft Life")
        #expect(AlbumFootnote.cleaned(nil) == nil)
    }
}
