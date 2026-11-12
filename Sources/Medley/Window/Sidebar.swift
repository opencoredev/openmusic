import CoreTransferable
import MedleyCore
import SwiftUI

enum SidebarMetrics {
    /// The column's width until the listener drags it; the split view remembers a dragged width. One constant
    /// with the resize rules' arithmetic (`SplitViewTuning.sidebarIdealWidth`).
    nonisolated static let idealWidth: CGFloat = SplitViewTuning.sidebarIdealWidth
    /// Recently Played rows shown before Show More.
    static let recentsShown = 3
    /// Playlists shown under All Playlists before Show More, so a long list doesn't push Recently Played far down.
    static let playlistsShown = 10

    /// Whether a section of `count` rows folds behind Show More: only when that hides two or more rows. "Show 1 More"
    /// took a row to hide a row.
    static func foldsRows(_ count: Int, shown: Int) -> Bool { count >= shown + 2 }

    /// How many of a section's `count` rows draw: all of them when expanded or when Show More would hide just one.
    static func visibleRows(_ count: Int, shown: Int, expanded: Bool) -> Int {
        expanded || !foldsRows(count, shown: shown) ? count : shown
    }
}

/// The sidebar's collapsible sections. Each one's open or closed state is remembered under
/// `sidebar.expanded.<rawValue>`; every section starts open until the listener closes it.
enum SidebarSection: String, CaseIterable {
    case library, pinned, playlists, recents

    var defaultsKey: String { "sidebar.expanded.\(rawValue)" }
}

