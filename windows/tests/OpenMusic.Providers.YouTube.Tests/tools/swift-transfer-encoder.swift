// Produces Fixtures/transfer_swift_*.json: the Swift app's sign-in payload encoder (types copied from
// YTMCredentials.swift, Models.swift AccountInfo, YouTubeMusicSignInTransfer.swift). Run: swift swift-transfer-encoder.swift
// Output recorded on macOS 27.0.1 (identical on Linux Swift 6). The last line checks URLComponents query encoding.
import Foundation

struct AccountInfo: Hashable, Sendable, Codable {
    public var name: String
    public var avatar: URL?
    public var detail: String?
    public var id: String?
}
struct YTMCredentials: Sendable, Equatable, Codable {
    var cookies: [String: String]
    var authUser: Int = 0
    var datasyncId: String?
    enum CodingKeys: String, CodingKey { case cookies, authUser, datasyncId }
}
struct YouTubeMusicSignInPayload: Codable, Sendable {
    var version = 1
    var credentials: YTMCredentials
    var account: AccountInfo?
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
let cookies: [String: String] = [
    "SAPISID": "AbCdEfGh/IjKlMn-OpQ", "__Secure-3PAPISID": "AbCdEfGh/IjKlMn-OpQ", "__Secure-1PAPISID": "AbCdEfGh/IjKlMn-OpQ",
    "SID": "g.a000abc", "__Secure-1PSID": "g.a000one", "__Secure-3PSID": "g.a000three", "HSID": "Ah1", "SSID": "As2", "APISID": "x/y",
    "LOGIN_INFO": "AFmmF2swRQIhAK:QUQ3MjNmeE==", "PREF": "f6=40000000&tz=Europe.Paris", "SIDCC": "AKEyXz", "__Secure-1PSIDTS": "sidts-CjEB",
    "__Secure-3PSIDTS": "sidts-CjEC", "__Secure-1PSIDCC": "AKEy1", "__Secure-3PSIDCC": "AKEy3", "VISITOR_INFO1_LIVE": "abc_DEF-1",
    "YSC": "ysc1", "a": "lower", "b10": "n10", "b9": "n9", "Zed": "z", "_under": "u", "quote": "he said \"hi\" \\ back\tslash\n\u{1}\u{7f}é🎵\u{2028}<>&'",
]
let creds = YTMCredentials(cookies: cookies, authUser: 1, datasyncId: "brandABC||userXYZ")
let account = AccountInfo(name: "Zoë \"DJ\" Ünïcode 🎧", avatar: URL(string: "https://yt3.ggpht.com/abc/def=s88-c-k-c0x00ffffff-no-rj"), detail: "@zoe_dj", id: nil)
let p1 = YouTubeMusicSignInPayload(credentials: creds, account: account)
print(String(decoding: try p1.encoded(), as: UTF8.self))
let p2 = YouTubeMusicSignInPayload(credentials: YTMCredentials(cookies: ["SAPISID": "s", "SID": "i"]), account: nil)
print(String(decoding: try p2.encoded(), as: UTF8.self))
let p3 = YouTubeMusicSignInPayload(credentials: YTMCredentials(cookies: ["SAPISID": "s", "SID": "i"], authUser: 0, datasyncId: "||user"), account: AccountInfo(name: "Ada", avatar: nil, detail: nil, id: "datasync:||user"))
print(String(decoding: try p3.encoded(), as: UTF8.self))
var c = URLComponents(string: "https://music.youtube.com/youtubei/v1/browse")!
c.queryItems = [URLQueryItem(name: "prettyPrint", value: "false"), URLQueryItem(name: "ctoken", value: "4qmF+sg/K=Ab%3D%3D&x?y z#h:@!$'()*,;~")]
print(c.url!.absoluteString)
