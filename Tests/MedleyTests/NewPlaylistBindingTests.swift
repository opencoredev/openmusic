import Foundation
import MedleyCore
import Testing
@testable import Medley

/// Sol's review of b56ad76: New Playlist is bound to the account it started under, refused during a sign-in swap, and
/// its Try Again after a failed append adds the songs to the playlist already made instead of making another.
@MainActor
@Suite struct NewPlaylistBindingTests {
    private let offline = ProviderError.network(URLError(.notConnectedToInternet).localizedDescription)

    private func setUp() throws -> (AppModel, MockProvider, [Track]) {
        let model = AppModel(environment: ["MEDLEY_MOCK": "1"])
        model.noticeDuration = .seconds(30)
        let sp = try #require(model.providers.first { $0.id == .spotify } as? MockProvider)
        sp.sessionOverride = ProviderSession(generation: 0, identity: .account(id: "listener"))
        return (model, sp, Array(sp.catalog.allTracks.prefix(3)))
    }

    private func made(_ sp: MockProvider, _ title: String) -> [Playlist] { sp.catalog.playlists.filter { $0.title == title } }

    @Test func newPlaylistDuringASwapIsRefused() async throws {
        let (model, sp, songs) = try setUp()
        let settled = sp.session
        sp.sessionOverride = settled.next(.changing)
        await model.createPlaylist("Swapped", provider: .spotify, adding: songs).value
        #expect(made(sp, "Swapped").isEmpty, "nothing created during the swap")
        let notice = try #require(model.notice)
        #expect(notice.text == "Couldn’t create “Swapped”. Your Spotify sign-in was changing.")
        let retry = try #require(notice.retry)
        sp.sessionOverride = settled.next(.changing).next(.account(id: "listener"))
        model.dismissNotice()
        retry()
        for _ in 0..<50 where made(sp, "Swapped").isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        await model.lastPlaylistEdit?.value
        let playlist = try #require(made(sp, "Swapped").first)
        #expect(sp.catalog.playlistTracks[playlist.providerID]?.map(\.id) == songs.map(\.id))
    }

    /// Another account's credentials land between the check and the creation request: nothing is created.
    @Test func aSwapBetweenTheCheckAndTheSendCreatesNothing() async throws {
        let (model, sp, songs) = try setUp()
        sp.playlistEditGate = { kind in if kind == "create" { sp.credentialsAccountID = "intruder" } }
        await model.createPlaylist("Intruded", provider: .spotify, adding: songs).value
        #expect(made(sp, "Intruded").isEmpty)
        #expect(model.notice?.text == "Couldn’t create “Intruded”. Your Spotify sign-in was changing.")
    }

    /// The playlist is made, then adding its songs fails: Try Again adds them to that playlist, and no second one is made.
    @Test func tryAgainAfterAFailedAppendFillsTheSamePlaylist() async throws {
        let (model, sp, songs) = try setUp()
        sp.addFailure = (0, offline)
        await model.createPlaylist("Late Night", provider: .spotify, adding: songs).value
        await model.lastPlaylistEdit?.value
        let first = try #require(made(sp, "Late Night").first)
        #expect(sp.catalog.playlistTracks[first.providerID]?.isEmpty ?? true)
        let retry = try #require(model.notice?.retry)
        model.dismissNotice()
        retry()
        for _ in 0..<50 where (sp.catalog.playlistTracks[first.providerID] ?? []).isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        await model.lastPlaylistEdit?.value
        #expect(made(sp, "Late Night").count == 1, "no second playlist")
        #expect(sp.catalog.playlistTracks[first.providerID]?.map(\.id) == songs.map(\.id))
    }
}
