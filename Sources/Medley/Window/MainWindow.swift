import AppKit
import MedleyCore
import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @State private var enteredWindowFullScreen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model
        // Sidebar, page and inspector all run full height, like Music. The player floats over the page only
        // (see `DetailArea`).
        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            Sidebar()
        } detail: {
            DetailArea()
        }
        .toolbar { MainToolbar(sidebarCollapsed: model.columnVisibility == .detailOnly) }
        .modifier(SearchField())
        .toolbar(removing: .title)
        // No toolbar backing in any layout: with the sidebar collapsed the window otherwise drew a titlebar band
        // with a hard bottom edge over the page (`SoftTopEdge`, `TopScrollFade`).
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar(model.isFullScreenPlayerPresented || model.firstRun != nil ? .hidden : .automatic, for: .windowToolbar)
        // Behind the first-run flow nothing takes the keyboard, the pointer or VoiceOver.
        .disabled(model.firstRun != nil)
        .accessibilityHidden(model.firstRun != nil)
        // After the split view, so the full-screen player covers everything.
        .overlay {
            if model.isFullScreenPlayerPresented {
                FullScreenPlayer()
                    .transition(Motion.Transition.fullScreenPlayer.transition(reduce: reduceMotion))
                    .zIndex(1)
            }
        }
        // Above the full-screen player, which is opaque: confirmations and failures (Add to Queue, Like) from its
        // More menu would otherwise land under it. While browsing the notice sits above the floating player instead
        // (`DetailArea`); only one of the two placements draws at a time.
        .overlay(alignment: .top) {
            if model.isFullScreenPlayerPresented {
                NoticeHUD(placement: .fullScreen)
            }
        }
        // The first-run flow covers the whole window; Home loads underneath.
        .overlay {
            if let flow = model.firstRun {
                FirstRunView(flow: flow)
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: model.firstRun == nil)
        .sheet(item: $model.signInRequest) { id in
            model.provider(id)?.makeSignInView { model.signInRequest = nil }
        }
        .sheet(item: $model.newPlaylistRequest) { NewPlaylistSheet(request: $0) }
        // "Remove from Playlist" on a service that can't put the song back where it was (no Undo): ask first.
        .confirmationDialog(
            model.pendingPlaylistRemoval.map { "Remove \($0.phrase) from “\($0.playlist.title)”?" } ?? "",
            isPresented: Binding(get: { model.pendingPlaylistRemoval != nil }, set: { if !$0 { model.pendingPlaylistRemoval = nil } }),
            titleVisibility: .visible,
            presenting: model.pendingPlaylistRemoval
        ) { pending in
            Button("Remove", role: .destructive) {
                model.pendingPlaylistRemoval = nil
                model.remove(pending.tracks, from: pending.playlist, entries: pending.entries)
            }
            Button("Cancel", role: .cancel) { model.pendingPlaylistRemoval = nil }
        } message: { pending in
            Text("\(pending.playlist.provider.displayName) can’t put \(pending.entries == 1 ? "it" : "them") back in the same place, so this can’t be undone.")
        }
        // Another device asking for this Mac's sign-in key: `SyncHub.keyPrompter` puts its alert on this window.
        .background(SettingsOpener())
        // At least the sidebar, page and inspector minimums side by side (190 + 420 + 280, plus dividers). SwiftUI
        // measures the columns as needing more than that (`SplitViewTuning.neededWidth`), so `AppModel` narrows or
        // hides the sidebar and the panel as the window narrows (`MEDLEY_SELFTEST=resize`).
        .frame(minWidth: 900, minHeight: 560)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { model.windowWidth = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.windowHeight = $0 }
        .background(WindowAccessor { window in
            model.mainWindow = window
            // AppKit gives the sidebar search field focus at launch; Music opens with nothing focused.
            DispatchQueue.main.async {
                window?.makeFirstResponder(nil)
                if let window { applyLaunchSize(window) }
                SplitViewTuning.keepWindowWidthWhenShowingSidebar(in: window)
            }
        })
        .task { await model.launch(); if !model.isMock { BrowseDiskCache.watchAccounts(model) } }
        .task {
            #if DEBUG
            let env = ProcessInfo.processInfo.environment
            if model.isMock, env["MEDLEY_SELFTEST"] == "layout", let out = env["MEDLEY_SELFTEST_OUT"] {
                await LayoutSelfTest(model: model, output: URL(fileURLWithPath: out)).run()
            }
            #endif
        }
        .task(id: model.authKey) { await model.refreshLibraryState() }
        .onChange(of: model.isFullScreenPlayerPresented) { _, presented in syncWindowFullScreen(presented) }
        .onAppear { KeyMonitor.shared.install(model) }
    }

    /// Like Apple Music, the full-screen player also takes the window full screen.
    ///
    /// This runs inside SwiftUI's update (`onChange`), so every AppKit window call waits for the next turn of
    /// the main loop. Calling `toggleFullScreen` or `makeFirstResponder` synchronously here makes AppKit lay out
    /// the window while SwiftUI is still rendering it, which on macOS 27 aborts with a reentrant-layout exception.
    private func syncWindowFullScreen(_ presented: Bool) {
        guard let window = model.mainWindow else { return }
        let live = model.snapshotDirectory == nil || model.snapshotActsLive
        DispatchQueue.main.async {
            // The search field would otherwise keep focus and draw its ring over the player.
            if presented { window.makeFirstResponder(nil) }
            guard live else { return }
            let isFull = window.styleMask.contains(.fullScreen)
            if presented, !isFull {
                enteredWindowFullScreen = true
                window.toggleFullScreen(nil)
            } else if !presented, enteredWindowFullScreen {
                enteredWindowFullScreen = false
                if isFull { window.toggleFullScreen(nil) }
            }
        }
    }
}

