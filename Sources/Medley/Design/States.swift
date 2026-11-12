import MedleyCore
import SwiftUI

// MARK: - Skeletons

/// A gently pulsing placeholder block. Pulses only while visible, and stays still with Reduce Motion.
struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var radius: CGFloat = 5
    var circle = false

    var body: some View {
        Group {
            if circle {
                Circle().fill(.quaternary)
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.quaternary)
            }
        }
        .frame(width: width, height: height)
        .modifier(Pulse())
        .accessibilityHidden(true)
    }
}

private struct Pulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.medleySnapshot) private var snapshot
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.55 : 1)
            .onAppear {
                guard !reduceMotion, !snapshot else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// Skeleton for a page of shelves (Home, New, See All). Each section has its final shape and size: cards at the
/// fitted width and column count the real shelf will use (square for releases and playlists, 16:9 for videos),
/// two rows of mood tiles, song rows, or Home's featured card. So nothing rearranges when the data arrives.
struct ShelvesSkeleton: View {
    enum Section: Hashable {
        /// Album and playlist cards: square artwork and a two-line caption.
        case cards
        /// Music videos: 16:9 artwork at the video card width.
        case videos
        /// Moods & genres: two rows of colored tiles.
        case tiles
        /// A song grid (Quick picks).
        case songs
        /// Home's featured card.
        case featured
    }

    var sections: [Section] = [.cards, .cards, .cards]
    @Environment(\.isCompactHeight) private var compact
    @State private var available: CGFloat = 0

    init(sections: [Section] = [.cards, .cards, .cards]) {
        self.sections = sections
    }

    /// The old count-only form (artist pages): that many card shelves.
    init(shelves: Int) {
        self.sections = Array(repeating: .cards, count: shelves)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 28 : Metrics.sectionSpacing) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                switch section {
                case .featured:
                    // The row of slim cards Home leads with (`FeaturedRow`).
                    let pad = FeaturedCard.padding(compact: compact, slim: true)
                    let art = FeaturedCard.artworkSize(compact: compact, slim: true)
                    let count = max(1, min(FeaturedRow.maxCards, Int((available + FeaturedRow.spacing) / (FeaturedRow.minCardWidth + FeaturedRow.spacing))))
                    HStack(spacing: FeaturedRow.spacing) {
                        ForEach(0..<count, id: \.self) { _ in
                            HStack(alignment: .center, spacing: 16) {
                                SkeletonBlock(width: art, height: art, radius: FeaturedCard.artworkRadius)
                                VStack(alignment: .leading, spacing: 8) {
                                    SkeletonBlock(width: 90, height: 10)
                                    SkeletonBlock(width: 150, height: 20, radius: 6)
                                    SkeletonBlock(width: 110, height: 11)
                                    SkeletonBlock(width: 40, height: 40, circle: true).padding(.top, 4)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(pad)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: FeaturedCard.artworkRadius + pad, style: .continuous))
                        }
                    }
                default:
                    VStack(alignment: .leading, spacing: 12) {
                        // As tall as a `SectionHeader` title line.
                        SkeletonBlock(width: 180, height: 20).frame(height: 26)
                        row(section)
                    }
                }
            }
        }
        .padding(.horizontal, Metrics.pageInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width - Metrics.pageInset * 2 } action: { available = $0 }
    }

    @ViewBuilder private func row(_ section: Section) -> some View {
        switch section {
        case .tiles:
            // `CategoryTileRows`: two rows of tiles, 190–250 pt wide, 14 pt apart.
            let layout = Metrics.cardLayout(available: available, widths: 190...250, spacing: 14)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(0..<2, id: \.self) { _ in
                    HStack(spacing: layout.spacing) {
                        ForEach(0..<layout.columns, id: \.self) { _ in
                            SkeletonBlock(width: layout.width, height: CategoryTile.height, radius: 12)
                        }
                    }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
        case .songs:
            // `TrackGridShelf` columns of compact song rows.
            let layout = Metrics.cardLayout(available: available, widths: 320...420, spacing: 24)
            HStack(alignment: .top, spacing: layout.spacing) {
                ForEach(0..<layout.columns, id: \.self) { column in
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(0..<(compact ? 2 : 4), id: \.self) { row in
                            HStack(spacing: 12) {
                                SkeletonBlock(width: compact ? 44 : 52, height: compact ? 44 : 52, radius: 5)
                                VStack(alignment: .leading, spacing: 6) {
                                    SkeletonBlock(width: CGFloat(110 + ((column * 4 + row) * 37) % 90), height: 12)
                                    SkeletonBlock(width: CGFloat(70 + ((column * 4 + row) * 23) % 60), height: 10)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                    .frame(width: layout.width, alignment: .leading)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
        default:
            let videos = section == .videos
            let widths = videos ? Metrics.videoCardWidths : compact ? Metrics.compactCardWidths : Metrics.cardWidths
            let layout = Metrics.cardLayout(available: available, widths: widths)
            HStack(alignment: .top, spacing: layout.spacing) {
                ForEach(0..<layout.columns, id: \.self) { _ in
                    CardSkeleton(width: layout.width, aspect: videos ? 9 / 16 : 1)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
    }
}

/// A card's artwork, then a caption area as tall as `CardCaption` (two title lines and a subtitle).
struct CardSkeleton: View {
    var width: CGFloat
    var circle = false
    /// Height / width of the artwork.
    var aspect: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SkeletonBlock(width: width, height: (width * aspect).rounded(), radius: Metrics.artworkRadius, circle: circle)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBlock(width: width * 0.7, height: 12)
                SkeletonBlock(width: width * 0.45, height: 11)
            }
            .padding(.top, 2)
            // Same height as the real caption: two 14 pt title lines and one 13 pt subtitle.
            .frame(height: 54, alignment: .top)
        }
        .frame(width: width, alignment: .leading)
    }
}

/// Track rows at the real row height and column positions.
struct TrackListSkeleton: View {
    var rows = 8
    var style: TrackListStyle = .album
    var showsHeader = true
    @Environment(\.isCompactHeight) private var compact

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                HStack {
                    SkeletonBlock(width: 10, height: 9).frame(width: 28, alignment: .trailing)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 0.5) }
                .padding(.bottom, 6)
            }
            ForEach(0..<rows, id: \.self) { i in
                HStack(spacing: 12) {
                    SkeletonBlock(width: 14, height: 11).frame(width: 28, alignment: .trailing)
                    if style == .playlist { SkeletonBlock(width: 40, height: 40, radius: 4) }
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonBlock(width: CGFloat(140 + (i * 47) % 120), height: 12)
                        if style == .playlist { SkeletonBlock(width: CGFloat(80 + (i * 31) % 60), height: 10) }
                    }
                    Spacer()
                    SkeletonBlock(width: 34, height: 11)
                }
                .padding(.horizontal, 10)
                .frame(height: TrackRow.height(style, compact: compact))
            }
        }
        .frame(maxWidth: Metrics.trackListMaxWidth(style), alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A grid of card skeletons at the fitted card width.
struct GridSkeleton: View {
    var circle = false
    @State private var available: CGFloat = 0
    @Environment(\.isCompactHeight) private var compact

    var body: some View {
        let layout = Metrics.cardLayout(available: available, widths: compact ? Metrics.compactCardWidths : Metrics.cardWidths)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(layout.width), spacing: layout.spacing, alignment: .top), count: layout.columns), alignment: .leading, spacing: 28) {
            ForEach(0..<12, id: \.self) { _ in
                CardSkeleton(width: layout.width, circle: circle)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
        .padding(Metrics.pageInset)
    }
}

// MARK: - Empty and error states

struct EmptyStateView<Actions: View>: View {
    let symbol: String
    let title: String
    var message: String? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.body)
                    .foregroundStyle(.readableSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            actions
                .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(symbol: String, title: String, message: String? = nil) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

struct ErrorStateView: View {
    let error: any Error
    let retry: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        if let providerError = error as? ProviderError, providerError == .notSignedIn {
            EmptyStateView(symbol: "person.crop.circle", title: "Sign in to see this", message: "Connect an account in Settings to load your music.") {
                // Settings › Accounts, where both services' sign-ins are (not the welcome sheet).
                Button("Open Accounts…") { model.perform(.openAccounts) }
                    .controlSize(.large)
                    .modifier(LayoutProbe(key: "open-accounts"))
            }
        } else {
            EmptyStateView(symbol: "wifi.exclamationmark", title: "Couldn't load this page", message: error.localizedDescription) {
                Button("Try Again", action: retry)
                    .controlSize(.large)
            }
        }
    }
}

// MARK: - Loading

/// A value per provider: either loaded or the reason it failed.
struct ProviderResult<Value: Sendable>: Sendable {
    let provider: ProviderID
    let value: Value?
    let error: String?
}

/// Shows cached data instantly and refreshes in the background.
/// Falls back to `placeholder` (a skeleton) only when nothing is cached yet.
/// A copy of a page's value kept on disk: read when memory has nothing for the key (the first visit after launch),
/// written after every successful load.
struct LoadableDisk<Value: Sendable> {
    let load: () async -> (value: Value, date: Date)?
    let save: (Value) -> Void
}

struct Loadable<Value: Sendable, Content: View, Placeholder: View>: View {
    let key: String
    var maxAge: TimeInterval = 120
    var disk: LoadableDisk<Value>? = nil
    /// Shown above the error page when the first load fails (a playlist's unfinished edit, `PartialEditBannerSlot`).
    var failureHeader: AnyView? = nil
    let load: () async throws -> Value
    @ViewBuilder var content: (Value) -> Content
    @ViewBuilder var placeholder: () -> Placeholder

    @Environment(AppModel.self) private var model
    @State private var state: (key: String, value: Value)?
    @State private var failure: (key: String, error: any Error)?

    var body: some View {
        Group {
            if let value = currentValue {
                content(value)
            } else if let failure, failure.key == key {
                VStack(spacing: 0) {
                    if let failureHeader { failureHeader }
                    ErrorStateView(error: failure.error) { Task { await refresh(force: true) } }
                }
            } else {
                placeholder()
            }
        }
        .pageBackground()
        // A page whose service copy changed (`AppModel.pageVersions`) loads again, keeping what it shows meanwhile.
        .task(id: "\(key)#\(model.refreshTick)#\(model.pageVersions[key] ?? 0)") { await refresh(force: false) }
    }

    private var currentValue: Value? {
        if let state, state.key == key { return state.value }
        return model.cache.value(for: key)?.value
    }

    private func refresh(force: Bool) async {
        let key = key
        if !force, let cached: (value: Value, date: Date) = model.cache.value(for: key) {
            state = (key, cached.value)
            if Date().timeIntervalSince(cached.date) < maxAge { return }
        } else if !force, let disk, let saved = await disk.load() {
            // Shown at once, then replaced by the fresh load below (or kept if that fails).
            guard !Task.isCancelled else { return }
            // With the saved date, so a page that comes back before the fresh load lands still refetches.
            model.cache.set(saved.value, for: key, date: saved.date)
            if state?.key != key { state = (key, saved.value) }
        }
        if force { failure = nil }
        do {
            let value = try await load()
            guard !Task.isCancelled else { return }
            model.cache.set(value, for: key)
            state = (key, value)
            failure = nil
            disk?.save(value)
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            if state?.key != key { failure = (key, error) }
        }
    }
}

/// In-memory cache of loaded pages, keyed by route. Lets back/forward navigation render instantly.
@MainActor
final class PageCache {
    private var store: [String: (value: Any, date: Date)] = [:]

    func value<T>(for key: String) -> (value: T, date: Date)? {
        guard let entry = store[key], let value = entry.value as? T else { return nil }
        return (value, entry.date)
    }

    func set(_ value: Any, for key: String, date: Date = Date()) { store[key] = (value, date) }
    func invalidate(prefix: String) { store = store.filter { !$0.key.hasPrefix(prefix) } }
    func remove(_ key: String) { store[key] = nil }
    func hasEntry(prefix: String) -> Bool { store.keys.contains { $0.hasPrefix(prefix) } }
    func removeAll() { store.removeAll() }
}

// MARK: - Environment

extension EnvironmentValues {
    /// True while the app is rendering snapshots: animations that never settle are turned off.
    @Entry var medleySnapshot = false
}
