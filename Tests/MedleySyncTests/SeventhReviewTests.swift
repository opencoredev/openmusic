import Foundation
import MedleyCore
import Testing
@testable import MedleySync

/// The cases the seventh review of the accounts design found, each failing on the code before it (a54eabb):
///
/// 1. A device removal recorded nothing, so a delayed copy of its registration could register the token again after
///    the device signed out (or was removed elsewhere, or evicted) and deleted its keys: a row whose token and key no
///    installation has. Now a device token is single-use: every removal retires it, and registration refuses it.
/// 2. The app's sign-out read the user after awaiting Clerk, so a sign-in that finished in that await (another user,
///    or the same one again) was the one sync signed out. Now the snapshot is coherent and checked right before sync
///    signs out, and sync compares the sign-in's generation, not only its user.
@MainActor
@Suite(.serialized) struct SeventhReviewTests {
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

    /// Registers `service` with two copies of the same registration: the first (R1) is sent and parked by the server,
    /// the device hears nothing; the retry (R2) lands, the credentials are saved and the saved registration dropped.
    func registerWithADelayedCopy(_ server: FakeKeyServer, _ service: SyncService, store: MemoryCredentialStore) async throws -> String {
        server.delay("account:register")
        await #expect(throws: (any Error).self) { try await signIn(service) }
        let token = try #require(savedRegistration(store)?.token)
        #expect(server.parked == 1 && server.devices.allSatisfy { $0.token != token })
        try await signIn(service)
        #expect(service.isRegistered && service.credentials?.token == token)
        #expect(savedRegistration(store) == nil && store.load()?.token == token)
        return token
    }

    // MARK: 1. A device token is single-use

    /// The review's sequence: R1 delayed, R2 lands, the device signs out normally (`devices:remove`) and deletes its
    /// keys, then R1 runs. It used to register the token again: a holder row (here the first of a new library) whose
    /// token and key were discarded. Now the removal retired the token and R1 is refused.
    @Test func aLateCopyOfARegistrationNeverRegistersAgainAfterANormalSignOut() async throws {
        let server = FakeKeyServer()
        let store = MemoryCredentialStore()
        let mac = device(server, "Leo's Mac", store: store)
        let token = try await registerWithADelayedCopy(server, mac, store: store)

        await mac.signOut()
        #expect(server.devices.isEmpty && store.load() == nil && mac.pendingRemovals.isEmpty)
        #expect(!server.calls("account:unregister").contains { $0.args["token"]?.stringValue == token })

        server.commitDelayed()
        #expect(server.devices.isEmpty, "the late copy registered a device whose token and key are gone")
        #expect(server.refusal(token, user: "u") == .retired)
        mac.stop()
    }

    /// The same when another device removes it: the late copy doesn't bring the removed device back.
    @Test func aLateCopyOfARegistrationNeverBringsBackADeviceRemovedElsewhere() async throws {
        let server = FakeKeyServer()
        let mac = device(server, "Leo's Mac")
        try await signIn(mac)
        let store = MemoryCredentialStore()
        let phone = device(server, "Leo's iPhone", store: store)
        let token = try await registerWithADelayedCopy(server, phone, store: store)
        let phoneID = try #require(phone.selfID)

        try await mac.remove(phoneID)
        #expect(server.devices.map(\.name) == ["Leo's Mac"])
        server.commitDelayed()
        #expect(!server.devices.contains { $0.token == token }, "the removed device came back")
        #expect(server.devices.map(\.name) == ["Leo's Mac"])
        mac.stop()
        phone.stop()
    }

