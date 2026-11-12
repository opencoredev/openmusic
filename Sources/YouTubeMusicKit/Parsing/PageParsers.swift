import Foundation
import OpenMusicCore

/// Continuation tokens come in two flavors: the newer `continuationCommand.token` (sent in the body)
/// and the older `nextContinuationData.continuation` (sent as `ctoken`/`continuation` query params).
/// We prefix them so callers can hand back a single opaque string.
enum ContinuationToken {
    static func encode(body token: String) -> String { "b:" + token }
    static func encode(query token: String) -> String { "q:" + token }

    /// The next continuation in `node`, preferring the newer style.
    static func find(in node: Any?) -> String? {
        if let item = JSONWalk.firstObject("continuationItemRenderer", in: node),
           let token = JSONWalk.firstObject("continuationCommand", in: item)?["token"] as? String {
            return encode(body: token)
        }
        if let data = JSONWalk.firstObject("nextContinuationData", in: node), let token = data["continuation"] as? String {
            return encode(query: token)
        }
        return nil
    }
}

enum PageParser {
    static let provider = ProviderID.youtubeMusic

    // MARK: Shelves (home, explore, charts, artist pages)

    /// Section-list contents from a browse response or a continuation response.
    static func sections(_ root: JSONObject) -> [JSONObject] {
        var out: [JSONObject] = []
        for list in JSONWalk.all("sectionListRenderer", in: root["contents"]) {
            out += ((list as? JSONObject)?["contents"] as? [Any] ?? []).compactMap { $0 as? JSONObject }
        }
        if let cont = root.o("continuationContents", "sectionListContinuation") {
            out += (cont["contents"] as? [Any] ?? []).compactMap { $0 as? JSONObject }
        }
        for action in root.a("onResponseReceivedActions") {
            out += ((action as? JSONObject)?.a("appendContinuationItemsAction", "continuationItems") ?? []).compactMap { $0 as? JSONObject }
        }
        return out
    }

    /// The section list's own continuation (more shelves), not one nested in a shelf.
    static func sectionsContinuation(_ root: JSONObject) -> String? {
        if let list = JSONWalk.firstObject("sectionListRenderer", in: root["contents"]),
           let token = (list.a("continuations").first as? JSONObject)?.s("nextContinuationData", "continuation") {
            return ContinuationToken.encode(query: token)
        }
        if let cont = root.o("continuationContents", "sectionListContinuation"),
           let token = (cont.a("continuations").first as? JSONObject)?.s("nextContinuationData", "continuation") {
            return ContinuationToken.encode(query: token)
        }
        return nil
    }

    static func shelves(_ root: JSONObject, skipTitles: Set<String> = []) -> [Shelf] {
        sections(root).enumerated().compactMap { index, section in
            guard let shelf = shelf(section, index: index), !skipTitles.contains(shelf.title) else { return nil }
            return shelf
        }
    }

    static func shelf(_ section: JSONObject, index: Int) -> Shelf? {
        guard let key = section.rendererKey, let r = section[key] as? JSONObject else { return nil }
        let title: String
        var subtitle: String?
        var moreEndpoint: YTEndpoint?
        var items: [MediaItem]
        var hero = false
        switch key {
        case "musicCarouselShelfRenderer", "musicImmersiveCarouselShelfRenderer":
            let header = r.o("header", "musicCarouselShelfBasicHeaderRenderer") ?? r.o("header", "musicImmersiveCarouselShelfHeaderRenderer") ?? [:]
            title = header.text("title") ?? ""
            subtitle = header.text("strapline")
            moreEndpoint = YTEndpoint(header.o("moreContentButton", "buttonRenderer", "navigationEndpoint"))
                ?? YTEndpoint(YTText.runs(header.o("title")).first?.o("navigationEndpoint"))
            items = ItemParser.items(r.a("contents"))
            hero = key == "musicImmersiveCarouselShelfRenderer"
        case "musicShelfRenderer":
            title = r.text("title") ?? ""
            moreEndpoint = YTEndpoint(r.o("bottomEndpoint")) ?? YTEndpoint(r.o("moreContentButton", "buttonRenderer", "navigationEndpoint"))
            items = ItemParser.items(r.a("contents"))
        case "gridRenderer":
            title = r.text("header", "gridHeaderRenderer", "title") ?? ""
            items = ItemParser.items(r.a("items"))
        case "musicCardShelfRenderer":
            title = r.text("header", "musicCardShelfHeaderBasicRenderer", "title") ?? "Top result"
            items = ItemParser.items(r.a("contents"))
        default:
            return nil
        }
        guard !items.isEmpty else { return nil }
        let moreToken: String? = switch moreEndpoint {
        case .browse(let id, let params, _)?: MoreToken.browse(browseId: id, params: params).encoded
        default: nil
        }
        return Shelf(id: "ytm-\(index)-\(title)", title: title, subtitle: subtitle, style: style(for: items, hero: hero), items: items, moreToken: moreToken)
    }

