import Foundation
import OpenMusicCore
import OpenMusicSync
import SpotifyKit
import YouTubeMusicKit

/// Probe commands for cross-device sync. Owned by the sync worker.
///
/// Every command takes `--state <path>`: a 0600 JSON file holding this probe device's token and keys, so two
/// processes with two state files are two devices. Tokens are never printed. `--url` picks the deployment (default:
/// dev). `--jwt-file <path>` holds a Clerk session JWT from the `convex` template for the signed-in test user (read
/// again on every refresh, so another process can keep it fresh); the device registers with that user's account.
///
///   openmusic-probe sync sign-in --name A --state a.json --jwt-file jwt.txt     register this device with the account
///   openmusic-probe sync sign-out --state a.json --jwt-file jwt.txt             remove it and forget its keys
///   openmusic-probe sync keys --state a.json --jwt-file …                       vault key status and requests (with codes)
///   openmusic-probe sync allow <device|all> | deny <device> --state a.json …    answer a device asking for the vault key
///   openmusic-probe sync confirm --state b.json …                                 the asking device: the codes match
///   openmusic-probe sync devices --state a.json
///   openmusic-probe sync rename <device> <name> | remove <device> --state a.json
///   openmusic-probe sync watch [--seconds N] --state a.json        live devices, playback states and commands
///   openmusic-probe sync fake-play [--tracks N] [--start-at S] [--seconds N] [--script "..."] [--ytm "query"] --state a.json
///   openmusic-probe sync play-here --from <device> [--seconds N] --state b.json
///   openmusic-probe sync send --to <device> [--after S] [--seconds N] --state b.json
///   openmusic-probe sync remote <device> <play|pause|toggle|next|previous|stop|seek S|volume V> --state b.json
///   openmusic-probe sync run [--play] [--script "..."] [--seconds N] --state b.json
///
/// Scripts are `;`-separated steps run in order: `sleep S`, `play`, `pause`, `seek S`, `play-here DEV`, `send DEV`,
/// `remote DEV ACTION [ARG]`, `drop-socket S` (drop the socket and block reconnects for S seconds), `status`, `quit`,
/// `signin PROVIDER TEXT` (a fake sign-in changes here), `signout PROVIDER here|everywhere`, `crossfade S`,
/// `autoplay on|off`, `searches A,B,C`, `allow-key [S]` (the holder: wait up to S s for a request, Allow it),
/// `confirm-key [S]` (the asking device: wait for its code, confirm, wait for the key), `signin-test youtubeMusic|spotify` (a test sign-in in the transfer's real
/// format, with fake cookies or tokens; see `YouTubeMusicSignInTransfer.testPayload`). Fake devices sync fake sign-ins for both providers and a PlaybackSettings
/// kept in a UserDefaults suite named after the state file.
/// A fake device plays MockProvider tracks on the silent mock engine and obeys commands. With `--ytm "query"` it
/// plays real YouTube Music tracks instead (the first album the query finds, else its songs, looked up signed out),
/// still on the silent engine, so another device can pull the queue and really play it.
@MainActor
enum SyncProbe {
    static func run(_ args: [String]) async throws -> Int32 {
        guard let command = args.first else { return usage() }
        var options = Options(Array(args.dropFirst()))
        guard let state = options.value("--state") else {
            print("--state <path> is required")
            return 2
        }
        guard let jwtFile = options.value("--jwt-file") else {
            print("--jwt-file <path> is required: a Clerk session JWT (template \"convex\") for the test user")
            return 2
        }
        let url = options.value("--url").flatMap(URL.init(string:)) ?? SyncService.defaultDeploymentURL
        let name = options.value("--name") ?? "Probe \(Int.random(in: 100...999))"
        // `--platform ios|mac|windows`: what the other devices take this one for ("Open OpenMusic on your iPhone…").
        let platform = options.value("--platform").flatMap(DevicePlatform.init(rawValue:)) ?? .mac
        let probe = Probe(state: URL(fileURLWithPath: (state as NSString).expandingTildeInPath), url: url, name: name, platform: platform,
                          httpOnly: options.flag("--http-only"),
                          tokens: JWTFileTokens(url: URL(fileURLWithPath: (jwtFile as NSString).expandingTildeInPath)))
        let seconds = options.value("--seconds").flatMap(Double.init)

        switch command {
        case "sign-in": return try await probe.signIn()
        case "sign-out": return try await probe.signOut()
        case "keys": return try await probe.keys()
        case "confirm": return try await probe.confirm()
        case "allow":
            guard let device = options.positional.first else { return usage() }
            return try await probe.allow(device)
        case "deny":
            guard let device = options.positional.first else { return usage() }
            return try await probe.deny(device)
        case "devices": return try await probe.devices()
        case "rename":
            guard options.positional.count >= 2 else { return usage() }
            return try await probe.rename(options.positional[0], to: options.positional.dropFirst().joined(separator: " "))
        case "remove":
            guard let device = options.positional.first else { return usage() }
            return try await probe.remove(device)
        case "watch": return try await probe.watch(seconds: seconds ?? 60)
        case "fake-play", "run":
            let play = command == "fake-play" || options.flag("--play")
            return try await probe.device(play: play, tracks: options.value("--tracks").flatMap(Int.init) ?? 12,
                                          startAt: options.value("--start-at").flatMap(Double.init) ?? 0,
                                          script: options.value("--script"), seconds: seconds ?? 120, ytm: options.value("--ytm"))
        case "play-here":
            guard let from = options.value("--from") else { return usage() }
            return try await probe.device(play: false, tracks: 0, startAt: 0, script: "play-here \(from)", seconds: seconds ?? 20)
        case "send":
            guard let to = options.value("--to") else { return usage() }
            let after = options.value("--after") ?? "3"
            return try await probe.device(play: true, tracks: 12, startAt: 0, script: "sleep \(after); send \(to)", seconds: seconds ?? 20)
        case "remote":
            guard options.positional.count >= 2 else { return usage() }
            return try await probe.remote(device: options.positional[0], action: Array(options.positional.dropFirst()))
        default: return usage()
        }
    }

