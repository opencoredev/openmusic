import Foundation
import OpenMusicCore
import Testing
@testable import SpotifyKit

// Regression tests for work that outlives the session, sign-in, or play request it was started for.

/// A one-shot latch: `wait()` suspends until `open()`. Ignores task cancellation on purpose, so a "slow request"
/// can finish after its caller gave up, like a real network reply that was already on its way.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock {
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiting = lock.withLock {
            isOpen = true
            defer { waiters.removeAll() }
            return waiters
        }
        waiting.forEach { $0.resume() }
    }
}

/// `FakeTransport`, but requests to `heldPath` (from the `from`-th one on) wait for `release` after signalling `reached`.
final class HeldTransport: SpotifyTransport, @unchecked Sendable {
    let inner: FakeTransport
    let heldPath: String
    let holdFrom: Int
    let reached = Gate()
    let release = Gate()
    private let lock = NSLock()
    private var seen = 0

    init(holding path: String, from: Int = 0, _ handler: @escaping @Sendable (URLRequest, Int) -> FakeTransport.Reply) {
        inner = FakeTransport(handler)
        heldPath = path
        holdFrom = from
    }

    var requests: [URLRequest] { inner.requests }
    func requests(path: String) -> [URLRequest] { inner.requests(path: path) }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.path == heldPath, lock.withLock({ defer { seen += 1 }; return seen >= holdFrom }) {
            reached.open()
            await release.wait()
        }
        return try await inner.send(request)
    }
}

private struct Who: Decodable, Sendable { var id: String }

private func token(_ name: String, expiresIn: TimeInterval = 3600) -> SpotifyToken {
    SpotifyToken(accessToken: "access-\(name)", refreshToken: "refresh-\(name)", expiresAt: Date().addingTimeInterval(expiresIn), scope: nil)
}

