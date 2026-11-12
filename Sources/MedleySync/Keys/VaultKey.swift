import CryptoKit
import Foundation
import MedleyCore

// MARK: - Vault key

/// The account's vault key: 32 random bytes, made by the first device. It lives in each device's Keychain and
/// travels only wrapped to another device's key (`KeyGrant`); the server sees only `id`, its fingerprint.
public struct LibraryKey: Sendable, Hashable, Codable {
    public let key: SymmetricKey
    /// First 16 bytes of SHA-256("medley.library-key.v1" + key), as 32 hex characters.
    public let id: String

    public init(_ key: SymmetricKey) {
        self.key = key
        var hasher = SHA256()
        hasher.update(data: Data("medley.library-key.v1".utf8))
        key.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        id = hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public static func generate() -> LibraryKey { LibraryKey(SymmetricKey(size: .bits256)) }

    /// base64url of the 32 key bytes, as the credentials store it.
    public var encoded: String { key.withUnsafeBytes { Data($0) }.base64URLEncodedString() }

    public init?(encoded text: String) {
        guard let data = Data(base64URLEncoded: text), data.count == 32 else { return nil }
        self.init(SymmetricKey(data: data))
    }

    public static func == (a: LibraryKey, b: LibraryKey) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let key = LibraryKey(encoded: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad library key"))
        }
        self = key
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(encoded)
    }
}

extension LibraryKey: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "LibraryKey(id: \(id), key: <redacted>)" }
    public var debugDescription: String { description }
}

/// AES-GCM sealing of a provider's sign-in under the library key. The provider and the vault revision the write
/// gets are bound in as authenticated data (`medley.vault.v2:<provider>:<revision>`), so a blob can't be replayed
/// as another provider's, nor at another revision (for example on top of a "sign out everywhere" tombstone).
public enum SignInSealing {
    static func associatedData(_ provider: ProviderID, revision: Int) -> Data {
        Data("medley.vault.v2:\(provider.rawValue):\(revision)".utf8)
    }

    /// Base64 of nonce + ciphertext + tag (`AES.GCM.SealedBox.combined`). `revision` is the revision the vault row
    /// will have once this is written: the base revision plus one.
    public static func seal(_ plaintext: Data, provider: ProviderID, revision: Int, key: LibraryKey) throws -> String {
        let box = try AES.GCM.seal(plaintext, using: key.key, authenticating: associatedData(provider, revision: revision))
        guard let combined = box.combined else { throw SyncError.signInTransferFailed("could not seal") }
        return combined.base64EncodedString()
    }

    /// The format before revisions: `medley.vault.v1:<provider>`. Read only for revision-0 entries, to migrate them.
    static func legacyAssociatedData(_ provider: ProviderID) -> Data {
        Data("medley.vault.v1:\(provider.rawValue)".utf8)
    }

    /// Opens a legacy (v1) blob. Callers use it only for an entry at revision 0, which no current writer produces.
    public static func openLegacy(_ sealed: String, provider: ProviderID, key: LibraryKey) throws -> Data {
        guard let data = Data(base64Encoded: sealed) else { throw SyncError.signInTransferFailed("the sealed sign-in is malformed") }
        do {
            return try AES.GCM.open(try AES.GCM.SealedBox(combined: data), using: key.key, authenticating: legacyAssociatedData(provider))
        } catch {
            throw SyncError.signInTransferFailed("the library key doesn't open this sign-in")
        }
    }

    /// Seals in the legacy (v1) format. Only for tests of the migration.
    static func sealLegacy(_ plaintext: Data, provider: ProviderID, key: LibraryKey) throws -> String {
        let box = try AES.GCM.seal(plaintext, using: key.key, authenticating: legacyAssociatedData(provider))
        guard let combined = box.combined else { throw SyncError.signInTransferFailed("could not seal") }
        return combined.base64EncodedString()
    }

    /// Opens a blob read from the vault row at `revision`. Fails for a blob sealed for any other revision.
    public static func open(_ sealed: String, provider: ProviderID, revision: Int, key: LibraryKey) throws -> Data {
        guard let data = Data(base64Encoded: sealed) else { throw SyncError.signInTransferFailed("the sealed sign-in is malformed") }
        do {
            return try AES.GCM.open(try AES.GCM.SealedBox(combined: data), using: key.key,
                                    authenticating: associatedData(provider, revision: revision))
        } catch {
            throw SyncError.signInTransferFailed("the library key doesn't open this sign-in")
        }
    }
}

