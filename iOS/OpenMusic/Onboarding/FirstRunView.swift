import AuthenticationServices
import OpenMusicCore
import OpenMusicSync
import SwiftUI

/// The first-run flow, full screen: Welcome, then a navigation stack of Your music, Sync (Use your own server),
/// Approve this device. Each step is a scrolling page with its title in the content and its buttons in a bar at the
/// bottom; at accessibility text sizes the buttons scroll with the page instead, so nothing is cut off.
struct FirstRunView: View {
    let flow: FirstRunFlow
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var flow = flow
        NavigationStack(path: $flow.path) {
            WelcomeStep(flow: flow)
                .navigationDestination(for: FirstRun.Step.self) { step in
                    switch step {
                    case .welcome: WelcomeStep(flow: flow)
                    case .music: MusicStep(flow: flow)
                    case .sync: SyncStep(flow: flow)
                    case .server: ServerStep(flow: flow)
                    case .approve: ApproveStep(flow: flow)
                    }
                }
        }
        .sheet(item: $flow.signingIn) { id in
            if let provider = model.provider(id) {
                provider.makeSignInView { flow.signInFinished() }
                    .presentationDetents(id == .spotify ? [.medium] : [.large])
            }
        }
        // A device asking this iPhone for the key while the flow is up (the cover hides RootView's alert).
        .modifier(KeyRequestAlert())
    }
}

// MARK: - Page

private struct FirstRunPage<Content: View, Actions: View>: View {
    let symbol: String
    let title: String
    let subtitle: String?
    /// False while the page is about one field (the email code): the symbol and the line go, so the field, its error
    /// and its links stay above the keyboard.
    var showsHeader = true
    /// The step's way past it (Not Now, Do This Later): always in the bottom bar, at every text size.
    var escape: (title: String, action: () -> Void)? = nil
    /// The way past is shown but waits (a sign-in on its way).
    var escapeDisabled = false
    /// Explanation that, at accessibility sizes, comes after the actions instead of before them.
    var explanation: String? = nil
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var short = false

    var body: some View {
        let large = typeSize.isAccessibilitySize
        // At accessibility sizes and on short screens (iPhone SE) the decorative symbol gives its room to the task;
        // at accessibility sizes the title leads, the controls come next and the longer explanation after them.
        let showsSymbol = showsHeader && !large && !short
        let alignment: HorizontalAlignment = large ? .leading : .center
        let textAlignment: TextAlignment = large ? .leading : .center
        ScrollView {
            VStack(alignment: alignment, spacing: 0) {
                if showsSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 76, height: 76)
                        .glassEffect(.regular.tint(.accentColor.opacity(0.14)), in: .circle)
                        .padding(.bottom, 20)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(showsHeader && !large ? .largeTitle.bold() : .title2.bold())
                    .multilineTextAlignment(textAlignment)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle, showsHeader, !large {
                    subtitleText(subtitle, alignment: textAlignment).padding(.top, 10)
                }
                content
                    .padding(.top, large || short || !showsHeader ? 20 : 28)
                if let explanation, !large {
                    explanationText(explanation).padding(.top, 16)
                }
                if large {
                    // One scrolling stack at accessibility sizes: the step's actions, then its way past.
                    ActionBar { actions }
                        .padding(.top, 24)
                    if let explanation { explanationText(explanation).padding(.top, 20) }
                    if let subtitle, showsHeader {
                        subtitleText(subtitle, alignment: textAlignment).padding(.top, 24)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 20)
            .frame(maxWidth: 560, alignment: large ? .leading : .center)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaBar(edge: .bottom) {
            if !large {
                ActionBar {
                    actions
                    if let escape { SecondaryButton(title: escape.title, action: escape.action).disabled(escapeDisabled) }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.height < 600 } action: { short = $0 }
        .navigationBarTitleDisplayMode(.inline)
        // At accessibility sizes the way past sits in the navigation bar: always in view, never over a button.
        .toolbar {
            if large, let escape {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(escape.title, action: escape.action).disabled(escapeDisabled)
                }
            }
        }
    }

    private func explanationText(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: typeSize.isAccessibilitySize ? .leading : .center)
    }

    private func subtitleText(_ text: String, alignment: TextAlignment) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ActionBar<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 12) { content }
            .frame(maxWidth: 520)
    }
}

