import Foundation
import OpenMusicCore

/// Moves the Spotify sign-in between devices for OpenMusic Sync (`OpenMusicSync.SignInTransfer`).
///
/// It has the exact shape of `SignInTransfer`, so an app that links both kits declares the conformance in one line
/// (`extension SpotifySignInTransfer: @retroactive SignInTransfer {}`) and registers it with
/// `sync.signIns.register(_:)`. SpotifyKit itself doesn't depend on OpenMusicSync.
///
/// What travels: the whole token (access token, refresh token, expiry, scope and the client that issued it) and
/// the Spotify user id. The access token goes too on purpose: a device that imports a fresh token uses it until it
/// expires instead of refreshing at once. Spotify rotates the refresh token on every refresh, so if each import
/// forced a refresh, two devices would keep rotating and re-uploading forever. This way the library refreshes
/// about once an hour, on whichever device needs it first, and that device's rotation syncs to the rest.
/// OpenMusicSync seals the blob with the library key; this type never logs it.
@MainActor
public final class SpotifySignInTransfer {
    public let provider: ProviderID = .spotify
    /// Set by `SignInSync.register`. Called on every sign-in, sign-out and token rotation here.
    public var signInDidChange: (@MainActor () -> Void)?

    /// Checks a transferred token before it replaces this device's session. Returns the account and the token to
    /// keep (the check may have refreshed it).
    public typealias Verifier = @Sendable (_ token: TransferredToken) async throws -> VerifiedSignIn

    /// Set by the app: the Spotify sign-in stored in the sync library's vault right now, opened (nil when there is
    /// none, or this device can't open it). When Spotify refuses a refresh, the transfer looks here first for the
    /// token another device rotated.
    public var syncedSignIn: (@MainActor () -> Data?)?
    /// How long a refused refresh waits for another device's rotated token to arrive before signing out.
    public var refreshRecoveryWait: Duration = .seconds(6)

    private let spotify: SpotifyProvider
    private let verify: Verifier
    /// Refused refreshes waiting for the next import (`recoverRefresh`), each with the owner it needs.
    private var importWaiters: [UUID: (owner: String, continuation: CheckedContinuation<SpotifyAPI.RecoveredToken?, Never>)] = [:]

    public init(provider: SpotifyProvider, verify: Verifier? = nil) {
        self.spotify = provider
        self.verify = verify ?? Self.checkWithSpotify(transport: provider.transport)
        provider.sessionDidChange = { [weak self] in self?.signInDidChange?() }
        let recovery: SpotifyAPI.RefreshRecovery = { [weak self] rejected, owner in try await self?.recoverRefresh(rejected: rejected, owner: owner) }
        Task { await provider.service.api.setRefreshRecovery(recovery) }
    }

    // MARK: SignInTransfer

    public func exportSignIn() async -> Data? {
        guard spotify.authStatus.isSignedIn, let token = await spotify.service.api.currentToken, token.refreshToken != nil else { return nil }
        return try? SpotifySignInPayload(token: token, userID: await spotify.service.api.userID).encoded()
    }

    public func importSignIn(_ data: Data) async throws {
        let payload: SpotifySignInPayload
        do {
            payload = try SpotifySignInPayload.decode(data)
        } catch {
            throw TransferError.unreadable
        }
        guard payload.token.refreshToken != nil else { throw TransferError.unreadable }
        let verified: VerifiedSignIn
        do {
            verified = try await verify(TransferredToken(token: payload.token))
        } catch ProviderError.notSignedIn {
            // Spotify revoked it. Keep this device's own session untouched.
            throw TransferError.rejected
        } catch let interrupted as CheckInterrupted where (interrupted.underlying as? ProviderError) == .notSignedIn {
            throw TransferError.rejected
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Offline, or Spotify didn't answer: nothing is committed until Spotify accepts the token. The sign-in
            // sync tries this import again later; this device's own session stays as it is.
            throw TransferError.unverified
        }
        // Throws when the Keychain didn't take it: not applied, and the sign-in sync tries again later.
        try await spotify.adoptTransferredSignIn(verified.token.token, account: verified.account, userID: verified.userID ?? payload.userID)
        rotatedDuringCheck = nil
        resumeImportWaiters(with: verified.token.token, owner: verified.userID)
        // If the check refreshed the token, this export differs from what arrived and the rotation syncs back.
        signInDidChange?()
    }

    // MARK: Refresh races

