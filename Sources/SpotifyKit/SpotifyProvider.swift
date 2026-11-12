import Foundation
import OpenMusicCore
import Observation
import SwiftUI

/// Spotify through the Web API (OAuth PKCE with the built-in client, or the listener's own Client ID), playing
/// through the Spotify app or Spotify Connect. See `SpotifyService` for what the current API allows and how OpenMusic works around the rest.
@MainActor
@Observable
public final class SpotifyProvider: MusicProvider {
    public let id: ProviderID = .spotify
    /// Lyrics come from LRCLIB. Related artists and recommendations aren't available to new Spotify apps;
    /// radio is search-built.
    public let capabilities: ProviderCapabilities = [
        .search, .home, .explore, .library, .lyrics, .syncedLyrics, .radio, .like, .playlistEditing, .playlistInsert, .follow, .playback,
    ]
    public private(set) var authStatus: AuthStatus = .signedOut

    /// Sign in with the listener's own Spotify developer app instead of the built-in client. Off by default.
    public var usesOwnClientID: Bool {
        didSet { defaults.set(usesOwnClientID, forKey: Keys.usesOwnClientID) }
    }

    /// The listener's own Spotify app Client ID (not a secret for PKCE clients). Used only with `usesOwnClientID`.
    /// Also refreshes sessions saved before the built-in client existed.
    public var clientID: String {
        didSet {
            let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != clientID { clientID = trimmed } // doesn't re-enter didSet
            defaults.set(trimmed, forKey: Keys.clientID)
            clientIDBox.set(trimmed)
        }
    }

    /// How the redirect comes back with the listener's own Client ID. The built-in client always uses the browser.
    public var redirect: SpotifyRedirect {
        didSet { defaults.set(redirect.rawValue, forKey: Keys.redirect) }
    }

    public let engine: SpotifyPlaybackEngine
    public var playbackEngine: any PlaybackEngine { engine }

    @ObservationIgnored public let service: SpotifyService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clientIDBox: ClientIDBox
    @ObservationIgnored private let lyricsClient = LRCLibClient()
    @ObservationIgnored let transport: any SpotifyTransport
    /// Called after every sign-in, sign-out, token refresh (the refresh token rotates) and a restore that found the
    /// session revoked. `SpotifySignInTransfer` listens here so the sign-in syncs to the other devices.
    @ObservationIgnored var sessionDidChange: (@MainActor () -> Void)?
    @ObservationIgnored private var recentSearches: [String]

    // Sign-in in progress. Every step checks `signInGeneration` before writing credentials or changing `authStatus`,
    // so a cancelled or superseded sign-in can't finish behind the listener's back.
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var signInGeneration = 0
    /// `authStatus` before the pending sign-in started; restored when it's cancelled. Nil when none is pending.
    @ObservationIgnored private var statusBeforeSignIn: AuthStatus?
    /// Runs the browser part of sign-in: given where the redirect should go and a builder for the authorize URL (which
    /// needs the final redirect URI), returns the redirect. A seam for tests; the app uses `SpotifySignInFlow`.
    @ObservationIgnored var authorize: @MainActor (SpotifyRedirectTarget, @MainActor (String) -> URL) async throws -> SpotifyAuthorization
    /// Where the signed-in account summary is kept between launches. A seam for tests.
    @ObservationIgnored var saveAccount: @MainActor (AccountInfo?) -> Void = { Keychain.setCodable($0, for: Keys.account) }

    /// Who requests go out as: changes only around a swap of the API's token (`swapToken`) and when launch or a
    /// refresh learns what the saved token is, so it is right even while `authStatus` says `.signingIn`.
    public private(set) var session: ProviderSession
    /// Bumped by every `swapToken`; only the newest one settles `session`.
    @ObservationIgnored private var swapEpoch = 0
    @ObservationIgnored private var swapsInFlight = 0

