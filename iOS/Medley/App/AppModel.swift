import MedleyCore
import MedleySync
import Observation
import SpotifyKit
import SwiftUI
import UIKit
import YouTubeMusicKit

enum AppTab: String, Hashable, CaseIterable {
    case home, new, library, search
}

/// A page pushed on a tab's navigation stack.
enum Route: Hashable {
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)
    /// "See All" for a shelf, or a mood/genre category (an empty shelf with a `moreToken`).
    case shelf(Shelf, ProviderID)
    case library(LibraryKind)
}

enum NowPlayingMode: Hashable {
    case artwork, lyrics, queue
}

/// The iPhone app's single source of truth: providers, the one `PlayerController`, navigation, library state.
///
/// Sync and other features built outside the core screens attach through `player` (a `SyncCoordinator` drives it
/// like any other caller) and through `extensions` (views shown above the mini player and in Now Playing, URL
/// handlers). See `iOS/README.md`.
@MainActor
@Observable
final class AppModel {
    // MARK: Services

    let providers: [any MusicProvider]
    /// The one player. Everything that plays, pauses or queues goes through it.
    let player = PlayerController()
    /// Now Playing and lock screen controls, the audio session, queue persistence and playback settings.
    let playback: PlaybackSystem
    let options: LaunchOptions
    let extensions = AppExtensions()
    /// Medley Sync (the account, handoff, sign-ins, settings). Nil in sample-data runs.
    private(set) var sync: SyncHub?
    /// The first-run flow (`FirstRunView`, full screen): Welcome, Your music, Sync, Approve this device. Set at the
    /// first launch (`FirstRun.shouldShow`); nil once finished or skipped.
    var firstRun: FirstRunFlow?
    @ObservationIgnored let cache = PageCache()

    // MARK: Navigation

    var tab: AppTab = .home
    var paths: [AppTab: [Route]] = [:]
    var isNowPlayingPresented = false
    var nowPlayingMode: NowPlayingMode = .artwork
    var isSettingsPresented = false
    var settingsPath: [SettingsRoute] = []
    /// The provider whose sign-in sheet is up.
    var signInProvider: ProviderID?
    var toast: Toast?
    /// Bumped when sign-in state changes, so library pages reload.
    var refreshTick = 0

    // MARK: Library

    private(set) var likedTrackIDs: Set<String> = []
    /// Like state already asked of the provider this session, so Now Playing asks once per track.
    @ObservationIgnored private var likeChecked: Set<String> = []
    /// Lyrics by track id (nil: the song has none), most recent 60.
    @ObservationIgnored private var lyricsCache = LRUCache<String, Lyrics?>(limit: 60)
    @ObservationIgnored private var lyricsInflight: [String: LyricsRequest] = [:]
    @ObservationIgnored private var memoryWarning: NSObjectProtocol?

    // MARK: Search

