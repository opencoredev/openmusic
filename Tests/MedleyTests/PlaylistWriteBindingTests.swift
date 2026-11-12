import Foundation
import MedleyCore
import Testing
@testable import Medley

/// Sol's review of 48d0809: a playlist edit's requests carry the account they were checked for to where the service
/// picks their credentials, and no edit starts or recovers while a sign-in is being swapped.
@MainActor
@Suite struct PlaylistWriteBindingTests {
    private let offline = ProviderError.network(URLError(.notConnectedToInternet).localizedDescription)

    private func setUp(_ count: Int = 4) async throws -> (AppModel, MockProvider, Playlist, [Track]) {
        let model = AppModel(environment: ["MEDLEY_MOCK": "1"])
        model.noticeDuration = .seconds(30)
        let sp = try #require(model.providers.first { $0.id == .spotify } as? MockProvider)
        sp.sessionOverride = ProviderSession(generation: 0, identity: .account(id: "listener"))
        let songs = Array(sp.catalog.allTracks.prefix(count))
        let playlist = try await sp.createPlaylist(title: "Edits", description: nil)
        try await sp.add(songs, toPlaylist: playlist.providerID)
        return (model, sp, playlist, songs)
    }

    private func entries(_ sp: MockProvider, _ playlist: Playlist) -> [String] {
        (sp.catalog.playlistTracks[playlist.providerID] ?? []).map(\.id)
    }

    private func undoManager() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        return undo
    }

    private func turns(_ count: Int = 10) async throws {
        for _ in 0..<count { try await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: P1: the request carries the account

    /// An Undo checked as the listener; another account's credentials land on the service's network side before the
    /// insert goes (the main actor still says the listener). Nothing is written; the put-back stops with Try Again.
    @Test func anUndoSendsNothingOnceAnotherAccountsCredentialsLanded() async throws {
        let (model, sp, playlist, songs) = try await setUp()
        let undo = undoManager()
        await model.remove([songs[1]], from: playlist, undoManager: undo).value
        let after = entries(sp, playlist)
        sp.playlistEditGate = { kind in if kind == "insert" { sp.credentialsAccountID = "intruder" } }
        undo.undo()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == after, "nothing written with the other account's credentials")
        #expect(!sp.playlistEdits.contains { $0.hasPrefix("insert") })
        let notice = try #require(model.notice)
        #expect(notice.text.hasSuffix("Your Spotify sign-in was changing."))
        #expect(notice.retry != nil)
    }

    /// The same for a removal's requests and for Add to Playlist.
    @Test func removalsAndAddsSendNothingForAnotherAccount() async throws {
        let (model, sp, playlist, songs) = try await setUp()
        let before = entries(sp, playlist)
        sp.playlistEditGate = { _ in sp.credentialsAccountID = "intruder" }
        await model.remove([songs[1]], from: playlist, undoManager: undoManager()).value
        #expect(entries(sp, playlist) == before)
        sp.credentialsAccountID = nil
        sp.playlistEditGate = { _ in sp.credentialsAccountID = "intruder" }
        model.dismissNotice()
        await model.add([sp.catalog.allTracks[10]], to: playlist).value
        #expect(entries(sp, playlist) == before)
    }

    /// A new token for the same account while the Undo is on its way still writes.
    @Test func aSameAccountRefreshMidEditStillWrites() async throws {
        let (model, sp, playlist, songs) = try await setUp()
        let before = entries(sp, playlist)
        let undo = undoManager()
        await model.remove([songs[1]], from: playlist, undoManager: undo).value
        sp.playlistEditGate = { kind in
            guard kind == "insert" else { return }
            sp.sessionOverride = sp.session.next(.account(id: "listener"))
            sp.credentialsAccountID = "listener"
        }
        undo.undo()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == before)
    }

    // MARK: P2: nothing starts or recovers during a sign-in swap

    /// A removal asked for while the sign-in is being swapped: refused with the sign-in notice and Try Again, nothing
    /// written; Try Again once the swap settled removes the song.
    @Test func anEditAskedForDuringASwapIsRefused() async throws {
        let (model, sp, playlist, songs) = try await setUp()
        let before = entries(sp, playlist)
        let settled = sp.session
        sp.sessionOverride = settled.next(.changing)
        await model.remove([songs[1]], from: playlist, undoManager: undoManager()).value
        #expect(entries(sp, playlist) == before)
        let notice = try #require(model.notice)
        #expect(notice.text == "Couldn’t remove “\(songs[1].title)” from “Edits”. Your Spotify sign-in was changing.")
        let retry = try #require(notice.retry)
        #expect(model.canEdit(playlist))
        sp.sessionOverride = settled.next(.changing).next(.account(id: "listener"))
        try await turns()
        model.dismissNotice()
        retry()
        await model.lastPlaylistEdit?.value
        #expect(!entries(sp, playlist).contains(songs[1].id))
    }

    /// Add Back at End clicked during a swap: nothing appended, the sign-in notice with Try Again, which appends the
    /// song once the swap settled on the same account (still bound to the edit's account).
    @Test func addBackAtEndDuringASwapWaitsForIt() async throws {
        let (model, sp, playlist, songs) = try await setUp()
        let undo = undoManager()
        let song = songs[1]
        await model.remove([song], from: playlist, undoManager: undo).value
        let outsider = try #require(sp.catalog.allTracks.first { s in !songs.contains { $0.id == s.id } })
        try await sp.insert([outsider], intoPlaylist: playlist.providerID, at: 0)
        undo.undo()
        await model.lastPlaylistEdit?.value
        let changed = entries(sp, playlist)
        let addBack = try #require(model.notice?.action)
        #expect(addBack.title == "Add Back at End")

        let settled = sp.session
        sp.sessionOverride = settled.next(.changing)
        addBack.run()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == changed, "nothing appended during the swap")
        let notice = try #require(model.notice)
        #expect(notice.text == "Couldn’t add “\(song.title)” back to “Edits”. Your Spotify sign-in was changing.")
        let retry = try #require(notice.retry)

        sp.sessionOverride = settled.next(.changing).next(.account(id: "listener"))
        try await turns()
        model.dismissNotice()
        retry()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == changed + [song.id])
    }
}
