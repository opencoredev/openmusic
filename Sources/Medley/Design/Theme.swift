import AppKit
import MedleyCore
import SwiftUI

// Direction: a quiet first-party macOS 27 app where the album artwork supplies the color.
// - Reference: Apple Music on macOS 27 (artwork-led color, monochrome chrome, Liquid Glass toolbar)
//   and Finder's sidebar (monochrome symbols, selection in the user's own accent color).
// - Palette: system label colors only (primary, secondary, tertiary, quaternary, separator). The only
//   other color is a soft, desaturated average of the current artwork behind album and playlist headers
//   and in the full-screen player. Brand colors appear once, as the logos in Settings › Accounts.
// - Type: SF Pro on the Apple Music scale: bold page titles, semibold section headers, secondary subtitles.
// - Avoiding: an app accent color, zebra stripes, colored dots on every item, custom chips over native controls.

extension ProviderID {
    /// Brand color, used only for the logo in Settings › Accounts.
    var brandColor: Color {
        self == .youtubeMusic
            ? Color(.sRGB, red: 1.0, green: 0.0, blue: 0.2)
            : Color(.sRGB, red: 0.114, green: 0.725, blue: 0.329)
    }
}

enum Metrics {
    static let pageInset: CGFloat = 28
    static let sectionSpacing: CGFloat = 40
    /// Card widths in shelves and grids. The column count comes from this range, so a small window never
    /// gets bigger cards than a large one.
    static let cardWidths: ClosedRange<CGFloat> = 160...210
    /// The first shelf on Home is presented larger.
    static let featuredCardWidths: ClosedRange<CGFloat> = 210...260
    /// Card widths in a short window (see `compactHeight`): smaller artwork, so a second row of choices fits
    /// above the player. Text stays the same size.
    /// Music-video cards (16:9 artwork).
    static let videoCardWidths: ClosedRange<CGFloat> = 220...280
    static let compactCardWidths: ClosedRange<CGFloat> = 140...176
    /// Below this window height, pages use their short layout: smaller artwork and hero, tighter spacing,
    /// two rows of Quick picks. Type sizes don't change.
    static let compactHeight: CGFloat = 720
    /// Kept for fixed-size uses (skeletons before the width is known).
    static let cardWidth: CGFloat = 180
    static let cardSpacing: CGFloat = 20
    static let artworkRadius: CGFloat = 8
    /// Padding of the hover tile around a card's artwork and text. Tile radius = artwork radius + this.
    static let cardTilePadding: CGFloat = 8
    /// Hover and selection highlights on rows.
    static let rowRadius: CGFloat = 8
    /// Album and playlist heroes: the artwork color fades into the page over this distance.
    static let heroFade: CGFloat = 340
    /// Wide enough for "0:00:00" in tabular digits at track-row size, so hour-long durations never wrap.
    static let durationWidth: CGFloat = 58
    /// Track tables stop growing here (rows include their 10 pt inner padding), so a song's duration and
    /// actions stay within reach of its title in a wide window. Cards and shelves still use the full width.
    static let trackTableMaxWidth: CGFloat = 1160
    /// Album track lists stop sooner: one line per song (title, a time), so at 1160 pt a short title sat about
    /// 1,000 pt from its "…" and time. 880 pt of content from the hero's leading edge, as in Music's album page,
    /// plus the rows' 10 pt padding on each side; a narrower pane fills.
    static let albumTrackListMaxWidth: CGFloat = 880 + 20

    /// The track table's width for `style`.
    static func trackListMaxWidth(_ style: TrackListStyle) -> CGFloat {
        style == .album ? albumTrackListMaxWidth : trackTableMaxWidth
    }

    /// Card widths change in steps of this many points, so a shelf's card size and height change a few times while
    /// a pane slides instead of on every frame. The column count always comes from the real width (snapping the
    /// width first could drop a column that fits and leave a large gap). What the step leaves over goes into the
    /// gaps between cards (`CardLayout.spacing`), so the last card ends on the trailing margin, under "Show All".
    static let cardWidthStep: CGFloat = 4
    /// The widest a gap may grow to take up what's left over, as a multiple of the shelf's spacing. Past it (two
    /// capped 280 pt video cards in a 672 pt row would sit 112 pt apart), the cards grow past `widths.upperBound`
    /// instead, as `fills` rows do.
    static let cardSpacingStretch: CGFloat = 1.5

