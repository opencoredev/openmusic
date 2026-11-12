import CryptoKit
import Foundation
import MedleyCore
import Testing
@testable import MedleySync

/// `ContentSealing`: what the server stores of playback, queues, takeovers, results and settings.
@Suite struct ContentSealingTests {
    static func bytes(_ seed: String) -> Data { Data(SHA256.hash(data: Data(seed.utf8))) }

    let key = LibraryKey(SymmetricKey(data: ContentSealingTests.bytes("vector-K1")))
    let other = LibraryKey(SymmetricKey(data: ContentSealingTests.bytes("vector-K2")))
    let library = LibraryID(rawValue: "kh7vector0library")
    let mac = DeviceID("jd7vectorholderA")
    let phone = DeviceID("jd7vectorrequestB")

    @Test func everyKindOpensOnlyWhereItWasSealed() throws {
        let plaintext = Data(#"{"title":"Get Lucky"}"#.utf8)
        for kind in ContentKind.allCases {
            let sealed = try ContentSealing.seal(plaintext, kind: kind, library: library, writer: mac, context: "ctx", key: key)
            #expect(sealed.v == 1 && sealed.keyId == key.id)
            #expect(!Data(base64Encoded: sealed.sealed)!.contains(plaintext), "the ciphertext isn't the plaintext")
            #expect(try ContentSealing.open(sealed, kind: kind, library: library, writer: mac, context: "ctx", key: key) == plaintext)
            // Moved to another kind, account, device or context: it doesn't open.
            for wrongKind in ContentKind.allCases where wrongKind != kind {
                #expect(throws: ContentSealingError.doesNotOpen) {
                    try ContentSealing.open(sealed, kind: wrongKind, library: library, writer: mac, context: "ctx", key: key)
                }
            }
            #expect(throws: ContentSealingError.doesNotOpen) {
                try ContentSealing.open(sealed, kind: kind, library: LibraryID(rawValue: "other"), writer: mac, context: "ctx", key: key)
            }
            #expect(throws: ContentSealingError.doesNotOpen) {
                try ContentSealing.open(sealed, kind: kind, library: library, writer: phone, context: "ctx", key: key)
            }
            #expect(throws: ContentSealingError.doesNotOpen) {
                try ContentSealing.open(sealed, kind: kind, library: library, writer: mac, context: "ctx2", key: key)
            }
            // A blob that names the right key but was sealed with another doesn't open; one under another key is skipped.
            var forged = try ContentSealing.seal(plaintext, kind: kind, library: library, writer: mac, context: "ctx", key: other)
            #expect(try ContentSealing.open(forged, kind: kind, library: library, writer: mac, context: "ctx", key: key) == nil)
            forged.keyId = key.id
            #expect(throws: ContentSealingError.doesNotOpen) {
                try ContentSealing.open(forged, kind: kind, library: library, writer: mac, context: "ctx", key: key)
            }
        }
    }

    @Test func aSettingCantBeMovedToAnotherKey() throws {
        let sealed = try ContentSealing.seal(Data("[\"daft punk\"]".utf8), kind: .setting, library: library, writer: mac,
                                             context: "search.recent", key: key)
        #expect(throws: ContentSealingError.doesNotOpen) {
            try ContentSealing.open(sealed, kind: .setting, library: library, writer: mac, context: "playback.autoplay", key: key)
        }
    }

    @Test func everySealHasAFreshNonce() throws {
        let plaintext = Data("same".utf8)
        let seals = try (0..<50).map { _ in try ContentSealing.seal(plaintext, kind: .playback, library: library, writer: mac, key: key).sealed }
        #expect(Set(seals).count == 50)
        #expect(Set(seals.map { Data(base64Encoded: $0)!.prefix(12) }).count == 50)
    }

    @Test func eachKindHasItsOwnKeyNoneOfThemTheVaultKey() {
        let keys = ContentKind.allCases.map { ContentSealing.contentKey(key, kind: $0).withUnsafeBytes { Data($0) } }
        #expect(Set(keys).count == ContentKind.allCases.count)
        #expect(!keys.contains(key.key.withUnsafeBytes { Data($0) }))
    }

    @Test func theAuthenticatedDataIsLengthPrefixed() {
        let aad = ContentSealing.associatedData(kind: .setting, library: LibraryID(rawValue: "L"), writer: DeviceID("D"), keyId: "K", context: "ab")
        var expected = Data("medley.content.v1".utf8)
        for field in ["setting", "L", "D", "K", "ab"] {
            expected.append(contentsOf: [0, 0, 0, UInt8(field.utf8.count)])
            expected.append(Data(field.utf8))
        }
        #expect(aad == expected)
        // Shifting a byte between fields changes it.
        #expect(aad != ContentSealing.associatedData(kind: .setting, library: LibraryID(rawValue: "L"), writer: DeviceID("D"), keyId: "Ka", context: "b"))
    }

    // MARK: Cross-language vectors (windows/Medley.Sync)

    /// One vector per kind, sealed with a fixed nonce so the output is stable. `MEDLEY_CONTENT_VECTORS_OUT=<path>` writes
    /// them for the C# tests (`windows/Medley.Sync.Tests/Vectors/swift-content-vectors.json`); C#'s own output
    /// (`MEDLEY_CSHARP_CONTENT_VECTORS=<path>`) is opened here.
    static func vectors() throws -> [[String: String]] {
        let key = LibraryKey(SymmetricKey(data: bytes("vector-K1")))
        let library = LibraryID(rawValue: "kh7vector0library")
        let mac = DeviceID("jd7vectorholderA")
        let phone = DeviceID("jd7vectorrequestB")
        let track = Track(providerID: "5NV6Rdv1a3I", provider: .youtubeMusic, title: "Get Lucky (feat. Pharrell Williams) · Ünïcødé",
                          artists: [ArtistRef(id: "UCx", name: "Daft Punk")], album: AlbumRef(id: "MPRE1", title: "Random Access Memories"),
                          duration: 369, artwork: Artwork(url: URL(string: "https://lh3.googleusercontent.com/a/b=w544-h544")),
                          extra: ["setVideoId": "abc"])
        let entries = [QueueEntry(track: track, uid: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
                       QueueEntry(track: Track(providerID: "4uLU6hMCjMI75M1A2tKUQC", provider: .spotify, title: "Harder, Better",
                                               artists: [ArtistRef(name: "Daft Punk")]),
                                  isUserQueued: true, uid: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)]
        let window = QueueWindow(entries: entries, index: 0)
        // Sorted keys: the plaintext, and so the vector, is the same on every run.
        let json = JSONEncoder()
        json.outputFormatting = .sortedKeys
        let cases: [(ContentKind, DeviceID, String, Data)] = [
            (.playback, mac, "", try json.encode(PlaybackContent(track: track, index: 0, queueLength: 2))),
            (.queue, mac, "", try json.encode(window)),
            (.command, mac, phone.rawValue, try json.encode(window)),
            (.result, phone, "jh7vectorcommand1", try json.encode(ResultContent(message: "\"Get Lucky\" couldn't be loaded on Leo's iPhone."))),
            (.setting, mac, "search.recent", Data(#"["daft punk","Ünïcødé"]"#.utf8)),
        ]
        return try cases.map { kind, writer, context, plaintext in
            let nonce = try AES.GCM.Nonce(data: bytes("content-nonce-\(kind.rawValue)").prefix(12))
            let sealed = try ContentSealing.seal(plaintext, kind: kind, library: library, writer: writer, context: context, key: key, nonce: nonce)
            return [
                "kind": kind.rawValue, "libraryId": library.rawValue, "writer": writer.rawValue, "context": context,
                "key": key.encoded, "keyId": key.id, "plaintext": plaintext.base64EncodedString(),
                "contentKey": ContentSealing.contentKey(key, kind: kind).withUnsafeBytes { Data($0) }.base64EncodedString(),
                "aad": ContentSealing.associatedData(kind: kind, library: library, writer: writer, keyId: key.id, context: context).base64EncodedString(),
                "nonce": Data(nonce).base64EncodedString(), "sealed": sealed.sealed,
            ]
        }
    }

    @Test func vectorsOpenAndAreStable() throws {
        let vectors = try Self.vectors()
        #expect(vectors.count == ContentKind.allCases.count)
        for v in vectors {
            let kind = try #require(ContentKind(rawValue: v["kind"]!))
            let sealed = SealedContent(keyId: v["keyId"]!, sealed: v["sealed"]!)
            let opened = try ContentSealing.open(sealed, kind: kind, library: LibraryID(rawValue: v["libraryId"]!), writer: DeviceID(v["writer"]!),
                                                 context: v["context"]!, key: key)
            #expect(opened == Data(base64Encoded: v["plaintext"]!))
        }
        #expect(try Self.vectors().map { $0["sealed"] } == vectors.map { $0["sealed"] }, "a fixed nonce gives the same blob")
        if let out = ProcessInfo.processInfo.environment["MEDLEY_CONTENT_VECTORS_OUT"] {
            let data = try JSONSerialization.data(withJSONObject: ["content": vectors], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: out))
        }
    }

    /// What the C# side sealed (`windows/Medley.Sync.Tests`, `WriteCSharpContentVectors`) opens here.
    @Test func csharpVectorsOpen() throws {
        guard let path = ProcessInfo.processInfo.environment["MEDLEY_CSHARP_CONTENT_VECTORS"] else { return }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any]
        let vectors = try #require(object?["content"] as? [[String: String]])
        #expect(vectors.count == ContentKind.allCases.count)
        for v in vectors {
            let kind = try #require(ContentKind(rawValue: v["kind"]!))
            let key = try #require(LibraryKey(encoded: v["key"]!))
            let opened = try ContentSealing.open(SealedContent(keyId: v["keyId"]!, sealed: v["sealed"]!), kind: kind,
                                                 library: LibraryID(rawValue: v["libraryId"]!), writer: DeviceID(v["writer"]!), context: v["context"]!, key: key)
            #expect(opened == Data(base64Encoded: v["plaintext"]!), "C# \(kind) opens here")
            if kind == .queue || kind == .command {
                #expect((try? JSONDecoder().decode(QueueWindow.self, from: opened ?? Data())) != nil, "C# \(kind) decodes as a queue window")
            }
            if kind == .playback {
                #expect((try? JSONDecoder().decode(PlaybackContent.self, from: opened ?? Data())) != nil, "C# playback decodes")
            }
        }
    }
}
