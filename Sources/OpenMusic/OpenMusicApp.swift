import AppKit
import OpenMusicCore
import SwiftUI

@main
struct OpenMusicApp: App {
    @State private var model: AppModel
    /// Takes `openmusic://` links (Debug self-test links and the Clerk sign-in callback).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Before the model, whose providers read their sign-ins from the Keychain.
        #if DEBUG
        // Sync self-test runs keep every sign-in in files of their own, never in the Mac's Keychain.
        SyncHub.Options.isolateKeychainForSelfTest()
        #endif
        KeychainProbe.runIfRequested()
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        Window(ProductInfo.name, id: "main") {
            MainWindow()
                .environment(model)
                .environment(\.showsServiceMarks, model.showsServiceMarks)
                .environment(\.openMusicSnapshot, model.snapshotDirectory != nil)
                .transaction { t in
                    // Snapshots capture the final state of every change, not a frame mid-animation.
                    if model.snapshotDirectory != nil, !model.snapshotActsLive { t.animation = nil; t.disablesAnimations = true }
                }
                .task {
                    let env = LaunchEnvironment.current
                    #if DEBUG
                    if model.snapshotDirectory != nil { await SnapshotRunner(model: model).run() }
                    if model.isMock, env["OPENMUSIC_SELFTEST"] == "fullscreen", let out = env["OPENMUSIC_SELFTEST_OUT"] {
                        await FullScreenSelfTest(model: model, output: URL(fileURLWithPath: out)).run()
                    }
                    if model.isMock, env["OPENMUSIC_SELFTEST"] == "inspector", let out = env["OPENMUSIC_SELFTEST_OUT"] {
                        await InspectorSelfTest(model: model, output: URL(fileURLWithPath: out)).run()
                    }
                    if model.isMock, env["OPENMUSIC_SELFTEST"] == "inspectorwidth", let out = env["OPENMUSIC_SELFTEST_OUT"] {
                        await InspectorWidthSelfTest(model: model, output: URL(fileURLWithPath: out)).run()
                    }
                    #if DEBUG
                    if model.isMock, env["OPENMUSIC_SELFTEST"] == "resize", let out = env["OPENMUSIC_SELFTEST_OUT"] {
                        await ResizeSelfTest(model: model, output: URL(fileURLWithPath: out)).run()
                    }
                    #endif
                    if model.isMock, env["OPENMUSIC_SELFTEST"] == "find", let out = env["OPENMUSIC_SELFTEST_OUT"] {
                        await FindSelfTest(model: model, output: URL(fileURLWithPath: out)).run()
                    }
                    if env["OPENMUSIC_SELFTEST"] == "menus", let out = env["OPENMUSIC_SELFTEST_OUT"] {
                        await MenuSelfTest(output: URL(fileURLWithPath: out)).run()
                    }
                    if env["OPENMUSIC_SELFTEST"] == "launch", let out = env["OPENMUSIC_SELFTEST_OUT"] {
                        await LaunchSelfTest(model: model, output: URL(fileURLWithPath: out)).run()
                    }
                    if model.isMock, env["OPENMUSIC_SELFTEST"] == "lyrics", let out = env["OPENMUSIC_SELFTEST_OUT"] {
                        await LyricsSelfTest(model: model, output: URL(fileURLWithPath: out)).run()
                    }
                    if model.isMock, env["OPENMUSIC_SELFTEST"] == "tour", let out = env["OPENMUSIC_SELFTEST_OUT"] {
                        await TourSelfTest(model: model, output: URL(fileURLWithPath: out)).run()
                    }
                    if model.isMock, env["OPENMUSIC_SELFTEST"] == "hover", let out = env["OPENMUSIC_SELFTEST_OUT"] {
                        await HoverSelfTest(model: model, output: URL(fileURLWithPath: out, isDirectory: true)).run()
                    }
                    #endif
                    // Kept in Release on purpose: the sidebar frame-timing benchmarks (AGENTS.md, "Mac app: frame
                    // timing"; `scripts/sidebar-bench.sh`) run these self-tests on Release builds. They only run with
                    // mock data (`OPENMUSIC_MOCK=1`).
                    if model.isMock, env["OPENMUSIC_SELFTEST"] == "sidebar", let out = env["OPENMUSIC_SELFTEST_OUT"] {
                        await SidebarSelfTest(model: model, output: URL(fileURLWithPath: out)).run()
                    }
                    if model.isMock, env["OPENMUSIC_SELFTEST"] == "sidebarscroll", let out = env["OPENMUSIC_SELFTEST_OUT"] {
                        await SidebarScrollSelfTest(model: model, output: URL(fileURLWithPath: out)).run()
                    }
                }
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            OpenMusicCommands(model: model)
        }

