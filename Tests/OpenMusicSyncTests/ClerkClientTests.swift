import Foundation
import Testing
@testable import OpenMusicSync

/// A scripted Clerk Frontend API. Each route answers JSON and may rotate the client token in `Authorization`.
final class FakeClerk: ClerkHTTP, @unchecked Sendable {
    struct Answer {
        var status = 200
        var json: [String: Any]
        var authorization: String?
    }

    private let lock = NSLock()
    private var routes: [String: (URLRequest) -> Answer] = [:]
    private var _requests: [URLRequest] = []
    private var holds: [String: AsyncGate] = [:]
    var requests: [URLRequest] { lock.withLock { _requests } }

    /// Holds requests to `route` until the gate opens (an answer still on its way).
    func hold(_ route: String, _ gate: AsyncGate) { lock.withLock { holds[route] = gate } }

    /// `"POST /v1/client/sign_ins"` → answer.
    func on(_ route: String, _ answer: @escaping (URLRequest) -> Answer) { lock.withLock { routes[route] = answer } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
        let (handler, gate) = lock.withLock { () -> (((URLRequest) -> Answer)?, AsyncGate?) in
            _requests.append(request)
            return (routes[key], holds[key])
        }
        if let gate { await gate.wait() }
        let answer = handler?(request) ?? Answer(status: 404, json: ["errors": [["code": "resource_not_found", "message": "not found"]]])
        var headers = ["Content-Type": "application/json"]
        if let auth = answer.authorization { headers["Authorization"] = auth }
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (try JSONSerialization.data(withJSONObject: answer.json), response)
    }

    func form(_ request: URLRequest) -> [String: String] {
        let text = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        var out: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if parts.count == 2 { out[parts[0]] = parts[1] }
        }
        return out
    }
}

/// Opens once; everyone waiting goes on.
actor AsyncGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// An HTTP poster that is offline until told otherwise, then answers `config:get` with `key`.
final class FlakyPoster: HTTPPoster, @unchecked Sendable {
    private let lock = NSLock()
    private var _online = false
    private var _calls = 0
    let key: String
    init(key: String = testPublishableKey) { self.key = key }
    var online: Bool {
        get { lock.withLock { _online } }
        set { lock.withLock { _online = newValue } }
    }
    var calls: Int { lock.withLock { _calls } }
    func post(_ url: URL, body: Data, headers: [String: String]) async throws -> (body: Data, status: Int) {
        let online = lock.withLock { _calls += 1; return _online }
        guard online else { throw URLError(.notConnectedToInternet) }
        let value = ConvexValue.object(["status": .string("success"), "value": .object(["auth": .object(["kind": .string("clerk"), "publishableKey": .string(key)])])])
        return (value.jsonData(), 200)
    }
}

/// `pk_test_` + base64("<host>$").
func publishableKey(_ host: String) -> String { "pk_test_" + Data("\(host)$".utf8).base64EncodedString() }

final class MemoryClerkStore: ClerkStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: ClerkState?
    init(_ state: ClerkState? = nil) { self.state = state }
    func load() -> ClerkState? { lock.withLock { state } }
    func save(_ state: ClerkState?) { lock.withLock { self.state = state } }
}

