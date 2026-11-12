import MedleyCore
import Observation

/// A playlist page's later pages: the songs after the first page, the next token, and whether a request runs.
///
/// Every request runs inside the caller's `await` (the page's lifecycle-owned `.task`), never in a task of its own, so
/// leaving the page cancels it: a rate-limit wait or retry in the provider ends with the page, and coming back starts
/// one fresh request instead of a second beside the first. A request that was cancelled, or overtaken by a newer one,
/// publishes nothing.
///
/// Opening loads the rest at once only for a playlist whose service gave its total (`knownTotal`, never a count of
/// the first page standing in for it) of at most `eagerLoadLimit` songs, and only for `eagerPageBudget` pages. A
/// token the service already handed out (or hands back unchanged) ends the list instead of looping on it.
///
/// Each song is listed once: a song the playlist holds twice (Spotify and YouTube both allow it) keeps its first
/// place, on the first page and on every later one, and its row says how many copies there are (`copies`, "2×"):
/// a copy on a later page adds to the row already listed. Rows, selection, Play from a row and the queue all go by
/// `Track.id`; Remove from Playlist takes every copy (`AppModel.remove`), and its menu item says so.
///
/// The header counts entries, never rows: the service's total (`knownTotal`), which the rows' copies add up to once
/// every entry is loaded, and the total length counts each copy.
@MainActor @Observable
final class PlaylistPager {
    /// Playlists up to this many songs load all their pages when opened (a few requests), so the header can give
    /// their total length.
    static let eagerLoadLimit = 200
    /// At most this many pages load without the listener asking: 200 songs in the mock's 25-song pages is 7 after the
    /// first; YouTube and Spotify send 100 a page.
    static let eagerPageBudget = 8
    /// At most this many pages load by themselves while the list has no rows to show (a playlist opening on entries
    /// Medley leaves out, such as Spotify's local files and episodes): there is no last row to scroll to, so past it
    /// the page offers Load More. They count as eager pages too, so neither budget can be passed through the other.
    static let emptyPageBudget = 5

    let firstPage: [Track]
    /// The service's own song count, nil when it gave none.
    let knownTotal: Int?
    private(set) var more: [Track] = []
    private(set) var continuation: String?
    private(set) var isLoading = false
    /// The last request's failure, shown with Try Again. Loading stops until it's cleared.
    var error: String?
    /// Pages loaded so far after the first (a page of songs already listed still counts, so a caller keyed on it
    /// moves on).
    private(set) var pagesLoaded = 0
    /// Pages loaded without the listener asking: because the playlist is short, or because the list had no rows.
    private(set) var eagerPages = 0
    /// Of those, the pages loaded because the list had no rows to show.
    private(set) var emptyPages = 0
    /// True when the service handed back a token it had already given: the list ended there.
    private(set) var stoppedOnRepeatedToken = false

    @ObservationIgnored private var usedTokens: Set<String> = []
    @ObservationIgnored private var generation = 0

    /// Every entry the service listed so far, repeats and entries left out (Spotify's local files) included: the
    /// service's total counts them.
    private(set) var entriesSeen: Int
    /// How many entries each listed song has so far, by `Track.id`: 2 for a song the playlist holds twice. A copy on a
    /// later page adds to the count of the row listed earlier.
    private(set) var copies: [String: Int] = [:]

    init(firstPage: [Track], continuation: String?, knownTotal: Int?, entryCount: Int? = nil) {
        var seen = Set<String>()
        self.firstPage = firstPage.filter { seen.insert($0.id).inserted }
        self.entriesSeen = entryCount ?? firstPage.count
        self.continuation = continuation
        self.knownTotal = knownTotal
        for track in firstPage { copies[track.id, default: 0] += 1 }
    }

    convenience init(_ detail: PlaylistDetail) {
        self.init(firstPage: detail.tracks, continuation: detail.continuation, knownTotal: detail.playlist.trackCount, entryCount: detail.entryCount)
    }

    var tracks: [Track] { firstPage + more }

    /// The header's song count: the service's total of entries, every copy counted, or the entries listed so far when
    /// the service gave none. It never switches to the number of rows.
    var entryTotal: Int { knownTotal ?? entriesSeen }

    /// Every entry is loaded: no token left, the list didn't end on a token handed out twice (the service stopped
    /// paging, not the playlist), and the service listed as many entries as its total says.
    var isComplete: Bool {
        continuation == nil && !stoppedOnRepeatedToken && (knownTotal.map { entriesSeen >= $0 } ?? true)
    }

    /// Whether the page should fetch another page on its own: a known total within `eagerLoadLimit`, pages left in
    /// the budget, and nothing failed. A list with no rows yet loads only as `wantsEmptyPage` allows.
    var wantsEagerPage: Bool {
        guard !tracks.isEmpty, continuation != nil, error == nil, eagerPages < Self.eagerPageBudget, let knownTotal else { return false }
        return knownTotal <= Self.eagerLoadLimit
    }

    /// Whether the page should fetch another page on its own because it has no rows to show: pages left, nothing
    /// failed, and both `emptyPageBudget` and `eagerPageBudget` not yet used up.
    var wantsEmptyPage: Bool {
        tracks.isEmpty && continuation != nil && error == nil
            && emptyPages < Self.emptyPageBudget && eagerPages < Self.eagerPageBudget
    }

    /// Fetches the next page through `fetch` and appends its new songs. Runs in the caller's task: cancelling it
    /// cancels the request, and then nothing changes (no songs, no error). `eager` and `empty` count the page against
    /// those budgets (`empty` against both).
    func loadNext(eager: Bool = false, empty: Bool = false, fetch: (String) async throws -> Page<Track>) async {
        guard error == nil, let token = continuation, !Task.isCancelled else { return }
        generation += 1
        let mine = generation
        isLoading = true
        let result: Result<Page<Track>, any Error>
        do { result = .success(try await fetch(token)) } catch { result = .failure(error) }
        // Overtaken by a newer request (which owns `isLoading` now) or cancelled with the page: publish nothing.
        guard mine == generation else { return }
        defer { isLoading = false }
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let page):
            usedTokens.insert(token)
            var known = Set(tracks.map(\.id))
            more.append(contentsOf: page.items.filter { known.insert($0.id).inserted })
            // A song already listed (on this page or an earlier one) is one more copy of its row.
            for track in page.items { copies[track.id, default: 0] += 1 }
            entriesSeen += page.entryCount ?? page.items.count
            if let next = page.continuation, usedTokens.contains(next) {
                continuation = nil
                stoppedOnRepeatedToken = true
            } else {
                continuation = page.continuation
            }
            pagesLoaded += 1
            if eager || empty { eagerPages += 1 }
            if empty { emptyPages += 1 }
        case .failure(let failure):
            if failure is CancellationError { return }
            error = failure.localizedDescription
        }
    }
}
