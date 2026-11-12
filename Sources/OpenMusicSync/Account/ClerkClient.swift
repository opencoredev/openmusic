import Foundation
import OpenMusicCore

// Clerk's Frontend API in native mode, the way the official clerk-ios SDK speaks it, without the SDK
// (docs/accounts-design.md, "Clerk on native"). Every request carries `_is_native=true` and the saved client token
// in `Authorization` (no cookies, no Origin); every response's `Authorization` header replaces the saved token.

/// Sends one request. URLSession in the app; a fake in tests.
public protocol ClerkHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionClerkHTTP: ClerkHTTP {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClerkError.unexpected("not an HTTP response") }
        return (data, http)
    }
}

/// What the sign-in flows report. Messages are meant to be shown.
public enum ClerkError: LocalizedError, Sendable, Equatable {
    /// Clerk refused the request; `message` is Clerk's own (for example "Incorrect code").
    case refused(code: String, message: String)
    /// The Clerk app asks for more than an email address and a code (a password, a name, a phone number).
    case unsupportedRequirements([String])
    /// The server has no Clerk app configured, or its publishable key is malformed.
    case notConfigured
    /// The Clerk session ended (signed out elsewhere, or revoked).
    case sessionEnded
    case network(String)
    case unexpected(String)
    /// The session changed (signed out, or signed in again) while the request was in flight; its answer was dropped.
    case stale
    /// The server now names a different Clerk host than the one this device signed in with; the saved sign-in
    /// was dropped without being sent there.
    case originChanged(String)
    /// The saved session ended while this Clerk client still has another active one (named here); OpenMusic signed out
    /// instead of switching to it.
    case otherSessionNotAdopted(String)

    public var errorDescription: String? {
        switch self {
        case .refused(_, let message): message
        case .unsupportedRequirements(let fields):
            "This server's sign-in also asks for \(fields.joined(separator: ", ")), which \(ProductInfo.name) doesn't support. Its Clerk app should ask only for an email address."
        case .notConfigured: "This server isn't set up for sign-in yet."
        case .sessionEnded: "You were signed out. Sign in again."
        case .network(let why): "Can't reach the sign-in service: \(why)"
        case .unexpected(let why): "Sign-in failed: \(why)"
        case .stale: "You signed out while that was in progress."
        case .originChanged(let host):
            "This server now signs in through a different service (\(host)), so \(ProductInfo.name) signed you out instead of sending your sign-in there. Sign in again only if you trust this server."
        case .otherSessionNotAdopted(let name):
            "Your sign-in on this device ended. \(ProductInfo.name) signed you out instead of switching to another sign-in it found (\(name)). Sign in again to choose the account."
        }
    }
}

/// The signed-in Clerk user, as the apps show them. Never sent to the sync server.
public struct ClerkUser: Codable, Sendable, Hashable {
    public var id: String
    public var firstName: String?
    public var lastName: String?
    public var email: String?
    public var imageURL: URL?

    public init(id: String, firstName: String? = nil, lastName: String? = nil, email: String? = nil, imageURL: URL? = nil) {
        self.id = id
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.imageURL = imageURL
    }

    /// "Riley Smith", else the email address, else "Signed in".
    public var displayName: String {
        let name = [firstName, lastName].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        if !name.isEmpty { return name }
        return email ?? "Signed in"
    }
}

/// One Clerk session and its user: what a sign-in or a launch's restore made current.
public struct ClerkSession: Sendable, Hashable {
    public var id: String
    public var user: ClerkUser

    public init(id: String, user: ClerkUser) {
        self.id = id
        self.user = user
    }
}

/// A session that ended on Clerk's side (signed out elsewhere, revoked, expired, or gone at launch), with who it was,
/// so the app ends that sign-in only and never a newer one that started while this was on its way to it.
public struct ClerkSessionEnd: Sendable, Hashable {
    public var sessionID: String
    public var userID: String?
    /// Another active session this Clerk client still has, which OpenMusic did not switch to (`restore()` never moves
    /// to another session by itself), so the app can say why it signed out.
    public var notAdopted: ClerkUser?

