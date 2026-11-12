#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Combine
import Foundation
import OpenMusicCore
import SwiftUI
import WebKit

/// Google sign-in for music.youtube.com inside an embedded browser.
///
/// The web view uses its own persistent `WKWebsiteDataStore` (OpenMusic only, separate from Safari) and a
/// Safari user agent so Google serves its normal sign-in page instead of "This browser may not be secure".
/// When the flow lands back on music.youtube.com with session cookies, they're stored in the Keychain.
@MainActor
enum YTMSignInWebView {
    /// Fixed identifier so the Google session survives relaunches (re-sign-in is one click).
    static let dataStoreID = UUID(uuidString: "6D3B1C52-6B0E-4C55-9A57-3F0B8C1E7A11")!

    /// Desktop Safari on every platform: it's the flow that's proven to land on music.youtube.com with session
    /// cookies, and Google's sign-in pages are responsive, so it reads fine on an iPhone too.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"

    static let signInURL: URL = {
        let next = "https://music.youtube.com/"
        var signin = URLComponents(string: "https://www.youtube.com/signin")!
        signin.queryItems = [
            URLQueryItem(name: "action_handle_signin", value: "true"),
            URLQueryItem(name: "app", value: "desktop"),
            URLQueryItem(name: "hl", value: "en"),
            URLQueryItem(name: "next", value: next),
        ]
        // No `passive`: show Google's account chooser / login so the person picks which account (and, for a brand
        // account, which channel) instead of silently reusing a session. `AccountChooser` surfaces "Use another
        // account" when sessions already exist, and goes to a normal login when the web view's store is empty.
        var login = URLComponents(string: "https://accounts.google.com/AccountChooser")!
        login.queryItems = [
            URLQueryItem(name: "service", value: "youtube"),
            URLQueryItem(name: "continue", value: signin.url!.absoluteString),
            URLQueryItem(name: "hl", value: "en"),
        ]
        return login.url!
    }()

    static var dataStore: WKWebsiteDataStore { WKWebsiteDataStore(forIdentifier: dataStoreID) }

    static func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.preferences.isElementFullscreenEnabled = false
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 480, height: 640), configuration: config)
        view.customUserAgent = userAgent
        return view
    }

    /// Session cookies for youtube.com currently in the OpenMusic web data store.
    static func youtubeCookies(in store: WKWebsiteDataStore) async -> YTMCredentials? {
        let cookies = await store.httpCookieStore.allCookies()
        var jar: [String: String] = [:]
        for cookie in cookies where cookie.domain.hasSuffix("youtube.com") {
            jar[cookie.name] = cookie.value
        }
        let creds = YTMCredentials(cookies: jar)
        return creds.isUsable ? creds : nil
    }

    /// Signs the embedded browser out of Google too, so the next sign-in can pick another account.
    static func clearWebsiteData() async {
        #if DEBUG
        // An isolated self-test run (Keychain.isolate) must not sign this Mac's real Google session out of the shared
        // web data store.
        if Keychain.isIsolated { return }
        #endif
        // On iOS 27 and macOS 27, `WKWebsiteDataStore.remove(forIdentifier:)` crashes inside WebKit
        // (`removeDataStoreWithIdentifierImpl`) when no web view in this process has used the store yet, e.g. a
        // sign-out that arrives through sync. Emptying the store is safe everywhere and signs Google out the same.
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}

#if os(macOS)
/// Sign-in sheet. It first offers the YouTube login the person's own browser already has (one click, then
/// macOS asks once to let OpenMusic read it). Signing in with Google inside OpenMusic is the fallback.
struct YTMSignInView: View {
    let provider: YouTubeMusicProvider
    let onFinish: @MainActor () -> Void

