import Foundation
import MedleyCore
import Testing
@testable import Medley

/// A playlist page's later pages: a short playlist loads the rest only on a known total and within its page budget,
/// a repeated token ends the list, and a cancelled request publishes nothing.
@MainActor
@Suite struct PlaylistPagerTests {
    private func track(_ n: Int) -> Track {
        Track(providerID: "t\(n)", provider: .youtubeMusic, title: "Song \(n)", artists: [])
    }

    private func page(_ range: Range<Int>, next: String?) -> Page<Track> {
        Page(items: range.map(track), continuation: next)
    }

    /// Runs eager pages the way the page's task does, until the pager stops wanting one (or `limit` rounds).
    private func runEager(_ pager: PlaylistPager, limit: Int = 50, fetch: (String) async throws -> Page<Track>) async -> Int {
        var rounds = 0
        while pager.wantsEagerPage, rounds < limit {
            await pager.loadNext(eager: true, fetch: fetch)
            rounds += 1
        }
        return rounds
    }

    @Test func unknownTotalDoesNotLoadEagerly() async {
        // YouTube without "N songs" in the header: no total, so opening loads nothing more.
        let pager = PlaylistPager(firstPage: (0..<100).map(track), continuation: "p1", knownTotal: nil)
        #expect(!pager.wantsEagerPage)
        var requests = 0
        let rounds = await runEager(pager) { _ in requests += 1; return page(100..<200, next: "p2") }
        #expect(rounds == 0)
        #expect(requests == 0)
    }

    @Test func shortKnownTotalLoadsEverything() async {
        let pager = PlaylistPager(firstPage: (0..<25).map(track), continuation: "25", knownTotal: 60)
        let rounds = await runEager(pager) { token in
            let offset = Int(token)!
            let end = min(offset + 25, 60)
            return page(offset..<end, next: end < 60 ? "\(end)" : nil)
        }
        #expect(rounds == 2)
        #expect(pager.tracks.count == 60)
        #expect(pager.continuation == nil)
    }

    @Test func longKnownTotalDoesNotLoadEagerly() {
        let pager = PlaylistPager(firstPage: (0..<100).map(track), continuation: "p1", knownTotal: 1000)
        #expect(!pager.wantsEagerPage)
    }

    @Test func eagerLoadingStopsAtItsPageBudget() async {
        // A service that keeps handing out new tokens past the total it gave.
        let pager = PlaylistPager(firstPage: (0..<10).map(track), continuation: "1", knownTotal: 150)
        var requests = 0
        let rounds = await runEager(pager) { token in
            requests += 1
            let n = Int(token)!
            return page(n * 10..<(n + 1) * 10, next: "\(n + 1)")
        }
        #expect(rounds == PlaylistPager.eagerPageBudget)
        #expect(requests == PlaylistPager.eagerPageBudget)
        #expect(pager.continuation != nil)
    }

    @Test func repeatedTokenEndsTheList() async {
        let pager = PlaylistPager(firstPage: (0..<10).map(track), continuation: "a", knownTotal: 100)
        var requests = 0
        let rounds = await runEager(pager) { token in
            requests += 1
            // "a" → "b" → "a" again.
            return token == "a" ? page(10..<20, next: "b") : page(20..<30, next: "a")
        }
        #expect(rounds == 2)
        #expect(requests == 2)
        #expect(pager.continuation == nil)
        #expect(pager.stoppedOnRepeatedToken)
        #expect(pager.tracks.count == 30)
    }

    @Test func sameTokenBackEndsTheList() async {
        let pager = PlaylistPager(firstPage: [], continuation: "x", knownTotal: 50)
        await pager.loadNext { _ in page(0..<10, next: "x") }
        #expect(pager.continuation == nil)
        #expect(pager.stoppedOnRepeatedToken)
    }

