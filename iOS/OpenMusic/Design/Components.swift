import OpenMusicCore
import SwiftUI
import UIKit

// Direction: Apple Music for iPhone on iOS 26. System type with Dynamic Type, system materials and Liquid Glass
// controls, artwork carries the color. One accent (AccentColor, a warm red-pink) for links, the playing
// indicator and the primary Play button. No custom fonts, card shadows or gradient decoration.

extension EnvironmentValues {
    /// True on a short iPhone (SE class, under 740 points tall): headers shrink so music shows on the first screen.
    /// Set once by `RootView` from the window's height.
    @Entry var isShortScreen = false
}

extension ShapeStyle where Self == Color {
    /// Secondary text (artists, metadata, captions, footers): 4.5:1 or better on the system backgrounds, the grouped
    /// gray included: #636366 in light (about 5.4:1 on #F2F2F7, 6:1 on white), Apple's increased-contrast #AEAEB2 in
    /// dark. The plain `.secondary` label measured about 3.3:1 to 3.4:1.
    static var secondaryText: Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0xAE / 255, green: 0xAE / 255, blue: 0xB2 / 255, alpha: 1)
                : UIColor(red: 0x63 / 255, green: 0x63 / 255, blue: 0x66 / 255, alpha: 1)
        })
    }
}

enum Metrics {
    static let gutter: CGFloat = 20
    static let card: CGFloat = 160
    static let artistCircle: CGFloat = 120
    static let artworkRadius: CGFloat = 8
}

// MARK: Loading

enum LoadPhase<Value> {
    case loading
    case loaded(Value)
    case failed(String)
}

/// Loads a value through the page cache and shows it, with loading, error and retry states.
/// Cached values appear at once. Pull to refresh reloads (the child's scroll view picks up `.refreshable`).
struct Loader<Value: Sendable, Content: View>: View {
    let key: String
    let load: () async throws -> Value
    @ViewBuilder let content: (Value) -> Content
    @Environment(AppModel.self) private var model
    @State private var phase: LoadPhase<Value> = .loading
    /// The key `phase` belongs to. The same Loader is reused when its key changes (a new search), and a result for
    /// an older key must never show under the new one.
    @State private var phaseKey: String?
    /// Bumped by every load; only the newest one may publish.
    @State private var generation = 0

    init(key: String, load: @escaping () async throws -> Value, @ViewBuilder content: @escaping (Value) -> Content) {
        self.key = key
        self.load = load
        self.content = content
    }

    var body: some View {
        Group {
            switch resolvedPhase {
            case .loading:
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await run(force: true) } }
                        .buttonStyle(.glass)
                }
            case .loaded(let value):
                content(value)
            }
        }
        .refreshable { await run(force: true) }
        .task(id: "\(key)#\(model.refreshTick)") { await run(force: false) }
    }

    /// A cache hit renders on the first frame, before `.task` runs. A phase for another key reads as loading.
    private var resolvedPhase: LoadPhase<Value> {
        let current: LoadPhase<Value> = phaseKey == key ? phase : .loading
        if case .loading = current, let hit: Value = model.cachedValue(key) { return .loaded(hit) }
        return current
    }

    private func run(force: Bool) async {
        let requestKey = key
        generation += 1
        let mine = generation
        if !force, let hit: Value = model.cachedValue(requestKey) {
            publish(.loaded(hit), key: requestKey)
            return
        }
        do {
            let value = try await model.cached(requestKey, force: force, load)
            // A newer load started (the key changed or the user refreshed): this answer is stale.
            guard mine == generation, !Task.isCancelled else { return }
            publish(.loaded(value), key: requestKey)
        } catch is CancellationError {
        } catch {
            guard mine == generation, !Task.isCancelled else { return }
            if case .loaded = phase, force, phaseKey == requestKey { model.report(error); return }
            publish(.failed(error.localizedDescription), key: requestKey)
        }
    }

    private func publish(_ new: LoadPhase<Value>, key: String) {
        phase = new
        phaseKey = key
    }
}

// MARK: Headers

struct SectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if let subtitle {
                    Text(subtitle.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondaryText)
                }
                Text(title).font(.title2.bold()).lineLimit(2)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, Metrics.gutter)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Header that pushes a route with a chevron, like Apple Music's "Recently Played ›".
struct LinkedSectionHeader: View {
    let title: String
    var subtitle: String?
    let route: Route

