import XCTest

/// The first-run flow as VoiceOver reads it, on a fresh install: every button, link and text field on each step has
/// a label, and at the largest accessibility text size nothing runs off the screen's sides. XCUITest reads the same
/// accessibility tree VoiceOver does. Run by `scripts/onboarding-shots-apple.sh` (fresh simulator); writes what it
/// found to `$COUNCIL_OUT/onboarding-ax<COUNCIL_SUFFIX>.txt`.
final class OnboardingAccessibility: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var report: [String] = []

    override func setUp() {
        continueAfterFailure = true
    }

    override func tearDown() {
        let out = env["COUNCIL_OUT"] ?? NSTemporaryDirectory()
        try? report.joined(separator: "\n").appending("\n")
            .write(toFile: "\(out)/onboarding-ax\(env["COUNCIL_SUFFIX"] ?? "").txt", atomically: true, encoding: .utf8)
    }

    /// Default text size, then the largest accessibility size (the flow shown again with `-firstRunFinished NO`).
    @MainActor
    func testEveryStepIsLabeled() {
        walk(extraArguments: [], name: "default")
        walk(extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"], name: "AX5")
    }

    @MainActor
    private func walk(extraArguments: [String], name: String) {
        let app = XCUIApplication()
        app.launchArguments = ["-firstRunFinished", "NO", "-didShowAccountWelcome", "NO", "-didOnboard", "NO"] + extraArguments
        app.launch()
        let getStarted = app.buttons["Get Started"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 20), "\(name): Welcome shows Get Started")
        audit(app, step: "\(name) Welcome")
        getStarted.tap()

        let without = app.buttons["Use without an account"]
        XCTAssertTrue(without.waitForExistence(timeout: 8), "\(name): Your music shows Use without an account")
        audit(app, step: "\(name) Your music")
        scrollTo(without, in: app)
        without.tap()
        let next = app.buttons["Continue"]
        scrollTo(next, in: app)
        XCTAssertTrue(next.isEnabled, "\(name): Continue is enabled after Use without an account")
        next.tap()

        let server = app.buttons["Use your own server"]
        XCTAssertTrue(server.waitForExistence(timeout: 8), "\(name): Sync shows Use your own server")
        audit(app, step: "\(name) Sync")
        scrollTo(server, in: app)
        server.tap()
        let guide = app.buttons["Set up an OpenMusic server"]
        XCTAssertTrue(guide.waitForExistence(timeout: 8), "\(name): the server step shows its guide link")
        audit(app, step: "\(name) Use your own server")
        scrollTo(guide, in: app)
        guide.tap()
        sleep(1)
        audit(app, step: "\(name) Server guide")
        app.buttons["Done"].firstMatch.tap()
        sleep(1)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let notNow = app.buttons["Not Now"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 8), "\(name): Sync shows Not Now")
        notNow.tap()
        XCTAssertFalse(getStarted.waitForExistence(timeout: 3), "\(name): Not Now closes the flow")
        app.terminate()
    }

    /// Every button, link and text field VoiceOver can reach has a label, and none sticks out of the screen sideways.
    @MainActor
    private func audit(_ app: XCUIApplication, step: String) {
        sleep(1)
        let screen = app.windows.firstMatch.frame
        var count = 0
        for type in [XCUIElement.ElementType.button, .link, .textField] {
            // Only what is on screen and reachable: Home is in the tree under the full-screen flow, with its own carousels
            // running past the screen's edge on purpose.
            for element in app.descendants(matching: type).allElementsBoundByIndex where element.exists && !element.frame.isEmpty && element.isHittable {
                count += 1
                let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
                report.append("\(step): \(type == .textField ? "field" : type == .link ? "link" : "button") \"\(label)\"")
                XCTAssertFalse(label.isEmpty, "\(step): a \(type) without a label at \(element.frame)")
                XCTAssertTrue(element.frame.minX >= screen.minX - 1 && element.frame.maxX <= screen.maxX + 1,
                              "\(step): \"\(label)\" runs off the screen (\(element.frame))")
            }
        }
        for text in app.staticTexts.allElementsBoundByIndex where text.exists && !text.frame.isEmpty && text.isHittable {
            XCTAssertTrue(text.frame.minX >= screen.minX - 1 && text.frame.maxX <= screen.maxX + 1,
                          "\(step): text \"\(text.label.prefix(40))\" runs off the screen (\(text.frame))")
        }
        report.append("\(step): \(count) controls")
        XCTAssertGreaterThan(count, 0, "\(step): found no controls")
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        var tries = 0
        while !element.isHittable, tries < 8 {
            app.swipeUp()
            tries += 1
        }
    }
}
