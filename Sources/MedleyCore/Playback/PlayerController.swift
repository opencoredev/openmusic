import Foundation
import Observation

/// The one place playback is controlled from. Owns the queue and routes each track to its provider's engine.
///
/// Queue model: `queue` holds the entries before `currentIndex` (`previousEntries`), the current entry, and
/// Up Next (after it). Entries come from the played context (album/playlist), from the user (Play Next, Add
/// to Queue, insert), or from autoplay radio. Shuffle reorders only context entries in Up Next; user-queued
/// entries stay in front and autoplay entries stay at the end. Earlier entries are never reordered, so
/// Previous walks back through the queue in order. What the listener actually heard is a separate list,
/// `listeningHistory`: starting song 5 of an album doesn't mean songs 1–4 played.
@MainActor
@Observable
public final class PlayerController {
    // MARK: Published state

    public private(set) var queue: [QueueEntry] = []
    /// Index into `queue` of the current entry, nil when nothing is loaded.
    public private(set) var currentIndex: Int?
    public private(set) var state: PlaybackState = .idle
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval?
    public private(set) var lastError: String?
    /// Tracks the listener heard for 30 s (or half their length), newest first, one entry per track.
    /// Includes the current song once it counts; `listeningHistory` is the list to show.
    public private(set) var recentlyPlayed: [PlayedTrack] = []
    public private(set) var sleepTimer: SleepTimer = .off

    public var shuffle: Bool {
        get { shuffleEnabled }
        set { setShuffle(newValue) }
    }

    public var repeatMode: RepeatMode = .off {
        didSet { if repeatMode != oldValue { queueDidChange() } }
    }

    /// Continue with radio tracks when the queue runs out.
    public var autoplay = true {
        didSet { if autoplay && !oldValue { extendWithRadioIfNeeded() } }
    }

    /// 0...1
    public var volume: Float {
        get { volumeLevel }
        set {
            volumeLevel = max(0, min(1, newValue))
            activeEngine?.volume = volumeLevel
        }
    }

    /// Loudness normalization for engines that support it (`ConfigurableAudioEngine`).
    public var normalizationEnabled = true { didSet { applyAudioSettingsToAllEngines() } }
    /// Crossfade in seconds, 0...12. 0 (the default) means gapless-style handoff with no overlap.
    public var crossfadeDuration: TimeInterval {
        get { crossfadeSeconds }
        set {
            crossfadeSeconds = max(0, min(Self.maxCrossfade, newValue))
            applyAudioSettingsToAllEngines()
        }
    }
    /// CoreAudio output device UID, nil for the system default.
    public var outputDeviceUID: String? { didSet { applyAudioSettingsToAllEngines() } }

    /// Called once each time a track counts as played (see `recentlyPlayed`). Providers can report history here.
    @ObservationIgnored public var onTrackPlayed: (@MainActor (PlayedTrack) -> Void)?

    // MARK: Derived state

    public var current: Track? { currentEntry?.track }
    public var currentEntry: QueueEntry? { currentIndex.flatMap { queue.indices.contains($0) ? queue[$0] : nil } }
    /// Where the current entry came from.
    public var currentContext: PlaybackContext? { currentEntry?.context }
    /// "Playing from <album/playlist>", or nil when the current entry has no context.
    public var sourceLabel: String? { currentContext?.label }
    /// Index in `queue` where Up Next begins. Use it to convert Up Next list offsets to queue indices.
    public var upNextStartIndex: Int { currentIndex.map { min($0 + 1, queue.count) } ?? 0 }
    public var upNext: ArraySlice<QueueEntry> { queue[upNextStartIndex...] }
    /// Queue entries before the current one, in queue order. Previous walks back through these. Not a
    /// record of listening: when a list starts at its fifth song, the first four are here but never played.
    public var previousEntries: ArraySlice<QueueEntry> { currentIndex.map { queue.prefix(upTo: min($0, queue.count)) } ?? [] }

    /// Songs the listener actually heard, newest first: the queue panel's History.
    ///
    /// The rule follows Spotify's stream count: a song is listed once it has played for 30 seconds of
    /// listening time, or half its length if that's shorter. Seeking ahead doesn't add listening time, so a
    /// song skipped or scrubbed through sooner never appears, and neither do earlier queue entries that
    /// never played. One entry per song (playing it again moves it to the top). It outlives the queue: a new
    /// album or playlist doesn't clear it. Capped at `maxRecentlyPlayed` and saved with the queue. The song
    /// playing now isn't listed while it plays, even if it was heard before; it's Now Playing.
    public var listeningHistory: [PlayedTrack] {
        guard let id = current?.id else { return recentlyPlayed }
        return recentlyPlayed.filter { $0.track.id != id }
    }
    public var isPlaying: Bool { state == .playing || state == .buffering || (state == .loading && loadAutoplays) }
    /// Seconds until the sleep timer pauses playback, nil when it isn't a timed one.
    public var sleepTimerRemaining: TimeInterval? {
        guard case .at(let date) = sleepTimer else { return nil }
        return max(0, date.timeIntervalSince(scheduler.now))
    }

    // MARK: Wiring

    @ObservationIgnored private var providers: [ProviderID: any MusicProvider] = [:]
    @ObservationIgnored private var activeEngine: (any PlaybackEngine)?
    @ObservationIgnored private let scheduler: any PlaybackScheduler
    @ObservationIgnored private var changeHandlers: [UUID: @MainActor (PlayerChange) -> Void] = [:]

    private var shuffleEnabled = false
    private var volumeLevel: Float = 0.8
    private var crossfadeSeconds: TimeInterval = 0
    /// Rank of each entry before shuffle was turned on.
    @ObservationIgnored private var originalRank: [UUID: Int]?

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadToken = 0
    private var loadAutoplays = true
    /// True after `restore` (or `stop`) until the current entry is loaded into an engine.
    @ObservationIgnored private var needsLoad = false
    @ObservationIgnored private var consecutiveFailures = 0

