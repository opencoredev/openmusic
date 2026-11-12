import Foundation
import OpenMusicCore
import Testing
@testable import OpenMusicSync

/// Randomized interleavings of account and key operations against the fake server, one run per seed: sign-ins as two
/// users (their token sometimes can't be fetched at first), sign-outs, relaunches, device lists delivered late and out
/// of order, forced rotations with lost answers, lost registration answers, requests that are sent but commit later
/// (registrations, claims, withdrawals, rotations, removals), devices dropping off the network, approvals and Ask
/// Again, all started without waiting for each other. After every run (and during it, for the server-side check)
/// these hold:
///
/// 1. The vault key is never reset while a device left on the account could still reach it (it knows the key, or a
///    rotated key waiting for it was made from a key it knows): no recoverable vault is cleared.
/// 2. No call ever carries a token whose subject differs from its scope: a call with a device's token goes out only
///    with a JWT of the user that device token was made for.
/// 3. No newer session is erased by an older operation: a device whose last request was a sign-in that succeeded is
///    signed in as that user at the end, and one whose last request was a sign-out is signed out.
/// 4. No recovery material is lost on a stale observation: applying a list older than this device's own rotation or
///    claim never deletes the saved key, and a device list never touches the saved registration or removals.
/// 5. No orphan: every device row on the server belongs to a token some installation still has (its credentials, its
///    saved registration, or a removal it owes), and a holder row's installation still has that holder's key.
@MainActor
@Suite(.serialized) struct InterleavingTests {
    nonisolated static let seeds = Array(1...40)
    nonisolated static let steps = 30
    let url = URL(string: "https://example-123.convex.cloud")!

    /// One installation of the app: its Keychain outlives a relaunch; each launch gets its own wrappers, which a
    /// relaunch kills (the old process writes and sends nothing more).
    final class Slot {
        let name: String
        let store = MemoryCredentialStore()
        var launch: Launch
        init(name: String, launch: Launch) {
            self.name = name
            self.launch = launch
        }
    }

    final class Launch: @unchecked Sendable {
        let store: LaunchStore
        let http: LaunchHTTP
        init(_ inner: MemoryCredentialStore, audit: IdentityAudit) {
            store = LaunchStore(inner, audit: audit)
            http = LaunchHTTP(audit)
        }
        func kill() {
            store.dead.value = true
            http.dead.value = true
        }
    }

    func launch(_ slot: Slot, _ audit: IdentityAudit) -> SyncService {
        slot.launch = Launch(slot.store, audit: audit)
        let transport = FakeTransport()
        transport.autoFail = true
        return SyncService(deploymentURL: url, deviceInfo: DeviceInfo(name: slot.name, platform: .ios, model: "t", appVersion: "1"),
                           credentials: slot.launch.store, transport: transport, http: slot.launch.http, options: fastOptions(fallbackAfter: 1))
    }

