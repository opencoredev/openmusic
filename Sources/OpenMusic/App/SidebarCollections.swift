import Foundation
import OpenMusicCore
import Observation

/// An album, playlist, artist or radio shown in the sidebar's Pinned and Recently Played sections.
enum SidebarEntry: Codable, Hashable, Sendable, Identifiable {
    /// An album, playlist or artist (never a song).
    case item(MediaItem)
    case radio(RadioStation)

    var id: String {
        switch self {
        case .item(let item): item.id
        // A radio started from an artist or playlist is one station whichever seed asked for it (the artist page
        // passes its RDEM… seed, its menu the UC… channel id), so it's keyed by where it came from.
        case .radio(let r): "radio:" + (r.origin.map(\.id) ?? "\(r.provider.rawValue):\(r.seedID)")
        }
    }

    var provider: ProviderID {
        switch self {
        case .item(let item): item.provider
        case .radio(let r): r.provider
        }
    }

    var title: String {
        switch self {
        case .item(let item): item.title
        case .radio(let r): "\(r.name) Radio"
        }
    }

    /// "Album · Daft Punk", "Playlist", "Artist", "Radio".
    var detail: String {
        switch self {
        case .item(.album(let a)):
            a.artistLine.isEmpty ? a.kind.label : "\(a.kind.label) · \(a.artistLine)"
        case .item(.playlist): "Playlist"
        case .item(.artist): "Artist"
        case .item(.track): "Song"
        case .radio: "Radio"
        }
    }

    var artwork: Artwork? {
        switch self {
        case .item(let item): item.artwork
        case .radio(let r): r.artwork
        }
    }

    var isArtist: Bool {
        if case .item(.artist) = self { true } else { false }
    }

    /// The album, playlist or artist a drag of the row carries; a radio has none.
    var mediaItem: MediaItem? {
        if case .item(let item) = self { item } else { nil }
    }

    /// The page a click opens: the collection itself, or for a radio the artist, playlist or album it came from.
    var route: Route? {
        switch self {
        case .item(let item): Route.for(item)
        case .radio(let r): r.origin.flatMap(Route.for)
        }
    }

    /// What "Pin to Sidebar" pins for a page or card.
    init?(_ item: MediaItem) {
        if case .track = item { return nil }
        self = .item(item)
    }
}

/// A radio started from an artist, playlist or song. `origin` is the page its row opens.
struct RadioStation: Codable, Hashable, Sendable {
    var provider: ProviderID
    /// The seed for `radio(seedID:)`, or a song id when `seedTrack` is set.
    var seedID: String
    /// What the radio is named after ("Daft Punk"); the row reads "Daft Punk Radio".
    var name: String
    var artwork: Artwork?
    var origin: MediaItem?
    /// Song radios start from this song with `radio(seed:)`.
    var seedTrack: Track?
}

/// Pinned and recently played collections, newest first, saved as JSON in Application Support next to the
/// queue. Sample-data and snapshot runs use a temporary file, so they never touch the real lists.
@MainActor
@Observable
final class SidebarCollections {
    static let recentLimit = 12

