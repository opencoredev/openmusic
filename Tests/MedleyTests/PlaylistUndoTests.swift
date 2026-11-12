import AppKit
import Foundation
import MedleyCore
import Testing
@testable import Medley

/// Single-level Undo for playlist edits (round 35): a playlist edit goes on the undo manager only once every request
/// was acknowledged, any new playlist edit takes the older one off first, Undo registers no Redo, and a partly applied
/// edit keeps its playlist locked until Try Again, Undo or Leave As Is ends it, whatever happens to its notice.
@MainActor
@Suite struct PlaylistUndoTests {
    private let offline = ProviderError.network(URLError(.notConnectedToInternet).localizedDescription)

    /// An editable Spotify playlist holding `count` songs in order, edited in requests of two songs.
    private func setUp(_ count: Int = 7) async throws -> (AppModel, MockProvider, Playlist, [Track]) {
        let model = AppModel(environment: ["MEDLEY_MOCK": "1"])
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

    private func undoManager() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        return undo
    }

    // MARK: Sol's P1 (round 34): a dismissed partial Undo left older positions undoable

    /// [A…G], requests of two. Remove E, then A, B, C; Undo, whose second request (C) fails; close the notice. The
    /// playlist stays locked (no edit, no Undo of E), and Try Again puts C back at its own place. E's removal is no
    /// longer undoable at any point, so it can't land at a place that moved.
    @Test func aDismissedPartialUndoKeepsThePlaylistLockedAndTheOlderRemovalGone() async throws {
        let (model, sp, playlist, songs) = try await setUp()
        let before = entries(sp, playlist)
        let undo = undoManager()
        let (a, b, c, e) = (songs[0], songs[1], songs[2], songs[4])
        await model.remove([e], from: playlist, undoManager: undo).value
        await model.remove([a, b, c], from: playlist, undoManager: undo).value
        #expect(entries(sp, playlist) == [songs[3], songs[5], songs[6]].map(\.id))
        #expect(undo.undoActionName == "Remove 3 Songs")

        sp.playlistEditFailures = [sp.playlistEdits.count + 2: offline]
        undo.undo()
        await model.lastPlaylistEdit?.value
        let afterFailure = [a, b, songs[3], songs[5], songs[6]].map(\.id)
        #expect(entries(sp, playlist) == afterFailure, "A and B back, C's request failed")
        let failure = try #require(model.notice)
        #expect(failure.kind == .failure)
        let retry = try #require(failure.retry)

        model.dismissNotice()
        #expect(!model.canEdit(playlist), "closing the notice doesn't unlock the playlist")
        #expect(!undo.canUndo, "E's removal is no longer undoable")
        undo.undo()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == afterFailure, "nothing goes back at a stale place")