// A full-height translucent column like Music's and Finder's: Home and New, the library, the albums, playlists,
// artists and radios the listener pinned, the service's playlists, then what they played lately (signed out too;
// three rows until Show More), and the account at the bottom.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @AppStorage("sidebarShowsAllRecents") private var showsAllRecents = false
    @AppStorage("sidebarShowsAllPlaylists") private var showsAllPlaylists = false
    // Nil until the listener opens or closes the section (then the default applies).
    @AppStorage(SidebarSection.library.defaultsKey) private var libraryOpen: Bool?
    @AppStorage(SidebarSection.pinned.defaultsKey) private var pinnedOpen: Bool?
    @AppStorage(SidebarSection.playlists.defaultsKey) private var playlistsOpen: Bool?
    @AppStorage(SidebarSection.recents.defaultsKey) private var recentsOpen: Bool?

    var body: some View {
        @Bindable var model = model
        let collections = model.collections
        let pinned = model.sidebarPinned
        let recents = model.sidebarRecents
        List(selection: $model.sidebarSelection) {
            Section {
                ForEach(SidebarItem.browse, id: \.self) { item in
                    SidebarLabel(title: item.title, symbol: item.symbol).tag(item)
                }
                if model.libraryProviders.isEmpty {
                    // Signed out (or the filtered service has no library): one row under Home and New that opens the
                    // sign-in empty state, instead of six destinations that all lead there, and no "Library" header
                    // over a single "Library" row.
                    SidebarLabel(title: "Library", symbol: SidebarItem.libraryPlaceholderSymbol).tag(SidebarItem.recentlyAdded)
                }
            }

            // Library, Pinned, Playlists and Recently Played fold away with the system's disclosure chevron, shown
            // when the pointer is over the heading.
            if !model.libraryProviders.isEmpty {
                Section(isExpanded: expanded(.library)) {
                    ForEach(SidebarItem.library, id: \.self) { item in
                        if item == .likedSongs {
                            LikedSongsSidebarRow().tag(item)
                        } else {
                            SidebarLabel(title: item.title, symbol: item.symbol).tag(item)
                        }
                    }
                } header: { SidebarSectionHeader("Library") }
            }

            // Only pins on a service the filter shows; the section goes when none are left.
            if !pinned.isEmpty {
                Section(isExpanded: expanded(.pinned)) {
                    ForEach(pinned) { entry in
                        CollectionSidebarRow(entry: entry, isPinned: true)
                            .tag(SidebarItem.collection(entry.id))
                    }
                    .onMove { model.movePinned(fromVisible: $0, to: $1) }
                } header: { SidebarSectionHeader("Pinned") }
            }

            if !model.libraryProviders.isEmpty {
                let playlists = model.sidebarPlaylists
                Section(isExpanded: expanded(.playlists)) {
                    SidebarLabel(title: SidebarItem.allPlaylists.title, symbol: SidebarItem.allPlaylists.symbol)
                        .tag(SidebarItem.allPlaylists)
                    // The first ten, then Show More, like Recently Played; All Playlists has them all.
                    let visible = SidebarMetrics.visibleRows(playlists.count, shown: SidebarMetrics.playlistsShown, expanded: showsAllPlaylists)
                    ForEach(Array(playlists.prefix(visible))) { playlist in
                        PlaylistSidebarRow(playlist: playlist)
                            .tag(SidebarItem.playlist(playlist.provider, playlist.providerID))
                    }
                    if SidebarMetrics.foldsRows(playlists.count, shown: SidebarMetrics.playlistsShown) {
                        ShowMoreRow(expanded: $showsAllPlaylists, hidden: playlists.count - SidebarMetrics.playlistsShown,
                                    section: "Playlists", noun: "playlists")
                    }
                } header: { SidebarSectionHeader("Playlists") }
            }

            // Hidden only when everything played already has a row above (pinned, or under Playlists).
            if !recents.isEmpty || collections.recents.isEmpty {
                Section(isExpanded: expanded(.recents)) {
                    if collections.recents.isEmpty {
                        // Sidebar rows default to one line; this one wraps.
                        Text("Albums and playlists you play show up here.")
                            .font(.callout)
                            .foregroundStyle(.readableSecondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .modifier(LayoutProbe(key: "sidebar-recents-caption"))
                            .padding(.vertical, 2)
                            // A row's content starts 2 pt right of its section heading's text; this sentence reads as
                            // the heading's caption, so it starts on the heading's edge.
                            .padding(.leading, -2)
                            .selectionDisabled()
                    }
                    let visible = SidebarMetrics.visibleRows(recents.count, shown: SidebarMetrics.recentsShown, expanded: showsAllRecents)
                    ForEach(Array(recents.prefix(visible))) { entry in
                        CollectionSidebarRow(entry: entry, isPinned: false)
                            .tag(SidebarItem.collection(entry.id))
                    }
                    if SidebarMetrics.foldsRows(recents.count, shown: SidebarMetrics.recentsShown) {
                        ShowMoreRow(expanded: $showsAllRecents, hidden: recents.count - SidebarMetrics.recentsShown,
                                    section: "Recently Played", noun: "recently played items")
                    }
                } header: { SidebarSectionHeader("Recently Played") }
            }
        }
        .listStyle(.sidebar)
        .modifier(SidebarFooter { SidebarAccountFooter() })
        // A fixed minimum size for the column (see `DetailStack` in MainWindow.swift).
        .frame(minWidth: SplitViewTuning.sidebarMinWidth, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
        .navigationSplitViewColumnWidth(min: SplitViewTuning.sidebarMinWidth, ideal: SidebarMetrics.idealWidth, max: SplitViewTuning.sidebarMaxWidth)
        .onAppear {
            // After AppKit has made the list's table.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { SplitViewTuning.scrollSidebarHeadersAway(in: model.mainWindow) }
            revealSelection(model.sidebarSelection)
        }
        // The selected row is never hidden in a closed section: picking it some other way (a page's link, ⌘1…,
        // a playlist page) opens its section. Runs only when the selection changes.
        .onChange(of: model.sidebarSelection) { _, selection in revealSelection(selection) }
    }

    /// A section's open state: what the listener chose with the heading's chevron, else open. Long sections stay
    /// short through Show More instead of starting closed.
    private func expanded(_ section: SidebarSection) -> Binding<Bool> {
        let stored = storage(section)
        return Binding(get: { stored.wrappedValue ?? true }, set: { stored.wrappedValue = $0 })
    }

    private func storage(_ section: SidebarSection) -> Binding<Bool?> {
        switch section {
        case .library: $libraryOpen
        case .pinned: $pinnedOpen
        case .playlists: $playlistsOpen
        case .recents: $recentsOpen
        }
    }

    /// The section holding the selected row, if it is one of the collapsible ones.
    private func section(holding selection: SidebarItem?) -> SidebarSection? {
        switch selection {
        case .allPlaylists?, .playlist?: return .playlists
        case .collection(let id)?:
            if model.isPinnedInSidebar(id) { return .pinned }
            return model.sidebarRecents.contains(where: { $0.id == id }) ? .recents : nil
        case let item? where SidebarItem.library.contains(item) && !model.libraryProviders.isEmpty: return .library
        default: return nil
        }
    }

    private func revealSelection(_ selection: SidebarItem?) {
        guard let section = section(holding: selection) else { return }
        if !expanded(section).wrappedValue { storage(section).wrappedValue = true }
        // A Recently Played entry past the first few, or a playlist past the first ten, is behind Show More.
        if section == .recents, !showsAllRecents, case .collection(let id)? = selection,
           let index = model.sidebarRecents.firstIndex(where: { $0.id == id }),
           index >= SidebarMetrics.visibleRows(model.sidebarRecents.count, shown: SidebarMetrics.recentsShown, expanded: false) {
            showsAllRecents = true
        }
        if section == .playlists, !showsAllPlaylists, case .playlist(let provider, let id)? = selection,
           let index = model.sidebarPlaylists.firstIndex(where: { $0.provider == provider && $0.providerID == id }),
           index >= SidebarMetrics.visibleRows(model.sidebarPlaylists.count, shown: SidebarMetrics.playlistsShown, expanded: false) {
            showsAllPlaylists = true
        }
    }
}

/// A section heading ("Library", "Pinned"): the list's own heading font, in the opaque `readableSecondary` gray. The
/// system's heading color is a translucent tertiary label that the sidebar's material dims to about 2.5:1.
private struct SidebarSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).foregroundStyle(.readableSecondary)
            .modifier(LayoutProbe(key: "sidebar-header-\(title)"))
    }
}

