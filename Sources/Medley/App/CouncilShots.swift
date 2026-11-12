#if DEBUG
import AppKit
import SwiftUI
import MedleyCore

/// `MEDLEY_MOCK=demo MEDLEY_DEMO_ART=<dir> MEDLEY_SNAPSHOT_DIR=<dir> MEDLEY_SNAPSHOT_ONLY=council`: the screens a panel
/// of reviewers grades (scripts/council-shots.sh). Same data as DemoShots (real chart albums, the made-up listener,
/// "the cure" playing 1:12 in), every main screen in light and dark, captured without the window shadow at the
/// screen's full density. Writes `<name>-<light|dark>.png`, `council.txt` (a log) and `manifest.tsv`
/// (name, then one line on what the shot shows) for the contact sheet and index.
///
/// `MEDLEY_DEMO_SIZE=1440x900` sets the main window size in points; `MEDLEY_COUNCIL_SHOTS=home,album` limits the shots.
@MainActor
struct CouncilShots {
    let model: AppModel
    let window: NSWindow
    let dir: URL
    let yt: MockProvider
    let sp: MockProvider

    private struct Shot {
        let name: String
        let about: String
        /// Sets the screen up. Returns extra windows to composite over the main window (a sheet), or a window to
        /// capture instead of it (Settings, the mini player).
        let apply: @MainActor () async -> Target
        /// Undo anything the next shot shouldn't inherit.
        var reset: (@MainActor () async -> Void)?
    }

    private enum Target {
        case main
        case window(NSWindow?)
        /// The main window with a pointer drawn at this point (top-left window coordinates) for hover states.
        case mainWithPointer(CGPoint)
        /// The main window cropped to its left `width` points (the sidebar), with an optional pointer.
        case sidebarCrop(width: CGFloat, pointer: CGPoint?)
        /// The main window with its attached sheet drawn where it sits.
        case mainWithSheet
        /// The main window with the app's open menu (a pop-up from a menu button) drawn where it sits.
        case mainWithMenu
        /// Another window (the mini player) with the app's open menu drawn where it sits.
        case windowWithMenu(NSWindow?)
    }

    func run() async {
        var log: [String] = []
        var manifest: [String] = []
        // What the queue was before `playing-next-cleared` pressed Clear, for its ⌘Z check.
        var queueBeforeClear: [UUID] = []
        var pendingRequestsBefore: [Int] = []
        var currentBeforeClear: UUID?
        let env = ProcessInfo.processInfo.environment
        let size = (env["MEDLEY_DEMO_SIZE"] ?? "1440x900").split(separator: "x").compactMap { Double($0) }
        let (w, h) = size.count == 2 ? (size[0], size[1]) : (1440, 900)

        var screen = NSScreen.screens.first { $0.backingScaleFactor >= 2 }
        for _ in 0..<20 where screen == nil {
            try? await Task.sleep(for: .milliseconds(250))
            screen = NSScreen.screens.first { $0.backingScaleFactor >= 2 }
        }
        let target = screen ?? window.screen ?? NSScreen.main
        log.append("screens: " + NSScreen.screens.map { "\(Int($0.frame.width))x\(Int($0.frame.height))@\(Int($0.backingScaleFactor))x" }.joined(separator: ", "))
        log.append(screen == nil ? "no 2x screen: captures are 1x" : "capturing on a 2x screen")
        func place(_ width: Double, _ height: Double) {
            guard let target else { return }
            let visible = target.visibleFrame
            window.requestFrame(NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height), display: true)
        }
        place(w, h)
        parkPointer()
        // Every sidebar section open and Playlists at its first ten (Show More not pressed), so the hover shots' row
        // counting (`playlistsStartRow`) sees the rows as drawn; `sidebar-collapsed` closes Playlists as a listener would.
        for section in SidebarSection.allCases { UserDefaults.standard.set(true, forKey: section.defaultsKey) }
        UserDefaults.standard.set(false, forKey: "sidebarShowsAllPlaylists")

        guard let hero = yt.demoNowPlaying else {
            log.append("no demo data: run with MEDLEY_MOCK=demo")
            write(log, manifest)
            return
        }

        // Listening history, oldest first, so Recently Played reads like a real library (Daily Mix 1 is played too, but
        // shows only under Playlists; Liked Music too, but only Library › Liked Songs stands for it),
        // and two pins.
        for key in ["sabrina-carpenter-short-n-sweet", "olivia-dean-the-art-of-loving"] {
            if let album = yt.demoAlbum(key) { play(album, provider: yt) }
        }
        if let mix = sp.catalog.playlists.first(where: { $0.title == "Daily Mix 1" }) { play(mix, provider: sp) }
        if let album = sp.demoAlbum("noah-kahan-the-great-divide") { play(album, provider: sp) }
        let liked = yt.catalog.playlists.first { $0.title == "Liked Music" }
        if let liked { play(liked, provider: yt) }
        for key in ["taylor-swift-the-life-of-a-showgirl", "billie-eilish-hit-me-hard-and-soft"] {
            if let album = yt.demoAlbum(key) { model.pinToSidebar(.item(.album(album))) }
        }
        if let weekly = sp.catalog.playlists.first(where: { $0.title == "Discover Weekly" }) { model.pinToSidebar(.item(.playlist(weekly))) }
        playHero(hero)

        let heroRoute = Route.album(.youtubeMusic, id: hero.album.providerID, preview: hero.album)
        let artist = yt.catalog.artists.first { $0.name == hero.album.artists.first?.name } ?? yt.catalog.artists[0]
        let playlist = sp.catalog.playlists.first { $0.title == "Discover Weekly" } ?? sp.catalog.playlists[0]
        let likedID = liked.map { SidebarEntry.item(.playlist($0)).id }
        // The playlist the sidebar's selection shots highlight under Playlists (played, so it's in the history too).
        let mix = sp.catalog.playlists.first { $0.title == "Daily Mix 1" }
        let mixID = mix.map { SidebarEntry.item(.playlist($0)).id }
        let heroID = SidebarEntry.item(.album(hero.album)).id

