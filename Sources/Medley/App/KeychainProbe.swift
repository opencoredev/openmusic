import Foundation
import MedleyCore
import Security

/// `MEDLEY_KEYCHAIN_PROBE=<mode> MEDLEY_SELFTEST_OUT=<file>`, debug builds only (`CONFIG=debug scripts/bundle.sh`):
/// checks that a build can read what an earlier build saved, the way a sign-in survives an update, and what the
/// Keychain service refuses. Writes one line to the output file and quits before any provider or window starts.
///
/// - `write` saves a value through `MedleyCore.Keychain` under the account "keychain-probe"; `read` reads it back
///   with Keychain prompts off, so an item this build may not open reads as missing instead of asking; `acl` prints
///   the item's access list and partition; `delete` removes it.
/// - `refused`: asks the service itself to write and read an account outside its allow-list; both must come back
///   `errSecMissingEntitlement` (-34018).
/// - `unpinned-read`: reads "keychain-probe" without checking the service's signature. Run in a copied bundle whose
///   service was replaced, it shows the substitute would answer, while `read` (pinned) gets nothing from it.
///
/// Only the throwaway account (or names the service must refuse), never a sign-in: in a release build this does
/// nothing at all, so no process can launch Medley to read or overwrite credentials through it.
enum KeychainProbe {
    /// Changed between the two builds of the check, so their code (and cdhash) differ.
    static let buildMarker = "1"
    /// The only account the probe touches.
    static let key = Keychain.probeAccount

    static func runIfRequested() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard let mode = env["MEDLEY_KEYCHAIN_PROBE"], let out = env["MEDLEY_SELFTEST_OUT"] else { return }
        let line = run(mode)
        try? (line + "\n").write(to: URL(fileURLWithPath: out), atomically: true, encoding: .utf8)
        exit(0)
        #endif
    }

    #if DEBUG
    private static func run(_ mode: String) -> String {
        let path = "through the \(Keychain.backendName == "service" ? "Keychain service" : "process directly")"
        switch mode {
        case "write":
            let value = "written by build \(buildMarker)"
            var saved = "saved"
            do { try Keychain.store(Data(value.utf8), for: key) } catch { saved = "\(error)" }
            let back = Keychain.data(for: key).flatMap { String(data: $0, encoding: .utf8) }
            return "build \(buildMarker) write \(key) \(path): \(saved == "saved" && back == value ? "PASS" : "FAIL") (\(saved), reads back \(back ?? "nothing"))"
        case "read":
            // A prompt would fail instead of showing: the service never asks, and neither does this process.
            SecKeychainSetUserInteractionAllowed(false)
            let start = Date()
            let value = Keychain.data(for: key).flatMap { String(data: $0, encoding: .utf8) }
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            return "build \(buildMarker) read \(key) \(path) without a prompt: \(value?.hasPrefix("written by build") == true ? "PASS" : "FAIL") (value \(value ?? "none"), first read \(ms) ms)"
        case "acl":
            return aclDescription(service: Keychain.backendName == "service" ? "dev.openmusic.keychain" : Keychain.service)
        case "refused":
            let account = "medley.not-allowed"
            let wrote = Keychain.probeService(account: account, pinned: true, set: Data("x".utf8)).status
            let read = Keychain.probeService(account: account, pinned: true).status
            let ok = wrote == errSecMissingEntitlement && read == errSecMissingEntitlement
            return "build \(buildMarker) service refuses \(account): \(ok ? "PASS" : "FAIL") (write \(wrote), read \(read))"
        case "unpinned-read":
            SecKeychainSetUserInteractionAllowed(false)
            let (status, data) = Keychain.probeService(account: key, pinned: false)
            return "build \(buildMarker) unpinned read \(key): status \(status), value \(data.flatMap { String(data: $0, encoding: .utf8) } ?? "none")"
        case "delete":
            let deleted = Keychain.set(nil, for: key)
            return "build \(buildMarker) delete \(key) \(path): \(deleted && Keychain.data(for: key) == nil ? "PASS" : "FAIL")"
        default:
            return "unknown probe \(mode)"
        }
    }

    /// The item's access entries: authorizations, trusted apps and the partition list.
    private static func aclDescription(service: String) -> String {
        var ref: AnyObject?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnRef as String: true,
        ] as CFDictionary, &ref)
        guard status == errSecSuccess, let ref else { return "acl \(key): no item (\(status))" }
        let item = ref as! SecKeychainItem
        var access: SecAccess?
        guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess, let access else { return "acl \(key): no access" }
        var list: CFArray?
        SecAccessCopyACLList(access, &list)
        var lines: [String] = ["acl \(key):"]
        for acl in (list as? [SecACL]) ?? [] {
            var apps: CFArray?
            var desc: CFString?
            var prompt = SecKeychainPromptSelector()
            SecACLCopyContents(acl, &apps, &desc, &prompt)
            let auths = (SecACLCopyAuthorizations(acl) as? [String]) ?? []
            var appNames: [String] = []
            for app in (apps as? [SecTrustedApplication]) ?? [] {
                var data: CFData?
                SecTrustedApplicationCopyData(app, &data)
                appNames.append((data as Data?).flatMap { String(data: $0, encoding: .utf8) } ?? "?")
            }
            var text = (desc as String?) ?? ""
            // The partition list is a hex-encoded plist in the description.
            if auths.contains("ACLAuthorizationPartitionID"), let bytes = hexData(text),
               let plist = try? PropertyListSerialization.propertyList(from: bytes, format: nil) {
                text = "\(plist)".replacingOccurrences(of: "\n", with: " ")
            }
            lines.append("  \(auths.joined(separator: ",")) apps=\(apps == nil ? "any" : appNames.description) desc=\(text)")
        }
        return lines.joined(separator: "\n")
    }

    private static func hexData(_ hex: String) -> Data? {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
    #endif
}
