import Foundation
import Observation
import SwiftUI

/// Offline provider with sample data, for UI work and snapshots without network or accounts.
/// Each `ProviderID` gets its own invented catalog (see `MockCatalog`), so two mocks look like two services.
@MainActor
@Observable
public final class MockProvider: MusicProvider {
    public let id: ProviderID
    /// Settable so tests can take `.playlistInsert` away (a service that can't put a removed song back in place).
    public var capabilities: ProviderCapabilities = [.search, .home, .library, .lyrics, .syncedLyrics, .radio, .like, .playlistEditing, .playlistInsert, .follow, .playback, .explore]
    public private(set) var authStatus: AuthStatus
    public let playbackEngine: any PlaybackEngine = MockPlaybackEngine()
    /// Artificial delay for every call, to exercise loading states.
    public var latency: Duration = .zero
    public private(set) var catalog: MockCatalog
    private var liked: Set<String>
    /// Saved albums and playlists and followed artists, by `MediaItem.id`.
    private var saved: Set<String> = []
    private static let pageSize = 25

    /// `dataset: .demo` (Debug builds only) serves real chart albums signed in as a made-up listener; Release
    /// builds serve the sample data whichever is asked for.
    public init(id: ProviderID, signedIn: Bool = true, dataset: MockDataset = .sample) {
        self.id = id
        let catalog = MockCatalog(provider: id, dataset: dataset)
        self.catalog = catalog
        self.authStatus = signedIn ? .signedIn(Self.account(id, catalog.dataset)) : .signedOut
        // Every fifth song starts out liked.
        self.liked = Set(catalog.allTracks.enumerated().filter { $0.offset % 5 == 0 }.map(\.element.id))
    }

    private static func account(_ id: ProviderID, _ dataset: MockDataset) -> AccountInfo {
        #if DEBUG
        if dataset == .demo {
            return AccountInfo(name: DemoAccount.name, avatar: MockArtwork.url("avatar", DemoAccount.initials), detail: id == .spotify ? "Premium" : "YouTube Music Premium")
        }
        #endif
        return AccountInfo(name: "Sample Listener", avatar: MockArtwork.url("portrait", "me-\(id.rawValue)"), detail: id == .spotify ? "Premium" : "YouTube Music Premium")
    }

    public func restoreSession() async {}

    public func makeSignInView(onFinish: @escaping @MainActor () -> Void) -> AnyView {
        AnyView(MockSignInView(provider: id) { [weak self] in
            guard let self else { return }
            self.authStatus = .signedIn(Self.account(self.id, self.catalog.dataset))
            onFinish()
        } cancel: { onFinish() })
    }

    public func makeSettingsView() -> AnyView {
        AnyView(Section { LabeledContent("Source") { Text("Offline sample catalog").foregroundStyle(.readableSecondary) } } header: { ProviderSettingsHeader() })
    }

    public func signOut() async { authStatus = .signedOut }

    // Test seams for caches keyed by account (`BrowseDiskCache`).
    /// Who requests go out as, when set; otherwise what `authStatus` implies.
    public var sessionOverride: ProviderSession?
    public var session: ProviderSession { sessionOverride ?? .derived(from: authStatus) }
    /// Browse calls (`home`, `explore`) throw this when set.
    public var browseFailure: ProviderError?
    /// Test seams for play requests: an extra wait and a failure for library calls only, and every library call made
    /// ("likedSongs:first", "likedSongs:50").
    public var libraryDelay: Duration = .zero
    public var libraryFailure: ProviderError?
    public private(set) var libraryRequests: [String] = []
    /// Single library pages that throw, by the same "kind:continuation" name ("songs:first", "songs:50"), each
    /// for `times` more calls, so a test can fail a first page, a continuation page or a refresh on its own.
    public var libraryPageFailures: [String: (error: ProviderError, times: Int)] = [:]
    /// Album, artist and playlist pages throw this when set (an error page, such as an expired sign-in).
    public var detailFailure: ProviderError?
    /// Later playlist pages that throw, by continuation token ("<playlist id>|25"), each for `times` more calls.
    public var playlistPageFailures: [String: (error: ProviderError, times: Int)] = [:]
    /// Awaited by every later playlist page before it answers, with its token: a test holds a request here and lets it go.
    public var playlistPageGate: (@MainActor (String) async -> Void)?
    /// Every later playlist page asked for, by token.
    public private(set) var playlistPageRequests: [String] = []
    /// Shows a sign-in in progress, as a real provider does while it still sends the previous account's credentials.
    public func beginSignIn() { authStatus = .signingIn }