    private enum Mode { case scanning, browser, embedded }
    /// Google sign-in is the front door, so the person picks their account (and channel) on Google's own page.
    /// Borrowing a browser's login is a secondary option behind a link.
    @State private var mode: Mode = .embedded
    /// Bumped to reload the Google web view after clearing its session ("Use a different account").
    @State private var webReloadToken = 0
    /// True while committing a chosen channel (browser- or Google-path), to lock the picker and show progress.
    @State private var committing = false
    /// True while the Google session is being cleared and reloaded, so a stale cookie capture from the old page
    /// is ignored.
    @State private var ignoringCapture = false
    @State private var scan: BrowserLoginScan?
    /// The login being copied, while the macOS permission prompt or the account check is up.
    @State private var importing: BrowserLogin?
    /// Set when a browser profile has more than one Google account: the person picks which one.
    @State private var accounts: [BrowserAccount]?
    /// The login those accounts came from (which browser to name, and to go back to).
    @State private var accountsLogin: BrowserLogin?
    @State private var status: String?
    @State private var isWorking = false
    /// The sign-in, owned by the sheet so closing it (Cancel or otherwise) stops it.
    @State private var signInTask: Task<Void, Never>?
    /// Closed with the sheet, so a cookie read still in flight in the web view can't start a sign-in afterwards.
    @State private var gate = YTMSignInGate()
    /// Set only for rendered snapshots: a fixed scan, nothing read from disk.
    private let isPreview: Bool

    init(provider: YouTubeMusicProvider, onFinish: @escaping @MainActor () -> Void) {
        self.provider = provider
        self.onFinish = onFinish
        self.isPreview = false
    }

    /// A still of the browser step for `openmusic-probe ytm render-signin`.
    init(preview scan: BrowserLoginScan, importing: Bool = false, status: String? = nil, accounts: [BrowserAccount]? = nil) {
        self.provider = YouTubeMusicProvider(validateAccount: { _ in throw CancellationError() })
        self.onFinish = {}
        self.isPreview = true
        _mode = State(initialValue: .browser)
        _scan = State(initialValue: scan)
        _importing = State(initialValue: importing ? scan.logins.first : nil)
        _status = State(initialValue: status)
        _accounts = State(initialValue: accounts)
        _accountsLogin = State(initialValue: accounts != nil ? scan.logins.first : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to YouTube Music").font(.headline)
                Spacer()
                if isWorking && mode == .embedded { ProgressView().controlSize(.small) }
                Button("Cancel") {
                    close()
                    onFinish()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            switch mode {
            case .scanning:
                ProgressView().controlSize(.small).frame(width: 460, height: 220)
            case .browser:
                if let scan { browserChoice(scan) }
            case .embedded:
                // After the Google sign-in resolves an account with several channels, pick one here; otherwise
                // show the Google web view.
                if let accounts { accountChoice(accounts, login: accountsLogin) }
                else { embedded }
            }
        }
        // Back from an external browser after signing in there: look again (only in the browser-login path).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard !isPreview, mode == .browser, importing == nil else { return }
            Task { await rescan() }
        }
        // The sheet can also close without Cancel (window closed, provider switched); a sign-in still checking
        // cookies then must not finish. After a successful sign-in this is a no-op.
        .onAppear { gate.open() }
        .onDisappear { close() }
    }

    // MARK: Browser login

    @ViewBuilder
    private func browserChoice(_ scan: BrowserLoginScan) -> some View {
        if let accounts, let login = accountsLogin ?? scan.logins.first {
            accountChoice(accounts, login: login)
        } else {
            browserList(scan)
        }
    }