    struct CardLayout: Equatable {
        var columns: Int
        var width: CGFloat
        /// The gap between cards: at least the shelf's spacing, plus an equal share of what the stepped card width
        /// left over, so `columns × width + (columns − 1) × spacing` is the available width.
        var spacing: CGFloat
    }

    /// How many cards of `widths` fit in `available` points, how wide each one is, and how far apart they sit.
    ///
    /// `fills`: the cards grow past `widths.upperBound` rather than leave the row's end empty. For large cards
    /// (Home's mixes, 236–300 pt) the cap left about 50 pt bare at the end of a 672 pt row (two 300 pt cards where
    /// two 326 pt ones fill it, and three would fall under the minimum). Still in `cardWidthStep` steps.
    static func cardLayout(available: CGFloat, widths: ClosedRange<CGFloat> = cardWidths, spacing: CGFloat = cardSpacing,
                           fills: Bool = false) -> CardLayout {
        guard available > 0 else { return CardLayout(columns: 1, width: widths.lowerBound, spacing: spacing) }
        let columns = max(1, Int(((available + spacing) / (widths.lowerBound + spacing)).rounded(.down)))
        let width = (available - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let stepped = max(1, (width / cardWidthStep).rounded(.down) * cardWidthStep)
        guard columns > 1 else { return CardLayout(columns: 1, width: fills ? stepped : min(widths.upperBound, stepped), spacing: spacing) }
        func gap(_ width: CGFloat) -> CGFloat { (available - CGFloat(columns) * width) / CGFloat(columns - 1) }
        let capped = fills ? stepped : min(widths.upperBound, stepped)
        let cardWidth = gap(capped) > spacing * cardSpacingStretch ? stepped : capped
        return CardLayout(columns: columns, width: cardWidth, spacing: max(spacing, gap(cardWidth)))
    }
}

/// Motion constants (see the direction brief): quick ease-out hovers, a rising card play button,
/// a 0.96 press, and artwork that fades in only when it wasn't cached. Page pushes stay instant.
enum Motion {
    static let hover = Animation.easeOut(duration: 0.14)
    static let reveal = Animation.easeOut(duration: 0.18)
    static let press = Animation.easeOut(duration: 0.12)
    static let artwork = Animation.easeOut(duration: 0.2)
    /// A full-screen panel opening or closing, with the artwork and controls gliding to their new place.
    static let panel = Animation.smooth(duration: 0.4)
    static let pressScale: CGFloat = 0.96
    /// How far the card play button rises as it appears.
    static let revealRise: CGFloat = 6
}

// MARK: - Reduce Motion

/// What a custom transition does as its view comes or goes. Described rather than built, so tests can read what
/// Reduce Motion picks (`Motion.Transition.movement(reduce:)`).
enum Movement: Equatable, Sendable {
    case fade
    case fadeScale(CGFloat)
    case fadeOffset(x: CGFloat, y: CGFloat)
    /// Fades while sliding down from under the view above it.
    case fadeFromTop

    var isSpatial: Bool { self != .fade }

    var transition: AnyTransition {
        switch self {
        case .fade: .opacity
        case .fadeScale(let scale): .opacity.combined(with: .scale(scale: scale))
        case .fadeOffset(let x, let y): .opacity.combined(with: .offset(x: x, y: y))
        case .fadeFromTop: .opacity.combined(with: .move(edge: .top))
        }
    }
}

extension Motion {
    /// Reduce Motion as the system has it, for code that isn't a view (menu commands, the model). Views read
    /// `accessibilityReduceMotion`, which follows the same setting.
    static var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The app's custom transitions. With Reduce Motion each is a plain crossfade: nothing scales, slides or rises.
    enum Transition: CaseIterable {
        /// The full-screen player coming up over the window (`MainWindow`).
        case fullScreenPlayer
        /// A confirmation or failure above the floating player.
        case browsingNotice
        /// The same at the top of the full-screen player.
        case fullScreenNotice
        /// A notice inside the mini player.
        case miniPlayerNotice
        /// Lyrics or Playing Next arriving beside the full-screen artwork, and leaving.
        case fullScreenPanelIn, fullScreenPanelOut
        /// A device's remote controls opening under its row in the Devices popover.
        case deviceControls
        /// The first-run flow's next step coming in from the trailing side, and going back (`FirstRunView`).
        case firstRunForward, firstRunBack

