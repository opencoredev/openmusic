import CoreTransferable
import MedleyCore
import SwiftUI
import UniformTypeIdentifiers

/// "Playing Next": the current song, the user's queue, autoplay suggestions, and history.
struct QueuePanel: View {
    /// What the header's close button does. The window's inspector by default; the full-screen player closes its own panel.
    var close: (() -> Void)? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.showsServiceMarks) private var showsMarks
    @Environment(\.queueMetrics) private var metrics
    @State private var showsHistory = false

    /// Rows carry their service's glyph only when the list mixes services; a queue that is all one service (an
    /// album, a playlist) would repeat the same mark on every row.
    private var listMixesServices: Bool {
        let player = model.player
        return showsHistory ? ProviderID.sole(player.listeningHistory.lazy.map(\.track.provider)) == nil
            : ProviderID.sole(player.queue.lazy.map(\.track.provider)) == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: showsHistory ? "History" : "Playing Next", titleSize: metrics.headerSize, topInset: metrics.headerTop) {
                Button { showsHistory.toggle() } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(IconButtonStyle(tint: showsHistory ? .accentColor : .secondary))
                .help(showsHistory ? "Show Playing Next" : "Show History")
                .accessibilityLabel("History")
                .accessibilityAddTraits(showsHistory ? .isSelected : [])
            } close: {
                if let close { close() } else { model.inspector = nil }
            }

            Group {
                if showsHistory {
                    HistoryList()
                } else {
                    UpNextList()
                }
            }
            .environment(\.showsServiceMarks, showsMarks && listMixesServices)
        }
    }
}

// MARK: - Sizes

/// Playing Next's type and artwork sizes: the inspector's, or the full-screen player's larger ones (set by
/// `FullScreenPanelContent`), where the rows sit beside 500 pt artwork and 34 pt lyrics.
struct QueueMetrics: Equatable {
    var headerSize: CGFloat
    var headerTop: CGFloat
    var sectionSize: CGFloat
    var titleSize: CGFloat
    var artistSize: CGFloat
    var artwork: CGFloat
    var lineSpacing: CGFloat

    static let inspector = QueueMetrics(headerSize: 15, headerTop: 10, sectionSize: 12, titleSize: 13, artistSize: 12, artwork: 40, lineSpacing: 1)
    /// The header's text starts level with the artwork's top edge beside it (`QueueBesideArtworkLayout`).
    static let fullScreen = QueueMetrics(headerSize: 22, headerTop: 0, sectionSize: 13, titleSize: 15, artistSize: 13, artwork: 48, lineSpacing: 2)
}

extension EnvironmentValues {
    @Entry var queueMetrics: QueueMetrics = .inspector
}

// MARK: - Up Next

/// Which group a row belongs to. Rows reorder within their group: the songs you queued or played from,
/// and the songs autoplay added after them.
private enum QueueGroup: Hashable { case upNext, autoplay }

/// A row being dragged and where it would land.
///
/// Reordering uses a plain drag gesture rather than a system drag session: the row follows the pointer,
/// an insertion line shows the drop position, and releasing commits. It needs no pasteboard and works the
/// same for a mouse, a trackpad or an automated pointer.
private struct QueueDrag: Equatable {
    var uid: UUID
    var group: QueueGroup
    var from: Int
    var translation: CGFloat
    /// Insert before this row offset within the group (`count` means after the last row).
    var slot: Int
}

/// A selectable row in Playing Next: the song that's playing, or a queued entry.
private enum QueueKey: Hashable {
    case current
    case entry(UUID)
}

