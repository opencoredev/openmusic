import AppKit
import Foundation
import MedleyCore
import SwiftUI
import YouTubeMusicKit

/// Probe commands for YouTube Music. Owned by the YouTubeMusicKit worker.
///
///   medley-probe ytm search <query> [all|songs|albums|artists|playlists]
///   medley-probe ytm suggest <query>
///   medley-probe ytm link <videoId>   (album and artist links for a song)
///   medley-probe ytm home | explore | more <moreToken>
///   medley-probe ytm album <MPREb_id> | artist <UC id> | playlist <id> [--all]
///   medley-probe ytm radio <videoId> | radio-seed <artist/playlist id>
///   medley-probe ytm lyrics <videoId>
///   medley-probe ytm stream <videoId>
///   medley-probe ytm play <videoId> [seconds] [--seek-mid]
///   medley-probe ytm signin-check [snapshot.png]
///   medley-probe ytm browser-logins   (browsers signed in to YouTube; names only, no keychain access)
///   MEDLEY_STORAGE_PASSWORD=... medley-probe ytm browser-decrypt-check <Cookies db>   (counts only)
///   MEDLEY_YTM_COOKIE='...' medley-probe ytm accounts [--list]   (the sign-in account step; --list skips the
///       selected-channel shortcut and shows the whole picker)
///   MEDLEY_YTM_COOKIE='...' medley-probe ytm whoami | library <likedSongs|songs|albums|artists|playlists|recentlyPlayed>
@MainActor
enum YouTubeMusicProbe {
    static func run(_ args: [String]) async throws -> Int32 {
        guard let command = args.first else { return usage() }
        let rest = Array(args.dropFirst())
        let provider = YouTubeMusicProvider()
        let started = Date()
        defer { print(String(format: "(%.2fs)", Date().timeIntervalSince(started))) }

        switch command {
        case "search":
            guard let q = rest.first else { return usage() }
            let scope = rest.dropFirst().first.flatMap(SearchScope.init(rawValue:)) ?? .all
            let r = try await provider.search(q, scope: scope)
            if let top = r.top { print("top: \(describe(top))") }
            section("songs", r.tracks.map(describe))
            section("albums", r.albums.map(describe))
            section("artists", r.artists.map(describe))
            section("playlists", r.playlists.map(describe))

        case "suggest":
            guard let q = rest.first else { return usage() }
            let s = try await provider.richSearchSuggestions(q)
            for q in s.queries { print("  \(q)") }
            section("direct matches", s.items.map(describe))

        case "link":
            guard let id = rest.first else { return usage() }
            let t = try await provider.linkedTrack(Track(providerID: id, provider: .youtubeMusic, title: "?"))
            print(describe(t))
            print("  album id: \(t.album?.id ?? "-")  artist ids: \(t.artists.map { $0.id ?? "-" }.joined(separator: ", "))")

        case "home", "explore":
            let shelves = command == "home" ? try await provider.home() : try await provider.explore()
            for shelf in shelves { printShelf(shelf) }

        case "more":
            guard let token = rest.first else { return usage() }
            printShelf(try await provider.shelf(moreToken: token), limit: 50)

        case "album":
            guard let id = rest.first else { return usage() }
            let d = try await provider.album(id: id)
            print("\(d.album.title) — \(d.album.artistLine) [\(d.album.kind.rawValue)\(d.album.year.map { ", \($0)" } ?? "")]")
            print("  footnote: \(d.footnote ?? "-")  playlistId: \(d.album.extra["playlistId"] ?? "-")  art: \(artSummary(d.album.artwork))")
            if let s = d.summary { print("  about: \(s.prefix(100))…") }
            for t in d.tracks { print("  \(t.trackNumber.map { String(format: "%2d", $0) } ?? "  "). \(describe(t))") }
            section("more by artist", d.moreByArtist.map(describe))

        case "artist":
            guard let id = rest.first else { return usage() }
            let d = try await provider.artist(id: id)
            print("\(d.artist.name) — \(d.artist.subtitle ?? "")  radioSeed: \(d.radioSeed ?? "-")  followed: \(d.isFollowed.map(String.init) ?? "-")  art: \(artSummary(d.artist.artwork))")
            if let bio = d.bio { print("  bio: \(bio.prefix(100))…") }
            section("top songs", d.topTracks.map(describe))
            section("albums", d.albums.map(describe))
            section("singles", d.singles.map(describe))
            section("playlists", d.playlists.map(describe))
            section("related", d.related.map(describe))

        case "playlist":
            guard let id = rest.first else { return usage() }
            let d = try await provider.playlist(id: id)
            print("\(d.playlist.title) — \(d.playlist.owner ?? "-")  count: \(d.playlist.trackCount.map(String.init) ?? "-")  editable: \(d.playlist.isEditable)  art: \(artSummary(d.playlist.artwork))")
            var tracks = d.tracks
            var token = d.continuation
            var pages = 1
            if rest.contains("--all") {
                while let next = token, pages < 100 {
                    let page = try await provider.playlistTracks(continuation: next)
                    print("  continuation page \(pages): +\(page.items.count) tracks")
                    tracks += page.items
                    token = page.continuation
                    pages += 1
                }
            }
            print("  \(tracks.count) tracks loaded in \(pages) page(s); more: \(token != nil)")
            for (i, t) in tracks.enumerated() where i < 5 || i >= tracks.count - 3 {
                print("  \(String(format: "%3d", i + 1)). \(describe(t))")
            }

        case "radio":
            guard let id = rest.first else { return usage() }
            let seed = Track(providerID: id, provider: .youtubeMusic, title: id)
            let tracks = try await provider.radio(seed: seed)
            print("radio for \(id): \(tracks.count) tracks")
            for t in tracks.prefix(12) { print("  \(describe(t))") }

        case "radio-seed":
            guard let id = rest.first else { return usage() }
            let tracks = try await provider.radio(seedID: id)
            print("radio from \(id): \(tracks.count) tracks")
            for t in tracks.prefix(12) { print("  \(describe(t))") }

        case "lyrics":
            guard let id = rest.first else { return usage() }
            let track = Track(providerID: id, provider: .youtubeMusic, title: id)
            guard let lyrics = try await provider.lyrics(for: track) else { print("no lyrics"); return 0 }
            print("synced: \(lyrics.isSynced)  lines: \(lyrics.lines.count)  source: \(lyrics.source ?? "-")")
            for line in lyrics.lines.filter({ !$0.text.isEmpty }).prefix(10) {
                print("  \(line.time.map { String(format: "[%06.2f]", $0) } ?? "        ") \(line.text)")
            }

        case "stream":
            guard let id = rest.first else { return usage() }
            let r = try await provider.streamResolver.resolve(videoId: id)
            print("client: \(r.client)  itag: \(r.itag.map(String.init) ?? "-")  mime: \(r.stream.mimeType ?? "-")  bitrate: \(r.stream.bitrate.map(String.init) ?? "-")")
            print("host: \(r.stream.url.host ?? "-")  loudnessDb: \(r.stream.loudnessDB.map { String(format: "%.2f", $0) } ?? "-")  expires: \(r.stream.expiresAt.map { ISO8601DateFormatter().string(from: $0) } ?? "-")")

        case "play":
            guard let id = rest.first else { return usage() }
            let seconds = rest.dropFirst().first.flatMap(Double.init) ?? 20
            return try await play(provider: provider, videoId: id, seconds: seconds, seekMid: rest.contains("--seek-mid"))

        case "signin-check":
            let snapshotPath = rest.first
            guard let report = await YTMSignInCheck.run(snapshot: snapshotPath != nil) else { print("sign-in page did not load"); return 1 }
            if let snapshotPath, let png = report.snapshotPNG {
                try png.write(to: URL(fileURLWithPath: snapshotPath))
                print("snapshot: \(snapshotPath)")
            }
            print("url: \(report.finalURL.prefix(90))")
            print("title: \(report.title)")
            print("headline: \(report.headline)")
            print("email field: \(report.hasEmailField)  insecure-browser warning: \(report.showsInsecureBrowserWarning)")
            return report.hasEmailField && !report.showsInsecureBrowserWarning ? 0 : 1

        case "browser-logins":
            let scan = BrowserLogins.scan()
            print("default browser: \(scan.defaultBrowserName ?? "-")  readable: \(scan.defaultBrowser != nil)  needs sign-in: \(scan.defaultBrowserNeedsSignIn)")
            for login in scan.logins { print("  \(login.browser.name)  \(login.profileDirectory)  \(login.profileName ?? "")") }
            if scan.logins.isEmpty { print("  (no browser signed in to YouTube)") }

        case "render-signin":
            guard let dir = rest.first else { return usage() }
            let out = URL(fileURLWithPath: dir, isDirectory: true)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            _ = NSApplication.shared
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for (name, view) in YTMViewSnapshots.signInStates() {
                    let host = NSHostingView(rootView: view.fixedSize().background(Color(nsColor: .windowBackgroundColor)))
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
                    print("\(file.lastPathComponent)  \(Int(size.width))x\(Int(size.height))")
                }
            }

        case "browser-decrypt-check":
            guard let path = rest.first, let password = ProcessInfo.processInfo.environment["MEDLEY_STORAGE_PASSWORD"] else { return usage() }
            let result = try BrowserLogins.decryptCheck(cookiesDB: URL(fileURLWithPath: path), password: password)
            print("db version: \(result.version)  encrypted cookies: \(result.total)  decrypted with host check: \(result.decrypted)")
            return result.total > 0 && result.decrypted == result.total ? 0 : 1

        case "whoami", "library":
            guard let cookie = ProcessInfo.processInfo.environment["MEDLEY_YTM_COOKIE"], !cookie.isEmpty else {
                print("set MEDLEY_YTM_COOKIE to a music.youtube.com Cookie header")
                return 2
            }
            try await provider.signIn(cookieHeader: cookie, persist: false)
            if case .signedIn(let info) = provider.authStatus { print("signed in as \(info.name) (\(info.detail ?? "-"))") }
            if command == "library" {
                let kind = rest.first.flatMap(LibraryKind.init(rawValue:)) ?? .likedSongs
                let page = try await provider.library(kind, continuation: nil)
                print("\(kind.rawValue): \(page.items.count) items; more: \(page.continuation != nil)")
                for item in page.items.prefix(20) { print("  \(describe(item))") }
            }

        case "accounts":
            guard let cookie = ProcessInfo.processInfo.environment["MEDLEY_YTM_COOKIE"], !cookie.isEmpty else {
                print("set MEDLEY_YTM_COOKIE to a music.youtube.com Cookie header")
                return 2
            }
            let found = try await provider.diagnosticSignIn(cookieHeader: cookie, preferSelected: !rest.contains("--list"))
            print("picker: \(found.accounts.count) account(s), authoritative: \(found.authoritative)")
            for account in found.accounts {
                let kind = account.identity.delegatedSessionId == nil ? "account" : "channel"
                print("  \(account.identity.isSelected ? "*" : " ") [\(kind) au=\(account.identity.authUser)] \(account.info.name) (\(account.info.detail ?? "-"))")
            }
            if case .signedIn(let info) = provider.authStatus { print("signed in as \(info.name) (\(info.detail ?? "-"))") }
            let liked = try await provider.library(.likedSongs, continuation: nil)
            print("liked songs: \(liked.items.count) on the first page")
            for item in liked.items.prefix(3) { print("  \(describe(item))") }

        case "raw":
            guard rest.count >= 2 else { return usage() }
            print(try await provider.diagnosticRequest(endpoint: rest[0], bodyJSON: rest[1]))

        default:
            return usage()
        }
        return 0
    }

    // MARK: play

    static func play(provider: YouTubeMusicProvider, videoId: String, seconds: Double, seekMid: Bool) async throws -> Int32 {
        let engine = provider.playbackEngine
        final class Box { var state = PlaybackState.idle; var failure: String? }
        let box = Box()
        engine.onEvent = { event in
            switch event {
            case .state(let s): if s != box.state { box.state = s; print("  state → \(s.rawValue)") }
            case .failed(let msg): box.failure = msg; print("  failed: \(msg)")
            case .finished: print("  finished")
            case .time: break
            }
        }
        let track = Track(providerID: videoId, provider: .youtubeMusic, title: videoId)
        let r = try await provider.streamResolver.resolve(videoId: videoId)
        print("stream: \(r.client) itag \(r.itag.map(String.init) ?? "-") \(r.stream.mimeType ?? "")")
        engine.volume = 0.2
        try await engine.load(track, startAt: 0, autoplay: true)
        var seeked = false
        let start = Date()
        var tick = 0
        while Date().timeIntervalSince(start) < seconds, box.failure == nil {
            // Async main runs the main CFRunLoop, so AVPlayer callbacks keep arriving while we sleep.
            try? await Task.sleep(for: .seconds(1))
            tick += 1
            print(String(format: "  t+%02ds  state=%@  currentTime=%.1f  duration=%@", tick, box.state.rawValue, engine.currentTime,
                         engine.duration.map { String(format: "%.0f", $0) } ?? "-"))
            if seekMid, !seeked, tick == 5, let d = engine.duration {
                seeked = true
                print(String(format: "  seeking to %.0f (middle)", d / 2))
                engine.seek(to: d / 2)
            }
        }
        engine.stop()
        return box.failure == nil ? 0 : 1
    }

    // MARK: Formatting

    static func usage() -> Int32 {
        print("usage: medley-probe ytm <search|suggest|home|explore|more|album|artist|playlist|radio|radio-seed|lyrics|stream|play|signin-check|whoami|library> [args]")
        return 2
    }

    static func section(_ title: String, _ lines: [String], limit: Int = 6) {
        guard !lines.isEmpty else { return }
        print("\(title) (\(lines.count)):")
        for line in lines.prefix(limit) { print("  \(line)") }
    }

    static func printShelf(_ shelf: Shelf, limit: Int = 5) {
        let more = shelf.moreToken.map { "  more: \($0.prefix(60))" } ?? ""
        print("[\(shelf.style.rawValue)] \(shelf.subtitle.map { "\($0) / " } ?? "")\(shelf.title) (\(shelf.items.count))\(more)")
        for item in shelf.items.prefix(limit) { print("    \(describe(item))") }
    }

    static func describe(_ item: MediaItem) -> String {
        switch item {
        case .track(let t): "♪ " + describe(t)
        case .album(let a): "◎ " + describe(a)
        case .artist(let a): "☺ " + describe(a)
        case .playlist(let p): "≡ " + describe(p)
        }
    }

    static func describe(_ t: Track) -> String {
        let d = t.duration.map { String(format: "%d:%02d", Int($0) / 60, Int($0) % 60) } ?? "-"
        let album = t.album.map { " · \($0.title)" } ?? ""
        let flags = (t.isExplicit ? " [E]" : "") + (t.isPlayable ? "" : " [unplayable]")
        return "\(t.title) — \(t.artistLine)\(album) (\(d)) [\(t.providerID)]\(flags)"
    }

    static func describe(_ a: Album) -> String {
        "\(a.title) — \(a.artistLine) \(a.year.map(String.init) ?? "") \(a.kind.rawValue) [\(a.providerID)]"
    }

    static func describe(_ a: Artist) -> String { "\(a.name) — \(a.subtitle ?? "") [\(a.providerID)]" }

    static func describe(_ p: Playlist) -> String {
        "\(p.title) — \(p.owner ?? "-")\(p.trackCount.map { " · \($0) tracks" } ?? "") [\(p.providerID.prefix(48))]"
    }

    static func artSummary(_ art: Artwork?) -> String {
        guard let art else { return "none" }
        return art.images.compactMap(\.width).map(String.init).joined(separator: "/")
    }
}
