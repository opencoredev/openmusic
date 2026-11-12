import MedleyCore
import SwiftUI

struct SearchPage: View {
    @Environment(AppModel.self) private var model
    @State private var width: CGFloat = 800

    var body: some View {
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let providers = model.searchProviders
        let searching = !providers.isEmpty && !query.isEmpty
        Group {
            if providers.isEmpty {
                NoServicesView(title: "Search")
            } else if query.isEmpty {
                SearchHome()
            } else {
                SearchResultsView(key: model.searchKey(for: query))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // The scopes sit in the toolbar, as in Music, so results start right under it with no second bar.
        .toolbar {
            if searching {
                ToolbarItem(placement: .principal) {
                    SearchScopePicker(compact: width < SearchScopePicker.segmentedMinPageWidth)
                        .modifier(LayoutProbe(key: "search-header"))
                }
            }
        }
        .navigationTitle("Search")
    }
}

/// Scopes as a native segmented control, or a pop-up menu when the page is too narrow for five segments (the
/// queue open in a small window).
private struct SearchScopePicker: View {
    let compact: Bool
    @Environment(AppModel.self) private var model

    /// Five segments, back/forward and the toolbar's margins.
    static let segmentedMinPageWidth: CGFloat = 560

    var body: some View {
        @Bindable var model = model
        let picker = Picker("Show", selection: $model.searchScope) {
            ForEach(SearchScope.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Group {
            if compact {
                picker.pickerStyle(.menu)
            } else {
                picker.pickerStyle(.segmented)
            }
        }
        .labelsHidden()
        .fixedSize()
        .help("Show results of one kind")
    }
}

extension SearchScope {
    var title: String {
        switch self {
        case .all: "Top Results"
        case .songs: "Songs"
        case .albums: "Albums"
        case .artists: "Artists"
        case .playlists: "Playlists"
        }
    }
}

/// Before typing: recent searches and a nudge.
private struct SearchHome: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.recentSearches.isEmpty {
            EmptyStateView(symbol: "magnifyingglass", title: "Search", message: "Find songs, albums, artists and playlists.")
        } else {
            ScrollPage {
                VStack(alignment: .leading, spacing: 4) {
                    SectionHeader(title: "Recent Searches") {
                        Button("Clear") { model.clearRecentSearches() }
                            .buttonStyle(SubtleLinkStyle(readable: true))
                            .font(.callout)
                    }
                    .padding(.bottom, 6)
                    ForEach(model.recentSearches, id: \.self) { q in
                        Button { model.searchText = q; model.recordSearch(q) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                                Text(q)
                                Spacer()
                            }
                            .frame(height: 30)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, Metrics.pageInset)
                    }
                }
            }
        }
    }
}

/// Results for one (query, scope, services) key. While the key loads it shows a skeleton shaped like
/// the results, never the previous query's rows; late answers for older keys are dropped by the store.
private struct SearchResultsView: View {
    let key: SearchKey

    @Environment(AppModel.self) private var model

    private struct LoadID: Hashable {
        let key: SearchKey
        let refresh: Int
    }

    var body: some View {
        let store = model.searchResults
        Group {
            if let results = store.results(for: key) {
                SearchResultsContent(query: key.query, scope: key.scope, results: results)
                    // Each query and scope gets its own page, starting at the top. One scroll view for all of them kept
                    // Top Results' offset: Songs opened mid-list (past its end in one capture), and Artists, switched
                    // to in the same update as a scroll, laid out no rows and showed a blank page (council round 22).
                    // View › Refresh keeps the key, so the rows on screen stay where they are.
                    .id(key)
            } else {
                SearchSkeleton(scope: key.scope)
            }
        }
        // A page pushed over the results means a result was opened.
        .onDisappear { if model.sidebarSelection == .search, !model.path.isEmpty { model.searchResultUsed() } }
        .task(id: LoadID(key: key, refresh: model.refreshTick)) { [refreshTick = model.refreshTick] in
            // View > Refresh reloads the same key; rows on screen keep their places.
            let refreshed = lastRefresh.map { $0 != refreshTick } ?? false
            lastRefresh = refreshTick
            await store.load(key, force: refreshed)
        }
    }