    private func delay() async {
        if latency > .zero { try? await Task.sleep(for: latency) }
    }

    private func requireSignIn() throws {
        guard authStatus.isSignedIn else { throw ProviderError.notSignedIn }
    }

    /// When set, likes, saves, follows and playlist edits throw this, to show how the app reports a failed write.
    public var failingWrites: ProviderError?
    /// The most songs one playlist removal or insertion takes (`playlistEditBatchSize`), as Spotify's 100: a test sets
    /// a small one so a removal of a few songs takes several requests.
    public var editBatchSize: Int?
    public var playlistEditBatchSize: Int? { editBatchSize }
    /// Playlist removals and insertions that throw, by their number among those calls (1 is the first), each once.
    public var playlistEditFailures: [Int: ProviderError] = [:]
    /// Every playlist removal and insertion asked for: "remove a, b", "insert a, b at 3".
    public private(set) var playlistEdits: [String] = []
    /// Playlist entries left out of every page, as Spotify leaves out local files and episodes: they still count for
    /// the places of the songs after them (`Page.positions`) and for the total.
    public var unlistedTrackIDs: Set<String> = []
    /// When set, every playlist add, removal and insertion request awaits it before it goes, so a test can hold one in
    /// flight (`"add"`, `"remove"`, `"insert"`).
    public var playlistEditGate: (@MainActor (String) async -> Void)?
    /// The entries `unlistedTrackIDs` leaves out are reported with their identities (`unlistedEntries`), as Spotify
    /// gives local files' and episodes' URIs; true leaves them anonymous, as Spotify's `null` entries are.
    public var unlistedEntriesAnonymous = false
    /// Later playlist pages hand out the token they were asked with again, as a service that loops would.
    public var repeatsContinuations = false
    /// The next playlist add appends its first `after` songs, then throws `error` (once), as an append that stopped
    /// partway.
    public var addFailure: (after: Int, error: ProviderError)?
    /// The account the mock's network side holds right now, as a provider's API actor does (a sign-in can land there
    /// before the main actor's session says so). Nil: the account `session` names.
    public var credentialsAccountID: String?
    /// Every playlist read: "cached <id or token>" through `playlist(id:)`/`playlistTracks`, "fresh …" through the
    /// uncached reads.
    public private(set) var playlistReads: [String] = []

    private func notePlaylistEdit(_ description: String) throws {
        playlistEdits.append(description)
        if let failure = playlistEditFailures.removeValue(forKey: playlistEdits.count) { throw failure }
    }

    /// The entries `offset..<offset + pageSize` of a playlist: the ones listed, with their places, and how many there were.
    private func entries(_ tracks: [Track], from offset: Int) -> (tracks: [Track], positions: [Int]?, count: Int, unlisted: [Int: String]?) {
        let slice = Array(tracks.dropFirst(offset).prefix(Self.pageSize))
        guard !unlistedTrackIDs.isEmpty else { return (slice, nil, slice.count, nil) }
        let listed = slice.enumerated().filter { !unlistedTrackIDs.contains($0.element.id) }
        var unlisted: [Int: String] = [:]
        if !unlistedEntriesAnonymous {
            for (index, track) in slice.enumerated() where unlistedTrackIDs.contains(track.id) { unlisted[offset + index] = "local:\(track.id)" }
        }
        return (listed.map(\.element), listed.map { offset + $0.offset }, slice.count, unlisted.isEmpty ? nil : unlisted)
    }

    private func requireWritable() throws {
        try requireSignIn()
        if let failingWrites { throw failingWrites }
    }

    // MARK: Browse

