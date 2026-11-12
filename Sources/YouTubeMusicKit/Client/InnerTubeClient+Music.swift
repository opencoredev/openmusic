import Foundation
import MedleyCore

/// YouTube Music operations. They live on `InnerTubeClient` so raw JSON never leaves the actor;
/// only `Sendable` models are returned.
extension InnerTubeClient {
    // MARK: Browse

    func home() async throws -> [Shelf] {
        var root = try await browse("FEmusic_home")
        var shelves = PageParser.shelves(root)
        var token = PageParser.sectionsContinuation(root)
        var pages = 0
        // Signed-out home is short; signed-in home pages in more shelves on scroll. Load a few pages up front.
        while let next = token, pages < 4, shelves.count < 18 {
            root = try await browseContinuation(next)
            shelves += PageParser.shelves(root)
            token = PageParser.sectionsContinuation(root)
            pages += 1
        }
        return Self.uniqueIDs(shelves, prefix: "home")
    }

    func explore() async throws -> [Shelf] {
        async let explorePage = shelves(browseId: "FEmusic_explore")
        async let chartsPage = shelves(browseId: "FEmusic_charts")
        let skip: (Shelf) -> Bool = { shelf in
            let t = shelf.title.lowercased()
            // The untitled grid at the top only links to New releases / Charts / Moods / Podcasts.
            return t.isEmpty || t.contains("podcast") || t.contains("episode")
        }
        var shelves = try await explorePage.filter { !skip($0) }
        shelves += ((try? await chartsPage) ?? []).filter { !skip($0) }
        return Self.uniqueIDs(shelves, prefix: "explore")
    }

    private func shelves(browseId: String) async throws -> [Shelf] {
        PageParser.shelves(try await browse(browseId))
    }

    func shelf(moreToken: String) async throws -> Shelf {
        guard case .browse(let id, let params)? = MoreToken(moreToken) else { throw ProviderError.notFound }
        if id.hasPrefix("VL") {
            let detail = try await playlist(id: ItemParser.playlistID(fromBrowseID: id))
            return Shelf(id: "more-" + moreToken, title: detail.playlist.title, style: .trackList, items: detail.tracks.map(MediaItem.track))
        }
        let root = try await browse(id, params: params)
        return PageParser.expandedShelf(root, token: moreToken)
    }

    static func uniqueIDs(_ shelves: [Shelf], prefix: String) -> [Shelf] {
        shelves.enumerated().map { i, shelf in
            var s = shelf
            s.id = "\(prefix)-\(i)-\(shelf.title)"
            return s
        }
    }

    // MARK: Search

    static func searchParams(_ scope: SearchScope) -> String? {
        switch scope {
        case .all: nil
        case .songs: "EgWKAQIIAWoMEA4QChADEAQQCRAF"
        case .albums: "EgWKAQIYAWoMEA4QChADEAQQCRAF"
        case .artists: "EgWKAQIgAWoMEA4QChADEAQQCRAF"
        case .playlists: "Eg-KAQwIABAAGAAgACgBMABqChAEEAMQCRAFEAo%3D"
        }
    }

    func search(_ query: String, scope: SearchScope) async throws -> SearchResults {
        var body: JSONObject = ["query": query]
        if let params = Self.searchParams(scope) { body["params"] = params }
        let root = try await post("search", body: body, cacheable: true)
        return PageParser.search(root, scope: scope)
    }

    func suggestions(_ query: String) async throws -> SearchSuggestions {
        let root = try await post("music/get_search_suggestions", body: ["input": query], cacheable: true)
        return SearchSuggestions(queries: PageParser.suggestions(root), items: PageParser.suggestionItems(root))
    }

    /// The song as the watch queue describes it, whose byline links the artist and the album.
    func linkedTrack(videoId: String) async throws -> Track? {
        let root = try await post("next", body: ["videoId": videoId, "isAudioOnly": true], authenticated: false, cacheable: true)
        let tracks = PageParser.watchNext(root).tracks
        return tracks.first { $0.providerID == videoId }
    }

    // MARK: Entities

    func album(id: String) async throws -> AlbumDetail {
        try PageParser.album(try await browse(id), browseId: id)
    }

    func artist(id: String) async throws -> ArtistDetail {
        let browseId = ItemParser.normalizeArtistID(id)
        return try PageParser.artist(try await browse(browseId), browseId: browseId)
    }

