import Foundation
import MedleyCore
import Testing
@testable import SpotifyKit

/// Sol's review of b56ad76: a token recovered after a refused refresh (from the sync vault or an import) is installed
/// only when it belongs to the account the session already holds. Another account's token is never adopted under the
/// old owner, so a write bound to that owner can't go out with it.
@MainActor
@Suite struct RecoveryOwnerTests {
    private static func token(_ name: String, expiresIn: TimeInterval) -> SpotifyToken {
        SpotifyToken(accessToken: "at-\(name)", refreshToken: "rt-\(name)", expiresAt: Date().addingTimeInterval(expiresIn), scope: "s",
                     clientID: SpotifyBuiltInClient.clientID)
    }

    /// Spotify as the race leaves it: every refresh is refused (another device rotated the token); `/me` answers with
    /// the account the bearer belongs to (`at-A…` is user-A, `at-B…` user-B); `at-A-stale` gets a 401; writes succeed.
    private static func transport() -> FakeTransport {
        FakeTransport { request, _ in
            if request.url?.host == "accounts.spotify.com" { return .json("auth-error-invalid-grant", status: 400) }
            let bearer = request.value(forHTTPHeaderField: "Authorization") ?? ""
            if bearer == "Bearer at-A-stale" { return .raw(#"{"error":{"status":401,"message":"The access token expired"}}"#, status: 401) }
            if request.url?.path == "/v1/me" {
                let who = bearer.hasPrefix("Bearer at-B") ? "B" : "A"
                return .raw(#"{"id":"user-\#(who)","display_name":"\#(who)","type":"user","uri":"spotify:user:user-\#(who)"}"#)
            }
            return .raw(#"{"snapshot_id":"s1"}"#, status: 201)
        }
    }

    /// A provider signed in as user-A holding `token`, whose transfer finds `vault` in the sync library.
    private func device(_ transport: FakeTransport, token: SpotifyToken, vault: SpotifyToken?, vaultUser: String?) async throws
        -> (SpotifyProvider, SpotifySignInTransfer, MemoryTokenStore) {
        let store = MemoryTokenStore()
        let defaults = try #require(UserDefaults(suiteName: "medley.tests.\(UUID().uuidString)"))
        let provider = SpotifyProvider(defaults: defaults, transport: transport, tokenStore: store)
        provider.saveAccount = { _ in }
        let transfer = SpotifySignInTransfer(provider: provider)
        transfer.refreshRecoveryWait = .milliseconds(50)
        for _ in 0..<5 { await Task.yield() }
        let payload = try vault.map { try SpotifySignInPayload(token: $0, userID: vaultUser).encoded() }
        transfer.syncedSignIn = { payload }
        try await provider.adoptTransferredSignIn(token, account: AccountInfo(name: "A", id: "user-A"), userID: "user-A")
        for _ in 0..<5 { await Task.yield() }
        return (provider, transfer, store)
    }

    private func writes(_ transport: FakeTransport) -> [URLRequest] {
        transport.requests.filter { $0.httpMethod == "POST" && $0.url?.host == "api.spotify.com" }
    }

    private let song = Track(providerID: "x", provider: .spotify, title: "X", extra: ["uri": "spotify:track:x"])

    /// A's refresh is refused and the vault holds B's token (the payload even claims user-A). B's token isn't
    /// installed under A: the write bound to A sends nothing, and A's session ends (signed out) instead.
    @Test func anotherAccountsVaultTokenIsNeverInstalled() async throws {
        let transport = Self.transport()
        let (provider, transfer, store) = try await device(transport, token: Self.token("A", expiresIn: -60),
                                                    vault: Self.token("B", expiresIn: 3000), vaultUser: "user-A")
        let account = PlaylistWriteAccount(accountID: "user-A", session: provider.session)
        await #expect(throws: (any Error).self) { try await provider.add([song], toPlaylist: "pl", as: account) }
        #expect(writes(transport).isEmpty, "nothing written")
        #expect(!transport.requests.contains { $0.value(forHTTPHeaderField: "Authorization") == "Bearer at-B" && $0.url?.path != "/v1/me" })
        #expect(store.load()?.accessToken != "at-B", "B's token isn't saved as this session's")
        withExtendedLifetime(transfer) {}
    }

    /// The same after a 401: A's token is turned away, the refresh is refused, the vault holds B. Nothing goes out
    /// with B's token.
    @Test func anotherAccountsVaultTokenIsNeverInstalledAfterA401() async throws {
        let transport = Self.transport()
        let stale = SpotifyToken(accessToken: "at-A-stale", refreshToken: "rt-A", expiresAt: Date().addingTimeInterval(3000), scope: "s",
                                 clientID: SpotifyBuiltInClient.clientID)
        let (provider, transfer, store) = try await device(transport, token: stale, vault: Self.token("B", expiresIn: 3000), vaultUser: "user-A")
        let account = PlaylistWriteAccount(accountID: "user-A", session: provider.session)
        await #expect(throws: (any Error).self) { try await provider.add([song], toPlaylist: "pl", as: account) }
        let withB = writes(transport).filter { $0.value(forHTTPHeaderField: "Authorization") == "Bearer at-B" }
        #expect(withB.isEmpty, "no write with B's token")
        #expect(store.load()?.accessToken != "at-B")
        withExtendedLifetime(transfer) {}
    }

    /// The vault holds A's own rotated token: recovery still works and the write goes out with it.
    @Test func theSameAccountsVaultTokenIsStillRecovered() async throws {
        let transport = Self.transport()
        let (provider, transfer, store) = try await device(transport, token: Self.token("A", expiresIn: -60),
                                                    vault: Self.token("A2", expiresIn: 3000), vaultUser: "user-A")
        let account = PlaylistWriteAccount(accountID: "user-A", session: provider.session)
        try await provider.add([song], toPlaylist: "pl", as: account)
        #expect(writes(transport).map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer at-A2"])
        #expect(store.load()?.accessToken == "at-A2")
        #expect(provider.authStatus.isSignedIn)
        withExtendedLifetime(transfer) {}
    }
}
