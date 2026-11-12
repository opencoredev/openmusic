import AppKit
import AuthenticationServices
import MedleyCore
import MedleySync
import SwiftUI

// MARK: - Sign in

/// Email code, plus the social sign-ins the server's Clerk app has on. A new email address gets an account with
/// the same two steps.
struct SignInForm: View {
    let hub: SyncHub
    var back: (() -> Void)?
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
        VStack(alignment: .leading, spacing: 0) {
            if let challenge { codeStep(challenge) } else { emailStep }
            if let error {
                WarningLabel(error).font(.callout).padding(.top, 12)
            }
            HStack {
                if let back {
                    Button("Back") { if challenge != nil { challenge = nil; error = nil } else { back() } }
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            .padding(.top, 20)
        }
        .padding(28)
        .disabled(busy)
    }

    private var emailStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sign in to \(ProductInfo.name)").font(.title2.weight(.semibold))
            Text("One account for all your devices.")
                .foregroundStyle(.readableSecondary)
                .padding(.top, 4)
            let providers = hub.account.socialProviders
            if !providers.isEmpty {
                VStack(spacing: 8) {
                    ForEach(providers) { provider in
                        Button { socialSignIn(provider) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: provider.strategy == "oauth_apple" ? "apple.logo" : "globe")
                                Text("Continue with \(provider.name)")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                    }
                }
                .padding(.top, 20)
                HStack {
                    VStack { Divider() }
                    Text("or").font(.caption).foregroundStyle(.readableSecondary)
                    VStack { Divider() }
                }
                .padding(.vertical, 14)
            }
            TextField("Email address", text: $email)
                .textContentType(.emailAddress)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($focused, equals: .email)
                .onSubmit(sendCode)
                .padding(.top, providers.isEmpty ? 20 : 0)
            Button("Continue", action: sendCode)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .disabled(!email.contains("@"))
                .padding(.top, 10)
            Text("We'll email you a 6-digit code. New to \(ProductInfo.name)? The same steps create your account.")
                .font(.caption)
                .foregroundStyle(.readableSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
        .onAppear { focused = .email }
    }

    private func codeStep(_ challenge: ClerkEmailChallenge) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Check your email").font(.title2.weight(.semibold))
            Text("Enter the 6-digit code sent to \(challenge.email).")
                .foregroundStyle(.readableSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            TextField("Code", text: $code)
                .textContentType(.oneTimeCode)
                .textFieldStyle(.roundedBorder)
                .font(.title3.monospacedDigit())
                .controlSize(.large)
                .focused($focused, equals: .code)
                .onSubmit(verify)
                .padding(.top, 20)
            HStack {
                Button("Send a New Code", action: sendCode).buttonStyle(.link).font(.callout)
                Spacer()
                Button("Sign In", action: verify)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(code.filter(\.isNumber).count < 6)
            }
            .padding(.top, 10)
        }
        .onAppear { focused = .code }
    }

    private func sendCode() {
        guard email.contains("@") else { return }
        run {
            challenge = try await hub.account.startEmail(email)
            code = ""
        }
    }

    private func verify() {
        guard let challenge, code.filter(\.isNumber).count >= 6 else { return }
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
        SignInForm(hub: hub, back: { dismiss() }) { Task { await hub.didSignIn() } }
            .frame(width: 400)
    }
}

// MARK: - Server

/// "Use your own server": one URL of a self-hosted Medley server (a Convex deployment), checked before it is used.
struct ServerForm: View {
    let hub: SyncHub
    var back: (() -> Void)?
    @State private var text = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Use Your Own Server").font(.title2.weight(.semibold))
            Text("\(ProductInfo.name) syncs through its own server unless you run one. Enter your server's address; sign-in then goes through that server's Clerk app.")
                .foregroundStyle(.readableSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            TextField("Server address", text: $text, prompt: Text(verbatim: "your-deployment.convex.cloud"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($fieldFocused)
                .onSubmit(useServer)
                .padding(.top, 18)
            if let error {
                WarningLabel(error).font(.callout).padding(.top, 10)
            }
            HStack {
                if let back { Button("Back", action: back).keyboardShortcut(.cancelAction) }
                if hub.account.server.isCustom {
                    Button("Use \(ProductInfo.name)'s Server") { switchTo(nil) }
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Use Server", action: useServer)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 20)
            Text("A server is the \(ProductInfo.name) sync backend on your own Convex deployment, with your own Clerk app.")
                .font(.caption)
                .foregroundStyle(.readableSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
        }
        .padding(28)
        .disabled(busy)
        .onAppear {
            if hub.account.server.isCustom { text = hub.account.server.url.absoluteString }
            fieldFocused = true
        }
    }

    private func useServer() {
        busy = true
        error = nil
        Task {
            do { switchTo(try await hub.account.checkServer(text)) } catch { self.error = error.localizedDescription; busy = false; fieldFocused = true }
        }
    }

    private func switchTo(_ url: URL?) {
        busy = true
        Task {
            await hub.switchServer(to: url)
            busy = false
            back?()
        }
    }
}

struct ServerSheet: View {
    let hub: SyncHub
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ServerForm(hub: hub, back: { dismiss() }).frame(width: 440)
    }
}

// MARK: - Allow a device

// The "Allow <device>…?" alert is an NSAlert sheet run by `KeyRequestPrompter` (Sync/KeyRequestPrompter.swift).