    @Test(arguments: seeds) func accountOperationsInterleaveSafely(seed: Int) async throws {
        var rng = SplitMix(seed: UInt64(seed))
        let server = FakeKeyServer()
        let audit = IdentityAudit(server.http())
        let names = ["Mac", "iPhone", "iPad"]
        var slots: [Slot] = []
        var services: [SyncService] = []
        for name in names {
            let slot = Slot(name: name, launch: Launch(MemoryCredentialStore(), audit: audit))
            slots.append(slot)
            services.append(launch(slot, audit))
        }
        enum Request { case signIn(String), signOut }
        var last: [Int: (request: Request, task: Task<Bool, Never>)] = [:]
        var all: [Task<Bool, Never>] = []
        var captured: [Int: [DeviceListResult]] = [:]
        var staleViolations: [String] = []
        var away: Set<String> = []
        let delayable = ["account:register", "keys:claim", "account:unregister", "keys:rotate", "devices:remove"]

        func signIn(_ i: Int, _ user: String, failures: Int) {
            let service = services[i]
            let tokens = FlakyTokens(user, failures: failures)
            let task = Task { () -> Bool in (try? await service.signIn(auth: tokens, userID: user)) != nil }
            last[i] = (.signIn(user), task)
            all.append(task)
        }

        for _ in 0..<Self.steps {
            let i = Int.random(in: 0..<names.count, using: &rng)
            let service = services[i]
            switch Int.random(in: 0..<15, using: &rng) {
            case 0, 1:
                let user = Int.random(in: 0..<5, using: &rng) == 0 ? "v" : "u"
                // Sometimes the new identity's token can't be fetched at first (offline, Clerk slow).
                signIn(i, user, failures: Int.random(in: 0..<3, using: &rng) == 0 ? Int.random(in: 1...3, using: &rng) : 0)
            case 2:
                let task = Task { () -> Bool in await service.signOut(); return true }
                last[i] = (.signOut, task)
                all.append(task)
            case 3, 4:
                if let token = service.credentials?.token, let list = server.listResult(token: token) { captured[i, default: []].append(list) }
            case 5:
                // A list captured earlier arrives now, late and maybe out of order with others.
                guard var lists = captured[i], !lists.isEmpty else { break }
                let stale = lists.remove(at: Int.random(in: 0..<lists.count, using: &rng))
                captured[i] = lists
                let store = slots[i].store
                try? await service.operations.run { _ in
                    let before = (next: service.credentials?.nextLibraryKey, claim: service.credentials?.claimingLibraryKey,
                                  token: service.credentials?.token, registration: savedRegistration(store)?.token,
                                  removals: service.pendingRemovals)
                    service.applyNow(stale)
                    let after = service.credentials
                    let revision = stale.keyRevision ?? 0
                    if let next = before.next, let token = before.token, after?.nextLibraryKey == nil, after?.libraryKey != next,
                       let arrived = server.arrival(token, next.id), revision < arrived {
                        staleViolations.append("seed \(seed): a list from revision \(revision) deleted the rotation key that reached the server at \(arrived)")
                    }
                    if let claim = before.claim, let token = before.token, after?.claimingLibraryKey == nil, after?.libraryKey != claim,
                       let arrived = server.arrival(token, claim.id), revision < arrived {
                        staleViolations.append("seed \(seed): a list from revision \(revision) deleted the claimed key that reached the server at \(arrived)")
                    }
                    if savedRegistration(store)?.token != before.registration || service.pendingRemovals != before.removals {
                        staleViolations.append("seed \(seed): a device list changed the saved registration or removals")
                    }
                }
            case 6:
                if let key = server.keyId { server.setLibrary(keyId: key, rotationNeeded: true) }
            case 7:
                if away.contains(names[i]) { away.remove(names[i]) } else { away.insert(names[i]) }
                server.setAway(names[i], away.contains(names[i]))
            case 8:
                if Bool.random(using: &rng) { server.loseRotateAnswer(true) } else { server.loseRegisterAnswer(Bool.random(using: &rng)) }
            case 9:
                for request in service.keyRequests { all.append(Task { (try? await service.allowKey(for: request)) != nil }) }
                if case .comparing = service.keyStatus { service.confirmKeyCode() }
            case 10:
                if service.keyStatus == .outdated || service.keyStatus == .denied {
                    all.append(Task { (try? await service.requestKeyAgain()) != nil })
                }
            case 11:
                // The next request to one of these is sent but commits only later.
                server.delay(delayable[Int.random(in: 0..<delayable.count, using: &rng)])
            case 12:
                server.commitDelayed()
            case 13:
                // The app is quit and launched again: the old process stops at once (nothing more written or sent),
                // the Keychain stays, and the new launch signs in again as the account it was last asked for.
                slots[i].launch.kill()
                service.stop()
                services[i] = launch(slots[i], audit)
                switch last[i]?.request {
                case .signIn(let user)?: signIn(i, user, failures: 0)
                case .signOut?: break
                case nil: if let user = slots[i].store.load()?.userID { signIn(i, user, failures: 0) }
                }
            default:
                try await Task.sleep(for: .milliseconds(Int.random(in: 0...40, using: &rng)))
            }
        }

        // Settle: everyone back online, nothing lost any more, everything parked committed, every request answered.
        server.loseRegisterAnswer(false)
        server.loseRotateAnswer(false)
        for name in names { server.setAway(name, false) }
        server.commitDelayed()
        for task in all { _ = await task.value }
        for service in services { try? await service.operations.run { _ in } }
        try await Task.sleep(for: .milliseconds(300))

        #expect(server.violations.isEmpty, "seed \(seed): \(server.violations)")
        #expect(audit.violations.isEmpty, "seed \(seed): \(audit.violations)")
        #expect(staleViolations.isEmpty, "\(staleViolations)")
        for (i, entry) in last {
            let service = services[i]
            switch entry.request {
            case .signIn(let user):
                guard await entry.task.value else { continue }   // it failed (offline, lost answer): nothing to keep
                #expect(service.isRegistered && service.credentials?.userID == user,
                        "seed \(seed): \(names[i])'s sign-in as \(user) was erased (now \(service.credentials?.userID ?? "signed out"))")
            case .signOut:
                #expect(!service.isRegistered && service.credentials == nil, "seed \(seed): \(names[i])'s sign-out was undone")
            }
        }
        for violation in orphans(server, slots: slots, services: services) { Issue.record("seed \(seed): \(violation)") }
        for service in services { service.stop() }
    }

    /// Invariant 5: device rows nobody can use or remove any more.
    func orphans(_ server: FakeKeyServer, slots: [Slot], services: [SyncService]) -> [String] {
        var found: [String] = []
        for row in server.devices {
            let account = server.keyId(of: row.owner)
            let owners = slots.indices.filter { i in
                slots[i].store.load()?.token == row.token || savedRegistration(slots[i].store)?.token == row.token
                    || services[i].pendingRemovals.contains { $0.token == row.token }
            }
            guard let i = owners.first else {
                found.append("\(row.name)'s row (\(row.state.kind), \(row.owner)) belongs to a token no installation has any more")
                continue
            }
            guard case .holder(nil) = row.state, let account else { continue }
            if services[i].pendingRemovals.contains(where: { $0.token == row.token }) { continue }
            let credentials = slots[i].store.load()
            let known: [String?] = credentials?.token == row.token
                ? [credentials?.libraryKey?.id, credentials?.nextLibraryKey?.id, credentials?.claimingLibraryKey?.id]
                : [savedRegistration(slots[i].store)?.proposedKey.id]
            if !known.contains(account) {
                found.append("\(row.name) holds \(account) on the server, but its installation discarded that key")
            }
        }
        return found
    }

    // MARK: Clerk sign-out and sign-in

    /// Randomized interleavings of the app's sign-out (`signOut(sync:)`: sync first, then the Clerk session, or the Clerk
    /// part alone, `signOut(ifStill:)`) with the same user signing in again (Clerk, then the app connecting sync with
    /// that sign-in's generation), Clerk's session removal answering late or at once, and sometimes a sign-in that
    /// finishes inside a sign-out's session capture (`currentSession()`, the await between reading the sign-in and
    /// asking sync to sign out). A sign-in that finished after every sign-out started is the newest thing that
    /// happened: it must be what the account shows and what the store keeps at the end, and once its sync sign-in
    /// succeeded, sync stays signed in by it. A sign-out that started after the last sign-in finished must leave the
    /// account signed out, and sync too when it was `signOut(sync:)`.
    @Test(arguments: Array(1...30)) func aClerkSignOutNeverErasesANewerSignIn(seed: Int) async throws {
        var rng = SplitMix(seed: UInt64(seed))
        let clerkHTTP = FakeClerk()
        let sessions = Box(1)
        clerkHTTP.on("POST /v1/client/sign_ins") { _ in
            .init(json: ["response": ["id": "sia", "status": "needs_first_factor",
                                      "supported_first_factors": [["strategy": "email_code", "email_address_id": "idn_1"]]]])
        }
        clerkHTTP.on("POST /v1/client/sign_ins/sia/prepare_first_factor") { _ in .init(json: ["response": ["id": "sia"]]) }
        clerkHTTP.on("POST /v1/client/sign_ins/sia/attempt_first_factor") { _ in
            sessions.value += 1
            return .init(json: ["response": ["id": "sia", "status": "complete", "created_session_id": "sess_\(sessions.value)"]])
        }
        for n in 1...200 {
            clerkHTTP.on("POST /v1/client/sessions/sess_\(n)/touch") { _ in
                .init(json: ["response": [:] as [String: Any], "client": clientJSON(session: "sess_\(n)", user: "user_a")])
            }
            clerkHTTP.on("POST /v1/client/sessions/sess_\(n)/remove") { _ in .init(json: ["response": ["id": "sess_\(n)"]]) }
        }
        clerkHTTP.on("GET /v1/client") { _ in .init(json: ["response": clientJSON(session: "sess_1", user: "user_a")]) }
        clerkHTTP.on("GET /v1/environment") { _ in .init(json: ["user_settings": ["social": [:] as [String: Any]]]) }
        let clerkStore = MemoryClerkStore(ClerkState(frontendAPI: "https://clerk.openmusic.test", clientToken: "client-jwt", sessionID: "sess_1",
                                                     user: ClerkUser(id: "user_a", email: "a@example.com")))
        let config = FakeHTTP()
        config.respond = { _, _ in .object(["status": .string("success"), "value": .object(["auth": .object(["kind": .string("clerk"), "publishableKey": .string(testPublishableKey)])])]) }
        let defaults = try #require(UserDefaults(suiteName: "openmusic-tests-\(UUID().uuidString)"))
        let account = AccountService(hostedURL: url, store: clerkStore, defaults: defaults, http: config, clerkHTTP: clerkHTTP)
        account.watchesNetwork = false
        await account.load()
        try await Task.sleep(for: .milliseconds(50))

        let server = FakeKeyServer()
        let transport = FakeTransport()
        transport.autoFail = true
        let mac = SyncService(deploymentURL: url, deviceInfo: DeviceInfo(name: "Mac", platform: .mac, model: "t", appVersion: "1"),
                              credentials: MemoryCredentialStore(), transport: transport, http: server.http(), options: fastOptions(fallbackAfter: 1))
        try await mac.signIn(auth: FakeTokens([jwt("user_a")]), userID: "user_a", generation: account.sessionGeneration)

        let run = ClerkRun()
        run.connected.insert(account.sessionGeneration)
        var gates: [AsyncGate] = []
        var tasks: [Task<Void, Never>] = []

        /// A Clerk sign-in, then the app connecting sync for it, as `SyncHub.didSignIn` does.
        @MainActor func signInAndConnect() async {
            guard !run.signingIn else { return }
            run.signingIn = true
            defer { run.signingIn = false }
            guard let challenge = try? await account.startEmail("a@example.com"),
                  (try? await account.verifyEmail(challenge, code: "123456")) != nil,
                  let session = clerkStore.load()?.sessionID else { return }
            let generation = account.sessionGeneration
            run.lastSignIn = (run.tick(), session, generation)
            if (try? await mac.signIn(auth: FakeTokens([jwt("user_a")]), userID: "user_a", generation: generation)) != nil {
                run.connected.insert(generation)
            }
        }

        for _ in 0..<16 {
            // Let what started run a little: a sign-in finishing while a sign-out waits for Clerk is the case.
            try await Task.sleep(for: .milliseconds(Int.random(in: 1...8, using: &rng)))
            switch Int.random(in: 0..<5, using: &rng) {
            case 0, 1:
                if Bool.random(using: &rng), let session = await account.currentSession().sessionID {
                    // Clerk takes a while to end this session.
                    let gate = AsyncGate()
                    clerkHTTP.hold("POST /v1/client/sessions/\(session)/remove", gate)
                    gates.append(gate)
                }
                let withSync = Bool.random(using: &rng)
                if withSync, Int.random(in: 0..<3, using: &rng) == 0 {
                    // A sign-in finishes while this sign-out captures the session.
                    account.willReadClerkSession = {
                        account.willReadClerkSession = nil
                        await signInAndConnect()
                    }
                }
                tasks.append(Task {
                    run.signOutStarts.append((run.tick(), withSync))
                    if withSync {
                        await account.signOut(sync: mac)
                    } else {
                        let session = await account.currentSession()
                        await account.signOut(ifStill: session)
                    }
                })
            case 2:
                // One sign-in at a time (two at once race inside Clerk, which isn't the case here).
                guard !run.signingIn else { break }
                tasks.append(Task { await signInAndConnect() })
            case 3:
                for gate in gates { await gate.release() }
                gates = []
            default:
                try await Task.sleep(for: .milliseconds(Int.random(in: 0...20, using: &rng)))
            }
        }
        account.willReadClerkSession = nil
        for gate in gates { await gate.release() }
        for task in tasks { await task.value }
        try? await mac.operations.run { _ in }

        if let newest = run.lastSignIn, run.signOutStarts.allSatisfy({ $0.at < newest.at }) {
            #expect(account.user?.id == "user_a", "seed \(seed): the newest sign-in shows signed out")
            #expect(clerkStore.load()?.sessionID == newest.session, "seed \(seed): the newest sign-in's session was erased")
            if run.connected.contains(newest.generation) {
                #expect(mac.isRegistered && mac.currentSignIn == SyncSignIn(userID: "user_a", generation: newest.generation),
                        "seed \(seed): the newest sign-in's sync sign-in was signed out (now \(String(describing: mac.currentSignIn)))")
            }
        } else {
            #expect(account.user == nil && clerkStore.load()?.sessionID == nil, "seed \(seed): a sign-out after the last sign-in didn't sign out")
            if let newest = run.lastSignIn, run.signOutStarts.contains(where: { $0.sync && $0.at > newest.at }) {
                #expect(!mac.isRegistered, "seed \(seed): a sign-out after the last sign-in left sync signed in")
            }
        }
        mac.stop()
    }
}

