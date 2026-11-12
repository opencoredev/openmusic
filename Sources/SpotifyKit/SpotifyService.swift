import Foundation
import MedleyCore

/// Everything Medley asks of the Spotify Web API, mapped to Medley models.
///
/// Written against the API as it stands for development-mode apps after the February 2026 changes:
/// - No `/browse/*`, `/artists/{id}/top-tracks`, recommendations, or related artists. Clients outside development
///   mode (the built-in client) may still have them, so `/browse/new-releases`, top tracks and related artists are
///   tried once per session and dropped on 403/404/410. Without them, artist top songs come from an artist-filtered
///   search and new releases from `tag:new`; radio is always built from searches.
/// - Library writes go through `PUT/DELETE /me/library?uris=…`, checks through `/me/library/contains`.
/// - Playlist tracks are `/playlists/{id}/items`, readable only for playlists the user owns or collaborates on.
/// - Search returns at most 10 items per type per page.
///
/// All methods run off the main actor (`@concurrent`).
public struct SpotifyService: Sendable {
    public let api: SpotifyAPI

    public init(api: SpotifyAPI) {
        self.api = api
    }

    static let searchPageSize = 10
    static let pageSize = 50
    static let homeShelfSize = 20
    static let explorerGenres = ["pop", "hip-hop", "rock", "electronic", "indie", "r&b"]

    // MARK: Account

    /// Whose token this is: an owner check (restore, a bound write learning its user, the sign-in transfer's checks), so
    /// always uncached (`HTTP.uncachedSession`: no HTTP cache, no cookies, none of the API's own cache).
    @concurrent
    public func me() async throws -> AccountInfo {
        let generation = await api.sessionGeneration
        let user: SP.User = try await api.get("me", uncached: true)
        await api.setUserID(user.id, session: generation)
        return SpotifyMapping.account(user)
    }

    private func userID() async -> String? {
        if let id = await api.userID { return id }
        return try? await (api.get("me", ttl: 300) as SP.User).id
    }

    // MARK: Home & explore

    @concurrent
    public func home() async throws -> [Shelf] {
        let me = await userID()
        let n = Self.homeShelfSize
        async let recent = attempt { try await recentlyPlayed(limit: 50) }
        async let topTracks = attempt { try await topTracks(limit: n) }
        async let topArtists = attempt { try await topArtists(limit: n) }
        async let albums = attempt { try await savedAlbums(limit: n, next: nil).items }
        async let playlists = attempt { try await myPlaylists(limit: n, next: nil, userID: me).items }
        async let followed = attempt { try await followedArtists(limit: n, next: nil).items }
        async let releases = attempt { try await newReleases(limit: n) }

        var shelves: [Shelf] = []
        let recentTracks = await recent ?? []
        if !recentTracks.isEmpty {
            shelves.append(Shelf(id: "recent", title: "Recently Played", style: .trackList,
                                 items: Array(Self.dedupe(recentTracks).prefix(n)).map(MediaItem.track), moreToken: "home:recent"))
            let jumpBack = Self.albumsFromTracks(recentTracks)
            if jumpBack.count >= 3 {
                shelves.append(Shelf(id: "jump-back", title: "Jump Back In", style: .carousel, items: jumpBack.map(MediaItem.album)))
            }
        }
        if let items = await topTracks, !items.isEmpty {
            shelves.append(Shelf(id: "top-tracks", title: "Your Top Songs", subtitle: "Last 4 weeks", style: .trackList,
                                 items: items.map(MediaItem.track), moreToken: "home:top-tracks"))
        }
        if let items = await playlists, !items.isEmpty {
            shelves.append(Shelf(id: "playlists", title: "Your Playlists", style: .carousel, items: items.map(MediaItem.playlist), moreToken: "home:playlists"))
        }
        if let items = await topArtists, !items.isEmpty {
            shelves.append(Shelf(id: "top-artists", title: "Your Top Artists", style: .artists, items: items.map(MediaItem.artist), moreToken: "home:top-artists"))
        }
        if let items = await albums, !items.isEmpty {
            shelves.append(Shelf(id: "saved-albums", title: "Your Albums", style: .carousel, items: items.map(MediaItem.album), moreToken: "home:saved-albums"))
        }
        if let items = (await releases) ?? nil, !items.isEmpty {
            shelves.append(Shelf(id: "new-releases", title: "New Releases", style: .carousel, items: items.map(MediaItem.album), moreToken: "explore:new"))
        }
        if let items = await followed, !items.isEmpty {
            shelves.append(Shelf(id: "followed", title: "Artists You Follow", style: .artists, items: items.map(MediaItem.artist), moreToken: "home:followed"))
        }
        if shelves.isEmpty {
            // Every section failed or was empty. Surface the real error (403 "user not registered", offline, …)
            // instead of a blank page; a brand-new account with no history gets an empty page.
            _ = try await recentlyPlayed(limit: 1)
        }
        return shelves
    }

