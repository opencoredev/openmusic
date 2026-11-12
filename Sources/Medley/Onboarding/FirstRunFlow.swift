import Foundation
import MedleyCore
import MedleySync
import Observation

/// The first-run flow's state on the Mac (`FirstRunView` draws it): Welcome, Your music, Sync (with Use your own
/// server), Approve this device, then Home. Every step has a way past it; finishing or skipping marks the flow done
/// (`AppModel.finishFirstRun`). The steps and words are the same on every platform (docs/onboarding.md).
///
/// It always reads the current `model.sync`: switching servers replaces the hub mid-flow.
@MainActor
@Observable
final class FirstRunFlow {
    @ObservationIgnored weak var model: AppModel?

    private(set) var step: FirstRun.Step
    /// Whether the last move went forward (the transition's direction).
    private(set) var forward = true
    /// "Use without an account" on YouTube Music: signed-out YouTube Music browses and plays.
    var youTubeWithoutAccount = false

    // Sync
    var email = ""
    var code = "" {
        didSet {
            let digits = FirstRun.codeDigits(code)
            if digits != code { code = digits }
        }
    }
    private(set) var challenge: ClerkEmailChallenge?
    private(set) var codeSentAt: Date?
    private(set) var activity: Activity?
    var syncError: String?
    /// Signed in, but this Mac couldn't start syncing (offline, rate limited). The flow can still go on.
    private(set) var connectProblem: String?

    // Use your own server
    var serverText = ""
    private(set) var serverCheck: ServerCheck = .idle
    /// "Set up an OpenMusic server", the guide's sheet.
    var showsServerGuide = false

    // Approve this device
    private(set) var askingAgain = false

    enum Activity: Equatable {
        case sendingCode, verifying, social(String), settingUp, switchingServer
    }

    enum ServerCheck: Equatable {
        case idle, checking(String), reachable(URL), failed(String)
    }

    init(model: AppModel, step: FirstRun.Step = .welcome) {
        self.model = model
        self.step = step
    }

    private var hub: SyncHub? { model?.sync }
    /// Still the flow on screen (the listener may have skipped while a sign-in ran).
    private var isCurrent: Bool { model?.firstRun === self }

    // MARK: Moving

    func go(to next: FirstRun.Step, forward: Bool = true) {
        self.forward = forward
        step = next
    }

    func back() {
        switch step {
        case .welcome: break
        case .music: go(to: .welcome, forward: false)
        case .sync:
            // From the code back to the email first.
            if challenge != nil { changeEmail() } else { go(to: .music, forward: false) }
        case .server: go(to: .sync, forward: false)
        case .approve: break
        }
    }

    var canGoBack: Bool { step == .music || step == .sync || step == .server }

    func getStarted() { go(to: .music) }

    // MARK: Your music

    func status(_ id: ProviderID) -> AuthStatus {
        #if DEBUG
        if let shown = previewStatus[id] { return shown }
        #endif
        return model?.provider(id)?.authStatus ?? .signedOut
    }

    #if DEBUG
    /// Captures only (`firstrun?preview=…`): a service shown as signed in without a sign-in that would have to work
    /// against the real service. Debug builds only.
    var previewStatus: [ProviderID: AuthStatus] = [:]
    #endif

    var isYouTubeReady: Bool { youTubeWithoutAccount || status(.youtubeMusic).isSignedIn }
    var isSpotifyReady: Bool { status(.spotify).isSignedIn }
    var canContinueFromMusic: Bool { isYouTubeReady || isSpotifyReady }

    /// The service's own sign-in (YouTube's Google sign-in, Spotify's Connect), as a sheet over the window.
    func signIn(_ id: ProviderID) {
        model?.signInRequest = id
    }

    func useYouTubeWithoutAccount() { youTubeWithoutAccount = true }

    func continueFromMusic() {
        guard canContinueFromMusic else { return }
        go(to: .sync)
    }

    // MARK: Sync

