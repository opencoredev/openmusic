import Foundation
import OpenMusicCore
import Testing
@testable import OpenMusicSync

/// The cases the sixth review of the accounts design found, each failing on the code before it (1f0b0c2):
///
/// 1. An identity change whose new token can't be fetched kept the old identity's token: the socket still spoke for
///    A and HTTP sent A's JWT, so B's registration went into A's library.
/// 2. A withdrawn first registration (`account:unregister` answered "nothing to remove") could still land afterwards,
///    leaving a holder row whose token and key the device had discarded.
/// 3. A claim refused by nothing could land long after the device saw another key and dropped it, making the device
///    the holder of a key it no longer had.
/// 4. A Clerk sign-out erased a sign-in of the same user that finished while it waited for Clerk.
/// 5. A live query result delivered just before a session ended was applied after it.
/// Plus: claim and rotation answers count as observations, so an older list can't undo them.
@MainActor
@Suite(.serialized) struct IdentityChangeRaceTests {
    let url = URL(string: "https://example-123.convex.cloud")!

    func device(_ server: FakeKeyServer, _ name: String, store: any SyncCredentialStore = MemoryCredentialStore(),
                http: (any HTTPPoster)? = nil) -> SyncService {
        let transport = FakeTransport()
        transport.autoFail = true
        return SyncService(deploymentURL: url, deviceInfo: DeviceInfo(name: name, platform: .ios, model: "t", appVersion: "1"),
                           credentials: store, transport: transport, http: http ?? server.http(), options: fastOptions(fallbackAfter: 1))
    }

    func signIn(_ service: SyncService, user: String = "u") async throws {
        try await service.signIn(auth: FakeTokens([jwt(user)]), userID: user)
    }

    // MARK: 1. Calls go out only with their own identity's token

    /// The socket is authenticated as A. B signs in, and B's token can't be fetched yet. B's call used to go out at
    /// once on the socket that still spoke for A. Now the socket drops A's identity at once, and B's call waits until
    /// B's token is here and has been sent ahead of it.
    @Test func aCallForBNeverGoesOutOnASocketThatSpeaksForA() async throws {
        let transport = FakeTransport()
        let client = makeClient(transport)
        await client.setAuth(FakeTokens([jwt("a")]), identity: "a")
        await client.start()
        #expect(await eventually { transport.sockets.count == 1 })
        let socket = transport.sockets[0]
        socket.open()
        #expect(await eventually { await client.status.state == .connected })

        let bTokens = FakeTokens([jwt("b")])
        await bTokens.setFails(true)
        let scope = await client.setAuth(bTokens, identity: "b")
        let call = Task { try await client.mutation("account:register", args: .object(["token": .string("b-device")]), scope: scope) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(socket.messages(ofType: "Mutation").isEmpty, "B's call went out on the socket authenticated as A")
        #expect(socket.messages(ofType: "Authenticate").last?["tokenType"] == .string("None"), "the socket still speaks for A")

        // B's token arrives: it is sent first, then the call.
        await bTokens.setFails(false)
        await client.setAuth(bTokens, identity: "b")
        #expect(await eventually { socket.messages(ofType: "Mutation").count == 1 })
        let types = socket.messages.compactMap { message -> String? in
            switch message["type"]?.stringValue {
            case "Authenticate": message["value"]?.stringValue.flatMap { IdentityAudit.subject("Bearer \($0)") } ?? "none"
            case "Mutation": "call"
            default: nil
            }
        }
        #expect(types.suffix(2) == ["b", "call"], "\(types)")
        call.cancel()
        await client.stop()
    }

    /// The same over HTTP, end to end: the Mac is signed in as A; B signs in while B's token can't be fetched. B's
    /// registration used to go out with A's cached JWT and land in A's library. Now it waits for B's token and lands
    /// in B's own library.
    @Test func aRegistrationForBNeverCarriesAsTokenOverHTTP() async throws {
        let server = FakeKeyServer()
        let audit = IdentityAudit(server.http())
        let store = HookedStore()
        store.onPersistState = { name, data in
            guard name == SyncService.PendingRegistration.stateName, let data,
                  let saved = try? JSONDecoder().decode(SyncService.PendingRegistration.self, from: data) else { return }
            audit.expect(token: saved.token, user: saved.userID)
        }
        let mac = device(server, "Leo's Mac", store: store, http: audit)
        try await signIn(mac, user: "a")
        #expect(server.devices(of: "a").count == 1)

        let bTokens = FakeTokens([jwt("b")])
        await bTokens.setFails(true)
        let switching = Task { try await mac.signIn(auth: bTokens, userID: "b") }
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.devices(of: "a").count == 1, "B's registration landed in A's library")
        #expect(audit.violations.isEmpty, "\(audit.violations)")
        // B's token can be fetched now: the client's own retry gets it, and the registration goes out with it.
        await bTokens.setFails(false)
        try await switching.value
        #expect(await waitUntil { server.devices(of: "b").count == 1 })
        #expect(server.devices(of: "a").allSatisfy { $0.token != savedRegistration(store)?.token })
        #expect(audit.violations.isEmpty, "\(audit.violations)")
        mac.stop()
    }

