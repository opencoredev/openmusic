import OpenMusicCore
import SwiftUI

// MARK: Shared header

/// Centered artwork, title, a tappable artist line and a meta line, then Play / Shuffle.
private struct CollectionHeader: View {
    let artwork: Artwork?
    let title: String
    let artist: String?
    var artistRoute: Route?
    let meta: String?
    var placeholder = "music.note"
    @Environment(\.isShortScreen) private var isShortScreen

    /// Smaller on a short iPhone, so Play / Shuffle and the first songs show above the mini player.
    static func artworkSide(short: Bool) -> CGFloat { short ? 160 : 270 }

    var body: some View {
        let side = Self.artworkSide(short: isShortScreen)
        VStack(spacing: 6) {
            ArtworkView(artwork: artwork, points: side, placeholder: placeholder)
                .frame(width: side, height: side)
                .clipShape(.rect(cornerRadius: 12))
                .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
                .padding(.bottom, isShortScreen ? 6 : 12)
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            if let artist, !artist.isEmpty {
                if let artistRoute {
                    NavigationLink(value: artistRoute) {
                        Text(artist).font(.title3).foregroundStyle(.tint).multilineTextAlignment(.center)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(artist).font(.title3).foregroundStyle(.tint).multilineTextAlignment(.center)
                }
            }
            if let meta, !meta.isEmpty {
                Text(meta).font(.footnote.weight(.semibold)).foregroundStyle(.secondaryText)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, isShortScreen ? 2 : 8)
        .padding(.bottom, isShortScreen ? 10 : 16)
        .frame(maxWidth: .infinity)
    }
}

private func duration(_ tracks: [Track]) -> String? {
    let total = tracks.compactMap(\.duration).reduce(0, +)
    guard total > 0 else { return nil }
    let minutes = Int(total / 60)
    return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
}

// MARK: Album

struct AlbumPage: View {
    let album: Album
    @Environment(AppModel.self) private var model

    var body: some View {
        Loader(key: "album:\(album.id)") { try await load() } content: { detail in
            AlbumContent(detail: detail)
        }
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu { ItemMenu(item: .album(album)) } label: { Label("More", systemImage: "ellipsis") }
            }
        }
    }

    private func load() async throws -> AlbumDetail {
        guard let provider = model.provider(album.provider) else { throw ProviderError.notFound }
        return try await provider.album(id: album.providerID)
    }
}

private struct AlbumContent: View {
    let detail: AlbumDetail
    @Environment(AppModel.self) private var model
    @Environment(\.isShortScreen) private var isShortScreen

    var body: some View {
        let album = detail.album
        let context = PlaybackContext.album(album)
        let isCurrent = model.player.currentContext == context
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                CollectionHeader(
                    artwork: album.artwork,
                    title: album.title,
                    artist: album.artistLine,
                    artistRoute: album.artists.first(where: { $0.id != nil }).map { .artist(Artist(providerID: $0.id!, provider: album.provider, name: $0.name)) },
                    meta: [kindLabel(album.kind), album.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
                )
                PlayShuffleButtons(
                    play: {
                        if isCurrent { model.player.togglePlayPause() } else { model.play(detail.tracks, from: context) }
                    },
                    shuffle: { model.play(detail.tracks, shuffled: true, from: context) },
                    isCurrentPlaying: isCurrent && model.player.isPlaying
                )
                .padding(.bottom, isShortScreen ? 8 : 18)
                if let summary = detail.summary, !summary.isEmpty {
                    ExpandableText(text: summary).padding(.horizontal, Metrics.gutter).padding(.bottom, 12)
                }
                Divider().padding(.leading, Metrics.gutter)
                ForEach(Array(detail.tracks.enumerated()), id: \.element.id) { i, track in
                    TrackRow(track: track, number: track.trackNumber ?? i + 1, showsArtist: track.artistLine != album.artistLine) {
                        model.play(detail.tracks, startAt: i, from: context)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, Metrics.gutter)
                    Divider().padding(.leading, Metrics.gutter + 36)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(detail.tracks.count) songs\(duration(detail.tracks).map { ", \($0)" } ?? "")")
                    if let footnote = detail.footnote { Text(footnote) }
                }
                .font(.footnote)
                .foregroundStyle(.secondaryText)
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 14)
                if !detail.moreByArtist.isEmpty {
                    SectionHeader(title: "More by \(album.artistLine)").padding(.top, 16).padding(.bottom, 12)
                    Carousel { ForEach(detail.moreByArtist) { MediaCard(item: .album($0)) } }
                }
            }
            .padding(.bottom, 24)
        }
        .collapsingTitle(album.title, after: CollectionHeader.artworkSide(short: isShortScreen) + 50)
    }

    private func kindLabel(_ kind: AlbumKind) -> String? {
        switch kind {
        case .album: "Album"
        case .single: "Single"
        case .ep: "EP"
        case .compilation: "Compilation"
        case .unknown: nil
        }
    }
}