    @ObservationIgnored private var radioTask: Task<Void, Never>?
    /// Set while the queue ran out and the player waits on a radio fetch to move on: whether the next
    /// track should play (true) or be cued paused (false). nil when no advance is pending.
    @ObservationIgnored private var pendingRadioAdvance: Bool?
    /// Bumped whenever the queue is replaced, so a radio fetch for an old queue is discarded.
    @ObservationIgnored private var queueGeneration = 0
    @ObservationIgnored private var exhaustedRadioSeed: String?

    @ObservationIgnored private var sleepAction: ScheduledAction?

    @ObservationIgnored private var listenedSeconds: TimeInterval = 0
    @ObservationIgnored private var lastTickTime: TimeInterval = 0
    @ObservationIgnored private var playRecorded = false

    public static let maxRecentlyPlayed = 100
    public static let maxRadioBatch = 25
    public static let maxCrossfade: TimeInterval = 12
    static let maxConsecutiveFailures = 5

    public init(scheduler: (any PlaybackScheduler)? = nil) {
        self.scheduler = scheduler ?? SystemScheduler()
    }

    public func register(_ provider: any MusicProvider) {
        providers[provider.id] = provider
        let engine = provider.playbackEngine
        applyAudioSettings(to: engine)
        engine.onEvent = { [weak self, weak engine] event in
            guard let self, let engine, engine === self.activeEngine else { return }
            self.handle(event)
        }
        if let reporting = engine as? any DurationReportingEngine {
            // Not limited to the active engine: the length of a prepared next track is worth keeping too.
            reporting.onDurationResolved = { [weak self] trackID, seconds in
                self?.learnStreamDuration(seconds, for: trackID)
            }
        }
    }

    public func provider(for id: ProviderID) -> (any MusicProvider)? { providers[id] }

    /// Subscribe to coarse player changes. Keep the returned id to unsubscribe.
    @discardableResult
    public func addChangeHandler(_ handler: @escaping @MainActor (PlayerChange) -> Void) -> UUID {
        let id = UUID()
        changeHandlers[id] = handler
        return id
    }

    public func removeChangeHandler(_ id: UUID) {
        changeHandlers[id] = nil
    }

    // MARK: Queue commands

    /// Replace the queue with `tracks` and start playing.
    /// - Parameters:
    ///   - index: the track to start with. nil starts at the first track, or a random one when shuffling.
    ///   - shuffled: true/false turns shuffle on/off; nil keeps the current shuffle setting.
    ///   - context: shown as "Playing from <title>".
    public func play(_ tracks: [Track], startAt index: Int? = nil, shuffled: Bool? = nil, from context: PlaybackContext? = nil) {
        let playable = tracks.indices.filter { tracks[$0].isPlayable }
        guard !playable.isEmpty else { return }
        let useShuffle = shuffled ?? shuffleEnabled

        // The first playable track at or after the requested index.
        let startSource: Int
        if let index {
            startSource = playable.first { $0 >= index } ?? playable[0]
        } else if useShuffle {
            startSource = playable.randomElement() ?? playable[0]
        } else {
            startSource = playable[0]
        }

        learnCatalogDurations(tracks)
        var entries: [QueueEntry] = []
        var start = 0
        for i in playable {
            if i == startSource { start = entries.count }
            entries.append(QueueEntry(track: withKnownDuration(tracks[i]), context: context))
        }

        resetQueueState()
        shuffleEnabled = useShuffle
        if useShuffle {
            originalRank = Self.rankMap(entries)
            let first = entries.remove(at: start)
            entries = [first] + entries.shuffled()
            start = 0
        }
        queue = entries
        currentIndex = nil
        notify(.queue)
        startEntry(at: start)
    }

    public func play(_ track: Track, from context: PlaybackContext? = nil) { play([track], from: context) }

    /// Replace the queue with `entries` exactly as given (uids, flags and contexts kept, nothing reshuffled), make
    /// `index` current and load it at `position`. With `autoplay: false` the track is cued paused once the engine is
    /// ready, so a caller can seek to a fresher position and then `resume()`. Used by cross-device handoff.
    public func load(_ entries: [QueueEntry], at index: Int, position: TimeInterval, shuffle: Bool, repeatMode: RepeatMode, autoplay: Bool) {
        guard entries.indices.contains(index) else { return }
        learnCatalogDurations(entries.map(\.track))
        resetQueueState()
        shuffleEnabled = shuffle
        self.repeatMode = repeatMode
        queue = entries.map { entry in
            var e = entry
            e.track = withKnownDuration(entry.track)
            return e
        }
        currentIndex = nil
        notify(.queue)
        startEntry(at: index, startAt: max(0, position), autoplay: autoplay)
    }

    /// Start a radio station seeded by `seed`. The seed plays first.
    public func playRadio(seed: Track) async {
        guard let provider = providers[seed.provider] else { return fail("\(seed.provider.displayName) isn't available.") }
        let context = PlaybackContext.radio(title: seed.title, seedID: seed.providerID, provider: seed.provider)
        do {
            let tracks = try await provider.radio(seed: seed)
            learnCatalogDurations(tracks)
            var seen: Set<String> = [seed.id]
            play([seed] + tracks.filter { seen.insert($0.id).inserted }, startAt: 0, shuffled: false, from: context)
        } catch {
            play([seed], from: context)
        }
    }

