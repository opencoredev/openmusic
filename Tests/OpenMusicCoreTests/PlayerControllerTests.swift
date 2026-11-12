import Foundation
import Testing
@testable import OpenMusicCore

/// Queue behavior against the shared `MockProvider` (the same one the UI uses).
@MainActor
struct PlayerControllerMockProviderTests {
    func make() -> (PlayerController, MockProvider) {
        let player = PlayerController()
        let provider = MockProvider(id: .youtubeMusic)
        player.register(provider)
        player.autoplay = false
        return (player, provider)
    }

    @Test func playStartsAtIndex() async throws {
        let (player, provider) = make()
        let tracks = provider.sampleTracks(5)
        player.play(tracks, startAt: 2)
        #expect(player.current?.id == tracks[2].id)
        #expect(player.upNext.count == 2)
        #expect(player.previousEntries.count == 2)
        await player.settle()
        #expect(player.state == .playing)
    }

    @Test func playNextInsertsAfterCurrent() async throws {
        let (player, provider) = make()
        let tracks = provider.sampleTracks(3)
        player.play(tracks)
        let extra = provider.sampleTracks(1, seed: "x")
        player.playNext(extra)
        #expect(player.upNext.first?.track.id == extra[0].id)
    }

    @Test func nextAndPreviousMove() async throws {
        let (player, provider) = make()
        let tracks = provider.sampleTracks(3)
        player.play(tracks)
        player.next()
        #expect(player.current?.id == tracks[1].id)
        player.previous()
        #expect(player.current?.id == tracks[0].id)
    }

    @Test func shuffleKeepsCurrentAndRestoresOrder() async throws {
        let (player, provider) = make()
        let tracks = provider.sampleTracks(10)
        player.play(tracks)
        player.shuffle = true
        #expect(player.current?.id == tracks[0].id)
        #expect(player.queue.count == 10)
        player.shuffle = false
        #expect(player.queue.map(\.track.id) == tracks.map(\.id))
    }

    @Test func autoplayExtendsFromMockRadioWithoutDuplicates() async throws {
        let (player, provider) = make()
        player.autoplay = true
        let seeds = provider.sampleTracks(2)
        player.play(seeds)
        await player.settle()
        // Up Next had fewer than 2 entries, so radio was fetched right away.
        let radio = try await provider.radio(seed: seeds[1])
        let expected = Set(radio.map(\.id)).subtracting(seeds.map(\.id)).count
        #expect(expected > 0)
        #expect(player.queue.count == 2 + min(expected, 25))
        #expect(Set(player.queue.map(\.track.id)).count == player.queue.count)
        #expect(player.queue.dropFirst(2).allSatisfy { $0.isAutoplay })
        #expect(player.queue.last?.context == .autoplay)
    }
}

/// Queue behavior with a scriptable engine, for failure, race and engine-call assertions.
@MainActor
struct PlayerControllerTests {
    let scheduler = ManualScheduler()

    func make(autoplay: Bool = false) -> (PlayerController, FakeProvider) {
        let player = PlayerController(scheduler: scheduler)
        let provider = FakeProvider()
        player.register(provider)
        player.autoplay = autoplay
        return (player, provider)
    }

    // MARK: play

    @Test func playSkipsUnplayableStartTrack() async {
        let (player, _) = make()
        var tracks = makeTracks(5)
        tracks[2].isPlayable = false
        player.play(tracks, startAt: 2)
        #expect(player.current?.id == tracks[3].id)
        #expect(player.queue.count == 4)
    }

    @Test func playWithDuplicateTracksStartsAtExactIndex() async {
        let (player, _) = make()
        let t = makeTracks(1)[0]
        player.play([t, t, t], startAt: 1)
        #expect(player.currentIndex == 1)
        #expect(player.previousEntries.count == 1)
        #expect(Set(player.queue.map(\.uid)).count == 3)
    }

    @Test func playIgnoresAllUnplayable() async {
        let (player, _) = make()
        var tracks = makeTracks(2)
        tracks[0].isPlayable = false
        tracks[1].isPlayable = false
        player.play(tracks)
        #expect(player.queue.isEmpty)
        #expect(player.state == .idle)
    }

    @Test func playLoadsTrackAndPreparesNext() async {
        let (player, provider) = make()
        let tracks = makeTracks(3)
        player.play(tracks)
        await player.settle()
        #expect(provider.engine.lastLoad == .init(trackID: tracks[0].id, startAt: 0, autoplay: true))
        #expect(provider.engine.lastPrepared == tracks[1].id)
        #expect(player.state == .playing)
    }

