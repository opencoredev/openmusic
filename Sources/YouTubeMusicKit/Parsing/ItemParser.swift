import Foundation
import MedleyCore

/// Turns the InnerTube item renderers YouTube Music uses everywhere into Medley models.
///
/// Classification relies on endpoints (watch vs. browse + page type) rather than on display text,
/// so it works the same in search, shelves, library grids, playlists, and album pages.
enum ItemParser {
    static let provider = ProviderID.youtubeMusic

    // MARK: Entry points

    /// Any supported renderer wrapper (`{"musicResponsiveListItemRenderer": {...}}` etc.).
    static func item(_ wrapper: Any?) -> MediaItem? {
        guard let wrapper = wrapper as? JSONObject else { return nil }
        if let r = wrapper["musicResponsiveListItemRenderer"] as? JSONObject { return listItem(r) }
        if let r = wrapper["musicTwoRowItemRenderer"] as? JSONObject { return twoRowItem(r) }
        if let r = wrapper["playlistPanelVideoRenderer"] as? JSONObject { return panelVideo(r).map(MediaItem.track) }
        if let r = wrapper.o("playlistPanelVideoWrapperRenderer", "primaryRenderer", "playlistPanelVideoRenderer") {
            return panelVideo(r).map(MediaItem.track)
        }
        if let r = wrapper["musicNavigationButtonRenderer"] as? JSONObject { return category(r).map(MediaItem.playlist) }
        if let r = wrapper["musicMultiRowListItemRenderer"] as? JSONObject { return multiRowItem(r) }
        return nil
    }

    static func items(_ list: [Any]) -> [MediaItem] { list.compactMap(item) }

    static func tracks(_ list: [Any]) -> [Track] {
        items(list).compactMap { if case .track(let t) = $0 { t } else { nil } }
    }

    // MARK: Subtitle runs

    /// What we could read out of a "Song • Daft Punk & Todd Edwards • Discovery • 3:47" run list.
    struct Meta {
        var typeLabel: String?
        var artists: [ArtistRef] = []
        var album: AlbumRef?
        var duration: TimeInterval?
        var year: Int?
        /// Counts like "1.2B plays", "68.3M monthly audience", "35 songs".
        var stats: [String] = []
        var plain: [String] = []
    }

    static let typeLabels: Set<String> = [
        "Song", "Video", "Album", "Single", "EP", "Artist", "Playlist", "Episode", "Podcast", "Profile", "Station", "Mix",
    ]