/// "Show 7 More" / "Show Less" under Playlists and Recently Played, like the disclosure rows in Mail's and Finder's
/// sidebars: secondary text with a chevron, not selectable. The choice is remembered per section.
private struct ShowMoreRow: View {
    @Binding var expanded: Bool
    let hidden: Int
    /// The section's name, for VoiceOver.
    let section: String
    /// What the hidden rows are, for the tooltip.
    let noun: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(Motion.Expansion.sidebarShowMore.animation(reduce: reduceMotion)) { expanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(expanded ? "Show Less" : "Show \(hidden) More")
                DisclosureChevron(open: expanded)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.readableSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .selectionDisabled()
        .help(expanded ? "Show fewer \(noun)" : "Show \(hidden) more \(noun)")
        .accessibilityLabel(expanded ? "Show Less" : "Show \(hidden) More")
        .accessibilityHint(section)
    }
}

/// The account row pinned under the sidebar list. On macOS 26 and later it is a safe-area bar, so rows
/// scrolling beneath it fade out under the scroll edge effect instead of showing through it.
private struct SidebarFooter<Footer: View>: ViewModifier {
    @ViewBuilder var footer: Footer
    /// The list is scrolled away from its top.
    @State private var scrolled = false
    /// Rows continue below the account bar (the list isn't scrolled to its end).
    @State private var moreBelow = false
    /// The list's top content inset (the title bar and the search field, about 98 pt): where its mask starts. AppKit
    /// sets it, so SwiftUI's safe area doesn't carry it; read from the scroll geometry when it changes.
    @State private var topInset: CGFloat = 0
    /// The list's bottom content inset: the account bar's height, where the mask ends.
    @State private var bottomInset: CGFloat = 0

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // Top: the system search field isn't a bar to the soft effect, which ended at the title bar and left
            // half-rows crisp right under the field (a clear safe-area bar under the field didn't change that). The
            // hard one ends at the field's bottom, but cut rows in half against its hairline and still let faint
            // rows through behind the traffic lights. (`.searchable(placement: .sidebar)` is AppKit's field, so it
            // can't move into a `safeAreaBar` without giving up its suggestions, ⌘F and the collapsed-sidebar
            // search.) So the list is masked: nothing of it draws above the field's safe-area line (the hairline
            // and the hard edge's band included), and once scrolled its first 12 pt fade in, so no row ends on a
            // line. At rest the mask is solid below the line and the soft edge draws nothing.
            // Bottom: the soft edge (the hard one cut the last row through its letters on a hairline over the
            // account bar), and the same mask in mirror: nothing of the list draws under the bar (with the soft edge
            // alone, row text showed faintly behind it), and while rows continue below, the last 12 pt above the bar
            // fade out, so the last row never ends on a line.
            content
                .mask { SidebarEdgeMask(top: topInset, scrolled: scrolled, bottom: bottomInset, moreBelow: moreBelow) }
                .safeAreaBar(edge: .bottom, spacing: 0) { footer.modifier(LayoutProbe(key: "sidebar-footer")) }
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .scrollEdgeEffectStyle(scrolled ? .hard : .soft, for: .top)
                // A Bool, so the action (and `scrolled`) runs only when the list crosses its top, not on every
                // scrolled point.
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y + geo.contentInsets.top > 1
                } action: { _, isScrolled in
                    scrolled = isScrolled
                    if LayoutProbe.enabled { DebugProbes.note("sidebar-top-edge", isScrolled ? "shown" : "hidden") }
                }
                // Likewise only when the list reaches or leaves its end.
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y + geo.containerSize.height - geo.contentInsets.bottom < geo.contentSize.height - 1
                } action: { _, below in
                    moreBelow = below
                    if LayoutProbe.enabled { DebugProbes.note("sidebar-bottom-edge", below ? "fading" : "at the end") }
                }
                // Only when an inset changes (window setup, full screen), never per scrolled point.
                .onScrollGeometryChange(for: EdgeInsets.self) { geo in
                    EdgeInsets(top: geo.contentInsets.top.rounded(), leading: 0, bottom: geo.contentInsets.bottom.rounded(), trailing: 0)
                } action: { _, insets in
                    topInset = insets.top
                    bottomInset = insets.bottom
                }
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) { footer.background(.bar) }
        }
    }
}

