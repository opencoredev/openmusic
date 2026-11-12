import Foundation
import MedleyCore
import Observation
import SwiftUI

/// YouTube Music through InnerTube, the API music.youtube.com itself uses.
///
/// All network and JSON work happens on `InnerTubeClient` / `YouTubeStreamResolver` (actors);
/// this class only publishes results on the main actor.
@MainActor
@Observable
public final class YouTubeMusicProvider: MusicProvider {
    public let id: ProviderID = .youtubeMusic
    public private(set) var authStatus: AuthStatus = .signedOut
    /// Who requests go out as: changes only around a swap of the client's credentials (`swapCredentials`), so it
    /// is right even while `authStatus` says `.signingIn` and the client still holds the previous account's cookies.
    public private(set) var session = ProviderSession(generation: 0, identity: .signedOut)
    /// Bumped by every `swapCredentials`; only the newest one settles `session`.
    @ObservationIgnored private var swapEpoch = 0

    @ObservationIgnored let client: InnerTubeClient
    @ObservationIgnored public let streamResolver: YouTubeStreamResolver
    @ObservationIgnored public let playbackEngine: any PlaybackEngine
    /// Like state learned this session (from `isLiked` or set by `setLiked`), keyed by videoId.
    @ObservationIgnored private var likeCache: [String: Bool] = [:]

    // Sign-in in progress. Checked before every credential write and `authStatus` change, so a cancelled
    // sign-in (sheet closed while cookies were still being checked) can't sign in afterwards.
    @ObservationIgnored private var signInGeneration = 0
    /// `authStatus` before the pending sign-in started; restored when it's cancelled. Nil when none is pending.
    @ObservationIgnored private var statusBeforeSignIn: AuthStatus?
    /// Checks cookies by fetching the account they belong to. A seam for tests.
    @ObservationIgnored private let validateAccount: @Sendable (YTMCredentials) async throws -> AccountInfo
    /// Called after every sign-in (including a channel switch), sign-out, and a restore that found the cookies
    /// revoked. `YouTubeMusicSignInTransfer` listens here so sign-ins sync to the other devices. Cookie rotations
    /// don't call it (see the transfer).
    @ObservationIgnored var sessionDidChange: (@MainActor () -> Void)?

    public convenience init() {
        self.init(validateAccount: { creds in
            // A throwaway client that never writes rotated cookies to the Keychain, so checking cookies
            // changes nothing until the sign-in commits.
            let probe = InnerTubeClient()
            await probe.setCredentials(creds, persist: false)
            return try await probe.account()
        })
    }

    init(validateAccount: @escaping @Sendable (YTMCredentials) async throws -> AccountInfo) {
        let client = InnerTubeClient()
        let resolver = YouTubeStreamResolver(client: client)
        self.client = client
        self.streamResolver = resolver
        self.playbackEngine = AVPlaybackEngine(resolver: resolver)
        self.validateAccount = validateAccount
    }

    public var capabilities: ProviderCapabilities {
        var caps: ProviderCapabilities = [.search, .home, .explore, .lyrics, .syncedLyrics, .radio, .playback]
        if authStatus.isSignedIn { caps.formUnion([.library, .like, .playlistEditing, .follow]) }
        return caps
    }

    // MARK: Account

    public func restoreSession() async {
        guard let creds = YTMCredentials.load() else { return }
        _ = try? await swapCredentials(creds, persist: true, store: false)
        let cached = Keychain.codable(AccountInfo.self, for: YTMCredentials.accountKey).map { Self.identified($0, creds) }
        if let cached { authStatus = .signedIn(cached) }
        do {
            let info = Self.identified(try await client.account(), creds)
            Keychain.setCodable(info, for: YTMCredentials.accountKey)
            authStatus = .signedIn(info)
        } catch ProviderError.notSignedIn {
            // Cookies expired or were revoked. Deleting them is best effort: if it fails, the next launch finds
            // them revoked again.
            _ = try? await swapCredentials(nil, persist: true, store: false)
            try? YTMCredentials.clear()
            authStatus = .signedOut
            sessionDidChange?()
        } catch {
            // Offline at launch: keep the cached account so the library UI stays available.
            if cached == nil { authStatus = .signedIn(AccountInfo(name: "YouTube Music", id: Self.accountID(creds))) }
        }
    }

