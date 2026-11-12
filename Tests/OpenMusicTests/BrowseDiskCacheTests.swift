import Foundation
import OpenMusicCore
import Testing
@testable import OpenMusic

@MainActor
@Suite struct BrowseDiskCacheTests {
    private func makeCache() -> (BrowseDiskCache, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("browse-test-\(UUID().uuidString)/browse", isDirectory: true)
        return (BrowseDiskCache(directory: dir), dir)
    }

    private func shelves(_ title: String, provider: ProviderID = .spotify) -> [ProviderResult<[Shelf]>] {
        let track = Track(providerID: "t-\(title)", provider: provider, title: title, artists: [ArtistRef(name: "A")], duration: 200)
        return [ProviderResult(provider: provider, value: [Shelf(id: "s-\(title)", title: title, style: .trackList, items: [.track(track)])], error: nil)]
    }

    private func files(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private let alexA = AccountInfo(name: "Alex", detail: "Premium", id: "alex-1")
    private let alexB = AccountInfo(name: "Alex", detail: "Premium", id: "alex-2")
    private func tag(_ provider: ProviderID, _ id: String) -> String { BrowseDiskCache.accountTag(provider, id: id) }

    @Test func twoAccountsWithTheSameNameAndPlanGetSeparateEntries() async {
        let (cache, _) = makeCache()
        let a = BrowseDiskCache.Key(page: "home", accounts: [tag(.spotify, "alex-1")])
        let b = BrowseDiskCache.Key(page: "home", accounts: [tag(.spotify, "alex-2")])
        #expect(a.fileName != b.fileName)
        cache.save(shelves("A's mix"), key: a)
        #expect(await cache.load(b) == nil)
        #expect(await cache.load(a)?.value.first?.value?.first?.title == "A's mix")
        // The same account (same id) keeps its tag across launches.
        #expect(BrowseDiskCache.accountTag(.spotify, alexA) == BrowseDiskCache.accountTag(.spotify, AccountInfo(name: "Alex", detail: "Premium", id: "alex-1")))
    }

    @Test func filesAreOwnerOnly() throws {
        let (cache, dir) = makeCache()
        cache.save(shelves("x"), key: BrowseDiskCache.Key(page: "home", accounts: ["aaaa"]))
        cache.flush()
        let names = files(dir)
        #expect(names.count == 1)
        let file = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(names[0]).path)
        let folder = try FileManager.default.attributesOfItem(atPath: dir.path)
        #expect((file[.posixPermissions] as? Int) == 0o600)
        #expect((folder[.posixPermissions] as? Int) == 0o700)
    }

    @Test func signingOutDeletesThatAccountsFilesOnly() async {
        let (cache, dir) = makeCache()
        let spotify = tag(.spotify, "alex-1")
        let ytm = tag(.youtubeMusic, "datasync:alex||1")
        let both = BrowseDiskCache.Key(page: "home both", accounts: [spotify, ytm])
        let ytmOnly = BrowseDiskCache.Key(page: "home ytm", accounts: [ytm])
        let signedOut = BrowseDiskCache.Key(page: "explore", accounts: [])
        cache.save(shelves("both"), key: both)
        cache.save(shelves("ytm", provider: .youtubeMusic), key: ytmOnly)
        cache.save(shelves("public", provider: .youtubeMusic), key: signedOut)
        cache.flush()
        // A file an older build wrote, keyed by account names.
        try? Data("[]".utf8).write(to: dir.appendingPathComponent("0123456789abcdef01234567.json"))
        cache.prune(keeping: [ytm])
        cache.flush()
        #expect(files(dir) == [ytmOnly.fileName, signedOut.fileName].sorted())
        #expect(await cache.load(both) == nil)
    }

    @Test func aSavePendingAtSignOutNeverRecreatesTheFile() async {
        let (cache, dir) = makeCache()
        let key = BrowseDiskCache.Key(page: "home", accounts: [tag(.spotify, "alex-1")])
        cache.prune(keeping: [tag(.spotify, "alex-1")])
        // Queued before the sign-out's purge: written, then purged.
        cache.save(shelves("before"), key: key)
        cache.prune(keeping: [])
        // A load that finished after the sign-out: refused.
        cache.save(shelves("after"), key: key)
        cache.flush()
        #expect(files(dir).isEmpty)
        #expect(await cache.load(key) == nil)
    }

