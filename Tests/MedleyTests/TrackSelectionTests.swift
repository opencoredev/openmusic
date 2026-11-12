import AppKit
import Foundation
import MedleyCore
import Testing
@testable import Medley

/// Several rows selected in an album or playlist list (`TrackSelection`), the menu actions on them, and the header's
/// Play in a sorted list.
@MainActor
@Suite struct TrackSelectionTests {
    private let order = ["a", "b", "c", "d", "e", "f", "g"]

    private func picked(_ s: TrackSelection) -> [String] { s.selected(order, id: { $0 }) }

    @Test func aPlainClickSelectsOnlyThatRow() {
        var s = TrackSelection()
        s.click("c", .select, in: order)
        s.click("e", .select, in: order)
        #expect(picked(s) == ["e"])
        #expect(s.anchor == "e" && s.lead == "e")
    }

    @Test func commandClickAddsAndRemovesOneRow() {
        var s = TrackSelection()
        s.click("b", .select, in: order)
        s.click("d", .toggle, in: order)
        s.click("f", .toggle, in: order)
        #expect(picked(s) == ["b", "d", "f"])
        s.click("d", .toggle, in: order)
        #expect(picked(s) == ["b", "f"])
        // Removing the last one leaves nothing selected; the lead stays for the focus cursor.
        s.click("b", .toggle, in: order)
        s.click("f", .toggle, in: order)
        #expect(s.isEmpty)
        #expect(s.lead == "f")
    }

    @Test func shiftClickSelectsTheRangeFromTheAnchorKeepingCommandClicks() {
        var s = TrackSelection()
        s.click("a", .select, in: order)
        s.click("c", .toggle, in: order)
        s.click("e", .extend, in: order)
        #expect(picked(s) == ["a", "c", "d", "e"])
        // A second ⇧-click moves the range's far end from the same anchor: the range shrinks.
        s.click("d", .extend, in: order)
        #expect(picked(s) == ["a", "c", "d"])
        // Upward from the anchor.
        s.click("b", .extend, in: order)
        #expect(picked(s) == ["a", "b", "c"])
        // Without an anchor, ⇧-click is a plain click.
        var fresh = TrackSelection()
        fresh.click("f", .extend, in: order)
        #expect(picked(fresh) == ["f"])
    }

    @Test func modifierFlagsPickTheClick() {
        #expect(TrackSelection.Click([]) == .select)
        #expect(TrackSelection.Click(.command) == .toggle)
        #expect(TrackSelection.Click(.shift) == .extend)
        #expect(TrackSelection.Click([.command, .shift]) == .toggle)
    }

    @Test func shiftArrowsExtendFromTheAnchor() {
        var s = TrackSelection()
        s.click("c", .select, in: order)
        s.move(1, extending: true, in: order, cursor: nil)
        s.move(1, extending: true, in: order, cursor: nil)
        #expect(picked(s) == ["c", "d", "e"])
        #expect(s.lead == "e")
        // Back up past the anchor: the range turns around it.
        for _ in 0..<3 { s.move(-1, extending: true, in: order, cursor: nil) }
        #expect(picked(s) == ["b", "c"])
        // A plain arrow selects the next row alone.
        s.move(1, extending: false, in: order, cursor: nil)
        #expect(picked(s) == ["c"])
        // At the ends it stays put.
        var top = TrackSelection()
        top.click("a", .select, in: order)
        top.move(-1, extending: true, in: order, cursor: nil)
        #expect(picked(top) == ["a"])
    }

    @Test func anArrowWithNothingSelectedSelectsTheCursorRow() {
        var s = TrackSelection()
        let lead = s.move(1, extending: true, in: order, cursor: "d")
        #expect(lead == "d")
        #expect(picked(s) == ["d"])
    }

    @Test func commandASelectsEveryRowAndEscapeClears() {
        var s = TrackSelection()
        s.click("c", .select, in: order)
        s.selectAll(order)
        #expect(picked(s) == order)
        s.clear()
        #expect(s.isEmpty)
        #expect(s.lead == "c")
        // ⌘A with nothing clicked before anchors at the first row, so ⇧-click then ranges from there.
        var fresh = TrackSelection()
        fresh.selectAll(order)
        fresh.click("c", .extend, in: order)
        #expect(picked(fresh) == ["a", "b", "c"])
    }

