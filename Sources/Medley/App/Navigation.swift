import MedleyCore
import SwiftUI

/// Rows in the sidebar.
enum SidebarItem: Hashable {
    case home, explore, search
    case recentlyAdded, artists, albums, songs, likedSongs, recentlyPlayed
    case allPlaylists
    case playlist(ProviderID, String)
    /// A pinned or recently played album, playlist, artist or radio (`SidebarEntry.id`).
    case collection(String)

    var title: String {
        switch self {
        case .home: "Home"
        case .explore: "New"
        case .search: "Search"
        case .recentlyAdded: "Recently Added"
        case .artists: "Artists"
        case .albums: "Albums"
        case .songs: "Songs"
        case .likedSongs: "Liked Songs"
        // The service's listening history. "Recently Played" is the sidebar section of collections.
        case .recentlyPlayed: "History"
        case .allPlaylists: "All Playlists"
        case .playlist: "Playlist"
        case .collection: "Collection"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .explore: "square.grid.2x2"
        case .search: "magnifyingglass"
        case .recentlyAdded: "plus.circle"
        case .artists: "music.mic"
        case .albums: "square.stack"
        case .songs: "music.note"
        case .likedSongs: "heart"
        case .recentlyPlayed: "clock.arrow.circlepath"
        case .allPlaylists: "square.grid.3x3"
        case .playlist: "music.note.list"
        case .collection: "square.stack"
        }
    }

    /// The single "Library" row shown while no service has a library (signed out), and its empty state.
    static let libraryPlaceholderSymbol = "books.vertical"

    static let browse: [SidebarItem] = [.home, .explore]
    static let library: [SidebarItem] = [.recentlyAdded, .artists, .albums, .songs, .likedSongs, .recentlyPlayed]
    /// ⌘1… order.
    static let numbered: [SidebarItem] = browse + library
}

/// Pages pushed onto the detail stack.
enum Route: Hashable {
    case album(ProviderID, id: String, preview: Album?)
    case artist(ProviderID, id: String, preview: Artist?)
    case playlist(ProviderID, id: String, preview: Playlist?)
    /// "See All" for a shelf. Uses `moreToken` when there is one, else shows the shelf's own items.
    case shelf(ProviderID, Shelf)

    static func `for`(_ item: MediaItem) -> Route? {
        switch item {
        case .track: nil
        case .album(let a): .album(a.provider, id: a.providerID, preview: a)
        case .artist(let a): .artist(a.provider, id: a.providerID, preview: a)
        case .playlist(let p): .playlist(p.provider, id: p.providerID, preview: p)
        }
    }
}

enum ServiceFilter: String, CaseIterable, Identifiable, Hashable {
    case all, youtubeMusic, spotify

    var id: String { rawValue }

    var provider: ProviderID? {
        switch self {
        case .all: nil
        case .youtubeMusic: .youtubeMusic
        case .spotify: .spotify
        }
    }

    var title: String { provider?.displayName ?? "All Services" }

    /// What the sidebar footer says while this filter is in use: "YouTube Music only".
    var onlyTitle: String { provider.map { "\($0.displayName) only" } ?? title }

    func includes(_ id: ProviderID) -> Bool { provider == nil || provider == id }
}

enum InspectorPanel: String, Hashable {
    case lyrics, queue
}
