import MedleyCore
import SwiftUI

struct PlaylistPage: View {
    let provider: ProviderID
    let id: String
    let preview: Playlist?

    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let p = model.provider(provider) {
                Loadable(key: "playlist:\(provider.rawValue):\(id)", failureHeader: AnyView(
                    // A partly applied edit stays within reach when the page can't load (offline).
                    PartialEditBannerSlot(key: "playlist:\(provider.rawValue):\(id)")
                        .padding(.horizontal, Metrics.pageInset)
                        .padding(.top, 20)
                )) {
                    try await p.playlist(id: id)
                } content: { detail in
                    PlaylistContent(detail: detail).id(detail.playlist.id)
                } placeholder: {
                    DetailScaffold(wash: preview?.artwork) {
                        CollectionHero(artwork: preview?.artwork, kind: "Playlist", title: preview?.title, description: preview?.summary,
                                       service: preview.flatMap { PlaylistOwnerLead.ownerIsService($0) ? nil : $0.provider }) {
                            if let preview { PlaylistOwnerLead(playlist: preview) }
                        } trailingMeta: {
                            SkeletonBlock(width: 110, height: 12)
                        }
                    } actions: {
                        HeroActionsSkeleton()
                    } body: {
                        TrackListSkeleton(style: .playlist)
                    }
                }
            }
        }
        .navigationTitle(preview?.title ?? "Playlist")
    }
}

/// The first part of a playlist header's meta line, as a shelf header names a service: "◉ Spotify" (logo first)
/// when the service made the playlist (Discover Weekly, mixes), else the owner's name, which the service's tag
/// follows. Where only one service has content there are no marks, and the line starts with the owner's name.
struct PlaylistOwnerLead: View {
    let playlist: Playlist
    @Environment(\.showsServiceMarks) private var showsMarks

    static func ownerIsService(_ playlist: Playlist) -> Bool {
        playlist.owner == nil || playlist.owner == playlist.provider.displayName
    }

    var body: some View {
        if Self.ownerIsService(playlist), showsMarks {
            ServiceTag(provider: playlist.provider, style: .inline)
        } else {
            Text(playlist.owner ?? playlist.provider.displayName)
        }
    }
}

#if DEBUG
/// Tests only (`PlaylistPageHostTests`): what the hosted playlist page does, through the environment, so release
/// builds carry none of it.
@MainActor final class PlaylistPageProbe {
    /// Called each time the page's loading task runs, with the pager it loads through (the first, then each one fresh
    /// detail brings) and whether it is refilling to the replaced pager's length.
    var onTask: (PlaylistPager, Bool) -> Void = { _, _ in }
    /// The track list's selection, once the list is on screen.
    var selection: Binding<TrackSelection>?
    /// Whether the rows hold their selection (a refill not finished), as the page last drew it.
    var holdsSelection = false
    /// The page's Try Again under a failed page.
    var tryAgain: (() -> Void)?
    /// The page's Find in playlist text.
    var query: Binding<String>?
    /// The page shows Load More (a list with no rows whose automatic loading reached its budget).
    var showsLoadMore = false
    /// The page's Load More.
    var loadMore: (() -> Void)?
    /// The banner of a partly applied edit as it is mounted (`PartialEditBanner` sets it as it appears and clears it
    /// as it goes): its buttons by title. Nil while no banner is on screen.
    var editBanner: [String: () -> Void]?
    /// The page shows the banner of a partly applied edit.
    var showsEditBanner: Bool { editBanner != nil }
}

extension EnvironmentValues {
    @Entry var playlistPageProbe: PlaylistPageProbe? = nil
}
#endif