    @Test func signingOutInTheAppPurgesThatAccountsFiles() async throws {
        let (cache, dir) = makeCache()
        let model = AppModel(environment: ["OPENMUSIC_MOCK": "1"])
        let spotify = try #require(model.provider(.spotify) as? MockProvider)
        spotify.sessionOverride = ProviderSession(generation: 1, identity: .account(id: "alex-1"))
        let mine = try BrowseDiskCache.Key(page: "home", accounts: #require(BrowseDiskCache.diskAccounts(BrowsePage.sessions([spotify]))))
        #expect(mine.accounts == [tag(.spotify, "alex-1")])
        cache.save(shelves("mine"), key: mine)
        BrowseDiskCache.watchAccounts(model, cache: cache)
        cache.flush()
        #expect(files(dir) == [mine.fileName])
        await spotify.signOut()
        spotify.sessionOverride = ProviderSession(generation: 2, identity: .signedOut)
        for _ in 0..<100 where !files(dir).isEmpty {
            try await Task.sleep(for: .milliseconds(10))
            cache.flush()
        }
        #expect(files(dir).isEmpty)
        // And the page can't bring it back.
        cache.save(shelves("late"), key: mine)
        cache.flush()
        #expect(files(dir).isEmpty)
    }

    @Test func clearCacheRemovesEverything() {
        let (cache, dir) = makeCache()
        cache.save(shelves("x"), key: BrowseDiskCache.Key(page: "home", accounts: []))
        cache.removeAll()
        cache.flush()
        #expect(files(dir).isEmpty)
    }

    @Test func aFailedRefreshKeepsTheShelvesAlreadyShown() {
        let shown = shelves("Saved mix") + shelves("YT saved", provider: .youtubeMusic)
        let fresh: [ProviderResult<[Shelf]>] = [
            ProviderResult(provider: .spotify, value: nil, error: "The Internet connection appears to be offline."),
            ProviderResult(provider: .youtubeMusic, value: shelves("YT fresh", provider: .youtubeMusic)[0].value, error: nil),
        ]
        let merged = BrowsePage.keepingShown(fresh, shown: shown)
        #expect(merged[0].value?.first?.title == "Saved mix")
        #expect(merged[0].error == "The Internet connection appears to be offline.")
        #expect(merged[1].value?.first?.title == "YT fresh")
        #expect(merged[1].error == nil)
        // Nothing shown yet: the error stands alone.
        #expect(BrowsePage.keepingShown(fresh, shown: nil)[0].value == nil)
    }

    // MARK: Account transitions (which account a page's shelves belong to)

    @Test func aPendingSignInKeepsTheShelvesUnderTheAccountStillInUse() throws {
        // YouTube signed in as A; a sign-in to B starts. `authStatus` drops to `.signingIn`, but requests still carry
        // A's cookies, so the page must stay keyed (and saved) as A, never as signed out.
        let youtube = MockProvider(id: .youtubeMusic)
        youtube.sessionOverride = ProviderSession(generation: 3, identity: .account(id: "datasync:a||1"))
        youtube.beginSignIn()
        #expect(youtube.authStatus == .signingIn)
        let accounts = try #require(BrowseDiskCache.diskAccounts(BrowsePage.sessions([youtube])))
        #expect(accounts == [tag(.youtubeMusic, "datasync:a||1")])
        #expect(accounts != BrowseDiskCache.diskAccounts([.youtubeMusic: ProviderSession(generation: 0, identity: .signedOut)]))
    }

    @Test func nothingGoesOnDiskWithoutAnImmutableAccountID() {
        // An account without an id (Spotify offline with no saved account; YouTube cookies without a datasync id)
        // can't be told apart from the next one, and a session mid-swap could answer as either side.
        #expect(BrowseDiskCache.diskAccounts([.spotify: ProviderSession(generation: 1, identity: .account(id: nil))]) == nil)
        #expect(BrowseDiskCache.diskAccounts([.youtubeMusic: ProviderSession(generation: 1, identity: .changing)]) == nil)
        #expect(BrowseDiskCache.diskAccounts([.youtubeMusic: ProviderSession(generation: 1, identity: .signedOut)]) == [])
        #expect(BrowseDiskCache.accountTag(.spotify, AccountInfo(name: "Alex", detail: "Premium")) == nil)
    }

    @Test func aRequestOverlappingASignInLandingIsDiscarded() async throws {
        let youtube = MockProvider(id: .youtubeMusic)
        youtube.sessionOverride = ProviderSession(generation: 3, identity: .account(id: "datasync:a||1"))
        youtube.latency = .milliseconds(300)
        let sessions = BrowsePage.sessions([youtube])
        let request = Task { try await BrowsePage.fetch([youtube], kind: .home, sessions: sessions, shown: nil) }
        try await Task.sleep(for: .milliseconds(50))
        // The new account's cookies land while Home is still being fetched with the old ones.
        youtube.sessionOverride = ProviderSession(generation: 4, identity: .changing)
        await #expect(throws: CancellationError.self) { try await request.value }
        // A request that starts while the swap is landing isn't even sent.
        await #expect(throws: CancellationError.self) {
            try await BrowsePage.fetch([youtube], kind: .home, sessions: BrowsePage.sessions([youtube]), shown: nil)
        }
        // Once settled, the page is keyed by the new session and loads.
        youtube.sessionOverride = ProviderSession(generation: 5, identity: .account(id: "datasync:b||1"))
        youtube.latency = .zero
        let fresh = try await BrowsePage.fetch([youtube], kind: .home, sessions: BrowsePage.sessions([youtube]), shown: nil)
        #expect(fresh.first?.value?.isEmpty == false)
    }

