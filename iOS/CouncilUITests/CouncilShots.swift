import XCTest

/// Screens that need a finger: each test opens a `-MedleyScreen` state with the demo data, does one gesture and
/// saves the screen to `$COUNCIL_OUT/<name><COUNCIL_SUFFIX>.png`. Run by `scripts/ios-council-shots.sh` with
/// `xcodebuild test-without-building`, which passes `TEST_RUNNER_*` variables in without the prefix.
final class CouncilShots: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var out: String { env["COUNCIL_OUT"] ?? NSTemporaryDirectory() }
    private var suffix: String { env["COUNCIL_SUFFIX"] ?? "" }

    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    private func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-MedleyMock", "demo", "-MedleyScreen", screen]
        if let art = env["COUNCIL_ART"] { app.launchArguments += ["-MedleyDemoArt", art] }
        app.launch()
        sleep(4)
        return app
    }

    private func save(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: "\(out)/\(name)\(suffix).png"))
    }

    /// Home scrolled so shelves pass under the tab bar and the mini player.
    @MainActor
    func testHomeScrolled() {
        let app = launch("home")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)), withVelocity: .slow, thenHoldForDuration: 0.2)
        sleep(2)
        save("home-scrolled")
    }

    /// A long press on the first Quick picks song: its context menu.
    @MainActor
    func testContextMenu() {
        let app = launch("home")
        let title = env["COUNCIL_SONG"] ?? "Billie Jean"
        let text = app.staticTexts[title].firstMatch
        if text.waitForExistence(timeout: 5) {
            text.press(forDuration: 1.3)
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.28)).press(forDuration: 1.3)
        }
        sleep(2)
        save("contextmenu")
    }

    /// Search with a partial query typed: the suggestions list over the keyboard.
    @MainActor
    func testSearchSuggestions() {
        let app = launch("search-recent")
        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap()
            sleep(1)
            field.typeText(env["COUNCIL_QUERY"] ?? "oli")
        }
        sleep(3)
        save("search-suggestions")
    }

    /// The route picker opened from Now Playing.
    @MainActor
    func testAirPlay() {
        let app = launch("nowplaying")
        let button = app.buttons["AirPlay"].firstMatch
        if button.waitForExistence(timeout: 5) { button.tap() }
        sleep(3)
        save("airplay")
    }

    /// The queue mid-drag: the first Up Next song lifted by its reorder handle and held two rows down. The script
    /// takes this one from outside while the finger holds (`$COUNCIL_OUT/.dragging` marks the moment), since the drag
    /// call blocks the test.
    @MainActor
    func testQueueDrag() {
        let app = launch("queue")
        let title = app.staticTexts[env["COUNCIL_QUEUE_SONG"] ?? "begged"].firstMatch
        guard title.waitForExistence(timeout: 5) else { return }
        let origin = app.coordinate(withNormalizedOffset: .zero)
        // The handle sits at the row's trailing edge, level with the title and subtitle.
        let from = origin.withOffset(CGVector(dx: app.frame.width - 50, dy: title.frame.midY + 9))
        let to = from.withOffset(CGVector(dx: 0, dy: 128))
        FileManager.default.createFile(atPath: "\(out)/.dragging", contents: Data())
        from.press(forDuration: 0.4, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 6)
        sleep(1)
    }

    /// A tap on the third Up Next song: it starts playing.
    @MainActor
    func testQueueTap() {
        let app = launch("queue")
        let title = app.staticTexts["less"].firstMatch
        guard title.waitForExistence(timeout: 5) else { return }
        title.tap()
        sleep(2)
        save("queue-tapped")
    }
}
