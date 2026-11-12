import MediaPlayer
import AppKit
import MedleyCore
import MedleySync
import SwiftUI

// The runner is Debug-only: Release builds ignore `MEDLEY_SNAPSHOT_DIR` (`AppModel.init`) and carry no
// `SnapshotRunner` (`scripts/check-release-hooks.sh` checks the binary).
#if DEBUG
/// `MEDLEY_MOCK=1 MEDLEY_SNAPSHOT_DIR=<dir>`: walk through the main screens, write a PNG of the window
/// for each at two sizes in light and dark, check a few interactions, then quit.
///
/// Captures use `cacheDisplay`, which needs no screen-recording permission.
@MainActor
struct SnapshotRunner {
    let model: AppModel

    private struct Step {
        let name: String
        let apply: @MainActor (AppModel) async -> Void
    }

    func run() async {
        guard let dir = model.snapshotDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var log: [String] = []

        while model.mainWindow == nil { try? await Task.sleep(for: .milliseconds(100)) }
        if !model.isMock, let window = model.mainWindow {
            await runSignedOut(window: window, dir: dir)
            return
        }
        guard let window = model.mainWindow,
              let yt = model.provider(.youtubeMusic) as? MockProvider,
              let sp = model.provider(.spotify) as? MockProvider
        else { return }
        await settle(0.8)
        log.append("window visible (not occluded): \(window.occlusionState.contains(.visible))")

        #if DEBUG
        // MEDLEY_SNAPSHOT_ONLY=demo (with MEDLEY_MOCK=demo): the screenshots for posting; see DemoShots.
        if ProcessInfo.processInfo.environment["MEDLEY_SNAPSHOT_ONLY"] == "demo" {
            await DemoShots(model: model, window: window, dir: dir, yt: yt, sp: sp).run()
            Self.quit()
            return
        }
        // MEDLEY_SNAPSHOT_ONLY=council (with MEDLEY_MOCK=demo): the screens the judging panel grades; see CouncilShots.
        if ProcessInfo.processInfo.environment["MEDLEY_SNAPSHOT_ONLY"] == "council" {
            await CouncilShots(model: model, window: window, dir: dir, yt: yt, sp: sp).run()
            Self.quit()
            return
        }
        #endif

        // MEDLEY_SNAPSHOT_ONLY=geometry: measure card, featured-card and track-row geometry on Home, New and a
        // long playlist at a short and a tall window, write the numbers, and quit (no PNGs).
        if ProcessInfo.processInfo.environment["MEDLEY_SNAPSHOT_ONLY"] == "geometry" {
            let lines = await GeometryCheck(model: model, window: window, yt: yt).run()
            try? lines.joined(separator: "\n").appending("\n").write(to: dir.appendingPathComponent("geometry.txt"), atomically: true, encoding: .utf8)
            Self.quit()
            return
        }

        let ytAlbum = yt.catalog.albums[0]
        let spAlbum = sp.catalog.albums[2]
        let spArtist = sp.catalog.artists[1]
        let ytPlaylist = yt.catalog.playlists[1]

        // Interaction checks, done through real events where possible.
        log += await checkInteractions(window: window, album: ytAlbum)

        // Queue up a mix from both services so the queue panel has content.
        model.player.addToQueue(Array(sp.catalog.allTracks.prefix(3)))
        model.player.seek(to: 52)

        let allSteps: [Step] = [
            Step(name: "home") { m in m.playerBanner = nil; m.select(.home) },
            Step(name: "search") { m in m.select(.search); m.searchText = "night" },
            Step(name: "album") { m in m.searchText = ""; await navigate(m, .home, .album(.spotify, id: spAlbum.providerID, preview: spAlbum)) },
            Step(name: "album-about") { m in
                await navigate(m, .home, .album(.youtubeMusic, id: ytAlbum.providerID, preview: ytAlbum))
            },
            Step(name: "artist") { m in m.debugFrames["bio-more"] = nil; await navigate(m, .home, .artist(.spotify, id: spArtist.providerID, preview: spArtist)) },
            Step(name: "playlist") { m in await navigate(m, .home, .playlist(.youtubeMusic, id: ytPlaylist.providerID, preview: ytPlaylist)) },
            Step(name: "songs") { $0.select(.songs) },
            Step(name: "lyrics") { m in await navigate(m, .home, .album(.youtubeMusic, id: ytAlbum.providerID, preview: ytAlbum)); m.inspector = .lyrics },
            Step(name: "queue") { $0.inspector = .queue },
            Step(name: "fullscreen") { m in m.inspector = nil; m.isFullScreenPlayerPresented = true },
            Step(name: "albums") { m in m.isFullScreenPlayerPresented = false; m.select(.albums) },
            Step(name: "explore") { $0.select(.explore) },
            Step(name: "artist-yt") { m in await navigate(m, .home, .artist(.youtubeMusic, id: yt.catalog.artists[0].providerID, preview: yt.catalog.artists[0])) },
            // The slot sync's "Continue from iPhone" will use, filled with sample text.
            Step(name: "banner") { m in
                m.select(.home)
                m.playerBanner = PlayerBanner(id: "sample", symbol: "iphone", title: "Continue from iPhone",
                                              subtitle: "Northern Lights · Mara Vale · 1:52", actionTitle: "Play Here", action: {})
            },
        ]

        // MEDLEY_SNAPSHOT_ONLY=lyrics,queue limits the steps (and uses one size and appearance) for quick iteration.
        let only = ProcessInfo.processInfo.environment["MEDLEY_SNAPSHOT_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let steps = only.map { names in allSteps.filter { names.contains($0.name) } } ?? allSteps
        let sizes: [(Int, Int)] = only == nil ? [(1440, 900), (960, 620), (1920, 1000)] : [(1440, 900)]
        for appearance in only == nil ? [NSAppearance.Name.aqua, .darkAqua] : [.darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            let mode = appearance == .aqua ? "light" : "dark"
            for (w, h) in sizes {
                window.requestFrame(NSRect(x: 40, y: 40, width: w, height: h), display: true)
                for (i, step) in steps.enumerated() {
                    await step.apply(model)
                    await settle(step.name == "search" ? 1.0 : 0.7)
                    if step.name == "lyrics", appearance == .aqua {
                        let actual = Int(window.frame.width)
                        log.append("window width with the inspector open on an album at \(w): \(actual): \(abs(actual - w) <= 1 ? "PASS" : "FAIL")")
                    }
                    if step.name == "artist", w == 1440, appearance == .aqua {
                        // The page is lazy, so the bio at its end is laid out only once it scrolls into view.
                        scrollPageToEnd(in: window)
                        await settle(0.6)
                        log.append("artist bio shows More when clipped: \(model.debugFrames["bio-more"] != nil ? "PASS" : "FAIL")")
                        await step.apply(model)
                        await settle(0.7)
                    }
                    capture(window.contentView?.superview ?? window.contentView, to: dir.appendingPathComponent(String(format: "%02d-%@-%@-%dx%d.png", i + 1, step.name, mode, w, h)))
                }
                model.isFullScreenPlayerPresented = false
                await settle(0.4)
                await captureSettings(appearance: appearance, to: dir.appendingPathComponent("20-settings-accounts-\(mode)-\(w)x\(h).png"))
                if w == 1440 { await captureSettings(appearance: appearance, provider: .spotify, to: dir.appendingPathComponent("20-settings-accounts-spotify-\(mode).png")) }
                window.makeKeyAndOrderFront(nil)
            }
        }

        // Lyrics highlight should move as playback advances.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        window.requestFrame(NSRect(x: 40, y: 40, width: 1440, height: 900), display: true)
        model.inspector = .lyrics
        await settle(0.5)
        log.append("side panel frame at 1440: \(model.debugFrames["panel"].map { "\($0)" } ?? "not laid out")")
        model.player.resume()
        model.player.seek(to: 20)
        await settle(1.0)
        let lyricsT0 = model.player.currentTime
        capture(window.contentView?.superview, to: dir.appendingPathComponent("21-lyrics-advance-a.png"))
        await settle(8)
        capture(window.contentView?.superview, to: dir.appendingPathComponent("21-lyrics-advance-b.png"))
        log.append("lyrics: captured 21-lyrics-advance-a at t=\(String(format: "%.1f", lyricsT0))s and -b at t=\(String(format: "%.1f", model.player.currentTime))s")

        // Mini player and onboarding.
        await captureHosted(MiniPlayerView(), size: NSSize(width: 320, height: 320), appearance: .darkAqua, to: dir.appendingPathComponent("22-mini-player.png"))
        model.showOnboarding = true
        model.firstRun?.go(to: .music)
        await settle(1.0)
        capture(window.contentView?.superview, to: dir.appendingPathComponent("23-onboarding-mock.png"))
        model.showOnboarding = false
        await settle(0.6)
        log += await captureAccount(window: window, dir: dir)

        try? log.joined(separator: "\n").appending("\n").write(to: dir.appendingPathComponent("interactions.txt"), atomically: true, encoding: .utf8)
        Self.quit()
    }

    /// Real providers (stubs until the provider workers land): empty states, onboarding and accounts.
    private func runSignedOut(window: NSWindow, dir: URL) async {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            let mode = appearance == .aqua ? "light" : "dark"
            window.requestFrame(NSRect(x: 40, y: 40, width: 1440, height: 900), display: true)
            for item in [SidebarItem.home, .songs] {
                model.select(item)
                await settle(0.8)
                capture(window.contentView?.superview, to: dir.appendingPathComponent("30-real-\(item.title.lowercased())-\(mode).png"))
            }
            model.inspector = .lyrics
            await settle(0.6)
            capture(window.contentView?.superview, to: dir.appendingPathComponent("30-real-lyrics-empty-\(mode).png"))
            model.inspector = nil
            if mode == "light" { await runLive(window: window, dir: dir) }
            model.showOnboarding = true
            model.firstRun?.go(to: .music)
            await settle(1.0)
            capture(window.contentView?.superview, to: dir.appendingPathComponent("31-onboarding-\(mode).png"))
            model.showOnboarding = false
            await settle(0.6)
            await captureSettings(appearance: appearance, to: dir.appendingPathComponent("32-settings-accounts-real-\(mode).png"))
            await captureSettings(appearance: appearance, provider: .spotify, to: dir.appendingPathComponent("32-settings-accounts-real-spotify-\(mode).png"))
            window.makeKeyAndOrderFront(nil)
        }
        Self.quit()
    }

