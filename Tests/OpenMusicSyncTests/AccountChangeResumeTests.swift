import Foundation
import OpenMusicCore
import Testing
@testable import OpenMusicSync

/// The cases the fifth review of the accounts design found, each an operation resuming after another one changed
/// the account: a late device list deleting the saved rotation key that opens the waiting rotation, a registration
/// prepared for one user enqueued under the next user's identity, a sign-out ending a Clerk session that signed in
/// while it waited, and a sign-out after a lost first registration dropping the only token of a holder row.
@MainActor
@Suite(.serialized) struct AccountChangeResumeTests {
    let url = URL(string: "https://example-123.convex.cloud")!

    func device(_ server: FakeKeyServer, _ name: String, store: any SyncCredentialStore = MemoryCredentialStore(),
                http: (any HTTPPoster)? = nil, fallbackAfter: Int = 1) -> SyncService {
        let transport = FakeTransport()
        transport.autoFail = true
        return SyncService(deploymentURL: url, deviceInfo: DeviceInfo(name: name, platform: .ios, model: "t", appVersion: "1"),
                           credentials: store, transport: transport, http: http ?? server.http(), options: fastOptions(fallbackAfter: fallbackAfter))
    }

    func signIn(_ service: SyncService, user: String = "u") async throws {
        try await service.signIn(auth: FakeTokens([jwt(user)]), userID: user)
    }

    func comparison(_ service: SyncService) -> SyncService.KeyComparison? {
        if case .comparing(let c) = service.keyStatus { c } else { nil }
    }

