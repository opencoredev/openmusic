import Foundation
import OpenMusicCore
import Observation

/// What `SyncCoordinator` needs from the service. `SyncService` is the real one; tests use an in-memory hub.
@MainActor
public protocol SyncServicing: AnyObject {
    var selfID: DeviceID? { get }
    var devices: [SyncDevice] { get }
    var playback: [DeviceID: RemotePlayback] { get }
    var clock: ServerClock { get }
    /// Runs each incoming command once; the service acks it with the result.
    var commandHandler: (@MainActor (IncomingCommand) async -> CommandResult)? { get set }
    func publish(anchor: PlaybackAnchor, queue: QueueWindow?) async throws
    func clearPlayback() async throws
    func fetchQueue(of device: DeviceID) async throws -> QueueWindow?
    func send(_ command: SyncCommand, to device: DeviceID) async throws -> CommandID
    func waitForAck(_ command: CommandID, timeout: Duration) async throws -> CommandResult
    /// Playing counts as active: heartbeats keep running while the app is in the background.
    func setPlaying(_ playing: Bool)
    /// Whether this device holds the account's current vault key, so it can seal what it plays (and open what others
    /// play). Without it, it publishes only its anchor and can't hand playback off.
    var canSealContent: Bool { get }
    /// Called when the key this device seals with changes (it got the key, a rotation, it lost it): the coordinator
    /// publishes its queue again, sealed under the new key (or with no content).
    var onContentKeyChange: (@MainActor () -> Void)? { get set }
}

/// One app-level sign-in on this device: the Clerk user and which of the sign-ins on this device it is
/// (`AccountService.sessionGeneration`). A sign-out carries the one it was started for, and sync compares both: the
/// user id alone can't tell a sign-in from the same user's next one.
public struct SyncSignIn: Sendable, Hashable {
    public var userID: String
    public var generation: Int

    public init(userID: String, generation: Int) {
        self.userID = userID
        self.generation = generation
    }
}

/// The sync session of this device: its registration with the signed-in account, the device list, everyone's
/// playback and the command channel, and the vault key moving between devices.
///
/// The app signs in with Clerk and calls `signIn(auth:userID:)`: the device registers with the account and the
/// live queries open (devices, playback, incoming and outgoing commands, vault, settings). It sends a heartbeat
/// every 30 s while the app is in the foreground or playing. `signOut()` removes the device.
@MainActor
@Observable
public final class SyncService: SyncServicing, VaultEndpoint, SettingsEndpoint {
    public enum Registration: Sendable, Equatable {
        /// Not signed in, or signed in but not registered yet.
        case none
        case registered(deviceID: DeviceID, libraryID: LibraryID)
    }

    /// Whether this device can sync YouTube Music and Spotify sign-ins (it holds the account's vault key).
    public enum KeyStatus: Sendable, Equatable {
        case none
        /// This device holds the vault key; sign-ins sync.
        case available
        /// Asked for the key; no device that has it has answered yet (none is open, or all are offline).
        case waiting
        /// A device that has the key answered: compare the code with the one it shows. See `KeyComparison`.
        case comparing(KeyComparison)
        /// A device that has the key said no. `requestKeyAgain()` asks again.
        case denied
        /// This attempt ended (the codes didn't match, the key didn't open, too many tries). `requestKeyAgain()`
        /// starts a new one. The message says what happened.
        case failed(String)
        /// The key this device holds isn't the account's; sign-ins don't sync.
        case mismatch
        /// This device holds a key the account replaced while it was away (two rotations it missed), and the server
        /// lists it as asking for the key. Nothing changes by itself: `requestKeyAgain()` drops the old key and asks
        /// a device that has the current one, with the usual code comparison.
        case outdated
    }

    /// The code an asking device shows while it compares with the holder that answered it. The key is used only once
    /// the holder allowed it (`allowed`) and the listener confirmed here that the codes match (`confirmed`), in
    /// either order: `confirmKeyCode()` or `rejectKeyCode()`.
    public struct KeyComparison: Sendable, Hashable {
        public var code: String
        public var holderID: DeviceID
        public var holderName: String
        /// The holder tapped Allow (its grant arrived and opened here).
        public var allowed: Bool
        /// The listener tapped Codes Match on this device.
        public var confirmed: Bool

        public init(code: String, holderID: DeviceID, holderName: String, allowed: Bool, confirmed: Bool) {
            self.code = code
            self.holderID = holderID
            self.holderName = holderName
            self.allowed = allowed
            self.confirmed = confirmed
        }

        /// The card's title, the same on both apps. `here` is "this Mac" or "this iPhone".
        public func title(here: String) -> String {
            switch (allowed, confirmed) {
            case (false, false): "Compare the codes"
            case (false, true): "Waiting for \(holderName)"
            case (true, false): "\(holderName) allowed \(here)"
            case (true, true): "Taking your sign-ins…"
            }
        }

        /// What to do next.
        public func instructions(here: String) -> String {
            switch (allowed, confirmed) {
            case (false, false):
                "\(holderName) shows a code too. If it's the same as this one, tap Allow on \(holderName) and Codes Match here. If it isn't, tap Codes Don't Match."
            case (false, true):
                "Tap Allow on \(holderName) to share your YouTube Music and Spotify sign-ins with \(here)."
            case (true, false):
                "Tap Codes Match if \(holderName) showed this same code. If it didn't, tap Codes Don't Match: \(here) then doesn't take anything."
            case (true, true):
                "Your YouTube Music and Spotify sign-ins arrive in a moment."
            }
        }
    }

    /// Another of the account's devices asking for the vault key. Ask "Allow <device> to use your YouTube Music and
    /// Spotify sign-ins?", show `code` (it must match the one on that device), then `allowKey` or `denyKey`. Only
    /// listed once the exchange checked out on this device.
    public struct KeyRequest: Sendable, Hashable, Identifiable {
        public var device: SyncDevice
        public var code: String
        /// Which exchange this is (a new request from the same device is a new one).
        public var commitment: String
        public var id: DeviceID { device.id }

        public init(device: SyncDevice, code: String, commitment: String) {
            self.device = device
            self.code = code
            self.commitment = commitment
        }
    }

    /// The vault key, when this device holds it.
    public var libraryKey: LibraryKey? { credentials?.libraryKey }

    // MARK: Observable state

