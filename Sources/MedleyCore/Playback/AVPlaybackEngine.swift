import AVFoundation
import Foundation

/// One AVPlayer plus what the engine knows about the item in it.
@MainActor
private final class Slot {
    let player = AVPlayer()
    var track: Track?
    var stream: PlayableStream?
    /// Linear loudness-normalization gain for this item.
    var gain: Float = 1
    /// Crossfade multiplier, 0...1.
    var fade: Float = 1
    /// Re-resolves spent on the current track.
    var recoveries = 0
    /// Last position known to have played, used to resume after a re-resolve.
    var lastGoodTime: TimeInterval = 0
    var itemObservers: [NSObjectProtocol] = []
    var statusObservation: NSKeyValueObservation?
    var timeControlObservation: NSKeyValueObservation?

    var item: AVPlayerItem? { player.currentItem }
    var isUsable: Bool { track != nil && item != nil && item?.status != .failed }

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .pause
    }

    func detachItemObservers() {
        for observer in itemObservers { NotificationCenter.default.removeObserver(observer) }
        itemObservers = []
        statusObservation?.invalidate()
        statusObservation = nil
    }

    func clear() {
        detachItemObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        track = nil
        stream = nil
        gain = 1
        fade = 1
        recoveries = 0
        lastGoodTime = 0
    }
}

/// Plays direct stream URLs with AVPlayer. Used by providers that implement `StreamResolver`.
///
/// - Two players: the active one, and a standby that holds the next track (resolved by `prepareNext`
///   and buffered in the last `preloadLead` seconds), so the handoff at the end of a track is near-gapless.
///   With `crossfadeDuration > 0` the standby starts early and the two overlap.
/// - When a stream fails (item failure, HTTP 403/410 in the error log, a stall that doesn't clear, or an
///   `expiresAt` in the past on resume), the track is re-resolved and resumed at the last good position.
/// - The periodic time observer is attached only while the active player is playing or buffering,
///   so a paused or idle engine schedules no work at all.
@MainActor
public final class AVPlaybackEngine: PlaybackEngine, ConfigurableAudioEngine, DurationReportingEngine {
    public var onEvent: (@MainActor (PlaybackEvent) -> Void)?
    public var onDurationResolved: (@MainActor (_ trackID: String, _ seconds: TimeInterval) -> Void)?

    /// A command a caller gave the engine, as opposed to AVPlayer pausing on its own (an interruption, a stall).
    enum TransportCommand: Equatable { case play, pause, stop }
    /// Called before the engine acts on `play()`, `pause()`, `stop()` and `load` (play or cue). `AudioSessionController`
    /// uses it to activate the session before audio starts and to tell an explicit pause from an interruption.
    var onTransportCommand: (@MainActor (TransportCommand) -> Void)?

    /// 0...1
    public var volume: Float {
        get { userVolume }
        set { userVolume = max(0, min(1, newValue)); applyVolumes() }
    }

    public var normalizationEnabled = true { didSet { applyVolumes() } }

    /// Overlap between tracks, 0...12 s. 0 disables crossfade (tracks still hand off without a reload gap).
    public var crossfadeDuration: TimeInterval {
        get { crossfadeSeconds }
        set { crossfadeSeconds = max(0, min(12, newValue)) }
    }

    /// macOS only. iOS routes audio through `AVAudioSession` (AirPlay, Bluetooth), so this is ignored there.
    public var outputDeviceUID: String? {
        didSet {
            guard outputDeviceUID != oldValue else { return }
            #if os(macOS)
            for slot in slots { slot.player.audioOutputDeviceUniqueID = outputDeviceUID }
            #endif
        }
    }

    /// Loudness target. YouTube's `loudnessDb` is relative to this reference, so gain = -loudnessDB.
    public static let targetLUFS: Double = -14
    /// Gain limits for normalization, in dB.
    public static let maxCutDB: Double = 12
    public static let maxBoostDB: Double = 6

    // Tunables (internal so tests can shorten them).
    var maxRecoveryAttempts = 3
    var stallTimeout: TimeInterval = 12
    var preloadLead: TimeInterval = 30
    var timeInterval: TimeInterval = 0.5

    private let resolver: any StreamResolver
    private var userVolume: Float = 1
    private var crossfadeSeconds: TimeInterval = 0

