import Foundation
import Testing
@testable import OpenMusicCore

private func withoutDurations(_ tracks: [Track]) -> [Track] {
    tracks.map { var t = $0; t.duration = nil; return t }
}

/// The queue panel's History: songs that actually played, not the queue's earlier entries.
@MainActor
struct ListeningHistoryTests {
    let scheduler = ManualScheduler()

    func make() -> (PlayerController, FakeProvider) {
        let player = PlayerController(scheduler: scheduler)
        let provider = FakeProvider()
        player.register(provider)
        player.autoplay = false
        return (player, provider)
    }

    @Test func startingMidListLeavesHistoryEmpty() async {
        let (player, _) = make()
        player.play(makeTracks(6), startAt: 4)
        await player.settle()
        #expect(player.previousEntries.count == 4)
        #expect(player.listeningHistory.isEmpty)
    }

    @Test func onlySongsHeardForThirtySecondsAreListed() async {
        let (player, provider) = make()
        let tracks = makeTracks(4)
        player.play(tracks)
        await player.settle()
        provider.engine.play(until: 10) // skipped early: doesn't count
        player.next()
        await player.settle()
        provider.engine.play(until: 45)
        player.next()
        await player.settle()
        #expect(player.listeningHistory.map(\.track.id) == [tracks[1].id])
    }

    @Test func doubleClickingAnotherRowRecordsOnlyWhatPlayed() async {
        // The judge's case: play Blank Space (2nd), then Enchanted (5th). Songs 1, 3 and 4 never played.
        let (player, provider) = make()
        let tracks = makeTracks(5)
        player.play(tracks, startAt: 1)
        await player.settle()
        provider.engine.play(until: 60)
        player.jump(to: player.queue[4].uid)
        await player.settle()
        #expect(player.current?.id == tracks[4].id)
        #expect(player.listeningHistory.map(\.track.id) == [tracks[1].id])
    }

    @Test func currentSongIsNotListedWhileItPlays() async {
        let (player, provider) = make()
        let tracks = makeTracks(2)
        player.play(tracks)
        await player.settle()
        provider.engine.play(until: 40)
        #expect(player.recentlyPlayed.map(\.track.id) == [tracks[0].id])
        #expect(player.listeningHistory.isEmpty)
        player.next()
        await player.settle()
        #expect(player.listeningHistory.map(\.track.id) == [tracks[0].id])
    }

    @Test func aSongHeardBeforeIsHiddenWhileItPlaysAgain() async {
        let (player, provider) = make()
        let tracks = makeTracks(2)
        player.play(tracks)
        await player.settle()
        provider.engine.play(until: 31)
        player.next()
        await player.settle()
        provider.engine.play(until: 31)
        // Back to the first song, which is in History from before but hasn't counted again yet.
        player.jump(to: player.queue[0].uid)
        await player.settle()
        provider.engine.play(until: 5)
        #expect(player.recentlyPlayed.map(\.track.id) == [tracks[1].id, tracks[0].id])
        #expect(player.listeningHistory.map(\.track.id) == [tracks[1].id])
    }

    @Test func survivesANewQueue() async {
        let (player, provider) = make()
        let album = makeTracks(3, prefix: "a")
        player.play(album)
        await player.settle()
        provider.engine.play(until: 31)
        player.play(makeTracks(3, prefix: "p"))
        await player.settle()
        #expect(player.listeningHistory.map(\.track.id) == [album[0].id])
    }

    @Test func isCapped() async {
        let (player, provider) = make()
        let count = PlayerController.maxRecentlyPlayed + 5
        player.play(makeTracks(count, duration: 40))
        await player.settle()
        for _ in 0..<count {
            provider.engine.currentTime = 0
            provider.engine.play(until: 21)
            player.next()
            await player.settle()
        }
        #expect(player.recentlyPlayed.count == PlayerController.maxRecentlyPlayed)
    }

    @Test func persistsWithTheQueue() async {
        let (player, provider) = make()
        let tracks = makeTracks(3)
        player.play(tracks)
        await player.settle()
        provider.engine.play(until: 31)
        player.next()
        await player.settle()
        let restored = PlayerController(scheduler: scheduler)
        restored.register(FakeProvider())
        restored.restore(player.snapshot())
        #expect(restored.current?.id == tracks[1].id)
        #expect(restored.listeningHistory.map(\.track.id) == [tracks[0].id])
    }