    func playlist(id: String) async throws -> PlaylistDetail {
        if id.hasPrefix("category:") {
            return try await categoryPlaylist(token: String(id.dropFirst("category:".count)))
        }
        let playlistId = ItemParser.playlistID(fromBrowseID: id)
        guard playlistId.hasPrefix("RD") else {
            return try PageParser.playlist(try await browse("VL" + playlistId, cacheable: !isSignedIn), playlistId: playlistId)
        }
        // Generated mixes (RDTMAK..., RDCLAK...) sometimes come back empty for a given visitor id;
        // retry once without it, then fall back to reading the mix as a watch queue.
        for (attempt, sendVisitor) in [true, false, false].enumerated() {
            if attempt == 2 { try? await Task.sleep(for: .milliseconds(400)) }
            if let detail = try? PageParser.playlist(try await browse("VL" + playlistId, cacheable: !isSignedIn, sendVisitor: sendVisitor), playlistId: playlistId),
               !detail.tracks.isEmpty {
                return detail
            }
            if isSignedIn { break } // signed-in mixes are personal; the visitor id isn't the problem
        }
        var queue = try await watchQueue(playlistId: playlistId, params: nil)
        if queue.isEmpty { queue = try await watchQueue(playlistId: playlistId, params: "wAEB") }
        // YouTube occasionally generates nothing for a mix; report it so the UI can offer a retry.
        guard !queue.isEmpty else { throw ProviderError.network("YouTube Music returned an empty mix. Try again.") }
        let playlist = Playlist(providerID: playlistId, provider: .youtubeMusic, title: "Mix", owner: "YouTube Music",
                                artwork: queue.first?.artwork, trackCount: queue.count)
        return PlaylistDetail(playlist: playlist, tracks: queue)
    }

    /// Moods & genres: show the category's first playlist; the full list is available via `shelf(moreToken:)`.
    private func categoryPlaylist(token: String) async throws -> PlaylistDetail {
        let shelf = try await shelf(moreToken: token)
        guard let first = shelf.items.lazy.compactMap({ if case .playlist(let p) = $0 { p } else { nil } }).first(where: { $0.extra["category"] == nil }) else {
            throw ProviderError.notFound
        }
        return try await playlist(id: first.providerID)
    }

    func playlistTracks(continuation: String) async throws -> Page<Track> {
        let root = try await browseContinuation(continuation, cacheable: !isSignedIn)
        let (items, next) = PageParser.continuationItems(root)
        let tracks = items.compactMap { if case .track(let t) = $0 { t } else { nil } }
        return Page(items: tracks, continuation: next)
    }

    // MARK: Library

    static func libraryBrowseID(_ kind: LibraryKind) -> String {
        switch kind {
        case .likedSongs: "VLLM"
        case .songs: "FEmusic_liked_videos"
        case .albums: "FEmusic_liked_albums"
        case .artists: "FEmusic_library_corpus_track_artists"
        case .playlists: "FEmusic_liked_playlists"
        case .recentlyPlayed: "FEmusic_history"
        }
    }

    func library(_ kind: LibraryKind, continuation: String?) async throws -> Page<MediaItem> {
        guard isSignedIn else { throw ProviderError.notSignedIn }
        if let continuation {
            let root = try await browseContinuation(continuation, cacheable: false)
            let (items, next) = PageParser.continuationItems(root)
            return Page(items: items, continuation: next)
        }
        let root = try await browse(Self.libraryBrowseID(kind), cacheable: false)
        if kind == .likedSongs {
            let detail = try PageParser.playlist(root, playlistId: "LM")
            return Page(items: detail.tracks.map(MediaItem.track), continuation: detail.continuation)
        }
        var page = PageParser.libraryPage(root)
        if kind == .playlists {
            // Drop the "New playlist" tile and keep real playlists.
            page.items = page.items.filter { if case .playlist = $0 { true } else { false } }
        }
        return page
    }

    // MARK: Mutations (signed in)

    private func mutate(_ endpoint: String, body: JSONObject, binding: YTMWriteBinding? = nil) async throws -> JSONObject {
        guard isSignedIn else { throw ProviderError.notSignedIn }
        let result = try await post(endpoint, body: body, binding: binding)
        clearCache()
        return result
    }

    func rate(videoId: String, like: Bool) async throws {
        _ = try await mutate(like ? "like/like" : "like/removelike", body: ["target": ["videoId": videoId]])
    }

    func rate(playlistId: String, like: Bool) async throws {
        _ = try await mutate(like ? "like/like" : "like/removelike", body: ["target": ["playlistId": playlistId]])
    }

    func subscribe(channelId: String, subscribe: Bool) async throws {
        _ = try await mutate(subscribe ? "subscription/subscribe" : "subscription/unsubscribe", body: ["channelIds": [channelId]])
    }

    func isLiked(videoId: String) async throws -> Bool {
        guard isSignedIn else { throw ProviderError.notSignedIn }
        let root = try await post("next", body: ["videoId": videoId, "isAudioOnly": true])
        return PageParser.watchNext(root).likeStatus == "LIKE"
    }

