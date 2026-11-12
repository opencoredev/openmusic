import CryptoKit
import Foundation
import MedleyCore
import Observation

// MARK: - The app's side

/// One provider's sign-in, as the app stores it. The apps implement it (YouTube Music: cookie and selected
/// channel; Spotify: refresh token). MedleySync seals what `exportSignIn()` returns with the library key and
/// never looks inside.
@MainActor
public protocol SignInTransfer: AnyObject {
    var provider: ProviderID { get }
    /// The current sign-in, or nil when signed out.
    func exportSignIn() async -> Data?
    /// Replaces this device's sign-in with one from another device.
    func importSignIn(_ data: Data) async throws
    /// Signs this device out (another device chose "sign out everywhere", or `SignInSync.signOut` was called).
    /// Throws when the saved sign-in couldn't be deleted (the Keychain refused): the device is then still signed in,
    /// and `SignInSync` keeps the sign-out pending and tries again instead of treating it as done.
    func signOut() async throws
    /// Set by `SignInSync.register`. Call it whenever the local sign-in changes: after signing in, after a
    /// token refresh that rotated the stored secret, after signing out.
    var signInDidChange: (@MainActor () -> Void)? { get set }
}

// MARK: - Wire shapes

/// A provider's row in the vault (`vault:list`).
public struct VaultEntry: Codable, Sendable, Hashable {
    public var provider: ProviderID
    /// Base64 AES-GCM ciphertext; nil after "sign out everywhere", or when `cleared`.
    public var sealed: String?
    /// The account lost its vault key and this sign-in with it (nobody who could open it was left). Not a sign-out:
    /// devices keep their own sign-in and upload it again, at the next revision.
    public var cleared: Bool = false
    public var keyId: String
    /// Counts every write of this row, sign-outs included (0 for rows from before revisions). The ciphertext is
    /// sealed for exactly this revision.
    public var revision: Int = 0
    public var updatedAt: ServerMillis
    public var updatedBy: DeviceID
}

extension VaultEntry {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(ProviderID.self, forKey: .provider)
        sealed = try c.decodeIfPresent(String.self, forKey: .sealed)
        cleared = try c.decodeIfPresent(Bool.self, forKey: .cleared) ?? false
        keyId = try c.decode(String.self, forKey: .keyId)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        updatedAt = try c.decode(ServerMillis.self, forKey: .updatedAt)
        updatedBy = try c.decode(DeviceID.self, forKey: .updatedBy)
    }
}

/// A vault write the server accepted.
public struct VaultWrite: Sendable, Equatable {
    public var updatedAt: ServerMillis
    public var revision: Int

    public init(updatedAt: ServerMillis, revision: Int) {
        self.updatedAt = updatedAt
        self.revision = revision
    }
}

/// The server refused a write based on an older revision than the stored one (`ConvexError` code `conflict`).
public struct SyncConflict: Error, Sendable, Equatable {
    /// The stored revision, when the server said.
    public var revision: Int?

    public init(revision: Int?) { self.revision = revision }
}

/// What `SignInSync` needs from the service. `SyncService` is the real one.
@MainActor
public protocol VaultEndpoint: AnyObject {
    var selfID: DeviceID? { get }
    var libraryKey: LibraryKey? { get }
    /// Nothing may be written while true: the device can't be sure its key is the account's current one (not
    /// confirmed yet, a mismatch, or the key is being replaced). Reading and honoring sign-outs go on.
    var vaultWritesPaused: Bool { get }
    /// nil until the first `vault:list` result arrived.
    var vaultEntries: [VaultEntry]? { get }
    var clock: ServerClock { get }
    /// Writes `sealed` (sealed for `baseRevision + 1`) if the stored revision is still `baseRevision`; throws
    /// `SyncConflict` otherwise.
    func putVault(_ provider: ProviderID, sealed: String, keyId: String, baseRevision: Int) async throws -> VaultWrite
    /// Leaves a "sign out everywhere" tombstone at `baseRevision + 1`; throws `SyncConflict` like `putVault`.
    func signOutVault(_ provider: ProviderID, baseRevision: Int) async throws -> VaultWrite
}

// MARK: - Sign-in sync

