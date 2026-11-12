import Foundation
import OpenMusicCore
import Testing
@testable import OpenMusicSync

/// The cases the fourth review of the accounts design found: a stale device list making a holder give up a key that
/// opens the rotation waiting for it, a registration queued for one user sent under the next user's sign-in, and a
/// sign-out erasing a sign-in that started while it waited for the server.
@MainActor
@Suite(.serialized) struct StaleListAndIdentityRaceTests {
    let url = URL(string: "https://example-123.convex.cloud")!

    func device(_ server: FakeKeyServer, _ name: String, store: any SyncCredentialStore = MemoryCredentialStore(),
                transport: FakeTransport? = nil, http: (any HTTPPoster)? = nil) -> SyncService {
        let transport = transport ?? {
            let t = FakeTransport()
            t.autoFail = true
            return t
        }()
        return SyncService(deploymentURL: url, deviceInfo: DeviceInfo(name: name, platform: .ios, model: "t", appVersion: "1"),
                           credentials: store, transport: transport, http: http ?? server.http(), options: fastOptions(fallbackAfter: 1))
    }

    func signIn(_ service: SyncService, user: String = "u") async throws {
        try await service.signIn(auth: FakeTokens([jwt(user)]), userID: user)
    }

    func comparison(_ service: SyncService) -> SyncService.KeyComparison? {
        if case .comparing(let c) = service.keyStatus { c } else { nil }
    }

    /// The Mac holds the key and the phone took it through the codes: two holders.
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

    // MARK: P2-1: a release is decided on the account's current state

    /// The Mac's list from while the account used K1 arrives late. Meanwhile the Mac rotated to K2, the phone took K2,
    /// rotated to K3 (wrapped for the Mac under K2) and left. Holding K2 and reading "K1", the Mac used to release K2
    /// at once: the server dropped the K2→K3 envelope it could open and, with no holder left, cleared the vault. Now it
    /// looks again first, opens K3 with K2, and sends no release.
    @Test func aStaleListNeverReleasesAKeyThatOpensTheWaitingRotation() async throws {
        let server = FakeKeyServer()
        let (mac, phone) = try await twoHolders(server)
        let k1 = try #require(mac.libraryKey)
        let stale = try server.listResult(for: "Leo's Mac")
        #expect(stale.keyId == k1.id && stale.rekey == nil)

        // The Mac rotates K1 → K2 while the phone is away.
        server.setAway("Leo's iPhone", true)
        server.setLibrary(keyId: k1.id, rotationNeeded: true)
        #expect(await waitUntil { mac.libraryKey != k1 && mac.libraryKey?.id == server.keyId })
        let k2 = try #require(mac.libraryKey)

        // The phone takes K2, rotates K2 → K3 while the Mac is away, and leaves.
        server.setAway("Leo's Mac", true)
        server.setAway("Leo's iPhone", false)
        #expect(await waitUntil { phone.libraryKey == k2 && server.device(named: "Leo's iPhone")?.state == .holder(rekey: nil) })
        server.setLibrary(keyId: k2.id, rotationNeeded: true)
        #expect(await waitUntil { server.keyId != k2.id && phone.libraryKey?.id == server.keyId })
        let k3 = try #require(server.keyId)
        guard case .holder(let rekey?)? = server.device(named: "Leo's Mac")?.state else {
            Issue.record("the Mac should have a rotated key waiting")
            return
        }
        #expect(rekey.keyId == k3 && rekey.fromKeyId == k2.id)
        phone.stop()
        server.remove("Leo's iPhone")

        // The Mac is back without polling, and the late list arrives: it says K1 while the Mac holds K2. The list is
        // older than one the Mac applied, so it is ignored whole (no release, no fresh look on its account); the Mac
        // learns K3 from its next list.
        mac.setForeground(false)
        try await Task.sleep(for: .milliseconds(150))
        server.setAway("Leo's Mac", false)
        mac.apply(stale)
        try await Task.sleep(for: .milliseconds(150))
        #expect(mac.libraryKey == k2 && server.calls("keys:release", by: "Leo's Mac").isEmpty)
        mac.setForeground(true)

        #expect(await waitUntil { mac.libraryKey?.id == server.keyId && mac.keyStatus == .available })
        #expect(server.keyId != nil && mac.libraryKey != k2)
        #expect(server.device(named: "Leo's Mac")?.state.kind == "holder")
        #expect(server.calls("keys:release", by: "Leo's Mac").isEmpty)
        mac.stop()
    }

