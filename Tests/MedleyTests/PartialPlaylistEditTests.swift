import Foundation
import MedleyCore
import Testing
@testable import Medley

/// Removals and put-backs that take more than one request (Spotify: 100 songs each), with a request failing partway,
/// and places counted the way the service numbers its entries. The mock service splits its edits into requests of
/// `editBatchSize` songs, as Spotify does, and fails the ones `playlistEditFailures` names.
@MainActor
@Suite struct PartialPlaylistEditTests {
    private let offline = ProviderError.network(URLError(.notConnectedToInternet).localizedDescription)

    /// A new editable Spotify playlist holding `songs` in order.
    private func setUp(_ count: Int = 6) async throws -> (AppModel, MockProvider, Playlist, [Track]) {
        let model = AppModel(environment: ["MEDLEY_MOCK": "1"])
        model.noticeDuration = .seconds(30)
        let sp = try #require(model.providers.first { $0.id == .spotify } as? MockProvider)
        let songs = Array(sp.catalog.allTracks.prefix(count))
        #expect(songs.count == count)
        let playlist = try await sp.createPlaylist(title: "Partial", description: nil)
        try await sp.add(songs, toPlaylist: playlist.providerID)
        return (model, sp, playlist, songs)
    }

    /// The playlist's entries as the service holds them, the unlisted ones included.
    private func entries(_ sp: MockProvider, _ playlist: Playlist) -> [String] {
        (sp.catalog.playlistTracks[playlist.providerID] ?? []).map(\.id)
    }

