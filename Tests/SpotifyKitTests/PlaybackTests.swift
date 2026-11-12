import Foundation
import OpenMusicCore
import Testing
@testable import SpotifyKit

/// End-of-track detection for the Spotify.app and Connect routes, without Spotify.
@Suite struct EndOfTrackDetectorTests {
    let ours = "spotify:track:ours"
    let next = "spotify:track:next"

    func s(_ state: RemotePlayerState, _ uri: String?, _ position: TimeInterval, at time: TimeInterval, duration: TimeInterval? = 200) -> RemoteSample {
        RemoteSample(state: state, trackURI: uri, position: position, duration: duration, timestamp: time)
    }

    @Test func waitsUntilOurTrackShowsUp() {
        var d = EndOfTrackDetector(expectedURI: ours, expectedDuration: 200)
        #expect(d.ingest(s(.playing, "spotify:track:previous", 150, at: 0, duration: 300)) == .waiting)
        #expect(d.ingest(s(.playing, ours, 0.3, at: 1)) == .playing)
        #expect(d.hasStarted)
    }

    @Test func playsThroughThenSpotifyMovesOn() {
        var d = EndOfTrackDetector(expectedURI: ours, expectedDuration: 200)
        #expect(d.ingest(s(.playing, ours, 10, at: 0)) == .playing)
        #expect(d.ingest(s(.playing, ours, 198.8, at: 188.8)) == .playing)
        // Next poll: Spotify autoplayed its next track.
        #expect(d.ingest(s(.playing, next, 0.4, at: 189.8, duration: 240)) == .finished)
    }

    @Test func endDetectedEvenWithSlowConnectPolling() {
        var d = EndOfTrackDetector(expectedURI: ours, expectedDuration: 200)
        _ = d.ingest(s(.playing, ours, 190, at: 0))
        // 5 s later the projected position is 195 of 200: not near enough yet for a mid-track change…
        #expect(d.ingest(s(.playing, ours, 195, at: 5)) == .playing)
        // …but 4.5 s later we're projected past the end, so a new track means ours finished.
        #expect(d.ingest(s(.playing, next, 3, at: 9.5, duration: 180)) == .finished)
    }

    @Test func userPickedSomethingElseMidTrack() {
        var d = EndOfTrackDetector(expectedURI: ours, expectedDuration: 200)
        _ = d.ingest(s(.playing, ours, 50, at: 0))
        #expect(d.ingest(s(.playing, next, 1, at: 1, duration: 180)) == .replaced)
    }

    @Test func spotifyStopsAtEndOfContext() {
        var d = EndOfTrackDetector(expectedURI: ours, expectedDuration: 200)
        _ = d.ingest(s(.playing, ours, 199.2, at: 0))
        // Spotify resets to 0 and pauses on the same track when there's nothing after it.
        #expect(d.ingest(s(.paused, ours, 0, at: 1)) == .finished)
    }

    @Test func stoppedAtEnd() {
        var d = EndOfTrackDetector(expectedURI: ours, expectedDuration: 200)
        _ = d.ingest(s(.playing, ours, 199, at: 0))
        #expect(d.ingest(s(.stopped, nil, 0, at: 1, duration: nil)) == .finished)
    }

    @Test func pausedMidTrackIsNotTheEnd() {
        var d = EndOfTrackDetector(expectedURI: ours, expectedDuration: 200)
        _ = d.ingest(s(.playing, ours, 80, at: 0))
        #expect(d.ingest(s(.paused, ours, 81, at: 1)) == .paused)
        var e = EndOfTrackDetector(expectedURI: ours, expectedDuration: 200)
        _ = e.ingest(s(.playing, ours, 80, at: 0))
        #expect(e.ingest(s(.stopped, ours, 0, at: 1)) == .paused)
    }

    @Test func pausedJustBeforeTheEndIsStillAPause() {
        var d = EndOfTrackDetector(expectedURI: ours, expectedDuration: 200)
        _ = d.ingest(s(.playing, ours, 198, at: 0))
        #expect(d.ingest(s(.paused, ours, 199.4, at: 1.4)) == .paused)
    }

