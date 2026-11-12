#if os(macOS)
import AppKit
#else
import UIKit
#endif
import OpenMusicCore
import SwiftUI

#if os(macOS)
/// Neutral tint for Spotify's buttons, so they never pick up the app's accent (or the red the system accent can be).
private let neutralTint = Color(nsColor: .systemGray)

/// What playing music needs, shown wherever the listener signs in.
private let playbackNote = "To play music you need Spotify Premium (to play through Spotify Connect) or the Spotify app on this Mac."
private let signInDetail = "Sign in with your Spotify account in your browser."
private let waitingText = "Waiting for your browser…"
#else
private let neutralTint = Color(uiColor: .systemGray)
private let playbackNote = "\(ProductInfo.name) plays Spotify through Spotify Connect: it needs Premium and Spotify open on a device, such as this iPhone or a speaker."
private let signInDetail = "Sign in with your Spotify account."
private let waitingText = "Waiting for Spotify…"
#endif

// MARK: Sign-in sheet

struct SpotifySignInView: View {
    @Bindable var provider: SpotifyProvider
    let onFinish: @MainActor () -> Void

    var body: some View {
        SpotifySignInContent(
            status: provider.authStatus,
            needsClientID: !provider.canSignIn,
            signIn: {
                Task {
                    await provider.signIn()
                    if provider.authStatus.isSignedIn { onFinish() }
                }
            },
            cancel: {
                provider.cancelSignIn()
                onFinish()
            }
        )
    }
}

/// The sheet's layout, driven by plain values so every state can be rendered on its own.
struct SpotifySignInContent: View {
    let status: AuthStatus
    let needsClientID: Bool
    let signIn: () -> Void
    let cancel: () -> Void

    private var isWaiting: Bool { status == .signingIn }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign In to Spotify")
                .font(.title2.weight(.semibold))
            Text(signInDetail)
                .fixedSize(horizontal: false, vertical: true)
            Text(playbackNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if needsClientID {
                Notice("You chose to use your own Client ID. Paste it in Settings › Spotify › Advanced, or turn that option off.")
            } else if case .failed(let message) = status {
                Notice(message)
            }

            HStack(spacing: 8) {
                if isWaiting {
                    ProgressView().controlSize(.small)
                    Text(waitingText)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                if !isWaiting {
                    Button("Sign In", action: signIn)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(needsClientID)
                }
            }
            .padding(.top, 8)
        }
        .tint(neutralTint)
        .padding(20)
        #if os(macOS)
        .frame(width: 420)
        #else
        .frame(maxWidth: .infinity, alignment: .leading)
        #endif
    }
}

/// A short problem message. Yellow system warning symbol, normal text: no red.
private struct Notice: View {
    let message: String
    init(_ message: String) { self.message = message }

    var body: some View {
        Label {
            Text(message).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
        }
        .font(.callout)
    }
}

// MARK: Settings

/// Spotify's sections in Settings > Accounts. The Accounts pane shows the account row and owns
/// Connect / Sign Out, so this adds only plain `Section`s to its form.
struct SpotifySettingsView: View {
    @Bindable var provider: SpotifyProvider

    var body: some View {
        SpotifyPlaybackSection(engine: provider.engine, isSignedIn: provider.authStatus.isSignedIn)

        Section {
            Text(playbackNote)
                .font(.callout)
                .foregroundStyle(.readableSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Lyrics come from LRCLIB (lrclib.net).")
                .font(.callout)
                .foregroundStyle(.readableSecondary)
        }

        SpotifyAdvancedSection(provider: provider)
    }
}

/// "Use my own Client ID", folded away. The default sign-in needs none of it.
struct SpotifyAdvancedSection: View {
    @Bindable var provider: SpotifyProvider
    @State private var isExpanded: Bool

    init(provider: SpotifyProvider, isExpanded: Bool = false) {
        self.provider = provider
        _isExpanded = State(initialValue: isExpanded)
    }