    /// Spotify refused `rejected`'s refresh token. If another device refreshed the same token first, its rotated
    /// token is in the vault or on the way: take it from the vault, else wait briefly for the import. nil: no
    /// newer token of this account, the session really is revoked.
    ///
    /// The token must belong to the session's owner: `owner` (the API's user id) or, before the API learned it, the
    /// account the provider holds. The vault's token is checked with Spotify (`/me` on a throwaway client, which may
    /// refresh it) and the import's was checked on import; a token of another account, or one whose owner can't be
    /// established, is never handed back: the payload's own user id is a claim, not a check.
    ///
    /// Only a definite answer ends the session: Spotify naming another user for the token, or refusing the token itself
    /// (`notSignedIn`). A check that couldn't be made (offline, a timeout, 429, 5xx) throws, so the refresh fails
    /// retryably and nothing is deleted. When the check refreshed the token on its throwaway client before failing, the
    /// rotated token (the vault's refresh token is spent by then) is kept here, uninstalled, and checked next time.
    func recoverRefresh(rejected: SpotifyToken, owner: String?) async throws -> SpotifyAPI.RecoveredToken? {
        guard let expected = owner ?? heldAccountID else { return nil }
        let session = spotify.session
        // A kept token counts only for the account and session it was checked for; otherwise it just goes.
        if let kept = rotatedDuringCheck, kept.owner != expected || kept.session != session { rotatedDuringCheck = nil }
        if let kept = rotatedDuringCheck {
            if let recovered = try await check(kept.token, owner: expected, session: session) { return recovered }
            // It failed its check: dropped, never a reason to end this sign-in. The vault is next.
            rotatedDuringCheck = nil
        }
        if let vault = syncedSignIn?().flatMap({ try? SpotifySignInPayload.decode($0) })?.token, Self.isNewer(vault, than: rejected) {
            return try await check(vault, owner: expected, session: session)
        }
        let id = UUID()
        let wait = refreshRecoveryWait
        return await withCheckedContinuation { continuation in
            importWaiters[id] = (expected, continuation)
            Task { [weak self] in
                try? await Task.sleep(for: wait)
                self?.importWaiters.removeValue(forKey: id)?.continuation.resume(returning: nil)
            }
        }
    }

    /// A token the owner check rotated on its throwaway client before the check failed for a passing reason, with the
    /// account and session it was checked for: the next recovery in that same session checks it (never installed before
    /// that). Dropped on sign-out, on an import, and whenever the session it belongs to isn't the current one.
    private var rotatedDuringCheck: (token: SpotifyToken, owner: String, session: ProviderSession)?

    /// Checks `token`'s owner with Spotify. The recovered token when it is `owner`'s; nil when Spotify says definitely
    /// not (another user, or the token itself refused). Throws when it can't tell (offline, a timeout, 429, 5xx); if the
    /// check rotated the token first, the rotation is kept for `owner` and `session`, unless the session moved on
    /// meanwhile (a late check of an old session keeps nothing).
    private func check(_ token: SpotifyToken, owner: String, session: ProviderSession) async throws -> SpotifyAPI.RecoveredToken? {
        let verified: VerifiedSignIn
        do {
            verified = try await verify(TransferredToken(token: token))
        } catch ProviderError.notSignedIn {
            return nil
        } catch let interrupted as CheckInterrupted {
            if (interrupted.underlying as? ProviderError) == .notSignedIn { return nil }
            if let rotated = interrupted.rotated, spotify.session == session {
                rotatedDuringCheck = (rotated, owner, session)
            }
            throw interrupted.underlying
        }
        if rotatedDuringCheck?.session == session { rotatedDuringCheck = nil }
        guard let id = verified.userID, id == owner else { return nil }
        return SpotifyAPI.RecoveredToken(token: verified.token.token, userID: id)
    }

    /// The account id the provider's session holds now.
    private var heldAccountID: String? {
        if case .account(let id?) = spotify.session.identity { return id }
        return nil
    }

    /// An import landed: each waiting refusal gets its token only if it is the same account's.
    private func resumeImportWaiters(with token: SpotifyToken, owner: String?) {
        let waiters = importWaiters
        importWaiters = [:]
        for waiter in waiters.values {
            guard let owner, owner == waiter.owner else { waiter.continuation.resume(returning: nil); continue }
            waiter.continuation.resume(returning: SpotifyAPI.RecoveredToken(token: token, userID: owner))
        }
    }

    static func isNewer(_ token: SpotifyToken, than rejected: SpotifyToken) -> Bool {
        guard let refresh = token.refreshToken, refresh != rejected.refreshToken else { return false }
        return token.clientID == nil || rejected.clientID == nil || token.clientID == rejected.clientID
    }

    /// Throws when the saved token couldn't be deleted; the provider then stays signed in (`trySignOut`).
    public func signOut() async throws {
        rotatedDuringCheck = nil
        // The provider's hook reports the change.
        try await spotify.trySignOut()
    }