    /// Start a radio from an artist/playlist seed (`ArtistDetail.radioSeed`, a playlist id).
    public func playRadio(seedID: String, provider id: ProviderID, title: String) async {
        guard let provider = providers[id] else { return fail("\(id.displayName) isn't available.") }
        do {
            let tracks = try await provider.radio(seedID: seedID)
            play(Self.dedupe(tracks), startAt: 0, shuffled: false, from: .radio(title: title, seedID: seedID, provider: id))
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Play `track` now, keeping the rest of the queue: it goes in right after the current entry and starts,
    /// and Up Next carries on after it. Used for songs picked from History.
    public func playNow(_ track: Track, from context: PlaybackContext? = nil) {
        guard track.isPlayable else { return }
        guard currentIndex != nil else { return play([track], from: context) }
        // A radio fetch still running at the end of the queue would otherwise advance past this song when it
        // lands. It still fills Up Next.
        if pendingRadioAdvance != nil { pendingRadioAdvance = nil }
        let at = upNextStartIndex
        insertUserEntries([track], at: at, context: context)
        startEntry(at: at)
    }

    /// Insert right after the current entry ("Play Next").
    public func playNext(_ tracks: [Track], from context: PlaybackContext? = nil) {
        guard currentIndex != nil else { return play(tracks, from: context) }
        insertUserEntries(tracks, at: upNextStartIndex, context: context)
    }

    /// Add after everything the user and the context queued, before autoplay entries ("Play Later").
    public func addToQueue(_ tracks: [Track], from context: PlaybackContext? = nil) {
        guard currentIndex != nil else { return play(tracks, from: context) }
        let firstAuto = queue.indices.dropFirst(upNextStartIndex).first { queue[$0].isAutoplay } ?? queue.count
        insertUserEntries(tracks, at: firstAuto, context: context)
    }

    /// Insert at an absolute `queue` index. Indices at or before the current entry go to the start of Up Next.
    public func insert(_ tracks: [Track], at index: Int, from context: PlaybackContext? = nil) {
        guard currentIndex != nil else { return play(tracks, from: context) }
        insertUserEntries(tracks, at: max(upNextStartIndex, min(index, queue.count)), context: context)
    }

    /// Insert at an offset within `upNext` (0 = play next). Convenience for drag and drop into the Up Next list.
    public func insert(_ tracks: [Track], atUpNextOffset offset: Int, from context: PlaybackContext? = nil) {
        insert(tracks, at: upNextStartIndex + max(0, offset), from: context)
    }

    /// Remove an entry. Removing the current entry moves on to the next one (keeping play/pause state).
    public func remove(_ uid: UUID) {
        remove([uid])
    }

    public func remove(_ uids: some Collection<UUID>) {
        let doomed = Set(uids)
        guard !doomed.isEmpty, queue.contains(where: { doomed.contains($0.uid) }) else { return }
        let currentUID = currentEntry?.uid
        let removingCurrent = currentUID.map(doomed.contains) ?? false

        if removingCurrent, let c = currentIndex {
            // The new current is the first surviving entry after the old one.
            let autoplay = shouldAutoplayOnSkip
            let nextUID = queue[(c + 1)...].first { !doomed.contains($0.uid) }?.uid
            queue.removeAll { doomed.contains($0.uid) }
            originalRank = originalRank?.filter { !doomed.contains($0.key) }
            currentIndex = nil
            if let nextUID, let n = queue.firstIndex(where: { $0.uid == nextUID }) {
                notify(.queue)
                go(to: n, autoplay: autoplay)
            } else if queue.isEmpty {
                clearQueue()
            } else {
                currentIndex = queue.count - 1
                endQueue()
                notify(.queue)
                notify(.track)
            }
            return
        }

        queue.removeAll { doomed.contains($0.uid) }
        originalRank = originalRank?.filter { !doomed.contains($0.key) }
        currentIndex = currentUID.flatMap { uid in queue.firstIndex { $0.uid == uid } }
        queueDidChange()
    }

    /// Remove Up Next entries by their offsets within `upNext`.
    public func removeUpNext(atOffsets offsets: IndexSet) {
        let base = upNextStartIndex
        remove(offsets.compactMap { queue.indices.contains(base + $0) ? queue[base + $0].uid : nil })
    }

    /// SwiftUI `onMove` semantics on absolute `queue` indices.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let valid = source.filter { queue.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let destination = max(0, min(destination, queue.count))
        let currentUID = currentEntry?.uid
        let moving = valid.map { queue[$0] }
        var remaining = queue.enumerated().filter { !valid.contains($0.offset) }.map(\.element)
        let removedBefore = valid.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: min(destination - removedBefore, remaining.count))
        guard remaining.map(\.uid) != queue.map(\.uid) else { return }
        queue = remaining
        currentIndex = currentUID.flatMap { uid in queue.firstIndex { $0.uid == uid } }
        queueDidChange()
    }

    /// SwiftUI `onMove` semantics on offsets within `upNext`.
    public func moveUpNext(fromOffsets source: IndexSet, toOffset destination: Int) {
        let base = upNextStartIndex
        move(fromOffsets: IndexSet(source.map { $0 + base }), toOffset: destination + base)
    }

    /// Moves the Up Next entry `uid` by `delta` places (negative: earlier), clamped to Up Next, found where it is
    /// now: a drag or menu that started before playback advanced or the queue changed still moves the song it
    /// started on. Returns false, changing nothing, when the entry is no longer in Up Next.
    @discardableResult
    public func moveUpNext(uid: UUID, by delta: Int) -> Bool {
        let next = Array(upNext)
        guard let from = next.firstIndex(where: { $0.uid == uid }) else { return false }
        let target = max(0, min(next.count - 1, from + delta))
        guard target != from else { return true }
        moveUpNext(fromOffsets: IndexSet(integer: from), toOffset: target > from ? target + 1 : target)
        return true
    }