    // MARK: 2. A withdrawn registration never lands later

    /// The first registration was sent and got no answer; it is still on its way when the device signs out. With a
    /// server that records withdrawals, the late registration is refused and nothing is left behind.
    @Test func aRegistrationStillOnItsWayWhenTheDeviceSignsOutNeverLands() async throws {
        let server = FakeKeyServer()
        let store = MemoryCredentialStore()
        let mac = device(server, "Leo's Mac", store: store)
        server.delay("account:register")
        await #expect(throws: (any Error).self) { try await signIn(mac) }
        #expect(savedRegistration(store) != nil && server.parked == 1)
        await mac.signOut()
        server.commitDelayed()
        #expect(server.devices.isEmpty, "the late registration made a device whose token and key are gone")
        #expect(mac.pendingRemovals.isEmpty)
    }

    /// The same against a server that doesn't record withdrawals (it answers only "nothing to remove"): the device
    /// used to drop the token at once, and the late registration left a holder nobody could use. Now it keeps the
    /// removal until the server confirms, and the next sign-in of the same user removes the late row.
    @Test func aRemovalIsKeptUntilTheServerConfirmsTheTokenIsSettled() async throws {
        let server = FakeKeyServer()
        server.legacyUnregister(true)
        let store = MemoryCredentialStore()
        let mac = device(server, "Leo's Mac", store: store)
        server.delay("account:register")
        await #expect(throws: (any Error).self) { try await signIn(mac) }
        let token = try #require(savedRegistration(store)?.token)
        await mac.signOut()
        #expect(mac.pendingRemovals.map(\.token) == [token], "the token was dropped on \"nothing to remove\"")
        server.commitDelayed()
        #expect(server.devices.map(\.token) == [token])   // the late registration landed

        let again = device(server, "Leo's Mac", store: store)
        try await signIn(again)
        #expect(await waitUntil { !server.devices.contains { $0.token == token } }, "the orphan holder stayed")
        #expect(await waitUntil { again.libraryKey != nil && again.libraryKey?.id == server.keyId })
        again.stop()
    }

    // MARK: 3. A claim lands only on the state it was decided on

    /// The phone claims C for a keyless account, but the claim is still on its way. The iPad joins with a key of its
    /// own (K'), the phone sees K' and drops C, the iPad leaves (the account is keyless again), and only then does the
    /// phone's claim run. It used to land: the phone became the holder of C, which it no longer had, and the account
    /// could never recover. Now the claim carries the revision it was decided on and is refused.
    @Test func aClaimStillOnItsWayNeverLandsAfterTheDeviceDroppedItsKey() async throws {
        let server = FakeKeyServer()
        let mac = device(server, "Leo's Mac")
        try await signIn(mac)
        let phone = device(server, "Leo's iPhone")
        try await signIn(phone)
        server.delay("keys:claim", count: 1000)   // every copy of the claim, retries included, is on its way
        await mac.signOut()   // the phone can't open the vault: the key resets
        #expect(await waitUntil { server.parked >= 1 && phone.credentials?.claimingLibraryKey != nil })
        let claimed = try #require(phone.credentials?.claimingLibraryKey)

        let iPad = device(server, "Leo's iPad")
        try await signIn(iPad)
        let other = try #require(server.keyId)
        #expect(other != claimed.id)
        #expect(await waitUntil { phone.credentials?.claimingLibraryKey == nil && phone.serverKeyID == other })

        server.setAway("Leo's iPhone", true)
        await iPad.signOut()
        server.commitDelayed()
        server.setAway("Leo's iPhone", false)

        #expect(server.keyId != claimed.id, "the late claim made the phone the holder of a key it had dropped")
        #expect(await waitUntil { phone.libraryKey != nil && phone.libraryKey?.id == server.keyId })
        phone.stop()
    }