    public enum TransferError: LocalizedError, Equatable {
        case unreadable
        case rejected
        /// Spotify couldn't be asked (offline, or it didn't answer). Retryable.
        case unverified

        public var errorDescription: String? {
            switch self {
            case .unreadable: "The Spotify sign-in from your other device couldn't be read. Update \(ProductInfo.name) on both devices."
            case .rejected: "Spotify no longer accepts the sign-in from your other device. Sign in again there or here."
            case .unverified: "Couldn't check the Spotify sign-in from your other device with Spotify. \(ProductInfo.name) tries again shortly."
            }
        }
    }

    /// A token in transit. Prints redacted.
    public struct TransferredToken: Sendable, CustomStringConvertible {
        public let token: SpotifyToken
        public init(token: SpotifyToken) { self.token = token }
        /// The probe's test sign-in (`testPayload`), which isn't a real Spotify token.
        #if DEBUG
        public var isTestSignIn: Bool { token.scope == SpotifySignInPayload.testScope }
        #endif
        public var description: String { "TransferredToken(expiresAt: \(token.expiresAt), tokens: <redacted>)" }
    }

    public struct VerifiedSignIn: Sendable {
        public var account: AccountInfo
        public var token: TransferredToken
        public var userID: String?
        public init(account: AccountInfo, token: TransferredToken, userID: String?) {
            self.account = account
            self.token = token
            self.userID = userID
        }
    }
}

// MARK: - Payload

/// The blob that travels, sealed by OpenMusicSync. Version 1.
struct SpotifySignInPayload: Codable, Sendable, CustomStringConvertible {
    var version = 1
    var token: SpotifyToken
    var userID: String?

    #if DEBUG
    static let testScope = "medley-test-signin"
    #endif

    /// Stable bytes for the same token (sorted keys, dates as seconds since 1970).
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> SpotifySignInPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let payload = try decoder.decode(SpotifySignInPayload.self, from: data)
        guard payload.version == 1 else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unknown version")) }
        return payload
    }

    var description: String { "SpotifySignInPayload(userID: \(userID ?? "-"), tokens: <redacted>)" }
}

extension SpotifySignInTransfer {
    // The fake test sign-in and the verifier that accepts it exist in Debug builds only (self-tests, the probe and
    // unit tests). Release builds can neither make nor accept one.
    #if DEBUG
    /// A sign-in payload with a fake token, for `openmusic-probe sync` to check the transfer end to end without real
    /// credentials. Spotify rejects it, so a device only accepts it with a test `Verifier` (`acceptingTestSignIns`).
    public nonisolated static func testPayload() -> Data {
        let token = SpotifyToken(accessToken: "openmusic-test", refreshToken: "openmusic-test", expiresAt: Date().addingTimeInterval(3600),
                                 scope: SpotifySignInPayload.testScope, clientID: SpotifyBuiltInClient.clientID)
        return (try? SpotifySignInPayload(token: token, userID: nil).encoded()) ?? Data()
    }

    /// A verifier that accepts the probe's test sign-in without a request and checks everything else for real.
    /// For self-tests only.
    public static func acceptingTestSignIns(provider: SpotifyProvider) -> Verifier {
        let real = checkWithSpotify(transport: provider.transport)
        return { transferred in
            guard transferred.isTestSignIn else { return try await real(transferred) }
            return VerifiedSignIn(account: AccountInfo(name: "Test Account", detail: "Test sign-in"), token: transferred, userID: nil)
        }
    }
    #endif

    /// The real check: `/me` (uncached, no cookies) on a throwaway client. If it refreshes, the new token lands in its
    /// own store, not the shared one, and comes back to be kept. When the check fails after such a refresh, it throws
    /// `CheckInterrupted` carrying the rotated token, so the caller can keep it.
    nonisolated static func checkWithSpotify(transport: any SpotifyTransport) -> Verifier {
        { transferred in
            let store = MemoryTokenStore(transferred.token)
            let api = SpotifyAPI(transport: transport, tokenStore: store, clientID: { transferred.token.clientID })
            let account: AccountInfo
            do {
                account = try await SpotifyService(api: api).me()
            } catch {
                guard let rotated = store.load(), rotated.refreshToken != transferred.token.refreshToken else { throw error }
                throw CheckInterrupted(rotated: rotated, underlying: error)
            }
            return VerifiedSignIn(account: account, token: TransferredToken(token: store.load() ?? transferred.token), userID: await api.userID)
        }
    }

    /// An owner check that failed after its throwaway client rotated the token: the rotated token, still unchecked.
    struct CheckInterrupted: Error {
        let rotated: SpotifyToken?
        let underlying: any Error
    }
}