    @concurrent
    public func explore() async throws -> [Shelf] {
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        async let releases = attempt { try await newReleasesOrSearch(pages: 2) }
        async let fresh = attempt { try await searchTracks("year:\(year)", pages: 2) }
        let genres = await withTaskGroup(of: (Int, [Track]?).self) { group in
            for (index, genre) in Self.explorerGenres.enumerated() {
                group.addTask { (index, await attempt { try await searchTracks("genre:\"\(genre)\" year:\(year - 1)-\(year)", pages: 1) }) }
            }
            var out: [(Int, [Track])] = []
            for await (index, tracks) in group { if let tracks, !tracks.isEmpty { out.append((index, tracks)) } }
            return out.sorted { $0.0 < $1.0 }
        }

        var shelves: [Shelf] = []
        if let albums = await releases, !albums.isEmpty {
            shelves.append(Shelf(id: "explore-new", title: "New Releases", style: .carousel, items: albums.map(MediaItem.album), moreToken: "explore:new"))
        }
        if let tracks = await fresh, !tracks.isEmpty {
            shelves.append(Shelf(id: "explore-fresh", title: "Popular in \(year)", style: .trackList, items: tracks.map(MediaItem.track), moreToken: "explore:year:\(year)"))
        }
        for (index, tracks) in genres {
            let genre = Self.explorerGenres[index]
            shelves.append(Shelf(id: "explore-genre-\(genre)", title: Self.genreTitle(genre), style: .trackList,
                                 items: tracks.map(MediaItem.track), moreToken: "explore:genre:\(genre)"))
        }
        if shelves.isEmpty {
            _ = try await searchTracks("year:\(year)", pages: 1) // throws the underlying error if there is one
            throw ProviderError.notSupported("Browse for this Spotify app")
        }
        return shelves
    }

    static func genreTitle(_ genre: String) -> String {
        switch genre {
        case "hip-hop": "Hip-Hop"
        case "r&b": "R&B"
        default: genre.capitalized
        }
    }

    @concurrent
    public func shelf(moreToken: String) async throws -> Shelf {
        let me = await userID()
        let parts = moreToken.split(separator: ":", maxSplits: 2).map(String.init)
        switch (parts.first, parts.dropFirst().first) {
        case ("home", "recent"):
            let tracks = Self.dedupe(try await recentlyPlayed(limit: 50))
            return Shelf(id: moreToken, title: "Recently Played", style: .trackList, items: tracks.map(MediaItem.track))
        case ("home", "top-tracks"):
            return Shelf(id: moreToken, title: "Your Top Songs", style: .trackList, items: try await topTracks(limit: 50).map(MediaItem.track))
        case ("home", "top-artists"):
            return Shelf(id: moreToken, title: "Your Top Artists", style: .artists, items: try await topArtists(limit: 50).map(MediaItem.artist))
        case ("home", "saved-albums"):
            return Shelf(id: moreToken, title: "Your Albums", style: .carousel, items: try await savedAlbums(limit: 50, next: nil).items.map(MediaItem.album))
        case ("home", "playlists"):
            return Shelf(id: moreToken, title: "Your Playlists", style: .carousel, items: try await myPlaylists(limit: 50, next: nil, userID: me).items.map(MediaItem.playlist))
        case ("home", "followed"):
            return Shelf(id: moreToken, title: "Artists You Follow", style: .artists, items: try await followedArtists(limit: 50, next: nil).items.map(MediaItem.artist))
        case ("explore", "new"):
            return Shelf(id: moreToken, title: "New Releases", style: .carousel, items: try await newReleasesOrSearch(pages: 5).map(MediaItem.album))
        case ("explore", "year"):
            let year = parts.count > 2 ? parts[2] : String(Calendar(identifier: .gregorian).component(.year, from: Date()))
            return Shelf(id: moreToken, title: "Popular in \(year)", style: .trackList, items: try await searchTracks("year:\(year)", pages: 5).map(MediaItem.track))
        case ("explore", "genre") where parts.count > 2:
            let genre = parts[2]
            let year = Calendar(identifier: .gregorian).component(.year, from: Date())
            return Shelf(id: moreToken, title: Self.genreTitle(genre), style: .trackList,
                         items: try await searchTracks("genre:\"\(genre)\" year:\(year - 1)-\(year)", pages: 5).map(MediaItem.track))
        default:
            throw ProviderError.notFound
        }
    }

    // MARK: Search

