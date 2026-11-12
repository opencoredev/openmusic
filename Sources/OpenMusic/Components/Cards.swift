import OpenMusicCore
import SwiftUI

/// How a card describes an album: on an artist page the artist is implied, so the year and type say more.
enum CardSubtitleStyle {
    case standard, discography
}

extension EnvironmentValues {
    @Entry var cardSubtitleStyle: CardSubtitleStyle = .standard
}

extension Track {
    /// YouTube music videos (official and user uploads), drawn 16:9 and labeled as videos.
    var isVideo: Bool {
        ["MUSIC_VIDEO_TYPE_OMV", "MUSIC_VIDEO_TYPE_UGC"].contains(extra["musicVideoType"] ?? "")
    }
}

extension MediaItem {
    var isVideo: Bool { if case .track(let t) = self { t.isVideo } else { false } }
}

/// An album, playlist, song or video card: artwork, a title of up to two lines, and a subtitle by kind.
/// Hover (or keyboard focus) lights a rounded tile behind it and raises a play button into the artwork's
/// bottom-right corner. Pass `width` for a fixed size, or nil to fill the slot a shelf or grid gives it.
///
/// Every card in a row has the same geometry: the artwork gets an explicit frame from the slot width and the
/// shelf's aspect (the image fills and crops, whatever its own size or shape), and the caption below always
/// reserves two title lines and one subtitle line. So artwork bottoms and first title baselines line up even
/// when one title wraps and the next doesn't.
struct MediaCard: View {
    let item: MediaItem
    var width: CGFloat? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.cardSubtitleStyle) private var subtitleStyle
    @Environment(\.shelfCellWidth) private var slotWidth
    @Environment(\.cardArtworkAspect) private var shelfAspect
    @State private var hovering = false
    @State private var measuredWidth: CGFloat = 0
    @FocusState private var focused: Bool

    /// Height / width of the artwork: the shelf's when it sets one (so a stray video in an album shelf is
    /// cropped square like its neighbours), else 16:9 for videos and square for everything else.
    private var aspect: CGFloat { shelfAspect ?? (item.isVideo ? 9 / 16 : 1) }

    var body: some View {
        let revealed = hovering || focused
        let cardWidth = width ?? slotWidth
        let artWidth = cardWidth ?? measuredWidth
        let artSize = CGSize(width: artWidth, height: (artWidth * aspect).rounded())
        let liked = showsAsLikedSongs
        Button { if liked { model.select(.likedSongs) } else { model.open(item) } } label: {
            VStack(alignment: .leading, spacing: 8) {
                artwork(width: cardWidth)
                    .modifier(DebugFrame(key: "card-art-\(item.id)"))
                CardCaption(title: title, subtitle: subtitle, provider: liked ? nil : item.provider, isExplicit: isExplicit,
                            names: liked ? nil : item.cardSubtitleNames(style: subtitleStyle))
                    .modifier(DebugFrame(key: "card-caption-\(item.id)"))
            }
            .frame(width: cardWidth, alignment: .leading)
            .frame(maxWidth: cardWidth == nil ? .infinity : nil, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardButtonStyle(highlighted: revealed))
        .focused($focused)
        .overlay(alignment: .topLeading) {
            if item.isPlayableCollection, artSize.width > 0 {
                CardPlayButton(revealed: revealed, pending: model.isPlayPending(playKey)) { play() }
                    .padding(8)
                    .frame(width: artSize.width, height: artSize.height, alignment: .bottomTrailing)
            }
        }
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        .contextMenu {
            if liked {
                Button("Play", systemImage: "play") { play() }
                Button("Go to Liked Songs", systemImage: SidebarItem.likedSongs.symbol) { model.select(.likedSongs) }
            } else {
                CollectionMenu(item: item)
            }
        }
        .mediaDraggable(item)
        .modifier(DebugFrame(key: "card-\(item.id)"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityAction(named: "Play") { play() }
    }

    /// A service's own liked-songs playlist (YouTube's Liked Music, Spotify's Liked Songs) is Library › Liked Songs
    /// here, as in the sidebar: one name and the sidebar's heart, it opens that page, and Play plays both services'
    /// likes (`AppModel.playLikedSongs`).
    private var showsAsLikedSongs: Bool { item.isServiceLikedSongs && !model.libraryProviders.isEmpty }

    private var title: String { showsAsLikedSongs ? SidebarItem.likedSongs.title : item.title }

    private var playKey: AppModel.PlayRequestKey {
        showsAsLikedSongs ? .likedSongs : .collection(item.id, shuffled: false)
    }

    private func play() {
        if showsAsLikedSongs {
            model.playOrPause(AppModel.likedSongsContext) { model.playLikedSongs() }
        } else {
            model.play(item)
        }
    }

    /// An explicit frame when the slot width is known (shelves and grids); otherwise the artwork takes the width
    /// it is offered and its height follows from that alone, never from the height left over by the caption.
    @ViewBuilder private func artwork(width: CGFloat?) -> some View {
        let symbol = item.isVideo ? "play.rectangle" : "music.note"
        if showsAsLikedSongs, let width {
            LikedSongsArtwork(size: width)
                .frame(width: width, height: (width * aspect).rounded())
        } else if showsAsLikedSongs {
            Color.clear
                .aspectRatio(1 / aspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay { LikedSongsArtwork(size: max(measuredWidth, Metrics.cardWidths.lowerBound)) }
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth = $0 }
        } else if let width {
            ArtworkView(artwork: item.artwork, size: width, symbol: symbol)
                .frame(width: width, height: (width * aspect).rounded())
        } else {
            Color.clear
                .aspectRatio(1 / aspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay { ArtworkView(artwork: item.artwork, size: max(measuredWidth, Metrics.cardWidths.lowerBound), symbol: symbol) }
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth = $0 }
        }
    }

    private var isExplicit: Bool {
        switch item {
        case .track(let t): t.isExplicit
        case .album(let a): a.isExplicit
        default: false
        }
    }

    private var subtitle: String { showsAsLikedSongs ? "Library" : item.cardSubtitle(style: subtitleStyle) }
}

/// A card's text: the title (up to two lines) with its subtitle right under it, in an area always as tall as
/// two title lines plus a subtitle line. Every card in a row then has the same caption height and the same first
/// baseline, and a one-line title doesn't leave a gap above its subtitle.
struct CardCaption: View {
    let title: String
    let subtitle: String
    /// The service's mark before the subtitle (where marks show); nil for a list of both services' songs.
    let provider: ProviderID?
    var isExplicit = false
    /// The subtitle as a label and artist names ("Single · " and two artists), fitted as names.
    var names: (prefix: String, names: [String])? = nil

    var body: some View {
        // An invisible two-line title and subtitle fix the height (and follow the fonts); the real text sits on top.
        lines(title: "A\nA", subtitle: "A", explicit: false)
            .hidden()
            .accessibilityHidden(true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topLeading) {
                lines(title: title, subtitle: subtitle, explicit: isExplicit)
            }
    }

    private func lines(title: String, subtitle: String, explicit: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // The badge is part of the title's text, so on a wrapped title it follows the last word instead of
            // standing at the trailing edge of the first line.
            Group {
                if explicit {
                    // A no-break space: when the badge doesn't fit, the last word wraps with it.
                    Text("\(title)\u{00A0}\(ExplicitBadge.inline)")
                        .accessibilityLabel("\(title), Explicit")
                } else {
                    Text(title)
                }
            }
            .font(.cardTitle)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            HStack(spacing: 5) {
                if let provider { ServiceGlyph(provider: provider, size: 10) }
                // Whole words: a mix's "Kendrick Lamar, Dominic Fike and more", a description's "Catch all the
                // latest music from…", never a name or word cut in half.
                if let names, subtitle == names.prefix + names.names.joined(separator: ", ") {
                    FittedText(text: names.prefix, size: 13, names: names.names)
                } else {
                    FittedText(text: subtitle, size: 13)
                }
            }
            .font(.secondaryText)
            .foregroundStyle(.readableSecondary)
        }
    }
}

/// One line of text in whole words (`FittedLine.variants(of:)`): a list of names ending "and more" drops names and
/// keeps "and more", other text ends after the last whole word that fits, with "…". As `FittedNames`, the width
/// becomes the variant's index in `onGeometryChange` and the state changes only when that index does, never on
/// every frame of a resize. `size` is the system font's regular weight the text is drawn in. The whole text is the
/// tooltip when cut, and the accessibility label.
///
/// `lines: 2` keeps two lines' height and picks the longest variant that surely wraps into two: one no wider than
/// twice the room less the widest word (the first line breaks before a word no wider than that).
struct FittedText: View {
    let text: String
    let size: CGFloat
    var lines = 1
    /// Names after `text`, which is then their label ("Single · "): fitted as a list of names
    /// (`FittedLine.variants(prefix:names:)`), so the line keeps whole names and "and more".
    var names: [String] = []
    @State private var variant = 0

    nonisolated private static func variants(_ text: String, names: [String]) -> [String] {
        names.count > 1 ? FittedLine.variants(prefix: text, names: names) : FittedLine.variants(of: names.isEmpty ? text : text + names[0])
    }

    var body: some View {
        let variants = Self.variants(text, names: names)
        let full = variants.first ?? text
        // The flexible frame takes the room it's offered whatever the variant, so the line's width never depends on
        // the variant shown (no placeholder view: there is one of these on every card).
        Text(verbatim: variants[min(variant, variants.count - 1)])
            .lineLimit(lines, reservesSpace: lines > 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: Int.self) { [text, names, size, lines] geo in
                let variants = Self.variants(text, names: names)
                let room = FittedLine.room(for: variants.first ?? text, width: geo.size.width, lines: lines, size: size)
                return FittedLine.index(of: variants, fitting: room) { FittedLine.width($0, size: size) }
            } action: { variant = $0 }
            .help(variant > 0 ? full : "")
            .accessibilityLabel(full)
    }
}

extension EnvironmentValues {
    /// Height / width of every card's artwork in a shelf (9/16 for a row of videos, 1 for albums and
    /// playlists). Nil lets each card choose from its own kind.
    @Entry var cardArtworkAspect: CGFloat? = nil
}

extension MediaItem {
    /// Albums "2001 · Album" on artist pages, else "Single · Artist"; playlists "Playlist · <owner>" (the same shape
    /// as an album's, so a shelf mixing both reads evenly), else their description or song count; songs and videos
    /// say which they are; artists "Artist".
    func cardSubtitle(style: CardSubtitleStyle = .standard) -> String {
        switch self {
        case .album(let a):
            switch style {
            case .discography:
                return [a.year.map(String.init), a.kind.label].compactMap(\.self).joined(separator: " · ")
            case .standard:
                return a.artistLine.isEmpty ? [a.year.map(String.init), a.kind.label].compactMap(\.self).joined(separator: " · ") : "\(a.kind.label) · \(a.artistLine)"
            }
        case .playlist(let p):
            if let owner = p.owner, !owner.isEmpty { return "Playlist · \(owner)" }
            if let summary = p.summary, !summary.isEmpty { return summary }
            if let count = p.trackCount { return "\(count) song\(count == 1 ? "" : "s")" }
            return "Playlist"
        case .track(let t):
            return t.artistLine.isEmpty ? (t.isVideo ? "Video" : "Song") : "\(t.isVideo ? "Video" : "Song") · \(t.artistLine)"
        case .artist:
            return "Artist"
        }
    }

    /// `cardSubtitle(style:)` as its label and the artists, when it ends in two or more artists' names ("Single · " and
    /// "Olivia Rodrigo", "Olivia Dean"), so the card fits it as names ("Single · Olivia Rodrigo and more").
    func cardSubtitleNames(style: CardSubtitleStyle = .standard) -> (prefix: String, names: [String])? {
        switch self {
        case .album(let a) where style == .standard && a.artists.count > 1:
            return ("\(a.kind.label) · ", a.artists.map(\.name))
        case .track(let t) where t.artists.count > 1:
            return ("\(t.isVideo ? "Video" : "Song") · ", t.artists.map(\.name))
        default:
            return nil
        }
    }

    /// A service's own liked-songs playlist, which OpenMusic shows as Library › Liked Songs.
    var isServiceLikedSongs: Bool { if case .playlist(let p) = self { p.isLikedSongs } else { false } }

    /// Mood and genre entries open a list of playlists; they have nothing to play directly.
    var isPlayableCollection: Bool {
        if case .playlist(let p) = self { return !p.isCategory }
        return true
    }
}

/// The card surface: a rounded tile lights up behind artwork and text while hovered or focused,
/// and the card presses down to 0.96.
struct CardButtonStyle: ButtonStyle {
    var highlighted: Bool
    var circle = false

    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration, highlighted: highlighted)
    }

    private struct CardBody: View {
        let configuration: ButtonStyleConfiguration
        let highlighted: Bool
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: Metrics.artworkRadius + Metrics.cardTilePadding, style: .continuous)
                        .fill(Color.primary.opacity(highlighted ? (scheme == .dark ? 0.07 : 0.05) : 0))
                        .padding(-Metrics.cardTilePadding)
                }
                .motionScale(configuration.isPressed ? Motion.pressScale : 1)
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