    /// The same when a full account evicts it: the late copy neither brings it back nor evicts another device.
    @Test func aLateCopyOfARegistrationNeverBringsBackAnEvictedDevice() async throws {
        let server = FakeKeyServer()
        server.setMaxDevices(2)
        let mac = device(server, "Leo's Mac")
        try await signIn(mac)
        let store = MemoryCredentialStore()
        let phone = device(server, "Leo's iPhone", store: store)
        let token = try await registerWithADelayedCopy(server, phone, store: store)
        // The phone goes quiet (its calls no longer reach the server); the Mac is seen after it.
        server.setAway("Leo's iPhone", true)
        phone.stop()
        server.touch("Leo's Mac")

        let pad = device(server, "Leo's iPad")
        try await signIn(pad)
        #expect(Set(server.devices.map(\.name)) == ["Leo's Mac", "Leo's iPad"], "the phone wasn't the one evicted")
        server.commitDelayed()
        #expect(!server.devices.contains { $0.token == token }, "the evicted device came back")
        #expect(Set(server.devices.map(\.name)) == ["Leo's Mac", "Leo's iPad"])
        mac.stop()
        pad.stop()
    }

    // MARK: 2. Sign-out acts on one coherent snapshot of the sign-in

    func makeAccount(clerkHTTP: FakeClerk, clerkStore: MemoryClerkStore) async throws -> AccountService {
        let config = FakeHTTP()
        config.respond = { _, _ in .object(["status": .string("success"), "value": .object(["auth": .object(["kind": .string("clerk"), "publishableKey": .string(testPublishableKey)])])]) }
        let defaults = try #require(UserDefaults(suiteName: "medley-tests-\(UUID().uuidString)"))
        let account = AccountService(hostedURL: url, store: clerkStore, defaults: defaults, http: config, clerkHTTP: clerkHTTP)
        account.watchesNetwork = false
        await account.load()
        try await Task.sleep(for: .milliseconds(100))   // the launch's restore has answered
        return account
    }

    /// A Clerk app where `email` signs in as `user` with session `session`, and user A's session is `sess_a`.
    func clerk(signingIn user: String, email: String, session: String) -> FakeClerk {
        let clerkHTTP = FakeClerk()
        clerkHTTP.on("POST /v1/client/sign_ins") { _ in
            .init(json: ["response": ["id": "sia_1", "status": "needs_first_factor",
                                      "supported_first_factors": [["strategy": "email_code", "email_address_id": "idn_1"]]]])
        }
        clerkHTTP.on("POST /v1/client/sign_ins/sia_1/prepare_first_factor") { _ in .init(json: ["response": ["id": "sia_1"]]) }
        clerkHTTP.on("POST /v1/client/sign_ins/sia_1/attempt_first_factor") { _ in
            .init(json: ["response": ["id": "sia_1", "status": "complete", "created_session_id": session]])
        }
        clerkHTTP.on("POST /v1/client/sessions/\(session)/touch") { _ in
            .init(json: ["response": [:] as [String: Any], "client": clientJSON(session: session, user: user, email: email)])
        }
        clerkHTTP.on("GET /v1/client") { _ in .init(json: ["response": clientJSON(session: "sess_a", user: "user_a")]) }
        clerkHTTP.on("GET /v1/environment") { _ in .init(json: ["user_settings": ["social": [:] as [String: Any]]]) }
        clerkHTTP.on("POST /v1/client/sessions/sess_a/remove") { _ in .init(json: ["response": ["id": "sess_a"]]) }
        clerkHTTP.on("POST /v1/client/sessions/\(session)/remove") { _ in .init(json: ["response": ["id": session]]) }
        return clerkHTTP
    }

