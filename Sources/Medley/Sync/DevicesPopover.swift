import MedleyCore
import MedleySync
import SwiftUI

// MARK: - Player bar button

/// The player bar's Devices button, like AirPlay or Spotify Connect: every device in the library, a click sends
/// what's playing here to it, and a device that plays can be controlled from here or continued on this Mac.
/// Shown in the capsule's full tier only; narrower tiers list the devices in "…" (`DevicesMenuSection`).
struct DevicesButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let hub = model.sync {
            @Bindable var hub = hub
            let othersPlaying = hub.service.otherDevices.contains { d in
                hub.service.playback[d.id].map { hub.coordinator.effectiveAnchor($0).isPlaying } == true
            }
            Button { hub.isDevicesPresented.toggle() } label: {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 13, weight: .medium))
                    .symbolEffect(.pulse, isActive: hub.busyDevice != nil)
                    .frame(width: 28, height: 28)
                    .overlay(alignment: .bottom) {
                        // Another device is playing: a dot, like the panel toggles' "open" dot.
                        Circle().frame(width: 4, height: 4).offset(y: 1).opacity(othersPlaying ? 1 : 0)
                    }
            }
            .buttonStyle(IconButtonStyle(tint: hub.isDevicesPresented || othersPlaying ? .accentColor : .primary.opacity(0.75)))
            .help("Devices")
            .accessibilityLabel("Devices")
            .accessibilityValue(othersPlaying ? "Another device is playing" : "")
            .playerPopover(isPresented: $hub.isDevicesPresented, arrowEdge: .top) {
                DevicesPopover(hub: hub)
                    .environment(model)
            }
        }
    }
}

/// "…" in the narrower tiers: the other devices to send to or continue from.
struct DevicesMenuSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let hub = model.sync {
            let service = hub.service
            if service.isRegistered, !service.otherDevices.isEmpty {
                Section("Devices") {
                    ForEach(service.otherDevices) { device in
                        let online = service.isOnline(device)
                        let row = service.playback[device.id]
                        if let row, hub.coordinator.effectiveAnchor(row).isPlaying {
                            Button("Continue from \(device.name)", systemImage: "arrow.down.forward.and.arrow.up.backward") {
                                hub.playHere(from: device.id)
                            }
                        } else {
                            Button("Play on \(device.name)", systemImage: DeviceGlyph.symbol(device)) {
                                Task { if let m = await hub.send(to: device.id) { model.show(.init(text: m, symbol: "exclamationmark.triangle.fill")) } }
                            }
                            .disabled(!online || model.player.current == nil)
                        }
                    }
                }
            }
            Button(service.isRegistered ? "Account Settings…" : "Sign In to Sync…", systemImage: "laptopcomputer.and.iphone") {
                model.requestSettings(.sync)
                openSettings()
            }
        }
    }
}

// MARK: - Popover

