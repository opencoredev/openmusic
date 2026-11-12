import CryptoKit
import Foundation
import MedleyCore
import Observation

/// Home and New as they were last loaded, kept in ~/Library/Caches/OpenMusic/browse so a launch shows them at once (and
/// offline) while `Loadable` fetches fresh shelves in the background. Before this, real Home appeared about
/// 1.7 s after launch, behind its placeholder (`MEDLEY_SELFTEST=launch`).
///
/// The shelves are personal, so:
/// - each file is named for the page and for the accounts it belongs to (`Key`), by the service's immutable account
///   id, so a second account with the same name and plan never sees the first one's Home. The accounts come from
///   the credentials the request was actually sent with (`MusicProvider.session`), not from `authStatus`, and a page
///   whose sessions changed during the request saves nothing (`BrowsePage`). An account without such an id is
///   never cached on disk (`diskAccounts`);
/// - files are owner-only (0600, in a 0700 folder);
/// - `prune(keeping:)` deletes every file of an account that is no longer signed in, and refuses later writes for
///   it. `watchAccounts` runs it after launch and whenever a service's session changes, per service.
///
/// Every read, write and deletion runs in order on one queue, so a save still pending when an account signs out
/// either lands before the purge (and is purged) or is refused after it.
///
/// Only complete results are saved (every service answered). Entries older than a week are ignored and pruned.
/// Mock runs don't use it.
nonisolated final class BrowseDiskCache: @unchecked Sendable {
    typealias Value = [ProviderResult<[Shelf]>]
    static let maxAge: TimeInterval = 7 * 24 * 3600

    static let shared = BrowseDiskCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("\(ProductInfo.folderName)/browse", isDirectory: true))

    /// A page and the accounts whose shelves it holds. The file name is a hash of the page plus one short hash per
    /// account, so no names end up on disk and a purge can find an account's files.
    struct Key: Hashable, Sendable {
        let page: String
        let accounts: Set<String>

        var fileName: String {
            let digest = SHA256.hash(data: Data(page.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            return (["v2-" + digest] + accounts.sorted()).joined(separator: ".") + ".json"
        }

        /// The accounts in a file name this cache wrote; nil for anything else (files from older builds included).
        static func accounts(inFileName name: String) -> Set<String>? {
            guard name.hasPrefix("v2-"), name.hasSuffix(".json") else { return nil }
            let parts = name.dropLast(5).split(separator: ".").map(String.init)
            return Set(parts.dropFirst())
        }
    }

    /// One account's short tag: provider plus the service's immutable account id.
    static func accountTag(_ provider: ProviderID, id: String) -> String {
        let digest = SHA256.hash(data: Data("\(provider.rawValue)\u{1F}id:\(id)".utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The account's tag, nil when it has no immutable id (a name or detail is never used: two accounts can share it).
    static func accountTag(_ provider: ProviderID, _ account: AccountInfo) -> String? {
        account.id.map { accountTag(provider, id: $0) }
    }

    /// The accounts a page answered by these sessions belongs to, nil when it can't go on disk: a session that is
    /// changing could have answered as either account, and an account without an immutable id can't be told apart
    /// from the next one. Signed-out sessions add no tag (their shelves are public).
    static func diskAccounts(_ sessions: [ProviderID: ProviderSession]) -> Set<String>? {
        var tags = Set<String>()
        for (provider, session) in sessions {
            switch session.identity {
            case .signedOut: continue
            case .changing, .account(id: nil): return nil
            case .account(id: let id?): tags.insert(accountTag(provider, id: id))
            }
        }
        return tags
    }

    private struct StoredShelf: Codable {
        var id: String
        var title: String
        var subtitle: String?
        var style: ShelfStyle
        var items: [MediaItem]
        var moreToken: String?
    }

    private struct StoredResult: Codable {
        var provider: ProviderID
        var shelves: [StoredShelf]
    }

    private let directory: URL?
    private let queue = DispatchQueue(label: "\(ProductInfo.identifierPrefix).browse-disk-cache", qos: .utility)
    /// Accounts whose files may exist (queue only). Nil until the first prune after launch: until sessions are
    /// restored, every provider reads as signed out.
    private var allowed: Set<String>?

    init(directory: URL?) {
        self.directory = directory
    }

    private func isAllowed(_ key: Key) -> Bool {
        allowed.map { key.accounts.isSubset(of: $0) } ?? true
    }

    /// Settings › General › Clear Cache.
    static func removeAll() { shared.removeAll() }

    func removeAll() {
        guard let directory else { return }
        queue.async { try? FileManager.default.removeItem(at: directory) }
    }

    /// Deletes every file holding an account not in `accounts` (and files from older builds or past `maxAge`);
    /// later saves for such accounts are refused.
    func prune(keeping accounts: Set<String>) {
        queue.async { [self] in
            allowed = accounts
            guard let directory,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
            for name in names {
                let url = directory.appendingPathComponent(name)
                let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                let expired = date.map { Date().timeIntervalSince($0) >= Self.maxAge } ?? true
                if expired || !(Key.accounts(inFileName: name)?.isSubset(of: accounts) ?? false) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    /// The saved value and when it was saved, read off the main actor.
    func load(_ key: Key) async -> (value: Value, date: Date)? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: read(key)) }
        }
    }

    private func read(_ key: Key) -> (value: Value, date: Date)? {
        guard isAllowed(key), let url = directory?.appendingPathComponent(key.fileName),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attributes[.modificationDate] as? Date, Date().timeIntervalSince(date) < Self.maxAge,
              let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([StoredResult].self, from: data)
        else { return nil }
        let value = stored.map { result in
            ProviderResult(provider: result.provider, value: result.shelves.map {
                Shelf(id: $0.id, title: $0.title, subtitle: $0.subtitle, style: $0.style, items: $0.items, moreToken: $0.moreToken)
            }, error: nil)
        }
        return (value, date)
    }

    func save(_ value: Value, key: Key) {
        guard value.allSatisfy({ $0.error == nil && $0.value != nil }),
              value.contains(where: { !($0.value ?? []).isEmpty })
        else { return }
        let stored = value.map { result in
            StoredResult(provider: result.provider, shelves: (result.value ?? []).map {
                StoredShelf(id: $0.id, title: $0.title, subtitle: $0.subtitle, style: $0.style, items: $0.items, moreToken: $0.moreToken)
            })
        }
        queue.async { [self] in
            guard isAllowed(key), let directory, let data = try? JSONEncoder().encode(stored) else { return }
            write(data, to: directory.appendingPathComponent(key.fileName), in: directory)
        }
    }

    /// Owner-only from the start: the temporary file is created 0600 inside a 0700 folder, then renamed over the
    /// old one.
    private func write(_ data: Data, to url: URL, in directory: URL) {
        let fm = FileManager.default
        guard (try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil
        else { return }
        // A folder an older build made 0755.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary.path, url.path) != 0 { try? fm.removeItem(at: temporary) }
    }

    /// Waits for every queued read, write and deletion (tests).
    func flush() {
        queue.sync {}
    }

    // MARK: Watching sign-ins

    /// The account each service last settled on, so one whose credentials are being swapped keeps exactly that.
    @MainActor final class SettledAccounts {
        var tags: [ProviderID: String] = [:]

        /// The accounts whose files stay: every service's current account, judged per service. A sign-in still in
        /// progress is not a change (the service still sends the previous account's credentials, and `session`
        /// says so); during the moment a swap is landing, that service keeps the account it had before.
        func keep(_ providers: [any MusicProvider]) -> Set<String> {
            var keep = Set<String>()
            for provider in providers {
                switch provider.session.identity {
                case .changing:
                    if let tag = tags[provider.id] { keep.insert(tag) }
                case .signedOut, .account(id: nil):
                    tags[provider.id] = nil
                case .account(id: let id?):
                    let tag = accountTag(provider.id, id: id)
                    tags[provider.id] = tag
                    keep.insert(tag)
                }
            }
            return keep
        }
    }

    /// After launch has restored the sessions: prunes now and again whenever a service's session changes (sign-in,
    /// sign-out, another account), each service on its own.
    @MainActor static func watchAccounts(_ model: AppModel, cache: BrowseDiskCache = .shared, settled: SettledAccounts = SettledAccounts()) {
        let keep = withObservationTracking {
            settled.keep(model.providers)
        } onChange: { [weak model] in
            Task { @MainActor in if let model { watchAccounts(model, cache: cache, settled: settled) } }
        }
        cache.prune(keeping: keep)
    }
}