    public private(set) var registration: Registration = .none
    /// Every device of the library, this one included, oldest first.
    public internal(set) var devices: [SyncDevice] = []
    /// Published playback by device, this one included. Devices with nothing loaded have no entry. What plays is opened
    /// with this device's key; without it a row has only its anchor (`RemotePlayback.content`).
    public private(set) var playback: [DeviceID: RemotePlayback] = [:]
    /// Commands this device sent recently, newest first.
    public private(set) var outgoing: [OutgoingCommand] = []
    /// Commands for this device that aren't acked yet.
    public private(set) var incoming: [IncomingCommand] = []
    public private(set) var connection = ConvexClient.Status(state: .idle, httpFallback: false, connections: 0)
    public internal(set) var lastError: SyncError?
    public private(set) var clock = ServerClock()
    /// The library's sealed sign-ins (`vault:list`); nil until loaded.
    public private(set) var vaultEntries: [VaultEntry]?
    /// The library's synced settings (`settings:list`), opened with this device's key; nil until loaded, and while
    /// this device has no key (settings sync only between devices that hold it).
    public private(set) var settingEntries: [SettingEntry]?
    /// Fingerprint of the vault key according to the server (nil while nobody holds one).
    public internal(set) var serverKeyID: String? {
        didSet { if serverKeyID != oldValue { contentKeysChanged() } }
    }
    /// Whether this device can sync sign-ins.
    public internal(set) var keyStatus: KeyStatus = .none
    /// A device that could open the vault left, so a holder must replace the key (this one does it at once).
    public internal(set) var rotationNeeded = false
    /// Devices asking for the vault key whose exchange with this device checked out, when this device has it.
    public var keyRequests: [KeyRequest] { verifiedKeyRequests() }
    /// Something about requests for the key looks wrong (failed or refused attempts, a tampered exchange), worth
    /// showing in Settings › Account. nil when all is well.
    public var keyWarning: String? { keyExchangeWarning() }
    /// The other devices that hold the vault key (and so can allow this one).
    public var keyHolders: [SyncDevice] { otherDevices.filter { $0.keyState == .holder } }
    /// Called after the server stopped knowing this device (it was removed on another device). The app signs out.
    @ObservationIgnored public var onRemoved: (@MainActor () -> Void)?
    /// Sign-in sync. Register each provider's `SignInTransfer` here.
    @ObservationIgnored public let signIns: SignInSync
    /// Settings sync: `bind(PlaybackSettings)`, recent searches, other values.
    @ObservationIgnored public let settings: SettingsSync
    /// Name, platform and model sent when this device joins.
    public var deviceInfo: DeviceInfo

    public var selfID: DeviceID? {
        if case .registered(let id, _) = registration { return id }
        return nil
    }
    public var isRegistered: Bool { selfID != nil }
    public var selfDevice: SyncDevice? { devices.first { $0.id == selfID } }
    public var otherDevices: [SyncDevice] { devices.filter { $0.id != selfID } }

    public func isOnline(_ device: SyncDevice) -> Bool { device.isOnline(serverNow: clock.now()) }

    /// Live position (seconds) of a device's playback, extrapolated on the server clock.
    public func livePosition(of device: DeviceID) -> TimeInterval? {
        playback[device]?.anchor.position(atServerTime: clock.now())
    }

    @ObservationIgnored public var commandHandler: (@MainActor (IncomingCommand) async -> CommandResult)? {
        didSet { if commandHandler != nil { processIncoming() } }
    }
    /// Called as each command arrives, before it runs, with how long it took to get here (server clock, ms).
    @ObservationIgnored public var onCommandReceived: (@MainActor (IncomingCommand, _ deliveryMs: Double) -> Void)?

    // MARK: Wiring

    @ObservationIgnored public let client: ConvexClient
    @ObservationIgnored let store: any SyncCredentialStore
    @ObservationIgnored var credentials: SyncCredentials? {
        didSet { if credentials?.libraryKey?.id != oldValue?.libraryKey?.id || credentials?.libraryID != oldValue?.libraryID { contentKeysChanged() } }
    }
    /// The server's rows as they came, kept sealed so they can be opened again when this device's key changes.
    @ObservationIgnored private var playbackRows: [PlaybackRow] = []
    @ObservationIgnored var sealedSettings: [SealedSettingEntry]?
    @ObservationIgnored private var wireOutgoing: [WireOutgoingCommand] = []
    /// The keys `contentKeysChanged` last acted on: the one rows are opened with, and the one this device seals with.
    @ObservationIgnored private var openingKeyMark: String?
    @ObservationIgnored private var sealingKeyMark: String?
    @ObservationIgnored public var onContentKeyChange: (@MainActor () -> Void)?
    /// This device's record of its key exchanges (see `KeyLedger`). Observed: the status and requests derive from it.
    var ledger = KeyLedger()
    /// A grant that opened, waiting for the listener to confirm the code here.
    var pendingGrantKey: LibraryKey?
    /// The serial executor every account and key operation runs on (`AccountOperations`).
    @ObservationIgnored let operations = AccountOperations()
    /// The identity calls are made for: what `client.setAuth` returned for the signed-in user. Captured by each call
    /// when it is made, so a call never takes on an identity set after it.
    @ObservationIgnored var authScope: AuthScope?
    /// The Clerk user `authScope` belongs to.
    @ObservationIgnored var authUserID: String?
    /// The app-level sign-in that signed sync in as `authUserID` (nil before any sign-in in this process).
    @ObservationIgnored private var authSignIn: SyncSignIn?
    /// The newest key revision (`devices:list` `keyRevision`) this session applied. Older lists are ignored.
    @ObservationIgnored var appliedKeyRevision = 0
    /// The newest device list delivered and not applied yet, with the token of the session it was fetched for.
    @ObservationIgnored var pendingList: (list: DeviceListResult, token: String?)?
    @ObservationIgnored var failedKeyBlobs: Set<String> = []
    /// The wall clock for rate limits and warnings (tests move it).
    @ObservationIgnored var now: @Sendable () -> Date = { Date() }
    @ObservationIgnored private var started = false
    @ObservationIgnored private var subscriptionTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var handledCommands: [CommandID] = []
    @ObservationIgnored private var commandQueue: [IncomingCommand] = []
    @ObservationIgnored private var runningCommands = false
    @ObservationIgnored private var ackWaiters: [CommandID: [UUID: CheckedContinuation<CommandResult, any Error>]] = [:]
    @ObservationIgnored private var isForeground = true
    @ObservationIgnored private var isPlaying = false
    @ObservationIgnored private var suspendTask: Task<Void, Never>?

    /// Close the socket when the app is in the background and not playing (after `backgroundGrace`), and reconnect
    /// when it comes back or starts playing. On by default on iOS, where the system would kill the socket anyway;
    /// off on macOS, where a paused app in the background should still answer commands.
    @ObservationIgnored public var suspendsInBackground: Bool = {
        #if os(iOS)
        true
        #else
        false
        #endif
    }()
    @ObservationIgnored public var backgroundGrace: Duration = .seconds(10)

    public nonisolated static let heartbeatInterval: Duration = .seconds(30)
    /// The dev deployment (Convex project `openmusic`): Debug builds, tests, self-tests, live scripts, the probe's default.
    public nonisolated static let defaultDeploymentURL = URL(string: "https://sensible-barracuda-214.convex.cloud")!
    /// The production deployment: Release builds.
    public nonisolated static let productionDeploymentURL = URL(string: "https://insightful-roadrunner-835.convex.cloud")!
    /// The Info.plist key naming the hosted deployment (`scripts/bundle.sh` on the Mac, `OPENMUSIC_SYNC_URL` per
    /// configuration in `iOS/project.yml`).
    public nonisolated static let deploymentURLKey = "OpenMusicSyncURL"

