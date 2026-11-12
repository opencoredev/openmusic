import Foundation
import Testing
@testable import MedleySync

// MARK: - Fakes

final class FakeSocket: WebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [String] = []
    private var _closed = false
    let events: AsyncStream<WebSocketEvent>
    private let continuation: AsyncStream<WebSocketEvent>.Continuation

    init() {
        (events, continuation) = AsyncStream.makeStream(of: WebSocketEvent.self)
    }

    var sent: [String] { lock.withLock { _sent } }
    var isClosed: Bool { lock.withLock { _closed } }

    func send(_ text: String) { lock.withLock { _sent.append(text) } }

    func close() {
        let already = lock.withLock { () -> Bool in defer { _closed = true }; return _closed }
        guard !already else { return }
        continuation.yield(.closed(reason: "closed by client"))
        continuation.finish()
    }

    func open() { continuation.yield(.opened) }
    func receive(_ text: String) { continuation.yield(.message(text)) }
    func serverClose(_ reason: String = "network down") {
        lock.withLock { _closed = true }
        continuation.yield(.closed(reason: reason))
        continuation.finish()
    }

    /// The sent messages as parsed objects.
    var messages: [ConvexValue] { sent.compactMap { try? ConvexValue.parse(Data($0.utf8)) } }
    func messages(ofType type: String) -> [ConvexValue] { messages.filter { $0["type"]?.stringValue == type } }
}

final class FakeTransport: WebSocketTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _sockets: [FakeSocket] = []
    var autoFail = false

    var sockets: [FakeSocket] { lock.withLock { _sockets } }

    func connect(to url: URL) -> (connection: any WebSocketConnection, events: AsyncStream<WebSocketEvent>) {
        let socket = FakeSocket()
        lock.withLock { _sockets.append(socket) }
        if lock.withLock({ autoFail }) { socket.serverClose("refused") }
        return (socket, socket.events)
    }
}

final class FakeHTTP: HTTPPoster, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [(path: String, body: ConvexValue, headers: [String: String])] = []
    var respond: @Sendable (String, ConvexValue) -> ConvexValue = { _, _ in .object(["status": .string("success"), "value": .null]) }
    /// Answers with the request's headers too, and may throw (the request never got an answer). Used instead of
    /// `respond` when set.
    var handle: (@Sendable (String, ConvexValue, [String: String]) throws -> ConvexValue)?

    var requests: [(path: String, body: ConvexValue, headers: [String: String])] { lock.withLock { _requests } }
    private var _urls: [URL] = []
    /// The full URL of every request, in order.
    var urls: [URL] { lock.withLock { _urls } }

    func post(_ url: URL, body: Data, headers: [String: String]) async throws -> (body: Data, status: Int) {
        let parsed = try ConvexValue.parse(body)
        lock.withLock { _requests.append((url.path, parsed, headers)); _urls.append(url) }
        if let handle { return (try handle(url.path, parsed, headers).jsonData(), 200) }
        return (respond(url.path, parsed).jsonData(), 200)
    }
}

/// Polls until `condition` holds (or ~3 s pass).
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<600 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

func ts(_ n: UInt64) -> String { ConvexTimestamp(value: n).encoded }

func transition(from: (Int, UInt64), to: (Int, UInt64), _ modifications: String...) -> String {
    #"{"type":"Transition","startVersion":{"querySet":\#(from.0),"ts":"\#(ts(from.1))","identity":0},"endVersion":{"querySet":\#(to.0),"ts":"\#(ts(to.1))","identity":0},"modifications":[\#(modifications.joined(separator: ","))]}"#
}

func updated(_ id: Int, _ value: String) -> String {
    #"{"type":"QueryUpdated","queryId":\#(id),"value":\#(value),"logLines":[],"journal":null}"#
}

/// A value tests change while the code under test reads it from other tasks.
final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

func fastOptions(fallbackAfter: Int = 3) -> ConvexClient.Options {
    var options = ConvexClient.Options()
    options.initialBackoff = .milliseconds(10)
    options.maxBackoff = .milliseconds(40)
    options.pollInterval = .milliseconds(50)
    options.fallbackAfterFailures = fallbackAfter
    options.jitter = false
    options.authRetryDelay = .milliseconds(20)
    return options
}

