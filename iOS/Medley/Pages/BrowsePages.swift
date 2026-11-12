import MedleyCore
import SwiftUI

// MARK: Shelves

struct ShelfView: View {
    let shelf: Shelf

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if shelf.moreToken != nil || shelf.items.count > 12 {
                LinkedSectionHeader(title: shelf.title, subtitle: shelf.subtitle, route: .shelf(shelf, shelf.items.first?.provider ?? .youtubeMusic))
            } else {
                SectionHeader(title: shelf.title, subtitle: shelf.subtitle)
            }
            if shelf.isCategoryShelf {
                CategoryTiles(categories: shelf.categories)
            } else {
                switch effectiveStyle {
                case .hero: HeroRow(items: shelf.items)
            case .trackList: TrackColumns(shelf: shelf)
            case .artists:
                Carousel {
                    ForEach(artists) { ArtistCircle(artist: $0) }
                }
                case .carousel:
                    Carousel {
                        ForEach(shelf.items) { MediaCard(item: $0) }
                    }
                }
            }
        }
    }

    /// A shelf of only songs reads better as rows than as cards.
    private var effectiveStyle: ShelfStyle {
        if shelf.style == .carousel, !shelf.items.isEmpty, shelf.items.allSatisfy({ if case .track = $0 { true } else { false } }) {
            return .trackList
        }
        if shelf.style == .carousel, !shelf.items.isEmpty, shelf.items.allSatisfy({ if case .artist = $0 { true } else { false } }) {
            return .artists
        }
        return shelf.style
    }

    private var artists: [Artist] {
        shelf.items.compactMap { if case .artist(let a) = $0 { a } else { nil } }
    }
}

/// Songs in pages of four rows that scroll sideways, like Apple Music's Top Songs.
private struct TrackColumns: View {
    let shelf: Shelf
    @Environment(AppModel.self) private var model

    var body: some View {
        let tracks = shelf.items.compactMap { if case .track(let t) = $0 { t } else { nil } }
        let columns = stride(from: 0, to: tracks.count, by: 4).map { Array(tracks[$0..<min($0 + 4, tracks.count)]) }
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(Array(columns.enumerated()), id: \.offset) { c, column in
                    VStack(spacing: 0) {
                        ForEach(Array(column.enumerated()), id: \.element.id) { r, track in
                            TrackRow(track: track) {
                                model.play(tracks, startAt: c * 4 + r, from: PlaybackContext(kind: .other, title: shelf.title))
                            }
                            .padding(.vertical, 5)
                            if r < column.count - 1 { Divider().padding(.leading, 60) }
                        }
                    }
                    .containerRelativeFrame(.horizontal) { width, _ in width - Metrics.gutter * 2 - 24 }
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, Metrics.gutter, for: .scrollContent)
    }
}

/// Big cards for featured items: wide artwork with the title over a scrim.
private struct HeroRow: View {
    let items: [MediaItem]
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 12) {
                ForEach(items) { item in
                    Button { model.open(item: item) } label: { card(item) }
                        .buttonStyle(.plain)
                        .contextMenu { ItemMenu(item: item) }
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, Metrics.gutter, for: .scrollContent)
    }

    private func card(_ item: MediaItem) -> some View {
        ArtworkView(artwork: item.artwork, points: 340)
            .frame(height: 220)
            .containerRelativeFrame(.horizontal) { width, _ in width - Metrics.gutter * 2 - 24 }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.title3.bold()).lineLimit(2)
                    if let subtitle = item.subtitle { Text(subtitle).font(.subheadline).lineLimit(1).opacity(0.85) }
                }
                .foregroundStyle(.white)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 24)
                .background(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.45), location: 0.45),
                                                    .init(color: .black.opacity(0.7), location: 1)],
                                           startPoint: .top, endPoint: .bottom))
            }
            .clipShape(.rect(cornerRadius: 12))
            .accessibilityElement(children: .combine)
    }
}

/// Shelves stacked in a scrolling page.
struct ShelfStack: View {
    let shelves: [Shelf]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                ForEach(shelves) { ShelfView(shelf: $0) }
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }
}

// MARK: Home / New

/// Loads shelves from every service that can browse, in parallel.
@MainActor
func loadShelves(_ model: AppModel, _ capability: ProviderCapabilities) async throws -> [Shelf] {
    let tasks = model.browseProviders(capability).map { provider in
        Task { capability == .home ? try await provider.home() : try await provider.explore() }
    }
    var shelves: [Shelf] = []
    var firstError: (any Error)?
    for task in tasks {
        do { shelves += try await task.value } catch { firstError = firstError ?? error }
    }
    if shelves.isEmpty, let firstError { throw firstError }
    return shelves.filter { !$0.items.isEmpty }
}

struct HomeTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack(path: model.path(.home)) {
            Loader(key: "home") { try await loadShelves(model, .home) } content: { shelves in
                if shelves.isEmpty {
                    ContentUnavailableView("Nothing Here Yet", systemImage: "music.note.house",
                                           description: Text("Play some music and Home fills up with picks for you."))
                } else {
                    ShelfStack(shelves: shelves)
                }
            }
            .navigationTitle("Home")
            // The large title and the account button share one row, as in Music.
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { AccountButton() } }
            .medleyDestinations()
        }
    }
}

struct NewTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack(path: model.path(.new)) {
            Loader(key: "new") { try await loadShelves(model, .explore) } content: { shelves in
                ShelfStack(shelves: shelves)
            }
            .navigationTitle("New")
            // The large title and the account button share one row, as in Music.
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { AccountButton() } }
            .medleyDestinations()
        }
    }
}

