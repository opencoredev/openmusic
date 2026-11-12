import Foundation
import OpenMusicCore
import Observation

/// Loads one library list (Songs, Liked Songs, Albums…) from every service that has one, and says honestly what it
/// got. Each service is loaded, saved and judged on its own:
///
/// - What a service loaded completely is saved under its own key (`savedKey`), so a later failure of the same
///   service shows that saved list, and a failure of the other service never touches it.
/// - A service whose first page fails is named in an `Issue` (`.failed`, or `.notRefreshed` while its saved list
///   stays on screen), with Try Again, or Sign In when the service says the sign-in is gone.
/// - A later page that fails is tried again after `retryDelays`; one that still fails is kept, the list loaded so
///   far stays on screen (`.partial`), and Try Again resumes from the kept pages instead of starting over.
/// - A service stops after `pageLimit` pages with its next page kept (`.more`, "Load More"), never as complete.
/// - A refresh that failed is never saved, so it can't replace a saved list with an empty one.
@MainActor
@Observable
final class LibraryLoader {
    enum Status: Equatable {
        /// Pages are still arriving.
        case loading
        /// Every service loaded every page.
        case complete
        /// Done, but at least one service has an `Issue`.
        case incomplete
    }

    /// Something the page must say about one service's part of the list.
    struct Issue: Identifiable, Equatable {
        enum Kind: Equatable {
            /// Nothing from this service: its first page failed and nothing was saved.
            case failed
            /// The refresh failed; the list saved earlier is shown.
            case notRefreshed
            /// Some pages loaded, a later one didn't (kept for Try Again).
            case partial
            /// Stopped at the page limit; more pages are kept for Load More.
            case more
        }

        let provider: ProviderID
        let kind: Kind
        /// The service says the sign-in is gone: the action is Sign In, not Try Again.
        let needsSignIn: Bool
        /// The failure's own words, for the detail line.
        let message: String?
        /// How many items of this service are on screen.
        let shown: Int
        var id: ProviderID { provider }
    }

    /// One service's list as saved after it loaded every page (or stopped at the page limit: `complete` false).
    struct Saved {
        let items: [MediaItem]
        let complete: Bool
    }

    private struct Service {
        let provider: any MusicProvider
        var saved: Saved?
        var savedDate: Date?
        /// This load's items, in the order they arrived.
        var loaded: [MediaItem] = []
        /// What the page shows for this service: the saved list until a refresh finishes, else `loaded`.
        var shown: [MediaItem] = []
        /// Kinds whose first page is still to load (or failed, until Try Again).
        var firstPages: [LibraryKind] = []
        var failedFirstPages: [LibraryKind] = []
        /// Next pages to load, and pages that failed after their retries.
        var tokens: [(kind: LibraryKind, token: String)] = []
        var failedTokens: [(kind: LibraryKind, token: String)] = []
        var lastError: (any Error)?
        var pages = 0
        var finished = false
        var issue: Issue?
    }

    let kinds: [LibraryKind]
    /// The list's name in keys ("songs", "recent").
    let listName: String
    private let cache: PageCache
    private var services: [Service]
    /// Pages a service loads before Load More, and the waits before each retry of a failed later page.
    var pageLimit = 200
    var retryDelays: [Duration] = [.milliseconds(600), .seconds(2)]
    /// How long a complete saved list counts as fresh (no refresh on the next visit).
    var freshFor: TimeInterval = 60

    /// Nil until there is something to show: a saved list, or every service's first page answered.
    private(set) var items: [MediaItem]?
    private(set) var status: Status = .loading
    private(set) var issues: [Issue] = []
    private var driver: Task<Void, Never>?

    init(kinds: [LibraryKind], listName: String, providers: [any MusicProvider], cache: PageCache) {
        self.kinds = kinds
        self.listName = listName
        self.cache = cache
        services = providers.map { Service(provider: $0) }
    }

    /// The key one service's list is saved under ("library:songs:spotify").
    static func savedKey(_ listName: String, _ provider: ProviderID) -> String { "library:\(listName):\(provider.rawValue)" }

