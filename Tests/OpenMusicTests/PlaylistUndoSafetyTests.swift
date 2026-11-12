import AppKit
import Foundation
import OpenMusicCore
import Testing
@testable import OpenMusic

/// Sol's round 36 review of single-level playlist Undo: a put-back checks the playlist first (changed outside OpenMusic:
/// no positional put-back, "Add Back at End" adds only what is missing), edits are bound to the account they began
/// under, and the Undo goes on the undo manager only at the top level, as a group of its own.
@MainActor
@Suite struct PlaylistUndoSafetyTests {
    private let offline = ProviderError.network(URLError(.notConnectedToInternet).localizedDescription)

    /// An editable Spotify playlist, "Edits", holding `count` songs in order, edited in requests of two songs.
    private func setUp(_ count: Int = 4) async throws -> (AppModel, MockProvider, Playlist, [Track]) {
        let model = AppModel(environment: ["OPENMUSIC_MOCK": "1"])
        model.noticeDuration = .seconds(30)
        let sp = try #require(model.providers.first { $0.id == .spotify } as? MockProvider)
        let songs = Array(sp.catalog.allTracks.prefix(count))
        #expect(songs.count == count)
        let playlist = try await sp.createPlaylist(title: "Edits", description: nil)
        try await sp.add(songs, toPlaylist: playlist.providerID)
        sp.editBatchSize = 2
        return (model, sp, playlist, songs)
    }

    private func entries(_ sp: MockProvider, _ playlist: Playlist) -> [String] {
        (sp.catalog.playlistTracks[playlist.providerID] ?? []).map(\.id)
    }