    @Test func theSelectionFollowsItsRowsThroughASortAndLosesHiddenOnes() {
        var s = TrackSelection()
        s.click("b", .select, in: order)
        s.click("e", .toggle, in: order)
        // Sorted the other way: the same songs stay selected, listed in the new order.
        let reversed = Array(order.reversed())
        s.keep(reversed)
        #expect(s.selected(reversed, id: { $0 }) == ["e", "b"])
        // A filter hides "e": it leaves the selection.
        s.keep(["a", "b", "c"])
        #expect(s.selected(order, id: { $0 }) == ["b"])
    }

    // MARK: A song listed twice

    private func song(_ id: String, _ title: String) -> Track { Track(providerID: id, provider: .spotify, title: title) }

    /// A playlist lists a song it holds twice once, on its first page as on later ones, so rows, selection and Play from
    /// a row all go by `Track.id`; the service's total still counts every entry until the list is complete.
    @Test func aPlaylistListsARepeatedSongOnceOnEveryPage() async throws {
        let a = song("a", "Alpha"), b = song("b", "Bravo"), c = song("c", "Charlie"), d = song("d", "Delta")
        let pager = PlaylistPager(firstPage: [a, b, a, c], continuation: "p2", knownTotal: 6)
        #expect(pager.tracks.map(\.id) == [a.id, b.id, c.id])
        #expect(!pager.isComplete)
        await pager.loadNext { _ in Page(items: [c, d], continuation: nil) }
        #expect(pager.tracks.map(\.id) == [a.id, b.id, c.id, d.id])
        #expect(pager.entriesSeen == 6)
        #expect(pager.isComplete)
        // One row per song: a click selects one row and counts one.
        let ids = pager.tracks.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func playingASortedPlaylistWithARepeatedSongQueuesItOnce() async throws {
        let model = await model()
        let a = song("a", "Alpha"), b = song("b", "Bravo"), c = song("c", "Charlie")
        let context = AppModel.PlayingFrom(title: "Twice")
        await model.playPlaylist([b, a, c, a], continuation: nil, provider: .spotify, startAt: 1, from: context)
        #expect(model.player.queue.filter { !$0.isAutoplay }.map(\.track.title) == ["Bravo", "Alpha", "Charlie"])
        #expect(model.player.current?.title == "Alpha")
        await model.playPlaylistSorted([b, a, c], continuation: nil, provider: .spotify, sort: TrackSort(key: .title, ascending: true),
                                       startID: c.id, from: context)
        #expect(model.player.queue.filter { !$0.isAutoplay }.map(\.track.title) == ["Alpha", "Bravo", "Charlie"])
        #expect(model.player.currentIndex == 2)
    }

    // MARK: Rows that change under the selection

    @Test func removingTheAnchorMovesItToTheNearestSelectedRow() {
        var s = TrackSelection()
        s.click("b", .select, in: order)
        s.click("d", .extend, in: order)
        #expect(picked(s) == ["b", "c", "d"])
        // "b" is removed elsewhere.
        let after = order.filter { $0 != "b" }
        s.keep(after, previous: order)
        #expect(s.selected(after, id: { $0 }) == ["c", "d"])
        #expect(s.anchor == "c" && s.lead == "d")
        // ⇧↓ extends what is still selected.
        s.move(1, extending: true, in: after, cursor: nil)
        #expect(s.selected(after, id: { $0 }) == ["c", "d", "e"])
        // ⇧-click too.
        s.click("f", .extend, in: after)
        #expect(s.selected(after, id: { $0 }) == ["c", "d", "e", "f"])
        // Upward from the new anchor.
        s.click("a", .extend, in: after)
        #expect(s.selected(after, id: { $0 }) == ["a", "c"])
    }

    @Test func removingTheLeadMovesItBackIntoTheRange() {
        var s = TrackSelection()
        s.click("b", .select, in: order)
        s.click("d", .extend, in: order)
        let after = order.filter { $0 != "d" }
        s.keep(after, previous: order)
        #expect(s.anchor == "b" && s.lead == "c")
        s.move(1, extending: true, in: after, cursor: nil)
        #expect(s.selected(after, id: { $0 }) == ["b", "c", "e"])
    }

    @Test func aReanchoredRangeKeepsTheCommandClickedRows() {
        var s = TrackSelection()
        s.click("a", .select, in: order)
        s.click("e", .toggle, in: order)
        s.click("g", .extend, in: order)
        #expect(picked(s) == ["a", "e", "f", "g"])
        // The anchor "e" goes: "f" anchors, "a" stays as the ⌘-clicked part.
        let after = order.filter { $0 != "e" }
        s.keep(after, previous: order)
        #expect(s.anchor == "f")
        s.move(-1, extending: true, in: after, cursor: nil)
        #expect(s.selected(after, id: { $0 }) == ["a", "f"])
    }

    /// A discontiguous selection whose anchor goes: the selected row closest to it takes over, not the first one.
    @Test func removingADiscontiguousAnchorMovesItToTheClosestSelectedRow() {
        var s = TrackSelection()
        s.click("a", .select, in: order)
        s.click("g", .toggle, in: order)
        // A third row, ⌘-clicked after "g": the anchor, at the far end from "a".
        let rows = order + ["h"]
        s.click("h", .toggle, in: rows)
        #expect(s.anchor == "h")
        let after = rows.filter { $0 != "h" }
        s.keep(after, previous: rows)
        #expect(s.anchor == "g" && s.lead == "g")
        #expect(s.selected(after, id: { $0 }) == ["a", "g"])
        // ⇧-click extends from "g", keeping "a" as the ⌘-clicked part.
        s.click("e", .extend, in: after)
        #expect(s.selected(after, id: { $0 }) == ["a", "e", "f", "g"])
    }

    @Test func aRefreshedListsShortPartKeepsLaterSelectedRowsUntilItIsWhole() {
        // Rows 1–6 shown; "f" (a later page's song) selected along with "b".
        let whole = ["a", "b", "c", "d", "e", "f"]
        var s = TrackSelection()
        s.click("b", .select, in: whole)
        s.click("f", .toggle, in: whole)
        // Fresh detail: only the first page for now, loading again.
        let prefix = ["a", "b", "c"]
        s.rowsChanged(from: whole, to: prefix, holding: true)
        #expect(s.contains("f"))
        // Acted on: only the selected rows shown.
        #expect(s.selected(prefix, id: { $0 }) == ["b"])
        // The page is back: "f" is still selected.
        s.rowsChanged(from: prefix, to: whole, holding: true)
        s.keep(whole)
        #expect(s.selected(whole, id: { $0 }) == ["b", "f"])
        // A filter (not a refresh) does drop it.
        s.rowsChanged(from: whole, to: prefix, holding: false)
        #expect(!s.contains("f"))
    }

    @Test func aRefillThatEndsWithoutTheRowDropsIt() {
        let whole = ["a", "b", "c", "d"]
        var s = TrackSelection()
        s.click("d", .select, in: whole)
        s.rowsChanged(from: whole, to: ["a", "b"], holding: true)
        #expect(s.contains("d"))
        // The refreshed playlist ended at "c": "d" was removed after all.
        s.rowsChanged(from: ["a", "b"], to: ["a", "b", "c"], holding: true)
        s.keep(["a", "b", "c"])
        #expect(s.isEmpty)
    }

    // MARK: Actions on the selection

    private func model() async -> AppModel {
        let model = AppModel(environment: ["MEDLEY_MOCK": "1"])
        model.noticeDuration = .seconds(10)
        await model.refreshLibraryState()
        return model
    }

    private func spotify(_ model: AppModel) throws -> MockProvider {
        try #require(model.providers.first { $0.id == .spotify } as? MockProvider)
    }

    @Test func playNextAndAddToQueuePutTheSelectedRowsInTheOrderShown() async throws {
        let model = await model()
        let sp = try spotify(model)
        let songs = Array(sp.catalog.allTracks.filter(\.isPlayable).prefix(8))
        try #require(songs.count == 8)
        model.play([songs[0]], from: AppModel.PlayingFrom(title: "Test"))
        // Rows shown in some order, three of them selected out of order of clicking.
        let shown = Array(songs[1...7])
        var s = TrackSelection()
        s.click(shown[4].id, .select, in: shown.map(\.id))
        s.click(shown[1].id, .toggle, in: shown.map(\.id))
        s.click(shown[2].id, .extend, in: shown.map(\.id))
        let selected = s.selected(shown, id: \.id)
        #expect(selected.map(\.id) == [shown[1], shown[2], shown[4]].map(\.id))
        model.playNext(selected)
        #expect(model.player.upNext.prefix(3).map(\.track.id) == selected.map(\.id))
        #expect(model.notice?.text == "Playing next")
        model.addToQueue(selected)
        let user = model.player.upNext.filter { !$0.isAutoplay }.map(\.track.id)
        #expect(Array(user.suffix(3)) == selected.map(\.id))
        #expect(model.notice?.text == "Added to queue")
    }

    @Test func removingSeveralSelectedRowsIsOneRemovalWithOneUndo() async throws {
        let model = await model()
        let sp = try spotify(model)
        let page = try await sp.library(.playlists, continuation: nil)
        let playlist = try #require(page.items.compactMap { if case .playlist(let p) = $0, p.isEditable { p } else { nil } }.first)
        func ids() async throws -> [String] {
            var detail = try await sp.playlist(id: playlist.providerID)
            var all = detail.tracks
            while let next = detail.continuation {
                let page = try await sp.playlistTracks(continuation: next)
                all += page.items
                detail.continuation = page.continuation
            }
            return all.map(\.id)
        }
        let rows = try await sp.playlist(id: playlist.providerID).tracks
        try #require(rows.count >= 5)
        var s = TrackSelection()
        s.click(rows[1].id, .select, in: rows.map(\.id))
        s.click(rows[3].id, .toggle, in: rows.map(\.id))
        s.click(rows[4].id, .extend, in: rows.map(\.id))
        let selected = AppModel.eachOnce(s.selected(rows, id: \.id))
        #expect(selected.map(\.id) == [rows[1], rows[3], rows[4]].map(\.id))
        let before = try await ids()

        let undo = UndoManager()
        undo.groupsByEvent = false
        model.requestRemove(selected, from: playlist, undoManager: undo)
        try await Task.sleep(for: .milliseconds(400))
        let after = try await ids()
        #expect(after == before.filter { id in !selected.contains { $0.id == id } })
        #expect(undo.undoActionName == "Remove 3 Songs")
        #expect(model.notice?.action?.title == "Undo")

        // One Undo puts all three back where they were.
        undo.undo()
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await ids() == before)
        #expect(!undo.canUndo)
    }

