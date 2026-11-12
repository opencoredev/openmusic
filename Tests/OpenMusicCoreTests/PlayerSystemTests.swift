import Foundation
import MediaPlayer
import SwiftUI
import Testing
@testable import OpenMusicCore

@MainActor
struct SleepTimerTests {
    let scheduler = ManualScheduler()

    func make() -> (PlayerController, FakeProvider) {
        let player = PlayerController(scheduler: scheduler)
        let provider = FakeProvider()
        player.register(provider)
        player.autoplay = false
        return (player, provider)
    }

    @Test func pausesAfterMinutes() async {
        let (player, provider) = make()
        player.play(makeTracks(3))
        await player.settle()
        player.setSleepTimer(minutes: 10)
        #expect(player.sleepTimer == .at(scheduler.now.addingTimeInterval(600)))
        scheduler.advance(by: 9 * 60)
        #expect(player.state == .playing)
        #expect(player.sleepTimerRemaining == 60)
        scheduler.advance(by: 60)
        #expect(player.state == .paused)
        #expect(provider.engine.pauses == 1)
        #expect(player.sleepTimer == .off)
        #expect(player.sleepTimerRemaining == nil)
    }

    @Test func resettingReplacesTheDeadline() async {
        let (player, provider) = make()
        player.play(makeTracks(3))
        await player.settle()
        player.setSleepTimer(minutes: 5)
        player.setSleepTimer(minutes: 20)
        #expect(scheduler.pendingCount == 1)
        scheduler.advance(by: 6 * 60)
        #expect(player.state == .playing)
        scheduler.advance(by: 15 * 60)
        #expect(player.state == .paused)
        #expect(provider.engine.pauses == 1)
    }

    @Test func cancelLeavesPlaybackAlone() async {
        let (player, provider) = make()
        player.play(makeTracks(3))
        await player.settle()
        player.setSleepTimer(minutes: 1)
        player.cancelSleepTimer()
        scheduler.advance(by: 3600)
        #expect(player.state == .playing)
        #expect(provider.engine.pauses == 0)
        #expect(scheduler.pendingCount == 0)
    }

    @Test func endOfTrackStopsAtTheBoundaryAndCuesTheNextTrack() async {
        let (player, provider) = make()
        let tracks = makeTracks(3)
        player.play(tracks)
        await player.settle()
        #expect(provider.engine.lastPrepared == tracks[1].id)
        player.setSleepTimerEndOfTrack()
        // No gapless handoff into a track that shouldn't play.
        #expect(provider.engine.lastPrepared == .some(nil))
        player.skip(by: 30)
        #expect(player.state == .playing)
        provider.engine.finish()
        await player.settle()
        #expect(player.current?.id == tracks[1].id)
        #expect(provider.engine.lastLoad == .init(trackID: tracks[1].id, startAt: 0, autoplay: false))
        #expect(player.state == .paused)
        #expect(player.sleepTimer == .off)
        player.togglePlayPause()
        #expect(player.state == .playing)
    }

    @Test func endOfTrackOnLastTrackEnds() async {
        let (player, provider) = make()
        player.play(makeTracks(1))
        await player.settle()
        player.setSleepTimerEndOfTrack()
        provider.engine.finish()
        #expect(player.state == .ended)
    }
}

@MainActor
struct RecentlyPlayedTests {
    let scheduler = ManualScheduler()

    func make() -> (PlayerController, FakeProvider) {
        let player = PlayerController(scheduler: scheduler)
        let provider = FakeProvider()
        player.register(provider)
        player.autoplay = false
        return (player, provider)
    }

    @Test func recordsAfterThirtySecondsOfListening() async {
        let (player, provider) = make()
        let tracks = makeTracks(2, duration: 240)
        var reported: [String] = []
        player.onTrackPlayed = { reported.append($0.track.id) }
        player.play(tracks, from: .playlist(Playlist(providerID: "p", provider: .youtubeMusic, title: "Mix")))
        await player.settle()
        provider.engine.play(until: 29)
        #expect(player.recentlyPlayed.isEmpty)
        provider.engine.play(until: 30)
        #expect(player.recentlyPlayed.map(\.track.id) == [tracks[0].id])
        #expect(player.recentlyPlayed.first?.playedAt == scheduler.now)
        #expect(player.recentlyPlayed.first?.context?.title == "Mix")
        provider.engine.play(until: 120)
        #expect(reported == [tracks[0].id])
    }

    @Test func shortTracksCountAtHalfTheirLength() async {
        let (player, provider) = make()
        player.play(makeTracks(1, duration: 40))
        await player.settle()
        provider.engine.play(until: 19)
        #expect(player.recentlyPlayed.isEmpty)
        provider.engine.play(until: 20)
        #expect(player.recentlyPlayed.count == 1)
    }

