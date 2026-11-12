import Foundation
import MedleyCore
@testable import MedleySync
import Testing
@testable import Medley

/// Playing a playlist whose later pages are still to load: a transport choice made meanwhile wins over a start still
/// loading (but not over a playlist already playing and filling in), and a page that fails or a cancelled task never
/// turns into a queue of part of the playlist.
@MainActor
@Suite struct PlaylistPlaybackTests {
    private func setUp() async throws -> (AppModel, MockProvider, Playlist, PlaylistDetail, Track) {
        let model = AppModel(environment: ["MEDLEY_MOCK": "1"])
        model.noticeDuration = .seconds(30)
        await model.refreshLibraryState()
        let sp = try #require(model.providers.first { $0.id == .spotify } as? MockProvider)
        var found: (Playlist, PlaylistDetail)?
        for p in sp.catalog.playlists {
            if let detail = try? await sp.playlist(id: p.providerID), detail.continuation != nil { found = (p, detail); break }
        }
        let (playlist, detail) = try #require(found)
        let song = try #require(sp.catalog.allTracks.first { $0.isPlayable && !detail.tracks.contains($0) })
        // Something is playing already: the queue a failed or superseded start must leave alone.
        model.play([song], from: AppModel.PlayingFrom(title: song.title))
        return (model, sp, playlist, detail, song)
    }

    private func context(_ playlist: Playlist) -> AppModel.PlayingFrom {
        AppModel.PlayingFrom(title: playlist.title, route: .playlist(playlist.provider, id: playlist.providerID, preview: playlist))
    }

    private func userQueue(_ model: AppModel) -> [String] {
        model.player.queue.filter { !$0.isAutoplay }.map(\.track.id)
    }

    private func wholePlaylist(_ sp: MockProvider, _ detail: PlaylistDetail) async throws -> [Track] {
        var all = detail.tracks
        var token = detail.continuation
        while let t = token {
            let page = try await sp.playlistTracks(continuation: t)
            all += page.items.filter { s in !all.contains { $0.id == s.id } }
            token = page.continuation
        }
        return all
    }

    // MARK: Transport choices while a sorted playlist loads

    enum Transport: String, CaseIterable { case pause, togglePlayPause, next, seek, mediaKeyPause, syncPause, syncNext, syncSeek }