        let shots: [Shot] = [
            Shot(name: "home", about: "Home, top of the page: Quick picks and the first shelves, the sidebar, the floating player") {
                model.inspector = nil; model.select(.home)
                await settle(1.0)
                logFeaturedSubtitles("home", into: &log)
                // The first shot of a run: the card's probes can register a moment after the page draws.
                for _ in 0..<20 where featuredTextProbes().count < 2 { await settle(0.1) }
                await logCardTextContrast("home", probes: featuredTextProbes(), into: &log)
                return .main
            },
            Shot(name: "quickpicks-more-keyboard", about: "Home with the pointer away from the window, after Tab moved keyboard focus to the first Quick picks song's More (…) button and Space opened its menu: the row highlighted, the button shown with an accent focus ring, the song's menu with its symbols") {
                model.inspector = nil; model.select(.home)
                await settle(1.0)
                return await openQuickPicksMoreByKeyboard(into: &log)
            } reset: {
                await choosePlayNextFromKeyboardMenu(hero: hero, into: &log)
            },
            Shot(name: "home-scrolled", about: "Home scrolled down to Listen again (shelves of cards and mixes; the liked-songs card reads \"Liked Songs\" over \"Library\" and opens Library › Liked Songs); the cards fade out under back/forward") {
                model.inspector = nil; model.select(.home)
                await settle(1.0)
                // Home is lazy, so its height (and any fixed fraction of it) changes as shelves lay out: scroll until
                // the shelf is on screen instead.
                let found = await scrollPage(untilProbe: "shelf-listen again", topAt: 380)
                log.append("home-scrolled: Listen again \(found ? "on screen (PASS)" : "not found (FAIL)")")
                await settle(0.6)
                logTopFade("home-scrolled", into: &log)
                logCardEdges("home-scrolled 1440", into: &log)
                // Made for You's caption strips, scrolled into view under the toolbar for the measurement.
                _ = await scrollPage(untilProbe: "shelf-made for you", topAt: 120)
                await settle(0.6)
                await logCardTextContrast("home-scrolled mix cards", probes: mixCaptionProbes(), into: &log)
                _ = await scrollPage(untilProbe: "shelf-listen again", topAt: 380)
                await settle(0.4)
                return .main
            } reset: {
                // The same rows at 960 pt with the sidebar, then the window back.
                place(960, h)
                await settle(0.8)
                _ = await scrollPage(untilProbe: "shelf-listen again", topAt: 380)
                logCardEdges("home-scrolled 960", into: &log)
                place(w, h)
                scrollPage(to: 0)
                await settle(0.6)
            },
            Shot(name: "album", about: "An album page: \(hero.album.title), hero header, track list with the playing song; the list stops 880 pt from the header's leading edge (a reading width, as in Music), so each song's time sits near its title") {
                model.inspector = nil; await open(heroRoute)
                await settle(1.0)
                await logHeroActions("album", into: &log)
                return .main
            },
            Shot(name: "album-scrolled", about: "The album page scrolled down a little: track rows passing under the toolbar's soft edge") {
                model.inspector = nil; await open(heroRoute)
                await settle(1.0)
                scrollPage(to: 0.3)
                await settle(0.6)
                logTopFade("album-scrolled", into: &log)
                return .main
            } reset: { scrollPage(to: 0) },
            Shot(name: "artist", about: "An artist page: \(artist.name), the photo across the whole header with the face Vision found in the right part of the frame, the name over a shade from the left: in light mode over this pale photo dark text on a light shade of the photo's tint with the album page's buttons, the photo fading into that tint, which carries on under Top Songs; in dark mode white text on a dark scrim. Top Songs as Home's Quick picks rows (artwork, title, album), three columns") {
                model.inspector = nil; await open(.artist(.youtubeMusic, id: artist.providerID, preview: artist))
                await logPhotoFocus(artist, banner: heroBanner(), into: &log)
                await settle(0.8)
                log.append("artist scrim: \(DebugProbes.notes["artist-scrim"] ?? "not reported")")
                await logArtistHeader("artist", into: &log)
                return .main
            },
            Shot(name: "artist-topsongs-more-keyboard", about: "The artist page with the pointer away from the window, after Tab moved keyboard focus to the first Top Songs row's More (…) button and Space opened its menu, as in Quick picks: the row highlighted, the button's accent focus ring, the song's menu") {
                model.inspector = nil; await open(.artist(.youtubeMusic, id: artist.providerID, preview: artist))
                await settle(1.0)
                let target = await openQuickPicksMoreByKeyboard(label: "artist top songs more keyboard", into: &log)
                let id = DebugProbes.notes["more-focus"].flatMap { $0.split(separator: "|", maxSplits: 1).first.map(String.init) }
                let top = (try? await yt.artist(id: artist.providerID))?.topTracks.map(\.id) ?? []
                log.append("artist top songs more keyboard: the focused More is a Top Songs row's: \(id.map { top.contains($0) } == true ? "PASS" : "FAIL")")
                return target
            } reset: {
                KeyboardMoreMenu.current?.cancelTracking()
                await settle(0.3)
                await clearKeyboardFocus(into: &log)
            },
            Shot(name: "playlist", about: "A playlist page: Spotify's \(playlist.title), with its description; the header's meta line ends with the song count and total length (\"40 songs, 2 hr 14 min\"), as on an album") {
                // The album page's line is still in the note: start without it, so only this page's line counts.
                DebugProbes.note("song-count", nil)
                model.inspector = nil; await open(.playlist(.spotify, id: playlist.providerID, preview: playlist))
                // The later pages of a short playlist load right after the first; then the total shows.
                for _ in 0..<30 where !(DebugProbes.notes["song-count"] ?? "").contains(",") { await settle(0.1) }
                let line = DebugProbes.notes["song-count"] ?? "not reported"
                log.append("playlist header: \"\(line)\" (\(line.contains(", ") ? "PASS: count and total length" : "FAIL: no total length"))")
                return .main
            },
            Shot(name: "playlist-sorted", about: "The playlist after two clicks on the Title header: sorted Z to A, a down chevron after \"Title\"; the action row has no separate sort button (Sort By is in More)") {
                model.inspector = nil; await open(.playlist(.spotify, id: playlist.providerID, preview: playlist))
                await settle(1.0)
                let lineBefore = DebugProbes.notes["song-count"] ?? "not reported"
                guard let title = DebugProbes.windowFrame("sort-menu") else {
                    log.append("playlist-sorted: Title header not found (FAIL)")
                    return .main
                }
                let point = CGPoint(x: title.minX + 20, y: title.midY)
                click(at: point)
                await settle(0.5)
                let first = DebugProbes.notes["track-sort"] ?? "not reported"
                click(at: point)
                await settle(0.8)
                let second = DebugProbes.notes["track-sort"] ?? "not reported"
                let order = DebugProbes.notes["track-list-order"] ?? "not reported"
                log.append("playlist-sorted: first click \(first), second click \(second) (\(first == "title ascending" && second == "title descending" ? "PASS" : "FAIL")); first rows \(order)")
                // The header's song count reads the same before and after sorting loads the rest of the playlist.
                await settle(0.8)
                let lineAfter = DebugProbes.notes["song-count"] ?? "not reported"
                log.append("playlist-sorted: header line \"\(lineBefore)\" on first render, \"\(lineAfter)\" after sorting (\(lineBefore == lineAfter && lineBefore != "not reported" ? "PASS" : "FAIL"))")
                parkPointer()
                return .main
            } reset: {
                if let title = DebugProbes.windowFrame("sort-menu") {
                    click(at: CGPoint(x: title.minX + 20, y: title.midY))
                    await settle(0.5)
                }
                let third = DebugProbes.notes["track-sort"] ?? "not reported"
                log.append("playlist-sorted: third click \(third) (\(third == "original ascending" ? "PASS" : "FAIL"))")
            },
            Shot(name: "playlist-sorted-play", about: "The playlist sorted by Title, Z to A, right after the header's Play: the whole playlist queued in that order from its first row, which shows the playing bars; the round Play turned into Pause") {
                model.inspector = nil; await open(.playlist(.spotify, id: playlist.providerID, preview: playlist))
                await settle(1.0)
                await sortedHeaderPlay(playlist, into: &log)
                return .main
            } reset: {
                if let title = DebugProbes.windowFrame("sort-menu") {
                    click(at: CGPoint(x: title.minX + 20, y: title.midY))
                    await settle(0.5)
                }
                playHero(hero)
                await settle(0.3)
            },
            Shot(name: "playlist-multi-select", about: "One of the listener's Spotify playlists with several rows selected as in a Mac table (a click on the second row, ⌘-click on the fourth, ⇧-click on the sixth, then ⇧↓: the second and the fourth to seventh rows, neighbours' fills joined into one) and a selected row's More menu open: \"5 Songs\", then Play Next, Add to Queue, Add to Playlist and Remove from Playlist, which act on every selected row") {
                await multiSelect(into: &log)
            } reset: {
                await finishMultiSelect(hero: hero, into: &log)
            },
            Shot(name: "track-list-focus", about: "The album page after Tab moved keyboard focus into the track list, nothing selected: the first row has an accent outline") {
                model.inspector = nil; await open(heroRoute)
                await settle(1.0)
                await tabIntoTrackList(into: &log)
                return .main
            } reset: {
                // Leave the page, so the next shot's album page starts without list focus.
                model.select(.songs)
                await settle(0.3)
            },
            Shot(name: "songs", about: "Library › Songs: the artwork in its own unlabeled column so \"Title\" sits over the titles; the header divider and the selection on the page margins; each liked song's heart 8 pt before its time") {
                model.inspector = nil; model.select(.songs)
                await settle(1.2)
                log.append("songs table: \(DebugProbes.notes["songs-table"] ?? "not reported")")
                return .main
            },
            Shot(name: "songs-selected", about: "Library › Songs with the second and third rows selected and the table focused (the second a liked song): the accent selection, its service, heart and time in white") {
                model.inspector = nil; model.select(.songs)
                await settle(1.0)
                let tables = views(of: NSTableView.self, in: window.contentView).filter { $0 !== sidebarTable }
                if let table = tables.first, table.numberOfRows > 2 {
                    table.selectRowIndexes([1, 2], byExtendingSelection: false)
                    window.makeFirstResponder(table)
                    log.append("songs-selected: selected rows 1, 2 of \(table.numberOfRows), table is first responder: \(window.firstResponder === table ? "yes" : "no")")
                    await settle(0.6)
                    log.append(songsSelectedHeartCheck(table, row: 1))
                } else {
                    log.append("songs-selected: songs table not found (FAIL)")
                }
                return .main
            } reset: {
                for table in views(of: NSTableView.self, in: window.contentView) where table !== sidebarTable { table.deselectAll(nil) }
                model.select(.home)
            },
            Shot(name: "songs-find", about: "Library › Songs after ⌘F and typing \"olivia\" into Find in Songs: only the matching songs (title, artist or album), the count reads \"n of N songs\", the column headers still sort") {
                model.inspector = nil; model.select(.songs)
                await settle(1.2)
                window.makeFirstResponder(nil)
                let table = views(of: NSTableView.self, in: window.contentView).first { $0 !== sidebarTable }
                let before = table?.numberOfRows ?? 0
                pressCommandF()
                await settle(0.5)
                let field = AppModel.pageFindField(in: window)
                let editor = window.firstResponder as? NSTextView
                let focused = field != nil && editor?.delegate === field
                editor?.insertText("olivia", replacementRange: editor?.selectedRange() ?? NSRange(location: 0, length: 0))
                await settle(0.8)
                let after = views(of: NSTableView.self, in: window.contentView).first { $0 !== sidebarTable }?.numberOfRows ?? 0
                log.append("songs-find: ⌘F focused \"\(field?.placeholderString ?? "no Find field")\" (\(focused ? "PASS" : "FAIL")); \"olivia\" left \(after) of \(before) rows (\(after > 0 && after < before ? "PASS" : "FAIL"))")
                return .main
            } reset: {
                window.makeFirstResponder(nil)
                model.select(.home)
                await settle(0.3)
            },
            Shot(name: "library-refused", about: "Library › Songs while Spotify refuses its library (as when it can't be reached): YouTube Music's songs listed, and over them a note naming the service, \"Couldn't load your Spotify songs\", with Try Again") {
                model.inspector = nil
                // Nothing saved, so the page loads both services again; Spotify answers every library page with a
                // failure.
                model.cache.invalidate(prefix: "library:")
                sp.libraryFailure = .network("The request timed out.")
                model.select(.home)
                await settle(0.3)
                model.select(.songs)
                for _ in 0..<30 where DebugProbes.windowFrame("library-issue-spotify") == nil { await settle(0.1) }
                await settle(0.6)
                let note = DebugProbes.notes["library-issue-spotify"] ?? "not shown"
                let named = note.hasPrefix("Couldn’t load your Spotify songs")
                let tables = views(of: NSTableView.self, in: window.contentView).filter { $0 !== sidebarTable }
                let rows = tables.first?.numberOfRows ?? 0
                log.append("library-refused: note \"\(note)\" (\(named ? "PASS" : "FAIL")); YouTube Music's songs still listed: \(rows) rows (\(rows > 0 ? "PASS" : "FAIL"))")
                return .main
            } reset: {
                // Spotify answers again: Try Again (a real click) brings its songs in and the note goes.
                sp.libraryFailure = nil
                let before = views(of: NSTableView.self, in: window.contentView).filter { $0 !== sidebarTable }.first?.numberOfRows ?? 0
                if let button = DebugProbes.windowFrame("library-issue-action-spotify") {
                    click(at: CGPoint(x: button.midX, y: button.midY))
                    for _ in 0..<30 where DebugProbes.windowFrame("library-issue-spotify") != nil { await settle(0.1) }
                    await settle(0.4)
                    let after = views(of: NSTableView.self, in: window.contentView).filter { $0 !== sidebarTable }.first?.numberOfRows ?? 0
                    let gone = DebugProbes.windowFrame("library-issue-spotify") == nil
                    log.append("library-refused: Try Again: note \(gone ? "gone" : "still shown"), rows \(before) → \(after) (\(gone && after > before ? "PASS" : "FAIL"))")
                } else {
                    log.append("library-refused: Try Again not found (FAIL)")
                }
                model.cache.invalidate(prefix: "library:")
            },
            Shot(name: "search", about: "Search results for \"olivia\": the scope picker in the toolbar, then top result, songs with their lengths, albums, then the two artists") {
                model.inspector = nil; model.select(.search); model.searchText = "olivia"
                await settle(1.0)
                return .main
            } reset: { model.searchText = "" },
            Shot(name: "search-scrolled", about: "Search results for \"olivia\" scrolled to Albums and Artists: Albums first (a two-artist single's subtitle keeps whole names: \"Single · Olivia Rodrigo and more\", or \"Olivia Rodrigo and more\" in a card too narrow for that, never a name cut short), then the two artists in one compact row (64 pt portrait, name and \"Artist\" beside it) lined up with Top Results") {
                model.inspector = nil; model.select(.search); model.searchScope = .all; model.searchText = "olivia"
                await settle(1.0)
                let found = await scrollPage(untilProbe: "search-compact-artist", topAt: 560)
                log.append("search-scrolled: compact artist row \(found ? "on screen (PASS)" : "not found (FAIL)")")
                return .main
            } reset: { scrollPage(to: 0); model.searchText = "" },
            Shot(name: "search-artists", about: "Search › Artists for \"olivia\" right after scrolling Top Results to its end and switching the scope: the large portrait grid at the top of the page, kept for the Artists scope") {
                model.inspector = nil; model.select(.search); model.searchScope = .all; model.searchText = "olivia"
                await settle(1.0)
                // As a listener does it: Top Results scrolled down, then the Artists segment. The first switch loads
                // the scope; the second (Top Results, scrolled again, Artists) finds it already loaded.
                for pass in ["first visit", "loaded before"] {
                    if pass == "loaded before" {
                        model.searchScope = .all
                        await settle(1.0)
                    }
                    scrollPage(to: 1)
                    await settle(0.5)
                    let before = pageScrollState().text
                    model.searchScope = .artists
                    await settle(1.0)
                    log.append("search-artists (\(pass)): Top Results scrolled to \(before), then Artists: \(searchArtistGridCheck())")
                }
                // A scope switch starts at the top: Songs, longer than Top Results, kept its offset (opened mid-list).
                model.searchScope = .all
                await settle(1.0)
                scrollPage(to: 1)
                await settle(0.5)
                model.searchScope = .songs
                await settle(1.0)
                let songs = pageScrollState()
                log.append("search-artists: Top Results scrolled, then Songs: \(songs.text) (\(songs.offset <= 0 ? "PASS: at the top" : "FAIL: kept the offset"))")
                // Round 22's blank page: scrolled, then the query cleared and set again with Artists in the same update
                // (the old capture did exactly this) left the page's lazy stack with no rows.
                model.searchScope = .all
                await settle(1.0)
                scrollPage(to: 1)
                await settle(0.5)
                scrollPage(to: 0); model.searchText = ""
                model.searchText = "olivia"; model.searchScope = .artists
                await settle(1.0)
                log.append("search-artists (query and scope changed in one update): \(searchArtistGridCheck())")
                return .main
            } reset: { model.searchScope = .all; model.searchText = "" },
            Shot(name: "lyrics", about: "The album page with the Lyrics panel open on the right (placeholder lyric lines): Play, Shuffle, Add and More stay beside the cover") {
                // As a listener does it: the album page first, then the player's Lyrics button (`toggleInspector`).
                await open(heroRoute)
                await settle(0.8)
                model.toggleInspector(.lyrics)
                await settle(1.4)
                let width = SplitViewTuning.inspectorWidth(in: window) ?? 0
                let size = DebugProbes.notes["lyrics-font"] ?? "not reported"
                let ok = abs(width - InspectorMetrics.lyricsWidth) <= 2 && size == "19"
                log.append("lyrics panel width: \(Int(width)) pt in a \(Int(model.windowWidth)) pt window, lines at \(size) pt (\(ok ? "PASS" : "FAIL"), wanted 420 pt and 19 pt); columns \(SplitViewTuning.describeColumns(in: window))")
                await logHeroActions("lyrics", into: &log)
                return .main
            } reset: { model.inspector = nil },
            Shot(name: "lyrics-scrolled", about: "The Lyrics panel scrolled so a line sits right under the \"Lyrics\" heading: it fades out through the 46 pt top fade instead of showing cut in half") {
                await open(heroRoute)
                await settle(0.8)
                if model.inspector != .lyrics { model.toggleInspector(.lyrics) }
                await settle(1.4)
                log.append(await lyricsTopFadeCheck())
                return .main
            } reset: {
                model.inspector = nil
                if lyricsPausedPlayback { model.player.resume(); lyricsPausedPlayback = false }
            },
            Shot(name: "playing-next", about: "Home with the Playing Next (queue) panel open on the right, the pointer on the second Up Next song (pointer drawn in): its \"…\" (the row's song menu) in place of its time, as on the other song rows; it shows with keyboard focus too") {
                model.select(.home); model.inspector = .queue
                await settle(1.0)
                guard let row = DebugProbes.windowFrame("queue-row-upNext-1") else {
                    log.append("playing-next: second Up Next row not found (FAIL)"); return .main
                }
                // In the gap between the text and the "…", covering neither.
                let point = CGPoint(x: row.maxX - 64, y: row.midY)
                hover(at: point)
                await settle(0.4)
                let id = Array(model.player.upNext)[safe: 1]?.track.id ?? ""
                let shown = DebugProbes.windowFrame("queue-more-\(id)")
                log.append("playing-next: hovered row's More \(shown.map { String(format: "at x %.0f–%.0f, inside the row (%@)", $0.minX, $0.maxX, row.contains(CGPoint(x: $0.midX, y: $0.midY)) ? "PASS" : "FAIL") } ?? "not found (FAIL)")")
                // The probe is there while the "…" is drawn in clear ink too: check the row says it's revealed, and
                // that the capture has the dots' ink inside the button.
                let revealed = DebugProbes.notes["queue-more-revealed-\(id)"] ?? "not reported"
                log.append("playing-next: hovered row's More is \(revealed) (\(revealed == "shown" ? "PASS" : "FAIL"))")
                if let shown { log.append(moreInkCheck(shown)) }
                return .mainWithPointer(point)
            } reset: { parkPointer(); model.inspector = nil },
            Shot(name: "playing-next-keyboard", about: "Playing Next with a row picked by the keyboard: a click on the first Up Next song, then ↓ ↓ (the third Up Next song selected, the list focused; its \"…\" in place of the time)") {
                model.select(.home); model.inspector = .queue
                await settle(1.0)
                await selectQueueRowByKeyboard(into: &log)
                return .main
            } reset: {
                model.inspector = nil
                parkPointer()
            },
            Shot(name: "queue-focus-escape", about: "Playing Next after a click on the first Up Next song, ↓, then Escape: nothing selected, the list keeps focus, and the row that was selected keeps an accent outline") {
                model.select(.home); model.inspector = .queue
                await settle(1.0)
                await selectQueueRowThenEscape(into: &log)
                return .main
            } reset: {
                model.inspector = nil
                parkPointer()
            },
            Shot(name: "queue-focus-removed", about: "Playing Next after a click on the first Up Next song, then that song removed from the queue elsewhere: the list keeps focus and the song that took its place is outlined") {
                model.select(.home); model.inspector = .queue
                await settle(1.0)
                await selectQueueRowThenRemove(into: &log)
                return .main
            } reset: {
                model.inspector = nil
                parkPointer()
                // Put the removed song back: the hero album from the hero song on, as at the start.
                playHero(hero)
            },
            Shot(name: "fullscreen-player", about: "The full-screen player (⇧⌘F), shown inside the window, with lyrics and the Lyrics / Playing Next buttons bottom right") {
                model.inspector = nil; model.fullScreenPanel = .lyrics; model.isFullScreenPlayerPresented = true; return .main
            } reset: { model.isFullScreenPlayerPresented = false },
            Shot(name: "fullscreen-buffering", about: "The full-screen player while its stream has been buffering for more than half a second (forced for the capture): a faint full ring on the Pause disc's edge with a short arc on it, turned by Core Animation; shorter waits show nothing") {
                model.inspector = nil; model.fullScreenPanel = .lyrics; model.isFullScreenPlayerPresented = true
                await settle(0.6)
                DebugProbes.note("play-ring", nil)
                model.debugForcesBuffering = true
                await settle(0.3)
                let early = DebugProbes.notes["play-ring"] ?? "none"
                await settle(0.6)
                let late = DebugProbes.notes["play-ring"] ?? "none"
                log.append("fullscreen-buffering ring: after 0.3 s \(early), after 0.9 s \(late) (\(early == "none" && late != "none" ? "PASS: only after the delay" : "FAIL"))")
                return .main
            } reset: {
                model.debugForcesBuffering = false
                model.isFullScreenPlayerPresented = false
                await settle(0.3)
            },
            Shot(name: "fullscreen-actions", about: "The full-screen player with the More (…) menu beside the title open: the song's menu, as on right-click, drawn dark in either system appearance (the player is always dark); the button shows a pressed fill, no focus ring; Like sits on the title's other side") {
                model.inspector = nil; model.fullScreenPanel = .lyrics; model.isFullScreenPlayerPresented = true
                await settle(1.2)
                guard let more = DebugProbes.windowFrame("fullscreen-more") else {
                    log.append("fullscreen-actions: More button not found (FAIL)")
                    return .main
                }
                log.append("fullscreen-actions: More at \(more), Like \(DebugProbes.windowFrame("fullscreen-like").map { "at \($0)" } ?? "missing")")
                click(at: CGPoint(x: more.midX, y: more.midY))
                await settle(0.8)
                let appearance = KeyboardMoreMenu.current?.appearance?.name
                log.append("fullscreen-actions: menu appearance \(appearance?.rawValue ?? "none") (\(appearance == .darkAqua ? "PASS" : "FAIL"))")
                return .mainWithMenu
            } reset: {
                KeyboardMoreMenu.current?.cancelTracking()
                await settle(0.4)
                window.makeFirstResponder(nil)
                model.isFullScreenPlayerPresented = false
            },
            Shot(name: "fullscreen-player-queue", about: "The full-screen player with Playing Next open beside the artwork instead of lyrics") {
                model.inspector = nil; model.fullScreenPanel = .queue; model.isFullScreenPlayerPresented = true; return .main
            } reset: { model.isFullScreenPlayerPresented = false },
            Shot(name: "fullscreen-player-nopanel", about: "The full-screen player with both panels closed: artwork and controls centered") {
                model.inspector = nil; model.fullScreenPanel = nil; model.isFullScreenPlayerPresented = true; return .main
            } reset: {
                model.isFullScreenPlayerPresented = false
                model.fullScreenPanel = .lyrics
            },
            // Notices from the full-screen player's More menu and Like button draw over it (`NoticeHUD`), clear of
            // its controls. Held for the shot (a notice normally goes after 2.2 s).
            Shot(name: "fullscreen-notice", about: "The full-screen player right after Add to Queue from its More menu: the \"Added to queue\" confirmation at the top center, clear of the controls") {
                model.inspector = nil; model.fullScreenPanel = .lyrics; model.isFullScreenPlayerPresented = true
                await settle(0.8)
                model.noticeDuration = .seconds(30)
                if let next = model.player.queue.first?.track { model.addToQueue(.track(next)) }
                await settle(0.6)
                checkNotice("fullscreen-notice", expecting: "Added to queue", into: &log)
                return .main
            } reset: { await endNoticeShot(hero) },
            // A failure stays until closed (no `noticeDuration` hold: the capture comes about 2.6 s later, past the
            // 2.2 s a confirmation lasts), with Try Again and a close button that take clicks.
            Shot(name: "fullscreen-notice-error", about: "The full-screen player with Playing Next open after a Like that failed offline: \"Couldn’t like “<song>”. You’re offline.\" at the top center with Try Again and a close button, still up after the 2.2 s a confirmation lasts; the heart back as it was") {
                model.inspector = nil; model.fullScreenPanel = .queue; model.isFullScreenPlayerPresented = true
                await settle(0.8)
                return await failLike(name: "fullscreen-notice-error", checkControls: true, into: &log)
            } reset: {
                await checkNoticeButtons("fullscreen-notice-error", into: &log)
                yt.failingWrites = nil
                await endNoticeShot(hero)
            },
            Shot(name: "notice-error", about: "Browsing the album page after a Like that failed offline: the failure notice above the floating player with Try Again and a close button") {
                model.inspector = nil; await open(heroRoute)
                await settle(0.8)
                return await failLike(name: "notice-error", checkControls: false, into: &log)
            } reset: {
                await checkNoticeButtons("notice-error", into: &log)
                yt.failingWrites = nil
                model.notice = nil
                await settle(0.3)
            },
            Shot(name: "save-refused", about: "The album page after Add to Library (the hero's + button, clicked for real) that the service refused offline: the button back to + \"Add to Library\", the failure notice with Try Again above the floating player") {
                model.inspector = nil; await open(heroRoute)
                await settle(0.8)
                return await refuseSave(hero: hero, into: &log)
            } reset: {
                yt.failingWrites = nil
                model.notice = nil
                await settle(0.3)
            },
            Shot(name: "playlist-remove-undo", about: "One of the listener's Spotify playlists right after Remove from Playlist on its second song: the row is gone, the notice \"Removed “…” from “…”\" offers Undo above the floating player (Edit › Undo also puts it back)") {
                await removeFromPlaylistWithUndo(into: &log)
            } reset: {
                await undoPlaylistRemoval(into: &log)
                checkQueueRemovalUndo(into: &log)
            },
            Shot(name: "playlist-edit-partial", about: "One of the listener's Spotify playlists after removing its second and third songs with the service failing partway (offline after the first request): the failure notice \"Removed only 1 of 2 songs…\" with Undo, Try Again and Leave As Is; the playlist takes no other edit until one of them") {
                await partialPlaylistEdit("playlist-edit-partial", closeNotice: false, into: &log)
            } reset: {
                await endPartialPlaylistEdit("playlist-edit-partial", into: &log)
            },
            Shot(name: "playlist-edit-banner", about: "The same partly applied removal with its failure notice closed: the playlist page keeps it in view in a banner over the list, \"The last change to this playlist isn’t finished\", with Undo, Try Again and Leave As Is; closing the notice didn't unlock the playlist") {
                await partialPlaylistEdit("playlist-edit-banner", closeNotice: true, into: &log)
            } reset: {
                await endPartialPlaylistEdit("playlist-edit-banner", into: &log)
            },
            Shot(name: "playlist-edit-changed", about: "One of the listener's Spotify playlists after Remove from Playlist on its second song, another device then putting a song at the top, and Edit › Undo: nothing goes back at the old place (the page shows the playlist as it is now), and the notice \"“…” changed since you removed this song.\" offers Add Back at End and Cancel") {
                await changedPlaylistUndo(into: &log)
            } reset: {
                await addBackAtEnd(into: &log)
            },
            Shot(name: "playlist-edit-read-incomplete", about: "The changed playlist's Add Back at End while the service hands out the same page token twice: nothing is appended from a partial read, and the failure notice \"Couldn’t read all of “…”.\" offers Try Again") {
                await incompleteAddBack(into: &log)
            } reset: {
                sp.repeatsContinuations = false
                if let retry = model.notice?.retry {
                    model.dismissNotice()
                    retry()
                    await model.lastPlaylistEdit?.value
                }
                await addBackAtEnd(name: "playlist-edit-read-incomplete", into: &log)
            },
            Shot(name: "playlist-edit-banner-empty", about: "One of the listener's Spotify playlists after removing its last song and an Undo that failed offline, the failure notice closed: \"This playlist is empty\" with the banner over it, \"The last change to this playlist isn’t finished\", Try Again and Leave As Is") {
                await emptyPlaylistBanner(into: &log)
            } reset: {
                await endEmptyPlaylistBanner(into: &log)
            },
            Shot(name: "playlist-repeated", about: "One of the listener's YouTube Music playlists holding its first song twice: one row for the song with \"2×\" before its time, the header's count the service's total of entries (the rows' copies add up to it), and the row's menu open with \"Remove Both Copies\" (the context menu, the same items as its More)") {
                await showRepeatedSong(into: &log)
            } reset: {
                Self.repeatedMenu?.cancelTracking()
                Self.repeatedMenu = nil
                await settle(0.4)
            },
            Shot(name: "playlist-remove-confirm", about: "One of the listener's YouTube Music playlists after Remove from Playlist, with the service set up as one that can't put a song back where it was: a dialog names the song and the playlist and says it can't be undone (Remove / Cancel)") {
                await askBeforeRemoving(into: &log)
            } reset: {
                model.pendingPlaylistRemoval = nil
                yt.capabilities.insert(.playlistInsert)
                await settle(0.5)
            },
            // The hero cover is mid-tone: the metadata contrast is also judged over a pale and a dark cover.
            Shot(name: "fullscreen-pale", about: "The full-screen player on a pale cover (\(Self.paleCover)) with lyrics: the title and artist line over the palest backdrop in the demo set") {
                await presentFullScreen(cover: Self.paleCover, panel: .lyrics, into: &log)
            } reset: { await endCoverShot(hero) },
            Shot(name: "fullscreen-pale-nopanel", about: "The full-screen player on the pale cover with both panels closed") {
                await presentFullScreen(cover: Self.paleCover, panel: nil, into: &log)
            } reset: { await endCoverShot(hero) },
            Shot(name: "fullscreen-dark", about: "The full-screen player on a dark cover (\(Self.darkCover)) with lyrics") {
                await presentFullScreen(cover: Self.darkCover, panel: .lyrics, into: &log)
            } reset: { await endCoverShot(hero) },
            Shot(name: "fullscreen-dark-nopanel", about: "The full-screen player on the dark cover with both panels closed") {
                await presentFullScreen(cover: Self.darkCover, panel: nil, into: &log)
            } reset: { await endCoverShot(hero) },
            Shot(name: "settings-general", about: "Settings › General") {
                .window(await openSettings(.general))
            },
            Shot(name: "settings-accounts", about: "Settings › Accounts: both services' accounts in one list (both signed in), then each service's own settings under its name") {
                .window(await openSettings(.accounts))
            },
            Shot(name: "settings-playback", about: "Settings › Playback: Autoplay, then Sound Check, Crossfade and Output grouped under YouTube Music Audio") {
                .window(await openSettings(.playback))
            },
            Shot(name: "settings-sync", about: "Settings › Sync (not paired; sync is off in sample-data runs)") {
                .window(await openSettings(.sync))
            } reset: { settingsWindow()?.close() },
            Shot(name: "sidebar-hover", about: "The full window with the pointer resting on Library › Liked Songs: its heart turns into a Play button (pointer drawn in); Playlists has no Liked Music row") {
                model.select(.home)
                await settle(0.6)
                guard let point = sidebarRowCenter(row: likedSongsRow).map({ CGPoint(x: $0.x + 44, y: $0.y) }) else { return .main }
                hover(at: point)
                return .mainWithPointer(point)
            } reset: { parkPointer() },
            Shot(name: "sidebar-hover-crop", about: "Close-up of the sidebar with the pointer on Library › Liked Songs: Play in place of its heart; the playing album shows bars (pointer drawn in)") {
                model.select(.home)
                await settle(0.6)
                // Past the title's end, so the pointer doesn't cover it.
                let point = sidebarRowCenter(row: likedSongsRow).map { CGPoint(x: $0.x + 44, y: $0.y) }
                writeSidebarRows(point)
                if let point { hover(at: point) }
                await settle(0.5)
                log.append("sidebar-hover-crop: \(sidebarDiscCheck(pressed: false))")
                return .sidebarCrop(width: sidebarWidth(), pointer: point)
            } reset: { parkPointer() },
            Shot(name: "sidebar-hover-playing", about: "Close-up of the sidebar with the pointer on the album that's playing: its bars turn into Pause (pointer drawn in)") {
                model.select(.home)
                await settle(0.6)
                let point = sidebarRowCenter(row: recentRow(heroID))
                if let point { hover(at: point) }
                return .sidebarCrop(width: sidebarWidth(), pointer: point)
            } reset: { parkPointer() },
            Shot(name: "sidebar-hover-playlist", about: "Close-up of the sidebar with the pointer on Daily Mix 1 under Playlists, which isn't playing: Play over its artwork (pointer drawn in)") {
                model.select(.home)
                await settle(0.6)
                guard let mix, model.playingFrom?.title != mix.title else {
                    log.append("sidebar-hover-playlist: Daily Mix 1 \(mix == nil ? "missing" : "is playing") (FAIL)")
                    return .main
                }
                // Past the title's end, so the pointer doesn't cover it.
                let point = sidebarRowCenter(row: playlistRow(mix)).map { CGPoint(x: $0.x + 44, y: $0.y) }
                if let point { hover(at: point) }
                log.append("sidebar-hover-playlist: pointer on \(mix.title) \(point == nil ? "row not found (FAIL)" : "(PASS)")")
                return .sidebarCrop(width: sidebarWidth(), pointer: point)
            } reset: { parkPointer() },
            Shot(name: "sidebar-selected", about: "Daily Mix 1's page opened from a Recently Played tag: the one highlighted row is Daily Mix 1 under Playlists (it doesn't repeat in Recently Played)") {
                logSelectionChecks(mixID: mixID, mix: mix, pinned: playlist, into: &log)
                logLikedEntries(likedID: likedID, liked: liked, into: &log)
                if let mixID { model.select(.collection(mixID)) } else { model.select(.songs) }
                return .main
            },
            Shot(name: "sidebar-sections", about: "Close-up of the sidebar from the top: Library (Liked Songs the one liked entry), Pinned (2 albums, a playlist), then Playlists with All Playlists and no Liked Music; Daily Mix 1 selected further down") {
                if let mixID { model.select(.collection(mixID)) }
                await settle(0.6)
                scrollSidebar(toRow: 0)
                await settle(0.3)
                let edge = DebugProbes.notes["sidebar-top-edge"] ?? "not reported"
                log.append("sidebar top edge at the top of the list: \(edge) (\(edge.hasPrefix("hidden") ? "PASS" : "FAIL"))")
                return .sidebarCrop(width: sidebarWidth(), pointer: nil)
            },
            Shot(name: "sidebar-filter", about: "Close-up of the sidebar with the service filter set to YouTube Music: no Spotify row anywhere (Pinned, Playlists, Recently Played); the footer says \"YouTube Music only\" under the account name, beside the filled filter icon; View › Show lists All Services, YouTube Music and Spotify with a checkmark on YouTube Music") {
                model.select(.home)
                await settle(0.4)
                logSidebarFilterRows("all services", into: &log)
                // Picked from View › Show, as the listener would.
                pickViewShow(ServiceFilter.youtubeMusic.title, into: &log)
                await settle(0.8)
                let label = DebugProbes.windowFrame("service-filter-label")
                log.append("service filter label: \(label.map { "shown at \($0)" } ?? "missing") (\(label != nil ? "PASS" : "FAIL"))")
                logSidebarFilterRows("YouTube Music only", into: &log)
                logViewShowMenu(into: &log)
                return .sidebarCrop(width: sidebarWidth(), pointer: nil)
            } reset: {
                model.serviceFilter = .all
                await settle(0.3)
            },
            Shot(name: "sidebar-recents", about: "Close-up of the sidebar scrolled to the end: the last playlists, then Recently Played (Show More only when it would hide two or more entries), none of them a playlist listed above (nor Liked Music); Daily Mix 1 selected under Playlists") {
                if let mixID { model.select(.collection(mixID)) }
                await settle(0.6)
                if let table = sidebarTable {
                    log.append("sidebar table \(type(of: table)): floats group rows \(table.floatsGroupRows ? "yes" : "no"), \(table.numberOfRows) rows, style \(table.style.rawValue)")
                    scrollSidebar(toRow: 0)
                    await settle(0.4)
                    let rest = WindowCapture.image(of: window, shadow: false, fullResolution: true)
                    if let rest { logSidebarBottomEdge(rest: rest, into: &log) }
                    scrollSidebar(toRow: table.numberOfRows - 1)
                    await settle(0.5)
                    if let rest, let scrolled = WindowCapture.image(of: window, shadow: false, fullResolution: true) {
                        logSidebarTopEdge(rest: rest, scrolled: scrolled, into: &log)
                    }
                    let edge = DebugProbes.notes["sidebar-top-edge"] ?? "not reported"
                    log.append("sidebar top edge scrolled to the end: \(edge) (\(edge.hasPrefix("shown") ? "PASS" : "FAIL"))")
                }
                return .sidebarCrop(width: sidebarWidth(), pointer: nil)
            } reset: { scrollSidebar(toRow: 0) },
            Shot(name: "sidebar-collapsed", about: "Close-up of the sidebar after the listener closed Playlists with its heading's chevron (every section starts open), with the pointer on the heading: the system disclosure chevron shows; Recently Played follows (pointer drawn in)") {
                model.select(.home)
                await settle(0.4)
                let rows = sidebarTable?.numberOfRows ?? 0
                // Never toggled: open, with All Playlists, the first ten and Show More.
                UserDefaults.standard.removeObject(forKey: SidebarSection.playlists.defaultsKey)
                await settle(0.8)
                let byDefault = sidebarTable?.numberOfRows ?? 0
                let count = model.sidebarPlaylists.count
                let folds = SidebarMetrics.foldsRows(count, shown: SidebarMetrics.playlistsShown)
                let visible = SidebarMetrics.visibleRows(count, shown: SidebarMetrics.playlistsShown, expanded: false)
                let shown = 1 + visible + (folds ? 1 : 0)
                log.append("sidebar-collapsed: Playlists with \(count) playlists opens by default: \(byDefault) rows, as before \(rows) (\(byDefault == rows ? "PASS" : "FAIL")); \(shown) of them under Playlists (All Playlists, \(visible) playlists\(folds ? ", Show \(count - visible) More" : ""))")
                // The listener closes it.
                UserDefaults.standard.set(false, forKey: SidebarSection.playlists.defaultsKey)
                await settle(0.8)
                let collapsed = sidebarTable?.numberOfRows ?? 0
                log.append("sidebar-collapsed: closed by the listener: \(collapsed) rows (\(collapsed == rows - shown ? "PASS" : "FAIL"))")
                let point = sidebarRowCenter(row: playlistsStartRow - 2).map { CGPoint(x: $0.x + 40, y: $0.y) }
                if let point { hover(at: point) }
                return .sidebarCrop(width: sidebarWidth(), pointer: point)
            } reset: {
                parkPointer()
                // Selecting a playlist row while Playlists is closed opens it again.
                if let mix { model.select(.playlist(mix.provider, mix.providerID)) }
                await settle(0.6)
                let open = UserDefaults.standard.object(forKey: SidebarSection.playlists.defaultsKey) as? Bool
                log.append("sidebar-collapsed: selecting \(mix?.title ?? "a playlist") opened Playlists: \(open == true ? "PASS" : "FAIL")")
                UserDefaults.standard.set(true, forKey: SidebarSection.playlists.defaultsKey)
                // A playlist past the first ten is behind Show More: selecting it shows them all.
                let playlists = model.sidebarPlaylists
                if SidebarMetrics.foldsRows(playlists.count, shown: SidebarMetrics.playlistsShown), let last = playlists.last {
                    let before = UserDefaults.standard.bool(forKey: "sidebarShowsAllPlaylists")
                    model.select(.playlist(last.provider, last.providerID))
                    await settle(0.6)
                    let after = UserDefaults.standard.bool(forKey: "sidebarShowsAllPlaylists")
                    log.append("sidebar-collapsed: selecting \(last.title) (playlist \(playlists.count)) pressed Show More: \(before ? "already shown (FAIL)" : after ? "PASS" : "FAIL")")
                    UserDefaults.standard.set(false, forKey: "sidebarShowsAllPlaylists")
                }
                model.select(.home)
                await settle(0.4)
            },
            Shot(name: "liked-songs-pending", about: "Library › Liked Songs' play button double-clicked while the services are slow to answer (held 4 s for the shot): a small spinner in the heart's place until the songs arrive, and one request, not two") {
                model.select(.home)
                await settle(0.6)
                // Nothing cached, so the click has to load; both services held back.
                model.cache.invalidate(prefix: "library")
                for mock in [yt, sp] { mock.libraryDelay = .seconds(4) }
                pendingRequestsBefore = [yt, sp].map { $0.libraryRequests.filter { $0 == "likedSongs:first" }.count }
                // Wait for the button: after the appearance switch the sidebar's rows are rebuilt, and the dark run
                // looked before the row's probe was back (round 25: not found, no requests).
                guard let point = await likedSongsSymbolCenter(waiting: 4) else {
                    log.append("play requests: Liked Songs' play button not found after 4 s (FAIL)")
                    return .main
                }
                hover(at: point)
                await settle(0.3)
                click(at: point)
                click(at: point)
                await settle(0.5)
                parkPointer()
                await settle(0.3)
                let pending = model.isPlayPending(.likedSongs)
                let spinner = DebugProbes.windowFrame("sidebar-play-spinner")
                log.append("play requests: after a double click on Liked Songs' play button: loading \(pending), spinner \(spinner.map { "\(Int($0.width))×\(Int($0.height)) pt at \(Int($0.minX)), \(Int($0.minY))" } ?? "not shown") (\(pending && spinner != nil ? "PASS" : "FAIL"))")
                return .main
            } reset: {
                // A newer choice while Liked Songs still loads: the hero song. When Liked Songs arrives it must not replace it.
                playHero(hero)
                let chosen = model.player.current?.id
                try? await Task.sleep(for: .seconds(4.6))
                let requests = zip([yt, sp], pendingRequestsBefore).map { $0.libraryRequests.filter { $0 == "likedSongs:first" }.count - $1 }
                let kept = model.player.current?.id == chosen && model.playingFrom?.title == hero.album.title
                log.append("play requests: the hero song chosen while Liked Songs loaded is still playing after it arrived: \(kept ? "yes" : "no"), from \(model.playingFrom?.title ?? "nothing"); spinner gone: \(model.pendingPlay == nil ? "yes" : "no"); no notice: \(model.notice == nil ? "yes" : "no") (\(kept && model.pendingPlay == nil && model.notice == nil ? "PASS" : "FAIL"))")
                log.append("play requests: first-page Liked Songs requests from the double click per service: \(requests.map(String.init).joined(separator: ", ")) (\(requests.allSatisfy { $0 == 1 } ? "PASS: one each" : "FAIL"))")
                for mock in [yt, sp] { mock.libraryDelay = .zero }
                playHero(hero)
                await settle(0.4)
            },
            Shot(name: "narrow-home", about: "The window at 960 pt wide with the sidebar collapsed, on Home") {
                place(960, h)
                model.columnVisibility = .detailOnly
                model.select(.home)
                await settle(1.0)
                logFeaturedSubtitles("narrow-home", into: &log)
                return .main
            },
            Shot(name: "narrow-home-queue", about: "The window at 960 pt wide on Home with Playing Next open (the sidebar collapsed for it): the lead's single featured card at most 460 pt wide from the leading margin; Quick picks and its Show All run to the trailing margin") {
                // From the 960 pt window as a listener has it (sidebar shown): Playing Next collapses the sidebar.
                model.columnVisibility = .all
                place(960, h)
                model.select(.home)
                await settle(0.8)
                model.toggleInspector(.queue)
                await settle(1.2)
                // In capture runs (no animation) the split view can widen the window as the panel opens (see
                // `search-collapsed`; the live app keeps 960, `MEDLEY_SELFTEST=inspectorwidth`): put it back.
                let grew = Int(window.frame.width)
                place(960, h)
                await settle(1.0)
                let windowWidth = window.frame.width
                log.append("narrow-home-queue: window was \(grew) pt after opening, set back to 960")
                if let card = model.debugFrames["featured-card"] {
                    let page = DebugProbes.windowFrame("page-content")?.width ?? 0
                    // Beside the panel the row has no room for two cards: the one card keeps its 460 pt reading width
                    // from the page's leading margin (round 27's ran to the trailing margin, its right half empty
                    // tint), while Quick picks' Show All still ends at the trailing margin.
                    let pageFrame = DebugProbes.windowFrame("page-content")
                    let leading = (pageFrame?.minX ?? 0) + Metrics.pageInset
                    let margin = (pageFrame?.maxX ?? 0) - Metrics.pageInset
                    let cardFrame = DebugProbes.windowFrame("featured-card") ?? card
                    let seeAll = DebugProbes.windowFrame("see-all")?.maxX
                    let ok = abs(cardFrame.minX - leading) <= 1.5 && cardFrame.width <= FeaturedRow.singleCardMaxWidth + 0.5
                        && seeAll.map { abs($0 - margin) <= 1.5 } != false && abs(windowWidth - 960) <= 1
                    log.append(String(format: "narrow-home-queue: window %.0f pt, featured card %.0f pt wide in a %.0f pt page, x %.0f–%.0f; Show All ends at x %@; page margins at x %.0f and %.0f (%@: a 960 pt window, the card at most %.0f pt from the leading margin, Show All at the trailing one)",
                                      windowWidth, cardFrame.width, page, cardFrame.minX, cardFrame.maxX, seeAll.map { String(format: "%.0f", $0) } ?? "none",
                                      leading, margin, ok ? "PASS" : "FAIL", FeaturedRow.singleCardMaxWidth))
                } else {
                    log.append("narrow-home-queue: featured card not found (FAIL)")
                }
                log.append("narrow-home-queue: \(narrowQueueEdgesCheck())")
                log.append("narrow-home-queue: \(wholeCardsCheck("shelf-made for you"))")
                logFeaturedSubtitles("narrow-home-queue", into: &log)
                await logCardTextContrast("narrow-home-queue", probes: featuredTextProbes(), into: &log)
                return .main
            } reset: {
                model.inspector = nil
                await settle(1.0)
                model.columnVisibility = .all
                place(w, h)
                await settle(0.6)
            },
            Shot(name: "narrow-album", about: "The window at 960 pt wide with the sidebar collapsed, on the album page") {
                place(960, h)
                model.columnVisibility = .detailOnly
                await open(heroRoute)
                return .main
            },
            Shot(name: "narrow-home-scrolled", about: "The window at 960 pt wide on Home, scrolled: shelf titles and cards passing under the toolbar") {
                place(960, h)
                model.columnVisibility = .detailOnly
                model.select(.home)
                await settle(1.0)
                scrollPage(to: 0.2)
                await settle(0.6)
                logTopFade("narrow-home-scrolled", into: &log)
                return .main
            } reset: { scrollPage(to: 0) },
            Shot(name: "narrow-artist", about: "The window at 960 pt wide with the sidebar collapsed, on \(artist.name)'s page (the full-bleed header at a narrower banner; in light mode the same dark text on a light shade as at 1440, the buttons on light pills)") {
                place(960, h)
                model.columnVisibility = .detailOnly
                await open(.artist(.youtubeMusic, id: artist.providerID, preview: artist))
                await logPhotoFocus(artist, banner: heroBanner(), into: &log)
                await settle(0.8)
                log.append("artist scrim (960): \(DebugProbes.notes["artist-scrim"] ?? "not reported")")
                await logArtistHeader("narrow-artist", into: &log)
                return .main
            } reset: {
                model.columnVisibility = .all
                place(w, h)
            },
            Shot(name: "search-collapsed", about: "The window at 960 pt with Lyrics open (which hid the sidebar), right after ⌘F: the panel closed, the sidebar back and its search field focused; the window stays 960 pt") {
                await checkSearchReveal(height: h, place: place, into: &log)
                return .main
            } reset: {
                window.makeFirstResponder(nil)
                model.inspector = nil
                model.columnVisibility = .all
                place(w, h)
                await settle(0.6)
            },
            Shot(name: "playing-next-cleared", about: "Playing Next right after Clear beside Up Next: the Up Next group is empty and Autoplay's songs stay; ⌘Z afterwards puts the songs back without restarting the current one") {
                model.select(.home); model.inspector = .queue
                await settle(1.0)
                let player = model.player
                queueBeforeClear = player.queue.map(\.uid)
                currentBeforeClear = player.currentEntry?.uid
                let userBefore = player.upNext.filter { !$0.isAutoplay }.count
                let autoBefore = player.upNext.filter(\.isAutoplay).count
                let panelBefore = SplitViewTuning.inspectorWidth(in: window) ?? -1
                let contentBefore = DebugProbes.windowFrame("queue-content")?.width ?? -1
                guard let clear = DebugProbes.windowFrame("queue-clear") else {
                    log.append("queue clear: Clear button not found (FAIL)")
                    return .main
                }
                click(at: CGPoint(x: clear.midX, y: clear.midY))
                await settle(0.8)
                let userAfter = player.upNext.filter { !$0.isAutoplay }.count
                let autoAfter = player.upNext.filter(\.isAutoplay).count
                let ok = userBefore > 0 && userAfter == 0 && autoAfter == autoBefore && player.currentEntry?.uid == currentBeforeClear
                let list = DebugProbes.notes["queue-list"] ?? "not reported"
                log.append("queue clear: after the click on Clear the list reports \(list); no outline: \(list.hasSuffix("outlined row none") || !list.hasPrefix("focused") ? "PASS" : "FAIL")")
                let panelAfter = SplitViewTuning.inspectorWidth(in: window) ?? -1
                let contentAfter = DebugProbes.windowFrame("queue-content")?.width ?? -1
                let steady = abs(panelAfter - panelBefore) <= 0.5 && abs(contentAfter - contentBefore) <= 0.5 && panelAfter >= InspectorMetrics.minWidth
                log.append("queue clear: panel \(Int(panelBefore)) → \(Int(panelAfter)) pt, list \(Int(contentBefore)) → \(Int(contentAfter)) pt with and without Up Next songs (\(steady ? "PASS" : "FAIL"))")
                log.append("queue clear: Up Next \(userBefore) → \(userAfter), Autoplay \(autoBefore) → \(autoAfter), same song playing: \(player.currentEntry?.uid == currentBeforeClear ? "yes" : "no"); undo menu item \"\(window.undoManager?.undoMenuItemTitle ?? "none")\" (\(ok && window.undoManager?.undoActionName == "Clear Up Next" ? "PASS" : "FAIL"))")
                return .main
            } reset: {
                // ⌘Z through the app's Edit menu, as the listener would.
                let player = model.player
                let time = player.currentTime
                pressCommandZ()
                await settle(0.6)
                let restored = player.queue.map(\.uid) == queueBeforeClear
                let same = player.currentEntry?.uid == currentBeforeClear && player.currentTime >= time - 0.5
                log.append("queue clear: ⌘Z restored every entry in order: \(restored ? "yes" : "no"), current song not restarted: \(same ? "yes" : "no") (\(restored && same ? "PASS" : "FAIL"))")
                window.makeFirstResponder(nil)
                model.inspector = nil
                parkPointer()
            },
            Shot(name: "drag-to-playlist", about: "Home with a song dragged over one of the listener's playlists in the sidebar (Playlists opened with Show More): the row's drop highlight, an accent outline and tint. The hover state is shown through a capture hook, since posting a real drag needs Accessibility access the app lacks; then the drop handler runs with the first Quick picks song: it's appended and \"Added to …\" confirms it") {
                model.inspector = nil; model.select(.home)
                UserDefaults.standard.set(true, forKey: "sidebarShowsAllPlaylists")
                await settle(1.0)
                return await previewPlaylistDrop(into: &log)
            } reset: {
                await finishPlaylistDrop(into: &log)
                UserDefaults.standard.set(false, forKey: "sidebarShowsAllPlaylists")
                model.notice = nil
                await settle(0.4)
            },
            Shot(name: "drag-to-playing-next", about: "Home with Playing Next open and a song dragged over the top of Up Next: the queue's insertion line above the first Up Next song (Play Next). The hover state is shown through a capture hook; then the drop handlers run: dropped above Up Next the song plays next, below it the song ends Up Next") {
                model.select(.home)
                model.inspector = .queue
                await settle(1.2)
                DropPreviewProbe.show("queue:playNext")
                await settle(0.3)
                return .main
            } reset: {
                DropPreviewProbe.show(nil)
                await checkQueueDrops(into: &log)
                model.inspector = nil
                model.notice = nil
                playHero(hero)
                await settle(0.4)
            },
            Shot(name: "player-song-more", about: "The floating player's song More (…) beside the heart, open: the song's own menu, as on right-click (full tier); the clicked button shows a pressed fill, no focus ring") {
                model.inspector = nil; model.select(.home)
                await settle(0.8)
                guard let more = DebugProbes.windowFrame("player-song-more") else {
                    log.append("player song more: button not found (FAIL)")
                    return .main
                }
                log.append("player song more: at \(more) (PASS)")
                click(at: CGPoint(x: more.midX, y: more.midY))
                return .mainWithMenu
            } reset: {
                KeyboardMoreMenu.current?.cancelTracking()
                await settle(0.4)
                window.makeFirstResponder(nil)
                parkPointer()
            },
            Shot(name: "player-more-compact", about: "The window at 960 pt with Playing Next open, so the player is in a narrower tier: its one More (…) open, the song's actions first, then what the tier folded away (output, windows); the artist line shows in full beside the heart") {
                model.columnVisibility = .all
                model.select(.home)
                place(960, h)
                model.inspector = .queue
                await settle(1.0)
                // Opening the panel can widen the window; put it back to 960 pt.
                place(960, h)
                await settle(1.2)
                let songMore = DebugProbes.windowFrame("player-song-more")
                guard let more = DebugProbes.windowFrame("player-more") else {
                    log.append("player more (compact): merged More not found, window \(Int(window.frame.width)) pt (FAIL)")
                    return .main
                }
                log.append("player more (compact): window \(Int(window.frame.width)) pt, merged More at \(more); a second song More shown: \(songMore == nil ? "no (PASS)" : "yes (FAIL)")")
                click(at: CGPoint(x: more.midX, y: more.midY))
                await settle(0.6)
                let titles = KeyboardMoreMenu.current?.items.map { $0.isSeparatorItem ? "—" : $0.title } ?? []
                log.append("player more (compact): menu \(titles.joined(separator: ", ")) (\(titles.first == "Play Next" && titles.contains("Mini Player") ? "PASS" : "FAIL"))")
                let playOn = KeyboardMoreMenu.current?.items.first { $0.title == "Play On" }
                let inline = KeyboardMoreMenu.current?.items.contains { $0.title == "System Default" } ?? false
                log.append("player more (compact): Play On \(playOn?.hasSubmenu == true ? "is a submenu" : playOn == nil ? "missing" : "is not a submenu"), devices listed inline: \(inline ? "yes" : "no") (\(playOn?.hasSubmenu == true && !inline ? "PASS" : "FAIL"))")
                return .mainWithMenu
            } reset: {
                KeyboardMoreMenu.current?.cancelTracking()
                await settle(0.4)
                window.makeFirstResponder(nil)
                model.inspector = nil
                model.columnVisibility = .all
                place(w, h)
                await settle(0.6)
                parkPointer()
            },
            Shot(name: "mini-player", about: "The mini player window (⌥⌘M), pointer away: the song with Like and More (…) after its title, then previous, play/pause and next") {
                let mini = await openMiniPlayer(hovering: false)
                await settle(0.4)
                let focused = DebugProbes.notes["more-focus"] == "mini-more"
                log.append("mini player at rest: More \(focused ? "has keyboard focus, its ring showing (FAIL)" : "without focus or ring (PASS)")")
                return .window(mini)
            },
            Shot(name: "mini-player-more", about: "The mini player with its More (…) clicked: the song's menu, the same as the full-screen player's; the clicked button shows a pressed fill, no focus ring") {
                let mini = await openMiniPlayer(hovering: false)
                guard let mini, let more = DebugProbes.windowFrame("mini-more") else {
                    log.append("mini player more: no More button (FAIL)")
                    return .window(mini)
                }
                log.append("mini player like: \(DebugProbes.windowFrame("mini-like").map { "at \($0) (PASS)" } ?? "missing (FAIL)")")
                click(at: CGPoint(x: more.midX, y: more.midY), in: mini)
                await settle(0.8)
                let items = KeyboardMoreMenu.current?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
                let pass = items.first == "Play Next" && items.contains("Go to Album") && items.contains("Copy Link")
                log.append("mini player more: menu \(items.joined(separator: ", ")) (\(pass ? "PASS" : "FAIL"))")
                return .windowWithMenu(mini)
            } reset: {
                KeyboardMoreMenu.current?.cancelTracking()
                await settle(0.3)
            },
            Shot(name: "mini-player-notice-error", about: "The mini player in front of the main window after its Like (clicked for real) that the service refused offline: the failure notice inside the mini player, wrapping under the traffic lights, with Try Again and a close button; previous, play/pause and next stay clear below") {
                let mini = await openMiniPlayer(hovering: false)
                return await failLikeInMiniPlayer(mini, into: &log)
            } reset: {
                await checkMiniNoticeButtons(into: &log)
                yt.failingWrites = nil
                sp.failingWrites = nil
                model.notice = nil
                await settle(0.3)
            },
            Shot(name: "mini-player-notice-partial", about: "The mini player in front of the main window after removing two songs of a Spotify playlist with the service failing partway: the partly applied edit's notice inside the mini player, with Undo, Try Again and Leave As Is inside the card") {
                let mini = await openMiniPlayer(hovering: false)
                return await partialEditInMiniPlayer(mini, into: &log)
            } reset: {
                await endPartialPlaylistEdit("mini-player-notice-partial", into: &log)
                // The main window key again: a later shot's notice and Edit menu belong to it.
                MiniPlayerWindow.window?.close()
                window.makeKeyAndOrderFront(nil)
                await settle(0.6)
            },
            Shot(name: "mini-player-hover", about: "The mini player with the pointer over it: timeline, volume, and Lyrics, Playing Next and Back to the Main Window top right revealed; the strip's own time line hides, so one clock shows") {
                let mini = await openMiniPlayer(hovering: true)
                log.append("mini player expand: \(DebugProbes.windowFrame("mini-expand").map { "at \($0), in the top-right group (\($0.minY < 60 ? "PASS" : "FAIL"))" } ?? "missing (FAIL)")")
                return .window(mini)
            } reset: {
                if let mini = MiniPlayerWindow.window {
                    move(to: CGPoint(x: mini.frame.minX - 40, y: mini.frame.minY - 40), in: mini)
                    try? await Task.sleep(for: .milliseconds(300))
                    mini.close()
                }
                parkPointer()
            },
        ]

