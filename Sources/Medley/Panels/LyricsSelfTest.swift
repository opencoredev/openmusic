#if DEBUG
import AppKit
import MedleyCore
import OSLog
import SwiftUI

/// `MEDLEY_MOCK=1 MEDLEY_SELFTEST=lyrics MEDLEY_SELFTEST_OUT=<file>`: frame timing of opening and closing the
/// lyrics panel, with Playing Next as the baseline. At 1440×900 (lyrics widen the panel there) and 1200×900
/// it plays an album and toggles each scenario six times (three opens, three closes):
/// - `queue`: Playing Next.
/// - `lyrics`: the sample song's synced lyrics (about 24 lines), already loaded.
/// - `lyrics-long`: 80 synced lines, the length of a real song's lyrics, already loaded.
/// - `lyrics-load`: not loaded yet; the fetch takes 300 ms, so the lines arrive while the panel opens.
/// A display link records every frame for two seconds after each toggle, with the panel column's width:
/// how long the panel moves (first to last width change), the longest gap between frames, the frames dropped,
/// the biggest one-frame width change (a snap rather than an animation), and the main thread's CPU time.
/// Writes one line per toggle and a summary per scenario, then quits.
@MainActor
struct LyricsSelfTest {
    let model: AppModel
    let output: URL

    private enum Scenario: String, CaseIterable {
        case queue, lyrics, lyricsLong = "lyrics-long", lyricsLoad = "lyrics-load"
        var panel: InspectorPanel { self == .queue ? .queue : .lyrics }
    }

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

        // An album song with synced lyrics.
        let album = yt.catalog.albums[0]
        guard let detail = try? await yt.album(id: album.providerID),
              let start = detail.tracks.firstIndex(where: { yt.catalog.lyrics(for: $0)?.isSynced == true }),
              let short = yt.catalog.lyrics(for: detail.tracks[start])
        else { return note("setup: no song with synced lyrics FAIL") }
        model.select(.home)
        model.path = [.album(.youtubeMusic, id: album.providerID, preview: album)]
        model.play(detail.tracks, startAt: start, from: .init(title: album.title))
        try? await Task.sleep(for: .seconds(1))
        guard let track = model.player.current else { return note("setup: nothing playing FAIL") }
        let long = Lyrics(lines: (0..<80).map { i in LyricLine(time: 2 + Double(i) * 2.6, text: short.lines[i % short.lines.count].text) },
                          source: short.source)

        // Open the panel once to find its split view, then measure from a settled, closed state.
        model.inspector = .queue
        try? await Task.sleep(for: .seconds(1.5))
        guard let split = SplitViewTuning.inspectorSplitView(in: window.contentView) else { return note("setup: inspector split view FAIL") }
        let openColumns = split.arrangedSubviews.map { "\(Int($0.frame.width))\($0.isHidden ? "h" : "")" }
        model.inspector = nil
        try? await Task.sleep(for: .seconds(1.5))
        let closedColumns = split.arrangedSubviews.map { "\(Int($0.frame.width))\($0.isHidden ? "h" : "")" }
        note("setup: playing \(track.title), \(short.lines.count) lines; columns open \(openColumns), closed \(closedColumns)")
        let panelWidth: () -> CGFloat = { [weak split] in
            guard let split, split.arrangedSubviews.count >= 2, let panel = split.arrangedSubviews.last, !panel.isHidden else { return 0 }
            return panel.frame.width
        }