    @Test func eachOnceKeepsTheFirstOfARepeatedSong() {
        let a = Track(providerID: "1", provider: .spotify, title: "One")
        let b = Track(providerID: "2", provider: .spotify, title: "Two")
        #expect(AppModel.eachOnce([a, b, a]).map(\.id) == [a.id, b.id])
    }

    // MARK: The header's Play in a sorted list

    @Test func headerPlayOfASortedAlbumQueuesTheWholeAlbumInTheOrderShown() async throws {
        let model = await model()
        let sp = try spotify(model)
        let album = try #require(sp.catalog.albums.first { (sp.catalog.albumTracks[$0.providerID]?.count ?? 0) > 3 })
        let tracks = try await sp.album(id: album.providerID).tracks
        let sort = TrackSort(key: .title, ascending: false)
        let queue = sort.headerQueue(tracks, shuffled: false)
        let expected = tracks.enumerated().sorted { a, b in
            let r = a.element.title.localizedStandardCompare(b.element.title)
            return r == .orderedSame ? a.offset < b.offset : r == .orderedDescending
        }.map(\.element)
        #expect(queue.map(\.id) == expected.map(\.id))
        #expect(queue.count == tracks.count)
        // Shuffle draws from the album itself; the original order plays as listed.
        #expect(sort.headerQueue(tracks, shuffled: true).map(\.id) == tracks.map(\.id))
        #expect(TrackSort.original.headerQueue(tracks, shuffled: false).map(\.id) == tracks.map(\.id))

        // Played as the album page's header does: the queue starts at the first song shown.
        let route = Route.album(album.provider, id: album.providerID, preview: album)
        let context = AppModel.PlayingFrom(title: album.title, route: route)
        model.playOrPause(route) { model.play(queue, from: context) }
        #expect(model.player.current?.id == expected.first?.id)
        #expect(model.player.queue.filter { !$0.isAutoplay }.map(\.track.id) == expected.map(\.id))
        // The header then shows Pause/Resume: a second press doesn't start it again.
        #expect(model.isCurrentContext(route))
        model.playOrPause(route) { Issue.record("started again") }
    }

