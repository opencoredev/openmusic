import Foundation

// MARK: - Provider identity

/// The streaming services Medley talks to.
public enum ProviderID: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case youtubeMusic
    case spotify

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .youtubeMusic: "YouTube Music"
        case .spotify: "Spotify"
        }
    }
}

// MARK: - Artwork

/// One rendition of an image.
public struct ArtworkImage: Hashable, Sendable, Codable {
    public var url: URL
    public var width: Int?
    public var height: Int?

    public init(url: URL, width: Int? = nil, height: Int? = nil) {
        self.url = url
        self.width = width
        self.height = height
    }
}

/// All known renditions of an image. Providers fill in what they have; the UI asks for the size it needs.
public struct Artwork: Hashable, Sendable, Codable {
    public var images: [ArtworkImage]

    public init(images: [ArtworkImage]) {
        self.images = images
    }

    public init?(url: URL?) {
        guard let url else { return nil }
        self.images = [ArtworkImage(url: url)]
    }

    /// The smallest image at least `pixels` wide, else the largest one.
    public func url(minPixels pixels: Int) -> URL? {
        let sized = images.filter { $0.width != nil }.sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        if let fit = sized.first(where: { ($0.width ?? 0) >= pixels }) { return fit.url }
        return sized.last?.url ?? images.first?.url
    }
}

// MARK: - References

public struct ArtistRef: Hashable, Sendable, Codable {
    public var id: String?
    public var name: String

    public init(id: String? = nil, name: String) {
        self.id = id
        self.name = name
    }
}

public struct AlbumRef: Hashable, Sendable, Codable {
    public var id: String?
    public var title: String

    public init(id: String? = nil, title: String) {
        self.id = id
        self.title = title
    }
}

// MARK: - Entities

/// A playable song (or music video on YouTube Music).
public struct Track: Identifiable, Hashable, Sendable, Codable {
    /// Provider-native identifier (YouTube videoId, Spotify track id).
    public var providerID: String
    public var provider: ProviderID
    public var title: String
    public var artists: [ArtistRef]
    public var album: AlbumRef?
    public var duration: TimeInterval?
    public var artwork: Artwork?
    public var isExplicit: Bool
    public var isPlayable: Bool
    public var trackNumber: Int?
    /// Provider-specific values the provider needs later (e.g. YouTube `setVideoId`, Spotify `uri`).
    public var extra: [String: String]

    public var id: String { "\(provider.rawValue):\(providerID)" }

    public var artistLine: String { artists.map(\.name).joined(separator: ", ") }

    public init(
        providerID: String,
        provider: ProviderID,
        title: String,
        artists: [ArtistRef] = [],
        album: AlbumRef? = nil,
        duration: TimeInterval? = nil,
        artwork: Artwork? = nil,
        isExplicit: Bool = false,
        isPlayable: Bool = true,
        trackNumber: Int? = nil,
        extra: [String: String] = [:]
    ) {
        self.providerID = providerID
        self.provider = provider
        self.title = title
        self.artists = artists
        self.album = album
        self.duration = duration
        self.artwork = artwork
        self.isExplicit = isExplicit
        self.isPlayable = isPlayable
        self.trackNumber = trackNumber
        self.extra = extra
    }
}

public enum AlbumKind: String, Codable, Sendable, Hashable {
    case album, single, ep, compilation, unknown
}

public struct Album: Identifiable, Hashable, Sendable, Codable {
    public var providerID: String
    public var provider: ProviderID
    public var title: String
    public var artists: [ArtistRef]
    public var year: Int?
    public var artwork: Artwork?
    public var kind: AlbumKind
    public var trackCount: Int?
    public var isExplicit: Bool
    public var extra: [String: String]

    public var id: String { "\(provider.rawValue):\(providerID)" }
    public var artistLine: String { artists.map(\.name).joined(separator: ", ") }

    public init(
        providerID: String,
        provider: ProviderID,
        title: String,
        artists: [ArtistRef] = [],
        year: Int? = nil,
        artwork: Artwork? = nil,
        kind: AlbumKind = .album,
        trackCount: Int? = nil,
        isExplicit: Bool = false,
        extra: [String: String] = [:]
    ) {
        self.providerID = providerID
        self.provider = provider
        self.title = title
        self.artists = artists
        self.year = year
        self.artwork = artwork
        self.kind = kind
        self.trackCount = trackCount
        self.isExplicit = isExplicit
        self.extra = extra
    }
}

