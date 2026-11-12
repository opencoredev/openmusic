import Foundation
import MedleyCore
import Testing
@testable import SpotifyKit

/// `SpotifySignInTransfer` with fake sessions: a fake transport, memory token stores, no Keychain writes.
@MainActor
@Suite struct SpotifySignInTransferTests {
    final class Counter { var count = 0 }

    /// Answers the token endpoint with `refresh` (a rotated pair by default) and the API from fixtures.
    static func transport(refresh: FakeTransport.Reply = .raw(#"{"access_token":"at-2","expires_in":3600,"refresh_token":"rt-2","scope":"s"}"#),
                          me: FakeTransport.Reply? = nil) -> FakeTransport {
        FakeTransport { request, n in
            if request.url?.host == "accounts.spotify.com" { return refresh }
            if request.url?.path == "/v1/me", let me { return me }
            return fixtureRoutes(request, n)
        }
    }

    func device(_ transport: FakeTransport = transport(), token: SpotifyToken? = nil) async -> (SpotifyProvider, SpotifySignInTransfer, MemoryTokenStore, Counter) {
        let store = MemoryTokenStore(token)
        let defaults = UserDefaults(suiteName: "medley.tests.\(UUID().uuidString)")!
        let provider = SpotifyProvider(defaults: defaults, transport: transport, tokenStore: store)
        provider.saveAccount = { _ in }
        provider.authorize = { target, makeURL in
            let redirectURI = "http://127.0.0.1:8898/login"
            let url = makeURL(redirectURI)
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            return SpotifyAuthorization(callback: URL(string: "\(redirectURI)?code=c&state=\(state)")!, redirectURI: redirectURI)
        }
        let transfer = SpotifySignInTransfer(provider: provider)
        let counter = Counter()
        transfer.signInDidChange = { counter.count += 1 }
        if token != nil { await provider.restoreSession() }
        await settle()
        return (provider, transfer, store, counter)
    }

    /// The API's refresh observer is installed and fires in tasks; let them run.
    func settle() async { for _ in 0..<5 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(30)) }

    static let fresh = SpotifyToken(accessToken: "at-1", refreshToken: "rt-1", expiresAt: Date().addingTimeInterval(3000), scope: "s",
                                    clientID: SpotifyBuiltInClient.clientID)
    static let expired = SpotifyToken(accessToken: "at-0", refreshToken: "rt-0", expiresAt: Date().addingTimeInterval(-60), scope: "s",
                                      clientID: SpotifyBuiltInClient.clientID)

    @Test func signedOutExportsNothing() async {
        let (_, transfer, _, _) = await device()
        #expect(await transfer.exportSignIn() == nil)
    }

