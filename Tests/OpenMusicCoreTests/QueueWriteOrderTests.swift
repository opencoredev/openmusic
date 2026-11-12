import Foundation
import Testing
@testable import OpenMusicCore

/// A background save queued before the app went to the background must not land over the flush it made.
@MainActor
struct QueueWriteOrderTests {
    func tempStore() -> QueueStore {
        QueueStore(url: FileManager.default.temporaryDirectory.appending(path: "openmusic-tests/queue-\(UUID().uuidString).json"))
    }

    func snapshot(index: Int) -> PlayerSnapshot {
        PlayerSnapshot(queue: makeTracks(4).map { QueueEntry(track: $0) }, currentIndex: index, position: 0, shuffle: false,
                       repeatMode: .off, originalOrder: nil, recentlyPlayed: [], savedAt: Date())
    }

    @Test func storeKeepsTheNewestGeneration() async throws {
        let store = tempStore()
        #expect(try store.writeNow(snapshot(index: 2), generation: 5))
        #expect(try await !store.save(snapshot(index: 1), generation: 3))
        #expect(await store.load()?.currentIndex == 2)
        #expect(try await store.save(snapshot(index: 3), generation: 6))
        #expect(await store.load()?.currentIndex == 3)
    }

    @Test func backgroundFlushWinsOverAnOlderQueuedSave() async throws {
        let scheduler = ManualScheduler()
        let player = PlayerController(scheduler: scheduler)
        let provider = FakeProvider()
        player.register(provider)
        player.autoplay = false
        let store = tempStore()
        let persistence = QueuePersistence(player: player, store: store, scheduler: scheduler, debounce: 1, playingInterval: 20)
        persistence.start()
        player.play(makeTracks(4))
        await player.settle()
        player.pause()

        // The debounced save fires and queues a write of "track 0"; before it runs, the listener skips and the app
        // goes to the background, which writes "track 1" synchronously.
        scheduler.advance(by: 1)
        #expect(persistence.saveCount == 1)
        player.next()
        #expect(player.currentIndex == 1)
        persistence.flushSynchronously()
        await persistence.waitForPendingSaves()

        #expect(await store.load()?.currentIndex == 1)
        persistence.stop()
    }
}