// MARK: Playlist

struct PlaylistPage: View {
    let playlist: Playlist
    @Environment(AppModel.self) private var model

    var body: some View {
        Loader(key: "playlist:\(playlist.id)") { try await load() } content: { detail in
            PlaylistContent(detail: detail)
        }
        .navigationTitle(playlist.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu { ItemMenu(item: .playlist(playlist)) } label: { Label("More", systemImage: "ellipsis") }
            }
        }
    }

    private func load() async throws -> PlaylistDetail {
        guard let provider = model.provider(playlist.provider) else { throw ProviderError.notFound }
        return try await provider.playlist(id: playlist.providerID)
    }
}

private struct PlaylistContent: View {
    let detail: PlaylistDetail
    @Environment(AppModel.self) private var model
    @Environment(\.isShortScreen) private var isShortScreen
    @State private var more: [Track] = []
    @State private var continuation: String?
    @State private var loadingMore = false

    var body: some View {
        let playlist = detail.playlist
        let tracks = detail.tracks + more
        let context = PlaybackContext.playlist(playlist)
        let isCurrent = model.player.currentContext == context
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                CollectionHeader(artwork: playlist.artwork, title: playlist.title, artist: playlist.owner, meta: playlist.trackCount.map { "\($0) songs" },
                                 placeholder: "music.note.list")
                PlayShuffleButtons(
                    play: {
                        if isCurrent { model.player.togglePlayPause() } else {
                            Task { await model.playPlaylist(tracks, continuation: continuation, playlist: playlist) }
                        }
                    },
                    shuffle: { Task { await model.playPlaylist(tracks, continuation: continuation, playlist: playlist, shuffled: true) } },
                    isCurrentPlaying: isCurrent && model.player.isPlaying
                )
                .padding(.bottom, isShortScreen ? 8 : 18)
                if let summary = playlist.summary, !summary.isEmpty {
                    ExpandableText(text: summary).padding(.horizontal, Metrics.gutter).padding(.bottom, 12)
                }
                ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                    TrackRow(track: track) {
                        Task { await model.playPlaylist(tracks, continuation: continuation, playlist: playlist, startAt: i) }
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, Metrics.gutter)
                    .onAppear { if i == tracks.count - 1 { loadMore() } }
                    Divider().padding(.leading, Metrics.gutter + 60)
                }
                if loadingMore { ProgressView().frame(maxWidth: .infinity).padding() }
            }
            .padding(.bottom, 24)
        }
        .collapsingTitle(playlist.title, after: CollectionHeader.artworkSide(short: isShortScreen) + 50)
        .onAppear { if continuation == nil, more.isEmpty { continuation = detail.continuation } }
    }

    private func loadMore() {
        guard let token = continuation, !loadingMore, let provider = model.provider(detail.playlist.provider) else { return }
        loadingMore = true
        Task {
            if let page = try? await provider.playlistTracks(continuation: token) {
                let seen = Set((detail.tracks + more).map(\.id))
                more += page.items.filter { !seen.contains($0.id) }
                continuation = page.continuation
            } else {
                continuation = nil
            }
            loadingMore = false
        }
    }
}

// MARK: Artist

struct ArtistPage: View {
    let artist: Artist
    @Environment(AppModel.self) private var model

    var body: some View {
        Loader(key: "artist:\(artist.id)") { try await load() } content: { detail in
            ArtistContent(detail: detail)
        }
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu { ItemMenu(item: .artist(artist)) } label: { Label("More", systemImage: "ellipsis") }
            }
        }
    }

    private func load() async throws -> ArtistDetail {
        guard let provider = model.provider(artist.provider) else { throw ProviderError.notFound }
        return try await provider.artist(id: artist.providerID)
    }
}

private struct ArtistContent: View {
    let detail: ArtistDetail
    @Environment(AppModel.self) private var model
    @Environment(\.isShortScreen) private var isShortScreen

