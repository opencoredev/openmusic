import AVFoundation
import Foundation
import Testing
@testable import MedleyCore

/// Real AVPlayer against generated AAC files on disk. Serialized because they run on wall-clock time.
@MainActor
@Suite(.serialized)
struct AVPlaybackEngineTests {
    let track = makeTracks(1, prefix: "e")[0]
    let nextTrack = makeTracks(1, prefix: "n")[0]

    @Test func playsAndReportsTime() async throws {
        let url = try AudioFixture.tone(seconds: 6)
        let engine = AVPlaybackEngine(resolver: FakeResolver(urls: [url]))
        let log = EventLog()
        log.attach(to: engine)
        try await engine.load(track, startAt: 0, autoplay: true)
        #expect(await waitUntil { log.lastState == .playing })
        #expect(await waitUntil { engine.currentTime > 1.0 })
        #expect(log.timeEvents >= 1)
        #expect(engine.duration.map { abs($0 - 6) < 0.2 } == true)
        #expect(engine.isTimeObserverAttached)
        engine.stop()
        #expect(log.lastState == .idle)
        #expect(!engine.isTimeObserverAttached)
    }

    @Test func startsAtRequestedPositionPaused() async throws {
        let url = try AudioFixture.tone(seconds: 6)
        let engine = AVPlaybackEngine(resolver: FakeResolver(urls: [url]))
        let log = EventLog()
        log.attach(to: engine)
        try await engine.load(track, startAt: 3, autoplay: false)
        #expect(log.lastState == .paused)
        #expect(abs(engine.currentTime - 3) < 0.1)
        #expect(!engine.isTimeObserverAttached)
        engine.stop()
    }

    @Test func pausedEngineSchedulesNoTimeEvents() async throws {
        let url = try AudioFixture.tone(seconds: 8)
        let engine = AVPlaybackEngine(resolver: FakeResolver(urls: [url]))
        let log = EventLog()
        log.attach(to: engine)
        try await engine.load(track, startAt: 0, autoplay: true)
        #expect(await waitUntil { engine.currentTime > 0.6 })
        engine.pause()
        #expect(await waitUntil { log.lastState == .paused && !engine.isTimeObserverAttached })
        let before = log.timeEvents
        try await Task.sleep(for: .seconds(1.5))
        #expect(log.timeEvents == before)
        engine.play()
        #expect(await waitUntil { log.lastState == .playing && engine.isTimeObserverAttached })
        engine.stop()
    }

    @Test func reResolvesWhenTheFirstURLFails() async throws {
        let good = try AudioFixture.tone(seconds: 6)
        let resolver = FakeResolver(urls: [AudioFixture.missing, good])
        let engine = AVPlaybackEngine(resolver: resolver)
        let log = EventLog()
        log.attach(to: engine)
        try await engine.load(track, startAt: 0, autoplay: true)
        #expect(await waitUntil { log.lastState == .playing && engine.currentTime > 0.5 })
        #expect(resolver.calls == 2)
        #expect(engine.recoveryCount == 1)
        #expect(log.failures.isEmpty)
        engine.stop()
    }

    @Test func midTrackFailureResumesAtTheSamePosition() async throws {
        let first = try AudioFixture.tone(seconds: 10)
        let fresh = try AudioFixture.copy(of: first)
        let resolver = FakeResolver(urls: [first, fresh])
        let engine = AVPlaybackEngine(resolver: resolver)
        let log = EventLog()
        log.attach(to: engine)
        try await engine.load(track, startAt: 0, autoplay: true)
        #expect(await waitUntil { engine.currentTime >= 2.0 })
        let position = engine.currentTime
        engine.simulateStreamFailure()
        #expect(log.lastState == .buffering)
        #expect(await waitUntil { log.lastState == .playing })
        #expect(resolver.calls == 2)
        let resumed = engine.currentTime
        #expect(resumed >= position - 0.75)
        #expect(resumed < position + 1.5)
        #expect(await waitUntil { engine.currentTime > resumed + 0.5 })
        #expect(log.failures.isEmpty)
        engine.stop()
    }

    @Test func recoveryBypassesTheResolverCache() async throws {
        // The first URL is dead but nominally valid for hours; a cached lookup would return it again.
        let good = try AudioFixture.tone(seconds: 6)
        let resolver = CachingResolver(urls: [AudioFixture.missing, good])
        let engine = AVPlaybackEngine(resolver: resolver)
        let log = EventLog()
        log.attach(to: engine)
        try await engine.load(track, startAt: 0, autoplay: true)
        #expect(await waitUntil { log.lastState == .playing && engine.currentTime > 0.5 })
        #expect(resolver.fetches == 2)
        #expect(engine.recoveryCount == 1)
        #expect(log.failures.isEmpty)
        engine.stop()
    }

