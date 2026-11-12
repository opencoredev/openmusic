import AppKit
import MedleyCore
import Observation
import SwiftUI
import Testing
@testable import Medley

// `PlaylistPageProbe` exists in Debug builds only (release builds carry none of the page's test hooks).
#if DEBUG
/// The real playlist page (`PlaylistContent`) hosted in an `NSHostingView`, driven by the mock service: what its
/// `.task` does with the pager when fresh detail replaces it (6e52ec6), and the refill that keeps a refreshed list as
/// long as the listener had it.
@MainActor
@Suite struct PlaylistPageHostTests {
    /// The detail the hosted page shows; replacing it is what a refreshed cache entry does through `Loadable`.
    @MainActor @Observable final class DetailHolder {
        var detail: PlaylistDetail
        init(_ detail: PlaylistDetail) { self.detail = detail }
    }

    struct Hosted: View {
        let holder: DetailHolder
        let probe: PlaylistPageProbe
        var body: some View { PlaylistContent(detail: holder.detail).environment(\.playlistPageProbe, probe) }
    }

    /// Holds each later-page request until the test lets it go, and records which ones were cancelled meanwhile.
    @MainActor final class PageGate {
        private(set) var tokens: [String] = []
        private(set) var cancelled: Set<Int> = []
        private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]