        func movement(reduce: Bool) -> Movement {
            if reduce { return .fade }
            switch self {
            case .fullScreenPlayer: return .fadeScale(0.98)
            case .browsingNotice: return .fadeOffset(x: 0, y: 8)
            case .fullScreenNotice, .miniPlayerNotice: return .fadeOffset(x: 0, y: self == .fullScreenNotice ? -8 : -6)
            case .fullScreenPanelIn: return .fadeOffset(x: 40, y: 0)
            case .fullScreenPanelOut: return .fadeOffset(x: 24, y: 0)
            case .deviceControls: return .fadeFromTop
            case .firstRunForward: return .fadeOffset(x: 36, y: 0)
            case .firstRunBack: return .fadeOffset(x: -36, y: 0)
            }
        }

        func transition(reduce: Bool) -> AnyTransition { movement(reduce: reduce).transition }
    }

    /// Things that grow or shrink in place when pressed. With Reduce Motion the change is immediate (no animation),
    /// and the chevron that turns with them is swapped for the other symbol instead of rotating.
    enum Expansion: CaseIterable {
        /// Show More / Show Less under the sidebar's Playlists and Recently Played.
        case sidebarShowMore
        /// An artist bio's More / Less.
        case inlineText
        /// An artist's Top Songs, Show All / Show Less.
        case topSongs
        /// A device's remote controls in the Devices popover, and its list of devices.
        case deviceList

        func animation(reduce: Bool) -> Animation? {
            if reduce { return nil }
            switch self {
            case .sidebarShowMore: return .snappy(duration: 0.2)
            case .inlineText, .topSongs: return .easeOut(duration: 0.2)
            case .deviceList: return .smooth(duration: 0.25)
            }
        }
    }

    /// How long the full-screen player takes to come up or go. With Reduce Motion it's a short crossfade (the
    /// transition is `.fade`); the menu command, ⇧⌘F, Escape, the close button, the artwork and the expand button
    /// all go through `AppModel.setFullScreenPlayerPresented`.
    static func fullScreenToggleDuration(opening: Bool, reduce: Bool) -> Double {
        reduce ? 0.15 : (opening ? 0.3 : 0.25)
    }

    /// A press, hover or pause scale (`motionScale`); 1 with Reduce Motion, where color and opacity carry the state.
    static func scale(_ value: CGFloat, reduce: Bool) -> CGFloat { reduce ? 1 : value }

    /// A disclosure chevron: rotated 180° when open, or with Reduce Motion the up chevron with no rotation.
    static func chevron(open: Bool, reduce: Bool) -> (symbol: String, degrees: Double) {
        reduce ? (open ? "chevron.up" : "chevron.down", 0) : ("chevron.down", open ? 180 : 0)
    }
}

extension View {
    /// `scaleEffect` for press, hover and paused feedback that Reduce Motion turns off.
    func motionScale(_ scale: CGFloat, anchor: UnitPoint = .center) -> some View {
        modifier(MotionScale(scale: scale, anchor: anchor))
    }
}

private struct MotionScale: ViewModifier {
    let scale: CGFloat
    let anchor: UnitPoint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.scaleEffect(Motion.scale(scale, reduce: reduceMotion), anchor: anchor)
    }
}

/// The chevron of a Show More row or a device's controls: turns to point up when open, or with Reduce Motion is
/// simply the up chevron.
struct DisclosureChevron: View {
    let open: Bool
    var size: CGFloat = 9
    var weight: Font.Weight = .semibold
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let chevron = Motion.chevron(open: open, reduce: reduceMotion)
        Image(systemName: chevron.symbol)
            .font(.system(size: size, weight: weight))
            .rotationEffect(.degrees(chevron.degrees))
    }
}