    @Test func seekingAheadDoesNotCount() async {
        let (player, provider) = make()
        player.play(makeTracks(1))
        await player.settle()
        provider.engine.tick(5)
        player.seek(to: 150)
        provider.engine.tick(150)
        provider.engine.tick(160)
        #expect(player.recentlyPlayed.isEmpty)
    }

    @Test func replaysMoveToTheFrontWithoutDuplicates() async {
        let (player, provider) = make()
        let tracks = makeTracks(2)
        player.play(tracks)
        await player.settle()
        provider.engine.play(until: 31)
        player.next()
        await player.settle()
        provider.engine.play(until: 31)
        player.previous() // more than 3 s in: restart
        player.previous() // back to the first track
        await player.settle()
        provider.engine.play(until: 31)
        #expect(player.recentlyPlayed.map(\.track.id) == [tracks[0].id, tracks[1].id])
    }

    @Test func repeatOneCountsEachPlay() async {
        let (player, provider) = make()
        var reports = 0
        player.onTrackPlayed = { _ in reports += 1 }
        player.repeatMode = .one
        player.play(makeTracks(1, duration: 60))
        await player.settle()
        provider.engine.play(until: 60)
        provider.engine.finish()
        provider.engine.currentTime = 0
        provider.engine.play(until: 40)
        #expect(reports == 2)
        #expect(player.recentlyPlayed.count == 1)
    }
}

@MainActor
struct PersistenceTests {
    func tempStore() -> QueueStore {
        QueueStore(url: FileManager.default.temporaryDirectory.appending(path: "openmusic-tests/queue-\(UUID().uuidString).json"))
    }

    @Test func snapshotRoundTripsThroughDisk() async throws {
        let scheduler = ManualScheduler()
        let player = PlayerController(scheduler: scheduler)
        let provider = FakeProvider()
        player.register(provider)
        player.autoplay = false
        let tracks = makeTracks(8)
        player.play(tracks, startAt: 2, from: .album(Album(providerID: "a", provider: .youtubeMusic, title: "Homework")))
        await player.settle()
        player.playNext(makeTracks(1, prefix: "q"))
        player.shuffle = true
        player.repeatMode = .all
        provider.engine.play(until: 42)

        let store = tempStore()
        let snapshot = player.snapshot()
        try await store.save(snapshot)
        let loaded = try #require(await store.load())
        #expect(loaded == snapshot)

        // A fresh player (next launch) comes back paused at the same spot, without touching the engine.
        let relaunched = PlayerController(scheduler: scheduler)
        let freshProvider = FakeProvider()
        relaunched.register(freshProvider)
        relaunched.restore(loaded)
        #expect(relaunched.queue == player.queue)
        #expect(relaunched.currentIndex == player.currentIndex)
        #expect(relaunched.currentTime == 42)
        #expect(relaunched.state == .paused)
        #expect(relaunched.shuffle)
        #expect(relaunched.repeatMode == .all)
        #expect(relaunched.sourceLabel == "Playing from Homework")
        #expect(relaunched.recentlyPlayed.map(\.track.id) == [tracks[2].id])
        #expect(freshProvider.engine.loads.isEmpty)

        // Unshuffle still works after the relaunch.
        relaunched.shuffle = false
        #expect(relaunched.upNext.first?.track.id == "youtubeMusic:q0")
        #expect(relaunched.upNext.dropFirst().map(\.track.id) == tracks[3...].map(\.id))

        // Play loads the saved track at the saved position.
        relaunched.togglePlayPause()
        await relaunched.settle()
        #expect(freshProvider.engine.lastLoad == .init(trackID: tracks[2].id, startAt: 42, autoplay: true))
        #expect(relaunched.state == .playing)
    }

    @Test func restoredPlayerMovesCursorWithoutLoading() async {
        let player = PlayerController(scheduler: ManualScheduler())
        let provider = FakeProvider()
        player.register(provider)
        let tracks = makeTracks(3)
        let snapshot = PlayerSnapshot(
            queue: tracks.map { QueueEntry(track: $0) }, currentIndex: 1, position: 12, shuffle: false,
            repeatMode: .off, originalOrder: nil, recentlyPlayed: [], savedAt: Date()
        )
        player.restore(snapshot)
        player.next()
        #expect(player.current?.id == tracks[2].id)
        #expect(player.currentTime == 0)
        player.seek(to: 7)
        #expect(provider.engine.loads.isEmpty)
        player.resume()
        await player.settle()
        #expect(provider.engine.lastLoad == .init(trackID: tracks[2].id, startAt: 7, autoplay: true))
    }

