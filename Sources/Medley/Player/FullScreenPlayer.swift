import AppKit
import MedleyCore
import SwiftUI

/// Full-screen player: blurred artwork backdrop, big artwork and controls, and beside them large synced lyrics or
/// Playing Next, picked with the small control group in the bottom-right corner (like Music's full-screen player).
/// With neither panel open the artwork and controls sit centered.
struct FullScreenPlayer: View {
    @Environment(AppModel.self) private var model
    @State private var size: CGSize = .init(width: 1200, height: 800)
    @State private var tint: TintColor?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Narrower than this there's no room for a panel beside the artwork.
    static let panelMinWidth: CGFloat = 760

    var body: some View {
        let track = model.player.current
        let fits = size.width >= Self.panelMinWidth
        let panel = fits ? model.shownFullScreenPanel : nil
        let showPanel = panel != nil
        ZStack {
            ArtworkBackdrop(artwork: track?.artwork, blur: 90, sourcePixels: 64)
                .overlay(Color.black.opacity(Self.dim(for: tint)))
                .ignoresSafeArea()

            // With a panel open, one soft ramp across the whole screen deepens the side the lyrics or queue sit on.
            // No local shade with an edge: an earlier one starting at the artwork column left a bright band between
            // the two halves that read as a rendering bug.
            if let panel {
                (panel == .lyrics ? Self.lyricsRamp : Self.panelRamp)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }

            // Playing Next starts level with the artwork's top (`QueueBesideArtworkLayout`); lyrics run the full height.
            let spacing = showPanel ? max(40, size.width * 0.06) : 0
            let row = panel == .queue ? AnyLayout(QueueBesideArtworkLayout(spacing: spacing)) : AnyLayout(HStackLayout(spacing: spacing))
            row {
                NowPlayingColumn(track: track, artSize: artSize(showPanel: showPanel))
                    .frame(maxWidth: showPanel ? min(size.width * 0.42, 560) : 620)
                if let panel {
                    FullScreenPanelContent(panel: panel)
                        .frame(maxWidth: panel == .queue ? QueueBesideArtworkLayout.panelMaxWidth : 640, maxHeight: .infinity)
                        .transition(.asymmetric(insertion: Motion.Transition.fullScreenPanelIn.transition(reduce: reduceMotion),
                                                removal: Motion.Transition.fullScreenPanelOut.transition(reduce: reduceMotion)))
                }
            }
            .padding(.horizontal, max(40, size.width * 0.07))
            .padding(.vertical, 50)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .topLeading) {
            // The same glass capsule as the panel controls in the opposite corner, 20 pt in from the screen's edges.
            GlassControlGroup {
                Button { close() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(PanelControlStyle(isOn: false))
                .keyboardShortcut(.cancelAction)
                .help("Close Full Screen Player (Esc)")
                .accessibilityLabel("Close full screen player")
            }
            .modifier(LayoutProbe(key: "fullscreen-close"))
            .padding(.top, 20)
            .padding(.leading, 20)
            .ignoresSafeArea()
        }
        .overlay(alignment: .topTrailing) {
            // Where the sound goes, in the same glass capsule as the close button opposite, like Music's AirPlay
            // control: the output devices for YouTube Music, Spotify's device for a Spotify song.
            GlassControlGroup {
                OutputDeviceMenu(tint: .white.opacity(0.9), side: 30)
            }
            .modifier(LayoutProbe(key: "fullscreen-output"))
            .padding(.top, 20)
            .padding(.trailing, 20)
            .ignoresSafeArea()
        }
        .overlay(alignment: .bottomTrailing) {
            if fits {
                FullScreenPanelControls()
                    .padding(.trailing, 24)
                    .padding(.bottom, 24)
            }
        }
        .environment(\.colorScheme, .dark)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .onExitCommand { close() }
        .task(id: track?.artwork?.url(minPixels: 64)) {
            guard let url = track?.artwork?.url(minPixels: 64) else { tint = nil; return }
            let value = await ArtworkTintCache.shared.tint(for: url)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) { tint = value }
        }
    }