extension Font {
    /// Artist names over the artist banner. Scales down to 34 pt in narrow panes.
    static func heroTitleSize(width: CGFloat) -> CGFloat {
        min(56, max(34, (width * 0.06).rounded()))
    }
    /// Album and playlist titles beside the artwork, given the text column's width: bold, at most 36 pt (Music's
    /// album titles sit near 30; at 44 a long title became a heavy two-line block), down to 28 pt in a narrow pane.
    static func collectionTitleSize(width: CGFloat) -> CGFloat {
        min(36, max(28, (width * 0.065).rounded()))
    }
    static let pageTitle = Font.system(size: 32, weight: .bold)
    static let sectionTitle = Font.system(size: 22, weight: .bold)
    /// Later shelves on Home, a step under the featured card and Quick picks.
    static let secondarySectionTitle = Font.system(size: 20, weight: .bold)
    static let cardTitle = Font.system(size: 14, weight: .semibold)
    static let secondaryText = Font.system(size: 13)
    static let rowTitle = Font.system(size: 14)
    static let rowSecondary = Font.system(size: 13)
    static let tableHeader = Font.system(size: 12, weight: .medium)
}

extension Color {
    /// The content background. In dark mode it sits a step deeper than the default window gray, so artwork
    /// and the player stand out; light mode stays white like Music. The sidebar keeps its native material.
    static let pageBackground = Color(nsColor: NSColor(name: "MedleyPageBackground") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.09, green: 0.09, blue: 0.09, alpha: 1)
            : NSColor.textBackgroundColor
    })
}

// `ReadableSecondary` (secondary text that stays at 4.5:1 or more) lives in MedleyCore, so the services' own
// settings views use it too.

/// The heart on a liked song in a track list: the accent color, like Music's favorites star, so it reads as a state
/// rather than gray decoration. White on the focused accent selection, like the row's text.
struct LikedHeartStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        environment.backgroundProminence == .increased ? .white : .accentColor
    }
}

extension ShapeStyle where Self == LikedHeartStyle {
    static var likedHeart: LikedHeartStyle { LikedHeartStyle() }
}

/// A selected list row's fill, the same as a native table's: the system's selected-content (accent) color while the
/// list has keyboard focus, with white text on it, and the unemphasized gray when it doesn't, with normal text.
/// White on the accent reads 4.5:1 or more in light and dark (measured on the council captures).
enum SelectionFill {
    static func color(focused: Bool) -> Color {
        Color(nsColor: focused ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor)
    }
}

/// Secondary text over an album or playlist hero's artwork wash (year, song count, description, the owner's service
/// mark). The translucent `.secondary` measured 3.2–3.7:1 there. These opaque grays hold 4.5:1 or more on every
/// hero fill `TintColor.heroColor` can make: light #383838 is 5.1:1 on its darkest light fill (a blue pastel at 0.9
/// brightness, 0.28 saturation), dark #D9D9D9 is 5.3:1 on its lightest dark fill (a yellow at 0.34 brightness, 0.45
/// saturation), and more on the neutral fill shown before the tint is known. Hierarchy against the title and the
/// artist line comes from weight. Increased Contrast goes a step further.
struct HeroSecondary: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        let increased = environment.colorSchemeContrast == .increased
        return environment.colorScheme == .dark
            ? Color(white: increased ? 0.92 : HeroSecondary.dark)
            : Color(white: increased ? 0.14 : HeroSecondary.light)
    }

    /// sRGB gray levels: #383838 and #D9D9D9.
    static let light: Double = 56.0 / 255
    static let dark: Double = 217.0 / 255
}

extension ShapeStyle where Self == HeroSecondary {
    /// Opaque secondary text over a collection hero's wash (`HeroSecondary`).
    static var heroSecondary: HeroSecondary { HeroSecondary() }
}


