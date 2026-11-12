import Foundation
import MedleyCore
import Testing
@testable import SpotifyKit

/// Sol's review of 48d0809: a playlist write carries the account the app checked to where the API chooses its
/// credentials, and a playlist edit's reads skip the HTTP cache as well as the API's own.
@Suite struct WriteBindingTests {
    private func token(_ name: String) -> SpotifyToken {
        SpotifyToken(accessToken: "access-\(name)", refreshToken: "refresh-\(name)", expiresAt: Date().addingTimeInterval(3600), scope: nil)
    }

    private func writes(_ transport: FakeTransport) -> [URLRequest] {
        transport.requests.filter { $0.httpMethod == "POST" || $0.httpMethod == "DELETE" }
    }

    private func routes(_ request: URLRequest, _ n: Int) -> FakeTransport.Reply {
        switch (request.httpMethod, request.url?.path) {
        case ("GET", "/v1/me"): .json("me")
        case ("GET", "/v1/playlists/abc"): .json("playlist-owned")
        default: .raw(#"{"snapshot_id":"s1"}"#, status: 201)
        }
    }

    /// Checked as A; B's sign-in lands on the API actor before the requests go: none of the three writes is sent.
    @Test func aWriteCheckedForAnotherAccountIsNeverSent() async throws {
        let transport = FakeTransport(routes)
        let api = SpotifyAPI(transport: transport, tokenStore: MemoryTokenStore(), clientID: { "c" })
        try await api.setToken(token("A"), userID: "user-A")
        let service = SpotifyService(api: api)
        let asA = SpotifyWriteBinding(userID: "user-A", epoch: 0)
        try await api.setToken(token("B"), userID: "user-B")
        await #expect(throws: PlaylistEditError.accountChanged) { try await service.insert(["spotify:track:x"], intoPlaylist: "pl", at: 0, as: asA) }
        await #expect(throws: PlaylistEditError.accountChanged) { try await service.remove(["spotify:track:x"], fromPlaylist: "pl", as: asA) }
        await #expect(throws: PlaylistEditError.accountChanged) { try await service.add(["spotify:track:x"], toPlaylist: "pl", as: asA) }
        #expect(writes(transport).isEmpty, "no write went out with B's token")
    }

    /// A new token for the same account (a refresh, a sign-in synced from another device) still writes.
    @Test func aNewTokenForTheSameAccountStillWrites() async throws {
        let transport = FakeTransport(routes)
        let api = SpotifyAPI(transport: transport, tokenStore: MemoryTokenStore(), clientID: { "c" })
        try await api.setToken(token("A"), userID: "user-A")
        let service = SpotifyService(api: api)
        try await api.setToken(token("A2"), userID: "user-A")
        try await service.insert(["spotify:track:x"], intoPlaylist: "pl", at: 0, as: SpotifyWriteBinding(userID: "user-A", epoch: 0))
        #expect(writes(transport).map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer access-A2"])
    }

    /// New Playlist is a bound write too: checked as A, B's token landed, nothing is created.
    @Test func aNewPlaylistCheckedForAnotherAccountIsNeverCreated() async throws {
        let transport = FakeTransport(routes)
        let api = SpotifyAPI(transport: transport, tokenStore: MemoryTokenStore(), clientID: { "c" })
        try await api.setToken(token("A"), userID: "user-A")
        let service = SpotifyService(api: api)
        try await api.setToken(token("B"), userID: "user-B")
        await #expect(throws: PlaylistEditError.accountChanged) {
            _ = try await service.createPlaylist(title: "New", description: nil, as: SpotifyWriteBinding(userID: "user-A", epoch: 0))
        }
        #expect(writes(transport).isEmpty)
    }