// MARK: - Device key pair and key grants

/// This device's X25519 key pair. Made when the device signs in and kept with its credentials; the server stores
/// only the public half. Another device wraps the vault key to the public key (`KeyGrant`), so the vault key
/// reaches this device without anyone else, the server included, being able to read it.
public struct DeviceKeyPair: Sendable, Codable {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init(_ privateKey: Curve25519.KeyAgreement.PrivateKey = .init()) { self.privateKey = privateKey }

    public static func generate() -> DeviceKeyPair { DeviceKeyPair() }

    /// base64 of the 32-byte public key, as the server stores it.
    public var publicKey: String { privateKey.publicKey.rawRepresentation.base64EncodedString() }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let data = Data(base64Encoded: text), let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad device key"))
        }
        privateKey = key
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(privateKey.rawRepresentation.base64EncodedString())
    }
}

extension DeviceKeyPair: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "DeviceKeyPair(public: \(publicKey), private: <redacted>)" }
    public var debugDescription: String { description }
}

/// The verification exchange that moves the vault key to a new device (docs/accounts-design.md, "Approving a
/// device"). The sync server relays it and is not trusted: nothing here relies on what it says.
///
/// 1. The asking device B makes a secret 32-byte nonce `nB` and publishes `commitment = SHA-256(commit domain ‖
///    pkB ‖ nB)`.
/// 2. A holder A, having seen the commitment, answers with its device public key `pkA` and a fresh nonce `nA`.
/// 3. B, having seen the answer, reveals `nB`. A checks it against the commitment.
/// 4. Both show `code(transcript)`: six digits from a hash of the account, both device ids, both public keys and
///    both nonces. The listener compares them, taps Allow on A and confirms on B.
/// 5. A seals the vault key under `HKDF(X25519(skA, pkB), salt: transcript digest)`. Only A and B can derive that
///    key, so B knows the grant came from the holder in the transcript, and the server can't open it.
///
/// Whoever sits between the devices must fix its own commitment before it sees A's nonce and its own nonce before it
/// sees B's, so each attempt to make two different exchanges show the same code succeeds with probability 10⁻⁶,
/// with no way to search offline. Devices rate limit attempts and show repeated failures.
public enum KeyExchange {
    static let commitDomain = Data("medley.key-exchange.v1.commit".utf8)
    static let transcriptDomain = Data("medley.key-exchange.v1.transcript".utf8)
    static let codeDomain = Data("medley.key-exchange.v1.code".utf8)

    /// 32 random bytes.
    public static func nonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    static let answerNonceDomain = Data("medley.key-exchange.v2.answer-nonce".utf8)

