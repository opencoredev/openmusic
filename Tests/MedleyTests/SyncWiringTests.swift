import Foundation
import MedleySync
import SwiftUI
import Testing
@testable import Medley

/// Settings › Account's sign-in sync line for each key state.
@MainActor @Suite struct SignInSyncTextTests {
    @Test func aDeviceWithoutTheKeySaysSoInsteadOfChecking() {
        let comparing = SyncService.KeyComparison(code: "123 456", holderID: DeviceID("phone"), holderName: "iPhone", allowed: true, confirmed: false)
        #expect(SignInSyncText.status(nil, keyStatus: .waiting) == "Not shared with this Mac")
        #expect(SignInSyncText.status(.synced(1), keyStatus: .comparing(comparing)) == "Not shared with this Mac")
        #expect(SignInSyncText.status(.synced(1), keyStatus: .denied) == "Not shared with this Mac")
        #expect(SignInSyncText.status(.synced(1), keyStatus: .failed("x")) == "Not shared with this Mac")
        #expect(SignInSyncText.status(.synced(1), keyStatus: .available) == "Synced")
        #expect(SignInSyncText.status(.notSignedIn, keyStatus: .available) == "Not signed in")
    }
}

@MainActor @Suite struct DevicesScheduleTests {
    let start = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func ticksEverySecondWhileADevicePlays() {
        let dates = Array(DevicesSchedule(ticking: true, expiries: []).entries(from: start, mode: .normal).prefix(4))
        #expect(dates == [0, 1, 2, 3].map { start.addingTimeInterval($0) })
    }

    @Test func otherwiseRedrawsOnlyWhenADeviceGoesOffline() {
        let expiries = [start.addingTimeInterval(40), start.addingTimeInterval(-5), start.addingTimeInterval(12)]
        let dates = Array(DevicesSchedule(ticking: false, expiries: expiries).entries(from: start, mode: .normal))
        #expect(dates == [start, start.addingTimeInterval(12), start.addingTimeInterval(40)])
    }
}

/// The Mac's "Allow …?" alert (`KeyRequestPrompter`) against a preview hub's requests, on a real window. Sol's re-check
/// of the merge: a held alert must give way to the device's new exchange, close when its request ends, and close and
/// stay closed when its hub stops (sign-out of a server, a server switch).
@MainActor @Suite(.serialized) struct KeyRequestPrompterTests {
    let now = Date().timeIntervalSince1970 * 1000

    func device(_ id: String, _ name: String, _ state: KeyStateKind) -> SyncDevice {
        SyncDevice(id: DeviceID(id), name: name, platform: .ios, model: "iPhone18,1", appVersion: "1.0",
                   createdAt: now, lastSeenAt: now, keyState: state)
    }

