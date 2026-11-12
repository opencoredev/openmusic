import Foundation
import OpenMusicCore
import Testing
@testable import OpenMusicSync

/// The cases the eighth review of the accounts design found, each failing on the code before it (d2c57e1):
///
/// 1. Clerk's notice that a session ended was queued to the main actor without saying which session, and acted on
///    whatever sign-in was current when it ran: delayed past B's sign-in, it ended B and the apps removed B's device.
///    Now it names the session and is ignored unless that is the one shown.
/// 2. A launch's restore moved to another active session on the Clerk client when the saved one was gone, showing
///    that account while sync still spoke for the saved one and the sign-in generation never moved. Now it never
///    switches by itself: it signs out with a notice, and the app signs sync out for the saved sign-in.
/// 3. A saved registration was resent forever, so after a month offline (the server forgets retired tokens after 30
///    days) it could register a token whose device was removed meanwhile. Now a saved registration older than 7 days
///    is never resent: its token is owed as a removal and a new registration takes its place.
/// (The fourth, `cancelledRegistrations.reason` staged as optional with a backfill, is tested in `sync/convex`.)
@MainActor
@Suite(.serialized) struct ClerkSessionEndTests {
    let url = URL(string: "https://example-123.convex.cloud")!

    func device(_ server: FakeKeyServer, _ name: String, store: any SyncCredentialStore = MemoryCredentialStore()) -> SyncService {
        let transport = FakeTransport()
        transport.autoFail = true
        return SyncService(deploymentURL: url, deviceInfo: DeviceInfo(name: name, platform: .ios, model: "t", appVersion: "1"),
                           credentials: store, transport: transport, http: server.http(), options: fastOptions(fallbackAfter: 1))
    }

    /// A Clerk app where user A is saved with session `sess_a`, and `b@example.com` signs in as user B (`sess_b`).
    func clerk(client: [String: Any] = clientJSON(session: "sess_a", user: "user_a")) -> FakeClerk {
        let clerkHTTP = FakeClerk()
        clerkHTTP.on("POST /v1/client/sign_ins") { _ in
            .init(json: ["response": ["id": "sia_1", "status": "needs_first_factor",
                                      "supported_first_factors": [["strategy": "email_code", "email_address_id": "idn_1"]]]])
        }
        clerkHTTP.on("POST /v1/client/sign_ins/sia_1/prepare_first_factor") { _ in .init(json: ["response": ["id": "sia_1"]]) }
        clerkHTTP.on("POST /v1/client/sign_ins/sia_1/attempt_first_factor") { _ in
            .init(json: ["response": ["id": "sia_1", "status": "complete", "created_session_id": "sess_b"]])
        }
        clerkHTTP.on("POST /v1/client/sessions/sess_b/touch") { _ in
            .init(json: ["response": [:] as [String: Any], "client": clientJSON(session: "sess_b", user: "user_b", email: "b@example.com")])
        }
        clerkHTTP.on("GET /v1/client") { _ in .init(json: ["response": client]) }
        clerkHTTP.on("GET /v1/environment") { _ in .init(json: ["user_settings": ["social": [:] as [String: Any]]]) }
        // Clerk ended A's session (signed out elsewhere): its token is refused.
        clerkHTTP.on("POST /v1/client/sessions/sess_a/tokens/convex") { _ in
            .init(status: 401, json: ["errors": [["code": "signed_out", "message": "Signed out"]]])
        }
        return clerkHTTP
    }

    func savedA() -> MemoryClerkStore {
        MemoryClerkStore(ClerkState(frontendAPI: "https://clerk.openmusic.test", clientToken: "client-jwt-a", sessionID: "sess_a",
                                    user: ClerkUser(id: "user_a", email: "a@example.com")))
    }

    func makeAccount(clerkHTTP: FakeClerk, clerkStore: MemoryClerkStore) throws -> AccountService {
        let config = FakeHTTP()
        config.respond = { _, _ in .object(["status": .string("success"), "value": .object(["auth": .object(["kind": .string("clerk"), "publishableKey": .string(testPublishableKey)])])]) }
        let defaults = try #require(UserDefaults(suiteName: "openmusic-tests-\(UUID().uuidString)"))
        let account = AccountService(hostedURL: url, store: clerkStore, defaults: defaults, http: config, clerkHTTP: clerkHTTP)
        account.watchesNetwork = false
        return account
    }

    /// What both apps' hubs do when the account says a session ended: sign sync out for that sign-in only.
    func signSyncOutWhenTheSessionEnds(_ account: AccountService, _ sync: SyncService, ended: Box<[SyncSignIn?]>) {
        account.onSessionEnded = { [account] in
            let signIn = account.endedSignIn
            ended.value.append(signIn)
            Task { await sync.signOut(ifSignIn: signIn) }
        }
    }