    func twoHolders(_ server: FakeKeyServer) async throws -> (mac: SyncService, phone: SyncService) {
        let mac = device(server, "Leo's Mac")
        try await signIn(mac)
        let phone = device(server, "Leo's iPhone")
        try await signIn(phone)
        #expect(await waitUntil { mac.keyRequests.count == 1 && comparison(phone) != nil })
        try await mac.allowKey(for: try #require(mac.keyRequests.first))
        phone.confirmKeyCode()
        #expect(await waitUntil { phone.keyStatus == .available && server.device(named: "Leo's iPhone")?.state == .holder(rekey: nil) })
        return (mac, phone)
    }

    // MARK: 1. A late list never deletes the saved rotation key

    /// The Mac holds K1 and rotated to K2, but the answer was lost, so it holds K1 with K2 saved. The phone took K2,
    /// rotated to K3 (wrapped for the Mac under K2) and left. Then the Mac's delayed list from before any rotation
    /// arrives (K1, no rotation needed). It used to delete K2 on the spot ("never landed, not needed"); the Mac then
    /// couldn't open K3, its release passed the server's check, and as the only holder it reset a vault it could have
    /// opened. Now an older list is ignored, K2 stays, and K3 opens with it.
    @Test func aDelayedOldListNeverDeletesTheSavedRotationKey() async throws {
        let server = FakeKeyServer()
        let (mac, phone) = try await twoHolders(server)
        let k1 = try #require(mac.libraryKey)
        let sealed = try SignInSealing.seal(Data("spotify sign-in".utf8), provider: .spotify, revision: 1, key: k1)
        server.putRow(.init(provider: "spotify", sealed: sealed, keyId: k1.id, revision: 1, updatedAt: 1, updatedBy: "x"))
        #expect(await waitUntil { mac.vaultEntries?.count == 1 && phone.vaultEntries?.count == 1 })
        let stale = try server.listResult(for: "Leo's Mac")
        #expect(stale.keyId == k1.id && stale.rotationNeeded == false && stale.rekey == nil)

        // The Mac rotates K1 → K2; the server takes it, the answer is lost and the Mac hears nothing more.
        server.setAway("Leo's iPhone", true)
        server.loseRotateAnswer(true)
        server.setLibrary(keyId: k1.id, rotationNeeded: true)
        #expect(await waitUntil { server.keyId != nil && server.keyId != k1.id })
        let k2 = try #require(server.keyId)
        #expect(mac.libraryKey == k1 && mac.credentials?.nextLibraryKey?.id == k2)

        // The phone takes K2, rotates K2 → K3 (wrapped for the Mac under K2) and leaves.
        server.setAway("Leo's iPhone", false)
        #expect(await waitUntil { phone.libraryKey?.id == k2 && server.device(named: "Leo's iPhone")?.state == .holder(rekey: nil) })
        server.setLibrary(keyId: k2, rotationNeeded: true)
        #expect(await waitUntil { server.keyId != k2 && phone.libraryKey?.id == server.keyId })
        let k3 = try #require(server.keyId)
        guard case .holder(let rekey?)? = server.device(named: "Leo's Mac")?.state else {
            Issue.record("the Mac should have K3 waiting")
            return
        }
        #expect(rekey.keyId == k3 && rekey.fromKeyId == k2)
        phone.stop()
        server.remove("Leo's iPhone")

        // The delayed list arrives while the Mac still can't reach the server.
        mac.apply(stale)
        try await Task.sleep(for: .milliseconds(150))
        #expect(mac.credentials?.nextLibraryKey?.id == k2, "the late list deleted the saved rotation key")

        // Back online, the Mac opens K3 with K2 (and, the phone having left, rotates on to a key of its own). The
        // vault is never cleared and no release is sent.
        server.setAway("Leo's Mac", false)
        #expect(await waitUntil { mac.libraryKey != nil && mac.libraryKey?.id == server.keyId && mac.keyStatus == .available && !mac.rotationNeeded })
        #expect(server.keyId != nil && server.keyId != k1.id && server.keyId != k2)
        #expect(server.calls("keys:accept", by: "Leo's Mac").contains { $0.args["keyId"]?.stringValue == k3 })
        #expect(server.calls("keys:release", by: "Leo's Mac").isEmpty)
        #expect(server.violations.isEmpty)
        let row = try #require(server.vault.first)
        #expect(row.sealed != nil && !row.cleared && row.keyId == server.keyId)
        let opened = try SignInSealing.open(try #require(row.sealed), provider: .spotify, revision: row.revision, key: try #require(mac.libraryKey))
        #expect(opened == Data("spotify sign-in".utf8))
        mac.stop()
    }

    // MARK: 2. A call takes the identity it was made for

    /// User A's sign-in saved its registration and, while it was on its way to the client (`client.start()`), user
    /// B's sign-in changed the identity. A's registration used to be enqueued after that and take B's scope, so it
    /// went out with B's token. Now the call carries A's scope from the moment it was made (and A's sign-in, overtaken,
    /// stops), so nothing with A's device token is ever sent under B.
    @Test func aRegistrationPreparedForOneUserIsNeverEnqueuedUnderTheNext() async throws {
        let server = FakeKeyServer()
        let http = server.http()
        let store = HookedStore()
        let mac = device(server, "Leo's Mac", store: store, http: http, fallbackAfter: 3)
        let second = Box<Task<Void, any Error>?>(nil)
        let aToken = Box<String?>(nil)
        store.onPersistState = { name, data in
            guard name == SyncService.PendingRegistration.stateName, second.value == nil, let data,
                  let saved = try? JSONDecoder().decode(SyncService.PendingRegistration.self, from: data), saved.userID == "a" else { return }
            aToken.value = saved.token
            // B signs in the moment A's registration is saved, before A's call reaches the client.
            second.value = MainActor.assumeIsolated {
                Task { try await mac.signIn(auth: FakeTokens([jwt("b")]), userID: "b") }
            }
        }
        let first = Task { try await mac.signIn(auth: FakeTokens([jwt("a")]), userID: "a") }
        _ = await first.result
        let bSignIn = try #require(second.value)
        try await bSignIn.value
        let a = try #require(aToken.value)

        for request in http.requests where firstArgs(request.body)?["token"]?.stringValue == a {
            #expect(request.headers["Authorization"] == "Bearer \(jwt("a"))", "A's device token went out under another identity")
        }
        #expect(!server.devices.contains { $0.token == a })
        #expect(store.load()?.userID == "b" && server.devices.count == 1)
        #expect(mac.libraryKey != nil && mac.libraryKey?.id == server.keyId)
        mac.stop()
    }

    // MARK: 3. Sign-out ends only the Clerk session it started for

    /// User A taps Sign Out; sync's device removal waits on the server. User B signs in with Clerk meanwhile and sync
    /// signs in as B. When the removal answers, the app used to call `account.signOut()`, which ended whichever
    /// session was current: B's. Now the sign-out ends A's session only, so B stays signed in, at Clerk and in sync.
    @Test func aSignOutNeverEndsTheClerkSessionThatSignedInWhileItWaited() async throws {
        let clerkHTTP = FakeClerk()
        clerkHTTP.on("POST /v1/client/sign_ins") { _ in
            .init(json: ["response": ["id": "sia_1", "status": "needs_first_factor",
                                      "supported_first_factors": [["strategy": "email_code", "email_address_id": "idn_1"]]]],
                  authorization: "client-jwt-b")
        }
        clerkHTTP.on("POST /v1/client/sign_ins/sia_1/prepare_first_factor") { _ in .init(json: ["response": ["id": "sia_1"]]) }
        clerkHTTP.on("POST /v1/client/sign_ins/sia_1/attempt_first_factor") { _ in
            .init(json: ["response": ["id": "sia_1", "status": "complete", "created_session_id": "sess_b"]])
        }
        clerkHTTP.on("POST /v1/client/sessions/sess_b/touch") { _ in
            .init(json: ["response": [:] as [String: Any], "client": clientJSON(session: "sess_b", user: "user_b", email: "b@example.com")])
        }
        clerkHTTP.on("GET /v1/client") { _ in .init(json: ["response": clientJSON(session: "sess_a", user: "user_a")]) }
        clerkHTTP.on("GET /v1/environment") { _ in .init(json: ["user_settings": ["social": [:] as [String: Any]]]) }
        clerkHTTP.on("POST /v1/client/sessions/sess_a/remove") { _ in .init(json: ["response": ["id": "sess_a"]]) }
        clerkHTTP.on("POST /v1/client/sessions/sess_b/remove") { _ in .init(json: ["response": ["id": "sess_b"]]) }
        let clerkStore = MemoryClerkStore(ClerkState(frontendAPI: "https://clerk.openmusic.test", clientToken: "client-jwt-a", sessionID: "sess_a",
                                                     user: ClerkUser(id: "user_a", email: "a@example.com")))
        let config = FakeHTTP()
        config.respond = { _, _ in .object(["status": .string("success"), "value": .object(["auth": .object(["kind": .string("clerk"), "publishableKey": .string(testPublishableKey)])])]) }
        let defaults = try #require(UserDefaults(suiteName: "openmusic-tests-\(UUID().uuidString)"))
        let account = AccountService(hostedURL: url, store: clerkStore, defaults: defaults, http: config, clerkHTTP: clerkHTTP)
        account.watchesNetwork = false
        await account.load()
        #expect(account.user?.id == "user_a")
        try await Task.sleep(for: .milliseconds(100))   // the launch's restore has answered

        let server = FakeKeyServer()
        let gate = HTTPGate(server.http(), holding: "devices:remove")
        let mac = device(server, "Leo's Mac", http: gate)
        try await signIn(mac, user: "user_a")
        let aDevice = try #require(mac.selfID)

        let signingOut = Task { await account.signOut(sync: mac) }
        #expect(await eventually { gate.waiting > 0 })
        // B signs in with Clerk, and the app connects sync as B, while A's sign-out waits.
        let challenge = try await account.startEmail("b@example.com")
        try await account.verifyEmail(challenge, code: "123456")
        #expect(account.user?.id == "user_b")
        let connecting = Task { try await mac.signIn(auth: FakeTokens([jwt("user_b")]), userID: "user_b") }
        try await Task.sleep(for: .milliseconds(50))

        gate.open()
        await signingOut.value
        try await connecting.value
        #expect(account.user?.id == "user_b" && clerkStore.load()?.sessionID == "sess_b")
        #expect(!clerkHTTP.requests.contains { $0.url?.path == "/v1/client/sessions/sess_b/remove" }, "B's session was ended")
        #expect(mac.isRegistered && mac.credentials?.userID == "user_b" && mac.selfID != aDevice)
        #expect(server.devices.allSatisfy { $0.id != aDevice.rawValue })
        mac.stop()
    }

    // MARK: 4. Sign-out after a lost first registration

    /// The first device's registration landed (it holds the account's key on the server) but the answer was lost, so
    /// the device never learned its id. Signing out used to skip the removal (no id) and delete the saved
    /// registration, the only copy of that row's token: the holder row stayed, and with it the account couldn't
    /// reset. Now sign-out removes it by its token.
    @Test func aSignOutAfterALostFirstRegistrationRemovesThatDevice() async throws {
        let server = FakeKeyServer()
        let store = MemoryCredentialStore()
        let mac = device(server, "Leo's Mac", store: store)
        server.loseRegisterAnswer(true)
        await #expect(throws: (any Error).self) { try await signIn(mac) }
        server.loseRegisterAnswer(false)
        #expect(server.devices.count == 1 && server.device(named: "Leo's Mac")?.state == .holder(rekey: nil) && server.keyId != nil)
        #expect(savedRegistration(store) != nil && !mac.isRegistered)

        await mac.signOut()
        #expect(server.devices.isEmpty, "the holder row of the lost registration was left behind")
        #expect(savedRegistration(store) == nil && store.load() == nil)
        #expect(mac.pendingRemovals.isEmpty)
    }

    /// The same sign-out offline: the device to remove is recorded before the saved registration goes, and the next
    /// sign-in of the same user removes it. Until then the server keeps the row (it is never dropped silently).
    @Test func anOfflineSignOutAfterALostFirstRegistrationRemovesItOnTheNextSignIn() async throws {
        let server = FakeKeyServer()
        let store = MemoryCredentialStore()
        let mac = device(server, "Leo's Mac", store: store)
        server.loseRegisterAnswer(true)
        await #expect(throws: (any Error).self) { try await signIn(mac) }
        server.loseRegisterAnswer(false)
        let orphan = try #require(server.devices.first)

        server.setUnreachable(true)
        await mac.signOut()
        #expect(server.devices.map(\.id) == [orphan.id])
        #expect(savedRegistration(store) == nil)
        #expect(mac.pendingRemovals.map(\.token) == [orphan.token])

        // Another user signing in here doesn't touch it.
        let triedOffline = server.calls("account:unregister").count
        server.setUnreachable(false)
        let relaunched = device(server, "Leo's Mac", store: store)
        try await signIn(relaunched, user: "other")
        try await Task.sleep(for: .milliseconds(150))
        #expect(server.devices.contains { $0.id == orphan.id })
        #expect(!server.calls("account:unregister").dropFirst(triedOffline).contains { $0.args["token"]?.stringValue == orphan.token })
        await relaunched.signOut()

        // The same user again: the orphan goes, the account resets, and this device claims a fresh key.
        let again = device(server, "Leo's Mac", store: store)
        try await signIn(again)
        #expect(await waitUntil { !server.devices.contains { $0.id == orphan.id } })
        #expect(await waitUntil { again.libraryKey != nil && again.libraryKey?.id == server.keyId })
        #expect(again.pendingRemovals.isEmpty)
        again.stop()
    }
}

/// A credential store that tells the test as state is saved (to start something at that exact moment).
final class HookedStore: SyncCredentialStore, @unchecked Sendable {
    let inner = MemoryCredentialStore()
    var onPersistState: (@Sendable (String, Data?) -> Void)?

    func load() -> SyncCredentials? { inner.load() }
    func save(_ credentials: SyncCredentials?) { inner.save(credentials) }
    func state(_ name: String) -> Data? { inner.state(name) }
    func setState(_ name: String, _ data: Data?) { inner.setState(name, data) }
    func persistState(_ name: String, _ data: Data?) -> Bool {
        inner.setState(name, data)
        onPersistState?(name, data)
        return inner.state(name) == data
    }
}
