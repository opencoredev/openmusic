import AppKit
import MedleyCore
import SpotifyKit
import SwiftUI

// The player: a floating Liquid Glass capsule over the page, like Music's on macOS 27.
//
// Direction
// - Reference: Music on macOS 27 (a capsule inset from the detail pane's edges, page artwork showing through)
//   and Medley's own earlier toolbar capsules, which the owner liked.
// - Palette: the system's regular glass with a faint base tint in the window's tone, the label color and an
//   opaque secondary ink (`glassSecondary`, 4.5:1 over the glass); the accent color marks on states (shuffle,
//   repeat, open panels). No opaque fill, no artwork-colored glow.
// - Type: SF Pro. Title 13 semibold, artist 12 secondary, times 11 medium with tabular digits. The heart follows
//   the title and artist.
// - Layout: one 62 pt capsule over the detail column only (sidebar and inspector run full height). Left the
//   song, center the transport over a slim timeline, right panels, output, volume and windows.
// - Signature: covers scroll beneath the glass.
// - Avoiding: the full-width opaque bar, heavy drop shadows (light mode has a hairline and a soft 10% one, so the
//   capsule holds together over white) and tinted backgrounds.
//
// It adapts to the width it's offered, never to a width stored in state: secondary controls fold into "…",
// then the times go, then shuffle and repeat move into "…". The title keeps at least 90 pt.

struct FloatingPlayer: View {
    static let height: CGFloat = 62
    /// Space between the capsule and the pane's left, right and bottom edges.
    static let inset: CGFloat = 12
    /// Space between the end of a page's content and the capsule's top.
    static let gap: CGFloat = 8
    /// What page content must clear at the bottom of the detail pane.
    static var reservedHeight: CGFloat { height + inset + gap }

    @Environment(AppModel.self) private var model
    /// The narrowest row each tier fits in, measured by hidden copies at their ideal size (`TierMinimums`).
    @State private var minimums: [CapsuleTier: CGFloat] = [:]
    @State private var tier: CapsuleTier = .full

    var body: some View {
        // The tier comes from the width through cut-offs measured once, not from `ViewThatFits`: that sized all
        // four rows on every frame while the pane's width changed (the sidebar sliding), the largest single cost
        // of each frame of the move.
        let minimums = minimums
        CapsuleRow(tier: tier)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CapsuleTier.self) { proxy in
                CapsuleTier.widest(fitting: proxy.size.width, minimums: minimums)
            } action: { tier = $0 }
            .background { TierMinimums(minimums: $minimums) }
        .padding(.leading, 11)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .modifier(PlayerGlass())
        .modifier(LayoutProbe(key: "player-capsule"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Player")
    }
}

/// Liquid Glass in a capsule on macOS 26 and later; a material capsule with a hairline rim before that.
private struct PlayerGlass: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(AppModel.self) private var model

    /// A faint base tint in the window's own tone. Plain regular glass took up saturated art scrolling beneath it
    /// as strong colour blotches in light mode, and let the page's brightness swing the glass far enough that
    /// secondary text over it fell under 4.5:1; this keeps the glass nearer the window's tone and still clear.
    /// With nothing queued the bar is mostly dimmed controls, and Home's coloured mood tiles behind it read as a
    /// muddy band through the faint tint: a much stronger one then, nearly the window's own colour.
    private var baseTint: Color {
        let idle = model.player.current == nil
        return scheme == .dark ? Color.black.opacity(idle ? 0.55 : 0.22) : Color.white.opacity(idle ? 0.8 : 0.42)
    }

