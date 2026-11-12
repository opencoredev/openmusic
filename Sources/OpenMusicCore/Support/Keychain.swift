import CryptoKit
import Foundation
import Security

/// Small generic-password Keychain wrapper. Each provider stores its own keys under service "dev.openmusic"
/// ("dev.openmusic.keychain" when saved through the Mac app's Keychain service).
///
/// In the Mac app bundle, items go through `Contents/XPCServices/dev.openmusic.keychain-service.xpc`, an XPC service
/// that is the same binary in every build and serves only OpenMusic (see `Resources/KeychainService/main.swift`).
/// macOS limits an item to the code that created it (its partition list); for an app without an Apple Team ID that
/// is the binary's cdhash, which changes with every build, so writing items straight from OpenMusic meant every update
/// signed the listener out. Elsewhere (iOS, tests, `openmusic-probe`, `swift run`) items are read and written directly.
public enum Keychain {
    public static let service = "dev.openmusic"

    /// Every account the app saves. The Mac app's Keychain service serves only these (its own copy of the list is in
    /// `Resources/KeychainService/main.swift`, and changing it signs everyone out once), so a new account needs both.
    public static let accounts: Set<String> = [
        "spotify.token", "spotify.account",
        "ytm.credentials", "ytm.account", "ytm.transfer",
        "sync.credentials", "sync.credentials.installKey",
    ]
    /// Families of accounts: `KeychainCredentialStore`'s state blobs (`sync.credentials.state.<name>`).
    public static let accountPrefixes = ["sync.credentials.state."]
    /// The debug Keychain probe's throwaway account. Served only to debug builds.
    public static let probeAccount = "keychain-probe"

    /// Whether the Keychain service would serve `key` to this build.
    public static func isServed(_ key: String) -> Bool {
        #if DEBUG
        if key == probeAccount { return true }
        #endif
        return accounts.contains(key) || accountPrefixes.contains { key.hasPrefix($0) && key.count > $0.count }
    }

    /// Why the Keychain didn't answer: an `OSStatus`, or `errSecNotAvailable` when the service couldn't be reached.
    public struct Failure: LocalizedError, Equatable, CustomStringConvertible {
        public let status: OSStatus
        public init(status: OSStatus) { self.status = status }
        public var description: String { "Keychain error \(status)" }
        public var errorDescription: String? { "The Keychain didn't save the change (error \(status))." }
    }

    /// Stores `data` for `key` (deletes it when nil). Throws when the Keychain didn't take it; the value is then not
    /// kept anywhere, so a later read returns what is really saved.
    public static func store(_ data: Data?, for key: String) throws {
        try backend.set(data, for: key)
    }

    /// `store` for a Codable value (deletes when nil).
    public static func storeCodable<T: Encodable>(_ value: T?, for key: String) throws {
        guard let value else { return try store(nil, for: key) }
        let data: Data
        do { data = try JSONEncoder().encode(value) } catch { throw Failure(status: errSecParam) }
        try store(data, for: key)
    }

    /// `store`, reporting failure as false for callers that can go on without persistence.
    @discardableResult
    public static func set(_ data: Data?, for key: String) -> Bool {
        do {
            try store(data, for: key)
            return true
        } catch {
            return false
        }
    }

    public static func data(for key: String) -> Data? {
        backend.data(for: key)
    }

    @discardableResult
    public static func setCodable<T: Encodable>(_ value: T?, for key: String) -> Bool {
        do {
            try storeCodable(value, for: key)
            return true
        } catch {
            return false
        }
    }

