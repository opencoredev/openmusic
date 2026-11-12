import Foundation
import MedleyCore
import Testing
@testable import Medley

@MainActor
@Suite struct FailureNoticeTests {
    private let track = Track(providerID: "t1", provider: .youtubeMusic, title: "the cure", artists: [ArtistRef(name: "Olivia Rodrigo")])

    @Test func reasonsArePlainWordsNeverTheErrorText() {
        let offline = URLError(.notConnectedToInternet).localizedDescription
        #expect(FailureReason(ProviderError.network(offline), write: true).text == "You’re offline.")
        #expect(FailureReason(URLError(.notConnectedToInternet)).text == "You’re offline.")
        #expect(FailureReason(ProviderError.network("timed out"), service: .spotify).text == "Spotify can’t be reached.")
        #expect(FailureReason(ProviderError.rateLimited).text == "Try again in a moment.")
        #expect(FailureReason(ProviderError.notSignedIn).text == "Sign in to do this.")
        let refused = FailureReason(ProviderError.server(400, "{\"error\":{\"code\":400}}"), write: true, service: .youtubeMusic)
        #expect(refused.text == "YouTube Music didn’t accept the change.")
        #expect(!refused.text.contains("400"))
        #expect(FailureReason(ProviderError.network(offline)).isRecoverable)
        #expect(FailureReason(ProviderError.rateLimited).isRecoverable)
        #expect(!FailureReason(ProviderError.notSignedIn).isRecoverable)
        #expect(!FailureReason(ProviderError.notSupported("Likes")).isRecoverable)
    }

    @Test func aFailedLikeNamesTheSongStaysAndOffersTryAgain() async throws {
        let model = AppModel(environment: ["MEDLEY_MOCK": "1"])
        let yt = try #require(model.providers.first { $0.id == .youtubeMusic } as? MockProvider)
        yt.failingWrites = .network(URLError(.notConnectedToInternet).localizedDescription)
        model.noticeDuration = .milliseconds(50)
        model.setLiked(track, liked: true)
        try await Task.sleep(for: .milliseconds(300))
        let notice = try #require(model.notice)
        #expect(notice.text == "Couldn’t like “the cure”. You’re offline.")
        #expect(notice.kind == .failure)
        #expect(notice.retry != nil)
        #expect(!model.isLiked(track))

        // Try Again asks for the same state again; with the service back it sticks.
        yt.failingWrites = nil
        model.dismissNotice()
        notice.retry?()
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.isLiked(track))
        #expect(model.notice == nil)
    }

    /// A notice clock the test advances by hand. `sleepStarted()` returns once the model is waiting on it (an awaited
    /// handshake, no polling), so `advance()` always has a sleep to end. Both waits end when their task is cancelled,
    /// also when it was cancelled before the wait began (a test past its time limit ends instead of hanging), and
    /// `finish()` ends every wait still open.
    @MainActor final class ManualClock {
        private(set) var asked: [Duration] = []
        private var sleeping: (id: Int, continuation: CheckedContinuation<Void, Never>)?
        private var started: [Int: CheckedContinuation<Void, Never>] = [:]
        private var nextID = 0
        private var finished = false

        /// Waits for `sleepStarted()` still open.
        var waitingForStart: Int { started.count }

        func sleep(_ duration: Duration) async {
            asked.append(duration)
            let id = newID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled || finished { return continuation.resume() }
                    sleeping?.continuation.resume()
                    sleeping = (id, continuation)
                    let waiting = started
                    started = [:]
                    for waiter in waiting.values { waiter.resume() }
                }
            } onCancel: {
                Task { @MainActor in self.cancel(id) }
            }
        }

        func sleepStarted() async {
            if sleeping != nil { return }
            let id = newID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled || finished { return continuation.resume() }
                    started[id] = continuation
                }
            } onCancel: {
                Task { @MainActor in self.cancel(id) }
            }
        }

        func advance() {
            sleeping?.continuation.resume()
            sleeping = nil
        }

        /// Ends every wait still open; later waits return at once.
        func finish() {
            finished = true
            advance()
            let waiting = started
            started = [:]
            for waiter in waiting.values { waiter.resume() }
        }

        private func newID() -> Int {
            nextID += 1
            return nextID
        }

        private func cancel(_ id: Int) {
            if sleeping?.id == id { advance() }
            started.removeValue(forKey: id)?.resume()
        }
    }

    /// A confirmation goes once its time is up, measured on the model's clock (here one the test advances), and not
    /// before. A failure stays.
    @Test(.timeLimit(.minutes(1))) func confirmationsGoByThemselves() async throws {
        let model = AppModel(environment: ["MEDLEY_MOCK": "1"])
        let clock = ManualClock()
        defer { clock.finish() }
        model.noticeSleep = { await clock.sleep($0) }
        model.show(.init(text: "Added to queue"))
        await clock.sleepStarted()
        #expect(clock.asked == [model.noticeDuration])
        #expect(model.notice?.text == "Added to queue", "still there until the clock says its time is up")
        clock.advance()
        await model.noticeExpiry?.value
        #expect(model.notice == nil)

        // A confirmation with a button waits longer; a failure never asks the clock.
        model.show(.init(text: "Removed", action: AppModel.NoticeAction(title: "Undo") {}))
        await clock.sleepStarted()
        #expect(clock.asked.last == model.noticeDuration * 2.5)
        clock.advance()
        await model.noticeExpiry?.value
        model.show(.init(text: "Couldn’t", kind: .failure))
        #expect(clock.asked.count == 2)
        #expect(model.notice?.kind == .failure)
    }

    /// The clock's waits end when their task is cancelled, also when it was cancelled before the wait began, and
    /// `finish()` ends the ones still open: a handshake that never arrives can't hang a test.
    @Test(.timeLimit(.minutes(1))) func aHandshakeThatNeverArrivesEndsOnCancellation() async {
        let clock = ManualClock()
        // No sleep ever starts: the wait is registered, then cancelled.
        let waiter = Task { await clock.sleepStarted() }
        for _ in 0..<1_000 where clock.waitingForStart == 0 { await Task.yield() }
        #expect(clock.waitingForStart == 1)
        waiter.cancel()
        await waiter.value
        #expect(clock.waitingForStart == 0)

        // Cancelled before the wait began (the task hasn't run yet).
        let early = Task { await clock.sleepStarted() }
        early.cancel()
        await early.value

        // A sleep cancelled while the model waits on it.
        let sleeper = Task { await clock.sleep(.seconds(1)) }
        await clock.sleepStarted()
        sleeper.cancel()
        await sleeper.value

        // Cleanup ends a wait still open.
        let pending = Task { await clock.sleepStarted() }
        for _ in 0..<1_000 where clock.waitingForStart == 0 { await Task.yield() }
        clock.finish()
        await pending.value
        #expect(clock.waitingForStart == 0)
    }
}

