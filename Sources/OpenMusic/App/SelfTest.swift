import AppKit
import OpenMusicCore
import SwiftUI

// Debug builds only: Release builds have no self-test entry points.
#if DEBUG
/// `OPENMUSIC_MOCK=1 OPENMUSIC_SELFTEST=fullscreen OPENMUSIC_SELFTEST_OUT=<file>`: runs the app normally (not in
/// snapshot mode, so animations and window full screen are real), opens an album, plays it, opens the lyrics
/// panel, then enters and leaves the full-screen player three times through its menu command and Escape.
/// Writes one line per step to the output file, so a crash shows where it happened, then quits.
@MainActor
struct FullScreenSelfTest {
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
        model.select(.home)
        try? await Task.sleep(for: .milliseconds(300))
        model.path = [.album(.youtubeMusic, id: album.providerID, preview: album)]
        try? await Task.sleep(for: .seconds(1))
        if let detail = try? await yt.album(id: album.providerID) {
            model.play(detail.tracks, startAt: 0, from: .init(title: album.title))
        }
        model.toggleInspector(.lyrics)
        try? await Task.sleep(for: .seconds(2))
        note("setup: album \(album.title), playing \(model.player.current?.title ?? "-"), inspector \(String(describing: model.inspector))")

        // Leave the pointer where a person would after clicking the lyrics button: the toolbar's top-right corner.
        // In full screen that is the edge that reveals the hidden toolbar.
        if LaunchEnvironment.current["OPENMUSIC_SELFTEST_POINTER"] == "toolbar", let screen = window.screen {
            let f = window.frame
            let topLeftY = screen.frame.maxY - f.maxY
            CGWarpMouseCursorPosition(CGPoint(x: f.maxX - 60, y: topLeftY + 26))
            note("pointer at toolbar")
        }

        var ok = true
        for cycle in 1...3 {
            note("cycle \(cycle): enter")
            performMenuItem("Full Screen Player")
            try? await Task.sleep(for: .seconds(3))
            let entered = window.styleMask.contains(.fullScreen) && model.isFullScreenPlayerPresented
            note("cycle \(cycle): entered \(entered); escape")
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let esc = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                              charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                    window.sendEvent(esc)
                }
            }
            try? await Task.sleep(for: .seconds(3))
            let left = !window.styleMask.contains(.fullScreen) && !model.isFullScreenPlayerPresented
            note("cycle \(cycle): left \(left)")
            ok = ok && entered && left
        }
        note("full screen with lyrics, 3 cycles, no crash: \(ok ? "PASS" : "FAIL")")
        NSApp.terminate(nil)
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
}
#endif
