import Foundation
import OpenMusicCore

// Account types shared by every sign-in path (browser login on macOS, Google sign-in in a web view on both platforms).

/// The accounts a browser profile can sign in with, and whether the list is authoritative (from the account
/// switcher) or a best-effort fallback. A single fallback account is not auto-committed, since the fallback can't
/// prove the profile has no other channels.
public struct BrowserAccountList: Sendable {
    public let accounts: [BrowserAccount]
    public let authoritative: Bool
    public init(accounts: [BrowserAccount], authoritative: Bool) {
        self.accounts = accounts
        self.authoritative = authoritative
    }
}

/// One account signed in to a browser profile that OpenMusic can use: a Google account or a channel / brand account
/// under it. `info` is the name/photo confirmed by a real request; `identity` is how requests select it.
public struct BrowserAccount: Sendable, Hashable, Identifiable {
    public let identity: AccountIdentity
    public let info: AccountInfo
    public var authUser: Int { identity.authUser }
    public var id: String { identity.selectorKey }
    public init(identity: AccountIdentity, info: AccountInfo) {
        self.identity = identity
        self.info = info
    }
}

public enum BrowserLoginError: LocalizedError, Equatable {
    /// The person chose Deny (or Cancel) when macOS asked for the browser's keychain password.
    case keychainDenied(browser: String)
    case keychainMissing(browser: String)
    /// The cookie database couldn't be read or decrypted.
    case unreadable(browser: String)
    /// The profile no longer has the YouTube session cookies.
    case notSignedIn(browser: String)

    public var errorDescription: String? {
        switch self {
        case .keychainDenied(let b):
            "\(ProductInfo.name) needs permission to read \(b)'s login. Try again and choose Allow when macOS asks."
        case .keychainMissing(let b):
            "Unable to find \(b)'s login key in your Keychain. Open \(b) once, then try again."
        case .unreadable(let b):
            "Unable to read \(b)'s YouTube login. Sign in with Google in \(ProductInfo.name) instead."
        case .notSignedIn(let b):
            "\(b) isn't signed in to YouTube anymore. Open YouTube Music in \(b), sign in, then try again."
        }
    }
}
