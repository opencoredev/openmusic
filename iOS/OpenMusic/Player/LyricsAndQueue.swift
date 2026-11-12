import OpenMusicCore
import SwiftUI

// MARK: Lyrics

/// Lyrics for the current song. Synced lyrics follow playback and a tap on a line jumps there.
struct LyricsPane: View {
    let track: Track
    @Environment(AppModel.self) private var model
    @State private var phase: LoadPhase<Lyrics?> = .loading

    var body: some View {
        Group {
            switch resolved {
            case .loading:
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let error):
                message(title: "Lyrics Unavailable", detail: error)
            case .loaded(let lyrics?) where !lyrics.lines.isEmpty:
                if lyrics.isSynced {
                    SyncedLyrics(lyrics: lyrics)
                } else {
                    PlainLyrics(lyrics: lyrics)
                }
            case .loaded:
                message(title: "No Lyrics", detail: "Lyrics aren't available for this song.")
            }
        }
        .frame(maxHeight: .infinity)
        .task(id: track.id) {
            if case .loaded = resolved { return }
            do { phase = .loaded(try await model.lyrics(for: track)) } catch is CancellationError {} catch { phase = .failed(error.localizedDescription) }
        }
    }

    private var resolved: LoadPhase<Lyrics?> {
        if case .loading = phase, let hit = model.cachedLyrics(track) { return .loaded(hit) }
        return phase
    }

    private func message(title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "quote.bubble").font(.largeTitle)
            Text(title).font(.title3.bold())
            Text(detail).font(.subheadline).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(0.7))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Synced lyrics. Opening them has to be as cheap as the queue, so:
/// - only `LyricsClock`, a zero-size leaf, watches the playback time; this view updates when the sung line
///   changes, and then only the rows whose look changed (`LyricRow` is equatable);
/// - rows are lazy, so only the lines on screen are laid out and drawn (and blurred: a blur filter on every line
///   of a song was about 60 offscreen passes a frame);
/// - the first position is set before the first frame, without animation, so nothing scrolls while the pane
///   fades in; only later line changes glide.
private struct SyncedLyrics: View {
    let lyrics: Lyrics
    /// Each timed line's index and time, in order, for the clock's lookup.
    private let cues: [LyricCue]
    @Environment(AppModel.self) private var model
    @State private var active: Int?
    /// After the listener scrolls by hand, following the song waits a few seconds.
    @State private var manualScrollAt: Date?
    /// The first line is placed by `onAppear`; its `onChange` must not glide there again during the transition.
    @State private var placedInstantly = false

    init(lyrics: Lyrics) {
        self.lyrics = lyrics
        cues = lyrics.lines.enumerated().compactMap { i, line in line.time.map { LyricCue(index: i, time: $0) } }
    }

    private static let anchor = UnitPoint(x: 0, y: 0.32)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(lyrics.lines.indices, id: \.self) { i in
                        let line = lyrics.lines[i]
                        LyricRow(text: line.text, emphasis: LyricRow.Emphasis(i, active: active),
                                 blur: manualScrollAt == nil ? LyricRow.blur(distance: abs(i - (active ?? 0))) : 0) {
                            if let time = line.time { model.player.seek(to: time); setManualScroll(nil) }
                        }
                        .equatable()
                        .id(i)
                    }
                    if let source = lyrics.source {
                        Text(lyricsCredit(source)).font(.footnote).foregroundStyle(.white.opacity(0.5)).padding(.top, 12)
                    }
                }
                .padding(.vertical, 140)
            }
            .scrollIndicators(.hidden)
            // A fade at each edge: lines leaving at the top dissolve under the header instead of showing cut glyphs.
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 56)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 36)
                }
            }
            .background { LyricsClock(cues: cues, active: $active) }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { setManualScroll(Date()) }
            }
            .onAppear {
                // Read once here, not in `body`: the clock owns the per-tick updates.
                let start = LyricsClock.line(in: cues, at: model.player.currentTime)
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) {
                    // `onChange` runs only when the value changes (it may already be set when the pane reappears).
                    placedInstantly = start != active
                    active = start
                    if let start { proxy.scrollTo(start, anchor: Self.anchor) }
                }
            }
            .onChange(of: active) { _, index in
                if placedInstantly { placedInstantly = false; return }
                guard let index else { return }
                if let manualScrollAt, Date().timeIntervalSince(manualScrollAt) < 4 { return }
                manualScrollAt = nil
                withAnimation(.smooth(duration: 0.6)) { proxy.scrollTo(index, anchor: Self.anchor) }
            }
        }
    }
}

extension SyncedLyrics {
    /// Scrolling by hand sharpens the far lines at once; only a new sung line animates them.
    private func setManualScroll(_ date: Date?) {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { manualScrollAt = date }
    }
}

private struct LyricCue {
    let index: Int
    let time: TimeInterval
}

/// The only lyrics view that reads the playback time. It sets `active` when the sung line changes, so the
/// half-second time tick redraws nothing else.
private struct LyricsClock: View {
    let cues: [LyricCue]
    @Binding var active: Int?
    @Environment(AppModel.self) private var model