    /// Every service's saved list, interleaved, when each has a complete one; nil otherwise. For Play on Liked Songs,
    /// which plays a list the page already loaded at once.
    static func savedList(_ listName: String, providers: [any MusicProvider], cache: PageCache) -> [MediaItem]? {
        var lists: [[MediaItem]] = []
        for provider in providers {
            guard let saved: (value: Saved, date: Date) = cache.value(for: savedKey(listName, provider.id)), saved.value.complete else { return nil }
            lists.append(saved.value.items)
        }
        return dedupe(interleave(lists))
    }

    // MARK: Loading

    /// Shows what was saved, then loads every service that isn't fresh. Returns when loading stops (cancelled with
    /// the calling task, as `.task` does when the page goes away).
    func load() async {
        cancel()
        for i in services.indices {
            // A page that appears again starts over from what was saved.
            services[i] = Service(provider: services[i].provider)
            let id = services[i].provider.id
            if let saved: (value: Saved, date: Date) = cache.value(for: Self.savedKey(listName, id)) {
                services[i].saved = saved.value
                services[i].savedDate = saved.date
                services[i].shown = saved.value.items
            }
            let fresh = services[i].saved?.complete == true
                && Date().timeIntervalSince(services[i].savedDate ?? .distantPast) < freshFor
            if fresh {
                services[i].finished = true
            } else {
                services[i].firstPages = kinds
            }
        }
        if services.contains(where: { $0.saved != nil }) || services.allSatisfy(\.finished) { publish() }
        await runDriver()
    }

    /// Try Again for one service: the first pages that failed and the later pages kept after failing load again;
    /// what loaded already stays.
    func retry(_ provider: ProviderID) {
        guard let i = services.firstIndex(where: { $0.provider.id == provider }) else { return }
        if services[i].finished, services[i].firstPages.isEmpty, services[i].failedFirstPages.isEmpty, services[i].failedTokens.isEmpty,
           services[i].tokens.isEmpty {
            // Nothing kept to resume (a saved list shown fresh): load it again from the top.
            services[i].loaded = []
            services[i].firstPages = kinds
        }
        services[i].firstPages += services[i].failedFirstPages
        services[i].failedFirstPages = []
        services[i].tokens += services[i].failedTokens
        services[i].failedTokens = []
        // A fresh page budget, as Load More gives, or a failure on the last allowed page could never be tried again.
        services[i].pages = 0
        restart(i)
    }

    /// Load More for a service that stopped at the page limit: another `pageLimit` pages.
    func loadMore(_ provider: ProviderID) {
        guard let i = services.firstIndex(where: { $0.provider.id == provider }) else { return }
        services[i].pages = 0
        restart(i)
    }

    func cancel() {
        driver?.cancel()
        driver = nil
    }

    private func restart(_ i: Int) {
        services[i].finished = false
        services[i].issue = nil
        services[i].lastError = nil
        publish()
        if driver == nil { Task { await runDriver() } }
    }

    private func runDriver() async {
        if let driver { return await driver.value }
        let task = Task { await drive() }
        driver = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if driver == task { driver = nil }
    }

