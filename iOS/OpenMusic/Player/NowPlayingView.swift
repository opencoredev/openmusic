import AVKit
import MediaPlayer
import OpenMusicCore
import SwiftUI

/// Full-screen Now Playing: artwork over a backdrop sampled from it, scrubber, transport, system volume, AirPlay,
/// and two modes that swap the artwork for synced lyrics or the Up Next queue. Always dark, like Apple Music.
struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Namespace private var art
    /// The colors sampled for the song on show. Nil until the first sample of this presentation.
    @State private var palette: ArtworkPalette?

    var body: some View {
        let player = model.player
        ZStack {
            // Reopening for a song already sampled starts on its colors, not a fade from gray over the zoom.
            Backdrop(palette: palette ?? ArtworkPalette.cached(player.current?.artwork) ?? .neutral,
                     dimmed: model.nowPlayingMode == .lyrics)
            if let track = player.current {
                VStack(spacing: 0) {
                    grabber
                    switch model.nowPlayingMode {
                    case .artwork:
                        BigArtwork(track: track, isPlaying: player.isPlaying, namespace: art)
                            .frame(maxHeight: .infinity)
                        TitleRow(track: track, large: true)
                            .padding(.bottom, 18)
                    case .lyrics:
                        CompactHeader(track: track, namespace: art)
                        LyricsPane(track: track).id(track.id)
                    case .queue:
                        CompactHeader(track: track, namespace: art)
                        QueuePane()
                    }
                    Controls()
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 8)
            } else {
                ContentUnavailableView("Not Playing", systemImage: "music.note")
                    .onAppear { dismiss() }
            }
        }
        .preferredColorScheme(.dark)
        .foregroundStyle(.white)
        .tint(.white)
        .task(id: player.current?.id) {
            guard let track = player.current else { return }
            async let liked: Void = model.checkLiked(track)
            // Ready before Lyrics or Playing Next is tapped: the lyrics, and the small artwork the header flies to.
            async let lyrics: Void = model.prefetchLyrics(track)
            async let header: Void = CompactHeader.prepare(track, scale: displayScale)
            if let sampled = await ArtworkPalette.load(track.artwork) {
                if palette == nil, ArtworkPalette.cached(track.artwork) == sampled {
                    palette = sampled
                } else {
                    withAnimation(.easeInOut(duration: 0.6)) { palette = sampled }
                }
                ArtworkPalette.remember(sampled, for: track.artwork)
            }
            _ = await (liked, lyrics, header)
        }
        .accessibilityAction(.escape) { dismiss() }
    }

    /// The grabber (a tap closes, as does a swipe down) and where the music plays from, on up to two centered
    /// lines without the "Playing from" prefix. One close cue: no separate chevron.
    private var grabber: some View {
        VStack(spacing: 5) {
            Button { dismiss() } label: {
                Capsule().fill(.white.opacity(0.35)).frame(width: 38, height: 5)
                    .frame(width: 120, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            // A 44 pt target that takes 18 pt of layout, so the source line stays tucked under the grabber.
            .padding(.vertical, -13)
            .accessibilityLabel("Close Now Playing")
            if let label = model.player.sourceLabel {
                Text(Self.sourceTitle(label))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 24)
                    .accessibilityLabel(label)
            }
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 44, alignment: .top)
    }

    /// "Playing from Discovery" → "Discovery"; "Autoplay" stays.
    static func sourceTitle(_ label: String) -> String {
        let prefix = "Playing from "
        return label.hasPrefix(prefix) ? String(label.dropFirst(prefix.count)) : label
    }
}

// MARK: Backdrop

private struct Backdrop: View {
    let palette: ArtworkPalette
    /// Lyrics put a lot of white text on the backdrop; a darker one keeps the inactive lines at 3:1 or better
    /// even under light artwork.
    var dimmed = false

    var body: some View {
        ZStack {
            // The cover's colors where they sit on the cover, blended: a still mesh, so a paused player draws nothing.
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.5, 0.5], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ], colors: palette.colors)
            // A soft vignette keeps controls readable whatever the artwork.
            LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.32)], startPoint: .top, endPoint: .bottom)
            Color.black.opacity(dimmed ? 0.22 : 0)
        }
        .animation(.easeInOut(duration: 0.4), value: dimmed)
        .ignoresSafeArea()
    }
}

