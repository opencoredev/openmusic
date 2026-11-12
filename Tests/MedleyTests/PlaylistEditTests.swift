import AppKit
import Foundation
import MedleyCore
import SwiftUI
import Testing
@testable import Medley

/// One edit at a time per playlist, and one record per listener action whose Undo and Try Again only ever invert what
/// the service acknowledged (rounds 34 and 35; single-level Undo itself is `PlaylistUndoTests`). The mock service splits its edits into requests of `editBatchSize` (2
/// here), fails the ones `playlistEditFailures` names, and holds requests in flight through `playlistEditGate`.
@MainActor
@Suite struct PlaylistEditTests {
    private let offline = ProviderError.network(URLError(.notConnectedToInternet).localizedDescription)

    /// Holds every playlist edit request until the test lets it go.
    @MainActor final class EditGate {
        private(set) var held: [String] = []
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var arrivals: [CheckedContinuation<Void, Never>] = []

        func hold(_ kind: String) async {
            held.append(kind)
            await withCheckedContinuation { continuation in
                waiting.append(continuation)
                let ready = arrivals
                arrivals = []
                for arrival in ready { arrival.resume() }
            }
        }

        /// Returns once a request is held.
        func requestHeld() async {
            if !waiting.isEmpty { return }
            await withCheckedContinuation { arrivals.append($0) }
        }

        func releaseAll() {
            let all = waiting
            waiting = []
            for continuation in all { continuation.resume() }
        }
    }

    /// An editable Spotify playlist holding `count` songs in order.
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

    // MARK: P2: an edit while another can still be resumed

    /// [A…G]: removing B, D, E stops after B and D. While it is partly applied, removing F and adding a song are
    /// refused, also after its notice is closed; Try Again takes E out; then F goes, and its Undo (the only one: single
    /// level) puts F back before G.
    @Test func noOtherEditWhileAPartialRemovalCanBeResumed() async throws {
        let (model, sp, playlist, songs) = try await setUp()
        let before = entries(sp, playlist)
        let undo = undoManager()
        sp.playlistEditFailures = [2: offline]
        let first = [songs[1], songs[3], songs[4]]
        await model.remove(first, from: playlist, undoManager: undo).value
        let failure = try #require(model.notice)
        let retry = try #require(failure.retry)
        let partial = before.filter { $0 != songs[1].id && $0 != songs[3].id }
        #expect(entries(sp, playlist) == partial)

        await model.remove([songs[5]], from: playlist, undoManager: undo).value
        #expect(entries(sp, playlist) == partial, "a second removal waits for the first")
        #expect(model.canEdit(playlist) == false, "its Remove and Add to Playlist items are disabled")
        await model.add([songs[0]], to: playlist).value
        #expect(entries(sp, playlist) == partial, "so does an add")
        #expect(model.notice?.id == failure.id, "the failure, with its Try Again, stays")

        model.dismissNotice()
        await model.add([songs[0]], to: playlist).value
        #expect(entries(sp, playlist) == partial, "still refused with the notice closed")
        #expect(model.notice?.edit === failure.edit, "the refusal brings the failure notice back")
        retry()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == before.filter { !first.map(\.id).contains($0) })

