import Foundation
import MedleyCore

/// One listener action on a playlist ("Remove from Playlist" on one or more songs) and every request made for it
/// afterwards: Try Again and Undo work on this one record.
///
/// It holds exactly what the service acknowledged: which songs are out, and which of the places they held (read once,
/// before the first request) are empty now. Undo puts back only places acknowledged empty, and Try Again goes on
/// toward the same goal, so no request ever inverts a change that didn't happen.
///
/// The playlist's state lives in the model (`AppModel.PlaylistEditState`), not in a notice: while a run is in flight,
/// or after one stopped partway, the playlist takes no other edit. Undo is single-level: only a settled edit (every
/// request acknowledged) goes on the undo manager, and any new playlist edit takes it off first
/// (`AppModel.purgePlaylistUndo`), so no older edit's places stay undoable.
///
/// Places can still go stale outside Medley (another device, the service's own app). So the record keeps the
/// playlist's entries as read before the first request (`before`), and every put-back first reads the playlist again
/// and compares it with what the acknowledged requests leave (`expectedEntries`): only an unchanged playlist gets songs
/// back at their places; a changed one gets "Add Back at End" (`songsToAddBack`, minus any already there).
///
/// It belongs to the account its requests went out as (`account`): when that service's session changes, the model
/// drops the record, its lock, its Undo and its notices (`AppModel.dropEditsOfChangedAccounts`).
@MainActor final class PlaylistEdit {
    enum Goal: Equatable {
        /// The removal and its Try Again: take out every song asked for (by `Track.id`).
        case remove(Set<String>)
        /// Undo: fill every place acknowledged empty.
        case putBack
    }

    let playlist: Playlist
    /// The playlist's page key (`AppModel.playlistKey`).
    let key: String
    /// The songs, each once, in the order asked for.
    let tracks: [Track]
    /// Every place the songs held before the first request, in place order (the service's entry numbers). Empty
    /// where the service can't put a song back in place: no Undo then.
    let places: [(track: Track, index: Int)]
    /// The confirmed removal's count of copies, for its notice (a service that can't put songs back).
    let entries: Int?
    /// The account the requests go out as.
    let account: PlaylistEditAccount
    /// The playlist's entries as read before the first request (empty where no places were read).
    let before: [PlaylistEntry]
    /// Per place: acknowledged empty (its song removed) and not filled again since.
    private(set) var emptied: [Bool]
    /// Per place: put back by this record (the service gave the entry a new id, so only the song is known).
    private(set) var refilled: [Bool]
    /// Songs the service acknowledged removed, none of whose places came back since.
    private(set) var songsOut: Set<String> = []
    /// What the current (or last) run of requests is for.
    private(set) var goal: Goal
    /// The places empty when the current put-back began: its notices name these.
    private(set) var putBackPlaces: [Int] = []
    /// The undo manager its settled Undo goes on. Weak: the manager owns the handler, which owns this record.
    weak var undoManager: UndoManager?
    /// The failure that stopped its last run partway, for the notice it shows again (`AppModel.failureNotice`) and
    /// the playlist page's banner.
    var failureText: String?
    /// That failure can work on a second attempt: the notice and the banner offer Try Again.
    var canRetry = false

    init(playlist: Playlist, key: String, tracks: [Track], places: [(track: Track, index: Int)], entries: Int?,
         account: PlaylistEditAccount, before: [PlaylistEntry] = []) {
        self.playlist = playlist
        self.key = key
        self.tracks = tracks
        self.places = places.sorted { $0.index < $1.index }
        self.entries = entries
        self.account = account
        self.before = before
        emptied = Array(repeating: false, count: places.count)
        refilled = emptied
        goal = .remove(Set(tracks.map(\.id)))
    }

    /// "Remove “Espresso”", "Remove 3 Songs": what the listener asked for, Edit › Undo's title.
    var actionName: String { tracks.count == 1 ? "Remove “\(tracks[0].title)”" : "Remove \(tracks.count) Songs" }

    /// There is something to put back: a place acknowledged empty.
    var canPutBack: Bool { emptied.contains(true) }

    /// The service has changed the playlist for this record: a song out (and not all back). With nothing acknowledged
    /// a failed removal leaves the playlist as it was.
    var hasChanged: Bool { !songsOut.isEmpty || canPutBack }

    /// Starts a run toward `goal`; a put-back notes the places it fills. Try Again keeps the goal and those places.
    func begin(_ goal: Goal, resuming: Bool = false) {
        if !resuming, goal == .putBack { putBackPlaces = emptied.indices.filter { emptied[$0] } }
        self.goal = goal
    }

    /// The songs of `scope` still in the playlist, as far as the service has said, in the order asked for.
    func songsToRemove(_ scope: Set<String>) -> [Track] {
        tracks.filter { scope.contains($0.id) && !songsOut.contains($0.id) }
    }