    func body(content: Content) -> some View {
        // A nearly clear fill so clicks between the controls land on the player, not the page beneath it.
        let hitArea = content.background(Capsule().fill(Color.primary.opacity(0.001)))
        if #available(macOS 26.0, *) {
            hitArea.glassEffect(.regular.tint(baseTint), in: .capsule)
                // Light mode: over a white page the glass's own rim all but vanished and the capsule read as loose
                // controls. A hairline and a soft shadow make it one object; dark mode's page already sets it off.
                // Both are static (drawn again only when the capsule's size changes, as the glass is).
                .overlay {
                    if scheme == .light {
                        Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5).allowsHitTesting(false)
                    }
                }
                .background {
                    if scheme == .light { PlayerShadow() }
                }
        } else {
            hitArea
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        }
    }
}

/// The capsule's soft shadow (16 pt blur, 4 pt down, black at 10%), drawn only outside the capsule so nothing dark
/// sits behind the glass for it to pick up. One small bitmap drawn once and stretched along the capsule's straight
/// middle (`capInsets`): no blur or mask is worked out again while the page scrolls under the glass or the sidebar
/// resizes the capsule.
private struct PlayerShadow: View {
    private static let pad: CGFloat = 24
    private static let radius = FloatingPlayer.height / 2

    private static let image: NSImage = {
        let height = FloatingPlayer.height
        let size = NSSize(width: 2 * (radius + pad) + 4, height: height + 2 * pad)
        return NSImage(size: size, flipped: false) { _ in
            let capsule = NSRect(x: pad, y: pad, width: size.width - 2 * pad, height: height)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.1)
            shadow.shadowBlurRadius = 16
            shadow.shadowOffset = NSSize(width: 0, height: -4)
            shadow.set()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: capsule, xRadius: radius, yRadius: radius).fill()
            NSGraphicsContext.restoreGraphicsState()
            // The shape that cast it goes, with 1 pt to spare for its antialiased edge.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: capsule.insetBy(dx: -1, dy: -1), xRadius: radius + 1, yRadius: radius + 1).fill()
            return true
        }
    }()

    var body: some View {
        let inset = Self.pad + Self.radius + 1
        Image(nsImage: Self.image)
            .resizable(capInsets: EdgeInsets(top: 0, leading: inset, bottom: 0, trailing: inset), resizingMode: .stretch)
            .padding(-Self.pad)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Hidden copies of every tier's row at their ideal (minimum) width. They are measured when their content
/// changes (a button appears, the title changes), not while the pane's width changes: their proposal never does.
private struct TierMinimums: View {
    @Binding var minimums: [CapsuleTier: CGFloat]

    var body: some View {
        ZStack {
            ForEach(CapsuleTier.allCases, id: \.self) { tier in
                CapsuleRow(tier: tier)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                        if minimums[tier] != width { minimums[tier] = width }
                    }
            }
        }
        .frame(width: 0, height: 0, alignment: .leading)
        // Copies for measuring only: their buttons' popovers (Devices, Volume) must never present, or a click on the
        // visible button would open a second presenter bound to the same state inside this zero-size box.
        .environment(\.isPlayerMeasurement, true)
        .environment(\.isLayoutMeasurement, true)
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// How much the capsule shows, widest first. The capsule shows the first whose minimum fits.
private nonisolated enum CapsuleTier: CaseIterable, Hashable, Sendable {
    /// Everything inline, with a volume slider.
    case full
    /// Volume becomes a popover button; output device, mini player and full screen fold into "…".
    case regular
    /// The center narrows, so the timeline drops its times.
    case compact
    /// Previous, play and next only; lyrics, shuffle and repeat join the "…" menu.
    case minimal

    /// The song side's floor: artwork, at least some title, the heart and, where it shows, the song's More.
    var identityMin: CGFloat { self == .minimal ? 130 : showsSongMore ? 172 : 150 }
    /// The song's own "…" beside the heart, in the full tier. The others already have a "…" at the trailing end
    /// for what they fold away; that one becomes the song's (its actions first), so there are never two "…".
    var showsSongMore: Bool { self == .full }
    var centerMin: CGFloat {
        switch self {
        case .full, .regular: 300
        case .compact: 196
        case .minimal: 112
        }
    }
    /// How far the center may narrow so a long title or artist line shows in full (`CapsuleRowLayout`): the
    /// transport and a timeline that still has its times.
    var centerFloor: CGFloat {
        switch self {
        case .full, .regular: 256
        case .compact: 196
        case .minimal: 112
        }
    }
    var showsModes: Bool { self != .minimal }

    /// The widest tier whose measured minimum fits `width`; before anything is measured, `.full`.
    static func widest(fitting width: CGFloat, minimums: [CapsuleTier: CGFloat]) -> CapsuleTier {
        guard !minimums.isEmpty else { return .full }
        return allCases.first { (minimums[$0] ?? .infinity) <= width + 0.5 } ?? .minimal
    }
}

private struct CapsuleRow: View {
    let tier: CapsuleTier

    var body: some View {
        CapsuleRowLayout(identityMin: tier.identityMin, centerMin: tier.centerMin, centerFloor: tier.centerFloor) {
            PlayerIdentity(showsMore: tier.showsSongMore)
            PlayerCenter(showsModes: tier.showsModes)
            PlayerTrailing(tier: tier)
        }
    }
}

/// The song on the left, the transport centered in the capsule when the sides leave room for it (else as close
/// to the middle as fits), and the trailing buttons at their natural width on the right.
///
/// When the song's line is cut short and there's room between the center and the trailing buttons (a narrow
/// capsule, Playing Next open at 960 pt), the center moves right, then narrows down to `centerFloor`, just enough
/// to show it: "Olivia Ro…" had about 40 pt free on the other side of the transport. The song side's natural width
/// is read while placing, from the layout's own subviews, so nothing is stored per frame.
///
/// Its ideal width is the minimum the tier needs, so `ViewThatFits` can choose a tier; every placement comes
/// from the width offered.
///
/// The trailing buttons' natural width is measured once per change of the subviews and kept in the layout cache.
/// Measuring it on every pass made `ViewThatFits` size all four rows' buttons each time the pane's width changed,
/// about a tenth of every frame while the sidebar slides.
private struct CapsuleRowLayout: Layout {
    let identityMin: CGFloat
    let centerMin: CGFloat
    var centerFloor: CGFloat
    var centerMax: CGFloat = 520
    var spacing: CGFloat = 14

    struct Cache {
        var trailing: CGFloat
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(trailing: subviews.count == 3 ? subviews[2].sizeThatFits(.unspecified).width : 0)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let height = proposal.height ?? FloatingPlayer.height
        guard subviews.count == 3 else { return CGSize(width: proposal.width ?? 0, height: height) }
        let needed = identityMin + centerMin + cache.trailing + 2 * spacing
        guard let width = proposal.width, width.isFinite else { return CGSize(width: needed, height: height) }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard subviews.count == 3 else { return }
        let width = bounds.width
        let height = bounds.height
        let trailing = cache.trailing
        let room = max(width - trailing - 2 * spacing, 0)
        var center = max(min(max(width * 0.42, centerMin), centerMax, room - identityMin), min(centerMin, room))
        // What the song side would take uncut: artwork, the longer of its two lines, the heart (and More).
        let wanted = max(identityMin, subviews[0].sizeThatFits(.unspecified).width)
        // Narrower, down to its floor, only when the song still wouldn't fit beside a center pushed fully right.
        let short = wanted - (room - center)
        if short > 0 { center = max(min(centerFloor, center), center - short) }
        // Centered in the capsule if both sides fit; else pushed off center just enough: past the song's own width
        // when there's room on the other side, but never past the trailing buttons.
        let lowest = bounds.minX + wanted + spacing
        let highest = bounds.maxX - trailing - spacing - center
        let centerX = max(min(bounds.midX - center / 2, highest), min(lowest, highest))
        let identity = max(centerX - spacing - bounds.minX, 0)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: identity, height: height))
        subviews[1].place(at: CGPoint(x: centerX, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: center, height: height))
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                          proposal: ProposedViewSize(width: trailing, height: height))
    }
}

