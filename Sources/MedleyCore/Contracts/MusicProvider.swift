import Foundation
import SwiftUI

public struct ProviderCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let search = ProviderCapabilities(rawValue: 1 << 0)
    public static let home = ProviderCapabilities(rawValue: 1 << 1)
    public static let library = ProviderCapabilities(rawValue: 1 << 2)
    public static let lyrics = ProviderCapabilities(rawValue: 1 << 3)
    public static let syncedLyrics = ProviderCapabilities(rawValue: 1 << 4)
    public static let radio = ProviderCapabilities(rawValue: 1 << 5)
    public static let like = ProviderCapabilities(rawValue: 1 << 6)
    public static let playlistEditing = ProviderCapabilities(rawValue: 1 << 7)
    public static let follow = ProviderCapabilities(rawValue: 1 << 8)
    public static let playback = ProviderCapabilities(rawValue: 1 << 9)
    public static let explore = ProviderCapabilities(rawValue: 1 << 10)
    /// Songs can be added at a given place in a playlist (`insert(_:intoPlaylist:at:)`), so a removal can be undone
    /// exactly. Without it the app asks before removing.
    public static let playlistInsert = ProviderCapabilities(rawValue: 1 << 11)
}

/// One streaming service. Implemented by `YouTubeMusicProvider` and `SpotifyProvider`.
///
/// Every call is safe to make from the main actor; implementations do their network
/// and parsing work off the main actor and hop back only to publish results.
/// Unsupported operations throw `ProviderError.notSupported`.
@MainActor
public protocol MusicProvider: AnyObject, Observable {
    var id: ProviderID { get }
    var capabilities: ProviderCapabilities { get }

    // MARK: Account

    var authStatus: AuthStatus { get }
    /// Restore a saved session at launch (Keychain). Must not show UI.
    func restoreSession() async
    /// The view shown in a sheet to sign in. Call `onFinish` when the sheet should close.
    func makeSignInView(onFinish: @escaping @MainActor () -> Void) -> AnyView
    /// Provider-specific settings (e.g. Spotify client ID, stream quality). Shown in Settings.
    func makeSettingsView() -> AnyView
    /// Signs out. When the saved sign-in can't be deleted it stays signed in (see `trySignOut`).
    func signOut() async
    /// Signs out, or throws and stays signed in when the saved sign-in couldn't be deleted, so the UI can say so
    /// instead of showing a sign-out that comes back at the next launch. The default calls `signOut()`.
    func trySignOut() async throws
    /// Who requests are sent as right now. Caches keyed by account read it before and after a request.
    /// The default derives it from `authStatus`.
    var session: ProviderSession { get }

    // MARK: Browse

    /// "Home" / "Listen Now" shelves.
    func home() async throws -> [Shelf]
    /// "Explore" / "Browse": new releases, charts, moods & genres.
    func explore() async throws -> [Shelf]
    /// Expand a shelf's `moreToken` ("See All").
    func shelf(moreToken: String) async throws -> Shelf

    // MARK: Search

    func search(_ query: String, scope: SearchScope) async throws -> SearchResults
    func searchSuggestions(_ query: String) async throws -> [String]
    /// Query completions plus direct matches (an artist, a song) when the service offers them.
    /// The default wraps `searchSuggestions` with no direct matches.
    func richSearchSuggestions(_ query: String) async throws -> SearchSuggestions

    // MARK: Entities

    func album(id: String) async throws -> AlbumDetail
    func artist(id: String) async throws -> ArtistDetail
    func playlist(id: String) async throws -> PlaylistDetail
    func playlistTracks(continuation: String) async throws -> Page<Track>
    /// The playlist as the service has it now: never read from a cache and never written to one, for the reads a
    /// playlist edit compares or counts. The defaults call `playlist(id:)` and `playlistTracks(continuation:)`, for
    /// providers that keep no cache of them.
    func uncachedPlaylist(id: String) async throws -> PlaylistDetail
    func uncachedPlaylistTracks(continuation: String) async throws -> Page<Track>
    /// The track with its album and artist links filled in, for "Go to Album" and "Go to Artist" when a
    /// list (search rows, top-result cards) left them out. The default returns the track unchanged.
    func linkedTrack(_ track: Track) async throws -> Track

    // MARK: Library (requires sign-in)

    func library(_ kind: LibraryKind, continuation: String?) async throws -> Page<MediaItem>
    func setLiked(_ track: Track, liked: Bool) async throws
    func isLiked(_ track: Track) async throws -> Bool
    func setSaved(_ item: MediaItem, saved: Bool) async throws
    func createPlaylist(title: String, description: String?) async throws -> Playlist
    func add(_ tracks: [Track], toPlaylist playlistID: String) async throws
    func remove(_ tracks: [Track], fromPlaylist playlistID: String) async throws
    /// Adds `tracks` so the first lands at `position` (0-based) in the playlist, the rest after it. Only with
    /// `.playlistInsert`; the default throws `ProviderError.notSupported`.
    func insert(_ tracks: [Track], intoPlaylist playlistID: String, at position: Int) async throws
    /// The most songs one request of `remove(_:fromPlaylist:)` or `insert(_:intoPlaylist:at:)` takes (Spotify: 100).
    /// A caller that splits a bigger edit at this size knows exactly which requests went through when one fails.
    /// Nil (the default): each call is one request, whatever its size.
    var playlistEditBatchSize: Int? { get }
    /// The same writes bound to `account`, the account the app checked on the main actor: the provider carries it to
    /// where the request's credentials are chosen and sends nothing (`PlaylistEditError.accountChanged`) when they
    /// belong to another account by then.
    func add(_ tracks: [Track], toPlaylist playlistID: String, as account: PlaylistWriteAccount) async throws
    func remove(_ tracks: [Track], fromPlaylist playlistID: String, as account: PlaylistWriteAccount) async throws
    func insert(_ tracks: [Track], intoPlaylist playlistID: String, at position: Int, as account: PlaylistWriteAccount) async throws
    /// New Playlist, bound to `account` like the writes above.
    func createPlaylist(title: String, description: String?, as account: PlaylistWriteAccount) async throws -> Playlist

