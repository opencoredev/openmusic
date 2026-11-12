import AppKit
import OpenMusicCore
import SwiftUI

struct AlbumPage: View {
    let provider: ProviderID
    let id: String
    let preview: Album?

    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let p = model.provider(provider) {
                Loadable(key: "album:\(provider.rawValue):\(id)") {
                    try await p.album(id: id)
                } content: { detail in
                    AlbumContent(detail: detail)
                } placeholder: {
                    // The same hero as the loaded page, with the parts not known yet as skeletons,
                    // so nothing moves when the album arrives.
                    DetailScaffold(wash: preview?.artwork) {
                        CollectionHero(
                            artwork: preview?.artwork, kind: preview?.kind.label ?? "Album", title: preview?.title,
                            isExplicit: preview?.isExplicit ?? false, meta: preview.map { [$0.year.map(String.init)].compactMap(\.self) } ?? [],
                            service: preview?.provider
                        ) {
                            if let preview { ArtistLinks(artists: preview.artists, provider: preview.provider) }
                        } trailingMeta: {
                            SkeletonBlock(width: 110, height: 12)
                        }
                    } actions: {
                        HeroActionsSkeleton()
                    } body: {
                        TrackListSkeleton(style: .album)
                    }
                    .environment(\.detailListMaxWidth, Metrics.albumTrackListMaxWidth)
                }
            }
        }
        .navigationTitle(preview?.title ?? "Album")
    }
}

func kicker(_ album: Album) -> String {
    [album.kind.label.uppercased(), album.year.map(String.init)].compactMap(\.self).joined(separator: " · ")
}

/// "12 songs, 1 hr 1 min" (or just the count when durations are missing or the list isn't complete).
/// `length` gives each song's length; pages pass `model.displayDuration(for:)`, so once the player knows a
/// song's real length the total is the sum of the lengths the rows show.
/// `copies` counts a song a playlist holds more than once that many times in the total length (one row, two entries).
/// `count` is the service's count of entries; when the rows and their copies come to fewer (entries left out, such as
/// Spotify's local files and episodes), those entries' lengths are unknown, so there is no total length.
func songCountLine(count: Int, tracks: [Track], complete: Bool = true, copies: [String: Int] = [:],
                   length: (Track) -> TimeInterval? = { $0.duration }) -> String {
    let songs = "\(count) song\(count == 1 ? "" : "s")"
    guard complete, !tracks.isEmpty else { return songs }
    let listed = tracks.reduce(0) { $0 + max(1, copies[$1.id] ?? 1) }
    guard listed >= count else { return songs }
    let lengths = tracks.map(length)
    guard lengths.allSatisfy({ $0 != nil }) else { return songs }
    let total = zip(tracks, lengths).reduce(0) { $0 + ($1.1 ?? 0) * TimeInterval(max(1, copies[$1.0.id] ?? 1)) }
    return total > 0 ? "\(songs), \(total.spokenLength)" : songs
}

/// "· 14 songs, 1 hr 2 min" at the end of a hero's meta line. Its own view, so learning a song's real length
/// redraws only this line, not the whole page.
struct SongCountMeta: View {
    let count: Int
    let tracks: [Track]
    var complete = true
    /// A playlist's copies per song (`PlaylistPager.copies`), so the length counts every entry.
    var copies: [String: Int] = [:]
    @Environment(AppModel.self) private var model

    var body: some View {
        let line = songCountLine(count: count, tracks: tracks, complete: complete, copies: copies, length: { model.displayDuration(for: $0) })
        Text("·").foregroundStyle(.heroSecondary)
        Text(line)
            .foregroundStyle(.heroSecondary)
            // Council captures compare the line before and after sorting (`playlist-sorted`).
            .onChange(of: line, initial: true) { if LayoutProbe.enabled { DebugProbes.note("song-count", line) } }
    }
}

private struct AlbumContent: View {
    let detail: AlbumDetail
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var sort: TrackSort = .original

