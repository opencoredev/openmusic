import OpenMusicCore
import OpenMusicSync
import SwiftUI
import YouTubeMusicKit
import SpotifyKit
import MediaPlayer
import UIKit

#if DEBUG
/// Live sync check, on with `-OpenMusicSyncSelfTest YES` on the command line of a Debug build (Release builds have none
/// of this). Logs every sync event to `Documents/synctest.log` and takes
/// `openmusic://` links, one per line, appended to `Documents/synctest-cmd.txt` in the app's container. Each goes
/// through `AppModel.handle(url:)`, the same path `onOpenURL` takes. (`xcrun simctl openurl` works too, but on iOS
/// 27 the simulator first asks "Open in OpenMusic?", which a script can't answer.) `openmusic://test/<command>` runs the
/// same code the buttons run, so a script on the build Mac can drive the app:
///
///   playhere                        the banner's Play Here
///   send?to=NAME                    the Devices sheet: tap a device
///   remote?to=NAME&do=toggle|next|previous|seek|volume&v=VALUE
///   signout?provider=youtubeMusic&everywhere=0|1
///   signout?provider=youtubeMusic&tap=1   the provider page's Sign Out button (asks when sign-ins sync)
///   allow | deny                    the "Allow <device>…?" alert's buttons, for the first device asking
///   codes-match | codes-dont-match  Settings › Account's buttons while this iPhone compares the code
///   askagain                        Settings › Account › Ask Again
///   type?text=TEXT&submit=1         types into the field with keyboard focus (as the keyboard does), then Return
///                                   (the field's onSubmit): the sign-in sheet's email and code fields
///   screen?name=account|signin|server|welcome|devices|nowplaying|account-youtubeMusic|signout-youtubeMusic|settings|home|close
///   status                          one line per device, playback, sign-in and setting
///   signout-account                 Settings › Account › Sign Out
///   firstrun?do=ACTION | step=STEP | server=TEXT   the first-run flow's buttons (see `firstRun(_:)`)
///   signin-test?provider=youtubeMusic|spotify   a fake sign-in made here, for the signed-in screens
///
/// The run also accepts the probe's test sign-ins (fake cookies and tokens that the services would reject), so
/// sign-in sync can be checked without real credentials. Real sign-ins are still verified.
@MainActor
enum SyncSelfTest {
    static func start(_ hub: SyncHub) {
        let log = SyncTestLog()
        hub.log = log
        log.write("start \(Date().formatted(.iso8601)) device \(hub.service.deviceInfo.name) registered=\(hub.service.isRegistered)")
        guard let model = hub.model else { return }
        let player = model.player
        hub.service.settings.onApply = { key, value, latency in
            log.write("SETTING \(key) → \(value)\(latency.map { ", \(Int($0)) ms after it was written" } ?? ""); local crossfade=\(model.playback.settings.crossfadeSeconds) autoplay=\(model.playback.settings.autoplay) soundCheck=\(model.playback.settings.normalizeVolume)")
        }
        hub.service.onCommandReceived = { command, delivery in
            log.write("COMMAND \(command.command.kind.rawValue) from \(hub.service.devices.first { $0.id == command.fromDeviceId }?.name ?? "?"), delivered in \(Int(delivery)) ms")
        }
        var lastState = player.state
        _ = player.addChangeHandler { change in
            guard change == .state, player.state != lastState else { return }
            lastState = player.state
            log.write("PLAYER \(player.state.rawValue) \"\(player.current?.title ?? "-")\" at \(fmt(player.currentTime))")
        }
        // Where the source paused after a pull, against where this iPhone was at that same server time.
        var lastRows: [DeviceID: RemotePlayback] = [:]
        Task {
            while true {
                for (id, row) in hub.service.playback where id != hub.service.selfID {
                    if let old = lastRows[id], old.updatedAt != row.updatedAt {
                        let name = hub.service.devices.first { $0.id == id }?.name ?? "?"
                        var line = "REMOTE-STATE \(name): \(row.anchor.isPlaying ? "playing" : "paused") \"\(row.track?.title ?? "(sealed)")\" (\((row.index ?? -1) + 1)/\(row.queueLength ?? 0)) at \(fmt(row.anchor.position(atServerTime: hub.service.clock.now())))"
                        if old.anchor.isPlaying, !row.anchor.isPlaying, player.state == .playing, player.current?.id == row.track?.id {
                            let localThen = player.currentTime - (hub.service.clock.now() - row.anchor.positionAt) / 1000
                            line += String(format: "; this iPhone was at %@ when it paused, delta %.0f ms", fmt(localThen), (localThen - row.anchor.positionMs / 1000) * 1000)
                        }
                        log.write(line)
                    }
                    lastRows[id] = row
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        // The sign-in key: this iPhone's key status (with the code it shows while comparing), the devices asking it
        // (with the code the alert shows), and the account's device list, each logged when it changes.
        Task {
            var lastKey = "", lastRequests = "", lastDevices = "", lastPresented = "", lastFirstRun = ""
            while true {
                let s = hub.service
                let key = keyStatusText(s.keyStatus)
                if key != lastKey { log.write("KEYSTATUS \(key)"); lastKey = key }
                let requests = s.keyRequests.map { "\($0.device.name) code \($0.code)" }.joined(separator: ", ")
                if requests != lastRequests { log.write("KEYREQUESTS [\(requests)]"); lastRequests = requests }
                let devices = s.devices.map { "\($0.name)\($0.id == s.selfID ? " (self)" : "") \($0.keyState?.rawValue ?? "none")" }.joined(separator: ", ")
                if devices != lastDevices { log.write("DEVICES [\(devices)]"); lastDevices = devices }
                // What is on screen, and whether the "Allow …?" alert should be: to tell a prompt that never showed
                // from one that did.
                let shown = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).compactMap { w -> String? in
                    var chain: [String] = []
                    var vc = w.rootViewController?.presentedViewController
                    while let current = vc { chain.append(String(describing: type(of: current))); vc = current.presentedViewController }
                    return chain.isEmpty ? nil : chain.joined(separator: " > ")
                }.joined(separator: ", ")
                let presented = "pending=\(hub.pendingKeyRequest?.device.name ?? "none") on screen: \(shown)"
                if presented != lastPresented { log.write("PRESENTED \(presented)"); lastPresented = presented }
                let firstRun = model.firstRun.map { f in
                    "step=\(f.step.rawValue) activity=\(f.activity.map { "\($0)" } ?? "none") code=\(f.challenge == nil ? "no" : "sent") error=\(f.syncError ?? "none") server=\(f.serverCheck) youtube=\(f.youTubeWithoutAccount ? "without-account" : f.status(.youtubeMusic).logText) spotify=\(f.status(.spotify).logText) account=\(hub.account.user == nil ? "signed out" : "signed in")"
                } ?? "closed"
                if firstRun != lastFirstRun { log.write("FIRSTRUN \(firstRun)"); lastFirstRun = firstRun }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        // The command file: take it whole (rename, so the script's next append starts a new file), run each line.
        let inbox = log.url.deletingLastPathComponent().appendingPathComponent("synctest-cmd.txt")
        let taken = log.url.deletingLastPathComponent().appendingPathComponent("synctest-cmd.taken")
        Task {
            while true {
                try? await Task.sleep(for: .milliseconds(250))
                try? FileManager.default.removeItem(at: taken)
                guard (try? FileManager.default.moveItem(at: inbox, to: taken)) != nil,
                      let text = try? String(contentsOf: taken, encoding: .utf8) else { continue }
                for line in text.split(whereSeparator: \.isNewline) {
                    guard let url = URL(string: line.trimmingCharacters(in: .whitespaces)) else { continue }
                    model.handle(url: url)
                }
            }
        }
        Task {
            while true {
                try? await Task.sleep(for: .seconds(5))
                log.write("hb app=\(UIApplication.shared.applicationState == .active ? "active" : "background") player=\(player.state.rawValue) t=\(fmt(player.currentTime)) \"\(player.current?.title ?? "-")\" connection=\(hub.service.connection.state)")
            }
        }
    }

    /// Handles one `openmusic://test/…` link. Returns true when it was one.
    static func run(_ url: URL, hub: SyncHub) -> Bool {
        guard let log = hub.log, let model = hub.model else { return false }
        let command = url.pathComponents.dropFirst().first ?? ""
        let q = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                           uniquingKeysWith: { a, _ in a })
        // Typed text (an email address, a code) is never logged, only its length.
        log.write("TEST \(command) \(q.sorted { $0.key < $1.key }.map { "\($0.key)=\(command == "type" && $0.key == "text" ? "<\($0.value.count) characters>" : $0.value)" }.joined(separator: " "))")
        func device(_ name: String?) -> SyncDevice? {
            hub.service.otherDevices.first { $0.name.caseInsensitiveCompare(name ?? "") == .orderedSame } ?? hub.service.otherDevices.first
        }
        switch command {
        case "playhere":
            guard let suggestion = hub.banner else { log.write("TEST playhere: no banner"); return true }
            hub.playHere(from: suggestion.device.id)
        case "send":
            guard let target = device(q["to"]) else { log.write("TEST send: no device"); return true }
            Task { _ = await hub.send(to: target.id) }
        case "remote":
            guard let target = device(q["to"]) else { log.write("TEST remote: no device"); return true }
            let value = Double(q["v"] ?? "") ?? 0
            let action = q["do"] ?? "toggle"
            Task {
                _ = await hub.remote(target.id, action) { remote in
                    switch action {
                    case "next": try await remote.next()
                    case "previous": try await remote.previous()
                    case "seek": try await remote.seek(to: value)
                    case "volume": try await remote.setVolume(value)
                    case "play": try await remote.play()
                    case "pause": try await remote.pause()
                    default: try await remote.toggle()
                    }
                }
            }
        case "signout":
            guard let provider = ProviderID(rawValue: q["provider"] ?? "") else { return true }
            if q["tap"] == "1" { hub.requestSignOut(provider) } else { hub.signOut(provider, everywhere: q["everywhere"] == "1") }
        case "allow", "deny":
            guard let request = hub.pendingKeyRequest else { log.write("TEST \(command): no device is asking"); return true }
            Task { if command == "allow" { await hub.allowKey(request) } else { await hub.denyKey(request) } }
        case "codes-match":
            hub.service.confirmKeyCode()
        case "codes-dont-match":
            hub.service.rejectKeyCode()
        case "askagain":
            Task {
                do { try await hub.service.requestKeyAgain() } catch { log.write("KEY ask again failed: \(error.localizedDescription)") }
            }
        case "type":
            typeText(q["text"] ?? "", submit: q["submit"] == "1", log: log)
        case "screen":
            open(q["name"] ?? "", hub: hub, model: model)
        case "status":
            status(hub, model: model, log: log)
        case "signout-account":
            Task { await hub.signOutOfAccount() }
        case "firstrun":
            firstRun(q, hub: hub, model: model, log: log)
        case "signin-test":
            // A fake sign-in made on this iPhone (as if signed in here), for the signed-in screens.
            guard let provider = ProviderID(rawValue: q["provider"] ?? ""), let transfer = hub.transfer(for: provider) else { return true }
            let payload = provider == .youtubeMusic ? YouTubeMusicSignInTransfer.testPayload(accountName: "\(ProductInfo.name) Test (iPhone)") : SpotifySignInTransfer.testPayload()
            Task {
                do {
                    try await transfer.importSignIn(payload)
                    log.write("SIGNIN-TEST \(provider.rawValue) made here; provider \(model.provider(provider)?.authStatus.logText ?? "-")")
                } catch {
                    log.write("SIGNIN-TEST \(provider.rawValue) failed: \(error.localizedDescription)")
                }
            }
        default:
            log.write("TEST unknown \(command)")
        }
        return true
    }

    /// `firstrun?do=ACTION` presses the first-run flow's buttons; `firstrun?step=STEP` pushes a step;
    /// `firstrun?server=TEXT` fills the server field.
    private static func firstRun(_ q: [String: String], hub: SyncHub, model: AppModel, log: SyncTestLog) {
        if let step = q["step"].flatMap(FirstRun.Step.init(rawValue:)) {
            if model.firstRun == nil { model.firstRun = FirstRunFlow(model: model) }
            model.firstRun?.go(to: step)
        }
        if let text = q["server"] { model.firstRun?.serverText = text }
        // As pasted: the email address, and a code ("424 242" works; six digits verify by themselves).
        if let text = q["email"] { model.firstRun?.email = text }
        if let text = q["code"] { model.firstRun?.code = text }
        // `preview=youtubeMusic:Name,spotify:Name` shows those services signed in (Debug captures); `preview=` clears.
        if let list = q["preview"] {
            var shown: [ProviderID: AuthStatus] = [:]
            for item in list.split(separator: ",") {
                let parts = item.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let id = ProviderID(rawValue: parts[0]) else { continue }
                shown[id] = .signedIn(AccountInfo(name: parts[1], id: "preview-\(id.rawValue)"))
            }
            model.firstRun?.previewStatus = shown
        }
        guard let action = q["do"] else { return }
        guard let flow = model.firstRun else { log.write("FIRSTRUN not showing; \(action) ignored"); return }
        switch action {
        case "getstarted": flow.getStarted()
        case "back": flow.back()
        case "continue":
            switch flow.step {
            case .music: flow.continueFromMusic()
            case .sync: flow.continueSignedIn()
            default: flow.finish()
            }
        case "youtube-without": flow.useYouTubeWithoutAccount()
        case "signin-youtube": flow.signIn(.youtubeMusic)
        case "signin-spotify": flow.signIn(.spotify)
        case "close-signin": flow.signingIn = nil
        case "send": flow.sendCode()
        case "verify": flow.verify()
        case "changeemail": flow.changeEmail()
        case "notnow", "finish": flow.finish()
        case "server": flow.openServer()
        case "check": flow.checkServer()
        case "guide": flow.showsServerGuide = true
        case "close-guide": flow.showsServerGuide = false
        case "use":
            if case .reachable(let url) = flow.serverCheck { flow.useServer(url) } else { log.write("FIRSTRUN use: nothing checked") }
        case "codes-match": flow.codesMatch()
        case "codes-dont-match": flow.codesDontMatch()
        case "askagain": flow.askAgain()
        case "later": flow.doThisLater()
        case "dismiss-keyboard":
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        default: log.write("FIRSTRUN unknown \(action)")
        }
    }

    private static func open(_ name: String, hub: SyncHub, model: AppModel) {
        hub.isDevicesPresented = false
        hub.isSignInPresented = false
        hub.signOutPrompt = nil
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            switch name {
            case "close", "home":
                model.isSettingsPresented = false
                model.isNowPlayingPresented = false
                model.settingsPath = []
            case "settings":
                model.isNowPlayingPresented = false
                model.settingsPath = []
                model.isSettingsPresented = true
            case "nowplaying":
                model.isSettingsPresented = false
                model.presentNowPlaying()
            case "devices":
                model.isSettingsPresented = false
                model.presentNowPlaying()
                try? await Task.sleep(for: .milliseconds(700))
                hub.isDevicesPresented = true
            default:
                model.isNowPlayingPresented = false
                model.isSettingsPresented = true
                if name.hasPrefix("account-") || name.hasPrefix("signout-"), let id = ProviderID(rawValue: String(name.split(separator: "-")[1])) {
                    model.settingsPath = [.provider(id)]
                    if name.hasPrefix("signout-") {
                        try? await Task.sleep(for: .milliseconds(700))
                        hub.signOutPrompt = id
                    }
                    return
                }
                model.settingsPath = [.sync]
                try? await Task.sleep(for: .milliseconds(700))
                switch name {
                case "signin": hub.isSignInPresented = true
                case "server": model.settingsPath = [.sync, .server]
                case "welcome":
                    model.isSettingsPresented = false
                    model.settingsPath = []
                    try? await Task.sleep(for: .milliseconds(500))
                    if model.firstRun == nil { model.firstRun = FirstRunFlow(model: model) }
                default: break
                }
            }
        }
    }

    /// Types into the field that has keyboard focus, as the keyboard does (`UIKeyInput.insertText`), and with `submit`
    /// presses Return: the text field's return-key path (`textFieldShouldReturn`), which runs its `onSubmit`. Logs only
    /// how many characters went in, never the text.
    private static func typeText(_ text: String, submit: Bool, log: SyncTestLog) {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let field = windows.lazy.compactMap({ firstResponder(in: $0) }).first as? (UIView & UIKeyInput) else {
            log.write("TYPE no focused field")
            return
        }
        field.insertText(text)
        log.write("TYPE \(text.count) characters\(submit ? " and Return" : "")")
        guard submit else { return }
        // The keyboard's return key arrives as a newline: the field ends editing and runs its `onSubmit` instead of
        // keeping it.
        field.insertText("\n")
        if let textField = field as? UITextField, textField.text?.contains("\n") == true {
            textField.text = textField.text?.replacingOccurrences(of: "\n", with: "")
            log.write("TYPE Return was kept as text")
        }
    }

    private static func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for subview in view.subviews { if let found = firstResponder(in: subview) { return found } }
        return nil
    }

    static func keyStatusText(_ status: SyncService.KeyStatus) -> String {
        switch status {
        case .comparing(let c): "comparing code \(c.code) with \(c.holderName) allowed=\(c.allowed) confirmed=\(c.confirmed)"
        case .failed(let why): "failed: \(why)"
        default: String(describing: status)
        }
    }

    private static func status(_ hub: SyncHub, model: AppModel, log: SyncTestLog) {
        let s = hub.service
        log.write("STATUS registered=\(s.isRegistered) key=\(s.keyStatus) requests=\(s.keyRequests.map { "\($0.device.name) \($0.code)" }) connection=\(s.connection.state) devices=\(s.devices.count)")
        for d in s.devices {
            let row = s.playback[d.id]
            log.write("  device \(d.name)\(d.id == s.selfID ? " (this iPhone)" : "") \(s.isOnline(d) ? "online" : "offline") \(row.map { "\($0.anchor.isPlaying ? "playing" : "paused") \"\($0.track?.title ?? "(sealed)")\" at \(fmt(hub.coordinator.livePosition(of: d.id)))" } ?? "nothing loaded")")
        }
        let p = model.player
        log.write("  local \(p.state.rawValue) \"\(p.current?.title ?? "-")\" at \(fmt(p.currentTime)) index \(p.currentIndex ?? -1)/\(p.queue.count)")
        for provider in model.providers {
            log.write("  sign-in \(provider.id.rawValue): \(provider.authStatus.logText); sync \(String(describing: s.signIns.status[provider.id]))")
        }
        let st = model.playback.settings
        log.write("  settings crossfade=\(st.crossfadeSeconds) autoplay=\(st.autoplay) soundCheck=\(st.normalizeVolume) sleep=\(st.sleepTimerMinutes); recent searches \(model.recentSearches)")
        let love = MPRemoteCommandCenter.shared().likeCommand
        log.write("  lock-screen Love: enabled=\(love.isEnabled) active=\(love.isActive) for \"\(p.current?.title ?? "-")\"")
        log.write("  banner \(hub.banner.map { "Continue from \($0.device.name): \($0.playback.track?.title ?? "(sealed)")" } ?? "none")")
    }
}

#endif

/// The sync self-test's log file. Only created by `SyncSelfTest` (Debug builds); `SyncHub.log` is nil otherwise.
@MainActor
final class SyncTestLog {
    let url: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("synctest.log")
    private let started = Date()

    init() { try? Data().write(to: url) }

    func write(_ line: String) {
        let stamped = String(format: "[+%8.3fs] ", Date().timeIntervalSince(started)) + line
        print("[synctest] \(stamped)")
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((stamped + "\n").utf8))
        try? handle.close()
    }
}
