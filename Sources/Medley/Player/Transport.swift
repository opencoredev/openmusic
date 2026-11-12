import AppKit
import MedleyCore
import SwiftUI

/// Shuffle, previous, play/pause, next, repeat. The floating player, the full-screen player and the mini player
/// all use this, at different sizes.
struct TransportControls: View {
    var scale: CGFloat = 1
    var tint: Color = .primary
    /// Space between buttons at scale 1.
    var spacing: CGFloat = 18
    var showsModes = true
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        let hasQueue = !player.queue.isEmpty
        HStack(spacing: spacing * scale) {
            if showsModes {
                ModeButton(symbol: "shuffle", on: player.shuffle, scale: scale, tint: tint,
                           help: player.shuffle ? "Turn Shuffle Off" : "Shuffle", label: "Shuffle", value: player.shuffle ? "On" : "Off") {
                    player.shuffle.toggle()
                }
            }

            Button { model.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 15 * scale))
                    .frame(width: 28 * scale, height: 28 * scale)
            }
            .buttonStyle(IconButtonStyle(tint: tint))
            .disabled(!hasQueue)
            .help("Previous")
            .accessibilityLabel("Previous")

            PlayPauseButton(size: 34 * scale, tint: tint)

            Button { model.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 15 * scale))
                    .frame(width: 28 * scale, height: 28 * scale)
            }
            .buttonStyle(IconButtonStyle(tint: tint))
            .disabled(!hasQueue)
            .help("Next")
            .accessibilityLabel("Next")
            .modifier(FocusProbe(key: "player-next"))

            if showsModes {
                ModeButton(symbol: player.repeatMode == .one ? "repeat.1" : "repeat", on: player.repeatMode != .off, scale: scale, tint: tint,
                           help: player.repeatMode.help, label: "Repeat", value: player.repeatMode.rawValue) {
                    player.repeatMode = player.repeatMode.next
                }
            }
        }
    }
}

/// The big round play/pause button. When the stream has been resolving or refilling for `ringDelay` without a
/// break, a ring circles on the disc's edge: a faint full track with a short arc going round it. The brief waits
/// AVPlayer makes during normal playback (a few hundred milliseconds) show nothing. The delay is one state flip in
/// a task, cancelled when buffering ends; Core Animation turns the arc (`SpinnerRing`), so nothing animates
/// through SwiftUI. Shared by the floating, mini and full-screen players.
struct PlayPauseButton: View {
    var size: CGFloat = 34
    var tint: Color = .primary
    @Environment(AppModel.self) private var model
    /// A hidden copy kept only to measure the floating player's tiers: it never waits for or draws the ring.
    @Environment(\.isPlayerMeasurement) private var measuring
    /// Buffering has gone on for `ringDelay`.
    @State private var showsRing = false

    static let ringDelay: Duration = .milliseconds(500)

    /// Whether a button watches buffering at all: never in a measuring copy (no delay task, no Core Animation).
    static func tracksBuffering(_ buffering: Bool, measuring: Bool) -> Bool { buffering && !measuring }

    private var isBuffering: Bool {
        #if DEBUG
        if model.debugForcesBuffering { return Self.tracksBuffering(true, measuring: measuring) }
        #endif
        return Self.tracksBuffering(model.player.isBuffering, measuring: measuring)
    }

    var body: some View {
        let player = model.player
        let playing = player.isPlaying
        let buffering = isBuffering
        Button { model.togglePlayPause() } label: {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
                // The play triangle's visual center sits left of its box.
                .offset(x: playing ? 0 : size * 0.03)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
        }
        .buttonStyle(RoundPlayButtonStyle(tint: tint, ring: showsRing && buffering))
        .task(id: buffering) {
            guard buffering else { showsRing = false; return }
            try? await Task.sleep(for: Self.ringDelay)
            if !Task.isCancelled, isBuffering { showsRing = true }
        }
        .disabled(player.queue.isEmpty)
        .help(playing ? "Pause" : "Play")
        .accessibilityLabel(playing ? "Pause" : "Play")
        .accessibilityValue(showsRing && buffering ? "Loading" : "")
        // Council captures read when the ring appears (`fullscreen-buffering`).
        .onChange(of: showsRing && buffering, initial: true) { if LayoutProbe.enabled { DebugProbes.note("play-ring", showsRing && buffering ? "drawn" : nil) } }
    }
}