    /// The immutable id caches key this account by: the datasync id the account switcher gave when it was picked
    /// (`delegatedSessionId||userSessionId` for a brand channel, the Google account's own id otherwise), which names
    /// the Google account and the channel. Never the handle or email, which can change or move to another account.
    /// Nil when the credentials don't carry one (a pasted cookie header, or a sign-in saved before it was kept).
    nonisolated static func accountID(_ creds: YTMCredentials) -> String? {
        guard let datasyncId = creds.datasyncId, datasyncId.contains(where: { $0 != "|" && !$0.isWhitespace }) else { return nil }
        return "datasync:" + datasyncId
    }

    /// `info` with `id` set from the credentials it belongs to (`accountID`).
    nonisolated static func identified(_ info: AccountInfo, _ creds: YTMCredentials) -> AccountInfo {
        var info = info
        info.id = accountID(creds)
        return info
    }

    /// Hands `creds` to the client, with `session` `.changing` until the client has them. With `store`, the client
    /// first saves them to the Keychain (deletes when nil); when that fails this throws and nothing changed.
    /// Returns false when a newer swap started meanwhile; that one settles `session`.
    private func swapCredentials(_ creds: YTMCredentials?, persist: Bool, store: Bool) async throws -> Bool {
        swapEpoch &+= 1
        let epoch = swapEpoch
        let before = session.identity
        session = session.next(.changing)
        let applied: Bool
        do {
            applied = try await client.commit(creds, persist: persist, store: store, epoch: epoch)
        } catch {
            if epoch == swapEpoch { session = session.next(before) }
            throw error
        }
        guard applied, epoch == swapEpoch else { return false }
        session = session.next(creds.map { .account(id: Self.accountID($0)) } ?? .signedOut)
        return true
    }

    /// Signs in with a `Cookie:` header copied from a signed-in browser session (advanced fallback).
    public func signIn(cookieHeader: String, persist: Bool = true) async throws {
        guard let creds = YTMCredentials(cookieHeader: cookieHeader) else {
            throw ProviderError.decoding("The cookie header needs SAPISID (or __Secure-3PAPISID) and SID cookies from music.youtube.com.")
        }
        try await signIn(credentials: creds, persist: persist)
    }

    /// Credentials (from a browser login, or from the in-app Google sign-in) held between `prepareAccounts` and the
    /// commit, with a name to put in an error. In memory only.
    @ObservationIgnored private var preparedCredentials: (credentials: YTMCredentials, sourceName: String)?
    /// Bumped by each prepare and by `discardPreparedSignIn`, so a slow prepare the user already cancelled can't
    /// clobber a newer one's held credentials.
    @ObservationIgnored private var prepareGeneration = 0

    #if os(macOS)
    /// Reads the browser login (one keychain prompt), then lists the accounts and channels it can use.
    public func prepareBrowserSignIn(from login: BrowserLogin, maxIndex: Int = 7) async throws -> BrowserAccountList {
        prepareGeneration &+= 1
        let generation = prepareGeneration
        let creds = try await Task.detached(priority: .userInitiated) {
            try BrowserLogins.credentials(from: login)
        }.value
        guard generation == prepareGeneration, !Task.isCancelled else { throw CancellationError() }
        return try await prepareAccounts(credentials: creds, sourceName: login.browser.name, generation: generation, maxIndex: maxIndex)
    }
    #endif

    /// Lists every account and channel reachable from `credentials`: each Google account signed into that session
    /// and each channel / brand account under it, the way YouTube's account switcher shows them. Every entry is
    /// confirmed by a real request (and a channel is kept only if selecting it actually changes the account), so the
    /// picker can't mislabel one or offer a channel it can't switch to. The credentials are held for `commitSignIn`.
    ///
    /// With `preferSelected`, the identity the session already acts as (the channel just picked on YouTube's own
    /// "Choose a channel" page) comes back alone, once confirmed, so the caller signs straight in to it. The full
    /// list is the fallback when nothing is selected or the selection can't be confirmed.
    func prepareAccounts(credentials creds: YTMCredentials, sourceName: String, preferSelected: Bool = false) async throws -> BrowserAccountList {
        prepareGeneration &+= 1
        return try await prepareAccounts(credentials: creds, sourceName: sourceName, generation: prepareGeneration,
                                         maxIndex: 7, preferSelected: preferSelected)
    }