    @Test func cancelledRequestPublishesNothing() async {
        let pager = PlaylistPager(firstPage: (0..<10).map(track), continuation: "p1", knownTotal: 40)
        let started = AsyncStream<Void>.makeStream()
        let task = Task { @MainActor in
            await pager.loadNext(eager: true) { _ in
                started.continuation.yield()
                // A rate-limit wait: ends early only by cancellation.
                try await Task.sleep(for: .seconds(30))
                return page(10..<20, next: "p2")
            }
        }
        for await _ in started.stream { break }
        #expect(pager.isLoading)
        task.cancel()
        await task.value
        #expect(pager.tracks.count == 10)
        #expect(pager.continuation == "p1")
        #expect(pager.error == nil)
        #expect(!pager.isLoading)
        #expect(pager.eagerPages == 0)
    }

    @Test func requestFinishingAfterCancelIsDropped() async {
        // A provider that ignores cancellation and answers anyway: the answer still isn't published.
        let pager = PlaylistPager(firstPage: [], continuation: "p1", knownTotal: nil)
        let task = Task { @MainActor in
            await pager.loadNext { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return page(0..<10, next: "p2")
            }
        }
        await task.value
        #expect(pager.tracks.isEmpty)
        #expect(pager.continuation == "p1")
        #expect(!pager.isLoading)
    }

    @Test func failureIsKeptForTryAgain() async {
        let pager = PlaylistPager(firstPage: [], continuation: "p1", knownTotal: 30)
        await pager.loadNext(eager: true) { _ in throw ProviderError.network("offline") }
        #expect(pager.error != nil)
        #expect(!pager.wantsEagerPage)
        pager.error = nil
        await pager.loadNext { _ in page(0..<30, next: nil) }
        #expect(pager.tracks.count == 30)
        #expect(pager.continuation == nil)
    }

    // MARK: Copies, the header's count, completeness

    /// A song the playlist holds twice is one row with two copies; a copy on page 3 of a song first listed on page 1
    /// adds to that row instead of being dropped.
    @Test func aRepeatOnALaterPageAddsACopyToTheFirstRow() async {
        // Page 1: songs 0, 1, 0. Page 2: 2. Page 3: 1, 3.
        let pager = PlaylistPager(firstPage: [track(0), track(1), track(0)], continuation: "p2", knownTotal: 6)
        #expect(pager.tracks.map(\.title) == ["Song 0", "Song 1"])
        #expect(pager.copies[track(0).id] == 2)
        await pager.loadNext { _ in page(2..<3, next: "p3") }
        await pager.loadNext { _ in Page(items: [track(1), track(3)], continuation: nil) }
        #expect(pager.tracks.map(\.title) == ["Song 0", "Song 1", "Song 2", "Song 3"])
        #expect(pager.copies[track(1).id] == 2)
        #expect(pager.copies[track(3).id] == 1)
        // The rows' copies add up to the service's total, which the header keeps throughout.
        #expect(pager.tracks.reduce(0) { $0 + (pager.copies[$1.id] ?? 0) } == 6)
        #expect(pager.entryTotal == 6)
        #expect(pager.isComplete)
    }

    /// The header's count is the service's total of entries before, during and after loading: never the rows.
    @Test func theHeaderKeepsTheServiceTotal() async {
        let pager = PlaylistPager(firstPage: [track(0), track(0), track(1)], continuation: "p2", knownTotal: 5)
        #expect(pager.entryTotal == 5)
        await pager.loadNext { _ in Page(items: [track(1), track(2)], continuation: nil) }
        #expect(pager.tracks.count == 3)
        #expect(pager.entryTotal == 5)
        // Without a total from the service: every entry listed so far, copies counted.
        let unknown = PlaylistPager(firstPage: [track(0), track(0), track(1)], continuation: nil, knownTotal: nil)
        #expect(unknown.entryTotal == 3)
        #expect(unknown.tracks.count == 2)
    }

    /// Entries a page leaves out (Spotify's local files) still count toward the total, so the list can be complete.
    @Test func entriesLeftOutOfAPageStillCount() async {
        let pager = PlaylistPager(firstPage: [track(0)], continuation: "p2", knownTotal: 4, entryCount: 2)
        await pager.loadNext { _ in Page(items: [track(1)], continuation: nil, positions: [3], entryCount: 2) }
        #expect(pager.entriesSeen == 4)
        #expect(pager.isComplete)
    }