    // MARK: P2-2: queued calls belong to the identity they were made for

    /// User A's registration waits on a socket that hasn't opened. The device signs out and user B signs in; then the
    /// socket opens. A's registration used to be replayed on it under B's identity. Now it is failed when the
    /// identity changes, and only B's registration is sent.
    @Test func aRegistrationQueuedForOneUserIsNeverSentUnderTheNext() async throws {
        try await queuedRegistrationScenario(signOutBetween: true)
    }

    /// The same without a sign-out in between: B's sign-in overtakes A's directly.
    @Test func aRegistrationQueuedForOneUserIsNeverSentWhenAnotherUserSignsInOverIt() async throws {
        try await queuedRegistrationScenario(signOutBetween: false)
    }

    func queuedRegistrationScenario(signOutBetween: Bool) async throws {
        let server = FakeKeyServer()
        let store = MemoryCredentialStore()
        let transport = FakeTransport()   // sockets open only when the test says so
        let mac = device(server, "Leo's Mac", store: store, transport: transport)

        let first = Task { try await mac.signIn(auth: FakeTokens([jwt("a")]), userID: "a") }
        #expect(await waitUntil { savedRegistration(store)?.userID == "a" })
        let aToken = try #require(savedRegistration(store)?.token)
        try await Task.sleep(for: .milliseconds(100))   // queued on the socket, which hasn't opened
        #expect(transport.sockets.allSatisfy { $0.sent.isEmpty })

        if signOutBetween { await mac.signOut() }
        let second = Task { try await mac.signIn(auth: FakeTokens([jwt("b")]), userID: "b") }
        #expect(await waitUntil { savedRegistration(store)?.userID == "b" })
        let bToken = try #require(savedRegistration(store)?.token)
        try await Task.sleep(for: .milliseconds(100))

        // The socket opens: it carries B's identity and B's registration, never A's.
        let open = transport.sockets.filter { !$0.isClosed }
        #expect(!open.isEmpty)
        for socket in open { socket.open() }
        #expect(await eventually { open.contains { $0.sent.contains { $0.contains(bToken) } } })
        let sent = transport.sockets.flatMap(\.sent)
        #expect(!sent.contains { $0.contains(aToken) })
        #expect(!sent.contains { $0.contains(jwt("a")) && $0.contains("Mutation") })

        // The socket drops and the client falls back to HTTP: B's registration lands, and B holds a key of its own.
        transport.autoFail = true
        for socket in open { socket.serverClose() }
        try await second.value
        if case .success = await first.result { Issue.record("A's overtaken sign-in reported success") }
        let registered = server.calls("account:register").compactMap { $0.args["token"]?.stringValue }
        #expect(!registered.contains(aToken) && registered.contains(bToken))
        #expect(server.devices.count == 1 && server.devices.first?.token == bToken)
        #expect(store.load()?.userID == "b" && store.load()?.token == bToken)
        #expect(mac.libraryKey != nil && mac.libraryKey?.id == server.keyId)
        #expect(server.device(named: "Leo's Mac")?.state == .holder(rekey: nil))
        mac.stop()
    }

