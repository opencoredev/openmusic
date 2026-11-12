#if DEBUG
import AppKit
import MedleyCore
import OSLog
import SwiftUI

/// `MEDLEY_MOCK=1 MEDLEY_SELFTEST=tour MEDLEY_SELFTEST_OUT=<file>`: frame timing of everyday moves while a song
/// plays, at 1440×900. Each move is recorded with a display link for a fixed time (every frame counts, not just
/// those of one column's motion): the longest gap between frames, the frames dropped and the main thread's CPU
/// time. Moves: the full-screen player in and out, switching sidebar pages and pushing an album and an artist,
/// scrolling Home with a stream of scroll-wheel events, typing a search one letter at a time, and resizing the
/// window step by step. Three runs each; one line per run and a summary per move, then quits.
/// `MEDLEY_SELFTEST_TOUR=scroll,search` runs only those moves. Each move is a Points of Interest signpost.
@MainActor
struct TourSelfTest {
    let model: AppModel
    let output: URL

    private static let signposter = OSSignposter(subsystem: "\(ProductInfo.identifierPrefix).selftest", category: .pointsOfInterest)

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
        if let detail = try? await yt.album(id: album.providerID) {
            model.play(detail.tracks, startAt: 0, from: .init(title: album.title))
        }
        try? await Task.sleep(for: .seconds(1))
        note("setup: playing \(model.player.current?.title ?? "-")")
        let only = ProcessInfo.processInfo.environment["MEDLEY_SELFTEST_TOUR"].map { Set($0.split(separator: ",").map(String.init)) }

        var summary: [String] = []
        /// Runs `action` three times, recording `seconds` after each start; `reset` runs unrecorded between runs.
        func measure(_ name: String, seconds: Double, reset: () async -> Void = {}, _ action: () async -> Void) async {
            guard only?.contains(name) ?? true else { return }
            var results: [FrameRecorder.Result] = []
            for run in 1...3 {
                await reset()
                try? await Task.sleep(for: .milliseconds(800))
                let recorder = FrameRecorder(window: window, whole: true)
                recorder.start()
                Self.signposter.emitEvent("move", "\(name) \(run)")
                let started = CACurrentMediaTime()
                await action()
                let left = seconds - (CACurrentMediaTime() - started)
                if left > 0 { try? await Task.sleep(for: .seconds(left)) }
                let r = recorder.stop()
                results.append(r)
                note(String(format: "%@ %d: %d frames, longest gap %.1f ms, dropped %d, main %.0f ms", name, run, r.frames, r.longestGapMs, r.dropped, r.mainThreadMs))
            }
            let gaps = results.map(\.longestGapMs).sorted()
            summary.append(String(format: "summary %@: longest gap median %.1f ms (max %.1f), dropped %d over %d runs, main median %.0f ms", name,
                                  gaps[gaps.count / 2], gaps.last ?? 0, results.map(\.dropped).reduce(0, +), results.count,
                                  results.map(\.mainThreadMs).sorted()[results.count / 2]))
        }

        // The full-screen player, through the same calls as its buttons (the window goes full screen too).
        await measure("fullscreen-open", seconds: 2.5, reset: {
            if model.isFullScreenPlayerPresented {
                model.setFullScreenPlayerPresented(false)
                try? await Task.sleep(for: .seconds(2.5))
            }
        }) {
            model.setFullScreenPlayerPresented(true)
        }
        await measure("fullscreen-close", seconds: 2.5, reset: {
            if !model.isFullScreenPlayerPresented {
                model.setFullScreenPlayerPresented(true)
                try? await Task.sleep(for: .seconds(2.5))
            }
        }) {
            model.setFullScreenPlayerPresented(false)
        }
        try? await Task.sleep(for: .seconds(1.5))

        // Pages: each switch from Songs, the way a sidebar click or a card click does it.
        let pages: [(String, () -> Void)] = [
            ("page-home", { model.select(.home) }),
            ("page-new", { model.select(.explore) }),
            ("page-album", { model.path = [.album(.youtubeMusic, id: album.providerID, preview: album)] }),
            ("page-artist", { model.path = [.artist(.youtubeMusic, id: artist.providerID, preview: artist)] }),
            ("page-songs", { model.select(.songs) }),
            ("page-playlists", { model.select(.allPlaylists) }),
        ]
        for (name, open) in pages {
            await measure(name, seconds: 1.2, reset: { model.select(name == "page-songs" ? .albums : .songs) }) { open() }
        }

        // Home, scrolled down and back with trackpad-like wheel events (two pages of shelves with artwork).
        await measure("scroll-home", seconds: 2.4, reset: {
            model.select(.home)
            try? await Task.sleep(for: .seconds(1))
            scroll(window, by: 4000)
        }) {
            for _ in 0..<60 {
                scroll(window, by: -40)
                try? await Task.sleep(for: .milliseconds(16))
            }
            for _ in 0..<60 {
                scroll(window, by: 40)
                try? await Task.sleep(for: .milliseconds(16))
            }
        }

        // Typing a search, one letter every 120 ms, as the field's text binding sees it.
        await measure("search-typing", seconds: 2.4, reset: {
            model.searchText = ""
            model.select(.home)
        }) {
            for i in 1..."glass harbor".count {
                model.searchText = String("glass harbor".prefix(i))
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        model.searchText = ""

        // A live-resize-like drag of the window's width, 1440 to 1000 and back, panels closed.
        await measure("resize", seconds: 2.0, reset: {
            model.select(.home)
            model.path = [.album(.youtubeMusic, id: album.providerID, preview: album)]
        }) {
            let widths = Array(stride(from: 1440, through: 1000, by: -22)) + Array(stride(from: 1000, through: 1440, by: 22))
            for w in widths {
                window.requestFrame(NSRect(x: 60, y: 60, width: CGFloat(w), height: 900), display: true)
                try? await Task.sleep(for: .milliseconds(16))
            }
        }

        for line in summary { note(line) }
        NSApp.terminate(nil)
    }

    /// One scroll-wheel event over the middle of the page (positive scrolls down), delivered to the window.
    private func scroll(_ window: NSWindow, by points: Int32) {
        guard let content = window.contentView,
              let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -points, wheel2: 0, wheel3: 0)
        else { return }
        let point = NSPoint(x: content.bounds.width * 0.6, y: content.bounds.height * 0.5)
        let screen = window.convertPoint(toScreen: point)
        // CGEvent locations are top-left based.
        let height = window.screen?.frame.maxY ?? NSScreen.screens.first?.frame.maxY ?? 0
        cg.location = CGPoint(x: screen.x, y: height - screen.y)
        if let event = NSEvent(cgEvent: cg) { window.sendEvent(event) }
    }
}
#endif