    var body: some View {
        let album = detail.album
        let route = Route.album(album.provider, id: album.providerID, preview: album)
        let context = AppModel.PlayingFrom(title: album.title, route: route)
        let filterable = detail.tracks.count > TrackFilter.minimumCount
        let listing = TrackListing(tracks: detail.tracks, query: query, sort: sort, enabled: filterable, length: { model.displayDuration(for: $0) })
        let reordered = listing.filtering || !sort.isOriginal
        DetailScaffold(wash: album.artwork) {
            CollectionHero(
                artwork: album.artwork, kind: album.kind.label, title: album.title, isExplicit: album.isExplicit,
                meta: [album.year.map(String.init)].compactMap(\.self), service: album.provider
            ) {
                ArtistLinks(artists: album.artists, provider: album.provider)
            } trailingMeta: {
                SongCountMeta(count: detail.tracks.count, tracks: detail.tracks)
            }
        } actions: {
            HeroActions(item: .album(album), route: route, enabled: !detail.tracks.isEmpty,
                        sorting: filterable ? TrackSorting(sort: $sort, options: [.original, .title, .artist, .duration]) : nil) { shuffled in
                // Play: the whole album in the order shown, from its first song (Pause and Resume when it's playing
                // are `HeroActions`'s).
                let order = filterable ? sort : .original
                model.play(order.headerQueue(detail.tracks, shuffled: shuffled, length: { model.displayDuration(for: $0) }), shuffled: shuffled, from: context)
            }
        } tools: {
            if filterable {
                TrackFilterField(text: $query, prompt: "Find in album")
            }
        } body: {
            VStack(alignment: .leading, spacing: 32) {
                if listing.shown.isEmpty, listing.filtering {
                    NoFilterMatches(query: query) { query = "" }
                } else {
                    // Filtered or sorted rows keep their track numbers. Play from a row plays the whole album from
                    // that song, in the order shown (sorted, or the album's own order).
                    TrackListView(
                        tracks: listing.shown.map { detail.tracks[$0] }, style: .album, context: context,
                        albumArtist: album.artistLine,
                        onPlay: { index in
                            guard let start = listing.playStart(forRow: index) else { return }
                            model.play(listing.playOrder.map { detail.tracks[$0] }, startAt: start, from: context)
                        },
                        rowNumbers: reordered ? listing.shown.map { detail.tracks[$0].trackNumber ?? $0 + 1 } : nil,
                        sort: filterable ? $sort : nil
                    )
                }
                AboutBlock(title: album.title, text: detail.summary, footnote: AlbumFootnote.cleaned(detail.footnote))
            }
        } footer: {
            if !detail.moreByArtist.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "More by \(album.artists.first?.name ?? album.artistLine)")
                    Carousel(items: detail.moreByArtist.map(MediaItem.album)) { MediaCard(item: $0) }
                        .environment(\.cardSubtitleStyle, .discography)
                }
            }
        }
        // The action row's trailing tools end where the album's narrower track list does.
        .environment(\.detailListMaxWidth, Metrics.albumTrackListMaxWidth)
    }
}

/// Hero, actions, body and footer, shared by album and playlist pages. The artwork's color fills the hero,
/// reaching up behind the toolbar, and fades into the page background below the actions.
///
/// Like Music's, the actions sit in the text column beside the artwork, under the meta line, whenever that column
/// holds the whole action row; only a narrow pane puts them on their own line below. That keeps nine album rows
/// above the player at 900 pt tall. In a short window (`Metrics.compactHeight`) the hero also uses smaller artwork
/// and tighter spacing, so at least five songs show at 960×620. Type sizes don't change.
///
/// Every part fits any pane width down to the split view's 420 pt minimum (with the queue open, say). Which
/// arrangement is used comes from the scroll view's own width (the pane's) through `onGeometryChange`, never from
/// a width stored elsewhere: a stored width went stale when the queue opened, the page kept the sidebar-width
/// arrangement, and SwiftUI centered and clipped the too-wide page in its pane.
struct DetailScaffold<Header: View, Actions: View, Tools: View, Body: View, Footer: View>: View {
    var wash: Artwork?
    @ViewBuilder var header: Header
    @ViewBuilder var actions: Actions
    /// Sort menu and Find field, at the trailing end of the actions; they wrap onto their own line when the row
    /// is too narrow.
    @ViewBuilder var tools: Tools
    @ViewBuilder var body_: Body
    @ViewBuilder var footer: Footer

    init(wash: Artwork? = nil, @ViewBuilder header: () -> Header, @ViewBuilder actions: () -> Actions, @ViewBuilder tools: () -> Tools,
         @ViewBuilder body: () -> Body, @ViewBuilder footer: () -> Footer) {
        self.wash = wash
        self.header = header()
        self.actions = actions()
        self.tools = tools()
        self.body_ = body()
        self.footer = footer()
    }

