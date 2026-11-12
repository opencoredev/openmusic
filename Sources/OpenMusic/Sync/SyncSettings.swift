import AppKit
import OpenMusicCore
import OpenMusicSync
import SwiftUI

// MARK: - Settings › Account

/// The OpenMusic account: who is signed in, the server, this Mac and your other devices, the sign-in key, Sign Out.
struct AccountSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let hub = model.sync {
                @Bindable var hub = hub
                Group {
                    if let user = hub.account.user {
                        SignedInForm(hub: hub, user: user)
                    } else {
                        SignedOutForm(hub: hub)
                    }
                }
                .sheet(isPresented: $hub.isSignInPresented) { SignInSheet(hub: hub) }
                .sheet(isPresented: $hub.isServerPresented) { ServerSheet(hub: hub) }
                .animation(.smooth, value: hub.account.isSignedIn)
                // Signed-out and signed-in forms keep one height while their content changes (a code being
                // compared, a device joining), so the window doesn't jump under the pointer.
                .frame(minHeight: 460)
            } else {
                // One line: the pane is as tall as it, like the other panes, not a 460 pt window around it.
                Form {
                    Label("Your account is off while \(ProductInfo.name) runs with sample data.", systemImage: "flask")
                        .foregroundStyle(.readableSecondary)
                }
                .formStyle(.grouped)
                .modifier(FitsContent())
            }
        }
    }
}

/// Not signed in: what an account does, Sign In, and the server.
private struct SignedOutForm: View {
    let hub: SyncHub

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    SyncGlyph(size: 64)
                    Text("Listen Across Your Devices")
                        .font(.title3.weight(.semibold))
                    Text("Sign in on your Mac and iPhone to pick up on one what the other is playing, control one from the other, and keep sign-ins and settings the same on both.")
                        .font(.callout)
                        .foregroundStyle(.readableSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Sign In…") { hub.isSignInPresented = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding(.top, 6)
                        .disabled(hub.account.serverProblem != nil)
                    if let problem = hub.account.serverProblem {
                        WarningLabel(problem).font(.callout)
                        Button("Try Again") { Task { await hub.account.retry() } }
                    }
                    if let notice = hub.account.notice { WarningLabel(notice).font(.callout) }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            ServerSection(hub: hub)
        }
        .formStyle(.grouped)
    }
}

private struct ServerSection: View {
    let hub: SyncHub

    var body: some View {
        Section {
            LabeledContent {
                Button(hub.account.server.isCustom ? "Change…" : "Use Your Own…") { hub.isServerPresented = true }
            } label: {
                Text("Server")
                Text(hub.account.server.isCustom ? hub.account.server.displayName : "\(ProductInfo.name)")
            }
        } header: {
            Text("Advanced")
        }
    }
}

/// Signed in: the account, the sign-in key, this Mac, the other devices, the server and Sign Out.
private struct SignedInForm: View {
    let hub: SyncHub
    let user: ClerkUser
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var confirmSignOut = false
    @State private var removing: SyncDevice?
    @State private var error: String?

