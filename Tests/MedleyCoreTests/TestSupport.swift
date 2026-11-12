import AVFoundation
import Foundation
import SwiftUI
@testable import MedleyCore

// MARK: - Tracks

func makeTracks(_ count: Int, prefix: String = "t", provider: ProviderID = .youtubeMusic, duration: TimeInterval = 200) -> [Track] {
    (0..<count).map { i in
        Track(providerID: "\(prefix)\(i)", provider: provider, title: "\(prefix.uppercased()) \(i)", artists: [ArtistRef(name: "Artist")], album: AlbumRef(title: "Album"), duration: duration)
    }
}

// MARK: - Scheduler

/// Time only moves when the test says so.
@MainActor
final class ManualScheduler: PlaybackScheduler {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var items: [(id: Int, at: Date, action: @MainActor @Sendable () -> Void)] = []
    private var nextID = 0

    var pendingCount: Int { items.count }

    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> ScheduledAction {
        nextID += 1
        let id = nextID
        items.append((id, now.addingTimeInterval(delay), action))
        return ScheduledAction { [weak self] in self?.items.removeAll { $0.id == id } }
    }

    func advance(by seconds: TimeInterval) {
        let target = now.addingTimeInterval(seconds)
        while let next = items.filter({ $0.at <= target }).min(by: { $0.at < $1.at }) {
            items.removeAll { $0.id == next.id }
            now = max(now, next.at)
            next.action()
        }
        now = target
    }
}

// MARK: - Engine

/// Scriptable engine: records commands, can hold or fail loads, and emits events on demand.
@MainActor
final class FakeEngine: PlaybackEngine, DurationReportingEngine {
    var onEvent: (@MainActor (PlaybackEvent) -> Void)?
    var onDurationResolved: (@MainActor (_ trackID: String, _ seconds: TimeInterval) -> Void)?
    var volume: Float = 1
    var currentTime: TimeInterval = 0
    var duration: TimeInterval?

    struct Load: Equatable { var trackID: String; var startAt: TimeInterval; var autoplay: Bool }
    private(set) var loads: [Load] = []
    private(set) var prepared: [String?] = []
    private(set) var plays = 0
    private(set) var pauses = 0
    private(set) var stops = 0
    private(set) var seeks: [TimeInterval] = []
    var failingIDs: Set<String> = []
    var holdLoads = false
    private var held: [(id: String, continuation: CheckedContinuation<Void, Never>)] = []

    var lastLoad: Load? { loads.last }
    var lastPrepared: String?? { prepared.last }
    var heldCount: Int { held.count }

    func load(_ track: Track, startAt: TimeInterval, autoplay: Bool) async throws {
        loads.append(Load(trackID: track.id, startAt: startAt, autoplay: autoplay))
        if holdLoads {
            await withCheckedContinuation { held.append((track.id, $0)) }
        }
        if failingIDs.contains(track.id) { throw ProviderError.unplayable("fake failure for \(track.id)") }
        duration = track.duration
        currentTime = startAt
        onEvent?(.state(autoplay ? .playing : .paused))
    }

    /// Resume a held load (by position in the held list).
    func release(at index: Int) {
        let item = held.remove(at: index)
        item.continuation.resume()
    }

    func releaseAll() {
        while !held.isEmpty { release(at: 0) }
    }

    func play() { plays += 1; onEvent?(.state(.playing)) }
    func pause() { pauses += 1; onEvent?(.state(.paused)) }
    func stop() { stops += 1; onEvent?(.state(.idle)) }
    func seek(to seconds: TimeInterval) { seeks.append(seconds); currentTime = seconds }
    func prepareNext(_ track: Track?) { prepared.append(track?.id) }

    // Event helpers
    func tick(_ t: TimeInterval) { currentTime = t; onEvent?(.time(current: t, duration: duration)) }
    /// Ticks once per second from the current time up to `t`, like real playback.
    func play(until t: TimeInterval) {
        var now = currentTime
        while now < t { now = min(t, now + 1); tick(now) }
    }
    func finish() { onEvent?(.state(.ended)); onEvent?(.finished) }
    func failMidTrack(_ message: String = "stream died") { onEvent?(.state(.failed)); onEvent?(.failed(message)) }
    func emit(_ event: PlaybackEvent) { onEvent?(event) }
}

// MARK: - Provider

@MainActor
final class FakeProvider: MusicProvider {
    let id: ProviderID
    var capabilities: ProviderCapabilities = [.radio, .playback]
    var authStatus: AuthStatus = .signedIn(AccountInfo(name: "Test"))
    let engine = FakeEngine()
    var playbackEngine: any PlaybackEngine { engine }

    var radioResult: [Track] = []
    private(set) var radioCalls: [String] = []
    var holdRadio = false
    private var heldRadio: [CheckedContinuation<Void, Never>] = []

    init(id: ProviderID = .youtubeMusic) { self.id = id }

    func releaseRadio() {
        let pending = heldRadio
        heldRadio = []
        pending.forEach { $0.resume() }
    }

