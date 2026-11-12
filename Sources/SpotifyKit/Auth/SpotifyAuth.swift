import Foundation
import OpenMusicCore

/// Sends one HTTP request. `URLSessionTransport` in the app, a fake in tests.
public protocol SpotifyTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// `uncached`: on a session with no HTTP cache, for reads that must come from Spotify (a playlist edit's checks).
    /// The default sends it as any other.
    func send(_ request: URLRequest, uncached: Bool) async throws -> (Data, HTTPURLResponse)
}

public extension SpotifyTransport {
    func send(_ request: URLRequest, uncached: Bool) async throws -> (Data, HTTPURLResponse) { try await send(request) }
}

public struct URLSessionTransport: SpotifyTransport {
    private let session: URLSession

    /// The session uncached reads go through: no URL cache (`HTTP.uncachedSession`).
    let uncachedSession: URLSession

    public init(session: URLSession = HTTP.session, uncachedSession: URLSession = HTTP.uncachedSession) {
        self.session = session
        self.uncachedSession = uncachedSession
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await send(request, uncached: false)
    }

    public func send(_ request: URLRequest, uncached: Bool) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await (uncached ? uncachedSession : session).data(for: request)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.network("No HTTP response")
        }
        return (data, http)
    }
}

/// The OAuth client OpenMusic signs in with when the listener hasn't set up their own Spotify app.
///
/// This is Spotify's own desktop client ID, the one librespot, ncspot and spotify_player use to log in. Spotify has
/// registered `http://127.0.0.1:<any port>/login` for it, so OpenMusic needs no developer app, no pasted Client ID,
/// and no fixed port. It is not OpenMusic's client: Spotify's developer terms don't allow borrowing it, and Spotify
/// could block it or rate-limit it at any time. "Use my own Client ID" in Settings is the way out when that happens.
public enum SpotifyBuiltInClient {
    public static let clientID = "65b708073fc0480ea92a077233ca87bd"
    /// The path Spotify registered for this client's loopback redirect. The port is free.
    public static let redirectPath = "/login"
    /// Tried first (librespot's example port). When it's busy, OpenMusic lets the system pick a free one.
    public static let preferredPort: UInt16 = 8898

    public static func redirectURI(port: UInt16) -> String { "http://127.0.0.1:\(port)\(redirectPath)" }
}

/// How the authorization response gets back to OpenMusic when the listener signs in with their own Client ID.
public enum SpotifyRedirect: String, CaseIterable, Sendable, Hashable, Identifiable {
    /// `http://127.0.0.1:43827/callback`, caught by a one-shot local listener. Spotify's documented choice for native apps.
    case loopback
    /// `openmusic://spotify-callback`, caught by `ASWebAuthenticationSession`. Spotify still accepts custom schemes.
    case customScheme

    public static let loopbackPort: UInt16 = 43827
    public static let loopbackPath = "/callback"

    public var id: String { rawValue }

    public var uri: String {
        switch self {
        case .loopback: "http://127.0.0.1:\(Self.loopbackPort)\(Self.loopbackPath)"
        case .customScheme: "\(ProductInfo.urlScheme)://spotify-callback"
        }
    }

    public var label: String {
        switch self {
        case .loopback: "Browser (loopback)"
        case .customScheme: "In-app sheet (\(ProductInfo.urlScheme)://)"
        }
    }

    /// The listener's own Spotify app has exactly this URI registered, so the port can't move.
    var target: SpotifyRedirectTarget {
        switch self {
        case .loopback: .loopback(port: Self.loopbackPort, path: Self.loopbackPath, portIsFlexible: false)
        case .customScheme: .customScheme
        }
    }
}

/// Where the browser sends the authorization response, worked out when a sign-in starts.
public enum SpotifyRedirectTarget: Sendable, Hashable {
    /// One-shot listener on 127.0.0.1. With `portIsFlexible`, a busy `port` falls back to one the system picks
    /// (the built-in client accepts any loopback port); without it, a busy port is an error.
    case loopback(port: UInt16, path: String, portIsFlexible: Bool)
    /// `openmusic://spotify-callback` through `ASWebAuthenticationSession`.
    case customScheme

    static let builtIn = SpotifyRedirectTarget.loopback(
        port: SpotifyBuiltInClient.preferredPort, path: SpotifyBuiltInClient.redirectPath, portIsFlexible: true)
}

/// What the browser step hands back: the redirect carrying the code, and the exact redirect URI it was sent to
/// (needed again for the token exchange).
public struct SpotifyAuthorization: Sendable, Hashable {
    public var callback: URL
    public var redirectURI: String

    public init(callback: URL, redirectURI: String) {
        self.callback = callback
        self.redirectURI = redirectURI
    }
}

/// OAuth 2.0 Authorization Code with PKCE for a public client (no client secret).
public struct SpotifyAuthConfig: Sendable, Hashable {
    public static let authorizeEndpoint = URL(string: "https://accounts.spotify.com/authorize")!
    public static let tokenEndpoint = URL(string: "https://accounts.spotify.com/api/token")!

    /// Everything OpenMusic reads or changes. Spotify shows these on the consent screen.
    public static let defaultScopes = [
        "user-read-private",
        "user-library-read",
        "user-library-modify",
        "user-follow-read",
        "user-follow-modify",
        "user-top-read",
        "user-read-recently-played",
        "playlist-read-private",
        "playlist-read-collaborative",
        "playlist-modify-public",
        "playlist-modify-private",
        "user-read-playback-state",
        "user-modify-playback-state",
        "user-read-currently-playing",
    ]

    public var clientID: String
    public var redirectURI: String
    public var scopes: [String]