    var searchText = ""
    var searchScope: SearchScope = .all
    /// The query whose results are showing; set on submit, not on every keystroke.
    var submittedQuery = ""
    private(set) var recentSearches: [String]
    /// Called when this device's recent searches change (sync uploads them).
    @ObservationIgnored var onRecentSearchesChanged: (([String]) -> Void)?

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var symbol: String = "checkmark.circle.fill"
    }

    // MARK: Init

    init(options: LaunchOptions = .current) {
        self.options = options
        if options.demo {
            // Real chart albums and covers, both services signed in as a made-up listener (Debug builds only).
            MockArtwork.demoDirectory = options.demoArt
            providers = [MockProvider(id: .youtubeMusic, signedIn: !options.signedOut, dataset: .demo), MockProvider(id: .spotify, dataset: .demo)]
        } else if options.mock {
            providers = [MockProvider(id: .youtubeMusic, signedIn: !options.signedOut), MockProvider(id: .spotify, signedIn: false)]
        } else {
            providers = [YouTubeMusicProvider(), SpotifyProvider()]
        }
        for provider in providers { player.register(provider) }
        // Sample-data runs keep their queue and settings apart, so a real launch never restores a mock song.
        let store = options.mock
            ? QueueStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("medley-mock-queue.json"))
            : QueueStore(url: QueueStore.defaultURL)
        let settings = options.mock ? PlaybackSettings(defaults: UserDefaults(suiteName: "medley.mock") ?? .standard) : PlaybackSettings()
        playback = PlaybackSystem(player: player, settings: settings, store: store)
        recentSearches = options.demo ? ["Olivia Rodrigo", "Tate McRae", "the cure"] : options.mock
            ? ["Daft Punk", "Glass Harbor", "Night drive"]
            : UserDefaults.standard.stringArray(forKey: Keys.recentSearches) ?? []
        memoryWarning = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dropCaches() }
        }
    }

    /// Low memory: pages and lyrics reload on demand.
    func dropCaches() {
        cache.removeAll()
        lyricsCache.removeAll()
    }

    private enum Keys {
        static let recentSearches = "recentSearches"
    }

    /// Restores sessions and the saved queue, then starts Now Playing, the audio session and persistence.
    func launch() async {
        // iOS volume is the system volume (buttons, Control Center, MPVolumeView); the player stays at full.
        playback.settings.volume = 1
        if options.mock { await playback.persistence.store.clear() }
        for provider in providers { await provider.restoreSession() }
        await playback.start()
        // The lock screen and Control Center heart follow every track change, not only Now Playing.
        _ = player.addChangeHandler { [weak self] change in
            if change == .track { self?.currentTrackChanged() }
        }
        currentTrackChanged()
        // The first-run flow, decided from what is on this iPhone before any network: a fresh install shows it, one
        // that answered it (or the welcome before it) or restored a service sign-in doesn't. Snapshot runs choose
        // their own screen.
        if !options.isSnapshot, options.selfTest == nil, FirstRun.showAtLaunch(anyServiceSignedIn: providers.contains(where: \.isSignedIn)) {
            firstRun = FirstRunFlow(model: self)
        }
        startSync()
        // URL handlers are in place now: take the links that arrived while sessions were restoring.
        isLaunched = true
        let queued = pendingURLs
        pendingURLs = []
        for url in queued { handle(url: url) }
        await refreshLibraryState()
    }

    /// Sync starts after the providers restored their sessions, so their sign-ins can be compared with the library's.
    private func startSync() {
        guard !options.mock, sync == nil else { return }
        let hub = SyncHub(model: self)
        sync = hub
        #if DEBUG
        if options.syncSelfTest { SyncSelfTest.start(hub) }
        #endif
        hub.start()
    }

    /// The first-run flow finished or was skipped: Home, and the flow never comes back by itself.
    func finishFirstRun() {
        FirstRun.markFinished()
        firstRun = nil
        tab = .home
        sync?.refreshApprovalBanner()
    }

    #if DEBUG
    /// Snapshot runs: show the account screens with a hub that never connects.
    func usePreviewSync(_ hub: SyncHub?) { sync = hub }
    #endif

    /// After switching servers: a new sync session against the new server.
    func restartSync() {
        sync?.stop()
        sync = nil
        startSync()
    }

    // MARK: Providers

    func provider(_ id: ProviderID) -> (any MusicProvider)? { providers.first { $0.id == id } }

    func can(_ capability: ProviderCapabilities, _ id: ProviderID) -> Bool {
        provider(id)?.capabilities.contains(capability) ?? false
    }

    /// Services that can fill Home, New or Search now. YouTube Music works signed out; Spotify needs an account.
    func browseProviders(_ capability: ProviderCapabilities) -> [any MusicProvider] {
        providers.filter { $0.capabilities.contains(capability) && ($0.isSignedIn || $0.id == .youtubeMusic) }
    }

    var libraryProviders: [any MusicProvider] {
        providers.filter { $0.isSignedIn && $0.capabilities.contains(.library) }
    }

    // MARK: Navigation

    func path(_ tab: AppTab) -> Binding<[Route]> {
        Binding(get: { self.paths[tab] ?? [] }, set: { self.paths[tab] = $0 })
    }

    /// Pushes a page on the current tab. From Now Playing, closes it first.
    func open(_ route: Route) {
        if isNowPlayingPresented { isNowPlayingPresented = false }
        paths[tab, default: []].append(route)
    }

    func open(item: MediaItem) {
        switch item {
        case .album(let a): open(.album(a))
        case .artist(let a): open(.artist(a))
        case .playlist(let p): open(.playlist(p))
        case .track(let t): play([t], from: nil)
        }
    }

    /// "Go to Album" / "Go to Artist" for a track, filling in links the list left out.
    func goToAlbum(_ track: Track) {
        Task {
            var track = track
            if track.album?.id == nil, let provider = provider(track.provider) {
                track = (try? await provider.linkedTrack(track)) ?? track
            }
            guard let ref = track.album, let id = ref.id else {
                return show(Toast(text: "No album for this song", symbol: "square.stack"))
            }
            open(.album(Album(providerID: id, provider: track.provider, title: ref.title, artists: track.artists, artwork: track.artwork)))
        }
    }

    func goToArtist(_ track: Track) {
        Task {
            var track = track
            if !track.artists.contains(where: { $0.id != nil }), let provider = provider(track.provider) {
                track = (try? await provider.linkedTrack(track)) ?? track
            }
            guard let ref = track.artists.first(where: { $0.id != nil }), let id = ref.id else {
                return show(Toast(text: "No artist page for this song", symbol: "music.mic"))
            }
            open(.artist(Artist(providerID: id, provider: track.provider, name: ref.name)))
        }
    }

    func presentNowPlaying(_ mode: NowPlayingMode = .artwork) {
        guard player.current != nil else { return }
        nowPlayingMode = mode
        isNowPlayingPresented = true
    }

    /// `medley://` links. Extension handlers (sync's links) get the first look. Links that arrive before
    /// `launch()` installed the handlers (a cold start from a link) wait for it.
    func handle(url: URL) {
        guard isLaunched else {
            if pendingURLs.count < 8 { pendingURLs.append(url) }
            sync?.log?.write("URL queued until launch finishes")
            return
        }
        for handler in extensions.urlHandlers where handler(url) { return }
    }

    @ObservationIgnored private var isLaunched = false
    @ObservationIgnored private var pendingURLs: [URL] = []

    // MARK: Playback

    func play(_ tracks: [Track], startAt index: Int = 0, shuffled: Bool = false, from context: PlaybackContext?) {
        guard !tracks.isEmpty else { return }
        playGeneration += 1
        player.play(tracks, startAt: index, shuffled: shuffled, from: context)
    }

    @ObservationIgnored private var playGeneration = 0
    static let maxPlaylistPages = 40

    /// Plays everything behind an album, playlist or artist.
    func play(_ item: MediaItem, shuffled: Bool = false) {
        Task {
            if case .playlist(let p) = item, let provider = provider(p.provider) {
                do {
                    let detail: PlaylistDetail = try await cached("playlist:\(p.id)") { try await provider.playlist(id: p.providerID) }
                    await playPlaylist(detail.tracks, continuation: detail.continuation, playlist: p, shuffled: shuffled)
                } catch { report(error) }
                return
            }
            guard let (tracks, context) = await tracks(for: item) else { return }
            play(tracks, shuffled: shuffled, from: context)
        }
    }

    /// Starts the loaded part of a playlist at once and appends the rest as it arrives (shuffle loads it all first).
    func playPlaylist(_ loaded: [Track], continuation: String?, playlist: Playlist, startAt index: Int = 0, shuffled: Bool = false) async {
        let context = PlaybackContext.playlist(playlist)
        guard let continuation, let provider = provider(playlist.provider) else {
            return play(loaded, startAt: index, shuffled: shuffled, from: context)
        }
        if shuffled {
            let rest = await remainingPlaylistTracks(after: loaded, continuation: continuation, provider: provider)
            return play(loaded + rest, shuffled: true, from: context)
        }
        play(loaded, startAt: index, from: context)
        let generation = playGeneration
        var seen = Set(loaded.map(\.id))
        var token: String? = continuation
        var pages = 0
        while let t = token, pages < Self.maxPlaylistPages {
            guard let page = try? await provider.playlistTracks(continuation: t) else { return }
            guard generation == playGeneration, player.currentIndex != nil else { return }
            let fresh = page.items.filter { seen.insert($0.id).inserted }
            if !fresh.isEmpty { player.addToQueue(fresh, from: context) }
            token = page.continuation
            pages += 1
        }
    }

    private func remainingPlaylistTracks(after loaded: [Track], continuation: String?, provider: any MusicProvider) async -> [Track] {
        var seen = Set(loaded.map(\.id))
        var out: [Track] = []
        var token = continuation
        var pages = 0
        while let t = token, pages < Self.maxPlaylistPages {
            guard let page = try? await provider.playlistTracks(continuation: t) else { break }
            out += page.items.filter { seen.insert($0.id).inserted }
            token = page.continuation
            pages += 1
        }
        return out
    }

    func playNext(_ item: MediaItem) {
        Task {
            guard let (tracks, context) = await tracks(for: item) else { return }
            player.playNext(tracks, from: context)
            show(Toast(text: "Playing Next", symbol: "text.line.first.and.arrowtriangle.forward"))
        }
    }

    func addToQueue(_ item: MediaItem) {
        Task {
            guard let (tracks, context) = await tracks(for: item) else { return }
            player.addToQueue(tracks, from: context)
            show(Toast(text: "Added to Queue", symbol: "text.line.last.and.arrowtriangle.forward"))
        }
    }

    func startRadio(_ track: Track) {
        guard let provider = provider(track.provider) else { return }
        Task {
            do {
                let tracks = try await provider.radio(seed: track)
                play([track] + tracks.filter { $0.id != track.id },
                     from: .radio(title: track.title, seedID: track.providerID, provider: track.provider))
            } catch { report(error) }
        }
    }

    func startRadio(seedID: String, title: String, provider id: ProviderID) {
        guard let provider = provider(id) else { return }
        Task {
            do {
                play(try await provider.radio(seedID: seedID), from: .radio(title: title, seedID: seedID, provider: id))
            } catch { report(error) }
        }
    }

    /// The tracks behind any item, for play and queue commands.
    func tracks(for item: MediaItem) async -> ([Track], PlaybackContext?)? {
        guard let provider = provider(item.provider) else { return nil }
        do {
            switch item {
            case .track(let t):
                return ([t], nil)
            case .album(let a):
                let detail: AlbumDetail = try await cached("album:\(a.id)") { try await provider.album(id: a.providerID) }
                return (detail.tracks, .album(a))
            case .playlist(let p):
                let detail: PlaylistDetail = try await cached("playlist:\(p.id)") { try await provider.playlist(id: p.providerID) }
                let rest = await remainingPlaylistTracks(after: detail.tracks, continuation: detail.continuation, provider: provider)
                return (detail.tracks + rest, .playlist(p))
            case .artist(let a):
                let detail: ArtistDetail = try await cached("artist:\(a.id)") { try await provider.artist(id: a.providerID) }
                return (detail.topTracks, .artist(a))
            }
        } catch {
            report(error)
            return nil
        }
    }

    /// Reads through the page cache: a hit returns at once (no spinner for cached pages).
    func cached<T: Sendable>(_ key: String, force: Bool = false, _ load: () async throws -> T) async throws -> T {
        if !force, let hit: (value: T, date: Date) = cache.value(for: key) { return hit.value }
        let value = try await load()
        cache.set(value, for: key)
        return value
    }

    func cachedValue<T>(_ key: String) -> T? {
        let hit: (value: T, date: Date)? = cache.value(for: key)
        return hit?.value
    }

    // MARK: Library

    func isLiked(_ track: Track) -> Bool { likedTrackIDs.contains(track.id) }

    func canLike(_ track: Track) -> Bool {
        guard let provider = provider(track.provider) else { return false }
        return provider.isSignedIn && provider.capabilities.contains(.like)
    }

    func toggleLike(_ track: Track) {
        guard canLike(track), let provider = provider(track.provider) else { return }
        let liked = !isLiked(track)
        if liked { likedTrackIDs.insert(track.id) } else { likedTrackIDs.remove(track.id) }
        syncLikeCommand()
        Task {
            do {
                try await provider.setLiked(track, liked: liked)
                cache.invalidate(prefix: "library")
            } catch {
                if liked { likedTrackIDs.remove(track.id) } else { likedTrackIDs.insert(track.id) }
                syncLikeCommand()
                report(error)
            }
        }
    }

    /// Love on the lock screen and in Control Center: offered only when the current track's service can like it
    /// (signed in), lit when it's liked. Runs on every track change, sign-in change and like.
    private func syncLikeCommand() {
        let track = player.current
        let likeable = track.map(canLike) ?? false
        if likeable, playback.nowPlaying.onLike == nil {
            playback.nowPlaying.onLike = { [weak self] track in self?.toggleLike(track) }
        } else if !likeable, playback.nowPlaying.onLike != nil {
            playback.nowPlaying.onLike = nil
        }
        playback.nowPlaying.isCurrentTrackLiked = likeable && (track.map(isLiked) ?? false)
    }

    @ObservationIgnored private var likeLookup: Task<Void, Never>?

    /// A new current track: update the heart now from what's known, then ask the service once.
    private func currentTrackChanged() {
        syncLikeCommand()
        likeLookup?.cancel()
        guard let track = player.current else { return }
        likeLookup = Task { [weak self] in await self?.checkLiked(track) }
    }

    /// Asks the provider once whether the current track is liked (for the Now Playing heart).
    func checkLiked(_ track: Track) async {
        syncLikeCommand()
        guard !likeChecked.contains(track.id), canLike(track), let provider = provider(track.provider) else { return }
        likeChecked.insert(track.id)
        if let liked = try? await provider.isLiked(track) {
            if liked { likedTrackIDs.insert(track.id) } else { likedTrackIDs.remove(track.id) }
            syncLikeCommand()
        }
    }

    func setSaved(_ item: MediaItem, saved: Bool) {
        guard let provider = provider(item.provider) else { return }
        Task {
            do {
                try await provider.setSaved(item, saved: saved)
                cache.invalidate(prefix: "library")
                show(Toast(text: saved ? "Added to Library" : "Removed from Library", symbol: saved ? "plus.circle.fill" : "minus.circle.fill"))
            } catch { report(error) }
        }
    }

    /// Reloads liked songs after sign-in changes, so hearts show without asking per track.
    func refreshLibraryState() async {
        cache.invalidate(prefix: "library")
        cache.invalidate(prefix: "home")
        cache.invalidate(prefix: "new")
        likeChecked = []
        var liked: Set<String> = []
        for provider in libraryProviders {
            if let page = try? await provider.library(.likedSongs, continuation: nil) {
                for case .track(let t) in page.items { liked.insert(t.id) }
            }
        }
        likedTrackIDs = liked
        currentTrackChanged()
        refreshTick += 1
    }

    func signOut(_ id: ProviderID) {
        guard let provider = provider(id) else { return }
        Task {
            // `trySignOut` deletes the saved sign-in first and throws (staying signed in) if that fails.
            do { try await provider.trySignOut() } catch { report(error) }
            await refreshLibraryState()
        }
    }

    func signInFinished() {
        signInProvider = nil
        Task { await refreshLibraryState() }
    }

    // MARK: Search

    func submitSearch(_ query: String? = nil) {
        let q = (query ?? searchText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if let query { searchText = query }
        submittedQuery = q
        recentSearches.removeAll { $0.caseInsensitiveCompare(q) == .orderedSame }
        recentSearches.insert(q, at: 0)
        if recentSearches.count > 12 { recentSearches.removeLast(recentSearches.count - 12) }
        if !options.mock { UserDefaults.standard.set(recentSearches, forKey: Keys.recentSearches) }
        onRecentSearchesChanged?(recentSearches)
    }

    func clearRecentSearches() {
        recentSearches = []
        if !options.mock { UserDefaults.standard.removeObject(forKey: Keys.recentSearches) }
        onRecentSearchesChanged?(recentSearches)
    }

    /// Recent searches from another device (sync). Not sent back.
    func replaceRecentSearches(_ list: [String]) {
        recentSearches = Array(list.prefix(12))
        if !options.mock { UserDefaults.standard.set(recentSearches, forKey: Keys.recentSearches) }
    }

    /// Search results merged across services, in provider order. Cancelling the caller (a newer query replaced
    /// this one) cancels every provider's request too, and a cancelled search throws instead of returning.
    func search(_ query: String, scope: SearchScope) async throws -> SearchResults {
        let tasks = browseProviders(.search).map { provider in Task { try await provider.search(query, scope: scope) } }
        return try await withTaskCancellationHandler {
            var merged = SearchResults()
            var firstError: (any Error)?
            for task in tasks {
                do {
                    let r = try await task.value
                    if merged.top == nil { merged.top = r.top }
                    merged.tracks += r.tracks
                    merged.albums += r.albums
                    merged.artists += r.artists
                    merged.playlists += r.playlists
                } catch {
                    firstError = firstError ?? error
                }
            }
            try Task.checkCancellation()
            if merged.isEmpty, let firstError { throw firstError }
            return merged
        } onCancel: {
            for task in tasks { task.cancel() }
        }
    }

    func suggestions(_ query: String) async -> SearchSuggestions {
        guard let provider = browseProviders(.search).first else { return SearchSuggestions() }
        return (try? await provider.richSearchSuggestions(query)) ?? SearchSuggestions()
    }

    // MARK: Lyrics

    func cachedLyrics(_ track: Track) -> Lyrics?? { lyricsCache.peek(track.id) }

    #if DEBUG
    /// `PerfSelfTest` gives a song realistic (long) lyrics.
    func seedLyricsForTesting(_ lyrics: Lyrics?, for track: Track) { lyricsCache.set(lyrics, for: track.id) }
    #endif

    func lyrics(for track: Track) async throws -> Lyrics? {
        if let hit = lyricsCache.value(for: track.id) { return hit }
        guard let provider = provider(track.provider), provider.capabilities.contains(.lyrics) else { return nil }
        // One request per song: the pane opening while Now Playing's prefetch runs waits for that one. The request
        // is cancelled once every caller waiting on it is cancelled (skipping songs quickly), so abandoned songs
        // don't keep fetching.
        let id = track.id
        let request: LyricsRequest
        if let running = lyricsInflight[id], !running.task.isCancelled {
            request = running
        } else {
            request = LyricsRequest(task: Task { try await provider.lyrics(for: track) })
            lyricsInflight[id] = request
        }
        request.waiters += 1
        defer {
            request.waiters -= 1
            if request.waiters == 0, lyricsInflight[id] === request { lyricsInflight[id] = nil }
        }
        let lyrics = try await withTaskCancellationHandler {
            try await request.task.value
        } onCancel: {
            Task { @MainActor in request.waiterCancelled() }
        }
        lyricsCache.set(lyrics, for: id)
        return lyrics
    }

    /// A lyrics request shared by everyone waiting for the same song.
    @MainActor private final class LyricsRequest {
        let task: Task<Lyrics?, any Error>
        var waiters = 0
        private var cancelled = 0
        init(task: Task<Lyrics?, any Error>) { self.task = task }
        func waiterCancelled() {
            cancelled += 1
            if cancelled >= waiters { task.cancel() }
        }
    }

    /// Fetches the song's lyrics ahead of time (Now Playing calls it when it opens and when the song changes), so
    /// opening the lyrics shows them on the first frame instead of a spinner that swaps mid-transition.
    func prefetchLyrics(_ track: Track) async {
        guard can(.lyrics, track.provider), cachedLyrics(track) == nil else { return }
        _ = try? await lyrics(for: track)
    }

    // MARK: Feedback

    func show(_ toast: Toast) {
        self.toast = toast
        let id = toast.id
        Task {
            try? await Task.sleep(for: .seconds(2))
            if self.toast?.id == id { self.toast = nil }
        }
    }

    func report(_ error: any Error) {
        guard !(error is CancellationError) else { return }
        show(Toast(text: error.localizedDescription, symbol: "exclamationmark.triangle.fill"))
    }
}

