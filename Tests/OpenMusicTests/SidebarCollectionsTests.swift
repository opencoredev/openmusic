import Foundation
import OpenMusicCore
import Testing
@testable import OpenMusic

@MainActor
@Suite struct SidebarCollectionsTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-test-\(UUID().uuidString).json")
    }

    private func id(_ n: Int) -> String { MediaItem.album(album(n)).id }

    private func album(_ n: Int) -> Album {
        Album(providerID: "album-\(n)", provider: .youtubeMusic, title: "Album \(n)", artists: [ArtistRef(id: "a", name: "Daft Punk")])
    }

    @Test func recentsAreNewestFirstDeduplicatedAndCapped() {
        let store = SidebarCollections(url: tempURL())
        for n in 0..<15 { store.recordPlayed(.item(.album(album(n)))) }
        store.recordPlayed(.item(.album(album(5))))
        #expect(store.recents.count == SidebarCollections.recentLimit)
        #expect(store.recents.first?.id == id(5))
        #expect(store.recents.filter { $0.id == id(5) }.count == 1)
        #expect(store.recents[1].id == id(14))
    }

    @Test func songsAreNotRecorded() {
        let store = SidebarCollections(url: tempURL())
        let track = Track(providerID: "t1", provider: .youtubeMusic, title: "One More Time", artists: [ArtistRef(name: "Daft Punk")])
        store.recordPlayed(.item(.track(track)))
        #expect(store.recents.isEmpty)
        #expect(SidebarEntry(.track(track)) == nil)
    }

    @Test func pinnedRowsLeaveRecentsAndPersist() async {
        let url = tempURL()
        let store = SidebarCollections(url: url)
        store.recordPlayed(.item(.album(album(1))))
        store.recordPlayed(.item(.album(album(2))))
        store.pin(.item(.album(album(1))))
        store.pin(.item(.album(album(3))))
        #expect(store.unpinnedRecents.map(\.id) == [id(2)])
        store.movePinned(id(3), by: -1)
        #expect(store.pinned.map(\.id) == [id(3), id(1)])
        await store.flush()

        let reloaded = SidebarCollections(url: url)
        #expect(reloaded.pinned.map(\.id) == [id(3), id(1)])
        #expect(reloaded.recents.map(\.id) == [id(2), id(1)])
        #expect(reloaded.recents.first?.detail == "Album · Daft Punk")
        try? FileManager.default.removeItem(at: url)
    }

    @Test func playingACollectionRecordsItButASongDoesNot() {
        let model = AppModel(environment: ["OPENMUSIC_MOCK": "1"])
        #expect(model.collections.recents.isEmpty)
        let a = album(9)
        let track = Track(providerID: "t1", provider: .youtubeMusic, title: "Song", artists: [ArtistRef(name: "X")])
        model.play([track], from: .init(title: "Search: x"))
        #expect(model.collections.recents.isEmpty)
        model.play([track], from: .init(title: a.title, route: .album(.youtubeMusic, id: a.providerID, preview: a)))
        #expect(model.collections.recents.map(\.id) == [MediaItem.album(a).id])
    }

    @Test func theServiceFilterHidesOtherServicesPinsAndRecentsAndReordersTheFullList() {
        let model = AppModel(environment: ["OPENMUSIC_MOCK": "1"])
        defer { model.serviceFilter = .all }
        for entry in model.collections.pinned { model.collections.unpin(entry.id) }
        func spAlbum(_ n: Int) -> Album {
            Album(providerID: "sp-\(n)", provider: .spotify, title: "Spotify \(n)", artists: [ArtistRef(id: "s", name: "Artist")])
        }
        // Pinned, in order: YT 1, SP 1, YT 2, SP 2, YT 3.
        let order: [SidebarEntry] = [.item(.album(album(1))), .item(.album(spAlbum(1))), .item(.album(album(2))),
                                     .item(.album(spAlbum(2))), .item(.album(album(3)))]
        for entry in order { model.collections.pin(entry) }
        #expect(model.collections.pinned.map(\.id) == order.map(\.id))
        model.collections.recordPlayed(.item(.album(spAlbum(7))))
        model.collections.recordPlayed(.item(.album(album(7))))

        model.serviceFilter = .youtubeMusic
        #expect(model.sidebarPinned.map(\.id) == [id(1), id(2), id(3)])
        #expect(model.sidebarRecents.allSatisfy { $0.provider == .youtubeMusic })
        #expect(model.sidebarRecents.contains { $0.id == id(7) })

        // Dragging YT 3 above YT 2 among the visible rows: the hidden Spotify pins keep their places around them.
        model.movePinned(fromVisible: IndexSet(integer: 2), to: 1)
        #expect(model.sidebarPinned.map(\.id) == [id(1), id(3), id(2)])
        #expect(model.collections.pinned.map(\.id) == [id(1), MediaItem.album(spAlbum(1)).id, id(3), id(2), MediaItem.album(spAlbum(2)).id])
        // Move Down skips the hidden pin.
        model.movePinned(id(1), by: 1)
        #expect(model.sidebarPinned.map(\.id) == [id(3), id(1), id(2)])

        // A hidden pin isn't a row: its selection isn't Pinned's.
        #expect(!model.isPinnedInSidebar(MediaItem.album(spAlbum(1)).id))
        #expect(model.isPinnedInSidebar(id(3)))

        // Only Spotify: no YouTube pin or recent, and the section is empty where nothing is left.
        model.serviceFilter = .spotify
        #expect(model.sidebarPinned.allSatisfy { $0.provider == .spotify })
        #expect(model.sidebarRecents.allSatisfy { $0.provider == .spotify })
        model.serviceFilter = .all
        #expect(model.sidebarPinned.count == 5)
    }

    @Test func removingTheSelectedRowGoesHome() {
        let model = AppModel(environment: ["OPENMUSIC_MOCK": "1"])
        let entry = SidebarEntry.item(.album(album(4)))
        model.collections.recordPlayed(entry)
        model.select(.collection(entry.id))
        model.removeFromRecentlyPlayed(entry.id)
        #expect(model.sidebarSelection == .home)
    }

    @Test func oneArtistRadioIsOneRowWhicheverSeedStartedIt() {
        let artist = Artist(providerID: "UCdp", provider: .youtubeMusic, name: "Daft Punk")
        let fromPage = SidebarEntry.radio(RadioStation(provider: .youtubeMusic, seedID: "RDEMabc", name: "Daft Punk", origin: .artist(artist)))
        let fromMenu = SidebarEntry.radio(RadioStation(provider: .youtubeMusic, seedID: "UCdp", name: "Daft Punk", origin: .artist(artist)))
        #expect(fromPage.id == fromMenu.id)
        #expect(fromPage.id != SidebarEntry.item(.artist(artist)).id)
    }

    @Test func radioRowsOpenTheirOrigin() {
        let artist = Artist(providerID: "artist-1", provider: .youtubeMusic, name: "Daft Punk")
        let radio = SidebarEntry.radio(RadioStation(provider: .youtubeMusic, seedID: "RDX", name: "Daft Punk", origin: .artist(artist)))
        #expect(radio.title == "Daft Punk Radio")
        #expect(radio.detail == "Radio")
        #expect(radio.route == .artist(.youtubeMusic, id: "artist-1", preview: artist))
    }
}