/// `pk_test_` + base64("clerk.openmusic.test$").
let testPublishableKey = "pk_test_" + Data("clerk.openmusic.test$".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")

func clientJSON(session: String = "sess_1", user: String = "user_1", email: String = "leo@example.com") -> [String: Any] {
    [
        "object": "client", "id": "client_1", "last_active_session_id": session,
        "sessions": [[
            "id": session, "status": "active",
            "user": [
                "id": user, "first_name": "Leo", "last_name": NSNull(), "primary_email_address_id": "idn_1",
                "email_addresses": [["id": "idn_1", "email_address": email]], "image_url": "https://img.clerk.com/x.png",
            ] as [String: Any],
        ] as [String: Any]],
    ]
}

@Suite(.serialized) struct ClerkClientTests {
    @Test func thePublishableKeyNamesTheFrontendAPI() {
        #expect(ClerkPublishableKey.frontendAPI(testPublishableKey) == URL(string: "https://clerk.openmusic.test"))
        let live = "pk_live_" + Data("clerk.openmusic.app$".utf8).base64EncodedString()
        #expect(ClerkPublishableKey.frontendAPI(live)?.host == "clerk.openmusic.app")
        #expect(ClerkPublishableKey.frontendAPI("sk_test_abc") == nil)
        #expect(ClerkPublishableKey.frontendAPI("pk_test_" + Data("no-dollar".utf8).base64EncodedString()) == nil)
        #expect(ClerkPublishableKey.frontendAPI("pk_test_" + Data("evil.com/path$".utf8).base64EncodedString()) == nil)
    }

    @Test func onlyPlausiblePublicHostsAreAcceptedAsTheFrontendAPI() {
        for host in ["clerk.example.com", "happy-otter-12.clerk.accounts.dev", "clerk.openmusic.app"] {
            #expect(ClerkPublishableKey.frontendAPI(publishableKey(host)) == URL(string: "https://\(host)"), "\(host)")
        }
        for host in ["localhost", "clerk.localhost", "printer.local", "192.168.1.10", "10.0.0.1", "[::1]", "clerk.example.com:8443",
                     "Clerk.Example.com", "user@clerk.example.com", "clerk.example.com/v1", "clerk.example.com?x=1", "-clerk.example.com",
                     "clerk..example.com", "nodots", "clerk.example.com.", "clerk example.com", "clérk.example.com", ""] {
            #expect(ClerkPublishableKey.frontendAPI(publishableKey(host)) == nil, "\(host)")
        }
    }

    /// A compromised or replaced server that starts handing out another Clerk app's key must not receive the saved
    /// client token at its host: the state belongs to the Frontend API it was created with.
    @Test func aSavedSignInIsNeverSentToAnotherFrontendAPI() async throws {
        let saved = ClerkState(frontendAPI: "https://clerk.openmusic.test", clientToken: "client-token-secret", sessionID: "sess_1",
                               user: ClerkUser(id: "user_1"))
        let evil = FakeClerk()
        evil.on("GET /v1/client") { _ in .init(json: ["response": clientJSON()]) }
        evil.on("GET /v1/environment") { _ in .init(json: ["user_settings": ["social": [:] as [String: Any]]]) }
        let store = MemoryClerkStore(saved)
        let clerk = try ClerkClient(publishableKey: publishableKey("clerk.attacker.example"), http: evil, store: store)
        #expect(clerk.discardedStateForOtherOrigin)
        #expect(store.load() == nil)
        #expect(await clerk.savedUser == nil)
        #expect(try await clerk.restore() == nil)
        #expect(try await clerk.token(forceRefresh: true) == nil)
        _ = try await clerk.socialProviders()
        #expect(evil.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })

        // Its own origin keeps it; state from before origins were recorded is dropped the same way.
        let mine = MemoryClerkStore(saved)
        let same = try ClerkClient(publishableKey: testPublishableKey, http: FakeClerk(), store: mine)
        #expect(!same.discardedStateForOtherOrigin && mine.load() == saved)
        let legacy = MemoryClerkStore(ClerkState(clientToken: "old", sessionID: "sess_1"))
        #expect(try ClerkClient(publishableKey: testPublishableKey, http: FakeClerk(), store: legacy).discardedStateForOtherOrigin)
        #expect(legacy.load() == nil)
    }

    /// The actor is reentrant: a restore that started before Sign Out and answers after it must not bring the
    /// session (or the rotated client token) back.
    @Test func aSignOutWinsOverARestoreStillInFlight() async throws {
        let fake = FakeClerk()
        let gate = AsyncGate()
        fake.hold("GET /v1/client", gate)
        fake.on("GET /v1/client") { _ in .init(json: ["response": clientJSON()], authorization: "rotated-after-sign-out") }
        fake.on("POST /v1/client/sessions/sess_1/remove") { _ in .init(json: ["response": ["id": "sess_1"]], authorization: "also-rotated") }
        let store = MemoryClerkStore(ClerkState(frontendAPI: "https://clerk.openmusic.test", clientToken: "c0", sessionID: "sess_1",
                                                user: ClerkUser(id: "user_1")))
        let clerk = try ClerkClient(publishableKey: testPublishableKey, http: fake, store: store)
        let restore = Task { try await clerk.restore() }
        #expect(await eventually { fake.requests.contains { $0.url?.path == "/v1/client" } })
        await clerk.signOut()
        // The sign-out carried the token it had.
        let remove = try #require(fake.requests.first { $0.url?.path == "/v1/client/sessions/sess_1/remove" })
        #expect(remove.value(forHTTPHeaderField: "Authorization") == "c0")
        await gate.release()
        let restored = try? await restore.value
        #expect(restored == nil)
        #expect(store.load() == ClerkState(frontendAPI: "https://clerk.openmusic.test"))
        #expect(await clerk.savedUser == nil)
        #expect(try await clerk.token(forceRefresh: false) == nil)
    }

    @Test func emailCodeSignInInNativeMode() async throws {
        let fake = FakeClerk()
        fake.on("POST /v1/client/sign_ins") { _ in
            .init(json: ["response": ["id": "sia_1", "status": "needs_first_factor",
                                      "supported_first_factors": [["strategy": "email_code", "email_address_id": "idn_1"]]]],
                  authorization: "client-jwt-1")
        }
        fake.on("POST /v1/client/sign_ins/sia_1/prepare_first_factor") { _ in .init(json: ["response": ["id": "sia_1"]], authorization: "client-jwt-2") }
        fake.on("POST /v1/client/sign_ins/sia_1/attempt_first_factor") { request in
            fake.form(request)["code"] == "123456"
                ? .init(json: ["response": ["id": "sia_1", "status": "complete", "created_session_id": "sess_1"]])
                : .init(status: 422, json: ["errors": [["code": "form_code_incorrect", "message": "Incorrect code", "long_message": "Incorrect code"]]])
        }
        fake.on("POST /v1/client/sessions/sess_1/touch") { _ in .init(json: ["response": [:] as [String: Any], "client": clientJSON()]) }
        let store = MemoryClerkStore()
        let clerk = try ClerkClient(publishableKey: testPublishableKey, http: fake, store: store)

        let challenge = try await clerk.startEmail("  leo@example.com ")
        #expect(challenge == ClerkEmailChallenge(kind: .signIn, attemptID: "sia_1", email: "leo@example.com"))
        await #expect(throws: ClerkError.refused(code: "form_code_incorrect", message: "Incorrect code")) {
            try await clerk.verifyEmail(challenge, code: "000000")
        }
        let user = try await clerk.verifyEmail(challenge, code: "123 456").user
        #expect(user == ClerkUser(id: "user_1", firstName: "Leo", email: "leo@example.com", imageURL: URL(string: "https://img.clerk.com/x.png")))
        #expect(user.displayName == "Leo")
        #expect(store.load()?.sessionID == "sess_1" && store.load()?.user?.id == "user_1")

        let requests = fake.requests
        // Native mode: every request says so, sends no Origin, and carries the newest client token.
        #expect(requests.allSatisfy { $0.url?.query?.contains("_is_native=true") == true })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Origin") == nil })
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "client-jwt-1")
        #expect(requests[2].value(forHTTPHeaderField: "Authorization") == "client-jwt-2")
        #expect(fake.form(requests[0]) == ["identifier": "leo@example.com"])
        #expect(fake.form(requests[1]) == ["strategy": "email_code", "email_address_id": "idn_1"])
        #expect(store.load()?.clientToken == "client-jwt-2")
        #expect(!"\(store.load()!)".contains("client-jwt"))
    }

    @Test func anUnknownEmailSignsUpWithTheSameTwoSteps() async throws {
        let fake = FakeClerk()
        fake.on("POST /v1/client/sign_ins") { _ in
            .init(status: 422, json: ["errors": [["code": "form_identifier_not_found", "message": "Couldn't find your account."]]])
        }
        fake.on("POST /v1/client/sign_ups") { request in
            #expect(fake.form(request) == ["email_address": "new@example.com"])
            return .init(json: ["response": ["id": "sua_1", "status": "missing_requirements", "unverified_fields": ["email_address"]]])
        }
        fake.on("POST /v1/client/sign_ups/sua_1/prepare_verification") { _ in .init(json: ["response": ["id": "sua_1"]]) }
        fake.on("POST /v1/client/sign_ups/sua_1/attempt_verification") { _ in
            .init(json: ["response": ["id": "sua_1", "status": "complete", "created_session_id": "sess_9"]])
        }
        fake.on("POST /v1/client/sessions/sess_9/touch") { _ in .init(json: ["client": clientJSON(session: "sess_9", user: "user_9")]) }
        let clerk = try ClerkClient(publishableKey: testPublishableKey, http: fake, store: MemoryClerkStore())
        let challenge = try await clerk.startEmail("new@example.com")
        #expect(challenge.kind == .signUp)
        #expect(try await clerk.verifyEmail(challenge, code: "111111").user.id == "user_9")
    }

    @Test func aClerkAppThatAsksForMoreThanEmailIsExplained() async throws {
        let fake = FakeClerk()
        fake.on("POST /v1/client/sign_ins") { _ in .init(status: 422, json: ["errors": [["code": "form_identifier_not_found", "message": "x"]]]) }
        fake.on("POST /v1/client/sign_ups") { _ in .init(json: ["response": ["id": "sua_1", "status": "missing_requirements"]]) }
        fake.on("POST /v1/client/sign_ups/sua_1/prepare_verification") { _ in .init(json: ["response": ["id": "sua_1"]]) }
        fake.on("POST /v1/client/sign_ups/sua_1/attempt_verification") { _ in
            .init(json: ["response": ["id": "sua_1", "status": "missing_requirements", "missing_fields": ["password", "phone_number"]]])
        }
        let clerk = try ClerkClient(publishableKey: testPublishableKey, http: fake, store: MemoryClerkStore())
        let challenge = try await clerk.startEmail("a@b.c")
        await #expect(throws: ClerkError.unsupportedRequirements(["password", "phone number"])) { try await clerk.verifyEmail(challenge, code: "1") }
        // Nothing is filled in for an app that asks for more than a password.
        #expect(!fake.requests.contains { $0.httpMethod == "PATCH" })
    }

    /// Clerk's default (and the hosted development instance's) sign-up requires a password, which only its dashboard
    /// can turn off: the sign-up gets a random one nobody sees, and OpenMusic goes on signing in with codes.
    @Test func aClerkAppThatRequiresOnlyAPasswordGetsARandomOne() async throws {
        let fake = FakeClerk()
        fake.on("POST /v1/client/sign_ins") { _ in .init(status: 422, json: ["errors": [["code": "form_identifier_not_found", "message": "x"]]]) }
        fake.on("POST /v1/client/sign_ups") { _ in
            .init(json: ["response": ["id": "sua_1", "status": "missing_requirements", "missing_fields": ["password"], "unverified_fields": ["email_address"]]])
        }
        fake.on("POST /v1/client/sign_ups/sua_1/prepare_verification") { _ in .init(json: ["response": ["id": "sua_1"]]) }
        fake.on("POST /v1/client/sign_ups/sua_1/attempt_verification") { _ in
            .init(json: ["response": ["id": "sua_1", "status": "missing_requirements", "missing_fields": ["password"], "unverified_fields": []]])
        }
        let passwords = LockedBox<[String]>([])
        fake.on("PATCH /v1/client/sign_ups/sua_1") { request in
            passwords.value.append(fake.form(request)["password"] ?? "")
            return .init(json: ["response": ["id": "sua_1", "status": "complete", "created_session_id": "sess_9"]])
        }
        fake.on("POST /v1/client/sessions/sess_9/touch") { _ in .init(json: ["client": clientJSON(session: "sess_9", user: "user_9")]) }
        let store = MemoryClerkStore()
        let clerk = try ClerkClient(publishableKey: testPublishableKey, http: fake, store: store)
        let challenge = try await clerk.startEmail("new@example.com")
        #expect(try await clerk.verifyEmail(challenge, code: "424242").user.id == "user_9")
        let sent = passwords.value
        #expect(sent.count == 1)
        #expect(sent[0].count == 43)
        #expect(sent[0] != ClerkClient.unusedPassword())
        // Never kept: not in the saved state.
        #expect(!"\(store.load()!)".contains(sent[0]))
    }

    @Test func convexTokensAreCachedUntilNearExpiryAndAnEndedSessionSignsOut() async throws {
        let fake = FakeClerk()
        let count = Box(0)
        fake.on("POST /v1/client/sessions/sess_1/tokens/convex") { _ in
            count.value += 1
            return .init(json: ["object": "token", "jwt": jwt("t\(count.value)", lifetime: 60)])
        }
        let ended = Box<ClerkSessionEnd?>(nil)
        let clerk = try ClerkClient(publishableKey: testPublishableKey, http: fake,
                                    store: MemoryClerkStore(ClerkState(frontendAPI: "https://clerk.openmusic.test", clientToken: "c", sessionID: "sess_1", user: ClerkUser(id: "user_1"))))
        await clerk.setOnSessionEnded { ended.value = $0 }
        #expect(await clerk.savedUser?.id == "user_1")
        #expect(try await clerk.token(forceRefresh: false) == jwt("t1", lifetime: 60))
        #expect(try await clerk.token(forceRefresh: false) == jwt("t1", lifetime: 60), "cached")
        #expect(try await clerk.token(forceRefresh: true) == jwt("t2", lifetime: 60))

        fake.on("POST /v1/client/sessions/sess_1/tokens/convex") { _ in
            .init(status: 401, json: ["errors": [["code": "signed_out", "message": "Signed out"]]])
        }
        #expect(try await clerk.token(forceRefresh: true) == nil)
        #expect(ended.value == ClerkSessionEnd(sessionID: "sess_1", userID: "user_1"), "the notice names the session that ended")
        #expect(await clerk.savedUser == nil)
        #expect(try await clerk.token(forceRefresh: false) == nil)
    }

    @Test func aServerErrorIsRetryableNotASignOut() async throws {
        let fake = FakeClerk()
        fake.on("POST /v1/client/sessions/sess_1/tokens/convex") { _ in .init(status: 503, json: [:]) }
        let clerk = try ClerkClient(publishableKey: testPublishableKey, http: fake, store: MemoryClerkStore(ClerkState(frontendAPI: "https://clerk.openmusic.test", sessionID: "sess_1", user: ClerkUser(id: "u"))))
        await #expect(throws: ClerkError.self) { try await clerk.token(forceRefresh: true) }
        #expect(await clerk.savedUser?.id == "u")
    }

    @Test func socialSignInForAnExistingAndANewUser() async throws {
        let fake = FakeClerk()
        fake.on("POST /v1/client/sign_ins") { request in
            #expect(fake.form(request) == ["strategy": "oauth_google", "redirect_url": "openmusic://oauth-callback"])
            return .init(json: ["response": ["id": "sia_2", "status": "needs_first_factor",
                                             "first_factor_verification": ["status": "unverified",
                                                                           "external_verification_redirect_url": "https://accounts.google.com/o/oauth2?x=1"]]])
        }
        fake.on("GET /v1/client/sign_ins/sia_2") { request in
            if request.url?.query?.contains("rotating_token_nonce=n1") == true {
                return .init(json: ["response": ["id": "sia_2", "status": "complete", "created_session_id": "sess_1"]])
            }
            return .init(json: ["response": ["id": "sia_2", "status": "needs_identifier", "first_factor_verification": ["status": "transferable"]]])
        }
        fake.on("POST /v1/client/sign_ups") { request in
            #expect(fake.form(request) == ["transfer": "true"])
            return .init(json: ["response": ["id": "sua_3", "status": "complete", "created_session_id": "sess_2"]])
        }
        fake.on("POST /v1/client/sessions/sess_1/touch") { _ in .init(json: ["client": clientJSON(session: "sess_1")]) }
        fake.on("POST /v1/client/sessions/sess_2/touch") { _ in .init(json: ["client": clientJSON(session: "sess_2", user: "user_new")]) }
        let clerk = try ClerkClient(publishableKey: testPublishableKey, http: fake, store: MemoryClerkStore())

        let start = try await clerk.startOAuth(.google)
        #expect(start.url.host == "accounts.google.com")
        let existing = try await clerk.completeOAuth(start, callback: URL(string: "openmusic://oauth-callback?rotating_token_nonce=n1")!)
        #expect(existing.user.id == "user_1")
        let newcomer = try await clerk.completeOAuth(start, callback: URL(string: "openmusic://oauth-callback")!)
        #expect(newcomer.user.id == "user_new")
        await #expect(throws: ClerkError.self) { try await clerk.completeOAuth(start, callback: URL(string: "https://evil.example/oauth-callback")!) }
    }

    @Test func environmentListsTheEnabledSocialSignInsAppleFirst() async throws {
        let fake = FakeClerk()
        fake.on("GET /v1/environment") { _ in
            .init(json: ["user_settings": ["social": [
                "oauth_google": ["enabled": true, "authenticatable": true, "strategy": "oauth_google"],
                "oauth_apple": ["enabled": true, "authenticatable": true, "strategy": "oauth_apple"],
                "oauth_github": ["enabled": false, "authenticatable": true, "strategy": "oauth_github"],
            ]]])
        }
        let clerk = try ClerkClient(publishableKey: testPublishableKey, http: fake, store: MemoryClerkStore())
        #expect(try await clerk.socialProviders().map(\.name) == ["Apple", "Google"])
    }

    @Test func restoreAndSignOut() async throws {
        let fake = FakeClerk()
        fake.on("GET /v1/client") { _ in .init(json: ["response": clientJSON(), "client": NSNull()]) }
        fake.on("POST /v1/client/sessions/sess_1/remove") { _ in .init(json: ["response": ["id": "sess_1", "status": "removed"]]) }
        let store = MemoryClerkStore(ClerkState(frontendAPI: "https://clerk.openmusic.test", clientToken: "c", sessionID: "sess_1"))
        let clerk = try ClerkClient(publishableKey: testPublishableKey, http: fake, store: store)
        #expect(try await clerk.restore()?.user.email == "leo@example.com")
        await clerk.signOut()
        #expect(fake.requests.last?.url?.path == "/v1/client/sessions/sess_1/remove")
        #expect(store.load() == ClerkState(frontendAPI: "https://clerk.openmusic.test"))
        #expect(try await clerk.token(forceRefresh: false) == nil)
    }
}