    /// Pick which account or channel to use. `login` is set when the accounts came from a browser (names that
    /// browser); nil when they came from the in-app Google sign-in.
    private func accountChoice(_ accounts: [BrowserAccount], login: BrowserLogin?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let login {
                header(browser: login.browser,
                       title: "Choose an account",
                       detail: "\(login.browser.name) is signed in to more than one account or channel. Pick the one for \(ProductInfo.name).")
            } else {
                genericHeader(title: "Choose an account",
                              detail: "This Google account has more than one channel. Pick the one for \(ProductInfo.name).")
            }
            Group {
                // A Google account can own dozens of channels: scroll past a handful instead of growing off-screen.
                if accounts.count > 6 {
                    ScrollView { accountRows(accounts).padding(.trailing, 12) }
                        .frame(height: 380)
                } else {
                    accountRows(accounts)
                }
            }
            .padding(.top, 18)
            if importing != nil || committing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Signing you in…").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.top, 14)
            }
            if let status {
                Text(status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            }
            Divider().padding(.top, 20)
            HStack(spacing: 16) {
                if login != nil {
                    Button("Use a different browser") { backToBrowsers() }
                        .buttonStyle(.link)
                        .disabled(importing != nil || committing)
                    Button("Sign in with Google in \(ProductInfo.name) instead") { backToGoogle() }
                        .buttonStyle(.link)
                        .disabled(importing != nil || committing)
                } else {
                    // Came from the Google sign-in: go back to it to pick a different Google account.
                    Button("Use a different account") { backToGoogle() }
                        .buttonStyle(.link)
                        .disabled(importing != nil || committing)
                }
            }
            .padding(.top, 12)
        }
        .padding(24)
        .frame(width: 460, alignment: .leading)
    }

    private func genericHeader(title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Return from the account picker to the browser list (e.g. to pick a different profile).
    private func backToBrowsers() {
        cancelSignIn()
        accounts = nil
        accountsLogin = nil
        status = nil
    }

    /// Go back to the Google web view (clearing its session) to pick a different Google account.
    private func backToGoogle() {
        cancelSignIn()
        accounts = nil
        accountsLogin = nil
        status = nil
        mode = .embedded
        switchGoogleAccount()
    }

    private func accountRows(_ accounts: [BrowserAccount]) -> some View {
        VStack(spacing: 8) {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                accountButton(account, prominent: index == 0)
            }
        }
    }

    private func accountButton(_ account: BrowserAccount, prominent: Bool) -> some View {
        let content = HStack(spacing: 10) {
            AccountChoiceAvatar(url: account.info.avatar)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.info.name).lineLimit(1)
                if let detail = account.info.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        return Group {
            if prominent {
                Button { commit(account) } label: { content }.buttonStyle(.borderedProminent)
            } else {
                Button { commit(account) } label: { content }.buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
        .disabled(importing != nil || committing)
    }

    @ViewBuilder
    private func browserList(_ scan: BrowserLoginScan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let first = scan.logins.first {
                header(browser: first.browser,
                       title: "Use your YouTube login from \(first.browser.name)",
                       detail: "\(first.browser.name) is already signed in to YouTube. \(ProductInfo.name) copies that login to your Keychain, so you don't type anything.")
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(scan.logins.enumerated()), id: \.element.id) { index, login in
                        loginButton(login, prominent: index == 0, showsProfile: needsProfileName(login, in: scan))
                    }
                }
                .padding(.top, 18)
                if let importing {
                    progress(for: importing)
                } else if status == nil {
                    Text(Set(scan.logins.map(\.browser)).count == 1
                         ? "macOS asks for your Mac password so \(ProductInfo.name) can read \(first.browser.name)'s login. Choose Always Allow to skip this next time."
                         : "macOS asks for your Mac password so \(ProductInfo.name) can read the browser's login. Choose Always Allow to skip this next time.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 14)
                }
            } else if let browser = scan.defaultBrowser {
                header(browser: browser,
                       title: "Sign in to YouTube in \(browser.name)",
                       detail: "Open YouTube Music in \(browser.name) and sign in there. When you come back, \(ProductInfo.name) uses that login.")
                Button("Open YouTube Music in \(browser.name)") { BrowserLogins.openYouTubeMusic(in: browser) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 18)
            }
            if let status {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            Divider().padding(.top, 20)
            Button("Sign in with Google in \(ProductInfo.name) instead") {
                cancelSignIn()
                status = nil
                mode = .embedded
            }
            .buttonStyle(.link)
            .padding(.top, 12)
            .disabled(importing != nil || committing)
        }
        .padding(24)
        .frame(width: 460, alignment: .leading)
    }

    private func header(browser: KnownBrowser, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            if let icon = BrowserLogins.icon(for: browser) {
                Image(nsImage: icon).resizable().frame(width: 48, height: 48).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func loginButton(_ login: BrowserLogin, prominent: Bool, showsProfile: Bool) -> some View {
        let label = showsProfile && login.profileName != nil
            ? "Continue with \(login.browser.name) (\(login.profileName!))"
            : "Continue with \(login.browser.name)"
        let content = HStack(spacing: 8) {
            if let icon = BrowserLogins.icon(for: login.browser) {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18).accessibilityHidden(true)
            }
            Text(label)
        }
        .frame(maxWidth: .infinity)
        return Group {
            if prominent {
                Button { start(login) } label: { content }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button { start(login) } label: { content }
                    .buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
        .disabled(importing != nil || committing)
    }

    /// Profile names only matter when one browser has more than one signed-in profile.
    private func needsProfileName(_ login: BrowserLogin, in scan: BrowserLoginScan) -> Bool {
        scan.logins.filter { $0.browser == login.browser }.count > 1
    }

    private func progress(for login: BrowserLogin) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            // While reading the login and listing accounts, authStatus is unchanged; once committing it's .signingIn.
            Text(provider.authStatus == .signingIn ? "Signing you in…" : "Getting your account from \(login.browser.name)…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 14)
    }

    private func rescan() async {
        let found = await Task.detached(priority: .userInitiated) { BrowserLogins.scan() }.value
        guard mode != .embedded else { return }
        scan = found
        if found.logins.isEmpty && found.defaultBrowser == nil {
            // Safari, Firefox or no readable browser: sign in inside OpenMusic, as before.
            mode = .embedded
        } else {
            mode = .browser
        }
    }

    private func start(_ login: BrowserLogin) {
        guard importing == nil else { return }
        importing = login
        status = nil
        signInTask = Task {
            do {
                let found = try await provider.prepareBrowserSignIn(from: login)
                guard !Task.isCancelled else { return }
                if found.authoritative, found.accounts.count == 1, let only = found.accounts.first {
                    // The switcher confirmed exactly one account: sign straight in.
                    try await provider.commitBrowserSignIn(only)
                    guard !Task.isCancelled else { return }
                    signInTask = nil
                    onFinish()
                } else {
                    // Several accounts/channels, or a non-authoritative fallback: let the person choose.
                    accounts = found.accounts
                    accountsLogin = login
                    importing = nil
                }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                signInTask = nil
                importing = nil
                status = error.localizedDescription
                await rescan()
            }
        }
    }

    private func commit(_ account: BrowserAccount) {
        guard importing == nil, !committing else { return }
        committing = true
        status = nil
        signInTask = Task {
            do {
                try await provider.commitBrowserSignIn(account)
                guard !Task.isCancelled else { return }
                signInTask = nil
                onFinish()
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                signInTask = nil
                committing = false
                status = error.localizedDescription
            }
        }
    }

    // MARK: Sign in inside OpenMusic

    private var embedded: some View {
        VStack(spacing: 0) {
            YTMWebViewRepresentable(reloadToken: webReloadToken, gate: gate) { creds in
                // Ignore a capture that lands while the session is being switched/cleared, or after the sheet closed.
                guard !isWorking, !ignoringCapture, !gate.isClosed else { return }
                isWorking = true
                status = nil
                signInTask = Task {
                    do {
                        // The web login authenticated a Google account. List that account's channels and, if there
                        // are several, let the person pick which one; a single account signs straight in.
                        // If the person already picked a channel on YouTube's own "Choose a channel" page, the
                        // session acts as it: sign in as that one rather than asking again.
                        let found = try await provider.prepareAccounts(credentials: creds, sourceName: "YouTube", preferSelected: true)
                        guard !Task.isCancelled else { return }
                        if found.authoritative, found.accounts.count == 1, let only = found.accounts.first {
                            try await provider.commitBrowserSignIn(only)
                            guard !Task.isCancelled else { return }
                            signInTask = nil
                            onFinish()
                        } else {
                            accounts = found.accounts
                            accountsLogin = nil
                            isWorking = false
                        }
                    } catch {
                        guard !Task.isCancelled, !(error is CancellationError) else { return }
                        signInTask = nil
                        status = error.localizedDescription
                        isWorking = false
                    }
                }
            }
            Divider()
            HStack(spacing: 14) {
                Button("Use a different account") { switchGoogleAccount() }
                    .buttonStyle(.link)
                    .disabled(isWorking)
                if let status {
                    Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button("Use a login from your browser") { openBrowserOption() }
                    .buttonStyle(.link)
                    .disabled(isWorking)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 620, idealHeight: 700)
    }

    /// Clears the Google session in the web view and reloads, so the next sign-in starts at the account chooser.
    /// While clearing, captures from the old page are ignored; the reload happens only after the clear completes.
    private func switchGoogleAccount() {
        guard !ignoringCapture else { return }
        cancelSignIn()
        isWorking = false
        status = nil
        ignoringCapture = true
        Task {
            await YTMSignInWebView.clearWebsiteData()
            webReloadToken += 1
            ignoringCapture = false
        }
    }

    /// Switch to the (secondary) browser-login path, scanning for signed-in browsers.
    private func openBrowserOption() {
        cancelSignIn()
        status = nil
        mode = .scanning
        Task { await rescan() }
    }

    /// The sheet is closing: nothing may sign in from here on.
    private func close() {
        gate.close()
        cancelSignIn()
    }

    private func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        importing = nil
        committing = false
        provider.discardPreparedSignIn()
        provider.cancelSignIn()
    }
}

/// An account's picture (or a person symbol) for the account picker.
private struct AccountChoiceAvatar: View {
    let url: URL?

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 26)).foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 26)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
    }
}