/// The page stack with the floating player, plus the lyrics/queue inspector. Its own view so it observes
/// `model.inspector`.
///
/// The player is a bottom safe-area inset of the page, attached before `.inspector`, so it sits over the page
/// only. Every page's scroll view still reaches the bottom of the pane and scrolls under the glass, but its
/// content ends above the capsule: the inset becomes the scroll view's bottom content inset, once, for every
/// page (`MEDLEY_SELFTEST=layout` checks each page type).
private struct DetailArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        DetailStack()
            // Inside the inset, so the notice floats just above the capsule. In full screen `MainWindow` draws it
            // over the full-screen player instead.
            .overlay(alignment: .bottom) {
                if !model.isFullScreenPlayerPresented { NoticeHUD(placement: .browsing) }
            }
            .safeAreaInset(edge: .bottom, spacing: FloatingPlayer.gap) {
                VStack(spacing: 0) {
                    // "Continue from iPhone" and other offers about playback (`AppModel.playerBanner`).
                    PlayerBannerSlot()
                    FloatingPlayer()
                }
                .padding(.horizontal, FloatingPlayer.inset)
                .padding(.bottom, FloatingPlayer.inset)
                .accessibilityHidden(model.isFullScreenPlayerPresented)
            }
            .inspector(isPresented: Binding(get: { model.inspector != nil }, set: { if !$0 { model.inspectorPresentationEnded() } })) {
                InspectorContent()
                    // Constant sizes: see `DetailStack`. A width tied to the window, or a minimum taken from the
                    // lyrics or queue content, feeds back into the split view's layout. A wider ideal or maximum
                    // (330/480) made collapsing the sidebar at 960 pt loop on Update Constraints and abort
                    // (`MEDLEY_SELFTEST=inspector` reproduces it). The ideal is 310, except 420 for lyrics opened in
                    // a window of 1300 pt or more, set only in the update that opens the panel (`AppModel.sizeInspector`);
                    // the maximum is 520 so long lyric lines can be read without wrapping (`MEDLEY_SELFTEST=inspectorwidth`
                    // drags the edge to it, toggles the sidebar under the wide ideal and repeats the narrow-window cycle),
                    // less where the panel opens beside the sidebar with less room than that (`AppModel.fitInspector`,
                    // also set only in the opening update; AppKit can bring the column back at its last width).
                    .frame(minWidth: 280, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
                    .modifier(DebugFrame(key: "panel"))
                    // Outermost: under the capture's frame probe (`DebugFrame`, snapshot runs only) SwiftUI didn't read
                    // the column's limits and pinned the panel at its default 270 pt, so council shots showed lyrics at
                    // 270–280 pt while the app opened them at 420.
                    .inspectorColumnWidth(min: InspectorMetrics.minWidth, ideal: model.inspectorIdealWidth, max: model.inspectorMaxWidth)
            }
    }
}

