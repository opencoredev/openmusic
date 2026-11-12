import AppKit
import OpenMusicCore
import SwiftUI

/// One titled row of a browse page, laid out by its `ShelfStyle`.
struct ShelfView: View {
    let shelf: Shelf
    let provider: ProviderID
    /// Show the service glyph next to the title (when both services are mixed on one page).
    var showsGlyph = true
    /// The first shelf on Home: bigger cards and rows, as the "what to play now" answer.
    var featured = false

    /// Items not to show (the one Home features above its shelves).
    var excluding: String? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.isCompactHeight) private var compact

    private var shown: [MediaItem] {
        guard let excluding else { return shelf.items }
        return shelf.items.filter { $0.id != excluding }
    }

    /// The shelf holds the service's liked-songs playlist, which OpenMusic shows as Library › Liked Songs and plays from
    /// every signed-in service (`MediaCard.showsAsLikedSongs`): with two services the shelf is no longer one
    /// service's, so its header names none and each other card carries its own service's mark instead.
    private var mixesServices: Bool {
        model.libraryProviders.count > 1 && shown.contains { $0.isServiceLikedSongs }
    }

    var body: some View {
        let mixed = mixesServices
        VStack(alignment: .leading, spacing: featured ? 14 : 12) {
            SectionHeader(title: shelf.title.titleCased(), subtitle: shelf.subtitle ?? sharedHeroCaption, provider: showsGlyph && !mixed ? provider : nil) {
                if shelf.moreToken != nil || shown.count > 8 {
                    SeeAllButton { model.open(.shelf(provider, shelf)) }
                }
            }
            if shelf.isCategoryShelf {
                CategoryTileRows(categories: shelf.categories)
            } else if mixed {
                items
            } else {
                // A shelf comes from one service and its header already says which.
                items.environment(\.showsServiceMarks, false)
            }
        }
    }

    @ViewBuilder private var items: some View {
        switch shelf.style {
        case .carousel:
            // One artwork shape per shelf: 16:9 when most items are videos, square otherwise.
            let videos = shelf.isVideoShelf
            let aspect: CGFloat = videos ? 9 / 16 : 1
            // A short window's first shelf takes the compact card size too (the larger featured size pushed its
            // captions under the player bar at 960×620 when Home had no Quick picks to lead with).
            Carousel(items: shown, widths: featured && !compact ? Metrics.featuredCardWidths : videos ? Metrics.videoCardWidths : Metrics.cardWidths, artworkAspect: aspect) { item in
                switch item {
                case .artist(let a): ArtistCard(artist: a)
                default: MediaCard(item: item)
                }
            }
            .environment(\.cardArtworkAspect, aspect)
        case .artists:
            Carousel(items: shown) { item in
                if case .artist(let a) = item { ArtistCard(artist: a) } else { MediaCard(item: item) }
            }
        case .hero:
            // A caption every card shares ("Made for You" over each mix) says it once, as the shelf's subtitle.
            let shared = sharedHeroCaption
            // The mixes fill the row's width: at their 300 pt cap two of them left ~50 pt bare in a 960 pt window.
            Carousel(items: shown, widths: HeroCard.widths, artworkAspect: 1, fills: true) { item in
                HeroCard(item: item, caption: shared == nil ? heroCaption(item) : nil)
            }
        case .trackList:
            // A short window shows two rows, so a second complete choice fits above the player bar.
            TrackGridShelf(tracks: shown.compactMap { if case .track(let t) = $0 { t } else { nil } }, title: shelf.title.titleCased(),
                           rows: compact ? 2 : 4, featured: featured && !compact)
        }
    }

    /// The caption when every card of a hero shelf would show the same one; nil when they differ (Music labels each
    /// card on its own then: "Listen Again", "Made for You") or the shelf isn't a hero shelf.
    private var sharedHeroCaption: String? {
        guard shelf.style == .hero, let first = shown.first.flatMap(heroCaption) else { return nil }
        return shown.allSatisfy { heroCaption($0) == first } ? first : nil
    }

    private func heroCaption(_ item: MediaItem) -> String? {
        switch item {
        case .playlist(let p) where p.owner == provider.displayName: "Made for You"
        case .playlist: "Playlist"
        case .album(let a): a.kind.label
        default: nil
        }
    }
}