    @State private var lastRefresh: Int?
}

/// How many columns of a given minimum width fit in `width`.
private func columnCount(_ width: CGFloat, min: CGFloat, spacing: CGFloat, max: Int) -> Int {
    let usable = width - 2 * Metrics.pageInset
    return Swift.max(1, Swift.min(max, Int((usable + spacing) / (min + spacing))))
}

struct SearchResultsContent: View {
    let query: String
    let scope: SearchScope
    let results: [ProviderResult<SearchResults>]

    @Environment(AppModel.self) private var model
    @Environment(\.showsServiceMarks) private var showsMarks
    @State private var width: CGFloat = 900

    var body: some View {
        let values = results.compactMap(\.value)
        // Top Results lists each recording once (YouTube Music often repeats a song); the Songs scope keeps all.
        let allTracks = interleave(values.map(\.tracks))
        let tracks = scope == .all ? SongVersions.consolidated(allTracks) : allTracks
        let albums = interleave(values.map(\.albums))
        let artists = interleave(values.map(\.artists))
        let playlists = interleave(values.map(\.playlists))
        let failures = results.filter { $0.error != nil }
        let pageService = scope == .all
            ? Self.soleProvider(values.compactMap(\.top).map(\.provider) + tracks.map(\.provider) + albums.map(\.provider)
                                + artists.map(\.provider) + playlists.map(\.provider))
            : nil
        // The one service this scope's results all came from.
        let scopeService: ProviderID? = switch scope {
        case .all: pageService
        case .songs: Self.soleProvider(tracks.map(\.provider))
        case .albums: Self.soleProvider(albums.map(\.provider))
        case .artists: Self.soleProvider(artists.map(\.provider))
        case .playlists: Self.soleProvider(playlists.map(\.provider))
        }
        let needing = model.searchProvidersNeedingSignIn
        // Named once, at the top ("Results from YouTube Music"), where the service isn't a given: both are in use, or
        // one still waits for a sign-in (signed out, YouTube Music searches alone). Its items then carry no mark.
        let namedService = showsMarks || !needing.isEmpty ? scopeService : nil
        let itemMarks = namedService == nil && showsMarks
        Group {
            if values.allSatisfy(\.isEmpty) {
                if failures.isEmpty {
                    EmptyStateView(symbol: "magnifyingglass", title: "No results for “\(query)”", message: "Check the spelling or try a different search.")
                } else {
                    ScrollPage {
                        ForEach(failures, id: \.provider) { ProviderFailureRow(provider: $0.provider, message: $0.error ?? "") }
                    }
                }
            } else {
                ScrollPage {
                    // One line above the first heading, in every scope: the service every result came from, and at
                    // its trailing end Home's way in for a service that would search once signed in (signed out of
                    // everything the "Sign In" menu, else "Connect <service>").
                    serviceLine(namedService, needing: needing)
                    switch scope {
                    case .all:
                        topResults(values: values, tracks: tracks, pageService: pageService)
                        if !tracks.isEmpty {
                            section("Songs", scope: .songs, count: tracks.count, providers: tracks.map(\.provider), pageService: pageService) {
                                SearchSongColumns(tracks: tracks, query: query, width: width)
                            }
                        }
                        // Albums, then Artists, as in Apple Music's Top Results.
                        if !albums.isEmpty {
                            let ranked = AlbumRanking.split(albums, query: query, artists: artists)
                            section("Albums", scope: .albums, count: albums.count, providers: albums.map(\.provider), pageService: pageService) {
                                Carousel(items: (ranked.byArtist + ranked.others).map(MediaItem.album)) { MediaCard(item: $0) }
                            }
                        }
                        artistSections(artists, pageService: pageService)
                        if !playlists.isEmpty {
                            section("Playlists", scope: .playlists, count: playlists.count, providers: playlists.map(\.provider), pageService: pageService) {
                                Carousel(items: playlists.map(MediaItem.playlist)) { MediaCard(item: $0) }
                            }
                        }
                    case .songs:
                        TrackListView(tracks: tracks, style: .playlist, context: .init(title: "Search: \(query)"))
                            .padding(.horizontal, Metrics.pageInset - 10)
                            .environment(\.showsServiceMarks, itemMarks)
                    case .albums:
                        // The artist's own releases first; the other albums the words matched under a small label.
                        let ranked = AlbumRanking.split(albums, query: query, artists: artists)
                        if ranked.byArtist.isEmpty || ranked.others.isEmpty {
                            MediaGrid(items: (ranked.byArtist + ranked.others).map(MediaItem.album))
                                .environment(\.showsServiceMarks, itemMarks)
                        } else {
                            MediaGrid(items: ranked.byArtist.map(MediaItem.album))
                                .environment(\.showsServiceMarks, itemMarks)
                            Text("Other matches")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.readableSecondary)
                                .padding(.horizontal, Metrics.pageInset)
                                .padding(.bottom, -14)
                            MediaGrid(items: ranked.others.map(MediaItem.album))
                                .environment(\.showsServiceMarks, itemMarks)
                        }
                    case .artists:
                        // One service's artists: the line above names it, so the cards carry no mark (as Top Results'
                        // and the compact Artists row's don't).
                        MediaGrid(items: artists.map(MediaItem.artist))
                            .environment(\.showsServiceMarks, itemMarks)
                            .modifier(LayoutProbe(key: "search-artist-grid"))
                    case .playlists:
                        MediaGrid(items: playlists.map(MediaItem.playlist))
                            .environment(\.showsServiceMarks, itemMarks)
                    }
                    ForEach(failures, id: \.provider) { ProviderFailureRow(provider: $0.provider, message: $0.error ?? "") }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// Up to three large cards that share the page's width: each service's top hit, then the first songs.
    @ViewBuilder private func topResults(values: [SearchResults], tracks: [Track], pageService: ProviderID?) -> some View {
        let tops = values.compactMap(\.top)
        let columns = TopResultsLayout.columns(for: width)
        let fill = tracks.filter { t in
            !tops.contains { top in
                if case .track(let shown) = top { return shown.id == t.id || SongVersions.isSameRecording(shown, t) }
                return false
            }
        }
        let items = Array((tops + fill.map(MediaItem.track)).prefix(columns))
        if !items.isEmpty {
            let only = Self.soleProvider(items.map(\.provider))
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Top Results", provider: only == pageService ? nil : only)
                HStack(alignment: .top, spacing: TopResultsLayout.spacing) {
                    ForEach(items) { TopResultCard(item: $0) }
                }
                .padding(.horizontal, Metrics.pageInset)
                .environment(\.showsServiceMarks, only == nil && showsMarks)
            }
        }
    }

    /// "◉ Results from YouTube Music" with the sign-in way in at its trailing end, 12 pt above the first heading.
    /// Either half may be missing; with neither there's no line. The Sign In pill stays off the Top Results heading
    /// row, which keeps its own Show All.
    @ViewBuilder private func serviceLine(_ service: ProviderID?, needing: [any MusicProvider]) -> some View {
        if service != nil || !needing.isEmpty {
            HStack(alignment: .center, spacing: 16) {
                if let service { ResultsServiceCaption(provider: service) }
                Spacer(minLength: 0)
                if !needing.isEmpty { ConnectLinks(providers: needing, purpose: "search results") }
            }
            .padding(.horizontal, Metrics.pageInset)
            .padding(.bottom, 12 - Metrics.sectionSpacing)
            .modifier(LayoutProbe(key: "search-service-line"))
        }
    }

    /// The artists the query names, then the ones the service adds as related, labeled as such.
    /// Both groups share one row so a single exact match doesn't cost a whole section of height.
    ///
    /// A few artists (`CompactArtistRow.maxArtists` or fewer) take one compact row in the Top Results grid instead:
    /// three large portraits with most of the row empty read as a gap. The Artists scope keeps the large grid.
    @ViewBuilder private func artistSections(_ artists: [Artist], pageService: ProviderID?) -> some View {
        let split = ArtistMatch.split(artists, query: query)
        if !artists.isEmpty, artists.count <= CompactArtistRow.maxArtists {
            section("Artists", scope: .artists, count: artists.count, providers: artists.map(\.provider), pageService: pageService) {
                CompactArtistRow(artists: split.matches + split.related, columns: TopResultsLayout.columns(for: width))
            }
        } else if !artists.isEmpty {
            let only = Self.soleProvider(artists.map(\.provider))
            ArtistGroupsRow(provider: only, showsTag: only != pageService, groups: [
                ("Artists", split.matches),
                (split.matches.isEmpty ? "Artists" : "Related Artists", split.related),
            ].filter { !$0.1.isEmpty }.map { ArtistGroupsRow.Group(title: $0.0, artists: $0.1) }, cardWidth: ArtistGroupsRow.cardWidth(pageWidth: width))
        }
    }

    /// A titled section. When every result in it comes from one service, the service's mark shows once, beside the
    /// title, instead of on every row and card (as Home's shelves do); and not even there when the whole page is that
    /// service's (`pageService`, named once under the scope bar by `ResultsServiceCaption`).
    private func section<Content: View>(_ title: String, scope: SearchScope, count: Int, providers: [ProviderID], pageService: ProviderID?,
                                        @ViewBuilder content: () -> Content) -> some View {
        let only = Self.soleProvider(providers)
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title.titleCased(), provider: only == pageService ? nil : only) {
                if count > 6 { SeeAllButton { model.searchScope = scope } }
            }
            content()
                .environment(\.showsServiceMarks, only == nil && showsMarks)
        }
    }

