import Foundation

/// Supplies the JWT the Convex client authenticates with (a Clerk session token from the `convex` template).
/// `ClerkSession` is the real one; tests use a fake.
public protocol AuthTokenProvider: Sendable {
    /// The current token, or nil when signed out. With `forceRefresh`, skip any cached token: the server refused
    /// it, or it is about to expire. Throws when it can't be fetched right now (offline); the client retries.
    func token(forceRefresh: Bool) async throws -> String?
}

extension ConvexClient {
    /// Where the client's identity stands. Part of `Status`.
    public enum AuthState: Sendable, Equatable {
        /// No token provider, or it says signed out. Functions that need an identity throw `unauthenticated`.
        case none
        /// A token was sent; the server hasn't confirmed it yet.
        case pending
        /// The server accepted the token.
        case authenticated
        /// The server refused fresh tokens repeatedly. The socket runs without an identity until `setAuth` is
        /// called again.
        case failed(String)
    }
}

/// A token as the client keeps it: its text and when to refresh it.
struct AuthToken: Sendable, Equatable {
    var value: String
    /// When to fetch a new one: `refreshLeeway` before it expires, by its own lifetime (`exp - iat`) counted from
    /// when it arrived, so a skewed device clock doesn't matter. nil when the token carries no lifetime.
    var refreshAt: ContinuousClock.Instant?
    /// Who the token signs in (its `sub` claim: the Clerk user id), nil when it doesn't say.
    var subject: String?

    static let refreshLeeway: Duration = .seconds(10)

    init(_ value: String, receivedAt: ContinuousClock.Instant = .now) {
        self.value = value
        let claims = JWTClaims(value)
        subject = claims?.sub
        if let claims, let exp = claims.exp, let iat = claims.iat, exp > iat {
            refreshAt = receivedAt + .seconds(max(0, exp - iat)) - Self.refreshLeeway
        } else {
            refreshAt = nil
        }
    }

    func needsRefresh(at now: ContinuousClock.Instant = .now) -> Bool {
        refreshAt.map { now >= $0 } ?? false
    }
}

/// The `exp`, `iat` and `sub` claims of a JWT (times in seconds since 1970), decoded without checking the signature.
/// Convex verifies every token and is the authorization boundary; nothing here is verification. `sub` is a routing
/// guard only: it keeps the client's own bookkeeping straight, so a call made for one identity never goes out with a
/// token the client fetched for another (`ConvexClient.matches`). A forged or tampered token passes it and still gets
/// nothing from the server.
struct JWTClaims: Sendable, Equatable {
    var exp: Double?
    var iat: Double?
    var sub: String?

    init?(_ jwt: String) {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = Data(base64URLEncoded: String(parts[1])),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        exp = (object["exp"] as? NSNumber)?.doubleValue
        iat = (object["iat"] as? NSNumber)?.doubleValue
        sub = object["sub"] as? String
    }
}

extension ClientMessage {
    /// `Authenticate` with a user token. `baseVersion` is the identity version the client is at before it.
    static func authenticate(token: String, baseVersion: Int) -> String {
        ConvexValue.object([
            "type": .string("Authenticate"),
            "tokenType": .string("User"),
            "value": .string(token),
            "baseVersion": .float64(Double(baseVersion)),
        ]).jsonString()
    }

    /// `Authenticate` with no token: drops the identity on an open socket.
    static func authenticateNone(baseVersion: Int) -> String {
        ConvexValue.object([
            "type": .string("Authenticate"),
            "tokenType": .string("None"),
            "baseVersion": .float64(Double(baseVersion)),
        ]).jsonString()
    }
}