    /// While A's sign-out reads the Clerk session (`currentSession()`), B signs in with Clerk and the app connects sync
    /// as B. The sign-out used to read the user after that await, so it asked sync to sign out B and removed B's
    /// device. Now it sees its snapshot is stale before it reaches sync and does nothing: B stays, at Clerk and in sync.
    @Test func aSignInDuringTheSessionCaptureIsNeverSignedOut() async throws {
        let clerkHTTP = clerk(signingIn: "user_b", email: "b@example.com", session: "sess_b")
        let clerkStore = MemoryClerkStore(ClerkState(frontendAPI: "https://clerk.medley.test", clientToken: "client-jwt-a", sessionID: "sess_a",
                                                     user: ClerkUser(id: "user_a", email: "a@example.com")))
        let account = try await makeAccount(clerkHTTP: clerkHTTP, clerkStore: clerkStore)
        #expect(account.user?.id == "user_a")
        let server = FakeKeyServer()
        let mac = device(server, "Leo's Mac")
        try await mac.signIn(auth: FakeTokens([jwt("user_a")]), userID: "user_a", generation: account.sessionGeneration)

        account.willReadClerkSession = { [account] in
            account.willReadClerkSession = nil
            guard let challenge = try? await account.startEmail("b@example.com"),
                  (try? await account.verifyEmail(challenge, code: "123456")) != nil else { return }
            try? await mac.signIn(auth: FakeTokens([jwt("user_b")]), userID: "user_b", generation: account.sessionGeneration)
        }
        await account.signOut(sync: mac)

        #expect(account.user?.id == "user_b" && clerkStore.load()?.sessionID == "sess_b")
        #expect(mac.isRegistered && mac.credentials?.userID == "user_b", "B's sync sign-in was signed out")
        #expect(server.devices(of: "user_b").count == 1)
        #expect(!clerkHTTP.requests.contains { $0.url?.path == "/v1/client/sessions/sess_b/remove" })
        mac.stop()
    }

    /// The same with the same user signing in again: the user id matched, so sync removed the device of the newer
    /// sign-in while Clerk kept it (signed in, not syncing). Now nothing is signed out.
    @Test func theSameUserSigningInDuringTheSessionCaptureIsNeverSignedOut() async throws {
        let clerkHTTP = clerk(signingIn: "user_a", email: "a@example.com", session: "sess_2")
        let clerkStore = MemoryClerkStore(ClerkState(frontendAPI: "https://clerk.medley.test", clientToken: "client-jwt-a", sessionID: "sess_a",
                                                     user: ClerkUser(id: "user_a", email: "a@example.com")))
        let account = try await makeAccount(clerkHTTP: clerkHTTP, clerkStore: clerkStore)
        let server = FakeKeyServer()
        let mac = device(server, "Leo's Mac")
        try await mac.signIn(auth: FakeTokens([jwt("user_a")]), userID: "user_a", generation: account.sessionGeneration)
        let deviceID = try #require(mac.selfID)

        account.willReadClerkSession = { [account] in
            account.willReadClerkSession = nil
            guard let challenge = try? await account.startEmail("a@example.com"),
                  (try? await account.verifyEmail(challenge, code: "123456")) != nil else { return }
            try? await mac.signIn(auth: FakeTokens([jwt("user_a")]), userID: "user_a", generation: account.sessionGeneration)
        }
        await account.signOut(sync: mac)

        #expect(account.user?.id == "user_a" && clerkStore.load()?.sessionID == "sess_2")
        #expect(mac.isRegistered && mac.selfID == deviceID, "the newer sign-in's sync device was removed")
        #expect(server.devices.map(\.id) == [deviceID.rawValue])
        mac.stop()
    }

    /// Sync's own guard: a sign-out for an older sign-in of the same user does nothing once a newer one asked sync to
    /// sign in (and after it ran), while one for the current sign-in signs out.
    @Test func syncSignsOutOnlyForTheSignInItWasAskedFor() async throws {
        let server = FakeKeyServer()
        let mac = device(server, "Leo's Mac")
        try await mac.signIn(auth: FakeTokens([jwt("u")]), userID: "u", generation: 1)
        try await mac.signIn(auth: FakeTokens([jwt("u")]), userID: "u", generation: 2)
        #expect(mac.currentSignIn == SyncSignIn(userID: "u", generation: 2))

        await mac.signOut(ifSignIn: SyncSignIn(userID: "u", generation: 1))
        #expect(mac.isRegistered && server.devices.count == 1, "an older sign-in's sign-out signed the newer one out")
        await mac.signOut(ifSignIn: SyncSignIn(userID: "u", generation: 2))
        #expect(!mac.isRegistered && server.devices.isEmpty)
        mac.stop()
    }
}
