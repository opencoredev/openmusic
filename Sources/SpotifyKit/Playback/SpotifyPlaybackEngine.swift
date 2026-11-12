import Foundation
import OpenMusicCore
import Observation

/// Plays Spotify tracks through the Spotify app on this Mac or a Spotify Connect device, with OpenMusic's queue in charge.
///
/// Spotify has no way to hand audio to a third-party player, so OpenMusic drives a real Spotify player:
/// it asks for exactly one track, watches it (1 Hz for the app, every 5 s for Connect, faster near the end),
/// and when the track ends pauses Spotify and reports `.finished` so `PlayerController` picks what's next.
/// Nothing is polled while paused.
@MainActor
@Observable
public final class SpotifyPlaybackEngine: PlaybackEngine {
    public enum RoutePreference: String, CaseIterable, Sendable, Identifiable {
        /// Spotify.app when installed, else Spotify Connect.
        case automatic
        case thisMac
        case connect

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .automatic: "Automatic"
            case .thisMac: "Spotify app on this Mac"
            case .connect: "Spotify Connect device"
            }
        }
    }

    public enum ActiveRoute: String, Sendable {
        case thisMac, connect
    }

    @ObservationIgnored public var onEvent: (@MainActor (PlaybackEvent) -> Void)?

    public var preference: RoutePreference {
        didSet { defaults.set(preference.rawValue, forKey: Keys.route) }
    }
    /// Connect device to play on; nil uses the active device.
    public var connectDeviceID: String? {
        didSet { defaults.set(connectDeviceID, forKey: Keys.device) }
    }
    public private(set) var devices: [SpotifyDevice] = []
    public private(set) var activeRoute: ActiveRoute?
    public private(set) var lastError: String?

    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval?

    public var volume: Float = 1 {
        didSet { scheduleVolume() }
    }

    @ObservationIgnored private let service: SpotifyService
    @ObservationIgnored private let bridge: SpotifyAppBridge
    @ObservationIgnored private let defaults: UserDefaults
    /// Whether the Web API is usable (needed for Connect). Set by the provider.
    @ObservationIgnored var isSignedIn: @MainActor () -> Bool
    @ObservationIgnored private let appInstalled: @MainActor () -> Bool
    @ObservationIgnored private let routeFactory: (@MainActor (ActiveRoute) -> any SpotifyPlaybackRoute)?

    // Playback session
    @ObservationIgnored private var route: (any SpotifyPlaybackRoute)?
    @ObservationIgnored private var track: Track?
    @ObservationIgnored private var detector: EndOfTrackDetector?
    /// True until Spotify has been told to play the current track (load without autoplay, or after a replace).
    @ObservationIgnored private var needsStart = false
    /// Whether the listener wants sound: true from the moment they press play (or load with autoplay), even while
    /// Spotify is still starting, and false as soon as they pause or stop.
    @ObservationIgnored private var isPlaying = false
    @ObservationIgnored private var generation = 0
    /// Bumped by every play, pause, stop and load. A start or resume that comes back under an older value is obsolete.
    @ObservationIgnored private var intent = 0
    /// Tail of the remote command queue. Commands run one at a time in the order they were issued, so a pause
    /// can never overtake the play it follows.
    @ObservationIgnored private var commandTail: Task<Void, Never>?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var volumeTask: Task<Void, Never>?
    // Interpolation anchor
    @ObservationIgnored private var anchorPosition: TimeInterval = 0
    @ObservationIgnored private var anchorTime: TimeInterval = 0
    @ObservationIgnored private var startedAt: TimeInterval = 0
    @ObservationIgnored private var failures = 0

    enum Keys {
        static let route = "spotify.playbackRoute"
        static let device = "spotify.connectDevice"
    }

    init(
        service: SpotifyService,
        bridge: SpotifyAppBridge = SpotifyAppBridge(),
        defaults: UserDefaults = .standard,
        isSignedIn: @escaping @MainActor () -> Bool = { false },
        appInstalled: @escaping @MainActor () -> Bool = { SpotifyAppBridge.isInstalled },
        makeRoute: (@MainActor (ActiveRoute) -> any SpotifyPlaybackRoute)? = nil
    ) {
        self.service = service
        self.bridge = bridge
        self.defaults = defaults
        self.isSignedIn = isSignedIn
        self.appInstalled = appInstalled
        self.routeFactory = makeRoute
        self.preference = RoutePreference(rawValue: defaults.string(forKey: Keys.route) ?? "") ?? .automatic
        self.connectDeviceID = defaults.string(forKey: Keys.device)
    }

    // MARK: Routes

    /// Which route a track would use right now, or why none works.
    public func resolveRoute() throws -> ActiveRoute {
        switch preference {
        case .thisMac:
            guard appInstalled() else { throw ProviderError.unplayable("The Spotify app isn't installed on this Mac. Install it, or switch playback to a Spotify Connect device in Settings.") }
            return .thisMac
        case .connect:
            guard isSignedIn() else { throw ProviderError.notSignedIn }
            return .connect
        case .automatic:
            if appInstalled() { return .thisMac }
            if isSignedIn() { return .connect }
            #if os(macOS)
            throw ProviderError.unplayable("Install the Spotify app on this Mac, or sign in with Spotify Premium to play on a Spotify Connect device.")
            #else
            throw ProviderError.unplayable("Sign in with Spotify Premium to play on a Spotify Connect device.")
            #endif
        }
    }

    private func makeRoute(_ route: ActiveRoute) -> any SpotifyPlaybackRoute {
        if let routeFactory { return routeFactory(route) }
        return switch route {
        case .thisMac: AppRoute(bridge: bridge)
        case .connect: ConnectRoute(service: service, deviceID: connectDeviceID)
        }
    }

    public func refreshDevices() async {
        do {
            devices = try await service.devices()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Moves playback to a Connect device (and uses it from now on).
    public func transfer(to deviceID: String) async {
        connectDeviceID = deviceID
        do {
            try await service.transfer(to: deviceID, play: isPlaying)
            if activeRoute == .connect { route = makeRoute(.connect) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: PlaybackEngine

    public func load(_ track: Track, startAt: TimeInterval, autoplay: Bool) async throws {
        generation += 1
        intent += 1
        let generation = self.generation
        let intent = self.intent
        stopLoop()
        onEvent?(.state(.loading))

        let active = try resolveRoute()
        let route = makeRoute(active)
        self.route = route
        self.activeRoute = active
        self.track = track
        self.detector = EndOfTrackDetector(expectedURI: SpotifyMapping.uri(track), expectedDuration: track.duration)
        self.duration = track.duration
        self.currentTime = startAt
        self.failures = 0
        self.lastError = nil
        self.needsStart = true
        // Autoplay means the listener wants sound from now on, so a Pause pressed while Spotify starts counts.
        self.isPlaying = autoplay

        guard autoplay else {
            // Don't touch Spotify until the listener presses play.
            onEvent?(.time(current: startAt, duration: track.duration))
            onEvent?(.state(.paused))
            return
        }
        do {
            try await startOrResume(at: startAt, route: route, track: track, fresh: true, generation: generation, intent: intent)
        } catch {
            // Only the current load reports its failure; an obsolete one just goes away.
            guard wants(generation, intent) else { return }
            isPlaying = false
            throw error
        }
    }

    public func play() {
        guard let route, let track, !isPlaying else { return }
        intent += 1
        let generation = self.generation
        let intent = self.intent
        let position = currentTime
        let fresh = needsStart
        isPlaying = true
        onEvent?(.state(.loading))
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.startOrResume(at: position, route: route, track: track, fresh: fresh, generation: generation, intent: intent)
            } catch {
                guard self.wants(generation, intent) else { return }
                self.isPlaying = false
                self.fail(error)
            }
        }
    }

    public func pause() {
        guard isPlaying else { return }
        intent += 1
        isPlaying = false
        if !needsStart { currentTime = projectedTime() }
        stopLoop()
        onEvent?(.state(.paused))
        // A start still on its way pauses Spotify itself when it lands (see `startOrResume`).
        guard let route, !needsStart else { return }
        enqueue { [weak self] in
            do { try await route.pause() } catch { self?.lastError = error.localizedDescription }
        }
    }

    public func stop() {
        generation += 1
        intent += 1
        stopLoop()
        // A start still on its way pauses Spotify itself when it lands (see `startOrResume`).
        let wasStarted = !needsStart && isPlaying
        isPlaying = false
        if wasStarted, let route {
            enqueue { try? await route.pause() }
        }
        track = nil
        detector = nil
        route = nil
        activeRoute = nil
        currentTime = 0
        duration = nil
        onEvent?(.state(.idle))
    }

    public func seek(to seconds: TimeInterval) {
        let target = max(0, min(seconds, duration ?? seconds))
        currentTime = target
        anchorPosition = target
        anchorTime = now()
        onEvent?(.time(current: target, duration: duration))
        guard let route, !needsStart else { return }
        enqueue { [weak self] in
            do { try await route.seek(to: target) } catch { self?.lastError = error.localizedDescription }
        }
    }

    public func prepareNext(_ track: Track?) {}

    // MARK: Internals

    /// Whether the play request made under `generation`/`intent` is still what the listener wants.
    private func wants(_ generation: Int, _ intent: Int) -> Bool {
        generation == self.generation && intent == self.intent && isPlaying
    }

    /// Tells Spotify to play (`fresh`: start the track at `position`; else resume) through the command queue,
    /// then starts watching it. If the listener paused, stopped, or moved on while Spotify was starting, the
    /// command is skipped when it hadn't gone out yet, or followed by a pause when it had, and nothing here changes.
    private func startOrResume(
        at position: TimeInterval, route: any SpotifyPlaybackRoute, track: Track, fresh: Bool, generation: Int, intent: Int
    ) async throws {
        let uri = SpotifyMapping.uri(track)
        let started = try await enqueue { [weak self] () -> Bool in
            guard let self, self.wants(generation, intent) else { return false }
            if fresh {
                try await route.start(uri: uri, at: position)
            } else {
                try await route.resume()
            }
            if !self.wants(generation, intent) {
                // Obsolete, but Spotify already heard it: make it quiet again before the next command runs.
                try? await route.pause()
                return false
            }
            return true
        }.value
        guard started, wants(generation, intent) else { return }
        if fresh {
            needsStart = false
            detector = EndOfTrackDetector(expectedURI: uri, expectedDuration: track.duration)
            startedAt = now()
            scheduleVolume(immediately: true)
        }
        beginPlaying(at: position)
    }

    /// Queues a remote command behind every earlier one and returns its task.
    @discardableResult
    private func enqueue<T: Sendable>(_ command: @escaping @MainActor @Sendable () async throws -> T) -> Task<T, any Error> {
        let previous = commandTail
        let task = Task { @MainActor in
            await previous?.value
            return try await command()
        }
        commandTail = Task { _ = await task.result }
        return task
    }

    /// Waits until every queued remote command has run. For tests.
    func waitForCommands() async {
        while let tail = commandTail {
            await tail.value
            if commandTail == tail { return }
        }
    }

    private func beginPlaying(at position: TimeInterval) {
        isPlaying = true
        anchorPosition = position
        anchorTime = now()
        onEvent?(.state(.playing))
        startLoop()
    }

    private func startLoop() {
        stopLoop()
        guard let route else { return }
        let generation = self.generation
        loop = Task { [weak self] in
            var nextPoll: TimeInterval = 0.6 // first check soon after starting
            var sinceTick: TimeInterval = 0
            while !Task.isCancelled {
                guard let self, generation == self.generation, self.isPlaying else { return }
                let step = min(0.5, nextPoll)
                try? await Task.sleep(for: .milliseconds(Int(step * 1000)))
                guard !Task.isCancelled, generation == self.generation, self.isPlaying else { return }
                nextPoll -= step
                sinceTick += step
                if sinceTick >= 0.5 {
                    sinceTick = 0
                    self.currentTime = self.projectedTime()
                    self.onEvent?(.time(current: self.currentTime, duration: self.duration))
                }
                guard nextPoll <= 0.001 else { continue }
                nextPoll = await self.poll(route: route, generation: generation)
            }
        }
    }

    private func stopLoop() {
        loop?.cancel()
        loop = nil
    }

    /// Takes one sample and acts on it. Returns seconds until the next one.
    private func poll(route: any SpotifyPlaybackRoute, generation: Int) async -> TimeInterval {
        let sample: RemoteSample
        do {
            sample = try await route.sample()
            failures = 0
        } catch {
            failures += 1
            if failures >= 3 {
                fail(error)
            }
            return route.pollInterval
        }
        guard generation == self.generation, isPlaying, var detector else { return route.pollInterval }
        let verdict = detector.ingest(sample)
        self.detector = detector

        switch verdict {
        case .waiting:
            if now() - startedAt > 12 {
                fail(ProviderError.unplayable("Spotify didn't start the track."))
            }
            return 0.5
        case .playing:
            anchorPosition = sample.position
            anchorTime = sample.timestamp
            if let d = sample.duration { duration = d }
            currentTime = sample.position
            onEvent?(.time(current: currentTime, duration: duration))
            return EndOfTrackDetector.nextPollInterval(position: sample.position, duration: duration, base: route.pollInterval)
        case .paused:
            // Paused from Spotify itself (or its own controls). Stop polling until the listener resumes in OpenMusic.
            isPlaying = false
            currentTime = sample.position
            stopLoop()
            onEvent?(.time(current: currentTime, duration: duration))
            onEvent?(.state(.paused))
            return route.pollInterval
        case .finished:
            isPlaying = false
            needsStart = true
            stopLoop()
            if sample.state == .playing {
                // Spotify moved on to its own next track; stop it so OpenMusic's queue decides.
                enqueue { try? await route.pause() }
            }
            currentTime = duration ?? currentTime
            onEvent?(.state(.ended))
            onEvent?(.finished)
            return route.pollInterval
        case .replaced:
            // The listener picked something else in Spotify. Step back; pressing play in OpenMusic restarts our track.
            isPlaying = false
            needsStart = true
            stopLoop()
            onEvent?(.state(.paused))
            return route.pollInterval
        }
    }

    private func projectedTime() -> TimeInterval {
        guard isPlaying else { return currentTime }
        let t = anchorPosition + (now() - anchorTime)
        if let duration { return min(t, duration) }
        return t
    }

    private func fail(_ error: any Error) {
        stopLoop()
        isPlaying = false
        let message = error.localizedDescription
        lastError = message
        onEvent?(.state(.failed))
        onEvent?(.failed(message))
    }

    private func scheduleVolume(immediately: Bool = false) {
        guard let route, !needsStart else { return }
        let percent = Int((max(0, min(1, volume)) * 100).rounded())
        volumeTask?.cancel()
        volumeTask = Task {
            // Coalesce slider drags into one request.
            if !immediately { try? await Task.sleep(for: .milliseconds(200)) }
            guard !Task.isCancelled else { return }
            try? await route.setVolume(percent)
        }
    }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}