    /// What "Clear Up Next" removed, so it can be put back (`restoreUpNext`).
    public struct ClearedUpNext: Sendable {
        /// The removed entries, in queue order, flags and context unchanged.
        public let entries: [QueueEntry]
        /// Every entry after the current one before the clear, removed or kept, in order: where to put them back.
        let order: [UUID]
        /// The removed entries' places in the order from before shuffle was turned on, if it was on.
        let ranks: [UUID: Int]
        /// The queue they came from (`queueGeneration`): once another album or playlist replaced it, they don't
        /// come back into the new one.
        let generation: Int
    }

    /// Empty the Up Next group: everything after the current song that autoplay didn't add (the rest of the album or
    /// playlist and what the listener queued). Autoplay's entries stay, and the current song plays on. Returns what
    /// was removed, for undo; nil when there was nothing to remove.
    ///
    /// `includingAutoplay` empties everything after the current song and stops a radio fetch, for a list that shows
    /// one group (the iOS app's Playing Next).
    @discardableResult
    public func clearUpNext(includingAutoplay: Bool = false) -> ClearedUpNext? {
        if includingAutoplay {
            // As before for that list: with nothing current, the whole queue goes.
            guard currentIndex != nil else { clearQueue(); return nil }
            cancelRadio()
        }
        return clearUpNext { includingAutoplay || !$0.isAutoplay }
    }

    /// Removes the Up Next entries `include` picks (never the current one), keeping what's needed to put them back.
    private func clearUpNext(where include: (QueueEntry) -> Bool) -> ClearedUpNext? {
        let after = Array(upNext)
        let removed = after.filter(include)
        guard !removed.isEmpty else { return nil }
        let doomed = Set(removed.map(\.uid))
        let ranks = originalRank?.filter { doomed.contains($0.key) } ?? [:]
        let currentUID = currentEntry?.uid
        queue.removeAll { doomed.contains($0.uid) }
        originalRank = originalRank?.filter { !doomed.contains($0.key) }
        currentIndex = currentUID.flatMap { uid in queue.firstIndex { $0.uid == uid } }
        // No radio fetch here: Autoplay carries on as it was (and fills up as usual when the song ends), and Undo
        // gets back exactly the queue from before.
        queueDidChange()
        return ClearedUpNext(entries: removed, order: after.map(\.uid), ranks: ranks, generation: queueGeneration)
    }

