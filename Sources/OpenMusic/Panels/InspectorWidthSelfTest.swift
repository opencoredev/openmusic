import AppKit
import OpenMusicCore
import SwiftUI

// Debug builds only: Release builds have no self-test entry points.
#if DEBUG
/// `OPENMUSIC_MOCK=1 OPENMUSIC_SELFTEST=inspectorwidth OPENMUSIC_SELFTEST_OUT=<file>`: checks that the lyrics and
/// queue panel can be widened. At 1440×900 it opens Lyrics, moves the panel's divider the way a drag does
/// (`NSSplitView.setPosition`) to several widths, and records what the panel settles at: wider than the
/// ideal up to the maximum, clamped at the maximum and minimum. Then it repeats the narrow-window cycle that
/// once looped AppKit's Update Constraints (open a panel at 960 pt, which collapses the sidebar, and close
/// it), with the panel left wide. Writes one line per step, then quits.
@MainActor
struct InspectorWidthSelfTest {
    let model: AppModel
    let output: URL

    static let minWidth = InspectorMetrics.minWidth
    static let maxWidth = InspectorMetrics.maxWidth
    static let idealWidth = InspectorMetrics.idealWidth

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
        if let detail = try? await yt.album(id: album.providerID) {
            model.play(detail.tracks, startAt: 0, from: .init(title: album.title))
        }
        model.toggleInspector(.lyrics)
        try? await Task.sleep(for: .seconds(1.5))

        guard let split = Self.splitView(in: window.contentView), split.arrangedSubviews.count >= 2 else {
            note("split view with an inspector column: not found FAIL")
            return NSApp.terminate(nil)
        }
        func panelWidth() -> CGFloat { split.arrangedSubviews.last?.frame.width ?? 0 }
        note("setup: window \(Int(window.frame.width)), columns \(split.arrangedSubviews.map { Int($0.frame.width) }), panel \(Int(panelWidth()))")
        note("setup items: \(SplitViewTuning.describeColumns(in: window))")

        var ok = true
        // Lyrics open at a reading width in a wide window; the queue goes back to the ideal; lyrics widen again.
        for (panel, expected) in [(InspectorPanel.lyrics, InspectorMetrics.lyricsWidth), (.queue, Self.idealWidth), (.lyrics, InspectorMetrics.lyricsWidth)] {
            if model.inspector != panel { model.inspector = panel; try? await Task.sleep(for: .seconds(1.5)) }
            let width = panelWidth()
            let pass = abs(width - expected) <= 2
            ok = ok && pass
            note("\(panel.rawValue) at 1440: panel \(Int(width)), expected \(Int(expected)) \(pass ? "PASS" : "FAIL")")
        }
        // Each target, and the width the panel should settle at.
        let steps: [(target: CGFloat, expected: CGFloat)] = [(400, 400), (520, 520), (640, Self.maxWidth), (240, Self.minWidth), (480, 480)]
        for step in steps {
            let divider = split.arrangedSubviews.count - 2
            split.setPosition(split.bounds.width - step.target - split.dividerThickness, ofDividerAt: divider)
            try? await Task.sleep(for: .milliseconds(800))
            let width = panelWidth()
            let pass = abs(width - step.expected) <= 2
            ok = ok && pass
            note("drag panel to \(Int(step.target)): panel \(Int(width)), expected \(Int(step.expected)) \(pass ? "PASS" : "FAIL"); columns \(split.arrangedSubviews.map { Int($0.frame.width) })")
        }

        // A pointer drag through AppKit's own path: hit-test the divider, then a mouse-down there with the
        // drag and mouse-up already queued, so NSSplitView's tracking loop reads them as a person's drag.
        split.setPosition(split.bounds.width - Self.idealWidth - split.dividerThickness, ofDividerAt: split.arrangedSubviews.count - 2)
        try? await Task.sleep(for: .milliseconds(800))
        for dx in [-160, 80] as [CGFloat] {
            let before = panelWidth()
            guard let panel = split.arrangedSubviews.last else { break }
            let edge = panel.convert(panel.bounds, to: nil)
            let start = NSPoint(x: edge.minX - split.dividerThickness / 2, y: edge.midY)
            let hit = window.contentView?.hitTest(window.contentView?.convert(start, from: nil) ?? start)
            note("divider at x \(Int(start.x)): hit \(hit.map { String(describing: type(of: $0)) } ?? "nothing")")
            drag(in: window, from: start, by: dx)
            try? await Task.sleep(for: .milliseconds(800))
            let expected = min(Self.maxWidth, max(Self.minWidth, before - dx))
            let width = panelWidth()
            let pass = abs(width - expected) <= 3
            ok = ok && pass
            note("pointer drag \(Int(dx)) pt: panel \(Int(before)) -> \(Int(width)), expected \(Int(expected)) \(pass ? "PASS" : "FAIL")")
            if dx < 0 { capture(window, "inspectorwidth-dragged.png") }
        }