    @Test func restoreIgnoresABadIndex() async {
        let player = PlayerController(scheduler: ManualScheduler())
        let snapshot = PlayerSnapshot(queue: [], currentIndex: 4, position: 10, shuffle: false, repeatMode: .one, originalOrder: nil, recentlyPlayed: [], savedAt: Date())
        player.restore(snapshot)
        #expect(player.current == nil)
        #expect(player.state == .idle)
    }

    @Test func storeReturnsNilForMissingOrCorruptFiles() async throws {
        let store = tempStore()
        #expect(await store.load() == nil)
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.url)
        #expect(await store.load() == nil)
    }

    @Test func persistenceDebouncesAndRestores() async throws {
        let scheduler = ManualScheduler()
        let player = PlayerController(scheduler: scheduler)
        let provider = FakeProvider()
        player.register(provider)
        player.autoplay = false
        let store = tempStore()
        let persistence = QueuePersistence(player: player, store: store, scheduler: scheduler, debounce: 2, playingInterval: 20)
        persistence.start()

        player.play(makeTracks(4))
        player.addToQueue(makeTracks(2, prefix: "u"))
        player.repeatMode = .all
        await player.settle()
        #expect(persistence.saveCount == 0)
        scheduler.advance(by: 2)
        #expect(persistence.saveCount == 1)
        // While playing, the position is saved periodically; pausing saves sooner.
        provider.engine.play(until: 15)
        scheduler.advance(by: 10)
        #expect(persistence.saveCount == 1)
        player.pause()
        scheduler.advance(by: 2)
        #expect(persistence.saveCount == 2)
        // Paused: nothing else is scheduled.
        #expect(scheduler.pendingCount == 0)
        await persistence.flush()

        let relaunched = PlayerController(scheduler: scheduler)
        let restorer = QueuePersistence(player: relaunched, store: store, scheduler: scheduler)
        #expect(await restorer.restore())
        #expect(relaunched.queue.map(\.track.id) == player.queue.map(\.track.id))
        #expect(relaunched.currentTime == 15)
        #expect(relaunched.repeatMode == .all)
        #expect(relaunched.state == .paused)
    }

    @Test func queueEntryDecodesOlderPayloads() throws {
        let entry = QueueEntry(track: makeTracks(1)[0])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as! [String: Any]
        json["isUserQueued"] = nil
        json["context"] = nil
        json["isAutoplay"] = nil
        let decoded = try JSONDecoder().decode(QueueEntry.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.uid == entry.uid)
        #expect(decoded.isUserQueued == false)
        #expect(decoded.isAutoplay == false)
    }
}

@MainActor
struct PlaybackSettingsTests {
    @Test func persistsAndClamps() {
        let suite = "openmusic-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = PlaybackSettings(defaults: defaults)
        #expect(settings.normalizeVolume)
        #expect(settings.crossfadeSeconds == 0)
        #expect(settings.autoplay)
        #expect(settings.outputDeviceUID == nil)
        #expect(settings.volume == 0.8)

        settings.normalizeVolume = false
        settings.crossfadeSeconds = 30
        settings.outputDeviceUID = "BuiltInSpeakerDevice"
        settings.autoplay = false
        settings.sleepTimerMinutes = 45
        settings.volume = 2
        #expect(settings.crossfadeSeconds == 12)
        #expect(settings.volume == 1)

        let reloaded = PlaybackSettings(defaults: defaults)
        #expect(reloaded.normalizeVolume == false)
        #expect(reloaded.crossfadeSeconds == 12)
        #expect(reloaded.outputDeviceUID == "BuiltInSpeakerDevice")
        #expect(reloaded.autoplay == false)
        #expect(reloaded.sleepTimerMinutes == 45)
        #expect(reloaded.volume == 1)
        reloaded.outputDeviceUID = nil
        #expect(PlaybackSettings(defaults: defaults).outputDeviceUID == nil)
    }

    @Test func controllerForwardsAudioSettingsToConfigurableEngines() async throws {
        let player = PlayerController(scheduler: ManualScheduler())
        let url = try AudioFixture.tone(seconds: 2)
        let engine = AVPlaybackEngine(resolver: FakeResolver(urls: [url]))
        let provider = EngineProvider(engine: engine)
        player.register(provider)
        player.normalizationEnabled = false
        player.crossfadeDuration = 20
        player.outputDeviceUID = "missing-device"
        #expect(engine.normalizationEnabled == false)
        #expect(engine.crossfadeDuration == 12)
        #expect(player.crossfadeDuration == 12)
        #expect(engine.outputDeviceUID == "missing-device")
        player.outputDeviceUID = nil
        #expect(engine.outputDeviceUID == nil)
        player.volume = 3
        #expect(player.volume == 1)
    }
}