    /// A holder's nonce for answering one request: HMAC-SHA256 under a key derived from the holder's private key, over
    /// everything the code covers that is fixed before the holder answers: the library, the asking device's id and
    /// public key, its commitment (which fixes its nonce), and the holder's own id and public key (each
    /// length-prefixed). Unpredictable to anyone without that private key, and always the same for the same request,
    /// so a server that shows a holder one request again (after a `conflict`, or once the holder's record of it is
    /// gone) never gets a second nonce for it. A request that differs in any field, such as the same commitment shown
    /// as another device, gets a nonce of its own, so knowing one answer tells the server nothing about the code of
    /// another: each one is a fresh online try, counted against the holder's hourly limit. The key and commitment
    /// count by their bytes, not their base64 text, so a re-encoding is the same request. nil for a malformed key or
    /// commitment, which a holder doesn't answer.
    public static func answerNonce(holder: DeviceKeyPair, holderID: DeviceID, libraryID: LibraryID, requester: DeviceID,
                                   requesterKey: String, commitment: String) -> Data? {
        guard let requesterBytes = Data(base64Encoded: requesterKey), requesterBytes.count == 32,
              let commitmentBytes = Data(base64Encoded: commitment), commitmentBytes.count == 32 else { return nil }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: holder.privateKey.rawRepresentation),
                                         info: answerNonceDomain, outputByteCount: 32)
        var mac = HMAC<SHA256>(key: key)
        let fields = [Data(libraryID.rawValue.utf8), Data(requester.rawValue.utf8), requesterBytes, commitmentBytes,
                      Data(holderID.rawValue.utf8), holder.privateKey.publicKey.rawRepresentation]
        for field in fields {
            var length = UInt32(field.count).bigEndian
            mac.update(data: Data(bytes: &length, count: 4))
            mac.update(data: field)
        }
        return Data(mac.finalize())
    }

    /// base64 of SHA-256(commit domain ‖ public key ‖ nonce). nil for a malformed key or nonce.
    public static func commitment(publicKey: String, nonce: Data) -> String? {
        guard let key = Data(base64Encoded: publicKey), key.count == 32, nonce.count == 32 else { return nil }
        return Data(SHA256.hash(data: commitDomain + key + nonce)).base64EncodedString()
    }

    /// Everything one run of the exchange agreed on, as each device recorded it itself.
    public struct Transcript: Sendable, Hashable {
        public var libraryID: LibraryID
        public var requester: DeviceID
        /// The asking device's public key (base64).
        public var requesterKey: String
        public var requesterNonce: Data
        public var holder: DeviceID
        /// The holder's device public key (base64).
        public var holderKey: String
        public var holderNonce: Data

        public init(libraryID: LibraryID, requester: DeviceID, requesterKey: String, requesterNonce: Data,
                    holder: DeviceID, holderKey: String, holderNonce: Data) {
            self.libraryID = libraryID
            self.requester = requester
            self.requesterKey = requesterKey
            self.requesterNonce = requesterNonce
            self.holder = holder
            self.holderKey = holderKey
            self.holderNonce = holderNonce
        }

        /// SHA-256 over every field, each length-prefixed, so no two transcripts hash alike by shifting bytes.
        public var digest: Data {
            var hasher = SHA256()
            hasher.update(data: transcriptDomain)
            for field in [Data(libraryID.rawValue.utf8), Data(requester.rawValue.utf8), Data(base64Encoded: requesterKey) ?? Data(),
                          requesterNonce, Data(holder.rawValue.utf8), Data(base64Encoded: holderKey) ?? Data(), holderNonce] {
                var length = UInt32(field.count).bigEndian
                hasher.update(data: Data(bytes: &length, count: 4))
                hasher.update(data: field)
            }
            return Data(hasher.finalize())
        }

        /// The six digits both devices show, as "482 913".
        public var code: String {
            let hash = SHA256.hash(data: codeDomain + digest)
            let number = hash.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } % 1_000_000
            let digits = String(format: "%06llu", number)
            return "\(digits.prefix(3)) \(digits.suffix(3))"
        }
    }

    static func grantKey(own: DeviceKeyPair, peer: String, transcript: Transcript, keyId: String) throws -> SymmetricKey {
        guard let peerData = Data(base64Encoded: peer), peerData.count == 32,
              let peerKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerData) else {
            throw SyncError.keyGrantFailed("that device's key is malformed")
        }
        let shared = try own.privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        let info = Data("medley.key-grant.v2|\(transcript.libraryID.rawValue)|\(transcript.requester.rawValue)|\(keyId)".utf8)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript.digest, sharedInfo: info, outputByteCount: 32)
    }

    /// The holder seals `key` for the asking device in `transcript`. `holder` must be the key pair the transcript names.
    public static func wrap(_ key: LibraryKey, transcript: Transcript, holder: DeviceKeyPair) throws -> String {
        guard holder.publicKey == transcript.holderKey else { throw SyncError.keyGrantFailed("the exchange names another device") }
        let wrapKey = try grantKey(own: holder, peer: transcript.requesterKey, transcript: transcript, keyId: key.id)
        guard let combined = try AES.GCM.seal(key.key.withUnsafeBytes { Data($0) }, using: wrapKey).combined else {
            throw SyncError.keyGrantFailed("could not seal")
        }
        return combined.base64EncodedString()
    }

    /// The asking device opens a grant made for `transcript` (as it recorded it) and checks the key inside has
    /// fingerprint `keyId`. Only the holder the transcript names could have made a grant that opens.
    public static func unwrap(_ wrapped: String, transcript: Transcript, requester: DeviceKeyPair, keyId: String) throws -> LibraryKey {
        guard requester.publicKey == transcript.requesterKey else { throw SyncError.keyGrantFailed("the exchange names another device") }
        guard let data = Data(base64Encoded: wrapped) else { throw SyncError.keyGrantFailed("the grant is malformed") }
        let plaintext: Data
        do {
            let wrapKey = try grantKey(own: requester, peer: transcript.holderKey, transcript: transcript, keyId: keyId)
            plaintext = try AES.GCM.open(try AES.GCM.SealedBox(combined: data), using: wrapKey)
        } catch {
            throw SyncError.keyGrantFailed("it doesn't open on this device")
        }
        guard plaintext.count == 32 else { throw SyncError.keyGrantFailed("the grant holds no key") }
        let key = LibraryKey(SymmetricKey(data: plaintext))
        guard key.id == keyId else { throw SyncError.keyGrantFailed("the key isn't your account's") }
        return key
    }
}

