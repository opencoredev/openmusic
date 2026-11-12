import Foundation
import OpenMusicCore
import Testing
@testable import YouTubeMusicKit

/// Answers every request; requests to `/youtubei/` wait for `release()` and then rotate a cookie, as Google does.
final class HeldCookieProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var held = false
    nonisolated(unsafe) private static var open = false

    static func reset() { lock.withLock { held = false; open = false } }
    static var reached: Bool { lock.withLock { held } }
    static func release() { lock.withLock { open = true } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let isAPI = url.path.hasPrefix("/youtubei/")
        DispatchQueue.global().async {
            if isAPI {
                Self.lock.withLock { Self.held = true }
                while !Self.lock.withLock({ Self.open }) { usleep(5_000) }
            }
            let headers = isAPI
                ? ["Content-Type": "application/json", "Set-Cookie": "__Secure-3PSIDTS=rotated-for-A; Domain=.youtube.com; Path=/; Secure"]
                : ["Content-Type": "text/plain"]
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(isAPI ? "{}".utf8 : "".utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// Sol's review of b56ad76: a response to a request sent with account A's cookies, arriving after B's were committed,
/// never touches B's cookies.
@Suite(.serialized) struct StaleCookieTests {
    @Test func aStaleResponseDoesNotRotateTheNewAccountsCookies() async throws {
        HeldCookieProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeldCookieProtocol.self]
        let client = InnerTubeClient(configuration: config)
        let a = YTMCredentials(cookies: ["SAPISID": "a", "SID": "a", "__Secure-3PSIDTS": "a-ts"], datasyncId: "A||s")
        let b = YTMCredentials(cookies: ["SAPISID": "b", "SID": "b", "__Secure-3PSIDTS": "b-ts"], datasyncId: "B||s")
        // persist false: nothing goes to the Keychain.
        _ = try await client.commit(a, persist: false, store: false, epoch: 1)
        let request = Task { try await client.rate(videoId: "x", like: true) }
        for _ in 0..<400 where !HeldCookieProtocol.reached { try await Task.sleep(for: .milliseconds(5)) }
        #expect(HeldCookieProtocol.reached)
        _ = try await client.commit(b, persist: false, store: false, epoch: 2)
        HeldCookieProtocol.release()
        _ = try? await request.value
        let now = try #require(await client.currentCredentials)
        #expect(now.cookies == b.cookies, "B's cookies untouched by A's response")
    }
}