    // MARK: 4. A sign-out never erases a newer sign-in of the same user

    /// Sign-out forgets the Clerk session and waits for Clerk to end it. The same user signs in again meanwhile (a new
    /// session). Sign-out used to check only the user id when Clerk answered, find "the same user", erase the saved
    /// sign-in and show signed out. Now it compares the sign-in generation and leaves the new session alone.
    @Test func aSignOutNeverErasesTheSameUsersNewerSignIn() async throws {
        let clerkHTTP = FakeClerk()
        clerkHTTP.on("POST /v1/client/sign_ins") { _ in
            .init(json: ["response": ["id": "sia_2", "status": "needs_first_factor",
                                      "supported_first_factors": [["strategy": "email_code", "email_address_id": "idn_1"]]]])
        }
        clerkHTTP.on("POST /v1/client/sign_ins/sia_2/prepare_first_factor") { _ in .init(json: ["response": ["id": "sia_2"]]) }
        clerkHTTP.on("POST /v1/client/sign_ins/sia_2/attempt_first_factor") { _ in
            .init(json: ["response": ["id": "sia_2", "status": "complete", "created_session_id": "sess_2"]])
        }
        clerkHTTP.on("POST /v1/client/sessions/sess_2/touch") { _ in
            .init(json: ["response": [:] as [String: Any], "client": clientJSON(session: "sess_2", user: "user_a")])
        }
        clerkHTTP.on("GET /v1/client") { _ in .init(json: ["response": clientJSON(session: "sess_1", user: "user_a")]) }
        clerkHTTP.on("GET /v1/environment") { _ in .init(json: ["user_settings": ["social": [:] as [String: Any]]]) }
        clerkHTTP.on("POST /v1/client/sessions/sess_1/remove") { _ in .init(json: ["response": ["id": "sess_1"]]) }
        let removal = AsyncGate()
        clerkHTTP.hold("POST /v1/client/sessions/sess_1/remove", removal)
        let clerkStore = MemoryClerkStore(ClerkState(frontendAPI: "https://clerk.openmusic.test", clientToken: "client-jwt", sessionID: "sess_1",
                                                     user: ClerkUser(id: "user_a", email: "a@example.com")))
        let config = FakeHTTP()
        config.respond = { _, _ in .object(["status": .string("success"), "value": .object(["auth": .object(["kind": .string("clerk"), "publishableKey": .string(testPublishableKey)])])]) }
        let defaults = try #require(UserDefaults(suiteName: "openmusic-tests-\(UUID().uuidString)"))
        let account = AccountService(hostedURL: url, store: clerkStore, defaults: defaults, http: config, clerkHTTP: clerkHTTP)
        account.watchesNetwork = false
        await account.load()
        try await Task.sleep(for: .milliseconds(100))   // the launch's restore has answered
        #expect(account.user?.id == "user_a")

        let session = await account.currentSession()
        let signingOut = Task { await account.signOut(ifStill: session) }
        #expect(await eventually { clerkHTTP.requests.contains { $0.url?.path == "/v1/client/sessions/sess_1/remove" } })
        // The same user signs in again while Clerk ends the old session.
        let challenge = try await account.startEmail("a@example.com")
        try await account.verifyEmail(challenge, code: "123456")
        await removal.release()
        _ = await signingOut.value

        #expect(account.user?.id == "user_a", "the newer sign-in shows signed out")
        #expect(clerkStore.load()?.sessionID == "sess_2", "the newer sign-in was erased from the store")
        #expect(await account.currentSession().sessionID == "sess_2")
    }

    // MARK: 5. A live query result of an ended session is never applied

    /// A `vault:list` result is on its way to the main actor when the session ends. It used to be applied after the
    /// session had ended (in the app, to the next user's session: a tombstone there signs a provider out). Now every
    /// result is checked against the session and the task's cancellation right before it is applied.
    @Test func aResultDeliveredJustBeforeTheSessionEndedIsNotApplied() async throws {
        let server = FakeKeyServer()
        let tap = ResultTap(server.http(), path: "vault:list")
        let mac = device(server, "Leo's Mac", http: tap)
        try await signIn(mac)
        #expect(await waitUntil { mac.vaultEntries == [] })

        tap.arm()
        server.putRow(.init(provider: "spotify", sealed: nil, keyId: String(repeating: "0", count: 32), revision: 1, updatedAt: 1, updatedBy: "x"))
        // Hold the main actor until the new result has been handed to the live query's stream, then end the session
        // before the main actor can run the code that applies it.
        let started = Date()
        while !tap.answered, Date().timeIntervalSince(started) < 5 {}
        let handed = Date()
        while Date().timeIntervalSince(handed) < 0.15 {}
        #expect(tap.answered)
        mac.forget()

        try await Task.sleep(for: .milliseconds(150))
        #expect(mac.vaultEntries == nil, "a vault result of the ended session was applied after it ended")
        mac.stop()
    }

