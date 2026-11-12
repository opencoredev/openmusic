import Foundation
import OpenMusicCore
import Observation

/// Bridges a `PlayerController` and the sync service. No UI; the same on macOS and iOS.
///
/// - Publishes local playback when it changes (debounced 300 ms) and every 20 s while playing. Nothing while paused.
/// - Runs incoming commands against the player and acks them.
/// - `playHere(from:)` pulls another device's playback here; `send(to:)` pushes this device's playback there.
/// - `remote(_:)` controls another device.
@MainActor
@Observable
public final class SyncCoordinator {
    public enum Phase: Sendable, Equatable {
        case idle
        case pulling(from: DeviceID)
        case pushing(to: DeviceID)
    }

    /// "Continue from <device>": the most recently active other device that is playing, or paused under 30 minutes ago.
    public struct ContinueSuggestion: Sendable, Equatable {
        public var device: SyncDevice
        public var playback: RemotePlayback
        public var isPlaying: Bool
    }

    /// Timings of the last handoff, for diagnostics and the probe.
    public struct HandoffReport: Sendable, Equatable {
        public enum Kind: String, Sendable { case pull, push }
        public var kind: Kind
        public var device: DeviceID
        /// Tap to queue fetched (pull) or to command sent (push), ms.
        public var fetchMs: Double
        /// Tap to the local track cued (pull) or the target's ack (push), ms.
        public var readyMs: Double
        /// Tap to playing here (pull) or paused here (push), ms.
        public var totalMs: Double
        /// Local position minus the source's extrapolated position when playback started here (pull), ms.
        public var positionDeltaMs: Double?
        /// The source acked the pause (pull). nil while waiting.
        public var sourcePaused: CommandResult?
    }

    public private(set) var phase: Phase = .idle
    public private(set) var lastError: SyncError?
    public private(set) var lastHandoff: HandoffReport?

    /// Whether a track's service can play here. Default: its provider is registered and signed in.
    @ObservationIgnored public var canPlay: @MainActor (ProviderID) -> Bool

    /// Called just before a remote command acts on the player (play, pause, next, previous, stop, seek, a takeover;
    /// not volume), as `NowPlayingCenter.willRunTransportCommand` is for the media keys: the app counts it as the
    /// listener's transport choice, so a playlist still loading to start here gives up instead of replacing what the
    /// other device just did (the Mac's `AppModel.noteTransportChoice`).
    @ObservationIgnored public var willRunTransportCommand: (@MainActor () -> Void)?
    /// Called just before a handoff replaces the player's queue (an incoming takeover, Play Here): the app makes it a
    /// new playback choice, so a playlist that was playing here stops appending its later pages into the queue that
    /// came from the other device (the Mac's `AppModel.beginPlayRequest`).
    @ObservationIgnored public var willReplaceQueue: (@MainActor () -> Void)?

    public let service: any SyncServicing
    public let player: PlayerController
    @ObservationIgnored private let scheduler: any PlaybackScheduler

    @ObservationIgnored private var changeHandler: UUID?
    @ObservationIgnored private var debounce: ScheduledAction?
    @ObservationIgnored private var refresh: ScheduledAction?
    @ObservationIgnored private var lastQueueSignature: QueueSignature?
    /// Counts changes of the key this device seals with. Part of the queue signature, so a publish that was in flight
    /// when the key changed can't mark the queue as published under the new key (its signature has the old count).
    @ObservationIgnored private var contentKeyGeneration = 0
    @ObservationIgnored private var hasPublished = false
    /// The device id the last publish went out as. Joining another library gets a new one, and the queue is sent again.
    @ObservationIgnored private var publishedAs: DeviceID?
    @ObservationIgnored private var publishing = false
    @ObservationIgnored private var publishAgain = false
    /// The suggestion the listener closed: that device, on that track (nil while its track is sealed from this device).
    /// Pauses, seeks and the 20 s refresh publishes change the row's `updatedAt` but not this, so the offer stays
    /// hidden for the rest of the song.
    private var dismissed: (device: DeviceID, track: Track.ID?)?
    @ObservationIgnored private var dismissalWatch = 0

    public static let debounceDelay: TimeInterval = 0.3
    public static let refreshInterval: TimeInterval = 20