private struct YTMWebViewRepresentable: NSViewRepresentable {
    let reloadToken: Int
    let gate: YTMSignInGate
    let onCredentials: @MainActor (YTMCredentials) -> Void

    func makeCoordinator() -> YTMSignInNavigator { YTMSignInNavigator(gate: gate, onCredentials: onCredentials) }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.makeWebView(reloadToken: reloadToken)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.update(nsView, reloadToken: reloadToken)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: YTMSignInNavigator) {
        coordinator.invalidate(nsView)
    }
}
#endif

/// Closed when a sign-in sheet goes away (Cancel, swiped down, window closed). Shared by the sheet and its web
/// view's navigator: once closed, cookies the web view reads can't start a sign-in.
@MainActor
final class YTMSignInGate {
    private(set) var isClosed = false

    func close() { isClosed = true }

    /// The sheet is showing again.
    func open() { isClosed = false }
}

/// Watches the Google sign-in web view and hands over the YouTube cookies once the flow lands on
/// music.youtube.com. Shared by the macOS and iOS web view wrappers.
@MainActor
final class YTMSignInNavigator: NSObject, WKNavigationDelegate {
    let gate: YTMSignInGate
    let onCredentials: @MainActor (YTMCredentials) -> Void
    var loadedToken = 0
    private var delivered = false
    /// Set when the web view is torn down; nothing is delivered after that.
    private(set) var isInvalidated = false
    /// Bumped on reset so a cookie read suspended across its await can't deliver for a session being cleared.
    private var generation = 0

