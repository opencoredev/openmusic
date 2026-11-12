import MedleyCore
import SwiftUI

nonisolated enum LyricsStyle: Equatable {
    case panel, fullScreen

    /// One weight for every line, like Apple Music: the active line stands out by brightness and scale.
    /// A weight change can't interpolate, so animating it cross-fades two text layouts of different widths
    /// and the line looks doubled for the length of the animation.
    func font(active: Bool, narrow: Bool = false) -> Font {
        // 19 in a panel at least `narrowPanel` wide (it opens at 420 in a wide window), so the panel reads as lyrics
        // first; 16 in a narrower one (280–340 pt, the width it gets beside a full page), so ordinary lines keep to
        // one or two lines instead of breaking after three or four words.
        let size: CGFloat = self == .panel ? (narrow ? 16 : 19) : 34
        return .system(size: size, weight: .bold)
    }

    /// The instrumental break's "…": 1.4 × the line's text size, the full-screen player's 48 pt dots beside its
    /// 34 pt lines.
    func breakDotSize(narrow: Bool = false) -> CGFloat {
        self == .panel ? ((narrow ? 16 : 19) * 1.4).rounded() : 48
    }

    /// Below this width the panel's lines use the smaller size.
    static let narrowPanel: CGFloat = 340
    /// The panel's leading inset for every line, the same as the "Lyrics" header's (`PanelHeader`), so the heading
    /// and the lines start on one edge.
    static let panelInset: CGFloat = PanelMetrics.leadingInset
    /// The panel's lines start this far under the "Lyrics" heading, where the top fade begins.
    static let panelHeadingGap: CGFloat = 12
    /// The panel's top fade once the list has scrolled: a whole line and its spacing (19 pt lines are about 24 pt tall,
    /// 12 pt apart), so a line passing under the "Lyrics" heading dissolves instead of showing sliced in half at the
    /// edge (round 31's 20 pt fade cut through a line).
    static let panelTopFade: CGFloat = 46
    /// The fade at rest, with the list at its top: over before the first line (24 pt into the list), so the first line
    /// isn't dimmed. The fade switches between the two as the list leaves or reaches its top.
    static let panelRestingTopFade: CGFloat = 20
    var spacing: CGFloat { self == .panel ? 12 : 20 }

    /// Opacity for each line state: of `.primary` (already 85% label alpha) in the panel, of pure white in
    /// the full-screen player, which is always dark. The panel, like full screen, keeps the eye on the line being
    /// sung: the lines are 16–19 pt bold, large text, so upcoming ones need 3:1, not 4.5:1. Measured on the rendered
    /// panel backgrounds (council `lyrics` shots, glyph cores against the panel): upcoming lines 0.45 in light (0.42
    /// read 2.98–3.00:1 on its 237 gray, so a step more) and 0.40 in dark (3.7–3.85:1), sung lines a step dimmer, the
    /// active line at full label color.
    /// Full screen, like Music's, keeps the eye on the line being sung: the others drop well back (upcoming 0.42,
    /// sung 0.32) and blur with distance (`blur(distance:)`); a darker ramp behind the lyrics column
    /// (`FullScreenPlayer.lyricsRamp`) keeps them legible. With Reduce Transparency or Increase Contrast
    /// (`plain`) there's no blur and every dim line, panel or full screen, stays at 0.6.
    func opacity(_ state: LyricLineState, scheme: ColorScheme, hovering: Bool, plain: Bool = false) -> Double {
        if state == .active { return 1 }
        let base: Double = switch (self, scheme, state) {
        case (_, _, _) where plain: 0.6
        case (.fullScreen, _, .upcoming): 0.42
        case (.fullScreen, _, _): 0.32
        case (.panel, .dark, .upcoming): 0.40
        case (.panel, .dark, _): 0.28
        case (.panel, _, .upcoming): 0.45
        case (.panel, _, _): 0.30
        }
        return hovering ? min(1, base + 0.18) : base
    }

    /// Full screen only: a line two away from the one being sung is softly out of focus (1.5 pt), further ones more
    /// (3 pt); the lines next to it stay sharp. Past `blurReach` lines (off screen, or a part the listener scrolled
    /// to) nothing is blurred, so a long song doesn't keep dozens of blurred layers alive.
    func blur(distance: Int?, plain: Bool) -> CGFloat {
        guard self == .fullScreen, !plain, let distance else { return 0 }
        switch distance {
        case ...1: return 0
        case 2: return 1.5
        case ...Self.blurReach: return 3
        default: return 0
        }
    }

    static let blurReach = 10
}

nonisolated enum LyricLineState: Equatable { case active, past, upcoming }

