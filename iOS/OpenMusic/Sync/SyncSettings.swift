import OpenMusicCore
import OpenMusicSync
import SwiftUI

// MARK: - Settings row

/// The OpenMusic account row at the top of Settings.
struct AccountSettingsRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let hub = model.sync {
            NavigationLink(value: SettingsRoute.sync) {
                HStack(spacing: 12) {
                    Image(systemName: hub.account.isSignedIn ? "person.crop.circle.fill" : "laptopcomputer.and.iphone")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Color.accentColor.gradient, in: .rect(cornerRadius: 7))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hub.account.user?.displayName ?? "\(ProductInfo.name) Account")
                        Text(summary(hub)).font(.subheadline).foregroundStyle(.secondaryText).lineLimit(1)
                    }
                }
            }
        }
    }

    private func summary(_ hub: SyncHub) -> String {
        guard hub.account.isSignedIn else { return "Sign in to sync your devices" }
        let others = hub.service.otherDevices.count
        switch hub.service.keyStatus {
        case .waiting, .comparing, .denied, .failed, .outdated: return "Sign-ins aren't shared with this iPhone yet"
        default: return others == 0 ? "No other devices yet" : "Syncing with \(others) other device\(others == 1 ? "" : "s")"
        }
    }
}

enum SettingsRoute: Hashable {
    case sync
    case server
    case provider(ProviderID)
}

// MARK: - Settings › Account

struct AccountSettingsPage: View {
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
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.smooth, value: model.sync?.account.isSignedIn)
    }
}

/// Not signed in: what an account does, Sign In, and the server. Also the Devices sheet's content then.
struct SignedOutForm: View {
    let hub: SyncHub

    var body: some View {
        Form {
            Section {
                VStack(spacing: 14) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 88, height: 88)
                        .glassEffect(.regular.tint(.accentColor.opacity(0.15)), in: .circle)
                        .accessibilityHidden(true)
                    Text("Listen Across Your Devices")
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                    Text("Sign in on your iPhone and Mac to pick up on one what the other is playing, control one from the other, and keep sign-ins and settings the same on both.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button { hub.isSignInPresented = true } label: {
                        Text("Sign In").font(.body.weight(.semibold)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(hub.account.serverProblem != nil)
                    if let problem = hub.account.serverProblem {
                        WarningText(problem).font(.footnote)
                        Button("Try Again") { Task { await hub.account.retry() } }
                    }
                    if let notice = hub.account.notice { WarningText(notice).font(.footnote) }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            ServerSection(hub: hub)
        }
    }
}

private struct ServerSection: View {
    let hub: SyncHub

    var body: some View {
        Section {
            NavigationLink(value: SettingsRoute.server) {
                LabeledContent("Server", value: hub.account.server.isCustom ? hub.account.server.displayName : "\(ProductInfo.name)")
            }
        } header: {
            Text("Advanced")
        }
    }
}

/// Settings › Account › Server.
struct ServerSettingsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let hub = model.sync { ServerForm(hub: hub) { dismiss() } }
    }
}