    static func style(for items: [MediaItem], hero: Bool) -> ShelfStyle {
        if hero { return .hero }
        let artists = items.filter { if case .artist = $0 { true } else { false } }.count
        if artists * 2 > items.count { return .artists }
        let tracks = items.filter {
            if case .track(let t) = $0 { t.extra["musicVideoType"] != "MUSIC_VIDEO_TYPE_OMV" && t.extra["musicVideoType"] != "MUSIC_VIDEO_TYPE_UGC" } else { false }
        }.count
        return tracks * 2 > items.count ? .trackList : .carousel
    }

    /// For "See All" pages: one shelf holding everything on the page.
    static func expandedShelf(_ root: JSONObject, token: String) -> Shelf {
        let shelves = shelves(root)
        let pageTitle = root.text("header", "musicHeaderRenderer", "title")
            ?? JSONWalk.firstObject("musicResponsiveHeaderRenderer", in: root).flatMap { $0.text("title") }
            ?? shelves.first?.title ?? ""
        if shelves.count == 1, var only = shelves.first {
            only.id = "more-" + token
            if only.title.isEmpty { only.title = pageTitle }
            only.moreToken = nil
            return only
        }
        var items: [MediaItem] = []
        var seen = Set<String>()
        for shelf in shelves { for item in shelf.items where seen.insert(item.id).inserted { items.append(item) } }
        return Shelf(id: "more-" + token, title: pageTitle, style: style(for: items, hero: false), items: items)
    }

    // MARK: Search

    static func search(_ root: JSONObject, scope: SearchScope) -> SearchResults {
        var results = SearchResults()
        let tab = (root.a("contents", "tabbedSearchResultsRenderer", "tabs").first as? JSONObject)?.o("tabRenderer", "content") ?? root
        var seen = Set<String>()
        func add(_ item: MediaItem) {
            guard seen.insert(item.id).inserted else { return }
            switch item {
            case .track(let t): results.tracks.append(t)
            case .album(let a): results.albums.append(a)
            case .artist(let a): results.artists.append(a)
            case .playlist(let p): results.playlists.append(p)
            }
        }
        for section in sections(["contents": tab]) {
            if let card = section["musicCardShelfRenderer"] as? JSONObject {
                let top = topResult(card)
                if results.top == nil, let top {
                    results.top = top
                    add(top)
                }
                for var item in ItemParser.items(card.a("contents")) {
                    // Songs in an artist's top-result card omit the artist name.
                    if case .track(var t) = item, t.artists.isEmpty, case .artist(let a)? = top {
                        t.artists = [ArtistRef(id: a.providerID, name: a.name)]
                        item = .track(t)
                    }
                    add(item)
                }
                continue
            }
            for list in ["itemSectionRenderer", "musicShelfRenderer"] {
                if let contents = (section[list] as? JSONObject)?.a("contents") {
                    for item in ItemParser.items(contents) { add(item) }
                }
            }
        }
        // Songs before videos in the combined list.
        if scope == .all {
            let isVideo: (Track) -> Bool = { ["MUSIC_VIDEO_TYPE_OMV", "MUSIC_VIDEO_TYPE_UGC"].contains($0.extra["musicVideoType"] ?? "") }
            results.tracks = results.tracks.filter { !isVideo($0) } + results.tracks.filter(isVideo)
        }
        return results
    }