/// The play button that rises into a card's artwork corner on hover or focus.
struct CardPlayButton: View {
    let revealed: Bool
    var size: CGFloat = 40
    /// Its play request is loading: a spinner in the disc, shown without hover until playback starts.
    var pending = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = revealed || pending
        PlayCircleButton(size: size, isLoading: pending, action: action)
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : Motion.revealRise)
            .animation(Motion.reveal, value: shown)
            .allowsHitTesting(shown)
            .accessibilityHidden(true)
    }
}

/// The round play button. On artwork it is a light disc with a dark glyph, readable on any cover;
/// elsewhere it is ink on paper like the Play pill. `isPause` shows Pause instead (hero buttons).
struct PlayCircleButton: View {
    var size: CGFloat = 30
    var onArtwork = true
    var isPause = false
    /// The play request is loading: AppKit's small spinner in place of the glyph (dark spokes on the light disc).
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .environment(\.colorScheme, onArtwork ? .light : .dark)
                } else {
                    Image(systemName: isPause ? "pause.fill" : "play.fill")
                        .font(.system(size: size * 0.38, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(onArtwork ? AnyShapeStyle(Color.black.opacity(0.85)) : AnyShapeStyle(Color.pageBackground))
                        // The play triangle's visual center sits left of its box.
                        .offset(x: isPause ? 0 : size * 0.03)
                }
            }
                .frame(width: size, height: size)
                .background(onArtwork ? AnyShapeStyle(Color.white.opacity(0.95)) : AnyShapeStyle(Color.primary), in: Circle())
                .shadow(color: .black.opacity(onArtwork ? 0.3 : 0), radius: 6, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(PlayCircleStyle())
        .accessibilityLabel(isLoading ? "Loading" : isPause ? "Pause" : "Play")
    }

    private struct PlayCircleStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            PlayCircleBody(configuration: configuration)
        }
    }

    private struct PlayCircleBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .opacity(isEnabled ? 1 : 0.4)
                .motionScale(configuration.isPressed ? Motion.pressScale : hovering && isEnabled ? 1.04 : 1)
                .animation(Motion.press, value: configuration.isPressed)
                .animation(Motion.hover, value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// Round artist portrait with the name and "Artist" underneath. Hover lights the same tile as other cards.
struct ArtistCard: View {
    let artist: Artist
    var width: CGFloat? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.shelfCellWidth) private var slotWidth
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        let width = width ?? slotWidth
        Button { model.open(.artist(artist)) } label: {
            VStack(alignment: .leading, spacing: 8) {
                // A fixed square from the slot width, like `MediaCard`, so the caption can't shrink the portrait.
                if let width {
                    ArtworkView(artwork: artist.artwork, size: width, circle: true, symbol: "music.mic")
                        .frame(width: width, height: width)
                } else {
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .overlay { ArtworkView(artwork: artist.artwork, size: Metrics.cardWidths.upperBound, circle: true, symbol: "music.mic") }
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        ServiceGlyph(provider: artist.provider, size: 10)
                            .foregroundStyle(.secondary)
                        Text(artist.name).font(.cardTitle).lineLimit(1)
                    }
                    Text("Artist").font(.secondaryText).foregroundStyle(.readableSecondary)
                }
            }
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardButtonStyle(highlighted: hovering || focused))
        .focused($focused)
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        .contextMenu { CollectionMenu(item: .artist(artist)) }
        .mediaDraggable(.artist(artist))
        .accessibilityLabel("\(artist.name), Artist")
    }
}