// MARK: - Left: the song

private struct PlayerIdentity: View {
    /// The song's "…" after the heart (the wider tiers).
    let showsMore: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        if let track = model.player.current {
            HStack(spacing: 10) {
                BarArtwork(track: track)
                // The text and the heart hug their content: the heart sits 8 pt after the longer line (its 28 pt
                // target is wider than the glyph), centred on the two lines, in every tier and layout.
                HStack(spacing: 8 - LikeButton.glyphInset) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            // Always a link: to the album, looked up first when the listing didn't name it (with a
                            // spinner meanwhile), or to the artist with a notice for a song on no album.
                            Button(track.title) { model.goToAlbumResolving(track) }
                                .buttonStyle(BarLinkStyle(base: AnyShapeStyle(.primary)))
                                .help(track.album.map { "\(track.title) · Go to \($0.title)" } ?? "\(track.title) · Go to Album")
                                .accessibilityHint("Go to Album")
                            if track.isExplicit { ExplicitBadge() }
                            if model.resolvingAlbumTrackID == track.id {
                                ProgressView()
                                    .controlSize(.mini)
                                    .accessibilityLabel("Finding the album")
                            }
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                        HStack(spacing: 5) {
                            ServiceGlyph(provider: track.provider, size: 10)
                                .foregroundStyle(.glassSecondary)
                            if let artist = track.artists.first(where: { $0.id != nil }) {
                                Button(track.artistLine) { model.goToArtist(artist, provider: track.provider) }
                                    .buttonStyle(BarLinkStyle(base: AnyShapeStyle(.glassSecondary)))
                                    .help(track.artistLine)
                            } else {
                                Text(track.artistLine).foregroundStyle(.glassSecondary)
                            }
                        }
                        .font(.system(size: 12))
                        .lineLimit(1)
                    }
                    // When room runs out the text truncates and the heart stays. The capsule's tiers measure only fixed
                    // widths (`CapsuleRowLayout`), so a long title never asks for more room.
                    LikeButton(track: track)
                        .fixedSize()
                    if showsMore {
                        SongMoreButton(track: track)
                            .padding(.leading, -(8 - LikeButton.glyphInset))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu { TrackMenu(track: track) }
        } else {
            // Nothing playing yet: a quiet empty tile, not a fake song.
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 15))
                            .foregroundStyle(.tertiary)
                    }
                Text("Not Playing")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}