/// What a run of `aClerkSignOutNeverErasesANewerSignIn` saw happen, in order.
@MainActor final class ClerkRun {
    private var clock = 0
    /// When the newest successful sign-in finished, its session and its generation.
    var lastSignIn: (at: Int, session: String, generation: Int)? = (0, "sess_1", 0)
    /// Generations whose sync sign-in succeeded.
    var connected: Set<Int> = []
    /// When each sign-out started, and whether it signed sync out too (`signOut(sync:)`).
    var signOutStarts: [(at: Int, sync: Bool)] = []
    var signingIn = false
    func tick() -> Int {
        clock += 1
        return clock
    }
}

/// A token source for `user` that can't answer its first `failures` requests (offline), then answers.
actor FlakyTokens: AuthTokenProvider {
    let user: String
    var failures: Int
    init(_ user: String, failures: Int) {
        self.user = user
        self.failures = failures
    }
    func token(forceRefresh: Bool) async throws -> String? {
        if failures > 0 {
            failures -= 1
            throw URLError(.notConnectedToInternet)
        }
        return jwt(user)
    }
}

/// One launch's view of an installation's Keychain: after the launch is killed it writes nothing. It tells the
/// identity audit which user each registration's device token is for, as the registration is saved.
final class LaunchStore: SyncCredentialStore, @unchecked Sendable {
    let inner: MemoryCredentialStore
    let audit: IdentityAudit
    let dead = LockedBox(false)
    init(_ inner: MemoryCredentialStore, audit: IdentityAudit) {
        self.inner = inner
        self.audit = audit
    }
    func load() -> SyncCredentials? { inner.load() }
    func save(_ credentials: SyncCredentials?) { if !dead.value { inner.save(credentials) } }
    func persist(_ credentials: SyncCredentials?) -> Bool {
        guard !dead.value else { return false }
        inner.save(credentials)
        return inner.load() == credentials
    }
    func state(_ name: String) -> Data? { inner.state(name) }
    func setState(_ name: String, _ data: Data?) { if !dead.value { inner.setState(name, data) } }
    func persistState(_ name: String, _ data: Data?) -> Bool {
        guard !dead.value else { return false }
        inner.setState(name, data)
        if name == SyncService.PendingRegistration.stateName, let data,
           let saved = try? JSONDecoder().decode(SyncService.PendingRegistration.self, from: data) {
            audit.expect(token: saved.token, user: saved.userID)
        }
        return inner.state(name) == data
    }
}

