import Foundation
import MedleyCore
import Testing
@testable import MedleySync

/// A provider whose next import is held until the test releases it (a slow session restore).
@MainActor
final class GatedSignIn: SignInTransfer {
    let provider: ProviderID
    var data: Data?
    var imports: [String] = []
    var holdNextImport = false
    private var release: CheckedContinuation<Void, Never>?
    var signInDidChange: (@MainActor () -> Void)?

    init(_ provider: ProviderID, _ text: String? = nil) {
        self.provider = provider
        data = text.map { Data($0.utf8) }
    }

    var text: String? { data.map { String(decoding: $0, as: UTF8.self) } }
    var isHolding: Bool { release != nil }

    func exportSignIn() async -> Data? { data }

    func importSignIn(_ data: Data) async throws {
        if holdNextImport {
            holdNextImport = false
            await withCheckedContinuation { release = $0 }
        }
        self.data = data
        imports.append(String(decoding: data, as: UTF8.self))
        signInDidChange?()
    }

    func signOut() async {
        data = nil
        signInDidChange?()
    }

    func localChange(_ text: String?) {
        data = text.map { Data($0.utf8) }
        signInDidChange?()
    }

    func releaseImport() {
        release?.resume()
        release = nil
    }
}

@MainActor
@Suite(.serialized) struct SignInRevocationTests {
    @Test func aDeviceThatMissedSignOutEverywhereSignsOutOnAReplayedBlobAndUploadsNothing() async throws {
        let key = LibraryKey.generate()
        let library = FakeLibrary()
        let a = library.device("A", key: key)
        let b = library.device("B", key: key)
        let sa = FakeSignIn(.spotify, "refresh-1"), sb = FakeSignIn(.spotify)
        a.signIns.register(sa); b.signIns.register(sb)
        await settleAll(library)
        #expect(sb.text == "refresh-1")
        let old = try #require(library.vault.first)

        // B is offline and misses the tombstone at revision 2; meanwhile its provider rotated the token.
        b.staleVault = library.vault
        try await a.signIns.signOut(.spotify, everywhere: true)
        await settleAll(library)
        #expect(library.vault.first?.revision == 2)
        sb.data = Data("refresh-1-rotated".utf8)

        // Revision 3 replays the revision-1 blob. B comes back and sees only that.
        library.vault = [VaultEntry(provider: .spotify, sealed: old.sealed, keyId: key.id, revision: 3, updatedAt: library.tick(), updatedBy: a.id)]
        b.staleVault = nil
        let putsBefore = library.vaultPuts
        library.push()
        await settleAll(library)
        #expect(library.vaultPuts == putsBefore, "nothing local is uploaded over the unreadable entry")
        #expect(library.vault.first?.revision == 3)
        #expect(sb.data == nil && sa.data == nil, "the revocation holds on B too")
        #expect(b.signIns.status[.spotify] == .failed(SignInSync.unreadableMessage))

        // Only a fresh sign-in on B replaces the entry, and A follows.
        sb.localChange("refresh-new")
        await settleAll(library)
        #expect(library.vault.first?.revision == 4)
        #expect(sa.text == "refresh-new")
    }

    @Test func aKeylessDeviceHonorsSignOutEverywhere() async throws {
        let key = LibraryKey.generate()
        let library = FakeLibrary()
        let a = library.device("A", key: key)
        let keyless = library.device("K", key: nil)
        let sa = FakeSignIn(.spotify, "refresh-1")
        let sk = FakeSignIn(.spotify, "signed-in-by-hand")
        a.signIns.register(sa); keyless.signIns.register(sk)
        await settleAll(library)
        #expect(sk.text == "signed-in-by-hand" && keyless.signIns.status[.spotify] == .needsKey)

        try await a.signIns.signOut(.spotify, everywhere: true)
        await settleAll(library)
        #expect(sk.data == nil && sk.signOuts == 1)
        #expect(keyless.signIns.lastImport?.signedOut == true)
        // Only once: later results don't sign it out again.
        sk.localChange("signed-in-again")
        library.push()
        await settleAll(library)
        #expect(sk.text == "signed-in-again" && sk.signOuts == 1)
        #expect(library.vault.first?.sealed == nil, "a keyless device never writes")
    }

