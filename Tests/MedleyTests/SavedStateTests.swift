import Foundation
import MedleyCore
import Testing
@testable import Medley

/// One saved/followed state per collection: the hero button, every context menu and the sidebar read it, a refused
/// change rolls back, and Try Again asks for the same state again.
@MainActor
@Suite struct SavedStateTests {
    private func setUp() async throws -> (AppModel, MockProvider, Album) {
        let model = AppModel(environment: ["MEDLEY_MOCK": "1"])
        model.noticeDuration = .seconds(10)
        let yt = try #require(model.providers.first { $0.id == .youtubeMusic } as? MockProvider)
        let page = try await yt.library(.albums, continuation: nil)
        let album = try #require(page.items.compactMap { if case .album(let a) = $0 { a } else { nil } }.first)
        return (model, yt, album)
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }

    @Test func aRefusedSaveRollsBackAndTryAgainAsksForTheSameState() async throws {
        let (model, yt, album) = try await setUp()
        let detail = try await yt.album(id: album.providerID)
        let item = MediaItem.album(detail.album)
        // The page reports "not saved" (YouTube's "0"), and tells the model.
        #expect(AppModel.reportedSaved(item) == false)
        model.noteSaved(item, reported: AppModel.reportedSaved(item))
        #expect(model.saveAction(for: item)?.title == "Add to Library")

        yt.failingWrites = .network(URLError(.notConnectedToInternet).localizedDescription)
        model.setSaved(item, saved: true)
        // Shown at once, before the service answers.
        #expect(model.isSaved(item) == true)
        #expect(model.saveAction(for: item)?.title == "Remove from Library")
        try await settle()

        // Refused: back to not saved, with the failure named and Try Again offered.
        #expect(model.isSaved(item) == false)
        #expect(model.saveAction(for: item)?.title == "Add to Library")
        let notice = try #require(model.notice)
        #expect(notice.kind == .failure)
        #expect(notice.text == "Couldn’t add “\(album.title)” to your library. You’re offline.")
        let retry = try #require(notice.retry)

        // Try Again asks to save again (not a toggle); with the service back it sticks, and the cached page goes.
        model.cache.set(detail, for: item.id)
        yt.failingWrites = nil
        model.dismissNotice()
        retry()
        try await settle()
        #expect(model.isSaved(item) == true)
        #expect(model.saveAction(for: item)?.title == "Remove from Library")
        let cached: (value: AlbumDetail, date: Date)? = model.cache.value(for: "album:\(album.provider.rawValue):\(album.providerID)")
        #expect(cached == nil)
        // The service now reports it saved too.
        #expect(AppModel.reportedSaved(.album(try await yt.album(id: album.providerID).album)) == true)
    }

    @Test func aStaleFlagAfterTheListenersChangeDoesNotUndoIt() async throws {
        let (model, _, album) = try await setUp()
        let item = MediaItem.album(album)
        model.noteSaved(item, reported: false)
        model.setSaved(item, saved: true)
        try await settle()
        // A page loaded right after the change can still carry the old flag; the listener's change wins.
        model.noteSaved(item, reported: false)
        #expect(model.isSaved(item) == true)
    }

    @Test func menusAndHeroAgreeWhateverCopyOfTheItemTheyHold() async throws {
        let (model, _, album) = try await setUp()
        // The page's copy carries the flag; a card's copy of the same album (from a shelf) carries none.
        var pageCopy = album
        pageCopy.extra["saved"] = "1"
        var cardCopy = album
        cardCopy.extra["saved"] = nil
        #expect(model.saveAction(for: .album(cardCopy))?.title == "Add to Library")
        model.noteSaved(.album(pageCopy), reported: AppModel.reportedSaved(.album(pageCopy)))
        let hero = try #require(model.saveAction(for: .album(pageCopy)))
        let menu = try #require(model.saveAction(for: .album(cardCopy)))
        #expect(hero == menu)
        #expect(menu.title == "Remove from Library")
        #expect(menu.target == false)

        // Keyed by provider and id: the same id on the other service is its own collection.
        var other = album
        other.provider = .spotify
        other.extra["saved"] = nil
        #expect(model.isSaved(.album(other)) == nil)
    }

    @Test func aRefusedUnfollowPutsFollowingBack() async throws {
        let (model, yt, album) = try await setUp()
        let artistID = try #require(album.artists.first?.id)
        let detail = try await yt.artist(id: artistID)
        let item = MediaItem.artist(detail.artist)
        model.setSaved(item, saved: true)
        try await settle()
        #expect(model.saveAction(for: item)?.title == "Unfollow")
        #expect(model.notice?.text == "Following \(detail.artist.name)")

        yt.failingWrites = .rateLimited
        model.setSaved(item, saved: false)
        #expect(model.saveAction(for: item)?.title == "Follow")
        try await settle()
        #expect(model.isSaved(item) == true)
        #expect(model.saveAction(for: item)?.title == "Unfollow")
        #expect(model.notice?.text.hasPrefix("Couldn’t unfollow “\(detail.artist.name)”") == true)
        #expect(model.notice?.retry != nil)
    }

    @Test func sidebarPlaylistsAreSavedAndOwnPlaylistsOfferNoSave() async throws {
        let model = AppModel(environment: ["MEDLEY_MOCK": "1"])
        await model.refreshLibraryState()
        let playlists = model.libraryPlaylists[.youtubeMusic] ?? []
        if let own = playlists.first(where: \.isEditable) {
            #expect(model.saveAction(for: .playlist(own)) == nil)
        }
        let followed = try #require(playlists.first { !$0.isEditable })
        #expect(model.isSaved(.playlist(followed)) == true)
        #expect(model.saveAction(for: .playlist(followed))?.title == "Remove from Library")
        model.setSaved(.playlist(followed), saved: false)
        try await settle()
        #expect(!(model.libraryPlaylists[.youtubeMusic] ?? []).contains { $0.providerID == followed.providerID })
        #expect(model.saveAction(for: .playlist(followed))?.title == "Add to Library")
    }
}