@MainActor
@Suite(.serialized) struct AccountServiceTests {
    @Test func serverURLsAreHTTPSOrThisMachine() {
        #expect(SyncServer.parse("happy-otter-123.convex.cloud") == URL(string: "https://happy-otter-123.convex.cloud"))
        #expect(SyncServer.parse(" https://sync.example.com/ ") == URL(string: "https://sync.example.com"))
        #expect(SyncServer.parse("http://localhost:3210") == URL(string: "http://localhost:3210"))
        #expect(SyncServer.parse("http://sync.example.com") == nil)
        #expect(SyncServer.parse("https://user:pw@sync.example.com") == nil)
        #expect(SyncServer.parse("ftp://sync.example.com") == nil)
        #expect(SyncServer.parse("") == nil)
    }

    /// Self-hosted servers: https on any host and port; http only to this machine and the local network (what the
    /// apps' ATS allows); Tailscale over http refused with its own reason; never a path.
    @Test func selfHostedServerURLs() {
        // https anywhere, with a port, a Tailscale Serve name or an IP.
        #expect(SyncServer.parse("https://sync-box.tail1234.ts.net:3443") == URL(string: "https://sync-box.tail1234.ts.net:3443"))
        #expect(SyncServer.parse("sync.example.com:8443") == URL(string: "https://sync.example.com:8443"))
        #expect(SyncServer.parse("https://203.0.113.7:3210") == URL(string: "https://203.0.113.7:3210"))
        #expect(SyncServer.parse("https://100.101.102.103:3443") == URL(string: "https://100.101.102.103:3443"))
        #expect(SyncServer.parse("HTTPS://Sync.Example.com/") == URL(string: "https://Sync.Example.com"))
        // http: this machine, private networks, link-local, unique-local, .local.
        for ok in ["http://localhost:3210", "http://127.0.0.1:3210", "http://[::1]:3210", "http://10.0.0.5:3210",
                   "http://172.20.1.2:3210", "http://192.168.1.20:3210", "http://169.254.3.4", "http://[fd12:3456::1]:3210",
                   "http://[fe80::1]:3210", "http://[::ffff:192.168.1.2]:3210", "http://nas.local:3210"] {
            #expect(SyncServer.parse(ok) != nil, "\(ok)")
        }
        #expect(SyncServer.parse("http://192.168.1.20:3210") == URL(string: "http://192.168.1.20:3210"))
        // Tailscale over http: ATS blocks it (not the local network), so it is refused up front, pointing at https.
        for tailnet in ["http://100.101.102.103:3210", "http://100.64.0.1", "http://100.127.255.255",
                        "http://[fd7a:115c:a1e0::1529:c039]:3210", "http://[::ffff:100.100.1.1]"] {
            #expect(throws: AccountService.ServerError.tailnetHTTP, "\(tailnet)") { try SyncServer.validate(tailnet) }
        }
        // http elsewhere is refused with the reason, as are public look-alikes of private ranges and names that only
        // happen to resolve to a private address today.
        for bad in ["http://sync.example.com:3210", "http://8.8.8.8", "http://100.128.0.1", "http://100.63.255.255",
                    "http://172.32.0.1", "http://192.169.1.1", "http://[2001:db8::1]", "http://sync-box.tail1234.ts.net:3210",
                    "http://localhost.example.com", "http://10.0.0.5.nip.io", "http://[::ffff:8.8.8.8]"] {
            #expect(throws: AccountService.ServerError.self, "\(bad)") { try SyncServer.validate(bad) }
            #expect(SyncServer.parse(bad) == nil, "\(bad)")
        }
        #expect(throws: AccountService.ServerError.insecure(host: "sync.example.com")) { try SyncServer.validate("http://sync.example.com:3210") }
        #expect(throws: AccountService.ServerError.insecure(host: "100.128.0.1")) { try SyncServer.validate("http://100.128.0.1") }
        // Leading zeros: the resolver reads them as octal (010.8.8.8 is the public 8.8.8.8), so they are names, never
        // the private address they look like. Other shorthand forms are names too.
        for ambiguous in ["http://010.8.8.8:3210", "http://192.168.001.010:3210", "http://0127.0.0.1", "http://127.1",
                          "http://0x7f.0.0.1", "http://2130706433"] {
            #expect(throws: AccountService.ServerError.insecure(host: String(ambiguous.dropFirst(7).split(separator: ":")[0])), "\(ambiguous)") {
                try SyncServer.validate(ambiguous)
            }
        }
        #expect(SyncServer.parse("http://10.0.0.0:3210") != nil, "a lone 0 octet is fine")
        // Ports outside 1–65535 are refused.
        #expect(throws: AccountService.ServerError.invalidURL) { try SyncServer.validate("https://example.com:65536") }
        #expect(throws: AccountService.ServerError.invalidURL) { try SyncServer.validate("https://example.com:0") }
        #expect(SyncServer.parse("https://example.com:65535") != nil)
        // The client builds its own paths from the origin, so a path would be dropped on the socket: refuse it.
        #expect(throws: AccountService.ServerError.hasPath) { try SyncServer.validate("https://sync.example.com/openmusic") }
        #expect(throws: AccountService.ServerError.hasPath) { try SyncServer.validate("https://sync.example.com/?a=1") }
        #expect(throws: AccountService.ServerError.hasPath) { try SyncServer.validate("https://sync.example.com/#x") }
        #expect(throws: AccountService.ServerError.invalidURL) { try SyncServer.validate("   ") }
        #expect(throws: AccountService.ServerError.invalidURL) { try SyncServer.validate("ws://sync.example.com") }
        // Every refusal explains itself.
        for error in [AccountService.ServerError.invalidURL, .hasPath, .insecure(host: "h"), .tailnetHTTP, .blockedHTTP] {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    @Test func theServerLineNamesTheHostAndPort() {
        #expect(SyncServer.custom(URL(string: "https://sync-box.tail1234.ts.net:3443")!).displayName == "sync-box.tail1234.ts.net:3443")
        #expect(SyncServer.custom(URL(string: "https://mine.convex.cloud")!).displayName == "mine.convex.cloud")
        #expect(SyncServer.custom(URL(string: "http://[fd7a:115c:a1e0::1]:3210")!).displayName == "[fd7a:115c:a1e0::1]:3210")
        #expect(SyncServer.custom(URL(string: "http://100.101.102.103:3210")!).displayName == "100.101.102.103:3210")
    }

    @Test func checkServerExplainsARefusedAddressBeforeAskingIt() async {
        let http = FakeHTTP()
        http.respond = { _, _ in Issue.record("a refused address must not be asked"); return .null }
        let account = AccountService(hostedURL: URL(string: "https://hosted.convex.cloud")!, store: MemoryClerkStore(),
                                     defaults: UserDefaults(suiteName: "openmusic-tests-\(UUID().uuidString)")!, http: http, clerkHTTP: FakeClerk())
        await #expect(throws: AccountService.ServerError.insecure(host: "sync.example.com")) { try await account.checkServer("http://sync.example.com") }
        await #expect(throws: AccountService.ServerError.hasPath) { try await account.checkServer("https://sync.example.com/openmusic") }
        await #expect(throws: AccountService.ServerError.tailnetHTTP) { try await account.checkServer("http://100.101.102.103:3210") }
        #expect(http.requests.isEmpty)
    }

    @Test func aRefusalByAppTransportSecuritySaysWhatToDo() async {
        let http = FakeHTTP()
        http.handle = { _, _, _ in throw URLError(.appTransportSecurityRequiresSecureConnection) }
        await #expect(throws: AccountService.ServerError.blockedHTTP) {
            try await AccountService.fetchPublishableKey(server: URL(string: "http://10.1.2.3:3210")!, http: http)
        }
        http.handle = { _, _, _ in throw URLError(.cannotConnectToHost) }
        await #expect(throws: AccountService.ServerError.self) {
            try await AccountService.fetchPublishableKey(server: URL(string: "http://10.1.2.3:3210")!, http: http)
        }
    }

    @Test func checkServerAcceptsAPortAndPlainHTTPOnTheLocalNetwork() async throws {
        let http = FakeHTTP()
        http.respond = { _, _ in .object(["status": .string("success"), "value": .object(["auth": .object(["kind": .string("clerk"), "publishableKey": .string(testPublishableKey)])])]) }
        let account = AccountService(hostedURL: URL(string: "https://hosted.convex.cloud")!, store: MemoryClerkStore(),
                                     defaults: UserDefaults(suiteName: "openmusic-tests-\(UUID().uuidString)")!, http: http, clerkHTTP: FakeClerk())
        #expect(try await account.checkServer("http://192.168.1.20:3210") == URL(string: "http://192.168.1.20:3210"))
        #expect(http.urls.last == URL(string: "http://192.168.1.20:3210/api/query"))
        #expect(try await account.checkServer("https://sync-box.tail1234.ts.net:3443/") == URL(string: "https://sync-box.tail1234.ts.net:3443"))
        #expect(http.urls.last == URL(string: "https://sync-box.tail1234.ts.net:3443/api/query"))
        // The socket keeps the port and picks ws for http, wss for https.
        #expect(ConvexClient(deploymentURL: URL(string: "http://192.168.1.20:3210")!).syncURL.absoluteString == "ws://192.168.1.20:3210/api/\(ConvexClient.protocolVersion)/sync")
        #expect(ConvexClient(deploymentURL: URL(string: "https://sync-box.tail1234.ts.net:3443")!).syncURL.absoluteString == "wss://sync-box.tail1234.ts.net:3443/api/\(ConvexClient.protocolVersion)/sync")
    }

    @Test func theServerSaysWhichClerkAppToUse() async throws {
        let http = FakeHTTP()
        http.respond = { path, body in
            #expect(path == "/api/query" && body["path"] == .string("config:get"))
            return .object(["status": .string("success"), "value": .object(["auth": .object(["kind": .string("clerk"), "publishableKey": .string(testPublishableKey)])])])
        }
        #expect(try await AccountService.fetchPublishableKey(server: URL(string: "https://x.convex.cloud")!, http: http) == testPublishableKey)
        #expect(http.requests.first?.headers["Authorization"] == nil, "no sign-in needed")

        http.respond = { _, _ in .object(["status": .string("success"), "value": .object(["auth": .object(["kind": .string("notConfigured")])])]) }
        await #expect(throws: ClerkError.notConfigured) { try await AccountService.fetchPublishableKey(server: URL(string: "https://x.convex.cloud")!, http: http) }
        http.respond = { _, _ in .object(["status": .string("error"), "errorMessage": .string("Could not find public function for 'config:get'")]) }
        await #expect(throws: AccountService.ServerError.notOpenMusic) {
            try await AccountService.fetchPublishableKey(server: URL(string: "https://x.convex.cloud")!, http: http)
        }
    }

    @Test func aCustomServerIsSavedPerDeviceAndTheHostedOneIsTheDefault() async throws {
        let defaults = try #require(UserDefaults(suiteName: "openmusic-tests-\(UUID().uuidString)"))
        let hosted = URL(string: "https://hosted.convex.cloud")!
        let http = FakeHTTP()
        http.respond = { _, _ in .object(["status": .string("success"), "value": .object(["auth": .object(["kind": .string("clerk"), "publishableKey": .string(testPublishableKey)])])]) }
        let account = AccountService(hostedURL: hosted, store: MemoryClerkStore(), defaults: defaults, http: http, clerkHTTP: FakeClerk())
        #expect(account.server == .hosted(hosted))
        let custom = try await account.checkServer("mine.convex.cloud")
        await account.setServer(custom)
        #expect(account.server == .custom(URL(string: "https://mine.convex.cloud")!))
        #expect(SyncServer.current(hosted: hosted, defaults: defaults).isCustom)
        #expect(account.state == .signedOut && account.serverProblem == nil)
        await account.setServer(nil)
        #expect(account.server == .hosted(hosted))
    }

    @Test func aSavedSignInCountsAtLaunchEvenOffline() async throws {
        let http = FakeHTTP()
        http.respond = { _, _ in .object(["status": .string("success"), "value": .object(["auth": .object(["kind": .string("clerk"), "publishableKey": .string(testPublishableKey)])])]) }
        let store = MemoryClerkStore(ClerkState(frontendAPI: "https://clerk.openmusic.test", clientToken: "c", sessionID: "sess_1",
                                                user: ClerkUser(id: "user_1", email: "leo@example.com")))
        let defaults = try #require(UserDefaults(suiteName: "openmusic-tests-\(UUID().uuidString)"))
        let account = AccountService(hostedURL: URL(string: "https://hosted.convex.cloud")!, store: store, defaults: defaults, http: http, clerkHTTP: FakeClerk())
        await account.load()
        #expect(account.user?.id == "user_1")
        #expect(account.tokenProvider != nil)
    }

    @Test func aServerThatStartsNamingAnotherClerkHostSignsOutWithANotice() async throws {
        let store = MemoryClerkStore(ClerkState(frontendAPI: "https://clerk.openmusic.test", clientToken: "secret", sessionID: "sess_1",
                                                user: ClerkUser(id: "user_1", email: "leo@example.com")))
        let defaults = try #require(UserDefaults(suiteName: "openmusic-tests-\(UUID().uuidString)"))
        let poster = FlakyPoster(key: publishableKey("clerk.attacker.example"))
        poster.online = true
        let clerkHTTP = FakeClerk()
        let account = AccountService(hostedURL: URL(string: "https://hosted.convex.cloud")!, store: store, defaults: defaults, http: poster, clerkHTTP: clerkHTTP)
        account.watchesNetwork = false
        let ended = Box(false)
        account.onSessionEnded = { ended.value = true }
        await account.load()
        #expect(account.state == .signedOut)
        #expect(ended.value)
        #expect(account.notice?.contains("clerk.attacker.example") == true)
        #expect(store.load() == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(clerkHTTP.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    /// Offline at launch: the saved sign-in still shows, the configuration is tried again by itself with backoff,
    /// and once it loads the app is told so it can connect. Sign In works again without a relaunch.
    @Test func anOfflineLaunchRetriesTheServerByItselfAndOnRetry() async throws {
        let store = MemoryClerkStore(ClerkState(frontendAPI: "https://clerk.openmusic.test", clientToken: "c", sessionID: "sess_1",
                                                user: ClerkUser(id: "user_1")))
        let defaults = try #require(UserDefaults(suiteName: "openmusic-tests-\(UUID().uuidString)"))
        let poster = FlakyPoster()
        let account = AccountService(hostedURL: URL(string: "https://hosted.convex.cloud")!, store: store, defaults: defaults, http: poster, clerkHTTP: FakeClerk())
        account.watchesNetwork = false
        account.retryDelays = [.milliseconds(30), .milliseconds(60)]
        let ready = Box(0)
        account.onReady = { ready.value += 1 }
        await account.load()
        #expect(account.user?.id == "user_1" && !account.isReady && account.tokenProvider == nil)
        #expect(account.serverProblem != nil)
        #expect(await waitUntil { poster.calls >= 3 }, "it keeps trying")
        poster.online = true
        #expect(await waitUntil { account.isReady })
        #expect(account.serverProblem == nil && account.tokenProvider != nil && ready.value == 1)

        // The Retry button tries at once instead of waiting for the next automatic try.
        let flaky = FlakyPoster()
        let signedOut = AccountService(hostedURL: URL(string: "https://hosted.convex.cloud")!, store: MemoryClerkStore(), defaults: defaults,
                                       http: flaky, clerkHTTP: FakeClerk())
        signedOut.watchesNetwork = false
        signedOut.retryDelays = [.seconds(600)]
        await signedOut.load()
        #expect(signedOut.state == .signedOut && !signedOut.isReady && signedOut.serverProblem != nil)
        flaky.online = true
        await signedOut.retry()
        #expect(signedOut.isReady && signedOut.serverProblem == nil)
    }
}