    @Test func anImportForTheOldLibraryFinishesBeforeTheNewLibrarysSyncWhichWins() async throws {
        let key = LibraryKey.generate()
        let first = FakeLibrary()
        let a = first.device("A", key: key)
        let b = first.device("B", key: key)
        b.signIns.beginSession(scope: "d|library-1|B")
        a.signIns.register(FakeSignIn(.spotify, "from-library-1"))
        await settleAll(first)
        let sb = GatedSignIn(.spotify)
        sb.holdNextImport = true
        b.signIns.register(sb)
        #expect(await waitUntil { sb.isHolding })

        // B joins library 2 (which has its own sign-in) while library 1's import is still running.
        let second = FakeLibrary()
        let c = second.device("C", key: key)
        c.signIns.register(FakeSignIn(.spotify, "from-library-2"))
        await settleAll(second)
        first.devices.removeAll { $0 === b }
        b.library = second
        second.devices.append(b)
        b.signIns.beginSession(scope: "d|library-2|B")
        second.push()
        sb.releaseImport()
        await settleAll(second)
        #expect(sb.text == "from-library-2")
        #expect(sb.imports == ["from-library-1", "from-library-2"], "library 2's import ran after library 1's finished")
        #expect(second.vaultPuts == 1, "library 1's sign-in never reached library 2")
        guard case .synced = b.signIns.status[.spotify] else { Issue.record("B: \(String(describing: b.signIns.status[.spotify]))"); return }
    }

    @Test func aSignInAnOldLibrarysImportInstalledIsNeverUploadedToTheNewLibrary() async throws {
        let key = LibraryKey.generate()
        let first = FakeLibrary()
        let a = first.device("A", key: key)
        let b = first.device("B", key: key)
        b.signIns.beginSession(scope: "d|library-1|B")
        a.signIns.register(FakeSignIn(.spotify, "from-library-1"))
        await settleAll(first)
        let sb = GatedSignIn(.spotify)
        sb.holdNextImport = true
        b.signIns.register(sb)
        #expect(await waitUntil { sb.isHolding })

        // Library 2 has no sign-in yet.
        let second = FakeLibrary()
        first.devices.removeAll { $0 === b }
        b.library = second
        second.devices.append(b)
        b.signIns.beginSession(scope: "d|library-2|B")
        sb.releaseImport()
        await settleAll(second)
        // A token refresh of that sign-in isn't uploaded either.
        sb.localChange("from-library-1-refreshed")
        await settleAll(second)
        #expect(second.vaultPuts == 0)
        #expect(b.signIns.status[.spotify] == .failed(SignInSync.foreignMessage))

        // Signing out and in again here shares the new sign-in.
        sb.localChange(nil)
        await settleAll(second)
        sb.localChange("signed-in-on-B")
        await settleAll(second)
        #expect(second.vaultPuts == 1)
    }

    @Test func aLegacyEntryIsImportedAndMigratedOnce() async throws {
        let key = LibraryKey.generate()
        let library = FakeLibrary()
        let old = DeviceID("dev-old-client")
        let legacy = try SignInSealing.sealLegacy(Data("legacy-cookie".utf8), provider: .youtubeMusic, key: key)
        library.vault = [VaultEntry(provider: .youtubeMusic, sealed: legacy, keyId: key.id, revision: 0, updatedAt: library.tick(), updatedBy: old)]
        let b = library.device("B", key: key)
        let c = library.device("C", key: key)
        let yb = FakeSignIn(.youtubeMusic), yc = FakeSignIn(.youtubeMusic)
        b.signIns.register(yb)
        c.signIns.register(yc)
        await settleAll(library)
        #expect(yb.text == "legacy-cookie" && yc.text == "legacy-cookie")
        #expect(library.vaultPuts == 1, "one device migrated; the other lost the compare and swap")
        let migrated = try #require(library.vault.first)
        #expect(migrated.revision == 1)
        let sealed = try #require(migrated.sealed)
        #expect(try SignInSealing.open(sealed, provider: .youtubeMusic, revision: 1, key: key) == Data("legacy-cookie".utf8))

        // A new device joining later reads the migrated entry; nothing writes again.
        let d = library.device("D", key: key)
        let yd = FakeSignIn(.youtubeMusic)
        d.signIns.register(yd)
        await settleAll(library)
        #expect(yd.text == "legacy-cookie" && library.vaultPuts == 1)
        guard case .synced = d.signIns.status[.youtubeMusic] else { Issue.record("D: \(String(describing: d.signIns.status[.youtubeMusic]))"); return }
    }

