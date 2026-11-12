import AppKit
import OpenMusicCore
import SwiftUI

// Debug builds only: Release builds have no self-test entry points.
#if DEBUG
/// `OPENMUSIC_MOCK=1 OPENMUSIC_SELFTEST=inspector OPENMUSIC_SELFTEST_OUT=<file>`: runs the app normally at 960×620,
/// plays an album, then opens and closes the queue and lyrics panels four times, then resizes across the floating player's tiers. In a narrow window
/// opening a panel collapses the sidebar and closing it brings the sidebar back; that pair of split-view
/// changes once looped AppKit's Update Constraints until it aborted. Writes one line per step, so a crash
/// shows where it happened, then quits.
@MainActor
struct InspectorSelfTest {
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
        window.requestFrame(NSRect(x: 60, y: 60, width: 960, height: 620), display: true)
        try? await Task.sleep(for: .seconds(1.5))

        let album = yt.catalog.albums[0]
        if let detail = try? await yt.album(id: album.providerID) {
            model.play(detail.tracks, startAt: 0, from: .init(title: album.title))
        }
        try? await Task.sleep(for: .seconds(1))
        note("setup: window \(Int(window.frame.width))x\(Int(window.frame.height)), playing \(model.player.current?.title ?? "-")")

        var ok = true
        for cycle in 1...4 {
            let panel: InspectorPanel = cycle.isMultiple(of: 2) ? .lyrics : .queue
            // Start each cycle at 960, so every cycle collapses the sidebar.
            window.requestFrame(NSRect(x: 60, y: 60, width: 960, height: 620), display: true)
            try? await Task.sleep(for: .milliseconds(700))
            model.toggleInspector(panel)
            try? await Task.sleep(for: .seconds(1.2))
            let collapsed = model.columnVisibility == .detailOnly
            note("cycle \(cycle): opened \(panel.rawValue), sidebar collapsed \(collapsed), window \(Int(window.frame.width))")
            model.inspector = nil
            // Bringing the sidebar back must not widen the window, not even for a frame (it once grew
            // 960 → 1181 and stayed): sample the width every 20 ms while the sidebar comes back.
            var widths: [Int] = []
            for _ in 0..<50 {
                try? await Task.sleep(for: .milliseconds(20))
                widths.append(Int(window.frame.width))
            }
            let restored = model.columnVisibility == .all
            let kept = widths.allSatisfy { abs($0 - 960) <= 1 }
            note("cycle \(cycle): closed, sidebar back \(restored), window \(Int(window.frame.width)), widest \(widths.max() ?? 0), width kept: \(kept ? "PASS" : "FAIL")")
            ok = ok && collapsed && restored && kept
        }
        // Resize across the floating player's tiers (its pane passes about 800, 650 and 545 pt). The panels stay
        // closed; `OPENMUSIC_SELFTEST=resize` resizes with the sidebar and a panel both open.
        for width in [880, 1000, 1180, 940, 900, 1440] {
            note("resizing to \(width), sidebar \(model.columnVisibility == .all ? "shown" : "hidden")")
            window.requestFrame(NSRect(x: 60, y: 60, width: CGFloat(width), height: 620), display: true)
            try? await Task.sleep(for: .milliseconds(700))
            note("resize \(width): window \(Int(window.frame.width)), windowWidth \(Int(model.windowWidth))")
        }
        note("inspector open/close at 960 and resize, no crash: \(ok ? "PASS" : "FAIL")")
        NSApp.terminate(nil)
    }
}
#endif