    private func prepareAccounts(credentials creds: YTMCredentials, sourceName: String, generation: Int, maxIndex: Int,
                                 preferSelected: Bool = false) async throws -> BrowserAccountList {
        guard generation == prepareGeneration, !Task.isCancelled else { throw CancellationError() }
        preparedCredentials = (creds, sourceName)
        let probe = InnerTubeClient()
        await probe.setCredentials(creds, persist: false)

        // Candidate identities come from the account switcher (every Google account and channel). A network or
        // server error propagates — not treated as "no channels". Only an empty/unreadable 200 body falls back to a
        // plain per-authUser sweep, which can't prove a profile has no other channels, so its result is not
        // authoritative and a single entry is never auto-committed.
        let listed = try await probe.accountIdentities()
        let fromSwitcher = !listed.isEmpty

        // Only when the session holds one Google account: the web sign-in's cookies don't say which account the
        // page landed on, so with several, the switcher (asked as authUser 0) could report another account's pick.
        if preferSelected, Set(listed.map(\.authUser)).count == 1, let chosen = listed.first(where: \.isSelected) {
            // Confirm against the account's default identity too, so an ignored channel selector can't pass.
            let subset = chosen.delegatedSessionId == nil ? [chosen] : [AccountIdentity(authUser: chosen.authUser), chosen]
            let confirmed = try await Self.confirmedAccounts(subset, credentials: creds, sweep: false)
            guard generation == prepareGeneration, !Task.isCancelled else { throw CancellationError() }
            if let match = confirmed.first(where: { $0.identity.selectorKey == chosen.selectorKey }) {
                return BrowserAccountList(accounts: [match], authoritative: true)
            }
        }

        // The selected identity first, then the switcher's order.
        let candidates = fromSwitcher
            ? listed.filter(\.isSelected) + listed.filter { !$0.isSelected }
            : (0...maxIndex).map { AccountIdentity(authUser: $0) }
        let accounts = try await Self.confirmedAccounts(candidates, credentials: creds, sweep: !fromSwitcher)
        guard generation == prepareGeneration, !Task.isCancelled else { throw CancellationError() }
        if accounts.isEmpty { throw BrowserLoginError.notSignedIn(browser: sourceName) }
        return BrowserAccountList(accounts: accounts, authoritative: fromSwitcher)
    }

