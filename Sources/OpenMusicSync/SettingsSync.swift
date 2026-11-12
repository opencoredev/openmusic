import Foundation
import OpenMusicCore
import Observation

/// A synced setting (`settings:list`), opened: JSON text per key, last write wins. On the server the value is sealed
/// under the vault key (`SealedSettingEntry`); only devices that hold the key sync settings.
public struct SettingEntry: Codable, Sendable, Hashable {
    public var key: String
    public var value: String
    public var updatedAt: ServerMillis
    public var updatedBy: DeviceID
    /// The writer's id for this write (nil for writers that don't send one).
    public var writeId: String?

    public init(key: String, value: String, updatedAt: ServerMillis, updatedBy: DeviceID, writeId: String? = nil) {
        self.key = key
        self.value = value
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.writeId = writeId
    }
}

/// A settings row as the server has it: the value sealed (kind `setting`, the key and `updatedBy` bound in).
struct SealedSettingEntry: Decodable, Sendable, Hashable {
    var key: String
    var value: SealedContent
    var updatedAt: ServerMillis
    var updatedBy: DeviceID
    var writeId: String?
}

/// What `SettingsSync` needs from the service. `SyncService` is the real one.
@MainActor
public protocol SettingsEndpoint: AnyObject {
    var selfID: DeviceID? { get }
    /// nil until the first `settings:list` result arrived.
    var settingEntries: [SettingEntry]? { get }
    /// Writes one setting; `writeId` makes a retry of the same write idempotent. With `ifAbsent` the write only
    /// happens when the library has no value for the key yet. Returns the server time of the stored value.
    func putSetting(_ key: String, value: String, writeId: String, ifAbsent: Bool) async throws -> ServerMillis
}

/// Library-wide settings: playback preferences and recent searches. Each key syncs on its own and the last write (by
/// server time) wins. Volume and output device stay per device. Values are sealed under the vault key by the service
/// (`SyncService.putSetting`), so a device without the key doesn't sync settings until it has it.
///
/// - `bind(_:)` keeps a `PlaybackSettings` in sync: Sound Check, crossfade, autoplay and the sleep-timer preset.
/// - `set(_:_:)` and `observe(_:_:)` sync any other `Codable` value, such as `recentSearchesKey`.
/// A value arriving from another device is applied without being sent back; on first sync the library's
/// value wins over this device's, and keys the library doesn't have yet are uploaded from here.
/// While a local write of a key is pending or in flight, values arriving for that key wait. Once it settles, the
/// server's committed value (the newest entry, whoever wrote it) is compared with the local one and adopted when
/// they differ, so two devices writing at once end up with the same value.
@MainActor
@Observable
public final class SettingsSync {
    public static let recentSearchesKey = "search.recent"

    /// The playback preferences that sync. Volume and output device are deliberately absent.
    public enum PlaybackKey: String, CaseIterable, Sendable {
        case normalizeVolume = "playback.normalizeVolume"
        case crossfadeSeconds = "playback.crossfadeSeconds"
        case autoplay = "playback.autoplay"
        case sleepTimerMinutes = "playback.sleepTimerMinutes"
    }

    /// Remote changes applied here, newest last (diagnostics and the probe).
    public private(set) var appliedCount = 0
    @ObservationIgnored public var onApply: (@MainActor (_ key: String, _ value: String, _ latencyMs: Double?) -> Void)?

    @ObservationIgnored weak var endpoint: (any SettingsEndpoint)?
    /// The value this device has for each key (set here or adopted from the library).
    @ObservationIgnored private var local: [String: String] = [:]
    /// The newest committed value the server reported for each key.
    @ObservationIgnored private var committed: [String: (value: String, updatedAt: ServerMillis)] = [:]
    @ObservationIgnored private var observers: [String: [@MainActor (String) -> Void]] = [:]
    /// Keys this device has a local value for, read when the library doesn't have the key yet.
    @ObservationIgnored private var localValues: [String: @MainActor () -> String?] = [:]
    /// The local write of each key that is debouncing or in flight.
    @ObservationIgnored private var writes: [String: (id: String, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var playback: PlaybackSettings?
    @ObservationIgnored private var initialDone = false
    /// Bumped by `beginSession`; writes started earlier are dropped.
    @ObservationIgnored private var session = 0
    @ObservationIgnored var clock: (@MainActor () -> ServerMillis)?

    public static let debounce: Duration = .milliseconds(400)

    public convenience init(endpoint: any SettingsEndpoint) {
        self.init()
        self.endpoint = endpoint
    }

    init() {}

    // MARK: Generic values

    /// This device's value for `key` (the library's once synced), decoded.
    public func value<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let text = local[key] ?? committed[key]?.value else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(text.utf8))
    }