/// Ink on paper: a disc in the foreground color with the glyph knocked out in the background color.
///
/// With the default `.primary` tint the colors are solid (near-white on dark, near-black on light), not the
/// hierarchical `.primary` style: inside Liquid Glass that style turns vibrant and the disc washed out to gray.
private struct RoundPlayButtonStyle: ButtonStyle {
    let tint: Color
    /// The buffering ring, in the glyph's ink on the disc's edge.
    var ring = false

    func makeBody(configuration: Configuration) -> some View {
        RoundBody(configuration: configuration, tint: tint, ring: ring)
    }

    private struct RoundBody: View {
        let configuration: Configuration
        let tint: Color
        let ring: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorScheme) private var scheme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            let ink = tint == .primary
            let disc: Color = ink ? (scheme == .dark ? Color(white: 0.96) : Color(white: 0.1)) : tint
            let glyph: Color = ink ? (scheme == .dark ? Color(white: 0.08) : .white) : .black
            configuration.label
                .foregroundStyle(glyph)
                .background(Circle().fill(disc))
                .overlay {
                    // On the disc's edge, inside it: it scales with the disc on hover and press.
                    if ring { SpinnerRing(ink: glyph, spins: !reduceMotion) }
                }
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : 0.35)
                .motionScale(configuration.isPressed ? 0.96 : hovering && isEnabled ? 1.04 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// The buffering ring: a faint full circle (the track) and a quarter arc on it, 2 pt wide, filling its frame. Core
/// Animation turns the arc (one repeating rotation on its layer), so SwiftUI renders nothing while it spins; with
/// Reduce Motion the arc stands still, on the top right. The rotation runs only while the view is in a window and not
/// hidden: it is taken off when the view leaves or hides, and put back when it returns.
struct SpinnerRing: NSViewRepresentable {
    let ink: Color
    let spins: Bool

    func makeNSView(context: Context) -> RingView { RingView() }

    static func dismantleNSView(_ view: RingView, coordinator: ()) { view.stop() }

    func updateNSView(_ view: RingView, context: Context) {
        // Resolved in SwiftUI's environment, so the full-screen player's forced scheme still applies.
        let color = NSColor(cgColor: ink.resolve(in: context.environment).cgColor) ?? .labelColor
        view.update(color: color.cgColor, spins: spins)
    }

    final class RingView: NSView {
        private let track = CAShapeLayer()
        private let arc = CAShapeLayer()
        /// The ring should turn (not with Reduce Motion); it does only while shown (`isTurning`).
        private var spins = false

        /// The rotation is on the arc's layer.
        var isTurning: Bool { arc.animation(forKey: "spin") != nil }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for shape in [track, arc] {
                shape.fillColor = nil
                shape.lineWidth = 2
                shape.lineCap = .round
                layer?.addSublayer(shape)
            }
            arc.strokeEnd = 0.25
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            let bounds = self.bounds
            let path = CGPath(ellipseIn: bounds.insetBy(dx: 1, dy: 1), transform: nil)
            for shape in [track, arc] {
                shape.frame = bounds
                shape.path = path
            }
            // Turn about the ring's center; start the arc at the top.
            arc.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            arc.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }

        func update(color: CGColor, spins: Bool) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            track.strokeColor = color.copy(alpha: color.alpha * 0.25)
            arc.strokeColor = color
            CATransaction.commit()
            self.spins = spins
            syncRotation()
        }

        /// Taken down for good (SwiftUI dismantled the view).
        func stop() {
            spins = false
            syncRotation()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            syncRotation()
        }

        override func viewDidHide() {
            super.viewDidHide()
            syncRotation()
        }

        override func viewDidUnhide() {
            super.viewDidUnhide()
            syncRotation()
        }

        /// The rotation runs exactly while it should turn and the view is on screen in a window.
        private func syncRotation() {
            let turn = spins && window != nil && !isHiddenOrHasHiddenAncestor
            guard turn != isTurning else { return }
            if turn {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = -2 * Double.pi
                spin.duration = 0.9
                spin.repeatCount = .infinity
                spin.isRemovedOnCompletion = false
                arc.add(spin, forKey: "spin")
            } else {
                arc.removeAnimation(forKey: "spin")
            }
        }
    }
}