/// Loaded pages, so Back and tab switches are instant. Keeps the 120 most recently used; a memory warning empties it.
final class PageCache {
    private var store = LRUCache<String, (value: Any, date: Date)>(limit: 120)

    func value<T>(for key: String) -> (value: T, date: Date)? {
        guard let entry = store.value(for: key), let value = entry.value as? T else { return nil }
        return (value, entry.date)
    }

    func set(_ value: Any, for key: String) { store.set((value, Date()), for: key) }
    func invalidate(prefix: String) { store.removeAll { $0.hasPrefix(prefix) } }
    func removeAll() { store.removeAll() }
}

/// A small least-recently-used cache. `value(for:)` and `set` mark a key as used; past `limit`, the oldest goes.
struct LRUCache<Key: Hashable, Value> {
    let limit: Int
    private var values: [Key: Value] = [:]
    /// Keys, least recently used first.
    private var order: [Key] = []

    init(limit: Int) { self.limit = limit }

    var count: Int { values.count }

    /// Reads without marking the key as used (for view bodies).
    func peek(_ key: Key) -> Value? { values[key] }

    mutating func value(for key: Key) -> Value? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    mutating func set(_ value: Value, for key: Key) {
        if values.updateValue(value, forKey: key) == nil { order.append(key) } else { touch(key) }
        while order.count > limit { values.removeValue(forKey: order.removeFirst()) }
    }