        let signedOut: [Shot] = [
            Shot(name: "signed-out-home", about: "Signed out of both services, first launch: Home with nothing played or pinned: charts, new releases and moods, no Listen again or mixes; the grey \"Sign In ⌄\" pill by the greeting (a secondary way in; the empty Library's is the accent one)") {
                model.select(.home)
                await settle(1.0)
                logCardEdges("signed-out-home 1440", into: &log)
                // The empty Recently Played caption starts on its heading's edge.
                for _ in 0..<20 where DebugProbes.windowFrame("sidebar-recents-caption") == nil { await settle(0.1) }
                if let caption = DebugProbes.windowFrame("sidebar-recents-caption"), let heading = DebugProbes.windowFrame("sidebar-header-Recently Played") {
                    let offset = caption.minX - heading.minX
                    log.append(String(format: "signed-out caption: starts %.1f pt from the Recently Played heading's edge (%@)", offset, abs(offset) <= 0.5 ? "PASS" : "FAIL"))
                } else {
                    @MainActor func state(_ key: String) -> String {
                        guard let view = DebugProbes.view(key) else { return "no probe" }
                        return view.window == nil ? "probe off-window" : "probe found"
                    }
                    log.append("signed-out caption: not found: caption \(state("sidebar-recents-caption")), heading \(state("sidebar-header-Recently Played")) (FAIL)")
                }
                return .main
            } reset: {
                // Card rows further down, and at 960 pt with the sidebar, then the window back.
                scrollPage(to: 0.35)
                await settle(0.6)
                logCardEdges("signed-out-home 1440 scrolled", into: &log)
                place(960, h)
                await settle(0.8)
                scrollPage(to: 0)
                await settle(0.4)
                logCardEdges("signed-out-home 960", into: &log)
                scrollPage(to: 0.35)
                await settle(0.6)
                logCardEdges("signed-out-home 960 scrolled", into: &log)
                place(w, h)
                scrollPageToTop()
                await settle(0.6)
            },
            Shot(name: "signed-out-sign-in", about: "Signed out: Home's Sign In button by the greeting with its menu open: \"Sign in to\" over one item per service (YouTube Music…, Spotify…)") {
                model.select(.home)
                await settle(1.0)
                // Home may still be swapping its placeholder for the shelves after the sign-out.
                for _ in 0..<20 where DebugProbes.windowFrame("home-sign-in") == nil { await settle(0.15) }
                // Right after signing out, the first pass's Home kept a Sign In button without its probe; a fresh
                // Home makes one.
                if DebugProbes.windowFrame("home-sign-in") == nil {
                    model.select(.explore)
                    await settle(0.8)
                    model.select(.home)
                    for _ in 0..<20 where DebugProbes.windowFrame("home-sign-in") == nil { await settle(0.15) }
                }
                // The button sits by the greeting at the top of the page. An earlier shot's `scrollPage(to: 0)` leaves
                // the page under the toolbar's inset (round 23's capture: the button hidden under the toolbar, the
                // click landing on nothing), so scroll to the real top first.
                scrollPageToTop()
                await settle(0.5)
                let probe = DebugProbes.views.object(forKey: "home-sign-in")
                // The probe, else the control AppKit made for the menu (found by its accessibility label).
                let control = views(of: NSView.self, in: window.contentView).first {
                    $0.accessibilityLabel() == "Sign In" && $0.frame.width > 20 && !$0.isHiddenOrHasHiddenAncestor
                }
                let found = DebugProbes.windowFrame("home-sign-in") ?? control.map { view in
                    let r = view.convert(view.bounds, to: nil)
                    return CGRect(x: r.minX, y: window.frame.height - r.maxY, width: r.width, height: r.height)
                }
                log.append("signed-out-sign-in: \(pageScrollState().text); probe \(probe == nil ? "missing" : probe?.window == nil ? "off-window" : "found"), control \(control.map { "\(type(of: $0))" } ?? "missing")")
                guard let button = found else {
                    log.append("signed-out-sign-in: Sign In button not found (FAIL)")
                    return .main
                }
                // In view: below the toolbar (52 pt) and above the floating player, inside the window's width.
                let height = window.contentView?.bounds.height ?? 0
                let visible = CGRect(x: 0, y: 52, width: window.frame.width, height: max(0, height - 52 - 100))
                let inView = visible.contains(button)
                log.append(String(format: "signed-out-sign-in: Sign In button %.0f×%.0f pt at %.0f, %.0f, in view below the toolbar: %@ (%@)",
                                  button.width, button.height, button.minX, button.minY, inView ? "yes" : "no", inView ? "PASS" : "FAIL"))
                // The menu AppKit opens for it, read when it starts tracking.
                let tracked = TrackedMenu()
                let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
                    // Posted on the main thread, by the menu itself.
                    nonisolated(unsafe) let menu = note.object as? NSMenu
                    MainActor.assumeIsolated { if tracked.menu == nil { tracked.menu = menu } }
                }
                click(at: CGPoint(x: button.midX, y: button.midY))
                for _ in 0..<20 where tracked.menu == nil { await settle(0.1) }
                await settle(0.3)
                NotificationCenter.default.removeObserver(observer)
                let opened = tracked.menu
                let titles = opened?.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map(\.title) ?? []
                let services = ["YouTube Music…", "Spotify…"]
                let listed = services.allSatisfy(titles.contains)
                log.append("signed-out-sign-in: menu \(opened == nil ? "did not open" : "items \(titles.joined(separator: ", "))") (\(opened != nil && listed ? "PASS: both services listed" : "FAIL: expected \(services.joined(separator: " and "))"))")
                return .mainWithMenu
            } reset: {
                press(keyCode: 53, character: 27, function: false)
                await settle(0.4)
            },
            Shot(name: "signed-out-library", about: "Signed out: the Library row's sign-in empty state, its \"Sign In ⌄\" menu in the accent fill with white text that Settings › Accounts and the welcome sheet use for Sign In (Home's and Search's Sign In stay the grey pill)") {
                model.select(.recentlyAdded)
                await settle(0.8)
                logSignInFill(into: &log)
                return .main
            },
            Shot(name: "signed-out-search", about: "Signed out: search for \"olivia\" (YouTube Music searches signed out): Home's grey \"Sign In ⌄\" menu at the top right above the first heading, as on Home") {
                model.select(.search); model.searchText = "olivia"
                await settle(1.0)
                return .main
            } reset: { model.searchText = "" },
            Shot(name: "signed-out-accounts", about: "Signed out: Settings › Accounts with both services not signed in, each with the same accent \"Sign In…\" button") {
                .window(await openSettings(.accounts))
            } reset: { settingsWindow()?.close() },
            Shot(name: "onboarding", about: "The first-run flow's Your music step over the main window") {
                model.select(.home)
                model.showOnboarding = true
                model.firstRun?.go(to: .music)
                await settle(0.8)
                return .main
            } reset: {
                model.showOnboarding = false
                await settle(0.6)
            },
        ]

        let only = env["MEDLEY_COUNCIL_SHOTS"].map { Set($0.split(separator: ",").map(String.init)) }
        func runAll(_ list: [Shot]) async {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                NSApp.appearance = NSAppearance(named: appearance)
                let mode = appearance == .aqua ? "light" : "dark"
                for shot in list where only?.contains(shot.name) ?? true {
                    if model.player.current != nil, model.player.current?.id != hero.tracks[hero.index].id { playHero(hero) }
                    // Every shot starts with the sidebar at its top (Home and New in view); shots that need a row
                    // further down scroll to it themselves. A shot scrolled to Recently Played left the next ones,
                    // and the whole dark pass, with the top of the list scrolled away.
                    resetSidebarScroll()
                    let target = await shot.apply()
                    await settle(1.6)
                    if model.player.current != nil { model.player.seek(to: hero.position) }
                    await settle(0.25)
                    NSApp.activate()
                    if case .window(let other?) = target { other.makeKeyAndOrderFront(nil) } else { window.makeKeyAndOrderFront(nil) }
                    await settle(0.2)
                    let file = "\(shot.name)-\(mode).png"
                    if let image = image(for: target) {
                        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(file))
                        // Every shot at the 2x display's density (round 25's signed-out shots came out at 1x).
                        let scale = window.backingScaleFactor
                        log.append("\(file): \(image.width)x\(image.height)\(scale >= 2 ? "" : " (FAIL: captured at \(Int(scale))x)")")
                    } else {
                        log.append("\(file): capture failed")
                    }
                    if mode == "light" { manifest.append("\(shot.name)\t\(shot.about)") }
                    await shot.reset?()
                    write(log, manifest)
                }
            }
        }

        await runAll(shots)
        if only?.contains("sidebar-play-check") ?? true {
            await checkSidebarPlay(hero: hero, into: &log)
            write(log, manifest)
        }
        if only?.contains("artist-faces") ?? true {
            await logAllArtistFaces(into: &log)
            write(log, manifest)
        }
        if only?.contains("focus-checks") ?? true {
            await checkListFocus(heroRoute: heroRoute, into: &log)
            write(log, manifest)
        }
        if only?.contains("space-keys") ?? true {
            await checkSpaceKeys(hero: hero, heroRoute: heroRoute, into: &log)
            write(log, manifest)
        }

        if only?.contains("account-routes") ?? true {
            await checkAccountRoutes(into: &log)
            write(log, manifest)
        }

        // Signed out, first launch: no account, nothing playing, nothing pinned or played.
        await yt.signOut()
        await sp.signOut()
        model.player.clearQueue()
        for entry in model.collections.pinned { model.unpinFromSidebar(entry.id) }
        for entry in model.collections.recents { model.removeFromRecentlyPlayed(entry.id) }
        await model.refreshLibraryState()
        model.cache.invalidate(prefix: "home")
        model.cache.invalidate(prefix: "explore")
        model.refreshTick += 1
        await settle(0.6)
        await runAll(signedOut)

        settingsWindow()?.close()
        log.append(String(format: "buffering waits: %d settles waited %.1f s in all for the player's audio (the play button's ring never caught by chance)",
                          Self.bufferingWaits, Double(Self.bufferingWaitMs) / 1000))
        write(log, manifest)
    }

    // MARK: Track lists: sorted Play, several rows selected

    /// Sorts the playlist by Title (two clicks: Z to A), clicks the header's Play, and checks the queue: every song of
    /// the playlist, in the order shown, from the first row (PASS/FAIL).
    private func sortedHeaderPlay(_ playlist: Playlist, into log: inout [String]) async {
        guard let title = DebugProbes.windowFrame("sort-menu") else {
            log.append("playlist-sorted-play: Title header not found (FAIL)"); return
        }
        let point = CGPoint(x: title.minX + 20, y: title.midY)
        click(at: point)
        await settle(0.5)
        click(at: point)
        await settle(1.0)
        let sort = DebugProbes.notes["track-sort"] ?? "not reported"
        guard let play = DebugProbes.windowFrame("play-button") else {
            log.append("playlist-sorted-play: header Play not found (FAIL)"); return
        }
        parkPointer()
        click(at: CGPoint(x: play.midX, y: play.midY))
        for _ in 0..<30 where model.playingFrom?.title != playlist.title { await settle(0.1) }
        await settle(0.5)
        var all: [Track] = []
        if var detail = try? await sp.playlist(id: playlist.providerID) {
            all = detail.tracks
            while let next = detail.continuation, let page = try? await sp.playlistTracks(continuation: next) {
                all += page.items
                detail.continuation = page.continuation
            }
        }
        let expected = TrackSort(key: .title, ascending: false).sorted(all, length: { model.displayDuration(for: $0) }).map(\.id)
        let queued = model.player.queue.filter { !$0.isAutoplay }.map(\.track.id)
        let current = model.player.current
        let inOrder = !expected.isEmpty && queued == expected
        let fromFirst = current?.id == expected.first
        let titles = model.player.queue.prefix(3).map(\.track.title).joined(separator: " / ")
        log.append("playlist-sorted-play: sorted \(sort), header Play queued \(queued.count) of \(all.count) songs from \(model.playingFrom?.title ?? "nothing"), first \(titles): in the order shown \(inOrder ? "PASS" : "FAIL"); playing its first row “\(current?.title ?? "nothing")” \(fromFirst ? "PASS" : "FAIL")")
    }

    /// The frame of row `index` of the page's track list (its `track-row-<n>` probe).
    private func trackRow(_ index: Int) -> CGRect? { DebugProbes.windowFrame("track-row-\(index)") ?? model.debugFrames["track-row-\(index)"] }

    /// Click, ⌘-click, ⇧-click and ⇧↓ in an editable Spotify playlist, each logged against the rows it should select,
    /// then a selected row's More: the menu for the selection (PASS/FAIL).
    private func multiSelect(into log: inout [String]) async -> Target {
        guard let playlist = sp.catalog.playlists.first(where: \.isEditable) else {
            log.append("playlist-multi-select: no editable Spotify playlist (FAIL)"); return .main
        }
        model.inspector = nil
        await open(.playlist(.spotify, id: playlist.providerID, preview: playlist))
        await settle(1.0)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        parkPointer()
        func titleSpot(_ row: Int) -> CGPoint? { trackRow(row).map { CGPoint(x: $0.minX + 140, y: $0.midY) } }
        func step(_ label: String, expect: String) -> Bool {
            let note = DebugProbes.notes["track-list"] ?? "not focused"
            let ok = note.hasPrefix("focused, selected \(expect),")
            log.append("playlist-multi-select: \(label): \(note) (\(ok ? "PASS" : "FAIL: expected selected \(expect)"))")
            return ok
        }
        guard let first = titleSpot(1), let third = titleSpot(3), let fifth = titleSpot(5) else {
            log.append("playlist-multi-select: track rows not found (FAIL)"); return .main
        }
        click(at: first)
        await settle(0.7)
        _ = step("click row 1", expect: "row 1")
        click(at: third, modifiers: .command)
        await settle(0.7)
        _ = step("⌘-click row 3", expect: "rows 1, 3")
        click(at: fifth, modifiers: .shift)
        await settle(0.7)
        _ = step("⇧-click row 5", expect: "rows 1, 3, 4, 5")
        press(keyCode: 125, character: NSDownArrowFunctionKey, modifiers: .shift)
        await settle(0.5)
        _ = step("⇧↓", expect: "rows 1, 3, 4, 5, 6")
        Self.multiSelectOrder = DebugProbes.notes["track-list-selection"] ?? ""
        // The "…" on the focused accent selection is white like the rest of the row; on an unselected row, the label ink.
        for (index, selected) in [(3, true), (5, true), (2, false)] {
            log.append(selectedMoreInkCheck(row: index, selected: selected))
        }
        // A selected row's More: the selection's menu, read when AppKit starts tracking it.
        guard let row = trackRow(3) else { return .main }
        let more = CGPoint(x: row.maxX - 10 - Metrics.durationWidth - 6 - 12, y: row.midY)
        hover(at: CGPoint(x: row.midX, y: row.midY))
        await settle(0.3)
        let tracked = TrackedMenu()
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            nonisolated(unsafe) let menu = note.object as? NSMenu
            MainActor.assumeIsolated { if tracked.menu == nil { tracked.menu = menu } }
        }
        click(at: more)
        for _ in 0..<20 where tracked.menu == nil { await settle(0.1) }
        await settle(0.3)
        NotificationCenter.default.removeObserver(observer)
        Self.multiSelectMenu = tracked.menu
        let titles = tracked.menu?.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map(\.title) ?? []
        let wanted = ["5 Songs", "Play Next", "Add to Queue", "Add to Playlist", "Remove from Playlist"]
        log.append("playlist-multi-select: More on selected row 3: \(tracked.menu == nil ? "no menu" : titles.joined(separator: ", ")) (\(titles == wanted ? "PASS: the selection's menu" : "FAIL: expected \(wanted.joined(separator: ", "))"))")
        let still = DebugProbes.notes["track-list"] ?? "not focused"
        log.append("playlist-multi-select: selection with the menu open: \(still) (\(still.hasPrefix("focused, selected rows 1, 3, 4, 5, 6,") ? "PASS" : "FAIL"))")
        return .mainWithMenu
    }

    private static var multiSelectMenu: NSMenu?
    private static var multiSelectOrder = ""

    /// Picks Play Next in the selection's menu (the five songs next in the queue, in the order shown), then ⌘A (every
    /// row), a plain click (that row alone) and Escape (nothing; the row outlined) (PASS/FAIL each).
    private func finishMultiSelect(hero: DemoNowPlaying, into log: inout [String]) async {
        let menu = Self.multiSelectMenu
        Self.multiSelectMenu = nil
        menu?.cancelTracking()
        await settle(0.4)
        if let menu, let index = menu.items.firstIndex(where: { $0.title == "Play Next" }) {
            menu.performActionForItem(at: index)
            await settle(0.6)
            let next = model.player.upNext.prefix(5).map(\.track.title).joined(separator: " / ")
            log.append("playlist-multi-select: Play Next queued \(next) (\(next == Self.multiSelectOrder && !next.isEmpty ? "PASS: the selected rows in the order shown" : "FAIL: expected \(Self.multiSelectOrder)"))")
        } else {
            log.append("playlist-multi-select: Play Next not found in the menu (FAIL)")
        }
        parkPointer()
        pressCommandA()
        await settle(0.5)
        let all = DebugProbes.notes["track-list"] ?? "not focused"
        let rows = all.contains("selected rows ") ? (all.components(separatedBy: "selected rows ").last?.components(separatedBy: ", outlined").first ?? "").split(separator: ",").count : 0
        var total = 0
        if let editable = sp.catalog.playlists.first(where: \.isEditable) { total = await playlistIDs(sp, editable).count }
        log.append("playlist-multi-select: ⌘A selected \(rows) of \(total) rows (\(rows == total && total > 0 ? "PASS: every row" : "FAIL"))")
        if let row = trackRow(2) {
            click(at: CGPoint(x: row.minX + 140, y: row.midY))
            await settle(0.7)
            let note = DebugProbes.notes["track-list"] ?? "not focused"
            log.append("playlist-multi-select: plain click row 2: \(note) (\(note.hasPrefix("focused, selected row 2,") ? "PASS" : "FAIL"))")
        }
        press(keyCode: 53, character: 0x1B, function: false)
        await settle(0.4)
        let escaped = DebugProbes.notes["track-list"] ?? "not focused"
        log.append("playlist-multi-select: Escape: \(escaped) (\(escaped == "focused, selected row none, outlined row 2" ? "PASS" : "FAIL"))")
        window.makeFirstResponder(nil)
        model.player.clearQueue()
        playHero(hero)
        model.select(.home)
        await settle(0.4)
    }

    // MARK: Account buttons

    /// Every account button goes where it says (round 26): "Open Accounts…" on an error page to Settings › Accounts,
    /// and each button naming a service ("Connect Spotify" on Home and Search, the Library note's and empty page's
    /// "Sign In to Spotify…", the filtered Home's) to that service's own sign-in sheet; never the welcome sheet.
    /// Real clicks on each button, found by its `LayoutProbe`. Spotify ends signed out (the signed-out pass follows).
    private func checkAccountRoutes(into log: inout [String]) async {
        func button(_ key: String) async -> CGRect? {
            for _ in 0..<40 where DebugProbes.windowFrame(key) == nil { await settle(0.1) }
            return DebugProbes.windowFrame(key)
        }
        func press(_ key: String, _ label: String) async -> Bool {
            guard let frame = await button(key) else {
                log.append("account route: \(label): button not found (FAIL)")
                return false
            }
            click(at: CGPoint(x: frame.midX, y: frame.midY))
            await settle(1.0)
            return true
        }
        func expectSignInSheet(_ label: String) async {
            let sheet = window.attachedSheet
            let ok = model.signInRequest == .spotify && sheet != nil && !model.showOnboarding
            log.append("account route: \(label) → \(model.signInRequest.map { "\($0.displayName) sign-in" } ?? "no sign-in"), sheet \(sheet == nil ? "none" : "attached"), welcome sheet \(model.showOnboarding ? "shown" : "not shown") (\(ok ? "PASS" : "FAIL"))")
            model.signInRequest = nil
            await settle(0.8)
        }

        // An error page whose service says the sign-in is gone: "Open Accounts…". Settings left on General first,
        // so the pane it opens on is the button's doing.
        settingsWindow()?.close()
        _ = await openSettings(.general)
        settingsWindow()?.close()
        await settle(0.4)
        if let weekly = sp.catalog.playlists.first(where: { $0.title == "Discover Weekly" }) {
            sp.detailFailure = .notSignedIn
            model.cache.invalidate(prefix: "playlist:")
            await open(.playlist(.spotify, id: weekly.providerID, preview: weekly))
            if await press("open-accounts", "error page's Open Accounts…") {
                let settings = settingsWindow()
                let ok = settings?.title == SettingsPane.accounts.title && !model.showOnboarding && window.attachedSheet == nil
                log.append("account route: error page's Open Accounts… → Settings \(settings.map { "› \($0.title)" } ?? "not open"), welcome sheet \(model.showOnboarding ? "shown" : "not shown") (\(ok ? "PASS" : "FAIL"))")
            }
            settingsWindow()?.close()
            sp.detailFailure = nil
            model.cache.invalidate(prefix: "playlist:")
            model.path = []
            await settle(0.5)
        }

        // Library › Songs while Spotify's sign-in is gone: the note's "Sign In to Spotify…".
        model.cache.invalidate(prefix: "library:")
        sp.libraryFailure = .notSignedIn
        model.select(.home)
        await settle(0.3)
        model.select(.songs)
        if await press("library-issue-action-spotify", "Library note's Sign In to Spotify…") {
            await expectSignInSheet("Library note's Sign In to Spotify…")
        }
        sp.libraryFailure = nil
        model.cache.invalidate(prefix: "library:")

        // Spotify signed out, YouTube Music signed in: Home's and Search's "Connect Spotify".
        await sp.signOut()
        await model.refreshLibraryState()
        model.select(.explore)
        await settle(0.3)
        model.select(.home)
        // Home loads again for the one service left; click once its button has settled at the top of the page.
        _ = await button("connect-spotify")
        await settle(1.0)
        scrollPageToTop()
        await settle(0.5)
        if await press("connect-spotify", "Home's Connect Spotify") { await expectSignInSheet("Home's Connect Spotify") }
        model.select(.search)
        model.searchText = "olivia"
        await settle(1.0)
        if await press("connect-spotify", "Search's Connect Spotify") { await expectSignInSheet("Search's Connect Spotify") }
        model.searchText = ""

        // The filter on Spotify, signed out: the empty Library's and Home's "Sign In to Spotify…".
        model.serviceFilter = .spotify
        model.select(.songs)
        if await press("library-account-action", "empty Library's Sign In to Spotify…") {
            await expectSignInSheet("empty Library's Sign In to Spotify…")
        }
        model.select(.home)
        if await press("no-services-sign-in", "filtered Home's Sign In to Spotify…") {
            await expectSignInSheet("filtered Home's Sign In to Spotify…")
        }
        model.serviceFilter = .all
        // The mock's sessions don't change generation on sign-out, so Home and New, loaded here with YouTube Music
        // alone, would be kept for the signed-out pass under the same key: load them again there.
        model.cache.invalidate(prefix: "home")
        model.cache.invalidate(prefix: "explore")
        model.refreshTick += 1
        model.select(.home)
        await settle(0.6)
    }

    // MARK: Setup

    /// The palest and the darkest covers in the demo set by mean brightness (179 and 24 of 255; the hero's is 152).
    static let paleCover = "morgan-wallen-im-the-problem"
    static let darkCover = "don-toliver-octane"

    /// Plays the first song of a demo album without recording it in Recently Played (no route), so later sidebar
    /// shots are unchanged, and opens the full-screen player on it.
    private func presentFullScreen(cover key: String, panel: InspectorPanel?, into log: inout [String]) async -> Target {
        let found = [yt, sp].lazy.compactMap { provider in provider.demoAlbum(key).map { ($0, provider) } }.first
        guard let (album, provider) = found, let tracks = provider.catalog.albumTracks[album.providerID], !tracks.isEmpty else {
            log.append("cover \(key): album not in the demo catalog")
            return .main
        }
        model.inspector = nil
        model.play(tracks, from: AppModel.PlayingFrom(title: album.title))
        model.fullScreenPanel = panel
        model.isFullScreenPlayerPresented = true
        await settle(0.6)
        if let frame = DebugProbes.windowFrame("fullscreen-metadata") {
            log.append("cover \(key): metadata block at \(frame) (top-left window points)")
        }
        logFullScreenMetadata("cover \(key)", album: album.title, into: &log)
        return .main
    }

    // MARK: Removal and Undo

    private static var removal: (playlist: Playlist, before: [String], song: Track)?

    private func playlistIDs(_ provider: MockProvider, _ playlist: Playlist) async -> [String] {
        guard var detail = try? await provider.playlist(id: playlist.providerID) else { return [] }
        var all = detail.tracks
        while let next = detail.continuation, let page = try? await provider.playlistTracks(continuation: next) {
            all += page.items
            detail.continuation = page.continuation
        }
        return all.map(\.id)
    }

    /// Remove from Playlist (an editable Spotify playlist, which can put songs back in place): removed at once,
    /// Edit › Undo named after the song, the notice with Undo.
    private func removeFromPlaylistWithUndo(into log: inout [String]) async -> Target {
        // The listener's own (editable) Spotify playlist.
        guard let playlist = sp.catalog.playlists.first(where: \.isEditable) else {
            log.append("playlist-remove-undo: no editable Spotify playlist (FAIL)"); return .main
        }
        model.inspector = nil
        await open(.playlist(.spotify, id: playlist.providerID, preview: playlist))
        await settle(1.0)
        let before = await playlistIDs(sp, playlist)
        guard let detail = try? await sp.playlist(id: playlist.providerID), detail.tracks.count > 2 else {
            log.append("playlist-remove-undo: playlist empty (FAIL)"); return .main
        }
        let song = detail.tracks[1]
        Self.removal = (playlist, before, song)
        model.noticeDuration = .seconds(30)
        model.requestRemove([song], from: playlist, undoManager: window.undoManager)
        await settle(1.2)
        let after = await playlistIDs(sp, playlist)
        let title = window.undoManager?.undoMenuItemTitle ?? "none"
        let notice = model.notice
        log.append("playlist-remove-undo: “\(song.title)” removed from the service: \(after.contains(song.id) ? "no (FAIL)" : "yes (PASS)"), no dialog: \(model.pendingPlaylistRemoval == nil ? "PASS" : "FAIL"); Edit menu \"\(title)\" (\(title == "Undo Remove “\(song.title)”" ? "PASS" : "FAIL")); notice \"\(notice?.text ?? "none")\" with \(notice?.action?.title ?? "no button") (\(notice?.action?.title == "Undo" ? "PASS" : "FAIL")), button \(DebugProbes.windowFrame("notice-action").map { "at \($0)" } ?? "not found")")
        // The real Edit menu once the removal settled: Undo names it and is enabled; no Redo of it.
        if let items = editMenuUndoItems() {
            let ok = items.undo == "Undo Remove “\(song.title)”" && items.undoEnabled && !items.redo.contains("Remove “\(song.title)”")
            log.append("playlist-remove-undo: Edit menu after settling: \"\(items.undo)\" \(items.undoEnabled ? "enabled" : "disabled"), \"\(items.redo)\" \(items.redoEnabled ? "enabled" : "disabled") (\(ok ? "PASS" : "FAIL"))")
        } else {
            log.append("playlist-remove-undo: Edit menu's Undo and Redo not found (FAIL)")
        }
        return .main
    }

    /// Edit › Undo's and Redo's titles and enabled states as the menu shows them now (SwiftUI updates its items as a
    /// menu opens, and validation sets the titles from the undo manager).
    private func editMenuUndoItems() -> (undo: String, undoEnabled: Bool, redo: String, redoEnabled: Bool)? {
        guard let edit = NSApp.mainMenu?.items.first(where: { $0.title == "Edit" })?.submenu else { return nil }
        edit.delegate?.menuNeedsUpdate?(edit)
        edit.update()
        func item(_ action: String, _ prefix: String) -> NSMenuItem? {
            edit.items.first { $0.action == Selector((action)) } ?? edit.items.first { $0.title.hasPrefix(prefix) }
        }
        guard let undo = item("undo:", "Undo"), let redo = item("redo:", "Redo") else { return nil }
        return (undo.title, undo.isEnabled, redo.title, redo.isEnabled)
    }

    /// Removes the second and third songs of an editable Spotify playlist in requests of one, the second failing
    /// offline: a partly applied edit. With `closeNotice` the failure notice is closed, so the page's banner shows.
    /// Logs the notice's buttons, the lock and the banner (PASS/FAIL).
    private func partialPlaylistEdit(_ name: String, closeNotice: Bool, into log: inout [String]) async -> Target {
        guard let playlist = sp.catalog.playlists.first(where: \.isEditable) else {
            log.append("\(name): no editable Spotify playlist (FAIL)"); return .main
        }
        model.inspector = nil
        await open(.playlist(.spotify, id: playlist.providerID, preview: playlist))
        await settle(1.0)
        let before = await playlistIDs(sp, playlist)
        guard let detail = try? await sp.playlist(id: playlist.providerID), detail.tracks.count > 3 else {
            log.append("\(name): playlist too short (FAIL)"); return .main
        }
        Self.partial = (playlist, before)
        model.noticeDuration = .seconds(30)
        sp.editBatchSize = 1
        sp.playlistEditFailures = [sp.playlistEdits.count + 2: .network(URLError(.notConnectedToInternet).localizedDescription)]
        model.requestRemove(Array(detail.tracks[1...2]), from: playlist, undoManager: window.undoManager)
        await settle(1.2)
        let notice = model.notice
        let buttons = [notice?.action?.title, notice?.retry == nil ? nil : "Try Again", notice?.secondaryAction?.title].compactMap { $0 }
        log.append("\(name): notice \"\(notice?.text ?? "none")\" with \(buttons.joined(separator: ", ")) (\(buttons == ["Undo", "Try Again", "Leave As Is"] ? "PASS" : "FAIL")); Edit menu Undo \(window.undoManager?.canUndo == true ? "\"\(window.undoManager?.undoMenuItemTitle ?? "")\"" : "none") while partly applied")
        if closeNotice {
            model.dismissNotice()
            await settle(0.6)
            let banner = DebugProbes.windowFrame("playlist-edit-banner")
            log.append("\(name): notice closed, playlist still locked: \(model.canEdit(playlist) ? "no (FAIL)" : "yes (PASS)"); banner \(banner.map { "at \($0) (PASS)" } ?? "not found (FAIL)")")
        }
        return .main
    }

    /// The partly applied edit's Undo (the banner's or the notice's, the same call): the playlist as before, unlocked.
    private func endPartialPlaylistEdit(_ name: String, into log: inout [String]) async {
        defer { model.noticeDuration = .seconds(2.2); model.notice = nil; sp.editBatchSize = nil; sp.playlistEditFailures = [:] }
        guard case let (playlist, before)? = Self.partial else { return }
        Self.partial = nil
        if let edit = model.partialEdit(of: playlist) {
            model.undoPartial(edit)
            await model.lastPlaylistEdit?.value
        }
        await settle(0.6)
        let restored = await playlistIDs(sp, playlist)
        log.append("\(name): after Undo the playlist as before: \(restored == before ? "PASS" : "FAIL"), unlocked: \(model.canEdit(playlist) ? "PASS" : "FAIL")")
    }

    private static var partial: (Playlist, [String])?

    /// Puts the playlist back to exactly `tracks` on the mock service and loads its page again.
    private func restorePlaylist(_ playlist: Playlist, to tracks: [Track]) async {
        let current = sp.catalog.playlistTracks[playlist.providerID] ?? []
        if !current.isEmpty { try? await sp.remove(current, fromPlaylist: playlist.providerID) }
        if !tracks.isEmpty { try? await sp.add(tracks, toPlaylist: playlist.providerID) }
        model.cache.invalidate(prefix: AppModel.playlistKey(playlist))
        model.refreshTick += 1
        await settle(0.6)
    }

    private static var changed: (playlist: Playlist, original: [Track], song: Track, outsider: Track)?

    /// Remove from Playlist on the second song, then another device puts a song first, then Edit › Undo: the check
    /// finds the playlist changed, puts nothing back at the old place and offers Add Back at End (PASS/FAIL).
    private func changedPlaylistUndo(name: String = "playlist-edit-changed", into log: inout [String]) async -> Target {
        guard let playlist = sp.catalog.playlists.first(where: \.isEditable) else {
            log.append("\(name): no editable Spotify playlist (FAIL)"); return .main
        }
        let original = sp.catalog.playlistTracks[playlist.providerID] ?? []
        guard original.count > 2, let outsider = sp.catalog.allTracks.first(where: { song in !original.contains { $0.id == song.id } }) else {
            log.append("\(name): playlist too short (FAIL)"); return .main
        }
        model.inspector = nil
        await open(.playlist(.spotify, id: playlist.providerID, preview: playlist))
        await settle(1.0)
        let song = original[1]
        Self.changed = (playlist, original, song, outsider)
        model.noticeDuration = .seconds(30)
        model.requestRemove([song], from: playlist, undoManager: window.undoManager)
        await settle(1.2)
        // Another device puts a song first.
        try? await sp.insert([outsider], intoPlaylist: playlist.providerID, at: 0)
        window.undoManager?.undo()
        await settle(1.2)
        let ids = await playlistIDs(sp, playlist)
        let expected = [outsider.id] + original.map(\.id).filter { $0 != song.id }
        let notice = model.notice
        let buttons = [notice?.action?.title, notice?.secondaryAction?.title].compactMap { $0 }
        let text = "“\(playlist.title)” changed since you removed this song."
        log.append("\(name): notice \"\(notice?.text ?? "none")\" (\(notice?.text == text ? "PASS" : "FAIL")) with \(buttons.joined(separator: ", ")) (\(buttons == ["Add Back at End", "Cancel"] ? "PASS" : "FAIL")), buttons \(["notice-action", "notice-secondary"].map { DebugProbes.windowFrame($0).map { "at \($0)" } ?? "missing" }.joined(separator: ", ")); nothing put back at the old place: \(ids == expected ? "PASS" : "FAIL"); playlist unlocked: \(model.canEdit(playlist) ? "PASS" : "FAIL")")
        return .main
    }

    /// Add Back at End on the changed playlist's notice: the song appended once (PASS/FAIL); then the playlist as it was.
    private func addBackAtEnd(name: String = "playlist-edit-changed", into log: inout [String]) async {
        defer { model.noticeDuration = .seconds(2.2); model.notice = nil }
        guard case let (playlist, original, song, outsider)? = Self.changed else { return }
        Self.changed = nil
        if let action = model.notice?.action, action.title == "Add Back at End" {
            action.run()
            await model.lastPlaylistEdit?.value
        }
        await settle(0.6)
        let ids = await playlistIDs(sp, playlist)
        let expected = [outsider.id] + original.map(\.id).filter { $0 != song.id } + [song.id]
        log.append("\(name): Add Back at End appended “\(song.title)” once: \(ids == expected ? "PASS" : "FAIL"); notice \"\(model.notice?.text ?? "none")\"")
        await restorePlaylist(playlist, to: original)
    }

    /// The changed-playlist notice (as `changedPlaylistUndo`), then Add Back at End while the service repeats a page
    /// token: nothing appended, "Couldn’t read all of “P”." with Try Again (PASS/FAIL).
    private func incompleteAddBack(into log: inout [String]) async -> Target {
        let name = "playlist-edit-read-incomplete"
        _ = await changedPlaylistUndo(name: name, into: &log)
        guard case let (playlist, _, _, _)? = Self.changed, let addBack = model.notice?.action else {
            log.append("\(name): no changed-playlist notice (FAIL)"); return .main
        }
        let before = await playlistIDs(sp, playlist)
        sp.repeatsContinuations = true
        addBack.run()
        await model.lastPlaylistEdit?.value
        await settle(0.8)
        sp.repeatsContinuations = false
        let after = await playlistIDs(sp, playlist)
        let notice = model.notice
        let text = "Couldn’t read all of “\(playlist.title)”."
        log.append("\(name): notice \"\(notice?.text ?? "none")\" (\(notice?.text == text ? "PASS" : "FAIL")) with Try Again \(notice?.retry != nil ? "(PASS)" : "missing (FAIL)"); nothing appended: \(after == before ? "PASS" : "FAIL")")
        return .main
    }

    private static var emptied: (playlist: Playlist, original: [Track])?

    /// A playlist down to one song (on the mock service), that song removed, then Edit › Undo failing offline and its
    /// notice closed: "This playlist is empty" with the banner over it (PASS/FAIL).
    private func emptyPlaylistBanner(into log: inout [String]) async -> Target {
        guard let playlist = sp.catalog.playlists.first(where: \.isEditable) else {
            log.append("playlist-edit-banner-empty: no editable Spotify playlist (FAIL)"); return .main
        }
        let original = sp.catalog.playlistTracks[playlist.providerID] ?? []
        guard let song = original.first else {
            log.append("playlist-edit-banner-empty: playlist empty already (FAIL)"); return .main
        }
        Self.emptied = (playlist, original)
        try? await sp.remove(original.filter { $0.id != song.id }, fromPlaylist: playlist.providerID)
        model.inspector = nil
        model.cache.invalidate(prefix: AppModel.playlistKey(playlist))
        model.refreshTick += 1
        await open(.playlist(.spotify, id: playlist.providerID, preview: playlist))
        await settle(1.0)
        model.noticeDuration = .seconds(30)
        model.requestRemove([song], from: playlist, undoManager: window.undoManager)
        await settle(1.2)
        sp.playlistEditFailures = [sp.playlistEdits.count + 1: .network(URLError(.notConnectedToInternet).localizedDescription)]
        window.undoManager?.undo()
        await settle(1.2)
        let notice = model.notice
        log.append("playlist-edit-banner-empty: Undo failed: \"\(notice?.text ?? "none")\" (\(notice?.kind == .failure ? "PASS" : "FAIL"))")
        model.dismissNotice()
        await settle(0.8)
        let ids = await playlistIDs(sp, playlist)
        let banner = DebugProbes.windowFrame("playlist-edit-banner")
        log.append("playlist-edit-banner-empty: the playlist empty: \(ids.isEmpty ? "PASS" : "FAIL"); still locked: \(model.canEdit(playlist) ? "no (FAIL)" : "yes (PASS)"); banner over the empty page \(banner.map { "at \($0) (PASS)" } ?? "not found (FAIL)")")
        return .main
    }

    /// The banner's Try Again (the same call): the song back, unlocked (PASS/FAIL); then the playlist as it was.
    private func endEmptyPlaylistBanner(into log: inout [String]) async {
        defer { model.noticeDuration = .seconds(2.2); model.notice = nil; sp.playlistEditFailures = [:] }
        guard case let (playlist, original)? = Self.emptied else { return }
        Self.emptied = nil
        sp.playlistEditFailures = [:]
        if let edit = model.partialEdit(of: playlist) {
            model.tryAgain(edit)
            await model.lastPlaylistEdit?.value
        }
        await settle(0.6)
        let ids = await playlistIDs(sp, playlist)
        log.append("playlist-edit-banner-empty: after Try Again the song is back: \(ids == original.prefix(1).map(\.id) ? "PASS" : "FAIL"), unlocked: \(model.canEdit(playlist) ? "PASS" : "FAIL")")
        await restorePlaylist(playlist, to: original)
    }

    /// Removes the second and third songs of an editable Spotify playlist with the mini player key, the second request
    /// failing offline: the partly applied edit's notice in the mini player, its three buttons inside the card.
    private func partialEditInMiniPlayer(_ mini: NSWindow?, into log: inout [String]) async -> Target {
        guard let mini, let playlist = sp.catalog.playlists.first(where: \.isEditable),
              let detail = try? await sp.playlist(id: playlist.providerID), detail.tracks.count > 3 else {
            log.append("mini player partial notice: no mini player or editable playlist (FAIL)")
            return .window(mini)
        }
        Self.partial = (playlist, await playlistIDs(sp, playlist))
        model.notice = nil
        model.noticeDuration = .seconds(30)
        sp.editBatchSize = 1
        sp.playlistEditFailures = [sp.playlistEdits.count + 2: .network(URLError(.notConnectedToInternet).localizedDescription)]
        NSApp.activate()
        mini.makeKeyAndOrderFront(nil)
        await settle(0.3)
        model.requestRemove(Array(detail.tracks[1...2]), from: playlist, undoManager: window.undoManager)
        await settle(1.2)
        let notice = model.notice
        let card = DebugProbes.windowFrame("mini-notice")
        let keys = ["mini-notice-action", "mini-notice-retry", "mini-notice-secondary"]
        let frames = keys.map { DebugProbes.windowFrame($0) }
        let inside = card.map { card in frames.allSatisfy { $0.map { card.insetBy(dx: -0.5, dy: -0.5).contains($0) } ?? false } } ?? false
        let buttons = [notice?.action?.title, notice?.retry == nil ? nil : "Try Again", notice?.secondaryAction?.title].compactMap { $0 }
        log.append("mini player partial notice: \"\(notice?.text ?? "none")\" in the mini player: \(notice?.inMiniPlayer == true && card != nil ? "at \(card!) (PASS)" : "no (FAIL)"); buttons \(buttons.joined(separator: ", ")) (\(buttons == ["Undo", "Try Again", "Leave As Is"] ? "PASS" : "FAIL")) at \(zip(keys, frames).map { "\($0) \($1.map { "\($0)" } ?? "missing")" }.joined(separator: ", ")); all inside the card: \(inside ? "PASS" : "FAIL")")
        return .window(mini)
    }

    /// Edit › Undo (the window's undo manager, as ⌘Z) puts the song back at its place.
    private func undoPlaylistRemoval(into log: inout [String]) async {
        defer { model.noticeDuration = .seconds(2.2); model.notice = nil }
        guard case let (playlist, before, song)? = Self.removal else { return }
        window.undoManager?.undo()
        await settle(1.2)
        let restored = await playlistIDs(sp, playlist)
        log.append("playlist-remove-undo: after Edit › Undo “\(song.title)” is back at place \((restored.firstIndex(of: song.id) ?? -1) + 1) of \(restored.count), the playlist as before: \(restored == before ? "PASS" : "FAIL"); notice \"\(model.notice?.text ?? "none")\"")
        // No Redo for a playlist edit, and Undo moved on to whatever is under it (never the removal again).
        if let items = editMenuUndoItems() {
            let ok = !items.redo.contains("Remove “\(song.title)”") && !items.undo.contains("Remove “\(song.title)”")
                && window.undoManager?.redoActionName.contains(song.title) != true
            log.append("playlist-remove-undo: Edit menu after Undo: \"\(items.undo)\" \(items.undoEnabled ? "enabled" : "disabled"), \"\(items.redo)\" \(items.redoEnabled ? "enabled" : "disabled") (\(ok ? "PASS: no Redo of the removal" : "FAIL"))")
        } else {
            log.append("playlist-remove-undo: Edit menu's Undo and Redo not found (FAIL)")
        }
        Self.removal = nil
    }

    /// Remove from Queue on an Up Next song, then Edit › Undo: the same entry back in its place, the playing song
    /// not restarted.
    private func checkQueueRemovalUndo(into log: inout [String]) {
        let player = model.player
        guard let entry = player.upNext.first(where: { !$0.isAutoplay }) else {
            log.append("queue remove undo: no Up Next song (FAIL)"); return
        }
        let before = player.queue
        let current = player.currentEntry?.uid
        player.removeUpNext([entry.uid], undoManager: window.undoManager)
        let removed = !player.queue.contains { $0.uid == entry.uid }
        let title = window.undoManager?.undoMenuItemTitle ?? "none"
        window.undoManager?.undo()
        log.append("queue remove undo: removed \(removed ? "yes" : "no"), Edit menu \"\(title)\" (\(title == "Undo Remove “\(entry.track.title)”" ? "PASS" : "FAIL")); after Undo the queue as before (same entries, order, flags): \(player.queue == before ? "PASS" : "FAIL"), same song playing: \(player.currentEntry?.uid == current ? "PASS" : "FAIL")")
    }

    /// Remove from Playlist where the service can't insert at a place: nothing goes until the dialog is answered.
    /// An editable YouTube Music playlist other than the one the drag shots drop on, holding its first song twice:
    /// the copy goes in as the third entry, on the first page, so the row's "2×" shows as the page opens. Light and
    /// dark run in one session, so the copy is added only while the song is there once.
    private func repeatedSongPlaylist(_ name: String, into log: inout [String]) async -> (Playlist, Track)? {
        guard let playlist = yt.catalog.playlists.first(where: { $0.isEditable && $0.title != "late night drive" }) else {
            log.append("\(name): no editable YouTube Music playlist (FAIL)"); return nil
        }
        guard let song = (try? await yt.playlist(id: playlist.providerID))?.tracks.first else {
            log.append("\(name): playlist empty (FAIL)"); return nil
        }
        if await playlistIDs(yt, playlist).filter({ $0 == song.id }).count == 1 {
            let insertable = yt.capabilities.contains(.playlistInsert)
            yt.capabilities.insert(.playlistInsert)
            try? await yt.insert([song], intoPlaylist: playlist.providerID, at: 2)
            if !insertable { yt.capabilities.remove(.playlistInsert) }
            model.cache.invalidate(prefix: "playlist:\(playlist.provider.rawValue):\(playlist.providerID)")
        }
        return (playlist, song)
    }

    private static var repeatedMenu: NSMenu?

    /// The repeated song's row: its "2×" marker (drawn, inside the row, before the time), the header's count against
    /// the service's total and the rows' copies, and its More with "Remove Both Copies" (PASS/FAIL each).
    private func showRepeatedSong(into log: inout [String]) async -> Target {
        guard let found = await repeatedSongPlaylist("playlist-repeated", into: &log) else { return .main }
        let (playlist, song) = found
        model.inspector = nil
        DebugProbes.note("song-count", nil)
        await open(.playlist(.youtubeMusic, id: playlist.providerID, preview: playlist))
        for _ in 0..<30 where !(DebugProbes.notes["song-count"] ?? "").contains(",") { await settle(0.1) }
        await settle(0.5)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        parkPointer()
        let entries = await playlistIDs(yt, playlist)
        let unique = Set(entries).count
        let line = DebugProbes.notes["song-count"] ?? "not reported"
        let counted = line.hasPrefix("\(entries.count) song")
        log.append("playlist-repeated header: \"\(line)\" for \(entries.count) entries in \(unique) rows (\(counted ? "PASS: the service's total of entries" : "FAIL: expected \(entries.count) songs"))")
        // Rows count from 0: the repeated song keeps the first place.
        guard let row = trackRow(0) else {
            log.append("playlist-repeated: first row not found (FAIL)"); return .main
        }
        let marker = DebugProbes.windowFrame("copies-marker-2")
        let inRow = marker.map { abs($0.midY - row.midY) < row.height / 2 && $0.minX >= row.maxX - 10 - Metrics.durationWidth - 1 && $0.maxX <= row.maxX } ?? false
        log.append("playlist-repeated marker: \(marker.map { String(format: "\"2×\" at x %.0f–%.0f, y %.0f in the first row (x %.0f–%.0f, y %.0f–%.0f)", $0.minX, $0.maxX, $0.midY, row.minX, row.maxX, row.minY, row.maxY) } ?? "not drawn") (\(inRow ? "PASS: in the time's column, before the time" : "FAIL"))")
        // The row's context menu (the same items as its More), opened over the title so the whole menu is inside the
        // window's capture; a pull-down from the More at the trailing edge runs past it.
        let title = CGPoint(x: row.minX + 300, y: row.midY)
        hover(at: title)
        await settle(0.3)
        let tracked = TrackedMenu()
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            nonisolated(unsafe) let menu = note.object as? NSMenu
            MainActor.assumeIsolated { if tracked.menu == nil { tracked.menu = menu } }
        }
        mouse([.rightMouseDown, .rightMouseUp], at: title)
        for _ in 0..<20 where tracked.menu == nil { await settle(0.1) }
        var opened = "context menu"
        if tracked.menu == nil {
            opened = "More"
            click(at: CGPoint(x: row.maxX - 10 - Metrics.durationWidth - 6 - 12, y: row.midY))
            for _ in 0..<20 where tracked.menu == nil { await settle(0.1) }
        }
        await settle(0.3)
        NotificationCenter.default.removeObserver(observer)
        Self.repeatedMenu = tracked.menu
        let titles = tracked.menu?.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map(\.title) ?? []
        log.append("playlist-repeated \(opened) on “\(song.title)”: \(tracked.menu == nil ? "no menu" : titles.joined(separator: ", ")) (\(titles.contains("Remove Both Copies") ? "PASS: names both copies" : "FAIL: no Remove Both Copies"))")
        return .mainWithMenu
    }

    private func askBeforeRemoving(into log: inout [String]) async -> Target {
        guard let found = await repeatedSongPlaylist("playlist-remove-confirm", into: &log) else { return .main }
        let (playlist, song) = found
        // The song twice in the playlist (listed once on its page): the dialog must say both copies go.
        yt.capabilities.remove(.playlistInsert)
        model.inspector = nil
        await open(.playlist(.youtubeMusic, id: playlist.providerID, preview: playlist))
        await settle(1.0)
        let before = await playlistIDs(yt, playlist)
        model.requestRemove([song], from: playlist, undoManager: window.undoManager)
        await settle(1.0)
        let after = await playlistIDs(yt, playlist)
        let sheet = window.attachedSheet
        let phrase = model.pendingPlaylistRemoval?.phrase ?? "none"
        log.append("playlist-remove-confirm: dialog \(model.pendingPlaylistRemoval.map { "for “\($0.tracks.first?.title ?? "")” in “\($0.playlist.title)”" } ?? "missing") (\(model.pendingPlaylistRemoval != nil ? "PASS" : "FAIL")), sheet \(sheet == nil ? "not shown (FAIL)" : "shown (PASS)"), nothing removed yet: \(after == before ? "PASS" : "FAIL"); the song twice in the playlist, the dialog removes \(phrase) (\(phrase.hasPrefix("both copies") ? "PASS" : "FAIL"))")
        return .mainWithSheet
    }

    /// Full screen, one song after another: the artist and album lines keep their height (album two lines even when
    /// short), so the transport sits at the same place for every song with the same panel state.
    private static var transportTops: [String: CGFloat] = [:]
    private func logFullScreenMetadata(_ label: String, album: String, into log: inout [String]) {
        guard let transport = DebugProbes.windowFrame("fullscreen-transport"), let albumFrame = DebugProbes.windowFrame("fullscreen-album"),
              let artist = DebugProbes.windowFrame("fullscreen-artist") else {
            log.append("\(label): full-screen metadata probes missing (FAIL)"); return
        }
        let key = "\(Int(window.frame.width))x\(Int(window.frame.height))|\(model.fullScreenPanel.map { "\($0)" } ?? "none")"
        let first = Self.transportTops[key]
        if first == nil { Self.transportTops[key] = transport.minY }
        let same = first.map { abs($0 - transport.minY) < 0.5 } ?? true
        log.append("\(label): artist line \(artist.height) pt, album “\(album)” \(albumFrame.height) pt (two lines reserved), transport top \(transport.minY)\(first.map { " vs \($0) for the first song" } ?? "") (\(same ? "PASS" : "FAIL"))")
    }

    private func endNoticeShot(_ hero: DemoNowPlaying) async {
        model.noticeDuration = .seconds(2.2)
        model.notice = nil
        model.isFullScreenPlayerPresented = false
        model.fullScreenPanel = .lyrics
        // Drops the song Add to Queue appended.
        playHero(hero)
        await settle(0.4)
    }

    /// Likes the playing song while the mock service refuses writes as an offline Mac would, waits past a
    /// confirmation's lifetime, and logs the failure notice: its text, its buttons, and (full screen) whether it
    /// clears the controls.
    private func failLike(name: String, checkControls: Bool, into log: inout [String]) async -> Target {
        model.noticeDuration = .seconds(2.2)
        yt.failingWrites = .network(URLError(.notConnectedToInternet).localizedDescription)
        guard let track = model.player.current else {
            log.append("\(name): nothing playing (FAIL)")
            return .main
        }
        let wasLiked = model.isLiked(track)
        model.setLiked(track, liked: !wasLiked)
        await settle(0.6)
        let expected = "Couldn’t \(wasLiked ? "unlike" : "like") “\(track.title)”. You’re offline."
        if checkControls {
            checkNotice(name, expecting: expected, into: &log)
        } else {
            let shown = model.notice?.text ?? "none"
            log.append("\(name): notice \"\(shown)\" at \(DebugProbes.windowFrame("notice").map { "\($0)" } ?? "nowhere") (\(shown == expected ? "PASS" : "FAIL"))")
        }
        let buttons = ["notice-retry", "notice-close"].map { key in "\(key) \(DebugProbes.windowFrame(key).map { "at \($0)" } ?? "missing")" }
        log.append("\(name): \(buttons.joined(separator: ", ")); heart back as it was: \(model.isLiked(track) == wasLiked ? "PASS" : "FAIL")")
        return .main
    }

    /// Clicks the mini player's Like while the mock service refuses writes, with the mini player key and the main window
    /// behind it, and logs where the failure shows: in the mini player (not the main window), clear of the transport.
    private func failLikeInMiniPlayer(_ mini: NSWindow?, into log: inout [String]) async -> Target {
        guard let mini, let like = DebugProbes.windowFrame("mini-like"), let track = model.player.current else {
            log.append("mini player notice: no mini player or Like button (FAIL)")
            return .window(mini)
        }
        yt.failingWrites = .network(URLError(.notConnectedToInternet).localizedDescription)
        sp.failingWrites = .network(URLError(.notConnectedToInternet).localizedDescription)
        model.notice = nil
        let wasLiked = model.isLiked(track)
        NSApp.activate()
        mini.makeKeyAndOrderFront(nil)
        await settle(0.3)
        click(at: CGPoint(x: like.midX, y: like.midY), in: mini)
        await settle(0.9)
        let expected = "Couldn’t \(wasLiked ? "unlike" : "like") “\(track.title)”. You’re offline."
        let notice = model.notice
        let frame = DebugProbes.windowFrame("mini-notice")
        let inMini = notice?.inMiniPlayer == true && frame != nil
        log.append("mini player notice: \"\(notice?.text ?? "none")\" (\(notice?.text == expected ? "PASS" : "FAIL")), in the mini player \(inMini ? "at \(frame!) (PASS)" : "no (FAIL)"), main window's notice \(inMini ? "hidden" : "shown")")
        let transport = ["mini-more", "mini-like"].compactMap { DebugProbes.windowFrame($0) }
        let clear = frame.map { f in transport.allSatisfy { !$0.intersects(f) } } ?? false
        let buttons = ["mini-notice-retry", "mini-notice-close"].map { key in "\(key) \(DebugProbes.windowFrame(key).map { "at \($0)" } ?? "missing")" }
        log.append("mini player notice: \(buttons.joined(separator: ", ")); clear of Like, More and the transport below: \(clear && (frame?.maxY ?? 999) < MiniPlayerView.width ? "PASS" : "FAIL"); heart back as it was: \(model.isLiked(track) == wasLiked ? "PASS" : "FAIL")")
        return .window(mini)
    }

    /// After the mini player shot: Try Again runs the Like again (it fails again: a new notice, still in the mini
    /// player), then Close removes it. Real clicks in the mini player.
    private func checkMiniNoticeButtons(into log: inout [String]) async {
        guard let mini = MiniPlayerWindow.window, let first = model.notice else {
            log.append("mini player notice buttons: the failure was gone before the capture finished (FAIL)")
            return
        }
        NSApp.activate()
        mini.makeKeyAndOrderFront(nil)
        await settle(0.2)
        if let retry = DebugProbes.windowFrame("mini-notice-retry") {
            click(at: CGPoint(x: retry.midX, y: retry.midY), in: mini)
            await settle(0.8)
            let again = model.notice
            let ok = again != nil && again?.id != first.id && again?.inMiniPlayer == true
            log.append("mini player notice buttons: clicked Try Again at \(retry): \(ok ? "the Like ran again and failed again, a new notice in the mini player (PASS)" : "no new attempt (FAIL)")")
        } else {
            log.append("mini player notice buttons: no Try Again button (FAIL)")
        }
        if let close = DebugProbes.windowFrame("mini-notice-close") {
            click(at: CGPoint(x: close.midX, y: close.midY), in: mini)
            await settle(0.6)
            log.append("mini player notice buttons: clicked Close at \(close): \(model.notice == nil ? "notice gone (PASS)" : "still shown (FAIL)")")
        } else {
            log.append("mini player notice buttons: no close button (FAIL)")
        }
    }

    /// Clicks the album hero's Add to Library while the mock service refuses writes (offline), and logs what the
    /// button, the album's context-menu item and the notice say once the refusal came back: the button and the menu
    /// back to "Add to Library" together, the failure naming the album, Try Again offered.
    private func refuseSave(hero: DemoNowPlaying, into log: inout [String]) async -> Target {
        model.noticeDuration = .seconds(2.2)
        yt.failingWrites = .network(URLError(.notConnectedToInternet).localizedDescription)
        let cached: (value: AlbumDetail, date: Date)? = model.cache.value(for: "album:\(hero.album.id)")
        let item = MediaItem.album(cached?.value.album ?? hero.album)
        let before = model.saveAction(for: item)
        guard let button = DebugProbes.windowFrame("hero-save"), let before else {
            log.append("save-refused: no Add to Library button (FAIL)")
            return .main
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        click(at: CGPoint(x: button.midX, y: button.midY))
        // The optimistic state right after the click, before the refusal (the mock answers at once, so this may
        // already be the rolled-back state; the log says which).
        await settle(0.05)
        let during = model.isSaved(item)
        await settle(0.8)
        parkPointer()
        let after = model.saveAction(for: item)
        let expected = "Couldn’t add “\(item.title)” to your library. You’re offline."
        let shown = model.notice?.text ?? "none"
        log.append("save-refused: before \"\(before.title)\", right after the click saved=\(during.map(String.init) ?? "unknown"), after the refusal \"\(after?.title ?? "none")\" (\(after == before ? "PASS: rolled back" : "FAIL"))")
        log.append("save-refused: hero and context menu read the same state: \(model.saveAction(for: .album(hero.album)) == after ? "PASS" : "FAIL")")
        log.append("save-refused: notice \"\(shown)\" (\(shown == expected ? "PASS" : "FAIL")), Try Again \(model.notice?.retry != nil ? "offered (PASS)" : "missing (FAIL)")")
        return .main
    }

    /// After the shot: the failure is still up past a confirmation's 2.2 s, Try Again runs the Like again (it fails
    /// again: a new notice), and the close button removes it. Real clicks, so this also proves the notice takes them.
    private func checkNoticeButtons(_ name: String, into log: inout [String]) async {
        guard let first = model.notice else {
            log.append("\(name) buttons: the failure was gone before the capture finished (FAIL)")
            return
        }
        log.append("\(name) buttons: still shown after the capture, kind \(first.kind == .failure ? "failure" : "confirmation") (\(first.kind == .failure ? "PASS" : "FAIL"))")
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        if let retry = DebugProbes.windowFrame("notice-retry") {
            click(at: CGPoint(x: retry.midX, y: retry.midY))
            await settle(0.8)
            let again = model.notice
            let ok = again != nil && again?.id != first.id && again?.kind == .failure
            log.append("\(name) buttons: clicked Try Again at \(retry): \(ok ? "the Like ran again and failed again, a new notice (PASS)" : "no new attempt (FAIL)")")
        } else {
            log.append("\(name) buttons: no Try Again button (FAIL)")
        }
        if let close = DebugProbes.windowFrame("notice-close") {
            click(at: CGPoint(x: close.midX, y: close.midY))
            await settle(0.6)
            log.append("\(name) buttons: clicked Close at \(close): \(model.notice == nil ? "notice gone (PASS)" : "still shown (FAIL)")")
        } else {
            log.append("\(name) buttons: no close button (FAIL)")
        }
        parkPointer()
    }

    /// Logs the notice's text and frame and whether it clears the full-screen controls (PASS/FAIL).
    private func checkNotice(_ name: String, expecting text: String, into log: inout [String]) {
        guard let notice = DebugProbes.windowFrame("notice") else {
            log.append("\(name): no notice on screen (FAIL)")
            return
        }
        let shown = model.notice?.text ?? "none"
        let controls = ["fullscreen-close", "fullscreen-panels", "fullscreen-transport", "fullscreen-like", "fullscreen-more", "fullscreen-metadata"]
        let overlaps = controls.filter { key in DebugProbes.windowFrame(key).map { $0.intersects(notice) } ?? false }
        let found = controls.filter { DebugProbes.windowFrame($0) != nil }
        let ok = shown.hasPrefix(text) && overlaps.isEmpty
        log.append("\(name): notice \"\(shown)\" at \(notice); checked against \(found.joined(separator: ", ")); overlaps \(overlaps.isEmpty ? "none" : overlaps.joined(separator: ", ")) (\(ok ? "PASS" : "FAIL"))")
    }

    private func endCoverShot(_ hero: DemoNowPlaying) async {
        model.isFullScreenPlayerPresented = false
        model.fullScreenPanel = .lyrics
        playHero(hero)
        await settle(0.3)
    }

    private func play(_ album: Album, provider: MockProvider) {
        guard let tracks = provider.catalog.albumTracks[album.providerID] else { return }
        model.play(tracks, from: AppModel.PlayingFrom(title: album.title, route: .album(album.provider, id: album.providerID, preview: album)))
    }

    private func play(_ playlist: Playlist, provider: MockProvider) {
        guard let tracks = provider.catalog.playlistTracks[playlist.providerID] else { return }
        model.play(tracks, from: AppModel.PlayingFrom(title: playlist.title, route: .playlist(playlist.provider, id: playlist.providerID, preview: playlist)))
    }

    private func playHero(_ hero: DemoNowPlaying) {
        model.play(hero.tracks, startAt: hero.index,
                   from: AppModel.PlayingFrom(title: hero.album.title, route: .album(.youtubeMusic, id: hero.album.providerID, preview: hero.album)))
        model.player.seek(to: hero.position)
    }

    private func open(_ route: Route) async {
        if model.path.last != route || model.sidebarSelection != .home {
            model.select(.home)
            try? await Task.sleep(for: .milliseconds(250))
            model.path = [route]
        }
    }

    /// How often `settle` waited for buffering to end, and for how long in all (logged at the end).
    private static var bufferingWaits = 0
    private static var bufferingWaitMs = 0

    private func settle(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
        // A stream still loading or refilling would show the play button's buffering ring in some runs and not in
        // others: wait (up to 3 s) until the player has its audio, so the shots repeat.
        var waited = 0
        while model.player.isBuffering, waited < 30 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        if waited > 0 {
            Self.bufferingWaits += 1
            Self.bufferingWaitMs += waited * 100
            try? await Task.sleep(for: .milliseconds(150))
        }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    /// `MEDLEY_COUNCIL_LOG=<name>` (the Keyboard Navigation run of council-shots.sh): the log goes to that file and
    /// no manifest is written, so the main run's files stay.
    private func write(_ log: [String], _ manifest: [String]) {
        let name = ProcessInfo.processInfo.environment["MEDLEY_COUNCIL_LOG"]
        try? log.joined(separator: "\n").appending("\n").write(to: dir.appendingPathComponent(name ?? "council.txt"), atomically: true, encoding: .utf8)
        guard name == nil else { return }
        try? manifest.joined(separator: "\n").appending("\n").write(to: dir.appendingPathComponent("manifest.tsv"), atomically: true, encoding: .utf8)
    }

    // MARK: Windows

    private func settingsWindow() -> NSWindow? {
        NSApp.windows.first { w in
            w.isVisible && w !== window && w !== MiniPlayerWindow.window
                && (w.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true
                    || SettingsPane.allCases.contains { $0.title == w.title })
        }
    }

    /// The real Settings window on `pane`; for Accounts, `service` picks the segment (0 YouTube Music, 1 Spotify).
    private func openSettings(_ pane: SettingsPane, service: Int? = nil) async -> NSWindow? {
        model.requestSettings(pane)
        model.openSettingsAction?()
        try? await Task.sleep(for: .seconds(0.8))
        guard let settings = settingsWindow() else { return nil }
        if let service, let control = views(of: NSSegmentedControl.self, in: settings.contentView).first, control.segmentCount > service {
            control.selectedSegment = service
            if let action = control.action { NSApp.sendAction(action, to: control.target, from: control) }
            try? await Task.sleep(for: .seconds(0.5))
        }
        settings.displayIfNeeded()
        return settings
    }

    private func openMiniPlayer(hovering: Bool) async -> NSWindow? {
        if MiniPlayerWindow.window?.isVisible != true {
            performMenuItem("Mini Player")
            try? await Task.sleep(for: .seconds(1.2))
        }
        guard let mini = MiniPlayerWindow.window else { return nil }
        if hovering {
            mini.makeKeyAndOrderFront(nil)
            move(to: CGPoint(x: mini.frame.midX, y: mini.frame.maxY - 160), in: mini)
        } else {
            // Off the mini player too, so its hover state from an earlier shot ends.
            move(to: CGPoint(x: mini.frame.minX - 40, y: mini.frame.minY - 40), in: mini)
            parkPointer()
        }
        try? await Task.sleep(for: .milliseconds(600))
        return mini
    }

    /// View › Show, refreshed as AppKit does before showing it.
    private func viewShowMenu() -> NSMenu? {
        guard let view = NSApp.mainMenu?.items.first(where: { $0.title == "View" })?.submenu else { return nil }
        view.delegate?.menuNeedsUpdate?(view)
        view.update()
        guard let show = view.items.first(where: { $0.title == "Show" })?.submenu else { return nil }
        show.delegate?.menuNeedsUpdate?(show)
        show.update()
        return show
    }

    /// Picks `title` from View › Show and logs whether the filter followed.
    private func pickViewShow(_ title: String, into log: inout [String]) {
        guard let show = viewShowMenu(), let index = show.items.firstIndex(where: { $0.title == title }) else {
            log.append("view menu: Show › \(title) not found (FAIL)")
            return
        }
        show.performActionForItem(at: index)
        log.append("view menu: picked Show › \(title), filter now \(model.serviceFilter.title) (\(model.serviceFilter.title == title ? "PASS" : "FAIL"))")
    }

    /// View › Show: its items and which one has the checkmark (the filter in use).
    private func logViewShowMenu(into log: inout [String]) {
        guard let show = viewShowMenu() else {
            log.append("view menu: no View › Show submenu (FAIL)")
            return
        }
        let items = show.items.filter { !$0.isSeparatorItem }
        let checked = items.filter { $0.state == .on }.map(\.title)
        let titles = items.map(\.title)
        let ok = titles == ServiceFilter.allCases.map(\.title) && checked == [model.serviceFilter.title]
        log.append("view menu: Show › \(titles.joined(separator: ", ")), checked \(checked.joined(separator: ", ")) (\(ok ? "PASS" : "FAIL"))")
    }

    private func performMenuItem(_ title: String) {
        func find(_ menu: NSMenu) -> (NSMenu, Int)? {
            for (i, item) in menu.items.enumerated() {
                if item.title == title { return (menu, i) }
                if let sub = item.submenu, let hit = find(sub) { return hit }
            }
            return nil
        }
        if let main = NSApp.mainMenu, let (menu, index) = find(main) {
            menu.update()
            menu.performActionForItem(at: index)
        }
    }

    private func views<T: NSView>(of type: T.Type, in root: NSView?) -> [T] {
        guard let root else { return [] }
        return ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views(of: type, in: $0) }
    }

    // MARK: Page and sidebar geometry

    /// Where the album hero's action row sits (`DetailScaffoldLayout`): beside the cover, in the text column, when
    /// that column holds it (PASS/FAIL), with the measured widths, and whether the row would still sit beside the
    /// cover in a 700 pt pane.
    private func logHeroActions(_ shot: String, into log: inout [String]) async {
        // The first open loads the album; wait for the loaded page's row.
        for _ in 0..<20 where DebugProbes.windowFrame("hero-actions") == nil || DebugProbes.notes["hero-actions-width"] == nil {
            await settle(0.15)
        }
        let actions = DebugProbes.notes["hero-actions-width"].flatMap { Double($0) }.map { CGFloat($0) }
        let tools = DebugProbes.notes["hero-tools-width"].flatMap { Double($0) }.map { CGFloat($0) } ?? 0
        guard let row = DebugProbes.windowFrame("hero-actions"), let page = DebugProbes.windowFrame("page-content"),
              let actions else {
            log.append("\(shot): hero actions not found (FAIL)")
            return
        }
        // Beside the cover: the row starts right of the artwork, not at the page inset.
        let beside = row.minX - page.minX > Metrics.pageInset + 100
        let width = CollectionHeroMetrics.rowWidth(actions: actions, tools: tools, compact: false)
        let at700 = CollectionHeroMetrics.fitsInline(paneWidth: 700, actions: width, compact: false)
        log.append("\(shot): hero actions \(beside ? "beside the cover" : "below the cover") in a \(Int(page.width)) pt pane "
                   + "(\(beside ? "PASS" : "FAIL")); actionsWidth \(Int(actions)) pt, tools \(Int(tools)) pt, row \(Int(width)) pt, "
                   + "row seen \(Int(row.width)) pt; at 700 pt: \(at700 ? "beside (PASS)" : "below (FAIL)")")
    }

    /// The scrolled page's fade under the toolbar (`TopScrollFade`): drawn once the page has scrolled, with the
    /// toolbar's height known (PASS/FAIL).
    /// Each row of cards on screen: how many, and where the last card's artwork ends against the trailing margin
    /// (the pane's edge less `Metrics.pageInset`, where "Show All" ends). Within 0.5 pt is a PASS.
    private func logCardEdges(_ shot: String, into log: inout [String]) {
        let mode = NSApp.appearance?.name == .darkAqua ? "dark" : "light"
        let width = window.contentView?.bounds.width ?? window.frame.width
        let margin = width - Metrics.pageInset
        let keys = (DebugProbes.views.keyEnumerator().allObjects as? [NSString] ?? []).map { $0 as String }
        let arts: [CGRect] = keys.filter { $0.hasPrefix("card-art-") }.compactMap { key in
            guard let probe = DebugProbes.views.object(forKey: key as NSString), probe.window === window, !probe.isHiddenOrHasHiddenAncestor,
                  let art = DebugProbes.windowFrame(key), art.minY >= 0, art.maxY <= window.frame.height,
                  art.minX < margin, art.maxX <= width + 1 else { return nil }
            return art
        }
        let rows = Dictionary(grouping: arts) { Int(($0.minY / 4).rounded()) }.sorted { $0.key < $1.key }.filter { $0.value.count > 1 }
        let showAll = DebugProbes.windowFrame("see-all").map { " (a Show All ends at x \(String(format: "%.1f", $0.maxX)))" } ?? ""
        guard !rows.isEmpty else { log.append("card edges \(shot) (\(mode)): no card rows on screen"); return }
        for (_, row) in rows {
            let sorted = row.sorted { $0.minX < $1.minX }
            let end = sorted.last!.maxX
            let gaps = zip(sorted.dropFirst(), sorted).map { $0.minX - $1.maxX }
            let gap = gaps.isEmpty ? "" : String(format: ", gaps %.1f–%.1f", gaps.min()!, gaps.max()!)
            let short = margin - end
            log.append("card edges \(shot) (\(mode)): row at y \(Int(sorted[0].minY)): \(row.count) cards \(Int(sorted[0].width.rounded())) pt wide\(gap), last ends at x \(String(format: "%.1f", end)), margin x \(String(format: "%.1f", margin))\(showAll): \(String(format: "%.1f", short)) pt short (\(abs(short) <= 0.5 ? "PASS" : "FAIL"))")
        }
    }

    private func logTopFade(_ shot: String, into log: inout [String]) {
        let note = DebugProbes.notes["top-fade"] ?? "not reported"
        let mode = NSApp.appearance?.name == .darkAqua ? "dark" : "light"
        log.append("\(shot) (\(mode)): top fade \(note) (\(note.hasPrefix("drawn") ? "PASS" : "FAIL"))")
    }

    /// Whether `lyricsTopFadeCheck` paused playback (so the lyrics don't scroll themselves), to resume in the reset.
    private static var pausedForLyrics = false
    private var lyricsPausedPlayback: Bool {
        get { Self.pausedForLyrics }
        nonmutating set { Self.pausedForLyrics = newValue }
    }

    /// Round 31's lyrics panel sliced a line under its heading: the top fade (20 pt) was shorter than a line. Scrolls the
    /// panel so a line sits fully below the fade, captures it, then scrolls that line up to 2 pt under the fade's start
    /// and captures again. Each pixel row of the line's ink against its unfaded ink must follow the fade (at most the
    /// fade's opacity at that row, plus 0.2): a row at full ink inside the fade is a cut. Also logs the fade's height.
    private func lyricsTopFadeCheck() async -> String {
        let label = "lyrics-scrolled: line under the heading"
        if model.player.isPlaying { model.player.pause(); lyricsPausedPlayback = true }
        await settle(0.3)
        let index = 6
        guard let list = DebugProbes.windowFrame("lyrics-list"), DebugProbes.windowFrame("lyrics-line-\(index)") != nil else {
            return "\(label): lyrics list or line probes not found (FAIL)"
        }
        // The panel's scroll view: the one whose frame is the list's.
        let scroll = views(of: NSScrollView.self, in: window.contentView).first { view in
            guard let content = window.contentView, view.documentView != nil else { return false }
            let r = view.convert(view.bounds, to: content)
            let top = content.isFlipped ? r.minY : content.bounds.height - r.maxY
            return abs(r.minX - list.minX) < 2 && abs(top - list.minY) < 2
        }
        guard let scroll, let doc = scroll.documentView else { return "\(label): the panel's scroll view not found (FAIL)" }
        func scrollLine(toTopAt y: CGFloat) async {
            guard let line = DebugProbes.windowFrame("lyrics-line-\(index)") else { return }
            let clip = scroll.contentView
            var bounds = clip.bounds
            let delta = line.minY - y
            bounds.origin.y += doc.isFlipped ? delta : -delta
            clip.setBoundsOrigin(clip.constrainBoundsRect(bounds).origin)
            scroll.reflectScrolledClipView(clip)
            await settle(0.7)
        }
        /// Ink per device-pixel row of the line (its greatest luma distance from the panel at the list's leading edge).
        func profile() -> (rows: [Double], top: CGFloat, scale: CGFloat)? {
            guard let line = DebugProbes.windowFrame("lyrics-line-\(index)"),
                  let image = WindowCapture.image(of: window, shadow: false, fullResolution: true), let px = Pixels(image) else { return nil }
            let scale = CGFloat(image.width) / max(window.frame.width, 1)
            let top = Int((line.minY * scale).rounded()), bottom = Int((line.maxY * scale).rounded())
            let left = Int(((line.minX + 2) * scale).rounded()), right = Int((min(line.maxX, list.maxX - 4) * scale).rounded())
            let edge = Int(((list.minX + 3) * scale).rounded())
            var rows: [Double] = []
            for r in top..<max(top, bottom) {
                let panel = px.luma(r, edge)
                var ink = 0.0
                for c in stride(from: left, to: right, by: 1) { ink = max(ink, abs(px.luma(r, c) - panel)) }
                rows.append(ink)
            }
            return (rows, line.minY, scale)
        }
        await scrollLine(toTopAt: list.minY + LyricsStyle.panelTopFade + 14)
        guard let clear = profile() else { return "\(label): capture not found (FAIL)" }
        await scrollLine(toTopAt: list.minY + 2)
        let fade = DebugProbes.notes["lyrics-top-fade"] ?? "not reported"
        guard let faded = profile() else { return "\(label): capture not found (FAIL)" }
        let offset = faded.top - list.minY
        var worst = 0.0, sumTop = 0.0, nTop = 0, sumBottom = 0.0, nBottom = 0, maxRatio = 0.0
        let count = min(clear.rows.count, faded.rows.count)
        for i in 0..<count where clear.rows[i] >= 40 {
            let y = faded.top + CGFloat(i) / faded.scale - list.minY
            let alpha = Double(min(max(y / LyricsStyle.panelTopFade, 0), 1))
            let ratio = faded.rows[i] / clear.rows[i]
            worst = max(worst, ratio - alpha)
            maxRatio = max(maxRatio, ratio)
            if i < count / 3 { sumTop += ratio; nTop += 1 } else if i >= count * 2 / 3 { sumBottom += ratio; nBottom += 1 }
        }
        let top = nTop > 0 ? sumTop / Double(nTop) : 0, bottom = nBottom > 0 ? sumBottom / Double(nBottom) : 0
        let placed = abs(offset - 2) <= 3
        let pass = placed && fade == "\(Int(LyricsStyle.panelTopFade))" && nTop > 0 && nBottom > 0 && worst <= 0.2 && top < bottom && maxRatio > 0.05
        return String(format: "%@ %ld (%.0f pt under the fade's start; top fade %@ pt): ink against the unfaded line %.0f%% in its top third, %.0f%% in its bottom third, at most %.2f over the fade's opacity at any row (%@)",
                      label, index, offset, fade, top * 100, bottom * 100, worst,
                      pass ? "PASS: fades" : !placed ? "FAIL: line not placed" : worst > 0.2 ? "FAIL: cut, rows at full ink inside the fade" : "FAIL")
    }

    /// Scrolls the page (the widest tall scroll view; the sidebar's and panels' are narrower) to a fraction of its length.
    /// Scrolls the page down in steps until the view with LayoutProbe `key` exists, then puts its top `topAt` points
    /// below the window's top. Returns whether it was found.
    private func scrollPage(untilProbe key: String, topAt: CGFloat) async -> Bool {
        scrollPage(to: 0)
        await settle(0.3)
        var fraction: CGFloat = 0
        while DebugProbes.windowFrame(key) == nil, fraction < 1 {
            fraction += 0.05
            scrollPage(to: fraction)
            await settle(0.2)
        }
        guard let frame = DebugProbes.windowFrame(key) else { return false }
        scrollPage(by: frame.minY - topAt)
        await settle(0.5)
        return DebugProbes.windowFrame(key) != nil
    }

    /// Scrolls the page by `delta` points (positive: further down).
    private func scrollPage(by delta: CGFloat) {
        let page = views(of: NSScrollView.self, in: window.contentView)
            .filter { $0.documentView != nil && !$0.isHidden && $0.bounds.height > 300 }
            .max { $0.bounds.width < $1.bounds.width }
        guard let page, let doc = page.documentView else { return }
        let clip = page.contentView
        var bounds = clip.bounds
        bounds.origin.y += doc.isFlipped ? delta : -delta
        clip.setBoundsOrigin(clip.constrainBoundsRect(bounds).origin)
        page.reflectScrolledClipView(clip)
    }

    private func scrollPage(to fraction: CGFloat) {
        let page = views(of: NSScrollView.self, in: window.contentView)
            .filter { $0.documentView != nil && !$0.isHidden && $0.bounds.height > 300 }
            .max { $0.bounds.width < $1.bounds.width }
        guard let page, let doc = page.documentView else { return }
        let clip = page.contentView
        let range = max(0, doc.frame.height - clip.bounds.height)
        var bounds = clip.bounds
        bounds.origin.y = doc.isFlipped ? range * fraction : range * (1 - fraction)
        clip.setBoundsOrigin(clip.constrainBoundsRect(bounds).origin)
        page.reflectScrolledClipView(clip)
    }

    /// The one-line subtitle each featured card on Home shows (`FittedLine`): a list keeps "and more" and loses
    /// names from its end; nothing is cut inside a word.
    private func logFeaturedSubtitles(_ label: String, into log: inout [String]) {
        let prefix = "featured-subtitle|"
        let notes = DebugProbes.notes.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }
        if notes.isEmpty { log.append("\(label) featured subtitles: none reported (FAIL)") }
        for (key, value) in notes {
            log.append("\(label) featured subtitle, \(key.dropFirst(prefix.count)): \(value)")
        }
    }

    /// With Playing Next open in a narrow window: the sidebar either shown whole or not at all (no strip of it with
    /// its rows cut at the window's leading edge), and the panel's trailing edge inside the window.
    /// Whether a carousel shows only whole cards with the last one ending at the page's margin: after the window
    /// was set back to 960 (from the 1502 pt the split view made of it), Made for You kept its 1136 pt layout and a
    /// slice of a third card sat against the panel (round 25). Reads the carousel's probes (`carouselProbe`).
    private func wholeCardsCheck(_ shelf: String) -> String {
        guard let viewport = DebugProbes.windowFrame("\(shelf)-viewport"), let page = DebugProbes.windowFrame("page-content") else {
            return "\(shelf): carousel not laid out (FAIL)"
        }
        let margin = page.maxX - Metrics.pageInset
        // What the page shows of the carousel: its scroll view, which the page's column clips.
        let visible = (minX: viewport.minX, maxX: min(viewport.maxX, page.maxX))
        let cards = (0..<60).compactMap { DebugProbes.windowFrame("\(shelf)-card-\($0)") }
            .filter { $0.maxX > visible.minX + 0.5 && $0.minX < visible.maxX - 0.5 }
            .sorted { $0.minX < $1.minX }
        let cut = cards.filter { $0.minX < visible.minX - 0.5 || $0.maxX > visible.maxX + 0.5 || $0.maxX > margin + 1 }
        let lastEnd = cards.last?.maxX
        let atMargin = lastEnd.map { abs($0 - margin) <= 1.5 } ?? false
        let ok = !cards.isEmpty && cut.isEmpty && atMargin
        return String(format: "%@: %d cards shown (%@ pt wide), %d cut; last card ends at x %.0f, page margin at x %.0f (%@)",
                      shelf, cards.count, cards.map { String(format: "%.0f", $0.width) }.joined(separator: ", "), cut.count,
                      lastEnd ?? -1, margin, ok ? "PASS" : "FAIL: only whole cards, the last one ending at the page margin")
    }

    /// The empty Library's Sign In: the button's fill, read from a capture beside its leading end (inside the capsule,
    /// clear of the label), against the system accent color in the window's appearance (within 24 levels per channel:
    /// the accent under its 8% shade), and the label's white against that fill (4.5:1 or more; both for a PASS).
    private func logSignInFill(into log: inout [String]) {
        guard let button = DebugProbes.windowFrame("home-sign-in"),
              let image = WindowCapture.image(of: window, shadow: false, fullResolution: true), let px = Pixels(image) else {
            log.append("signed-out-library sign in: button or capture not found (FAIL)")
            return
        }
        let scale = CGFloat(image.width) / max(window.frame.width, 1)
        let fill = px.rgb(Int((button.midY * scale).rounded()), Int(((button.minX + 9) * scale).rounded()))
        var accent = (red: 0, green: 0, blue: 0)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) {
                accent = (Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
            }
        }
        let off = max(abs(fill.red - accent.red), abs(fill.green - accent.green), abs(fill.blue - accent.blue))
        func lin(_ v: Int) -> Double { let c = Double(v) / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * lin(fill.red) + 0.7152 * lin(fill.green) + 0.0722 * lin(fill.blue)
        let contrast = 1.05 / (luminance + 0.05)
        log.append(String(format: "signed-out-library sign in: %.0f×%.0f pt, fill rgb(%d, %d, %d), accent rgb(%d, %d, %d), %d levels apart; white label %.2f:1 (%@)",
                          button.width, button.height, fill.red, fill.green, fill.blue, accent.red, accent.green, accent.blue, off, contrast,
                          off > 24 ? "FAIL: not the accent fill" : contrast < 4.5 ? "FAIL: white label under 4.5:1" : "PASS: the accent fill, label 4.5:1 or more"))
    }

    /// The track row's "…" ink, read from the capture: inside the 24 pt button, the pixel furthest in luma from the
    /// row's own fill just before it. On a focused selected row it must be white (luma 225+ on the accent fill); on an
    /// unselected row it must be drawn (60+ levels from the row).
    private func selectedMoreInkCheck(row index: Int, selected: Bool) -> String {
        let label = "playlist-multi-select: More ink on \(selected ? "selected" : "unselected") row \(index)"
        guard let row = trackRow(index), let image = WindowCapture.image(of: window, shadow: false, fullResolution: true), let px = Pixels(image) else {
            return "\(label): capture not found (FAIL)"
        }
        let scale = CGFloat(image.width) / max(window.frame.width, 1)
        let center = CGPoint(x: row.maxX - 10 - Metrics.durationWidth - 6 - 12, y: row.midY)
        let box = CGRect(x: center.x - 10, y: center.y - 6, width: 20, height: 12)
        let background = px.luma(Int((center.y * scale).rounded()), Int(((box.minX - 6) * scale).rounded()))
        var ink = background
        for r in Int((box.minY * scale).rounded())..<Int((box.maxY * scale).rounded()) {
            for c in Int((box.minX * scale).rounded())..<Int((box.maxX * scale).rounded()) {
                let l = px.luma(r, c)
                if abs(l - background) > abs(ink - background) { ink = l }
            }
        }
        let pass = selected ? ink >= 225 : abs(ink - background) >= 60
        return String(format: "%@: dots luma %.0f on the row's luma %.0f (%@)", label, ink, background,
                      pass ? (selected ? "PASS: white" : "PASS: drawn") : (selected ? "FAIL: not white" : "FAIL: not drawn"))
    }

    /// The liked heart on a selected Songs row (the focused accent selection): white like the row's text, not the accent
    /// on the accent. Read from the capture in the Time column's heart slot (left of the 38 pt time): PASS when 20+
    /// device pixels there are near white.
    private func songsSelectedHeartCheck(_ table: NSTableView, row: Int) -> String {
        let label = "songs-selected: liked heart on selected row \(row)"
        guard table.numberOfColumns > 0, let image = WindowCapture.image(of: window, shadow: false, fullResolution: true), let px = Pixels(image),
              let content = window.contentView else { return "\(label): capture not found (FAIL)" }
        let cell = table.convert(table.frameOfCell(atColumn: table.numberOfColumns - 1, row: row), to: nil)
        let scale = CGFloat(image.width) / max(window.frame.width, 1)
        let top = content.bounds.height - cell.maxY
        let slot = CGRect(x: cell.maxX - 66, y: top + 4, width: 24, height: cell.height - 8)
        var white = 0
        for r in Int((slot.minY * scale).rounded())..<Int((slot.maxY * scale).rounded()) {
            for c in Int((slot.minX * scale).rounded())..<Int((slot.maxX * scale).rounded()) where px.luma(r, c) >= 225 { white += 1 }
        }
        return "\(label): \(white) near-white device pixels in the heart's slot (\(white >= 20 ? "PASS: white" : "FAIL: not white"))"
    }

    /// Whether the queue row's "…" is drawn: device pixels inside the button's frame at least 60 levels of luma from
    /// the row's own background just before the button (PASS from 8; the dots are a few dozen at 2x).
    private func moreInkCheck(_ frame: CGRect) -> String {
        guard let image = WindowCapture.image(of: window, shadow: false, fullResolution: true), let px = Pixels(image) else {
            return "playing-next: More ink: capture not found (FAIL)"
        }
        let scale = CGFloat(image.width) / max(window.frame.width, 1)
        let rows = Int((frame.minY * scale).rounded())..<Int((frame.maxY * scale).rounded())
        let columns = Int((frame.minX * scale).rounded())..<Int((frame.maxX * scale).rounded())
        let background = px.luma(Int((frame.midY * scale).rounded()), Int(((frame.minX - 4) * scale).rounded()))
        var ink = 0
        for row in rows { for column in columns where abs(px.luma(row, column) - background) >= 60 { ink += 1 } }
        return String(format: "playing-next: More ink: %d device pixels inside the button differ by 60+ levels from the row (luma %.0f) (%@)",
                      ink, background, ink >= 8 ? "PASS: drawn" : "FAIL: not drawn")
    }

    private func narrowQueueEdgesCheck() -> String {
        let width = window.contentView?.bounds.width ?? window.frame.width
        var notes: [String] = []
        var ok = true
        if let root = window.contentView, let (_, item) = SplitViewTuning.sidebarItem(in: root) {
            let column = item.viewController.view
            let frame = column.convert(column.bounds, to: nil)
            let shown = !item.isCollapsed && !column.isHiddenOrHasHiddenAncestor && frame.width > 1 && frame.maxX > 0.5
            let visible = shown ? max(0, min(frame.maxX, width) - max(frame.minX, 0)) : 0
            // The sidebar's list and its footer, which slid off the leading edge in round 23's strip.
            let list = views(of: NSTableView.self, in: column).filter { !$0.isHiddenOrHasHiddenAncestor }
                .map { $0.convert($0.bounds, to: nil) }.min { $0.minX < $1.minX }
            let footer = DebugProbes.windowFrame("sidebar-footer")
            let cut = shown && (frame.minX < -0.5 || visible < frame.width - 0.5 || (list?.minX ?? 0) < -0.5 || (footer?.minX ?? 0) < -0.5
                                || visible < 180)
            if cut { ok = false }
            notes.append(String(format: "sidebar %@ (column %.0f pt wide at x %.0f, %.0f pt visible; list at x %@; footer at x %@)",
                                item.isCollapsed ? "collapsed" : shown ? (cut ? "partly visible" : "shown whole") : "hidden",
                                frame.width, frame.minX, visible, list.map { String(format: "%.0f", $0.minX) } ?? "none",
                                footer.map { String(format: "%.0f", $0.minX) } ?? "none"))
        } else {
            notes.append("sidebar item not found")
            ok = false
        }
        if let panel = DebugProbes.windowFrame("panel") {
            let past = panel.maxX - width
            if past > 0.5 { ok = false }
            notes.append(String(format: "panel %.0f–%.0f pt in a %.0f pt window (%@)", panel.minX, panel.maxX, width,
                                past > 0.5 ? String(format: "%.0f pt past the trailing edge", past) : "inside"))
        } else {
            notes.append("panel not laid out")
            ok = false
        }
        return notes.joined(separator: "; ") + " (\(ok ? "PASS" : "FAIL: the sidebar must be shown whole or hidden, and the panel inside the window"))"
    }

    /// Scrolls the page to its real top, with the toolbar's inset above the content (`scrollPage(to: 0)` puts the
    /// content's top at the window's top edge, under the toolbar).
    private func scrollPageToTop() {
        let page = views(of: NSScrollView.self, in: window.contentView)
            .filter { $0.documentView != nil && !$0.isHidden && $0.bounds.height > 300 }
            .max { $0.bounds.width < $1.bounds.width }
        guard let page, let doc = page.documentView else { return }
        let clip = page.contentView
        var bounds = clip.bounds
        bounds.origin.y = doc.isFlipped ? -page.contentInsets.top : doc.frame.height - bounds.height + page.contentInsets.top
        clip.setBoundsOrigin(bounds.origin)
        page.reflectScrolledClipView(clip)
    }

    /// The page scroll view's offset (0 or less: at the top, under the toolbar's inset) and its content's height.
    private func pageScrollState() -> (offset: CGFloat, text: String) {
        let page = views(of: NSScrollView.self, in: window.contentView)
            .filter { $0.documentView != nil && !$0.isHidden && $0.bounds.height > 300 }
            .max { $0.bounds.width < $1.bounds.width }
        guard let page, let doc = page.documentView else { return (.infinity, "no page scroll view") }
        let clip = page.contentView.bounds
        let offset = doc.isFlipped ? clip.minY : doc.frame.height - clip.maxY
        return (offset, "offset \(Int(offset)) of \(Int(max(0, doc.frame.height - clip.height))) pt (content \(Int(doc.frame.height)) pt)")
    }

    /// Whether the Artists scope's grid is drawn in the visible part of the page (under the toolbar, above the
    /// floating player): a scope switch must never leave the page blank.
    private func searchArtistGridCheck() -> String {
        let state = pageScrollState().text
        guard let grid = DebugProbes.windowFrame("search-artist-grid"), grid.width > 0, grid.height > 0 else {
            return "\(state); artist grid not laid out (FAIL)"
        }
        let height = window.contentView?.bounds.height ?? 0
        let visible = CGRect(x: 0, y: 52, width: window.frame.width, height: max(0, height - 52 - 100))
        let shown = grid.intersection(visible)
        let ok = !shown.isNull && shown.height >= min(grid.height, 120)
        return "\(state); artist grid at y \(Int(grid.minY))–\(Int(grid.maxY)), \(shown.isNull ? 0 : Int(shown.height)) pt of it in view (\(ok ? "PASS" : "FAIL"))"
    }

    private var sidebarTable: NSTableView? {
        views(of: NSTableView.self, in: window.contentView).min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    /// The sidebar column's width in points (the list's scroll view), or 260.
    private func sidebarWidth() -> CGFloat {
        guard let table = sidebarTable, let scroll = table.enclosingScrollView else { return 260 }
        return scroll.convert(scroll.bounds, to: nil).maxX + 1
    }

    /// Scrolls the sidebar so `row` sits in the middle of its visible part (clear of the account footer), or to the
    /// top for row 0. Recently Played comes after the playlists, below the fold in a 900 pt window.
    private func scrollSidebar(toRow row: Int) {
        guard let table = sidebarTable, let scroll = table.enclosingScrollView, row < table.numberOfRows else { return }
        let clip = scroll.contentView
        var bounds = clip.bounds
        let rect = table.convert(table.rect(ofRow: row), to: clip.documentView ?? table)
        if row == 0 {
            bounds.origin.y = -scroll.contentInsets.top
        } else if row == table.numberOfRows - 1, let doc = clip.documentView {
            // The very end, so the last row sits above the account footer.
            bounds.origin.y = doc.frame.height - bounds.height + scroll.contentInsets.bottom
        } else {
            bounds.origin.y = rect.midY - bounds.height / 2
        }
        clip.setBoundsOrigin(clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    /// The sidebar back at its top, only when it isn't there: scrolling it forces a layout of the window, which
    /// right after a shot closed the queue panel left the next shot's panel unopened.
    private func resetSidebarScroll() {
        guard let table = sidebarTable, let scroll = table.enclosingScrollView else { return }
        guard abs(scroll.contentView.bounds.origin.y + scroll.contentInsets.top) > 0.5 else { return }
        scrollSidebar(toRow: 0)
    }

    private func sidebarRowCenter(row: Int) -> CGPoint? {
        guard let table = sidebarTable, row < table.numberOfRows else { return nil }
        scrollSidebar(toRow: row)
        return center(of: table.rect(ofRow: row), in: table)
    }

    /// Rows before the Playlists section's first playlist in the sidebar's outline view. Every SwiftUI Section adds a
    /// header row (zero height for the first, untitled one), so the rows are: header, Home, New; header, six library
    /// rows; header, the pins; header, All Playlists, the playlists; header, Recently Played. Checked by
    /// `sidebar-rows.txt` and by eye in the hover shots.
    private var playlistsStartRow: Int {
        let pinned = model.sidebarPinned.count
        return 1 + SidebarItem.browse.count + 1 + SidebarItem.library.count + (pinned > 0 ? 1 + pinned : 0) + 1 + 1
    }

    /// Library › Liked Songs: header, Home, New; header, then the library rows.
    private var likedSongsRow: Int {
        1 + SidebarItem.browse.count + 1 + (SidebarItem.library.firstIndex(of: .likedSongs) ?? 0)
    }

    /// The center of Liked Songs' 20 pt symbol (its play button), from the symbol's own probe; the row scrolled
    /// into view first.
    /// `likedSongsSymbolCenter()` once the button exists and holds still (the same center twice, 100 ms apart), or
    /// nil after `timeout` seconds.
    private func likedSongsSymbolCenter(waiting timeout: Double) async -> CGPoint? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: CGPoint?
        while Date() < deadline {
            let now = likedSongsSymbolCenter()
            if let now, let last, abs(now.x - last.x) < 0.5, abs(now.y - last.y) < 0.5 { return now }
            last = now
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private func likedSongsSymbolCenter() -> CGPoint? {
        guard sidebarRowCenter(row: likedSongsRow) != nil,
              let r = DebugProbes.windowFrame("sidebar-play-symbol-\(SidebarItem.likedSongs.title)") else { return nil }
        return CGPoint(x: r.midX, y: r.midY)
    }

    /// A playlist's row under Playlists.
    private func playlistRow(_ playlist: Playlist?) -> Int {
        playlistsStartRow + (model.sidebarPlaylists.firstIndex { $0.id == playlist?.id } ?? 0)
    }

    /// A Recently Played row (the playing album). Playlists shows its first ten and a Show More row.
    private func recentRow(_ id: String?) -> Int {
        let count = model.sidebarPlaylists.count
        let shown = SidebarMetrics.visibleRows(count, shown: SidebarMetrics.playlistsShown, expanded: UserDefaults.standard.bool(forKey: "sidebarShowsAllPlaylists"))
        let playlists = model.libraryProviders.isEmpty ? 0 : shown + (SidebarMetrics.foldsRows(count, shown: SidebarMetrics.playlistsShown) ? 1 : 0)
        let recent = model.sidebarRecents.firstIndex { $0.id == id } ?? 0
        return playlistsStartRow + playlists + 1 + recent
    }

    /// Logs which row each way of opening a playlist page highlights (`AppModel.canonicalSidebarSelection`): Daily
    /// Mix 1 from its Recently Played tag and from its Playlists row, and the pinned playlist from its Playlists row.
    /// Each should land on one row: the Playlists row, or the Pinned row when pinned. Also that neither is listed in
    /// Recently Played.
    private func logSelectionChecks(mixID: String?, mix: Playlist?, pinned: Playlist, into log: inout [String]) {
        guard let mixID, let mix else { log.append("sidebar selection: no Daily Mix 1 (FAIL)"); return }
        let mixRow = SidebarItem.playlist(mix.provider, mix.providerID)
        let pinnedID = SidebarEntry.item(.playlist(pinned)).id
        let cases: [(String, SidebarItem, SidebarItem)] = [
            ("\(mix.title) from Recently Played", .collection(mixID), mixRow),
            ("\(mix.title) from Playlists", mixRow, mixRow),
            ("\(pinned.title) (pinned) from Playlists", .playlist(pinned.provider, pinned.providerID), .collection(pinnedID)),
            ("\(pinned.title) (pinned) from Pinned", .collection(pinnedID), .collection(pinnedID)),
        ]
        for (label, asked, expected) in cases {
            model.select(asked)
            let got = model.sidebarSelection
            log.append("sidebar selection: \(label): \(got.map { "\($0)" } ?? "none") (\(got == expected ? "PASS" : "FAIL"))")
        }
        let recentIDs = Set(model.sidebarRecents.map(\.id))
        let repeated = [mixID, pinnedID].filter(recentIDs.contains)
        log.append("sidebar selection: Recently Played shows \(model.sidebarRecents.map(\.title).joined(separator: ", ")); repeats a playlist above: \(repeated.isEmpty ? "none (PASS)" : "\(repeated) (FAIL)")")
    }

    /// One liked entry: the services' own liked-songs playlists (Liked Music, played earlier) are in neither Playlists
    /// nor Recently Played, Library › Liked Songs stands for them, and All Playlists still lists them.
    private func logLikedEntries(likedID: String?, liked: Playlist?, into log: inout [String]) {
        guard let likedID, let liked else { log.append("liked entries: no Liked Music (FAIL)"); return }
        let underPlaylists = model.sidebarPlaylists.filter(\.isLikedSongs).map(\.title)
        let inRecents = model.sidebarRecents.contains { $0.id == likedID }
        let played = model.collections.recents.contains { $0.id == likedID }
        let inAll = (model.libraryPlaylists[liked.provider] ?? []).contains { $0.id == liked.id }
        log.append("liked entries: liked-songs playlists under Playlists: \(underPlaylists.isEmpty ? "none (PASS)" : "\(underPlaylists) (FAIL)"); \(liked.title) played \(played), in Recently Played \(inRecents) (\(inRecents ? "FAIL" : "PASS")); in All Playlists \(inAll) (\(inAll ? "PASS" : "FAIL")); Library lists \(SidebarItem.library.map(\.title).joined(separator: ", "))")
    }

    /// The center of a sidebar row's 24 pt artwork: the row's leading edge plus the list's inset to the icon.
    private func sidebarArtworkCenter(row: Int) -> CGPoint? {
        guard let table = sidebarTable, row < table.numberOfRows else { return nil }
        scrollSidebar(toRow: row)
        let rect = table.rect(ofRow: row)
        // Find the artwork from the row's own view: the first 24 pt square subview on the leading side.
        if let rowView = table.rowView(atRow: row, makeIfNecessary: false) {
            let squares = views(of: NSView.self, in: rowView).filter { abs($0.frame.width - 24) < 0.5 && abs($0.frame.height - 24) < 0.5 }
            if let art = squares.min(by: { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }) {
                let r = art.convert(art.bounds, to: nil)
                return CGPoint(x: r.midX, y: window.frame.height - r.midY)
            }
        }
        // SwiftUI may draw the row without a 24 pt view of its own: fall back to the list's standard icon position.
        let center = center(of: rect, in: table)
        let leading = table.convert(rect, to: nil).minX
        return CGPoint(x: leading + 10 + 12, y: center.y)
    }

    /// The rows the sidebar should draw from the model's filtered lists (`sidebarPinned`, `sidebarPlaylists`,
    /// `sidebarRecents`), every section open, against the rows its table has; and that no row is from a service the
    /// filter leaves out.
    private func logSidebarFilterRows(_ label: String, into log: inout [String]) {
        let pinned = model.sidebarPinned
        let playlists = model.sidebarPlaylists
        let recents = model.sidebarRecents
        var rows = 1 + SidebarItem.browse.count
        rows += model.libraryProviders.isEmpty ? 1 : 1 + SidebarItem.library.count
        if !pinned.isEmpty { rows += 1 + pinned.count }
        if !model.libraryProviders.isEmpty {
            let all = UserDefaults.standard.bool(forKey: "sidebarShowsAllPlaylists")
            rows += 2 + SidebarMetrics.visibleRows(playlists.count, shown: SidebarMetrics.playlistsShown, expanded: all)
                + (SidebarMetrics.foldsRows(playlists.count, shown: SidebarMetrics.playlistsShown) ? 1 : 0)
        }
        if !recents.isEmpty || model.collections.recents.isEmpty {
            let all = UserDefaults.standard.bool(forKey: "sidebarShowsAllRecents")
            rows += 1 + (model.collections.recents.isEmpty ? 1 : 0) + SidebarMetrics.visibleRows(recents.count, shown: SidebarMetrics.recentsShown, expanded: all)
                + (SidebarMetrics.foldsRows(recents.count, shown: SidebarMetrics.recentsShown) ? 1 : 0)
        }
        let table = sidebarTable?.numberOfRows ?? -1
        let filter = model.serviceFilter
        let strays = pinned.filter { !filter.includes($0.provider) }.map(\.title)
            + playlists.filter { !filter.includes($0.provider) }.map(\.title)
            + recents.filter { !filter.includes($0.provider) }.map(\.title)
        let services = { (ids: [ProviderID]) in Set(ids.map(\.displayName)).sorted().joined(separator: "+") }
        log.append("sidebar filter (\(label)): pinned \(pinned.count) of \(model.collections.pinned.count) [\(services(pinned.map(\.provider)))], playlists \(playlists.count) [\(services(playlists.map(\.provider)))], recently played \(recents.count) [\(services(recents.map(\.provider)))]; rows expected \(rows), table \(table) (\(rows == table ? "PASS" : "FAIL")); other services' rows: \(strays.isEmpty ? "none (PASS)" : "\(strays) (FAIL)")")
    }

    /// The sidebar's top edge once scrolled: compared with the same window at rest, nothing changed above the search
    /// field's bottom (no rows behind the traffic lights or the field) or in the 8 pt under it (no row text). Gray
    /// differences per pixel, at most a few levels for the material's noise.
    private func logSidebarTopEdge(rest: CGImage, scrolled: CGImage, into log: inout [String]) {
        guard let field = AppModel.sidebarSearchField(in: window) else {
            log.append("sidebar top edge scrolled: no search field (FAIL)"); return
        }
        let f = field.convert(field.bounds, to: nil)
        let fieldBottom = window.frame.height - f.minY
        let width = sidebarWidth() - 2
        func gray(_ image: CGImage) -> [UInt8]? {
            let w = image.width, h = image.height
            var data = [UInt8](repeating: 0, count: w * h)
            guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return data
        }
        guard rest.width == scrolled.width, rest.height == scrolled.height, let a = gray(rest), let b = gray(scrolled) else {
            log.append("sidebar top edge scrolled: captures differ in size (FAIL)"); return
        }
        let scale = CGFloat(rest.width) / window.frame.width
        // Top-left origin rows in the bitmap (CGContext draws bottom-up, so row 0 of the data is the image's top).
        func maxDiff(fromY y0: CGFloat, toY y1: CGFloat) -> Int {
            let r0 = max(0, Int((y0 * scale).rounded())), r1 = min(rest.height, Int((y1 * scale).rounded()))
            let cols = min(rest.width, Int((width * scale).rounded()))
            var worst = 0
            for r in r0..<max(r0, r1) {
                for c in 2..<cols { worst = max(worst, abs(Int(a[r * rest.width + c]) - Int(b[r * rest.width + c]))) }
            }
            return worst
        }
        let above = maxDiff(fromY: 0, toY: fieldBottom)
        let below = maxDiff(fromY: fieldBottom, toY: fieldBottom + 8)
        let limit = 6
        log.append("sidebar top edge scrolled: field bottom at \(fieldBottom) pt, \(DebugProbes.notes["sidebar-mask"] ?? "mask not reported"); largest change against the list at rest above the field \(above)/255 (\(above <= limit ? "PASS" : "FAIL")), in the 8 pt under it \(below)/255 (\(below <= limit ? "PASS" : "FAIL"))")
    }

    /// The sidebar's bottom edge at rest (rows continue below): no row text cut on a line over the account bar. In
    /// the 2 pt above the bar's top and the 3 pt under it, every pixel stays within a few gray levels of its row's
    /// median (the material); a row cut on a hard line leaves letters at full contrast right above it.
    private func logSidebarBottomEdge(rest: CGImage, into log: inout [String]) {
        guard let footer = DebugProbes.windowFrame("sidebar-footer"), let px = Pixels(rest) else {
            log.append("sidebar bottom edge at rest: no account bar probe (FAIL)"); return
        }
        let scale = CGFloat(rest.width) / window.frame.width
        let line = Int((footer.minY * scale).rounded())
        let cols = 2..<min(rest.width, Int(((sidebarWidth() - 2) * scale).rounded()))
        func spread(_ rows: Range<Int>) -> Int {
            var worst = 0
            for r in rows where r >= 0 && r < rest.height {
                let lumas = cols.map { px.luma(r, $0) }.sorted()
                let median = lumas[lumas.count / 2]
                worst = max(worst, Int((max(median - lumas[0], lumas[lumas.count - 1] - median)).rounded()))
            }
            return worst
        }
        let above = spread((line - Int(2 * scale))..<line)
        let below = spread(line..<(line + Int(3 * scale)))
        let context = spread((line - Int(12 * scale))..<(line - Int(8 * scale)))
        let limit = 12
        let edge = DebugProbes.notes["sidebar-bottom-edge"] ?? "not reported"
        log.append("sidebar bottom edge at rest: account bar top at \(footer.minY) pt, list \(edge), \(DebugProbes.notes["sidebar-mask"] ?? "mask not reported"); largest gray spread across a pixel row in the 2 pt above the bar \(above)/255 (\(above <= limit ? "PASS" : "FAIL")), in the 3 pt under its top \(below)/255 (\(below <= limit ? "PASS" : "FAIL")); 8–12 pt above the bar, where rows fade, \(context)/255")
    }

    /// The artist header as captured: the seam where it meets the page (no luminance step over 6/255 between pixel
    /// rows at its bottom edge), and the text against the pixels next to it. For the text, a second capture with the
    /// name, the "Artist" line and the buttons' labels hidden (`HeroTextProbe`, glass and capsules kept) gives what's
    /// behind them: the letters are where the two captures differ. White text (letters brighter than what they cover)
    /// has to clear the brightest pixel of the hidden capture within 3 pt of a letter at 4.5:1; dark text (light mode
    /// over a pale photo) is read as its letters' darkest pixel, the solid ink, against the darkest pixel within 3 pt.
    private func logArtistHeader(_ label: String, into log: inout [String]) async {
        let appearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
        let width = Int(heroBanner().width)
        guard let hero = DebugProbes.windowFrame("artist-hero"),
              let shownImage = WindowCapture.image(of: window, shadow: false, fullResolution: true), let shown = Pixels(shownImage) else {
            log.append("artist header (\(label), \(appearance)): not found (FAIL)"); return
        }
        let scale = CGFloat(shownImage.width) / window.frame.width
        // The seam: every column across the header, the pixel rows from 4 above its bottom edge to 3 below it.
        let edge = Int((hero.maxY * scale).rounded())
        let c0 = max(0, Int((hero.minX * scale).rounded()) + 4), c1 = min(shown.width, Int((hero.maxX * scale).rounded()) - 4)
        var step = 0.0, stepX = 0, lastRow = 0.0, pageRow = 0.0
        for c in c0..<max(c0, c1) {
            for r in (edge - 4)..<(edge + 3) where r > 0 && r < shown.height {
                let d = abs(shown.luma(r, c) - shown.luma(r - 1, c))
                if d > step { step = d; stepX = c }
            }
            lastRow += shown.luma(edge - 1, c); pageRow += shown.luma(edge + 1, c)
        }
        let n = Double(max(1, c1 - c0))
        log.append(String(format: "artist header seam (%@ %d pt, %@): last header row %.1f/255 on average, page %.1f; largest step between pixel rows at the bottom edge %.1f/255 at x %.0f pt (%@)",
                          label, width, appearance, lastRow / n, pageRow / n, step, Double(stepX) / Double(scale), step <= 6 ? "PASS" : "FAIL"))
        // The gap under the buttons: from the 32 pt capsules' bottom (10 pt above the 52 pt row's) to the Top Songs heading.
        if let row = DebugProbes.windowFrame("hero-actions"), let heading = DebugProbes.windowFrame("top-songs-header") {
            let gap = heading.minY - (row.maxY - 10)
            log.append(String(format: "artist gap (%@ %d pt, %@): buttons to Top Songs %.0f pt, header ends %.0f pt under the buttons (%@: 30–48 pt)",
                              label, width, appearance, gap, hero.maxY - (row.maxY - 10), (30...48).contains(gap) ? "PASS" : "FAIL"))
        }

        // The second capture once the text is gone: round 28's first full run captured before SwiftUI had redrawn
        // (0 letter pixels), so it waits for the name's pixels to change, up to 2 s.
        HeroTextProbe.shared.hidden = true
        var hiddenImage: CGImage?
        let nameFrame = DebugProbes.windowFrame("artist-hero-name")
        for _ in 0..<10 {
            await settle(0.2)
            hiddenImage = WindowCapture.image(of: window, shadow: false, fullResolution: true)
            guard let nameFrame, let candidate = hiddenImage.flatMap(Pixels.init), candidate.width == shown.width else { break }
            var changed = 0
            let y = Int((nameFrame.midY * scale).rounded())
            for x in stride(from: Int((nameFrame.minX * scale).rounded()), to: Int((nameFrame.maxX * scale).rounded()), by: 2)
                where shown.difference(candidate, y, x) > 60 { changed += 1 }
            if changed > 0 { break }
        }
        HeroTextProbe.shared.hidden = false
        await settle(0.3)
        guard let hiddenImage, hiddenImage.width == shownImage.width, hiddenImage.height == shownImage.height, let hidden = Pixels(hiddenImage) else {
            log.append("artist text contrast (\(label), \(appearance)): no capture without the text (FAIL)"); return
        }
        for (name, key) in [("name", "artist-hero-name"), ("Artist line", "artist-hero-meta"), ("button labels", "hero-actions")] {
            guard let frame = DebugProbes.windowFrame(key), let m = textContrast(shown: shown, hidden: hidden, frame: frame, scale: scale) else {
                log.append("artist text contrast (\(label) \(width) pt, \(appearance)) \(name): not found (FAIL)"); continue
            }
            log.append("artist text contrast (\(label) \(width) pt, \(appearance)) \(name): \(m.summary(scale: scale))")
        }
    }

    /// What a contrast check read for one run of text: its letters (where the capture changed by more than 60 levels
    /// once the text was hidden), their ink (the brightest letter pixel for light text, the darkest for dark text) and
    /// the worst background within 3 pt of a letter in the capture without the text (the brightest under light text,
    /// the darkest under dark text).
    private struct TextContrast {
        let white: Bool
        let ink: Double
        let extreme: Double
        let at: (Int, Int)
        let letters: Int
        var ratio: Double { white ? (ink + 0.05) / (extreme + 0.05) : (extreme + 0.05) / (ink + 0.05) }
        var passes: Bool { letters > 0 && ratio >= 4.5 }

        func summary(scale: CGFloat) -> String {
            let what = white ? String(format: "light text (its ink at luminance %.3f) against the brightest pixel within 3 pt of a letter", ink)
                : String(format: "dark text (its ink at luminance %.3f) against the darkest pixel within 3 pt of a letter", ink)
            return String(format: "%@ (luminance %.3f at %.0f, %.0f pt) %.2f:1 (%@); %d letter pixels",
                          what, extreme, Double(at.0) / Double(scale), Double(at.1) / Double(scale), ratio, passes ? "PASS" : "FAIL", letters)
        }
    }

    private func textContrast(shown: Pixels, hidden: Pixels, frame: CGRect, scale: CGFloat) -> TextContrast? {
        let reach = Int((3 * scale).rounded())
        let x0 = max(0, Int((frame.minX * scale).rounded()) - reach), x1 = min(shown.width, Int((frame.maxX * scale).rounded()) + reach)
        let y0 = max(0, Int((frame.minY * scale).rounded()) - reach), y1 = min(shown.height, Int((frame.maxY * scale).rounded()) + reach)
        guard x1 > x0, y1 > y0 else { return nil }
        let w = x1 - x0, h = y1 - y0
        // Letters: where the text changed the capture by more than a shadow does.
        var letter = [Bool](repeating: false, count: w * h)
        var letters = 0
        for y in 0..<h { for x in 0..<w where shown.difference(hidden, y0 + y, x0 + x) > 60 { letter[y * w + x] = true; letters += 1 } }
        // Within `reach` of a letter: dilate rows, then columns.
        var rows = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w where letter[y * w + x] {
                for k in max(0, x - reach)...min(w - 1, x + reach) { rows[y * w + k] = true }
            }
        }
        // Light or dark text: whether the letters made the capture brighter or darker than what they cover.
        var lighter = 0
        for y in 0..<h {
            for x in 0..<w where letter[y * w + x] && shown.relativeLuminance(y0 + y, x0 + x) > hidden.relativeLuminance(y0 + y, x0 + x) { lighter += 1 }
        }
        let white = lighter * 2 >= letters
        var ink = white ? 0.0 : 1.0
        for y in 0..<h {
            for x in 0..<w where letter[y * w + x] {
                let l = shown.relativeLuminance(y0 + y, x0 + x)
                ink = white ? max(ink, l) : min(ink, l)
            }
        }
        var extreme = white ? 0.0 : 1.0, at = (0, 0)
        for x in 0..<w {
            for y in 0..<h where rows[y * w + x] {
                for k in max(0, y - reach)...min(h - 1, y + reach) {
                    let l = hidden.relativeLuminance(y0 + k, x0 + x)
                    if white ? l > extreme : l < extreme { extreme = l; at = (x0 + x, y0 + k) }
                }
            }
        }
        return TextContrast(white: white, ink: ink, extreme: extreme, at: at, letters: letters)
    }

    /// Live probes whose key starts with `prefix`, in the main window and inside its visible part (under the toolbar,
    /// above the floating player), by key.
    private func visibleProbes(prefix: String) -> [(key: String, frame: CGRect)] {
        var keys = Set<String>()
        let enumerator = DebugProbes.liveProbes.keyEnumerator()
        while let view = enumerator.nextObject() as? NSView {
            if view.window === window, let key = DebugProbes.liveProbes.object(forKey: view) as String?, key.hasPrefix(prefix) { keys.insert(key) }
        }
        let height = window.contentView?.bounds.height ?? window.frame.height
        let visible = CGRect(x: 0, y: 52, width: window.frame.width, height: max(0, height - 52 - 96))
        return keys.sorted().compactMap { key in
            guard let frame = DebugProbes.windowFrame(key), visible.contains(frame) else { return nil }
            return (key, frame)
        }
    }

    /// Secondary text on Home's cards against what's under it, read from the capture and a second capture with that
    /// text hidden (`TextContrastProbe`): the featured card's eyebrow and description (light text in dark mode, dark
    /// in light mode, over the artwork's tint), the Made for You cards' white detail lines over their shaded strip.
    /// 4.5:1 is a PASS.
    private func logCardTextContrast(_ label: String, probes: [(name: String, key: String, frame: CGRect)], into log: inout [String]) async {
        let appearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
        guard !probes.isEmpty else { log.append("\(label) text contrast (\(appearance)): no text found (FAIL)"); return }
        guard let shownImage = WindowCapture.image(of: window, shadow: false, fullResolution: true), let shown = Pixels(shownImage) else {
            log.append("\(label) text contrast (\(appearance)): capture failed (FAIL)"); return
        }
        let scale = CGFloat(shownImage.width) / window.frame.width
        TextContrastProbe.shared.hidden = true
        var hidden: Pixels?
        let probe = probes[0].frame
        for _ in 0..<10 {
            await settle(0.2)
            guard let candidate = WindowCapture.image(of: window, shadow: false, fullResolution: true).flatMap(Pixels.init), candidate.width == shown.width else { continue }
            hidden = candidate
            var changed = 0
            for y in stride(from: Int((probe.minY * scale).rounded()), to: Int((probe.maxY * scale).rounded()), by: 1) {
                for x in stride(from: Int((probe.minX * scale).rounded()), to: Int((probe.maxX * scale).rounded()), by: 2) where shown.difference(candidate, y, x) > 60 { changed += 1 }
            }
            if changed > 0 { break }
        }
        TextContrastProbe.shared.hidden = false
        await settle(0.3)
        guard let hidden, hidden.height == shown.height else {
            log.append("\(label) text contrast (\(appearance)): no capture without the text (FAIL)"); return
        }
        for probe in probes {
            guard let m = textContrast(shown: shown, hidden: hidden, frame: probe.frame, scale: scale) else {
                log.append("\(label) text contrast (\(appearance)) \(probe.name): not measured (FAIL)"); continue
            }
            log.append("\(label) text contrast (\(appearance)) \(probe.name): \(m.summary(scale: scale))")
        }
    }

    /// The featured card's eyebrow and description (the first card's probes).
    private func featuredTextProbes() -> [(name: String, key: String, frame: CGRect)] {
        [("featured eyebrow", "featured-eyebrow"), ("featured description", "featured-description")].compactMap { name, key in
            DebugProbes.windowFrame(key).map { (name, key, $0) }
        }
    }

    /// Every Made for You card's detail line on screen.
    private func mixCaptionProbes() -> [(name: String, key: String, frame: CGRect)] {
        visibleProbes(prefix: "hero-card-detail|").map { probe in
            ("caption of \(probe.key.split(separator: "|", maxSplits: 1).last.map(String.init) ?? probe.key)", probe.key, probe.frame)
        }
    }

    /// The sidebar's rows as the capture sees them (`sidebar-rows.txt`), to check which row a hover shot points at.
    private func writeSidebarRows(_ point: CGPoint?) {
        guard let table = sidebarTable else { return }
        var lines = ["table \(type(of: table)), \(table.numberOfRows) rows, pointer \(point.map { "\($0)" } ?? "none")"]
        for row in 0..<table.numberOfRows {
            lines.append("\(row): center \(center(of: table.rect(ofRow: row), in: table)), height \(table.rect(ofRow: row).height)")
        }
        try? lines.joined(separator: "\n").appending("\n").write(to: dir.appendingPathComponent("sidebar-rows.txt"), atomically: true, encoding: .utf8)
    }

    private func center(of rect: NSRect, in view: NSView) -> CGPoint {
        // Window coordinates are bottom-left; captures and pointers here are top-left.
        let r = view.convert(rect, to: nil)
        return CGPoint(x: r.midX, y: window.frame.height - r.midY)
    }

    // MARK: Checks

    /// The artist hero's banner size right now: the page's width (the window minus the sidebar when it shows) and
    /// `ArtistHero.height(forWidth:)`.
    private func heroBanner() -> CGSize {
        let sidebar = model.columnVisibility == .detailOnly ? 0 : sidebarWidth()
        let width = window.frame.width - sidebar
        return CGSize(width: width, height: ArtistHero<EmptyView>.height(forWidth: width))
    }

    /// Logs what the artist hero found in a photo and which part of it shows in a banner of `banner` size.
    private func logPhotoFocus(_ artist: Artist, banner: CGSize, into log: inout [String]) async {
        guard let url = artist.artwork?.url(minPixels: PhotoFocusCache.pixels) else {
            log.append("photo focus \(artist.name): no photo"); return
        }
        guard let focus = await PhotoFocusCache.shared.focus(for: url) else {
            log.append("photo focus \(artist.name): photo didn't load (default crop)"); return
        }
        log.append(describe(focus, artist: artist.name, banner: banner))
    }

    private func describe(_ focus: PhotoFocus, artist: String, banner: CGSize) -> String {
        func f(_ v: CGFloat) -> String { String(format: "%.3f", v) }
        func r(_ rect: CGRect?) -> String { rect.map { "y \(f($0.minY))–\(f($0.maxY)) x \(f($0.minX))–\(f($0.maxX))" } ?? "none" }
        let placement = focus.placement(banner: banner, displayScale: 2)
        let shown = placement.visibleRect(banner: banner)
        func inView(_ rect: CGRect) -> Bool { shown.minY <= rect.minY + 0.0005 && shown.maxY >= rect.maxY - 0.0005 }
        var parts = ["photo \(Int(placement.size.width))x\(Int(placement.size.height)) pt at x \(Int(placement.origin.x)), y \(Int(placement.origin.y))",
                     "shows y \(f(shown.minY))–\(f(shown.maxY)) x \(f(shown.minX))–\(f(shown.maxX))",
                     placement.origin.x > 0.5 ? "leading \(Int(placement.origin.x)) pt filled from the photo's edge" : "fills the banner"]
        if let up = placement.upscale(sourceWidth: focus.sourceWidth, displayScale: 2) {
            parts.append("source \(focus.sourceWidth ?? 0) px, \(String(format: "%.2f", up)) px per source px at 2x (\(up <= PhotoFocus.maxUpscale + 0.01 ? "PASS" : "FAIL"))")
        }
        if let subject = focus.subject {
            let keep = focus.source == .face && !inView(subject) ? (focus.primary ?? subject) : subject
            let center = (placement.origin.x + keep.midX * placement.size.width) / banner.width
            let inRange = (0.6...0.75).contains(center)
            parts.append("subject center at \(Int((center * 100).rounded()))% across (\(inRange ? "PASS" : "outside 60–75%"))")
            if focus.source == .face {
                let face = PhotoFocus.face(fromHead: keep)
                let faceBottom = (placement.origin.y + face.maxY * placement.size.height) / banner.height
                parts.append("face in view: \(inView(face) ? "yes" : "NO"), whole head: \(inView(keep) ? "yes" : "no (crown cut)"), chin at \(Int((faceBottom * 100).rounded()))% down")
            }
        }
        return "photo focus \(artist) @ \(Int(banner.width))x\(Int(banner.height)): \(focus.source.rawValue), aspect \(f(focus.aspect)), subject \(r(focus.subject)), biggest face \(r(focus.primary)); " + parts.joined(separator: "; ")
    }

    /// Every demo artist's photo at the 1440 pt (sidebar shown) and 960 pt (sidebar hidden) banner sizes.
    private func logAllArtistFaces(into log: inout [String]) async {
        let page1440 = 1440 - sidebarWidth()
        let banners = [CGSize(width: page1440, height: ArtistHero<EmptyView>.height(forWidth: page1440)),
                       CGSize(width: 960, height: ArtistHero<EmptyView>.height(forWidth: 960))]
        var seen = Set<String>()
        for artist in yt.catalog.artists + sp.catalog.artists where seen.insert(artist.name).inserted {
            for banner in banners { await logPhotoFocus(artist, banner: banner, into: &log) }
        }
    }

    /// Clicks the play button on Library › Liked Songs (its heart turns into Play under the pointer), then the row's
    /// title, and logs what each did: the button should start Liked Songs without opening it, a second click pause
    /// it, and the title open its page. Then puts the hero song back where it was.
    private func checkSidebarPlay(hero: DemoNowPlaying, into log: inout [String]) async {
        NSApp.appearance = NSAppearance(named: .aqua)
        model.select(.home)
        await settle(0.8)
        let liked = AppModel.likedSongsContext.title
        let row = likedSongsRow
        guard let art = likedSongsSymbolCenter() else {
            log.append("sidebar play check: Liked Songs' play button not found (FAIL)"); return
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        hover(at: art)
        await settle(0.4)
        log.append("sidebar play check: \(sidebarDiscCheck(pressed: false))")
        // Held down: the disc darkens (the release below is the click).
        mouse([.leftMouseDown], at: art)
        await settle(0.35)
        log.append("sidebar play check: \(sidebarDiscCheck(pressed: true))")
        mouse([.leftMouseUp], at: art)
        await settle(1.5)
        let playingLiked = model.playingFrom == AppModel.likedSongsContext && model.player.current != nil
        let selection = model.sidebarSelection
        log.append("sidebar play check: clicked \(liked)' heart (row \(row)) at \(art): playing from \(model.playingFrom?.title ?? "nothing") (\(playingLiked ? "PASS" : "FAIL")), \(model.player.queue.count) songs queued, isPlaying \(model.player.isPlaying), selection \(selection.map { "\($0)" } ?? "none") (\(selection == .home ? "PASS: row not opened" : "FAIL: row opened"))")
        // Find it again, in case the list moved. This time 1.5 pt past the symbol's trailing edge, toward the title:
        // outside the 20 pt symbol, inside its 28 pt target.
        let again = likedSongsSymbolCenter().map { CGPoint(x: $0.x + 11.5, y: $0.y) }
        if let again {
            hover(at: again)
            await settle(0.3)
            click(at: again)
            await settle(0.8)
            log.append("sidebar play check: clicked it again 1.5 pt past the symbol's trailing edge at \(again): isPlaying \(model.player.isPlaying) (\(model.player.isPlaying ? "FAIL" : "PASS: paused")), still from \(model.playingFrom?.title ?? "nothing"), selection \(model.sidebarSelection.map { "\($0)" } ?? "none")")
        }
        if let title = sidebarRowCenter(row: likedSongsRow).map({ CGPoint(x: $0.x + 40, y: $0.y) }) {
            click(at: title)
            await settle(0.8)
            let opened = model.sidebarSelection == .likedSongs
            log.append("sidebar play check: clicked the row's title at \(title): selection \(model.sidebarSelection.map { "\($0)" } ?? "none") (\(opened ? "PASS: opened" : "FAIL"))")
        }
        parkPointer()
        playHero(hero)
        model.select(.home)
        await settle(0.6)
        log.append("sidebar play check: restored \(model.playingFrom?.title ?? "nothing"); Recently Played starts with \(model.sidebarRecents.first?.title ?? "none")")
    }

    /// Liked Songs' revealed play button read from the capture: the disc's fill just inside its top edge (clear of the
    /// glyph) against the accent color (within 24 levels: PASS) or, pressed, darker than the accent by 20 levels of luma
    /// or more (PASS); and the glyph at its center white (luma 230 or more: PASS).
    private func sidebarDiscCheck(pressed: Bool) -> String {
        let label = pressed ? "play disc pressed" : "play disc"
        guard let disc = DebugProbes.windowFrame("sidebar-play-disc"),
              let image = WindowCapture.image(of: window, shadow: false, fullResolution: true), let px = Pixels(image) else {
            return "\(label): disc or capture not found (FAIL)"
        }
        let scale = CGFloat(image.width) / max(window.frame.width, 1)
        let fill = px.rgb(Int(((disc.minY + 3) * scale).rounded()), Int((disc.midX * scale).rounded()))
        let glyph = px.luma(Int((disc.midY * scale).rounded()), Int(((disc.midX + 0.5) * scale).rounded()))
        var accent = (red: 0, green: 0, blue: 0)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) {
                accent = (Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
            }
        }
        func luma(_ c: (red: Int, green: Int, blue: Int)) -> Double { 0.2126 * Double(c.red) + 0.7152 * Double(c.green) + 0.0722 * Double(c.blue) }
        let off = max(abs(fill.red - accent.red), abs(fill.green - accent.green), abs(fill.blue - accent.blue))
        let darker = luma(accent) - luma(fill)
        let fillOK = pressed ? darker >= 20 : off <= 24
        return String(format: "%@ %.0f×%.0f pt: fill rgb(%d, %d, %d), accent rgb(%d, %d, %d), %d levels apart, %.0f darker (%@); glyph luma %.0f (%@)",
                      label, disc.width, disc.height, fill.red, fill.green, fill.blue, accent.red, accent.green, accent.blue, off, darker,
                      fillOK ? (pressed ? "PASS: darker while pressed" : "PASS: the accent disc") : "FAIL",
                      glyph, glyph >= 230 ? "PASS: white" : "FAIL")
    }

    /// Clicks the first Up Next row in Playing Next (selecting it and focusing the list), then presses ↓ twice
    /// through the event queue, the way a listener would.
    private func selectQueueRowByKeyboard(into log: inout [String]) async {
        guard let row = DebugProbes.windowFrame("queue-row-upNext-0") else {
            log.append("playing-next keyboard: first Up Next row not found"); return
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // On the title, clear of the artwork and the duration.
        let point = CGPoint(x: row.minX + 80, y: row.midY)
        click(at: point)
        await settle(0.4)
        for _ in 0..<2 {
            press(keyCode: 125, character: NSDownArrowFunctionKey)
            await settle(0.25)
        }
        parkPointer()
        // Rows count from the playing song (row 0), so the first Up Next song is row 1 and ↓ ↓ lands on row 3.
        let state = DebugProbes.notes["queue-list"] ?? "not focused"
        // A row's "…" with keyboard focus would have taken it from the list.
        let more = DebugProbes.notes["more-focus"].map { "; a More has focus: \($0)" } ?? ""
        log.append("playing-next keyboard: clicked the first Up Next row at \(point), then pressed ↓ twice: \(state)\(more) (\(state.hasPrefix("focused, selected row 3") ? "PASS" : "FAIL"))")
    }

    /// Clicks the first Up Next row, presses ↓ (the second Up Next song selected), then Escape, and logs what the
    /// list reports: focused, nothing selected, the row that was selected outlined.
    private func selectQueueRowThenEscape(into log: inout [String]) async {
        guard let row = DebugProbes.windowFrame("queue-row-upNext-0") else {
            log.append("queue focus escape: first Up Next row not found"); return
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        DebugProbes.note("queue-list", nil)
        click(at: CGPoint(x: row.minX + 80, y: row.midY))
        await settle(0.4)
        press(keyCode: 125, character: NSDownArrowFunctionKey)
        await settle(0.25)
        let before = DebugProbes.notes["queue-list"] ?? "not focused"
        press(keyCode: 53, character: 0x1B, function: false)
        await settle(0.3)
        parkPointer()
        let after = DebugProbes.notes["queue-list"] ?? "not focused"
        let pass = after.hasPrefix("focused, selected row none, outlined row ") && !after.hasSuffix("outlined row none")
        log.append("queue focus escape: after click and ↓: \(before); after Escape: \(after) (\(pass ? "PASS" : "FAIL"))")
    }

    /// Clicks the first Up Next row, then removes that song the way another view would (a context menu, sync), not
    /// with the list's own Delete key, and logs what the list reports: focused, nothing selected, the row that took
    /// its place outlined.
    private func selectQueueRowThenRemove(into log: inout [String]) async {
        guard let row = DebugProbes.windowFrame("queue-row-upNext-0") else {
            log.append("queue focus removed: first Up Next row not found"); return
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        DebugProbes.note("queue-list", nil)
        click(at: CGPoint(x: row.minX + 80, y: row.midY))
        await settle(0.4)
        let before = DebugProbes.notes["queue-list"] ?? "none"
        if let entry = model.player.upNext.first(where: { !$0.isAutoplay }) { model.player.remove(entry.uid) }
        await settle(0.4)
        parkPointer()
        let after = DebugProbes.notes["queue-list"] ?? "none"
        log.append("queue focus removed: after the click: \(before); after removing that song: \(after) (\(after == "focused, selected row none, outlined row 1" ? "PASS" : "FAIL"))")
    }

    /// With the pointer parked off the window and nothing focused, presses Tab (at most 40 times) until a Quick picks
    /// row's More button has keyboard focus, then Space to open its menu. Logs the presses, the song and whether the
    /// menu opened.
    private func openQuickPicksMoreByKeyboard(label: String = "quick picks more keyboard", into log: inout [String]) async -> Target {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        parkPointer()
        window.makeFirstResponder(nil)
        DebugProbes.note("more-focus", nil)
        await settle(0.3)
        var presses = 0
        var reached: [String] = []
        while DebugProbes.notes["more-focus"] == nil, presses < 40 {
            press(keyCode: 48, character: 0x09, function: false)
            presses += 1
            await settle(0.2)
            let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
            if reached.last != responder { reached.append(responder) }
        }
        guard let focused = DebugProbes.notes["more-focus"] else {
            log.append("\(label): \(presses) Tab presses, no More button took focus (FAIL); focus went through \(reached.joined(separator: " → "))")
            return .main
        }
        let title = focused.split(separator: "|", maxSplits: 1).last.map(String.init) ?? focused
        log.append("\(label): \(presses) Tab presses: More of “\(title)” focused (PASS)")
        DebugProbes.note("more-open", nil)
        press(keyCode: 49, character: 0x20, function: false)
        await settle(0.6)
        var key = "Space"
        if KeyboardMoreMenu.current == nil {
            log.append("\(label): Space opened no menu (FAIL: \(DebugProbes.notes["more-open"] ?? "the key never reached the button")); trying Return")
            press(keyCode: 36, character: 0x0D, function: false)
            await settle(0.6)
            key = "Return"
        }
        let items = KeyboardMoreMenu.current?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
        log.append("\(label): \(key) opened \(items.isEmpty ? "no menu (FAIL: \(DebugProbes.notes["more-open"] ?? "the key never reached the button"))" : "the menu: \(items.joined(separator: ", ")) (PASS)")")
        return .mainWithMenu
    }

    /// Picks Play Next from the menu `openQuickPicksMoreByKeyboard` opened, then checks the song is next in the queue.
    /// Puts the hero queue back afterwards.
    private func choosePlayNextFromKeyboardMenu(hero: DemoNowPlaying, into log: inout [String]) async {
        let id = DebugProbes.notes["more-focus"].flatMap { $0.split(separator: "|", maxSplits: 1).first.map(String.init) }
        let before = model.player.upNext.first?.track.title ?? "nothing"
        if let menu = KeyboardMoreMenu.current, let index = menu.items.firstIndex(where: { $0.title == "Play Next" }) {
            menu.performActionForItem(at: index)
            menu.cancelTracking()
            await settle(0.8)
            let next = model.player.upNext.first?.track
            let pass = id != nil && next?.id == id
            log.append("quick picks more keyboard: chose Play Next: up next was “\(before)”, now “\(next?.title ?? "nothing")” (\(pass ? "PASS: queue changed" : "FAIL"))")
            let ring = DebugProbes.notes["more-focus"] != nil
            log.append("quick picks more keyboard: after the menu closed the More button \(ring ? "keeps" : "lost") keyboard focus (\(ring ? "PASS" : "FAIL"))")
        } else {
            KeyboardMoreMenu.current?.cancelTracking()
            log.append("quick picks more keyboard: no open menu with Play Next (FAIL)")
        }
        model.notice = nil
        await clearKeyboardFocus(into: &log)
        playHero(hero)
        await settle(0.4)
    }

    /// Space: the focused control acts on it, and only Space that nothing focused takes plays or pauses
    /// (`SpaceFallback`). Background Space in the main window and the mini player, Space in a track list, then (with
    /// Keyboard Navigation on, as council-shots.sh's second launch has it) the floating player's Next, the mini
    /// player's Next and Liked Songs' sidebar Play with focus. PASS/FAIL per step.
    private func checkSpaceKeys(hero: DemoNowPlaying, heroRoute: Route, into log: inout [String]) async {
        NSApp.appearance = NSAppearance(named: .aqua)
        let keyboardNavigation = NSApp.isFullKeyboardAccessEnabled
        log.append("space keys: Keyboard Navigation \(keyboardNavigation ? "on" : "off")")
        model.inspector = nil
        model.select(.home)
        playHero(hero)
        await settle(0.8)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        parkPointer()

        func space(in target: NSWindow) async {
            DebugProbes.note("space", nil)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: target.windowNumber, context: nil, characters: " ",
                                                charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            await settle(0.5)
        }
        func responder(_ w: NSWindow) -> String { w.firstResponder.map { String(describing: type(of: $0)) } ?? "none" }

        // Background: nothing focused in the main window.
        window.makeFirstResponder(nil)
        await settle(0.3)
        var playing = model.player.isPlaying
        await space(in: window)
        log.append("space keys: main window, nothing focused (first responder \(responder(window))): isPlaying \(playing) → \(model.player.isPlaying), \(DebugProbes.notes["space"] ?? "no fallback") (\(model.player.isPlaying != playing ? "PASS" : "FAIL"))")
        if model.player.isPlaying != playing { await space(in: window) }
        if !model.player.isPlaying { model.player.resume(); await settle(0.3) }

        // A track list with focus: Space plays and pauses, the list keeps focus.
        await open(heroRoute)
        await settle(1.0)
        await tabIntoTrackList(into: &log)
        playing = model.player.isPlaying
        await space(in: window)
        let listStill = DebugProbes.notes["track-list"]?.hasPrefix("focused") == true
        log.append("space keys: album track list focused: isPlaying \(playing) → \(model.player.isPlaying), \(DebugProbes.notes["space"] ?? "no toggle"), list still focused \(listStill) (\(model.player.isPlaying != playing && listStill ? "PASS" : "FAIL"))")
        if model.player.isPlaying != playing { await space(in: window) }
        window.makeFirstResponder(nil)
        model.select(.home)
        await settle(0.6)

        // Focused Next in the floating player.
        if keyboardNavigation {
            let before = model.player.current?.id
            playing = model.player.isPlaying
            DebugProbes.note("focus", nil)
            FocusProbe.request("player-next")
            await settle(0.4)
            let focused = DebugProbes.notes["focus"] == "player-next"
            await space(in: window)
            let advanced = model.player.current?.id != before
            log.append("space keys: floating player's Next focused \(focused) (first responder \(responder(window))): song \(advanced ? "advanced" : "unchanged"), isPlaying \(playing) → \(model.player.isPlaying), \(DebugProbes.notes["space"] ?? "no fallback") (\(focused && advanced && model.player.isPlaying == playing ? "PASS" : "FAIL"))")
            playHero(hero)
            await settle(0.4)

            // Focused Play on Liked Songs in the sidebar.
            do {
                let liked = AppModel.likedSongsContext.title
                DebugProbes.note("focus", nil)
                FocusProbe.request("sidebar-play-\(liked)")
                await settle(0.4)
                let focused = DebugProbes.notes["focus"] == "sidebar-play-\(liked)"
                await space(in: window)
                await settle(0.8)
                let started = model.playingFrom == AppModel.likedSongsContext && model.player.isPlaying
                log.append("space keys: Liked Songs' sidebar Play focused \(focused) (first responder \(responder(window))): playing from \(model.playingFrom?.title ?? "nothing"), isPlaying \(model.player.isPlaying), \(DebugProbes.notes["space"] ?? "no fallback") (\(focused && started ? "PASS" : "FAIL"))")
            }
            window.makeFirstResponder(nil)
            playHero(hero)
            await settle(0.4)
        } else {
            log.append("space keys: focused Next and sidebar Play: buttons take focus only with Keyboard Navigation on; checked in the second launch (council-space.txt)")
        }

        // The mini player: background Space, then (Keyboard Navigation) a focused Next.
        if let mini = await openMiniPlayer(hovering: false) {
            mini.makeKeyAndOrderFront(nil)
            mini.makeFirstResponder(nil)
            await settle(0.4)
            playing = model.player.isPlaying
            await space(in: mini)
            log.append("space keys: mini player, nothing focused (first responder \(responder(mini))): isPlaying \(playing) → \(model.player.isPlaying), \(DebugProbes.notes["space"] ?? "no fallback") (\(model.player.isPlaying != playing ? "PASS" : "FAIL"))")
            if model.player.isPlaying != playing { await space(in: mini) }
            if keyboardNavigation {
                let before = model.player.current?.id
                playing = model.player.isPlaying
                DebugProbes.note("focus", nil)
                FocusProbe.request("mini-next")
                await settle(0.4)
                let focused = DebugProbes.notes["focus"] == "mini-next"
                await space(in: mini)
                let advanced = model.player.current?.id != before
                log.append("space keys: mini player's Next focused \(focused) (first responder \(responder(mini))): song \(advanced ? "advanced" : "unchanged"), isPlaying \(playing) → \(model.player.isPlaying) (\(focused && advanced && model.player.isPlaying == playing ? "PASS" : "FAIL"))")
                mini.makeFirstResponder(nil)
            }
            mini.close()
            await settle(0.4)
        } else {
            log.append("space keys: the mini player didn't open (FAIL)")
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        playHero(hero)
        if !model.player.isPlaying { model.player.resume() }
        await settle(0.4)
    }

    // MARK: Drag and drop

    /// The first Quick picks song on Home.
    private func firstQuickPick() async -> Track? {
        guard let shelves = try? await yt.home(),
              let quick = shelves.first(where: { $0.title.lowercased() == "quick picks" }) else { return nil }
        return quick.items.lazy.compactMap { if case .track(let t) = $0 { t } else { nil } }.first
    }

    private static var dropPlaylist: Playlist?

    /// Shows the drop highlight on the first editable YouTube Music playlist in the sidebar.
    private func previewPlaylistDrop(into log: inout [String]) async -> Target {
        Self.dropPlaylist = nil
        guard let mine = model.sidebarPlaylists.first(where: { $0.isEditable && $0.provider == .youtubeMusic }),
              sidebarRowCenter(row: playlistRow(mine)) != nil else {
            log.append("drop on playlist: no editable YouTube Music playlist in the sidebar (FAIL)")
            return .main
        }
        DropPreviewProbe.show("playlist:\(mine.id)")
        await settle(0.3)
        Self.dropPlaylist = mine
        log.append("drop on playlist: hover highlight shown on “\(mine.title)” (row \(playlistRow(mine)))")
        return .main
    }

    /// Clears the highlight and drops the first Quick picks song on that playlist through the real handler, then
    /// checks it was appended and confirmed (PASS/FAIL).
    private func finishPlaylistDrop(into log: inout [String]) async {
        DropPreviewProbe.show(nil)
        guard let playlist = Self.dropPlaylist, let track = await firstQuickPick() else { return }
        Self.dropPlaylist = nil
        let before = yt.catalog.playlistTracks[playlist.providerID]?.count ?? 0
        let accepted = model.drop([MediaDragItem(.track(track))], on: playlist)
        await settle(0.8)
        let after = yt.catalog.playlistTracks[playlist.providerID] ?? []
        let ok = accepted && after.count == before + 1 && after.last?.id == track.id && model.notice?.text == "Added to \(playlist.title)"
        log.append("drop on playlist: “\(track.title)” dropped on “\(playlist.title)”: accepted \(accepted), \(before) → \(after.count) songs, notice \"\(model.notice?.text ?? "none")\" (\(ok ? "PASS" : "FAIL"))")
        if let spotify = sp.catalog.allTracks.first {
            let refused = !model.drop([MediaDragItem(.track(spotify))], on: playlist)
            log.append("drop on playlist: a Spotify song on it is refused with \"\(model.notice?.text ?? "no notice")\" (\(refused ? "PASS" : "FAIL"))")
        }
    }

    /// Drops the first Quick picks song on Playing Next through the real handler, above Up Next then below it.
    private func checkQueueDrops(into log: inout [String]) async {
        guard let track = await firstQuickPick() else { log.append("drop on playing next: no Quick picks song (FAIL)"); return }
        model.dropOnQueue([MediaDragItem(.track(track))], at: .playNext)
        await settle(0.6)
        let next = model.player.upNext.first?.track
        log.append("drop on playing next, above Up Next: next up “\(next?.title ?? "nothing")”, notice \"\(model.notice?.text ?? "none")\" (\(next?.id == track.id && model.notice?.text == "Playing next" ? "PASS" : "FAIL"))")
        let other = yt.catalog.allTracks.first { $0.id != track.id } ?? track
        model.dropOnQueue([MediaDragItem(.track(other))], at: .addToQueue)
        await settle(0.6)
        let end = model.player.upNext.filter { !$0.isAutoplay }.last?.track
        log.append("drop on playing next, below Up Next: Up Next ends with “\(end?.title ?? "nothing")”, notice \"\(model.notice?.text ?? "none")\" (\(end?.id == other.id && model.notice?.text == "Added to queue" ? "PASS" : "FAIL"))")
    }

    /// Takes keyboard focus off whatever the Tab presses left it on (the sidebar's search field would keep its ring
    /// in every later shot), and logs whether the search field let go.
    private func clearKeyboardFocus(into log: inout [String]) async {
        window.makeFirstResponder(nil)
        await settle(0.2)
        if AppModel.sidebarSearchHasFocus(in: window) {
            window.makeFirstResponder(window.contentView)
            await settle(0.2)
        }
        if AppModel.sidebarSearchHasFocus(in: window) { log.append("quick picks more keyboard: the sidebar search field kept focus after the check") }
    }

    /// Presses Tab (at most 20 times) until the album's track list has keyboard focus, and logs how many it took and
    /// what the list reports: focused, nothing selected, the first row outlined.
    private func tabIntoTrackList(into log: inout [String]) async {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        parkPointer()
        // Start from the window itself, not a field an earlier shot focused.
        window.makeFirstResponder(nil)
        DebugProbes.note("track-list", nil)
        await settle(0.2)
        var presses = 0
        while DebugProbes.notes["track-list"] == nil, presses < 20 {
            press(keyCode: 48, character: 0x09, function: false)
            presses += 1
            await settle(0.25)
        }
        let note = DebugProbes.notes["track-list"]
        let pass = note == "focused, selected row none, outlined row 0"
        log.append("track list focus: \(presses) Tab presses: \(note ?? "never focused") (\(pass ? "PASS" : "FAIL"))")
    }

    /// Focus that stays visible without a selection in a track list after ↓ ↓ Escape: the second row stays outlined.
    /// Logs PASS/FAIL.
    private func checkListFocus(heroRoute: Route, into log: inout [String]) async {
        NSApp.appearance = NSAppearance(named: .aqua)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        await open(heroRoute)
        await settle(1.0)
        await tabIntoTrackList(into: &log)
        for _ in 0..<2 {
            press(keyCode: 125, character: NSDownArrowFunctionKey)
            await settle(0.25)
        }
        let selected = DebugProbes.notes["track-list"] ?? "not focused"
        press(keyCode: 53, character: 0x1B, function: false)
        await settle(0.3)
        let escaped = DebugProbes.notes["track-list"] ?? "not focused"
        log.append("focus check, track list ↓ ↓ Escape: after ↓ ↓: \(selected); after Escape: \(escaped) (\(escaped == "focused, selected row none, outlined row 1" ? "PASS" : "FAIL"))")
        model.select(.home)
        await settle(0.4)
    }

    /// ⌘F (and the toolbar's search button) with the sidebar collapsed: the sidebar comes back with its search field
    /// focused. First at the full width with the sidebar hidden by hand, clicking the toolbar button; then ⌘F at the
    /// full width; last at 960 pt with Lyrics open (which hid the sidebar), where the panel has to close first. Ends in
    /// that last state for the shot.
    private func checkSearchReveal(height h: Double, place: (Double, Double) -> Void, into log: inout [String]) async {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        func state() -> String {
            "sidebar \(model.columnVisibility == .detailOnly ? "collapsed" : "shown"), panel \(model.inspector.map { "\($0)" } ?? "none"), "
                + "search field first responder \(AppModel.sidebarSearchHasFocus(in: window) ? "yes" : "no"), window \(Int(window.frame.width)) pt"
        }
        func reset() async {
            window.makeFirstResponder(nil)
            model.columnVisibility = .detailOnly
            await settle(0.8)
        }
        model.inspector = nil
        model.select(.home)
        await reset()
        let button = DebugProbes.windowFrame("toolbar-search")
        if let button {
            click(at: CGPoint(x: button.midX, y: button.midY))
            await settle(1.5)
            let ok = model.columnVisibility != .detailOnly && AppModel.sidebarSearchHasFocus(in: window)
            log.append("search collapsed: toolbar Search button at \(button) clicked: \(state()) (\(ok ? "PASS" : "FAIL"))")
        } else {
            log.append("search collapsed: toolbar Search button not on screen with the sidebar collapsed (FAIL)")
        }

        await reset()
        pressCommandF()
        await settle(1.5)
        let wide = model.columnVisibility != .detailOnly && AppModel.sidebarSearchHasFocus(in: window)
        log.append("search collapsed: ⌘F with the sidebar collapsed, no panel: \(state()) (\(wide ? "PASS" : "FAIL"))")

        window.makeFirstResponder(nil)
        model.columnVisibility = .all
        place(960, h)
        await settle(0.8)
        model.inspector = .lyrics
        await settle(1.5)
        // In capture runs (no animation) the split view can widen the window as the panel opens; put it back, so ⌘F
        // meets a 960 pt window with the panel open and the sidebar hidden.
        let grew = Int(window.frame.width)
        place(960, h)
        await settle(1.0)
        log.append("search collapsed: Lyrics opened at 960 pt (window was \(grew) pt after opening, set back to 960): \(state())")
        pressCommandF()
        await settle(1.8)
        let narrow = model.columnVisibility != .detailOnly && model.inspector == nil && AppModel.sidebarSearchHasFocus(in: window)
            && abs(window.frame.width - 960) < 1
        log.append("search collapsed: ⌘F at 960 pt with Lyrics open: \(state()) (\(narrow ? "PASS" : "FAIL"))")
    }

    /// ⌘F as a key event through the app, so it takes the menu's key-equivalent path like a person's press.
    private func pressCommandZ() {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: "z",
                                            charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6) {
                NSApp.sendEvent(event)
            }
        }
    }

    /// ⌘A through the app, as a person's press: the menu's key-equivalent path (Edit › Select All) first.
    private func pressCommandA() {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: "a",
                                            charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0) {
                NSApp.sendEvent(event)
            }
        }
    }

    private func pressCommandF() {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: "f",
                                            charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3) {
                NSApp.sendEvent(event)
            }
        }
    }

    /// A key press through the event queue, to whatever has keyboard focus in the main window.
    /// Arrow keys are function keys on the numeric pad; Tab and Escape (`function: false`) carry no flags.
    private func press(keyCode: UInt16, character: Int, function: Bool = true, modifiers: NSEvent.ModifierFlags = []) {
        let chars = String(Character(UnicodeScalar(UInt32(character))!))
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: (function ? NSEvent.ModifierFlags([.function, .numericPad]) : []).union(modifiers),
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                            isARepeat: false, keyCode: keyCode) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    /// A real click through the event queue at a top-left window point. Posted rather than sent, so a control that
    /// tracks the mouse (the sidebar's table) finds the mouse-up in the queue.
    private func click(at point: CGPoint, in target: NSWindow? = nil, modifiers: NSEvent.ModifierFlags = []) {
        mouse([.leftMouseDown, .leftMouseUp], at: point, in: target, modifiers: modifiers)
    }

    /// Mouse events through the event queue at a top-left window point (a press without its release, for a pressed state).
    private func mouse(_ types: [NSEvent.EventType], at point: CGPoint, in target: NSWindow? = nil, modifiers: NSEvent.ModifierFlags = []) {
        let window = target ?? window
        let local = NSPoint(x: point.x, y: window.frame.height - point.y)
        for type in types {
            if let event = NSEvent.mouseEvent(with: type, location: local, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                              pressure: type == .leftMouseDown ? 1 : 0) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    // MARK: Pointer

    /// Moves the real pointer off the window, so no hover state shows by accident.
    private func parkPointer() {
        let f = window.frame
        move(to: CGPoint(x: max(0, f.minX - 30), y: f.minY + 40), in: window)
    }

    /// Hovers a point given in top-left window coordinates.
    private func hover(at point: CGPoint) {
        let f = window.frame
        move(to: CGPoint(x: f.minX + point.x, y: f.maxY - point.y), in: window)
    }

    /// Moves the real pointer (screen coordinates, bottom-left origin) and delivers the enter/exit and moved
    /// events a warped cursor doesn't post (as HoverSelfTest does).
    private func move(to point: CGPoint, in target: NSWindow) {
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let quartz = CGPoint(x: point.x, y: primary - point.y)
        CGWarpMouseCursorPosition(quartz)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: quartz, mouseButton: .left)?.post(tap: .cghidEventTap)
        let local = target.convertPoint(fromScreen: point)
        let now = ProcessInfo.processInfo.systemUptime
        guard let root = target.contentView?.superview ?? target.contentView else { return }
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            stack.append(contentsOf: view.subviews)
            for area in view.trackingAreas {
                guard let owner = area.owner as? NSResponder else { continue }
                let rect = view.convert(area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect, to: nil)
                let inside = rect.contains(local)
                guard let event = NSEvent.enterExitEvent(with: inside ? .mouseEntered : .mouseExited, location: local, modifierFlags: [], timestamp: now,
                                                         windowNumber: target.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) else { continue }
                if inside { owner.mouseEntered(with: event) } else { owner.mouseExited(with: event) }
                if inside, let moved = NSEvent.mouseEvent(with: .mouseMoved, location: local, modifierFlags: [], timestamp: now,
                                                          windowNumber: target.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                    owner.mouseMoved(with: moved)
                }
            }
        }
    }

    // MARK: Capture

    private func image(for target: Target) -> CGImage? {
        switch target {
        case .main:
            return WindowCapture.image(of: window, shadow: false, fullResolution: true)
        case .window(let other):
            return other.flatMap { WindowCapture.image(of: $0, shadow: false, fullResolution: true) }
        case .mainWithPointer(let point):
            guard let base = WindowCapture.image(of: window, shadow: false, fullResolution: true) else { return nil }
            return drawPointer(on: base, at: point)
        case .sidebarCrop(let width, let pointer):
            guard var base = WindowCapture.image(of: window, shadow: false, fullResolution: true) else { return nil }
            if let pointer, let drawn = drawPointer(on: base, at: pointer) { base = drawn }
            let scale = CGFloat(base.width) / window.frame.width
            return base.cropping(to: CGRect(x: 0, y: 0, width: min(CGFloat(base.width), (width * scale).rounded()), height: CGFloat(base.height)))
        case .mainWithMenu:
            return imageWithMenus(of: window)
        case .windowWithMenu(let other):
            return other.flatMap { imageWithMenus(of: $0) }
        case .mainWithSheet:
            guard let base = WindowCapture.image(of: window, shadow: false, fullResolution: true) else { return nil }
            guard let sheet = window.attachedSheet, let top = WindowCapture.image(of: sheet, shadow: false, fullResolution: true) else { return base }
            let scale = CGFloat(base.width) / window.frame.width
            return composite(base) { ctx in
                // Bottom-left origin, like screen coordinates. A soft shadow stands in for the window server's.
                let rect = CGRect(x: (sheet.frame.minX - window.frame.minX) * scale, y: (sheet.frame.minY - window.frame.minY) * scale,
                                  width: sheet.frame.width * scale, height: sheet.frame.height * scale)
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -8 * scale), blur: 30 * scale, color: CGColor(gray: 0, alpha: 0.35))
                ctx.draw(top, in: rect)
                ctx.restoreGState()
            }
        }
    }

    /// A window with the app's open pop-up menus (their own window-server windows) drawn where they sit.
    private func imageWithMenus(of window: NSWindow) -> CGImage? {
        guard let base = WindowCapture.image(of: window, shadow: false, fullResolution: true) else { return nil }
        let menus = WindowCapture.menuWindows(above: window)
        guard !menus.isEmpty else { return base }
        let scale = CGFloat(base.width) / window.frame.width
        let origin = WindowCapture.bounds(of: window) ?? .zero
        return composite(base) { ctx in
            for (image, bounds) in menus {
                // Window-server bounds have a top-left origin; the context's is bottom-left.
                let rect = CGRect(x: (bounds.minX - origin.minX) * scale, y: CGFloat(base.height) - (bounds.maxY - origin.minY) * scale,
                                  width: bounds.width * scale, height: bounds.height * scale)
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 24 * scale, color: CGColor(gray: 0, alpha: 0.3))
                ctx.draw(image, in: rect)
                ctx.restoreGState()
            }
        }
    }

    /// The arrow pointer drawn on a capture at a top-left window point, since window captures never include it.
    private func drawPointer(on base: CGImage, at point: CGPoint) -> CGImage? {
        let cursor = NSCursor.arrow
        let scale = CGFloat(base.width) / window.frame.width
        var rect = NSRect(origin: .zero, size: cursor.image.size)
        guard let arrow = cursor.image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return base }
        let size = cursor.image.size
        let hot = cursor.hotSpot
        return composite(base) { ctx in
            let x = (point.x - hot.x) * scale
            let yTop = (point.y - hot.y) * scale
            ctx.draw(arrow, in: CGRect(x: x, y: CGFloat(base.height) - yTop - size.height * scale, width: size.width * scale, height: size.height * scale))
        }
    }

    private func composite(_ base: CGImage, draw: (CGContext) -> Void) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: base.colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return base }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        draw(ctx)
        return ctx.makeImage()
    }
}