    /// Resolves each candidate with a real `account_menu` request (a few at a time, each on its own throwaway client)
    /// and keeps the ones that are real, distinct, and actually selectable. `sweep` marks the bare authUser sweep,
    /// which stops at the first empty index.
    private static func confirmedAccounts(_ candidates: [AccountIdentity], credentials creds: YTMCredentials,
                                          sweep: Bool) async throws -> [BrowserAccount] {
        // One request per distinct selector.
        var seenSelectors: Set<String> = []
        let unique = candidates.filter { seenSelectors.insert($0.selectorKey).inserted }

        var infos = [AccountInfo?](repeating: nil, count: unique.count)
        if sweep {
            // The fallback sweep goes one index at a time and stops at the first gap, so a failing request past
            // the last real account can't sink the sign-in.
            let client = InnerTubeClient()
            for (index, candidate) in unique.enumerated() {
                try Task.checkCancellation()
                var scoped = creds
                scoped.authUser = candidate.authUser
                scoped.datasyncId = candidate.datasyncId
                await client.setCredentials(scoped, persist: false)
                do {
                    infos[index] = try await client.account()
                } catch ProviderError.notSignedIn {
                    if candidate.authUser > 0 { break }
                }
            }
        }
        let workers = sweep ? 0 : min(6, unique.count)
        try await withThrowingTaskGroup(of: [(Int, AccountInfo?)].self) { group in
            for worker in 0..<workers {
                group.addTask {
                    let client = InnerTubeClient()
                    var out: [(Int, AccountInfo?)] = []
                    for index in stride(from: worker, to: unique.count, by: workers) {
                        try Task.checkCancellation()
                        var scoped = creds
                        scoped.authUser = unique[index].authUser
                        scoped.datasyncId = unique[index].datasyncId
                        await client.setCredentials(scoped, persist: false)
                        do {
                            out.append((index, try await client.account()))
                        } catch ProviderError.notSignedIn {
                            out.append((index, nil))  // No account at this selector.
                        }
                    }
                    return out
                }
            }
            for try await batch in group {
                for (index, info) in batch { infos[index] = info }
            }
        }

        struct Resolved { let candidate: AccountIdentity; let info: AccountInfo }
        var resolved: [Resolved] = []
        for (index, candidate) in unique.enumerated() {
            guard let info = infos[index] else {
                // On the bare authUser sweep, stop after the first gap.
                if sweep, candidate.authUser > 0 { break }
                continue
            }
            resolved.append(Resolved(candidate: candidate, info: info))
        }

        // The default (no channel) identity for each Google account, to prove a channel selector actually took.
        func identityKey(_ info: AccountInfo) -> String { (info.detail ?? info.name).lowercased() }
        var baseByAuthUser: [Int: String] = [:]
        for entry in resolved where entry.candidate.delegatedSessionId == nil {
            baseByAuthUser[entry.candidate.authUser] = identityKey(entry.info)
        }

        var accounts: [BrowserAccount] = []
        var seen: Set<String> = []
        for entry in resolved {
            // A channel whose selectors were ignored comes back as its account's default identity — so if it matches
            // the base, Medley can't switch to it; drop it rather than list a channel it can't actually use.
            if entry.candidate.delegatedSessionId != nil,
               let base = baseByAuthUser[entry.candidate.authUser], base == identityKey(entry.info) {
                continue
            }
            // Dedupe by the resolved identity when a handle/email pins it down; otherwise by the selector, so two
            // genuinely different channels that happen to share a display name both survive.
            let dedupe = entry.info.detail != nil ? "r:" + identityKey(entry.info) : "s:" + entry.candidate.selectorKey
            guard seen.insert(dedupe).inserted else { continue }
            // Prefer the confirmed name/photo from the real request; keep the switcher's as a fallback.
            let confirmed = AccountInfo(name: entry.info.name,
                                        avatar: entry.info.avatar ?? entry.candidate.photo,
                                        detail: entry.info.detail ?? entry.candidate.listedByline)
            accounts.append(BrowserAccount(identity: entry.candidate, info: confirmed))
        }
        return accounts
    }

    /// Commits the sign-in for the chosen account, using the credentials held by the last prepare.
    public func commitBrowserSignIn(_ account: BrowserAccount) async throws {
        guard var creds = preparedCredentials?.credentials else { throw CancellationError() }
        let sourceName = preparedCredentials?.sourceName ?? "YouTube"
        creds.authUser = account.identity.authUser
        creds.datasyncId = account.identity.datasyncId
        try Task.checkCancellation()
        do {
            try await signIn(credentials: creds, persist: true)
            preparedCredentials = nil
        } catch ProviderError.notSignedIn {
            throw BrowserLoginError.notSignedIn(browser: sourceName)
        }
    }

    /// Diagnostics (`medley-probe ytm accounts`): runs the real prepare step on a `Cookie:` header, then signs in to
    /// the first account it offers without touching the Keychain. Returns what the picker would have shown.
    public func diagnosticSignIn(cookieHeader: String, preferSelected: Bool) async throws -> BrowserAccountList {
        guard let creds = YTMCredentials(cookieHeader: cookieHeader) else { throw ProviderError.notSignedIn }
        let found = try await prepareAccounts(credentials: creds, sourceName: "probe", preferSelected: preferSelected)
        guard let first = found.accounts.first, var chosen = preparedCredentials?.credentials else { return found }
        chosen.authUser = first.identity.authUser
        chosen.datasyncId = first.identity.datasyncId
        preparedCredentials = nil
        try await signIn(credentials: chosen, persist: false)
        return found
    }