/// Shuffle and repeat. "On" is the system accent color plus a small dot under the symbol, so the state
/// also reads without color.
private struct ModeButton: View {
    let symbol: String
    let on: Bool
    let scale: CGFloat
    let tint: Color
    let help: String
    let label: String
    let value: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13 * scale, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28 * scale, height: 28 * scale)
                .overlay(alignment: .bottom) {
                    Circle().frame(width: 4 * scale, height: 4 * scale)
                        .offset(y: 1 * scale)
                        .opacity(on ? 1 : 0)
                }
        }
        .buttonStyle(IconButtonStyle(tint: on ? (tint == .primary ? .accentColor : tint) : tint.opacity(0.6)))
        .animation(.easeOut(duration: 0.15), value: on)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

extension RepeatMode {
    var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    var help: String {
        switch self {
        case .off: "Repeat All"
        case .all: "Repeat One"
        case .one: "Turn Repeat Off"
        }
    }
}

// MARK: - Volume

/// A speaker button (click to mute) and a line slider.
struct VolumeControl: View {
    /// The slider's width; nil fills the row, with the speaker flush with the row's leading edge (the mini player,
    /// where it lines up under the timeline).
    var width: CGFloat? = 92
    var tint: Color = .primary
    var activeTint: Color? = .accentColor
    @Environment(AppModel.self) private var model
    @Environment(\.isEnabled) private var isEnabled
    @State private var unmutedVolume: Float = 0.7

    var body: some View {
        let settings = model.playback.settings
        let fills = width == nil
        HStack(spacing: fills ? 8 : 4) {
            Button { toggleMute() } label: {
                Image(systemName: volumeSymbol(settings.volume))
                    .font(.system(size: 13))
                    .contentTransition(.symbolEffect(.replace))
                    // The widest symbol (speaker.wave.3) is about 20 pt.
                    .frame(width: fills ? 20 : 28, height: 28, alignment: fills ? .leading : .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(IconButtonStyle(tint: tint.opacity(0.75)))
            .help(settings.volume < 0.01 ? "Unmute" : "Mute")
            .accessibilityLabel(settings.volume < 0.01 ? "Unmute" : "Mute")

            LineSlider(
                value: Double(settings.volume),
                tint: tint,
                activeTint: activeTint,
                accessibilityLabel: "Volume",
                accessibilityValue: "\(Int((settings.volume * 100).rounded())) percent",
                onEditing: { f in if let f { settings.volume = Float(f) } },
                onCommit: { settings.volume = Float($0) }
            )
            .frame(width: width)
            .frame(maxWidth: fills ? .infinity : nil)
            // Disabled (nothing queued in the floating player): dimmed like the icon buttons, and no drags.
            .opacity(isEnabled ? 1 : 0.35)
            .allowsHitTesting(isEnabled)
        }
    }

    private func toggleMute() {
        let settings = model.playback.settings
        if settings.volume < 0.01 {
            settings.volume = max(unmutedVolume, 0.1)
        } else {
            unmutedVolume = settings.volume
            settings.volume = 0
        }
    }
}

func volumeSymbol(_ v: Float) -> String {
    switch v {
    case ..<0.01: "speaker.slash.fill"
    case ..<0.34: "speaker.wave.1.fill"
    case ..<0.67: "speaker.wave.2.fill"
    default: "speaker.wave.3.fill"
    }
}

/// Volume as a single button with a popover slider, for narrow windows.
struct VolumeButton: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false

    var body: some View {
        let settings = model.playback.settings
        Button { showing.toggle() } label: {
            Image(systemName: volumeSymbol(settings.volume))
                .font(.system(size: 13))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(IconButtonStyle(tint: .primary.opacity(0.75)))
        .help("Volume")
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((settings.volume * 100).rounded())) percent")
        .playerPopover(isPresented: $showing, arrowEdge: .top) {
            VolumeControl(width: 140)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }
}
