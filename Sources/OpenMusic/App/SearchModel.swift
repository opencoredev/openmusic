import Foundation
import OpenMusicCore
import Observation

/// Which results a search page shows: the query, the scope and the services searched.
/// Results always belong to one key, so an answer for an older query or scope never shows under a newer one.
struct SearchKey: Hashable, Sendable {
    /// Trimmed and lowercased, so "Daft Punk " and "daft punk" share results.
    let query: String
    let scope: SearchScope
    /// Services searched, in the app's provider order.
    let services: [ProviderID]

    init(query: String, scope: SearchScope, services: [ProviderID]) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.scope = scope
        self.services = services
    }

    var cacheKey: String { "search:\(scope.rawValue):\(services.map(\.rawValue).joined(separator: "+")):\(query)" }
}

/// Loads search results for one key at a time and drops answers that arrive for an older key.
///
/// Every service is awaited before anything shows, so rows never reshuffle as a second service answers.
/// If the same key loads again (Refresh), rows already on screen keep their order and new ones go after them.
@MainActor
@Observable
final class SearchResultsStore {
    typealias Results = [ProviderResult<SearchResults>]

    /// The key the page asked for most recently.
    private(set) var key: SearchKey?
    /// Results for `key`, or nil while they load.
    private(set) var results: Results?

    @ObservationIgnored private let fetch: @MainActor (SearchKey) async -> Results
    @ObservationIgnored private let cache: PageCache?
    @ObservationIgnored private let debounce: Duration
    /// Bumped by every `load`, so only the newest request for a key may publish, even a same-key refresh.
    @ObservationIgnored private var generation = 0

    init(cache: PageCache?, debounce: Duration = .milliseconds(200), fetch: @escaping @MainActor (SearchKey) async -> Results) {
        self.cache = cache
        self.debounce = debounce
        self.fetch = fetch
    }

    /// Results to show for `key`. Nil means "show the loading skeleton", never another key's rows.
    func results(for key: SearchKey) -> Results? {
        self.key == key ? results : nil
    }

    /// Makes `key` current and loads it. Cached results show at once; otherwise a short debounce
    /// skips the requests for intermediate keystrokes.
    func load(_ key: SearchKey, force: Bool = false) async {
        if !force, self.key == key, results != nil { return }
        generation &+= 1
        let current = generation
        if self.key != key {
            self.key = key
            results = nil
        }
        if !force, let hit: (value: Results, date: Date) = cache?.value(for: key.cacheKey) {
            results = hit.value
            return
        }
        if debounce > .zero {
            try? await Task.sleep(for: debounce)
            // Typing on, or the page went away, before anyone was asked. The next `load` starts over.
            if Task.isCancelled { return }
        }
        guard self.key == key, generation == current else { return }
        let fresh = await fetch(key)
        // A newer query, scope or service set, or a newer load of this key, took over while this one
        // loaded: drop the late answer.
        guard self.key == key, generation == current else { return }
        // Keep rows that are on screen now where they are.
        let shown = results.map { Self.stabilized(fresh, keeping: $0) } ?? fresh
        cache?.set(shown, for: key.cacheKey)
        results = shown
    }

    // MARK: Stable order

    /// `fresh`, ordered so rows already on screen (`old`) stay where they are. Their values update in
    /// place by identity; rows that are new go after them; rows that disappeared are dropped.
    static func stabilized(_ fresh: Results, keeping old: Results) -> Results {
        fresh.map { result in
            guard let new = result.value, let before = old.first(where: { $0.provider == result.provider })?.value else { return result }
            var merged = new
            merged.tracks = stableOrder(new.tracks, keeping: before.tracks)
            merged.albums = stableOrder(new.albums, keeping: before.albums)
            merged.artists = stableOrder(new.artists, keeping: before.artists)
            merged.playlists = stableOrder(new.playlists, keeping: before.playlists)
            if let top = before.top, new.contains(top) { merged.top = new.item(id: top.id) ?? top }
            return ProviderResult(provider: result.provider, value: merged, error: result.error)
        }
    }

    static func stableOrder<T: Identifiable>(_ fresh: [T], keeping old: [T]) -> [T] where T.ID: Hashable {
        let byID = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = old.compactMap { byID[$0.id] }
        let keptIDs = Set(kept.map(\.id))
        return kept + fresh.filter { !keptIDs.contains($0.id) }
    }
}

extension SearchResults {
    func contains(_ item: MediaItem) -> Bool { self.item(id: item.id) != nil }

    func item(id: String) -> MediaItem? {
        if top?.id == id { return top }
        let all = tracks.map(MediaItem.track) + albums.map(MediaItem.album) + artists.map(MediaItem.artist) + playlists.map(MediaItem.playlist)
        return all.first { $0.id == id }
    }
}

// MARK: - Artists

/// Splits search artists into the ones the query names and the ones a service adds as related.
enum ArtistMatch {
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    /// True when the artist's name and the query name each other ("daft" → Daft Punk, "taylor swift" → Taylor Swift).
    static func matches(_ name: String, query: String) -> Bool {
        let n = fold(name), q = fold(query)
        guard !n.isEmpty, !q.isEmpty else { return false }
        return n.hasPrefix(q) || q.hasPrefix(n) || (q.count >= 4 && n.contains(q))
    }

    static func split(_ artists: [Artist], query: String) -> (matches: [Artist], related: [Artist]) {
        var matches: [Artist] = [], related: [Artist] = []
        for artist in artists {
            if Self.matches(artist.name, query: query) { matches.append(artist) } else { related.append(artist) }
        }
        return (matches, related)
    }
}