    @Test func headerPlayOfASortedPlaylistLoadsTheRestAndQueuesItInTheOrderShown() async throws {
        let model = await model()
        let sp = try spotify(model)
        // A playlist longer than one page, so some songs aren't loaded when Play is pressed.
        var found: (Playlist, PlaylistDetail)?
        for p in sp.catalog.playlists {
            if let detail = try? await sp.playlist(id: p.providerID), detail.continuation != nil { found = (p, detail); break }
        }
        let (playlist, detail) = try #require(found)
        var all = detail.tracks
        var token = detail.continuation
        while let t = token {
            let page = try await sp.playlistTracks(continuation: t)
            all += page.items.filter { s in !all.contains { $0.id == s.id } }
            token = page.continuation
        }
        #expect(all.count > detail.tracks.count)
        let sort = TrackSort(key: .title, ascending: false)
        let expected = all.sorted { a, b in
            let r = a.title.localizedStandardCompare(b.title)
            return r == .orderedSame ? all.firstIndex(of: a)! < all.firstIndex(of: b)! : r == .orderedDescending
        }
        let context = AppModel.PlayingFrom(title: playlist.title, route: .playlist(playlist.provider, id: playlist.providerID, preview: playlist))
        await model.playPlaylistSorted(detail.tracks, continuation: detail.continuation, provider: .spotify, sort: sort, from: context)
        #expect(model.player.current?.id == expected.first?.id)
        #expect(model.player.queue.filter { !$0.isAutoplay }.map(\.track.id) == expected.map(\.id))
        #expect(model.playingFrom == context)

        // From a row: the same order, starting at that song.
        let row = expected[5]
        await model.playPlaylistSorted(detail.tracks, continuation: detail.continuation, provider: .spotify, sort: sort, startID: row.id, from: context)
        #expect(model.player.current?.id == row.id)
        #expect(model.player.queue.filter { !$0.isAutoplay }.map(\.track.id) == expected.map(\.id))
    }