/// The sidebar page with any pushed pages on top. Only the top page is alive;
/// going back re-renders the page below from `PageCache`, so it appears instantly.
private struct DetailStack: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let route = model.path.last {
                RoutePage(route: route)
                    .id(model.path.count)
            } else {
                RootPage(item: model.sidebarSelection ?? .home)
                    .id(model.sidebarSelection)
            }
        }
        // A fixed minimum, so the split view never reads a content-dependent minimum size. On macOS 26
        // and later it re-solves constraints whenever a column's minimum changes, and pages whose layout
        // depends on their own width (album header, track columns) can otherwise loop until AppKit aborts.
        .frame(minWidth: SplitViewTuning.pageMinWidth, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
        .modifier(SoftTopEdge())
    }
}

/// Pages run under the toolbar, like Music: album tints and artist photos reach the window's top edge, and
/// scrolled text fades and blurs out beneath the back/forward buttons instead of showing through them.
///
/// This was a hard edge (an opaque band) from when the toolbar carried the playback controls, so scrolled rows
/// wouldn't show through them; that band also cut every hero off ~36 pt below the top. The toolbar now holds only
/// back/forward (and Search's scopes), on their own glass, and the soft edge keeps scrolled text from reading
/// behind them.
private struct SoftTopEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
    }
}

private struct RootPage: View {
    let item: SidebarItem
    @Environment(AppModel.self) private var model

    var body: some View {
        switch item {
        case .home: BrowsePage(kind: .home).navigationTitle("Home")
        case .explore: BrowsePage(kind: .explore).navigationTitle("New")
        case .search: SearchPage()
        case .recentlyAdded, .artists, .albums, .songs, .likedSongs, .recentlyPlayed, .allPlaylists:
            LibraryPage(item: item)
        case .playlist(let provider, let id):
            PlaylistPage(provider: provider, id: id, preview: model.libraryPlaylists[provider]?.first { $0.providerID == id })
        case .collection(let id):
            if let route = model.collections.entry(id: id)?.route {
                RoutePage(route: route)
            } else {
                BrowsePage(kind: .home).navigationTitle("Home")
            }
        }
    }
}

struct RoutePage: View {
    let route: Route

    var body: some View {
        switch route {
        case .album(let p, let id, let preview): AlbumPage(provider: p, id: id, preview: preview)
        case .artist(let p, let id, let preview): ArtistPage(provider: p, id: id, preview: preview)
        case .playlist(let p, let id, let preview): PlaylistPage(provider: p, id: id, preview: preview)
        case .shelf(let p, let shelf): SeeAllPage(provider: p, shelf: shelf)
        }
    }
}

private struct InspectorContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.inspector {
        case .lyrics:
            VStack(spacing: 0) {
                PanelHeader(title: "Lyrics") { model.inspector = nil }
                LyricsView(style: .panel)
            }
        case .queue, nil:
            QueuePanel()
        }
    }
}

/// Back and forward (the split view adds the sidebar toggle), and Search while the sidebar, which holds the search
/// field, is collapsed. All playback lives in the floating player.
struct MainToolbar: ToolbarContent {
    let sidebarCollapsed: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            BackForwardButtons()
        }
        if sidebarCollapsed {
            ToolbarItem(placement: .navigation) {
                SearchToolbarButton()
            }
        }
    }
}

/// Brings the sidebar back with its search field focused (`AppModel.revealSearch`), like ⌘F.
private struct SearchToolbarButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.revealSearch() } label: {
            Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).frame(width: 26, height: 26)
        }
        .buttonStyle(IconButtonStyle())
        .help("Search (⌘F)")
        .accessibilityLabel("Search")
        .modifier(LayoutProbe(key: "toolbar-search"))
    }
}

private struct BackForwardButtons: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            Button { model.goBack() } label: {
                Image(systemName: "chevron.left").font(.system(size: 14, weight: .medium)).frame(width: 26, height: 26)
            }
            .disabled(!model.canGoBack)
            .help("Back")
            .accessibilityLabel("Back")
            Button { model.goForward() } label: {
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .medium)).frame(width: 26, height: 26)
            }
            .disabled(!model.canGoForward)
            .help("Forward")
            .accessibilityLabel("Forward")
        }
        .buttonStyle(IconButtonStyle())
    }
}