    /// The client itself: a new token source for the same user keeps queued mutations; another user's never gets
    /// them. One already sent under A isn't replayed on the next socket (it fails with `.authChanged`), and one not
    /// sent yet fails as soon as the identity changes.
    @Test func aMutationIsNeverSentUnderAnotherIdentityThanItWasMadeFor() async throws {
        let transport = FakeTransport()
        let client = makeClient(transport)
        await client.setAuth(FakeTokens([jwt("a")]), identity: "a")
        await client.start()
        let first = Task { try await client.mutation("devices:heartbeat", args: .object(["n": .float64(1)])) }
        try await Task.sleep(for: .milliseconds(50))
        await client.setAuth(FakeTokens([jwt("a")]), identity: "a")
        let socket1 = try #require(transport.sockets.last)
        socket1.open()
        #expect(await eventually { socket1.messages(ofType: "Mutation").count == 1 })

        await client.setAuth(FakeTokens([jwt("b")]), identity: "b")
        socket1.serverClose()
        #expect(await eventually { transport.sockets.count == 2 })
        let socket2 = transport.sockets[1]
        socket2.open()
        #expect(await eventually { !socket2.messages(ofType: "Connect").isEmpty })
        if case .failure(let error) = await first.result {
            #expect(error as? ConvexClientError == .authChanged)
        } else {
            Issue.record("a mutation sent under A completed after B signed in")
        }
        #expect(socket2.messages(ofType: "Mutation").isEmpty)

        await client.stop()

        // Not sent yet when the identity changes (the socket hasn't opened): it fails at once.
        let quiet = FakeTransport()
        let other = makeClient(quiet)
        await other.setAuth(FakeTokens([jwt("a")]), identity: "a")
        await other.start()
        let unsent = Task { try await other.mutation("devices:heartbeat", args: .object(["n": .float64(3)])) }
        try await Task.sleep(for: .milliseconds(50))
        await other.setAuth(nil)
        if case .failure(let error) = await unsent.result {
            #expect(error as? ConvexClientError == .authChanged)
        } else {
            Issue.record("a queued mutation survived the sign-out")
        }
        quiet.sockets.last?.open()
        try await Task.sleep(for: .milliseconds(50))
        #expect(quiet.sockets.allSatisfy { $0.messages(ofType: "Mutation").isEmpty })
        await other.stop()
    }

    // MARK: P2-3: sign-out leaves a newer sign-in alone

    /// User A signs out and its device removal waits on the server. User B signs in meanwhile. Sign-out used to
    /// forget B's credentials, drop B's auth and stop sync when the removal answered. Account operations now run one
    /// at a time: B's sign-in waits for A's sign-out, so the sign-out can't erase it, and A's removal still lands.
    @Test func aSignOutOvertakenByASignInLeavesThatSignInAlone() async throws {
        let server = FakeKeyServer()
        let gate = HTTPGate(server.http(), holding: "devices:remove")
        let store = MemoryCredentialStore()
        let mac = device(server, "Leo's Mac", store: store, http: gate)
        try await signIn(mac, user: "a")
        let aDevice = try #require(mac.selfID)

        let signingOut = Task { await mac.signOut() }
        #expect(await eventually { gate.waiting > 0 })
        let signingIn = Task { try await signIn(mac, user: "b") }
        try await Task.sleep(for: .milliseconds(100))
        #expect(mac.selfID == aDevice, "B's sign-in waits for the sign-out")

        gate.open()
        await signingOut.value
        try await signingIn.value
        let bDevice = try #require(mac.selfID)
        #expect(bDevice != aDevice && store.load()?.userID == "b")
        #expect(server.devices.allSatisfy { $0.id != aDevice.rawValue })
        #expect(mac.selfID == bDevice && mac.isRegistered)
        #expect(store.load()?.userID == "b" && store.load()?.deviceID == bDevice)
        // B's session still works: calls go out with B's token and identity.
        try await mac.rename(bDevice, to: "Leo's Mac (B)")
        let rename = try #require(server.calls("devices:rename").last)
        #expect(rename.args["token"]?.stringValue == store.load()?.token)
        let lastHeaders = try #require(gate.inner.requests.last?.headers)
        #expect(lastHeaders["Authorization"] == "Bearer \(jwt("b"))")
        mac.stop()
    }
}

/// An HTTP poster that holds calls to one function until the test opens it.
final class HTTPGate: HTTPPoster, @unchecked Sendable {
    let inner: FakeHTTP
    private let path: String
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var _waiting = 0

    init(_ inner: FakeHTTP, holding path: String) {
        self.inner = inner
        self.path = path
    }

    var waiting: Int { lock.withLock { _waiting } }

    func post(_ url: URL, body: Data, headers: [String: String]) async throws -> (body: Data, status: Int) {
        if (try? ConvexValue.parse(body))?["path"]?.stringValue == path {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if isOpen { return true }
                    _waiting += 1
                    waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        return try await inner.post(url, body: body, headers: headers)
    }

    func open() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in waiting { waiter.resume() }
    }
}