/// A row of cards that shows only whole cards: the column count and card width come from the available
/// width and `widths`, and the row pages sideways by a screenful. Arrows appear at the edges on hover
/// (or when tabbed to), and trackpad scrolling snaps to card edges.
struct Carousel<Item: Identifiable & Hashable, Cell: View>: View {
    let items: [Item]
    var spacing: CGFloat = Metrics.cardSpacing
    var widths: ClosedRange<CGFloat> = Metrics.cardWidths
    /// Height / width of the cell's artwork, to center the arrows on it.
    var artworkAspect: CGFloat = 1
    /// Cards grow past `widths` to fill the row (`Metrics.cardLayout`).
    var fills = false
    @ViewBuilder var cell: (Item) -> Cell

    @State private var available: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = ScrollPosition(idType: Int.self)
    @State private var firstIndex = 0
    @State private var hovering = false
    @State private var settle: Task<Void, Never>?
    /// The width as it is now, while `available` waits for it to settle. A plain reference, so writing it on every
    /// frame of a slide renders nothing; paging reads it so it never pages by a stale column count.
    @State private var latest = LatestWidth()
    /// True between a width change and its settling: the page arrows hide, since they sit on the old viewport.
    @State private var settling = false
    @FocusState private var arrowFocus: Bool
    /// The shelf's name for council captures' layout probes (`carouselProbe`); nil elsewhere.
    @Environment(\.carouselProbe) private var probe

    /// Room around the cards for the hover tile, which reaches past each card's edge.
    private let bleed: CGFloat = 12

    @Environment(\.isCompactHeight) private var compact

    /// A short window shrinks standard cards to `compactCardWidths`; other ranges (videos, tiles, songs) stay.
    private var fittedWidths: ClosedRange<CGFloat> {
        compact && widths == Metrics.cardWidths ? Metrics.compactCardWidths : widths
    }