/// The artwork opens the full-screen player. On hover (or keyboard focus) it darkens and shows the
/// expand symbol, so the click target is discoverable.
private struct BarArtwork: View {
    let track: Track
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        let reveal = hovering || focused
        Button {
            model.setFullScreenPlayerPresented(true)
        } label: {
            ArtworkView(artwork: track.artwork, size: 40, cornerRadius: 8)
                .frame(width: 40, height: 40)
                .overlay {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.4))
                        Image(systemName: "chevron.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .opacity(reveal ? 1 : 0)
                }
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: reveal)
        .help("Open Full Screen Player")
        .accessibilityLabel("Open full screen player")
    }
}

/// A text link: its base color at rest, underlined on hover, like Spotify's song and artist links. The base is
/// any style, so the artist line can use the opaque `glassSecondary` ink.
private struct BarLinkStyle: ButtonStyle {
    var base: AnyShapeStyle

    func makeBody(configuration: Configuration) -> some View {
        LinkBody(configuration: configuration, base: base)
    }

    private struct LinkBody: View {
        let configuration: Configuration
        let base: AnyShapeStyle
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : base)
                .underline(hovering)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// The song's actions (`TrackMenu`, as when right-clicking it) from a "…" the keyboard reaches with Tab, like a
/// row's More. The measuring copies (`TierMinimums`) get a same-size placeholder that presents nothing.
private struct SongMoreButton: View {
    let track: Track
    @Environment(\.isPlayerMeasurement) private var measuring
    @State private var focused = false