    /// `OpenMusicSyncURL` from Info.plist; without it, dev in a Debug build and production in a Release build.
    public nonisolated static func deploymentURL(bundle: Bundle = .main) -> URL {
        (bundle.object(forInfoDictionaryKey: deploymentURLKey) as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
            ?? builtInDeploymentURL
    }

    /// The deployment this build uses when Info.plist names none.
    public nonisolated static var builtInDeploymentURL: URL {
        #if DEBUG
        defaultDeploymentURL
        #else
        productionDeploymentURL
        #endif
    }

    public init(
        deploymentURL: URL = SyncService.deploymentURL(),
        deviceInfo: DeviceInfo,
        credentials store: any SyncCredentialStore = KeychainCredentialStore(),
        transport: any WebSocketTransport = URLSessionWebSocketTransport(),
        http: any HTTPPoster = URLSessionHTTPPoster(),
        options: ConvexClient.Options = .init()
    ) {
        self.deviceInfo = deviceInfo
        self.store = store
        self.client = ConvexClient(deploymentURL: deploymentURL, transport: transport, http: http, options: options)
        signIns = SignInSync(store: store)
        settings = SettingsSync()
        if let saved = store.load(), saved.deploymentURL == deploymentURL {
            credentials = saved
            registration = .registered(deviceID: saved.deviceID, libraryID: saved.libraryID)
        }
        loadLedger()
        // Sign-in state saved for another library, deployment or device id is dropped.
        signIns.beginSession(scope: credentials.map(Self.scope))
        signIns.endpoint = self
        settings.endpoint = self
        settings.clock = { [weak self] in self?.clock.now() ?? 0 }
        updateKeyStatus()
        openingKeyMark = credentials?.libraryKey?.id
        sealingKeyMark = contentKey?.id
    }

    // MARK: Lifecycle

    /// Connects and, when registered, opens the live queries. Safe to call more than once.
    public func start() {
        guard !started else { return }
        started = true
        statusTask = Task { [weak self, client] in
            for await status in client.statusUpdates() {
                self?.connection = status
            }
        }
        Task { await client.start() }
        if credentials != nil { openSubscriptions() }
        updateActivity()
    }

    public func stop() {
        // A sync session that ends (a server change) takes every account operation still on its way with it, except
        // a sign-out, which still removes this device.
        _ = operations.supersede()
        stopNow()
    }

    /// `stop()` without starting a new epoch: a sign-out ends with it, and must not cancel a sign-in queued after it.
    private func stopNow() {
        started = false
        closeSubscriptions()
        statusTask?.cancel()
        statusTask = nil
        // The status stream is gone, so it can't report the socket closing: show it here.
        connection = ConvexClient.Status(state: .idle, httpFallback: false, connections: connection.connections)
        heartbeatTask?.cancel()
        heartbeatTask = nil
        suspendTask?.cancel()
        suspendTask = nil
        Task { [client] in await client.stop() }
    }

    /// The app moved to or from the foreground. Heartbeats and the HTTP fallback poll run only while in the
    /// foreground or playing; coming back reconnects at once.
    public func setForeground(_ foreground: Bool) {
        let returning = foreground && !isForeground
        isForeground = foreground
        updateActivity()
        // A sign-out whose local deletion failed is retried at once rather than after its delay.
        if returning { signIns.retryNow() }
    }

    public func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        updateActivity()
    }

    /// In the foreground or playing: the socket, heartbeats and the HTTP fallback poll stay on.
    private var isAwake: Bool { isForeground || isPlaying }

    /// After a wake from sleep: replace the socket now instead of trusting one that may have died silently.
    public func reconnectNow(force: Bool = false) {
        guard started else { return }
        Task { [client] in await client.reconnectNow(force: force) }
    }