        var summary: [String] = []
        var refresh: Double = 0
        // Two captures 300 ms apart while playing, next to the log: the timeline's fill and the playing row's bars
        // should differ between them (both are animated by Core Animation, outside these measurements).
        capture(window, "lyrics-motion-0.png")
        try? await Task.sleep(for: .milliseconds(300))
        capture(window, "lyrics-motion-1.png")
        // `MEDLEY_SELFTEST_LYRICS_STRESS=<n>`: n times, open and close lyrics at 1440 (where they open wide), then
        // shrink the window to 1200 and 960 with the panel closed. Writes a line per step, so an abort shows where.
        if let n = Int(ProcessInfo.processInfo.environment["MEDLEY_SELFTEST_LYRICS_STRESS"] ?? "") {
            for round in 1...max(1, n) {
                window.requestFrame(NSRect(x: 60, y: 60, width: 1440, height: 900), display: true)
                try? await Task.sleep(for: .seconds(1))
                model.toggleInspector(.lyrics)
                try? await Task.sleep(for: .seconds(1.2))
                let open = panelWidth()
                model.inspector = nil
                try? await Task.sleep(for: .seconds(1.2))
                note("stress \(round): lyrics opened at \(Int(open)), closed; shrinking")
                for width in [1200, 960] as [CGFloat] {
                    window.requestFrame(NSRect(x: 60, y: 60, width: width, height: 900), display: true)
                    try? await Task.sleep(for: .milliseconds(700))
                    note("stress \(round): window \(Int(window.frame.width))")
                }
            }
            note("stress: \(n) rounds, no abort")
            return NSApp.terminate(nil)
        }
        // What playback costs the main thread with nothing moving: the album page alone, then with each panel open.
        model.setCachedLyrics(long, for: track)
        for panel in [nil, InspectorPanel.queue, .lyrics] {
            model.inspector = panel
            try? await Task.sleep(for: .seconds(1.5))
            var mains: [Double] = []
            for _ in 1...3 {
                let recorder = FrameRecorder(window: window, probe: panelWidth)
                recorder.start()
                try? await Task.sleep(for: .seconds(2))
                mains.append(recorder.stop().mainThreadMs)
            }
            summary.append(String(format: "idle %@ while playing: main %@ ms per 2 s", panel?.rawValue ?? "no panel",
                                  mains.map { String(format: "%.0f", $0) }.joined(separator: ", ")))
        }
        model.inspector = nil
        model.player.pause()
        try? await Task.sleep(for: .seconds(1.5))
        var paused: [Double] = []
        for _ in 1...3 {
            let recorder = FrameRecorder(window: window, probe: panelWidth)
            recorder.start()
            try? await Task.sleep(for: .seconds(2))
            paused.append(recorder.stop().mainThreadMs)
        }
        summary.append("idle no panel while paused: main \(paused.map { String(format: "%.0f", $0) }.joined(separator: ", ")) ms per 2 s")
        model.player.resume()
        try? await Task.sleep(for: .seconds(1.5))
        // `MEDLEY_SELFTEST_LYRICS=1200:queue,1440:lyrics` runs only those, for profiling one case.
        let only = ProcessInfo.processInfo.environment["MEDLEY_SELFTEST_LYRICS"].map { Set($0.split(separator: ",").map(String.init)) }
        if ProcessInfo.processInfo.environment["MEDLEY_SELFTEST_IDLE_ONLY"] == "1" {
            for line in summary { note(line) }
            return NSApp.terminate(nil)
        }
        for width in [1440, 1200] as [CGFloat] {
            window.requestFrame(NSRect(x: 60, y: 60, width: width, height: 900), display: true)
            try? await Task.sleep(for: .seconds(1.5))
            for scenario in Scenario.allCases where only?.contains("\(Int(width)):\(scenario.rawValue)") ?? true {
                switch scenario {
                case .queue, .lyricsLoad: break
                case .lyrics: model.setCachedLyrics(short, for: track)
                case .lyricsLong: model.setCachedLyrics(long, for: track)
                }
                var results: [(open: Bool, result: FrameRecorder.Result)] = []
                for cycle in 1...6 {
                    let opening = model.inspector == nil
                    if scenario == .lyricsLoad, opening {
                        model.setCachedLyrics(nil, for: track)
                        yt.latency = .milliseconds(300)
                    }
                    let recorder = FrameRecorder(window: window, probe: panelWidth)
                    recorder.start()
                    // A point of interest per toggle, so a trace (`xctrace`, Time Profiler) can be cut to each move.
                    Self.signposter.emitEvent("toggle", "\(Int(width)) \(scenario.rawValue) \(cycle)")
                    model.toggleInspector(scenario.panel)
                    try? await Task.sleep(for: .seconds(2))
                    let r = recorder.stop()
                    yt.latency = .zero
                    if width == 1440, cycle == 1, scenario == .lyricsLong { capture(window, "lyrics-open-1440.png") }
                    results.append((opening, r))
                    refresh = r.refreshHz
                    note(String(format: "%d %@ %d %@: move %.0f ms, %d frames, longest gap %.1f ms, dropped %d, largest step %.0f pt, panel %.0f, main %.0f ms",
                                Int(width), scenario.rawValue, cycle, opening ? "open" : "close", r.moveMs, r.frames, r.longestGapMs, r.dropped,
                                r.largestStep, r.endWidth, r.mainThreadMs))
                    try? await Task.sleep(for: .milliseconds(400))
                }
                if model.inspector != nil { model.inspector = nil; try? await Task.sleep(for: .seconds(1.5)) }
                for opening in [true, false] {
                    let rs = results.filter { $0.open == opening }.map(\.result)
                    let median = { (xs: [Double]) in xs.sorted()[xs.count / 2] }
                    summary.append(String(format: "summary %d %@ %@: move median %.0f ms, longest gap median %.1f ms (max %.1f), dropped %d, largest step max %.0f pt, main median %.0f ms",
                                          Int(width), scenario.rawValue, opening ? "open" : "close", median(rs.map(\.moveMs)), median(rs.map(\.longestGapMs)),
                                          rs.map(\.longestGapMs).max() ?? 0, rs.map(\.dropped).reduce(0, +), rs.map(\.largestStep).max() ?? 0,
                                          median(rs.map(\.mainThreadMs))))
                }
            }
        }
        for line in summary { note(line) }
        note(String(format: "refresh %.0f Hz", refresh))
        NSApp.terminate(nil)
    }

    private static let signposter = OSSignposter(subsystem: "\(ProductInfo.identifierPrefix).selftest", category: .pointsOfInterest)

    private func capture(_ window: NSWindow, _ name: String) {
        guard let image = WindowCapture.image(of: window) else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
            .write(to: output.deletingLastPathComponent().appendingPathComponent(name))
    }
}
#endif