/// Lyrics for the current song: synced lyrics follow playback, unsynced lyrics are shown plainly.
struct LyricsView: View {
    var style: LyricsStyle = .panel
    @Environment(AppModel.self) private var model

    var body: some View {
        if let track = model.player.current {
            if model.can(.lyrics, track.provider) {
                LyricsLoader(track: track, style: style).id(track.id)
            } else {
                LyricsMessage(style: style, symbol: "quote.bubble", title: "No lyrics", message: "\(track.provider.displayName) doesn't provide lyrics in \(ProductInfo.name).")
            }
        } else {
            // Not "Lyrics": the panel's header already says that.
            LyricsMessage(style: style, symbol: "quote.bubble", title: "Nothing Playing", message: "Play a song to see its lyrics here.")
        }
    }
}

private struct LyricsLoader: View {
    let track: Track
    let style: LyricsStyle
    @Environment(AppModel.self) private var model
    @State private var phase: Phase = .loading

    enum Phase {
        case loading
        case loaded(Lyrics?)
        case failed(String)
    }

    var body: some View {
        Group {
            switch currentPhase {
            case .loading:
                VStack(alignment: .leading, spacing: style.spacing + 6) {
                    ForEach(0..<7, id: \.self) { i in
                        SkeletonBlock(width: CGFloat(150 + (i * 53) % 110), height: style == .panel ? 16 : 26)
                    }
                }
                .padding(.horizontal, style == .panel ? LyricsStyle.panelInset : 0)
                .padding(.vertical, style == .panel ? 20 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .loaded(let lyrics?) where !lyrics.lines.isEmpty:
                if lyrics.isSynced {
                    SyncedLyrics(lyrics: lyrics, style: style)
                } else {
                    PlainLyrics(lyrics: lyrics, style: style)
                }
            case .loaded:
                LyricsMessage(style: style, symbol: "music.quarternote.3", title: "No lyrics for this song", message: "It may be instrumental, or lyrics aren't available yet.")
            case .failed(let message):
                LyricsMessage(style: style, symbol: "exclamationmark.bubble", title: "Couldn't load lyrics", message: message) {
                    Button("Try Again") { phase = .loading; Task { await load() } }
                }
            }
        }
        .task { await load() }
    }

    private var currentPhase: Phase {
        if case .loading = phase, let cached = model.cachedLyrics(track) { return .loaded(cached) }
        return phase
    }

    private func load() async {
        if let cached = model.cachedLyrics(track) { phase = .loaded(cached); return }
        do {
            phase = .loaded(try await model.lyrics(for: track))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// Reads the playback time and passes only the active line index down,
/// so the line list re-renders when the line changes, not on every tick.
private struct SyncedLyrics: View {
    let lyrics: Lyrics
    let style: LyricsStyle
    @Environment(AppModel.self) private var model

    var body: some View {
        let t = model.player.currentTime + 0.2
        let active = lyrics.lines.lastIndex { ($0.time ?? .infinity) <= t }
        SyncedLyricLines(lines: lyrics.lines, active: active, style: style, source: lyrics.source) { time in
            model.seek(to: time)
            if !model.player.isPlaying { model.resume() }
        }
        .equatable()
    }
}

private struct SyncedLyricLines: View, Equatable {
    let lines: [LyricLine]
    let active: Int?
    let style: LyricsStyle
    let source: String?
    let seek: (TimeInterval) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var userScrolledAt: Date = .distantPast
    @State private var narrow = false
    /// The list is off its top (the panel's taller top fade, `PanelTopFadeMask`). Written when it flips, not per frame.
    @State private var scrolledDown = false

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.lines == b.lines && a.active == b.active && a.style == b.style && a.source == b.source
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: style.spacing) {
                    // Full screen runs from the top of the screen, so the first line starts below the top fade.
                    Color.clear.frame(height: style == .panel ? 24 : 170)
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        LyricLineRow(line: line, state: state(index), distance: active.map { abs(index - $0) }, style: style, narrow: narrow) {
                            if let time = line.time { seek(time) }
                        }
                        .modifier(LayoutProbe(key: style == .panel ? "lyrics-line-\(index)" : ""))
                        .id(index)
                    }
                    if let source { LyricsSourceFooter(source: source) }
                    Color.clear.frame(height: style == .panel ? 200 : 320)
                }
                .padding(.horizontal, style == .panel ? LyricsStyle.panelInset : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .onScrollGeometryChange(for: TopFadeBand.self) { TopFadeBand($0.contentOffset.y + $0.contentInsets.top) } action: { _, band in
                if style == .panel { let off = band.scrolled(was: scrolledDown); if off != scrolledDown { scrolledDown = off } }
            }
            .modifier(LayoutProbe(key: style == .panel ? "lyrics-list" : ""))
            // The panel's width is fixed by the split view, so the font change never feeds back into it.
            .onGeometryChange(for: Bool.self) { style == .panel && $0.size.width < LyricsStyle.narrowPanel } action: {
                narrow = $0
                if LayoutProbe.enabled, style == .panel { DebugProbes.note("lyrics-font", $0 ? "16" : "19") }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .decelerating { userScrolledAt = Date() }
            }
            .task {
                // Wait one layout pass so the scroll view knows its size, then jump without animating.
                try? await Task.sleep(for: .milliseconds(30))
                proxy.scrollTo(active ?? 0, anchor: anchor)
            }
            .onChange(of: active) { _, new in
                // Don't fight the user: pause auto-scroll for a few seconds after they scroll.
                guard Date().timeIntervalSince(userScrolledAt) > 3 else { return }
                if reduceMotion {
                    proxy.scrollTo(new ?? 0, anchor: anchor)
                } else {
                    withAnimation(.smooth(duration: 0.6)) { proxy.scrollTo(new ?? 0, anchor: anchor) }
                }
            }
        }
        .mask {
            if style == .panel {
                // In points at the top: the fade starts 12 pt under the "Lyrics" heading (the padding below). At rest it
                // is over 20 pt later, above the first line (24 pt down); scrolled, it takes a whole line (46 pt). A
                // fade over the top 6% of the panel reached past the first line in a tall window (round 25).
                PanelTopFadeMask(scrolled: scrolledDown, bottom: fadeStops)
            } else {
                LinearGradient(stops: fadeStops, startPoint: .top, endPoint: .bottom)
            }
        }
        .padding(.top, style == .panel ? LyricsStyle.panelHeadingGap : 0)
    }

    /// Lines fade in and out at the edges. Full screen fades over the outer 15% at each end of the screen, so a line
    /// scrolling past the top dissolves instead of being clipped mid-glyph.
    private var fadeStops: [Gradient.Stop] {
        switch style {
        case .panel:
            // The top's fade is the fixed one above; this is the bottom's.
            [.init(color: .black, location: 0), .init(color: .black, location: 0.87), .init(color: .clear, location: 1)]
        case .fullScreen:
            // Eased: a line in the outer 5% is all but gone, so nothing reads as cut at the screen's edge.
            [.init(color: .clear, location: 0), .init(color: .black.opacity(0.08), location: 0.05), .init(color: .black.opacity(0.45), location: 0.1),
             .init(color: .black, location: 0.15), .init(color: .black, location: 0.85), .init(color: .black.opacity(0.45), location: 0.9),
             .init(color: .black.opacity(0.08), location: 0.95), .init(color: .clear, location: 1)]
        }
    }

    private var anchor: UnitPoint { UnitPoint(x: 0, y: style == .panel ? 0.3 : 0.35) }

    private func state(_ index: Int) -> LyricLineState {
        guard let active else { return .upcoming }
        if index == active { return .active }
        return index < active ? .past : .upcoming
    }
}

private struct LyricLineRow: View {
    let line: LyricLine
    let state: LyricLineState
    /// Lines from the one being sung; nil before the first line starts.
    let distance: Int?
    let style: LyricsStyle
    var narrow = false
    let tap: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    /// No blur and steadier dim lines for Reduce Transparency and Increase Contrast.
    private var plain: Bool { reduceTransparency || contrast == .increased }

