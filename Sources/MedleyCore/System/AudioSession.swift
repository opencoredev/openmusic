import Foundation

/// The decisions behind `AudioSessionController`, free of `AVAudioSession` so they're testable on every platform.
///
/// - Playback intent: Play sets it, an explicit Pause or Stop (in the app, lock screen, Siri, sleep timer, route
///   loss) clears it. Pausing for an interruption doesn't count as either.
/// - Auto-resume: an interruption that paused local playback arms it; the interruption ending with
///   `.shouldResume` resumes only if it's still armed. Any explicit Pause, Stop or Play disarms it.
/// - Session lifetime: active while local audio plays; released at once when what's playing is remote
///   (Spotify Connect) or nothing; released after a short grace when local playback is idle in the background.
struct AudioSessionPolicy: Equatable {
    enum Command: Equatable { case play, pause, stop }

    enum SessionAction: Equatable {
        case activate
        case deactivate
        /// Release unless playback starts again within the grace period.
        case deactivateAfterGrace
        case none
    }

    /// What the listener last asked for: true after Play or playback starting, false after an explicit Pause or Stop.
    private(set) var wantsPlayback = false
    /// Between an interruption's `.began` and `.ended`.
    private(set) var isInterrupted = false
    /// An interruption paused playback and nothing since said otherwise.
    private(set) var resumeAfterInterruption = false

    /// An explicit transport command from the listener (not Medley pausing for an interruption).
    mutating func command(_ command: Command) {
        wantsPlayback = command == .play
        resumeAfterInterruption = false
    }

    /// The player reports it's playing (or loading to play).
    mutating func playbackStarted() {
        // During an interruption a late "playing" from before the pause says nothing about the listener.
        guard !isInterrupted else { return }
        wantsPlayback = true
        resumeAfterInterruption = false
    }

    /// The session became active again. iOS doesn't promise an `.ended` for every `.began`, so this also ends one.
    mutating func sessionActivated() {
        isInterrupted = false
    }

    /// Returns true when playback should pause for this interruption.
    mutating func interruptionBegan(isPlayingLocally: Bool, appWasSuspended: Bool) -> Bool {
        // A "began" for a suspended app arrives late and describes the past; nothing is playing.
        guard !appWasSuspended else { return false }
        isInterrupted = true
        guard isPlayingLocally else { return false }
        resumeAfterInterruption = true
        return true
    }

    /// Returns true when playback should resume.
    mutating func interruptionEnded(shouldResume: Bool) -> Bool {
        isInterrupted = false
        defer { resumeAfterInterruption = false }
        return resumeAfterInterruption && shouldResume
    }

    func sessionAction(isPlaying: Bool, isLocal: Bool, isActive: Bool, inBackground: Bool) -> SessionAction {
        if isPlaying && isLocal { return isActive ? .none : .activate }
        guard isActive, !isInterrupted else { return .none }
        // Remote playback (or an empty queue) needs no session; holding one would stop the Spotify app's audio.
        if !isLocal { return .deactivate }
        return inBackground ? .deactivateAfterGrace : .none
    }

    /// After the media server restarted: play again only if the listener wanted playback and no interruption holds it.
    var resumeAfterMediaReset: Bool { wantsPlayback && !isInterrupted }
}

#if os(iOS)
import AVFoundation
import UIKit

/// Owns the app's `AVAudioSession` on iOS: the `.playback` category (so audio keeps going in the background and
/// with the silent switch on), activation, release, interruptions (calls, Siri, alarms) and media-server resets.
///
/// - The category is set at start, which doesn't stop other apps' audio. The session is activated only when local
///   audio starts (`AVPlaybackEngine`), so opening Medley never silences a podcast that's already playing, and
///   Spotify Connect playback (remote, even when the device is this phone) never takes the session.
/// - When local playback goes idle in the background, the session is released with `.notifyOthersOnDeactivation`
///   after a short grace, so other apps can resume. Play activates it again.
/// - When an interruption begins while playing, playback pauses. When it ends and iOS says it may resume
///   (`.shouldResume`), playback resumes, unless the listener paused or stopped in between.
/// - After a media-server reset the category is set again and the players are rebuilt, at the same position,
///   playing or paused as before.
/// - Route loss (headphones unplugged, AirPods gone) is `AudioOutputMonitor`'s job; `PlaybackSystem` pauses on it.
///
/// Event-driven: notifications, player change callbacks and engine commands. The only timer is the one-shot grace.
@MainActor
public final class AudioSessionController {
    private weak var player: PlayerController?
    private let session: AVAudioSession
    private let idleGrace: TimeInterval
    private var observers: [NSObjectProtocol] = []
    private var handlerID: UUID?
    private var policy = AudioSessionPolicy()
    private var hookedEngines: [ObjectIdentifier: AVPlaybackEngine] = [:]
    /// True while Medley itself pauses for an interruption, so that pause isn't taken as the listener's.
    private var pausingForInterruption = false
    private var inBackground = false
    private var deactivationTask: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    public private(set) var isActive = false
    /// True while an interruption that paused playback may still resume it.
    public var pausedByInterruption: Bool { policy.resumeAfterInterruption }
    /// Last error from configuring, activating or releasing the session, for diagnostics.
    public private(set) var lastError: String?

    public init(player: PlayerController, session: AVAudioSession = .sharedInstance(), idleGrace: TimeInterval = 3) {
        self.player = player
        self.session = session
        self.idleGrace = idleGrace
    }

