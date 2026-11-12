import AppKit
import OpenMusicCore
import OpenMusicSync
import Observation
import os
import SpotifyKit
import SwiftUI
import YouTubeMusicKit

/// The app's single source of truth: providers, the player, navigation and library state.
@MainActor
@Observable
final class AppModel {
    // MARK: Services

    let providers: [any MusicProvider]
    let player = PlayerController()
    /// Now Playing + media keys, queue persistence, output devices, playback settings.
    let playback: PlaybackSystem
    let isMock: Bool
    let snapshotDirectory: URL?
    @ObservationIgnored let cache = PageCache()
    /// The sidebar's Pinned and Recently Played collections.
    let collections: SidebarCollections
    @ObservationIgnored weak var mainWindow: NSWindow? {
        didSet { if mainWindow !== oldValue { watchMainWindowResize() } }
    }
    @ObservationIgnored private var mainWindowObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var columnLimitsScheduled = false
    /// Watches the sidebar's split view item for anything that shows it through AppKit directly
    /// (`showSidebarBesidePanel`).
    @ObservationIgnored private var sidebarColumnObservation: NSKeyValueObservation?
    @ObservationIgnored private weak var observedSidebarItem: NSSplitViewItem?
    /// Window actions that decide the main window's size and don't go through `setFrame`: live resizes and full
    /// screen. With `SidebarAnimationGuard.frameRequests`, the stamp of `WidthCorrection`.
    @ObservationIgnored private var windowActions = 0
    /// The width correction after showing the sidebar closed a panel (`fitPanelBesideShownSidebar`), and its id.
    @ObservationIgnored private var widthCorrection: (id: Int, correction: WidthCorrection)?
    /// Whether View › Show/Hide Sidebar can act: the main window is open and key or main, and has its sidebar
    /// column. `SidebarCommands`' item was disabled otherwise.
    private(set) var canToggleSidebar = false
    /// Frames of a few views, recorded only in snapshot mode so the runner can click them.
    @ObservationIgnored var debugFrames: [String: CGRect] = [:]
    /// Snapshot checks set this to run one step the way a person would: animated, with real window full screen.
    @ObservationIgnored var snapshotActsLive = false
    /// OpenMusic Sync: the OpenMusic account, handoff, sign-ins and settings across devices. Nil in sample-data and snapshot runs,
    /// and until `launch()` has restored the providers' sessions.
    private(set) var sync: SyncHub?
    /// SwiftUI's `openSettings`, captured from the main window so code outside a view can bring Settings up.
    @ObservationIgnored var openSettingsAction: (() -> Void)?

    var serviceFilter: ServiceFilter {
        didSet {
            UserDefaults.standard.set(serviceFilter.rawValue, forKey: "serviceFilter")
            // A pinned playlist the filter now hides has no row: its row under Playlists (or the pin again) lights.
            if serviceFilter != oldValue { reselectCanonicalRow() }
        }
    }

    // MARK: Navigation

    var sidebarSelection: SidebarItem? = .home {
        didSet {
            // One highlighted row per playlist page, whichever row asked for it (`canonicalSidebarSelection`).
            let canonical = canonicalSidebarSelection(sidebarSelection)
            if canonical != sidebarSelection { sidebarSelection = canonical }
            if sidebarSelection != oldValue { path = []; forwardPath = []; navigationCommitted() }
        }
    }
    /// Pages pushed on top of the sidebar page. A plain array rendered by `DetailStack`;
    /// AppKit's NavigationStack didn't relayout pushed pages when the inspector opened.
    var path: [Route] = [] {
        didSet { if path != oldValue { navigationCommitted() } }
    }
    /// Pages popped with Back, for Forward.
    private(set) var forwardPath: [Route] = []
    var inspector: InspectorPanel? {
        didSet {
            if inspector == nil, oldValue != nil {
                normalizePanelBeforeClose()
                lastInspectorClose = (Date(), echoed: false)
            }
            if inspector != nil, oldValue == nil { lastInspectorOpen = Date() }
            fitInspector(opening: inspector != nil && oldValue == nil, closing: inspector == nil && oldValue != nil)
            if inspector != oldValue, inspector != nil { sizeInspector(for: inspector, opening: oldValue == nil) }
            if inspector == nil, oldValue != nil { restoreInspectorIdeal() }
        }
    }
    /// The panel column's ideal width (`.inspectorColumnWidth`), chosen as the panel opens: lyrics in a wide window
    /// open at their reading width, everything else at `InspectorMetrics.idealWidth`. It changes in the update that
    /// opens the panel and back to the ideal once the panel has closed, never while a panel shows (`sizeInspector`).
    private(set) var inspectorIdealWidth: CGFloat = InspectorMetrics.idealWidth
    /// The panel column's maximum (`.inspectorColumnWidth`): the room it has beside the sidebar and the page as it
    /// opens, at most `InspectorMetrics.maxWidth` (`fitInspector`). Set only in the update that opens the panel and
    /// back to the maximum once it has closed, like `inspectorIdealWidth`.
    private(set) var inspectorMaxWidth: CGFloat = InspectorMetrics.maxWidth
    var columnVisibility: NavigationSplitViewVisibility = .all {
        didSet {
            if oldValue == .detailOnly, columnVisibility != .detailOnly { showSidebarBesidePanel(fromAppKit: false) }
        }
    }
    /// The main window's width, so narrow layouts can make room (inspector, toolbar).
    var windowWidth: CGFloat = 1280
    /// The main window's height, so short windows can show less of a shelf (Home's Quick picks).
    var windowHeight: CGFloat = 820
    @ObservationIgnored private var collapsedSidebarForInspector = false
    /// The panel was widened for lyrics (`sizeInspector`), so the queue puts it back to its ideal width.
    @ObservationIgnored private var widenedForLyrics = false
    /// Bumped by every inspector open or close, so a delayed sidebar restore from an earlier close gives up.
    @ObservationIgnored private var sidebarRestoreGeneration = 0
    var isFullScreenPlayerPresented = false

    /// Brings the full-screen player up or takes it away, animated: the one path for the artwork, the expand button,
    /// the close button, Escape and Controls › Full Screen Player (⇧⌘F). With Reduce Motion it's a short crossfade
    /// (`Motion.Transition.fullScreenPlayer` is a fade then).
    func setFullScreenPlayerPresented(_ presented: Bool, reduceMotion: Bool = Motion.reducesMotion) {
        guard presented != isFullScreenPlayerPresented else { return }
        withAnimation(.easeOut(duration: Motion.fullScreenToggleDuration(opening: presented, reduce: reduceMotion))) {
            isFullScreenPlayerPresented = presented
        }
    }

    /// What the full-screen player shows beside the artwork: lyrics, Playing Next, or nothing (artwork and controls
    /// centered). Remembered apart from the window's `inspector`, so lyrics full screen and the queue in the window
    /// each stay where the listener left them.
    var fullScreenPanel: InspectorPanel? = AppModel.storedFullScreenPanel() {
        didSet { UserDefaults.standard.set(fullScreenPanel?.rawValue ?? "none", forKey: Self.fullScreenPanelKey) }
    }
    /// The first-run flow over the main window (`FirstRunView`): Welcome, Your music, Sync, Approve this device. Set
    /// at the first launch (`FirstRun.shouldShow`) and by Settings › General's "Show Again…"; nil once finished or
    /// skipped.
    var firstRun: FirstRunFlow?
    /// Whether the first-run flow is up. Setting it true starts the flow at Welcome; false closes it without marking
    /// it finished (snapshot runs).
    var showOnboarding: Bool {
        get { firstRun != nil }
        set {
            if newValue { if firstRun == nil { firstRun = FirstRunFlow(model: self) } } else { firstRun = nil }
        }
    }
    /// A service's own sign-in sheet over the main window, asked for from Home's or New's Sign In menu.
    var signInRequest: ProviderID?
    /// The Settings pane to show the next time Settings opens or comes forward (see `openSettings(_:)`).
    private(set) var settingsRequest: SettingsRequest?
    var newPlaylistRequest: NewPlaylistRequest?
    var notice: Notice?
    /// Per playlist (`playlistKey`), an edit that isn't idle: requests in flight (a removal reading its places or
    /// sending requests, a Try Again, an Undo, an add), or a partly applied edit waiting on the listener. Only these
    /// lock a playlist; notices never do (`PlaylistEditState`).
    private(set) var playlistEdits: [String: PlaylistEditState] = [:]
    /// The one settled playlist edit whose Undo is available (Edit › Undo and its notice), if any: single-level.
    @ObservationIgnored private var undoablePlaylistEdit: PlaylistEdit?
    /// Counts registrations of a playlist Undo; a deferred one (`registerUndoAtTopLevel`) runs only while it is the newest.
    @ObservationIgnored private var undoRegistrations = 0
    /// The playlist edit whose put-back found the playlist changed outside OpenMusic, while its notice offers Add Back at
    /// End. Any new playlist edit drops it, as it does an Undo (`purgePlaylistUndo`).
    @ObservationIgnored private var driftedEdit: PlaylistEdit?
    /// Per service, the target its playlist edits' Undo is registered with (`purgePlaylistUndo`).
    @ObservationIgnored private var playlistUndoTargets: [ProviderID: PlaylistUndoTarget] = [:]
    /// The services' sessions are watched for playlist edits (`watchEditAccounts`), from the first edit on.
    @ObservationIgnored private var watchesEditAccounts = false
    /// The mini player window is open (`MiniPlayerView` sets it), so a notice for it has somewhere to show.
    var isMiniPlayerOpen = false
    /// How long a notice stays. The council capture holds one longer so the shot catches it.
    @ObservationIgnored var noticeDuration: Duration = .seconds(2.2)
    /// How a confirmation waits out its time before it goes: the clock, which tests replace with one they advance.
    @ObservationIgnored var noticeSleep: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// The newest confirmation's expiry, which tests await.
    @ObservationIgnored private(set) var noticeExpiry: Task<Void, Never>?
    #if DEBUG
    /// Council captures only: the play buttons act as if the stream were buffering, to show the ring.
    var debugForcesBuffering = false
    #endif
    /// The newest drop's work (resolving its songs, then adding or queueing them), which tests await.
    @ObservationIgnored var lastDrop: Task<Void, Never>?
    /// The newest playlist edit's run (a removal, its Try Again or an Undo), which tests await.
    @ObservationIgnored private(set) var lastPlaylistEdit: Task<Void, Never>?
    /// An offer shown above the player capsule, like "Continue from iPhone" (see `PlayerBanner`).
    var playerBanner: PlayerBanner?
    /// The song whose album "Go to Album" (or the player bar's title) is looking up, for a small spinner.
    private(set) var resolvingAlbumTrackID: String?
    /// Bumped by "Try Again" and View > Refresh to reload visible pages.
    var refreshTick = 0
    /// Bumped per page key when the service's copy changed (a song removed from or put back in a playlist): an open
    /// page with that key loads again in place (`Loadable`).
    private(set) var pageVersions: [String: Int] = [:]

    // MARK: Search

    /// The sidebar search field. Editing it from any page shows that query's results (see `searchTextChanged`).
    var searchText = "" {
        didSet { if searchText != oldValue { searchTextChanged(from: oldValue) } }
    }
    var searchScope: SearchScope = .all {
        didSet { if searchScope != oldValue { navigationCommitted() } }
    }
    var searchFocused = false
    /// The field text the suggestion popover was closed for: opening a result, picking a suggestion,
    /// Return, or any other navigation closes it and keeps the query. It opens again only once the text
    /// changes by the user's editing. nil while suggestions may show.
    private(set) var suggestionsDismissedFor: String?
    /// True while the popover stays closed for the current text.
    var suggestionsDismissed: Bool { suggestionsDismissedFor == searchText }
    /// Set while typing in the search field brings the results page forward, which isn't a navigation the
    /// listener committed to, so it leaves the suggestions open.
    @ObservationIgnored private var followingTyping = false
    private(set) var recentSearches: [String] = UserDefaults.standard.stringArray(forKey: "recentSearches") ?? []
    /// Called when the listener's recent searches change here (sync uploads them). Not called for
    /// `replaceRecentSearches`, so another device's list isn't sent back.
    @ObservationIgnored var onRecentSearchesChanged: (([String]) -> Void)?
    /// Search results by (query, scope, services). Lives here, not in the page, so Back from a result
    /// shows the same rows instantly.
    @ObservationIgnored private(set) lazy var searchResults = SearchResultsStore(cache: cache) { [unowned self] key in
        await self.fetchSearch(key)
    }
    /// What the search field currently offers, so picking one can be told apart from typing.
    @ObservationIgnored var offeredSuggestions = SearchFieldSuggestions()

    /// Services that can search right now. Spotify needs an account; YouTube Music searches signed out.
    var searchProviders: [any MusicProvider] {
        activeProviders.filter { $0.capabilities.contains(.search) && ($0.isSignedIn || $0.id == .youtubeMusic) }
    }

    /// Services the filter includes that would search once signed in, for one quiet "Connect" link.
    var searchProvidersNeedingSignIn: [any MusicProvider] {
        let ready = Set(searchProviders.map(\.id))
        return activeProviders.filter { $0.capabilities.contains(.search) && !ready.contains($0.id) }
    }

    /// Services that can fill Home or New right now. A signed-out service isn't asked: its "sign in" answer
    /// isn't a failure to show, just a quiet "Connect" link (`browseProvidersNeedingSignIn`).
    func browseProviders(_ capability: ProviderCapabilities) -> [any MusicProvider] {
        activeProviders.filter { $0.capabilities.contains(capability) && ($0.isSignedIn || $0.id == .youtubeMusic) }
    }

    /// Services the filter includes that would add to Home or New once signed in.
    func browseProvidersNeedingSignIn(_ capability: ProviderCapabilities) -> [any MusicProvider] {
        let ready = Set(browseProviders(capability).map(\.id))
        return activeProviders.filter { $0.capabilities.contains(capability) && !ready.contains($0.id) }
    }

    func searchKey(for query: String) -> SearchKey {
        SearchKey(query: query, scope: searchScope, services: searchProviders.map(\.id))
    }

    /// True while the search results page is the visible page (not a page pushed on top of it).
    var isShowingSearchResults: Bool { sidebarSelection == .search && path.isEmpty }

    /// Brings the search results to the front: from any sidebar page or any pushed album, artist or playlist.
    /// A search started away from the results page starts on Top Results.
    func showSearchResults() {
        guard !isShowingSearchResults else { return }
        searchScope = .all
        isFullScreenPlayerPresented = false
        if sidebarSelection != .search { sidebarSelection = .search }
        path = []
        forwardPath = []
    }

