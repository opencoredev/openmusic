import CryptoKit
import Foundation
import Testing
@testable import MedleySync

@Suite struct KeyGrantTests {
    let library = LibraryID(rawValue: "lib1")
    let phone = DeviceID("phone")
    let mac = DeviceID("mac")

    /// One honest run: the phone (B) asks, the Mac (A) answers. Each side builds the transcript from its own record.
    func honest(_ b: DeviceKeyPair, _ a: DeviceKeyPair) -> (transcript: KeyExchange.Transcript, nonceB: Data, nonceA: Data) {
        let nonceB = KeyExchange.nonce()
        let nonceA = KeyExchange.nonce()
        let t = KeyExchange.Transcript(libraryID: library, requester: phone, requesterKey: b.publicKey, requesterNonce: nonceB,
                                       holder: mac, holderKey: a.publicKey, holderNonce: nonceA)
        return (t, nonceB, nonceA)
    }

    @Test func bothDevicesShowTheSameCodeAndEveryFieldChangesIt() throws {
        let b = DeviceKeyPair.generate()
        let a = DeviceKeyPair.generate()
        let (t, _, _) = honest(b, a)
        #expect(t.code.count == 7 && t.code.dropFirst(3).first == " " && t.code.filter(\.isNumber).count == 6)
        // The other side, from its own copy of the same values, gets the same code.
        let mirror = KeyExchange.Transcript(libraryID: t.libraryID, requester: t.requester, requesterKey: t.requesterKey,
                                            requesterNonce: t.requesterNonce, holder: t.holder, holderKey: t.holderKey, holderNonce: t.holderNonce)
        #expect(mirror.code == t.code)
        var changed = [t, t, t, t, t, t, t]
        changed[0].libraryID = LibraryID(rawValue: "lib2")
        changed[1].requester = DeviceID("ipad")
        changed[2].requesterKey = DeviceKeyPair.generate().publicKey
        changed[3].requesterNonce = KeyExchange.nonce()
        changed[4].holder = DeviceID("server")
        changed[5].holderKey = DeviceKeyPair.generate().publicKey
        changed[6].holderNonce = KeyExchange.nonce()
        for other in changed { #expect(other.digest != t.digest) }
    }

    /// A holder's answer to one request is always the same nonce, nobody without its private key can predict it, and
    /// every field of the request the code covers changes it: a commitment shown again as another device, or with
    /// another key, gets a nonce of its own (the third review's replay of a pruned commitment under a new id).
    @Test func aHolderHasOneNoncePerRequestAndEveryFieldChangesIt() throws {
        let a = DeviceKeyPair.generate()
        let b = DeviceKeyPair.generate()
        let c = KeyExchange.nonce().base64EncodedString()
        func nonce(holder: DeviceKeyPair = a, holderID: DeviceID = DeviceID("mac"), library: LibraryID = LibraryID(rawValue: "lib1"),
                   requester: DeviceID = DeviceID("phone"), requesterKey: String? = nil, commitment: String? = nil) -> Data? {
            KeyExchange.answerNonce(holder: holder, holderID: holderID, libraryID: library, requester: requester,
                                    requesterKey: requesterKey ?? b.publicKey, commitment: commitment ?? c)
        }
        let first = try #require(nonce())
        #expect(first.count == 32)
        #expect(nonce() == first)
        let changed: [Data?] = [
            nonce(holder: .generate()),
            nonce(holderID: DeviceID("other-mac")),
            nonce(library: LibraryID(rawValue: "lib2")),
            nonce(requester: DeviceID("made-up-ipad")),
            nonce(requesterKey: DeviceKeyPair.generate().publicKey),
            nonce(commitment: KeyExchange.nonce().base64EncodedString()),
        ]
        for other in changed { #expect(other != nil && other != first) }
        // Malformed keys and commitments get no answer.
        #expect(nonce(requesterKey: "short") == nil)
        #expect(nonce(commitment: "c") == nil)
    }

    @Test func theCommitmentBindsTheKeyAndTheNonce() throws {
        let b = DeviceKeyPair.generate()
        let nonce = KeyExchange.nonce()
        let c = try #require(KeyExchange.commitment(publicKey: b.publicKey, nonce: nonce))
        #expect(KeyExchange.commitment(publicKey: b.publicKey, nonce: nonce) == c)
        #expect(KeyExchange.commitment(publicKey: b.publicKey, nonce: KeyExchange.nonce()) != c)
        #expect(KeyExchange.commitment(publicKey: DeviceKeyPair.generate().publicKey, nonce: nonce) != c)
        #expect(KeyExchange.commitment(publicKey: "short", nonce: nonce) == nil)
        #expect(KeyExchange.commitment(publicKey: b.publicKey, nonce: Data([1, 2, 3])) == nil)
    }

    /// The attack the old code allowed: the server puts its own key in place of the new device's (and of the
    /// holder's, towards the new device). With the old static code it could search a million key pairs offline for
    /// one whose code matched. Now each side's code also covers a nonce the server must fix before it sees the
    /// other side's, so it can't search: every try is a fresh 1-in-a-million guess the listener sees fail.
    @Test func aServerInTheMiddleGetsTwoDifferentCodes() throws {
        let b = DeviceKeyPair.generate()
        let a = DeviceKeyPair.generate()
        let server = DeviceKeyPair.generate()
        var matches = 0
        for _ in 0..<200 {
            // Towards the Mac the server poses as the phone with its own key and nonce (committed before nA).
            let nonceServerB = KeyExchange.nonce()
            let nonceA = KeyExchange.nonce()
            let seenByMac = KeyExchange.Transcript(libraryID: library, requester: phone, requesterKey: server.publicKey, requesterNonce: nonceServerB,
                                                   holder: mac, holderKey: a.publicKey, holderNonce: nonceA)
            // Towards the phone it poses as the Mac (its nonce chosen before the phone revealed nB).
            let nonceServerA = KeyExchange.nonce()
            let nonceB = KeyExchange.nonce()
            let seenByPhone = KeyExchange.Transcript(libraryID: library, requester: phone, requesterKey: b.publicKey, requesterNonce: nonceB,
                                                     holder: mac, holderKey: server.publicKey, holderNonce: nonceServerA)
            if seenByMac.code == seenByPhone.code { matches += 1 }
        }
        #expect(matches == 0)
    }

    @Test func aGrantOpensOnlyForTheRecordedExchangeAndOnlyFromItsHolder() throws {
        let key = LibraryKey.generate()
        let b = DeviceKeyPair.generate()
        let a = DeviceKeyPair.generate()
        let (t, _, _) = honest(b, a)
        let wrapped = try KeyExchange.wrap(key, transcript: t, holder: a)
        #expect(!wrapped.contains(key.encoded))
        let opened = try KeyExchange.unwrap(wrapped, transcript: t, requester: b, keyId: key.id)
        #expect(opened == key)
        #expect(opened.key.withUnsafeBytes { Data($0) } == key.key.withUnsafeBytes { Data($0) })

        // Not on another device, not for another exchange, not for another fingerprint.
        #expect(throws: SyncError.self) { try KeyExchange.unwrap(wrapped, transcript: t, requester: .generate(), keyId: key.id) }
        var other = t
        other.holderNonce = KeyExchange.nonce()
        #expect(throws: SyncError.self) { try KeyExchange.unwrap(wrapped, transcript: other, requester: b, keyId: key.id) }
        #expect(throws: SyncError.self) { try KeyExchange.unwrap(wrapped, transcript: t, requester: b, keyId: LibraryKey.generate().id) }

        // A key of the server's own, wrapped by a key pair the transcript doesn't name, doesn't open: the grant is
        // authenticated by the holder's device key that the code covered.
        let server = DeviceKeyPair.generate()
        var forgedTranscript = t
        forgedTranscript.holderKey = server.publicKey
        let fake = LibraryKey.generate()
        let forged = try KeyExchange.wrap(fake, transcript: forgedTranscript, holder: server)
        #expect(throws: SyncError.self) { try KeyExchange.unwrap(forged, transcript: t, requester: b, keyId: fake.id) }
        // The holder can only wrap as itself, and a tampered blob doesn't open.
        #expect(throws: SyncError.self) { try KeyExchange.wrap(key, transcript: t, holder: server) }
        var bytes = try #require(Data(base64Encoded: wrapped))
        bytes[bytes.count - 1] ^= 0x01
        #expect(throws: SyncError.self) { try KeyExchange.unwrap(bytes.base64EncodedString(), transcript: t, requester: b, keyId: key.id) }
    }

    @Test func aRotatedKeyOpensOnlyForItsHolderAndOnlyIfMadeWithTheOldKey() throws {
        let old = LibraryKey.generate()
        let new = LibraryKey.generate()
        let holder = DeviceKeyPair.generate()
        let wrapped = try KeyRotation.wrap(new, replacing: old, to: holder.publicKey, libraryID: library, deviceID: phone)
        #expect(try KeyRotation.unwrap(wrapped, with: holder, replacing: old, libraryID: library, deviceID: phone, keyId: new.id) == new)
        #expect(throws: SyncError.self) {
            try KeyRotation.unwrap(wrapped, with: .generate(), replacing: old, libraryID: library, deviceID: phone, keyId: new.id)
        }
        #expect(throws: SyncError.self) {
            try KeyRotation.unwrap(wrapped, with: holder, replacing: old, libraryID: library, deviceID: mac, keyId: new.id)
        }
        // The server knows the holder's public key but not the old vault key: its own "rotation" doesn't open.
        let serverKey = LibraryKey.generate()
        let forged = try KeyRotation.wrap(serverKey, replacing: LibraryKey.generate(), to: holder.publicKey, libraryID: library, deviceID: phone)
        #expect(throws: SyncError.self) {
            try KeyRotation.unwrap(forged, with: holder, replacing: old, libraryID: library, deviceID: phone, keyId: serverKey.id)
        }
        #expect(throws: SyncError.self) {
            try KeyRotation.unwrap(wrapped, with: holder, replacing: old, libraryID: library, deviceID: phone, keyId: serverKey.id)
        }
    }

    @Test func theKeyPairRoundTripsAndNeverPrintsItsPrivateHalf() throws {
        let pair = DeviceKeyPair.generate()
        let data = try JSONEncoder().encode(pair)
        let back = try JSONDecoder().decode(DeviceKeyPair.self, from: data)
        #expect(back.publicKey == pair.publicKey)
        #expect(!"\(pair)".contains(pair.privateKey.rawRepresentation.base64EncodedString()))
        #expect("\(pair)".contains("<redacted>"))
    }
}