    /// Drops the held login (sheet closed or cancelled), and invalidates any prepare still in flight.
    public func discardPreparedSignIn() {
        prepareGeneration &+= 1
        preparedCredentials = nil
    }

    /// Checks the cookies, then signs in with them. Throws `CancellationError` if `cancelSignIn()`, a newer
    /// sign-in, or cancelling the calling task got there first; `authStatus` is then left as it was before.
    func signIn(credentials creds: YTMCredentials, persist: Bool) async throws {
        let previous = statusBeforeSignIn ?? authStatus
        signInGeneration &+= 1
        let generation = signInGeneration
        statusBeforeSignIn = previous.isSignedIn ? previous : .signedOut
        authStatus = .signingIn

        let info: AccountInfo
        do {
            info = try await validateAccount(creds)
        } catch {
            guard isPending(generation) else { throw CancellationError() }
            if Task.isCancelled || error is CancellationError {
                cancelSignIn()
                throw CancellationError()
            }
            // The current session (if any) was never touched, so a signed-in listener stays signed in.
            let before = statusBeforeSignIn ?? .signedOut
            statusBeforeSignIn = nil
            authStatus = before.isSignedIn ? before : .failed(error.localizedDescription)
            throw error
        }
        guard isPending(generation) else { throw CancellationError() }
        if Task.isCancelled {
            cancelSignIn()
            throw CancellationError()
        }

        // Commit. From here Cancel can't undo it (`statusBeforeSignIn` is cleared synchronously); `authStatus`
        // stays `.signingIn` until the client holds the new cookies, so nothing is shown as the new account early.
        let before = statusBeforeSignIn ?? .signedOut
        statusBeforeSignIn = nil
        likeCache.removeAll()
        let account = Self.identified(info, creds)
        do {
            guard try await swapCredentials(creds, persist: persist, store: persist) else { throw CancellationError() }
        } catch is CancellationError {
            // Signed out or replaced while committing; whoever did that set `authStatus`.
            throw CancellationError()
        } catch {
            // The Keychain didn't take the cookies: nothing changed, and the sign-in reports it.
            if statusBeforeSignIn == nil { authStatus = before.isSignedIn ? before : .failed(Self.saveFailure(error)) }
            throw error
        }
        if persist { Keychain.setCodable(account, for: YTMCredentials.accountKey) }
        // A newer sign-in that started meanwhile goes back to this account if it's cancelled.
        if statusBeforeSignIn != nil { statusBeforeSignIn = .signedIn(account) } else { authStatus = .signedIn(account) }
        sessionDidChange?()
    }

    nonisolated static func saveFailure(_ error: any Error) -> String {
        "Couldn't save the sign-in to the Keychain. \(error.localizedDescription)"
    }

    /// Commits a sign-in another device made (`YouTubeMusicSignInTransfer`), already checked by the transfer.
    /// Doesn't call `sessionDidChange`: the transfer reports the change itself.
    /// Throws, changing nothing, when the Keychain didn't take the cookies.
    func adoptTransferredSignIn(_ creds: YTMCredentials, info: AccountInfo, persist: Bool) async throws {
        cancelSignIn()
        guard try await swapCredentials(creds, persist: persist, store: persist) else { throw CancellationError() }
        likeCache.removeAll()
        let account = Self.identified(info, creds)
        if persist { Keychain.setCodable(account, for: YTMCredentials.accountKey) }
        authStatus = .signedIn(account)
    }

    /// The session's current cookies and channel, nil when signed out.
    var currentCredentials: YTMCredentials? {
        get async { await client.currentCredentials }
    }

    private func isPending(_ generation: Int) -> Bool {
        generation == signInGeneration && statusBeforeSignIn != nil
    }

    /// Abandons a pending sign-in and puts `authStatus` back to what it was (normally `.signedOut`).
    /// Does nothing once the sign-in has committed.
    public func cancelSignIn() {
        guard let previous = statusBeforeSignIn else { return }
        signInGeneration &+= 1
        statusBeforeSignIn = nil
        authStatus = previous
    }

