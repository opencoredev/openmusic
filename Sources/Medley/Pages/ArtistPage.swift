import MedleyCore
import SwiftUI

struct ArtistPage: View {
    let provider: ProviderID
    let id: String
    let preview: Artist?

    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let p = model.provider(provider) {
                Loadable(key: "artist:\(provider.rawValue):\(id)") {
                    try await p.artist(id: id)
                } content: { detail in
                    ArtistContent(detail: detail)
                } placeholder: {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                            // The action row is reserved at its final size so the name never moves.
                            ArtistHero(artist: preview, name: preview?.name, subtitle: preview?.subtitle) {
                                HStack(spacing: 10) {
                                    SkeletonBlock(width: 52, height: 52, circle: true).opacity(0.6).padding(.trailing, 4)
                                    SkeletonBlock(width: 96, height: 32, radius: 16).opacity(0.6)
                                    SkeletonBlock(width: 96, height: 32, radius: 16).opacity(0.6)
                                    SkeletonBlock(width: 32, height: 32, circle: true).opacity(0.6)
                                }
                            }
                            .padding(.bottom, ArtistHero<EmptyView>.spacingBelow - Metrics.sectionSpacing)
                            VStack(alignment: .leading, spacing: 12) {
                                SkeletonBlock(width: 140, height: 22).padding(.horizontal, Metrics.pageInset)
                                TrackListSkeleton(rows: 5, style: .playlist, showsHeader: false)
                                    .padding(.horizontal, Metrics.pageInset - 10)
                            }
                            ShelvesSkeleton(shelves: 1)
                        }
                        .padding(.bottom, 40)
                    }
                    .pageBackground()
                    .compactHeightEnvironment()
                }
            }
        }
        .navigationTitle(preview?.name ?? "Artist")
    }
}

private struct ArtistContent: View {
    let detail: ArtistDetail
    @Environment(AppModel.self) private var model
    @Environment(\.showsServiceMarks) private var showsMarks

    var body: some View {
        let artist = detail.artist
        let context = AppModel.PlayingFrom(title: artist.name, route: .artist(artist.provider, id: artist.providerID, preview: artist))
        let route = Route.artist(artist.provider, id: artist.providerID, preview: artist)
        ScrollView {
            // Lazy like `ScrollPage`: only the shelves on screen are laid out when the page's width changes.
            LazyVStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                ArtistHero(artist: artist, name: artist.name, subtitle: artist.subtitle) {
                    // The same row as album and playlist pages: Play, Shuffle, Follow, Radio, More. The model's follow
                    // state is shared with every artist context menu, and a refused follow puts the button back.
                    HeroActions(item: .artist(artist), route: route, enabled: !detail.topTracks.isEmpty, onPhoto: true,
                                reported: detail.isFollowed, radioSeed: detail.radioSeed) { shuffled in
                        model.play(detail.topTracks, shuffled: shuffled, from: context)
                    }
                }
                .environment(\.showsServiceMarks, showsMarks)
                .padding(.bottom, ArtistHero<EmptyView>.spacingBelow - Metrics.sectionSpacing)

                if !detail.topTracks.isEmpty {
                    TopSongs(tracks: detail.topTracks, context: context)
                }
                albumShelf("Albums", detail.albums)
                albumShelf("Singles & EPs", detail.singles)
                albumShelf("Appears On", detail.appearsOn)
                if !detail.playlists.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Featured On")
                        Carousel(items: detail.playlists.map(MediaItem.playlist)) { MediaCard(item: $0) }
                    }
                }
                if !detail.related.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Similar Artists")
                        Carousel(items: detail.related) { ArtistCard(artist: $0) }
                    }
                }
                if let bio = detail.bio, !bio.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "About \(artist.name)")
                        ExpandableText(text: bio, lineLimit: 4, font: .body, lineSpacing: 3, debugKey: "bio-more")
                            .foregroundStyle(.readableSecondary)
                            .frame(maxWidth: 680, alignment: .leading)
                            .padding(.horizontal, Metrics.pageInset)
                    }
                }
            }
            .padding(.bottom, 40)
            .modifier(LayoutProbe(key: "page-content"))
            // The artist's songs and albums all come from the artist's service.
            .environment(\.showsServiceMarks, false)
            .environment(\.cardSubtitleStyle, .discography)
        }
        .pageBackground()
        .compactHeightEnvironment()
        // The page's follow flag becomes the model's, so the artist's cards and menus say the same.
        .task(id: artist.id) { model.noteSaved(.artist(artist), reported: detail.isFollowed) }
    }

    @ViewBuilder
    private func albumShelf(_ title: String, _ albums: [Album]) -> some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: title.titleCased())
                Carousel(items: albums.map(MediaItem.album)) { MediaCard(item: $0) }
            }
        }
    }
}