struct PlaylistContent: View {
    let detail: PlaylistDetail
    @Environment(AppModel.self) private var model
    #if DEBUG
    @Environment(\.playlistPageProbe) private var probe
    #endif
    /// The later pages (`PlaylistPager`): every request runs in this view's `.task`, so leaving the page cancels it.
    @State private var pager: PlaylistPager
    /// The listener asked for the next page (the list scrolled near its end, or Try Again).
    @State private var wantsMore = false
    /// Fresh detail replaced a pager that had loaded more songs: the new one loads its pages again up to there (the
    /// list stays as long as the listener had it), and the rows hold their selection meanwhile.
    @State private var refill: Refill?
    @State private var query = ""
    @State private var sort: TrackSort = .original

    /// A refill's target: the songs the replaced pager had, and how many pages the new one may ask for on its own to
    /// get there (the pages the old one took, plus `slack` for songs added before that point, at most `pageLimit`).
    struct Refill: Equatable {
        var songs: Int
        var pageBudget: Int

        static let slack = 2
        static let pageLimit = 20

        /// The refill after fresh detail replaced `old` (itself perhaps still refilling to `current`), or nil when
        /// the new pager already has as many songs.
        static func after(_ old: PlaylistPager, current: Refill?, newCount: Int) -> Refill? {
            let songs = max(old.tracks.count, current?.songs ?? 0)
            guard songs > newCount else { return nil }
            let pages = max(old.pagesLoaded + slack, current?.pageBudget ?? 0)
            return Refill(songs: songs, pageBudget: min(pages, pageLimit))
        }
    }

    init(detail: PlaylistDetail) {
        self.detail = detail
        _pager = State(initialValue: PlaylistPager(detail))
    }

    /// The rows hold their selection: the pager is still short of the songs the replaced one had and the list goes on.
    /// A failed page doesn't end it (Try Again goes on refilling); catching up or the list's real end does.
    private var holding: Bool {
        guard let refill else { return false }
        return pager.tracks.count < refill.songs && pager.continuation != nil
    }

    /// The page asks for the refill's next page by itself: holding, nothing failed, and pages left in its budget. Past
    /// the budget the list loads on as the listener scrolls, still holding.
    private var refilling: Bool {
        guard let refill, holding else { return false }
        return pager.error == nil && pager.pagesLoaded < refill.pageBudget
    }

    /// Try Again under a failed page: the request goes again, and a refill goes on.
    private func tryAgain() {
        pager.error = nil
        wantsMore = true
    }

    private var tracks: [Track] { pager.tracks }
    private var isLoadingMore: Bool { pager.isLoading }
    private var nextToken: String? { pager.continuation }