public struct Artist: Identifiable, Hashable, Sendable, Codable {
    public var providerID: String
    public var provider: ProviderID
    public var name: String
    public var artwork: Artwork?
    /// e.g. "12.3M monthly listeners" or "Artist".
    public var subtitle: String?
    public var extra: [String: String]

    public var id: String { "\(provider.rawValue):\(providerID)" }

    public init(
        providerID: String,
        provider: ProviderID,
        name: String,
        artwork: Artwork? = nil,
        subtitle: String? = nil,
        extra: [String: String] = [:]
    ) {
        self.providerID = providerID
        self.provider = provider
        self.name = name
        self.artwork = artwork
        self.subtitle = subtitle
        self.extra = extra
    }
}

public struct Playlist: Identifiable, Hashable, Sendable, Codable {
    public var providerID: String
    public var provider: ProviderID
    public var title: String
    public var owner: String?
    public var artwork: Artwork?
    public var trackCount: Int?
    public var summary: String?
    /// True when the signed-in user can add/remove tracks.
    public var isEditable: Bool
    public var extra: [String: String]

    public var id: String { "\(provider.rawValue):\(providerID)" }

    public init(
        providerID: String,
        provider: ProviderID,
        title: String,
        owner: String? = nil,
        artwork: Artwork? = nil,
        trackCount: Int? = nil,
        summary: String? = nil,
        isEditable: Bool = false,
        extra: [String: String] = [:]
    ) {
        self.providerID = providerID
        self.provider = provider
        self.title = title
        self.owner = owner
        self.artwork = artwork
        self.trackCount = trackCount
        self.summary = summary
        self.isEditable = isEditable
        self.extra = extra
    }

    /// `extra` key that marks a service's own liked-songs playlist where its id doesn't (sample data).
    public static let likedSongsKey = "likedSongs"

    /// The service's own list of liked songs: YouTube Music's "Liked Music" (`LM`) or Spotify's "Liked Songs"
    /// (`collection`, which its API doesn't list among playlists but a link can carry). Medley shows these as
    /// Library › Liked Songs; the sidebar leaves them out of Playlists so there's one liked entry.
    public var isLikedSongs: Bool {
        if extra[Self.likedSongsKey] == "1" { return true }
        switch provider {
        case .youtubeMusic: return providerID == "LM" || providerID == "VLLM"
        case .spotify: return providerID == "collection" || providerID.hasSuffix(":collection")
        }
    }
}

/// Anything that can appear in a shelf, search result, or grid.
public enum MediaItem: Identifiable, Hashable, Sendable, Codable {
    case track(Track)
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)

    public var id: String {
        switch self {
        case .track(let t): "track:\(t.id)"
        case .album(let a): "album:\(a.id)"
        case .artist(let a): "artist:\(a.id)"
        case .playlist(let p): "playlist:\(p.id)"
        }
    }

    public var provider: ProviderID {
        switch self {
        case .track(let t): t.provider
        case .album(let a): a.provider
        case .artist(let a): a.provider
        case .playlist(let p): p.provider
        }
    }

    public var title: String {
        switch self {
        case .track(let t): t.title
        case .album(let a): a.title
        case .artist(let a): a.name
        case .playlist(let p): p.title
        }
    }

    public var subtitle: String? {
        switch self {
        case .track(let t): t.artistLine
        case .album(let a): a.artistLine
        case .artist(let a): a.subtitle
        case .playlist(let p): p.owner
        }
    }

    public var artwork: Artwork? {
        switch self {
        case .track(let t): t.artwork
        case .album(let a): a.artwork
        case .artist(let a): a.artwork
        case .playlist(let p): p.artwork
        }
    }
}

// MARK: - Details

public struct AlbumDetail: Hashable, Sendable {
    public var album: Album
    public var tracks: [Track]
    public var summary: String?
    /// e.g. "12 songs, 48 minutes · 2021 · Label".
    public var footnote: String?
    public var moreByArtist: [Album]

