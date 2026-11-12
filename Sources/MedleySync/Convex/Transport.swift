import Foundation

/// What a socket reports, in order. `closed` is always the last event.
public enum WebSocketEvent: Sendable, Equatable {
    case opened
    case message(String)
    case closed(reason: String)
}

/// One open (or opening) socket.
public protocol WebSocketConnection: Sendable {
    func send(_ text: String)
    func close()
}

/// Opens sockets. Swapped for a fake in tests.
public protocol WebSocketTransport: Sendable {
    func connect(to url: URL) -> (connection: any WebSocketConnection, events: AsyncStream<WebSocketEvent>)
}

/// POSTs JSON. Swapped for a fake in tests.
public protocol HTTPPoster: Sendable {
    func post(_ url: URL, body: Data, headers: [String: String]) async throws -> (body: Data, status: Int)
}

// MARK: - URLSession implementations

public struct URLSessionWebSocketTransport: WebSocketTransport {
    public init() {}

    public func connect(to url: URL) -> (connection: any WebSocketConnection, events: AsyncStream<WebSocketEvent>) {
        let (stream, continuation) = AsyncStream.makeStream(of: WebSocketEvent.self, bufferingPolicy: .unbounded)
        let connection = URLSessionWebSocketConnection(url: url, continuation: continuation)
        connection.start()
        return (connection, stream)
    }
}

/// A `URLSessionWebSocketTask` with its own delegate session, so open and close are reported.
final class URLSessionWebSocketConnection: NSObject, WebSocketConnection, URLSessionWebSocketDelegate, @unchecked Sendable {
    // Mutable state is guarded by `lock`. URLSession calls the delegate on its own serial queue.
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var finished = false
    private let continuation: AsyncStream<WebSocketEvent>.Continuation
    private let url: URL

    init(url: URL, continuation: AsyncStream<WebSocketEvent>.Continuation) {
        self.url = url
        self.continuation = continuation
    }

    func start() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.setValue("medley-swift-\(MedleySync.version)", forHTTPHeaderField: "Convex-Client")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024
        lock.withLock {
            self.session = session
            self.task = task
        }
        task.resume()
    }

    func send(_ text: String) {
        let task = lock.withLock { self.task }
        task?.send(.string(text)) { [weak self] error in
            if let error { self?.finish("send failed: \(error.localizedDescription)") }
        }
    }

    func close() {
        let task = lock.withLock { self.task }
        task?.cancel(with: .normalClosure, reason: nil)
        finish("closed by client")
    }

    private func receive() {
        let task = lock.withLock { self.task }
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                self.yield(.message(text))
                self.receive()
            case .success(.data(let data)):
                self.yield(.message(String(decoding: data, as: UTF8.self)))
                self.receive()
            case .success:
                self.receive()
            case .failure(let error):
                self.finish(error.localizedDescription)
            }
        }
    }

    private func yield(_ event: WebSocketEvent) {
        let done = lock.withLock { finished }
        if !done { continuation.yield(event) }
    }

    private func finish(_ reason: String) {
        let session: URLSession? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            let s = self.session
            self.session = nil
            self.task = nil
            return s
        }
        guard let session else { return }
        continuation.yield(.closed(reason: reason))
        continuation.finish()
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        yield(.opened)
        receive()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish("server closed (\(closeCode.rawValue))")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        finish(error?.localizedDescription ?? "connection ended")
    }
}

public struct URLSessionHTTPPoster: HTTPPoster {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func post(_ url: URL, body: Data, headers: [String: String]) async throws -> (body: Data, status: Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 20
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