    var body: some View {
        if measuring {
            Color.clear.frame(width: 28, height: 28)
        } else {
            KeyboardMoreButton(size: 14, focused: $focused, label: "More actions for \(track.title)", opensAbove: true) {
                TrackMenu(track: track)
            }
            .frame(width: 28, height: 28)
            .foregroundStyle(.primary.opacity(0.75))
            .modifier(LayoutProbe(key: "player-song-more"))
        }
    }
}

private struct LikeButton: View {
    let track: Track
    /// Space between the 28 pt target's edge and the 14 pt heart glyph inside it.
    static let glyphInset: CGFloat = 7
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.can(.like, track.provider), model.provider(track.provider)?.isSignedIn == true {
            let liked = model.isLiked(track)
            Button { model.toggleLike(track) } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.system(size: 14))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(IconButtonStyle(tint: liked ? .accentColor : .secondary))
            .help(liked ? "Remove from Liked Songs" : "Add to Liked Songs")
            .accessibilityLabel(liked ? "Unlike" : "Like")
        }
    }
}

// MARK: - Center: transport and timeline

private struct PlayerCenter: View {
    let showsModes: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let hasTrack = model.player.current != nil
        VStack(spacing: -3) {
            TransportControls(scale: 0.94, spacing: 15, showsModes: showsModes)
            // With nothing loaded, the transport sits alone and dimmed; no empty timeline.
            if hasTrack {
                ViewThatFits(in: .horizontal) {
                    BarTimeline(showsTimes: true)
                    BarTimeline(showsTimes: false)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .disabled(!hasTrack)
    }
}

/// Only this view reads `currentTime`, so time ticks re-render the timeline and nothing else.
private struct BarTimeline: View {
    let showsTimes: Bool
    @Environment(AppModel.self) private var model
    @State private var preview: TimeInterval?

    var body: some View {
        let player = model.player
        let total = player.displayDuration
        let long = (total ?? 0) >= 3600
        HStack(spacing: 8) {
            if showsTimes {
                Text((preview ?? player.currentTime).clock)
                    .frame(minWidth: long ? 46 : 34, alignment: .trailing)
            }
            Scrubber(current: player.currentTime, duration: total, isPlaying: player.state == .playing,
                     onPreview: { preview = $0 }) { model.seek(to: $0) }
                .frame(minWidth: showsTimes ? 150 : 60, idealWidth: showsTimes ? 150 : 60, maxWidth: .infinity)
            if showsTimes {
                Text(total?.clock ?? "-:--")
                    .frame(minWidth: long ? 46 : 34, alignment: .leading)
            }
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        // Opaque: the translucent `.secondary` measured about 3:1 over the glass.
        .foregroundStyle(.glassSecondary)
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(LayoutProbe(key: "player-timeline"))
    }
}

// MARK: - Right: panels, device, volume, windows

private struct PlayerTrailing: View {
    let tier: CapsuleTier
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.isPlayerMeasurement) private var measuring
    @State private var moreFocused = false

    // Three groups, left to right. A new control goes into its group here, and into `foldedItems` for the tiers that
    // fold it away; the capsule measures the result itself (`CapsuleRowLayout`), so tiers need no new numbers.
    var body: some View {
        HStack(spacing: 4) {
            panels
            destination
            windows
        }
        .fixedSize()
    }

    /// Lyrics and the queue. The minimal tier moves lyrics into "…".
    @ViewBuilder private var panels: some View {
        if tier != .minimal { PanelToggle(panel: .lyrics, symbol: "quote.bubble", label: "Lyrics") }
        PanelToggle(panel: .queue, symbol: "list.bullet", label: "Queue")
    }

    /// Where the sound plays and how loud. The Devices button (play on another device, like AirPlay or Spotify
    /// Connect) comes first in this group in the full tier; the "…" menu's destination section lists devices otherwise.
    @ViewBuilder private var destination: some View {
        // With nothing queued there is nothing to route or make louder: dimmed and inert, like Full Screen.
        let idle = model.player.current == nil
        if tier == .full {
            DevicesButton()
            OutputDeviceMenu()
            VolumeControl(width: 80)
                .disabled(idle)
        } else {
            VolumeButton()
                .disabled(idle)
        }
    }

    /// Mini player and full screen inline in the full tier; otherwise "…", which is also the song's More there: the
    /// song's actions first, then what the tier folded away.
    @ViewBuilder private var windows: some View {
        if tier == .full {
            BarIconButton(symbol: "pip", help: "Open Mini Player") { showMiniPlayer(openWindow) }
                .disabled(model.player.current == nil)
            BarIconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Full Screen Player") { presentFullScreen() }
                .disabled(model.player.current == nil)
        } else {
            songAndMoreMenu
        }
    }

    /// The song's actions, then what the tier folded away, from a "…" the keyboard reaches with Tab. The measuring
    /// copies get a same-size placeholder that presents nothing.
    @ViewBuilder private var songAndMoreMenu: some View {
        if measuring {
            Color.clear.frame(width: 28, height: 28)
        } else {
            let track = model.player.current
            KeyboardMoreButton(size: 14, focused: $moreFocused, label: track.map { "More actions for \($0.title)" } ?? "More",
                               opensAbove: true) {
                if let track {
                    TrackMenu(track: track)
                    Divider()
                }
                foldedItems
            }
            .frame(width: 28, height: 28)
            .foregroundStyle(.primary.opacity(0.75))
            .modifier(LayoutProbe(key: "player-more"))
        }
    }

    /// What the narrower tiers fold into "…": lyrics, shuffle and repeat (minimal), the windows, then where it plays.
    @ViewBuilder private var foldedItems: some View {
        let player = model.player
        Group {
            if tier == .minimal {
                Button(model.inspector == .lyrics ? "Hide Lyrics" : "Show Lyrics", systemImage: "quote.bubble") {
                    model.toggleInspector(.lyrics)
                }
                .disabled(player.current == nil && model.inspector != .lyrics)
                Toggle("Shuffle", systemImage: "shuffle", isOn: Binding(get: { player.shuffle }, set: { player.shuffle = $0 }))
                Picker("Repeat", systemImage: "repeat", selection: Binding(get: { player.repeatMode }, set: { player.repeatMode = $0 })) {
                    Text("Off").tag(RepeatMode.off)
                    Text("All").tag(RepeatMode.all)
                    Text("One").tag(RepeatMode.one)
                }
                Divider()
            }
            Button("Mini Player", systemImage: "pip") { showMiniPlayer(openWindow) }
                .disabled(player.current == nil)
            Button("Full Screen Player", systemImage: "arrow.up.left.and.arrow.down.right") { presentFullScreen() }
                .disabled(player.current == nil)
            Divider()
            // Destination: other devices to play on (Medley Sync), then the output devices.
            DevicesMenuSection()
            Divider()
            PlaybackDestinationPicker()
        }
    }

    private func presentFullScreen() {
        model.setFullScreenPlayerPresented(true)
    }
}

private struct BarIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(IconButtonStyle(tint: .primary.opacity(0.75)))
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Lyrics and queue. Open is the system accent color plus a dot, matching shuffle and repeat.
private struct PanelToggle: View {
    let panel: InspectorPanel
    let symbol: String
    let label: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let on = model.inspector == panel
        Button { model.toggleInspector(panel) } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .overlay(alignment: .bottom) {
                    Circle().frame(width: 4, height: 4).offset(y: 1).opacity(on ? 1 : 0)
                }
        }
        .buttonStyle(IconButtonStyle(tint: on ? .accentColor : .primary.opacity(0.75)))
        // With nothing playing there are no lyrics and no queue: dimmed and inert like Full Screen, unless the panel
        // is open (then it still closes it). History stays in the sidebar.
        .disabled(model.player.current == nil && !on)
        .animation(.easeOut(duration: 0.15), value: on)
        .help(on ? "Hide \(label)" : "Show \(label)")
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Where audio goes: System Default or a specific device for YouTube Music, which Medley plays itself. A Spotify
/// song plays wherever Spotify plays it, so then the button shows Spotify's device instead (`SpotifyDeviceMenu`).
/// The floating player shows it in its full tier, the full-screen player in its top-right corner.
struct OutputDeviceMenu: View {
    var tint: Color = .primary.opacity(0.75)
    /// The button's square target.
    var side: CGFloat = 28
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let engine = model.playingSpotifyEngine {
                SpotifyDeviceMenu(engine: engine, tint: tint, side: side)
            } else {
                LocalOutputMenu(tint: tint, side: side)
            }
        }
        // Nothing to route with nothing playing; Settings › Playback still picks the output device.
        .disabled(model.player.current == nil)
    }
}

