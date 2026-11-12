import OpenMusicCore
import SwiftUI

/// Home and New: shelves from every active service, merged under one page.
struct BrowsePage: View {
    enum Kind: String { case home, explore }
    let kind: Kind

    @Environment(AppModel.self) private var model
    /// What the page shows, kept apart from `model.cache` so "Try Again" (which empties that cache to force a
    /// refresh) still has the shelves to keep for a service whose refresh fails again.
    @State private var shown = ShownResults()

    private var title: String { kind == .home ? "Home" : "New" }

    /// Home greets by time of day; New keeps its name.
    private var pageTitle: String {
        guard kind == .home else { return title }
        let hour = Calendar.current.component(.hour, from: .now)
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }
    private var capability: ProviderCapabilities { kind == .home ? .home : .explore }

    var body: some View {
        // Signed-out Spotify isn't asked (it can only answer "sign in"); it gets one quiet link by the title.
        let providers = model.browseProviders(capability)
        if providers.isEmpty {
            NoServicesView(title: title)
        } else {
            let ids = providers.map(\.id.rawValue).joined(separator: "+")
            // Keyed by who each service sends its requests as (`session`: its generation changes with every swap of
            // credentials), so another account never sees this one's shelves, in memory or on disk.
            let sessions = Self.sessions(providers)
            let page = "\(kind == .home ? "home" : "explore"):\(ids)"
            let key = "\(page):" + providers.map { "\($0.id.rawValue)#\(sessions[$0.id]?.generation ?? 0)" }.joined(separator: "+")
            let disk = model.isMock ? nil : BrowseDiskCache.diskAccounts(sessions).map { accounts in
                let diskKey = BrowseDiskCache.Key(page: page, accounts: accounts)
                return LoadableDisk(load: { await BrowseDiskCache.shared.load(diskKey) },
                                    save: { value in
                                        // Only what was answered by the sessions the key names.
                                        guard Self.unchanged(providers, sessions) else { return }
                                        BrowseDiskCache.shared.save(value, key: diskKey)
                                    })
            }
            Loadable(key: key, disk: disk) {
                try await load(providers, sessions: sessions, key: key)
            } content: { results in
                let _ = shown.remember(results, for: key)
                ScrollPage(title: pageTitle, titleStyle: kind == .home ? .greeting : .page) {
                    content(results, glyphs: providers.count > 1)
                } accessory: {
                    ConnectLinks(providers: model.browseProvidersNeedingSignIn(capability), purpose: title)
                }
            } placeholder: {
                // Each section's final shape (Home's featured card and song rows; New's releases, mood tiles and
                // videos), so sections don't rearrange when the data arrives.
                ScrollPage(title: pageTitle, titleStyle: kind == .home ? .greeting : .page) {
                    ShelvesSkeleton(sections: kind == .home ? [.featured, .songs, .cards, .cards] : [.cards, .tiles, .videos, .videos])
                } accessory: {
                    ConnectLinks(providers: model.browseProvidersNeedingSignIn(capability), purpose: title)
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ results: [ProviderResult<[Shelf]>], glyphs: Bool) -> some View {
        let merged = interleave(results.map { r in (r.value ?? []).map { (r.provider, $0) } })
        // Home leads with one listening choice, then Quick picks; later shelves step down a size.
        // Up to three, each from its own shelf, passing over what's already pinned in the sidebar.
        let features = kind == .home
            ? HomeFeature.picks(from: merged, avoiding: Set(model.collections.pinned.map(\.id)), limit: FeaturedRow.maxCards)
            : []
        // In a short window, Quick picks may sit beside the featured card (`HomeLead`); then it isn't repeated below.
        let besideFirst = !features.isEmpty && merged.first.map { HomeLead.canPair($0.1) } == true
        if !features.isEmpty {
            HomeLead(features: features, first: besideFirst ? merged.first : nil, glyphs: glyphs)
        }
        ForEach(Array(merged.enumerated()), id: \.element.1.id) { index, entry in
            // Home's first shelf is the "what to play now" answer, so it gets bigger cards and rows.
            ShelfView(shelf: entry.1, provider: entry.0, showsGlyph: glyphs, featured: kind == .home && index == 0,
                      excluding: HomeFeature.excluded(from: entry.1, by: features))
                .environment(\.sectionTitleFont, kind == .home && index > 0 ? .secondarySectionTitle : .sectionTitle)
                .modifier(HiddenWhenPaired(paired: besideFirst && index == 0))
                // The council capture scrolls Home until a named shelf is on screen.
                .modifier(LayoutProbe(key: "shelf-\(entry.1.title.lowercased())"))
                .environment(\.carouselProbe, LayoutProbe.enabled ? "shelf-\(entry.1.title.lowercased())" : nil)
        }
        ForEach(results.filter { $0.error != nil }, id: \.provider) { failed in
            ProviderFailureRow(provider: failed.provider, message: failed.error ?? "", showsSaved: !(failed.value ?? []).isEmpty)
        }
        if merged.isEmpty, results.allSatisfy({ $0.error == nil }) {
            EmptyStateView(symbol: "music.note.house", title: "Nothing here yet", message: "Listen to a few songs and recommendations will show up here.")
        }
    }

    private func load(_ providers: [any MusicProvider], sessions: [ProviderID: ProviderSession], key: String) async throws -> [ProviderResult<[Shelf]>] {
        // What the page shows now, kept for any service whose refresh fails. Read from the page itself first: "Try
        // Again" empties `model.cache` before calling this.
        try await Self.fetch(providers, kind: kind, sessions: sessions, shown: Self.displayed(for: key, shown: shown, cache: model.cache))
    }

    /// The shelves on screen for `key`: what the page rendered, else what the page cache holds.
    static func displayed(for key: String, shown: ShownResults, cache: PageCache) -> [ProviderResult<[Shelf]>]? {
        shown.results(for: key) ?? cache.value(for: key)?.value
    }

    /// Each provider's session, read once when the page is keyed.
    static func sessions(_ providers: [any MusicProvider]) -> [ProviderID: ProviderSession] {
        Dictionary(providers.map { ($0.id, $0.session) }, uniquingKeysWith: { first, _ in first })
    }

    /// True while every provider still sends requests as the session the page was keyed by, and none is changing.
    static func unchanged(_ providers: [any MusicProvider], _ sessions: [ProviderID: ProviderSession]) -> Bool {
        providers.allSatisfy { $0.session == sessions[$0.id] && $0.session.identity != .changing }
    }

    /// Asks every provider for the page. Throws `CancellationError`, so nothing is shown under the key or saved,
    /// when a session differs from `sessions` before or after the requests: they may have been answered as another
    /// account (a sign-in landing, a sign-out) than the one the key and its disk file belong to. The page is then
    /// keyed again by the new session and loads for it.
    static func fetch(_ providers: [any MusicProvider], kind: Kind, sessions: [ProviderID: ProviderSession],
                      shown: [ProviderResult<[Shelf]>]?) async throws -> [ProviderResult<[Shelf]>] {
        guard unchanged(providers, sessions) else { throw CancellationError() }
        let tasks = providers.map { p in
            (p.id, Task { try await kind == .home ? p.home() : p.explore() })
        }
        var out: [ProviderResult<[Shelf]>] = []
        for (id, task) in tasks {
            do {
                out.append(ProviderResult(provider: id, value: try await task.value, error: nil))
            } catch {
                out.append(ProviderResult(provider: id, value: nil, error: error.localizedDescription))
            }
        }
        guard unchanged(providers, sessions) else { throw CancellationError() }
        return keepingShown(out, shown: shown)
    }

    /// A service whose refresh failed keeps the shelves already shown for it, with the error alongside: offline,
    /// Home stays as it was instead of turning into error rows. The result isn't written to disk (it has an error).
    nonisolated static func keepingShown(_ fresh: [ProviderResult<[Shelf]>], shown: [ProviderResult<[Shelf]>]?) -> [ProviderResult<[Shelf]>] {
        fresh.map { result in
            guard result.error != nil,
                  let saved = shown?.first(where: { $0.provider == result.provider })?.value, !saved.isEmpty
            else { return result }
            return ProviderResult(provider: result.provider, value: saved, error: result.error)
        }
    }
}

/// The shelves a page last showed, by page key. A plain reference (not observed): written while the page renders,
/// read when it refreshes.
final class ShownResults {
    private var key: String?
    private var results: [ProviderResult<[Shelf]>]?

    func remember(_ results: [ProviderResult<[Shelf]>], for key: String) {
        self.key = key
        self.results = results
    }

    func results(for key: String) -> [ProviderResult<[Shelf]>]? {
        self.key == key ? results : nil
    }
}

/// The one listening choice Home leads with, picked from Home's own shelves.
struct HomeFeature: Equatable {
    let item: MediaItem
    let provider: ProviderID
    let shelfID: String
    let shelfTitle: String

    /// Shelves of things picked for this listener, in order of preference.
    static let personalShelves = ["mixed for you", "listen again", "your mixes", "made for you", "your top mixes", "recently played"]

    /// A personal shelf's first mix, playlist or album; else the first mix anywhere (YouTube's generated mixes
    /// have `RDTMAK`/`RDAMPL`/`RDMM`/`RDEM` ids, or "Mix" in an editorial title); else the first playlist shelf's
    /// first playlist. Songs, artists and mood tiles are never featured.
    static func pick(from shelves: [(ProviderID, Shelf)]) -> HomeFeature? {
        picks(from: shelves, limit: 1).first
    }

    /// Up to `limit` choices in the same order of preference, at most one per shelf (so each shelf below leaves out
    /// just its own). Items in `avoiding` (already pinned in the sidebar, by `SidebarEntry` id) are passed over
    /// while anything else qualifies; with nothing else, they're used after all.
    static func picks(from shelves: [(ProviderID, Shelf)], avoiding: Set<String> = [], limit: Int) -> [HomeFeature] {
        func feature(_ entry: (ProviderID, Shelf), _ item: MediaItem) -> HomeFeature {
            HomeFeature(item: item, provider: entry.0, shelfID: entry.1.id, shelfTitle: entry.1.title)
        }
        func collect(avoiding: Set<String>) -> [HomeFeature] {
            var out: [HomeFeature] = []
            func take(_ entry: (ProviderID, Shelf), _ matches: (MediaItem) -> Bool) {
                guard out.count < limit, !out.contains(where: { $0.shelfID == entry.1.id }) else { return }
                let shown = Set(out.map(\.item.id))
                if let item = entry.1.items.first(where: { item in
                    matches(item) && !shown.contains(item.id) && !avoiding.contains(SidebarEntry.item(item).id)
                }) {
                    out.append(feature(entry, item))
                }
            }
            for name in personalShelves {
                if let entry = shelves.first(where: { $0.1.title.lowercased().contains(name) }) { take(entry, isCollection) }
            }
            for entry in shelves { take(entry, isMix) }
            for entry in shelves where entry.1.style == .carousel || entry.1.style == .hero {
                take(entry) { if case .playlist(let p) = $0 { !p.isCategory } else { false } }
            }
            return out
        }
        let preferred = collect(avoiding: avoiding)
        return preferred.isEmpty ? collect(avoiding: []) : preferred
    }

    /// The item a shelf leaves out because a featured card already shows it.
    static func excluded(from shelf: Shelf, by features: [HomeFeature]) -> String? {
        features.first { $0.shelfID == shelf.id }?.item.id
    }

    static func isCollection(_ item: MediaItem) -> Bool {
        switch item {
        case .playlist(let p): !p.isCategory
        case .album: true
        default: false
        }
    }

    static func isMix(_ item: MediaItem) -> Bool {
        guard case .playlist(let p) = item, !p.isCategory else { return false }
        if ["RDTMAK", "RDAMPL", "RDMM", "RDEM"].contains(where: p.providerID.hasPrefix) { return true }
        // A user's own "PL…" playlist called "Workout Mix" isn't a generated mix.
        guard !p.providerID.hasPrefix("PL") else { return false }
        return p.title.range(of: #"\b(super)?mix\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The card's two description lines: the playlist's description or owner, an album's artists.
    var description: String? {
        switch item {
        case .playlist(let p): [p.summary, p.owner].compactMap { $0?.isEmpty == false ? $0 : nil }.first
        case .album(let a): [a.kind.label, a.artistLine].filter { !$0.isEmpty }.joined(separator: " · ")
        default: nil
        }
    }

    var route: Route? {
        switch item {
        case .playlist(let p): .playlist(p.provider, id: p.providerID, preview: p)
        case .album(let a): .album(a.provider, id: a.providerID, preview: a)
        default: nil
        }
    }
}

/// Home's featured listening choice: large artwork, where it comes from ("From Throwbacks"), a big title, two
/// lines of description, and a big round Play plus Shuffle, on the artwork's own tint like the album hero.
/// Clicking anywhere else on the card opens it.
struct FeaturedCard: View {
    let feature: HomeFeature
    /// Stretch to the height it's offered (beside Quick picks), content centered.
    var fillsHeight = false
    /// One of the row of cards above Quick picks (`FeaturedRow`): 120 pt artwork, one-line title, a smaller Play,
    /// no page inset of its own. 144 pt tall instead of 240.
    var slim = false
    /// Carries the `featured-card` / `featured-play` probes (the first card).
    var probes = true
    /// The text column's widest, when narrower than `textMaxWidth`: a lone card stretched to the page's margin keeps
    /// its text where a 460 pt card would have it (`FeaturedRow`).
    var textLimit: CGFloat? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.isCompactHeight) private var compact
    @State private var hovering = false
    /// Which of the description's one-line variants fits (`FittedLine`); 0 is the whole text.
    @State private var descriptionVariant = 0

    static func descriptionSize(slim: Bool) -> CGFloat { slim ? 13 : 14 }

    /// 128 pt in a short window (judge: 120–144), so the next shelf's covers and captions show at 960×620.
    static func artworkSize(compact: Bool, slim: Bool = false) -> CGFloat { slim ? 120 : compact ? 128 : 200 }
    static func padding(compact: Bool, slim: Bool = false) -> CGFloat { slim || compact ? 12 : 20 }
    /// The text keeps a reading width however wide the card gets.
    static let textMaxWidth: CGFloat = 560
    static let artworkRadius: CGFloat = 8

    var body: some View {
        let item = feature.item
        let art = Self.artworkSize(compact: compact, slim: slim)
        let pad = Self.padding(compact: compact, slim: slim)
        let small = slim || compact
        let isPlaying = feature.route.map { model.isCurrentContext($0) && model.player.isPlaying } ?? false
        let spacing: CGFloat = slim ? 16 : compact ? 20 : 26
        HStack(alignment: .center, spacing: spacing) {
            Button { model.open(item) } label: {
                ArtworkView(artwork: item.artwork, size: art, cornerRadius: Self.artworkRadius)
                    .frame(width: art, height: art)
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(item.title)")

            VStack(alignment: .leading, spacing: 0) {
                // The eyebrow and the description in the album hero's opaque secondary ink (`heroSecondary`): the
                // translucent `.secondary` read about 3.8:1 on the artwork's tint in light mode.
                Text("From \(feature.shelfTitle.titleCased())")
                    .font(.system(size: slim ? 12 : 13, weight: .semibold))
                    .foregroundStyle(.heroSecondary)
                    .lineLimit(1)
                    .opacity(TextContrastProbe.hides ? 0 : 1)
                    .modifier(LayoutProbe(key: probes ? "featured-eyebrow" : "featured-eyebrow-other"))
                Button { model.open(item) } label: {
                    Text(item.title)
                        .font(.system(size: slim ? 22 : compact ? 28 : 34, weight: .heavy))
                        .tracking(slim ? -0.45 : compact ? -0.6 : -0.75)
                        .lineLimit(small ? 1 : 2)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .padding(.top, slim ? 2 : 4)
                if let description = feature.description, !description.isEmpty {
                    // On one line, the variant that fits (`FittedLine`): names dropped before "and more", never a
                    // word cut in half.
                    let variants = small ? FittedLine.variants(of: description) : [description]
                    Text(variants[min(descriptionVariant, variants.count - 1)])
                        .font(.system(size: Self.descriptionSize(slim: slim)))
                        .foregroundStyle(.heroSecondary)
                        .lineLimit(small ? 1 : 2)
                        .opacity(TextContrastProbe.hides ? 0 : 1)
                        .modifier(LayoutProbe(key: probes ? "featured-description" : "featured-description-other"))
                        .padding(.top, slim ? 2 : compact ? 4 : 6)
                        .help(description)
                        .accessibilityLabel(description)
                }
                HStack(spacing: slim ? 8 : 14) {
                    PlayCircleButton(size: slim ? 40 : compact ? 48 : 52, onArtwork: false, isPause: isPlaying) {
                        if let route = feature.route {
                            model.playOrPause(route) { model.play(item) }
                        } else {
                            model.play(item)
                        }
                    }
                    .help(isPlaying ? "Pause" : "Play")
                    .modifier(DebugFrame(key: probes ? "featured-play" : "featured-play-other"))
                    HeroIconButton(symbol: "shuffle", label: "Shuffle") { model.play(item, shuffled: true) }
                }
                .padding(.top, slim ? 8 : compact ? 10 : 16)
            }
            .frame(maxWidth: textLimit ?? Self.textMaxWidth, alignment: .leading)
            // No trailing Spacer: beside one the stack split the room left over after the artwork with it, so the
            // text got about half (the description was cut at 186 of 341 pt); the frame below keeps the card leading.
        }
        .padding(pad)
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .leading)
        // The description's room is the card's width less the artwork, gap and padding (at most the text's reading
        // width); it becomes the index of the variant that fits, which changes only at a few widths, so a resize or
        // sidebar slide doesn't write state on every frame.
        .onGeometryChange(for: Int.self) { [description = small ? feature.description : nil, maxText = textLimit ?? Self.textMaxWidth,
                                            size = Self.descriptionSize(slim: slim)] geo in
            guard let description, !description.isEmpty else { return 0 }
            let room = min(maxText, geo.size.width - 2 * pad - art - spacing)
            return FittedLine.index(of: description, fitting: room, size: size)
        } action: { index in
            descriptionVariant = index
            if LayoutProbe.enabled, small, let description = feature.description, !description.isEmpty {
                let variants = FittedLine.variants(of: description)
                let shown = variants[min(index, variants.count - 1)]
                DebugProbes.note("featured-subtitle|\(item.title)\(fillsHeight ? " (beside Quick Picks)" : "")", "\"\(shown)\" (variant \(index + 1) of \(variants.count), \(Int(FittedLine.width(shown, size: Self.descriptionSize(slim: slim)))) pt)")
            }
        }
        .background {
            // The tint is strongest behind the artwork and title and eases off toward the far end, so a wide
            // window gets a wash rather than a slab of color.
            ArtworkTintFill(artwork: item.artwork)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.35), .init(color: .black.opacity(0.22), location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
                .overlay(Color.primary.opacity(hovering ? 0.03 : 0))
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.artworkRadius + pad, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Self.artworkRadius + pad, style: .continuous))
        .onTapGesture { model.open(item) }
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        .contextMenu { CollectionMenu(item: item) }
        .padding(.horizontal, slim ? 0 : Metrics.pageInset)
        .modifier(DebugFrame(key: probes ? "featured-card" : "featured-card-other"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Featured: \(item.title), from \(feature.shelfTitle)")
    }
}

/// Home's lead: the featured card, with the first song shelf (Quick picks) beside it when the page is wide enough,
/// else under it. In a short window that's what lets the next shelf's covers and captions show above the player
/// bar at 960×620 (stacked, a 128 pt card plus two rows of Quick picks leaves no room for them). In a wide page
/// (1920 pt windows) Quick picks takes two columns beside the card instead of the card stretching into an empty
/// band; the card grows to the row's height.
struct HomeLead: View {
    /// The first is the one beside Quick picks; stacked, up to three share a row (`FeaturedRow`).
    let features: [HomeFeature]
    /// The first shelf, when it can sit with the card.
    let first: (ProviderID, Shelf)?
    let glyphs: Bool

    @Environment(\.isCompactHeight) private var compact

    /// Only a song shelf pairs with the card (cards beside it would be too small).
    static func canPair(_ shelf: Shelf) -> Bool { shelf.style == .trackList && !shelf.isCategoryShelf }

    var body: some View {
        if let first {
            ViewThatFits(in: .horizontal) {
                HomeLeadRow(minimumWidth: compact ? 720 : 1500, share: compact ? 0.42 : 0.45, trailingWidths: compact ? 300...460 : 640...820) {
                    // The choices stacked, sharing the row's height with Quick picks.
                    VStack(spacing: 12) {
                        ForEach(Array(features.enumerated()), id: \.element.item.id) { index, feature in
                            FeaturedCard(feature: feature, fillsHeight: true, slim: true, probes: index == 0)
                        }
                    }
                    .padding(.leading, Metrics.pageInset)
                    .padding(.trailing, 20)
                    shelf(first).padding(.leading, -20)
                }
                VStack(alignment: .leading, spacing: compact ? 28 : Metrics.sectionSpacing) {
                    FeaturedRow(features: features)
                    shelf(first)
                }
            }
        } else {
            FeaturedRow(features: features)
        }
    }

    private func shelf(_ entry: (ProviderID, Shelf)) -> some View {
        ShelfView(shelf: entry.1, provider: entry.0, showsGlyph: glyphs, featured: true,
                  excluding: HomeFeature.excluded(from: entry.1, by: features))
            .environment(\.sectionTitleFont, .sectionTitle)
    }
}

/// Home's listening choices as a row of slim cards, as many as fit at `minCardWidth` (three in a 1440 pt window
/// with the sidebar, two at 960 pt or beside a panel), so the lead is one short band of picks rather than one tall card whose
/// right half is empty tint. A single card is at most 460 pt, leading-aligned, however wide the row: in a row too
/// narrow for two (960 pt with Playing Next open, a 594 pt row) it once ran to the page's margin, and its tint went on
/// for about 130 pt past the text into an empty right half (round 27).
struct FeaturedRow: View {
    let features: [HomeFeature]
    static let maxCards = 3
    static let minCardWidth: CGFloat = 320
    static let spacing: CGFloat = 16
    /// The widest a card gets when it's the only one in a row that has room for two: the 120 pt artwork and a title
    /// of about 20 characters.
    static let singleCardMaxWidth: CGFloat = 460
    /// A lone card's text column: what it has in a `singleCardMaxWidth` card.
    static let singleCardTextWidth: CGFloat = singleCardMaxWidth - FeaturedCard.artworkSize(compact: false, slim: true)
        - 2 * FeaturedCard.padding(compact: false, slim: true) - 16

    /// Three until the first layout measures the row (the usual 1440 pt window).
    @State private var count = FeaturedRow.maxCards

    var body: some View {
        let most = min(Self.maxCards, features.count)
        // The count comes from the width by arithmetic, written only when it changes. `ViewThatFits` over the 3-, 2-
        // and 1-card rows measured every card (and each card's sentence-fitting text) on each frame of a resize.
        let shown = max(1, min(count, most))
        HStack(spacing: Self.spacing) {
            ForEach(Array(features.prefix(shown).enumerated()), id: \.element.item.id) { index, feature in
                // A card alone keeps its own width at the leading edge: stretched across the page its tint ran on
                // past the text into an empty right half.
                FeaturedCard(feature: feature, slim: true, probes: index == 0, textLimit: shown == 1 ? Self.singleCardTextWidth : nil)
                    .frame(minWidth: 0, maxWidth: shown == 1 ? Self.singleCardMaxWidth : .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: Int.self) { Self.columns(fitting: $0.size.width, most: most) } action: { count = $0 }
        .padding(.horizontal, Metrics.pageInset)
    }

    /// How many cards at least `minCardWidth` wide fit in `width`, from 1 to `most`.
    nonisolated static func columns(fitting width: CGFloat, most: Int) -> Int {
        guard most > 1 else { return 1 }
        return (1...most).last { CGFloat($0) * minCardWidth + CGFloat($0 - 1) * spacing <= width + 0.5 } ?? 1
    }
}

/// The card on the leading side, the song shelf on the trailing `share` of the width (within `trailingWidths`),
/// both as tall as the taller one. Its ideal width is `minimumWidth`, the narrowest page that holds both, which
/// `ViewThatFits` compares with the page's width.
private struct HomeLeadRow: Layout {
    let minimumWidth: CGFloat
    let share: CGFloat
    let trailingWidths: ClosedRange<CGFloat>

    private func widths(_ total: CGFloat) -> (CGFloat, CGFloat) {
        let trailing = min(trailingWidths.upperBound, max(trailingWidths.lowerBound, (total * share).rounded()))
        return (total - trailing, trailing)
    }

    private func height(_ total: CGFloat, _ subviews: Subviews) -> CGFloat {
        let (a, b) = widths(total)
        return zip(subviews, [a, b]).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? minimumWidth
        return CGSize(width: total, height: height(total, subviews))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (a, b) = widths(bounds.width)
        let h = height(bounds.width, subviews)
        var x = bounds.minX
        for (view, width) in zip(subviews, [a, b]) {
            view.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: width, height: h))
            x += width
        }
    }
}

/// Leaves out the first shelf when `HomeLead` shows it (beside the card, or under it when the page is too narrow
/// for both).
private struct HiddenWhenPaired: ViewModifier {
    let paired: Bool

    func body(content: Content) -> some View {
        if paired { EmptyView() } else { content }
    }
}

/// The way in by the page title. Signed out of everything: one "Sign In" menu offering each service, worded like
/// the welcome sheet's buttons ("Sign in to YouTube Music"), since a lone "Connect Spotify" read as if Spotify were
/// the only account. With one service signed in: "Connect Spotify" for the other, like the search page's. A quiet
/// filled capsule, so it reads as a button rather than a caption.
struct ConnectLinks: View {
    let providers: [any MusicProvider]
    let purpose: String
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.anySignedIn {
            SignInMenu()
        } else {
            HStack(spacing: 16) {
                ForEach(providers, id: \.id) { provider in
                    // Straight to that service's own sign-in sheet.
                    Button("Connect \(provider.id.displayName)") { model.perform(.signIn(provider.id)) }
                        .buttonStyle(PillButtonStyle(prominent: false))
                        .help("Sign in to add \(provider.id.displayName) to \(purpose)")
                        .modifier(LayoutProbe(key: "connect-\(provider.id.rawValue)"))
                }
            }
        }
    }
}

/// "Sign In ⌄": a pill whose menu opens either service's own sign-in sheet. `prominent`: the accent fill with white
/// text that Settings › Accounts and the welcome sheet use for Sign In, as an empty page's one action (the empty
/// Library). Otherwise the quiet gray pill, a secondary way in beside Home's greeting and on Search.
struct SignInMenu: View {
    var prominent = false
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            // Short items under a "Sign in to" heading: the menu opens at the button's leading edge, by the window's
            // right side, where "Sign in to YouTube Music…" ran past it.
            Section("Sign in to") {
                ForEach(model.providers.filter { !$0.isSignedIn }, id: \.id) { provider in
                    Button("\(provider.id.displayName)…") { model.perform(.signIn(provider.id)) }
                        .accessibilityLabel("Sign in to \(provider.id.displayName)")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text("Sign In")
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .accessibilityHidden(true)
            }
        }
        .menuStyle(.button)
        .buttonStyle(PillButtonStyle(prominent: false, accent: prominent))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sign in to YouTube Music or Spotify to see your library")
        .accessibilityLabel("Sign In")
        .modifier(LayoutProbe(key: "home-sign-in"))
    }
}

/// An inline note when one service failed but others loaded.
struct ProviderFailureRow: View {
    let provider: ProviderID
    let message: String
    /// The service's saved shelves are still on the page.
    var showsSaved = false
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            ServiceGlyph(provider: provider, size: 16, always: true)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(provider.displayName) \(showsSaved ? "didn't refresh" : "didn't load")").font(.headline)
                Text(message).font(.callout).foregroundStyle(.readableSecondary).lineLimit(2)
            }
            Spacer()
            if let action = AccountAction.forService(provider, in: model) {
                Button("Sign In to \(provider.displayName)…") { model.perform(action) }
                    .modifier(LayoutProbe(key: "failure-sign-in-\(provider.rawValue)"))
            } else {
                Button("Try Again") { model.cache.invalidate(prefix: "home"); model.cache.invalidate(prefix: "explore"); model.refreshTick += 1 }
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, Metrics.pageInset)
    }
}

/// Shown when no service offers this page: the filter shows a service that isn't signed in, or nothing is connected.
struct NoServicesView: View {
    let title: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let filtered = model.serviceFilter.provider.flatMap { model.provider($0) }
        Group {
        if let filtered, !filtered.isSignedIn {
            EmptyStateView(
                symbol: "person.crop.circle",
                title: "\(filtered.id.displayName) isn't signed in",
                message: "Sign in to see \(title) from \(filtered.id.displayName), or show music from all services."
            ) {
                HStack(spacing: 10) {
                    Button("Sign In to \(filtered.id.displayName)…") { model.perform(.signIn(filtered.id)) }
                        .buttonStyle(PillButtonStyle(prominent: true))
                        .modifier(LayoutProbe(key: "no-services-sign-in"))
                    Button("Show All Services") { model.serviceFilter = .all }
                        .buttonStyle(PillButtonStyle(prominent: false))
                }
            }
        } else {
            EmptyStateView(
                symbol: "music.note.house",
                title: "\(title) isn't available here",
                message: "Try another service in the sidebar filter."
            ) {
                Button("Show All Services") { model.serviceFilter = .all }
                    .buttonStyle(PillButtonStyle(prominent: false))
            }
        }
        }
        .pageBackground()
    }
}

/// "See All" for a shelf.
struct SeeAllPage: View {
    let provider: ProviderID
    let shelf: Shelf
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let token = shelf.moreToken, let p = model.provider(provider) {
                Loadable(key: "shelf:\(provider.rawValue):\(token)") {
                    try await p.shelf(moreToken: token)
                } content: { full in
                    ShelfGridPage(shelf: Shelf(id: full.id, title: shelf.title, subtitle: full.subtitle, style: full.style, items: full.items), provider: provider)
                } placeholder: {
                    ScrollPage(title: shelf.title.titleCased()) { GridSkeleton().padding(.top, -20) }
                }
            } else {
                ShelfGridPage(shelf: shelf, provider: provider)
            }
        }
        .navigationTitle(shelf.title.titleCased())
    }
}

private struct ShelfGridPage: View {
    let shelf: Shelf
    let provider: ProviderID

    var body: some View {
        let tracks = shelf.items.compactMap { if case .track(let t) = $0 { t } else { nil } }
        let title = shelf.title.titleCased()
        ScrollPage(title: title) {
            if shelf.isCategoryShelf {
                CategoryTileGrid(categories: shelf.categories)
            } else if tracks.count == shelf.items.count, !tracks.isEmpty {
                TrackListView(tracks: tracks, style: .playlist, context: .init(title: title))
                    .padding(.horizontal, Metrics.pageInset - 10)
            } else {
                MediaGrid(items: shelf.items)
            }
        }
    }
}