    private func updateActivity() {
        let awake = isAwake
        Task { [weak self, client] in
            await client.setForeground(awake)
            // Read `started` now, not when the task was made: a `stop()` (leaving sync) during the await above must
            // not be undone by a reconnect here.
            guard awake, let self, self.started else { return }
            await client.start()          // back from a background suspend
            await client.reconnectNow()   // or waiting on a backoff
        }
        if awake {
            suspendTask?.cancel()
            suspendTask = nil
        } else {
            armSuspend()
        }
        let active = started && credentials != nil && awake
        if active, heartbeatTask == nil {
            heartbeatTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.heartbeat()
                    try? await Task.sleep(for: SyncService.heartbeatInterval)
                }
            }
        } else if !active {
            heartbeatTask?.cancel()
            heartbeatTask = nil
        }
    }

    /// Closes the socket `backgroundGrace` after the app went to the background without playing.
    private func armSuspend() {
        guard suspendsInBackground, started, !isAwake else { return }
        suspendTask?.cancel()
        let grace = backgroundGrace
        suspendTask = Task { [weak self, client] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled, let self, self.started, !self.isAwake else { return }
            await client.suspend()
        }
    }

    private func heartbeat() async {
        guard let token = credentials?.token else { return }
        _ = try? await call("devices:heartbeat", TokenArgs(token: token), as: ServerNowResult.self)
        // Requests a holder held back (its hourly limit) get answered once the limit allows, without a list change.
        operations.enqueue("answers") { _ in self.resumeKeyRequests() }
    }

    // MARK: Account

    /// A registration sent but not settled: the device token (which is also the registration's request id: the server
    /// finds a retry by its hash and answers with the same device), the device's key pair and the fresh vault key it
    /// proposes. Saved in the credential store before `account:register` is sent and kept until the server answers:
    /// if the server took it and the answer was lost (timeout, the app quit), the account's first key and the token
    /// of the device that holds it aren't lost with it, and the next attempt, this session or the next launch, sends
    /// the same registration again and adopts what the server says it did.
    ///
    /// It expires: one made more than `maxAge` ago (by this device's clock) is never sent again. The server forgets
    /// retired and withdrawn tokens after 30 days (`LIMITS.cancelledRegistrationTtlMs`), so a registration resent after
    /// that, by a device that was offline for a month, could register a token whose device was removed meanwhile (and
    /// evict another device from a full account). The device starts a new registration instead and owes the old token's
    /// removal (`PendingRemoval`), since it may have landed. The server refuses attempts older than its own limit too
    /// (`createdAt`, `LIMITS.registrationMaxAgeMs`).
    struct PendingRegistration: Codable, Sendable {
        static let stateName = "registration.v1"
        /// Far inside the server's 30 days, and inside its own 14-day limit with room for clock differences.
        static let maxAge: TimeInterval = 7 * 24 * 3600
        /// A creation time this far ahead of the clock means the clock was moved back since: treated as expired.
        static let maxAhead: TimeInterval = 24 * 3600

        var token = newDeviceToken()
        var deviceKey = DeviceKeyPair.generate()
        var proposedKey = LibraryKey.generate()
        /// The Clerk user and deployment it was sent to; another user or server starts over.
        var userID: String
        var deploymentURL: URL
        /// When it was made (sent with every attempt). nil only for one saved by a build before expiry, which counts
        /// as expired.
        var createdAt: Date?

        func isExpired(at now: Date) -> Bool {
            guard let createdAt else { return true }
            let age = now.timeIntervalSince(createdAt)
            return age > Self.maxAge || age < -Self.maxAhead
        }
    }
    /// The registration in flight, mirrored in the credential store (`PendingRegistration.stateName`).
    @ObservationIgnored private var pending: PendingRegistration?

    /// A device of this installation that must still be removed from its account: its sign-out couldn't reach the
    /// server, or it was a first registration whose answer was lost, so this installation never learned its id and
    /// the token is the only handle on its row (which may hold the account's key and keep the vault from resetting).
    /// Saved before the local state is dropped, and completed (`account:unregister`, by token) the next time the same
    /// user signs in on this device to the same server.
    struct PendingRemoval: Codable, Sendable, Equatable {
        static let stateName = "removals.v1"
        var token: String
        var userID: String
        var deploymentURL: URL
    }

    /// Signs this device in to sync: calls carry `auth`'s token from now on, the device registers with the account
    /// (once; later launches reuse the saved registration) and the live queries open. `userID` is the Clerk user;
    /// a registration saved for another user is set aside to be removed when that user signs in again. Throws when
    /// registering fails (offline, rate limited) or its credentials couldn't be saved; calling it again, or launching
    /// again, resends the same registration until the server answers and the credentials are saved. Throws
    /// `CancellationError` when a sign-out, a newer sign-in or a server change overtook it; it then changed nothing.
    ///
    /// Runs as one account operation (`AccountOperations`): nothing else touches the account until it finished.
    ///
    /// `generation` says which of the user's app-level sign-ins this is (`AccountService.sessionGeneration`), so a
    /// sign-out started for an older one (`signOut(ifSignIn:)`) leaves it alone, the same user's included.
    public func signIn(auth: any AuthTokenProvider, userID: String, generation: Int = 0) async throws {
        let signIn = SyncSignIn(userID: userID, generation: generation)
        let ticket = operations.supersede()
        requestedSignIn = signIn
        try await operations.run(ticket) { ticket in
            try await self.performSignIn(auth: auth, signIn: signIn, ticket)
        }
    }

    private func performSignIn(auth: any AuthTokenProvider, signIn: SyncSignIn, _ ticket: AccountOperations.Ticket) async throws {
        let userID = signIn.userID
        if let saved = credentials, saved.userID != userID {
            // Another user's device: removed when that user signs in here again, never just forgotten.
            guard setAsideForRemoval(token: saved.token, userID: saved.userID) else { throw Self.registrationNotSaved }
            forgetNow()
        }
        if let saved = savedPendingRegistration(), saved.userID != userID || saved.deploymentURL != client.deploymentURL {
            guard setAsideForRemoval(token: saved.token, userID: saved.userID, deploymentURL: saved.deploymentURL) else { throw Self.registrationNotSaved }
            dropPendingRegistration()
        }
        // Calls still queued for another user fail here instead of going out under this user's identity.
        let scope = await client.setAuth(auth, identity: userID)
        try ticket.check(operations)
        authScope = scope
        authUserID = userID
        authSignIn = signIn
        if !started { start() }
        if let credentials {
            try saveCredentialsOfPendingRegistration(credentials)
            completeRemovalsLater()
            return
        }
        let attempt = try pendingRegistration(for: userID)
        let args = RegisterArgs(token: attempt.token, device: deviceInfo, publicKey: attempt.deviceKey.publicKey, keyId: attempt.proposedKey.id,
                                createdAt: ((attempt.createdAt ?? now()).timeIntervalSince1970 * 1000).rounded())
        let result: RegisterResult
        do {
            result = try await callReportingCodes("account:register", args, as: RegisterResult.self, ticket: ticket)
        } catch let error as ConvexClientError where Self.refusesRegistration(error) {
            // Refused, so it never landed (or its device belongs to another account, or is gone): the next attempt
            // starts over with a new token and key.
            if pending?.token == attempt.token { dropPendingRegistration() }
            throw SyncError.from(error)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Not known to have landed or not: the registration stays saved and is sent again as it is.
            throw SyncError.from(error)
        }
        guard credentials == nil, pending?.token == attempt.token else { return }
        serverKeyID = result.keyId
        // Only a key this device just made counts: an account that has a key gives it only through the exchange.
        let holdsProposal = result.keyState == .holder && result.keyId == attempt.proposedKey.id
        let saved = adopt(SyncCredentials(deviceID: result.deviceId, libraryID: result.libraryId, token: attempt.token,
                                          deploymentURL: client.deploymentURL, deviceKey: attempt.deviceKey, userID: userID,
                                          libraryKey: holdsProposal ? attempt.proposedKey : nil),
                          keyRevision: result.keyRevision ?? 0)
        // Dropped only once the credentials holding the token and key are saved; otherwise the next sign-in, or the
        // next launch, settles it.
        guard saved else { throw Self.registrationNotSaved }
        dropPendingRegistration()
        completeRemovalsLater()
    }

    private static let registrationNotSaved = SyncError.server("\(ProductInfo.name) couldn't save this device's registration. It tries again later.")

    /// Signed in already, with a registration still saved: its credentials weren't saved when it settled. They are
    /// saved now, and the saved registration is dropped only once they are, so a quit before that loses nothing.
    private func saveCredentialsOfPendingRegistration(_ credentials: SyncCredentials) throws {
        guard pending != nil || store.state(PendingRegistration.stateName) != nil else { return }
        guard store.load() == credentials || store.persist(credentials) else { throw Self.registrationNotSaved }
        dropPendingRegistration()
    }

    /// Errors after which a registration certainly didn't land as sent: the token names a device of another account
    /// or of a library that's gone (`unauthorized`), or the server refused the arguments (`invalidArgument`).
    private static func refusesRegistration(_ error: ConvexClientError) -> Bool {
        error.code == "unauthorized" || error.code == "invalidArgument"
    }

    private func savedPendingRegistration() -> PendingRegistration? {
        pending ?? store.state(PendingRegistration.stateName).flatMap { try? JSONDecoder().decode(PendingRegistration.self, from: $0) }
    }

    /// The registration to send: the one in flight or saved by an earlier launch, for this user and server, else a
    /// new one, saved before it is returned. Throws when it can't be saved, so nothing is sent that could be lost.
    ///
    /// A saved one that expired (`PendingRegistration.isExpired`) is never sent again: it may have landed, so its token
    /// is recorded as a removal owed (by token, `account:unregister`, which settles a landed device and an unknown token
    /// alike and is free to retry) before it is dropped, and a new registration takes its place.
    private func pendingRegistration(for userID: String) throws -> PendingRegistration {
        if let saved = savedPendingRegistration(), saved.userID == userID, saved.deploymentURL == client.deploymentURL {
            guard saved.isExpired(at: now()) else {
                pending = saved
                return saved
            }
            guard setAsideForRemoval(token: saved.token, userID: saved.userID, deploymentURL: saved.deploymentURL) else { throw Self.registrationNotSaved }
            dropPendingRegistration()
        }
        let fresh = PendingRegistration(userID: userID, deploymentURL: client.deploymentURL, createdAt: now())
        guard let data = try? JSONEncoder().encode(fresh), store.persistState(PendingRegistration.stateName, data) else {
            throw Self.registrationNotSaved
        }
        pending = fresh
        return fresh
    }

    private func dropPendingRegistration() {
        pending = nil
        if store.state(PendingRegistration.stateName) != nil { store.setState(PendingRegistration.stateName, nil) }
    }

    // MARK: Removals still owed

    var pendingRemovals: [PendingRemoval] {
        store.state(PendingRemoval.stateName).flatMap { try? JSONDecoder().decode([PendingRemoval].self, from: $0) } ?? []
    }

    /// Records a device to remove later. Returns whether the record was saved: until it is, the caller keeps
    /// whatever else holds the token.
    private func setAsideForRemoval(token: String, userID: String?, deploymentURL: URL? = nil) -> Bool {
        guard let userID else { return true }   // credentials from before accounts: no user to remove it as
        let record = PendingRemoval(token: token, userID: userID, deploymentURL: deploymentURL ?? client.deploymentURL)
        var all = pendingRemovals
        if all.contains(record) { return true }
        all.append(record)
        guard let data = try? JSONEncoder().encode(all) else { return false }
        return store.persistState(PendingRemoval.stateName, data)
    }

    private func dropRemoval(_ record: PendingRemoval) {
        let rest = pendingRemovals.filter { $0 != record }
        store.setState(PendingRemoval.stateName, rest.isEmpty ? nil : try? JSONEncoder().encode(rest))
    }

    /// Removes, after the sign-in, the devices this installation still owes the signed-in user.
    private func completeRemovalsLater() {
        guard let user = authUserID, pendingRemovals.contains(where: { $0.userID == user }) else { return }
        operations.enqueue("removals") { ticket in await self.completeRemovals(ticket) }
    }

    private func completeRemovals(_ ticket: AccountOperations.Ticket) async {
        guard let user = authUserID else { return }
        for record in pendingRemovals where record.userID == user && record.deploymentURL == client.deploymentURL {
            guard record.token != credentials?.token else {
                dropRemoval(record)   // this device's own registration now; nothing to remove
                continue
            }
            do {
                let result = try await withTimeout(.seconds(10), "The sync server") { [self] in
                    try await self.callReportingCodes("account:unregister", TokenArgs(token: record.token), as: UnregisterResult.self, ticket: ticket)
                }
                try ticket.check(operations)
                // Kept until the server says the token is removed or refused from now on: a registration with it may
                // still be on its way, and could land after a plain "nothing to remove".
                if result.settled { dropRemoval(record) }
            } catch let error as ConvexClientError where error.code == "invalidArgument" {
                // A malformed token (corrupted saved data) can never name a device: drop it so it can't block the rest.
                dropRemoval(record)
                if (try? ticket.check(operations)) == nil { return }
                continue
            } catch let error as ConvexClientError where error.code == "rateLimited" {
                // This token's withdrawal was refused (the withdrawal limits apply to tokens no device has). The record
                // stays for the next sign-in, and the others still go: removals of real devices are never limited, and
                // one blocked withdrawal must not keep a landed holder from being removed.
                if (try? ticket.check(operations)) == nil { return }
                continue
            } catch {
                // Offline, or overtaken: the record stays for the next sign-in.
                return
            }
        }
    }

    /// Signs this device out of sync: removes it from the account's devices, forgets the token, keys and vault key,
    /// and closes the connection. The device's own YouTube Music and Spotify sign-ins are untouched.
    ///
    /// A first registration whose answer was lost (this device never learned its id) is removed by its token
    /// (`account:unregister`). When the server can't be reached, the device to remove is recorded first and removed
    /// the next time the same user signs in here; the token of a row that may hold the account's key is never just
    /// dropped.
    ///
    /// Runs as one account operation, after everything enqueued before it and before anything enqueued after it (a
    /// sign-in started meanwhile waits for it, so the sign-out can never erase it). It is never cancelled.
    public func signOut() async {
        let ticket = operations.supersede(immune: true)
        requestedSignIn = nil
        try? await operations.run(ticket) { ticket in
            await self.performSignOut(ticket)
        }
    }

    /// `signOut()` for an app-level sign-out started for `signIn` (the sign-in current when it started): when sync is
    /// asked for, or signed in by, another sign-in by then (another user, or the same user signing in again), this
    /// sign-out is older than it and does nothing. The user id alone can't tell the same user's sign-ins apart; the
    /// generation can. nil signs out whoever is signed in.
    public func signOut(ifSignIn signIn: SyncSignIn?) async {
        // A newer sign-in already asked for: this sign-out neither cancels it nor waits for it.
        if let signIn, let latest = requestedSignIn, latest != signIn { return }
        let ticket = operations.supersede(immune: true)
        requestedSignIn = nil
        try? await operations.run(ticket) { ticket in
            if let signIn, !self.isSignedIn(as: signIn) { return }
            await self.performSignOut(ticket)
        }
    }

    /// Whether sync is signed in by `signIn`, or not by any other: compared by user and generation once a sign-in ran
    /// in this process; before that (credentials restored at launch) only the saved user can be compared.
    private func isSignedIn(as signIn: SyncSignIn) -> Bool {
        if let current = authSignIn { return current == signIn }
        if let user = authUserID ?? credentials?.userID { return user == signIn.userID }
        return true
    }

    /// The sign-in the newest `signIn` call was for, nil after a sign-out was asked for.
    @ObservationIgnored private var requestedSignIn: SyncSignIn?

    /// The Clerk user sync is signed in as (nil when signed out).
    public var signedInUserID: String? { authUserID ?? credentials?.userID }

    /// The app-level sign-in sync is signed in by (nil when signed out, or restored at launch and not signed in yet).
    public var currentSignIn: SyncSignIn? { authUserID == nil ? nil : authSignIn }

    private func performSignOut(_ ticket: AccountOperations.Ticket) async {
        var keepRegistration = false
        if let credentials, let id = selfID {
            let removed: Bool
            do {
                _ = try await withTimeout(.seconds(5), "The sync server") { [self] in
                    try await self.callReportingCodes("devices:remove", DeviceArgs(token: credentials.token, deviceId: id),
                                                      as: ServerNowResult.self, ticket: ticket)
                }
                removed = true
            } catch let error as ConvexClientError where error.code == "unauthorized" || error.code == "notFound" {
                removed = true   // gone already (removed elsewhere, or a retry of a removal that landed)
            } catch {
                removed = false
            }
            if !removed, !setAsideForRemoval(token: credentials.token, userID: credentials.userID) {
                // Nothing to remember it by: the credentials themselves stay, signed out of the session.
                keepRegistration = true
            }
        }
        if let saved = savedPendingRegistration(), saved.token != credentials?.token {
            var removed = false
            if saved.userID == authUserID, saved.deploymentURL == client.deploymentURL {
                do {
                    let result = try await withTimeout(.seconds(5), "The sync server") { [self] in
                        try await self.callReportingCodes("account:unregister", TokenArgs(token: saved.token), as: UnregisterResult.self, ticket: ticket)
                    }
                    // The registration may still be on its way: "not found" alone doesn't settle it, only the server
                    // saying it removed the device or refuses the token from now on. Otherwise it is recorded below.
                    removed = result.settled
                } catch {}
            }
            if !removed, !setAsideForRemoval(token: saved.token, userID: saved.userID, deploymentURL: saved.deploymentURL) {
                keepRegistration = true
            }
        }
        forgetNow(keepRegistration: keepRegistration)
        authScope = nil
        authUserID = nil
        authSignIn = nil
        await client.setAuth(nil)
        stopNow()
    }

    #if DEBUG
    /// Snapshot runs only: shows a made-up registration and devices without a server. Nothing is saved or sent.
    /// `requests` are shown as verified requests for the key (the "Allow …?" alert and the device rows).
    public func preview(selfID: DeviceID, devices: [SyncDevice], keyStatus: KeyStatus, requests: [KeyRequest] = [], warning: String? = nil) {
        registration = .registered(deviceID: selfID, libraryID: LibraryID(rawValue: "preview"))
        self.devices = devices
        self.keyStatus = keyStatus
        previewRequests = requests
        previewWarning = warning
    }
    var previewRequests: [KeyRequest]?
    var previewWarning: String?
    #endif

    public func rename(_ device: DeviceID, to name: String) async throws {
        _ = try await call("devices:rename", RenameArgs(token: try requireToken(), deviceId: device, name: name), as: ServerNowResult.self)
    }

    /// Removes a device and revokes its token. Removing this device signs it out of sync (`forget()`).
    public func remove(_ device: DeviceID) async throws {
        try await operations.run { ticket in
            let removingSelf = device == self.selfID
            do {
                _ = try await self.call("devices:remove", DeviceArgs(token: try self.requireToken(), deviceId: device), as: ServerNowResult.self, ticket: ticket)
            } catch SyncError.unknownDevice where removingSelf {
                // A retry of a removal that already went through (socket, then HTTP).
            }
            if removingSelf, self.selfID == device { self.forget() }
        }
    }

    /// Starts the session of a new registration. Returns whether its credentials were saved.
    @discardableResult
    private func adopt(_ new: SyncCredentials, keyRevision: Int) -> Bool {
        let serverKey = serverKeyID
        endSession()
        credentials = new
        let saved = store.persist(new)
        registration = .registered(deviceID: new.deviceID, libraryID: new.libraryID)
        serverKeyID = serverKey
        appliedKeyRevision = keyRevision
        signIns.beginSession(scope: Self.scope(new))
        loadLedger()
        updateKeyStatus()
        if started { openSubscriptions() }
        updateActivity()
        return saved
    }

    /// Drops the registration locally (after removal or a revoked token), and any registration in flight. Every
    /// account operation still queued or running for it stops (except a sign-out).
    public func forget() {
        _ = operations.supersede()
        forgetNow()
    }

    /// `forget()` inside an operation. `keepRegistration` keeps the saved credentials and registration: a sign-out
    /// that couldn't record the device it owes the server.
    private func forgetNow(keepRegistration: Bool = false) {
        endSession()
        credentials = nil
        if !keepRegistration {
            store.save(nil)
            dropPendingRegistration()
        }
        pending = nil
        registration = .none
        signIns.beginSession(scope: nil)
        loadLedger()
        updateKeyStatus()
        updateActivity()
    }

    /// Everything that belongs to the current library: its live results, the command queue, waiters for acks
    /// and the sign-in and settings sync state. Work still running for it drops its results.
    private func endSession() {
        closeSubscriptions()
        lastError = nil
        devices = []
        playback = [:]
        outgoing = []
        incoming = []
        vaultEntries = nil
        settingEntries = nil
        playbackRows = []
        sealedSettings = nil
        wireOutgoing = []
        serverKeyID = nil
        handledCommands = []
        commandQueue = []
        failedKeyBlobs = []
        pendingGrantKey = nil
        rotationNeeded = false
        appliedKeyRevision = 0
        pendingList = nil
        let waiters = ackWaiters
        ackWaiters = [:]
        for continuation in waiters.values.flatMap(\.values) { continuation.resume(throwing: SyncError.notPaired) }
        settings.beginSession()
    }

    /// Which deployment, library and device local sync state belongs to.
    static func scope(_ credentials: SyncCredentials) -> String {
        "\(credentials.deploymentURL.absoluteString)|\(credentials.libraryID.rawValue)|\(credentials.deviceID.rawValue)"
    }

    func requireToken() throws -> String {
        guard let token = credentials?.token else { throw SyncError.notPaired }
        return token
    }

    // MARK: Live queries

    private func openSubscriptions() {
        closeSubscriptions()
        guard let token = credentials?.token else { return }
        let args = TokenArgs(token: token)
        // The queries belong to this session's identity: the client drops them the moment it changes.
        let scope = authScope
        subscriptionTasks = [
            follow(client.subscribe("devices:list", args: args, as: DeviceListResult.self, scope: scope), token: token) { service, list in
                service.apply(list, token: token)
            },
            follow(client.subscribe("vault:list", args: args, as: [VaultEntry].self, scope: scope), token: token) { service, entries in
                service.vaultEntries = entries
                service.signIns.reconcileAll()
            },
            follow(client.subscribe("settings:list", args: args, as: [SealedSettingEntry].self, scope: scope), token: token) { service, entries in
                service.sealedSettings = entries
                service.applySettings()
            },
            follow(client.subscribe("playback:list", args: args, as: [PlaybackRow].self, scope: scope), token: token) { service, rows in
                service.playbackRows = rows
                service.openPlayback()
            },
            follow(client.subscribe("commands:incoming", args: args, as: [WireIncomingCommand].self, scope: scope), token: token) { service, commands in
                service.receive(commands)
            },
            follow(client.subscribe("commands:outgoing", args: args, as: [WireOutgoingCommand].self, scope: scope), token: token) { service, commands in
                service.wireOutgoing = commands
                service.openOutgoing()
                service.resolveAckWaiters()
            },
        ]
    }

    /// Applies each result of a live query of the session with device `token`. A result is applied only while that
    /// session is current: one delivered before the session ended but handled after (it was already on its way to the
    /// main actor when `endSession` cancelled the task) is dropped, success or failure, so a late vault, settings,
    /// playback, command or device list result of one session never lands in the next.
    private func follow<Value: Sendable>(
        _ stream: AsyncStream<Result<Value, ConvexClientError>>,
        token: String,
        _ apply: @escaping @MainActor (SyncService, Value) -> Void
    ) -> Task<Void, Never> {
        Task { [weak self] in
            for await result in stream {
                guard let self, !Task.isCancelled else { return }
                guard self.credentials?.token == token else { continue }
                switch result {
                case .success(let value): apply(self, value)
                case .failure(let error): self.report(error, token: token)
                }
            }
        }
    }

    private func closeSubscriptions() {
        for task in subscriptionTasks { task.cancel() }
        subscriptionTasks = []
    }

    /// An error from a call or a live query made with `token` (the session's device token then). Errors of a session
    /// that ended are dropped. The server no longer knowing the device (`removedFromLibrary`) signs it out, as an
    /// account operation queued after whatever is already queued: it acts only if that session is still the current
    /// one when its turn comes, so an old session's late error never ends a sign-in started after it.
    func report(_ error: any Error, token: String?) {
        if error is CancellationError { return }
        guard let token, token == credentials?.token else { return }
        let sync = SyncError.from(error)
        lastError = sync
        guard sync == .removedFromLibrary else { return }
        operations.enqueue("removed:\(token)") { [weak self] _ in
            guard let self, self.credentials?.token == token else { return }
            self.forgetNow()
            self.lastError = .removedFromLibrary
            self.onRemoved?()
        }
    }

    // MARK: Commands

    /// Sends a command. A takeover's queue window is sealed for `device` first (this device needs the key for that).
    public func send(_ command: SyncCommand, to device: DeviceID) async throws -> CommandID {
        let token = try requireToken()
        let wire: WireCommand
        if case .takeOver(let state) = command {
            let window = QueueWindow(entries: state.queue, index: state.index)
            wire = .takeOver(anchor: state.anchor, content: try seal(window, kind: .command, context: device.rawValue))
        } else {
            wire = .plain(command)
        }
        let args = SendCommandArgs(token: token, toDeviceId: device, command: wire, clientId: UUID().uuidString)
        return try await call("commands:send", args, as: SendCommandResult.self).commandId
    }

    /// Waits until the target acks `command` (seen through the live `outgoing` list).
    public func waitForAck(_ command: CommandID, timeout: Duration = .seconds(30)) async throws -> CommandResult {
        if let result = outgoing.first(where: { $0.id == command })?.result { return result }
        let waiter = UUID()
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.failAckWaiter(command, waiter)
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            ackWaiters[command, default: [:]][waiter] = continuation
        }
    }

    private func failAckWaiter(_ command: CommandID, _ waiter: UUID) {
        guard let continuation = ackWaiters[command]?.removeValue(forKey: waiter) else { return }
        if ackWaiters[command]?.isEmpty == true { ackWaiters[command] = nil }
        continuation.resume(throwing: SyncError.timedOut("The other device"))
    }

    private func resolveAckWaiters() {
        for command in outgoing {
            guard let result = command.result, let waiters = ackWaiters.removeValue(forKey: command.id) else { continue }
            for continuation in waiters.values { continuation.resume(returning: result) }
        }
    }

    /// Opens the commands waiting for this device. A takeover that doesn't open here (this device has no key yet, or it
    /// was sealed under another one) never reaches the handler: it is acked at once with why.
    private func receive(_ commands: [WireIncomingCommand]) {
        var opened: [IncomingCommand] = []
        for wire in commands {
            switch wire.command {
            case .plain(let command):
                opened.append(IncomingCommand(id: wire.id, fromDeviceId: wire.fromDeviceId, command: command, createdAt: wire.createdAt, expiresAt: wire.expiresAt))
            case .takeOver(let anchor, let content):
                if let window = openTakeOver(content, from: wire.fromDeviceId) {
                    let state = HandoffState(window: window, anchor: anchor)
                    opened.append(IncomingCommand(id: wire.id, fromDeviceId: wire.fromDeviceId, command: .takeOver(state), createdAt: wire.createdAt,
                                                  expiresAt: wire.expiresAt))
                } else if !handledCommands.contains(wire.id) {
                    remember(wire.id)
                    let reason: CommandFailure = contentKey == nil ? .needsKey : .unreadable
                    Task { [weak self] in try? await self?.ack(wire.id, CommandResult(ok: false, reason: reason)) }
                }
            }
        }
        incoming = opened
        processIncoming()
    }

    private func openTakeOver(_ content: SealedContent, from sender: DeviceID) -> QueueWindow? {
        guard let key = credentials?.libraryKey, let library = credentials?.libraryID, let me = selfID else { return nil }
        guard let window = (try? ContentSealing.open(content, as: QueueWindow.self, kind: .command, library: library, writer: sender,
                                                     context: me.rawValue, key: key)) ?? nil,
              window.entries.indices.contains(window.index) else { return nil }
        return window
    }

    private func remember(_ command: CommandID) {
        handledCommands.append(command)
        if handledCommands.count > 200 { handledCommands.removeFirst(handledCommands.count - 200) }
    }

    private func processIncoming() {
        guard commandHandler != nil else { return }
        let now = clock.now()
        for command in incoming where !handledCommands.contains(command.id) {
            remember(command.id)
            onCommandReceived?(command, now - command.createdAt)
            commandQueue.append(command)
        }
        runCommands()
    }

    private func runCommands() {
        guard !runningCommands, !commandQueue.isEmpty else { return }
        runningCommands = true
        Task { [weak self] in
            while let self, !self.commandQueue.isEmpty {
                let command = self.commandQueue.removeFirst()
                let result: CommandResult
                if self.clock.now() > command.expiresAt {
                    result = CommandResult(ok: false, reason: .expired)
                } else if let handler = self.commandHandler {
                    result = await handler(command)
                } else {
                    result = CommandResult(ok: false, reason: .unavailable)
                }
                try? await self.ack(command.id, result)
            }
            self?.runningCommands = false
        }
    }

    /// Acks a command with what happened. The server gets the outcome and a reason code; a message (it may name a
    /// song) goes only sealed, and only when this device holds the key, else the sender shows the reason's own words.
    public func ack(_ command: CommandID, _ result: CommandResult) async throws {
        let token = try requireToken()
        let content = result.message.flatMap { message in
            try? seal(ResultContent(message: message), kind: .result, context: command.rawValue)
        }
        let wire = WireResult(ok: result.ok, reason: result.ok ? nil : (result.reason ?? .failed), content: result.ok ? nil : content)
        _ = try await call("commands:ack", AckArgs(token: token, commandId: command, result: wire), as: ServerNowResult.self)
    }

    /// The outgoing list with each result opened: its sealed message, or what its reason says about the target.
    private func openOutgoing() {
        outgoing = wireOutgoing.map { wire in
            let result = wire.result.map { result -> CommandResult in
                if result.ok { return .success }
                let reason = result.reason ?? .failed
                let message = result.content.flatMap { content in
                    open(content, as: ResultContent.self, kind: .result, writer: wire.toDeviceId, context: wire.id.rawValue)?.message
                }
                let name = devices.first { $0.id == wire.toDeviceId }?.name ?? "The other device"
                return CommandResult(ok: false, message: message ?? reason.message(device: name), reason: reason)
            }
            return OutgoingCommand(id: wire.id, toDeviceId: wire.toDeviceId, kind: wire.kind, createdAt: wire.createdAt, expiresAt: wire.expiresAt,
                                   ackedAt: wire.ackedAt, result: result)
        }
    }

    // MARK: Playback

    /// Publishes this device's player. With `queue` (it or the current index changed), what plays goes sealed: the
    /// current track with its place, and the window. A device without the key publishes no content instead (and drops
    /// any it published under a key it no longer has); the anchor always goes.
    public func publish(anchor: PlaybackAnchor, queue: QueueWindow?) async throws {
        let token = try requireToken()
        let content: PublishArgs.Content
        if let queue {
            if contentKey != nil {
                let now = PlaybackContent(track: queue.current.track, index: queue.index, queueLength: queue.entries.count)
                content = .replace(playback: try seal(now, kind: .playback), queue: try seal(queue, kind: .queue))
            } else {
                content = .drop
            }
        } else {
            content = .keep
        }
        _ = try await call("playback:publish", PublishArgs(token: token, anchor: anchor, content: content), as: PublishResult.self)
    }

    public func clearPlayback() async throws {
        _ = try await call("playback:clear", TokenArgs(token: try requireToken()), as: ServerNowResult.self)
    }

    /// A device's queue window, fresh from the server. nil when it has nothing loaded.
    public func fetchQueue(of device: DeviceID) async throws -> QueueWindow? {
        let token = credentials?.token
        do {
            let args = DeviceArgs(token: try requireToken(), deviceId: device)
            let result = try await withTimeout(.seconds(15), "The sync server") { [client] in
                try await client.query("playback:queue", args: args, as: QueueResult?.self)
            }
            guard let result else { return nil }
            guard credentials?.libraryKey != nil else { throw SyncError.needsKey(device: nil) }
            guard let library = credentials?.libraryID,
                  let window = try openThrowing(result.content, as: QueueWindow.self, kind: .queue, library: library, writer: device),
                  window.entries.indices.contains(window.index) else {
                throw SyncError.server("That device's queue is sealed with a key this device doesn't have yet. Try again in a moment.")
            }
            return window
        } catch {
            let sync = SyncError.from(error)
            if sync == .removedFromLibrary { report(error, token: token) }
            throw sync
        }
    }

    /// The device list as the server has it now, outside the live query (whose last result may be older).
    func fetchDeviceList(token: String) async throws -> DeviceListResult {
        try await withTimeout(.seconds(15), "The sync server") { [client] in
            try await client.query("devices:list", args: TokenArgs(token: token), as: DeviceListResult.self)
        }
    }

    // MARK: Vault and settings

    public func putVault(_ provider: ProviderID, sealed: String, keyId: String, baseRevision: Int) async throws -> VaultWrite {
        let args = VaultPutArgs(token: try requireToken(), provider: provider, sealed: sealed, keyId: keyId, baseRevision: baseRevision)
        let result = try await call("vault:put", args, as: VaultWriteResult.self)
        return VaultWrite(updatedAt: result.updatedAt, revision: result.revision)
    }

    public func signOutVault(_ provider: ProviderID, baseRevision: Int) async throws -> VaultWrite {
        let args = VaultSignOutArgs(token: try requireToken(), provider: provider, baseRevision: baseRevision)
        let result = try await call("vault:signOutEverywhere", args, as: VaultWriteResult.self)
        return VaultWrite(updatedAt: result.updatedAt, revision: result.revision)
    }

    /// Writes one setting, its value sealed under the account's key (the setting key bound in).
    public func putSetting(_ key: String, value: String, writeId: String, ifAbsent: Bool) async throws -> ServerMillis {
        let token = try requireToken()
        let sealed = try seal(Data(value.utf8), kind: .setting, context: key)
        let args = SettingPutArgs(token: token, key: key, value: sealed, writeId: writeId, ifAbsent: ifAbsent ? true : nil)
        return try await call("settings:put", args, as: UpdatedResult.self).updatedAt
    }

    // MARK: Sealed content

    /// The key this device seals content with: the vault key it holds, when it is the account's.
    var contentKey: LibraryKey? {
        guard let key = credentials?.libraryKey, key.id == serverKeyID else { return nil }
        return key
    }

    public var canSealContent: Bool { contentKey != nil }

    /// Seals what this device writes (`writer` is this device).
    func seal(_ plaintext: Data, kind: ContentKind, context: String = "") throws -> SealedContent {
        guard let key = contentKey, let library = credentials?.libraryID, let me = selfID else { throw SyncError.needsKey(device: nil) }
        return try ContentSealing.seal(plaintext, kind: kind, library: library, writer: me, context: context, key: key)
    }

    func seal<T: Encodable>(_ value: T, kind: ContentKind, context: String = "") throws -> SealedContent {
        try seal(try JSONEncoder().encode(value), kind: kind, context: context)
    }

    /// Opens what `writer` wrote with the key this device holds; nil when it isn't under that key or doesn't open.
    func open<T: Decodable>(_ sealed: SealedContent, as type: T.Type, kind: ContentKind, writer: DeviceID, context: String = "") -> T? {
        guard let library = credentials?.libraryID else { return nil }
        return (try? openThrowing(sealed, as: type, kind: kind, library: library, writer: writer, context: context)) ?? nil
    }

    private func openThrowing<T: Decodable>(_ sealed: SealedContent, as type: T.Type, kind: ContentKind, library: LibraryID, writer: DeviceID,
                                            context: String = "") throws -> T? {
        guard let key = credentials?.libraryKey else { return nil }
        return try ContentSealing.open(sealed, as: type, kind: kind, library: library, writer: writer, context: context, key: key)
    }

    /// The key rows are opened with, or the one this device seals with, changed: open everything again, and let the
    /// coordinator publish its queue under the new key (or with no content).
    private func contentKeysChanged() {
        let opening = credentials?.libraryKey?.id
        let sealing = contentKey?.id
        guard opening != openingKeyMark || sealing != sealingKeyMark else { return }
        let sealingChanged = sealing != sealingKeyMark
        openingKeyMark = opening
        sealingKeyMark = sealing
        openPlayback()
        applySettings()
        openOutgoing()
        if sealingChanged { onContentKeyChange?() }
    }

    private func openPlayback() {
        var rows: [DeviceID: RemotePlayback] = [:]
        for row in playbackRows where rows[row.deviceId] == nil {
            var opened = RemotePlayback(deviceId: row.deviceId, track: nil, index: nil, queueLength: nil, queueVersion: row.queueVersion,
                                        anchor: row.anchor, updatedAt: row.updatedAt, content: row.content == nil ? RemotePlayback.Content.none : .sealed)
            if let sealed = row.content, let now = open(sealed, as: PlaybackContent.self, kind: .playback, writer: row.deviceId) {
                opened.track = now.track
                opened.index = now.index
                opened.queueLength = now.queueLength
                opened.content = .open
            }
            rows[row.deviceId] = opened
        }
        playback = rows
    }

    /// Hands the settings that open here to `SettingsSync`. Nothing until this device can seal with the account's key
    /// (`contentKey`, not just a saved key: at launch the saved key is known before the server's `keyId` arrives, and a
    /// first sync then would try fill-ins it can't seal and lose them). It neither reads nor fills in settings until then.
    func applySettings() {
        guard let sealed = sealedSettings, let key = contentKey, let library = credentials?.libraryID else {
            settingEntries = nil
            return
        }
        let opened = sealed.compactMap { entry -> SettingEntry? in
            guard let data = try? ContentSealing.open(entry.value, kind: .setting, library: library, writer: entry.updatedBy, context: entry.key,
                                                      key: key),
                  let value = String(data: data, encoding: .utf8) else { return nil }
            return SettingEntry(key: entry.key, value: value, updatedAt: entry.updatedAt, updatedBy: entry.updatedBy, writeId: entry.writeId)
        }
        settingEntries = opened
        settings.apply(opened, present: Set(sealed.map(\.key)))
    }

    // MARK: Calls

    func call<Args: Encodable & Sendable, Result: Decodable & Sendable & ServerTimed>(
        _ path: String, _ args: Args, as type: Result.Type, ticket: AccountOperations.Ticket? = nil
    ) async throws -> Result {
        let token = credentials?.token
        do {
            return try await callReportingCodes(path, args, as: type, ticket: ticket)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ConvexClientError where error.code == "conflict" {
            guard case .function(_, let data) = error else { throw SyncConflict(revision: nil) }
            throw SyncConflict(revision: data?["revision"]?.doubleValue.map { Int($0) })
        } catch {
            let sync = SyncError.from(error)
            if sync == .removedFromLibrary { report(error, token: token) }
            throw sync
        }
    }

    /// `call`, with the server's error as it came (`ConvexClientError`, whose `code` says "forbidden", "conflict"…).
    ///
    /// The call belongs to the identity and the account epoch current when it is made, both captured before the
    /// first await: the client refuses it (`.authChanged`) if the identity changed before it was enqueued or sent,
    /// and an answer that arrives after the account moved on (`ticket`, or any new epoch without one) is not
    /// returned: the call throws `CancellationError` instead, so nobody acts on it.
    func callReportingCodes<Args: Encodable & Sendable, Result: Decodable & Sendable & ServerTimed>(
        _ path: String, _ args: Args, as type: Result.Type, ticket: AccountOperations.Ticket? = nil
    ) async throws -> Result {
        let scope = authScope
        let epoch = operations.epoch
        func check() throws {
            if let ticket { try ticket.check(operations) } else if epoch != operations.epoch { throw CancellationError() }
        }
        if !started { start() }
        await client.start()
        try check()
        // A call made while suspended in the background woke the socket; put it back to sleep afterwards.
        defer { if !isAwake { armSuspend() } }
        let timed: Timed<Result>
        do {
            timed = try await client.mutation(path, args: args, as: Result.self, scope: scope)
        } catch {
            try check()
            throw error
        }
        try check()
        clock.record(serverNow: timed.value.serverNow, sentAt: timed.sentAt, receivedAt: timed.receivedAt)
        return timed.value
    }
}

/// Runs `operation`, throwing `SyncError.timedOut(what)` if it takes longer than `timeout`.
func withTimeout<T: Sendable>(_ timeout: Duration, _ what: String, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw SyncError.timedOut(what)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

protocol ServerTimed { var serverNow: ServerMillis { get } }
extension ServerNowResult: ServerTimed {}
extension RegisterResult: ServerTimed {}
extension PublishResult: ServerTimed {}
extension SendCommandResult: ServerTimed {}
extension ClaimKeyResult: ServerTimed {}
extension RotateKeyResult: ServerTimed {}
extension UpdatedResult: ServerTimed {}
extension VaultWriteResult: ServerTimed {}
extension UnregisterResult: ServerTimed {}