/// The sidebar list's mask: clear above the list's top content inset (the title bar and the search field), then,
/// once the list is scrolled, a 12 pt eased fade, then solid; at the bottom the same in mirror, clear under the
/// account bar (the bottom inset) and, while rows continue below, a 12 pt fade above it. It changes only when
/// `scrolled` or `moreBelow` flips (the list crossing its top or reaching its end) or an inset changes, never per
/// scrolled point.
private struct SidebarEdgeMask: View {
    let top: CGFloat
    let scrolled: Bool
    let bottom: CGFloat
    let moreBelow: Bool
    static let fade: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Color.clear.frame(height: top)
                ZStack {
                    // Eased (about t²), so the first few points are nearly clear: no text right under the field.
                    LinearGradient(stops: Self.easedStops, startPoint: .top, endPoint: .bottom)
                    Color.black.opacity(scrolled ? 0 : 1)
                }
                .frame(height: Self.fade)
                Color.black
                ZStack {
                    LinearGradient(stops: Self.easedStops, startPoint: .bottom, endPoint: .top)
                    Color.black.opacity(moreBelow ? 0 : 1)
                }
                .frame(height: Self.fade)
                Color.clear.frame(height: bottom)
            }
            .onChange(of: [top, bottom], initial: true) { _, insets in
                if LayoutProbe.enabled {
                    DebugProbes.note("sidebar-mask", "mask clear above \(insets[0]) pt and in the bottom \(insets[1]) pt, list frame \(geo.frame(in: .global))")
                }
            }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.15), value: scrolled)
        .animation(.easeOut(duration: 0.15), value: moreBelow)
        .allowsHitTesting(false)
    }

    private static let easedStops: [Gradient.Stop] = [
        .init(color: .black.opacity(0), location: 0),
        .init(color: .black.opacity(0.06), location: 0.25),
        .init(color: .black.opacity(0.25), location: 0.5),
        .init(color: .black.opacity(0.56), location: 0.75),
        .init(color: .black, location: 1),
    ]
}

/// Like Music's: the account's picture and name (or "Sign In"), opening Settings › Accounts. With two
/// services signed in, a small menu beside it picks which one's music shows.
private struct SidebarAccountFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let accounts = model.providers.compactMap { provider -> AccountInfo? in
            if case .signedIn(let info) = provider.authStatus { info } else { nil }
        }
        let filter = accounts.count >= 2 ? model.serviceFilter : .all
        HStack(spacing: 4) {
            Button {
                model.requestSettings(.accounts)
                openSettings()
            } label: {
                HStack(spacing: 8) {
                    AccountAvatar(account: accounts.first)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(accounts.first?.name ?? "Sign In")
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        // A filter in use says so beside its icon, so a page missing one service's music explains
                        // itself ("YouTube Music only").
                        if accounts.isEmpty {
                            // Which sign-in this is: the music services', not the OpenMusic sync account's.
                            Text("YouTube Music or Spotify")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.readableSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        } else if filter.provider != nil {
                            Text(filter.onlyTitle)
                                .font(.system(size: 11, weight: .medium))
                                // Readable gray (4.5:1 on the sidebar); the filled accent icon beside it carries the color.
                                .foregroundStyle(.readableSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .modifier(LayoutProbe(key: "service-filter-label"))
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(SidebarFooterButtonStyle())
            .help(accounts.isEmpty ? "Sign in to YouTube Music or Spotify" : "Accounts")
            .accessibilityLabel(accounts.isEmpty ? "Sign in to YouTube Music or Spotify" : "Accounts, \(accounts.map(\.name).joined(separator: ", "))")
            .accessibilityValue(filter.provider == nil ? "" : filter.onlyTitle)

            if accounts.count >= 2 { ServiceFilterMenu() }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }
}

private struct AccountAvatar: View {
    let account: AccountInfo?

    var body: some View {
        if let account, let artwork = Artwork(url: account.avatar) {
            ArtworkView(artwork: artwork, size: 24, circle: true, symbol: "person.fill")
                .frame(width: 24, height: 24)
        } else if let account {
            // Initials, like Music's account row.
            Text(Self.initials(account.name))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.gray))
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
    }

    static func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

/// A quiet rounded highlight on hover and press, like a sidebar row.
private struct SidebarFooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FooterButtonBody(configuration: configuration)
    }

    private struct FooterButtonBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(.primary)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : hovering ? 0.06 : 0))
                }
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// All / YouTube Music / Spotify, as a small menu (only with both services signed in).
private struct ServiceFilterMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let filtered = model.serviceFilter != .all
        Menu {
            Picker("Show Music From", selection: $model.serviceFilter) {
                ForEach(ServiceFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: filtered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 15))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(IconButtonStyle(tint: filtered ? .accentColor : .secondary))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Showing music from \(model.serviceFilter.title)")
        .accessibilityLabel("Show music from")
        .accessibilityValue(model.serviceFilter.title)
    }
}