    func createPlaylist(title: String, description: String?, videoIds: [String] = [], binding: YTMWriteBinding? = nil) async throws -> String {
        var body: JSONObject = ["title": title, "description": description ?? "", "privacyStatus": "PRIVATE"]
        if !videoIds.isEmpty { body["videoIds"] = videoIds }
        let root = try await mutate("playlist/create", body: body, binding: binding)
        guard let id = root["playlistId"] as? String else { throw ProviderError.decoding("playlist/create returned no id") }
        return id
    }

    /// `binding`: sent only with the cookies of the account it was checked for (`checkWriteBinding`).
    func editPlaylist(_ playlistId: String, edits: [PlaylistEdit], binding: YTMWriteBinding? = nil) async throws {
        let actions: [JSONObject] = edits.map { edit in
            switch edit {
            case .add(let videoId):
                ["action": "ACTION_ADD_VIDEO", "addedVideoId": videoId, "dedupeOption": "DEDUPE_OPTION_SKIP"]
            case .remove(let videoId, let setVideoId):
                ["action": "ACTION_REMOVE_VIDEO", "removedVideoId": videoId, "setVideoId": setVideoId]
            }
        }
        let root = try await mutate("browse/edit_playlist", body: ["playlistId": ItemParser.playlistID(fromBrowseID: playlistId), "actions": actions], binding: binding)
        if let status = root["status"] as? String, status != "STATUS_SUCCEEDED" {
            throw ProviderError.server(200, status)
        }
    }

    // MARK: Watch next: radio, lyrics

    func watchQueue(videoId: String? = nil, playlistId: String?, params: String?) async throws -> [Track] {
        var body: JSONObject = ["isAudioOnly": true, "enablePersistentPlaylistPanel": true, "tunerSettingValue": "AUTOMIX_SETTING_NORMAL"]
        if let videoId { body["videoId"] = videoId }
        if let playlistId { body["playlistId"] = playlistId }
        if let params { body["params"] = params }
        let root = try await post("next", body: body, cacheable: true)
        return PageParser.watchNext(root).tracks
    }

    /// "Up next" for a song: its radio (`RDAMVM<videoId>`), without the seed itself.
    func radio(videoId: String) async throws -> [Track] {
        let tracks = try await watchQueue(videoId: videoId, playlistId: "RDAMVM" + videoId, params: "wAEB")
        return tracks.filter { $0.providerID != videoId }
    }

    /// Radio from an artist (`UC...` or its `RDEM...` seed) or a playlist id.
    func radio(seedID: String) async throws -> [Track] {
        var playlistId = seedID
        if seedID.hasPrefix("UC") || seedID.hasPrefix("MPLA") {
            guard let seed = try await artist(id: seedID).radioSeed else { throw ProviderError.notFound }
            playlistId = seed
        } else if seedID.hasPrefix("VL") {
            playlistId = "RDAMPL" + seedID.dropFirst(2)
        } else if !seedID.hasPrefix("RD") {
            playlistId = "RDAMPL" + seedID
        }
        return try await watchQueue(playlistId: playlistId, params: "wAEB")
    }

    func lyrics(videoId: String) async throws -> Lyrics? {
        let next = try await post("next", body: ["videoId": videoId, "isAudioOnly": true], authenticated: false, cacheable: true)
        guard let browseId = PageParser.watchNext(next).lyricsBrowseId else { return nil }
        // The Android app gets timed lyrics for the same browse id; the web client only gets plain text.
        if let timed = try? await post("browse", body: ["browseId": browseId], profile: .androidMusic, authenticated: false, cacheable: true),
           let lyrics = PageParser.lyrics(timed), lyrics.isSynced {
            return lyrics
        }
        let plain = try await post("browse", body: ["browseId": browseId], authenticated: false, cacheable: true)
        return PageParser.lyrics(plain)
    }

    // MARK: Account

    func account() async throws -> AccountInfo {
        guard isSignedIn else { throw ProviderError.notSignedIn }
        let root = try await post("account/account_menu", body: [:])
        guard let info = PageParser.account(root) else { throw ProviderError.notSignedIn }
        return info
    }

    // MARK: Diagnostics

    func rawRequest(endpoint: String, bodyJSON: String) async throws -> String {
        let body = try JSONSerialization.jsonObject(with: Data(bodyJSON.utf8)) as? JSONObject ?? [:]
        let root = try await post(endpoint, body: body)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }


    // MARK: Player

    func player(videoId: String, profile: InnerTubeProfile) async throws -> PlayerInfo {
        let root = try await post("player", body: [
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ], profile: profile, authenticated: false)
        return PlayerInfo(root)
    }
}

enum PlaylistEdit: Sendable, Hashable {
    case add(videoId: String)
    case remove(videoId: String, setVideoId: String)
}
