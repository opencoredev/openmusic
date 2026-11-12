import Foundation
import OpenMusicCore
import Testing
@testable import SpotifyKit

/// Holds the first `/me` asked with `bearer` until `release` opens (after signalling `reached`).
final class HeldIdentity: SpotifyTransport, @unchecked Sendable {
    let inner: OwnerScript
    let bearer: String
    let reached = Gate()
    let release = Gate()
    private let lock = NSLock()
    private var held = false

    init(_ inner: OwnerScript, holding bearer: String) {
        self.inner = inner
        self.bearer = bearer
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { try await send(request, uncached: false) }

    func send(_ request: URLRequest, uncached: Bool) async throws -> (Data, HTTPURLResponse) {
        let hold = request.url?.path == "/v1/me" && request.value(forHTTPHeaderField: "Authorization") == "Bearer \(bearer)"
            && lock.withLock { defer { held = true }; return !held }
        if hold {
            reached.open()
            await release.wait()
        }
        return try await inner.send(request, uncached: uncached)
    }
}

/// Sol's final pass on fbb606e: a token kept from an owner check that rotated it and then failed belongs to the account
/// and session it was checked for. It never outlives them, a late old check can't put it back, and when it doesn't
/// match or fails its check it is only dropped: the current sign-in is never deleted because of it.
@MainActor
@Suite struct RetainedCandidateTests {
    private static func token(_ name: String, expiresIn: TimeInterval) -> SpotifyToken {
        SpotifyToken(accessToken: "at-\(name)", refreshToken: "rt-\(name)", expiresAt: Date().addingTimeInterval(expiresIn), scope: "s",
                     clientID: SpotifyBuiltInClient.clientID)
    }

    @MainActor final class Vault { var token: SpotifyToken?; var user = "user-A" }

    private let song = Track(providerID: "x", provider: .spotify, title: "X", extra: ["uri": "spotify:track:x"])

    private func device(_ transport: any SpotifyTransport, vault: Vault) async throws -> (SpotifyProvider, SpotifySignInTransfer, MemoryTokenStore) {
        let store = MemoryTokenStore()
        let defaults = try #require(UserDefaults(suiteName: "openmusic.tests.\(UUID().uuidString)"))
        let provider = SpotifyProvider(defaults: defaults, transport: transport, tokenStore: store)
        provider.saveAccount = { _ in }
        let transfer = SpotifySignInTransfer(provider: provider)
        transfer.refreshRecoveryWait = .milliseconds(50)
        transfer.syncedSignIn = { vault.token.flatMap { try? SpotifySignInPayload(token: $0, userID: vault.user).encoded() } }
        for _ in 0..<5 { await Task.yield() }
        return (provider, transfer, store)
    }

    private func signIn(_ provider: SpotifyProvider, _ who: String, token: SpotifyToken) async throws {
        try await provider.adoptTransferredSignIn(token, account: AccountInfo(name: who, id: "user-\(who)"), userID: "user-\(who)")
        for _ in 0..<5 { await Task.yield() }
    }

    private func write(_ provider: SpotifyProvider, as who: String) async throws {
        try await provider.add([song], toPlaylist: "pl", as: PlaylistWriteAccount(accountID: "user-\(who)", session: provider.session))
    }

    /// A's check rotates the vault's token (A2 → A3) and times out: A3 is kept. The listener switches to B; another
    /// device rotated B's token (the vault now holds B2). B's recovery doesn't let A3 sign B out: B's sign-in is kept
    /// and recovered from the vault.
    @Test func anotherAccountsRetainedTokenNeverDeletesTheSignIn() async throws {
        let script = OwnerScript()
        script.rotate("rt-A2", to: "A3")
        let vault = Vault()
        vault.token = Self.token("A2", expiresIn: -60)
        let (provider, transfer, store) = try await device(script, vault: vault)
        try await signIn(provider, "A", token: Self.token("A", expiresIn: -60))
        script.failMe(.network(URLError(.timedOut).localizedDescription))
        await #expect(throws: (any Error).self) { try await write(provider, as: "A") }
        script.failMe(nil)

        try await signIn(provider, "B", token: Self.token("B", expiresIn: -60))
        vault.token = Self.token("B2", expiresIn: 3000)
        vault.user = "user-B"
        try await write(provider, as: "B")
        #expect(script.writes.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer at-B2"])
        #expect(store.load()?.accessToken == "at-B2", "B's sign-in kept and recovered")
        #expect(provider.authStatus.isSignedIn)
        withExtendedLifetime(transfer) {}
    }

    /// Sign-out drops the kept token: signed in as A again later, it isn't used.
    @Test func signOutClearsTheRetainedToken() async throws {
        let script = OwnerScript()
        script.rotate("rt-A2", to: "A3")
        let vault = Vault()
        vault.token = Self.token("A2", expiresIn: -60)
        let (provider, transfer, _) = try await device(script, vault: vault)
        try await signIn(provider, "A", token: Self.token("A", expiresIn: -60))
        script.failMe(.network(URLError(.timedOut).localizedDescription))
        await #expect(throws: (any Error).self) { try await write(provider, as: "A") }
        script.failMe(nil)

        try await transfer.signOut()
        vault.token = nil
        try await signIn(provider, "A", token: Self.token("A", expiresIn: -60))
        _ = try? await write(provider, as: "A")
        #expect(!script.writes.contains { $0.value(forHTTPHeaderField: "Authorization") == "Bearer at-A3" }, "the kept token was dropped")
        withExtendedLifetime(transfer) {}
    }

    /// A's check is still out when the listener switches to B; it then fails after rotating the token. That late result
    /// isn't kept, so B's recovery goes straight to the vault and B stays signed in.
    @Test func aLateOldCheckDoesNotKeepItsToken() async throws {
        let script = OwnerScript()
        script.rotate("rt-A2", to: "A3")
        let transport = HeldIdentity(script, holding: "at-A3")
        let vault = Vault()
        vault.token = Self.token("A2", expiresIn: -60)
        let (provider, transfer, store) = try await device(transport, vault: vault)
        try await signIn(provider, "A", token: Self.token("A", expiresIn: -60))
        let asA = PlaylistWriteAccount(accountID: "user-A", session: provider.session)
        let old = Task { try await provider.add([song], toPlaylist: "pl", as: asA) }
        await transport.reached.wait()

        try await signIn(provider, "B", token: Self.token("B", expiresIn: -60))
        script.failMe(.network(URLError(.timedOut).localizedDescription))
        transport.release.open()
        _ = try? await old.value
        script.failMe(nil)

        vault.token = Self.token("B2", expiresIn: 3000)
        vault.user = "user-B"
        try await write(provider, as: "B")
        #expect(script.writes.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer at-B2"])
        #expect(store.load()?.accessToken == "at-B2")
        withExtendedLifetime(transfer) {}
    }
}
