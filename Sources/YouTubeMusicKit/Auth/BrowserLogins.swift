#if os(macOS)
import AppKit
import CommonCrypto
import CryptoKit
import Foundation
import MedleyCore
import Security
import SQLite3

/// A Chromium-family browser Medley knows how to borrow a YouTube login from.
///
/// Chromium on macOS encrypts cookie values with AES-128-CBC. The key comes from a password the browser keeps in
/// the login keychain ("<Name> Safe Storage"); reading it makes macOS ask the person for permission once.
public struct KnownBrowser: Sendable, Hashable {
    public let bundleID: String
    public let name: String
    /// Profile root, relative to `~/Library/Application Support`.
    let supportPath: String
    let keychainService: String
    let keychainAccount: String

    static let all: [KnownBrowser] = [
        KnownBrowser(bundleID: "at.studio.asidebrowser", name: "Aside", supportPath: "Aside", keychainService: "Aside Safe Storage", keychainAccount: "Aside"),
        KnownBrowser(bundleID: "net.imput.helium", name: "Helium", supportPath: "net.imput.helium", keychainService: "Helium Storage Key", keychainAccount: "Helium"),
        KnownBrowser(bundleID: "com.google.Chrome", name: "Chrome", supportPath: "Google/Chrome", keychainService: "Chrome Safe Storage", keychainAccount: "Chrome"),
        KnownBrowser(bundleID: "company.thebrowser.Browser", name: "Arc", supportPath: "Arc/User Data", keychainService: "Arc Safe Storage", keychainAccount: "Arc"),
        KnownBrowser(bundleID: "com.brave.Browser", name: "Brave", supportPath: "BraveSoftware/Brave-Browser", keychainService: "Brave Safe Storage", keychainAccount: "Brave"),
        KnownBrowser(bundleID: "com.microsoft.edgemac", name: "Edge", supportPath: "Microsoft Edge", keychainService: "Microsoft Edge Safe Storage", keychainAccount: "Microsoft Edge"),
        KnownBrowser(bundleID: "com.vivaldi.Vivaldi", name: "Vivaldi", supportPath: "Vivaldi", keychainService: "Vivaldi Safe Storage", keychainAccount: "Vivaldi"),
        KnownBrowser(bundleID: "org.chromium.Chromium", name: "Chromium", supportPath: "Chromium", keychainService: "Chromium Safe Storage", keychainAccount: "Chromium"),
    ]

    static func named(bundleID: String?) -> KnownBrowser? {
        guard let bundleID else { return nil }
        return all.first { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }
    }
}

/// One browser profile on this Mac that is signed in to YouTube.
public struct BrowserLogin: Sendable, Hashable, Identifiable {
    public let browser: KnownBrowser
    /// Directory name inside the browser's profile root ("Default", "Profile 1").
    public let profileDirectory: String
    /// The name the person gave the profile in the browser, when it has one.
    public let profileName: String?
    let cookiesURL: URL

    public var id: String { browser.bundleID + "/" + profileDirectory }
}

/// What `BrowserLogins.scan()` found.
public struct BrowserLoginScan: Sendable {
    /// Signed-in profiles, default browser first.
    public var logins: [BrowserLogin]
    /// The default browser, when Medley knows how to read it.
    public var defaultBrowser: KnownBrowser?
    /// The default browser's display name even when it isn't supported (Safari, Firefox), for copy.
    public var defaultBrowserName: String?

    /// True when the person's default browser is one Medley can read but it has no YouTube login.
    public var defaultBrowserNeedsSignIn: Bool {
        guard let defaultBrowser else { return false }
        return !logins.contains { $0.browser == defaultBrowser }
    }
}

/// Finds YouTube logins in the person's browsers and copies one into Medley.
///
/// Only cookie names are read while scanning (no keychain access). Values are decrypted only for the
/// login the person picks, and only the youtube.com cookies are kept. Nothing is logged.
public enum BrowserLogins {
    static var applicationSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    static let youtubeHosts: Set<String> = [".youtube.com", "youtube.com", "music.youtube.com", ".music.youtube.com"]