    private func undoManager(byEvent: Bool = false) -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = byEvent
        return undo
    }

    /// A song from the catalog that isn't in the playlist, as another device would add it.
    private func outsider(_ sp: MockProvider, _ songs: [Track]) throws -> Track {
        try #require(sp.catalog.allTracks.first { song in !songs.contains { $0.id == song.id } })
    }

    /// Polls the main actor (run loop turns included) until `condition` holds, for at most two seconds.
    private func waitUntil(_ condition: () -> Bool, _ what: Comment) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), what)
    }

    // MARK: P1: changed outside OpenMusic

    /// [A, B, C, D]; remove B; another device puts X first. Undo doesn't put B at place 1 ([X, B, A, C, D]): the
    /// notice says the playlist changed and offers Add Back at End, which appends B.
    @Test func undoAfterAnInsertElsewhereOffersAddBackAtEnd() async throws {
        let (model, sp, playlist, songs) = try await setUp()
        let (a, b, c, d) = (songs[0], songs[1], songs[2], songs[3])
        let x = try outsider(sp, songs)
        let undo = undoManager()
        await model.remove([b], from: playlist, undoManager: undo).value
        try await sp.insert([x], intoPlaylist: playlist.providerID, at: 0)
        let calls = sp.playlistEdits.count

        undo.undo()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == [x, a, c, d].map(\.id), "nothing put back at a stale place")
        #expect(sp.playlistEdits.count == calls, "no insert sent")
        let notice = try #require(model.notice)
        #expect(notice.text == "“Edits” changed since you removed this song.")
        #expect(notice.action?.title == "Add Back at End")
        #expect(notice.secondaryAction?.title == "Cancel")
        #expect(model.canEdit(playlist))

        let addBack = try #require(notice.action)
        addBack.run()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == [x, a, c, d, b].map(\.id), "B appended")
        #expect(model.canEdit(playlist))
        #expect(!undo.canUndo)
        #expect(!undo.canRedo)
    }

    /// [A, B, C, D]; remove B and C; another device adds B back. Add Back at End appends only C: B is never doubled.
    @Test func anExternalReAddIsNeverDuplicated() async throws {
        let (model, sp, playlist, songs) = try await setUp()
        let (a, b, c, d) = (songs[0], songs[1], songs[2], songs[3])
        let undo = undoManager()
        await model.remove([b, c], from: playlist, undoManager: undo).value
        try await sp.add([b], toPlaylist: playlist.providerID)

        undo.undo()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == [a, d, b].map(\.id))
        let notice = try #require(model.notice)
        #expect(notice.text == "“Edits” changed since you removed these songs.")
        let addBack = try #require(notice.action)
        addBack.run()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == [a, d, b, c].map(\.id), "only C appended")
    }

    /// Unchanged since the removal: Undo still puts the song back at its own place, and the check reads every page.
    @Test func withNoOutsideChangeUndoPutsBackInPlace() async throws {
        let (model, sp, playlist, songs) = try await setUp(60)
        let before = entries(sp, playlist)
        let undo = undoManager()
        let song = songs[40]
        await model.remove([song], from: playlist, undoManager: undo).value
        let calls = sp.playlistEdits.count
        let pages = sp.playlistPageRequests.count
        undo.undo()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == before)
        #expect(Array(sp.playlistEdits.dropFirst(calls)) == ["insert \(song.providerID) at 40"])
        #expect(sp.playlistPageRequests.count - pages == 2, "the check read pages 2 and 3")
        #expect(model.notice?.text == "Put “\(song.title)” back in “Edits”")
    }

    /// [A…G], requests of two: remove B, C, D; Undo stops after B and C are back (D's request fails). Another device
    /// puts X first. Try Again doesn't put D at a stale place: the notice offers Add Back at End, which appends only D.
    @Test func tryAgainOfAPartialPutBackChecksForOutsideChanges() async throws {
        let (model, sp, playlist, songs) = try await setUp(7)
        let (a, b, c, d) = (songs[0], songs[1], songs[2], songs[3])
        let x = try outsider(sp, songs)
        let undo = undoManager()
        await model.remove([b, c, d], from: playlist, undoManager: undo).value
        sp.playlistEditFailures = [sp.playlistEdits.count + 2: offline]
        undo.undo()
        await model.lastPlaylistEdit?.value
        let failure = try #require(model.notice)
        #expect(failure.kind == .failure)
        let retry = try #require(failure.retry)
        #expect(entries(sp, playlist) == [a, b, c].map(\.id) + songs.dropFirst(4).map(\.id))

        try await sp.insert([x], intoPlaylist: playlist.providerID, at: 0)
        let changed = entries(sp, playlist)
        let calls = sp.playlistEdits.count
        model.dismissNotice()
        retry()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == changed, "D not put back at a stale place")
        #expect(sp.playlistEdits.count == calls)
        let notice = try #require(model.notice)
        #expect(notice.text == "“Edits” changed since you removed these songs.")
        #expect(model.partialEdit(of: playlist) == nil, "the edit ended; the playlist is as the service has it")
        #expect(model.canEdit(playlist))
        let addBack = try #require(notice.action)
        addBack.run()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == changed + [d.id], "only D appended: B and C are back already")
    }

    /// Cancel on the changed-playlist notice leaves the playlist as the service has it, with no Undo left.
    @Test func cancelLeavesTheChangedPlaylistAlone() async throws {
        let (model, sp, playlist, songs) = try await setUp()
        let x = try outsider(sp, songs)
        let undo = undoManager()
        await model.remove([songs[1]], from: playlist, undoManager: undo).value
        try await sp.add([x], toPlaylist: playlist.providerID)
        let changed = entries(sp, playlist)
        undo.undo()
        await model.lastPlaylistEdit?.value
        let notice = try #require(model.notice)
        let addBack = try #require(notice.action)
        model.dismissNotice()
        let cancel = try #require(notice.secondaryAction)
        cancel.run()
        addBack.run()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == changed, "after Cancel the old Add Back at End does nothing")
        #expect(model.canEdit(playlist))
        #expect(!undo.canUndo)
    }

    // MARK: P2: edits are bound to the account they began under

    /// A removal in requests of two; the account changes while the second request is out. Nothing else is sent, and
    /// nothing is published for the old account: no notice, no Undo, no lock.
    @Test func switchingAccountsMidBatchStopsTheRemoval() async throws {
        let (model, sp, playlist, songs) = try await setUp(6)
        let undo = undoManager()
        var removals = 0
        sp.playlistEditGate = { kind in
            guard kind == "remove" else { return }
            removals += 1
            if removals == 2 { sp.sessionOverride = sp.session.next(.account(id: "someone-else")) }
        }
        model.dismissNotice()
        await model.remove(Array(songs.prefix(5)), from: playlist, undoManager: undo).value
        #expect(removals == 2, "no request after the switch")
        #expect(model.notice == nil, "nothing published for the old account")
        #expect(!undo.canUndo)
        #expect(model.partialEdit(of: playlist) == nil)
        try await waitUntil({ model.canEdit(playlist) }, "the lock is released")
    }

    /// A settled removal, then another account: its Undo leaves the Edit menu and the notice, and the old notice's
    /// Undo does nothing.
    @Test func undoAfterAnAccountSwitchDoesNothing() async throws {
        let (model, sp, playlist, songs) = try await setUp()
        let undo = undoManager()
        await model.remove([songs[1]], from: playlist, undoManager: undo).value
        let stale = try #require(model.notice?.action)
        #expect(undo.canUndo)
        sp.sessionOverride = sp.session.next(.account(id: "someone-else"))
        try await waitUntil({ !undo.canUndo }, "the Undo leaves the undo manager")
        #expect(model.notice == nil, "the notice goes")
        let after = entries(sp, playlist)
        stale.run()
        undo.undo()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == after)
    }

    /// A partly applied edit's Try Again after an account switch does nothing, and the lock is gone.
    @Test func aPartialEditsTryAgainAfterAnAccountSwitchDoesNothing() async throws {
        let (model, sp, playlist, songs) = try await setUp()
        sp.playlistEditFailures = [2: offline]
        await model.remove([songs[0], songs[2], songs[3]], from: playlist, undoManager: undoManager()).value
        let retry = try #require(model.notice?.retry)
        let partial = entries(sp, playlist)
        sp.sessionOverride = sp.session.next(.account(id: "someone-else"))
        try await waitUntil({ model.canEdit(playlist) }, "the lock is released")
        #expect(model.partialEdit(of: playlist) == nil)
        #expect(model.notice == nil)
        retry()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == partial)
    }

    /// Signing out ends a partly applied edit: the playlist is unlocked and its notice goes.
    @Test func signingOutReleasesTheLock() async throws {
        let (model, sp, playlist, songs) = try await setUp()
        sp.playlistEditFailures = [2: offline]
        await model.remove([songs[0], songs[2], songs[3]], from: playlist, undoManager: undoManager()).value
        #expect(!model.canEdit(playlist))
        await sp.signOut()
        try await waitUntil({ model.canEdit(playlist) }, "the lock is released")
        #expect(model.partialEdit(of: playlist) == nil)
        #expect(model.notice == nil)
    }

    // MARK: P2: an Undo group of its own, at the top level

    /// The queue's state the listener chose (Autoplay may fill in meanwhile).
    private func listened(_ model: AppModel) -> [String] { model.player.queue.filter { !$0.isAutoplay }.map(\.track.id) }

    /// The removal settles while an outer group is open (another component's), with the queue's Clear in it: the
    /// playlist edit's Undo waits for the top level, so one ⌘Z undoes the removal and the next the Clear.
    @Test func aRemovalSettlingInsideAnOpenGroupGetsAnUndoOfItsOwn() async throws {
        let (model, sp, playlist, songs) = try await setUp(7)
        let before = entries(sp, playlist)
        let undo = undoManager()
        model.player.play(Array(songs.prefix(1)), startAt: 0)
        model.player.addToQueue(Array(songs.dropFirst(4)))
        let queue = listened(model)

        undo.beginUndoGrouping()
        model.player.clearUpNext(undoManager: undo)
        await model.remove([songs[2]], from: playlist, undoManager: undo).value
        undo.endUndoGrouping()
        try await waitUntil({ undo.groupingLevel == 0 && undo.undoActionName == "Remove “\(songs[2].title)”" }, "registered once the group closed")

        undo.undo()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == before)
        #expect(listened(model).count == 1, "the queue's Clear wasn't undone with it")
        #expect(undo.canUndo)
        undo.undo()
        #expect(listened(model) == queue)
    }

    /// Default event grouping: a queue action registered in the same run-loop turn right after the playlist edit's
    /// Undo went on the manager gets its own ⌘Z.
    @Test func aQueueActionInTheSameTurnGetsItsOwnUndo() async throws {
        let (model, sp, playlist, songs) = try await setUp(7)
        let before = entries(sp, playlist)
        let undo = undoManager(byEvent: true)
        model.player.play(Array(songs.prefix(1)), startAt: 0)
        model.player.addToQueue(Array(songs.dropFirst(4)))
        let queue = listened(model)
        let song = songs[2]
        var cleared = false
        let observer = NotificationCenter.default.addObserver(forName: .NSUndoManagerDidCloseUndoGroup, object: undo, queue: nil) { _ in
            MainActor.assumeIsolated {
                guard !cleared, undo.undoActionName == "Remove “\(song.title)”" else { return }
                cleared = true
                model.player.clearUpNext(undoManager: undo)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        await model.remove([song], from: playlist, undoManager: undo).value
        try await waitUntil({ cleared && undo.groupingLevel == 0 }, "the queue's Clear went in the same turn")
        #expect(listened(model).count == 1)

        undo.undo()
        await model.lastPlaylistEdit?.value
        #expect(listened(model) == queue, "the first ⌘Z undid the Clear")
        #expect(!entries(sp, playlist).contains(song.id), "and not the removal")
        #expect(undo.undoActionName == "Remove “\(song.title)”")
        undo.undo()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == before)
    }

    /// A newer edit that starts before a deferred registration ran cancels it: only the newer one is undoable.
    @Test func aNewerEditCancelsADeferredRegistration() async throws {
        let (model, sp, playlist, songs) = try await setUp(7)
        let before = entries(sp, playlist)
        let undo = undoManager()
        undo.beginUndoGrouping()
        await model.remove([songs[1]], from: playlist, undoManager: undo).value
        await model.remove([songs[3]], from: playlist, undoManager: undo).value
        undo.endUndoGrouping()
        try await waitUntil({ undo.groupingLevel == 0 && undo.undoActionName == "Remove “\(songs[3].title)”" }, "the newer removal registered")
        undo.undo()
        await model.lastPlaylistEdit?.value
        let afterUndo = before.filter { $0 != songs[1].id }
        #expect(entries(sp, playlist) == afterUndo)
        // What is left is the outer group, which the undo manager keeps although it is empty: undoing it puts nothing
        // back, since the first removal never registered.
        try await Task.sleep(for: .milliseconds(100))
        if undo.canUndo { undo.undo() }
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == afterUndo, "the first removal never registered")
        #expect(!undo.canUndo)
    }
}