    // MARK: context

    @Test func contextLabelFollowsTheCurrentEntry() async {
        let (player, _) = make()
        let album = Album(providerID: "al1", provider: .youtubeMusic, title: "Discovery")
        player.play(makeTracks(2), from: .album(album))
        #expect(player.sourceLabel == "Playing from Discovery")
        player.playNext(makeTracks(1, prefix: "q"))
        player.next()
        #expect(player.current?.id == "youtubeMusic:q0")
        #expect(player.sourceLabel == nil)
        player.next()
        #expect(player.sourceLabel == "Playing from Discovery")
        #expect(PlaybackContext.radio(title: "Daft Punk").label == "Playing from Daft Punk Radio")
        #expect(PlaybackContext.autoplay.label == "Autoplay")
    }

    @Test func playRadioStartsWithSeedAndRadioContext() async {
        let (player, provider) = make()
        let seed = makeTracks(1, prefix: "seed")[0]
        provider.radioResult = [seed] + makeTracks(5, prefix: "r")
        await player.playRadio(seed: seed)
        #expect(player.queue.map(\.track.id) == [seed.id] + makeTracks(5, prefix: "r").map(\.id))
        #expect(player.sourceLabel == "Playing from SEED 0 Radio")
    }

    // MARK: insert / add / move / remove

    @Test func playNextStacksMostRecentFirst() async {
        let (player, _) = make()
        player.play(makeTracks(3))
        let a = makeTracks(1, prefix: "a")
        let b = makeTracks(1, prefix: "b")
        player.playNext(a)
        player.playNext(b)
        #expect(player.upNext.prefix(2).map(\.track.id) == [b[0].id, a[0].id])
        #expect(player.upNext.prefix(2).allSatisfy { $0.isUserQueued })
    }

    @Test func addToQueueGoesBeforeAutoplayEntries() async {
        let (player, provider) = make(autoplay: true)
        provider.radioResult = makeTracks(3, prefix: "r")
        player.play(makeTracks(1))
        await player.settle()
        #expect(player.queue.count == 4)
        let added = makeTracks(1, prefix: "u")
        player.addToQueue(added)
        #expect(player.queue[1].track.id == added[0].id)
        #expect(player.queue[2...].allSatisfy { $0.isAutoplay })
    }

    @Test func insertAtIndexClampsIntoUpNext() async {
        let (player, _) = make()
        let tracks = makeTracks(5)
        player.play(tracks, startAt: 2)
        let x = makeTracks(1, prefix: "x")
        player.insert(x, at: 0)
        #expect(player.currentIndex == 2)
        #expect(player.queue[3].track.id == x[0].id)
        let y = makeTracks(1, prefix: "y")
        player.insert(y, at: 99)
        #expect(player.queue.last?.track.id == y[0].id)
        let z = makeTracks(1, prefix: "z")
        player.insert(z, atUpNextOffset: 1)
        #expect(player.upNext.map(\.track.id)[1] == z[0].id)
        #expect(player.current?.id == tracks[2].id)
    }

    @Test func insertWithEmptyQueuePlays() async {
        let (player, _) = make()
        let x = makeTracks(2, prefix: "x")
        player.insert(x, at: 5)
        #expect(player.current?.id == x[0].id)
    }

    @Test func moveKeepsCurrentEntry() async {
        let (player, _) = make()
        let tracks = makeTracks(5)
        player.play(tracks, startAt: 1)
        // Move the current entry to the end.
        player.move(fromOffsets: IndexSet(integer: 1), toOffset: 5)
        #expect(player.current?.id == tracks[1].id)
        #expect(player.currentIndex == 4)
        // Move two entries to the front.
        player.move(fromOffsets: IndexSet([2, 3]), toOffset: 0)
        #expect(player.queue.map(\.track.id) == [tracks[3], tracks[4], tracks[0], tracks[2], tracks[1]].map(\.id))
        #expect(player.current?.id == tracks[1].id)
        // Out of range offsets are ignored.
        player.move(fromOffsets: IndexSet(integer: 42), toOffset: 0)
        #expect(player.queue.count == 5)
    }