@MainActor
@Suite struct SidebarSelectionTests {
    @Test func aPlaylistPageHighlightsOneRow() async throws {
        let model = AppModel(environment: ["MEDLEY_MOCK": "1"])
        await model.refreshLibraryState()
        let playlist = try #require(model.sidebarPlaylists.first)
        let entry = SidebarEntry.item(.playlist(playlist))
        model.collections.recordPlayed(entry)

        // Played and under Playlists: not repeated in Recently Played, and its Recently Played tag lands on the
        // Playlists row.
        #expect(!model.sidebarRecents.contains { $0.id == entry.id })
        model.select(.collection(entry.id))
        #expect(model.sidebarSelection == .playlist(playlist.provider, playlist.providerID))

        // Pinned: every way in lands on the Pinned row.
        model.pinToSidebar(entry)
        #expect(model.sidebarSelection == .collection(entry.id))
        model.select(.playlist(playlist.provider, playlist.providerID))
        #expect(model.sidebarSelection == .collection(entry.id))

        // Unpinned again: back to the Playlists row, not a hidden Recently Played one.
        model.unpinFromSidebar(entry.id)
        #expect(model.sidebarSelection == .playlist(playlist.provider, playlist.providerID))
    }
}

@MainActor
@Suite struct LikedSongsSidebarTests {
    @Test func likedSongsPlaylistsAreOnlyInAllPlaylists() async throws {
        let model = AppModel(environment: ["MEDLEY_MOCK": "1"])
        await model.refreshLibraryState()
        let liked = try #require((model.libraryPlaylists[.youtubeMusic] ?? []).first { $0.title == "Liked Music" })
        #expect(liked.isLikedSongs)
        #expect(!model.sidebarPlaylists.contains { $0.id == liked.id })
        #expect(!model.sidebarPlaylists.isEmpty)

        // Played, it still doesn't come back as a Recently Played row: Library › Liked Songs stands for it.
        model.collections.recordPlayed(.item(.playlist(liked)))
        #expect(!model.sidebarRecents.contains { $0.id == SidebarEntry.item(.playlist(liked)).id })
    }

    @Test func likedSongsIDs() {
        #expect(Playlist(providerID: "LM", provider: .youtubeMusic, title: "Liked Music").isLikedSongs)
        #expect(Playlist(providerID: "collection", provider: .spotify, title: "Liked Songs").isLikedSongs)
        #expect(!Playlist(providerID: "LM", provider: .spotify, title: "LM").isLikedSongs)
        #expect(!Playlist(providerID: "PL123", provider: .youtubeMusic, title: "Liked Music covers").isLikedSongs)
    }

    @Test func thePlayButtonPlaysAndPausesLikedSongs() async throws {
        let model = AppModel(environment: ["MEDLEY_MOCK": "1"])
        await model.refreshLibraryState()
        model.playOrPause(AppModel.likedSongsContext) { model.playLikedSongs() }
        for _ in 0..<40 where model.player.current == nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(model.playingFrom == AppModel.likedSongsContext)
        #expect(model.isCurrentContext(AppModel.likedSongsContext))
        let liked = try await model.providers[0].library(.likedSongs, continuation: nil)
        #expect(model.player.queue.count >= liked.items.count)

        // The same button pauses and resumes in place.
        let first = model.player.current?.id
        model.playOrPause(AppModel.likedSongsContext) { Issue.record("started again") }
        #expect(!model.player.isPlaying)
        model.playOrPause(AppModel.likedSongsContext) { Issue.record("started again") }
        #expect(model.player.current?.id == first)
    }

    @Test func soleProvider() {
        #expect(ProviderID.sole([ProviderID.spotify, .spotify]) == .spotify)
        #expect(ProviderID.sole([ProviderID.spotify, .youtubeMusic]) == nil)
        #expect(ProviderID.sole([ProviderID]()) == nil)
    }
}