/// A confirmation ("Added to queue") or a failure ("Couldn't like “the cure”. You're offline."). One view, drawn in
/// one of two places: while browsing just above the floating player; in full screen at the top center, level with
/// the close button, clear of the transport (centered under the artwork), the panel controls (bottom right) and the
/// lyrics' bright active line. A confirmation goes by itself and lets clicks through. A failure stays until closed,
/// with a close button and, for a write that could work on a second attempt, Try Again; only the capsule takes
/// clicks, the space around it stays the page's.
struct NoticeHUD: View {
    enum Placement { case browsing, fullScreen }
    let placement: Placement
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // A notice for something done in the mini player shows there instead (`MiniNotice`).
            if let notice = model.notice, !(notice.inMiniPlayer && model.isMiniPlayerOpen) {
                NoticeCapsule(notice: notice)
                    .frame(maxWidth: 520)
                    .transition((placement == .fullScreen ? Motion.Transition.fullScreenNotice : .browsingNotice).transition(reduce: reduceMotion))
                    .id(notice.id)
                    // A confirmation with a button (Undo) takes clicks too; a plain one lets them through.
                    .allowsHitTesting(notice.kind == .failure || notice.action != nil)
                    .modifier(LayoutProbe(key: "notice"))
            }
        }
        .padding(placement == .fullScreen ? .top : .bottom, placement == .fullScreen ? 20 : 10)
        // Full screen: 20 pt from the screen's top like the close button, not below the hidden titlebar's inset,
        // which pushed a two-line notice down against the Playing Next heading.
        .ignoresSafeArea(edges: placement == .fullScreen ? .top : [])
        // The full-screen player is always dark; its notice matches it in either appearance.
        .environment(\.colorScheme, placement == .fullScreen ? .dark : colorScheme)
        .animation(.easeOut(duration: 0.2), value: model.notice)
        .onChange(of: model.notice) { _, notice in
            // VoiceOver hears the confirmation or failure without moving focus.
            guard let notice else { return }
            let hint = (notice.action.map { " \($0.title) is available." } ?? "")
                + (notice.kind == .failure && notice.retry != nil ? " Try Again is available." : "")
                + (notice.secondaryAction.map { " \($0.title) is available." } ?? "")
            AccessibilityNotification.Announcement(notice.text + hint).post()
        }
    }

    @Environment(\.colorScheme) private var colorScheme
}

private struct NoticeCapsule: View {
    let notice: AppModel.Notice
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.symbol)
                .foregroundStyle(notice.kind == .failure ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            Text(notice.text)
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            // A failure can carry one too: a removal that stopped partway offers Undo for what went, beside Try Again.
            if let action = notice.action {
                Button(action.title) {
                    model.dismissNotice()
                    action.run()
                }
                .buttonStyle(NoticeButtonStyle())
                .modifier(LayoutProbe(key: "notice-action"))
            }
            if notice.kind == .failure, let retry = notice.retry {
                Button("Try Again") {
                    model.dismissNotice()
                    retry()
                }
                .buttonStyle(NoticeButtonStyle())
                .modifier(LayoutProbe(key: "notice-retry"))
            }
            // "Leave As Is" on a partly applied playlist edit: last, after Try Again.
            if let secondary = notice.secondaryAction {
                Button(secondary.title) {
                    model.dismissNotice()
                    secondary.run()
                }
                .buttonStyle(NoticeButtonStyle())
                .modifier(LayoutProbe(key: "notice-secondary"))
            }
            if notice.kind == .failure {
                Button {
                    model.dismissNotice()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(NoticeCloseStyle())
                .help("Close")
                .accessibilityLabel("Close")
                .modifier(LayoutProbe(key: "notice-close"))
            }
        }
        .font(.callout.weight(.medium))
        .padding(.leading, 16)
        .padding(.trailing, notice.kind == .failure || notice.action != nil ? 8 : 16)
        .padding(.vertical, notice.kind == .failure || notice.action != nil ? 7 : 10)
        .frame(minHeight: notice.kind == .failure || notice.action != nil ? 40 : nil)
        .modifier(NoticeGlass())
        .accessibilityElement(children: .contain)
    }
}

/// Try Again in a failure notice: a small filled capsule, quieter than a pill button, so the text leads.
struct NoticeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        NoticeButtonBody(configuration: configuration)
    }

    private struct NoticeButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.colorScheme) private var scheme
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.2 : hovering ? 0.16 : scheme == .dark ? 0.12 : 0.08)))
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// The failure notice's close button: an xmark on a faint disc that darkens on hover.
struct NoticeCloseStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CloseBody(configuration: configuration)
    }

    private struct CloseBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.readableSecondary))
                .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.1 : 0)))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// The notice in the same glass as the player, so the two read as one family.