/// The tall "Top Picks" style card: artwork on top, a band of blurred artwork color with text below.
struct HeroCard: View {
    let item: MediaItem
    var caption: String?
    static let widths: ClosedRange<CGFloat> = 236...300

    @Environment(\.shelfCellWidth) private var slotWidth
    private var width: CGFloat { slotWidth ?? 244 }

    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let caption {
                Text(caption)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.readableSecondary)
                    .lineLimit(1)
            }
            Button { model.open(item) } label: {
                VStack(spacing: 0) {
                    ArtworkView(artwork: item.artwork, size: width, cornerRadius: 0)
                        .frame(width: width, height: width)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.headline)
                            .lineLimit(1)
                        // A list of artists on one line in whole names, "and more" kept with them ("Kendrick
                        // Lamar, Dominic Fike and more"; round 28 left "and more" alone on a second line); a
                        // description on two lines, cut after a whole word with "…" (`FittedText`). Every caption
                        // keeps two lines' height, so the cards in a row end level.
                        ZStack(alignment: .topLeading) {
                            Text(verbatim: "A\nA").lineLimit(2).hidden().accessibilityHidden(true)
                            switch Self.detailLayout(item: item, detail: detail) {
                            case .names(let names): FittedText(text: "", size: 12, names: names)
                            case .nameList: FittedText(text: detail, size: 12)
                            case .description: FittedText(text: detail, size: 12, lines: 2)
                            }
                        }
                        .font(.callout)
                        .opacity(TextContrastProbe.hides ? 0 : Self.detailOpacity)
                        .modifier(LayoutProbe(key: "hero-card-detail|\(item.title)"))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(width: width, alignment: .leading)
                    .background {
                        // A fixed dark layer over the blurred art, the same on every card: on pale art (Daily Mix
                        // 2's grey) the 28% layer left a light strip and the 80% white line read weakly. Half black
                        // keeps the 90% white line at 4.5:1 over art up to about 86% gray; paler art (a white
                        // cover) gets just enough more (`CaptionShade`).
                        ArtworkBackdrop(artwork: item.artwork, blur: 30, caption: (minimum: Self.stripShade, opacity: Self.detailOpacity))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .overlay(alignment: .topLeading) {
                CardPlayButton(revealed: hovering, size: 40) { model.play(item) }
                    .padding(10)
                    .frame(width: width, height: width, alignment: .bottomTrailing)
            }
            .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        }
        .frame(width: width)
        .contextMenu { CollectionMenu(item: item) }
    }

    /// The black over the caption strip's blurred art (at least), and the white detail line's opacity.
    static let stripShade: Double = 0.5
    static let detailOpacity: Double = 0.9

    enum DetailLayout: Equatable {
        /// An album's or song's artists, fitted as names on one line.
        case names([String])
        /// A list of names already ending "and more" (a mix's summary), fitted on one line keeping "and more".
        case nameList
        /// Prose: two lines, cut after a whole word.
        case description
    }

    static func detailLayout(item: MediaItem, detail: String) -> DetailLayout {
        switch item {
        case .album(let a) where a.artists.count > 1: return .names(a.artists.map(\.name))
        case .track(let t) where t.artists.count > 1: return .names(t.artists.map(\.name))
        case .album, .track, .artist: return .nameList
        case .playlist:
            return detail.trimmingCharacters(in: .whitespaces).hasSuffix(" and more") ? .nameList : .description
        }
    }

    private var detail: String {
        switch item {
        case .playlist(let p): p.summary ?? p.owner ?? "Playlist"
        case .album(let a): a.artistLine
        case .artist(let a): a.subtitle ?? "Artist"
        case .track(let t): t.artistLine
        }
    }
}