    static func topResult(_ card: JSONObject) -> MediaItem? {
        let titleRun = YTText.runs(card.o("title")).first
        let title = YTText.plain(card.o("title")) ?? ""
        let meta = ItemParser.meta(runs: YTText.runs(card.o("subtitle")))
        let artwork = YTArtwork.from(card["thumbnail"])
        let endpoint = YTEndpoint(titleRun?.o("navigationEndpoint")) ?? YTEndpoint(card.o("onTap"))
        switch endpoint {
        case .watch(let id, _, let type)?:
            return .track(ItemParser.track(videoId: id, title: title, meta: meta, artwork: artwork, renderer: card, videoType: type))
        case .browse(let id, _, let page)?:
            return ItemParser.browseItem(browseId: id, pageType: page, title: title, meta: meta, artwork: artwork, renderer: card)
        default:
            return nil
        }
    }

    /// The direct matches YouTube Music lists under the completions (an artist, then songs and albums).
    static func suggestionItems(_ root: JSONObject) -> [MediaItem] {
        root.a("contents").flatMap { section -> [MediaItem] in
            ItemParser.items((section as? JSONObject)?.a("searchSuggestionsSectionRenderer", "contents") ?? [])
        }
    }

    static func suggestions(_ root: JSONObject) -> [String] {
        root.a("contents").flatMap { section -> [String] in
            ((section as? JSONObject)?.a("searchSuggestionsSectionRenderer", "contents") ?? []).compactMap { entry in
                guard let e = entry as? JSONObject else { return nil }
                return (e["searchSuggestionRenderer"] as? JSONObject)?.text("suggestion")
                    ?? (e["historySuggestionRenderer"] as? JSONObject)?.text("suggestion")
            }
        }
    }

    // MARK: Album

