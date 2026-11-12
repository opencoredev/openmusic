import Foundation
import OpenMusicCore
import Testing
@testable import YouTubeMusicKit

/// A cookie check that waits until released, so tests can cancel sign-in while it runs.
/// Ignores task cancellation on purpose: a network reply can still arrive after the caller gave up.
private final class HeldCheck: @unchecked Sendable {
    private let lock = NSLock()
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var didReach = false
    private var didRelease = false
    let result: Result<AccountInfo, ProviderError>

    init(_ result: Result<AccountInfo, ProviderError> = .success(AccountInfo(name: "Ada"))) {
        self.result = result
    }

    func run(_ creds: YTMCredentials) async throws -> AccountInfo {
        let waiting = lock.withLock {
            didReach = true
            defer { reachedWaiters.removeAll() }
            return reachedWaiters
        }
        waiting.forEach { $0.resume() }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { didRelease ? true : { releaseWaiters.append(c); return false }() }
            if now { c.resume() }
        }
        return try result.get()
    }

    func reached() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { didReach ? true : { reachedWaiters.append(c); return false }() }
            if now { c.resume() }
        }
    }

    func release() {
        let waiting = lock.withLock {
            didRelease = true
            defer { releaseWaiters.removeAll() }
            return releaseWaiters
        }
        waiting.forEach { $0.resume() }
    }
}

/// Closing the sign-in sheet while cookies are still being checked must not sign in afterwards.
@MainActor
@Suite struct YTMSignInCancellationTests {
    let creds = YTMCredentials(cookies: ["SAPISID": "s", "SID": "i"])

    @Test func signsInWhenNotCancelled() async throws {
        let check = HeldCheck()
        check.release()
        let provider = YouTubeMusicProvider(validateAccount: { try await check.run($0) })
        try await provider.signIn(credentials: creds, persist: false)
        #expect(provider.authStatus == .signedIn(AccountInfo(name: "Ada")))
        #expect(await provider.client.isSignedIn)
    }

    @Test func cancelDuringCookieCheckLeavesSignedOut() async throws {
        let check = HeldCheck()
        let provider = YouTubeMusicProvider(validateAccount: { try await check.run($0) })
        let signIn = Task { try await provider.signIn(credentials: creds, persist: false) }
        await check.reached()
        #expect(provider.authStatus == .signingIn)
        provider.cancelSignIn()
        #expect(provider.authStatus == .signedOut)
        check.release()

        await #expect(throws: CancellationError.self) { try await signIn.value }
        #expect(provider.authStatus == .signedOut)
        #expect(await provider.client.isSignedIn == false)
    }

    @Test func cancellingTheCallerCancelsTheSignIn() async throws {
        // What the sheet's onDisappear does when it closes by other means: cancel the task it owns.
        let check = HeldCheck()
        let provider = YouTubeMusicProvider(validateAccount: { try await check.run($0) })
        let signIn = Task { try await provider.signIn(credentials: creds, persist: false) }
        await check.reached()
        signIn.cancel()
        check.release()

        await #expect(throws: CancellationError.self) { try await signIn.value }
        #expect(provider.authStatus == .signedOut)
        #expect(await provider.client.isSignedIn == false)
    }

    @Test func failedCheckReportsTheError() async throws {
        let check = HeldCheck(.failure(.notSignedIn))
        check.release()
        let provider = YouTubeMusicProvider(validateAccount: { try await check.run($0) })
        await #expect(throws: ProviderError.notSignedIn) { try await provider.signIn(credentials: creds, persist: false) }
        #expect(provider.authStatus == .failed(ProviderError.notSignedIn.localizedDescription))
        #expect(await provider.client.isSignedIn == false)
    }

