import Foundation
import MedleyCore

/// Moves the YouTube Music sign-in between devices for Medley Sync (`MedleySync.SignInTransfer`).
///
/// It has the exact shape of `SignInTransfer`, so an app that links both kits declares the conformance in one line
/// (`extension YouTubeMusicSignInTransfer: @retroactive SignInTransfer {}`) and registers it with
/// `sync.signIns.register(_:)`. YouTubeMusicKit itself doesn't depend on MedleySync.
///
/// What travels: the session cookies, the Google account index (`authUser`) and the selected channel
/// (`datasyncId`), plus the account name and photo so the other device can show who is signed in. MedleySync seals
/// it with the library key; this type never logs it.
///
/// Google rotates a few cookies (`__Secure-*PSIDTS`, `SIDCC`) every few minutes of use. Syncing each rotation would
/// upload on every reconcile and keep the devices overwriting each other's fresher cookies, so the export is a
/// snapshot taken at the last sign-in, channel switch or import. It is retaken from the live cookies at most once a
/// day (`snapshotMaxAge`), which keeps the copy on other devices reasonably fresh.
@MainActor
public final class YouTubeMusicSignInTransfer {
    public let provider: ProviderID = .youtubeMusic
    /// Set by `SignInSync.register`. Called on every sign-in, channel switch and sign-out here.
    public var signInDidChange: (@MainActor () -> Void)?

    /// Checks transferred cookies before they replace this device's session. Returns the account they belong to.
    public typealias Verifier = @Sendable (_ credentials: TransferredCredentials) async throws -> AccountInfo

    private let youtube: YouTubeMusicProvider
    private let store: any YouTubeMusicTransferStore
    private let verify: Verifier
    private let persist: Bool
    private let now: @Sendable () -> Date
    /// True while an import commits, so the provider's change hook doesn't retake the snapshot from it.
    private var importing = false

    public static let snapshotMaxAge: TimeInterval = 24 * 3600

    /// - Parameters:
    ///   - verify: checks the cookies with a real request by default. Tests pass a fake.
    ///   - persist: false keeps everything out of the Keychain (tests, the probe).
    public convenience init(provider: YouTubeMusicProvider, verify: Verifier? = nil) {
        self.init(provider: provider, store: KeychainYouTubeMusicTransferStore(), verify: verify, persist: true)
    }

    init(provider: YouTubeMusicProvider, store: any YouTubeMusicTransferStore, verify: Verifier? = nil, persist: Bool,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.youtube = provider
        self.store = store
        self.persist = persist
        self.now = now
        self.verify = verify ?? Self.checkWithYouTube
        provider.sessionDidChange = { [weak self] in self?.localSessionChanged() }
    }

    // MARK: SignInTransfer

    public func exportSignIn() async -> Data? {
        guard youtube.authStatus.isSignedIn, let live = await youtube.currentCredentials else { return nil }
        if let snapshot = store.load(), now().timeIntervalSince(snapshot.takenAt) < Self.snapshotMaxAge,
           let payload = try? YouTubeMusicSignInPayload.decode(snapshot.payload),
           payload.credentials.authUser == live.authUser, payload.credentials.datasyncId == live.datasyncId {
            return snapshot.payload
        }
        return takeSnapshot(of: live)
    }

    public func importSignIn(_ data: Data) async throws {
        let payload: YouTubeMusicSignInPayload
        do {
            payload = try YouTubeMusicSignInPayload.decode(data)
        } catch {
            throw TransferError.unreadable
        }
        guard payload.credentials.isUsable else { throw TransferError.unreadable }
        let info: AccountInfo
        do {
            info = try await verify(TransferredCredentials(credentials: payload.credentials, account: payload.account))
        } catch ProviderError.notSignedIn {
            // Google no longer accepts these cookies. Keep this device's own session untouched.
            throw TransferError.rejected
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Offline, or YouTube didn't answer: nothing is committed until Google accepts the cookies. The sign-in
            // sync tries this import again later; this device's own session stays as it is.
            throw TransferError.unverified
        }
        importing = true
        defer { importing = false }
        // Throws when the Keychain didn't take it: not applied, and the sign-in sync tries again later.
        try await youtube.adoptTransferredSignIn(payload.credentials, info: info, persist: persist)
        // Export exactly what arrived, so the echo of this import isn't uploaded again.
        store.save(YouTubeMusicTransferSnapshot(payload: data, takenAt: now()))
        signInDidChange?()
    }

    /// Throws when the saved cookies couldn't be deleted; the provider then stays signed in (`trySignOut`).
    public func signOut() async throws {
        // The provider's hook clears the snapshot and reports the change. `clearWebsiteData` empties (rather than
        // deletes) the web data store on iOS, so a sign-out arriving from another device is safe.
        try await youtube.trySignOut()
    }

    // MARK: Local changes

    private func localSessionChanged() {
        guard !importing else { return }
        if youtube.authStatus.isSignedIn {
            Task { [weak self] in
                guard let self, let live = await self.youtube.currentCredentials else { return }
                self.takeSnapshot(of: live)
                self.signInDidChange?()
            }
        } else {
            store.save(nil)
            signInDidChange?()
        }
    }

