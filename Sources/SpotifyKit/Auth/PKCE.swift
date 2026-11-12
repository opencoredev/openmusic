import CryptoKit
import Foundation
import Security

/// RFC 7636 Proof Key for Code Exchange, S256 method.
public struct PKCE: Sendable, Hashable {
    public let verifier: String
    public let challenge: String
    public let method = "S256"

    /// A fresh verifier: 64 random bytes, base64url without padding (86 characters, within 43...128).
    public init() {
        var bytes = [UInt8](repeating: 0, count: 64)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // SecRandomCopyBytes does not fail in practice; fall back to the system RNG rather than crash.
            var rng = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        }
        self.init(verifier: Self.base64URL(Data(bytes)))
    }

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Self.challenge(for: verifier)
    }

    /// BASE64URL(SHA256(ASCII(verifier))).
    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Random URL-safe string for the OAuth `state` parameter.
    public static func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }
}