/// Moving a rotated vault key to the other holders (`keys:rotate`). The new key is sealed to each holder's device
/// key with an ephemeral X25519 key, and the old vault key is mixed into the wrapping key:
///
/// - `wrapKey = HKDF-SHA256(X25519(e, holder) ‖ old key, salt: e.public ‖ holder, info: "medley.key-rotation.v1|<library>|<device>|<old id>|<new id>")`
/// - `wrapped = base64(e.public ‖ AES.GCM.seal(new key, wrapKey).combined)`
///
/// Only that holder can open it (its private key), and only a device holding the old key could have made it, so
/// the server (which has neither) can't hand a holder a key of its own.
public enum KeyRotation {
    static func wrapKey(shared: SharedSecret, old: LibraryKey, ephemeral: Data, recipient: Data, info: Data) -> SymmetricKey {
        var material = shared.withUnsafeBytes { Data($0) }
        material.append(old.key.withUnsafeBytes { Data($0) })
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material), salt: ephemeral + recipient, info: info, outputByteCount: 32)
    }

    static func info(libraryID: LibraryID, deviceID: DeviceID, old: String, new: String) -> Data {
        Data("medley.key-rotation.v1|\(libraryID.rawValue)|\(deviceID.rawValue)|\(old)|\(new)".utf8)
    }

    public static func wrap(_ new: LibraryKey, replacing old: LibraryKey, to recipient: String, libraryID: LibraryID, deviceID: DeviceID) throws -> String {
        guard let recipientData = Data(base64Encoded: recipient), recipientData.count == 32,
              let recipientKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientData) else {
            throw SyncError.keyGrantFailed("that device's key is malformed")
        }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipientKey)
        let ephemeralPublic = ephemeral.publicKey.rawRepresentation
        let key = wrapKey(shared: shared, old: old, ephemeral: ephemeralPublic, recipient: recipientData,
                          info: info(libraryID: libraryID, deviceID: deviceID, old: old.id, new: new.id))
        guard let combined = try AES.GCM.seal(new.key.withUnsafeBytes { Data($0) }, using: key).combined else {
            throw SyncError.keyGrantFailed("could not seal")
        }
        return (ephemeralPublic + combined).base64EncodedString()
    }

    /// Opens a rotation wrapped to `pair`, made with `old`, and checks the new key has fingerprint `keyId`.
    public static func unwrap(_ wrapped: String, with pair: DeviceKeyPair, replacing old: LibraryKey, libraryID: LibraryID,
                              deviceID: DeviceID, keyId: String) throws -> LibraryKey {
        guard let data = Data(base64Encoded: wrapped), data.count > 32 else { throw SyncError.keyGrantFailed("the new key is malformed") }
        let ephemeralPublic = Data(data.prefix(32))
        let plaintext: Data
        do {
            let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralPublic)
            let shared = try pair.privateKey.sharedSecretFromKeyAgreement(with: ephemeral)
            let key = wrapKey(shared: shared, old: old, ephemeral: ephemeralPublic, recipient: pair.privateKey.publicKey.rawRepresentation,
                              info: info(libraryID: libraryID, deviceID: deviceID, old: old.id, new: keyId))
            plaintext = try AES.GCM.open(try AES.GCM.SealedBox(combined: Data(data.dropFirst(32))), using: key)
        } catch {
            throw SyncError.keyGrantFailed("the new key wasn't made with this device's key")
        }
        guard plaintext.count == 32 else { throw SyncError.keyGrantFailed("the new key is malformed") }
        let key = LibraryKey(SymmetricKey(data: plaintext))
        guard key.id == keyId else { throw SyncError.keyGrantFailed("the new key isn't the one announced") }
        return key
    }
}

// MARK: - base64url

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    init?(base64URLEncoded text: String) {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}