extension View {
    /// Paints the deeper content background behind a page, including under the toolbar, and on a scrolling page
    /// fades scrolled content out under the toolbar (`TopScrollFade`).
    func pageBackground() -> some View {
        background(Color.pageBackground).modifier(TopScrollFade())
    }
}

/// Pages run under the toolbar so heroes reach the window's top edge. At rest nothing covers them; once the page
/// scrolls, a band of the toolbar's own material fades in over the toolbar's height and dissolves 28 pt below it,
/// so titles and rows passing under back/forward blur away instead of showing cut through. (On macOS 26 the soft
/// scroll edge effect alone left scrolled text sharp up to the window's edge.) Its opacity follows the first
/// 40 pt of scrolling, so it never pops in.
///
/// The toolbar's height comes with the scroll offset, from the same scroll geometry (its top content inset), so
/// the two can't disagree. It used to come from a separate `onGeometryChange` of the safe area: Home stays alive
/// under the full-screen player, which hides the toolbar, and that value could be left at 0 afterwards, so the
/// band never drew and scrolled cards ran sharp up under back/forward (council round 16, dark Home). The safe area
/// is still read as a second source, for a scroll view whose content insets leave the toolbar out.
private struct TopScrollFade: ViewModifier {
    private struct FadeState: Equatable {
        /// Points scrolled, 0…`ramp`.
        var scrolled: CGFloat
        /// The scroll view's top content inset: the toolbar's height when the page runs under it.
        var inset: CGFloat
    }

    @State private var edge = FadeState(scrolled: 0, inset: 0)
    @State private var safeTop: CGFloat = 0
    private static let ramp: CGFloat = 40
    private static let tail: CGFloat = 28