    /// Sets `key` for the whole library (debounced by 400 ms per key). Equal to what is synced: nothing is sent.
    public func set<T: Encodable>(_ key: String, _ value: T) {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return }
        upload(key, text)
    }

    /// Calls `handler` with each value of `key` that arrives from another device (JSON text; decode it with
    /// `JSONDecoder`). `current` supplies this device's value for the first sync when the library has none.
    public func observe(_ key: String, current: (@MainActor () -> String?)? = nil, _ handler: @escaping @MainActor (String) -> Void) {
        observers[key, default: []].append(handler)
        if let current { localValues[key] = current }
        guard initialDone else { return }
        // Bound after the library's values arrived: the library's value wins, else this device's goes up.
        if let text = local[key] ?? committed[key]?.value {
            local[key] = text
            handler(text)
        } else if let text = current?() {
            upload(key, text, debounce: false, ifAbsent: true)
        }
    }

    /// Convenience for recent searches: `handler` gets the library's list; call `set(recentSearchesKey, list)` on change.
    public func observeRecentSearches(current: @escaping @MainActor () -> [String], _ handler: @escaping @MainActor ([String]) -> Void) {
        observe(Self.recentSearchesKey, current: { Self.json(current()) }) { text in
            if let list = try? JSONDecoder().decode([String].self, from: Data(text.utf8)) { handler(list) }
        }
    }

    // MARK: PlaybackSettings

    /// Syncs `settings` both ways. Call once at launch.
    public func bind(_ settings: PlaybackSettings) {
        playback = settings
        for key in PlaybackKey.allCases {
            observe(key.rawValue, current: { [weak self] in self?.playbackValue(key) }) { [weak self] text in
                self?.applyPlayback(key, text)
            }
        }
        trackPlayback()
    }

    private func playbackValue(_ key: PlaybackKey) -> String? {
        guard let p = playback else { return nil }
        return switch key {
        case .normalizeVolume: Self.json(p.normalizeVolume)
        case .crossfadeSeconds: Self.json(p.crossfadeSeconds)
        case .autoplay: Self.json(p.autoplay)
        case .sleepTimerMinutes: Self.json(p.sleepTimerMinutes)
        }
    }

    private func applyPlayback(_ key: PlaybackKey, _ text: String) {
        guard let p = playback else { return }
        let data = Data(text.utf8)
        switch key {
        case .normalizeVolume: if let v = try? JSONDecoder().decode(Bool.self, from: data), v != p.normalizeVolume { p.normalizeVolume = v }
        case .crossfadeSeconds: if let v = try? JSONDecoder().decode(Double.self, from: data), v != p.crossfadeSeconds { p.crossfadeSeconds = v }
        case .autoplay: if let v = try? JSONDecoder().decode(Bool.self, from: data), v != p.autoplay { p.autoplay = v }
        case .sleepTimerMinutes: if let v = try? JSONDecoder().decode(Int.self, from: data), v != p.sleepTimerMinutes { p.sleepTimerMinutes = v }
        }
    }

    private func trackPlayback() {
        guard let p = playback else { return }
        withObservationTracking {
            _ = (p.normalizeVolume, p.crossfadeSeconds, p.autoplay, p.sleepTimerMinutes)
        } onChange: { [weak self] in
            // onChange runs before the new value is stored; read it on the next turn.
            Task { @MainActor [weak self] in
                guard let self else { return }
                for key in PlaybackKey.allCases {
                    if let text = self.playbackValue(key) { self.upload(key.rawValue, text) }
                }
                self.trackPlayback()
            }
        }
    }

    // MARK: Sync

    /// Starts over for another library (or none): drops pending writes and everything known about the old library.
    /// The next `apply` is a first sync again.
    func beginSession() {
        session += 1
        for write in writes.values { write.task.cancel() }
        writes = [:]
        local = [:]
        committed = [:]
        initialDone = false
    }

    /// Applies the library's settings (the service calls it on every `settings:list` result it could open). `present`
    /// is every key the library has, opened or not (nil: those of `entries`): a key whose value didn't open here (sealed
    /// under a key this device hasn't taken yet) is never filled in from this device as if the library lacked it.
    public func apply(_ entries: [SettingEntry], present: Set<String>? = nil) {
        for entry in entries {
            if let known = committed[entry.key], entry.updatedAt <= known.updatedAt { continue }
            committed[entry.key] = (entry.value, entry.updatedAt)
            reconcile(entry.key)
        }
        // First sync: keys the library doesn't have yet are uploaded from here.
        guard !initialDone, endpoint?.settingEntries != nil else { return }
        initialDone = true
        let present = present ?? Set(entries.map(\.key))
        for (key, current) in localValues where !present.contains(key) {
            if let text = current() { upload(key, text, debounce: false, ifAbsent: true) }
        }
    }

    /// Makes the local value the committed one, unless a local write of the key is still pending.
    private func reconcile(_ key: String) {
        guard writes[key] == nil, let committed = committed[key], local[key] != committed.value else { return }
        local[key] = committed.value
        for handler in observers[key] ?? [] { handler(committed.value) }
        appliedCount += 1
        onApply?(key, committed.value, clock.map { $0() - committed.updatedAt })
    }

    /// `ifAbsent`: a first-sync fill-in for a key the library seemed to lack. If another device filled it in first,
    /// the server keeps that value and this device adopts it when it arrives.
    private func upload(_ key: String, _ text: String, debounce: Bool = true, ifAbsent: Bool = false) {
        // Before the first sync, the library's values haven't arrived; they win, so hold local changes.
        guard initialDone || !debounce else { return }
        guard local[key] != text else { return }
        local[key] = text
        writes[key]?.task.cancel()
        let id = UUID().uuidString
        let session = self.session
        let task = Task { [weak self] in
            if debounce { try? await Task.sleep(for: SettingsSync.debounce) }
            guard !Task.isCancelled, let self, session == self.session else { return }
            if let endpoint = self.endpoint, let text = self.local[key] {
                // A fill-in may not have been stored; the live query brings whatever was.
                if let at = try? await endpoint.putSetting(key, value: text, writeId: id, ifAbsent: ifAbsent), !ifAbsent,
                   session == self.session, at > self.committed[key]?.updatedAt ?? 0 {
                    self.committed[key] = (text, at)
                }
            }
            // A newer local change replaced this write: it settles that key instead.
            guard session == self.session, self.writes[key]?.id == id else { return }
            self.writes[key] = nil
            self.reconcile(key)
        }
        writes[key] = (id, task)
    }

    static func json<T: Encodable>(_ value: T) -> String? {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Waits for debounced uploads (tests).
    func settle() async {
        var waited: Set<String> = []
        while let write = writes.values.first(where: { !waited.contains($0.id) }) {
            waited.insert(write.id)
            await write.task.value
        }
    }
}