    private var active: Slot
    /// Free player for the next track. nil while a crossfade is using it.
    private var standby: Slot?
    /// The outgoing player during a crossfade.
    private var fading: Slot?
    private var slots: [Slot] { [active, standby, fading].compactMap { $0 } }

    private var wantsToPlay = false
    private var loadGeneration = 0
    private var isLoading = false
    private var failureDuringLoad: String?
    private var isRecovering = false
    /// Set once the engine gave up on the current item, so late AVPlayer callbacks don't overwrite `.failed`.
    private var hasFailed = false
    private var recoveryTask: Task<Void, Never>?
    /// Set when the engine started the next track by itself (end-of-track handoff or crossfade);
    /// the controller's following `load` of that track adopts it instead of reloading.
    private var handedOffTrackID: String?

    private var nextTrack: Track?
    private var preparedStream: (trackID: String, stream: PlayableStream)?
    private var prepareTask: Task<Void, Never>?

    private var timeObserver: Any?
    private var timeObserverPlayer: AVPlayer?
    private var stallTask: Task<Void, Never>?
    private var fadeTimer: Timer?
    private var fadeStart = Date()
    private var fadeLength: TimeInterval = 0

    // Diagnostics for tests and the probe.
    private(set) var resolveCount = 0
    private(set) var recoveryCount = 0
    private(set) var mediaResetCount = 0
    var activePlayer: AVPlayer { active.player }
    var isTimeObserverAttached: Bool { timeObserver != nil }
    var standbyTrackID: String? { standby?.track?.id }
    var isCrossfading: Bool { fading != nil }
    var activeGain: Float { active.gain }

    public init(resolver: any StreamResolver) {
        self.resolver = resolver
        active = Slot()
        standby = Slot()
        observeTimeControl(of: active)
        if let standby { observeTimeControl(of: standby) }
    }

    // MARK: PlaybackEngine

    public var currentTime: TimeInterval {
        if isRecovering { return active.lastGoodTime }
        let t = active.player.currentTime().seconds
        return t.isFinite ? max(0, t) : 0
    }

    public var duration: TimeInterval? { duration(of: active) }

    /// Throws `CancellationError` when the caller was cancelled or a later `load`/`stop` superseded it,
    /// so a stale load never starts audio. A cancelled caller doesn't bump the generation either, which
    /// would cancel the load that replaced it.
    public func load(_ track: Track, startAt: TimeInterval, autoplay: Bool) async throws {
        try Task.checkCancellation()
        onTransportCommand?(autoplay ? .play : .pause)
        loadGeneration += 1
        let generation = loadGeneration
        func ensureCurrent() throws {
            guard generation == loadGeneration, !Task.isCancelled else {
                if generation == loadGeneration { isLoading = false }
                throw CancellationError()
            }
        }
        cancelStallWatch()
        recoveryTask?.cancel()
        isRecovering = false

        // The engine already started this track at the end of the previous one.
        if let handed = handedOffTrackID, handed == track.id, active.track?.id == track.id, startAt == 0 {
            handedOffTrackID = nil
            wantsToPlay = autoplay
            if autoplay {
                if active.player.timeControlStatus == .paused { active.player.play() }
                emitCurrentState()
            } else {
                finishFade()
                active.player.pause()
                emit(.state(.paused))
            }
            return
        }

        handedOffTrackID = nil
        hasFailed = false
        finishFade()
        isLoading = true
        failureDuringLoad = nil
        wantsToPlay = autoplay
        emit(.state(.loading))
        active.player.pause()
        updateTimeObserver()

        if let standby, standby.track?.id == track.id, standby.isUsable, !Self.isExpired(standby.stream) {
            let old = active
            active = standby
            self.standby = old
            old.clear()
            if nextTrack?.id == track.id { nextTrack = nil }
        } else {
            let stream: PlayableStream
            if let prepared = preparedStream, prepared.trackID == track.id, !Self.isExpired(prepared.stream) {
                stream = prepared.stream
                preparedStream = nil
            } else {
                do {
                    stream = try await resolve(track)
                } catch {
                    if generation == loadGeneration { isLoading = false }
                    throw error
                }
            }
            try ensureCurrent()
            install(stream, for: track, into: active)
        }
        active.recoveries = 0
        active.lastGoodTime = startAt

        if startAt > 0 {
            await active.player.seek(to: Self.cmTime(startAt), toleranceBefore: .zero, toleranceAfter: .zero)
            try ensureCurrent()
        }
        isLoading = false
        applyVolumes()

        if let failure = failureDuringLoad {
            failureDuringLoad = nil
            recover(reason: failure)
        } else if wantsToPlay {
            active.player.play()
            emitCurrentState()
        } else {
            emit(.state(.paused))
        }
    }