@MainActor
struct NowPlayingTests {
    @Test func infoDictionaryDescribesTheTrack() {
        var track = makeTracks(1)[0]
        track.trackNumber = 3
        let info = NowPlayingCenter.makeInfo(track: track, elapsed: 12.5, duration: 201, isPlaying: true, queueIndex: 2, queueCount: 9)
        #expect(info[MPMediaItemPropertyTitle] as? String == "T 0")
        #expect(info[MPMediaItemPropertyArtist] as? String == "Artist")
        #expect(info[MPMediaItemPropertyAlbumTitle] as? String == "Album")
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 201)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 12.5)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
        #expect(info[MPNowPlayingInfoPropertyPlaybackQueueIndex] as? Int == 2)
        #expect(info[MPNowPlayingInfoPropertyPlaybackQueueCount] as? Int == 9)
        #expect(info[MPMediaItemPropertyAlbumTrackNumber] as? Int == 3)

        let paused = NowPlayingCenter.makeInfo(track: track, elapsed: 0, duration: nil, isPlaying: false, queueIndex: nil, queueCount: 0)
        #expect(paused[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        #expect(paused[MPMediaItemPropertyPlaybackDuration] as? Double == 200) // falls back to track metadata
    }

    @Test func playbackStateMapping() {
        #expect(NowPlayingCenter.playbackState(for: .playing) == .playing)
        #expect(NowPlayingCenter.playbackState(for: .buffering) == .playing)
        #expect(NowPlayingCenter.playbackState(for: .paused) == .paused)
        #expect(NowPlayingCenter.playbackState(for: .ended) == .stopped)
        #expect(NowPlayingCenter.playbackState(for: .idle) == .stopped)
    }

    @Test func publishesToTheInfoCenterAndRoutesCommands() async {
        let player = PlayerController(scheduler: ManualScheduler())
        let provider = FakeProvider()
        player.register(provider)
        player.autoplay = false
        let center = NowPlayingCenter(player: player)
        center.start()
        defer { center.stop() }
        let tracks = makeTracks(2)
        player.play(tracks)
        await player.settle()
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        #expect(info?[MPMediaItemPropertyTitle] as? String == tracks[0].title)
        #expect(MPNowPlayingInfoCenter.default().playbackState == .playing)
        player.pause()
        #expect(MPNowPlayingInfoCenter.default().playbackState == .paused)
        #expect(MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled)
        #expect(!MPRemoteCommandCenter.shared().likeCommand.isEnabled)
        center.onLike = { _ in }
        #expect(MPRemoteCommandCenter.shared().likeCommand.isEnabled)
    }
}

/// Wraps a real engine in a provider so the controller can drive it.
@MainActor
final class EngineProvider: MusicProvider {
    let id: ProviderID
    let capabilities: ProviderCapabilities = [.playback]
    let authStatus: AuthStatus = .signedOut
    let playbackEngine: any PlaybackEngine
    private let inner = FakeProvider()

    init(engine: any PlaybackEngine, id: ProviderID = .youtubeMusic) {
        self.playbackEngine = engine
        self.id = id
    }

    func restoreSession() async {}
    func makeSignInView(onFinish: @escaping @MainActor () -> Void) -> AnyView { inner.makeSignInView(onFinish: onFinish) }
    func makeSettingsView() -> AnyView { inner.makeSettingsView() }
    func signOut() async {}
    func home() async throws -> [Shelf] { [] }
    func explore() async throws -> [Shelf] { [] }
    func shelf(moreToken: String) async throws -> Shelf { throw ProviderError.notSupported("shelf") }
    func search(_ query: String, scope: SearchScope) async throws -> SearchResults { SearchResults() }
    func searchSuggestions(_ query: String) async throws -> [String] { [] }
    func album(id: String) async throws -> AlbumDetail { throw ProviderError.notFound }
    func artist(id: String) async throws -> ArtistDetail { throw ProviderError.notFound }
    func playlist(id: String) async throws -> PlaylistDetail { throw ProviderError.notFound }
    func playlistTracks(continuation: String) async throws -> Page<Track> { Page(items: []) }
    func library(_ kind: LibraryKind, continuation: String?) async throws -> Page<MediaItem> { Page(items: []) }
    func setLiked(_ track: Track, liked: Bool) async throws {}
    func isLiked(_ track: Track) async throws -> Bool { false }
    func setSaved(_ item: MediaItem, saved: Bool) async throws {}
    func createPlaylist(title: String, description: String?) async throws -> Playlist { throw ProviderError.notSupported("create") }
    func add(_ tracks: [Track], toPlaylist playlistID: String) async throws {}
    func remove(_ tracks: [Track], fromPlaylist playlistID: String) async throws {}
    func radio(seed: Track) async throws -> [Track] { [] }
    func radio(seedID: String) async throws -> [Track] { [] }
    func lyrics(for track: Track) async throws -> Lyrics? { nil }
}