    /// How much the blurred backdrop is darkened: 50% for most covers, more for a pale one (up to 74%), so the whole
    /// backdrop lands at or below about 30% brightness. One even wash keeps a pale cover's own color; a darker local
    /// patch under the title (an earlier approach) turned cream into a muddy brown smudge, and a dark half behind
    /// the panel left a bright stripe between the halves.
    static func dim(for tint: TintColor?) -> Double {
        guard let brightness = tint?.brightness, brightness > 0 else { return 0.5 }
        return min(0.74, max(0.5, 1 - 0.36 / brightness + 0.12))
    }

    /// Lyrics: nothing over the artwork's side, then deepening under the lyrics column to 35% black at the trailing
    /// edge, so the dim lines (0.32–0.42 white, `LyricsStyle.opacity`) stay legible on a pale cover. Smooth all the
    /// way across, with no band where it starts.
    static let lyricsRamp = LinearGradient(
        stops: [.init(color: .black.opacity(0), location: 0), .init(color: .black.opacity(0.03), location: 0.35),
                .init(color: .black.opacity(0.2), location: 0.58), .init(color: .black.opacity(0.32), location: 0.8),
                .init(color: .black.opacity(0.35), location: 1)],
        startPoint: .leading, endPoint: .trailing)

    /// Black from 0 at the leading edge through 10% at the middle to 22% at the trailing edge.
    static let panelRamp = LinearGradient(
        stops: [.init(color: .black.opacity(0), location: 0), .init(color: .black.opacity(0.1), location: 0.5), .init(color: .black.opacity(0.22), location: 1)],
        startPoint: .leading, endPoint: .trailing)

    private func artSize(showPanel: Bool) -> CGFloat {
        let byHeight = size.height * 0.5
        let byWidth = showPanel ? size.width * 0.34 : size.width * 0.5
        return max(200, min(byHeight, byWidth, 520))
    }

    private func close() {
        model.setFullScreenPlayerPresented(false)
    }
}

/// The artwork column and Playing Next side by side: the column centered as an `HStack` centers it, and the queue
/// starting level with the artwork's top edge (the column's top) and running to the bottom. A layout, so the column's
/// height is read in the layout pass: nothing is written to state from geometry.
struct QueueBesideArtworkLayout: Layout {
    var spacing: CGFloat
    static let panelMaxWidth: CGFloat = 420

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else {
            for view in subviews { view.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(bounds.size)) }
            return
        }
        let column = subviews[0], panel = subviews[1]
        let available = max(0, bounds.width - spacing)
        // As an HStack offers two flexible views: half each, the capped one first, the rest to the other.
        let panelWidth = min(panel.sizeThatFits(ProposedViewSize(width: available / 2, height: bounds.height)).width, available / 2)
        let columnWidth = min(column.sizeThatFits(ProposedViewSize(width: available - panelWidth, height: bounds.height)).width, available - panelWidth)
        let columnHeight = min(column.sizeThatFits(ProposedViewSize(width: columnWidth, height: bounds.height)).height, bounds.height)
        let left = bounds.minX + (bounds.width - (columnWidth + spacing + panelWidth)) / 2
        let top = bounds.midY - columnHeight / 2
        column.place(at: CGPoint(x: left, y: top), anchor: .topLeading, proposal: ProposedViewSize(width: columnWidth, height: columnHeight))
        panel.place(at: CGPoint(x: left + columnWidth + spacing, y: top), anchor: .topLeading,
                    proposal: ProposedViewSize(width: panelWidth, height: bounds.maxY - top))
    }
}

/// Small white-on-glass controls on the full-screen player, grouped in one capsule.
private struct GlassControlGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 2) { content }
            .padding(3)
            .background(.white.opacity(0.14), in: Capsule())
    }
}

/// Lyrics or Playing Next beside the artwork. Switching between them cross-fades in place.
private struct FullScreenPanelContent: View {
    let panel: InspectorPanel
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch panel {
            case .lyrics:
                // Top to bottom of the screen, past the row's padding: the lines fade out at the screen's edges
                // (`SyncedLyricLines`) instead of being cut off mid-glyph at the padding.
                LyricsView(style: .fullScreen)
                    .padding(.vertical, -50)
                    .ignoresSafeArea(.container, edges: .vertical)
            case .queue:
                // Its own sizes here (`QueueMetrics.fullScreen`), in a column of at most 420 pt.
                QueuePanel { model.togglePanel(.queue) }
                    .environment(\.queueMetrics, .fullScreen)
                    .frame(maxWidth: QueueBesideArtworkLayout.panelMaxWidth)
            }
        }
        .id(panel)
        .transition(.opacity)
    }
}

