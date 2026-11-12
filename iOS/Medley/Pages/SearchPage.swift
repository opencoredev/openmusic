import MedleyCore
import SwiftUI

struct SearchTab: View {
    @Environment(AppModel.self) private var model
    @State private var suggestions = SearchSuggestions()

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: model.path(.search)) {
            SearchContent()
                .navigationTitle("Search")
                // Results start right under the field and scopes, as in Music; the large title is for browsing.
                .toolbarTitleDisplayMode(model.submittedQuery.isEmpty ? .inlineLarge : .inline)
                .medleyDestinations()
                .toolbar { ToolbarItem(placement: .topBarTrailing) { AccountButton() } }
        }
        // Always shown, also over Recently Searched (a List, which would otherwise tuck the field away until pulled).
        .searchable(text: $model.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Artists, Songs, Albums and More")
        .searchScopes($model.searchScope, activation: .onSearchPresentation) {
            Text("All").tag(SearchScope.all)
            Text("Songs").tag(SearchScope.songs)
            Text("Albums").tag(SearchScope.albums)
            Text("Artists").tag(SearchScope.artists)
            Text("Playlists").tag(SearchScope.playlists)
        }
        .searchSuggestions {
            if model.searchText != model.submittedQuery {
                ForEach(suggestions.queries, id: \.self) { query in
                    // Color.primary, not the hierarchical .primary: inside a suggestion that resolves to the tint.
                    Label {
                        Text(query).foregroundStyle(Color.primary)
                    } icon: {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondaryText)
                    }
                    .searchCompletion(query)
                }
                ForEach(suggestions.items.prefix(4)) { item in
                    SuggestedItemRow(item: item)
                }
            }
        }
        .onSubmit(of: .search) { model.submitSearch() }
        .onChange(of: model.searchText) { _, text in
            // Picking a completion fills the field with it: treat that as a submit.
            if suggestions.queries.contains(text) { model.submitSearch() }
            if text.isEmpty { model.submittedQuery = "" }
        }
        .task(id: model.searchText) {
            let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, query != model.submittedQuery else { suggestions = SearchSuggestions(); return }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let found = await model.suggestions(query)
            guard !Task.isCancelled else { return }
            suggestions = found
        }
    }
}

private struct SuggestedItemRow: View {
    let item: MediaItem
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.submitSearch(item.title)
            model.open(item: item)
        } label: {
            HStack(spacing: 12) {
                ArtworkView(artwork: item.artwork, points: 44, placeholder: isArtist ? "music.mic" : "music.note")
                    .frame(width: 44, height: 44)
                    .clipShape(isArtist ? AnyShape(Circle()) : AnyShape(.rect(cornerRadius: 5)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).foregroundStyle(Color.primary).lineLimit(1)
                    Text(kind + (item.subtitle.map { " · \($0)" } ?? "")).font(.subheadline).foregroundStyle(.secondaryText).lineLimit(1)
                }
            }
        }
    }

    private var isArtist: Bool { if case .artist = item { true } else { false } }

    private var kind: String {
        switch item {
        case .track: "Song"
        case .album: "Album"
        case .artist: "Artist"
        case .playlist: "Playlist"
        }
    }
}

private struct SearchContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSearching) private var isSearching

    var body: some View {
        @Bindable var model = model
        if model.submittedQuery.isEmpty {
            RecentSearches()
        } else {
            Loader(key: "search:\(model.searchScope.rawValue):\(model.submittedQuery)") {
                try await model.search(model.submittedQuery, scope: model.searchScope)
            } content: { results in
                if results.isEmpty {
                    ContentUnavailableView {
                        Label("No Results for “\(model.submittedQuery)”", systemImage: "magnifyingglass")
                    } description: {
                        Text("Check the spelling or try a new search.").font(.subheadline).foregroundStyle(.secondaryText)
                    }
                } else if model.searchScope == .all {
                    TopResults(results: results)
                } else {
                    ScopedResults(results: results, scope: model.searchScope)
                }
            }
            .id(model.searchScope)
            // The scopes stay under the field with the results; while the field is active the system shows its own.
            .safeAreaBar(edge: .top) {
                if !isSearching {
                    Picker("Search In", selection: $model.searchScope) {
                        ForEach(SearchScope.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.bottom, 8)
                }
            }
        }
    }
}

extension SearchScope {
    var title: String {
        switch self {
        case .all: "All"
        case .songs: "Songs"
        case .albums: "Albums"
        case .artists: "Artists"
        case .playlists: "Playlists"
        }
    }
}

/// Search before anything is typed: recent searches, then moods and genres to browse (from the services' explore
/// pages, the same tiles as New).
private struct RecentSearches: View {
    @Environment(AppModel.self) private var model
    @State private var categories: [Playlist] = []

