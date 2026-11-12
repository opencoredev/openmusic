#if DEBUG
import AppKit
import OpenMusicCore

/// `OPENMUSIC_SNAPSHOT_DIR=<dir> OPENMUSIC_SNAPSHOT_ONLY=demo`: the screenshots for posting (scripts/demo-shots.sh),
/// captured with the window's shadow on a transparent background in light and dark. With `OPENMUSIC_MOCK=1` (the
/// sample data, what the repository's images use) they show only invented artists and procedural covers; with
/// `OPENMUSIC_MOCK=demo OPENMUSIC_DEMO_ART=<dir>`, real chart albums and their covers with a made-up listener.
///
/// Retina: captures come out at the screen's scale. The script starts a 2× virtual display first
/// (scripts/virtual-display.m); the window moves to the first 2× screen it finds, or stays put at 1× with a note in
/// `demo.txt`. `OPENMUSIC_DEMO_SIZE=1440x900` sets the window size in points.
@MainActor
struct DemoShots {
    let model: AppModel
    let window: NSWindow
    let dir: URL
    let yt: MockProvider
    let sp: MockProvider

    func run() async {
        var log: [String] = []
        let env = LaunchEnvironment.current
        let size = (env["OPENMUSIC_DEMO_SIZE"] ?? "1440x900").split(separator: "x").compactMap { Double($0) }
        let (w, h) = size.count == 2 ? (size[0], size[1]) : (1440, 900)

        // A 2× screen may take a moment to appear after the virtual display starts.
        var screen = NSScreen.screens.first { $0.backingScaleFactor >= 2 }
        for _ in 0..<20 where screen == nil {
            try? await Task.sleep(for: .milliseconds(250))
            screen = NSScreen.screens.first { $0.backingScaleFactor >= 2 }
        }
        let target = screen ?? window.screen ?? NSScreen.main
        log.append("screens: " + NSScreen.screens.map { "\(Int($0.frame.width))x\(Int($0.frame.height))@\(Int($0.backingScaleFactor))x" }.joined(separator: ", "))
        log.append(screen == nil ? "no 2x screen: captures are 1x" : "capturing on a 2x screen")
        if let target {
            let visible = target.visibleFrame
            let frame = NSRect(x: visible.midX - w / 2, y: visible.midY - h / 2, width: w, height: h)
            window.requestFrame(frame, display: true)
        }

        guard let hero = yt.demoNowPlaying ?? yt.sampleNowPlaying else {
            log.append("no screenshot data: run with OPENMUSIC_MOCK=1 (sample) or OPENMUSIC_MOCK=demo")
            write(log)
            return
        }
        let sample = yt.demoNowPlaying == nil
        log.append(sample ? "data: sample (invented artists, procedural covers)" : "data: demo (chart albums)")

        // Some listening history first, so the sidebar's Recently Played reads like a real library.
        let history = sample
            ? [3, 2, 1].compactMap { yt.sampleAlbum($0) }
            : ["sabrina-carpenter-short-n-sweet", "olivia-dean-the-art-of-loving", "taylor-swift-the-life-of-a-showgirl"].compactMap { yt.demoAlbum($0) }
        for album in history { play(album, provider: yt) }
        if let mix = sp.catalog.playlists.first(where: { $0.title == "Daily Mix 1" }), let tracks = sp.catalog.playlistTracks[mix.providerID] {
            model.play(tracks, from: AppModel.PlayingFrom(title: mix.title, route: .playlist(.spotify, id: mix.providerID, preview: mix)))
        }
        if let album = sample ? sp.sampleAlbum(0) : sp.demoAlbum("noah-kahan-the-great-divide") { play(album, provider: sp) }
        playHero(hero)

        struct Shot {
            let name: String
            let apply: @MainActor (AppModel) async -> Void
        }
        let heroRoute = Route.album(.youtubeMusic, id: hero.album.providerID, preview: hero.album)
        let shots: [Shot] = [
            Shot(name: "home") { m in m.playerBanner = nil; m.inspector = nil; m.select(.home) },
            Shot(name: "album") { m in m.inspector = nil; await open(m, heroRoute) },
            Shot(name: "lyrics") { m in await open(m, heroRoute); m.inspector = .lyrics },
            Shot(name: "queue") { m in m.select(.home); m.inspector = .queue },
            Shot(name: "new") { m in m.inspector = nil; m.select(.explore) },
            // "Continue from iPhone": what sync shows when the phone is playing something else.
            Shot(name: "handoff") { m in
                m.inspector = nil
                m.select(.home)
                // Another song playing here, so the banner offers the phone's.
                let other: (album: Album, tracks: [Track], index: Int)?
                if sample {
                    other = yt.sampleAlbum(2).flatMap { album in yt.catalog.albumTracks[album.providerID].map { (album, $0, 2) } }
                } else if let album = yt.demoAlbum("sabrina-carpenter-short-n-sweet"), let tracks = yt.catalog.albumTracks[album.providerID],
                          let espresso = yt.demoTrack("sabrina-carpenter-short-n-sweet", "Espresso"), let i = tracks.firstIndex(of: espresso) {
                    other = (album, tracks, i)
                } else {
                    other = nil
                }
                if let other, other.tracks.indices.contains(other.index) {
                    m.play(other.tracks, startAt: other.index,
                           from: AppModel.PlayingFrom(title: other.album.title, route: .album(.youtubeMusic, id: other.album.providerID, preview: other.album)))
                    try? await Task.sleep(for: .milliseconds(200))
                    m.player.seek(to: 41)
                }
                let phone = hero.tracks[hero.index]
                m.playerBanner = PlayerBanner(id: "demo", symbol: "iphone", title: "Continue from iPhone",
                                              subtitle: "\(phone.title) · \(phone.artistLine) · 1:12", actionTitle: "Play Here", action: {},
                                              artwork: phone.artwork)
            },
        ]
        let only = env["OPENMUSIC_DEMO_SHOTS"].map { Set($0.split(separator: ",").map(String.init)) }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            let mode = appearance == .aqua ? "light" : "dark"
            for shot in shots where only?.contains(shot.name) ?? true {
                if shot.name != "handoff", model.player.current?.id != hero.tracks[hero.index].id { playHero(hero) }
                await shot.apply(model)
                // Covers load and the page settles; then put the song back at 1:12 for every capture.
                await settle(1.6)
                if shot.name != "handoff" { model.player.seek(to: hero.position) } else { model.player.seek(to: 41) }
                await settle(0.25)
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
                await settle(0.15)
                let url = dir.appendingPathComponent("mac-\(shot.name)-\(mode).png")
                if let image = WindowCapture.image(of: window, shadow: true) {
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                    log.append("\(url.lastPathComponent): \(image.width)x\(image.height)")
                } else {
                    log.append("\(url.lastPathComponent): capture failed")
                }
            }
        }
        model.playerBanner = nil
        write(log)
    }

    private func play(_ album: Album, provider: MockProvider) {
        guard let tracks = provider.catalog.albumTracks[album.providerID] else { return }
        model.play(tracks, from: AppModel.PlayingFrom(title: album.title, route: .album(album.provider, id: album.providerID, preview: album)))
    }

    private func playHero(_ hero: DemoNowPlaying) {
        model.play(hero.tracks, startAt: hero.index,
                   from: AppModel.PlayingFrom(title: hero.album.title, route: .album(.youtubeMusic, id: hero.album.providerID, preview: hero.album)))
        model.player.seek(to: hero.position)
    }

    private func open(_ m: AppModel, _ route: Route) async {
        if m.path.last != route {
            m.select(.home)
            try? await Task.sleep(for: .milliseconds(250))
            m.path = [route]
        }
    }

    private func settle(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private func write(_ log: [String]) {
        try? log.joined(separator: "\n").appending("\n").write(to: dir.appendingPathComponent("demo.txt"), atomically: true, encoding: .utf8)
    }
}
#endif
