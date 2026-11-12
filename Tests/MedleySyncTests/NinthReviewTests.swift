import Foundation
import MedleyCore
import Testing
@testable import MedleySync

/// The case the ninth review of the accounts design found, failing on the code before it (4ef321a): the owed-removal
/// loop stopped at the first error, so a withdrawal refused by the withdrawal limits (tokens no device has) kept every
/// later entry from going, including a landed device whose removal is never limited. That device could stay a holder
/// whose key this installation had already discarded. Now a `rateLimited` entry stays owed and the loop goes on.
@MainActor
@Suite(.serialized) struct NinthReviewTests {
    let url = URL(string: "https://example-123.convex.cloud")!

    func device(_ server: FakeKeyServer, _ name: String, store: any SyncCredentialStore = MemoryCredentialStore()) -> SyncService {
        let transport = FakeTransport()
        transport.autoFail = true
        return SyncService(deploymentURL: url, deviceInfo: DeviceInfo(name: name, platform: .ios, model: "t", appVersion: "1"),
                           credentials: store, transport: transport, http: server.http(), options: fastOptions(fallbackAfter: 1))
    }

    @Test func aRefusedWithdrawalNeverBlocksTheRemovalOfALandedDevice() async throws {
        let server = FakeKeyServer()
        let mac = device(server, "Leo's Mac")
        try await mac.signIn(auth: FakeTokens([jwt("u")]), userID: "u")

        // A phone's registration landed, but its answer was lost.
        let phoneStore = MemoryCredentialStore()
        let phone = device(server, "Leo's iPhone", store: phoneStore)
        server.loseRegisterAnswer(true)
        await #expect(throws: (any Error).self) { try await phone.signIn(auth: FakeTokens([jwt("u")]), userID: "u") }
        server.loseRegisterAnswer(false)
        let landed = try #require(savedRegistration(phoneStore)?.token)
        #expect(server.devices.contains { $0.token == landed })
        phone.stop()

        // Another installation owes eleven withdrawals of tokens that never landed (one more than an hour allows),
        // then the landed one.
        let store = MemoryCredentialStore()
        let unknown = (0..<11).map { "never-landed-\($0)-" + String(repeating: "x", count: 32) }
        let owed = (unknown + [landed]).map { SyncService.PendingRemoval(token: $0, userID: "u", deploymentURL: url) }
        store.setState(SyncService.PendingRemoval.stateName, try JSONEncoder().encode(owed))
        let ipad = device(server, "Leo's iPad", store: store)
        try await ipad.signIn(auth: FakeTokens([jwt("u")]), userID: "u")

        #expect(await waitUntil { !server.devices.contains { $0.token == landed } }, "the landed device was never removed")
        #expect(server.refusal(landed, user: "u") == .retired)
        // The refused withdrawal stays owed for the next sign-in; the settled ones are gone.
        #expect(await waitUntil { ipad.pendingRemovals.map(\.token) == [unknown[10]] })
        mac.stop()
        ipad.stop()
    }

    // MARK: Review 10: a key is saved before it's acknowledged

    func comparison(_ service: SyncService) -> SyncService.KeyComparison? {
        if case .comparing(let c) = service.keyStatus { c } else { nil }
    }

    /// The phone's key write fails at the moment it takes a granted key. It used to keep the key in memory only and
    /// still send `keys:accept`, so the server deleted the grant and listed it as a holder; after a relaunch it had no
    /// key and, as a holder, no way to ask again. Now nothing is acknowledged until the key is saved, and the next
    /// list retries once the store works again.
    @Test func aGrantedKeyIsAcknowledgedOnlyAfterItIsSaved() async throws {
        let server = FakeKeyServer()
        let mac = device(server, "Leo's Mac")
        try await mac.signIn(auth: FakeTokens([jwt("u")]), userID: "u")
        let phoneStore = FlakyCredentialStore()
        let phone = device(server, "Leo's iPhone", store: phoneStore)
        try await phone.signIn(auth: FakeTokens([jwt("u")]), userID: "u")
        #expect(await waitUntil { mac.keyRequests.count == 1 && comparison(phone) != nil })
        try await mac.allowKey(for: try #require(mac.keyRequests.first))
        #expect(await waitUntil { comparison(phone)?.allowed == true })

        phoneStore.failing = true
        phone.confirmKeyCode()
        _ = await waitUntil { false }   // give it the time it would take to accept
        #expect(server.calls("keys:accept", by: "Leo's iPhone").isEmpty, "the key was acknowledged without being saved")
        #expect(server.device(named: "Leo's iPhone")?.state != .holder(rekey: nil))
        #expect(phoneStore.load()?.libraryKey == nil)

        phoneStore.failing = false
        phone.setForeground(true)
        #expect(await waitUntil { phone.keyStatus == .available && server.device(named: "Leo's iPhone")?.state == .holder(rekey: nil) })
        #expect(phoneStore.load()?.libraryKey == mac.libraryKey)
        mac.stop()
        phone.stop()
    }

    /// The same for a rotated key: an unsaved rotated key is never acknowledged, so the wrap stays for the next list.
    @Test func aRotatedKeyIsAcknowledgedOnlyAfterItIsSaved() async throws {
        let server = FakeKeyServer()
        let mac = device(server, "Leo's Mac")
        try await mac.signIn(auth: FakeTokens([jwt("u")]), userID: "u")
        let phoneStore = FlakyCredentialStore()
        let phone = device(server, "Leo's iPhone", store: phoneStore)
        try await phone.signIn(auth: FakeTokens([jwt("u")]), userID: "u")
        #expect(await waitUntil { mac.keyRequests.count == 1 && comparison(phone) != nil })
        try await mac.allowKey(for: try #require(mac.keyRequests.first))
        phone.confirmKeyCode()
        #expect(await waitUntil { phone.keyStatus == .available && server.device(named: "Leo's iPhone")?.state == .holder(rekey: nil) })
        let k1 = try #require(phone.libraryKey)

        // The Mac rotates; the phone's write fails when the new key arrives.
        phoneStore.failing = true
        let acceptsBefore = server.calls("keys:accept", by: "Leo's iPhone").count
        server.setLibrary(keyId: k1.id, rotationNeeded: true)
        #expect(await waitUntil { server.keyId != k1.id })
        let k2 = try #require(server.keyId)
        _ = await waitUntil { false }
        #expect(server.calls("keys:accept", by: "Leo's iPhone").count == acceptsBefore, "the rotated key was acknowledged without being saved")
        #expect(phoneStore.load()?.libraryKey?.id == k1.id)

        phoneStore.failing = false
        phone.setForeground(true)
        #expect(await waitUntil { phone.libraryKey?.id == k2 && server.device(named: "Leo's iPhone")?.state == .holder(rekey: nil) })
        #expect(phoneStore.load()?.libraryKey?.id == k2)
        mac.stop()
        phone.stop()
    }
}
