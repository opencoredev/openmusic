import Foundation
import MedleyCore
import Testing
@testable import MedleySync

/// An in-memory stand-in for the backend: devices, playback rows, queue windows and commands with acks.
@MainActor
final class FakeHub {
    var devices: [SyncDevice] = []
    var playback: [DeviceID: RemotePlayback] = [:]
    var queues: [DeviceID: QueueWindow] = [:]
    var results: [CommandID: CommandResult] = [:]
    var sent: [(from: DeviceID, to: DeviceID, command: SyncCommand)] = []
    var queuePublishes = 0
    var nodes: [DeviceID: FakeNode] = [:]
    private var nextCommand = 0

    var now: ServerMillis { Date().timeIntervalSince1970 * 1000 }

    func node(_ name: String) -> FakeNode {
        let id = DeviceID("dev-\(name)")
        devices.append(SyncDevice(id: id, name: name, platform: .mac, model: "test", appVersion: "1", createdAt: now, lastSeenAt: now))
        let node = FakeNode(hub: self, id: id)
        nodes[id] = node
        return node
    }

    func send(_ command: SyncCommand, from: DeviceID, to: DeviceID) -> CommandID {
        nextCommand += 1
        let id = CommandID(rawValue: "cmd-\(nextCommand)")
        sent.append((from, to, command))
        let incoming = IncomingCommand(id: id, fromDeviceId: from, command: command, createdAt: now, expiresAt: now + 120_000)
        Task { @MainActor in
            guard let target = self.nodes[to], let handler = target.commandHandler else { return }
            self.results[id] = await handler(incoming)
        }
        return id
    }
}

@MainActor
final class FakeNode: SyncServicing {
    let hub: FakeHub
    let id: DeviceID
    var clock = ServerClock()
    var commandHandler: (@MainActor (IncomingCommand) async -> CommandResult)?
    var playing = false

    init(hub: FakeHub, id: DeviceID) {
        self.hub = hub
        self.id = id
    }

    var selfID: DeviceID? { id }
    var devices: [SyncDevice] { hub.devices }
    var playback: [DeviceID: RemotePlayback] { hub.playback }

    /// Holds a publish in flight until it returns (a test can change the key meanwhile).
    var publishGate: (@MainActor () async -> Void)?

    func publish(anchor: PlaybackAnchor, queue: QueueWindow?) async throws {
        if let gate = publishGate { await gate() }
        if let queue {
            hub.queues[id] = queue
            hub.queuePublishes += 1
        }
        guard let window = hub.queues[id] else { throw SyncError.server("The first publish must include the queue.") }
        let version = (hub.playback[id]?.queueVersion ?? 0) + (queue == nil ? 0 : 1)
        hub.playback[id] = RemotePlayback(deviceId: id, track: window.current.track, index: window.index, queueLength: window.entries.count,
                                          queueVersion: version, anchor: anchor, updatedAt: hub.now)
    }

    func clearPlayback() async throws {
        hub.playback[id] = nil
        hub.queues[id] = nil
    }

    func fetchQueue(of device: DeviceID) async throws -> QueueWindow? { hub.queues[device] }

    func send(_ command: SyncCommand, to device: DeviceID) async throws -> CommandID {
        hub.send(command, from: id, to: device)
    }

    func waitForAck(_ command: CommandID, timeout: Duration) async throws -> CommandResult {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let result = hub.results[command] { return result }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw SyncError.timedOut("ack")
    }

    func setPlaying(_ playing: Bool) { self.playing = playing }

    /// Every fake node holds the key unless a test takes it away.
    var canSealContent = true
    var onContentKeyChange: (@MainActor () -> Void)?
}

@MainActor
func makeDevice(_ hub: FakeHub, _ name: String, providers: [ProviderID] = [.youtubeMusic, .spotify]) -> (node: FakeNode, player: PlayerController, sync: SyncCoordinator) {
    let node = hub.node(name)
    let player = PlayerController()
    for id in providers { player.register(MockProvider(id: id)) }
    let sync = SyncCoordinator(service: node, player: player)
    sync.attach()
    return (node, player, sync)
}

@MainActor
func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<600 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

@MainActor
@Suite(.serialized) struct SyncCoordinatorTests {
    let tracks = MockProvider(id: .youtubeMusic).catalog.allTracks