    @discardableResult
    private func takeSnapshot(of credentials: YTMCredentials) -> Data? {
        let account: AccountInfo? = if case .signedIn(let info) = youtube.authStatus { info } else { nil }
        guard let data = try? YouTubeMusicSignInPayload(credentials: credentials, account: account).encoded() else { return nil }
        store.save(YouTubeMusicTransferSnapshot(payload: data, takenAt: now()))
        return data
    }

    public enum TransferError: LocalizedError, Equatable {
        case unreadable
        case rejected
        /// YouTube couldn't be asked (offline, or it didn't answer). Retryable.
        case unverified

        public var errorDescription: String? {
            switch self {
            case .unreadable: "The YouTube Music sign-in from your other device couldn't be read. Update \(ProductInfo.name) on both devices."
            case .rejected: "YouTube Music no longer accepts the sign-in from your other device. Sign in again there or here."
            case .unverified: "Couldn't check the YouTube Music sign-in from your other device with YouTube. \(ProductInfo.name) tries again shortly."
            }
        }
    }

    /// What `Verifier` checks: the cookies and channel, and the account the other device said they belong to.
    public struct TransferredCredentials: Sendable, CustomStringConvertible {
        let credentials: YTMCredentials
        public let account: AccountInfo?
        /// The probe's test sign-in (`testPayload`), which carries no real cookies.
        #if DEBUG
        public var isTestSignIn: Bool { credentials.cookies[YouTubeMusicSignInPayload.testCookie] != nil }
        #endif
        public var description: String { "TransferredCredentials(account: \(account?.name ?? "-"), cookies: <redacted>)" }
    }
}

// MARK: - Payload

/// The blob that travels, sealed by MedleySync. Version 1.
struct YouTubeMusicSignInPayload: Codable, Sendable, CustomStringConvertible {
    var version = 1
    var credentials: YTMCredentials
    var account: AccountInfo?

    #if DEBUG
    static let testCookie = "MEDLEY_TEST_SIGNIN"
    #endif

    /// Stable bytes for the same sign-in (sorted keys), so an unchanged sign-in is never uploaded twice.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> YouTubeMusicSignInPayload {
        let payload = try JSONDecoder().decode(YouTubeMusicSignInPayload.self, from: data)
        guard payload.version == 1 else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unknown version")) }
        return payload
    }

    var description: String { "YouTubeMusicSignInPayload(account: \(account?.name ?? "-"), cookies: <redacted>)" }
}

extension YouTubeMusicSignInTransfer {
    // The fake test sign-in and the verifier that accepts it exist in Debug builds only (self-tests, the probe and
    // unit tests). Release builds can neither make nor accept one.
    #if DEBUG
    /// A sign-in payload with fake cookies, for `medley-probe sync` to check the transfer end to end without real
    /// credentials. YouTube rejects it, so a device only accepts it with a test `Verifier` (`acceptingTestSignIns`).
    public nonisolated static func testPayload(accountName: String) -> Data {
        let creds = YTMCredentials(cookies: ["SAPISID": "medley-test", "SID": "medley-test", YouTubeMusicSignInPayload.testCookie: "1"])
        return (try? YouTubeMusicSignInPayload(credentials: creds, account: AccountInfo(name: accountName, detail: "Test sign-in")).encoded()) ?? Data()
    }

    /// A verifier that accepts the probe's test sign-in without a request and checks everything else for real.
    /// For self-tests only.
    public nonisolated static func acceptingTestSignIns() -> Verifier {
        { transferred in
            guard transferred.isTestSignIn else { return try await checkWithYouTube(transferred) }
            return transferred.account ?? AccountInfo(name: "Test Account")
        }
    }
    #endif

    /// The real check: the account menu on a throwaway client that never writes rotated cookies anywhere.
    nonisolated static let checkWithYouTube: Verifier = { transferred in
        let probe = InnerTubeClient()
        await probe.setCredentials(transferred.credentials, persist: false)
        return try await probe.account()
    }
}

// MARK: - Snapshot storage

struct YouTubeMusicTransferSnapshot: Codable, Sendable {
    /// The exact payload bytes last exported or imported.
    var payload: Data
    var takenAt: Date
}

protocol YouTubeMusicTransferStore: Sendable {
    func load() -> YouTubeMusicTransferSnapshot?
    func save(_ snapshot: YouTubeMusicTransferSnapshot?)
}

struct KeychainYouTubeMusicTransferStore: YouTubeMusicTransferStore {
    static let key = "ytm.transfer"
    func load() -> YouTubeMusicTransferSnapshot? { Keychain.codable(YouTubeMusicTransferSnapshot.self, for: Self.key) }
    func save(_ snapshot: YouTubeMusicTransferSnapshot?) { Keychain.setCodable(snapshot, for: Self.key) }
}

final class MemoryYouTubeMusicTransferStore: YouTubeMusicTransferStore, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: YouTubeMusicTransferSnapshot?
    func load() -> YouTubeMusicTransferSnapshot? { lock.withLock { snapshot } }
    func save(_ snapshot: YouTubeMusicTransferSnapshot?) { lock.withLock { self.snapshot = snapshot } }
}