    @Test func signInReportsAndExportsTheToken() async throws {
        let (provider, transfer, _, counter) = await device(Self.transport(refresh: .json("token")))
        await provider.signIn()
        #expect(provider.authStatus.isSignedIn)
        #expect(counter.count == 1)
        let payload = try SpotifySignInPayload.decode(try #require(await transfer.exportSignIn()))
        #expect(payload.token.refreshToken == "AQD-refresh-token-1")
        #expect(payload.token.clientID == SpotifyBuiltInClient.clientID)
        #expect(payload.userID == "ada.listener")
    }

    @Test func rotationReportsAndExportsTheNewRefreshToken() async throws {
        let (provider, transfer, store, counter) = await device(token: Self.fresh)
        #expect(provider.authStatus.isSignedIn)
        let start = counter.count
        // The access token runs out; the next request refreshes and Spotify rotates the refresh token.
        try await provider.service.api.setToken(Self.expired)
        _ = try await provider.service.me()
        await settle()
        #expect(store.load()?.refreshToken == "rt-2")
        #expect(counter.count == start + 1)
        let after = try SpotifySignInPayload.decode(try #require(await transfer.exportSignIn()))
        #expect(after.token.refreshToken == "rt-2")
    }

    @Test func importOfAFreshTokenDoesntRefreshAndEchoesNothing() async throws {
        let (_, transferA, _, _) = await device(token: Self.fresh)
        let data = try #require(await transferA.exportSignIn())

        let transportB = Self.transport()
        let (b, transferB, storeB, counterB) = await device(transportB)
        try await transferB.importSignIn(data)
        await settle()
        #expect(b.authStatus.accountName == "Ada Listener")
        #expect(storeB.load()?.refreshToken == "rt-1")
        #expect(transportB.requests(path: "/api/token").isEmpty)
        #expect(counterB.count == 1)
        #expect(await transferB.exportSignIn() == data)
    }

    @Test func importOfAnExpiredTokenKeepsTheRefreshedOne() async throws {
        let (_, transferA, _, _) = await device(Self.transport(refresh: .status(500)), token: Self.expired)
        let data = try #require(await transferA.exportSignIn())
        let (_, transferB, storeB, _) = await device()
        try await transferB.importSignIn(data)
        #expect(storeB.load()?.refreshToken == "rt-2")
        // The rotation goes back up: the export differs from what arrived.
        #expect(await transferB.exportSignIn() != data)
    }

    @Test func rejectedImportKeepsThisDevicesSession() async throws {
        let (_, transferA, _, _) = await device(token: Self.fresh)
        let data = try #require(await transferA.exportSignIn())
        let own = SpotifyToken(accessToken: "b-at", refreshToken: "b-rt", expiresAt: Date().addingTimeInterval(3000), scope: "s",
                               clientID: SpotifyBuiltInClient.clientID)
        // /me answers 401 and the refresh is refused: Spotify revoked the transferred token.
        let transportB = Self.transport(refresh: .json("auth-error-invalid-grant", status: 400), me: .status(401))
        let (b, transferB, storeB, _) = await device(transportB)
        try await b.service.api.setToken(own)
        await #expect(throws: SpotifySignInTransfer.TransferError.rejected) { try await transferB.importSignIn(data) }
        #expect(storeB.load() == own)
    }

    /// Offline (the transport throws): the import is retryable and this device's working token stays.
    @Test func networkFailureKeepsThisDevicesSession() async throws {
        let (_, transferA, _, _) = await device(token: Self.fresh)
        let data = try #require(await transferA.exportSignIn())
        let own = SpotifyToken(accessToken: "b-at", refreshToken: "b-rt", expiresAt: Date().addingTimeInterval(3000), scope: "s",
                               clientID: SpotifyBuiltInClient.clientID)
        let (b, transferB, storeB, counterB) = await device(token: own)
        #expect(b.authStatus.isSignedIn)
        let reports = counterB.count
        let offline = SpotifySignInTransfer(provider: b, verify: SpotifySignInTransfer.checkWithSpotify(transport: OfflineTransport()))
        await #expect(throws: SpotifySignInTransfer.TransferError.unverified) { try await offline.importSignIn(data) }
        #expect(storeB.load() == own)
        #expect(await b.service.api.currentToken == own)
        #expect(b.authStatus.isSignedIn)
        #expect(counterB.count == reports)
        _ = transferB
        // Spotify answering 503 isn't proof either.
        let flaky = SpotifySignInTransfer(provider: b, verify: { _ in throw ProviderError.server(503, "unavailable") })
        await #expect(throws: SpotifySignInTransfer.TransferError.unverified) { try await flaky.importSignIn(data) }
        #expect(storeB.load() == own)
    }

    /// Signed out and offline: a structurally valid token that was never checked doesn't sign this device in.
    @Test func networkFailureDoesNotSignInWithAnUncheckedToken() async throws {
        let (b, _, storeB, _) = await device()
        let transfer = SpotifySignInTransfer(provider: b, verify: SpotifySignInTransfer.checkWithSpotify(transport: OfflineTransport()))
        let garbage = try SpotifySignInPayload(token: SpotifyToken(accessToken: "x", refreshToken: "y", expiresAt: Date().addingTimeInterval(3000),
                                                                  scope: "s", clientID: SpotifyBuiltInClient.clientID), userID: "eve").encoded()
        await #expect(throws: SpotifySignInTransfer.TransferError.unverified) { try await transfer.importSignIn(garbage) }
        #expect(!b.authStatus.isSignedIn)
        #expect(storeB.load() == nil)
    }

    @Test func validImportIsCommitted() async throws {
        let (_, transferA, _, _) = await device(token: Self.fresh)
        let data = try #require(await transferA.exportSignIn())
        let own = SpotifyToken(accessToken: "b-at", refreshToken: "b-rt", expiresAt: Date().addingTimeInterval(3000), scope: "s",
                               clientID: SpotifyBuiltInClient.clientID)
        let (b, transferB, storeB, _) = await device(token: own)
        try await transferB.importSignIn(data)
        #expect(storeB.load()?.refreshToken == "rt-1")
        #expect(b.authStatus.accountName == "Ada Listener")
    }

    // MARK: Two devices refreshing the same token

    /// The token endpoint of a race: refreshing `rt-0` is refused (the other device already rotated it); `rt-A`, the
    /// other device's rotated token, refreshes to `rt-A2`.
    static func raceTransport() -> FakeTransport {
        FakeTransport { request, n in
            if request.url?.host == "accounts.spotify.com" {
                switch request.formFields["refresh_token"] {
                case "rt-A": return .raw(#"{"access_token":"at-A2","expires_in":3600,"refresh_token":"rt-A2","scope":"s"}"#)
                default: return .json("auth-error-invalid-grant", status: 400)
                }
            }
            return fixtureRoutes(request, n)
        }
    }

    static func otherDevicesToken(expiresIn: TimeInterval) -> SpotifyToken {
        SpotifyToken(accessToken: "at-A", refreshToken: "rt-A", expiresAt: Date().addingTimeInterval(expiresIn), scope: "s",
                     clientID: SpotifyBuiltInClient.clientID)
    }

    @Test func refusedRefreshContinuesWithTheTokenInTheVault() async throws {
        let transport = Self.raceTransport()
        let (provider, transfer, store, _) = await device(transport, token: Self.fresh)
        let vault = try SpotifySignInPayload(token: Self.otherDevicesToken(expiresIn: 3000), userID: "ada.listener").encoded()
        transfer.syncedSignIn = { vault }
        try await provider.service.api.setToken(Self.expired)
        let account = try await provider.service.me()
        await settle()
        #expect(account.name == "Ada Listener")
        #expect(provider.authStatus.isSignedIn)
        #expect(store.load()?.refreshToken == "rt-A")
        // The vault's token was still good: no second refresh.
        #expect(transport.requests(path: "/api/token").count == 1)
        #expect(transport.requests(path: "/api/token").first?.formFields["refresh_token"] == "rt-0")
    }

    @Test func refusedRefreshRefreshesAnExpiredVaultToken() async throws {
        let transport = Self.raceTransport()
        let (provider, transfer, store, _) = await device(transport, token: Self.fresh)
        let vault = try SpotifySignInPayload(token: Self.otherDevicesToken(expiresIn: -10), userID: "ada.listener").encoded()
        transfer.syncedSignIn = { vault }
        try await provider.service.api.setToken(Self.expired)
        _ = try await provider.service.me()
        await settle()
        #expect(provider.authStatus.isSignedIn)
        #expect(store.load()?.refreshToken == "rt-A2")
        let exported = try #require(await transfer.exportSignIn())
        #expect(try SpotifySignInPayload.decode(exported).token.refreshToken == "rt-A2")
    }

    @Test func refusedRefreshWaitsForTheOtherDevicesTokenToArrive() async throws {
        let transport = Self.raceTransport()
        let (provider, transfer, store, _) = await device(transport, token: Self.fresh)
        transfer.syncedSignIn = { nil }
        transfer.refreshRecoveryWait = .seconds(5)
        try await provider.service.api.setToken(Self.expired)
        let request = Task { try await provider.service.me() }
        // The vault update arrives while the refused refresh waits.
        try await Task.sleep(for: .milliseconds(150))
        let incoming = try SpotifySignInPayload(token: Self.otherDevicesToken(expiresIn: 3000), userID: "ada.listener").encoded()
        try await transfer.importSignIn(incoming)
        _ = try? await request.value
        await settle()
        #expect(provider.authStatus.isSignedIn)
        #expect(store.load()?.refreshToken == "rt-A")
        _ = try await provider.service.me()
    }

    @Test func refusedRefreshWithNoNewerTokenSignsOut() async throws {
        let transport = Self.raceTransport()
        let (provider, transfer, store, _) = await device(transport, token: Self.fresh)
        // The vault holds the same refused token: not newer.
        let same = try SpotifySignInPayload(token: Self.expired, userID: nil).encoded()
        transfer.syncedSignIn = { same }
        transfer.refreshRecoveryWait = .milliseconds(100)
        try await provider.service.api.setToken(Self.expired)
        await #expect(throws: ProviderError.notSignedIn) { try await provider.service.me() }
        await settle()
        #expect(!provider.authStatus.isSignedIn)
        #expect(store.load() == nil)
    }

    @Test func signOutReportsAndExportsNothing() async throws {
        let (provider, transfer, _, counter) = await device(token: Self.fresh)
        let start = counter.count
        try await transfer.signOut()
        #expect(!provider.authStatus.isSignedIn)
        #expect(counter.count == start + 1)
        #expect(await transfer.exportSignIn() == nil)
    }

    @Test func revokedRefreshSignsOutAndReports() async throws {
        let transport = Self.transport(refresh: .json("auth-error-invalid-grant", status: 400))
        let (provider, transfer, _, counter) = await device(transport, token: Self.fresh)
        transfer.refreshRecoveryWait = .milliseconds(50)
        #expect(provider.authStatus.isSignedIn)
        let start = counter.count
        try await provider.service.api.setToken(Self.expired)
        _ = try? await provider.service.me()
        await settle()
        #expect(!provider.authStatus.isSignedIn)
        #expect(counter.count == start + 1)
        #expect(await transfer.exportSignIn() == nil)
    }

    @Test func testPayloadAndRedaction() async throws {
        let (b, _, _, _) = await device()
        let transfer = SpotifySignInTransfer(provider: b, verify: SpotifySignInTransfer.acceptingTestSignIns(provider: b))
        try await transfer.importSignIn(SpotifySignInTransfer.testPayload())
        #expect(b.authStatus.isSignedIn)
        let payload = SpotifySignInPayload(token: Self.fresh, userID: "ada")
        #expect(!String(describing: payload).contains("rt-1"))
        #expect(!"\(SpotifySignInTransfer.TransferredToken(token: Self.fresh))".contains("at-1"))
    }
}

/// Every request fails as if the device were offline.
struct OfflineTransport: SpotifyTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw ProviderError.network("The Internet connection appears to be offline.")
    }
}

private extension AuthStatus {
    var accountName: String? { if case .signedIn(let info) = self { info.name } else { nil } }
}