    var body: some View {
        DetailScaffoldLayout(wash: wash, header: header, actions: actions, tools: tools, body_: body_, footer: footer)
            .compactHeightEnvironment()
    }
}

private struct DetailScaffoldLayout<Header: View, Actions: View, Tools: View, Body: View, Footer: View>: View {
    let wash: Artwork?
    let header: Header
    let actions: Actions
    let tools: Tools
    let body_: Body
    let footer: Footer

    @Environment(\.showsServiceMarks) private var showsMarks
    @Environment(\.isCompactHeight) private var compact
    @Environment(\.detailListMaxWidth) private var listMaxWidth
    @State private var heroHeight: CGFloat = 300
    /// The actions' narrowest one-line width, measured once by a hidden copy (`actionsMinimum`).
    @State private var actionsWidth: CGFloat?
    /// The tools' narrowest width, by the same hidden copy; 0 when the page shows none.
    @State private var toolsWidth: CGFloat = 0
    /// The pane's last width, for deciding again when the row's measurement changes. A reference, so recording it
    /// on every frame of a resize doesn't update the view.
    @State private var paneWidth = PaneWidth()

    private final class PaneWidth { var value: CGFloat = 0 }

    /// Beside the artwork or below it, from the pane's last width and the row's measured width; writes only a change.
    private func decideInline() {
        guard paneWidth.value > 0 else { return }
        let row = actionsWidth.map { CollectionHeroMetrics.rowWidth(actions: $0, tools: toolsWidth, compact: compact) }
        let fits = CollectionHeroMetrics.fitsInline(paneWidth: paneWidth.value, actions: row, compact: compact)
        if inline != fits { inline = fits }
    }
    @State private var inline = true

    var body: some View {
        let rowWidth = actionsWidth.map { CollectionHeroMetrics.rowWidth(actions: $0, tools: toolsWidth, compact: compact) }
        let compact = compact
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Beside the artwork when the text column holds the whole action row, else below it. Decided from
                // the width through the row's width measured once, not by `ViewThatFits`: that measured the whole
                // hero (title, description, actions) twice on every frame while the sidebar slid.
                if inline { heroBlock(inline: true) } else { stackedBlock }
                body_
                    .padding(.horizontal, Metrics.pageInset - 10)
                footer
                    .padding(.top, Metrics.sectionSpacing)
            }
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .topLeading) { actionsMinimum }
            .modifier(LayoutProbe(key: "page-content"))
            // Everything below the header comes from the page's own service.
            .environment(\.showsServiceMarks, false)
            .background(alignment: .top) {
                HeroWash(artwork: wash, heroHeight: heroHeight)
            }
        }
        // The scroll view's width is the pane's, whatever its content asks for, so the choice can't feed itself.
        // The width, not the answer: reporting the Bool, SwiftUI skipped the action when the answer went back to
        // true. Opening Lyrics at 1440 pt took the pane through 464 and 420 pt (false) and on to 928 pt, where the
        // transform said true and the action never ran, so the actions stayed below the cover. The action runs
        // per width but writes `inline` only when the answer changes; a new row measurement decides again from
        // the last width.
        .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { width in
            paneWidth.value = width
            decideInline()
        }
        .onChange(of: rowWidth) { decideInline() }
        .onChange(of: compact) { decideInline() }
        .pageBackground()
    }

    private func heroBlock(inline: Bool) -> some View {
        header
            .environment(\.heroInlineActions, inline ? AnyView(oneLineRow) : nil)
            .padding(.horizontal, Metrics.pageInset)
            .padding(.top, compact ? 12 : 22)
            .padding(.bottom, compact ? (inline ? 12 : 10) : (inline ? 16 : 18))
            .environment(\.showsServiceMarks, showsMarks)
            // The wash is solid behind the header and fades out from its bottom edge.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heroHeight = $0 }
    }

    private var stackedBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            heroBlock(inline: false)
            // As wide as the track table's content, so a trailing control lines up with the durations.
            ViewThatFits(in: .horizontal) {
                oneLineRow
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: compact ? 14 : 18) { actions }
                    HStack(spacing: 14) { tools }
                }
            }
            .frame(maxWidth: listMaxWidth - 20, alignment: .leading)
            .padding(.horizontal, Metrics.pageInset)
            .padding(.top, compact ? 10 : 4)
            .padding(.bottom, compact ? 10 : 16)
        }
    }

    /// Hidden copies of the actions and of the tools at their ideal (narrowest) widths, measured apart: the row is
    /// their sum plus the gap between them, and the gap counts only when the tools take room
    /// (`CollectionHeroMetrics.rowWidth`). Measuring the whole one-line row also counted the spacer and tools slot
    /// an album page passes even when it shows no tools (an `if` with nothing in it isn't `EmptyView`): 354.5 pt for
    /// a 306 pt row. They're measured when their content changes, not while the pane's width does: their proposal
    /// never changes.
    private var actionsMinimum: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: compact ? 14 : 18) { actions }
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    if actionsWidth != width { actionsWidth = width }
                    if LayoutProbe.enabled { DebugProbes.note("hero-actions-width", "\(Int(width.rounded()))") }
                }
            if Tools.self != EmptyView.self {
                HStack(spacing: 14) { tools }
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                        if toolsWidth != width { toolsWidth = width }
                        if LayoutProbe.enabled { DebugProbes.note("hero-tools-width", "\(Int(width.rounded()))") }
                    }
            }
        }
            .frame(width: 0, height: 0, alignment: .topLeading)
            .environment(\.isLayoutMeasurement, true)
            .hidden()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Play, Shuffle, Share and More, then the tools at the trailing end. Its ideal width holds the Find field at
    /// its minimum, so `ViewThatFits` keeps one line as long as that fits; the field then grows into the room.
    private var oneLineRow: some View {
        HStack(spacing: compact ? 14 : 18) {
            actions
            if Tools.self != EmptyView.self {
                Spacer(minLength: 12)
                // Before the spacer, so the Find field grows to its full width first.
                HStack(spacing: 14) { tools }
                    .layoutPriority(1)
            }
        }
        .modifier(LayoutProbe(key: "hero-actions"))
    }
}

