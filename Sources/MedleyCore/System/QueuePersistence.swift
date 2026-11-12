#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation

/// Reads and writes `PlayerSnapshot` JSON. An actor, so encoding and disk I/O stay off the main actor.
public actor QueueStore {
    public nonisolated let url: URL
    /// Shared by the actor's saves and the synchronous `writeNow`, so the two can't interleave.
    private nonisolated let order = WriteOrder()

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/OpenMusic/queue.json`
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return base.appending(path: ProductInfo.folderName, directoryHint: .isDirectory).appending(path: "queue.json")
    }

    public func load() -> PlayerSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(PlayerSnapshot.self, from: data),
              snapshot.version <= PlayerSnapshot.currentVersion else { return nil }
        return snapshot
    }

    public func save(_ snapshot: PlayerSnapshot) throws {
        try order.write(snapshot, to: url, generation: nil)
    }

    /// Saves unless a snapshot with a later `generation` was already written. Returns whether it wrote.
    @discardableResult
    func save(_ snapshot: PlayerSnapshot, generation: Int) throws -> Bool {
        try order.write(snapshot, to: url, generation: generation)
    }

    /// Synchronous `save(_:generation:)`, for the app going away where there's no time to hop actors.
    @discardableResult
    nonisolated func writeNow(_ snapshot: PlayerSnapshot, generation: Int) throws -> Bool {
        try order.write(snapshot, to: url, generation: generation)
    }

    public func clear() {
        order.remove(url)
    }

    /// Synchronous write, for app termination where there's no time to hop actors.
    public nonisolated static func write(_ snapshot: PlayerSnapshot, to url: URL) throws {
        try writeData(JSONEncoder().encode(snapshot), to: url)
    }

    fileprivate nonisolated static func writeData(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }
}

/// One write at a time, and never an older snapshot over a newer one. Snapshots are numbered by `QueuePersistence`
/// on the main actor when taken, so a background save that lands after the synchronous flush is dropped.
private final class WriteOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var newest = Int.min

    func write(_ snapshot: PlayerSnapshot, to url: URL, generation: Int?) throws -> Bool {
        let data = try JSONEncoder().encode(snapshot)
        lock.lock()
        defer { lock.unlock() }
        if let generation, generation <= newest { return false }
        try QueueStore.writeData(data, to: url)
        if let generation { newest = generation }
        return true
    }

    func remove(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Saves the queue, position, shuffle and repeat whenever they change (debounced), and puts them back at launch,
/// paused at the saved position.
@MainActor
public final class QueuePersistence {
    public let store: QueueStore
    private weak var player: PlayerController?
    private let scheduler: any PlaybackScheduler
    private let debounce: TimeInterval
    /// While playing, the position is saved this often so a crash loses little.
    private let playingInterval: TimeInterval
    private var pending: ScheduledAction?
    private var pendingFireDate: Date?
    private var handlerID: UUID?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var saveTask: Task<Void, Never>?
    /// Numbers snapshots in the order they're taken; the store keeps only the newest.
    private var generation = 0
    private(set) var saveCount = 0

    public init(player: PlayerController, store: QueueStore, scheduler: (any PlaybackScheduler)? = nil, debounce: TimeInterval = 1.5, playingInterval: TimeInterval = 20) {
        self.player = player
        self.store = store
        self.scheduler = scheduler ?? SystemScheduler()
        self.debounce = debounce
        self.playingInterval = playingInterval
    }

    /// Load the saved snapshot into the player. Returns false when there was nothing to restore.
    @discardableResult
    public func restore() async -> Bool {
        guard let snapshot = await store.load(), let player else { return false }
        player.restore(snapshot)
        return true
    }

    /// Start saving on changes and on app termination.
    public func start() {
        guard handlerID == nil, let player else { return }
        handlerID = player.addChangeHandler { [weak self] change in
            self?.playerChanged(change)
        }
        // iOS suspends and later kills apps without a terminate notification, so save when going to the background too.
        lifecycleObservers = Self.lifecycleNotifications.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushSynchronously() }
            }
        }
    }

    private static var lifecycleNotifications: [Notification.Name] {
        #if os(macOS)
        [NSApplication.willTerminateNotification]
        #else
        [UIApplication.willTerminateNotification, UIApplication.didEnterBackgroundNotification]
        #endif
    }

    public func stop() {
        if let handlerID { player?.removeChangeHandler(handlerID) }
        handlerID = nil
        for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
        lifecycleObservers = []
        pending?.cancel()
        pending = nil
    }

    /// Save now, skipping the debounce.
    public func flush() async {
        pending?.cancel()
        pending = nil
        await saveTask?.value
        guard let snapshot = player?.snapshot() else { return }
        saveCount += 1
        generation += 1
        try? await store.save(snapshot, generation: generation)
    }

    /// Waits for background saves already started. For tests.
    func waitForPendingSaves() async {
        await saveTask?.value
    }

    private func playerChanged(_ change: PlayerChange) {
        scheduleSave(after: debounce)
    }

    private func scheduleSave(after delay: TimeInterval) {
        // Throttle: the first change schedules a save and later ones ride along with it,
        // unless they need it sooner (a pause shouldn't wait for the slow while-playing save).
        let fireDate = scheduler.now.addingTimeInterval(delay)
        if pending != nil, let pendingFireDate, pendingFireDate <= fireDate { return }
        pending?.cancel()
        pendingFireDate = fireDate
        pending = scheduler.schedule(after: delay) { [weak self] in self?.saveNow() }
    }

    private func saveNow() {
        pending = nil
        pendingFireDate = nil
        guard let player else { return }
        let snapshot = player.snapshot()
        saveCount += 1
        generation += 1
        let generation = generation
        let store = store
        let previous = saveTask
        saveTask = Task {
            await previous?.value
            try? await store.save(snapshot, generation: generation)
        }
        if player.isPlaying { scheduleSave(after: playingInterval) }
    }

    /// The app is going to the background or quitting: write now. A background save still queued holds an older
    /// snapshot and is dropped when it runs.
    func flushSynchronously() {
        pending?.cancel()
        pending = nil
        guard let snapshot = player?.snapshot() else { return }
        generation += 1
        try? store.writeNow(snapshot, generation: generation)
    }
}