    var isSignedIn: Bool { hub?.account.isSignedIn == true }

    /// Apple and Google, in that order, when the server's sign-in has them on. Both, disabled, until it loaded.
    var socialProviders: [ClerkOAuthProvider] {
        guard let account = hub?.account, account.isReady else { return [.apple, .google] }
        return [ClerkOAuthProvider.apple, .google].filter { account.socialProviders.contains($0) }
    }

    var isAccountReady: Bool { hub?.account.isReady == true && hub?.account.serverProblem == nil }

    /// A sign-in is on its way (the code checked, the browser sheet open, this device registering): Not Now waits
    /// for it, so a sign-in can't land after the flow closed and skip Approve this device.
    var isSigningIn: Bool {
        switch activity {
        case .verifying?, .social?, .settingUp?, .switchingServer?: true
        default: false
        }
    }

    var canSendCode: Bool { email.contains("@") && email.contains(".") && activity == nil && isAccountReady }

    /// Seconds until Resend Code works again; 0 when it does.
    func resendWait(now: Date = .now) -> Int {
        guard let codeSentAt else { return 0 }
        let wait = codeSentAt.addingTimeInterval(Double(FirstRun.resendDelay.components.seconds)).timeIntervalSince(now)
        return max(0, Int(wait.rounded(.up)))
    }

    func sendCode() {
        guard let hub, canSendCode || (challenge != nil && resendWait() == 0 && activity == nil) else { return }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        run(.sendingCode) {
            let next = try await hub.account.startEmail(address)
            self.challenge = next
            self.code = ""
            self.codeSentAt = .now
        }
    }

    func changeEmail() {
        challenge = nil
        code = ""
        codeSentAt = nil
        syncError = nil
    }

    /// Runs by itself once six digits are in (typed or pasted).
    func verify() {
        guard let hub, let challenge, code.count == 6, activity == nil else { return }
        let entered = code
        run(.verifying) {
            do {
                _ = try await hub.account.verifyEmail(challenge, code: entered)
            } catch {
                // A wrong or expired code: the field empties for the next try, the message says why and what to do.
                if self.code == entered { self.code = "" }
                self.syncError = FirstRun.codeProblem(error)
                return
            }
            await self.didSignIn()
        }
    }

    /// Continue with Apple / Google: Clerk's web sign-in in a browser sheet, back through `openmusic://oauth-callback`.
    func socialSignIn(_ provider: ClerkOAuthProvider, authenticate: @escaping @MainActor (URL) async throws -> URL?) {
        guard let hub, activity == nil, isAccountReady else { return }
        run(.social(provider.name)) {
            let start = try await hub.account.startOAuth(provider)
            // nil: the listener closed the browser sheet.
            guard let callback = try await authenticate(start.url) else { return }
            _ = try await hub.account.completeOAuth(start, callback: callback)
            await self.didSignIn()
        }
    }

    /// Signed in: register this Mac, then Approve this device when another device holds the key, else Home.
    private func didSignIn() async {
        guard let hub else { return }
        activity = .settingUp
        await hub.connect()
        guard isCurrent else { return }
        if let failure = hub.connectFailure {
            connectProblem = failure
            activity = nil
            return
        }
        await routeAfterSignIn(hub)
    }

    /// Already signed in (a reinstall that kept its sign-in, or a sign-in this flow made): where to go next.
    func continueSignedIn() {
        guard let hub else { finish(); return }
        if connectProblem != nil || !hub.service.isRegistered {
            // Try once more; Settings › Account keeps trying after the flow.
            run(.settingUp) {
                self.connectProblem = nil
                await self.didSignIn()
            }
            return
        }
        Task { await routeAfterSignIn(hub) }
    }