    var body: some View {
        let service = hub.service
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(.readableSecondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.displayName).font(.headline)
                            if let email = user.email, email != user.displayName {
                                Text(email).foregroundStyle(.readableSecondary)
                            }
                        }
                        Spacer()
                        Button("Sign Out…") { confirmSignOut = true }
                    }
                    .padding(.vertical, 2)
                    if let failure = hub.connectFailure {
                        WarningLabel(failure).font(.callout)
                    }
                }
                KeyStatusSection(hub: hub)
                Section("This Mac") {
                    TextField("Name", text: $name)
                        .onSubmit { hub.setDeviceName(name) }
                    LabeledContent("Status") { ConnectionDot(status: service.connection) }
                }
                Section {
                    ForEach(service.otherDevices) { device in
                        DeviceListRow(device: device, hub: hub) { removing = device }
                            .contextMenu {
                                Button("Remove…", role: .destructive) { removing = device }
                            }
                    }
                    if service.otherDevices.isEmpty {
                        Text("Sign in on your iPhone with the same account and it shows up here.")
                            .foregroundStyle(.readableSecondary)
                    }
                } header: {
                    Text("Your Devices")
                }
                Section {
                    ForEach(model.providers, id: \.id) { provider in
                        LabeledContent {
                            Text(SignInSyncText.status(service.signIns.status[provider.id], keyStatus: service.keyStatus))
                                .foregroundStyle(.readableSecondary)
                        } label: {
                            HStack(spacing: 8) {
                                ServiceLogo(provider: provider.id, size: 18)
                                Text(provider.id.displayName)
                            }
                        }
                    }
                } header: {
                    Text("Sign-ins")
                } footer: {
                    Text("Sign in to a service once and every device is signed in. Sign-ins are end-to-end encrypted with a key only your devices hold; the server can't read them.")
                        .font(.caption).foregroundStyle(.readableSecondary)
                }
                if let error {
                    Section { WarningLabel(error) }
                }
                ServerSection(hub: hub)
            }
            .formStyle(.grouped)
        }
        .onAppear { name = service.selfDevice?.name ?? service.deviceInfo.name }
        .onChange(of: service.selfDevice?.name) { _, new in if let new { name = new } }
        .confirmationDialog("Sign out of \(ProductInfo.name) on this Mac?", isPresented: $confirmSignOut) {
            Button("Sign Out") { Task { await hub.signOutOfAccount() } }
        } message: {
            Text("This Mac stops syncing and is removed from your devices. It stays signed in to YouTube Music and Spotify.")
        }
        .confirmationDialog("Remove \(removing?.name ?? "this device")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { device in
            Button("Remove", role: .destructive) {
                Task {
                    do { try await service.remove(device.id) } catch { self.error = error.localizedDescription }
                }
            }
        } message: { device in
            Text("\(device.name) is signed out of \(ProductInfo.name) and stops syncing. It can sign in again.")
        }
    }
}

/// Whether this Mac can use the account's YouTube Music and Spotify sign-ins, and what to do when it can't.
private struct KeyStatusSection: View {
    let hub: SyncHub
    @State private var asking = false

    var body: some View {
        let service = hub.service
        switch service.keyStatus {
        case .waiting:
            Section {
                KeyCard(symbol: "key.horizontal", title: "Waiting for your other device", text: waitingText(service), code: nil)
            }
        case .comparing(let comparison):
            Section {
                KeyCard(symbol: comparison.allowed ? "checkmark.shield" : "number.square", title: comparison.title(here: "this Mac"),
                        text: comparison.instructions(here: "this Mac"), code: comparison.code) {
                    if !comparison.confirmed {
                        HStack(spacing: 8) {
                            Button("Codes Match") { service.confirmKeyCode() }
                                .buttonStyle(.borderedProminent)
                            Button("Codes Don't Match") { service.rejectKeyCode() }
                        }
                        .padding(.top, 2)
                    }
                }
            }
        case .denied:
            Section {
                KeyCard(symbol: "key.slash", title: "Your sign-ins weren't shared with this Mac",
                        text: "Sign in to YouTube Music and Spotify here, or ask again.", code: nil) { askAgain(service) }
            }
        case .failed(let message):
            Section {
                KeyCard(symbol: "exclamationmark.triangle", title: "Your sign-ins weren't shared with this Mac", text: message, code: nil) {
                    askAgain(service)
                }
            }
        case .mismatch:
            Section {
                KeyCard(symbol: "key.slash", title: "This Mac's sign-in key isn't your account's",
                        text: "Sign out of \(ProductInfo.name) and sign in again to fix it.", code: nil)
            }
        case .outdated:
            Section {
                KeyCard(symbol: "key.slash", title: "Your sign-ins changed while this Mac was away",
                        text: outdatedText(service, here: "this Mac"), code: nil) { askAgain(service) }
            }
        case .none, .available:
            if let warning = service.keyWarning {
                Section { WarningLabel(warning).font(.callout) }
            }
        }
    }

