import MedleyCore
import SwiftUI

extension LibraryKind {
    var title: String {
        switch self {
        case .likedSongs: "Liked Songs"
        case .songs: "Songs"
        case .albums: "Albums"
        case .artists: "Artists"
        case .playlists: "Playlists"
        case .recentlyPlayed: "Recently Played"
        }
    }

    var symbol: String {
        switch self {
        case .likedSongs: "heart"
        case .songs: "music.note"
        case .albums: "square.stack"
        case .artists: "music.mic"
        case .playlists: "music.note.list"
        case .recentlyPlayed: "clock"
        }
    }
}

struct LibraryTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack(path: model.path(.library)) {
            Group {
                if model.libraryProviders.isEmpty {
                    SignedOutLibrary()
                } else {
                    LibraryHome()
                }
            }
            .navigationTitle("Library")
            // The large title and the account button share one row, as in Music.
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { AccountButton() } }
            .medleyDestinations()
        }
    }
}

private struct SignedOutLibrary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                ContentUnavailableView {
                    Label("Your Library", systemImage: "music.note.house")
                } description: {
                    Text("Sign in to YouTube Music to see your liked songs, playlists, albums and artists here.")
                } actions: {
                    Button("Sign In to YouTube Music") { model.signInProvider = .youtubeMusic }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                }
                .padding(.top, 40)
                RecentlyPlayedShelf()
            }
        }
    }
}

private struct LibraryHome: View {
    @Environment(AppModel.self) private var model
    @State private var recentFromServices: [MediaItem] = []

    var body: some View {
        List {
            Section {
                ForEach([LibraryKind.likedSongs, .playlists, .albums, .artists, .songs], id: \.self) { kind in
                    NavigationLink(value: Route.library(kind)) {
                        Label {
                            Text(kind.title).font(.title3)
                        } icon: {
                            Image(systemName: kind.symbol).foregroundStyle(.tint)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            Section {
                RecentlyPlayedShelf(fromServices: recentFromServices)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .task(id: model.refreshTick) { recentFromServices = await RecentlyPlayedShelf.load(model) }
    }
}

/// Albums, playlists and songs played lately: this device's own history first, then what the signed-in services
/// remember (YouTube Music's history, Spotify's recently played), so a new install isn't empty. Works signed out.
private struct RecentlyPlayedShelf: View {
    /// What the services remember (`RecentlyPlayedShelf.load`), after this device's own history.
    var fromServices: [MediaItem] = []
    @Environment(AppModel.self) private var model

    var body: some View {
        let recent = recentItems
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Recently Played")
                Carousel { ForEach(recent) { MediaCard(item: $0, width: 150) } }
            }
            .padding(.top, 24)
            .padding(.bottom, 12)
        }
    }

    /// The signed-in services' recently played, first page each, through the page cache.
    static func load(_ model: AppModel) async -> [MediaItem] {
        let providers = model.libraryProviders
        guard !providers.isEmpty else { return [] }
        // When every service failed (offline), nothing is cached, so the next visit asks again.
        let items = try? await model.cached("library:recent") {
            var items: [MediaItem] = []
            var failure: (any Error)?
            var answered = false
            for provider in providers {
                do {
                    items += try await provider.library(.recentlyPlayed, continuation: nil).items
                    answered = true
                } catch {
                    failure = failure ?? error
                }
            }
            if !answered, let failure { throw failure }
            return items
        }
        return items ?? []
    }

    private var recentItems: [MediaItem] {
        var seen = Set<String>()
        var out: [MediaItem] = []
        func add(_ item: MediaItem) {
            if out.count < 12, seen.insert(item.id).inserted { out.append(item) }
        }
        for played in model.player.listeningHistory {
            if let context = played.context, let id = context.id, let provider = context.provider, context.kind == .album {
                add(.album(Album(providerID: id, provider: provider, title: context.title, artists: played.track.artists, artwork: played.track.artwork)))
            } else if let context = played.context, let id = context.id, let provider = context.provider, context.kind == .playlist {
                add(.playlist(Playlist(providerID: id, provider: provider, title: context.title, artwork: played.track.artwork)))
            } else {
                add(.track(played.track))
            }
        }
        for item in fromServices {
            // A song the service remembers shows as its album when it names one, as Apple Music does.
            if case .track(let track) = item, let ref = track.album, let id = ref.id {
                add(.album(Album(providerID: id, provider: track.provider, title: ref.title, artists: track.artists, artwork: track.artwork)))
            } else {
                add(item)
            }
        }
        return out
    }
}

/// One library list, merged across signed-in services, loading more pages as it scrolls.
struct LibraryListPage: View {
    let kind: LibraryKind
    @Environment(AppModel.self) private var model
    @State private var items: [MediaItem] = []
    @State private var continuations: [ProviderID: String] = [:]
    @State private var phase: LoadPhase<Void> = .loading
    @State private var loadingMore = false

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load", systemImage: "wifi.exclamationmark")
                } description: { Text(message) } actions: {
                    Button("Try Again") { Task { await reload() } }.buttonStyle(.glass)
                }
            case .loaded:
                if items.isEmpty {
                    ContentUnavailableView("No \(kind.title)", systemImage: kind.symbol, description: Text(emptyMessage))
                } else {
                    list
                }
            }
        }
        .navigationTitle(kind.title)
        .refreshable { await reload() }
        .task(id: model.refreshTick) { await reload() }
    }

