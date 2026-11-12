#if os(iOS)
import OpenMusicCore
import SwiftUI
import UIKit
import WebKit

/// Google sign-in for YouTube Music on iPhone: Google's own pages in a web view, then (when the Google account
/// has several channels or brand accounts) a picker for which one OpenMusic uses. Same flow as the Mac's embedded
/// sign-in; borrowing a browser's login is macOS only.
struct YTMSignInView: View {
    let provider: YouTubeMusicProvider
    let onFinish: @MainActor () -> Void

    /// Bumped to reload the Google web view after clearing its session ("Use a different account").
    @State private var webReloadToken = 0
    @State private var accounts: [BrowserAccount]?
    @State private var committing: BrowserAccount.ID?
    @State private var isWorking = false
    @State private var ignoringCapture = false
    @State private var status: String?
    @State private var signInTask: Task<Void, Never>?
    /// Closed with the sheet, so a cookie read still in flight in the web view can't start a sign-in afterwards.
    @State private var gate = YTMSignInGate()

    init(provider: YouTubeMusicProvider, onFinish: @escaping @MainActor () -> Void) {
        self.provider = provider
        self.onFinish = onFinish
    }

    var body: some View {
        NavigationStack {
            Group {
                if let accounts {
                    accountPicker(accounts)
                } else {
                    YTMWebViewRepresentable(reloadToken: webReloadToken, gate: gate, onCredentials: captured)
                        .ignoresSafeArea(edges: .bottom)
                        .overlay {
                            if isWorking {
                                VStack(spacing: 12) {
                                    ProgressView()
                                    Text("Signing you in…").font(.callout).foregroundStyle(.secondary)
                                }
                                .padding(24)
                                .glassEffect(in: .rect(cornerRadius: 20))
                            }
                        }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let status {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                }
            }
            .navigationTitle(accounts == nil ? "YouTube Music" : "Choose an Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        close()
                        onFinish()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Use a Different Account", systemImage: "person.crop.circle.badge.plus") { backToGoogle() }
                            .disabled(isWorking || committing != nil)
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
        }
        .interactiveDismissDisabled(isWorking || committing != nil)
        .onAppear { gate.open() }
        .onDisappear { close() }
    }

    // MARK: Account picker

    private func accountPicker(_ accounts: [BrowserAccount]) -> some View {
        List {
            Section {
                ForEach(accounts) { account in
                    Button { commit(account) } label: {
                        HStack(spacing: 12) {
                            Avatar(url: account.info.avatar)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.info.name).foregroundStyle(.primary)
                                if let detail = account.info.detail {
                                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            if committing == account.id { ProgressView() }
                        }
                        .contentShape(.rect)
                    }
                    .disabled(committing != nil)
                }
            } header: {
                Text("This Google account has more than one channel. Pick the one for \(ProductInfo.name).")
                    .textCase(nil)
                    .font(.subheadline)
            }
            Section {
                Button("Use a Different Account") { backToGoogle() }
                    .disabled(committing != nil)
            }
        }
    }

    // MARK: Flow

    private func captured(_ creds: YTMCredentials) {
        guard !isWorking, !ignoringCapture, !gate.isClosed else { return }
        isWorking = true
        status = nil
        signInTask = Task {
            do {
                // If the person already picked a channel on YouTube's "Choose a channel" page, the session acts as
                // it: sign in as that one rather than asking again.
                let found = try await provider.prepareAccounts(credentials: creds, sourceName: "YouTube", preferSelected: true)
                guard !Task.isCancelled else { return }
                if found.authoritative, found.accounts.count == 1, let only = found.accounts.first {
                    try await provider.commitBrowserSignIn(only)
                    guard !Task.isCancelled else { return }
                    signInTask = nil
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onFinish()
                } else {
                    accounts = found.accounts
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

    private func commit(_ account: BrowserAccount) {
        guard committing == nil else { return }
        committing = account.id
        status = nil
        signInTask = Task {
            do {
                try await provider.commitBrowserSignIn(account)
                guard !Task.isCancelled else { return }
                signInTask = nil
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onFinish()
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                signInTask = nil
                committing = nil
                status = error.localizedDescription
            }
        }
    }

    /// Clears the Google session in the web view and reloads, so the next sign-in starts at the account chooser.
    private func backToGoogle() {
        guard !ignoringCapture else { return }
        cancelSignIn()
        accounts = nil
        isWorking = false
        status = nil
        ignoringCapture = true
        Task {
            await YTMSignInWebView.clearWebsiteData()
            webReloadToken += 1
            ignoringCapture = false
        }
    }

    /// The sheet is closing: nothing may sign in from here on.
    private func close() {
        gate.close()
        cancelSignIn()
    }

    private func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        committing = nil
        provider.discardPreparedSignIn()
        provider.cancelSignIn()
    }
}

private struct Avatar: View {
    let url: URL?

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

private struct YTMWebViewRepresentable: UIViewRepresentable {
    let reloadToken: Int
    let gate: YTMSignInGate
    let onCredentials: @MainActor (YTMCredentials) -> Void

    func makeCoordinator() -> YTMSignInNavigator { YTMSignInNavigator(gate: gate, onCredentials: onCredentials) }

    func makeUIView(context: Context) -> WKWebView {
        let view = context.coordinator.makeWebView(reloadToken: reloadToken)
        view.allowsBackForwardNavigationGestures = true
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.update(uiView, reloadToken: reloadToken)
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: YTMSignInNavigator) {
        coordinator.invalidate(uiView)
    }
}
#endif
