import AppKit
import MedleyCore
import SwiftUI

/// Animated bars for the row that is playing; still bars when paused. Accent-colored on a row, white over artwork.
///
/// AppKit draws it (`WaveformSymbol`), so Core Animation runs the bars. SwiftUI's `.symbolEffect` is driven from
/// the main thread: while music played it re-rendered and laid out the whole window on every frame, about a
/// fifth of a core with nothing else moving, and every other animation (panels, sidebar, scrolling) lost frames.
struct NowPlayingIndicator: View {
    var tint: Color = .accentColor
    @Environment(AppModel.self) private var model
    @Environment(\.medleySnapshot) private var snapshot

    var body: some View {
        WaveformSymbol(tint: tint, animating: model.player.isPlaying && !snapshot,
                       label: model.player.isPlaying ? "Now playing" : "Paused")
            .fixedSize()
    }
}

/// The "waveform" symbol at 12 pt semibold, its variable-color effect run by AppKit.
private struct WaveformSymbol: NSViewRepresentable {
    let tint: Color
    let animating: Bool
    let label: String

    func makeNSView(context: Context) -> SymbolView {
        let view = SymbolView()
        view.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        view.imageScaling = .scaleNone
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setAccessibilityRole(.image)
        return view
    }

    func updateNSView(_ view: SymbolView, context: Context) {
        // Resolved in SwiftUI's environment, so a forced color scheme (the full-screen player's) still applies.
        let color = NSColor(cgColor: tint.resolve(in: context.environment).cgColor) ?? .controlAccentColor
        if view.contentTintColor != color { view.contentTintColor = color }
        view.setAccessibilityLabel(label)
        guard view.animating != animating else { return }
        view.animating = animating
        if animating {
            view.addSymbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
        } else {
            view.removeAllSymbolEffects()
        }
    }

    final class SymbolView: NSImageView {
        var animating = false
        // Clicks go to the SwiftUI button or row underneath.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

enum TrackListStyle {
    /// Numbered rows without artwork (album pages).
    case album
    /// Numbered rows with artwork, artist and album columns (playlists, liked songs, top songs).
    case playlist
}

/// The track table on album, playlist and library pages: a header row (#, Title, Album, a clock), then
/// numbered rows. Hovering a row swaps its number for a play button; the current track shows a semibold title
/// and an animated equalizer in place of its number. Click selects and moves keyboard focus into the list; arrows move the
/// selection; Return, double-click and the hover button all play through one callback that keeps the whole
/// list as the queue.
///
/// Several rows can be selected as in a Mac table (`TrackSelection`): ⌘-click, ⇧-click, ⇧↑/⇧↓ and ⌘A. A selected
/// row's context menu and More then act on every selected row in the order shown (`TracksMenu`); a row outside the
/// selection acts on itself. Neighbouring selected rows join into one fill.
///
/// Focus stays visible without a selection: while the list has focus and nothing is selected (Tab into it, Escape,
/// the selected row gone), the cursor row gets an accent outline, when that focus is the keyboard's
/// (`KeyboardCursorTracking`: a click that focuses the list without selecting a row leaves none). The cursor is the
/// row last selected (or the first row), and ↑/↓ select it before moving on.
struct TrackListView: View {
    let tracks: [Track]
    let style: TrackListStyle
    let context: AppModel.PlayingFrom
    var albumArtist: String? = nil
    var playlist: Playlist? = nil
    /// What playing row `index` does. Defaults to playing `tracks` from that row with `context`.
    /// A paged playlist passes its own so the unloaded pages are queued too.
    var onPlay: ((Int) -> Void)? = nil
    /// Called when the last rows appear, to load the next page.
    var onReachEnd: (() -> Void)? = nil
    var showsHeader = true
    /// Allow the Album column (it still hides when no row has an album, or the list is narrow).
    var allowsAlbum = true
    /// Show the row's position instead of the album track number.
    var numbersByPosition = false
    /// The number to show on each row, when the rows are a filtered part of a longer list.
    var rowNumbers: [Int]? = nil
    /// The # column's numbers. Off for a sorted playlist, as in Music: its places (30, 38, 29…) read as noise in
    /// another order. The column keeps its width for the hover Play and the now-playing bars.
    var showsNumbers = true
    /// The page's sort: the header's Title, Album and duration cells become buttons that set it. Nil for lists that
    /// don't sort (short ones, artist top songs).
    var sort: Binding<TrackSort>? = nil
    /// The rows are for now a shorter part of the list (fresh detail replaced the pages loaded before, and they are
    /// loading again): selected rows missing from them stay selected until it is whole, and only the selected rows
    /// shown are acted on.
    var holdsSelection = false
    /// A playlist's entries per song (`PlaylistPager.copies`): a row whose song is in the playlist more than once
    /// says "2×" beside its time, and its Remove item names the copies.
    var copies: [String: Int] = [:]

