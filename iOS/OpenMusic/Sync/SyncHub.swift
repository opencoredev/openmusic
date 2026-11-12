import OpenMusicCore
import OpenMusicSync
import Observation
import SpotifyKit
import SwiftUI
import YouTubeMusicKit

// The provider kits ship transfers with `SignInTransfer`'s exact shape; the conformance lives in the app.
extension YouTubeMusicSignInTransfer: @retroactive SignInTransfer {}
extension SpotifySignInTransfer: @retroactive SignInTransfer {}

/// OpenMusic Sync on the iPhone: the `SyncService` session, the `SyncCoordinator` attached to the one player, the
/// sign-in transfers, settings and recent searches. Created once in `AppModel.launch()` (not in sample-data runs).
///
/// It owns the OpenMusic account (`AccountService`: Clerk sign-in against the chosen server) and fills the app's
/// extension slots: the welcome screen, the "Continue from <device>" banner above the mini player, the Devices
/// button in Now Playing and the "Allow <device>…?" question. See docs/accounts-design.md.
@MainActor
@Observable
final class SyncHub {
    let account: AccountService
    let service: SyncService
    let coordinator: SyncCoordinator
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var transfers: [any SignInTransfer] = []

    /// The Devices sheet (Now Playing's Devices button).
    var isDevicesPresented = false
    /// The Sign In sheet (Settings › Account, the Devices sheet).
    var isSignInPresented = false
    /// The provider whose "this iPhone or all devices" sign-out question is up.
    var signOutPrompt: ProviderID?
    /// Key requests the listener closed without answering, so they don't come straight back (a new request from the
    /// same device does).
    var dismissedKeyRequests = DismissedKeyRequests()
    /// Why this iPhone isn't syncing although the account is signed in (offline, rate limited); nil when it is.
    private(set) var connectFailure: String?
    /// What the banner shows (kept in step with `coordinator.continueSuggestion`, which is computed).
    private(set) var banner: SyncCoordinator.ContinueSuggestion?
    /// The device whose handoff is running, for spinners.
    var busyDevice: DeviceID? {
        switch coordinator.phase {
        case .idle: nil
        case .pulling(let id), .pushing(let id): id
        }
    }

    @ObservationIgnored private var bannerTimer: Task<Void, Never>?
    @ObservationIgnored private var importRetry: Task<Void, Never>?

    /// The sync self-test's log (Debug builds with `-OpenMusicSyncSelfTest YES`); always nil in Release.
    @ObservationIgnored var log: SyncTestLog?

    /// The device asking for this iPhone's sign-in key that the "Allow …?" alert shows, if any.
    var pendingKeyRequest: SyncService.KeyRequest? {
        dismissedKeyRequests.firstShown(in: service.keyRequests)
    }

    /// The name this iPhone shows to the others. Set during onboarding or in Settings; a launch argument
    /// (`-OpenMusicSyncDeviceName "…"`) overrides it. Saved under its key from before the rename, which must stay so a
    /// name set by an earlier build is kept (`-MedleySyncDeviceName` reaches it through the argument domain too).
    static let deviceNameKey = "MedleySyncDeviceName"

    init(model: AppModel, store: any SyncCredentialStore = KeychainCredentialStore()) {
        self.model = model
        var info = DeviceInfo.current()
        if let name = (LaunchEnvironment.argument("SyncDeviceName") ?? UserDefaults.standard.string(forKey: Self.deviceNameKey))?
            .trimmingCharacters(in: .whitespaces), !name.isEmpty {
            info.name = String(name.prefix(64))
        } else if info.name.hasPrefix("agent-") {
            // The simulator reports its own name. iOS reports "iPhone" for real devices without the entitlement.
            info.name = "iPhone"
        }
        // The hosted deployment: `OpenMusicSyncURL` from Info.plist (per configuration in iOS/project.yml); without it, dev in
        // Debug and production in Release. A custom server overrides it.
        account = AccountService(hostedURL: SyncService.deploymentURL(), store: CredentialClerkStateStore(store: store))
        service = SyncService(deploymentURL: account.server.url, deviceInfo: info, credentials: store)
        coordinator = SyncCoordinator(service: service, player: model.player)
        // YouTube Music plays without an account; Spotify needs one.
        coordinator.canPlay = { [weak model] id in
            guard let provider = model?.provider(id) else { return false }
            return id == .youtubeMusic || provider.isSignedIn
        }
    }

    // MARK: Start