    @Test func repeatOneLoopCountsAsFinished() {
        var d = EndOfTrackDetector(expectedURI: ours, expectedDuration: 200)
        _ = d.ingest(s(.playing, ours, 199, at: 0))
        #expect(d.ingest(s(.playing, ours, 0.6, at: 1)) == .finished)
    }

    @Test func seekingBackMidTrackIsNotTheEnd() {
        var d = EndOfTrackDetector(expectedURI: ours, expectedDuration: 200)
        _ = d.ingest(s(.playing, ours, 120, at: 0))
        #expect(d.ingest(s(.playing, ours, 10, at: 1)) == .playing)
    }

    @Test func acceptsRelinkedTrack() {
        var d = EndOfTrackDetector(expectedURI: ours, expectedDuration: 200)
        #expect(d.ingest(s(.playing, "spotify:track:relinked", 0.5, at: 0, duration: 200.8)) == .playing)
        #expect(d.expectedURI == "spotify:track:relinked")
        // But not a different-length track that happened to be playing.
        var e = EndOfTrackDetector(expectedURI: ours, expectedDuration: 200)
        #expect(e.ingest(s(.playing, "spotify:track:other", 0.5, at: 0, duration: 260)) == .waiting)
    }

    @Test func usesSpotifyDurationWhenOursIsMissing() {
        var d = EndOfTrackDetector(expectedURI: ours, expectedDuration: nil)
        _ = d.ingest(s(.playing, ours, 99, at: 0, duration: 100))
        #expect(d.ingest(s(.playing, next, 0, at: 1)) == .finished)
    }

    @Test func pollIntervals() {
        #expect(EndOfTrackDetector.nextPollInterval(position: 10, duration: 200, base: 1) == 1)
        #expect(EndOfTrackDetector.nextPollInterval(position: 199, duration: 200, base: 1) == 0.25)
        // Connect: 5 s base, but land a sample about a second before the end.
        #expect(EndOfTrackDetector.nextPollInterval(position: 10, duration: 200, base: 5) == 5)
        #expect(EndOfTrackDetector.nextPollInterval(position: 196, duration: 200, base: 5) == 3)
        #expect(EndOfTrackDetector.nextPollInterval(position: 10, duration: nil, base: 5) == 5)
    }
}

@Suite struct AppBridgeTests {
    @Test func fourCharCodes() {
        #expect(fourCC("spfy") == 0x7370_6679)
        #expect(fourCC("ID  ") == 0x4944_2020)
        #expect(fourCC("----") == 0x2D2D_2D2D)
    }

    @Test func dictionaryCodesAreWellFormed() {
        for (kind, _, code) in SpotifyAppBridge.dictionaryCodes {
            #expect(code.utf8.count == (kind == "command" ? 8 : 4))
        }
    }

    @Test func permissionErrorExplainsTheFix() {
        let error = SpotifyAppError(code: -1743)
        #expect(error.isPermissionDenied)
        #expect(error.localizedDescription.contains("Automation"))
        #expect(SpotifyAppError(code: -600).isNotRunning)
        #expect(SpotifyAppError(code: -1728).isNoSuchObject)
    }
}

/// The engine wiring that doesn't need Spotify: route choice and the lazy start on load without autoplay.
@MainActor
@Suite struct EngineTests {
    func engine(appInstalled: Bool, signedIn: Bool, preference: SpotifyPlaybackEngine.RoutePreference = .automatic) async -> SpotifyPlaybackEngine {
        let defaults = UserDefaults(suiteName: "openmusic.tests.\(UUID().uuidString)")!
        let (service, _) = await makeService(fixtureRoutes)
        let engine = SpotifyPlaybackEngine(service: service, defaults: defaults, isSignedIn: { signedIn }, appInstalled: { appInstalled })
        engine.preference = preference
        return engine
    }

    @Test func automaticPrefersTheApp() async throws {
        #expect(try await engine(appInstalled: true, signedIn: true).resolveRoute() == .thisMac)
        #expect(try await engine(appInstalled: false, signedIn: true).resolveRoute() == .connect)
    }

