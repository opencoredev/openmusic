import Foundation
import MedleyCore
import Testing
@testable import MedleySync

/// Real `SyncService`s through `FakeKeyServer` (which keeps content as the backend does: sealed blobs only): what plays,
/// takeovers, results and settings reach the server sealed, devices with the key read them, a device without it sees
/// only where others are, and a rotation leaves everything readable.
@MainActor
@Suite(.serialized) struct SealedContentServiceTests {
    let url = URL(string: "https://example-123.convex.cloud")!

    func device(_ server: FakeKeyServer, _ name: String) -> SyncService {
        let transport = FakeTransport()
        transport.autoFail = true
        return SyncService(deploymentURL: url, deviceInfo: DeviceInfo(name: name, platform: .mac, model: "t", appVersion: "1"),
                           credentials: MemoryCredentialStore(), transport: transport, http: server.http(), options: fastOptions(fallbackAfter: 1))
    }

    func signIn(_ service: SyncService) async throws {
        try await service.signIn(auth: FakeTokens([jwt("u")]), userID: "u")
    }

    /// `asker` signs in and gets the key through the exchange from whichever of `holders` answered it (the first answer
    /// wins, so with two holders either may).
    func approve(_ asker: SyncService, by holders: SyncService...) async throws {
        try await signIn(asker)
        #expect(await waitUntil { holders.contains { h in h.keyRequests.contains { $0.id == asker.selfID } } })
        let holder = try #require(holders.first { h in h.keyRequests.contains { $0.id == asker.selfID } })
        let request = try #require(holder.keyRequests.first { $0.id == asker.selfID })
        try await holder.allowKey(for: request)
        #expect(await waitUntil { if case .comparing(let c) = asker.keyStatus { c.allowed } else { false } })
        asker.confirmKeyCode()
        #expect(await waitUntil { asker.keyStatus == .available })
    }

    static let title = "Get Lucky (Sealed Test Title)"
    static let artist = "Daft Punk Sealed Artist"
    static let album = "Random Access Sealed Album"
    static let artworkURL = "https://lh3.googleusercontent.com/sealed-artwork"
    static let search = "sealed search text"

    func window() -> QueueWindow {
        let track = Track(providerID: "sealedTrackId1", provider: .youtubeMusic, title: Self.title, artists: [ArtistRef(name: Self.artist)],
                          album: AlbumRef(title: Self.album), duration: 240, artwork: Artwork(url: URL(string: Self.artworkURL)))
        let next = Track(providerID: "sealedTrackId2", provider: .youtubeMusic, title: "Second Sealed Song", artists: [ArtistRef(name: Self.artist)])
        return QueueWindow(entries: [QueueEntry(track: track), QueueEntry(track: next)], index: 0)
    }

    func anchor(_ service: SyncService, playing: Bool = true) -> PlaybackAnchor {
        PlaybackAnchor(positionMs: 133_000, positionAt: service.clock.now(), isPlaying: playing, durationMs: 240_000, volume: 0.5, shuffle: false, repeat: .off)
    }

    func expectNoPlaintext(_ server: FakeKeyServer, sourceLocation: SourceLocation = #_sourceLocation) {
        let dump = server.contentDump + server.sentJSON("playback:publish").joined() + server.sentJSON("commands:send").joined()
            + server.sentJSON("commands:ack").joined() + server.sentJSON("settings:put").joined() + server.sentJSON("keys:rotate").joined()
        for text in [Self.title, Self.artist, Self.album, Self.artworkURL, "googleusercontent", Self.search, "sealedTrackId", "Second Sealed Song",
                     "couldn't be loaded"] {
            #expect(!dump.contains(text), "the server saw \(text)", sourceLocation: sourceLocation)
        }
    }

