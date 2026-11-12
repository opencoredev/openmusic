import Foundation
import MedleyCore

/// One way of making Spotify play: the desktop app on this Mac, or a Spotify Connect device.
protocol SpotifyPlaybackRoute: Sendable {
    /// Seconds between samples while playing.
    var pollInterval: TimeInterval { get }
    func start(uri: String, at seconds: TimeInterval) async throws
    func resume() async throws
    func pause() async throws
    func seek(to seconds: TimeInterval) async throws
    /// 0...100
    func setVolume(_ percent: Int) async throws
    func sample() async throws -> RemoteSample
}

/// Spotify.app via Apple Events. Works with Free and Premium accounts.
struct AppRoute: SpotifyPlaybackRoute {
    let bridge: SpotifyAppBridge
    var pollInterval: TimeInterval { 1 }

    func start(uri: String, at seconds: TimeInterval) async throws {
        try await mapErrors {
            try await bridge.launchIfNeeded()
            if await bridge.permission(ask: true) == .denied {
                throw SpotifyAppError(code: Int(errAEEventNotPermitted))
            }
            try await bridge.playTrack(uri)
            if seconds > 1 {
                // `play track` restarts from 0; give Spotify a moment to load before seeking.
                try await Task.sleep(for: .milliseconds(400))
                try await bridge.setPosition(seconds)
            }
        }
    }

    func resume() async throws { try await mapErrors { try await bridge.play() } }
    func pause() async throws { try await mapErrors { try await bridge.pause() } }
    func seek(to seconds: TimeInterval) async throws { try await mapErrors { try await bridge.setPosition(seconds) } }
    func setVolume(_ percent: Int) async throws { try await mapErrors { try await bridge.setVolume(percent) } }

    func sample() async throws -> RemoteSample {
        try await mapErrors {
            guard SpotifyAppBridge.isRunning else {
                return RemoteSample(state: .stopped, trackURI: nil, position: 0, duration: nil, timestamp: ProcessInfo.processInfo.systemUptime)
            }
            return try await bridge.sample()
        }
    }

    private func mapErrors<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as SpotifyAppError {
            throw ProviderError.unplayable(error.localizedDescription)
        }
    }
}

/// A Spotify Connect device through `/me/player`. Needs Premium.
struct ConnectRoute: SpotifyPlaybackRoute {
    let service: SpotifyService
    /// nil plays on whichever device is active.
    let deviceID: String?
    /// Fewer Web API calls: interpolate locally and resync every few seconds.
    var pollInterval: TimeInterval { 5 }

    func start(uri: String, at seconds: TimeInterval) async throws {
        let device = try await resolveDevice()
        try await service.startPlayback(uri: uri, positionMS: Int(seconds * 1000), deviceID: device)
    }

    // After `start`, the device we played on is the active one, so the rest target the active device.
    func resume() async throws { try await service.resume(deviceID: nil) }
    func pause() async throws { try await service.pause(deviceID: nil) }
    func seek(to seconds: TimeInterval) async throws { try await service.seek(positionMS: Int(seconds * 1000), deviceID: nil) }
    func setVolume(_ percent: Int) async throws { try await service.setVolume(percent: percent, deviceID: nil) }

    func sample() async throws -> RemoteSample {
        let now = ProcessInfo.processInfo.systemUptime
        guard let state = try await service.playbackState() else {
            return RemoteSample(state: .stopped, trackURI: nil, position: 0, duration: nil, timestamp: now)
        }
        return Self.sample(from: state, timestamp: now)
    }

    static func sample(from state: SP.PlaybackState, timestamp: TimeInterval) -> RemoteSample {
        RemoteSample(
            state: state.is_playing ? .playing : (state.item == nil ? .stopped : .paused),
            trackURI: state.item?.uri,
            position: TimeInterval(state.progress_ms ?? 0) / 1000,
            duration: state.item?.duration_ms.map { TimeInterval($0) / 1000 },
            timestamp: timestamp
        )
    }

    /// The chosen device, else the active one, else the first usable one.
    private func resolveDevice() async throws -> String? {
        let devices = try await service.devices()
        return try Self.pickDevice(devices, preferred: deviceID)
    }

    static func pickDevice(_ devices: [SpotifyDevice], preferred: String?) throws -> String {
        let usable = devices.filter { !$0.isRestricted }
        if let preferred, usable.contains(where: { $0.id == preferred }) { return preferred }
        if let active = usable.first(where: \.isActive) { return active.id }
        if let first = usable.first { return first.id }
        throw ProviderError.unplayable("No Spotify Connect device is available. Open Spotify on a phone, speaker, or computer signed in to your account.")
    }
}