/// Signed in: the account, the sign-in key, this iPhone, the other devices, sign-ins, the server and Sign Out.
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
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.displayName).font(.headline)
                            if let email = user.email, email != user.displayName {
                                Text(email).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    if let failure = hub.connectFailure { WarningText(failure).font(.subheadline) }
                }
                KeyStatusSection(hub: hub)
                Section {
                    TextField("Name", text: $name)
                        .submitLabel(.done)
                        .onSubmit { hub.setDeviceName(name) }
                        .accessibilityLabel("This iPhone's name")
                    ConnectionRow(status: service.connection)
                } header: {
                    Text("This iPhone")
                } footer: {
                    Text("Your other devices see this name.")
                }
                Section {
                    ForEach(service.otherDevices) { device in
                        DeviceListRow(device: device, hub: hub)
                            .swipeActions {
                                Button("Remove", systemImage: "trash", role: .destructive) { removing = device }
                            }
                            .contextMenu {
                                Button("Remove", systemImage: "trash", role: .destructive) { removing = device }
                            }
                    }
                } header: {
                    Text("Your Devices")
                } footer: {
                    if service.otherDevices.isEmpty {
                        Text("Sign in on your Mac with the same account and it shows up here.")
                    }
                }
                Section {
                    ForEach(model.providers, id: \.id) { provider in
                        LabeledContent {
                            Text(SignInSyncText.status(service.signIns.status[provider.id], keyStatus: service.keyStatus))
                                .foregroundStyle(.secondary)
                        } label: {
                            HStack(spacing: 10) {
                                ServiceMark(id: provider.id, size: 24)
                                Text(provider.id.displayName)
                            }
                        }
                    }
                } header: {
                    Text("Sign-ins")
                } footer: {
                    Text("Sign in to a service once and every device is signed in. Sign-ins are end-to-end encrypted with a key only your devices hold; the server can't read them.")
                }
                if let error {
                    Section { WarningText(error) }
                }
                ServerSection(hub: hub)
                Section {
                    Button("Sign Out", role: .destructive) { confirmSignOut = true }
                } footer: {
                    Text("This iPhone stops syncing and is removed from your devices. It stays signed in to YouTube Music and Spotify.")
                }
            }
        }
        .onAppear { name = service.selfDevice?.name ?? service.deviceInfo.name }
        .onChange(of: service.selfDevice?.name) { _, new in if let new { name = new } }
        .confirmationDialog("Sign out of \(ProductInfo.name) on this iPhone?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await hub.signOutOfAccount() } }
        }
        .confirmationDialog("Remove \(removing?.name ?? "this device")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { device in
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

/// Whether this iPhone can use the account's YouTube Music and Spotify sign-ins, and what to do when it can't.
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
                KeyCard(symbol: comparison.allowed ? "checkmark.shield" : "number.square", title: comparison.title(here: "this iPhone"),
                        text: comparison.instructions(here: "this iPhone"), code: comparison.code)
                if !comparison.confirmed {
                    Button("Codes Match") { service.confirmKeyCode() }
                        .fontWeight(.semibold)
                    Button("Codes Don't Match") { service.rejectKeyCode() }
                        .foregroundStyle(.primary)
                }
            }
        case .denied:
            Section {
                KeyCard(symbol: "key.slash", title: "Your sign-ins weren't shared with this iPhone",
                        text: "Sign in to YouTube Music and Spotify here, or ask again.", code: nil)
                askAgain(service)
            }
        case .failed(let message):
            Section {
                KeyCard(symbol: "exclamationmark.triangle", title: "Your sign-ins weren't shared with this iPhone", text: message, code: nil)
                askAgain(service)
            }
        case .mismatch:
            Section {
                KeyCard(symbol: "key.slash", title: "This iPhone's sign-in key isn't your account's",
                        text: "Sign out of \(ProductInfo.name) and sign in again to fix it.", code: nil)
            }
        case .outdated:
            Section {
                KeyCard(symbol: "key.slash", title: "Your sign-ins changed while this iPhone was away",
                        text: outdatedText(service, here: "this iPhone"), code: nil)
                askAgain(service)
            }
        case .none, .available:
            if let warning = service.keyWarning {
                Section { WarningText(warning).font(.footnote) }
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
            return "Playback and settings already sync. To use your YouTube Music and Spotify sign-ins here, sign in to them on this iPhone."
        }
        let place = holders.count == 1 ? first : "\(first) or another of your devices"
        return "Playback and settings already sync. Open \(ProductInfo.name) on \(place) and allow this iPhone to use your YouTube Music and Spotify sign-ins, or sign in to them here."
    }
}