    public func makeSignInView(onFinish: @escaping @MainActor () -> Void) -> AnyView {
        AnyView(YTMSignInView(provider: self, onFinish: onFinish))
    }

    public func makeSettingsView() -> AnyView {
        AnyView(YTMSettingsView(provider: self))
    }

    /// Signs out. When the saved cookies can't be deleted it stays signed in; `trySignOut` reports that.
    public func signOut() async {
        try? await trySignOut()
    }

    /// Deletes the saved cookies first: if the Keychain refuses, this throws and the session stays as it was, so the
    /// app never looks signed out while the next launch would sign back in.
    public func trySignOut() async throws {
        cancelSignIn()
        guard try await swapCredentials(nil, persist: true, store: true) else { return }
        likeCache.removeAll()
        await YTMSignInWebView.clearWebsiteData()
        authStatus = .signedOut
        sessionDidChange?()
    }

    // MARK: Browse

    public func home() async throws -> [Shelf] {
        let signedIn = isSignedIn
        let shelves = try await client.home()
        return signedIn ? shelves : Self.anonymousHome(shelves)
    }

    /// Shelves that come from a listener's own history. Signed out, YouTube can still send some for this Mac's
    /// visitor id after a few plays; Home leaves them out then, so a signed-out first launch shows the charts, hits
    /// and moods instead of a "Listen again" made from someone's earlier listening.
    nonisolated static let personalShelfTitles = ["listen again", "your mixes", "mixed for you", "liked music", "your likes",
                                                  "from your library", "recommended for you", "your favorites", "recently played"]

    /// `shelves` without the personal ones, or the Liked Music playlist (`LM`) anywhere.
    nonisolated static func anonymousHome(_ shelves: [Shelf]) -> [Shelf] {
        shelves.compactMap { shelf in
            let title = shelf.title.lowercased()
            if personalShelfTitles.contains(where: title.contains) { return nil }
            var kept = shelf
            kept.items.removeAll { if case .playlist(let p) = $0 { p.providerID == "LM" } else { false } }
            return kept.items.isEmpty ? nil : kept
        }
    }
    public func explore() async throws -> [Shelf] { try await client.explore() }
    public func shelf(moreToken: String) async throws -> Shelf { try await client.shelf(moreToken: moreToken) }

    // MARK: Search