    /// Return in the search field (or the magnifying glass): record the query and show its results.
    func submitSearch() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        recordSearch(q)
        dismissSuggestions()
        // Picking the artist suggestion can also count as a submit; keep the artist page it just opened.
        if let pick = artistPick, pick.name == q, Date().timeIntervalSince(pick.date) < 1 { return }
        showSearchResults()
    }

    @ObservationIgnored private var artistPick: (name: String, date: Date)?

    /// The listener acted on the current query's results (opened or played one): remember the query,
    /// as Spotify does, even if they never pressed Return.
    func searchResultUsed() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { recordSearch(q) }
        dismissSuggestions()
    }

    /// Closes the suggestion popover for the current text (see `suggestionsDismissedFor`).
    func dismissSuggestions() {
        if suggestionsDismissedFor != searchText { suggestionsDismissedFor = searchText }
    }

    /// Opening a page, going back or forward, switching sidebar pages or result scopes.
    private func navigationCommitted() {
        if !followingTyping { dismissSuggestions() }
    }

    private func searchTextChanged(from old: String) {
        // Any edit may show suggestions again; a pick below closes them for its own text.
        if suggestionsDismissedFor != nil { suggestionsDismissedFor = nil }
        // Picking the direct artist suggestion: clean the field, then open the artist over its results.
        if searchText.last == SearchFieldSuggestions.artistMarker {
            let name = String(searchText.dropLast())
            let artist = offeredSuggestions.artist
            searchText = name
            followingTyping = true
            showSearchResults()
            followingTyping = false
            recordSearch(name)
            dismissSuggestions()
            if let artist {
                artistPick = (name, Date())
                open(.artist(artist.provider, id: artist.providerID, preview: artist))
            }
            return
        }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = old.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, q != before else { return }
        followingTyping = true
        showSearchResults()
        followingTyping = false
        // Picking a query completion fills the field in one step (not one typed character); record it
        // like a submitted search.
        let typedOneCharacter = q.count == before.count + 1 && q.lowercased().hasPrefix(before.lowercased())
        if !typedOneCharacter, offeredSuggestions.queries.contains(where: { $0.caseInsensitiveCompare(q) == .orderedSame }) {
            recordSearch(q)
            dismissSuggestions()
        }
    }

    /// Every service in the key, asked at once. Each request runs to completion even if the page goes
    /// away, so going Back finds the results cached.
    private func fetchSearch(_ key: SearchKey) async -> [ProviderResult<SearchResults>] {
        let tasks = key.services.compactMap { id in provider(id) }.map { p in
            (p.id, Task { [query = key.query, scope = key.scope] in try await p.search(query, scope: scope) })
        }
        var out: [ProviderResult<SearchResults>] = []
        for (id, task) in tasks {
            do { out.append(.init(provider: id, value: try await task.value, error: nil)) } catch { out.append(.init(provider: id, value: nil, error: error.localizedDescription)) }
        }
        return out
    }

    /// "Go to Album", and the player bar's title, for any song. With the album linked it opens at once. Otherwise
    /// the service is asked (the player bar shows a spinner meanwhile, and a notice appears if it takes a moment),
    /// then the album opens; a song on no album (a music video, say) opens its artist with a notice saying so.
    /// A failed lookup says so instead of doing nothing.
    /// Bumped by every album lookup, so only the newest one may navigate or clear the spinner.
    @ObservationIgnored private var albumLookupGeneration = 0

    func goToAlbumResolving(_ track: Track) {
        if track.album?.id != nil { return goToAlbum(of: track) }
        guard resolvingAlbumTrackID != track.id else { return }
        albumLookupGeneration &+= 1
        let generation = albumLookupGeneration
        // Where the listener was when they asked. If they go somewhere else meanwhile, the answer is dropped.
        let startPath = path, startSidebar = sidebarSelection, startFullScreen = isFullScreenPlayerPresented
        resolvingAlbumTrackID = track.id
        let finding = Notice(text: "Finding the album…", symbol: "square.stack")
        Task {
            // Only a lookup that takes a moment gets the notice; a cached one just opens.
            try? await Task.sleep(for: .milliseconds(350))
            if resolvingAlbumTrackID == track.id { notice = finding }
        }
        Task {
            defer {
                if albumLookupGeneration == generation { resolvingAlbumTrackID = nil }
                if notice?.id == finding.id { notice = nil }
            }
            let linked: Track
            do {
                linked = try await linkedTrackThrowing(track)
                guard albumLookupGeneration == generation, path == startPath, sidebarSelection == startSidebar,
                      isFullScreenPlayerPresented == startFullScreen else { return }
            } catch {
                guard albumLookupGeneration == generation else { return }
                report(error, doing: "Couldn’t find the album of “\(track.title)”", service: track.provider, retry: { self.goToAlbumResolving(track) })
                return
            }
            if let album = linked.album, let id = album.id {
                openAlbum(linked.provider, id: id)
            } else if let artist = linked.artists.first(where: { $0.id != nil }) {
                goToArtist(artist, provider: linked.provider)
                show(Notice(text: "This song isn't on an album", symbol: "square.stack"))
            } else {
                show(Notice(text: "This song isn't on an album", symbol: "square.stack"))
            }
        }
    }

    /// "Go to Artist" for a song whose artist isn't linked in this listing.
    func goToArtistResolving(_ track: Track) {
        if let artist = track.artists.first(where: { $0.id != nil }) { return goToArtist(artist, provider: track.provider) }
        Task {
            let linked = await linkedTrack(track)
            if let artist = linked.artists.first(where: { $0.id != nil }) {
                goToArtist(artist, provider: linked.provider)
            } else {
                show(Notice(text: "No artist page for this song", symbol: "music.mic"))
            }
        }
    }

    /// `track` with its album, linked artists and length filled in by the service when its listing left
    /// them out (one cached request per song). Used by Go to Album/Artist and the Top Results song cards.
    func linkedTrack(_ track: Track) async -> Track {
        (try? await linkedTrackThrowing(track)) ?? track
    }

    /// `linkedTrack`, passing on a failed request instead of answering with the listing as it was.
    func linkedTrackThrowing(_ track: Track) async throws -> Track {
        guard let provider = provider(track.provider) else { return track }
        if let hit: (value: Track, date: Date) = cache.value(for: "linked:\(track.id)") { return hit.value }
        let linked = try await provider.linkedTrack(track)
        cache.set(linked, for: "linked:\(track.id)")
        return linked
    }

    // MARK: Library state

    /// Playlists in each signed-in service's library, for the sidebar and "Add to Playlist".
    private(set) var libraryPlaylists: [ProviderID: [Playlist]] = [:]
    /// Track ids (`Track.id`) the user has liked.
    private(set) var likedTrackIDs: Set<String> = []
    /// One saved (album, playlist) or followed (artist) state per collection, keyed by `MediaItem.id` (provider and
    /// id): what the service last said on a page, or what the listener asked for, shown at once. Read through
    /// `isSaved(_:)`.
    private(set) var savedStates: [String: Bool] = [:]
    /// What the service last confirmed per collection, to roll a refused change back to.
    @ObservationIgnored private var confirmedSaved: [String: Bool] = [:]
    /// The latest save/unsave request per collection this session (a counter); present once the listener changed it.
    @ObservationIgnored private var savedWrites: [String: Int] = [:]
    /// What the current queue was started from, e.g. "Glass Harbor".
    private(set) var playingFrom: PlayingFrom?
    private var lyricsCache: [String: Lyrics?] = [:]

    struct PlayingFrom: Hashable {
        var title: String
        var route: Route?
    }

    struct NewPlaylistRequest: Identifiable {
        let id = UUID()
        let provider: ProviderID
        let tracks: [Track]
    }

    /// A confirmation ("Added to queue") goes after `noticeDuration`. A failure stays until the listener closes it
    /// (or a newer notice replaces it), and a write that can work on a second attempt carries `retry` for its
    /// Try Again button.
    struct NoticeAction {
        let title: String
        let run: @MainActor () -> Void
    }

    struct Notice: Identifiable, Equatable {
        enum Kind { case confirmation, failure }
        let id = UUID()
        let text: String
        var symbol: String = "checkmark.circle.fill"
        var kind: Kind = .confirmation
        var retry: (@MainActor () -> Void)?
        /// A button on a confirmation ("Undo" after a removal); the notice then stays a little longer and takes clicks.
        var action: NoticeAction?
        /// A last button, after Try Again: "Leave As Is" on a partly applied playlist edit.
        var secondaryAction: NoticeAction?
        /// The playlist edit this notice is about (its outcome, its Undo, its Try Again).
        var edit: PlaylistEdit?
        /// The account a playlist edit's notice belongs to (its edit's, when it has one): it goes when that service's
        /// session changes, so none of its buttons acts as another account.
        var account: PlaylistEditAccount?
        /// Shown in the mini player rather than the main window: it was the window in use (`show(_:)`).
        var inMiniPlayer = false

        static func == (a: Notice, b: Notice) -> Bool { a.id == b.id }
    }

    // MARK: Init

    init(environment: [String: String] = LaunchEnvironment.current) {
        // Snapshot runs (`SnapshotRunner`) exist in Debug builds only; a Release build never enters snapshot mode.
        #if DEBUG
        snapshotDirectory = environment["OPENMUSIC_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        #else
        snapshotDirectory = nil
        #endif
        // OPENMUSIC_MOCK=demo (Debug builds only): real chart albums and cover art, signed in as a made-up listener,
        // for screenshots (scripts/demo-shots.sh). OPENMUSIC_DEMO_ART names the downloaded art (scripts/demo-art.sh).
        var dataset = MockDataset.sample
        #if DEBUG
        if environment["OPENMUSIC_MOCK"] == "demo" {
            dataset = .demo
            MockArtwork.demoDirectory = environment["OPENMUSIC_DEMO_ART"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        #endif
        isMock = environment["OPENMUSIC_MOCK"] == "1" || dataset == .demo
        if isMock {
            let latency = Int(environment["OPENMUSIC_MOCK_LATENCY"] ?? "") ?? 0
            let mocks = ProviderID.allCases.map { MockProvider(id: $0, dataset: dataset) }
            for mock in mocks { mock.latency = .milliseconds(latency) }
            providers = mocks
        } else {
            providers = [YouTubeMusicProvider(), SpotifyProvider()]
        }
        serviceFilter = snapshotDirectory == nil ? ServiceFilter(rawValue: UserDefaults.standard.string(forKey: "serviceFilter") ?? "") ?? .all : .all
        for provider in providers { player.register(provider) }
        // Sample-data and snapshot runs keep their queue in a temporary file, so a later real launch
        // never restores a mock song.
        let store = isMock || snapshotDirectory != nil
            ? QueueStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("openmusic-mock-queue-\(ProcessInfo.processInfo.processIdentifier).json"))
            : QueueStore(url: QueueStore.defaultURL)
        playback = PlaybackSystem(player: player, store: store)
        collections = SidebarCollections(url: isMock || snapshotDirectory != nil
            // One file per model, so sample-data runs (and parallel tests) each start with an empty sidebar.
            ? FileManager.default.temporaryDirectory.appendingPathComponent("openmusic-mock-sidebar-\(UUID().uuidString).json")
            : SidebarCollections.defaultURL)
    }

    /// Called once at launch: restore saved sessions, then load library state.
    func launch() async {
        for provider in providers { await provider.restoreSession() }
        if snapshotDirectory == nil {
            playback.nowPlaying.onLike = { [weak self] track in self?.toggleLike(track) }
            playback.nowPlaying.willRunTransportCommand = { [weak self] in self?.noteTransportChoice() }
            await playback.start()
        }
        // The first-run flow, decided from what is on this Mac before any network: a fresh install shows it, one
        // that answered it (or the welcome sheets before it) or restored a service sign-in doesn't. Snapshot runs
        // never show it by themselves.
        if snapshotDirectory == nil, FirstRun.showAtLaunch(anyServiceSignedIn: providers.contains(where: \.isSignedIn)) {
            firstRun = FirstRunFlow(model: self)
        }
        startSync()
    }

    /// The first-run flow finished or was skipped: Home, and the flow never comes back by itself.
    func finishFirstRun() {
        FirstRun.markFinished()
        firstRun = nil
        select(.home)
        mainWindow?.makeFirstResponder(nil)
    }

    /// Sync starts once the providers restored their sessions, so their sign-ins can be compared with the library's.
    private func startSync() {
        guard !isMock, snapshotDirectory == nil, sync == nil else { return }
        let hub = SyncHub(model: self, options: .init())
        sync = hub
        hub.start()
    }

    #if DEBUG
    /// Snapshot runs: show the account screens with a hub that never connects.
    func usePreviewSync(_ hub: SyncHub?) {
        if sync !== hub { sync?.keyPrompter?.stop() }
        sync = hub
    }
    #endif

    /// After switching servers: a new sync session against the new server.
    func restartSync() {
        sync?.stop()
        sync = nil
        startSync()
    }

    /// Reload sidebar playlists and liked songs. Called at launch and whenever sign-in state changes.
    func refreshLibraryState() async {
        // The service filter only shows (in the sidebar footer) with two services signed in; with one, it's All.
        // Before any request, so a hidden filter never keeps pages filtered to a signed-out service.
        if providers.filter(\.isSignedIn).count < 2, serviceFilter != .all { serviceFilter = .all }
        cache.invalidate(prefix: "library")
        cache.invalidate(prefix: "home")
        for provider in providers {
            // Saved and followed states belong to the account they were read or set under.
            forgetSavedStates(for: provider.id)
            guard provider.isSignedIn, provider.capabilities.contains(.library) else {
                libraryPlaylists[provider.id] = nil
                likedTrackIDs = likedTrackIDs.filter { !$0.hasPrefix(provider.id.rawValue + ":") }
                continue
            }
            if let page = try? await provider.library(.playlists, continuation: nil) {
                libraryPlaylists[provider.id] = page.items.compactMap { if case .playlist(let p) = $0 { p } else { nil } }
            }
            if provider.capabilities.contains(.like), let page = try? await provider.library(.likedSongs, continuation: nil) {
                let ids = page.items.compactMap { if case .track(let t) = $0 { t.id } else { nil } }
                likedTrackIDs.formUnion(ids)
            }
        }
    }

    /// A key that changes whenever any provider signs in or out.
    var authKey: String {
        providers.map { "\($0.id.rawValue)=\($0.isSignedIn)" }.joined(separator: ",")
    }

    // MARK: Providers

    func provider(_ id: ProviderID) -> (any MusicProvider)? { providers.first { $0.id == id } }

    func can(_ capability: ProviderCapabilities, _ id: ProviderID) -> Bool {
        provider(id)?.capabilities.contains(capability) ?? false
    }

    /// Providers that match the service filter.
    var activeProviders: [any MusicProvider] { providers.filter { serviceFilter.includes($0.id) } }

    /// Active providers that are signed in and have a library.
    var libraryProviders: [any MusicProvider] {
        activeProviders.filter { $0.isSignedIn && $0.capabilities.contains(.library) }
    }

    var anySignedIn: Bool { providers.contains(where: \.isSignedIn) }

    /// Service marks on items only help when more than one service has content on screen.
    /// YouTube Music browses and plays signed out; Spotify needs an account.
    var showsServiceMarks: Bool {
        activeProviders.filter { $0.isSignedIn || $0.id == .youtubeMusic }.count > 1
    }

    func editablePlaylists(_ id: ProviderID) -> [Playlist] {
        (libraryPlaylists[id] ?? []).filter(\.isEditable)
    }

    /// The services' playlists under Playlists, less each service's own liked-songs list ("Liked Music"): Library ›
    /// Liked Songs is the one liked entry, and plays both services' likes. All Playlists still lists them.
    var sidebarPlaylists: [Playlist] {
        let lists = libraryProviders.map { (libraryPlaylists[$0.id] ?? []).filter { !$0.isLikedSongs } }
        return interleave(lists)
    }

    // MARK: Navigation

    func open(_ route: Route) {
        isFullScreenPlayerPresented = false
        path.append(route)
        forwardPath = []
    }

    var canGoBack: Bool { !path.isEmpty }
    var canGoForward: Bool { !forwardPath.isEmpty }

    func goBack() {
        guard let last = path.popLast() else { return }
        forwardPath.append(last)
    }

    func goForward() {
        guard let next = forwardPath.popLast() else { return }
        path.append(next)
    }

    func open(_ item: MediaItem) {
        if case .track(let t) = item {
            play([t], from: nil)
        } else if let route = Route.for(item) {
            open(route)
        }
    }

    func goToArtist(_ ref: ArtistRef, provider: ProviderID) {
        guard let id = ref.id else { return }
        open(.artist(provider, id: id, preview: nil))
    }

    func goToAlbum(of track: Track) {
        guard let album = track.album, let id = album.id else { return }
        openAlbum(track.provider, id: id)
    }

    /// Opens an album page, unless it's the page already on screen (a second copy on the stack looked like
    /// nothing happened, and made Back go nowhere).
    func openAlbum(_ provider: ProviderID, id: String) {
        isFullScreenPlayerPresented = false
        if case .album(let p, let shown, _) = path.last, p == provider, shown == id { return }
        open(.album(provider, id: id, preview: nil))
    }

    func goToCurrentSong() {
        guard let track = player.current else { return }
        isFullScreenPlayerPresented = false
        if let route = playingFrom?.route {
            if path.last != route { open(route) }
        } else {
            goToAlbumResolving(track)
        }
    }

    func select(_ item: SidebarItem) {
        isFullScreenPlayerPresented = false
        sidebarSelection = item
        path = []
    }

    /// ⌘F: the "Find in playlist" field of the page on screen if it has one, else the sidebar search.
    /// Pressing it again (or while that field has focus) goes to the sidebar search.
    ///
    /// "Has focus" is read from the window's first responder, not from the field's own report, which can
    /// outlive the field. And focus moves in AppKit first: while the sidebar search field (AppKit's, behind
    /// `.searchable`) is first responder, a SwiftUI focus request for the page field changed nothing, so
    /// the next keystrokes replaced the search query and left the playlist (seen live only).
    func focusSearch() {
        if pageFindOwner != nil, !pageFindHasFocus, !isFullScreenPlayerPresented {
            if let window = mainWindow, let field = Self.pageFindField(in: window) {
                window.makeFirstResponder(field)
            }
            pageFindFocusRequest += 1
            return
        }
        isFullScreenPlayerPresented = false
        if columnVisibility == .detailOnly { return revealSearch() }
        searchFocused = true
    }

    /// The sidebar is collapsed, so its search field isn't on screen (`.searchable(placement: .sidebar)` has nowhere
    /// else to go): bring the sidebar back and focus the field once it has animated in. The toolbar's search button
    /// and ⌘F both land here. A panel open in a window too narrow for the sidebar beside it
    /// (`SplitViewTuning.sidebarFitsBesidePanel`, the rule every way of showing the sidebar follows) closes first, so
    /// the three columns are never shown together where they don't fit.
    func revealSearch() {
        isFullScreenPlayerPresented = false
        guard columnVisibility == .detailOnly else { searchFocused = true; return }
        var delay = 0.0
        if inspector != nil, !SplitViewTuning.sidebarFitsBesidePanel(windowWidth: mainWindow?.contentView?.bounds.width ?? windowWidth,
                                                                    panelWidth: SplitViewTuning.inspectorWidth(in: mainWindow) ?? 0) {
            // This restore shows the sidebar itself, after the panel's close animation (as `fitInspector` waits).
            collapsedSidebarForInspector = false
            inspector = nil
            delay = 0.3
        }
        // A newer panel open or close (which bumps the generation) cancels the rest.
        sidebarRestoreGeneration &+= 1
        let generation = sidebarRestoreGeneration
        let stillWanted: () -> Bool = { [weak self] in self?.sidebarRestoreGeneration == generation }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, stillWanted() else { return }
            SplitViewTuning.showSidebarKeepingWidth(in: self.mainWindow) { [weak self] in
                self?.columnVisibility == .all
            } stillWanted: {
                stillWanted()
            } sync: { [weak self] in
                self?.columnVisibility = .all
            }
            // After the sidebar's slide-in (and SwiftUI's binding), so the field exists to take focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, stillWanted(), self.columnVisibility != .detailOnly else { return }
                self.searchFocused = true
                // The SwiftUI request can arrive before AppKit has put the field back in the window; ask AppKit too.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let window = self?.mainWindow, !Self.sidebarSearchHasFocus(in: window),
                          let field = Self.sidebarSearchField(in: window) else { return }
                    window.makeFirstResponder(field)
                }
            }
        }
    }

    /// Whether the sidebar's search field is the window's first responder (its field editor is).
    static func sidebarSearchHasFocus(in window: NSWindow) -> Bool {
        if window.firstResponder is NSSearchField { return true }
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return false }
        return editor.delegate is NSSearchField
    }

    /// The sidebar's search field (AppKit's, behind `.searchable`), if it's in the window and visible.
    static func sidebarSearchField(in window: NSWindow) -> NSSearchField? {
        guard let root = window.contentView else { return nil }
        func find(_ view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField, !field.isHiddenOrHasHiddenAncestor { return field }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        // The search field may live in the toolbar's view tree, outside the content view.
        return find(root.superview ?? root)
    }

    /// Whether the page's Find field holds keyboard focus right now, read from the window: a text field
    /// that isn't the sidebar's search field, while a page has a Find field.
    private var pageFindHasFocus: Bool {
        guard pageFindOwner != nil else { return false }
        guard let editor = mainWindow?.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSTextField else { return false }
        return !(field is NSSearchField)
    }

    /// The page's Find field in the window: an editable text field that isn't a search field, preferring
    /// one whose placeholder is "Find in …" (`TrackFilterField`).
    static func pageFindField(in window: NSWindow) -> NSTextField? {
        guard let root = window.contentView else { return nil }
        var fields: [NSTextField] = []
        func walk(_ view: NSView) {
            if let f = view as? NSTextField, !(f is NSSearchField), f.isEditable, !f.isHiddenOrHasHiddenAncestor { fields.append(f) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return fields.first { $0.placeholderString?.hasPrefix("Find in") == true } ?? (fields.count == 1 ? fields[0] : nil)
    }

    // MARK: Find in page

    /// The "Find in playlist" field on screen, if any. Only the top page is alive, so there is at most one.
    @ObservationIgnored private var pageFindOwner: UUID?
    /// Bumped by ⌘F to focus the page's field.
    private(set) var pageFindFocusRequest = 0

    /// A new page's field starts unfocused, whatever the previous page's field last reported.
    func registerPageFind(_ owner: UUID) {
        pageFindOwner = owner
    }

    func unregisterPageFind(_ owner: UUID) {
        guard pageFindOwner == owner else { return }
        pageFindOwner = nil
    }

    /// View › Show/Hide Sidebar (⌃⌘S). Showing the sidebar beside an open panel sets `columnVisibility`, as the
    /// toolbar's button does, so the rule in `showSidebarBesidePanel` runs before AppKit lays the column out; anything
    /// else goes to the split view, as `SidebarCommands` did.
    func toggleSidebar() {
        guard canToggleSidebar, let window = mainWindow else { return }
        if columnVisibility == .detailOnly, inspector != nil {
            withAnimation { columnVisibility = .all }
        } else {
            SplitViewTuning.toggleSidebar(in: window)
        }
    }

    func toggleInspector(_ panel: InspectorPanel) {
        // A reopen still waiting shows nothing yet, so asking for a panel again asks to show it: the same one keeps
        // waiting, the other one waits in its place.
        if pendingInspectorOpen != nil { pendingInspectorOpen = panel; return }
        guard inspector == nil else { inspector = inspector == panel ? nil : panel; return }
        if reopenMustWait { return holdInspectorOpen(panel) }
        inspector = panel
    }

    /// SwiftUI finishes presenting or closing the panel in its own transaction and then writes the outcome back
    /// through the inspector binding (`MainWindow`): `true` about 250 ms after an open, `false` 300–400 ms after a
    /// close. A `false` with a panel open is a close SwiftUI or AppKit made, and the model follows it.
    func inspectorPresentationEnded() {
        if inspector == nil {
            lastInspectorClose?.echoed = true
            return
        }
        // The write-back of an earlier close arriving after a reopen (one that didn't wait, or waited past
        // `reopenWaitLimit`): SwiftUI has closed the column, so follow it and open again once it's settled. Only a
        // close not yet written back, made shortly before the panel's latest open, counts: AppKit collapsing the
        // column (`SplitViewTuning.collapsePanel`, showing the sidebar where the panel doesn't fit) writes `false`
        // at once, with the panel still open in the model, and is a real close.
        let staleClose = lastInspectorClose.map { close in
            !close.echoed && Date().timeIntervalSince(close.time) < Self.reopenWaitLimit + 0.5
                && (lastInspectorOpen.map { $0 > close.time } ?? false)
        } ?? false
        let panel = inspector
        inspector = nil
        if staleClose, let panel {
            lastInspectorClose?.echoed = true
            holdInspectorOpen(panel)
        }
    }

    /// The last close of the panel, and whether SwiftUI has written it back yet (`inspectorPresentationEnded`).
    @ObservationIgnored private var lastInspectorClose: (time: Date, echoed: Bool)?
    /// When the panel last opened.
    @ObservationIgnored private var lastInspectorOpen: Date?
    /// A reopen waiting for the close before it to settle (`holdInspectorOpen`).
    @ObservationIgnored private var pendingInspectorOpen: InspectorPanel?
    /// The sidebar's return after a closing panel is scheduled but hasn't started (`fitInspector`).
    @ObservationIgnored private var sidebarReturnScheduled = false
    /// How long after a close a reopen may wait for it to settle; past it the panel opens anyway.
    static let reopenWaitLimit: TimeInterval = 1.5

    /// Whether opening a panel now would overlap the close before it: SwiftUI hasn't written that close back yet,
    /// or the sidebar that close brings back is still on its way (scheduled, or animating in). A panel reopened
    /// during SwiftUI's close was closed again by its write-back of that close: 60 of 96 reopens 50–150 ms after a
    /// close (`OPENMUSIC_SELFTEST=resize`, `rapid`). One reopened before the sidebar's return cancelled the return and
    /// kept the sidebar hidden although both fit, and one opened while the sidebar animates in is measured against
    /// a sidebar only partly there. Opens that don't follow a close never wait.
    private var reopenMustWait: Bool {
        guard let close = lastInspectorClose, Date().timeIntervalSince(close.time) < Self.reopenWaitLimit else { return false }
        return !close.echoed || sidebarReturnScheduled || SidebarAnimationGuard.isActive
    }

    /// Opens `panel` once the close before it has settled (`reopenMustWait`), checking every 30 ms. The panel
    /// stays closed meanwhile, as it shows; a newer request replaces it (`toggleInspector`).
    private func holdInspectorOpen(_ panel: InspectorPanel) {
        let first = pendingInspectorOpen == nil
        pendingInspectorOpen = panel
        guard first else { return }
        #if DEBUG
        debugSidebarTrace?("reopen of \(panel.rawValue) waits for the close to settle")
        #endif
        func check() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                guard let self, let panel = self.pendingInspectorOpen else { return }
                if self.reopenMustWait { return check() }
                self.pendingInspectorOpen = nil
                #if DEBUG
                self.debugSidebarTrace?("reopen of \(panel.rawValue) goes ahead")
                #endif
                if self.inspector == nil { self.inspector = panel }
            }
        }
        check()
    }

    static let fullScreenPanelKey = "fullScreenPanel"

    /// Lyrics until the listener picks otherwise; "none" is a remembered choice to show neither.
    static func storedFullScreenPanel() -> InspectorPanel? {
        guard let raw = UserDefaults.standard.string(forKey: fullScreenPanelKey) else { return .lyrics }
        return InspectorPanel(rawValue: raw)
    }

    /// Whether the current song has lyrics to show (its service serves them).
    var currentSongHasLyrics: Bool {
        player.current.map { can(.lyrics, $0.provider) } ?? false
    }

    /// The panel the full-screen player shows right now: the remembered choice, except lyrics for a song whose
    /// service has none (the choice stays, for the next song that has them).
    var shownFullScreenPanel: InspectorPanel? {
        fullScreenPanel == .lyrics && !currentSongHasLyrics ? nil : fullScreenPanel
    }

    /// The panel on screen where the listener is looking: the full-screen player's while it's up, else the
    /// window's inspector. The View menu's Show/Hide titles follow it.
    var visiblePanel: InspectorPanel? {
        isFullScreenPlayerPresented ? shownFullScreenPanel : inspector
    }

    /// Show or hide lyrics or Playing Next on the surface in front: the full-screen player's panel while it's up
    /// (the window's inspector underneath stays as it was), else the inspector.
    func togglePanel(_ panel: InspectorPanel) {
        guard isFullScreenPlayerPresented else { return toggleInspector(panel) }
        let next: InspectorPanel? = shownFullScreenPanel == panel ? nil : panel
        if next == .lyrics, !currentSongHasLyrics { return }
        // Reduce Motion: the artwork jumps to its new place instead of gliding there.
        let animation: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : Motion.panel
        withAnimation(animation) { fullScreenPanel = next }
    }

    /// In a narrow window there's no room for sidebar, page and inspector at once (`SplitViewTuning.panelRoom`;
    /// on macOS 26 about 1112 pt with the sidebar at 190, 1196 at 232), so opening the inspector hides the sidebar
    /// and closing it brings the sidebar back (the rule is in `showSidebarBesidePanel`).
    ///
    /// The sidebar comes back only once the inspector column is gone, and only if it fits next to the page
    /// at the current width. Showing it in the same update that closes the inspector made AppKit lay out all
    /// three columns at once and widen the window to fit them (960 → 1181 pt), and the window kept that width.
    private func fitInspector(opening: Bool, closing: Bool) {
        // Only a real open or close counts: SwiftUI also writes nil to a closed inspector.
        guard opening || closing else { return }
        sidebarRestoreGeneration &+= 1
        // A newer open or close supersedes a scheduled sidebar return (it checks the generation).
        sidebarReturnScheduled = false
        let generation = sidebarRestoreGeneration
        if opening {
            // Only a sidebar this collapse hid comes back on close: one the user hid before stays hidden, and so
            // does one the user hides while the panel is open in a wide window.
            let sidebar = SplitViewTuning.sidebarWidth(in: mainWindow)
            let room = SplitViewTuning.panelRoom(windowWidth: windowWidth, sidebarWidth: sidebar)
            // The width the panel can come back at: its ideal, or wider when AppKit may still want an earlier width
            // (`SplitViewTuning.panelRestoreBound`: a 520 pt drag made while the sidebar was hidden came back at
            // 387–520 pt beside the 232 pt sidebar in a 1220 pt window whatever this open's maximum, 1406 pt needed,
            // and AppKit aborted in its Update Constraints pass). A panel that won't fit beside the sidebar at that
            // width hides it, as the panel asked for last. Closing normally narrows such a panel first
            // (`normalizePanelBeforeClose`), so this is the fallback.
            let opensAt = SplitViewTuning.panelRestoreBound(in: mainWindow)
            collapsedSidebarForInspector = room < opensAt && columnVisibility != .detailOnly
            if collapsedSidebarForInspector { columnVisibility = .detailOnly }
            // The column's maximum for this open: the room beside the sidebar it keeps. AppKit can bring the column
            // back at its last width (a 520 pt drag) rather than the ideal, and SwiftUI applies its own maximum as it
            // presents the panel, overwriting any cap set on the split view item: lyrics reopened at 498 pt beside
            // a 232 pt sidebar in a 1220 pt window (1384 needed) and AppKit aborted (`OPENMUSIC_SELFTEST=resize`,
            // `toggle`). Like the ideal, it changes only in the update that opens the panel and goes back to 520
            // once the panel has closed (`restoreInspectorIdeal`).
            let openRoom = SplitViewTuning.panelRoom(windowWidth: windowWidth, sidebarWidth: collapsedSidebarForInspector ? 0 : sidebar)
            inspectorMaxWidth = min(InspectorMetrics.maxWidth, max(InspectorMetrics.minWidth, openRoom.rounded(.down)))
            #if DEBUG
            debugSidebarTrace?("panel opens at \(opensAt) with maximum \(inspectorMaxWidth) beside sidebar \(collapsedSidebarForInspector ? 0 : sidebar) in \(windowWidth)")
            #endif
        } else if closing, collapsedSidebarForInspector {
            collapsedSidebarForInspector = false
            sidebarReturnScheduled = true
            // After the inspector's close animation, outside this SwiftUI update.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if self?.sidebarRestoreGeneration == generation { self?.sidebarReturnScheduled = false }
                guard let self, self.sidebarRestoreGeneration == generation, self.inspector == nil,
                      self.columnVisibility == .detailOnly, self.windowWidth >= Self.sidebarFitWidth
                else { return }
                SplitViewTuning.showSidebarKeepingWidth(in: self.mainWindow) { [weak self] in
                    self?.columnVisibility == .all
                } stillWanted: { [weak self] in
                    guard let self else { return false }
                    return self.sidebarRestoreGeneration == generation && self.inspector == nil
                } sync: { [weak self] in
                    self?.columnVisibility = .all
                }
            }
        }
    }

    /// Keeps the sidebar, the page and an open panel inside the main window (`SplitViewTuning.neededWidth`); a
    /// window narrower than the columns need aborts AppKit's layout. Each time the window's size changes, before
    /// AppKit lays out the new size, the panel (to its ideal width) and then the sidebar (to its minimum) narrow,
    /// and with a panel open the sidebar hides when even that doesn't fit. It comes back when the panel closes, as
    /// when opening a panel hides it. After any column changes width, divider drags are capped at the room left.
    /// The resize notification is posted from inside the frame change, before the layout pass, so that part stays
    /// synchronous.
    private func watchMainWindowResize() {
        for observer in mainWindowObservers { NotificationCenter.default.removeObserver(observer) }
        mainWindowObservers = []
        SidebarAnimationGuard.watch(mainWindow)
        watchSidebarCommandState()
        guard let window = mainWindow else { return }
        mainWindowObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if var pending = self.widthCorrection, let window = self.mainWindow {
                    pending.correction.windowResized(to: window.frame, stamp: self.windowActionStamp)
                    self.widthCorrection = pending
                }
                self.fitColumnsToWindow()
            }
        })
        // A live resize and full screen are newer window actions: a pending width correction gives up
        // (`WidthCorrection`), and so does a held shrink in full screen (`SidebarAnimationGuard`).
        for name in [NSWindow.willStartLiveResizeNotification, NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            let fullScreen = name != NSWindow.willStartLiveResizeNotification
            mainWindowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.windowActions &+= 1
                    if fullScreen { SidebarAnimationGuard.cancel() }
                }
            })
        }
        // Posted from inside layout: cap the drags on the next turn of the main loop.
        mainWindowObservers.append(NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: nil) { [weak self, weak window] note in
            // Posted on the main thread, where split views live.
            nonisolated(unsafe) let view = note.object as? NSView
            MainActor.assumeIsolated {
                guard let window, view?.window === window else { return }
                // Every width the panel column shows bounds what it can come back at (`panelRestoreBound`).
                if let split = view as? NSSplitView { SplitViewTuning.notePanelWidth(in: split) }
                self?.scheduleColumnLimits()
            }
        })
        // A window that opens narrower than its saved columns need (a frame and a sidebar width saved by an earlier
        // launch, or a panel opened before this ran) is fitted as soon as it is watched, not at its first resize.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, window === self.mainWindow else { return }
            self.fitColumnsToWindow()
        }
    }

    private var windowActionStamp: Int { windowActions &+ SidebarAnimationGuard.frameRequests }

    @ObservationIgnored private var sidebarCommandObservers: [NSObjectProtocol] = []

    /// Keeps `canToggleSidebar` current as windows become key or main, close, or miniaturize.
    private func watchSidebarCommandState() {
        updateSidebarCommandState()
        guard sidebarCommandObservers.isEmpty else { return }
        let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                                          NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
                                          NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                                          NSWindow.didDeminiaturizeNotification, NSApplication.didBecomeActiveNotification,
                                          NSApplication.didResignActiveNotification]
        for name in names {
            sidebarCommandObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                // Read the windows once AppKit has finished the change.
                DispatchQueue.main.async { self?.updateSidebarCommandState() }
            })
        }
    }

    private func updateSidebarCommandState() {
        var enabled = false
        if let window = mainWindow, window.isVisible, !window.isMiniaturized,
           NSApp.keyWindow === window || NSApp.mainWindow === window,
           let root = window.contentView, SplitViewTuning.sidebarItem(in: root) != nil {
            enabled = true
        }
        if canToggleSidebar != enabled { canToggleSidebar = enabled }
    }

    private func fitColumnsToWindow() {
        guard let window = mainWindow else { return }
        observeSidebarColumn()
        let panelFloor = inspector != nil ? InspectorMetrics.idealWidth : 0
        if !SplitViewTuning.narrowColumnsToFit(window, panelFloor: panelFloor), inspector != nil, columnVisibility != .detailOnly {
            collapsedSidebarForInspector = true
            SplitViewTuning.collapseSidebar(in: window)
            columnVisibility = .detailOnly
            _ = SplitViewTuning.narrowColumnsToFit(window, panelFloor: panelFloor)
        }
        SplitViewTuning.limitColumnWidths(in: window)
    }

    /// Before the lyrics/queue panel closes, while it still shows: when it may come back wider than the room beside
    /// the sidebar in this window (`SplitViewTuning.panelRestoreBound`), its divider goes back to the ideal width,
    /// so it reopens there beside the sidebar instead of hiding it. Moving the divider is what changes the width
    /// AppKit brings the column back at; lowering the closed column's maximum or its view's frame did not. A panel
    /// that fits beside the sidebar keeps its width (lyrics at 420 in a wide window close as they are).
    private func normalizePanelBeforeClose() {
        guard let window = mainWindow, let width = window.contentView?.bounds.width else { return }
        let bound = SplitViewTuning.panelRestoreBound(in: window)
        let room = SplitViewTuning.panelRoom(windowWidth: width, sidebarWidth: SplitViewTuning.sidebarIdealWidth)
        guard bound > InspectorMetrics.idealWidth + 0.5, bound > room + 0.5 else { return }
        SplitViewTuning.normalizePanel(to: InspectorMetrics.idealWidth, in: window)
    }

    private func scheduleColumnLimits() {
        guard !columnLimitsScheduled else { return }
        columnLimitsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.columnLimitsScheduled = false
            self.observeSidebarColumn()
            SplitViewTuning.limitColumnWidths(in: self.mainWindow)
        }
    }

    #if DEBUG
    /// `OPENMUSIC_RESIZE_TRACE` (`ResizeSelfTest`).
    @ObservationIgnored var debugSidebarTrace: ((String) -> Void)?
    /// How many times `showSidebarBesidePanel` ran (`ResizeSelfTest` checks a toggle settles).
    @ObservationIgnored var debugSidebarDecisions = 0
    /// How many times `fitPanelBesideShownSidebar` put the window back to its width (`ResizeSelfTest`'s `widen`).
    @ObservationIgnored var debugWidthCorrections = 0
    #endif

    /// The sidebar and the lyrics/queue panel share the window only when both fit beside the page. Otherwise the one
    /// asked for last wins, as in Music: opening a panel hides a sidebar it doesn't fit beside (`fitInspector`),
    /// narrowing the window hides the sidebar once it can't keep its minimum beside the panel's ideal width
    /// (`fitColumnsToWindow`; 1112 pt on macOS 26 and later, 922 before), showing the sidebar closes a panel it doesn't
    /// fit beside, and closing a panel brings back a sidebar it hid. Showing the sidebar takes room for its ideal
    /// width beside the panel's current one (`SplitViewTuning.sidebarFitsBesidePanel`; 1196 pt beside a 310 pt
    /// panel on macOS 26), and never resizes the panel: narrowing a 520 pt queue to make room as the sidebar came in
    /// looped SwiftUI's toolbar updates until AppKit aborted.
    ///
    /// The toolbar's button and View › Show Sidebar (⌃⌘S, `toggleSidebar`) set `columnVisibility`, which comes here
    /// while the sidebar's column is still collapsed. SwiftUI would show the column by widening the window
    /// (1100 → 1321 pt), so the sidebar stays hidden for now and comes back through AppKit at the same width
    /// (`showSidebarKeepingWidth`): once the panel is gone, as after a panel that hid it closes, or at once where
    /// both fit.
    ///
    /// Anything that uncollapses the column in AppKit directly (`NSSplitViewController.toggleSidebar`, and
    /// `showSidebarKeepingWidth` itself) arrives through key-value observing (`observeSidebarColumn`, `fromAppKit`)
    /// with the column already on its way in (`fitPanelBesideShownSidebar`), and the binding follows at once.
    private func showSidebarBesidePanel(fromAppKit: Bool) {
        #if DEBUG
        debugSidebarDecisions += 1
        let line = "\(fromAppKit ? "appkit" : "binding") inspector=\(inspector?.rawValue ?? "nil") collapsed=\(mainWindow?.contentView.flatMap { SplitViewTuning.sidebarItem(in: $0)?.1.isCollapsed }.map(String.init) ?? "?") panel=\(SplitViewTuning.inspectorWidth(in: mainWindow) ?? -1) sidebarMax=\(mainWindow?.contentView.flatMap { SplitViewTuning.sidebarItem(in: $0)?.1.maximumThickness } ?? -1)"
        debugSidebarTrace?(line)
        #endif
        if fromAppKit {
            fitPanelBesideShownSidebar()
            // SwiftUI's binding follows AppKit at once, not when SwiftUI or `showSidebarKeepingWidth`'s delayed sync
            // gets to it: a sync arriving while the window was being resized made SwiftUI resize the window to fit the
            // columns, over and over (80100 pt), until AppKit aborted. This comes back here as a binding change and
            // stops below, the column being shown already.
            if columnVisibility == .detailOnly { columnVisibility = .all }
            return
        }
        guard inspector != nil, let window = mainWindow, let root = window.contentView,
              let (_, item) = SplitViewTuning.sidebarItem(in: root) else { return }
        // SwiftUI writing back a change AppKit already made.
        guard item.isCollapsed else { return }
        let fits = SplitViewTuning.sidebarFitsBesidePanel(windowWidth: root.bounds.width,
                                                          panelWidth: SplitViewTuning.inspectorWidth(in: window) ?? 0)
        if fits, window.styleMask.contains(.fullScreen) {
            // In full screen the window is as wide as the screen and SwiftUI can't grow it, so where both fit SwiftUI
            // shows the column itself, decided here once. The AppKit restore below skips full screen and set the
            // binding straight back, which came back here and hid the sidebar again, over and over. (Where they
            // don't fit, the panel closes and `fitInspector`'s restore sets the binding with no panel open.)
            SplitViewTuning.capSidebarBesidePanel(in: window)
            return
        }
        columnVisibility = .detailOnly
        if fits {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.columnVisibility == .detailOnly else { return }
                SplitViewTuning.capSidebarBesidePanel(in: self.mainWindow)
                SplitViewTuning.showSidebarKeepingWidth(in: self.mainWindow) { [weak self] in
                    self?.columnVisibility == .all
                } sync: { [weak self] in
                    self?.columnVisibility = .all
                }
            }
        } else {
            // `fitInspector` brings the sidebar back once the panel is gone.
            collapsedSidebarForInspector = true
            inspector = nil
        }
    }

    /// The sidebar's column has started to uncollapse in AppKit with a panel open: caps the sidebar where both fit,
    /// otherwise closes the panel (`showSidebarBesidePanel`). The column is already on its way in (collapsing it
    /// again mid-animation has aborted the same way), so the panel's column collapses at once; and as AppKit widens
    /// the window by the sidebar's width while the page's column still counts the closing panel, the window goes
    /// back to its width.
    private func fitPanelBesideShownSidebar() {
        guard inspector != nil, let window = mainWindow, let root = window.contentView else { return }
        collapsedSidebarForInspector = false
        // A panel still opening counts at the ideal width it is opening to.
        let fits = SplitViewTuning.sidebarFitsBesidePanel(windowWidth: root.bounds.width,
                                                          panelWidth: SplitViewTuning.inspectorWidth(in: window) ?? 0)
        if fits { return SplitViewTuning.capSidebarBesidePanel(in: window) }
        // Only the widening AppKit makes for this column is undone; a newer resize, zoom, tiling or full screen
        // keeps its width (`WidthCorrection`).
        let id = (widthCorrection?.id ?? 0) &+ 1
        widthCorrection = (id, WidthCorrection(original: window.frame, stamp: windowActionStamp))
        normalizePanelBeforeClose()
        SplitViewTuning.collapsePanel(in: window)
        inspector = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let pending = self.widthCorrection, pending.id == id else { return }
            self.widthCorrection = nil
            guard let window = self.mainWindow, !window.styleMask.contains(.fullScreen),
                  let frame = pending.correction.correctedFrame(current: window.frame, stamp: self.windowActionStamp) else { return }
            #if DEBUG
            self.debugSidebarTrace?("putting the window back from \(Int(window.frame.width)) to \(Int(frame.width))")
            self.debugWidthCorrections += 1
            #endif
            window.requestFrame(frame, display: true)
        }
    }

    /// Starts watching the sidebar's split view item for `showSidebarBesidePanel`, once SwiftUI has made it (and
    /// again if it makes a new one).
    private func observeSidebarColumn() {
        guard let root = mainWindow?.contentView, let (_, item) = SplitViewTuning.sidebarItem(in: root),
              item !== observedSidebarItem else { return }
        observedSidebarItem = item
        // The column exists now, so View › Show/Hide Sidebar can act.
        updateSidebarCommandState()
        adoptRestoredSidebar(item)
        sidebarColumnObservation = item.observe(\.isCollapsed, options: [.old, .new]) { [weak self] _, change in
            guard change.oldValue == true, change.newValue == false else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                // Window shrinks wait until the column is in (`SidebarAnimationGuard`).
                if let window = self.mainWindow { SidebarAnimationGuard.begin(window, duration: Self.sidebarAnimationGuardDuration) }
                #if DEBUG
                self.traceSidebarAnimation()
                #endif
                self.showSidebarBesidePanel(fromAppKit: true)
            }
        }
    }

    /// A new sidebar column that AppKit made collapsed while the binding says shown: the split view's autosave
    /// restores the column hidden when it was hidden at quit (a panel had hidden it in a narrow window), while
    /// `columnVisibility` starts at `.all`. SwiftUI then showed the column by widening the window (900 → 1091 pt),
    /// and with a panel opening at the same time AppKit aborted in its Update Constraints pass. So the binding takes
    /// AppKit's state, and the sidebar comes back the way it does after a panel closes (`fitInspector`): through
    /// AppKit at the window's width, beside an open panel only where both fit, and otherwise once the panel closes.
    private func adoptRestoredSidebar(_ item: NSSplitViewItem) {
        guard item.isCollapsed, columnVisibility != .detailOnly, let window = mainWindow,
              !window.styleMask.contains(.fullScreen) else { return }
        #if DEBUG
        debugSidebarTrace?("adopting a collapsed sidebar column at \(Int(window.frame.width)), panel \(inspector?.rawValue ?? "closed")")
        #endif
        columnVisibility = .detailOnly
        if inspector != nil, !SplitViewTuning.sidebarFitsBesidePanel(windowWidth: window.contentView?.bounds.width ?? windowWidth,
                                                                    panelWidth: SplitViewTuning.inspectorWidth(in: window) ?? 0) {
            collapsedSidebarForInspector = true
            return
        }
        let generation = sidebarRestoreGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sidebarRestoreGeneration == generation, self.columnVisibility == .detailOnly else { return }
            if self.inspector != nil { SplitViewTuning.capSidebarBesidePanel(in: self.mainWindow) }
            SplitViewTuning.showSidebarKeepingWidth(in: self.mainWindow) { [weak self] in
                self?.columnVisibility == .all
            } stillWanted: { [weak self] in
                self?.sidebarRestoreGeneration == generation
            } sync: { [weak self] in
                self?.columnVisibility = .all
            }
        }
    }

    /// How long window shrinks wait after the sidebar's column starts to uncollapse (`SidebarAnimationGuard`).
    static let sidebarAnimationGuardDuration: TimeInterval = 0.8

    #if DEBUG
    /// With `OPENMUSIC_RESIZE_TRACE`, logs the sidebar's and the window's width every 20 ms for 1.2 s after the
    /// column starts to uncollapse, to see how long its animation runs.
    private func traceSidebarAnimation() {
        guard let trace = debugSidebarTrace else { return }
        let start = Date()
        func sample(_ n: Int) {
            guard n < 60 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let window = self.mainWindow else { return }
                    trace("anim +\(Int(Date().timeIntervalSince(start) * 1000)) ms: window \(Int(window.frame.width)) sidebar \(Int(SplitViewTuning.sidebarWidth(in: window)))")
                    sample(n + 1)
                }
            }
        }
        sample(0)
    }
    #endif

    /// Lyrics show at a reading width (`InspectorMetrics.lyricsWidth`) in a wide window, as far as the room beside
    /// the sidebar and the page allows (`SplitViewTuning.panelRoom`; a wide sidebar leaves less); the queue goes back
    /// to the ideal 310 if lyrics had widened the panel.
    ///
    /// Opening: the panel opens straight at its width, through the column's ideal width, set in the same update.
    /// Moving the divider after the open animation instead made lyrics slide in at 310 and then snap to 420 half a
    /// second later, re-laying out the page. A wide ideal is only chosen in a window too wide for opening to collapse
    /// the sidebar and with room for 420 beside it (lyrics at 420 beside the 232 pt sidebar need 1306 pt on macOS 26);
    /// in a 1300 pt window lyrics open at 310 and the divider moves to the room left. The next open in a narrow
    /// window sets 310 again in its own update (`OPENMUSIC_SELFTEST=inspectorwidth` toggles the sidebar under the wide
    /// ideal, open and closed, and reopens at 960).
    ///
    /// Switching panels while one shows keeps the ideal and moves the divider (outside this SwiftUI update), so the
    /// column's limits never change under an open panel. Every divider move is capped at the room left.
    private func sizeInspector(for panel: InspectorPanel?, opening: Bool) {
        let target: CGFloat
        if opening {
            let width = mainWindow?.contentView?.bounds.width ?? windowWidth
            // The sidebar as AppKit has it now (0 when collapsed): one this open is hiding still takes its width
            // while it slides out, so lyrics open at 310 then and widen once it is gone.
            let sidebar = SplitViewTuning.sidebarWidth(in: mainWindow)
            let wideWindow = panel == .lyrics && width >= InspectorMetrics.wideLyricsWindow
            let wideIdeal = wideWindow && SplitViewTuning.panelRoom(windowWidth: width, sidebarWidth: sidebar) >= InspectorMetrics.lyricsWidth
            inspectorIdealWidth = wideIdeal ? InspectorMetrics.lyricsWidth : InspectorMetrics.idealWidth
            // AppKit reopens the column at its last width, not at an ideal that changed while it was closed: after
            // wide lyrics the queue (or lyrics in a narrow window) came back at 420 (`OPENMUSIC_SELFTEST=inspectorwidth`,
            // "queue opened at 960"). Then the divider goes to 310 as a switch moves it.
            if wideWindow {
                // The ideal alone isn't always kept: a page whose layout holds its width (an album, at 1208 pt) left the
                // column at its 280 minimum (council `lyrics`). The divider then goes to 420 during the open; where the
                // ideal held (Home) that does nothing.
                widenedForLyrics = true
                target = InspectorMetrics.lyricsWidth
            } else if widenedForLyrics {
                target = InspectorMetrics.idealWidth
            } else {
                return
            }
        } else {
            switch panel {
            case .lyrics where windowWidth >= InspectorMetrics.wideLyricsWindow:
                target = InspectorMetrics.lyricsWidth
            case .queue where widenedForLyrics:
                target = InspectorMetrics.idealWidth
            default:
                return
            }
        }
        let generation = sidebarRestoreGeneration
        for delay in [0.05, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.inspector == panel, self.sidebarRestoreGeneration == generation,
                      let window = self.mainWindow, let width = window.contentView?.bounds.width else { return }
                let room = SplitViewTuning.panelRoom(windowWidth: width, sidebarWidth: SplitViewTuning.sidebarWidth(in: window))
                let fitted = min(target, room)
                // Narrowing back to 310 needs no wide window: lyrics opened at 1440, closed, then reopened at 960 kept
                // AppKit's 420 when this asked for a wide window here too (merge review). Widening does.
                let narrowing = target <= InspectorMetrics.idealWidth
                guard narrowing || (fitted > InspectorMetrics.idealWidth && width >= InspectorMetrics.wideLyricsWindow) else { return }
                SplitViewTuning.setInspectorWidth(fitted, in: window)
                // Only once the panel really is that wide: in native full screen `setInspectorWidth` does nothing,
                // and clearing the flag there left the queue at the lyrics width with nothing left to narrow it.
                if let shown = SplitViewTuning.inspectorWidth(in: window), abs(shown - fitted) <= 1 {
                    self.widenedForLyrics = fitted > InspectorMetrics.idealWidth
                }
            }
        }
    }

    /// Back to the usual ideal and maximum once the close animation is over, so a closed panel leaves the split view
    /// exactly as it was before wide lyrics existed (window resizes and sidebar toggles happen against 310).
    private func restoreInspectorIdeal() {
        guard inspectorIdealWidth != InspectorMetrics.idealWidth || inspectorMaxWidth != InspectorMetrics.maxWidth else { return }
        let generation = sidebarRestoreGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.inspector == nil, self.sidebarRestoreGeneration == generation else { return }
            if self.inspectorIdealWidth != InspectorMetrics.idealWidth { self.inspectorIdealWidth = InspectorMetrics.idealWidth }
            if self.inspectorMaxWidth != InspectorMetrics.maxWidth { self.inspectorMaxWidth = InspectorMetrics.maxWidth }
        }
    }

    /// The narrowest window that holds the sidebar at its minimum beside the page's minimum, with no panel
    /// (`SplitViewTuning.neededWidth`: 802 pt on macOS 26 and later, under the 900 pt window minimum).
    static let sidebarFitWidth: CGFloat = SplitViewTuning.neededWidth(sidebar: SplitViewTuning.sidebarMinWidth, panel: 0)

    func recordSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        recentSearches.removeAll { $0.caseInsensitiveCompare(q) == .orderedSame }
        recentSearches.insert(q, at: 0)
        recentSearches = Array(recentSearches.prefix(12))
        // Sample-data and snapshot runs never touch the real list.
        if snapshotDirectory == nil, !isMock { UserDefaults.standard.set(recentSearches, forKey: "recentSearches") }
        onRecentSearchesChanged?(recentSearches)
    }

    func clearRecentSearches() {
        recentSearches = []
        if snapshotDirectory == nil, !isMock { UserDefaults.standard.removeObject(forKey: "recentSearches") }
        onRecentSearchesChanged?(recentSearches)
    }

    /// Recent searches from another device (sync). Saved, not sent back.
    func replaceRecentSearches(_ list: [String]) {
        let list = Array(list.prefix(12))
        guard list != recentSearches else { return }
        recentSearches = list
        if snapshotDirectory == nil, !isMock { UserDefaults.standard.set(recentSearches, forKey: "recentSearches") }
    }

    // MARK: Playback

    /// A playback choice that starts at once (a song, a loaded album): it supersedes any request still loading.
    func play(_ tracks: [Track], startAt index: Int = 0, shuffled: Bool = false, from context: PlayingFrom?) {
        guard !tracks.isEmpty else { return }
        beginPlayRequest()
        startPlaying(tracks, startAt: index, shuffled: shuffled, from: context)
    }

    /// Replaces the queue, for the request that is still the newest choice.
    private func startPlaying(_ tracks: [Track], startAt index: Int = 0, shuffled: Bool = false, from context: PlayingFrom?) {
        guard !tracks.isEmpty else { return }
        playingFrom = context
        player.play(tracks, startAt: index, shuffled: shuffled)
        // Albums, playlists and artists go to the sidebar's Recently Played; single songs don't.
        if let entry = SidebarEntry(route: context?.route) { collections.recordPlayed(entry) }
    }

    /// Plays an album, playlist, or artist from the start (or shuffled). A second request for the same collection
    /// while the first still loads does nothing; any newer choice makes this one give up.
    func play(_ item: MediaItem, shuffled: Bool = false) {
        let key = PlayRequestKey.collection(item.id, shuffled: shuffled)
        guard !isPlayPending(key) else { return }
        let request = beginPlayRequest(pending: key)
        Task {
            if case .playlist(let p) = item {
                guard let provider = provider(p.provider) else { return finishPlayRequest(request) }
                do {
                    let detail: PlaylistDetail = try await cached("playlist:\(p.id)") { try await provider.playlist(id: p.providerID) }
                    let context = PlayingFrom(title: p.title, route: .playlist(p.provider, id: p.providerID, preview: p))
                    await playPlaylist(detail.tracks, continuation: detail.continuation, provider: p.provider, shuffled: shuffled, from: context, request: request)
                } catch {
                    guard canStartPlayRequest(request) else { return }
                    finishPlayRequest(request)
                    report(error, doing: "Couldn’t play “\(p.title)”", service: p.provider, retry: { self.play(item, shuffled: shuffled) })
                }
                return
            }
            do {
                let (tracks, context) = try await loadTracks(for: item)
                guard canStartPlayRequest(request) else { return }
                finishPlayRequest(request)
                startPlaying(tracks, shuffled: shuffled, from: context)
            } catch {
                guard canStartPlayRequest(request) else { return }
                finishPlayRequest(request)
                report(error, doing: "Couldn’t play “\(item.title)”", service: item.provider, retry: { self.play(item, shuffled: shuffled) })
            }
        }
    }

    // MARK: Play requests

    /// What a play request is for: a second click on the same row while it loads is the same request.
    enum PlayRequestKey: Hashable {
        case likedSongs
        /// An album, playlist or artist (`MediaItem.id`), in order or shuffled.
        case collection(String, shuffled: Bool)
        /// A radio station, by its seed.
        case radio(String)
    }

    /// A request that is still loading what it will play, for the spinner in its row's artwork or symbol slot.
    struct PendingPlay: Equatable {
        let key: PlayRequestKey
        let id: Int
    }

    /// The newest playback choice. Every choice the listener makes (a song, a collection, Liked Songs, a radio, a
    /// song picked in Playing Next) takes the next number; a request that loads first starts playing, reports a
    /// failure and appends later pages only while its number is still the newest. A slow Liked Songs load can then
    /// never replace a song chosen after it.
    @ObservationIgnored private(set) var playRequest = 0
    /// The request still loading, if any (one at a time: a newer choice supersedes it). Rows read it for a spinner.
    private(set) var pendingPlay: PendingPlay?

    /// Whether `key` is loading to play right now.
    func isPlayPending(_ key: PlayRequestKey) -> Bool { pendingPlay?.key == key }

    /// A new playback choice: older requests give up. `pending` names what this one loads before it can play.
    @discardableResult
    func beginPlayRequest(pending key: PlayRequestKey? = nil) -> Int {
        playRequest &+= 1
        playRequestTransport = transportChoices
        let pending = key.map { PendingPlay(key: $0, id: playRequest) }
        if pendingPlay != pending { pendingPlay = pending }
        return playRequest
    }

    /// Whether `id` is still the newest playback choice: a request that already started playing appends its later
    /// pages only while this holds. Pause, Next or a seek doesn't end it (the playlist keeps filling in).
    func isCurrentPlayRequest(_ id: Int) -> Bool { id == playRequest }

    /// Whether a request still loading may start playing (or report its failure): it is the newest choice and no
    /// transport choice (Play/Pause, Next, Previous, a seek, from any player, the Controls menu or the media keys)
    /// came after it. Pausing while a sorted playlist loads keeps the queue that was there, paused.
    func canStartPlayRequest(_ id: Int) -> Bool { id == playRequest && playRequestTransport == transportChoices }

    /// Transport choices made so far (`noteTransportChoice`), and how many there were when the newest request began.
    @ObservationIgnored private(set) var transportChoices = 0
    @ObservationIgnored private var playRequestTransport = 0

    /// The listener chose a transport action: a request still loading to start playing gives up (its spinner goes);
    /// one that already plays goes on appending its pages.
    func noteTransportChoice() {
        transportChoices &+= 1
        if pendingPlay != nil { pendingPlay = nil }
    }

    // MARK: Transport

    // Every player surface, the Controls menu, Space and the media keys (`NowPlayingCenter.willRunTransportCommand`)
    // go through these, so a choice made while something loads wins over it.

    func togglePlayPause() { noteTransportChoice(); player.togglePlayPause() }
    func pause() { noteTransportChoice(); player.pause() }
    func resume() { noteTransportChoice(); player.resume() }
    func next() { noteTransportChoice(); player.next() }
    func previous() { noteTransportChoice(); player.previous() }
    func seek(to seconds: TimeInterval) { noteTransportChoice(); player.seek(to: seconds) }

    /// The request has started playing, or failed: its spinner goes.
    private func finishPlayRequest(_ id: Int) {
        if pendingPlay?.id == id { pendingPlay = nil }
    }

    /// Plays a song already in the queue (Playing Next's double-click, Return or Play Now): a playback choice, so a
    /// request still loading gives up.
    func jump(to uid: UUID) {
        beginPlayRequest()
        player.jump(to: uid)
    }

    /// Plays a History song next, keeping the queue: also a playback choice.
    func playNow(_ track: Track, from context: PlaybackContext?) {
        beginPlayRequest()
        player.playNow(track, from: context)
    }

    /// Which collection a route points at, ignoring the preview model, so two routes to the same album match.
    struct ContextKey: Hashable {
        enum Kind: Hashable { case album, playlist, artist }
        let provider: ProviderID
        let kind: Kind
        let id: String

        init?(_ route: Route?) {
            switch route {
            case .album(let p, let id, _): self.init(provider: p, kind: .album, id: id)
            case .playlist(let p, let id, _): self.init(provider: p, kind: .playlist, id: id)
            case .artist(let p, let id, _): self.init(provider: p, kind: .artist, id: id)
            default: return nil
            }
        }

        init(provider: ProviderID, kind: Kind, id: String) {
            self.provider = provider
            self.kind = kind
            self.id = id
        }
    }

    /// Whether the current queue was started from this collection (matched by provider, kind and id).
    func isCurrentContext(_ route: Route) -> Bool {
        guard player.current != nil, let key = ContextKey(route) else { return false }
        return ContextKey(playingFrom?.route) == key
    }

    /// Whether `track` is the current song *and* the queue was started from `context`, so a row's Play
    /// glyph can pause or resume in place. The same song playing from somewhere else starts this list.
    func isCurrent(_ track: Track, in context: PlayingFrom) -> Bool {
        guard player.current?.id == track.id, let playingFrom else { return false }
        if let key = ContextKey(context.route) { return ContextKey(playingFrom.route) == key }
        return playingFrom.route == nil && playingFrom.title == context.title
    }

    /// The hero Play button: pause or resume when this collection is the one playing, else start it.
    /// Resuming never replaces the queue.
    func playOrPause(_ route: Route, start: () -> Void) {
        if isCurrentContext(route) {
            if player.isPlaying { pause() } else { resume() }
        } else {
            start()
        }
    }

    /// Library › Liked Songs as a play context: the page's Play and the sidebar row's play button start the same queue,
    /// so each shows the other's playback.
    static let likedSongsContext = PlayingFrom(title: SidebarItem.likedSongs.title)

    /// Whether the current queue was started from `context`: by collection when it has a route, else by title (a
    /// library list such as Liked Songs).
    func isCurrentContext(_ context: PlayingFrom) -> Bool {
        if let route = context.route { return isCurrentContext(route) }
        guard player.current != nil, let playingFrom else { return false }
        return playingFrom.route == nil && playingFrom.title == context.title
    }

    /// `playOrPause(_:start:)` for any play context.
    func playOrPause(_ context: PlayingFrom, start: () -> Void) {
        if isCurrentContext(context) {
            if player.isPlaying { pause() } else { resume() }
        } else {
            start()
        }
    }

    /// Plays Library › Liked Songs from the top, in the page's order (the services' likes interleaved). A list the page
    /// already loaded plays at once; otherwise the first page of each service starts playing and the rest is
    /// appended as it arrives, as a long playlist does.
    func playLikedSongs() {
        let providers = libraryProviders
        guard !providers.isEmpty else { return }
        // A second click while the first request loads: the same request, still loading.
        guard !isPlayPending(.likedSongs) else { return }
        let context = Self.likedSongsContext
        func tracks(_ items: [MediaItem]) -> [Track] { items.compactMap { if case .track(let t) = $0 { t } else { nil } } }
        // Every service's whole list saved by the Liked Songs page (`LibraryLoader`).
        if let saved = LibraryLoader.savedList(LibraryKind.likedSongs.rawValue, providers: providers, cache: cache), !saved.isEmpty {
            return play(tracks(saved), from: context)
        }
        let request = beginPlayRequest(pending: .likedSongs)
        Task {
            // Each service's first page at once, so the slower one sets the wait, not their sum.
            let firstPages = providers.map { provider in
                (provider, Task { try await provider.library(.likedSongs, continuation: nil) })
            }
            var first: [[Track]] = []
            var tokens: [(any MusicProvider, String)] = []
            var failure: (any Error)?
            for (provider, task) in firstPages {
                do {
                    let page = try await task.value
                    first.append(tracks(page.items))
                    if let next = page.continuation { tokens.append((provider, next)) }
                } catch {
                    failure = failure ?? error
                }
            }
            // Superseded while loading (the listener chose something else): nothing to start, report or append.
            guard canStartPlayRequest(request) else { return }
            finishPlayRequest(request)
            let loaded = interleave(first)
            guard !loaded.isEmpty else {
                if let failure {
                    report(failure, doing: "Couldn’t play Liked Songs", retry: { self.playLikedSongs() })
                } else {
                    show(Notice(text: "No liked songs yet", symbol: "heart"))
                }
                return
            }
            startPlaying(loaded, from: context)
            var seen = Set(loaded.map(\.id))
            var pages = 0
            while !tokens.isEmpty, pages < Self.maxPlaylistPages {
                let (provider, token) = tokens.removeFirst()
                guard let page = try? await provider.library(.likedSongs, continuation: token) else { continue }
                guard isCurrentPlayRequest(request), player.currentIndex != nil else { return }
                let fresh = tracks(page.items).filter { seen.insert($0.id).inserted }
                if !fresh.isEmpty { player.addToQueue(fresh) }
                if let next = page.continuation { tokens.append((provider, next)) }
                pages += 1
            }
        }
    }

    /// Upper bound on pages fetched for one playlist (YouTube Music and Spotify both serve 100 per page).
    static let maxPlaylistPages = 40
    /// The bound in use (`maxPlaylistPages`; tests lower it).
    @ObservationIgnored var playlistPageLimit = AppModel.maxPlaylistPages

    /// A playlist with pages left after `playlistPageLimit` pages: `tracks` are the songs loaded before the bound (for
    /// `remainingPlaylistTracks`, the part after the songs it was given). Callers use them and say what was left out
    /// (`showIncomplete`), never passing them off as the whole playlist.
    struct PlaylistLoadIncomplete: Error {
        var tracks: [Track]
    }

    /// The notice for a playlist cut at the page bound: how many songs could be loaded, and what was done with them
    /// (`outcome`: "Playing those."). It stays until closed, like a failure; Try Again would stop at the same bound.
    func showIncomplete(_ count: Int, of title: String, _ outcome: String) {
        show(Notice(text: "Only the first \(count.formatted()) songs of “\(title)” could be loaded. \(outcome)",
                    symbol: "exclamationmark.triangle.fill", kind: .failure))
    }

    /// Plays a playlist of which `loaded` is the part already fetched, and `continuation` points at the rest.
    /// Play starts right away and appends the remaining pages to the queue as they arrive, so long playlists
    /// don't stop after the first page. Shuffle needs every track to draw from, so it loads the rest first; if a page
    /// fails then, the queue stays as it was and the failure notice offers Try Again (never a shuffle of part of it).
    /// `request` is the play request this belongs to; nil makes a new one (a page's Play, which starts it here).
    func playPlaylist(_ loaded: [Track], continuation: String?, provider id: ProviderID, startAt index: Int = 0, shuffled: Bool = false,
                      from context: PlayingFrom, request: Int? = nil) async {
        // Each song once, as the page lists it (a page's rows already are, so `index` stays theirs).
        let loaded = Self.eachOnce(loaded)
        let request = request ?? beginPlayRequest()
        guard canStartPlayRequest(request) else { return }
        guard let continuation, let provider = provider(id) else {
            finishPlayRequest(request)
            return startPlaying(loaded, startAt: index, shuffled: shuffled, from: context)
        }
        if shuffled || !loaded.contains(where: \.isPlayable) {
            let rest: [Track]
            var incomplete = false
            do {
                rest = try await remainingPlaylistTracks(after: loaded, continuation: continuation, provider: provider)
            } catch let partial as PlaylistLoadIncomplete {
                // Past the page bound: play (or shuffle) the part loaded, and say so.
                rest = partial.tracks
                incomplete = true
            } catch {
                finishPlayRequest(request)
                // Cancelled, or superseded while the pages loaded: nothing to start or report.
                guard canStartPlayRequest(request), !Task.isCancelled else { return }
                return report(error, doing: "Couldn’t play “\(context.title)”", service: id, retry: {
                    Task { await self.playPlaylist(loaded, continuation: continuation, provider: id, startAt: index, shuffled: shuffled, from: context) }
                })
            }
            finishPlayRequest(request)
            guard canStartPlayRequest(request), !Task.isCancelled else { return }
            startPlaying(loaded + rest, startAt: shuffled ? 0 : index, shuffled: shuffled, from: context)
            if incomplete { showIncomplete(loaded.count + rest.count, of: context.title, shuffled ? "Shuffling those." : "Playing those.") }
            return
        }
        finishPlayRequest(request)
        startPlaying(loaded, startAt: index, from: context)
        await appendPlaylistPages(from: continuation, seen: Set(loaded.map(\.id)), provider: provider, title: context.title, request: request)
    }

    /// Appends a playing playlist's later pages to the queue, while its request is still the newest choice and
    /// something plays. A page that fails leaves what is queued playing, with a notice whose Try Again goes on from
    /// that page; a cancelled one ends quietly.
    private func appendPlaylistPages(from continuation: String, seen: Set<Track.ID>, provider: any MusicProvider, title: String,
                                     request: Int, pagesSoFar: Int = 0) async {
        var seen = seen
        var token: String? = continuation
        var pages = pagesSoFar
        while let t = token, pages < playlistPageLimit {
            let page: Page<Track>
            do {
                page = try await provider.playlistTracks(continuation: t)
            } catch {
                guard !Task.isCancelled, isCurrentPlayRequest(request), player.currentIndex != nil else { return }
                let resume = (seen: seen, pages: pages)
                report(error, doing: "Couldn’t load the rest of “\(title)”", service: provider.id, retry: {
                    guard self.isCurrentPlayRequest(request) else { return }
                    Task {
                        await self.appendPlaylistPages(from: t, seen: resume.seen, provider: provider, title: title,
                                                       request: request, pagesSoFar: resume.pages)
                    }
                })
                return
            }
            // Stop if the listener started something else, or stopped playback, while this page loaded.
            guard !Task.isCancelled, isCurrentPlayRequest(request), player.currentIndex != nil else { return }
            let fresh = page.items.filter { seen.insert($0.id).inserted }
            if !fresh.isEmpty { player.addToQueue(fresh) }
            token = page.continuation
            pages += 1
        }
        // Stopped at the page bound with pages left: the queue holds part of the playlist, and says so.
        if token != nil, pages >= playlistPageLimit {
            showIncomplete(seen.count, of: title, "Playing those.")
        }
    }

    /// Every track after the first page of a playlist, deduplicated against `loaded` (as the playlist page's later
    /// pages are, `PlaylistPager`). Throws when a page fails, `CancellationError` when the calling task is cancelled
    /// before or after a page, and `PlaylistLoadIncomplete` (with the part loaded) when pages are left after
    /// `playlistPageLimit` pages, so no caller takes the part it got for the whole playlist.
    func remainingPlaylistTracks(after loaded: [Track], continuation: String?, provider: any MusicProvider) async throws -> [Track] {
        var seen = Set(loaded.map(\.id))
        var out: [Track] = []
        var token = continuation
        var pages = 0
        while let t = token {
            guard pages < playlistPageLimit else { throw PlaylistLoadIncomplete(tracks: out) }
            try Task.checkCancellation()
            let page = try await provider.playlistTracks(continuation: t)
            try Task.checkCancellation()
            out += page.items.filter { seen.insert($0.id).inserted }
            token = page.continuation
            pages += 1
        }
        return out
    }

    /// Plays a whole playlist in `sort`, the order its page shows: the pages not loaded yet are fetched first, so
    /// they sort into place instead of being left out, then the queue starts at the song `startID` (the first in that
    /// order when nil: the header's Play). A newer playback choice or a transport choice (Pause) made while the pages
    /// load wins. A page that fails, or a cancelled task, starts nothing: the queue stays, and a failure shows its
    /// notice with Try Again. A playlist longer than the page bound plays the part loaded, sorted, and says so.
    func playPlaylistSorted(_ loaded: [Track], continuation: String?, provider id: ProviderID, sort: TrackSort,
                            startID: String? = nil, from context: PlayingFrom) async {
        let request = beginPlayRequest()
        var all = loaded
        var incomplete = false
        if let continuation, let provider = provider(id) {
            do {
                all += try await remainingPlaylistTracks(after: loaded, continuation: continuation, provider: provider)
            } catch let partial as PlaylistLoadIncomplete {
                all += partial.tracks
                incomplete = true
            } catch {
                guard canStartPlayRequest(request), !Task.isCancelled else { return }
                return report(error, doing: "Couldn’t play “\(context.title)”", service: id, retry: {
                    Task { await self.playPlaylistSorted(loaded, continuation: continuation, provider: id, sort: sort, startID: startID, from: context) }
                })
            }
        }
        guard canStartPlayRequest(request), !Task.isCancelled else { return }
        let order = sort.ordered(all, indices: Array(all.indices), length: { displayDuration(for: $0) })
        let start = startID.flatMap { id in order.firstIndex { all[$0].id == id } } ?? 0
        startPlaying(order.map { all[$0] }, startAt: start, from: context)
        if incomplete { showIncomplete(all.count, of: context.title, "Playing those in this order.") }
    }

    /// Several selected songs after the current one, in the order given (the order shown).
    func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        player.playNext(tracks)
        show(Notice(text: "Playing next", symbol: "text.line.first.and.arrowtriangle.forward"))
    }

    /// Several selected songs at the end of Up Next, in the order given.
    func addToQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        player.addToQueue(tracks)
        show(Notice(text: "Added to queue", symbol: "text.line.last.and.arrowtriangle.forward"))
    }

    func playNext(_ item: MediaItem) { queue(item, next: true) }

    func addToQueue(_ item: MediaItem) { queue(item, next: false) }

    /// Play Next / Add to Queue of an album, playlist or artist. A failure is reported here, with a Try Again that
    /// repeats the command; a playlist past the page bound queues the part loaded and says so.
    private func queue(_ item: MediaItem, next: Bool) {
        Task {
            let tracks: [Track]
            var incomplete = false
            do {
                tracks = try await loadTracks(for: item).0
            } catch let partial as PlaylistLoadIncomplete {
                tracks = partial.tracks
                incomplete = true
            } catch {
                return report(error, doing: "Couldn’t load “\(item.title)”", service: item.provider, retry: { self.queue(item, next: next) })
            }
            if next { player.playNext(tracks) } else { player.addToQueue(tracks) }
            if incomplete {
                showIncomplete(tracks.count, of: item.title, next ? "Playing those next." : "Added those to the queue.")
            } else if next {
                show(Notice(text: "Playing next", symbol: "text.line.first.and.arrowtriangle.forward"))
            } else {
                show(Notice(text: "Added to queue", symbol: "text.line.last.and.arrowtriangle.forward"))
            }
        }
    }

    func startRadio(_ track: Track) {
        guard let provider = provider(track.provider) else { return }
        let key = PlayRequestKey.radio("\(track.provider.rawValue):\(track.providerID)")
        guard !isPlayPending(key) else { return }
        let request = beginPlayRequest(pending: key)
        Task {
            do {
                let tracks = try await provider.radio(seed: track)
                guard canStartPlayRequest(request) else { return }
                finishPlayRequest(request)
                startPlaying([track] + tracks.filter { $0.id != track.id }, from: PlayingFrom(title: "\(track.title) Radio"))
                // The row opens the song's artist; a song with no linked artist has no page to open, so no row.
                if let ref = track.artists.first(where: { $0.id != nil }), let artistID = ref.id {
                    let artist = Artist(providerID: artistID, provider: track.provider, name: ref.name)
                    collections.recordPlayed(.radio(RadioStation(provider: track.provider, seedID: track.providerID, name: track.title,
                                                                 artwork: track.artwork, origin: .artist(artist), seedTrack: track)))
                }
            } catch {
                guard canStartPlayRequest(request) else { return }
                finishPlayRequest(request)
                report(error, doing: "Couldn’t start “\(track.title)” Radio", service: track.provider, retry: { self.startRadio(track) })
            }
        }
    }

    /// An artist or playlist radio. `origin` (the artist or playlist) gives the sidebar row its artwork and page.
    func startRadio(seedID: String, title: String, provider id: ProviderID, origin: MediaItem? = nil) {
        guard let provider = provider(id) else { return }
        let key = PlayRequestKey.radio("\(id.rawValue):\(seedID)")
        guard !isPlayPending(key) else { return }
        let request = beginPlayRequest(pending: key)
        Task {
            do {
                let tracks = try await provider.radio(seedID: seedID)
                guard canStartPlayRequest(request) else { return }
                finishPlayRequest(request)
                startPlaying(tracks, from: PlayingFrom(title: "\(title) Radio"))
                if let origin {
                    collections.recordPlayed(.radio(RadioStation(provider: id, seedID: seedID, name: title,
                                                                 artwork: origin.artwork, origin: origin)))
                }
            } catch {
                guard canStartPlayRequest(request) else { return }
                finishPlayRequest(request)
                report(error, doing: "Couldn’t start “\(title)” Radio", service: id,
                       retry: { self.startRadio(seedID: seedID, title: title, provider: id, origin: origin) })
            }
        }
    }

    /// An item's songs as a drop or Add to Playlist resolved them: all of them, or (a playlist past the page bound)
    /// the first part, which the operation's own notice then names (`partPhrase`).
    struct ResolvedTracks {
        var tracks: [Track]
        var context: PlayingFrom
        /// Set when only the first part loaded: the item's title and how many songs came.
        var part: PartLoaded?
    }

    /// Part of a collection's songs, the first `count` of `title`.
    struct PartLoaded: Equatable {
        let title: String
        let count: Int
    }

    /// Resolves the tracks behind any item, for a drop or Add to Playlist; a failure is reported. A playlist past
    /// the page bound gives the part loaded, marked so, and shows nothing itself: the operation that uses the songs
    /// publishes one notice that says what it did with that part ("Added the first 4,000 songs of “X” to the queue").
    func tracks(for item: MediaItem) async -> ResolvedTracks? {
        do {
            let (tracks, context) = try await loadTracks(for: item)
            return ResolvedTracks(tracks: tracks, context: context)
        } catch let partial as PlaylistLoadIncomplete {
            return ResolvedTracks(tracks: partial.tracks, context: PlayingFrom(title: item.title),
                                  part: PartLoaded(title: item.title, count: partial.tracks.count))
        } catch {
            report(error, doing: "Couldn’t load “\(item.title)”", service: item.provider)
            return nil
        }
    }

    /// "the first 4,000 songs of “X”", one per part-loaded item, joined with "and".
    static func partPhrase(_ parts: [PartLoaded]) -> String {
        ListFormatter.localizedString(byJoining: parts.map { "the first \($0.count.formatted()) songs of “\($0.title)”" })
    }

    /// An operation done with part of a playlist: says so until closed, as the page bound's other notices do.
    func showPartial(_ text: String) {
        show(Notice(text: text, symbol: "exclamationmark.triangle.fill", kind: .failure))
    }

    /// The tracks behind any item, passing a failure on (play requests report it only while still current).
    func loadTracks(for item: MediaItem) async throws -> ([Track], PlayingFrom) {
        guard let provider = provider(item.provider) else { throw ProviderError.notSupported("Playing from \(item.provider.displayName)") }
        switch item {
        case .track(let t):
            return ([t], PlayingFrom(title: t.title))
        case .album(let a):
            let detail: AlbumDetail = try await cached("album:\(a.id)") { try await provider.album(id: a.providerID) }
            return (detail.tracks, PlayingFrom(title: a.title, route: .album(a.provider, id: a.providerID, preview: a)))
        case .playlist(let p):
            let detail: PlaylistDetail = try await cached("playlist:\(p.id)") { try await provider.playlist(id: p.providerID) }
            // Play Next / Add to Queue take the whole playlist, not just its first page, and never part of it: a page
            // that fails fails the command. Each song once, as the page lists it. Past the page bound the part loaded
            // comes back in `PlaylistLoadIncomplete`, for the caller to use and name.
            let first = Self.eachOnce(detail.tracks)
            do {
                let rest = try await remainingPlaylistTracks(after: first, continuation: detail.continuation, provider: provider)
                return (first + rest, PlayingFrom(title: p.title, route: .playlist(p.provider, id: p.providerID, preview: p)))
            } catch let partial as PlaylistLoadIncomplete {
                throw PlaylistLoadIncomplete(tracks: first + partial.tracks)
            }
        case .artist(let a):
            let detail: ArtistDetail = try await cached("artist:\(a.id)") { try await provider.artist(id: a.providerID) }
            return (detail.topTracks, PlayingFrom(title: a.name, route: .artist(a.provider, id: a.providerID, preview: a)))
        }
    }

    private func cached<T: Sendable>(_ key: String, _ load: () async throws -> T) async throws -> T {
        if let hit: (value: T, date: Date) = cache.value(for: key) { return hit.value }
        let value = try await load()
        cache.set(value, for: key)
        return value
    }

    // MARK: Library actions

    func isLiked(_ track: Track) -> Bool { likedTrackIDs.contains(track.id) }

    func toggleLike(_ track: Track) { setLiked(track, liked: !isLiked(track)) }

    /// Likes or unlikes at once and puts the heart back if the service refuses. Try Again asks for the same state
    /// again (not a toggle), so a second failure can't flip it the other way.
    func setLiked(_ track: Track, liked: Bool) {
        guard let provider = provider(track.provider) else { return }
        if liked { likedTrackIDs.insert(track.id) } else { likedTrackIDs.remove(track.id) }
        Task {
            do {
                try await provider.setLiked(track, liked: liked)
                cache.invalidate(prefix: "library")
            } catch {
                if liked { likedTrackIDs.remove(track.id) } else { likedTrackIDs.insert(track.id) }
                report(error, doing: liked ? "Couldn’t like “\(track.title)”" : "Couldn’t unlike “\(track.title)”",
                       write: true, service: track.provider, retry: { self.setLiked(track, liked: liked) })
            }
        }
    }

    /// Whether an album or playlist is in the library, or an artist followed. `nil` when nothing says: no page of
    /// it was shown, the listing carried no flag, and the listener hasn't saved it here.
    /// `reported` is what the page on screen was told, before `noteSaved` passes it on.
    func isSaved(_ item: MediaItem, reported: Bool? = nil) -> Bool? {
        if let state = savedStates[item.id] { return state }
        if let reported = reported ?? Self.reportedSaved(item) { return reported }
        if case .playlist(let p) = item, libraryPlaylists[p.provider]?.contains(where: { $0.providerID == p.providerID }) == true {
            return true
        }
        return nil
    }

    /// The flag a listing or page carried (YouTube's toggle button, "1"/"0"), when it carried one.
    static func reportedSaved(_ item: MediaItem) -> Bool? {
        let extra: [String: String] = switch item {
        case .album(let a): a.extra
        case .playlist(let p): p.extra
        case .artist(let a): a.extra
        case .track: [:]
        }
        switch extra["saved"] {
        case "1", "true": return true
        case "0", "false": return false
        default: return nil
        }
    }

    /// A page tells the model what the service said (an album's or playlist's saved flag, an artist's follow) so
    /// cards, context menus and the sidebar say the same as the page. Once the listener saved or unsaved it in
    /// this session their request wins: a page loaded right after the change can still carry the old flag.
    func noteSaved(_ item: MediaItem, reported: Bool?) {
        guard let reported, savedWrites[item.id] == nil, savedStates[item.id] != reported else { return }
        savedStates[item.id] = reported
        confirmedSaved[item.id] = reported
    }

    /// The Save or Follow item for a collection, or nil where the service can't save it (signed out, no library
    /// or follow support, or the listener's own playlist, which is in the library by definition). Hero buttons and
    /// every context menu take their label from here, so they always agree.
    func saveAction(for item: MediaItem, reported: Bool? = nil) -> SaveAction? {
        guard provider(item.provider)?.isSignedIn ?? false else { return nil }
        let saved = isSaved(item, reported: reported) ?? false
        switch item {
        case .artist:
            guard can(.follow, item.provider) else { return nil }
            return SaveAction(target: !saved, title: saved ? "Unfollow" : "Follow",
                              symbol: saved ? "person.badge.minus" : "person.badge.plus")
        case .album, .playlist:
            guard can(.library, item.provider) else { return nil }
            if case .playlist(let p) = item, p.isEditable { return nil }
            return SaveAction(target: !saved, title: saved ? "Remove from Library" : "Add to Library",
                              symbol: saved ? "minus.circle" : "plus")
        case .track:
            return nil
        }
    }

    /// Drops what's known about a service's saved and followed collections, when its account may have changed.
    private func forgetSavedStates(for provider: ProviderID) {
        let marker = ":\(provider.rawValue):"
        func keep(_ key: String) -> Bool { !key.contains(marker) }
        if savedStates.keys.contains(where: { !keep($0) }) { savedStates = savedStates.filter { keep($0.key) } }
        confirmedSaved = confirmedSaved.filter { keep($0.key) }
        savedWrites = savedWrites.filter { keep($0.key) }
    }

    struct SaveAction: Equatable {
        /// The state the action asks for.
        let target: Bool
        let title: String
        let symbol: String
    }

    /// Saves or unsaves (follows or unfollows) at once, and puts the old state back if the service refuses. Try
    /// Again asks for the same state again (not a toggle). After the service took it, the cached page is dropped
    /// so the next visit loads what the service now says.
    func setSaved(_ item: MediaItem, saved: Bool) {
        guard let provider = provider(item.provider) else { return }
        let id = item.id
        let generation = (savedWrites[id] ?? 0) + 1
        savedWrites[id] = generation
        if confirmedSaved[id] == nil, let known = isSaved(item) { confirmedSaved[id] = known }
        savedStates[id] = saved
        let isArtist: Bool = if case .artist = item { true } else { false }
        Task {
            do {
                try await provider.setSaved(item, saved: saved)
                confirmedSaved[id] = saved
                // A playlist joins or leaves the sidebar's Playlists at once, not at the next library refresh.
                if case .playlist(let p) = item {
                    var lists = libraryPlaylists[p.provider] ?? []
                    lists.removeAll { $0.providerID == p.providerID }
                    if saved { lists.insert(p, at: 0) }
                    if libraryPlaylists[p.provider] != nil || saved { libraryPlaylists[p.provider] = lists }
                }
                cache.invalidate(prefix: "library")
                // `MediaItem.id` is the page's cache key ("album:<provider>:<id>"), and `tracks(for:)`'s.
                cache.remove(id)
                show(Notice(text: isArtist ? (saved ? "Following \(item.title)" : "Unfollowed \(item.title)")
                                           : (saved ? "Added to library" : "Removed from library")))
            } catch {
                // Only the latest request decides what shows: an older one failing after a newer one doesn't undo it.
                // (A sign-in change since forgot the request: put back what the new account's pages say.)
                if savedWrites[id] == generation || savedWrites[id] == nil {
                    if let confirmed = confirmedSaved[id] { savedStates[id] = confirmed } else { savedStates[id] = nil }
                }
                let doing = isArtist
                    ? (saved ? "Couldn’t follow “\(item.title)”" : "Couldn’t unfollow “\(item.title)”")
                    : (saved ? "Couldn’t add “\(item.title)” to your library" : "Couldn’t remove “\(item.title)” from your library")
                report(error, doing: doing, write: true, service: item.provider, retry: { self.setSaved(item, saved: saved) })
            }
        }
    }

    /// Appends the songs. `parts` names the collections only partly loaded (past the page bound): the notice then
    /// says which part went in instead of "Added to …". The returned task ends when the request has finished or failed.
    @discardableResult
    func add(_ tracks: [Track], to playlist: Playlist, parts: [PartLoaded] = []) -> Task<Void, Never> {
        // One edit at a time: an add waits for a removal's requests (or a partly applied edit) like any other edit,
        // and as a new playlist edit it takes the last one's Undo away (`beginPlaylistEdit`). It is bound to the
        // account it began under: after a switch it sends nothing and publishes nothing.
        guard let provider = provider(playlist.provider),
              let lock = beginPlaylistEdit(playlist, provider: provider, doing: "Couldn’t add \(Self.songsPhrase(tracks)) to “\(playlist.title)”",
                                           retry: { self.add(tracks, to: playlist, parts: parts) }) else { return Task {} }
        let task = Task {
            do {
                guard isCurrent(lock, provider) else { return }
                try requireSendable(lock, provider)
                try await provider.add(tracks, toPlaylist: playlist.providerID, as: lock.account.write)
                guard isCurrent(lock, provider) else { return }
                endPlaylistEdit(playlist, lock)
                cache.invalidate(prefix: "playlist:\(playlist.provider.rawValue):\(playlist.providerID)")
                if parts.isEmpty {
                    show(Notice(text: "Added to \(playlist.title)"))
                } else {
                    showPartial("Added \(Self.partPhrase(parts)) to “\(playlist.title)”")
                }
            } catch {
                guard isCurrent(lock, provider) else { return }
                endPlaylistEdit(playlist, lock)
                report(error, doing: "Couldn’t add \(Self.songsPhrase(tracks)) to “\(playlist.title)”",
                       write: true, service: playlist.provider, account: lock.account, retry: { self.add(tracks, to: playlist, parts: parts) })
            }
        }
        lock.task = task
        return task
    }

    // MARK: Editing a playlist: one edit at a time, single-level Undo

    /// A playlist's key for its edits: its page's cache key.
    static func playlistKey(_ playlist: Playlist) -> String { "playlist:\(playlist.provider.rawValue):\(playlist.providerID)" }

    /// A playlist's edit while it isn't idle (`playlistEdits`). Kept in the model, never in a notice: closing or
    /// replacing a notice doesn't unlock a playlist.
    enum PlaylistEditState {
        /// Requests to it are in flight, under the lock's account: a removal (its record, once its places are read),
        /// its Try Again or Undo, an add, or Add Back at End.
        case inFlight(PlaylistEditLock)
        /// A run stopped partway: the service acknowledged some requests and not the rest. Locked until Try Again
        /// finishes it, its Undo puts back what the service acknowledged, or the listener chooses Leave As Is.
        case partial(PlaylistEdit)
    }

    /// Whether the playlist takes an edit now: idle, nothing in flight and nothing partly applied. Its Remove and Add
    /// to Playlist items are disabled otherwise.
    func canEdit(_ playlist: Playlist) -> Bool { playlistEdits[Self.playlistKey(playlist)] == nil }

    /// The playlist's partly applied edit, waiting on Try Again, Undo or Leave As Is (the playlist page's banner).
    func partialEdit(of playlist: Playlist) -> PlaylistEdit? { partialEdit(key: Self.playlistKey(playlist)) }

    /// The partly applied edit of the playlist with this key (`playlistKey`).
    func partialEdit(key: String) -> PlaylistEdit? {
        if case .partial(let edit) = playlistEdits[key] { return edit }
        return nil
    }

    /// Refuses an edit the playlist can't take now and says why: "Finishing the last change to “P”…" while a request
    /// is in flight; for a partly applied edit its failure notice, with Try Again, Undo and Leave As Is, comes back
    /// (it stays when it is already up).
    func refusesEdit(_ playlist: Playlist, explain: Bool = true) -> Bool {
        switch playlistEdits[Self.playlistKey(playlist)] {
        case nil:
            return false
        case .inFlight:
            if explain { show(Notice(text: "Finishing the last change to “\(playlist.title)”…", symbol: "clock")) }
        case .partial(let edit):
            if explain, notice?.edit !== edit { show(failureNotice(edit)) }
        }
        return true
    }

    /// Starts a new edit of the playlist, or refuses it (`refusesEdit`). A new edit first takes every earlier playlist
    /// edit's Undo away (single-level history); `endPlaylistEdit` ends it.
    ///
    /// It belongs to the service's current account, or, for a recovery (Add Back at End and its Try Again), to
    /// `account`, the original edit's, never re-captured. Either way the service must send as that account now: during
    /// a sign-in swap, signed out, or holding another account, nothing starts and the notice says why ("`doing`. Your
    /// Spotify sign-in was changing.") with `retry`.
    private func beginPlaylistEdit(_ playlist: Playlist, provider: any MusicProvider, account recovering: PlaylistEditAccount? = nil,
                                   doing: String, retry: @escaping @MainActor () -> Void) -> PlaylistEditLock? {
        guard !refusesEdit(playlist) else { return nil }
        let account = recovering ?? PlaylistEditAccount(provider: playlist.provider, session: provider.session)
        guard account.canSend(with: provider.session) else {
            report(PlaylistSignInChanging(), doing: doing, write: true, service: playlist.provider, account: recovering, retry: retry)
            return nil
        }
        purgePlaylistUndo()
        watchEditAccounts()
        let lock = PlaylistEditLock(account: account)
        playlistEdits[Self.playlistKey(playlist)] = .inFlight(lock)
        return lock
    }

    /// Unlocks the playlist, if `lock` still holds it.
    private func endPlaylistEdit(_ playlist: Playlist, _ lock: PlaylistEditLock) {
        let key = Self.playlistKey(playlist)
        if case .inFlight(let holder) = playlistEdits[key], holder === lock { playlistEdits[key] = nil }
    }

    /// The run holding `lock` may go on: not cancelled, and its service still holds the account it began under (a
    /// new token for the same account counts). Checked after every wait; a run that fails it stops and publishes
    /// nothing.
    private func isCurrent(_ lock: PlaylistEditLock, _ provider: any MusicProvider) -> Bool {
        !lock.isCancelled && lock.account.isHeld(by: provider.session)
    }

    /// The edit's account is still its service's (`PlaylistEditAccount.isHeld`).
    private func isCurrent(_ account: PlaylistEditAccount) -> Bool {
        provider(account.provider).map { account.isHeld(by: $0.session) } ?? false
    }

    /// Before every request: the service sends it as the edit's account right now, with no swap of its sign-in under
    /// way; otherwise nothing is sent and the run stops with `PlaylistSignInChanging` (Try Again).
    private func requireSendable(_ lock: PlaylistEditLock, _ provider: any MusicProvider) throws {
        guard lock.account.canSend(with: provider.session) else { throw PlaylistSignInChanging() }
    }

    /// Takes the settled playlist edit's Undo off its undo manager (only the actions registered with its service's
    /// `PlaylistUndoTarget`: the queue's and text fields' stay), a deferred registration of it, and its notice; and
    /// drops a changed playlist's Add Back at End.
    private func purgePlaylistUndo() {
        if let drifted = driftedEdit {
            driftedEdit = nil
            if notice?.edit === drifted { notice = nil }
        }
        guard let edit = undoablePlaylistEdit else { return }
        undoablePlaylistEdit = nil
        undoRegistrations &+= 1
        edit.undoManager?.removeAllActions(withTarget: undoTarget(edit.playlist.provider))
        if notice?.edit === edit { notice = nil }
    }

    /// The target a service's playlist edits register their Undo with.
    private func undoTarget(_ provider: ProviderID) -> PlaylistUndoTarget {
        if let target = playlistUndoTargets[provider] { return target }
        let target = PlaylistUndoTarget()
        playlistUndoTargets[provider] = target
        return target
    }

    // MARK: Playlist edits belong to an account

    /// Watches every service's session from the first playlist edit on (`dropEditsOfChangedAccounts`).
    private func watchEditAccounts() {
        guard !watchesEditAccounts else { return }
        watchesEditAccounts = true
        observeEditAccounts()
    }

    private func observeEditAccounts() {
        withObservationTracking {
            for provider in providers { _ = provider.session }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.dropEditsOfChangedAccounts()
                self.observeEditAccounts()
            }
        }
    }

    /// A service's session changed (a sign-out, another account, a sign-in in progress): every playlist edit begun
    /// under its old session ends here. Runs in flight are cancelled (their late answers publish nothing), locks and
    /// partly applied edits are released, the settled edit's Undo leaves the undo manager, and their notices, a
    /// changed playlist's Add Back at End and a removal waiting for confirmation go.
    func dropEditsOfChangedAccounts() {
        for (key, state) in playlistEdits {
            switch state {
            case .inFlight(let lock) where !isCurrent(lock.account):
                lock.cancel()
                playlistEdits[key] = nil
            case .partial(let edit) where !isCurrent(edit.account):
                edit.failureText = nil
                playlistEdits[key] = nil
            default:
                break
            }
        }
        if let edit = undoablePlaylistEdit, !isCurrent(edit.account) { purgePlaylistUndo() }
        if let edit = driftedEdit, !isCurrent(edit.account) { driftedEdit = nil }
        if let account = notice?.account, !isCurrent(account) { notice = nil }
        if let account = pendingPlaylistRemoval?.account, !isCurrent(account) { pendingPlaylistRemoval = nil }
        if let read = confirmationRead, !isCurrent(read.account) {
            read.task.cancel()
            confirmationRead = nil
        }
    }

    /// The copies of a removal the listener has to confirm, being counted (`requestRemove`): cancelled when its account
    /// goes.
    @ObservationIgnored private var confirmationRead: (account: PlaylistEditAccount, task: Task<Void, Never>)?

    // MARK: Removing from a playlist

    /// A removal the listener has to confirm first: the service can't put the song back where it was
    /// (`MainWindow`'s confirmation dialog names the song, the playlist and how many copies go).
    struct PendingPlaylistRemoval: Identifiable {
        let id = UUID()
        let tracks: [Track]
        let playlist: Playlist
        /// Every entry the songs hold in the playlist (each copy counted; at least one per song).
        var entries: Int
        /// The account the copies were counted under: the dialog goes when it changes.
        var account: PlaylistEditAccount?

        init(tracks: [Track], playlist: Playlist, entries: Int? = nil, account: PlaylistEditAccount? = nil) {
            self.tracks = tracks
            self.playlist = playlist
            self.entries = max(entries ?? tracks.count, tracks.count)
            self.account = account
        }

        /// "“Espresso”", "both copies of “Espresso”", "3 songs (5 copies in all)".
        var phrase: String { AppModel.removalPhrase(tracks, entries: entries) }
    }

    /// Set by "Remove from Playlist" on a service that can't put a song back in place; the main window asks.
    var pendingPlaylistRemoval: PendingPlaylistRemoval?

    /// The service can put a removed song back at its old place, so removal goes at once with Undo.
    func canRestorePlaylistRemoval(_ playlist: Playlist) -> Bool { can(.playlistInsert, playlist.provider) }

    /// "Remove from Playlist": at once, with Undo (Edit menu and the notice), where the service can put the songs
    /// back in place; otherwise only after the listener confirms (`pendingPlaylistRemoval`). A song goes from the
    /// playlist entirely, every copy (a playlist lists it once, `PlaylistPager`): the confirmation counts the copies
    /// first, so it can say "both copies"; the notice with Undo says it after the removal.
    func requestRemove(_ tracks: [Track], from playlist: Playlist, undoManager: UndoManager?) {
        guard !tracks.isEmpty, !refusesEdit(playlist) else { return }
        if canRestorePlaylistRemoval(playlist) {
            remove(tracks, from: playlist, undoManager: undoManager)
        } else {
            guard let provider = provider(playlist.provider) else { return }
            let account = PlaylistEditAccount(provider: playlist.provider, session: provider.session)
            guard account.canSend(with: provider.session) else {
                return report(PlaylistSignInChanging(), doing: "Couldn’t remove \(Self.songsPhrase(tracks)) from “\(playlist.title)”",
                              write: true, service: playlist.provider,
                              retry: { [weak undoManager] in self.requestRemove(tracks, from: playlist, undoManager: undoManager) })
            }
            watchEditAccounts()
            confirmationRead?.task.cancel()
            let task = Task {
                do {
                    let listing = try await readListing(playlist, provider: provider, account: account)
                    guard !Task.isCancelled, isCurrent(account) else { return }
                    confirmationRead = nil
                    pendingPlaylistRemoval = PendingPlaylistRemoval(tracks: tracks, playlist: playlist,
                                                                    entries: Self.places(of: tracks, in: listing).count, account: account)
                } catch {
                    guard !Task.isCancelled, isCurrent(account) else { return }
                    confirmationRead = nil
                    report(error, doing: "Couldn’t remove \(Self.songsPhrase(tracks)) from “\(playlist.title)”", service: playlist.provider,
                           account: account, retry: { [weak undoManager] in self.requestRemove(tracks, from: playlist, undoManager: undoManager) })
                }
            }
            confirmationRead = (account, task)
        }
    }

    /// Removes the songs, every copy (both services remove a song entirely), as one `PlaylistEdit`. Where the service
    /// can put them back, it first reads the playlist (every page, fresh), which gives each copy's place and the
    /// entries a later Undo compares against, and once every request is acknowledged registers the one Undo with
    /// `undoManager` (the main window's when nil) and offers the same Undo in the notice, which says how many copies
    /// went. `entries` is the confirmed removal's count of copies, for its notice. Refused while the playlist isn't
    /// idle (`beginPlaylistEdit`). The returned task ends when the removal has finished or failed.
    ///
    /// The songs go in requests of at most the service's `playlistEditBatchSize` (Spotify: 100). When one fails after
    /// others went through, the page refreshes and the playlist stays locked (`PlaylistEditState.partial`): Try Again
    /// goes on with the rest, keeping the places read before the first request; Undo puts back exactly the songs the
    /// service took out; Leave As Is keeps what the service has.
    @discardableResult
    func remove(_ tracks: [Track], from playlist: Playlist, undoManager: UndoManager? = nil, entries: Int? = nil) -> Task<Void, Never> {
        weak let undoManager = undoManager ?? mainWindow?.undoManager
        guard let provider = provider(playlist.provider),
              let lock = beginPlaylistEdit(playlist, provider: provider, doing: "Couldn’t remove \(Self.songsPhrase(Self.eachOnce(tracks))) from “\(playlist.title)”",
                                           retry: { self.remove(tracks, from: playlist, undoManager: undoManager, entries: entries) }) else { return Task {} }
        let restorable = canRestorePlaylistRemoval(playlist)
        let tracks = Self.eachOnce(tracks)
        let key = Self.playlistKey(playlist)
        return editTask(lock) { [self] in
            var listing: PlaylistListing?
            do {
                if restorable {
                    listing = try await readListing(playlist, provider: provider, account: lock.account)
                }
            } catch {
                guard isCurrent(lock, provider) else { return }
                endPlaylistEdit(playlist, lock)
                return report(error, doing: "Couldn’t remove \(Self.songsPhrase(tracks)) from “\(playlist.title)”",
                              write: true, service: playlist.provider, account: lock.account,
                              retry: { self.remove(tracks, from: playlist, undoManager: undoManager, entries: entries) })
            }
            guard isCurrent(lock, provider) else { return }
            let places = listing.map { Self.places(of: tracks, in: $0) } ?? []
            let edit = PlaylistEdit(playlist: playlist, key: key, tracks: tracks, places: places, entries: entries,
                                    account: lock.account, before: listing?.entries ?? [])
            edit.undoManager = undoManager
            await run(edit, lock: lock, provider: provider)
        }
    }

    /// Runs a playlist edit in a task of its own, held by its lock (cancelled with it) and kept as `lastPlaylistEdit`.
    @discardableResult
    private func editTask(_ lock: PlaylistEditLock, _ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let task = Task { await work() }
        lock.task = task
        lastPlaylistEdit = task
        return task
    }

    /// Starts the edit's next run toward `goal`: its Try Again or an Undo, under the account it began with. The
    /// callers check the state it starts from. A notice of this edit (its Undo, its Try Again) is replaced at once by
    /// what is happening, so no other way in to the same action stays usable.
    private func start(_ edit: PlaylistEdit, toward goal: PlaylistEdit.Goal, resuming: Bool = false) {
        guard edit.hasWork(toward: goal), isCurrent(edit.account), let provider = provider(edit.playlist.provider) else { return }
        edit.begin(goal, resuming: resuming)
        let lock = PlaylistEditLock(account: edit.account)
        playlistEdits[edit.key] = .inFlight(lock)
        if notice?.edit === edit {
            switch goal {
            case .putBack:
                show(Notice(text: "Putting \(edit.phrase(places: edit.putBackPlaces)) back in “\(edit.playlist.title)”…", symbol: "clock"))
            case .remove(let scope):
                show(Notice(text: "Removing \(edit.phrase(removing: scope)) from “\(edit.playlist.title)”…", symbol: "clock"))
            }
        }
        editTask(lock) { [self] in await run(edit, lock: lock, provider: provider) }
    }

    /// Sends the edit's requests toward its goal until it is reached or a request fails, recording each acknowledged
    /// request in the edit. The playlist is in flight under `lock` (set by the caller); this settles it: idle once the
    /// goal is reached (a removal's Undo registered then), partly applied when a request failed after the service
    /// changed something, idle again when a removal failed before anything went.
    ///
    /// A put-back first reads the playlist again (fresh, every page) and goes on only if it is exactly what this
    /// record's acknowledged requests left (`PlaylistEdit.isUnchanged`); otherwise the playlist changed outside OpenMusic,
    /// its places mean something else now, and `playlistChanged` offers Add Back at End instead. A read that fails
    /// counts as a failed put-back request (the edit is then partly applied, with Try Again).
    ///
    /// The run stops without a word when its account's session changes (`isCurrent`, checked before each request and
    /// after each wait): the model has dropped the edit by then.
    private func run(_ edit: PlaylistEdit, lock: PlaylistEditLock, provider: any MusicProvider) async {
        let playlist = edit.playlist
        let batch = max(1, provider.playlistEditBatchSize ?? max(edit.tracks.count, edit.places.count))
        var changed = false
        var failure: (any Error)?
        do {
            switch edit.goal {
            case .remove(let scope):
                while true {
                    let next = Array(edit.songsToRemove(scope).prefix(batch))
                    if next.isEmpty { break }
                    guard isCurrent(lock, provider) else { return }
                    try requireSendable(lock, provider)
                    try await provider.remove(next, fromPlaylist: playlist.providerID, as: lock.account.write)
                    guard isCurrent(lock, provider) else { return }
                    edit.acknowledgeRemoved(next)
                    changed = true
                }
            case .putBack:
                let listing = try await readListing(playlist, provider: provider, account: lock.account)
                guard isCurrent(lock, provider) else { return }
                guard edit.isUnchanged(listing) else { return playlistChanged(edit, lock: lock) }
                while true {
                    let next = edit.nextPutBack(batch: batch)
                    guard let first = next.first else { break }
                    guard isCurrent(lock, provider) else { return }
                    try requireSendable(lock, provider)
                    try await provider.insert(next.map { edit.places[$0].track }, intoPlaylist: playlist.providerID, at: edit.places[first].index,
                                              as: lock.account.write)
                    guard isCurrent(lock, provider) else { return }
                    edit.acknowledgePutBack(next)
                    changed = true
                }
            }
        } catch {
            guard isCurrent(lock, provider) else { return }
            failure = error
        }
        if changed { playlistDidChange(playlist) }
        let title = playlist.title
        guard let failure else {
            playlistEdits[edit.key] = nil
            edit.failureText = nil
            switch edit.goal {
            case .remove(let scope):
                // Settled: the removal's one Undo (Edit menu and the notice), where the service can put songs back.
                let undoable = edit.canPutBack
                if undoable { registerUndo(of: edit) }
                show(Notice(text: "Removed \(edit.phrase(removing: scope)) from “\(title)”", symbol: "minus.circle.fill",
                            action: undoable ? undoAction(edit) : nil, edit: edit))
            case .putBack:
                // No Redo for a playlist edit: removing again is one click.
                show(Notice(text: "Put \(edit.phrase(places: edit.putBackPlaces)) back in “\(title)”", edit: edit))
            }
            return
        }
        let doing: String
        switch edit.goal {
        case .remove(let scope):
            let done = edit.removedCount(scope)
            doing = done > 0
                ? "Removed only \(done) of \(scope.count) songs from “\(title)”"
                : "Couldn’t remove \(Self.songsPhrase(edit.tracks.filter { scope.contains($0.id) })) from “\(title)”"
            // Nothing went: the playlist is as it was, so it is idle again, and Try Again is a new removal.
            if !edit.hasChanged {
                playlistEdits[edit.key] = nil
                weak let undoManager = edit.undoManager
                return report(failure, doing: doing, write: true, service: playlist.provider, account: edit.account,
                              retry: { [weak self, edit] in self?.remove(edit.tracks, from: playlist, undoManager: undoManager, entries: edit.entries) })
            }
        case .putBack:
            doing = "Couldn’t put \(Self.songsPhrase(Self.eachOnce(edit.putBackPlaces.map { edit.places[$0].track }))) back in “\(title)”"
        }
        // Partly applied: locked until Try Again, Undo or Leave As Is.
        noticeLog.error("\(doing, privacy: .public) failed: \(String(describing: failure), privacy: .private)")
        let reason = FailureReason(failure, write: true, service: playlist.provider)
        edit.failureText = "\(doing). \(reason.text)"
        edit.canRetry = reason.isRecoverable
        playlistEdits[edit.key] = .partial(edit)
        show(failureNotice(edit))
    }

    /// A partly applied edit's failure notice: Undo (for a removal: the songs that went), Try Again (when a second
    /// attempt can work) and Leave As Is. Closing it leaves the playlist locked; the playlist page's banner offers the
    /// same buttons, and an edit refused meanwhile shows it again.
    func failureNotice(_ edit: PlaylistEdit) -> Notice {
        var notice = Notice(text: edit.failureText ?? "Couldn’t finish the last change to “\(edit.playlist.title)”.",
                            symbol: "exclamationmark.triangle.fill", kind: .failure)
        if edit.canRetry {
            notice.retry = { [weak self, edit] in self?.tryAgain(edit) }
        }
        if case .remove = edit.goal, edit.canPutBack {
            notice.action = undoAction(edit)
        }
        notice.secondaryAction = NoticeAction(title: "Leave As Is") { [weak self, edit] in self?.leaveAsIs(edit) }
        notice.edit = edit
        return notice
    }

    /// Whether `edit` is its playlist's partly applied edit.
    private func isPartial(_ edit: PlaylistEdit) -> Bool {
        if case .partial(let waiting) = playlistEdits[edit.key] { return waiting === edit }
        return false
    }

    /// Try Again of a partly applied edit: the same goal, from what the service acknowledged.
    func tryAgain(_ edit: PlaylistEdit) {
        guard isPartial(edit) else { return }
        start(edit, toward: edit.goal, resuming: true)
    }

    /// Undo of a partly applied removal: the places the service acknowledged empty are filled again.
    func undoPartial(_ edit: PlaylistEdit) {
        guard isPartial(edit), case .remove = edit.goal, edit.canPutBack else { return }
        start(edit, toward: .putBack)
    }

    /// Leave As Is: the partly applied edit ends, the playlist stays as the service has it, with no Undo.
    func leaveAsIs(_ edit: PlaylistEdit) {
        guard isPartial(edit) else { return }
        playlistEdits[edit.key] = nil
        edit.failureText = nil
        if notice?.edit === edit { notice = nil }
    }

    // MARK: A playlist changed outside OpenMusic

    /// A put-back found the playlist changed since the edit's last acknowledged request (another device, the service's
    /// own app): nothing goes back at a place that may mean something else now. The edit ends (the playlist is as the
    /// service has it, unlocked, with no Undo), and its notice offers Add Back at End, which appends the songs still
    /// out that the playlist doesn't hold again, or Cancel.
    private func playlistChanged(_ edit: PlaylistEdit, lock: PlaylistEditLock) {
        endPlaylistEdit(edit.playlist, lock)
        // The open page shows the playlist as it is now.
        playlistDidChange(edit.playlist)
        edit.failureText = nil
        driftedEdit = edit
        var notice = Notice(text: "“\(edit.playlist.title)” changed since you removed \(edit.tracks.count == 1 ? "this song" : "these songs").",
                            symbol: "exclamationmark.triangle.fill", kind: .failure)
        notice.action = NoticeAction(title: "Add Back at End") { [weak self, edit] in self?.addBackAtEnd(edit) }
        notice.secondaryAction = NoticeAction(title: "Cancel") { [weak self, edit] in self?.cancelAddBack(edit) }
        notice.edit = edit
        show(notice)
    }

    /// Cancel on a changed playlist's notice: the playlist stays as the service has it.
    func cancelAddBack(_ edit: PlaylistEdit) {
        guard driftedEdit === edit else { return }
        driftedEdit = nil
        if notice?.edit === edit { notice = nil }
    }

    /// Add Back at End on a changed playlist's notice: a new edit (it takes the lock, and any Undo goes) that reads
    /// the playlist again and appends the edit's songs still out, each once, leaving out any it holds again.
    func addBackAtEnd(_ edit: PlaylistEdit) {
        guard driftedEdit === edit, isCurrent(edit.account), let provider = provider(edit.playlist.provider),
              let lock = beginPlaylistEdit(edit.playlist, provider: provider, account: edit.account,
                                           doing: "Couldn’t add \(Self.songsPhrase(edit.songsToAddBack)) back to “\(edit.playlist.title)”",
                                           retry: { [weak self, edit] in self?.addBackAtEnd(edit) }) else { return }
        addBack(edit.songsToAddBack, to: edit.playlist, lock: lock, provider: provider)
    }

    /// Add Back at End's Try Again: the same songs, still bound to the original edit's account.
    private func retryAddBack(_ songs: [Track], to playlist: Playlist, account: PlaylistEditAccount) {
        guard isCurrent(account), let provider = provider(playlist.provider),
              let lock = beginPlaylistEdit(playlist, provider: provider, account: account,
                                           doing: "Couldn’t add \(Self.songsPhrase(songs)) back to “\(playlist.title)”",
                                           retry: { [weak self] in self?.retryAddBack(songs, to: playlist, account: account) }) else { return }
        addBack(songs, to: playlist, lock: lock, provider: provider)
    }

    private func addBack(_ songs: [Track], to playlist: Playlist, lock: PlaylistEditLock, provider: any MusicProvider) {
        let title = playlist.title
        editTask(lock) { [self] in
            do {
                // Only a whole read proves a song absent: a partial one would append songs the rest still holds.
                let listing = try await readListing(playlist, provider: provider, account: lock.account)
                guard isCurrent(lock, provider) else { return }
                guard listing.complete else { throw PlaylistReadIncomplete() }
                let present = listing.songIDs
                let missing = songs.filter { !present.contains($0.id) }
                if !missing.isEmpty {
                    try requireSendable(lock, provider)
                    try await provider.add(missing, toPlaylist: playlist.providerID, as: lock.account.write)
                    guard isCurrent(lock, provider) else { return }
                    playlistDidChange(playlist)
                }
                endPlaylistEdit(playlist, lock)
                show(Notice(text: missing.isEmpty
                                ? "“\(title)” already has \(Self.songsPhrase(songs))"
                                : "Added \(Self.songsPhrase(missing)) back at the end of “\(title)”",
                            account: lock.account))
            } catch {
                guard isCurrent(lock, provider) else { return }
                endPlaylistEdit(playlist, lock)
                let account = lock.account
                // Try Again reads the whole playlist again, so songs that went in before the failure aren't added twice.
                let retry: @MainActor () -> Void = { [weak self] in self?.retryAddBack(songs, to: playlist, account: account) }
                if error is PlaylistReadIncomplete {
                    show(Notice(text: "Couldn’t read all of “\(title)”.", symbol: "exclamationmark.triangle.fill", kind: .failure,
                                retry: retry, account: account))
                } else {
                    report(error, doing: "Couldn’t add \(Self.songsPhrase(songs)) back to “\(title)”", write: true,
                           service: playlist.provider, account: account, retry: retry)
                }
            }
        }
    }

    // MARK: The settled edit's Undo

    /// Puts the settled edit's Undo on its undo manager as the only playlist edit there (any other goes first), in an
    /// undo group of its own at the top level (`registerUndoAtTopLevel`). Undoing it registers nothing, so there is no
    /// Redo.
    ///
    /// Each service's playlist edits are registered with its own `PlaylistUndoTarget`, so purging takes exactly those.
    /// The handler holds the record and the model weakly, and not the manager.
    private func registerUndo(of edit: PlaylistEdit) {
        purgePlaylistUndo()
        undoablePlaylistEdit = edit
        undoRegistrations &+= 1
        registerUndoAtTopLevel(edit, registration: undoRegistrations, attempt: 0)
    }

    /// Tries to defer a registration made inside another component's group this many times (the first few on the
    /// next run-loop turn, then every 50 ms: about 10 s), then leaves the Undo to the notice.
    static let undoRegistrationAttempts = 200

    /// Registers the edit's Undo only at the top level of its undo manager: inside a group someone else opened (with
    /// event grouping, any registration earlier in the same run-loop pass), it would join that group and one ⌘Z would
    /// undo both. So while `groupingLevel` is above 0 it tries again on a later turn, never closing another
    /// component's group; a newer edit (`undoRegistrations`) or an Undo from the notice meanwhile cancels it. At the
    /// top level, event grouping is off for the one registration: `beginUndoGrouping` at level 0 would otherwise open
    /// the pass's event group around ours, and a queue action later in the same pass would join it.
    private func registerUndoAtTopLevel(_ edit: PlaylistEdit, registration: Int, attempt: Int) {
        guard undoablePlaylistEdit === edit, undoRegistrations == registration, let undoManager = edit.undoManager else { return }
        guard undoManager.groupingLevel == 0 else {
            guard attempt < Self.undoRegistrationAttempts else { return }
            let retry: @Sendable () -> Void = { [weak self, edit] in
                MainActor.assumeIsolated { self?.registerUndoAtTopLevel(edit, registration: registration, attempt: attempt + 1) }
            }
            if attempt < 3 {
                RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel], block: retry)
                CFRunLoopWakeUp(CFRunLoopGetMain())
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: retry)
            }
            return
        }
        let groupsByEvent = undoManager.groupsByEvent
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: undoTarget(edit.playlist.provider)) { [weak self, edit] _ in
            MainActor.assumeIsolated { self?.undoSettled(edit) }
        }
        undoManager.setActionName(edit.actionName)
        // Back on before the group closes: observers of its closing may register at once, in a group of their own.
        undoManager.groupsByEvent = groupsByEvent
        undoManager.endUndoGrouping()
    }

    /// Edit › Undo (⌘Z) of the settled edit: the manager has already taken the action off its stack; the notice's
    /// Undo goes as the put-back starts.
    private func undoSettled(_ edit: PlaylistEdit) {
        guard undoablePlaylistEdit === edit, canEdit(edit.playlist), isCurrent(edit.account) else { return }
        undoablePlaylistEdit = nil
        undoRegistrations &+= 1
        start(edit, toward: .putBack)
    }

    /// The notice's Undo: a settled edit's (the Edit menu's entry goes off the stack at once) or a partly applied
    /// removal's.
    private func undoAction(_ edit: PlaylistEdit) -> NoticeAction {
        NoticeAction(title: "Undo") { [weak self, edit] in self?.undoFromNotice(edit) }
    }

    private func undoFromNotice(_ edit: PlaylistEdit) {
        if isPartial(edit) { return undoPartial(edit) }
        guard undoablePlaylistEdit === edit, canEdit(edit.playlist), isCurrent(edit.account) else { return }
        undoablePlaylistEdit = nil
        undoRegistrations &+= 1
        edit.undoManager?.removeAllActions(withTarget: undoTarget(edit.playlist.provider))
        start(edit, toward: .putBack)
    }

    // MARK: Reading a playlist for an edit

    /// The most pages an edit reads of a playlist (Spotify: 100 entries each). A longer playlist reads as incomplete,
    /// so a put-back after it never counts it unchanged and Add Back at End never appends from it.
    static let editReadPageLimit = 200

    /// The playlist's entries as the service has them now, uncached (`MusicProvider.uncachedPlaylist`), every page up
    /// to `editReadPageLimit`, numbered as the service numbers them: entries OpenMusic leaves out (Spotify's local files
    /// and episodes) still take a place (`Page.positions`), with the identity the service gives them, so Undo puts each
    /// copy back where it was. A continuation handed out twice ends the read as incomplete. Before and after every
    /// request it checks cancellation and that the service still sends as `account` (`PlaylistSignInChanging`
    /// otherwise), so a read never goes on as another account.
    private func readListing(_ playlist: Playlist, provider: any MusicProvider, account: PlaylistEditAccount) async throws -> PlaylistListing {
        func check() throws {
            try Task.checkCancellation()
            guard account.canSend(with: provider.session) else { throw PlaylistSignInChanging() }
        }
        var entries: [PlaylistEntry] = []
        func take(_ items: [Track], positions: [Int]?, count: Int?, unlisted: [Int: String]?) {
            let start = entries.count
            var page = (0..<max(count ?? items.count, items.count)).map { PlaylistEntry.unlisted(id: unlisted?[start + $0]) }
            for (offset, track) in items.enumerated() {
                let place = (positions?[safe: offset] ?? start + offset) - start
                guard page.indices.contains(place) else { continue }
                page[place] = .song(id: track.id, entry: track.extra["setVideoId"])
            }
            entries += page
        }
        try check()
        let detail = try await provider.uncachedPlaylist(id: playlist.providerID)
        try check()
        take(detail.tracks, positions: detail.positions, count: detail.entryCount, unlisted: detail.unlistedEntries)
        var token = detail.continuation
        var seen = Set<String>()
        var pages = 0
        while let next = token, pages < Self.editReadPageLimit, seen.insert(next).inserted {
            try check()
            let page = try await provider.uncachedPlaylistTracks(continuation: next)
            try check()
            take(page.items, positions: page.positions, count: page.entryCount, unlisted: page.unlistedEntries)
            token = page.continuation
            pages += 1
        }
        return PlaylistListing(entries: entries, complete: token == nil)
    }

    /// Every place the songs hold in the listing, in place order.
    static func places(of tracks: [Track], in listing: PlaylistListing) -> [(track: Track, index: Int)] {
        let wanted = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return listing.entries.indices.compactMap { index in
            guard case .song(let id, _) = listing.entries[index], let song = wanted[id] else { return nil }
            return (song, index)
        }
    }

    /// The playlist's songs changed on the service: its cached page goes and an open page loads again in place.
    private func playlistDidChange(_ playlist: Playlist) {
        let key = Self.playlistKey(playlist)
        cache.invalidate(prefix: key)
        pageVersions[key, default: 0] += 1
    }

    /// New Playlist (with songs from a drop or a menu): bound to the account the listener started under, like every
    /// playlist write (`MusicProvider.createPlaylist(title:description:as:)`), and refused during a sign-in swap with
    /// Try Again. Once the service acknowledged the playlist it is kept: when adding the songs fails, Try Again adds
    /// them to that playlist (`fillNewPlaylist`) and never makes a second one. The returned task ends once the playlist
    /// is made or creating it failed.
    @discardableResult
    func createPlaylist(_ title: String, provider id: ProviderID, adding tracks: [Track]) -> Task<Void, Never> {
        guard let provider = provider(id) else { return Task {} }
        let account = PlaylistEditAccount(provider: id, session: provider.session)
        let doing = "Couldn’t create “\(title)”"
        let retry: @MainActor () -> Void = { [weak self] in self?.createPlaylist(title, provider: id, adding: tracks) }
        guard account.canSend(with: provider.session) else {
            report(PlaylistSignInChanging(), doing: doing, write: true, service: id, retry: retry)
            return Task {}
        }
        watchEditAccounts()
        return Task {
            let playlist: Playlist
            do {
                playlist = try await provider.createPlaylist(title: title, description: nil, as: account.write)
            } catch {
                guard isCurrent(account) else { return }
                return report(error, doing: doing, write: true, service: id, account: account, retry: retry)
            }
            guard isCurrent(account) else { return }
            libraryPlaylists[id, default: []].insert(playlist, at: 0)
            cache.invalidate(prefix: "library")
            if tracks.isEmpty {
                show(Notice(text: "Created \(title)"))
            } else {
                fillNewPlaylist(NewPlaylistFill(playlist: playlist, tracks: tracks, account: account))
            }
        }
    }

    /// Adds a new playlist's songs, as a playlist edit bound to the account it was made under, in requests of the
    /// service's batch size (Spotify: 100). The record keeps what the service acknowledged, request by request, so Try
    /// Again sends only the songs still pending, to the same playlist. A failure that may have landed anyway (a timeout
    /// after the request went, a 5xx; not offline, 429, 401 or an account refusal, which apply nothing) is resolved
    /// before anything is sent again: the playlist is read uncached and whole (`readListing`; an incomplete read says
    /// "Couldn’t read all of “P”." with Try Again), and only the pending songs it doesn't hold go, as Add Back at End.
    private func fillNewPlaylist(_ fill: NewPlaylistFill) {
        let playlist = fill.playlist
        let retry: @MainActor () -> Void = { [weak self] in self?.fillNewPlaylist(fill) }
        let doing = { "Created “\(playlist.title)”, but couldn’t add \(Self.songsPhrase(fill.pending)) to it" }
        guard isCurrent(fill.account), let provider = provider(playlist.provider),
              let lock = beginPlaylistEdit(playlist, provider: provider, account: fill.account, doing: doing(), retry: retry) else { return }
        editTask(lock) { [self] in
            var changed = false
            do {
                if fill.mayHaveLanded {
                    let listing = try await readListing(playlist, provider: provider, account: lock.account)
                    guard isCurrent(lock, provider) else { return }
                    guard listing.complete else { throw PlaylistReadIncomplete() }
                    fill.settle(present: listing.songIDs)
                }
                let batch = max(1, provider.playlistEditBatchSize ?? fill.pending.count)
                while !fill.pending.isEmpty {
                    let next = Array(fill.pending.prefix(batch))
                    guard isCurrent(lock, provider) else { return }
                    try requireSendable(lock, provider)
                    do {
                        try await provider.add(next, toPlaylist: playlist.providerID, as: lock.account.write)
                    } catch {
                        if Self.writeMayHaveLanded(error) { fill.mayHaveLanded = true }
                        throw error
                    }
                    guard isCurrent(lock, provider) else { return }
                    fill.acknowledge(next.count)
                    changed = true
                }
                endPlaylistEdit(playlist, lock)
                if changed { playlistDidChange(playlist) }
                show(Notice(text: "Created \(playlist.title)"))
            } catch {
                guard isCurrent(lock, provider) else { return }
                endPlaylistEdit(playlist, lock)
                if changed || fill.mayHaveLanded { playlistDidChange(playlist) }
                if error is PlaylistReadIncomplete {
                    show(Notice(text: "Couldn’t read all of “\(playlist.title)”.", symbol: "exclamationmark.triangle.fill", kind: .failure,
                                retry: retry, account: fill.account))
                } else {
                    report(error, doing: doing(), write: true, service: playlist.provider, account: fill.account, retry: retry)
                }
            }
        }
    }

    /// Whether a failed write may still have been applied: anything but an answer that says nothing was (offline before
    /// sending, 429, 401, an account refusal before sending).
    static func writeMayHaveLanded(_ error: any Error) -> Bool {
        switch error {
        case is PlaylistSignInChanging, PlaylistEditError.accountChanged, is CancellationError: return false
        case ProviderError.rateLimited, ProviderError.notSignedIn, ProviderError.notFound, ProviderError.notSupported: return false
        case ProviderError.network(let message): return !offlineMessages.contains(message)
        case let error as URLError: return !offlineCodes.contains(error.code)
        default: return true
        }
    }

    private static let offlineCodes: Set<URLError.Code> = [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .cannotConnectToHost, .cannotFindHost]
    private static let offlineMessages: Set<String> = Set(offlineCodes.map { URLError($0).localizedDescription })

    func copyLink(_ item: MediaItem) {
        guard let url = WebLinks.url(for: item) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        show(Notice(text: "Link copied", symbol: "link"))
    }

    // MARK: Lyrics

    func cachedLyrics(_ track: Track) -> Lyrics?? { lyricsCache[track.id] }

    /// Self-tests only (`LyricsSelfTest`): set or forget the lyrics a sample-data track shows.
    func setCachedLyrics(_ lyrics: Lyrics??, for track: Track) {
        guard isMock else { return }
        lyricsCache[track.id] = lyrics
    }

    func lyrics(for track: Track) async throws -> Lyrics? {
        if let hit = lyricsCache[track.id] { return hit }
        guard let provider = provider(track.provider), provider.capabilities.contains(.lyrics) else { return nil }
        let lyrics = try await provider.lyrics(for: track)
        lyricsCache[track.id] = lyrics
        return lyrics
    }

    // MARK: Notices

    func show(_ notice: Notice) {
        var notice = notice
        if notice.account == nil { notice.account = notice.edit?.account }
        notice.inMiniPlayer = noticeBelongsInMiniPlayer
        self.notice = notice
        // Failures wait for the listener: they may need Try Again, and they shouldn't vanish while being read.
        guard notice.kind == .confirmation else { return }
        let wait = notice.action == nil ? noticeDuration : noticeDuration * 2.5
        noticeExpiry = Task {
            // Long enough to reach its button.
            await noticeSleep(wait)
            if self.notice?.id == notice.id { self.notice = nil }
        }
    }

    /// A notice goes to the mini player when that's where the listener is: it's the key window, or the main window
    /// is closed, minimized or covered. Otherwise to the main window, as always.
    private var noticeBelongsInMiniPlayer: Bool {
        guard isMiniPlayerOpen, let mini = MiniPlayerWindow.window, mini.isVisible else { return false }
        if NSApp.keyWindow === mini { return true }
        guard let main = mainWindow else { return true }
        return !main.isVisible || main.isMiniaturized || !main.occlusionState.contains(.visible)
    }

    /// Closes the notice (its close button, or Try Again before it runs the action).
    func dismissNotice() { notice = nil }

    @ObservationIgnored private let noticeLog = Logger(subsystem: ProductInfo.macBundleIdentifier, category: "notices")

    /// Shows a failure in plain words: `doing` names the action and the item ("Couldn't like “the cure”"), then a
    /// short reason from `FailureReason`. The error's own text (server codes, response bodies) goes to the log
    /// only, marked private. `retry` becomes a Try Again button when a second attempt could work (offline, rate
    /// limited, the service refusing for now); `write` says the action changed something on the service, which picks
    /// the wording of a refusal.
    func report(_ error: any Error, doing: String? = nil, write: Bool = false, service: ProviderID? = nil,
                account: PlaylistEditAccount? = nil, action: NoticeAction? = nil, retry: (@MainActor () -> Void)? = nil) {
        // A cancelled request (the listener moved on) isn't a failure to tell them about.
        if error is CancellationError { return }
        let reason = FailureReason(error, write: write, service: service)
        noticeLog.error("\(doing ?? "Request", privacy: .public) failed: \(String(describing: error), privacy: .private)")
        let text = doing.map { "\($0). \(reason.text)" } ?? reason.text
        show(Notice(text: text, symbol: "exclamationmark.triangle.fill", kind: .failure,
                    retry: reason.isRecoverable ? retry : nil, action: action, account: account))
    }

    /// What a removal takes, every copy counted: "“Espresso”", "both copies of “Espresso”", "all 3 copies of
    /// “Espresso”", "3 songs", "3 songs (5 copies in all)".
    static func removalPhrase(_ tracks: [Track], entries: Int) -> String {
        guard entries > tracks.count else { return songsPhrase(tracks) }
        if tracks.count == 1 {
            return entries == 2 ? "both copies of “\(tracks[0].title)”" : "all \(entries) copies of “\(tracks[0].title)”"
        }
        return "\(tracks.count) songs (\(entries) copies in all)"
    }

    /// Each song once, at its first place: a playlist lists a song it holds twice once (`PlaylistPager`).
    static func eachOnce(_ tracks: [Track]) -> [Track] {
        var seen = Set<String>()
        return tracks.filter { seen.insert($0.id).inserted }
    }

    /// "a song" titles one song ("“the cure”"), more as a count ("3 songs").
    static func songsPhrase(_ tracks: [Track]) -> String {
        tracks.count == 1 ? "“\(tracks[0].title)”" : "\(tracks.count) songs"
    }
}