    public init(service: any SyncServicing, player: PlayerController, scheduler: (any PlaybackScheduler)? = nil) {
        self.service = service
        self.player = player
        self.scheduler = scheduler ?? SystemScheduler()
        self.canPlay = { [weak player] id in
            guard let provider = player?.provider(for: id) else { return false }
            return provider.isSignedIn
        }
    }

    // MARK: Attach

    /// Starts publishing and obeying commands. Call once after the providers are registered with the player.
    public func attach() {
        guard changeHandler == nil else { return }
        changeHandler = player.addChangeHandler { [weak self] _ in self?.playerChanged() }
        service.commandHandler = { [weak self] command in
            guard let self else { return .failure("This device stopped syncing.") }
            return await self.execute(command)
        }
        // The key this device seals with changed (it got the key, a rotation, it lost it): publish the queue again,
        // sealed under the new key or as no content, so others never keep reading it under a retired key.
        service.onContentKeyChange = { [weak self] in
            guard let self else { return }
            self.contentKeyGeneration += 1
            self.lastQueueSignature = nil
            self.schedulePublish(after: 0)
        }
        schedulePublish(after: 0)
    }

    public func detach() {
        if let changeHandler { player.removeChangeHandler(changeHandler) }
        changeHandler = nil
        service.commandHandler = nil
        service.onContentKeyChange = nil
        debounce?.cancel()
        refresh?.cancel()
    }

    private func playerChanged() {
        service.setPlaying(player.isPlaying)
        schedulePublish(after: Self.debounceDelay)
    }

    // MARK: Publishing

    private func schedulePublish(after delay: TimeInterval) {
        debounce?.cancel()
        debounce = scheduler.schedule(after: delay) { [weak self] in
            Task { await self?.publishNow() }
        }
    }

    /// The local anchor now: engine time while it plays, the player's otherwise.
    public func currentAnchor() -> PlaybackAnchor {
        let engineTime: TimeInterval? = switch player.state {
        case .playing, .buffering: player.current.flatMap { player.provider(for: $0.provider)?.playbackEngine.currentTime }
        default: nil
        }
        return PlaybackAnchor(
            positionMs: (engineTime ?? player.currentTime) * 1000,
            positionAt: service.clock.now(),
            isPlaying: player.state == .playing,
            durationMs: player.duration.map { $0 * 1000 },
            volume: Double(player.volume),
            shuffle: player.shuffle,
            repeat: player.repeatMode
        )
    }

    /// Publishes now (the debounce and the 20 s refresh call this). Sends the queue window only when it changed.
    func publishNow() async {
        guard let me = service.selfID else { return }
        if publishing { publishAgain = true; return }
        // Every service call is bounded (mutations time out), so this always resets.
        publishing = true
        defer { publishing = false }
        if publishedAs != me {
            publishedAs = me
            lastQueueSignature = nil
            hasPublished = false
        }
        var playing = false
        repeat {
            publishAgain = false
            guard let window = QueueWindow(queue: player.queue, current: player.currentIndex) else {
                if hasPublished {
                    do { try await service.clearPlayback(); hasPublished = false; lastQueueSignature = nil } catch { lastError = SyncError.from(error) }
                }
                playing = false
                continue
            }
            let signature = QueueSignature(uids: window.entries.map(\.uid), index: window.index, keyGeneration: contentKeyGeneration)
            let includeQueue = signature != lastQueueSignature
            let anchor = currentAnchor()
            playing = anchor.isPlaying
            do {
                try await service.publish(anchor: anchor, queue: includeQueue ? window : nil)
                lastQueueSignature = signature
                hasPublished = true
            } catch {
                lastError = SyncError.from(error)
                lastQueueSignature = nil
            }
        } while publishAgain
        refresh?.cancel()
        refresh = nil
        if playing {
            refresh = scheduler.schedule(after: Self.refreshInterval) { [weak self] in
                Task { await self?.publishNow() }
            }
        }
    }

    // MARK: Incoming commands