/// The top songs as a grid of Home's Quick picks rows across the page: the large two-line row (52 pt artwork, the
/// title, the album under it), read down the first column then the next, with "Show All" for the rest. Three
/// columns once the grid has room for three of Quick picks' 320 pt columns (a 1300 pt window with the sidebar),
/// two from 560 pt, one below (the queue open in a small window). Its header is a plain `SectionHeader`, so
/// "Show All" lines up with the shelves below.
struct TopSongs: View {
    let tracks: [Track]
    let context: AppModel.PlayingFrom
    @State private var expanded = false
    /// The grid's column count, written only when it changes (not on every frame of a resize or sidebar slide).
    @State private var columnCount = 2
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Columns for a grid `width` points wide: three of Quick picks' 320 pt featured columns and their 24 pt gaps,
    /// else two from 560 pt, else one.
    static func columns(forWidth width: CGFloat) -> Int {
        width >= 3 * 320 + 2 * 24 ? 3 : width >= 560 ? 2 : 1
    }

    /// Songs shown before Show All: whole rows of the grid (three rows of three, five rows of two, ten in one column).
    static func collapsedCount(columns: Int) -> Int { columns == 3 ? 9 : 10 }

    /// The row's second line: the song's album, as under Home's Quick picks (the artist would only repeat the page's
    /// name), cut after a whole word (`FittedText`). A song without one shows its artists instead (`CompactTrackRow`'s
    /// default). When every top song comes from one album the rows have no second line (an empty subtitle): nine
    /// copies of one album's name said nothing (round 28's "you seem pretty sad for a girl so…" on every row).
    static func subtitle(for track: Track, oneAlbum: Bool) -> String? {
        guard let album = track.album?.title, !album.isEmpty else { return nil }
        return oneAlbum ? "" : album
    }

    /// Whether every top song names the same album (two songs or more; case and spacing ignored).
    static func sharesOneAlbum(_ tracks: [Track]) -> Bool {
        let albums = tracks.map { $0.album?.title.trimmingCharacters(in: .whitespaces).lowercased() ?? "" }
        guard tracks.count > 1, let first = albums.first, !first.isEmpty else { return false }
        return albums.allSatisfy { $0 == first }
    }