    @Test func legacyCiphertextIsNeverAcceptedAtALaterRevision() async throws {
        let key = LibraryKey.generate()
        let library = FakeLibrary()
        let a = library.device("A", key: key)
        let ya = FakeSignIn(.youtubeMusic, "current-cookie")
        a.signIns.register(ya)
        await settleAll(library)
        #expect(library.vault.first?.revision == 1)
        let legacy = try SignInSealing.sealLegacy(Data("legacy-cookie".utf8), provider: .youtubeMusic, key: key)
        library.vault = [VaultEntry(provider: .youtubeMusic, sealed: legacy, keyId: key.id, revision: 2, updatedAt: library.tick(), updatedBy: DeviceID("x"))]
        let b = library.device("B", key: key)
        let yb = FakeSignIn(.youtubeMusic)
        b.signIns.register(yb)
        library.push()
        await settleAll(library)
        #expect(yb.imports.isEmpty && ya.imports.isEmpty)
        #expect(library.vault.first?.revision == 2, "nobody re-uploads over it automatically")
    }

    /// The account lost its vault key (its last holder left) while a waiting device had applied a sign-out at
    /// revision 5. The server keeps counting (sealed rows become cleared one revision on, the sign-out stays), so the
    /// waiting device, after claiming a new key, writes on top of what is stored instead of conflicting forever, and
    /// a sign-in the account lost is uploaded again from the device that still has it.
    @Test func afterTheKeyIsLostRevisionsKeepCountingAndAFreshSignInSyncs() async throws {
        let library = FakeLibrary()
        let key = LibraryKey.generate()
        let a = library.device("mac", key: key)
        let w = library.device("phone", key: nil)
        let aSpotify = FakeSignIn(.spotify, "mac spotify 1")
        let aYouTube = FakeSignIn(.youtubeMusic, "mac ytm")
        let wSpotify = FakeSignIn(.spotify, "phone spotify")
        let wYouTube = FakeSignIn(.youtubeMusic, "phone ytm")
        a.signIns.register(aSpotify)
        a.signIns.register(aYouTube)
        w.signIns.register(wSpotify)
        w.signIns.register(wYouTube)
        await settleAll(library)
        for n in 2...4 {
            aSpotify.localChange("mac spotify \(n)")
            await settleAll(library)
        }
        try await a.signIns.signOut(.spotify, everywhere: true)
        await settleAll(library)
        #expect(library.vault.first { $0.provider == .spotify }?.revision == 5)
        // The waiting phone honored the sign-out without the key.
        #expect(w.signIns.savedState(.spotify).revision == 5 && wSpotify.data == nil)
        #expect(library.vault.first { $0.provider == .youtubeMusic }?.revision == 1)

        // The Mac leaves; nobody can open the vault. The server clears the sealed row a revision on.
        library.devices.removeAll { $0 === a }
        library.vault = library.vault.map { row in
            guard row.sealed != nil else { return row }
            var cleared = row
            cleared.sealed = nil
            cleared.cleared = true
            cleared.keyId = String(repeating: "0", count: 32)
            cleared.revision += 1
            return cleared
        }
        let fresh = LibraryKey.generate()
        w.libraryKey = fresh
        library.push()
        await settleAll(library)
        // Cleared isn't a sign-out: the phone keeps its own YouTube Music sign-in, and shares it under the new key.
        #expect(wYouTube.data != nil && wYouTube.signOuts == 0)
        let ytm = try #require(library.vault.first { $0.provider == .youtubeMusic })
        #expect(ytm.revision == 3 && !ytm.cleared && ytm.updatedBy == w.id)
        #expect(try SignInSealing.open(try #require(ytm.sealed), provider: .youtubeMusic, revision: 3, key: fresh) == Data("phone ytm".utf8))

        // A fresh Spotify sign-in on the phone goes up at revision 6, with no conflict loop.
        let conflicts = library.conflicts
        wSpotify.localChange("phone spotify, fresh")
        await settleAll(library)
        let spotify = try #require(library.vault.first { $0.provider == .spotify })
        #expect(spotify.revision == 6 && spotify.updatedBy == w.id)
        #expect(library.conflicts == conflicts)
        #expect(w.signIns.status[.spotify] == .synced(spotify.updatedAt))

        // A device joining later with the new key imports both.
        let b = library.device("ipad", key: fresh)
        let bSpotify = FakeSignIn(.spotify)
        b.signIns.register(bSpotify)
        await settleAll(library)
        #expect(bSpotify.text == "phone spotify, fresh")
    }

    @Test func savedStateFromBeforeTheNewFieldsStillLoads() throws {
        let old = #"{"revision":4,"appliedAt":12,"digest":"ab","signedOutHere":false}"#
        let state = try JSONDecoder().decode(SignInSync.ProviderState.self, from: Data(old.utf8))
        #expect(state.revision == 4 && state.appliedAt == 12 && state.digest == "ab")
        #expect(state.unreadableRevision == nil && !state.holdsForeignSignIn)
    }
}
