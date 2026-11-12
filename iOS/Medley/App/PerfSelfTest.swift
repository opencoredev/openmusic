import MedleyCore
import QuartzCore
import SwiftUI
import UIKit

#if DEBUG
/// Frame timing for the transitions people notice: `-MedleyMock YES -MedleySelfTest perf`
/// (`scripts/ios.sh <slot> perf` runs it and prints the log).
///
/// Each scenario is triggered the way the UI triggers it (same model change, same animation) while a display link
/// records every frame and a run-loop observer adds up the time the main thread was busy. Per run it reports the
/// longest gap between frames, hitch time (the part of every late frame beyond one refresh interval, frames more
/// than 1.5 intervals apart only), dropped frames and main-thread busy time over the window. Each scenario runs
/// several times; the summary gives the median and the worst run. Writes `Documents/perf.log`, ends with "done".
@MainActor
struct PerfSelfTest {
    let model: AppModel
    private let log = PerfLog()
    private let runs = 6

    /// `-MedleyPerfOnly a,b`: run only these scenarios (the steps between them still run).
    private let only: Set<String>? = LaunchOptions.argument("MedleyPerfOnly", in: ProcessInfo.processInfo.arguments)
        .map { Set($0.split(separator: ",").map(String.init)) }

    func run() async {
        // `-MedleyPerfDelay <s>`: time to attach Instruments first.
        if let delay = LaunchOptions.argument("MedleyPerfDelay", in: ProcessInfo.processInfo.arguments).flatMap(Double.init) {
            try? await Task.sleep(for: .seconds(delay))
        }
        log.write("start \(Date().formatted(.iso8601))")
        guard let yt = model.provider(.youtubeMusic) as? MockProvider,
              let album = yt.catalog.albums.first(where: { $0.kind == .album }),
              let tracks = yt.catalog.albumTracks[album.providerID], tracks.count > 2 else { return finish("FAIL setup: no mock album") }
        let player = model.player
        model.play(tracks, from: .album(album))
        try? await Task.sleep(for: .seconds(2))
        await settle()

        // Home first: scroll the shelves and switch tabs before anything else is cached.
        await measure("home-scroll", runs: 3, window: 2.4) { probe in
            guard let scroll = Self.mainScrollView() else { return }
            scroll.setContentOffset(.zero, animated: false)
            Self.drive(scroll, in: probe, speed: 2400)
        } reset: {
            Self.mainScrollView()?.setContentOffset(.zero, animated: false)
        }
        await measure("tab-switch", runs: runs, window: 0.6) { _ in
            let order: [AppTab] = [.home, .new, .library, .search]
            let next = order[((order.firstIndex(of: model.tab) ?? 0) + 1) % order.count]
            model.tab = next
        }
        model.tab = .home
        await settle()
        await measure("album-push", runs: runs, window: 0.8) { _ in
            model.open(.album(album))
        } reset: {
            model.paths[.home] = []
        }
        await measure("play-pause", runs: runs, window: 0.5) { _ in
            player.togglePlayPause()
        }
        if !player.isPlaying { player.togglePlayPause() }
        await measure("settings-sheet", runs: 4, window: 0.8) { _ in
            model.isSettingsPresented = true
        } reset: {
            model.isSettingsPresented = false
        }

        // Now Playing open and close, the way the mini player and the chevron do it.
        await measure("nowplaying-open", runs: runs, window: 0.9) { _ in
            model.presentNowPlaying()
        } reset: {
            model.isNowPlayingPresented = false
        }
        model.presentNowPlaying()
        await settle(1.2)
        await measure("nowplaying-close", runs: runs, window: 0.9) { _ in
            model.isNowPlayingPresented = false
        } reset: {
            model.presentNowPlaying()
        }
        model.presentNowPlaying()
        await settle(1.2)

        // Lyrics for a song that just started: the first open has to wait for them unless they were fetched already.
        yt.latency = .milliseconds(300)
        await measure("lyrics-open-new-song", runs: 4, window: 1.0) { _ in
            withAnimation(.smooth(duration: 0.4)) { model.nowPlayingMode = .lyrics }
        } reset: {
            withAnimation(.smooth(duration: 0.4)) { model.nowPlayingMode = .artwork }
            try? await Task.sleep(for: .seconds(0.8))
            player.next()
            try? await Task.sleep(for: .seconds(1.5))
        }
        yt.latency = .zero

        // A long synced song, like most real ones (YouTube Music lyrics run 40 to 90 lines).
        if let track = player.current {
            model.seedLyricsForTesting(Self.longLyrics(), for: track)
            player.seek(to: 40)
        }
        withAnimation(.smooth(duration: 0.4)) { model.nowPlayingMode = .artwork }
        await settle(1.2)
        await measure("lyrics-open", runs: runs, window: 0.9) { _ in
            withAnimation(.smooth(duration: 0.4)) { model.nowPlayingMode = .lyrics }
        } reset: {
            withAnimation(.smooth(duration: 0.4)) { model.nowPlayingMode = .artwork }
        }
        withAnimation(.smooth(duration: 0.4)) { model.nowPlayingMode = .lyrics }
        await settle(1.2)
        await measure("lyrics-close", runs: runs, window: 0.9) { _ in
            withAnimation(.smooth(duration: 0.4)) { model.nowPlayingMode = .artwork }
        } reset: {
            withAnimation(.smooth(duration: 0.4)) { model.nowPlayingMode = .lyrics }
        }
        // Lyrics left open while the song plays: the per-tick cost.
        withAnimation(.smooth(duration: 0.4)) { model.nowPlayingMode = .lyrics }
        await settle(1.2)
        layers("lyrics")
        await measure("lyrics-playing-4s", runs: 2, window: 4) { _ in }

        withAnimation(.smooth(duration: 0.4)) { model.nowPlayingMode = .artwork }
        await settle(1.2)
        await measure("queue-open", runs: runs, window: 0.9) { _ in
            withAnimation(.smooth(duration: 0.4)) { model.nowPlayingMode = .queue }
        } reset: {
            withAnimation(.smooth(duration: 0.4)) { model.nowPlayingMode = .artwork }
        }
        withAnimation(.smooth(duration: 0.4)) { model.nowPlayingMode = .queue }
        await settle(1.2)
        layers("queue")
        await measure("queue-close", runs: runs, window: 0.9) { _ in
            withAnimation(.smooth(duration: 0.4)) { model.nowPlayingMode = .artwork }
        } reset: {
            withAnimation(.smooth(duration: 0.4)) { model.nowPlayingMode = .queue }
        }
        withAnimation(.smooth(duration: 0.4)) { model.nowPlayingMode = .artwork }
        await settle(1.2)
        layers("artwork")
        await measure("nowplaying-playing-4s", runs: 2, window: 4) { _ in }
        model.isNowPlayingPresented = false
        await settle(1.2)

        // Search: results for a submitted query, then typing (suggestions follow each keystroke).
        model.tab = .search
        await settle()
        let queries = ["glass", "night", "harbor", "drive", "summer", "ocean"]
        var q = 0
        await measure("search-submit", runs: runs, window: 0.8) { _ in
            model.searchText = queries[q % queries.count]
            model.submitSearch()
            q += 1
        }
        await measure("search-typing", runs: 3, window: 1.6) { _ in
            Task {
                model.searchText = ""
                model.submittedQuery = ""
                for prefix in (1...9).map({ String("daft punk".prefix($0)) }) {
                    model.searchText = prefix
                    try? await Task.sleep(for: .milliseconds(140))
                }
            }
        }
        model.searchText = ""
        model.submittedQuery = ""
        model.tab = .home
        finish("done")
    }