    public func home() async throws -> [Shelf] {
        await delay()
        if let browseFailure { throw browseFailure }
        let c = catalog
        // Signed out there is no listening to draw on, as on YouTube Music's own signed-out home: charts, new
        // releases and moods, no Listen again, mixes or Liked Music.
        if !authStatus.isSignedIn { return anonymousHome() }
        #if DEBUG
        if c.dataset == .demo { return DemoShelves.home(c) }
        #endif
        let tracks = c.allTracks
        if id == .youtubeMusic {
            return [
                Shelf(id: "yt-quick", title: "Quick picks", style: .trackList, items: stride(from: 3, to: tracks.count, by: 3).prefix(16).map { .track(tracks[$0]) }, moreToken: "quick"),
                Shelf(id: "yt-listen", title: "Listen again", style: .carousel, items: (c.albums.prefix(4).map(MediaItem.album) + c.playlists.prefix(4).map(MediaItem.playlist)), moreToken: "listen"),
                Shelf(id: "yt-mixed", title: "Mixed for you", subtitle: "Mixes made from your listening", style: .hero, items: c.playlists.filter { !$0.isEditable }.map(MediaItem.playlist)),
                Shelf(id: "yt-albums", title: "Albums for you", style: .carousel, items: c.albums.dropFirst(6).prefix(12).map(MediaItem.album), moreToken: "albums"),
                Shelf(id: "yt-artists", title: "Artists you listen to", style: .artists, items: c.artists.map(MediaItem.artist)),
            ]
        } else {
            return [
                Shelf(id: "sp-made", title: "Made For You", subtitle: "Mixes updated daily", style: .hero, items: c.playlists.filter { !$0.isEditable }.map(MediaItem.playlist)),
                Shelf(id: "sp-jump", title: "Jump back in", style: .carousel, items: c.albums.suffix(10).map(MediaItem.album), moreToken: "jump"),
                Shelf(id: "sp-top", title: "Your top songs this month", style: .trackList, items: stride(from: 1, to: tracks.count, by: 4).prefix(12).map { .track(tracks[$0]) }),
                Shelf(id: "sp-artists", title: "Your top artists", style: .artists, items: c.artists.reversed().map(MediaItem.artist)),
                Shelf(id: "sp-recent", title: "Recently played", style: .carousel, items: c.playlists.prefix(6).map(MediaItem.playlist) + c.albums.prefix(4).map(MediaItem.album)),
            ]
        }
    }