    /// Scans installed browsers for profiles with a YouTube login. File reads only; call off the main actor.
    public nonisolated static func scan() -> BrowserLoginScan {
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://music.youtube.com/")!)
        let defaultBundle = defaultApp.flatMap { Bundle(url: $0)?.bundleIdentifier }
        let defaultBrowser = KnownBrowser.named(bundleID: defaultBundle)
        let defaultName = defaultApp.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }

        var logins: [BrowserLogin] = []
        for browser in KnownBrowser.all {
            logins += profiles(of: browser, root: applicationSupport.appendingPathComponent(browser.supportPath, isDirectory: true))
        }
        logins.sort { a, b in
            let ad = a.browser == defaultBrowser, bd = b.browser == defaultBrowser
            if ad != bd { return ad }
            if a.browser != b.browser {
                return KnownBrowser.all.firstIndex(of: a.browser)! < KnownBrowser.all.firstIndex(of: b.browser)!
            }
            return profileOrder(a.profileDirectory) < profileOrder(b.profileDirectory)
        }
        return BrowserLoginScan(logins: logins, defaultBrowser: defaultBrowser, defaultBrowserName: defaultName)
    }

    /// Signed-in profiles of one browser under `root`.
    nonisolated static func profiles(of browser: KnownBrowser, root: URL) -> [BrowserLogin] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        let names = profileNames(localState: root.appendingPathComponent("Local State"))
        var found: [BrowserLogin] = []
        for dir in entries where dir == "Default" || dir.hasPrefix("Profile ") {
            let profile = root.appendingPathComponent(dir, isDirectory: true)
            let candidates = [profile.appendingPathComponent("Network/Cookies"), profile.appendingPathComponent("Cookies")]
            guard let db = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else { continue }
            guard (try? hasYouTubeSession(cookiesDB: db)) == true else { continue }
            found.append(BrowserLogin(browser: browser, profileDirectory: dir, profileName: names[dir], cookiesURL: db))
        }
        return found
    }

    /// "Default" first, then "Profile 1", "Profile 2", … in numeric order.
    static func profileOrder(_ dir: String) -> Int {
        dir == "Default" ? -1 : Int(dir.dropFirst("Profile ".count)) ?? Int.max
    }

    /// Profile directory → the name shown in the browser's profile menu, from its `Local State` file.
    nonisolated static func profileNames(localState: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: localState),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] else { return [:] }
        var names: [String: String] = [:]
        for (dir, info) in cache {
            if let name = (info as? [String: Any])?["name"] as? String, !name.isEmpty { names[dir] = name }
        }
        return names
    }

    // MARK: Reading a login

    /// Decrypts the picked profile's youtube.com cookies. Asks macOS for the browser's keychain password, which
    /// shows a permission prompt the first time, so this blocks until the person answers. Call off the main actor.
    nonisolated static func credentials(from login: BrowserLogin) throws -> YTMCredentials {
        let name = login.browser.name
        let password = try keychainPassword(service: login.browser.keychainService, account: login.browser.keychainAccount, browserName: name)
        let key = try derivedKey(password: password)
        let jar: [String: String]
        do {
            jar = try youtubeCookies(cookiesDB: login.cookiesURL, key: key)
        } catch {
            throw BrowserLoginError.unreadable(browser: name)
        }
        let creds = YTMCredentials(cookies: jar)
        guard creds.isUsable else { throw BrowserLoginError.notSignedIn(browser: name) }
        return creds
    }

    nonisolated static func keychainPassword(service: String, account: String, browserName: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, !data.isEmpty else { throw BrowserLoginError.keychainMissing(browser: browserName) }
            return data
        case errSecItemNotFound:
            throw BrowserLoginError.keychainMissing(browser: browserName)
        default:
            // errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed: the person said no.
            throw BrowserLoginError.keychainDenied(browser: browserName)
        }
    }

    /// Chromium's macOS cookie key: PBKDF2-HMAC-SHA1(password, "saltysalt", 1003 rounds), 16 bytes.
    nonisolated static func derivedKey(password: Data) throws -> Data {
        var key = Data(count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let status = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { pw in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pw.baseAddress?.assumingMemoryBound(to: CChar.self), pw.count,
                    salt, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                    keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128
                )
            }
        }
        guard status == kCCSuccess else { throw BrowserLoginError.unreadable(browser: "the browser") }
        return key
    }

    enum CookieError: Error { case open, query, decrypt }

    /// Decrypts one `encrypted_value`. Database version 24 and later prefix the plaintext with SHA-256 of the
    /// cookie's host; that prefix is checked, so a wrong key or a format change fails instead of yielding junk.
    nonisolated static func decrypt(_ blob: Data, key: Data, hostKey: String, dbVersion: Int) throws -> String {
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) || blob.prefix(3) == Data("v11".utf8) else { throw CookieError.decrypt }
        let cipher = Data(blob.dropFirst(3))
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: cipher.count + kCCBlockSizeAES128)
        var written = 0
        let outCapacity = out.count
        let status = out.withUnsafeMutableBytes { outBytes in
            cipher.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                inBytes.baseAddress, cipher.count,
                                outBytes.baseAddress, outCapacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw CookieError.decrypt }
        var plain = out.prefix(written)
        if dbVersion >= 24 {
            guard plain.count >= 32, Data(plain.prefix(32)) == Data(SHA256.hash(data: Data(hostKey.utf8))) else { throw CookieError.decrypt }
            plain = plain.dropFirst(32)
        }
        guard let text = String(data: Data(plain), encoding: .utf8) else { throw CookieError.decrypt }
        return text
    }

    /// Whether the cookie database has YouTube's session cookies (names only, nothing decrypted).
    nonisolated static func hasYouTubeSession(cookiesDB: URL) throws -> Bool {
        try withCopiedDatabase(cookiesDB) { db in
            var names: Set<String> = []
            try forEachYouTubeCookie(db) { _, name, _, _ in names.insert(name) }
            let creds = YTMCredentials(cookies: Dictionary(uniqueKeysWithValues: names.map { ($0, "x") }))
            return creds.isUsable
        }
    }

    /// The host Medley sends YouTube Music requests to. Only cookies a browser would send here are used.
    static let musicHost = "music.youtube.com"

    /// Whether a cookie stored under `host` (Chromium's `host_key`) is sent with requests to music.youtube.com.
    /// A leading dot marks a domain cookie, sent to that domain and its subdomains; without one the cookie is
    /// host-only and sent to that exact host. So `.youtube.com` applies, but host-only `youtube.com` does not.
    static func appliesToMusic(host: String) -> Bool {
        if host.hasPrefix(".") {
            let domain = String(host.dropFirst())
            return musicHost == domain || musicHost.hasSuffix("." + domain)
        }
        return host == musicHost
    }

    /// How specific a cookie's host is, for picking one value when a name appears on several applicable hosts.
    /// A longer domain is more specific, and a host-only cookie beats a domain cookie for the same name, as in
    /// a browser: host-only `music.youtube.com` > `.music.youtube.com` > `.youtube.com`.
    static func specificity(host: String) -> Int {
        host.hasPrefix(".") ? (host.count - 1) * 2 : host.count * 2 + 1
    }

    /// The youtube.com cookies in a Chromium cookie database that apply to music.youtube.com, decrypted with
    /// `key`. Expired cookies are skipped; when a name appears on several hosts the most specific one wins.
    nonisolated static func youtubeCookies(cookiesDB: URL, key: Data) throws -> [String: String] {
        try withCopiedDatabase(cookiesDB) { db in
            let version = metaVersion(db)
            var jar: [String: String] = [:]
            var chosen: [String: Int] = [:]
            try forEachYouTubeCookie(db) { host, name, value, encrypted in
                let rank = specificity(host: host)
                if let existing = chosen[name], existing >= rank { return }
                let plain = encrypted.isEmpty ? value : try decrypt(encrypted, key: key, hostKey: host, dbVersion: version)
                jar[name] = plain
                chosen[name] = rank
            }
            return jar
        }
    }

    /// Opens a private copy of the database. The browser keeps the original open (and locked) while it runs, so
    /// Medley copies the main file plus any write-ahead log, shared-memory and rollback-journal files. A copy taken
    /// mid-write is at worst a moment stale: the main file is self-consistent without the log, which only adds
    /// newer committed writes. The copy is removed afterwards.
    nonisolated static func withCopiedDatabase<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("medley-cookies-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("Cookies")
        try fm.copyItem(at: url, to: copy)
        for suffix in ["-wal", "-shm", "-journal"] {
            let side = URL(fileURLWithPath: url.path + suffix)
            guard fm.fileExists(atPath: side.path) else { continue }
            // A sidecar that vanished between the check and the copy (the browser checkpointed) is fine to skip.
            try? fm.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix))
        }
        var db: OpaquePointer?
        // Read-write, on the private copy only: if the browser was mid-transaction in rollback-journal mode the copy
        // has a hot journal, and SQLite can only roll that back through a handle that may write.
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw CookieError.open
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        return try body(db)
    }

    nonisolated static func metaVersion(_ db: OpaquePointer) -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'version'", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return 0 }
        return Int(String(cString: text)) ?? 0
    }

    /// Calls `body(host, name, value, encryptedValue)` for each unexpired youtube.com cookie.
    nonisolated static func forEachYouTubeCookie(_ db: OpaquePointer, _ body: (String, String, String, Data) throws -> Void) throws {
        // expires_utc counts microseconds since 1601-01-01; 0 means a session cookie.
        let now = Int64((Date().timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        let hosts = youtubeHosts.map { "'\($0)'" }.joined(separator: ",")
        let sql = "SELECT host_key, name, value, encrypted_value FROM cookies WHERE host_key IN (\(hosts)) AND (expires_utc = 0 OR expires_utc > ?)"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw CookieError.query }
        sqlite3_bind_int64(stmt, 1, now)
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw CookieError.query }
            let host = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let value = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let count = Int(sqlite3_column_bytes(stmt, 3))
            let encrypted = count > 0 ? Data(bytes: sqlite3_column_blob(stmt, 3), count: count) : Data()
            // Skip cookies a browser wouldn't send to music.youtube.com (e.g. host-only `youtube.com`), so the
            // scan and the import agree on what counts as a session.
            guard !name.isEmpty, appliesToMusic(host: host) else { continue }
            try body(host, name, value, encrypted)
        }
    }

    // MARK: Diagnostics (medley-probe)

    /// Decrypts every cookie in a Chromium cookie database with a given storage password and counts how many
    /// pass the host-hash check. Prints nothing and returns no values; used to check the algorithm against a
    /// real browser's database (for example one written with `--use-mock-keychain`).
    public nonisolated static func decryptCheck(cookiesDB: URL, password: String) throws -> (version: Int, total: Int, decrypted: Int) {
        let key = try derivedKey(password: Data(password.utf8))
        return try withCopiedDatabase(cookiesDB) { db in
            let version = metaVersion(db)
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT host_key, encrypted_value FROM cookies", -1, &stmt, nil) == SQLITE_OK else { throw CookieError.query }
            var total = 0, ok = 0
            while sqlite3_step(stmt) == SQLITE_ROW {
                let host = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let count = Int(sqlite3_column_bytes(stmt, 1))
                guard count > 0 else { continue }
                total += 1
                let blob = Data(bytes: sqlite3_column_blob(stmt, 1), count: count)
                if (try? decrypt(blob, key: key, hostKey: host, dbVersion: version)) != nil { ok += 1 }
            }
            return (version, total, ok)
        }
    }

    // MARK: Opening the browser

    /// Opens music.youtube.com in `browser`, so the person can sign in there.
    @MainActor
    public static func openYouTubeMusic(in browser: KnownBrowser) {
        let url = URL(string: "https://music.youtube.com/")!
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @MainActor
    public static func icon(for browser: KnownBrowser) -> NSImage? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: app.path)
    }
}

#endif
