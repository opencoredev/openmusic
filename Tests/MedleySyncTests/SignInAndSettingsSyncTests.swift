import Foundation
import MedleyCore
import Testing
@testable import MedleySync

/// A shared in-memory vault and settings table, standing in for the backend and its live queries.
@MainActor
final class FakeLibrary {
    var vault: [VaultEntry] = []
    var settings: [SettingEntry] = []
    var vaultPuts = 0
    var conflicts = 0
    var settingPuts = 0
    /// Runs before each setting write commits (a test can hold writes in flight with it).
    var settingGate: (@MainActor () async -> Void)?
    var devices: [FakeLibraryDevice] = []
    private var lastTime: ServerMillis = 1_000_000

    func tick() -> ServerMillis {
        lastTime = max(lastTime + 1, Date().timeIntervalSince1970 * 1000)
        return lastTime
    }

    func device(_ name: String, key: LibraryKey?) -> FakeLibraryDevice {
        let d = FakeLibraryDevice(library: self, id: DeviceID("dev-\(name)"), key: key)
        devices.append(d)
        return d
    }

    /// The live query pushing new results to every device.
    func push() {
        for d in devices {
            d.signIns.reconcileAll()
            d.settings.apply(settings)
        }
    }
}

@MainActor
final class FakeLibraryDevice: VaultEndpoint, SettingsEndpoint {
    var library: FakeLibrary
    let id: DeviceID
    var libraryKey: LibraryKey?
    var vaultWritesPaused = false
    var clock = ServerClock()
    var online = true
    /// When set, this device sees this vault instead of the library's (its live query is behind).
    var staleVault: [VaultEntry]?
    let store = MemoryCredentialStore()
    lazy var signIns = SignInSync(endpoint: self, store: store)
    lazy var settings = SettingsSync(endpoint: self)

    init(library: FakeLibrary, id: DeviceID, key: LibraryKey?) {
        self.library = library
        self.id = id
        libraryKey = key
    }

    var selfID: DeviceID? { id }
    var vaultEntries: [VaultEntry]? { staleVault ?? library.vault }
    var settingEntries: [SettingEntry]? { library.settings }

    func putVault(_ provider: ProviderID, sealed: String, keyId: String, baseRevision: Int) async throws -> VaultWrite {
        try write(provider, sealed: sealed, keyId: keyId, baseRevision: baseRevision)
    }

    func signOutVault(_ provider: ProviderID, baseRevision: Int) async throws -> VaultWrite {
        try write(provider, sealed: nil, keyId: libraryKey?.id ?? "", baseRevision: baseRevision)
    }

    /// Compare and swap on the revision, like `vault:put`.
    private func write(_ provider: ProviderID, sealed: String?, keyId: String, baseRevision: Int) throws -> VaultWrite {
        let current = library.vault.first { $0.provider == provider }?.revision ?? 0
        guard baseRevision == current else {
            library.conflicts += 1
            throw SyncConflict(revision: current)
        }
        let at = library.tick()
        library.vault.removeAll { $0.provider == provider }
        library.vault.append(VaultEntry(provider: provider, sealed: sealed, keyId: keyId, revision: current + 1, updatedAt: at, updatedBy: id))
        library.vaultPuts += 1
        library.push()
        return VaultWrite(updatedAt: at, revision: current + 1)
    }

    func putSetting(_ key: String, value: String, writeId: String, ifAbsent: Bool) async throws -> ServerMillis {
        if let gate = library.settingGate { await gate() }
        if ifAbsent, let existing = library.settings.first(where: { $0.key == key }) { return existing.updatedAt }
        let at = library.tick()
        library.settings.removeAll { $0.key == key }
        library.settings.append(SettingEntry(key: key, value: value, updatedAt: at, updatedBy: id, writeId: writeId))
        library.settingPuts += 1
        library.push()
        return at
    }
}

/// Behaves like an app's provider: importing or signing out changes its sign-in and reports the change.
@MainActor
final class FakeSignIn: SignInTransfer {
    let provider: ProviderID
    var data: Data?
    var imports: [String] = []
    var signOuts = 0
    /// Makes `importSignIn` throw, as a provider whose session can't be restored would.
    var failImports = false
    /// Makes `signOut` throw and keep the sign-in, as a provider whose Keychain refuses the deletion does.
    var refuseSignOuts = false
    var refusedSignOuts = 0
    var signInDidChange: (@MainActor () -> Void)?

    init(_ provider: ProviderID, _ text: String? = nil) {
        self.provider = provider
        data = text.map { Data($0.utf8) }
    }