    @Test func publishesTheQueueOnceThenOnlyAnchors() async throws {
        let hub = FakeHub()
        let a = makeDevice(hub, "A")
        a.player.play(Array(tracks.prefix(8)), startAt: 2)
        #expect(await waitUntil { a.player.state == .playing })
        await a.sync.publishNow()
        let row = try #require(hub.playback[a.node.id])
        #expect(row.track?.id == tracks[2].id)
        #expect(row.index == 2)
        #expect(row.anchor.isPlaying)
        #expect(hub.queues[a.node.id]?.entries.count == 8)
        #expect(hub.queuePublishes == 1)

        a.player.seek(to: 77)
        await a.sync.publishNow()
        #expect(hub.queuePublishes == 1, "a seek sends only the anchor")
        #expect(abs((hub.playback[a.node.id]?.anchor.positionMs ?? 0) - 77_000) < 600)

        a.player.next()
        #expect(await waitUntil { a.player.state == .playing })
        await a.sync.publishNow()
        #expect(hub.queuePublishes == 2, "a new current entry sends the window again")
        #expect(hub.playback[a.node.id]?.track?.id == tracks[3].id)

        // The debounce publishes on its own after a change.
        a.player.pause()
        #expect(await waitUntil { hub.playback[a.node.id]?.anchor.isPlaying == false })
        #expect(a.node.playing == false)

        a.player.clearQueue()
        #expect(await waitUntil { hub.playback[a.node.id] == nil })
    }

    @Test func playHerePullsTheQueueAndPositionThenPausesTheSource() async throws {
        let hub = FakeHub()
        let a = makeDevice(hub, "A")
        let b = makeDevice(hub, "B")
        a.player.play(Array(tracks.prefix(10)), startAt: 4)
        a.player.shuffle = false
        a.player.repeatMode = .all
        #expect(await waitUntil { a.player.state == .playing })
        a.player.seek(to: 50)
        await a.sync.publishNow()

        #expect(b.sync.continueSuggestion?.device.name == "A")
        try await b.sync.playHere(from: a.node.id)

        #expect(b.player.state == .playing)
        #expect(b.player.current?.id == tracks[4].id)
        #expect(b.player.queue.map(\.uid) == a.player.queue.map(\.uid))
        #expect(b.player.repeatMode == .all)
        let report = try #require(b.sync.lastHandoff)
        #expect(report.kind == .pull)
        #expect(abs(report.positionDeltaMs ?? 9_999) < 1_000)
        #expect(abs(b.player.currentTime - (hub.playback[a.node.id]!.anchor.position(atServerTime: hub.now))) < 1.0)

        // The source got a pause command, ran it and acked.
        #expect(await waitUntil { a.player.state == .paused })
        #expect(hub.sent.last?.command == .pause)
        #expect(await waitUntil { b.sync.lastHandoff?.sourcePaused?.ok == true })
        #expect(b.sync.continueSuggestion == nil, "no banner while this device plays")
    }

    @Test func sendPushesWithTakeOverAndPausesOnceTheTargetPlays() async throws {
        let hub = FakeHub()
        let a = makeDevice(hub, "A")
        let b = makeDevice(hub, "B")
        b.player.play(Array(tracks.prefix(5)), startAt: 1)
        #expect(await waitUntil { b.player.state == .playing })
        b.player.seek(to: 30)

        try await b.sync.send(to: a.node.id)
        #expect(a.player.state == .playing)
        #expect(a.player.current?.id == tracks[1].id)
        #expect(abs(a.player.currentTime - 30) < 1.0)
        #expect(b.player.state == .paused)
        guard case .takeOver(let state) = hub.sent.last?.command else { Issue.record("expected takeOver"); return }
        #expect(state.queue.count == 5)
        #expect(b.sync.lastHandoff?.kind == .push)
    }

    /// The pause after a push handoff is a transport choice like any other (`AppModel.noteTransportChoice` on the
    /// Mac), and a takeover arriving here is a new playback choice before it replaces the queue.
    @Test func handoffsGoThroughTheRequestGate() async throws {
        let hub = FakeHub()
        let a = makeDevice(hub, "A")
        let b = makeDevice(hub, "B")
        final class Log { var lines: [String] = [] }
        let log = Log()
        b.sync.willRunTransportCommand = { log.lines.append("B transport, playing \(b.player.state == .playing)") }
        a.sync.willReplaceQueue = { log.lines.append("A replaces, queue \(a.player.queue.count)") }
        b.player.play(Array(tracks.prefix(5)), startAt: 1)
        #expect(await waitUntil { b.player.state == .playing })

        try await b.sync.send(to: a.node.id)
        #expect(a.player.queue.count == 5)
        #expect(b.player.state == .paused)
        // A's hook ran before its queue changed (still empty); B's before its pause (still playing).
        #expect(log.lines == ["A replaces, queue 0", "B transport, playing true"])
    }

