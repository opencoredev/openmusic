import AppKit
import OpenMusicCore
import SwiftUI

/// Library sections: shows only services that are signed in and have a library.
struct LibraryPage: View {
    let item: SidebarItem
    @Environment(AppModel.self) private var model

    private var kind: LibraryKind {
        switch item {
        case .songs: .songs
        case .likedSongs: .likedSongs
        case .recentlyPlayed: .recentlyPlayed
        case .albums: .albums
        case .artists: .artists
        default: .playlists
        }
    }

    var body: some View {
        let providers = model.libraryProviders
        Group {
            if providers.isEmpty {
                EmptyStateView(
                    // The sidebar shows one "Library" row then (`Sidebar`); its page uses the same symbol.
                    symbol: item == .recentlyAdded ? SidebarItem.libraryPlaceholderSymbol : item.symbol,
                    title: model.anySignedIn ? "No library for \(model.serviceFilter.title)" : "Your library lives here",
                    message: model.anySignedIn ? "Sign in to this service, or switch the service filter." : "Sign in to YouTube Music or Spotify to see your songs, albums and playlists."
                ) {
                    // The page's one action, in the accent style Settings › Accounts uses for Sign In: the filtered
                    // service's own sign-in, else Settings › Accounts, else (signed out) a menu of both services.
                    switch AccountAction.forEmptyLibrary(model) {
                    case .signIn(let id):
                        Button("Sign In to \(id.displayName)…") { model.perform(.signIn(id)) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .modifier(LayoutProbe(key: "library-account-action"))
                    case .openAccounts:
                        Button("Open Accounts…") { model.perform(.openAccounts) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .modifier(LayoutProbe(key: "library-account-action"))
                    case nil:
                        SignInMenu(prominent: true)
                    }
                }
            } else {
                LibraryFeed(kind: kind, includeAlbumsAndPlaylists: item == .recentlyAdded, providers: providers) { items, status, issues in
                    content(items, status: status, issues: issues)
                }
                .id("\(item)-\(providers.map(\.id.rawValue).joined())-\(model.refreshTick)")
            }
        }
        .pageBackground()
        .navigationTitle(item.title)
    }

    @ViewBuilder
    private func content(_ items: [MediaItem], status: LibraryLoader.Status, issues: LibraryIssueList) -> some View {
        let tracks = items.compactMap { if case .track(let t) = $0 { t } else { nil } }
        if items.isEmpty, status != .loading {
            if issues.issues.isEmpty {
                EmptyStateView(symbol: item.symbol, title: emptyTitle, message: emptyMessage)
            } else {
                // Nothing to show because a service failed: say which, never "No songs yet".
                LibraryFailureState(issues: issues)
            }
        } else if !tracks.isEmpty, tracks.count == items.count {
            SongsTable(title: item.title, tracks: tracks, isComplete: status != .loading, banner: issues.issues.isEmpty ? nil : AnyView(issues))
        } else {
            ScrollPage(title: item.title) {
                if !issues.issues.isEmpty { issues.padding(.horizontal, Metrics.pageInset) }
                MediaGrid(items: items)
                if status == .loading { GridSkeleton().padding(.top, -40) }
            }
        }
    }

    private var emptyTitle: String {
        switch item {
        case .likedSongs: "No liked songs yet"
        case .recentlyPlayed: "Nothing played yet"
        case .artists: "No artists yet"
        case .albums: "No albums yet"
        default: "Nothing here yet"
        }
    }

    private var emptyMessage: String {
        switch item {
        case .likedSongs: "Songs you like on any service show up here. Right-click a song and choose Like."
        case .recentlyPlayed: "Songs you play show up here."
        default: "Add music to your library and it will show up here."
        }
    }
}

/// Loads a library list through `LibraryLoader`, showing what was saved at once and the first pages as soon as they
/// arrive.
private struct LibraryFeed<Content: View>: View {
    let kind: LibraryKind
    var includeAlbumsAndPlaylists = false
    let providers: [any MusicProvider]
    @ViewBuilder var content: (_ items: [MediaItem], _ status: LibraryLoader.Status, _ issues: LibraryIssueList) -> Content

    @Environment(AppModel.self) private var model
    @State private var loader: LibraryLoader?

    var body: some View {
        Group {
            if let loader, let items = loader.items {
                content(items, loader.status, LibraryIssueList(issues: loader.issues, noun: noun, loader: loader))
            } else if kind == .songs || kind == .likedSongs || kind == .recentlyPlayed {
                VStack(alignment: .leading, spacing: 18) {
                    SkeletonBlock(width: 200, height: 28)
                    TrackListSkeleton(rows: 12)
                }
                .padding(Metrics.pageInset)
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                GridSkeleton(circle: kind == .artists)
            }
        }
        .task {
            let loader = loader ?? LibraryLoader(
                kinds: includeAlbumsAndPlaylists ? [.albums, .playlists] : [kind],
                listName: includeAlbumsAndPlaylists ? "recent" : kind.rawValue,
                providers: providers, cache: model.cache
            )
            self.loader = loader
            await loader.load()
        }
        .onDisappear { loader?.cancel() }
    }

    /// What the list holds, for "Couldn't load your Spotify songs".
    private var noun: String {
        if includeAlbumsAndPlaylists { return "albums and playlists" }
        return switch kind {
        case .songs: "songs"
        case .likedSongs: "liked songs"
        case .recentlyPlayed: "recently played songs"
        case .albums: "albums"
        case .artists: "artists"
        case .playlists: "playlists"
        }
    }
}

/// One note per service whose part of the list is missing or cut short, above the list: what's missing in the
/// service's name ("Couldn't load your Spotify songs") and the one action that can help: Try Again, Sign In to the
/// service when its sign-in is gone, or Load More after the page limit.
struct LibraryIssueList: View {
    let issues: [LibraryLoader.Issue]
    let noun: String
    let loader: LibraryLoader

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(issues) { LibraryIssueBanner(issue: $0, noun: noun, loader: loader) }
        }
    }
}

