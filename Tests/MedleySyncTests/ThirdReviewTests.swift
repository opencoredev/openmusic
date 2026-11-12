import Foundation
import MedleyCore
import Testing
@testable import MedleySync

/// The cases the third review of the accounts design found: an answer nonce a server could reuse under another
/// requester id, a saved rotation key dropped before it could open the next rotation, a holder left with no way to
/// the account's key, a stalled sign-in overwriting the next user's registration, and a registration dropped while
/// its credentials were never saved.
@MainActor
@Suite(.serialized) struct ThirdReviewTests {
    let url = URL(string: "https://example-123.convex.cloud")!

    func device(_ server: FakeKeyServer, _ name: String, store: any SyncCredentialStore = MemoryCredentialStore()) -> SyncService {
        let transport = FakeTransport()
        transport.autoFail = true
        return SyncService(deploymentURL: url, deviceInfo: DeviceInfo(name: name, platform: .ios, model: "t", appVersion: "1"),
                           credentials: store, transport: transport, http: server.http(), options: fastOptions(fallbackAfter: 1))
    }

    func signIn(_ service: SyncService, user: String = "u") async throws {
        try await service.signIn(auth: FakeTokens([jwt(user)]), userID: user)
    }

    func comparison(_ service: SyncService) -> SyncService.KeyComparison? {
        if case .comparing(let c) = service.keyStatus { c } else { nil }
    }