private struct UpNextList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.undoManager) private var undoManager
    @State private var drag: QueueDrag?
    /// Row frames in the list's coordinate space, for finding the drop slot.
    @State private var frames: [UUID: CGRect] = [:]
    @State private var selection: QueueKey?
    @State private var cursor: QueueKey?
    /// The cursor's outline shows for keyboard focus only (`KeyboardCursorTracking`).
    @State private var keyboardCursor = false
    @FocusState private var focused: Bool
    /// Where songs dragged in from elsewhere would land, while they hover the list.
    @State private var dropTarget: AppModel.QueueDrop?

    /// Queue positions of the songs queued by the listener and of those autoplay added, in play order.
    private var groups: (user: [Int], auto: [Int]) {
        let player = model.player
        let base = player.upNextStartIndex
        let upNext = Array(player.upNext)
        return (upNext.indices.filter { !upNext[$0].isAutoplay }.map { $0 + base },
                upNext.indices.filter { upNext[$0].isAutoplay }.map { $0 + base })
    }

    var body: some View {
        let player = model.player
        let upNext = Array(player.upNext)
        let (userIdx, autoIdx) = groups
        // Keyboard order: the current song, then Up Next, then Autoplay, as drawn.
        let keys = (player.current == nil ? [] : [QueueKey.current])
            + (userIdx + autoIdx).compactMap { player.queue.indices.contains($0) ? QueueKey.entry(player.queue[$0].uid) : nil }
        let focusCursor = focused && keyboardCursor && selection == nil ? QueueFocus.cursorKey(cursor, in: keys) : nil

        if player.current == nil, upNext.isEmpty {
            EmptyStateView(symbol: "list.bullet", title: "Nothing queued", message: "Songs you play or add to the queue show up here.")
        } else {
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let current = player.current {
                        QueueSectionHeader(title: "Now Playing") {
                            EmptyView()
                        } subtitle: {
                            if let from = model.playingFrom {
                                Button {
                                    if let route = from.route { model.open(route) }
                                } label: {
                                    Text("Playing from \(from.title)").lineLimit(1)
                                }
                                .buttonStyle(SubtleLinkStyle(readable: true))
                                .font(.caption)
                                .disabled(from.route == nil)
                            }
                        }
                        QueueRow(track: current, isCurrent: true, isSelected: selection == .current, listFocused: focused,
                                 isFocusCursor: focusCursor == .current)
                            .padding(.horizontal, 8)
                            .id(QueueKey.current)
                            .simultaneousGesture(TapGesture().onEnded { select(.current) })
                    }

                    QueueSectionHeader(title: "Up Next") {
                        // Clears this group only; Autoplay's songs stay. Undo (⌘Z) puts the songs back.
                        if !userIdx.isEmpty {
                            Button("Clear") { player.clearUpNext(undoManager: undoManager) }
                                .buttonStyle(SubtleLinkStyle(readable: true))
                                .font(.callout)
                                .help("Clear Up Next (Autoplay stays; Undo restores)")
                                .accessibilityLabel("Clear Up Next")
                                .modifier(LayoutProbe(key: "queue-clear"))
                        }
                    }
                    .padding(.top, 10)
                    if userIdx.isEmpty {
                        // Wraps to the column instead of sizing it: without the flexible frame its one-line ideal
                        // width fed the panel's width, which narrowed to 270 pt once Clear emptied Up Next.
                        Text("Add songs with Play Next or Add to Queue, or drag them here.")
                            .font(.callout)
                            .foregroundStyle(.readableSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, PanelMetrics.leadingInset)
                            .padding(.vertical, 6)
                            .overlay(alignment: .top) { if dropTarget != nil { InsertionLine().padding(.horizontal, 8).offset(y: -1) } }
                    }
                    rows(userIdx, group: .upNext, focusCursor: focusCursor)

                    QueueSectionHeader(title: "Autoplay") {
                        Toggle("Autoplay", isOn: Bindable(model.playback.settings).autoplay)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                    } subtitle: {
                        Text(player.autoplay ? "Similar music keeps playing" : "Off")
                            .font(.caption)
                            .foregroundStyle(.readableSecondary)
                    }
                    .padding(.top, 14)
                    rows(autoIdx, group: .autoplay, focusCursor: focusCursor)
                }
                .padding(.bottom, 16)
                .coordinateSpace(.named(QueueSpace.name))
                .onPreferenceChange(QueueRowFrames.self) { frames = $0 }
                // Songs, albums, playlists or artists dragged in from a page or the sidebar: above Up Next they play
                // next, anywhere below they join the end of Up Next. The insertion line shows which.
                .onDrop(of: [.medleyItem], delegate: QueueDropDelegate(
                    target: $dropTarget,
                    position: { y in dropPosition(at: y) },
                    perform: { items, position in model.dropOnQueue(items, at: position) }
                ))
                .modifier(DropPreviewProbe { key in
                    dropTarget = key == "queue:playNext" ? .playNext : key == "queue:addToQueue" ? .addToQueue : nil
                })
                .modifier(QueueKeyboard(
                    keys: keys, selection: $selection, cursor: $cursor, cursorVisible: $keyboardCursor, focused: $focused, isFocused: focused, probe: "queue-list",
                    reveal: { key in
                        switch key {
                        case .current: proxy.scrollTo(QueueKey.current)
                        case .entry(let uid): proxy.scrollTo(uid)
                        }
                    },
                    activate: activate,
                    remove: { key in
                        guard case .entry(let uid) = key else { return false }
                        // Undoable (Edit › Undo Remove “<song>”): the entry comes back in its place, playback untouched.
                        model.player.removeUpNext([uid], undoManager: undoManager)
                        return true
                    },
                    reorder: { key, delta in reorder(key, by: delta) }
                ))
            }
            .scrollIndicators(.automatic)
            .modifier(LayoutProbe(key: "queue-content"))
            }
        }
    }

    private func select(_ key: QueueKey) {
        selection = key
        focused = true
    }

    /// Above the middle of the first Up Next row (the current song, the heading): Play Next. Lower: Add to Queue.
    private func dropPosition(at y: CGFloat) -> AppModel.QueueDrop {
        let queue = model.player.queue
        guard let first = groups.user.first, queue.indices.contains(first), let frame = frames[queue[first].uid] else { return .playNext }
        return y < frame.midY ? .playNext : .addToQueue
    }

    /// Return and double-click: jump to a queued song; on the song that's playing, resume it if paused.
    private func activate(_ key: QueueKey) {
        switch key {
        case .current:
            if !model.player.isPlaying { model.resume() }
        case .entry(let uid):
            model.jump(to: uid)
            // The song is now the one playing: keep it selected there.
            selection = .current
        }
    }

    /// ⌥⌘↑ / ⌥⌘↓: moves the selected entry one place within its group. False when it can't move that way.
    private func reorder(_ key: QueueKey, by delta: Int) -> Bool {
        guard case .entry(let uid) = key else { return false }
        let queue = model.player.queue
        let (userIdx, autoIdx) = groups
        for indices in [userIdx, autoIdx] {
            guard let offset = indices.firstIndex(where: { queue.indices.contains($0) && queue[$0].uid == uid }) else { continue }
            let target = offset + delta
            guard indices.indices.contains(target) else { return false }
            move(offset, to: delta < 0 ? target : target + 1, within: indices)
            return true
        }
        return false
    }

    @ViewBuilder
    private func rows(_ indices: [Int], group: QueueGroup, focusCursor: QueueKey?) -> some View {
        let queue = model.player.queue
        let entries = indices.compactMap { queue.indices.contains($0) ? queue[$0] : nil }
        ForEach(Array(entries.enumerated()), id: \.element.uid) { offset, entry in
            QueueDragRow(
                entry: entry, group: group, offset: offset, count: entries.count,
                drag: drag?.group == group ? drag : nil,
                dropLine: group != .upNext ? nil
                    : dropTarget == .playNext && offset == 0 ? .top
                    : dropTarget == .addToQueue && offset == entries.count - 1 ? .bottom : nil,
                isSelected: selection == .entry(entry.uid), listFocused: focused,
                isFocusCursor: focusCursor == .entry(entry.uid),
                select: { select(.entry(entry.uid)) },
                onChanged: { y, dy in
                    drag = QueueDrag(uid: entry.uid, group: group, from: offset, translation: dy, slot: slot(at: y, in: entries))
                },
                onEnded: {
                    if let d = drag, d.uid == entry.uid { move(d.from, to: d.slot, within: indices) }
                    drag = nil
                },
                move: { to in move(offset, to: to, within: indices) }
            )
        }
    }

    /// The row offset the pointer is above (insert before it), or `count` below the last row.
    private func slot(at y: CGFloat, in entries: [QueueEntry]) -> Int {
        for (i, entry) in entries.enumerated() {
            if let f = frames[entry.uid], y < f.midY { return i }
        }
        return entries.count
    }

    /// Moves the row at `from` (an offset within the group) so it lands before `to`.
    private func move(_ from: Int, to: Int, within indices: [Int]) {
        guard indices.indices.contains(from), to != from, to != from + 1, to >= 0, to <= indices.count else { return }
        let source = IndexSet(integer: indices[from])
        let destination = to < indices.count ? indices[to] : (indices.last ?? 0) + 1
        if reduceMotion {
            model.player.move(fromOffsets: source, toOffset: destination)
        } else {
            withAnimation(.snappy(duration: 0.2)) { model.player.move(fromOffsets: source, toOffset: destination) }
        }
    }
}