    /// Home for a listener who isn't signed in: nothing personal.
    private func anonymousHome() -> [Shelf] {
        let c = catalog
        let p = id.short
        let moods = Self.moods.map { MediaItem.playlist(category($0.name, color: $0.color)) }
        #if DEBUG
        if c.dataset == .demo { return DemoShelves.anonymousHome(c, moods: moods) }
        #endif
        let tracks = c.allTracks
        return [
            Shelf(id: "\(p)-top", title: "Top songs", style: .trackList, items: stride(from: 0, to: tracks.count, by: 2).prefix(12).map { .track(tracks[$0]) }, moreToken: "charts"),
            Shelf(id: "\(p)-new", title: "New releases", style: .carousel, items: c.albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }.prefix(14).map(MediaItem.album), moreToken: "new"),
            Shelf(id: "\(p)-moods", title: "Moods & genres", style: .carousel, items: moods, moreToken: "moods"),
            Shelf(id: "\(p)-popular", title: "Popular artists", style: .artists, items: c.artists.map(MediaItem.artist)),
        ]
    }

    public func explore() async throws -> [Shelf] {
        await delay()
        if let browseFailure { throw browseFailure }
        let c = catalog
        #if DEBUG
        if c.dataset == .demo { return DemoShelves.explore(c, moods: Self.moods.map { .playlist(category($0.name, color: $0.color)) }) }
        #endif
        let tracks = c.allTracks
        let prefix = id.short
        var rng = SeededRandom(seed: fnv1a(prefix))
        return [
            Shelf(id: "\(prefix)-new", title: "New releases", style: .carousel, items: c.albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }.prefix(14).map(MediaItem.album), moreToken: "new"),
            Shelf(id: "\(prefix)-moods", title: "Moods & genres", style: .carousel, items: Self.moods.map { .playlist(category($0.name, color: $0.color)) }, moreToken: "moods"),
            Shelf(id: "\(prefix)-charts", title: id == .spotify ? "Top 50 · Global" : "Top songs", style: .trackList, items: stride(from: 0, to: tracks.count, by: 2).prefix(16).map { .track(tracks[$0]) }, moreToken: "charts"),
            Shelf(id: "\(prefix)-singles", title: "New singles & EPs", style: .carousel, items: c.albums.filter { $0.kind != .album }.map(MediaItem.album)),
            Shelf(id: "\(prefix)-rising", title: "Rising artists", style: .artists, items: c.artists.shuffled(using: &rng).map(MediaItem.artist)),
        ]
    }

    public func shelf(moreToken: String) async throws -> Shelf {
        await delay()
        let c = catalog
        if moreToken.hasPrefix("mood:") {
            let name = String(moreToken.dropFirst("mood:".count))
            var rng = SeededRandom(seed: fnv1a(name))
            return Shelf(id: moreToken, title: name, style: .carousel, items: c.playlists.shuffled(using: &rng).map(MediaItem.playlist))
        }
        switch moreToken {
        case "moods":
            return Shelf(id: moreToken, title: "Moods & genres", style: .carousel, items: Self.moods.map { .playlist(category($0.name, color: $0.color)) })
        case "quick", "charts":
            var songs = Array(c.allTracks.prefix(50))
            #if DEBUG
            if c.dataset == .demo { songs = DemoShelves.chart(c) + c.allTracks.filter { !DemoShelves.chart(c).contains($0) }.prefix(20) }
            #endif
            return Shelf(id: moreToken, title: moreToken == "quick" ? "Quick picks" : "Top songs", style: .trackList, items: songs.map(MediaItem.track))
        case "listen", "jump":
            return Shelf(id: moreToken, title: moreToken == "jump" ? "Jump back in" : "Listen again", style: .carousel, items: c.albums.map(MediaItem.album) + c.playlists.map(MediaItem.playlist))
        default:
            return Shelf(id: moreToken, title: moreToken == "new" ? "New releases" : "Albums for you", style: .carousel, items: c.albums.map(MediaItem.album))
        }
    }

    /// Mood/genre entries, shaped like YouTube Music's (`extra["category"]`, a "#RRGGBB" stripe color, a browse token).
    private static let moods: [(name: String, color: String)] = [
        ("Chill", "#5FA8D3"), ("Commute", "#F2A541"), ("Energize", "#F25F5C"), ("Feel good", "#FFE066"),
        ("Focus", "#6A8EAE"), ("Party", "#C86BFA"), ("Romance", "#FF8FAB"), ("Sleep", "#3D348B"),
        ("Workout", "#E4572E"), ("Hip-hop", "#76B041"), ("Pop", "#FF5D8F"), ("Rock", "#8C5E58"),
        ("Jazz", "#2E86AB"), ("Classical", "#C9ADA7"),
    ]

    private func category(_ name: String, color: String) -> Playlist {
        Playlist(providerID: "category:mood:\(name)", provider: id, title: name, extra: ["category": "1", "color": color, "moreToken": "mood:\(name)"])
    }

    // MARK: Search

    public func search(_ query: String, scope: SearchScope) async throws -> SearchResults {
        await delay()
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return SearchResults() }
        let c = catalog
        func hit(_ s: String) -> Bool { s.lowercased().contains(q) }
        let artists = c.artists.filter { hit($0.name) }
        let artistIDs = Set(artists.map(\.providerID))
        let tracks = c.allTracks.filter { hit($0.title) || $0.artists.contains { hit($0.name) } || hit($0.album?.title ?? "") }
        let albums = c.albums.filter { hit($0.title) || artistIDs.contains($0.artists.first?.id ?? "") }
        let playlists = c.playlists.filter { hit($0.title) || hit($0.summary ?? "") }
        let top: MediaItem? = artists.first.map(MediaItem.artist) ?? albums.first.map(MediaItem.album) ?? tracks.first.map(MediaItem.track) ?? playlists.first.map(MediaItem.playlist)
        var results = SearchResults(top: top, tracks: Array(tracks.prefix(20)), albums: Array(albums.prefix(16)), artists: Array(artists.prefix(12)), playlists: Array(playlists.prefix(12)))
        switch scope {
        case .all: break
        case .songs: results = SearchResults(tracks: Array(tracks.prefix(50)))
        case .albums: results = SearchResults(albums: albums)
        case .artists: results = SearchResults(artists: artists)
        case .playlists: results = SearchResults(playlists: playlists)
        }
        return results
    }

    public func searchSuggestions(_ query: String) async throws -> [String] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        let c = catalog
        let names = c.artists.map(\.name) + c.albums.map(\.title) + c.allTracks.map(\.title)
        var seen = Set<String>()
        return names.filter { $0.lowercased().hasPrefix(q) || $0.lowercased().contains(" \(q)") }
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(6).map { $0 }
    }

    /// Completions plus the artists and albums that match, the way YouTube Music sends them.
    public func richSearchSuggestions(_ query: String) async throws -> SearchSuggestions {
        let queries = try await searchSuggestions(query)
        let q = query.lowercased()
        guard !q.isEmpty else { return SearchSuggestions() }
        func matches(_ s: String) -> Bool { s.lowercased().hasPrefix(q) || s.lowercased().contains(" \(q)") }
        let c = catalog
        let artists = c.artists.filter { matches($0.name) }.prefix(2).map(MediaItem.artist)
        let albums = c.albums.filter { matches($0.title) || matches($0.artistLine) }.prefix(2).map(MediaItem.album)
        return SearchSuggestions(queries: Array(queries.prefix(4)), items: Array(artists) + Array(albums))
    }

    // MARK: Entities

    public func album(id albumID: String) async throws -> AlbumDetail {
        await delay()
        if let detailFailure { throw detailFailure }
        let c = catalog
        guard var album = c.album(albumID) else { throw ProviderError.notFound }
        // The saved flag as YouTube Music's toggle button reports it.
        album.extra["saved"] = saved.contains(MediaItem.album(album).id) ? "1" : "0"
        let tracks = c.albumTracks[albumID] ?? []
        let minutes = Int(tracks.compactMap(\.duration).reduce(0, +) / 60)
        let more = c.albums(by: album.artists.first?.id ?? "").filter { $0.providerID != albumID }
        let date = "\(["January", "March", "April", "June", "September", "October", "November"][Int(fnv1a(albumID) % 7)]) \(1 + albumID.count % 27), \(album.year ?? 2024)"
        if c.dataset == .demo {
            // Real albums: their real release date and label line, and no invented liner notes.
            let released = album.extra["released"].flatMap { try? Date($0 + "T12:00:00Z", strategy: .iso8601) }
            let day = released.map { $0.formatted(.dateTime.month(.wide).day().year().locale(Locale(identifier: "en_US"))) } ?? date
            return AlbumDetail(
                album: album, tracks: tracks,
                footnote: "\(day)\n\(tracks.count) song\(tracks.count == 1 ? "" : "s"), \(minutes) minute\(minutes == 1 ? "" : "s")\n\(album.extra["copyright"] ?? "")",
                moreByArtist: more.isEmpty ? Array(c.albums.prefix(6)) : more
            )
        }
        return AlbumDetail(
            album: album, tracks: tracks,
            summary: album.kind == .album ? "A warm, widescreen record built from late-night demos, tape loops and a borrowed upright piano. Most of it was tracked live in a converted church hall over two winter weeks, with the band sharing two microphones and a single reel of tape. The songs drift between hushed ballads and loose, swinging grooves, held together by the piano's warped tuning and the room's long natural reverb. Strings were added later, recorded one player at a time in a kitchen." : nil,
            footnote: "\(date)\n\(tracks.count) song\(tracks.count == 1 ? "" : "s"), \(minutes) minute\(minutes == 1 ? "" : "s")\n℗ \(album.year ?? 2024) \(album.artistLine) under exclusive license to Sample Records",
            moreByArtist: more.isEmpty ? Array(c.albums.prefix(5)) : more
        )
    }

    public func artist(id artistID: String) async throws -> ArtistDetail {
        await delay()
        if let detailFailure { throw detailFailure }
        let c = catalog
        guard let artist = c.artist(artistID) else { throw ProviderError.notFound }
        let all = c.albums(by: artistID)
        let index = c.artists.firstIndex(of: artist) ?? 0
        let related = (1...6).map { c.artists[(index + $0 * 3) % c.artists.count] }.filter { $0 != artist }
        return ArtistDetail(
            artist: artist,
            topTracks: Array(c.tracks(by: artistID).prefix(10)),
            albums: all.filter { $0.kind == .album },
            singles: all.filter { $0.kind != .album },
            playlists: Array(c.playlists.filter { !$0.isEditable }.prefix(3)),
            related: Array(Set(related)).sorted { $0.name < $1.name },
            bio: c.bios[artistID],
            radioSeed: "radio-\(artistID)",
            isFollowed: saved.contains(MediaItem.artist(artist).id)
        )
    }

    public func playlist(id playlistID: String) async throws -> PlaylistDetail {
        playlistReads.append("cached \(playlistID)")
        return try await detail(playlistID)
    }

    public func uncachedPlaylist(id playlistID: String) async throws -> PlaylistDetail {
        playlistReads.append("fresh \(playlistID)")
        return try await detail(playlistID)
    }

    public func playlistTracks(continuation: String) async throws -> Page<Track> {
        playlistReads.append("cached \(continuation)")
        return try await page(continuation)
    }

    public func uncachedPlaylistTracks(continuation: String) async throws -> Page<Track> {
        playlistReads.append("fresh \(continuation)")
        return try await page(continuation)
    }

    private func detail(_ playlistID: String) async throws -> PlaylistDetail {
        await delay()
        if let detailFailure { throw detailFailure }
        let c = catalog
        guard var playlist = c.playlist(playlistID) else { throw ProviderError.notFound }
        if !playlist.isEditable { playlist.extra["saved"] = saved.contains(MediaItem.playlist(playlist).id) ? "1" : "0" }
        let tracks = c.playlistTracks[playlistID] ?? []
        let first = entries(tracks, from: 0)
        return PlaylistDetail(playlist: playlist, tracks: first.tracks, continuation: tracks.count > Self.pageSize ? "\(playlistID)|\(Self.pageSize)" : nil,
                              positions: first.positions, entryCount: first.positions == nil ? nil : first.count, unlistedEntries: first.unlisted)
    }

    private func page(_ continuation: String) async throws -> Page<Track> {
        playlistPageRequests.append(continuation)
        await delay()
        if let playlistPageGate { await playlistPageGate(continuation) }
        if let failure = playlistPageFailures[continuation], failure.times > 0 {
            playlistPageFailures[continuation] = failure.times == 1 ? nil : (failure.error, failure.times - 1)
            throw failure.error
        }
        let parts = continuation.split(separator: "|")
        guard parts.count == 2, let offset = Int(parts[1]) else { throw ProviderError.decoding("bad continuation") }
        let tracks = catalog.playlistTracks[String(parts[0])] ?? []
        let page = entries(tracks, from: offset)
        let next = offset + Self.pageSize
        let token = repeatsContinuations ? continuation : (next < tracks.count ? "\(parts[0])|\(next)" : nil)
        return Page(items: page.tracks, continuation: token,
                    positions: page.positions, entryCount: page.positions == nil ? nil : page.count, unlistedEntries: page.unlisted)
    }

    // MARK: Library

    public func library(_ kind: LibraryKind, continuation: String?) async throws -> Page<MediaItem> {
        try requireSignIn()
        libraryRequests.append("\(kind.rawValue):\(continuation ?? "first")")
        await delay()
        if libraryDelay > .zero { try? await Task.sleep(for: libraryDelay) }
        if let libraryFailure { throw libraryFailure }
        let pageName = "\(kind.rawValue):\(continuation ?? "first")"
        if let failure = libraryPageFailures[pageName], failure.times > 0 {
            libraryPageFailures[pageName] = failure.times == 1 ? nil : (failure.error, failure.times - 1)
            throw failure.error
        }
        let c = catalog
        let items: [MediaItem] = switch kind {
        case .likedSongs: c.allTracks.filter { liked.contains($0.id) }.map(MediaItem.track)
        case .songs: c.allTracks.enumerated().filter { $0.offset % 2 == 0 || liked.contains($0.element.id) }.map { .track($0.element) }
        case .albums: c.albums.enumerated().filter { $0.offset % 3 != 1 }.map { .album($0.element) }
        case .artists: c.artists.map(MediaItem.artist)
        case .playlists: c.playlists.map(MediaItem.playlist)
        case .recentlyPlayed: stride(from: 5, to: c.allTracks.count, by: 7).prefix(16).map { .track(c.allTracks[$0]) }
        }
        let offset = Int(continuation ?? "0") ?? 0
        let page = 50
        let slice = Array(items.dropFirst(offset).prefix(page))
        return Page(items: slice, continuation: offset + page < items.count ? String(offset + page) : nil)
    }

    public func setLiked(_ track: Track, liked isLiked: Bool) async throws {
        try requireWritable()
        if isLiked { liked.insert(track.id) } else { liked.remove(track.id) }
    }

    public func isLiked(_ track: Track) async throws -> Bool { liked.contains(track.id) }

    public func setSaved(_ item: MediaItem, saved isSaved: Bool) async throws {
        try requireWritable()
        if isSaved { saved.insert(item.id) } else { saved.remove(item.id) }
    }

    public func createPlaylist(title: String, description: String?) async throws -> Playlist {
        try await createPlaylist(title: title, description: description, bound: nil)
    }

    public func createPlaylist(title: String, description: String?, as account: PlaylistWriteAccount) async throws -> Playlist {
        try await createPlaylist(title: title, description: description, bound: account)
    }

    private func createPlaylist(title: String, description: String?, bound account: PlaylistWriteAccount?) async throws -> Playlist {
        if let playlistEditGate { await playlistEditGate("create") }
        try checkBinding(account)
        try requireSignIn()
        let playlist = Playlist(
            providerID: "\(id.short)-new-\(UUID().uuidString.prefix(8))", provider: id, title: title, owner: catalog.dataset == .demo ? DemoAccountName.value : "Sample Listener",
            artwork: MockArtwork.artwork("art", "new-\(title)"), trackCount: 0, summary: description, isEditable: true
        )
        catalog.addPlaylist(playlist)
        return playlist
    }

    public func add(_ tracks: [Track], toPlaylist playlistID: String) async throws {
        try await add(tracks, toPlaylist: playlistID, bound: nil)
    }

    public func add(_ tracks: [Track], toPlaylist playlistID: String, as account: PlaylistWriteAccount) async throws {
        try await add(tracks, toPlaylist: playlistID, bound: account)
    }

    public func remove(_ tracks: [Track], fromPlaylist playlistID: String, as account: PlaylistWriteAccount) async throws {
        try await remove(tracks, fromPlaylist: playlistID, bound: account)
    }

    public func insert(_ tracks: [Track], intoPlaylist playlistID: String, at position: Int, as account: PlaylistWriteAccount) async throws {
        try await insert(tracks, intoPlaylist: playlistID, at: position, bound: account)
    }

    /// Where a real provider's network side picks a request's credentials (after the gate, which stands for the hop
    /// there): a bound write goes only while the account they belong to is the one it was checked for. A sign-in swap
    /// in progress (`.changing`) still holds the old account's credentials there, as an API actor does until the new
    /// token lands; `credentialsAccountID` puts another account's there early.
    private func checkBinding(_ account: PlaylistWriteAccount?) throws {
        guard let account else { return }
        let held: Bool
        if let credentialsAccountID {
            held = account.accountID == credentialsAccountID
        } else {
            switch session.identity {
            case .changing: held = true
            case .account(let id): held = account.accountID.map { $0 == id } ?? (session == account.session)
            case .signedOut: held = false
            }
        }
        guard held else { throw PlaylistEditError.accountChanged }
    }

    private func add(_ tracks: [Track], toPlaylist playlistID: String, bound account: PlaylistWriteAccount?) async throws {
        if let playlistEditGate { await playlistEditGate("add") }
        try checkBinding(account)
        try requireWritable()
        if let failure = addFailure {
            addFailure = nil
            catalog.append(Array(tracks.prefix(failure.after)), to: playlistID)
            throw failure.error
        }
        catalog.append(tracks, to: playlistID)
    }

    /// Like Spotify's: every occurrence of each song goes, in requests of `editBatchSize` songs, each its own call
    /// for `playlistEditFailures` (a failing request leaves the earlier ones done, as on the service).
    public func remove(_ tracks: [Track], fromPlaylist playlistID: String) async throws {
        try await remove(tracks, fromPlaylist: playlistID, bound: nil)
    }

    private func remove(_ tracks: [Track], fromPlaylist playlistID: String, bound account: PlaylistWriteAccount?) async throws {
        try requireWritable()
        for chunk in Self.requests(tracks, editBatchSize) {
            if let playlistEditGate { await playlistEditGate("remove") }
            try checkBinding(account)
            try notePlaylistEdit("remove \(chunk.map(\.providerID).joined(separator: ", "))")
            catalog.remove(Set(chunk.map(\.id)), from: playlistID)
        }
    }

    /// Like Spotify's: the songs from `position` on, in requests of `editBatchSize` songs (the second at `position`
    /// plus the first's count, and so on).
    public func insert(_ tracks: [Track], intoPlaylist playlistID: String, at position: Int) async throws {
        try await insert(tracks, intoPlaylist: playlistID, at: position, bound: nil)
    }

    private func insert(_ tracks: [Track], intoPlaylist playlistID: String, at position: Int, bound account: PlaylistWriteAccount?) async throws {
        guard capabilities.contains(.playlistInsert) else { throw ProviderError.notSupported("Adding songs at a position in a playlist") }
        try requireWritable()
        var at = position
        for chunk in Self.requests(tracks, editBatchSize) {
            if let playlistEditGate { await playlistEditGate("insert") }
            try checkBinding(account)
            try notePlaylistEdit("insert \(chunk.map(\.providerID).joined(separator: ", ")) at \(at)")
            catalog.insert(chunk, at: at, into: playlistID)
            at += chunk.count
        }
    }

    private static func requests(_ tracks: [Track], _ size: Int?) -> [[Track]] {
        guard let size, size > 0, tracks.count > size else { return [tracks] }
        return stride(from: 0, to: tracks.count, by: size).map { Array(tracks[$0..<min($0 + size, tracks.count)]) }
    }

    // MARK: Playback support

    public func radio(seed: Track) async throws -> [Track] {
        var rng = SeededRandom(seed: fnv1a("radio-\(seed.id)"))
        return Array(catalog.allTracks.filter { $0.id != seed.id }.shuffled(using: &rng).prefix(15))
    }

    public func radio(seedID: String) async throws -> [Track] {
        var rng = SeededRandom(seed: fnv1a("radio-\(seedID)"))
        let artistID = seedID.replacingOccurrences(of: "radio-", with: "")
        let own = catalog.tracks(by: artistID)
        return Array((own.shuffled(using: &rng).prefix(6) + catalog.allTracks.shuffled(using: &rng).prefix(14)).prefix(20))
    }

    public func lyrics(for track: Track) async throws -> Lyrics? {
        await delay()
        return catalog.lyrics(for: track)
    }

    // MARK: Sample data (kept for older callers)

    public func sampleTracks(_ count: Int = 12, seed: String = "t") -> [Track] {
        Array(catalog.allTracks.prefix(count))
    }
}