private struct LibraryIssueBanner: View {
    let issue: LibraryLoader.Issue
    let noun: String
    let loader: LibraryLoader
    @Environment(AppModel.self) private var model

    var body: some View {
        let service = issue.provider.displayName
        HStack(spacing: 10) {
            ServiceGlyph(provider: issue.provider, size: 16, always: true)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(issue, noun: noun)).font(.headline)
                Text(Self.detail(issue, noun: noun)).font(.callout).foregroundStyle(.readableSecondary).lineLimit(2)
            }
            Spacer(minLength: 12)
            Group {
                if issue.kind == .more {
                    Button("Load More") { loader.loadMore(issue.provider) }
                } else if issue.needsSignIn {
                    Button("Sign In to \(service)…") { model.perform(.signIn(issue.provider)) }
                } else {
                    Button("Try Again") { loader.retry(issue.provider) }
                }
            }
            .modifier(LayoutProbe(key: "library-issue-action-\(issue.provider.rawValue)"))
        }
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .modifier(LayoutProbe(key: "library-issue-\(issue.provider.rawValue)"))
        .onAppear {
            if LayoutProbe.enabled { DebugProbes.note("library-issue-\(issue.provider.rawValue)", "\(Self.title(issue, noun: noun)) | \(Self.detail(issue, noun: noun))") }
        }
    }

    /// "Couldn't load your Spotify songs", "Couldn't refresh…", "Couldn't load all…", "Showing your first 10,000…".
    static func title(_ issue: LibraryLoader.Issue, noun: String) -> String {
        let service = issue.provider.displayName
        return switch issue.kind {
        case .failed: "Couldn’t load your \(service) \(noun)"
        case .notRefreshed: "Couldn’t refresh your \(service) \(noun)"
        case .partial: "Couldn’t load all your \(service) \(noun)"
        case .more: "Showing your first \(issue.shown.formatted()) \(service) \(noun)"
        }
    }

    static func detail(_ issue: LibraryLoader.Issue, noun: String) -> String {
        let reason = issue.message.map { " \($0)" } ?? ""
        return switch issue.kind {
        case .failed: (issue.message ?? "Something went wrong.") + (issue.needsSignIn ? "" : " The rest of your library is below.")
        case .notRefreshed: "Showing the \(issue.shown.formatted()) saved earlier.\(reason)"
        case .partial: "Showing the first \(issue.shown.formatted()).\(reason)"
        case .more: "\(issue.provider.displayName) has more. Load them when you need them."
        }
    }
}

/// Nothing on the page because services failed: the first issue's words, and its action for each service.
private struct LibraryFailureState: View {
    let issues: LibraryIssueList
    @Environment(AppModel.self) private var model

