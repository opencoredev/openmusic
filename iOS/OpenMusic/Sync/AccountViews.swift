import AuthenticationServices
import OpenMusicCore
import OpenMusicSync
import SwiftUI

// MARK: - Sign in

/// Email code, plus the social sign-ins the server's Clerk app has on. A new email address gets an account with the
/// same two steps.
struct SignInForm: View {
    let hub: SyncHub
    let done: () -> Void
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var email = ""
    @State private var code = ""
    @State private var challenge: ClerkEmailChallenge?
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Field?

    enum Field { case email, code }

    var body: some View {
        Form {
            if let challenge {
                Section {
                    TextField("6-digit code", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.title3.monospacedDigit())
                        .focused($focused, equals: .code)
                        .onChange(of: code) { _, new in if new.filter(\.isNumber).count == 6 { verify() } }
                } header: {
                    Text("Check your email")
                } footer: {
                    Text("Enter the code sent to \(challenge.email).")
                }
                Section {
                    Button { verify() } label: { busyLabel("Sign In") }
                        .disabled(code.filter(\.isNumber).count < 6)
                    Button("Send a New Code") { sendCode() }
                    Button("Use a Different Email") { self.challenge = nil; error = nil }
                }
            } else {
                let providers = hub.account.socialProviders
                if !providers.isEmpty {
                    Section {
                        ForEach(providers) { provider in
                            Button { socialSignIn(provider) } label: {
                                Label("Continue with \(provider.name)", systemImage: provider.strategy == "oauth_apple" ? "apple.logo" : "globe")
                            }
                        }
                    }
                }
                Section {
                    TextField("Email address", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.continue)
                        .focused($focused, equals: .email)
                        .onSubmit(sendCode)
                    Button { sendCode() } label: { busyLabel("Continue") }
                        .disabled(!email.contains("@"))
                } footer: {
                    Text("We'll email you a 6-digit code. New to \(ProductInfo.name)? The same steps create your account.")
                }
            }
            if let error {
                Section { WarningText(error).font(.subheadline) }
            }
        }
        .navigationTitle("Sign In to \(ProductInfo.name)")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(busy)
        .onAppear { focused = challenge == nil ? .email : .code }
        .onChange(of: challenge) { _, new in focused = new == nil ? .email : .code }
    }

    private func busyLabel(_ title: String) -> some View {
        HStack {
            Text(title).font(.body.weight(.semibold))
            Spacer()
            if busy { ProgressView() }
        }
    }

    private func sendCode() {
        guard email.contains("@") else { return }
        run {
            challenge = try await hub.account.startEmail(email)
            code = ""
        }
    }

    private func verify() {
        guard let challenge, code.filter(\.isNumber).count >= 6, !busy else { return }
        run {
            try await hub.account.verifyEmail(challenge, code: code)
            done()
        }
    }

    private func socialSignIn(_ provider: ClerkOAuthProvider) {
        run {
            let start = try await hub.account.startOAuth(provider)
            let callback: URL
            do {
                callback = try await webAuthenticationSession.authenticate(using: start.url, callbackURLScheme: ProductInfo.urlScheme, preferredBrowserSession: .ephemeral)
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                return
            }
            try await hub.account.completeOAuth(start, callback: callback)
            done()
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        busy = true
        error = nil
        Task {
            do { try await work() } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

/// Settings › Account › Sign In, as a sheet.
struct SignInSheet: View {
    let hub: SyncHub
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SignInForm(hub: hub) { Task { await hub.didSignIn() } }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", systemImage: "xmark") { dismiss() }
                    }
                }
        }
    }
}

// MARK: - Server

/// "Use your own server": one URL of a self-hosted OpenMusic server (a Convex deployment), checked before use.
struct ServerForm: View {
    let hub: SyncHub
    let done: () -> Void
    @State private var text = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Server address", text: $text, prompt: Text(verbatim: "your-deployment.convex.cloud"))
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(useServer)
            } header: {
                Text("Server address")
            } footer: {
                Text("\(ProductInfo.name) syncs through its own server unless you run one: the \(ProductInfo.name) sync backend on your own Convex deployment, with your own Clerk app. Sign-in then goes through that server.")
            }
            Section {
                Button { useServer() } label: {
                    HStack {
                        Text("Use Server").font(.body.weight(.semibold))
                        Spacer()
                        if busy { ProgressView() }
                    }
                }
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                if hub.account.server.isCustom {
                    Button("Use \(ProductInfo.name)'s Server") { switchTo(nil) }
                }
            }
            if let error {
                Section { WarningText(error).font(.subheadline) }
            }
        }
        .navigationTitle("Your Own Server")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(busy)
        .onAppear { if hub.account.server.isCustom { text = hub.account.server.url.absoluteString } }
    }

    private func useServer() {
        busy = true
        error = nil
        Task {
            do { switchTo(try await hub.account.checkServer(text)) } catch { self.error = error.localizedDescription; busy = false }
        }
    }

    private func switchTo(_ url: URL?) {
        busy = true
        Task {
            await hub.switchServer(to: url)
            busy = false
            done()
        }
    }
}

// MARK: - Allow a device

/// "Allow Riley's Mac to use your YouTube Music and Spotify sign-ins?" while another device asks for the sign-in key
/// and this iPhone has it: a sheet with the code as large as the asking device shows it (a system alert could only
/// show it as small gray text), Allow and Don't Allow. Swiping it away dismisses this exchange; a new request from
/// the same device asks again.
struct KeyRequestAlert: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let request = model.sync?.pendingKeyRequest
        content.sheet(item: Binding(get: { request }, set: { if $0 == nil, let request { model.sync?.dismissedKeyRequests.dismiss(request) } })) { request in
            KeyRequestSheet(request: request)
                .presentationDragIndicator(.visible)
        }
    }
}

private struct KeyRequestSheet: View {
    let request: SyncService.KeyRequest
    @Environment(AppModel.self) private var model
    /// The content's height: the sheet fits it, with room under Don't Allow (scrolling at large text sizes).
    @State private var height: CGFloat = 520

    var body: some View {
        let name = request.device.name
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(FirstRun.allowTitle(name))
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(FirstRun.spacedCode(request.code))
                    .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                    .tracking(3)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20, style: .continuous))
                    .accessibilityLabel("Code \(FirstRun.spokenCode(request.code))")
                Text(FirstRun.allowMessage(name))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 10) {
                    Button { answer(allow: true) } label: {
                        Text("Allow").font(.headline).frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    Button { answer(allow: false) } label: {
                        Text("Don't Allow").font(.headline).frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 24)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.height(height + 12), .large])
        // Opaque: the code and the question read the same over any Home behind the sheet.
        .presentationBackground(Color(.systemBackground))
    }

    private func answer(allow: Bool) {
        guard let hub = model.sync else { return }
        // Answered: this exchange doesn't come back while its answer is on the way.
        hub.dismissedKeyRequests.dismiss(request)
        Task { if allow { await hub.allowKey(request) } else { await hub.denyKey(request) } }
    }
}

/// An error or warning line: the triangle is orange, the text stays at full contrast (orange text on white is
/// about 2.3:1).
struct WarningText: View {
    let text: String
    var symbol = "exclamationmark.triangle.fill"

    init(_ text: String, symbol: String = "exclamationmark.triangle.fill") {
        self.text = text
        self.symbol = symbol
    }

    var body: some View {
        Label {
            Text(text).foregroundStyle(.primary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.orange)
        }
    }
}
