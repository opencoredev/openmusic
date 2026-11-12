import AppKit
import OpenMusicCore
import SwiftUI

/// A thin line you can click, drag or arrow-key along: the timeline and the volume slider.
///
/// The line stays thin, but the hit area is at least 16 pt tall. The thumb appears on hover, while
/// dragging, and when the slider has keyboard focus; the fill switches to `activeTint` at the same time.
struct LineSlider: View {
    /// Shown position, 0...1.
    let value: Double
    var enabled = true
    var lineHeight: CGFloat = 4
    var tint: Color = .primary
    var trackOpacity: Double = 0.18
    /// Fill color while hovered, dragged or focused. `nil` keeps `tint`.
    var activeTint: Color? = .accentColor
    /// How far one arrow-key press moves, as a fraction.
    var step: Double = 0.05
    /// Set for the playback timeline: the fill is a Core Animation layer that glides to each new `value` over this
    /// many seconds (0 jumps). Nil draws the fill in SwiftUI, for sliders that only move when the user moves them.
    var glide: TimeInterval? = nil
    var accessibilityLabel: String
    var accessibilityValue: String
    /// The live position while dragging, then `nil` when the drag ends.
    var onEditing: (Double?) -> Void = { _ in }
    /// The final position (end of a drag, a click, or an arrow key).
    let onCommit: (Double) -> Void

    @State private var drag: Double?
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        let active = enabled && (hovering || drag != nil || focused)
        let shown = drag ?? min(max(value, 0), 1)
        let thumb = lineHeight + 8
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(tint.opacity(enabled ? trackOpacity : trackOpacity * 0.6))
                    .frame(height: lineHeight)
                let fill = active ? (activeTint ?? tint) : tint.opacity(0.85)
                if let glide {
                    GlidingFill(fraction: shown, glide: drag == nil ? glide : 0, color: fill, lineHeight: lineHeight)
                        .frame(height: lineHeight)
                        .opacity(enabled ? 1 : 0)
                } else {
                    Capsule()
                        .fill(fill)
                        .frame(width: max(lineHeight, width * shown), height: lineHeight)
                        .opacity(enabled ? 1 : 0)
                }
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .frame(width: thumb, height: thumb)
                    .offset(x: min(max(0, width * shown - thumb / 2), width - thumb))
                    // The thumb glides with the fill, but only while it shows: a hidden thumb animates nothing,
                    // so playback with the pointer away still costs one update per time report.
                    .animation(active && drag == nil && (glide ?? 0) > 0 ? .linear(duration: glide ?? 0) : nil, value: shown)
                    .opacity(active ? 1 : 0)
                    .motionScale(active ? 1 : 0.5)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard enabled else { return }
                        let f = min(max(g.location.x / width, 0), 1)
                        drag = f
                        onEditing(f)
                    }
                    .onEnded { _ in
                        guard let f = drag else { return }
                        onCommit(f)
                        drag = nil
                        onEditing(nil)
                    }
            )
        }
        .frame(height: max(16, thumb + 4))
        .onHover { hovering = $0 }
        .focusable(enabled, interactions: .activate)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { nudge(-1); return .handled }
        .onKeyPress(.rightArrow) { nudge(1); return .handled }
        .animation(.easeOut(duration: 0.12), value: active)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(1)
            case .decrement: nudge(-1)
            @unknown default: break
            }
        }
    }

    private func nudge(_ sign: Double) {
        guard enabled else { return }
        onCommit(min(max(value + sign * step, 0), 1))
    }
}

/// The playback timeline: a `LineSlider` that glides between the engine's time reports.
///
/// The engine reports time every ~0.5s; between reports the fill glides linearly so it never stutters.
/// Core Animation runs the glide (`GlidingFill`): the main thread sets one target per report. A SwiftUI animation
/// here re-rendered and laid out the whole window on every frame for as long as music played.
/// While paused nothing animates, so idle CPU stays at zero.
struct Scrubber: View {
    let current: TimeInterval
    let duration: TimeInterval?
    let isPlaying: Bool
    var lineHeight: CGFloat = 4
    var tint: Color = .primary
    var trackOpacity: Double = 0.18
    var activeTint: Color? = .accentColor
    /// The time under the pointer while dragging, so the elapsed label can follow it.
    var onPreview: (TimeInterval?) -> Void = { _ in }
    let onSeek: (TimeInterval) -> Void

    @State private var shown: TimeInterval = 0
    /// How long the fill takes to reach `shown`: the time since the last report while playing, else 0.
    @State private var glide: TimeInterval = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var total: TimeInterval? { duration.flatMap { $0 > 0 ? $0 : nil } }

