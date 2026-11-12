import Foundation
import OpenMusicCore
import Testing
@testable import OpenMusic

/// Sol's review of 138acd6: a new playlist's songs go in batch by batch, and Try Again sends only what the service
/// hasn't acknowledged; after an answer that may or may not have landed (a timeout), it reads the playlist first and
/// sends only what is missing.
@MainActor
@Suite struct NewPlaylistFillTests {
    private func setUp() throws -> (AppModel, MockProvider, [Track]) {
        let model = AppModel(environment: ["OPENMUSIC_MOCK": "1"])
        model.noticeDuration = .seconds(30)
        let sp = try #require(model.providers.first { $0.id == .spotify } as? MockProvider)
        sp.sessionOverride = ProviderSession(generation: 0, identity: .account(id: "listener"))
        sp.editBatchSize = 100
        let songs = (0..<150).map { Track(providerID: "fill-\($0)", provider: .spotify, title: "Song \($0)") }
        return (model, sp, songs)
    }

    private func made(_ sp: MockProvider, _ title: String) throws -> Playlist {
        try #require(sp.catalog.playlists.first { $0.title == title })
    }

    private func entries(_ sp: MockProvider, _ playlist: Playlist) -> [String] {
        (sp.catalog.playlistTracks[playlist.providerID] ?? []).map(\.id)
    }

    /// Fails the `n`-th add request (1 is the first) with `error`, after appending its first `applied` songs.
    private func failAdd(_ sp: MockProvider, _ n: Int, applied: Int, _ error: ProviderError) -> () -> Int {
        var adds = 0
        sp.playlistEditGate = { kind in
            guard kind == "add" else { return }
            adds += 1
            if adds == n { sp.addFailure = (applied, error) }
        }
        return { adds }
    }

    /// 150 songs in requests of 100; the second is refused (429, nothing applied). Try Again sends only the last 50.
    @Test func tryAgainSendsOnlyTheBatchesNotAcknowledged() async throws {
        let (model, sp, songs) = try setUp()
        let adds = failAdd(sp, 2, applied: 0, .rateLimited)
        await model.createPlaylist("Fill", provider: .spotify, adding: songs).value
        await model.lastPlaylistEdit?.value
        let playlist = try made(sp, "Fill")
        #expect(entries(sp, playlist) == songs.prefix(100).map(\.id))
        let retry = try #require(model.notice?.retry)
        model.dismissNotice()
        let before = adds()
        retry()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == songs.map(\.id), "each song once")
        #expect(adds() - before == 1, "one request, for the last 50")
    }

    /// The second request times out after the service applied it. Try Again reads the playlist (uncached, whole), finds
    /// every song there and sends nothing.
    @Test func aTimeoutThatLandedIsNotSentAgain() async throws {
        let (model, sp, songs) = try setUp()
        let adds = failAdd(sp, 2, applied: 50, .network(URLError(.timedOut).localizedDescription))
        await model.createPlaylist("Landed", provider: .spotify, adding: songs).value
        await model.lastPlaylistEdit?.value
        let playlist = try made(sp, "Landed")
        #expect(entries(sp, playlist) == songs.map(\.id))
        let retry = try #require(model.notice?.retry)
        model.dismissNotice()
        let before = adds()
        let reads = sp.playlistReads.count
        retry()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == songs.map(\.id), "nothing doubled")
        #expect(adds() == before, "nothing sent")
        #expect(sp.playlistReads.dropFirst(reads).allSatisfy { $0.hasPrefix("fresh") } && sp.playlistReads.count > reads)
        #expect(model.notice?.text == "Created Landed")
    }

    /// The second request times out before the service applied it: Try Again reads the playlist and sends the 50 missing.
    @Test func aTimeoutThatDidntLandSendsWhatIsMissing() async throws {
        let (model, sp, songs) = try setUp()
        _ = failAdd(sp, 2, applied: 0, .network(URLError(.timedOut).localizedDescription))
        await model.createPlaylist("Missing", provider: .spotify, adding: songs).value
        await model.lastPlaylistEdit?.value
        let playlist = try made(sp, "Missing")
        let retry = try #require(model.notice?.retry)
        model.dismissNotice()
        retry()
        await model.lastPlaylistEdit?.value
        #expect(entries(sp, playlist) == songs.map(\.id))
    }
}
