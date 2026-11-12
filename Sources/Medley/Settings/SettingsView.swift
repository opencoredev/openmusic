import MedleyCore
import SwiftUI

/// The Settings window's panes, in toolbar order. Adding one is a case here, its title and symbol, and its view in
/// `SettingsView.pane(_:)`. `AppModel.requestSettings(_:)` opens any pane directly.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, accounts, playback, sync

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .accounts: "Services"
        case .playback: "Playback"
        case .sync: "Account"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .accounts: "music.note.square.stack"
        case .playback: "play.circle"
        // Symbols with a .fill variant: the selected toolbar item draws the filled one (laptopcomputer.and.iphone
        // has none and showed as a blank tile).
        case .sync: "person.crop.circle"
        }
    }
}

struct SettingsView: View {
    typealias Tab = SettingsPane
    @Environment(AppModel.self) private var model
    @State private var tab: SettingsPane
    private let accountsProvider: ProviderID?

    init(tab: SettingsPane = .accounts, accountsProvider: ProviderID? = nil) {
        _tab = State(initialValue: tab)
        self.accountsProvider = accountsProvider
    }

    var body: some View {
        TabView(selection: $tab) {
            ForEach(SettingsPane.allCases) { pane in
                self.pane(pane)
                    .tabItem { Label(pane.title, systemImage: pane.symbol) }
                    .tag(pane)
            }
        }
        .frame(width: 560)
        // A request made before the window existed (Settings › Sync from the player bar or a menu) applies on appear.
        .onAppear { if let pane = model.takeSettingsRequest() { tab = pane } }
        .onChange(of: model.settingsRequest) { _, request in
            if request != nil, let pane = model.takeSettingsRequest() { tab = pane }
        }
    }

    @ViewBuilder private func pane(_ pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralSettings()
        case .accounts: AccountsSettings(initial: accountsProvider)
        case .playback: PlaybackSettingsPane()
        case .sync: AccountSettingsPane()
        }
    }
}

// MARK: - Accounts

/// Both services in one list, so their sign-in states show at once: an account row for each, then each signed-in
/// service's own settings under its name. One form for the whole pane, like the other panes (a control above the
/// form drew a toolbar divider the other panes don't have). This pane owns sign-in and sign-out; each provider's
/// settings view adds plain `Section`s to the same form.
struct AccountsSettings: View {
    @Environment(AppModel.self) private var model

    /// Kept for callers that open Accounts for one service; both services always show now.
    init(initial: ProviderID? = nil) {}

    var body: some View {
        let providers = model.providers
        Form {
            Section {
                ForEach(providers, id: \.id) { provider in
                    AccountRow(provider: provider)
                }
            } footer: {
                // Only when it has something to say: an empty footer still reserved its padding, which left a large
                // gap between the accounts and the first service's settings. (One section either way, so an account
                // row's state, such as an open sign-in sheet, survives the footer appearing.)
                if hasFooter(providers) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(providers.filter(\.capabilities.isEmpty), id: \.id) { provider in
                            Text("\(provider.id.displayName) support is still being built.")
                                .font(.caption)
                                .foregroundStyle(.readableSecondary)
                        }
                        ForEach(providers, id: \.id) { SignInSyncFooter(id: $0.id) }
                    }
                }
            }
            ForEach(providers, id: \.id) { provider in
                // The service's name heads its first section (`ProviderSettingsHeader`), so "Playback" or "Advanced"
                // says whose it is. An empty section of its own for the name left a double gap above it.
                provider.makeSettingsView()
                    .environment(\.providerSettingsTitle, provider.id.displayName)
            }
        }
        .formStyle(.grouped)
        .modifier(FitsContent())
    }

    /// Whether the accounts section's footer shows anything: a service still being built, or a sign-in sync note.
    private func hasFooter(_ providers: [any MusicProvider]) -> Bool {
        if providers.contains(where: \.capabilities.isEmpty) { return true }
        guard let hub = model.sync, hub.service.isRegistered else { return false }
        return providers.contains { SignInSyncText.footer(hub.service.signIns.status[$0.id]) != nil }
    }
}

/// One service's account: its picture with the service's logo, the name and plan (or "Not signed in"), and Sign In
/// or Sign Out.
private struct AccountRow: View {
    let provider: any MusicProvider
    @Environment(AppModel.self) private var model
    @State private var showSignIn = false
    /// Sign-out that couldn't delete the saved sign-in: the account stays signed in and this says why.
    @State private var signOutError: String?

