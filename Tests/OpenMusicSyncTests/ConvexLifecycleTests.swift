import Foundation
import Testing
@testable import OpenMusicSync

/// An HTTP server that holds every request until the test releases it, then answers `value`.
actor HeldHTTP: HTTPPoster {
    private(set) var started = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false
    let value: ConvexValue

    init(answer value: ConvexValue = .null) { self.value = value }

    nonisolated func post(_ url: URL, body: Data, headers: [String: String]) async throws -> (body: Data, status: Int) {
        await hold()
        return (ConvexValue.object(["status": .string("success"), "value": value]).jsonData(), 200)
    }

    private func hold() async {
        started += 1
        if released { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Answers every held request, and every later one at once.
    func releaseAll() {
        released = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

@Suite struct ConvexLifecycleTests {
    private func client(_ transport: FakeTransport, _ http: HTTPPoster, timeout: Duration, pollInterval: Duration = .milliseconds(50)) -> ConvexClient {
        var options = fastOptions(fallbackAfter: 1)
        options.mutationTimeout = timeout
        options.pollInterval = pollInterval
        return ConvexClient(deploymentURL: URL(string: "https://x.convex.cloud")!, transport: transport, http: http, options: options)
    }

    /// A connected client with one mutation sent on the socket, then the socket dies and the mutation moves to HTTP.
    private func mutationMovedToHTTP(_ client: ConvexClient, _ transport: FakeTransport, _ http: HeldHTTP) async -> Task<Timed<ConvexValue>, any Error> {
        await client.start()
        #expect(await eventually { transport.sockets.count == 1 })
        transport.sockets[0].open()
        #expect(await eventually { await client.status.state == .connected })
        let task = Task { try await client.mutation("x:write", args: .null) }
        #expect(await eventually { transport.sockets[0].messages(ofType: "Mutation").count == 1 })
        transport.autoFail = true
        transport.sockets[0].serverClose()
        #expect(await eventually { await http.started == 1 })
        return task
    }

    @Test func aMutationMovedFromTheSocketToHTTPStillMeetsItsDeadline() async throws {
        let transport = FakeTransport()
        let http = HeldHTTP()
        let client = client(transport, http, timeout: .milliseconds(150))
        let started = ContinuousClock.now
        let task = await mutationMovedToHTTP(client, transport, http)
        await #expect(throws: ConvexClientError.transport("the sync server didn't answer in time")) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(2))
        // The late HTTP answer is dropped (a second resume would crash the test process).
        await http.releaseAll()
        try await Task.sleep(for: .milliseconds(50))
        await client.stop()
    }

    @Test func stopEndsAMutationThatMovedToHTTP() async throws {
        let transport = FakeTransport()
        let http = HeldHTTP()
        let client = client(transport, http, timeout: .seconds(30))
        let task = await mutationMovedToHTTP(client, transport, http)
        await client.stop()
        await #expect(throws: ConvexClientError.stopped) { try await task.value }
        await http.releaseAll()
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test func aMutationSentWhileInTheFallbackMeetsItsDeadlineAndStopToo() async throws {
        let transport = FakeTransport()
        transport.autoFail = true
        let http = HeldHTTP()
        let client = client(transport, http, timeout: .milliseconds(150), pollInterval: .seconds(30))
        await client.start()
        #expect(await eventually { await client.status.httpFallback })
        let started = ContinuousClock.now
        await #expect(throws: ConvexClientError.transport("the sync server didn't answer in time")) {
            try await client.mutation("x:write", args: .null)
        }
        #expect(ContinuousClock.now - started < .seconds(2))

        let second = Task { try await client.mutation("x:write", args: .null) }
        #expect(await eventually { await http.started >= 2 })
        await client.stop()
        await #expect(throws: ConvexClientError.stopped) { try await second.value }
        await http.releaseAll()
    }

    @Test func aMutationAnsweredOverHTTPResolvesWithTheAnswer() async throws {
        let transport = FakeTransport()
        let http = HeldHTTP(answer: .object(["serverNow": .float64(7)]))
        let client = client(transport, http, timeout: .seconds(5))
        let task = await mutationMovedToHTTP(client, transport, http)
        await http.releaseAll()
        #expect(try await task.value.value == .object(["serverNow": .float64(7)]))
        // It isn't sent again when a socket comes back.
        transport.autoFail = false
        #expect(await eventually { transport.sockets.last.map { !$0.isClosed } ?? false })
        let socket = try #require(transport.sockets.last)
        socket.open()
        try await Task.sleep(for: .milliseconds(50))
        #expect(socket.messages(ofType: "Mutation").isEmpty)
        await client.stop()
    }

    @Test func aPollStillInFlightWhenTheSocketReturnsDoesNotOverwriteTheSocketsNewerValue() async throws {
        let transport = FakeTransport()
        transport.autoFail = true
        let http = HeldHTTP(answer: .float64(1))
        let client = client(transport, http, timeout: .seconds(5), pollInterval: .seconds(10))
        let results = Collector<ConvexClient.QueryResult>()
        let consumer = results.consume(client.subscribe("x:q", args: .null))
        defer { consumer.cancel() }
        await client.start()
        #expect(await eventually { await http.started == 1 })

        // The socket comes back and delivers 2 while the poll is still waiting for its answer.
        transport.autoFail = false
        #expect(await eventually { transport.sockets.last.map { !$0.isClosed } ?? false })
        let socket = try #require(transport.sockets.last)
        socket.open()
        #expect(await eventually { socket.messages(ofType: "ModifyQuerySet").count == 1 })
        guard case .array(let adds) = socket.messages(ofType: "ModifyQuerySet")[0]["modifications"] else { Issue.record("no adds"); return }
        let queryID = Int(adds[0]["queryId"]?.doubleValue ?? -1)
        socket.receive(transition(from: (0, 0), to: (1, 5), updated(queryID, "2")))
        #expect(await eventually { results.items.count == 1 })

        await http.releaseAll()
        try await Task.sleep(for: .milliseconds(100))
        #expect(results.items.count == 1)
        #expect(try results.items.last?.get() == .float64(2))
        await client.stop()
    }
}

@MainActor
@Suite(.serialized) struct SyncServiceAccountTests {
    func makeService(_ transport: FakeTransport, _ http: FakeHTTP, paired: Bool = true) -> SyncService {
        let url = URL(string: "https://example-123.convex.cloud")!
        let credentials = SyncCredentials(deviceID: DeviceID("d1"), libraryID: LibraryID(rawValue: "l1"),
                                          token: String(repeating: "t", count: 43), deploymentURL: url)
        return SyncService(deploymentURL: url, deviceInfo: DeviceInfo(name: "Test", platform: .ios, model: "t", appVersion: "1"),
                           credentials: MemoryCredentialStore(paired ? credentials : nil), transport: transport, http: http,
                           options: fastOptions(fallbackAfter: 1))
    }

    @Test func stoppingShowsTheConnectionAsNoLongerConnected() async throws {
        let transport = FakeTransport()
        let service = makeService(transport, FakeHTTP())
        service.start()
        #expect(await eventually { transport.sockets.count == 1 })
        transport.sockets[0].open()
        #expect(await waitUntil { service.connection.state == .connected })
        service.stop()
        #expect(service.connection.state == .idle && !service.connection.httpFallback)
        try await Task.sleep(for: .milliseconds(100))
        #expect(service.connection.state == .idle, "nothing flips it back afterwards")
    }

    @Test func signingInRegistersTheDeviceAndTheFirstDeviceKeepsItsKey() async throws {
        let transport = FakeTransport()
        transport.autoFail = true
        let http = FakeHTTP()
        http.respond = { path, body in
            guard path == "/api/mutation", body["path"] == .string("account:register"), let a = firstArgs(body) else { return ok(.array([])) }
            // The account had no key: the proposed one is adopted.
            return ok(.object(["deviceId": .string("d1"), "libraryId": .string("l1"), "keyId": a["keyId"] ?? .null,
                                    "keyState": .string("holder"), "serverNow": .float64(5)]))
        }
        let store = MemoryCredentialStore()
        let url = URL(string: "https://example-123.convex.cloud")!
        let service = SyncService(deploymentURL: url, deviceInfo: DeviceInfo(name: "Leo's iPhone", platform: .ios, model: "t", appVersion: "1"),
                                  credentials: store, transport: transport, http: http, options: fastOptions(fallbackAfter: 1))
        #expect(service.registration == .none && service.keyStatus == .none)
        try await service.signIn(auth: FakeTokens([jwt("user_1")]), userID: "user_1")

        #expect(service.registration == .registered(deviceID: DeviceID("d1"), libraryID: LibraryID(rawValue: "l1")))
        #expect(service.keyStatus == .available)
        let sent = try #require(http.requests.first { $0.body["path"] == .string("account:register") })
        let a = try #require(firstArgs(sent.body))
        let saved = try #require(store.load())
        #expect(a["token"] == .string(saved.token) && saved.token.count == 43)
        #expect(a["publicKey"] == .string(saved.deviceKey.publicKey))
        #expect(a["keyId"] == .string(saved.libraryKey?.id ?? "missing"))
        #expect(a["device"]?["name"] == .string("Leo's iPhone"))
        #expect(sent.headers["Authorization"] == "Bearer \(jwt("user_1"))")
        #expect(saved.userID == "user_1")

        // Signing in again (next launch) keeps the registration; another user starts over.
        try await service.signIn(auth: FakeTokens([jwt("user_1")]), userID: "user_1")
        #expect(http.requests.filter { $0.body["path"] == .string("account:register") }.count == 1)
        try await service.signIn(auth: FakeTokens([jwt("user_2")]), userID: "user_2")
        #expect(http.requests.filter { $0.body["path"] == .string("account:register") }.count == 2)
        #expect(store.load()?.userID == "user_2")
        service.stop()
    }

    @Test func signingOutRemovesTheDeviceAndForgetsEverything() async throws {
        let transport = FakeTransport()
        transport.autoFail = true
        let http = FakeHTTP()
        http.respond = { _, body in
            if body["path"] == .string("account:register") {
                return ok(.object(["deviceId": .string("d1"), "libraryId": .string("l1"), "keyId": firstArgs(body)?["keyId"] ?? .null,
                                        "keyState": .string("holder"), "serverNow": .float64(5)]))
            }
            return ok(.object(["serverNow": .float64(6)]))
        }
        let store = MemoryCredentialStore()
        let service = SyncService(deploymentURL: URL(string: "https://example-123.convex.cloud")!,
                                  deviceInfo: DeviceInfo(name: "Mac", platform: .mac, model: "t", appVersion: "1"),
                                  credentials: store, transport: transport, http: http, options: fastOptions(fallbackAfter: 1))
        try await service.signIn(auth: FakeTokens([jwt("u")]), userID: "u")
        let token = try #require(store.load()?.token)
        await service.signOut()
        let remove = try #require(http.requests.first { $0.body["path"] == .string("devices:remove") })
        #expect(firstArgs(remove.body)?["token"] == .string(token) && firstArgs(remove.body)?["deviceId"] == .string("d1"))
        #expect(store.load() == nil)
        #expect(service.registration == .none && service.keyStatus == .none && service.libraryKey == nil)
    }
}

/// The first argument object of a recorded HTTP call.
func firstArgs(_ body: ConvexValue) -> ConvexValue? { if case .array(let a) = body["args"] { a.first } else { nil } }

func ok(_ value: ConvexValue) -> ConvexValue { .object(["status": .string("success"), "value": value]) }

func deviceRow(_ id: String, _ name: String, keyState: String, publicKey: String? = nil) -> ConvexValue {
    .object(["id": .string(id), "name": .string(name), "platform": .string("ios"), "model": .string("m"), "appVersion": .string("1"),
             "createdAt": .float64(1), "lastSeenAt": .float64(1), "keyState": .string(keyState),
             "publicKey": publicKey.map(ConvexValue.string) ?? .null])
}