    /// The category the session has, for the in-app self-test.
    public var category: AVAudioSession.Category { session.category }

    public func start() {
        guard handlerID == nil, let player else { return }
        configure()
        inBackground = UIApplication.shared.applicationState == .background
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
                let info = note.userInfo
                let type = (info?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
                let options = AVAudioSession.InterruptionOptions(rawValue: info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                let reason = (info?[AVAudioSessionInterruptionReasonKey] as? UInt).flatMap(AVAudioSession.InterruptionReason.init)
                MainActor.assumeIsolated { self?.interruption(type: type, options: options, reason: reason) }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.mediaServicesReset() }
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.inBackground = true
                    self?.update()
                }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.inBackground = false
                    self?.update()
                }
            },
        ]
        handlerID = player.addChangeHandler { [weak self] change in
            switch change {
            case .state, .track: self?.playerChanged()
            default: break
            }
        }
        playerChanged()
    }

    public func stop() {
        if let handlerID { player?.removeChangeHandler(handlerID) }
        handlerID = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        for engine in hookedEngines.values { engine.onTransportCommand = nil }
        hookedEngines = [:]
        cancelDeactivation()
    }

    private func configure() {
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Activate before audio starts. Safe to call repeatedly.
    public func activate() {
        cancelDeactivation()
        guard !isActive else { return }
        do {
            try session.setActive(true)
            isActive = true
            policy.sessionActivated()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func deactivate() {
        cancelDeactivation()
        guard isActive else { return }
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            isActive = false
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Player

    /// Local engines are the ones that play through this app's session.
    private var localEngines: [AVPlaybackEngine] {
        guard let player else { return [] }
        return ProviderID.allCases.compactMap { player.provider(for: $0)?.playbackEngine as? AVPlaybackEngine }
    }

    private var currentEngine: (any PlaybackEngine)? {
        guard let player, let current = player.current else { return nil }
        return player.provider(for: current.provider)?.playbackEngine
    }

    private var isLocal: Bool { currentEngine is AVPlaybackEngine }

    /// Listen for transport commands on every local engine, including ones registered after `start()`.
    private func hookEngines() {
        for engine in localEngines where hookedEngines[ObjectIdentifier(engine)] == nil {
            hookedEngines[ObjectIdentifier(engine)] = engine
            engine.onTransportCommand = { [weak self] command in self?.transport(command) }
        }
    }

    private func transport(_ command: AVPlaybackEngine.TransportCommand) {
        guard !pausingForInterruption else { return }
        switch command {
        case .play:
            policy.command(.play)
            // Before AVPlayer starts, so the first buffer already has the session.
            activate()
        case .pause:
            policy.command(.pause)
        case .stop:
            policy.command(.stop)
        }
    }

    private func playerChanged() {
        guard let player else { return }
        hookEngines()
        if player.isPlaying { policy.playbackStarted() }
        update()
    }

    private func update() {
        guard let player else { return }
        switch policy.sessionAction(isPlaying: player.isPlaying, isLocal: isLocal, isActive: isActive, inBackground: inBackground) {
        case .activate: activate()
        case .deactivate: deactivate()
        case .deactivateAfterGrace: scheduleDeactivation()
        case .none: cancelDeactivation()
        }
    }

    /// One-shot: release the session after `idleGrace` unless playback starts again. A background task keeps the
    /// app awake for it, since iOS suspends an app soon after its audio stops.
    private func scheduleDeactivation() {
        guard deactivationTask == nil else { return }
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Release audio session") { [weak self] in
                MainActor.assumeIsolated { self?.idleGraceEnded() }
            }
        }
        let grace = idleGrace
        deactivationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(grace))
            guard !Task.isCancelled else { return }
            self?.idleGraceEnded()
        }
    }

    private func idleGraceEnded() {
        deactivationTask = nil
        if let player {
            switch policy.sessionAction(isPlaying: player.isPlaying, isLocal: isLocal, isActive: isActive, inBackground: inBackground) {
            case .deactivate, .deactivateAfterGrace: deactivate()
            case .activate, .none: break
            }
        }
        endBackgroundTask()
    }

    private func cancelDeactivation() {
        deactivationTask?.cancel()
        deactivationTask = nil
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: System events

    private func interruption(type: AVAudioSession.InterruptionType?, options: AVAudioSession.InterruptionOptions,
                              reason: AVAudioSession.InterruptionReason?) {
        guard let player, let type else { return }
        switch type {
        case .began:
            // The system deactivated the session.
            isActive = false
            cancelDeactivation()
            if policy.interruptionBegan(isPlayingLocally: player.isPlaying && isLocal, appWasSuspended: reason == .appWasSuspended) {
                pausingForInterruption = true
                player.pause()
                pausingForInterruption = false
            }
        case .ended:
            if policy.interruptionEnded(shouldResume: options.contains(.shouldResume)) {
                activate()
                player.resume()
            } else {
                update()
            }
        @unknown default:
            break
        }
    }

    /// The media server restarted: every audio object is gone. Configure from scratch and rebuild the players.
    private func mediaServicesReset() {
        isActive = false
        cancelDeactivation()
        configure()
        let resume = policy.resumeAfterMediaReset
        let current = currentEngine
        if resume && isLocal { activate() }
        for engine in localEngines {
            engine.rebuildPlayers(playing: resume && engine === current)
        }
    }
}
#endif
