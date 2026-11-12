import AppKit
import MedleyCore
import MedleySync
import Network
import Observation
import SpotifyKit
import SwiftUI
import YouTubeMusicKit

// The provider kits ship transfers with `SignInTransfer`'s exact shape; the conformance lives in the app. (No
// `@retroactive` here: in SwiftPM the kits are in the same package. The iOS app, an Xcode project, needs it.)
extension YouTubeMusicSignInTransfer: SignInTransfer {}
extension SpotifySignInTransfer: SignInTransfer {}

/// Medley Sync on the Mac: the `SyncService` session, the `SyncCoordinator` on the one player, the sign-in
/// transfers, playback settings and recent searches. `AppModel.launch()` creates it once the providers restored
/// their sessions (never in sample-data or snapshot runs). See docs/sync-design.md.
///
/// It owns the Medley account (`AccountService`: Clerk sign-in against the chosen server) and fills the Mac's sync
/// slots: the welcome sheet, `model.playerBanner` ("Continue from iPhone"), the Devices popover in the player bar,
/// Settings › Account, the "Allow <device>…" question, and the sign-out question in Settings › Services.
@MainActor
@Observable
final class SyncHub {
    let account: AccountService
    let service: SyncService
    let coordinator: SyncCoordinator
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored let options: Options
    @ObservationIgnored private(set) var transfers: [any SignInTransfer] = []

    /// The Devices popover in the player bar.
    var isDevicesPresented = false
    /// The Sign In sheet.
    var isSignInPresented = false
    /// The custom server sheet (welcome screen and Settings › Account).
    var isServerPresented = false
    /// The provider whose "this Mac or all devices" sign-out question is up (Settings › Services).
    var signOutPrompt: ProviderID?
    /// The remote device whose controls the Devices popover shows.
    var selectedDevice: DeviceID?
    /// What the "Continue from" banner shows (kept in step with `coordinator.continueSuggestion`, which is computed).
    private(set) var banner: SyncCoordinator.ContinueSuggestion?
    /// The last handoff or remote failure, for the popover.
    var message: String?
    /// Key requests the listener closed without answering, so they don't come straight back (a new request from the
    /// same device does).
    var dismissedKeyRequests = DismissedKeyRequests()

    var busyDevice: DeviceID? {
        switch coordinator.phase {
        case .idle: nil
        case .pulling(let id), .pushing(let id): id
        }
    }

    /// The device asking for this Mac's sign-in key that the "Allow …?" alert shows, if any.
    var pendingKeyRequest: SyncService.KeyRequest? {
        dismissedKeyRequests.firstShown(in: service.keyRequests)
    }

    /// Launch arguments for live checks (see `SyncSelfTest`). Debug builds only; read from the command line, never
    /// from saved defaults, so nothing persistent can turn the self-test (which accepts fake sign-ins) on.
    struct Options {
        /// `-MedleySyncSelfTest YES`: log sync events and take commands from a file.
        var selfTest = false
        /// `-MedleySyncDir <path>`: where the self-test log and command file live.
        var directory: URL?
        /// `-MedleySyncState <path>`: keep the device token in this 0600 file instead of the Keychain, so a test run
        /// never touches (or is touched by) another Medley build's sync on a shared Mac.
        var stateFile: URL?
        /// `-MedleySyncDeviceName <name>`: the name this Mac shows to the others, for this run only.
        var deviceName: String?
        /// `-MedleySyncJWTFile <path>`: sign in to sync with a Clerk session JWT read from this file (template
        /// "convex") instead of the Clerk sign-in, so a live test needs no browser. Its `sub` is the user.
        var jwtFile: URL?
        /// Where this run keeps every Keychain account (provider sign-ins included) instead of the Keychain:
        /// `-MedleyKeychainDir <path>`, else `<MedleySyncDir>/keychain`, else a temporary folder. Always set in a
        /// self-test run, so the test never restores, overwrites, deletes or uploads the Mac's real sign-ins.
        var keychainDirectory: URL?

