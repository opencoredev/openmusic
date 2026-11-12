import AppKit
import AuthenticationServices
import OpenMusicCore
import OpenMusicSync
import SwiftUI

/// The first-run flow over the whole main window, in the manner of Setup Assistant: a symbol, a title and one line
/// at the top, the step's controls in a narrow column, Back on the leading side of the bottom bar and the step's
/// action on the trailing side. Return is the step's action, Escape its way past (Not Now, Do This Later) or Back,
/// ⌘[ Back. Home loads underneath, so it is there the moment the flow ends.
struct FirstRunView: View {
    let flow: FirstRunFlow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            Group {
                switch flow.step {
                case .welcome: WelcomeStep(flow: flow)
                case .music: MusicStep(flow: flow)
                case .sync: SyncStep(flow: flow)
                case .server: ServerStep(flow: flow)
                case .approve: ApproveStep(flow: flow)
                }
            }
            .id(flow.step)
            .transition((flow.forward ? Motion.Transition.firstRunForward : .firstRunBack).transition(reduce: reduceMotion))
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35), value: flow.step)
        .modifier(DebugFrame(key: "first-run"))
    }
}

// MARK: - Page

/// One step: header, content and the bottom bar. The content scrolls when the window is short (900 × 560 at least).
private struct FirstRunPage<Content: View, Leading: View, Trailing: View>: View {
    let symbol: String
    let title: String
    let subtitle: String?
    @ViewBuilder var content: Content
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @State private var compact = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    HeaderGlyph(symbol: symbol, size: compact ? 56 : 72)
                    Text(title)
                        .font(.system(size: compact ? 24 : 28, weight: .bold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, compact ? 14 : 20)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .font(.title3)
                            .foregroundStyle(.readableSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)
                    }
                    content
                        .padding(.top, compact ? 22 : 30)
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 40)
                .padding(.top, compact ? 34 : 64)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            HStack(spacing: 12) {
                leading
                Spacer(minLength: 12)
                trailing
            }
            .controlSize(.large)
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
        .onGeometryChange(for: Bool.self) { $0.size.height < 680 } action: { compact = $0 }
    }
}

private struct HeaderGlyph: View {
    let symbol: String
    var size: CGFloat = 72

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .medium))
            .foregroundStyle(.tint)
            .frame(width: size, height: size)
            .modifier(TintedGlass())
            .accessibilityHidden(true)
    }
}

private struct TintedGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(.accentColor.opacity(0.14)), in: .circle)
        } else {
            content.background(Circle().fill(Color.accentColor.opacity(0.12)))
        }
    }
}

/// Back (⌘[), on the bottom bar's leading side.
private struct BackButton: View {
    let flow: FirstRunFlow
    var cancels = false

    var body: some View {
        // One shortcut per button: a second `keyboardShortcut` on the same button replaces the first, so ⌘[ is a
        // hidden button of its own.
        Button("Back") { flow.back() }
            .modifier(CancelShortcut(on: cancels))
            .background {
                Button("Back") { flow.back() }
                    .keyboardShortcut("[", modifiers: .command)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

private struct CancelShortcut: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.keyboardShortcut(.cancelAction) } else { content }
    }
}

private struct DefaultShortcut: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.keyboardShortcut(.defaultAction) } else { content }
    }
}

/// The inset box Setup Assistant draws around a list of choices.
private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

// MARK: - 1. Welcome

private struct WelcomeStep: View {
    let flow: FirstRunFlow

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            AppIconImage(size: 136)
            Text(ProductInfo.name)
                .font(.system(size: 40, weight: .bold))
                .padding(.top, 10)
                .accessibilityAddTraits(.isHeader)
            Text("YouTube Music and Spotify in one fast player, on all your devices.")
                .font(.title3)
                .foregroundStyle(.readableSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560)
                .padding(.top, 10)
            Button { flow.getStarted() } label: {
                Text("Get Started").frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 36)
            Spacer(minLength: 24)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 2. Your music

private struct MusicStep: View {
    let flow: FirstRunFlow

