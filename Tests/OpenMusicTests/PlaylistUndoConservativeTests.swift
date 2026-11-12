import Foundation
import OpenMusicCore
import Testing
@testable import OpenMusic

/// Sol's review of b0149fb: Undo puts songs back in place only when every entry of the playlist is identified and
/// unchanged, reads the playlist uncached, keeps an edit across a new token for the same account, appends only after
/// reading the whole playlist, and stops counting copies when the account changes.
@MainActor
@Suite struct PlaylistUndoConservativeTests {
    private let offline = ProviderError.network(URLError(.notConnectedToInternet).localizedDescription)

    /// An editable Spotify playlist, "Edits", holding `songs` in order.
    private func setUp(_ songs: (MockProvider) -> [Track], account: String? = nil) async throws -> (AppModel, MockProvider, Playlist, [Track]) {
        let model = AppModel(environment: ["OPENMUSIC_MOCK": "1"])
        model.noticeDuration = .seconds(30)
        let sp = try #require(model.providers.first { $0.id == .spotify } as? MockProvider)
        if let account { sp.sessionOverride = ProviderSession(generation: 0, identity: .account(id: account)) }
        let list = songs(sp)
        let playlist = try await sp.createPlaylist(title: "Edits", description: nil)
        try await sp.add(list, toPlaylist: playlist.providerID)
        return (model, sp, playlist, list)
    }

    private func setUp(_ count: Int, account: String? = nil) async throws -> (AppModel, MockProvider, Playlist, [Track]) {
        try await setUp({ Array($0.catalog.allTracks.prefix(count)) }, account: account)
    }

    private func entries(_ sp: MockProvider, _ playlist: Playlist) -> [String] {
        (sp.catalog.playlistTracks[playlist.providerID] ?? []).map(\.id)
    }

