import Foundation
import MedleyCore

/// One identity in YouTube's account switcher: a Google account (`authUser`) or a channel / brand account under
/// it (selected by `datasyncId`). This is what the browser shows under your avatar.
public struct AccountIdentity: Sendable, Hashable {
    public var authUser: Int
    /// `delegatedSessionId||userSessionId` for a brand channel, else the personal account's (no delegated prefix).
    public var datasyncId: String?
    /// The name and photo the switcher listed, before the account is confirmed by a real request.
    public var listedName: String?
    public var listedByline: String?
    public var photo: URL?
    /// The identity the session currently acts as: the account or channel just picked on YouTube's own
    /// "Choose a channel" page (or last used in the browser).
    public var isSelected: Bool

    public init(authUser: Int, datasyncId: String? = nil, listedName: String? = nil, listedByline: String? = nil,
                photo: URL? = nil, isSelected: Bool = false) {
        self.authUser = authUser
        self.datasyncId = datasyncId
        self.listedName = listedName
        self.listedByline = listedByline
        self.photo = photo
        self.isSelected = isSelected
    }

    /// The delegated session id that selects a brand channel (the part before `||`, when both sides are present).
    /// Nil for a personal account.
    public var delegatedSessionId: String? { YTMCredentials.delegatedSessionId(datasyncId) }

    /// A stable key for this identity's selectors, to dedupe without relying on the display name.
    public var selectorKey: String { "\(authUser)|\(delegatedSessionId ?? "")" }
}

/// Parses `getAccountSwitcherEndpoint` into the identities it lists, in the order they appear.
///
/// The response (its `)]}'` guard already stripped) nests `accountItemSectionRenderer` sections, one per signed-in
/// Google account, each holding `accountItem`s for that account and its channels. Each item's selectors sit in
/// `serviceEndpoint.selectActiveIdentityEndpoint.supportedTokens`:
///
///     {"datasyncIdToken": {"datasyncIdToken": "<delegatedSessionId>||<userSessionId>"}}
///     {"pageIdToken": {"pageId": "<delegatedSessionId>"}}
///     {"accountSigninToken": {"signinUrl": "/signin?...&authuser=0&pageid=<delegatedSessionId>&..."}}
///
/// (shape seen on music.youtube.com, Nov 2026). The authUser comes from the signin URL when present, else the
/// section's order. Names read from `simpleText` or `runs`. Each identity is still confirmed by a real request in
/// `prepareAccounts`, so a wrong guess here can't sign anyone in to the wrong account.
public enum AccountSwitcherParser {
    public static func identities(fromJSON data: Data) -> [AccountIdentity] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let sections = collect(key: "accountItemSectionRenderer", in: root)
        var identities: [AccountIdentity] = []
        if sections.isEmpty {
            for item in collect(key: "accountItem", in: root) {
                if let id = identity(fromItem: item, authUser: 0) { identities.append(id) }
            }
        } else {
            for (authUser, section) in sections.enumerated() {
                for item in collect(key: "accountItem", in: section) {
                    if let id = identity(fromItem: item, authUser: authUser) { identities.append(id) }
                }
            }
        }
        return identities
    }

    static func identity(fromItem item: Any, authUser: Int) -> AccountIdentity? {
        guard let dict = item as? [String: Any] else { return nil }
        let name = text(dict["accountName"]) ?? text(dict["channelTitle"])
        let byline = text(dict["accountByline"]) ?? text(dict["channelHandle"]) ?? text(dict["email"])
        let photo = firstString(key: "url", in: dict["accountPhoto"]).flatMap(URL.init(string:))
        // `datasyncIdToken.datasyncIdToken` is the real shape; `datasyncId` is accepted too in case it changes back.
        let datasyncId = firstString(key: "datasyncIdToken", in: dict) ?? firstString(key: "datasyncId", in: dict)
        let signinURL = firstString(key: "signinUrl", in: dict)
        // An item with no selector and no name is a header or separator, not an account.
        guard name != nil || datasyncId != nil else { return nil }
        let resolvedAuthUser = queryValue("authuser", in: signinURL).flatMap(Int.init) ?? authUser
        return AccountIdentity(authUser: resolvedAuthUser, datasyncId: datasyncId,
                               listedName: name, listedByline: byline, photo: photo,
                               isSelected: dict["isSelected"] as? Bool ?? false)
    }

    /// A query parameter from a relative or absolute URL string.
    static func queryValue(_ name: String, in url: String?) -> String? {
        guard let url, let components = URLComponents(string: url) else { return nil }
        return components.queryItems?.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Reads a label from a `{simpleText}` or `{runs:[{text}]}` node.
    static func text(_ value: Any?) -> String? {
        guard let dict = value as? [String: Any] else { return nil }
        if let simple = dict["simpleText"] as? String { return simple.isEmpty ? nil : simple }
        if let runs = dict["runs"] as? [Any] {
            let joined = runs.compactMap { ($0 as? [String: Any])?["text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    /// Every object stored under `key`, in document order (depth-first).
    static func collect(key: String, in value: Any) -> [Any] {
        var out: [Any] = []
        func walk(_ v: Any) {
            if let dict = v as? [String: Any] {
                for (k, sub) in dict {
                    if k == key { out.append(sub) }
                    walk(sub)
                }
            } else if let array = v as? [Any] {
                for sub in array { walk(sub) }
            }
        }
        walk(value)
        return out
    }

    /// The first string value stored under `key` anywhere in `value` (depth-first).
    static func firstString(key: String, in value: Any?) -> String? {
        guard let value else { return nil }
        var found: String?
        func walk(_ v: Any) {
            if found != nil { return }
            if let dict = v as? [String: Any] {
                for (k, sub) in dict {
                    if k == key, let s = sub as? String, !s.isEmpty { found = s; return }
                    walk(sub)
                }
            } else if let array = v as? [Any] {
                for sub in array { walk(sub) }
            }
        }
        walk(value)
        return found
    }
}
