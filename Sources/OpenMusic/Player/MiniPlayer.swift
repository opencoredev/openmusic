import AppKit
import OpenMusicCore
import SwiftUI

/// The mini player window (⌥⌘M): artwork on top, then the song with Like and its "…" menu, and persistent
/// previous, play/pause and next. Lyrics, Playing Next and the button back to the main window show top right on
/// hover, as in Music's MiniPlayer. The position shows at a glance as "1:02 / 3:51" under the
/// artist and a thin progress line along the top of the strip, just under the artwork; hovering the window (or moving keyboard focus into it) swaps it for the
/// timeline, times and volume over the bottom of the artwork. The window keeps one size, so nothing jumps.
struct MiniPlayerView: View {
    static let width: CGFloat = 300

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var hovering = false
    @State private var tint: TintColor?
    @FocusState private var focus: Control?
    /// Keyboard focus is somewhere in the timeline or volume, so they stay visible while focused.
    @FocusState private var overlayFocused: Bool
    /// Keyboard focus is on the Lyrics, Playing Next or Back to the Main Window button.
    @FocusState private var panelButtonsFocused: Bool
    /// Keyboard focus is on the song's "…" button.
    @State private var moreFocused = false
    @State private var titleBarHeight: CGFloat = 0
    /// The system appearance: the strip under the artwork follows it, as Music's MiniPlayer does. The artwork and
    /// what sits on it (hover controls, panel buttons) stay dark.
    @Environment(\.colorScheme) private var scheme

    enum Control: Hashable { case previous, play, next }

    var body: some View {
        let track = model.player.current
        let reveal = hovering || focus != nil || overlayFocused || panelButtonsFocused
        VStack(spacing: 0) {
            ArtworkView(artwork: track?.artwork, size: Self.width, cornerRadius: 0)
                .frame(width: Self.width, height: Self.width)
                .overlay(alignment: .bottom) {
                    MiniHoverControls()
                        .focused($overlayFocused)
                        .opacity(reveal ? 1 : 0)
                        .allowsHitTesting(reveal)
                }
                // Lyrics and Playing Next open in the main window, top right, clear of the traffic lights.
                .overlay(alignment: .topTrailing) {
                    MiniPanelButtons()
                        .focused($panelButtonsFocused)
                        .opacity(reveal ? 1 : 0)
                        .allowsHitTesting(reveal)
                }
                // What the mini player's own actions report (a refused Like, Add to Queue from its More): under the
                // traffic lights and the hover buttons, clear of the timeline, and over the artwork, so the window keeps
                // its size and the transport below stays where it is.
                .overlay(alignment: .top) { MiniNotice().padding(.top, 50) }
                .contextMenu { if let track { TrackMenu(track: track) } }
                .environment(\.colorScheme, .dark)

            VStack(spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track?.title ?? "Not Playing")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(MiniStripInk.title(scheme))
                        if let track {
                            Text(track.artistLine)
                                .font(.system(size: 12))
                                .foregroundStyle(MiniStripInk.secondary(scheme))
                            // The hover timeline has its own times: one clock at a time. Hidden, not removed, so
                            // the strip keeps its height.
                            MiniPositionText()
                                .padding(.top, 1)
                                .opacity(reveal ? 0 : 1)
                                .accessibilityHidden(reveal)
                        }
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(track.map { "\($0.title) — \($0.artistLine)" } ?? "")

                    // Like and the song's menu (the same `TrackMenu` as the full-screen player's "…"), right after
                    // the title as in the floating and full-screen players.
                    if let track {
                        HStack(spacing: 0) {
                            MiniLikeButton(track: track)
                            // Opens up over the artwork: below, it would hang off the small window's bottom edge.
                            // Over dark artwork it draws dark (the artwork and its controls stay dark in light mode).
                            KeyboardMoreButton(size: 14, focused: $moreFocused, probeNote: "mini-more",
                                               label: "More actions for \(track.title)", opensAbove: true,
                                               forceDark: scheme == .light && (tint?.brightness ?? 1) < 0.45) {
                                TrackMenu(track: track)
                            }
                            .foregroundStyle(MiniStripInk.control(scheme).opacity(0.85))
                            .frame(width: 28, height: 28)
                            .modifier(LayoutProbe(key: "mini-more"))
                        }
                    }
                }

                MiniTransport(focus: $focus)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
            .frame(width: Self.width)
            .background { MiniStripBackground(tint: tint, scheme: scheme) }
            // Along the strip's top edge, just under the artwork: on the strip's own known background, in its text
            // ink, so the played part reads as played on any cover.
            .overlay(alignment: .top) {
                MiniProgressLine(scheme: scheme)
                    .opacity(reveal || track == nil ? 0 : 1)
            }
        }
        .frame(width: Self.width)
        // The artwork runs to the window's top edge, under the traffic lights (the title bar is hidden and
        // transparent), as in Music's MiniPlayer. Pulled up by the title bar's height rather than ignoring the safe
        // area, so the window (sized to its content) loses that height instead of leaving a band at the bottom.
        .padding(.top, -titleBarHeight)
        // A floating mini player is usually hovered while another app is active, where SwiftUI's
        // `onHover` stays silent; this tracking area reports the pointer in any state.
        .overlay { HoverTracker { h in withAnimation(.easeOut(duration: 0.18)) { hovering = h } } }
        .animation(.easeOut(duration: 0.18), value: focus != nil || overlayFocused || panelButtonsFocused)
        .background(WindowAccessor { window in
            MiniPlayerWindow.window = window
            // `.hiddenTitleBar` already gives full-size content; a transparent title bar keeps AppKit from drawing
            // its own strip behind the traffic lights in light mode.
            DispatchQueue.main.async {
                guard let window else { return }
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.styleMask.insert(.fullSizeContentView)
                // The title bar's height: the part of the window outside its content layout rect.
                let bar = (window.frame.height - window.contentLayoutRect.height).rounded()
                if bar > 0, bar < 60, bar != titleBarHeight { titleBarHeight = bar }
            }
        })
        // The song's "…" is the window's only view that takes focus without Keyboard Navigation, so AppKit handed it
        // the focus each time the window became key and its ring showed at rest. Tab still reaches it.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let window = note.object as? NSWindow, window === MiniPlayerWindow.window else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if moreFocused, NSApp.currentEvent?.type != .keyDown { window.makeFirstResponder(nil) }
            }
        }
        .onAppear { model.isMiniPlayerOpen = true }
        .onDisappear { model.isMiniPlayerOpen = false }
        .task(id: track?.artwork?.url(minPixels: 64)) {
            guard let url = track?.artwork?.url(minPixels: 64) else { tint = nil; return }
            let value = await ArtworkTintCache.shared.tint(for: url)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) { tint = value }
        }
    }
}