    @Test func cancelKeepsAnExistingSession() async throws {
        let first = HeldCheck()
        first.release()
        let checks = [first, HeldCheck()]
        let calls = Counter()
        let provider = YouTubeMusicProvider(validateAccount: { try await checks[calls.next()].run($0) })
        try await provider.signIn(credentials: creds, persist: false)
        let before = provider.authStatus
        #expect(before.isSignedIn)

        let other = YTMCredentials(cookies: ["SAPISID": "s2", "SID": "i2"])
        let signIn = Task { try await provider.signIn(credentials: other, persist: false) }
        await checks[1].reached()
        provider.cancelSignIn()
        checks[1].release()
        await #expect(throws: CancellationError.self) { try await signIn.value }
        #expect(provider.authStatus == before)
        #expect(await provider.client.isSignedIn)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}

/// `session` names who requests go out as, from the credentials themselves, so the Home cache can't file one
/// account's shelves under another account or under signed out.
@MainActor
@Suite struct YTMSessionTests {
    let channelA = YTMCredentials(cookies: ["SAPISID": "s", "SID": "a"], authUser: 0, datasyncId: "chanA||userA")
    let channelB = YTMCredentials(cookies: ["SAPISID": "s", "SID": "b"], authUser: 0, datasyncId: "chanB||userA")

    @Test func theAccountIdIsTheDatasyncIdNeverTheHandleOrEmail() {
        #expect(YouTubeMusicProvider.accountID(channelA) == "datasync:chanA||userA")
        #expect(YouTubeMusicProvider.accountID(YTMCredentials(cookies: [:], datasyncId: "||userA")) == "datasync:||userA")
        // A pasted cookie header carries no datasync id: no id, so nothing personal is cached on disk.
        #expect(YouTubeMusicProvider.accountID(YTMCredentials(cookies: [:])) == nil)
        #expect(YouTubeMusicProvider.accountID(YTMCredentials(cookies: [:], datasyncId: "||")) == nil)
        let named = AccountInfo(name: "Ada", detail: "@ada", id: "handle:@ada")
        #expect(YouTubeMusicProvider.identified(named, channelA).id == "datasync:chanA||userA")
        #expect(YouTubeMusicProvider.identified(named, YTMCredentials(cookies: [:])).id == nil)
    }

    @Test func aPendingReplacementStillReportsThePreviousAccount() async throws {
        let first = HeldCheck(.success(AccountInfo(name: "A", detail: "@a")))
        first.release()
        let provider = YouTubeMusicProvider(validateAccount: { try await first.run($0) })
        #expect(provider.session.identity == .signedOut)
        try await provider.signIn(credentials: channelA, persist: false)
        let signedInA = provider.session
        #expect(signedInA.identity == .account(id: "datasync:chanA||userA"))
        #expect(provider.authStatus == .signedIn(AccountInfo(name: "A", detail: "@a", id: "datasync:chanA||userA")))

        // Replacing the account: while B's cookies are checked, `authStatus` is `.signingIn` but the client still
        // sends A's cookies, and `session` says so (the bug keyed this as signed out).
        let second = HeldCheck(.success(AccountInfo(name: "B", detail: "@b")))
        let a = channelA
        let replacing = YouTubeMusicProvider(validateAccount: { creds in
            creds == a ? try await first.run(creds) : try await second.run(creds)
        })
        try await replacing.signIn(credentials: channelA, persist: false)
        let before = replacing.session
        let signIn = Task { try await replacing.signIn(credentials: channelB, persist: false) }
        await second.reached()
        #expect(replacing.authStatus == .signingIn)
        #expect(replacing.session == before)
        second.release()
        try await signIn.value
        #expect(replacing.session.identity == .account(id: "datasync:chanB||userA"))
        #expect(replacing.session.generation > before.generation)
        #expect(await replacing.currentCredentials == channelB)
    }

    @Test func aCancelledReplacementKeepsTheSameSession() async throws {
        let first = HeldCheck()
        first.release()
        let second = HeldCheck()
        let a = channelA
        let provider = YouTubeMusicProvider(validateAccount: { creds in
            creds == a ? try await first.run(creds) : try await second.run(creds)
        })
        try await provider.signIn(credentials: channelA, persist: false)
        let before = provider.session
        let signIn = Task { try await provider.signIn(credentials: channelB, persist: false) }
        await second.reached()
        provider.cancelSignIn()
        second.release()
        _ = try? await signIn.value
        #expect(provider.session == before)
        #expect(await provider.currentCredentials == channelA)
    }
}