    private func askAgain(_ service: SyncService) -> some View {
        Button("Ask Again") {
            asking = true
            Task { try? await service.requestKeyAgain(); asking = false }
        }
        .disabled(asking)
    }

    private func outdatedText(_ service: SyncService, here: String) -> String {
        let place = service.keyHolders.first?.name ?? "your other device"
        return "Your account replaced the key for its YouTube Music and Spotify sign-ins, and \(here) missed it. Ask again, then compare the code with \(place)."
    }

    private func waitingText(_ service: SyncService) -> String {
        let holders = service.keyHolders.map(\.name)
        guard let first = holders.first else {
            return "Playback and settings already sync. To use your YouTube Music and Spotify sign-ins here, sign in to them on this Mac."
        }
        let place = holders.count == 1 ? first : "\(first) or another of your devices"
        return "Playback and settings already sync. Open \(ProductInfo.name) on \(place) and allow this Mac to use your YouTube Music and Spotify sign-ins, or sign in to them here."
    }
}

private struct KeyCard<Actions: View>: View {
    let symbol: String
    let title: String
    let text: String
    let code: String?
    @ViewBuilder var actions: Actions

    init(symbol: String, title: String, text: String, code: String?, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.symbol = symbol
        self.title = title
        self.text = text
        self.code = code
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(.tint)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.readableSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let code {
                    LabeledContent("Code") {
                        Text(code).font(.title2.monospacedDigit().weight(.bold)).foregroundStyle(.primary).textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
                actions
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SyncGlyph: View {
    var size: CGFloat = 64
    var symbol: String? = nil

    var body: some View {
        Image(systemName: symbol ?? "laptopcomputer.and.iphone")
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(.tint)
            .frame(width: size, height: size)
            .modifier(GlyphGlass())
            .accessibilityHidden(true)
    }
}

private struct GlyphGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(.accentColor.opacity(0.12)), in: .circle)
        } else {
            content.background(Circle().fill(Color.accentColor.opacity(0.12)))
        }
    }
}

private struct DeviceListRow: View {
    let device: SyncDevice
    let hub: SyncHub
    let remove: () -> Void

    var body: some View {
        let service = hub.service
        let online = service.isOnline(device)
        let row = service.playback[device.id]
        let playing = row.map { hub.coordinator.effectiveAnchor($0).isPlaying } ?? false
        HStack(spacing: 10) {
            Image(systemName: DeviceGlyph.symbol(device))
                .font(.system(size: 16))
                .foregroundStyle(online ? .primary : .secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(device.name)
                    Circle().fill(online ? Color.green : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                        .accessibilityLabel(online ? "Online" : "Offline")
                }
                Text(detail(row: row, playing: playing, online: online))
                    .font(.caption).foregroundStyle(.readableSecondary).lineLimit(1)
            }
            Spacer()
            if wantsKey {
                Button("Allow…") { hub.dismissedKeyRequests.show(device.id) }
                    .help("Let \(device.name) use your YouTube Music and Spotify sign-ins")
            }
            Button("Remove…", action: remove)
                .buttonStyle(.borderless)
                .foregroundStyle(.readableSecondary)
                .accessibilityLabel("Remove \(device.name)")
        }
    }

    /// This Mac has the sign-in key and the device asks for it.
    private var wantsKey: Bool { hub.service.keyRequests.contains { $0.id == device.id } }

