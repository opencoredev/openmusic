import Foundation
import Testing
@testable import YouTubeMusicKit

/// A cookie read that waits until the test releases it, like `youtubeCookies` suspended on WebKit.
@MainActor
private final class HeldCookieRead {
    private var continuation: CheckedContinuation<YTMCredentials?, Never>?
    private(set) var started = false
    let creds = YTMCredentials(cookies: ["SAPISID": "x", "__Secure-3PAPISID": "y", "SID": "z"])

    func read() async -> YTMCredentials? {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume(returning: creds)
        continuation = nil
    }
}

@MainActor
struct SignInGateTests {
    private func waitForStart(_ read: HeldCookieRead) async {
        for _ in 0..<200 where !read.started { await Task.yield() }
    }

    @Test func deliversWhenTheSheetIsOpen() async {
        let gate = YTMSignInGate()
        var delivered: [YTMCredentials] = []
        let navigator = YTMSignInNavigator(gate: gate) { delivered.append($0) }
        let read = HeldCookieRead()
        let task = navigator.deliverCredentials { await read.read() }
        await waitForStart(read)
        read.release()
        await task.value
        #expect(delivered.count == 1)
    }

    @Test func closingTheSheetMidReadDropsTheCapture() async {
        let gate = YTMSignInGate()
        var delivered = 0
        let navigator = YTMSignInNavigator(gate: gate) { _ in delivered += 1 }
        let read = HeldCookieRead()
        let task = navigator.deliverCredentials { await read.read() }
        await waitForStart(read)
        #expect(read.started)
        // Cancel tapped while the cookie store is being read.
        gate.close()
        read.release()
        await task.value
        #expect(delivered == 0)
    }

    @Test func dismantledWebViewDropsTheCapture() async {
        let gate = YTMSignInGate()
        var delivered = 0
        let navigator = YTMSignInNavigator(gate: gate) { _ in delivered += 1 }
        let read = HeldCookieRead()
        let task = navigator.deliverCredentials { await read.read() }
        await waitForStart(read)
        navigator.invalidate()
        read.release()
        await task.value
        #expect(delivered == 0)
        #expect(navigator.isInvalidated)
    }

    @Test func closedSheetDoesNotEvenStartARead() async {
        let gate = YTMSignInGate()
        gate.close()
        var delivered = 0
        let navigator = YTMSignInNavigator(gate: gate) { _ in delivered += 1 }
        let read = HeldCookieRead()
        let task = navigator.deliverCredentials { await read.read() }
        await task.value
        #expect(!read.started)
        #expect(delivered == 0)
    }

    @Test func reopenedSheetAcceptsAgain() async {
        let gate = YTMSignInGate()
        gate.close()
        gate.open()
        var delivered = 0
        let navigator = YTMSignInNavigator(gate: gate) { _ in delivered += 1 }
        let read = HeldCookieRead()
        let task = navigator.deliverCredentials { await read.read() }
        await waitForStart(read)
        read.release()
        await task.value
        #expect(delivered == 1)
    }
}
