import Foundation
import OpenMusicCore
import Testing
@testable import SpotifyKit

/// Spotify as a refresh race leaves it, scripted: refreshes are refused except the rotations listed (each refresh token
/// works once); `/me` names the bearer's account (`at-B…` is user-B, else user-A) unless told to fail; writes succeed.
/// Records each request with whether it went uncached.
final class OwnerScript: SpotifyTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [(request: URLRequest, uncached: Bool)] = []
    private var rotations: [String: String] = [:]
    private var meError: ProviderError?
    private var meReply: FakeTransport.Reply?

    func rotate(_ refreshToken: String, to name: String) { lock.withLock { rotations[refreshToken] = name } }
    func failMe(_ error: ProviderError?) { lock.withLock { meError = error } }
    func answerMe(_ reply: FakeTransport.Reply?) { lock.withLock { meReply = reply } }

    var requests: [(request: URLRequest, uncached: Bool)] { lock.withLock { log } }
    var meRequests: [(request: URLRequest, uncached: Bool)] { requests.filter { $0.request.url?.path == "/v1/me" } }
    var writes: [URLRequest] { requests.map(\.request).filter { $0.httpMethod == "POST" && $0.url?.host == "api.spotify.com" } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { try await send(request, uncached: false) }

    func send(_ request: URLRequest, uncached: Bool) async throws -> (Data, HTTPURLResponse) {
        let reply: FakeTransport.Reply = try lock.withLock {
            log.append((request, uncached))
            if request.url?.host == "accounts.spotify.com" {
                let refresh = request.formFields["refresh_token"] ?? ""
                guard let name = rotations.removeValue(forKey: refresh) else { return .json("auth-error-invalid-grant", status: 400) }
                return .raw(#"{"access_token":"at-\#(name)","expires_in":3600,"refresh_token":"rt-\#(name)","scope":"s"}"#)
            }
            if request.url?.path == "/v1/me" {
                if let meError { throw meError }
                if let meReply { return meReply }
                let who = (request.value(forHTTPHeaderField: "Authorization") ?? "").hasPrefix("Bearer at-B") ? "B" : "A"
                return .raw(#"{"id":"user-\#(who)","display_name":"\#(who)","type":"user","uri":"spotify:user:user-\#(who)"}"#)
            }
            return .raw(#"{"snapshot_id":"s1"}"#, status: 201)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (reply.body, response)
    }
}

/// Sol's review of 138acd6: every owner check (`/me`) skips the HTTP cache and cookies, a check that fails for a
/// passing reason (timeout, offline, 429) keeps the sign-in and is retryable, and a token the check rotated is kept
/// for the next check without being installed.
@MainActor
@Suite struct OwnerCheckTests {
    private static func token(_ name: String, expiresIn: TimeInterval) -> SpotifyToken {
        SpotifyToken(accessToken: "at-\(name)", refreshToken: "rt-\(name)", expiresAt: Date().addingTimeInterval(expiresIn), scope: "s",
                     clientID: SpotifyBuiltInClient.clientID)
    }

    private let song = Track(providerID: "x", provider: .spotify, title: "X", extra: ["uri": "spotify:track:x"])

    private func device(_ script: OwnerScript, token: SpotifyToken, vault: SpotifyToken?) async throws
        -> (SpotifyProvider, SpotifySignInTransfer, MemoryTokenStore) {
        let store = MemoryTokenStore()
        let defaults = try #require(UserDefaults(suiteName: "openmusic.tests.\(UUID().uuidString)"))
        let provider = SpotifyProvider(defaults: defaults, transport: script, tokenStore: store)
        provider.saveAccount = { _ in }
        let transfer = SpotifySignInTransfer(provider: provider)
        transfer.refreshRecoveryWait = .milliseconds(50)
        for _ in 0..<5 { await Task.yield() }
        let payload = try vault.map { try SpotifySignInPayload(token: $0, userID: "user-A").encoded() }
        transfer.syncedSignIn = { payload }
        try await provider.adoptTransferredSignIn(token, account: AccountInfo(name: "A", id: "user-A"), userID: "user-A")
        for _ in 0..<5 { await Task.yield() }
        return (provider, transfer, store)
    }

    private func account(_ provider: SpotifyProvider) -> PlaylistWriteAccount {
        PlaylistWriteAccount(accountID: "user-A", session: provider.session)
    }

    // MARK: P1: owner checks skip the HTTP cache and cookies

    @Test func theIdentitySessionHasNoCacheAndNoCookies() {
        let config = HTTP.uncachedSession.configuration
        #expect(config.urlCache == nil)
        #expect(config.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(config.httpCookieStorage == nil)
        #expect(config.httpShouldSetCookies == false)
    }

    /// The recovery's check, the import's check and the API learning its user before a bound write: every `/me` goes
    /// uncached, ignoring every cache.
    @Test func everyOwnerCheckIsUncached() async throws {
        let script = OwnerScript()
        let (provider, transfer, _) = try await device(script, token: Self.token("A", expiresIn: -60), vault: Self.token("A2", expiresIn: 3000))
        try await provider.add([song], toPlaylist: "pl", as: account(provider))              // recovery's check
        try await transfer.importSignIn(try SpotifySignInPayload(token: Self.token("A3", expiresIn: 3000), userID: "user-A").encoded())
        let api = SpotifyAPI(transport: script, tokenStore: MemoryTokenStore(Self.token("A", expiresIn: 3000)), clientID: { "c" })
        try await SpotifyService(api: api).add(["spotify:track:x"], toPlaylist: "pl", as: SpotifyWriteBinding(userID: "user-A", epoch: 0))
        let checks = script.meRequests
        #expect(checks.count >= 3)
        #expect(checks.allSatisfy { $0.uncached && $0.request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData })
        withExtendedLifetime(transfer) {}
    }

    // MARK: P2: a passing failure keeps the sign-in

    /// The vault's token can't be checked right now (timeout, offline, 429): the write fails retryably, nothing is
    /// deleted, the session stays; once Spotify answers, Try Again recovers and writes.
    @Test(arguments: [
        ProviderError.network(URLError(.timedOut).localizedDescription),
        ProviderError.network(URLError(.notConnectedToInternet).localizedDescription),
        ProviderError.rateLimited,
    ])
    func aPassingCheckFailureKeepsTheSignIn(_ failure: ProviderError) async throws {
        let script = OwnerScript()
        let (provider, transfer, store) = try await device(script, token: Self.token("A", expiresIn: -60), vault: Self.token("A2", expiresIn: 3000))
        if failure == .rateLimited {
            script.answerMe(FakeTransport.Reply(status: 429, headers: ["Retry-After": "0"]))
        } else {
            script.failMe(failure)
        }
        var thrown: (any Error)?
        do { try await provider.add([song], toPlaylist: "pl", as: account(provider)) } catch { thrown = error }
        #expect(thrown != nil)
        #expect((thrown as? ProviderError) != .notSignedIn, "a passing failure, not a sign-out")
        #expect(script.writes.isEmpty)
        #expect(store.load()?.accessToken == "at-A", "the saved sign-in stays")
        #expect(provider.authStatus.isSignedIn)

        script.failMe(nil)
        script.answerMe(nil)
        try await provider.add([song], toPlaylist: "pl", as: account(provider))
        #expect(script.writes.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer at-A2"])
        withExtendedLifetime(transfer) {}
    }

    /// A definite answer naming another account still fails closed: signed out, nothing written.
    @Test func aDefiniteOtherAccountAnswerFailsClosed() async throws {
        let script = OwnerScript()
        let (provider, transfer, store) = try await device(script, token: Self.token("A", expiresIn: -60), vault: Self.token("B", expiresIn: 3000))
        await #expect(throws: ProviderError.notSignedIn) { try await provider.add([song], toPlaylist: "pl", as: account(provider)) }
        #expect(script.writes.isEmpty)
        #expect(store.load() == nil)
        withExtendedLifetime(transfer) {}
    }

    /// The vault's token had expired, so the check refreshed it (rotating it: the vault's refresh token is spent), then
    /// timed out. The rotated token isn't installed, and it isn't lost: the next check uses it, and once it passes the
    /// session continues with it.
    @Test func aTokenRotatedDuringACheckIsKeptForTheNextCheck() async throws {
        let script = OwnerScript()
        script.rotate("rt-A2", to: "A3")
        let (provider, transfer, store) = try await device(script, token: Self.token("A", expiresIn: -60), vault: Self.token("A2", expiresIn: -60))
        script.failMe(.network(URLError(.timedOut).localizedDescription))
        await #expect(throws: (any Error).self) { try await provider.add([song], toPlaylist: "pl", as: account(provider)) }
        #expect(store.load()?.accessToken == "at-A", "the rotated token isn't installed before its owner is checked")
        #expect(provider.authStatus.isSignedIn)

        script.failMe(nil)
        try await provider.add([song], toPlaylist: "pl", as: account(provider))
        #expect(script.writes.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer at-A3"])
        #expect(store.load()?.accessToken == "at-A3")
        withExtendedLifetime(transfer) {}
    }
}