    var body: some View {
        Section {
            DisclosureGroup("Advanced", isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Use my own Client ID", isOn: $provider.usesOwnClientID)
                    Text(provider.usesOwnClientID
                         ? "\(ProductInfo.name) signs in through your Spotify developer app. Takes effect the next time you sign in."
                         : "\(ProductInfo.name) signs in through Spotify's own desktop client. If Spotify starts refusing it, set up a free developer app and use its Client ID here.")
                        .font(.callout)
                        .foregroundStyle(.readableSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if provider.usesOwnClientID {
                        SpotifySetupSteps(provider: provider)
                            .padding(.top, 4)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .tint(neutralTint)
    }
}

/// Setup steps for the listener's own Spotify app, with the exact redirect URI to register.
struct SpotifySetupSteps: View {
    @Bindable var provider: SpotifyProvider
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            step(1) {
                HStack(spacing: 4) {
                    Text("Open the")
                    Link("Spotify Developer Dashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                    Text("and click Create app.")
                }
            }
            step(2) { Text("Give it any name and description, and tick **Web API**.") }
            step(3) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add this Redirect URI exactly, then save:")
                    HStack {
                        Text(provider.redirectURI)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        Button(copied ? "Copied" : "Copy") {
                            #if os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(provider.redirectURI, forType: .string)
                            #else
                            UIPasteboard.general.string = provider.redirectURI
                            #endif
                            copied = true
                        }
                        .controlSize(.small)
                    }
                }
            }
            step(4) { Text("Open the app's **Settings**, copy its **Client ID**, and paste it below.") }
            LabeledContent("Client ID") {
                TextField("Client ID", text: $provider.clientID, prompt: Text("32-character Client ID"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: 300)
            }
            Picker("Redirect", selection: $provider.redirect) {
                ForEach(SpotifyRedirect.allCases) { Text($0.label).tag($0) }
            }
            Text("Development-mode apps work only if the app owner has **Premium**, for up to 5 accounts. To add another account, list its email under **User Management** in the dashboard.")
                .font(.callout)
                .foregroundStyle(.readableSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: provider.redirect) { copied = false }
    }

    private func step<Content: View>(_ n: Int, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(.readableSecondary)
                .frame(width: 16, alignment: .trailing)
            content()
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SpotifyPlaybackSection: View {
    @Bindable var engine: SpotifyPlaybackEngine
    let isSignedIn: Bool
    @State private var isRefreshingDevices = false

    var body: some View {
        Section {
            #if os(macOS)
            Picker("Play through", selection: $engine.preference) {
                ForEach(SpotifyPlaybackEngine.RoutePreference.allCases) { Text($0.label).tag($0) }
            }
            LabeledContent("Spotify app") {
                Text(SpotifyAppBridge.isInstalled ? "Installed" : "Not installed")
                    .foregroundStyle(.readableSecondary)
            }
            #endif
            if engine.preference != .thisMac {
                HStack {
                    Picker("Connect device", selection: $engine.connectDeviceID) {
                        Text("Active device").tag(String?.none)
                        ForEach(engine.devices) { device in
                            Text(device.isActive ? "\(device.name) (active)" : device.name).tag(Optional(device.id))
                        }
                    }
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh devices")
                    .disabled(!isSignedIn || isRefreshingDevices)
                }
                Text("Spotify Connect needs Premium and a device with Spotify open.")
                    .font(.callout)
                    .foregroundStyle(.readableSecondary)
            }
            if let error = engine.lastError {
                Notice(error)
            }
        } header: {
            // "Spotify" over "Playback" in Settings › Accounts; "Playback" alone elsewhere.
            ProviderSettingsHeader("Playback")
        }
        .task {
            if isSignedIn, engine.preference != .thisMac { await refresh() }
        }
    }

    private func refresh() async {
        isRefreshingDevices = true
        await engine.refreshDevices()
        isRefreshingDevices = false
    }
}

// MARK: Snapshots

/// Every state of the Spotify sign-in sheet and settings, for `openmusic-probe spotify render-views`.
@MainActor
public enum SpotifyViewSnapshots {
    public static func signInStates() -> [(name: String, view: AnyView)] {
        func content(_ status: AuthStatus, needsClientID: Bool = false) -> AnyView {
            AnyView(SpotifySignInContent(status: status, needsClientID: needsClientID, signIn: {}, cancel: {}))
        }
        return [
            ("signin-default", content(.signedOut)),
            ("signin-waiting", content(.signingIn)),
            ("signin-failed", content(.failed(SpotifyAuthError.portInUse(SpotifyRedirect.loopbackPort).localizedDescription))),
            ("signin-needs-client-id", content(.signedOut, needsClientID: true)),
        ]
    }

    /// Settings sections in a grouped form: Advanced folded (the default), and unfolded with "own Client ID" on.
    /// Uses throwaway providers, so nothing is read from or written to the real settings or Keychain.
    public static func settingsStates() -> [(name: String, view: AnyView)] {
        func form(ownClientID: Bool) -> AnyView {
            let suite = UserDefaults(suiteName: "openmusic.snapshots.\(UUID().uuidString)")!
            let provider = SpotifyProvider(defaults: suite, transport: URLSessionTransport(), tokenStore: MemoryTokenStore())
            provider.usesOwnClientID = ownClientID
            return AnyView(Form {
                SpotifyPlaybackSection(engine: provider.engine, isSignedIn: false)
                SpotifyAdvancedSection(provider: provider, isExpanded: ownClientID)
            }.formStyle(.grouped))
        }
        return [("settings-default", form(ownClientID: false)), ("settings-advanced", form(ownClientID: true))]
    }
}