    /// Real providers, signed out: browse, search, open an album and actually play it through the app.
    /// Writes `live.txt` with PASS/FAIL lines. Used to verify YouTube Music end to end.
    private func runLive(window: NSWindow, dir: URL) async {
        var log: [String] = []
        // Start Now Playing, media keys and persistence like a normal launch, so the live pass covers them.
        model.playback.nowPlaying.onLike = { [weak model] track in model?.toggleLike(track) }
        await model.playback.start()
        func shot(_ name: String) { capture(window.contentView?.superview, to: dir.appendingPathComponent("40-live-\(name).png")) }
        model.serviceFilter = .youtubeMusic
        model.select(.home)
        await settle(4)
        shot("home")
        let yt = model.provider(.youtubeMusic)
        let shelves = (try? await yt?.home()) ?? []
        log.append("home: \(shelves.count) shelves: \(shelves.isEmpty ? "FAIL" : "PASS")")
        model.select(.explore)
        await settle(3)
        shot("explore")
        model.select(.search)
        model.searchText = "daft punk discovery"
        await settle(4)
        shot("search")
        let results = try? await yt?.search("daft punk discovery", scope: .all)
        log.append("search: \(results?.tracks.count ?? 0) songs, \(results?.albums.count ?? 0) albums: \(results?.albums.isEmpty == false ? "PASS" : "FAIL")")
        guard let album = results?.albums.first else {
            log.append("no album to open: FAIL")
            try? log.joined(separator: "\n").write(to: dir.appendingPathComponent("live.txt"), atomically: true, encoding: .utf8)
            return
        }
        model.searchText = ""
        await navigate(model, .home, .album(.youtubeMusic, id: album.providerID, preview: album))
        await settle(3)
        shot("album")
        let notes = (try? await yt?.album(id: album.providerID))?.summary ?? ""
        log.append("album notes (\(notes.count) chars) moved below the track list: About More button \(model.debugFrames["about-more"] != nil ? "present" : "absent"): \(notes.count > 300 && model.debugFrames["about-more"] == nil ? "FAIL" : "PASS")")
        // Narrow window: the album, Home and New at 960 x 620.
        window.requestFrame(NSRect(x: 40, y: 40, width: 960, height: 620), display: true)
        await settle(1.5)
        shot("album-960")
        model.select(.home)
        await settle(2)
        shot("home-960")
        model.select(.explore)
        await settle(2)
        shot("explore-960")
        window.requestFrame(NSRect(x: 40, y: 40, width: 1440, height: 900), display: true)
        await navigate(model, .home, .album(.youtubeMusic, id: album.providerID, preview: album))
        await settle(1.5)
        let detail = try? await yt?.album(id: album.providerID)
        let tracks = detail?.tracks ?? []
        log.append("album \"\(album.title)\": \(tracks.count) tracks: \(tracks.isEmpty ? "FAIL" : "PASS")")
        guard !tracks.isEmpty else { return }
        model.player.play(tracks, startAt: 0)
        var samples: [String] = []
        for _ in 0..<12 {
            await settle(1)
            samples.append(String(format: "%@ %.1f", model.player.state.rawValue, model.player.currentTime))
        }
        let advancing = model.player.state == .playing && model.player.currentTime > 5
        log.append("play \"\(model.player.current?.title ?? "-")\": \(samples.joined(separator: ", ")): \(advancing ? "PASS" : "FAIL")")
        if let error = model.player.lastError { log.append("player error: \(error)") }
        shot("playing")
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        log.append("now playing: \(info?[MPMediaItemPropertyTitle] as? String ?? "-"), artwork \(info?[MPMediaItemPropertyArtwork] != nil): \(info?[MPMediaItemPropertyArtwork] != nil ? "PASS" : "FAIL")")
        model.inspector = .lyrics
        await settle(4)
        shot("lyrics")
        var lyrics: Lyrics?
        if let current = model.player.current { lyrics = (try? await yt?.lyrics(for: current)) ?? nil }
        log.append("lyrics: \(lyrics?.lines.count ?? 0) lines, synced \(lyrics?.isSynced == true): \(lyrics?.lines.isEmpty == false ? "PASS" : "FAIL")")
        model.player.seek(to: 120)
        await settle(4)
        log.append(String(format: "seek to 120 → %.1f, %@: %@", model.player.currentTime, model.player.state.rawValue, model.player.currentTime > 120 && model.player.state == .playing ? "PASS" : "FAIL"))
        shot("lyrics-mid")
        model.inspector = nil
        model.player.next()
        await settle(5)
        log.append(String(format: "next → \"%@\" %@ %.1f: %@", model.player.current?.title ?? "-", model.player.state.rawValue, model.player.currentTime, model.player.state == .playing ? "PASS" : "FAIL"))
        model.inspector = .queue
        await settle(1.5)
        shot("queue")
        log.append("queue: \(model.player.queue.count) entries")
        model.inspector = nil
        model.isFullScreenPlayerPresented = true
        await settle(2)
        shot("fullscreen")
        model.isFullScreenPlayerPresented = false
        log.append(await checkLivePlaylistPlay(shelves: shelves))
        model.player.pause()
        await settle(1)
        log.append("pause → \(model.player.state.rawValue): \(model.player.state == .paused ? "PASS" : "FAIL")")
        model.serviceFilter = .all
        try? log.joined(separator: "\n").write(to: dir.appendingPathComponent("live.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: Interactions

    private func checkInteractions(window: NSWindow, album: Album) async -> [String] {
        var log: [String] = []
        window.requestFrame(NSRect(x: 40, y: 40, width: 1440, height: 900), display: true)
        model.select(.home)
        await navigate(model, .home, .album(.youtubeMusic, id: album.providerID, preview: album))
        await settle(1.0)

        // Double-click the third song row with synthesized mouse events.
        let tracks = (try? await model.provider(.youtubeMusic)?.album(id: album.providerID).tracks) ?? []
        if let frame = model.debugFrames["track-row-2"], tracks.count > 2 {
            // SwiftUI's global space is top-left; window coordinates are bottom-left.
            let flipped = NSPoint(x: frame.midX, y: (window.contentView?.bounds.height ?? 0) - frame.midY)
            doubleClick(window: window, at: flipped)
            await settle(0.8)
            let ok = model.player.current?.id == tracks[2].id
            log.append("double-click row 3 → plays \"\(model.player.current?.title ?? "nothing")\" (expected \"\(tracks[2].title)\"): \(ok ? "PASS" : "FAIL")")
        } else {
            log.append("double-click: row frame not found: NOT CHECKED")
        }
        if model.player.current == nil {
            model.play(tracks, startAt: 2, from: .init(title: album.title, route: .album(.youtubeMusic, id: album.providerID, preview: album)))
            await settle(0.5)
        }
        let t0 = model.player.currentTime
        await settle(2.0)
        let t1 = model.player.currentTime
        log.append("time advances while playing: \(String(format: "%.1f", t0))s → \(String(format: "%.1f", t1))s: \(t1 > t0 ? "PASS" : "FAIL")")
        log.append("state: \(model.player.state.rawValue), toolbar shows \"\(model.player.current?.title ?? "-")\"")

        capture(window.contentView?.superview, to: model.snapshotDirectory!.appendingPathComponent("00-after-double-click.png"))

        model.player.togglePlayPause()
        await settle(0.3)
        let pausedAt = model.player.currentTime
        await settle(1.2)
        log.append("pause stops time: \(model.player.state.rawValue), \(String(format: "%.1f", pausedAt))s → \(String(format: "%.1f", model.player.currentTime))s: \(model.player.currentTime == pausedAt ? "PASS" : "FAIL")")
        model.player.togglePlayPause()

        model.player.next()
        await settle(0.4)
        log.append("next → \"\(model.player.current?.title ?? "-")\": \(model.player.current?.id == tracks[safe: 3]?.id ? "PASS" : "FAIL")")
        model.player.previous()
        await settle(0.4)
        log.append("previous → \"\(model.player.current?.title ?? "-")\": \(model.player.current?.id == tracks[2].id ? "PASS" : "FAIL")")

        // Playlist Play, clicked on the page without scrolling, queues every page (mock pages hold 25).
        if let yt = model.provider(.youtubeMusic) as? MockProvider,
           let long = yt.catalog.playlists.max(by: { ($0.trackCount ?? 0) < ($1.trackCount ?? 0) }),
           let total = long.trackCount, total > 25 {
            model.debugFrames["play-button"] = nil
            await navigate(model, .home, .playlist(.youtubeMusic, id: long.providerID, preview: long))
            await settle(1.0)
            if let frame = DebugProbes.windowFrame("play-button") ?? model.debugFrames["play-button"] {
                click(window: window, frame: frame)
                await settle(0.4)
                let atStart = model.player.current?.title ?? "-"
                await settle(1.0)
                let count = model.player.queue.count
                log.append("playlist page Play \"\(long.title)\" (\(total) songs) → starts \"\(atStart)\", queue \(count): \(count == total ? "PASS" : "FAIL")")
            } else {
                log.append("playlist page Play: button frame not found: NOT CHECKED")
            }
            model.play(.playlist(long))
            await settle(1.5)
            log.append("playlist menu Play → queue \(model.player.queue.count) of \(total): \(model.player.queue.count == total ? "PASS" : "FAIL")")
            model.play(.playlist(long), shuffled: true)
            await settle(1.5)
            log.append("playlist menu Shuffle → queue \(model.player.queue.count) of \(total): \(model.player.queue.count == total ? "PASS" : "FAIL")")
            // Put playback back where the screenshots expect it: the album, third song.
            model.play(tracks, startAt: 2, shuffled: false, from: .init(title: album.title, route: .album(.youtubeMusic, id: album.providerID, preview: album)))
            await settle(0.4)
        }

        log += await checkPageInteractions(window: window, album: album, tracks: tracks)

        // Real window full screen with the lyrics panel open: on macOS 27 this once looped Auto Layout until
        // AppKit aborted. Snapshot mode skips the window part of the full-screen player, so do it here.
        // The partial log names the step if the app dies.
        if let dir = model.snapshotDirectory {
            try? (log + ["full screen with lyrics: started"]).joined(separator: "\n")
                .write(to: dir.appendingPathComponent("interactions-partial.txt"), atomically: true, encoding: .utf8)
        }
        // Same calls as ⇧⌘F and Escape, animated, three times.
        model.inspector = .lyrics
        await settle(0.8)
        model.snapshotActsLive = true
        var cycles: [String] = []
        for _ in 0..<3 {
            // ⇧⌘F through the main menu, then Escape to the window, as typed.
            performMenuItem("Full Screen Player")
            await settle(2.5)
            let entered = window.styleMask.contains(.fullScreen)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let esc = keyEvent(window: window, "\u{1b}", keyCode: 53, flags: [], type: type) { window.sendEvent(esc) }
            }
            await settle(2.5)
            cycles.append("\(entered ? "in" : "no-in")/\(window.styleMask.contains(.fullScreen) ? "no-out" : "out")")
        }
        model.snapshotActsLive = false
        model.inspector = nil
        await settle(0.4)
        let ok = cycles.allSatisfy { $0 == "in/out" }
        log.append("window full screen with lyrics open, 3 cycles → \(cycles.joined(separator: " ")), no crash: \(ok ? "PASS" : "FAIL")")
        return log
    }

    /// Builder B's checks: hero Play → Pause → resume keeps the queue, Return plays the selected row,
    /// the artist name doesn't move while the page loads, and hour-long durations fit on one line.
    private func checkPageInteractions(window: NSWindow, album: Album, tracks: [Track]) async -> [String] {
        var log: [String] = []
        let route = Route.album(.youtubeMusic, id: album.providerID, preview: album)
        // Start from another collection, so the album isn't already the playing context.
        if let sp = model.provider(.spotify) as? MockProvider {
            let other = sp.catalog.albums[1]
            model.play(sp.catalog.albumTracks[other.providerID] ?? [], from: .init(title: other.title, route: .album(.spotify, id: other.providerID, preview: other)))
            await settle(0.4)
        }
        model.debugFrames["play-button"] = nil
        await navigate(model, .home, route)
        await settle(1.0)
        if let frame = DebugProbes.windowFrame("play-button") ?? model.debugFrames["play-button"] {
            click(window: window, frame: frame)
            await settle(0.8)
            let started = model.isCurrentContext(route) && model.player.isPlaying && model.player.current?.id == tracks.first?.id
            let queue = model.player.queue.map(\.id)
            log.append("album hero Play → plays \"\(model.player.current?.title ?? "-")\" from the album: \(started ? "PASS" : "FAIL")")
            await settle(1.5)
            click(window: window, frame: DebugProbes.windowFrame("play-button") ?? frame)
            await settle(0.5)
            let pausedAt = model.player.currentTime
            log.append("album hero second click → \(model.player.state.rawValue) at \(String(format: "%.1f", pausedAt))s: \(model.player.state == .paused ? "PASS" : "FAIL")")
            capture(window.contentView?.superview, to: model.snapshotDirectory!.appendingPathComponent("00-album-hero-paused.png"))
            click(window: window, frame: DebugProbes.windowFrame("play-button") ?? frame)
            await settle(0.8)
            let resumed = model.player.isPlaying && model.player.queue.map(\.id) == queue && model.player.current?.id == tracks.first?.id && model.player.currentTime >= pausedAt
            log.append(String(format: "album hero third click → %@ at %.1fs, same queue and song: %@", model.player.state.rawValue, model.player.currentTime, resumed ? "PASS" : "FAIL"))
            capture(window.contentView?.superview, to: model.snapshotDirectory!.appendingPathComponent("00-album-hero-playing.png"))
        } else {
            log.append("album hero Play: button frame not found: NOT CHECKED")
        }

        // Click row 4 once (select), then press Return.
        await settle(0.3)
        if tracks.count > 3, let frame = DebugProbes.windowFrame("track-row-3") ?? model.debugFrames["track-row-3"] {
            click(window: window, frame: CGRect(x: frame.midX - 40, y: frame.minY, width: 80, height: frame.height))
            await settle(0.4)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let ret = keyEvent(window: window, "\r", keyCode: 36, flags: [], type: type) { window.sendEvent(ret) }
            }
            await settle(0.8)
            let ok = model.player.current?.id == tracks[3].id && model.player.queue.count == tracks.count
            log.append("select row 4, Return → plays \"\(model.player.current?.title ?? "-")\" (expected \"\(tracks[3].title)\"), queue \(model.player.queue.count) of \(tracks.count): \(ok ? "PASS" : "FAIL")")
            // Down arrow moves the selection; Return plays it.
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let down = keyEvent(window: window, "\u{F701}", keyCode: 125, flags: [.numericPad, .function], type: type) { window.sendEvent(down) }
            }
            await settle(0.2)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let ret = keyEvent(window: window, "\r", keyCode: 36, flags: [], type: type) { window.sendEvent(ret) }
            }
            await settle(0.8)
            log.append("Down arrow, Return → plays \"\(model.player.current?.title ?? "-")\" (expected \"\(tracks[safe: 4]?.title ?? "-")\"): \(model.player.current?.id == tracks[safe: 4]?.id ? "PASS" : "FAIL")")
            capture(window.contentView?.superview, to: model.snapshotDirectory!.appendingPathComponent("00-row-keyboard.png"))
        } else {
            log.append("Return on a selected row: row frame not found: NOT CHECKED")
        }