    var body: some View {
        let line = Self.line(in: cues, at: model.player.currentTime)
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: line) { _, new in active = new }
    }

    /// The last line whose time has come. A quarter second early, so a line lights as it's sung.
    static func line(in cues: [LyricCue], at time: TimeInterval) -> Int? {
        let now = time + 0.25
        var low = 0, high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].time <= now { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? cues[low - 1].index : nil
    }
}

/// One synced line. Equatable on what it shows, so a new sung line redraws only the rows whose look changes.
/// The dimming is view opacity, not a text color: an animated text color redraws the glyphs on the CPU every frame.
/// Lines blur a little more the further they are from the sung one; rows are lazy, so only the few on screen carry
/// the filter.
private struct LyricRow: View, Equatable {
    enum Emphasis: Equatable {
        case active, sung, upcoming

        init(_ i: Int, active: Int?) {
            guard let active else { self = .upcoming; return }
            self = i == active ? .active : i < active ? .sung : .upcoming
        }

        /// The sung line is white; the others stay at 3:1 or better against the backdrop (Now Playing dims it
        /// further in lyrics mode): sung lines at 50% white, upcoming ones at 56%.
        var opacity: Double {
            switch self {
            case .active: 1
            case .sung: 0.5
            case .upcoming: 0.56
            }
        }
    }

    let text: String
    let emphasis: Emphasis
    let blur: CGFloat
    let seek: () -> Void
    /// Large, like Apple Music's lyrics, and still following Dynamic Type.
    @ScaledMetric(relativeTo: .title) private var size: CGFloat = 30

    /// No blur on the sung line and its neighbours, then a little more per line.
    static func blur(distance: Int) -> CGFloat {
        distance <= 1 ? 0 : min(2.4, CGFloat(distance - 1) * 0.8)
    }

    static func == (a: LyricRow, b: LyricRow) -> Bool { a.text == b.text && a.emphasis == b.emphasis && a.blur == b.blur }

    var body: some View {
        Button(action: seek) {
            Text(text.isEmpty ? "♪" : text)
                .font(.system(size: size, weight: .bold))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.white)
                .opacity(emphasis.opacity)
                .scaleEffect(emphasis == .active ? 1 : 0.95, anchor: .leading)
                .blur(radius: blur)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.45), value: emphasis)
        .animation(.smooth(duration: 0.45), value: blur)
        .accessibilityAddTraits(emphasis == .active ? .isSelected : [])
    }
}