    var body: some View {
        FirstRunPage(symbol: "music.note.list", title: "Your music",
                     subtitle: "Play from YouTube Music, Spotify or both. You can change this later in Settings.") {
            VStack(spacing: 12) {
                Card {
                    YouTubeRow(flow: flow)
                    Divider().padding(.leading, 68)
                    SpotifyRow(flow: flow)
                }
                Text(flow.canContinueFromMusic ? " " : "Choose how to use YouTube Music, or connect Spotify, to continue.")
                    .font(.callout)
                    .foregroundStyle(.readableSecondary)
                    .accessibilityHidden(flow.canContinueFromMusic)
            }
        } leading: {
            BackButton(flow: flow, cancels: true)
        } trailing: {
            Button("Continue") { flow.continueFromMusic() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!flow.canContinueFromMusic)
        }
    }
}

private struct ServiceRow<Detail: View, Actions: View>: View {
    let provider: ProviderID
    @ViewBuilder var detail: Detail
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ServiceLogo(provider: provider, size: 38)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(provider.displayName).font(.headline)
                detail
                    .font(.callout)
                    .foregroundStyle(.readableSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 10)
            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

/// "Signed in as …" with a green check, read as one line.
private struct DoneLabel: View {
    let text: String

    var body: some View {
        Label {
            Text(text).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
        .foregroundStyle(.primary)
    }
}

private struct YouTubeRow: View {
    let flow: FirstRunFlow

    var body: some View {
        let status = flow.status(.youtubeMusic)
        ServiceRow(provider: .youtubeMusic) {
            switch status {
            case .signedIn(let info): DoneLabel(text: "Signed in as \(info.name)")
            case .failed(let message): WarningLabel(message)
            default:
                if flow.youTubeWithoutAccount {
                    DoneLabel(text: "Using without an account")
                } else {
                    Text("Browse and play for free, or sign in for your library and mixes.")
                }
            }
        } actions: {
            switch status {
            case .signedIn: EmptyView()
            case .signingIn: ProgressView().controlSize(.small).accessibilityLabel("Signing in")
            default:
                VStack(alignment: .trailing, spacing: 6) {
                    Button("Sign in with Google") { flow.signIn(.youtubeMusic) }
                    if !flow.youTubeWithoutAccount {
                        Button("Use without an account") { flow.useYouTubeWithoutAccount() }
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                }
            }
        }
    }
}

private struct SpotifyRow: View {
    let flow: FirstRunFlow

    var body: some View {
        let status = flow.status(.spotify)
        ServiceRow(provider: .spotify) {
            switch status {
            case .signedIn(let info): DoneLabel(text: "Connected as \(info.name)")
            case .failed(let message): WarningLabel(message)
            default:
                Text("Optional. Playback needs Spotify Premium.").font(.caption)
            }
        } actions: {
            switch status {
            case .signedIn: EmptyView()
            case .signingIn: ProgressView().controlSize(.small).accessibilityLabel("Connecting")
            default:
                Button("Connect") { flow.signIn(.spotify) }
                    .accessibilityLabel("Connect Spotify")
            }
        }
    }
}

// MARK: - 3. Sync

private struct SyncStep: View {
    let flow: FirstRunFlow
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @FocusState private var focus: Field?

    enum Field { case email, code }