        // Hover, through synthesized mouse-moved events: a row swaps its number for a play button,
        // a card lights its tile and raises the play button, and that button plays the card's collection.
        if let frame = DebugProbes.windowFrame("track-row-1") {
            hover(window: window, at: CGPoint(x: frame.midX, y: frame.midY))
            await settle(0.5)
            capture(window.contentView?.superview, to: model.snapshotDirectory!.appendingPathComponent("00-hover-row.png"))
            log.append("row hover: captured 00-hover-row.png (row 2 should show a play button and a highlight)")
        }
        model.select(.explore)
        await settle(1.0)
        let cards = model.debugFrames.keys.filter { $0.hasPrefix("card-album:") }
            .compactMap { key in DebugProbes.windowFrame(key).map { (key, $0) } }
            .filter { $0.1.minY > 120 && $0.1.minX > 0 && $0.1.maxX < window.frame.width }
            .sorted { ($0.1.minY, $0.1.minX) < ($1.1.minY, $1.1.minX) }
        if let (key, frame) = cards.dropFirst().first {
            hover(window: window, at: CGPoint(x: frame.midX, y: frame.minY + frame.width / 2))
            await settle(0.6)
            capture(window.contentView?.superview, to: model.snapshotDirectory!.appendingPathComponent("00-hover-card.png"))
            // The play button sits 8 pt inside the artwork's bottom-right corner and is 40 pt wide.
            let button = CGRect(x: frame.maxX - 48, y: frame.minY + frame.width - 48, width: 40, height: 40)
            hover(window: window, at: CGPoint(x: button.midX, y: button.midY))
            await settle(0.6)
            capture(window.contentView?.superview, to: model.snapshotDirectory!.appendingPathComponent("00-hover-card-button.png"))
            let before = model.playingFrom?.title
            click(window: window, frame: button)
            await settle(1.2)
            let albumID = key.replacingOccurrences(of: "card-album:", with: "")
            let ok = model.playingFrom.flatMap { AppModel.ContextKey($0.route) }.map { "\($0.provider.rawValue):\($0.id)" } == albumID && model.player.isPlaying && model.path.isEmpty
            log.append("card hover play button (\(albumID)) → playing from \"\(model.playingFrom?.title ?? "-")\" (was \"\(before ?? "-")\"), stayed on New: \(ok ? "PASS" : "FAIL")")
        } else {
            log.append("card hover: no card frame found: NOT CHECKED")
        }
        hover(window: window, at: CGPoint(x: 5, y: 5))