    @Environment(AppModel.self) private var model
    @Environment(\.isCompactHeight) private var compact
    @State private var selection = TrackSelection()
    #if DEBUG
    @Environment(\.playlistPageProbe) private var probe
    #endif
    /// Where keyboard focus sits in the list: the last selected row (the selection's lead). Outlined while the list has
    /// focus and no selection.
    @State private var cursor: Int?
    /// The cursor's outline shows for keyboard focus only (`KeyboardCursorTracking`).
    @State private var keyboardCursor = false
    @State private var width: CGFloat = 800
    @FocusState private var focused: Bool

    /// The row that shows focus without a selection: the cursor, kept within the rows, or the first row.
    private var cursorRow: Int? {
        guard !tracks.isEmpty else { return nil }
        return min(max(0, cursor ?? 0), tracks.count - 1)
    }

    /// The Album column needs this much table width to leave the title readable.
    static var albumColumnMinWidth: CGFloat { 1000 }

    /// Whether a playlist-style table gets an Album column: at least half its rows have an album (a mostly blank
    /// column wastes the width the titles need) and the table is at least `albumColumnMinWidth` wide. Otherwise
    /// each row puts its album, when it has one, in the subtitle line.
    static func showsAlbumColumn(_ tracks: [Track], width: CGFloat) -> Bool {
        guard width >= albumColumnMinWidth, !tracks.isEmpty else { return false }
        let withAlbum = tracks.count(where: { !($0.album?.title ?? "").isEmpty })
        return withAlbum * 2 >= tracks.count
    }

    /// The rows' ids: each song's `Track.id` (a playlist lists a song once, `PlaylistPager`).
    private var ids: [String] { tracks.map(\.id) }