    public init(clientID: String, redirectURI: String, scopes: [String] = SpotifyAuthConfig.defaultScopes) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
    }

    public func authorizeURL(pkce: PKCE, state: String, showDialog: Bool = false) -> URL {
        var components = URLComponents(url: Self.authorizeEndpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
        ]
        if showDialog { items.append(URLQueryItem(name: "show_dialog", value: "true")) }
        // Strict RFC 3986 encoding (":" "/" "+" escaped too), so the redirect URI matches byte for byte after decoding.
        components.percentEncodedQueryItems = items.map {
            URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: SpotifyAuthService.unreserved))
        }
        return components.url!
    }

    /// Pulls the authorization code out of the redirect, checking `state`.
    public static func code(fromRedirect url: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw error == "access_denied"
                ? SpotifyAuthError.cancelled
                : SpotifyAuthError.authorization(error)
        }
        guard value("state") == expectedState else { throw SpotifyAuthError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw SpotifyAuthError.authorization("missing code") }
        return code
    }
}

public enum SpotifyAuthError: LocalizedError, Sendable, Equatable {
    case missingClientID
    case cancelled
    case stateMismatch
    case authorization(String)
    case token(String)
    case portInUse(UInt16)

    public var errorDescription: String? {
        switch self {
        case .missingClientID: "Paste your Client ID in Settings, or turn off Use My Own Client ID."
        case .cancelled: "Sign-in was cancelled."
        case .stateMismatch: "Sign-in response didn't match the request. Try again."
        case .authorization(let reason): "Spotify didn't finish the sign-in (\(reason)). Try again."
        case .token(let reason): "Spotify didn't issue a token: \(reason)"
        case .portInUse(let port): "Another app is using port \(port), so \(ProductInfo.name) can't hear back from your browser. Quit that app and try again, or switch the redirect to \(ProductInfo.urlScheme):// in Settings."
        }
    }
}

/// Access + refresh token pair, persisted in the Keychain.
public struct SpotifyToken: Codable, Sendable, Hashable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var scope: String?
    /// The client that issued the token; refreshes must use the same one. Nil for tokens saved before OpenMusic had a
    /// built-in client (those came from the listener's own Client ID).
    public var clientID: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, scope: String?, clientID: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.clientID = clientID
    }

    /// True when the token expires within `leeway` seconds.
    public func needsRefresh(now: Date, leeway: TimeInterval = 120) -> Bool {
        expiresAt.timeIntervalSince(now) <= leeway
    }
}

struct TokenResponse: Decodable, Sendable {
    var access_token: String
    var token_type: String?
    var scope: String?
    var expires_in: Int
    var refresh_token: String?

    /// Spotify may omit `refresh_token` on refresh; keep the old one then.
    func token(now: Date, previousRefreshToken: String?, clientID: String) -> SpotifyToken {
        SpotifyToken(accessToken: access_token, refreshToken: refresh_token ?? previousRefreshToken,
                     expiresAt: now.addingTimeInterval(TimeInterval(expires_in)), scope: scope, clientID: clientID)
    }
}

/// Token endpoint calls.
public struct SpotifyAuthService: Sendable {
    let transport: any SpotifyTransport
    let now: @Sendable () -> Date

    public init(transport: any SpotifyTransport, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.now = now
    }

    public func exchange(code: String, verifier: String, config: SpotifyAuthConfig) async throws -> SpotifyToken {
        try await tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": config.redirectURI,
            "client_id": config.clientID,
            "code_verifier": verifier,
        ], previousRefreshToken: nil)
    }

    public func refresh(_ token: SpotifyToken, clientID: String) async throws -> SpotifyToken {
        guard let refreshToken = token.refreshToken else { throw ProviderError.notSignedIn }
        return try await tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ], previousRefreshToken: refreshToken)
    }

    /// RFC 3986 unreserved characters (ASCII only).
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func formBody(_ fields: [String: String]) -> Data {
        let body = fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? $0.value)" }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    private func tokenRequest(_ fields: [String: String], previousRefreshToken: String?) async throws -> SpotifyToken {
        var request = URLRequest(url: SpotifyAuthConfig.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(fields)
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            let body = try? JSONDecoder().decode(SP.AuthErrorBody.self, from: data)
            // invalid_grant means the refresh token was revoked or expired: the session is over.
            if body?.error == "invalid_grant", fields["grant_type"] == "refresh_token" { throw ProviderError.notSignedIn }
            if response.statusCode == 429 { throw ProviderError.rateLimited }
            throw SpotifyAuthError.token(body.map { [$0.error, $0.error_description].compactMap { $0 }.joined(separator: ": ") } ?? "HTTP \(response.statusCode)")
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
                .token(now: now(), previousRefreshToken: previousRefreshToken, clientID: fields["client_id"] ?? "")
        } catch {
            throw ProviderError.decoding("token response")
        }
    }
}

/// Where tokens live between launches.
public protocol SpotifyTokenStore: Sendable {
    func load() -> SpotifyToken?
    /// Saves the token (deletes it when nil); throws when it wasn't saved.
    func save(_ token: SpotifyToken?) throws
}

public struct KeychainTokenStore: SpotifyTokenStore {
    public static let key = "spotify.token"
    public init() {}
    public func load() -> SpotifyToken? { Keychain.codable(SpotifyToken.self, for: Self.key) }
    public func save(_ token: SpotifyToken?) throws { try Keychain.storeCodable(token, for: Self.key) }
}

/// For tests and the probe CLI.
public final class MemoryTokenStore: SpotifyTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: SpotifyToken?
    public init(_ token: SpotifyToken? = nil) { self.token = token }
    public func load() -> SpotifyToken? { lock.withLock { token } }
    public func save(_ token: SpotifyToken?) { lock.withLock { self.token = token } }
}