private struct LocalOutputMenu: View {
    let tint: Color
    let side: CGFloat
    @Environment(AppModel.self) private var model

    var body: some View {
        let outputs = model.playback.outputs
        let device = model.playback.effectiveOutputDeviceUID.flatMap { outputs.device(uid: $0) }
        Menu {
            OutputDevicePicker()
        } label: {
            Image(systemName: OutputGlyph.name)
                .font(.system(size: 13, weight: .medium))
                .frame(width: side, height: side)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(IconButtonStyle(tint: tint))
        .menuIndicator(.hidden)
        .fixedSize()
        .help(device.map { "Playing on \($0.name)" } ?? "Output Device")
        .accessibilityLabel("Output device")
        .accessibilityValue(device?.name ?? "System Default")
    }
}

/// The "…" menu's destination: a "Play On" submenu with the output devices, or Spotify's devices while a Spotify song
/// plays. A submenu, not an inline picker, so its items keep the menu's symbol column and line up with the rest.
private struct PlaybackDestinationPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Group {
                if let engine = model.playingSpotifyEngine {
                    SpotifyDevicePicker(engine: engine)
                } else {
                    OutputDevicePicker()
                }
            }
            // The submenu's title already says "Play On".
            .labelsHidden()
        } label: {
            Label("Play On", systemImage: OutputGlyph.name)
        }
    }
}