        /// Release builds ignore all of it.
        init(arguments: [String] = ProcessInfo.processInfo.arguments) {
            #if DEBUG
            func value(_ name: String) -> String? {
                guard let i = arguments.firstIndex(of: "-\(name)"), arguments.indices.contains(i + 1) else { return nil }
                return arguments[i + 1]
            }
            selfTest = value("MedleySyncSelfTest").map { ["yes", "1", "true"].contains($0.lowercased()) } ?? false
            guard selfTest else { return }
            directory = value("MedleySyncDir").map { URL(fileURLWithPath: $0, isDirectory: true) }
            stateFile = value("MedleySyncState").map { URL(fileURLWithPath: $0) }
            deviceName = value("MedleySyncDeviceName")
            jwtFile = value("MedleySyncJWTFile").map { URL(fileURLWithPath: $0) }
            keychainDirectory = value("MedleyKeychainDir").map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? directory?.appendingPathComponent("keychain", isDirectory: true)
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("medley-selftest-keychain-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            #endif
        }

        #if DEBUG
        /// Self-test runs: points `MedleyCore.Keychain` at files in `keychainDirectory` before anything reads it.
        /// Call first thing at launch, before the providers restore their sessions. Debug builds only.
        static func isolateKeychainForSelfTest(arguments: [String] = ProcessInfo.processInfo.arguments) {
            let options = Options(arguments: arguments)
            guard options.selfTest, let directory = options.keychainDirectory else { return }
            Keychain.isolate(in: directory)
        }
        #endif
    }

    /// The name this Mac shows to the others (Settings › Sync). Defaults to the computer's name.
    static let deviceNameKey = "syncDeviceName"

    @ObservationIgnored private var bannerTimer: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var lastPath: (satisfied: Bool, interfaces: [String])?
    @ObservationIgnored private var lastNetworkReconnect: ContinuousClock.Instant?
    @ObservationIgnored private var importRetry: Task<Void, Never>?
    @ObservationIgnored private var asleep = false
    @ObservationIgnored private var lastForeground: Bool?
    @ObservationIgnored var log: SyncTestLog?
    /// The "Allow …?" alert on the main window (`KeyRequestPrompter`).
    @ObservationIgnored private(set) var keyPrompter: KeyRequestPrompter?

    init(model: AppModel, options: Options) {
        self.model = model
        self.options = options
        var info = DeviceInfo.current()
        if let name = (options.deviceName ?? UserDefaults.standard.string(forKey: Self.deviceNameKey))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            info.name = String(name.prefix(64))
        }
        let store: any SyncCredentialStore = options.stateFile.map { FileCredentialStore(url: $0) } ?? KeychainCredentialStore()
        account = AccountService(hostedURL: SyncService.deploymentURL(), store: CredentialClerkStateStore(store: store))
        service = SyncService(deploymentURL: account.server.url, deviceInfo: info, credentials: store)
        coordinator = SyncCoordinator(service: service, player: model.player)
        Self.routeTransport(of: coordinator, to: model)
        // YouTube Music plays without an account; Spotify needs one.
        coordinator.canPlay = { [weak model] id in
            guard let provider = model?.provider(id) else { return false }
            return id == .youtubeMusic || provider.isSignedIn
        }
        keyPrompter = KeyRequestPrompter(hub: self)
    }

    /// Remote Play/Pause, Next, Previous, Stop, seeks and takeovers count as transport choices, like the media keys:
    /// a playback request still loading here gives up instead of replacing what the other device asked for. So does
    /// the pause after this Mac hands its playback off. A handoff that replaces the queue here (a takeover, Play Here)
    /// is a new playback choice: a playlist already playing stops appending its pages into the queue that arrived.
    static func routeTransport(of coordinator: SyncCoordinator, to model: AppModel) {
        coordinator.willRunTransportCommand = { [weak model] in model?.noteTransportChoice() }
        coordinator.willReplaceQueue = { [weak model] in model?.beginPlayRequest() }
    }

    // MARK: Start

    /// Call once, after the providers restored their sessions. Links that arrived during launch run after this.
    func start() {
        guard let model else { return }
        #if DEBUG
        if options.selfTest { SyncSelfTest.start(self) }
        #endif
        // No connection for someone who isn't signed in: it opens once the account is.
        Task { await startAccount() }
        coordinator.attach()
        routeRemoteVolume()

        for provider in model.providers {
            if let youtube = provider as? YouTubeMusicProvider {
                transfers.append(YouTubeMusicSignInTransfer(provider: youtube, verify: testVerifier(youtube)))
            } else if let spotify = provider as? SpotifyProvider {
                let transfer = SpotifySignInTransfer(provider: spotify, verify: testVerifier(spotify))
                // A refresh Spotify refuses first looks for the token another device rotated (two devices refreshed at once).
                transfer.syncedSignIn = { [weak self] in self?.openVaultEntry(.spotify) }
                transfers.append(transfer)
            }
        }
        for transfer in transfers { service.signIns.register(transfer) }
        service.signIns.onImport = { [weak self] i in self?.signInArrived(i) }
        trackImportFailures()

        service.settings.bind(model.playback.settings)
        service.settings.observeRecentSearches(current: { [weak model] in model?.recentSearches ?? [] }) { [weak model] list in
            model?.replaceRecentSearches(list)
        }
        model.onRecentSearchesChanged = { [weak self] list in
            self?.service.settings.set(SettingsSync.recentSearchesKey, list)
        }

        URLRouter.shared.handler = { [weak self] url in self?.handle(url) ?? false }
        service.onRemoved = { [weak self] in self?.removedElsewhere() }
        account.onSessionEnded = { [weak self] in self?.sessionEnded() }
        observeLifecycle()
        trackBanner()
        trackApproval()
        log?.write("STARTED device \(service.deviceInfo.name) registered=\(service.isRegistered) key=\(service.keyStatus) keychain=\(Keychain.backendName)")
    }

