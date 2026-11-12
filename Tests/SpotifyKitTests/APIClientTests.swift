import Foundation
import MedleyCore
import Testing
@testable import SpotifyKit

@Suite struct APIClientTests {
    @Test func sendsBearerToken() async throws {
        let (service, transport) = await makeService { _, _ in .json("me") }
        let me = try await service.me()
        #expect(me.name == "Ada Listener")
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.spotify.com/v1/me")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-0")
    }

    @Test func refreshesBeforeExpiry() async throws {
        let (service, transport) = await makeService(token: validToken(expiresIn: 30)) { request, _ in
            request.url?.host == "accounts.spotify.com" ? .json("token") : .json("me")
        }
        _ = try await service.me()
        #expect(transport.requests.map { $0.url!.host! } == ["accounts.spotify.com", "api.spotify.com"])
        #expect(transport.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer BQD-access-token-1")
    }

    @Test func refreshesOnceOn401ThenRetries() async throws {
        let (service, transport) = await makeService { request, n in
            if request.url?.host == "accounts.spotify.com" { return .json("token") }
            return n == 0 ? .raw(#"{"error":{"status":401,"message":"The access token expired"}}"#, status: 401) : .json("me")
        }
        _ = try await service.me()
        #expect(transport.requests.count == 3)
        #expect(transport.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer access-0")
        #expect(transport.requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer BQD-access-token-1")
    }

    @Test func second401MeansSignedOut() async {
        let (service, _) = await makeService { request, _ in
            request.url?.host == "accounts.spotify.com" ? .json("token") : .status(401)
        }
        await #expect(throws: ProviderError.notSignedIn) { try await service.me() }
    }

    @Test func revokedRefreshTokenClearsSession() async {
        let store = MemoryTokenStore(validToken(expiresIn: 10))
        let transport = FakeTransport { _, _ in .json("auth-error-invalid-grant", status: 400) }
        let api = SpotifyAPI(transport: transport, tokenStore: store, clientID: { "c" })
        await #expect(throws: ProviderError.notSignedIn) { try await api.accessToken() }
        #expect(store.load() == nil)
        #expect(await api.hasToken == false)
    }

    @Test func concurrentRequestsShareOneRefresh() async throws {
        let (service, transport) = await makeService(token: validToken(expiresIn: 5)) { request, _ in
            request.url?.host == "accounts.spotify.com" ? .json("token") : .json("me")
        }
        async let a = service.api.accessToken()
        async let b = service.api.accessToken()
        async let c = service.api.accessToken()
        let tokens = try await [a, b, c]
        #expect(Set(tokens) == ["BQD-access-token-1"])
        #expect(transport.requests.filter { $0.url?.host == "accounts.spotify.com" }.count == 1)
    }

    @Test func waitsOutRetryAfter() async throws {
        let sleeps = SleepRecorder()
        let (service, transport) = await makeService(sleeps: sleeps) { _, n in
            n < 2 ? .status(429, headers: ["Retry-After": "3"]) : .json("me")
        }
        _ = try await service.me()
        #expect(transport.requests.count == 3)
        #expect(sleeps.sleeps == [3, 3])
    }

    @Test func givesUpOnLongRetryAfter() async {
        let sleeps = SleepRecorder()
        let (service, _) = await makeService(sleeps: sleeps) { _, _ in
            FakeTransport.Reply(status: 429, body: Fixture.data("error-quota"), headers: ["Retry-After": "3600"])
        }
        await #expect(throws: ProviderError.rateLimited) { try await service.me() }
        #expect(sleeps.sleeps.isEmpty)
    }

    @Test func givesUpAfterThreeRateLimits() async {
        let sleeps = SleepRecorder()
        let (service, transport) = await makeService(sleeps: sleeps) { _, _ in .status(429, headers: ["Retry-After": "1"]) }
        await #expect(throws: ProviderError.rateLimited) { try await service.me() }
        #expect(transport.requests.count == 4)
    }

    @Test func retriesServerErrorOnceForGET() async throws {
        let (service, transport) = await makeService { _, n in n == 0 ? .status(503) : .json("me") }
        _ = try await service.me()
        #expect(transport.requests.count == 2)
    }

    @Test func cachesGETAndClearsOnWrite() async throws {
        let (service, transport) = await makeService { request, _ in
            request.httpMethod == "GET" ? .json("me") : .status(200)
        }
        // `me()` is an owner check and never cached; another GET with a ttl is.
        struct User: Decodable { var id: String }
        _ = try await service.api.get("me", ttl: 300, as: User.self)
        _ = try await service.api.get("me", ttl: 300, as: User.self)
        #expect(transport.requests.count == 1) // cached for 5 minutes
        try await service.setInLibrary(["spotify:track:x"], saved: true)
        _ = try await service.api.get("me", ttl: 300, as: User.self)
        #expect(transport.requests.count == 3)
    }

    /// An uncached read goes to Spotify even when an earlier cached read of the same playlist, delayed on the wire,
    /// landed (and filled the cache) just before it, and it writes nothing to the cache itself.
    @Test func anUncachedPlaylistReadNeverUsesOrFillsTheCache() async throws {
        let owned = String(decoding: Fixture.data("playlist-owned"), as: UTF8.self)
        let transport = FirstHeldTransport(path: "/v1/playlists/abc") { request, n in
            guard request.url?.path == "/v1/playlists/abc" else { return .json("me") }
            return .raw(n == 0 ? owned : owned.replacingOccurrences(of: "\"Late Night Drive\"", with: "\"Late Night Drive (fresh)\""))
        }
        let api = SpotifyAPI(transport: transport, tokenStore: MemoryTokenStore(validToken()), clientID: { "c" })
        let service = SpotifyService(api: api)
        let earlier = Task { try await service.playlist(id: "abc") }
        await transport.reached.wait()
        transport.release.open()
        let stale = try await earlier.value
        #expect(stale.playlist.title == "Late Night Drive")

        let fresh = try await service.playlist(id: "abc", fresh: true)
        #expect(fresh.playlist.title == "Late Night Drive (fresh)", "not the copy the earlier read cached")
        let requests = transport.requests(path: "/v1/playlists/abc").count
        #expect(requests == 2)
        _ = try await service.playlist(id: "abc", fresh: true)
        #expect(transport.requests(path: "/v1/playlists/abc").count == 3, "every uncached read asks")
        let cached = try await service.playlist(id: "abc")
        #expect(cached.playlist.title == "Late Night Drive", "the uncached reads wrote nothing to the cache")
        #expect(transport.requests(path: "/v1/playlists/abc").count == 3)
    }

    @Test func rejectsForeignPageLinks() async {
        let (service, transport) = await makeService { _, _ in .json("playlist-items-page2") }
        await #expect(throws: ProviderError.self) {
            _ = try await service.playlistTracks(continuation: "https://evil.example.com/v1/steal")
        }
        #expect(transport.requests.isEmpty) // the bearer token never leaves api.spotify.com
    }

    @Test func mapsSpotifyErrorReasons() {
        #expect(SpotifyAPI.error(status: 403, data: Fixture.data("error-premium")) == .unplayable("Spotify Connect playback needs Spotify Premium."))
        if case .unplayable = SpotifyAPI.error(status: 404, data: Fixture.data("error-no-device")) {} else { Issue.record("expected unplayable") }
        #expect(SpotifyAPI.error(status: 404, data: Fixture.data("error-not-found")) == .notFound)
        #expect(SpotifyAPI.error(status: 500, data: Data("oops".utf8)) == .server(500, "oops"))
    }

    @Test func escapesPlusInQueries() async {
        let api = SpotifyAPI(transport: FakeTransport { _, _ in .status(200) }, tokenStore: MemoryTokenStore(), clientID: { nil })
        let url = await api.url("search", query: ["q": "c++ ac/dc", "type": "track"])
        #expect(url.absoluteString == "https://api.spotify.com/v1/search?q=c%2B%2B%20ac/dc&type=track")
    }

    @Test func noTokenMeansNotSignedIn() async {
        let (service, transport) = await makeService(token: nil) { _, _ in .json("me") }
        await #expect(throws: ProviderError.notSignedIn) { try await service.me() }
        #expect(transport.requests.isEmpty)
    }
}

/// Holds the first request to `path` until `release` opens (after signalling `reached`); the handler gets each
/// request and how many requests to `path` came before it.
final class FirstHeldTransport: SpotifyTransport, @unchecked Sendable {
    let reached = Gate()
    let release = Gate()
    private let path: String
    private let handler: @Sendable (URLRequest, Int) -> FakeTransport.Reply
    private let lock = NSLock()
    private var log: [URLRequest] = []

    init(path: String, _ handler: @escaping @Sendable (URLRequest, Int) -> FakeTransport.Reply) {
        self.path = path
        self.handler = handler
    }

    func requests(path: String) -> [URLRequest] { lock.withLock { log.filter { $0.url?.path == path } } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index: Int = lock.withLock {
            defer { log.append(request) }
            return log.filter { $0.url?.path == path }.count
        }
        if request.url?.path == path, index == 0 {
            reached.open()
            await release.wait()
        }
        let reply = handler(request, index)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        return (reply.body, response)
    }
}