/// The step's one prominent action, full width.
private struct PrimaryButton: View {
    let title: String
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(busy ? 0 : 1)
                if busy { ProgressView() }
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .modifier(LargeTextShape())
        .accessibilityLabel(title)
    }
}

/// Capsules at ordinary sizes; at accessibility sizes, where labels wrap, rounded rectangles that hold two lines well.
private struct LargeTextShape: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize
    func body(content: Content) -> some View {
        content.buttonBorderShape(typeSize.isAccessibilitySize ? .roundedRectangle(radius: 22) : .capsule)
    }
}

/// Not Now, Do This Later, Codes Don't Match: a plain text button under the primary one.
private struct SecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .font(.body.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(.rect)
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 24, style: .continuous))
    }
}

/// "Signed in as …" with a green check.
private struct DoneLabel: View {
    let text: String
    var body: some View {
        Label {
            Text(text).foregroundStyle(.primary)
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }
}

// MARK: - 1. Welcome

private struct WelcomeStep: View {
    let flow: FirstRunFlow
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: typeSize.isAccessibilitySize ? 24 : 80)
                Image(systemName: "music.note")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [.white, Color(white: 0.82)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 120, height: 120)
                    .background(LinearGradient(colors: [Color(white: 0.27), Color(white: 0.09)], startPoint: .top, endPoint: .bottom),
                                in: .rect(cornerRadius: 27, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
                    .accessibilityHidden(true)
                Text(ProductInfo.name)
                    .font(.system(.largeTitle, weight: .bold))
                    .padding(.top, 26)
                    .accessibilityAddTraits(.isHeader)
                Text("YouTube Music and Spotify in one fast player, on all your devices.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                if typeSize.isAccessibilitySize {
                    PrimaryButton(title: "Get Started") { flow.getStarted() }.padding(.top, 32)
                }
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaBar(edge: .bottom) {
            if !typeSize.isAccessibilitySize {
                PrimaryButton(title: "Get Started") { flow.getStarted() }
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

// MARK: - 2. Your music

private struct MusicStep: View {
    let flow: FirstRunFlow

    var body: some View {
        FirstRunPage(symbol: "music.note.list", title: "Your music",
                     subtitle: "Play from YouTube Music, Spotify or both. You can change this later in Settings.") {
            VStack(spacing: 14) {
                YouTubeCard(flow: flow)
                SpotifyCard(flow: flow)
            }
        } actions: {
            if !flow.canContinueFromMusic {
                Text("Choose how to use YouTube Music, or connect Spotify, to continue.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            PrimaryButton(title: "Continue") { flow.continueFromMusic() }
                .disabled(!flow.canContinueFromMusic)
        }
    }
}

private struct ServiceHeader<Detail: View>: View {
    let id: ProviderID
    @ViewBuilder var detail: Detail
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At accessibility sizes the logo sits above the name, so the words get the card's full width.
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
        layout {
            ServiceMark(id: id, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(id.displayName).font(.headline)
                detail
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct YouTubeCard: View {
    let flow: FirstRunFlow

    var body: some View {
        let status = flow.status(.youtubeMusic)
        Card {
            VStack(alignment: .leading, spacing: 14) {
                ServiceHeader(id: .youtubeMusic) {
                    switch status {
                    case .signedIn(let info): DoneLabel(text: "Signed in as \(info.name)")
                    case .signingIn: Text("Signing in…")
                    case .failed(let message): WarningText(message)
                    case .signedOut:
                        if flow.youTubeWithoutAccount { DoneLabel(text: "Using without an account") }
                        else { Text("Browse and play for free, or sign in for your library and mixes.") }
                    }
                }
                if !status.isSignedIn {
                    PairLayout {
                        Button { flow.signIn(.youtubeMusic) } label: {
                            Text("Sign in with Google").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        if !flow.youTubeWithoutAccount {
                            Button { flow.useYouTubeWithoutAccount() } label: {
                                Text("Use without an account").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                            .controlSize(.large)
                        }
                    }
                }
            }
            .padding(18)
        }
    }
}

private struct SpotifyCard: View {
    let flow: FirstRunFlow

    var body: some View {
        let status = flow.status(.spotify)
        Card {
            VStack(alignment: .leading, spacing: 14) {
                ServiceHeader(id: .spotify) {
                    switch status {
                    case .signedIn(let info): DoneLabel(text: "Connected as \(info.name)")
                    case .signingIn: Text("Connecting…")
                    case .failed(let message): WarningText(message)
                    case .signedOut: Text("Optional. Playback needs Spotify Premium.").font(.footnote)
                    }
                }
                if !status.isSignedIn {
                    Button { flow.signIn(.spotify) } label: {
                        Text("Connect").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .accessibilityLabel("Connect Spotify")
                }
            }
            .padding(18)
        }
    }
}

/// Two controls side by side, stacked once the text is too large for both.
private struct PairLayout<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        let layout = typeSize > .xxLarge ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        layout { content }
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
        let enteringCode = flow.challenge != nil && model.sync?.account.user == nil
        FirstRunPage(symbol: "iphone.and.arrow.forward", title: enteringCode ? "Check your email" : "Pick up where you left off.",
                     subtitle: "Sign in to see what's playing on your other devices and move it here with one tap.",
                     showsHeader: !enteringCode,
                     escape: model.sync?.account.user == nil
                        ? (enteringCode ? nil : ("Not Now", { flow.finish() }))
                        : (flow.connectProblem != nil ? ("Continue Without Syncing", { flow.continueWithoutSync() }) : nil),
                     escapeDisabled: flow.isSigningIn) {
            VStack(spacing: 0) {
                if let user = model.sync?.account.user {
                    signedIn(user)
                } else if let challenge = flow.challenge {
                    codeEntry(challenge)
                } else {
                    signInChoices
                }
                if let error = flow.syncError, !enteringCode {
                    WarningText(error).font(.subheadline).padding(.top, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let problem = model.sync?.account.serverProblem, model.sync?.account.user == nil {
                    VStack(spacing: 6) {
                        WarningText(problem).font(.subheadline)
                        Button("Try Again") { Task { await model.sync?.account.retry() } }.font(.subheadline.weight(.semibold))
                    }
                    .padding(.top, 14)
                }
                if !enteringCode {
                    PrivacyNote().padding(.top, 24)
                }
                if model.sync?.account.user == nil, !enteringCode {
                    serverLink.padding(.top, 10)
                }
            }
            .disabled(model.sync == nil)
        } actions: {
            if model.sync?.account.user != nil {
                PrimaryButton(title: flow.connectProblem == nil ? "Continue" : "Try Again", busy: flow.activity == .settingUp) { flow.continueSignedIn() }
                    .disabled(flow.activity == .settingUp)
            }
        }
        // While the code is entered the number pad covers the bottom bar: Not Now moves up beside Back.
        .toolbar {
            if enteringCode {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Not Now") { flow.finish() }
                        .disabled(flow.isSigningIn)
                }
            }
        }
        .onChange(of: flow.challenge) { _, new in focus = new == nil ? nil : .code }
    }

    private var signInChoices: some View {
        VStack(spacing: 12) {
            ForEach(flow.socialProviders) { provider in
                Button { social(provider) } label: {
                    HStack(spacing: 8) {
                        if flow.activity == .social(provider.name) {
                            ProgressView().tint(provider == .apple ? Color(.systemBackground) : nil)
                        } else {
                            ProviderMark(provider: provider)
                        }
                        Text("Continue with \(provider.name)")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 30)
                }
                .modifier(SocialStyle(apple: provider == .apple))
                .disabled(!flow.isAccountReady || flow.activity != nil)
            }
            HStack(spacing: 10) {
                VStack { Divider() }
                Text("or").font(.subheadline).foregroundStyle(.secondary)
                VStack { Divider() }
            }
            .padding(.vertical, 4)
            .accessibilityHidden(true)
            PairLayout {
                TextField("Email address", text: Bindable(flow).email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .focused($focus, equals: .email)
                    .onSubmit { flow.sendCode() }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 50)
                    .background(Color(.secondarySystemBackground), in: .capsule)
                    .accessibilityLabel("Email address")
                Button { flow.sendCode() } label: {
                    ZStack {
                        Text("Send Code").opacity(flow.activity == .sendingCode ? 0 : 1)
                        if flow.activity == .sendingCode { ProgressView() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 30)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(!flow.canSendCode)
                .accessibilityLabel("Send Code")
            }
        }
    }

    private func codeEntry(_ challenge: ClerkEmailChallenge) -> some View {
        VStack(spacing: 14) {
            VStack(spacing: 2) {
                Text("Enter the 6-digit code sent to")
                    .foregroundStyle(.secondary)
                // The address on a line of its own, never hyphenated; shortened in the middle when it doesn't fit.
                Text(verbatim: challenge.email)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.middle)
            }
            .font(.body)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            TextField("Code", text: Bindable(flow).code, prompt: Text("6-digit code").font(.title3))
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(.title, design: .rounded, weight: .semibold).monospacedDigit())
                .multilineTextAlignment(.center)
                .focused($focus, equals: .code)
                .frame(minHeight: 60)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .trailing) {
                    if flow.activity == .verifying || flow.activity == .settingUp {
                        ProgressView().padding(.trailing, 18)
                            .accessibilityLabel(flow.activity == .verifying ? "Checking the code" : "Setting up sync")
                    }
                }
                .onChange(of: flow.code) { _, new in if new.count == 6 { flow.verify() } }
                .accessibilityLabel("6-digit code")
                .onAppear { focus = .code }
            if let error = flow.syncError {
                WarningText(error).font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 22) { codeLinks }
                VStack(spacing: 10) { codeLinks }
            }
            .font(.subheadline.weight(.semibold))
        }
    }

    @ViewBuilder private var codeLinks: some View {
        Button("Change Email") { flow.changeEmail() }
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let wait = flow.resendWait(now: context.date)
            Button(wait > 0 ? "Resend Code in \(wait) s" : "Resend Code") { flow.sendCode() }
                .disabled(wait > 0 || flow.activity != nil)
        }
    }

    private func signedIn(_ user: ClerkUser) -> some View {
        VStack(spacing: 10) {
            DoneLabel(text: "Signed in as \(user.email ?? user.displayName)")
                .font(.body.weight(.medium))
            if flow.activity == .settingUp {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Setting up sync on this iPhone…").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else if let problem = flow.connectProblem {
                WarningText("Signed in, but this iPhone can't sync yet: \(problem) It keeps trying; Settings › Account shows how it's going.")
                    .font(.subheadline)
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
        .font(.subheadline.weight(.medium))
        .frame(minHeight: 44)
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

private struct PrivacyNote: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "lock.fill").accessibilityHidden(true)
            Text("\(ProductInfo.name)'s server sees when you play and pause, never what you play. Songs, queues and searches are encrypted on your devices.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct ProviderMark: View {
    let provider: ClerkOAuthProvider
    var body: some View {
        Group {
            if provider == .apple {
                Image(systemName: "apple.logo")
            } else {
                Text(verbatim: "G")
                    .font(.system(.headline, design: .rounded, weight: .heavy))
                    .foregroundStyle(AngularGradient(colors: [.red, .yellow, .green, .blue, .red], center: .center))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Continue with Apple as Apple draws it (black, white in dark mode); Continue with Google as a glass button.
private struct SocialStyle: ViewModifier {
    let apple: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if apple {
            content
                .buttonStyle(.glassProminent)
                .tint(scheme == .dark ? .white : .black)
                .foregroundStyle(scheme == .dark ? .black : .white)
                .controlSize(.large)
                .modifier(LargeTextShape())
        } else {
            content
                .buttonStyle(.glass)
                .controlSize(.large)
                .modifier(LargeTextShape())
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
            VStack(alignment: .leading, spacing: 14) {
                TextField("Server address", text: Bindable(flow).serverText, prompt: Text(verbatim: "https://your-deployment.convex.cloud"))
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($focused)
                    .onSubmit { flow.checkServer() }
                    .onChange(of: flow.serverText) { flow.serverTextDidChange() }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 50)
                    .background(Color(.secondarySystemBackground), in: .capsule)
                    .accessibilityLabel("Server address")
                result
                Text("Already have a server? Enter its address above.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Set up an \(ProductInfo.name) server") { flow.showsServerGuide = true }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
        } actions: {
            if case .reachable(let url) = flow.serverCheck {
                PrimaryButton(title: "Use This Server", busy: flow.activity == .switchingServer) { flow.useServer(url) }
                    .disabled(flow.activity == .switchingServer)
            } else {
                PrimaryButton(title: "Check Server", busy: isChecking) { flow.checkServer() }
                    .disabled(flow.serverText.trimmingCharacters(in: .whitespaces).isEmpty || isChecking)
            }
            if model.sync?.account.server.isCustom == true {
                SecondaryButton(title: "Use \(ProductInfo.name)'s Server") { flow.useServer(nil) }
            }
        }
        .sheet(isPresented: Bindable(flow).showsServerGuide) { ServerGuide() }
    }

    private var isChecking: Bool { if case .checking = flow.serverCheck { true } else { false } }

    @ViewBuilder private var result: some View {
        switch flow.serverCheck {
        case .idle:
            EmptyView()
        case .checking(let host):
            HStack(spacing: 8) {
                ProgressView()
                Text("Checking \(host)…").foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .accessibilityElement(children: .combine)
        case .reachable(let url):
            VStack(alignment: .leading, spacing: 3) {
                DoneLabel(text: "Reachable and set up").font(.body.weight(.semibold))
                Text("\(url.host ?? url.absoluteString) runs the \(ProductInfo.name) server with sign-in on. Use This Server signs this iPhone in there.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        case .failed(let message):
            WarningText(message).font(.subheadline)
        }
    }
}

// MARK: - 4. Approve this device

private struct ApproveStep: View {
    let flow: FirstRunFlow
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let service = model.sync?.service
        let status = service?.keyStatus ?? .none
        let holders = service?.keyHolders ?? []
        FirstRunPage(symbol: status == .available ? "checkmark.shield" : "lock.shield",
                     title: status == .available ? "This iPhone is approved"
                        : typeSize.isAccessibilitySize ? "Approve this iPhone" : FirstRun.approveTitle(holders: holders, here: "this iPhone"),
                     subtitle: status == .available
                        ? "Your sign-ins and settings now sync to this iPhone."
                        : "Your YouTube Music and Spotify sign-ins are encrypted with a key only your devices hold. Approving shares it with this iPhone.",
                     escape: status == .available ? nil : ("Do This Later", { flow.doThisLater() }),
                     explanation: comparisonText(status)) {
            VStack(spacing: 16) {
                if typeSize.isAccessibilitySize, status != .available {
                    // The long title's instruction, kept at the top when the title is the short one.
                    Text("Open \(ProductInfo.name) on \(FirstRun.deviceNoun(Set(holders.map(\.platform)).count == 1 ? holders.first?.platform : nil)).")
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                content(status, holder: holders.first?.name ?? "your other device")
                if let error = flow.syncError { WarningText(error).font(.subheadline) }
            }
        } actions: {
            actions(status)
        }
        .navigationBarBackButtonHidden()
        .task(id: status == .available) { if status == .available { await flow.approved() } }
    }

    @ViewBuilder private func content(_ status: SyncService.KeyStatus, holder: String) -> some View {
        switch status {
        case .comparing(let comparison):
            CodeCard(code: comparison.code)
            if comparison.confirmed {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(comparison.allowed ? "Taking your sign-ins…" : "Waiting for \(comparison.holderName)…").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        case .available:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
        case .denied:
            WarningText("\(holder) didn't allow this iPhone. Ask again, or sign in to YouTube Music and Spotify here.", symbol: "key.slash")
        case .failed(let message):
            WarningText(message)
        case .outdated:
            WarningText("Your sign-ins changed while this iPhone was away. Ask again, then compare the code.", symbol: "key.slash")
        default:
            CodeCard(code: nil)
            HStack(spacing: 8) {
                ProgressView()
                Text("Waiting for \(holder)…").foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Text("Open \(ProductInfo.name) on \(holder). It asks to approve this iPhone and shows the same code.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What to do with the code: under it, or after the buttons at accessibility sizes.
    private func comparisonText(_ status: SyncService.KeyStatus) -> String? {
        guard case .comparing(let comparison) = status else { return nil }
        return comparison.confirmed && !comparison.allowed
            ? "Now tap Allow on \(comparison.holderName)."
            : comparison.allowed
                ? "\(comparison.holderName) allowed this iPhone. Tap Codes Match if it showed this same code."
                : "\(comparison.holderName) shows a code too. If it's the same, tap Allow there and Codes Match here."
    }

    @ViewBuilder private func actions(_ status: SyncService.KeyStatus) -> some View {
        switch status {
        case .comparing(let comparison) where !comparison.confirmed:
            PrimaryButton(title: "Codes Match") { flow.codesMatch() }
            Button { flow.codesDontMatch() } label: {
                Text("Codes Don't Match").font(.headline).frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        case .denied, .failed, .outdated:
            PrimaryButton(title: "Ask Again", busy: flow.askingAgain) { flow.askAgain() }
                .disabled(flow.askingAgain)
        default:
            EmptyView()
        }
    }
}

private struct CodeCard: View {
    let code: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 4) {
            // The caption gives its room to the digits at accessibility sizes; VoiceOver still says "Code".
            if !typeSize.isAccessibilitySize {
                Text("Code")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(code.map(FirstRun.spacedCode) ?? "––– –––")
                .font(.system(size: 52, weight: .semibold, design: .rounded).monospacedDigit())
                .tracking(3)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(code == nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.primary))
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(code.map { "Code \(FirstRun.spokenCode($0))" } ?? "No code yet")
    }
}

// MARK: - Approve later

/// Above the mini player after Do This Later, until this iPhone is approved: opens Settings › Account.
struct ApprovalBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let hub = model.sync {
            let holders = hub.service.keyHolders
            let noun = FirstRun.deviceNoun(Set(holders.map(\.platform)).count == 1 ? holders.first?.platform : nil)
            HStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Approve this iPhone").font(.subheadline.weight(.semibold))
                    Text("Open \(ProductInfo.name) on \(noun)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Approve") { open() }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.glass)
                Button { hub.closeApprovalBanner() } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            .background(Color(.systemBackground).opacity(0.72), in: .rect(cornerRadius: 20))
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            .accessibilityElement(children: .contain)
        }
    }

    private func open() {
        model.settingsPath = [.sync]
        model.isSettingsPresented = true
    }
}

/// "Set up an OpenMusic server": the self-hosting guide in four steps.
private struct ServerGuide: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Your own server keeps sync on a machine you control.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(FirstRun.serverSetupSteps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.subheadline.weight(.bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(Color.accentColor))
                                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(step.title).font(.headline)
                                Text(step.detail)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Step \(index + 1), \(step.title). \(step.detail)")
                        }
                    }
                    Text(FirstRun.serverSetupFooter)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
            }
            .navigationTitle("Set up an \(ProductInfo.name) server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}
