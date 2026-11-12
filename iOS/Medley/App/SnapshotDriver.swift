import MediaPlayer
import MedleyCore
import MedleySync
import SwiftUI
import UIKit

// Screenshots and the live check exist only in Debug builds: Release has no code that a launch argument or a saved
// default could switch on.
#if DEBUG
/// Opens one screen in a fixed state for screenshots: `-MedleyMock YES -MedleyScreen <name>`.
/// `scripts/ios.sh <slot> snapshots` launches the app once per screen and appearance and captures it.
///
/// Screens: home, new, library, library-liked, library-songs, library-albums, library-artists, library-playlists,
/// library-playlist, library-signedout (with `-MedleySignedOut YES`), search,
/// search-recent, search-empty, album, artist, playlist, shelf, error, nowplaying, nowplaying-long (a title too long
/// for one line, which scrolls), lyrics, queue, settings, signin.
@MainActor
struct SnapshotDriver {
    let model: AppModel

    static let screens = ["home", "new", "library", "library-liked", "library-songs", "library-albums", "library-artists",
                          "library-playlists", "library-playlist", "library-signedout", "search", "search-recent", "search-empty",
                          "album", "artist", "playlist", "shelf", "error", "nowplaying", "nowplaying-long", "lyrics", "queue", "settings", "signin",
                          "welcome", "welcome-signin", "account-signedout", "account-comparing", "account-allowed", "account-outdated", "account", "allow-device"]

    func run(_ screen: String) async {
        let catalog = (model.providers.first as? MockProvider)?.catalog
        let demo = (model.providers.first as? MockProvider)?.demoNowPlaying
        if let demo {
            // The demo: "the cure" playing, started a few seconds early so it reads about 1:12 when captured.
            model.play(demo.tracks, startAt: demo.index, from: .album(demo.album))
            try? await Task.sleep(for: .milliseconds(150))
            model.player.seek(to: demo.position - 3)
            if !["nowplaying", "lyrics", "queue"].contains(screen) { model.player.pause() }
        } else if let catalog, let album = catalog.albums.first, let tracks = catalog.albumTracks[album.providerID] {
            // Something in the mini player on every screen, paused at a fixed point so captures match.
            model.play(tracks, startAt: 1, from: .album(album))
            try? await Task.sleep(for: .milliseconds(150))
            model.player.pause()
            model.player.seek(to: 74)
        }
        let path: (Route) -> Void = { model.paths[model.tab, default: []].append($0) }
        switch screen {
        case "new": model.tab = .new
        case "library", "library-signedout": model.tab = .library
        case "library-liked":
            model.tab = .library
            path(.library(.likedSongs))
        case "library-songs", "library-albums", "library-artists", "library-playlists":
            model.tab = .library
            let kinds: [String: LibraryKind] = ["library-songs": .songs, "library-albums": .albums, "library-artists": .artists, "library-playlists": .playlists]
            if let kind = kinds[screen] { path(.library(kind)) }
        case "search":
            model.tab = .search
            let name = catalog?.artists.first?.name.split(separator: " ").first.map(String.init) ?? "daft punk"
            model.submitSearch(name)
        case "search-recent": model.tab = .search
        case "search-empty":
            model.tab = .search
            model.submitSearch("zzqxv")
        case "album": if let a = demo?.album ?? catalog?.albums.first(where: { $0.kind == .album }) { path(.album(a)) }
        case "artist": if let a = catalog?.artists.first { path(.artist(a)) }
        case "playlist": if let p = catalog?.playlists.first { path(.playlist(p)) }
        case "library-playlist":
            // One of the listener's own playlists, opened from Library.
            model.tab = .library
            if let p = catalog?.playlists.first { path(.playlist(p)) }
        case "shelf":
            if let shelf = try? await model.providers.first?.home().first(where: { $0.style == .carousel }) { path(.shelf(shelf, .youtubeMusic)) }
        case "error":
            path(.album(Album(providerID: "missing", provider: .youtubeMusic, title: "Missing Album")))
        case "nowplaying":
            model.player.resume()
            model.presentNowPlaying(.artwork)
        case "nowplaying-long":
            if var track = model.player.current {
                track.title = "One More Time (Radio Edit) [2026 Remaster]"
                model.play([track], from: nil)
                try? await Task.sleep(for: .milliseconds(150))
                model.player.pause()
            }
            model.presentNowPlaying(.artwork)
        case "lyrics":
            model.presentNowPlaying(.lyrics)
        case "queue":
            model.presentNowPlaying(.queue)
        case "welcome", "welcome-signin", "account-signedout", "account-comparing", "account-allowed", "account-outdated", "account", "allow-device":
            await account(screen)
        case "settings":
            // Signed in to a Medley account too, as a listener who set it up would see Settings.
            await account(screen)
            model.isSettingsPresented = true
        case "signin": model.signInProvider = .youtubeMusic
        default: model.tab = .home
        }
    }