    #if DEBUG
    /// Self-test runs accept the probe's fake sign-ins (and check real ones for real). Debug builds only.
    private func testVerifier(_ youtube: YouTubeMusicProvider) -> YouTubeMusicSignInTransfer.Verifier? {
        options.selfTest ? YouTubeMusicSignInTransfer.acceptingTestSignIns() : nil
    }
    private func testVerifier(_ spotify: SpotifyProvider) -> SpotifySignInTransfer.Verifier? {
        options.selfTest ? SpotifySignInTransfer.acceptingTestSignIns(provider: spotify) : nil
    }
    #else
    private func testVerifier(_ youtube: YouTubeMusicProvider) -> YouTubeMusicSignInTransfer.Verifier? { nil }
    private func testVerifier(_ spotify: SpotifyProvider) -> SpotifySignInTransfer.Verifier? { nil }
    #endif

    /// Ends this sync session (switching servers): no more connection, observers or timers. A new hub takes over.
    func stop() {
        keyPrompter?.stop()
        coordinator.detach()
        service.stop()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
        pathMonitor?.cancel()
        pathMonitor = nil
        bannerTimer?.cancel()
        importRetry?.cancel()
        URLRouter.shared.handler = nil
    }

    #if DEBUG
    /// Snapshot runs: a hub that never connects, keeps nothing in the Keychain and shows made-up devices.
    static func preview(model: AppModel) -> SyncHub {
        var options = Options(arguments: [])
        options.stateFile = FileManager.default.temporaryDirectory.appendingPathComponent("medley-preview-\(UUID().uuidString).json")
        return SyncHub(model: model, options: options)
    }
    #endif

    // MARK: Account

    /// Reads the saved sign-in and the server's configuration, then connects when signed in. Shows the welcome
    /// sheet once, to someone who isn't signed in.
    private func startAccount() async {
        #if DEBUG
        if let file = options.jwtFile {
            await connect(JWTFileTokens(url: file))
            return
        }
        #endif
        await account.load()
        // A launch that couldn't load the server's sign-in configuration (offline) connects once it loads.
        account.onReady = { [weak self] in
            guard let self, self.account.isSignedIn else { return }
            Task { await self.connect() }
        }
        // Someone who isn't signed in meets the account in the first-run flow's Sync step (`FirstRunFlow`).
        if account.isSignedIn { await connect() }
    }

    /// Signs this Mac in to sync as the signed-in account. Retried on wake and network changes while it fails.
    func connect(_ tokens: (any AuthTokenProvider)? = nil) async {
        guard let tokens = tokens ?? account.tokenProvider else { return }
        let user: String?
        #if DEBUG
        if let jwt = tokens as? JWTFileTokens { user = try? jwt.userID() } else { user = account.user?.id }
        #else
        user = account.user?.id
        #endif
        guard let user else { return }
        do {
            try await service.signIn(auth: tokens, userID: user, generation: account.sessionGeneration)
            connectFailure = nil
            log?.write("ACCOUNT signed in to sync as \(service.selfID?.rawValue ?? "?"); key \(service.keyStatus)")
        } catch is CancellationError {
            // A sign-out, a newer sign-in or a server change overtook this one; it changed nothing.
        } catch {
            connectFailure = error.localizedDescription
            log?.write("ACCOUNT sync sign-in failed: \(error.localizedDescription)")
        }
    }

    /// Why this Mac isn't syncing although the account is signed in (offline, rate limited); nil when it is.
    private(set) var connectFailure: String?

    /// After a sign-in in the sheet: connect, and close the sheet.
    func didSignIn() async {
        isSignInPresented = false
        await connect()
        model?.show(.init(text: "Signed in as \(account.user?.displayName ?? "you")", symbol: "checkmark.circle.fill"))
    }

    // MARK: Approving this Mac later

    /// UserDefaults: the listener chose Do This Later on the first run's Approve this device, so a quiet banner
    /// stays until this Mac has the key (or the account signs out).
    static let approvalDeferredKey = "firstRunApprovalDeferred"
    /// The banner's close button hid it for this launch.
    @ObservationIgnored private var approvalBannerClosed = false