    var body: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.id.displayName).font(.headline)
                status
            }
            Spacer()
            switch provider.authStatus {
            case .signedIn:
                // Asks "this Mac or all devices" when sign-ins sync; a failed local deletion shows the alert below.
                SyncAwareSignOutButton(provider: provider, error: $signOutError)
            case .signingIn:
                ProgressView().controlSize(.small)
            case .signedOut, .failed:
                Button("Sign In…") { showSignIn = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $showSignIn) {
            provider.makeSignInView { showSignIn = false }
        }
        .alert("Couldn't remove the saved sign-in", isPresented: Binding(get: { signOutError != nil }, set: { if !$0 { signOutError = nil } })) {
            Button("OK") {}
        } message: {
            Text("\(provider.id.displayName) is still signed in on this Mac. \(signOutError ?? "")")
        }
    }

    @ViewBuilder private var avatar: some View {
        ZStack(alignment: .bottomTrailing) {
            if case .signedIn(let info) = provider.authStatus, let url = info.avatar {
                ArtworkView(artwork: Artwork(url: url), size: 40, circle: true, symbol: "person.fill")
                    .frame(width: 40, height: 40)
            } else {
                Circle().fill(.quaternary)
                    .frame(width: 40, height: 40)
                    .overlay(Image(systemName: "person.fill").foregroundStyle(.tertiary))
            }
            // The one place brand color appears: a small logo on the account picture.
            ServiceLogo(provider: provider.id, size: 16)
                .background(Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 2))
                .offset(x: 2, y: 2)
        }
    }

    @ViewBuilder private var status: some View {
        switch provider.authStatus {
        case .signedIn(let info):
            Text([info.name, info.detail].compactMap(\.self).joined(separator: " · "))
                .font(.callout).foregroundStyle(.readableSecondary)
        case .signingIn:
            Text("Signing in…").font(.callout).foregroundStyle(.readableSecondary)
        case .signedOut:
            Text("Not signed in").font(.callout).foregroundStyle(.readableSecondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }
}

// MARK: - Playback

struct PlaybackSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.playback.settings
        let outputs = model.playback.outputs
        Form {
            Section {
                Toggle(isOn: $settings.autoplay) {
                    Text("Autoplay")
                    Text("When your queue ends, keep playing similar music.")
                        .foregroundStyle(.readableSecondary)
                }
            }
            // Medley's own audio engine plays YouTube Music only; Spotify plays through the Spotify app or a Connect
            // device, which keeps its own volume leveling, crossfade and output (the player's device button
            // shows Spotify's device while a Spotify song plays).
            Section {
                Toggle(isOn: $settings.normalizeVolume) {
                    Text("Sound Check")
                    Text("Play songs at the same volume level.")
                        .foregroundStyle(.readableSecondary)
                }
                LabeledContent("Crossfade") {
                    HStack {
                        Slider(value: $settings.crossfadeSeconds, in: MedleyCore.PlaybackSettings.crossfadeRange, step: 1) { Text("Crossfade") }
                            .labelsHidden()
                            .frame(width: 200)
                        Text(settings.crossfadeSeconds == 0 ? "Off" : "\(Int(settings.crossfadeSeconds)) s")
                            .monospacedDigit()
                            .foregroundStyle(.readableSecondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Picker("Output", selection: $settings.outputDeviceUID) {
                    Text("System Default").tag(String?.none)
                    ForEach(outputs.devices) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                }
            } header: {
                Text("YouTube Music Audio")
            } footer: {
                Text("These settings apply only to YouTube Music.")
                    .font(.caption)
                    .foregroundStyle(.readableSecondary)
            }
            Section {
                LabeledContent("YouTube Music") {
                    // The form's own value gray is the translucent `.secondary` (3.9:1 on the grouped fill).
                    Text("AAC, 128 kbps").foregroundStyle(.readableSecondary)
                }
            } header: {
                Text("Stream Quality")
            } footer: {
                Text("YouTube Music streams come straight from YouTube's servers. Lossless or 256 kbps audio isn't available to third-party players.")
                    .font(.caption)
                    .foregroundStyle(.readableSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .modifier(FitsContent())
    }
}

/// A Settings pane exactly as tall as its form, so the window has no empty space below the last section (the
/// window takes each pane's height as it's picked). The form doesn't scroll: every pane fits on any screen.
struct FitsContent: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var cleared = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Show music from", selection: $model.serviceFilter) {
                    ForEach(ServiceFilter.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                LabeledContent("Artwork and page cache") {
                    Button(cleared ? "Cleared" : "Clear Cache") {
                        ArtworkPipeline.shared.clearDisk()
                        BrowseDiskCache.removeAll()
                        cleared = true
                    }
                    .disabled(cleared)
                }
                LabeledContent("Recent searches") {
                    Button("Clear") { model.clearRecentSearches() }
                        .disabled(model.recentSearches.isEmpty)
                }
                LabeledContent("Welcome screen") {
                    Button("Show Again…") { model.showOnboarding = true }
                }
            }
            if model.isMock {
                Section {
                    Label("Running with sample data (MEDLEY_MOCK=1). Nothing is sent to any service.", systemImage: "flask")
                        .foregroundStyle(.readableSecondary)
                }
            }
        }
        .formStyle(.grouped)
        .modifier(FitsContent())
    }
}