/// One launch's network: after the launch is killed nothing more is sent.
final class LaunchHTTP: HTTPPoster, @unchecked Sendable {
    let inner: any HTTPPoster
    let dead = LockedBox(false)
    init(_ inner: any HTTPPoster) { self.inner = inner }
    func post(_ url: URL, body: Data, headers: [String: String]) async throws -> (body: Data, status: Int) {
        guard !dead.value else { throw URLError(.cancelled) }
        return try await inner.post(url, body: body, headers: headers)
    }
}

/// splitmix64: a small seeded generator, so a failing seed replays exactly.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Wraps the fake server's HTTP and checks every call that carries a device token against the user that token was
/// made for (from the registration each device saved before sending it): a call under any other identity is a
/// violation.
final class IdentityAudit: HTTPPoster, @unchecked Sendable {
    private let inner: FakeHTTP
    private let lock = NSLock()
    private var users: [String: String] = [:]
    private var sent: [(token: String, user: String?, path: String)] = []

    init(_ inner: FakeHTTP) { self.inner = inner }

    func expect(token: String, user: String) { lock.withLock { users[token] = user } }

    var violations: [String] {
        lock.withLock {
            sent.compactMap { call in
                guard let owner = users[call.token], call.user != owner else { return nil }
                return "\(call.path) with \(owner)'s device token went out as \(call.user ?? "nobody")"
            }
        }
    }

    func post(_ url: URL, body: Data, headers: [String: String]) async throws -> (body: Data, status: Int) {
        if let parsed = try? ConvexValue.parse(body), let token = firstArgs(parsed)?["token"]?.stringValue {
            let user = headers["Authorization"].flatMap(Self.subject)
            lock.withLock { sent.append((token, user, parsed["path"]?.stringValue ?? "?")) }
        }
        return try await inner.post(url, body: body, headers: headers)
    }

    /// The `sub` of a "Bearer <jwt>" header.
    static func subject(_ header: String) -> String? {
        guard header.hasPrefix("Bearer ") else { return nil }
        let parts = header.dropFirst(7).split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["sub"] as? String
    }
}
