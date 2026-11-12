import Foundation
import MedleyCore
import Testing
@testable import MedleySync

@Suite struct ConvexValueTests {
    @Test func int64UsesLittleEndianBase64() throws {
        #expect(ConvexValue.int64(1).jsonString() == #"{"$integer":"AQAAAAAAAAA="}"#)
        #expect(ConvexValue.int64(-1).jsonString() == #"{"$integer":"//////////8="}"#)
        #expect(ConvexValue.int64(Int64.min).jsonString() == #"{"$integer":"AAAAAAAAAIA="}"#)
        for value: Int64 in [0, 1, -1, 42, 1 << 40, .max, .min] {
            #expect(try ConvexValue.parse(ConvexValue.int64(value).jsonData()) == .int64(value))
        }
    }

    @Test func specialFloatsUseDollarFloat() throws {
        #expect(ConvexValue.float64(1.5).jsonString() == "1.5")
        #expect(ConvexValue.float64(200).jsonString() == "200")
        #expect(ConvexValue.float64(-0.0).jsonString() == #"{"$float":"AAAAAAAAAIA="}"#)
        #expect(ConvexValue.float64(.infinity).jsonString() == #"{"$float":"AAAAAAAA8H8="}"#)
        let nan = try ConvexValue.parse(ConvexValue.float64(.nan).jsonData())
        guard case .float64(let d) = nan else { Issue.record("expected a float"); return }
        #expect(d.isNaN)
        let negZero = try ConvexValue.parse(ConvexValue.float64(-0.0).jsonData())
        #expect(negZero.doubleValue?.sign == .minus)
        #expect(try ConvexValue.parse(Data("1e300".utf8)) == .float64(1e300))
    }

    @Test func bytesStringsAndNesting() throws {
        let value = ConvexValue.object([
            "bytes": .bytes(Data([0, 1, 2, 255])),
            "text": .string("quote \" backslash \\ newline \n tab \t bell \u{07} é 🎵"),
            "list": .array([.null, .bool(true), .bool(false), .float64(-3.25)]),
        ])
        let text = value.jsonString()
        #expect(text.contains(#""bytes":{"$bytes":"AAEC/w=="}"#))
        #expect(text.contains(#"\u0007"#))
        #expect(try ConvexValue.parse(Data(text.utf8)) == value)
        // Booleans and numbers stay apart when parsed.
        #expect(try ConvexValue.parse(Data("[true, 1, 0]".utf8)) == .array([.bool(true), .float64(1), .float64(0)]))
    }

    @Test func unknownDollarTypesAreRejected() {
        #expect(throws: ConvexValueError.self) { try ConvexValue.parse(Data(#"{"$set":"x"}"#.utf8)) }
        #expect(throws: ConvexValueError.self) { try ConvexValue.parse(Data(#"{"$integer":"AQ=="}"#.utf8)) }
    }

    @Test func codableBridgeRoundTripsTracksAndCommands() throws {
        let track = Track(providerID: "abc", provider: .spotify, title: "Song", artists: [ArtistRef(id: "a1", name: "Artist")],
                          album: AlbumRef(title: "Album"), duration: 201.5,
                          artwork: Artwork(images: [ArtworkImage(url: URL(string: "https://i.example/x.jpg")!, width: 300, height: 300)]),
                          trackNumber: 4, extra: ["uri": "spotify:track:abc"])
        let entry = QueueEntry(track: track, isUserQueued: true, context: .album(Album(providerID: "al", provider: .spotify, title: "Album")))
        let encoded = try ConvexValue(encoding: entry)
        // Shapes the Convex validators expect: plain numbers, URL strings, no nulls for missing optionals.
        #expect(encoded["track"]?["duration"] == .float64(201.5))
        #expect(encoded["track"]?["trackNumber"] == .float64(4))
        #expect(encoded["track"]?["artwork"]?["images"] == .array([.object(["url": .string("https://i.example/x.jpg"), "width": .float64(300), "height": .float64(300)])]))
        #expect(encoded["track"]?["album"] == .object(["title": .string("Album")]))
        #expect(encoded["uid"] == .string(entry.uid.uuidString))
        #expect(try encoded.decode(QueueEntry.self) == entry)

        let state = HandoffState(queue: [entry], index: 0, anchor: PlaybackAnchor(positionMs: 1000, positionAt: 5, isPlaying: true, durationMs: nil, volume: 0.5, shuffle: false, repeat: .all))
        for command: SyncCommand in [.play, .seek(positionMs: 42_000), .setVolume(0.25)] {
            let value = try ConvexValue(encoding: WireCommand.plain(command))
            #expect(value["kind"] == .string(command.kind.rawValue))
            #expect(try value.decode(WireCommand.self) == .plain(command))
        }
        #expect(try ConvexValue(encoding: WireCommand.plain(.seek(positionMs: 5))) == .object(["kind": .string("seek"), "positionMs": .float64(5)]))
        // A takeover never goes in the clear: only its anchor and the sealed queue.
        #expect(throws: (any Error).self) { try ConvexValue(encoding: WireCommand.plain(.takeOver(state))) }
        let sealed = SealedContent(keyId: String(repeating: "a", count: 32), sealed: "c2VhbGVk")
        let takeOver = try ConvexValue(encoding: WireCommand.takeOver(anchor: state.anchor, content: sealed))
        #expect(takeOver["kind"] == .string("takeOver") && takeOver["state"] == nil && takeOver["content"]?["v"] == .float64(1))
        #expect(try takeOver.decode(WireCommand.self) == .takeOver(anchor: state.anchor, content: sealed))
        // A device list with a platform this build doesn't know still decodes: that device shows as a generic computer.
        let device = try ConvexValue(json: ["id": "d9", "name": "PC", "platform": "fuchsia", "model": "m", "appVersion": "1", "createdAt": 1, "lastSeenAt": 2])
        #expect(try device.decode(SyncDevice.self).platform == .unknown)
        #expect(try ConvexValue.string("windows").decode(DevicePlatform.self) == .windows)
    }
}

