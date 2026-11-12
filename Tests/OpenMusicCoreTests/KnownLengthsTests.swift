import Foundation
import Observation
import Testing
@testable import OpenMusicCore

/// Real song lengths for rows (`KnownLengths`): album, playlist, search and queue rows follow the player
/// once a song's stream has said how long it is.
@MainActor
struct KnownLengthsTests {
    func song(_ id: String = "a", listed: TimeInterval? = 346, album: Bool = true) -> Track {
        Track(providerID: id, provider: .youtubeMusic, title: "Veridis Quo", artists: [ArtistRef(name: "Daft Punk")],
              album: album ? AlbumRef(id: "MPREb_x", title: "Discovery") : nil, duration: listed)
    }

    @Test func listedLengthUntilTheStreamSaysOtherwise() {
        let store = KnownLengths()
        let t = song()
        #expect(store.displayDuration(for: t) == 346)
        store.learn(406, for: t.id)
        #expect(store.displayDuration(for: t) == 406)
    }

    @Test func listingWinsWhenTheStreamAgreesWithinTolerance() {
        let store = KnownLengths()
        let t = song(listed: 227)
        store.learn(228.4, for: t.id)
        #expect(store.displayDuration(for: t) == 227)
        #expect(store.mismatch(for: t) == nil)
    }

    @Test func streamFillsAMissingListing() {
        let store = KnownLengths()
        let t = song(listed: nil)
        #expect(store.displayDuration(for: t) == nil)
        store.learn(231, for: t.id)
        #expect(store.displayDuration(for: t) == 231)
        // Nothing listed, so nothing to explain.
        #expect(store.mismatch(for: t) == nil)
    }

    @Test func mismatchOnlyBeyondTenSeconds() {
        let store = KnownLengths()
        let near = song("near", listed: 207)
        let far = song("far", listed: 346)
        store.learn(213, for: near.id)   // 6 s: shown, not explained
        store.learn(406, for: far.id)    // 60 s: explained
        #expect(store.displayDuration(for: near) == 213)
        #expect(store.mismatch(for: near) == nil)
        let m = store.mismatch(for: far)
        #expect(m?.listed == 346)
        #expect(m?.real == 406)
    }

    @Test func ignoresInvalidLengths() {
        let store = KnownLengths()
        let t = song()
        for bad in [0, -3, .nan, .infinity] { store.learn(bad, for: t.id) }
        #expect(store.length(for: t.id) == nil)
    }

    @Test func rowsFollowOnlyTheirOwnSong() {
        let store = KnownLengths()
        let a = song("a"), b = song("b")
        final class Counter: @unchecked Sendable { var count = 0 }
        let changes = Counter()
        func observeA() {
            withObservationTracking { _ = store.length(for: a.id) } onChange: { changes.count += 1 }
        }
        observeA()
        store.learn(300, for: b.id)
        #expect(changes.count == 0)
        store.learn(406, for: a.id)
        #expect(changes.count == 1)
        observeA()
        // The same length again, or sub-second jitter from a player item refining it, isn't a change.
        store.learn(406, for: a.id)
        store.learn(406.3, for: a.id)
        #expect(changes.count == 1)
        #expect(store.length(for: a.id) == 406)
    }

    // MARK: Fed by the player

    func makePlayer() -> (PlayerController, FakeProvider) {
        let player = PlayerController(scheduler: ManualScheduler())
        let provider = FakeProvider()
        player.register(provider)
        player.autoplay = false
        return (player, provider)
    }

    @Test func streamTicksTeachTheStore() async {
        let (player, provider) = makePlayer()
        let tracks = makeTracks(2, duration: 346)
        player.play(tracks)
        await player.settle()
        provider.engine.duration = 406
        provider.engine.tick(1)
        // An album row built from the same listing shows the length the player shows.
        #expect(player.knownLengths.displayDuration(for: tracks[0]) == 406)
        #expect(player.knownLengths.displayDuration(for: tracks[0]) == player.duration)
        #expect(player.knownLengths.displayDuration(for: tracks[1]) == 346)
    }

    @Test func resolvedNextSongTeachesTheStore() async {
        let (player, provider) = makePlayer()
        let tracks = makeTracks(3, duration: 200)
        player.play(tracks)
        await player.settle()
        provider.engine.onDurationResolved?(tracks[2].id, 262)
        #expect(player.knownLengths.length(for: tracks[2].id) == 262)
    }

    @Test func listingsNeverTeachTheStore() async {
        let (player, _) = makePlayer()
        let tracks = makeTracks(2, duration: 200)
        player.play(tracks)
        await player.settle()
        // Catalog lengths fill queue entries, but the store holds only what streams said.
        #expect(player.knownLengths.length(for: tracks[1].id) == nil)
    }

    @Test func agreeingStreamIsStillRecordedFromTicks() async {
        let (player, provider) = makePlayer()
        let tracks = makeTracks(1, duration: 200)
        player.play(tracks)
        await player.settle()
        provider.engine.duration = 200.4
        provider.engine.tick(1)
        #expect(player.knownLengths.length(for: tracks[0].id) == 200.4)
        #expect(player.knownLengths.displayDuration(for: tracks[0]) == 200)
    }
}