    @Test func remoteControlRunsCommandsOnTheTarget() async throws {
        let hub = FakeHub()
        let a = makeDevice(hub, "A")
        let b = makeDevice(hub, "B")
        a.player.play(Array(tracks.prefix(5)))
        #expect(await waitUntil { a.player.state == .playing })

        let remote = b.sync.remote(a.node.id)
        try await remote.toggle()
        #expect(await waitUntil { a.player.state == .paused })
        try await remote.toggle()
        #expect(await waitUntil { a.player.state == .playing })
        try await remote.seek(to: 100)
        #expect(await waitUntil { abs(a.player.currentTime - 100) < 1 })
        try await remote.setVolume(0.3)
        #expect(await waitUntil { abs(a.player.volume - 0.3) < 0.001 })
        try await remote.next()
        #expect(await waitUntil { a.player.current?.id == tracks[1].id })
        #expect(hub.results.values.allSatisfy { $0.ok })
        await #expect(throws: SyncError.self) { try await b.sync.sendRemote(.takeOver(HandoffState(queue: [], index: 0, anchor: a.sync.currentAnchor())), to: a.node.id) }
    }

    /// Remote transport counts as the listener's transport choice on the target (the Mac wires it to
    /// `AppModel.noteTransportChoice`); volume and a play with nothing to play don't.
    @Test func remoteTransportRunsTheTransportHookFirst() async throws {
        let hub = FakeHub()
        let a = makeDevice(hub, "A")
        let b = makeDevice(hub, "B")
        var log: [String] = []
        a.sync.willRunTransportCommand = { log.append("hook, playing \(a.player.state == .playing)") }

        // Nothing queued yet: a remote Play fails without counting.
        let nothing = try await b.sync.sendRemote(.play, to: a.node.id)
        #expect(await waitUntil { hub.results[nothing] != nil })
        #expect(log.isEmpty)

        a.player.play(Array(tracks.prefix(5)))
        #expect(await waitUntil { a.player.state == .playing })
        let remote = b.sync.remote(a.node.id)
        try await remote.toggle()
        #expect(await waitUntil { a.player.state == .paused })
        // The hook ran before the player acted (it was still playing).
        #expect(log == ["hook, playing true"])
        try await remote.setVolume(0.4)
        #expect(await waitUntil { abs(a.player.volume - 0.4) < 0.001 })
        #expect(log.count == 1, "volume isn't a transport choice")
        try await remote.seek(to: 30)
        #expect(await waitUntil { log.count == 2 })
        try await remote.next()
        #expect(await waitUntil { log.count == 3 })
        try await remote.previous()
        #expect(await waitUntil { log.count == 4 })
        let pause = try await b.sync.sendRemote(.pause, to: a.node.id)
        #expect(await waitUntil { hub.results[pause] != nil })
        #expect(log.count == 5)
    }

    @Test func aMissingProviderIsReportedClearly() async throws {
        let hub = FakeHub()
        let a = makeDevice(hub, "A")
        let b = makeDevice(hub, "B", providers: [.youtubeMusic])
        let spotify = MockProvider(id: .spotify).catalog.allTracks
        a.player.play(Array(spotify.prefix(3)))
        #expect(await waitUntil { a.player.state == .playing })
        await a.sync.publishNow()

        await #expect(throws: SyncError.providerUnavailable(.spotify, deviceName: nil)) { try await b.sync.playHere(from: a.node.id) }
        #expect(b.sync.lastError?.localizedDescription == "Spotify isn't signed in on this device.")
        #expect(a.player.state == .playing, "the source keeps playing when the handoff fails")

        // Pushing to it fails the same way and the sender keeps playing.
        await #expect(throws: SyncError.self) { try await a.sync.send(to: b.node.id) }
        #expect(a.player.state == .playing)
        #expect(hub.results.values.first?.message == "Spotify isn't signed in on B.", "the sender sees which device lacks it")
    }