@Suite struct ClockAndPositionTests {
    @Test func offsetUsesTheFastestRoundTrip() {
        var clock = ServerClock()
        let t0 = Date(timeIntervalSince1970: 1000)
        // Slow sample: 400 ms round trip, server 1000 ms ahead.
        clock.record(serverNow: 1_000_000 + 1000 + 200 + 50, sentAt: t0, receivedAt: t0.addingTimeInterval(0.4))
        // Fast sample: 20 ms round trip, server exactly 1000 ms ahead.
        let t1 = Date(timeIntervalSince1970: 1001)
        clock.record(serverNow: 1_001_000 + 1000 + 10, sentAt: t1, receivedAt: t1.addingTimeInterval(0.02))
        #expect(abs(clock.offsetMs - 1000) < 0.001)
        #expect(abs(clock.now(Date(timeIntervalSince1970: 2000)) - 2_001_000) < 0.001)
        #expect(abs(clock.localDate(2_001_000).timeIntervalSince1970 - 2000) < 0.000_01)
    }

    @Test func oldSamplesFallOut() {
        var clock = ServerClock()
        let t = Date(timeIntervalSince1970: 0)
        clock.record(serverNow: 500, sentAt: t, receivedAt: t) // 0 ms round trip, offset 500
        for i in 0..<ServerClock.maxSamples {
            let at = Date(timeIntervalSince1970: Double(i + 1))
            clock.record(serverNow: at.timeIntervalSince1970 * 1000 + 50 + 5, sentAt: at, receivedAt: at.addingTimeInterval(0.01))
        }
        #expect(abs(clock.offsetMs - 50) < 0.001)
    }

    @Test func extrapolationFollowsTheAnchor() {
        let anchor = PlaybackAnchor(positionMs: 30_000, positionAt: 1_000_000, isPlaying: true, durationMs: 200_000, volume: 1, shuffle: false, repeat: .off)
        #expect(anchor.position(atServerTime: 1_000_000) == 30)
        #expect(anchor.position(atServerTime: 1_012_500) == 42.5)
        // Clock skew backwards never rewinds.
        #expect(anchor.position(atServerTime: 999_000) == 30)
        // Clamped to the track.
        #expect(anchor.position(atServerTime: 1_000_000 + 500_000) == 200)
        var paused = anchor
        paused.isPlaying = false
        #expect(paused.position(atServerTime: 1_100_000) == 30)
        var fast = anchor
        fast.rate = 2
        #expect(fast.position(atServerTime: 1_010_000) == 50)
    }

    @Test func extrapolationWithAClockOffset() {
        // The server runs 2.5 s ahead of this device; the anchor is in server time.
        var clock = ServerClock()
        let sent = Date(timeIntervalSince1970: 10_000)
        clock.record(serverNow: 10_000_000 + 2_500 + 15, sentAt: sent, receivedAt: sent.addingTimeInterval(0.03))
        let anchor = PlaybackAnchor(positionMs: 60_000, positionAt: 10_000_000 + 2_500, isPlaying: true, durationMs: nil, volume: 1, shuffle: false, repeat: .off)
        // Four local seconds after `sent`, the source is four seconds further.
        let local = sent.addingTimeInterval(4)
        #expect(abs(anchor.position(atServerTime: clock.now(local)) - 64) < 0.02)
    }