extension EnvironmentValues {
    /// The page's actions, when a short window puts them inside the hero beside the artwork.
    @Entry var heroInlineActions: AnyView? = nil
    /// The widest the page's track table grows (rows' padding included): the action row's tools end where it does.
    @Entry var detailListMaxWidth: CGFloat = Metrics.trackTableMaxWidth
}

enum CollectionHeroMetrics {
    /// Artwork in a short window (judge: about 144–160 pt).
    static let compactArtwork: CGFloat = 144
    static let spacing: CGFloat = 24

    /// The artwork's size for a hero `width` points wide. Narrow panes (the queue open in a small window) get
    /// smaller artwork, so the title keeps some room.
    static func artwork(width: CGFloat, compact: Bool) -> CGFloat {
        compact
            ? (width < 520 ? 112 : compactArtwork)
            : width < 480 ? 128 : width < 560 ? 150 : width < 760 ? 190 : 232
    }

    /// The one-line action row's narrowest width from its parts: the actions, then, when the page shows tools, the
    /// row's spacing, the 12 pt spacer, the spacing again and the tools (`DetailScaffoldLayout.oneLineRow`).
    static func rowWidth(actions: CGFloat, tools: CGFloat, compact: Bool) -> CGFloat {
        guard tools > 0.5 else { return actions }
        return actions + 2 * (compact ? 14 : 18) + 12 + tools
    }

    /// Whether the action row, `actions` points at its narrowest, fits in the text column beside the artwork in a
    /// pane `paneWidth` wide. Before the row is measured, yes (the usual case).
    static func fitsInline(paneWidth: CGFloat, actions: CGFloat?, compact: Bool) -> Bool {
        guard let actions else { return true }
        let hero = paneWidth - Metrics.pageInset * 2
        return hero - artwork(width: hero, compact: compact) - spacing >= actions - 0.5
    }
}

extension DetailScaffold where Footer == EmptyView {
    init(wash: Artwork? = nil, @ViewBuilder header: () -> Header, @ViewBuilder actions: () -> Actions, @ViewBuilder tools: () -> Tools,
         @ViewBuilder body: () -> Body) {
        self.init(wash: wash, header: header, actions: actions, tools: tools, body: body, footer: { EmptyView() })
    }
}