    /// Without an account id, only the token swap the app checked counts: a later swap refuses the write.
    @Test func withoutAnAccountIDTheTokenSwapMustBeTheSame() async throws {
        let transport = FakeTransport(routes)
        let api = SpotifyAPI(transport: transport, tokenStore: MemoryTokenStore(), clientID: { "c" })
        _ = try await api.setToken(token("A"), userID: nil, epoch: 1)
        let service = SpotifyService(api: api)
        try await service.add(["spotify:track:x"], toPlaylist: "pl", as: SpotifyWriteBinding(userID: nil, epoch: 1))
        #expect(writes(transport).count == 1)
        _ = try await api.setToken(token("X"), userID: nil, epoch: 2)
        await #expect(throws: PlaylistEditError.accountChanged) {
            try await service.add(["spotify:track:x"], toPlaylist: "pl", as: SpotifyWriteBinding(userID: nil, epoch: 1))
        }
        #expect(writes(transport).count == 1)
    }

    /// The API doesn't know whose token it holds yet (restored at launch): it asks `/me` before the write and sends it
    /// only for that account.
    @Test func anUnknownAccountIsLearnedBeforeTheWrite() async throws {
        let transport = FakeTransport(routes)
        let api = SpotifyAPI(transport: transport, tokenStore: MemoryTokenStore(token("A")), clientID: { "c" })
        let service = SpotifyService(api: api)
        await #expect(throws: PlaylistEditError.accountChanged) {
            try await service.add(["spotify:track:x"], toPlaylist: "pl", as: SpotifyWriteBinding(userID: "someone-else", epoch: 0))
        }
        #expect(writes(transport).isEmpty)
        try await service.add(["spotify:track:x"], toPlaylist: "pl", as: SpotifyWriteBinding(userID: "ada.listener", epoch: 0))
        #expect(writes(transport).count == 1)
    }

    /// Through the provider: the edit is checked as A on the main actor, then B's sign-in lands on the API actor before
    /// the Undo's insert reaches the network. Nothing is written.
    @MainActor
    @Test func anUndoCheckedAsASendsNothingOnceBsTokenLanded() async throws {
        let transport = FakeTransport(routes)
        let defaults = try #require(UserDefaults(suiteName: "medley.tests.\(UUID().uuidString)"))
        let provider = SpotifyProvider(defaults: defaults, transport: transport, tokenStore: MemoryTokenStore())
        provider.saveAccount = { _ in }
        try await provider.adoptTransferredSignIn(token("A"), account: AccountInfo(name: "A", id: "user-A"), userID: "user-A")
        let account = PlaylistWriteAccount(accountID: "user-A", session: provider.session)
        try await provider.service.api.setToken(token("B"), userID: "user-B")
        let song = Track(providerID: "x", provider: .spotify, title: "X", extra: ["uri": "spotify:track:x"])
        await #expect(throws: PlaylistEditError.accountChanged) {
            try await provider.insert([song], intoPlaylist: "pl", at: 0, as: account)
        }
        #expect(writes(transport).isEmpty)
    }

    // MARK: The HTTP cache

    /// A playlist edit's reads (`fresh`) go uncached through the transport, the request ignoring every cache; other
    /// reads don't.
    @Test func uncachedReadsIgnoreTheHTTPCache() async throws {
        let transport = FakeTransport(routes)
        let api = SpotifyAPI(transport: transport, tokenStore: MemoryTokenStore(token("A")), clientID: { "c" })
        let service = SpotifyService(api: api)
        _ = try await service.playlist(id: "abc", fresh: true)
        let fresh = try #require(transport.requests(path: "/v1/playlists/abc").last)
        #expect(fresh.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(transport.uncachedPaths == ["/v1/playlists/abc"])
        _ = try await service.playlist(id: "abc")
        let cached = try #require(transport.requests(path: "/v1/playlists/abc").last)
        #expect(cached.cachePolicy == .useProtocolCachePolicy)
        #expect(transport.uncachedPaths == ["/v1/playlists/abc"])
    }

    /// The production transport sends uncached requests on a session with no URL cache.
    @Test func theUncachedSessionHasNoCache() {
        let transport = URLSessionTransport()
        #expect(transport.uncachedSession.configuration.urlCache == nil)
        #expect(transport.uncachedSession.configuration.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(transport.uncachedSession !== HTTP.session)
    }
}