    var body: some View {
        FirstRunPage(symbol: "laptopcomputer.and.iphone", title: "Pick up where you left off.",
                     subtitle: "Sign in to see what's playing on your other devices and move it here with one tap.") {
            VStack(spacing: 0) {
                if let user = model.sync?.account.user {
                    signedIn(user)
                } else if let challenge = flow.challenge {
                    codeEntry(challenge)
                } else {
                    signInChoices
                }
                if let error = flow.syncError {
                    WarningLabel(error).font(.callout).padding(.top, 12)
                        .frame(maxWidth: 360, alignment: .leading)
                }
                if let problem = model.sync?.account.serverProblem, model.sync?.account.user == nil {
                    VStack(spacing: 6) {
                        WarningLabel(problem).font(.callout)
                        Button("Try Again") { Task { await model.sync?.account.retry() } }
                    }
                    .padding(.top, 12)
                    .frame(maxWidth: 360)
                }
                PrivacyNote()
                    .padding(.top, 22)
                if model.sync?.account.user == nil {
                    serverLink.padding(.top, 14)
                }
            }
            .disabled(model.sync == nil)
        } leading: {
            BackButton(flow: flow)
        } trailing: {
            if model.sync?.account.user != nil {
                if flow.connectProblem != nil {
                    Button("Continue Without Syncing") { flow.continueWithoutSync() }
                        .keyboardShortcut(.cancelAction)
                }
                Button(flow.connectProblem == nil ? "Continue" : "Try Again") { flow.continueSignedIn() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(flow.activity == .settingUp)
            } else {
                Button("Not Now") { flow.finish() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(flow.isSigningIn)
            }
        }
        .onAppear { if flow.challenge == nil, model.sync?.account.user == nil { focus = .email } }
        .onChange(of: flow.challenge) { _, new in focus = new == nil ? .email : .code }
    }

    private var signInChoices: some View {
        VStack(spacing: 10) {
            ForEach(flow.socialProviders) { provider in
                Button { social(provider) } label: {
                    HStack(spacing: 8) {
                        if flow.activity == .social(provider.name) {
                            ProgressView().controlSize(.small)
                        } else {
                            ProviderMark(provider: provider)
                        }
                        Text("Continue with \(provider.name)")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(SocialButtonStyle(apple: provider == .apple))
                .disabled(!flow.isAccountReady || flow.activity != nil)
            }
            HStack(spacing: 10) {
                VStack { Divider() }
                Text("or").font(.callout).foregroundStyle(.readableSecondary)
                VStack { Divider() }
            }
            .padding(.vertical, 6)
            .accessibilityHidden(true)

            FieldLabel("Email address")
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                TextField("Email address", text: Bindable(flow).email)
                    .textContentType(.emailAddress)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($focus, equals: .email)
                    .onSubmit { flow.sendCode() }
                    .accessibilityLabel("Email address")
                Button { flow.sendCode() } label: {
                    if flow.activity == .sendingCode {
                        ProgressView().controlSize(.small).frame(minWidth: 72)
                    } else {
                        Text("Send Code").frame(minWidth: 72)
                    }
                }
                .controlSize(.large)
                .disabled(!flow.canSendCode)
            }
        }
        .frame(maxWidth: 360)
    }

    private func codeEntry(_ challenge: ClerkEmailChallenge) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text("Enter the 6-digit code sent to")
                // The address on a line of its own, never hyphenated; shortened in the middle when it doesn't fit.
                Text(verbatim: challenge.email)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.body)
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            HStack(spacing: 10) {
                TextField("Code", text: Bindable(flow).code, prompt: Text("6-digit code").font(.system(size: 15)))
                    .textContentType(.oneTimeCode)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 22, weight: .medium).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .frame(width: 240)
                    .focused($focus, equals: .code)
                    .onSubmit { flow.verify() }
                    .onChange(of: flow.code) { _, new in if new.count == 6 { flow.verify() } }
                    .accessibilityLabel("6-digit code")
                if flow.activity == .verifying || flow.activity == .settingUp {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(flow.activity == .verifying ? "Checking the code" : "Setting up sync")
                }
            }
            HStack(spacing: 18) {
                Button("Change Email") { flow.changeEmail() }
                    .buttonStyle(.link)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let wait = flow.resendWait(now: context.date)
                    Button(wait > 0 ? "Resend Code in \(wait) s" : "Resend Code") { flow.sendCode() }
                        .buttonStyle(.link)
                        .disabled(wait > 0 || flow.activity != nil)
                }
            }
            .font(.callout)
        }
        .frame(maxWidth: 400)
    }