    private static func usage() -> Int32 {
        print("""
        usage: openmusic-probe sync <command> --state <path> --jwt-file <path> [--url <deployment>] [--name <device name>] [--platform ios|mac|windows] [--http-only]
          sign-in                         register this device with the account of the JWT's user
          sign-out                        remove this device and forget its token and keys
          keys                            vault key status, and devices asking for it (with their codes)
          allow <device|all> | deny <device>   answer a device asking for the vault key
          confirm                              on the asking device: the codes match (the key is taken once allowed)
          devices                         list the account's devices
          rename <device> <new name> | remove <device>
          watch [--seconds N]             print devices, playback and commands as they change
          fake-play [--tracks N] [--start-at S] [--script "..."] [--seconds N] [--ytm "query"]
          play-here --from <device>       pull playback here, then stay on as a fake device
          send --to <device> [--after S]  fake-play, then push playback there
          remote <device> <play|pause|toggle|next|previous|stop|seek S|volume V>
          run [--play] [--script "..."]   a fake device driven by a script
        """)
        return 2
    }
}

// MARK: - Options

private struct Options {
    var positional: [String] = []
    private var named: [String: String] = [:]
    private var flags: Set<String> = []
    private static let valued: Set<String> = ["--state", "--jwt-file", "--url", "--name", "--platform", "--seconds", "--tracks", "--start-at", "--script", "--from", "--to", "--after", "--ytm"]

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let a = args[i]
            if Self.valued.contains(a), i + 1 < args.count {
                named[a] = args[i + 1]
                i += 2
            } else if a.hasPrefix("--") {
                flags.insert(a)
                i += 1
            } else {
                positional.append(a)
                i += 1
            }
        }
    }

    func value(_ key: String) -> String? { named[key] }
    func flag(_ key: String) -> Bool { flags.contains(key) }
}