    var body: some View {
        NavigationLink(value: route) {
            // Last baseline: the chevron sits on the title, not on the caption above it.
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    if let subtitle {
                        Text(subtitle.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondaryText)
                    }
                    Text(title).font(.title2.bold()).foregroundStyle(.primary).lineLimit(2)
                }
                Image(systemName: "chevron.forward").font(.title3.weight(.semibold)).foregroundStyle(.secondaryText)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Metrics.gutter)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: Cards

/// Album, playlist or song card: square artwork with title and subtitle underneath.
struct MediaCard: View {
    let item: MediaItem
    var width: CGFloat = Metrics.card

    var body: some View {
        Group {
            if case .track = item {
                CardButton(item: item) { label }
            } else {
                NavigationLink(value: route) { label }.buttonStyle(.plain)
            }
        }
        .contextMenu { ItemMenu(item: item) }
    }

    private var route: Route {
        switch item {
        case .album(let a): .album(a)
        case .artist(let a): .artist(a)
        case .playlist(let p): .playlist(p)
        case .track: .library(.songs)
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(artwork: item.artwork, points: width, placeholder: placeholder)
                .frame(width: width, height: width)
                .clipShape(.rect(cornerRadius: Metrics.artworkRadius))
                .overlay { RoundedRectangle(cornerRadius: Metrics.artworkRadius).strokeBorder(.separator.opacity(0.4), lineWidth: 0.5) }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondaryText).lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var placeholder: String {
        switch item {
        case .playlist: "music.note.list"
        case .artist: "music.mic"
        default: "music.note"
        }
    }
}

/// Plays a song card on tap.
private struct CardButton<Label: View>: View {
    let item: MediaItem
    @ViewBuilder let label: Label
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.open(item: item) } label: { label }
            .buttonStyle(.plain)
    }
}

struct ArtistCircle: View {
    let artist: Artist
    var size: CGFloat = Metrics.artistCircle

    var body: some View {
        NavigationLink(value: Route.artist(artist)) {
            VStack(spacing: 8) {
                ArtworkView(artwork: artist.artwork, points: size, placeholder: "music.mic")
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                Text(artist.name)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: size)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu { ItemMenu(item: .artist(artist)) }
    }
}

/// A horizontally scrolling row with the page gutter and view-aligned snapping.
struct Carousel<Content: View>: View {
    var spacing: CGFloat = 14
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: spacing) { content }
                .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, Metrics.gutter, for: .scrollContent)
    }
}

// MARK: Track rows

struct TrackRow: View {
    let track: Track
    /// Track number for album lists; nil shows artwork.
    var number: Int?
    var showsArtist = true
    let play: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let isCurrent = model.player.current?.id == track.id
        Button(action: play) {
            HStack(spacing: 12) {
                if let number {
                    ZStack {
                        if isCurrent {
                            PlayingIndicator(isPlaying: model.player.isPlaying)
                        } else {
                            Text("\(number)").font(.body.monospacedDigit()).foregroundStyle(.secondaryText)
                        }
                    }
                    .frame(minWidth: 24, alignment: .center)
                } else {
                    ArtworkView(artwork: track.artwork, points: 48)
                        .frame(width: 48, height: 48)
                        .clipShape(.rect(cornerRadius: 6))
                        .overlay {
                            if isCurrent {
                                RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.35))
                                PlayingIndicator(isPlaying: model.player.isPlaying).foregroundStyle(.white)
                            }
                        }
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(track.title)
                            .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                            .lineLimit(1)
                        if track.isExplicit { ExplicitBadge() }
                    }
                    if showsArtist, !track.artistLine.isEmpty {
                        Text(track.artistLine).font(.subheadline).foregroundStyle(.secondaryText).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if model.isLiked(track) {
                    Image(systemName: "heart.fill").font(.caption).foregroundStyle(.tint).accessibilityLabel("Liked")
                }
                Menu {
                    TrackMenu(track: track)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondaryText)
                        .frame(width: 32, height: 44)
                        .contentShape(.rect)
                }
                .accessibilityLabel("More")
            }
            .opacity(track.isPlayable ? 1 : 0.45)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu { TrackMenu(track: track) }
        .disabled(!track.isPlayable)
    }
}

struct ExplicitBadge: View {
    var body: some View {
        Image(systemName: "e.square.fill")
            .font(.caption)
            .foregroundStyle(.secondaryText)
            .accessibilityLabel("Explicit")
    }
}