    private func drive() async {
        // First pages, every service's, so something shows quickly.
        var answeredFirst = false
        while !Task.isCancelled {
            if let i = services.indices.first(where: { !services[$0].finished && !services[$0].firstPages.isEmpty }) {
                let kind = services[i].firstPages.removeFirst()
                do {
                    let page = try await services[i].provider.library(kind, continuation: nil)
                    if Task.isCancelled { return }
                    services[i].loaded += page.items
                    if let next = page.continuation { services[i].tokens.append((kind, next)) }
                } catch {
                    if Task.isCancelled { return }
                    services[i].failedFirstPages.append(kind)
                    services[i].lastError = error
                }
                finishIfDone(i)
                continue
            }
            if !answeredFirst {
                answeredFirst = true
                publish()
            }
            // Then the later pages, one service after the other.
            guard let i = nextServiceWithPages() else { break }
            let (kind, token) = services[i].tokens.removeFirst()
            let page = await page(i, kind, token)
            // A cancelled driver (Refresh, the page gone) changes nothing, so it can't save an old list as fresh.
            if Task.isCancelled { return }
            if let page {
                services[i].loaded += page.items
                if let next = page.continuation { services[i].tokens.append((kind, next)) }
            } else {
                services[i].failedTokens.append((kind, token))
            }
            services[i].pages += 1
            finishIfDone(i)
            if services[i].pages % 4 == 0 { publish() }
        }
        if Task.isCancelled { return }
        for i in services.indices { finishIfDone(i) }
        publish()
        // Cleared here, with no wait after the last check for work, so a Try Again from now on starts a new driver.
        driver = nil
    }

    private var turn = 0
    private func nextServiceWithPages() -> Int? {
        let ready = services.indices.filter { !services[$0].finished && !services[$0].tokens.isEmpty && services[$0].pages < pageLimit }
        guard !ready.isEmpty else { return nil }
        turn += 1
        return ready[turn % ready.count]
    }

    /// A later page, tried again after each of `retryDelays` before giving up. Nil when it failed or was cancelled.
    private func page(_ i: Int, _ kind: LibraryKind, _ token: String) async -> Page<MediaItem>? {
        for attempt in 0...retryDelays.count {
            if attempt > 0 {
                try? await Task.sleep(for: retryDelays[attempt - 1])
            }
            if Task.isCancelled { return nil }
            do {
                return try await services[i].provider.library(kind, continuation: token)
            } catch {
                if Task.isCancelled { return nil }
                services[i].lastError = error
                // A sign-in that's gone won't come back by waiting.
                if (error as? ProviderError) == .notSignedIn { return nil }
            }
        }
        return nil
    }

    /// Settles a service with no pages left to load now: what it shows, what the page says about it, and whether
    /// its list is saved.
    private func finishIfDone(_ i: Int) {
        var s = services[i]
        guard !s.finished, s.firstPages.isEmpty else { return }
        let stopped = !s.tokens.isEmpty
        guard !stopped || s.pages >= pageLimit else { return }
        s.finished = true
        let failedSome = !s.failedFirstPages.isEmpty || !s.failedTokens.isEmpty
        let needsSignIn = (s.lastError as? ProviderError) == .notSignedIn
        let id = s.provider.id
        // The short reason ("You’re offline.", "Spotify can’t be reached."), never the error's own text.
        let message = s.lastError.map { FailureReason($0, service: id).text }
        if failedSome {
            if let saved = s.saved {
                // The saved list stays; the failed refresh isn't saved.
                s.shown = saved.items
                s.issue = Issue(provider: id, kind: .notRefreshed, needsSignIn: needsSignIn, message: message, shown: saved.items.count)
            } else {
                s.shown = s.loaded
                let nothing = s.failedFirstPages.count == kinds.count
                s.issue = Issue(provider: id, kind: nothing ? .failed : .partial, needsSignIn: needsSignIn, message: message, shown: s.loaded.count)
            }
        } else {
            let items = Self.dedupe(s.loaded)
            s.shown = items
            cache.set(Saved(items: items, complete: !stopped), for: Self.savedKey(listName, id))
            s.saved = Saved(items: items, complete: !stopped)
            s.issue = stopped ? Issue(provider: id, kind: .more, needsSignIn: false, message: nil, shown: items.count) : nil
        }
        services[i] = s
    }

    private func publish() {
        for i in services.indices where !services[i].finished && services[i].saved == nil {
            services[i].shown = services[i].loaded
        }
        items = Self.dedupe(interleave(services.map(\.shown)))
        issues = services.compactMap(\.issue)
        status = !services.allSatisfy(\.finished) ? .loading : issues.isEmpty ? .complete : .incomplete
    }

    private static func dedupe(_ items: [MediaItem]) -> [MediaItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }
}