// MARK: See All

struct ShelfPage: View {
    let shelf: Shelf
    let provider: ProviderID
    @Environment(AppModel.self) private var model

    var body: some View {
        Loader(key: "shelf:\(shelf.id)") { try await expanded() } content: { full in
            ScrollView {
                if full.isCategoryShelf {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                        ForEach(full.categories) { CategoryTile(category: $0) }
                    }
                    .padding(.horizontal, Metrics.gutter)
                } else if full.items.allSatisfy({ if case .track = $0 { true } else { false } }) {
                    let tracks = full.items.compactMap { if case .track(let t) = $0 { t } else { nil } }
                    LazyVStack(spacing: 0) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                            TrackRow(track: track) { model.play(tracks, startAt: i, from: PlaybackContext(kind: .other, title: full.title)) }
                                .padding(.vertical, 5)
                                .padding(.horizontal, Metrics.gutter)
                            Divider().padding(.leading, Metrics.gutter + 60)
                        }
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16, alignment: .top)], spacing: 22) {
                        ForEach(full.items) { item in
                            if case .artist(let a) = item { ArtistCircle(artist: a, size: 150) } else { MediaCard(item: item, width: 160) }
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                }
            }
        }
        .navigationTitle(shelf.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func expanded() async throws -> Shelf {
        guard let token = shelf.moreToken, let provider = model.provider(provider) else { return shelf }
        let more = try await provider.shelf(moreToken: token)
        return more.items.isEmpty ? shelf : more
    }
}

// MARK: Moods & genres

extension Playlist {
    /// Providers mark mood/genre entries (not real playlists) with `extra["category"]`.
    var isCategory: Bool { extra["category"] != nil }
}

extension Shelf {
    var categories: [Playlist] { items.compactMap { if case .playlist(let p) = $0, p.isCategory { p } else { nil } } }
    var isCategoryShelf: Bool { !items.isEmpty && categories.count == items.count }
}

/// Moods and genres as two rows of colored tiles that scroll sideways.
private struct CategoryTiles: View {
    let categories: [Playlist]

    var body: some View {
        let rows = categories.count > 6 ? 2 : 1
        let columns = stride(from: 0, to: categories.count, by: rows).map { Array(categories[$0..<min($0 + rows, categories.count)]) }
        Carousel(spacing: 12) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                VStack(spacing: 12) {
                    ForEach(column) { CategoryTile(category: $0).frame(width: 180) }
                }
            }
        }
    }
}

/// A tile in the category's color with its name in white. Opens the category's playlists.
struct CategoryTile: View {
    let category: Playlist
    @Environment(AppModel.self) private var model

    var body: some View {
        let fill = CategoryColor.fill(hex: category.extra["color"], title: category.title)
        Button(action: open) {
            Text(category.title)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 84, alignment: .bottomLeading)
                .background {
                    ZStack {
                        LinearGradient(colors: [fill.top, fill.bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
                        RadialGradient(colors: [.white.opacity(0.16), .clear], center: .topTrailing, startRadius: 0, endRadius: 140)
                    }
                }
                .clipShape(.rect(cornerRadius: 12))
                .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(PressScale())
        .accessibilityHint("Shows playlists for this mood or genre")
    }

    private func open() {
        if let token = category.extra["moreToken"] {
            model.open(.shelf(Shelf(id: category.providerID, title: category.title, style: .carousel, items: [], moreToken: token), category.provider))
        } else {
            model.open(.playlist(category))
        }
    }
}

/// Tile colors from the provider's "#RRGGBB" color, darkened (hue kept) so the white label reads.
/// Categories without a usable color get a stable hue from their name.
nonisolated enum CategoryColor {
    struct Fill { let top: Color; let bottom: Color }

    static func fill(hex: String?, title: String) -> Fill {
        let rgb = hex.flatMap(parse).flatMap { saturation($0) >= 0.22 ? $0 : nil } ?? fallback(title)
        let base = darkened(rgb, toLuminance: 0.24)
        let deep = darkened(base, toLuminance: 0.12)
        return Fill(top: color(base), bottom: color(deep))
    }

    static func parse(_ hex: String) -> (Double, Double, Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 8 { s.removeFirst(2) }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    static func luminance(_ c: (Double, Double, Double)) -> Double {
        func ch(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * ch(c.0) + 0.7152 * ch(c.1) + 0.0722 * ch(c.2)
    }

    static func darkened(_ c: (Double, Double, Double), toLuminance target: Double) -> (Double, Double, Double) {
        var c = c
        var steps = 0
        while luminance(c) > target, steps < 60 {
            c = (c.0 * 0.95, c.1 * 0.95, c.2 * 0.95)
            steps += 1
        }
        return c
    }

    static func saturation(_ c: (Double, Double, Double)) -> Double {
        let mx = max(c.0, c.1, c.2), mn = min(c.0, c.1, c.2)
        return mx == 0 ? 0 : (mx - mn) / mx
    }

    /// A stable hue from the title (FNV-1a), at a fixed saturation and value.
    static func fallback(_ title: String) -> (Double, Double, Double) {
        var hash: UInt32 = 2_166_136_261
        for byte in title.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        let h = Double(hash % 360) / 60, s = 0.55, v = 0.85
        let i = Int(h) % 6, f = h - Double(Int(h))
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    static func color(_ c: (Double, Double, Double)) -> Color { Color(.sRGB, red: c.0, green: c.1, blue: c.2) }
}