    @concurrent
    public func search(_ query: String, scope: SearchScope) async throws -> SearchResults {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return SearchResults() }
        let me = await userID()
        let type: String = switch scope {
        case .all: "track,album,artist,playlist"
        case .songs: "track"
        case .albums: "album"
        case .artists: "artist"
        case .playlists: "playlist"
        }
        // One page for "all"; a scoped search takes two pages (Spotify caps a page at 10 since February 2026).
        let pages = scope == .all ? 1 : 2
        let responses = try await withThrowingTaskGroup(of: (Int, SP.SearchResponse).self) { group in
            for page in 0..<pages {
                group.addTask {
                    let response: SP.SearchResponse = try await api.get("search", query: [
                        "q": q, "type": type, "limit": String(Self.searchPageSize),
                        "offset": String(page * Self.searchPageSize), "market": "from_token",
                    ], ttl: 120)
                    return (page, response)
                }
            }
            var out: [(Int, SP.SearchResponse)] = []
            for try await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let tracks = Self.dedupe(responses.flatMap { $0.tracks?.items ?? [] }.compactMap(SpotifyMapping.track))
        let albums = Self.unique(responses.flatMap { $0.albums?.items ?? [] }.map(SpotifyMapping.album))
        let artists = Self.unique(responses.flatMap { $0.artists?.items ?? [] }.map(SpotifyMapping.artist))
        let playlists = Self.unique(responses.flatMap { $0.playlists?.items ?? [] }.map { SpotifyMapping.playlist($0, currentUserID: me) })
        let top = scope == .all ? Self.topResult(query: q, tracks: tracks, albums: albums, artists: artists, playlists: playlists) : nil
        return SearchResults(top: top, tracks: tracks, albums: albums, artists: artists, playlists: playlists)
    }

    /// Spotify has no "top result". Pick an exact name match (artist, then album, then song), else the first artist
    /// whose name starts the query, else the first song.
    static func topResult(query: String, tracks: [Track], albums: [Album], artists: [Artist], playlists: [Playlist]) -> MediaItem? {
        let q = normalize(query)
        if let artist = artists.first(where: { normalize($0.name) == q }) { return .artist(artist) }
        if let album = albums.prefix(3).first(where: { normalize($0.title) == q }) { return .album(album) }
        if let track = tracks.prefix(3).first(where: { normalize($0.title) == q }) { return .track(track) }
        if let artist = artists.first, q.hasPrefix(normalize(artist.name)) || normalize(artist.name).hasPrefix(q) { return .artist(artist) }
        if let track = tracks.first { return .track(track) }
        if let artist = artists.first { return .artist(artist) }
        if let album = albums.first { return .album(album) }
        return playlists.first.map(MediaItem.playlist)
    }

