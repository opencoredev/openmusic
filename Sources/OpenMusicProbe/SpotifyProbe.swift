import AppKit
import Foundation
import OpenMusicCore
import SpotifyKit
import SwiftUI

/// Probe commands for Spotify. Owned by the SpotifyKit worker.
///
///   openmusic-probe spotify auth-url                     authorize URL for the built-in client
///                                                     (env OPENMUSIC_SPOTIFY_CLIENT_ID + OPENMUSIC_SPOTIFY_REDIRECT for your own)
///   openmusic-probe spotify login [--open]               built-in sign-in: binds the loopback listener, prints the URL
///                                                     (or opens it), waits for the redirect, exchanges the code
///   openmusic-probe spotify render-views <dir>           PNGs of the sign-in sheet and settings states
///   openmusic-probe spotify lyrics "<title>" "<artist>" [album] [seconds]   LRCLIB, live
///   openmusic-probe spotify applescript-check [Spotify.app path]            Spotify.app + scripting dictionary check
///   openmusic-probe spotify me | search <q> | album <id> | artist <id> | playlist <id> | library <kind> | devices
///                                                     need env OPENMUSIC_SPOTIFY_TOKEN (an access token)
@MainActor
enum SpotifyProbe {
    static func run(_ args: [String]) async throws -> Int32 {
        guard let command = args.first else { return usage() }
        let rest = Array(args.dropFirst())
        switch command {
        case "auth-url": return authURL()
        case "login": return await login(rest)
        case "render-views": return renderViews(rest)
        case "lyrics": return try await lyrics(rest)
        case "applescript-check": return await appleScriptCheck(rest)
        case "app-state": return await appState()
        case "me", "search", "album", "artist", "playlist", "library", "devices", "home", "explore", "radio":
            return try await tokenCommand(command, rest)
        default: return usage()
        }
    }

    private static func usage() -> Int32 {
        print("""
        usage: openmusic-probe spotify <command>
          auth-url
          login [--open]       built-in sign-in through the loopback listener; prints the token's scopes, never the token
          render-views <dir>   PNGs of the sign-in sheet and Spotify settings
          lyrics "<title>" "<artist>" [album] [seconds]
          applescript-check [path/to/Spotify.app]
          app-state            reads Spotify.app's player through the same Apple Events the engine sends
          me | search <query> | album <id> | artist <id> | playlist <id> | library <likedSongs|albums|artists|playlists|recentlyPlayed> | devices | home | explore | radio <seedID>
            (token commands read OPENMUSIC_SPOTIFY_TOKEN)
        """)
        return 2
    }

    // MARK: auth-url

