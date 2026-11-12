// openmusic-keychain-service: the XPC service that reads and writes OpenMusic's Keychain items, so sign-ins survive app
// updates and no other program can read them.
//
// Why a separate binary: macOS gives a Keychain item a partition list naming the code that created it. For an app
// without an Apple Team ID (Medley is self-signed) that is `cdhash:<hash of the binary>`, which changes with every
// build of Medley. This service is compiled once and its signed bundle reused byte for byte in every build
// (scripts/bundle.sh caches it by the hash of this file and Info.plist), so its cdhash, and the partition of every
// item it creates, stays the same.
//
// Who may use it: launchd starts a bundled XPC service only for the app that contains it, and every connection is
// checked against `identifier "dev.openmusic.OpenMusic" and certificate leaf = H"<this service's own certificate>"` with
// `NSXPCConnection.setCodeSigningRequirement`. The check runs on the audit token of each message, so it holds for
// the code actually sending it (a process that execs into Medley after connecting, or a copied bundle with its own
// main binary, is refused). The app checks this service the same way in return.
//
// What it serves: one account at a time, and only the accounts in `accounts` / `accountPrefixes` (the app's own list
// is `Keychain.accounts` in Sources/MedleyCore/Support/Keychain.swift). The debug Keychain probe's account is served
// only to debug builds, which `scripts/bundle.sh` marks with `MedleyKeychainProbe` in their (signed) Info.plist.
//
// DO NOT CHANGE THIS FILE (or Info.plist next to it) without reason: any change gives the service a new cdhash, and
// every user has to sign in again. When you do change it, also change `itemService`: the new binary can't open or
// overwrite items the old one created, so reusing the name would make every save fail.

import CryptoKit
import Foundation
import Security

/// Items live under this service name. Not "dev.openmusic" (the name iOS, tests and the probe use directly) or any of
/// the Medley-era names ("app.medley", "app.medley.helper", "app.medley.keychain", "app.medley.keychain.v2"): items
/// those created can't be opened by this binary, and a write to the same name would collide with them.
let itemService = "dev.openmusic.keychain"
let clientIdentifier = "dev.openmusic.OpenMusic"

/// The accounts the app saves (`Keychain.accounts`).
let accounts: Set<String> = [
    "spotify.token", "spotify.account",
    "ytm.credentials", "ytm.account", "ytm.transfer",
    "sync.credentials", "sync.credentials.installKey",
]
/// Families of accounts: the sync client's state blobs, `sync.credentials.state.<name>`.
let accountPrefixes = ["sync.credentials.state."]
/// The debug Keychain probe's throwaway account.
let probeAccount = "keychain-probe"

func isAllowed(_ account: String, probe: Bool) -> Bool {
    guard account.count <= 64, account.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
    else { return false }
    if account == probeAccount { return probe }
    return accounts.contains(account) || accountPrefixes.contains { account.hasPrefix($0) && account.count > $0.count }
}

/// The interface, as `MedleyCore.Keychain` declares it too. Statuses are OSStatus values.
@objc(MedleyKeychainServiceV2Protocol) protocol MedleyKeychainServiceProtocol {
    /// The account's data, or nil with the status: `errSecItemNotFound` when it has none.
    func get(_ account: String, reply: @escaping (Data?, Int32) -> Void)
    /// Stores `data` for the account (updating it in place when it exists), or deletes it when `data` is nil.
    func set(_ data: Data?, account: String, reply: @escaping (Int32) -> Void)
}

/// SHA-1 of the leaf certificate this service is signed with.
func ownLeafHash() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
          let leaf = certificates.first
    else { return nil }
    let der = SecCertificateCopyData(leaf) as Data
    return Insecure.SHA1.hash(data: der).map { String(format: "%02x", $0) }.joined()
}

func base(_ account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: itemService, kSecAttrAccount as String: account]
}

final class Store: NSObject, MedleyKeychainServiceProtocol {
    /// The client is a debug build (see `Listener`).
    let probe: Bool

    init(probe: Bool) {
        self.probe = probe
    }

    func get(_ account: String, reply: @escaping (Data?, Int32) -> Void) {
        guard isAllowed(account, probe: probe) else { return reply(nil, errSecMissingEntitlement) }
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        guard status == errSecSuccess else { return reply(nil, status) }
        guard let data = value as? Data else { return reply(nil, errSecDecode) }
        reply(data, errSecSuccess)
    }

    func set(_ data: Data?, account: String, reply: @escaping (Int32) -> Void) {
        guard isAllowed(account, probe: probe) else { return reply(errSecMissingEntitlement) }
        guard let data else {
            let status = SecItemDelete(base(account) as CFDictionary)
            return reply(status == errSecItemNotFound ? errSecSuccess : status)
        }
        // Update in place, so a failed write never leaves the account with nothing.
        let status = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return reply(status) }
        var add = base(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        reply(SecItemAdd(add as CFDictionary, nil))
    }
}

final class Listener: NSObject, NSXPCListenerDelegate {
    let requirement: String?

    init(requirement: String?) {
        self.requirement = requirement
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Unsigned (or ad-hoc) service: there is no certificate to pin, so serve no one.
        guard let requirement else { return false }
        // Every message must come from Medley signed with this certificate (checked per message, by audit token).
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: MedleyKeychainServiceProtocol.self)
        connection.exportedObject = Store(probe: isDebugBuild(connection.processIdentifier, requirement: requirement))
        connection.resume()
        return true
    }

    /// Whether the client is a debug build: Medley signed with this certificate whose Info.plist has
    /// `MedleyKeychainProbe`. Checked once, by pid; that is enough here because every message must still pass the
    /// per-message requirement above, so the worst a pid race can do is let one genuine Medley build use the probe's
    /// throwaway account.
    func isDebugBuild(_ pid: pid_t, requirement: String) -> Bool {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return false }
        var debug: SecRequirement?
        guard SecRequirementCreateWithString("\(requirement) and info [MedleyKeychainProbe] exists" as CFString, [], &debug) == errSecSuccess,
              let debug else { return false }
        return SecCodeCheckValidity(code, [], debug) == errSecSuccess
    }
}

// Never ask the user: an item this service can't open is reported as an error, not a prompt.
SecKeychainSetUserInteractionAllowed(false)
let delegate = Listener(requirement: ownLeafHash().map { "identifier \"\(clientIdentifier)\" and certificate leaf = H\"\($0)\"" })
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