    /// The one service every result in a section came from, or nil when they mix.
    static func soleProvider(_ providers: [ProviderID]) -> ProviderID? { ProviderID.sole(providers) }
}

/// "◉ Results from YouTube Music": under the scope bar when every result in the scope comes from one service, so
/// the service is named once instead of after each section's title or on each card. A section from another service
/// still gets its own tag.
private struct ResultsServiceCaption: View {
    let provider: ProviderID

    var body: some View {
        HStack(spacing: 5) {
            ServiceGlyph(provider: provider, size: 12, always: true)
            Text("Results from \(provider.displayName)")
        }
        .font(.callout)
        .foregroundStyle(.readableSecondary)
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Results from \(provider.displayName)")
        .modifier(LayoutProbe(key: "search-service-caption"))
    }
}

/// Artist groups side by side in one sideways-scrolling row, each under its own title.
///
/// Cards get an explicit width, the same as the Artists scope's grid at this page width: inside a sideways
/// scroll view a card has no width offered, and an unsized card shrank its portrait to a 10 pt dot.
/// The gap between groups is about three times the gap between cards, so the groups read as two.
private struct ArtistGroupsRow: View {
    struct Group: Identifiable {
        let title: String
        let artists: [Artist]
        var id: String { title }
    }

    /// Every artist's service when they share one: its mark shows once, after the first title.
    var provider: ProviderID? = nil
    /// False when the page already names that service once (`ResultsServiceCaption`).
    var showsTag = true
    let groups: [Group]
    let cardWidth: CGFloat
    @Environment(\.showsServiceMarks) private var showsMarks