    /// The Mac holds the key and the phone took it through the codes: two holders.
    func twoHolders(_ server: FakeKeyServer, macStore: any SyncCredentialStore = MemoryCredentialStore()) async throws -> (mac: SyncService, phone: SyncService) {
        let mac = device(server, "Leo's Mac", store: macStore)
        try await signIn(mac)
        let phone = device(server, "Leo's iPhone")
        try await signIn(phone)
        #expect(await waitUntil { mac.keyRequests.count == 1 && comparison(phone) != nil })
        try await mac.allowKey(for: try #require(mac.keyRequests.first))
        phone.confirmKeyCode()
        #expect(await waitUntil { phone.keyStatus == .available && server.device(named: "Leo's iPhone")?.state == .holder(rekey: nil) })
        return (mac, phone)
    }

    // MARK: P1: the answer nonce covers the whole request

    /// A holder's nonce used to depend on the library and the commitment only, while the code also covers the asking
    /// device's id. Once the holder's record of an answer was pruned, a server could show the same commitment as
    /// another device and get the same nonce, so it could search offline for a device id whose code matched one it
    /// had fixed on the real device. Now the same commitment under another id gets a nonce of its own.
    @Test func aCommitmentShownAgainUnderAnotherRequesterGetsAnotherNonce() async throws {
        let server = FakeKeyServer()
        let mac = device(server, "Leo's Mac")
        let clock = ClockBox(Date(timeIntervalSince1970: 1_800_000_000))
        mac.now = { clock.value }
        try await signIn(mac)
        let answers = { server.calls("keys:answer", by: "Leo's Mac") }
        let commitment = KeyExchange.nonce().base64EncodedString()
        let publicKey = DeviceKeyPair.generate().publicKey
        server.answerMischief(.conflictAndShowAgain)
        server.addAskingDevice("Made-up iPad", commitment: commitment, publicKey: publicKey)
        #expect(await waitUntil { answers().count == 1 })
        let first = try #require(answers().first)

        // Two days on, the record of that answer is gone; the same commitment and key come back under another id.
        clock.value = clock.value.addingTimeInterval(2 * 24 * 3600)
        mac.ledger.answers.removeAll()
        server.remove("Made-up iPad")
        server.addAskingDevice("Made-up iPad 2", commitment: commitment, publicKey: publicKey)
        #expect(await waitUntil { answers().count == 2 })
        let second = try #require(answers().last)
        #expect(second.args["commitment"] == first.args["commitment"])
        #expect(second.args["deviceId"] != first.args["deviceId"])
        #expect(second.args["nonce"] != first.args["nonce"])
        mac.stop()
    }

    // MARK: P2-a: a saved rotation key opens the rotation made from it

    /// The Mac saved K2 and rotated K1→K2, but lost the answer and quit. The phone took K2 and rotated to K3, wrapping
    /// K3 to the Mac with K2. Back, the Mac holds K1 and the saved K2: it used to drop K2 because the server had moved
    /// past it, and then couldn't open the K2→K3 wrap, stuck as a holder of nothing. It now opens it with K2.
    @Test func aRotationWhoseAnswerWasLostStillOpensTheNextRotation() async throws {
        let server = FakeKeyServer()
        let macStore = MemoryCredentialStore()
        let (mac, phone) = try await twoHolders(server, macStore: macStore)
        let k1 = try #require(mac.libraryKey)

        // The Mac rotates (the phone is away, so the Mac is the one); the server takes it and the answer is lost.
        server.setAway("Leo's iPhone", true)
        server.loseRotateAnswer(true)
        server.setLibrary(keyId: k1.id, rotationNeeded: true)
        #expect(await waitUntil { server.keyId != k1.id && !server.calls("keys:rotate", by: "Leo's Mac").isEmpty })
        let k2 = try #require(server.keyId)
        mac.stop()
        #expect(macStore.load()?.libraryKey == k1 && macStore.load()?.nextLibraryKey?.id == k2)

        // The phone takes K2, then rotates to K3 while the Mac is gone.
        server.setAway("Leo's iPhone", false)
        #expect(await waitUntil { phone.libraryKey?.id == k2 })
        server.setLibrary(keyId: k2, rotationNeeded: true)
        #expect(await waitUntil { server.keyId != k2 && phone.libraryKey?.id == server.keyId })
        let k3 = try #require(server.keyId)

        server.setAway("Leo's Mac", false)
        let relaunched = device(server, "Leo's Mac", store: macStore)
        try await signIn(relaunched)
        #expect(await waitUntil { relaunched.libraryKey?.id == k3 && relaunched.keyStatus == .available })
        #expect(await waitUntil { server.device(named: "Leo's Mac")?.state == .holder(rekey: nil) })
        #expect(macStore.load()?.libraryKey?.id == k3 && macStore.load()?.nextLibraryKey == nil)
        relaunched.stop()
        phone.stop()
    }

    /// A holder whose key isn't the account's and that has no way to the current one (its rotated key never reached
    /// it) used to stay a `holder` on the server: Ask Again did nothing and no reset ever came. It now says so to the
    /// server (`keys:release`), keeps its key until the listener taps Ask Again, and then gets the current key
    /// through the codes like any device.
    @Test func aHolderThatCantReachTheAccountsKeyStepsDownAndAskAgainWorks() async throws {
        let server = FakeKeyServer()
        let (mac, phone) = try await twoHolders(server)
        let k1 = try #require(mac.libraryKey)

        // The phone rotates while the Mac is away, and the Mac's wrap is lost.
        server.setAway("Leo's Mac", true)
        server.setLibrary(keyId: k1.id, rotationNeeded: true)
        #expect(await waitUntil { server.keyId != k1.id && phone.libraryKey?.id == server.keyId })
        server.set("Leo's Mac", state: .holder(rekey: nil))
        server.setAway("Leo's Mac", false)

        #expect(await waitUntil { mac.keyStatus == .outdated })
        #expect(server.calls("keys:release", by: "Leo's Mac").count >= 1)
        #expect(server.device(named: "Leo's Mac")?.state.kind == "requested")
        // Nothing changes by itself: the key stays until the listener asks.
        #expect(mac.libraryKey == k1 && server.calls("keys:request", by: "Leo's Mac").isEmpty)

        try await mac.requestKeyAgain()
        #expect(mac.libraryKey == nil)
        #expect(await waitUntil { phone.keyRequests.count == 1 && comparison(mac) != nil })
        #expect(phone.keyRequests.first?.code == comparison(mac)?.code)
        try await phone.allowKey(for: try #require(phone.keyRequests.first))
        mac.confirmKeyCode()
        #expect(await waitUntil { mac.keyStatus == .available && mac.libraryKey?.id == server.keyId })
        mac.stop()
        phone.stop()
    }

    // MARK: P2-b: a sign-in overtaken by sign-out does nothing more

    /// A sign-in for user A stalls fetching its token; the device signs out and user B signs in (B's registration
    /// saved, its answer lost). When A's sign-in resumes, it used to replace B's saved registration with one of A's
    /// and send it under B's session. Now it stops: B's registration is untouched and nothing more is sent.
    @Test func aStalledSignInNeverTouchesTheNextUsersRegistration() async throws {
        let server = FakeKeyServer()
        let store = MemoryCredentialStore()
        let mac = device(server, "Leo's Mac", store: store)
        let stalled = GatedTokens(jwt("a"))
        let first = Task { try await mac.signIn(auth: stalled, userID: "a") }
        #expect(await eventually { await stalled.asked > 0 })

        await mac.signOut()
        server.loseRegisterAnswer(true)
        await #expect(throws: SyncError.self) { try await signIn(mac, user: "b") }
        let saved = try #require(savedRegistration(store))
        #expect(saved.userID == "b")
        let sent = server.calls("account:register").count

        await stalled.release()
        let outcome = await first.result
        if case .failure(let error) = outcome {
            #expect(error is CancellationError)
        } else {
            Issue.record("the overtaken sign-in reported success")
        }
        #expect(savedRegistration(store)?.token == saved.token && savedRegistration(store)?.userID == "b")
        #expect(server.calls("account:register").count == sent)

        // B's registration settles as usual.
        server.loseRegisterAnswer(false)
        try await signIn(mac, user: "b")
        #expect(store.load()?.userID == "b" && store.load()?.token == saved.token)
        #expect(savedRegistration(store) == nil)
        mac.stop()
    }

    // MARK: P2-c: the registration stays until its credentials are saved

    /// The device registered but the store refused its credentials: it syncs from memory and keeps the saved
    /// registration. A later sign-in used to drop that registration anyway, so a quit then lost the device and its
    /// key. Now the registration is dropped only once the credentials are saved, and a sign-in tries saving first.
    @Test func aRegistrationIsKeptUntilItsCredentialsAreSaved() async throws {
        let server = FakeKeyServer()
        let store = FlakyCredentialStore()
        store.failing = true
        let mac = device(server, "Leo's Mac", store: store)
        _ = try? await signIn(mac)
        #expect(mac.isRegistered && mac.libraryKey != nil && store.load() == nil)
        let pending = try #require(savedRegistration(store))

        // Still failing: the registration stays.
        _ = try? await signIn(mac)
        #expect(savedRegistration(store)?.token == pending.token)
        #expect(store.load() == nil)

        // The store works again: the credentials are saved first, then the registration goes.
        store.failing = false
        try await signIn(mac)
        #expect(store.load()?.token == pending.token && store.load()?.libraryKey == mac.libraryKey)
        #expect(savedRegistration(store) == nil)
        mac.stop()

        let relaunched = device(server, "Leo's Mac", store: store)
        try await signIn(relaunched)
        #expect(relaunched.selfID == mac.selfID && relaunched.libraryKey == mac.libraryKey)
        #expect(server.devices.count == 1)
        relaunched.stop()
    }
}

/// A token provider that waits, the first time it is asked, until the test lets it answer.
actor GatedTokens: AuthTokenProvider {
    private let value: String
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false
    private(set) var asked = 0

    init(_ value: String) { self.value = value }

    func token(forceRefresh: Bool) async throws -> String? {
        asked += 1
        if !open { await withCheckedContinuation { waiters.append($0) } }
        return value
    }

    func release() {
        open = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// A credential store whose credential writes fail while `failing` is set (state blobs still save).
final class FlakyCredentialStore: SyncCredentialStore, @unchecked Sendable {
    private let inner = MemoryCredentialStore()
    private let lock = NSLock()
    private var _failing = false
    var failing: Bool {
        get { lock.withLock { _failing } }
        set { lock.withLock { _failing = newValue } }
    }

    func load() -> SyncCredentials? { inner.load() }
    func save(_ credentials: SyncCredentials?) { if !failing { inner.save(credentials) } }
    func persist(_ credentials: SyncCredentials?) -> Bool {
        guard !failing else { return false }
        inner.save(credentials)
        return true
    }
    func state(_ name: String) -> Data? { inner.state(name) }
    func setState(_ name: String, _ data: Data?) { inner.setState(name, data) }
    func persistState(_ name: String, _ data: Data?) -> Bool { inner.persistState(name, data) }
}