    /// The Medley account screens with a hub that never connects and made-up devices.
    private func account(_ screen: String) async {
        #if DEBUG
        let hub = SyncHub.preview(model: model)
        model.usePreviewSync(hub)
        let now = Date().timeIntervalSince1970 * 1000
        let phone = SyncDevice(id: DeviceID("phone"), name: "Riley's iPhone", platform: .ios, model: "iPhone18,1", appVersion: "1.0",
                               createdAt: now, lastSeenAt: now, keyState: .holder)
        let mac = SyncDevice(id: DeviceID("mac"), name: "Studio Mac", platform: .mac, model: "Mac16,10", appVersion: "1.0",
                             createdAt: now, lastSeenAt: now, keyState: .holder)
        let ipad = SyncDevice(id: DeviceID("ipad"), name: "Riley's iPad", platform: .ios, model: "iPad16,3", appVersion: "1.0",
                              createdAt: now, lastSeenAt: now, keyState: .requested, publicKey: DeviceKeyPair.generate().publicKey)
        // The iPad asks this iPhone (a holder); this iPhone, asking, compares with the Mac.
        let request = SyncService.KeyRequest(device: ipad, code: "305 118", commitment: "preview")
        let comparing = SyncService.KeyComparison(code: "482 913", holderID: mac.id, holderName: mac.name, allowed: false, confirmed: false)
        let previewUser = ClerkUser(id: "user_preview", firstName: "Riley", lastName: "Calder", email: "riley@example.com")
        switch screen {
        case "welcome", "welcome-signin":
            hub.account.preview(user: nil)
            model.firstRun = FirstRunFlow(model: model, path: screen == "welcome" ? [] : [.music, .sync])
        case "account-signedout":
            hub.account.preview(user: nil)
            model.settingsPath = [.sync]
            model.isSettingsPresented = true
        case "account-comparing", "account-allowed":
            hub.account.preview(user: previewUser)
            var state = comparing
            state.allowed = screen == "account-allowed"
            hub.service.preview(selfID: phone.id, devices: [phone, mac], keyStatus: .comparing(state))
            model.settingsPath = [.sync]
            model.isSettingsPresented = true
        case "account-outdated":
            // Back after missing two rotations: this iPhone keeps its old key until the listener asks again.
            hub.account.preview(user: previewUser)
            var behind = phone
            behind.keyState = .requested
            hub.service.preview(selfID: phone.id, devices: [behind, mac], keyStatus: .outdated)
            model.settingsPath = [.sync]
            model.isSettingsPresented = true
        case "account", "settings":
            hub.account.preview(user: previewUser)
            hub.service.preview(selfID: phone.id, devices: [phone, mac], keyStatus: .available)
            if screen == "account" {
                model.settingsPath = [.sync]
                model.isSettingsPresented = true
            }
        default:
            hub.account.preview(user: previewUser)
            hub.service.preview(selfID: phone.id, devices: [phone, mac, ipad], keyStatus: .available, requests: [request])
        }
        if screen == "welcome-signin-sheet" {
            // The Sign In sheet from Settings › Account.
            try? await Task.sleep(for: .milliseconds(600))
            model.settingsPath = [.sync]
            model.isSettingsPresented = true
            try? await Task.sleep(for: .milliseconds(700))
            hub.isSignInPresented = true
        }
        #endif
    }
}

/// The live check against YouTube Music: `-MedleySelfTest live`. Writes one line per step to
/// `Documents/selftest.log` in the app's container (`scripts/ios.sh <slot> selftest` reads it back),
/// then logs a heartbeat for a minute so backgrounding can be checked from outside.
@MainActor
struct SelfTest {
    let model: AppModel
    private let log = SelfTestLog()

