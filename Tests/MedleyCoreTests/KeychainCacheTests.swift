import Foundation
import Security
import Testing
@testable import MedleyCore

/// The Mac app's Keychain path (`CachedKeychain`) against an in-memory stand-in for the Keychain service.
@Suite struct KeychainCacheTests {
    final class FakeService: KeychainTransport, @unchecked Sendable {
        var items: [String: Data]
        var readStatus: OSStatus = errSecSuccess
        /// Writes to these keys fail with errSecIO.
        var failing: Set<String> = []
        private(set) var reads: [String] = []
        private(set) var writes: [String] = []

        init(_ items: [String: Data] = [:]) {
            self.items = items
        }

        func get(_ key: String) -> Result<Data?, Keychain.Failure> {
            reads.append(key)
            return readStatus == errSecSuccess ? .success(items[key]) : .failure(Keychain.Failure(status: readStatus))
        }

        func set(_ data: Data?, for key: String) -> OSStatus {
            writes.append(key)
            if failing.contains(key) { return errSecIO }
            items[key] = data
            return errSecSuccess
        }
    }

    private func d(_ text: String) -> Data { Data(text.utf8) }

    @Test func aFailedWriteThrowsAndKeepsWhatIsReallySaved() throws {
        let service = FakeService(["spotify.token": d("old")])
        let keychain = CachedKeychain(transport: service)
        service.failing = ["spotify.token"]
        #expect(throws: Keychain.Failure(status: errSecIO)) { try keychain.set(d("new"), for: "spotify.token") }
        #expect(keychain.data(for: "spotify.token") == d("old"))
        #expect(throws: Keychain.Failure(status: errSecIO)) { try keychain.set(nil, for: "spotify.token") }
        #expect(keychain.data(for: "spotify.token") == d("old"))
    }

    @Test func aConfirmedWriteIsReadBack() throws {
        let service = FakeService()
        let keychain = CachedKeychain(transport: service)
        try keychain.set(d("v"), for: "ytm.credentials")
        #expect(keychain.data(for: "ytm.credentials") == d("v"))
        #expect(service.items["ytm.credentials"] == d("v"))
        try keychain.set(nil, for: "ytm.credentials")
        #expect(keychain.data(for: "ytm.credentials") == nil)
        #expect(service.items["ytm.credentials"] == nil)
    }

    @Test func eachAccountIsReadOnceAndAbsenceIsRemembered() {
        let service = FakeService(["ytm.account": d("a")])
        let keychain = CachedKeychain(transport: service)
        #expect(keychain.data(for: "ytm.account") == d("a"))
        #expect(keychain.data(for: "ytm.account") == d("a"))
        #expect(keychain.data(for: "spotify.token") == nil)
        #expect(keychain.data(for: "spotify.token") == nil)
        #expect(service.reads == ["ytm.account", "spotify.token"])
    }

    @Test func anUnreachableServiceReadsAsNothingAndIsAskedAgain() {
        let service = FakeService(["spotify.token": d("v")])
        service.readStatus = errSecNotAvailable
        let keychain = CachedKeychain(transport: service)
        #expect(keychain.data(for: "spotify.token") == nil)
        service.readStatus = errSecSuccess
        #expect(keychain.data(for: "spotify.token") == d("v"))
    }

    @Test func accountsOutsideTheAllowListNeverReachTheService() {
        let service = FakeService(["other.app.secret": d("v")])
        let keychain = CachedKeychain(transport: service)
        #expect(keychain.data(for: "other.app.secret") == nil)
        #expect(throws: Keychain.Failure(status: errSecMissingEntitlement)) { try keychain.set(d("x"), for: "other.app.secret") }
        // The prefix family needs a name after the prefix.
        #expect(throws: Keychain.Failure(status: errSecMissingEntitlement)) { try keychain.set(d("x"), for: "sync.credentials.state.") }
        #expect(service.reads.isEmpty)
        #expect(service.writes.isEmpty)
    }

    @Test func everyAccountTheAppUsesIsServed() {
        // The names the providers and the sync client save under (see their Keychain keys).
        for key in ["spotify.token", "spotify.account", "ytm.credentials", "ytm.account", "ytm.transfer",
                    "sync.credentials", "sync.credentials.installKey", "sync.credentials.state.signins.v2"] {
            #expect(Keychain.isServed(key), "\(key)")
        }
        #expect(!Keychain.isServed("medley.migrated-from-helper"))
    }

    @Test func theServiceListsTheSameAccountsAsTheApp() throws {
        // The service keeps its own copy (it is a separate, never-rebuilt binary); the two must agree.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/KeychainService/main.swift"), encoding: .utf8)
        let quoted = try Regex(#"let accounts: Set<String> = \[([^\]]*)\]"#)
        let match = try #require(source.firstMatch(of: quoted))
        let listed = Set(String(match.output[1].substring ?? "").split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }.filter { !$0.isEmpty })
        #expect(listed == Keychain.accounts)
        #expect(source.contains(#"let accountPrefixes = ["sync.credentials.state."]"#))
        #expect(Keychain.accountPrefixes == ["sync.credentials.state."])
    }
}