    private func detail(row: RemotePlayback?, playing: Bool, online: Bool) -> String {
        if wantsKey { return "Asking to use your sign-ins" }
        let seen = hub.service.clock.localDate(device.lastSeenAt).formatted(.relative(presentation: .named))
        if let row {
            guard let what = row.trackLine else {
                return playing ? "Playing on \(device.name)" : (online ? "Paused" : "Offline · seen \(seen)")
            }
            return playing ? "Playing \(what)" : (online ? "Paused · \(what)" : "Offline · seen \(seen)")
        }
        return online ? "Online" : "Offline · seen \(seen)"
    }
}

enum SignInSyncText {
    static func status(_ status: SignInSync.Status?, keyStatus: SyncService.KeyStatus) -> String {
        switch keyStatus {
        case .waiting, .comparing, .denied, .failed: return "Not shared with this Mac"
        case .mismatch, .outdated: return "Needs key"
        case .none, .available: break
        }
        switch status {
        case nil, .unavailable?, .waiting?: return "Checking…"
        case .needsKey?: return "Not shared with this Mac"
        case .notSignedIn?: return "Not signed in"
        case .synced?: return "Synced"
        case .signedOutHere?: return "Signed out on this Mac"
        case .signedOutEverywhere?: return "Signed out everywhere"
        case .failed?: return "Couldn't sync"
        }
    }

    /// A sentence under the account in Settings › Services.
    static func footer(_ status: SignInSync.Status?) -> String? {
        switch status {
        case .synced?: "This sign-in syncs to your other devices."
        case .signedOutHere?: "Signed out on this Mac only. Your other devices are still signed in; sign in here to sync again."
        case .signedOutEverywhere?: "Signed out on all your devices."
        case .needsKey?: "Allow this Mac on a device that has your sign-ins to sync it (Settings › Account)."
        case .failed(let message)?: message
        default: nil
        }
    }
}

// MARK: - Services (YouTube Music, Spotify)

/// Settings › Services' Sign Out, sync-aware: asks "this Mac or all devices" when sign-ins sync. `error` gets the
/// message when the saved sign-in couldn't be removed (the Accounts pane shows it).
struct SyncAwareSignOutButton: View {
    let provider: any MusicProvider
    @Binding var error: String?
    @Environment(AppModel.self) private var model

    var body: some View {
        let id = provider.id
        let asking = Binding(get: { model.sync?.signOutPrompt == id }, set: { if !$0 { model.sync?.signOutPrompt = nil } })
        Button("Sign Out") {
            Task {
                if let hub = model.sync {
                    error = await hub.signOutTapped(id)
                } else {
                    do { try await provider.trySignOut() } catch { self.error = error.localizedDescription }
                }
            }
        }
        // The standard dialog. "All Devices" has no destructive role on purpose: macOS 26 draws a destructive alert
        // button as red text on a red tint, measured at 1.5:1 (light) and 2.8:1 (dark). The caution symbol of the
        // critical severity marks the dialog instead, and every label stays readable (7.6:1 and 9.9:1).
        .confirmationDialog("Sign out of \(id.displayName)?", isPresented: asking) {
            Button("Sign Out on This Mac") { signOut(everywhere: false) }
            Button("Sign Out on All Devices") { signOut(everywhere: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Signing out on this Mac keeps your other devices signed in. Signing out on all devices signs out your iPhone too.")
        }
        .dialogSeverity(.critical)
    }

    private func signOut(everywhere: Bool) {
        Task { error = await model.sync?.signOut(provider.id, everywhere: everywhere) }
    }
}

/// Under the account: whether this sign-in syncs.
struct SignInSyncFooter: View {
    let id: ProviderID
    @Environment(AppModel.self) private var model

    var body: some View {
        if let hub = model.sync, hub.service.isRegistered, let text = SignInSyncText.footer(hub.service.signIns.status[id]) {
            Label(text, systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.readableSecondary)
        }
    }
}

/// A warning that stays readable on light backgrounds: the icon in orange, the words in the primary color.
struct WarningLabel: View {
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
        .fixedSize(horizontal: false, vertical: true)
    }
}