        // The artist name must sit at the same place in the loading and loaded states.
        if let yt = model.provider(.youtubeMusic) as? MockProvider {
            let artist = yt.catalog.artists[2]
            yt.latency = .milliseconds(1500)
            model.cache.removeAll()
            model.debugFrames["artist-name"] = nil
            await navigate(model, .home, .artist(.youtubeMusic, id: artist.providerID, preview: artist))
            await settle(0.5)
            let loading = DebugProbes.windowFrame("artist-name")
            capture(window.contentView?.superview, to: model.snapshotDirectory!.appendingPathComponent("00-artist-loading.png"))
            await settle(2.0)
            let loaded = DebugProbes.windowFrame("artist-name")
            yt.latency = .zero
            capture(window.contentView?.superview, to: model.snapshotDirectory!.appendingPathComponent("00-artist-loaded.png"))
            if let loading, let loaded {
                let dy = abs(loading.minY - loaded.minY), dx = abs(loading.minX - loaded.minX)
                log.append(String(format: "artist name while loading %@ vs loaded %@ (moved %.1f, %.1f pt): %@", "\(loading.origin)", "\(loaded.origin)", dx, dy, dx < 1 && dy < 1 ? "PASS" : "FAIL"))
            } else {
                log.append("artist name frame: loading \(loading.map { "\($0)" } ?? "none"), loaded \(loaded.map { "\($0)" } ?? "none"): NOT CHECKED")
            }
        }

