import Foundation
import MedleyCore
import Testing
@testable import Medley

/// Playback requests keep the order the listener chose them in: a request still loading (Liked Songs, a collection)
/// gives up when anything newer is chosen, a second click on the same row while it loads makes no second request, and
/// the row shows a spinner only while its own request loads.
@MainActor
@Suite struct PlayRequestTests {
    private func setUp(libraryDelay: Duration = .milliseconds(400)) async throws -> (AppModel, [MockProvider]) {
        let model = AppModel(environment: ["MEDLEY_MOCK": "1"])
        model.noticeDuration = .seconds(10)
        await model.refreshLibraryState()
        let mocks = model.providers.compactMap { $0 as? MockProvider }
        for mock in mocks { mock.libraryDelay = libraryDelay }
        return (model, mocks)
    }

    private func someSong(_ mock: MockProvider) throws -> Track {
        try #require(mock.catalog.allTracks.first { $0.isPlayable })
    }

    @Test func aSongChosenWhileLikedSongsLoadsKeepsPlaying() async throws {
        let (model, mocks) = try await setUp()
        model.playLikedSongs()
        #expect(model.isPlayPending(.likedSongs))

        // The listener picks a song before Liked Songs has loaded.
        let song = try someSong(mocks[0])
        model.play([song], from: AppModel.PlayingFrom(title: song.title))
        #expect(model.pendingPlay == nil)
        #expect(model.player.current?.id == song.id)

        // Liked Songs arrives later and changes nothing: no queue replaced, no pages appended, no notice.
        try await Task.sleep(for: .milliseconds(900))
        #expect(model.player.current?.id == song.id)
        #expect(model.playingFrom?.title == song.title)
        // Only the chosen song (autoplay may add its own suggestions after it), none of the liked songs.
        #expect(model.player.queue.filter { !$0.isAutoplay }.map(\.track.id) == [song.id])
        #expect(model.notice == nil)
        #expect(!model.isPlayPending(.likedSongs))
    }

    @Test func aFailureOfASupersededRequestIsNotReported() async throws {
        let (model, mocks) = try await setUp()
        for mock in mocks { mock.libraryFailure = .network("offline") }
        model.playLikedSongs()
        let song = try someSong(mocks[0])
        model.play([song], from: AppModel.PlayingFrom(title: song.title))
        try await Task.sleep(for: .milliseconds(900))
        #expect(model.notice == nil)
        #expect(model.player.current?.id == song.id)
    }

    @Test func aDoubleClickOnLikedSongsMakesOneRequest() async throws {
        let (model, mocks) = try await setUp()
        // The library refresh read each service's first page once already.
        let before = mocks.map { $0.libraryRequests.filter { $0 == "likedSongs:first" }.count }
        model.playOrPause(AppModel.likedSongsContext) { model.playLikedSongs() }
        let request = model.playRequest
        model.playOrPause(AppModel.likedSongsContext) { model.playLikedSongs() }
        #expect(model.playRequest == request)
        for _ in 0..<60 where model.player.current == nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(model.playingFrom == AppModel.likedSongsContext)
        #expect(model.pendingPlay == nil)
        for (mock, earlier) in zip(mocks, before) {
            #expect(mock.libraryRequests.filter { $0 == "likedSongs:first" }.count == earlier + 1)
        }
    }

    @Test func aDoubleClickOnACollectionMakesOneRequest() async throws {
        let (model, mocks) = try await setUp()
        mocks[0].latency = .milliseconds(300)
        let album = try #require(mocks[0].catalog.albums.first)
        let key = AppModel.PlayRequestKey.collection(MediaItem.album(album).id, shuffled: false)
        model.play(.album(album))
        #expect(model.isPlayPending(key))
        let request = model.playRequest
        model.play(.album(album))
        #expect(model.playRequest == request)
        for _ in 0..<60 where model.player.current == nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(model.playingFrom?.title == album.title)
        #expect(!model.isPlayPending(key))
    }

    @Test func aNewerCollectionSupersedesAnOlderOne() async throws {
        let (model, mocks) = try await setUp()
        mocks[0].latency = .milliseconds(300)
        let albums = Array(mocks[0].catalog.albums.prefix(2))
        try #require(albums.count == 2)
        model.play(.album(albums[0]))
        model.play(.album(albums[1]))
        #expect(model.isPlayPending(.collection(MediaItem.album(albums[1]).id, shuffled: false)))
        // Poll instead of one fixed sleep: under a loaded machine the 300 ms load can take longer than a second.
        for _ in 0..<100 where model.playingFrom?.title != albums[1].title || model.pendingPlay != nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        // Then give a late, stale load of the older album time to land: it must not take over.
        try await Task.sleep(for: .milliseconds(600))
        #expect(model.playingFrom?.title == albums[1].title)
        #expect(model.pendingPlay == nil)
    }

    @Test func aQueueJumpSupersedesALoadingRequest() async throws {
        let (model, mocks) = try await setUp()
        let tracks = Array(mocks[0].catalog.allTracks.filter(\.isPlayable).prefix(3))
        model.play(tracks, from: AppModel.PlayingFrom(title: "Test"))
        model.playLikedSongs()
        let target = try #require(model.player.queue.last)
        model.jump(to: target.uid)
        #expect(model.pendingPlay == nil)
        try await Task.sleep(for: .milliseconds(900))
        #expect(model.player.current?.id == target.track.id)
        #expect(model.playingFrom?.title == "Test")
    }

    @Test func showMoreFoldsOnlyTwoOrMoreRows() {
        #expect(!SidebarMetrics.foldsRows(4, shown: 3))
        #expect(SidebarMetrics.foldsRows(5, shown: 3))
        #expect(SidebarMetrics.visibleRows(4, shown: 3, expanded: false) == 4)
        #expect(SidebarMetrics.visibleRows(5, shown: 3, expanded: false) == 3)
        #expect(SidebarMetrics.visibleRows(5, shown: 3, expanded: true) == 5)
        #expect(SidebarMetrics.visibleRows(11, shown: 10, expanded: false) == 11)
    }
}