    private(set) var pinned: [SidebarEntry] = []
    private(set) var recents: [SidebarEntry] = []
    @ObservationIgnored let url: URL

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            pinned = saved.pinned
            recents = Array(saved.recents.prefix(Self.recentLimit))
        }
    }

    /// `~/Library/Application Support/OpenMusic/sidebar.json`
    static var defaultURL: URL {
        QueueStore.defaultURL.deletingLastPathComponent().appending(path: "sidebar.json")
    }

    /// Recently played rows, without the ones already pinned (they show once, under Pinned).
    var unpinnedRecents: [SidebarEntry] {
        let pinnedIDs = Set(pinned.map(\.id))
        return recents.filter { !pinnedIDs.contains($0.id) }
    }

    func isPinned(_ id: String) -> Bool { pinned.contains { $0.id == id } }

    /// The entry behind a sidebar row, pinned or recent.
    func entry(id: String) -> SidebarEntry? {
        pinned.first { $0.id == id } ?? recents.first { $0.id == id }
    }

    /// Moves `entry` to the top of Recently Played. A newer copy (fresher artwork or title) replaces the old one.
    func recordPlayed(_ entry: SidebarEntry) {
        if case .item(.track) = entry { return }
        var list = recents
        list.removeAll { $0.id == entry.id }
        list.insert(entry, at: 0)
        list = Array(list.prefix(Self.recentLimit))
        guard list != recents else { return }
        recents = list
        // Keep a pinned copy's title and artwork current too.
        if let i = pinned.firstIndex(where: { $0.id == entry.id }), pinned[i] != entry { pinned[i] = entry }
        save()
    }

    func removeRecent(_ id: String) {
        guard recents.contains(where: { $0.id == id }) else { return }
        recents.removeAll { $0.id == id }
        save()
    }

    func pin(_ entry: SidebarEntry) {
        guard !isPinned(entry.id) else { return }
        pinned.append(entry)
        save()
    }

    func unpin(_ id: String) {
        guard isPinned(id) else { return }
        pinned.removeAll { $0.id == id }
        save()
    }

    /// Drag reordering in the Pinned section.
    func movePinned(from source: IndexSet, to destination: Int) {
        pinned.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Move Up / Move Down in a pinned row's menu.
    func movePinned(_ id: String, by delta: Int) {
        guard let i = pinned.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard pinned.indices.contains(j) else { return }
        pinned.swapAt(i, j)
        save()
    }

    private struct Saved: Codable {
        var version = 1
        var pinned: [SidebarEntry]
        var recents: [SidebarEntry]
    }

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Encodes here (a few kilobytes) and writes off the main actor, each write after the previous one.
    private func save() {
        guard let data = try? JSONEncoder().encode(Saved(pinned: pinned, recents: recents)) else { return }
        let url = url
        let previous = saveTask
        saveTask = Task.detached(priority: .utility) {
            await previous?.value
            Self.write(data, to: url)
        }
    }

    /// Waits for pending writes (tests).
    func flush() async { await saveTask?.value }

    private nonisolated static func write(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

extension SidebarEntry {
    /// The collection a play context points at, from the route's preview model (nil for songs and radios).
    init?(route: Route?) {
        switch route {
        case .album(_, _, let preview?): self = .item(.album(preview))
        case .playlist(_, _, let preview?): self = .item(.playlist(preview))
        case .artist(_, _, let preview?): self = .item(.artist(preview))
        default: return nil
        }
    }
}

// MARK: - Sidebar collection actions

extension AppModel {
    /// Plays a pinned or recent row: the collection, or the radio again.
    func play(_ entry: SidebarEntry) {
        switch entry {
        case .item(let item):
            play(item)
        case .radio(let r):
            if let seed = r.seedTrack {
                startRadio(seed)
            } else {
                startRadio(seedID: r.seedID, title: r.name, provider: r.provider, origin: r.origin)
            }
        }
    }

    /// The play request a row's button starts (`play(_ entry:)`), for its spinner while it loads.
    static func playRequestKey(for entry: SidebarEntry) -> PlayRequestKey {
        switch entry {
        case .item(let item):
            return .collection(item.id, shuffled: false)
        case .radio(let r):
            if let seed = r.seedTrack { return .radio("\(seed.provider.rawValue):\(seed.providerID)") }
            return .radio("\(r.provider.rawValue):\(r.seedID)")
        }
    }

    func pinToSidebar(_ entry: SidebarEntry) {
        collections.pin(entry)
        reselectCanonicalRow()
    }

    func unpinFromSidebar(_ id: String) {
        collections.unpin(id)
        reselectCanonicalRow()
        leaveRemovedCollection(id)
    }

    /// Pinned rows the service filter shows (View › Show): with "YouTube Music only", no Spotify pin. The stored
    /// order is the unfiltered one (`movePinned(fromVisible:to:)`).
    var sidebarPinned: [SidebarEntry] {
        collections.pinned.filter { serviceFilter.includes($0.provider) }
    }

    /// A pin that has a row now: pinned, and its service not filtered out.
    func isPinnedInSidebar(_ id: String) -> Bool {
        guard let entry = collections.pinned.first(where: { $0.id == id }) else { return false }
        return serviceFilter.includes(entry.provider)
    }

    /// Recently Played rows: what was played lately on a service the filter shows, less what already has a row
    /// above (pinned, one of the service's playlists under Playlists, or a service's liked-songs list, which Library ›
    /// Liked Songs stands for), so nothing shows twice.
    var sidebarRecents: [SidebarEntry] {
        let listed = Set(sidebarPlaylists.map { MediaItem.playlist($0).id })
        return collections.unpinnedRecents.filter { entry in
            if case .item(.playlist(let p)) = entry, p.isLikedSongs { return false }
            return !listed.contains(entry.id) && serviceFilter.includes(entry.provider)
        }
    }

    /// A drag among the visible pinned rows (`onMove` offsets into `sidebarPinned`), applied to the full list: hidden
    /// pins keep their places relative to each other, and the moved rows land before the visible row they were
    /// dropped on (after the last visible one at the end).
    func movePinned(fromVisible source: IndexSet, to destination: Int) {
        let visible = sidebarPinned
        let all = collections.pinned
        let moving = source.compactMap { visible.indices.contains($0) ? visible[$0].id : nil }
        let fullSource = IndexSet(moving.compactMap { id in all.firstIndex { $0.id == id } })
        guard !fullSource.isEmpty else { return }
        let fullDestination: Int
        if visible.indices.contains(destination), let i = all.firstIndex(where: { $0.id == visible[destination].id }) {
            fullDestination = i
        } else if let last = visible.last, let i = all.firstIndex(where: { $0.id == last.id }) {
            fullDestination = i + 1
        } else {
            fullDestination = all.count
        }
        collections.movePinned(from: fullSource, to: fullDestination)
    }

    /// Move Up / Move Down in a pinned row's menu: past the next visible pin that way, skipping filtered-out ones.
    func movePinned(_ id: String, by delta: Int) {
        let visible = sidebarPinned
        guard let i = visible.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard visible.indices.contains(j) else { return }
        movePinned(fromVisible: IndexSet(integer: i), to: delta > 0 ? j + 1 : j)
    }

    /// The one row a selection highlights. A playlist can be pinned, under Playlists, and in Recently Played at once,
    /// and its two kinds of tag (`.playlist(provider, id)` under Playlists, `.collection(id)` elsewhere) would each
    /// light their own row. Every playlist selection resolves to the Pinned row when it's pinned, else to its row
    /// under Playlists; only a playlist with neither keeps its Recently Played row.
    func canonicalSidebarSelection(_ item: SidebarItem?) -> SidebarItem? {
        switch item {
        case .playlist(let provider, let id):
            let entryID = MediaItem.playlist(Playlist(providerID: id, provider: provider, title: "")).id
            return isPinnedInSidebar(entryID) ? .collection(entryID) : item
        case .collection(let entryID):
            // A pin the service filter hides has no row: the playlist's row under Playlists stands in.
            guard !isPinnedInSidebar(entryID), case .item(.playlist(let playlist))? = collections.entry(id: entryID),
                  sidebarPlaylists.contains(where: { $0.provider == playlist.provider && $0.providerID == playlist.providerID })
            else { return item }
            return .playlist(playlist.provider, playlist.providerID)
        default:
            return item
        }
    }

    /// After a pin or unpin, moves the highlight to the row that now stands for the page (only on the page itself:
    /// a page pushed over it keeps its place).
    func reselectCanonicalRow() {
        guard path.isEmpty else { return }
        let canonical = canonicalSidebarSelection(sidebarSelection)
        if canonical != sidebarSelection { sidebarSelection = canonical }
    }

    func removeFromRecentlyPlayed(_ id: String) {
        collections.removeRecent(id)
        leaveRemovedCollection(id)
    }

    /// A row that left the sidebar can't stay selected: its page goes back to Home.
    private func leaveRemovedCollection(_ id: String) {
        if sidebarSelection == .collection(id), collections.entry(id: id) == nil { select(.home) }
    }
}