        func hold(_ token: String) async {
            let index = tokens.count
            tokens.append(token)
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiting[index] = $0 }
            } onCancel: {
                Task { @MainActor in self.cancelled.insert(index) }
            }
        }

        func release(_ index: Int) { waiting.removeValue(forKey: index)?.resume() }
        func releaseAll() { for key in waiting.keys.sorted() { release(key) } }
    }

    /// Every pager the page used, in order, and the refill flag each task run saw.
    @MainActor final class PagerLog {
        private(set) var pagers: [PlaylistPager] = []
        private(set) var refilling: [(pager: Int, refilling: Bool)] = []

        func note(_ pager: PlaylistPager, _ refill: Bool) {
            if !pagers.contains(where: { $0 === pager }) { pagers.append(pager) }
            let index = pagers.firstIndex { $0 === pager } ?? 0
            refilling.append((index, refill))
        }
    }

    private func host(_ model: AppModel, _ holder: DetailHolder, log: PagerLog, probe: PlaylistPageProbe = PlaylistPageProbe()) -> NSHostingView<some View> {
        probe.onTask = { log.note($0, $1) }
        let view = NSHostingView(rootView: Hosted(holder: holder, probe: probe).environment(model))
        // Short enough that the list's last rows never appear, so nothing loads because of a scroll.
        view.frame = CGRect(x: 0, y: 0, width: 1100, height: 600)
        view.layoutSubtreeIfNeeded()
        pump.view = view
        return view
    }

    /// The hosting view, laid out on every poll: without a window nothing else asks it for an update pass.
    @MainActor final class Pump { var view: NSView? }
    private let pump = Pump()

    private func waitUntil(_ condition: () -> Bool, _ what: Comment) async throws {
        for _ in 0..<200 where !condition() {
            pump.view?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), what)
    }

    private func setUp() async throws -> (AppModel, MockProvider, PlaylistDetail) {
        let model = AppModel(environment: ["MEDLEY_MOCK": "1"])
        await model.refreshLibraryState()
        let sp = try #require(model.providers.first { $0.id == .spotify } as? MockProvider)
        var found: PlaylistDetail?
        for p in sp.catalog.playlists {
            if let detail = try? await sp.playlist(id: p.providerID), detail.continuation != nil,
               let total = detail.playlist.trackCount, total <= PlaylistPager.eagerLoadLimit {
                found = detail
                break
            }
        }
        return (model, sp, try #require(found))
    }

    /// 6e52ec6: fresh detail with every counter the same (no page loaded yet, not sorted, nothing asked for) still
    /// cancels the old pager's request and asks again through the new pager, and the old request, let go afterwards,
    /// publishes nothing.
    @Test func freshDetailCancelsTheOldPagersRequestAndLoadsThroughTheNewOne() async throws {
        let (model, sp, detail) = try await setUp()
        let gate = PageGate()
        sp.playlistPageGate = { await gate.hold($0) }
        let holder = DetailHolder(detail)
        let log = PagerLog()
        let view = host(model, holder, log: log)
        defer { gate.releaseAll(); _ = view }

        // The short playlist's eager request, held.
        try await waitUntil({ gate.tokens.count == 1 }, "the first pager asked for page 2")
        let old = try #require(log.pagers.first)
        #expect(old.isLoading)
        #expect(old.pagesLoaded == 0)

        // A refreshed cache entry: the same songs, so the new pager's counters equal the old one's.
        var fresh = detail
        fresh.playlist.extra["refreshed"] = "1"
        holder.detail = fresh
        try await waitUntil({ gate.tokens.count == 2 }, "the new pager asked for page 2")
        #expect(log.pagers.count == 2)
        #expect(gate.tokens[1] == gate.tokens[0])
        try await waitUntil({ gate.cancelled.contains(0) }, "the old request was cancelled")
        #expect(!gate.cancelled.contains(1))
        let new = log.pagers[1]
        #expect(new !== old)
        #expect(new.pagesLoaded == old.pagesLoaded)

        // The old result arrives after all: nothing published, on either pager.
        gate.release(0)
        try await Task.sleep(for: .milliseconds(150))
        #expect(old.more.isEmpty)
        #expect(old.pagesLoaded == 0)
        #expect(new.more.isEmpty)
        #expect(new.tracks.count == detail.tracks.count)

        // The new pager's own request publishes.
        gate.release(1)
        try await waitUntil({ new.pagesLoaded == 1 }, "the new pager loaded page 2")
        #expect(!new.more.isEmpty)
        #expect(old.more.isEmpty)
    }

    /// Fresh detail after the listener loaded later pages and selected a song on one of them: the new pager loads them
    /// again by itself (no scroll, no sort, a total it can't load eagerly) within its page budget, the rows holding the
    /// selection meanwhile, and the later song is still selected once its page is back.
    @Test func freshDetailRefillsToTheLengthTheListenerHadKeepingALaterSelectedRow() async throws {
        let (model, sp, found) = try await setUp()
        // No total: nothing loads eagerly, so only the refill can load the new pager's pages.
        var detail = found
        detail.playlist.trackCount = nil
        let holder = DetailHolder(detail)
        let log = PagerLog()
        let probe = PlaylistPageProbe()
        let view = host(model, holder, log: log, probe: probe)
        defer { _ = view }
        try await waitUntil({ !log.pagers.isEmpty && probe.selection != nil }, "the page made its pager and its list")
        let old = log.pagers[0]
        // As a scroll to the end would: the next page through the page's own pager.
        await old.loadNext { try await sp.playlistTracks(continuation: $0) }
        let loaded = old.tracks.count
        #expect(loaded > detail.tracks.count)
        // The listener selects a song on page 2 (and one on page 1).
        let later = old.tracks[detail.tracks.count + 1].id
        let early = old.tracks[1].id
        try await waitUntil({ (probe.selection?.wrappedValue.isEmpty ?? false) }, "the list is drawn")
        probe.selection?.wrappedValue.click(early, .select, in: old.tracks.map(\.id))
        probe.selection?.wrappedValue.click(later, .toggle, in: old.tracks.map(\.id))
        pump.view?.layoutSubtreeIfNeeded()
        #expect(probe.selection?.wrappedValue.contains(later) == true)
        let requests = sp.playlistPageRequests.count

        // Held while the new pager has only page 1.
        let gate = PageGate()
        sp.playlistPageGate = { await gate.hold($0) }
        var fresh = detail
        fresh.playlist.extra["refreshed"] = "1"
        holder.detail = fresh
        try await waitUntil({ gate.tokens.count == 1 }, "the refill asked for page 2")
        #expect(probe.holdsSelection)
        #expect(probe.selection?.wrappedValue.contains(later) == true, "a later page's song stays selected while its page loads again")
        sp.playlistPageGate = nil
        gate.releaseAll()

        try await waitUntil({ log.pagers.count == 2 && log.pagers[1].tracks.count >= loaded }, "the new pager loaded back to \(loaded) songs")
        let new = log.pagers[1]
        #expect(log.refilling.contains { $0.pager == 1 && $0.refilling })
        try await waitUntil({ log.refilling.last.map { $0.pager == 1 && !$0.refilling } == true && !probe.holdsSelection }, "the refill ended")
        #expect(new.tracks.map(\.id) == old.tracks.map(\.id))
        // Back, and still selected with the first page's song.
        let selection = try #require(probe.selection?.wrappedValue)
        #expect(selection.selected(new.tracks).map(\.id) == [early, later])
        // The refill asked for no more pages than it needed (one here), well inside its budget.
        #expect(sp.playlistPageRequests.count - requests == old.pagesLoaded)
    }

    /// A page that fails during the refill: the refill target and the held selection stay; Try Again goes on refilling
    /// and the later song is selected again once its page is back.
    @Test func aRefillWhosePageFailsKeepsTheSelectionAndTryAgainGoesOn() async throws {
        let (model, sp, found) = try await setUp()
        var detail = found
        detail.playlist.trackCount = nil
        let holder = DetailHolder(detail)
        let log = PagerLog()
        let probe = PlaylistPageProbe()
        let view = host(model, holder, log: log, probe: probe)
        defer { _ = view }
        try await waitUntil({ !log.pagers.isEmpty && probe.selection != nil }, "the page made its pager and its list")
        let old = log.pagers[0]
        await old.loadNext { try await sp.playlistTracks(continuation: $0) }
        let loaded = old.tracks.count
        let later = old.tracks[detail.tracks.count + 1].id
        probe.selection?.wrappedValue.click(later, .select, in: old.tracks.map(\.id))
        pump.view?.layoutSubtreeIfNeeded()

        // Page 2 fails once on the new pager.
        let token = try #require(detail.continuation)
        sp.playlistPageFailures[token] = (.network("offline"), 1)
        var fresh = detail
        fresh.playlist.extra["refreshed"] = "1"
        holder.detail = fresh
        try await waitUntil({ log.pagers.count == 2 && log.pagers[1].error != nil }, "the refill's page failed")
        let new = log.pagers[1]
        // Let the page settle with the failure shown: the selection is still held, and nothing else was asked for.
        for _ in 0..<10 { pump.view?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(probe.holdsSelection, "a failed page doesn't end the hold")
        #expect(probe.selection?.wrappedValue.contains(later) == true)
        #expect(!new.tracks.contains { $0.id == later })

        // Try Again: the refill goes on to the old length, and the song is selected and shown again.
        let tryAgain = try #require(probe.tryAgain)
        tryAgain()
        try await waitUntil({ new.tracks.count >= loaded && !probe.holdsSelection }, "the refill caught up after Try Again")
        #expect(new.error == nil)
        #expect(probe.selection?.wrappedValue.selected(new.tracks).map(\.id) == [later])
    }

    /// A refresh whose first page has nothing to show (Spotify's local files and episodes, left out of the rows) while
    /// a later page's song is selected: the list stays mounted through the refill, the empty state never replaces it,
    /// and the song is still selected once its page is back.
    @Test func anEmptyFirstPageDuringARefillKeepsTheListAndTheSelection() async throws {
        let (model, sp, found) = try await setUp()
        var detail = found
        detail.playlist.trackCount = nil
        let holder = DetailHolder(detail)
        let log = PagerLog()
        let probe = PlaylistPageProbe()
        let view = host(model, holder, log: log, probe: probe)
        defer { _ = view }
        try await waitUntil({ !log.pagers.isEmpty && probe.selection != nil }, "the page made its pager and its list")
        let old = log.pagers[0]
        await old.loadNext { try await sp.playlistTracks(continuation: $0) }
        let later = old.tracks[detail.tracks.count + 1].id
        probe.selection?.wrappedValue.click(later, .select, in: old.tracks.map(\.id))
        pump.view?.layoutSubtreeIfNeeded()
        #expect(probe.selection?.wrappedValue.contains(later) == true)

        // Refreshed: every song of page 1 is now an entry the service lists but Medley leaves out.
        sp.unlistedTrackIDs = Set(detail.tracks.map(\.id))
        var fresh = try await sp.playlist(id: detail.playlist.providerID)
        #expect(fresh.tracks.isEmpty)
        #expect(fresh.continuation != nil)
        fresh.playlist.trackCount = nil
        fresh.playlist.extra["refreshed"] = "1"
        // The refill's page 2 is held, so the page draws its empty first page for a while.
        let gate = PageGate()
        sp.playlistPageGate = { await gate.hold($0) }
        holder.detail = fresh
        try await waitUntil({ gate.tokens.count == 1 }, "the refill asked for page 2")
        for _ in 0..<10 { pump.view?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(log.pagers[1].tracks.isEmpty)
        #expect(probe.holdsSelection)
        sp.playlistPageGate = nil
        gate.releaseAll()
        try await waitUntil({ log.pagers.count == 2 && log.pagers[1].tracks.contains { $0.id == later } }, "the refill brought the song back")
        for _ in 0..<5 { pump.view?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(probe.selection?.wrappedValue.selected(log.pagers[1].tracks).map(\.id) == [later], "the selection outlived the empty first page")
    }

    /// A playlist whose 40 pages (distinct tokens) all have nothing to show: the page loads at most
    /// `PlaylistContent.emptyPageBudget` of them by itself, whether or not the service gave a short total (eager pages)
    /// or a refill holds a selection, then stops with the list mounted.
    @Test(arguments: [false, true])
    func emptyPagesStopAtTheirBudget(knownTotal: Bool) async throws {
        let (model, sp, _) = try await setUp()
        let ghost = try #require(sp.catalog.allTracks.first)
        let playlist = try await sp.createPlaylist(title: "Ghosts", description: nil)
        try await sp.add(Array(repeating: ghost, count: 1000), toPlaylist: playlist.providerID)
        sp.unlistedTrackIDs = [ghost.id]
        var detail = try await sp.playlist(id: playlist.providerID)
        #expect(detail.tracks.isEmpty)
        // A short total would load eagerly; the empty pages still count against their own budget.
        detail.playlist.trackCount = knownTotal ? 150 : nil
        let requests = sp.playlistPageRequests.count
        let holder = DetailHolder(detail)
        let log = PagerLog()
        let probe = PlaylistPageProbe()
        let view = host(model, holder, log: log, probe: probe)
        defer { _ = view }
        try await waitUntil({ (log.pagers.first?.pagesLoaded ?? 0) >= 5 }, "the empty pages loaded")
        for _ in 0..<30 { pump.view?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(sp.playlistPageRequests.count - requests == PlaylistPager.emptyPageBudget, "no more than the empty-page budget")
        #expect(probe.selection != nil, "the list stays mounted")
        try await waitUntil({ probe.showsLoadMore }, "Load More shows at the bound")
        // Load More asks for one page, then waits again.
        let loadMore = try #require(probe.loadMore)
        loadMore()
        try await waitUntil({ sp.playlistPageRequests.count - requests == PlaylistPager.emptyPageBudget + 1 && probe.showsLoadMore }, "one more page, then Load More again")
        for _ in 0..<20 { pump.view?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(sp.playlistPageRequests.count - requests == PlaylistPager.emptyPageBudget + 1)
    }

    /// A refill whose new pager's pages are all empty: the refill's own budget and the empty-page budget bound it
    /// together; the held selection stays and nothing loads past them.
    @Test func emptyPagesDuringARefillStopAtTheBudgetHoldingTheSelection() async throws {
        let (model, sp, found) = try await setUp()
        var detail = found
        detail.playlist.trackCount = nil
        let holder = DetailHolder(detail)
        let log = PagerLog()
        let probe = PlaylistPageProbe()
        let view = host(model, holder, log: log, probe: probe)
        defer { _ = view }
        try await waitUntil({ !log.pagers.isEmpty && probe.selection != nil }, "the page made its pager and its list")
        let old = log.pagers[0]
        await old.loadNext { try await sp.playlistTracks(continuation: $0) }
        let later = old.tracks[detail.tracks.count + 1].id
        probe.selection?.wrappedValue.click(later, .select, in: old.tracks.map(\.id))
        pump.view?.layoutSubtreeIfNeeded()

        // Refreshed: the playlist is now 1000 entries Medley leaves out, after its songs.
        let ghost = try #require(sp.catalog.allTracks.last { !old.tracks.map(\.id).contains($0.id) })
        try await sp.insert(Array(repeating: ghost, count: 1000), intoPlaylist: detail.playlist.providerID, at: 0)
        sp.unlistedTrackIDs = [ghost.id]
        var fresh = try await sp.playlist(id: detail.playlist.providerID)
        #expect(fresh.tracks.isEmpty)
        fresh.playlist.trackCount = nil
        fresh.playlist.extra["refreshed"] = "1"
        let requests = sp.playlistPageRequests.count
        holder.detail = fresh
        try await waitUntil({ log.pagers.count == 2 && log.pagers[1].pagesLoaded >= 3 }, "the refill loaded its pages")
        for _ in 0..<30 { pump.view?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(sp.playlistPageRequests.count - requests <= PlaylistContent.Refill.slack + old.pagesLoaded, "the refill's budget")
        #expect(probe.holdsSelection)
        #expect(probe.selection?.wrappedValue.contains(later) == true, "the selection is still held")
        try await waitUntil({ probe.showsLoadMore }, "Load More shows at the bound, the list still mounted")
        #expect(probe.selection != nil)
    }

    /// A partly applied removal of the page's playlist: while its failure notice is up the page shows no banner; once
    /// the notice is closed the banner (Undo, Try Again, Leave As Is) keeps the edit in view, and Leave As Is ends it.
    @Test func aPartialEditWithItsNoticeClosedShowsTheBanner() async throws {
        let (model, sp, found) = try await setUp()
        model.noticeDuration = .seconds(30)
        let holder = DetailHolder(found)
        let log = PagerLog()
        let probe = PlaylistPageProbe()
        let view = host(model, holder, log: log, probe: probe)
        defer { _ = view }
        try await waitUntil({ probe.selection != nil }, "the list is drawn")
        sp.editBatchSize = 1
        sp.playlistEditFailures = [sp.playlistEdits.count + 2: .network("offline")]
        await model.remove(Array(found.tracks.prefix(2)), from: found.playlist, undoManager: UndoManager()).value
        let edit = try #require(model.partialEdit(of: found.playlist))
        #expect(model.notice?.edit === edit)
        for _ in 0..<10 { pump.view?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(!probe.showsEditBanner, "the notice carries the buttons while it is up")
        model.dismissNotice()
        try await waitUntil({ probe.showsEditBanner }, "the banner shows once the notice is closed")
        #expect(!model.canEdit(found.playlist))
        model.leaveAsIs(edit)
        try await waitUntil({ !probe.showsEditBanner }, "Leave As Is ends it")
        #expect(model.canEdit(found.playlist))
    }

    /// Find with a later page's song selected, then a refresh whose refill page fails: nothing on the page matches the
    /// query for now, so "No songs match" shows, but the list stays mounted under it and keeps holding the selection;
    /// after Try Again the song is back, matched and still selected.
    @Test func findWithAHeldSelectionKeepsItWhileNothingMatches() async throws {
        let (model, sp, found) = try await setUp()
        var detail = found
        detail.playlist.trackCount = nil
        let holder = DetailHolder(detail)
        let log = PagerLog()
        let probe = PlaylistPageProbe()
        let view = host(model, holder, log: log, probe: probe)
        defer { _ = view }
        try await waitUntil({ !log.pagers.isEmpty && probe.selection != nil && probe.query != nil }, "the page made its pager, list and Find")
        let old = log.pagers[0]
        await old.loadNext { try await sp.playlistTracks(continuation: $0) }
        let loaded = old.tracks.count
        // A song on page 2 whose title matches nothing on page 1.
        let firstPage = Array(old.tracks.prefix(detail.tracks.count))
        let later = try #require(old.tracks.dropFirst(detail.tracks.count).first { TrackFilter.matches(firstPage, query: $0.title).isEmpty })
        probe.query?.wrappedValue = later.title
        pump.view?.layoutSubtreeIfNeeded()
        probe.selection?.wrappedValue.click(later.id, .select, in: [later.id])
        pump.view?.layoutSubtreeIfNeeded()
        #expect(probe.selection?.wrappedValue.contains(later.id) == true)

        // Refreshed; the refill's page 2 fails once, so the matching song is missing for now.
        let token = try #require(detail.continuation)
        sp.playlistPageFailures[token] = (.network("offline"), 1)
        var fresh = detail
        fresh.playlist.extra["refreshed"] = "1"
        holder.detail = fresh
        try await waitUntil({ log.pagers.count == 2 && log.pagers[1].error != nil }, "the refill's page failed")
        for _ in 0..<10 { pump.view?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(probe.holdsSelection)
        #expect(probe.selection?.wrappedValue.contains(later.id) == true, "the selection outlives a query that matches nothing yet")

        let tryAgain = try #require(probe.tryAgain)
        tryAgain()
        let new = log.pagers[1]
        try await waitUntil({ new.tracks.count >= loaded && !probe.holdsSelection }, "the refill caught up after Try Again")
        #expect(probe.selection?.wrappedValue.selected(new.tracks).map(\.id) == [later.id])
    }

    // MARK: Sol's round 36 P2: the banner wherever the page is

    /// The last song removed, then its Undo failing offline: the page says "This playlist is empty", and with the
    /// failure notice closed the banner is mounted over it with Try Again and Leave As Is (read from the banner itself,
    /// not from the model). Its Try Again puts the song back, and the banner goes.
    @Test func thePartialEditBannerShowsOnAnEmptyPlaylist() async throws {
        let model = AppModel(environment: ["MEDLEY_MOCK": "1"])
        model.noticeDuration = .seconds(30)
        let sp = try #require(model.providers.first { $0.id == .spotify } as? MockProvider)
        let song = try #require(sp.catalog.allTracks.first)
        let playlist = try await sp.createPlaylist(title: "One Song", description: nil)
        try await sp.add([song], toPlaylist: playlist.providerID)
        let holder = DetailHolder(try await sp.playlist(id: playlist.providerID))
        let probe = PlaylistPageProbe()
        let view = host(model, holder, log: PagerLog(), probe: probe)
        defer { _ = view }
        try await waitUntil({ probe.selection != nil }, "the list is drawn")

        let undo = UndoManager()
        undo.groupsByEvent = false
        await model.remove([song], from: playlist, undoManager: undo).value
        holder.detail = try await sp.playlist(id: playlist.providerID)
        #expect(holder.detail.tracks.isEmpty)
        for _ in 0..<10 { pump.view?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }

        sp.playlistEditFailures = [sp.playlistEdits.count + 1: .network("offline")]
        undo.undo()
        await model.lastPlaylistEdit?.value
        let edit = try #require(model.partialEdit(of: playlist))
        #expect(model.notice?.edit === edit)
        model.dismissNotice()
        try await waitUntil({ probe.editBanner.map { Set($0.keys) } == ["Try Again", "Leave As Is"] }, "the banner and its buttons are mounted on the empty page")

        let tryAgain = try #require(probe.editBanner?["Try Again"])
        tryAgain()
        await model.lastPlaylistEdit?.value
        #expect(sp.catalog.playlistTracks[playlist.providerID]?.map(\.id) == [song.id], "the song is back")
        #expect(model.canEdit(playlist))
        try await waitUntil({ probe.editBanner == nil }, "the banner goes")
    }

    /// A partly applied edit of a playlist whose page can't load (offline): the error page carries the banner too.
    @Test func thePartialEditBannerShowsOverALoadingError() async throws {
        let model = AppModel(environment: ["MEDLEY_MOCK": "1"])
        model.noticeDuration = .seconds(30)
        let sp = try #require(model.providers.first { $0.id == .spotify } as? MockProvider)
        let songs = Array(sp.catalog.allTracks.prefix(3))
        let playlist = try await sp.createPlaylist(title: "Offline", description: nil)
        try await sp.add(songs, toPlaylist: playlist.providerID)
        sp.editBatchSize = 1
        sp.playlistEditFailures = [sp.playlistEdits.count + 2: .network("offline")]
        await model.remove(Array(songs.prefix(2)), from: playlist, undoManager: UndoManager()).value
        #expect(model.partialEdit(of: playlist) != nil)
        model.dismissNotice()
        sp.detailFailure = .network("offline")

        let probe = PlaylistPageProbe()
        let view = NSHostingView(rootView: PlaylistPage(provider: .spotify, id: playlist.providerID, preview: playlist)
            .environment(\.playlistPageProbe, probe).environment(model))
        view.frame = CGRect(x: 0, y: 0, width: 1100, height: 600)
        pump.view = view
        defer { _ = view }
        try await waitUntil({ probe.editBanner.map { Set($0.keys) } == ["Undo", "Try Again", "Leave As Is"] }, "the banner is mounted over the error page")
        let edit = try #require(model.partialEdit(of: playlist))
        let leave = try #require(probe.editBanner?["Leave As Is"])
        leave()
        #expect(model.partialEdit(of: playlist) == nil)
        #expect(model.canEdit(playlist))
        _ = edit
        try await waitUntil({ probe.editBanner == nil }, "the banner goes")
    }
}
#endif