// MARK: Artwork and title

private struct BigArtwork: View {
    let track: Track
    let isPlaying: Bool
    let namespace: Namespace.ID

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ArtworkView(artwork: track.artwork, points: side)
                .frame(width: side, height: side)
                .clipShape(.rect(cornerRadius: 12))
                .matchedGeometryEffect(id: "art", in: namespace)
                .shadow(color: .black.opacity(0.35), radius: isPlaying ? 24 : 10, y: isPlaying ? 16 : 6)
                .scaleEffect(isPlaying ? 1 : 0.82)
                .animation(.spring(response: 0.45, dampingFraction: 0.72), value: isPlaying)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Artwork for \(track.title)")
        }
        .padding(.vertical, 16)
    }
}

private struct CompactHeader: View {
    let track: Track
    let namespace: Namespace.ID
    @Environment(AppModel.self) private var model

    static let artworkPoints: CGFloat = 60

    /// Decodes the header's artwork into the memory cache, so it is drawn on the first frame of the move from the
    /// big artwork instead of a placeholder.
    static func prepare(_ track: Track, scale: CGFloat) async {
        let pixels = Int(artworkPoints * scale)
        guard let url = track.artwork?.url(minPixels: pixels) else { return }
        _ = await ArtworkPipeline.shared.load(url, pixels: pixels)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button { withAnimation(.smooth(duration: 0.4)) { model.nowPlayingMode = .artwork } } label: {
                ArtworkView(artwork: track.artwork, points: Self.artworkPoints)
                    .frame(width: 60, height: 60)
                    .clipShape(.rect(cornerRadius: 6))
                    .matchedGeometryEffect(id: "art", in: namespace)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show Artwork")
            TitleRow(track: track, large: false)
        }
        .padding(.vertical, 12)
    }
}

private struct TitleRow: View {
    let track: Track
    let large: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(text: track.title, font: large ? .title3.bold() : .headline)
                Button { model.goToArtist(track) } label: {
                    Text(track.artistLine)
                        .font(large ? .title3 : .subheadline)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.canLike(track) {
                let liked = model.isLiked(track)
                Button { model.toggleLike(track) } label: {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .font(.system(size: 22, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(PressScale())
                .foregroundStyle(.white.opacity(liked ? 1 : 0.85))
                .sensoryFeedback(.selection, trigger: liked)
                .accessibilityLabel(liked ? "Unlike" : "Like")
            }
            // Plain symbols, lighter than the title: circles are kept for the active Lyrics / Playing Next button.
            Menu {
                TrackMenu(track: track)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .foregroundStyle(.white.opacity(0.85))
            .accessibilityLabel("More")
        }
    }
}

/// One line that scrolls when it doesn't fit, like Apple Music's Now Playing title: it rests for a moment, glides
/// to show the rest, then starts over. With Reduce Motion it wraps to two lines instead.
struct MarqueeText: View {
    let text: String
    let font: Font
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private let gap: CGFloat = 40
    private let speed: CGFloat = 30 // points per second

    var body: some View {
        let overflows = textWidth > boxWidth + 1 && boxWidth > 0
        if reduceMotion {
            Text(text).font(font).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // A hidden one-line copy sets the height and the box width.
            Text(text).font(font).lineLimit(1).hidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
                .overlay(alignment: .leading) {
                    HStack(spacing: gap) {
                        label.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                        if overflows { label }
                    }
                    .offset(x: offset)
                    .frame(width: boxWidth, alignment: .leading)
                    .clipped()
                    .mask {
                        HStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                                .frame(width: overflows && offset < 0 ? 12 : 0)
                            Rectangle()
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: overflows ? 16 : 0)
                        }
                    }
                }
                .task(id: "\(text)|\(overflows)|\(Int(textWidth))") { await scroll(overflows) }
                .accessibilityElement()
                .accessibilityLabel(text)
        }
    }

    private var label: some View {
        Text(text).font(font).lineLimit(1).fixedSize()
    }

    private func scroll(_ overflows: Bool) async {
        offset = 0
        guard overflows else { return }
        let distance = textWidth + gap
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: distance / speed)) { offset = -distance }
            try? await Task.sleep(for: .seconds(distance / speed))
            guard !Task.isCancelled else { return }
            offset = 0
        }
    }
}

