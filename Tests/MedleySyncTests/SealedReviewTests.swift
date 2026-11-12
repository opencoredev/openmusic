import Foundation
import MedleyCore
import Testing
@testable import MedleySync

/// The P1s Sol's review of the sealed content found, each failing on the code before its fix.
@MainActor
@Suite(.serialized) struct SealedReviewTests {
    let tracks = MockProvider(id: .youtubeMusic).catalog.allTracks

    /// A publish in flight when the key changed used to write its queue signature back on completion, so the publish the
    /// key change asked for went out anchor-only and the queue stayed under the old key.
    @Test func aKeyChangeDuringAPublishStillPublishesTheQueueAgain() async throws {
        let hub = FakeHub()
        let a = makeDevice(hub, "A")
        a.player.play(Array(tracks.prefix(4)), startAt: 1)
        #expect(await waitUntil { a.player.state == .playing && hub.queuePublishes >= 1 })
        await a.sync.publishNow()
        let before = hub.queuePublishes
        // An anchor-only publish waits in flight...
        var release: CheckedContinuation<Void, Never>?
        var held = false
        a.node.publishGate = {
            held = true
            await withCheckedContinuation { release = $0 }
        }
        let inFlight = Task { await a.sync.publishNow() }
        #expect(await waitUntil { held })
        // ...while the key this device seals with changes.
        a.node.publishGate = nil
        a.node.onContentKeyChange?()
        try await Task.sleep(for: .milliseconds(50))
        release?.resume()
        await inFlight.value
        #expect(await waitUntil { hub.queuePublishes > before }, "the queue went out again under the new key")
        a.sync.detach()
    }

    /// At launch the saved key is known before the server's keyId: settings that arrived first used to start the first
    /// sync, whose fill-ins couldn't be sealed and were never sent again.
    @Test func settingsWaitUntilTheDeviceCanSealThenFillIn() async throws {
        let key = LibraryKey.generate()
        let service = SyncService(deploymentURL: URL(string: "https://example-123.convex.cloud")!,
                                  deviceInfo: DeviceInfo(name: "Mac", platform: .mac, model: "t", appVersion: "1"),
                                  credentials: MemoryCredentialStore(), transport: FakeTransport(), http: FakeKeyServer().http(),
                                  options: fastOptions(fallbackAfter: 1))
        service.credentials = SyncCredentials(deviceID: DeviceID("d1"), libraryID: LibraryID(rawValue: "lib"), token: String(repeating: "t", count: 43),
                                              deploymentURL: URL(string: "https://example-123.convex.cloud")!, libraryKey: key)
        service.sealedSettings = []
        service.applySettings()
        #expect(service.settingEntries == nil, "no first sync before the server's keyId says the saved key is the account's")
        service.serverKeyID = key.id
        #expect(service.settingEntries == [], "the first sync starts once it can seal")
    }
}
