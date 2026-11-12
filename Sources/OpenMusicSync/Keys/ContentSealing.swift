import CryptoKit
import OpenMusicCore
import Foundation

/// One sealed field as it travels and is stored: `{ v: 1, keyId, sealed }`. `sealed` is base64 of the AES-GCM nonce,
/// ciphertext and tag (`AES.GCM.SealedBox.combined`); `keyId` names the vault key it was sealed under.
public struct SealedContent: Codable, Sendable, Hashable {
    public var v: Int
    public var keyId: String
    public var sealed: String

    public init(v: Int = 1, keyId: String, sealed: String) {
        self.v = v
        self.keyId = keyId
        self.sealed = sealed
    }
}

/// What a sealed field holds. Each kind has its own content key and its own place in the authenticated data.
public enum ContentKind: String, Sendable, CaseIterable {
    /// A device's current track, its index in the queue window and the window's length (`PlaybackContent`).
    case playback
    /// A device's queue window (`QueueWindow`).
    case queue
    /// A takeover's queue window (`QueueWindow`); the context is the target device.
    case command
    /// A failed command's message (`ResultContent`); the context is the command id.
    case result
    /// A setting's JSON text; the context is the setting key.
    case setting
}

/// End-to-end sealing of what someone listens to and searches for (docs/sync-design.md, "What the server can see").
///
/// - Content key: `HKDF-SHA256(ikm: vault key, salt: none, info: "medley.content.v1.<kind>", 32 bytes)`, so a key
///   never serves two kinds and none of them is the vault key the sign-ins are sealed with.
/// - Seal: AES-256-GCM with a fresh random 12-byte nonce per seal, `combined` (nonce ‖ ciphertext ‖ tag), base64.
/// - Authenticated data: `"medley.content.v1"` followed by five fields, each a 4-byte big-endian length and its UTF-8
///   bytes: the kind, the library id, the id of the device that wrote it, the vault key's fingerprint, and the
///   context (the setting key, a takeover's target device, a result's command id; empty for playback and queues). A
///   blob therefore opens only as the same kind, in the same account, from the same device, under the same key and
///   for the same setting, command or target: the server can't move it anywhere else.
///
/// The C# client (`windows/src/OpenMusic.Sync/Crypto/ContentSealing.cs`) does exactly the same; `ContentSealingTests`
/// writes the cross-language vectors it checks.
public enum ContentSealing {
    static let domain = "medley.content.v1"

    /// The content key for `kind`.
    static func contentKey(_ key: LibraryKey, kind: ContentKind) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key.key, info: Data("\(domain).\(kind.rawValue)".utf8), outputByteCount: 32)
    }

    static func associatedData(kind: ContentKind, library: LibraryID, writer: DeviceID, keyId: String, context: String) -> Data {
        var data = Data(domain.utf8)
        for field in [kind.rawValue, library.rawValue, writer.rawValue, keyId, context] {
            let bytes = Data(field.utf8)
            var length = UInt32(bytes.count).bigEndian
            data.append(Data(bytes: &length, count: 4))
            data.append(bytes)
        }
        return data
    }

    /// Seals `plaintext` written by `writer` in `library`.
    public static func seal(_ plaintext: Data, kind: ContentKind, library: LibraryID, writer: DeviceID, context: String = "",
                            key: LibraryKey) throws -> SealedContent {
        try seal(plaintext, kind: kind, library: library, writer: writer, context: context, key: key, nonce: AES.GCM.Nonce())
    }

    /// `seal` with a given nonce: only for the fixed test vectors. Never reuse a nonce under one key.
    static func seal(_ plaintext: Data, kind: ContentKind, library: LibraryID, writer: DeviceID, context: String,
                     key: LibraryKey, nonce: AES.GCM.Nonce) throws -> SealedContent {
        let aad = associatedData(kind: kind, library: library, writer: writer, keyId: key.id, context: context)
        let box = try AES.GCM.seal(plaintext, using: contentKey(key, kind: kind), nonce: nonce, authenticating: aad)
        guard let combined = box.combined else { throw SyncError.server("\(ProductInfo.name) couldn't seal that.") }
        return SealedContent(keyId: key.id, sealed: combined.base64EncodedString())
    }

    /// Opens a blob `writer` wrote in `library`. nil when it isn't sealed under `key` (a retired key, or one this
    /// device doesn't have yet): readers skip such blobs. Throws when it is under `key` but doesn't open (tampered, or
    /// moved from another device, kind, setting or command).
    public static func open(_ sealed: SealedContent, kind: ContentKind, library: LibraryID, writer: DeviceID, context: String = "",
                            key: LibraryKey) throws -> Data? {
        guard sealed.v == 1, sealed.keyId == key.id else { return nil }
        guard let data = Data(base64Encoded: sealed.sealed) else { throw ContentSealingError.malformed }
        let aad = associatedData(kind: kind, library: library, writer: writer, keyId: key.id, context: context)
        do {
            return try AES.GCM.open(try AES.GCM.SealedBox(combined: data), using: contentKey(key, kind: kind), authenticating: aad)
        } catch {
            throw ContentSealingError.doesNotOpen
        }
    }

    /// Seals a `Codable` value as JSON.
    static func seal<T: Encodable>(_ value: T, kind: ContentKind, library: LibraryID, writer: DeviceID, context: String = "",
                                   key: LibraryKey) throws -> SealedContent {
        try seal(try JSONEncoder().encode(value), kind: kind, library: library, writer: writer, context: context, key: key)
    }

    /// Opens and decodes a JSON value; nil when the blob isn't under `key`.
    static func open<T: Decodable>(_ sealed: SealedContent, as type: T.Type, kind: ContentKind, library: LibraryID, writer: DeviceID,
                                   context: String = "", key: LibraryKey) throws -> T? {
        guard let data = try open(sealed, kind: kind, library: library, writer: writer, context: context, key: key) else { return nil }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw ContentSealingError.malformed }
    }
}

public enum ContentSealingError: Error, Equatable {
    /// Under the right key, but it doesn't open here: changed on the way, or not written where it claims to be.
    case doesNotOpen
    /// Not base64, or not the JSON its kind holds.
    case malformed
}

/// What the `playback` kind holds: the device's current track and where it is in the published window.
public struct PlaybackContent: Codable, Sendable, Hashable {
    public var track: Track
    public var index: Int
    public var queueLength: Int
}

/// What the `result` kind holds: a failed command's message, which may name a song.
struct ResultContent: Codable, Sendable, Hashable {
    var message: String
}