    func body(content: Content) -> some View {
        content
            // Changes only over the first 40 pt of scrolling and when the toolbar comes or goes, not every frame.
            .onScrollGeometryChange(for: FadeState.self) { geo in
                FadeState(scrolled: min(Self.ramp, max(0, geo.contentOffset.y + geo.contentInsets.top)).rounded(),
                     inset: geo.contentInsets.top.rounded())
            } action: { _, value in
                edge = value
                if LayoutProbe.enabled {
                    let drawn = value.scrolled > 0 && max(value.inset, safeTop) > 0
                    DebugProbes.note("top-fade", "\(drawn ? "drawn" : "not drawn"): scrolled \(Int(value.scrolled)), inset \(Int(value.inset)), safe area \(Int(safeTop))")
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top.rounded() } action: { safeTop = $0 }
            .overlay(alignment: .top) {
                let inset = max(edge.inset, safeTop)
                if inset > 0, edge.scrolled > 0 {
                    let height = inset + Self.tail
                    ZStack {
                        Rectangle().fill(.bar)
                        // Over the material, so text passing under back/forward is gone, not a ghost.
                        Color.pageBackground.opacity(0.55)
                    }
                        .mask {
                            LinearGradient(stops: [.init(color: .black, location: 0),
                                                   .init(color: .black, location: max(0, inset - 8) / height),
                                                   .init(color: .black.opacity(0.5), location: (inset + 8) / height),
                                                   .init(color: .clear, location: 1)],
                                           startPoint: .top, endPoint: .bottom)
                        }
                        .frame(height: height)
                        .opacity(Double(edge.scrolled / Self.ramp))
                        .ignoresSafeArea(.container, edges: .top)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

extension EnvironmentValues {
    /// True when the window is shorter than `Metrics.compactHeight`. Set once per page by
    /// `compactHeightEnvironment()`, so views below only update when the window crosses the threshold.
    @Entry var isCompactHeight = false
    /// The font of `SectionHeader` titles (Home lowers it for shelves after the first).
    @Entry var sectionTitleFont: Font = .sectionTitle
}

/// Publishes `isCompactHeight` from the window height to the page below.
private struct CompactHeightEnvironment: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.environment(\.isCompactHeight, model.windowHeight < Metrics.compactHeight)
    }
}

extension View {
    func compactHeightEnvironment() -> some View { modifier(CompactHeightEnvironment()) }
}

extension EnvironmentValues {
    /// Whether items carry a small service mark. Off when only one service has content, since the
    /// mark then tells you nothing.
    @Entry var showsServiceMarks = true
}

// MARK: - Service marks

/// A tiny monochrome YouTube Music or Spotify mark in the surrounding foreground style, so an item's
/// source is clear without a colored dot. Hidden when only one service has content.
extension ProviderID {
    /// The one service every item came from, or nil when they mix (or there are none). Lists that are all one
    /// service drop the per-row service glyph.
    static func sole(_ providers: some Sequence<ProviderID>) -> ProviderID? {
        var iterator = providers.makeIterator()
        guard let first = iterator.next() else { return nil }
        while let next = iterator.next() { if next != first { return nil } }
        return first
    }
}

struct ServiceGlyph: View {
    let provider: ProviderID
    var size: CGFloat = 11
    /// Show even when only one service is active (headers that name the service).
    var always = false
    @Environment(\.showsServiceMarks) private var showsMarks

    var body: some View {
        if always || showsMarks {
            ServiceMark(provider: provider, size: size)
                .help(provider.displayName)
                .accessibilityElement()
                .accessibilityLabel(provider.displayName)
        }
    }
}

/// "◉ YouTube Music" after a section title, on a page that mixes both services, for a section whose items all come
/// from one: the 11 pt mark and the service's name in caption type. A bare gray mark beside a title read as a stray
/// icon. Hidden where only one service has content (`showsServiceMarks`), like every other mark.
struct ServiceTag: View {
    let provider: ProviderID
    /// `.caption` after a section title; `.inline` inside a header's meta line ("Olivia Rodrigo · ◉ YouTube Music ·
    /// 2026"), at that line's own size and ink with a 13 pt mark, so the headers and the shelves read alike.
    var style: Style = .caption
    @Environment(\.showsServiceMarks) private var showsMarks

    enum Style { case caption, inline }

    var body: some View {
        if showsMarks {
            Group {
                switch style {
                case .caption:
                    HStack(spacing: 4) {
                        ServiceMark(provider: provider, size: 11)
                        Text(provider.displayName).font(.caption).lineLimit(1)
                    }
                    .foregroundStyle(.readableSecondary)
                case .inline:
                    // The line's own font and ink (set outside), so "◉ YouTube Music" matches "2026" beside it.
                    HStack(spacing: 5) {
                        ServiceMark(provider: provider, size: 13)
                        Text(provider.displayName).lineLimit(1)
                    }
                }
            }
            .fixedSize()
            .help("From \(provider.displayName)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("From \(provider.displayName)")
        }
    }
}

/// "· ◉ YouTube Music" in a collection header's meta line, in the hero's secondary ink. Nothing where only one
/// service has content, like every other mark.
struct HeroServiceMeta: View {
    let provider: ProviderID
    @Environment(\.showsServiceMarks) private var showsMarks

    var body: some View {
        if showsMarks {
            Text("·").foregroundStyle(.heroSecondary)
            ServiceTag(provider: provider, style: .inline).foregroundStyle(.heroSecondary)
        }
    }
}

/// The brand-colored logo. Only Settings › Accounts uses it.
struct ServiceLogo: View {
    let provider: ProviderID
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle().fill(provider.brandColor)
            ServiceCutout(provider: provider, size: size)
                .foregroundStyle(provider == .youtubeMusic ? Color.white : Color(white: 0.07))
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(provider.displayName)
    }
}

/// A filled disc with the service's mark knocked out, in the current foreground style.
private struct ServiceMark: View {
    let provider: ProviderID
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
            ServiceCutout(provider: provider, size: size)
                .foregroundStyle(.black)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .frame(width: size, height: size)
    }
}

/// The inner part of each service mark: YouTube Music's ring and play triangle, Spotify's three arcs.
private struct ServiceCutout: View {
    let provider: ProviderID
    let size: CGFloat

    var body: some View {
        switch provider {
        case .youtubeMusic:
            ZStack {
                Circle()
                    .strokeBorder(lineWidth: max(0.9, size * 0.08))
                    .padding(size * 0.19)
                PlayTriangle()
                    .frame(width: size * 0.27, height: size * 0.31)
                    .offset(x: size * 0.03)
            }
            .frame(width: size, height: size)
        case .spotify:
            SpotifyArcs()
                .stroke(style: StrokeStyle(lineWidth: max(1, size * 0.1), lineCap: .round))
                .padding(size * 0.23)
                .frame(width: size, height: size)
        }
    }
}

nonisolated private struct PlayTriangle: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        }
    }
}

