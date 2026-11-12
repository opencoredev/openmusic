import Foundation
import MedleyCore
import Testing
@testable import MedleySync

/// A sign-out the vault asks for only counts once the local sign-in is really gone. A provider whose Keychain
/// refuses the deletion stays signed in, so its sign-in must never be sealed back into the vault.
@MainActor
@Suite(.serialized) struct SignInDeletionFailureTests {
    /// A and B share a Spotify sign-in; B's transfer refuses deletion.
    private func pair() async -> (FakeLibrary, FakeLibraryDevice, FakeLibraryDevice, FakeSignIn, FakeSignIn) {
        let key = LibraryKey.generate()
        let library = FakeLibrary()
        let a = library.device("A", key: key)
        let b = library.device("B", key: key)
        let sa = FakeSignIn(.spotify, "refresh-1"), sb = FakeSignIn(.spotify)
        a.signIns.register(sa); b.signIns.register(sb)
        await settleAll(library)
        sb.refuseSignOuts = true
        return (library, a, b, sa, sb)
    }

    @Test func aTombstoneWhoseDeletionFailsStaysPendingAndNothingIsReuploaded() async throws {
        let (library, a, b, sa, sb) = await pair()
        #expect(sb.text == "refresh-1")
        b.signIns.signOutRetryDelay = .seconds(60)

        try await a.signIns.signOut(.spotify, everywhere: true)
        await settleAll(library)
        #expect(sa.data == nil && library.vault.first?.revision == 2 && library.vault.first?.sealed == nil)
        #expect(sb.refusedSignOuts == 1 && sb.text == "refresh-1", "B is still signed in")
        guard case .failed(let message) = b.signIns.status[.spotify], message.contains("couldn't be deleted") else {
            Issue.record("B: \(String(describing: b.signIns.status[.spotify]))"); return
        }
        #expect(b.signIns.savedState(.spotify).revision == 1, "the tombstone is not marked applied")
        #expect(b.signIns.lastImport?.signedOut == false, "no sign-out is reported as done")

        // Later reconciles (vault updates, a token rotation on B) never upload B's still-present sign-in.
        let puts = library.vaultPuts
        library.push()
        sb.data = Data("refresh-1-rotated".utf8)
        sb.signInDidChange?()
        await settleAll(library)
        #expect(library.vaultPuts == puts, "nothing is uploaded over the tombstone")
        #expect(library.vault.first?.sealed == nil && sa.data == nil, "A stays signed out")

        // Coming back to the foreground retries at once; the deletion goes through and the tombstone is applied.
        sb.refuseSignOuts = false
        b.signIns.retryNow()
        await settleAll(library)
        #expect(sb.data == nil && sb.signOuts == 1)
        #expect(b.signIns.status[.spotify] == .signedOutEverywhere)
        #expect(b.signIns.savedState(.spotify).revision == 2)
        #expect(b.signIns.lastImport?.signedOut == true)
        #expect(library.vaultPuts == puts && library.vault.first?.sealed == nil)
    }

    @Test func aFailedDeletionIsRetriedOnItsOwnAfterTheDelay() async throws {
        let (library, a, b, _, sb) = await pair()
        b.signIns.signOutRetryDelay = .milliseconds(100)
        try await a.signIns.signOut(.spotify, everywhere: true)
        await settleAll(library)
        #expect(sb.refusedSignOuts == 1 && sb.data != nil)

        // Still refusing: the timer tries again, nothing is uploaded.
        #expect(await waitUntil { sb.refusedSignOuts >= 2 })
        sb.refuseSignOuts = false
        #expect(await waitUntil { sb.data == nil })
        await settleAll(library)
        #expect(b.signIns.status[.spotify] == .signedOutEverywhere)
        #expect(library.vault.first?.revision == 2 && library.vault.first?.sealed == nil)
    }

    @Test func aPendingSignOutSurvivesARestart() async throws {
        let (library, a, b, _, sb) = await pair()
        b.signIns.signOutRetryDelay = .seconds(60)
        try await a.signIns.signOut(.spotify, everywhere: true)
        await settleAll(library)
        #expect(sb.refusedSignOuts == 1 && sb.data != nil)

        // The app relaunches (a new SignInSync over the same saved state) and its provider restores the sign-in.
        let relaunched = SignInSync(endpoint: b, store: b.store)
        let restored = FakeSignIn(.spotify, "refresh-1")
        let puts = library.vaultPuts
        relaunched.register(restored)
        await relaunched.settle()
        #expect(restored.signOuts == 1 && restored.data == nil, "the pending sign-out runs at launch")
        #expect(library.vaultPuts == puts && library.vault.first?.sealed == nil)
        #expect(relaunched.status[.spotify] == .signedOutEverywhere)
    }

    @Test func anUnreadableEntryWhoseDeletionFailsStaysPendingAndNothingIsReuploaded() async throws {
        let (library, a, b, sa, sb) = await pair()
        b.signIns.signOutRetryDelay = .seconds(60)
        let old = try #require(library.vault.first)

        // B misses the tombstone; revision 3 replays the revision-1 blob.
        b.staleVault = library.vault
        try await a.signIns.signOut(.spotify, everywhere: true)
        await settleAll(library)
        library.vault = [VaultEntry(provider: .spotify, sealed: old.sealed, keyId: old.keyId, revision: 3, updatedAt: library.tick(), updatedBy: a.id)]
        b.staleVault = nil
        let puts = library.vaultPuts
        library.push()
        await settleAll(library)
        #expect(sb.refusedSignOuts == 1 && sb.text == "refresh-1")
        guard case .failed(let message) = b.signIns.status[.spotify], message.contains("couldn't be deleted") else {
            Issue.record("B: \(String(describing: b.signIns.status[.spotify]))"); return
        }
        #expect(b.signIns.savedState(.spotify).unreadableRevision == nil && b.signIns.savedState(.spotify).revision == 1)
        sb.signInDidChange?()
        library.push()
        await settleAll(library)
        #expect(library.vaultPuts == puts && library.vault.first?.revision == 3)
        #expect(sa.data == nil)

        sb.refuseSignOuts = false
        b.signIns.retryNow()
        await settleAll(library)
        #expect(sb.data == nil)
        #expect(b.signIns.status[.spotify] == .failed(SignInSync.unreadableMessage))
        #expect(b.signIns.savedState(.spotify).revision == 3 && library.vaultPuts == puts)
    }

    @Test func signingOutLocallyThrowsAndChangesNothingWhenDeletionFails() async throws {
        let (library, _, b, sa, sb) = await pair()
        await #expect(throws: KeychainRefused.self) { try await b.signIns.signOut(.spotify, everywhere: true) }
        await #expect(throws: KeychainRefused.self) { try await b.signIns.signOut(.spotify, everywhere: false) }
        await settleAll(library)
        #expect(library.vault.first?.revision == 1 && library.vault.first?.sealed != nil, "no tombstone for other devices")
        #expect(sa.text == "refresh-1" && sb.text == "refresh-1")
        #expect(!b.signIns.savedState(.spotify).signedOutHere)
        guard case .synced = b.signIns.status[.spotify] else { Issue.record("B: \(String(describing: b.signIns.status[.spotify]))"); return }
    }
}