    /// Undo `clearUpNext`: the removed entries go back after the current song, each in its old place relative to
    /// the entries still queued from before; songs queued since stay in their group. The current song isn't
    /// touched. Entries already back in the queue (by `uid`) are skipped, so restoring twice adds nothing, and
    /// nothing comes back once a new album or playlist replaced the queue.
    public func restoreUpNext(_ cleared: ClearedUpNext) {
        guard cleared.generation == queueGeneration else { return }
        let present = Set(queue.map(\.uid))
        let missing = cleared.entries.filter { !present.contains($0.uid) }
        guard !missing.isEmpty else { return }
        let byUID = Dictionary(missing.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        let start = upNextStartIndex
        let head = Array(queue[..<start])
        let tail = Array(queue[start...])
        let tailUIDs = Set(tail.map(\.uid))
        // The old order, with what is still queued and what comes back; anything queued since goes after it.
        var rebuilt: [QueueEntry] = []
        var placed = Set<UUID>()
        let tailByUID = Dictionary(tail.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        for uid in cleared.order {
            if let entry = byUID[uid] ?? (tailUIDs.contains(uid) ? tailByUID[uid] : nil) {
                rebuilt.append(entry)
                placed.insert(uid)
            }
        }
        // Songs queued since stay in their group: the listener's before autoplay's, new autoplay songs at the end.
        let since = tail.filter { !placed.contains($0.uid) }
        let firstAuto = rebuilt.firstIndex(where: \.isAutoplay) ?? rebuilt.count
        rebuilt.insert(contentsOf: since.filter { !$0.isAutoplay }, at: firstAuto)
        rebuilt += since.filter(\.isAutoplay)
        queue = head + rebuilt
        if originalRank != nil {
            for (uid, rank) in cleared.ranks where byUID[uid] != nil { originalRank?[uid] = rank }
        }
        queueDidChange()
    }

    /// `clearUpNext`, registered with `undoManager` as "Clear Up Next": Undo puts the songs back and Redo removes
    /// those same songs again (not ones queued since).
    public func clearUpNext(undoManager: UndoManager?) {
        guard let cleared = clearUpNext() else { return }
        registerUndo(of: cleared, with: undoManager)
    }

    /// Removes queued entries after the current song ("Remove from Queue", Delete in the queue), registered with
    /// `undoManager` as "Remove “<song>”" (or "Remove 3 Songs"): Undo puts the same entries (identity, flags,
    /// context) back in their places the way Clear Up Next's Undo does, without touching the current song, and Redo
    /// removes them again. The current song and history aren't removed here (`remove(_:)` covers those).
    public func removeUpNext(_ uids: some Collection<UUID>, undoManager: UndoManager?) {
        let doomed = Set(uids)
        // The current song or one before it: removed the plain way (no undo).
        let elsewhere = doomed.subtracting(upNext.map(\.uid))
        if !elsewhere.isEmpty { remove(elsewhere) }
        guard let removed = clearUpNext(where: { doomed.contains($0.uid) }) else { return }
        registerUndo(of: removed, with: undoManager, actionName: Self.removeActionName(for: removed.entries))
    }

    /// "Remove “Espresso”", "Remove 3 Songs": the Edit menu's Undo and Redo titles for a queue removal.
    public static func removeActionName(for entries: [QueueEntry]) -> String {
        entries.count == 1 ? "Remove “\(entries[0].track.title)”" : "Remove \(entries.count) Songs"
    }

    private func registerUndo(of cleared: ClearedUpNext, with undoManager: UndoManager?, actionName: String = clearUpNextActionName) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { player in
            MainActor.assumeIsolated {
                player.restoreUpNext(cleared)
                undoManager.registerUndo(withTarget: player) { player in
                    MainActor.assumeIsolated {
                        let uids = Set(cleared.entries.map(\.uid))
                        guard let again = player.clearUpNext(where: { uids.contains($0.uid) }) else { return }
                        player.registerUndo(of: again, with: undoManager, actionName: actionName)
                    }
                }
                undoManager.setActionName(actionName)
            }
        }
        undoManager.setActionName(actionName)
    }

    public static let clearUpNextActionName = "Clear Up Next"

    /// Stop and empty the queue.
    public func clearQueue() {
        activeEngine?.stop()
        resetQueueState()
        queue = []
        currentIndex = nil
        currentTime = 0
        duration = nil
        state = .idle
        needsLoad = false
        queueDidChange()
        notify(.track)
        notify(.state)
    }

    public func jump(to uid: UUID) {
        guard let i = queue.firstIndex(where: { $0.uid == uid }) else { return }
        startEntry(at: i)
    }

    // MARK: Transport

    public func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    public func pause() {
        guard !needsLoad else { return }
        if state == .loading { loadAutoplays = false }
        // Waiting on radio after the last track: cue the next one paused when it arrives.
        if pendingRadioAdvance != nil { pendingRadioAdvance = false }
        activeEngine?.pause()
    }

    /// Play from the current position. Loads the current entry first if needed (after restore, stop, end or failure).
    public func resume() {
        guard let i = currentIndex, queue.indices.contains(i) else {
            if !queue.isEmpty { startEntry(at: 0) }
            return
        }
        if pendingRadioAdvance != nil {
            // The listener already moved past this track; play the next one once radio delivers it.
            pendingRadioAdvance = true
            return
        }
        switch state {
        case _ where needsLoad || activeEngine == nil:
            startEntry(at: i, startAt: currentTime)
        case .ended:
            startEntry(at: 0)
        case .failed:
            startEntry(at: i, startAt: currentTime)
        case .loading:
            loadAutoplays = true
            activeEngine?.play()
        default:
            activeEngine?.play()
        }
    }

    /// Stop playback but keep the queue. Play resumes the current entry from the start.
    public func stop() {
        activeEngine?.stop()
        loadTask?.cancel()
        loadToken += 1
        pendingRadioAdvance = nil
        needsLoad = true
        currentTime = 0
        state = .paused
        notify(.state)
        notify(.timing)
    }

    public func next() {
        advance(autoplay: shouldAutoplayOnSkip)
    }

    /// Restarts the track if more than 3 seconds in (or at the start of the queue), else goes back one.
    public func previous() {
        guard let i = currentIndex else { return }
        if currentTime > 3 || i == 0 {
            seek(to: 0)
        } else {
            go(to: i - 1, autoplay: shouldAutoplayOnSkip)
        }
    }

    public func seek(to seconds: TimeInterval) {
        let target = max(0, min(seconds, duration ?? .greatestFiniteMagnitude))
        if !needsLoad { activeEngine?.seek(to: target) }
        currentTime = target
        lastTickTime = target
        notify(.timing)
    }

    public func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    // MARK: Sleep timer

    /// Pause after `minutes` of wall-clock time.
    public func setSleepTimer(minutes: Double) {
        sleepAction?.cancel()
        let seconds = max(0, minutes * 60)
        sleepTimer = .at(scheduler.now.addingTimeInterval(seconds))
        sleepAction = scheduler.schedule(after: seconds) { [weak self] in self?.sleepTimerFired() }
        updatePrepareNext()
    }

    /// Pause when the current track ends. The next entry is loaded paused, so Play continues from there.
    public func setSleepTimerEndOfTrack() {
        sleepAction?.cancel()
        sleepAction = nil
        sleepTimer = .endOfTrack
        updatePrepareNext()
    }

    public func cancelSleepTimer() {
        sleepAction?.cancel()
        sleepAction = nil
        sleepTimer = .off
        updatePrepareNext()
    }

    private func sleepTimerFired() {
        sleepAction = nil
        sleepTimer = .off
        pause()
        updatePrepareNext()
    }

    // MARK: Persistence

    public func snapshot() -> PlayerSnapshot {
        let order: [UUID]? = originalRank.map { rank in rank.sorted { $0.value < $1.value }.map(\.key) }
        return PlayerSnapshot(
            queue: queue,
            currentIndex: currentIndex,
            position: currentTime,
            shuffle: shuffleEnabled,
            repeatMode: repeatMode,
            originalOrder: order,
            recentlyPlayed: recentlyPlayed,
            savedAt: scheduler.now
        )
    }

    /// Put back a saved queue, paused at the saved position. Nothing is resolved or loaded until Play,
    /// so launch stays instant and offline-safe.
    public func restore(_ snapshot: PlayerSnapshot) {
        activeEngine?.stop()
        activeEngine = nil
        resetQueueState()
        queue = snapshot.queue
        recentlyPlayed = Array(snapshot.recentlyPlayed.prefix(Self.maxRecentlyPlayed))
        shuffleEnabled = snapshot.shuffle
        if snapshot.shuffle, let order = snapshot.originalOrder {
            originalRank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        }
        repeatMode = snapshot.repeatMode
        if let i = snapshot.currentIndex, queue.indices.contains(i) {
            currentIndex = i
            duration = queue[i].track.duration
            currentTime = max(0, min(snapshot.position, duration ?? snapshot.position))
            state = .paused
            needsLoad = true
        } else {
            currentIndex = nil
            currentTime = 0
            duration = nil
            state = .idle
            needsLoad = false
        }
        lastTickTime = currentTime
        notify(.queue)
        notify(.track)
        notify(.state)
        notify(.timing)
    }

    // MARK: Internals: loading

    private func startEntry(at index: Int, startAt: TimeInterval = 0, autoplay: Bool = true) {
        guard queue.indices.contains(index) else { return }
        let track = queue[index].track
        currentIndex = index
        currentTime = startAt
        lastTickTime = startAt
        duration = track.duration
        lastError = nil
        listenedSeconds = 0
        playRecorded = false
        needsLoad = false
        loadAutoplays = autoplay
        loadToken += 1
        let token = loadToken
        loadTask?.cancel()

        guard let provider = providers[track.provider] else {
            notify(.track)
            handleLoadFailure("\(track.provider.displayName) isn't available.", token: token)
            return
        }
        let engine = provider.playbackEngine
        let previousEngine = activeEngine
        activeEngine = engine
        if let previousEngine, previousEngine !== engine {
            // Switching providers: the old engine must go quiet before the new one starts.
            previousEngine.prepareNext(nil)
            previousEngine.stop()
        }
        engine.volume = volume
        applyAudioSettings(to: engine)
        state = .loading
        notify(.track)
        notify(.state)

        loadTask = Task { [weak self] in
            // A newer command may have replaced this load before the task got to run (and already stopped
            // this engine if it switched providers). Starting it now would play over the new track.
            guard !Task.isCancelled, token == self?.loadToken else { return }
            do {
                try await engine.load(track, startAt: startAt, autoplay: autoplay)
                guard let self, token == self.loadToken else { return }
                self.updatePrepareNext()
                self.extendWithRadioIfNeeded()
            } catch {
                guard let self, token == self.loadToken, !(error is CancellationError) else { return }
                self.handleLoadFailure(error.localizedDescription, token: token)
            }
        }
    }

    /// Skips forward after a failed track, giving up after a few in a row (or once every entry failed),
    /// so a dead network or a queue of unplayable tracks can't loop forever.
    private func handleLoadFailure(_ message: String, token: Int) {
        guard token == loadToken else { return }
        lastError = message
        consecutiveFailures += 1
        let limit = min(Self.maxConsecutiveFailures, queue.count)
        if consecutiveFailures < limit, let next = nextIndex(wrapping: repeatMode == .all) {
            startEntry(at: next, autoplay: loadAutoplays)
            return
        }
        activeEngine?.stop()
        consecutiveFailures = 0
        needsLoad = true
        state = .failed
        notify(.state)
    }

    private func handle(_ event: PlaybackEvent) {
        switch event {
        case .state(let s):
            // `.ended` is decided by the controller (repeat, autoplay, sleep timer), not the engine.
            guard s != .ended, s != state else { return }
            if s == .idle && currentEntry != nil && !needsLoad { return }
            state = s
            if s == .playing { consecutiveFailures = 0; loadAutoplays = true }
            if s == .paused { loadAutoplays = false }
            notify(.state)
        case .time(let current, let total):
            let delta = current - lastTickTime
            if delta > 0 && delta <= 2 { listenedSeconds += delta }
            lastTickTime = current
            currentTime = current
            if let total, let entry = currentEntry {
                // A no-op once known (one lookup), so rows learn it even when the entry already agrees.
                knownLengths.learn(total, for: entry.track.id)
                // The stream's length wins when it's a different cut, and the queue entry follows it.
                // Checked against the entry first, so a steady tick doesn't walk the queue.
                if Self.reconciledDuration(catalog: entry.track.duration, stream: total) != entry.track.duration {
                    learnStreamDuration(total, for: entry.track.id)
                }
                let shown = Self.reconciledDuration(catalog: currentEntry?.track.duration, stream: total)
                if shown != duration {
                    duration = shown
                    notify(.timing)
                }
            }
            recordPlayIfNeeded()
        case .finished:
            trackFinished()
        case .failed(let message):
            handleLoadFailure(message, token: loadToken)
        }
    }

    private func trackFinished() {
        if sleepTimer == .endOfTrack {
            sleepTimer = .off
            if let next = nextIndex(wrapping: repeatMode == .all) {
                startEntry(at: next, autoplay: false)
            } else {
                endQueue()
            }
            return
        }
        if repeatMode == .one {
            listenedSeconds = 0
            playRecorded = false
            lastTickTime = 0
            activeEngine?.seek(to: 0)
            activeEngine?.play()
            currentTime = 0
            notify(.timing)
            return
        }
        advance(autoplay: true)
    }

    /// Skips keep the current play/pause intent: paused (or restored) stays paused, everything else plays.
    /// After the player gave up on failures, a skip tries the next track.
    private var shouldAutoplayOnSkip: Bool { state != .paused && !(needsLoad && state != .failed) }

    /// Make `index` current. When nothing is loaded (after restore/stop) and it shouldn't play, only the
    /// cursor moves and Play loads it later.
    private func go(to index: Int, autoplay: Bool) {
        guard queue.indices.contains(index) else { return }
        if needsLoad && !autoplay {
            currentIndex = index
            currentTime = 0
            lastTickTime = 0
            duration = queue[index].track.duration
            notify(.track)
            notify(.timing)
        } else {
            startEntry(at: index, autoplay: autoplay)
        }
    }

    private func advance(autoplay shouldPlay: Bool) {
        guard currentIndex != nil else { return }
        if let next = nextIndex(wrapping: repeatMode == .all) {
            go(to: next, autoplay: shouldPlay)
        } else if needsLoad {
            return
        } else if autoplay {
            pendingRadioAdvance = shouldPlay
            requestRadio()
        } else {
            endQueue()
        }
    }

    private func nextIndex(wrapping: Bool) -> Int? {
        guard let i = currentIndex else { return queue.isEmpty ? nil : 0 }
        if i + 1 < queue.count { return i + 1 }
        if wrapping, !queue.isEmpty { return 0 }
        return nil
    }

    private func endQueue() {
        activeEngine?.prepareNext(nil)
        activeEngine?.stop()
        loadToken += 1
        state = .ended
        currentTime = 0
        notify(.state)
    }

    /// Tell the engine what will play after the current entry so it can resolve and buffer it early.
    private func updatePrepareNext() {
        guard let engine = activeEngine, !needsLoad else { return }
        var next: Track?
        if repeatMode != .one, sleepTimer != .endOfTrack, let n = nextIndex(wrapping: repeatMode == .all), n != currentIndex {
            next = queue[n].track
        }
        if let n = next, providers[n.provider]?.playbackEngine !== engine { next = nil }
        engine.prepareNext(next)
    }

    private func queueDidChange() {
        updatePrepareNext()
        notify(.queue)
    }

    private func resetQueueState() {
        loadTask?.cancel()
        loadToken += 1
        queueGeneration += 1
        cancelRadio()
        originalRank = nil
        consecutiveFailures = 0
        exhaustedRadioSeed = nil
    }

    private func fail(_ message: String) {
        lastError = message
        notify(.state)
    }

    private func notify(_ change: PlayerChange) {
        for handler in changeHandlers.values { handler(change) }
    }

    // MARK: Internals: audio settings

    private func applyAudioSettingsToAllEngines() {
        for provider in providers.values { applyAudioSettings(to: provider.playbackEngine) }
    }

    private func applyAudioSettings(to engine: any PlaybackEngine) {
        guard let engine = engine as? any ConfigurableAudioEngine else { return }
        if engine.normalizationEnabled != normalizationEnabled { engine.normalizationEnabled = normalizationEnabled }
        if engine.crossfadeDuration != crossfadeDuration { engine.crossfadeDuration = crossfadeDuration }
        if engine.outputDeviceUID != outputDeviceUID { engine.outputDeviceUID = outputDeviceUID }
    }

    // MARK: Internals: queue editing

    private func insertUserEntries(_ tracks: [Track], at index: Int, context: PlaybackContext?) {
        learnCatalogDurations(tracks)
        let entries = tracks.filter(\.isPlayable).map { QueueEntry(track: withKnownDuration($0), isUserQueued: true, context: context) }
        guard !entries.isEmpty else { return }
        queue.insert(contentsOf: entries, at: max(0, min(index, queue.count)))
        if let c = currentIndex, index <= c { currentIndex = c + entries.count }
        queueDidChange()
    }

    private static func rankMap(_ entries: [QueueEntry]) -> [UUID: Int] {
        Dictionary(entries.enumerated().map { ($1.uid, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private static func dedupe(_ tracks: [Track]) -> [Track] {
        var seen: Set<String> = []
        return tracks.filter { seen.insert($0.id).inserted }
    }

    private func setShuffle(_ on: Bool) {
        guard on != shuffleEnabled else { return }
        shuffleEnabled = on
        let start = upNextStartIndex
        let head = Array(queue[..<start])
        let tail = Array(queue[start...])
        let pinned = Array(tail.prefix { $0.isUserQueued })
        let rest = tail.dropFirst(pinned.count)
        let autoEntries = rest.filter(\.isAutoplay)
        let body = rest.filter { !$0.isAutoplay }

        if on {
            originalRank = Self.rankMap(queue)
            queue = head + pinned + body.shuffled() + autoEntries
        } else {
            let rank = originalRank ?? [:]
            let position = Dictionary(body.enumerated().map { ($1.uid, $0) }, uniquingKeysWith: { a, _ in a })
            // Entries from before the shuffle return to their old order; ones added since keep theirs, after them.
            let sorted = body.sorted { a, b in
                switch (rank[a.uid], rank[b.uid]) {
                case let (ra?, rb?): ra < rb
                case (.some, nil): true
                case (nil, .some): false
                case (nil, nil): position[a.uid, default: 0] < position[b.uid, default: 0]
                }
            }
            queue = head + pinned + sorted + autoEntries
            originalRank = nil
        }
        queueDidChange()
    }

    // MARK: Internals: autoplay radio

    private func extendWithRadioIfNeeded() {
        guard autoplay, repeatMode != .all, currentIndex != nil, upNext.count < 2 else { return }
        requestRadio()
    }

    private func requestRadio() {
        guard radioTask == nil else { return } // a fetch is already running; it will honor pendingRadioAdvance
        guard autoplay, let seed = queue.last?.track, seed.id != exhaustedRadioSeed,
              let provider = providers[seed.provider], provider.capabilities.contains(.radio) else {
            if pendingRadioAdvance != nil { pendingRadioAdvance = nil; endQueue() }
            return
        }
        let generation = queueGeneration
        radioTask = Task { [weak self] in
            let tracks = (try? await provider.radio(seed: seed)) ?? []
            guard let self, !Task.isCancelled, generation == self.queueGeneration else { return }
            self.radioTask = nil
            self.appendRadio(tracks, seed: seed)
        }
    }

    private func appendRadio(_ tracks: [Track], seed: Track) {
        // Radio listings carry lengths. Learn them before dropping songs already queued, so a queued copy
        // that arrived without one (artist top songs) gets it.
        learnCatalogDurations(tracks)
        var seen = Set(queue.map(\.track.id))
        let fresh = tracks.filter { $0.isPlayable && seen.insert($0.id).inserted }.prefix(Self.maxRadioBatch)
        if fresh.isEmpty {
            exhaustedRadioSeed = seed.id
        } else {
            queue.append(contentsOf: fresh.map { QueueEntry(track: withKnownDuration($0), isAutoplay: true, context: .autoplay) })
            queueDidChange()
        }
        if let shouldPlay = pendingRadioAdvance {
            pendingRadioAdvance = nil
            if let i = currentIndex, i + 1 < queue.count { startEntry(at: i + 1, autoplay: shouldPlay) } else { endQueue() }
        }
    }

    private func cancelRadio() {
        radioTask?.cancel()
        radioTask = nil
        pendingRadioAdvance = nil
    }

    // MARK: Durations

    /// Within this many seconds a stream's length and the catalog's describe the same recording, rounded
    /// differently. Beyond it the stream is a different cut (YouTube Music sometimes plays an album track's
    /// official video, a minute longer), and the stream's length is what the listener will hear.
    public nonisolated static let durationTolerance: TimeInterval = 2

    /// The length to show for a song whose listing says `catalog` and whose stream says `stream`: the
    /// catalog's when the two agree within `durationTolerance` (so the player matches the album page),
    /// otherwise the stream's. Either alone is used as is.
    public nonisolated static func reconciledDuration(catalog: TimeInterval?, stream: TimeInterval?) -> TimeInterval? {
        let catalog = catalog.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        guard let stream, stream.isFinite, stream > 0 else { return catalog }
        guard let catalog else { return stream }
        return abs(stream - catalog) > durationTolerance ? stream : catalog
    }

    /// Lengths learned for songs by `Track.id`: from streams (playing, or resolved early for the next song)
    /// and from listings that came with one (radio batches, albums). Fills queue entries that arrived
    /// without a length, such as artist top songs, without asking any service. Session only; the queue
    /// entries themselves keep what they learned when the queue is saved.
    @ObservationIgnored private var knownDurations: [String: TimeInterval] = [:]
    static let maxKnownDurations = 2000

    /// Real lengths heard from streams, for album, playlist, search and queue rows (`KnownLengths`).
    /// Its own store, observed per song, so learning a length never redraws rows on the time tick.
    @ObservationIgnored public let knownLengths = KnownLengths()

    /// Records the length of the stream for `trackID` and updates every queued and played copy of the song.
    func learnStreamDuration(_ seconds: TimeInterval, for trackID: String) {
        guard seconds.isFinite, seconds > 0 else { return }
        remember(seconds, for: trackID)
        knownLengths.learn(seconds, for: trackID)
        var changed = false
        for i in queue.indices where queue[i].track.id == trackID {
            let d = Self.reconciledDuration(catalog: queue[i].track.duration, stream: seconds)
            if d != queue[i].track.duration { queue[i].track.duration = d; changed = true }
        }
        for i in recentlyPlayed.indices where recentlyPlayed[i].track.id == trackID {
            let d = Self.reconciledDuration(catalog: recentlyPlayed[i].track.duration, stream: seconds)
            if d != recentlyPlayed[i].track.duration { recentlyPlayed[i].track.duration = d; changed = true }
        }
        if changed { notify(.queue) }
        // Resolved before the item reports a length: show it now rather than jump at the first tick.
        if let entry = currentEntry, entry.track.id == trackID, let d = entry.track.duration,
           Self.reconciledDuration(catalog: duration, stream: d) != duration {
            duration = d
            notify(.timing)
        }
    }

    /// Keeps the lengths a listing came with, and gives them to queued copies that have none.
    private func learnCatalogDurations(_ tracks: [Track]) {
        var learned: [String: TimeInterval] = [:]
        for t in tracks {
            guard let d = t.duration, d.isFinite, d > 0 else { continue }
            // A stream's length is better than a listing's: don't replace one.
            if knownDurations[t.id] == nil { remember(d, for: t.id); learned[t.id] = d }
        }
        guard !learned.isEmpty else { return }
        var changed = false
        for i in queue.indices where queue[i].track.duration == nil {
            if let d = learned[queue[i].track.id] { queue[i].track.duration = d; changed = true }
        }
        if changed { notify(.queue) }
    }

    private func remember(_ seconds: TimeInterval, for trackID: String) {
        if knownDurations.count >= Self.maxKnownDurations, knownDurations[trackID] == nil { knownDurations.removeAll() }
        knownDurations[trackID] = seconds
    }

    /// `track` with the length learned for it, when its own is missing or a known stream says otherwise.
    private func withKnownDuration(_ track: Track) -> Track {
        guard let known = knownDurations[track.id] else { return track }
        var t = track
        t.duration = Self.reconciledDuration(catalog: track.duration, stream: known)
        return t
    }

    // MARK: Internals: history

    private func recordPlayIfNeeded() {
        guard !playRecorded, let entry = currentEntry else { return }
        let length = duration ?? entry.track.duration
        let threshold = min(30, (length ?? .infinity) / 2)
        guard listenedSeconds >= max(1, threshold) else { return }
        playRecorded = true
        let played = PlayedTrack(track: entry.track, playedAt: scheduler.now, context: entry.context)
        recentlyPlayed.removeAll { $0.track.id == entry.track.id }
        recentlyPlayed.insert(played, at: 0)
        if recentlyPlayed.count > Self.maxRecentlyPlayed { recentlyPlayed.removeLast(recentlyPlayed.count - Self.maxRecentlyPlayed) }
        onTrackPlayed?(played)
        notify(.queue)
    }

    // MARK: Test support

    /// Waits for the in-flight load and radio fetch. Used by tests.
    func settle() async {
        for _ in 0..<10 {
            let load = loadTask
            let radio = radioTask
            await load?.value
            await radio?.value
            await Task.yield()
            if load == loadTask && radio == radioTask { return }
        }
    }
}
