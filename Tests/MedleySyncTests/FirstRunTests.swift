import Foundation
import MedleyCore
import Testing
@testable import MedleySync

@Suite("First run")
struct FirstRunTests {
    private func defaults() -> UserDefaults {
        let name = "first-run-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func freshInstallShows() {
        #expect(FirstRun.shouldShow(defaults: defaults(), anyServiceSignedIn: false))
    }

    @Test func finishedNeverShowsAgain() {
        let d = defaults()
        FirstRun.markFinished(defaults: d)
        #expect(!FirstRun.shouldShow(defaults: d, anyServiceSignedIn: false))
        // An older build run afterwards sees its own welcome as answered too.
        for key in FirstRun.legacyKeys { #expect(d.bool(forKey: key)) }
    }

    @Test(arguments: FirstRun.legacyKeys)
    func earlierWelcomeAnsweredDoesNotShow(key: String) {
        let d = defaults()
        d.set(true, forKey: key)
        #expect(!FirstRun.shouldShow(defaults: d, anyServiceSignedIn: false))
    }

    @Test func restoredServiceSignInDoesNotShow() {
        #expect(!FirstRun.shouldShow(defaults: defaults(), anyServiceSignedIn: true))
    }

    @Test func routingAfterSignIn() {
        let comparison = SyncService.KeyComparison(code: "123 456", holderID: DeviceID("a"), holderName: "Mac", allowed: false, confirmed: false)
        #expect(FirstRun.afterSignIn(keyStatus: .none) == nil)
        #expect(FirstRun.afterSignIn(keyStatus: .available) == .done)
        #expect(FirstRun.afterSignIn(keyStatus: .waiting) == .approve)
        #expect(FirstRun.afterSignIn(keyStatus: .comparing(comparison)) == .approve)
        #expect(FirstRun.afterSignIn(keyStatus: .denied) == .approve)
        #expect(FirstRun.afterSignIn(keyStatus: .failed("x")) == .approve)
        #expect(FirstRun.afterSignIn(keyStatus: .outdated) == .approve)
        #expect(FirstRun.afterSignIn(keyStatus: .mismatch) == .done)
    }

    @Test func codes() {
        #expect(FirstRun.codeDigits("Code: 123-456 ") == "123456")
        #expect(FirstRun.codeDigits("1234567") == "123456")
        #expect(FirstRun.codeDigits("١٢٣") == "")
        #expect(FirstRun.spacedCode("482913") == "482 913")
        #expect(FirstRun.spacedCode("482 913") == "482 913")
        #expect(FirstRun.spokenCode("482 913") == "4 8 2, 9 1 3")
    }

    @Test func approveTitle() {
        let now = Date().timeIntervalSince1970 * 1000
        let mac = SyncDevice(id: DeviceID("m"), name: "Studio", platform: .mac, model: "Mac16,10", appVersion: "1", createdAt: now, lastSeenAt: now, keyState: .holder)
        let phone = SyncDevice(id: DeviceID("p"), name: "Phone", platform: .ios, model: "iPhone18,1", appVersion: "1", createdAt: now, lastSeenAt: now, keyState: .holder)
        #expect(FirstRun.approveTitle(holders: [mac], here: "this iPhone") == "Open \(ProductInfo.name) on your Mac to approve this iPhone")
        #expect(FirstRun.approveTitle(holders: [mac, phone], here: "this Mac") == "Open \(ProductInfo.name) on your other device to approve this Mac")
        #expect(FirstRun.approveTitle(holders: [], here: "this Mac") == "Open \(ProductInfo.name) on your other device to approve this Mac")
    }

    @Test func serverProblemsAreSaidPlainly() {
        func message(_ code: URLError.Code) -> String { AccountService.unreachableMessage(URLError(code), host: "sync.example.com") }
        #expect(message(.cannotFindHost) == "Can't find a server at sync.example.com. Check the address and try again.")
        #expect(message(.dnsLookupFailed) == message(.cannotFindHost))
        #expect(message(.notConnectedToInternet).hasPrefix("This device is offline."))
        #expect(message(.timedOut).hasPrefix("sync.example.com didn't answer."))
        #expect(message(.cannotConnectToHost).hasPrefix("sync.example.com refused the connection."))
        #expect(message(.badServerResponse).hasPrefix("Can't reach that server: "))
        #expect(AccountService.ServerError.unreachable("x").errorDescription == "x")
    }

    @Test func codeProblemsSayWhatToDo() {
        #expect(FirstRun.codeProblem(ClerkError.refused(code: "form_code_incorrect", message: "Incorrect code")).hasPrefix("That code isn't right."))
        #expect(FirstRun.codeProblem(ClerkError.refused(code: "verification_expired", message: "expired")) == "That code has expired. Send a new code.")
        #expect(FirstRun.codeProblem(ClerkError.refused(code: "other", message: "Clerk says no")) == "Clerk says no")
        #expect(FirstRun.codeProblem(ClerkError.sessionEnded) == ClerkError.sessionEnded.localizedDescription)
    }

    @Test func anInstallWithASignInStaysFinishedAfterSigningOut() {
        let d = defaults()
        #expect(!FirstRun.showAtLaunch(defaults: d, anyServiceSignedIn: true))
        // Signed out of that service later: still not a first run.
        #expect(!FirstRun.showAtLaunch(defaults: d, anyServiceSignedIn: false))
        let fresh = defaults()
        #expect(FirstRun.showAtLaunch(defaults: fresh, anyServiceSignedIn: false))
        #expect(!fresh.bool(forKey: FirstRun.finishedKey), "showing the flow doesn't mark it finished")
    }
}