    var body: some View {
        let playlist = detail.playlist
        let context = AppModel.PlayingFrom(title: playlist.title, route: .playlist(playlist.provider, id: playlist.providerID, preview: playlist))
        let tracks = tracks
        let route = Route.playlist(playlist.provider, id: playlist.providerID, preview: playlist)
        // The service's total of entries, every copy counted, loaded or not: a song listed twice is one row marked
        // "2×", and the rows' copies add up to this count. The length counts every copy too, once all are loaded.
        let complete = pager.isComplete
        let count = pager.entryTotal
        let copies = pager.copies
        // Find and the sort stay while either is in use, so a count that changes can't take away the field holding
        // the query or the header holding the sort. One sort, `sort`, orders the rows and what Play queues.
        let filterable = max(count, tracks.count) > TrackFilter.minimumCount || !query.isEmpty || !self.sort.isOriginal
        let sort = filterable ? self.sort : .original
        let listing = TrackListing(tracks: tracks, query: query, sort: sort, enabled: filterable, length: { model.displayDuration(for: $0) })
        let filtering = listing.filtering
        let reordered = filtering || !sort.isOriginal
        let refilling = refilling
        let holding = holding
        // A list with no rows whose automatic loading stopped at its budget (`nextLoad`): Load More asks for a page.
        let stalled = tracks.isEmpty && nextToken != nil && !isLoadingMore && pager.error == nil
            && Self.nextLoad(reordered: reordered, wantsMore: wantsMore, refilling: refilling, holding: holding,
                             wantsEagerPage: pager.wantsEagerPage, wantsEmptyPage: pager.wantsEmptyPage) == nil
        DetailScaffold(wash: playlist.artwork) {
            CollectionHero(
                artwork: playlist.artwork, kind: "Playlist", title: playlist.title, description: playlist.summary,
                meta: [], service: PlaylistOwnerLead.ownerIsService(playlist) ? nil : playlist.provider
            ) {
                PlaylistOwnerLead(playlist: playlist)
            } trailingMeta: {
                // The total length once every song is loaded, every entry is listed (none left out, such as local
                // files) and each row's length is known, as on an album page: a
                // short playlist's later pages load right after the first (`eagerLoadLimit`), so "40 songs" becomes
                // "40 songs, 2 hr 14 min" a moment after the page opens; a long one's when scrolling, sorting or
                // filtering has loaded it all.
                SongCountMeta(count: count, tracks: tracks, complete: complete, copies: copies)
            }
        } actions: {
            HeroActions(item: .playlist(playlist), route: route, enabled: !tracks.isEmpty,
                        sorting: filterable ? TrackSorting(sort: $sort, options: TrackSort.Key.allCases) : nil) { shuffled in
                // Play in a sort: the whole playlist in the order shown, from its first song, the rest loaded first
                // (as Play from a sorted row). Shuffle, and Play in the playlist's own order, start at once.
                if shuffled || !filterable || sort.isOriginal {
                    Task { await playAll(shuffled: shuffled, context: context) }
                } else {
                    Task { await playSorted(from: nil, sort: sort, context: context) }
                }
            }
        } tools: {
            if filterable {
                TrackFilterField(text: $query, prompt: "Find in playlist")
            }
        } body: {
            VStack(spacing: 0) {
                // A partly applied edit whose notice isn't up keeps its buttons here, until Try Again, Undo or Leave As Is:
                // over the list, and over "This playlist is empty" when the edit took its last song.
                PartialEditBannerSlot(key: AppModel.playlistKey(playlist), spacing: 12)
                // Empty only once the playlist's end is known: a first page with nothing to show (Spotify's local files and
                // episodes are left out of the rows) or a refill still under way keeps the list, and the selection it holds.
                if Self.showsEmptyState(rows: tracks.count, continuation: nextToken, holding: holding) {
                    EmptyStateView(symbol: "music.note.list", title: "This playlist is empty", message: playlist.isEditable ? "Add songs with “Add to Playlist” from any song's menu." : nil)
                        .frame(height: 260)
                } else {
                    let noMatches = listing.shown.isEmpty && filtering && !isLoadingMore
                    VStack(spacing: 0) {
                        if noMatches {
                            NoFilterMatches(query: query) { query = "" }
                        }
                        // Mounted even when nothing matches (no rows, no header then): the list owns the selection, and
                        // a selection held through a refill (`holding`) must outlive a query that matches nothing yet.
                        // Filtered rows keep their place numbers; sorted rows show none. Play from a row plays the whole
                        // playlist from that song: in its own order (with the pages not loaded yet), or in the sorted order.
                        TrackListView(
                            tracks: listing.shown.map { tracks[$0] }, style: .playlist, context: context, playlist: playlist,
                            onPlay: { index in
                                if sort.isOriginal {
                                    guard let start = listing.shown[safe: index] else { return }
                                    Task { await playAll(startAt: start, shuffled: false, context: context) }
                                } else {
                                    guard let row = listing.shown[safe: index] else { return }
                                    Task { await playSorted(from: tracks[row].id, sort: sort, context: context) }
                                }
                            },
                            onReachEnd: { if !pager.isLoading { wantsMore = true } },
                            showsHeader: !noMatches && !tracks.isEmpty,
                            rowNumbers: reordered ? listing.shown.map { $0 + 1 } : nil,
                            // Sorted: no # column, as in Music (a filter in the playlist's own order keeps the places).
                            showsNumbers: sort.isOriginal,
                            sort: filterable ? $sort : nil,
                            holdsSelection: holding,
                            copies: copies
                        )
                        if stalled {
                            Button("Load More") { tryAgain() }
                                .font(.callout)
                                .padding(.top, 12)
                                .modifier(LayoutProbe(key: "playlist-load-more"))
                        } else if isLoadingMore || (tracks.isEmpty && pager.error == nil) {
                            TrackListSkeleton(rows: 3, style: .playlist, showsHeader: tracks.isEmpty)
                        } else if let loadError = pager.error {
                            HStack {
                                Text(loadError).foregroundStyle(.readableSecondary)
                                Button("Try Again") { tryAgain() }
                            }
                            .font(.callout)
                            .padding(.top, 12)
                        }
                    }
                }
            }
        }
        // While filtering or sorted, fetch the rest of the playlist so every song can match and sorts into place; a
        // short playlist's rest at once (a known total of at most `PlaylistPager.eagerLoadLimit`, within its page
        // budget), for the header's total length. The request is awaited here: leaving the page cancels it. The id
        // leaves out `isLoading`, which the request itself sets. It includes the pager itself: fresh detail (a cached
        // page refreshed) replaces the pager, which cancels a request still running on the old one and loads through
        // the new one, even when both have the same counters.
        // A refill after fresh detail loads like a listener's request, up to the songs the old pager had.
        .task(id: "\(ObjectIdentifier(pager).hashValue)|\(reordered)|\(pager.pagesLoaded)|\(wantsMore)|\(pager.error == nil)|\(refilling)|\(holding)|\(tracks.isEmpty)") {
            let pager = pager
            #if DEBUG
            probe?.onTask(pager, refilling)
            #endif
            guard pager.continuation != nil, pager.error == nil, let provider = model.provider(detail.playlist.provider) else { return }
            let fetch: (String) async throws -> Page<Track> = { try await provider.playlistTracks(continuation: $0) }
            switch Self.nextLoad(reordered: reordered, wantsMore: wantsMore, refilling: refilling, holding: holding,
                                 wantsEagerPage: pager.wantsEagerPage, wantsEmptyPage: pager.wantsEmptyPage) {
            case .asked:
                await pager.loadNext(fetch: fetch)
                if !Task.isCancelled { wantsMore = false }
            case .eager:
                await pager.loadNext(eager: true, fetch: fetch)
            case .empty:
                await pager.loadNext(empty: true, fetch: fetch)
            case nil:
                break
            }
        }
        .onChange(of: detail) {
            let old = pager
            pager = PlaylistPager(detail)
            wantsMore = false
            refill = Refill.after(old, current: refill, newCount: pager.tracks.count)
        }
        // The refill ended (caught up, or the list really ended): rows missing now are gone, and leave the selection.
        .onChange(of: holding) { if !holding { refill = nil } }
        #if DEBUG
        .onChange(of: holding, initial: true) { probe?.holdsSelection = holding }
        .onChange(of: stalled, initial: true) { probe?.showsLoadMore = stalled }
        .onAppear {
            probe?.tryAgain = { tryAgain() }
            probe?.loadMore = { tryAgain() }
            probe?.query = $query
        }
        #endif
    }