func makeClient(_ transport: FakeTransport, http: FakeHTTP = FakeHTTP(), fallbackAfter: Int = 3) -> ConvexClient {
    var options = ConvexClient.Options()
    options.initialBackoff = .milliseconds(10)
    options.maxBackoff = .milliseconds(40)
    options.pollInterval = .milliseconds(50)
    options.fallbackAfterFailures = fallbackAfter
    options.jitter = false
    return ConvexClient(deploymentURL: URL(string: "https://example-123.convex.cloud")!, transport: transport, http: http, options: options)
}

/// Collects a stream into an array the test can poll.
final class Collector<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [T] = []
    var items: [T] { lock.withLock { _items } }
    func add(_ item: T) { lock.withLock { _items.append(item) } }

    func consume(_ stream: AsyncStream<T>) -> Task<Void, Never> {
        Task { for await item in stream { self.add(item) } }
    }
}

// MARK: - Tests

@Suite struct ConvexClientTests {
    @Test func syncURLMatchesTheNpmClient() {
        let client = makeClient(FakeTransport())
        #expect(client.syncURL.absoluteString == "wss://example-123.convex.cloud/api/1.49.0/sync")
    }

    @Test func connectsSubscribesAndDeliversTransitions() async throws {
        let transport = FakeTransport()
        let client = makeClient(transport)
        let results = Collector<ConvexClient.QueryResult>()
        let consumer = results.consume(client.subscribe("devices:list", args: .object(["token": .string("t")])))
        defer { consumer.cancel() }
        await client.start()
        #expect(await eventually { transport.sockets.count == 1 })
        let socket = transport.sockets[0]
        socket.open()
        #expect(await eventually { socket.messages(ofType: "ModifyQuerySet").count == 1 })

        let connect = try #require(socket.messages.first)
        #expect(connect["type"] == .string("Connect"))
        #expect(connect["connectionCount"] == .float64(0))
        #expect(connect["lastCloseReason"] == .string("InitialConnect"))
        #expect(connect["sessionId"]?.stringValue?.count == 36)

        let modify = try #require(socket.messages(ofType: "ModifyQuerySet").first)
        #expect(modify["baseVersion"] == .float64(0))
        #expect(modify["newVersion"] == .float64(1))
        guard case .array(let mods) = modify["modifications"], let add = mods.first else { Issue.record("no Add"); return }
        #expect(add["type"] == .string("Add"))
        #expect(add["udfPath"] == .string("devices:list"))
        #expect(add["args"] == .array([.object(["token": .string("t")])]))
        let queryID = Int(try #require(add["queryId"]?.doubleValue))

        socket.receive(transition(from: (0, 0), to: (1, 5), updated(queryID, #"{"n":{"$integer":"BwAAAAAAAAA="}}"#)))
        #expect(await eventually { results.items.count == 1 })
        #expect(try results.items[0].get() == .object(["n": .int64(7)]))

        socket.receive(transition(from: (1, 5), to: (1, 9), updated(queryID, #"{"n":2}"#)))
        #expect(await eventually { results.items.count == 2 })
        #expect(try results.items[1].get() == .object(["n": .float64(2)]))
        #expect(await client.status.state == .connected)
        await client.stop()
    }

    @Test func mutationsResolveOnlyAfterTheirTransition() async throws {
        let transport = FakeTransport()
        let client = makeClient(transport)
        await client.start()
        #expect(await eventually { transport.sockets.count == 1 })
        let socket = transport.sockets[0]
        socket.open()
        #expect(await eventually { socket.messages(ofType: "ModifyQuerySet").count == 1 })
        socket.receive(transition(from: (0, 0), to: (1, 1)))

        let order = Collector<String>()
        let first = Task { let r = try await client.mutation("playback:publish", args: .object([:])); order.add("first"); return r }
        #expect(await eventually { socket.messages(ofType: "Mutation").count == 1 })
        let second = Task { let r = try await client.mutation("devices:heartbeat", args: .object([:])); order.add("second"); return r }
        #expect(await eventually { socket.messages(ofType: "Mutation").count == 2 })
        let ids = socket.messages(ofType: "Mutation").compactMap { $0["requestId"]?.doubleValue }.map(Int.init)
        #expect(ids == [0, 1])
        #expect(socket.messages(ofType: "Mutation")[0]["udfPath"] == .string("playback:publish"))

        // Responses arrive out of order; the second's commit timestamp is reached first.
        socket.receive(#"{"type":"MutationResponse","requestId":1,"success":true,"result":{"serverNow":2},"ts":"\#(ts(20))","logLines":[]}"#)
        socket.receive(#"{"type":"MutationResponse","requestId":0,"success":true,"result":{"serverNow":1},"ts":"\#(ts(30))","logLines":[]}"#)
        try await Task.sleep(for: .milliseconds(50))
        #expect(order.items.isEmpty, "nothing resolves before the client has seen the commit")

        socket.receive(transition(from: (1, 1), to: (1, 25)))
        #expect(await eventually { order.items == ["second"] })
        socket.receive(transition(from: (1, 25), to: (1, 30)))
        #expect(await eventually { order.items == ["second", "first"] })
        #expect(try await first.value.value == .object(["serverNow": .float64(1)]))
        #expect(try await second.value.value == .object(["serverNow": .float64(2)]))

        // A failure resolves at once with the ConvexError payload.
        let failing = Task { try await client.mutation("devices:rename", args: .object([:])) }
        #expect(await eventually { socket.messages(ofType: "Mutation").count == 3 })
        socket.receive(#"{"type":"MutationResponse","requestId":2,"success":false,"result":"Uncaught ConvexError","logLines":[],"errorData":{"code":"notFound","message":"No such device in this library."}}"#)
        let error = await #expect(throws: ConvexClientError.self) { try await failing.value }
        #expect(error?.code == "notFound")
        #expect(error?.localizedDescription == "No such device in this library.")
        await client.stop()
    }

    @Test func reconnectReplaysQueriesAndUnansweredMutations() async throws {
        let transport = FakeTransport()
        let client = makeClient(transport)
        let results = Collector<ConvexClient.QueryResult>()
        let consumer = results.consume(client.subscribe("playback:list", args: .object(["token": .string("t")])))
        defer { consumer.cancel() }
        await client.start()
        #expect(await eventually { transport.sockets.count == 1 })
        let first = transport.sockets[0]
        first.open()
        #expect(await eventually { first.messages(ofType: "ModifyQuerySet").count == 1 })
        let queryID = Int(first.messages(ofType: "ModifyQuerySet")[0]["modifications"].flatMap { if case .array(let a) = $0 { a.first?["queryId"]?.doubleValue } else { nil } } ?? -1)
        first.receive(transition(from: (0, 0), to: (1, 10), updated(queryID, "1")))
        #expect(await eventually { results.items.count == 1 })

        let pending = Task { try await client.mutation("commands:send", args: .object(["x": .float64(1)])) }
        #expect(await eventually { first.messages(ofType: "Mutation").count == 1 })

        first.serverClose("network down")
        #expect(await eventually { transport.sockets.count == 2 })
        let second = transport.sockets[1]
        second.open()
        #expect(await eventually { second.messages(ofType: "Mutation").count == 1 })

        let connect = try #require(second.messages.first)
        #expect(connect["type"] == .string("Connect"))
        #expect(connect["connectionCount"] == .float64(1))
        #expect(connect["lastCloseReason"] == .string("network down"))
        #expect(connect["sessionId"] == first.messages.first?["sessionId"])
        #expect(connect["maxObservedTimestamp"] == .string(ts(10)))

        let replay = try #require(second.messages(ofType: "ModifyQuerySet").first)
        #expect(replay["baseVersion"] == .float64(0))
        #expect(replay["newVersion"] == .float64(1))
        guard case .array(let mods) = replay["modifications"] else { Issue.record("no modifications"); return }
        #expect(mods.map { $0["queryId"] } == [.float64(Double(queryID))])
        #expect(second.messages(ofType: "Mutation")[0]["requestId"] == .float64(0))

        // The new socket starts again from version zero.
        second.receive(transition(from: (0, 0), to: (1, 40), updated(queryID, "2")))
        second.receive(#"{"type":"MutationResponse","requestId":0,"success":true,"result":"done","ts":"\#(ts(35))","logLines":[]}"#)
        #expect(try await pending.value.value == .string("done"))
        #expect(await eventually { results.items.count == 2 })
        #expect(await client.status.connections == 2)
        await client.stop()
    }

    @Test func aTransitionFromTheWrongVersionRestartsTheSocket() async throws {
        let transport = FakeTransport()
        let client = makeClient(transport)
        await client.start()
        #expect(await eventually { transport.sockets.count == 1 })
        transport.sockets[0].open()
        #expect(await eventually { transport.sockets[0].messages(ofType: "ModifyQuerySet").count == 1 })
        transport.sockets[0].receive(transition(from: (3, 99), to: (4, 100)))
        #expect(await eventually { transport.sockets[0].isClosed })
        #expect(await eventually { transport.sockets.count == 2 })
        await client.stop()
    }

    @Test func chunkedTransitionsAreReassembled() async throws {
        let transport = FakeTransport()
        let client = makeClient(transport)
        let results = Collector<ConvexClient.QueryResult>()
        let consumer = results.consume(client.subscribe("q:a", args: .object([:])))
        defer { consumer.cancel() }
        await client.start()
        #expect(await eventually { transport.sockets.count == 1 })
        let socket = transport.sockets[0]
        socket.open()
        #expect(await eventually { socket.messages(ofType: "ModifyQuerySet").count == 1 })
        let full = transition(from: (0, 0), to: (1, 3), updated(1, #""a long value""#))
        let mid = full.index(full.startIndex, offsetBy: full.count / 2)
        for (i, part) in [String(full[..<mid]), String(full[mid...])].enumerated() {
            let chunk = ConvexValue.object(["type": .string("TransitionChunk"), "chunk": .string(part), "partNumber": .float64(Double(i)),
                                            "totalParts": .float64(2), "transitionId": .string("x")]).jsonString()
            socket.receive(chunk)
        }
        #expect(await eventually { results.items.count == 1 })
        #expect(try results.items[0].get() == .string("a long value"))
        await client.stop()
    }

    @Test func pingsKeepTheSocketAndNothingBreaks() async throws {
        let transport = FakeTransport()
        var options = ConvexClient.Options()
        options.inactivityTimeout = .milliseconds(150)
        options.initialBackoff = .milliseconds(10)
        options.jitter = false
        let client = ConvexClient(deploymentURL: URL(string: "https://x.convex.cloud")!, transport: transport, http: FakeHTTP(), options: options)
        await client.start()
        #expect(await eventually { transport.sockets.count == 1 })
        transport.sockets[0].open()
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(80))
            transport.sockets[0].receive(#"{"type":"Ping"}"#)
        }
        #expect(transport.sockets.count == 1)
        // Silence past the inactivity timeout reconnects.
        #expect(await eventually { transport.sockets.count == 2 })
        await client.stop()
    }

    @Test func fallsBackToHTTPWhenTheSocketCantConnect() async throws {
        let transport = FakeTransport()
        transport.autoFail = true
        let http = FakeHTTP()
        http.respond = { path, body in
            if path.hasSuffix("/api/query") {
                return .object(["status": .string("success"), "value": .object(["path": body["path"] ?? .null])])
            }
            return .object(["status": .string("success"), "value": .object(["serverNow": .float64(123)])])
        }
        let client = makeClient(transport, http: http, fallbackAfter: 3)
        let results = Collector<ConvexClient.QueryResult>()
        let consumer = results.consume(client.subscribe("devices:list", args: .object(["token": .string("t")])))
        defer { consumer.cancel() }
        await client.start()
        #expect(await eventually { await client.status.httpFallback })
        #expect(await eventually { results.items.count == 1 })
        #expect(try results.items[0].get() == .object(["path": .string("devices:list")]))
        let query = try #require(http.requests.first { $0.path == "/api/query" })
        #expect(query.body["format"] == .string("convex_encoded_json"))
        #expect(query.body["args"] == .array([.object(["token": .string("t")])]))

        let result = try await client.mutation("devices:heartbeat", args: .object(["token": .string("t")]))
        #expect(result.value == .object(["serverNow": .float64(123)]))
        #expect(http.requests.contains { $0.path == "/api/mutation" })

        // Unchanged poll results aren't delivered again; the poll stops in the background.
        try await Task.sleep(for: .milliseconds(150))
        #expect(results.items.count == 1)
        await client.setForeground(false)
        try await Task.sleep(for: .milliseconds(30)) // a request already in flight may still land
        let before = http.requests.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(http.requests.count == before, "background polls: \(http.requests.dropFirst(before).map(\.path))")

        // Once the socket connects again, the fallback ends.
        transport.autoFail = false
        #expect(await eventually { transport.sockets.last.map { !$0.isClosed } ?? false })
        transport.sockets.last?.open()
        #expect(await eventually { await client.status == .init(state: .connected, httpFallback: false, connections: 1) })
        await client.stop()
    }

    @Test func aMutationTheSocketNeverAnsweredFinishesOverHTTPWhenTheFallbackStarts() async throws {
        let transport = FakeTransport()
        let http = FakeHTTP()
        http.respond = { _, _ in .object(["status": .string("success"), "value": .object(["serverNow": .float64(7)])]) }
        let client = makeClient(transport, http: http, fallbackAfter: 1)
        await client.start()
        #expect(await eventually { transport.sockets.count == 1 })
        let socket = transport.sockets[0]
        socket.open()
        #expect(await eventually { socket.messages(ofType: "ModifyQuerySet").count == 1 })
        socket.receive(transition(from: (0, 0), to: (1, 1)))

        let pending = Task { try await client.mutation("commands:send", args: .object(["clientId": .string("c-1")])) }
        #expect(await eventually { socket.messages(ofType: "Mutation").count == 1 })
        // The socket dies before the answer arrives and can't reconnect.
        transport.autoFail = true
        socket.serverClose("network down")

        let result = try await pending.value
        #expect(result.value == .object(["serverNow": .float64(7)]))
        let retried = try #require(http.requests.first { $0.path == "/api/mutation" })
        #expect(retried.body["path"] == .string("commands:send"))
        #expect(retried.body["args"] == .array([.object(["clientId": .string("c-1")])]), "the retry carries the same client id")
        await client.stop()
    }

    @Test func aMutationWithNoAnswerFailsAfterTheTimeout() async throws {
        let transport = FakeTransport()
        var options = fastOptions()
        options.mutationTimeout = .milliseconds(150)
        let client = ConvexClient(deploymentURL: URL(string: "https://x.convex.cloud")!, transport: transport, http: FakeHTTP(), options: options)
        await client.start()
        #expect(await eventually { transport.sockets.count == 1 })
        transport.sockets[0].open()
        let started = ContinuousClock.now
        await #expect(throws: ConvexClientError.self) { try await client.mutation("playback:publish", args: .object([:])) }
        #expect(ContinuousClock.now - started < .seconds(2))
        // It isn't replayed on the next socket either.
        transport.sockets[0].serverClose()
        #expect(await eventually { transport.sockets.count == 2 })
        transport.sockets[1].open()
        try await Task.sleep(for: .milliseconds(50))
        #expect(transport.sockets[1].messages(ofType: "Mutation").isEmpty)
        await client.stop()
    }

    @Test func aPollAfterTheSocketDeliveredNewerValuesIsNotDroppedAsUnchanged() async throws {
        let transport = FakeTransport()
        transport.autoFail = true
        let polled = Box<ConvexValue>(.float64(1))
        let http = FakeHTTP()
        http.respond = { _, _ in .object(["status": .string("success"), "value": polled.value]) }
        let client = makeClient(transport, http: http, fallbackAfter: 3)
        let results = Collector<ConvexClient.QueryResult>()
        let consumer = results.consume(client.subscribe("q:x", args: .object([:])))
        defer { consumer.cancel() }
        await client.start()
        #expect(await eventually { results.items.count == 1 })
        #expect(try results.items[0].get() == .float64(1))

        // The socket comes back and delivers a newer value.
        transport.autoFail = false
        #expect(await eventually { transport.sockets.last.map { !$0.isClosed } ?? false })
        let socket = try #require(transport.sockets.last)
        socket.open()
        #expect(await eventually { socket.messages(ofType: "ModifyQuerySet").count == 1 })
        let queryID = Int(socket.messages(ofType: "ModifyQuerySet")[0]["modifications"].flatMap { if case .array(let a) = $0 { a.first?["queryId"]?.doubleValue } else { nil } } ?? -1)
        socket.receive(transition(from: (0, 0), to: (1, 5), updated(queryID, "2")))
        #expect(await eventually { results.items.count == 2 })

        // The socket drops for good; the value went back to 1 meanwhile. The poll must deliver it.
        transport.autoFail = true
        socket.serverClose()
        #expect(await eventually { await client.status.httpFallback })
        #expect(await eventually { results.items.count == 3 })
        #expect(try results.items.last?.get() == .float64(1))
        await client.stop()
    }

    @Test func suspendClosesTheSocketKeepsTheQueriesAndStartResumes() async throws {
        let transport = FakeTransport()
        let client = makeClient(transport)
        let results = Collector<ConvexClient.QueryResult>()
        let consumer = results.consume(client.subscribe("devices:list", args: .object([:])))
        defer { consumer.cancel() }
        await client.start()
        #expect(await eventually { transport.sockets.count == 1 })
        transport.sockets[0].open()
        await client.suspend()
        #expect(transport.sockets[0].isClosed)
        #expect(await client.status.state == .idle)
        try await Task.sleep(for: .milliseconds(100))
        #expect(transport.sockets.count == 1, "no reconnects while suspended")
        await client.start()
        #expect(await eventually { transport.sockets.count == 2 })
        transport.sockets[1].open()
        #expect(await eventually { transport.sockets[1].messages(ofType: "ModifyQuerySet").count == 1 })
        await client.stop()
    }
}

@MainActor
@Suite(.serialized) struct SyncServiceActivityTests {
    func makeService(_ transport: FakeTransport, _ http: FakeHTTP) -> SyncService {
        let url = URL(string: "https://example-123.convex.cloud")!
        let credentials = SyncCredentials(deviceID: DeviceID("d1"), libraryID: LibraryID(rawValue: "l1"),
                                          token: String(repeating: "t", count: 43), deploymentURL: url)
        return SyncService(deploymentURL: url, deviceInfo: DeviceInfo(name: "Test", platform: .mac, model: "t", appVersion: "1"),
                           credentials: MemoryCredentialStore(credentials), transport: transport, http: http,
                           options: fastOptions(fallbackAfter: 1))
    }

    @Test func theFallbackPollKeepsRunningInTheBackgroundWhilePlaying() async throws {
        let transport = FakeTransport()
        transport.autoFail = true
        let http = FakeHTTP()
        let service = makeService(transport, http)
        let queries: @Sendable () -> Int = { http.requests.filter { $0.path == "/api/query" }.count }
        service.start()
        #expect(await eventually { queries() > 0 })

        service.setForeground(false)
        try await Task.sleep(for: .milliseconds(80))
        let idle = queries()
        try await Task.sleep(for: .milliseconds(200))
        #expect(queries() == idle, "no polling in the background while paused")

        // Playing in the background: incoming commands must still arrive.
        service.setPlaying(true)
        #expect(await eventually { queries() > idle + 5 })
        service.stop()
    }

    @Test func inTheBackgroundWhilePausedTheSocketClosesAfterAGraceAndReopensOnReturn() async throws {
        let transport = FakeTransport()
        let service = makeService(transport, FakeHTTP())
        service.suspendsInBackground = true
        service.backgroundGrace = .milliseconds(50)
        service.start()
        #expect(await eventually { transport.sockets.count == 1 })
        transport.sockets[0].open()

        service.setForeground(false)
        #expect(await eventually { transport.sockets[0].isClosed })
        #expect(await service.client.status.state == .idle)
        try await Task.sleep(for: .milliseconds(150))
        #expect(transport.sockets.count == 1, "nothing reconnects while suspended")

        service.setForeground(true)
        #expect(await eventually { transport.sockets.count == 2 })
        transport.sockets[1].open()

        // Playing in the background keeps the socket.
        service.setPlaying(true)
        service.setForeground(false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!transport.sockets[1].isClosed)
        service.stop()
    }
}
