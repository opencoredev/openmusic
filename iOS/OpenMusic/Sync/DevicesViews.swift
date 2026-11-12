import OpenMusicCore
import OpenMusicSync
import SwiftUI

// MARK: - Continue banner

/// "Continue from <device>", above the mini player while another device plays (or paused under 30 minutes ago).
/// One tap continues it here; the close button hides it until that device plays something else.
struct ContinueBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let hub = model.sync, let suggestion = hub.banner {
            let device = suggestion.device
            let row = suggestion.playback
            let pulling = hub.busyDevice == device.id
            HStack(spacing: 12) {
                ArtworkView(artwork: row.track?.artwork, points: 44)
                    .frame(width: 44, height: 44)
                    .clipShape(.rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Label("Continue from \(device.name)", systemImage: DeviceGlyph.symbol(device))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                    // Without the key: where the other device is, never what it plays ("Playing on Riley's Mac · 2:13").
                    Text(row.track?.title ?? "\(suggestion.isPlaying ? "Playing" : "Paused") on \(device.name)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    LivePositionText(hub: hub, device: device.id, prefix: row.track?.artistLine ?? "", playing: suggestion.isPlaying)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button { hub.playHere(from: device.id) } label: {
                    ZStack {
                        Image(systemName: "play.fill").opacity(pulling ? 0 : 1)
                        if pulling { ProgressView().controlSize(.small) }
                    }
                    .font(.body.weight(.semibold))
                    .frame(width: 30, height: 30)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(pulling)
                .accessibilityLabel("Play Here")
                Button { hub.dismissBanner() } label: {
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
            // A steadier backing than glass alone: shelves scrolling under the banner don't read through its text.
            .background(Color(.systemBackground).opacity(0.72), in: .rect(cornerRadius: 20))
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
            .contentShape(.rect(cornerRadius: 20))
            .onTapGesture { if !pulling { hub.playHere(from: device.id) } }
            .sensoryFeedback(.impact(weight: .light), trigger: pulling) { _, new in new }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(row.track.map { "Continue \($0.title) from \(device.name)" } ?? "Continue from \(device.name)")
            .accessibilityAction(named: "Play Here") { hub.playHere(from: device.id) }
            .accessibilityAction(named: "Dismiss") { hub.dismissBanner() }
        }
    }
}

/// "Artist · 1:23" that ticks while the other device plays.
private struct LivePositionText: View {
    let hub: SyncHub
    let device: DeviceID
    let prefix: String
    let playing: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: playing ? 1 : 3600)) { _ in
            let position = hub.coordinator.livePosition(of: device).map(Scrubber.format) ?? ""
            Text([prefix, position].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}

enum DeviceGlyph {
    static func symbol(_ device: SyncDevice) -> String {
        switch device.platform {
        case .ios: "iphone"
        case .mac: "laptopcomputer"
        case .android: "candybarphone"
        // Windows, Linux and platforms this build doesn't know yet: a generic computer.
        case .windows, .linux, .unknown: "desktopcomputer"
        }
    }
}

// MARK: - Devices button (Now Playing)

/// Now Playing's Devices button, between AirPlay and the queue. Lit when another device is playing.
struct DevicesButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let hub = model.sync {
            @Bindable var hub = hub
            let othersPlaying = hub.service.otherDevices.contains { hub.service.playback[$0.id]?.anchor.isPlaying == true && hub.service.isOnline($0) }
            Button { hub.isDevicesPresented = true } label: {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.title3)
                    .symbolEffect(.pulse, isActive: hub.busyDevice != nil)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(othersPlaying ? 1 : 0.7))
            .accessibilityLabel("Devices")
            .sheet(isPresented: $hub.isDevicesPresented) {
                DevicesSheet()
                    .environment(model)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

// MARK: - Devices sheet

/// Every device in the library, like Spotify Connect: tap one to send what's playing here to it, or control a
/// device that's playing and take its music with "Play on This iPhone".
struct DevicesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if let hub = model.sync {
                    @Bindable var hub = hub
                    if hub.service.isRegistered {
                        list(hub)
                    } else {
                        SignedOutForm(hub: hub)
                            .sheet(isPresented: $hub.isSignInPresented) { SignInSheet(hub: hub) }
                    }
                }
            }
            .navigationTitle("Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        // Now Playing tints everything white; the sheet, toolbar included, uses the app's accent.
        .tint(Color.openMusicAccent)
    }

    private func list(_ hub: SyncHub) -> some View {
        let service = hub.service
        let player = model.player
        return TimelineView(.periodic(from: .now, by: 1)) { _ in
            List {
                if let message {
                    Section {
                        WarningText(message)
                            .font(.subheadline)
                            .transition(.opacity)
                    }
                }
                Section {
                    ThisDeviceRow(name: service.selfDevice?.name ?? service.deviceInfo.name, player: player)
                } header: {
                    Text("This iPhone")
                }
                Section {
                    if service.otherDevices.isEmpty {
                        Text("No other devices yet. Sign in on your Mac with the same account.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(service.otherDevices) { device in
                        RemoteDeviceRow(device: device, hub: hub, canSend: player.current != nil) { result in
                            withAnimation { message = result }
                        }
                    }
                } header: {
                    Text("Your Devices")
                } footer: {
                    if player.current != nil, !service.otherDevices.isEmpty {
                        Text("Tap a device to move what's playing here to it.")
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .animation(.smooth, value: service.otherDevices.map(\.id))
        .sensoryFeedback(.success, trigger: hub.coordinator.lastHandoff?.totalMs)
    }
}

private struct ThisDeviceRow: View {
    let name: String
    let player: PlayerController

    var body: some View {
        HStack(spacing: 12) {
            DeviceIcon(symbol: "iphone", active: player.isPlaying)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.medium))
                Text(status).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if player.isPlaying {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.openMusicAccent).symbolEffect(.variableColor.iterative, isActive: true)
                    .accessibilityLabel("Playing here")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var status: String {
        guard let track = player.current else { return "Not playing" }
        return "\(player.isPlaying ? "Playing" : "Paused") · \(track.title)"
    }
}

private struct DeviceIcon: View {
    let symbol: String
    var active = false
    var online = true

    var body: some View {
        Image(systemName: symbol)
            .font(.title3)
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(online ? .primary : .secondary))
            .frame(width: 40, height: 40)
            .background(active ? AnyShapeStyle(Color.openMusicAccent.gradient) : AnyShapeStyle(.fill.tertiary), in: .rect(cornerRadius: 10))
            .accessibilityHidden(true)
    }
}

/// One other device: what it's doing, live progress, and (when it has something loaded) its remote controls.
private struct RemoteDeviceRow: View {
    let device: SyncDevice
    let hub: SyncHub
    let canSend: Bool
    let report: (String?) -> Void

    var body: some View {
        let service = hub.service
        let online = service.isOnline(device)
        let row = service.playback[device.id]
        let anchor = row.map(hub.coordinator.effectiveAnchor)
        let playing = anchor?.isPlaying == true
        let busy = hub.busyDevice == device.id
        VStack(alignment: .leading, spacing: 12) {
            Button {
                guard canSend else { return }
                guard online else { return report(SyncError.deviceOffline(device.name).localizedDescription) }
                report(nil)
                Task { report(await hub.send(to: device.id)) }
            } label: {
                HStack(spacing: 12) {
                    DeviceIcon(symbol: DeviceGlyph.symbol(device), active: playing, online: online)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(device.name).font(.body.weight(.medium)).foregroundStyle(online ? .primary : .secondary)
                            Circle().fill(online ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                                .accessibilityLabel(online ? "Online" : "Offline")
                        }
                        Text(subtitle(row: row, playing: playing, online: online))
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if busy {
                        ProgressView()
                    } else if canSend, online {
                        Image(systemName: "arrow.up.forward.circle")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(busy || !canSend)
            .accessibilityHint(canSend ? (online ? "Moves what's playing here to \(device.name)" : "\(device.name) is offline") : "")

            if let row, let anchor {
                RemoteControls(device: device, row: row, anchor: anchor, online: online, hub: hub, report: report)
            }
        }
        .padding(.vertical, 4)
    }

    private func subtitle(row: RemotePlayback?, playing: Bool, online: Bool) -> String {
        if !online {
            let seen = hub.service.clock.localDate(device.lastSeenAt)
            return "Offline · seen \(seen.formatted(.relative(presentation: .named)))"
        }
        guard let row else { return "Not playing" }
        // Sealed from this iPhone (it has no key yet): the state and position only, never a title.
        guard let track = row.track else {
            let position = hub.coordinator.livePosition(of: device.id).map { " · \(Scrubber.format($0))" } ?? ""
            return "\(playing ? "Playing on" : "Paused on") \(device.name)\(position)"
        }
        return "\(playing ? "Playing" : "Paused") · \(track.artistLine)"
    }
}

/// Track, scrubber, transport and volume for another device, plus "Play on This iPhone".
private struct RemoteControls: View {
    let device: SyncDevice
    let row: RemotePlayback
    let anchor: PlaybackAnchor
    let online: Bool
    let hub: SyncHub
    let report: (String?) -> Void
    @State private var drag: Double?
    @State private var volume: Double?

    var body: some View {
        let position = hub.coordinator.livePosition(of: device.id) ?? 0
        let duration = (anchor.durationMs ?? 0) / 1000
        let busy = hub.busyDevice == device.id
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ArtworkView(artwork: row.track?.artwork, points: 48)
                    .frame(width: 48, height: 48)
                    .clipShape(.rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    if let track = row.track {
                        Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(track.artistLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text("\(anchor.isPlaying ? "Playing" : "Paused") on \(device.name)").font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text("This iPhone sees what plays once it has your sign-in key.").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if duration > 0 {
                VStack(spacing: 2) {
                    Slider(value: Binding(get: { drag ?? min(position, duration) }, set: { drag = $0 }), in: 0...duration) { editing in
                        guard !editing, let target = drag else { return }
                        Task {
                            report(await hub.remote(device.id, "seek \(Int(target))") { try await $0.seek(to: target) })
                            drag = nil
                        }
                    }
                    .disabled(!online)
                    .accessibilityLabel("Position on \(device.name)")
                    HStack {
                        Text(Scrubber.format(drag ?? position))
                        Spacer()
                        Text("-" + Scrubber.format(PlaybackClock.remaining(elapsed: drag ?? position, total: duration)))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 28) {
                control("backward.fill", "Previous") { try await $0.previous() }
                control(anchor.isPlaying ? "pause.fill" : "play.fill", anchor.isPlaying ? "Pause" : "Play", large: true) { try await $0.toggle() }
                control("forward.fill", "Next") { try await $0.next() }
            }
            .disabled(!online)
            // iPhones use the system volume, which apps can't set; Macs take a volume command.
            if device.platform.takesVolumeCommands {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { volume ?? anchor.volume }, set: { volume = $0 }), in: 0...1) { editing in
                        guard !editing, let target = volume else { return }
                        Task {
                            report(await hub.remote(device.id, "volume \(String(format: "%.2f", target))") { try await $0.setVolume(target) })
                            volume = nil
                        }
                    }
                    .accessibilityLabel("Volume on \(device.name)")
                    Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
                }
                .disabled(!online)
            }
            Button {
                report(nil)
                Task { report(await hub.pull(from: device.id)) }
            } label: {
                Label("Play on This iPhone", systemImage: "iphone.and.arrow.forward.inward")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .trailing) { if busy { ProgressView().controlSize(.small) } }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(busy)
        }
        .padding(12)
        .background(.fill.quaternary, in: .rect(cornerRadius: 16))
    }

    private func control(_ symbol: String, _ label: String, large: Bool = false,
                         _ action: @escaping @MainActor (RemoteControl) async throws -> CommandID) -> some View {
        Button {
            Task { report(await hub.remote(device.id, label.lowercased(), action)) }
        } label: {
            Image(systemName: symbol)
                .font(large ? .title : .title3)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(PressScale())
        .accessibilityLabel("\(label) on \(device.name)")
    }
}

extension Color {
    /// The app's accent from the asset catalog. Unlike `Color.accentColor`, it ignores the surrounding `.tint`
    /// (Now Playing tints everything white).
    static let openMusicAccent = Color("AccentColor")
}