    /// Call once, after the providers restored their sessions. The sync socket opens only once the account is
    /// signed in.
    #if DEBUG
    /// The self-test also accepts the probe's fake test sign-ins (and checks real ones for real). Debug builds only.
    private func testVerifier(_ youtube: YouTubeMusicProvider) -> YouTubeMusicSignInTransfer.Verifier? {
        model?.options.syncSelfTest == true ? YouTubeMusicSignInTransfer.acceptingTestSignIns() : nil
    }
    private func testVerifier(_ spotify: SpotifyProvider) -> SpotifySignInTransfer.Verifier? {
        model?.options.syncSelfTest == true ? SpotifySignInTransfer.acceptingTestSignIns(provider: spotify) : nil
    }
    #else
    private func testVerifier(_ youtube: YouTubeMusicProvider) -> YouTubeMusicSignInTransfer.Verifier? { nil }
    private func testVerifier(_ spotify: SpotifyProvider) -> SpotifySignInTransfer.Verifier? { nil }
    #endif

    func start() {
        guard let model else { return }
        coordinator.attach()
        service.onRemoved = { [weak self] in self?.removedElsewhere() }
        account.onSessionEnded = { [weak self] in self?.sessionEnded() }
        Task { await startAccount() }

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

        model.extensions.nowPlayingAccessory = AnyView(DevicesButton())
        model.extensions.urlHandlers.insert({ [weak self] url in self?.handle(url) ?? false }, at: 0)
        trackBanner()
        trackApproval()
    }

    // MARK: Approving this iPhone later

    /// UserDefaults: the listener chose Do This Later on the first run's Approve this device, so a quiet banner
    /// stays above the mini player until this iPhone has the key (or the account signs out).
    static let approvalDeferredKey = "firstRunApprovalDeferred"
    /// The banner's close button hid it for this launch.
    @ObservationIgnored private var approvalBannerClosed = false
    /// The banner slot holds the approval banner (not the Continue banner, which wins).
    @ObservationIgnored private var showsApprovalBanner = false

    var approvalDeferred: Bool {
        get { UserDefaults.standard.bool(forKey: Self.approvalDeferredKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.approvalDeferredKey)
            refreshApprovalBanner()
        }
    }

    /// Whether this iPhone is signed in but still waits for another device to approve it.
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

    func closeApprovalBanner() {
        approvalBannerClosed = true
        refreshApprovalBanner()
    }

