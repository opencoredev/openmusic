import AppKit
import MedleyCore
import QuartzCore
import SwiftUI

/// `MEDLEY_MOCK=1 MEDLEY_SELFTEST=sidebar MEDLEY_SELFTEST_OUT=<file>`: runs the app normally at 1440×900 and
/// hides and shows the sidebar six times on Home, New, an album, an artist and Songs, the way the toolbar button does.
/// A display link records every frame while the sidebar moves: how long the move takes (first to last change of
/// the sidebar's width), the longest gap between frames and the frames dropped against the display's refresh.
/// Writes one line per toggle and a summary, then quits.
// Not behind `#if DEBUG`, unlike the other self-tests: the sidebar frame-timing benchmark runs it on Release builds.
@MainActor
struct SidebarSelfTest {
    let model: AppModel
    let output: URL

    func run() async {
        var log: [String] = []
        func note(_ line: String) {
            log.append(line)
            try? log.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
        }
        while model.mainWindow == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let window = model.mainWindow, let yt = model.provider(.youtubeMusic) as? MockProvider else { return note("setup: FAIL") }
        window.requestFrame(NSRect(x: 60, y: 60, width: 1440, height: 900), display: true)
        try? await Task.sleep(for: .seconds(1.5))
        let album = yt.catalog.albums[0]
        let artist = yt.catalog.artists[0]
        let pages: [(String, () -> Void)] = [
            ("home", { model.select(.home) }),
            ("new", { model.select(.explore) }),
            ("album", { model.select(.home); model.path = [.album(.youtubeMusic, id: album.providerID, preview: album)] }),
            ("artist", { model.select(.home); model.path = [.artist(.youtubeMusic, id: artist.providerID, preview: artist)] }),
            ("songs", { model.select(.songs) }),
        ]
        var all: [FrameRecorder.Result] = []
        var byPage: [(String, [FrameRecorder.Result])] = []
        for (name, open) in pages {
            open()
            try? await Task.sleep(for: .seconds(1.5))
            for cycle in 1...6 {
                let hiding = model.columnVisibility != .detailOnly
                let recorder = FrameRecorder(window: window)
                recorder.start()
                SplitViewTuning.toggleSidebar(in: window)
                try? await Task.sleep(for: .seconds(1.0))
                let result = recorder.stop()
                all.append(result)
                note("\(name) \(cycle) \(hiding ? "hide" : "show"): \(result.line)")
            }
            byPage.append((name, Array(all.suffix(6))))
            // Always leave each page with the sidebar shown.
            if model.columnVisibility == .detailOnly {
                SplitViewTuning.toggleSidebar(in: window)
                try? await Task.sleep(for: .seconds(1.0))
            }
        }
        for (name, results) in byPage {
            let frames = results.map(\.frames).sorted()
            let gaps = results.map(\.longestGapMs).sorted()
            note(String(format: "page %@: frames median %d, longest gap median %.1f ms, dropped %d", name, frames[frames.count / 2],
                        gaps[gaps.count / 2], results.map(\.dropped).reduce(0, +)))
        }
        let moves = all.map(\.moveMs).sorted()
        let gaps = all.map(\.longestGapMs).sorted()
        let dropped = all.map(\.dropped).reduce(0, +)
        let median = { (xs: [Double]) in xs.isEmpty ? 0 : xs[xs.count / 2] }
        note(String(format: "summary: %d toggles, move median %.0f ms (max %.0f), longest frame gap median %.1f ms (max %.1f), dropped frames total %d, refresh %.0f Hz",
                    all.count, median(moves), moves.last ?? 0, median(gaps), gaps.last ?? 0, dropped, all.first?.refreshHz ?? 0))
        NSApp.terminate(nil)
    }
}

