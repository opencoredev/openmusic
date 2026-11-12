import XCTest

/// Reference screenshots of Apple's own Music app in the same simulator, for the council to compare against
/// (`COUNCIL_TESTS=testAppleMusic scripts/ios-council-shots.sh`). No Apple account: it shows what Music shows signed
/// out. Every step is best effort; a step that finds nothing still saves the screen it is on.
final class AppleMusicReference: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var out: String { env["COUNCIL_OUT"] ?? NSTemporaryDirectory() }
    private var suffix: String { env["COUNCIL_SUFFIX"] ?? "" }

    override func setUp() { continueAfterFailure = true }

    private func save(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "\(out)/applemusic-\(name)\(suffix).png"))
    }

    /// Taps through welcome and offer sheets.
    @MainActor
    private func dismissPrompts(_ app: XCUIApplication) {
        for _ in 0..<4 {
            var tapped = false
            for label in ["Not Now", "Continue", "Allow", "OK", "Close", "Dismiss", "No Thanks", "Maybe Later"] {
                let b = app.buttons[label].firstMatch
                if b.exists && b.isHittable { b.tap(); tapped = true; sleep(1) }
            }
            if !tapped { return }
        }
    }

    @MainActor
    private func tab(_ app: XCUIApplication, _ name: String) {
        let b = app.tabBars.buttons[name].firstMatch
        if b.waitForExistence(timeout: 3) { b.tap() } else { app.buttons[name].firstMatch.tap() }
        sleep(3)
    }

    @MainActor
    func testAppleMusic() {
        let app = XCUIApplication(bundleIdentifier: "com.apple.Music")
        app.launch()
        sleep(6)
        dismissPrompts(app)
        sleep(3)
        dismissPrompts(app)
        save("home")
        app.swipeUp()
        sleep(2)
        save("home-scrolled")
        tab(app, "New")
        dismissPrompts(app)
        save("new")
        tab(app, "Library")
        dismissPrompts(app)
        save("library")
        tab(app, "Search")
        dismissPrompts(app)
        save("search")
        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 4) {
            field.tap()
            sleep(1)
            field.typeText("oli")
            sleep(4)
            save("search-suggestions")
            field.typeText("via rodrigo\n")
            sleep(5)
            save("search-results")
            // An album from the results: the first cell whose label mentions "Album".
            let album = app.cells.containing(NSPredicate(format: "label CONTAINS[c] 'Album'")).firstMatch
            if album.waitForExistence(timeout: 4) {
                album.tap()
                sleep(5)
                save("album")
                // Long press on a song: its context menu.
                let song = app.cells.element(boundBy: 2)
                if song.exists {
                    song.press(forDuration: 1.3)
                    sleep(2)
                    save("contextmenu")
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
                    sleep(1)
                    // Play it: a preview plays signed out, or an offer sheet shows.
                    song.tap()
                    sleep(5)
                    save("album-playing")
                    dismissPrompts(app)
                }
            }
        }
        // The mini player, if anything plays: open Now Playing, then lyrics and the queue.
        let mini = app.otherElements["MiniPlayer"].firstMatch
        if mini.exists { mini.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.86)).tap() }
        sleep(4)
        save("nowplaying")
        for (label, name) in [("Lyrics", "lyrics"), ("Playing Next", "queue")] {
            let b = app.buttons[label].firstMatch
            if b.exists { b.tap(); sleep(3); save(name); b.tap(); sleep(1) }
        }
        app.terminate()
    }
}