    static func album(_ root: JSONObject, browseId: String) throws -> AlbumDetail {
        guard let header = JSONWalk.firstObject("musicResponsiveHeaderRenderer", in: root["contents"]) else {
            throw ProviderError.decoding("album header missing")
        }
        let title = header.text("title") ?? ""
        let subtitle = ItemParser.meta(runs: YTText.runs(header.o("subtitle")))
        var artists = ItemParser.meta(runs: YTText.runs(header.o("straplineTextOne"))).artists
        if artists.isEmpty, let name = header.text("straplineTextOne") { artists = ItemParser.artistNames(name) }
        let artwork = YTArtwork.from(header["thumbnail"])
        let secondary = header.text("secondSubtitle")
        let summary = header.text("description", "musicDescriptionShelfRenderer", "description")

        var extra: [String: String] = [:]
        if let pid = albumPlaylistID(root, header: header) { extra["playlistId"] = pid }
        if let saved = JSONWalk.firstObject("toggleButtonRenderer", in: header["buttons"])?["isToggled"] as? Bool {
            extra["saved"] = saved ? "1" : "0"
        }

        let secondaryContents = root.o("contents", "twoColumnBrowseResultsRenderer", "secondaryContents")
        let shelfNode = JSONWalk.firstObject("musicShelfRenderer", in: secondaryContents) ?? JSONWalk.firstObject("musicShelfRenderer", in: root["contents"])
        let albumRef = AlbumRef(id: browseId, title: title)
        var tracks = ItemParser.tracks(shelfNode?.a("contents") ?? [])
        var explicit = false
        for i in tracks.indices {
            if tracks[i].artists.isEmpty { tracks[i].artists = artists }
            if tracks[i].album == nil { tracks[i].album = albumRef }
            tracks[i].artwork = artwork ?? tracks[i].artwork
            if tracks[i].trackNumber == nil { tracks[i].trackNumber = i + 1 }
            if let pid = extra["playlistId"] { tracks[i].extra["playlistId"] = pid }
            explicit = explicit || tracks[i].isExplicit
        }
        let album = Album(
            providerID: browseId, provider: provider, title: title, artists: artists, year: subtitle.year, artwork: artwork,
            kind: ItemParser.albumKind(subtitle.typeLabel), trackCount: tracks.count,
            isExplicit: explicit || ItemParser.isExplicit(header), extra: extra
        )
        var more: [Album] = []
        for section in sections(["contents": secondaryContents ?? [:]]) {
            if let carousel = section["musicCarouselShelfRenderer"] as? JSONObject {
                // The carousel may be "More by <artist>" or a generic "Releases for you"; keep the artist's own.
                let names = Set(artists.map(\.name))
                for case .album(var a) in ItemParser.items(carousel.a("contents")) {
                    if a.artists.isEmpty { a.artists = artists }
                    if a.artists.contains(where: { names.contains($0.name) }) { more.append(a) }
                }
            }
        }
        let footnote = [secondary, subtitle.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
        return AlbumDetail(album: album, tracks: tracks, summary: summary, footnote: footnote.isEmpty ? nil : footnote, moreByArtist: more)
    }

    static func albumPlaylistID(_ root: JSONObject, header: JSONObject) -> String? {
        for node in [header["buttons"], header["menu"], root["contents"]] {
            for case let pid as String in JSONWalk.all("playlistId", in: node) where pid.hasPrefix("OLAK") { return pid }
        }
        if let canonical = root.s("microformat", "microformatDataRenderer", "urlCanonical"),
           let list = URLComponents(string: canonical)?.queryItems?.first(where: { $0.name == "list" })?.value {
            return list
        }
        return nil
    }

    // MARK: Artist

    static func artist(_ root: JSONObject, browseId: String) throws -> ArtistDetail {
        let headerWrapper = root.o("header") ?? [:]
        guard let key = headerWrapper.rendererKey, let header = headerWrapper[key] as? JSONObject else {
            throw ProviderError.decoding("artist header missing")
        }
        let name = header.text("title") ?? ""
        let subscribe = header.o("subscriptionButton", "subscribeButtonRenderer")
        var extra: [String: String] = [:]
        if let channel = subscribe?["channelId"] as? String { extra["channelId"] = channel }
        if let subs = subscribe.flatMap({ YTText.plain($0.o("subscriberCountText")) }) { extra["subscribers"] = subs }
        let artist = Artist(
            providerID: browseId, provider: provider, name: name,
            artwork: YTArtwork.from(header["thumbnail"]),
            subtitle: header.text("monthlyListenerCount") ?? extra["subscribers"].map { "\($0) subscribers" },
            extra: extra
        )
        let me = ArtistRef(id: browseId, name: name)
        var detail = ArtistDetail(artist: artist)
        detail.bio = header.text("description")
        detail.isFollowed = subscribe?["subscribed"] as? Bool
        detail.radioSeed = header.s("startRadioButton", "buttonRenderer", "navigationEndpoint", "watchEndpoint", "playlistId")
            ?? header.s("startRadioButton", "buttonRenderer", "navigationEndpoint", "watchPlaylistEndpoint", "playlistId")
            ?? header.s("playButton", "buttonRenderer", "navigationEndpoint", "watchEndpoint", "playlistId")

        for section in sections(root) {
            if let shelf = section["musicShelfRenderer"] as? JSONObject {
                detail.topTracks += ItemParser.tracks(shelf.a("contents"))
                continue
            }
            if detail.bio == nil, let desc = section["musicDescriptionShelfRenderer"] as? JSONObject {
                detail.bio = desc.text("description")
                continue
            }
            guard let carousel = section["musicCarouselShelfRenderer"] as? JSONObject else { continue }
            let title = (carousel.o("header", "musicCarouselShelfBasicHeaderRenderer")?.text("title") ?? "").lowercased()
            let items = ItemParser.items(carousel.a("contents"))
            for item in items {
                switch item {
                case .album(var a):
                    if a.artists.isEmpty { a.artists = [me] }
                    if title.contains("single") || title.hasPrefix("ep") {
                        detail.singles.append(a)
                    } else {
                        detail.albums.append(a)
                    }
                case .playlist(let p): detail.playlists.append(p)
                case .artist(let a): detail.related.append(a)
                case .track: break // "Videos" / "Live performances" carousels
                }
            }
        }
        return detail
    }

    // MARK: Playlist

    static func playlist(_ root: JSONObject, playlistId: String) throws -> PlaylistDetail {
        let header = JSONWalk.firstObject("musicResponsiveHeaderRenderer", in: root["contents"])
            ?? JSONWalk.firstObject("musicDetailHeaderRenderer", in: root)
        guard let header else { throw ProviderError.decoding("playlist header missing") }
        let editable = JSONWalk.first("musicEditablePlaylistDetailHeaderRenderer", in: root["contents"]) != nil
        let title = header.text("title") ?? ""
        let ownerMeta = ItemParser.meta(runs: YTText.runs(header.o("straplineTextOne")))
        let owner = ownerMeta.artists.first?.name ?? header.text("straplineTextOne")
            ?? header.text("facepile", "avatarStackViewModel", "text") ?? ownerMeta.plain.first
        let second = header.text("secondSubtitle")
        var extra: [String: String] = [:]
        if let second { extra["stats"] = second }
        if let saved = JSONWalk.firstObject("toggleButtonRenderer", in: header["buttons"])?["isToggled"] as? Bool {
            extra["saved"] = saved ? "1" : "0"
        }
        let shelf = JSONWalk.firstObject("musicPlaylistShelfRenderer", in: root["contents"])
            ?? JSONWalk.firstObject("musicShelfRenderer", in: root.o("contents", "twoColumnBrowseResultsRenderer", "secondaryContents"))
        let contents = shelf?.a("contents") ?? []
        let tracks = ItemParser.tracks(contents)
        let continuation = ContinuationToken.find(in: contents)
        let playlist = Playlist(
            providerID: playlistId, provider: provider, title: title, owner: owner,
            artwork: YTArtwork.from(header["thumbnail"]),
            // The header's own total. Without one, the first page's length is the total only when there is no
            // later page; otherwise nil, so the app never takes 100 loaded songs for a 100-song playlist.
            trackCount: Self.trackCount(second) ?? (continuation == nil ? tracks.count : nil),
            summary: header.text("description", "musicDescriptionShelfRenderer", "description"),
            isEditable: editable, extra: extra
        )
        return PlaylistDetail(playlist: playlist, tracks: tracks, continuation: continuation)
    }

    /// "29K views • 1,000 songs • 3+ hours" → 1000.
    static func trackCount(_ text: String?) -> Int? {
        guard let text else { return nil }
        let segment = text.components(separatedBy: "•").first { $0.contains("song") || $0.contains("track") || $0.contains("episode") || $0.contains("video") }
        return segment.flatMap { YTText.number(in: $0.trimmingCharacters(in: .whitespaces)) }
    }

    /// A continuation of a playlist or any list (library, history).
    static func continuationItems(_ root: JSONObject) -> (items: [MediaItem], continuation: String?) {
        var list: [Any] = []
        for action in root.a("onResponseReceivedActions") {
            list += (action as? JSONObject)?.a("appendContinuationItemsAction", "continuationItems") ?? []
        }
        if let cc = root.o("continuationContents") {
            for (_, value) in cc {
                guard let v = value as? JSONObject else { continue }
                list += v.a("contents") + v.a("items")
                if let token = (v.a("continuations").first as? JSONObject)?.s("nextContinuationData", "continuation") {
                    return (ItemParser.items(list), ContinuationToken.encode(query: token))
                }
            }
        }
        return (ItemParser.items(list), ContinuationToken.find(in: list))
    }

    // MARK: Library pages (grids and shelves with continuations)

    static func libraryPage(_ root: JSONObject) -> Page<MediaItem> {
        var items: [MediaItem] = []
        var continuation: String?
        for section in sections(root) {
            guard let key = section.rendererKey, let r = section[key] as? JSONObject else { continue }
            let list = r.a("items") + r.a("contents")
            items += ItemParser.items(list)
            if continuation == nil {
                continuation = ContinuationToken.find(in: list)
                    ?? (r.a("continuations").first as? JSONObject)?.s("nextContinuationData", "continuation").map(ContinuationToken.encode(query:))
            }
        }
        return Page(items: items, continuation: continuation)
    }

    // MARK: Watch next (radio, lyrics id, like status)

    struct WatchNext {
        var tracks: [Track]
        var lyricsBrowseId: String?
        var relatedBrowseId: String?
        var likeStatus: String?
        var continuation: String?
    }

    static func watchNext(_ root: JSONObject) -> WatchNext {
        let tabs = root.a("contents", "singleColumnMusicWatchNextResultsRenderer", "tabbedRenderer", "watchNextTabbedResultsRenderer", "tabs")
        var out = WatchNext(tracks: [])
        for case let tab as JSONObject in tabs {
            guard let renderer = tab["tabRenderer"] as? JSONObject else { continue }
            if let id = YTEndpoint(renderer.o("endpoint"))?.browseId {
                if id.hasPrefix("MPLY") { out.lyricsBrowseId = id }
                if id.hasPrefix("MPTR") { out.relatedBrowseId = id }
            }
            if let panel = JSONWalk.firstObject("playlistPanelRenderer", in: renderer["content"]) {
                out.tracks = ItemParser.tracks(panel.a("contents"))
                if let token = (panel.a("continuations").first as? JSONObject)?.s("nextRadioContinuationData", "continuation") {
                    out.continuation = token
                }
            }
        }
        // Continuation responses for the queue.
        if let panel = root.o("continuationContents", "playlistPanelContinuation") {
            out.tracks = ItemParser.tracks(panel.a("contents"))
            out.continuation = (panel.a("continuations").first as? JSONObject)?.s("nextRadioContinuationData", "continuation")
        }
        out.likeStatus = JSONWalk.firstObject("likeButtonRenderer", in: root["playerOverlays"])?["likeStatus"] as? String
        return out
    }

    // MARK: Lyrics

    /// Timed lyrics (ANDROID_MUSIC client) or plain lyrics (WEB_REMIX).
    static func lyrics(_ root: JSONObject) -> Lyrics? {
        if let data = JSONWalk.firstObject("timedLyricsModel", in: root["contents"])?.o("lyricsData") {
            let raw = data.a("timedLyricsData").compactMap { $0 as? JSONObject }
            let lines: [LyricLine] = raw.compactMap { line in
                guard let text = line["lyricLine"] as? String else { return nil }
                let start = (line.s("cueRange", "startTimeMilliseconds")).flatMap(Double.init).map { $0 / 1000 }
                return LyricLine(time: start, text: text == "♪" ? "" : text)
            }
            if !lines.isEmpty {
                return Lyrics(lines: lines, source: data["sourceMessage"] as? String)
            }
        }
        guard let shelf = JSONWalk.firstObject("musicDescriptionShelfRenderer", in: root["contents"]),
              let text = shelf.text("description") else { return nil }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map { LyricLine(text: $0) }
        return Lyrics(lines: lines, source: shelf.text("footer"))
    }

    // MARK: Account

    static func account(_ root: JSONObject) -> AccountInfo? {
        guard let header = JSONWalk.firstObject("activeAccountHeaderRenderer", in: root) else { return nil }
        guard let name = header.text("accountName") else { return nil }
        let photo = (header.a("accountPhoto", "thumbnails").last as? JSONObject)?["url"] as? String
        let handle = header.text("channelHandle"), email = header.text("email")
        // No id: account_menu carries no immutable one (a handle or email can change or move to another account).
        // The provider sets it from the credentials' datasync id (`YouTubeMusicProvider.identified`).
        return AccountInfo(name: name, avatar: photo.flatMap(URL.init(string:)), detail: handle ?? email)
    }
}
