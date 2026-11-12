import OpenMusicCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var signingIn: ProviderID?

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.settingsPath) {
            Form {
                if model.sync != nil {
                    Section {
                        AccountSettingsRow()
                    } footer: {
                        Text("Continue what's playing on your other devices, and keep sign-ins and settings the same.")
                            .foregroundStyle(.secondaryText)
                    }
                }
                Section {
                    ForEach(model.providers, id: \.id) { provider in
                        NavigationLink(value: SettingsRoute.provider(provider.id)) {
                            AccountRow(id: provider.id)
                        }
                    }
                } header: {
                    Text("Services").foregroundStyle(.secondaryText)
                } footer: {
                    // Only while it would help: signed in, the services' rows already say who is connected.
                    if !(model.provider(.youtubeMusic)?.isSignedIn ?? false) {
                        Text("YouTube Music works without an account. Sign in to see your library and like songs.")
                            .foregroundStyle(.secondaryText)
                    }
                }
                PlaybackSection()
                Section {
                    LabeledContent("Version") {
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                            .foregroundStyle(.secondaryText)
                    }
                } footer: {
                    Text("\(ProductInfo.name) plays YouTube Music and Spotify in one app. Lyrics come from the service or LRCLIB.")
                        .foregroundStyle(.secondaryText)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .sync: AccountSettingsPage()
                case .server: ServerSettingsPage()
                case .provider(let id): ProviderSettingsPage(id: id, signIn: { signingIn = id })
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .sheet(item: $signingIn) { id in
            if let provider = model.provider(id) {
                provider.makeSignInView {
                    signingIn = nil
                    model.signInFinished()
                }
                .presentationDetents(id == .spotify ? [.medium] : [.large])
            }
        }
    }
}

struct ServiceMark: View {
    let id: ProviderID
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: id == .youtubeMusic ? "play.fill" : "waveform")
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(id == .youtubeMusic ? Color(red: 1, green: 0, blue: 0.2) : Color(red: 0.114, green: 0.725, blue: 0.329),
                        in: .rect(cornerRadius: size * 0.24))
            .accessibilityHidden(true)
    }
}

private struct AccountRow: View {
    let id: ProviderID
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            ServiceMark(id: id)
            VStack(alignment: .leading, spacing: 1) {
                Text(id.displayName)
                Text(status).font(.subheadline).foregroundStyle(.secondaryText).lineLimit(1)
            }
        }
    }

    private var status: String {
        switch model.provider(id)?.authStatus ?? .signedOut {
        case .signedIn(let info): info.name
        case .signingIn: "Signing in…"
        case .failed: "Couldn't sign in"
        case .signedOut: "Not signed in"
        }
    }
}

private struct ProviderSettingsPage: View {
    let id: ProviderID
    let signIn: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        if let provider = model.provider(id) {
            Form {
                Section {
                    HStack(spacing: 14) {
                        ServiceMark(id: id, size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            if case .signedIn(let info) = provider.authStatus {
                                Text(info.name).font(.headline)
                                if let detail = info.detail { Text(detail).font(.subheadline).foregroundStyle(.secondaryText) }
                            } else {
                                Text(id.displayName).font(.headline)
                                Text("Not signed in").font(.subheadline).foregroundStyle(.secondaryText)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    if provider.isSignedIn {
                        SyncAwareSignOutButton(id: id)
                    } else {
                        Button(id == .youtubeMusic ? "Sign In with Google" : "Sign In to Spotify", action: signIn)
                    }
                    if case .failed(let message) = provider.authStatus {
                        Text(message).font(.footnote).foregroundStyle(.secondaryText)
                    }
                    SignInSyncFooter(id: id)
                }
                provider.makeSettingsView()
            }
            .navigationTitle(id.displayName)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct PlaybackSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.playback.settings
        let player = model.player
        Section {
            Toggle("Autoplay", isOn: $settings.autoplay)
            Toggle("Sound Check", isOn: $settings.normalizeVolume)
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Crossfade") {
                    Text(settings.crossfadeSeconds < 1 ? "Off" : "\(Int(settings.crossfadeSeconds)) s").foregroundStyle(.secondaryText)
                }
                // The row above shows the value; the slider needs no end labels of its own.
                Slider(value: $settings.crossfadeSeconds, in: PlaybackSettings.crossfadeRange, step: 1) {
                    Text("Crossfade")
                }
                .accessibilityValue(settings.crossfadeSeconds < 1 ? "Off" : "\(Int(settings.crossfadeSeconds)) seconds")
            }
            Menu {
                ForEach(PlaybackSettings.sleepTimerPresets, id: \.self) { minutes in
                    Button("\(minutes) Minutes") {
                        settings.sleepTimerMinutes = minutes
                        player.setSleepTimer(minutes: Double(minutes))
                    }
                }
                Button("End of Current Song") { player.setSleepTimerEndOfTrack() }
                    .disabled(player.current == nil)
                if player.sleepTimer != .off {
                    Divider()
                    Button("Turn Off", role: .destructive) { player.cancelSleepTimer() }
                }
            } label: {
                LabeledContent("Sleep Timer", value: sleepLabel)
                    .foregroundStyle(.primary)
            }
        } header: {
            Text("Playback").foregroundStyle(.secondaryText)
        } footer: {
            Text("Autoplay keeps similar music going when the queue ends. Sound Check plays songs at a similar volume.")
                .foregroundStyle(.secondaryText)
        }
    }

    private var sleepLabel: String {
        switch model.player.sleepTimer {
        case .off: "Off"
        case .endOfTrack: "End of Song"
        case .at(let date): "Until \(date.formatted(date: .omitted, time: .shortened))"
        }
    }
}