    public static func codable<T: Decodable>(_ type: T.Type, for key: String) -> T? {
        data(for: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    /// Where items go: "service" (the Mac app's Keychain service), "direct", or (debug self-test runs) "file <dir>".
    public static var backendName: String { backend.name }

    #if DEBUG
    /// Debug builds only: from now on every account lives in a 0600 file under `directory` (made 0700) and the real
    /// Keychain is never read or written by this process. For live tests on a shared Mac, so a test run can't restore,
    /// overwrite, delete or sync the Mac's real sign-ins. Call before anything reads the Keychain; it can't be undone.
    public static func isolate(in directory: URL) {
        isolated.install(FileKeychain(directory: directory))
    }

    /// True after `isolate(in:)`: a test run that must also leave other shared state (e.g. the sign-in web view's
    /// cookies) alone.
    public static var isIsolated: Bool { isolated.backend != nil }

    private static let isolated = IsolatedBackend()

    private static var backend: any KeychainBackend { isolated.backend ?? defaultBackend }
    #else
    private static var backend: any KeychainBackend { defaultBackend }
    #endif

    #if DEBUG && os(macOS)
    /// The debug Keychain probe only: asks the bundled service on a new connection, skipping the in-memory copy and
    /// this build's allow-list, so the probe can show what the service itself does. Only the probe's own account or
    /// an account the service must refuse; never a real sign-in. `pinned` false skips checking the service's
    /// signature (to show a substituted service would answer). `set` nil reads; otherwise writes `set`.
    public static func probeService(account: String, pinned: Bool, set: Data? = nil) -> (status: OSStatus, data: Data?) {
        guard account == probeAccount || !isServed(account) else { return (errSecParam, nil) }
        let requirement = pinned ? KeychainServiceTransport.serviceRequirement() : "always"
        let transport = KeychainServiceTransport(requirement: requirement)
        if let set { return (transport.set(set, for: account), nil) }
        switch transport.get(account) {
        case .success(let data): return (data == nil ? errSecItemNotFound : errSecSuccess, data)
        case .failure(let failure): return (failure.status, nil)
        }
    }
    #endif

    private static let defaultBackend: any KeychainBackend = {
        #if os(macOS)
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
        let serviceBundle = contents.appendingPathComponent("XPCServices/\(KeychainServiceTransport.serviceName).xpc")
        if FileManager.default.fileExists(atPath: serviceBundle.path) {
            return CachedKeychain(transport: KeychainServiceTransport(requirement: KeychainServiceTransport.serviceRequirement()))
        }
        #endif
        return DirectKeychain()
    }()
}

protocol KeychainBackend: Sendable {
    var name: String { get }
    func data(for key: String) -> Data?
    func set(_ data: Data?, for key: String) throws
}

/// The process's own Keychain access (iOS, tests, command-line tools, unsigned builds).
struct DirectKeychain: KeychainBackend {
    var name: String { "direct" }

    private func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Keychain.service, kSecAttrAccount as String: key]
    }

    func set(_ data: Data?, for key: String) throws {
        guard let data else {
            let status = SecItemDelete(base(key) as CFDictionary)
            if status != errSecSuccess, status != errSecItemNotFound { throw Keychain.Failure(status: status) }
            return
        }
        // Update in place, so a failed write never leaves the key with nothing saved.
        let status = SecItemUpdate(base(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Keychain.Failure(status: status) }
        var add = base(key)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(add as CFDictionary, nil)
        if added != errSecSuccess { throw Keychain.Failure(status: added) }
    }

    func data(for key: String) -> Data? {
        var query = base(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
}

#if DEBUG
/// The backend `Keychain.isolate(in:)` installed, if any.
final class IsolatedBackend: @unchecked Sendable {
    private let lock = NSLock()
    private var installed: (any KeychainBackend)?

    var backend: (any KeychainBackend)? {
        lock.lock()
        defer { lock.unlock() }
        return installed
    }

    func install(_ backend: any KeychainBackend) {
        lock.lock()
        defer { lock.unlock() }
        installed = backend
    }
}

/// Debug self-test runs: one 0600 file per account in a 0700 folder. Never the Keychain.
struct FileKeychain: KeychainBackend {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    var name: String { "file \(directory.path)" }

    private func url(_ key: String) -> URL {
        // Account names are fixed strings like "spotify.token"; anything else is escaped so it stays in the folder.
        let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "._-"))) ?? "invalid"
        return directory.appendingPathComponent(safe.hasPrefix(".") ? "%2E" + safe.dropFirst() : safe)
    }

    func data(for key: String) -> Data? { try? Data(contentsOf: url(key)) }

    func set(_ data: Data?, for key: String) throws {
        let file = url(key)
        guard let data else {
            do { try FileManager.default.removeItem(at: file) } catch CocoaError.fileNoSuchFile {} catch { throw Keychain.Failure(status: errSecIO) }
            return
        }
        do {
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            throw Keychain.Failure(status: errSecIO)
        }
    }
}
#endif

/// A store in another process (the Keychain service), one account at a time.
protocol KeychainTransport: Sendable {
    /// The account's data, nil when it has none, or the status that stopped the read.
    func get(_ key: String) -> Result<Data?, Keychain.Failure>
    func set(_ data: Data?, for key: String) -> OSStatus
}

/// A store reached through another process (the Keychain service). Each account is read once and kept in memory
/// (absence too); a failed read isn't kept, so the next read asks again. A write updates memory only after the store
/// confirmed it. Accounts outside `Keychain.accounts` are refused here as the service would refuse them.
final class CachedKeychain: KeychainBackend, @unchecked Sendable {
    private let transport: any KeychainTransport
    private let lock = NSLock()
    private var cache: [String: Data?] = [:]

