import Foundation
import Observation

/// Playback preferences for the Settings window, persisted in UserDefaults.
/// `PlaybackSystem` applies every change to the `PlayerController` immediately.
@MainActor
@Observable
public final class PlaybackSettings {
    /// Even out loudness between tracks (YouTube Music `loudnessDb`).
    public var normalizeVolume: Bool {
        didSet { defaults.set(normalizeVolume, forKey: Key.normalize); changed() }
    }

    /// Seconds of overlap between tracks, 0 (off) ... 12. Stored clamped.
    public var crossfadeSeconds: Double {
        get { crossfadeStorage }
        set {
            crossfadeStorage = max(Self.crossfadeRange.lowerBound, min(Self.crossfadeRange.upperBound, newValue))
            defaults.set(crossfadeStorage, forKey: Key.crossfade)
            changed()
        }
    }

    /// Preferred output device UID (`AudioOutputDevice.uid`); nil follows the system default.
    /// If the device is missing, playback uses the system default until it comes back.
    public var outputDeviceUID: String? {
        didSet { defaults.set(outputDeviceUID, forKey: Key.outputDevice); changed() }
    }

    /// Keep playing similar music when the queue ends.
    public var autoplay: Bool {
        didSet { defaults.set(autoplay, forKey: Key.autoplay); changed() }
    }

    /// Last sleep-timer duration the user picked, offered as the default next time.
    public var sleepTimerMinutes: Int {
        didSet { defaults.set(sleepTimerMinutes, forKey: Key.sleepMinutes) }
    }

    /// Player volume, 0...1.
    public var volume: Float {
        get { volumeStorage }
        set {
            volumeStorage = max(0, min(1, newValue))
            defaults.set(volumeStorage, forKey: Key.volume)
            changed()
        }
    }

    public static let crossfadeRange: ClosedRange<Double> = 0...12
    public static let sleepTimerPresets = [5, 10, 15, 30, 45, 60, 90, 120]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    private var crossfadeStorage: Double
    private var volumeStorage: Float

    private enum Key {
        static let normalize = "playback.normalizeVolume"
        static let crossfade = "playback.crossfadeSeconds"
        static let outputDevice = "playback.outputDeviceUID"
        static let autoplay = "playback.autoplay"
        static let sleepMinutes = "playback.sleepTimerMinutes"
        static let volume = "playback.volume"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        normalizeVolume = defaults.object(forKey: Key.normalize) as? Bool ?? true
        crossfadeStorage = max(0, min(12, defaults.object(forKey: Key.crossfade) == nil ? 0 : defaults.double(forKey: Key.crossfade)))
        outputDeviceUID = defaults.string(forKey: Key.outputDevice)
        autoplay = defaults.object(forKey: Key.autoplay) as? Bool ?? true
        sleepTimerMinutes = defaults.object(forKey: Key.sleepMinutes) == nil ? 30 : defaults.integer(forKey: Key.sleepMinutes)
        volumeStorage = max(0, min(1, defaults.object(forKey: Key.volume) == nil ? 0.8 : defaults.float(forKey: Key.volume)))
    }

    private func changed() { onChange?() }
}