/// Sidebar symbols in the accent color, like Music on macOS 26 (Search, Home, Library rows), selected or not; white on
/// an accent-filled (emphasized) selection, like the row's text.
///
/// Every symbol sits in the same 20 pt box at the medium scale, so rows with wide, tall or short symbols (the grid,
/// the music note, the clock) are the same height and their titles start at the same x.
private struct SidebarIcon: View {
    let symbol: String
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Image(systemName: symbol)
            .imageScale(.medium)
            .frame(width: 20, height: 20)
            .foregroundStyle(prominence == .increased ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
    }
}

private struct SidebarLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            SidebarIcon(symbol: symbol)
        }
    }
}

/// A pinned or recently played album, playlist, artist or radio: 24 pt artwork (round for artists) and the title;
/// what it is ("Album · Daft Punk") shows in the tooltip. Hovering the row puts a play button on the artwork; the rest of the row opens
/// the page.
private struct CollectionSidebarRow: View {
    let entry: SidebarEntry
    let isPinned: Bool
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Label {
            // One line, like Music's Pins and the Playlists rows, so every row is the same height. What it is
            // ("Album · Taylor Swift") is in the tooltip and VoiceOver's label; the artwork's shape (round for an
            // artist) shows the kind at a glance.
            Text(entry.title)
                .lineLimit(1)
                .accessibilityLabel("\(entry.title), \(entry.detail)")
        } icon: {
            SidebarPlayArtwork(artwork: entry.artwork, circle: entry.isArtist, symbol: symbol, title: entry.title,
                               context: playContext.map { AppModel.PlayingFrom(title: entry.title, route: $0) },
                               pending: AppModel.playRequestKey(for: entry), rowHovered: hovering) {
                if let playContext { model.playOrPause(playContext) { model.play(entry) } } else { model.play(entry) }
            }
        }
        .modifier(SidebarRowHover(hovering: $hovering))
        .modifier(SidebarPlaylistDrop(playlist: editablePlaylist))
        .help("\(entry.title) · \(entry.detail)")
        .contextMenu { menu }
        .modifier(SidebarRowDrag(item: entry.mediaItem))
    }

    /// A pinned playlist of the listener's own takes dropped songs, as under Playlists.
    private var editablePlaylist: Playlist? {
        if case .item(.playlist(let p)) = entry, p.isEditable { p } else { nil }
    }

    /// The collection a queue started from this row would come from, so its button can pause and resume in place.
    /// A radio plays a fresh station each time, so it has none.
    private var playContext: Route? {
        if case .item = entry { entry.route } else { nil }
    }

    private var symbol: String {
        switch entry {
        case .item(.artist): "music.mic"
        case .item(.playlist): "music.note.list"
        case .radio: "dot.radiowaves.left.and.right"
        default: "square.stack"
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Play", systemImage: "play") { model.play(entry) }
        Divider()
        if isPinned {
            Button("Unpin from Sidebar", systemImage: "pin.slash") { model.unpinFromSidebar(entry.id) }
            // Among the pins the service filter shows.
            let pinned = model.sidebarPinned
            let index = pinned.firstIndex(of: entry)
            Button("Move Up", systemImage: "arrow.up") { model.movePinned(entry.id, by: -1) }
                .disabled(index == nil || index == 0)
            Button("Move Down", systemImage: "arrow.down") { model.movePinned(entry.id, by: 1) }
                .disabled(index == nil || index == pinned.count - 1)
        } else {
            Button("Pin to Sidebar", systemImage: "pin") { model.pinToSidebar(entry) }
            Button("Remove from Recently Played", systemImage: "minus.circle") { model.removeFromRecentlyPlayed(entry.id) }
        }
    }
}