/// Album results for an artist's name: the artist's own releases first, then everything else the words matched.
/// YouTube Music's Albums scope for "daft punk" mixed eight other artists' singles in among Daft Punk's albums.
enum AlbumRanking {
    /// `byArtist` keeps the albums with an artist named exactly like the query (ignoring case, accents and
    /// punctuation), or one of the matched `artists` from the same search (by id or name); `others` keeps the rest.
    /// Both keep the service's order, and no album is dropped.
    static func split(_ albums: [Album], query: String, artists: [Artist] = []) -> (byArtist: [Album], others: [Album]) {
        let q = ArtistMatch.fold(query)
        guard !q.isEmpty else { return ([], albums) }
        let matched = ArtistMatch.split(artists, query: query).matches
        // "Daft Punk" also prefix-matches "Daft Punk Tribute Band"; with an exact name in the results, only it counts.
        let exact = matched.filter { ArtistMatch.fold($0.name) == q }
        let named = exact.isEmpty ? matched : exact
        let ids = Set(named.map(\.providerID))
        let names = Set(named.map { ArtistMatch.fold($0.name) }).union([q])
        var byArtist: [Album] = [], others: [Album] = []
        for album in albums {
            let isTheArtists = album.artists.contains { ref in
                if let id = ref.id, ids.contains(id) { return true }
                return names.contains(ArtistMatch.fold(ref.name))
            }
            if isTheArtists { byArtist.append(album) } else { others.append(album) }
        }
        return (byArtist, others)
    }
}

// MARK: - Suggestions

/// What the search field offers for the typed text.
struct SearchFieldSuggestions: Equatable {
    /// A direct artist match, shown first with its picture.
    var artist: Artist?
    var queries: [String] = []

    /// Picking the artist row fills the field with the artist's name plus this invisible marker,
    /// so the app can tell "picked the artist" from "typed the name" and open the artist page.
    static let artistMarker: Character = "\u{2060}"

    static func completion(for artist: Artist) -> String { artist.name + String(artistMarker) }

    var isEmpty: Bool { artist == nil && queries.isEmpty }

    static func make(query: String, from lists: [SearchSuggestions]) -> SearchFieldSuggestions {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = lists.lazy.flatMap(\.items).compactMap { item -> Artist? in
            if case .artist(let a) = item, ArtistMatch.matches(a.name, query: q) { return a }
            return nil
        }.first
        var seen = Set<String>()
        let queries = lists.flatMap(\.queries).filter {
            seen.insert($0.lowercased()).inserted && $0.caseInsensitiveCompare(q) != .orderedSame
        }
        return SearchFieldSuggestions(artist: artist, queries: Array(queries.prefix(artist == nil ? 8 : 7)))
    }
}

// MARK: Song versions in results

/// Whether a result plays the song's audio or a video of it. YouTube Music mixes both in one search, often
/// under the same title and artist ("You Need To Calm Down" the song, 2:52, and its video, 3:31).
nonisolated enum RecordingKind: Equatable {
    case song, video

    init(_ track: Track) {
        switch track.extra["musicVideoType"] {
        case "MUSIC_VIDEO_TYPE_OMV", "MUSIC_VIDEO_TYPE_UGC", "MUSIC_VIDEO_TYPE_OFFICIAL_SOURCE_MUSIC": self = .video
        default: self = .song
        }
    }
}

nonisolated enum SongVersions {
    /// Two results are the same recording when title and artists match (ignoring case and accents), both are
    /// songs or both are videos, and both lengths are known and agree within 2 s. With a length missing, they
    /// stay apart: the card fills in its length later, and an unknown one may be a different edit.
    static func isSameRecording(_ a: Track, _ b: Track) -> Bool {
        guard a.provider == b.provider, key(a.title) == key(b.title),
              a.artists.map { key($0.name) } == b.artists.map { key($0.name) },
              RecordingKind(a) == RecordingKind(b) else { return false }
        guard let da = a.duration, let db = b.duration else { return false }
        if let x = a.album?.title, let y = b.album?.title, key(x) != key(y) { return false }
        return abs(da - db) <= PlayerController.durationTolerance
    }

    /// `tracks` without later copies of a recording already listed; the first copy stays where it was.
    static func consolidated(_ tracks: [Track]) -> [Track] {
        var kept: [Track] = []
        for t in tracks where !kept.contains(where: { isSameRecording($0, t) }) { kept.append(t) }
        return kept
    }

    /// The secondary line for a song in Top Results: "Song · Taylor Swift", "Video · Taylor Swift". The length
    /// goes after it ("Song · Taylor Swift · 3:45"), separately, so it never truncates. The album is in the card's
    /// tooltip (`helpLine`) and its menu's Go to Album.
    static func detailLine(for track: Track) -> String {
        let kind = RecordingKind(track) == .video ? "Video" : "Song"
        return [kind, track.artistLine].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The second line of a song row in the search song grid: the artist only ("Video · artist" for a video, so
    /// a song and its video read differently). Three columns leave too little room for the album as well; it moves
    /// to the row's tooltip (`helpLine`) and its menu.
    static func rowLine(for track: Track) -> String {
        switch RecordingKind(track) {
        case .video: return ["Video", track.artistLine].filter { !$0.isEmpty }.joined(separator: " · ")
        case .song: return track.artistLine
        }
    }

    /// A search result's tooltip: "the cure — Olivia Rodrigo · GUTS", the album named when the listing has it.
    static func helpLine(for track: Track) -> String {
        let rest = [track.artistLine, track.album?.title ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        return rest.isEmpty ? track.title : "\(track.title) — \(rest)"
    }

    private static func key(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
