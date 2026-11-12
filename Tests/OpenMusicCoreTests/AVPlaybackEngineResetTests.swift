import AVFoundation
import Foundation
import Testing
@testable import OpenMusicCore

/// Part of the serialized `AVPlaybackEngineTests` suite: real AVPlayer on wall-clock time.
extension AVPlaybackEngineTests {
    @Test func reportsTransportCommandsBeforeActing() async throws {
        let url = try AudioFixture.tone(seconds: 6)
        let engine = AVPlaybackEngine(resolver: FakeResolver(urls: [url]))
        var commands: [AVPlaybackEngine.TransportCommand] = []
        engine.onTransportCommand = { commands.append($0) }
        try await engine.load(track, startAt: 0, autoplay: false)
        engine.play()
        engine.pause()
        try await engine.load(nextTrack, startAt: 0, autoplay: true)
        engine.stop()
        #expect(commands == [.pause, .play, .pause, .play, .stop])
    }

    @Test func playerPauseReachesTheEngineEvenWhenAlreadyPaused() async throws {
        // What lets the iOS audio session tell "the listener paused" from "an interruption paused us".
        let url = try AudioFixture.tone(seconds: 6)
        let engine = AVPlaybackEngine(resolver: FakeResolver(urls: [url]))
        let player = PlayerController(scheduler: ManualScheduler())
        player.register(EngineProvider(engine: engine))
        var commands: [AVPlaybackEngine.TransportCommand] = []
        engine.onTransportCommand = { commands.append($0) }
        player.play(track)
        #expect(await waitUntil { player.state == .playing })
        player.pause()
        #expect(await waitUntil { player.state == .paused })
        player.pause()
        #expect(commands == [.play, .pause, .pause])
        player.stop()
        #expect(commands.last == .stop)
    }

    @Test func rebuildAfterMediaResetKeepsPlaying() async throws {
        let url = try AudioFixture.tone(seconds: 8)
        let resolver = FakeResolver(urls: [url])
        let engine = AVPlaybackEngine(resolver: resolver)
        let log = EventLog()
        log.attach(to: engine)
        try await engine.load(track, startAt: 0, autoplay: true)
        #expect(await waitUntil { engine.currentTime >= 1.5 })
        let oldPlayer = engine.activePlayer
        let position = engine.currentTime

        engine.rebuildPlayers(playing: true)
        #expect(engine.activePlayer !== oldPlayer)
        #expect(engine.mediaResetCount == 1)
        #expect(await waitUntil { log.lastState == .playing && engine.activePlayer.timeControlStatus == .playing })
        let resumed = engine.currentTime
        #expect(resumed >= position - 0.75)
        #expect(resumed < position + 1.5)
        #expect(await waitUntil { engine.currentTime > resumed + 0.5 })
        // The unexpired stream is reused: no extra lookup.
        #expect(resolver.calls == 1)
        #expect(log.failures.isEmpty)
        engine.stop()
    }

    @Test func rebuildAfterMediaResetStaysPaused() async throws {
        let url = try AudioFixture.tone(seconds: 6)
        let engine = AVPlaybackEngine(resolver: FakeResolver(urls: [url]))
        let log = EventLog()
        log.attach(to: engine)
        try await engine.load(track, startAt: 3, autoplay: false)
        #expect(log.lastState == .paused)
        let oldPlayer = engine.activePlayer

        engine.rebuildPlayers(playing: false)
        #expect(engine.activePlayer !== oldPlayer)
        #expect(await waitUntil { abs(engine.currentTime - 3) < 0.1 && engine.activePlayer.currentItem?.status == .readyToPlay })
        try await Task.sleep(for: .milliseconds(500))
        #expect(log.lastState == .paused)
        #expect(engine.activePlayer.timeControlStatus == .paused)
        #expect(!engine.isTimeObserverAttached)
        // Play still works on the new player.
        engine.play()
        #expect(await waitUntil { log.lastState == .playing })
        #expect(await waitUntil { engine.currentTime > 3.3 })
        engine.stop()
    }

    @Test func rebuildWithNothingLoadedIsQuiet() {
        let engine = AVPlaybackEngine(resolver: FakeResolver(urls: [AudioFixture.missing]))
        let log = EventLog()
        log.attach(to: engine)
        engine.rebuildPlayers(playing: true)
        #expect(log.events.isEmpty)
        #expect(engine.activePlayer.currentItem == nil)
    }
}