    var text: String? { data.map { String(decoding: $0, as: UTF8.self) } }

    func exportSignIn() async -> Data? { data }

    func importSignIn(_ data: Data) async throws {
        if failImports {
            signInDidChange?()
            throw SyncError.signInTransferFailed("the provider rejected it")
        }
        self.data = data
        imports.append(String(decoding: data, as: UTF8.self))
        signInDidChange?()
    }

    func signOut() async throws {
        if refuseSignOuts {
            refusedSignOuts += 1
            throw KeychainRefused()
        }
        data = nil
        signOuts += 1
        signInDidChange?()
    }

    /// The user signed in (or the provider rotated its token) on this device.
    func localChange(_ text: String?) {
        data = text.map { Data($0.utf8) }
        signInDidChange?()
    }
}

struct KeychainRefused: LocalizedError {
    var errorDescription: String? { "The Keychain refused to delete the item." }
}

@MainActor
func settleAll(_ library: FakeLibrary) async {
    for _ in 0..<5 {
        for d in library.devices {
            await d.signIns.settle()
            await d.settings.settle()
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
@Suite(.serialized) struct SignInSyncTests {
    @Test func aSignInReachesTheOtherDeviceAndTheImportIsNotSentBack() async throws {
        let key = LibraryKey.generate()
        let library = FakeLibrary()
        let a = library.device("A", key: key)
        let b = library.device("B", key: key)
        let spotifyA = FakeSignIn(.spotify, "refresh-1")
        let spotifyB = FakeSignIn(.spotify)
        a.signIns.register(spotifyA)
        await settleAll(library)
        #expect(library.vaultPuts == 1)
        // The server only ever holds ciphertext.
        let stored = try #require(library.vault.first?.sealed)
        #expect(!stored.contains("refresh") && Data(base64Encoded: stored).map { !String(decoding: $0, as: UTF8.self).contains("refresh") } == true)

        b.signIns.register(spotifyB)
        await settleAll(library)
        #expect(spotifyB.text == "refresh-1")
        #expect(library.vaultPuts == 1, "B's import (and the change it reported) isn't uploaded again")
        #expect(b.signIns.lastImport?.provider == .spotify)
        guard case .synced = b.signIns.status[.spotify] else { Issue.record("B not synced: \(String(describing: b.signIns.status[.spotify]))"); return }

        // A rotates its refresh token; B follows.
        spotifyA.localChange("refresh-2")
        await settleAll(library)
        #expect(spotifyB.text == "refresh-2")
        #expect(spotifyB.imports == ["refresh-1", "refresh-2"])
        #expect(spotifyA.imports.isEmpty, "A never imports its own writes")
        #expect(library.vaultPuts == 2)

        // B rotates next; last write wins on both.
        spotifyB.localChange("refresh-3")
        await settleAll(library)
        #expect(spotifyA.text == "refresh-3")
        #expect(library.vaultPuts == 3)
    }

    @Test func olderEntriesAndOwnEchoesAreIgnored() async throws {
        let key = LibraryKey.generate()
        let library = FakeLibrary()
        let a = library.device("A", key: key)
        let b = library.device("B", key: key)
        let ytmB = FakeSignIn(.youtubeMusic)
        b.signIns.register(ytmB)
        let fresh = try SignInSealing.seal(Data("cookie-new".utf8), provider: .youtubeMusic, revision: 2, key: key)
        library.vault = [VaultEntry(provider: .youtubeMusic, sealed: fresh, keyId: key.id, revision: 2, updatedAt: library.tick(), updatedBy: a.id)]
        library.push()
        await settleAll(library)
        #expect(ytmB.text == "cookie-new")

        // A stale entry (a lower revision than what B applied) changes nothing.
        let stale = try SignInSealing.seal(Data("cookie-old".utf8), provider: .youtubeMusic, revision: 1, key: key)
        library.vault = [VaultEntry(provider: .youtubeMusic, sealed: stale, keyId: key.id, revision: 1, updatedAt: library.tick(), updatedBy: a.id)]
        library.push()
        await settleAll(library)
        #expect(ytmB.text == "cookie-new")

        // A newer entry that B itself wrote isn't imported.
        let own = try SignInSealing.seal(Data("cookie-mine".utf8), provider: .youtubeMusic, revision: 3, key: key)
        library.vault = [VaultEntry(provider: .youtubeMusic, sealed: own, keyId: key.id, revision: 3, updatedAt: library.tick(), updatedBy: b.id)]
        library.push()
        await settleAll(library)
        #expect(ytmB.imports == ["cookie-new"])
    }

    @Test func aWrongKeyNeverImportsAndNoKeyWaits() async throws {
        let library = FakeLibrary()
        let a = library.device("A", key: LibraryKey.generate())
        let wrong = library.device("W", key: LibraryKey.generate())
        let keyless = library.device("K", key: nil)
        a.signIns.register(FakeSignIn(.spotify, "refresh-1"))
        let w = FakeSignIn(.spotify)
        let k = FakeSignIn(.spotify)
        wrong.signIns.register(w)
        keyless.signIns.register(k)
        await settleAll(library)
        #expect(w.data == nil && k.data == nil)
        guard case .failed = wrong.signIns.status[.spotify] else { Issue.record("expected failed"); return }
        #expect(keyless.signIns.status[.spotify] == .needsKey)

        // The key arrives later (QR from Settings): it syncs.
        keyless.libraryKey = a.libraryKey
        keyless.signIns.reconcileAll()
        await settleAll(library)
        #expect(k.text == "refresh-1")
    }

    @Test func signOutEverywhereClearsEveryDeviceAndSignOutHereOnlyThisOne() async throws {
        let key = LibraryKey.generate()
        let library = FakeLibrary()
        let a = library.device("A", key: key)
        let b = library.device("B", key: key)
        let c = library.device("C", key: key)
        let sa = FakeSignIn(.spotify, "refresh-1"), sb = FakeSignIn(.spotify), sc = FakeSignIn(.spotify)
        a.signIns.register(sa); b.signIns.register(sb); c.signIns.register(sc)
        await settleAll(library)
        #expect(sb.text == "refresh-1" && sc.text == "refresh-1")

        // C signs out only here: it stays out when A rotates.
        try await c.signIns.signOut(.spotify, everywhere: false)
        sa.localChange("refresh-2")
        await settleAll(library)
        #expect(sc.data == nil)
        #expect(sb.text == "refresh-2")
        #expect(c.signIns.status[.spotify] == .signedOutHere)

        // A signs out everywhere: B is signed out too; the vault keeps only a tombstone.
        try await a.signIns.signOut(.spotify, everywhere: true)
        await settleAll(library)
        #expect(sa.data == nil && sb.data == nil)
        #expect(sb.signOuts == 1)
        #expect(library.vault.first?.sealed == nil)
        #expect(b.signIns.status[.spotify] == .signedOutEverywhere)
        #expect(b.signIns.lastImport?.signedOut == true)

        // Signing in again on C syncs to everyone.
        sc.localChange("refresh-9")
        await settleAll(library)
        #expect(sa.text == "refresh-9" && sb.text == "refresh-9")
    }

    @Test func anOldBlobReplayedAfterSignOutEverywhereIsNeverImported() async throws {
        let key = LibraryKey.generate()
        let library = FakeLibrary()
        let a = library.device("A", key: key)
        let b = library.device("B", key: key)
        let sa = FakeSignIn(.spotify, "refresh-1"), sb = FakeSignIn(.spotify)
        a.signIns.register(sa); b.signIns.register(sb)
        await settleAll(library)
        #expect(sb.text == "refresh-1")
        let old = try #require(library.vault.first)
        #expect(old.revision == 1)

        try await a.signIns.signOut(.spotify, everywhere: true)
        await settleAll(library)
        #expect(sb.data == nil && library.vault.first?.revision == 2)

        // The old blob is put back on top of the tombstone at a newer revision (a device or the server replays it).
        library.vault = [VaultEntry(provider: .spotify, sealed: old.sealed, keyId: key.id, revision: 3, updatedAt: library.tick(), updatedBy: a.id)]
        library.push()
        await settleAll(library)
        #expect(sa.data == nil && sb.data == nil, "the replayed sign-in isn't imported anywhere")
        #expect(sb.imports == ["refresh-1"])
        guard case .failed = b.signIns.status[.spotify] else { Issue.record("B: \(String(describing: b.signIns.status[.spotify]))"); return }

        // Signing in again replaces the unreadable entry, and the other device follows.
        sb.localChange("refresh-9")
        await settleAll(library)
        #expect(library.vault.first?.revision == 4)
        #expect(sa.text == "refresh-9")
    }

    @Test func aDeviceThatMissedSignOutEverywhereCantUndoIt() async throws {
        let key = LibraryKey.generate()
        let library = FakeLibrary()
        let a = library.device("A", key: key)
        let b = library.device("B", key: key)
        let sa = FakeSignIn(.spotify, "refresh-1"), sb = FakeSignIn(.spotify)
        a.signIns.register(sa); b.signIns.register(sb)
        await settleAll(library)
        #expect(sb.text == "refresh-1")

        // B's live query falls behind; A signs out everywhere; B then rotates its token from the stale view.
        b.staleVault = library.vault
        try await a.signIns.signOut(.spotify, everywhere: true)
        await settleAll(library)
        sb.localChange("refresh-2")
        await settleAll(library)
        #expect(library.conflicts == 1, "the server refused B's write from the old revision")
        #expect(library.vault.first?.sealed == nil)
        #expect(sa.data == nil)

        // B's query catches up: it signs out too.
        b.staleVault = nil
        library.push()
        await settleAll(library)
        #expect(sb.data == nil)
        #expect(b.signIns.status[.spotify] == .signedOutEverywhere)
        #expect(library.vault.first?.sealed == nil && library.vault.first?.revision == 2)
    }

    @Test func aFailedImportIsNotMarkedAppliedAndIsRetried() async throws {
        let key = LibraryKey.generate()
        let library = FakeLibrary()
        let a = library.device("A", key: key)
        let b = library.device("B", key: key)
        let sa = FakeSignIn(.spotify, "refresh-1")
        let sb = FakeSignIn(.spotify, "local-b")
        sb.failImports = true
        b.signIns.importRetryDelay = .milliseconds(150)
        a.signIns.register(sa)
        await settleAll(library)
        b.signIns.register(sb)
        await settleAll(library)
        guard case .failed = b.signIns.status[.spotify] else { Issue.record("B: \(String(describing: b.signIns.status[.spotify]))"); return }
        #expect(sb.text == "local-b")
        #expect(library.vaultPuts == 1, "B's own sign-in isn't uploaded over the one it failed to import")

        // The provider recovers; the next vault update retries the same entry.
        sb.failImports = false
        try await Task.sleep(for: .milliseconds(200))
        library.push()
        await settleAll(library)
        #expect(sb.text == "refresh-1")
        guard case .synced = b.signIns.status[.spotify] else { Issue.record("B: \(String(describing: b.signIns.status[.spotify]))"); return }
        #expect(library.vaultPuts == 1)
    }

    @Test func syncStateBelongsToOneLibrary() async throws {
        let key = LibraryKey.generate()
        let first = FakeLibrary()
        let a = first.device("A", key: key)
        let b = first.device("B", key: key)
        b.signIns.beginSession(scope: "deployment|library-1|dev-B")
        let sa = FakeSignIn(.spotify, "refresh-1"), sb = FakeSignIn(.spotify)
        a.signIns.register(sa); b.signIns.register(sb)
        await settleAll(first)
        for i in 2...3 { sa.localChange("refresh-\(i)"); await settleAll(first) }
        #expect(sb.text == "refresh-3")
        #expect(first.vault.map(\.revision) == [3])

        // B leaves and joins another library, whose sign-in is at revision 1.
        let second = FakeLibrary()
        let other = second.device("C", key: key)
        let sc = FakeSignIn(.spotify, "other-1")
        other.signIns.register(sc)
        await settleAll(second)
        first.devices.removeAll { $0 === b }
        b.library = second
        second.devices.append(b)
        b.signIns.beginSession(scope: "deployment|library-2|dev-B2")
        await settleAll(second)
        #expect(sb.text == "other-1", "revision 1 of the new library isn't mistaken for an old one")
        #expect(second.vaultPuts == 1)

        // Saved state is tied to its scope: a restart in the same scope keeps it, another scope drops it.
        let same = SignInSync(endpoint: b, store: b.store)
        same.beginSession(scope: "deployment|library-2|dev-B2")
        let kept = FakeSignIn(.spotify, "other-1")
        same.register(kept)
        await same.settle()
        #expect(kept.imports.isEmpty && second.vaultPuts == 1)
        let elsewhere = SignInSync(endpoint: b, store: b.store)
        elsewhere.beginSession(scope: "deployment|library-1|dev-B")
        let fresh = FakeSignIn(.spotify)
        elsewhere.register(fresh)
        await elsewhere.settle()
        #expect(fresh.imports == ["other-1"])
    }
}

@MainActor
@Suite(.serialized) struct SettingsSyncTests {
    func freshSettings() -> PlaybackSettings {
        PlaybackSettings(defaults: UserDefaults(suiteName: "medley-sync-test-\(UUID().uuidString)")!)
    }

    @Test func playbackSettingsSyncButVolumeStaysLocal() async throws {
        let library = FakeLibrary()
        let a = library.device("A", key: nil)
        let b = library.device("B", key: nil)
        let pa = freshSettings(), pb = freshSettings()
        pa.crossfadeSeconds = 3
        pa.autoplay = false
        a.settings.bind(pa)
        a.settings.apply(library.settings)  // first (empty) result: A's values go up
        await settleAll(library)
        #expect(library.settings.count == SettingsSync.PlaybackKey.allCases.count)

        b.settings.bind(pb)
        b.settings.apply(library.settings)  // B's first result: the library wins over B's defaults
        await settleAll(library)
        #expect(pb.crossfadeSeconds == 3)
        #expect(pb.autoplay == false)
        let putsAfterJoin = library.settingPuts

        pa.crossfadeSeconds = 7
        pa.normalizeVolume = false
        pa.volume = 0.1
        try await Task.sleep(for: .milliseconds(450))
        await settleAll(library)
        #expect(pb.crossfadeSeconds == 7)
        #expect(pb.normalizeVolume == false)
        #expect(pb.volume == 0.8, "volume is per device")
        #expect(library.settingPuts == putsAfterJoin + 2, "B applying them sends nothing back")
        #expect(b.settings.appliedCount >= 2)
    }

    @Test func recentSearchesAndLastWriteWins() async throws {
        let library = FakeLibrary()
        let a = library.device("A", key: nil)
        let b = library.device("B", key: nil)
        var seenOnB: [[String]] = []
        a.settings.observeRecentSearches(current: { ["daft punk"] }) { _ in }
        a.settings.apply(library.settings)
        b.settings.observeRecentSearches(current: { [] }) { seenOnB.append($0) }
        b.settings.apply(library.settings)
        await settleAll(library)
        #expect(b.settings.value(SettingsSync.recentSearchesKey, as: [String].self) == ["daft punk"])

        b.settings.set(SettingsSync.recentSearchesKey, ["justice", "daft punk"])
        try await Task.sleep(for: .milliseconds(450))
        await settleAll(library)
        #expect(a.settings.value(SettingsSync.recentSearchesKey, as: [String].self) == ["justice", "daft punk"])

        // An entry older than the one applied doesn't roll it back.
        library.settings = [SettingEntry(key: SettingsSync.recentSearchesKey, value: #"["old"]"#, updatedAt: 3, updatedBy: a.id)]
        b.settings.apply(library.settings)
        #expect(seenOnB.last != ["old"])
    }

    @Test func concurrentWritesOfOneKeyEndTheSameOnBothDevices() async throws {
        let library = FakeLibrary()
        let a = library.device("A", key: nil)
        let b = library.device("B", key: nil)
        var seenOnA: [String] = []
        a.settings.observe("k") { seenOnA.append($0) }
        b.settings.observe("k") { _ in }
        a.settings.apply(library.settings)
        b.settings.apply(library.settings)

        // A's write goes in flight and is held there.
        let held = HeldWrite()
        library.settingGate = { await held.hold() }
        a.settings.set("k", 1)
        #expect(await waitUntil { held.isHolding })
        library.settingGate = nil

        // B writes the same key and commits first; A sees it while its own write is still in flight.
        b.settings.set("k", 2)
        try await Task.sleep(for: .milliseconds(450))
        #expect(await waitUntil { library.settings.first?.value == "2" })
        // A's write commits last, so the server ends at 1.
        held.release()
        await settleAll(library)
        #expect(library.settings.first?.value == "1")
        #expect(a.settings.value("k", as: Int.self) == 1)
        #expect(b.settings.value("k", as: Int.self) == 1, "B adopts the committed value")
        #expect(!seenOnA.contains("2"), "A never flips to B's overwritten value")
    }

    @Test func aNewLibraryDropsPendingWritesAndCachedValues() async throws {
        let library = FakeLibrary()
        let a = library.device("A", key: nil)
        var seen: [String] = []
        a.settings.observe("k") { seen.append($0) }
        a.settings.apply([SettingEntry(key: "k", value: "5", updatedAt: library.tick(), updatedBy: DeviceID("x"))])
        a.settings.set("k", 6)
        a.settings.beginSession()
        try await Task.sleep(for: .milliseconds(450))
        await settleAll(library)
        #expect(library.settingPuts == 0, "the old library's pending write never goes out")

        // The new library's value wins even though its server time is lower than what was cached.
        a.settings.apply([SettingEntry(key: "k", value: "9", updatedAt: 3, updatedBy: DeviceID("y"))])
        #expect(seen.last == "9")
    }
}

/// Holds one write in flight until `release()`.
@MainActor
final class HeldWrite {
    private var continuation: CheckedContinuation<Void, Never>?
    private var used = false
    var isHolding: Bool { continuation != nil }

    func hold() async {
        guard !used else { return }
        used = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