/// The demo listener's name where code is compiled in both configurations (Release has no demo data).
enum DemoAccountName {
    #if DEBUG
    static let value = DemoAccount.name
    #else
    static let value = "Sample Listener"
    #endif
}

/// A stand-in sign-in sheet for mock mode.
struct MockSignInView: View {
    let provider: ProviderID
    let finish: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Sign in to \(provider.displayName)")
                .font(.title2.bold())
            Text("This is the offline sample account. No data leaves this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Sign In", action: finish)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(32)
        .frame(width: 380)
    }
}

/// Simulates playback with a timer. No audio.
@MainActor
public final class MockPlaybackEngine: PlaybackEngine {
    public var onEvent: (@MainActor (PlaybackEvent) -> Void)?
    public var volume: Float = 1
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval?
    private var timer: Timer?
    /// Track ids (`Track.id`) whose load throws, to test what happens when a stream can't be resolved.
    public var failingTrackIDs: Set<String> = []

    public init() {}

    public func load(_ track: Track, startAt: TimeInterval, autoplay: Bool) async throws {
        timer?.invalidate()
        if failingTrackIDs.contains(track.id) { throw ProviderError.notFound }
        duration = track.duration ?? 200
        currentTime = startAt
        onEvent?(.time(current: startAt, duration: duration))
        if autoplay { play() } else { onEvent?(.state(.paused)) }
    }

    public func play() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        onEvent?(.state(.playing))
    }

    private func tick() {
        currentTime += 0.5
        onEvent?(.time(current: currentTime, duration: duration))
        if let duration, currentTime >= duration {
            timer?.invalidate()
            onEvent?(.state(.ended))
            onEvent?(.finished)
        }
    }

    public func pause() { timer?.invalidate(); onEvent?(.state(.paused)) }
    public func stop() { timer?.invalidate(); currentTime = 0; onEvent?(.state(.idle)) }
    public func seek(to seconds: TimeInterval) { currentTime = seconds; onEvent?(.time(current: seconds, duration: duration)) }
    public func prepareNext(_ track: Track?) {}
}