    private func signedIn(_ user: ClerkUser) -> some View {
        VStack(spacing: 10) {
            DoneLabel(text: "Signed in as \(user.email ?? user.displayName)")
                .font(.body.weight(.medium))
            if flow.activity == .settingUp {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Setting up sync on this Mac…").foregroundStyle(.readableSecondary)
                }
                .accessibilityElement(children: .combine)
            } else if let problem = flow.connectProblem {
                WarningLabel("Signed in, but this Mac can't sync yet: \(problem) It keeps trying; Settings › Account shows how it's going.")
                    .font(.callout)
                    .frame(maxWidth: 400)
            }
        }
    }

    private var serverLink: some View {
        Group {
            if let server = model.sync?.account.server, server.isCustom {
                Button("Server: \(server.displayName)") { flow.openServer() }
            } else {
                Button("Use your own server") { flow.openServer() }
            }
        }
        .buttonStyle(.link)
        .font(.callout)
    }

    private func social(_ provider: ClerkOAuthProvider) {
        flow.socialSignIn(provider) { url in
            do {
                return try await webAuthenticationSession.authenticate(using: url, callbackURLScheme: ProductInfo.urlScheme,
                                                                      preferredBrowserSession: .ephemeral)
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                return nil
            }
        }
    }
}

/// "OpenMusic's server sees when you play and pause, never what you play."
private struct PrivacyNote: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.readableSecondary)
                .accessibilityHidden(true)
            Text("\(ProductInfo.name)'s server sees when you play and pause, never what you play. Songs, queues and searches are encrypted on your devices.")
                .foregroundStyle(.readableSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .frame(maxWidth: 400)
        .accessibilityElement(children: .combine)
    }
}

/// Apple's mark, or a "G" in Google's four colors.
private struct ProviderMark: View {
    let provider: ClerkOAuthProvider

    var body: some View {
        Group {
            if provider == .apple {
                Image(systemName: "apple.logo").font(.system(size: 15, weight: .medium))
            } else {
                Text(verbatim: "G")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(AngularGradient(colors: [.red, .yellow, .green, .blue, .red], center: .center))
            }
        }
        .frame(width: 18)
        .accessibilityHidden(true)
    }
}

/// Continue with Apple in Apple's black (white in dark mode) style; Continue with Google in the plain bordered one.
private struct SocialButtonStyle: ButtonStyle {
    let apple: Bool

    func makeBody(configuration: Configuration) -> some View {
        SocialBody(configuration: configuration, apple: apple)
    }

    private struct SocialBody: View {
        let configuration: Configuration
        let apple: Bool
        @Environment(\.colorScheme) private var scheme
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let dark = scheme == .dark
            configuration.label
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(apple ? (dark ? Color.black : Color.white) : Color.primary)
                .frame(height: 38)
                .frame(maxWidth: .infinity)
                .background {
                    Capsule(style: .continuous)
                        .fill(apple ? (dark ? Color.white : Color.black) : Color(nsColor: .controlBackgroundColor))
                    if !apple { Capsule(style: .continuous).strokeBorder(Color(nsColor: .separatorColor)) }
                }
                .overlay { if configuration.isPressed { Capsule(style: .continuous).fill(.black.opacity(dark && !apple ? 0.2 : 0.12)) } }
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Capsule())
        }
    }
}

// MARK: - Use your own server

