import Foundation
import OpenMusicCore
import Testing
@testable import OpenMusic

/// Library lists say honestly what loaded: a service whose first page fails is named while the other service's list
/// shows, a later page that fails is kept and resumed, the page limit ends in Load More rather than "complete", and a
/// failed refresh keeps the saved list instead of saving an empty one.
@MainActor
@Suite struct LibraryLoaderTests {
    private let offline = ProviderError.network("offline")

    private func loader(_ providers: [MockProvider], cache: PageCache, kind: LibraryKind = .songs) -> LibraryLoader {
        let loader = LibraryLoader(kinds: [kind], listName: kind.rawValue, providers: providers, cache: cache)
        // One quick retry of a failed later page.
        loader.retryDelays = [.zero]
        return loader
    }

    /// Every item of a service's list, read page by page straight from the mock.
    private func everything(_ provider: MockProvider, _ kind: LibraryKind = .songs) async throws -> [MediaItem] {
        var items: [MediaItem] = []
        var token: String?
        repeat {
            let page = try await provider.library(kind, continuation: token)
            items += page.items
            token = page.continuation
        } while token != nil
        return items
    }

    private func settle(_ loader: LibraryLoader) async {
        for _ in 0..<500 where loader.status == .loading { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func saved(_ cache: PageCache, _ provider: ProviderID, _ kind: LibraryKind = .songs) -> LibraryLoader.Saved? {
        let entry: (value: LibraryLoader.Saved, date: Date)? = cache.value(for: LibraryLoader.savedKey(kind.rawValue, provider))
        return entry?.value
    }

    private func services() async throws -> (MockProvider, MockProvider, Int, Int) {
        // Counted on copies, so the mocks the loader uses have no requests yet.
        let ytCount = try await everything(MockProvider(id: .youtubeMusic)).count
        let spCount = try await everything(MockProvider(id: .spotify)).count
        // Songs need a second page for the continuation tests.
        try #require(spCount > 50)
        return (MockProvider(id: .youtubeMusic), MockProvider(id: .spotify), ytCount, spCount)
    }

    @Test func aFailedFirstPageIsNamedWhileTheOtherServiceShows() async throws {
        let (yt, sp, ytCount, spCount) = try await services()
        sp.libraryPageFailures["songs:first"] = (offline, 1)
        let cache = PageCache()
        let loader = loader([yt, sp], cache: cache)
        await loader.load()

        #expect(loader.items?.count == ytCount)
        #expect(loader.items?.allSatisfy { $0.provider == .youtubeMusic } == true)
        #expect(loader.status == .incomplete)
        let issue = try #require(loader.issues.first)
        #expect(loader.issues.count == 1)
        #expect(issue.provider == .spotify && issue.kind == .failed && !issue.needsSignIn)
        #expect(issue.message == "Spotify can’t be reached.")
        // YouTube's complete list is saved; nothing is saved for Spotify.
        #expect(saved(cache, .youtubeMusic)?.items.count == ytCount)
        #expect(saved(cache, .youtubeMusic)?.complete == true)
        #expect(saved(cache, .spotify) == nil)

        // Try Again loads Spotify; YouTube's list stays as it was.
        loader.retry(.spotify)
        await settle(loader)
        #expect(loader.status == .complete)
        #expect(loader.issues.isEmpty)
        #expect(loader.items?.count == ytCount + spCount)
        #expect(saved(cache, .spotify)?.items.count == spCount)
    }

    @Test func aLostSignInAsksForThatServicesSignIn() async throws {
        let (yt, sp, ytCount, _) = try await services()
        sp.libraryFailure = .notSignedIn
        let loader = loader([yt, sp], cache: PageCache())
        await loader.load()
        #expect(loader.items?.count == ytCount)
        let issue = try #require(loader.issues.first)
        #expect(issue.provider == .spotify && issue.kind == .failed && issue.needsSignIn)
    }

    @Test func everyServiceFailingLeavesNoEmptyLibrary() async throws {
        let (yt, sp, _, _) = try await services()
        yt.libraryFailure = offline
        sp.libraryFailure = offline
        let cache = PageCache()
        let loader = loader([yt, sp], cache: cache)
        await loader.load()
        // Nothing to show, and the page knows why (an issue per service), so it never says "No songs yet".
        #expect(loader.items?.isEmpty == true)
        #expect(loader.status == .incomplete)
        #expect(Set(loader.issues.map(\.provider)) == [.youtubeMusic, .spotify])
        #expect(saved(cache, .youtubeMusic) == nil && saved(cache, .spotify) == nil)
    }

    @Test func aLaterPageThatFailsOnceIsRetried() async throws {
        let (yt, sp, ytCount, spCount) = try await services()
        sp.libraryPageFailures["songs:50"] = (offline, 1)
        let loader = loader([yt, sp], cache: PageCache())
        await loader.load()
        #expect(loader.status == .complete)
        #expect(loader.issues.isEmpty)
        #expect(loader.items?.count == ytCount + spCount)
        #expect(sp.libraryRequests.filter { $0 == "songs:50" }.count == 2)
    }

    @Test func aLaterPageThatKeepsFailingIsKeptAndResumed() async throws {
        let (yt, sp, ytCount, spCount) = try await services()
        // Fails the first try and its one retry.
        sp.libraryPageFailures["songs:50"] = (offline, 2)
        let cache = PageCache()
        let loader = loader([yt, sp], cache: cache)
        await loader.load()

        let issue = try #require(loader.issues.first)
        #expect(issue.provider == .spotify && issue.kind == .partial)
        #expect(issue.shown == 50)
        #expect(loader.status == .incomplete)
        #expect(loader.items?.count == ytCount + 50)
        // A partial list isn't saved as Spotify's library.
        #expect(saved(cache, .spotify) == nil)

        // Try Again asks for the kept page, not the first page again.
        let firstPages = sp.libraryRequests.filter { $0 == "songs:first" }.count
        loader.retry(.spotify)
        await settle(loader)
        #expect(sp.libraryRequests.filter { $0 == "songs:first" }.count == firstPages)
        #expect(sp.libraryRequests.filter { $0 == "songs:50" }.count == 3)
        #expect(loader.status == .complete)
        #expect(loader.items?.count == ytCount + spCount)
        #expect(saved(cache, .spotify)?.complete == true)
    }

    /// A later page that fails on the last page the limit allows is still tried again by Try Again (a fresh page
    /// budget), instead of the issue turning into Load More with no request made.
    @Test func tryAgainRetriesAFailureOnTheLastAllowedPage() async throws {
        let (yt, sp, _, _) = try await services()
        sp.libraryPageFailures["songs:50"] = (offline, 2)
        let loader = loader([yt, sp], cache: PageCache())
        loader.pageLimit = 1
        await loader.load()
        let issue = try #require(loader.issues.first { $0.provider == .spotify })
        #expect(issue.kind == .partial)
        #expect(sp.libraryRequests.filter { $0 == "songs:50" }.count == 2)

        loader.retry(.spotify)
        await settle(loader)
        #expect(sp.libraryRequests.filter { $0 == "songs:50" }.count == 3)
        #expect(loader.issues.first { $0.provider == .spotify }?.kind != .partial)
    }

    @Test func thePageLimitEndsInLoadMoreNotComplete() async throws {
        let (yt, sp, ytCount, spCount) = try await services()
        let cache = PageCache()
        let loader = loader([yt, sp], cache: cache)
        // No later pages at all: each service stops after its first.
        loader.pageLimit = 0
        await loader.load()

        #expect(loader.status == .incomplete)
        let spotify = try #require(loader.issues.first { $0.provider == .spotify })
        #expect(spotify.kind == .more && spotify.shown == 50)
        #expect(saved(cache, .spotify)?.complete == false)

        loader.pageLimit = 200
        for issue in loader.issues { loader.loadMore(issue.provider) }
        await settle(loader)
        #expect(loader.status == .complete)
        #expect(loader.items?.count == ytCount + spCount)
        #expect(saved(cache, .spotify)?.complete == true)
    }

    @Test func aFailedRefreshKeepsTheSavedList() async throws {
        let (yt, sp, ytCount, spCount) = try await services()
        let cache = PageCache()
        let first = loader([yt, sp], cache: cache)
        await first.load()
        #expect(first.status == .complete)
        // An hour later: no longer fresh, so the next visit refreshes.
        for id in [ProviderID.youtubeMusic, .spotify] {
            let key = LibraryLoader.savedKey(LibraryKind.songs.rawValue, id)
            let entry: (value: LibraryLoader.Saved, date: Date)? = cache.value(for: key)
            cache.set(try #require(entry).value, for: key, date: Date().addingTimeInterval(-3600))
        }
        sp.libraryFailure = offline

        let second = loader([yt, sp], cache: cache)
        await second.load()
        // Spotify's saved songs stay on the page and in the cache; the page says the refresh failed.
        #expect(second.items?.count == ytCount + spCount)
        let issue = try #require(second.issues.first)
        #expect(second.issues.count == 1)
        #expect(issue.provider == .spotify && issue.kind == .notRefreshed && issue.shown == spCount)
        #expect(saved(cache, .spotify)?.items.count == spCount)

        // Same for a refresh whose first page loads and a later one fails.
        sp.libraryFailure = nil
        sp.libraryPageFailures["songs:50"] = (offline, 2)
        let third = loader([yt, sp], cache: cache)
        await third.load()
        #expect(third.issues.first?.kind == .notRefreshed)
        #expect(third.items?.count == ytCount + spCount)
        #expect(saved(cache, .spotify)?.items.count == spCount)
    }

    @Test func likedSongsPlaysTheSavedListsOnlyWhenEveryServiceSavedOne() async throws {
        let (yt, sp, _, _) = try await services()
        let cache = PageCache()
        #expect(LibraryLoader.savedList("likedSongs", providers: [yt, sp], cache: cache) == nil)
        sp.libraryFailure = offline
        let loader = loader([yt, sp], cache: cache, kind: .likedSongs)
        await loader.load()
        // Only YouTube's is saved: not the whole list.
        #expect(LibraryLoader.savedList("likedSongs", providers: [yt, sp], cache: cache) == nil)
        sp.libraryFailure = nil
        loader.retry(.spotify)
        await settle(loader)
        #expect(LibraryLoader.savedList("likedSongs", providers: [yt, sp], cache: cache)?.count == loader.items?.count)
    }
}

/// Account buttons go where they say: "Open Accounts…" to Settings › Accounts, a named service's button to that
/// service's own sign-in sheet, never the welcome sheet.
@MainActor
@Suite struct AccountActionTests {
    @Test func openAccountsOpensSettingsOnAccounts() {
        let model = AppModel(environment: ["OPENMUSIC_MOCK": "1"])
        var opened = 0
        model.openSettingsAction = { opened += 1 }
        model.perform(.openAccounts)
        #expect(opened == 1)
        #expect(model.takeSettingsRequest() == .accounts)
        #expect(!model.showOnboarding)
        #expect(model.signInRequest == nil)
    }

    @Test func aServiceButtonOpensThatServicesSignIn() {
        let model = AppModel(environment: ["OPENMUSIC_MOCK": "1"])
        model.perform(.signIn(.spotify))
        #expect(model.signInRequest == .spotify)
        #expect(!model.showOnboarding)
        #expect(model.settingsRequest == nil)
    }

    @Test func emptyLibraryAndFailureRowsPickTheirDestination() async {
        let model = AppModel(environment: ["OPENMUSIC_MOCK": "1"])
        let stored = UserDefaults.standard.string(forKey: "serviceFilter")
        defer { UserDefaults.standard.set(stored, forKey: "serviceFilter") }
        let mocks = model.providers.compactMap { $0 as? MockProvider }
        let sp = mocks.first { $0.id == .spotify }!
        let yt = mocks.first { $0.id == .youtubeMusic }!
        await sp.signOut()
        // Showing a service that isn't signed in: its own sign-in.
        model.serviceFilter = .spotify
        #expect(AccountAction.forEmptyLibrary(model) == .signIn(.spotify))
        #expect(AccountAction.forService(.spotify, in: model) == .signIn(.spotify))
        #expect(AccountAction.forService(.youtubeMusic, in: model) == nil)
        // Another service signed in: Settings › Accounts.
        model.serviceFilter = .all
        #expect(AccountAction.forEmptyLibrary(model) == .openAccounts)
        // Signed out of everything: the menu of both services' sign-ins.
        await yt.signOut()
        #expect(AccountAction.forEmptyLibrary(model) == nil)
    }
}