// MARK: - Probe device

@MainActor
private final class Probe {
    let service: SyncService
    let name: String
    let started = Date()
    var signIns: [ProbeSignIn] = []
    var playbackSettings: PlaybackSettings?

    let tokens: JWTFileTokens

    init(state: URL, url: URL, name: String, platform: DevicePlatform = .mac, httpOnly: Bool, tokens: JWTFileTokens) {
        self.name = name
        self.tokens = tokens
        let info = DeviceInfo(name: name, platform: platform, model: "openmusic-probe", appVersion: OpenMusicSync.version)
        let transport: any WebSocketTransport = httpOnly ? RefusingTransport() : URLSessionWebSocketTransport()
        service = SyncService(deploymentURL: url, deviceInfo: info, credentials: FileCredentialStore(url: state), transport: transport)
    }

    func log(_ message: String) {
        print(String(format: "[%@ +%7.3fs] ", name, Date().timeIntervalSince(started)) + message)
        fflush(stdout)
    }

    // MARK: Account

    /// Registers this device with the JWT's user (once; later commands reuse the saved registration).
    func signInToSync() async throws {
        guard let user = try tokens.userID() else { throw SyncError.notSignedIn }
        try await service.signIn(auth: tokens, userID: user)
    }

    func signIn() async throws -> Int32 {
        try await signInToSync()
        log("registered as \(service.selfID?.rawValue ?? "?") in \(service.registration.libraryText) (token saved, not shown); vault key \(service.keyStatus)")
        return 0
    }

    func signOut() async throws -> Int32 {
        try await signInToSync()
        await service.signOut()
        log("signed out: this device was removed and its token and keys forgotten")
        return 0
    }

    func keys() async throws -> Int32 {
        try await ready()
        // `ready` waits for the device list only; give the key rows (and this device's answer to a request, when it
        // holds the key) a moment, or a fast server returns before either.
        try await Task.sleep(for: .seconds(3))
        log("vault key: \(service.keyStatus); holders: \(service.keyHolders.map(\.name))")
        log("server key id \(service.serverKeyID ?? "none"); this device's key id \(service.libraryKey?.id ?? "none")")
        for request in service.keyRequests { log("REQUEST \(request.device.name) (\(request.device.id)) code \(request.code)") }
        return 0
    }