    var body: some View {
        let currentID = model.player.current?.id
        let showAlbum = style == .playlist && allowsAlbum && Self.showsAlbumColumn(tracks, width: width)
        let ids = ids
        // The selected rows shown, in the order shown (a held selection can name rows not loaded again yet), handed to
        // the selected rows only while there are several: their menus act on all of them.
        let shownSelection = selection.selected(tracks)
        let group = shownSelection.count > 1 ? shownSelection : nil
        let groupCopies = group.map { $0.reduce(0) { $0 + max(1, copies[$1.id] ?? 1) } } ?? 0
        let noneSelected = shownSelection.isEmpty
        // Some lists (YouTube artist top songs) come without any durations: drop the column, not a row of dashes.
        let showDuration = tracks.contains { $0.duration != nil }
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // Outside the focusable rows, so its sort buttons take Tab focus of their own.
                if showsHeader {
                    TrackTableHeader(style: style, showAlbum: showAlbum, showDuration: showDuration, showsNumbers: showsNumbers, sort: sort)
                        .padding(.bottom, 6)
                }
                LazyVStack(spacing: 0) {
                    ForEach(Array(zip(ids, tracks).enumerated()), id: \.element.0) { index, row in
                        let (rowID, track) = row
                        let selected = selection.contains(rowID)
                        TrackRow(
                            track: track, index: index, style: style,
                            isCurrent: track.id == currentID,
                            togglesInPlace: track.id == currentID && model.isCurrent(track, in: context),
                            isSelected: selected,
                            joinsAbove: selected && index > 0 && selection.contains(ids[index - 1]),
                            joinsBelow: selected && index < ids.count - 1 && selection.contains(ids[index + 1]),
                            group: selected ? group : nil,
                            groupCopies: selected ? groupCopies : 0,
                            copies: max(1, copies[track.id] ?? 1),
                            listFocused: focused,
                            isFocusCursor: focused && keyboardCursor && noneSelected && cursorRow == index,
                            showAlbum: showAlbum,
                            showDuration: showDuration,
                            albumArtist: albumArtist,
                            playlist: playlist,
                            numberByPosition: numbersByPosition || style == .playlist,
                            number: rowNumbers?[safe: index],
                            showsNumber: showsNumbers,
                            compact: compact,
                            showsSeparator: style == .album && index < tracks.count - 1,
                            play: { play(index) },
                            toggleSelection: {
                                selection.click(rowID, .toggle, in: ids)
                            }
                        )
                        .modifier(DebugFrame(key: "track-row-\(index)"))
                        // Both taps run side by side, so a single click selects at once instead of waiting
                        // out the double-click interval; the second click of a double-click then plays.
                        .simultaneousGesture(TapGesture().onEnded {
                            // The click's own modifiers (the event being handled), else the keys held now.
                            let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
                            selection.click(rowID, TrackSelection.Click(flags), in: ids)
                            focused = true
                        })
                        .simultaneousGesture(TapGesture(count: 2).onEnded { play(index) })
                        .onAppear {
                            if index >= tracks.count - 5 { onReachEnd?() }
                        }
                    }
                }
                .focusable()
                .focused($focused)
                // The rows draw focus: the accent selection, or the cursor row's outline when nothing is selected.
                .focusEffectDisabled()
                .modifier(KeyboardCursorTracking(isFocused: focused, selection: noneSelected ? nil : selection.ids, visible: $keyboardCursor))
                .onChange(of: focused) {
                    // Keyboard entry (Tab) lands on the cursor row: bring it into view. A click selects first, so it doesn't scroll.
                    if focused, noneSelected, let row = cursorRow { proxy.scrollTo(ids[row]) }
                    noteFocus()
                }
                .onChange(of: selection) {
                    if !selection.isEmpty, let lead = selection.lead, let row = ids.firstIndex(of: lead) { cursor = row }
                    noteFocus()
                }
                .onChange(of: keyboardCursor) { noteFocus() }
                // ⇧ extends the selection from its anchor.
                .onKeyPress(keys: [.downArrow, .upArrow]) { press in
                    move(press.key == .downArrow ? 1 : -1, extending: press.modifiers.contains(.shift), proxy)
                }
                // ⌘A: Edit › Select All reaches the focused list through the responder chain; the key itself when no
                // menu item takes it.
                .onCommand(#selector(NSText.selectAll(_:))) { selectAll() }
                .onKeyPress(keys: ["a"]) { press in
                    guard press.modifiers == .command else { return .ignored }
                    selectAll()
                    return .handled
                }
                // A song list plays and pauses on Space, as in Music (a focusable view's activation would take it).
                .onKeyPress(.space) { SpaceFallback.toggle(model, from: "track list"); return .handled }
                .onKeyPress(.return) {
                    // The first selected row in the order shown, as in Songs.
                    guard let first = selection.indices(in: ids).first else { return .ignored }
                    play(first)
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard !selection.isEmpty else { return .ignored }
                    selection.clear()
                    keyboardCursor = true
                    return .handled
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // The selection is the rows' ids: a sort or the next page keeps it, and rows a filter hides or a removal took
        // away leave it (the anchor moving to a selected row still there). Rows missing only while a refreshed list
        // loads its pages again (`holdsSelection`) stay selected, and leave once the list is whole without them. The
        // cursor keeps its position, so the outline stays on screen where the selection was.
        .onChange(of: ids) { old, new in
            selection.rowsChanged(from: old, to: new, holding: holdsSelection)
            if LayoutProbe.enabled, sort != nil { DebugProbes.note("track-list-order", tracks.prefix(3).map(\.title).joined(separator: " / ")) }
        }
        .onChange(of: holdsSelection) {
            if !holdsSelection { selection.keep(ids) }
        }
        #if DEBUG
        .onAppear { probe?.selection = $selection }
        #endif
        // A reading width, starting at the page's content inset like the hero above it (narrower for albums).
        .frame(maxWidth: Metrics.trackListMaxWidth(style), alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Records the list's focus state for the council capture's log: "selected row 2", "selected rows 1, 3, 4", or
    /// "selected row none".
    private func noteFocus() {
        guard LayoutProbe.enabled else { return }
        let ids = ids
        let rows = selection.indices(in: ids)
        let selected = rows.count > 1 ? "rows \(rows.map(String.init).joined(separator: ", "))" : "row \(rows.first.map(String.init) ?? "none")"
        let outlined = selection.isEmpty && keyboardCursor ? cursorRow.map(String.init) ?? "none" : "none"
        DebugProbes.note("track-list", focused ? "focused, selected \(selected), outlined row \(outlined)" : nil)
        DebugProbes.note("track-list-selection", rows.isEmpty ? nil : selection.selected(tracks).map(\.title).joined(separator: " / "))
    }

    /// Plays from row `index`. A row outside the selection becomes the selection; one inside keeps it.
    private func play(_ index: Int) {
        let ids = ids
        guard tracks.indices.contains(index), ids.indices.contains(index) else { return }
        if !selection.contains(ids[index]) { selection.select(ids[index]) }
        if let onPlay { onPlay(index) } else { model.play(tracks, startAt: index, from: context) }
    }

    /// ↑/↓: moves the selection (⇧: its far end, from the anchor); with nothing selected, selects the outlined cursor row.
    private func move(_ delta: Int, extending: Bool, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !tracks.isEmpty, let cursorRow else { return .ignored }
        let ids = ids
        if let lead = selection.move(delta, extending: extending, in: ids, cursor: ids[cursorRow]) {
            proxy.scrollTo(lead)
        }
        return .handled
    }

    private func selectAll() {
        guard !tracks.isEmpty else { return }
        selection.selectAll(ids)
    }
}

/// Fixed widths shared by the header and the rows, so columns line up.
private enum TrackColumns {
    static let number: CGFloat = 28
    static let art: CGFloat = 40
    /// Heart, "…" and the duration.
    static let trailing: CGFloat = 14 + 6 + 24 + 6 + Metrics.durationWidth
    static let trailingWithoutDuration: CGFloat = 14 + 6 + 24
}

private struct TrackTableHeader: View {
    let style: TrackListStyle
    let showAlbum: Bool
    var showDuration = true
    var showsNumbers = true
    var sort: Binding<TrackSort>?

    var body: some View {
        HStack(spacing: 12) {
            Text(showsNumbers ? "#" : "").frame(width: TrackColumns.number, alignment: .trailing)
            if style == .playlist { Color.clear.frame(width: TrackColumns.art, height: 1) }
            cell(.title, alignment: .leading) { Text("Title") }
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(DebugFrame(key: "sort-menu"))
            if showAlbum {
                cell(.album, alignment: .leading) { Text("Album") }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Group {
                if showDuration {
                    cell(.duration, alignment: .trailing) { Image(systemName: "clock").accessibilityLabel("Duration") }
                } else {
                    Color.clear
                }
            }
            .frame(width: Metrics.durationWidth, alignment: .trailing)
            .frame(width: showDuration ? TrackColumns.trailing : TrackColumns.trailingWithoutDuration, alignment: .trailing)
        }
        .font(.tableHeader)
        .foregroundStyle(.readableSecondary)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .overlay(alignment: .bottom) {
            // Inset by the rows' 10 pt padding, so the line starts and ends at the page margin with the hero above,
            // not 10 pt past it on each side.
            Rectangle().fill(.separator).frame(height: 0.5)
                .padding(.horizontal, 10)
        }
    }

    @ViewBuilder private func cell(_ column: TrackSort.Key, alignment: Alignment, @ViewBuilder label: () -> some View) -> some View {
        if let sort {
            SortHeaderCell(column: column, alignment: alignment, sort: sort, label: label)
        } else {
            label()
        }
    }
}

/// A header cell that sorts the table, like a native table's column header: a click sorts by its column, a second
/// click reverses, a third goes back to the original order (`TrackSort.toggled`). The active column shows a small
/// chevron (up for ascending) after its title, or before a trailing column's glyph so the clock stays over the
/// durations. The whole column's header takes the click.
///
/// Focusable with or without the system's Keyboard Navigation setting (as `KeyboardMoreButton`): Tab reaches it,
/// Space or Return sorts, and keyboard focus shows a 2 pt accent ring around the title. A click leaves no focus
/// behind, as a native header does.
private struct SortHeaderCell<Label: View>: View {
    let column: TrackSort.Key
    let alignment: Alignment
    @Binding var sort: TrackSort
    @ViewBuilder var label: Label

    @FocusState private var hasFocus: Bool
    @State private var keyboard = false
    @State private var hovering = false

    var body: some View {
        let active = sort.key == column
        let trailing = alignment == .trailing
        HStack(spacing: 4) {
            if trailing, active { chevron }
            label
            if !trailing, active { chevron }
        }
        .foregroundStyle(active || hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.readableSecondary))
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .overlay {
            if hasFocus && keyboard {
                RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, -5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .contentShape(Rectangle())
        .focusable(interactions: .edit)
        .focused($hasFocus)
        .focusEffectDisabled()
        .onAppear { LastInput.start() }
        .onChange(of: hasFocus) {
            keyboard = hasFocus && (LastInput.wasKeyboard || NSApp.currentEvent?.type == .keyDown)
        }
        .onTapGesture {
            keyboard = false
            sort = sort.toggled(column)
            // A click doesn't leave focus here (Space would sort instead of playing).
            RunLoop.main.perform(inModes: [.default]) {
                MainActor.assumeIsolated { hasFocus = false }
            }
        }
        .onKeyPress(keys: [.space, .return]) { _ in
            sort = sort.toggled(column)
            return .handled
        }
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .onChange(of: sort) {
            if LayoutProbe.enabled, column == .title { DebugProbes.note("track-sort", "\(sort.key.rawValue) \(sort.ascending ? "ascending" : "descending")") }
        }
        .help("Sort by \(column.label)")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Sort by \(column.label)")
        .accessibilityValue(active ? (sort.ascending ? "Ascending" : "Descending") : "")
        .accessibilityAction { sort = sort.toggled(column) }
    }

    private var chevron: some View {
        Image(systemName: sort.ascending ? "chevron.up" : "chevron.down")
            .font(.system(size: 8, weight: .bold))
            .accessibilityHidden(true)
    }
}

struct TrackRow: View {
    let track: Track
    let index: Int
    let style: TrackListStyle
    let isCurrent: Bool
    /// The row's Play glyph pauses or resumes instead of starting the list: this song is playing from this list.
    var togglesInPlace = false
    let isSelected: Bool
    /// The rows above and below are selected too: the fills join into one block, with no rounded corners between.
    var joinsAbove = false
    var joinsBelow = false
    /// Every selected row in the order shown, when this row is one of several selected: its menus act on all of them.
    var group: [Track]? = nil
    /// Every entry the group's songs have in the playlist, copies counted (its Remove item names them).
    var groupCopies = 0
    /// How many entries this song has in the playlist (`PlaylistPager.copies`): "2×" beside the time from 2.
    var copies = 1
    var listFocused = false
    /// The list has focus but nothing is selected, and this is where focus sits: drawn with an accent outline.
    var isFocusCursor = false
    let showAlbum: Bool
    var showDuration = true
    var albumArtist: String?
    var playlist: Playlist?
    var numberByPosition = false
    /// Overrides the number shown (a filtered list keeps each song's place in the whole list).
    var number: Int? = nil
    /// Off: nothing at rest in the # column (a sorted playlist); Play on hover and the playing bars still show.
    var showsNumber = true
    /// Shorter rows for a short window (same type sizes).
    var compact = false
    /// A hairline under the row from the title column to the trailing edge (album pages, all but the last row).
    var showsSeparator = false
    let play: () -> Void
    /// ⌘-click's toggle, for VoiceOver's Add to Selection / Remove from Selection actions.
    var toggleSelection: (() -> Void)? = nil

    static func height(_ style: TrackListStyle, compact: Bool) -> CGFloat {
        switch style {
        // Album rows are one line of text: 44 pt, like Music's, with a hairline between them (`showsSeparator`).
        case .album: compact ? 40 : 44
        case .playlist: compact ? 52 : 58
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            leadingNumber
                .frame(width: TrackColumns.number, alignment: .trailing)
            if style == .playlist {
                ArtworkView(artwork: track.artwork, size: TrackColumns.art, cornerRadius: 4, symbol: track.isVideo ? "play.rectangle" : "music.note")
                    .frame(width: TrackColumns.art, height: TrackColumns.art)
            }
            if style == .album {
                // One line, like every album row: the featured artists follow the title and truncate first, so a
                // song with guests is no taller than the rest.
                HStack(spacing: 8) {
                    titleLine.layoutPriority(1)
                    if let subtitle {
                        subtitleText(subtitle)
                            .font(.rowSecondary)
                            .foregroundStyle(.readableSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    titleLine
                    if let subtitle {
                        HStack(spacing: 5) {
                            if style == .playlist { ServiceGlyph(provider: track.provider, size: 10) }
                            subtitleText(subtitle)
                        }
                        .font(.rowSecondary)
                        .foregroundStyle(.readableSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if showAlbum {
                Text(track.album?.title ?? "")
                    .font(.rowSecondary)
                    .foregroundStyle(.readableSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if showDuration { AltVersionLabel(track: track) } else if copies > 1 { CopiesMarker(count: copies).foregroundStyle(.readableSecondary) }
            trailing
        }
        // On the focused selection every line turns white, as in a native table (`readableSecondary` and the
        // hierarchical styles follow the background's prominence).
        .environment(\.backgroundProminence, emphasized ? .increased : .standard)
        .padding(.horizontal, 10)
        .frame(height: Self.height(style, compact: compact))
        .background(rowBackground, in: rowShape)
        .overlay(alignment: .bottom) {
            // Hidden under the row's own highlight, which has rounded corners the line would cut through.
            if showsSeparator {
                Rectangle().fill(.separator).frame(height: 0.5)
                    .padding(.leading, 10 + TrackColumns.number + 12)
                    .padding(.trailing, 10)
                    .opacity(hovering || isSelected || isFocusCursor ? 0 : 1)
                    .accessibilityHidden(true)
            }
        }
        .overlay { if isFocusCursor { FocusCursorOutline() } }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        .contextMenu { menu }
        .mediaDraggable(.track(track))
        .opacity(track.isPlayable ? 1 : 0.45)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Play") { play() }
        // ⌘-click without the pointer: VoiceOver's actions menu (VO-⌘-Space) adds or removes the row.
        .accessibilityActions {
            if let toggleSelection {
                Button(isSelected ? "Remove from Selection" : "Add to Selection", action: toggleSelection)
            }
        }
    }

    /// Album rows: featured artists only. Playlist rows: the artist line.
    private var subtitle: String? {
        switch style {
        case .album:
            guard let albumArtist else { return nil }
            let names = track.artists.map(\.name)
            return names.isEmpty || names == [albumArtist] ? nil : names.joined(separator: ", ")
        case .playlist:
            // Without an Album column, the album joins the artist line (unless it only repeats the song's title,
            // as a single's does).
            var parts = track.artistLine.isEmpty ? [] : [track.artistLine]
            if !showAlbum, let album = track.album?.title, !album.isEmpty, album.caseInsensitiveCompare(track.title) != .orderedSame {
                parts.append(album)
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    /// The subtitle, as whole names when it is only the song's artists ("HUNTR/X, EJAE and more", `FittedNames`);
    /// with the album after them, cut at the end as before.
    @ViewBuilder private func subtitleText(_ subtitle: String) -> some View {
        let names = track.artists.map(\.name)
        if names.count > 1, subtitle == names.joined(separator: ", ") {
            FittedNames(names: names, size: 13)
        } else {
            Text(subtitle).lineLimit(1)
        }
    }

    /// Play shows under the pointer, and on the focused selection when it's one row (several selected rows would show
    /// a column of Play buttons; Return plays the first).
    private var revealsControls: Bool { hovering || (isSelected && listFocused && group == nil) }

    @ViewBuilder private var leadingNumber: some View {
        if revealsControls {
            Button(action: togglesInPlace ? { model.togglePlayPause() } : play) {
                Image(systemName: togglesInPlace && model.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: TrackColumns.number, height: 28, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(IconButtonStyle(tint: emphasized ? .white : nil))
            .accessibilityLabel(togglesInPlace && model.player.isPlaying ? "Pause" : "Play \(track.title)")
        } else if isCurrent {
            // The bars are the "now playing" cue; the title stays in the label color.
            NowPlayingIndicator(tint: emphasized ? .white : .accentColor)
        } else if !showsNumber {
            Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
        } else {
            Text("\(number ?? (numberByPosition ? index + 1 : track.trackNumber ?? index + 1))")
                .font(.rowSecondary.monospacedDigit())
                .foregroundStyle(.readableSecondary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var titleLine: some View {
        HStack(spacing: 5) {
            Text(track.title)
                .font(.rowTitle)
                .lineLimit(1)
                // The playing song's title stays in the label color, semibold: an accent title read under 4.5:1.
                .fontWeight(isCurrent ? .semibold : nil)
                .foregroundStyle(emphasized ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            if track.isExplicit { ExplicitBadge() }
        }
    }

    private var trailing: some View {
        HStack(spacing: 6) {
            Image(systemName: "heart.fill")
                .font(.system(size: 11))
                // White on the focused accent selection (set here: the style's own prominence check left it accent
                // on accent, about 1:1).
                .foregroundStyle(emphasized ? AnyShapeStyle(Color.white) : AnyShapeStyle(.likedHeart))
                .frame(width: 14)
                .opacity(model.isLiked(track) ? 1 : 0)
                .accessibilityHidden(!model.isLiked(track))
                .accessibilityLabel("Liked")
            // On every row at rest in a quiet gray, like Music's; the label color under the pointer or on the
            // selection, white on the focused accent selection.
            // The menu's label takes its ink from `ink`: a pull-down menu's borderless label ignores the
            // foreground style around it, and stayed dark on the focused accent selection.
            MoreButton(ink: moreInk) { menu }
            if showDuration {
                // "2×" just before the time, inside the time's column, so the Time header stays over the times.
                HStack(spacing: 5) {
                    if copies > 1 { CopiesMarker(count: copies) }
                    TrackDurationText(track, minWidth: nil)
                }
                .foregroundStyle(.readableSecondary)
                .frame(minWidth: Metrics.durationWidth, alignment: .trailing)
            }
        }
        .frame(width: showDuration ? TrackColumns.trailing : TrackColumns.trailingWithoutDuration, alignment: .trailing)
        .modifier(LayoutProbe(key: "row-trailing"))
    }

    /// Selected while the list has keyboard focus: the solid accent selection with white text.
    private var emphasized: Bool { isSelected && listFocused }

    /// The "…" ink: white on the focused accent selection, the label color under the pointer or on the unfocused
    /// selection, and a quiet gray at rest, like Music's.
    private var moreInk: MoreButtonInk {
        if emphasized { return .white }
        return revealsControls || isSelected ? .label : .quiet
    }

    /// The song's menu, or the selection's when this row is one of several selected.
    @ViewBuilder private var menu: some View {
        if let group, group.count > 1 {
            TracksMenu(tracks: group, playlist: playlist, copies: groupCopies)
        } else {
            TrackMenu(track: track, playlist: playlist, copies: copies)
        }
    }

    /// The row's rounded shape, square where a selected neighbour's fill joins it.
    private var rowShape: UnevenRoundedRectangle {
        let r = Metrics.rowRadius
        let top: CGFloat = joinsAbove ? 0 : r, bottom: CGFloat = joinsBelow ? 0 : r
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous)
    }

    /// A hover highlight and the native table selection (`SelectionFill`), as in Songs.
    private var rowBackground: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(SelectionFill.color(focused: listFocused)) }
        if hovering { return AnyShapeStyle(Color.primary.opacity(scheme == .dark ? 0.07 : 0.05)) }
        return AnyShapeStyle(Color.clear)
    }
}

/// "2×", "3×": a playlist row whose song the playlist holds more than once (one row per song, `PlaylistPager`), in
/// the row's secondary ink, read by VoiceOver as "in this playlist twice".
struct CopiesMarker: View {
    let count: Int

    static func spoken(_ count: Int) -> String { count == 2 ? "in this playlist twice" : "in this playlist \(count) times" }

    var body: some View {
        Text("\(count)×")
            .font(.rowSecondary.monospacedDigit())
            .lineLimit(1)
            .fixedSize()
            .help("This song is \(Self.spoken(count)).")
            .accessibilityLabel(Self.spoken(count))
            .modifier(LayoutProbe(key: "copies-marker-\(count)"))
    }
}

/// Keyboard focus on a list row that isn't selected: a 2 pt accent outline inside the row's rounded shape, like the
/// system focus ring but kept inside the row so a scroll view never clips it. Solid accent: at least 3:1 against
/// the window background in light and dark, and against the full-screen player's dark panel.
struct FocusCursorOutline: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Whether a focused list with nothing selected draws its cursor outline (`FocusCursorOutline`): only when its focus
/// is the keyboard's, as `:focus-visible` on the web. `visible` turns on when focus arrives with a key press (Tab),
/// when a row gets selected (by click or key: the outline then marks where the selection was after Escape, or after
/// the selected song is played or removed elsewhere), and on Escape (the list sets it); a mouse down inside the
/// focused list (a click on Clear, the header, a row's heart or More) turns it off until one of those happens again.
/// Focus that a click gave the list without selecting a row shows no outline.
struct KeyboardCursorTracking<Key: Hashable>: ViewModifier {
    let isFocused: Bool
    let selection: Key?
    @Binding var visible: Bool

    func body(content: Content) -> some View {
        content
            // Watches mouse downs only while the list has focus; the click that gives it focus is read below.
            .background(MouseDownWatcher(active: isFocused) { visible = false })
            .onAppear { LastInput.start() }
            .onChange(of: isFocused) {
                guard isFocused else { return }
                // SwiftUI reports the focus change after the event that caused it has finished, so the event in
                // progress (`NSApp.currentEvent`) no longer says; the last key or mouse down the app saw does.
                if LastInput.wasKeyboard || NSApp.currentEvent?.type == .keyDown {
                    visible = true
                } else if selection == nil {
                    visible = false
                }
            }
            .onChange(of: selection) {
                if selection != nil { visible = true }
            }
    }
}

/// Whether the last key or mouse down the app received was a key: how focus that just moved got there. One app-local
/// monitor, started by the first list that shows a focus cursor.
@MainActor
enum LastInput {
    private(set) static var wasKeyboard = false
    private static var monitor: Any?

    static func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            MainActor.assumeIsolated { wasKeyboard = event.type == .keyDown }
            return event
        }
    }
}

/// Calls `action` on a mouse down inside its view (the list it sits behind) while `active`: an app-local event
/// monitor, installed only while the list has focus, so it costs nothing otherwise.
private struct MouseDownWatcher: NSViewRepresentable {
    let active: Bool
    let action: () -> Void

    @MainActor final class Coordinator {
        weak var view: NSView?
        var action: () -> Void = {}
        private var monitor: Any?

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) {
            guard let view, let window = view.window, event.window === window else { return }
            if view.bounds.contains(view.convert(event.locationInWindow, from: nil)) { action() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.action = action
        if active { context.coordinator.start() } else { context.coordinator.stop() }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.stop() }
}

/// A compact song row for grids (Home "Quick picks", search Songs).
struct CompactTrackRow: View {
    let track: Track
    /// The list `play` starts; Play pauses or resumes in place only when the queue came from it.
    var context: AppModel.PlayingFrom? = nil
    let play: () -> Void
    var showsGlyph = true
    /// Show the duration at the end of the row (off when the shelf has no durations at all).
    var showsDuration = false
    /// Bigger artwork and title, for the first shelf on Home.
    var large = false
    /// Replaces the artist line, e.g. "Video · Taylor Swift" in search results.
    var subtitle: String? = nil
    /// Search rows: the tooltip names the album, and the menu's Go to Album does too, since the row's text doesn't.
    var namesAlbum = false

    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    @State private var moreFocused = false

    var body: some View {
        let isCurrent = model.player.current?.id == track.id
        let togglesInPlace = isCurrent && context.map { model.isCurrent(track, in: $0) } == true
        let art: CGFloat = large ? 52 : 44
        HStack(spacing: 12) {
            Button(action: togglesInPlace ? { model.togglePlayPause() } : play) {
                ZStack {
                    ArtworkView(artwork: track.artwork, size: art, cornerRadius: 5)
                        .frame(width: art, height: art)
                    if hovering || isCurrent {
                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.black.opacity(0.45))
                        if isCurrent && !hovering {
                            NowPlayingIndicator(tint: .white)
                        } else {
                            Image(systemName: togglesInPlace && model.player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: large ? 16 : 14))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .frame(width: art, height: art)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.playLabel(title: track.title, togglesInPlace: togglesInPlace, isPlaying: model.player.isPlaying))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(track.title)
                        .font(large ? .system(size: 15, weight: .semibold) : .rowTitle)
                        .lineLimit(1)
                        // Label color: the bars on the artwork mark the playing song (an accent title read under 4.5:1).
                        .foregroundStyle(.primary)
                    if track.isExplicit { ExplicitBadge() }
                }
                // An empty subtitle means the row has no second line (an artist's top songs all from one album).
                if subtitle != "" || showsGlyph {
                    HStack(spacing: 5) {
                        if showsGlyph { ServiceGlyph(provider: track.provider, size: 10) }
                        if let subtitle {
                            // Whole words ("you seem pretty sad for a girl so…", an artist's Top Songs album line).
                            FittedText(text: subtitle, size: 13)
                        } else {
                            // Whole names, never one cut mid-list ("HUNTR/X, EJAE, AUDREY NUNA,…" in round 25).
                            FittedNames(names: track.artists.map(\.name), size: 13)
                        }
                    }
                    .font(.rowSecondary)
                    .foregroundStyle(.readableSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // On every row at rest in the opaque `readableSecondary` gray, the artist line's ink (a control needs
            // 3:1; the tertiary gray it had read 1.9:1 light, 2.2:1 dark); the label color under the pointer or with
            // keyboard focus (Tab reaches it with or without Keyboard Navigation).
            KeyboardMoreButton(focused: $moreFocused, probeNote: "\(track.id)|\(track.title)") {
                TrackMenu(track: track, namesAlbum: namesAlbum)
            }
            .foregroundStyle(moreFocused || hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.readableSecondary))
            if showsDuration {
                AltVersionLabel(track: track)
                TrackDurationText(track, minWidth: 44)
                    .foregroundStyle(.readableSecondary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        // The hover highlight, also while the row's More has keyboard focus, so it's clear which song the menu is for.
        .background(Color.primary.opacity(hovering || moreFocused ? (scheme == .dark ? 0.07 : 0.05) : 0), in: RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous))
        .padding(.horizontal, -8)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        .onTapGesture(count: 2, perform: play)
        .help(namesAlbum ? SongVersions.helpLine(for: track) : "")
        .contextMenu { TrackMenu(track: track, namesAlbum: namesAlbum) }
        .mediaDraggable(.track(track))
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Play", play)
    }

    /// What the artwork button does, said as it is: it pauses or resumes only this song playing from this row's
    /// list (`togglesInPlace`); anywhere else it starts the list here.
    static func playLabel(title: String, togglesInPlace: Bool, isPlaying: Bool) -> String {
        guard togglesInPlace else { return "Play \(title)" }
        return isPlaying ? "Pause \(title)" : "Resume \(title)"
    }
}

/// A song's artists on one line in whole names: all of them when they fit, else fewer and "and more" ("HUNTR/X, EJAE
/// and more"), else the first name cut after a whole word (`FittedLine.variants(ofNames:)`). The width becomes the
/// variant's index in `onGeometryChange`, and the state is written only when that index changes (a few widths), not
/// on every frame of a resize or sidebar slide. The full list is the tooltip and the accessibility label.
struct FittedNames: View {
    let names: [String]
    /// The system font's regular weight at this size (the rows' `rowSecondary` is 13).
    let size: CGFloat
    @State private var variant = 0

    var body: some View {
        let variants = FittedLine.variants(ofNames: names)
        let full = variants.first ?? ""
        // The line's size never depends on the variant shown: a hidden one-line placeholder takes the room and the
        // text sits over it. Sized by its own text, a shorter variant could narrow the room it was picked for and
        // feed back into the layout of a resize.
        Text(verbatim: "A")
            .lineLimit(1)
            .hidden()
            .accessibilityHidden(true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Text(variants[min(variant, variants.count - 1)]).lineLimit(1)
            }
            .onGeometryChange(for: Int.self) { [names, size] geo in
                FittedLine.index(of: FittedLine.variants(ofNames: names), fitting: geo.size.width) { FittedLine.width($0, size: size) }
            } action: { variant = $0 }
            .help(variant > 0 ? full : "")
            .accessibilityLabel(full)
    }
}