    /// What the page's task loads next: a page asked for (sorted or filtered, the list scrolled near its end, Try
    /// Again or Load More, a refill within its budget), a page because the list has no rows to show yet (a first page
    /// of only entries Medley leaves out: there is no last row to scroll to), an eager page of a short playlist, or
    /// nothing. Nothing automatic while a refill holds the selection: past its page budget the refill waits for the
    /// listener, and eager or empty pages would go past that budget by themselves. Empty pages stop at
    /// `PlaylistPager.emptyPageBudget` and count as eager pages; then a list with no rows shows Load More.
    enum Load: Equatable { case asked, eager, empty }

    static func nextLoad(reordered: Bool, wantsMore: Bool, refilling: Bool, holding: Bool, wantsEagerPage: Bool, wantsEmptyPage: Bool = false) -> Load? {
        if reordered || wantsMore || refilling { return .asked }
        if holding { return nil }
        if wantsEmptyPage { return .empty }
        if wantsEagerPage { return .eager }
        return nil
    }

    /// The empty state replaces the list only when there are no rows and none can come: the service has no pages left
    /// and no refill holds a selection. Until then the list stays mounted (with the loading rows under it).
    static func showsEmptyState(rows: Int, continuation: String?, holding: Bool) -> Bool {
        rows == 0 && continuation == nil && !holding
    }