    func execute(_ incoming: IncomingCommand) async -> CommandResult {
        defer { schedulePublish(after: 0) }
        let transport = willRunTransportCommand ?? {}
        switch incoming.command {
        case .play:
            guard player.currentEntry != nil || !player.queue.isEmpty else { return CommandResult(ok: false, reason: .nothingToPlay) }
            transport()
            player.resume()
        case .pause: transport(); player.pause()
        case .toggle: transport(); player.togglePlayPause()
        case .next: transport(); player.next()
        case .previous: transport(); player.previous()
        case .stop: transport(); player.stop()
        case .seek(let ms): transport(); player.seek(to: max(0, ms / 1000))
        case .setVolume(let volume): player.volume = Float(max(0, min(1, volume)))
        case .takeOver(let state):
            transport()
            do {
                // Name this device in the message: the sender shows it.
                _ = try await adopt(state, deviceName: service.devices.first { $0.id == service.selfID }?.name)
            } catch {
                let failure = SyncError.from(error)
                lastError = failure
                // The message may name the song: the service sends it sealed, and the reason in the clear.
                return .failure(failure.localizedDescription, reason: Self.reason(for: failure))
            }
        }
        return .success
    }

    static func reason(for error: SyncError) -> CommandFailure {
        switch error {
        case .providerUnavailable: .providerUnavailable
        case .playbackFailed: .playbackFailed
        case .needsKey: .needsKey
        case .nothingPlaying: .nothingToPlay
        default: .failed
        }
    }

    // MARK: Handoff

    /// Loads `state` here and starts playing at its live position. Returns (cued, playing) times.
    private func adopt(_ state: HandoffState, deviceName: String? = nil) async throws -> (ready: Date, playing: Date) {
        guard state.queue.indices.contains(state.index) else { throw SyncError.playbackFailed("the queue is empty") }
        let target = state.queue[state.index]
        guard canPlay(target.track.provider) else { throw SyncError.providerUnavailable(target.track.provider, deviceName: deviceName) }

        let cueAt = state.anchor.position(atServerTime: service.clock.now())
        willReplaceQueue?()
        player.load(state.queue, at: state.index, position: cueAt, shuffle: state.anchor.shuffle,
                    repeatMode: state.anchor.repeat, autoplay: false)
        let isTarget: @MainActor (PlayerController) -> Bool = { $0.currentEntry?.uid == target.uid }
        let cued = await waitForPlayer(timeout: 20) { $0.state != .loading || !isTarget($0) }
        guard cued, player.state != .failed else {
            throw SyncError.playbackFailed(player.lastError ?? "the track didn't load in time")
        }
        // The requested track failed and the player moved on to another one: that isn't a handoff.
        guard isTarget(player) else { throw wrongTrack(target, deviceName: deviceName) }
        let ready = Date()
        // Stream resolution took time; catch up to where the source is now.
        player.seek(to: state.anchor.position(atServerTime: service.clock.now()))
        player.resume()
        guard await waitForPlayer(timeout: 15, { $0.state == .playing || !isTarget($0) }) else {
            throw SyncError.playbackFailed(player.lastError ?? "playback didn't start")
        }
        guard isTarget(player) else { throw wrongTrack(target, deviceName: deviceName) }
        return (ready, Date())
    }

    /// Stops whatever the player skipped to and names the track that couldn't play.
    private func wrongTrack(_ target: QueueEntry, deviceName: String?) -> SyncError {
        willRunTransportCommand?()
        player.pause()
        let place = deviceName.map { "on \($0)" } ?? "here"
        let why = player.lastError.map { " (\($0))" } ?? ""
        return .playbackFailed("\"\(target.track.title)\" couldn't be loaded \(place)\(why).")
    }

    /// Pull handoff: continues `source`'s queue here at its live position, then pauses `source`.
    public func playHere(from source: DeviceID) async throws {
        guard phase == .idle else { return }
        guard let device = service.devices.first(where: { $0.id == source }) else { throw fail(.unknownDevice) }
        phase = .pulling(from: source)
        defer { phase = .idle }
        let start = Date()
        do {
            guard service.playback[source] != nil else { throw SyncError.nothingPlaying(device.name) }
            // What plays there is sealed with the account's key: without it this device can't know what to play.
            guard service.canSealContent else { throw SyncError.needsKey(device: nil) }
            var window = try await service.fetchQueue(of: source)
            // The live row can move on while the queue loads; refetch once if they disagree.
            if let w = window, let row = service.playback[source], row.track?.id != w.current.track.id {
                window = try await service.fetchQueue(of: source)
            }
            guard let window, let row = service.playback[source] else { throw SyncError.nothingPlaying(device.name) }
            let fetched = Date()
            let provider = window.current.track.provider
            guard canPlay(provider) else { throw SyncError.providerUnavailable(provider, deviceName: nil) }

            let times = try await adopt(HandoffState(window: window, anchor: effectiveAnchor(row)))
            let local = currentAnchor().position(atServerTime: service.clock.now())
            let sourceNow = effectiveAnchor(service.playback[source] ?? row).position(atServerTime: service.clock.now())
            let report = HandoffReport(kind: .pull, device: source, fetchMs: ms(fetched, start), readyMs: ms(times.ready, start),
                                       totalMs: ms(times.playing, start), positionDeltaMs: (local - sourceNow) * 1000, sourcePaused: nil)
            lastHandoff = report
            lastError = nil
            let pause = try await service.send(.pause, to: source)
            Task { [weak self] in
                let result = (try? await self?.service.waitForAck(pause, timeout: .seconds(20))) ?? .failure("no ack")
                guard let self, self.lastHandoff == report else { return }
                var acked = report
                acked.sourcePaused = result
                self.lastHandoff = acked
            }
        } catch {
            throw fail(SyncError.from(error))
        }
    }

