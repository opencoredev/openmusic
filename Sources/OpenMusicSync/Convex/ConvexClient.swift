import Foundation
import Synchronization

/// The identity a call is made for, as `ConvexClient.setAuth` returned it. A call made with a scope that is no longer
/// the client's is refused (`ConvexClientError.authChanged`) instead of going out under whoever is signed in now.
public struct AuthScope: Sendable, Equatable {
    let value: Int
}

public enum ConvexClientError: LocalizedError, Sendable, Equatable {
    /// The function threw. `data` is the `ConvexError` payload when it threw one.
    case function(message: String, data: ConvexValue?)
    case transport(String)
    case http(status: Int, body: String)
    case decoding(String)
    case stopped
    /// The signed-in identity changed before this mutation was sent: it was made for the previous one, so it is
    /// never sent under the new one.
    case authChanged

    /// `data.code` of a `ConvexError({ code, message })` thrown by the backend.
    public var code: String? {
        if case .function(_, let data) = self { return data?["code"]?.stringValue }
        return nil
    }

    public var errorDescription: String? {
        switch self {
        case .function(let message, let data): data?["message"]?.stringValue ?? message
        case .transport(let why): "Can't reach the sync server: \(why)"
        case .http(let status, _): "Sync server error \(status)."
        case .decoding(let why): "Unexpected sync response: \(why)"
        case .stopped: "Sync is stopped."
        case .authChanged: "The account changed before this was sent."
        }
    }
}

/// A value with the local times its request left and its response arrived (for clock offset estimates).
public struct Timed<Value: Sendable>: Sendable {
    public var value: Value
    public var sentAt: Date
    public var receivedAt: Date
}