    // MARK: Playback support

    /// Tracks to continue with after `track` (YouTube "Up next"/radio, Spotify recommendations).
    func radio(seed: Track) async throws -> [Track]
    /// Start a radio from an artist or playlist (`ArtistDetail.radioSeed`, playlist id, etc).
    func radio(seedID: String) async throws -> [Track]
    func lyrics(for track: Track) async throws -> Lyrics?

    /// The engine that plays this provider's tracks. Created once and reused.
    var playbackEngine: any PlaybackEngine { get }
}

public extension MusicProvider {
    var isSignedIn: Bool { authStatus.isSignedIn }

    func trySignOut() async throws { await signOut() }

    var session: ProviderSession { .derived(from: authStatus) }

    func richSearchSuggestions(_ query: String) async throws -> SearchSuggestions {
        SearchSuggestions(queries: try await searchSuggestions(query))
    }

    func linkedTrack(_ track: Track) async throws -> Track { track }

    func uncachedPlaylist(id: String) async throws -> PlaylistDetail { try await playlist(id: id) }

    func uncachedPlaylistTracks(continuation: String) async throws -> Page<Track> { try await playlistTracks(continuation: continuation) }

    func insert(_ tracks: [Track], intoPlaylist playlistID: String, at position: Int) async throws {
        throw ProviderError.notSupported("Adding songs at a position in a playlist")
    }

    var playlistEditBatchSize: Int? { nil }

    func add(_ tracks: [Track], toPlaylist playlistID: String, as account: PlaylistWriteAccount) async throws {
        try await add(tracks, toPlaylist: playlistID)
    }

    func remove(_ tracks: [Track], fromPlaylist playlistID: String, as account: PlaylistWriteAccount) async throws {
        try await remove(tracks, fromPlaylist: playlistID)
    }

    func insert(_ tracks: [Track], intoPlaylist playlistID: String, at position: Int, as account: PlaylistWriteAccount) async throws {
        try await insert(tracks, intoPlaylist: playlistID, at: position)
    }

    func createPlaylist(title: String, description: String?, as account: PlaylistWriteAccount) async throws -> Playlist {
        try await createPlaylist(title: title, description: description)
    }
}

/// Who a provider's requests are sent as, so a cache never files one account's results under another account (or
/// under signed out). Read it before a request and again after: keep the result only when both reads are equal and
/// neither is `.changing`.
public struct ProviderSession: Hashable, Sendable {
    public enum Identity: Hashable, Sendable {
        /// Requests carry no credentials.
        case signedOut
        /// Requests carry this account's credentials. `id` is the service's immutable account id (Spotify's user
        /// id, YouTube's datasync id), nil when the service didn't give one: such a session is never cached on disk.
        case account(id: String?)
        /// Credentials are being swapped, or not restored yet: a request may go out as either side.
        case changing
    }

    /// Changes whenever the credentials sent with requests change.
    public var generation: Int
    public var identity: Identity

    public init(generation: Int, identity: Identity) {
        self.generation = generation
        self.identity = identity
    }

    /// For providers that don't track their credentials: the session `authStatus` implies.
    public static func derived(from status: AuthStatus) -> ProviderSession {
        switch status {
        case .signedIn(let info): ProviderSession(generation: 0, identity: .account(id: info.id))
        case .signingIn: ProviderSession(generation: 0, identity: .changing)
        case .signedOut, .failed: ProviderSession(generation: 0, identity: .signedOut)
        }
    }

    /// The next session, with a new generation.
    public func next(_ identity: Identity) -> ProviderSession {
        ProviderSession(generation: generation &+ 1, identity: identity)
    }
}

/// The account a playlist write must go out as: the service's immutable account id the app checked (nil when the
/// service gave none) and the session it checked it in.
public struct PlaylistWriteAccount: Hashable, Sendable {
    public let accountID: String?
    public let session: ProviderSession

    public init(accountID: String?, session: ProviderSession) {
        self.accountID = accountID
        self.session = session
    }
}

/// What the search field offers while typing.
public struct SearchSuggestions: Hashable, Sendable {
    /// Completions of the typed text.
    public var queries: [String]
    /// Entities that match directly, best first (YouTube Music puts the artist first).
    public var items: [MediaItem]

    public init(queries: [String] = [], items: [MediaItem] = []) {
        self.queries = queries
        self.items = items
    }
}