    public init(sessionID: String, userID: String?, notAdopted: ClerkUser? = nil) {
        self.sessionID = sessionID
        self.userID = userID
        self.notAdopted = notAdopted
    }
}

/// A social sign-in the Clerk app has turned on.
public struct ClerkOAuthProvider: Sendable, Hashable, Identifiable {
    /// Clerk's strategy, for example "oauth_google".
    public var strategy: String
    public var id: String { strategy }

    public init(strategy: String) { self.strategy = strategy }

    public static let google = ClerkOAuthProvider(strategy: "oauth_google")
    public static let apple = ClerkOAuthProvider(strategy: "oauth_apple")

    /// "Google", "Apple", …
    public var name: String {
        switch strategy {
        case "oauth_google": "Google"
        case "oauth_apple": "Apple"
        case "oauth_github": "GitHub"
        case "oauth_microsoft": "Microsoft"
        default: String(strategy.dropFirst("oauth_".count)).capitalized
        }
    }
}

/// An email code on its way: which attempt to complete with the code.
public struct ClerkEmailChallenge: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case signIn, signUp }
    public var kind: Kind
    public var attemptID: String
    public var email: String
}

/// A social sign-in waiting for the browser: open `url` (ASWebAuthenticationSession, callback scheme `openmusic`),
/// then pass the callback to `completeOAuth`.
public struct ClerkOAuthStart: Sendable, Hashable {
    public var url: URL
    public var signInID: String
}

/// The persisted part of a Clerk sign-in: the client token, the session and the user (for offline launches), and the
/// Frontend API they belong to. The client token is a credential for that origin only: it is never sent anywhere
/// else, so a server whose configuration starts naming another Clerk host can't collect it.
public struct ClerkState: Codable, Sendable, Equatable {
    /// The Frontend API origin (`https://<host>`) this state was created with. nil only for state saved before
    /// origins were recorded, which is never used.
    public var frontendAPI: String?
    public var clientToken: String?
    public var sessionID: String?
    public var user: ClerkUser?

    public init(frontendAPI: String? = nil, clientToken: String? = nil, sessionID: String? = nil, user: ClerkUser? = nil) {
        self.frontendAPI = frontendAPI
        self.clientToken = clientToken
        self.sessionID = sessionID
        self.user = user
    }

    /// Whether anything worth protecting is saved (a client token or a session).
    var holdsCredentials: Bool { clientToken != nil || sessionID != nil }
}

extension ClerkState: CustomStringConvertible {
    public var description: String {
        "ClerkState(frontendAPI: \(frontendAPI ?? "none"), session: \(sessionID ?? "none"), user: \(user?.id ?? "none"), clientToken: <redacted>)"
    }
}

/// Where `ClerkClient` keeps `ClerkState`.
public protocol ClerkStateStore: Sendable {
    func load() -> ClerkState?
    func save(_ state: ClerkState?)
}

/// `ClerkState` inside the sync credential store (`sync.credentials.state.clerk` in the Keychain), so the Mac's
/// Keychain service needs no new account.
public struct CredentialClerkStateStore: ClerkStateStore {
    public var store: any SyncCredentialStore
    public var name: String

    public init(store: any SyncCredentialStore, name: String = "clerk") {
        self.store = store
        self.name = name
    }

    public func load() -> ClerkState? { store.state(name).flatMap { try? JSONDecoder().decode(ClerkState.self, from: $0) } }
    public func save(_ state: ClerkState?) { store.setState(name, state.flatMap { try? JSONEncoder().encode($0) }) }
}