/// Lyrics and Playing Next as a small two-button group, always on screen in the bottom-right corner. The panel
/// that's open is a white disc with a dark glyph; clicking it again closes it.
private struct FullScreenPanelControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let shown = model.shownFullScreenPanel
        GlassControlGroup {
            PanelControl(symbol: "quote.bubble", label: "Lyrics", isOn: shown == .lyrics, shortcut: "⌥⌘L",
                         disabledHelp: model.currentSongHasLyrics ? nil : "This song has no lyrics") {
                model.togglePanel(.lyrics)
            }
            .disabled(!model.currentSongHasLyrics)
            PanelControl(symbol: "list.bullet", label: "Playing Next", isOn: shown == .queue, shortcut: "⌥⌘U") {
                model.togglePanel(.queue)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Panels")
        .modifier(DebugFrame(key: "fullscreen-panels"))
    }
}

private struct PanelControl: View {
    let symbol: String
    let label: String
    let isOn: Bool
    let shortcut: String
    var disabledHelp: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(PanelControlStyle(isOn: isOn))
        .help(disabledHelp ?? "\(isOn ? "Hide" : "Show") \(label) (\(shortcut))")
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// White glyph on the glass at rest, a soft highlight on hover, and a white disc with a dark glyph when on.
private struct PanelControlStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        PanelControlBody(configuration: configuration, isOn: isOn)
    }

    private struct PanelControlBody: View {
        let configuration: Configuration
        let isOn: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(isOn ? Color.black.opacity(0.85) : Color.white.opacity(0.9))
                .background {
                    Circle().fill(.white.opacity(isOn ? 0.92 : hovering && isEnabled ? 0.14 : 0))
                }
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : 0.35)
                .motionScale(configuration.isPressed ? Motion.pressScale : 1)
                .animation(Motion.press, value: configuration.isPressed)
                .animation(Motion.hover, value: hovering)
                .animation(Motion.hover, value: isOn)
                .onHover { hovering = $0 }
        }
    }
}

private struct NowPlayingColumn: View {
    let track: Track?
    let artSize: CGFloat
    @Environment(AppModel.self) private var model

    /// The artist and album line: explicit white rather than `.secondary`, which is a translucent white that fell to
    /// about 2.6:1 over pale artwork. Over the local scrim this stays at or above 4.5:1 even on a near-white cover, and
    /// still reads one step below the title.
    static let secondaryText = Color.white.opacity(0.85)