/// One reorderable row: reports its frame, follows the pointer while dragged, and draws the insertion line.
private struct QueueDragRow: View {
    let entry: QueueEntry
    let group: QueueGroup
    let offset: Int
    let count: Int
    /// The drag in this row's group, if any.
    let drag: QueueDrag?
    /// Songs dragged in from elsewhere would land above (Play Next) or below (Add to Queue) this row.
    var dropLine: VerticalEdge? = nil
    let isSelected: Bool
    let listFocused: Bool
    let isFocusCursor: Bool
    let select: () -> Void
    let onChanged: (_ y: CGFloat, _ translation: CGFloat) -> Void
    let onEnded: () -> Void
    let move: (Int) -> Void

    var body: some View {
        let isDragged = drag?.uid == entry.uid
        QueueRow(entry: entry,
                 moveUp: offset > 0 ? { move(offset - 1) } : nil,
                 moveDown: offset < count - 1 ? { move(offset + 2) } : nil,
                 isLifted: isDragged, isSelected: isSelected, listFocused: listFocused, isFocusCursor: isFocusCursor)
            .padding(.horizontal, 8)
            .modifier(LayoutProbe(key: "queue-row-\(group)-\(offset)"))
            .simultaneousGesture(TapGesture().onEnded { select() })
            .background { frameReporter }
            .offset(y: isDragged ? drag?.translation ?? 0 : 0)
            .zIndex(isDragged ? 1 : 0)
            .overlay(alignment: .top) { if showsLineAbove || dropLine == .top { InsertionLine().offset(y: -1) } }
            .overlay(alignment: .bottom) { if showsLineBelow || dropLine == .bottom { InsertionLine().offset(y: 1) } }
            .gesture(gesture)
    }