    init(gate: YTMSignInGate, onCredentials: @escaping @MainActor (YTMCredentials) -> Void) {
        self.gate = gate
        self.onCredentials = onCredentials
    }

    /// The web view is going away with its sheet: stop it and drop any cookie read still in flight.
    func invalidate(_ view: WKWebView? = nil) {
        isInvalidated = true
        generation &+= 1
        view?.stopLoading()
        if view?.navigationDelegate === self { view?.navigationDelegate = nil }
    }

    private var accepts: Bool { !isInvalidated && !gate.isClosed }

    func makeWebView(reloadToken: Int) -> WKWebView {
        let view = YTMSignInWebView.makeWebView()
        view.navigationDelegate = self
        loadedToken = reloadToken
        view.load(URLRequest(url: YTMSignInWebView.signInURL))
        return view
    }

    /// "Use a different account" bumps the token after clearing the session: reload to the account chooser.
    func update(_ view: WKWebView, reloadToken: Int) {
        guard loadedToken != reloadToken else { return }
        loadedToken = reloadToken
        reset()
        view.load(URLRequest(url: YTMSignInWebView.signInURL))
    }

    func reset() {
        delivered = false
        generation &+= 1
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Only deliver once the flow has landed on music.youtube.com (the final destination), so cookies aren't
        // grabbed mid-flow on an accounts.google.com or www.youtube.com step.
        guard !delivered, webView.url?.host == "music.youtube.com" else { return }
        let store = webView.configuration.websiteDataStore
        deliverCredentials { await YTMSignInWebView.youtubeCookies(in: store) }
    }

    /// Reads the cookies and hands them over, unless the session was reset, the web view torn down or the sheet
    /// closed while the read was suspended.
    @discardableResult
    func deliverCredentials(_ read: @escaping @MainActor () async -> YTMCredentials?) -> Task<Void, Never> {
        let gen = generation
        return Task { @MainActor in
            guard gen == self.generation, !self.delivered, self.accepts,
                  let creds = await read(),
                  gen == self.generation, !self.delivered, self.accepts else { return }
            self.delivered = true
            self.onCredentials(creds)
        }
    }
}

// MARK: - Snapshots (used by `openmusic-probe ytm render-signin`)

