import Foundation
import OpenMusicCore

/// This device's registration with the signed-in account: its id, the account's library, the device's own secret
/// token and key pair, and the vault key once it has it. The token and keys are never logged or shown.
///
/// Credentials saved by builds from before accounts (paired by invite code) have no key pair, don't decode, and
/// are dropped: that device signs in once.
public struct SyncCredentials: Codable, Sendable, Hashable {
    public var deviceID: DeviceID
    public var libraryID: LibraryID
    /// 32 random bytes (base64url) the device made when it registered. Only its hash is on the server.
    public var token: String
    /// The deployment the token belongs to; a token from another deployment is ignored.
    public var deploymentURL: URL
    /// This device's X25519 key pair; other devices wrap the vault key to its public half.
    public var deviceKey: DeviceKeyPair
    /// The Clerk user this registration belongs to (their user id). Another user signing in starts over.
    public var userID: String?
    /// The account's vault key, when this device has it (made it, or a device holding it allowed this one). Once set
    /// it is pinned: it changes only by a rotation made with it (`KeyRotation`), or when this device claims a fresh
    /// key it made itself for an account left without one. Never from a grant.
    public var libraryKey: LibraryKey?
    /// A key this device is rotating to (`keys:rotate` sent, not yet confirmed). Saved first, so a rotation whose
    /// answer was lost isn't lost with it.
    public var nextLibraryKey: LibraryKey?
    /// The key revision of the newest device list applied when `nextLibraryKey` was saved. Only a newer list can
    /// prove it settled; nil (saved by an older build) means none can, and it is kept until it is adopted or replaced.
    public var nextLibraryKeyRevision: Int?
    /// A fresh key this device is claiming for an account without one (`keys:claim` sent, not yet confirmed). Saved
    /// before the claim is sent: if the server took it and the answer was lost (or the app quit), the account's only
    /// key isn't lost with it. The next device list adopts it when the server names it, and drops it otherwise.
    public var claimingLibraryKey: LibraryKey?
    /// The key revision of the newest device list applied when `claimingLibraryKey` was saved (see
    /// `nextLibraryKeyRevision`).
    public var claimingLibraryKeyRevision: Int?

    public init(deviceID: DeviceID, libraryID: LibraryID, token: String, deploymentURL: URL, deviceKey: DeviceKeyPair = .generate(),
                userID: String? = nil, libraryKey: LibraryKey? = nil) {
        self.deviceID = deviceID
        self.libraryID = libraryID
        self.token = token
        self.deploymentURL = deploymentURL
        self.deviceKey = deviceKey
        self.userID = userID
        self.libraryKey = libraryKey
    }

    public static func == (a: SyncCredentials, b: SyncCredentials) -> Bool {
        a.deviceID == b.deviceID && a.libraryID == b.libraryID && a.token == b.token && a.deploymentURL == b.deploymentURL
            && a.deviceKey.publicKey == b.deviceKey.publicKey && a.userID == b.userID && a.libraryKey == b.libraryKey
            && a.nextLibraryKey == b.nextLibraryKey && a.claimingLibraryKey == b.claimingLibraryKey
            && a.nextLibraryKeyRevision == b.nextLibraryKeyRevision && a.claimingLibraryKeyRevision == b.claimingLibraryKeyRevision
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(deviceID)
        hasher.combine(token)
    }
}

extension SyncCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "SyncCredentials(device: \(deviceID), library: \(libraryID.rawValue), token: <redacted>, key: \(libraryKey?.id ?? "none"))"
    }
    public var debugDescription: String { description }
}

/// A new device token: 32 random bytes, base64url.
func newDeviceToken() -> String {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).base64URLEncodedString()
}

/// Where the device token lives.
public protocol SyncCredentialStore: Sendable {
    func load() -> SyncCredentials?
    func save(_ credentials: SyncCredentials?)
    /// `save`, reporting whether it was stored. Used before telling the server about a key only this device has.
    func persist(_ credentials: SyncCredentials?) -> Bool
    /// Small private state blobs (what was last synced, per provider). Kept next to the credentials.
    func state(_ name: String) -> Data?
    func setState(_ name: String, _ data: Data?)
    /// `setState`, reporting whether it was stored. Used before telling the server about a key only this device has.
    func persistState(_ name: String, _ data: Data?) -> Bool
}

extension SyncCredentialStore {
    /// Saves and reads back.
    public func persist(_ credentials: SyncCredentials?) -> Bool {
        save(credentials)
        return load() == credentials
    }

    /// Saves and reads back.
    public func persistState(_ name: String, _ data: Data?) -> Bool {
        setState(name, data)
        return state(name) == data
    }
}

/// The app's store: the Keychain (`OpenMusicCore.Keychain`, service "dev.openmusic.keychain").
public struct KeychainCredentialStore: SyncCredentialStore {
    public var account: String

    public init(account: String = "sync.credentials") { self.account = account }

    public func load() -> SyncCredentials? { Keychain.codable(SyncCredentials.self, for: account) }
    public func save(_ credentials: SyncCredentials?) { Keychain.setCodable(credentials, for: account) }
    public func persist(_ credentials: SyncCredentials?) -> Bool { Keychain.setCodable(credentials, for: account) }

    public func state(_ name: String) -> Data? { Keychain.data(for: "\(account).state.\(name)") }
    public func setState(_ name: String, _ data: Data?) { Keychain.set(data, for: "\(account).state.\(name)") }
    public func persistState(_ name: String, _ data: Data?) -> Bool { Keychain.set(data, for: "\(account).state.\(name)") }
}

/// A JSON file readable only by the owner (0600). The probe uses it so two processes can be two devices.
public struct FileCredentialStore: SyncCredentialStore {
    public var url: URL

    public init(url: URL) { self.url = url }

    private struct File: Codable {
        var credentials: SyncCredentials?
        var state: [String: Data]?
    }

    private func read() -> File {
        guard let data = try? Data(contentsOf: url) else { return File() }
        if let file = try? JSONDecoder().decode(File.self, from: data) { return file }
        // A file from before accounts: its pairing doesn't decode, but its state blobs are kept.
        struct StateOnly: Codable { var state: [String: Data]? }
        return File(credentials: nil, state: (try? JSONDecoder().decode(StateOnly.self, from: data))?.state)
    }

    private func write(_ file: File) {
        guard let data = try? JSONEncoder().encode(file) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try? data.write(to: url)
    }

    public func load() -> SyncCredentials? { read().credentials }

    public func save(_ credentials: SyncCredentials?) {
        var file = read()
        file.credentials = credentials
        write(file)
    }

    public func state(_ name: String) -> Data? { read().state?[name] }

    public func setState(_ name: String, _ data: Data?) {
        var file = read()
        var state = file.state ?? [:]
        state[name] = data
        file.state = state
        write(file)
    }
}

/// For tests and previews.
public final class MemoryCredentialStore: SyncCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: SyncCredentials?
    private var states: [String: Data] = [:]

    public init(_ credentials: SyncCredentials? = nil) { self.credentials = credentials }
    public func state(_ name: String) -> Data? { lock.withLock { states[name] } }
    public func setState(_ name: String, _ data: Data?) { lock.withLock { states[name] = data } }

    public func load() -> SyncCredentials? { lock.withLock { credentials } }
    public func save(_ credentials: SyncCredentials?) { lock.withLock { self.credentials = credentials } }
}