    init(transport: any KeychainTransport) {
        self.transport = transport
    }

    var name: String { "service" }

    func data(for key: String) -> Data? {
        guard Keychain.isServed(key) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        guard case .success(let data) = transport.get(key) else { return nil }
        cache[key] = .some(data)
        return data
    }

    func set(_ data: Data?, for key: String) throws {
        guard Keychain.isServed(key) else { throw Keychain.Failure(status: errSecMissingEntitlement) }
        lock.lock()
        defer { lock.unlock() }
        let status = transport.set(data, for: key)
        guard status == errSecSuccess else { throw Keychain.Failure(status: status) }
        cache[key] = .some(data)
    }
}

#if os(macOS)
/// The interface of `Resources/KeychainService/main.swift`; keep the two in step.
@objc(MedleyKeychainServiceV2Protocol) protocol OpenMusicKeychainServiceProtocol {
    func get(_ account: String, reply: @escaping (Data?, Int32) -> Void)
    func set(_ data: Data?, account: String, reply: @escaping (Int32) -> Void)
}

/// Talks to the bundled XPC service. Calls block (at most `timeout`) because the Keychain API is synchronous.
///
/// The service is trusted only if it is signed with this app's own certificate under the service's identifier
/// (`setCodeSigningRequirement`, checked on every reply), so a bundle whose service was swapped for other code gets
/// no answers instead of handing that code the sign-ins. An app without a certificate (ad-hoc) uses no service.
final class KeychainServiceTransport: KeychainTransport, @unchecked Sendable {
    static let serviceName = "dev.openmusic.keychain-service"
    static let timeout: TimeInterval = 15

    /// `identifier "dev.openmusic.keychain-service" and certificate leaf = H"<this app's leaf>"`, nil when this
    /// process has no certificate.
    static func serviceRequirement() -> String? {
        ownLeafHash().map { "identifier \"\(serviceName)\" and certificate leaf = H\"\($0)\"" }
    }

    /// SHA-1 of the leaf certificate this process is signed with.
    static func ownLeafHash() -> String? {
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

    private let requirement: String?
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    init(requirement: String?) {
        self.requirement = requirement
    }

    private final class Reply<T>: @unchecked Sendable {
        var value: T?
        let done = DispatchSemaphore(value: 0)
    }

    private func proxy(onError: @escaping @Sendable (any Error) -> Void) -> (any OpenMusicKeychainServiceProtocol)? {
        guard let requirement else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            let new = NSXPCConnection(serviceName: Self.serviceName)
            new.remoteObjectInterface = NSXPCInterface(with: OpenMusicKeychainServiceProtocol.self)
            // Only the real service may answer; anything else invalidates the connection.
            new.setCodeSigningRequirement(requirement)
            // Refused or gone: connect again next time.
            new.invalidationHandler = { [weak self] in self?.dropConnection() }
            new.resume()
            connection = new
        }
        return connection?.remoteObjectProxyWithErrorHandler(onError) as? any OpenMusicKeychainServiceProtocol
    }

    private func dropConnection() {
        lock.lock()
        connection = nil
        lock.unlock()
    }

    private func call<T: Sendable>(failure: T, _ body: (any OpenMusicKeychainServiceProtocol, Reply<T>) -> Void) -> T {
        let reply = Reply<T>()
        guard let proxy = proxy(onError: { _ in
            reply.value = failure
            reply.done.signal()
        }) else { return failure }
        body(proxy, reply)
        guard reply.done.wait(timeout: .now() + Self.timeout) == .success else { return failure }
        return reply.value ?? failure
    }

    func get(_ key: String) -> Result<Data?, Keychain.Failure> {
        let (data, status) = call(failure: (Data?.none, Int32(errSecNotAvailable))) { proxy, reply in
            proxy.get(key) { data, status in
                reply.value = (data, status)
                reply.done.signal()
            }
        }
        if status == errSecItemNotFound { return .success(nil) }
        guard status == errSecSuccess, let data else {
            return .failure(Keychain.Failure(status: status == errSecSuccess ? errSecDecode : status))
        }
        return .success(data)
    }

    func set(_ data: Data?, for key: String) -> OSStatus {
        call(failure: Int32(errSecNotAvailable)) { proxy, reply in
            proxy.set(data, account: key) { status in
                reply.value = status
                reply.done.signal()
            }
        }
    }
}
#endif