    public init(album: Album, tracks: [Track], summary: String? = nil, footnote: String? = nil, moreByArtist: [Album] = []) {
        self.album = album
        self.tracks = tracks
        self.summary = summary
        self.footnote = footnote
        self.moreByArtist = moreByArtist
    }
}

public struct ArtistDetail: Hashable, Sendable {
    public var artist: Artist
    public var topTracks: [Track]
    public var albums: [Album]
    public var singles: [Album]
    public var playlists: [Playlist]
    public var related: [Artist]
    /// Releases by others that feature this artist ("Appears On"). Empty when the provider doesn't have them.
    public var appearsOn: [Album]
    public var bio: String?
    /// Provider-specific id that starts an artist radio/shuffle, if any.
    public var radioSeed: String?
    public var isFollowed: Bool?

    public init(
        artist: Artist,
        topTracks: [Track] = [],
        albums: [Album] = [],
        singles: [Album] = [],
        playlists: [Playlist] = [],
        related: [Artist] = [],
        appearsOn: [Album] = [],
        bio: String? = nil,
        radioSeed: String? = nil,
        isFollowed: Bool? = nil
    ) {
        self.artist = artist
        self.topTracks = topTracks
        self.albums = albums
        self.singles = singles
        self.playlists = playlists
        self.related = related
        self.appearsOn = appearsOn
        self.bio = bio
        self.radioSeed = radioSeed
        self.isFollowed = isFollowed
    }
}

public struct PlaylistDetail: Hashable, Sendable {
    public var playlist: Playlist
    public var tracks: [Track]
    /// Opaque token for `MusicProvider.playlistTracks(continuation:)`.
    public var continuation: String?
    /// Each track's place in the playlist as the service numbers its entries (0-based), when the service lists
    /// entries Medley leaves out (Spotify's local files, episodes, removed songs): `[A, local, X]` gives A at 0 and
    /// X at 2. Nil when every entry is listed, so a track's place is its offset.
    public var positions: [Int]?
    /// How many entries the service listed on this page, the ones left out included. Nil: `tracks.count`.
    public var entryCount: Int?
    /// The entries left out of `tracks` that the service still identifies, by place (Spotify's `spotify:local:` and
    /// episode URIs). A left-out place missing here can't be told apart from another (a `null` entry).
    public var unlistedEntries: [Int: String]?

    public init(playlist: Playlist, tracks: [Track], continuation: String? = nil, positions: [Int]? = nil, entryCount: Int? = nil,
                unlistedEntries: [Int: String]? = nil) {
        self.playlist = playlist
        self.tracks = tracks
        self.continuation = continuation
        self.positions = positions
        self.entryCount = entryCount
        self.unlistedEntries = unlistedEntries
    }
}

// MARK: - Browse

public enum ShelfStyle: String, Hashable, Sendable, Codable {
    /// Horizontally scrolling large cards (albums, playlists, mixes).
    case carousel
    /// Compact rows of songs, usually in columns.
    case trackList
    /// Round artist portraits.
    case artists
    /// Big hero cards at the top of a page.
    case hero
}

public struct Shelf: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var style: ShelfStyle
    public var items: [MediaItem]
    /// Opaque token for "See All", if the provider supports it.
    public var moreToken: String?

    public init(id: String, title: String, subtitle: String? = nil, style: ShelfStyle, items: [MediaItem], moreToken: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.style = style
        self.items = items
        self.moreToken = moreToken
    }
}

public struct SearchResults: Hashable, Sendable {
    public var top: MediaItem?
    public var tracks: [Track]
    public var albums: [Album]
    public var artists: [Artist]
    public var playlists: [Playlist]

    public init(top: MediaItem? = nil, tracks: [Track] = [], albums: [Album] = [], artists: [Artist] = [], playlists: [Playlist] = []) {
        self.top = top
        self.tracks = tracks
        self.albums = albums
        self.artists = artists
        self.playlists = playlists
    }

    public var isEmpty: Bool { top == nil && tracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty }
}

public enum SearchScope: String, CaseIterable, Hashable, Sendable {
    case all, songs, albums, artists, playlists
}