/// Round-robin merge, so results from both services alternate.
func interleave<T>(_ lists: [[T]]) -> [T] {
    var out: [T] = []
    out.reserveCapacity(lists.reduce(0) { $0 + $1.count })
    let longest = lists.map(\.count).max() ?? 0
    for i in 0..<longest {
        for list in lists where i < list.count { out.append(list[i]) }
    }
    return out
}

// MARK: - Settings

extension AppModel {
    /// Asks the Settings window to show `pane`. Each request is new, so asking for the same pane twice still works.
    struct SettingsRequest: Equatable {
        let pane: SettingsPane
        let id = UUID()
    }

    /// Selects `pane` in Settings; call SwiftUI's `openSettings` right after to bring the window up.
    func requestSettings(_ pane: SettingsPane) {
        settingsRequest = SettingsRequest(pane: pane)
    }

    /// Opens Settings › Accounts, or one service's own sign-in sheet over the main window: where every account
    /// button leads ("Open Accounts…", "Connect Spotify", "Sign In to YouTube Music…"). The first-run flow
    /// (`showOnboarding`) is for the first launch and Settings › General's "Show Again…" only.
    func perform(_ action: AccountAction) {
        switch action {
        case .openAccounts:
            requestSettings(.accounts)
            openSettingsAction?()
        case .signIn(let id):
            signInRequest = id
        }
    }