    private var frameReporter: some View {
        GeometryReader { geo in
            Color.clear.preference(key: QueueRowFrames.self, value: [entry.uid: geo.frame(in: .named(QueueSpace.name))])
        }
    }

    /// A drop that would leave the row where it is shows no line.
    private var isRealMove: Bool {
        guard let drag else { return false }
        return drag.slot != drag.from && drag.slot != drag.from + 1
    }

    private var showsLineAbove: Bool { isRealMove && drag?.slot == offset }
    private var showsLineBelow: Bool { isRealMove && offset == count - 1 && drag?.slot == count }

    private var gesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(QueueSpace.name))
            .onChanged { g in onChanged(g.location.y, g.translation.height) }
            .onEnded { _ in onEnded() }
    }
}

private enum QueueSpace { static let name = "queue-list" }

/// A drag from elsewhere over Playing Next: follows the pointer to say where it would land (a state write only when
/// that changes), and on release loads the dragged items and hands them over.
private struct QueueDropDelegate: DropDelegate {
    @Binding var target: AppModel.QueueDrop?
    let position: (CGFloat) -> AppModel.QueueDrop
    let perform: ([MediaDragItem], AppModel.QueueDrop) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.medleyItem]) }

    func dropEntered(info: DropInfo) { update(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) { target = nil }

    func performDrop(info: DropInfo) -> Bool {
        let where_ = position(info.location.y)
        target = nil
        let providers = info.itemProviders(for: [.medleyItem])
        guard !providers.isEmpty else { return false }
        if LayoutProbe.enabled { DebugProbes.note("queue-drop", "\(providers.count) at \(where_ == .playNext ? "Play Next" : "Add to Queue")") }
        Task { @MainActor in
            var items: [MediaDragItem] = []
            for provider in providers {
                if let item = await Self.load(provider) { items.append(item) }
            }
            perform(items, where_)
        }
        return true
    }

    private func update(_ info: DropInfo) {
        let next = position(info.location.y)
        if target != next { target = next }
    }

    private static func load(_ provider: NSItemProvider) async -> MediaDragItem? {
        await withCheckedContinuation { continuation in
            _ = provider.loadTransferable(type: MediaDragItem.self) { result in
                continuation.resume(returning: try? result.get())
            }
        }
    }
}