    @Test func aChoiceMadeWhileTheSortedPlaylistLoadsWins() async throws {
        let model = await model()
        let sp = try spotify(model)
        var found: (Playlist, PlaylistDetail)?
        for p in sp.catalog.playlists {
            if let detail = try? await sp.playlist(id: p.providerID), detail.continuation != nil { found = (p, detail); break }
        }
        let (playlist, detail) = try #require(found)
        let song = try #require(sp.catalog.allTracks.first { $0.isPlayable })
        let context = AppModel.PlayingFrom(title: playlist.title)
        // The rest of the playlist takes a moment to arrive.
        sp.latency = .milliseconds(150)
        let task = Task { await model.playPlaylistSorted(detail.tracks, continuation: detail.continuation, provider: .spotify, sort: .title, from: context) }
        // Chosen before the rest of the playlist arrives.
        try await Task.sleep(for: .milliseconds(50))
        model.play([song], from: AppModel.PlayingFrom(title: song.title))
        await task.value
        #expect(model.player.current?.id == song.id)
        #expect(model.playingFrom?.title == song.title)
    }

    // MARK: Caption strips

    @Test func captionShadeHoldsTheDetailLineAtFourAndAHalfToOne() {
        // Mid-gray art: the fixed half black is enough.
        #expect(CaptionShade.needed(over: (0.6, 0.6, 0.6), opacity: 0.9, minimum: 0.5) == 0.5)
        #expect(CaptionShade.contrast(over: (0.6, 0.6, 0.6), shade: 0.5, opacity: 0.9) >= 4.5)
        // Daily Mix 2's pale gray (about 82%) too.
        #expect(CaptionShade.contrast(over: (0.82, 0.82, 0.82), shade: 0.5, opacity: 0.9) >= 4.5)
        // White art needs more, and gets just enough.
        let white = CaptionShade.needed(over: (1, 1, 1), opacity: 0.9, minimum: 0.5)
        #expect(white > 0.5 && white < 0.7)
        #expect(CaptionShade.contrast(over: (1, 1, 1), shade: white, opacity: 0.9) >= 4.5)
        #expect(CaptionShade.contrast(over: (1, 1, 1), shade: 0.5, opacity: 0.9) < 4.5)
    }
}