    var body: some View {
        let first = issues.issues[0]
        let signIn = issues.issues.allSatisfy(\.needsSignIn)
        EmptyStateView(
            symbol: signIn ? "person.crop.circle" : "wifi.exclamationmark",
            title: issues.issues.count == 1 ? LibraryIssueBanner.title(first, noun: issues.noun) : "Couldn’t load your \(issues.noun)",
            message: first.message ?? "Something went wrong."
        ) {
            HStack(spacing: 10) {
                ForEach(issues.issues) { issue in
                    let service = issue.provider.displayName
                    let suffix = issues.issues.count == 1 ? "" : " (\(service))"
                    Group {
                        if issue.needsSignIn {
                            Button("Sign In to \(service)…") { model.perform(.signIn(issue.provider)) }
                        } else {
                            Button("Try Again\(suffix)") { issues.loader.retry(issue.provider) }
                        }
                    }
                    .controlSize(.large)
                    .modifier(LayoutProbe(key: "library-issue-action-\(issue.provider.rawValue)"))
                }
            }
        }
        .onAppear {
            if LayoutProbe.enabled {
                for issue in issues.issues {
                    DebugProbes.note("library-issue-\(issue.provider.rawValue)", "\(LibraryIssueBanner.title(issue, noun: issues.noun)) | \(issue.message ?? "")")
                }
            }
        }
    }
}

extension Track {
    var albumTitle: String { album?.title ?? "" }
    var durationValue: Double { duration ?? 0 }
    var serviceName: String { provider.displayName }
}

/// The Songs list: a native sortable table, like Apple Music's Songs view, with a "Find in Songs" field that narrows
/// it to the songs whose title, artist or album match. Column sorting applies to the matches, and Play, Shuffle and
/// double-click play the rows in the order shown.
struct SongsTable: View {
    let title: String
    let tracks: [Track]
    var isComplete = true
    /// Notes over the list (a service that didn't load), under the title row.
    var banner: AnyView? = nil

    @Environment(AppModel.self) private var model
    @State private var selection = Set<Track.ID>()
    @State private var sortOrder: [KeyPathComparator<Track>] = []
    @State private var query = ""

    /// How far in from the table's edge the inset style draws a selected row.
    static let selectionInset: CGFloat = 10

    var body: some View {
        let filtering = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let matches = filtering ? TrackFilter.matches(tracks, query: query).map { tracks[$0] } : tracks
        let sorted = sortOrder.isEmpty ? matches : matches.sorted(using: sortOrder)
        let currentID = model.player.current?.id
        let context = AppModel.PlayingFrom(title: title)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(title).font(.pageTitle)
                    Text(countLabel(shown: sorted.count, filtering: filtering))
                        .font(.callout)
                        .foregroundStyle(.readableSecondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 12)
                TrackFilterField(text: $query, prompt: "Find in \(title)")
                SongsPlayButtons(title: title, tracks: sorted, context: context)
            }
            .padding(.horizontal, Metrics.pageInset)
            .padding(.top, 20)
            .padding(.bottom, 14)

            if let banner {
                banner
                    .padding(.horizontal, Metrics.pageInset)
                    .padding(.bottom, 12)
            }