    /// The next put-back request: the first empty place and the empty places right after it (consecutive entry
    /// numbers), at most `batch`. Filling places in place order keeps every earlier place filled, so each lands at its
    /// own entry number.
    func nextPutBack(batch: Int) -> [Int] {
        guard let first = emptied.firstIndex(of: true) else { return [] }
        var run = [first]
        var next = first + 1
        while run.count < batch, next < places.count, emptied[next], places[next].index == places[first].index + run.count {
            run.append(next)
            next += 1
        }
        return run
    }

    /// Work left toward `goal`, from what the service has acknowledged.
    func hasWork(toward goal: Goal) -> Bool {
        switch goal {
        case .remove(let scope): !songsToRemove(scope).isEmpty
        case .putBack: canPutBack
        }
    }

    /// The service took these songs out: every copy, so every place they held is empty.
    func acknowledgeRemoved(_ songs: [Track]) {
        let ids = Set(songs.map(\.id))
        songsOut.formUnion(ids)
        for offset in places.indices where ids.contains(places[offset].track.id) { emptied[offset] = true }
    }

    /// The service put these places' songs back.
    func acknowledgePutBack(_ offsets: [Int]) {
        for offset in offsets {
            emptied[offset] = false
            refilled[offset] = true
            songsOut.remove(places[offset].track.id)
        }
    }

    /// The playlist as the requests the service acknowledged leave it: `before` without the places acknowledged empty,
    /// a place put back holding its song under whatever entry id the service gave it.
    func expectedEntries() -> [PlaylistEntry] {
        let offsets = Dictionary(places.indices.map { (places[$0].index, $0) }, uniquingKeysWith: { a, _ in a })
        return before.indices.compactMap { index in
            guard let offset = offsets[index] else { return before[index] }
            if emptied[offset] { return nil }
            return refilled[offset] ? .song(id: places[offset].track.id, entry: nil) : before[index]
        }
    }

    /// The playlist read now is exactly what this record's acknowledged requests left: every page read, every entry
    /// identified on both reads, the same entries in the same order. Only then do its places still mean what they
    /// meant; an entry the service doesn't identify (a `null` item) could have moved unseen, so its playlist never
    /// counts as unchanged.
    func isUnchanged(_ listing: PlaylistListing) -> Bool {
        let expected = expectedEntries()
        guard listing.complete, !before.isEmpty, expected.count == listing.entries.count,
              before.allSatisfy(\.isIdentified), listing.entries.allSatisfy(\.isIdentified) else { return false }
        return zip(expected, listing.entries).allSatisfy { $0.matches($1) }
    }

    /// The songs whose places are acknowledged empty, each once, in place order: what "Add Back at End" appends (less
    /// any the playlist has again).
    var songsToAddBack: [Track] {
        AppModel.eachOnce(places.indices.filter { emptied[$0] }.map { places[$0].track })
    }

    /// The songs of `scope` the service has taken out.
    func removedCount(_ scope: Set<String>) -> Int { tracks.count(where: { scope.contains($0.id) && songsOut.contains($0.id) }) }

    /// The songs (each once) and copies of `offsets`, for a notice: "both copies of “X”", "3 songs".
    func phrase(places offsets: [Int]) -> String {
        AppModel.removalPhrase(AppModel.eachOnce(offsets.map { places[$0].track }), entries: offsets.count)
    }

    /// What a removal of `scope` takes, every copy counted.
    func phrase(removing scope: Set<String>) -> String {
        let songs = tracks.filter { scope.contains($0.id) }
        guard !places.isEmpty else { return AppModel.removalPhrase(songs, entries: entries ?? songs.count) }
        return AppModel.removalPhrase(songs, entries: max(songs.count, places.count(where: { scope.contains($0.track.id) })))
    }
}

/// The target a service's playlist edits register their Undo with (one per service), so `removeAllActions(withTarget:)`
/// takes exactly those playlist edits off an undo manager and leaves the queue's and text fields' actions. The model
/// owns them (an undo manager keeps its targets unowned).
final class PlaylistUndoTarget: Sendable {}

/// The account a playlist edit belongs to: the service and its immutable account id (Spotify's user id, YouTube's
/// datasync id) when the edit began. A new token for the same account (a refresh, a sign-in synced from another
/// device) keeps the edit; another account or a sign-out ends it. Without an id (cookies pasted by hand) only the very
/// session the edit began in counts.
struct PlaylistEditAccount: Equatable, Sendable {
    let provider: ProviderID
    /// The account's id, nil when the service gave none.
    let accountID: String?
    /// The session the edit began in, which counts alone when there is no `accountID`.
    let session: ProviderSession