/// A notice for something done in the mini player (`AppModel.Notice.inMiniPlayer`), sized for its 300 pt window: the
/// text wraps to four lines beside its symbol, Try Again sits under it, and a failure has a close button top right.
/// It stays until closed, like the main window's; a confirmation goes by itself and lets clicks through.
private struct MiniNotice: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let notice = model.notice, notice.inMiniPlayer {
                MiniNoticeCard(notice: notice)
                    .id(notice.id)
                    .transition(Motion.Transition.miniPlayerNotice.transition(reduce: reduceMotion))
                    .allowsHitTesting(notice.kind == .failure || notice.action != nil)
            }
        }
        .padding(.horizontal, 10)
        .animation(.easeOut(duration: 0.2), value: model.notice)
        .onChange(of: model.notice) { _, notice in
            guard let notice, notice.inMiniPlayer else { return }
            let hint = (notice.action.map { " \($0.title) is available." } ?? "")
                + (notice.kind == .failure && notice.retry != nil ? " Try Again is available." : "")
                + (notice.secondaryAction.map { " \($0.title) is available." } ?? "")
            AccessibilityNotification.Announcement(notice.text + hint).post()
        }
    }
}

private struct MiniNoticeCard: View {
    let notice: AppModel.Notice
    @Environment(AppModel.self) private var model