    static func meta(runs: [JSONObject]) -> Meta {
        var meta = Meta()
        // Split into " • " separated segments.
        var segments: [[JSONObject]] = [[]]
        for run in runs {
            let text = run["text"] as? String ?? ""
            if text.trimmingCharacters(in: .whitespaces) == "•" { segments.append([]); continue }
            segments[segments.count - 1].append(run)
        }
        for segment in segments where !segment.isEmpty {
            let text = segment.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespaces)
            let navigable = segment.filter { $0["navigationEndpoint"] != nil }
            if !navigable.isEmpty {
                for run in navigable {
                    let name = run["text"] as? String ?? ""
                    guard let ep = YTEndpoint(run.o("navigationEndpoint")), let id = ep.browseId else {
                        meta.plain.append(name); continue
                    }
                    if id.hasPrefix("MPRE") || ep.pageType == "MUSIC_PAGE_TYPE_ALBUM" {
                        meta.album = AlbumRef(id: id, title: name)
                    } else if id.hasPrefix("UC") || id.hasPrefix("MPLA") || ep.pageType?.contains("ARTIST") == true {
                        meta.artists.append(ArtistRef(id: normalizeArtistID(id), name: name))
                    } else {
                        meta.plain.append(name)
                    }
                }
                continue
            }
            if text.isEmpty { continue }
            if meta.typeLabel == nil, typeLabels.contains(text) { meta.typeLabel = text; continue }
            if let d = YTText.duration(text) { meta.duration = d; continue }
            if YTText.isYear(text) { meta.year = Int(text); continue }
            if isStat(text) { meta.stats.append(text); continue }
            meta.plain.append(text)
        }
        return meta
    }

    static func isStat(_ text: String) -> Bool {
        let lower = text.lowercased()
        let words = ["plays", "views", "subscribers", "monthly", "audience", "songs", "song", "tracks", "episodes", "watching", "listeners", "likes", "videos", "followers"]
        return lower.first?.isNumber == true && words.contains { lower.contains($0) }
    }

    /// Splits an un-linked artist line like "Calvin Harris & Rihanna" into names.
    static func artistNames(_ text: String) -> [ArtistRef] {
        var names = [text]
        for sep in [", ", " & ", " x ", " feat. ", " ft. "] {
            names = names.flatMap { $0.components(separatedBy: sep) }
        }
        return names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { ArtistRef(name: $0) }
    }

    /// Library artist pages are `MPLAUC...`; the artist page itself is `UC...`.
    static func normalizeArtistID(_ id: String) -> String {
        id.hasPrefix("MPLA") ? String(id.dropFirst(4)) : id
    }

    /// Playlist browse ids are `VL<playlistId>`; Medley keeps the bare playlist id.
    static func playlistID(fromBrowseID id: String) -> String {
        id.hasPrefix("VL") ? String(id.dropFirst(2)) : id
    }

    // MARK: Badges and flags

    static func isExplicit(_ r: JSONObject) -> Bool {
        let badges = (r["badges"] as? [Any] ?? []) + (r["subtitleBadges"] as? [Any] ?? [])
        return badges.contains { badge in
            (badge as? JSONObject)?.s("musicInlineBadgeRenderer", "icon", "iconType") == "MUSIC_EXPLICIT_BADGE"
        }
    }

    static func isGreyedOut(_ r: JSONObject) -> Bool {
        (r["musicItemRendererDisplayPolicy"] as? String) == "MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT"
    }

    /// Like status from a menu (signed-in only): "LIKE", "DISLIKE", "INDIFFERENT".
    static func likeStatus(_ r: JSONObject) -> String? {
        (JSONWalk.firstObject("likeButtonRenderer", in: r["menu"]))?["likeStatus"] as? String
    }

    // MARK: musicResponsiveListItemRenderer

    static func listItem(_ r: JSONObject) -> MediaItem? {
        let flex = (r["flexColumns"] as? [Any] ?? []).compactMap {
            ($0 as? JSONObject)?.o("musicResponsiveListItemFlexColumnRenderer", "text")
        }
        let fixed = (r["fixedColumns"] as? [Any] ?? []).compactMap {
            ($0 as? JSONObject)?.o("musicResponsiveListItemFixedColumnRenderer", "text")
        }
        let titleNode = flex.first
        let title = YTText.plain(titleNode) ?? ""
        let rest = flex.dropFirst().flatMap { col -> [JSONObject] in
            // Treat each column as its own " • " segment.
            let runs = YTText.runs(col)
            return runs.isEmpty ? [] : runs + [["text": " • "]]
        }
        var meta = meta(runs: rest)
        for col in fixed { if let d = YTText.duration(YTText.plain(col)) { meta.duration = d } }

        let artwork = YTArtwork.from(r["thumbnail"])
        let titleEndpoint = YTEndpoint(YTText.runs(titleNode).first?.o("navigationEndpoint"))
        let rowEndpoint = YTEndpoint(r.o("navigationEndpoint"))
        let overlayEndpoint = YTEndpoint(r.o("overlay", "musicItemThumbnailOverlayRenderer", "content", "musicPlayButtonRenderer", "playNavigationEndpoint"))

        let videoId = r.s("playlistItemData", "videoId") ?? {
            if case .watch(let id, _, _)? = titleEndpoint { return id }
            if case .watch(let id, _, _)? = rowEndpoint { return id }
            if case .watch(let id, _, _)? = overlayEndpoint { return id }
            return nil
        }()

        if let videoId {
            var videoType: String?
            for ep in [titleEndpoint, rowEndpoint, overlayEndpoint] {
                if case .watch(_, _, let t)? = ep, let t { videoType = t; break }
            }
            if videoType == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE" || meta.typeLabel == "Episode" { return nil }
            return .track(track(videoId: videoId, title: title, meta: meta, artwork: artwork, renderer: r, videoType: videoType))
        }

        guard let ep = rowEndpoint ?? titleEndpoint, case .browse(let browseId, _, let pageType) = ep else {
            // Mixes and radios can be watch-playlist only.
            if case .watchPlaylist(let pid)? = overlayEndpoint ?? rowEndpoint {
                return .playlist(Playlist(providerID: pid, provider: provider, title: title, owner: meta.plain.first ?? meta.artists.first?.name, artwork: artwork))
            }
            return nil
        }
        return browseItem(browseId: browseId, pageType: pageType, title: title, meta: meta, artwork: artwork, renderer: r)
    }

    static func track(videoId: String, title: String, meta: Meta, artwork: Artwork?, renderer r: JSONObject, videoType: String?) -> Track {
        var artists = meta.artists
        if artists.isEmpty, let line = meta.plain.first, meta.typeLabel != "Episode" {
            artists = artistNames(line)
        }
        var extra: [String: String] = [:]
        if let set = r.s("playlistItemData", "playlistSetVideoId") ?? r["playlistSetVideoId"] as? String { extra["setVideoId"] = set }
        if let videoType { extra["musicVideoType"] = videoType }
        if let like = likeStatus(r) { extra["likeStatus"] = like }
        if let plays = meta.stats.first { extra["stats"] = plays }
        let number = YTText.plain(r.o("index")).flatMap { Int($0) }
        return Track(
            providerID: videoId,
            provider: provider,
            title: title,
            artists: artists,
            album: meta.album,
            duration: meta.duration,
            artwork: artwork ?? YTArtwork.forVideo(videoId),
            isExplicit: isExplicit(r),
            isPlayable: !isGreyedOut(r),
            trackNumber: number,
            extra: extra
        )
    }

    static func browseItem(browseId: String, pageType: String?, title: String, meta: Meta, artwork: Artwork?, renderer r: JSONObject) -> MediaItem? {
        let page = pageType ?? ""
        if page == "MUSIC_PAGE_TYPE_ALBUM" || browseId.hasPrefix("MPREb") {
            return .album(album(browseId: browseId, title: title, meta: meta, artwork: artwork, renderer: r))
        }
        if page.contains("ARTIST") || (page.isEmpty && browseId.hasPrefix("UC")) {
            let subtitle = meta.stats.first ?? meta.typeLabel
            return .artist(Artist(providerID: normalizeArtistID(browseId), provider: provider, name: title, artwork: artwork, subtitle: subtitle))
        }
        if page == "MUSIC_PAGE_TYPE_PLAYLIST" || browseId.hasPrefix("VL") {
            let owner = meta.artists.first?.name ?? meta.plain.first
            let count = meta.stats.first { $0.contains("song") || $0.contains("track") }.flatMap(YTText.number)
            var extra: [String: String] = [:]
            if let views = meta.stats.first(where: { $0.contains("view") }) { extra["stats"] = views }
            return .playlist(Playlist(providerID: playlistID(fromBrowseID: browseId), provider: provider, title: title, owner: owner, artwork: artwork, trackCount: count, extra: extra))
        }
        return nil // podcasts, profiles, audiobooks
    }

    static func album(browseId: String, title: String, meta: Meta, artwork: Artwork?, renderer r: JSONObject) -> Album {
        var artists = meta.artists
        if artists.isEmpty, let line = meta.plain.first { artists = artistNames(line) }
        var extra: [String: String] = [:]
        // The album's audio playlist (OLAK5uy_...) is used to save it and to play it.
        if let pid = JSONWalk.all("playlistId", in: r["overlay"] ?? r["thumbnailOverlay"], limit: 1).first as? String
            ?? JSONWalk.all("playlistId", in: r["menu"], limit: 1).first as? String {
            extra["playlistId"] = pid
        }
        return Album(
            providerID: browseId,
            provider: provider,
            title: title,
            artists: artists,
            year: meta.year,
            artwork: artwork,
            kind: albumKind(meta.typeLabel),
            isExplicit: isExplicit(r),
            extra: extra
        )
    }

    static func albumKind(_ label: String?) -> AlbumKind {
        switch label {
        case "Album": .album
        case "Single": .single
        case "EP": .ep
        case "Compilation": .compilation
        default: label == nil ? .album : .unknown
        }
    }

    // MARK: musicTwoRowItemRenderer (cards in carousels and grids)

    static func twoRowItem(_ r: JSONObject) -> MediaItem? {
        let titleNode = r.o("title")
        let title = YTText.plain(titleNode) ?? ""
        let meta = meta(runs: YTText.runs(r.o("subtitle")))
        let artwork = YTArtwork.from(r["thumbnailRenderer"])
        let endpoint = YTEndpoint(r.o("navigationEndpoint")) ?? YTEndpoint(YTText.runs(titleNode).first?.o("navigationEndpoint"))
        switch endpoint {
        case .watch(let videoId, _, let type)?:
            return .track(track(videoId: videoId, title: title, meta: meta, artwork: artwork, renderer: r, videoType: type))
        case .watchPlaylist(let pid)?:
            return .playlist(Playlist(providerID: pid, provider: provider, title: title, owner: meta.plain.first ?? meta.artists.first?.name, artwork: artwork))
        case .browse(let id, _, let pageType)?:
            return browseItem(browseId: id, pageType: pageType, title: title, meta: meta, artwork: artwork, renderer: r)
        case nil:
            return nil
        }
    }

    // MARK: playlistPanelVideoRenderer (watch queue / radio)

    static func panelVideo(_ r: JSONObject) -> Track? {
        guard let videoId = r["videoId"] as? String else { return nil }
        let meta = meta(runs: YTText.runs(r.o("longBylineText")))
        var t = track(videoId: videoId, title: r.text("title") ?? "", meta: meta, artwork: YTArtwork.from(r["thumbnail"]), renderer: r,
                      videoType: { if case .watch(_, _, let type)? = YTEndpoint(r.o("navigationEndpoint")) { type } else { nil } }())
        if let d = YTText.duration(r.text("lengthText")) { t.duration = d }
        if t.artists.isEmpty, let byline = r.text("shortBylineText") { t.artists = artistNames(byline) }
        if r["unplayableText"] != nil { t.isPlayable = false }
        return t
    }

    // MARK: musicMultiRowListItemRenderer (podcast episodes): skipped

    static func multiRowItem(_ r: JSONObject) -> MediaItem? { nil }

    // MARK: Moods & genres

    /// Mood/genre buttons aren't media. They become playlist-shaped entries whose id starts with
    /// `category:`; `YouTubeMusicProvider.playlist(id:)` and `shelf(moreToken:)` understand them.
    static func category(_ r: JSONObject) -> Playlist? {
        guard let title = r.text("buttonText"),
              case .browse(let id, let params, _)? = YTEndpoint(r.o("clickCommand")) else { return nil }
        let token = MoreToken.browse(browseId: id, params: params).encoded
        var extra = ["category": "1", "moreToken": token]
        if let color = r.any(["solid", "leftStripeColor"]) as? Int { extra["color"] = String(format: "#%06X", color & 0xFFFFFF) }
        return Playlist(providerID: "category:" + token, provider: provider, title: title, extra: extra)
    }
}

/// Opaque "See All" / category tokens handed to the UI.
enum MoreToken: Hashable {
    case browse(browseId: String, params: String?)

    var encoded: String {
        switch self {
        case .browse(let id, let params): "browse|\(id)|\(params ?? "")"
        }
    }

    init?(_ string: String) {
        let parts = string.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "browse", !parts[1].isEmpty else { return nil }
        self = .browse(browseId: parts[1], params: parts[2].isEmpty ? nil : parts[2])
    }
}