        // Hour-long durations stay on one line at a narrow width.
        let long = [3609.0, 7218, 3711, 201].enumerated().map { i, d in
            Track(providerID: "long\(i)", provider: .youtubeMusic, title: "Hour-long mix \(i + 1) with a fairly long title that truncates", artists: [ArtistRef(id: nil, name: "Sample Channel")], duration: d)
        }
        for (w, mode) in [(620, NSAppearance.Name.darkAqua), (900, .aqua)] {
            await captureHosted(
                TrackListView(tracks: long, style: .playlist, context: .init(title: "Long"))
                    .padding(12).frame(width: CGFloat(w), height: 320, alignment: .top).background(Color.pageBackground),
                size: NSSize(width: w, height: 320), appearance: mode,
                to: model.snapshotDirectory!.appendingPathComponent("00-durations-\(w).png")
            )
        }
        log.append("hour-long durations: captured 00-durations-620.png and 00-durations-900.png (check by eye)")
        // Put playback back where the screenshots expect it: the album, third song.
        model.play(tracks, startAt: 2, from: .init(title: album.title, route: route))
        await settle(0.4)
        return log
    }

    /// Live: a Home playlist with more than one page keeps queueing past its first page.
    private func checkLivePlaylistPlay(shelves: [Shelf]) async -> String {
        guard let yt = model.provider(.youtubeMusic) else { return "playlist Play: no provider: NOT CHECKED" }
        let playlists = shelves.flatMap(\.items).compactMap { if case .playlist(let p) = $0, !p.isCategory { p } else { nil } }
        for p in playlists.prefix(8) {
            guard let detail = try? await yt.playlist(id: p.providerID), detail.continuation != nil else { continue }
            model.play(.playlist(p))
            await settle(10)
            let count = model.player.queue.count
            return "playlist Play \"\(p.title)\": first page \(detail.tracks.count), queue \(count): \(count > detail.tracks.count ? "PASS" : "FAIL")"
        }
        return "playlist Play: no multi-page playlist among the first Home playlists: NOT CHECKED"
    }

    /// SwiftUI popovers live in their own window; capture it on its own.
    @discardableResult
    private func capturePopover(to url: URL) -> Bool {
        guard let popover = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }) else { return false }
        capture(popover.contentView?.superview ?? popover.contentView, to: url)
        return true
    }

    private func dismissPopover() {
        guard let popover = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }) else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: popover.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                popover.sendEvent(event)
            }
        }
    }

    /// Runs a main-menu command by title, the same path as its keyboard shortcut.
    private func performMenuItem(_ title: String) {
        func find(_ menu: NSMenu) -> (NSMenu, Int)? {
            for (i, item) in menu.items.enumerated() {
                if item.title == title { return (menu, i) }
                if let sub = item.submenu, let hit = find(sub) { return hit }
            }
            return nil
        }
        if let main = NSApp.mainMenu, let (menu, index) = find(main) {
            menu.update()
            menu.performActionForItem(at: index)
        }
    }

    private func keyEvent(window: NSWindow, _ chars: String, keyCode: UInt16, flags: NSEvent.ModifierFlags, type: NSEvent.EventType = .keyDown) -> NSEvent? {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: keyCode)
    }

    private func click(window: NSWindow, frame: CGRect) {
        // The build Mac is shared, so another app may be frontmost; send the click to a key window.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        let point = NSPoint(x: frame.midX, y: (window.contentView?.bounds.height ?? 0) - frame.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ) {
                window.sendEvent(event)
            }
        }
    }

    /// Moves the (synthesized) pointer to a point given in top-left window coordinates, for hover states.
    private func hover(window: NSWindow, at point: CGPoint) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        let p = NSPoint(x: point.x, y: (window.contentView?.bounds.height ?? 0) - point.y)
        // Move the real cursor too: SwiftUI hover follows the window server's tracking areas, which
        // synthesized NSEvents don't reach. Global display coordinates have a top-left origin.
        let screen = window.convertPoint(toScreen: p)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let global = CGPoint(x: screen.x, y: primaryHeight - screen.y)
        CGWarpMouseCursorPosition(global)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: global, mouseButton: .left)?.post(tap: .cghidEventTap)
        for _ in 0..<2 {
            if let event = NSEvent.mouseEvent(
                with: .mouseMoved, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
            ) {
                window.sendEvent(event)
            }
        }
    }

    private func doubleClick(window: NSWindow, at point: NSPoint) {
        for clickCount in 1...2 {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: type == .leftMouseDown ? 1 : 0
                ) {
                    window.sendEvent(event)
                }
            }
        }
    }

    // MARK: Capture

    /// Scrolls the page (not the sidebar or a panel) to its end, so lazy sections at the bottom get laid out.
    /// The page's scroll view is the widest tall one; the sidebar's and the panel's are narrower.
    private func scrollPageToEnd(in window: NSWindow) {
        func find(_ view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(find) }
        let page = find(window.contentView ?? NSView())
            .filter { $0.documentView != nil && !$0.isHidden && $0.bounds.height > 300 }
            .max { $0.bounds.width < $1.bounds.width }
        guard let page, let doc = page.documentView else { return }
        let clip = page.contentView
        var bounds = clip.bounds
        bounds.origin.y = doc.isFlipped ? 1e7 : -1e7
        clip.setBoundsOrigin(clip.constrainBoundsRect(bounds).origin)
        page.reflectScrolledClipView(clip)
    }

    /// Quits; exits outright if AppKit hasn't within two seconds (a sheet closing at the same moment has left the
    /// app idle until the run's timeout).
    static func quit() {
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
    }

    private func settle(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
        model.mainWindow?.contentView?.layoutSubtreeIfNeeded()
        model.mainWindow?.displayIfNeeded()
    }

    private func capture(_ view: NSView?, to url: URL) {
        // The window as the window server composites it (glass, vibrancy, the sidebar), when it's on screen.
        if let window = view?.window, window.isVisible, let image = WindowCapture.image(of: window) {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
            return
        }
        guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Selects a sidebar item, lets the stack reset, then pushes one page.
    private func navigate(_ m: AppModel, _ item: SidebarItem, _ route: Route) async {
        m.select(item)
        try? await Task.sleep(for: .milliseconds(250))
        m.path = [route]
    }

    /// The Medley account screens with made-up data and no server: the welcome and its sign-in and server steps,
    /// Settings › Account signed out, comparing the code with the device that has the sign-in key (before and after
    /// it allowed this Mac), back with an out-of-date key, and signed in with a device asking for it, and the "Allow …?" alert on the main window.
    private func captureAccount(window: NSWindow, dir: URL) async -> [String] {
        #if !DEBUG
        return ["account screens: debug builds only"]
        #else
        let hub = SyncHub.preview(model: model)
        model.usePreviewSync(hub)
        defer { model.usePreviewSync(nil) }
        let now = Date().timeIntervalSince1970 * 1000
        let mac = SyncDevice(id: DeviceID("mac"), name: "Studio Mac", platform: .mac, model: "Mac16,10", appVersion: "1.0",
                             createdAt: now, lastSeenAt: now, keyState: .holder)
        let phone = SyncDevice(id: DeviceID("phone"), name: "Riley's iPhone", platform: .ios, model: "iPhone18,1", appVersion: "1.0",
                               createdAt: now, lastSeenAt: now, keyState: .holder)
        let ipad = SyncDevice(id: DeviceID("ipad"), name: "Riley's iPad", platform: .ios, model: "iPad16,3", appVersion: "1.0",
                              createdAt: now, lastSeenAt: now - 20_000, keyState: .requested, publicKey: DeviceKeyPair.generate().publicKey)
        // The iPad asks this Mac (a holder); this Mac, asking, compares with the iPhone.
        let request = SyncService.KeyRequest(device: ipad, code: "305 118", commitment: "preview")
        let comparing = SyncService.KeyComparison(code: "482 913", holderID: phone.id, holderName: phone.name, allowed: false, confirmed: false)
        var allowed = comparing
        allowed.allowed = true
        let previewUser = ClerkUser(id: "user_preview", firstName: "Riley", lastName: "Calder", email: "riley@example.com")
        var log: [String] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let mode = appearance == .aqua ? "light" : "dark"
            hub.account.preview(user: nil)
            await captureHosted(FirstRunView(flow: FirstRunFlow(model: model)), size: NSSize(width: 1000, height: 640), appearance: appearance, to: dir.appendingPathComponent("24-welcome-\(mode).png"))
            await captureHosted(FirstRunView(flow: FirstRunFlow(model: model, step: .sync)), size: NSSize(width: 1000, height: 640), appearance: appearance, to: dir.appendingPathComponent("25-welcome-signin-\(mode).png"))
            await captureHosted(FirstRunView(flow: FirstRunFlow(model: model, step: .server)), size: NSSize(width: 1000, height: 640), appearance: appearance, to: dir.appendingPathComponent("26-welcome-server-\(mode).png"))
            await captureHosted(SettingsView(tab: .sync), size: NSSize(width: 560, height: 560), appearance: appearance, titled: true, to: dir.appendingPathComponent("27-settings-account-signedout-\(mode).png"))
            hub.account.preview(user: previewUser)
            hub.service.preview(selfID: mac.id, devices: [mac, phone], keyStatus: .comparing(comparing))
            await captureHosted(SettingsView(tab: .sync), size: NSSize(width: 560, height: 760), appearance: appearance, titled: true, to: dir.appendingPathComponent("28-settings-account-comparing-\(mode).png"))
            hub.service.preview(selfID: mac.id, devices: [mac, phone], keyStatus: .comparing(allowed))
            await captureHosted(SettingsView(tab: .sync), size: NSSize(width: 560, height: 760), appearance: appearance, titled: true, to: dir.appendingPathComponent("28b-settings-account-allowed-\(mode).png"))
            // Back after missing two rotations: this Mac keeps its old key until the listener asks again.
            var behind = mac
            behind.keyState = .requested
            hub.service.preview(selfID: mac.id, devices: [behind, phone], keyStatus: .outdated)
            await captureHosted(SettingsView(tab: .sync), size: NSSize(width: 560, height: 760), appearance: appearance, titled: true, to: dir.appendingPathComponent("28c-settings-account-outdated-\(mode).png"))
            hub.service.preview(selfID: mac.id, devices: [mac, phone, ipad], keyStatus: .available, requests: [request],
                                warning: "2 requests for your sign-ins failed or were refused today. If they weren't yours, remove devices you don't know and sign out of your account's other sessions.")
            await captureHosted(SettingsView(tab: .sync), size: NSSize(width: 560, height: 820), appearance: appearance, titled: true, to: dir.appendingPathComponent("29-settings-account-signedin-\(mode).png"))
            // The alert goes up on the main window while the iPad asks.
            NSApp.appearance = NSAppearance(named: appearance)
            window.makeKeyAndOrderFront(nil)
            await settle(1.2)
            if let sheet = window.attachedSheet {
                capture(sheet.contentView?.superview ?? sheet.contentView, to: dir.appendingPathComponent("30-allow-device-\(mode).png"))
                log.append("allow-device alert shown (\(mode)): PASS")
            } else {
                capture(window.contentView?.superview, to: dir.appendingPathComponent("30-allow-device-window-\(mode).png"))
                log.append("allow-device alert shown (\(mode)): FAIL (no sheet)")
            }
            log.append("allow-device alert shows the exchange's code: \(hub.pendingKeyRequest?.code == request.code ? "PASS" : "FAIL")")
            hub.dismissedKeyRequests.dismiss(request)
            await settle(0.6)
            hub.dismissedKeyRequests.removeAll()
            hub.service.preview(selfID: mac.id, devices: [mac, phone], keyStatus: .available)
            await settle(0.4)
        }
        return log
        #endif
    }

    private func captureSettings(appearance: NSAppearance.Name, provider: ProviderID? = nil, to url: URL) async {
        await captureHosted(SettingsView(tab: .accounts, accountsProvider: provider), size: NSSize(width: 560, height: 520), appearance: appearance, titled: true, to: url)
    }

    /// Renders a view in its own offscreen-style window (Settings, Mini Player) and captures it.
    private func captureHosted<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, titled: Bool = false, to url: URL) async {
        let host = NSHostingView(rootView: view.environment(model).environment(\.medleySnapshot, true))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: titled ? [.titled, .closable] : [.borderless], backing: .buffered, defer: false)
        window.title = "Accounts"
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(700))
        window.displayIfNeeded()
        capture(window.contentView?.superview ?? host, to: url)
        window.close()
    }
}