    func refreshApprovalBanner() {
        guard let model else { return }
        // Only a settled answer ends it: signed out (not still loading the saved sign-in at launch), or approved.
        let signedOut = account.state == .signedOut
        if approvalDeferred, signedOut || service.keyStatus == .available {
            UserDefaults.standard.set(false, forKey: Self.approvalDeferredKey)
        }
        let show = approvalBannerWins
        guard show != showsApprovalBanner else { return }
        showsApprovalBanner = show
        log?.write(show ? "BANNER approve this iPhone" : "BANNER approval hidden")
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            // Over a Continue banner too: without the key this iPhone can't take that playback anyway. Once
            // approved, the Continue banner it stood in for comes back.
            model.extensions.miniPlayerBanner = show ? AnyView(ApprovalBanner()) : banner == nil ? nil : AnyView(ContinueBanner())
        }
    }

    /// After Do This Later, until this iPhone is approved: the approval banner holds the slot above the mini player.
    var approvalBannerWins: Bool {
        approvalDeferred && needsApproval && !approvalBannerClosed && model?.firstRun == nil
    }

    /// The sign-in transfer for `provider` (the self-test's fake sign-ins go through it).
    func transfer(for provider: ProviderID) -> (any SignInTransfer)? { transfers.first { $0.provider == provider } }

    func setForeground(_ active: Bool) {
        service.setForeground(active)
        if active {
            refreshBanner()
            if !account.isReady { Task { await account.retry() } }
            // Imports that failed while offline get another try; a sign-in that couldn't register tries again.
            if service.isRegistered { service.signIns.reconcileAll() } else if account.isSignedIn { Task { await connect() } }
        }
    }

    #if DEBUG
    /// Snapshot runs: a hub that never connects, keeps nothing in the Keychain and shows made-up devices.
    static func preview(model: AppModel) -> SyncHub { SyncHub(model: model, store: MemoryCredentialStore()) }
    #endif

    // MARK: Account

    /// Reads the saved sign-in and the server's configuration, then connects when signed in. Someone who isn't signed
    /// in meets the account in the first-run flow's Sync step (`FirstRunFlow`).
    private func startAccount() async {
        #if DEBUG
        if let file = model?.options.syncJWTFile {
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
        if account.isSignedIn { await connect() }
    }

    /// Signs this iPhone in to sync as the signed-in account.
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

    /// After a sign-in in the sheet.
    func didSignIn() async {
        isSignInPresented = false
        await connect()
        model?.show(.init(text: "Signed in as \(account.user?.displayName ?? "you")", symbol: "checkmark.circle.fill"))
    }

    /// Settings › Account › Sign Out: removes this iPhone from the account's devices, then ends the Clerk session.
    func signOutOfAccount() async {
        // Sync first (it needs the session to remove the device), then the Clerk session this sign-out started for:
        // a sign-in that finished meanwhile keeps its session (`AccountService.signOut(sync:)`).
        await account.signOut(sync: service)
        dismissedKeyRequests.removeAll()
        log?.write("ACCOUNT signed out")
    }

    private func removedElsewhere() {
        log?.write("ACCOUNT this iPhone was removed from the account's devices")
        // The sign-in this removal happened under: a sign-in after it (the same user again included) is left alone.
        let signIn = service.currentSignIn
        Task {
            let session = await account.currentSession()
            if account.isCurrent(session), signIn == nil || session.signIn == signIn { await account.signOut(ifStill: session) }
            await service.signOut(ifSignIn: signIn)
            model?.show(.init(text: "This iPhone was removed from your devices", symbol: "person.crop.circle.badge.minus"))
        }
    }

    private func sessionEnded() {
        log?.write("ACCOUNT the Clerk session ended")
        // Only sync's sign-in for the user whose session ended; a newer one is left alone.
        let signIn = account.endedSignIn
        Task {
            await service.signOut(ifSignIn: signIn)
            model?.show(.init(text: "You were signed out of \(ProductInfo.name)", symbol: "person.crop.circle.badge.minus"))
        }
    }

    /// Switches to another server (nil: OpenMusic's). Signs out first; sync starts over against the new server.
    func switchServer(to url: URL?) async {
        await signOutOfAccount()
        await account.setServer(url)
        model?.restartSync()
    }

    /// Ends this session (switching servers). A new hub takes over.
    func stop() {
        coordinator.detach()
        service.stop()
        bannerTimer?.cancel()
        importRetry?.cancel()
    }

    // MARK: Sign-in key

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

    // MARK: Retrying imports

    /// An import that failed (offline, or the service didn't answer) stays pending; SignInSync tries it again on
    /// the next reconcile after `importRetryDelay`. This makes sure a reconcile comes: every 35 s while one is failing.
    private func trackImportFailures() {
        let failing = withObservationTracking {
            service.signIns.status.values.contains { if case .failed = $0 { true } else { false } }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.trackImportFailures() }
        }
        guard failing else { importRetry?.cancel(); importRetry = nil; return }
        guard importRetry == nil else { return }
        importRetry = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(35))
                guard !Task.isCancelled, let self else { return }
                self.log?.write("SIGN-IN retrying failed imports")
                self.service.signIns.reconcileAll()
            }
        }
    }

    /// The library's current sign-in for `provider`, opened with the library key. nil without one.
    private func openVaultEntry(_ provider: ProviderID) -> Data? {
        guard let key = service.libraryKey,
              let entry = service.vaultEntries?.first(where: { $0.provider == provider }),
              let sealed = entry.sealed, entry.keyId == key.id else { return nil }
        return try? SignInSealing.open(sealed, provider: provider, revision: entry.revision, key: key)
    }

    // MARK: Sign-ins

    private func signInArrived(_ i: SignInSync.Import) {
        guard let model else { return }
        let from = service.vaultEntries?.first { $0.provider == i.provider }.flatMap { entry in
            service.devices.first { $0.id == entry.updatedBy }?.name
        }
        log?.write("SIGN-IN \(i.provider.rawValue) \(i.signedOut ? "signed out everywhere" : "imported") from \(from ?? "?"), \(Int(i.latencyMs)) ms after it was written; provider \(model.provider(i.provider)?.authStatus.logText ?? "-")")
        Task { await model.refreshLibraryState() }
        if i.signedOut {
            model.show(.init(text: "Signed out of \(i.provider.displayName) on all devices", symbol: "person.crop.circle.badge.minus"))
        } else if model.provider(i.provider)?.isSignedIn == true {
            model.show(.init(text: "Signed in to \(i.provider.displayName)\(from.map { " from \($0)" } ?? "")", symbol: "person.crop.circle.badge.checkmark"))
        }
    }

    /// Whether signing out should ask "this iPhone or all devices".
    var offersSignOutEverywhere: Bool { service.isRegistered && service.keyStatus == .available }

    /// Sign Out on a provider page. Paired: through the sign-in sync, so the choice sticks (a sign-in arriving
    /// later, for example once the key code is scanned, doesn't sign this iPhone back in). Asks "this iPhone or
    /// all devices" when sign-ins sync.
    func requestSignOut(_ id: ProviderID) {
        if offersSignOutEverywhere {
            signOutPrompt = id
        } else if service.isRegistered {
            signOut(id, everywhere: false)
        } else {
            model?.signOut(id)
        }
    }

    func signOut(_ id: ProviderID, everywhere: Bool) {
        guard let model else { return }
        Task {
            do {
                try await service.signIns.signOut(id, everywhere: everywhere)
            } catch {
                model.report(error)
            }
            log?.write("SIGNED OUT \(id.rawValue) \(everywhere ? "everywhere" : "here"); status \(String(describing: service.signIns.status[id]))")
            await model.refreshLibraryState()
        }
    }

    // MARK: Devices

    func setDeviceName(_ raw: String) {
        let name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        guard !name.isEmpty else { return }
        UserDefaults.standard.set(name, forKey: Self.deviceNameKey)
        service.deviceInfo.name = name
        guard let me = service.selfID, service.selfDevice?.name != name else { return }
        Task {
            do { try await service.rename(me, to: name) } catch { model?.report(error) }
        }
    }

    /// `openmusic://test` links (Debug self-test runs only). Social sign-in callbacks (`openmusic://oauth-callback`) go
    /// to the web authentication session, not here.
    func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == ProductInfo.urlScheme else { return false }
        #if DEBUG
        if url.host == "test" { return log != nil && SyncSelfTest.run(url, hub: self) }
        #endif
        return false
    }

    // MARK: Handoff

    /// "Play here" from the banner or the Devices sheet. Errors show as a toast.
    func playHere(from device: DeviceID) {
        Task { if let message = await pull(from: device) { model?.show(.init(text: message, symbol: "exclamationmark.triangle.fill")) } }
    }

    /// Pulls `device`'s playback here. Returns the error message to show, if any.
    func pull(from device: DeviceID) async -> String? {
        let name = service.devices.first { $0.id == device }?.name ?? "the other device"
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

    /// Sends this iPhone's playback to `device`. Returns the error message to show, if any.
    func send(to device: DeviceID) async -> String? {
        let name = service.devices.first { $0.id == device }?.name ?? "?"
        log?.write("TAP send to \(name)")
        do {
            try await coordinator.send(to: device)
            if let r = coordinator.lastHandoff {
                log?.write("PUSH done: sent \(Int(r.fetchMs)) ms, \(name) acked playing \(Int(r.readyMs)) ms, paused here \(Int(r.totalMs)) ms; local \(model?.player.state.rawValue ?? "-")")
            }
            return nil
        } catch {
            log?.write("PUSH failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    /// Runs one remote command and waits for its ack. Returns the error message to show, if any.
    func remote(_ device: DeviceID, _ label: String, _ action: @escaping @MainActor (RemoteControl) async throws -> CommandID) async -> String? {
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

    /// Keeps `banner` and the mini-player slot in step with the coordinator's suggestion. The suggestion also
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
        if approvalBannerWins {
            banner = suggestion
            refreshApprovalBanner()
            return
        }
        guard suggestion?.device.id != banner?.device.id || suggestion?.playback.track?.id != banner?.playback.track?.id
                || suggestion?.isPlaying != banner?.isPlaying || (suggestion != nil && model?.extensions.miniPlayerBanner == nil) else {
            banner = suggestion
            return
        }
        if let suggestion {
            log?.write("BANNER Continue from \(suggestion.device.name): \"\(suggestion.playback.track?.title ?? "(sealed)")\" \(suggestion.isPlaying ? "playing" : "paused") at \(fmt(coordinator.livePosition(of: suggestion.device.id)))")
        } else if banner != nil {
            log?.write("BANNER hidden")
        }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            banner = suggestion
            if suggestion != nil { showsApprovalBanner = false }
            model?.extensions.miniPlayerBanner = suggestion == nil ? nil : AnyView(ContinueBanner())
        }
        if suggestion == nil { refreshApprovalBanner() }
    }

    func dismissBanner() {
        coordinator.dismissSuggestion()
        log?.write("BANNER dismissed")
        refreshBanner()
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