    @Test func devicesWithTheKeyReadEachOthersPlaybackAndTheServerSeesNone() async throws {
        let server = FakeKeyServer()
        let mac = device(server, "Leo's Mac")
        try await signIn(mac)
        let phone = device(server, "Leo's iPhone")
        try await approve(phone, by: mac)

        try await mac.publish(anchor: anchor(mac), queue: window())
        let macID = try #require(mac.selfID)
        #expect(await waitUntil { phone.playback[macID]?.track?.title == Self.title })
        let row = try #require(phone.playback[macID])
        #expect(row.content == .open && row.index == 0 && row.queueLength == 2)
        #expect(row.anchor.positionMs == 133_000)
        // Pull: the queue opens on the phone.
        let fetched = try #require(try await phone.fetchQueue(of: macID))
        #expect(fetched.entries.map(\.track.title) == [Self.title, "Second Sealed Song"])

        // Push: a takeover from the phone opens on the Mac, and its failure message comes back sealed.
        let opened = Box<IncomingCommand?>(nil)
        mac.commandHandler = { command in
            opened.value = command
            return .failure("\"\(Self.title)\" couldn't be loaded on Leo's Mac.", reason: .playbackFailed)
        }
        let id = try await phone.send(.takeOver(HandoffState(window: window(), anchor: anchor(phone))), to: macID)
        let result = try await phone.waitForAck(id, timeout: .seconds(10))
        guard case .takeOver(let state)? = opened.value?.command else { Issue.record("no takeover arrived"); return }
        #expect(state.queue.first?.track.title == Self.title && state.anchor.positionMs == 133_000)
        #expect(!result.ok && result.reason == .playbackFailed && result.message == "\"\(Self.title)\" couldn't be loaded on Leo's Mac.")

        // Settings: recent searches go sealed and arrive.
        let searches = Box<[String]>([])
        // The receiver has no value of its own: it would fill one in if its first sync came first.
        phone.settings.observe(SettingsSync.recentSearchesKey) { text in
            searches.value = (try? JSONDecoder().decode([String].self, from: Data(text.utf8))) ?? []
        }
        mac.settings.observeRecentSearches(current: { [Self.search] }) { _ in }
        #expect(await waitUntil { searches.value == [Self.search] })
        expectNoPlaintext(server)
        mac.stop()
        phone.stop()
    }

    @Test func aDeviceWithoutTheKeySeesWhereOthersPlayNotWhatAndCanStillControlThem() async throws {
        let server = FakeKeyServer()
        let mac = device(server, "Leo's Mac")
        try await signIn(mac)
        let macID = try #require(mac.selfID)
        try await mac.publish(anchor: anchor(mac), queue: window())
        mac.settings.observeRecentSearches(current: { [Self.search] }) { _ in }

        let ipad = device(server, "Leo's iPad")   // never approved
        try await signIn(ipad)
        #expect(await waitUntil { ipad.playback[macID] != nil })
        let row = try #require(ipad.playback[macID])
        #expect(row.track == nil && row.index == nil && row.content == .sealed && row.trackLine == nil)
        #expect(row.anchor.isPlaying && row.anchor.positionMs == 133_000)
        #expect(!ipad.canSealContent)
        // It publishes its anchor alone.
        try await ipad.publish(anchor: anchor(ipad, playing: false), queue: window())
        let ipadID = try #require(ipad.selfID)
        #expect(await waitUntil { mac.playback[ipadID] != nil })
        #expect(mac.playback[ipadID]?.content == RemotePlayback.Content.none && mac.playback[ipadID]?.anchor.isPlaying == false)
        // It can pause the Mac, and the Mac can tell it why a takeover can't go there.
        let paused = Box(false)
        mac.commandHandler = { command in
            if case .pause = command.command { paused.value = true }
            return .success
        }
        let pause = try await ipad.send(.pause, to: macID)
        #expect(try await ipad.waitForAck(pause, timeout: .seconds(10)).ok)
        #expect(paused.value)
        // No handoff without the key: the queue doesn't open, and a takeover can't be sealed.
        await #expect(throws: SyncError.needsKey(device: nil)) { _ = try await ipad.fetchQueue(of: macID) }
        await #expect(throws: SyncError.needsKey(device: nil)) {
            _ = try await ipad.send(.takeOver(HandoffState(window: window(), anchor: anchor(ipad))), to: macID)
        }
        // A takeover sent to it is answered "needs key" without running.
        ipad.commandHandler = { _ in Issue.record("a sealed takeover reached the handler"); return .success }
        let toIPad = try await mac.send(.takeOver(HandoffState(window: window(), anchor: anchor(mac))), to: ipadID)
        let answer = try await mac.waitForAck(toIPad, timeout: .seconds(10))
        #expect(!answer.ok && answer.reason == .needsKey)
        #expect(answer.message?.contains("Leo's iPad doesn't have your sign-in key") == true)
        // No settings either: it neither reads them nor fills them in.
        #expect(ipad.settingEntries == nil)
        expectNoPlaintext(server)

