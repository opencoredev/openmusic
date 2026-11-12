import Foundation
import OpenMusicCore
import Testing
@testable import SpotifyKit

/// Routes requests to fixtures by path, like the real API would answer them.
@Sendable func fixtureRoutes(_ request: URLRequest, _ n: Int) -> FakeTransport.Reply {
    let path = request.url!.path
    let query = request.query
    switch (request.httpMethod ?? "GET", path) {
    case ("GET", "/v1/me"): return .json("me")
    case ("GET", "/v1/me/player/recently-played"): return .json("recently-played")
    case ("GET", "/v1/me/top/tracks"): return .json("top-tracks")
    case ("GET", "/v1/me/top/artists"): return .json("top-artists")
    case ("GET", "/v1/me/albums"): return .json("saved-albums")
    case ("GET", "/v1/me/tracks"): return .json("saved-tracks")
    case ("GET", "/v1/me/playlists"): return .json("my-playlists")
    case ("GET", "/v1/me/following"): return .json("followed-artists")
    case ("GET", "/v1/browse/new-releases"): return .json("error-not-found", status: 404) // removed in dev mode
    case ("GET", "/v1/search"):
        if query["q"] == "tag:new" { return .json("search-albums-tagnew") }
        if query["type"] == "track" { return .json("search-tracks") }
        return .json("search")
    case ("GET", "/v1/albums/4m2880jivSbbyEGAKfITCa"): return .json("album")
    case ("GET", "/v1/albums/4m2880jivSbbyEGAKfITCa/tracks"): return .json("album-tracks-page2")
    case ("GET", "/v1/artists/4tZwfgrHOc3mvqYlEYSvVi"): return .json("artist")
    case ("GET", "/v1/artists/4tZwfgrHOc3mvqYlEYSvVi/albums"):
        return query["include_groups"] == "single" ? .json("artist-singles") : .json("artist-albums")
    case ("GET", "/v1/playlists/3cEYpjA9oz9GiPac4AsH4n"): return .json("playlist-owned")
    case ("GET", "/v1/playlists/3cEYpjA9oz9GiPac4AsH4n/items"): return .json("playlist-items-page2")
    case ("GET", "/v1/playlists/37i9dQZF1DZ06evO1NpUHo"): return .json("playlist-other")
    case ("GET", "/v1/me/library/contains"): return .json("library-contains")
    case ("PUT", "/v1/me/library"), ("DELETE", "/v1/me/library"): return .status(200)
    case ("POST", "/v1/me/playlists"): return .json("created-playlist", status: 201)
    case ("POST", "/v1/playlists/3cEYpjA9oz9GiPac4AsH4n/items"): return .json("snapshot", status: 201)
    case ("DELETE", "/v1/playlists/3cEYpjA9oz9GiPac4AsH4n/items"): return .json("snapshot")
    case ("GET", "/v1/me/player/devices"): return .json("devices")
    case ("GET", "/v1/me/player"): return .json("player-state")
    case ("PUT", "/v1/me/player/play"), ("PUT", "/v1/me/player/pause"), ("PUT", "/v1/me/player/seek"),
         ("PUT", "/v1/me/player/volume"), ("PUT", "/v1/me/player"):
        return .status(204)
    default: return .json("error-not-found", status: 404)
    }
}

@Suite struct ServiceTests {
    @Test func homeComposesShelvesAndSkipsFailures() async throws {
        let (service, transport) = await makeService { request, n in
            if request.url?.path == "/v1/me/top/artists" { return .status(500) } // a broken section
            return fixtureRoutes(request, n)
        }
        let shelves = try await service.home()
        #expect(shelves.map(\.id) == ["recent", "jump-back", "top-tracks", "playlists", "saved-albums", "followed"])
        let recent = try #require(shelves.first)
        #expect(recent.style == .trackList)
        #expect(recent.items.count == 3) // 4 plays, one repeat
        #expect(recent.moreToken == "home:recent")
        #expect(shelves[1].items.count == 3) // distinct albums from recent plays

        // new-releases answered 404 once; it isn't asked again this session.
        _ = try await service.home()
        #expect(transport.requests(path: "/v1/browse/new-releases").count == 1)
    }