    @Test func midTrackRecoveryFetchesAFreshURL() async throws {
        let first = try AudioFixture.tone(seconds: 10)
        let fresh = try AudioFixture.copy(of: first)
        let resolver = CachingResolver(urls: [first, fresh])
        let engine = AVPlaybackEngine(resolver: resolver)
        let log = EventLog()
        log.attach(to: engine)
        try await engine.load(track, startAt: 0, autoplay: true)
        #expect(await waitUntil { engine.currentTime >= 1.0 })
        engine.simulateStreamFailure()
        #expect(await waitUntil { log.lastState == .playing })
        #expect(resolver.fetches == 2)
        engine.stop()
    }

    @Test func givesUpAfterRepeatedFailures() async throws {
        let resolver = FakeResolver(urls: [AudioFixture.missing])
        let engine = AVPlaybackEngine(resolver: resolver)
        engine.maxRecoveryAttempts = 2
        let log = EventLog()
        log.attach(to: engine)
        try await engine.load(track, startAt: 0, autoplay: true)
        #expect(await waitUntil { log.failures.count == 1 })
        #expect(log.lastState == .failed)
        #expect(resolver.calls == 3)
        try await Task.sleep(for: .milliseconds(300))
        #expect(log.failures.count == 1)
        engine.stop()
    }