/// Answers `/v1/me` with the account the bearer token belongs to.
@Sendable private func accountRoutes(_ request: URLRequest, _ n: Int) -> FakeTransport.Reply {
    if request.url?.host == "accounts.spotify.com" {
        // A refresh for account A.
        return .raw(#"{"access_token":"access-A2","token_type":"Bearer","expires_in":3600,"refresh_token":"refresh-A2"}"#)
    }
    let bearer = request.value(forHTTPHeaderField: "Authorization") ?? ""
    let who = bearer.hasSuffix("-B") ? "B" : "A"
    return .raw(#"{"id":"user-\#(who)","display_name":"\#(who)","type":"user","uri":"spotify:user:user-\#(who)"}"#)
}

@Suite struct SessionFencingTests {
    @Test func slowResponseFromOldAccountIsNotReturnedOrCached() async throws {
        let transport = HeldTransport(holding: "/v1/me", accountRoutes)
        let api = SpotifyAPI(transport: transport, tokenStore: MemoryTokenStore(token("A")), clientID: { "c" })
        let slow = Task { try await api.get("me", ttl: 300, as: Who.self) }
        await transport.reached.wait()
        try await api.setToken(token("B"))
        transport.release.open()

        await #expect(throws: CancellationError.self) { try await slow.value }
        // B's own request goes to Spotify (nothing of A's was cached under the same URL) and gets B.
        let fresh = try await api.get("me", ttl: 300, as: Who.self)
        #expect(fresh.id == "user-B")
        #expect(transport.requests(path: "/v1/me").count == 2)
    }

    @Test func staleMeDoesNotSetTheNewAccountsUserID() async throws {
        let transport = HeldTransport(holding: "/v1/me", accountRoutes)
        let api = SpotifyAPI(transport: transport, tokenStore: MemoryTokenStore(token("A")), clientID: { "c" })
        let service = SpotifyService(api: api)
        let slow = Task { try await service.me() }
        await transport.reached.wait()
        try await api.setToken(token("B"))
        transport.release.open()
        await #expect(throws: CancellationError.self) { try await slow.value }
        #expect(await api.userID == nil)
    }

    @Test func refreshThatLandsAfterAccountSwitchIsDropped() async throws {
        let store = MemoryTokenStore(token("A", expiresIn: 30)) // needs a refresh before the next request
        let transport = HeldTransport(holding: "/api/token", accountRoutes)
        let api = SpotifyAPI(transport: transport, tokenStore: store, clientID: { "c" })
        let slow = Task { try await api.get("me", as: Who.self) }
        await transport.reached.wait()
        // Switch accounts while A's refresh is on the wire; the reply still arrives with A's new token.
        try await api.setToken(token("B"))
        transport.release.open()

        await #expect(throws: CancellationError.self) { try await slow.value }
        #expect(store.load()?.accessToken == "access-B")
        #expect(try await api.accessToken() == "access-B")
        #expect(try await api.get("me", as: Who.self).id == "user-B")
        // A's request never went out with either token.
        #expect(transport.requests(path: "/v1/me").map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer access-B"])
    }

    @Test func revokedRefreshAfterAccountSwitchKeepsTheNewSession() async throws {
        let store = MemoryTokenStore(token("A", expiresIn: 30))
        let transport = HeldTransport(holding: "/api/token") { request, _ in
            request.url?.host == "accounts.spotify.com" ? .json("auth-error-invalid-grant", status: 400) : accountRoutes(request, 0)
        }
        let api = SpotifyAPI(transport: transport, tokenStore: store, clientID: { "c" })
        let slow = Task { try await api.accessToken() }
        await transport.reached.wait()
        try await api.setToken(token("B"))
        transport.release.open()
        await #expect(throws: CancellationError.self) { try await slow.value }
        #expect(store.load()?.accessToken == "access-B")
        #expect(await api.hasToken)
    }
}

/// Sign-in that the listener cancels part-way must not save credentials or sign in afterwards.
@MainActor
@Suite struct SignInCancellationTests {
    final class AccountLog: @unchecked Sendable {
        var saved: [AccountInfo?] = []
    }

    func provider(_ transport: any SpotifyTransport, store: MemoryTokenStore, log: AccountLog) -> SpotifyProvider {
        let defaults = UserDefaults(suiteName: "openmusic.tests.\(UUID().uuidString)")!
        let provider = SpotifyProvider(defaults: defaults, transport: transport, tokenStore: store)
        provider.saveAccount = { log.saved.append($0) }
        // The "browser": approve straight away, echoing the state OpenMusic sent.
        provider.authorize = { _, makeURL in
            let redirectURI = "http://127.0.0.1:8898/login"
            let url = makeURL(redirectURI)
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            return SpotifyAuthorization(callback: URL(string: "\(redirectURI)?code=the-code&state=\(state)")!, redirectURI: redirectURI)
        }
        return provider
    }

    @Sendable nonisolated static func routes(_ request: URLRequest, _ n: Int) -> FakeTransport.Reply {
        request.url?.host == "accounts.spotify.com" ? .json("token") : fixtureRoutes(request, n)
    }

    @Test func signsInWhenNotCancelled() async throws {
        let store = MemoryTokenStore()
        let log = AccountLog()
        let transport = FakeTransport(Self.routes)
        let p = provider(transport, store: store, log: log)
        await p.signIn()
        #expect(p.authStatus.isSignedIn)
        #expect(store.load()?.accessToken == "BQD-access-token-1")
        #expect(await p.service.api.userID == "ada.listener")
        #expect(log.saved.count == 1)
    }

    @Test func cancelDuringTokenExchangeSavesNothing() async throws {
        let store = MemoryTokenStore()
        let log = AccountLog()
        let transport = HeldTransport(holding: "/api/token", Self.routes)
        let p = provider(transport, store: store, log: log)
        let signIn = Task { await p.signIn() }
        await transport.reached.wait()
        #expect(p.authStatus == .signingIn)
        p.cancelSignIn()
        #expect(p.authStatus == .signedOut)
        transport.release.open()
        await signIn.value

        #expect(p.authStatus == .signedOut)
        #expect(store.load() == nil)
        #expect(await p.service.api.hasToken == false)
        #expect(log.saved.isEmpty)
        #expect(transport.requests(path: "/v1/me").isEmpty)
    }

    @Test func cancelDuringAccountCheckSavesNothing() async throws {
        let store = MemoryTokenStore()
        let log = AccountLog()
        let transport = HeldTransport(holding: "/v1/me", Self.routes)
        let p = provider(transport, store: store, log: log)
        let signIn = Task { await p.signIn() }
        await transport.reached.wait()
        p.cancelSignIn()
        transport.release.open()
        await signIn.value

        #expect(p.authStatus == .signedOut)
        #expect(store.load() == nil)
        #expect(await p.service.api.hasToken == false)
        #expect(log.saved.isEmpty)
    }

    @Test func cancellingTheCallerCancelsTheSignIn() async throws {
        let store = MemoryTokenStore()
        let log = AccountLog()
        let transport = HeldTransport(holding: "/api/token", Self.routes)
        let p = provider(transport, store: store, log: log)
        let signIn = Task { await p.signIn() }
        await transport.reached.wait()
        signIn.cancel()
        transport.release.open()
        await signIn.value

        #expect(p.authStatus == .signedOut)
        #expect(store.load() == nil)
        #expect(log.saved.isEmpty)
    }

    @Test func cancelWhileTheBrowserIsOpenReturnsPromptly() async throws {
        let store = MemoryTokenStore()
        let log = AccountLog()
        let p = provider(FakeTransport(Self.routes), store: store, log: log)
        let opened = Gate()
        p.authorize = { _, _ in
            opened.open()
            try await Task.sleep(for: .seconds(600)) // the listener never finishes in the browser
            throw SpotifyAuthError.cancelled
        }
        let signIn = Task { await p.signIn() }
        await opened.wait()
        p.cancelSignIn()
        await signIn.value // returns because the browser wait was cancelled, not after 600 s
        #expect(p.authStatus == .signedOut)
        #expect(store.load() == nil)
    }

    @Test func cancelKeepsAnExistingSession() async throws {
        let store = MemoryTokenStore()
        let log = AccountLog()
        // The first sign-in goes straight through; the second one's token exchange is held.
        let transport = HeldTransport(holding: "/api/token", from: 1, Self.routes)
        let p = provider(transport, store: store, log: log)
        await p.signIn()
        let before = p.authStatus
        #expect(before.isSignedIn)

        let signIn = Task { await p.signIn() }
        await transport.reached.wait()
        p.cancelSignIn()
        #expect(p.authStatus == before)
        transport.release.open()
        await signIn.value
        #expect(p.authStatus == before)
        #expect(store.load()?.accessToken == "BQD-access-token-1")
        #expect(log.saved.count == 1)
    }
}

/// A Spotify route that records what it was told and can hold `start` until released.
final class FakeRoute: SpotifyPlaybackRoute, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [String] = []
    let holdStart: Bool
    let startReached = Gate()
    let releaseStart = Gate()

    init(holdStart: Bool) { self.holdStart = holdStart }

    var commands: [String] { lock.withLock { _commands } }
    /// Commands other than volume changes.
    var transport: [String] { commands.filter { !$0.hasPrefix("volume") } }
    private func record(_ command: String) { lock.withLock { _commands.append(command) } }

    var pollInterval: TimeInterval { 5 }

    func start(uri: String, at seconds: TimeInterval) async throws {
        record("start \(uri)")
        if holdStart {
            startReached.open()
            await releaseStart.wait()
        }
    }

    func resume() async throws { record("resume") }
    func pause() async throws { record("pause") }
    func seek(to seconds: TimeInterval) async throws { record("seek \(Int(seconds))") }
    func setVolume(_ percent: Int) async throws { record("volume \(percent)") }
    func sample() async throws -> RemoteSample {
        RemoteSample(state: .paused, trackURI: nil, position: 0, duration: nil, timestamp: ProcessInfo.processInfo.systemUptime)
    }
}

/// Pause and Stop pressed while Spotify is still starting must win.
@MainActor
@Suite struct PlaybackIntentTests {
    let track = Track(providerID: "abc", provider: .spotify, title: "T", duration: 200)

    func engine(_ route: FakeRoute) -> (SpotifyPlaybackEngine, EventLog) {
        let defaults = UserDefaults(suiteName: "openmusic.tests.\(UUID().uuidString)")!
        let api = SpotifyAPI(transport: FakeTransport(fixtureRoutes), tokenStore: MemoryTokenStore(validToken()), clientID: { "c" })
        let engine = SpotifyPlaybackEngine(service: SpotifyService(api: api), defaults: defaults,
                                           isSignedIn: { true }, appInstalled: { false }, makeRoute: { _ in route })
        let log = EventLog()
        engine.onEvent = { log.record($0) }
        return (engine, log)
    }

    @MainActor final class EventLog {
        var states: [String] = []
        func record(_ event: PlaybackEvent) {
            if case .state(let s) = event { states.append(s.rawValue) }
        }
    }

    @Test func pauseDuringAutoplayStartWins() async throws {
        let route = FakeRoute(holdStart: true)
        let (engine, log) = engine(route)
        let load = Task { try await engine.load(track, startAt: 0, autoplay: true) }
        await route.startReached.wait()
        engine.pause()
        route.releaseStart.open()
        try await load.value
        await engine.waitForCommands()

        // Spotify had already been told to play, so it's paused again; OpenMusic never reports playing.
        #expect(route.transport == ["start spotify:track:abc", "pause"])
        #expect(!log.states.contains("playing"))
        #expect(log.states.last == "paused")
    }

    @Test func stopDuringAutoplayStartPausesSpotify() async throws {
        // What a switch to YouTube Music does: the controller stops the Spotify engine.
        let route = FakeRoute(holdStart: true)
        let (engine, log) = engine(route)
        let load = Task { try await engine.load(track, startAt: 0, autoplay: true) }
        await route.startReached.wait()
        engine.stop()
        route.releaseStart.open()
        try await load.value
        await engine.waitForCommands()

        #expect(route.transport == ["start spotify:track:abc", "pause"])
        #expect(!log.states.contains("playing"))
        #expect(log.states.last == "idle")
        #expect(engine.activeRoute == nil)
    }

    @Test func pauseDuringPlayStartWins() async throws {
        let route = FakeRoute(holdStart: true)
        let (engine, log) = engine(route)
        try await engine.load(track, startAt: 30, autoplay: false)
        engine.play()
        await route.startReached.wait()
        engine.pause()
        route.releaseStart.open()
        await engine.waitForCommands()
        try await Task.sleep(for: .milliseconds(50)) // let the play task's continuation run

        #expect(route.transport == ["start spotify:track:abc", "pause"])
        #expect(!log.states.contains("playing"))
        #expect(log.states.last == "paused")
        #expect(engine.currentTime == 30)
    }

    @Test func pausePlayDuringStartEndsPlaying() async throws {
        let route = FakeRoute(holdStart: true)
        let (engine, log) = engine(route)
        let load = Task { try await engine.load(track, startAt: 0, autoplay: true) }
        await route.startReached.wait()
        engine.pause()
        engine.play()
        route.releaseStart.open()
        try await load.value
        await engine.waitForCommands()
        try await Task.sleep(for: .milliseconds(50))

        // Commands reach Spotify in the order pressed, and the last word (play) wins.
        #expect(route.transport == ["start spotify:track:abc", "pause", "start spotify:track:abc"])
        #expect(log.states.last == "playing")
        engine.stop()
    }

    @Test func unheldAutoplayStillPlays() async throws {
        let route = FakeRoute(holdStart: false)
        let (engine, log) = engine(route)
        try await engine.load(track, startAt: 0, autoplay: true)
        #expect(route.transport == ["start spotify:track:abc"])
        #expect(log.states == ["loading", "playing"])
        engine.pause()
        await engine.waitForCommands()
        #expect(route.transport == ["start spotify:track:abc", "pause"])
        engine.stop()
    }

    @Test func newTrackWhileStartingPlaysOnlyTheNewOne() async throws {
        let route = FakeRoute(holdStart: true)
        let (engine, log) = engine(route)
        let first = Task { try await engine.load(track, startAt: 0, autoplay: true) }
        await route.startReached.wait()
        let other = Track(providerID: "xyz", provider: .spotify, title: "U", duration: 180)
        let second = Task { try await engine.load(other, startAt: 0, autoplay: true) }
        try await Task.sleep(for: .milliseconds(50)) // let the second load queue its start
        route.releaseStart.open()
        try await first.value
        try await second.value
        await engine.waitForCommands()

        #expect(route.transport == ["start spotify:track:abc", "pause", "start spotify:track:xyz"])
        #expect(log.states.last == "playing")
        engine.stop()
    }
}
