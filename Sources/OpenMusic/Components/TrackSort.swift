import OpenMusicCore
import SwiftUI

/// How a long album or playlist is ordered on screen: a column and a direction. View-only: the collection itself
/// never changes, rows keep their original numbers, and the choice isn't saved (a page opens in its original order).
///
/// The table header's Title, Album and duration cells set it (`toggled(_:)`); the page's More › Sort By lists every
/// key the page offers, Artist and Original Order included.
struct TrackSort: Hashable {
    enum Key: String, CaseIterable, Identifiable {
        case original, title, artist, album, duration

        var id: String { rawValue }

        var label: String {
            switch self {
            case .original: "Original Order"
            case .title: "Title"
            case .artist: "Artist"
            case .album: "Album"
            case .duration: "Duration"
            }
        }
    }

    var key: Key = .original
    /// A to Z, shortest first. Original Order is always ascending.
    var ascending = true

    static let original = TrackSort(key: .original)
    static let title = TrackSort(key: .title)
    static let artist = TrackSort(key: .artist)
    static let album = TrackSort(key: .album)
    static let duration = TrackSort(key: .duration)

    var label: String { key.label }
    var isOriginal: Bool { key == .original }

    /// A click on `column`'s header: a new column sorts ascending, the active one reverses, and a click on a column
    /// already reversed goes back to the original order.
    func toggled(_ column: Key) -> TrackSort {
        guard column != .original else { return .original }
        guard key == column else { return TrackSort(key: column) }
        return ascending ? TrackSort(key: column, ascending: false) : .original
    }

    /// `indices` of `tracks` in this order. Text sorts ignore case and accents and compare numbers naturally;
    /// songs without an album or a duration go last in either direction; ties keep their original order.
    /// `length` is the song's length as shown in its row (the real one once known), so Duration order matches
    /// what's on screen.
    func ordered(_ tracks: [Track], indices: [Int], length: (Track) -> TimeInterval? = { $0.duration }) -> [Int] {
        guard key != .original else { return indices }
        return indices.sorted { a, b in
            let ta = tracks[a], tb = tracks[b]
            switch compare(ta, tb, length: length) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a < b
            }
        }
    }

    /// The whole list in this order.
    func sorted(_ tracks: [Track], length: (Track) -> TimeInterval? = { $0.duration }) -> [Track] {
        guard key != .original else { return tracks }
        return ordered(tracks, indices: Array(tracks.indices), length: length).map { tracks[$0] }
    }

    /// What a long album's or playlist's header Play queues: the whole collection in the order shown (this sort; Find's
    /// filter doesn't narrow it), from its first song, as Play from a sorted row does. Shuffle draws from the
    /// collection itself.
    func headerQueue(_ tracks: [Track], shuffled: Bool, length: (Track) -> TimeInterval? = { $0.duration }) -> [Track] {
        shuffled ? tracks : sorted(tracks, length: length)
    }

    private func compare(_ a: Track, _ b: Track, length: (Track) -> TimeInterval?) -> ComparisonResult {
        let flip = !ascending
        switch key {
        case .original: return .orderedSame
        case .title: return Self.text(a.title, b.title, flip: flip)
        case .artist:
            let byArtist = Self.text(a.artistLine, b.artistLine, flip: flip)
            return byArtist == .orderedSame ? Self.text(a.title, b.title) : byArtist
        case .album:
            let byAlbum = Self.text(a.album?.title ?? "", b.album?.title ?? "", flip: flip)
            guard byAlbum == .orderedSame else { return byAlbum }
            // Within one album, its own track order in either direction; songs without a number after the numbered
            // ones. (Every pair must agree, or the sort isn't consistent: [2, nil, 1] would otherwise loop.)
            return Self.missingLast(a.trackNumber, b.trackNumber, flip: false)
        case .duration:
            return Self.missingLast(length(a), length(b), flip: flip)
        }
    }

    private static func missingLast<T: Comparable>(_ a: T?, _ b: T?, flip: Bool) -> ComparisonResult {
        switch (a, b) {
        case let (x?, y?):
            guard x != y else { return .orderedSame }
            return (x < y) != flip ? .orderedAscending : .orderedDescending
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        }
    }

    /// Empty strings sort after everything else, in either direction.
    private static func text(_ a: String, _ b: String, flip: Bool = false) -> ComparisonResult {
        switch (a.isEmpty, b.isEmpty) {
        case (true, true): return .orderedSame
        case (true, false): return .orderedDescending
        case (false, true): return .orderedAscending
        case (false, false):
            let result = a.localizedStandardCompare(b)
            guard flip else { return result }
            return result == .orderedAscending ? .orderedDescending : result == .orderedDescending ? .orderedAscending : .orderedSame
        }
    }
}

/// What a long collection shows: the Find query, then the sort, applied to the full track list.
struct TrackListing {
    /// Indices into the full list, in display order.
    let shown: [Int]
    /// The whole list in display order (the sort without the filter): what Play from a sorted row queues.
    let playOrder: [Int]
    let filtering: Bool

    init(tracks: [Track], query: String, sort: TrackSort, enabled: Bool, length: (Track) -> TimeInterval? = { $0.duration }) {
        let query = enabled ? query.trimmingCharacters(in: .whitespaces) : ""
        let sort = enabled ? sort : .original
        filtering = !query.isEmpty
        shown = sort.ordered(tracks, indices: TrackFilter.matches(tracks, query: query), length: length)
        playOrder = sort.ordered(tracks, indices: Array(tracks.indices), length: length)
    }

    /// Where row `index` sits in `playOrder`, to start playback there.
    func playStart(forRow index: Int) -> Int? {
        guard let original = shown[safe: index] else { return nil }
        return playOrder.firstIndex(of: original)
    }
}

/// More › Sort By on album and playlist pages: every order the page offers, with a checkmark on the current one,
/// then the direction. The table header sorts by Title, Album and Duration with a click; this reaches Artist and
/// Original Order too, and the keyboard and VoiceOver have both ways.
struct SortByMenu: View {
    @Binding var sort: TrackSort
    var options: [TrackSort.Key]

    var body: some View {
        Menu("Sort By", systemImage: "arrow.up.arrow.down") {
            Picker("Sort By", selection: Binding(get: { sort.key }, set: { sort = TrackSort(key: $0) })) {
                ForEach(options) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if !sort.isOriginal {
                Divider()
                Picker("Direction", selection: Binding(get: { sort.ascending }, set: { sort.ascending = $0 })) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
    }
}

/// The page's sort, for the hero's More menu (`HeroActions.sorting`).
struct TrackSorting {
    var sort: Binding<TrackSort>
    var options: [TrackSort.Key]
}