    private static func authURL() -> Int32 {
        let env = LaunchEnvironment.current
        let config: SpotifyAuthConfig
        if let clientID = env["OPENMUSIC_SPOTIFY_CLIENT_ID"], !clientID.isEmpty {
            let redirect = SpotifyRedirect(rawValue: env["OPENMUSIC_SPOTIFY_REDIRECT"] ?? "") ?? .loopback
            config = SpotifyAuthConfig(clientID: clientID, redirectURI: redirect.uri)
        } else {
            // The port the app tries first; it moves to a free one if that's busy.
            config = SpotifyAuthConfig(clientID: SpotifyBuiltInClient.clientID,
                                       redirectURI: SpotifyBuiltInClient.redirectURI(port: SpotifyBuiltInClient.preferredPort))
        }
        let pkce = PKCE()
        let url = config.authorizeURL(pkce: pkce, state: PKCE.randomState())
        print(url.absoluteString)
        print("")
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            print("  \(item.name) = \(item.value ?? "")")
        }
        print("  code_verifier (kept locally) = \(pkce.verifier.count) chars")
        let verified = PKCE.challenge(for: pkce.verifier) == pkce.challenge
        print("  challenge == BASE64URL(SHA256(verifier)): \(verified)")
        return verified ? 0 : 1
    }

    // MARK: login

    private static func login(_ args: [String]) async -> Int32 {
        let openBrowser = args.contains("--open")
        do {
            let token = try await SpotifyLoginCheck.run(open: { url in
                print("authorize URL:\n\(url.absoluteString)\n")
                print(openBrowser ? "Opening the default browser…" : "Listening. Open the URL above in a browser on this Mac.")
                fflush(stdout)
                return openBrowser ? NSWorkspace.shared.open(url) : true
            })
            print("signed in: token expires \(token.expiresAt), refresh token: \(token.refreshToken != nil), client: \(token.clientID ?? "-")")
            print("scopes: \(token.scope ?? "-")")
            return 0
        } catch {
            print("sign-in failed: \(error.localizedDescription)")
            return 1
        }
    }

    // MARK: render-views

    private static func renderViews(_ args: [String]) -> Int32 {
        guard let dir = args.first else {
            print("usage: render-views <dir>")
            return 2
        }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // Like the app: red system accent and a pink tint around everything. Spotify's views must not pick either up.
        UserDefaults.standard.register(defaults: ["AppleAccentColor": 0])
        _ = NSApplication.shared
        let states = SpotifyViewSnapshots.signInStates() + SpotifyViewSnapshots.settingsStates()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (name, view) in states {
                let width: CGFloat = name.hasPrefix("settings") ? 560 : 420
                let host = NSHostingView(rootView: view.tint(.pink).frame(width: width).fixedSize(horizontal: false, vertical: true)
                    .background(Color(nsColor: .windowBackgroundColor)))
                host.appearance = NSAppearance(named: appearance)
                let size = host.fittingSize
                host.frame = CGRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                let file = out.appendingPathComponent("\(name)-\(appearance == .aqua ? "light" : "dark").png")
                try? rep.representation(using: .png, properties: [:])?.write(to: file)
                print("\(file.path)  \(Int(size.width))x\(Int(size.height))")
            }
        }
        return 0
    }

    // MARK: lyrics

    private static func lyrics(_ args: [String]) async throws -> Int32 {
        guard args.count >= 2 else {
            print("usage: lyrics \"<title>\" \"<artist>\" [album] [seconds]")
            return 2
        }
        let album = args.count > 2 ? args[2] : nil
        let seconds = args.count > 3 ? TimeInterval(args[3]) : nil
        let started = Date()
        guard let lyrics = try await LRCLibClient().lyrics(title: args[0], artist: args[1], album: album, duration: seconds) else {
            print("no lyrics found")
            return 1
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        print("source: \(lyrics.source ?? "?")  synced: \(lyrics.isSynced)  lines: \(lyrics.lines.count)  (\(ms) ms)")
        for line in lyrics.lines.prefix(8) {
            let time = line.time.map { String(format: "%02d:%05.2f", Int($0) / 60, $0.truncatingRemainder(dividingBy: 60)) } ?? "     "
            print("  [\(time)] \(line.text)")
        }
        if lyrics.lines.count > 8 { print("  … \(lyrics.lines.count - 8) more") }
        return 0
    }

    // MARK: applescript-check

    private static func appleScriptCheck(_ args: [String]) async -> Int32 {
        var ok = true
        let installed = SpotifyAppBridge.appURL
        print("Spotify.app installed: \(installed?.path ?? "no")")
        print("Spotify.app running: \(SpotifyAppBridge.isRunning)")
        let appURL = args.first.map { URL(fileURLWithPath: $0) } ?? installed
        guard let appURL else {
            print("No Spotify.app to check against. Pass a path: applescript-check /path/to/Spotify.app")
            return 0
        }
        if let version = Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            print("Checking against \(appURL.path) (version \(version))")
        }

        // 1. Every Apple Event code OpenMusic sends exists in Spotify's scripting dictionary under the expected name.
        let sdefURL = appURL.appendingPathComponent("Contents/Resources/Spotify.sdef")
        if let data = try? Data(contentsOf: sdefURL) {
            let terms = SdefTerms.parse(data)
            for (kind, name, code) in SpotifyAppBridge.dictionaryCodes {
                let found = terms.contains { $0.kind == kind && $0.name == name && $0.code == code }
                ok = ok && found
                print("  \(found ? "ok " : "MISSING") \(kind) \"\(name)\" '\(code)'")
            }
        } else {
            ok = false
            print("  could not read \(sdefURL.path)")
        }

        // 2. The same commands compile as AppleScript against this Spotify.app.
        let body = SpotifyAppBridge.scriptEquivalents.map { "  \($0)" }.joined(separator: "\n")
        let source = "tell application \"\(appURL.path)\"\n\(body)\nend tell"
        if let script = NSAppleScript(source: source) {
            var error: NSDictionary?
            let compiled = script.compileAndReturnError(&error)
            ok = ok && compiled
            print("AppleScript compiles: \(compiled)\(error.map { " \($0)" } ?? "")")
        }

        // 3. Automation permission, without prompting.
        if SpotifyAppBridge.isRunning {
            let permission = await SpotifyAppBridge().permission(ask: false)
            print("Automation permission: \(permission.rawValue)")
        }
        print(ok ? "PASS" : "FAIL")
        return ok ? 0 : 1
    }

    // MARK: app-state

    private static func appState() async -> Int32 {
        guard SpotifyAppBridge.isRunning else {
            print("Spotify isn't running")
            return 1
        }
        let bridge = SpotifyAppBridge()
        print("Automation permission: \((await bridge.permission(ask: false)).rawValue)")
        do {
            let sample = try await bridge.sample()
            print("state: \(sample.state.rawValue)  track: \(sample.trackURI ?? "-")  position: \(sample.position)  duration: \(sample.duration.map { String($0) } ?? "-")")
            print("volume: \(try await bridge.volume())")
            return 0
        } catch {
            print("Apple Event failed: \(error.localizedDescription)")
            return 1
        }
    }

    // MARK: token commands

    private static func tokenCommand(_ command: String, _ args: [String]) async throws -> Int32 {
        let env = LaunchEnvironment.current
        guard let accessToken = env["OPENMUSIC_SPOTIFY_TOKEN"], !accessToken.isEmpty else {
            print("Set OPENMUSIC_SPOTIFY_TOKEN to a Spotify access token (for example from the \(ProductInfo.name) app or the Spotify console).")
            return 2
        }
        let token = SpotifyToken(accessToken: accessToken, refreshToken: nil, expiresAt: .distantFuture, scope: nil)
        let clientID = env["OPENMUSIC_SPOTIFY_CLIENT_ID"]
        let api = SpotifyAPI(tokenStore: MemoryTokenStore(token), clientID: { clientID })
        let service = SpotifyService(api: api)
        func need(_ n: Int) -> Bool {
            if args.count >= n { return true }
            print("missing argument")
            return false
        }

        switch command {
        case "me":
            let me = try await service.me()
            print("name: \(me.name)  detail: \(me.detail ?? "-")  avatar: \(me.avatar != nil)")
        case "search":
            guard need(1) else { return 2 }
            let results = try await service.search(args.joined(separator: " "), scope: .all)
            print("top: \(results.top.map(describe) ?? "-")")
            results.tracks.prefix(5).forEach { print("  song   \($0.title) — \($0.artistLine)") }
            results.albums.prefix(5).forEach { print("  album  \($0.title) — \($0.artistLine)") }
            results.artists.prefix(5).forEach { print("  artist \($0.name)") }
            results.playlists.prefix(5).forEach { print("  list   \($0.title)") }
        case "album":
            guard need(1) else { return 2 }
            let detail = try await service.album(id: args[0])
            print("\(detail.album.title) — \(detail.album.artistLine) [\(detail.album.kind.rawValue)]")
            print(detail.footnote ?? "")
            detail.tracks.forEach { print("  \($0.trackNumber ?? 0). \($0.title)") }
        case "artist":
            guard need(1) else { return 2 }
            let detail = try await service.artist(id: args[0])
            print("\(detail.artist.name)  followed: \(detail.isFollowed.map(String.init) ?? "-")")
            print("top songs: \(detail.topTracks.map(\.title).prefix(10).joined(separator: ", "))")
            print("albums: \(detail.albums.count)  singles: \(detail.singles.count)  appears on: \(detail.appearsOn.count)")
        case "playlist":
            guard need(1) else { return 2 }
            let detail = try await service.playlist(id: args[0])
            print("\(detail.playlist.title) by \(detail.playlist.owner ?? "-")  tracks: \(detail.playlist.trackCount ?? 0)  editable: \(detail.playlist.isEditable)")
            if detail.playlist.extra["itemsUnavailable"] != nil { print("(Spotify doesn't share this playlist's tracks with development-mode apps)") }
            detail.tracks.prefix(20).forEach { print("  \($0.title) — \($0.artistLine)") }
            print("more: \(detail.continuation != nil)")
        case "library":
            guard need(1), let kind = LibraryKind(rawValue: args[0]) else {
                print("kinds: \(LibraryKind.allCases.map(\.rawValue).joined(separator: ", "))")
                return 2
            }
            let page = try await service.library(kind, continuation: nil)
            page.items.prefix(20).forEach { print("  \(describe($0))") }
            print("items: \(page.items.count)  more: \(page.continuation != nil)")
        case "devices":
            let devices = try await service.devices()
            if devices.isEmpty { print("no devices (open Spotify somewhere)") }
            devices.forEach { print("  \($0.name) [\($0.type)] \($0.isActive ? "active" : "")") }
        case "home", "explore":
            let shelves = try await (command == "home" ? service.home() : service.explore())
            shelves.forEach { print("  \($0.title): \($0.items.count) items") }
        case "radio":
            guard need(1) else { return 2 }
            let tracks = try await service.radio(seedID: args[0])
            tracks.forEach { print("  \($0.title) — \($0.artistLine)") }
        default:
            return usage()
        }
        return 0
    }

    private static func describe(_ item: MediaItem) -> String {
        switch item {
        case .track(let t): "song \(t.title) — \(t.artistLine)"
        case .album(let a): "album \(a.title) — \(a.artistLine)"
        case .artist(let a): "artist \(a.name)"
        case .playlist(let p): "playlist \(p.title)"
        }
    }
}

/// Reads command/property/enumerator names and codes out of an .sdef.
private final class SdefTerms: NSObject, XMLParserDelegate {
    struct Term { var kind: String; var name: String; var code: String }
    private var terms: [Term] = []

    static func parse(_ data: Data) -> [Term] {
        let collector = SdefTerms()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false
        parser.parse()
        return collector.terms
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        guard ["command", "property", "enumerator"].contains(element), let name = attributes["name"], let code = attributes["code"] else { return }
        terms.append(Term(kind: element, name: name, code: code))
    }
}