    var body: some View {
        let artist = detail.artist
        let context = PlaybackContext.artist(artist)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                hero(artist, context: context)
                if !detail.topTracks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Top Songs")
                        ForEach(Array(detail.topTracks.prefix(10).enumerated()), id: \.element.id) { i, track in
                            TrackRow(track: track) { model.play(detail.topTracks, startAt: i, from: context) }
                                .padding(.vertical, 4)
                                .padding(.horizontal, Metrics.gutter)
                        }
                    }
                }
                albumRow("Albums", detail.albums)
                albumRow("Singles & EPs", detail.singles)
                if !detail.playlists.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Playlists")
                        Carousel { ForEach(detail.playlists) { MediaCard(item: .playlist($0)) } }
                    }
                }
                albumRow("Appears On", detail.appearsOn)
                if !detail.related.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Similar Artists")
                        Carousel { ForEach(detail.related) { ArtistCircle(artist: $0) } }
                    }
                }
                if let bio = detail.bio, !bio.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "About \(artist.name)")
                        ExpandableText(text: bio, lineLimit: 5).padding(.horizontal, Metrics.gutter)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .ignoresSafeArea(edges: .top)
        .collapsingTitle(artist.name, after: heroHeight - 120, clearsEdge: true)
    }

    /// Tall enough that a square portrait keeps the whole head below the status bar and the floating back button;
    /// on a short iPhone, short enough that Top Songs starts on the first screen.
    private var heroHeight: CGFloat { isShortScreen ? 300 : 460 }

    /// Full-bleed portrait with the name and a round Play button over it, Apple Music style.
    private func hero(_ artist: Artist, context: PlaybackContext) -> some View {
        GeometryReader { geo in
            let minY = geo.frame(in: .scrollView).minY
            ArtworkView(artwork: artist.artwork, points: 440, placeholder: "music.mic")
                .frame(width: geo.size.width, height: geo.size.height + max(0, minY))
                .clipped()
                .offset(y: -max(0, minY))
                .overlay(alignment: .bottom) {
                    HStack(alignment: .bottom) {
                        Text(artist.name)
                            .font(.largeTitle.bold())
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                        Spacer()
                        HStack(spacing: 10) {
                            if let seed = detail.radioSeed, model.can(.radio, artist.provider) {
                                Button {
                                    model.startRadio(seedID: seed, title: artist.name, provider: artist.provider)
                                } label: {
                                    Image(systemName: "dot.radiowaves.left.and.right").font(.title3.weight(.semibold)).frame(width: 34, height: 34)
                                }
                                .buttonStyle(.glass)
                                .buttonBorderShape(.circle)
                                .accessibilityLabel("Start Radio")
                            }
                            Button {
                                let isCurrent = model.player.currentContext == context
                                if isCurrent { model.player.togglePlayPause() } else { model.play(detail.topTracks, from: context) }
                            } label: {
                                Image(systemName: model.player.currentContext == context && model.player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title2)
                                    .frame(width: 40, height: 40)
                            }
                            .buttonStyle(.glassProminent)
                            .buttonBorderShape(.circle)
                            .accessibilityLabel("Play")
                            .disabled(detail.topTracks.isEmpty)
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.bottom, 16)
                    .padding(.top, 60)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                }
        }
        .frame(height: heroHeight)
    }

    @ViewBuilder
    private func albumRow(_ title: String, _ albums: [Album]) -> some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: title)
                Carousel { ForEach(albums) { MediaCard(item: .album($0)) } }
            }
        }
    }
}

// MARK: Text

struct ExpandableText: View {
    let text: String
    var lineLimit = 3
    @State private var expanded = false
    /// Heights of the text at its line limit and in full: "More" shows only when the limit cuts something off.
    @State private var limitedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    private var isTruncated: Bool { fullHeight > limitedHeight + 1 }

    var body: some View {
        Button {
            guard isTruncated || expanded else { return }
            withAnimation(.snappy) { expanded.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondaryText)
                    .lineLimit(expanded ? nil : lineLimit)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if !expanded { limitedHeight = $0 } }
                    .background(alignment: .topLeading) {
                        Text(text)
                            .font(.subheadline)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .hidden()
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                    }
                if !expanded, isTruncated { Text("More").font(.subheadline.weight(.semibold)).foregroundStyle(.tint) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(isTruncated && !expanded ? "Shows the full text" : "")
    }
}