    // MARK: Running

    struct Run {
        let longestGapMs: Double
        let hitchMs: Double
        let dropped: Int
        let busyMs: Double
        let frames: Int
        let refreshHz: Double
    }

    private func measure(_ name: String, runs: Int, window: Double, _ action: (FrameProbe) async -> Void,
                         reset: () async -> Void = {}) async {
        if let only, !only.contains(name) { return }
        var results: [Run] = []
        for i in 1...runs {
            let probe = FrameProbe()
            probe.start()
            await action(probe)
            try? await Task.sleep(for: .seconds(window))
            let r = probe.stop()
            results.append(r)
            log.write(String(format: "  %@ #%d: gap %.1f ms, hitch %.1f ms, dropped %d, main %.0f ms, %d frames",
                             name, i, r.longestGapMs, r.hitchMs, r.dropped, r.busyMs, r.frames))
            await reset()
            await settle()
        }
        func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s[s.count / 2] }
        log.write(String(format: "%@: hitch median %.1f ms (max %.1f), longest gap median %.1f ms (max %.1f), dropped median %d, main median %.0f ms (max %.0f), %.0f Hz",
                         name, median(results.map(\.hitchMs)), results.map(\.hitchMs).max() ?? 0,
                         median(results.map(\.longestGapMs)), results.map(\.longestGapMs).max() ?? 0,
                         Int(median(results.map { Double($0.dropped) })),
                         median(results.map(\.busyMs)), results.map(\.busyMs).max() ?? 0, results.first?.refreshHz ?? 0))
    }

    /// What the render server composites for the screen on show: layers, and the ones that need an offscreen
    /// pass (filters such as blur, masks, shadows without a path).
    private func layers(_ name: String) {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows)
            .first(where: \.isKeyWindow) else { return }
        var total = 0, visible = 0, filtered = 0, masked = 0, shadowed = 0
        func visit(_ layer: CALayer, hidden: Bool) {
            total += 1
            let off = hidden || layer.isHidden || layer.opacity < 0.01
            if !off {
                visible += 1
                if !(layer.filters ?? []).isEmpty || !(layer.backgroundFilters ?? []).isEmpty || layer.compositingFilter != nil { filtered += 1 }
                if layer.mask != nil { masked += 1 }
                if layer.shadowOpacity > 0, layer.shadowPath == nil { shadowed += 1 }
            }
            layer.sublayers?.forEach { visit($0, hidden: off) }
        }
        // Full-screen covers live in their own window above the tab view.
        for w in window.windowScene?.windows ?? [window] { visit(w.layer, hidden: w.isHidden) }
        log.write("layers \(name): \(total) total, \(visible) visible, \(filtered) filtered, \(masked) masked, \(shadowed) shadowed")
    }

    private func settle(_ seconds: Double = 0.9) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func finish(_ line: String) {
        log.write(line)
    }

    // MARK: Helpers

    /// The tallest visible vertical scroll view in the key window (the current tab's page).
    static func mainScrollView() -> UIScrollView? {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        var best: UIScrollView?
        func visit(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0.01 else { return }
            if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height + 100,
               scroll.bounds.width > 300, scroll.window != nil,
               scroll.contentSize.height > (best?.contentSize.height ?? 0) {
                best = scroll
            }
            view.subviews.forEach(visit)
        }
        if let window { visit(window) }
        return best
    }

    /// Scrolls at `speed` points per second, one step per frame, down to the end and back up, like a long flick.
    static func drive(_ scroll: UIScrollView, in probe: FrameProbe, speed: CGFloat) {
        var direction: CGFloat = 1
        probe.onFrame = { dt in
            let maxY = max(0, scroll.contentSize.height - scroll.bounds.height)
            var y = scroll.contentOffset.y + direction * speed * CGFloat(dt)
            if y >= maxY { y = maxY; direction = -1 }
            if y <= 0, direction < 0 { y = 0; probe.onFrame = nil }
            scroll.contentOffset.y = y
        }
    }

    /// 64 synced lines, a line every 3.2 s.
    static func longLyrics() -> Lyrics {
        let words = ["Static on the line tonight", "Your voice is coming through in waves", "Tell me that you're on your way",
                     "Tell me something that can stay", "Paper planes across the ceiling", "Every one a wish we made",
                     "Counting down the summer evenings", "Watching all the colors fade"]
        let lines = (0..<64).map { i in LyricLine(time: 4 + Double(i) * 3.2, text: i % 9 == 8 ? "" : words[i % words.count]) }
        return Lyrics(lines: lines, source: "Synced lyrics")
    }
}

