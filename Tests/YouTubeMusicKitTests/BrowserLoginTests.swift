import CommonCrypto
import CryptoKit
import Foundation
import OpenMusicCore
import SQLite3
import Testing
@testable import YouTubeMusicKit

/// Builds Chromium-format cookie databases (meta version 24, v10 AES-128-CBC values with the host-hash prefix)
/// and checks that OpenMusic reads back exactly the youtube.com session.
@Suite struct BrowserLoginReading {
    static let password = "test-storage-password"

    struct Row {
        var host: String
        var name: String
        var value: String
        /// Microseconds since 1601; 0 = session cookie.
        var expires: Int64 = 0
    }

    static func chromiumTime(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000) }

    static func encrypt(_ value: String, host: String, key: Data, version: Int) -> Data {
        var plain = Data()
        if version >= 24 { plain.append(Data(SHA256.hash(data: Data(host.utf8)))) }
        plain.append(Data(value.utf8))
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: plain.count + kCCBlockSizeAES128)
        var written = 0
        let capacity = out.count
        _ = out.withUnsafeMutableBytes { o in
            plain.withUnsafeBytes { p in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { i in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, i.baseAddress, p.baseAddress, plain.count, o.baseAddress, capacity, &written)
                    }
                }
            }
        }
        return Data("v10".utf8) + out.prefix(written)
    }

    static func makeDatabase(at url: URL, rows: [Row], version: Int = 24, password: String = password) throws {
        let key = try BrowserLogins.derivedKey(password: Data(password.utf8))
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
        CREATE TABLE cookies(host_key TEXT NOT NULL, name TEXT NOT NULL, value TEXT NOT NULL, encrypted_value BLOB NOT NULL, expires_utc INTEGER NOT NULL);
        INSERT INTO meta VALUES('version', '\(version)');
        """
        try #require(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
        for row in rows {
            var stmt: OpaquePointer?
            try #require(sqlite3_prepare_v2(db, "INSERT INTO cookies VALUES(?, ?, '', ?, ?)", -1, &stmt, nil) == SQLITE_OK)
            let blob = encrypt(row.value, host: row.host, key: key, version: version)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, row.host, -1, transient)
            sqlite3_bind_text(stmt, 2, row.name, -1, transient)
            _ = blob.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(blob.count), transient) }
            sqlite3_bind_int64(stmt, 4, row.expires)
            try #require(sqlite3_step(stmt) == SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
    }

    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("openmusic-browser-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static let session: [Row] = [
        Row(host: ".youtube.com", name: "SAPISID", value: "sap-value/abc"),
        Row(host: ".youtube.com", name: "SID", value: "sid-value"),
        Row(host: ".youtube.com", name: "__Secure-3PAPISID", value: "sap3-value"),
    ]

    @Test func readsTheYouTubeSessionAndNothingElse() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("Cookies")
        let future = Self.chromiumTime(Date().addingTimeInterval(86_400 * 30))
        try Self.makeDatabase(at: db, rows: Self.session + [
            Row(host: ".google.com", name: "SID", value: "google-sid", expires: future),
            Row(host: ".example.com", name: "tracker", value: "nope"),
        ])
        let key = try BrowserLogins.derivedKey(password: Data(Self.password.utf8))
        let jar = try BrowserLogins.youtubeCookies(cookiesDB: db, key: key)
        #expect(jar == ["SAPISID": "sap-value/abc", "SID": "sid-value", "__Secure-3PAPISID": "sap3-value"])
        #expect(YTMCredentials(cookies: jar).isUsable)
        #expect(try BrowserLogins.hasYouTubeSession(cookiesDB: db))
    }

    @Test func skipsExpiredCookiesAndPrefersTheMoreSpecificHost() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("Cookies")
        let past = Self.chromiumTime(Date().addingTimeInterval(-3600))
        try Self.makeDatabase(at: db, rows: Self.session + [
            Row(host: ".youtube.com", name: "OLD", value: "expired", expires: past),
            Row(host: "music.youtube.com", name: "SID", value: "music-sid"),
        ])
        let key = try BrowserLogins.derivedKey(password: Data(Self.password.utf8))
        let jar = try BrowserLogins.youtubeCookies(cookiesDB: db, key: key)
        #expect(jar["OLD"] == nil)
        #expect(jar["SID"] == "music-sid")
    }

    @Test func ignoresHostOnlyRootCookiesAMusicRequestNeverSends() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("Cookies")
        // Host-only `youtube.com` is listed first and must lose regardless: a browser never sends it to
        // music.youtube.com, so it would break the session if it overrode the real `.youtube.com` SID.
        try Self.makeDatabase(at: db, rows: [
            Row(host: "youtube.com", name: "SID", value: "root-only-sid"),
            Row(host: ".youtube.com", name: "SID", value: "domain-sid"),
            Row(host: ".youtube.com", name: "SAPISID", value: "sap"),
        ])
        let key = try BrowserLogins.derivedKey(password: Data(Self.password.utf8))
        #expect(try BrowserLogins.youtubeCookies(cookiesDB: db, key: key)["SID"] == "domain-sid")
    }

    @Test func picksTheMostSpecificHostWhateverTheRowOrder() throws {
        let rows = [
            Row(host: ".youtube.com", name: "SID", value: "broad"),
            Row(host: ".music.youtube.com", name: "SID", value: "music-domain"),
            Row(host: "music.youtube.com", name: "SID", value: "music-host"),
            Row(host: ".youtube.com", name: "SAPISID", value: "sap"),
        ]
        let key = try BrowserLogins.derivedKey(password: Data(Self.password.utf8))
        for ordering in [rows, rows.reversed()] {
            let dir = try Self.tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let db = dir.appendingPathComponent("Cookies")
            try Self.makeDatabase(at: db, rows: Array(ordering))
            #expect(try BrowserLogins.youtubeCookies(cookiesDB: db, key: key)["SID"] == "music-host")
        }
    }

    @Test func hostApplicabilityMatchesWhatABrowserSends() {
        #expect(BrowserLogins.appliesToMusic(host: ".youtube.com"))
        #expect(BrowserLogins.appliesToMusic(host: ".music.youtube.com"))
        #expect(BrowserLogins.appliesToMusic(host: "music.youtube.com"))
        #expect(!BrowserLogins.appliesToMusic(host: "youtube.com"))
        #expect(!BrowserLogins.appliesToMusic(host: ".www.youtube.com"))
        #expect(!BrowserLogins.appliesToMusic(host: ".notyoutube.com"))
    }

    /// The browser may keep its database in WAL mode with recent writes still in the `-wal` file. OpenMusic must
    /// copy that log alongside the main file and read those rows too (a regression guard for the copy step).
    @Test func readsCookiesThatOnlyExistInTheWriteAheadLog() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("Cookies")
        try Self.makeDatabase(at: db, rows: [Row(host: ".youtube.com", name: "SAPISID", value: "sap")])
        // Reopen as the "browser": switch to WAL, stop auto-checkpointing, and write SID into the log only.
        var writer: OpaquePointer?
        try #require(sqlite3_open(db.path, &writer) == SQLITE_OK)
        defer { sqlite3_close(writer) }
        try #require(sqlite3_exec(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;", nil, nil, nil) == SQLITE_OK)
        let key = try BrowserLogins.derivedKey(password: Data(Self.password.utf8))
        let blob = Self.encrypt("wal-sid", host: ".youtube.com", key: key, version: 24)
        var stmt: OpaquePointer?
        try #require(sqlite3_prepare_v2(writer, "INSERT INTO cookies VALUES('.youtube.com', 'SID', '', ?, 0)", -1, &stmt, nil) == SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = blob.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(blob.count), transient) }
        try #require(sqlite3_step(stmt) == SQLITE_DONE)
        sqlite3_finalize(stmt)
        #expect(FileManager.default.fileExists(atPath: db.path + "-wal"))

        let jar = try BrowserLogins.youtubeCookies(cookiesDB: db, key: key)
        #expect(jar["SID"] == "wal-sid")
        #expect(try BrowserLogins.hasYouTubeSession(cookiesDB: db))
    }

    @Test func aWrongKeyFailsInsteadOfReturningJunk() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("Cookies")
        try Self.makeDatabase(at: db, rows: Self.session)
        let wrong = try BrowserLogins.derivedKey(password: Data("another password".utf8))
        #expect(throws: (any Error).self) { try BrowserLogins.youtubeCookies(cookiesDB: db, key: wrong) }
    }

    @Test func readsOlderDatabasesWithoutTheHostPrefix() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("Cookies")
        try Self.makeDatabase(at: db, rows: Self.session, version: 21)
        let key = try BrowserLogins.derivedKey(password: Data(Self.password.utf8))
        #expect(try BrowserLogins.youtubeCookies(cookiesDB: db, key: key)["SID"] == "sid-value")
    }

    @Test func aSignedOutProfileIsNotOffered() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("Aside")
        for profile in ["Default", "Profile 1", "Profile 2"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(profile), withIntermediateDirectories: true)
        }
        // Default is signed in; Profile 1 only has visitor cookies; Profile 2 is signed in (newer Network/ path).
        try Self.makeDatabase(at: root.appendingPathComponent("Default/Cookies"), rows: Self.session)
        try Self.makeDatabase(at: root.appendingPathComponent("Profile 1/Cookies"), rows: [Row(host: ".youtube.com", name: "YSC", value: "visitor")])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Profile 2/Network"), withIntermediateDirectories: true)
        try Self.makeDatabase(at: root.appendingPathComponent("Profile 2/Network/Cookies"), rows: Self.session)
        let localState = #"{"profile":{"info_cache":{"Default":{"name":"Work"},"Profile 2":{"name":"Home"}}}}"#
        try Data(localState.utf8).write(to: root.appendingPathComponent("Local State"))

        let browser = KnownBrowser.named(bundleID: "at.studio.asidebrowser")!
        let found = BrowserLogins.profiles(of: browser, root: root).sorted { BrowserLogins.profileOrder($0.profileDirectory) < BrowserLogins.profileOrder($1.profileDirectory) }
        #expect(found.map(\.profileDirectory) == ["Default", "Profile 2"])
        #expect(found.map(\.profileName) == ["Work", "Home"])
    }

    @Test func browserLookupIgnoresCase() {
        #expect(KnownBrowser.named(bundleID: "com.google.chrome")?.name == "Chrome")
        #expect(KnownBrowser.named(bundleID: "com.apple.Safari") == nil)
    }

    /// The account picker selects an account by its `X-Goog-AuthUser` index; the credentials must send it.
    @Test func authUserIndexGoesOutAsAHeader() {
        let creds = YTMCredentials(cookies: ["SAPISID": "x", "SID": "y"], authUser: 2)
        #expect(creds.headers()["X-Goog-AuthUser"] == "2")
        var zero = creds
        zero.authUser = 0
        #expect(zero.headers()["X-Goog-AuthUser"] == "0")
    }

    /// A brand channel is selected by its delegated session id (before `||`), sent as X-Goog-PageId. The personal
    /// account formats — `||user`, `user||`, or no `||` at all — carry no channel, so send no page id.
    @Test func brandChannelSendsDelegatedSessionAsPageId() {
        let channel = YTMCredentials(cookies: ["SAPISID": "x", "SID": "y"], authUser: 0, datasyncId: "CHAN123||SESS456")
        #expect(channel.delegatedSessionId == "CHAN123")
        #expect(channel.headers()["X-Goog-PageId"] == "CHAN123")
        for personalDatasync in ["||SESS456", "SESS456||", "SESS456"] {
            let personal = YTMCredentials(cookies: ["SAPISID": "x", "SID": "y"], authUser: 0, datasyncId: personalDatasync)
            #expect(personal.delegatedSessionId == nil, "\(personalDatasync) should not be a channel")
            #expect(personal.headers()["X-Goog-PageId"] == nil)
        }
        let noDatasync = YTMCredentials(cookies: ["SAPISID": "x", "SID": "y"])
        #expect(noDatasync.headers()["X-Goog-PageId"] == nil)
    }

    /// Credentials saved before datasyncId existed still decode (the key is optional).
    @Test func oldCredentialsWithoutIdentityStillDecode() throws {
        let old = #"{"cookies":{"SAPISID":"x","SID":"y"},"authUser":0}"#
        let creds = try JSONDecoder().decode(YTMCredentials.self, from: Data(old.utf8))
        #expect(creds.datasyncId == nil)
        #expect(creds.isUsable)
    }

}

@Suite struct AccountSwitcherParsing {
    /// The real shape (Nov 2026, anonymized): one section per Google account; each item's selectors sit in
    /// `supportedTokens` as `datasyncIdToken.datasyncIdToken`, `pageIdToken.pageId`, and a signin URL carrying
    /// `authuser`. Here: a personal account (`user||`) plus a brand channel under authuser 0, and a second Google
    /// account (authuser 1) whose section order and signin URL agree. The brand channel is the selected one.
    static let response = """
    )]}'
    {"code":"SUCCESS","data":{"actions":[{"getMultiPageMenuAction":{"menu":{"multiPageMenuRenderer":{"sections":[
      {"accountSectionListRenderer":{"contents":[{"accountItemSectionRenderer":{"contents":[
        {"accountItem":{"accountName":{"simpleText":"Leo Personal"},"isSelected":false,"hasChannel":true,
          "accountByline":{"simpleText":"12 subscribers"},"channelHandle":{"simpleText":"@leo"},
          "accountPhoto":{"thumbnails":[{"url":"https://x/p0.jpg"}]},
          "serviceEndpoint":{"selectActiveIdentityEndpoint":{"supportedTokens":[
            {"accountStateToken":{"hasChannel":true,"isMerged":false,"obfuscatedGaiaId":"USER0"}},
            {"accountSigninToken":{"signinUrl":"/signin?action_handle_signin=true&authuser=0&next=https%3A%2F%2Fmusic.youtube.com%2F"}},
            {"datasyncIdToken":{"datasyncIdToken":"USER0||"}}]}}}},
        {"accountItem":{"accountName":{"runs":[{"text":"Leo's "},{"text":"Band"}]},"isSelected":true,"hasChannel":true,
          "accountByline":{"simpleText":"7 subscribers"},"channelHandle":{"simpleText":"@leosband"},
          "accountPhoto":{"thumbnails":[{"url":"https://x/p1.jpg"}]},
          "serviceEndpoint":{"selectActiveIdentityEndpoint":{"supportedTokens":[
            {"pageIdToken":{"pageId":"CHAN1"}},
            {"accountSigninToken":{"signinUrl":"/signin?action_handle_signin=true&authuser=0&pageid=CHAN1&next=https%3A%2F%2Fmusic.youtube.com%2F"}},
            {"datasyncIdToken":{"datasyncIdToken":"CHAN1||USER0"}}]}}}}
      ]}},
      {"accountItemSectionRenderer":{"contents":[
        {"accountItem":{"accountName":{"simpleText":"Leo Work"},"isSelected":false,
          "accountByline":{"simpleText":"work@x.com"},
          "serviceEndpoint":{"selectActiveIdentityEndpoint":{"supportedTokens":[
            {"accountSigninToken":{"signinUrl":"/signin?action_handle_signin=true&authuser=1&next=%2F"}},
            {"datasyncIdToken":{"datasyncIdToken":"USER1||"}}]}}}}
      ]}}]}}
    ]}}}}]}}
    """

    func identities() -> [AccountIdentity] {
        var text = Self.response
        if text.hasPrefix(")]}'") { text = String(text.dropFirst(4)) }
        return AccountSwitcherParser.identities(fromJSON: Data(text.utf8))
    }

    @Test func listsEveryAccountAndChannelInOrder() {
        let ids = identities()
        #expect(ids.map(\.listedName) == ["Leo Personal", "Leo's Band", "Leo Work"])
        #expect(ids.map(\.authUser) == [0, 0, 1])
    }

    /// Regression: the channel id lives in `datasyncIdToken.datasyncIdToken`. Reading only `datasyncId` left every
    /// channel without a selector, so they all collapsed into the default account and that one signed in.
    @Test func readsTheChannelSelectorFromTheDatasyncToken() {
        let ids = identities()
        #expect(ids.map(\.datasyncId) == ["USER0||", "CHAN1||USER0", "USER1||"])
        #expect(ids.map(\.delegatedSessionId) == [nil, "CHAN1", nil])
        #expect(Set(ids.map(\.selectorKey)).count == 3)
    }

    @Test func marksTheSelectedChannel() {
        #expect(identities().map(\.isSelected) == [false, true, false])
    }

    @Test func authUserComesFromTheSigninURL() {
        // The signin URL wins over section order when they disagree.
        let item: [String: Any] = [
            "accountName": ["simpleText": "X"],
            "serviceEndpoint": ["selectActiveIdentityEndpoint": ["supportedTokens": [
                ["accountSigninToken": ["signinUrl": "/signin?authuser=3&pageid=P"]],
                ["datasyncIdToken": ["datasyncIdToken": "P||U"]],
            ]]],
        ]
        let id = AccountSwitcherParser.identity(fromItem: item, authUser: 0)
        #expect(id?.authUser == 3)
        #expect(id?.delegatedSessionId == "P")
    }

    @Test func stillReadsAPlainDatasyncIdKey() {
        let item: [String: Any] = ["accountName": ["simpleText": "X"], "datasyncId": "C||U"]
        #expect(AccountSwitcherParser.identity(fromItem: item, authUser: 2)?.datasyncId == "C||U")
        #expect(AccountSwitcherParser.identity(fromItem: item, authUser: 2)?.authUser == 2)
    }

    @Test func readsNamesFromSimpleTextOrRuns() {
        #expect(identities()[1].listedName == "Leo's Band")  // joined from two runs
        #expect(identities()[2].listedByline == "work@x.com")
    }

    @Test func emptyOrGarbageYieldsNoIdentities() {
        #expect(AccountSwitcherParser.identities(fromJSON: Data("not json".utf8)).isEmpty)
        #expect(AccountSwitcherParser.identities(fromJSON: Data("{}".utf8)).isEmpty)
    }
}