    enum Keys {
        static let clientID = "spotify.clientID"
        static let usesOwnClientID = "spotify.usesOwnClientID"
        static let redirect = "spotify.redirect"
        static let recentSearches = "spotify.recentSearches"
        static let account = "spotify.account"
    }

    public convenience init() {
        self.init(defaults: .standard, transport: URLSessionTransport(), tokenStore: KeychainTokenStore())
    }

    init(defaults: UserDefaults, transport: any SpotifyTransport, tokenStore: any SpotifyTokenStore) {
        self.defaults = defaults
        let clientID = defaults.string(forKey: Keys.clientID) ?? ""
        let box = ClientIDBox(clientID)
        self.clientIDBox = box
        self.clientID = clientID
        self.usesOwnClientID = defaults.bool(forKey: Keys.usesOwnClientID)
        self.redirect = SpotifyRedirect(rawValue: defaults.string(forKey: Keys.redirect) ?? "") ?? .loopback
        self.recentSearches = defaults.stringArray(forKey: Keys.recentSearches) ?? []
        self.transport = transport
        // A saved token is used by requests from the start, but whose it is is known only after `restoreSession`.
        self.session = ProviderSession(generation: 0, identity: tokenStore.load() == nil ? .signedOut : .changing)
        self.authorize = { target, makeURL in
            let flow = SpotifySignInFlow()
            return try await withTaskCancellationHandler {
                try await flow.authorize(target: target, makeURL: makeURL)
            } onCancel: {
                Task { @MainActor in flow.cancel() }
            }
        }
        let api = SpotifyAPI(transport: transport, tokenStore: tokenStore, clientID: { box.get() })
        let service = SpotifyService(api: api)
        self.service = service
        self.engine = SpotifyPlaybackEngine(service: service, defaults: defaults)
        engine.isSignedIn = { [weak self] in self?.authStatus.isSignedIn ?? false }
        let refreshed: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.tokenRefreshed() }
        }
        Task { await api.setTokenRefreshObserver(refreshed) }
    }

    /// A refresh rotated the token, or found it revoked.
    private func tokenRefreshed() {
        Task {
            if await service.api.hasToken {
                sessionDidChange?()
            } else if authStatus.isSignedIn {
                settleSession(.signedOut)
                saveAccount(nil)
                authStatus = .signedOut
                sessionDidChange?()
            }
        }
    }

    /// Commits a sign-in another device made (`SpotifySignInTransfer`), already checked by the transfer.
    /// Doesn't call `sessionDidChange`: the transfer reports the change itself.
    /// Throws, changing nothing, when the Keychain didn't take the token.
    func adoptTransferredSignIn(_ token: SpotifyToken, account: AccountInfo, userID: String?) async throws {
        cancelSignIn()
        guard try await swapToken(token, userID: userID, accountID: account.id ?? userID) else { throw CancellationError() }
        saveAccount(account)
        authStatus = .signedIn(account)
    }

    /// Hands `token` to the API, with `session` `.changing` until it has it. The API saves it first (deletes when
    /// nil); when that fails this throws and nothing changed. Returns false when a newer swap started meanwhile;
    /// that one settles `session`.
    private func swapToken(_ token: SpotifyToken?, userID: String?, accountID: String?) async throws -> Bool {
        swapEpoch &+= 1
        let epoch = swapEpoch
        let before = session.identity
        session = session.next(.changing)
        swapsInFlight += 1
        defer { swapsInFlight -= 1 }
        let applied: Bool
        do {
            applied = try await service.api.setToken(token, userID: userID, epoch: epoch)
        } catch {
            if epoch == swapEpoch { session = session.next(before) }
            throw error
        }
        guard applied, epoch == swapEpoch else { return false }
        session = session.next(token == nil ? .signedOut : .account(id: accountID))
        return true
    }

    /// Records who the API's token belongs to without swapping it (launch found the account, or a refresh found it
    /// revoked). A swap in progress settles `session` itself.
    private func settleSession(_ identity: ProviderSession.Identity) {
        guard swapsInFlight == 0, session.identity != identity else { return }
        session = session.next(identity)
    }

    nonisolated static func saveFailure(_ error: any Error) -> String {
        "Couldn't save the sign-in to the Keychain. \(error.localizedDescription)"
    }

    /// The redirect URI to register in the listener's own Spotify app.
    public var redirectURI: String { redirect.uri }
    public var hasClientID: Bool { !clientID.isEmpty }
    /// False only when the listener chose their own Client ID but hasn't pasted one.
    public var canSignIn: Bool { !usesOwnClientID || hasClientID }

    /// The client and redirect the next sign-in uses.
    var signInClient: (clientID: String, target: SpotifyRedirectTarget) {
        usesOwnClientID ? (clientID, redirect.target) : (SpotifyBuiltInClient.clientID, .builtIn)
    }

    // MARK: Account

    public func restoreSession() async {
        guard await service.api.hasToken else {
            settleSession(.signedOut)
            return
        }
        do {
            let account = try await service.me()
            settleSession(.account(id: account.id))
            saveAccount(account)
            authStatus = .signedIn(account)
        } catch ProviderError.notSignedIn {
            // Revoked. Deleting the saved token is best effort: if it fails, the next launch finds it revoked again.
            _ = try? await swapToken(nil, userID: nil, accountID: nil)
            saveAccount(nil)
            authStatus = .signedOut
            sessionDidChange?()
        } catch {
            // Offline or Spotify hiccup: stay signed in with what we knew; requests refresh the token when they can.
            // Without a saved account there is no id, and nothing is cached on disk for this session.
            let cached = Keychain.codable(AccountInfo.self, for: Keys.account) ?? AccountInfo(name: "Spotify")
            settleSession(.account(id: cached.id))
            authStatus = .signedIn(cached)
        }
    }

    /// Runs the full OAuth PKCE sign-in. Returns when it finishes, fails, or is cancelled (`cancelSignIn()`,
    /// a newer `signIn()`, or cancelling the calling task). A cancelled sign-in leaves `authStatus` as it was.
    public func signIn() async {
        guard canSignIn else {
            authStatus = .failed(SpotifyAuthError.missingClientID.localizedDescription)
            return
        }
        let previous = statusBeforeSignIn ?? authStatus
        abandonSignIn()
        let generation = signInGeneration
        statusBeforeSignIn = previous.isSignedIn ? previous : .signedOut
        authStatus = .signingIn
        let (clientID, target) = signInClient
        let ownClient = usesOwnClientID
        let task = Task { await self.runSignIn(clientID: clientID, target: target, ownClient: ownClient, generation: generation) }
        signInTask = task
        // Cancelling the caller cancels the sign-in too; `runSignIn` then restores `authStatus`.
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func runSignIn(clientID: String, target: SpotifyRedirectTarget, ownClient: Bool, generation: Int) async {
        let pkce = PKCE()
        let state = PKCE.randomState()
        do {
            let response = try await authorize(target) { redirectURI in
                SpotifyAuthConfig(clientID: clientID, redirectURI: redirectURI).authorizeURL(pkce: pkce, state: state)
            }
            try requireSignIn(generation)
            let config = SpotifyAuthConfig(clientID: clientID, redirectURI: response.redirectURI)
            let code = try SpotifyAuthConfig.code(fromRedirect: response.callback, expectedState: state)
            let token = try await SpotifyAuthService(transport: transport).exchange(code: code, verifier: pkce.verifier, config: config)
            try requireSignIn(generation)
            // Check the account on a throwaway client so nothing shared changes until the sign-in commits.
            let box = clientIDBox
            let probe = SpotifyAPI(transport: transport, tokenStore: MemoryTokenStore(token), clientID: { box.get() })
            let account = try await SpotifyService(api: probe).me()
            let userID = await probe.userID
            try requireSignIn(generation)

            // Commit. From here Cancel can't undo it (`finishSignIn` is synchronous); `authStatus` stays
            // `.signingIn` until the API holds the new token, so nothing is shown as the new account early.
            let before = statusBeforeSignIn ?? .signedOut
            finishSignIn()
            do {
                // False: signed out or replaced meanwhile; whoever did that set `authStatus`.
                guard try await swapToken(token, userID: userID, accountID: account.id ?? userID) else { return }
            } catch {
                // The Keychain didn't take the token: nothing changed, and the sign-in reports it.
                if statusBeforeSignIn == nil { authStatus = before.isSignedIn ? before : .failed(Self.saveFailure(error)) }
                return
            }
            saveAccount(account)
            // A newer sign-in that started meanwhile goes back to this account if it's cancelled.
            if statusBeforeSignIn != nil { statusBeforeSignIn = .signedIn(account) } else { authStatus = .signedIn(account) }
            sessionDidChange?()
        } catch {
            // Cancelled or superseded: whoever did that already restored `authStatus`.
            guard generation == signInGeneration, statusBeforeSignIn != nil else { return }
            if Task.isCancelled || error is CancellationError || (error as? SpotifyAuthError) == .cancelled {
                cancelSignIn()
            } else {
                finishSignIn()
                authStatus = .failed(Self.explain(error, ownClient: ownClient))
            }
        }
    }

    /// Throws `CancellationError` once sign-in `generation` was cancelled or replaced.
    private func requireSignIn(_ generation: Int) throws {
        guard generation == signInGeneration, statusBeforeSignIn != nil, !Task.isCancelled else { throw CancellationError() }
    }

    /// Stops any pending sign-in (browser, token exchange, `/me`) so its results are ignored. Leaves `authStatus` alone.
    private func abandonSignIn() {
        signInGeneration &+= 1
        signInTask?.cancel()
        signInTask = nil
    }

    private func finishSignIn() {
        statusBeforeSignIn = nil
        signInTask = nil
    }

    /// Cancels a pending sign-in and puts `authStatus` back to what it was before (normally `.signedOut`).
    /// Does nothing once the sign-in has committed.
    public func cancelSignIn() {
        guard let previous = statusBeforeSignIn else { return }
        abandonSignIn()
        statusBeforeSignIn = nil
        authStatus = previous
    }

    /// Signs out. When the saved token can't be deleted it stays signed in; `trySignOut` reports that.
    public func signOut() async {
        try? await trySignOut()
    }

    /// Deletes the saved token first: if the Keychain refuses, this throws and the session stays as it was, so the
    /// app never looks signed out while the next launch would sign back in.
    public func trySignOut() async throws {
        cancelSignIn()
        guard try await swapToken(nil, userID: nil, accountID: nil) else { return }
        engine.stop()
        saveAccount(nil)
        authStatus = .signedOut
        sessionDidChange?()
    }

    /// Turns sign-in errors into something actionable. Development-mode advice applies only to the listener's own app.
    nonisolated static func explain(_ error: any Error, ownClient: Bool = true) -> String {
        switch error as? ProviderError {
        case .server(403, let message)? where ownClient:
            if message.localizedCaseInsensitiveContains("not registered") || message.localizedCaseInsensitiveContains("developer dashboard") {
                return "This Spotify account isn't on your app's user list. Add it under User Management in the Spotify developer dashboard."
            }
            return "Spotify refused the request (403). Development-mode apps need the app owner to have Premium. \(message)"
        case .server(403, let message)?:
            return "Spotify refused the request (403): \(message). Try again later, or sign in with your own Client ID (Settings › Spotify › Advanced)."
        case .rateLimited? where !ownClient:
            return "Spotify is turning away requests from \(ProductInfo.name) right now. Try again in a few minutes, or sign in with your own Client ID (Settings › Spotify › Advanced)."
        default:
            if case SpotifyAuthError.authorization(let reason)? = error as? SpotifyAuthError, ownClient {
                return "Spotify didn't finish the sign-in (\(reason)). Check that your Spotify app's redirect URI matches the one in Settings exactly."
            }
            return error.localizedDescription
        }
    }

    public func makeSignInView(onFinish: @escaping @MainActor () -> Void) -> AnyView {
        AnyView(SpotifySignInView(provider: self, onFinish: onFinish).onDisappear { [weak self] in self?.cancelSignIn() })
    }

    public func makeSettingsView() -> AnyView {
        AnyView(SpotifySettingsView(provider: self))
    }

    // MARK: Browse

    public func home() async throws -> [Shelf] {
        try requireSignIn()
        return try await service.home()
    }

    public func explore() async throws -> [Shelf] {
        try requireSignIn()
        return try await service.explore()
    }

    public func shelf(moreToken: String) async throws -> Shelf {
        try requireSignIn()
        return try await service.shelf(moreToken: moreToken)
    }

    // MARK: Search

    public func search(_ query: String, scope: SearchScope) async throws -> SearchResults {
        try requireSignIn()
        let results = try await service.search(query, scope: scope)
        rememberSearch(query)
        return results
    }

    /// Spotify has no suggestion endpoint: matching recent searches first, then names from a small live search.
    public func searchSuggestions(_ query: String) async throws -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let recent = recentSearches.filter { q.isEmpty || $0.localizedCaseInsensitiveContains(q) }
        guard !q.isEmpty, authStatus.isSignedIn else { return Array(recent.prefix(8)) }
        let live = (try? await service.suggestions(q)) ?? []
        var seen = Set<String>()
        return (recent + live).filter { seen.insert($0.lowercased()).inserted }.prefix(8).map { $0 }
    }

    private func rememberSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return }
        recentSearches.removeAll { $0.caseInsensitiveCompare(q) == .orderedSame }
        recentSearches.insert(q, at: 0)
        recentSearches = Array(recentSearches.prefix(20))
        defaults.set(recentSearches, forKey: Keys.recentSearches)
    }

    // MARK: Entities

    public func album(id: String) async throws -> AlbumDetail {
        try requireSignIn()
        return try await service.album(id: id)
    }

    public func artist(id: String) async throws -> ArtistDetail {
        try requireSignIn()
        return try await service.artist(id: id)
    }

    public func playlist(id: String) async throws -> PlaylistDetail {
        try requireSignIn()
        return try await service.playlist(id: id)
    }

    public func playlistTracks(continuation: String) async throws -> Page<Track> {
        try requireSignIn()
        return try await service.playlistTracks(continuation: continuation)
    }

    /// The playlist and its pages are cached for 60 s (`SpotifyService.playlist`); a playlist edit's reads skip that.
    public func uncachedPlaylist(id: String) async throws -> PlaylistDetail {
        try requireSignIn()
        return try await service.playlist(id: id, fresh: true)
    }

    public func uncachedPlaylistTracks(continuation: String) async throws -> Page<Track> {
        try requireSignIn()
        return try await service.playlistTracks(continuation: continuation, fresh: true)
    }

    // MARK: Library

    public func library(_ kind: LibraryKind, continuation: String?) async throws -> Page<MediaItem> {
        try requireSignIn()
        return try await service.library(kind, continuation: continuation)
    }

    public func setLiked(_ track: Track, liked: Bool) async throws {
        try requireSignIn()
        try await service.setInLibrary([SpotifyMapping.uri(track)], saved: liked)
    }

    public func isLiked(_ track: Track) async throws -> Bool {
        try requireSignIn()
        return try await service.contains([SpotifyMapping.uri(track)]).first ?? false
    }

    /// Songs are liked, albums saved, playlists and artists followed. All go through `/me/library`.
    public func setSaved(_ item: MediaItem, saved: Bool) async throws {
        try requireSignIn()
        try await service.setInLibrary([SpotifyMapping.uri(item)], saved: saved)
    }

    public func createPlaylist(title: String, description: String?) async throws -> Playlist {
        try requireSignIn()
        return try await service.createPlaylist(title: title, description: description)
    }

    public func add(_ tracks: [Track], toPlaylist playlistID: String) async throws {
        try requireSignIn()
        guard !tracks.isEmpty else { return }
        try await service.add(tracks.map(SpotifyMapping.uri), toPlaylist: playlistID)
    }

    public func remove(_ tracks: [Track], fromPlaylist playlistID: String) async throws {
        try requireSignIn()
        guard !tracks.isEmpty else { return }
        try await service.remove(tracks.map(SpotifyMapping.uri), fromPlaylist: playlistID)
    }

    public func createPlaylist(title: String, description: String?, as account: PlaylistWriteAccount) async throws -> Playlist {
        try requireSignIn()
        return try await service.createPlaylist(title: title, description: description, as: try writeBinding(account))
    }

    public func add(_ tracks: [Track], toPlaylist playlistID: String, as account: PlaylistWriteAccount) async throws {
        try requireSignIn()
        guard !tracks.isEmpty else { return }
        try await service.add(tracks.map(SpotifyMapping.uri), toPlaylist: playlistID, as: try writeBinding(account))
    }

    public func remove(_ tracks: [Track], fromPlaylist playlistID: String, as account: PlaylistWriteAccount) async throws {
        try requireSignIn()
        guard !tracks.isEmpty else { return }
        try await service.remove(tracks.map(SpotifyMapping.uri), fromPlaylist: playlistID, as: try writeBinding(account))
    }

    public func insert(_ tracks: [Track], intoPlaylist playlistID: String, at position: Int, as account: PlaylistWriteAccount) async throws {
        try requireSignIn()
        guard !tracks.isEmpty else { return }
        try await service.insert(tracks.map(SpotifyMapping.uri), intoPlaylist: playlistID, at: position, as: try writeBinding(account))
    }

    /// Checked here on the main actor (the session holds the account, no swap under way), then carried to the API actor,
    /// which checks it again where it picks the token: a swap that lands in between stops the write there.
    private func writeBinding(_ account: PlaylistWriteAccount) throws -> SpotifyWriteBinding {
        guard case .account(let id) = session.identity, account.accountID.map({ $0 == id }) ?? (session == account.session) else {
            throw PlaylistEditError.accountChanged
        }
        return SpotifyWriteBinding(userID: account.accountID, epoch: swapEpoch)
    }

    /// Spotify's playlist item requests take 100 songs each (`SpotifyService.remove`/`insert` split there too).
    public var playlistEditBatchSize: Int? { 100 }

    public func insert(_ tracks: [Track], intoPlaylist playlistID: String, at position: Int) async throws {
        try requireSignIn()
        guard !tracks.isEmpty else { return }
        try await service.insert(tracks.map(SpotifyMapping.uri), intoPlaylist: playlistID, at: position)
    }

    // MARK: Playback support

    public func radio(seed: Track) async throws -> [Track] {
        try requireSignIn()
        return try await service.radio(seed: seed)
    }

    public func radio(seedID: String) async throws -> [Track] {
        try requireSignIn()
        return try await service.radio(seedID: seedID)
    }

    /// From LRCLIB; Spotify has no public lyrics API.
    public func lyrics(for track: Track) async throws -> Lyrics? {
        try await lyricsClient.lyrics(
            title: track.title,
            artist: track.artists.first?.name ?? "",
            album: track.album?.title,
            duration: track.duration
        )
    }

    private func requireSignIn() throws {
        guard authStatus.isSignedIn else { throw ProviderError.notSignedIn }
    }
}

/// Lets the API actor read the Client ID without hopping to the main actor.
final class ClientIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String
    init(_ value: String) { self.value = value }
    func get() -> String { lock.withLock { value } }
    func set(_ value: String) { lock.withLock { self.value = value } }
}
