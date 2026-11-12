import AppKit
import ApplicationServices
import MedleyCore
import MedleySync
import SpotifyKit
import SwiftUI
import YouTubeMusicKit

#if DEBUG
/// Live sync check, debug builds only (release builds compile all of this out), on with launch arguments:
/// `-MedleySyncSelfTest YES -MedleySyncDir <dir> -MedleySyncJWTFile <file> [-MedleySyncState <file>] [-MedleySyncDeviceName <name>]`.
/// The JWT file holds a Clerk session token (template "convex") for the test user; the Mac signs in to sync with it.
/// Logs every sync event to `<dir>/synctest.log` and takes `medley://` links,
/// one per line, appended to `<dir>/synctest-cmd.txt`. Each goes through `SyncHub.handle(_:)`, the path a link
/// opened from Launch Services takes.
/// `medley://test/<command>` runs the code the buttons run:
///
///   allow | deny                         the "Allow <device>…?" alert's buttons, for the first device asking
///   codes-match | codes-dont-match       Settings › Account's buttons while this Mac compares the code
///   askagain                             Settings › Account › Ask Again
///   remove-others                        Settings › Account › Remove… for every other device (leftovers of an
///                                        interrupted run)
///   type?text=TEXT&submit=1              types into the field with keyboard focus (the field editor takes it as
///                                        from the keyboard), then Return through the event queue: the sign-in
///                                        sheet's email and code fields, as a listener fills them in
///   playhere                             the banner's Play Here
///   dismiss                              the banner's close button
///   send?to=NAME                         the Devices popover: click a device
///   remote?to=NAME&do=toggle|play|pause|next|previous|seek|volume&v=VALUE
///   play?ytm=QUERY&seek=SECONDS          play the first album QUERY finds on YouTube Music, from track 1
///   pause | resume | seek?v=SECONDS | crossfade?v=SECONDS | search?q=QUERY
///   signin-test?provider=youtubeMusic|spotify   a fake sign-in on this Mac (as if signed in here), synced out
///   signout?provider=…&everywhere=0|1
///   signout-account                      Settings › Account › Sign Out
///   screen?name=account|signin|server|welcome|accounts|signout-<provider>|playback|devices|close
///   appearance?mode=light|dark           shot?name=NAME&w=main|stack|settings|popover|sheet
///   wake | drop?s=SECONDS                a wake from sleep / a network loss that blocks reconnects
///   network?up=1|0&if=en0,utun3          a network path update, as `NWPathMonitor` reports one
///   status                               one line per device, playback, sign-in and setting
///   firstrun?do=ACTION | step=STEP | server=TEXT   the first-run flow's buttons (getstarted, back, continue,
///                                        youtube-without, signin-youtube, signin-spotify, send, verify, changeemail,
///                                        notnow, server, check, use, codes-match, codes-dont-match, askagain, later)
///   key?k=tab|shift-tab|return|escape|cmd-[   a key through the event queue; logs what has focus after it
///   window?w=W&h=H                       the main window's content size in points
///
/// Fake sign-ins are accepted only here (`acceptingTestSignIns`); real ones are still verified.
@MainActor
enum SyncSelfTest {
    static func start(_ hub: SyncHub) {
        guard let model = hub.model, let dir = hub.options.directory else { return }
        let log = SyncTestLog(directory: dir)
        hub.log = log
        log.write("start \(Date().formatted(.iso8601)) device \(hub.service.deviceInfo.name) registered=\(hub.service.isRegistered)")
        let player = model.player
        hub.service.settings.onApply = { key, value, latency in
            log.write("SETTING \(key) → \(value)\(latency.map { ", \(Int($0)) ms after it was written" } ?? ""); local crossfade=\(model.playback.settings.crossfadeSeconds) autoplay=\(model.playback.settings.autoplay) soundCheck=\(model.playback.settings.normalizeVolume)")
        }
        hub.service.onCommandReceived = { command, delivery in
            log.write("COMMAND \(command.command.kind.rawValue) from \(hub.name(of: command.fromDeviceId)), delivered in \(Int(delivery)) ms")
        }
        // Connection changes, to show reconnects after wake, network changes and leaving.
        trackConnection(hub, log: log)
        var lastState = player.state
        var lastTrack = player.current?.id
        _ = player.addChangeHandler { _ in
            guard player.state != lastState || player.current?.id != lastTrack else { return }
            lastState = player.state
            lastTrack = player.current?.id
            log.write("PLAYER \(player.state.rawValue) \"\(player.current?.title ?? "-")\" at \(fmt(player.currentTime))")
        }
        // Each other device's published state, and where this Mac was at the server time a source paused.
        var lastRows: [DeviceID: RemotePlayback] = [:]
        Task {
            while true {
                for (id, row) in hub.service.playback where id != hub.service.selfID {
                    if let old = lastRows[id], old.updatedAt != row.updatedAt {
                        var line = "REMOTE-STATE \(hub.name(of: id)): \(row.anchor.isPlaying ? "playing" : "paused") \"\(row.track?.title ?? "(sealed)")\" (\((row.index ?? -1) + 1)/\(row.queueLength ?? 0)) at \(fmt(row.anchor.position(atServerTime: hub.service.clock.now())))"
                        if old.anchor.isPlaying, !row.anchor.isPlaying, player.state == .playing, player.current?.id == row.track?.id {
                            let localThen = player.currentTime - (hub.service.clock.now() - row.anchor.positionAt) / 1000
                            line += String(format: "; this Mac was at %@ when it paused, delta %.0f ms", fmt(localThen), (localThen - row.anchor.positionMs / 1000) * 1000)
                        }
                        log.write(line)
                    }
                    lastRows[id] = row
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        // The sign-in key: this Mac's key status (with the code it shows while comparing), the devices asking it (with
        // the code the alert shows), and the account's device list, each logged when it changes.
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
                let shown = NSApp.windows.filter(\.isVisible).map { w in "\(type(of: w))\(w.attachedSheet.map { " sheet \(type(of: $0)) \"\($0.title)\"" } ?? "")\(w.isKeyWindow ? " key" : "")" }.joined(separator: ", ") + " active=\(NSApp.isActive)"
                let presented = "pending=\(hub.pendingKeyRequest?.device.name ?? "none") on screen: \(shown)"
                if presented != lastPresented { log.write("PRESENTED \(presented)"); lastPresented = presented }
                let flow = model.firstRun
                let firstRun = flow.map { f in
                    "step=\(f.step.rawValue) activity=\(f.activity.map { "\($0)" } ?? "none") code=\(f.challenge == nil ? "no" : "sent") error=\(f.syncError ?? "none") server=\(f.serverCheck) youtube=\(f.youTubeWithoutAccount ? "without-account" : f.status(.youtubeMusic).logText) spotify=\(f.status(.spotify).logText) account=\(hub.account.user == nil ? "signed out" : "signed in")"
                } ?? "closed"
                if firstRun != lastFirstRun { log.write("FIRSTRUN \(firstRun)"); lastFirstRun = firstRun }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        // The command file: take it whole (rename, so the script's next append starts a new file), run each line.
        let inbox = dir.appendingPathComponent("synctest-cmd.txt")
        let taken = dir.appendingPathComponent("synctest-cmd.taken")
        Task {
            while true {
                try? await Task.sleep(for: .milliseconds(250))
                try? FileManager.default.removeItem(at: taken)
                guard (try? FileManager.default.moveItem(at: inbox, to: taken)) != nil,
                      let text = try? String(contentsOf: taken, encoding: .utf8) else { continue }
                for line in text.split(whereSeparator: \.isNewline) {
                    guard let url = URL(string: line.trimmingCharacters(in: .whitespaces)) else { continue }
                    // The same router Launch Services links go through.
                    URLRouter.shared.open(url)
                }
            }
        }
        Task {
            while true {
                try? await Task.sleep(for: .seconds(5))
                log.write("hb inUse=\(hub.isInUse) player=\(player.state.rawValue) t=\(fmt(player.currentTime)) \"\(player.current?.title ?? "-")\" connection=\(hub.service.connection.state)")
            }
        }
    }

    private static func trackConnection(_ hub: SyncHub, log: SyncTestLog) {
        withObservationTracking {
            _ = hub.service.connection
        } onChange: { [weak hub] in
            Task { @MainActor in
                guard let hub else { return }
                let c = hub.service.connection
                log.write("CONNECTION \(c.state)\(c.httpFallback ? " (HTTP fallback)" : "") connections=\(c.connections)")
                trackConnection(hub, log: log)
            }
        }
    }

    /// Handles one `medley://test/…` link. Returns true when it was one.
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
        let player = model.player
        switch command {
        case "allow", "deny":
            // The alert's own button while it is up, the path a listener takes; the hub's call when it isn't.
            if pressAlertButton(command == "allow" ? "Allow" : "Don't Allow", log: log) { return true }
            Task {
                guard let request = hub.pendingKeyRequest else { log.write("KEY no device is asking"); return }
                if command == "allow" { await hub.allowKey(request) } else { await hub.denyKey(request) }
            }
        case "codes-match":
            hub.service.confirmKeyCode()
        case "codes-dont-match":
            hub.service.rejectKeyCode()
        case "remove-others":
            Task {
                for other in hub.service.otherDevices {
                    do {
                        try await hub.service.remove(other.id)
                        log.write("REMOVED \(other.name)")
                    } catch {
                        log.write("REMOVE \(other.name) failed: \(error.localizedDescription)")
                    }
                }
            }
        case "remove":
            // Settings › Account › Remove… for one named device.
            guard let target = hub.service.otherDevices.first(where: { $0.name.caseInsensitiveCompare(q["to"] ?? "") == .orderedSame }) else {
                log.write("REMOVE no device named \(q["to"] ?? "")")
                return true
            }
            Task {
                do {
                    try await hub.service.remove(target.id)
                    log.write("REMOVED \(target.name)")
                } catch {
                    log.write("REMOVE \(target.name) failed: \(error.localizedDescription)")
                }
            }
        case "askagain":
            Task {
                do { try await hub.service.requestKeyAgain() } catch { log.write("KEY ask again failed: \(error.localizedDescription)") }
            }
        case "type":
            typeText(q["text"] ?? "", submit: q["submit"] == "1", hub: hub, model: model, log: log)
        case "playhere":
            guard let suggestion = hub.banner else { log.write("TEST playhere: no banner"); return true }
            hub.playHere(from: suggestion.device.id)
        case "dismiss":
            hub.dismissBanner()
        case "send":
            guard let target = device(q["to"]) else { log.write("TEST send: no device"); return true }
            Task {
                if let message = await hub.send(to: target.id) { hub.message = message }
            }
        case "remote":
            guard let target = device(q["to"]) else { log.write("TEST remote: no device"); return true }
            let value = Double(q["v"] ?? "") ?? 0
            let action = q["do"] ?? "toggle"
            Task {
                let message = await hub.remote(target.id, action) { remote in
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
                hub.message = message
            }
        case "play":
            let query = q["ytm"] ?? "daft punk discovery"
            let seek = Double(q["seek"] ?? "") ?? 0
            Task { await playAlbum(query, seek: seek, model: model, log: log) }
        case "pause": player.pause()
        case "resume": player.resume()
        case "seek": player.seek(to: Double(q["v"] ?? "") ?? 0)
        case "crossfade":
            model.playback.settings.crossfadeSeconds = Double(q["v"] ?? "") ?? 0
            log.write("SET crossfade \(model.playback.settings.crossfadeSeconds) here")
        case "search":
            model.recordSearch(q["q"] ?? "")
        case "signin-test":
            guard let provider = ProviderID(rawValue: q["provider"] ?? ""), let transfer = hub.transfer(for: provider) else { return true }
            let payload = provider == .youtubeMusic ? YouTubeMusicSignInTransfer.testPayload(accountName: "\(ProductInfo.name) Test (Mac)") : SpotifySignInTransfer.testPayload()
            Task {
                do {
                    // As if the listener signed in on this Mac: the provider adopts it, and sign-in sync uploads it.
                    try await transfer.importSignIn(payload)
                    log.write("SIGNIN-TEST \(provider.rawValue) made here (\(payload.count) bytes); provider \(model.provider(provider)?.authStatus.logText ?? "-")")
                    await model.refreshLibraryState()
                } catch {
                    log.write("SIGNIN-TEST \(provider.rawValue) failed: \(error.localizedDescription)")
                }
            }
        case "signout":
            guard let provider = ProviderID(rawValue: q["provider"] ?? "") else { return true }
            Task { if let error = await hub.signOut(provider, everywhere: q["everywhere"] == "1") { log.write("SIGN-OUT failed: \(error)") } }
        case "signout-account":
            Task { await hub.signOutOfAccount() }
        case "screen":
            open(q["name"] ?? "", q: q, hub: hub, model: model)
        case "appearance":
            NSApp.appearance = NSAppearance(named: q["mode"] == "dark" ? .darkAqua : .aqua)
        case "shot":
            shot(q["name"] ?? "shot", which: q["w"] ?? "main", hub: hub, model: model, log: log)
        case "wake":
            // What macOS posts after sleep: the hub reconnects at once instead of waiting out a backoff.
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        case "drop":
            // A network loss: the socket drops and reconnects are refused for `s` seconds.
            let seconds = Double(q["s"] ?? "") ?? 5
            Task { await hub.service.client.simulateNetworkLoss(for: .seconds(seconds)) }
        case "network":
            // The path monitor's handler with a made-up path: on a move to other interfaces the hub replaces the socket.
            hub.networkChanged(satisfied: q["up"] != "0", interfaces: (q["if"] ?? "").split(separator: ",").map(String.init))
        case "status":
            status(hub, model: model, log: log)
        case "firstrun":
            firstRun(q, hub: hub, model: model, log: log)
        case "key":
            postKey(q["k"] ?? "", model: model, log: log)
        case "ax":
            axAudit(model: model, sheetOnly: q["scope"] == "sheet", log: log)
        case "window":
            // The main window's size in points (the flow at the window's minimum, 900 × 560).
            if let window = model.mainWindow, let w = Double(q["w"] ?? ""), let h = Double(q["h"] ?? "") {
                var frame = window.frame
                let content = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: w, height: h))
                frame.origin.y += frame.height - content.height
                frame.size = content.size
                window.requestFrame(frame, display: true)
                log.write("WINDOW \(Int(window.frame.width))×\(Int(window.contentLayoutRect.height)) content \(Int(window.contentView?.bounds.width ?? 0))×\(Int(window.contentView?.bounds.height ?? 0))")
            }
        default:
            log.write("TEST unknown \(command)")
        }
        return true
    }