extension DetailScaffold where Tools == EmptyView {
    init(wash: Artwork? = nil, @ViewBuilder header: () -> Header, @ViewBuilder actions: () -> Actions,
         @ViewBuilder body: () -> Body, @ViewBuilder footer: () -> Footer) {
        self.init(wash: wash, header: header, actions: actions, tools: { EmptyView() }, body: body, footer: footer)
    }
}

extension DetailScaffold where Tools == EmptyView, Footer == EmptyView {
    init(wash: Artwork? = nil, @ViewBuilder header: () -> Header, @ViewBuilder actions: () -> Actions, @ViewBuilder body: () -> Body) {
        self.init(wash: wash, header: header, actions: actions, tools: { EmptyView() }, body: body, footer: { EmptyView() })
    }
}

/// Artwork on the left; the kind, a big title and a meta line that reads like a sentence on the right:
/// "Daft Punk · 2001 · 14 songs, 1 hr 1 min". A nil title draws a skeleton in its place.
struct CollectionHero<Lead: View, TrailingMeta: View>: View {
    let artwork: Artwork?
    let kind: String
    let title: String?
    var isExplicit = false
    var description: String? = nil
    /// Plain parts after the lead (year, song count).
    var meta: [String] = []
    /// The service's tag right after the lead ("Olivia Rodrigo · ◉ YouTube Music · 2026").
    var service: ProviderID? = nil
    /// The first part of the meta line: artist links or the owner.
    @ViewBuilder var lead: Lead
    /// Extra content at the end of the meta line (a skeleton while loading).
    @ViewBuilder var trailingMeta: TrailingMeta

    @State private var width: CGFloat = 900
    @Environment(\.isCompactHeight) private var compact
    @Environment(\.heroInlineActions) private var inlineActions
    @Environment(\.detailListMaxWidth) private var listMaxWidth

    /// The title sizes tried on one line before it wraps: the column's size, then two smaller steps down to 28 pt.
    static func oneLineSizes(_ size: CGFloat) -> [CGFloat] {
        var sizes: [CGFloat] = []
        for factor in [1, 0.9, 0.8] as [CGFloat] {
            let s = max(28, (size * factor).rounded())
            if sizes.last != s { sizes.append(s) }
        }
        return sizes
    }

    private func titleText(_ title: String, size: CGFloat) -> some View {
        Text(title)
            .font(.system(size: size, weight: .bold))
            .tracking(-size * 0.012)
            .textSelection(.enabled)
    }