        Window("Mini Player", id: "mini") {
            MiniPlayerView()
                .environment(model)
                .environment(\.showsServiceMarks, model.showsServiceMarks)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .windowResizability(.contentSize)
        .windowLevel(.floating)
        .defaultPosition(.topTrailing)
        // Window › Mini Player (⌥⌘M) opens it; without this SwiftUI listed a second, plain "Mini Player". This also
        // drops SwiftUI's "OpenMusic" entry, so Window › OpenMusic (⌘0) is a command of its own.
        .commandsRemoved()

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct OpenMusicCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // File › New Playlist, as in Music. With two services that can make playlists, one item per service.
        CommandGroup(replacing: .newItem) {
            let creators = model.providers.filter { $0.isSignedIn && $0.capabilities.contains(.playlistEditing) }
            if creators.count > 1 {
                ForEach(Array(creators.enumerated()), id: \.element.id) { index, provider in
                    Button("New \(provider.id.displayName) Playlist…") {
                        model.newPlaylistRequest = .init(provider: provider.id, tracks: [])
                    }
                    .keyboardShortcut(index == 0 ? KeyboardShortcut("n", modifiers: .command) : KeyboardShortcut("n", modifiers: [.command, .option]))
                }
            } else {
                Button("New Playlist…") {
                    if let provider = creators.first { model.newPlaylistRequest = .init(provider: provider.id, tracks: []) }
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(creators.isEmpty)
            }
        }

        CommandGroup(after: .textEditing) {
            Button("Search") { model.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
        }

        // View › Show/Hide Sidebar (⌃⌘S), in place of `SidebarCommands`, whose item AppKit applies to the sidebar's
        // column directly: this one shows the sidebar the way the toolbar's button does (`AppModel.toggleSidebar`).
        CommandGroup(replacing: .sidebar) {
            Button(model.columnVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar") { model.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.control, .command])
                // As `SidebarCommands`' item: only with the main window open and in front.
                .disabled(!model.canToggleSidebar)
        }

        CommandGroup(after: .sidebar) {
            Button("Back") { model.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.canGoBack)
            Button("Forward") { model.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!model.canGoForward)
            Divider()
            ForEach(Array(SidebarItem.numbered.enumerated()), id: \.offset) { index, item in
                Button(item.title) { model.select(item) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Divider()
            // In the full-screen player these show and hide its own panel, not the window's inspector behind it.
            Button(model.visiblePanel == .lyrics ? "Hide Lyrics" : "Show Lyrics") { model.togglePanel(.lyrics) }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(model.isFullScreenPlayerPresented && !model.currentSongHasLyrics)
            Button(model.visiblePanel == .queue ? "Hide Playing Next" : "Show Playing Next") { model.togglePanel(.queue) }
                .keyboardShortcut("u", modifiers: [.command, .option])
            Divider()
            // The sidebar footer's service filter, here too, with a checkmark on the one in use. Only with both
            // services signed in, as in the sidebar.
            Picker("Show", selection: Binding(get: { model.serviceFilter }, set: { model.serviceFilter = $0 })) {
                ForEach(ServiceFilter.allCases) { Text($0.title).tag($0) }
            }
            .disabled(model.providers.filter(\.isSignedIn).count < 2)
            Divider()
            Button("Refresh") {
                model.cache.removeAll()
                model.refreshTick += 1
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
        }

        CommandMenu("Controls") {
            let player = model.player
            // Space is handled by `KeyMonitor` so it never steals typing from text fields.
            Button(player.isPlaying ? "Pause" : "Play") { model.togglePlayPause() }
                .disabled(player.queue.isEmpty)
            Button("Next") { model.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(player.queue.isEmpty)
            Button("Previous") { model.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(player.queue.isEmpty)
            Divider()
            Button("Go to Current Song") { model.goToCurrentSong() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(player.current == nil)
            Divider()
            SyncCommands(model: model)
            let settings = model.playback.settings
            Button("Increase Volume") { settings.volume = min(1, settings.volume + 0.1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Decrease Volume") { settings.volume = max(0, settings.volume - 0.1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Divider()
            Toggle("Shuffle", isOn: Binding(get: { player.shuffle }, set: { player.shuffle = $0 }))
            Picker("Repeat", selection: Binding(get: { player.repeatMode }, set: { player.repeatMode = $0 })) {
                Text("Off").tag(RepeatMode.off)
                Text("All").tag(RepeatMode.all)
                Text("One").tag(RepeatMode.one)
            }
            Button("Cycle Repeat") { player.repeatMode = player.repeatMode.next }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            Toggle("Autoplay", isOn: Binding(get: { settings.autoplay }, set: { settings.autoplay = $0 }))
            Menu("Sleep Timer") {
                ForEach(OpenMusicCore.PlaybackSettings.sleepTimerPresets, id: \.self) { minutes in
                    Button("\(minutes) Minutes") { player.setSleepTimer(minutes: Double(minutes)) }
                }
                Button("End of Current Song") { player.setSleepTimerEndOfTrack() }
                    .disabled(player.current == nil)
                Divider()
                Button("Turn Off") { player.cancelSleepTimer() }
                    .disabled(player.sleepTimer == .off)
            }
        }

        CommandGroup(before: .windowList) {
            Button(model.isFullScreenPlayerPresented ? "Exit Full Screen Player" : "Full Screen Player") {
                model.setFullScreenPlayerPresented(!model.isFullScreenPlayerPresented)
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Mini Player") { showMiniPlayer(openWindow) }
                .keyboardShortcut("m", modifiers: [.command, .option])
            // The main window, also after ⌘W closed it (SwiftUI's own entry goes with the mini player's, below).
            Button(ProductInfo.name) { showMainWindow(openWindow, model: model) }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
        }
    }
}

/// Controls › Continue from <device> (⇧⌘C) and Controls › Play On, for OpenMusic Sync.
struct SyncCommands: View {
    let model: AppModel

    // Always listed (disabled until sync is up), so the menu doesn't change shape a moment after launch.
    var body: some View {
        let hub = model.sync
        let service = hub?.service
        Button(hub?.continueMenuTitle ?? "Continue from Another Device") {
            if let hub, let device = hub.banner?.device.id { hub.playHere(from: device) }
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .disabled(hub?.banner == nil || hub?.busyDevice != nil)
        Menu("Play On") {
            if let hub, let service {
                ForEach(service.otherDevices) { device in
                    Button(device.name) {
                        Task { if let m = await hub.send(to: device.id) { model.show(.init(text: m, symbol: "exclamationmark.triangle.fill")) } }
                    }
                    .disabled(!service.isOnline(device) || model.player.current == nil)
                }
                if !service.otherDevices.isEmpty { Divider() }
            }
            Button(service?.isRegistered == true ? "Account Settings…" : "Sign In to Sync…") {
                model.requestSettings(.sync)
                model.openSettingsAction?()
            }
            .disabled(hub == nil)
        }
        Divider()
    }
}