    /// A remote command arriving from another device, run by a coordinator wired as `SyncHub` wires the Mac's.
    private func runRemote(_ command: SyncCommand, on model: AppModel) async {
        let store = FileCredentialStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("medley-sync-\(UUID().uuidString).json"))
        let coordinator = SyncCoordinator(service: SyncService(deviceInfo: .current(), credentials: store), player: model.player)
        SyncHub.routeTransport(of: coordinator, to: model)
        let incoming = IncomingCommand(id: CommandID(rawValue: "remote-1"), fromDeviceId: DeviceID("phone"), command: command,
                                       createdAt: 0, expiresAt: .greatestFiniteMagnitude)
        _ = await coordinator.execute(incoming)
    }

    @Test(arguments: Transport.allCases)
    func aTransportChoiceWhileASortedPlaylistLoadsKeepsTheQueue(_ action: Transport) async throws {
        let (model, sp, playlist, detail, song) = try await setUp()
        // The media keys reach the model through the Now Playing center's hook (set at launch).
        model.playback.nowPlaying.willRunTransportCommand = { [weak model] in model?.noteTransportChoice() }
        sp.latency = .milliseconds(200)
        let task = Task { await model.playPlaylistSorted(detail.tracks, continuation: detail.continuation, provider: .spotify, sort: .title, from: context(playlist)) }
        try await Task.sleep(for: .milliseconds(60))
        switch action {
        case .pause: model.pause()
        case .togglePlayPause: model.togglePlayPause()
        case .next: model.next()
        case .seek: model.seek(to: 10)
        case .mediaKeyPause:
            // What `NowPlayingCenter`'s pause command runs.
            model.playback.nowPlaying.willRunTransportCommand?()
            model.player.pause()
        case .syncPause: await runRemote(.pause, on: model)
        case .syncNext: await runRemote(.next, on: model)
        case .syncSeek: await runRemote(.seek(positionMs: 10_000), on: model)
        }
        await task.value
        // The sorted playlist never replaced what was there.
        #expect(model.playingFrom?.title == song.title)
        #expect(!userQueue(model).contains(detail.tracks[0].id))
        if action == .pause || action == .togglePlayPause || action == .mediaKeyPause || action == .syncPause {
            #expect(model.player.current?.id == song.id)
            #expect(!model.player.isPlaying)
        }
        #expect(model.notice == nil)
    }

    /// A takeover from another device replaces the queue: a playlist already playing here (its next page still
    /// loading) is no longer the newest choice, so that page doesn't land in the queue that came from the other device.
    @Test func aTakeoverStopsAPlayingPlaylistAppendingItsPages() async throws {
        let (model, sp, playlist, detail, _) = try await setUp()
        // The playlist's second page waits until the test lets it go.
        final class Gate { var release: CheckedContinuation<Void, Never>? }
        let gate = Gate()
        sp.playlistPageGate = { _ in await withCheckedContinuation { gate.release = $0 } }
        let task = Task { await model.playPlaylist(detail.tracks, continuation: detail.continuation, provider: .spotify, from: context(playlist)) }
        for _ in 0..<200 where gate.release == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(gate.release != nil, "the second page was asked for")
        #expect(model.player.current?.id == detail.tracks[0].id)

        // The other device's queue: songs that aren't in the playlist.
        let handed = sp.catalog.allTracks.filter { $0.isPlayable && !detail.tracks.contains($0) }.suffix(3).map { QueueEntry(track: $0) }
        let state = HandoffState(queue: Array(handed), index: 0,
                                 anchor: PlaybackAnchor(positionMs: 0, positionAt: 0, isPlaying: true, durationMs: nil, volume: 1, shuffle: false, repeat: .off))
        await runRemote(.takeOver(state), on: model)
        #expect(model.player.queue.map(\.uid) == handed.map(\.uid))

        sp.playlistPageGate = nil
        gate.release?.resume()
        await task.value
        #expect(model.player.queue.filter { !$0.isAutoplay }.map(\.uid) == handed.map(\.uid), "no page of the playlist was appended")
    }

    @Test func pauseDoesNotStopAPlayingPlaylistFillingIn() async throws {
        let (model, sp, playlist, detail, _) = try await setUp()
        let all = try await wholePlaylist(sp, detail)
        sp.latency = .milliseconds(120)
        let task = Task { await model.playPlaylist(detail.tracks, continuation: detail.continuation, provider: .spotify, from: context(playlist)) }
        // Started at once from the first page; paused while the rest loads.
        for _ in 0..<60 where !(model.player.current?.id == detail.tracks[0].id && model.player.isPlaying) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.player.current?.id == detail.tracks[0].id)
        model.pause()
        await task.value
        // Every page arrived although the listener paused (the engine's own play/pause timing isn't checked here).
        #expect(userQueue(model) == all.map(\.id))
        #expect(model.playingFrom == context(playlist))
    }

    // MARK: A page that fails, a cancelled task

    @Test func aLaterPageFailingLeavesTheQueueAndOffersTryAgain() async throws {
        let (model, sp, playlist, detail, song) = try await setUp()
        let token = try #require(detail.continuation)
        sp.playlistPageFailures[token] = (.network("offline"), 1)
        let sort = TrackSort(key: .title, ascending: false)
        await model.playPlaylistSorted(detail.tracks, continuation: detail.continuation, provider: .spotify, sort: sort, from: context(playlist))
        // No partial sorted queue: the song that was playing still is.
        #expect(model.player.current?.id == song.id)
        #expect(userQueue(model) == [song.id])
        let notice = try #require(model.notice)
        #expect(notice.kind == .failure)
        #expect(notice.text.hasPrefix("Couldn’t play “\(playlist.title)”"))
        let retry = try #require(notice.retry)
        // Try Again, with the service back: the whole playlist in the order shown.
        retry()
        let all = try await wholePlaylist(sp, detail)
        let expected = sort.sorted(all, length: { model.displayDuration(for: $0) })
        for _ in 0..<100 where model.playingFrom?.title != playlist.title { try await Task.sleep(for: .milliseconds(10)) }
        #expect(userQueue(model) == expected.map(\.id))
    }

    @Test func cancellingDuringADelayedPageStartsNothing() async throws {
        let (model, sp, playlist, detail, song) = try await setUp()
        sp.latency = .milliseconds(200)
        let task = Task { await model.playPlaylistSorted(detail.tracks, continuation: detail.continuation, provider: .spotify, sort: .title, from: context(playlist)) }
        try await Task.sleep(for: .milliseconds(60))
        task.cancel()
        await task.value
        #expect(model.player.current?.id == song.id)
        #expect(userQueue(model) == [song.id])
        #expect(model.notice == nil)
    }

    @Test func shuffleWithAFailingPageShufflesNothing() async throws {
        let (model, sp, playlist, detail, song) = try await setUp()
        sp.playlistPageFailures[try #require(detail.continuation)] = (.network("offline"), 1)
        await model.playPlaylist(detail.tracks, continuation: detail.continuation, provider: .spotify, shuffled: true, from: context(playlist))
        #expect(model.player.current?.id == song.id)
        #expect(userQueue(model) == [song.id])
        #expect(model.notice?.kind == .failure)
        #expect(model.notice?.retry != nil)
    }

    @Test func aPlayingPlaylistWhosePageFailsKeepsPlayingAndTryAgainGoesOn() async throws {
        let (model, sp, playlist, detail, _) = try await setUp()
        let token = try #require(detail.continuation)
        sp.playlistPageFailures[token] = (.network("offline"), 1)
        await model.playPlaylist(detail.tracks, continuation: detail.continuation, provider: .spotify, from: context(playlist))
        // The first page plays; the failure says the rest didn't come.
        #expect(model.player.current?.id == detail.tracks[0].id)
        #expect(userQueue(model) == detail.tracks.map(\.id))
        let notice = try #require(model.notice)
        #expect(notice.text.hasPrefix("Couldn’t load the rest of “\(playlist.title)”"))
        let retry = try #require(notice.retry)
        retry()
        let all = try await wholePlaylist(sp, detail)
        for _ in 0..<100 where userQueue(model).count < all.count { try await Task.sleep(for: .milliseconds(10)) }
        #expect(userQueue(model) == all.map(\.id))
    }

    @Test func addToQueueOfAPlaylistWithAFailingPageAddsNothing() async throws {
        let (model, sp, playlist, detail, song) = try await setUp()
        sp.playlistPageFailures[try #require(detail.continuation)] = (.network("offline"), 1)
        model.addToQueue(.playlist(playlist))
        for _ in 0..<100 where model.notice == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(userQueue(model) == [song.id])
        #expect(model.notice?.kind == .failure)
    }

    /// Play Next / Add to Queue of a playlist whose page fails: the failure's Try Again repeats the command itself.
    @Test(arguments: [false, true])
    func queueingAPlaylistThatFailsOffersTryAgainThatQueuesIt(_ next: Bool) async throws {
        let (model, sp, playlist, detail, song) = try await setUp()
        sp.playlistPageFailures[try #require(detail.continuation)] = (.network("offline"), 1)
        if next { model.playNext(.playlist(playlist)) } else { model.addToQueue(.playlist(playlist)) }
        for _ in 0..<100 where model.notice == nil { try await Task.sleep(for: .milliseconds(10)) }
        let notice = try #require(model.notice)
        #expect(notice.kind == .failure)
        #expect(userQueue(model) == [song.id])
        let retry = try #require(notice.retry, "Try Again on a queue command's failure")
        model.dismissNotice()
        retry()
        for _ in 0..<100 where model.notice == nil { try await Task.sleep(for: .milliseconds(10)) }
        let all = try await wholePlaylist(sp, detail)
        #expect(userQueue(model) == [song.id] + all.map(\.id))
        #expect(model.notice?.text == (next ? "Playing next" : "Added to queue"))
    }

    // MARK: Past the page bound

    /// The playlist grown to at least four 25-song pages, and its fresh first page.
    private func longPlaylist(_ sp: MockProvider, _ playlist: Playlist) async throws -> PlaylistDetail {
        let have = Set(try await wholePlaylist(sp, try await sp.playlist(id: playlist.providerID)).map(\.id))
        let more = sp.catalog.allTracks.filter { !have.contains($0.id) }.prefix(max(0, 100 - have.count))
        try await sp.add(Array(more), toPlaylist: playlist.providerID)
        return try await sp.playlist(id: playlist.providerID)
    }

    @Test func remainingPagesPastTheBoundThrowWithThePartLoaded() async throws {
        let (model, sp, playlist, _, _) = try await setUp()
        let detail = try await longPlaylist(sp, playlist)
        model.playlistPageLimit = 1
        let all = try await wholePlaylist(sp, detail)
        try #require(all.count > detail.tracks.count + 25, "a playlist with at least three pages")
        do {
            _ = try await model.remainingPlaylistTracks(after: detail.tracks, continuation: detail.continuation, provider: sp)
            Issue.record("returned a part as the whole playlist")
        } catch let partial as AppModel.PlaylistLoadIncomplete {
            #expect(partial.tracks.map(\.id) == Array(all.dropFirst(detail.tracks.count).prefix(partial.tracks.count)).map(\.id))
            #expect(!partial.tracks.isEmpty)
        }
    }

    @Test func sortedPlayPastTheBoundPlaysThePartLoadedAndSaysSo() async throws {
        let (model, sp, playlist, _, _) = try await setUp()
        let detail = try await longPlaylist(sp, playlist)
        model.playlistPageLimit = 1
        let all = try await wholePlaylist(sp, detail)
        let sort = TrackSort(key: .title, ascending: true)
        await model.playPlaylistSorted(detail.tracks, continuation: detail.continuation, provider: .spotify, sort: sort, from: context(playlist))
        let queued = userQueue(model)
        #expect(queued.count < all.count)
        #expect(model.playingFrom?.title == playlist.title)
        let notice = try #require(model.notice)
        #expect(notice.text == "Only the first \(queued.count) songs of “\(playlist.title)” could be loaded. Playing those in this order.")
        #expect(notice.kind == .failure)
        #expect(notice.retry == nil)
    }

    @Test func shufflePastTheBoundShufflesThePartLoadedAndSaysSo() async throws {
        let (model, sp, playlist, _, _) = try await setUp()
        let detail = try await longPlaylist(sp, playlist)
        model.playlistPageLimit = 1
        await model.playPlaylist(detail.tracks, continuation: detail.continuation, provider: .spotify, shuffled: true, from: context(playlist))
        let queued = userQueue(model)
        #expect(queued.count > detail.tracks.count)
        #expect(model.notice?.text == "Only the first \(queued.count) songs of “\(playlist.title)” could be loaded. Shuffling those.")
    }

    @Test func aPlayingPlaylistStoppedByTheBoundSaysSo() async throws {
        let (model, sp, playlist, _, _) = try await setUp()
        let detail = try await longPlaylist(sp, playlist)
        model.playlistPageLimit = 1
        let all = try await wholePlaylist(sp, detail)
        await model.playPlaylist(detail.tracks, continuation: detail.continuation, provider: .spotify, from: context(playlist))
        let queued = userQueue(model)
        #expect(queued.count < all.count)
        #expect(model.notice?.text == "Only the first \(queued.count) songs of “\(playlist.title)” could be loaded. Playing those.")
    }

    @Test func addToQueuePastTheBoundQueuesThePartLoadedAndSaysSo() async throws {
        let (model, sp, playlist, _, song) = try await setUp()
        _ = try await longPlaylist(sp, playlist)
        model.playlistPageLimit = 1
        model.addToQueue(.playlist(playlist))
        for _ in 0..<100 where model.notice == nil { try await Task.sleep(for: .milliseconds(10)) }
        let added = userQueue(model).count - 1
        #expect(userQueue(model).first == song.id)
        #expect(model.notice?.text == "Only the first \(added) songs of “\(playlist.title)” could be loaded. Added those to the queue.")
    }

    /// A playlist past the page bound dropped on Playing Next: the one notice left says which part went, and stays
    /// until closed (the drop's "Added to queue" doesn't replace the incomplete warning).
    @Test func aTruncatedPlaylistDroppedOnTheQueueSaysWhichPartWent() async throws {
        let (model, sp, playlist, _, song) = try await setUp()
        _ = try await longPlaylist(sp, playlist)
        model.playlistPageLimit = 1
        #expect(model.dropOnQueue([MediaDragItem(.playlist(playlist))], at: .addToQueue))
        await model.lastDrop?.value
        let added = userQueue(model).count - 1
        #expect(added > 0)
        #expect(userQueue(model).first == song.id)
        let notice = try #require(model.notice)
        #expect(notice.text == "Added the first \(added) songs of “\(playlist.title)” to the queue")
        #expect(notice.kind == .failure)
        #expect(notice.retry == nil)
    }

    /// The same dropped on a playlist: "Added the first N songs of “X” to “P”", not "Added to P".
    @Test func aTruncatedPlaylistDroppedOnAPlaylistSaysWhichPartWent() async throws {
        let (model, sp, playlist, _, _) = try await setUp()
        _ = try await longPlaylist(sp, playlist)
        model.playlistPageLimit = 1
        let target = try #require(model.editablePlaylists(.spotify).first { $0.providerID != playlist.providerID })
        let before = sp.catalog.playlistTracks[target.providerID]?.count ?? 0
        #expect(model.drop([MediaDragItem(.playlist(playlist))], on: target))
        await model.lastDrop?.value
        let added = (sp.catalog.playlistTracks[target.providerID]?.count ?? 0) - before
        #expect(added > 0)
        let notice = try #require(model.notice)
        #expect(notice.text == "Added the first \(added) songs of “\(playlist.title)” to “\(target.title)”")
        #expect(notice.kind == .failure)
    }

    @Test func remainingPagesThrowWhenAPageFails() async throws {
        let (model, sp, _, detail, _) = try await setUp()
        sp.playlistPageFailures[try #require(detail.continuation)] = (.network("offline"), 1)
        await #expect(throws: ProviderError.self) {
            _ = try await model.remainingPlaylistTracks(after: detail.tracks, continuation: detail.continuation, provider: sp)
        }
    }
}