private struct KeyCard: View {
    let symbol: String
    let title: String
    let text: String
    let code: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(title).foregroundStyle(.primary)
            } icon: {
                Image(systemName: symbol).foregroundStyle(.tint)
            }
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let code {
                LabeledContent("Code") {
                    Text(code).font(.title2.monospacedDigit().weight(.bold)).foregroundStyle(.primary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct ConnectionRow: View {
    let status: ConvexClient.Status

    var body: some View {
        let (text, color): (String, Color) = switch status.state {
        case .connected: (status.httpFallback ? "Connected (slow network)" : "Connected", .green)
        case .connecting, .idle: ("Connecting…", .orange)
        case .waitingToReconnect: (status.httpFallback ? "Reconnecting (syncing slowly)" : "Offline, reconnecting…", .orange)
        case .stopped: ("Stopped", .secondary)
        }
        LabeledContent("Sync") {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(text)
            }
            .foregroundStyle(.secondary)
        }
    }
}

private struct DeviceListRow: View {
    let device: SyncDevice
    let hub: SyncHub

    var body: some View {
        let service = hub.service
        let online = service.isOnline(device)
        let row = service.playback[device.id]
        let playing = row.map { hub.coordinator.effectiveAnchor($0).isPlaying } ?? false
        HStack(spacing: 12) {
            Image(systemName: DeviceGlyph.symbol(device))
                .font(.title3)
                .foregroundStyle(online ? .primary : .secondary)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name)
                    Circle().fill(online ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                        .accessibilityLabel(online ? "Online" : "Offline")
                }
                Text(detail(row: row, playing: playing, online: online))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            if wantsKey {
                Spacer()
                Button("Allow") { hub.dismissedKeyRequests.show(device.id) }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Allow \(device.name) to use your sign-ins")
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// This iPhone has the sign-in key and the device asks for it.
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
        case .waiting, .comparing, .denied, .failed: return "Not shared with this iPhone"
        case .mismatch, .outdated: return "Needs key"
        case .none, .available: break
        }
        switch status {
        case nil, .unavailable?, .waiting?: return "Checking…"
        case .needsKey?: return "Not shared with this iPhone"
        case .notSignedIn?: return "Not signed in"
        case .synced?: return "Synced"
        case .signedOutHere?: return "Signed out here"
        case .signedOutEverywhere?: return "Signed out"
        case .failed?: return "Couldn't sync"
        }
    }

    /// A sentence for the provider's settings page.
    static func footer(_ status: SignInSync.Status?, provider: ProviderID) -> String? {
        switch status {
        case .synced?: "This sign-in syncs to your other devices."
        case .signedOutHere?: "Signed out on this iPhone only. Your other devices are still signed in; sign in here to sync again."
        case .signedOutEverywhere?: "Signed out on all your devices."
        case .needsKey?: "To sync this sign-in, allow this iPhone on a device that has your sign-ins (Settings › Account)."
        case .failed(let message)?: message
        default: nil
        }
    }
}

// MARK: - Sign out

/// Sign Out for a provider page: asks "this iPhone or all devices" when sign-ins sync.
struct SyncAwareSignOutButton: View {
    let id: ProviderID
    @Environment(AppModel.self) private var model

    var body: some View {
        let asking = Binding(get: { model.sync?.signOutPrompt == id }, set: { if !$0 { model.sync?.signOutPrompt = nil } })
        Button("Sign Out", role: .destructive) {
            // Signed in, the sign-out goes through the sign-in sync even without the key, so it sticks.
            if let hub = model.sync { hub.requestSignOut(id) } else { model.signOut(id) }
        }
        .confirmationDialog("Sign out of \(id.displayName)?", isPresented: asking, titleVisibility: .visible) {
            Button("Sign Out on This iPhone") { model.sync?.signOut(id, everywhere: false) }
            Button("Sign Out on All Devices", role: .destructive) { model.sync?.signOut(id, everywhere: true) }
        } message: {
            Text("Signing out on this iPhone keeps your other devices signed in.")
        }
    }
}

/// Under the account on a provider page: whether this sign-in syncs.
struct SignInSyncFooter: View {
    let id: ProviderID
    @Environment(AppModel.self) private var model

    var body: some View {
        if let hub = model.sync, hub.service.isRegistered, let text = SignInSyncText.footer(hub.service.signIns.status[id], provider: id) {
            Label(text, systemImage: "arrow.triangle.2.circlepath")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
