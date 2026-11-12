import Foundation
import MedleyCore
import Testing
@testable import SpotifyKit

/// One-click sign-in with the built-in client, the default since no Client ID needs pasting.
@MainActor
@Suite struct BuiltInClientTests {
    final class Captured: @unchecked Sendable {
        var target: SpotifyRedirectTarget?
        var authorizeURL: URL?
    }

    func provider(_ transport: FakeTransport = FakeTransport(SignInCancellationTests.routes),
                  store: MemoryTokenStore = MemoryTokenStore(), captured: Captured = Captured(),
                  port: UInt16 = 8898) -> SpotifyProvider {
        let defaults = UserDefaults(suiteName: "medley.tests.\(UUID().uuidString)")!
        let p = SpotifyProvider(defaults: defaults, transport: transport, tokenStore: store)
        p.saveAccount = { _ in }
        p.authorize = { target, makeURL in
            let path = if case .loopback(_, let path, _) = target { path } else { "" }
            let redirectURI = target == .customScheme ? "openmusic://spotify-callback" : "http://127.0.0.1:\(port)\(path)"
            let url = makeURL(redirectURI)
            captured.target = target
            captured.authorizeURL = url
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            return SpotifyAuthorization(callback: URL(string: "\(redirectURI)?code=the-code&state=\(state)")!, redirectURI: redirectURI)
        }
        return p
    }

    @Test func builtInClientIsTheDefault() {
        let p = provider()
        #expect(p.usesOwnClientID == false)
        #expect(p.hasClientID == false)
        #expect(p.canSignIn)
        #expect(p.signInClient.clientID == SpotifyBuiltInClient.clientID)
        #expect(p.signInClient.target == .loopback(port: 8898, path: "/login", portIsFlexible: true))
    }

    @Test func signsInWithTheBuiltInClientWithoutAClientID() async throws {
        let transport = FakeTransport(SignInCancellationTests.routes)
        let store = MemoryTokenStore()
        let captured = Captured()
        // The listener ended up on another port: the URL and the exchange must both use it.
        let p = provider(transport, store: store, captured: captured, port: 52011)
        await p.signIn()
        #expect(p.authStatus.isSignedIn)

        let url = try #require(captured.authorizeURL)
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(q["client_id"] == "65b708073fc0480ea92a077233ca87bd")
        #expect(q["redirect_uri"] == "http://127.0.0.1:52011/login")
        #expect(q["code_challenge_method"] == "S256")
        #expect(q["scope"]?.split(separator: " ").map(String.init) == SpotifyAuthConfig.defaultScopes)

        let exchange = try #require(transport.requests(path: "/api/token").first).formFields
        #expect(exchange["client_id"] == SpotifyBuiltInClient.clientID)
        #expect(exchange["redirect_uri"] == "http://127.0.0.1:52011/login")
        #expect(store.load()?.clientID == SpotifyBuiltInClient.clientID)
    }

    @Test func ownClientIDNeedsOneBeforeSigningIn() async {
        let transport = FakeTransport(SignInCancellationTests.routes)
        let p = provider(transport)
        p.usesOwnClientID = true
        #expect(!p.canSignIn)
        await p.signIn()
        #expect(p.authStatus == .failed(SpotifyAuthError.missingClientID.localizedDescription))
        #expect(transport.requests.isEmpty)
    }

    @Test func ownClientIDUsesItsFixedRedirect() async throws {
        let transport = FakeTransport(SignInCancellationTests.routes)
        let captured = Captured()
        let store = MemoryTokenStore()
        let p = provider(transport, store: store, captured: captured, port: 43827)
        p.usesOwnClientID = true
        p.clientID = "  own-client  "
        await p.signIn()
        #expect(p.authStatus.isSignedIn)
        #expect(captured.target == .loopback(port: 43827, path: "/callback", portIsFlexible: false))
        let exchange = try #require(transport.requests(path: "/api/token").first).formFields
        #expect(exchange["client_id"] == "own-client")
        #expect(exchange["redirect_uri"] == "http://127.0.0.1:43827/callback")
        #expect(store.load()?.clientID == "own-client")

        p.redirect = .customScheme
        await p.signIn()
        #expect(captured.target == .customScheme)
    }