#if os(macOS)

public enum YTMViewSnapshots {
    /// The browser sign-in step in its states, with made-up profiles (nothing is read from this Mac).
    @MainActor
    public static func signInStates() -> [(name: String, view: AnyView)] {
        let aside = KnownBrowser.named(bundleID: "at.studio.asidebrowser")!
        let helium = KnownBrowser.named(bundleID: "net.imput.helium")!
        func login(_ b: KnownBrowser, _ dir: String, _ name: String) -> BrowserLogin {
            BrowserLogin(browser: b, profileDirectory: dir, profileName: name, cookiesURL: URL(fileURLWithPath: "/dev/null"))
        }
        let one = BrowserLoginScan(logins: [login(aside, "Default", "Work")], defaultBrowser: aside, defaultBrowserName: "Aside")
        let several = BrowserLoginScan(logins: [login(aside, "Default", "Work"), login(helium, "Default", "Personal"), login(helium, "Profile 1", "Music")],
                                       defaultBrowser: aside, defaultBrowserName: "Aside")
        let none = BrowserLoginScan(logins: [], defaultBrowser: aside, defaultBrowserName: "Aside")
        let twoAccounts = [
            BrowserAccount(identity: AccountIdentity(authUser: 0), info: AccountInfo(name: "Riley", detail: "@riley")),
            BrowserAccount(identity: AccountIdentity(authUser: 0, datasyncId: "chan||sess"), info: AccountInfo(name: "Riley's Band", detail: "Brand account")),
        ]
        return [
            ("ytm-signin-one", AnyView(YTMSignInView(preview: one))),
            ("ytm-signin-several", AnyView(YTMSignInView(preview: several))),
            ("ytm-signin-waiting", AnyView(YTMSignInView(preview: one, importing: true))),
            ("ytm-signin-denied", AnyView(YTMSignInView(preview: one, status: BrowserLoginError.keychainDenied(browser: "Aside").localizedDescription))),
            ("ytm-signin-open-browser", AnyView(YTMSignInView(preview: none))),
            ("ytm-signin-accounts", AnyView(YTMSignInView(preview: one, accounts: twoAccounts))),
        ]
    }
}

#endif

// MARK: - Headless check (used by `openmusic-probe ytm signin-check`)

/// Loads the sign-in page in an off-screen web view and reports what Google served.
@MainActor
public enum YTMSignInCheck {
    public struct Report: Sendable {
        public var finalURL: String
        public var title: String
        public var hasEmailField: Bool
        public var showsInsecureBrowserWarning: Bool
        public var headline: String
        /// PNG of the page as the web view rendered it, if requested.
        public var snapshotPNG: Data?
    }

    public static func run(timeout: TimeInterval = 25, snapshot: Bool = false) async -> Report? {
        let view = YTMSignInWebView.makeWebView()
        let delegate = LoadWaiter()
        view.navigationDelegate = delegate
        view.load(URLRequest(url: YTMSignInWebView.signInURL))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            guard delegate.finished else { continue }
            // Google's page renders its form with JS after load; poll for the email field.
            let js = """
            JSON.stringify({
              title: document.title,
              email: !!document.querySelector('input[type=email], input#identifierId'),
              insecure: /browser or app may not be secure|isn't secure|not secure/i.test(document.body ? document.body.innerText : ''),
              headline: (document.querySelector('h1') || {}).innerText || ''
            })
            """
            if let raw = try? await view.evaluateJavaScript(js) as? String,
               let data = raw.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                var report = Report(
                    finalURL: view.url?.absoluteString ?? "",
                    title: json["title"] as? String ?? "",
                    hasEmailField: json["email"] as? Bool ?? false,
                    showsInsecureBrowserWarning: json["insecure"] as? Bool ?? false,
                    headline: json["headline"] as? String ?? ""
                )
                if report.hasEmailField || report.showsInsecureBrowserWarning || Date().addingTimeInterval(3) > deadline {
                    if snapshot, let image = try? await view.takeSnapshot(configuration: nil) {
                        #if os(macOS)
                        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                            report.snapshotPNG = rep.representation(using: .png, properties: [:])
                        }
                        #else
                        report.snapshotPNG = image.pngData()
                        #endif
                    }
                    return report
                }
            }
        }
        return nil
    }

    @MainActor
    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        var finished = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    }
}