    public func search(_ query: String, scope: SearchScope) async throws -> SearchResults {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return SearchResults() }
        return try await client.search(q, scope: scope)
    }

    public func searchSuggestions(_ query: String) async throws -> [String] {
        try await richSearchSuggestions(query).queries
    }

    public func richSearchSuggestions(_ query: String) async throws -> SearchSuggestions {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return SearchSuggestions() }
        return try await client.suggestions(q)
    }

    /// Search rows and top-result cards often leave out the album. The watch queue's byline has it.
    public func linkedTrack(_ track: Track) async throws -> Track {
        guard track.album?.id == nil || !track.artists.contains(where: { $0.id != nil }) || track.duration == nil else { return track }
        guard let linked = try await client.linkedTrack(videoId: track.providerID) else { return track }
        return track.filling(from: linked)
    }

    // MARK: Entities

    public func album(id: String) async throws -> AlbumDetail { try await client.album(id: id) }
    public func artist(id: String) async throws -> ArtistDetail { try await client.artist(id: id) }
    public func playlist(id: String) async throws -> PlaylistDetail { try await client.playlist(id: id) }
    public func playlistTracks(continuation: String) async throws -> Page<Track> { try await client.playlistTracks(continuation: continuation) }

    // MARK: Library

    public func library(_ kind: LibraryKind, continuation: String?) async throws -> Page<MediaItem> {
        try await client.library(kind, continuation: continuation)
    }

    public func setLiked(_ track: Track, liked: Bool) async throws {
        try await client.rate(videoId: track.providerID, like: liked)
        likeCache[track.providerID] = liked
    }

    /// Asks the server once per track per session. (`Track.extra["likeStatus"]` is only a hint:
    /// signed-out and cached responses report every track as INDIFFERENT.)
    public func isLiked(_ track: Track) async throws -> Bool {
        guard authStatus.isSignedIn else { return false }
        if let known = likeCache[track.providerID] { return known }
        let liked = try await client.isLiked(videoId: track.providerID)
        likeCache[track.providerID] = liked
        return liked
    }

    public func setSaved(_ item: MediaItem, saved: Bool) async throws {
        switch item {
        case .track(let track):
            try await setLiked(track, liked: saved)
        case .album(let album):
            var playlistId = album.extra["playlistId"]
            if playlistId == nil { playlistId = try await client.album(id: album.providerID).album.extra["playlistId"] }
            guard let playlistId else { throw ProviderError.notSupported("Saving this album") }
            try await client.rate(playlistId: playlistId, like: saved)
        case .playlist(let playlist):
            guard playlist.extra["category"] == nil else { throw ProviderError.notSupported("Saving a category") }
            try await client.rate(playlistId: playlist.providerID, like: saved)
        case .artist(let artist):
            var channel = artist.extra["channelId"]
            if channel == nil { channel = try await client.artist(id: artist.providerID).artist.extra["channelId"] }
            try await client.subscribe(channelId: channel ?? artist.providerID, subscribe: saved)
        }
    }

    public func createPlaylist(title: String, description: String?) async throws -> Playlist {
        let id = try await client.createPlaylist(title: title, description: description)
        return Playlist(providerID: id, provider: .youtubeMusic, title: title, owner: authStatus.accountName, trackCount: 0, summary: description, isEditable: true)
    }

    public func add(_ tracks: [Track], toPlaylist playlistID: String) async throws {
        guard !tracks.isEmpty else { return }
        try await client.editPlaylist(playlistID, edits: tracks.map { .add(videoId: $0.providerID) })
    }

    /// Removes every copy of each song: a playlist lists a song it holds twice once (Medley's `PlaylistPager`), so
    /// Remove from Playlist means the song, not one entry. The playlist's entries are read from the service (all
    /// pages), since a row's own `setVideoId` names only its first entry and tracks from elsewhere (the queue) have
    /// none.
    public func remove(_ tracks: [Track], fromPlaylist playlistID: String) async throws {
        guard !tracks.isEmpty else { return }
        let edits = try Self.removalEdits(for: tracks, entries: try await entries(of: playlistID))
        guard !edits.isEmpty else { throw ProviderError.notFound }
        try await client.editPlaylist(playlistID, edits: edits)
    }

    public func createPlaylist(title: String, description: String?, as account: PlaylistWriteAccount) async throws -> Playlist {
        let id = try await client.createPlaylist(title: title, description: description, binding: try writeBinding(account))
        return Playlist(providerID: id, provider: .youtubeMusic, title: title, owner: authStatus.accountName, trackCount: 0, summary: description, isEditable: true)
    }

    public func add(_ tracks: [Track], toPlaylist playlistID: String, as account: PlaylistWriteAccount) async throws {
        guard !tracks.isEmpty else { return }
        let binding = try writeBinding(account)
        try await client.editPlaylist(playlistID, edits: tracks.map { .add(videoId: $0.providerID) }, binding: binding)
    }

    public func remove(_ tracks: [Track], fromPlaylist playlistID: String, as account: PlaylistWriteAccount) async throws {
        guard !tracks.isEmpty else { return }
        let binding = try writeBinding(account)
        let edits = try Self.removalEdits(for: tracks, entries: try await entries(of: playlistID))
        guard !edits.isEmpty else { throw ProviderError.notFound }
        try await client.editPlaylist(playlistID, edits: edits, binding: binding)
    }

    /// Checked here on the main actor (the session holds the account, no swap under way), then carried to the client,
    /// which checks it again where it picks the cookies: a swap that lands in between stops the write there.
    private func writeBinding(_ account: PlaylistWriteAccount) throws -> YTMWriteBinding {
        guard case .account(let id) = session.identity, account.accountID.map({ $0 == id }) ?? (session == account.session) else {
            throw PlaylistEditError.accountChanged
        }
        return YTMWriteBinding(accountID: account.accountID, epoch: swapEpoch)
    }

    /// One removal per entry (`setVideoId`) of each song in `entries`, the playlist's whole list in order: every copy.
    /// Throws `PlaylistEditError.unidentifiedCopies`, before anything is written, when a copy of one of the songs has
    /// no `setVideoId`: removing the rest would leave that copy behind while the notice said every copy went.
    nonisolated static func removalEdits(for tracks: [Track], entries: [Track]) throws -> [PlaylistEdit] {
        let wanted = Set(tracks.map(\.providerID))
        var seen = Set<String>()
        var edits: [PlaylistEdit] = []
        var unidentified = 0
        for entry in entries where wanted.contains(entry.providerID) {
            guard let setId = entry.extra["setVideoId"], !setId.isEmpty else { unidentified += 1; continue }
            if seen.insert(setId).inserted { edits.append(.remove(videoId: entry.providerID, setVideoId: setId)) }
        }
        if unidentified > 0 { throw PlaylistEditError.unidentifiedCopies(unidentified) }
        return edits
    }

    /// Upper bound on pages read to find a playlist's entries (YouTube caps a playlist at 5,000 songs, 100 a page).
    static let entryPageLimit = 60

    /// Every entry of the playlist, repeats included, from all its pages. Throws rather than return part of a list
    /// longer than `entryPageLimit` pages, so a removal never leaves a copy behind unsaid.
    private func entries(of playlistID: String) async throws -> [Track] {
        let detail = try await client.playlist(id: playlistID)
        var all = detail.tracks
        var token = detail.continuation
        var pages = 0
        while let next = token {
            guard pages < Self.entryPageLimit else { throw ProviderError.notSupported("Removing songs from a playlist this long") }
            let page = try await client.playlistTracks(continuation: next)
            all += page.items
            token = page.continuation
            pages += 1
        }
        return all
    }

    // MARK: Playback support

    public func radio(seed: Track) async throws -> [Track] { try await client.radio(videoId: seed.providerID) }
    public func radio(seedID: String) async throws -> [Track] { try await client.radio(seedID: seedID) }
    /// YouTube's own lyrics first. When they are missing or unsynced, try LRCLIB for synced lyrics.
    public func lyrics(for track: Track) async throws -> Lyrics? {
        // nil means a source has no lyrics for the song; a thrown error means it couldn't be asked (offline, server
        // error). When nothing is found and a source failed, throw, so callers don't cache an outage as "no lyrics".
        var failure: (any Error)?
        var native: Lyrics?
        do { native = try await client.lyrics(videoId: track.providerID) } catch { failure = error }
        if let native, native.isSynced { return native }
        if let artist = track.artists.first?.name {
            do {
                if let fallback = try await LRCLibClient().lyrics(title: track.title, artist: artist, album: track.album?.title, duration: track.duration),
                   fallback.isSynced || native == nil {
                    return fallback
                }
            } catch {
                failure = failure ?? error
            }
        }
        if native == nil, let failure { throw failure }
        return native
    }
}

// MARK: - Diagnostics (medley-probe)

extension YouTubeMusicProvider {
    /// Sends a raw WEB_REMIX request and returns the response as pretty-printed JSON. For `medley-probe ytm raw`.
    public func diagnosticRequest(endpoint: String, bodyJSON: String) async throws -> String {
        try await client.rawRequest(endpoint: endpoint, bodyJSON: bodyJSON)
    }

    /// Loads a browser login (without persisting), sends a raw request, and returns the response JSON object.
    /// For `medley-probe ytm account-shape`, which redacts it before printing. Does not change saved state.

}

extension AuthStatus {
    var accountName: String? {
        if case .signedIn(let info) = self { info.name } else { nil }
    }
}

extension Track {
    /// This track with the album and artist links another listing of the same song has.
    /// Keeps everything this track already knows (title, artwork, queue ids).
    func filling(from other: Track) -> Track {
        var t = self
        if t.album?.id == nil, let album = other.album, album.id != nil { t.album = album }
        if !t.artists.contains(where: { $0.id != nil }), other.artists.contains(where: { $0.id != nil }) { t.artists = other.artists }
        if t.duration == nil { t.duration = other.duration }
        return t
    }
}