nonisolated private struct SpotifyArcs: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            let rows: [(y: CGFloat, w: CGFloat)] = [(0.24, 1.0), (0.54, 0.82), (0.82, 0.62)]
            for row in rows {
                let w = r.width * row.w
                let x0 = r.midX - w / 2
                let y = r.minY + r.height * row.y
                p.move(to: CGPoint(x: x0, y: y))
                p.addQuadCurve(to: CGPoint(x: x0 + w, y: y + r.height * 0.08), control: CGPoint(x: r.midX, y: y - r.height * 0.16))
            }
        }
    }
}

// MARK: - Small pieces

struct ExplicitBadge: View {
    /// Caption size next to rows and cards; headers pass a size that matches their title.
    var size: CGFloat? = nil

    var body: some View {
        Image(systemName: "e.square.fill")
            .font(size.map { .system(size: $0) } ?? .caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Explicit")
    }

    /// The badge's width at `size` points, for layouts that work out a title's room without measuring views.
    static func width(size: CGFloat) -> CGFloat {
        let image = NSImage(systemSymbolName: "e.square.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
        return ceil(image?.size.width ?? size)
    }

    /// The badge as text, to run inline after a title that may wrap. Caption-sized like the view.
    static var inline: Text {
        Text(Image(systemName: "e.square.fill")).font(.caption).foregroundStyle(.secondary)
    }
}

/// Play and Shuffle in album, playlist and library headers: neutral filled capsules.
/// The prominent one is ink on paper (dark in light mode, light in dark mode); the other is a quiet fill.
struct PillButtonStyle: ButtonStyle {
    var prominent = true
    var large = false
    /// The accent fill with white text, as `.borderedProminent` draws Settings › Accounts' and the welcome sheet's
    /// Sign In: an empty page's one account action. Wins over `prominent`.
    var accent = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, prominent: prominent, large: large, accent: accent)
    }

    private struct PillBody: View {
        /// The black laid over the accent fill at rest and under the pointer.
        static let accentShade = 0.08
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        let large: Bool
        let accent: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorScheme) private var scheme
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: large ? 14 : 13, weight: .semibold))
                .labelStyle(PillLabelStyle())
                .foregroundStyle(accent ? AnyShapeStyle(Color.white)
                                 : prominent ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.primary))
                .padding(.horizontal, large ? 22 : 18)
                .frame(minWidth: large ? 200 : 104, minHeight: large ? 36 : 30)
                .background { fill }
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.4)
                .motionScale(configuration.isPressed ? 0.96 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }

        @ViewBuilder private var fill: some View {
            if accent {
                // The system accent under 8% black, so its white label reads at 4.5:1 or more (the default blue,
                // rgb(0, 122, 255), gave 4.02:1; with the shade, 4.65:1), and no lighter under the pointer for the
                // same reason. Darker still when pressed, as the system's prominent buttons.
                Capsule().fill(Color.accentColor)
                    .overlay(Capsule().fill(Color.black.opacity(configuration.isPressed ? 0.24 : Self.accentShade)))
            } else if prominent {
                Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.72 : hovering && isEnabled ? 0.82 : 0.9))
            } else {
                Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hovering && isEnabled ? 0.12 : scheme == .dark ? 0.1 : 0.07))
            }
        }
    }
}

private struct PillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 11, weight: .bold))
            configuration.title
        }
    }
}

/// A borderless icon button that dims while pressed and when disabled (transport, panels).
struct IconButtonStyle: ButtonStyle {
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, tint: tint)
    }

    private struct IconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color?
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                .contentShape(Rectangle())
                .opacity(!isEnabled ? 0.3 : configuration.isPressed ? 0.55 : 1)
                .motionScale(configuration.isPressed ? 0.96 : 1)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

