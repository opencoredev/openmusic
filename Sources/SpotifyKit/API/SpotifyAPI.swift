import Foundation
import MedleyCore

/// Token-authorized Spotify Web API client.
///
/// Runs on its own actor so requests and JSON decoding never touch the main actor.
/// Refreshes the access token shortly before expiry and once more on a 401, waits out
/// 429 `Retry-After` (up to a cap), and keeps a small in-memory cache of GET responses.
public actor SpotifyAPI {
    public static let baseURL = URL(string: "https://api.spotify.com/v1")!

    public enum Method: String, Sendable { case get = "GET", put = "PUT", post = "POST", delete = "DELETE" }

    private let transport: any SpotifyTransport
    private let auth: SpotifyAuthService
    private let tokenStore: any SpotifyTokenStore
    /// Client ID for refreshing tokens that don't record their own (saved before the built-in client existed).
    private let clientID: @Sendable () -> String?
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    /// Called after a refresh stored a new token (Spotify rotates the refresh token too) or found it revoked.
    /// Not called for `setToken`; whoever sets a token knows. The sign-in transfer listens here.
    private var tokenRefreshObserver: (@Sendable () -> Void)?
    /// Asked when Spotify refuses a refresh (`invalid_grant`), before the session is declared revoked. Spotify
    /// rotates the refresh token on every refresh, so when two devices of a sync library refresh the same token at
    /// once, the slower one is refused. The sign-in transfer answers with the rotated token the other device synced
    /// (from the vault, or after waiting briefly for it), or nil. Not set on throwaway clients.
    ///
    /// It gets the account this session's token belongs to (`userID`, nil when not learned yet) and must answer only
    /// with a token whose owner it verified with Spotify (`RecoveredToken.userID`): a token of another account is never
    /// installed under this session's owner. A deliberate switch goes through sign-in or the transfer's import, which
    /// starts a new session.
    private var refreshRecovery: RefreshRecovery?

    /// nil: definitely no newer token of this account (the session is revoked). Throws when that can't be told yet
    /// (offline, a timeout, 429, 5xx): the refresh fails with that error, retryably, and the token stays saved.
    public typealias RefreshRecovery = @Sendable (_ rejected: SpotifyToken, _ owner: String?) async throws -> RecoveredToken?

    /// A token recovered after a refused refresh, with the Spotify user its owner was verified as.
    public struct RecoveredToken: Sendable {
        public let token: SpotifyToken
        public let userID: String

        public init(token: SpotifyToken, userID: String) {
            self.token = token
            self.userID = userID
        }
    }

    private var token: SpotifyToken?
    private var refreshTask: Task<SpotifyToken, any Error>?
    /// Bumped whenever the credentials change (sign-in, sign-out, account switch). Work started under an older
    /// session is dropped when it comes back: its responses aren't returned or cached and its tokens aren't saved.
    private var session = 0
    private var cache: [String: CacheEntry] = [:]
    private var cacheOrder: [String] = []

    /// Longest `Retry-After` the client waits out before giving up with `.rateLimited`.
    let maxRetryAfter: TimeInterval
    static let cacheLimit = 96

    struct CacheEntry {
        var data: Data
        var expires: Date
    }

    public init(
        transport: any SpotifyTransport = URLSessionTransport(),
        tokenStore: any SpotifyTokenStore = KeychainTokenStore(),
        clientID: @escaping @Sendable () -> String?,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: (@Sendable (TimeInterval) async throws -> Void)? = nil,
        maxRetryAfter: TimeInterval = 20
    ) {
        self.transport = transport
        self.auth = SpotifyAuthService(transport: transport, now: now)
        self.tokenStore = tokenStore
        self.clientID = clientID
        self.now = now
        self.sleep = sleep ?? { try await Task.sleep(for: .seconds($0)) }
        self.maxRetryAfter = maxRetryAfter
        self.token = tokenStore.load()
    }

    // MARK: Session facts

    /// Spotify user id of the signed-in account, set after `/me`.
    public private(set) var userID: String?
    /// Endpoints that answered 403/404 this session (removed for development-mode apps). Not retried.
    private var unavailable: Set<String> = []

    public func setUserID(_ id: String?) { userID = id }
    /// Sets the user id learned from a `/me` started in session `generation`; ignored if the session moved on.
    func setUserID(_ id: String?, session generation: Int) {
        guard generation == session else { return }
        userID = id
    }
    func isUnavailable(_ endpoint: String) -> Bool { unavailable.contains(endpoint) }
    func markUnavailable(_ endpoint: String, session generation: Int) {
        guard generation == session else { return }
        unavailable.insert(endpoint)
    }

    // MARK: Tokens

    public var hasToken: Bool { token != nil }

    /// The stored token as it is now, for the sign-in transfer.
    var currentToken: SpotifyToken? { token }

    func setTokenRefreshObserver(_ observer: (@Sendable () -> Void)?) { tokenRefreshObserver = observer }
    func setRefreshRecovery(_ recovery: RefreshRecovery?) { refreshRecovery = recovery }

    /// Replaces the session. In-flight requests and refreshes from the old session are discarded when they return.
    /// `userID` is the new account's id when the caller already knows it (sign-in), else it's learned from `/me`.
    /// Saves (or deletes) the token first: when the store refuses, this throws and the session is left as it was.
    public func setToken(_ token: SpotifyToken?, userID: String? = nil) throws {
        try tokenStore.save(token)
        session &+= 1
        self.token = token
        refreshTask?.cancel()
        refreshTask = nil
        self.userID = token == nil ? nil : userID
        unavailable.removeAll()
        clearCache()
        heldSwap = nil
    }

    /// The newest `setToken(_:userID:epoch:)` applied.
    private var tokenEpoch = 0

    /// The provider's token swaps, numbered by `epoch`: one that arrives after a newer one landed is ignored (returns
    /// false), so the client always ends with the provider's latest token.
    func setToken(_ token: SpotifyToken?, userID: String?, epoch: Int) throws -> Bool {
        guard epoch > tokenEpoch else { return false }
        try setToken(token, userID: userID)
        tokenEpoch = epoch
        heldSwap = epoch
        return true
    }

    /// The provider's swap whose token this holds (`setToken(_:userID:epoch:)`); nil after a token set any other way.
    /// The token loaded at launch is swap 0, as the provider's count starts.
    private var heldSwap: Int? = 0

    /// Throws `PlaylistEditError.accountChanged` unless the credentials a request would go out with now belong to the
    /// account `binding` was checked for: the same Spotify user (any token of theirs), or, without a user id, the same
    /// provider swap.
    private func check(_ binding: SpotifyWriteBinding?) throws {
        guard let binding else { return }
        let held = if let expected = binding.userID { userID == expected } else { heldSwap == binding.epoch }
        guard token != nil, held else { throw PlaylistEditError.accountChanged }
    }

    /// Current session number. Read it before a request whose result updates session facts.
    var sessionGeneration: Int { session }

    /// Throws `CancellationError` when the session changed since `generation` was read.
    private func requireSession(_ generation: Int) throws {
        guard generation == session else { throw CancellationError() }
    }

    /// A valid access token, refreshing first if it is about to expire.
    public func accessToken() async throws -> String {
        guard let token else { throw ProviderError.notSignedIn }
        if token.needsRefresh(now: now()) {
            return try await refreshToken().accessToken
        }
        return token.accessToken
    }

    /// Refreshes once even if many requests ask at the same time.
    @discardableResult
    func refreshToken() async throws -> SpotifyToken {
        let generation = session
        if let refreshTask {
            let fresh = try await refreshTask.value
            try requireSession(generation)
            return fresh
        }
        guard let current = token else { throw ProviderError.notSignedIn }
        // Refresh with the client that issued the token; older tokens don't record it and came from `clientID()`.
        guard let clientID = current.clientID ?? clientID(), !clientID.isEmpty else { throw ProviderError.notSignedIn }
        let auth = self.auth
        // Runs on this actor. Requests that ask meanwhile wait for the same task, recovery included.
        let task = Task { () throws -> SpotifyToken in
            do {
                return try await auth.refresh(current, clientID: clientID)
            } catch ProviderError.notSignedIn {
                guard let recovered = try await self.recoverRefresh(rejected: current, generation: generation, clientID: clientID) else {
                    throw ProviderError.notSignedIn
                }
                return recovered
            }
        }
        refreshTask = task
        // A newer session may have started its own refresh by the time this one returns; leave that one alone.
        defer { if generation == session { refreshTask = nil } }
        do {
            let fresh = try await task.value
            // The account changed while Spotify answered: never save the old account's token over the new one.
            try requireSession(generation)
            token = fresh
            // Best effort: the session goes on with the fresh token either way.
            try? tokenStore.save(fresh)
            tokenRefreshObserver?()
            return fresh
        } catch ProviderError.notSignedIn {
            try requireSession(generation)
            // Refresh token revoked or expired.
            token = nil
            try? tokenStore.save(nil)
            tokenRefreshObserver?()
            throw ProviderError.notSignedIn
        } catch {
            try requireSession(generation)
            throw error
        }
    }

    /// Spotify refused `rejected`'s refresh token. Asks `refreshRecovery` for a newer token another device rotated
    /// and continues with it: as it is while its access token is good, else refreshed once. nil: none came, the
    /// session is revoked. Throws `CancellationError` when a new session (the sign-in sync importing that token)
    /// replaced this one meanwhile; the new session is left alone.
    ///
    /// Fails closed: the recovered token is used only when its verified owner is this session's (`userID`), or, before
    /// that is learned, the account the provider holds (which the recovery compared it with); then that owner is this
    /// session's `userID`. Anything else counts as no newer token, and the session ends signed out.
    private func recoverRefresh(rejected: SpotifyToken, generation: Int, clientID: String) async throws -> SpotifyToken? {
        let owner = userID
        guard let refreshRecovery, let recovered = try await refreshRecovery(rejected, owner) else { return nil }
        try requireSession(generation)
        guard owner == nil || owner == recovered.userID else { return nil }
        let newer = recovered.token
        guard let refresh = newer.refreshToken, refresh != rejected.refreshToken else { return nil }
        if userID == nil { userID = recovered.userID }
        if !newer.needsRefresh(now: now()) { return newer }
        return try await auth.refresh(newer, clientID: newer.clientID ?? clientID)
    }

    // MARK: Requests

    /// GET a path under /v1 and decode it. `ttl` > 0 caches the raw response; 0 neither reads nor writes the cache.
    public func get<T: Decodable & Sendable>(_ path: String, query: [String: String] = [:], ttl: TimeInterval = 0, uncached: Bool = false, as type: T.Type = T.self) async throws -> T {
        let data = try await data(.get, url: url(path, query: query), ttl: uncached ? 0 : ttl, uncached: uncached)
        return try decode(T.self, from: data, context: path)
    }

    /// GET an absolute URL Spotify handed back (`next` links). Only api.spotify.com is accepted.
    public func get<T: Decodable & Sendable>(absolute url: URL, ttl: TimeInterval = 0, uncached: Bool = false, as type: T.Type = T.self) async throws -> T {
        guard Self.isSpotifyAPIURL(url) else { throw ProviderError.decoding("unexpected page link") }
        let data = try await data(.get, url: url, ttl: uncached ? 0 : ttl, uncached: uncached)
        return try decode(T.self, from: data, context: url.path)
    }

    /// Non-GET request with an optional JSON body. Clears the cache, since the library or a playlist changed.
    @discardableResult
    public func send(_ method: Method, _ path: String, query: [String: String] = [:], json: [String: any Sendable]? = nil,
                     as binding: SpotifyWriteBinding? = nil) async throws -> Data {
        var body: Data?
        if let json {
            body = try JSONSerialization.data(withJSONObject: json)
        }
        let result = try await data(method, url: url(path, query: query), body: body, binding: binding)
        if method != .get { clearCache() }
        return result
    }

    public func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    static func isSpotifyAPIURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == baseURL.host && url.path.hasPrefix("/v1/")
    }

    func url(_ path: String, query: [String: String]) -> URL {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            // URLComponents leaves ":" "," and "+" unescaped; Spotify treats a literal "+" as a space, so escape it.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return components.url!
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, context: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ProviderError.decoding("\(context): \(Self.describe(error))")
        }
    }

    static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        switch error {
        case .keyNotFound(let key, let ctx): return "missing \(key.stringValue) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx):
            return "\(ctx.debugDescription) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
        @unknown default: return "\(error)"
        }
    }

    /// `uncached`: the request ignores every cache and goes through the transport's cache-free session (it never
    /// touches this actor's cache either: `ttl` is 0). `binding`: checked on entry and again right after the token is
    /// chosen for each attempt (retries included), with no suspension between that check and the send, so a write
    /// never goes out with another account's token.
    private func data(_ method: Method, url: URL, body: Data? = nil, ttl: TimeInterval = 0, uncached: Bool = false,
                      binding: SpotifyWriteBinding? = nil) async throws -> Data {
        try check(binding)
        var generation = session
        let key = url.absoluteString
        if method == .get, ttl > 0, let hit = cache[key], hit.expires > now() {
            return hit.data
        }

        var refreshed = false
        var rateLimitRetries = 0
        var serverRetries = 0
        while true {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.httpMethod = method.rawValue
            let bearer = try await accessToken()
            // The credentials are chosen: from here to the send nothing suspends. A bound write whose account got a new
            // token meanwhile (a sign-in synced from another device for the same user) goes again with that token.
            try check(binding)
            if binding != nil, generation != session {
                generation = session
                continue
            }
            try requireSession(generation)
            if uncached { request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData }
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }

            let (data, response) = try await transport.send(request, uncached: uncached)
            // Signed out or switched accounts while this was in flight: the answer belongs to the old session.
            try requireSession(generation)
            let status = response.statusCode
            switch status {
            case 200..<300:
                if method == .get, ttl > 0 { store(data, for: key, ttl: ttl) }
                return data
            case 401 where !refreshed:
                refreshed = true
                try await refreshToken()
                continue
            case 401:
                throw ProviderError.notSignedIn
            case 429:
                let wait = Self.retryAfter(response)
                guard rateLimitRetries < 3, wait <= maxRetryAfter else { throw ProviderError.rateLimited }
                rateLimitRetries += 1
                try await sleep(wait)
                try requireSession(generation)
                continue
            case let code where [500, 502, 503, 504].contains(code) && method == .get && serverRetries < 1:
                serverRetries += 1
                try await sleep(1)
                try requireSession(generation)
                continue
            default:
                throw Self.error(status: status, data: data)
            }
        }
    }

    private func store(_ data: Data, for key: String, ttl: TimeInterval) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = CacheEntry(data: data, expires: now().addingTimeInterval(ttl))
        while cacheOrder.count > Self.cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    /// Seconds from `Retry-After`; Spotify sends whole seconds. Defaults to 1.
    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces) else { return 1 }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        return 1
    }

    static func error(status: Int, data: Data) -> ProviderError {
        let body = try? JSONDecoder().decode(SP.APIErrorBody.self, from: data)
        let message = body?.error.message ?? String(decoding: data.prefix(200), as: UTF8.self)
        switch (status, body?.error.reason) {
        case (403, "PREMIUM_REQUIRED"): return .unplayable("Spotify Connect playback needs Spotify Premium.")
        case (404, "NO_ACTIVE_DEVICE"): return .unplayable("No active Spotify device. Open Spotify on a device, or pick one in Settings.")
        case (_, "NO_ACTIVE_DEVICE"): return .unplayable("No active Spotify device.")
        case (404, _): return .notFound
        case (429, _): return .rateLimited
        default: return .server(status, message)
        }
    }
}

/// The account a write must go out as (`SpotifyAPI.send(_:_:query:json:as:)`): the Spotify user id the app checked, or,
/// when it had none, the provider's token swap (`setToken(_:userID:epoch:)`) it checked in.
public struct SpotifyWriteBinding: Sendable, Hashable {
    public let userID: String?
    public let epoch: Int

    public init(userID: String?, epoch: Int) {
        self.userID = userID
        self.epoch = epoch
    }
}