private struct PlainLyrics: View {
    let lyrics: Lyrics

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { _, line in
                    Text(line.text).font(.title3.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                }
                if let source = lyrics.source {
                    Text(lyricsCredit(source)).font(.footnote).foregroundStyle(.white.opacity(0.5)).padding(.top, 12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: Queue

/// Up Next: shuffle, repeat and autoplay, then the queue. Every row has a reorder handle: drag it to move the song
/// (the row lifts on a glass card and the others make room). Tap a row to play it; touch and hold for Play Now,
/// Play Next and Remove.
///
/// Not a `List`: its reorder lifts a snapshot of the cell on an opaque background, a dark slab over this backdrop.
struct QueuePane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        let upNext = Array(player.upNext)
        VStack(spacing: 10) {
            QueueToggles()
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Playing Next").font(.headline).foregroundStyle(.white)
                    if let label = player.sourceLabel {
                        Text(label.replacingOccurrences(of: "Playing from", with: "From"))
                            .font(.subheadline).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Spacer()
                if !upNext.isEmpty {
                    Button("Clear") { withAnimation { _ = player.clearUpNext(includingAutoplay: true) } }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(.top, 4)
            if upNext.isEmpty {
                Text(model.playback.settings.autoplay ? "Autoplay picks similar songs when the queue ends." : "Nothing up next.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ReorderableQueue(entries: upNext)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct ReorderableQueue: View {
    let entries: [QueueEntry]
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The row being dragged, where it is in `entries` now and how far the finger moved. Kept by identity: when the
    /// queue changes mid-drag (playback advances, autoplay adds songs) `from` follows the song, and the drag ends
    /// if the song left Up Next.
    @State private var drag: (uid: UUID, from: Int, dy: CGFloat)?
    /// 58 pt at the default text size, growing with Dynamic Type so two lines of scaled text fit; the reorder math
    /// uses the same height.
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 58

    var body: some View {
        let player = model.player
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.uid) { offset, entry in
                    let lifted = drag?.uid == entry.uid
                    let uid = entry.uid
                    QueueRow(entry: entry, lifted: lifted, divider: offset < entries.count - 1 && !lifted) {
                        handle(entry, at: offset)
                    }
                    .frame(height: rowHeight)
                    .offset(y: lifted ? drag?.dy ?? 0 : shift(for: offset))
                    .zIndex(lifted ? 1 : 0)
                    .contentShape(.rect)
                    .onTapGesture { player.jump(to: uid) }
                    // Every action names the song by its id and finds it when it runs, never by a captured offset.
                    .contextMenu {
                        Button("Play Now", systemImage: "play") { player.jump(to: uid) }
                        if offset > 0 {
                            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                                player.moveUpNext(uid: uid, by: -entries.count)
                            }
                        }
                        Divider()
                        Button("Remove from Queue", systemImage: "minus.circle", role: .destructive) {
                            withAnimation { player.removeUpNext([uid], undoManager: nil) }
                        }
                    }
                    .accessibilityAction(named: "Play Now") { player.jump(to: uid) }
                    .accessibilityAction(named: "Move Up") { player.moveUpNext(uid: uid, by: -1) }
                    .accessibilityAction(named: "Move Down") { player.moveUpNext(uid: uid, by: 1) }
                    .accessibilityAction(named: "Remove from Queue") { player.removeUpNext([uid], undoManager: nil) }
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(drag != nil)
        .contentMargins(.top, 4, for: .scrollContent)
        // Rows fade out at both edges instead of stopping hard at the header or the scrubber.
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 28)
            }
        }
        .sensoryFeedback(.selection, trigger: target)
        .onChange(of: entries.map(\.uid)) { _, uids in
            guard let current = drag else { return }
            if let index = uids.firstIndex(of: current.uid) {
                drag?.from = index
            } else {
                drag = nil
            }
        }
    }

    /// Where the dragged row would land now, in `entries`.
    private var target: Int? {
        guard let drag else { return nil }
        return min(entries.count - 1, max(0, drag.from + places(drag.dy)))
    }

    /// Whole rows the finger has moved.
    private func places(_ dy: CGFloat) -> Int { Int((dy / rowHeight).rounded()) }

    /// Rows between the dragged row's place and its landing place slide over by one row.
    private func shift(for offset: Int) -> CGFloat {
        guard let drag, let target else { return 0 }
        if drag.from < offset, offset <= target { return -rowHeight }
        if target <= offset, offset < drag.from { return rowHeight }
        return 0
    }

    private func handle(_ entry: QueueEntry, at offset: Int) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if drag == nil {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { drag = (entry.uid, offset, 0) }
                }
                guard drag?.uid == entry.uid else { return }
                var transaction = Transaction()
                transaction.animation = reduceMotion ? nil : .interactiveSpring(response: 0.25, dampingFraction: 0.86)
                withTransaction(transaction) { drag?.dy = value.translation.height }
            }
            .onEnded { _ in
                guard let drag, drag.uid == entry.uid else { return }
                let delta = places(drag.dy)
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                    self.drag = nil
                    // By identity and relative to where the song is now (it may have moved since the drag began).
                    if delta != 0 { model.player.moveUpNext(uid: drag.uid, by: delta) }
                }
            }
    }
}

private struct QueueToggles: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        @Bindable var settings = model.playback.settings
        HStack(spacing: 10) {
            toggle("Shuffle", symbol: "shuffle", isOn: player.shuffle) { player.shuffle.toggle() }
            toggle(repeatLabel, symbol: player.repeatMode == .one ? "repeat.1" : "repeat", isOn: player.repeatMode != .off) {
                player.repeatMode = player.repeatMode.next
            }
            toggle("Autoplay", symbol: "infinity", isOn: settings.autoplay) { settings.autoplay.toggle() }
        }
    }

    private var repeatLabel: String {
        switch model.player.repeatMode {
        case .off: "Repeat"
        case .all: "Repeat All"
        case .one: "Repeat One"
        }
    }

    private func toggle(_ title: String, symbol: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 34)
                .foregroundStyle(isOn ? Color.black : Color.white)
                .background(isOn ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.white.opacity(0.14)), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .sensoryFeedback(.selection, trigger: isOn)
    }
}

private struct QueueRow<Handle: Gesture>: View {
    let entry: QueueEntry
    var lifted = false
    var divider = true
    let handle: () -> Handle

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(artwork: entry.track.artwork, points: 44)
                .frame(width: 44, height: 44)
                .clipShape(.rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.track.title).foregroundStyle(.white).lineLimit(1)
                Text(entry.track.artistLine).font(.subheadline).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 0)
            if entry.isAutoplay {
                Image(systemName: "infinity").font(.caption).foregroundStyle(.white.opacity(0.5)).accessibilityLabel("Autoplay")
            }
            Image(systemName: "line.3.horizontal")
                .font(.body.weight(.medium))
                .foregroundStyle(.white.opacity(lifted ? 0.9 : 0.45))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
                .gesture(handle())
                .accessibilityHidden(true)
        }
        // The lifted card reaches 10 pt past the row on each side, so the row's content doesn't move when lifted.
        .padding(.horizontal, 10)
        .background {
            if lifted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.12))
                    .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5) }
                    .shadow(color: .black.opacity(0.28), radius: 14, y: 8)
                    .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, -10)
        .overlay(alignment: .bottom) {
            if divider {
                Rectangle().fill(.white.opacity(0.15)).frame(height: 0.5).padding(.leading, 56)
            }
        }
        .scaleEffect(lifted ? 1.03 : 1)
        .accessibilityElement(children: .combine)
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
}

/// "Lyrics from LRCLIB", or the provider's own credit line as given ("Source: LyricFind").
func lyricsCredit(_ source: String) -> String {
    source.lowercased().hasPrefix("source") ? source : "Lyrics from \(source)"
}