    static let groupSpacing: CGFloat = 60
    /// Room for the hover tile, which reaches past each card's edge.
    private static let bleed: CGFloat = 12

    /// The Artists scope's card width (see `MediaGrid`) for a page this wide.
    static func cardWidth(pageWidth: CGFloat) -> CGFloat {
        Metrics.cardLayout(available: pageWidth - 2 * Metrics.pageInset).width
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Self.groupSpacing) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(group.title)
                                .font(.sectionTitle)
                                .foregroundStyle(group.title == "Related Artists" ? .secondary : .primary)
                                .accessibilityAddTraits(.isHeader)
                            if let provider, showsTag, group.id == groups.first?.id {
                                ServiceTag(provider: provider)
                            }
                        }
                        HStack(alignment: .top, spacing: Metrics.cardSpacing) {
                            ForEach(group.artists) { ArtistCard(artist: $0, width: cardWidth) }
                        }
                        .environment(\.showsServiceMarks, provider == nil && showsMarks)
                    }
                }
            }
            .padding(.vertical, Self.bleed)
            .scrollTargetLayout()
        }
        .scrollIndicators(.never)
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, Metrics.pageInset, for: .scrollContent)
        .padding(.vertical, -Self.bleed)
    }
}

/// A few artists in the Top Results grid: a 64 pt portrait with the name and "Artist" beside it, the same card
/// as a Top Results artist, smaller. Columns match Top Results so the cards line up under it.
private struct CompactArtistRow: View {
    static let maxArtists = 3

    let artists: [Artist]
    let columns: Int