private struct PlaylistSidebarRow: View {
    let playlist: Playlist
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let route = Route.playlist(playlist.provider, id: playlist.providerID, preview: playlist)
        Label {
            Text(playlist.title).lineLimit(1)
        } icon: {
            SidebarPlayArtwork(artwork: playlist.artwork, circle: false, symbol: "music.note.list", title: playlist.title,
                               context: AppModel.PlayingFrom(title: playlist.title, route: route),
                               pending: .collection(MediaItem.playlist(playlist).id, shuffled: false), rowHovered: hovering) {
                model.playOrPause(route) { model.play(.playlist(playlist)) }
            }
        }
        .modifier(SidebarRowHover(hovering: $hovering))
        .modifier(SidebarPlaylistDrop(playlist: playlist.isEditable ? playlist : nil))
        .help(playlist.title)
        .contextMenu { CollectionMenu(item: .playlist(playlist)) }
        .modifier(SidebarRowDrag(item: .playlist(playlist)))
    }
}

/// Library › Liked Songs, with the play button collection rows have: its heart (in the 20 pt slot every library symbol
/// sits in) turns into a round Play button (an accent disc with a white triangle, darker while pressed) while the row is
/// hovered or the button has keyboard focus, and into the now-playing bars while Liked Songs plays (Pause on the disc
/// under the pointer). The button plays both services' likes in the page's order
/// (`AppModel.playLikedSongs`) or pauses and resumes them; the rest of the row opens the page.
private struct LikedSongsSidebarRow: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let item = SidebarItem.likedSongs
        Label {
            Text(item.title)
        } icon: {
            SidebarPlaySymbol(symbol: item.symbol, title: item.title, context: AppModel.likedSongsContext, pending: .likedSongs, rowHovered: hovering) {
                model.playOrPause(AppModel.likedSongsContext) { model.playLikedSongs() }
            }
        }
        .modifier(SidebarRowHover(hovering: $hovering))
    }
}

/// A sidebar symbol (20 pt, like `SidebarIcon`) that is also a play button: the symbol at rest; when revealed, a
/// 20 pt accent disc in its place with a white Play or Pause (or the loading spinner), as `play.circle.fill` draws it,
/// so it reads as a button the way the artwork rows' dimmed cover does; the now-playing bars while its list plays. On
/// an emphasized (accent) selection the disc turns white with an accent glyph.
private struct SidebarPlaySymbol: View {
    let symbol: String
    let title: String
    let context: AppModel.PlayingFrom
    /// The play request this button starts, for its loading spinner.
    let pending: AppModel.PlayRequestKey
    let rowHovered: Bool
    let play: () -> Void

    @FocusState private var focused: Bool
    /// A 28 pt target around the 20 pt symbol, as the artwork rows have around theirs.
    static let hitOutset: CGFloat = 4