    private func routeAfterSignIn(_ hub: SyncHub) async {
        activity = .settingUp
        // Registration settles the key in a moment: made here on the first device, asked for on the next.
        for _ in 0..<60 {
            if FirstRun.afterSignIn(keyStatus: hub.service.keyStatus) != nil { break }
            try? await Task.sleep(for: .milliseconds(200))
            guard isCurrent else { return }
        }
        activity = nil
        guard isCurrent else { return }
        if FirstRun.afterSignIn(keyStatus: hub.service.keyStatus) == .approve {
            go(to: .approve)
        } else {
            finish()
        }
    }

    // MARK: Use your own server

    func openServer() {
        if let server = hub?.account.server, server.isCustom, serverText.isEmpty { serverText = server.url.absoluteString }
        serverCheck = .idle
        go(to: .server)
    }

    /// The address changed after a check: its result (or the check still running) no longer applies.
    func serverTextDidChange() {
        guard checkedText != serverText.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        serverCheckTask?.cancel()
        serverCheck = .idle
    }

    @ObservationIgnored private var serverCheckTask: Task<Void, Never>?
    @ObservationIgnored private var checkedText: String?

    /// Checks the address in the field. A new check replaces one still running (a server that never answers doesn't
    /// hold the field), and only the newest check's answer shows.
    func checkServer() {
        guard let hub else { return }
        let text = serverText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if case .checking = serverCheck, checkedText == text { return }
        serverCheckTask?.cancel()
        checkedText = text
        serverCheck = .checking(URL(string: text.contains("://") ? text : "https://\(text)")?.host ?? text)
        serverCheckTask = Task {
            let result: ServerCheck
            do {
                result = .reachable(try await hub.account.checkServer(text))
            } catch {
                result = .failed(error.localizedDescription)
            }
            guard !Task.isCancelled, checkedText == text else { return }
            serverCheck = result
        }
    }

    /// Switches to the server that was just checked (nil: OpenMusic's), then back to Sync to sign in there.
    func useServer(_ url: URL?) {
        guard let hub, activity == nil else { return }
        activity = .switchingServer
        Task {
            await hub.switchServer(to: url)
            activity = nil
            changeEmail()
            serverCheck = .idle
            guard isCurrent else { return }
            go(to: .sync, forward: false)
        }
    }

    // MARK: Approve this device

    func codesMatch() { hub?.service.confirmKeyCode() }
    func codesDontMatch() { hub?.service.rejectKeyCode() }

    func askAgain() {
        guard let hub, !askingAgain else { return }
        askingAgain = true
        Task {
            do { try await hub.service.requestKeyAgain() } catch { syncError = error.localizedDescription }
            askingAgain = false
        }
    }

    /// The app keeps working; a quiet banner stays until this Mac is approved.
    func doThisLater() {
        hub?.approvalDeferred = true
        finish()
    }

    /// Signed in, but this device couldn't register with the server: Home anyway. Settings › Account keeps
    /// trying and shows how it goes.
    func continueWithoutSync() {
        guard activity == nil else { return }
        finish()
    }

    /// The key arrived: a moment on the approved state, then Home with a quiet confirmation, no extra click.
    func approved() async {
        try? await Task.sleep(for: .milliseconds(900))
        guard isCurrent, step == .approve else { return }
        finish()
        model?.show(.init(text: "This Mac is approved. Your sign-ins and settings now sync.", symbol: "checkmark.shield.fill"))
    }

    // MARK: Done

    /// Not Now, Do This Later, or the last step: Home. Not while a sign-in is on its way (`isSigningIn`).
    func finish() {
        guard let model, isCurrent, !isSigningIn else { return }
        model.finishFirstRun()
        model.sync?.refreshApprovalBanner()
    }

    private func run(_ kind: Activity, _ work: @escaping @MainActor () async throws -> Void) {
        activity = kind
        syncError = nil
        Task {
            do {
                try await work()
            } catch {
                if isCurrent { syncError = error.localizedDescription }
            }
            if activity == kind { activity = nil }
        }
    }
}

extension AuthStatus {
    var accountName: String? { if case .signedIn(let info) = self { info.name } else { nil } }
}