struct DevicesPopover: View {
    let hub: SyncHub
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let service = hub.service
        VStack(alignment: .leading, spacing: 0) {
            header
            if service.isRegistered {
                // Live positions need a tick only while another device plays; otherwise redraw just when a device's
                // online status runs out (rows and devices changing redraw through observation anyway).
                TimelineView(DevicesSchedule(ticking: anyPlaying, expiries: onlineExpiries)) { _ in
                    list
                }
            } else {
                unpaired
            }
        }
        .frame(width: 340)
        .animation(Motion.Expansion.deviceList.animation(reduce: reduceMotion), value: hub.selectedDevice)
        .animation(Motion.Expansion.deviceList.animation(reduce: reduceMotion), value: service.otherDevices.map(\.id))
        .onAppear { selectDefault() }
    }

    private var anyPlaying: Bool {
        hub.service.otherDevices.contains { d in
            hub.service.playback[d.id].map { hub.coordinator.effectiveAnchor($0).isPlaying } == true
        }
    }

    /// When each online device would count as offline unless it is heard from again (local time).
    private var onlineExpiries: [Date] {
        let service = hub.service
        return service.otherDevices.filter { service.isOnline($0) }.map {
            service.clock.localDate($0.lastSeenAt + SyncLimits.onlineWindow * 1000).addingTimeInterval(0.5)
        }
    }

    private var header: some View {
        HStack {
            Text("Devices").font(.system(size: 13, weight: .semibold))
            Spacer()
            if hub.service.isRegistered { ConnectionDot(status: hub.service.connection) }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var list: some View {
        let service = hub.service
        let player = model.player
        VStack(alignment: .leading, spacing: 2) {
            if let message = hub.message {
                WarningLabel(message)
                    .font(.system(size: 12))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
            ThisMacRow(name: service.selfDevice?.name ?? service.deviceInfo.name, player: player)
            if service.otherDevices.isEmpty {
                Text("No other devices yet. Add your iPhone in Settings › Sync.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            ForEach(service.otherDevices) { device in
                DeviceRow(device: device, hub: hub, canSend: player.current != nil, selected: hub.selectedDevice == device.id) {
                    tap(device)
                } toggleControls: {
                    hub.selectedDevice = hub.selectedDevice == device.id ? nil : device.id
                }
                if hub.selectedDevice == device.id, let row = service.playback[device.id] {
                    RemoteControls(device: device, row: row, hub: hub)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                        .transition(Motion.Transition.deviceControls.transition(reduce: reduceMotion))
                }
            }
            Divider().padding(.horizontal, 16).padding(.vertical, 6)
            Button {
                hub.isDevicesPresented = false
                model.requestSettings(.sync)
                openSettings()
            } label: {
                Label("Sync Settings…", systemImage: "gearshape")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private var unpaired: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign in on your Mac and iPhone to continue listening on one where the other left off. Sign-ins and settings stay the same on every device.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Sign In…") {
                hub.isDevicesPresented = false
                hub.isSignInPresented = true
                model.requestSettings(.sync)
                openSettings()
            }
            .buttonStyle(PillButtonStyle(prominent: true))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    /// Clicking a device sends this Mac's playback there. With nothing loaded here, it shows the device's controls.
    private func tap(_ device: SyncDevice) {
        if model.player.current == nil || hub.busyDevice != nil {
            hub.selectedDevice = hub.selectedDevice == device.id ? nil : device.id
            return
        }
        Task {
            let message = await hub.send(to: device.id)
            withAnimation(Motion.reducesMotion ? nil : .default) { hub.message = message }
        }
    }

    /// The device that is playing (or else the most recent one with something loaded) starts with its controls open.
    private func selectDefault() {
        hub.message = nil
        let service = hub.service
        if let selected = hub.selectedDevice, service.playback[selected] != nil { return }
        let loaded = service.otherDevices.filter { service.playback[$0.id] != nil }
        hub.selectedDevice = (loaded.first { service.playback[$0.id]?.anchor.isPlaying == true } ?? loaded.max { a, b in
            (service.playback[a.id]?.updatedAt ?? 0) < (service.playback[b.id]?.updatedAt ?? 0)
        })?.id
    }
}

private struct ThisMacRow: View {
    let name: String
    let player: PlayerController

    var body: some View {
        HStack(spacing: 10) {
            DeviceIcon(symbol: "laptopcomputer", active: player.isPlaying)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if player.isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.tint)
                    .symbolEffect(.variableColor.iterative, isActive: true)
                    .accessibilityLabel("Playing here")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("This Mac, \(name), \(status)")
    }

    private var status: String {
        guard let track = player.current else { return "This Mac · Not playing" }
        return "This Mac · \(player.isPlaying ? "Playing" : "Paused") \(track.title)"
    }
}

private struct DeviceIcon: View {
    let symbol: String
    var active = false
    var online = true

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(online ? .primary : .tertiary))
            .frame(width: 30, height: 30)
            .background(active ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.quaternary), in: .rect(cornerRadius: 7))
            .accessibilityHidden(true)
    }
}

/// One other device: what it's doing, live progress, and a click target that sends playback there.
private struct DeviceRow: View {
    let device: SyncDevice
    let hub: SyncHub
    let canSend: Bool
    let selected: Bool
    let tap: () -> Void
    let toggleControls: () -> Void
    @State private var hovering = false

    var body: some View {
        let service = hub.service
        let online = service.isOnline(device)
        let row = service.playback[device.id]
        let anchor = row.map(hub.coordinator.effectiveAnchor)
        let playing = anchor?.isPlaying == true
        let busy = hub.busyDevice == device.id
        HStack(spacing: 10) {
            DeviceIcon(symbol: DeviceGlyph.symbol(device), active: playing, online: online)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(device.name).font(.system(size: 13, weight: .medium)).foregroundStyle(online ? .primary : .secondary).lineLimit(1)
                    Circle().fill(online ? Color.green : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                        .accessibilityLabel(online ? "Online" : "Offline")
                }
                Text(subtitle(row: row, playing: playing, online: online))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                if let row, let duration = anchor?.durationMs, duration > 0 {
                    let position = hub.coordinator.livePosition(of: device.id) ?? 0
                    ProgressBar(fraction: position / (duration / 1000), tint: playing ? .accentColor : .secondary)
                        .frame(height: 3)
                        .padding(.top, 2)
                        .accessibilityLabel("Progress on \(device.name)")
                        .accessibilityValue("\(position.clock) of \((duration / 1000).clock)\(row.track.map { ", \($0.title)" } ?? "")")
                }
            }
            Spacer(minLength: 6)
            if busy {
                ProgressView().controlSize(.small)
            } else if row != nil {
                Button(action: toggleControls) {
                    DisclosureChevron(open: selected, size: 10, weight: .bold)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(IconButtonStyle(tint: .secondary))
                .help(selected ? "Hide Controls" : "Show Controls")
                .accessibilityLabel(selected ? "Hide controls for \(device.name)" : "Show controls for \(device.name)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering && canSend && online ? 0.07 : 0)))
        .contentShape(.rect(cornerRadius: 8))
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
        .onTapGesture { if !busy { tap() } }
        .help(canSend ? (online ? "Play on \(device.name)" : "\(device.name) is offline") : "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(canSend ? (online ? "Moves what's playing here to \(device.name)" : "\(device.name) is offline") : "Shows its controls")
        .accessibilityAction { tap() }
    }

    private func subtitle(row: RemotePlayback?, playing: Bool, online: Bool) -> String {
        if !online {
            let seen = hub.service.clock.localDate(device.lastSeenAt).formatted(.relative(presentation: .named))
            return row?.track.map { "Offline · \($0.title) · seen \(seen)" } ?? "Offline · seen \(seen)"
        }
        guard let row else { return canSend ? "Click to play here on \(device.name)" : "Not playing" }
        // Sealed from this Mac (it has no key yet): the state and position only, never a title.
        guard let what = row.trackLine else {
            let position = hub.coordinator.livePosition(of: device.id).map { " · \($0.clock)" } ?? ""
            return "\(playing ? "Playing on" : "Paused on") \(device.name)\(position)"
        }
        return "\(playing ? "Playing" : "Paused") · \(what)"
    }
}

private struct ProgressBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(tint).frame(width: max(3, geo.size.width * min(1, max(0, fraction.isFinite ? fraction : 0))))
            }
        }
    }
}

/// Artwork, scrubber, transport and volume for another device, plus "Play on This Mac".
private struct RemoteControls: View {
    let device: SyncDevice
    let row: RemotePlayback
    let hub: SyncHub
    @State private var drag: Double?
    @State private var volumeDrag: Double?

    var body: some View {
        let online = hub.service.isOnline(device)
        let anchor = hub.coordinator.effectiveAnchor(row)
        let position = hub.coordinator.livePosition(of: device.id) ?? 0
        let duration = (anchor.durationMs ?? row.track?.duration.map { $0 * 1000 } ?? 0) / 1000
        let busy = hub.busyDevice == device.id
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ArtworkView(artwork: row.track?.artwork, size: 44, cornerRadius: 6)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 1) {
                    if let track = row.track {
                        Text(track.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(track.artistLine).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text("\(anchor.isPlaying ? "Playing" : "Paused") on \(device.name)").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text("This Mac sees what plays once it has your sign-in key.").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            if duration > 0 {
                VStack(spacing: 3) {
                    LineSlider(
                        value: min(1, max(0, (drag ?? position) / duration)),
                        enabled: online,
                        accessibilityLabel: "Position on \(device.name)",
                        accessibilityValue: "\((drag ?? position).clock) of \(duration.clock)",
                        onEditing: { f in drag = f.map { $0 * duration } },
                        onCommit: { f in
                            let target = f * duration
                            drag = target
                            Task {
                                report(await hub.remote(device.id, "seek \(Int(target))") { try await $0.seek(to: target) })
                                drag = nil
                            }
                        }
                    )
                    .frame(height: 12)
                    HStack {
                        Text((drag ?? position).clock)
                        Spacer()
                        Text("-" + PlaybackClock.remaining(elapsed: drag ?? position, total: duration).clock)
                    }
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 22) {
                control("backward.fill", "Previous", online: online) { try await $0.previous() }
                control(anchor.isPlaying ? "pause.fill" : "play.fill", anchor.isPlaying ? "Pause" : "Play", large: true, online: online) { try await $0.toggle() }
                control("forward.fill", "Next", online: online) { try await $0.next() }
            }
            // An iPhone plays at the system volume, which apps can't set; a Mac takes a volume command.
            if device.platform.takesVolumeCommands {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    LineSlider(
                        value: volumeDrag ?? anchor.volume,
                        enabled: online,
                        accessibilityLabel: "Volume on \(device.name)",
                        accessibilityValue: "\(Int(((volumeDrag ?? anchor.volume) * 100).rounded())) percent",
                        onEditing: { volumeDrag = $0 },
                        onCommit: { v in
                            volumeDrag = v
                            Task {
                                report(await hub.remote(device.id, "volume \(String(format: "%.2f", v))") { try await $0.setVolume(v) })
                                volumeDrag = nil
                            }
                        }
                    )
                    .frame(height: 12)
                    Image(systemName: "speaker.wave.3.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Button {
                hub.message = nil
                Task {
                    let message = await hub.pull(from: device.id)
                    withAnimation(Motion.reducesMotion ? nil : .default) { hub.message = message }
                }
            } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.small) } else { Image(systemName: "laptopcomputer.and.arrow.down") }
                    Text("Play on This Mac")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(prominent: true))
            .disabled(busy)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private func report(_ message: String?) {
        withAnimation(Motion.reducesMotion ? nil : .default) { hub.message = message }
    }

    private func control(_ symbol: String, _ label: String, large: Bool = false, online: Bool,
                         _ action: @escaping @MainActor (RemoteControl) async throws -> CommandID) -> some View {
        Button {
            Task { report(await hub.remote(device.id, label.lowercased(), action)) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: large ? 20 : 14))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 28)
        }
        .buttonStyle(IconButtonStyle())
        .disabled(!online)
        .help("\(label) on \(device.name)")
        .accessibilityLabel("\(label) on \(device.name)")
    }
}

/// The Devices popover's redraws: every second while another device plays (its live position), else once at each
/// moment an online device would go offline.
struct DevicesSchedule: TimelineSchedule {
    var ticking: Bool
    var expiries: [Date]

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        if ticking {
            var next = startDate
            return AnyIterator {
                defer { next = next.addingTimeInterval(1) }
                return next
            }
        }
        var dates = ([startDate] + expiries.filter { $0 > startDate }.sorted()).makeIterator()
        return AnyIterator { dates.next() }
    }
}

/// A small green, orange or gray dot for the sync connection, with its words as help.
struct ConnectionDot: View {
    let status: ConvexClient.Status

    var body: some View {
        let (text, color) = ConnectionText.describe(status)
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

enum ConnectionText {
    static func describe(_ status: ConvexClient.Status) -> (String, Color) {
        switch status.state {
        case .connected: (status.httpFallback ? "Connected (slow network)" : "Connected", .green)
        case .connecting, .idle: ("Connecting…", .orange)
        case .waitingToReconnect: (status.httpFallback ? "Reconnecting, syncing slowly" : "Offline, reconnecting…", .orange)
        case .stopped: ("Not connected", .secondary)
        }
    }
}