    /// Names from a small artist+track search, for type-ahead.
    @concurrent
    public func suggestions(_ query: String) async throws -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        let response: SP.SearchResponse = try await api.get("search", query: ["q": q, "type": "artist,track", "limit": "5"], ttl: 300)
        var seen = Set<String>()
        var out: [String] = []
        for name in (response.artists?.items.map(\.name) ?? []) + (response.tracks?.items.map(\.name) ?? []) {
            let key = Self.normalize(name)
            if seen.insert(key).inserted { out.append(name) }
        }
        return out
    }

    // MARK: Entities

    @concurrent
    public func album(id: String) async throws -> AlbumDetail {
        let album: SP.Album = try await api.get("albums/\(id)", query: ["market": "from_token"], ttl: 600)
        let simplified = album.simplified
        var trackObjects = album.tracks?.items ?? []
        var next = album.tracks?.next
        var pages = 0
        while let link = next, let url = URL(string: link), pages < 10 {
            let page: SP.Paging<SP.SimplifiedTrack> = try await api.get(absolute: url, ttl: 600)
            trackObjects += page.items
            next = page.next
            pages += 1
        }
        let tracks = trackObjects.compactMap { SpotifyMapping.track($0, album: simplified) }
        let model = SpotifyMapping.album(simplified)

        var moreByArtist: [Album] = []
        if let artistID = album.artists?.first?.id {
            moreByArtist = (await attempt { try await artistAlbums(artistID, groups: "album,single", limit: 10) } ?? [])
                .filter { $0.providerID != id }
        }
        let copyright = album.copyrights?.first { $0.type == "P" }?.text ?? album.copyrights?.first?.text
        let footnote = SpotifyMapping.albumFootnote(
            trackCount: album.total_tracks ?? tracks.count,
            totalSeconds: tracks.compactMap(\.duration).reduce(0, +),
            releaseDate: album.release_date,
            copyright: copyright.map { $0.hasPrefix("℗") || $0.hasPrefix("©") ? $0 : "℗ \($0)" }
        )
        return AlbumDetail(album: model, tracks: tracks, footnote: footnote, moreByArtist: moreByArtist)
    }

    @concurrent
    public func artist(id: String) async throws -> ArtistDetail {
        let artist: SP.Artist = try await api.get("artists/\(id)", ttl: 600)
        async let top = attempt { try await artistTopTracks(id: id, name: artist.name) }
        async let related = attempt { try await relatedArtists(id: id) }
        async let albums = attempt { try await artistAlbums(id, groups: "album", limit: 10, pages: 2) }
        async let singles = attempt { try await artistAlbums(id, groups: "single", limit: 10, pages: 2) }
        async let appearsOn = attempt { try await artistAlbums(id, groups: "appears_on", limit: 10) }
        async let followed = attempt { try await contains(["spotify:artist:\(id)"]).first ?? false }
        return ArtistDetail(
            artist: SpotifyMapping.artist(artist),
            topTracks: await top ?? [],
            albums: await albums ?? [],
            singles: await singles ?? [],
            playlists: [],
            related: await related ?? [],
            appearsOn: await appearsOn ?? [],
            radioSeed: "artist:\(id)",
            isFollowed: await followed
        )
    }

    /// `/artists/{id}/top-tracks` where the client still has it, else an `artist:` search (ranked by popularity),
    /// keeping only tracks credited to this artist.
    func artistTopTracks(id: String, name: String, limit: Int = 10) async throws -> [Track] {
        if let response: SP.TopTracks = try await optionalEndpoint("artists/\(id)/top-tracks", family: "artists/top-tracks",
                                                                    query: ["market": "from_token"], ttl: 600),
           !response.tracks.isEmpty {
            return Array(response.tracks.compactMap(SpotifyMapping.track).prefix(limit))
        }
        let tracks = try await searchTracks("artist:\"\(name)\"", pages: 2)
        let credited = tracks.filter { $0.artists.contains { $0.id == id } }
        return Array((credited.isEmpty ? tracks : credited).prefix(limit))
    }

    /// `/artists/{id}/related-artists`, removed for new apps in November 2024. Empty where it's unavailable.
    func relatedArtists(id: String) async throws -> [Artist] {
        let response: SP.Artists? = try await optionalEndpoint("artists/\(id)/related-artists", family: "artists/related-artists", ttl: 3600)
        return Array((response?.artists ?? []).map(SpotifyMapping.artist).prefix(20))
    }

    func artistAlbums(_ id: String, groups: String, limit: Int, pages: Int = 1) async throws -> [Album] {
        var out: [Album] = []
        var page: SP.Paging<SP.SimplifiedAlbum> = try await api.get("artists/\(id)/albums", query: [
            "include_groups": groups, "limit": String(limit), "market": "from_token",
        ], ttl: 600)
        out += page.items.map(SpotifyMapping.album)
        var fetched = 1
        while fetched < pages, let link = page.next, let url = URL(string: link) {
            page = try await api.get(absolute: url, ttl: 600)
            out += page.items.map(SpotifyMapping.album)
            fetched += 1
        }
        return Self.unique(out)
    }

    @concurrent
    /// `fresh`: straight from Spotify, neither read from the response cache nor written to it, so a response to an
    /// earlier cached read that lands meanwhile can't stand in for it (a playlist edit's check before Undo).
    public func playlist(id: String, fresh: Bool = false) async throws -> PlaylistDetail {
        let me = await userID()
        let playlist: SP.Playlist = try await api.get("playlists/\(id)", query: ["market": "from_token", "additional_types": "track"], ttl: 60, uncached: fresh)
        var model = SpotifyMapping.playlist(playlist.simplified, currentUserID: me)
        guard let contents = playlist.contents else {
            // Development-mode apps only see the items of playlists the user owns or collaborates on.
            model.extra["itemsUnavailable"] = "true"
            return PlaylistDetail(playlist: model, tracks: [])
        }
        if model.trackCount == nil { model.trackCount = contents.total }
        let entries = Self.playlistEntries(contents)
        return PlaylistDetail(playlist: model, tracks: entries.tracks, continuation: contents.next,
                              positions: entries.positions, entryCount: entries.entryCount, unlistedEntries: entries.unlisted)
    }

    @concurrent
    /// `fresh`: uncached, as `playlist(id:fresh:)`.
    public func playlistTracks(continuation: String, fresh: Bool = false) async throws -> Page<Track> {
        guard let url = URL(string: continuation) else { throw ProviderError.notFound }
        let page: SP.Paging<SP.PlaylistItem> = try await api.get(absolute: url, ttl: 60, uncached: fresh)
        let entries = Self.playlistEntries(page)
        return Page(items: entries.tracks, continuation: page.next, positions: entries.positions, entryCount: entries.entryCount,
                    unlistedEntries: entries.unlisted)
    }

    /// A page of playlist entries as songs, with each song's place in the whole playlist: the page's offset plus its
    /// index among every entry Spotify listed, so the episodes, local files and `null`s left out still count
    /// (`[A, local, X, B, X]` puts X at 2 and 4, where a removal's Undo must put it back).
    /// The entries left out that Spotify still identifies (a local file's `spotify:local:` URI, an episode's URI) come
    /// back by place in `unlisted`; a `null` entry has none.
    static func playlistEntries(_ page: SP.Paging<SP.PlaylistItem>) -> (tracks: [Track], positions: [Int], entryCount: Int, unlisted: [Int: String]) {
        let base = page.offset ?? 0
        var tracks: [Track] = [], positions: [Int] = [], unlisted: [Int: String] = [:]
        for (item, index) in zip(page.items, page.itemIndices) {
            guard let content = item.content, let track = SpotifyMapping.track(content) else {
                if let uri = item.content?.uri, !uri.isEmpty { unlisted[base + index] = uri }
                continue
            }
            tracks.append(track)
            positions.append(base + index)
        }
        return (tracks, positions, page.rawCount, unlisted)
    }

    /// First page of a playlist's items through `/playlists/{id}/items` (owned or collaborative playlists only).
    func playlistItems(id: String, limit: Int = 50) async throws -> [Track] {
        let page: SP.Paging<SP.PlaylistItem> = try await api.get("playlists/\(id)/items", query: [
            "limit": String(limit), "market": "from_token", "additional_types": "track",
        ], ttl: 60)
        return page.items.compactMap { $0.content }.compactMap(SpotifyMapping.track)
    }

    // MARK: Library

    @concurrent
    public func library(_ kind: LibraryKind, continuation: String?) async throws -> Page<MediaItem> {
        let me = await userID()
        switch kind {
        case .likedSongs, .songs:
            let page: SP.Paging<SP.SavedTrack> = try await fetch("me/tracks", query: ["limit": "50", "market": "from_token"], next: continuation)
            return Page(items: page.items.compactMap { SpotifyMapping.track($0.track) }.map(MediaItem.track), continuation: page.next)
        case .albums:
            let page = try await savedAlbums(limit: 50, next: continuation)
            return Page(items: page.items.map(MediaItem.album), continuation: page.continuation)
        case .artists:
            let page = try await followedArtists(limit: 50, next: continuation)
            return Page(items: page.items.map(MediaItem.artist), continuation: page.continuation)
        case .playlists:
            let page = try await myPlaylists(limit: 50, next: continuation, userID: me)
            return Page(items: page.items.map(MediaItem.playlist), continuation: page.continuation)
        case .recentlyPlayed:
            let page: SP.CursorPaging<SP.PlayHistory> = try await fetch("me/player/recently-played", query: ["limit": "50"], next: continuation, ttl: 30)
            let tracks = page.items.compactMap { SpotifyMapping.track($0.track) }
            return Page(items: tracks.map(MediaItem.track), continuation: page.next)
        }
    }

    /// Saves/removes anything in the library: songs (likes), albums, playlists (follow), artists (follow).
    @concurrent
    public func setInLibrary(_ uris: [String], saved: Bool) async throws {
        for chunk in uris.chunked(40) {
            try await api.send(saved ? .put : .delete, "me/library", query: ["uris": chunk.joined(separator: ",")])
        }
    }

    @concurrent
    public func contains(_ uris: [String]) async throws -> [Bool] {
        var out: [Bool] = []
        for chunk in uris.chunked(40) {
            out += try await api.get("me/library/contains", query: ["uris": chunk.joined(separator: ",")], as: [Bool].self)
        }
        return out
    }

    @concurrent
    public func createPlaylist(title: String, description: String?, as binding: SpotifyWriteBinding? = nil) async throws -> Playlist {
        var body: [String: any Sendable] = ["name": title, "public": false]
        if let description, !description.isEmpty { body["description"] = description }
        try await learnAccount(for: binding)
        let data = try await api.send(.post, "me/playlists", json: body, as: binding)
        let created: SP.Playlist
        do { created = try JSONDecoder().decode(SP.Playlist.self, from: data) }
        catch { throw ProviderError.decoding("created playlist: \(SpotifyAPI.describe(error))") }
        var playlist = SpotifyMapping.playlist(created.simplified, currentUserID: await userID())
        playlist.isEditable = true
        return playlist
    }

    @concurrent
    /// `binding`: each request (each chunk, each retry) goes only with the bound account's token
    /// (`SpotifyAPI.send(_:_:query:json:as:)`).
    public func add(_ uris: [String], toPlaylist id: String, as binding: SpotifyWriteBinding? = nil) async throws {
        try await learnAccount(for: binding)
        for chunk in uris.chunked(100) {
            try await api.send(.post, "playlists/\(id)/items", json: ["uris": chunk], as: binding)
        }
    }

    /// A binding by user id needs the API to know whose token it holds: a token restored at launch learns it from
    /// `/me` first, under its own session.
    private func learnAccount(for binding: SpotifyWriteBinding?) async throws {
        guard binding?.userID != nil, await api.userID == nil else { return }
        _ = try await me()
    }

    /// Adds the URIs with the first at `position` (0-based), the rest after it.
    @concurrent
    public func insert(_ uris: [String], intoPlaylist id: String, at position: Int, as binding: SpotifyWriteBinding? = nil) async throws {
        try await learnAccount(for: binding)
        for (offset, chunk) in uris.chunked(100).enumerated() {
            try await api.send(.post, "playlists/\(id)/items", json: ["uris": chunk, "position": position + offset * 100], as: binding)
        }
    }

    /// Removes every occurrence of each URI.
    @concurrent
    public func remove(_ uris: [String], fromPlaylist id: String, as binding: SpotifyWriteBinding? = nil) async throws {
        try await learnAccount(for: binding)
        for chunk in Array(Set(uris)).sorted().chunked(100) {
            try await api.send(.delete, "playlists/\(id)/items", json: ["items": chunk.map { ["uri": $0] }], as: binding)
        }
    }

    // MARK: Radio

    /// Recommendations are gone for new apps (November 2024), so a radio is the seed's artists' best-known songs,
    /// songs from the main artist's genres when Spotify still reports them, and the listener's own top songs as filler.
    @concurrent
    public func radio(seed: Track, limit: Int = 30) async throws -> [Track] {
        let artists = Array(seed.artists.prefix(2))
        var groups: [[Track]] = await withTaskGroup(of: (Int, [Track]).self) { group in
            for (index, artist) in artists.enumerated() {
                group.addTask {
                    let tracks: [Track]
                    if let id = artist.id {
                        tracks = await attempt { try await artistTopTracks(id: id, name: artist.name, limit: 20) } ?? []
                    } else {
                        tracks = await attempt { try await searchTracks("artist:\"\(artist.name)\"", pages: 1) } ?? []
                    }
                    return (index, tracks)
                }
            }
            if let id = artists.first?.id {
                group.addTask { (100, await attempt { try await genreTracks(artistID: id) } ?? []) }
            }
            var out: [(Int, [Track])] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        if groups.joined().count < limit {
            groups.append(await attempt { try await topTracks(limit: 30) } ?? [])
        }
        var rng = SystemRandomNumberGenerator()
        return RadioMixer.mix(groups, excluding: seed, limit: limit, using: &rng)
    }

    /// `artist:<id>`, `playlist:<id>`, `album:<id>`, `track:<id>`, a `spotify:` URI, or a bare playlist id.
    @concurrent
    public func radio(seedID: String, limit: Int = 30) async throws -> [Track] {
        let (kind, id) = Self.parseSeed(seedID)
        var rng = SystemRandomNumberGenerator()
        switch kind {
        case "artist":
            let artist: SP.Artist = try await api.get("artists/\(id)", ttl: 600)
            async let top = attempt { try await artistTopTracks(id: id, name: artist.name, limit: 20) }
            async let genre = attempt { try await genreTracks(artistID: id) }
            async let albums = attempt { try await artistAlbums(id, groups: "album", limit: 5) }
            var groups = [await top ?? [], await genre ?? []]
            // A few tracks from a couple of albums for deeper cuts.
            for album in (await albums ?? []).prefix(2) {
                if let detail = await attempt({ try await self.album(id: album.providerID) }) {
                    groups.append(detail.tracks)
                }
            }
            let tracks = RadioMixer.mix(groups, excluding: nil, limit: limit, using: &rng)
            if tracks.isEmpty { throw ProviderError.notFound }
            return tracks
        case "album":
            let detail = try await album(id: id)
            guard let seed = detail.tracks.first else { throw ProviderError.notFound }
            return RadioMixer.mix([detail.tracks, try await radio(seed: seed, limit: limit)], excluding: nil, limit: limit, using: &rng)
        case "track":
            let raw: SP.Track = try await api.get("tracks/\(id)", query: ["market": "from_token"], ttl: 600)
            guard let seed = SpotifyMapping.track(raw) else { throw ProviderError.notFound }
            return try await radio(seed: seed, limit: limit)
        default:
            let detail = try await playlist(id: id)
            var tracks = detail.tracks.filter(\.isPlayable)
            if tracks.isEmpty { throw ProviderError.notSupported("Radio from playlists you don't own") }
            tracks.shuffle(using: &rng)
            if tracks.count >= limit { return Array(tracks.prefix(limit)) }
            let extra = try await radio(seed: tracks[0], limit: limit - tracks.count)
            return RadioMixer.mix([tracks, extra], excluding: nil, limit: limit, using: &rng)
        }
    }

    static func parseSeed(_ seed: String) -> (kind: String, id: String) {
        let parts = seed.split(separator: ":").map(String.init)
        if parts.count == 3, parts[0] == "spotify" { return (parts[1], parts[2]) }
        if parts.count == 2 { return (parts[0], parts[1]) }
        return ("playlist", seed)
    }

    private func genreTracks(artistID: String) async throws -> [Track] {
        let artist: SP.Artist = try await api.get("artists/\(artistID)", ttl: 600)
        guard let genre = artist.genres?.first else { return [] }
        return try await searchTracks("genre:\"\(genre)\"", pages: 2)
    }

    // MARK: Building blocks

    func recentlyPlayed(limit: Int) async throws -> [Track] {
        let page: SP.CursorPaging<SP.PlayHistory> = try await api.get("me/player/recently-played", query: ["limit": String(limit)], ttl: 30)
        return page.items.compactMap { SpotifyMapping.track($0.track) }
    }

    func topTracks(limit: Int) async throws -> [Track] {
        let page: SP.Paging<SP.Track> = try await api.get("me/top/tracks", query: ["limit": String(limit), "time_range": "short_term"], ttl: 600)
        return page.items.compactMap(SpotifyMapping.track)
    }

    func topArtists(limit: Int) async throws -> [Artist] {
        let page: SP.Paging<SP.Artist> = try await api.get("me/top/artists", query: ["limit": String(limit), "time_range": "medium_term"], ttl: 600)
        return page.items.map(SpotifyMapping.artist)
    }

    func savedAlbums(limit: Int, next: String?) async throws -> Page<Album> {
        let page: SP.Paging<SP.SavedAlbum> = try await fetch("me/albums", query: ["limit": String(limit), "market": "from_token"], next: next)
        return Page(items: page.items.map { SpotifyMapping.album($0.album.simplified) }, continuation: page.next)
    }

    func myPlaylists(limit: Int, next: String?, userID: String?) async throws -> Page<Playlist> {
        let page: SP.Paging<SP.SimplifiedPlaylist> = try await fetch("me/playlists", query: ["limit": String(limit)], next: next)
        return Page(items: page.items.map { SpotifyMapping.playlist($0, currentUserID: userID) }, continuation: page.next)
    }

    func followedArtists(limit: Int, next: String?) async throws -> Page<Artist> {
        let response: SP.FollowedArtists = try await fetch("me/following", query: ["type": "artist", "limit": String(limit)], next: next)
        return Page(items: response.artists.items.map(SpotifyMapping.artist), continuation: response.artists.next)
    }

    /// `/browse/new-releases` was removed for development-mode apps in February 2026. Try it once per session,
    /// since extended-quota apps still have it.
    func newReleases(limit: Int) async throws -> [Album]? {
        let response: SP.NewReleases? = try await optionalEndpoint("browse/new-releases", query: ["limit": String(limit)], ttl: 1800)
        return response?.albums.items.map(SpotifyMapping.album)
    }

    /// GET `path`, or nil when the endpoint is gone for this client. The first 403/404/410 marks `family` (default:
    /// `path`) unavailable for the session, so later calls skip the request.
    private func optionalEndpoint<T: Decodable & Sendable>(
        _ path: String, family: String? = nil, query: [String: String] = [:], ttl: TimeInterval
    ) async throws -> T? {
        let family = family ?? path
        if await api.isUnavailable(family) { return nil }
        let generation = await api.sessionGeneration
        do {
            return try await api.get(path, query: query, ttl: ttl) as T
        } catch let error as ProviderError {
            switch error {
            case .notFound, .server(403, _), .server(410, _):
                await api.markUnavailable(family, session: generation)
                return nil
            default:
                throw error
            }
        }
    }

    /// New releases, else albums from the last two weeks via the `tag:new` search filter.
    func newReleasesOrSearch(pages: Int) async throws -> [Album] {
        if let albums = try await newReleases(limit: min(50, pages * 10)), !albums.isEmpty { return albums }
        var albums: [Album] = []
        for page in 0..<pages {
            let response: SP.SearchResponse = try await api.get("search", query: [
                "q": "tag:new", "type": "album", "limit": String(Self.searchPageSize), "offset": String(page * Self.searchPageSize),
            ], ttl: 1800)
            let items = response.albums?.items ?? []
            albums += items.map(SpotifyMapping.album)
            if items.count < Self.searchPageSize { break }
        }
        return Self.unique(albums)
    }

    func searchTracks(_ q: String, pages: Int) async throws -> [Track] {
        try await withThrowingTaskGroup(of: (Int, [Track]).self) { group in
            for page in 0..<pages {
                group.addTask {
                    let response: SP.SearchResponse = try await api.get("search", query: [
                        "q": q, "type": "track", "limit": String(Self.searchPageSize),
                        "offset": String(page * Self.searchPageSize), "market": "from_token",
                    ], ttl: 900)
                    return (page, (response.tracks?.items ?? []).compactMap(SpotifyMapping.track))
                }
            }
            var out: [(Int, [Track])] = []
            for try await r in group { out.append(r) }
            return Self.dedupe(out.sorted { $0.0 < $1.0 }.flatMap(\.1))
        }
    }

    /// First page from `path`, or the page at `next` (a Spotify `next` link) when continuing.
    private func fetch<T: Decodable & Sendable>(_ path: String, query: [String: String], next: String?, ttl: TimeInterval = 60) async throws -> T {
        if let next {
            guard let url = URL(string: next) else { throw ProviderError.notFound }
            return try await api.get(absolute: url, ttl: ttl)
        }
        return try await api.get(path, query: query, ttl: ttl)
    }

    // MARK: Devices and playback (Spotify Connect)

    @concurrent
    public func devices() async throws -> [SpotifyDevice] {
        let response: SP.Devices = try await api.get("me/player/devices")
        return response.devices.compactMap(SpotifyDevice.init)
    }

    @concurrent
    func playbackState() async throws -> SP.PlaybackState? {
        let data = try await api.send(.get, "me/player", query: ["market": "from_token"])
        // 204 No Content: nothing is playing anywhere.
        guard !data.isEmpty else { return nil }
        do { return try JSONDecoder().decode(SP.PlaybackState.self, from: data) }
        catch { throw ProviderError.decoding("me/player: \(SpotifyAPI.describe(error))") }
    }

    @concurrent
    public func startPlayback(uri: String, positionMS: Int, deviceID: String?) async throws {
        try await api.send(.put, "me/player/play", query: deviceID.map { ["device_id": $0] } ?? [:],
                           json: ["uris": [uri], "position_ms": max(0, positionMS)])
    }

    @concurrent
    public func resume(deviceID: String?) async throws {
        try await api.send(.put, "me/player/play", query: deviceID.map { ["device_id": $0] } ?? [:])
    }

    @concurrent
    public func pause(deviceID: String?) async throws {
        try await api.send(.put, "me/player/pause", query: deviceID.map { ["device_id": $0] } ?? [:])
    }

    @concurrent
    public func seek(positionMS: Int, deviceID: String?) async throws {
        var query = ["position_ms": String(max(0, positionMS))]
        if let deviceID { query["device_id"] = deviceID }
        try await api.send(.put, "me/player/seek", query: query)
    }

    @concurrent
    public func setVolume(percent: Int, deviceID: String?) async throws {
        var query = ["volume_percent": String(min(100, max(0, percent)))]
        if let deviceID { query["device_id"] = deviceID }
        try await api.send(.put, "me/player/volume", query: query)
    }

    @concurrent
    public func transfer(to deviceID: String, play: Bool) async throws {
        try await api.send(.put, "me/player", json: ["device_ids": [deviceID], "play": play])
    }

    // MARK: Helpers

    /// Runs `op`, returning nil on failure so one broken section doesn't sink a page. Cancellation still propagates as nil.
    func attempt<T: Sendable>(_ op: () async throws -> T) async -> T? {
        try? await op()
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Unique by id, keeping order.
    static func dedupe(_ tracks: [Track]) -> [Track] {
        var seen = Set<String>()
        return tracks.filter { seen.insert($0.providerID).inserted }
    }

    static func unique<T: Identifiable>(_ items: [T]) -> [T] where T.ID == String {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    /// Distinct albums in play order, for "Jump Back In".
    static func albumsFromTracks(_ tracks: [Track], limit: Int = 12) -> [Album] {
        var seen = Set<String>()
        var out: [Album] = []
        for track in tracks {
            guard let ref = track.album, let id = ref.id, seen.insert(id).inserted else { continue }
            out.append(Album(providerID: id, provider: .spotify, title: ref.title,
                             artists: [ArtistRef(name: track.extra["albumArtist"] ?? track.artists.first?.name ?? "")],
                             artwork: track.artwork, extra: ["uri": "spotify:album:\(id)"]))
            if out.count == limit { break }
        }
        return out
    }
}

/// A Spotify Connect device.
public struct SpotifyDevice: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var type: String
    public var isActive: Bool
    public var isRestricted: Bool
    public var volumePercent: Int?

    init?(_ device: SP.Device) {
        guard let id = device.id else { return nil }
        self.id = id
        self.name = device.name
        self.type = device.type ?? "Unknown"
        self.isActive = device.is_active ?? false
        self.isRestricted = device.is_restricted ?? false
        self.volumePercent = device.volume_percent
    }

    public init(id: String, name: String, type: String, isActive: Bool, isRestricted: Bool = false, volumePercent: Int? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.isActive = isActive
        self.isRestricted = isRestricted
        self.volumePercent = volumePercent
    }
}

/// Builds a radio queue from groups of candidate tracks.
enum RadioMixer {
    /// Shuffles each group, interleaves them round-robin, drops duplicates (same id, or same title by the same lead
    /// artist) and the seed, and avoids the same lead artist twice in a row when another choice exists.
    static func mix<R: RandomNumberGenerator>(_ groups: [[Track]], excluding seed: Track?, limit: Int, using rng: inout R) -> [Track] {
        var seenIDs = Set<String>()
        var seenKeys = Set<String>()
        if let seed {
            seenIDs.insert(seed.providerID)
            seenKeys.insert(key(seed))
        }
        var shuffled = groups.map { $0.filter(\.isPlayable).shuffled(using: &rng) }
        var pool: [Track] = []
        var index = 0
        while shuffled.contains(where: { !$0.isEmpty }) {
            let g = index % shuffled.count
            index += 1
            guard !shuffled[g].isEmpty else { continue }
            let track = shuffled[g].removeFirst()
            guard seenIDs.insert(track.providerID).inserted, seenKeys.insert(key(track)).inserted else { continue }
            pool.append(track)
        }
        // Spread artists out.
        var out: [Track] = []
        while !pool.isEmpty, out.count < limit {
            let last = out.last?.artists.first?.name
            let pick = pool.firstIndex { $0.artists.first?.name != last } ?? 0
            out.append(pool.remove(at: pick))
        }
        return out
    }

    static func key(_ track: Track) -> String {
        let title = track.title.lowercased()
            .replacingOccurrences(of: #"\s*[\(\[].*?(remaster|version|edit|mix|live).*?[\)\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+-\s+.*(remaster|version|edit|mix|live).*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return "\(title)|\(track.artists.first?.name.lowercased() ?? "")"
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