private struct QueueRowFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The drop position: an accent-colored line with a small ring at its leading end, like Finder's lists.
private struct InsertionLine: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle().strokeBorder(Color.accentColor, lineWidth: 2).frame(width: 8, height: 8)
            Rectangle().fill(Color.accentColor).frame(height: 2)
        }
        .padding(.horizontal, 10)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct QueueSectionHeader<Trailing: View, Subtitle: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var subtitle: Subtitle
    @Environment(\.queueMetrics) private var metrics

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: metrics.sectionSize, weight: .semibold))
                    .foregroundStyle(.readableSecondary)
                    .accessibilityAddTraits(.isHeader)
                subtitle
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, PanelMetrics.leadingInset)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}

extension QueueSectionHeader where Subtitle == EmptyView {
    init(title: String, @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, trailing: trailing, subtitle: { EmptyView() })
    }
}

// MARK: - History

/// Songs the listener actually heard (`PlayerController.listeningHistory`), newest first. Not the queue's
/// earlier entries: starting an album at its fifth song doesn't put the first four here.
private struct HistoryList: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?
    @State private var cursor: String?
    /// The cursor's outline shows for keyboard focus only (`KeyboardCursorTracking`).
    @State private var keyboardCursor = false
    @FocusState private var focused: Bool

    var body: some View {
        let history = Array(model.player.listeningHistory)
        let keys = history.map(\.id)
        let focusCursor = focused && keyboardCursor && selection == nil ? QueueFocus.cursorKey(cursor, in: keys) : nil
        if history.isEmpty {
            EmptyStateView(symbol: "clock.arrow.circlepath", title: "No history yet", message: "Songs you listen to for 30 seconds show up here.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        QueueSectionHeader(title: "Recently Played") { EmptyView() }
                        ForEach(history) { played in
                            QueueRow(played: played, isSelected: selection == played.id, listFocused: focused,
                                     isFocusCursor: focusCursor == played.id)
                                .padding(.horizontal, 8)
                                .simultaneousGesture(TapGesture().onEnded {
                                    selection = played.id
                                    focused = true
                                })
                        }
                    }
                    .padding(.bottom, 16)
                    .modifier(QueueKeyboard(
                        keys: keys, selection: $selection, cursor: $cursor, cursorVisible: $keyboardCursor, focused: $focused, isFocused: focused, probe: "history-list",
                        reveal: { proxy.scrollTo($0) },
                        activate: { id in
                            if let played = history.first(where: { $0.id == id }) { model.playNow(played.track, from: played.context) }
                        }
                    ))
                }
            }
        }
    }
}

// MARK: - Keyboard

enum QueueFocus {
    /// The row that shows keyboard focus while nothing is selected: the cursor while it's still in the list, else the first row.
    static func cursorKey<Key: Hashable>(_ cursor: Key?, in keys: [Key]) -> Key? {
        if let cursor, keys.contains(cursor) { return cursor }
        return keys.first
    }

    /// Where the cursor goes when its row leaves the list: the row now at its old position (the next one), or the
    /// last row when it was at the end. Nil when the list is empty.
    static func relocated<Key: Hashable>(_ cursor: Key?, from old: [Key], to new: [Key]) -> Key? {
        guard let cursor else { return nil }
        if new.contains(cursor) { return cursor }
        guard !new.isEmpty, let index = old.firstIndex(of: cursor) else { return nil }
        // Rows before it that also left shift it up.
        let gone = old[..<index].filter { !new.contains($0) }.count
        return new[min(index - gone, new.count - 1)]
    }
}

