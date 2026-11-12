import Foundation
import MedleyCore
import Testing
@testable import YouTubeMusicKit

/// `YouTubeMusicSignInTransfer` with fake sessions: no network, no Keychain (persist: false, memory store).
/// Sign-out isn't covered here because `YouTubeMusicProvider.signOut()` clears the real Keychain and web data.
@MainActor
@Suite struct YouTubeMusicSignInTransferTests {
    let creds = YTMCredentials(cookies: ["SAPISID": "sapisid-a", "SID": "sid-a", "__Secure-1PSIDTS": "ts-1"], authUser: 1,
                               datasyncId: "brand||user")

    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    func makeDevice(account: String = "Ada", clock: Clock = Clock(),
                    verify: YouTubeMusicSignInTransfer.Verifier? = nil) -> (YouTubeMusicProvider, YouTubeMusicSignInTransfer, Counter) {
        let provider = YouTubeMusicProvider(validateAccount: { _ in AccountInfo(name: account, detail: "@\(account.lowercased())") })
        let transfer = YouTubeMusicSignInTransfer(provider: provider, store: MemoryYouTubeMusicTransferStore(),
                                                  verify: verify ?? { $0.account ?? AccountInfo(name: "?") }, persist: false,
                                                  now: { clock.now })
        let counter = Counter()
        transfer.signInDidChange = { counter.count += 1 }
        return (provider, transfer, counter)
    }

    final class Counter { var count = 0 }

    /// The hook takes its snapshot in a task; let it run.
    func settle() async { for _ in 0..<5 { await Task.yield() } ; try? await Task.sleep(for: .milliseconds(20)) }

    @Test func signedOutExportsNothing() async {
        let (_, transfer, _) = makeDevice()
        #expect(await transfer.exportSignIn() == nil)
    }

    @Test func signInReportsAndExportsCookiesChannelAndAccount() async throws {
        let (provider, transfer, counter) = makeDevice()
        try await provider.signIn(credentials: creds, persist: false)
        await settle()
        #expect(counter.count == 1)
        let data = try #require(await transfer.exportSignIn())
        let payload = try YouTubeMusicSignInPayload.decode(data)
        #expect(payload.credentials == creds)
        #expect(payload.account?.name == "Ada")
        // Stable: asking again gives the same bytes.
        #expect(await transfer.exportSignIn() == data)
    }

    @Test func cookieRotationDoesNotChangeTheExportUntilTheSnapshotIsADayOld() async throws {
        let clock = Clock()
        let (provider, transfer, counter) = makeDevice(clock: clock)
        try await provider.signIn(credentials: creds, persist: false)
        await settle()
        let first = try #require(await transfer.exportSignIn())
        // Google rotates a cookie: the live session changes, the provider reports nothing.
        var rotated = creds
        rotated.cookies["__Secure-1PSIDTS"] = "ts-2"
        await provider.client.setCredentials(rotated, persist: false)
        #expect(await transfer.exportSignIn() == first)
        #expect(counter.count == 1)
        clock.now += YouTubeMusicSignInTransfer.snapshotMaxAge + 1
        let later = try #require(await transfer.exportSignIn())
        #expect(later != first)
        #expect(try YouTubeMusicSignInPayload.decode(later).credentials.cookies["__Secure-1PSIDTS"] == "ts-2")
    }