/// The publishable key names the Frontend API host: `pk_test_` or `pk_live_` + base64("<host>$").
public enum ClerkPublishableKey {
    /// `https://<host>` for a well-formed key naming a plausible public DNS name, else nil.
    public static func frontendAPI(_ key: String) -> URL? {
        let body: Substring
        if key.hasPrefix("pk_test_") { body = key.dropFirst(8) } else if key.hasPrefix("pk_live_") { body = key.dropFirst(8) } else { return nil }
        var text = String(body)
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text), let decoded = String(data: data, encoding: .utf8), decoded.hasSuffix("$") else { return nil }
        let host = String(decoded.dropLast())
        guard isPlausibleHost(host), let url = URL(string: "https://\(host)"), url.scheme == "https", url.host == host,
              url.port == nil, url.user == nil, url.path.isEmpty, url.query == nil else { return nil }
        return url
    }

    /// A lowercase DNS name with at least two labels: letters, digits and inner hyphens, no IP address, no port,
    /// no `localhost`. Clerk's Frontend API hosts look like `clerk.example.com` or `happy-otter-12.clerk.accounts.dev`.
    static func isPlausibleHost(_ host: String) -> Bool {
        guard (4...253).contains(host.count), host == host.lowercased() else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for label in labels {
            guard (1...63).contains(label.count), label.first != "-", label.last != "-",
                  label.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }) else { return false }
        }
        // The last label is a name, never a number (no IPv4 address in disguise).
        guard let tld = labels.last, tld.contains(where: { ("a"..."z").contains($0) }) else { return false }
        return !host.hasSuffix(".localhost") && !host.hasSuffix(".local")
    }
}