/// List-style keyboard handling for the queue and History, like the track tables: the list takes focus when a row is
/// clicked (or by Tab); ↑/↓ move the selection and scroll it into view, Return plays it, Delete removes it, ⌥⌘↑/↓
/// move it, Escape clears it. The rows draw the selection, solid accent while the list has focus.
///
/// Focus stays visible without a selection: the cursor (the row last selected, else the first row) gets an accent
/// outline while the list has focus and nothing is selected (Tab into it, Escape, the selected song played or removed),
/// and ↑/↓ select it before moving on. Only keyboard focus draws it (`KeyboardCursorTracking`): a click on Clear or
/// the header that focuses the list leaves no outline.
private struct QueueKeyboard<Key: Hashable>: ViewModifier {
    let keys: [Key]
    @Binding var selection: Key?
    @Binding var cursor: Key?
    /// Whether the cursor's outline shows: keyboard focus only (`KeyboardCursorTracking`).
    @Binding var cursorVisible: Bool
    let focused: FocusState<Bool>.Binding
    /// The list's focus as the parent read it. A change to it re-renders this modifier, where the binding alone doesn't.
    let isFocused: Bool
    /// A name for `DebugProbes` notes (council captures).
    var probe = "queue"
    let reveal: (Key) -> Void
    let activate: (Key) -> Void
    /// Removes the row; false when it can't be removed (the song that's playing).
    var remove: ((Key) -> Bool)? = nil
    /// Moves the row up (-1) or down (+1); false when it can't move that way.
    var reorder: ((Key, Int) -> Bool)? = nil
    @Environment(AppModel.self) private var model

    private func space() { SpaceFallback.toggle(model, from: probe) }

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused(focused)
            // The rows draw focus: the accent selection, or the cursor row's outline when nothing is selected.
            .focusEffectDisabled()
            .modifier(KeyboardCursorTracking(isFocused: isFocused, selection: selection, visible: $cursorVisible))
            .onChange(of: cursorVisible) { note() }
            .onChange(of: isFocused) {
                // Keyboard entry (Tab) lands on the cursor row: bring it into view. A click selects first, so it doesn't scroll.
                if isFocused, selection == nil, let key = QueueFocus.cursorKey(cursor, in: keys) { reveal(key) }
                note()
            }
            .onChange(of: selection) {
                if let selection { cursor = selection }
                note()
            }
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                let modifiers = press.modifiers.intersection([.command, .option, .control, .shift])
                let delta = press.key == .upArrow ? -1 : 1
                if modifiers == [.command, .option] {
                    guard let selection, let reorder else { return .ignored }
                    if reorder(selection, delta) { reveal(selection) }
                    return .handled
                }
                guard modifiers.isEmpty, let start = QueueFocus.cursorKey(cursor, in: keys) else { return .ignored }
                // Nothing selected: the outlined cursor row is selected first.
                let next = selection.flatMap { keys.firstIndex(of: $0) }.map { keys[min(max(0, $0 + delta), keys.count - 1)] } ?? start
                selection = next
                reveal(next)
                return .handled
            }
            // A song list plays and pauses on Space, as in Music (a focusable view's activation would take it).
            .onKeyPress(.space) { space(); return .handled }
            .onKeyPress(.return) {
                guard let selection, keys.contains(selection) else { return .ignored }
                activate(selection)
                return .handled
            }
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                guard let remove, let selection, let index = keys.firstIndex(of: selection) else { return .ignored }
                // The row that takes its place stays selected: the next one, or the one above at the end.
                let after = keys.indices.contains(index + 1) ? keys[index + 1] : index > 0 ? keys[index - 1] : nil
                guard remove(selection) else { return .handled }
                self.selection = after
                if let after { reveal(after) }
                return .handled
            }
            .onKeyPress(.escape) {
                guard selection != nil else { return .ignored }
                selection = nil
                cursorVisible = true
                return .handled
            }
            // A row that left the list (played, removed elsewhere) takes the selection with it; the outline moves to
            // the row that took its place, so focus stays visible there.
            .onChange(of: keys) { old, new in
                if let selection, !new.contains(selection) { self.selection = nil }
                let moved = QueueFocus.relocated(cursor, from: old, to: new)
                if moved != cursor {
                    cursor = moved
                    if isFocused, selection == nil, let moved { reveal(moved) }
                }
                note()
            }
    }

    /// Records the list's focus state for the council capture's log.
    private func note() {
        guard LayoutProbe.enabled else { return }
        let index = { (key: Key?) in key.flatMap { keys.firstIndex(of: $0) }.map(String.init) ?? "none" }
        let outlined = selection == nil && cursorVisible ? index(QueueFocus.cursorKey(cursor, in: keys)) : "none"
        DebugProbes.note(probe, (isFocused ? "focused" : "unfocused") + ", selected row \(index(selection)), outlined row \(isFocused ? outlined : "none")")
    }
}