    @Test func aHandoffFailsWhenTheRequestedTrackCantLoadAndThePlayerSkipsAhead() async throws {
        let hub = FakeHub()
        let a = makeDevice(hub, "A")
        let b = makeDevice(hub, "B")
        a.player.play(Array(tracks.prefix(6)), startAt: 2)
        #expect(await waitUntil { a.player.state == .playing })
        await a.sync.publishNow()
        // On B the current track can't load, so B's player would move on to the next one.
        let engine = try #require(b.player.provider(for: .youtubeMusic)?.playbackEngine as? MockPlaybackEngine)
        engine.failingTrackIDs = [tracks[2].id]

        await #expect(throws: SyncError.self) { try await b.sync.playHere(from: a.node.id) }
        guard case .playbackFailed(let why) = b.sync.lastError else { Issue.record("lastError: \(String(describing: b.sync.lastError))"); return }
        #expect(why.contains(tracks[2].title))
        #expect(b.player.state != .playing, "B doesn't play the track it skipped to")
        #expect(a.player.state == .playing, "the source keeps playing")
        #expect(!hub.sent.contains { $0.command == .pause }, "the source is never paused")

        // Pushing to B fails the same way, and A keeps playing.
        await #expect(throws: SyncError.self) { try await a.sync.send(to: b.node.id) }
        #expect(a.player.state == .playing)
        #expect(b.player.state != .playing)
        #expect(hub.results.values.contains { $0.message?.contains(tracks[2].title) == true })
    }

    @Test func aDismissedSuggestionStaysHiddenForTheRestOfTheSong() async throws {
        let hub = FakeHub()
        let a = makeDevice(hub, "A")
        let b = makeDevice(hub, "B")
        a.player.play(Array(tracks.prefix(4)))
        #expect(await waitUntil { a.player.state == .playing })
        await a.sync.publishNow()
        #expect(b.sync.continueSuggestion?.device.name == "A")
        b.sync.dismissSuggestion()
        #expect(b.sync.continueSuggestion == nil)

        // Seeks, pauses and the periodic refresh rewrite the row (a new updatedAt) on the same track.
        try await Task.sleep(for: .milliseconds(20))
        a.player.seek(to: 40)
        await a.sync.publishNow()
        #expect(b.sync.continueSuggestion == nil, "a seek doesn't bring the banner back")
        a.player.pause()
        await a.sync.publishNow()
        try await Task.sleep(for: .milliseconds(20))
        a.player.resume()
        await a.sync.publishNow()
        #expect(b.sync.continueSuggestion == nil, "pause and resume on the same song don't bring it back")

        // Another track: offered again.
        a.player.next()
        #expect(await waitUntil { a.player.current?.id == tracks[1].id && a.player.state == .playing })
        await a.sync.publishNow()
        #expect(b.sync.continueSuggestion?.playback.track?.id == tracks[1].id)
    }

    @Test func continueSuggestionPrefersPlayingThenRecent() async throws {
        let hub = FakeHub()
        let a = makeDevice(hub, "A")
        let b = makeDevice(hub, "B")
        let c = makeDevice(hub, "C")
        #expect(c.sync.continueSuggestion == nil)

        a.player.play(Array(tracks.prefix(3)))
        #expect(await waitUntil { a.player.state == .playing })
        a.player.pause()
        await a.sync.publishNow()
        #expect(c.sync.continueSuggestion?.device.name == "A")
        #expect(c.sync.continueSuggestion?.isPlaying == false)

        b.player.play(Array(tracks.prefix(3)))
        #expect(await waitUntil { b.player.state == .playing })
        await b.sync.publishNow()
        #expect(c.sync.continueSuggestion?.device.name == "B")
        #expect(c.sync.continueSuggestion?.isPlaying == true)

        c.sync.dismissSuggestion()
        #expect(c.sync.continueSuggestion?.device.name == "A")

        // A device that went offline while playing counts as paused where it was last seen.
        b.sync.detach()
        hub.devices[1].lastSeenAt -= 120_000
        hub.playback[b.node.id]?.updatedAt -= 120_000
        let frozen = try #require(c.sync.livePosition(of: b.node.id))
        try await Task.sleep(for: .milliseconds(300))
        #expect(c.sync.livePosition(of: b.node.id) == frozen)
        #expect(c.sync.effectiveAnchor(hub.playback[b.node.id]!).isPlaying == false)

        // Paused more than 30 minutes ago: no longer suggested.
        hub.playback[a.node.id]?.updatedAt -= 31 * 60_000
        hub.playback[b.node.id]?.updatedAt -= 31 * 60_000
        #expect(c.sync.continueSuggestion == nil)
    }
}