    var body: some View {
        Button(action: play) {
            SidebarPlayGlyph(context: context, pending: pending, style: .symbol(symbol), revealed: rowHovered || focused)
                .frame(width: 20, height: 20)
                .modifier(LayoutProbe(key: "sidebar-play-symbol-\(title)"))
                .padding(.vertical, Self.hitOutset)
                .padding(.trailing, Self.hitOutset * 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(SidebarPlayStyle(scales: false))
        .padding(.vertical, -Self.hitOutset)
        .padding(.trailing, -Self.hitOutset * 2)
        .focused($focused)
        .modifier(SidebarPlayLabel(context: context, pending: pending, title: title))
        .modifier(FocusProbe(key: "sidebar-play-\(title)"))
    }
}

/// A sidebar row as a drag source. Through the list's own `itemProvider`, not `.draggable`: the outline view runs
/// row drags itself (Pinned reorders with them), and draws the row (artwork and title) as the drag image.
private struct SidebarRowDrag: ViewModifier {
    let item: MediaItem?

    func body(content: Content) -> some View {
        if let item {
            content.itemProvider {
                let provider = NSItemProvider()
                provider.register(MediaDragItem(item))
                return provider
            }
        } else {
            content
        }
    }
}

/// Songs, albums or playlists dropped on one of the listener's playlists are appended to it (`AppModel.drop(_:on:)`,
/// which confirms "Added to …"). While a drag hovers the row it gets an accent outline and tint, like Music's.
private struct SidebarPlaylistDrop: ViewModifier {
    let playlist: Playlist?
    @Environment(AppModel.self) private var model
    @State private var targeted = false

    func body(content: Content) -> some View {
        if let playlist {
            content
                .background {
                    if targeted {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor.opacity(0.18))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2))
                            .padding(.horizontal, -6)
                            .padding(.vertical, -3)
                            .allowsHitTesting(false)
                    }
                }
                .dropDestination(for: MediaDragItem.self) { items, _ in
                    if LayoutProbe.enabled { DebugProbes.note("sidebar-drop", "\(items.count) on \(playlist.title)") }
                    return model.drop(items, on: playlist)
                } isTargeted: { inside in
                    if targeted != inside { targeted = inside }
                }
                .modifier(DropPreviewProbe { key in targeted = key == "playlist:\(playlist.id)" })
        } else {
            content
        }
    }
}

/// Tracks the pointer over the whole row, label and empty space alike. Only a change of hover writes state, so a row
/// the pointer isn't on does no work, and nothing here takes part in layout.
private struct SidebarRowHover: ViewModifier {
    @Binding var hovering: Bool

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { inside in
                if hovering != inside { hovering = inside }
            }
    }
}

/// The row's 24 pt artwork with a play button on it, like Music's sidebar: hidden until the row is hovered or the
/// button has keyboard focus. For the collection that's playing it shows animated bars, which turn into Pause
/// under the pointer (Play when paused). Clicking it plays; the rest of the row opens the page.
private struct SidebarPlayArtwork: View {
    let artwork: Artwork?
    let circle: Bool
    let symbol: String
    let title: String
    /// The collection this row plays, matched against what's playing. Nil for a radio.
    let context: AppModel.PlayingFrom?
    /// The play request this button starts, for its loading spinner.
    let pending: AppModel.PlayRequestKey
    let rowHovered: Bool
    let play: () -> Void

    @FocusState private var focused: Bool
    static let hitOutset: CGFloat = 2

    var body: some View {
        Button(action: play) {
            ZStack {
                ArtworkView(artwork: artwork, size: 24, cornerRadius: 4, circle: circle, symbol: symbol)
                    .frame(width: 24, height: 24)
                SidebarPlayGlyph(context: context, pending: pending, style: .artwork(circle: circle), revealed: rowHovered || focused)
            }
            .frame(width: 24, height: 24)
            // A 28 pt target around the 24 pt artwork: 2 pt above and below and 4 pt toward the title take clicks but
            // take no room, so the row's layout and the artwork's size are unchanged. Not toward the leading side:
            // the list row's cell starts at the artwork's leading edge, so clicks there never reach the button.
            .padding(.vertical, Self.hitOutset)
            .padding(.trailing, Self.hitOutset * 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarPlayStyle())
        .padding(.vertical, -Self.hitOutset)
        .padding(.trailing, -Self.hitOutset * 2)
        .focused($focused)
        .modifier(SidebarPlayLabel(context: context, pending: pending, title: title))
        .modifier(FocusProbe(key: "sidebar-play-\(title)"))
    }
}

/// "Play <title>", or Pause/Resume for the collection that's playing. Its own view so only it reads the player.
private struct SidebarPlayLabel: ViewModifier {
    let context: AppModel.PlayingFrom?
    let pending: AppModel.PlayRequestKey
    let title: String
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let current = context.map { model.isCurrentContext($0) } ?? false
        let loading = model.isPlayPending(pending)
        content
            .accessibilityLabel(loading ? "Loading \(title)" : current ? (model.player.isPlaying ? "Pause \(title)" : "Resume \(title)") : "Play \(title)")
            .help(loading ? "Loading \(title)…" : current ? (model.player.isPlaying ? "Pause" : "Resume") : "Play \(title)")
    }
}

/// The play button's face. On artwork: nothing at rest, a dimmed cover with Play (or Pause) when revealed, and the
/// now-playing bars on the collection that's playing. On a symbol (Liked Songs): the symbol at rest, and in its place a
/// filled disc carrying the same glyphs (the bars stay unbacked, in the symbol's accent). Reads the player itself, so other rows don't redraw when playback starts or stops, and never
/// reads the playback time.
private struct SidebarPlayGlyph: View {
    enum Style {
        case artwork(circle: Bool)
        case symbol(String)
    }