extension AppModel {
    /// Spotify's player, while the song in the player is a Spotify song (nil for YouTube Music and sample data).
    var playingSpotifyEngine: SpotifyPlaybackEngine? {
        guard player.current?.provider == .spotify else { return nil }
        return (provider(.spotify) as? SpotifyProvider)?.engine
    }
}

/// Spotify's destination: the Spotify Connect devices to move playback to, or, when the Spotify app on this Mac
/// plays, its name (that app picks its own speakers, so Medley's output list would be wrong here).
private struct SpotifyDeviceMenu: View {
    let engine: SpotifyPlaybackEngine
    var tint: Color = .primary.opacity(0.75)
    var side: CGFloat = 28

    var body: some View {
        let destination = SpotifyDestination(engine)
        Menu {
            SpotifyDevicePicker(engine: engine)
        } label: {
            Image(systemName: OutputGlyph.name)
                .font(.system(size: 13, weight: .medium))
                .frame(width: side, height: side)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(IconButtonStyle(tint: tint))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Spotify plays on: \(destination.name)")
        .accessibilityLabel("Spotify device")
        .accessibilityValue(destination.name)
        // Connect lists the devices Spotify knows; ask once when a Connect song starts, not on a timer.
        .task(id: destination.route) {
            if destination.route == .connect { await engine.refreshDevices() }
        }
    }
}

private struct SpotifyDevicePicker: View {
    let engine: SpotifyPlaybackEngine
    @Environment(AppModel.self) private var model