    @Test func resolverErrorsSurfaceFromLoad() async throws {
        let engine = AVPlaybackEngine(resolver: FakeResolver([.failure(.unplayable("region locked"))]))
        await #expect(throws: ProviderError.unplayable("region locked")) {
            try await engine.load(track, startAt: 0, autoplay: true)
        }
    }

    @Test func reportsTheStreamLengthForLoadedAndPreparedTracks() async throws {
        let url = try AudioFixture.tone(seconds: 2)
        let engine = AVPlaybackEngine(resolver: FakeResolver([.success(PlayableStream(url: url, duration: 406))]))
        var reported: [String: TimeInterval] = [:]
        engine.onDurationResolved = { id, seconds in reported[id] = seconds }
        let next = Track(providerID: "next", provider: .youtubeMusic, title: "Next")
        try await engine.load(track, startAt: 0, autoplay: false)
        engine.prepareNext(next)
        #expect(await waitUntil { reported[next.id] != nil })
        #expect(reported == [track.id: 406, next.id: 406])
        engine.stop()
    }

    @Test func expiredStreamIsRefreshedOnResume() async throws {
        let url = try AudioFixture.tone(seconds: 6)
        let expiring = PlayableStream(url: url, expiresAt: Date().addingTimeInterval(5))
        let resolver = FakeResolver([.success(expiring), .success(PlayableStream(url: url))])
        let engine = AVPlaybackEngine(resolver: resolver)
        let log = EventLog()
        log.attach(to: engine)
        try await engine.load(track, startAt: 1, autoplay: false)
        engine.play()
        #expect(await waitUntil { log.lastState == .playing })
        #expect(resolver.calls == 2)
        #expect(engine.currentTime >= 0.9)
        engine.stop()
    }

    @Test func supersededLoadThrowsCancellation() async throws {
        let url = try AudioFixture.tone(seconds: 4)
        let resolver = FakeResolver(urls: [url])
        resolver.delay = 0.3
        let engine = AVPlaybackEngine(resolver: resolver)
        let first = Task { try await engine.load(track, startAt: 0, autoplay: true) }
        try await Task.sleep(for: .milliseconds(100)) // first load is now waiting on the resolver
        try await engine.load(nextTrack, startAt: 0, autoplay: true)
        await #expect(throws: CancellationError.self) { try await first.value }
        engine.stop()
    }

    @Test func cancelledCallerNeverLoads() async throws {
        let url = try AudioFixture.tone(seconds: 4)
        let resolver = FakeResolver(urls: [url])
        let engine = AVPlaybackEngine(resolver: resolver)
        let log = EventLog()
        log.attach(to: engine)
        let load = Task { try await engine.load(track, startAt: 0, autoplay: true) }
        load.cancel()
        await #expect(throws: CancellationError.self) { try await load.value }
        #expect(resolver.calls == 0)
        #expect(log.states.isEmpty)
        #expect(engine.duration == nil)
    }

    @Test func stopDuringLoadKeepsTheEngineSilent() async throws {
        let url = try AudioFixture.tone(seconds: 4)
        let resolver = FakeResolver(urls: [url])
        resolver.delay = 0.3
        let engine = AVPlaybackEngine(resolver: resolver)
        let log = EventLog()
        log.attach(to: engine)
        let load = Task { try await engine.load(track, startAt: 0, autoplay: true) }
        try await Task.sleep(for: .milliseconds(100)) // waiting on the resolver
        engine.stop()
        await #expect(throws: CancellationError.self) { try await load.value }
        try await Task.sleep(for: .milliseconds(300))
        #expect(log.lastState == .idle)
        #expect(engine.duration == nil)
        #expect(!engine.isTimeObserverAttached)
    }

    @Test func doubledDirectStreamDurationFallsBackToTheCatalog() {
        #expect(AVPlaybackEngine.playableDuration(reported: 400, expected: 200) == 200)
        #expect(AVPlaybackEngine.playableDuration(reported: 201.5, expected: 200) == 201.5)
        #expect(AVPlaybackEngine.playableDuration(reported: 180, expected: nil) == 180)
        #expect(AVPlaybackEngine.playableDuration(reported: .nan, expected: 200) == nil)
        #expect(AVPlaybackEngine.playableDuration(reported: nil, expected: 200) == nil)
    }

    @Test func handsOffToThePreparedTrackWithoutReloading() async throws {
        let a = try AudioFixture.tone(seconds: 2, frequency: 440)
        let b = try AudioFixture.tone(seconds: 4, frequency: 660)
        let resolver = FakeResolver(urls: [a, b])
        let engine = AVPlaybackEngine(resolver: resolver)
        let log = EventLog()
        log.attach(to: engine)
        try await engine.load(track, startAt: 0, autoplay: true)
        engine.prepareNext(nextTrack)
        #expect(await waitUntil { engine.standbyTrackID == nextTrack.id })
        #expect(await waitUntil { log.finishedCount == 1 })
        // The engine already started the next track; the controller's load adopts it.
        try await engine.load(nextTrack, startAt: 0, autoplay: true)
        #expect(resolver.calls == 2)
        #expect(await waitUntil { engine.currentTime > 0.5 && log.lastState == .playing })
        #expect(engine.duration.map { abs($0 - 4) < 0.2 } == true)
        engine.stop()
    }

    @Test func crossfadeOverlapsTracks() async throws {
        let a = try AudioFixture.tone(seconds: 4, frequency: 440)
        let b = try AudioFixture.tone(seconds: 4, frequency: 880)
        let resolver = FakeResolver(urls: [a, b])
        let engine = AVPlaybackEngine(resolver: resolver)
        engine.crossfadeDuration = 1.5
        let log = EventLog()
        log.attach(to: engine)
        try await engine.load(track, startAt: 0, autoplay: true)
        engine.prepareNext(nextTrack)
        #expect(await waitUntil { engine.isCrossfading })
        #expect(log.finishedCount == 1)
        try await engine.load(nextTrack, startAt: 0, autoplay: true)
        #expect(engine.isCrossfading) // adopting doesn't cut the fade short
        #expect(await waitUntil { !engine.isCrossfading })
        #expect(resolver.calls == 2)
        #expect(log.lastState == .playing)
        engine.stop()
    }

    @Test func loudnessGain() {
        #expect(AVPlaybackEngine.gain(forLoudnessDB: nil) == 1)
        #expect(AVPlaybackEngine.gain(forLoudnessDB: 0) == 1)
        #expect(abs(AVPlaybackEngine.gain(forLoudnessDB: 6) - 0.501) < 0.001)
        #expect(abs(AVPlaybackEngine.gain(forLoudnessDB: 40) - 0.251) < 0.001) // clamped at -12 dB
        #expect(abs(AVPlaybackEngine.gain(forLoudnessDB: -40) - 1.995) < 0.001) // clamped at +6 dB
        #expect(AVPlaybackEngine.gain(forLoudnessDB: .nan) == 1)
    }

    @Test func normalizationAppliesStreamLoudness() async throws {
        let url = try AudioFixture.tone(seconds: 3)
        let engine = AVPlaybackEngine(resolver: FakeResolver([.success(PlayableStream(url: url, loudnessDB: 6))]))
        try await engine.load(track, startAt: 0, autoplay: false)
        #expect(abs(engine.activeGain - 0.501) < 0.001)
        engine.stop()
    }
}

/// End-to-end through `PlayerController` with the real engine.
@MainActor
@Suite(.serialized)
struct ControllerWithAVEngineTests {
    @Test func controllerAdvancesAcrossRealTracks() async throws {
        let a = try AudioFixture.tone(seconds: 2, frequency: 440)
        let b = try AudioFixture.tone(seconds: 3, frequency: 550)
        let resolver = FakeResolver(urls: [a, b])
        let engine = AVPlaybackEngine(resolver: resolver)
        let player = PlayerController(scheduler: ManualScheduler())
        player.register(EngineProvider(engine: engine))
        player.autoplay = false
        let tracks = makeTracks(2, duration: 2)
        player.play(tracks)
        #expect(await waitUntil { player.state == .playing })
        #expect(await waitUntil(timeout: 8) { player.current?.id == tracks[1].id && player.currentTime > 0.3 })
        #expect(player.state == .playing)
        #expect(resolver.calls == 2)
        #expect(await waitUntil(timeout: 8) { player.state == .ended })
        player.clearQueue()
    }
}