    private var tracks: [Track] { items.compactMap { if case .track(let t) = $0 { t } else { nil } } }

    @ViewBuilder
    private var list: some View {
        let tracks = tracks
        List {
            if !tracks.isEmpty {
                Section {
                    PlayShuffleButtons(
                        play: { model.play(tracks, from: PlaybackContext(kind: kind == .likedSongs ? .likedSongs : .library, title: kind.title)) },
                        shuffle: { model.play(tracks, shuffled: true, from: PlaybackContext(kind: kind == .likedSongs ? .likedSongs : .library, title: kind.title)) }
                    )
                    .padding(.horizontal, -Metrics.gutter)
                    .listRowSeparator(.hidden)
                }
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                row(item, tracks: tracks)
                    .onAppear { if i == items.count - 1 { Task { await loadMore() } } }
            }
            if loadingMore { ProgressView().frame(maxWidth: .infinity) }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func row(_ item: MediaItem, tracks: [Track]) -> some View {
        switch item {
        case .track(let track):
            TrackRow(track: track) {
                let index = tracks.firstIndex { $0.id == track.id } ?? 0
                model.play(tracks, startAt: index, from: PlaybackContext(kind: kind == .likedSongs ? .likedSongs : .library, title: kind.title))
            }
        case .artist(let artist):
            NavigationLink(value: Route.artist(artist)) {
                HStack(spacing: 12) {
                    ArtworkView(artwork: artist.artwork, points: 52, placeholder: "music.mic").frame(width: 52, height: 52).clipShape(Circle())
                    Text(artist.name)
                }
            }
            .contextMenu { ItemMenu(item: item) }
        default:
            NavigationLink(value: item.route) {
                HStack(spacing: 12) {
                    ArtworkView(artwork: item.artwork, points: 56, placeholder: kind.symbol).frame(width: 56, height: 56).clipShape(.rect(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).lineLimit(1)
                        if let subtitle = item.subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondaryText).lineLimit(1) }
                    }
                }
            }
            .contextMenu { ItemMenu(item: item) }
        }
    }

    private var emptyMessage: String {
        switch kind {
        case .likedSongs: "Songs you like show up here."
        case .playlists: "Playlists you make or save show up here."
        default: "Things you add to your library show up here."
        }
    }

    private func reload() async {
        let providers = model.libraryProviders
        let tasks = providers.map { provider in (provider.id, Task { try await provider.library(kind, continuation: nil) }) }
        var merged: [MediaItem] = []
        var next: [ProviderID: String] = [:]
        var firstError: (any Error)?
        for (id, task) in tasks {
            do {
                let page = try await task.value
                merged += page.items
                if let c = page.continuation { next[id] = c }
            } catch {
                firstError = firstError ?? error
            }
        }
        if merged.isEmpty, let firstError, !(firstError is CancellationError) {
            phase = .failed(firstError.localizedDescription)
            return
        }
        items = merged
        continuations = next
        phase = .loaded(())
    }

    private func loadMore() async {
        guard !loadingMore, let (id, token) = continuations.first, let provider = model.provider(id) else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let page = try? await provider.library(kind, continuation: token) else {
            continuations[id] = nil
            return
        }
        let seen = Set(items.map(\.id))
        items += page.items.filter { !seen.contains($0.id) }
        continuations[id] = page.continuation
    }
}

extension MediaItem {
    var route: Route? {
        switch self {
        case .album(let a): .album(a)
        case .artist(let a): .artist(a)
        case .playlist(let p): .playlist(p)
        case .track: nil
        }
    }
}