/// Display-link frames and main-thread busy time between `start()` and `stop()`.
@MainActor
final class FrameProbe: NSObject {
    /// Called on every frame with the time since the previous one, to drive a scroll.
    var onFrame: ((CFTimeInterval) -> Void)?
    private var link: CADisplayLink?
    private var observer: CFRunLoopObserver?
    private var stamps: [CFTimeInterval] = []
    private var interval: CFTimeInterval = 1.0 / 60
    private var busySince: CFTimeInterval?
    private var busy: CFTimeInterval = 0

    func start() {
        let now = CACurrentMediaTime()
        stamps = [now]
        busySince = now
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue,
                                                          true, Int.max) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.runLoop(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func runLoop(_ activity: CFRunLoopActivity) {
        let now = CACurrentMediaTime()
        if activity == .beforeWaiting, let since = busySince {
            busy += now - since
            busySince = nil
        } else if activity == .afterWaiting {
            busySince = now
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        if link.targetTimestamp > link.timestamp { interval = link.targetTimestamp - link.timestamp }
        let previous = stamps.last ?? link.timestamp
        stamps.append(link.timestamp)
        onFrame?(max(0, link.timestamp - previous))
    }

    func stop() -> PerfSelfTest.Run {
        let now = CACurrentMediaTime()
        link?.invalidate()
        link = nil
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        if let since = busySince { busy += now - since }
        var longest: CFTimeInterval = 0
        var hitch: CFTimeInterval = 0
        var dropped = 0
        for i in 1..<max(1, stamps.count) {
            let gap = stamps[i] - stamps[i - 1]
            longest = max(longest, gap)
            if gap > interval * 1.5 {
                hitch += gap - interval
                dropped += Int((gap / interval).rounded()) - 1
            }
        }
        return .init(longestGapMs: longest * 1000, hitchMs: hitch * 1000, dropped: dropped, busyMs: busy * 1000,
                     frames: max(0, stamps.count - 1), refreshHz: 1 / interval)
    }
}

@MainActor
private final class PerfLog {
    let url: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("perf.log")
    }()

    init() { try? Data().write(to: url) }

    func write(_ line: String) {
        print("[perf] \(line)")
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    }
}
#endif
