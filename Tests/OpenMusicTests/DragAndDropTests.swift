import CoreTransferable
import Foundation
import OpenMusicCore
import Testing
import UniformTypeIdentifiers
@testable import OpenMusic

@MainActor
@Suite struct DragAndDropTests {
    private func model() async throws -> (AppModel, MockProvider, MockProvider) {
        let model = AppModel(environment: ["OPENMUSIC_MOCK": "1"])
        model.noticeDuration = .seconds(5)
        let yt = try #require(model.providers.first { $0.id == .youtubeMusic } as? MockProvider)
        let sp = try #require(model.providers.first { $0.id == .spotify } as? MockProvider)
        await model.refreshLibraryState()
        return (model, yt, sp)
    }

    @available(macOS 15.2, *)
    @Test func aDraggedSongCarriesItselfForOpenMusicAndItsLinkAndIDAsText() async throws {
        let track = Track(providerID: "abc123", provider: .youtubeMusic, title: "the cure", artists: [ArtistRef(name: "Olivia Rodrigo")])
        let drag = MediaDragItem(.track(track))
        #expect(MediaDragItem.transferRepresentation is any TransferRepresentation)

        let data = try await drag.exported(as: .openMusicItem)
        let back = try JSONDecoder().decode(MediaDragItem.self, from: data)
        #expect(back == drag)
        #expect(back.item.id == "track:\(track.id)")

        let text = try await drag.exported(as: .plainText)
        let lines = String(decoding: text, as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(lines == ["https://music.youtube.com/watch?v=abc123", "track:\(track.id)"])

        let imported = try await MediaDragItem(importing: data, contentType: .openMusicItem)
        #expect(imported == drag)
    }

    @available(macOS 15.2, *)
    @Test func collectionsExportTheirShareLinks() async throws {
        let playlist = Playlist(providerID: "37i9dQZF1DX", provider: .spotify, title: "Daily Mix 1")
        let text = try await MediaDragItem(.playlist(playlist)).exported(as: .plainText)
        #expect(String(decoding: text, as: UTF8.self).hasPrefix("https://open.spotify.com/playlist/37i9dQZF1DX\n"))
        let types = MediaDragItem(.playlist(playlist)).exportedContentTypes()
        #expect(types.first == .openMusicItem)
        #expect(types.contains { $0.conforms(to: .plainText) })
    }

    @Test func songsDroppedOnAPlaylistAreAppendedAndConfirmed() async throws {
        let (model, yt, _) = try await model()
        let playlist = try #require(model.editablePlaylists(.youtubeMusic).first)
        let before = yt.catalog.playlistTracks[playlist.providerID]?.count ?? 0
        let songs = Array(yt.catalog.allTracks.prefix(2))
        #expect(model.drop(songs.map { MediaDragItem(.track($0)) }, on: playlist))
        await model.lastDrop?.value
        let after = yt.catalog.playlistTracks[playlist.providerID] ?? []
        #expect(after.count == before + 2)
        #expect(Array(after.suffix(2)).map(\.id) == songs.map(\.id))
        #expect(model.notice?.text == "Added to \(playlist.title)")
    }

    @Test func anAlbumDroppedOnAPlaylistAddsItsSongs() async throws {
        let (model, yt, _) = try await model()
        let playlist = try #require(model.editablePlaylists(.youtubeMusic).first)
        let album = try #require(yt.catalog.albums.first)
        let albumTracks = try #require(yt.catalog.albumTracks[album.providerID])
        let before = yt.catalog.playlistTracks[playlist.providerID]?.count ?? 0
        #expect(model.drop([MediaDragItem(.album(album))], on: playlist))
        await model.lastDrop?.value
        #expect((yt.catalog.playlistTracks[playlist.providerID]?.count ?? 0) == before + albumTracks.count)
    }

    @Test func dropsThatCantGoThereAreRefused() async throws {
        let (model, yt, sp) = try await model()
        let mine = try #require(model.editablePlaylists(.youtubeMusic).first)
        let otherService = try #require(sp.catalog.allTracks.first)
        // The other service's song: refused, with a notice saying why.
        #expect(!model.drop([MediaDragItem(.track(otherService))], on: mine))
        #expect(model.notice?.kind == .failure)
        // An artist isn't a list of songs, and a mix that isn't the listener's takes nothing.
        let artist = try #require(yt.catalog.artists.first)
        #expect(!model.canDrop([MediaDragItem(.artist(artist))], on: mine))
        let mix = try #require(yt.catalog.playlists.first { !$0.isEditable })
        let song = try #require(yt.catalog.allTracks.first)
        #expect(!model.canDrop([MediaDragItem(.track(song))], on: mix))
        // A playlist onto itself adds nothing.
        #expect(!model.canDrop([MediaDragItem(.playlist(mine))], on: mine))
    }

    @Test func dropsOnPlayingNextPlayNextAboveAndQueueBelow() async throws {
        let (model, yt, _) = try await model()
        let tracks = Array(yt.catalog.allTracks.prefix(6))
        // The queue changes at once; the drops' work is awaited below.
        model.play(Array(tracks.prefix(2)), from: AppModel.PlayingFrom(title: "Test"))
        #expect(model.player.currentIndex != nil)
        let first = tracks[2], last = tracks[3]

        #expect(model.dropOnQueue([MediaDragItem(.track(first))], at: .playNext))
        await model.lastDrop?.value
        #expect(model.player.upNext.first?.track.id == first.id)
        #expect(model.notice?.text == "Playing next")

        #expect(model.dropOnQueue([MediaDragItem(.track(last))], at: .addToQueue))
        await model.lastDrop?.value
        let userQueue = model.player.upNext.filter { !$0.isAutoplay }
        #expect(userQueue.last?.track.id == last.id)
        #expect(model.notice?.text == "Added to queue")

        #expect(!model.dropOnQueue([], at: .playNext))
    }
}