        await model.remove([songs[5]], from: playlist, undoManager: undo).value
        #expect(entries(sp, playlist) == [songs[0], songs[2], songs[6]].map(\.id))
        undo.undo()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == before.filter { !first.map(\.id).contains($0) }, "F back before G")
        #expect(!undo.canUndo, "the first removal's Undo went when F's removal began")
    }

    // MARK: One edit at a time

    /// While a removal's request is in flight, another removal or an add to the same playlist is refused with a
    /// notice saying why; another playlist is unaffected. Once it lands, the playlist takes edits again.
    @Test func anEditWhileARequestIsInFlightIsRefused() async throws {
        let (model, sp, playlist, songs) = try await setUp()
        let other = try await sp.createPlaylist(title: "Other", description: nil)
        try await sp.add(Array(songs.prefix(3)), toPlaylist: other.providerID)
        let before = entries(sp, playlist)
        let gate = EditGate()
        sp.playlistEditGate = { await gate.hold($0) }
        let undo = undoManager()
        let removal = model.remove([songs[1]], from: playlist, undoManager: undo)
        await gate.requestHeld()

        #expect(!model.canEdit(playlist), "Remove and Add to Playlist are disabled for it")
        #expect(model.canEdit(other))
        model.remove([songs[2]], from: playlist, undoManager: undo)
        #expect(model.notice?.text == "Finishing the last change to “Edits”…")
        model.add([songs[0]], to: playlist)
        #expect(!model.drop([MediaDragItem(.track(songs[0]))], on: playlist), "a drop on it is refused")
        await Task.yield()
        #expect(gate.held == ["remove"], "nothing else was sent for this playlist")

        // Another playlist takes its edit meanwhile.
        sp.playlistEditGate = nil
        await model.remove([songs[0]], from: other, undoManager: undo).value
        #expect(entries(sp, other) == Array(songs.prefix(3)).dropFirst().map(\.id))

        gate.releaseAll()
        await removal.value
        #expect(entries(sp, playlist) == before.filter { $0 != songs[1].id })
        #expect(model.canEdit(playlist))
        await model.remove([songs[2]], from: playlist, undoManager: undo).value
        #expect(entries(sp, playlist) == before.filter { $0 != songs[1].id && $0 != songs[2].id })
    }

    /// A newer removal of the same playlist takes the older one's Undo away as it starts, before its requests land:
    /// Edit › Undo has nothing, and the old notice's Undo does nothing. Another playlist's removal, meanwhile, is the
    /// one Undo once it settles.
    @Test func aNewerRemovalTakesTheOlderUndoAwayAsItStarts() async throws {
        let (model, sp, playlist, songs) = try await setUp()
        let before = entries(sp, playlist)
        let yt = try #require(model.providers.first { $0.id == .youtubeMusic } as? MockProvider)
        let ytSongs = Array(yt.catalog.allTracks.prefix(3))
        let other = try await yt.createPlaylist(title: "Other", description: nil)
        try await yt.add(ytSongs, toPlaylist: other.providerID)
        let undo = undoManager()
        await model.remove([songs[1]], from: playlist, undoManager: undo).value
        let stale = try #require(model.notice?.action)

        let gate = EditGate()
        sp.playlistEditGate = { await gate.hold($0) }
        let newer = model.remove([songs[2]], from: playlist, undoManager: undo)
        await gate.requestHeld()
        #expect(!undo.canUndo, "the older removal's Undo went as the newer one began")
        stale.run()
        #expect(gate.held == ["remove"], "the old notice's Undo sent nothing")

        await model.remove([ytSongs[1]], from: other, undoManager: undo).value
        #expect(undo.undoActionName == "Remove “\(ytSongs[1].title)”")
        sp.playlistEditGate = nil
        gate.releaseAll()
        await newer.value
        #expect(undo.undoActionName == "Remove “\(songs[2].title)”", "the newest settled edit is the one Undo")
        undo.undo()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == before.filter { $0 != songs[1].id })
        #expect(!undo.canUndo)
        #expect(!entries(yt, other).contains(ytSongs[1].id), "the other playlist's removal stays; its Undo went")
    }

    /// While Undo's put-back is in flight the playlist takes no edit, Edit › Undo has nothing more of it, and once the
    /// songs are back there is no Redo.
    @Test func nothingElseWhileUndoIsInFlightAndNoRedoAfter() async throws {
        let (model, sp, playlist, songs) = try await setUp()
        let before = entries(sp, playlist)
        let undo = undoManager()
        await model.remove([songs[2]], from: playlist, undoManager: undo).value
        let gate = EditGate()
        sp.playlistEditGate = { await gate.hold($0) }
        undo.undo()
        await gate.requestHeld()
        #expect(!model.canEdit(playlist))
        #expect(!undo.canUndo)
        #expect(!undo.canRedo)
        model.remove([songs[3]], from: playlist, undoManager: undo)
        #expect(model.notice?.text == "Finishing the last change to “Edits”…")
        #expect(gate.held == ["insert"])
        sp.playlistEditGate = nil
        gate.releaseAll()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == before)
        #expect(!undo.canRedo)
        #expect(model.canEdit(playlist))
    }

    // MARK: P2: undo handlers and their manager

    /// After a removal and its Undo, and a second removal left on the stack, letting go of the undo manager and the
    /// model frees both: no handler keeps its manager (manager → handler → manager) or the model alive.
    @Test func theUndoManagerAndTheModelCanDeallocate() async throws {
        weak var weakUndo: UndoManager?
        weak var weakModel: AppModel?
        do {
            let (model, sp, playlist, songs) = try await setUp()
            model.noticeSleep = { _ in }
            let undo = undoManager()
            await model.remove([songs[1]], from: playlist, undoManager: undo).value
            undo.undo()
            await model.lastPlaylistEdit?.value
            await model.remove([songs[1]], from: playlist, undoManager: undo).value
            #expect(!entries(sp, playlist).contains(songs[1].id))
            #expect(undo.canUndo)
            model.dismissNotice()
            await model.noticeExpiry?.value
            weakUndo = undo
            weakModel = model
        }
        for _ in 0..<20 where weakUndo != nil || weakModel != nil { await Task.yield() }
        #expect(weakUndo == nil, "the undo manager is freed")
        #expect(weakModel == nil, "the model is freed")
    }

    // MARK: P3: a total length with entries left out

    /// A playlist whose service lists 3 entries but Medley shows 2 (a local file left out): the count stays 3, and
    /// with one length unknown there is no total length.
    @Test func entriesLeftOutHideTheTotalLength() {
        let a = Track(providerID: "a", provider: .spotify, title: "A", duration: 200)
        let b = Track(providerID: "b", provider: .spotify, title: "B", duration: 100)
        #expect(songCountLine(count: 3, tracks: [a, b]) == "3 songs")
        #expect(songCountLine(count: 2, tracks: [a, b]) == "2 songs, 5 min")
        // Copies count as entries: one row held twice is two of them.
        #expect(songCountLine(count: 3, tracks: [a, b], copies: [a.id: 2]) == "3 songs, 8 min 20 sec")
    }

    /// The same through the pager, with the mock leaving a song out of every page.
    @Test func aCompletePagerWithAnUnlistedEntryGivesNoLength() async throws {
        let (_, sp, playlist, songs) = try await setUp(4)
        sp.unlistedTrackIDs = [songs[1].id]
        let detail = try await sp.playlist(id: playlist.providerID)
        let pager = PlaylistPager(detail)
        #expect(pager.isComplete)
        #expect(pager.entryTotal == 4)
        #expect(pager.tracks.count == 3)
        #expect(songCountLine(count: pager.entryTotal, tracks: pager.tracks, complete: pager.isComplete, copies: pager.copies) == "4 songs")
    }

    // MARK: P3: the buffering ring on hidden measuring copies

    /// The floating player's hidden measuring rows carry a play button too: while buffering, it starts no ring (no
    /// delay task, no Core Animation rotation); the real button does.
    @Test func measuringCopiesDrawNoBufferingRing() async throws {
        let model = AppModel(environment: ["MEDLEY_MOCK": "1"])
        let sp = try #require(model.providers.first { $0.id == .spotify } as? MockProvider)
        model.player.play(Array(sp.catalog.allTracks.prefix(2)), startAt: 0)
        model.debugForcesBuffering = true
        func ringViews(_ view: NSView) -> Int {
            (view is SpinnerRing.RingView ? 1 : 0) + view.subviews.reduce(0) { $0 + ringViews($1) }
        }
        let measuring = NSHostingView(rootView: PlayPauseButton().environment(\.isPlayerMeasurement, true).environment(model))
        let shown = NSHostingView(rootView: PlayPauseButton().environment(model))
        for view in [measuring, shown] { view.frame = CGRect(x: 0, y: 0, width: 60, height: 60) }
        for _ in 0..<100 where ringViews(shown) == 0 {
            measuring.layoutSubtreeIfNeeded()
            shown.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(ringViews(shown) == 1, "the real button draws the ring after its delay")
        #expect(ringViews(measuring) == 0, "a measuring copy draws none")
    }

    @Test func measuringCopiesDontWatchBuffering() {
        #expect(!PlayPauseButton.tracksBuffering(true, measuring: true))
        #expect(PlayPauseButton.tracksBuffering(true, measuring: false))
        #expect(!PlayPauseButton.tracksBuffering(false, measuring: false))
    }

    /// The ring's Core Animation rotation runs only while the view is in a window and shown: it comes off when the
    /// view hides or leaves its window (or SwiftUI takes it down) and goes back on when it returns.
    @Test func theRingTurnsOnlyWhileShownInAWindow() {
        let ring = SpinnerRing.RingView(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
        let ink = NSColor.labelColor.cgColor
        ring.update(color: ink, spins: true)
        #expect(!ring.isTurning, "not in a window yet")
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(ring)
        #expect(ring.isTurning)
        ring.isHidden = true
        #expect(!ring.isTurning, "hidden")
        ring.isHidden = false
        #expect(ring.isTurning)
        ring.removeFromSuperview()
        #expect(!ring.isTurning, "out of its window")
        window.contentView?.addSubview(ring)
        #expect(ring.isTurning)
        ring.update(color: ink, spins: false)
        #expect(!ring.isTurning, "Reduce Motion")
        ring.update(color: ink, spins: true)
        ring.stop()
        #expect(!ring.isTurning, "dismantled")
    }
}