    /// The pane asked for, once: Settings calls this when it appears or a request arrives, so reopening Settings
    /// later with ⌘, shows the pane the listener left, not an old request.
    func takeSettingsRequest() -> SettingsPane? {
        defer { settingsRequest = nil }
        return settingsRequest?.pane
    }
}

/// Where an account button goes: Settings › Accounts ("Open Accounts…"), or a service's own sign-in sheet
/// ("Connect Spotify", "Sign In to YouTube Music…"). `AppModel.perform(_:)` takes it there.
enum AccountAction: Equatable {
    case openAccounts
    case signIn(ProviderID)

    /// The empty Library page's button: the filtered service's sign-in when the filter shows one that isn't signed
    /// in, Settings › Accounts while another service is signed in, and nil (a menu of both services' sign-ins)
    /// when nothing is.
    static func forEmptyLibrary(_ model: AppModel) -> AccountAction? {
        if let id = model.serviceFilter.provider, model.provider(id)?.isSignedIn == false { return .signIn(id) }
        return model.anySignedIn ? .openAccounts : nil
    }

    /// A service that didn't load or isn't connected: its own sign-in when it's signed out, else nil (Try Again).
    static func forService(_ id: ProviderID, in model: AppModel) -> AccountAction? {
        model.provider(id)?.isSignedIn == false ? .signIn(id) : nil
    }
}