    var body: some View {
        let player = model.player
        VStack(spacing: 22) {
            ArtworkView(artwork: track?.artwork, size: artSize, cornerRadius: 10)
                .frame(width: artSize, height: artSize)
                .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
                // Shrinks a little while paused; with Reduce Motion it keeps its size (the button shows the state).
                .motionScale(player.isPlaying || track == nil ? 1 : 0.94)
                .animation(.spring(duration: 0.5, bounce: 0.15), value: player.isPlaying)
                // The same menu as the More button beside the title.
                .contextMenu { if let track { TrackMenu(track: track) } }
                .zIndex(1)

            VStack(spacing: 22) {
                VStack(spacing: 4) {
                    // Like and More flank the title only, like Music's full-screen player; each keeps its slot when
                    // hidden, so the title stays centered under the artwork.
                    HStack(alignment: .center, spacing: 8) {
                        FullScreenLikeButton(track: track)
                            .frame(width: 32)
                        HStack(spacing: 6) {
                            Text(track?.title ?? "Not Playing")
                                .font(.system(size: 22, weight: .bold))
                                .lineLimit(1)
                                // The whole title when a long one is cut short.
                                .help(track?.title ?? "")
                            if track?.isExplicit == true { ExplicitBadge().font(.body) }
                        }
                        .frame(maxWidth: .infinity)
                        FullScreenMoreMenu(track: track)
                            .frame(width: 32)
                    }
                    // The glyphs line up with the artwork's edges (each 32 pt slot centers a ~17 pt glyph).
                    .frame(width: artSize + 16)
                    // The artist on its own line, then the album on up to two, both the artwork's full width. Both
                    // keep their height when empty or short (one artist line, two album lines), so the timeline and
                    // transport stay put from song to song.
                    HStack(spacing: 6) {
                        if let track { ServiceGlyph(provider: track.provider, size: 12) }
                        Text(track?.artistLine ?? " ")
                            .lineLimit(1)
                            .help(track?.artistLine ?? "")
                    }
                    .font(.title3.weight(.medium))
                    .foregroundStyle(Self.secondaryText)
                    .frame(maxWidth: artSize)
                    .modifier(LayoutProbe(key: "fullscreen-artist"))
                    Text(track?.album?.title ?? " ")
                        .font(.system(size: 14))
                        .foregroundStyle(Self.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineLimit(2, reservesSpace: true)
                        .truncationMode(.tail)
                        .help(track?.album?.title ?? "")
                        .frame(maxWidth: artSize)
                        .modifier(LayoutProbe(key: "fullscreen-album"))
                }
                .modifier(LayoutProbe(key: "fullscreen-metadata"))

                VStack(spacing: 6) {
                    FullScreenProgress()
                }
                .frame(width: artSize)

                VStack(spacing: 22) {
                    TransportControls(scale: 1.4, tint: .white, spacing: 20)
                    VolumeControl(width: min(artSize * 0.5, 220), tint: .white, activeTint: nil)
                }
                .modifier(LayoutProbe(key: "fullscreen-transport"))
            }
            // A light, wide shade under the title, times and controls for local bright patches in the backdrop.
            // Most of the contrast comes from the backdrop's own dimming (`FullScreenPlayer.dim`), so this stays
            // faint enough not to read as a dark patch on a pale cover.
            .background {
                Ellipse()
                    .fill(.black.opacity(0.22))
                    .padding(.horizontal, -90)
                    .padding(.vertical, -50)
                    .blur(radius: 50)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(.white)
    }
}

/// Add to or remove from Liked Songs, where the song's service supports likes and is signed in.
private struct FullScreenLikeButton: View {
    let track: Track?
    @Environment(AppModel.self) private var model

    var body: some View {
        if let track, model.can(.like, track.provider), model.provider(track.provider)?.isSignedIn == true {
            let liked = model.isLiked(track)
            Button { model.toggleLike(track) } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.system(size: 17, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(PanelControlStyle(isOn: false))
            .help(liked ? "Remove from Liked Songs" : "Add to Liked Songs")
            .accessibilityLabel(liked ? "Unlike" : "Like")
            .modifier(LayoutProbe(key: "fullscreen-like"))
        }
    }
}

/// The song's menu (`TrackMenu`, the same as right-clicking a song anywhere) from a visible "…" button. A
/// `KeyboardMoreButton`, so Tab reaches it, a click leaves no focus ring, and its menu draws dark: the player forces
/// the dark scheme, which a SwiftUI `Menu`'s `NSMenu` ignored, so in light mode a white menu opened over the dark
/// backdrop.
private struct FullScreenMoreMenu: View {
    let track: Track?
    @State private var hovering = false
    @State private var focused = false

    var body: some View {
        if let track {
            KeyboardMoreButton(size: 17, focused: $focused, label: "More actions for \(track.title)", side: 32, circular: true,
                               forceDark: true) {
                TrackMenu(track: track)
            }
            .foregroundStyle(Color.white.opacity(0.9))
            .background { Circle().fill(.white.opacity(hovering || focused ? 0.14 : 0)) }
            .animation(Motion.hover, value: hovering)
            .onHover { hovering = $0 }
            .modifier(LayoutProbe(key: "fullscreen-more"))
        }
    }
}

private struct FullScreenProgress: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        Scrubber(current: player.currentTime, duration: player.current == nil ? nil : player.displayDuration, isPlaying: player.state == .playing,
                 lineHeight: 6, tint: .white, trackOpacity: 0.28, activeTint: nil) {
            model.seek(to: $0)
        }
        TimeLabels(current: player.currentTime, duration: player.displayDuration, size: 14)
            .foregroundStyle(.white.opacity(0.9))
            .shadow(color: .black.opacity(0.35), radius: 3)
    }
}
