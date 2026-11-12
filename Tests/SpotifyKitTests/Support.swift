import Foundation
import OpenMusicCore
@testable import SpotifyKit

enum Fixture {
    static func data(_ name: String, ext: String = "json") -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url) else {
            fatalError("missing fixture \(name).\(ext)")
        }
        return data
    }

    static func text(_ name: String, ext: String) -> String {
        String(decoding: data(name, ext: ext), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: data(name))
    }
}

/// Records requests and answers them from a handler.
final class FakeTransport: SpotifyTransport, @unchecked Sendable {
    struct Reply {
        var status: Int = 200
        var body: Data = Data()
        var headers: [String: String] = [:]

        static func json(_ fixture: String, status: Int = 200) -> Reply { Reply(status: status, body: Fixture.data(fixture)) }
        static func status(_ code: Int, headers: [String: String] = [:]) -> Reply { Reply(status: code, headers: headers) }
        static func raw(_ string: String, status: Int = 200) -> Reply { Reply(status: status, body: Data(string.utf8)) }
    }

    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private let handler: @Sendable (URLRequest, Int) -> Reply

    /// `handler` gets the request and how many earlier requests hit the same method + path.
    init(_ handler: @escaping @Sendable (URLRequest, Int) -> Reply) {
        self.handler = handler
    }

    var requests: [URLRequest] { lock.withLock { _requests } }
    private var _uncached: [String] = []
    /// The paths of requests sent uncached (`send(_:uncached:)`).
    var uncachedPaths: [String] { lock.withLock { _uncached } }

    func send(_ request: URLRequest, uncached: Bool) async throws -> (Data, HTTPURLResponse) {
        if uncached { lock.withLock { _uncached.append(request.url?.path ?? "") } }
        return try await send(request)
    }

    func requests(path: String) -> [URLRequest] { requests.filter { $0.url?.path == path } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let count: Int = lock.withLock {
            let n = _requests.filter { $0.url?.path == request.url?.path && $0.httpMethod == request.httpMethod }.count
            _requests.append(request)
            return n
        }
        let reply = handler(request, count)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (reply.body, response)
    }
}

extension URLRequest {
    var query: [String: String] {
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    var formFields: [String: String] {
        let body = String(decoding: httpBody ?? Data(), as: UTF8.self)
        var out: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            out[kv[0]] = kv.count > 1 ? kv[1] : ""
        }
        return out
    }

    var jsonBody: [String: Any]? {
        httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

/// Thread-safe recorder for injected sleeps.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _sleeps: [TimeInterval] = []
    var sleeps: [TimeInterval] { lock.withLock { _sleeps } }
    func record(_ s: TimeInterval) { lock.withLock { _sleeps.append(s) } }
}

/// Deterministic RNG (SplitMix64) for shuffle tests.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func validToken(expiresIn: TimeInterval = 3600, now: Date = Date()) -> SpotifyToken {
    SpotifyToken(accessToken: "access-0", refreshToken: "refresh-0", expiresAt: now.addingTimeInterval(expiresIn), scope: nil)
}

/// A service over a fake transport, with a signed-in token and user id set.
func makeService(
    token: SpotifyToken? = validToken(),
    sleeps: SleepRecorder = SleepRecorder(),
    _ handler: @escaping @Sendable (URLRequest, Int) -> FakeTransport.Reply
) async -> (SpotifyService, FakeTransport) {
    let transport = FakeTransport(handler)
    let api = SpotifyAPI(transport: transport, tokenStore: MemoryTokenStore(token), clientID: { "client-123" },
                         sleep: { sleeps.record($0) })
    await api.setUserID("ada.listener")
    return (SpotifyService(api: api), transport)
}