    var body: some View {
        let collapsed = Self.collapsedCount(columns: columnCount)
        let shown = expanded ? tracks : Array(tracks.prefix(collapsed))
        let perColumn = Int((Double(shown.count) / Double(columnCount)).rounded(.up))
        let showsDuration = tracks.contains { $0.duration != nil }
        let oneAlbum = Self.sharesOneAlbum(tracks)
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Top Songs") {
                if tracks.count > collapsed {
                    Button(expanded ? "Show Less" : "Show All") {
                        withAnimation(Motion.Expansion.topSongs.animation(reduce: reduceMotion)) { expanded.toggle() }
                    }
                    .buttonStyle(SubtleLinkStyle(readable: true))
                    .font(.system(size: 13, weight: .semibold))
                }
            }
            .modifier(LayoutProbe(key: "top-songs-header"))
            HStack(alignment: .top, spacing: 24) {
                ForEach(0..<columnCount, id: \.self) { column in
                    VStack(spacing: 0) {
                        ForEach(Array(shown.enumerated().dropFirst(column * perColumn).prefix(perColumn)), id: \.element.id) { index, track in
                            // The whole list plays as the queue, wherever you start.
                            CompactTrackRow(track: track, context: context, play: {
                                model.play(tracks, startAt: index, from: context)
                            }, showsGlyph: false, showsDuration: showsDuration, large: true, subtitle: Self.subtitle(for: track, oneAlbum: oneAlbum))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .padding(.horizontal, Metrics.pageInset)
            .onGeometryChange(for: Int.self) { Self.columns(forWidth: $0.size.width - 2 * Metrics.pageInset) } action: { columnCount = $0 }
            .modifier(LayoutProbe(key: "top-songs"))
        }
    }
}

/// The artist's photo across the whole header, with the name, the "Artist" line and the buttons along its bottom left.
/// The photo reaches up behind the toolbar. A nil name draws a skeleton of the same height, so nothing moves when it
/// arrives.
///
/// The header is about 380 pt tall at a 1440 pt window (`height(forWidth:)`). The photo fills it edge to edge, scaled
/// and shifted so the face Vision found sits 62–72% of the way across (`PhotoFocus.placement`), clear of the name. A
/// small or face-filling photo isn't blown up past 2.5 device pixels per source pixel, nor so far that the head no
/// longer fits: then it stops short of the leading edge, and its own left edge, stretched and blurred, carries on
/// under the name instead of a separate gradient. The sharp photo appears once its focus is known.
///
/// Dark mode, and light mode over a photo whose leading side is dark: white text, and a gradient that darkens only
/// behind it, from the leading edge behind the name, the "Artist" line and the buttons, black 0.45 → clear over half
/// the width, deeper when what's under them would leave white text under 4.5:1 (`PhotoFocus.scrimForWhiteText`, from
/// the photo's tone grid), eased in from above the name and full from there to the bottom edge.
///
/// Light mode over a pale leading side (the darkest tone under the text at `paleTone` or more): dark text on a light
/// shade of the photo's own tint, and the album page's buttons (`HeroActions` off the photo): a black scrim there
/// left a muddy mid-gray band that faded back to white under the buttons (round 27).
///
/// The photo then fades out, drawn over the shade so the header's last row is one color with no step where the page
/// starts: dark mode into the page background over the bottom 45% (a pale photo, average brightness over 0.6, also
/// gets black 0.3 over the whole header); light mode into the photo's tint (`TintColor.heroColor`, as album and
/// playlist pages use), over the bottom `lightFade` points under white text and the bottom `paleFade` of the header
/// under dark text. In light mode that tint carries on below the header and fades into the page over
/// `Metrics.heroFade`, as an album's wash does, so "Top Songs" starts on it.
struct ArtistHero<Actions: View>: View {
    let artist: Artist?
    let name: String?
    let subtitle: String?
    @ViewBuilder var actions: Actions

    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.showsServiceMarks) private var showsMarks
    @State private var width: CGFloat = 1000
    /// The name, the "Artist" line and the buttons, in the header's coordinates: what the leading scrim keeps readable.
    @State private var textFrame: CGRect = .zero
    /// The name and the "Artist" line's frame, kept out of SwiftUI's sight (`HeroGeometry` isn't observable): it
    /// can change on every frame of a sidebar slide or resize, and only the decision it feeds is state.
    @State private var geometry = HeroGeometry()
    /// Dark text on a light shade (light mode over a pale leading side), published only when it flips.
    @State private var darkText = false
    /// How far the backdrop reaches above the page content, so overscrolling never shows a gap.
    private let topExtension: CGFloat = 120

    /// The analyzed photo and what was found in it (nil focus: the photo couldn't be loaded; use the default crop).
    @State private var analysis: (url: URL, focus: PhotoFocus?)?
    /// The photo's average color, for light mode's fade and the wash below (`ArtworkTintCache`, as `HeroWash`).
    @State private var tint: TintColor?

    private var tintURL: URL? { artist?.artwork?.url(minPixels: 64) }

    /// The photo the focus is computed from.
    private var focusURL: URL? { artist?.artwork?.url(minPixels: PhotoFocusCache.pixels) }

    static func height(forWidth width: CGFloat) -> CGFloat {
        // About 380 pt at a 1440 pt window with the sidebar (a 1207 pt page), 320 in a narrow one.
        min(380, max(320, (width * 0.315).rounded()))
    }

    /// The bottom part of the header that fades into the page in dark mode.
    static var fadeFraction: CGFloat { 0.45 }
    /// Light mode's fade from the photo into its tint along the header's bottom edge under white text, in points: it
    /// starts level with the buttons' middle (their glass ends 28 pt above the edge at the bottom padding of 18), so
    /// only their last few points sit on its first, nearly clear, part.
    static var lightFade: CGFloat { 36 }
    /// Under dark text the photo fades into its tint over the header's bottom 40%: the dark name and buttons read on
    /// the tint, so the photo can dissolve into the page as gently as in dark mode.
    static var paleFade: CGFloat { 0.4 }
    /// Light mode uses dark text when the darkest tone-grid cell under the name and the "Artist" line has at least this
    /// luminance (the buttons sit on light pills of their own then): near-black text then reads at 5.6:1 or more before the light shade lifts it further.
    static var paleTone: Double { 0.3 }
    /// Below the action row, inside the header: the photo's fade ends this far under the buttons.
    static var bottomPadding: CGFloat { 18 }
    /// From the header's bottom edge to the first section ("Top Songs"): with `bottomPadding` and the 10 pt under the
    /// 32 pt capsules in the 52 pt row, about 40 pt from the buttons to the heading, the gap between sections
    /// elsewhere on the page (the page's 40 pt section spacing here left about 80).
    static var spacingBelow: CGFloat { 8 }
    /// The leading scrim at its weakest: black 0.45 at the leading edge, clear halfway across.
    static var baseScrim: Double { 0.45 }

    /// Light mode over a pale leading side: dark text on a light shade.
    private func usesDarkText(focus: PhotoFocus?, placement: HeroPhotoPlacement?) -> Bool {
        guard scheme != .dark, let placement, let focus,
              let darkest = focus.darkestTone(in: geometry.nameFrame.insetBy(dx: -8, dy: -4), placement: placement) else { return false }
        return darkest >= Self.paleTone
    }

    /// Works the dark-text decision out again from the current photo, width and name frame, and writes the state
    /// only when it changes, so geometry moving under a slide never invalidates the header.
    private func refreshDarkText() {
        let resolved = resolvedFocus
        let banner = CGSize(width: width, height: Self.height(forWidth: width))
        let value = usesDarkText(focus: resolved ?? nil, placement: placement(resolved, banner: banner))
        if darkText != value { darkText = value }
    }

    private func placement(_ resolved: PhotoFocus??, banner: CGSize) -> HeroPhotoPlacement? {
        resolved.map { ($0 ?? PhotoFocus(aspect: 1, subject: nil, primary: nil, source: .none)).placement(banner: banner, displayScale: displayScale) }
    }

    var body: some View {
        let height = Self.height(forWidth: width)
        let titleSize = Font.heroTitleSize(width: width)
        let darkText = darkText
        ZStack(alignment: .bottomLeading) {
            Color.clear
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    if let name, !name.isEmpty {
                        Text(name)
                            .font(.system(size: titleSize, weight: .heavy))
                            .tracking(-titleSize * 0.022)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .shadow(color: .black.opacity(darkText ? 0 : 0.25), radius: 12, y: 2)
                            .modifier(DebugFrame(key: "artist-name"))
                            .modifier(LayoutProbe(key: "artist-hero-name"))
                    } else {
                        SkeletonBlock(width: 280, height: titleSize * 0.8, radius: 8)
                            .opacity(0.6)
                            .padding(.vertical, titleSize * 0.12)
                    }
                    // Always takes a line, so the name sits at the same height before the audience loads. The
                    // service mark sits in that line as its first word, never alone under the name: with no
                    // audience to show, the line reads "Artist" after the mark.
                    // The same logo-first tag as album, playlist and shelf headers: "◉ YouTube Music · 12M monthly
                    // listeners" (or "· Artist" with no audience). Without marks (one service) just the audience.
                    HStack(spacing: 6) {
                        if let artist, showsMarks {
                            ServiceTag(provider: artist.provider, style: .inline)
                            Text("·")
                        }
                        Text(metadataLine)
                    }
                    .font(.system(size: 14, weight: .medium))
                    .modifier(DebugFrame(key: "artist-meta"))
                    .modifier(LayoutProbe(key: "artist-hero-meta"))
                }
                .opacity(HeroTextProbe.shared.hidden ? 0 : 1)
                .onGeometryChange(for: CGRect.self) { geo in
                    let f = geo.frame(in: .named("artist-hero"))
                    return CGRect(x: f.minX.rounded(), y: f.minY.rounded(), width: f.width.rounded(), height: f.height.rounded())
                } action: { geometry.nameFrame = $0; refreshDarkText() }
                // In a narrow pane (the queue open in a small window) Shuffle, Radio and Follow drop their words.
                ViewThatFits(in: .horizontal) {
                    actions
                    actions.labelStyle(.iconOnly)
                }
                .frame(height: 52)
                .modifier(LayoutProbe(key: "hero-actions"))
                .environment(\.heroLabelsHidden, HeroTextProbe.shared.hidden)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("artist-hero")) } action: { textFrame = $0 }
            .foregroundStyle(darkText ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.white))
            // The buttons follow: the album page's on a light shade, the glass ones over a dark photo.
            .environment(\.artistHeroDarkText, darkText)
            .padding(.horizontal, Metrics.pageInset)
            .padding(.bottom, Self.bottomPadding)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .modifier(LayoutProbe(key: "artist-hero"))
        .coordinateSpace(.named("artist-hero"))
        .background(alignment: .top) {
            backdrop(height: height, darkText: darkText)
                .offset(y: -topExtension)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0; refreshDarkText() }
        .onChange(of: scheme) { refreshDarkText() }
        .onChange(of: displayScale) { refreshDarkText() }
        .task(id: tintURL) {
            guard let url = tintURL else { tint = nil; return }
            if let hit = ArtworkTintCache.shared.cached(url) { tint = hit; return }
            let value = await ArtworkTintCache.shared.tint(for: url)
            guard !Task.isCancelled else { return }
            tint = value
        }
        .task(id: focusURL) {
            // A photo analyzed before decides at once; a new one once Vision is done.
            refreshDarkText()
            guard let url = focusURL, PhotoFocusCache.shared.cached(url) == nil, analysis?.url != url else { return }
            let focus = await PhotoFocusCache.shared.focus(for: url)
            guard !Task.isCancelled else { return }
            analysis = (url, focus)
            refreshDarkText()
        }
    }


    private var metadataLine: String {
        if let subtitle, !subtitle.trimmingCharacters(in: .whitespaces).isEmpty { return subtitle }
        if artist != nil { return "Artist" }
        return " "
    }

    /// The analysis for the current photo: nil while it's still being found, `.some(nil)` when it couldn't be made.
    private var resolvedFocus: PhotoFocus?? {
        guard let url = focusURL else { return nil }
        if let hit = PhotoFocusCache.shared.cached(url) { return .some(hit) }
        if let analysis, analysis.url == url { return .some(analysis.focus) }
        return nil
    }

    /// The band above the header and the header, top to bottom.
    /// The photo's tint as light mode's page color under the header, or the page background until it's known.
    private var lightTint: Color {
        let shown = tint ?? tintURL.flatMap { ArtworkTintCache.shared.cached($0) }
        return shown?.heroColor(for: .light) ?? .pageBackground
    }

    @ViewBuilder
    private func backdrop(height: CGFloat, darkText: Bool) -> some View {
        let banner = CGSize(width: width, height: height)
        let resolved = resolvedFocus
        let focus = resolved ?? nil
        let placement = placement(resolved, banner: banner)
        let light = scheme != .dark
        let pale = !light && (focus?.mean.map { max($0.red, $0.green, $0.blue) > 0.6 } ?? false)
        let scrim = leadingScrimStops(focus: focus, placement: placement, banner: banner, extraDarkening: pale ? 0.3 : 0)
        let fadeEnd: Color = light ? lightTint : .pageBackground
        let span = light ? (darkText ? Self.paleFade : min(0.5, Self.lightFade / max(height, 1))) : Self.fadeFraction
        let darkest = placement.flatMap { focus?.darkestTone(in: geometry.nameFrame.insetBy(dx: -8, dy: -4), placement: $0) }
        let note = darkText
            ? String(format: "light, dark text: the photo under the name and Artist line is pale (darkest tone %.2f, %.2f or more uses dark text); a light shade of the photo's tint from the leading edge, clear %.0f%% across; fades into the photo's tint over the bottom %.0f%%, the tint fading into the page below",
                     darkest ?? 0, Self.paleTone, 50.0, Self.paleFade * 100)
            : (light ? "light, white text: " : "dark: ") + scrim.note
                + (light ? String(format: "; fades into the photo's tint over the bottom %.0f pt, the tint fading into the page below", Self.lightFade)
                         : String(format: "; fades into the page over the bottom %.0f%%", Self.fadeFraction * 100))
        let total = topExtension + height
        // One photo from the window's top edge through the header: it carries on above the header, under the toolbar
        // and when the page is pulled down (what `backgroundExtensionEffect()` does at a safe-area edge; inside a
        // scroll view there's no safe area). It ends at the header's bottom edge, where the frame clips it.
        ZStack(alignment: .top) {
            bannerPhoto(placement, banner: banner, above: topExtension, below: 0)
            if pale { Color.black.opacity(0.3).frame(height: total) }
            VStack(spacing: 0) {
                Color.clear.frame(height: topExtension)
                ZStack(alignment: .top) {
                    Group {
                        if darkText {
                            // A light shade of the photo's tint behind the dark text, as the black one behind white.
                            LinearGradient(stops: [.init(color: lightTint.opacity(0.7), location: 0), .init(color: lightTint.opacity(0.45), location: 0.2),
                                                   .init(color: lightTint.opacity(0.15), location: 0.36), .init(color: lightTint.opacity(0), location: 0.5)],
                                           startPoint: .leading, endPoint: .trailing)
                        } else {
                            LinearGradient(stops: scrim.stops, startPoint: .leading, endPoint: .trailing)
                        }
                    }
                    .mask {
                        LinearGradient(stops: scrimVerticalStops(top: scrim.top), startPoint: .top, endPoint: .bottom)
                    }
                    // Over the shade, so the bottom edge is one color: the page's in dark mode, the photo's tint in light.
                    pageFade(height: height, end: fadeEnd, span: span)
                }
                .frame(height: height, alignment: .top)
            }
        }
        .frame(height: total, alignment: .top)
        .clipped()
        .frame(width: width, height: total, alignment: .top)
        // Light mode: the tint carries on under the page and fades into it, as an album's wash does.
        .overlay(alignment: .bottom) {
            if light {
                LinearGradient(stops: [.init(color: fadeEnd, location: 0), .init(color: fadeEnd.opacity(0.5), location: 0.4),
                                       .init(color: fadeEnd.opacity(0.15), location: 0.75), .init(color: fadeEnd.opacity(0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: width, height: Metrics.heroFade)
                    .offset(y: Metrics.heroFade)
            }
        }
        .onChange(of: note, initial: true) {
            if LayoutProbe.enabled { DebugProbes.note("artist-scrim", note) }
        }
    }

    /// The photo in a frame `above` + `below` points taller than the banner (the extra above and below it): blurred
    /// while its focus is being found, then the sharp photo placed by `placement` over its own stretched leading edge,
    /// on a blurred copy where it doesn't reach the frame's top or bottom. No photo: the placeholder glyph.
    @ViewBuilder
    private func bannerPhoto(_ placement: HeroPhotoPlacement?, banner: CGSize, above: CGFloat, below: CGFloat) -> some View {
        let frame = CGSize(width: banner.width, height: banner.height + above + below)
        ZStack(alignment: .topLeading) {
            if focusURL == nil {
                ArtworkView(artwork: artist?.artwork, size: max(banner.width, 600), cornerRadius: 0, symbol: "music.mic")
                    .frame(width: frame.width, height: frame.height)
            } else if let placement {
                let y = placement.origin.y + above
                if y > 0 || y + placement.size.height < frame.height {
                    ArtworkBackdrop(artwork: artist?.artwork, blur: 30).frame(width: frame.width, height: frame.height)
                }
                if placement.origin.x > 0.5 {
                    PhotoEdgeFill(artwork: artist?.artwork)
                        .frame(width: placement.origin.x + Self.feather(placement), height: placement.size.height)
                        .offset(y: y)
                }
                ArtworkView(artwork: artist?.artwork, size: placement.size.width, cornerRadius: 0, symbol: "music.mic")
                    .frame(width: placement.size.width, height: placement.size.height)
                    .mask {
                        // A soft leading edge where the photo meets its stretched edge.
                        let feather = placement.origin.x > 0.5 ? Self.feather(placement) / placement.size.width : 0
                        LinearGradient(stops: [.init(color: feather > 0 ? .clear : .black, location: 0), .init(color: .black, location: feather)],
                                       startPoint: .leading, endPoint: .trailing)
                    }
                    .offset(x: placement.origin.x, y: y)
            } else {
                ArtworkBackdrop(artwork: artist?.artwork, blur: 30)
                    .frame(width: frame.width, height: frame.height)
            }
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .clipped()
    }

    /// The leading scrim's vertical extent over the header: eased in from the top down to just above the name (the
    /// photo's upper left keeps its own tone), then full behind the name, the "Artist" line and the buttons down to
    /// the header's bottom edge, where the page fade over it takes the photo into the page.
    private func scrimVerticalStops(top: CGFloat) -> [Gradient.Stop] {
        [.init(color: .clear, location: 0), .init(color: .black.opacity(0.3), location: top * 0.55),
         .init(color: .black.opacity(0.75), location: top * 0.85), .init(color: .black, location: top),
         .init(color: .black, location: 1)]
    }

    /// How far the photo's leading edge blends into the stretched edge beside it.
    private static func feather(_ placement: HeroPhotoPlacement) -> CGFloat {
        min(140, placement.size.width * 0.14)
    }

    /// The photo fading into `end` over the header's bottom `span` (a fraction of its height), ending on it exactly.
    /// Eased at both ends, so neither where it starts nor where it meets the page reads as a line.
    private func pageFade(height: CGFloat, end: Color, span: CGFloat) -> some View {
        let start = 1 - span
        return LinearGradient(stops: [.init(color: end.opacity(0), location: 0), .init(color: end.opacity(0), location: start),
                                      .init(color: end.opacity(0.12), location: start + span * 0.2),
                                      .init(color: end.opacity(0.42), location: start + span * 0.45),
                                      .init(color: end.opacity(0.75), location: start + span * 0.7),
                                      .init(color: end.opacity(0.94), location: start + span * 0.88),
                                      .init(color: end, location: 1)],
                              startPoint: .top, endPoint: .bottom)
            .frame(height: height)
    }

    /// Black from the leading edge behind the name and buttons: 0.45 fading to clear halfway across, held deeper over
    /// the name when the photo there would leave white text under 4.5:1. `top` is where it has fully eased in from
    /// the top (a fraction of the banner's height), so the photo's upper left keeps its own tone; `note` is for the
    /// capture's log.
    private func leadingScrimStops(focus: PhotoFocus?, placement: HeroPhotoPlacement?, banner: CGSize,
                                   extraDarkening: Double) -> (stops: [Gradient.Stop], top: CGFloat, note: String) {
        let text = textFrame.insetBy(dx: -8, dy: -4)
        let tone = placement.flatMap { p in focus?.brightestTone(in: text, placement: p) }
        let needed = tone.map { PhotoFocus.scrimForWhiteText(over: $0, extraDarkening: extraDarkening) } ?? 0
        let strength = min(0.82, max(Self.baseScrim, needed))
        let textEnd = min(0.9, max(0, text.maxX / max(banner.width, 1)))
        // Linear from the base strength to clear at 50%, unless the name needs more by its end; then held to the name's
        // end and eased out over the next fifth of the width.
        let baseAtEnd = Self.baseScrim * max(0, 1 - textEnd / 0.5)
        // Both ways it ends on an eased tail, so its edge never reads as a block.
        let held = max(needed, baseAtEnd)
        let stops: [Gradient.Stop] = needed > baseAtEnd && textEnd > 0
            ? [.init(color: .black.opacity(strength), location: 0), .init(color: .black.opacity(held), location: textEnd),
               .init(color: .black.opacity(held * 0.6), location: min(1, textEnd + 0.1)),
               .init(color: .black.opacity(held * 0.22), location: min(1, textEnd + 0.22)),
               .init(color: .clear, location: min(1, textEnd + 0.36))]
            : [.init(color: .black.opacity(strength), location: 0), .init(color: .black.opacity(strength * 0.55), location: 0.2),
               .init(color: .black.opacity(strength * 0.2), location: 0.36), .init(color: .clear, location: 0.5)]
        let top = max(0, (text.minY - 12) / max(banner.height, 1))
        let note = String(format: "black %.2f at the leading edge (what's under the name, Artist line and buttons needs %.2f for 4.5:1; photo at %.0f%% there), they end %.0f%% across",
                          strength, needed, 100.0, textEnd * 100)
        return (stops, top, note)
    }
}

/// The leading strip beside a photo that stops short of the header's leading edge: the photo's leftmost few
/// percent stretched across it and blurred, so the photo's own backdrop carries on under the name.
private struct PhotoEdgeFill: View {
    let artwork: Artwork?
    @State private var strip: CGImage?

    var body: some View {
        Color.black
            .overlay {
                if let strip {
                    Image(decorative: strip, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .blur(radius: 14, opaque: true)
                }
            }
            .clipped()
            .task(id: artwork?.url(minPixels: 256)?.absoluteString) {
                guard let url = artwork?.url(minPixels: 256),
                      let image = await ArtworkPipeline.shared.load(url, pixels: 256)?.cgImage, !Task.isCancelled else { return }
                let width = max(2, image.width / 25)
                strip = image.cropping(to: CGRect(x: 0, y: 0, width: width, height: image.height)) ?? image
            }
    }
}

/// Shuffle, Radio and Follow on the artist image: dark glass capsules with white labels, so the labels stay at 4.5:1
/// or more over a pale photo or backdrop (a white 20% fill over a light gray read about 2.5:1). The glass is always
/// the dark variant: in light mode the regular glass brightened toward white under the white text.
struct HeroButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(HeroLabelVisibility())
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .modifier(HeroButtonFill(pressed: configuration.isPressed))
            .contentShape(Capsule())
            .motionScale(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Council captures only: hides the artist header's white text (the name, the "Artist" line and the buttons'
/// labels, not the glass under them) for one capture, so the check can read the brightest pixel next to each letter
/// without the letters. Never set in a normal run.
@MainActor @Observable final class HeroTextProbe {
    static let shared = HeroTextProbe()
    var hidden = false
}

/// Council captures only: hides the secondary text on Home's cards (the featured card's eyebrow and description, the
/// Made for You cards' captions) for one capture, so the contrast check can read what lies under each letter. Read
/// only while probes are on, so a normal run never observes it.
@MainActor @Observable final class TextContrastProbe {
    static let shared = TextContrastProbe()
    var hidden = false
    static var hides: Bool { LayoutProbe.enabled && shared.hidden }
}

extension EnvironmentValues {
    @Entry var heroLabelsHidden = false
    /// The artist header draws dark text on a light shade (light mode over a pale photo): its buttons are the album
    /// page's, not the glass ones made for a photo.
    @Entry var artistHeroDarkText = false
}

struct HeroLabelVisibility: ViewModifier {
    @Environment(\.heroLabelsHidden) private var hidden
    func body(content: Content) -> some View { content.opacity(hidden ? 0 : 1) }
}

private struct HeroButtonFill: ViewModifier {
    let pressed: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.tint(.black.opacity(pressed ? 0.4 : 0.3)), in: .capsule)
                .environment(\.colorScheme, .dark)
        } else {
            content
                .background(.black.opacity(pressed ? 0.45 : 0.35), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5))
        }
    }
}

/// The artist header's raw geometry, outside SwiftUI's observation: writing it invalidates nothing. `ArtistHero`
/// reads it when it works out the dark-text decision, which is the only thing published.
@MainActor
final class HeroGeometry {
    var nameFrame: CGRect = .zero
}
