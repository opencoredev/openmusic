import Foundation
import OpenMusicCore
import Network
import Observation

/// Which sync server this device uses: OpenMusic's own, or one URL the listener entered (a self-hosted Convex
/// deployment). See docs/self-hosting.md.
public enum SyncServer: Sendable, Hashable {
    case hosted(URL)
    case custom(URL)

    public var url: URL {
        switch self {
        case .hosted(let url), .custom(let url): url
        }
    }

    public var isCustom: Bool { if case .custom = self { true } else { false } }

    /// UserDefaults key of the custom server URL. Absent means the hosted server.
    public static let defaultsKey = "syncServerURL"

    /// The server this device uses: the saved custom URL, else `hosted`.
    public static func current(hosted: URL, defaults: UserDefaults = .standard) -> SyncServer {
        if let text = defaults.string(forKey: defaultsKey), let url = parse(text) { return .custom(url) }
        return .hosted(hosted)
    }

    /// A server URL as typed, or nil. See `validate(_:)`.
    public static func parse(_ text: String) -> URL? { try? validate(text) }

    /// A server URL as typed: `https://host[:port]` (a bare host gets https), any host and port. `http://` only for
    /// this machine and the local network (`allowsHTTP`): sync carries the account's sign-in token, which plain http
    /// would show to anyone on the way, and the apps' App Transport Security allows plain http only there
    /// (`NSAllowsLocalNetworking`). Tailscale addresses are refused over http with their own reason: ATS blocks
    /// them (they aren't on the local network), and Tailscale Serve gives the same server an https address.
    /// No path, query, fragment or user info: the client builds its own paths from the origin.
    /// Throws the reason, worded for the listener.
    public static func validate(_ text: String) throws(AccountService.ServerError) -> URL {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw .invalidURL }
        if !raw.contains("://") { raw = "https://" + raw }
        guard var components = URLComponents(string: raw), let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil else { throw .invalidURL }
        guard components.query == nil, components.fragment == nil, components.path.isEmpty || components.path == "/" else {
            throw .hasPath
        }
        switch components.scheme?.lowercased() {
        case "https": break
        case "http":
            switch classify(host: host) {
            case .local: break
            case .tailnet: throw .tailnetHTTP
            case .other: throw .insecure(host: host)
            }
        default: throw .invalidURL
        }
        if let port = components.port, !(1...65535).contains(port) { throw .invalidURL }
        components.scheme = components.scheme?.lowercased()
        components.path = ""
        guard let url = components.url else { throw .invalidURL }
        return url
    }

    /// Whether plain http may go to `host`: this machine (`localhost`, 127.0.0.0/8, ::1), private networks (10/8,
    /// 172.16/12, 192.168/16, link-local 169.254/16 and fe80::/10, unique-local fc00::/7 outside Tailscale's) and
    /// `.local` (mDNS) names. Other names are refused even when they resolve to one of these: the name could
    /// resolve elsewhere tomorrow.
    public static func allowsHTTP(host: String) -> Bool { classify(host: host) == .local }

    enum HostKind { case local, tailnet, other }

    static func classify(host: String) -> HostKind {
        var host = host.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host == "localhost" || host.hasSuffix(".local") { return .local }
        if let v4 = ipv4(host) { return classify(v4) }
        var v6 = in6_addr()
        guard host.contains(":"), inet_pton(AF_INET6, host, &v6) == 1 else { return .other }
        let b = withUnsafeBytes(of: v6) { Array($0) }
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return .local } // ::1
        if b[0..<6] == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] { return .tailnet } // Tailscale's fd7a:115c:a1e0::/48
        if b[0] & 0xfe == 0xfc { return .local } // fc00::/7
        if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return .local } // fe80::/10
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { return classify([b[12], b[13], b[14], b[15]]) } // ::ffff:a.b.c.d
        return .other
    }

    private static func ipv4(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            // Canonical decimal only. The system resolver reads a leading zero as octal (010.8.8.8 is 8.8.8.8),
            // so such a host is not taken for the private address it looks like: it is no IPv4 address here, and
            // as a name it never gets plain http.
            guard (1...3).contains(part.count), part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  part.count == 1 || part.first != "0", let value = UInt8(part) else { return nil }
            bytes.append(value)
        }
        return bytes
    }

    private static func classify(_ a: [UInt8]) -> HostKind {
        switch (a[0], a[1]) {
        case (127, _), (10, _), (192, 168), (169, 254), (172, 16...31): .local
        case (100, 64...127): .tailnet // Tailscale, and carrier-grade NAT generally: never the local network
        default: .other
        }
    }

    /// How the server is named in Settings: the host, with its port when it has one.
    public var displayName: String {
        guard let host = url.host() else { return url.absoluteString }
        let shown = host.contains(":") ? "[\(host)]" : host
        return url.port.map { "\(shown):\($0)" } ?? shown
    }
}