/// A capture's pixels in sRGB, 8 bits a channel, top row first, for the checks that read them.
private struct Pixels {
    let width: Int
    let height: Int
    private let data: [UInt8]

    init?(_ image: CGImage) {
        width = image.width; height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        self.data = data
    }

    private func channel(_ row: Int, _ column: Int, _ c: Int) -> Int {
        Int(data[(min(max(row, 0), height - 1) * width + min(max(column, 0), width - 1)) * 4 + c])
    }

    /// The sRGB values, 0–255.
    func rgb(_ row: Int, _ column: Int) -> (red: Int, green: Int, blue: Int) {
        (channel(row, column, 0), channel(row, column, 1), channel(row, column, 2))
    }

    /// Rec. 709 luma of the sRGB values, 0–255 (what "a step of 6" in a capture means).
    func luma(_ row: Int, _ column: Int) -> Double {
        0.2126 * Double(channel(row, column, 0)) + 0.7152 * Double(channel(row, column, 1)) + 0.0722 * Double(channel(row, column, 2))
    }

    /// WCAG relative luminance, 0–1.
    func relativeLuminance(_ row: Int, _ column: Int) -> Double {
        func lin(_ v: Int) -> Double { let c = Double(v) / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(channel(row, column, 0)) + 0.7152 * lin(channel(row, column, 1)) + 0.0722 * lin(channel(row, column, 2))
    }

    /// The largest channel difference against another capture of the same size.
    func difference(_ other: Pixels, _ row: Int, _ column: Int) -> Int {
        (0..<3).map { abs(channel(row, column, $0) - other.channel(row, column, $0)) }.max() ?? 0
    }
}

/// The first menu that began tracking while a capture waited for one (`NSMenu.didBeginTrackingNotification`).
@MainActor
private final class TrackedMenu {
    var menu: NSMenu?
}
#endif