    var approvalDeferred: Bool {
        get { UserDefaults.standard.bool(forKey: Self.approvalDeferredKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.approvalDeferredKey)
            refreshApprovalBanner()
        }
    }

    /// Whether this Mac is signed in but still waits for another device to approve it.
    var needsApproval: Bool {
        guard account.isSignedIn, service.isRegistered else { return false }
        return FirstRun.afterSignIn(keyStatus: service.keyStatus) == .approve
    }

    private func trackApproval() {
        withObservationTracking {
            _ = service.keyStatus
            _ = account.state
            _ = service.isRegistered
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshApprovalBanner()
                self?.trackApproval()
            }
        }
        refreshApprovalBanner()
    }

    /// The quiet "Approve this Mac" banner, shown only while nothing else uses the slot (a Continue banner wins).
    func refreshApprovalBanner() {
        guard let model else { return }
        let id = "approve.key"
        // Only a settled answer ends it: signed out (not still loading the saved sign-in at launch), or approved.
        let signedOut = account.state == .signedOut
        if approvalDeferred, signedOut || service.keyStatus == .available {
            UserDefaults.standard.set(false, forKey: Self.approvalDeferredKey)
        }
        let show = approvalBannerWins
        // Over a Continue banner too: without the key this Mac can't take that playback anyway.
        if show, model.playerBanner == nil || model.playerBanner?.id.hasPrefix("sync.") == true {
            let holders = service.keyHolders
            model.playerBanner = PlayerBanner(
                id: id, symbol: "lock.shield",
                title: "Approve this Mac to sync your sign-ins",
                subtitle: "Open \(ProductInfo.name) on \(FirstRun.deviceNoun(Set(holders.map(\.platform)).count == 1 ? holders.first?.platform : nil))",
                actionTitle: "Approve…",
                action: { [weak model] in
                    model?.requestSettings(.sync)
                    model?.openSettingsAction?()
                },
                onDismiss: { [weak self] in self?.approvalBannerClosed = true })
            log?.write("BANNER approve this Mac")
        } else if !show, model.playerBanner?.id == id {
            model.playerBanner = nil
            log?.write("BANNER approval hidden")
            // Approved (or signed out): a Continue banner the approval one stood in for comes back.
            refreshBanner()
        }
    }

    /// After Do This Later, until this Mac is approved: the approval banner holds the player's banner slot.
    var approvalBannerWins: Bool {
        approvalDeferred && needsApproval && !approvalBannerClosed && model?.firstRun == nil
    }

    /// Settings › Account › Sign Out: removes this Mac from the account's devices, then ends the Clerk session.
    /// The Mac's own YouTube Music and Spotify sign-ins stay.
    func signOutOfAccount() async {
        // Sync first (it needs the session to remove the device), then the Clerk session this sign-out started for:
        // a sign-in that finished meanwhile keeps its session (`AccountService.signOut(sync:)`).
        await account.signOut(sync: service)
        dismissedKeyRequests.removeAll()
        log?.write("ACCOUNT signed out; connection \(service.connection.state)")
    }

    /// Another device removed this Mac: sign out of the account here too.
    private func removedElsewhere() {
        log?.write("ACCOUNT this Mac was removed from the account's devices")
        // The sign-in this removal happened under: a sign-in after it (the same user again included) is left alone.
        let signIn = service.currentSignIn
        Task {
            let session = await account.currentSession()
            if account.isCurrent(session), signIn == nil || session.signIn == signIn { await account.signOut(ifStill: session) }
            await service.signOut(ifSignIn: signIn)
            model?.show(.init(text: "This Mac was removed from your devices", symbol: "person.crop.circle.badge.minus"))
        }
    }

    /// Clerk ended the session (signed out elsewhere, revoked): stop syncing here.
    private func sessionEnded() {
        log?.write("ACCOUNT the Clerk session ended")
        // Only sync's sign-in for the user whose session ended; a newer one is left alone.
        let signIn = account.endedSignIn
        Task {
            await service.signOut(ifSignIn: signIn)
            model?.show(.init(text: "You were signed out of \(ProductInfo.name)", symbol: "person.crop.circle.badge.minus"))
        }
    }

    /// Switches to another server (nil: Medley's). Signs out of the current one first; sync starts over against the
    /// new server.
    func switchServer(to url: URL?) async {
        await signOutOfAccount()
        await account.setServer(url)
        model?.restartSync()
    }

    // MARK: Sign-in key

    /// "Allow" in the key request alert: wraps the sign-in key to that device.
    func allowKey(_ request: SyncService.KeyRequest) async {
        do {
            try await service.allowKey(for: request)
            log?.write("KEY allowed \(request.device.name) (code \(request.code))")
            model?.show(.init(text: "\(request.device.name) can now use your sign-ins", symbol: "key.fill"))
        } catch {
            dismissedKeyRequests.dismiss(request)
            model?.report(error)
        }
    }

    func denyKey(_ request: SyncService.KeyRequest) async {
        dismissedKeyRequests.dismiss(request)
        do { try await service.denyKey(for: request) } catch { model?.report(error) }
        log?.write("KEY denied \(request.device.name)")
    }

    /// The coordinator sets the player's volume for a remote "volume" command; on the Mac the volume lives in
    /// `PlaybackSettings` (the slider, and what is restored at launch), so it goes there too.
    private func routeRemoteVolume() {
        guard let inner = service.commandHandler, let settings = model?.playback.settings else { return }
        service.commandHandler = { command in
            if case .setVolume(let volume) = command.command { settings.volume = Float(max(0, min(1, volume))) }
            return await inner(command)
        }
    }

    // MARK: Foreground, sleep and network

    /// Heartbeats (and the HTTP fallback poll) run while Medley is in use or playing. On a Mac "in use" is the app
    /// being active or its window being on screen, unhidden, with the display awake: a Mac sitting on the desk with
    /// Medley open stays online for "send to Mac", while a hidden or sleeping one goes quiet. Playing keeps it awake
    /// regardless (`SyncCoordinator` calls `setPlaying`).
    private func observeLifecycle() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        let app: [Notification.Name] = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                                        NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                                        NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                                        NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification]
        for name in app {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateForeground(reason: nil) }
            })
        }
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.asleep = true
                self?.updateForeground(reason: "sleep")
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.asleep = true
                self?.updateForeground(reason: "display sleep")
            }
        })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.asleep = false
                    // Reconnect at once instead of waiting out a backoff the sleep left behind.
                    self?.updateForeground(reason: "wake", force: true)
                    // The socket may have died during sleep without a close; don't wait for the inactivity timeout.
                    self?.service.reconnectNow(force: true)
                }
            })
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let interfaces = path.availableInterfaces.map(\.name)
            Task { @MainActor [weak self] in self?.networkChanged(satisfied: satisfied, interfaces: interfaces) }
        }
        monitor.start(queue: DispatchQueue(label: "\(ProductInfo.identifierPrefix).sync.network"))
        pathMonitor = monitor
        updateForeground(reason: "launch")
    }

    /// Back online, or moved to another network (Wi-Fi to Ethernet, a VPN coming up): reconnect now rather than after
    /// the backoff, and replace a socket that still counts as connected. After a move it is bound to the old
    /// interface and can sit silent until the inactivity timeout, so the forced reconnect opens a fresh one, as on wake.
    func networkChanged(satisfied: Bool, interfaces: [String]) {
        let last = lastPath
        lastPath = (satisfied, interfaces)
        guard let last else { return }
        guard satisfied else {
            if last.satisfied { log?.write("NETWORK lost") }
            return
        }
        // Any update while online can mean a new network on the same interface (one Wi-Fi to another over en0), so
        // every one replaces the socket, at most once every 5 s so a burst of path updates costs one reconnect.
        let now = ContinuousClock.now
        if last.satisfied, let previous = lastNetworkReconnect, now - previous < .seconds(5) { return }
        lastNetworkReconnect = now
        log?.write("NETWORK \(last.satisfied ? "changed" : "back") (\(interfaces.joined(separator: ", ")))")
        updateForeground(reason: "network change", force: true)
        service.reconnectNow(force: true)
        // The server's sign-in configuration, if it couldn't be loaded while offline.
        Task { await account.retry() }
    }

    /// Whether Medley counts as in use (see `observeLifecycle`).
    var isInUse: Bool {
        guard !asleep else { return false }
        if NSApp.isActive { return true }
        guard !NSApp.isHidden, let window = model?.mainWindow else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    private func updateForeground(reason: String?, force: Bool = false) {
        let inUse = isInUse
        guard force || inUse != lastForeground else { return }
        lastForeground = inUse
        service.setForeground(inUse)
        if inUse {
            refreshBanner()
            if !account.isReady { Task { await account.retry() } }
            // Imports that failed while offline get another try.
            if service.isRegistered { service.signIns.reconcileAll() } else if account.isSignedIn { Task { await connect() } }
        }
        log?.write("FOREGROUND \(inUse)\(reason.map { " (\($0))" } ?? "")")
    }

    // MARK: Sign-ins

    /// An import that failed (offline, or the service didn't answer) stays pending; SignInSync tries it again on
    /// the next reconcile after its retry delay. This makes sure a reconcile comes: every 35 s while one is failing.
    private func trackImportFailures() {
        let failing = withObservationTracking {
            service.signIns.status.values.contains { if case .failed = $0 { true } else { false } }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.trackImportFailures() }
        }
        guard failing else { importRetry?.cancel(); importRetry = nil; return }
        guard importRetry == nil else { return }
        log?.write("SIGN-IN import failing; retrying every \(Int(Self.importRetryInterval.components.seconds)) s")
        importRetry = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.importRetryInterval)
                guard !Task.isCancelled, let self else { return }
                self.log?.write("SIGN-IN retrying failed imports")
                self.service.signIns.reconcileAll()
            }
        }
    }

    static let importRetryInterval: Duration = .seconds(35)

    /// The library's current sign-in for `provider`, opened with the library key. nil without one.
    private func openVaultEntry(_ provider: ProviderID) -> Data? {
        guard let key = service.libraryKey,
              let entry = service.vaultEntries?.first(where: { $0.provider == provider }),
              let sealed = entry.sealed, entry.keyId == key.id else { return nil }
        return try? SignInSealing.open(sealed, provider: provider, revision: entry.revision, key: key)
    }

    private func signInArrived(_ i: SignInSync.Import) {
        guard let model else { return }
        let from = deviceName(writerOf: i.provider)
        log?.write("SIGN-IN \(i.provider.rawValue) \(i.signedOut ? "signed out everywhere" : "imported") from \(from ?? "?"), \(Int(i.latencyMs)) ms after it was written; provider \(model.provider(i.provider)?.authStatus.logText ?? "-")")
        Task { await model.refreshLibraryState() }
        if i.signedOut {
            model.show(.init(text: "Signed out of \(i.provider.displayName) on all devices", symbol: "person.crop.circle.badge.minus"))
        } else if model.provider(i.provider)?.isSignedIn == true {
            model.show(.init(text: "Signed in to \(i.provider.displayName)\(from.map { " from \($0)" } ?? "")", symbol: "person.crop.circle.badge.checkmark"))
        }
    }

    func deviceName(writerOf provider: ProviderID) -> String? {
        service.vaultEntries?.first { $0.provider == provider }.flatMap { entry in
            service.devices.first { $0.id == entry.updatedBy }?.name
        }
    }

    /// Whether signing out should ask "this Mac or all devices".
    var offersSignOutEverywhere: Bool { service.isRegistered && service.keyStatus == .available }

    /// Settings › Accounts' Sign Out. On a paired Mac it always goes through sign-in sync, with or without the
    /// library key, so "this Mac only" sticks: later vault updates for that service are ignored until the listener
    /// signs in here again. Returns the error to show when the saved sign-in couldn't be removed.
    func signOutTapped(_ id: ProviderID) async -> String? {
        if offersSignOutEverywhere {
            signOutPrompt = id
            return nil
        }
        return await signOut(id, everywhere: false)
    }

    /// Signs `id` out here, and with `everywhere` on every device. Returns the message the Accounts pane shows when
    /// that didn't fully happen.
    ///
    /// Paired, sign-in sync does it all (`SignInSync.signOut`): it deletes the local sign-in first and, if the Keychain
    /// refuses, throws with nothing recorded and no sign-out written for the other devices, so they are never signed
    /// out while this Mac would sign back in at the next launch. Otherwise it records "signed out here" or writes the
    /// sign-out for every device. Unpaired, only the local deletion runs.
    @discardableResult
    func signOut(_ id: ProviderID, everywhere: Bool) async -> String? {
        guard let model, let provider = model.provider(id) else { return nil }
        var message: String?
        do {
            if service.isRegistered, transfer(for: id) != nil {
                try await service.signIns.signOut(id, everywhere: everywhere)
            } else {
                try await provider.trySignOut()
            }
        } catch {
            message = provider.isSignedIn
                ? "Couldn't sign out of \(id.displayName) on this Mac, so nothing changed on your other devices. \(error.localizedDescription)"
                : "Signed out on this Mac, but not on your other devices. \(error.localizedDescription)"
        }
        log?.write("SIGN-OUT \(id.rawValue) \(everywhere ? "everywhere" : "here") \(message == nil ? "done" : "failed"); provider \(provider.authStatus.logText); sync \(String(describing: service.signIns.status[id]))\(message.map { "; \($0)" } ?? "")")
        await model.refreshLibraryState()
        return message
    }

    func transfer(for provider: ProviderID) -> (any SignInTransfer)? { transfers.first { $0.provider == provider } }

    // MARK: Devices

    func setDeviceName(_ raw: String) {
        let name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        guard !name.isEmpty, name != service.deviceInfo.name || service.selfDevice?.name != name else { return }
        UserDefaults.standard.set(name, forKey: Self.deviceNameKey)
        service.deviceInfo.name = name
        guard let me = service.selfID, service.selfDevice?.name != name else { return }
        Task {
            do { try await service.rename(me, to: name) } catch { model?.report(error) }
        }
    }

    /// `medley://test` links (debug self-test runs only). True when it took the link. Social sign-in callbacks
    /// (`medley://oauth-callback`) go to the web authentication session, not here.
    func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == ProductInfo.urlScheme else { return false }
        #if DEBUG
        if url.host == "test" { return log != nil && SyncSelfTest.run(url, hub: self) }
        #endif
        return false
    }

    // MARK: Handoff

    func name(of device: DeviceID) -> String {
        service.devices.first { $0.id == device }?.name ?? "the other device"
    }

    /// "Play Here" from the banner, the menu or the popover. Errors show as a notice and in the popover.
    func playHere(from device: DeviceID) {
        Task {
            if let message = await pull(from: device) {
                self.message = message
                model?.show(.init(text: message, symbol: "exclamationmark.triangle.fill"))
            }
        }
    }

    /// Pulls `device`'s playback here. Returns the error message to show, if any.
    func pull(from device: DeviceID) async -> String? {
        let name = name(of: device)
        if let message = playabilityProblem(of: device) {
            log?.write("PULL refused: \(message)")
            return message
        }
        message = nil
        // A playback choice: a collection or Liked Songs still loading to play gives up.
        model?.beginPlayRequest()
        log?.write("TAP play here from \(name); source live at \(fmt(coordinator.livePosition(of: device)))")
        do {
            try await coordinator.playHere(from: device)
            if let r = coordinator.lastHandoff, let player = model?.player {
                log?.write("PULL done: queue \(Int(r.fetchMs)) ms, cued \(Int(r.readyMs)) ms, playing \(Int(r.totalMs)) ms; \"\(player.current?.title ?? "-")\" local \(fmt(player.currentTime)) vs source \(fmt(coordinator.livePosition(of: device))), delta \(Int(r.positionDeltaMs ?? 0)) ms")
            }
            return nil
        } catch {
            log?.write("PULL failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    /// A message when `device`'s track can't play on this Mac (its service isn't signed in here), checked before
    /// asking the coordinator so the listener reads why at once.
    func playabilityProblem(of device: DeviceID) -> String? {
        guard let row = service.playback[device] else { return SyncError.nothingPlaying(name(of: device)).localizedDescription }
        guard service.canSealContent else { return SyncError.needsKey(device: nil).localizedDescription }
        guard let track = row.track else {
            return "What plays on \(name(of: device)) is sealed with a key this Mac doesn't have yet. Try again in a moment."
        }
        let provider = track.provider
        guard coordinator.canPlay(provider) else {
            return "\(provider.displayName) isn't signed in on this Mac. Sign in under Settings › Accounts\(service.keyStatus == .available ? ", or on \(name(of: device)) to sync it here" : "")."
        }
        return nil
    }

    /// Sends this Mac's playback to `device`. Returns the error message to show, if any.
    func send(to device: DeviceID) async -> String? {
        let name = name(of: device)
        if let target = service.devices.first(where: { $0.id == device }), !service.isOnline(target) {
            return SyncError.deviceOffline(name).localizedDescription
        }
        message = nil
        log?.write("TAP send to \(name)")
        do {
            try await coordinator.send(to: device)
            if let r = coordinator.lastHandoff {
                log?.write("PUSH done: sent \(Int(r.fetchMs)) ms, \(name) acked playing \(Int(r.readyMs)) ms, paused here \(Int(r.totalMs)) ms; local \(model?.player.state.rawValue ?? "-")")
            }
            selectedDevice = device
            return nil
        } catch {
            log?.write("PUSH failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    /// Runs one remote command and waits for its ack. Returns the error message to show, if any.
    func remote(_ device: DeviceID, _ label: String, _ action: @escaping @MainActor (RemoteControl) async throws -> CommandID) async -> String? {
        if let target = service.devices.first(where: { $0.id == device }), !service.isOnline(target) {
            return SyncError.deviceOffline(target.name).localizedDescription
        }
        let started = Date()
        do {
            let id = try await action(coordinator.remote(device))
            let result = try await service.waitForAck(id, timeout: .seconds(15))
            log?.write("REMOTE \(label) acked ok=\(result.ok) \(Int(Date().timeIntervalSince(started) * 1000)) ms after the tap\(result.message.map { " (\($0))" } ?? "")")
            return result.ok ? nil : result.message
        } catch {
            log?.write("REMOTE \(label) failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    // MARK: Banner

    /// Keeps `banner` and `model.playerBanner` in step with the coordinator's suggestion. The suggestion also
    /// expires with time (30 minutes after a pause, 90 s after a playing device goes quiet), so a timer rechecks then.
    private func trackBanner() {
        withObservationTracking {
            _ = coordinator.continueSuggestion
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshBanner()
                self?.trackBanner()
            }
        }
        refreshBanner()
    }

    func refreshBanner() {
        let suggestion = coordinator.continueSuggestion
        bannerTimer?.cancel()
        bannerTimer = nil
        if let suggestion {
            let expiry = suggestion.isPlaying
                ? suggestion.device.lastSeenAt + SyncLimits.onlineWindow * 1000
                : suggestion.playback.updatedAt + SyncLimits.continueWindow * 1000
            let wait = max(1, (expiry - service.clock.now()) / 1000 + 0.5)
            bannerTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                self?.refreshBanner()
            }
        }
        let changed = suggestion?.device.id != banner?.device.id || suggestion?.playback.track?.id != banner?.playback.track?.id
            || suggestion?.isPlaying != banner?.isPlaying
        banner = suggestion
        if approvalBannerWins {
            refreshApprovalBanner()
            return
        }
        guard changed || (suggestion != nil && model?.playerBanner == nil) || (suggestion == nil && model?.playerBanner?.id.hasPrefix("sync.") == true) else { return }
        if let suggestion {
            if changed {
                log?.write("BANNER Continue from \(suggestion.device.name): \"\(suggestion.playback.track?.title ?? "(sealed)")\" \(suggestion.isPlaying ? "playing" : "paused") at \(fmt(coordinator.livePosition(of: suggestion.device.id)))")
            }
            model?.playerBanner = makeBanner(suggestion)
        } else {
            if changed { log?.write("BANNER hidden") }
            if model?.playerBanner?.id.hasPrefix("sync.") == true { model?.playerBanner = nil }
            refreshApprovalBanner()
        }
    }

    private func makeBanner(_ suggestion: SyncCoordinator.ContinueSuggestion) -> PlayerBanner {
        let device = suggestion.device
        // Without the key this Mac sees where the other device is, not what it plays: "Playing on Riley's iPhone · 2:13".
        let track = suggestion.playback.track
        return PlayerBanner(
            id: "sync.\(device.id.rawValue).\(track?.id ?? "sealed").\(suggestion.isPlaying)",
            symbol: DeviceGlyph.symbol(device),
            title: "Continue from \(device.name)",
            subtitle: track?.title ?? "\(suggestion.isPlaying ? "Playing" : "Paused") on \(device.name)",
            actionTitle: "Play Here",
            action: { [weak self] in self?.playHere(from: device.id) },
            onDismiss: { [weak self] in self?.dismissBanner() },
            artwork: track?.artwork,
            liveDetail: { [weak self] in
                guard let self else { return "" }
                let position = self.coordinator.livePosition(of: device.id).map(\.clock)
                return [track?.artistLine, position].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
            },
            isBusy: { [weak self] in self?.busyDevice == device.id },
            ticks: suggestion.isPlaying
        )
    }

    /// The close button: hides the offer until that device plays something else.
    func dismissBanner() {
        coordinator.dismissSuggestion()
        log?.write("BANNER dismissed")
        refreshBanner()
    }

    /// The menu's "Continue from …" item.
    var continueMenuTitle: String? {
        banner.map { "Continue from \($0.device.name)" }
    }
}

enum DeviceGlyph {
    static func symbol(_ device: SyncDevice) -> String {
        switch device.platform {
        case .ios: "iphone"
        case .mac: "laptopcomputer"
        case .android: "candybarphone"
        // Windows, Linux and platforms this build doesn't know yet: a generic computer.
        case .windows, .linux, .unknown: "desktopcomputer"
        }
    }
}

func fmt(_ seconds: TimeInterval?) -> String {
    guard let seconds, seconds.isFinite else { return "-" }
    return String(format: "%.2fs", seconds)
}

extension AuthStatus {
    var logText: String {
        switch self {
        case .signedOut: "signed out"
        case .signingIn: "signing in"
        case .signedIn(let info): "signed in as \(info.name)"
        case .failed(let message): "failed (\(message))"
        }
    }
}

/// Where `medley://` links arrive (`AppDelegate.application(_:open:)`). Links that come before sync starts wait.
@MainActor
final class URLRouter {
    static let shared = URLRouter()
    private var pending: [URL] = []
    var handler: ((URL) -> Bool)? {
        didSet {
            guard let handler else { return }
            let waiting = pending
            pending = []
            for url in waiting { _ = handler(url) }
        }
    }

    func open(_ url: URL) {
        if let handler { _ = handler(url) } else { pending.append(url) }
    }
}

/// Takes `medley://` links from Launch Services (the Info.plist registers the scheme).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == ProductInfo.urlScheme { URLRouter.shared.open(url) }
    }
}
