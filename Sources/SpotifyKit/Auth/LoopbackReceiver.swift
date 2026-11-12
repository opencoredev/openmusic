import Foundation
import OpenMusicCore
import Network

/// One-shot HTTP listener on 127.0.0.1 that catches the OAuth redirect (RFC 8252 loopback redirect).
///
/// Binds only to the loopback interface, answers the first request to `path` that carries `code` or `error` with a
/// small page, and shuts down. Anything else (a browser asking for /favicon.ico, a prefetch of the bare path) gets
/// a 404 or 400 and is ignored, so a stray request can't end the sign-in.
final class LoopbackReceiver: @unchecked Sendable {
    /// The port asked for; 0 lets the system pick a free one.
    let requestedPort: UInt16
    let path: String
    private let queue = DispatchQueue(label: "\(ProductInfo.identifierPrefix).spotify.loopback")
    // Touched only on `queue`.
    private var listener: NWListener?
    private var continuation: CheckedContinuation<URL, any Error>?
    private var finished = false
    private var ready: CheckedContinuation<UInt16, any Error>?
    private var boundPort: UInt16 = 0

    init(port: UInt16, path: String) {
        self.requestedPort = port
        self.path = path
    }

    /// Starts listening; returns the bound port once it's ready, or throws `portInUse` if it can't bind.
    @discardableResult
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: requestedPort) ?? .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw SpotifyAuthError.portInUse(requestedPort)
        }
        let port = requestedPort
        return try await withCheckedThrowingContinuation { (ready: CheckedContinuation<UInt16, any Error>) in
            queue.async { [weak self] in
                // The caller holds the receiver while awaiting, so `self` is alive here.
                guard let self else { return ready.resume(throwing: SpotifyAuthError.cancelled) }
                self.listener = listener
                self.ready = ready
                listener.stateUpdateHandler = { [weak self] state in
                    // Runs on `queue`.
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.boundPort = listener.port?.rawValue ?? port
                        self.ready?.resume(returning: self.boundPort)
                        self.ready = nil
                    case .failed(let error), .waiting(let error):
                        listener.cancel()
                        if let ready = self.ready {
                            self.ready = nil
                            ready.resume(throwing: Self.isAddressInUse(error) ? SpotifyAuthError.portInUse(port) : SpotifyAuthError.authorization(error.localizedDescription))
                        } else {
                            self.finish(.failure(SpotifyAuthError.authorization(error.localizedDescription)))
                        }
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection)
                }
                listener.start(queue: self.queue)
            }
        }
    }

    /// Waits for the redirect. Throws `SpotifyAuthError.cancelled` after `timeout` or when cancelled.
    func waitForRedirect(timeout: Duration = .seconds(300)) async throws -> URL {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finish(.failure(SpotifyAuthError.cancelled))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if self.finished {
                        continuation.resume(throwing: SpotifyAuthError.cancelled)
                    } else {
                        self.continuation = continuation
                    }
                }
            }
        } onCancel: {
            self.finish(.failure(SpotifyAuthError.cancelled))
        }
    }

    func cancel() {
        finish(.failure(SpotifyAuthError.cancelled))
    }

    private func finish(_ result: Result<URL, any Error>) {
        queue.async {
            guard !self.finished else { return }
            self.finished = true
            self.listener?.cancel()
            self.listener = nil
            if let continuation = self.continuation {
                self.continuation = nil
                continuation.resume(with: result)
            }
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let url = data.flatMap(Self.requestTarget).flatMap { URL(string: "http://127.0.0.1:\(self.boundPort)\($0)") }
            switch url.map({ Self.classify($0, path: self.path) }) ?? .notFound {
            case .notFound:
                self.respond(connection, status: "404 Not Found", body: "<p>Not found.</p>")
            case .stray:
                self.respond(connection, status: "400 Bad Request", body: "<p>This page is for \(ProductInfo.name)'s Spotify sign-in.</p>")
            case .approved:
                self.respond(connection, status: "200 OK", body: Self.signedInBody)
                self.finish(.success(url!))
            case .refused:
                self.respond(connection, status: "200 OK", body: Self.refusedBody)
                self.finish(.success(url!))
            }
        }
    }

    enum Request: Equatable { case notFound, stray, approved, refused }

    /// What a request to the listener means. Only `path` with `code` or `error` ends the wait.
    static func classify(_ url: URL, path: String) -> Request {
        guard url.path == path else { return .notFound }
        let names = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
        if names.contains("code") { return .approved }
        if names.contains("error") { return .refused }
        return .stray
    }

    static let signedInBody = "<h1>You're signed in.</h1><p>You can close this tab and go back to \(ProductInfo.name).</p>"
    static let refusedBody = "<h1>Spotify sign-in didn't finish.</h1><p>Go back to \(ProductInfo.name) and try again.</p>"

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let html = """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">\
        <title>\(ProductInfo.name)</title><style>body{font:15px/1.45 -apple-system,BlinkMacSystemFont,system-ui,sans-serif;\
        margin:18vh auto;max-width:26em;padding:0 1.5em;text-align:center}h1{font-size:20px;font-weight:600;\
        margin:0 0 .4em}p{margin:0;opacity:.7}</style></head><body>\(body)</body></html>
        """
        let bytes = Data(html.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        connection.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// "GET /login?code=x&state=y HTTP/1.1" → "/login?code=x&state=y". Only GET with an origin-form target.
    static func requestTarget(_ data: Data) -> String? {
        guard let text = String(data: data.prefix(8 * 1024), encoding: .utf8),
              let line = text.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/"), parts[2].hasPrefix("HTTP/1.") else { return nil }
        return String(parts[1])
    }

    private static func isAddressInUse(_ error: NWError) -> Bool {
        if case .posix(let code) = error { return code == .EADDRINUSE }
        return false
    }
}