    init(provider: ProviderID, session: ProviderSession) {
        self.provider = provider
        self.session = session
        if case .account(let id?) = session.identity { accountID = id } else { accountID = nil }
    }

    /// The service still holds this account: the same account id under whatever token, or a sign-in being swapped,
    /// which is judged again once it settles. Without an id, only the same session.
    func isHeld(by current: ProviderSession) -> Bool {
        guard let accountID else { return current == session }
        switch current.identity {
        case .account(let id): return id == accountID
        case .changing: return true
        case .signedOut: return false
        }
    }

    /// A request may go out now: the service holds an account (not signed out, no swap of its sign-in under way) and
    /// it is this one: the same account id, or, without one, the same session. An edit begun during a swap has no
    /// `.account` session to match, so it never sends.
    func canSend(with current: ProviderSession) -> Bool {
        guard case .account(let id) = current.identity else { return false }
        if let accountID { return id == accountID }
        return current == session
    }

    /// What the provider carries to where a write's credentials are chosen (`MusicProvider.add(_:toPlaylist:as:)`).
    var write: PlaylistWriteAccount { PlaylistWriteAccount(accountID: accountID, session: session) }
}

/// A playlist edit's request wasn't sent because the service's sign-in was being swapped: it might have gone out as
/// another account. Try Again goes on once the swap settles on the same account.
struct PlaylistSignInChanging: Error {}

/// A read of a playlist for an edit stopped before its end (the page bound, or a continuation handed out twice), so
/// what it holds can't be judged.
struct PlaylistReadIncomplete: Error {}

/// One entry of a playlist as the service lists it, for telling whether the playlist changed since an edit.
enum PlaylistEntry: Hashable, Sendable {
    /// A song, with the service's id for this entry where it has one (YouTube's `setVideoId`).
    case song(id: String, entry: String?)
    /// An entry the pages leave out (Spotify's local files and episodes): it still holds a place. `id` is what the
    /// service identifies it by (a `spotify:local:` or episode URI), nil when it gives nothing (a `null` item).
    case unlisted(id: String?)

    /// The service identifies this entry, so a read can tell it from another.
    var isIdentified: Bool {
        if case .unlisted(nil) = self { return false }
        return true
    }

    /// Whether an entry read now is this one. An expected song without an entry id (one put back, whose new id isn't
    /// known) matches the same song under any id. Unidentified entries match nothing.
    func matches(_ read: PlaylistEntry) -> Bool {
        switch (self, read) {
        case let (.unlisted(id?), .unlisted(readID?)): id == readID
        case let (.song(id, nil), .song(readID, _)): id == readID
        case let (.song(id, entry), .song(readID, readEntry)): id == readID && entry == readEntry
        default: false
        }
    }
}

/// A playlist's entries in the service's order, read page by page up to a bound.
struct PlaylistListing: Sendable {
    var entries: [PlaylistEntry]
    /// Every page was read (the bound wasn't reached).
    var complete: Bool

    /// The songs it holds.
    var songIDs: Set<String> {
        Set(entries.compactMap { if case .song(let id, _) = $0 { id } else { nil } })
    }
}

/// A playlist's lock while requests to it are in flight (`AppModel.PlaylistEditState.inFlight`): the account they go
/// out as and the task sending them. Cancelled when the service no longer holds that account; a run that finds its
/// lock cancelled after any wait sends nothing more and publishes nothing.
@MainActor final class PlaylistEditLock {
    let account: PlaylistEditAccount
    var task: Task<Void, Never>?
    private(set) var isCancelled = false

    init(account: PlaylistEditAccount) {
        self.account = account
    }

    func cancel() {
        isCancelled = true
        task?.cancel()
    }
}

/// A new playlist's songs on their way in (`AppModel.fillNewPlaylist`): the songs the service hasn't acknowledged yet,
/// in order, and whether the last request failed in a way that may have applied it anyway.
@MainActor final class NewPlaylistFill {
    let playlist: Playlist
    let account: PlaylistEditAccount
    /// Not acknowledged yet, in the order asked for.
    private(set) var pending: [Track]
    /// The last request's failure may have landed: the next attempt reads the playlist before sending anything.
    var mayHaveLanded = false

    init(playlist: Playlist, tracks: [Track], account: PlaylistEditAccount) {
        self.playlist = playlist
        self.account = account
        pending = tracks
    }

    /// The service acknowledged the next `count` songs.
    func acknowledge(_ count: Int) { pending.removeFirst(min(count, pending.count)) }

    /// After a whole read: songs the playlist holds are in; only the others are still pending.
    func settle(present: Set<String>) {
        pending.removeAll { present.contains($0.id) }
        mayHaveLanded = false
    }
}