    var body: some View {
        let failure = notice.kind == .failure
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: notice.symbol)
                .font(.system(size: 13))
                .foregroundStyle(failure ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(notice.text)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                if notice.action != nil || notice.secondaryAction != nil || (failure && notice.retry != nil) {
                    HStack(spacing: 6) {
                        // A failure can carry one too: a removal that stopped partway offers Undo beside Try Again.
                        if let action = notice.action {
                            Button(action.title) {
                                model.dismissNotice()
                                action.run()
                            }
                            .buttonStyle(NoticeButtonStyle())
                            .modifier(LayoutProbe(key: "mini-notice-action"))
                        }
                        if failure, let retry = notice.retry {
                            Button("Try Again") {
                                model.dismissNotice()
                                retry()
                            }
                            .buttonStyle(NoticeButtonStyle())
                            .modifier(LayoutProbe(key: "mini-notice-retry"))
                        }
                        if let secondary = notice.secondaryAction {
                            Button(secondary.title) {
                                model.dismissNotice()
                                secondary.run()
                            }
                            .buttonStyle(NoticeButtonStyle())
                            .modifier(LayoutProbe(key: "mini-notice-secondary"))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if failure {
                Button {
                    model.dismissNotice()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(NoticeCloseStyle())
                .padding(.top, -3)
                .padding(.trailing, -3)
                .help("Close")
                .accessibilityLabel("Close")
                .modifier(LayoutProbe(key: "mini-notice-close"))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(MiniNoticeGlass())
        .accessibilityElement(children: .contain)
        .modifier(LayoutProbe(key: "mini-notice"))
    }
}

/// Dark glass over the artwork (the artwork's overlays are always dark), a rounded rectangle since the text wraps.
private struct MiniNoticeGlass: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        if #available(macOS 26.0, *) {
            // A black layer between the glass and the text keeps white text at 4.5:1 over a pale cover.
            content
                .background(.black.opacity(0.4), in: shape)
                .glassEffect(.regular.tint(.black.opacity(0.3)), in: shape)
        } else {
            content
                .background(.black.opacity(0.6), in: shape)
                .background(.ultraThinMaterial, in: shape)
        }
    }
}

/// The mini player's window, so ⌥⌘M can bring it to the front.
@MainActor
enum MiniPlayerWindow {
    static weak var window: NSWindow?
}

/// Previous, play/pause, next. Always visible: the mini player's main job.
private struct MiniTransport: View {
    var focus: FocusState<MiniPlayerView.Control?>.Binding
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let player = model.player
        let hasQueue = !player.queue.isEmpty
        let ink = MiniStripInk.control(scheme)
        HStack(spacing: 28) {
            Button { model.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 17)).frame(width: 32, height: 32)
            }
            .buttonStyle(IconButtonStyle(tint: ink))
            .disabled(!hasQueue)
            .focused(focus, equals: .previous)
            .help("Previous")
            .accessibilityLabel("Previous")

            PlayPauseButton(size: 38, tint: scheme == .dark ? .white : .primary)
                .focused(focus, equals: .play)

            Button { model.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 17)).frame(width: 32, height: 32)
            }
            .buttonStyle(IconButtonStyle(tint: ink))
            .disabled(!hasQueue)
            .focused(focus, equals: .next)
            .help("Next")
            .accessibilityLabel("Next")
            .modifier(FocusProbe(key: "mini-next"))
        }
    }
}

/// The strip's text and control colors. Dark: white on the darkened tint. Light: near-black, with an opaque gray
/// for the artist and the time that stays at 4.5:1 or more on the palest tinted strip (see `MiniStripBackground`).
enum MiniStripInk {
    static func title(_ scheme: ColorScheme) -> Color { scheme == .dark ? .white : Color(white: 0.08) }
    static func secondary(_ scheme: ColorScheme) -> Color { scheme == .dark ? .white.opacity(0.7) : Color(white: 0.3) }
    static func time(_ scheme: ColorScheme) -> Color { scheme == .dark ? .white.opacity(0.68) : Color(white: 0.3) }
    static func control(_ scheme: ColorScheme) -> Color { scheme == .dark ? .white : Color(white: 0.1) }
    /// A liked heart: the accent, lightened on the dark strip where the system blue sits near 3:1.
    static func liked(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(nsColor: .controlAccentColor.blended(withFraction: 0.25, of: .white) ?? .controlAccentColor) : .accentColor
    }
}

/// Dark: a dark material tinted with the artwork's color, darkened so white text keeps its contrast. Light: the
/// light material washed toward white, then the artwork's pastel, like Music's MiniPlayer in light mode. Gray
/// artwork gets the plain material in either.
private struct MiniStripBackground: View {
    let tint: TintColor?
    let scheme: ColorScheme

    var body: some View {
        ZStack {
            Rectangle().fill(.thickMaterial)
            if scheme == .dark {
                Color.black.opacity(0.5)
                if let tint, tint.saturation > 0 {
                    tint.color(for: .dark).opacity(0.6).transition(.opacity)
                    Color.black.opacity(0.18)
                }
            } else {
                Color.white.opacity(0.35)
                if let tint, tint.saturation > 0 {
                    tint.color(for: .light).opacity(0.75).transition(.opacity)
                }
            }
        }
    }
}