/// Numbers for round 5's layout items, from the frames `DebugFrame` records in snapshot mode.
@MainActor
private struct GeometryCheck {
    let model: AppModel
    let window: NSWindow
    let yt: MockProvider

    /// Where the floating player's top edge sits, above the window's bottom.
    static let playerBar: CGFloat = FloatingPlayer.height + FloatingPlayer.inset

    func run() async -> [String] {
        var out: [String] = []
        let playlist = yt.catalog.playlists.max(by: { ($0.trackCount ?? 0) < ($1.trackCount ?? 0) }) ?? yt.catalog.playlists[0]
        for (w, h) in [(1440, 900), (960, 620)] {
            window.requestFrame(NSRect(x: 40, y: 40, width: w, height: h), display: true)
            await sleep(0.6)
            let size = "\(w)x\(h)"

            for (name, page) in [("home", SidebarItem.home), ("new", SidebarItem.explore)] {
                model.path = []
                model.select(.songs)
                await sleep(0.4)
                model.select(page)
                await sleep(2.0)
                out += cardRows(page: "\(name) \(size)")
                if name == "home" {
                    if let f = DebugProbes.windowFrame("featured-card") {
                        out.append("home \(size): featured card at y \(Int(f.minY)), \(Int(f.width))×\(Int(f.height))")
                    } else {
                        out.append("home \(size): featured card: MISSING")
                    }
                }
            }

            model.select(.home)
            await sleep(0.3)
            model.debugFrames = [:]
            model.path = [.playlist(.youtubeMusic, id: playlist.providerID, preview: playlist)]
            await sleep(1.4)
            let limit = CGFloat(h) - Self.playerBar
            let rows = (0..<80).compactMap { DebugProbes.windowFrame("track-row-\($0)") }.filter { $0.minY >= 0 && $0.maxY <= limit + 0.5 }
            out.append("playlist \(size) (\(playlist.trackCount ?? 0) songs): \(rows.count) whole rows above the player (player top y \(Int(limit)))")
            out.append("playlist \(size): sort header \(DebugProbes.windowFrame("sort-menu").map { "at x \(Int($0.minX)) y \(Int($0.minY))" } ?? "MISSING")")
        }
        return out
    }