    @Test func homeSurfacesErrorWhenEverythingFails() async {
        let (service, _) = await makeService { _, _ in .raw(#"{"error":{"status":403,"message":"User not registered in the Developer Dashboard"}}"#, status: 403) }
        await #expect(throws: ProviderError.server(403, "User not registered in the Developer Dashboard")) { try await service.home() }
        #expect(SpotifyProvider.explain(ProviderError.server(403, "User not registered in the Developer Dashboard")).contains("User Management"))
    }

    @Test func exploreFallsBackToSearch() async throws {
        let (service, transport) = await makeService(fixtureRoutes)
        let shelves = try await service.explore()
        #expect(shelves.first?.id == "explore-new")
        #expect(shelves.first?.items.count == 2) // from `tag:new`
        #expect(shelves.contains { $0.id == "explore-genre-pop" })
        #expect(transport.requests(path: "/v1/search").allSatisfy { Int($0.query["limit"] ?? "99")! <= 10 })
    }

    @Test func shelfMoreTokens() async throws {
        let (service, _) = await makeService(fixtureRoutes)
        #expect(try await service.shelf(moreToken: "home:playlists").items.count == 3)
        #expect(try await service.shelf(moreToken: "home:followed").style == .artists)
        await #expect(throws: ProviderError.notFound) { try await service.shelf(moreToken: "nope") }
    }

    @Test func searchAll() async throws {
        let (service, transport) = await makeService(fixtureRoutes)
        let results = try await service.search("daft punk", scope: .all)
        #expect(results.top == .artist(results.artists[0]))
        #expect(results.tracks.count == 4)
        #expect(results.playlists.count == 2)
        let request = try #require(transport.requests(path: "/v1/search").first)
        #expect(request.query["type"] == "track,album,artist,playlist")
        #expect(request.query["limit"] == "10")
        #expect(request.query["q"] == "daft punk")
    }

    @Test func scopedSearchTakesTwoPages() async throws {
        let (service, transport) = await makeService(fixtureRoutes)
        let results = try await service.search("daft punk", scope: .songs)
        #expect(results.top == nil)
        #expect(Set(transport.requests(path: "/v1/search").map { $0.query["offset"] }) == ["0", "10"])
        #expect(Set(results.tracks.map(\.providerID)).count == results.tracks.count) // pages deduped
    }

    @Test func topResultHeuristic() {
        let artist = Artist(providerID: "a", provider: .spotify, name: "Daft Punk")
        let track = Track(providerID: "t", provider: .spotify, title: "One More Time")
        let album = Album(providerID: "al", provider: .spotify, title: "Discovery")
        #expect(SpotifyService.topResult(query: "DAFT PUNK", tracks: [track], albums: [album], artists: [artist], playlists: []) == .artist(artist))
        #expect(SpotifyService.topResult(query: "discovery", tracks: [track], albums: [album], artists: [artist], playlists: []) == .album(album))
        #expect(SpotifyService.topResult(query: "one more time", tracks: [track], albums: [album], artists: [artist], playlists: []) == .track(track))
        #expect(SpotifyService.topResult(query: "zzz", tracks: [track], albums: [album], artists: [artist], playlists: []) == .track(track))
        #expect(SpotifyService.topResult(query: "zzz", tracks: [], albums: [], artists: [], playlists: []) == nil)
    }

    @Test func albumFollowsTrackPages() async throws {
        let (service, transport) = await makeService(fixtureRoutes)
        let detail = try await service.album(id: "4m2880jivSbbyEGAKfITCa")
        #expect(detail.tracks.map(\.trackNumber) == [1, 2, 3, 5])
        #expect(detail.footnote?.hasPrefix("13 songs") == true)
        #expect(detail.footnote?.contains("℗ 2013 Daft Life Limited under exclusive license") == true)
        #expect(detail.moreByArtist.map(\.title) == ["Discovery", "Homework"]) // the album itself is excluded
        #expect(transport.requests(path: "/v1/albums/4m2880jivSbbyEGAKfITCa/tracks").count == 1)
    }

    @Test func artistPageWithoutTopTracksEndpoint() async throws {
        let (service, transport) = await makeService(fixtureRoutes)
        let detail = try await service.artist(id: "4tZwfgrHOc3mvqYlEYSvVi")
        // Built from an artist-filtered search; the cover by someone else is dropped.
        #expect(!detail.topTracks.isEmpty)
        #expect(detail.topTracks.allSatisfy { $0.artists.contains { $0.id == "4tZwfgrHOc3mvqYlEYSvVi" } })
        // Asked once (404 here, as in development mode), then the search stands in.
        #expect(transport.requests(path: "/v1/artists/4tZwfgrHOc3mvqYlEYSvVi/top-tracks").count == 1)
        #expect(transport.requests(path: "/v1/artists/4tZwfgrHOc3mvqYlEYSvVi/related-artists").count == 1)
        #expect(transport.requests(path: "/v1/search").first?.query["q"] == "artist:\"Daft Punk\"")
        #expect(detail.albums.count == 3)
        #expect(detail.singles.map(\.kind) == [.single, .ep])
        #expect(detail.isFollowed == true)
        #expect(detail.radioSeed == "artist:4tZwfgrHOc3mvqYlEYSvVi")
        #expect(detail.related.isEmpty)
        let contains = try #require(transport.requests(path: "/v1/me/library/contains").first)
        #expect(contains.query["uris"] == "spotify:artist:4tZwfgrHOc3mvqYlEYSvVi")
    }

    @Test func ownedPlaylistPaginates() async throws {
        let (service, _) = await makeService(fixtureRoutes)
        let detail = try await service.playlist(id: "3cEYpjA9oz9GiPac4AsH4n")
        #expect(detail.playlist.isEditable)
        #expect(detail.tracks.count == 1)
        let continuation = try #require(detail.continuation)
        let page = try await service.playlistTracks(continuation: continuation)
        #expect(page.items.map(\.title) == ["One More Time", "Harder, Better, Faster, Stronger"])
        #expect(page.continuation == nil)
    }

    /// Entries OpenMusic leaves out (a local file with no id, an episode, a `null`) still take their place: each song's
    /// position is the page's offset plus its index among every entry Spotify listed, so `[A, local, X, B, X]` puts X
    /// at 2 and 4 (Undo of a removal puts it back there), and the page reports every entry it listed.
    @Test func playlistPositionsCountEntriesLeftOut() async throws {
        func track(_ id: String) -> String {
            #"{"item": {"id": "\#(id)", "name": "\#(id.uppercased())", "type": "track", "uri": "spotify:track:\#(id)", "artists": [], "duration_ms": 1000}}"#
        }
        let local = #"{"is_local": true, "item": {"id": null, "name": "Demo", "type": "track", "uri": "spotify:local:x", "is_local": true}}"#
        let episode = #"{"item": {"id": "ep1", "name": "Show", "type": "episode", "uri": "spotify:episode:ep1"}}"#
        let first = #"{"id": "pl", "name": "Locals", "owner": {"id": "ada.listener"}, "items": {"offset": 0, "total": 8, "next": "https://api.spotify.com/v1/playlists/pl/items?offset=5&limit=5", "items": [\#(track("a")), \#(local), \#(track("x")), \#(track("b")), \#(track("x"))]}}"#
        let second = #"{"offset": 5, "total": 8, "next": null, "items": [\#(episode), null, \#(track("c"))]}"#
        let (service, _) = await makeService { request, _ in
            switch request.url?.path {
            case "/v1/playlists/pl": .raw(first)
            case "/v1/playlists/pl/items": .raw(second)
            default: .json("error-not-found", status: 404)
            }
        }
        let detail = try await service.playlist(id: "pl")
        #expect(detail.tracks.map(\.providerID) == ["a", "x", "b", "x"])
        #expect(detail.positions == [0, 2, 3, 4])
        #expect(detail.entryCount == 5)
        let page = try await service.playlistTracks(continuation: try #require(detail.continuation))
        #expect(page.items.map(\.providerID) == ["c"])
        #expect(page.positions == [7])
        #expect(page.entryCount == 3)
        // The local file and the episode keep their URIs, so a playlist edit can tell them apart; the `null` has none.
        #expect(detail.unlistedEntries == [1: "spotify:local:x"])
        #expect(page.unlistedEntries == [5: "spotify:episode:ep1"])
    }

    @Test func foreignPlaylistIsMetadataOnly() async throws {
        let (service, _) = await makeService(fixtureRoutes)
        let detail = try await service.playlist(id: "37i9dQZF1DZ06evO1NpUHo")
        #expect(detail.tracks.isEmpty)
        #expect(detail.continuation == nil)
        #expect(detail.playlist.extra["itemsUnavailable"] == "true")
    }

    @Test func libraryPages() async throws {
        let (service, transport) = await makeService(fixtureRoutes)
        let liked = try await service.library(.likedSongs, continuation: nil)
        #expect(liked.items.count == 2)
        let next = try #require(liked.continuation)
        _ = try await service.library(.likedSongs, continuation: next)
        #expect(transport.requests(path: "/v1/me/tracks").last?.query["offset"] == "50")

        let artists = try await service.library(.artists, continuation: nil)
        #expect(artists.continuation?.contains("after=") == true)
        #expect(try await service.library(.albums, continuation: nil).items.count == 1)
        #expect(try await service.library(.playlists, continuation: nil).items.count == 3)
        let recent = try await service.library(.recentlyPlayed, continuation: nil)
        #expect(recent.items.count == 4)
        #expect(recent.continuation?.contains("before=") == true)
    }

    @Test func libraryWritesUseMeLibrary() async throws {
        let (service, transport) = await makeService(fixtureRoutes)
        try await service.setInLibrary(["spotify:track:a", "spotify:album:b"], saved: true)
        try await service.setInLibrary(["spotify:playlist:c"], saved: false)
        let put = try #require(transport.requests.first { $0.httpMethod == "PUT" })
        #expect(put.url?.path == "/v1/me/library")
        #expect(put.query["uris"] == "spotify:track:a,spotify:album:b")
        let delete = try #require(transport.requests.first { $0.httpMethod == "DELETE" })
        #expect(delete.query["uris"] == "spotify:playlist:c")

        // 41 URIs → two requests (max 40 each).
        let many = (0..<41).map { "spotify:track:\($0)" }
        try await service.setInLibrary(many, saved: true)
        #expect(transport.requests.filter { $0.httpMethod == "PUT" }.count == 3)

        #expect(try await service.contains(["spotify:track:a", "spotify:track:b"]) == [true, false])
    }

    @Test func playlistEditing() async throws {
        let (service, transport) = await makeService(fixtureRoutes)
        let created = try await service.createPlaylist(title: "Road Trip", description: "Songs for the car")
        #expect(created.title == "Road Trip")
        #expect(created.isEditable)
        let create = try #require(transport.requests.first { $0.httpMethod == "POST" })
        #expect(create.url?.path == "/v1/me/playlists")
        #expect(create.jsonBody?["name"] as? String == "Road Trip")
        #expect(create.jsonBody?["public"] as? Bool == false)

        let uris = (0..<150).map { "spotify:track:\($0)" }
        try await service.add(uris, toPlaylist: "3cEYpjA9oz9GiPac4AsH4n")
        let adds = transport.requests(path: "/v1/playlists/3cEYpjA9oz9GiPac4AsH4n/items").filter { $0.httpMethod == "POST" }
        #expect(adds.map { ($0.jsonBody?["uris"] as? [String])?.count } == [100, 50])

        try await service.remove(["spotify:track:x", "spotify:track:x", "spotify:track:y"], fromPlaylist: "3cEYpjA9oz9GiPac4AsH4n")
        let remove = try #require(transport.requests.first { $0.httpMethod == "DELETE" })
        let items = remove.jsonBody?["items"] as? [[String: String]]
        #expect(items == [["uri": "spotify:track:x"], ["uri": "spotify:track:y"]])
        #expect(remove.jsonBody?["tracks"] == nil) // renamed to `items` in February 2026
    }

    @Test func connectCommands() async throws {
        let (service, transport) = await makeService(fixtureRoutes)
        try await service.startPlayback(uri: "spotify:track:a", positionMS: 1500, deviceID: "dev1")
        let play = try #require(transport.requests.first { $0.url?.path == "/v1/me/player/play" })
        #expect(play.httpMethod == "PUT")
        #expect(play.query["device_id"] == "dev1")
        #expect(play.jsonBody?["uris"] as? [String] == ["spotify:track:a"])
        #expect(play.jsonBody?["position_ms"] as? Int == 1500)

        try await service.seek(positionMS: 30_000, deviceID: nil)
        #expect(transport.requests(path: "/v1/me/player/seek").first?.query == ["position_ms": "30000"])
        try await service.setVolume(percent: 140, deviceID: nil)
        #expect(transport.requests(path: "/v1/me/player/volume").first?.query["volume_percent"] == "100")
        try await service.transfer(to: "dev2", play: true)
        let transfer = try #require(transport.requests.first { $0.url?.path == "/v1/me/player" && $0.httpMethod == "PUT" })
        #expect(transfer.jsonBody?["device_ids"] as? [String] == ["dev2"])

        let state = try #require(try await service.playbackState())
        #expect(state.is_playing)
    }

    @Test func noPlaybackIs204() async throws {
        let (service, _) = await makeService { _, _ in .status(204) }
        #expect(try await service.playbackState() == nil)
    }

    @Test func pickDevice() throws {
        let active = SpotifyDevice(id: "a", name: "Mac", type: "Computer", isActive: true)
        let idle = SpotifyDevice(id: "b", name: "Phone", type: "Smartphone", isActive: false)
        let restricted = SpotifyDevice(id: "c", name: "TV", type: "TV", isActive: false, isRestricted: true)
        #expect(try ConnectRoute.pickDevice([idle, active], preferred: nil) == "a")
        #expect(try ConnectRoute.pickDevice([idle, active], preferred: "b") == "b")
        #expect(try ConnectRoute.pickDevice([idle, active], preferred: "gone") == "a")
        #expect(try ConnectRoute.pickDevice([restricted, idle], preferred: "c") == "b")
        #expect(throws: ProviderError.self) { try ConnectRoute.pickDevice([restricted], preferred: nil) }
    }

    @Test func radioFromTrackIsSearchBuilt() async throws {
        let (service, transport) = await makeService(fixtureRoutes)
        let seed = Track(providerID: "69kOkLUCkxIZYexIgSG8rq", provider: .spotify, title: "Get Lucky",
                         artists: [ArtistRef(id: "4tZwfgrHOc3mvqYlEYSvVi", name: "Daft Punk")])
        let radio = try await service.radio(seed: seed)
        #expect(!radio.isEmpty)
        #expect(!radio.contains { $0.providerID == seed.providerID })
        #expect(Set(radio.map(\.providerID)).count == radio.count)
        #expect(transport.requests.allSatisfy { !$0.url!.path.contains("recommendations") })
        // Genre search used the artist's first genre.
        #expect(transport.requests(path: "/v1/search").contains { $0.query["q"] == "genre:\"french house\"" })
    }

    @Test func seedParsing() {
        #expect(SpotifyService.parseSeed("artist:abc") == ("artist", "abc"))
        #expect(SpotifyService.parseSeed("spotify:album:xyz") == ("album", "xyz"))
        #expect(SpotifyService.parseSeed("37i9dQZF1DZ06evO1NpUHo") == ("playlist", "37i9dQZF1DZ06evO1NpUHo"))
    }
}

@Suite struct RadioMixerTests {
    func track(_ id: String, _ title: String, _ artist: String, playable: Bool = true) -> Track {
        Track(providerID: id, provider: .spotify, title: title, artists: [ArtistRef(name: artist)], isPlayable: playable)
    }

    @Test func dedupesExcludesSeedAndSpreadsArtists() {
        let seed = track("s", "Seed", "A")
        let groupA = [track("s", "Seed", "A"), track("a1", "One", "A"), track("a2", "Two", "A"), track("a3", "One - 2011 Remaster", "A")]
        let groupB = [track("b1", "Uno", "B"), track("a1", "One", "A"), track("b2", "Dos", "B", playable: false)]
        var rng = SeededRNG(state: 42)
        let mix = RadioMixer.mix([groupA, groupB], excluding: seed, limit: 10, using: &rng)
        #expect(Set(mix.map(\.providerID)) == ["a1", "a2", "b1"]) // seed, duplicate id, remaster dupe, unplayable gone
        for (x, y) in zip(mix, mix.dropFirst()) where x.artists.first?.name == y.artists.first?.name {
            // Only allowed when nothing else was left.
            #expect(mix.last?.artists.first?.name == y.artists.first?.name)
        }
    }

    @Test func respectsLimitAndIsDeterministicPerSeed() {
        let tracks = (0..<50).map { track("t\($0)", "Song \($0)", "Artist \($0 % 5)") }
        var r1 = SeededRNG(state: 7), r2 = SeededRNG(state: 7)
        let a = RadioMixer.mix([tracks], excluding: nil, limit: 20, using: &r1)
        let b = RadioMixer.mix([tracks], excluding: nil, limit: 20, using: &r2)
        #expect(a.count == 20)
        #expect(a == b)
        #expect(a.map(\.providerID) != tracks.prefix(20).map(\.providerID)) // shuffled
    }
}