        retry()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == before.filter { $0 != e.id }, "C back at place 3, E still out")
        #expect(model.canEdit(playlist))
        #expect(!undo.canUndo)
        #expect(!undo.canRedo)
    }

    // MARK: Single-level history

    /// A second removal takes the first one's Undo away: one Undo, for the newest edit, and nothing under it.
    @Test func aNewPlaylistEditPurgesThePreviousUndo() async throws {
        let (model, sp, playlist, songs) = try await setUp()
        let before = entries(sp, playlist)
        let undo = undoManager()
        await model.remove([songs[1]], from: playlist, undoManager: undo).value
        #expect(undo.undoActionName == "Remove “\(songs[1].title)”")
        await model.remove([songs[3]], from: playlist, undoManager: undo).value
        #expect(undo.undoActionName == "Remove “\(songs[3].title)”")
        undo.undo()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == before.filter { $0 != songs[1].id })
        #expect(!undo.canUndo, "the first removal's Undo went when the second began")
    }

    /// An add to another playlist is a playlist edit too: it takes the removal's Undo (and the notice's) away.
    @Test func anAddToAnotherPlaylistPurgesTheRemovalsUndo() async throws {
        let (model, sp, playlist, songs) = try await setUp()
        let other = try await sp.createPlaylist(title: "Other", description: nil)
        let undo = undoManager()
        await model.remove([songs[1]], from: playlist, undoManager: undo).value
        let stale = try #require(model.notice?.action)
        await model.add([songs[0]], to: other).value
        #expect(!undo.canUndo)
        stale.run()
        await model.lastPlaylistEdit?.value
        #expect(!entries(sp, playlist).contains(songs[1].id), "the old notice's Undo does nothing")
    }

    /// Undo of a playlist edit registers no Redo: the Edit menu then offers neither for it.
    @Test func undoingAPlaylistEditRegistersNoRedo() async throws {
        let (model, sp, playlist, songs) = try await setUp()
        let before = entries(sp, playlist)
        let undo = undoManager()
        await model.remove([songs[2]], from: playlist, undoManager: undo).value
        #expect(undo.undoMenuItemTitle == "Undo Remove “\(songs[2].title)”")
        undo.undo()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == before)
        #expect(!undo.canRedo)
        #expect(undo.redoMenuItemTitle == "Redo")
        #expect(!undo.canUndo)
    }

    // MARK: The Edit menu and the notice: one Undo

    /// Edit › Undo first: the notice's Undo goes at once, and pressed anyway it puts nothing back twice.
    @Test func theEditMenusUndoConsumesTheNotices() async throws {
        let (model, sp, playlist, songs) = try await setUp()
        let before = entries(sp, playlist)
        let undo = undoManager()
        await model.remove([songs[3]], from: playlist, undoManager: undo).value
        let stale = try #require(model.notice?.action)
        undo.undo()
        #expect(model.notice?.action == nil, "the notice changes as Edit › Undo starts")
        await model.lastPlaylistEdit?.value
        stale.run()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == before, "the song is back once")
    }

    /// The notice's Undo first: the Edit menu's entry goes at once, and the queue's Undo under it is on top again.
    @Test func theNoticesUndoConsumesTheEditMenusAndLeavesTheQueuesUndo() async throws {
        let (model, sp, playlist, songs) = try await setUp()
        let before = entries(sp, playlist)
        let undo = undoManager()
        model.player.play(Array(songs.prefix(1)), startAt: 0)
        model.player.addToQueue(Array(songs.dropFirst(4)))
        // The listener's entries (Autoplay may fill in meanwhile).
        func listened() -> [String] { model.player.queue.filter { !$0.isAutoplay }.map(\.track.id) }
        let queue = listened()
        #expect(queue.count == 4)
        undo.beginUndoGrouping()
        model.player.clearUpNext(undoManager: undo)
        undo.endUndoGrouping()
        #expect(listened().count == 1)

        await model.remove([songs[3]], from: playlist, undoManager: undo).value
        #expect(undo.undoActionName == "Remove “\(songs[3].title)”")
        let action = try #require(model.notice?.action)
        model.dismissNotice()
        action.run()
        #expect(undo.undoActionName == "Clear Up Next", "the playlist edit left the stack, the queue's Undo is next")
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == before)
        #expect(!undo.canRedo)
        undo.undo()
        #expect(listened() == queue, "the queue's Undo still works")
    }

    /// A text field's typing and a playlist edit share the window's undo manager: each Undo undoes its own.
    @Test func typingInATextFieldStillUndoesAlongsideAPlaylistEdit() async throws {
        let (model, sp, playlist, songs) = try await setUp()
        let before = entries(sp, playlist)
        let undo = undoManager()
        final class Host: NSObject, NSWindowDelegate {
            let undo: UndoManager
            init(_ undo: UndoManager) { self.undo = undo }
            func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undo }
        }
        let host = Host(undo)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.delegate = host
        let field = NSTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        field.allowsUndo = true
        window.contentView = field
        #expect(field.undoManager === undo)
        undo.beginUndoGrouping()
        field.insertText("night", replacementRange: NSRange(location: 0, length: 0))
        field.breakUndoCoalescing()
        undo.endUndoGrouping()
        #expect(field.string == "night")

        await model.remove([songs[1]], from: playlist, undoManager: undo).value
        undo.undo()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == before)
        #expect(field.string == "night", "⌘Z undid the playlist edit first")
        #expect(undo.canUndo)
        undo.undo()
        #expect(field.string == "", "then the typing")
        _ = host
    }

    // MARK: A partly applied edit stays locked

    /// [A…G]: removing B, D, E stops after B and D. Closing the failure notice keeps the playlist locked: removals and
    /// adds are refused, the menu items stay disabled, and the Edit menu has no Undo for the part done.
    @Test func dismissingAPartialEditsNoticeKeepsTheLock() async throws {
        let (model, sp, playlist, songs) = try await setUp()
        let before = entries(sp, playlist)
        let undo = undoManager()
        sp.playlistEditFailures = [2: offline]
        await model.remove([songs[1], songs[3], songs[4]], from: playlist, undoManager: undo).value
        let partial = before.filter { $0 != songs[1].id && $0 != songs[3].id }
        #expect(entries(sp, playlist) == partial)
        #expect(!undo.canUndo, "nothing on the undo manager until the edit settles")
        model.dismissNotice()
        #expect(!model.canEdit(playlist))
        await model.remove([songs[5]], from: playlist, undoManager: undo).value
        await model.add([songs[0]], to: playlist).value
        #expect(entries(sp, playlist) == partial, "both refused")
    }
}
