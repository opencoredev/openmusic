import Foundation

/// For live tests and the probe: a Clerk session JWT (template "convex") kept in a file instead of a Clerk sign-in.
/// A Clerk session JWT kept in a file, read again on every fetch so another process can keep it fresh.
public struct JWTFileTokens: AuthTokenProvider {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func token(forceRefresh: Bool) async throws -> String? { try read() }

    private func read() throws -> String? {
        let text = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The `sub` claim: the Clerk user id.
    public func userID() throws -> String? {
        guard let token = try read() else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["sub"] as? String
    }
}