        // The narrow-window cycle, with the panel left wide.
        for cycle in 1...3 {
            model.inspector = nil
            try? await Task.sleep(for: .seconds(1))
            window.requestFrame(NSRect(x: 60, y: 60, width: 960, height: 620), display: true)
            try? await Task.sleep(for: .milliseconds(700))
            model.toggleInspector(cycle.isMultiple(of: 2) ? .queue : .lyrics)
            try? await Task.sleep(for: .seconds(1.2))
            // Lyrics were widened at 1440 (and dragged wider): at 960 either panel opens at the ideal 310, never at
            // the width AppKit kept (merge review: lyrics reopened at 960 stayed at 420).
            let opened = panelWidth()
            let openedPass = abs(opened - Self.idealWidth) <= 2
            ok = ok && openedPass
            note("narrow cycle \(cycle): opened \(model.inspector?.rawValue ?? "nothing"), sidebar \(model.columnVisibility == .detailOnly ? "collapsed" : "shown"), window \(Int(window.frame.width)), panel \(Int(opened)), expected \(Int(Self.idealWidth)) \(openedPass ? "PASS" : "FAIL")")
            model.inspector = nil
            try? await Task.sleep(for: .seconds(1.2))
            note("narrow cycle \(cycle): closed, sidebar \(model.columnVisibility == .all ? "back" : "hidden"), window \(Int(window.frame.width))")
        }
        // Lyrics open at 420 through the column's ideal width (`AppModel.sizeInspector`). The sidebar is hidden and
        // shown under that ideal, first with lyrics open at 1440, then with the panel closed at 960; then the queue
        // opens at 960, which collapses the sidebar and sets the ideal back to 310 in the same update. A wider ideal
        // once looped Update Constraints at 960 until AppKit aborted.
        // Not covered: resizing the window while a panel and the sidebar both show. Shrinking it from 1440 to 1100
        // that way aborts in Update Constraints with the queue at 310 too, on builds before the wide ideal.
        model.inspector = nil
        window.requestFrame(NSRect(x: 60, y: 60, width: 1440, height: 900), display: true)
        try? await Task.sleep(for: .seconds(1.2))
        model.toggleInspector(.lyrics)
        try? await Task.sleep(for: .seconds(1.2))
        let wide = panelWidth()
        let widePass = abs(wide - InspectorMetrics.lyricsWidth) <= 2
        ok = ok && widePass
        note("wide lyrics: panel \(Int(wide)), expected \(Int(InspectorMetrics.lyricsWidth)) \(widePass ? "PASS" : "FAIL")")
        func toggleSidebar(_ label: String, _ times: Int) async {
            for step in 1...times {
                SplitViewTuning.toggleSidebar(in: window)
                try? await Task.sleep(for: .seconds(1))
                note("\(label) sidebar toggle \(step): window \(Int(window.frame.width)), columns \(split.arrangedSubviews.map { Int($0.frame.width) })")
            }
        }
        await toggleSidebar("1440 with lyrics", 4)
        model.inspector = nil
        try? await Task.sleep(for: .seconds(1.2))
        window.requestFrame(NSRect(x: 60, y: 60, width: 960, height: 620), display: true)
        try? await Task.sleep(for: .seconds(1))
        await toggleSidebar("960 closed", 2)
        model.toggleInspector(.queue)
        try? await Task.sleep(for: .seconds(1.2))
        let queue = panelWidth()
        let queuePass = abs(queue - Self.idealWidth) <= 2
        ok = ok && queuePass
        note("queue opened at 960: panel \(Int(queue)), expected \(Int(Self.idealWidth)) \(queuePass ? "PASS" : "FAIL"); sidebar \(model.columnVisibility == .detailOnly ? "collapsed" : "shown"), window \(Int(window.frame.width))")
        model.inspector = nil
        try? await Task.sleep(for: .seconds(1.2))
        let kept = abs(window.frame.width - 960) <= 1
        ok = ok && kept
        note("queue closed at 960: sidebar \(model.columnVisibility == .all ? "back" : "hidden"), window \(Int(window.frame.width)) \(kept ? "PASS" : "FAIL")")
        note("inspector widens to \(Int(Self.maxWidth)), clamps, and survives the narrow cycle: \(ok ? "PASS" : "FAIL")")
        NSApp.terminate(nil)
    }

    /// An offscreen image of the window next to the log (glass draws flat in these; widths are right).
    private func capture(_ window: NSWindow, _ name: String) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: output.deletingLastPathComponent().appendingPathComponent(name))
    }

    /// Queues the drag and mouse-up, then delivers the mouse-down; the view under it runs its tracking loop.
    private func drag(in window: NSWindow, from start: NSPoint, by dx: CGFloat) {
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: type == .leftMouseUp ? 0 : 1)
        }
        let steps = 8
        for i in 1...steps {
            if let e = event(.leftMouseDragged, NSPoint(x: start.x + dx * CGFloat(i) / CGFloat(steps), y: start.y)) {
                NSApp.postEvent(e, atStart: false)
            }
        }
        if let up = event(.leftMouseUp, NSPoint(x: start.x + dx, y: start.y)) { NSApp.postEvent(up, atStart: false) }
        if let down = event(.leftMouseDown, start) { window.sendEvent(down) }
    }

    /// The split view holding the inspector column: the deepest one with an arranged subview on the right.
    private static func splitView(in view: NSView?) -> NSSplitView? {
        guard let view else { return nil }
        for sub in view.subviews {
            if let found = splitView(in: sub) { return found }
        }
        if let split = view as? NSSplitView, split.isVertical, split.arrangedSubviews.count >= 2 { return split }
        return nil
    }
}
#endif
