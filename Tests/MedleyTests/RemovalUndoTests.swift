import Foundation
import MedleyCore
import Testing
@testable import Medley

/// "Remove from Playlist" with the sample-data service: Undo (Edit menu and the notice) puts each removed song
/// back at its old place, duplicates included; a service that can't insert at a place asks first instead.
@MainActor
@Suite struct RemovalUndoTests {
    private func setUp() async throws -> (AppModel, MockProvider, Playlist) {
        let model = AppModel(environment: ["MEDLEY_MOCK": "1"])
        model.noticeDuration = .seconds(10)
        let sp = try #require(model.providers.first { $0.id == .spotify } as? MockProvider)
        let page = try await sp.library(.playlists, continuation: nil)
        let playlist = try #require(page.items.compactMap { if case .playlist(let p) = $0, p.isEditable { p } else { nil } }.first)
        return (model, sp, playlist)
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }

    private func ids(_ provider: MockProvider, _ playlist: Playlist) async throws -> [String] {
        var detail = try await provider.playlist(id: playlist.providerID)
        var all = detail.tracks
        while let next = detail.continuation {
            let page = try await provider.playlistTracks(continuation: next)
            all += page.items
            detail.continuation = page.continuation
        }
        return all.map(\.id)
    }

    @Test func undoPutsARemovedSongBackAtEveryPlaceItHeld() async throws {
        let (model, sp, playlist) = try await setUp()
        let first = try await sp.playlist(id: playlist.providerID).tracks
        #expect(first.count >= 4)
        // The song is in the playlist twice: third, and again at the end.
        let song = first[2]
        try await sp.add([song], toPlaylist: playlist.providerID)
        let before = try await ids(sp, playlist)
        #expect(before.filter { $0 == song.id }.count == 2)

        let undo = UndoManager()
        undo.groupsByEvent = false
        model.requestRemove([song], from: playlist, undoManager: undo)
        try await settle()
        #expect(model.pendingPlaylistRemoval == nil)
        let removed = try await ids(sp, playlist)
        #expect(!removed.contains(song.id))
        #expect(removed.count == before.count - 2)
        #expect(undo.canUndo)
        #expect(undo.undoActionName == "Remove “\(song.title)”")
        // The notice says what went, both copies, and offers Undo.
        let notice = try #require(model.notice)
        #expect(notice.text == "Removed both copies of “\(song.title)” from “\(playlist.title)”")
        #expect(notice.action?.title == "Undo")

        undo.undo()
        try await settle()
        #expect(try await ids(sp, playlist) == before)
        #expect(model.notice?.text == "Put both copies of “\(song.title)” back in “\(playlist.title)”")

        // No Redo for a playlist edit: removing again is one click.
        #expect(!undo.canRedo)
        #expect(!undo.canUndo)
    }

    @Test func theNoticesUndoRestoresAndLeavesNothingForTheEditMenu() async throws {
        let (model, sp, playlist) = try await setUp()
        let before = try await ids(sp, playlist)
        let song = try await sp.playlist(id: playlist.providerID).tracks[1]
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.requestRemove([song], from: playlist, undoManager: undo)
        try await settle()
        let action = try #require(model.notice?.action)
        action.run()
        try await settle()
        #expect(try await ids(sp, playlist) == before)
        // Edit › Undo wouldn't add it a second time.
        #expect(!undo.canUndo)
    }

    @Test func aFailedPutBackOffersTryAgainWithoutAddingTwice() async throws {
        let (model, sp, playlist) = try await setUp()
        let before = try await ids(sp, playlist)
        let song = try await sp.playlist(id: playlist.providerID).tracks[0]
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.requestRemove([song], from: playlist, undoManager: undo)
        try await settle()

        sp.failingWrites = .network(URLError(.notConnectedToInternet).localizedDescription)
        undo.undo()
        try await settle()
        let failure = try #require(model.notice)
        #expect(failure.kind == .failure)
        let retry = try #require(failure.retry)
        sp.failingWrites = nil
        model.dismissNotice()
        retry()
        try await settle()
        #expect(try await ids(sp, playlist) == before)
    }

    @Test func aServiceThatCantPutItBackAsksFirst() async throws {
        let (model, sp, playlist) = try await setUp()
        sp.capabilities.remove(.playlistInsert)
        let before = try await ids(sp, playlist)
        let song = try await sp.playlist(id: playlist.providerID).tracks[0]

        model.requestRemove([song], from: playlist, undoManager: UndoManager())
        try await settle()
        // Nothing removed yet: the window asks, naming the song and the playlist.
        let pending = try #require(model.pendingPlaylistRemoval)
        #expect(pending.tracks.map(\.id) == [song.id])
        #expect(pending.playlist.providerID == playlist.providerID)
        #expect(try await ids(sp, playlist) == before)

        // Confirmed: removed, with no Undo to offer.
        model.pendingPlaylistRemoval = nil
        model.remove(pending.tracks, from: pending.playlist, entries: pending.entries)
        try await settle()
        #expect(!(try await ids(sp, playlist)).contains(song.id))
        #expect(model.notice?.action == nil)
        #expect(model.notice?.text == "Removed “\(song.title)” from “\(playlist.title)”")
    }

    /// The confirmation counts the copies first and names them; confirmed, every copy goes.
    @Test func theConfirmationSaysWhenEveryCopyGoes() async throws {
        let (model, sp, playlist) = try await setUp()
        sp.capabilities.remove(.playlistInsert)
        let song = try await sp.playlist(id: playlist.providerID).tracks[1]
        try await sp.add([song, song], toPlaylist: playlist.providerID)
        model.requestRemove([song], from: playlist, undoManager: UndoManager())
        try await settle()
        let pending = try #require(model.pendingPlaylistRemoval)
        #expect(pending.entries == 3)
        #expect(pending.phrase == "all 3 copies of “\(song.title)”")
        model.pendingPlaylistRemoval = nil
        model.remove(pending.tracks, from: pending.playlist, entries: pending.entries)
        try await settle()
        #expect(!(try await ids(sp, playlist)).contains(song.id))
        #expect(model.notice?.text == "Removed all 3 copies of “\(song.title)” from “\(playlist.title)”")
    }

    @Test func removalPhrasesCountCopies() {
        let a = Track(providerID: "1", provider: .spotify, title: "One")
        let b = Track(providerID: "2", provider: .spotify, title: "Two")
        #expect(AppModel.removalPhrase([a], entries: 1) == "“One”")
        #expect(AppModel.removalPhrase([a], entries: 2) == "both copies of “One”")
        #expect(AppModel.removalPhrase([a, b], entries: 2) == "2 songs")
        #expect(AppModel.removalPhrase([a, b], entries: 3) == "2 songs (3 copies in all)")
    }
}