public enum LibraryKind: String, CaseIterable, Hashable, Sendable {
    case likedSongs, songs, albums, artists, playlists, recentlyPlayed
}

/// One page of a paginated list.
public struct Page<Item: Sendable & Hashable>: Hashable, Sendable {
    public var items: [Item]
    public var continuation: String?
    /// For a playlist's page: each item's place in the whole playlist as the service numbers its entries, when it
    /// lists entries the page leaves out (see `PlaylistDetail.positions`). Nil: places follow the items.
    public var positions: [Int]?
    /// How many entries the service listed on this page, the ones left out included. Nil: `items.count`.
    public var entryCount: Int?
    /// For a playlist's page: the left-out entries the service identifies, by place (see
    /// `PlaylistDetail.unlistedEntries`).
    public var unlistedEntries: [Int: String]?

    public init(items: [Item], continuation: String? = nil, positions: [Int]? = nil, entryCount: Int? = nil,
                unlistedEntries: [Int: String]? = nil) {
        self.items = items
        self.continuation = continuation
        self.positions = positions
        self.entryCount = entryCount
        self.unlistedEntries = unlistedEntries
    }
}

// MARK: - Lyrics

public struct LyricLine: Hashable, Sendable, Codable {
    /// Start time in seconds, nil for unsynced lyrics.
    public var time: TimeInterval?
    public var text: String

    public init(time: TimeInterval? = nil, text: String) {
        self.time = time
        self.text = text
    }
}

public struct Lyrics: Hashable, Sendable, Codable {
    public var lines: [LyricLine]
    public var source: String?

    public var isSynced: Bool { lines.contains { $0.time != nil } }

    public init(lines: [LyricLine], source: String? = nil) {
        self.lines = lines
        self.source = source
    }
}

// MARK: - Accounts

public struct AccountInfo: Hashable, Sendable, Codable {
    public var name: String
    public var avatar: URL?
    /// e.g. "Premium", "Free", an email address.
    public var detail: String?
    /// The service's immutable identifier for the account (Spotify's user id; YouTube's datasync id, which names the
    /// Google account and the selected channel), so two accounts with the same name and plan are told apart. Nil when
    /// the service didn't give one (a placeholder while offline, or YouTube credentials saved without a datasync id).
    /// Never a name, handle or email: those can change or move to another account.
    public var id: String?

    public init(name: String, avatar: URL? = nil, detail: String? = nil, id: String? = nil) {
        self.name = name
        self.avatar = avatar
        self.detail = detail
        self.id = id
    }
}

public enum AuthStatus: Hashable, Sendable {
    case signedOut
    case signingIn
    case signedIn(AccountInfo)
    case failed(String)

    public var isSignedIn: Bool {
        if case .signedIn = self { return true }
        return false
    }
}

/// A playlist edit the service can't do exactly, refused before anything was written.
public enum PlaylistEditError: LocalizedError, Sendable, Equatable {
    /// Some copies of the songs carry no entry id the service could remove them by (YouTube's `setVideoId`):
    /// removing the others would leave those behind while saying every copy went.
    case unidentifiedCopies(Int)
    /// The request wasn't sent: the credentials it would have gone out with no longer belong to the account the edit
    /// was checked for (another account's sign-in landed, or a swap is under way).
    case accountChanged

    public var errorDescription: String? {
        switch self {
        case .unidentifiedCopies(let count): "\(count) of the copies have no entry id to remove them by."
        case .accountChanged: "The sign-in changed before the request went out."
        }
    }
}

public enum ProviderError: LocalizedError, Sendable, Equatable {
    case notSignedIn
    case notSupported(String)
    case notFound
    case rateLimited
    case unplayable(String)
    case network(String)
    case decoding(String)
    case server(Int, String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in to use this."
        case .notSupported(let what): "\(what) isn't supported."
        case .notFound: "Not found."
        case .rateLimited: "Too many requests. Try again in a moment."
        case .unplayable(let why): "Can't play this track: \(why)"
        case .network(let msg): "Network error: \(msg)"
        case .decoding(let msg): "Unexpected response: \(msg)"
        case .server(let code, let msg): "Server error \(code): \(msg)"
        }
    }
}