    @Test func settingsPersist() {
        let defaults = UserDefaults(suiteName: "medley.tests.\(UUID().uuidString)")!
        let a = SpotifyProvider(defaults: defaults, transport: FakeTransport(fixtureRoutes), tokenStore: MemoryTokenStore())
        a.usesOwnClientID = true
        a.clientID = "abc"
        let b = SpotifyProvider(defaults: defaults, transport: FakeTransport(fixtureRoutes), tokenStore: MemoryTokenStore())
        #expect(b.usesOwnClientID)
        #expect(b.clientID == "abc")
    }

    @Test func builtInErrorsDontTalkAboutDeveloperDashboards() {
        let limited = SpotifyProvider.explain(ProviderError.rateLimited, ownClient: false)
        #expect(limited.contains("own Client ID"))
        let forbidden = SpotifyProvider.explain(ProviderError.server(403, "Forbidden"), ownClient: false)
        #expect(!forbidden.contains("User Management"))
        #expect(!forbidden.contains("Development-mode"))
    }
}

@Suite struct BuiltInAuthorizeURLTests {
    @Test func authorizeURLForTheBuiltInClient() throws {
        let config = SpotifyAuthConfig(clientID: SpotifyBuiltInClient.clientID,
                                       redirectURI: SpotifyBuiltInClient.redirectURI(port: SpotifyBuiltInClient.preferredPort))
        let url = config.authorizeURL(pkce: PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), state: "s").absoluteString
        #expect(url.hasPrefix("https://accounts.spotify.com/authorize?client_id=65b708073fc0480ea92a077233ca87bd&response_type=code&"))
        #expect(url.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A8898%2Flogin"))
        #expect(url.contains("code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"))
        #expect(!url.contains("localhost"))
    }

    @Test func loopbackPathMatching() {
        func kind(_ s: String) -> LoopbackReceiver.Request { LoopbackReceiver.classify(URL(string: "http://127.0.0.1:8898\(s)")!, path: "/login") }
        #expect(kind("/login?code=abc&state=s") == .approved)
        #expect(kind("/login?error=access_denied&state=s") == .refused)
        #expect(kind("/login") == .stray)
        #expect(kind("/login?state=s") == .stray)
        #expect(kind("/favicon.ico") == .notFound)
        #expect(kind("/callback?code=abc") == .notFound)
        #expect(kind("/login/extra?code=abc") == .notFound)
    }

    @Test func refreshUsesTheClientThatIssuedTheToken() async throws {
        let transport = FakeTransport { _, _ in .json("token") }
        let expired = Date().addingTimeInterval(-10)
        let builtIn = SpotifyToken(accessToken: "a", refreshToken: "r", expiresAt: expired, scope: nil, clientID: SpotifyBuiltInClient.clientID)
        let api = SpotifyAPI(transport: transport, tokenStore: MemoryTokenStore(builtIn), clientID: { "legacy-own-client" })
        let fresh = try await api.refreshToken()
        #expect(transport.requests.last?.formFields["client_id"] == SpotifyBuiltInClient.clientID)
        #expect(fresh.clientID == SpotifyBuiltInClient.clientID)

        // Saved before the built-in client existed: refreshed with the listener's own Client ID.
        let legacy = SpotifyToken(accessToken: "a", refreshToken: "r", expiresAt: expired, scope: nil)
        let api2 = SpotifyAPI(transport: transport, tokenStore: MemoryTokenStore(legacy), clientID: { "legacy-own-client" })
        let fresh2 = try await api2.refreshToken()
        #expect(transport.requests.last?.formFields["client_id"] == "legacy-own-client")
        #expect(fresh2.clientID == "legacy-own-client")
    }

    @Test func legacyTokenJSONStillDecodes() throws {
        let json = #"{"accessToken":"a","refreshToken":"r","expiresAt":0,"scope":"x"}"#
        let token = try JSONDecoder().decode(SpotifyToken.self, from: Data(json.utf8))
        #expect(token.clientID == nil)
        #expect(token.accessToken == "a")
    }
}