            if sorted.isEmpty, filtering {
                NoFilterMatches(query: query) { query = "" }
                    .padding(.horizontal, Metrics.pageInset - 10)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                table(sorted, currentID: currentID, context: context)
            }
        }
        // A selection the filter hides isn't acted on by Return or the context menu.
        .onChange(of: query) {
            let shown = Set(sorted.map(\.id))
            if !selection.isSubset(of: shown) { selection = selection.intersection(shown) }
        }
    }

    /// Whether the Service column shows: only when the list's songs come from more than one service. Judged on the
    /// whole list, not the rows Find leaves, so typing never makes a column come and go.
    static func showsServiceColumn(_ tracks: [Track]) -> Bool {
        guard let first = tracks.first?.provider else { return false }
        return tracks.contains { $0.provider != first }
    }

    private func table(_ sorted: [Track], currentID: Track.ID?, context: AppModel.PlayingFrom) -> some View {
        let showsService = Self.showsServiceColumn(tracks)
        return Table(sorted, selection: $selection, sortOrder: $sortOrder) {
            // The artwork in its own narrow, unlabeled column, so the "Title" header sits over the titles.
            TableColumn("") { track in
                ZStack {
                    ArtworkView(artwork: track.artwork, size: 24, cornerRadius: 3)
                        .frame(width: 24, height: 24)
                    if track.id == currentID {
                        RoundedRectangle(cornerRadius: 3).fill(.black.opacity(0.45))
                        NowPlayingIndicator(tint: .white).scaleEffect(0.8)
                    }
                }
                .frame(width: 24, height: 24)
            }
            .width(24)
            TableColumn("Title", value: \.title) { track in
                HStack(spacing: 6) {
                    Text(track.title)
                        .lineLimit(1)
                        .fontWeight(track.id == currentID ? .semibold : .regular)
                    if track.isExplicit { ExplicitBadge() }
                }
            }
            .width(min: 120, ideal: 180)
            TableColumn("Artist", value: \.artistLine) { Text($0.artistLine).lineLimit(1) }
                .width(min: 80, ideal: 120)
            TableColumn("Album", value: \.albumTitle) { Text($0.albumTitle).lineLimit(1) }
                .width(min: 80, ideal: 120)
            // Only while the list mixes services: a column saying "YouTube Music" on every row (Spotify's songs
            // failed to load, or one service is in use) said nothing, the same rule as search's "Results from" line.
            if showsService {
                TableColumn("Service", value: \.serviceName) { track in
                    // The glyph and the full service name, as in the shelf headers and Settings.
                    HStack(spacing: 5) {
                        ServiceGlyph(provider: track.provider, size: 11, always: true)
                        Text(track.provider.displayName).lineLimit(1)
                    }
                    .foregroundStyle(.readableSecondary)
                }
                // Wide enough for "YouTube Music" beside its glyph.
                .width(min: 122, ideal: 128, max: 150)
            }
            // The heart, 8 pt, then the time, as on album and playlist pages: one column, no empty one beside it.
            // The time has a fixed slot, so the hearts line up down the list.
            TableColumn("Time", value: \.durationValue) { track in
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.likedHeart)
                        .opacity(model.isLiked(track) ? 1 : 0)
                        .accessibilityLabel("Liked")
                        .accessibilityHidden(!model.isLiked(track))
                    TrackDurationText(track, font: .body, minWidth: nil)
                        .foregroundStyle(.readableSecondary)
                        .frame(minWidth: 38, alignment: .trailing)
                }
            }
            .width(min: 76, ideal: 80, max: 96)
            // The header over the durations, which end at the column's trailing edge.
            .alignment(.trailing)
        }
        .tableStyle(.inset)
        .overlay(alignment: .topLeading) { HeaderDividerTrim(inset: Self.selectionInset) }
        // The inset style draws a row's selection 10 pt in from the table's edge (and its content 16 pt in): this puts
        // the selection on the page's margins, like the album list's highlight, with the rows' content 6 pt inside.
        .padding(.horizontal, Metrics.pageInset - Self.selectionInset)
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: Track.ID.self) { ids in
            let picked = sorted.filter { ids.contains($0.id) }
            if picked.count == 1, let track = picked.first {
                TrackMenu(track: track)
            } else if !picked.isEmpty {
                TracksMenu(tracks: picked)
            }
        } primaryAction: { ids in
            guard let index = sorted.firstIndex(where: { ids.contains($0.id) }) else { return }
            model.play(sorted, startAt: index, from: context)
        }
    }

    /// "1,204 songs", or "12 of 1,204 songs" while the field narrows the list.
    private func countLabel(shown: Int, filtering: Bool) -> String {
        let n = tracks.count
        let total = "\(n.formatted()) song\(n == 1 ? "" : "s")\(isComplete ? "" : "…")"
        return filtering ? "\(shown.formatted()) of \(total)" : total
    }
}

/// The album and playlist pages' style on Songs: the round Play (Pause while these songs play, Resume when paused),
/// then the Shuffle capsule. Its own view, so only it follows the player's state.
private struct SongsPlayButtons: View {
    let title: String
    let tracks: [Track]
    let context: AppModel.PlayingFrom
    @Environment(AppModel.self) private var model