// MARK: - Row

private struct QueueRow: View {
    let track: Track
    var entry: QueueEntry?
    /// A History row: plays the song again without replacing the queue.
    var played: PlayedTrack?
    var isCurrent = false
    var moveUp: (() -> Void)?
    var moveDown: (() -> Void)?
    /// Being dragged: drawn raised above the other rows.
    var isLifted = false
    var isSelected = false
    /// The list has keyboard focus: the selection is solid accent with white text, else gray.
    var listFocused = false
    /// The list has focus but nothing is selected, and this is where focus sits: drawn with an accent outline.
    var isFocusCursor = false

    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.undoManager) private var undoManager
    @Environment(\.queueMetrics) private var metrics
    @State private var hovering = false
    /// The row's More has keyboard focus (Tab): it shows, with the row's highlight.
    @State private var moreFocused = false

    init(entry: QueueEntry, moveUp: (() -> Void)? = nil, moveDown: (() -> Void)? = nil, isLifted: Bool = false,
         isSelected: Bool = false, listFocused: Bool = false, isFocusCursor: Bool = false) {
        self.track = entry.track
        self.entry = entry
        self.moveUp = moveUp
        self.moveDown = moveDown
        self.isLifted = isLifted
        self.isSelected = isSelected
        self.listFocused = listFocused
        self.isFocusCursor = isFocusCursor
    }

    init(track: Track, isCurrent: Bool, isSelected: Bool = false, listFocused: Bool = false, isFocusCursor: Bool = false) {
        self.track = track
        self.isCurrent = isCurrent
        self.isSelected = isSelected
        self.listFocused = listFocused
        self.isFocusCursor = isFocusCursor
    }

    init(played: PlayedTrack, isSelected: Bool = false, listFocused: Bool = false, isFocusCursor: Bool = false) {
        self.track = played.track
        self.played = played
        self.isSelected = isSelected
        self.listFocused = listFocused
        self.isFocusCursor = isFocusCursor
    }

    /// Double-click, Return-equivalent and "Play Now": jump to a queued entry, or play a History song next.
    private var playNow: (() -> Void)? {
        if let entry, !isCurrent { return { model.jump(to: entry.uid) } }
        if let played { return { model.playNow(played.track, from: played.context) } }
        return nil
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                ArtworkView(artwork: track.artwork, size: metrics.artwork, cornerRadius: 4)
                    .frame(width: metrics.artwork, height: metrics.artwork)
                if isCurrent {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.black.opacity(0.45))
                    NowPlayingIndicator(tint: .white)
                }
            }
            .frame(width: metrics.artwork, height: metrics.artwork)
            VStack(alignment: .leading, spacing: metrics.lineSpacing) {
                // The playing song's title stays in the label color (an accent title read about 3–4:1 on the panels);
                // the bars on its artwork and the semibold weight mark it.
                Text(track.title)
                    .font(.system(size: metrics.titleSize, weight: isCurrent || metrics.titleSize > 13 ? .semibold : .medium))
                    .foregroundStyle(emphasized ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                    .lineLimit(2)
                HStack(spacing: 4) {
                    ServiceGlyph(provider: track.provider, size: 9)
                    Text(track.artistLine).lineLimit(1)
                }
                .font(.system(size: metrics.artistSize))
                .foregroundStyle(.readableSecondary)
            }
            Spacer(minLength: 4)
            // The time at rest; the row's "…" in its place under the pointer, on the focused selection, or with
            // keyboard focus, as on the other song rows. The hidden button keeps its place in the Tab order: it is
            // drawn in a clear ink, since SwiftUI leaves views at opacity 0 out of it (`KeyboardMoreButton`).
            ZStack(alignment: .trailing) {
                TrackDurationText(track, font: .system(size: metrics.artistSize), minWidth: nil)
                    .foregroundStyle(model.displayDuration(for: track) == nil && !emphasized ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.readableSecondary))
                    .opacity(revealsMore ? 0 : 1)
                KeyboardMoreButton(size: metrics.titleSize > 13 ? 15 : 14, focused: $moreFocused, probeNote: "queue|\(track.id)|\(track.title)",
                                   label: "More actions for \(track.title)", forceDark: metrics == .fullScreen) {
                    rowMenu
                }
                .foregroundStyle(!revealsMore ? AnyShapeStyle(Color.clear)
                                 : emphasized ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                .modifier(LayoutProbe(key: isCurrent ? "queue-more-current" : "queue-more-\(track.id)"))
                // Council captures: whether the "…" is drawn, not just laid out (the probe exists in clear ink too).
                .onChange(of: revealsMore, initial: true) {
                    if LayoutProbe.enabled { DebugProbes.note("queue-more-revealed-\(track.id)", revealsMore ? "shown" : "hidden") }
                }
            }
        }
        // On the focused (accent) selection every line turns white, as in a native table: `readableSecondary` and the
        // hierarchical styles follow the background's prominence.
        .environment(\.backgroundProminence, emphasized ? .increased : .standard)
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background {
            if isLifted {
                RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            } else {
                RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
                    .fill(rowFill)
            }
        }
        .overlay { if isFocusCursor && !isLifted { FocusCursorOutline() } }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("\(track.title) — \(track.artistLine)")
        .onTapGesture(count: 2) { playNow?() }
        .contextMenu { rowMenu }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Play Now") { playNow?() }
        .accessibilityAction(named: "Move Up") { moveUp?() }
        .accessibilityAction(named: "Move Down") { moveDown?() }
    }

    /// The "…" shows in place of the time.
    private var revealsMore: Bool { !isLifted && (hovering || moreFocused || (isSelected && listFocused)) }

    /// The row's menu: the right-click menu and the "…" button's are the same.
    @ViewBuilder private var rowMenu: some View {
        if let played {
            Button("Play Now", systemImage: "play") { model.playNow(played.track, from: played.context) }
            Divider()
        }
        if let entry, !isCurrent {
            Button("Play Now", systemImage: "play") { model.jump(to: entry.uid) }
            if moveUp != nil || moveDown != nil {
                // The shortcuts work on the selected row while the list has focus (`QueueKeyboard`).
                Button("Move Up", systemImage: "arrow.up") { moveUp?() }
                    .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                    .disabled(moveUp == nil)
                Button("Move Down", systemImage: "arrow.down") { moveDown?() }
                    .keyboardShortcut(.downArrow, modifiers: [.option, .command])
                    .disabled(moveDown == nil)
            }
            Button("Remove from Queue", systemImage: "minus.circle") { model.player.removeUpNext([entry.uid], undoManager: undoManager) }
                .keyboardShortcut(.delete, modifiers: [])
            Divider()
        }
        TrackMenu(track: track)
    }

    /// Selected while the list has keyboard focus: the solid accent selection with white text.
    private var emphasized: Bool { isSelected && listFocused && !isLifted }

    /// The native table selection, as in Songs: the system's selected-content color while the list has focus, its
    /// unemphasized gray when it doesn't, a light gray on hover.
    private var rowFill: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(SelectionFill.color(focused: listFocused)) }
        // The hover highlight, also while the row's More has keyboard focus, so it's clear which song the menu is for.
        return AnyShapeStyle(Color.primary.opacity(hovering || moreFocused ? (scheme == .dark ? 0.07 : 0.05) : 0))
    }
}