    var body: some View {
        let total = total
        LineSlider(
            value: total.map { shown / $0 } ?? 0,
            enabled: total != nil,
            lineHeight: lineHeight,
            tint: tint,
            trackOpacity: trackOpacity,
            activeTint: activeTint,
            step: total.map { min(5 / $0, 1) } ?? 0.05,
            glide: glide,
            accessibilityLabel: "Playback position",
            accessibilityValue: "\(current.clock) of \((total ?? 0).clock)",
            onEditing: { f in onPreview(f.flatMap { f in total.map { f * $0 } }) },
            onCommit: { f in
                guard let total else { return }
                glide = 0
                shown = f * total
                onSeek(f * total)
            }
        )
        .onAppear { shown = current }
        .onChange(of: current) { old, new in
            let delta = new - old
            glide = isPlaying && delta > 0 && delta < 1.1 && !reduceMotion ? delta : 0
            shown = new
        }
    }
}

/// The played part of the timeline: a capsule layer whose width Core Animation moves, so a glide costs the main
/// thread one update per time report instead of a SwiftUI render of the window per frame. Each new fraction
/// glides from where the fill is on screen; a resize or a zero glide jumps.
private struct GlidingFill: NSViewRepresentable {
    let fraction: Double
    let glide: TimeInterval
    let color: Color
    let lineHeight: CGFloat

    func makeNSView(context: Context) -> FillView { FillView() }

    func updateNSView(_ view: FillView, context: Context) {
        // Resolved in SwiftUI's environment, so a forced color scheme (the full-screen player's) still applies.
        view.update(fraction: fraction, glide: glide, color: color.resolve(in: context.environment).cgColor, lineHeight: lineHeight)
    }

    final class FillView: NSView {
        private let fill = CALayer()
        private var fraction: Double = 0
        private var lineHeight: CGFloat = 4

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            fill.anchorPoint = CGPoint(x: 0, y: 0.5)
            layer?.addSublayer(fill)
        }

        required init?(coder: NSCoder) { nil }

        // Clicks and drags belong to the slider's SwiftUI gesture.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            place(glide: 0)
        }

        func update(fraction: Double, glide: TimeInterval, color: CGColor, lineHeight: CGFloat) {
            if fill.backgroundColor != color {
                let from = fill.presentation()?.backgroundColor ?? fill.backgroundColor
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                fill.backgroundColor = color
                if let from, window != nil {
                    // The hover and focus color change, as `LineSlider` animates it.
                    let fade = CABasicAnimation(keyPath: "backgroundColor")
                    fade.fromValue = from
                    fade.toValue = color
                    fade.duration = 0.12
                    fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    fill.add(fade, forKey: "color")
                }
                CATransaction.commit()
            }
            guard fraction != self.fraction || lineHeight != self.lineHeight else { return }
            self.fraction = fraction
            self.lineHeight = lineHeight
            place(glide: glide)
        }

        private func place(glide: TimeInterval) {
            let width = max(lineHeight, bounds.width * min(max(fraction, 0), 1))
            let from = fill.presentation()?.bounds.width ?? fill.bounds.width
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fill.bounds = CGRect(x: 0, y: 0, width: width, height: lineHeight)
            fill.position = CGPoint(x: 0, y: bounds.midY)
            fill.cornerRadius = lineHeight / 2
            if glide > 0, window != nil, abs(from - width) > 0.01 {
                let move = CABasicAnimation(keyPath: "bounds.size.width")
                move.fromValue = from
                move.toValue = width
                move.duration = glide
                move.timingFunction = CAMediaTimingFunction(name: .linear)
                fill.add(move, forKey: "glide")
            } else {
                fill.removeAnimation(forKey: "glide")
            }
            CATransaction.commit()
        }
    }
}

extension PlayerController {
    /// The duration to show: the stream's once it reports one, else the track's known length.
    var displayDuration: TimeInterval? {
        if let d = duration, d > 0 { return d }
        return current?.duration
    }

    /// The stream is resolving or refilling: the play button shows a progress ring.
    var isBuffering: Bool { current != nil && (state == .loading || state == .buffering) }
}

/// Elapsed and remaining labels under the full-screen and mini player timelines.
struct TimeLabels: View {
    let current: TimeInterval
    let duration: TimeInterval?
    var size: CGFloat = 11

    var body: some View {
        HStack {
            Text(current.clock)
            Spacer()
            Text("-" + PlaybackClock.remaining(elapsed: current, total: duration).clock)
        }
        .font(.system(size: size, weight: .medium).monospacedDigit())
        .lineLimit(1)
    }
}