        // Once approved, the title shows.
        try await approve(ipad, by: mac)
        #expect(await waitUntil { ipad.playback[macID]?.track?.title == Self.title })
        #expect(await waitUntil { ipad.settingEntries?.isEmpty == false })
        mac.stop()
        ipad.stop()
    }

    @Test func afterARotationEveryRemainingDeviceStillReadsPlaybackAndSettings() async throws {
        let server = FakeKeyServer()
        let mac = device(server, "Leo's Mac")
        try await signIn(mac)
        let phone = device(server, "Leo's iPhone")
        try await approve(phone, by: mac)
        let old = device(server, "Old iPad")
        try await approve(old, by: mac, phone)
        let coordinatorMac = SyncCoordinator(service: mac, player: PlayerController())
        let phonePlayer = PlayerController()
        phonePlayer.register(MockProvider(id: .youtubeMusic))
        let coordinatorPhone = SyncCoordinator(service: phone, player: phonePlayer)
        coordinatorMac.attach()
        coordinatorPhone.attach()
        let tracks = MockProvider(id: .youtubeMusic).catalog.allTracks
        phonePlayer.play(Array(tracks.prefix(3)), startAt: 1)
        let phoneID = try #require(phone.selfID)
        #expect(await waitUntil { mac.playback[phoneID]?.track?.id == tracks[1].id })
        let searches = Box<[String]>([])
        mac.settings.observe(SettingsSync.recentSearchesKey) { text in
            searches.value = (try? JSONDecoder().decode([String].self, from: Data(text.utf8))) ?? []
        }
        phone.settings.observeRecentSearches(current: { [Self.search] }) { _ in }
        #expect(await waitUntil { searches.value == [Self.search] })
        let before = try #require(mac.libraryKey)

        // The old iPad leaves: a holder rotates, the other takes the new key.
        try await mac.remove(try #require(old.selfID))
        #expect(await waitUntil { mac.libraryKey != before && phone.libraryKey == mac.libraryKey && server.keyId(of: "u") == mac.libraryKey?.id })
        let newKey = try #require(mac.libraryKey?.id)
        // The phone published again under the new key, and the Mac reads it; the settings were re-sealed and still open.
        #expect(await waitUntil { mac.playback[phoneID]?.track?.id == tracks[1].id })
        #expect(server.contentDump.contains(newKey))
        #expect(await waitUntil { phone.settingEntries?.first?.value == "[\"\(Self.search)\"]" })
        #expect(mac.settingEntries?.first?.value == "[\"\(Self.search)\"]")
        let rotate = try #require(server.sentJSON("keys:rotate").last)
        #expect(rotate.contains("\"settings\"") && !rotate.contains(Self.search))
        expectNoPlaintext(server)
        coordinatorMac.detach()
        coordinatorPhone.detach()
        mac.stop()
        phone.stop()
        old.stop()
    }
}