    var body: some View {
        List {
            if !model.recentSearches.isEmpty {
                Section {
                    ForEach(model.recentSearches, id: \.self) { query in
                        Button {
                            model.submitSearch(query)
                        } label: {
                            Label {
                                Text(query).foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondaryText)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Recently Searched").foregroundStyle(.secondaryText)
                        Spacer()
                        Button("Clear") { model.clearRecentSearches() }.font(.subheadline)
                    }
                }
            }
            if !categories.isEmpty {
                Section {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(categories.prefix(8)) { CategoryTile(category: $0) }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: Metrics.gutter, bottom: 16, trailing: Metrics.gutter))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } header: {
                    Text("Browse Categories")
                        .font(.title2.bold())
                        .foregroundStyle(Color.primary)
                        .textCase(nil)
                        .padding(.top, 16)
                        .accessibilityAddTraits(.isHeader)
                }
            } else if model.recentSearches.isEmpty {
                ContentUnavailableView("Search YouTube Music", systemImage: "magnifyingglass",
                                       description: Text("Find songs, albums, artists and playlists. Lyrics work too."))
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .task(id: model.refreshTick) {
            // The same page New loads, through the same cache entry.
            let shelves = try? await model.cached("new") { try await loadShelves(model, .explore) }
            categories = shelves?.first(where: \.isCategoryShelf)?.categories ?? []
        }
    }
}

private struct TopResults: View {
    let results: SearchResults
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if let top = results.top {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Top Result")
                        TopResultCard(item: top, tracks: results.tracks).padding(.horizontal, Metrics.gutter)
                    }
                }
                if !results.tracks.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            SectionHeader(title: "Songs")
                            if results.tracks.count > 4 {
                                Button("See All") { model.searchScope = .songs }.padding(.trailing, Metrics.gutter)
                            }
                        }
                        ForEach(Array(results.tracks.prefix(4).enumerated()), id: \.element.id) { i, track in
                            TrackRow(track: track) { play(i) }
                                .padding(.vertical, 4)
                                .padding(.horizontal, Metrics.gutter)
                        }
                    }
                }
                if !results.artists.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Artists")
                        Carousel { ForEach(results.artists) { ArtistCircle(artist: $0, size: 100) } }
                    }
                }
                if !results.albums.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Albums")
                        Carousel { ForEach(results.albums) { MediaCard(item: .album($0)) } }
                    }
                }
                if !results.playlists.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Playlists")
                        Carousel { ForEach(results.playlists) { MediaCard(item: .playlist($0)) } }
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func play(_ index: Int) {
        let track = results.tracks[index]
        // A song from search starts its radio, the way YouTube Music does, so playback keeps going.
        model.play([track], from: PlaybackContext(kind: .search, title: model.submittedQuery))
    }
}

private struct TopResultCard: View {
    let item: MediaItem
    let tracks: [Track]
    @Environment(AppModel.self) private var model
    @Environment(\.isShortScreen) private var isShortScreen

    var body: some View {
        Button {
            if case .track(let t) = item {
                model.play([t], from: PlaybackContext(kind: .search, title: model.submittedQuery))
            } else {
                model.open(item: item)
            }
        } label: {
            let side: CGFloat = isShortScreen ? 64 : 88
            HStack(spacing: 14) {
                ArtworkView(artwork: item.artwork, points: side, placeholder: isArtist ? "music.mic" : "music.note")
                    .frame(width: side, height: side)
                    .clipShape(isArtist ? AnyShape(Circle()) : AnyShape(.rect(cornerRadius: 8)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.title3.bold()).foregroundStyle(.primary).lineLimit(2)
                    Text(kind + (item.subtitle.map { " · \($0)" } ?? "")).font(.subheadline).foregroundStyle(.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(isShortScreen ? 12 : 14)
            .background(.fill.quinary, in: .rect(cornerRadius: 16))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu { ItemMenu(item: item) }
    }

    private var isArtist: Bool { if case .artist = item { true } else { false } }

    private var kind: String {
        switch item {
        case .track: "Song"
        case .album: "Album"
        case .artist: "Artist"
        case .playlist: "Playlist"
        }
    }
}

private struct ScopedResults: View {
    let results: SearchResults
    let scope: SearchScope
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            switch scope {
            case .songs, .all:
                LazyVStack(spacing: 0) {
                    ForEach(Array(results.tracks.enumerated()), id: \.element.id) { i, track in
                        TrackRow(track: track) {
                            model.play([track], from: PlaybackContext(kind: .search, title: model.submittedQuery))
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, Metrics.gutter)
                        Divider().padding(.leading, Metrics.gutter + 60)
                    }
                }
            case .artists:
                grid { ForEach(results.artists) { ArtistCircle(artist: $0, size: 150) } }
            case .albums:
                grid { ForEach(results.albums) { MediaCard(item: .album($0)) } }
            case .playlists:
                grid { ForEach(results.playlists) { MediaCard(item: .playlist($0)) } }
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func grid<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16, alignment: .top)], spacing: 22) { content() }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 12)
    }
}