    /// Push handoff: sends this device's playback to `target` with `takeOver` and pauses here once it plays there.
    public func send(to target: DeviceID) async throws {
        guard phase == .idle else { return }
        guard let device = service.devices.first(where: { $0.id == target }) else { throw fail(.unknownDevice) }
        guard device.isOnline(serverNow: service.clock.now()) else { throw fail(.deviceOffline(device.name)) }
        // The queue goes sealed with the account's key: both devices need it.
        guard service.canSealContent else { throw fail(.needsKey(device: nil)) }
        guard device.keyState == nil || device.keyState == .holder else { throw fail(.needsKey(device: device.name)) }
        guard let window = QueueWindow(queue: player.queue, current: player.currentIndex) else {
            throw fail(.nothingPlaying("this device"))
        }
        phase = .pushing(to: target)
        defer { phase = .idle }
        let start = Date()
        do {
            let command = try await service.send(.takeOver(HandoffState(window: window, anchor: currentAnchor())), to: target)
            let sent = Date()
            let result = try await service.waitForAck(command, timeout: .seconds(30))
            let acked = Date()
            guard result.ok else { throw SyncError.commandFailed(result.message ?? "\(device.name) couldn't take over.") }
            // A transport choice like any other Pause: a playlist still loading to start here gives up.
            willRunTransportCommand?()
            player.pause()
            lastHandoff = HandoffReport(kind: .push, device: target, fetchMs: ms(sent, start), readyMs: ms(acked, start),
                                        totalMs: ms(Date(), start), positionDeltaMs: nil, sourcePaused: nil)
            lastError = nil
        } catch {
            throw fail(SyncError.from(error))
        }
    }

    // MARK: Remote control

    /// Controls another device: play, pause, toggle, next, previous, seek, volume, stop.
    public func remote(_ device: DeviceID) -> RemoteControl { RemoteControl(coordinator: self, device: device) }

    @discardableResult
    func sendRemote(_ command: SyncCommand, to device: DeviceID) async throws -> CommandID {
        if case .takeOver = command { throw fail(.commandFailed("Use send(to:) to move playback.")) }
        guard service.devices.contains(where: { $0.id == device }) else { throw fail(.unknownDevice) }
        do { return try await service.send(command, to: device) } catch { throw fail(SyncError.from(error)) }
    }

    // MARK: Continue suggestion

    public var continueSuggestion: ContinueSuggestion? {
        guard let me = service.selfID, !player.isPlaying else { return nil }
        let now = service.clock.now()
        let devices = Dictionary(service.devices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let candidates = service.playback.values.compactMap { row -> ContinueSuggestion? in
            guard row.deviceId != me, let device = devices[row.deviceId] else { return nil }
            if let dismissed, dismissed.device == row.deviceId, dismissed.track == row.track?.id { return nil }
            let playing = row.anchor.isPlaying && device.isOnline(serverNow: now)
            guard playing || now - row.updatedAt < SyncLimits.continueWindow * 1000 else { return nil }
            return ContinueSuggestion(device: device, playback: row, isPlaying: playing)
        }
        return candidates.max { a, b in
            (a.isPlaying ? 1 : 0, a.playback.updatedAt) < (b.isPlaying ? 1 : 0, b.playback.updatedAt)
        }
    }

    /// Hides the current suggestion until that device plays another track (or clears its playback). Coming back to
    /// the same track later offers it again.
    public func dismissSuggestion() {
        guard let s = continueSuggestion else { return }
        dismissed = (s.device.id, s.playback.track?.id)
        dismissalWatch += 1
        watchDismissal(dismissalWatch)
    }

    /// Forgets the dismissal once the dismissed device's row shows another track or none.
    private func watchDismissal(_ generation: Int) {
        guard generation == dismissalWatch, let d = dismissed else { return }
        let track = withObservationTracking {
            service.playback[d.device].map { $0.track?.id }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.watchDismissal(generation) }
        }
        if track != d.track { dismissed = nil }
    }