    // MARK: 1. A session-ended notice names its session

    /// A's session ends at Clerk (its token is refused) and the notice is queued to the main actor; before it runs, B
    /// signs in and the app connects sync as B. The notice used to build the ended sign-in from what was current then,
    /// B, so the account showed signed out and sync removed B's device. Now it names `sess_a` and is ignored.
    @Test func aLateNoticeThatASessionEndedNeverEndsANewerSignIn() async throws {
        let clerkStore = savedA()
        let clerkHTTP = clerk()
        let account = try makeAccount(clerkHTTP: clerkHTTP, clerkStore: clerkStore)
        await account.load()
        #expect(await waitUntil { account.isReady } && account.user?.id == "user_a")
        let server = FakeKeyServer()
        let mac = device(server, "Leo's Mac")
        try await mac.signIn(auth: FakeTokens([jwt("user_a")]), userID: "user_a", generation: account.sessionGeneration)
        let ended = Box<[SyncSignIn?]>([])
        signSyncOutWhenTheSessionEnds(account, mac, ended: ended)

        let delivered = Box(false)
        account.willDeliverSessionEnd = { [account] in
            account.willDeliverSessionEnd = nil
            if let challenge = try? await account.startEmail("b@example.com"), (try? await account.verifyEmail(challenge, code: "123456")) != nil {
                try? await mac.signIn(auth: FakeTokens([jwt("user_b")]), userID: "user_b", generation: account.sessionGeneration)
            }
            delivered.value = true
        }
        let clerk = try #require(account.clerk)
        #expect(try await clerk.token(forceRefresh: true) == nil)   // A's session is gone: the notice is on its way
        #expect(await waitUntil { delivered.value })
        try await Task.sleep(for: .milliseconds(50))   // let anything the notice started run

        #expect(account.user?.id == "user_b" && account.isSignedIn, "the late notice for A signed B out")
        #expect(ended.value.isEmpty, "the apps were told B's sign-in ended: \(ended.value)")
        #expect(clerkStore.load()?.sessionID == "sess_b")
        #expect(mac.isRegistered && mac.credentials?.userID == "user_b", "B's sync device was removed")
        #expect(server.devices(of: "user_b").count == 1)
        mac.stop()
    }

    /// The notice still ends the sign-in it names when nothing newer happened.
    @Test func aNoticeThatTheShownSessionEndedEndsIt() async throws {
        let account = try makeAccount(clerkHTTP: clerk(), clerkStore: savedA())
        await account.load()
        #expect(await waitUntil { account.isReady })
        let server = FakeKeyServer()
        let mac = device(server, "Leo's Mac")
        try await mac.signIn(auth: FakeTokens([jwt("user_a")]), userID: "user_a", generation: account.sessionGeneration)
        let ended = Box<[SyncSignIn?]>([])
        signSyncOutWhenTheSessionEnds(account, mac, ended: ended)

        #expect(try await account.clerk?.token(forceRefresh: true) == nil)
        #expect(await waitUntil { !account.isSignedIn })
        #expect(ended.value == [SyncSignIn(userID: "user_a", generation: 0)])
        #expect(await waitUntil { !mac.isRegistered })
        #expect(account.notice == nil)
        mac.stop()
    }

    // MARK: 2. A launch never switches to another session by itself

    /// The saved session `sess_a` is gone, but the Clerk client still has B's session active. The launch's restore used
    /// to show B (generation 0, sync still signed in as A, so B's calls would carry A's device token). Now it signs out
    /// with a notice naming B, and the app signs sync out for A's sign-in.
    @Test func aLaunchWhoseSavedSessionIsGoneNeverSwitchesToAnotherOne() async throws {
        let clerkStore = savedA()
        let clerkHTTP = clerk(client: clientJSON(session: "sess_b", user: "user_b", email: "b@example.com"))
        let restoreAnswers = AsyncGate()
        clerkHTTP.hold("GET /v1/client", restoreAnswers)
        let account = try makeAccount(clerkHTTP: clerkHTTP, clerkStore: clerkStore)
        let server = FakeKeyServer()
        let mac = device(server, "Leo's Mac")
        let ended = Box<[SyncSignIn?]>([])
        signSyncOutWhenTheSessionEnds(account, mac, ended: ended)
        // Launch: the saved sign-in shows at once and connects sync, as the hubs do; the restore answers after.
        await account.load()
        #expect(account.user?.id == "user_a")
        try await mac.signIn(auth: FakeTokens([jwt("user_a")]), userID: "user_a", generation: account.sessionGeneration)
        await restoreAnswers.release()

        #expect(await waitUntil { account.state != .signedIn(ClerkUser(id: "user_a", email: "a@example.com")) })
        try await Task.sleep(for: .milliseconds(50))
        #expect(account.user == nil && account.state == .signedOut, "the launch switched to \(String(describing: account.user?.id))")
        #expect(account.notice?.contains("Leo") == true, "no notice: \(String(describing: account.notice))")
        #expect(ended.value == [SyncSignIn(userID: "user_a", generation: 0)])
        #expect(clerkStore.load()?.sessionID == nil)
        #expect(await waitUntil { !mac.isRegistered }, "sync stayed signed in as A")
        #expect(server.devices.isEmpty)

        // The listener signs in again (here as B): a new generation, sync as B.
        let challenge = try await account.startEmail("b@example.com")
        try await account.verifyEmail(challenge, code: "123456")
        #expect(account.user?.id == "user_b" && account.sessionGeneration == 1 && account.notice == nil)
        mac.stop()
    }