    @Test func channelSwitchReportsAndExportsTheNewChannel() async throws {
        let (provider, transfer, counter) = makeDevice()
        try await provider.signIn(credentials: creds, persist: false)
        await settle()
        var other = creds
        other.datasyncId = "otherbrand||user"
        try await provider.signIn(credentials: other, persist: false)
        await settle()
        #expect(counter.count == 2)
        let payload = try YouTubeMusicSignInPayload.decode(try #require(await transfer.exportSignIn()))
        #expect(payload.credentials.datasyncId == "otherbrand||user")
    }

    @Test func importSignsInAndExportsExactlyWhatArrived() async throws {
        let (a, transferA, _) = makeDevice(account: "Ada")
        try await a.signIn(credentials: creds, persist: false)
        await settle()
        let data = try #require(await transferA.exportSignIn())

        let (b, transferB, counterB) = makeDevice(account: "Someone else")
        try await transferB.importSignIn(data)
        await settle()
        // The id comes from the cookies' datasync id, never the handle.
        #expect(b.authStatus == .signedIn(AccountInfo(name: "Ada", detail: "@ada", id: "datasync:brand||user")))
        #expect(await b.currentCredentials == creds)
        #expect(counterB.count == 1)
        // The echo of the import finds nothing new to upload.
        #expect(await transferB.exportSignIn() == data)
    }

    @Test func rejectedImportKeepsThisDevicesSession() async throws {
        let (a, transferA, _) = makeDevice(account: "Ada")
        try await a.signIn(credentials: creds, persist: false)
        await settle()
        let data = try #require(await transferA.exportSignIn())

        let (b, transferB, _) = makeDevice(account: "Bob", verify: { _ in throw ProviderError.notSignedIn })
        let own = YTMCredentials(cookies: ["SAPISID": "sapisid-b", "SID": "sid-b"])
        try await b.signIn(credentials: own, persist: false)
        await settle()
        await #expect(throws: YouTubeMusicSignInTransfer.TransferError.rejected) { try await transferB.importSignIn(data) }
        #expect(b.authStatus.accountName == "Bob")
        #expect(await b.currentCredentials == own)
    }

    /// Offline: the import throws a retryable error and this device keeps its own working session.
    @Test func networkFailureKeepsThisDevicesSession() async throws {
        let (a, transferA, _) = makeDevice(account: "Ada")
        try await a.signIn(credentials: creds, persist: false)
        await settle()
        let data = try #require(await transferA.exportSignIn())

        let (b, transferB, counterB) = makeDevice(account: "Bob", verify: { _ in throw ProviderError.network("offline") })
        let own = YTMCredentials(cookies: ["SAPISID": "sapisid-b", "SID": "sid-b"])
        try await b.signIn(credentials: own, persist: false)
        await settle()
        let ownExport = try #require(await transferB.exportSignIn())
        let reports = counterB.count
        await #expect(throws: YouTubeMusicSignInTransfer.TransferError.unverified) { try await transferB.importSignIn(data) }
        #expect(b.authStatus.accountName == "Bob")
        #expect(await b.currentCredentials == own)
        #expect(await transferB.exportSignIn() == ownExport)
        #expect(counterB.count == reports)
        // A server error is no proof either.
        let (c, transferC, _) = makeDevice(verify: { _ in throw ProviderError.server(503, "unavailable") })
        await #expect(throws: YouTubeMusicSignInTransfer.TransferError.unverified) { try await transferC.importSignIn(data) }
        #expect(!c.authStatus.isSignedIn)
    }

    /// Signed out here and offline: structurally valid but unchecked cookies don't sign this device in.
    @Test func networkFailureDoesNotSignInWithUncheckedCookies() async throws {
        let (b, transferB, _) = makeDevice(verify: { _ in throw ProviderError.network("offline") })
        let garbage = try YouTubeMusicSignInPayload(credentials: YTMCredentials(cookies: ["SAPISID": "x", "SID": "y"]), account: AccountInfo(name: "Eve")).encoded()
        await #expect(throws: YouTubeMusicSignInTransfer.TransferError.unverified) { try await transferB.importSignIn(garbage) }
        #expect(!b.authStatus.isSignedIn)
        #expect(await b.currentCredentials == nil)
    }

    @Test func garbageAndTestPayloads() async throws {
        let (b, transferB, _) = makeDevice(verify: YouTubeMusicSignInTransfer.acceptingTestSignIns())
        await #expect(throws: YouTubeMusicSignInTransfer.TransferError.unreadable) { try await transferB.importSignIn(Data("refresh-1".utf8)) }
        #expect(!b.authStatus.isSignedIn)
        try await transferB.importSignIn(YouTubeMusicSignInTransfer.testPayload(accountName: "Probe Account"))
        #expect(b.authStatus.accountName == "Probe Account")
    }

    @Test func descriptionsRedactCookies() throws {
        let payload = YouTubeMusicSignInPayload(credentials: creds, account: AccountInfo(name: "Ada"))
        #expect(!String(describing: payload).contains("sapisid-a"))
        #expect(!"\(YouTubeMusicSignInTransfer.TransferredCredentials(credentials: creds, account: nil))".contains("sid-a"))
    }
}