    mutating func removeAll(where shouldRemove: (Key) -> Bool) {
        order.removeAll(where: shouldRemove)
        values = values.filter { !shouldRemove($0.key) }
    }

    mutating func removeAll() {
        values.removeAll()
        order.removeAll()
    }

    private mutating func touch(_ key: Key) {
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
        order.append(key)
    }
}

/// Places other features plug into without editing the core screens.
///
/// - `miniPlayerBanner`: shown just above the mini player on every tab (for example "Continue from Mac").
/// - `nowPlayingAccessory`: shown in Now Playing's bottom bar next to AirPlay (for example a Devices button).
/// - `urlHandlers`: tried in order for `medley://` links; return true to claim the link.
@MainActor
@Observable
final class AppExtensions {
    var miniPlayerBanner: AnyView?
    var nowPlayingAccessory: AnyView?
    @ObservationIgnored var urlHandlers: [@MainActor (URL) -> Bool] = []
}

/// Launch arguments, so `simctl launch <udid> app.medley.MedleyMobile -MedleyMock YES -MedleyScreen album` works.
/// All of them are Debug builds only: read from the command line, never from saved defaults, and compiled out of
/// Release builds, where every option keeps its default (real providers, no test code).
/// - `MedleyMock`: sample data, no network. `demo` instead of `YES`: real chart albums and covers, signed in as a
///   made-up listener, for screenshots (`scripts/demo-shots.sh`); `MedleyDemoArt <dir>` names the downloaded covers.
/// - `MedleySignedOut`: with mock, YouTube Music starts signed out.
/// - `MedleyScreen`: open one screen for a screenshot (see `SnapshotDriver`).
/// - `MedleySelfTest`: `live` runs the live YouTube Music check (see `SelfTest`); `perf`, with mock, records frame
///   timings for the main transitions (see `PerfSelfTest`).
/// - `MedleySyncSelfTest`: logs sync events, takes `medley://test/…` commands and accepts the probe's fake test
///   sign-ins (see `SyncSelfTest`).
/// - `MedleyOpenURL`: Debug builds only. Opens this `medley://` link at once, before launch finished (as a cold
///   start from a link does).
struct LaunchOptions {
    var mock = false
    var demo = false
    var demoArt: URL?
    var signedOut = false
    var screen: String?
    var selfTest: String?
    var syncSelfTest = false
    /// `-MedleySyncJWTFile <path>` (Debug, self-test): sign in to sync with the Clerk JWT in this file.
    var syncJWTFile: URL?
    var openURL: URL?

    static var current: LaunchOptions {
        var options = LaunchOptions()
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let flag = { (name: String) in argument(name, in: arguments).map { ["yes", "1", "true"].contains($0.lowercased()) } ?? false }
        options.mock = flag("MedleyMock") || argument("MedleyMock", in: arguments) == "demo"
        options.demo = argument("MedleyMock", in: arguments) == "demo"
        options.demoArt = argument("MedleyDemoArt", in: arguments).map { URL(fileURLWithPath: $0, isDirectory: true) }
        options.signedOut = flag("MedleySignedOut")
        options.screen = argument("MedleyScreen", in: arguments)
        options.selfTest = argument("MedleySelfTest", in: arguments)
        options.syncSelfTest = flag("MedleySyncSelfTest")
        options.syncJWTFile = argument("MedleySyncJWTFile", in: arguments).map { URL(fileURLWithPath: $0) }
        options.openURL = argument("MedleyOpenURL", in: arguments).flatMap(URL.init(string:))
        #endif
        return options
    }

    /// The value after `-name` on the command line.
    static func argument(_ name: String, in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: "-\(name)"), arguments.indices.contains(i + 1) else { return nil }
        return arguments[i + 1]
    }

    var isSnapshot: Bool { screen != nil }
}