private struct ServerStep: View {
    let flow: FirstRunFlow
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        FirstRunPage(symbol: "server.rack", title: "Use your own server",
                     subtitle: "Enter the address of your \(ProductInfo.name) server. \(ProductInfo.name) checks it before switching, and sign-in then goes through that server.") {
            VStack(alignment: .leading, spacing: 12) {
                FieldLabel("Server address")
                HStack(spacing: 8) {
                    TextField("Server address", text: Bindable(flow).serverText, prompt: Text(verbatim: "https://your-deployment.convex.cloud"))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .focused($focused)
                        .onSubmit { flow.checkServer() }
                        .onChange(of: flow.serverText) { flow.serverTextDidChange() }
                        .accessibilityLabel("Server address")
                    Button("Check") { flow.checkServer() }
                        .controlSize(.large)
                        .disabled(flow.serverText.trimmingCharacters(in: .whitespaces).isEmpty || isChecking)
                }
                result
                    .frame(minHeight: 44, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Already have a server? Enter its address above.")
                        .font(.callout)
                        .foregroundStyle(.readableSecondary)
                    Button("Set up an \(ProductInfo.name) server") { flow.showsServerGuide = true }
                        .buttonStyle(.link)
                        .font(.callout)
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: 420)
        } leading: {
            BackButton(flow: flow, cancels: true)
        } trailing: {
            if model.sync?.account.server.isCustom == true {
                Button("Use \(ProductInfo.name)'s Server") { flow.useServer(nil) }
                    .disabled(flow.activity == .switchingServer)
            }
            let use = Button {
                if case .reachable(let url) = flow.serverCheck { flow.useServer(url) }
            } label: {
                if flow.activity == .switchingServer { ProgressView().controlSize(.small).frame(minWidth: 110) } else { Text("Use This Server") }
            }
            .modifier(DefaultShortcut(on: isReachable))
            .disabled(!isReachable || flow.activity == .switchingServer)
            // The accent only once the address checked out; plain (and disabled) until then.
            if isReachable { use.buttonStyle(.borderedProminent) } else { use.buttonStyle(.bordered) }
        }
        .onAppear { focused = true }
        .sheet(isPresented: Bindable(flow).showsServerGuide) { ServerGuide() }
    }

    private var isChecking: Bool { if case .checking = flow.serverCheck { true } else { false } }
    private var isReachable: Bool { if case .reachable = flow.serverCheck { true } else { false } }

    @ViewBuilder private var result: some View {
        switch flow.serverCheck {
        case .idle:
            EmptyView()
        case .checking(let host):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking \(host)…").foregroundStyle(.readableSecondary)
            }
            .accessibilityElement(children: .combine)
        case .reachable(let url):
            VStack(alignment: .leading, spacing: 2) {
                DoneLabel(text: "Reachable and set up").font(.body.weight(.medium))
                Text("\(url.host ?? url.absoluteString) runs the \(ProductInfo.name) server with sign-in on. Use This Server signs this Mac in there.")
                    .font(.callout)
                    .foregroundStyle(.readableSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 24)
            }
            .accessibilityElement(children: .combine)
        case .failed(let message):
            WarningLabel(message).font(.callout)
        }
    }
}

// MARK: - 4. Approve this device

private struct ApproveStep: View {
    let flow: FirstRunFlow
    @Environment(AppModel.self) private var model

    var body: some View {
        let service = model.sync?.service
        let status = service?.keyStatus ?? .none
        FirstRunPage(symbol: status == .available ? "checkmark.shield" : "lock.shield",
                     title: status == .available ? "This Mac is approved" : FirstRun.approveTitle(holders: service?.keyHolders ?? [], here: "this Mac"),
                     subtitle: status == .available
                        ? "Your sign-ins and settings now sync to this Mac."
                        : "Your YouTube Music and Spotify sign-ins are encrypted with a key only your devices hold. Approving shares it with this Mac.") {
            VStack(spacing: 14) {
                content(status, holders: service?.keyHolders ?? [])
                if let error = flow.syncError {
                    WarningLabel(error).font(.callout)
                }
            }
            .frame(maxWidth: 440)
        } leading: {
            if status != .available {
                Button("Do This Later") { flow.doThisLater() }
                    .keyboardShortcut(.cancelAction)
            }
        } trailing: {
            trailing(status)
        }
        .task(id: status == .available) { if status == .available { await flow.approved() } }
    }