    func run() async {
        log.write("start \(Date().formatted(.iso8601))")
        let player = model.player
        do {
            // 1. Home
            let shelves = try await model.cached("home", force: true) { try await loadShelves(model, .home) }
            log.check("home", shelves.count > 0, "\(shelves.count) shelves, first \"\(shelves.first?.title ?? "-")\"")

            // 2. Search
            model.tab = .search
            model.submitSearch("daft punk")
            let results = try await model.search("daft punk", scope: .all)
            log.check("search", !results.isEmpty, "top \(results.top?.title ?? "-"), \(results.tracks.count) songs, \(results.albums.count) albums, \(results.artists.count) artists")

            // 3. Album
            guard let album = results.albums.first(where: { $0.title.localizedCaseInsensitiveContains("Discovery") }) ?? results.albums.first,
                  let provider = model.provider(album.provider) else { return log.check("album", false, "no album in results") }
            model.open(.album(album))
            let detail: AlbumDetail = try await model.cached("album:\(album.id)") { try await provider.album(id: album.providerID) }
            log.check("album", !detail.tracks.isEmpty, "\(album.title): \(detail.tracks.count) tracks")

            // 4. Play, time advances
            model.play(detail.tracks, from: .album(album))
            let started = await wait(30) { player.state == .playing && player.currentTime > 1.5 }
            let t1 = player.currentTime
            try? await Task.sleep(for: .seconds(3))
            let t2 = player.currentTime
            log.check("play", started && t2 > t1 + 1.5, "\(player.current?.title ?? "-") state=\(player.state.rawValue) t \(fmt(t1)) -> \(fmt(t2))")

            // 5. Next
            let before = player.currentIndex ?? 0
            player.next()
            let advanced = await wait(30) { player.currentIndex == before + 1 && player.state == .playing && player.currentTime > 1 }
            log.check("next", advanced, "index \(before) -> \(player.currentIndex ?? -1), \(player.current?.title ?? "-") t=\(fmt(player.currentTime))")

            // 6. Now Playing info and audio session
            _ = await wait(8) { MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] != nil }
            let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            let title = info[MPMediaItemPropertyTitle] as? String
            let rate = info[MPNowPlayingInfoPropertyPlaybackRate] as? Double
            let hasArtwork = info[MPMediaItemPropertyArtwork] != nil
            log.check("nowplaying-info", title == player.current?.title && rate == 1,
                      "title=\(title ?? "-") artist=\(info[MPMediaItemPropertyArtist] as? String ?? "-") rate=\(rate ?? -1) duration=\(info[MPMediaItemPropertyPlaybackDuration] as? Double ?? -1) artwork=\(hasArtwork)")
            let session = model.playback.audioSession
            log.check("audio-session", session.category == .playback && session.isActive, "category=\(session.category.rawValue) active=\(session.isActive)")
            let commands = MPRemoteCommandCenter.shared()
            log.check("remote-commands", commands.playCommand.isEnabled && commands.pauseCommand.isEnabled && commands.nextTrackCommand.isEnabled && commands.changePlaybackPositionCommand.isEnabled,
                      "play/pause/next/seek enabled")

            // 7. Lyrics on a song that has them
            let songs = try await model.search("One More Time Daft Punk", scope: .songs)
            guard let song = songs.tracks.first(where: { $0.title.localizedCaseInsensitiveContains("One More Time") }) else {
                return log.check("lyrics", false, "song not found")
            }
            model.play([song], from: PlaybackContext(kind: .search, title: "One More Time"))
            _ = await wait(30) { player.current?.id == song.id && player.state == .playing && player.currentTime > 1 }
            let lyrics = try await model.lyrics(for: song)
            log.check("lyrics", (lyrics?.lines.count ?? 0) > 0,
                      "\(song.title): \(lyrics?.lines.count ?? 0) lines, synced=\(lyrics?.isSynced ?? false), source=\(lyrics?.source ?? "-")")
            model.presentNowPlaying(.lyrics)
            log.write("screen lyrics-open")
        } catch {
            log.check("error", false, error.localizedDescription)
        }

        // 8. Heartbeat for backgrounding: the script sends the app to the background and brings it back.
        for _ in 0..<45 {
            let state = switch UIApplication.shared.applicationState {
            case .active: "active"
            case .inactive: "inactive"
            case .background: "background"
            @unknown default: "unknown"
            }
            log.write("hb app=\(state) player=\(player.state.rawValue) t=\(fmt(player.currentTime)) track=\(player.current?.title ?? "-")")
            try? await Task.sleep(for: .seconds(2))
        }
        log.write("done")
    }

    private func wait(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return condition()
    }

    private func fmt(_ t: TimeInterval) -> String { String(format: "%.1f", t) }
}

@MainActor
private final class SelfTestLog {
    let url: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("selftest.log")
    }()

    init() { try? Data().write(to: url) }

    func check(_ step: String, _ ok: Bool, _ detail: String) {
        write("\(ok ? "PASS" : "FAIL") \(step): \(detail)")
    }

    func write(_ line: String) {
        print("[selftest] \(line)")
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    }
}
#endif