    var body: some View {
        let destination = SpotifyDestination(engine)
        Section("Spotify") {
            if destination.route == .connect {
                if engine.devices.isEmpty {
                    Text(destination.name)
                } else {
                    Picker("Play On", selection: Binding(get: { destination.deviceID }, set: { id in
                        if let id { Task { await engine.transfer(to: id) } }
                    })) {
                        ForEach(engine.devices) { device in
                            Text(device.name).tag(Optional(device.id))
                        }
                    }
                    .pickerStyle(.inline)
                }
                Button("Refresh Devices", systemImage: "arrow.clockwise") { Task { await engine.refreshDevices() } }
            } else {
                // Shown, not chosen: the Spotify app on this Mac is the device, with its own speaker choice.
                Label(destination.name, systemImage: "checkmark")
            }
            Button("Spotify Playback Settings…") {
                model.requestSettings(.accounts)
                model.openSettingsAction?()
            }
        }
    }
}

/// Where Spotify plays right now, as the player shows it.
@MainActor
private struct SpotifyDestination {
    let route: SpotifyPlaybackEngine.ActiveRoute?
    let deviceID: String?
    let name: String

    init(_ engine: SpotifyPlaybackEngine) {
        let route = engine.activeRoute ?? (try? engine.resolveRoute())
        self.route = route
        switch route {
        case .connect:
            let device = engine.devices.first { $0.id == engine.connectDeviceID } ?? engine.devices.first(where: \.isActive)
            deviceID = device?.id
            name = device?.name ?? "Spotify Connect device"
        case .thisMac, nil:
            deviceID = nil
            name = "Spotify app on this Mac"
        }
    }
}

private struct OutputDevicePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.playback.settings
        let outputs = model.playback.outputs
        Picker("Play On", selection: $settings.outputDeviceUID) {
            Text("System Default").tag(String?.none)
            ForEach(outputs.devices) { device in
                Text(device.name).tag(Optional(device.uid))
            }
        }
        .pickerStyle(.inline)
    }
}

/// The output button's glyph in every player: AirPlay, as in Music, whichever device is chosen (the menu and the
/// tooltip name it). Spotify's device button uses it too, so the button doesn't change shape between services.
enum OutputGlyph {
    static let name = "airplay.audio"
}

// MARK: - Windows

/// Opens the mini player and brings it to the front, even when the app wasn't active.
/// The AppKit calls wait a turn so they never run inside a SwiftUI update.
@MainActor
func showMiniPlayer(_ openWindow: OpenWindowAction) {
    openWindow(id: "mini")
    DispatchQueue.main.async {
        NSApp.activate()
        MiniPlayerWindow.window?.makeKeyAndOrderFront(nil)
    }
}

/// Brings the main window back from the mini player.
@MainActor
func showMainWindow(_ openWindow: OpenWindowAction, model: AppModel) {
    openWindow(id: "main")
    DispatchQueue.main.async {
        NSApp.activate()
        if let window = model.mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }
}

extension EnvironmentValues {
    /// Set on the floating player's hidden measuring rows (`TierMinimums`): views in them present nothing.
    @Entry var isPlayerMeasurement = false
    /// Set on any hidden copy kept only to measure a width once (the player's tiers, a hero's action row): layout
    /// probes, debug frames and the Find field's ⌘F registration skip it.
    @Entry var isLayoutMeasurement = false
}

extension View {
    /// `.popover(isPresented:)`, left out on the floating player's hidden measuring rows.
    func playerPopover<Content: View>(isPresented: Binding<Bool>, arrowEdge: Edge, @ViewBuilder content: @escaping () -> Content) -> some View {
        modifier(PlayerPopover(isPresented: isPresented, arrowEdge: arrowEdge, popover: content))
    }
}

private struct PlayerPopover<Popover: View>: ViewModifier {
    @Binding var isPresented: Bool
    let arrowEdge: Edge
    let popover: () -> Popover
    @Environment(\.isPlayerMeasurement) private var measuring

    func body(content: Content) -> some View {
        if measuring {
            content
        } else {
            content.popover(isPresented: $isPresented, arrowEdge: arrowEdge, content: popover)
        }
    }
}
