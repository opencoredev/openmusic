import Foundation

/// Wires the player into the system: Now Playing and media keys / lock screen controls, queue persistence,
/// output devices and settings. On iOS it also owns the `AVAudioSession` (category, activation, interruptions).
///
/// ```swift
/// let system = PlaybackSystem(player: player)
/// await system.start()      // restores the last queue (paused) and starts the integrations
/// ```
@MainActor
public final class PlaybackSystem {
    public let player: PlayerController
    public let settings: PlaybackSettings
    public let nowPlaying: NowPlayingCenter
    public let outputs: AudioOutputMonitor
    public let persistence: QueuePersistence
    #if os(iOS)
    public let audioSession: AudioSessionController
    #endif
    private var started = false

    public init(
        player: PlayerController,
        settings: PlaybackSettings? = nil,
        store: QueueStore = QueueStore(url: QueueStore.defaultURL)
    ) {
        self.player = player
        self.settings = settings ?? PlaybackSettings()
        self.nowPlaying = NowPlayingCenter(player: player)
        self.outputs = AudioOutputMonitor()
        self.persistence = QueuePersistence(player: player, store: store)
        #if os(iOS)
        self.audioSession = AudioSessionController(player: player)
        #endif
    }

    /// Restore the saved queue and start every integration. Call once at launch, after registering providers.
    public func start() async {
        guard !started else { return }
        started = true
        settings.onChange = { [weak self] in self?.applySettings() }
        outputs.onDevicesRemoved = { [weak self] removed, previousDefault in
            self?.devicesRemoved(removed, previousDefaultUID: previousDefault)
        }
        outputs.onHeadphonesUnplugged = { [weak self] in
            self?.headphonesUnplugged()
        }
        outputs.onChange = { [weak self] in self?.applyOutputDevice() }
        #if os(iOS)
        // Category first, so the first play already gets background audio.
        audioSession.start()
        #endif
        outputs.start()
        applySettings()
        await persistence.restore()
        persistence.start()
        nowPlaying.start()
    }

    /// The device audio is actually going to right now.
    public var effectiveOutputDeviceUID: String? {
        player.outputDeviceUID ?? outputs.defaultDeviceUID
    }

    private func applySettings() {
        player.normalizationEnabled = settings.normalizeVolume
        player.crossfadeDuration = settings.crossfadeSeconds
        player.autoplay = settings.autoplay
        if player.volume != settings.volume { player.volume = settings.volume }
        applyOutputDevice()
    }

    /// Use the preferred device while it exists, the system default otherwise.
    private func applyOutputDevice() {
        let preferred = settings.outputDeviceUID
        let uid = preferred.flatMap { outputs.device(uid: $0) != nil ? $0 : nil }
        if player.outputDeviceUID != uid { player.outputDeviceUID = uid }
    }

    private func devicesRemoved(_ removed: [AudioOutputDevice], previousDefaultUID: String?) {
        // The device we were playing through: the preferred one if it was in use, else the old default.
        let inUse = player.outputDeviceUID ?? previousDefaultUID
        guard let inUse, removed.contains(where: { $0.uid == inUse }) else { return }
        if player.isPlaying { player.pause() }
    }

    private func headphonesUnplugged() {
        // Only matters when playing through the built-in output (the default, not a chosen external device).
        guard player.outputDeviceUID == nil || player.outputDeviceUID == outputs.defaultDeviceUID else { return }
        if player.isPlaying { player.pause() }
    }
}