    private var lineColor: AnyShapeStyle {
        let alpha = style.opacity(state, scheme: colorScheme, hovering: hovering, plain: plain)
        return style == .fullScreen ? AnyShapeStyle(Color.white.opacity(alpha)) : AnyShapeStyle(.primary.opacity(alpha))
    }

    var body: some View {
        let isBreak = line.text.trimmingCharacters(in: .whitespaces).isEmpty
        Button(action: tap) {
            Group {
                if isBreak {
                    // The instrumental gap: the full-screen player's "…" scaled to the line size (1.4 × the text, as
                    // 48 pt dots to 34 pt lines there), in a slot one lyric line tall, so it sits on the list's
                    // rhythm instead of hugging the line above as a stray "…" (round 28). It breathes while the gap
                    // plays (a symbol effect, run by Core Animation, and only then; never with Reduce Motion).
                    Text(verbatim: "A")
                        .font(style.font(active: false, narrow: narrow))
                        .hidden()
                        .accessibilityHidden(true)
                        .overlay(alignment: .leading) {
                            Image(systemName: "ellipsis")
                                .font(.system(size: style.breakDotSize(narrow: narrow), weight: .bold))
                                .symbolEffect(.breathe, options: .repeating, isActive: state == .active && !reduceMotion)
                        }
                } else {
                    Text(line.text)
                        .font(style.font(active: state == .active, narrow: narrow))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Alpha goes into the color rather than `.opacity`, so the "…" symbol dims exactly like the text.
            .foregroundStyle(lineColor)
            .motionScale(state == .active ? 1 : 0.97, anchor: .leading)
            .animation(.easeOut(duration: 0.3), value: state)
            // Outside the animation: the radius steps once per line change instead of re-rendering a blur on every
            // frame of a transition, and hovering a line brings it into focus.
            .blur(radius: hovering ? 0 : style.blur(distance: distance, plain: plain))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(hovering ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, -8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(isBreak ? "Instrumental break" : line.text)
        .accessibilityHint("Plays from this line")
    }
}

/// The lyrics panel's mask: the top fade under the "Lyrics" heading (`LyricsStyle.panelRestingTopFade` at rest,
/// `panelTopFade` once the list has scrolled, switching in 0.2 s, at once with Reduce Motion), then `bottom`'s stops.
private struct PanelTopFadeMask: View {
    let scrolled: Bool
    let bottom: [Gradient.Stop]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let height = scrolled ? LyricsStyle.panelTopFade : LyricsStyle.panelRestingTopFade
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: height)
            LinearGradient(stops: bottom, startPoint: .top, endPoint: .bottom)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: scrolled)
        .onChange(of: height, initial: true) {
            if LayoutProbe.enabled { DebugProbes.note("lyrics-top-fade", "\(Int(height))") }
        }
    }
}

private struct PlainLyrics: View {
    let lyrics: Lyrics
    let style: LyricsStyle
    @State private var scrolledDown = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                // A status the listener needs to read, not a footnote: 13 pt (15 full screen), at 72% of the
                // label color, about 6:1 on the panel in light and 7:1 in dark (the 4.5:1 floor for small text).
                Label("Not synced to the music", systemImage: "text.alignleft")
                    .font(.system(size: style == .panel ? 13 : 15, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .padding(.bottom, style == .panel ? 12 : 18)
                Text(lyrics.lines.map(\.text).joined(separator: "\n"))
                    .font(style == .panel ? .system(size: 15, weight: .semibold) : .system(size: 26, weight: .bold))
                    .lineSpacing(style == .panel ? 6 : 10)
                    .textSelection(.enabled)
                if let source = lyrics.source { LyricsSourceFooter(source: source) }
            }
            .padding(.horizontal, style == .panel ? LyricsStyle.panelInset : 0)
            .padding(.vertical, style == .panel ? 20 : 0)
            .padding(.vertical, style == .panel ? 0 : 80)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onScrollGeometryChange(for: TopFadeBand.self) { TopFadeBand($0.contentOffset.y + $0.contentInsets.top) } action: { _, band in
            if style == .panel { let off = band.scrolled(was: scrolledDown); if off != scrolledDown { scrolledDown = off } }
        }
        // The panel's text passes under the heading through the same fade as synced lines.
        .mask {
            if style == .panel {
                PanelTopFadeMask(scrolled: scrolledDown, bottom: [.init(color: .black, location: 0), .init(color: .black, location: 1)])
            } else {
                Color.black
            }
        }
    }
}

/// Where the lyrics come from ("Synced lyrics", a provider's credit): 11 pt in the opaque `readableSecondary` gray,
/// at least 4.5:1 on the panel and full screen (the translucent tertiary label it used read about 1.9:1).
private struct LyricsSourceFooter: View {
    let source: String