    @Test func queueWindowKeeps20BeforeAnd100After() {
        let entries = (0..<300).map { QueueEntry(track: Track(providerID: "t\($0)", provider: .youtubeMusic, title: "\($0)")) }
        let w = QueueWindow(queue: entries, current: 150)!
        #expect(w.entries.count == 121)
        #expect(w.index == 20)
        #expect(w.current.track.providerID == "t150")
        let start = QueueWindow(queue: entries, current: 3)!
        #expect(start.index == 3)
        #expect(start.entries.count == 104)
        #expect(QueueWindow(queue: entries, current: nil) == nil)
        #expect(QueueWindow(queue: [], current: 0) == nil)
    }
}

@Suite struct VaultKeyTests {
    @Test func libraryKeyFingerprintAndEncoding() throws {
        let key = LibraryKey.generate()
        #expect(key.id.count == 32)
        #expect(key.id.allSatisfy { "0123456789abcdef".contains($0) })
        let again = try #require(LibraryKey(encoded: key.encoded))
        #expect(again == key && again.id == key.id)
        #expect(LibraryKey.generate().id != key.id)
        #expect(LibraryKey(encoded: "short") == nil)
        #expect(!"\(key)".contains(key.encoded))
        let json = try JSONEncoder().encode(key)
        #expect(try JSONDecoder().decode(LibraryKey.self, from: json) == key)
    }

    @Test func sealedSignInsOpenOnlyWithTheKeyProviderAndRevision() throws {
        let key = LibraryKey.generate()
        let secret = Data(#"{"refreshToken":"AQB-secret"}"#.utf8)
        let sealed = try SignInSealing.seal(secret, provider: .spotify, revision: 3, key: key)
        #expect(!sealed.contains("secret"))
        #expect(try SignInSealing.open(sealed, provider: .spotify, revision: 3, key: try #require(LibraryKey(encoded: key.encoded))) == secret)
        #expect(throws: SyncError.self) { try SignInSealing.open(sealed, provider: .spotify, revision: 3, key: LibraryKey.generate()) }
        #expect(throws: SyncError.self) { try SignInSealing.open(sealed, provider: .youtubeMusic, revision: 3, key: key) }
        // The same blob served at another revision (replayed on top of a newer write) doesn't open.
        #expect(throws: SyncError.self) { try SignInSealing.open(sealed, provider: .spotify, revision: 4, key: key) }
        // A fresh nonce every time.
        #expect(try SignInSealing.seal(secret, provider: .spotify, revision: 3, key: key) != sealed)
    }

    @Test func credentialsNeverPrintTheTokenOrKeys() {
        let creds = SyncCredentials(deviceID: DeviceID("d1"), libraryID: LibraryID(rawValue: "l1"), token: "secret-token-value",
                                    deploymentURL: SyncService.defaultDeploymentURL, libraryKey: .generate())
        let raw = creds.deviceKey.privateKey.rawRepresentation.base64EncodedString()
        for text in ["\(creds)", String(reflecting: creds), "\(creds.deviceKey)"] {
            #expect(!text.contains("secret-token-value"))
            #expect(!text.contains(raw))
            #expect(!text.contains(creds.libraryKey!.encoded))
        }
    }

    @Test func fileStoreIsOwnerOnlyAndKeepsTheKeyPair() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "medley-sync-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileCredentialStore(url: url)
        let creds = SyncCredentials(deviceID: DeviceID("d1"), libraryID: LibraryID(rawValue: "l1"), token: "t", deploymentURL: SyncService.defaultDeploymentURL)
        store.save(creds)
        #expect(store.load() == creds)
        #expect(store.load()?.deviceKey.publicKey == creds.deviceKey.publicKey)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o600)
        store.save(nil)
        #expect(store.load() == nil)
    }

    @Test func credentialsFromBeforeAccountsAreDroppedButStateIsKept() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "medley-sync-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        // A paired device's file: a token and a library key, no device key pair.
        let old = #"{"credentials":{"deviceID":"d1","libraryID":"l1","token":"t","deploymentURL":"https://x.convex.cloud"},"installKey":"k","state":{"x":"AQI="}}"#
        try Data(old.utf8).write(to: url)
        let store = FileCredentialStore(url: url)
        #expect(store.load() == nil)
        #expect(store.state("x") == Data([1, 2]))
    }
}