/// Animated bars for the playing row; still while paused, so a paused app draws nothing.
struct PlayingIndicator: View {
    let isPlaying: Bool

    var body: some View {
        Image(systemName: "waveform")
            .font(.body.weight(.semibold))
            .foregroundStyle(.tint)
            .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating, isActive: isPlaying)
            .accessibilityLabel(isPlaying ? "Playing" : "Paused")
    }
}

// MARK: Menus

struct TrackMenu: View {
    let track: Track
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { model.playNext(.track(track)) }
        Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { model.addToQueue(.track(track)) }
        if model.canLike(track) {
            let liked = model.isLiked(track)
            Button(liked ? "Unlike" : "Like", systemImage: liked ? "heart.slash" : "heart") { model.toggleLike(track) }
        }
        Divider()
        if model.can(.radio, track.provider) {
            Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") { model.startRadio(track) }
        }
        Button("Go to Album", systemImage: "square.stack") { model.goToAlbum(track) }
        Button("Go to Artist", systemImage: "music.mic") { model.goToArtist(track) }
    }
}

struct ItemMenu: View {
    let item: MediaItem
    @Environment(AppModel.self) private var model

    var body: some View {
        if case .track(let track) = item {
            TrackMenu(track: track)
        } else {
            Button("Play", systemImage: "play") { model.play(item) }
            if case .artist = item {} else {
                Button("Shuffle", systemImage: "shuffle") { model.play(item, shuffled: true) }
            }
            Divider()
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { model.playNext(item) }
            Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { model.addToQueue(item) }
            if let provider = model.provider(item.provider), provider.isSignedIn, provider.capabilities.contains(.library) {
                Divider()
                Button(saveTitle, systemImage: "plus") { model.setSaved(item, saved: true) }
            }
        }
    }

    private var saveTitle: String {
        if case .artist = item { return "Follow" }
        return "Add to Library"
    }
}

// MARK: Buttons

/// Apple Music's pair of wide Play / Shuffle buttons under a collection header.
struct PlayShuffleButtons: View {
    let play: () -> Void
    let shuffle: () -> Void
    var isCurrentPlaying = false
    @Environment(\.isShortScreen) private var isShortScreen

    var body: some View {
        HStack(spacing: 14) {
            Button(action: play) {
                Label(isCurrentPlaying ? "Pause" : "Play", systemImage: isCurrentPlaying ? "pause.fill" : "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: isShortScreen ? 22 : 30)
            }
            Button(action: shuffle) {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: isShortScreen ? 22 : 30)
            }
        }
        .buttonStyle(.glass)
        .tint(.accentColor)
        .foregroundStyle(.tint)
        .controlSize(.large)
        .padding(.horizontal, Metrics.gutter)
        .sensoryFeedback(.impact(weight: .light), trigger: isCurrentPlaying)
    }
}

/// Opens Settings: the account button in Home, New and Library toolbars.
struct AccountButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.isSettingsPresented = true
        } label: {
            Label("Account and Settings", systemImage: "person.crop.circle")
        }
    }
}

extension View {
    /// Standard destinations for every tab's stack.
    func openMusicDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .album(let a): AlbumPage(album: a)
            case .artist(let a): ArtistPage(artist: a)
            case .playlist(let p): PlaylistPage(playlist: p)
            case .shelf(let s, let provider): ShelfPage(shelf: s, provider: provider)
            case .library(let kind): LibraryListPage(kind: kind)
            }
        }
    }
}

// MARK: Collapsing title

/// A page whose header already shows its name (album, playlist, artist): the navigation bar stays empty at the top
/// and shows the title, centered, once the header has scrolled away, like Apple Music. Apply to the page's
/// `ScrollView`. `clearsEdge` hides the top scroll-edge blur until then, for a photo that runs under the bar.
struct CollapsingTitle: ViewModifier {
    let title: String
    /// Scroll distance (points from the top of the content) after which the title shows.
    let threshold: CGFloat
    var clearsEdge = false
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top > threshold
            } action: { _, new in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { shown = new }
            }
            .scrollEdgeEffectHidden(clearsEdge && !shown, for: .top)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .opacity(shown ? 1 : 0)
                        .accessibilityHidden(!shown)
                }
            }
    }
}

extension View {
    func collapsingTitle(_ title: String, after threshold: CGFloat, clearsEdge: Bool = false) -> some View {
        modifier(CollapsingTitle(title: title, threshold: threshold, clearsEdge: clearsEdge))
    }
}