    let context: AppModel.PlayingFrom?
    /// The request the button starts: while it loads, a small spinner takes the glyph's place (`AppModel.pendingPlay`).
    let pending: AppModel.PlayRequestKey
    let style: Style
    let revealed: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.sidebarPlayPressed) private var pressed

    var body: some View {
        let current = context.map { model.isCurrentContext($0) } ?? false
        let loading = model.isPlayPending(pending)
        let visible = revealed || current || loading
        Group {
            switch style {
            case .artwork(let circle):
                let shape = circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                ZStack {
                    shape.fill(.black.opacity(0.45))
                    if loading {
                        SidebarPlaySpinner(light: true)
                    } else {
                        glyph(current: current, tint: .white, size: 10, barsScale: 0.75)
                    }
                }
                .frame(width: 24, height: 24)
                .opacity(visible ? 1 : 0)
            case .symbol(let symbol):
                let selected = prominence == .increased
                let tint = selected ? Color.white : Color.accentColor
                // The bars alone mark the playing list; Play, Pause and the spinner sit on the disc.
                let bars = current && !revealed && !loading
                ZStack {
                    Image(systemName: symbol)
                        .imageScale(.medium)
                        .foregroundStyle(tint)
                        .opacity(visible ? 0 : 1)
                    Group {
                        if bars {
                            glyph(current: current, tint: tint, size: 12, barsScale: 0.9)
                        } else {
                            ZStack {
                                Circle().fill(SidebarPlayDisc.fill(selected: selected, pressed: pressed))
                                if loading {
                                    // White spokes on the accent disc, dark ones on the selection's white disc.
                                    SidebarPlaySpinner(light: !selected)
                                        .environment(\.colorScheme, selected ? .light : .dark)
                                        .scaleEffect(0.85)
                                } else {
                                    glyph(current: current, tint: selected ? Color.accentColor : .white, size: 8.5, barsScale: 0.9)
                                        // The triangle's weight sits left of its box: nudged to look centered.
                                        .offset(x: current && model.player.isPlaying ? 0 : 0.75)
                                }
                            }
                            // 18 pt, the optical size of the 20 pt slot's symbols (a full 20 pt disc looked a size up).
                            .frame(width: 18, height: 18)
                            .modifier(LayoutProbe(key: "sidebar-play-disc"))
                        }
                    }
                    .opacity(visible ? 1 : 0)
                }
                .frame(width: 20, height: 20)
            }
        }
        .animation(Motion.hover, value: visible)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func glyph(current: Bool, tint: Color, size: CGFloat, barsScale: CGFloat) -> some View {
        if current && !revealed {
            NowPlayingIndicator(tint: tint)
                .scaleEffect(barsScale)
        } else {
            Image(systemName: current && model.player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
        }
    }
}

/// The spinner a sidebar play button shows while its request loads: AppKit's small indeterminate indicator (animated
/// by AppKit, not by SwiftUI frames), light on a dimmed cover or an emphasized selection.
private struct SidebarPlaySpinner: View {
    /// Light spokes (on a dimmed cover or the accent selection); otherwise the appearance's own.
    let light: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .scaleEffect(0.8)
            .frame(width: 16, height: 16)
            .environment(\.colorScheme, light ? .dark : scheme)
            .modifier(LayoutProbe(key: "sidebar-play-spinner"))
    }
}

/// The Liked Songs play disc's fill: the accent, a shade darker while pressed (as a pressed `play.circle.fill`
/// button); white on the accent selection, dimmed while pressed.
enum SidebarPlayDisc {
    static func fill(selected: Bool, pressed: Bool) -> Color {
        if selected { return Color.white.opacity(pressed ? 0.75 : 1) }
        return pressed ? Color.accentColor.mix(with: .black, by: 0.25) : Color.accentColor
    }
}

extension EnvironmentValues {
    /// The sidebar play button is held down (`SidebarPlayStyle`), for the disc's pressed fill.
    @Entry var sidebarPlayPressed = false
}

private struct SidebarPlayStyle: ButtonStyle {
    /// The artwork's button shrinks while pressed; the disc darkens instead (and keeps its 20 pt slot).
    var scales = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .motionScale(scales && configuration.isPressed ? 0.9 : 1)
            .environment(\.sidebarPlayPressed, configuration.isPressed)
            .animation(Motion.press, value: configuration.isPressed)
    }
}