    // MARK: Claim and rotation answers are observations

    /// A device list from before this device's own claim arrives after the claim's answer. It used to be applied (the
    /// claim's answer didn't count as newer), showing the account keyless again and sending a second claim.
    @Test func aListOlderThanTheClaimsAnswerIsIgnored() async throws {
        let server = FakeKeyServer()
        let mac = device(server, "Leo's Mac")
        try await signIn(mac)
        let lists = PathBlocker(server.http(), path: "devices:list")
        let phone = device(server, "Leo's iPhone", http: lists)
        try await signIn(phone)
        server.setAway("Leo's iPhone", true)
        await mac.signOut()   // keyless now
        let stale = try server.listResult(for: "Leo's iPhone")
        #expect(stale.keyId == nil)
        // From the moment the claim reaches the server, no newer list reaches the phone: only the claim's answer
        // says the account moved on.
        server.loseClaimAnswer(false, onClaim: { _ in lists.block() })
        server.setAway("Leo's iPhone", false)
        #expect(await waitUntil { phone.libraryKey != nil && phone.libraryKey?.id == server.keyId })
        let claims = server.calls("keys:claim").count

        try await phone.operations.run { _ in phone.applyNow(stale) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(phone.serverKeyID == server.keyId, "an older list undid the claim's answer")
        #expect(server.calls("keys:claim").count == claims, "an older list made the device claim again")
        phone.stop()
    }

    /// The same for a rotation: a list from before it (the old key) arrives after the rotation's answer. It used to
    /// be applied, showing the old key as the account's (a mismatch) until the next list.
    @Test func aListOlderThanTheRotationsAnswerIsIgnored() async throws {
        let server = FakeKeyServer()
        let mac = device(server, "Leo's Mac")
        try await signIn(mac)
        #expect(await waitUntil { mac.vaultEntries != nil && mac.keyStatus == .available })
        let stale = try server.listResult(for: "Leo's Mac")
        try await mac.rotateKey()
        let rotated = try #require(server.keyId)
        #expect(rotated != stale.keyId && mac.serverKeyID == rotated)

        try await mac.operations.run { _ in mac.applyNow(stale) }
        #expect(mac.serverKeyID == rotated && mac.keyStatus == .available, "an older list undid the rotation's answer")
        mac.stop()
    }
}

/// Wraps an HTTP poster; once blocked, requests to `path` get no answer (a transport error), including one that was
/// already on its way when it was blocked.
final class PathBlocker: HTTPPoster, @unchecked Sendable {
    private let inner: any HTTPPoster
    private let path: String
    private let blocked = LockedBox(false)

    init(_ inner: any HTTPPoster, path: String) {
        self.inner = inner
        self.path = path
    }

    func block() { blocked.value = true }

    func post(_ url: URL, body: Data, headers: [String: String]) async throws -> (body: Data, status: Int) {
        let matches = (try? ConvexValue.parse(body))?["path"]?.stringValue == path
        if matches, blocked.value { throw URLError(.timedOut) }
        let response = try await inner.post(url, body: body, headers: headers)
        if matches, blocked.value { throw URLError(.timedOut) }
        return response
    }
}

/// Wraps an HTTP poster and notes, once armed, when an answer to `path` with something in it has been handed back.
final class ResultTap: HTTPPoster, @unchecked Sendable {
    private let inner: any HTTPPoster
    private let path: String
    private let lock = NSLock()
    private var armed = false
    private var _answered = false

    init(_ inner: any HTTPPoster, path: String) {
        self.inner = inner
        self.path = path
    }

    var answered: Bool { lock.withLock { _answered } }
    func arm() { lock.withLock { armed = true } }

    func post(_ url: URL, body: Data, headers: [String: String]) async throws -> (body: Data, status: Int) {
        let response = try await inner.post(url, body: body, headers: headers)
        if (try? ConvexValue.parse(body))?["path"]?.stringValue == path,
           case .array(let rows)? = (try? ConvexValue.parse(response.body))?["value"], !rows.isEmpty {
            lock.withLock { if armed { _answered = true } }
        }
        return response
    }
}