    var body: some View {
        let art = CollectionHeroMetrics.artwork(width: width, compact: compact)
        let column = width - art - CollectionHeroMetrics.spacing
        let titleSize = Font.collectionTitleSize(width: column)
        // With the actions inside the text column, only they count toward its ideal width (a long title's one-line
        // width would otherwise make the hero ask for more than the pane). Laid out, the title still takes all the
        // room it's given.
        let reading = inlineActions == nil ? nil : CGFloat(0)
        HStack(alignment: .bottom, spacing: CollectionHeroMetrics.spacing) {
            ArtworkView(artwork: artwork, size: art, cornerRadius: 8)
                .frame(width: art, height: art)
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                .shadow(color: .black.opacity(0.28), radius: compact ? 16 : 24, y: compact ? 6 : 10)
            VStack(alignment: .leading, spacing: 0) {
                Text(kind)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.bottom, compact ? 3 : 6)
                if let title {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        // One line when it fits at up to two steps smaller (not under 28 pt), before wrapping: a long
                        // title beside the Lyrics panel otherwise broke into a heavy two-line block. The size comes
                        // from the title's measured width (`TitleWidths`), not from `ViewThatFits` trying each size
                        // on every frame of a resize.
                        let room = column - (isExplicit ? 8 + ExplicitBadge.width(size: compact ? 16 : 20) : 0)
                        if let size = Self.oneLineSizes(titleSize).first(where: { TitleWidths.width(title, size: $0) <= room }) {
                            titleText(title, size: size).lineLimit(1)
                        } else {
                            titleText(title, size: titleSize)
                                .lineLimit(compact ? 1 : 2)
                                .minimumScaleFactor(0.75)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // The badge's own caption font won over a `.font` set from outside, so it drew at 11 pt
                        // beside a 52 pt title.
                        if isExplicit { ExplicitBadge(size: compact ? 16 : 20) }
                    }
                    .frame(minWidth: 0, idealWidth: reading, maxWidth: .infinity, alignment: .leading)
                } else {
                    SkeletonBlock(width: min(360, width * 0.4), height: titleSize * 0.8, radius: 8)
                        .padding(.vertical, titleSize * 0.12)
                }
                if let description, !description.isEmpty {
                    ExpandableText(text: description, lineLimit: compact ? 1 : 2, font: .secondaryText, mode: .popover, title: title, debugKey: "header-more")
                        .foregroundStyle(.heroSecondary)
                        .frame(minWidth: 0, idealWidth: reading, maxWidth: 620, alignment: .leading)
                        .padding(.top, compact ? 4 : 8)
                }
                HStack(spacing: 6) {
                    lead
                        .font(.system(size: 14, weight: .semibold))
                    if let service { HeroServiceMeta(provider: service) }
                    ForEach(meta, id: \.self) { part in
                        Text("·").foregroundStyle(.heroSecondary)
                        Text(part).foregroundStyle(.heroSecondary)
                    }
                    trailingMeta
                }
                .font(.system(size: 14))
                .monospacedDigit()
                .lineLimit(1)
                .frame(minWidth: 0, idealWidth: reading, maxWidth: .infinity, alignment: .leading)
                .padding(.top, compact ? 6 : 12)
                if let inlineActions {
                    // A trailing Find field ends over the track list's durations, not past them.
                    inlineActions
                        .frame(maxWidth: max(0, listMaxWidth - 20 - art - CollectionHeroMetrics.spacing), alignment: .leading)
                        .padding(.top, compact ? 10 : 16)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// The one action row of album, playlist and artist pages, as in Music: the oversized round Play (Pause while this
/// collection plays, Resume when paused), then labeled capsules: Shuffle; Add/Added (library) or Follow/Following;
/// Radio where the service makes one from this collection (artists, playlists); then More (…), with the rest of the
/// collection's menu, Copy Link included. `onPhoto` is the artist header: a white Play, and dark glass capsules with
/// white labels so they read over any photo. A narrow artist header drops the capsules' words (`.labelStyle(.iconOnly)`).
struct HeroActions: View {
    let item: MediaItem
    let route: Route
    var enabled = true
    var onPhoto = false
    /// The follow or saved flag the page itself loaded, when the item's listing carried none (an artist's page).
    var reported: Bool? = nil
    /// The artist's radio seed from its page, when it has one.
    var radioSeed: String? = nil
    /// A long album or playlist's sort, offered as More › Sort By.
    var sorting: TrackSorting? = nil
    let play: (_ shuffled: Bool) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.isCompactHeight) private var compact
    /// The artist header draws dark text on a light shade: the page's buttons, at the header's sizes.
    @Environment(\.artistHeroDarkText) private var darkText

    /// On the artist photo with white text: the white Play and the glass capsules.
    private var photo: Bool { onPhoto && !darkText }

    var body: some View {
        let isCurrent = model.isCurrentContext(route)
        let isPlaying = isCurrent && model.player.isPlaying
        HStack(spacing: 10) {
            PlayCircleButton(size: onPhoto ? 52 : compact ? 48 : 56, onArtwork: photo, isPause: isPlaying) {
                model.playOrPause(route) { play(false) }
            }
            .disabled(!enabled)
            .help(isPlaying ? "Pause" : isCurrent ? "Resume" : "Play")
            .modifier(DebugFrame(key: onPhoto ? "artist-play" : "play-button"))
            // The page's saved flag becomes the model's, so cards and menus elsewhere say the same.
            .task(id: item.id) { model.noteSaved(item, reported: reported ?? AppModel.reportedSaved(item)) }
            .padding(.trailing, 4)

            Button { play(true) } label: { Label("Shuffle", systemImage: "shuffle") }
                .buttonStyle(HeroCapsuleStyle(onPhoto: photo))
                .disabled(!enabled)
                .help("Shuffle")
            // The same state as "Add to Library"/"Remove from Library" and "Follow"/"Unfollow" in every context menu.
            if let save = model.saveAction(for: item, reported: reported) {
                let saved = !save.target
                Button { model.setSaved(item, saved: save.target) } label: {
                    Label(saveTitle(saved: saved), systemImage: saved ? "checkmark" : "plus")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(HeroCapsuleStyle(onPhoto: photo))
                .help(save.title)
                .accessibilityLabel(save.title)
                .modifier(DebugFrame(key: isArtist ? "artist-follow" : "hero-save"))
            }
            if let radio {
                Button(action: radio) { Label("Radio", systemImage: "dot.radiowaves.left.and.right") }
                    .buttonStyle(HeroCapsuleStyle(onPhoto: photo))
                    .help("Start Radio")
            }
            HeroMoreButton(item: item, onPhoto: photo, sorting: sorting)
        }
    }

    private var isArtist: Bool { if case .artist = item { true } else { false } }

    private func saveTitle(saved: Bool) -> String {
        isArtist ? (saved ? "Following" : "Follow") : (saved ? "Added" : "Add")
    }

    /// Start Radio, for an artist or playlist on a service with radios.
    private var radio: (() -> Void)? {
        guard model.can(.radio, item.provider) else { return nil }
        switch item {
        case .artist(let a):
            return { model.startRadio(seedID: radioSeed ?? a.extra["radioSeed"] ?? a.providerID, title: a.name, provider: a.provider, origin: item) }
        case .playlist(let p):
            return { model.startRadio(seedID: p.providerID, title: p.title, provider: p.provider, origin: item) }
        default:
            return nil
        }
    }
}

/// The hero's labeled capsules (Shuffle, Add, Follow, Radio) and the Songs page's Shuffle: 32 pt tall, a quiet fill
/// in the label color on the page, or dark glass with white labels over a photo (`HeroButtonStyle`).
struct HeroCapsuleStyle: ButtonStyle {
    var onPhoto = false

    func makeBody(configuration: Configuration) -> some View {
        if onPhoto {
            HeroButtonStyle().makeBody(configuration: configuration)
        } else {
            QuietCapsule(configuration: configuration)
        }
    }

    private struct QuietCapsule: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorScheme) private var scheme
        @Environment(\.artistHeroDarkText) private var onPalePhoto
        @State private var hovering = false

        var body: some View {
            configuration.label
                // Hidden for the artist header's contrast capture (`HeroTextProbe`), as the glass capsules' labels.
                .modifier(HeroLabelVisibility())
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .frame(minWidth: 32, minHeight: 32)
                .background {
                    Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hovering && isEnabled ? 0.12 : scheme == .dark ? 0.1 : 0.07))
                        // On the artist photo under dark text: a light pill first, so the label never sits on hair.
                        .background { if onPalePhoto { Capsule().fill(.white.opacity(0.72)) } }
                }
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.4)
                .motionScale(configuration.isPressed ? Motion.pressScale : 1)
                .animation(Motion.press, value: configuration.isPressed)
                .animation(Motion.hover, value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// The hero's More (…): a round button matching the capsules beside it, opening the collection's menu (Play Next,
/// Add to Queue, Pin, Go to Artist, Copy Link…). A `KeyboardMoreButton`, so Tab reaches it with or without the
/// system's Keyboard Navigation setting, and its glyph takes the color given here: white on the artist photo (a
/// SwiftUI `Menu` label drew it in the label color there, near black on the dark glass in light mode).
struct HeroMoreButton: View {
    let item: MediaItem
    var onPhoto = false
    var sorting: TrackSorting? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.artistHeroDarkText) private var onPalePhoto
    @State private var hovering = false
    @State private var focused = false

    var body: some View {
        KeyboardMoreButton(size: 14, focused: $focused, label: "More", weight: .bold, side: 32, circular: true) {
            CollectionMenu(item: item)
            if let sorting {
                Divider()
                SortByMenu(sort: sorting.sort, options: sorting.options)
            }
        }
        .foregroundStyle(onPhoto ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
        .background { fill }
        .onHover { hovering = $0 }
        .modifier(DebugFrame(key: "hero-more"))
    }

    @ViewBuilder private var fill: some View {
        let lit = hovering || focused
        if onPhoto {
            Circle().fill(.black.opacity(lit ? 0.45 : 0.35)).overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 0.5))
        } else {
            Circle().fill(Color.primary.opacity(lit ? 0.12 : scheme == .dark ? 0.1 : 0.07))
                .background { if onPalePhoto { Circle().fill(.white.opacity(0.72)) } }
        }
    }
}

/// A large borderless icon in secondary color that brightens on hover (hero Shuffle, Save, Copy Link).
struct HeroIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(SubtleIconStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Secondary until hovered, primary on hover, 0.96 on press.
struct SubtleIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SubtleIconBody(configuration: configuration)
    }