    func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test func theAlertFollowsTheCurrentExchangeAndEndsWithItsHub() async throws {
        _ = NSApplication.shared
        let model = AppModel(environment: ["MEDLEY_MOCK": "1"])
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        // Closed at the end: without this, AppKit releases a window made in code on close and ARC releases it again.
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        model.mainWindow = window
        let hub = SyncHub.preview(model: model)
        model.usePreviewSync(hub)
        let prompter = try #require(hub.keyPrompter)
        let mac = device("mac", "Mac", .holder)
        let phone = device("phone", "iPhone", .requested)
        let first = SyncService.KeyRequest(device: phone, code: "111 111", commitment: "A")
        let second = SyncService.KeyRequest(device: phone, code: "222 222", commitment: "B")

        hub.service.preview(selfID: mac.id, devices: [mac, phone], keyStatus: .available, requests: [first])
        #expect(await waitUntil { prompter.current == first && window.attachedSheet != nil })
        // The phone asked again: the alert for A closes and B's comes up, never A's buttons answering B.
        hub.service.preview(selfID: mac.id, devices: [mac, phone], keyStatus: .available, requests: [second])
        #expect(await waitUntil { prompter.current == second && window.attachedSheet != nil })
        // B ended (allowed elsewhere): no alert.
        hub.service.preview(selfID: mac.id, devices: [mac, phone], keyStatus: .available, requests: [])
        #expect(await waitUntil { prompter.current == nil && window.attachedSheet == nil })
        // Dismissed, it stays away for that exchange.
        hub.dismissedKeyRequests.dismiss(first)
        hub.service.preview(selfID: mac.id, devices: [mac, phone], keyStatus: .available, requests: [first])
        try await Task.sleep(for: .milliseconds(300))
        #expect(prompter.current == nil && window.attachedSheet == nil)
        hub.dismissedKeyRequests.show(phone.id)
        #expect(await waitUntil { prompter.current == first && window.attachedSheet != nil })
        // The hub stops (a server switch): the alert closes and nothing comes up again.
        model.usePreviewSync(nil)
        #expect(await waitUntil { prompter.current == nil && window.attachedSheet == nil })
        hub.service.preview(selfID: mac.id, devices: [mac, phone], keyStatus: .available, requests: [second])
        try await Task.sleep(for: .milliseconds(300))
        #expect(prompter.current == nil && window.attachedSheet == nil)
        window.close()
    }

    /// Sol's second re-check: an alert begun behind another sheet was queued where it couldn't be ended, and came up
    /// later for a request that was gone; Allow showed the same request again while its grant was on the way.
    @Test func theAlertWaitsForAFreeWindowAndAnAnswerKeepsItAway() async throws {
        _ = NSApplication.shared
        let model = AppModel(environment: ["MEDLEY_MOCK": "1"])
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        model.mainWindow = window
        let hub = SyncHub.preview(model: model)
        model.usePreviewSync(hub)
        let prompter = try #require(hub.keyPrompter)
        let mac = device("mac", "Mac", .holder)
        let phone = device("phone", "iPhone", .requested)
        let first = SyncService.KeyRequest(device: phone, code: "111 111", commitment: "A")
        let second = SyncService.KeyRequest(device: phone, code: "222 222", commitment: "B")

        // Another sheet is up (the welcome, a confirmation): nothing is queued behind it.
        let other = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        window.beginSheet(other, completionHandler: nil)
        hub.service.preview(selfID: mac.id, devices: [mac, phone], keyStatus: .available, requests: [first])
        try await Task.sleep(for: .milliseconds(400))
        #expect(prompter.current == nil && window.attachedSheet === other)
        // The request ends while the other sheet is up; when it closes, nothing stale comes up.
        hub.service.preview(selfID: mac.id, devices: [mac, phone], keyStatus: .available, requests: [])
        window.endSheet(other)
        try await Task.sleep(for: .milliseconds(1500))
        #expect(prompter.current == nil && window.attachedSheet == nil)
        // A request that is still waiting comes up once the window is free.
        window.beginSheet(other, completionHandler: nil)
        hub.service.preview(selfID: mac.id, devices: [mac, phone], keyStatus: .available, requests: [second])
        try await Task.sleep(for: .milliseconds(300))
        #expect(prompter.current == nil)
        window.endSheet(other)
        #expect(await waitUntil { prompter.current == second && window.attachedSheet != nil && window.attachedSheet !== other })

        // Allow: the grant goes out (and fails here, with no server); the same exchange doesn't come straight back.
        func buttons(in view: NSView) -> [NSButton] { ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons) }
        let allow = try #require(window.attachedSheet?.contentView.flatMap { buttons(in: $0).first { $0.title == "Allow" } })
        allow.performClick(nil)
        #expect(await waitUntil { prompter.current == nil && window.attachedSheet == nil })
        try await Task.sleep(for: .milliseconds(600))
        #expect(prompter.current == nil && window.attachedSheet == nil)
        #expect(hub.dismissedKeyRequests.contains(second))
        model.usePreviewSync(nil)
        window.close()
        other.close()
    }
}