    var body: some View {
        let perRow = max(1, columns)
        let rows = stride(from: 0, to: artists.count, by: perRow).map { Array(artists[$0..<min(artists.count, $0 + perRow)]) }
        VStack(alignment: .leading, spacing: TopResultsLayout.spacing) {
            ForEach(rows, id: \.first?.id) { row in
                HStack(alignment: .top, spacing: TopResultsLayout.spacing) {
                    ForEach(row) { CompactArtistCard(artist: $0) }
                    // Empty columns keep each card the width of a Top Results card.
                    ForEach(row.count..<perRow, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
                }
            }
        }
        .padding(.horizontal, Metrics.pageInset)
    }
}

private struct CompactArtistCard: View {
    let artist: Artist
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        let item = MediaItem.artist(artist)
        Button { model.searchResultUsed(); model.open(item) } label: {
            HStack(spacing: 12) {
                ArtworkView(artwork: artist.artwork, size: 64, cornerRadius: 32, circle: true, symbol: "music.mic")
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(artist.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 5) {
                        ServiceGlyph(provider: artist.provider, size: 10)
                        Text("Artist").lineLimit(1)
                    }
                    .font(.callout)
                    .foregroundStyle(.readableSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.primary.opacity(hovering ? (scheme == .dark ? 0.1 : 0.07) : (scheme == .dark ? 0.06 : 0.04)),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .help(artist.name)
        .accessibilityLabel("\(artist.name), Artist")
        .contextMenu { CollectionMenu(item: item) }
        .mediaDraggable(item)
        .modifier(DebugFrame(key: "search-compact-artist"))
    }
}

enum TopResultsLayout {
    static let spacing: CGFloat = 16
    static func columns(for width: CGFloat) -> Int { columnCount(width, min: 280, spacing: spacing, max: 3) }
}

/// Search songs in columns of four that use the page's width: as many columns as fit (up to four), each
/// column as wide as the space allows so titles get room. Reads down, then across, like a chart.
private struct SearchSongColumns: View {
    let tracks: [Track]
    let query: String
    let width: CGFloat

    static let rows = 4
    static let spacing: CGFloat = 24

    @Environment(AppModel.self) private var model

    var body: some View {
        let fit = columnCount(width, min: 300, spacing: Self.spacing, max: 4)
        let needed = (tracks.count + Self.rows - 1) / Self.rows
        let columns = max(1, min(fit, needed))
        let shown = Array(tracks.prefix(columns * Self.rows))
        // Lengths as in every other song list, whenever the service gave any.
        let showsDuration = tracks.contains { $0.duration != nil }
        HStack(alignment: .top, spacing: Self.spacing) {
            ForEach(0..<columns, id: \.self) { column in
                VStack(spacing: 0) {
                    ForEach(column * Self.rows..<min(shown.count, (column + 1) * Self.rows), id: \.self) { index in
                        CompactTrackRow(track: shown[index], context: .init(title: "Search: \(query)"), play: {
                            model.searchResultUsed()
                            model.play(tracks, startAt: index, from: .init(title: "Search: \(query)"))
                        }, showsDuration: showsDuration, large: true, subtitle: SongVersions.rowLine(for: shown[index]), namesAlbum: true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .padding(.horizontal, Metrics.pageInset)
    }
}

/// Loading placeholder with the same geometry as the results it stands in for, so nothing jumps.
private struct SearchSkeleton: View {
    let scope: SearchScope
    @State private var width: CGFloat = 900

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                switch scope {
                case .all:
                    VStack(alignment: .leading, spacing: 12) {
                        SkeletonBlock(width: 130, height: 20)
                        HStack(spacing: TopResultsLayout.spacing) {
                            ForEach(0..<TopResultsLayout.columns(for: width), id: \.self) { _ in
                                HStack(spacing: 14) {
                                    SkeletonBlock(width: 80, height: 80, radius: 6)
                                    VStack(alignment: .leading, spacing: 8) {
                                        SkeletonBlock(width: 140, height: 13)
                                        SkeletonBlock(width: 90, height: 11)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.pageInset)
                    VStack(alignment: .leading, spacing: 12) {
                        SkeletonBlock(width: 80, height: 20)
                        HStack(alignment: .top, spacing: SearchSongColumns.spacing) {
                            ForEach(0..<columnCount(width, min: 300, spacing: SearchSongColumns.spacing, max: 3), id: \.self) { column in
                                VStack(spacing: 0) {
                                    ForEach(0..<SearchSongColumns.rows, id: \.self) { row in
                                        // The large song row's geometry (52 pt artwork, 6 pt above and below).
                                        HStack(spacing: 12) {
                                            SkeletonBlock(width: 52, height: 52, radius: 5)
                                            VStack(alignment: .leading, spacing: 6) {
                                                SkeletonBlock(width: CGFloat(120 + ((row + column) * 37) % 90), height: 12)
                                                SkeletonBlock(width: 80, height: 10)
                                            }
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.vertical, 6)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.pageInset)
                    // The artist row at its final geometry: a section title, then portraits as wide as the
                    // loaded cards with a name and "Artist" line under each.
                    let card = ArtistGroupsRow.cardWidth(pageWidth: width)
                    VStack(alignment: .leading, spacing: 12) {
                        SkeletonBlock(width: 90, height: 20)
                            .frame(height: 27, alignment: .leading)
                        HStack(alignment: .top, spacing: Metrics.cardSpacing) {
                            ForEach(0..<8, id: \.self) { i in
                                VStack(alignment: .leading, spacing: 8) {
                                    SkeletonBlock(width: card, height: card, circle: true)
                                    VStack(alignment: .leading, spacing: 3) {
                                        SkeletonBlock(width: card * (0.5 + 0.1 * Double(i % 3)), height: 11).frame(height: 17)
                                        SkeletonBlock(width: 44, height: 10).frame(height: 16)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.pageInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
                case .songs:
                    VStack(spacing: 0) {
                        ForEach(0..<10, id: \.self) { i in
                            HStack(spacing: 12) {
                                SkeletonBlock(width: 40, height: 40, radius: 4)
                                VStack(alignment: .leading, spacing: 6) {
                                    SkeletonBlock(width: CGFloat(140 + (i * 47) % 120), height: 11)
                                    SkeletonBlock(width: 90, height: 10)
                                }
                                Spacer()
                                SkeletonBlock(width: 34, height: 11)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 56)
                        }
                    }
                    .padding(.horizontal, Metrics.pageInset - 10)
                    .padding(.top, 26)
                case .albums, .playlists, .artists:
                    GridSkeleton(circle: scope == .artists)
                        .padding(.top, -Metrics.pageInset)
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDisabled(true)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityLabel("Loading results")
    }
}

/// The large first cards in search results: artwork, title and kind, with Play on the artwork on hover.
///
/// A song card says which recording it is: "Song · Taylor Swift · Lover · 2:52" or "Video · Taylor Swift ·
/// 3:31". YouTube's combined results leave album and length out, so the card asks for them once (cached).
struct TopResultCard: View {
    let item: MediaItem
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    /// The song with its album and length filled in, once the service has said.
    @State private var resolved: Track?

    private var track: Track? {
        if case .track(let t) = item { return resolved?.id == t.id ? resolved : t }
        return nil
    }

    var body: some View {
        let isArtist: Bool = if case .artist = item { true } else { false }
        Button { model.searchResultUsed(); model.open(item) } label: {
            HStack(spacing: 14) {
                ArtworkView(artwork: item.artwork, size: 80, cornerRadius: 6, circle: isArtist, symbol: isArtist ? "music.mic" : "music.note")
                    .frame(width: 80, height: 80)
                    .overlay {
                        if hovering && !isArtist {
                            PlayCircleButton(size: 32, onArtwork: true) { model.searchResultUsed(); model.play(item) }
                                .transition(.opacity)
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 5) {
                        ServiceGlyph(provider: item.provider, size: 10)
                        // One space each side of every dot: "Song · Olivia Rodrigo · 3:45". The length never truncates.
                        HStack(spacing: 0) {
                            Text(typeLabel).lineLimit(1)
                            if let track, let length = model.displayDuration(for: track) {
                                Text(" · \(length.clock)")
                                    .monospacedDigit()
                                    .fixedSize()
                                    .help(model.durationNote(for: track) ?? "")
                            }
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.readableSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.primary.opacity(hovering ? (scheme == .dark ? 0.1 : 0.07) : (scheme == .dark ? 0.06 : 0.04)),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .help(track.map(SongVersions.helpLine) ?? "")
        .contextMenu { CollectionMenu(item: item) }
        .mediaDraggable(item)
        .task(id: item.id) {
            guard case .track(let t) = item, t.album == nil || t.duration == nil else { return }
            let linked = await model.linkedTrack(t)
            if linked.id == t.id { resolved = linked }
        }
    }

    private var typeLabel: String {
        switch item {
        case .artist: "Artist"
        case .album(let a): "\(a.kind.label) · \(a.artistLine)"
        case .playlist(let p): "Playlist · \(p.owner ?? p.provider.displayName)"
        case .track(let t): SongVersions.detailLine(for: track ?? t)
        }
    }
}