/// Text links in secondary color that brighten to primary on hover ("See All", "Clear", artist names).
struct SubtleLinkStyle: ButtonStyle {
    var base: HierarchicalShapeStyle = .secondary
    /// Rests in the opaque `readableSecondary` instead of `base` (the queue panel, where vibrancy dims `.secondary`).
    var readable = false

    func makeBody(configuration: Configuration) -> some View {
        SubtleLinkBody(configuration: configuration, base: base, readable: readable)
    }

    private struct SubtleLinkBody: View {
        let configuration: ButtonStyleConfiguration
        let base: HierarchicalShapeStyle
        let readable: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        /// A disabled link keeps the system's dimmed hierarchical gray; only an enabled one rests in the opaque gray.
        private var resting: AnyShapeStyle {
            readable && isEnabled ? AnyShapeStyle(.readableSecondary) : AnyShapeStyle(base)
        }

        var body: some View {
            configuration.label
                .foregroundStyle(hovering && isEnabled ? AnyShapeStyle(.primary) : resting)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// Section header with an optional "See All" link, like Apple Music's shelf titles. `provider` names the one service a
/// section's items come from, as a labelled tag (`ServiceTag`) that shows only on a page mixing both services.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var provider: ProviderID? = nil
    @ViewBuilder var trailing: Trailing
    @Environment(\.sectionTitleFont) private var titleFont

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(title).font(titleFont)
                    if let provider { ServiceTag(provider: provider) }
                }
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.readableSecondary)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, Metrics.pageInset)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, provider: ProviderID? = nil) {
        self.init(title: title, subtitle: subtitle, provider: provider) { EmptyView() }
    }
}

struct SeeAllButton: View {
    let action: () -> Void
    var body: some View {
        Button("Show All", action: action)
            // Rests in the opaque readable gray: the translucent `.secondary` read 3.9:1 on a scrolled light page.
            .buttonStyle(SubtleLinkStyle(readable: true))
            .font(.system(size: 13, weight: .semibold))
            // The council capture compares the card rows' trailing edge with it.
            .modifier(LayoutProbe(key: "see-all"))
    }
}

extension TimeInterval {
    /// 3:07, or 1:02:09 for long items.
    var clock: String {
        guard isFinite, self >= 0 else { return "--:--" }
        let total = Int(self.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

extension TimeInterval {
    /// "1 hr 1 min", "45 min", "3 min 20 sec" for collection totals in hero meta lines.
    var spokenLength: String {
        guard isFinite, self > 0 else { return "" }
        let total = Int(self.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return m > 0 ? "\(h) hr \(m) min" : "\(h) hr" }
        if m >= 10 || s == 0 { return "\(m) min" }
        return m > 0 ? "\(m) min \(s) sec" : "\(s) sec"
    }
}

/// A duration in tabular digits that never wraps: "3:07", "1:02:09", or a dash when unknown.
/// Reserves room for "0:00:00" by default so a column of hour-long tracks lines up.
struct DurationText: View {
    let duration: TimeInterval?
    var font: Font = .rowSecondary
    /// Minimum width; nil sizes to the text.
    var minWidth: CGFloat? = Metrics.durationWidth
    var alignment: Alignment = .trailing

    init(_ duration: TimeInterval?, font: Font = .rowSecondary, minWidth: CGFloat? = Metrics.durationWidth, alignment: Alignment = .trailing) {
        self.duration = duration
        self.font = font
        self.minWidth = minWidth
        self.alignment = alignment
    }

    var body: some View {
        Text(duration.map(\.clock) ?? "–")
            .font(font.monospacedDigit())
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: minWidth, alignment: alignment)
            .accessibilityLabel(duration.map { Duration.seconds($0).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide)) } ?? "Unknown length")
    }
}

extension AlbumKind {
    var label: String {
        switch self {
        case .album: "Album"
        case .single: "Single"
        case .ep: "EP"
        case .compilation: "Compilation"
        case .unknown: "Album"
        }
    }
}