private struct NoticeGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        }
    }
}

/// Name a new playlist, then add the pending songs to it.
private struct NewPlaylistSheet: View {
    let request: AppModel.NewPlaylistRequest
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ServiceGlyph(provider: request.provider, size: 16, always: true)
                    .foregroundStyle(.secondary)
                Text("New \(request.provider.displayName) Playlist").font(.headline)
            }
            TextField("Playlist name", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            if !request.tracks.isEmpty {
                Text(request.tracks.count == 1 ? "“\(request.tracks[0].title)” will be added." : "\(request.tracks.count) songs will be added.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func create() {
        let name = title.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.createPlaylist(name, provider: request.provider, adding: request.tracks)
        dismiss()
    }
}

/// `MEDLEY_WINDOW_SIZE=960x620` opens the main window at that size (top left of the screen), for
/// screenshot and layout checks at a known width.
@MainActor
private func applyLaunchSize(_ window: NSWindow) {
    guard let spec = ProcessInfo.processInfo.environment["MEDLEY_WINDOW_SIZE"] else { return }
    let parts = spec.split(separator: "x").compactMap { Double($0) }
    guard parts.count == 2, let screen = window.screen ?? NSScreen.main else { return }
    let visible = screen.visibleFrame
    window.requestFrame(NSRect(x: visible.minX, y: visible.maxY - parts[1], width: parts[0], height: parts[1]), display: true)
}

/// Reports the hosting `NSWindow`.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class WindowReportingView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}

/// Space plays and pauses, as in Music, except where something focused takes Space itself. Text fields and text
/// views type it. With nothing focused (the window itself is first responder: the page, the background) or an AppKit
/// song list focused (Songs' table, the sidebar's list), it plays and pauses here. Otherwise SwiftUI has focus
/// somewhere and the key goes to it: a focused control (a button, toggle, menu button, card, a row's More) acts on it,
/// the way controls do with Keyboard Navigation on, and the track lists and Playing Next play and pause with
/// `onKeyPress`. A Space that SwiftUI passes up unhandled reaches `SpaceFallback`, after the window in the responder
/// chain, which plays and pauses too. Main window and mini player alike.
@MainActor
final class KeyMonitor {
    static let shared = KeyMonitor()
    private var monitor: Any?
    private weak var model: AppModel?

    func install(_ model: AppModel) {
        self.model = model
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let model = self.model, SpaceFallback.isPlainSpace(event), let window = NSApp.keyWindow,
                  window.attachedSheet == nil, window === model.mainWindow || window === MiniPlayerWindow.window
            else { return event }
            let responder = window.firstResponder
            if responder is NSText || responder is NSTextField { return event }
            // The window passes a key nobody took to `noResponder(for:)`, not along the chain: toggle here.
            if responder == nil || responder === window || responder is NSTableView {
                SpaceFallback.toggle(model, from: responder is NSTableView ? "table" : "nothing focused")
                return nil
            }
            SpaceFallback.install(in: window, model: model)
            return event
        }
    }
}

/// The responder after a main or mini player window: a Space that nothing focused handled ends here and plays or
/// pauses. Anything else goes on along the chain as before.
@MainActor
final class SpaceFallback: NSResponder {
    private weak var model: AppModel?

    static func isPlainSpace(_ event: NSEvent) -> Bool {
        event.keyCode == 49 && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }

    /// Puts a fallback right after `window` in its responder chain, once; SwiftUI may replace the window's next
    /// responder, so this runs before each Space.
    static func install(in window: NSWindow, model: AppModel) {
        if let existing = window.nextResponder as? SpaceFallback {
            existing.model = model
            return
        }
        let fallback = SpaceFallback()
        fallback.model = model
        fallback.nextResponder = window.nextResponder
        window.nextResponder = fallback
    }

    static func toggle(_ model: AppModel, from source: String) {
        model.togglePlayPause()
        if LayoutProbe.enabled { DebugProbes.note("space", "\(source): toggled play/pause") }
    }

    override func keyDown(with event: NSEvent) {
        if Self.isPlainSpace(event), let model {
            Self.toggle(model, from: "background")
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Hands SwiftUI's `openSettings` to the model, so menu commands and sync links can bring Settings up.
private struct SettingsOpener: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { model.openSettingsAction = { openSettings() } }
            .accessibilityHidden(true)
    }
}