    @Test func playNowFromHistoryKeepsTheQueue() async throws {
        let (player, provider) = make()
        let tracks = makeTracks(4)
        player.play(tracks)
        await player.settle()
        provider.engine.play(until: 31)
        player.next()
        await player.settle()
        let played = try #require(player.listeningHistory.first)
        player.playNow(played.track, from: played.context)
        await player.settle()
        #expect(player.current?.id == tracks[0].id)
        #expect(player.queue.count == 5)
        #expect(player.upNext.map(\.track.id) == [tracks[2].id, tracks[3].id])
        #expect(provider.engine.lastLoad?.trackID == tracks[0].id)
    }
}

/// One length per song across the player, the queue and History.
@MainActor
struct DurationReconciliationTests {
    func make() -> (PlayerController, FakeProvider) {
        let player = PlayerController(scheduler: ManualScheduler())
        let provider = FakeProvider()
        player.register(provider)
        player.autoplay = false
        return (player, provider)
    }

    @Test func rule() {
        let r = PlayerController.reconciledDuration
        #expect(r(346, 406) == 406) // another cut: the stream wins
        #expect(r(346, 347.5) == 346) // the same recording: keep the catalog's, so the player matches the album
        #expect(r(346, 344.5) == 346)
        #expect(r(nil, 231) == 231)
        #expect(r(200, nil) == 200)
        #expect(r(200, .nan) == 200)
        #expect(r(0, 100) == 100)
        #expect(r(nil, nil) == nil)
    }

    @Test func differentCutUpdatesPlayerAndEveryQueuedCopy() async {
        let (player, provider) = make()
        let veridis = makeTracks(1, prefix: "vq", duration: 346)[0]
        player.play([veridis, makeTracks(1)[0], veridis])
        await player.settle()
        provider.engine.duration = 406
        provider.engine.tick(1)
        #expect(player.duration == 406)
        #expect(player.queue.filter { $0.track.id == veridis.id }.allSatisfy { $0.track.duration == 406 })
    }

    @Test func smallDifferenceKeepsTheCatalogLength() async {
        let (player, provider) = make()
        player.play(makeTracks(1, duration: 346))
        await player.settle()
        provider.engine.duration = 347.4
        provider.engine.tick(1)
        #expect(player.duration == 346)
        #expect(player.current?.duration == 346)
    }

    @Test func currentEntryGetsTheLengthThePlayerKnows() async {
        let (player, provider) = make()
        player.play(withoutDurations(makeTracks(2)))
        await player.settle()
        #expect(player.current?.duration == nil)
        provider.engine.duration = 231
        provider.engine.tick(1)
        #expect(player.duration == 231)
        #expect(player.current?.duration == 231)
        #expect(player.upNext.first?.track.duration == nil)
    }

    @Test func historyKeepsTheLengthThatPlayed() async {
        let (player, provider) = make()
        player.play(makeTracks(2, duration: 346))
        await player.settle()
        provider.engine.duration = 406
        provider.engine.play(until: 31)
        player.next()
        await player.settle()
        #expect(player.listeningHistory.first?.track.duration == 406)
    }

    @Test func lengthResolvedForTheNextSongFillsItsRow() async {
        let (player, provider) = make()
        let tracks = withoutDurations(makeTracks(3))
        player.play(tracks)
        await player.settle()
        provider.engine.onDurationResolved?(tracks[1].id, 200)
        #expect(player.upNext.map(\.track.duration) == [200, nil])
    }

    @Test func resolvedLengthBeforeTheFirstTickShowsInThePlayer() async {
        let (player, provider) = make()
        let tracks = makeTracks(1, duration: 346)
        player.play(tracks)
        await player.settle()
        provider.engine.onDurationResolved?(tracks[0].id, 406)
        #expect(player.duration == 406)
        #expect(player.current?.duration == 406)
    }

    @Test func radioListingsFillQueuedSongsWithoutLengths() async {
        let (player, provider) = make()
        // Artist top songs: no lengths. Autoplay radio returns one of them with a length.
        let top = withoutDurations(makeTracks(2, prefix: "top"))
        var listed = top[0]
        listed.duration = 180
        provider.radioResult = [listed] + makeTracks(3, prefix: "r", duration: 210)
        player.autoplay = true
        player.play(top, startAt: 1)
        await player.settle()
        #expect(player.queue[0].track.duration == 180)
        #expect(player.upNext.allSatisfy { $0.track.duration == 210 })
    }

    @Test func learnedLengthsApplyToLaterQueues() async {
        let (player, provider) = make()
        let song = makeTracks(1, duration: 346)
        player.play(song)
        await player.settle()
        provider.engine.duration = 406
        provider.engine.tick(1)
        player.play(makeTracks(2, prefix: "x") + song, startAt: 0)
        await player.settle()
        #expect(player.queue.last?.track.duration == 406)
    }
}