/// The signed-in account on this device: the server choice, its Clerk app (from the server's public `config:get`)
/// and the Clerk session. The app pairs it with `SyncService`: after a sign-in it calls
/// `sync.signIn(auth: account.tokenProvider!, userID: user.id, generation: account.sessionGeneration)`, and signs out
/// with `signOut(sync:)`.
@MainActor
@Observable
public final class AccountService {
    public enum State: Sendable, Equatable {
        /// Reading the saved sign-in and the server's configuration.
        case loading
        case signedOut
        case signedIn(ClerkUser)
    }

    public private(set) var state: State = .loading
    public private(set) var server: SyncServer
    /// Social sign-ins the server's Clerk app has on (Google, Apple, …).
    public private(set) var socialProviders: [ClerkOAuthProvider] = []
    /// Why signing in isn't possible right now (the server isn't set up, or can't be reached). nil when it is.
    /// OpenMusic tries again by itself while the server can't be reached; `retry()` tries at once.
    public private(set) var serverProblem: String?
    /// Something the listener should know about their sign-in, shown until they sign in again: the server's
    /// configuration started naming another Clerk host, so the saved sign-in was dropped unused; or the saved session
    /// ended while Clerk still had another one on this device, which OpenMusic didn't switch to.
    public private(set) var notice: String?
    public var user: ClerkUser? { if case .signedIn(let user) = state { user } else { nil } }
    public var isSignedIn: Bool { user != nil }