    @Test func moveUpNextUsesUpNextOffsets() async {
        let (player, _) = make()
        let tracks = makeTracks(5)
        player.play(tracks, startAt: 1)
        // Up Next is t2 t3 t4; move t4 to the front.
        player.moveUpNext(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(player.upNext.map(\.track.id) == [tracks[4], tracks[2], tracks[3]].map(\.id))
        #expect(player.current?.id == tracks[1].id)
    }

    @Test func moveUpNextByIdentityFollowsTheEntry() async {
        let (player, _) = make()
        let tracks = makeTracks(6)
        player.play(tracks, startAt: 0)
        // Up Next is t1 t2 t3 t4 t5. A drag starts on t3 (offset 2) and means "two places later".
        let dragged = player.upNext.first { $0.track.id == tracks[3].id }!.uid
        // Playback advances before the drop: Up Next is now t2 t3 t4 t5, t3 at offset 1.
        player.next()
        #expect(player.moveUpNext(uid: dragged, by: 2))
        #expect(player.upNext.map(\.track.id) == [tracks[2], tracks[4], tracks[5], tracks[3]].map(\.id))
        // Clamped at the ends, and earlier moves work too.
        #expect(player.moveUpNext(uid: dragged, by: -10))
        #expect(player.upNext.map(\.track.id) == [tracks[3], tracks[2], tracks[4], tracks[5]].map(\.id))
        // An entry that left Up Next (it is playing now) changes nothing.
        player.next()
        let before = player.queue.map(\.uid)
        #expect(!player.moveUpNext(uid: dragged, by: 1))
        #expect(player.queue.map(\.uid) == before)
    }

    @Test func removeUpNextByIdentityAfterAdvancing() async {
        let (player, _) = make()
        let tracks = makeTracks(5)
        player.play(tracks, startAt: 0)
        let doomed = player.upNext.first { $0.track.id == tracks[3].id }!.uid
        player.next()
        player.removeUpNext([doomed], undoManager: nil)
        #expect(player.upNext.map(\.track.id) == [tracks[2], tracks[4]].map(\.id))
    }

    @Test func removeBeforeCurrentShiftsIndex() async {
        let (player, _) = make()
        let tracks = makeTracks(4)
        player.play(tracks, startAt: 2)
        player.remove(player.queue[0].uid)
        #expect(player.currentIndex == 1)
        #expect(player.current?.id == tracks[2].id)
        player.removeUpNext(atOffsets: IndexSet(integer: 0))
        #expect(player.upNext.isEmpty)
    }

    @Test func removeCurrentAdvances() async {
        let (player, provider) = make()
        let tracks = makeTracks(3)
        player.play(tracks)
        await player.settle()
        player.remove(player.queue[0].uid)
        await player.settle()
        #expect(player.current?.id == tracks[1].id)
        #expect(provider.engine.lastLoad?.trackID == tracks[1].id)
        #expect(player.state == .playing)
    }

    @Test func removeLastCurrentEnds() async {
        let (player, provider) = make()
        let tracks = makeTracks(2)
        player.play(tracks, startAt: 1)
        await player.settle()
        player.remove(player.queue[1].uid)
        #expect(player.state == .ended)
        #expect(provider.engine.stops >= 1)
        player.remove(player.queue[0].uid)
        #expect(player.queue.isEmpty)
        #expect(player.current == nil)
        #expect(player.state == .idle)
    }

    @Test func clearUpNextKeepsHistoryAndCurrent() async {
        let (player, _) = make()
        player.play(makeTracks(5), startAt: 2)
        player.clearUpNext()
        #expect(player.queue.count == 3)
        #expect(player.currentIndex == 2)
    }

    /// A queue of: the current song, one song queued with Play Next, the rest of the album, then autoplay's songs.
    private func queueWithAutoplay() async -> (PlayerController, FakeProvider) {
        let (player, provider) = make(autoplay: true)
        provider.radioResult = makeTracks(3, prefix: "r")
        player.play(makeTracks(2))
        await player.settle()
        player.playNext(makeTracks(1, prefix: "x"))
        return (player, provider)
    }

    @Test func clearUpNextLeavesAutoplay() async {
        let (player, provider) = await queueWithAutoplay()
        #expect(player.queue.map(\.track.providerID) == ["t0", "x0", "t1", "r0", "r1", "r2"])
        let loads = provider.engine.loads.count
        let cleared = player.clearUpNext()
        #expect(cleared?.entries.map(\.track.providerID) == ["x0", "t1"])
        #expect(player.queue.map(\.track.providerID) == ["t0", "r0", "r1", "r2"])
        #expect(player.queue.dropFirst().allSatisfy { $0.isAutoplay })
        #expect(player.current?.providerID == "t0")
        #expect(provider.engine.loads.count == loads)
        // Nothing left to clear: autoplay's songs aren't Up Next.
        #expect(player.clearUpNext() == nil)
    }

    @Test func undoClearUpNextRestoresEntriesWithoutRestarting() async {
        let (player, provider) = await queueWithAutoplay()
        let before = player.queue
        let loads = provider.engine.loads.count
        let seeks = provider.engine.seeks.count
        let undo = UndoManager()
        undo.groupsByEvent = false

        undo.beginUndoGrouping()
        player.clearUpNext(undoManager: undo)
        undo.endUndoGrouping()
        #expect(player.queue.map(\.track.providerID) == ["t0", "r0", "r1", "r2"])
        #expect(undo.canUndo)
        #expect(undo.undoActionName == "Clear Up Next")

        undo.undo()
        // Same entries (uids, so the same rows), in the same order, with their flags and contexts.
        #expect(player.queue == before)
        #expect(player.queue[1].isUserQueued)
        #expect(!player.queue[2].isUserQueued && !player.queue[2].isAutoplay)
        #expect(player.current?.providerID == "t0")
        #expect(player.currentIndex == 0)
        #expect(provider.engine.loads.count == loads)
        #expect(provider.engine.seeks.count == seeks)
        #expect(player.state == .playing)

        // Redo removes those songs again; undoing that brings them back once more.
        #expect(undo.canRedo)
        #expect(undo.redoActionName == "Clear Up Next")
        undo.redo()
        #expect(player.queue.map(\.track.providerID) == ["t0", "r0", "r1", "r2"])
        undo.undo()
        #expect(player.queue == before)
    }

    @Test func clearUpNextIncludingAutoplayEmptiesEverythingAfterCurrent() async {
        let (player, _) = await queueWithAutoplay()
        player.clearUpNext(includingAutoplay: true)
        #expect(player.queue.map(\.track.providerID) == ["t0"])
    }

    @Test func undoClearUpNextIgnoresAReplacedQueue() async {
        let (player, _) = await queueWithAutoplay()
        let cleared = player.clearUpNext()
        player.play(makeTracks(2, prefix: "n"))
        let replaced = player.queue.map(\.uid)
        if let cleared { player.restoreUpNext(cleared) }
        #expect(player.queue.map(\.uid) == replaced)
    }

    @Test func undoClearUpNextKeepsSongsQueuedSince() async {
        let (player, _) = await queueWithAutoplay()
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        player.clearUpNext(undoManager: undo)
        undo.endUndoGrouping()
        player.addToQueue(makeTracks(1, prefix: "y"))
        undo.undo()
        #expect(player.queue.map(\.track.providerID) == ["t0", "x0", "t1", "y0", "r0", "r1", "r2"])
        #expect(Set(player.queue.map(\.uid)).count == player.queue.count)
    }

    @Test func undoRemoveFromQueueRestoresTheEntryInPlaceWithoutRestarting() async {
        let (player, provider) = await queueWithAutoplay()
        let before = player.queue
        let loads = provider.engine.loads.count
        let seeks = provider.engine.seeks.count
        let undo = UndoManager()
        undo.groupsByEvent = false

        // Remove a song from the middle of Up Next (t1, after the queued x0) and one of autoplay's (r1).
        let t1 = before[2], r1 = before[4]
        undo.beginUndoGrouping()
        player.removeUpNext([t1.uid], undoManager: undo)
        undo.endUndoGrouping()
        #expect(player.queue.map(\.track.providerID) == ["t0", "x0", "r0", "r1", "r2"])
        #expect(undo.undoActionName == "Remove “\(t1.track.title)”")
        undo.beginUndoGrouping()
        player.removeUpNext([r1.uid], undoManager: undo)
        undo.endUndoGrouping()
        #expect(player.queue.map(\.track.providerID) == ["t0", "x0", "r0", "r2"])

        undo.undo()
        #expect(player.queue.map(\.track.providerID) == ["t0", "x0", "r0", "r1", "r2"])
        #expect(player.queue[3] == r1)
        #expect(player.queue[3].isAutoplay)
        undo.undo()
        // Same entries (uids, flags, contexts) in the same order; the current song wasn't touched.
        #expect(player.queue == before)
        #expect(player.queue[2].uid == t1.uid)
        #expect(!player.queue[2].isUserQueued && !player.queue[2].isAutoplay)
        #expect(player.queue[1].isUserQueued)
        #expect(player.currentIndex == 0)
        #expect(provider.engine.loads.count == loads)
        #expect(provider.engine.seeks.count == seeks)
        #expect(player.state == .playing)

        // Redo removes it again, and Undo brings it back once more.
        #expect(undo.redoActionName == "Remove “\(t1.track.title)”")
        undo.redo()
        #expect(player.queue.map(\.track.providerID) == ["t0", "x0", "r0", "r1", "r2"])
        undo.undo()
        #expect(player.queue == before)
    }

    @Test func removingTheCurrentSongStillAdvancesWithoutUndo() async {
        let (player, _) = await queueWithAutoplay()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let current = player.queue[0]
        undo.beginUndoGrouping()
        player.removeUpNext([current.uid], undoManager: undo)
        undo.endUndoGrouping()
        #expect(player.current?.providerID == "x0")
        #expect(!player.queue.contains { $0.uid == current.uid })
    }

    // MARK: transport

    @Test func previousRestartsAfterThreeSeconds() async {
        let (player, provider) = make()
        let tracks = makeTracks(3)
        player.play(tracks, startAt: 1)
        await player.settle()
        provider.engine.play(until: 10)
        player.previous()
        #expect(player.current?.id == tracks[1].id)
        #expect(provider.engine.seeks.last == 0)
        player.previous()
        #expect(player.current?.id == tracks[0].id)
        player.previous()
        #expect(player.current?.id == tracks[0].id)
    }

    @Test func skipWhilePausedStaysPaused() async {
        let (player, provider) = make()
        let tracks = makeTracks(3)
        player.play(tracks)
        await player.settle()
        player.pause()
        #expect(player.state == .paused)
        player.next()
        await player.settle()
        #expect(provider.engine.lastLoad == .init(trackID: tracks[1].id, startAt: 0, autoplay: false))
        #expect(player.state == .paused)
    }

    @Test func finishAdvancesAndPlays() async {
        let (player, provider) = make()
        let tracks = makeTracks(2)
        player.play(tracks)
        await player.settle()
        provider.engine.finish()
        await player.settle()
        #expect(player.current?.id == tracks[1].id)
        #expect(provider.engine.lastLoad?.autoplay == true)
    }

    @Test func endOfQueueStopsAndResumeRestarts() async {
        let (player, provider) = make()
        let tracks = makeTracks(2)
        player.play(tracks, startAt: 1)
        await player.settle()
        provider.engine.finish()
        #expect(player.state == .ended)
        #expect(provider.engine.stops == 1)
        #expect(player.isPlaying == false)
        player.togglePlayPause()
        await player.settle()
        #expect(player.current?.id == tracks[0].id)
        #expect(player.state == .playing)
    }

    @Test func repeatAllWraps() async {
        let (player, provider) = make()
        let tracks = makeTracks(2)
        player.repeatMode = .all
        player.play(tracks, startAt: 1)
        await player.settle()
        #expect(provider.engine.lastPrepared == tracks[0].id)
        provider.engine.finish()
        await player.settle()
        #expect(player.currentIndex == 0)
        player.next()
        player.next()
        #expect(player.currentIndex == 0)
    }

    @Test func repeatOneReplaysOnFinishButNextAdvances() async {
        let (player, provider) = make()
        let tracks = makeTracks(3)
        player.play(tracks)
        await player.settle()
        player.repeatMode = .one
        #expect(provider.engine.lastPrepared == .some(nil))
        provider.engine.play(until: 50)
        provider.engine.finish()
        await player.settle()
        #expect(player.current?.id == tracks[0].id)
        #expect(provider.engine.loads.count == 1)
        #expect(provider.engine.seeks.last == 0)
        #expect(player.currentTime == 0)
        player.next()
        await player.settle()
        #expect(player.current?.id == tracks[1].id)
    }

    @Test func seekClampsToDuration() async {
        let (player, provider) = make()
        player.play(makeTracks(1, duration: 100))
        await player.settle()
        player.seek(to: 500)
        #expect(player.currentTime == 100)
        player.skip(by: -250)
        #expect(player.currentTime == 0)
        #expect(provider.engine.seeks == [100, 0])
    }

    // MARK: shuffle

    @Test func shuffleKeepsHistoryAndCurrent() async {
        let (player, _) = make()
        let tracks = makeTracks(12)
        player.play(tracks, startAt: 4)
        let history = player.previousEntries.map(\.uid)
        player.shuffle = true
        #expect(player.previousEntries.map(\.uid) == history)
        #expect(player.current?.id == tracks[4].id)
        #expect(Set(player.upNext.map(\.track.id)) == Set(tracks[5...].map(\.id)))
        player.shuffle = false
        #expect(player.queue.map(\.track.id) == tracks.map(\.id))
    }

    @Test func unshuffleAfterSkippingKeepsWhatWasHeard() async {
        let (player, _) = make()
        let tracks = makeTracks(10)
        player.play(tracks, shuffled: true)
        let start = player.current!
        player.next()
        player.next()
        let heard = player.queue.prefix(through: player.currentIndex!).map(\.uid)
        player.shuffle = false
        // History (what was actually played) and the current entry stay put.
        #expect(player.queue.prefix(through: player.currentIndex!).map(\.uid) == heard)
        // Up Next is the rest, back in album order.
        let rest = tracks.filter { t in !player.queue.prefix(through: player.currentIndex!).contains { $0.track.id == t.id } }
        #expect(player.upNext.map(\.track.id) == rest.map(\.id))
        #expect(player.queue.first?.track.id == start.id)
    }

    @Test func shufflePinsPlayNextAndKeepsAutoplayLast() async {
        let (player, provider) = make(autoplay: true)
        provider.radioResult = makeTracks(3, prefix: "r")
        let album = makeTracks(10, prefix: "c")
        player.play(album)
        await player.settle()
        // Reach the end so autoplay appends radio, then go back to the start of the album.
        player.jump(to: player.queue[9].uid)
        await player.settle()
        #expect(player.queue.count == 13)
        player.jump(to: player.queue[0].uid)
        await player.settle()
        let pinned = makeTracks(2, prefix: "p")
        player.playNext(pinned)

        player.shuffle = true
        #expect(player.upNext.prefix(2).map(\.track.id) == pinned.map(\.id))
        #expect(Set(player.upNext.dropFirst(2).prefix(9).map(\.track.id)) == Set(album.dropFirst().map(\.id)))
        #expect(player.queue.suffix(3).allSatisfy { $0.isAutoplay })

        // Play Next while shuffled lands next and stays next after unshuffle.
        let x = makeTracks(1, prefix: "x")
        player.playNext(x)
        player.shuffle = false
        #expect(player.upNext.map(\.track.id) == x.map(\.id) + pinned.map(\.id) + album.dropFirst().map(\.id) + makeTracks(3, prefix: "r").map(\.id))
    }

    @Test func playShuffledPutsChosenTrackFirst() async {
        let (player, _) = make()
        let tracks = makeTracks(20)
        player.play(tracks, startAt: 7, shuffled: true)
        #expect(player.currentIndex == 0)
        #expect(player.current?.id == tracks[7].id)
        #expect(player.shuffle)
        #expect(Set(player.queue.map(\.track.id)) == Set(tracks.map(\.id)))
        // A new play keeps shuffle on unless told otherwise.
        player.play(makeTracks(5, prefix: "n"), startAt: 0)
        #expect(player.shuffle)
        player.play(makeTracks(5, prefix: "m"), shuffled: false)
        #expect(!player.shuffle)
        #expect(player.current?.id == "youtubeMusic:m0")
    }

    // MARK: failures

    @Test func failedLoadsSkipToNextPlayable() async {
        let (player, provider) = make()
        let tracks = makeTracks(4)
        provider.engine.failingIDs = [tracks[0].id, tracks[1].id]
        player.play(tracks)
        await player.settle()
        #expect(player.current?.id == tracks[2].id)
        #expect(player.state == .playing)
        #expect(provider.engine.loads.map(\.trackID) == tracks.prefix(3).map(\.id))
    }

    @Test func allFailingStopsWithoutLooping() async {
        let (player, provider) = make()
        let tracks = makeTracks(3)
        provider.engine.failingIDs = Set(tracks.map(\.id))
        player.repeatMode = .all
        player.play(tracks)
        await player.settle()
        #expect(player.state == .failed)
        #expect(provider.engine.loads.count == 3)
        #expect(player.lastError?.contains("fake failure") == true)
        // Long queue: gives up after maxConsecutiveFailures.
        let many = makeTracks(20, prefix: "m")
        provider.engine.failingIDs = Set(many.map(\.id))
        player.play(many)
        await player.settle()
        #expect(provider.engine.loads.count == 3 + PlayerController.maxConsecutiveFailures)
        #expect(player.state == .failed)
    }

    @Test func skipAfterGivingUpTriesTheNextTrack() async {
        let (player, provider) = make()
        let tracks = makeTracks(7)
        provider.engine.failingIDs = Set(tracks.map(\.id))
        player.play(tracks)
        await player.settle()
        // Gave up after maxConsecutiveFailures, on the 5th entry.
        #expect(player.state == .failed)
        #expect(player.currentIndex == PlayerController.maxConsecutiveFailures - 1)
        provider.engine.failingIDs = []
        player.next()
        await player.settle()
        #expect(player.currentIndex == PlayerController.maxConsecutiveFailures)
        #expect(player.state == .playing)
    }

    @Test func midTrackFailureSkips() async {
        let (player, provider) = make()
        let tracks = makeTracks(3)
        player.play(tracks)
        await player.settle()
        provider.engine.failMidTrack()
        await player.settle()
        #expect(player.current?.id == tracks[1].id)
        #expect(player.state == .playing)
    }

    @Test func missingProviderCountsAsFailure() async {
        let (player, _) = make()
        let spotify = makeTracks(1, prefix: "s", provider: .spotify)
        let ytm = makeTracks(1, prefix: "y")
        player.play(spotify + ytm)
        await player.settle()
        #expect(player.current?.id == ytm[0].id)
    }

    // MARK: races and providers

    @Test func rapidSkipsSettleOnTheLastTrack() async {
        let (player, provider) = make()
        let tracks = makeTracks(6)
        provider.engine.holdLoads = true
        // Each load reaches the engine before the next skip, so three of them go stale mid-flight.
        player.play(tracks)
        #expect(await waitUntil { provider.engine.heldCount == 1 })
        player.next()
        #expect(await waitUntil { provider.engine.heldCount == 2 })
        player.next()
        #expect(await waitUntil { provider.engine.heldCount == 3 })
        player.next()
        #expect(player.current?.id == tracks[3].id)
        #expect(await waitUntil { provider.engine.heldCount == 4 })
        // Finish the newest first, then let the stale ones complete.
        provider.engine.release(at: 3)
        await waitUntil { player.state == .playing }
        let prepareCount = provider.engine.prepared.count
        provider.engine.release(at: 0)
        provider.engine.release(at: 0)
        provider.engine.release(at: 0)
        await player.settle()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(player.current?.id == tracks[3].id)
        #expect(player.currentIndex == 3)
        // Stale loads finishing late don't re-prepare old neighbors.
        #expect(provider.engine.prepared.count == prepareCount)
        #expect(provider.engine.lastPrepared == tracks[4].id)
    }

    @Test func skipsBeforeTheLoadTaskRunsNeverReachTheEngine() async {
        let (player, provider) = make()
        let tracks = makeTracks(4)
        player.play(tracks)
        player.next()
        player.next()
        await player.settle()
        try? await Task.sleep(for: .milliseconds(50))
        // The superseded loads would bump the engine's generation and cancel the real one.
        #expect(provider.engine.loads.map(\.trackID) == [tracks[2].id])
        #expect(player.current?.id == tracks[2].id)
        #expect(player.state == .playing)
    }

    @Test func switchingProvidersBeforeTheLoadRunsKeepsTheOldEngineSilent() async {
        let player = PlayerController(scheduler: scheduler)
        let ytm = FakeProvider(id: .youtubeMusic)
        let spotify = FakeProvider(id: .spotify)
        player.register(ytm)
        player.register(spotify)
        player.autoplay = false
        let a = makeTracks(1, prefix: "a", provider: .youtubeMusic)
        let b = makeTracks(1, prefix: "b", provider: .spotify)
        player.play(a + b)
        // Skip to the Spotify track before the queued YouTube load task gets to run.
        player.next()
        await player.settle()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(ytm.engine.loads.isEmpty)
        #expect(spotify.engine.loads.map(\.trackID) == [b[0].id])
        #expect(player.current?.id == b[0].id)
        #expect(player.state == .playing)
    }

    @Test func switchingProvidersStopsTheOldEngine() async {
        let player = PlayerController(scheduler: scheduler)
        let ytm = FakeProvider(id: .youtubeMusic)
        let spotify = FakeProvider(id: .spotify)
        player.register(ytm)
        player.register(spotify)
        player.autoplay = false
        let a = makeTracks(1, prefix: "a", provider: .youtubeMusic)
        let b = makeTracks(1, prefix: "b", provider: .spotify)
        player.play(a + b)
        await player.settle()
        // The next track belongs to another engine, so nothing is prepared across providers.
        #expect(ytm.engine.lastPrepared == .some(nil))
        player.next()
        await player.settle()
        #expect(ytm.engine.stops == 1)
        #expect(spotify.engine.lastLoad?.trackID == b[0].id)
        // Late events from the old engine are ignored.
        ytm.engine.emit(.state(.paused))
        ytm.engine.emit(.finished)
        #expect(player.state == .playing)
        #expect(player.current?.id == b[0].id)
    }

    // MARK: autoplay

    @Test func autoplayAtEndFetchesRadioOnceAndAdvances() async {
        let (player, provider) = make(autoplay: false)
        let tracks = makeTracks(2)
        player.play(tracks, startAt: 1)
        await player.settle()
        provider.radioResult = [tracks[0], tracks[1]] + makeTracks(3, prefix: "r") + makeTracks(3, prefix: "r")
        provider.holdRadio = true
        player.autoplay = true
        await waitUntil { provider.radioCalls.count == 1 }
        // Pressing Next repeatedly while the fetch runs doesn't start more fetches or skip ahead.
        player.next()
        player.next()
        provider.releaseRadio()
        await player.settle()
        #expect(provider.radioCalls.count == 1)
        #expect(player.queue.map(\.track.id) == tracks.map(\.id) + makeTracks(3, prefix: "r").map(\.id))
        #expect(player.current?.id == "youtubeMusic:r0")
    }

    /// Plays the last of two tracks with autoplay on and the radio fetch held, so the queue runs out
    /// while the fetch is pending.
    func playLastTrackWithRadioHeld() async -> (PlayerController, FakeProvider) {
        let (player, provider) = make(autoplay: true)
        provider.holdRadio = true
        provider.radioResult = makeTracks(3, prefix: "r")
        player.play(makeTracks(2), startAt: 1)
        await waitUntil { provider.radioCalls.count == 1 }
        return (player, provider)
    }

    /// A song picked from History while the queue waits on autoplay radio keeps playing when the radio lands.
    @Test func playNowWhileWaitingOnRadioIsNotSkipped() async {
        let (player, provider) = await playLastTrackWithRadioHeld()
        provider.engine.finish()
        let picked = makeTracks(1, prefix: "h")[0]
        player.playNow(picked)
        provider.releaseRadio()
        await player.settle()
        #expect(player.current?.id == picked.id)
        #expect(player.upNext.map(\.track.id).contains("youtubeMusic:r0"))
    }

    @Test func nextWhilePausedOnTheLastTrackCuesRadioPaused() async {
        let (player, provider) = await playLastTrackWithRadioHeld()
        player.pause()
        player.next()
        provider.releaseRadio()
        await player.settle()
        #expect(player.current?.id == "youtubeMusic:r0")
        #expect(provider.engine.lastLoad == .init(trackID: "youtubeMusic:r0", startAt: 0, autoplay: false))
        #expect(player.state == .paused)
    }

    @Test func pausingWhileWaitingOnRadioKeepsThePause() async {
        let (player, provider) = await playLastTrackWithRadioHeld()
        provider.engine.finish()
        player.pause()
        provider.releaseRadio()
        await player.settle()
        #expect(player.current?.id == "youtubeMusic:r0")
        #expect(provider.engine.lastLoad?.autoplay == false)
        #expect(player.state == .paused)
    }

    @Test func playWhileWaitingOnRadioPlaysTheNextTrack() async {
        let (player, provider) = await playLastTrackWithRadioHeld()
        player.pause()
        player.next()
        player.resume()
        provider.releaseRadio()
        await player.settle()
        #expect(player.current?.id == "youtubeMusic:r0")
        #expect(provider.engine.lastLoad?.autoplay == true)
        #expect(player.state == .playing)
    }

    @Test func stopWhileWaitingOnRadioDoesNotRestart() async {
        let (player, provider) = await playLastTrackWithRadioHeld()
        let tracks = makeTracks(2)
        provider.engine.finish()
        player.stop()
        let loads = provider.engine.loads.count
        provider.releaseRadio()
        await player.settle()
        #expect(provider.engine.loads.count == loads)
        #expect(player.current?.id == tracks[1].id)
        #expect(player.state == .paused)
        // The radio tracks still join Up Next for when the listener presses Play.
        #expect(player.upNext.count == 3)
    }

    @Test func autoplayRadioForAReplacedQueueIsDiscarded() async {
        let (player, provider) = make(autoplay: true)
        provider.holdRadio = true
        provider.radioResult = makeTracks(3, prefix: "r")
        player.play(makeTracks(1, prefix: "old"))
        await waitUntil { provider.radioCalls.count == 1 }
        let fresh = makeTracks(5, prefix: "new")
        provider.holdRadio = false
        player.play(fresh)
        provider.releaseRadio()
        await player.settle()
        #expect(!player.queue.contains { $0.track.id.contains(":r") })
        #expect(player.queue.map(\.track.id) == fresh.map(\.id))
    }

    @Test func autoplayWithEmptyRadioEndsAndDoesNotRefetch() async {
        let (player, provider) = make(autoplay: true)
        provider.radioResult = []
        player.play(makeTracks(1))
        await player.settle()
        #expect(provider.radioCalls.count == 1)
        provider.engine.finish()
        await player.settle()
        #expect(player.state == .ended)
        #expect(provider.radioCalls.count == 1)
    }
}
