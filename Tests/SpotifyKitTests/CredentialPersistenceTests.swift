import Foundation
import OpenMusicCore
import Security
import Testing
@testable import SpotifyKit

/// A Keychain write that fails must be reported, never treated as saved: a sign-in that wasn't saved would be gone
/// at the next launch, and a sign-out that wasn't deleted would come back.
@MainActor
@Suite struct CredentialPersistenceTests {
    /// `MemoryTokenStore` whose writes fail while `failing` is set, the way a refused Keychain write does.
    final class FlakyTokenStore: SpotifyTokenStore, @unchecked Sendable {
        let inner = MemoryTokenStore()
        var failing = false
        func load() -> SpotifyToken? { inner.load() }
        func save(_ token: SpotifyToken?) throws {
            if failing { throw Keychain.Failure(status: errSecIO) }
            inner.save(token)
        }
    }

    func provider(_ store: FlakyTokenStore, transport: any SpotifyTransport = FakeTransport(SignInCancellationTests.routes)) -> SpotifyProvider {
        let defaults = UserDefaults(suiteName: "openmusic.tests.\(UUID().uuidString)")!
        let provider = SpotifyProvider(defaults: defaults, transport: transport, tokenStore: store)
        provider.saveAccount = { _ in }
        provider.authorize = { _, makeURL in
            let redirectURI = "http://127.0.0.1:8898/login"
            let url = makeURL(redirectURI)
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            return SpotifyAuthorization(callback: URL(string: "\(redirectURI)?code=the-code&state=\(state)")!, redirectURI: redirectURI)
        }
        return provider
    }

    @Test func aSignInTheKeychainRefusedIsReportedAndNotUsed() async {
        let store = FlakyTokenStore()
        store.failing = true
        let p = provider(store)
        await p.signIn()
        guard case .failed(let message) = p.authStatus else {
            Issue.record("expected a failed sign-in, got \(p.authStatus)")
            return
        }
        #expect(message.contains("Keychain"))
        #expect(await p.service.api.hasToken == false)
        #expect(p.session.identity == .signedOut)
    }

    @Test func aSignOutThatCantDeleteTheTokenThrowsAndStaysSignedIn() async throws {
        let store = FlakyTokenStore()
        let p = provider(store)
        await p.signIn()
        #expect(p.authStatus.isSignedIn)
        let before = p.session
        #expect(before.identity == .account(id: "ada.listener"))

        store.failing = true
        await #expect(throws: Keychain.Failure(status: errSecIO)) { try await p.trySignOut() }
        // Honest: still signed in, the token still saved and still used.
        #expect(p.authStatus.isSignedIn)
        #expect(store.load() != nil)
        #expect(await p.service.api.hasToken)
        #expect(p.session.identity == before.identity)

        // The non-throwing form doesn't pretend either.
        await p.signOut()
        #expect(p.authStatus.isSignedIn)

        store.failing = false
        try await p.trySignOut()
        #expect(p.authStatus == .signedOut)
        #expect(store.load() == nil)
        #expect(p.session.identity == .signedOut)
    }

    @Test func theSyncTransfersSignOutThrowsWhenTheTokenCantBeDeleted() async throws {
        let store = FlakyTokenStore()
        let p = provider(store)
        await p.signIn()
        let transfer = SpotifySignInTransfer(provider: p)
        store.failing = true
        // Sign-in sync must learn the token is still here, or it would treat a revocation as applied.
        await #expect(throws: Keychain.Failure(status: errSecIO)) { try await transfer.signOut() }
        #expect(p.authStatus.isSignedIn)
        #expect(await transfer.exportSignIn() != nil)

        store.failing = false
        try await transfer.signOut()
        #expect(p.authStatus == .signedOut)
        #expect(await transfer.exportSignIn() == nil)
    }

    @Test func aPendingReplacementStillReportsThePreviousAccount() async throws {
        let store = FlakyTokenStore()
        let transport = HeldTransport(holding: "/api/token", from: 1, SignInCancellationTests.routes)
        let p = provider(store, transport: transport)
        await p.signIn()
        let before = p.session
        #expect(before.identity == .account(id: "ada.listener"))
        let signIn = Task { await p.signIn() }
        await transport.reached.wait()
        #expect(p.authStatus == .signingIn)
        #expect(p.session == before)
        transport.release.open()
        await signIn.value
        #expect(p.authStatus.isSignedIn)
        #expect(p.session.generation > before.generation)
    }
}