    var body: some View {
        let layout = Metrics.cardLayout(available: available, widths: fittedWidths, spacing: spacing, fills: fills)
        let gap = layout.spacing
        let viewport = CGFloat(layout.columns) * (layout.width + gap) - gap
        let canBack = firstIndex > 0
        let canForward = firstIndex + layout.columns < items.count
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: gap) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    cell(item)
                        .frame(width: layout.width)
                        .environment(\.shelfCellWidth, layout.width)
                        // Council captures check that only whole cards show (`narrow-home-queue`).
                        .modifier(LayoutProbe(key: probe.map { "\($0)-card-\(index)" } ?? ""))
                        .id(index)
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, bleed)
        }
        .scrollIndicators(.never)
        .modifier(LayoutProbe(key: probe.map { "\($0)-viewport" } ?? ""))
        .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
        .scrollPosition($position, anchor: .leading)
        .contentMargins(.horizontal, bleed, for: .scrollContent)
        .onScrollGeometryChange(for: Int.self) { geo in
            let offset = geo.contentOffset.x + geo.contentInsets.leading
            return max(0, Int((offset / max(1, layout.width + gap)).rounded()))
        } action: { _, index in firstIndex = index }
        // Exactly N whole cards wide (plus the tile's bleed), so the next card is never half visible.
        // A maximum, not a fixed width: a fixed width would become the column's minimum and stop the
        // page from shrinking when the inspector opens.
        .frame(minWidth: 0, maxWidth: available > 0 ? viewport + bleed * 2 : .infinity, alignment: .leading)
        .padding(.vertical, -bleed)
        .overlay(alignment: .topLeading) {
            if layout.columns < items.count {
                let arrowY = layout.width * artworkAspect / 2 - 15
                HStack {
                    PageArrow(direction: .back, enabled: canBack) { page(-1, layout) }
                    Spacer(minLength: 0)
                    PageArrow(direction: .forward, enabled: canForward) { page(1, layout) }
                }
                .focused($arrowFocus)
                .padding(.horizontal, -3)
                .frame(width: viewport + bleed * 2)
                .offset(y: arrowY)
                .opacity((hovering || arrowFocus) && !settling ? 1 : 0)
                .animation(Motion.hover, value: hovering)
            }
        }
        .padding(.horizontal, Metrics.pageInset - bleed)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The card layout follows the width once it settles: while the sidebar or panel slides, every frame's
        // new width would re-measure every card of every shelf (Home ran at 30 fps). The shelf keeps its cards
        // and clips or leaves room at the end until the width stops changing.
        .onGeometryChange(for: CGFloat.self) { $0.size.width - Metrics.pageInset * 2 } action: { width in
            latest.width = width
            guard available > 0 else { available = width; return }
            scheduleSettle()
        }
        // A shelf that leaves and comes back (the page's lazy stack, a page switch) settles on the width it has now:
        // a settle cancelled as it left used to keep the old layout, a third card's slice past the page's margin after
        // the window was set back to 960 (council `narrow-home-queue`). Both go through the settle's task, never a
        // write during layout: a shelf appearing mid-resize that changed its card width (and height) at once looped
        // AppKit's Update Constraints in the resize self-test.
        .onAppear { if latest.width > 0, abs(latest.width - available) > 0.5 { scheduleSettle() } }
        .onDisappear { if latest.width > 0, abs(latest.width - available) > 0.5 { scheduleSettle() } else { settle?.cancel(); settle = nil; settling = false } }
        .onHover { hovering = $0 }
        .accessibilityAction(named: "Next Page") { page(1, layout) }
        .accessibilityAction(named: "Previous Page") { page(-1, layout) }
    }

    /// Applies the width once it has stopped changing: after 120 ms with no change, whatever the width is then
    /// (read from `latest`, not the width that started the wait), so the last change of a slide or of a frame the
    /// app sets always lands. Runs a few times per resize, never per frame.
    private func scheduleSettle() {
        settle?.cancel()
        if !settling { settling = true }
        settle = Task { @MainActor in
            var seen = latest.width
            while true {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                if latest.width == seen { break }
                seen = latest.width
            }
            applyLatestWidth()
        }
    }

    private func applyLatestWidth() {
        if latest.width > 0, abs(latest.width - available) > 0.5 { available = latest.width }
        if settling { settling = false }
    }

    private func page(_ direction: Int, _ shown: Metrics.CardLayout) {
        guard !items.isEmpty else { return }
        // Mid-resize, page by what fits now: apply the pending width at once rather than paging by the old layout.
        var layout = shown
        if latest.width > 0, latest.width != available {
            settle?.cancel()
            available = latest.width
            settling = false
            layout = Metrics.cardLayout(available: latest.width, widths: fittedWidths, spacing: spacing, fills: fills)
        }
        let target = min(max(0, firstIndex + direction * layout.columns), max(0, items.count - layout.columns))
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { position.scrollTo(id: target, anchor: .leading) }
    }
}

extension EnvironmentValues {
    /// The width a `Carousel` gives each cell, for cells that lay out from a known width (hero cards).
    @Entry var shelfCellWidth: CGFloat? = nil
    /// Names a `Carousel`'s layout probes (`<name>-viewport`, `<name>-card-<index>`) in council captures.
    @Entry var carouselProbe: String? = nil
}