    /// Plays the whole playlist in the current sort, from the song `id` (the first in that order when nil). Pages not
    /// loaded yet are fetched first, so they sort into place instead of being left out of the queue.
    private func playSorted(from id: String?, sort: TrackSort, context: AppModel.PlayingFrom) async {
        await model.playPlaylistSorted(tracks, continuation: nextToken, provider: detail.playlist.provider, sort: sort, startID: id, from: context)
    }

    /// Play from `index` right away; the model appends the pages not loaded yet (or loads them first for shuffle).
    private func playAll(startAt index: Int = 0, shuffled: Bool, context: AppModel.PlayingFrom) async {
        await model.playPlaylist(tracks, continuation: nextToken, provider: detail.playlist.provider, startAt: index, shuffled: shuffled, from: context)
    }
}

/// The playlist's partly applied edit in a banner while its failure notice isn't up, wherever the page is: over the
/// list, over "This playlist is empty", and over the page's loading error (`PlaylistPage`), so its buttons are always
/// within reach. `spacing` goes under it.
struct PartialEditBannerSlot: View {
    /// The playlist's key (`AppModel.playlistKey`).
    let key: String
    var spacing: CGFloat = 0
    @Environment(AppModel.self) private var model

    var body: some View {
        if let edit = model.partialEdit(key: key), model.notice?.edit !== edit {
            PartialEditBanner(edit: edit)
                .padding(.bottom, spacing)
        }
    }
}

/// A partly applied edit of the playlist whose failure notice was closed: the playlist takes no other edit until the
/// listener picks one of these (`AppModel.PlaylistEditState.partial`). The same buttons as the notice.
struct PartialEditBanner: View {
    let edit: PlaylistEdit
    @Environment(AppModel.self) private var model
    #if DEBUG
    @Environment(\.playlistPageProbe) private var probe
    #endif

    /// Its buttons, in order: Undo (a removal with songs out), Try Again (when a second attempt can work), Leave As Is.
    private var buttons: [(title: String, run: () -> Void)] {
        var buttons: [(title: String, run: () -> Void)] = []
        if case .remove = edit.goal, edit.canPutBack { buttons.append(("Undo", { model.undoPartial(edit) })) }
        if edit.canRetry { buttons.append(("Try Again", { model.tryAgain(edit) })) }
        buttons.append(("Leave As Is", { model.leaveAsIs(edit) }))
        return buttons
    }

    var body: some View {
        let buttons = buttons
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("The last change to this playlist isn’t finished").font(.headline)
                Text(edit.failureText ?? "").font(.callout).foregroundStyle(.readableSecondary).lineLimit(2)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                ForEach(buttons, id: \.title) { button in
                    Button(button.title, action: button.run)
                }
            }
            .fixedSize()
        }
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .modifier(LayoutProbe(key: "playlist-edit-banner"))
        #if DEBUG
        .onChange(of: buttons.map(\.title), initial: true) { probe?.editBanner = Dictionary(uniqueKeysWithValues: self.buttons.map { ($0.title, $0.run) }) }
        .onDisappear { probe?.editBanner = nil }
        #endif
        // Edge to edge with the list's header rule: the list's reading width, inset by its rows' 10 pt.
        .padding(.horizontal, 10)
        .frame(maxWidth: Metrics.trackListMaxWidth(.playlist), alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