/// A small Convex client speaking the WebSocket sync protocol, with no dependencies.
///
/// - Query subscriptions: `subscribe` returns a stream of results; the newest one wins.
/// - Mutations resolve once the server's transitions reach the mutation's commit timestamp (read your writes).
/// - Reconnects with jittered exponential backoff (1 s doubling to 16 s) and replays the query set and unanswered
///   mutations on the new socket. 60 s without any server message (the server pings) counts as a dead socket.
/// - After 3 failed connection attempts in a row it also serves queries over HTTP (`POST /api/query`, a slow poll)
///   and mutations over `POST /api/mutation`, while the socket keeps retrying. Mutations the socket sent but never
///   answered are retried over HTTP then, so the backend functions they call must be idempotent. The poll only runs
///   while `setForeground(true)` (the service passes "in the foreground or playing"). A poll answer that arrives
///   after the socket came back is dropped: the socket's results are newer.
/// - Every mutation has one lifecycle and one deadline whichever transport carries it: it completes within
///   `Options.mutationTimeout` (then throws `ConvexClientError.transport`), `stop()` fails it with `.stopped`, and an
///   answer arriving after either is dropped.
/// - `suspend()` closes the socket and stops reconnecting, keeping the query set; `start()` resumes.
/// - Every mutation belongs to the identity it was made under (`setAuth`). When the identity changes, mutations not
///   yet sent fail with `.authChanged`, and one already sent under the old identity is never sent again (a replay on
///   a new socket, or over HTTP, would carry the new identity): it fails with `.authChanged` instead.
/// - A call goes out only with a token of its own identity. On an identity change the old token is forgotten and the
///   socket drops its identity at once; calls of the new identity wait until its token is here (they time out if it
///   never comes), and a token whose `sub` isn't the identity `setAuth` named is never used. That `sub` is read
///   unverified: a routing guard for the client's own calls, not authentication (Convex verifies the token).
public actor ConvexClient {
    public struct Options: Sendable {
        public var initialBackoff: Duration = .seconds(1)
        public var maxBackoff: Duration = .seconds(16)
        public var inactivityTimeout: Duration = .seconds(60)
        public var pollInterval: Duration = .seconds(15)
        public var fallbackAfterFailures = 3
        public var jitter = true
        /// A mutation that has no answer after this long throws `.transport` (and is not replayed later).
        public var mutationTimeout: Duration = .seconds(30)
        /// How long to wait before asking the token provider again after it couldn't answer (offline).
        public var authRetryDelay: Duration = .seconds(5)

        public init() {}
    }

    public enum ConnectionState: Sendable, Equatable {
        case idle
        case connecting
        case connected
        case waitingToReconnect(attempt: Int)
        case stopped
    }

    public struct Status: Sendable, Equatable {
        public var state: ConnectionState
        /// True while queries are polled and mutations sent over HTTP because the socket can't connect.
        public var httpFallback: Bool
        /// Sockets opened so far (1 after the first connect).
        public var connections: Int
        /// Whether calls carry the signed-in user's identity.
        public var auth: AuthState = .none
    }

    public typealias QueryResult = Result<ConvexValue, ConvexClientError>

    public nonisolated let deploymentURL: URL
    private let transport: any WebSocketTransport
    private let http: any HTTPPoster
    private let options: Options
    private let sessionID = UUID().uuidString.lowercased()

    // Connection
    private var connection: (any WebSocketConnection)?
    private var generation = 0
    private var openedThisAttempt = false
    private var state: ConnectionState = .idle
    private var httpFallback = false
    private var isForeground = true
    private var connectionCount = 0
    private var lastCloseReason: String? = "InitialConnect"
    private var retries = 0
    private var consecutiveFailures = 0
    private var blockedUntil: ContinuousClock.Instant?
    private var eventTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var inactivityTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var statusObservers: [Int: AsyncStream<Status>.Continuation] = [:]

    // Authentication
    private var authProvider: (any AuthTokenProvider)?
    private var authToken: AuthToken?
    private var authState: AuthState = .none
    /// The client's identity version: 0 on a fresh socket without a token, +1 for every `Authenticate` sent.
    private var identityVersion = 0
    /// AuthErrors since the server last accepted a token. Past `maxAuthRefusals` the client gives up.
    private var authRefusals = 0
    private var authRefreshTask: Task<Void, Never>?
    /// Bumped by `setAuth`, so a token fetched for an older provider is dropped.
    private var authEpoch = 0
    /// The identity mutations are made for: bumped by `setAuth` whenever the identity changes. Each mutation records
    /// the scope it was made in and is never sent in another.
    private var authScope = 0
    /// Who `setAuth` last said the identity is (nil when unknown or signed out).
    private var authIdentity: String?
    /// A provider is set but its token isn't here yet (just set for a new identity, offline, or refused by the
    /// server): calls wait, so none goes out without its identity's token or with another identity's.
    private var identityPending = false
    /// The token the open socket last authenticated with; nil when it has no identity.
    private var socketToken: String?
    private static let maxAuthRefusals = 2

    // Queries
    private struct LocalQuery {
        let path: String
        let args: ConvexValue
        var journal: String?
        /// The last value handed to the subscriber, over either transport. A poll that returns it again is dropped.
        var lastDelivered: ConvexValue?
        let deliver: @Sendable (QueryResult) -> Void
        /// The identity it was subscribed for (`AuthScope.value`), or nil for a query of any identity.
        let scope: Int?
    }
    private var queries: [Int: LocalQuery] = [:]
    /// Queries of an identity that is no longer current: out of the query set and never polled again, kept here only
    /// until their subscriber unsubscribes (`removeQuery`).
    private var retiredQueries: Set<Int> = []
    private var cancelledQueries: Set<Int> = []
    private nonisolated let ids = Mutex(0)
    private var querySetVersion = 0
    private var remoteVersion = StateVersion.initial
    private var maxObservedTimestamp: ConvexTimestamp?
    private var chunks: (id: String, total: Int, parts: [String])?

    // Mutations
    private enum RequestStatus {
        case notSent
        case requested
        case completed(ts: ConvexTimestamp, value: ConvexValue, receivedAt: Date)
        /// In flight over HTTP; `finishHTTP` completes it unless the deadline or `stop()` came first.
        case http
    }
    private struct PendingRequest {
        let path: String
        let args: ConvexValue
        let message: String
        var status: RequestStatus
        var sentAt: Date
        let continuation: CheckedContinuation<Timed<ConvexValue>, any Error>
        var timeout: Task<Void, Never>?
        var httpTask: Task<Void, Never>?
        /// `authScope` when the mutation was made.
        let scope: Int

        /// Stops the deadline and any HTTP attempt; the caller resumes the continuation.
        func cancelTasks() {
            timeout?.cancel()
            httpTask?.cancel()
        }
    }
    private var requests: [Int: PendingRequest] = [:]
    private var nextRequestID = 0
    /// Bumped whenever a socket opens. An HTTP poll that started before is answered from an older snapshot than
    /// what the socket delivers, so its result is dropped.
    private var socketEpoch = 0

    public init(
        deploymentURL: URL,
        transport: any WebSocketTransport = URLSessionWebSocketTransport(),
        http: any HTTPPoster = URLSessionHTTPPoster(),
        options: Options = Options()
    ) {
        self.deploymentURL = deploymentURL
        self.transport = transport
        self.http = http
        self.options = options
    }

    /// `wss://<deployment>/api/<npm version>/sync`, as the npm client builds it.
    public nonisolated var syncURL: URL {
        var components = URLComponents(url: deploymentURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/api/\(ConvexClient.protocolVersion)/sync"
        return components.url!
    }

    /// The npm client version whose protocol this client speaks.
    public static let protocolVersion = "1.49.0"

    // MARK: Lifecycle

    public func start() {
        guard state == .idle || state == .stopped else { return }
        state = .connecting
        openSocket()
    }

    /// Closes the socket and stops reconnecting. Pending mutations fail with `.stopped`.
    public func stop() {
        state = .stopped
        generation += 1
        connection?.close()
        connection = nil
        for task in [eventTask, reconnectTask, inactivityTask, pollTask, authRefreshTask] { task?.cancel() }
        authRefreshTask = nil
        pollTask = nil
        httpFallback = false
        for (_, request) in requests {
            request.cancelTasks()
            request.continuation.resume(throwing: ConvexClientError.stopped)
        }
        requests.removeAll()
        publishStatus()
    }

    /// Closes the socket and stops reconnecting (the app is in the background and not playing), keeping the query
    /// set and unanswered mutations. `start()` (which `SyncService` calls before every mutation) reconnects and
    /// replays both. State is `.idle` meanwhile.
    public func suspend() {
        guard state != .stopped, state != .idle else { return }
        generation += 1
        connection?.close()
        connection = nil
        for task in [eventTask, reconnectTask, inactivityTask, pollTask] { task?.cancel() }
        pollTask = nil
        httpFallback = false
        consecutiveFailures = 0
        retries = 0
        lastCloseReason = "Suspended"
        setState(.idle)
        publishStatus()
    }

    /// Gates the HTTP fallback poll: it only runs while this is true (in the foreground, or playing in the background).
    public func setForeground(_ foreground: Bool) {
        isForeground = foreground
        if foreground { updatePolling(pollNow: true) } else { pollTask?.cancel(); pollTask = nil }
    }

    /// Reconnect right away if waiting on a backoff (for example when the app comes to the foreground).
    /// Reconnects at once if waiting on a backoff. With `force`, a connected socket is also replaced: after a sleep
    /// it may have died without a close, and would otherwise sit until the inactivity timeout.
    public func reconnectNow(force: Bool = false) {
        if force, state == .connected { restart(reason: "Reconnect") }
        guard case .waitingToReconnect = state else { return }
        reconnectTask?.cancel()
        attemptReconnect()
    }

    /// Testing aid: drops the socket as a network loss would and refuses to reconnect (socket and HTTP) for `duration`.
    public func simulateNetworkLoss(for duration: Duration) {
        blockedUntil = .now + duration
        if let connection {
            connection.close()
        }
    }

    public var status: Status { Status(state: state, httpFallback: httpFallback, connections: connectionCount, auth: authState) }

    public nonisolated func statusUpdates() -> AsyncStream<Status> {
        let id = ids.withLock { value in value += 1; return value }
        let (stream, continuation) = AsyncStream.makeStream(of: Status.self, bufferingPolicy: .bufferingNewest(8))
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        Task { await self.addObserver(id, continuation) }
        return stream
    }

    private func addObserver(_ id: Int, _ continuation: AsyncStream<Status>.Continuation) {
        statusObservers[id] = continuation
        continuation.yield(status)
    }

    private func removeObserver(_ id: Int) { statusObservers[id] = nil }

    private func publishStatus() {
        let s = status
        for continuation in statusObservers.values { continuation.yield(s) }
    }

    private func setState(_ new: ConnectionState) {
        guard new != state else { return }
        state = new
        publishStatus()
    }

    // MARK: Socket

    private var isBlocked: Bool {
        guard let until = blockedUntil else { return false }
        if ContinuousClock.now >= until { blockedUntil = nil; return false }
        return true
    }

    private func openSocket() {
        generation += 1
        let gen = generation
        openedThisAttempt = false
        setState(.connecting)
        // A token that expired while the socket was closed (suspended in the background, or refused by the server)
        // is replaced before the socket opens, so the server never sees a stale one.
        if let provider = authProvider, authToken == nil || authToken?.needsRefresh() == true, !isBlocked {
            let epoch = authEpoch
            Task { [weak self] in
                let token: TokenFetch
                do { token = .fetched(try await provider.token(forceRefresh: true)) } catch { token = .unavailable }
                await self?.openAfterRefresh(token, epoch: epoch, generation: gen)
            }
            return
        }
        connectSocket(generation: gen)
    }

    private func openAfterRefresh(_ token: TokenFetch, epoch: Int, generation gen: Int) {
        guard gen == generation, state == .connecting else { return }
        if epoch == authEpoch {
            switch token {
            case .fetched(let value?): _ = accept(value)
            case .fetched(nil): signedOutByProvider()
            case .unavailable: break   // Offline: connect with what there is; the server says if it's stale.
            }
        }
        connectSocket(generation: gen)
    }

    private func connectSocket(generation gen: Int) {
        if isBlocked {
            Task { self.handle(.closed(reason: "network unavailable"), generation: gen) }
            return
        }
        let (conn, events) = transport.connect(to: syncURL)
        connection = conn
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event, generation: gen)
            }
        }
    }

    func handle(_ event: WebSocketEvent, generation gen: Int) {
        guard gen == generation, state != .stopped else { return }
        switch event {
        case .opened:
            didOpen()
        case .message(let text):
            resetInactivity()
            do {
                try handleMessage(try ServerMessage.parse(text))
            } catch {
                restart(reason: "protocol error: \(error)")
            }
        case .closed(let reason):
            didClose(reason: reason)
        }
    }

    private func didOpen() {
        openedThisAttempt = true
        socketEpoch += 1
        consecutiveFailures = 0
        connection?.send(ClientMessage.connect(
            sessionID: sessionID, connectionCount: connectionCount, lastCloseReason: lastCloseReason,
            maxObservedTimestamp: maxObservedTimestamp, clientTs: Date().timeIntervalSince1970 * 1000))
        connectionCount += 1
        lastCloseReason = nil

        // The identity comes first, so the queries and replayed mutations below run as the signed-in user.
        if let token = authToken {
            connection?.send(ClientMessage.authenticate(token: token.value, baseVersion: 0))
            identityVersion = 1
            socketToken = token.value
            setAuthState(.pending)
            scheduleAuthRefresh()
        } else {
            identityVersion = 0
            socketToken = nil
        }

        // A fresh socket starts from an empty query set: add everything again.
        remoteVersion = .initial
        querySetVersion = 1
        chunks = nil
        let adds = queries.keys.sorted().map { id in
            let q = queries[id]!
            return ClientMessage.Add(queryID: id, path: q.path, args: q.args, journal: q.journal)
        }
        connection?.send(ClientMessage.modifyQuerySet(base: 0, new: 1, adds: adds, removes: []))

        // Replay unanswered and unconfirmed mutations; the server dedupes them by session and request id. One
        // already in flight over HTTP finishes there.
        for id in requests.keys.sorted() {
            guard var request = requests[id] else { continue }
            if case .http = request.status { continue }
            guard request.scope == authScope else {
                failForIdentity(id)
                continue
            }
            guard maySendOnSocket(scope: request.scope) else {
                // Its identity's token isn't here yet: it waits (`flushHeld`).
                request.status = .notSent
                requests[id] = request
                continue
            }
            if case .notSent = request.status { request.status = .requested; request.sentAt = Date() }
            requests[id] = request
            connection?.send(request.message)
        }
        httpFallback = false
        pollTask?.cancel()
        pollTask = nil
        setState(.connected)
        publishStatus()
        resetInactivity()
    }

    private func didClose(reason: String) {
        connection = nil
        inactivityTask?.cancel()
        if !openedThisAttempt { consecutiveFailures += 1 }
        lastCloseReason = String(reason.prefix(120))
        if consecutiveFailures >= options.fallbackAfterFailures, !httpFallback {
            httpFallback = true
            flushPendingOverHTTP()
            updatePolling(pollNow: true)
        }
        scheduleReconnect()
    }

    /// Closes the current socket and reconnects after a backoff.
    private func restart(reason: String) {
        let old = connection
        generation += 1
        connection = nil
        old?.close()
        didClose(reason: reason)
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let base = options.initialBackoff * (1 << min(retries, 10))
        var delay = min(base, options.maxBackoff)
        if options.jitter { delay = delay * Double.random(in: 0.5...1.0) }
        retries += 1
        setState(.waitingToReconnect(attempt: retries))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.attemptReconnect()
        }
    }

    private func attemptReconnect() {
        guard case .waitingToReconnect = state else { return }
        openSocket()
    }

    private func resetInactivity() {
        inactivityTask?.cancel()
        let gen = generation
        let timeout = options.inactivityTimeout
        inactivityTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.inactivityFired(generation: gen)
        }
    }

    private func inactivityFired(generation gen: Int) {
        guard gen == generation, state == .connected else { return }
        restart(reason: "ServerInactivity")
    }

    // MARK: Server messages

    private func handleMessage(_ message: ServerMessage) throws {
        switch message {
        case .ping, .actionResponse:
            break
        case .authError(let message, let baseVersion, _):
            authRefused(message, baseVersion: baseVersion)
        case .fatalError(let error):
            restart(reason: "FatalError: \(error)")
        case .transitionChunk(let chunk, let part, let total, let transitionID):
            if chunks == nil { chunks = (transitionID, total, []) }
            guard var buffer = chunks, buffer.id == transitionID, buffer.total == total, part == buffer.parts.count, total > 0 else {
                chunks = nil
                throw ConvexValueError("TransitionChunk out of order")
            }
            buffer.parts.append(chunk)
            if buffer.parts.count == total {
                chunks = nil
                let full = try ServerMessage.parse(buffer.parts.joined())
                guard case .transition = full else { throw ConvexValueError("Chunks did not form a Transition") }
                try handleMessage(full)
            } else {
                chunks = buffer
            }
        case .transition(let start, let end, let modifications):
            guard start == remoteVersion else {
                throw ConvexValueError("Transition from \(start) but the client is at \(remoteVersion)")
            }
            for modification in modifications {
                switch modification {
                case .updated(let id, let value, let journal):
                    guard queries[id] != nil else { continue }
                    queries[id]?.journal = journal
                    queries[id]?.lastDelivered = value
                    queries[id]?.deliver(.success(value))
                case .failed(let id, let message, let data, let journal):
                    guard queries[id] != nil else { continue }
                    queries[id]?.journal = journal
                    queries[id]?.lastDelivered = nil
                    queries[id]?.deliver(.failure(.function(message: message, data: data)))
                case .removed:
                    break
                }
            }
            if end.identity > start.identity, end.identity == identityVersion { authConfirmed() }
            remoteVersion = end
            observe(end.ts)
            retries = 0
            completeRequests(upTo: end.ts)
        case .mutationSuccess(let id, let value, let ts):
            observe(ts)
            guard var request = requests[id] else { return }
            if case .completed = request.status { return }
            let receivedAt = Date()
            if ts <= remoteVersion.ts {
                requests[id] = nil
                request.cancelTasks()
                request.continuation.resume(returning: Timed(value: value, sentAt: request.sentAt, receivedAt: receivedAt))
            } else {
                request.status = .completed(ts: ts, value: value, receivedAt: receivedAt)
                requests[id] = request
            }
        case .mutationFailure(let id, let message, let data):
            guard let request = requests.removeValue(forKey: id) else { return }
            request.cancelTasks()
            request.continuation.resume(throwing: ConvexClientError.function(message: message, data: data))
        }
    }

    private func observe(_ ts: ConvexTimestamp) {
        if maxObservedTimestamp.map({ $0 < ts }) ?? true { maxObservedTimestamp = ts }
    }

    private func completeRequests(upTo ts: ConvexTimestamp) {
        for (id, request) in requests {
            guard case .completed(let done, let value, let receivedAt) = request.status, done <= ts else { continue }
            requests[id] = nil
            request.cancelTasks()
            request.continuation.resume(returning: Timed(value: value, sentAt: request.sentAt, receivedAt: receivedAt))
        }
    }

    // MARK: Queries

    /// Subscribes to a query. The stream yields the current result and every change; cancel the consuming task
    /// (or drop the stream) to unsubscribe. With `scope` (what `setAuth` returned), the query belongs to that identity:
    /// it is taken out of the query set the moment `setAuth` names another identity (or none), before anything is sent
    /// for the new one, so its arguments (a device token) never go out with another identity's token. Its stream
    /// then yields nothing more.
    public nonisolated func subscribe(_ path: String, args: ConvexValue, scope: AuthScope? = nil) -> AsyncStream<QueryResult> {
        let id = ids.withLock { value in value += 1; return value }
        let (stream, continuation) = AsyncStream.makeStream(of: QueryResult.self, bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in Task { await self?.removeQuery(id) } }
        Task { await self.addQuery(id, path: canonicalUdfPath(path), args: args, scope: scope?.value) { continuation.yield($0) } }
        return stream
    }

    /// Typed subscription: encodes `args` and decodes each result off the main actor.
    public nonisolated func subscribe<Args: Encodable & Sendable, Value: Decodable & Sendable>(
        _ path: String, args: Args, as type: Value.Type, scope: AuthScope? = nil
    ) -> AsyncStream<Result<Value, ConvexClientError>> {
        let id = ids.withLock { value in value += 1; return value }
        let (stream, continuation) = AsyncStream.makeStream(of: Result<Value, ConvexClientError>.self, bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in Task { await self?.removeQuery(id) } }
        let encoded: ConvexValue
        do {
            encoded = try ConvexValue(encoding: args)
        } catch {
            continuation.yield(.failure(.decoding("arguments: \(error)")))
            continuation.finish()
            return stream
        }
        Task {
            await self.addQuery(id, path: canonicalUdfPath(path), args: encoded, scope: scope?.value) { result in
                continuation.yield(result.flatMap { value in
                    do { return .success(try value.decode(Value.self)) } catch { return .failure(.decoding("\(path): \(error)")) }
                })
            }
        }
        return stream
    }

    private func addQuery(_ id: Int, path: String, args: ConvexValue, scope: Int?, deliver: @escaping @Sendable (QueryResult) -> Void) {
        if cancelledQueries.remove(id) != nil { return }
        // Made for an identity that was replaced before the query got here: never added.
        if let scope, scope != authScope {
            retiredQueries.insert(id)
            return
        }
        queries[id] = LocalQuery(path: path, args: args, journal: nil, lastDelivered: nil, deliver: deliver, scope: scope)
        if state == .connected {
            let base = querySetVersion
            querySetVersion += 1
            connection?.send(ClientMessage.modifyQuerySet(base: base, new: querySetVersion, adds: [.init(queryID: id, path: path, args: args)], removes: []))
        } else if httpFallback, isForeground {
            Task { await self.poll(ids: [id]) }
        }
    }

    private func removeQuery(_ id: Int) {
        if retiredQueries.remove(id) != nil { return }
        guard queries.removeValue(forKey: id) != nil else {
            cancelledQueries.insert(id)
            return
        }
        if state == .connected {
            let base = querySetVersion
            querySetVersion += 1
            connection?.send(ClientMessage.modifyQuerySet(base: base, new: querySetVersion, adds: [], removes: [id]))
        }
    }

    /// Runs a query once: on the socket when connected (consistent with subscriptions), else over HTTP.
    public func query(_ path: String, args: ConvexValue) async throws -> ConvexValue {
        guard state == .connected else { return try await httpCall("query", path: path, args: args) }
        let stream = subscribe(path, args: args)
        for await result in stream { return try result.get() }
        throw ConvexClientError.stopped
    }

    public func query<Args: Encodable & Sendable, Value: Decodable & Sendable>(_ path: String, args: Args, as type: Value.Type) async throws -> Value {
        let value = try await query(path, args: try ConvexValue(encoding: args))
        do { return try value.decode(Value.self) } catch { throw ConvexClientError.decoding("\(path): \(error)") }
    }

    // MARK: Mutations

    /// Runs a mutation. `scope` is the identity it was made for (what `setAuth` returned when that identity was set):
    /// the check is made when the mutation is enqueued, inside the actor, so one made for an identity that changed
    /// before it got here fails with `.authChanged` at once instead of taking on the new one. Without `scope`, the
    /// identity current at enqueue time is used. Cancelling the calling task ends the mutation with
    /// `CancellationError`: one not sent yet never is, and the answer to one already sent is ignored.
    public func mutation(_ path: String, args: ConvexValue, scope: AuthScope? = nil) async throws -> Timed<ConvexValue> {
        guard state != .stopped, state != .idle else { throw ConvexClientError.stopped }
        if let scope, scope.value != authScope { throw ConvexClientError.authChanged }
        try Task.checkCancellation()
        let path = canonicalUdfPath(path)
        let id = nextRequestID
        nextRequestID += 1
        let message = ClientMessage.mutation(requestID: id, path: path, args: args)
        let made = authScope
        let connected = state == .connected && maySendOnSocket(scope: made)
        let overHTTP = httpFallback && state != .connected && maySend(scope: made)
        let limit = options.mutationTimeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self] in
                    try? await Task.sleep(for: limit)
                    guard !Task.isCancelled else { return }
                    await self?.timeOut(id)
                }
                requests[id] = PendingRequest(path: path, args: args, message: message, status: connected ? .requested : .notSent,
                                              sentAt: Date(), continuation: continuation, timeout: timeout, scope: made)
                if connected {
                    connection?.send(message)
                } else if overHTTP {
                    sendOverHTTP(id)
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id) }
        }
    }

    /// The caller stopped waiting: the mutation leaves the queue (never sent, or its answer ignored).
    private func cancelRequest(_ id: Int) {
        guard let request = requests.removeValue(forKey: id) else { return }
        request.cancelTasks()
        request.continuation.resume(throwing: CancellationError())
    }

    /// The identity mutations are made for right now (see `setAuth`).
    public var currentScope: AuthScope { AuthScope(value: authScope) }

    private func timeOut(_ id: Int) {
        guard let request = requests.removeValue(forKey: id) else { return }
        request.cancelTasks()
        request.continuation.resume(throwing: ConvexClientError.transport("the sync server didn't answer in time"))
    }

    public func mutation<Args: Encodable & Sendable, Value: Decodable & Sendable>(_ path: String, args: Args, as type: Value.Type,
                                                                                  scope: AuthScope? = nil) async throws -> Timed<Value> {
        let timed = try await mutation(path, args: try ConvexValue(encoding: args), scope: scope)
        do {
            return Timed(value: try timed.value.decode(Value.self), sentAt: timed.sentAt, receivedAt: timed.receivedAt)
        } catch {
            throw ConvexClientError.decoding("\(path): \(error)")
        }
    }

    // MARK: HTTP fallback

    /// The socket is gone for a while: every mutation still waiting on it finishes over HTTP instead. Unsent and
    /// unanswered ones are sent again (the server may have run an unanswered one already, so the functions are
    /// idempotent); one whose answer arrived but whose commit wasn't observed yet resolves with that answer.
    private func flushPendingOverHTTP() {
        for (id, request) in requests.sorted(by: { $0.key < $1.key }) {
            switch request.status {
            case .completed(_, let value, let receivedAt):
                requests[id] = nil
                request.cancelTasks()
                request.continuation.resume(returning: Timed(value: value, sentAt: request.sentAt, receivedAt: receivedAt))
            case .http:
                continue
            case .notSent, .requested:
                if request.scope != authScope {
                    failForIdentity(id)
                } else if maySend(scope: request.scope) {
                    sendOverHTTP(id)
                } else {
                    requests[id]?.status = .notSent   // waits for its identity's token (`flushHeld`)
                }
            }
        }
    }

    /// Sends a pending mutation over HTTP. It stays in `requests`, so its deadline and `stop()` still end it.
    private func sendOverHTTP(_ id: Int) {
        guard var request = requests[id] else { return }
        guard request.scope == authScope else { return failForIdentity(id) }
        guard maySend(scope: request.scope) else { return }   // waits for its identity's token (`flushHeld`)
        request.status = .http
        request.sentAt = Date()
        let path = request.path
        let args = request.args
        let scope = request.scope
        request.httpTask = Task { [weak self] in
            guard let self else { return }
            let result: Result<ConvexValue, any Error>
            do { result = .success(try await self.httpCall("mutation", path: path, args: args, scope: scope)) } catch { result = .failure(error) }
            await self.finishHTTP(id, result)
        }
        requests[id] = request
    }

    /// The HTTP answer for a pending mutation. Dropped when the request already ended (deadline, `stop()`).
    private func finishHTTP(_ id: Int, _ result: Result<ConvexValue, any Error>) {
        guard let request = requests[id], case .http = request.status else { return }
        requests[id] = nil
        request.timeout?.cancel()
        switch result {
        case .success(let value):
            request.continuation.resume(returning: Timed(value: value, sentAt: request.sentAt, receivedAt: Date()))
            // Read your writes: the poll brings what the mutation changed.
            Task { await self.poll(ids: nil) }
        case .failure(let error):
            request.continuation.resume(throwing: error)
        }
    }

    private func updatePolling(pollNow: Bool) {
        guard httpFallback, isForeground, state != .stopped, pollTask == nil else { return }
        let interval = options.pollInterval
        pollTask = Task { [weak self] in
            if !pollNow { try? await Task.sleep(for: interval) }
            while !Task.isCancelled {
                await self?.poll(ids: nil)
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func poll(ids: [Int]?) async {
        guard httpFallback, isForeground, state != .connected else { return }
        for id in ids ?? Array(queries.keys) {
            guard let q = queries[id] else { continue }
            let epoch = socketEpoch
            do {
                let value = try await httpCall("query", path: q.path, args: q.args, scope: q.scope)
                // A socket opened while this was in flight: its results are newer than this answer.
                guard epoch == socketEpoch, httpFallback, state != .connected else { return }
                guard queries[id] != nil, queries[id]?.lastDelivered != value else { continue }
                queries[id]?.lastDelivered = value
                q.deliver(.success(value))
            } catch let error as ConvexClientError {
                guard epoch == socketEpoch, httpFallback, state != .connected else { return }
                if case .function = error {
                    queries[id]?.lastDelivered = nil
                    q.deliver(.failure(error))
                }
            } catch {}
        }
    }

    /// `scope`: the identity a mutation or query was made for. It is sent only with a token of that identity.
    private func httpCall(_ kind: String, path: String, args: ConvexValue, scope: Int? = nil) async throws -> ConvexValue {
        if isBlocked { throw ConvexClientError.transport("network unavailable") }
        let body = ConvexValue.object([
            "path": .string(canonicalUdfPath(path)),
            "format": .string("convex_encoded_json"),
            "args": .array([args]),
        ]).jsonData()
        let url = deploymentURL.appending(path: "api/\(kind)")
        var headers = ["Content-Type": "application/json", "Convex-Client": "medley-swift-\(OpenMusicSync.version)"]
        let token = await tokenForHTTP()
        if let scope {
            guard scope == authScope else { throw ConvexClientError.authChanged }
            guard maySend(scope: scope) else { throw ConvexClientError.transport("not signed in to the sync server yet") }
        }
        // Never a token of another identity than the one calls are made for now.
        if let token {
            guard Self.matches(token.subject, authIdentity) else { throw ConvexClientError.authChanged }
            headers["Authorization"] = "Bearer \(token.value)"
        }
        let response: (body: Data, status: Int)
        do {
            response = try await http.post(url, body: body, headers: headers)
        } catch {
            throw ConvexClientError.transport(error.localizedDescription)
        }
        // 560 is Convex's "the function threw" status.
        guard (200..<300).contains(response.status) || response.status == 560 else {
            throw ConvexClientError.http(status: response.status, body: String(decoding: response.body.prefix(500), as: UTF8.self))
        }
        let parsed: ConvexValue
        do { parsed = try ConvexValue.parse(response.body) } catch { throw ConvexClientError.decoding("\(error)") }
        switch parsed["status"]?.stringValue {
        case "success": return parsed["value"] ?? .null
        case "error": throw ConvexClientError.function(message: parsed["errorMessage"]?.stringValue ?? "error", data: parsed["errorData"])
        default: throw ConvexClientError.decoding("HTTP response without a status")
        }
    }
}

// MARK: - Authentication

/// One answer from the token provider: a token or nil (signed out), or no answer at all (offline).
enum TokenFetch: Sendable {
    case fetched(String?)
    case unavailable
}

extension ConvexClient {
    /// Sets (or, with nil, removes) the source of the user's token. With a provider, the client fetches a token now,
    /// sends it on the open socket and on every new one (before the query set), refreshes it 10 s before it expires,
    /// and answers a server `AuthError` by fetching a fresh one and reconnecting. Removing the provider drops the
    /// identity on the open socket.
    ///
    /// `identity` names who the provider signs in (the app passes the Clerk user id). When it differs from the last
    /// one, or is nil, mutations made for the previous identity are never sent under this one: those not sent yet
    /// fail now with `.authChanged`, and those already sent aren't replayed. The same identity again (a new provider
    /// for the same user) keeps them.
    @discardableResult
    public func setAuth(_ provider: (any AuthTokenProvider)?, identity: String? = nil) async -> AuthScope {
        authEpoch += 1
        let epoch = authEpoch
        let sameIdentity = provider != nil && identity != nil && identity == authIdentity
        authIdentity = provider == nil ? nil : identity
        if !sameIdentity {
            authScope += 1
            for (id, request) in requests where request.scope != authScope {
                if case .notSent = request.status { failForIdentity(id) }
            }
            retireQueries()
            // The old identity's token goes now, and the open socket stops speaking for it, before anything awaits:
            // nothing of the new identity can go out with it, whether or not its own token can be fetched.
            dropIdentity()
        }
        let scope = AuthScope(value: authScope)
        authRefreshTask?.cancel()
        authRefreshTask = nil
        authRefusals = 0
        authProvider = provider
        guard let provider else {
            identityPending = false
            dropIdentity()
            setAuthState(.none)
            flushHeld()
            return scope
        }
        if authToken == nil { identityPending = true }
        let token: TokenFetch
        do { token = .fetched(try await provider.token(forceRefresh: false)) } catch { token = .unavailable }
        guard epoch == authEpoch else { return scope }
        apply(token)
        return scope
    }

    private func apply(_ token: TokenFetch) {
        switch token {
        case .fetched(let value?): adoptToken(value)
        case .fetched(nil): signedOutByProvider()
        case .unavailable: scheduleAuthRetry()
        }
    }

    /// A new token from the provider: used from now on, and sent on the open socket at once. Calls that waited for
    /// it go out after it. A token of another identity than `setAuth` named is refused (and asked for again later).
    private func adoptToken(_ value: String) {
        let changed = authToken?.value != value
        guard accept(value) else { return }
        if changed {
            if state == .connected {
                connection?.send(ClientMessage.authenticate(token: value, baseVersion: identityVersion))
                identityVersion += 1
                socketToken = value
            }
            setAuthState(.pending)
        }
        scheduleAuthRefresh()
        flushHeld()
    }

    /// Keeps `value` as the token if it belongs to the identity calls are made for. Returns whether it did.
    private func accept(_ value: String) -> Bool {
        let token = AuthToken(value)
        guard Self.matches(token.subject, authIdentity) else {
            // A provider answering for someone else: never sent. Calls keep waiting; the provider is asked again.
            scheduleAuthRetry()
            return false
        }
        authToken = token
        identityPending = false
        return true
    }

    /// Whether a token with `subject` may carry calls made for `identity` (nil: the identity wasn't named). A routing
    /// guard on the unverified `sub`, never a security check: the server verifies the token and decides what it may do.
    private static func matches(_ subject: String?, _ identity: String?) -> Bool {
        guard let identity else { return true }
        return subject == identity
    }

    /// Whether a call of `scope` may go out now: it is the current identity's, and either no provider is set (no
    /// identity at all), the provider said signed out (no token to mismatch), or the token in hand is that identity's.
    private func maySend(scope: Int) -> Bool {
        guard scope == authScope else { return false }
        guard authProvider != nil else { return true }
        guard !identityPending else { return false }
        guard let token = authToken else { return true }
        return Self.matches(token.subject, authIdentity)
    }

    /// `maySend`, on the open socket: it also has to be authenticated with that very token (or have no identity when
    /// there is no token).
    private func maySendOnSocket(scope: Int) -> Bool {
        maySend(scope: scope) && socketToken == authToken?.value
    }

    /// Takes the queries of an identity that is no longer current out of the query set (on the open socket too, before
    /// its identity changes), so the server never runs them for the new one and polling never sends them.
    private func retireQueries() {
        let stale = queries.filter { $0.value.scope.map { $0 != authScope } ?? false }.keys.sorted()
        guard !stale.isEmpty else { return }
        for id in stale {
            queries[id] = nil
            retiredQueries.insert(id)
        }
        if state == .connected {
            let base = querySetVersion
            querySetVersion += 1
            connection?.send(ClientMessage.modifyQuerySet(base: base, new: querySetVersion, adds: [], removes: stale))
        }
    }

    /// Sends the calls that waited for their identity's token, now that it's here (or the provider said signed out).
    private func flushHeld() {
        for id in requests.keys.sorted() {
            guard var request = requests[id], case .notSent = request.status, request.scope == authScope else { continue }
            if state == .connected {
                guard maySendOnSocket(scope: request.scope) else { continue }
                request.status = .requested
                request.sentAt = Date()
                requests[id] = request
                connection?.send(request.message)
            } else if httpFallback {
                sendOverHTTP(id)
            }
        }
    }

    /// The provider says signed out: no identity from now on. Calls that waited go out without one.
    private func signedOutByProvider() {
        identityPending = false
        dropIdentity()
        setAuthState(.none)
        flushHeld()
    }

    /// Forgets the token and, on an open socket that has an identity, tells the server.
    private func dropIdentity() {
        authToken = nil
        authRefreshTask?.cancel()
        authRefreshTask = nil
        if socketToken != nil, state == .connected {
            connection?.send(ClientMessage.authenticateNone(baseVersion: identityVersion))
            identityVersion += 1
        }
        socketToken = nil
    }

    private func setAuthState(_ new: AuthState) {
        guard new != authState else { return }
        authState = new
        publishStatus()
    }

    /// The server accepted the identity (a transition advanced it to the version the client is at).
    private func authConfirmed() {
        authRefusals = 0
        setAuthState(authToken == nil ? .none : .authenticated)
    }

    /// `AuthError`: the token was refused (expired, or not from the configured issuer). Fetch a fresh one and
    /// reconnect; after `maxAuthRefusals` refusals in a row, give up and run without an identity.
    private func authRefused(_ message: String, baseVersion: Int?) {
        guard authProvider != nil, authToken != nil else { return }
        // An error about an identity the client already replaced.
        if let baseVersion, baseVersion + 1 < identityVersion { return }
        authRefusals += 1
        authToken = nil
        authRefreshTask?.cancel()
        authRefreshTask = nil
        if authRefusals > Self.maxAuthRefusals {
            authProvider = nil
            identityPending = false
            setAuthState(.failed(message.isEmpty ? "The sync server refused the sign-in." : message))
        } else {
            // Calls wait for the fresh token `openSocket` fetches.
            identityPending = true
            setAuthState(.pending)
        }
        // `openSocket` fetches a fresh token first while a provider is set.
        restart(reason: "AuthError")
    }

    /// Refreshes the token `AuthToken.refreshLeeway` before it expires, while a socket is wanted. A suspended or
    /// stopped client refreshes when it opens a socket again (`openSocket`).
    private func scheduleAuthRefresh() {
        authRefreshTask?.cancel()
        guard let refreshAt = authToken?.refreshAt else { authRefreshTask = nil; return }
        let epoch = authEpoch
        authRefreshTask = Task { [weak self] in
            try? await Task.sleep(until: refreshAt, clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.refreshToken(epoch: epoch)
        }
    }

    private func scheduleAuthRetry() {
        authRefreshTask?.cancel()
        let epoch = authEpoch
        let delay = options.authRetryDelay
        authRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.refreshToken(epoch: epoch)
        }
    }

    private func refreshToken(epoch: Int) async {
        guard epoch == authEpoch, let provider = authProvider, state != .stopped, state != .idle else { return }
        let token: TokenFetch
        do { token = .fetched(try await provider.token(forceRefresh: true)) } catch { token = .unavailable }
        guard epoch == authEpoch, state != .stopped else { return }
        apply(token)
    }

    /// The token for an HTTP call, refreshed first when it is about to expire. Only ever a token of the identity
    /// calls are made for now: after an identity change the old one is gone (`setAuth`), and a fetched one counts
    /// only if the identity didn't change while it was fetched and it belongs to that identity.
    private func tokenForHTTP() async -> AuthToken? {
        guard let provider = authProvider else { return nil }
        if let token = authToken, !token.needsRefresh() { return token }
        let epoch = authEpoch
        guard let fresh = try? await provider.token(forceRefresh: true) else { return authToken }
        guard epoch == authEpoch else { return authToken }
        adoptToken(fresh)
        return authToken
    }

    /// Ends a mutation made for an identity that is no longer the client's, without sending it (again).
    private func failForIdentity(_ id: Int) {
        guard let request = requests.removeValue(forKey: id) else { return }
        request.cancelTasks()
        request.continuation.resume(throwing: ConvexClientError.authChanged)
    }

    /// Testing aid: the identity version the client is at.
    var currentIdentityVersion: Int { identityVersion }
}