    public func play() {
        onTransportCommand?(.play)
        wantsToPlay = true
        guard active.item != nil, !isLoading, !isRecovering else { return }
        if active.item?.status == .failed {
            recover(reason: active.item?.error?.localizedDescription ?? "Playback failed")
        } else if Self.isExpired(active.stream) {
            // Resuming after a long pause: the URL is stale, fetch a fresh one before AVPlayer hits a 403.
            recover(reason: "Stream expired", countsAsFailure: false)
        } else {
            active.player.play()
        }
    }

    public func pause() {
        onTransportCommand?(.pause)
        wantsToPlay = false
        finishFade()
        cancelStallWatch()
        active.player.pause()
        if isLoading || isRecovering { emit(.state(.paused)) }
    }

    public func stop() {
        onTransportCommand?(.stop)
        loadGeneration += 1
        hasFailed = false
        wantsToPlay = false
        isLoading = false
        isRecovering = false
        recoveryTask?.cancel()
        prepareTask?.cancel()
        prepareTask = nil
        cancelStallWatch()
        finishFade()
        active.clear()
        standby?.clear()
        nextTrack = nil
        preparedStream = nil
        handedOffTrackID = nil
        updateTimeObserver()
        emit(.state(.idle))
    }

    public func seek(to seconds: TimeInterval) {
        finishFade()
        let target = max(0, seconds)
        active.lastGoodTime = target
        guard !isLoading, !isRecovering else { return }
        active.player.seek(to: Self.cmTime(target), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func prepareNext(_ track: Track?) {
        if track?.id == nextTrack?.id {
            guard let track else { return }
            if preparedStream?.trackID == track.id || standby?.track?.id == track.id || prepareTask != nil { return }
        }
        nextTrack = track
        prepareTask?.cancel()
        prepareTask = nil
        if preparedStream?.trackID != track?.id { preparedStream = nil }
        if let standby, standby.track != nil, standby.track?.id != track?.id { standby.clear() }
        guard let track, standby?.track?.id != track.id else { return }

        prepareTask = Task { [weak self] in
            guard let self else { return }
            let stream = try? await self.resolve(track)
            guard !Task.isCancelled, self.nextTrack?.id == track.id else { return }
            self.prepareTask = nil
            if let stream {
                self.preparedStream = (track.id, stream)
                self.maybePreloadStandby()
            }
        }
    }

    // MARK: Loudness

    /// Linear gain for a YouTube-style loudness value (dB above the -14 LUFS reference), clamped.
    public static func gain(forLoudnessDB loudness: Double?) -> Float {
        guard let loudness, loudness.isFinite else { return 1 }
        let db = min(maxBoostDB, max(-maxCutDB, -loudness))
        return Float(pow(10, db / 20))
    }

    private func applyVolumes() {
        for slot in slots {
            let gain = normalizationEnabled ? slot.gain : 1
            slot.player.volume = max(0, min(1, userVolume * gain * slot.fade))
        }
    }

    // MARK: Items

    private func resolve(_ track: Track, forceRefresh: Bool = false) async throws -> PlayableStream {
        resolveCount += 1
        let stream = try await resolver.resolveStream(for: track, forceRefresh: forceRefresh)
        // The current song's length shows before the item reports one; the next song's fills its queue row.
        if let seconds = stream.duration { onDurationResolved?(track.id, seconds) }
        return stream
    }

    private func duration(of slot: Slot) -> TimeInterval? {
        Self.playableDuration(reported: slot.item?.duration.seconds, expected: slot.stream?.duration ?? slot.track?.duration)
    }

    /// AVFoundation reports twice the real length for YouTube's fragmented MP4 audio (it adds the `mvhd`
    /// duration to the fragments'). When the reported length is far above the expected one (the service's
    /// length for the stream, else the catalog's), trust the expected one.
    static func playableDuration(reported: Double?, expected: TimeInterval?) -> TimeInterval? {
        guard let reported, reported.isFinite, reported > 0 else { return nil }
        if let expected, expected > 0, reported > expected * 1.5 { return expected }
        return reported
    }

    private func install(_ stream: PlayableStream, for track: Track, into slot: Slot) {
        slot.detachItemObservers()
        var options: [String: Any] = [:]
        if !stream.httpHeaders.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = stream.httpHeaders
        }
        let asset = AVURLAsset(url: stream.url, options: options)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 30
        slot.track = track
        slot.stream = stream
        slot.gain = Self.gain(forLoudnessDB: stream.loudnessDB)
        slot.fade = 1
        observe(item, in: slot)
        #if os(macOS)
        if slot.player.audioOutputDeviceUniqueID != outputDeviceUID {
            slot.player.audioOutputDeviceUniqueID = outputDeviceUID
        }
        #endif
        slot.player.replaceCurrentItem(with: item)
        applyVolumes()
    }

    private func observe(_ item: AVPlayerItem, in slot: Slot) {
        let center = NotificationCenter.default
        slot.itemObservers = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self, weak slot, weak item] _ in
                MainActor.assumeIsolated {
                    guard let self, let slot, let item, slot.item === item else { return }
                    self.itemEnded(slot)
                }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self, weak slot, weak item] note in
                let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "Playback failed"
                MainActor.assumeIsolated {
                    guard let self, let slot, let item, slot.item === item else { return }
                    self.itemFailed(slot, message: message)
                }
            },
            center.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: item, queue: .main) { [weak self, weak slot, weak item] _ in
                MainActor.assumeIsolated {
                    guard let self, let slot, let item, slot.item === item else { return }
                    // An expired or revoked URL shows up as HTTP 403/410; AVPlayer would otherwise retry and stall.
                    guard let code = item.errorLog()?.events.last?.errorStatusCode, code == 403 || code == 410 else { return }
                    self.itemFailed(slot, message: "HTTP \(code)")
                }
            },
        ]
        slot.statusObservation = item.observe(\.status, options: [.new]) { [weak self, weak slot] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription ?? "Playback failed"
            let itemID = ObjectIdentifier(item)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let slot, let current = slot.item, ObjectIdentifier(current) == itemID else { return }
                    if status == .failed { self.itemFailed(slot, message: message) }
                    if status == .readyToPlay, slot === self.standby { self.applyVolumes() }
                }
            }
        }
    }

    private func observeTimeControl(of slot: Slot) {
        slot.timeControlObservation = slot.player.observe(\.timeControlStatus, options: [.new]) { [weak self, weak slot] player, _ in
            let status = player.timeControlStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let slot, slot === self.active else { return }
                    self.timeControlChanged(status)
                }
            }
        }
    }

    private func timeControlChanged(_ status: AVPlayer.TimeControlStatus) {
        // Read the live status: the KVO hop to the main queue can arrive after it changed again.
        _ = status
        let status = active.player.timeControlStatus
        updateTimeObserver()
        guard !isLoading, !isRecovering, !hasFailed else { return }
        switch status {
        case .playing:
            cancelStallWatch()
            emit(.state(.playing))
        case .waitingToPlayAtSpecifiedRate:
            guard active.item != nil else { return }
            emit(.state(.buffering))
            startStallWatch()
        case .paused:
            cancelStallWatch()
            guard active.item != nil else { return }
            if wantsToPlay {
                // AVPlayer pauses itself at the end of an item; the end notification handles that.
                if isNearEnd(active) || active.item?.status == .failed { return }
                wantsToPlay = false
            }
            emit(.state(.paused))
        @unknown default:
            break
        }
    }

    private func emitCurrentState() {
        switch active.player.timeControlStatus {
        case .playing: emit(.state(.playing))
        case .waitingToPlayAtSpecifiedRate: emit(.state(.buffering))
        case .paused: emit(.state(wantsToPlay ? .buffering : .paused))
        @unknown default: break
        }
    }

    private func isNearEnd(_ slot: Slot) -> Bool {
        guard let d = duration(of: slot) else { return false }
        let t = slot.player.currentTime().seconds
        return t.isFinite && t >= d - 1
    }

    // MARK: End of track

    private func itemEnded(_ slot: Slot) {
        if slot === fading { finishFade(); return }
        guard slot === active else { return }
        cancelStallWatch()
        if wantsToPlay, let standby, let next = nextTrack, standby.track?.id == next.id, standby.isUsable {
            // Near-gapless: the next item is already buffered in the standby player.
            let old = active
            active = standby
            self.standby = old
            old.clear()
            active.fade = 1
            active.recoveries = 0
            applyVolumes()
            active.player.play()
            handedOffTrackID = next.id
            nextTrack = nil
            updateTimeObserver()
            emit(.finished)
        } else {
            emit(.state(.ended))
            emit(.finished)
        }
    }

    private func maybePreloadStandby() {
        guard let next = nextTrack, let standby, standby.track == nil,
              let prepared = preparedStream, prepared.trackID == next.id, !Self.isExpired(prepared.stream),
              let d = duration else { return }
        let remaining = d - currentTime
        guard remaining <= max(preloadLead, crossfadeSeconds + 10) else { return }
        preparedStream = nil
        install(prepared.stream, for: next, into: standby)
    }

    private func maybeStartCrossfade() {
        guard crossfadeSeconds > 0, fading == nil, wantsToPlay, !isLoading, !isRecovering,
              let standby, let next = nextTrack, standby.track?.id == next.id,
              standby.item?.status == .readyToPlay,
              let d = duration, d > crossfadeSeconds * 2 else { return }
        let remaining = d - currentTime
        guard remaining <= crossfadeSeconds, remaining > 0.25 else { return }

        let old = active
        active = standby
        self.standby = nil
        fading = old
        active.fade = 0
        active.recoveries = 0
        old.fade = 1
        fadeLength = remaining
        fadeStart = Date()
        applyVolumes()
        active.player.play()
        handedOffTrackID = next.id
        nextTrack = nil
        updateTimeObserver()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fadeStep() }
        }
        emit(.finished)
    }

    private func fadeStep() {
        guard let fading else { return finishFade() }
        let p = min(1, Date().timeIntervalSince(fadeStart) / max(0.01, fadeLength))
        // Equal-power curve keeps perceived loudness steady through the overlap.
        active.fade = Float(sin(p * .pi / 2))
        fading.fade = Float(cos(p * .pi / 2))
        applyVolumes()
        if p >= 1 { finishFade() }
    }

    private func finishFade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        guard let old = fading else { return }
        fading = nil
        old.clear()
        standby = old
        active.fade = 1
        applyVolumes()
        maybePreloadStandby()
    }

    // MARK: Failure recovery

    private func itemFailed(_ slot: Slot, message: String) {
        if slot === standby {
            // The prepared item went bad (expired while waiting). Load fresh when it's needed.
            slot.clear()
            preparedStream = nil
            if let next = nextTrack { nextTrack = nil; prepareNext(next) }
            return
        }
        if slot === fading { finishFade(); return }
        guard slot === active else { return }
        if isLoading { failureDuringLoad = message; return }
        recover(reason: message)
    }

    /// Re-resolve the current track and resume at the last good position.
    private func recover(reason: String, countsAsFailure: Bool = true) {
        guard !isRecovering, let track = active.track else { return }
        if countsAsFailure {
            guard active.recoveries < maxRecoveryAttempts else { return fail(reason) }
            active.recoveries += 1
        }
        recoveryCount += 1
        cancelStallWatch()
        let generation = loadGeneration
        let recoveries = active.recoveries
        isRecovering = true
        hasFailed = false
        active.player.pause()
        updateTimeObserver()
        emit(.state(.buffering))

        recoveryTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Force a fresh lookup: a resolver cache would hand back the URL that just failed.
                let stream = try await self.resolve(track, forceRefresh: true)
                guard generation == self.loadGeneration, !Task.isCancelled else { return }
                self.install(stream, for: track, into: self.active)
                self.active.recoveries = recoveries
                // Read it now, not before the resolve: a seek during recovery wins.
                let position = max(0, self.active.lastGoodTime)
                if position > 0 {
                    await self.active.player.seek(to: Self.cmTime(position), toleranceBefore: .zero, toleranceAfter: .zero)
                    guard generation == self.loadGeneration, !Task.isCancelled else { return }
                }
                self.isRecovering = false
                if self.wantsToPlay {
                    self.active.player.play()
                    self.emitCurrentState()
                } else {
                    self.emit(.state(.paused))
                }
            } catch {
                guard generation == self.loadGeneration, !Task.isCancelled else { return }
                self.isRecovering = false
                self.fail(error.localizedDescription)
            }
        }
    }

    private func fail(_ message: String) {
        hasFailed = true
        wantsToPlay = false
        cancelStallWatch()
        active.player.pause()
        updateTimeObserver()
        emit(.state(.failed))
        emit(.failed(message))
    }

    private func startStallWatch() {
        guard stallTask == nil, wantsToPlay else { return }
        let generation = loadGeneration
        let timeout = stallTimeout
        stallTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled, generation == self.loadGeneration else { return }
            self.stallTask = nil
            guard self.wantsToPlay, self.active.player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
            self.recover(reason: "Playback stalled")
        }
    }

    private func cancelStallWatch() {
        stallTask?.cancel()
        stallTask = nil
    }

    // MARK: Media services reset

    /// After the media server restarted (`AVAudioSession.mediaServicesWereResetNotification` on iOS) every AVPlayer
    /// and item is dead. Builds fresh players and puts the current track back at its last good position, playing
    /// when `playing` is true and paused otherwise. A load in flight finishes into the new player.
    func rebuildPlayers(playing: Bool) {
        let track = active.track
        let stream = active.stream
        let position = max(0, active.lastGoodTime)
        let recoveries = active.recoveries

        // Nothing from the old players may call back.
        recoveryTask?.cancel()
        recoveryTask = nil
        isRecovering = false
        cancelStallWatch()
        fadeTimer?.invalidate()
        fadeTimer = nil
        if let timeObserver, let timeObserverPlayer { timeObserverPlayer.removeTimeObserver(timeObserver) }
        timeObserver = nil
        timeObserverPlayer = nil
        for slot in slots {
            slot.detachItemObservers()
            slot.timeControlObservation?.invalidate()
            slot.timeControlObservation = nil
        }
        active = Slot()
        let freshStandby = Slot()
        standby = freshStandby
        fading = nil
        handedOffTrackID = nil
        observeTimeControl(of: active)
        observeTimeControl(of: freshStandby)
        mediaResetCount += 1

        guard let track, !hasFailed else { return }
        active.track = track
        active.stream = stream
        active.lastGoodTime = position
        active.recoveries = recoveries
        if isLoading {
            // `load` installs into `active` after it resolves; if it already installed into the dead player, this
            // makes it re-resolve into the new one when it finishes.
            failureDuringLoad = "Media services were reset"
            return
        }
        wantsToPlay = playing
        guard let stream, !Self.isExpired(stream) else {
            recover(reason: "Media services were reset", countsAsFailure: false)
            return
        }
        install(stream, for: track, into: active)
        active.recoveries = recoveries
        active.lastGoodTime = position
        let generation = loadGeneration
        isRecovering = true
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            if position > 0 {
                await self.active.player.seek(to: Self.cmTime(position), toleranceBefore: .zero, toleranceAfter: .zero)
                guard generation == self.loadGeneration, !Task.isCancelled else { return }
            }
            self.isRecovering = false
            if self.wantsToPlay {
                self.active.player.play()
                self.emitCurrentState()
            } else {
                self.emit(.state(.paused))
            }
        }
    }

    // MARK: Time

    /// Attach the periodic observer only while the active player is running. Paused means zero wakeups.
    private func updateTimeObserver() {
        let wanted: AVPlayer? = active.player.timeControlStatus == .paused ? nil : active.player
        if wanted === timeObserverPlayer, (wanted == nil) == (timeObserver == nil) { return }
        if let timeObserver, let timeObserverPlayer { timeObserverPlayer.removeTimeObserver(timeObserver) }
        timeObserver = nil
        timeObserverPlayer = nil
        guard let wanted else { return }
        timeObserverPlayer = wanted
        timeObserver = wanted.addPeriodicTimeObserver(forInterval: Self.cmTime(timeInterval), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard !isLoading, !isRecovering else { return }
        let t = currentTime
        if active.item?.status == .readyToPlay, t > 0 { active.lastGoodTime = t }
        emit(.time(current: t, duration: duration))
        maybePreloadStandby()
        maybeStartCrossfade()
    }

    // MARK: Helpers

    private func emit(_ event: PlaybackEvent) {
        onEvent?(event)
    }

    private static func cmTime(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private static func isExpired(_ stream: PlayableStream?) -> Bool {
        guard let expires = stream?.expiresAt else { return false }
        return expires < Date().addingTimeInterval(30)
    }

    // MARK: Test support

    /// Runs the same path as a mid-track HTTP 403: re-resolve and resume at the last good position.
    func simulateStreamFailure(_ message: String = "HTTP 403 (simulated)") {
        itemFailed(active, message: message)
    }
}