    /// A list that ended on a token handed out twice isn't complete, even when the entries add up: the header gives
    /// no total length then.
    @Test func aRepeatedTokenStopIsNotComplete() async {
        let pager = PlaylistPager(firstPage: (0..<10).map(track), continuation: "a", knownTotal: 20)
        await pager.loadNext { _ in page(10..<20, next: "a") }
        #expect(pager.stoppedOnRepeatedToken)
        #expect(pager.continuation == nil)
        #expect(pager.entriesSeen == 20)
        #expect(!pager.isComplete)
        let unknown = PlaylistPager(firstPage: (0..<10).map(track), continuation: "a", knownTotal: nil)
        await unknown.loadNext { _ in page(10..<20, next: "a") }
        #expect(!unknown.isComplete)
    }

    /// The total length counts every copy of a song listed twice.
    @Test func theLengthCountsEveryCopy() {
        var a = track(0); a.duration = 100
        var b = track(1); b.duration = 60
        #expect(songCountLine(count: 3, tracks: [a, b], copies: [a.id: 2]) == "3 songs, \(TimeInterval(260).spokenLength)")
        #expect(songCountLine(count: 3, tracks: [a, b], complete: false, copies: [a.id: 2]) == "3 songs")
    }

    /// The page's task: no eager page while a refill holds the selection (its own budget used up, it waits for the
    /// listener), an asked-for page always, an eager page otherwise.
    /// A list whose pages (distinct tokens) have nothing to show loads `emptyPageBudget` of them by itself, counted as
    /// eager pages too, and then nothing more, even with a short known total.
    @Test func emptyPagesStopAtTheirBudgetAndCountAsEager() async {
        let pager = PlaylistPager(firstPage: [], continuation: "e1", knownTotal: 150)
        var pages = 0
        while pager.wantsEmptyPage || pager.wantsEagerPage, pages < 50 {
            pages += 1
            await pager.loadNext(empty: pager.wantsEmptyPage) { token in Page(items: [], continuation: "e\(pages + 1)") }
        }
        #expect(pages == PlaylistPager.emptyPageBudget)
        #expect(pager.emptyPages == PlaylistPager.emptyPageBudget)
        #expect(pager.eagerPages == PlaylistPager.emptyPageBudget)
        #expect(pager.continuation != nil)
        // Rows from a page the listener asked for: eager loading has only the rest of its budget.
        await pager.loadNext { _ in Page(items: [self.track(1)], continuation: "r1") }
        let eager = await runEager(pager) { token in Page(items: [], continuation: token + "x") }
        #expect(eager == PlaylistPager.eagerPageBudget - PlaylistPager.emptyPageBudget)
    }

    @Test func noEagerPageWhileARefillHolds() {
        typealias C = PlaylistContent
        #expect(C.nextLoad(reordered: false, wantsMore: false, refilling: false, holding: true, wantsEagerPage: true) == nil)
        #expect(C.nextLoad(reordered: false, wantsMore: false, refilling: false, holding: false, wantsEagerPage: true) == .eager)
        #expect(C.nextLoad(reordered: false, wantsMore: false, refilling: true, holding: true, wantsEagerPage: true) == .asked)
        #expect(C.nextLoad(reordered: false, wantsMore: true, refilling: false, holding: true, wantsEagerPage: true) == .asked)
        #expect(C.nextLoad(reordered: true, wantsMore: false, refilling: false, holding: false, wantsEagerPage: false) == .asked)
        #expect(C.nextLoad(reordered: false, wantsMore: false, refilling: false, holding: false, wantsEagerPage: false) == nil)
        // A list with no rows loads by itself only within the empty-page budget, and never while a refill holds.
        #expect(C.nextLoad(reordered: false, wantsMore: false, refilling: false, holding: false, wantsEagerPage: true, wantsEmptyPage: true) == .empty)
        #expect(C.nextLoad(reordered: false, wantsMore: false, refilling: false, holding: true, wantsEagerPage: false, wantsEmptyPage: true) == nil)
    }
}