/// Lyrics, Playing Next and Back to the Main Window on the hovered artwork: the first two bring the main window
/// forward with that panel open.
private struct MiniPanelButtons: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 2) {
            button(.lyrics, symbol: "quote.bubble", label: "Lyrics")
                .disabled(!model.currentSongHasLyrics)
            button(.queue, symbol: "list.bullet", label: "Playing Next")
            // Back to the full window: the expand arrows say "bigger" where a bare window outline didn't say what
            // it would do.
            Button { showMainWindow(openWindow, model: model) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(IconButtonStyle(tint: .white))
            .help("Back to the Main Window")
            .accessibilityLabel("Show main window")
            .accessibilityHint("Brings back \(ProductInfo.name)'s full window")
            .modifier(LayoutProbe(key: "mini-expand"))
        }
        .padding(3)
        .background(.black.opacity(0.35), in: Capsule())
        .padding(10)
    }

    private func button(_ panel: InspectorPanel, symbol: String, label: String) -> some View {
        Button {
            if model.inspector != panel { model.toggleInspector(panel) }
            showMainWindow(openWindow, model: model)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(IconButtonStyle(tint: .white))
        .help("Show \(label) in the Main Window")
        .accessibilityLabel("Show \(label)")
    }
}

/// Like for the playing song on the strip, where its service supports likes and is signed in: the strip's ink, or the
/// liked heart's accent once liked (both 3:1 or more on either strip, as a control needs).
private struct MiniLikeButton: View {
    let track: Track
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if model.can(.like, track.provider), model.provider(track.provider)?.isSignedIn == true {
            let liked = model.isLiked(track)
            Button { model.toggleLike(track) } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.system(size: 14))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(IconButtonStyle(tint: liked ? MiniStripInk.liked(scheme) : MiniStripInk.control(scheme).opacity(0.85)))
            .help(liked ? "Remove from Liked Songs" : "Add to Liked Songs")
            .accessibilityLabel(liked ? "Unlike" : "Like")
            .modifier(LayoutProbe(key: "mini-like"))
        }
    }
}

/// "1:02 / 3:51" in tabular digits under the artist, shown while the hover timeline (which has its own times) is
/// hidden. Its own view, so the time tick redraws only this line. Dark: white at 68% on the tinted strip measures
/// at or above 5.5:1. Light: 30% gray on the pastel strip, 6:1 or more.
private struct MiniPositionText: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let player = model.player
        let elapsed = player.currentTime
        let total = player.displayDuration
        Text(total.map { "\(elapsed.clock) / \($0.clock)" } ?? elapsed.clock)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(MiniStripInk.time(scheme))
            .lineLimit(1)
            .accessibilityLabel(Self.spoken(elapsed: elapsed, total: total))
    }

    static func spoken(elapsed: TimeInterval, total: TimeInterval?) -> String {
        func words(_ t: TimeInterval) -> String {
            Duration.seconds(max(0, t.rounded(.down))).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
        }
        return total.map { "\(words(elapsed)) of \(words($0))" } ?? words(elapsed)
    }
}

/// Position at a glance: a 2 pt line along the top edge of the strip under the artwork, no thumb, not interactive.
/// Seeking is the hover timeline's job. It sits on the strip, not the artwork, so its background is known: the played
/// part in the strip's title ink, the rest in that ink at 18%, in light and dark alike. It moves only when the
/// player's time does (a scale, no animation), as before.
private struct MiniProgressLine: View {
    let scheme: ColorScheme
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        let total = player.displayDuration ?? 0
        let fraction = total > 0 ? min(1, max(0, player.currentTime / total)) : 0
        let ink = MiniStripInk.title(scheme)
        Rectangle()
            .fill(ink.opacity(0.18))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(ink)
                    .scaleEffect(x: fraction, anchor: .leading)
            }
            .frame(height: 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Timeline, times and volume over a dark scrim at the bottom of the artwork.
private struct MiniHoverControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        VStack(spacing: 4) {
            Scrubber(current: player.currentTime, duration: player.current == nil ? nil : player.displayDuration,
                     isPlaying: player.state == .playing, tint: .white, trackOpacity: 0.3, activeTint: nil) {
                model.seek(to: $0)
            }
            TimeLabels(current: player.currentTime, duration: player.displayDuration)
                .foregroundStyle(.white.opacity(0.85))
            // Full width, so the speaker and the slider's ends line up with the timeline above.
            VolumeControl(width: nil, tint: .white, activeTint: nil)
        }
        .padding(.horizontal, 16)
        .padding(.top, 36)
        .padding(.bottom, 8)
        .background {
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// Reports the pointer entering and leaving, even when the window isn't key or the app isn't active.
/// It passes every click through to the views below.
struct HoverTracker: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) { view.onChange = onChange }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { onChange?(true) }
        override func mouseExited(with event: NSEvent) { onChange?(false) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