/// Records display-link frames and a column's width while it animates: the sidebar's by default, or whatever
/// `probe` measures (`LyricsSelfTest` passes the inspector column's).
@MainActor
final class FrameRecorder: NSObject {
    struct Result {
        let moveMs: Double
        let longestGapMs: Double
        let dropped: Int
        let frames: Int
        let refreshHz: Double
        /// Every frame interval of the move, in ms; the first runs from the toggle to the first frame.
        let gapsMs: [Double]
        /// The biggest change of the measured width between two frames, in points: a snap shows up here.
        var largestStep: CGFloat = 0
        /// The width when recording stopped.
        var endWidth: CGFloat = 0
        /// CPU time the main thread used from `start()` to `stop()`, in ms.
        var mainThreadMs: Double = 0
        var line: String {
            String(format: "move %.0f ms, %d frames, longest gap %.1f ms, dropped %d; gaps ", moveMs, frames, longestGapMs, dropped)
                + gapsMs.map { String(format: "%.0f", $0) }.joined(separator: " ")
        }
    }

    private weak var window: NSWindow?
    private weak var sidebar: NSView?
    private let probe: (() -> CGFloat)?
    private var link: CADisplayLink?
    private var samples: [(time: CFTimeInterval, width: CGFloat)] = []
    private var interval: CFTimeInterval = 1.0 / 60
    private var cpuAtStart: Double = 0

    /// Counts every frame from `start()` to `stop()` as the move (`TourSelfTest`), not only up to the last width change.
    private let whole: Bool

    init(window: NSWindow, probe: (() -> CGFloat)? = nil, whole: Bool = false) {
        self.window = window
        self.probe = whole ? { 0 } : probe
        self.whole = whole
    }

    func start() {
        guard let view = window?.contentView else { return }
        // Looked up once: walking the view tree every frame would itself cost frames.
        if probe == nil { sidebar = SplitViewTuning.sidebarItem(in: view).flatMap { $0.0.splitView.arrangedSubviews.first } }
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        cpuAtStart = Self.mainThreadCPUms()
        samples = [(CACurrentMediaTime(), width)]
    }

    /// CPU time (user + system) of the calling thread, which is the main thread here, in ms.
    static func mainThreadCPUms() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let port = pthread_mach_thread_np(pthread_self())
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard status == KERN_SUCCESS else { return 0 }
        let user = Double(info.user_time.seconds) * 1000 + Double(info.user_time.microseconds) / 1000
        let system = Double(info.system_time.seconds) * 1000 + Double(info.system_time.microseconds) / 1000
        return user + system
    }

    @objc private func tick(_ link: CADisplayLink) {
        if link.targetTimestamp > link.timestamp { interval = link.targetTimestamp - link.timestamp }
        samples.append((CACurrentMediaTime(), width))
    }

    /// Where the sidebar column ends (0 when hidden), or the probe's width.
    private var width: CGFloat {
        if let probe { return probe() }
        guard let sidebar, !sidebar.isHidden else { return 0 }
        return sidebar.frame.maxX
    }

    func stop() -> Result {
        link?.invalidate()
        link = nil
        let cpu = Self.mainThreadCPUms() - cpuAtStart
        let start = samples.first?.time ?? 0
        // The move runs from the toggle to the last frame whose sidebar width differs from the one before.
        var lastChange = 0
        for i in 1..<max(1, samples.count) where whole || abs(samples[i].width - samples[i - 1].width) > 0.5 { lastChange = i }
        let moving = Array(samples[0...lastChange])
        var longest: CFTimeInterval = 0
        var dropped = 0
        var gaps: [Double] = []
        for i in 1..<max(1, moving.count) {
            let gap = moving[i].time - moving[i - 1].time
            gaps.append(gap * 1000)
            longest = max(longest, gap)
            dropped += max(0, Int((gap / interval).rounded()) - 1)
        }
        var step: CGFloat = 0
        for i in 1..<max(1, samples.count) { step = max(step, abs(samples[i].width - samples[i - 1].width)) }
        return Result(moveMs: (moving.last!.time - start) * 1000, longestGapMs: longest * 1000, dropped: dropped,
                      frames: moving.count - 1, refreshHz: 1 / interval, gapsMs: gaps,
                      largestStep: step, endWidth: samples.last?.width ?? 0, mainThreadMs: cpu)
    }
}