    /// Live position (seconds) of another device.
    public func livePosition(of device: DeviceID) -> TimeInterval? {
        service.playback[device].map { effectiveAnchor($0).position(atServerTime: service.clock.now()) }
    }

    /// A row's anchor, except that a device that went offline while playing is taken as paused where it was
    /// last seen (its app was closed or lost the network; it isn't still advancing).
    public func effectiveAnchor(_ row: RemotePlayback) -> PlaybackAnchor {
        let now = service.clock.now()
        guard row.anchor.isPlaying, let device = service.devices.first(where: { $0.id == row.deviceId }),
              !device.isOnline(serverNow: now) else { return row.anchor }
        var anchor = row.anchor
        let lastSeen = max(device.lastSeenAt, row.updatedAt)
        anchor.positionMs = anchor.position(atServerTime: lastSeen) * 1000
        anchor.positionAt = lastSeen
        anchor.isPlaying = false
        return anchor
    }

    // MARK: Helpers

    private func fail(_ error: SyncError) -> SyncError {
        lastError = error
        return error
    }

    private func ms(_ a: Date, _ b: Date) -> Double { (a.timeIntervalSince(b) * 1000).rounded() }

    private func waitForPlayer(timeout: TimeInterval, _ condition: @escaping @MainActor (PlayerController) -> Bool) async -> Bool {
        if condition(player) { return true }
        let waiter = PlayerWaiter()
        return await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            waiter.handler = player.addChangeHandler { [weak self, waiter] _ in
                guard let self, condition(self.player) else { return }
                waiter.finish(true, player: self.player)
            }
            waiter.timer = Task { [weak self, waiter] in
                try? await Task.sleep(for: .seconds(timeout))
                waiter.finish(false, player: self?.player)
            }
        }
    }
}

/// Which entries the last published queue window held, and where the current one was.
private struct QueueSignature: Equatable {
    var uids: [UUID]
    var index: Int
    /// The sealing key it was published under (`contentKeyGeneration`).
    var keyGeneration: Int
}

@MainActor
private final class PlayerWaiter {
    var continuation: CheckedContinuation<Bool, Never>?
    var handler: UUID?
    var timer: Task<Void, Never>?

    func finish(_ value: Bool, player: PlayerController?) {
        guard let continuation else { return }
        self.continuation = nil
        if let handler { player?.removeChangeHandler(handler) }
        timer?.cancel()
        continuation.resume(returning: value)
    }
}

/// Controls one other device. Each call sends a command and returns its id; `SyncService.waitForAck` waits for it.
@MainActor
public struct RemoteControl {
    let coordinator: SyncCoordinator
    public let device: DeviceID

    @discardableResult public func play() async throws -> CommandID { try await coordinator.sendRemote(.play, to: device) }
    @discardableResult public func pause() async throws -> CommandID { try await coordinator.sendRemote(.pause, to: device) }
    @discardableResult public func toggle() async throws -> CommandID { try await coordinator.sendRemote(.toggle, to: device) }
    @discardableResult public func next() async throws -> CommandID { try await coordinator.sendRemote(.next, to: device) }
    @discardableResult public func previous() async throws -> CommandID { try await coordinator.sendRemote(.previous, to: device) }
    @discardableResult public func stop() async throws -> CommandID { try await coordinator.sendRemote(.stop, to: device) }
    @discardableResult public func seek(to seconds: TimeInterval) async throws -> CommandID {
        try await coordinator.sendRemote(.seek(positionMs: max(0, seconds) * 1000), to: device)
    }
    /// 0...1
    @discardableResult public func setVolume(_ volume: Double) async throws -> CommandID {
        try await coordinator.sendRemote(.setVolume(max(0, min(1, volume))), to: device)
    }
}