    /// Runs when Clerk ends the shown session by itself (signed out elsewhere, revoked, gone at launch), or when the
    /// saved sign-in was dropped because the server now names another Clerk host. `endedSignIn` says which sign-in
    /// ended; a notice about an older session that arrives after a newer sign-in never runs it.
    @ObservationIgnored public var onSessionEnded: (@MainActor () -> Void)?
    /// Runs when the server's sign-in configuration loaded after a launch that couldn't load it (offline): a saved
    /// sign-in can connect now (`tokenProvider` is set).
    @ObservationIgnored public var onReady: (@MainActor () -> Void)?
    /// Waits between automatic tries while the server can't be reached, the last one repeating.
    @ObservationIgnored public var retryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(15), .seconds(30), .seconds(60), .seconds(120), .seconds(300)]
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryAttempt = 0
    @ObservationIgnored private var loadingConfiguration = false
    /// Watch the network while the configuration is missing and try again when it comes back (off in tests).
    @ObservationIgnored public var watchesNetwork = true
    @ObservationIgnored private var pathMonitor: NWPathMonitor?

    @ObservationIgnored public private(set) var clerk: ClerkClient?
    /// The Convex token source for `SyncService.signIn`, once a Clerk app is known.
    public var tokenProvider: (any AuthTokenProvider)? { clerk }

    @ObservationIgnored private let hostedURL: URL
    @ObservationIgnored private let store: any ClerkStateStore
    @ObservationIgnored private let http: any HTTPPoster
    @ObservationIgnored private let clerkHTTP: any ClerkHTTP
    @ObservationIgnored private let defaults: UserDefaults

    public init(hostedURL: URL, store: any ClerkStateStore, defaults: UserDefaults = .standard,
                http: any HTTPPoster = URLSessionHTTPPoster(), clerkHTTP: any ClerkHTTP = URLSessionClerkHTTP()) {
        self.hostedURL = hostedURL
        self.store = store
        self.defaults = defaults
        self.http = http
        self.clerkHTTP = clerkHTTP
        server = SyncServer.current(hosted: hostedURL, defaults: defaults)
    }

    #if DEBUG
    /// Snapshot runs only: a made-up sign-in state without Clerk or a server.
    public func preview(user: ClerkUser?, socialProviders: [ClerkOAuthProvider] = [.apple, .google]) {
        state = user.map(State.signedIn) ?? .signedOut
        shownSessionID = user == nil ? nil : "preview"
        self.socialProviders = socialProviders
        serverProblem = nil
    }
    #endif

    // MARK: Launch

    /// Reads the server's sign-in configuration and the saved session. A saved session counts at once (offline
    /// launches stay signed in); Clerk is asked in the background whether it still stands. When the server can't be
    /// reached, the configuration is tried again with backoff, and on `retry()`.
    public func load() async {
        let saved = store.load()
        // Offline-safe: show the saved user right away; the checks below may sign out. Nothing is sent anywhere yet.
        if let user = saved?.user, let id = saved?.sessionID { show(ClerkSession(id: id, user: user)) }
        await loadConfiguration()
    }

    /// Tries the server's sign-in configuration again now, if it hasn't loaded: the Retry button, coming back
    /// online, coming back to the foreground.
    public func retry() async {
        guard clerk == nil else { return }
        retryTask?.cancel()
        retryTask = nil
        await loadConfiguration()
    }

    /// Whether the configuration is loaded (sign-in can start, and a saved sign-in can connect).
    public var isReady: Bool { clerk != nil }

    private func loadConfiguration() async {
        guard clerk == nil, !loadingConfiguration else { return }
        loadingConfiguration = true
        defer { loadingConfiguration = false }
        do {
            let clerk = try await makeClerk()
            retryTask?.cancel()
            retryTask = nil
            retryAttempt = 0
            stopWatchingNetwork()
            serverProblem = nil
            self.clerk = clerk
            if clerk.discardedStateForOtherOrigin {
                notice = ClerkError.originChanged(clerk.frontendAPI.host() ?? clerk.frontendAPI.absoluteString).errorDescription
                if isSignedIn { endShownSignIn() } else { showSignedOut() }
            } else if case .signedIn = state {
            } else if let saved = await clerk.savedSession {
                show(saved)
            } else {
                showSignedOut()
            }
            onReady?()
            Task { [weak self] in await self?.refresh() }
        } catch {
            serverProblem = Self.describe(error)
            if case .loading = state { showSignedOut() }
            if case ServerError.unreachable = error {
                scheduleRetry()
                watchNetwork()
            }
        }
    }

    private func watchNetwork() {
        guard watchesNetwork, pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in await self?.retry() }
        }
        monitor.start(queue: DispatchQueue(label: "\(ProductInfo.identifierPrefix).account.network"))
        pathMonitor = monitor
    }

    private func stopWatchingNetwork() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func scheduleRetry() {
        guard retryTask == nil, !retryDelays.isEmpty else { return }
        let delay = retryDelays[min(retryAttempt, retryDelays.count - 1)]
        retryAttempt += 1
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            await self.loadConfiguration()
        }
    }

    /// Asks Clerk whether the session still stands, and which social sign-ins are on. Only the session shown when it
    /// started is refreshed or ended: Clerk never moves this device to another session by itself (`ClerkClient.restore`),
    /// and a sign-in or sign-out that finished meanwhile is newer than what Clerk answered.
    public func refresh() async {
        guard let clerk else { return }
        if let providers = try? await clerk.socialProviders() { socialProviders = providers }
        let asked = shownSessionID
        let generation = sessionGeneration
        do {
            // nil: the session ended, which the client announces (`setOnSessionEnded`) naming it; acted on there.
            guard let restored = try await clerk.restore() else { return }
            guard let asked, generation == sessionGeneration, shownSessionID == asked, restored.id == asked else { return }
            state = .signedIn(restored.user)
        } catch ClerkError.network {
            // Offline: keep the saved sign-in.
        } catch {}
    }

    private func makeClerk() async throws -> ClerkClient {
        let publishableKey = try await Self.fetchPublishableKey(server: server.url, http: http)
        let clerk = try ClerkClient(publishableKey: publishableKey, http: clerkHTTP, store: store)
        await clerk.setOnSessionEnded { [weak self] ended in
            Task { @MainActor in
                #if DEBUG
                await self?.willDeliverSessionEnd?()
                #endif
                self?.sessionEnded(ended)
            }
        }
        return clerk
    }

    #if DEBUG
    /// Tests only: runs on the main actor when Clerk's notice that a session ended arrives, before it is acted on (the
    /// hop a sign-in can finish in).
    @ObservationIgnored var willDeliverSessionEnd: (@MainActor () async -> Void)?
    #endif

    /// The Clerk session the shown sign-in is (nil when signed out). Set together with `state` by every sign-in, a
    /// launch's saved sign-in and a restore; a notice that a session ended counts only when it names this one.
    @ObservationIgnored private var shownSessionID: String?

    private func show(_ session: ClerkSession) {
        shownSessionID = session.id
        state = .signedIn(session.user)
    }

    private func showSignedOut() {
        shownSessionID = nil
        state = .signedOut
    }

    /// Clerk ended `ended`. It acts only when that is the sign-in shown now: the notice is queued to the main actor
    /// and can arrive after a newer sign-in (another user, or the same one again), whose session it doesn't name, so it
    /// is ignored then and the newer sign-in keeps its session and its sync sign-in.
    private func sessionEnded(_ ended: ClerkSessionEnd) {
        guard let shownSessionID, ended.sessionID == shownSessionID, ended.userID == nil || ended.userID == user?.id else { return }
        if let other = ended.notAdopted { notice = ClerkError.otherSessionNotAdopted(other.displayName).errorDescription }
        endShownSignIn()
    }

    /// Ends the sign-in shown now (its session ended, or was dropped for another Clerk origin) and tells the app.
    private func endShownSignIn() {
        guard let user else { return }
        endedSignIn = SyncSignIn(userID: user.id, generation: sessionGeneration)
        showSignedOut()
        onSessionEnded?()
    }

    /// The sign-in whose session ended last (set before `onSessionEnded` runs), so the app signs sync out only for it
    /// (`SyncService.signOut(ifSignIn:)`), never for a newer sign-in.
    public private(set) var endedSignIn: SyncSignIn?

    /// The sign-in shown now, for `SyncService.signIn(auth:userID:generation:)` (nil when signed out).
    public var currentSignIn: SyncSignIn? { user.map { SyncSignIn(userID: $0.id, generation: sessionGeneration) } }

    // MARK: Signing in

    private func requireClerk() async throws -> ClerkClient {
        if clerk == nil { await retry() }
        guard let clerk else { throw ServerError.unreachable(serverProblem ?? "Can't reach that server: no answer") }
        return clerk
    }

    public func startEmail(_ email: String) async throws -> ClerkEmailChallenge {
        try await requireClerk().startEmail(email)
    }

    @discardableResult
    public func verifyEmail(_ challenge: ClerkEmailChallenge, code: String) async throws -> ClerkUser {
        let session = try await requireClerk().verifyEmail(challenge, code: code)
        signedIn(session)
        return session.user
    }

    public func startOAuth(_ provider: ClerkOAuthProvider) async throws -> ClerkOAuthStart {
        try await requireClerk().startOAuth(provider)
    }

    @discardableResult
    public func completeOAuth(_ start: ClerkOAuthStart, callback: URL) async throws -> ClerkUser {
        let session = try await requireClerk().completeOAuth(start, callback: callback)
        signedIn(session)
        return session.user
    }

    /// A sign-in finished: a new session, newer than any sign-out still on its way.
    private func signedIn(_ session: ClerkSession) {
        sessionGeneration += 1
        show(session)
        notice = nil
    }

    /// Bumped by every sign-in. A sign-out captures it before it waits for anything and acts afterwards only if it
    /// didn't move: a sign-in in between (the same user again included, which the user id alone can't tell) is newer
    /// and stays, in the UI and in the saved Clerk state. Sync is signed in with it (`currentSignIn`), so its own
    /// sign-out guard compares it too.
    @ObservationIgnored public private(set) var sessionGeneration = 0

    /// Ends the Clerk session. The app signs sync out first (`SyncService.signOut()`), which needs the session to
    /// remove the device on the server; `signOut(sync:)` does both in that order. A sign-in while Clerk ends the
    /// session (the removal is a network call) is newer and stays.
    public func signOut() async {
        let generation = sessionGeneration
        if let clerk {
            // The client forgets the session and saves that before it awaits Clerk; nothing is erased afterwards, so a
            // sign-in saved meanwhile stays saved.
            await clerk.signOut()
        } else {
            store.save(nil)
        }
        guard generation == sessionGeneration else { return }
        showSignedOut()
    }

    /// Which Clerk session (and user) is signed in now, and which sign-in it came from. A sign-out that has to wait
    /// for something first captures it, so it ends that session only (`signOut(ifStill:)`).
    public struct Session: Sendable, Equatable {
        public var sessionID: String?
        public var userID: String?
        /// `sessionGeneration` when captured: any sign-in since makes the capture stale.
        var generation = 0

        /// The sign-in this session is, for sync's guard (`SyncService.signOut(ifSignIn:)`); nil when signed out.
        public var signIn: SyncSignIn? { userID.map { SyncSignIn(userID: $0, generation: generation) } }
    }

    /// One coherent snapshot of the sign-in: the user and the generation are read together, before anything is
    /// awaited, and the session id after. A sign-in that finishes during that await makes the snapshot stale
    /// (`isCurrent` is false, and its session id is dropped): it describes the sign-in that was current when the caller
    /// asked, never a mix of that one and the next.
    public func currentSession() async -> Session {
        let generation = sessionGeneration
        let userID = user?.id
        #if DEBUG
        await willReadClerkSession?()
        #endif
        let id = await clerk?.currentSessionID
        return Session(sessionID: generation == sessionGeneration ? id : nil, userID: userID, generation: generation)
    }

    /// Whether no sign-in happened since `session` was captured.
    public func isCurrent(_ session: Session) -> Bool { session.generation == sessionGeneration }

    #if DEBUG
    /// Tests only: runs inside `currentSession()` after the user and generation are captured, before Clerk is asked
    /// for the session id (the await a sign-in can finish in).
    @ObservationIgnored var willReadClerkSession: (@MainActor () async -> Void)?
    #endif

    /// Ends the Clerk session only if it is still `session`; a newer sign-in that happened meanwhile, before or while
    /// this waits for Clerk, is left alone (the same user signing in again included). Returns whether it signed out.
    @discardableResult
    public func signOut(ifStill session: Session) async -> Bool {
        guard sessionGeneration == session.generation else { return false }
        if let clerk {
            // The check and forgetting the session happen together in the client, before it awaits Clerk, and it saves
            // the forgotten state then: nothing here erases the store afterwards, so a sign-in during the await stays.
            guard await clerk.signOut(ifSession: session.sessionID) else { return false }
        } else {
            guard user?.id == session.userID else { return false }
            store.save(nil)
        }
        // Revalidated after the await: a sign-in that finished meanwhile is newer than this sign-out.
        guard sessionGeneration == session.generation else { return false }
        showSignedOut()
        return true
    }

    /// Settings › Account › Sign Out: removes this device from sync (`SyncService.signOut(ifSignIn:)`, which needs the
    /// session to remove the device on the server), then ends the Clerk session it started for. A sign-in that happened
    /// meanwhile (another user, or the same one again) keeps its session and its sync sign-in:
    /// - one that finished while the snapshot was taken makes it stale, and the snapshot is checked right before sync is
    ///   asked to sign out, with nothing awaited in between, so this sign-out then does nothing at all;
    /// - one that finished while sync signed out is newer than the snapshot's generation, so sync's guard (which
    ///   compares the generation, not only the user) and `signOut(ifStill:)` leave it alone.
    public func signOut(sync: SyncService) async {
        let session = await currentSession()
        guard isCurrent(session) else { return }
        await sync.signOut(ifSignIn: session.signIn)
        await signOut(ifStill: session)
    }

    // MARK: Server

    /// Checks that `url` is an OpenMusic server with sign-in set up. Returns the URL to save.
    public func checkServer(_ text: String) async throws -> URL {
        let url = try SyncServer.validate(text)
        let key = try await Self.fetchPublishableKey(server: url, http: http)
        guard ClerkPublishableKey.frontendAPI(key) != nil else { throw ClerkError.notConfigured }
        return url
    }

    /// Switches servers (nil: the hosted one). The caller signs sync out first; this ends the Clerk session of the
    /// old server and loads the new one's configuration.
    public func setServer(_ url: URL?) async {
        await signOut()
        if let url, url != hostedURL { defaults.set(url.absoluteString, forKey: SyncServer.defaultsKey) } else { defaults.removeObject(forKey: SyncServer.defaultsKey) }
        server = SyncServer.current(hosted: hostedURL, defaults: defaults)
        clerk = nil
        retryTask?.cancel()
        retryTask = nil
        retryAttempt = 0
        stopWatchingNetwork()
        notice = nil
        socialProviders = []
        shownSessionID = nil
        state = .loading
        await load()
    }

    public enum ServerError: LocalizedError, Sendable, Equatable {
        case invalidURL
        /// The address has a path, query or fragment.
        case hasPath
        /// `http://` to a host that isn't this machine or the local network.
        case insecure(host: String)
        /// `http://` to a Tailscale address.
        case tailnetHTTP
        /// The system refused plain http to the server (App Transport Security).
        case blockedHTTP
        case unreachable(String)
        case notOpenMusic

        public var errorDescription: String? {
            switch self {
            case .invalidURL: "Enter the server's https:// address, for example https://happy-otter-123.convex.cloud."
            case .hasPath: "Enter only the server's address, without a path, for example https://sync.example.com:3443."
            case .insecure(let host): "\(ProductInfo.name) uses http:// only for this computer and your local network. Use https://\(host)."
            case .tailnetHTTP: "Plain http:// doesn't work over Tailscale. Use the server's https:// address from Tailscale Serve, for example https://my-server.your-tailnet.ts.net."
            case .blockedHTTP: "This device allows plain http:// only on your local network. Use the server's https:// address."
            case .unreachable(let why): why
            case .notOpenMusic: "That address doesn't run the \(ProductInfo.name) sync server."
            }
        }
    }

    static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// What to say when a server didn't answer, in the listener's terms: no such address, offline, no answer in
    /// time; anything else as the system put it.
    nonisolated static func unreachableMessage(_ error: any Error, host: String) -> String {
        switch (error as? URLError)?.code {
        case .cannotFindHost?, .dnsLookupFailed?:
            "Can't find a server at \(host). Check the address and try again."
        case .notConnectedToInternet?, .networkConnectionLost?, .dataNotAllowed?:
            "This device is offline. Connect to the internet, then try again."
        case .timedOut?:
            "\(host) didn't answer. Check the address, or try again once the server is running."
        case .cannotConnectToHost?:
            "\(host) refused the connection. Check that the server is running and the address includes the right port."
        default:
            "Can't reach that server: \(error.localizedDescription)"
        }
    }

    /// `config:get` over HTTP: the server's Clerk publishable key. Needs no sign-in.
    public nonisolated static func fetchPublishableKey(server: URL, http: any HTTPPoster) async throws -> String {
        let body = ConvexValue.object([
            "path": .string("config:get"),
            "format": .string("convex_encoded_json"),
            "args": .array([.object([:])]),
        ]).jsonData()
        let response: (body: Data, status: Int)
        do {
            response = try await http.post(server.appending(path: "api/query"), body: body,
                                           headers: ["Content-Type": "application/json", "Convex-Client": "medley-swift-\(OpenMusicSync.version)"])
        } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
            throw ServerError.blockedHTTP
        } catch {
            throw ServerError.unreachable(unreachableMessage(error, host: server.host ?? server.absoluteString))
        }
        guard (200..<300).contains(response.status) || response.status == 560,
              let parsed = try? ConvexValue.parse(response.body) else { throw ServerError.notOpenMusic }
        guard parsed["status"]?.stringValue == "success", let auth = parsed["value"]?["auth"] else { throw ServerError.notOpenMusic }
        guard auth["kind"]?.stringValue == "clerk", let key = auth["publishableKey"]?.stringValue else { throw ClerkError.notConfigured }
        return key
    }
}