    @Test func noRouteIsUnplayable() async {
        let e = await engine(appInstalled: false, signedIn: false)
        #expect {
            try e.resolveRoute()
        } throws: { error in
            if case ProviderError.unplayable = error { return true }
            return false
        }
    }

    @Test func forcedRoutes() throws {
        #expect(throws: ProviderError.self) { try self.syncResolve(appInstalled: false, signedIn: true, .thisMac) }
        #expect(try syncResolve(appInstalled: false, signedIn: true, .connect) == .connect)
        #expect(throws: ProviderError.notSignedIn) { try self.syncResolve(appInstalled: true, signedIn: false, .connect) }
    }

    private func syncResolve(appInstalled: Bool, signedIn: Bool, _ preference: SpotifyPlaybackEngine.RoutePreference) throws -> SpotifyPlaybackEngine.ActiveRoute {
        let defaults = UserDefaults(suiteName: "openmusic.tests.\(UUID().uuidString)")!
        let api = SpotifyAPI(transport: FakeTransport(fixtureRoutes), tokenStore: MemoryTokenStore(), clientID: { nil })
        let engine = SpotifyPlaybackEngine(service: SpotifyService(api: api), defaults: defaults, isSignedIn: { signedIn }, appInstalled: { appInstalled })
        engine.preference = preference
        return try engine.resolveRoute()
    }

    @Test func loadWithoutAutoplayDoesNotTouchSpotify() async throws {
        let defaults = UserDefaults(suiteName: "openmusic.tests.\(UUID().uuidString)")!
        let transport = FakeTransport(fixtureRoutes)
        let api = SpotifyAPI(transport: transport, tokenStore: MemoryTokenStore(validToken()), clientID: { "c" })
        let engine = SpotifyPlaybackEngine(service: SpotifyService(api: api), defaults: defaults, isSignedIn: { true }, appInstalled: { false })
        var events: [String] = []
        engine.onEvent = { event in
            switch event {
            case .state(let s): events.append(s.rawValue)
            case .time(let t, _): events.append("time:\(Int(t))")
            case .finished: events.append("finished")
            case .failed(let m): events.append("failed:\(m)")
            }
        }
        let track = Track(providerID: "abc", provider: .spotify, title: "T", duration: 200)
        try await engine.load(track, startAt: 42, autoplay: false)
        #expect(events == ["loading", "time:42", "paused"])
        #expect(engine.currentTime == 42)
        #expect(engine.activeRoute == .connect)
        #expect(transport.requests.isEmpty) // nothing sent until play()
        engine.stop()
        #expect(events.last == "idle")
    }

    @Test func connectAutoplayStartsOnPreferredDevice() async throws {
        let defaults = UserDefaults(suiteName: "openmusic.tests.\(UUID().uuidString)")!
        let transport = FakeTransport(fixtureRoutes)
        let api = SpotifyAPI(transport: transport, tokenStore: MemoryTokenStore(validToken()), clientID: { "c" })
        let engine = SpotifyPlaybackEngine(service: SpotifyService(api: api), defaults: defaults, isSignedIn: { true }, appInstalled: { false })
        engine.connectDeviceID = "0d1841b0976bae2a3a310dd74c0f3df354899bc8"
        let track = Track(providerID: "abc", provider: .spotify, title: "T", duration: 200)
        try await engine.load(track, startAt: 0, autoplay: true)
        let play = try #require(transport.requests.first { $0.url?.path == "/v1/me/player/play" })
        #expect(play.query["device_id"] == "0d1841b0976bae2a3a310dd74c0f3df354899bc8")
        #expect(play.jsonBody?["uris"] as? [String] == ["spotify:track:abc"])
        engine.stop()
    }

    @Test func settingsPersist() async {
        let suite = "openmusic.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let api = SpotifyAPI(transport: FakeTransport(fixtureRoutes), tokenStore: MemoryTokenStore(), clientID: { nil })
        let engine = SpotifyPlaybackEngine(service: SpotifyService(api: api), defaults: defaults)
        engine.preference = .connect
        engine.connectDeviceID = "dev"
        let again = SpotifyPlaybackEngine(service: SpotifyService(api: api), defaults: defaults)
        #expect(again.preference == .connect)
        #expect(again.connectDeviceID == "dev")
    }
}
