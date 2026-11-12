import CryptoKit
import Foundation
import OpenMusicCore

/// Google session cookies for music.youtube.com, and the auth headers the web client derives from them.
struct YTMCredentials: Sendable, Equatable, Codable {
    /// Cookie name → value, for cookies scoped to .youtube.com.
    var cookies: [String: String]
    /// Multi-login index (`X-Goog-AuthUser`): which Google account signed in to the browser.
    var authUser: Int = 0
    /// The chosen channel's datasync id, as the account switcher gives it: `delegatedSessionId||userSessionId`
    /// for a brand channel, or no delegated prefix for a personal account. Nil means the account's default channel.
    var datasyncId: String?

    static let origin = "https://music.youtube.com"

    init(cookies: [String: String], authUser: Int = 0, datasyncId: String? = nil) {
        self.cookies = cookies
        self.authUser = authUser
        self.datasyncId = datasyncId
    }

    // Codable with a datasyncId added later: old saved credentials without it still decode.
    enum CodingKeys: String, CodingKey { case cookies, authUser, datasyncId }

    /// The delegated session id a brand channel is selected by (the part before `||` in the datasync id), sent as
    /// both `X-Goog-PageId` and context `onBehalfOfUser`, the way youtube.com's own client does. Nil for a personal
    /// account, whose datasync id has no `||`, an empty prefix (`||user`), or an empty suffix (`user||`).
    var delegatedSessionId: String? { YTMCredentials.delegatedSessionId(datasyncId) }

    static func delegatedSessionId(_ datasyncId: String?) -> String? {
        guard let datasyncId, let sep = datasyncId.range(of: "||") else { return nil }
        let prefix = String(datasyncId[..<sep.lowerBound])
        let suffix = String(datasyncId[sep.upperBound...])
        // A brand channel is `delegatedSessionId||userSessionId`: both sides present. A primary account is
        // `||userSessionId` or `userSessionId||`, which carries no channel to switch to.
        return (prefix.isEmpty || suffix.isEmpty) ? nil : prefix
    }

    /// Parses a `Cookie:` header as copied from a browser's dev tools (with or without the `cookie:` prefix).
    init?(cookieHeader raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("cookie:") { text = String(text.dropFirst(7)) }
        var jar: [String: String] = [:]
        for pair in text.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            if !name.isEmpty { jar[name] = value }
        }
        self.init(cookies: jar)
        guard isUsable else { return nil }
    }

    /// True when the jar has what InnerTube needs to authenticate a request.
    var isUsable: Bool { sapisid != nil && (cookies["SID"] != nil || cookies["__Secure-3PSID"] != nil || cookies["__Secure-1PSID"] != nil) }

    var sapisid: String? { cookies["SAPISID"] ?? cookies["__Secure-3PAPISID"] }

    var cookieHeader: String {
        cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    /// `SAPISIDHASH <ts>_<sha1("<ts> <SAPISID> <origin>")>`, plus the 1P/3P variants the current web client sends.
    func authorization(now: Date = Date()) -> String? {
        guard let sapisid else { return nil }
        let ts = String(Int(now.timeIntervalSince1970))
        func hash(_ secret: String) -> String {
            let digest = Insecure.SHA1.hash(data: Data("\(ts) \(secret) \(Self.origin)".utf8))
            return ts + "_" + digest.map { String(format: "%02x", $0) }.joined()
        }
        var parts = ["SAPISIDHASH \(hash(sapisid))"]
        if let p1 = cookies["__Secure-1PAPISID"] { parts.append("SAPISID1PHASH \(hash(p1))") }
        if let p3 = cookies["__Secure-3PAPISID"] { parts.append("SAPISID3PHASH \(hash(p3))") }
        return parts.joined(separator: " ")
    }

    /// Headers for an authenticated InnerTube request.
    func headers(now: Date = Date()) -> [String: String] {
        var h = [
            "Cookie": cookieHeader,
            "X-Origin": Self.origin,
            "X-Goog-AuthUser": String(authUser),
        ]
        if let auth = authorization(now: now) { h["Authorization"] = auth }
        if let delegatedSessionId { h["X-Goog-PageId"] = delegatedSessionId }
        return h
    }

    /// Applies `Set-Cookie` updates from a response (Google rotates `__Secure-*PSIDTS` and friends).
    /// Returns true if anything changed.
    mutating func merge(setCookieHeaders fields: [AnyHashable: Any], url: URL) -> Bool {
        var headerFields: [String: String] = [:]
        for (k, v) in fields { if let k = k as? String, let v = v as? String { headerFields[k] = v } }
        let incoming = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
        var changed = false
        for cookie in incoming where cookie.domain.hasSuffix("youtube.com") {
            if let expires = cookie.expiresDate, expires < Date() {
                if cookies.removeValue(forKey: cookie.name) != nil { changed = true }
            } else if cookies[cookie.name] != cookie.value {
                cookies[cookie.name] = cookie.value
                changed = true
            }
        }
        return changed
    }

    // MARK: Keychain

    static let keychainKey = "ytm.credentials"
    static let accountKey = "ytm.account"

    static func load() -> YTMCredentials? { Keychain.codable(YTMCredentials.self, for: keychainKey) }
    /// Throws when the Keychain didn't take them.
    func save() throws { try Keychain.storeCodable(self, for: Self.keychainKey) }
    /// Deletes the saved cookies, throwing when they couldn't be deleted. The account summary next to them holds no
    /// credentials and is deleted as well as possible.
    static func clear() throws {
        try Keychain.store(nil, for: keychainKey)
        Keychain.set(nil, for: accountKey)
    }
}
