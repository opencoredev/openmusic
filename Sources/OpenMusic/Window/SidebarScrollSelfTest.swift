import AppKit
import OpenMusicCore
import QuartzCore
import SwiftUI

/// `OPENMUSIC_MOCK=1 OPENMUSIC_SELFTEST=sidebarscroll OPENMUSIC_SELFTEST_OUT=<file>`: hides and shows the sidebar on long pages
/// that are scrolled down, first at rest and then while the page is scrolling, the way it feels when you collapse
/// the sidebar halfway down Home or an album. Records every frame of each move with `FrameRecorder` and writes one
/// line per toggle, per-mode totals, and a last line `SCORE <dropped frames over all moves>` for the hill climb.
/// Each recording covers the whole second after the toggle (`whole: true`), so work deferred until the sidebar
/// stops (a late reflow) still counts. Main-thread CPU time (`CLOCK_THREAD_CPUTIME_ID`) is logged beside it: it includes the page's own scrolling work,
/// which hid real gains in the frames, so it's a diagnostic, not the score.
/// Quits when done. Writes no line starting with SCORE if setup fails, so a broken run can't score.
@MainActor
struct SidebarScrollSelfTest {
    let model: AppModel
    let output: URL

    func run() async {
        var log: [String] = []
        func note(_ line: String) {
            log.append(line)
            try? log.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
        }
        while model.mainWindow == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let window = model.mainWindow, let yt = model.provider(.youtubeMusic) as? MockProvider else {
            note("setup: FAIL no window or mock provider")
            NSApp.terminate(nil)
            return
        }
        window.requestFrame(NSRect(x: 60, y: 60, width: 1440, height: 900), display: true)
        try? await Task.sleep(for: .seconds(1.5))
        let album = yt.catalog.albums.max { $0.trackCount ?? 0 < $1.trackCount ?? 0 } ?? yt.catalog.albums[0]
        let artist = yt.catalog.artists[0]
        let pages: [(String, () -> Void)] = [
            ("home", { model.select(.home) }),
            ("album", { model.select(.home); model.path = [.album(.youtubeMusic, id: album.providerID, preview: album)] }),
            ("artist", { model.select(.home); model.path = [.artist(.youtubeMusic, id: artist.providerID, preview: artist)] }),
            ("songs", { model.select(.songs) }),
        ]
        var rest: [FrameRecorder.Result] = []
        var scrolling: [FrameRecorder.Result] = []
        var restCPU: Double = 0
        var scrollingCPU: Double = 0
        func cpuMs() -> Double {
            var ts = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
            return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1_000_000
        }
        for (name, open) in pages {
            if model.columnVisibility == .detailOnly {
                SplitViewTuning.toggleSidebar(in: window)
                try? await Task.sleep(for: .seconds(1.0))
            }
            open()
            try? await Task.sleep(for: .seconds(1.5))
            guard let scrollView = Self.pageScrollView(in: window) else {
                note("setup: FAIL no scrollable page on \(name)")
                NSApp.terminate(nil)
                return
            }
            Self.scroll(scrollView, toFraction: 0.45)
            try? await Task.sleep(for: .seconds(0.8))
            for cycle in 1...4 {
                let hiding = model.columnVisibility != .detailOnly
                let recorder = FrameRecorder(window: window, whole: true)
                recorder.start()
                let cpu0 = cpuMs()
                SplitViewTuning.toggleSidebar(in: window)
                try? await Task.sleep(for: .seconds(1.0))
                let cpu = cpuMs() - cpu0
                let result = recorder.stop()
                rest.append(result)
                restCPU += cpu
                note(String(format: "%@ rest %d %@: cpu %.0f ms, ", name, cycle, hiding ? "hide" : "show", cpu) + result.line)
            }
            for cycle in 1...4 {
                let hiding = model.columnVisibility != .detailOnly
                guard let scrollView = Self.pageScrollView(in: window) else { continue }
                let driver = ScrollDriver(scrollView: scrollView)
                driver.start()
                try? await Task.sleep(for: .seconds(0.3))
                let recorder = FrameRecorder(window: window, whole: true)
                recorder.start()
                let cpu0 = cpuMs()
                SplitViewTuning.toggleSidebar(in: window)
                try? await Task.sleep(for: .seconds(1.0))
                let cpu = cpuMs() - cpu0
                let result = recorder.stop()
                driver.stop()
                scrolling.append(result)
                scrollingCPU += cpu
                note(String(format: "%@ scrolling %d %@: cpu %.0f ms, ", name, cycle, hiding ? "hide" : "show", cpu) + result.line)
                try? await Task.sleep(for: .seconds(0.3))
            }
        }
        if model.columnVisibility == .detailOnly {
            SplitViewTuning.toggleSidebar(in: window)
            try? await Task.sleep(for: .seconds(1.0))
        }
        func summary(_ label: String, _ results: [FrameRecorder.Result]) -> Int {
            let gaps = results.map(\.longestGapMs).sorted()
            let dropped = results.map(\.dropped).reduce(0, +)
            note(String(format: "%@: %d moves, dropped %d, longest gap median %.1f ms (max %.1f)", label, results.count, dropped,
                        gaps.isEmpty ? 0 : gaps[gaps.count / 2], gaps.last ?? 0))
            return dropped
        }
        let dropped = summary("at rest, scrolled down", rest) + summary("while scrolling", scrolling)
        note(String(format: "main-thread cpu: at rest %.0f ms, while scrolling %.0f ms, dropped frames %d", restCPU, scrollingCPU, dropped))
        let total = dropped
        let hz = (rest.first ?? scrolling.first)?.refreshHz ?? 0
        if rest.count == 16, scrolling.count == 16 {
            note(String(format: "refresh %.0f Hz", hz))
            note("SCORE \(total)")
        } else {
            note("setup: FAIL only \(rest.count) + \(scrolling.count) of 32 moves ran")
        }
        NSApp.terminate(nil)
    }

    /// The page's vertical scroll view: the widest one whose content is taller than what it shows (the sidebar's
    /// list is narrower than any page).
    static func pageScrollView(in window: NSWindow) -> NSScrollView? {
        guard let root = window.contentView else { return nil }
        func all(_ view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(all) }
        return all(root)
            .filter { sv in
                guard let doc = sv.documentView, !sv.isHidden else { return false }
                return doc.frame.height > sv.contentView.bounds.height + 200
            }
            .max { $0.convert($0.bounds, to: nil).width < $1.convert($1.bounds, to: nil).width }
    }

    static func scroll(_ scrollView: NSScrollView, toFraction fraction: CGFloat) {
        guard let doc = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let maxY = max(0, doc.frame.height - clip.bounds.height)
        let y = doc.isFlipped ? maxY * fraction : maxY * (1 - fraction)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }
}

/// Scrolls a page steadily, one step per display frame (about 600 pt/s at 60 Hz), turning around at either end.
@MainActor
final class ScrollDriver: NSObject {
    private weak var scrollView: NSScrollView?
    private var link: CADisplayLink?
    private var step: CGFloat = 10

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
    }

    func start() {
        guard let scrollView else { return }
        let link = scrollView.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let scrollView, let doc = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let maxY = max(0, doc.frame.height - clip.bounds.height)
        var y = clip.bounds.origin.y + step
        if y > maxY || y < 0 {
            step = -step
            y = min(max(0, y), maxY)
        }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }
}