/// One Clerk instance (one publishable key). An actor, but reentrant across its awaits: two calls can be in flight at
/// once. Every request carries the session generation it started in; `signOut`, an ended session and a new sign-in
/// start a new generation, and a response that comes back for an older one is dropped (its rotated client token
/// isn't saved and it changes no state), so a sign-out always wins over a restore or refresh that was still running.
public actor ClerkClient: AuthTokenProvider {
    public nonisolated let frontendAPI: URL
    /// True when saved state belonged to another Frontend API origin and was dropped unused: the server's
    /// configuration now names a different Clerk host. The listener has to sign in again.
    public nonisolated let discardedStateForOtherOrigin: Bool
    private let http: any ClerkHTTP
    private let store: any ClerkStateStore
    private var state: ClerkState
    private var cachedToken: AuthToken?
    /// Bumped whenever the session this client speaks for changes (sign-out, ended session, new sign-in).
    private var generation = 0
    /// Called when the session ended on Clerk's side (signed out elsewhere, revoked, expired), with that session.
    private var onSessionEnded: (@Sendable (ClerkSessionEnd) -> Void)?

    /// The Convex JWT template (Clerk dashboard › Configure › Integrations › Convex creates it).
    public static let tokenTemplate = "convex"
    /// The redirect for social sign-ins. Add it to the Clerk app's allowed redirect URLs.
    public static let oauthRedirect = "\(ProductInfo.urlScheme)://oauth-callback"
    /// The Frontend API version the official clerk-ios SDK sends today (`Clerk.apiVersion`).
    public static let apiVersion = "2026-08-20"

    public init(publishableKey: String, http: any ClerkHTTP = URLSessionClerkHTTP(), store: any ClerkStateStore) throws {
        guard let api = ClerkPublishableKey.frontendAPI(publishableKey) else { throw ClerkError.notConfigured }
        frontendAPI = api
        self.http = http
        self.store = store
        let origin = api.absoluteString
        let saved = store.load()
        if let saved, saved.holdsCredentials, saved.frontendAPI != origin {
            // Saved for another Clerk host (or before origins were recorded): never sent here. Signed out.
            store.save(nil)
            discardedStateForOtherOrigin = true
            state = ClerkState(frontendAPI: origin)
        } else {
            discardedStateForOtherOrigin = false
            state = saved ?? ClerkState(frontendAPI: origin)
            state.frontendAPI = origin
        }
    }

    public func setOnSessionEnded(_ handler: (@Sendable (ClerkSessionEnd) -> Void)?) { onSessionEnded = handler }

    /// The user saved by the last sign-in, without asking Clerk (for an instant, offline-safe launch).
    public var savedUser: ClerkUser? { savedSession?.user }

    /// The session saved by the last sign-in, with its user, without asking Clerk.
    public var savedSession: ClerkSession? {
        guard let id = state.sessionID, let user = state.user else { return nil }
        return ClerkSession(id: id, user: user)
    }

    // MARK: Session

    /// Asks Clerk whether the saved session is still active, refreshing its user. nil when signed out. Throws
    /// `.network` when Clerk can't be reached (the saved user still counts then).
    ///
    /// Only the saved session counts. When it is gone, this client is signed out (`onSessionEnded` runs for it) even if
    /// Clerk still has another active session on this client: moving to it silently would show another account (or
    /// another sign-in of the same one) that the app never signed sync in with, under a sign-in generation that never
    /// moved, while sync still spoke for the saved one. The end names that other session's user (`notAdopted`), so the
    /// app can say so; the listener signs in again to choose.
    public func restore() async throws -> ClerkSession? {
        guard let saved = state.sessionID else { return nil }
        guard state.clientToken != nil else {
            endSession()   // a session with no client token to ask about it: nothing can keep it
            return nil
        }
        let object = try await request("GET", "/v1/client")
        let client = (object["response"] as? [String: Any]) ?? (object["client"] as? [String: Any])
        guard let client, let session = Self.activeSession(in: client, id: saved) else {
            endSession(notAdopted: client.flatMap { Self.activeSessions(in: $0).first?.user })
            return nil
        }
        state.user = session.user
        save()
        return session
    }

    /// The social sign-ins the Clerk app has on (`GET /v1/environment`, `user_settings.social`).
    public func socialProviders() async throws -> [ClerkOAuthProvider] {
        let env = try await request("GET", "/v1/environment")
        guard let settings = env["user_settings"] as? [String: Any], let social = settings["social"] as? [String: Any] else { return [] }
        let preferred = ["oauth_apple", "oauth_google"]
        return social.compactMap { strategy, value -> ClerkOAuthProvider? in
            guard let config = value as? [String: Any], config["enabled"] as? Bool == true,
                  (config["authenticatable"] as? Bool) ?? true else { return nil }
            return ClerkOAuthProvider(strategy: strategy)
        }
        .sorted { (preferred.firstIndex(of: $0.strategy) ?? 99, $0.strategy) < (preferred.firstIndex(of: $1.strategy) ?? 99, $1.strategy) }
    }

    /// The session this client speaks for now (nil when signed out).
    public var currentSessionID: String? { state.sessionID }

    /// `signOut()`, only if the session is still `session` (what `currentSessionID` was when the caller started).
    /// A sign-out that waited for something else first (sync removing the device) must not end a session that
    /// signed in meanwhile. The check and forgetting the session happen together, before any await. Returns whether
    /// it signed out.
    @discardableResult
    public func signOut(ifSession session: String?) async -> Bool {
        guard state.sessionID == session else { return false }
        await signOut()
        return true
    }

    /// Forgets the session here at once, then ends it at Clerk (best effort, with the token it had). Anything still
    /// running for the old session finds a new generation when it returns and changes nothing.
    public func signOut() async {
        let session = state.sessionID
        let token = state.clientToken
        generation += 1
        state = ClerkState(frontendAPI: frontendAPI.absoluteString)
        cachedToken = nil
        lastClient = nil
        save()
        if let session {
            _ = try? await request("POST", "/v1/client/sessions/\(session)/remove", token: .override(token))
        }
    }

    // MARK: Email code

    /// Sends a 6-digit code to `email`. A known address signs in; a new one signs up, with the same next step.
    public func startEmail(_ email: String) async throws -> ClerkEmailChallenge {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let signIn = try await response(request("POST", "/v1/client/sign_ins", form: ["identifier": address]))
            guard let id = signIn["id"] as? String else { throw ClerkError.unexpected("no sign-in id") }
            let factors = (signIn["supported_first_factors"] as? [[String: Any]]) ?? []
            guard let factor = factors.first(where: { $0["strategy"] as? String == "email_code" }),
                  let emailID = factor["email_address_id"] as? String else {
                throw ClerkError.unsupportedRequirements(["a password"])
            }
            _ = try await request("POST", "/v1/client/sign_ins/\(id)/prepare_first_factor",
                                  form: ["strategy": "email_code", "email_address_id": emailID])
            return ClerkEmailChallenge(kind: .signIn, attemptID: id, email: address)
        } catch ClerkError.refused(let code, _) where code == "form_identifier_not_found" {
            let signUp = try await response(request("POST", "/v1/client/sign_ups", form: ["email_address": address]))
            guard let id = signUp["id"] as? String else { throw ClerkError.unexpected("no sign-up id") }
            _ = try await request("POST", "/v1/client/sign_ups/\(id)/prepare_verification", form: ["strategy": "email_code"])
            return ClerkEmailChallenge(kind: .signUp, attemptID: id, email: address)
        }
    }

    /// Completes an email sign-in or sign-up with the code from the email.
    public func verifyEmail(_ challenge: ClerkEmailChallenge, code: String) async throws -> ClerkSession {
        let digits = code.filter(\.isNumber)
        switch challenge.kind {
        case .signIn:
            let signIn = try await response(request("POST", "/v1/client/sign_ins/\(challenge.attemptID)/attempt_first_factor",
                                                    form: ["strategy": "email_code", "code": digits]))
            return try await finish(signIn)
        case .signUp:
            var signUp = try await response(request("POST", "/v1/client/sign_ups/\(challenge.attemptID)/attempt_verification",
                                                    form: ["strategy": "email_code", "code": digits]))
            if Self.missesOnlyPassword(signUp) {
                // A Clerk app that requires a password at sign-up (Clerk's default, and the dashboard is the only place
                // to turn it off): give the new account a long random one, never shown, saved or sent anywhere else.
                // OpenMusic signs in with email codes only, so nobody needs it; "Forgot password" can still set one.
                signUp = try await response(request("PATCH", "/v1/client/sign_ups/\(challenge.attemptID)",
                                                    form: ["password": Self.unusedPassword()]))
            }
            return try await finish(signUp)
        }
    }

    /// A sign-up whose email is verified and whose only missing field is the password.
    static func missesOnlyPassword(_ signUp: [String: Any]) -> Bool {
        signUp["status"] as? String == "missing_requirements"
            && (signUp["missing_fields"] as? [String]) == ["password"]
            && ((signUp["unverified_fields"] as? [String]) ?? []).isEmpty
    }

    /// 32 random bytes as base64url (43 characters): past any length rule a Clerk app can set, and never in a breach list.
    static func unusedPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // MARK: Social sign-in

    /// Starts a social sign-in; open the returned URL in a web authentication session.
    public func startOAuth(_ provider: ClerkOAuthProvider) async throws -> ClerkOAuthStart {
        let form = ["strategy": provider.strategy, "redirect_url": Self.oauthRedirect]
        var signIn = try await response(request("POST", "/v1/client/sign_ins", form: form))
        guard let id = signIn["id"] as? String else { throw ClerkError.unexpected("no sign-in id") }
        if Self.externalURL(signIn) == nil {
            signIn = try await response(request("POST", "/v1/client/sign_ins/\(id)/prepare_first_factor", form: form))
        }
        guard let url = Self.externalURL(signIn) else { throw ClerkError.unexpected("Clerk returned no sign-in page") }
        return ClerkOAuthStart(url: url, signInID: id)
    }

    /// Finishes a social sign-in from the callback URL (`openmusic://oauth-callback?…`). A first-time user is signed
    /// up from the same sign-in (Clerk's "transfer").
    public func completeOAuth(_ start: ClerkOAuthStart, callback: URL) async throws -> ClerkSession {
        guard callback.scheme == ProductInfo.urlScheme, callback.host == "oauth-callback" else { throw ClerkError.unexpected("unexpected callback") }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var query: [String: String] = [:]
        if let nonce = items.first(where: { $0.name == "rotating_token_nonce" })?.value, !nonce.isEmpty {
            query["rotating_token_nonce"] = nonce
        }
        let signIn = try await response(request("GET", "/v1/client/sign_ins/\(start.signInID)", query: query))
        if let verification = signIn["first_factor_verification"] as? [String: Any], verification["status"] as? String == "transferable" {
            let signUp = try await response(request("POST", "/v1/client/sign_ups", form: ["transfer": "true"]))
            return try await finish(signUp)
        }
        if let error = (signIn["first_factor_verification"] as? [String: Any])?["error"] as? [String: Any] {
            throw ClerkError.refused(code: error["code"] as? String ?? "oauth", message: Self.message(error) ?? "Sign-in was cancelled.")
        }
        return try await finish(signIn)
    }

    // MARK: Tokens

    /// The Convex JWT for the signed-in user (template `convex`), cached until 10 s before it expires. nil when
    /// signed out or when the session ended (then `onSessionEnded` runs). Throws `.network` when offline.
    public func token(forceRefresh: Bool) async throws -> String? {
        try await token(forceRefresh: forceRefresh, retryIfStale: true)
    }

    private func token(forceRefresh: Bool, retryIfStale: Bool) async throws -> String? {
        guard let session = state.sessionID else { return nil }
        if !forceRefresh, let cached = cachedToken, !cached.needsRefresh() { return cached.value }
        do {
            let object = try await request("POST", "/v1/client/sessions/\(session)/tokens/\(Self.tokenTemplate)")
            guard let jwt = object["jwt"] as? String else { throw ClerkError.unexpected("no token") }
            cachedToken = AuthToken(jwt)
            return jwt
        } catch ClerkError.refused(let code, _) where Self.sessionGoneCodes.contains(code) {
            endSession()
            return nil
        } catch ClerkError.stale {
            // The session changed meanwhile: signed out (nil), or a new session whose token is fetched once more.
            guard retryIfStale, state.sessionID != nil else { return nil }
            return try await token(forceRefresh: true, retryIfStale: false)
        }
    }

    /// Answers that mean the session is gone for good (as opposed to a server error, which is retried).
    static let sessionGoneCodes: Set<String> = ["signed_out", "authentication_invalid", "resource_not_found", "session_not_found", "http_401", "http_404"]

    // MARK: Requests

    /// Turns a finished sign-in or sign-up into the active session: the one it created, never another.
    private func finish(_ attempt: [String: Any]) async throws -> ClerkSession {
        let status = attempt["status"] as? String
        guard status == "complete", let sessionID = attempt["created_session_id"] as? String else {
            let missing = ((attempt["missing_fields"] as? [String]) ?? []) + ((attempt["unverified_fields"] as? [String]) ?? [])
            if !missing.isEmpty { throw ClerkError.unsupportedRequirements(missing.map { $0.replacingOccurrences(of: "_", with: " ") }) }
            if status == "needs_second_factor" { throw ClerkError.unsupportedRequirements(["a second factor"]) }
            throw ClerkError.unexpected("sign-in isn't complete (\(status ?? "no status"))")
        }
        // Make it the client's active session, as clerk-js `setActive` does.
        let touched = try await request("POST", "/v1/client/sessions/\(sessionID)/touch")
        guard let client = touched["client"] as? [String: Any] ?? lastClient, let session = Self.activeSession(in: client, id: sessionID) else {
            throw ClerkError.unexpected("the new session is missing")
        }
        // A new session: anything still running for the previous one is dropped when it returns.
        generation += 1
        state.sessionID = session.id
        state.user = session.user
        cachedToken = nil
        save()
        return session
    }

    /// The `client` object of the last response, when it carried one.
    private var lastClient: [String: Any]?

    /// Forgets the session Clerk ended and tells the app which one it was (`onSessionEnded`), so the app ends that
    /// sign-in only, however late the notice reaches it.
    private func endSession(notAdopted: ClerkUser? = nil) {
        let ended = state.sessionID.map { ClerkSessionEnd(sessionID: $0, userID: state.user?.id, notAdopted: notAdopted) }
        generation += 1
        state.sessionID = nil
        state.user = nil
        cachedToken = nil
        save()
        if let ended { onSessionEnded?(ended) }
    }

    private func save() { store.save(state) }

    private func response(_ object: [String: Any]) throws -> [String: Any] {
        guard let response = object["response"] as? [String: Any] else { throw ClerkError.unexpected("empty response") }
        return response
    }

    /// Which client token a request carries: the saved one (whose rotations it saves), or a given one whose
    /// response is never saved (the sign-out of a session already forgotten here).
    enum TokenUse { case saved, override(String?) }

    /// Sends one request to the Frontend API this client was made for. Throws `.stale` when the session generation
    /// changed while it was in flight: nothing from its response is kept.
    private func request(_ method: String, _ path: String, form: [String: String]? = nil, query: [String: String] = [:],
                         token use: TokenUse = .saved) async throws -> [String: Any] {
        var components = URLComponents(url: frontendAPI.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "_is_native", value: "true")] + query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "clerk-api-version")
        #if os(iOS)
        request.setValue("1", forHTTPHeaderField: "x-mobile")
        #else
        request.setValue("0", forHTTPHeaderField: "x-mobile")
        #endif
        let token: String? = switch use {
        case .saved: state.clientToken
        case .override(let given): given
        }
        if let token { request.setValue(token, forHTTPHeaderField: "Authorization") }
        if let form { request.httpBody = Data(Self.formEncode(form).utf8) }

        let started = generation
        let data: Data
        let http: HTTPURLResponse
        do { (data, http) = try await self.http.send(request) } catch let error as ClerkError { throw error } catch {
            throw ClerkError.network(error.localizedDescription)
        }
        guard case .saved = use else { return [:] }
        // Signed out (or the session changed) while this was in flight: keep nothing from it.
        guard started == generation else { throw ClerkError.stale }
        if let rotated = http.value(forHTTPHeaderField: "Authorization"), !rotated.isEmpty, rotated != state.clientToken {
            state.clientToken = rotated
            save()
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let client = object["client"] as? [String: Any] { lastClient = client } else { lastClient = nil }
        guard (200..<300).contains(http.statusCode) else {
            let first = (object["errors"] as? [[String: Any]])?.first
            let code = first?["code"] as? String ?? "http_\(http.statusCode)"
            throw ClerkError.refused(code: code, message: first.flatMap(Self.message) ?? "Sign-in failed (\(http.statusCode)).")
        }
        return object
    }

    static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }

    static func message(_ error: [String: Any]) -> String? {
        (error["long_message"] as? String) ?? (error["message"] as? String)
    }

    static func externalURL(_ signIn: [String: Any]) -> URL? {
        ((signIn["first_factor_verification"] as? [String: Any])?["external_verification_redirect_url"] as? String).flatMap(URL.init(string:))
    }

    /// Session `id` with its user, if the client lists it as active. Never another session: the caller asked for this
    /// one (the one a sign-in created, or the one saved).
    static func activeSession(in client: [String: Any], id: String) -> ClerkSession? {
        activeSessions(in: client).first { $0.id == id }
    }

    /// The client's active sessions with their users, the last active one first.
    static func activeSessions(in client: [String: Any]) -> [ClerkSession] {
        let sessions = ((client["sessions"] as? [[String: Any]]) ?? []).filter { ($0["status"] as? String) == "active" }
        let last = client["last_active_session_id"] as? String
        return sessions.compactMap(session(_:)).sorted { ($0.id == last ? 0 : 1) < ($1.id == last ? 0 : 1) }
    }

    private static func session(_ object: [String: Any]) -> ClerkSession? {
        guard let id = object["id"] as? String, let user = object["user"] as? [String: Any], let userID = user["id"] as? String else { return nil }
        let emails = (user["email_addresses"] as? [[String: Any]]) ?? []
        let primary = emails.first { $0["id"] as? String == user["primary_email_address_id"] as? String } ?? emails.first
        return ClerkSession(id: id, user: ClerkUser(id: userID, firstName: user["first_name"] as? String, lastName: user["last_name"] as? String,
                                                    email: primary?["email_address"] as? String,
                                                    imageURL: (user["image_url"] as? String).flatMap(URL.init(string:))))
    }
}