    private func undoManager() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        return undo
    }

    private func outsider(_ sp: MockProvider, _ songs: [Track]) throws -> Track {
        try #require(sp.catalog.allTracks.first { song in !songs.contains { $0.id == song.id } })
    }

    private func waitUntil(_ condition: () -> Bool, _ what: Comment) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), what)
    }

    private func turns(_ count: Int = 10) async throws {
        for _ in 0..<count { try await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: P1: entries the app can't identify

    /// [A, local L, B, local M, C], the local files left out of the pages and the service naming neither: remove B,
    /// another device swaps L and M. Undo can't see the swap, so it never puts B back in place: the changed-playlist
    /// notice instead.
    @Test func aSwapOfUnidentifiedEntriesNeverGetsAPositionalPutBack() async throws {
        let (model, sp, playlist, list) = try await setUp(5)
        let (a, l, b, m, c) = (list[0], list[1], list[2], list[3], list[4])
        sp.unlistedTrackIDs = [l.id, m.id]
        sp.unlistedEntriesAnonymous = true
        let undo = undoManager()
        await model.remove([b], from: playlist, undoManager: undo).value
        try await sp.remove([l, m], fromPlaylist: playlist.providerID)
        try await sp.insert([m, l], intoPlaylist: playlist.providerID, at: 1)
        let swapped = [a, m, l, c].map(\.id)
        #expect(entries(sp, playlist) == swapped)
        let calls = sp.playlistEdits.count

        undo.undo()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == swapped, "B not put between M and L")
        #expect(sp.playlistEdits.count == calls)
        #expect(model.notice?.text == "“Edits” changed since you removed this song.")
        #expect(model.notice?.action?.title == "Add Back at End")
    }

    /// The same playlist untouched: with unidentified entries in it, Undo still doesn't put B back in place.
    @Test func unidentifiedEntriesAlwaysTakeTheConservativePath() async throws {
        let (model, sp, playlist, list) = try await setUp(5)
        sp.unlistedTrackIDs = [list[1].id, list[3].id]
        sp.unlistedEntriesAnonymous = true
        let undo = undoManager()
        await model.remove([list[2]], from: playlist, undoManager: undo).value
        let after = entries(sp, playlist)
        undo.undo()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == after)
        #expect(model.notice?.action?.title == "Add Back at End")
    }

    /// Local files the service identifies (Spotify's `spotify:local:` URIs): a swap of them is seen, and an untouched
    /// playlist still gets its song back in place.
    @Test func identifiedLeftOutEntriesAreCompared() async throws {
        let (model, sp, playlist, list) = try await setUp(5)
        let (a, l, b, m, c) = (list[0], list[1], list[2], list[3], list[4])
        sp.unlistedTrackIDs = [l.id, m.id]
        let undo = undoManager()
        await model.remove([b], from: playlist, undoManager: undo).value
        try await sp.remove([l, m], fromPlaylist: playlist.providerID)
        try await sp.insert([m, l], intoPlaylist: playlist.providerID, at: 1)
        undo.undo()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == [a, m, l, c].map(\.id), "the swap is seen")
        #expect(model.notice?.action?.title == "Add Back at End")

        model.dismissNotice()
        try await sp.remove([m, l], fromPlaylist: playlist.providerID)
        try await sp.insert([l, m], intoPlaylist: playlist.providerID, at: 1)
        await model.remove([c], from: playlist, undoManager: undo).value
        undo.undo()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == [a, l, m, c].map(\.id), "unchanged: back in place")
    }

    // MARK: P1: uncached reads

    /// The removal's read, Undo's check and Add Back at End's read all go to the service uncached.
    @Test func everyReadOfAnEditIsUncached() async throws {
        let (model, sp, playlist, list) = try await setUp(30)
        let undo = undoManager()
        var reads = sp.playlistReads.count
        await model.remove([list[1]], from: playlist, undoManager: undo).value
        #expect(sp.playlistReads.dropFirst(reads).allSatisfy { $0.hasPrefix("fresh") }, "the removal's read")
        try await sp.insert([try outsider(sp, list)], intoPlaylist: playlist.providerID, at: 0)
        reads = sp.playlistReads.count
        undo.undo()
        await model.lastPlaylistEdit?.value
        #expect(sp.playlistReads.count - reads == 2)
        #expect(sp.playlistReads.dropFirst(reads).allSatisfy { $0.hasPrefix("fresh") }, "Undo's check")
        reads = sp.playlistReads.count
        let addBack = try #require(model.notice?.action)
        addBack.run()
        await model.lastPlaylistEdit?.value
        #expect(sp.playlistReads.count - reads == 2)
        #expect(sp.playlistReads.dropFirst(reads).allSatisfy { $0.hasPrefix("fresh") }, "Add Back at End's read")
    }

    // MARK: P2: bound to the account, not to its token

    /// A sign-in synced from another device for the same account (a new token, a new session generation) keeps the
    /// settled removal's Undo, which still works.
    @Test func aSameUserTransferKeepsTheUndo() async throws {
        let (model, sp, playlist, list) = try await setUp(4, account: "listener")
        let before = entries(sp, playlist)
        let undo = undoManager()
        await model.remove([list[1]], from: playlist, undoManager: undo).value
        let session = sp.session
        sp.sessionOverride = session.next(.changing)
        try await turns()
        sp.sessionOverride = session.next(.changing).next(.account(id: "listener"))
        try await turns()
        #expect(undo.canUndo, "the Undo stays")
        #expect(model.notice?.action?.title == "Undo", "and the notice")
        undo.undo()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == before)
    }

    /// The same with a partly applied edit: it stays locked across the new token, and Try Again finishes it.
    @Test func aSameUserTransferKeepsAPartialEdit() async throws {
        let (model, sp, playlist, list) = try await setUp(4, account: "listener")
        sp.editBatchSize = 2
        sp.playlistEditFailures = [sp.playlistEdits.count + 2: offline]
        await model.remove([list[0], list[2], list[3]], from: playlist, undoManager: undoManager()).value
        let edit = try #require(model.partialEdit(of: playlist))
        sp.sessionOverride = sp.session.next(.changing)
        try await turns()
        sp.sessionOverride = sp.session.next(.account(id: "listener"))
        try await turns()
        #expect(model.partialEdit(of: playlist) === edit)
        model.tryAgain(edit)
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == [list[1].id])
        #expect(model.canEdit(playlist))
    }

    /// A sign-in synced from another device for another account drops the removal's Undo.
    @Test func aDifferentUserTransferDropsTheUndo() async throws {
        let (model, sp, playlist, list) = try await setUp(4, account: "listener")
        let undo = undoManager()
        await model.remove([list[1]], from: playlist, undoManager: undo).value
        let after = entries(sp, playlist)
        sp.sessionOverride = sp.session.next(.changing)
        try await turns()
        sp.sessionOverride = sp.session.next(.account(id: "someone-else"))
        try await waitUntil({ !undo.canUndo }, "the Undo goes")
        #expect(model.notice == nil)
        undo.undo()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == after)
    }

    /// No request goes out while the sign-in is being swapped: the run stops partway (Try Again), and once the swap
    /// settles on the same account Try Again finishes it.
    @Test func noWriteGoesOutWhileTheSignInIsChanging() async throws {
        let (model, sp, playlist, list) = try await setUp(6, account: "listener")
        sp.editBatchSize = 2
        var removals = 0
        sp.playlistEditGate = { kind in
            guard kind == "remove" else { return }
            removals += 1
            if removals == 1 { sp.sessionOverride = sp.session.next(.changing) }
        }
        await model.remove(Array(list.prefix(4)), from: playlist, undoManager: undoManager()).value
        #expect(removals == 1, "nothing sent while the credentials were changing")
        let edit = try #require(model.partialEdit(of: playlist))
        #expect(model.notice?.retry != nil)
        sp.playlistEditGate = nil
        sp.sessionOverride = sp.session.next(.account(id: "listener"))
        try await turns()
        model.tryAgain(edit)
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == list.suffix(2).map(\.id))
    }

    // MARK: P2: Add Back at End only after reading the whole playlist

    /// A service that hands out the same continuation again: the read is incomplete, so Add Back at End appends nothing
    /// and says it couldn't read the playlist, with Try Again; once the read is whole, Try Again appends the song.
    @Test func addBackAtEndNeedsTheWholePlaylist() async throws {
        let (model, sp, playlist, list) = try await setUp(30)
        let undo = undoManager()
        let song = list[1]
        await model.remove([song], from: playlist, undoManager: undo).value
        try await sp.insert([try outsider(sp, list)], intoPlaylist: playlist.providerID, at: 0)
        undo.undo()
        await model.lastPlaylistEdit?.value
        let changed = entries(sp, playlist)
        let addBack = try #require(model.notice?.action)
        sp.repeatsContinuations = true
        addBack.run()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == changed, "nothing appended from a partial read")
        let failure = try #require(model.notice)
        #expect(failure.text == "Couldn’t read all of “Edits”.")
        #expect(failure.kind == .failure)
        let retry = try #require(failure.retry)
        sp.repeatsContinuations = false
        model.dismissNotice()
        retry()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == changed + [song.id])
    }

    /// An append that stopped after its first song, then Try Again while the read is incomplete: nothing appended, the
    /// same notice; then Try Again with a whole read appends only the song still missing.
    @Test func tryAgainAfterAPartialAppendNeedsTheWholePlaylist() async throws {
        let (model, sp, playlist, list) = try await setUp(30)
        let undo = undoManager()
        let (b, c) = (list[1], list[2])
        await model.remove([b, c], from: playlist, undoManager: undo).value
        try await sp.insert([try outsider(sp, list)], intoPlaylist: playlist.providerID, at: 0)
        undo.undo()
        await model.lastPlaylistEdit?.value
        let changed = entries(sp, playlist)
        let addBack = try #require(model.notice?.action)
        sp.addFailure = (1, offline)
        addBack.run()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == changed + [b.id])
        let retry = try #require(model.notice?.retry)

        sp.repeatsContinuations = true
        model.dismissNotice()
        retry()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == changed + [b.id])
        #expect(model.notice?.text == "Couldn’t read all of “Edits”.")
        let again = try #require(model.notice?.retry)
        sp.repeatsContinuations = false
        model.dismissNotice()
        again()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == changed + [b.id, c.id], "C appended once, B not again")
    }

    // MARK: P2: the confirmation's count belongs to the account

    /// A service that asks before removing counts the song's copies over every page. The account changes while page 2
    /// is out: no later page is asked for, and no dialog or notice shows.
    @Test func aConfirmationCountStopsWhenTheAccountChanges() async throws {
        let (model, sp, playlist, list) = try await setUp(60)
        sp.capabilities.remove(.playlistInsert)
        let second = "\(playlist.providerID)|25", third = "\(playlist.providerID)|50"
        sp.playlistPageGate = { token in
            if token == second { sp.sessionOverride = sp.session.next(.account(id: "someone-else")) }
        }
        model.dismissNotice()
        model.requestRemove([list[3]], from: playlist, undoManager: undoManager())
        try await turns(30)
        #expect(sp.playlistPageRequests.contains(second))
        #expect(!sp.playlistPageRequests.contains(third), "no page read for the old account after the switch")
        #expect(model.pendingPlaylistRemoval == nil)
        #expect(model.notice == nil)
    }
}