    /// `firstrun?do=ACTION` presses the first-run flow's buttons; `firstrun?step=STEP` opens the flow at a step;
    /// `firstrun?server=TEXT` fills the server field. Typing goes through `type`, as a listener's keyboard.
    private static func firstRun(_ q: [String: String], hub: SyncHub, model: AppModel, log: SyncTestLog) {
        if let step = q["step"].flatMap(FirstRun.Step.init(rawValue:)) {
            if model.firstRun == nil { model.showOnboarding = true }
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
        case "close-signin": model.signInRequest = nil
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
        default: log.write("FIRSTRUN unknown \(action)")
        }
    }

    /// What VoiceOver finds in the main window (with its sheet): every button, link, text field and image with its
    /// label, and an `AX UNLABELED` line for any control without one.
    private static func axAudit(model: AppModel, sheetOnly: Bool = false, log: SyncTestLog) {
        var seen = 0, unlabeled: [String] = []
        // SwiftUI builds its accessibility tree for an assistive client: ask as one (the AX API, as VoiceOver does).
        do {
            let app = AXUIElementCreateApplication(getpid())
            func attribute(_ e: AXUIElement, _ name: String) -> AnyObject? {
                var value: AnyObject?
                return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
            }
            func walkAX(_ e: AXUIElement, depth: Int) {
                guard depth < 60 else { return }
                let role = attribute(e, kAXRoleAttribute) as? String ?? ""
                if ["AXButton", "AXLink", "AXTextField", "AXCheckBox", "AXPopUpButton"].contains(role) {
                    seen += 1
                    let label = [kAXDescriptionAttribute, kAXTitleAttribute, kAXPlaceholderValueAttribute]
                        .compactMap { attribute(e, $0) as? String }.first { !$0.isEmpty }
                    if let label { log.write("AX \(role) \"\(label)\"") } else { unlabeled.append(role) }
                }
                for child in attribute(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walkAX(child, depth: depth + 1) }
            }
            var trusted = "trusted"
            if attribute(app, kAXWindowsAttribute) == nil { trusted = "no answer (AX API not trusted?)" }
            for w in attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
                if sheetOnly {
                    // Only what is on the window's sheet or alert (`scope=sheet`).
                    for child in attribute(w, kAXChildrenAttribute) as? [AXUIElement] ?? [] where attribute(child, kAXRoleAttribute) as? String == "AXSheet" {
                        walkAX(child, depth: 0)
                    }
                } else {
                    walkAX(w, depth: 0)
                }
            }
            log.write("AX via the AX API: \(trusted)")
        }
        for role in unlabeled { log.write("AX UNLABELED \(role)") }
        log.write("AX audit: \(seen) controls, \(unlabeled.count) without a label; step \(model.firstRun?.step.rawValue ?? "closed")")
    }

    /// Tab, Shift-Tab, Return, Escape or ⌘[ through the event queue to the key window, as from the keyboard; then logs
    /// what has keyboard focus.
    private static func postKey(_ key: String, model: AppModel, log: SyncTestLog) {
        NSApp.activate()
        guard let window = NSApp.keyWindow ?? model.mainWindow else { log.write("KEY no window"); return }
        let (chars, code, flags): (String, UInt16, NSEvent.ModifierFlags) = switch key {
        case "tab": ("\t", 48, [])
        case "shift-tab": ("\u{19}", 48, [.shift])
        case "return": ("\r", 36, [])
        case "escape": ("\u{1b}", 53, [])
        case "cmd-[": ("[", 33, [.command])
        default: ("", 0, [])
        }
        guard !chars.isEmpty else { log.write("KEY unknown \(key)"); return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: chars,
                                            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                NSApp.postEvent(event, atStart: false)
            }
        }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            let responder = NSApp.keyWindow?.firstResponder
            var described = responder.map { String(describing: type(of: $0)) } ?? "none"
            if let editor = responder as? NSTextView, let field = editor.delegate as? NSTextField {
                described = "text field \"\(field.placeholderString ?? field.accessibilityLabel() ?? "")\""
            } else if let view = responder as? NSView {
                described += " \"\(view.accessibilityLabel() ?? view.accessibilityTitle() ?? "")\""
            }
            log.write("KEY \(key) → focus \(described); step \(model.firstRun?.step.rawValue ?? "closed")")
        }
    }

    private static func playAlbum(_ query: String, seek: TimeInterval, model: AppModel, log: SyncTestLog) async {
        guard let youtube = model.provider(.youtubeMusic) else { return }
        do {
            let results = try await youtube.search(query, scope: .all)
            guard let album = results.albums.first else { log.write("PLAY no album for \(query)"); return }
            let detail = try await youtube.album(id: album.providerID)
            model.play(detail.tracks, from: .init(title: album.title, route: .album(.youtubeMusic, id: album.providerID, preview: album)))
            log.write("PLAY \(album.title): \(detail.tracks.count) tracks, first \"\(detail.tracks.first?.title ?? "-")\"")
            guard seek > 0 else { return }
            for _ in 0..<150 where model.player.state != .playing { try? await Task.sleep(for: .milliseconds(100)) }
            model.player.seek(to: seek)
            log.write("PLAY seeked to \(fmt(seek)); state \(model.player.state.rawValue)")
        } catch {
            log.write("PLAY failed: \(error.localizedDescription)")
        }
    }

    private static func open(_ name: String, q: [String: String] = [:], hub: SyncHub, model: AppModel) {
        hub.isDevicesPresented = false
        hub.isSignInPresented = false
        hub.isServerPresented = false
        hub.signOutPrompt = nil
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            if name == "welcome" {
                model.showOnboarding = true
                return
            }
            switch name {
            case "close":
                settingsWindow()?.close()
            case "devices":
                settingsWindow()?.close()
                model.mainWindow?.makeKeyAndOrderFront(nil)
                hub.isDevicesPresented = true
            case "accounts", "playback":
                model.requestSettings(name == "accounts" ? .accounts : .playback)
                model.openSettingsAction?()
            case _ where name.hasPrefix("signout-"):
                model.requestSettings(.accounts)
                model.openSettingsAction?()
                try? await Task.sleep(for: .milliseconds(700))
                hub.signOutPrompt = ProviderID(rawValue: String(name.dropFirst("signout-".count)))
            default:
                model.requestSettings(.sync)
                model.openSettingsAction?()
                try? await Task.sleep(for: .milliseconds(700))
                switch name {
                case "signin": hub.isSignInPresented = true
                case "server": hub.isServerPresented = true
                default: break
                }
            }
        }
    }

    static func settingsWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && ($0.identifier?.rawValue.contains("Settings") == true || SettingsPane.allCases.map(\.title).contains($0.title)) }
    }

    /// Types into the field that has keyboard focus, through its field editor (what the keyboard's text goes to), and
    /// with `submit` presses Return through the event queue, which runs the field's `onSubmit`. Logs only how many
    /// characters went in, never the text.
    private static func typeText(_ text: String, submit: Bool, hub: SyncHub, model: AppModel, log: SyncTestLog) {
        NSApp.activate()
        let window = NSApp.keyWindow ?? settingsWindow()?.attachedSheet ?? model.mainWindow?.attachedSheet
        guard let window, let editor = window.firstResponder as? NSTextView else {
            log.write("TYPE no focused field (key window \(NSApp.keyWindow?.title ?? "none"))")
            return
        }
        editor.insertText(text, replacementRange: editor.selectedRange())
        log.write("TYPE \(text.count) characters\(submit ? " and Return" : "")")
        guard submit else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: "\r",
                                            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    /// Clicks the button titled `title` on the alert on screen (the "Allow …?" alert is an `NSAlert` sheet).
    private static func pressAlertButton(_ title: String, log: SyncTestLog) -> Bool {
        func buttons(in view: NSView) -> [NSButton] { ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons) }
        for window in NSApp.windows where window.isVisible && String(describing: type(of: window)).contains("AlertPanel") {
            guard let content = window.contentView, let button = buttons(in: content).first(where: { $0.title == title }) else { continue }
            button.performClick(nil)
            log.write("ALERT pressed \(title)")
            return true
        }
        log.write("ALERT none on screen; \(title) through the hub")
        return false
    }

    static func keyStatusText(_ status: SyncService.KeyStatus) -> String {
        switch status {
        case .comparing(let c): "comparing code \(c.code) with \(c.holderName) allowed=\(c.allowed) confirmed=\(c.confirmed)"
        case .failed(let why): "failed: \(why)"
        default: String(describing: status)
        }
    }

    private static func shot(_ name: String, which: String, hub: SyncHub, model: AppModel, log: SyncTestLog) {
        let shots = log.directory.appendingPathComponent("shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let window: NSWindow? = switch which {
        case "settings": settingsWindow()
        case "popover": NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
        case "sheet": (settingsWindow()?.attachedSheet ?? model.mainWindow?.attachedSheet)
        default: model.mainWindow // main, stack (with its sheet or alert)
        }
        guard let window else { log.write("SHOT \(name): no \(which) window"); return }
        window.displayIfNeeded()
        let url = shots.appendingPathComponent("\(name).png")
        if which == "stack", let image = WindowCapture.imageWithSheets(of: window) {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        } else if let image = WindowCapture.image(of: window, fullResolution: true) {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        } else if let view = window.contentView?.superview ?? window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        log.write("SHOT \(name) (\(which))")
    }

    private static func status(_ hub: SyncHub, model: AppModel, log: SyncTestLog) {
        let s = hub.service
        log.write("STATUS registered=\(s.isRegistered) key=\(s.keyStatus) requests=\(s.keyRequests.map { "\($0.device.name) \($0.code)" }) connection=\(s.connection.state) devices=\(s.devices.count) inUse=\(hub.isInUse)")
        // `connection` stops updating once the service stops, so ask the client itself too.
        Task { [client = s.client] in
            let live = await client.status
            log.write("  client socket \(live.state) (connections so far \(live.connections))")
        }
        for d in s.devices {
            let row = s.playback[d.id]
            log.write("  device \(d.name)\(d.id == s.selfID ? " (this Mac)" : "") \(s.isOnline(d) ? "online" : "offline") \(row.map { "\($0.anchor.isPlaying ? "playing" : "paused") \"\($0.track?.title ?? "(sealed)")\" at \(fmt(hub.coordinator.livePosition(of: d.id)))" } ?? "nothing loaded")")
        }
        let p = model.player
        log.write("  local \(p.state.rawValue) \"\(p.current?.title ?? "-")\" at \(fmt(p.currentTime)) index \(p.currentIndex ?? -1)/\(p.queue.count) volume \(model.playback.settings.volume)")
        for provider in model.providers {
            log.write("  sign-in \(provider.id.rawValue): \(provider.authStatus.logText); sync \(String(describing: s.signIns.status[provider.id]))")
        }
        let spotifyRecovery = (hub.transfer(for: .spotify) as? SpotifySignInTransfer)?.syncedSignIn != nil
        log.write("  spotify refresh recovery from the vault: \(spotifyRecovery ? "wired" : "missing"); keychain \(Keychain.backendName)")
        let st = model.playback.settings
        log.write("  settings crossfade=\(st.crossfadeSeconds) autoplay=\(st.autoplay) soundCheck=\(st.normalizeVolume) sleep=\(st.sleepTimerMinutes); recent searches \(model.recentSearches)")
        log.write("  banner \(hub.banner.map { "Continue from \($0.device.name): \($0.playback.track?.title ?? "(sealed)")" } ?? "none"); playerBanner \(model.playerBanner?.title ?? "none")")
    }
}
#endif