// MARK: Controls

private struct Controls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Scrubber()
            Transport()
            VolumeRow()
            BottomBar()
        }
    }
}

struct Scrubber: View {
    @Environment(AppModel.self) private var model
    @State private var dragFraction: Double?

    var body: some View {
        let player = model.player
        let duration = player.duration ?? player.current?.duration ?? 0
        let fraction = dragFraction ?? (duration > 0 ? min(1, max(0, player.currentTime / duration)) : 0)
        let elapsed = fraction * duration
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white.opacity(dragFraction == nil ? 0.7 : 1))
                        .frame(width: max(0, geo.size.width * fraction))
                }
                .frame(height: dragFraction == nil ? 7 : 12)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }
                            dragFraction = min(1, max(0, value.location.x / geo.size.width))
                        }
                        .onEnded { value in
                            guard duration > 0 else { return }
                            let f = min(1, max(0, value.location.x / geo.size.width))
                            player.seek(to: f * duration)
                            dragFraction = nil
                        }
                )
            }
            .frame(height: 22)
            HStack {
                Text(Self.format(elapsed))
                Spacer()
                Text("-" + Self.format(PlaybackClock.remaining(elapsed: elapsed, total: duration)))
            }
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
            .scaleEffect(dragFraction == nil ? 1 : 1.04)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: dragFraction == nil)
        .sensoryFeedback(.selection, trigger: dragFraction == nil)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(Self.format(elapsed)) of \(Self.format(duration))")
        .accessibilityAdjustableAction { direction in
            let step: TimeInterval = direction == .increment ? 10 : -10
            player.seek(to: min(duration, max(0, player.currentTime + step)))
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct Transport: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        HStack {
            Spacer()
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 32))
            }
            .accessibilityLabel("Previous")
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 48))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 72, height: 64)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .overlay {
                if player.state == .loading || player.state == .buffering {
                    ProgressView().tint(.white).offset(y: 44).accessibilityHidden(true)
                }
            }
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 32))
            }
            .accessibilityLabel("Next")
            Spacer()
        }
        .buttonStyle(PressScale())
        .sensoryFeedback(.impact(weight: .medium), trigger: player.isPlaying)
        .padding(.vertical, 4)
    }
}

/// Shrinks a control while pressed, like the system transport buttons.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(.rect)
    }
}

private struct VolumeRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").font(.caption)
            SystemVolumeSlider().frame(height: 34)
            Image(systemName: "speaker.wave.3.fill").font(.caption)
        }
        .foregroundStyle(.white.opacity(0.6))
        .accessibilityElement(children: .contain)
    }
}

private struct BottomBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            modeButton(.lyrics, symbol: "quote.bubble", activeSymbol: "quote.bubble.fill", label: "Lyrics")
                .disabled(!(model.player.current.map { model.can(.lyrics, $0.provider) } ?? false))
            Spacer()
            RoutePicker()
                .frame(width: 44, height: 44)
                .accessibilityLabel("AirPlay")
            if let accessory = model.extensions.nowPlayingAccessory {
                Spacer()
                accessory
            }
            Spacer()
            modeButton(.queue, symbol: "list.bullet", activeSymbol: "list.bullet", label: "Playing Next")
        }
        .padding(.horizontal, 12)
    }

    private func modeButton(_ mode: NowPlayingMode, symbol: String, activeSymbol: String, label: String) -> some View {
        let active = model.nowPlayingMode == mode
        return Button {
            withAnimation(.smooth(duration: 0.4)) { model.nowPlayingMode = active ? .artwork : mode }
        } label: {
            Image(systemName: active ? activeSymbol : symbol)
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(active ? AnyShapeStyle(.white.opacity(0.18)) : AnyShapeStyle(.clear), in: .circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(active ? 1 : 0.7))
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: active)
    }
}

// MARK: System views

/// The system volume slider (hardware buttons and Control Center move it too).
private struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.tintColor = .white
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

/// AirPlay and Bluetooth output picker.
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor.white.withAlphaComponent(0.7)
        view.activeTintColor = .white
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