    /// Laid-out cards (whole page height, visible width) grouped into rows by their artwork's top edge. In each row every artwork has one size
    /// and every caption starts at one height.
    private func cardRows(page: String) -> [String] {
        let bounds = CGRect(origin: .zero, size: window.frame.size)
        let keys = (DebugProbes.views.keyEnumerator().allObjects as? [NSString] ?? []).map { $0 as String }
        let ids = keys.filter { $0.hasPrefix("card-art-") }.map { String($0.dropFirst("card-art-".count)) }
        let cards: [(art: CGRect, caption: CGRect)] = ids.compactMap { id in
            guard let probe = DebugProbes.views.object(forKey: "card-art-\(id)" as NSString), probe.window != nil, !probe.isHiddenOrHasHiddenAncestor,
                  let art = DebugProbes.windowFrame("card-art-\(id)"), let caption = DebugProbes.windowFrame("card-caption-\(id)"),
                  art.minX >= bounds.minX, art.maxX <= bounds.maxX + 1 else { return nil }
            return (art, caption)
        }
        let rows = Dictionary(grouping: cards) { Int(($0.art.minY / 4).rounded()) }.sorted { $0.key < $1.key }
        if rows.isEmpty { return ["\(page): no card rows laid out: FAIL"] }
        return rows.map { _, row in
            let sizes = Set(row.map { "\(Int($0.art.width.rounded()))×\(Int($0.art.height.rounded()))" })
            let captionTops = Set(row.map { Int($0.caption.minY.rounded()) })
            let captionHeights = Set(row.map { Int($0.caption.height.rounded()) })
            let ok = sizes.count == 1 && captionTops.count == 1 && captionHeights.count == 1
            let xs = row.map { Int($0.art.minX) }.sorted()
            return "\(page): row at y \(Int(row[0].art.minY)): \(row.count) cards at x \(xs), artwork \(sizes.sorted().joined(separator: ", ")), caption tops \(captionTops.sorted()), caption heights \(captionHeights.sorted()): \(ok ? "PASS" : "FAIL")"
        }
    }

    private func sleep(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
}
#endif