/// Keeps provider sign-ins the same on every device of the library, end to end encrypted.
///
/// - A local change (`signInDidChange`) is exported, sealed with the library key for the next vault revision and
///   written with compare-and-swap on the revision this device last saw, unless it is what was last synced.
/// - A vault entry with a higher revision than the last one applied here is opened (for exactly its revision) and
///   imported. The revision is committed only after the import succeeded. Entries this device wrote, and blobs
///   equal to what is already here, are not imported again.
/// - A "sign out everywhere" tombstone newer than what was applied signs this device out, whether or not it holds
///   the library key.
/// - An entry that doesn't open at its revision (an old blob replayed on top of a sign-out, or corrupt data) is
///   never imported, and nothing local is uploaded over it automatically: it may stand where a sign-out this device
///   missed used to be, so the device signs out of that provider. Only a fresh sign-in here replaces the entry.
/// - Entries from before revisions (revision 0, sealed with the v1 format) are opened only at revision 0, imported,
///   and migrated once: re-sealed in the current format at revision 1 with compare-and-swap.
/// - A sign-out the vault asks for (a tombstone, or an unreadable entry) counts as applied only once the transfer
///   deleted the local sign-in. If deletion throws, the revision stays unapplied: nothing local is uploaded for that
///   provider, and the deletion is tried again on the next reconcile after `signOutRetryDelay` (a timer schedules
///   one), and at once when the app returns to the foreground (`retryNow`).
/// - `signOut(_:everywhere:)` signs out here; `everywhere` also leaves a tombstone that signs out every device.
///   Signing out only here stops this device from importing that provider until it signs in again. If the local
///   deletion fails it throws and changes nothing, so no other device is signed out while this one stays signed in.
/// - State is kept per deployment, library and device (`beginSession`); joining another library starts over. Work
///   stays serialized across the switch: the new library's sync waits for an import still running for the old one,
///   and a sign-in such an import installs is never uploaded to the new library.
@MainActor
@Observable
public final class SignInSync {
    public enum Status: Sendable, Equatable {
        /// No transfer registered for this provider.
        case unavailable
        /// This device lacks the vault key: a device that has it must allow this one (`SyncService.keyRequests`).
        case needsKey
        case waiting
        /// Not signed in here and nothing in the vault.
        case notSignedIn
        /// Local and vault agree as of this server time.
        case synced(ServerMillis)
        /// Signed out here only; vault updates for this provider are ignored until signing in again.
        case signedOutHere
        case signedOutEverywhere
        case failed(String)
    }

    /// One import, for diagnostics: when the entry was written and how long it took to arrive and import.
    public struct Import: Sendable, Equatable {
        public var provider: ProviderID
        public var updatedAt: ServerMillis
        public var latencyMs: Double
        public var signedOut: Bool
        /// Size of the imported sign-in in bytes (0 for a sign-out). Never the sign-in itself.
        public var bytes: Int = 0
    }

    public private(set) var status: [ProviderID: Status] = [:]
    public private(set) var lastImport: Import?
    @ObservationIgnored public var onImport: (@MainActor (Import) -> Void)?

    @ObservationIgnored weak var endpoint: (any VaultEndpoint)?
    @ObservationIgnored private let store: any SyncCredentialStore
    @ObservationIgnored private var transfers: [ProviderID: any SignInTransfer] = [:]
    @ObservationIgnored private var state: [ProviderID: ProviderState]
    @ObservationIgnored private var tail: Task<Void, Never>?
    /// Which deployment, library and device `state` belongs to.
    @ObservationIgnored private var scope: String?
    /// Bumped by `beginSession`; work started in an earlier session drops its results.
    @ObservationIgnored private var session = 0
    /// Digest of a sign-in being imported right now: the change the import reports is not uploaded.
    @ObservationIgnored private var importing: [ProviderID: String] = [:]
    /// An import that threw, so the same revision isn't retried in a tight loop.
    @ObservationIgnored private var failedImports: [ProviderID: (revision: Int, retryAt: ContinuousClock.Instant)] = [:]

    /// A vault sign-out whose local deletion threw: not tried again before `retryAt` (a timer reconciles then).
    @ObservationIgnored private var failedSignOuts: [ProviderID: (retryAt: ContinuousClock.Instant, message: String)] = [:]
    @ObservationIgnored private var signOutRetries: [ProviderID: Task<Void, Never>] = [:]