    @Test func onePendingSignInDoesntStopAnotherServicesPurge() async throws {
        let (cache, dir) = makeCache()
        let model = AppModel(environment: ["OPENMUSIC_MOCK": "1"])
        let spotify = try #require(model.provider(.spotify) as? MockProvider)
        let youtube = try #require(model.provider(.youtubeMusic) as? MockProvider)
        spotify.sessionOverride = ProviderSession(generation: 1, identity: .account(id: "alex-1"))
        youtube.sessionOverride = ProviderSession(generation: 1, identity: .account(id: "datasync:a||1"))
        let spotifyFile = BrowseDiskCache.Key(page: "home spotify", accounts: [tag(.spotify, "alex-1")])
        let youtubeFile = BrowseDiskCache.Key(page: "home youtube", accounts: [tag(.youtubeMusic, "datasync:a||1")])
        cache.save(shelves("sp"), key: spotifyFile)
        cache.save(shelves("yt", provider: .youtubeMusic), key: youtubeFile)
        BrowseDiskCache.watchAccounts(model, cache: cache)
        cache.flush()
        #expect(files(dir) == [spotifyFile.fileName, youtubeFile.fileName].sorted())

        // YouTube starts replacing its account, and its new cookies are landing (`.changing`)...
        youtube.beginSignIn()
        youtube.sessionOverride = ProviderSession(generation: 2, identity: .changing)
        // ...while Spotify signs out. Spotify's files go at once; YouTube keeps exactly its previous account's.
        await spotify.signOut()
        spotify.sessionOverride = ProviderSession(generation: 2, identity: .signedOut)
        for _ in 0..<100 where files(dir).count > 1 {
            try await Task.sleep(for: .milliseconds(10))
            cache.flush()
        }
        #expect(files(dir) == [youtubeFile.fileName])

        // The new YouTube account settles: the previous account's files go too.
        youtube.sessionOverride = ProviderSession(generation: 3, identity: .account(id: "datasync:b||1"))
        for _ in 0..<100 where !files(dir).isEmpty {
            try await Task.sleep(for: .milliseconds(10))
            cache.flush()
        }
        #expect(files(dir).isEmpty)
    }

    @Test func tryAgainKeepsTheShelvesOnScreen() async throws {
        // Home shows saved shelves with a "didn't refresh" row; "Try Again" empties the page cache to force the
        // refresh, and the refresh fails again. The shelves on screen must stay.
        let model = AppModel(environment: ["OPENMUSIC_MOCK": "1"])
        let spotify = try #require(model.provider(.spotify) as? MockProvider)
        spotify.browseFailure = .network("The Internet connection appears to be offline.")
        let key = "home:spotify#0"
        let onScreen = shelves("Saved mix")
        model.cache.set(onScreen, for: key)
        let shown = ShownResults()
        shown.remember(onScreen, for: key)
        model.cache.invalidate(prefix: "home")  // what "Try Again" does
        #expect((model.cache.value(for: key) as (value: [ProviderResult<[Shelf]>], date: Date)?) == nil)
        let displayed = BrowsePage.displayed(for: key, shown: shown, cache: model.cache)
        let refreshed = try await BrowsePage.fetch([spotify], kind: .home, sessions: BrowsePage.sessions([spotify]), shown: displayed)
        #expect(refreshed.first?.value?.first?.title == "Saved mix")
        #expect(refreshed.first?.error == ProviderError.network("The Internet connection appears to be offline.").localizedDescription)
        // Another page's key never borrows these shelves.
        #expect(shown.results(for: "explore:spotify#0") == nil)
    }
}