    /// The listener compared the codes and they match: the key is taken once the holder allowed it.
    func confirm() async throws -> Int32 {
        try await ready()
        // The exchange is worked through as account operations queued behind the first device list: give it a moment.
        for _ in 0..<50 {
            if case .comparing(let c) = service.keyStatus, c.allowed { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard case .comparing(let comparison) = service.keyStatus else {
            log("no code to confirm: vault key \(service.keyStatus)")
            return 1
        }
        service.confirmKeyCode()
        log("CONFIRMED code \(comparison.code) from \(comparison.holderName)")
        for _ in 0..<50 where service.keyStatus != .available { try await Task.sleep(for: .milliseconds(100)) }
        log("vault key: \(service.keyStatus)")
        return 0
    }

    func allow(_ ref: String) async throws -> Int32 {
        try await ready()
        func matching() -> [SyncService.KeyRequest] {
            ref == "all" ? service.keyRequests : service.keyRequests.filter { $0.device.id.rawValue == ref || $0.device.name == ref }
        }
        // The key rows can arrive after the device list `ready` waits for.
        for _ in 0..<100 where matching().isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        let requests = matching()
        guard !requests.isEmpty else { log("no device is asking for the vault key"); return 1 }
        for request in requests {
            try await service.allowKey(for: request)
            log("ALLOWED \(request.device.name) code \(request.code)")
        }
        return 0
    }

    func deny(_ ref: String) async throws -> Int32 {
        try await ready()
        guard let request = service.keyRequests.first(where: { $0.device.id.rawValue == ref || $0.device.name == ref }) else {
            log("that device isn't asking for the vault key"); return 1
        }
        try await service.denyKey(for: request)
        log("DENIED \(request.device.name)")
        return 0
    }

    func devices() async throws -> Int32 {
        try await ready()
        printDevices()
        return 0
    }

    func rename(_ ref: String, to newName: String) async throws -> Int32 {
        try await ready()
        let device = try resolve(ref)
        try await service.rename(device.id, to: newName)
        log("renamed \(device.name) to \(newName)")
        return 0
    }

    func remove(_ ref: String) async throws -> Int32 {
        try await ready()
        let device = try resolve(ref)
        try await service.remove(device.id)
        log("removed \(device.name) (\(device.id)); its token no longer works")
        return 0
    }

    /// Starts the service and waits until the device list arrived.
    func ready(timeout: TimeInterval = 15) async throws {
        try await signInToSync()
        guard service.isRegistered else { throw SyncError.notPaired }
        let deadline = Date().addingTimeInterval(timeout)
        while service.devices.isEmpty || !service.clock.hasSample {
            if let error = service.lastError { throw error }
            guard Date() < deadline else { throw SyncError.timedOut("The sync server") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func printDevices() {
        for d in service.devices {
            let online = service.isOnline(d) ? "online" : "offline"
            let me = d.id == service.selfID ? " (this device)" : ""
            let seen = (service.clock.now() - d.lastSeenAt) / 1000
            log("device \(d.name)\(me) id=\(d.id) \(d.platform.rawValue) \(d.model) \(online), seen \(String(format: "%.0f", seen)) s ago")
        }
    }

    func resolve(_ ref: String) throws -> SyncDevice {
        if let d = service.devices.first(where: { $0.id.rawValue == ref || $0.name.caseInsensitiveCompare(ref) == .orderedSame }) { return d }
        throw SyncError.unknownDevice
    }

    // MARK: Watch

    func watch(seconds: TimeInterval) async throws -> Int32 {
        try await ready()
        printDevices()
        var watcher = PlaybackWatcher()
        var lastIncoming: [CommandID] = []
        var lastConnection = service.connection
        let end = Date().addingTimeInterval(seconds)
        var lastSummary = Date.distantPast
        while Date() < end {
            for line in watcher.changes(service) { log(line) }
            let ids = service.incoming.map(\.id)
            if ids != lastIncoming {
                for c in service.incoming where !lastIncoming.contains(c.id) {
                    log("pending command \(c.command.kind.rawValue) from \(deviceName(c.fromDeviceId)), \(String(format: "%.0f", service.clock.now() - c.createdAt)) ms after it was sent")
                }
                lastIncoming = ids
            }
            if service.connection != lastConnection { lastConnection = service.connection; log("connection \(describe(lastConnection))") }
            if Date().timeIntervalSince(lastSummary) > 5 {
                lastSummary = Date()
                for (id, row) in service.playback.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                    log("  \(deviceName(id)): \(row.anchor.isPlaying ? "playing" : "paused") \"\(row.track?.title ?? "(sealed)")\" at \(fmt(row.anchor.position(atServerTime: service.clock.now())))")
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return 0
    }

    func deviceName(_ id: DeviceID) -> String { service.devices.first { $0.id == id }?.name ?? id.rawValue }

    // MARK: Fake device

    func device(play: Bool, tracks count: Int, startAt: TimeInterval, script: String?, seconds: TimeInterval, ytm: String? = nil) async throws -> Int32 {
        try await ready()
        let player = PlayerController()
        player.register(MockProvider(id: .youtubeMusic))
        player.register(MockProvider(id: .spotify))
        let sync = SyncCoordinator(service: service, player: player)
        sync.attach()

        // Fake sign-ins for both providers, and playback settings in a suite of their own.
        let signIns = [ProbeSignIn(.youtubeMusic), ProbeSignIn(.spotify)]
        service.signIns.onImport = { [weak self] i in
            // Provider, size and status only: never the sign-in itself.
            self?.log("SIGN-IN \(i.provider.rawValue) \(i.signedOut ? "signed out everywhere" : "imported \(i.bytes) bytes") — \(String(format: "%.0f", i.latencyMs)) ms after it was written (server clock)")
        }
        for signIn in signIns { service.signIns.register(signIn) }
        let playbackSettings = PlaybackSettings(defaults: UserDefaults(suiteName: "medley-probe.\(name.filter(\.isLetter))")!)
        service.settings.bind(playbackSettings)
        var searches: [String] = []
        service.settings.observeRecentSearches(current: { searches }) { [weak self] list in
            searches = list
            self?.log("SETTING recent searches → \(list)")
        }
        service.settings.onApply = { [weak self] key, value, latency in
            self?.log("SETTING \(key) → \(value)\(latency.map { String(format: " — %.0f ms after it was written", $0) } ?? "")")
        }
        log("vault key: \(service.keyStatus); crossfade \(playbackSettings.crossfadeSeconds) s, autoplay \(playbackSettings.autoplay)")
        self.signIns = signIns
        self.playbackSettings = playbackSettings

        service.onCommandReceived = { [weak self] command, delivery in
            self?.log("received \(command.command.kind.rawValue) from \(self?.deviceName(command.fromDeviceId) ?? "?") — delivery \(String(format: "%.0f", delivery)) ms (server clock)")
        }
        player.addChangeHandler { [weak self, weak player] change in
            guard let self, let player, change == .state else { return }
            self.log("player \(player.state.rawValue) \"\(player.current?.title ?? "-")\" at \(fmt(player.currentTime))")
        }
        printDevices()

        if play {
            let tracks: [Track]
            if let ytm {
                tracks = try await Self.youTubeMusicTracks(ytm, limit: max(1, count))
                log("YouTube Music \"\(ytm)\": \(tracks.count) tracks, first \"\(tracks.first?.title ?? "-")\" (\(tracks.first?.providerID ?? "-"))")
            } else {
                tracks = Array(MockProvider(id: .youtubeMusic).catalog.allTracks.prefix(max(1, count)))
            }
            player.play(tracks, startAt: 0)
            if startAt > 0 {
                while player.state != .playing { try await Task.sleep(for: .milliseconds(10)) }
                player.seek(to: startAt)
            }
        }

        let watch = Task { [weak self] in
            var watcher = PlaybackWatcher()
            var lastConnection = self?.service.connection
            while !Task.isCancelled, let self {
                for line in watcher.changes(self.service, local: player, selfID: self.service.selfID) { self.log(line) }
                if self.service.connection != lastConnection {
                    lastConnection = self.service.connection
                    self.log("connection \(describe(self.service.connection))")
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        defer { watch.cancel() }

        let end = Date().addingTimeInterval(seconds)
        var quit = false
        for step in (script ?? "").split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where !step.isEmpty {
            quit = try await runStep(step, sync: sync, player: player)
            if quit { break }
        }
        while !quit, Date() < end { try await Task.sleep(for: .milliseconds(100)) }
        sync.detach()
        log("done; local player \(player.state.rawValue) at \(fmt(player.currentTime))")
        return 0
    }

    /// Real tracks for `--ytm`: the first album `query` finds, else its songs. Signed out; nothing is saved.
    static func youTubeMusicTracks(_ query: String, limit: Int) async throws -> [Track] {
        let youtube = YouTubeMusicProvider()
        let results = try await youtube.search(query, scope: .all)
        if let album = results.albums.first {
            let detail = try await youtube.album(id: album.providerID)
            if !detail.tracks.isEmpty { return Array(detail.tracks.prefix(limit)) }
        }
        let songs = results.tracks.isEmpty ? try await youtube.search(query, scope: .songs).tracks : results.tracks
        guard !songs.isEmpty else { throw SyncError.nothingPlaying("YouTube Music search \"\(query)\"") }
        return Array(songs.prefix(limit))
    }

    private func runStep(_ step: String, sync: SyncCoordinator, player: PlayerController) async throws -> Bool {
        let parts = step.split(separator: " ").map(String.init)
        // A sign-in step carries the (fake) secret: log its size, not the text.
        log(parts.first == "signin" && parts.count >= 3 ? "step: signin \(parts[1]) <\(parts.dropFirst(2).joined(separator: " ").utf8.count) bytes>" : "step: \(step)")
        switch parts.first {
        case "sleep":
            try await Task.sleep(for: .seconds(Double(parts.dropFirst().first ?? "1") ?? 1))
        case "play": player.resume()
        case "pause": player.pause()
        case "seek": player.seek(to: Double(parts.dropFirst().first ?? "0") ?? 0)
        case "status":
            printDevices()
            log("local \(player.state.rawValue) \"\(player.current?.title ?? "-")\" at \(fmt(player.currentTime)); connection \(describe(service.connection))")
        case "play-here":
            let source = try resolve(parts.dropFirst().joined(separator: " "))
            let sourcePos = service.livePosition(of: source.id)
            log("play here from \(source.name): source at \(sourcePos.map(fmt) ?? "-")")
            do {
                try await sync.playHere(from: source.id)
                if let r = sync.lastHandoff {
                    log("PULL done: queue \(Int(r.fetchMs)) ms, cued \(Int(r.readyMs)) ms, playing \(Int(r.totalMs)) ms; local \(fmt(player.currentTime)) vs source live \(fmt(service.livePosition(of: source.id) ?? -1)); delta \(String(format: "%.0f", r.positionDeltaMs ?? .nan)) ms")
                }
            } catch {
                log("PULL failed: \(error.localizedDescription)")
            }
        case "send":
            let target = try resolve(parts.dropFirst().joined(separator: " "))
            do {
                try await sync.send(to: target.id)
                if let r = sync.lastHandoff {
                    log("PUSH done: command sent \(Int(r.fetchMs)) ms, target acked playing \(Int(r.readyMs)) ms, paused here \(Int(r.totalMs)) ms")
                }
            } catch {
                log("PUSH failed: \(error.localizedDescription)")
            }
        case "remote":
            guard parts.count >= 3 else { log("remote needs DEV ACTION"); return false }
            let target = try resolve(parts[1])
            try await sendRemote(to: target, action: Array(parts.dropFirst(2)))
        case "drop-socket":
            let s = Double(parts.dropFirst().first ?? "5") ?? 5
            log("dropping the socket and blocking reconnects for \(fmt(s))")
            await service.client.simulateNetworkLoss(for: .seconds(s))
        case "signin":
            guard parts.count >= 3, let provider = ProviderID(rawValue: parts[1]), let signIn = signIns.first(where: { $0.provider == provider }) else {
                log("signin needs PROVIDER TEXT"); return false
            }
            signIn.localChange(parts.dropFirst(2).joined(separator: " "))
        case "signout":
            guard parts.count >= 3, let provider = ProviderID(rawValue: parts[1]) else { log("signout needs PROVIDER here|everywhere"); return false }
            try await service.signIns.signOut(provider, everywhere: parts[2] == "everywhere")
            log("signed out of \(provider.rawValue) \(parts[2]); status \(String(describing: service.signIns.status[provider]))")
        case "crossfade":
            playbackSettings?.crossfadeSeconds = Double(parts.dropFirst().first ?? "0") ?? 0
        case "autoplay":
            playbackSettings?.autoplay = parts.dropFirst().first == "on"
        case "searches":
            service.settings.set(SettingsSync.recentSearchesKey, parts.dropFirst().joined(separator: " ").split(separator: ",").map(String.init))
        case "signin-test":
            #if DEBUG
            guard let provider = parts.dropFirst().first.flatMap(ProviderID.init(rawValue:)),
                  let signIn = signIns.first(where: { $0.provider == provider }) else { log("signin-test needs youtubeMusic|spotify"); return false }
            let payload = provider == .youtubeMusic ? YouTubeMusicSignInTransfer.testPayload(accountName: "Probe Test Account")
                                                    : SpotifySignInTransfer.testPayload()
            signIn.localChange(String(decoding: payload, as: UTF8.self))
            log("wrote a \(provider.rawValue) test sign-in (fake credentials, \(payload.count) bytes)")
            #else
            log("signin-test needs a debug build of the probe (release builds have no test sign-ins)")
            #endif
        case "allow-key":
            // The holder, as a running device: wait for a verified request (its code shown), then Allow.
            let deadline = Date().addingTimeInterval(Double(parts.dropFirst().first ?? "30") ?? 30)
            while service.keyRequests.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            guard let request = service.keyRequests.first else { log("allow-key: no device asked"); return false }
            log("REQUEST \(request.device.name) code \(request.code)")
            try await service.allowKey(for: request)
            log("ALLOWED \(request.device.name) code \(request.code)")
        case "confirm-key":
            // The asking device, as a running device: wait for its code, confirm it, wait for the key.
            let deadline = Date().addingTimeInterval(Double(parts.dropFirst().first ?? "30") ?? 30)
            while Date() < deadline { if case .comparing = service.keyStatus { break }; try await Task.sleep(for: .milliseconds(100)) }
            guard case .comparing(let comparison) = service.keyStatus else { log("confirm-key: no code: vault key \(service.keyStatus)"); return false }
            log("CODE \(comparison.code) from \(comparison.holderName)")
            service.confirmKeyCode()
            while service.keyStatus != .available, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            log("vault key: \(service.keyStatus); key id \(service.libraryKey?.id ?? "none"), server's \(service.serverKeyID ?? "none")")
        case "signins":
            for signIn in signIns { log("  \(signIn.provider.rawValue): \(signIn.text.map { "signed in, \($0.utf8.count) bytes" } ?? "signed out") (\(String(describing: service.signIns.status[signIn.provider])))") }
        case "quit":
            return true
        default:
            log("unknown step \(step)")
        }
        return false
    }

    // MARK: Remote

    func remote(device ref: String, action: [String]) async throws -> Int32 {
        try await ready()
        try await sendRemote(to: try resolve(ref), action: action)
        return 0
    }

    private func sendRemote(to target: SyncDevice, action: [String]) async throws {
        let command: SyncCommand
        switch action.first {
        case "play": command = .play
        case "pause": command = .pause
        case "toggle": command = .toggle
        case "next": command = .next
        case "previous": command = .previous
        case "stop": command = .stop
        case "seek": command = .seek(positionMs: (Double(action.dropFirst().first ?? "0") ?? 0) * 1000)
        case "volume": command = .setVolume(Double(action.dropFirst().first ?? "0.5") ?? 0.5)
        default: throw SyncError.commandFailed("unknown action \(action.joined(separator: " "))")
        }
        let start = Date()
        let id = try await service.send(command, to: target.id)
        let sent = Date()
        let result = try await service.waitForAck(id, timeout: .seconds(20))
        let acked = Date()
        log("REMOTE \(command.kind.rawValue) → \(target.name): send mutation \(ms(sent, start)) ms, ack seen \(ms(acked, start)) ms after the tap, result ok=\(result.ok)\(result.message.map { " (\($0))" } ?? "")")
    }
}

// MARK: - Helpers

/// Prints playback changes of other devices, and how far this device is from a source that just paused.
private struct PlaybackWatcher {
    private var last: [DeviceID: RemotePlayback] = [:]

    @MainActor
    mutating func changes(_ service: SyncService, local: PlayerController? = nil, selfID: DeviceID? = nil) -> [String] {
        var lines: [String] = []
        let names = Dictionary(service.devices.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for (id, row) in service.playback where id != selfID {
            let old = last[id]
            guard old?.updatedAt != row.updatedAt else { continue }
            let pos = row.anchor.position(atServerTime: service.clock.now())
            var line = "\(names[id] ?? id.rawValue) published: \(row.anchor.isPlaying ? "playing" : "paused") \"\(row.track?.title ?? "(sealed)")\" (\((row.index ?? -1) + 1)/\(row.queueLength ?? 0)) at \(fmt(pos))"
            if old?.queueVersion != row.queueVersion { line += ", queue v\(row.queueVersion)" }
            // The source just paused after a handoff: where was this device at the moment it paused?
            if let local, old?.anchor.isPlaying == true, !row.anchor.isPlaying, local.state == .playing,
               local.current?.id == row.track?.id {
                let localThen = local.currentTime - (service.clock.now() - row.anchor.positionAt) / 1000
                line += String(format: "; this device was at %@ then, delta %.0f ms", fmt(localThen), (localThen - row.anchor.positionMs / 1000) * 1000)
            }
            lines.append(line)
            last[id] = row
        }
        for id in last.keys where service.playback[id] == nil {
            lines.append("\(names[id] ?? id.rawValue) cleared its playback")
            last[id] = nil
        }
        return lines
    }
}

/// `--http-only`: every socket fails at once, so the client runs on its HTTP fallback.
private struct RefusingTransport: WebSocketTransport {
    private struct Dead: WebSocketConnection {
        func send(_ text: String) {}
        func close() {}
    }

    func connect(to url: URL) -> (connection: any WebSocketConnection, events: AsyncStream<WebSocketEvent>) {
        let (stream, continuation) = AsyncStream.makeStream(of: WebSocketEvent.self)
        continuation.yield(.closed(reason: "refused (--http-only)"))
        continuation.finish()
        return (Dead(), stream)
    }
}

/// A fake provider sign-in: a text "token" kept in memory. Importing or signing out reports the change, as the
/// app's providers will.
@MainActor
private final class ProbeSignIn: SignInTransfer {
    let provider: ProviderID
    var text: String?
    var signInDidChange: (@MainActor () -> Void)?

    init(_ provider: ProviderID) { self.provider = provider }

    func exportSignIn() async -> Data? { text.map { Data($0.utf8) } }

    func importSignIn(_ data: Data) async throws {
        text = String(decoding: data, as: UTF8.self)
        signInDidChange?()
    }

    func signOut() async {
        text = nil
        signInDidChange?()
    }

    /// What to print: a fake text sign-in as it is; a real-format sign-in (JSON from another device) only by size.
    var summary: String {
        guard let text else { return "signed out" }
        return text.hasPrefix("{") ? "<\(text.utf8.count)-byte sign-in, not shown>" : text
    }

    func localChange(_ new: String?) {
        text = new
        signInDidChange?()
    }
}

private extension SyncService.Registration {
    var libraryText: String {
        if case .registered(_, let library) = self { return library.rawValue }
        return "-"
    }
}


private func fmt(_ seconds: TimeInterval) -> String { String(format: "%.2fs", seconds) }

private func ms(_ a: Date, _ b: Date) -> Int { Int((a.timeIntervalSince(b) * 1000).rounded()) }

private func describe(_ s: ConvexClient.Status) -> String {
    let state: String = switch s.state {
    case .idle: "idle"
    case .connecting: "connecting"
    case .connected: "connected"
    case .waitingToReconnect(let attempt): "waiting to reconnect (attempt \(attempt))"
    case .stopped: "stopped"
    }
    return "\(state)\(s.httpFallback ? " + HTTP fallback" : ""), sockets opened: \(s.connections)"
}