    var body: some View {
        let isCurrent = model.playingFrom?.title == title && model.playingFrom?.route == nil && model.player.current != nil
        let isPlaying = isCurrent && model.player.isPlaying
        HStack(spacing: 10) {
            PlayCircleButton(size: 40, onArtwork: false, isPause: isPlaying) {
                if isCurrent { model.togglePlayPause() } else { model.play(tracks, from: context) }
            }
            .disabled(tracks.isEmpty)
            .help(isPlaying ? "Pause" : isCurrent ? "Resume" : "Play")
            Button { model.play(tracks, shuffled: true, from: context) } label: { Label("Shuffle", systemImage: "shuffle") }
                .buttonStyle(HeroCapsuleStyle())
                .disabled(tracks.isEmpty)
                .help("Shuffle")
        }
    }
}

/// Ends the Songs table's header (its background and the hairline under it) at the page margins. AppKit draws them
/// across the table's whole width, `inset` points past the selection's edges on both sides (the table is that much
/// wider than the margins so the rows' rounded selection lands on them); this covers those two short ends in the
/// page's color. The trailing end also covers the column divider AppKit draws after the last column (Time), so the
/// header ends at Time as a native table's does when its columns fill it. The header's height and where the last
/// column ends come from the table itself (`TableHeaderReader`).
private struct HeaderDividerTrim: View {
    let inset: CGFloat
    @State private var header: TableHeaderReader.Measure?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let header {
                // The header's whole height, so its background (a shade darker than the page in dark mode) ends
                // on the margins too, along with the hairline under it.
                HStack(spacing: 0) {
                    Color.pageBackground.frame(width: inset)
                    Spacer(minLength: 0)
                    Color.pageBackground.frame(width: max(inset, header.trailingCover))
                }
                .frame(height: header.height + 1.5)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .background(TableHeaderReader { measure in if header != measure { header = measure } })
    }
}

/// Reports the height of the header of the `NSTableView` under this view (the SwiftUI `Table` it overlays).
private struct TableHeaderReader: NSViewRepresentable {
    struct Measure: Equatable {
        let height: CGFloat
        /// From the last column's divider (its trailing point) to this view's trailing edge.
        let trailingCover: CGFloat
    }

    let report: (Measure) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.report = report
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.report = report
        view.measureSoon()
    }

    final class ReaderView: NSView {
        var report: ((Measure) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); measureSoon() }

        func measureSoon() {
            DispatchQueue.main.async { [weak self] in self?.measure() }
        }

        private func measure() {
            guard let window, let root = window.contentView else { return }
            let mine = convert(bounds, to: nil)
            let center = CGPoint(x: mine.midX, y: mine.midY)
            func tables(_ view: NSView) -> [NSTableView] {
                ((view as? NSTableView).map { [$0] } ?? []) + view.subviews.flatMap(tables)
            }
            guard let table = tables(root).first(where: { table in
                guard let scroll = table.enclosingScrollView else { return false }
                return scroll.convert(scroll.bounds, to: nil).contains(center)
            }), let header = table.headerView else { return }
            let height = header.frame.height
            // AppKit draws a column's divider in the last point of its header rect.
            var trailingCover: CGFloat = 0
            if table.numberOfColumns > 0 {
                let last = header.convert(header.headerRect(ofColumn: table.numberOfColumns - 1), to: nil)
                // Never more than a few points past the margin, whatever the geometry reads.
                trailingCover = min(max(0, mine.maxX - (last.maxX - 1)), 40)
            }
            if LayoutProbe.enabled {
                let scroll = table.enclosingScrollView.map { $0.convert($0.bounds, to: nil) } ?? .zero
                let row = table.numberOfRows > 0 ? table.convert(table.rect(ofRow: 0), to: nil) : .zero
                let cell = table.numberOfRows > 1 && table.numberOfColumns > 1
                    ? table.convert(table.frameOfCell(atColumn: 1, row: 0), to: nil) : .zero
                DebugProbes.note("songs-table", "scroll x \(Int(scroll.minX))…\(Int(scroll.maxX)), header height \(height), "
                    + "row 0 x \(Int(row.minX))…\(Int(row.maxX)), title cell x \(Int(cell.minX)), style \(table.style.rawValue), "
                    + "intercell \(table.intercellSpacing.width), overlay x \(Int(mine.minX))…\(Int(mine.maxX)), "
                    + "trailing cover \(Int(trailingCover.rounded())) pt")
            }
            report?(Measure(height: height, trailingCover: trailingCover))
        }
    }
}