    @ViewBuilder private func content(_ status: SyncService.KeyStatus, holders: [SyncDevice]) -> some View {
        let holder = holders.first?.name ?? "your other device"
        switch status {
        case .comparing(let comparison):
            CodeCard(code: comparison.code)
            Text(comparison.confirmed && !comparison.allowed
                 ? "Now choose Allow on \(comparison.holderName)."
                 : comparison.allowed
                    ? "\(comparison.holderName) allowed this Mac. Choose Codes Match if it showed this same code."
                    : "\(comparison.holderName) shows a code too. If it's the same, choose Allow there and Codes Match here.")
                .font(.body)
                .foregroundStyle(.readableSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if comparison.confirmed {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(comparison.allowed ? "Taking your sign-ins…" : "Waiting for \(comparison.holderName)…").foregroundStyle(.readableSecondary)
                }
                .accessibilityElement(children: .combine)
            }
        case .available:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
        case .denied:
            WarningLabel("\(holder) didn't allow this Mac. Ask again, or sign in to YouTube Music and Spotify here.", symbol: "key.slash")
                .font(.body)
        case .failed(let message):
            WarningLabel(message).font(.body)
        case .outdated:
            WarningLabel("Your sign-ins changed while this Mac was away. Ask again, then compare the code.", symbol: "key.slash").font(.body)
        default:
            CodeCard(code: nil)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for \(holder)…").foregroundStyle(.readableSecondary)
            }
            .accessibilityElement(children: .combine)
            Text("Open \(ProductInfo.name) on \(holder). It asks to approve this Mac and shows the same code.")
                .font(.callout)
                .foregroundStyle(.readableSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func trailing(_ status: SyncService.KeyStatus) -> some View {
        switch status {
        case .comparing(let comparison) where !comparison.confirmed:
            Button("Codes Don't Match") { flow.codesDontMatch() }
            Button("Codes Match") { flow.codesMatch() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        case .denied, .failed, .outdated:
            Button("Ask Again") { flow.askAgain() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(flow.askingAgain)
        default:
            EmptyView()
        }
    }
}

/// The six digits, large, to read against the other screen; dashes until the other device answers.
private struct CodeCard: View {
    let code: String?

    var body: some View {
        VStack(spacing: 4) {
            Text("Code")
                .font(.callout.weight(.medium))
                .foregroundStyle(.readableSecondary)
            Text(code.map(FirstRun.spacedCode) ?? "––– –––")
                .font(.system(size: 46, weight: .semibold, design: .rounded).monospacedDigit())
                .tracking(4)
                .foregroundStyle(code == nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.primary))
                .textSelection(.enabled)
        }
        .padding(.vertical, 18)
        .frame(maxWidth: 320)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(code.map { "Code \(FirstRun.spokenCode($0))" } ?? "No code yet")
    }
}

/// A field's name above it, so it stays when the placeholder goes.
private struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.bottom, -6)
            .accessibilityHidden(true)
    }
}

/// "Set up an OpenMusic server": the self-hosting guide in four steps, as a sheet over the flow.
private struct ServerGuide: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Set up an \(ProductInfo.name) server")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Your own server keeps sync on a machine you control.")
                .foregroundStyle(.readableSecondary)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(FirstRun.serverSetupSteps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.accentColor))
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title).font(.headline)
                            Text(step.detail)
                                .foregroundStyle(.readableSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Step \(index + 1), \(step.title). \(step.detail)")
                    }
                }
            }
            .padding(.top, 20)
            Text(FirstRun.serverSetupFooter)
                .font(.caption)
                .foregroundStyle(.readableSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 20)
        }
        .padding(28)
        .frame(width: 480)
    }
}