    private struct SubtleIconBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(hovering && isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .opacity(isEnabled ? 1 : 0.4)
                .motionScale(configuration.isPressed ? Motion.pressScale : 1)
                .animation(Motion.press, value: configuration.isPressed)
                .animation(Motion.hover, value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// The action row while the page loads: same sizes as `HeroActions`, so the track list doesn't move.
struct HeroActionsSkeleton: View {
    @Environment(\.isCompactHeight) private var compact

    var body: some View {
        HStack(spacing: 10) {
            SkeletonBlock(width: compact ? 48 : 56, height: compact ? 48 : 56, circle: true).padding(.trailing, 4)
            SkeletonBlock(width: 96, height: 32, radius: 16)
            SkeletonBlock(width: 76, height: 32, radius: 16)
            SkeletonBlock(width: 32, height: 32, circle: true)
        }
    }
}

/// The album's footnote without what the header already says. YouTube's is the listing's own "14 songs •
/// 1 hour, 1 minute" plus the year: once a song plays as a longer version, that catalog total disagreed with the
/// header's total of the lengths the rows show. Release dates and ℗/© lines stay.
enum AlbumFootnote {
    static func cleaned(_ footnote: String?) -> String? {
        guard let footnote else { return nil }
        let lines = footnote.split(separator: "\n").map { line in
            line.components(separatedBy: CharacterSet(charactersIn: "•·"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !isRepeat($0) }
                .joined(separator: " · ")
        }.filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// A song count, a length ("1 hour, 1 minute", "4 minutes, 35 seconds") or a bare year.
    static func isRepeat(_ part: String) -> Bool {
        let p = part.lowercased()
        if p.range(of: #"^\d{4}$"#, options: .regularExpression) != nil { return true }
        if p.range(of: #"^[\d,.]+ (songs?|tracks?)(, .*)?$"#, options: .regularExpression) != nil { return true }
        return p.range(of: #"^(\d+\+? (hours?|minutes?|seconds?|hr|min|sec),? ?)+$"#, options: .regularExpression) != nil
    }
}

/// The album's notes below the track list, with More to expand them, then the copyright line.
struct AboutBlock: View {
    let title: String
    let text: String?
    var footnote: String? = nil

    var body: some View {
        if (text ?? "").isEmpty, (footnote ?? "").isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let text, !text.isEmpty {
                    Text("About").font(.sectionTitle)
                    ExpandableText(text: text, lineLimit: 3, font: .system(size: 14), lineSpacing: 3, debugKey: "about-more")
                        .foregroundStyle(.readableSecondary)
                        .frame(maxWidth: 680, alignment: .leading)
                }
                if let footnote, !footnote.isEmpty {
                    // The release date and copyright: small, so in the opaque `readableSecondary` gray for 4.5:1
                    // (the tertiary gray read 1.9–2.2:1).
                    Text(footnote)
                        .font(.system(size: 12))
                        .foregroundStyle(.readableSecondary)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 10)
        }
    }
}

/// Artist names as links that brighten on hover.
struct ArtistLinks: View {
    let artists: [ArtistRef]
    let provider: ProviderID
    var base: HierarchicalShapeStyle = .primary
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(artists.enumerated()), id: \.offset) { i, artist in
                if i > 0 { Text(", ").foregroundStyle(base) }
                Button(artist.name) { model.goToArtist(artist, provider: provider) }
                    .buttonStyle(SubtleLinkStyle(base: base))
                    .disabled(artist.id == nil)
            }
        }
        .lineLimit(1)
    }
}

/// One-line widths of hero titles (bold, tracked like `CollectionHero.titleText`), measured with AppKit and kept, so
/// picking a title size during a resize is arithmetic.
@MainActor
enum TitleWidths {
    private static var cache: [String: CGFloat] = [:]

    static func width(_ title: String, size: CGFloat) -> CGFloat {
        let key = "\(size)|\(title)"
        if let width = cache[key] { return width }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .kern: -size * 0.012,
        ]
        // A point of slack for rounding between AppKit's measure and SwiftUI's.
        let width = ceil(NSAttributedString(string: title, attributes: attributes).size().width) + 1
        if cache.count > 500 { cache.removeAll() }
        cache[key] = width
        return width
    }
}