    // MARK: 3. A saved registration expires

    /// The phone's registration lands but the answer is lost, so it keeps the registration saved. The Mac removes the
    /// phone (retiring its token), and the phone stays offline for 31 days: the server forgot the retirement. Its next
    /// sign-in used to resend the saved registration and register the removed token again. Now the saved registration
    /// is too old to send: the phone registers with a new token and withdraws the old one.
    @Test func aRegistrationSavedAMonthAgoIsNeverResent() async throws {
        let server = FakeKeyServer()
        let mac = device(server, "Leo's Mac")
        try await mac.signIn(auth: FakeTokens([jwt("u")]), userID: "u")
        let store = MemoryCredentialStore()
        let phone = device(server, "Leo's iPhone", store: store)
        server.loseRegisterAnswer(true)
        await #expect(throws: (any Error).self) { try await phone.signIn(auth: FakeTokens([jwt("u")]), userID: "u") }
        server.loseRegisterAnswer(false)
        let token = try #require(savedRegistration(store)?.token)
        let landed = try #require(server.devices.first { $0.token == token })
        try await mac.remove(DeviceID(rawValue: landed.id))
        #expect(server.refusal(token, user: "u") == .retired)
        phone.stop()

        // A month later, the same installation launches again.
        let month: TimeInterval = 31 * 24 * 3600
        server.advanceTime(month * 1000)
        #expect(server.refusal(token, user: "u") == nil, "the server still remembers the retirement")
        let relaunched = device(server, "Leo's iPhone", store: store)
        relaunched.now = { Date().addingTimeInterval(month) }
        let sentBefore = server.calls("account:register").count
        try await relaunched.signIn(auth: FakeTokens([jwt("u")]), userID: "u")

        let resent = server.calls("account:register").dropFirst(sentBefore).filter { $0.args["token"]?.stringValue == token }
        #expect(resent.isEmpty, "the month-old registration was sent again")
        #expect(!server.devices.contains { $0.token == token }, "the removed device's token registered again")
        #expect(relaunched.isRegistered && relaunched.credentials?.token != token)
        #expect(savedRegistration(store) == nil)
        // The old token is withdrawn (it may have landed) and the removal settled.
        #expect(await waitUntil { relaunched.pendingRemovals.isEmpty })
        #expect(server.calls("account:unregister").contains { $0.args["token"]?.stringValue == token })
        #expect(server.refusal(token, user: "u") == .withdrawn)
        // Every attempt of one registration carries the same creation time.
        let attempts = server.calls("account:register").filter { $0.args["token"]?.stringValue == token }
        #expect(attempts.count >= 1 && Set(attempts.compactMap { $0.args["createdAt"]?.doubleValue }).count == 1)
        mac.stop()
        relaunched.stop()
    }

    /// Inside the limit, a saved registration is still resent as it is (the lost-answer recovery).
    @Test func aRegistrationSavedRecentlyIsStillResent() async throws {
        let server = FakeKeyServer()
        let store = MemoryCredentialStore()
        let phone = device(server, "Leo's iPhone", store: store)
        server.loseRegisterAnswer(true)
        await #expect(throws: (any Error).self) { try await phone.signIn(auth: FakeTokens([jwt("u")]), userID: "u") }
        server.loseRegisterAnswer(false)
        let token = try #require(savedRegistration(store)?.token)
        phone.stop()
        let relaunched = device(server, "Leo's iPhone", store: store)
        relaunched.now = { Date().addingTimeInterval(6 * 24 * 3600) }
        try await relaunched.signIn(auth: FakeTokens([jwt("u")]), userID: "u")
        #expect(relaunched.credentials?.token == token && server.devices.map(\.token) == [token])
        #expect(relaunched.pendingRemovals.isEmpty)
        relaunched.stop()
    }
}