    /// How long an import that threw waits before the same revision is tried again.
    @ObservationIgnored var importRetryDelay: Duration = .seconds(30)
    /// How long a sign-out whose local deletion threw waits before it is tried again.
    @ObservationIgnored var signOutRetryDelay: Duration = .seconds(30)

    struct ProviderState: Codable, Equatable {
        /// Vault revision this device last wrote or applied.
        var revision = 0
        /// updatedAt of that entry, for `Status.synced`.
        var appliedAt: ServerMillis = 0
        /// SHA-256 (hex) of the sign-in last synced, so an unchanged export isn't uploaded again.
        var digest: String?
        var signedOutHere = false
        /// The revision of an entry that didn't open (this device signed out because of it), for `Status.failed`.
        var unreadableRevision: Int?
        /// The provider holds a sign-in that an import for a previous library installed after this library's session
        /// began. It is never uploaded here; signing out, or importing this library's sign-in, clears it.
        var holdsForeignSignIn = false

        init() {}

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
            appliedAt = try c.decodeIfPresent(ServerMillis.self, forKey: .appliedAt) ?? 0
            digest = try c.decodeIfPresent(String.self, forKey: .digest)
            signedOutHere = try c.decodeIfPresent(Bool.self, forKey: .signedOutHere) ?? false
            unreadableRevision = try c.decodeIfPresent(Int.self, forKey: .unreadableRevision)
            holdsForeignSignIn = try c.decodeIfPresent(Bool.self, forKey: .holdsForeignSignIn) ?? false
        }
    }

    private struct Saved: Codable {
        var scope: String?
        var providers: [ProviderID: ProviderState]
    }

    static let stateName = "signins.v2"

    public convenience init(endpoint: any VaultEndpoint, store: any SyncCredentialStore) {
        self.init(store: store)
        self.endpoint = endpoint
    }

    init(store: any SyncCredentialStore) {
        self.store = store
        let saved = store.state(Self.stateName).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        scope = saved?.scope
        state = saved?.providers ?? [:]
        // The format before scopes and revisions can't be trusted for any library.
        if store.state("signins") != nil { store.setState("signins", nil) }
    }

    /// Starts over when this device's registration changed (another account, deployment or device id; nil when signed out):
    /// forgets what was applied and makes work already running or queued discard its results. The queue itself is
    /// kept, so the new session's work runs only after an import still running for the old one has finished.
    func beginSession(scope newScope: String?) {
        guard newScope != scope else { return }
        scope = newScope
        session += 1
        state = [:]
        importing = [:]
        failedImports = [:]
        failedSignOuts = [:]
        for retry in signOutRetries.values { retry.cancel() }
        signOutRetries = [:]
        lastImport = nil
        status = status.mapValues { _ in .waiting }
        persist()
        if newScope != nil { reconcileAll() }
    }

    /// Starts syncing one provider. Call once per provider at launch, after the provider restored its session.
    public func register(_ transfer: any SignInTransfer) {
        let provider = transfer.provider
        transfers[provider] = transfer
        transfer.signInDidChange = { [weak self] in self?.reconcile(provider) }
        reconcile(provider)
    }

    /// Signs out of `provider` here, and with `everywhere` on every device of the library. Throws the transfer's
    /// error, with nothing recorded and no tombstone written, when the local sign-in couldn't be deleted.
    public func signOut(_ provider: ProviderID, everywhere: Bool) async throws {
        try await serial { [self] in
            guard let transfer = transfers[provider] else { return }
            let session = self.session
            try await transfer.signOut()
            guard session == self.session else { return }
            var s = state[provider] ?? ProviderState()
            s.digest = nil
            s.holdsForeignSignIn = false
            if everywhere {
                guard let endpoint else { throw SyncError.notPaired }
                let stored = endpoint.vaultEntries?.first { $0.provider == provider }?.revision ?? 0
                var base = max(s.revision, stored)
                let write: VaultWrite
                do {
                    write = try await endpoint.signOutVault(provider, baseRevision: base)
                } catch let conflict as SyncConflict {
                    // Another device wrote first: sign out on top of what is there now. The user asked for it.
                    base = conflict.revision ?? (base + 1)
                    write = try await endpoint.signOutVault(provider, baseRevision: base)
                }
                guard session == self.session else { return }
                s.revision = max(s.revision, write.revision)
                s.appliedAt = write.updatedAt
                s.signedOutHere = false
                status[provider] = .signedOutEverywhere
            } else {
                s.signedOutHere = true
                status[provider] = .signedOutHere
            }
            save(provider, s)
        }
    }

    /// Re-runs the sync for every registered provider (the service calls it when vault entries or the key change).
    public func reconcileAll() {
        for provider in transfers.keys { reconcile(provider) }
    }

    /// Retries pending sign-outs now instead of after `signOutRetryDelay` (the app came back to the foreground).
    public func retryNow() {
        guard !failedSignOuts.isEmpty else { return }
        failedSignOuts = [:]
        reconcileAll()
    }

    func reconcile(_ provider: ProviderID) {
        let previous = tail
        tail = Task { [weak self] in
            await previous?.value
            await self?.sync(provider)
        }
    }

    /// What this device recorded for `provider` (tests).
    func savedState(_ provider: ProviderID) -> ProviderState { state[provider] ?? ProviderState() }

    /// Waits for queued work (tests).
    func settle() async {
        while let current = tail {
            await current.value
            if current == tail { return }
        }
    }

    private func serial(_ work: @escaping @MainActor () async throws -> Void) async throws {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            try await work()
        }
        tail = Task { _ = try? await task.value }
        try await task.value
    }

    static let unreadableMessage = "A sign-in in the library couldn't be opened, so this device signed out of it. Sign in again here to replace it."
    static let foreignMessage = "This sign-in came from the library this device left, so it isn't shared here. Sign in again to share one."

    private func sync(_ provider: ProviderID) async {
        let session = self.session
        guard let transfer = transfers[provider] else { status[provider] = .unavailable; return }
        guard let endpoint, let me = endpoint.selfID else { status[provider] = .waiting; return }
        guard let entries = endpoint.vaultEntries else { status[provider] = .waiting; return }
        var s = state[provider] ?? ProviderState()
        let entry = entries.first { $0.provider == provider }

        // The account lost its key: nothing to import and nothing to sign out of. Note the revision (so nothing older
        // ever applies) and forget what was synced, so this device's own sign-in is uploaded again under the new key.
        if let entry, entry.cleared, entry.revision > s.revision {
            s.revision = entry.revision
            s.appliedAt = entry.updatedAt
            s.digest = nil
            s.unreadableRevision = nil
            save(provider, s)
        }

        // Sign out everywhere: honored with or without the library key (a tombstone has nothing to open).
        if let entry, entry.sealed == nil, !entry.cleared, entry.revision > s.revision {
            let latency = endpoint.clock.now() - entry.updatedAt
            if !s.signedOutHere {
                guard await deleteSignIn(provider, transfer: transfer, session: session) else { return }
            }
            guard session == self.session else { return }
            s.revision = entry.revision
            s.appliedAt = entry.updatedAt
            s.digest = nil
            s.signedOutHere = false
            s.unreadableRevision = nil
            s.holdsForeignSignIn = false
            save(provider, s)
            status[provider] = endpoint.libraryKey == nil ? .needsKey : .signedOutEverywhere
            if entry.updatedBy != me { record(Import(provider: provider, updatedAt: entry.updatedAt, latencyMs: latency, signedOut: true)) }
            return
        }
        guard let key = endpoint.libraryKey else { status[provider] = .needsKey; return }

        // Remote → local.
        if let entry, let sealed = entry.sealed, entry.revision > s.revision || Self.isLegacy(entry, s) {
            if s.signedOutHere {
                s.revision = entry.revision
                s.appliedAt = entry.updatedAt
                save(provider, s)
                status[provider] = .signedOutHere
                return
            }
            guard entry.keyId == key.id else {
                // While the key is being replaced the entry may already be sealed with the new one.
                status[provider] = endpoint.vaultWritesPaused ? .waiting : .failed("This sign-in was sealed with another library key.")
                return
            }
            // Legacy (v1) ciphertext is accepted only at revision 0; every later revision must open as v2 for exactly it.
            let opened = entry.revision == 0
                ? try? SignInSealing.openLegacy(sealed, provider: provider, key: key)
                : try? SignInSealing.open(sealed, provider: provider, revision: entry.revision, key: key)
            guard let data = opened else {
                await signOutForUnreadable(provider, entry: entry, transfer: transfer, session: session, state: &s)
                return
            }
            let digest = Self.digest(data)
            if entry.updatedBy == me || digest == s.digest {
                // Our own write coming back, or the sign-in this device already has: nothing to import.
                s.revision = entry.revision
                s.appliedAt = entry.updatedAt
                s.digest = digest
                s.unreadableRevision = nil
                save(provider, s)
                status[provider] = .synced(entry.updatedAt)
            } else {
                if let failure = failedImports[provider], failure.revision == entry.revision, ContinuousClock.now < failure.retryAt {
                    return
                }
                guard session == self.session else { return }
                importing[provider] = digest
                do {
                    try await transfer.importSignIn(data)
                } catch {
                    guard session == self.session else { return }
                    importing[provider] = nil
                    // Not applied: the next vault update (or a retry after a pause) tries again, and nothing
                    // local is uploaded over it meanwhile.
                    failedImports[provider] = (entry.revision, ContinuousClock.now + importRetryDelay)
                    status[provider] = .failed(SyncError.from(error).localizedDescription)
                    return
                }
                guard session == self.session else {
                    // The device joined another library while this import ran: what it installed belongs to the old
                    // library and must not be shared with the new one.
                    var current = state[provider] ?? ProviderState()
                    current.holdsForeignSignIn = true
                    save(provider, current)
                    return
                }
                importing[provider] = nil
                failedImports[provider] = nil
                s.revision = entry.revision
                s.appliedAt = entry.updatedAt
                s.digest = digest
                s.unreadableRevision = nil
                s.holdsForeignSignIn = false
                save(provider, s)
                status[provider] = .synced(entry.updatedAt)
                record(Import(provider: provider, updatedAt: entry.updatedAt, latencyMs: endpoint.clock.now() - entry.updatedAt,
                              signedOut: false, bytes: data.count))
                if entry.revision != 0 { return }
            }
            if entry.revision == 0 {
                guard !endpoint.vaultWritesPaused else { status[provider] = .waiting; return }
                guard await migrateLegacy(provider, data: data, endpoint: endpoint, key: key, session: session, state: &s) else { return }
            }
        }

        // Local → remote.
        guard let data = await transfer.exportSignIn() else {
            guard session == self.session else { return }
            if s.holdsForeignSignIn {
                s.holdsForeignSignIn = false
                save(provider, s)
            }
            if s.signedOutHere {
                status[provider] = .signedOutHere
            } else if let unreadable = s.unreadableRevision, unreadable == entry?.revision {
                status[provider] = .failed(Self.unreadableMessage)
            } else if let entry, entry.sealed == nil {
                status[provider] = .signedOutEverywhere
            } else {
                status[provider] = .notSignedIn
            }
            return
        }
        guard session == self.session else { return }
        if s.holdsForeignSignIn {
            status[provider] = .failed(Self.foreignMessage)
            return
        }
        let digest = Self.digest(data)
        if digest == s.digest || digest == importing[provider] {
            status[provider] = .synced(s.appliedAt)
            return
        }
        // Never seal for a key this device isn't sure is the account's.
        guard !endpoint.vaultWritesPaused else {
            status[provider] = .waiting
            return
        }
        let base = max(s.revision, entry?.revision ?? 0)
        do {
            let sealed = try SignInSealing.seal(data, provider: provider, revision: base + 1, key: key)
            guard session == self.session else { return }
            let write = try await endpoint.putVault(provider, sealed: sealed, keyId: key.id, baseRevision: base)
            guard session == self.session else { return }
            s.revision = max(s.revision, write.revision)
            s.appliedAt = write.updatedAt
            s.digest = digest
            s.signedOutHere = false
            s.unreadableRevision = nil
            save(provider, s)
            status[provider] = .synced(write.updatedAt)
        } catch is SyncConflict {
            // Another device wrote first. Its entry is on the way; the live query reconciles again.
            guard session == self.session else { return }
            status[provider] = .waiting
        } catch {
            guard session == self.session else { return }
            status[provider] = .failed(SyncError.from(error).localizedDescription)
        }
    }

    /// A revision-0 entry from before revisions, while this device hasn't applied anything newer.
    private static func isLegacy(_ entry: VaultEntry, _ s: ProviderState) -> Bool {
        entry.revision == 0 && s.revision == 0 && !s.signedOutHere && s.unreadableRevision == nil
    }

    /// An entry that doesn't open at its revision is newer than what this device applied, but no device holding
    /// the key wrote it. It may cover a "sign out everywhere" this device never saw, so the device signs out of the
    /// provider rather than keep (or re-upload) an old sign-in. Only a later sign-in here replaces the entry.
    private func signOutForUnreadable(_ provider: ProviderID, entry: VaultEntry, transfer: any SignInTransfer, session: Int,
                                      state s: inout ProviderState) async {
        guard session == self.session else { return }
        let signedIn = await transfer.exportSignIn() != nil
        guard session == self.session else { return }
        if signedIn {
            guard await deleteSignIn(provider, transfer: transfer, session: session) else { return }
        }
        guard session == self.session else { return }
        s.revision = entry.revision
        s.appliedAt = entry.updatedAt
        s.digest = nil
        s.unreadableRevision = entry.revision
        s.holdsForeignSignIn = false
        save(provider, s)
        status[provider] = .failed(Self.unreadableMessage)
    }

    /// Deletes the local sign-in for a sign-out the vault asks for. False when the caller must stop without applying
    /// the entry: deletion threw (the revision stays unapplied, so this runs again, and nothing is uploaded meanwhile),
    /// an earlier failure's retry time hasn't come yet, or the session changed.
    private func deleteSignIn(_ provider: ProviderID, transfer: any SignInTransfer, session: Int) async -> Bool {
        if let failure = failedSignOuts[provider], ContinuousClock.now < failure.retryAt {
            status[provider] = .failed(failure.message)
            return false
        }
        do {
            try await transfer.signOut()
        } catch {
            guard session == self.session else { return false }
            let message = Self.deletionFailedMessage(error)
            failedSignOuts[provider] = (ContinuousClock.now + signOutRetryDelay, message)
            status[provider] = .failed(message)
            scheduleSignOutRetry(provider)
            return false
        }
        guard session == self.session else { return false }
        failedSignOuts[provider] = nil
        signOutRetries.removeValue(forKey: provider)?.cancel()
        return true
    }

    private func scheduleSignOutRetry(_ provider: ProviderID) {
        signOutRetries[provider]?.cancel()
        let delay = signOutRetryDelay
        signOutRetries[provider] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.signOutRetries[provider] = nil
            self.reconcile(provider)
        }
    }

    static func deletionFailedMessage(_ error: any Error) -> String {
        "This device was signed out from the library, but its saved sign-in couldn't be deleted (\(error.localizedDescription)). \(ProductInfo.name) keeps trying and shares nothing from this device until it's gone."
    }

    /// Re-seals a legacy entry (just opened at revision 0) in the current format at revision 1, with compare and
    /// swap on revision 0, so no device has to open v1 ciphertext again. False when the sync should stop here.
    private func migrateLegacy(_ provider: ProviderID, data: Data, endpoint: any VaultEndpoint, key: LibraryKey, session: Int,
                               state s: inout ProviderState) async -> Bool {
        do {
            let sealed = try SignInSealing.seal(data, provider: provider, revision: 1, key: key)
            guard session == self.session else { return false }
            let write = try await endpoint.putVault(provider, sealed: sealed, keyId: key.id, baseRevision: 0)
            guard session == self.session else { return false }
            s.revision = max(s.revision, write.revision)
            s.appliedAt = write.updatedAt
            s.digest = Self.digest(data)
            save(provider, s)
            status[provider] = .synced(write.updatedAt)
            return true
        } catch is SyncConflict {
            // Another device migrated (or wrote) first; its entry arrives through the live query.
            guard session == self.session else { return false }
            status[provider] = .waiting
            return false
        } catch {
            guard session == self.session else { return false }
            status[provider] = .failed(SyncError.from(error).localizedDescription)
            return false
        }
    }

    private func record(_ i: Import) {
        lastImport = i
        onImport?(i)
    }

    private func save(_ provider: ProviderID, _ s: ProviderState) {
        state[provider] = s
        persist()
    }

    private func persist() {
        store.setState(Self.stateName, try? JSONEncoder().encode(Saved(scope: scope, providers: state)))
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
