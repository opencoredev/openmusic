import AppKit
import OpenMusicCore
import SwiftUI

// Debug builds only: Release builds have no self-test entry points.
#if DEBUG
/// `OPENMUSIC_MOCK=1 OPENMUSIC_SELFTEST=hover OPENMUSIC_SELFTEST_OUT=<dir>`: checks the states that only appear
/// on hover. Plays an album, moves the pointer onto the floating player's timeline and over the mini player's
/// artwork, and writes a PNG of each window with the pointer away and with it resting there, so the
/// timeline thumb and the mini player's timeline and volume can be compared. Then quits.
@MainActor
struct HoverSelfTest {
    let model: AppModel
    let output: URL

    func run() async {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var log: [String] = []
        func note(_ line: String) {
            log.append(line)
            try? log.joined(separator: "\n").write(to: output.appendingPathComponent("hover.txt"), atomically: true, encoding: .utf8)
        }
        while model.mainWindow == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let window = model.mainWindow, let yt = model.provider(.youtubeMusic) as? MockProvider else { return note("setup: FAIL") }
        window.requestFrame(NSRect(x: 60, y: 60, width: 1440, height: 900), display: true)
        let album = yt.catalog.albums[0]
        if let detail = try? await yt.album(id: album.providerID) {
            model.play(detail.tracks, startAt: 0, from: .init(title: album.title))
        }
        try? await Task.sleep(for: .seconds(2))

        // The middle of the player's timeline (top-left window coordinates from its probe), else about where
        // the capsule puts it.
        let frame = window.frame
        let contentHeight = window.contentView?.bounds.height ?? frame.height
        let timeline = DebugProbes.windowFrame("player-timeline")
        let target = timeline.map { CGPoint(x: frame.minX + $0.midX, y: frame.minY + contentHeight - $0.midY) }
            ?? CGPoint(x: frame.midX + 110, y: frame.minY + 30)
        note("bar: timeline probe \(timeline.map { NSStringFromRect($0) } ?? "missing")")
        move(to: CGPoint(x: frame.midX - 200, y: frame.minY + 300), in: window)
        try? await Task.sleep(for: .milliseconds(600))
        capture(window, "bar-rest.png")
        move(to: target, in: window)
        try? await Task.sleep(for: .milliseconds(600))
        capture(window, "bar-hover.png")
        note("bar: captured rest and hover at time \(model.player.currentTime.clock)")

        performMenuItem("Mini Player")
        try? await Task.sleep(for: .seconds(1.5))
        guard let mini = MiniPlayerWindow.window else { return note("mini: window not found: FAIL") }
        note("mini: key \(mini.isKeyWindow), visible \(mini.isVisible), frame \(mini.frame)")
        move(to: CGPoint(x: frame.midX - 200, y: frame.minY + 300), in: window)
        try? await Task.sleep(for: .milliseconds(600))
        capture(mini, "mini-rest.png")
        let m = mini.frame
        let areas = move(to: CGPoint(x: m.midX, y: m.maxY - 150), in: mini)
        try? await Task.sleep(for: .milliseconds(800))
        capture(mini, "mini-hover.png")
        note("mini: captured rest and hover (\(areas) tracking areas under the pointer)")
        mini.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(300))
        let again = move(to: CGPoint(x: m.midX, y: m.maxY - 160), in: mini)
        try? await Task.sleep(for: .milliseconds(800))
        capture(mini, "mini-hover-key.png")
        note("mini: key \(mini.isKeyWindow), hover again (\(again) areas)")
        NSApp.terminate(nil)
    }

    /// Moves the real pointer (screen coordinates, bottom-left origin) and tells the window, so tracking
    /// areas update as they would for a person moving the mouse.
    @discardableResult
    private func move(to point: CGPoint, in window: NSWindow) -> Int {
        guard let screen = window.screen ?? NSScreen.main else { return 0 }
        let quartz = CGPoint(x: point.x, y: screen.frame.maxY - point.y)
        CGWarpMouseCursorPosition(quartz)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: quartz, mouseButton: .left)?.post(tap: .cghidEventTap)
        let local = window.convertPoint(fromScreen: point)
        let now = ProcessInfo.processInfo.systemUptime
        // A warped cursor posts no events, so deliver what AppKit would: mouseEntered to every tracking area
        // under the point (mouseExited to the rest), then a mouseMoved.
        guard let root = window.contentView?.superview ?? window.contentView else { return 0 }
        var views: [NSView] = [root]
        var entered = 0
        while let view = views.popLast() {
            views.append(contentsOf: view.subviews)
            for area in view.trackingAreas {
                guard let owner = area.owner as? NSResponder else { continue }
                let rect = view.convert(area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect, to: nil)
                let inside = rect.contains(local)
                let type: NSEvent.EventType = inside ? .mouseEntered : .mouseExited
                guard let event = NSEvent.enterExitEvent(with: type, location: local, modifierFlags: [], timestamp: now, windowNumber: window.windowNumber,
                                                         context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) else { continue }
                if inside { owner.mouseEntered(with: event); entered += 1 } else { owner.mouseExited(with: event) }
                if inside, let moved = NSEvent.mouseEvent(with: .mouseMoved, location: local, modifierFlags: [], timestamp: now,
                                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                    owner.mouseMoved(with: moved)
                }
            }
        }
        return entered
    }

    private func capture(_ window: NSWindow, _ name: String) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name))
    }

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
}
#endif
