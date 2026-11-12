import Foundation
import MedleyCore
import Testing
@testable import SpotifyKit

@Suite struct PKCETests {
    /// RFC 7636 Appendix B.
    @Test func rfc7636TestVector() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(pkce.method == "S256")
    }

    @Test func generatedVerifierIsValid() {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let a = PKCE(), b = PKCE()
        #expect((43...128).contains(a.verifier.count))
        #expect(a.verifier.allSatisfy { allowed.contains($0) })
        #expect(a.verifier != b.verifier)
        #expect(a.challenge == PKCE.challenge(for: a.verifier))
        #expect(!a.challenge.contains("=") && !a.challenge.contains("+") && !a.challenge.contains("/"))
    }
}

@Suite struct AuthorizeURLTests {
    let config = SpotifyAuthConfig(clientID: "abc123", redirectURI: SpotifyRedirect.loopback.uri)

    @Test func hasAllPKCEParameters() throws {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = config.authorizeURL(pkce: pkce, state: "xyz")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "accounts.spotify.com")
        #expect(components.path == "/authorize")
        let q = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(q["client_id"] == "abc123")
        #expect(q["response_type"] == "code")
        #expect(q["redirect_uri"] == "http://127.0.0.1:43827/callback")
        #expect(q["code_challenge_method"] == "S256")
        #expect(q["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(q["state"] == "xyz")
        #expect(q["scope"]?.split(separator: " ").count == SpotifyAuthConfig.defaultScopes.count)
        #expect(q["show_dialog"] == nil)
        // No implicit grant, no client secret.
        #expect(q["client_secret"] == nil)
    }

    @Test func encodesStrictly() {
        let url = config.authorizeURL(pkce: PKCE(), state: "s").absoluteString
        #expect(url.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A43827%2Fcallback"))
        #expect(url.contains("scope=user-read-private%20user-library-read"))
        #expect(!url.contains("+"))
    }

    @Test func redirectURIsFollowSpotifyRules() {
        // Loopback must be an explicit IP literal over http, never "localhost".
        #expect(SpotifyRedirect.loopback.uri.hasPrefix("http://127.0.0.1:"))
        #expect(!SpotifyRedirect.loopback.uri.contains("localhost"))
        #expect(SpotifyRedirect.customScheme.uri == "openmusic://spotify-callback")
    }

    @Test func parsesRedirect() throws {
        let ok = URL(string: "http://127.0.0.1:43827/callback?code=AQB123&state=s1")!
        #expect(try SpotifyAuthConfig.code(fromRedirect: ok, expectedState: "s1") == "AQB123")

        #expect(throws: SpotifyAuthError.stateMismatch) {
            try SpotifyAuthConfig.code(fromRedirect: ok, expectedState: "other")
        }
        let denied = URL(string: "http://127.0.0.1:43827/callback?error=access_denied&state=s1")!
        #expect(throws: SpotifyAuthError.cancelled) {
            try SpotifyAuthConfig.code(fromRedirect: denied, expectedState: "s1")
        }
        let custom = URL(string: "openmusic://spotify-callback?code=C&state=s")!
        #expect(try SpotifyAuthConfig.code(fromRedirect: custom, expectedState: "s") == "C")
    }

    @Test func loopbackRequestLineParsing() {
        let request = Data("GET /callback?code=abc&state=xyz HTTP/1.1\r\nHost: 127.0.0.1:43827\r\n\r\n".utf8)
        #expect(LoopbackReceiver.requestTarget(request) == "/callback?code=abc&state=xyz")
        #expect(LoopbackReceiver.requestTarget(Data("POST /callback HTTP/1.1\r\n\r\n".utf8)) == nil)
        #expect(LoopbackReceiver.requestTarget(Data("GET http://evil/ HTTP/1.1\r\n\r\n".utf8)) == nil)
        #expect(LoopbackReceiver.requestTarget(Data("garbage".utf8)) == nil)
    }
}

@Suite struct TokenTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func exchangeSendsPKCEFormAndParsesToken() async throws {
        let transport = FakeTransport { _, _ in .json("token") }
        let service = SpotifyAuthService(transport: transport, now: { [now] in now })
        let config = SpotifyAuthConfig(clientID: "client-123", redirectURI: SpotifyRedirect.loopback.uri)
        let token = try await service.exchange(code: "the-code", verifier: "the-verifier", config: config)

        #expect(token.accessToken == "BQD-access-token-1")
        #expect(token.refreshToken == "AQD-refresh-token-1")
        #expect(token.expiresAt == now.addingTimeInterval(3600))

        let request = try #require(transport.requests.first)
        #expect(request.url == SpotifyAuthConfig.tokenEndpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil) // public client: no secret, no Basic auth
        let form = request.formFields
        #expect(form == [
            "grant_type": "authorization_code",
            "code": "the-code",
            "redirect_uri": "http://127.0.0.1:43827/callback",
            "client_id": "client-123",
            "code_verifier": "the-verifier",
        ])
    }

    @Test func refreshKeepsOldRefreshTokenWhenOmitted() async throws {
        let transport = FakeTransport { _, _ in .json("token-refresh-no-rt") }
        let service = SpotifyAuthService(transport: transport, now: { [now] in now })
        let old = SpotifyToken(accessToken: "old", refreshToken: "keep-me", expiresAt: now, scope: nil)
        let fresh = try await service.refresh(old, clientID: "client-123")
        #expect(fresh.accessToken == "BQD-access-token-2")
        #expect(fresh.refreshToken == "keep-me")
        #expect(transport.requests.first?.formFields == ["grant_type": "refresh_token", "refresh_token": "keep-me", "client_id": "client-123"])
    }

    @Test func refreshReplacesRotatedRefreshToken() async throws {
        let transport = FakeTransport { _, _ in .json("token") }
        let service = SpotifyAuthService(transport: transport, now: { [now] in now })
        let fresh = try await service.refresh(SpotifyToken(accessToken: "old", refreshToken: "r0", expiresAt: now, scope: nil), clientID: "c")
        #expect(fresh.refreshToken == "AQD-refresh-token-1")
    }

    @Test func invalidGrantEndsTheSession() async {
        let transport = FakeTransport { _, _ in .json("auth-error-invalid-grant", status: 400) }
        let service = SpotifyAuthService(transport: transport)
        await #expect(throws: ProviderError.notSignedIn) {
            try await service.refresh(SpotifyToken(accessToken: "a", refreshToken: "r", expiresAt: .now, scope: nil), clientID: "c")
        }
    }

    @Test func needsRefreshLeeway() {
        let token = SpotifyToken(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(100), scope: nil)
        #expect(token.needsRefresh(now: now))           // within the 120 s leeway
        #expect(!token.needsRefresh(now: now, leeway: 30))
    }

    @Test func tokenRoundTripsThroughCodable() throws {
        let token = SpotifyToken(accessToken: "a", refreshToken: "r", expiresAt: now, scope: "s")
        let decoded = try JSONDecoder().decode(SpotifyToken.self, from: JSONEncoder().encode(token))
        #expect(decoded == token)
    }
}