    var body: some View {
        Text(source)
            .font(.system(size: 11))
            .foregroundStyle(.readableSecondary)
            .padding(.top, 20)
    }
}

private struct LyricsMessage<Actions: View>: View {
    let style: LyricsStyle
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: style == .panel ? 30 : 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(style == .panel ? .headline : .title.bold())
            Text(message)
                .font(style == .panel ? .callout : .title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            actions.padding(.top, 6)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension LyricsMessage where Actions == EmptyView {
    init(style: LyricsStyle, symbol: String, title: String, message: String) {
        self.init(style: style, symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

/// Where the lyrics list sits against the panel's top fade switch, with hysteresis: the long fade comes on past 4 pt
/// of scrolling and goes only under 1 pt, so an offset wobbling around one threshold (an elastic bounce, a line
/// scrolled to 2 pt) can't flip the mask back and forth. Only a band change reaches the view.
nonisolated enum TopFadeBand: Equatable {
    case rest, between, scrolled

    static let on: CGFloat = 4
    static let off: CGFloat = 1

    init(_ offset: CGFloat) {
        self = offset > Self.on ? .scrolled : offset < Self.off ? .rest : .between
    }

    /// The fade's state in this band: between the thresholds it keeps what it was.
    func scrolled(was: Bool) -> Bool {
        switch self {
        case .rest: false
        case .between: was
        case .scrolled: true
        }
    }
}