/// The real listener on 127.0.0.1, driven with URLSession.
@Suite(.serialized) struct LoopbackListenerTests {
    func get(_ url: String) async throws -> (Int, String) {
        let (data, response) = try await URLSession.shared.data(from: URL(string: url)!)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    @Test func ignoresStrayRequestsAndCatchesTheRedirect() async throws {
        let receiver = LoopbackReceiver(port: 0, path: "/login")
        let port = try await receiver.start()
        #expect(port != 0)
        let base = "http://127.0.0.1:\(port)"
        #expect(try await get("\(base)/favicon.ico").0 == 404)
        #expect(try await get("\(base)/login").0 == 400)
        async let redirect = receiver.waitForRedirect(timeout: .seconds(20))
        let (status, body) = try await get("\(base)/login?code=abc&state=xyz")
        #expect(status == 200)
        #expect(body.contains("You're signed in."))
        #expect(body.contains("You can close this tab and go back to OpenMusic."))
        let url = try await redirect
        #expect(url.path == "/login")
        #expect(try SpotifyAuthConfig.code(fromRedirect: url, expectedState: "xyz") == "abc")
    }

    @MainActor
    @Test func busyPortFallsBackForTheBuiltInClient() async throws {
        let blocker = LoopbackReceiver(port: 0, path: "/blocker")
        let busy = try await blocker.start()
        defer { blocker.cancel() }

        let flow = SpotifySignInFlow()
        flow.activateApp = {}
        flow.openURL = { url in
            // Play the browser: follow the redirect URI from the authorize URL.
            let redirect = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "redirect_uri" }?.value ?? ""
            Task.detached { _ = try? await URLSession.shared.data(from: URL(string: "\(redirect)?code=c&state=s")!) }
            return true
        }
        let response = try await flow.authorize(target: .loopback(port: busy, path: "/login", portIsFlexible: true)) { redirectURI in
            SpotifyAuthConfig(clientID: SpotifyBuiltInClient.clientID, redirectURI: redirectURI).authorizeURL(pkce: PKCE(), state: "s")
        }
        #expect(response.redirectURI.hasPrefix("http://127.0.0.1:"))
        #expect(response.redirectURI.hasSuffix("/login"))
        #expect(response.redirectURI != "http://127.0.0.1:\(busy)/login")
        #expect(response.callback.query == "code=c&state=s")
    }

    @MainActor
    @Test func busyPortIsAnErrorForAFixedRedirect() async throws {
        let blocker = LoopbackReceiver(port: 0, path: "/blocker")
        let busy = try await blocker.start()
        defer { blocker.cancel() }
        let flow = SpotifySignInFlow()
        flow.openURL = { _ in Issue.record("must not open the browser"); return false }
        await #expect(throws: SpotifyAuthError.portInUse(busy)) {
            try await flow.authorize(target: .loopback(port: busy, path: "/callback", portIsFlexible: false)) { _ in URL(string: "https://example.com")! }
        }
    }
}

@Suite struct ExtendedEndpointTests {
    @Test func artistPageUsesTopTracksAndRelatedWhenAvailable() async throws {
        let (service, transport) = await makeService { request, n in
            switch request.url!.path {
            case "/v1/artists/4tZwfgrHOc3mvqYlEYSvVi/top-tracks": return .json("artist-top-tracks")
            case "/v1/artists/4tZwfgrHOc3mvqYlEYSvVi/related-artists": return .json("related-artists")
            default: return fixtureRoutes(request, n)
            }
        }
        let detail = try await service.artist(id: "4tZwfgrHOc3mvqYlEYSvVi")
        #expect(detail.topTracks.map(\.title) == ["Harder, Better, Faster, Stronger", "Lose Yourself to Dance (feat. Pharrell Williams)"])
        #expect(detail.related.map(\.name) == ["Daft Punk", "Nile Rodgers"])
        #expect(transport.requests(path: "/v1/artists/4tZwfgrHOc3mvqYlEYSvVi/top-tracks").first?.query["market"] == "from_token")
        // No search stand-in when the endpoint answered.
        #expect(transport.requests(path: "/v1/search").isEmpty)
    }

    @Test func unavailableTopTracksIsNotAskedAgainThisSession() async throws {
        let (service, transport) = await makeService { request, n in
            request.url!.path.hasSuffix("/top-tracks") || request.url!.path.hasSuffix("/related-artists")
                ? .raw(#"{"error":{"status":403,"message":"Forbidden"}}"#, status: 403)
                : fixtureRoutes(request, n)
        }
        _ = try await service.artist(id: "4tZwfgrHOc3mvqYlEYSvVi")
        _ = try await service.artistTopTracks(id: "other", name: "Daft Punk")
        _ = try await service.relatedArtists(id: "other")
        #expect(transport.requests.filter { $0.url!.path.hasSuffix("/top-tracks") }.count == 1)
        #expect(transport.requests.filter { $0.url!.path.hasSuffix("/related-artists") }.count == 1)
    }
}