    private func undoManager() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        return undo
    }

    // MARK: A removal that fails partway (P1)

    /// Three songs in requests of two; the second request fails. The first two are out: the page refreshes, the
    /// playlist is locked, the Edit menu has no Undo yet (the edit hasn't settled), and the notice offers Undo of the
    /// two, Try Again and Leave As Is. Try Again goes on with the third without reading the changed playlist for
    /// places; settled, the one Undo covers all three.
    @Test func aRemovalThatFailsPartwayIsLockedAndTryAgainFinishesIt() async throws {
        let (model, sp, playlist, songs) = try await setUp()
        let before = entries(sp, playlist)
        sp.editBatchSize = 2
        sp.playlistEditFailures = [2: offline]
        let key = "playlist:\(playlist.provider.rawValue):\(playlist.providerID)"
        let version = model.pageVersions[key] ?? 0
        let undo = undoManager()
        let chosen = [songs[1], songs[3], songs[4]]

        await model.remove(chosen, from: playlist, undoManager: undo).value
        #expect(entries(sp, playlist) == before.filter { $0 != songs[1].id && $0 != songs[3].id })
        #expect((model.pageVersions[key] ?? 0) > version, "the open page refreshes after a partial removal")
        let failure = try #require(model.notice)
        #expect(failure.kind == .failure)
        #expect(failure.text.hasPrefix("Removed only 2 of 3 songs from “Partial”"))
        #expect(failure.action?.title == "Undo")
        #expect(failure.secondaryAction?.title == "Leave As Is")
        let retry = try #require(failure.retry)
        #expect(!undo.canUndo, "no Edit › Undo until every request is acknowledged")
        #expect(!model.canEdit(playlist))

        model.dismissNotice()
        retry()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == before.filter { !chosen.map(\.id).contains($0) })
        #expect(model.notice?.text == "Removed 3 songs from “Partial”")
        #expect(undo.undoActionName == "Remove 3 Songs")
        undo.undo()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == before)
        #expect(!undo.canUndo, "one Undo for the removal")
        #expect(!undo.canRedo)
    }

    /// Leave As Is: the partly applied removal ends with the two songs out, the playlist takes edits again, and there
    /// is no Undo of it anywhere.
    @Test func leaveAsIsKeepsWhatTheServiceHasAndUnlocks() async throws {
        let (model, sp, playlist, songs) = try await setUp()
        let before = entries(sp, playlist)
        sp.editBatchSize = 2
        sp.playlistEditFailures = [2: offline]
        let undo = undoManager()
        await model.remove([songs[1], songs[3], songs[4]], from: playlist, undoManager: undo).value
        let partial = before.filter { $0 != songs[1].id && $0 != songs[3].id }
        let failure = try #require(model.notice)
        let undoPart = try #require(failure.action)
        model.dismissNotice()
        #expect(!model.canEdit(playlist), "closing the notice keeps the lock")
        let edit = try #require(model.partialEdit(of: playlist))
        model.leaveAsIs(edit)
        #expect(model.canEdit(playlist))
        #expect(model.partialEdit(of: playlist) == nil)
        undoPart.run()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == partial, "the old notice's Undo does nothing")
        #expect(!undo.canUndo)
        await model.remove([songs[5]], from: playlist, undoManager: undo).value
        #expect(entries(sp, playlist) == partial.filter { $0 != songs[5].id }, "the playlist takes edits again")
    }

    /// Undo of the part removed (the failure notice's Undo) puts the playlist back as it was.
    @Test func theFailureNoticesUndoPutsThePartRemovedBack() async throws {
        let (model, sp, playlist, songs) = try await setUp()
        let before = entries(sp, playlist)
        sp.editBatchSize = 2
        sp.playlistEditFailures = [2: offline]
        let undo = undoManager()
        await model.remove([songs[0], songs[2], songs[5]], from: playlist, undoManager: undo).value
        let action = try #require(model.notice?.action)
        model.dismissNotice()
        action.run()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == before)
        #expect(!undo.canUndo)
    }

    /// Undo right after the failure (the page's banner, as the notice's) puts back exactly the two songs that went,
    /// at their places, and unlocks the playlist.
    @Test func undoOfAPartialRemovalPutsBackWhatWent() async throws {
        let (model, sp, playlist, songs) = try await setUp()
        let before = entries(sp, playlist)
        sp.editBatchSize = 2
        sp.playlistEditFailures = [2: offline]
        let undo = undoManager()
        await model.remove([songs[0], songs[4], songs[5]], from: playlist, undoManager: undo).value
        #expect(entries(sp, playlist) == before.filter { $0 != songs[0].id && $0 != songs[4].id })
        let calls = sp.playlistEdits.count
        model.dismissNotice()
        model.undoPartial(try #require(model.partialEdit(of: playlist)))
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == before)
        #expect(Array(sp.playlistEdits.dropFirst(calls)) == ["insert \(songs[0].providerID) at 0", "insert \(songs[4].providerID) at 4"])
        #expect(model.canEdit(playlist))
        #expect(!undo.canUndo)
        #expect(!undo.canRedo)
    }

    // MARK: A put-back that fails partway (P2)

    /// Undo of three neighbouring songs is one run, sent in requests of two: when the second fails, Try Again adds
    /// only the song not yet back, so nothing is duplicated.
    @Test func aPutBackThatFailsPartwayAddsNothingTwiceOnTryAgain() async throws {
        let (model, sp, playlist, songs) = try await setUp()
        let before = entries(sp, playlist)
        sp.editBatchSize = 2
        let undo = undoManager()
        await model.remove([songs[1], songs[2], songs[3]], from: playlist, undoManager: undo).value
        #expect(entries(sp, playlist).count == before.count - 3)

        let calls = sp.playlistEdits.count
        sp.playlistEditFailures = [calls + 2: offline]
        undo.undo()
        await model.lastPlaylistEdit?.value
        let failure = try #require(model.notice)
        #expect(failure.kind == .failure)
        let retry = try #require(failure.retry)
        model.dismissNotice()
        retry()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == before)
        #expect(Array(sp.playlistEdits.dropFirst(calls)) == [
            "insert \(songs[1].providerID), \(songs[2].providerID) at 1",
            "insert \(songs[3].providerID) at 3",
            "insert \(songs[3].providerID) at 3",
        ])
    }

    // MARK: Places around entries Medley leaves out (P2)

    /// [A, local, X, B, X]: the local file isn't listed, but it holds place 1, so X's places are 2 and 4, and Undo puts
    /// both copies back there.
    @Test func undoPutsCopiesBackAroundEntriesThePageLeavesOut() async throws {
        let model = AppModel(environment: ["MEDLEY_MOCK": "1"])
        model.noticeDuration = .seconds(30)
        let sp = try #require(model.providers.first { $0.id == .spotify } as? MockProvider)
        let pool = Array(sp.catalog.allTracks.prefix(4))
        let (a, local, x, b) = (pool[0], pool[1], pool[2], pool[3])
        let playlist = try await sp.createPlaylist(title: "Locals", description: nil)
        try await sp.add([a, local, x, b, x], toPlaylist: playlist.providerID)
        sp.unlistedTrackIDs = [local.id]
        let before = entries(sp, playlist)

        let detail = try await sp.playlist(id: playlist.providerID)
        #expect(detail.tracks.map(\.id) == [a, x, b, x].map(\.id))
        #expect(detail.positions == [0, 2, 3, 4])

        let undo = undoManager()
        await model.remove([x], from: playlist, undoManager: undo).value
        #expect(entries(sp, playlist) == [a, local, b].map(\.id))
        #expect(model.notice?.text == "Removed both copies of “\(x.title)” from “Locals”")
        undo.undo()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == before)
    }
}