    func restoreSession() async {}
    func makeSignInView(onFinish: @escaping @MainActor () -> Void) -> AnyView { AnyView(EmptyView()) }
    func makeSettingsView() -> AnyView { AnyView(EmptyView()) }
    func signOut() async {}
    func home() async throws -> [Shelf] { [] }
    func explore() async throws -> [Shelf] { [] }
    func shelf(moreToken: String) async throws -> Shelf { throw ProviderError.notSupported("shelf") }
    func search(_ query: String, scope: SearchScope) async throws -> SearchResults { SearchResults() }
    func searchSuggestions(_ query: String) async throws -> [String] { [] }
    func album(id: String) async throws -> AlbumDetail { throw ProviderError.notFound }
    func artist(id: String) async throws -> ArtistDetail { throw ProviderError.notFound }
    func playlist(id: String) async throws -> PlaylistDetail { throw ProviderError.notFound }
    func playlistTracks(continuation: String) async throws -> Page<Track> { Page(items: []) }
    func library(_ kind: LibraryKind, continuation: String?) async throws -> Page<MediaItem> { Page(items: []) }
    func setLiked(_ track: Track, liked: Bool) async throws {}
    func isLiked(_ track: Track) async throws -> Bool { false }
    func setSaved(_ item: MediaItem, saved: Bool) async throws {}
    func createPlaylist(title: String, description: String?) async throws -> Playlist { throw ProviderError.notSupported("create") }
    func add(_ tracks: [Track], toPlaylist playlistID: String) async throws {}
    func remove(_ tracks: [Track], fromPlaylist playlistID: String) async throws {}

    func radio(seed: Track) async throws -> [Track] {
        radioCalls.append(seed.id)
        if holdRadio { await withCheckedContinuation { heldRadio.append($0) } }
        return radioResult
    }

    func radio(seedID: String) async throws -> [Track] {
        radioCalls.append(seedID)
        return radioResult
    }

    func lyrics(for track: Track) async throws -> Lyrics? { nil }
}

// MARK: - Resolver

/// Returns scripted streams in order; the last one repeats.
final class FakeResolver: StreamResolver, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Result<PlayableStream, ProviderError>]
    private var _calls = 0
    /// Seconds each resolve takes.
    var delay: TimeInterval = 0

    init(_ responses: [Result<PlayableStream, ProviderError>]) {
        self.responses = responses
    }

    convenience init(urls: [URL]) {
        self.init(urls.map { .success(PlayableStream(url: $0)) })
    }

    var calls: Int { lock.withLock { _calls } }

    func set(_ responses: [Result<PlayableStream, ProviderError>]) {
        lock.withLock { self.responses = responses }
    }

    func resolveStream(for track: Track) async throws -> PlayableStream {
        let result: Result<PlayableStream, ProviderError> = lock.withLock {
            _calls += 1
            return responses.count > 1 ? responses.removeFirst() : responses[0]
        }
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        return try result.get()
    }
}

/// Caches like `YouTubeStreamResolver`: hands back the cached stream while it has more than ten minutes
/// of nominal validity left, unless asked to refresh. Each uncached fetch takes the next URL (the last repeats).
final class CachingResolver: StreamResolver, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL]
    private var cache: [String: PlayableStream] = [:]
    private var _fetches = 0

    init(urls: [URL]) { self.urls = urls }

    /// Uncached lookups, i.e. fresh URLs handed out.
    var fetches: Int { lock.withLock { _fetches } }

    func resolveStream(for track: Track) async throws -> PlayableStream {
        try await resolveStream(for: track, forceRefresh: false)
    }

    func resolveStream(for track: Track, forceRefresh: Bool) async throws -> PlayableStream {
        lock.withLock {
            if !forceRefresh, let hit = cache[track.id], let expiry = hit.expiresAt, expiry.timeIntervalSinceNow > 600 {
                return hit
            }
            _fetches += 1
            let url = urls.count > 1 ? urls.removeFirst() : urls[0]
            let stream = PlayableStream(url: url, expiresAt: Date().addingTimeInterval(6 * 3600))
            cache[track.id] = stream
            return stream
        }
    }
}

// MARK: - Audio fixtures

enum AudioFixture {
    /// A sine tone written as AAC in an .m4a, cached per (seconds, frequency).
    static func tone(seconds: Double, frequency: Double = 440) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "medley-tests", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "tone-\(Int(seconds * 10))-\(Int(frequency)).m4a")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let sampleRate = 44_100.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        let tmp = dir.appending(path: "\(UUID().uuidString).m4a")
        do {
            let file = try AVAudioFile(forWriting: tmp, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = AVAudioFrameCount(seconds * sampleRate)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { throw ProviderError.decoding("buffer") }
            buffer.frameLength = frames
            for channel in 0..<Int(file.processingFormat.channelCount) {
                let data = buffer.floatChannelData![channel]
                for i in 0..<Int(frames) { data[i] = Float(0.2 * sin(2 * .pi * frequency * Double(i) / sampleRate)) }
            }
            try file.write(from: buffer)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.moveItem(at: tmp, to: url)
        }
        return url
    }

    /// A copy of `url` at a new path, standing in for "a fresh URL for the same media".
    static func copy(of url: URL) throws -> URL {
        let copy = url.deletingLastPathComponent().appending(path: "copy-\(UUID().uuidString).m4a")
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    static var missing: URL {
        FileManager.default.temporaryDirectory.appending(path: "medley-tests/does-not-exist-\(UUID().uuidString).m4a")
    }
}

// MARK: - Waiting

/// Polls `condition` on the main actor until it's true or the timeout passes. Test-only.
@MainActor
@discardableResult
func waitUntil(timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

/// Records engine events for assertions.
@MainActor
final class EventLog {
    private(set) var events: [PlaybackEvent] = []
    var states: [PlaybackState] { events.compactMap { if case .state(let s) = $0 { s } else { nil } } }
    var lastState: PlaybackState? { states.last }
    var finishedCount: Int { events.filter { if case .finished = $0 { true } else { false } }.count }
    var failures: [String] { events.compactMap { if case .failed(let m) = $0 { m } else { nil } } }
    var timeEvents: Int { events.filter { if case .time = $0 { true } else { false } }.count }

    func attach(to engine: any PlaybackEngine) {
        engine.onEvent = { [weak self] event in self?.events.append(event) }
    }

    func clear() { events = [] }
}