/// A round chevron button at the edge of a shelf.
private struct PageArrow: View {
    enum Direction { case back, forward }
    let direction: Direction
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: direction == .back ? "chevron.left" : "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .frame(width: 30, height: 30)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(IconButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0)
        .help(direction == .back ? "Previous" : "Next")
        .accessibilityLabel(direction == .back ? "Previous page" : "Next page")
    }
}

/// Songs laid out in columns of four that page sideways (YouTube "Quick picks", search Songs).
/// As many columns as fit, never a cut-off column.
struct TrackGridShelf: View {
    let tracks: [Track]
    let title: String
    var showsGlyph = true
    var rows = 4
    /// Bigger rows for the first shelf on Home.
    var featured = false

    @Environment(AppModel.self) private var model
    @Environment(\.isCompactHeight) private var compact

    private struct Column: Identifiable, Hashable {
        let id: Int
        let tracks: [Track]
    }

    var body: some View {
        let rows = max(1, min(rows, tracks.count))
        let columns = stride(from: 0, to: tracks.count, by: rows).map { start in
            Column(id: start, tracks: Array(tracks[start..<min(start + rows, tracks.count)]))
        }
        let showsDuration = tracks.contains { $0.duration != nil }
        // A short window's rows are narrower, so a ~600 pt page (the queue open) still gets two columns. Rows are
        // text, so the columns have no maximum width: they fill the page and the grid ends where "Show All" ends
        // (a 420 pt cap left a 40 pt gap at its right in a 960 pt window).
        Carousel(items: columns, spacing: 24, widths: featured ? 320...2000 : compact ? 260...2000 : 290...2000, artworkAspect: 0) { column in
            VStack(spacing: 0) {
                ForEach(Array(column.tracks.enumerated()), id: \.element.id) { offset, track in
                    CompactTrackRow(track: track, context: .init(title: title), play: {
                        model.play(tracks, startAt: column.id + offset, from: .init(title: title))
                    }, showsGlyph: showsGlyph, showsDuration: showsDuration, large: featured)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

/// A grid of cards with a bounded card width (160–210 pt); the column count follows from the width.
struct MediaGrid: View {
    let items: [MediaItem]
    var onReachEnd: (() -> Void)? = nil

    @State private var available: CGFloat = 0
    @Environment(\.isCompactHeight) private var compact

    var body: some View {
        let layout = Metrics.cardLayout(available: available, widths: compact ? Metrics.compactCardWidths : Metrics.cardWidths)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(layout.width), spacing: layout.spacing, alignment: .top), count: layout.columns), alignment: .leading, spacing: 28) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Group {
                    if case .artist(let a) = item {
                        ArtistCard(artist: a)
                    } else {
                        MediaCard(item: item)
                    }
                }
                .environment(\.shelfCellWidth, layout.width)
                .onAppear { if index >= items.count - 6 { onReachEnd?() } }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
        .padding(.horizontal, Metrics.pageInset)
    }
}

/// The standard scrolling page container: large title, then sections, on the page background.
/// `accessory` sits at the trailing end of the title line (a quiet "Connect Spotify").
struct ScrollPage<Content: View, Accessory: View>: View {
    enum TitleStyle {
        /// A 32 pt page title ("New", "Liked Songs").
        case page
        /// Home's time-of-day greeting as the page's title: 28 pt bold, a step above the section titles under it.
        case greeting
    }

    var title: String?
    var subtitle: String? = nil
    var titleStyle: TitleStyle = .page
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory

    var body: some View {
        ScrollView {
            ScrollPageStack(title: title, subtitle: subtitle, titleStyle: titleStyle, content: content, accessory: accessory)
        }
        .pageBackground()
        .compactHeightEnvironment()
    }
}

private struct ScrollPageStack<Content: View, Accessory: View>: View {
    let title: String?
    let subtitle: String?
    let titleStyle: ScrollPage<Content, Accessory>.TitleStyle
    let content: Content
    let accessory: Accessory
    @Environment(\.isCompactHeight) private var compact

    var body: some View {
        // Lazy, so only the sections on screen are laid out. A page's width changes on every frame while the
        // sidebar slides or the window resizes; with a plain VStack every shelf on Home and New refitted its cards
        // each time, and the sidebar's move showed 7 of its 17 frames (`OPENMUSIC_SELFTEST=sidebar`).
        LazyVStack(alignment: .leading, spacing: compact ? 28 : Metrics.sectionSpacing) {
            if let title {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        switch titleStyle {
                        case .page:
                            Text(title)
                                .font(.pageTitle)
                                .tracking(-0.4)
                        case .greeting:
                            Text(title)
                                .font(.system(size: 28, weight: .bold))
                                .tracking(-0.3)
                                .foregroundStyle(.primary)
                                .accessibilityAddTraits(.isHeader)
                        }
                        if let subtitle {
                            Text(subtitle).font(.system(size: 15)).foregroundStyle(.readableSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                    accessory
                }
                .padding(.horizontal, Metrics.pageInset)
                .padding(.bottom, titleStyle == .greeting ? (compact ? -12 : -16) : -12)
            }
            content
        }
        .padding(.top, compact ? 14 : 20)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(LayoutProbe(key: "page-content"))
    }
}

extension ScrollPage where Accessory == EmptyView {
    init(title: String? = nil, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, content: content, accessory: { EmptyView() })
    }
}

// MARK: - Moods & genres

extension Playlist {
    /// Providers mark mood/genre entries (not real playlists) with `extra["category"]`.
    var isCategory: Bool { extra["category"] != nil }
}

extension Shelf {
    /// A row of music videos, drawn with 16:9 artwork (most of its items are videos).
    var isVideoShelf: Bool {
        guard !items.isEmpty else { return false }
        return items.filter(\.isVideo).count * 2 > items.count
    }
    var categories: [Playlist] { items.compactMap { if case .playlist(let p) = $0, p.isCategory { p } else { nil } } }
    /// A shelf made only of mood/genre entries, drawn as colored tiles instead of artwork cards.
    var isCategoryShelf: Bool { !items.isEmpty && categories.count == items.count }
}

/// Moods & genres as two rows of colored tiles, fitted to whole columns and paged like other shelves.
struct CategoryTileRows: View {
    let categories: [Playlist]

    private struct Column: Identifiable, Hashable {
        let id: Int
        let tiles: [Playlist]
    }

    var body: some View {
        let rows = categories.count > 6 ? 2 : 1
        let columns = stride(from: 0, to: categories.count, by: rows).map { Column(id: $0, tiles: Array(categories[$0..<min($0 + rows, categories.count)])) }
        Carousel(items: columns, spacing: 14, widths: 190...250, artworkAspect: CGFloat(rows) * CategoryTile.height / 220) { column in
            VStack(spacing: 14) {
                ForEach(column.tiles) { CategoryTile(category: $0, width: nil) }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

/// An adaptive grid of category tiles, for "See All".
struct CategoryTileGrid: View {
    let categories: [Playlist]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 14)], alignment: .leading, spacing: 14) {
            ForEach(categories) { CategoryTile(category: $0, width: nil) }
        }
        .padding(.horizontal, Metrics.pageInset)
    }
}

/// A rounded tile filled with the category's color and its name in white. Opens the category's playlists.
struct CategoryTile: View {
    let category: Playlist
    var width: CGFloat? = 210
    static let height: CGFloat = 92

    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let fill = CategoryColor.fill(hex: category.extra["color"], title: category.title)
        Button(action: open) {
            Text(category.title)
                .font(.system(size: 18, weight: .bold))
                .tracking(-0.2)
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 13)
                .frame(width: width, height: Self.height, alignment: .bottomLeading)
                .frame(maxWidth: width == nil ? .infinity : nil, alignment: .bottomLeading)
                .background {
                    ZStack {
                        LinearGradient(colors: [fill.top, fill.bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
                        // A soft light from the top-right corner gives each tile some depth.
                        RadialGradient(colors: [.white.opacity(0.16), .clear], center: .topTrailing, startRadius: 0, endRadius: 160)
                    }
                }
                .overlay(.white.opacity(hovering ? 0.08 : 0))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(TilePressStyle())
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        .accessibilityLabel(category.title)
        .accessibilityHint("Shows playlists for this mood or genre")
    }

    private func open() {
        if let token = category.extra["moreToken"] {
            model.open(.shelf(category.provider, Shelf(id: category.providerID, title: category.title, style: .carousel, items: [], moreToken: token)))
        } else {
            model.open(.playlist(category))
        }
    }
}

private struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .motionScale(configuration.isPressed ? Motion.pressScale : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// Tile colors from the provider's "#RRGGBB" stripe color, darkened (hue kept) until the 15 pt bold white label,
/// which counts as large text, reads at 3:1 or better at the gradient's lightest corner and about 4:1 under the label.
/// Categories without a color get a stable hue from their name.
nonisolated enum CategoryColor {
    struct Fill { let top: Color; let bottom: Color }

    static func fill(hex: String?, title: String) -> Fill {
        // A gray or missing stripe color gives no identity: use a stable hue from the title instead,
        // so a row never shows three gray tiles. Reds move to rose or amber (no red in this app).
        let rgb = awayFromRed(hex.flatMap(parse).flatMap { saturation($0) >= 0.22 ? $0 : nil } ?? fallback(title))
        let base = darkened(rgb, toLuminance: 0.26)
        let deep = darkened(base, toLuminance: 0.13)
        return Fill(top: color(base), bottom: color(deep))
    }

    static func parse(_ hex: String) -> (Double, Double, Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 8 { s.removeFirst(2) } // AARRGGBB
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    static func luminance(_ c: (Double, Double, Double)) -> Double {
        func ch(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * ch(c.0) + 0.7152 * ch(c.1) + 0.0722 * ch(c.2)
    }

    /// Scales the color toward black (keeping its hue) until its luminance is at most `target`.
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
        let hi = max(c.0, c.1, c.2), lo = min(c.0, c.1, c.2)
        return hi == 0 ? 0 : (hi - lo) / hi
    }

    static func hue(_ c: (Double, Double, Double)) -> Double {
        let ns = NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        return Double(ns.hueComponent) * 360
    }

    /// Hues within about 18° of pure red turn into rose (from the purple side) or amber (from the orange side).
    static func awayFromRed(_ c: (Double, Double, Double)) -> (Double, Double, Double) {
        let h = hue(c)
        guard saturation(c) > 0.15, h >= 342 || h <= 18 else { return c }
        let ns = NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        let shifted = NSColor(hue: (h >= 342 ? 328 : 30) / 360, saturation: min(ns.saturationComponent, 0.7), brightness: ns.brightnessComponent, alpha: 1)
            .usingColorSpace(.sRGB) ?? ns
        return (Double(shifted.redComponent), Double(shifted.greenComponent), Double(shifted.blueComponent))
    }

    /// A stable hue from the title (FNV-1a), skipping the red band.
    static func fallback(_ title: String) -> (Double, Double, Double) {
        let hash = title.unicodeScalars.reduce(UInt32(2166136261)) { ($0 ^ $1.value) &* 16777619 }
        let hue = 25 + Double(hash % 305) // 25°…330°
        let ns = NSColor(hue: hue / 360, saturation: 0.6, brightness: 0.8, alpha: 1).usingColorSpace(.sRGB)!
        return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
    }

    private static func color(_ c: (Double, Double, Double)) -> Color {
        Color(.sRGB, red: c.0, green: c.1, blue: c.2)
    }
}

/// A width a view keeps without observing it (see `Carousel.latest`).
private final class LatestWidth {
    var width: CGFloat = 0
}
