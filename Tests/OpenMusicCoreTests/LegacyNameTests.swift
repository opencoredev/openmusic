import Foundation
import Testing
@testable import OpenMusicCore

/// Names from before the rename that older scripts, command lines and saved files still use.
@Suite struct LegacyNameTests {
    @Test func anOpenMusicVariableFallsBackToItsMedleySpelling() {
        let env = LaunchEnvironment.withLegacyNames(["MEDLEY_MOCK": "1", "OPENMUSIC_DEMO_ART": "new", "MEDLEY_DEMO_ART": "old", "HOME": "/h"])
        #expect(env["OPENMUSIC_MOCK"] == "1")
        #expect(env["OPENMUSIC_DEMO_ART"] == "new")
        #expect(env["HOME"] == "/h")
        #expect(env["OPENMUSIC_HOME"] == nil)
    }

    @Test func anOpenMusicArgumentFallsBackToItsMedleySpelling() {
        #expect(LaunchEnvironment.argument("Mock", in: ["app", "-MedleyMock", "demo"]) == "demo")
        #expect(LaunchEnvironment.argument("Mock", in: ["app", "-MedleyMock", "YES", "-OpenMusicMock", "demo"]) == "demo")
        #expect(LaunchEnvironment.argument("Screen", in: ["app", "-OpenMusicScreen"]) == nil)
        #expect(LaunchEnvironment.argument("Screen", in: ["app"]) == nil)
    }

    @Test func mockArtworkSavedUnderTheOldSchemeStillDraws() throws {
        let old = try #require(URL(string: "medley-mock://art/yt-al0"))
        let current = try #require(MockArtwork.url("art", "yt-al0"))
        #expect(MockArtwork.isMock(old))
        #expect(MockArtwork.isMock(current))
        #expect(!MockArtwork.isMock(try #require(URL(string: "https://example.com/art.jpg"))))
        #expect(MockArtwork.render(old, pixels: 16) != nil)
    }
}
