import Foundation
import MedleyCore
import Testing
@testable import YouTubeMusicKit

/// Parser tests against real, signed-out InnerTube responses captured 2026-10-31 (scrubbed of
/// visitor ids, IP addresses, tracking params, and stream signatures; menus trimmed for size).
enum Fixture {
    static func data(_ name: String, ext: String = "json") throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"), "missing fixture \(name)")
        return try Data(contentsOf: url)
    }

    static func json(_ name: String) throws -> JSONObject {
        try #require(try JSONSerialization.jsonObject(with: data(name)) as? JSONObject)
    }

    static func text(_ name: String, ext: String) throws -> String {
        String(decoding: try data(name, ext: ext), as: UTF8.self)
    }
}

private extension MediaItem {
    var track: Track? { if case .track(let t) = self { t } else { nil } }
    var album: Album? { if case .album(let a) = self { a } else { nil } }
    var artist: Artist? { if case .artist(let a) = self { a } else { nil } }
    var playlist: Playlist? { if case .playlist(let p) = self { p } else { nil } }
}

@Suite struct BrowseParsing {
    @Test func home() throws {
        let root = try Fixture.json("home")
        let shelves = PageParser.shelves(root)
        let quick = try #require(shelves.first { $0.title == "Quick picks" })
        #expect(quick.style == .trackList)
        #expect(quick.items.count == 20)
        let first = try #require(quick.items.first?.track)
        #expect(first.providerID.count == 11)
        #expect(!first.artists.isEmpty)
        #expect(first.album != nil)
        #expect(first.artwork?.url(minPixels: 500) != nil)

        let throwbacks = try #require(shelves.first { $0.title == "Throwbacks" })
        #expect(throwbacks.subtitle == "CLASSICS FROM EVERY DECADE")
        #expect(throwbacks.style == .carousel)
        #expect(throwbacks.items.allSatisfy { $0.playlist != nil })

        let token = try #require(PageParser.sectionsContinuation(root))
        #expect(token.hasPrefix("q:"))
    }

    /// Signed out, Home keeps YouTube's public shelves and leaves out any made from this Mac's own listening.
    @Test func anonymousHomeLeavesOutPersonalShelves() throws {
        let shelves = PageParser.shelves(try Fixture.json("home"))
        #expect(YouTubeMusicProvider.anonymousHome(shelves).map(\.title) == shelves.map(\.title))

        let liked = Playlist(providerID: "LM", provider: .youtubeMusic, title: "Liked Music")
        let mix = Playlist(providerID: "RDTMAK5uy_x", provider: .youtubeMusic, title: "Supermix")
        let personal = [
            Shelf(id: "a", title: "Listen again", style: .carousel, items: [.playlist(mix)]),
            Shelf(id: "b", title: "Mixed for you", style: .hero, items: [.playlist(mix)]),
            Shelf(id: "c", title: "Throwbacks", style: .carousel, items: [.playlist(liked), .playlist(mix)]),
            Shelf(id: "d", title: "Only liked", style: .carousel, items: [.playlist(liked)]),
        ]
        let kept = YouTubeMusicProvider.anonymousHome(personal)
        #expect(kept.map(\.title) == ["Throwbacks"])
        #expect(kept.first?.items.count == 1)
    }

    @Test func homeContinuation() throws {
        let root = try Fixture.json("home_continuation")
        let shelves = PageParser.shelves(root)
        #expect(shelves.map(\.title).contains("Today's biggest hits"))
        #expect(shelves.allSatisfy { !$0.items.isEmpty })
        #expect(PageParser.sectionsContinuation(root) != nil)
    }

    @Test func explore() throws {
        let shelves = PageParser.shelves(try Fixture.json("explore"))
        let releases = try #require(shelves.first { $0.title == "New albums & singles" })
        #expect(releases.style == .carousel)
        #expect(releases.items.contains { $0.album != nil })
        #expect(releases.moreToken == "browse|FEmusic_new_releases_albums|")

        let moods = try #require(shelves.first { $0.title == "Moods & genres" })
        #expect(moods.items.count == 40)
        let chill = try #require(moods.items.first?.playlist)
        #expect(chill.extra["category"] == "1")
        #expect(chill.providerID.hasPrefix("category:browse|FEmusic_moods_and_genres_category|"))
        #expect(MoreToken(String(chill.providerID.dropFirst("category:".count))) != nil)
    }

    @Test func charts() throws {
        let shelves = PageParser.shelves(try Fixture.json("charts"))
        let artists = try #require(shelves.first { $0.title == "Top artists" })
        #expect(artists.style == .artists)
        #expect(artists.items.count == 40)
        #expect(artists.items.first?.artist?.subtitle?.contains("subscribers") == true)
        let albums = try #require(shelves.first { $0.title == "Top albums" })
        #expect(albums.items.allSatisfy { $0.album != nil })
    }

    @Test func moodsPageExpandsToCategories() throws {
        let shelf = PageParser.expandedShelf(try Fixture.json("moods"), token: "browse|FEmusic_moods_and_genres|")
        #expect(shelf.items.count == 40)
        #expect(shelf.items.allSatisfy { $0.playlist?.extra["category"] == "1" })
    }
}

@Suite struct SearchParsing {
    @Test func all() throws {
        let r = PageParser.search(try Fixture.json("search_all"), scope: .all)
        let top = try #require(r.top?.artist)
        #expect(top.name == "Daft Punk")
        #expect(top.providerID == "UCRr1xG_2WIDs18a6cIiCxeA")
        #expect(r.artists.first?.name == "Daft Punk")
        // Songs from the top-result card inherit the artist.
        let card = try #require(r.tracks.first { $0.providerID == "4j064xpolDw" })
        #expect(card.artists.first?.name == "Daft Punk")
        #expect(card.duration == 135)
        #expect(r.albums.contains { $0.providerID == "MPREb_7ltM34kr0mH" && $0.year == 2001 })
        #expect(r.playlists.contains { $0.providerID == "RDCLAK5uy_n20FRYQXNt1p1wS55Nj2r14IouO5weaYU" && $0.trackCount == 35 })
        // Songs come before music videos.
        let firstVideo = r.tracks.firstIndex { $0.extra["musicVideoType"] == "MUSIC_VIDEO_TYPE_OMV" } ?? r.tracks.endIndex
        #expect(r.tracks[..<firstVideo].allSatisfy { $0.extra["musicVideoType"] != "MUSIC_VIDEO_TYPE_OMV" })
        #expect(r.tracks[firstVideo...].allSatisfy { $0.extra["musicVideoType"] == "MUSIC_VIDEO_TYPE_OMV" })
    }

    @Test func songs() throws {
        let r = PageParser.search(try Fixture.json("search_songs"), scope: .songs)
        #expect(r.tracks.count == 20)
        let first = try #require(r.tracks.first)
        #expect(first.title == "Instant Crush (feat. Julian Casablancas)")
        #expect(first.artists.map(\.name) == ["Daft Punk", "Julian Casablancas"])
        #expect(first.artists.first?.id == "UCRr1xG_2WIDs18a6cIiCxeA")
        #expect(first.album == AlbumRef(id: "MPREb_K8qWMWVqXGi", title: "Random Access Memories"))
        #expect(first.duration == 338)
        #expect(first.extra["musicVideoType"] == "MUSIC_VIDEO_TYPE_ATV")
    }

    @Test func albumsArtistsPlaylists() throws {
        let albums = PageParser.search(try Fixture.json("search_albums"), scope: .albums).albums
        #expect(albums.first?.title == "Random Access Memories")
        #expect(albums.first?.year == 2013)
        #expect(albums.first?.kind == .album)
        #expect(albums.first?.artists.first?.name == "Daft Punk")

        let artists = PageParser.search(try Fixture.json("search_artists"), scope: .artists).artists
        #expect(artists.first?.name == "Daft Punk")
        #expect(artists.first?.subtitle == "68.3M monthly audience")

        let playlists = PageParser.search(try Fixture.json("search_playlists"), scope: .playlists).playlists
        #expect(playlists.count >= 10)
        #expect(playlists.first?.owner == "GotWub")
        #expect(playlists.allSatisfy { !$0.providerID.hasPrefix("VL") })
    }

    @Test func suggestions() throws {
        let s = PageParser.suggestions(try Fixture.json("suggestions"))
        #expect(s.first == "daft punk")
        #expect(s.contains("daft punk get lucky"))
    }

    /// The direct matches under the completions: the artist first, then songs with their albums.
    @Test func suggestionItems() throws {
        let items = PageParser.suggestionItems(try Fixture.json("suggestions"))
        guard case .artist(let artist)? = items.first else { Issue.record("expected an artist first"); return }
        #expect(artist.name == "Daft Punk")
        #expect(artist.providerID == "UCRr1xG_2WIDs18a6cIiCxeA")
        #expect(artist.artwork != nil)
        let songs = items.compactMap { if case .track(let t) = $0 { t } else { nil } }
        #expect(songs.count == 4)
        #expect(songs.first?.album?.title == "Discovery")
    }

    /// Search rows without an album take the album and artist links from the watch queue's listing.
    @Test func linkedTrackFillsMissingLinks() {
        let row = Track(providerID: "abc", provider: .youtubeMusic, title: "Patient Zero", artists: [ArtistRef(name: "Taylor Swift")], duration: 226)
        let listing = Track(providerID: "abc", provider: .youtubeMusic, title: "?", artists: [ArtistRef(id: "UCx", name: "Taylor Swift")],
                            album: AlbumRef(id: "MPREb_1", title: "The Life of a Showgirl"), duration: 999)
        let filled = row.filling(from: listing)
        #expect(filled.title == "Patient Zero")
        #expect(filled.album?.id == "MPREb_1")
        #expect(filled.artists.first?.id == "UCx")
        #expect(filled.duration == 226)
    }
}

@Suite struct EntityParsing {
    @Test func album() throws {
        let d = try PageParser.album(try Fixture.json("album"), browseId: "MPREb_7ltM34kr0mH")
        #expect(d.album.title == "Discovery")
        #expect(d.album.artists.first == ArtistRef(id: "UCRr1xG_2WIDs18a6cIiCxeA", name: "Daft Punk"))
        #expect(d.album.year == 2001)
        #expect(d.album.kind == .album)
        #expect(d.album.extra["playlistId"] == "OLAK5uy_mz6eafmqdRHSaR4IwG0ll6J6rgv0_ZpGw")
        #expect(d.tracks.count == 14)
        #expect(d.tracks.map(\.trackNumber) == Array(1...14))
        #expect(d.tracks.first?.title == "One More Time")
        #expect(d.tracks.first?.duration == 321)
        #expect(d.tracks.first?.extra["setVideoId"] != nil)
        #expect(d.tracks.allSatisfy { $0.artists.first?.name == "Daft Punk" && $0.album?.id == "MPREb_7ltM34kr0mH" })
        #expect(d.album.artwork?.images.contains { $0.width == 1080 } == true)
        #expect(d.footnote?.contains("14 songs") == true)
        #expect(d.summary?.hasPrefix("Discovery is the second studio album") == true)
        // "Releases for you" isn't "more by this artist".
        #expect(d.moreByArtist.allSatisfy { $0.artists.contains { $0.name == "Daft Punk" } })
    }

    @Test func artist() throws {
        let d = try PageParser.artist(try Fixture.json("artist"), browseId: "UCRr1xG_2WIDs18a6cIiCxeA")
        #expect(d.artist.name == "Daft Punk")
        #expect(d.artist.subtitle == "68.3M monthly audience")
        #expect(d.artist.extra["channelId"] == "UC_kRDKYrUlrbtrSiyu5Tflg")
        #expect(d.radioSeed?.hasPrefix("RDEM") == true)
        #expect(d.isFollowed == false)
        #expect(d.topTracks.count == 5)
        #expect(d.albums.count == 10)
        #expect(d.albums.contains { $0.title == "Discovery" && $0.artists.first?.name == "Daft Punk" })
        #expect(d.singles.count == 10)
        #expect(d.playlists.count >= 10)
        #expect(d.related.count == 10)
        #expect(d.bio?.hasPrefix("Daft Punk were a French") == true)
    }

    @Test func playlistWithContinuation() throws {
        let d = try PageParser.playlist(try Fixture.json("playlist"), playlistId: "RDCLAK5uy_mkXiaMATud8GJQ3aX7f0nCeCqvehA9wTQ")
        #expect(d.playlist.title == "Dance Party Hits")
        #expect(d.playlist.owner == "YouTube Music")
        #expect(d.playlist.trackCount == 119)
        #expect(d.playlist.isEditable == false)
        #expect(d.tracks.count == 100)
        #expect(d.tracks.allSatisfy { $0.extra["setVideoId"] != nil })
        #expect(d.tracks.first?.artists.map(\.name) == ["Calvin Harris", "Rihanna"])
        let token = try #require(d.continuation)
        #expect(token.hasPrefix("b:"))

        let (items, next) = PageParser.continuationItems(try Fixture.json("playlist_continuation"))
        #expect(items.count == 19)
        #expect(items.allSatisfy { $0.track != nil })
        #expect(next == nil)
    }

    /// A header without "119 songs": the first page's 100 songs aren't passed off as the total while a later page
    /// exists (the app would take a long playlist for a short one and load it all when opened).
    @Test func playlistWithoutTotal() throws {
        func strip(_ value: Any) -> Any {
            if let object = value as? JSONObject {
                return object.filter { $0.key != "secondSubtitle" }.mapValues(strip)
            }
            if let array = value as? [Any] { return array.map(strip) }
            return value
        }
        let root = try #require(strip(try Fixture.json("playlist")) as? JSONObject)
        let d = try PageParser.playlist(root, playlistId: "RDCLAK5uy_mkXiaMATud8GJQ3aX7f0nCeCqvehA9wTQ")
        #expect(d.tracks.count == 100)
        #expect(d.continuation != nil)
        #expect(d.playlist.trackCount == nil)
    }

    @Test func watchNext() throws {
        let next = PageParser.watchNext(try Fixture.json("next"))
        #expect(next.tracks.count == 50)
        #expect(next.tracks.first?.providerID == "wU26xVT_vBU")
        #expect(next.tracks.first?.artists.first?.name == "Daft Punk")
        #expect(next.tracks.first?.duration == 321)
        #expect(next.lyricsBrowseId == "MPLYt_uWQeJO6Z53u-2")
        #expect(next.likeStatus == "INDIFFERENT")
        #expect(next.continuation != nil)
    }

    @Test func timedLyrics() throws {
        let lyrics = try #require(PageParser.lyrics(try Fixture.json("lyrics_android")))
        #expect(lyrics.isSynced)
        #expect(lyrics.source == "Source: LyricFind")
        let first = try #require(lyrics.lines.first { !$0.text.isEmpty })
        #expect(first.text == "One more time")
        #expect(first.time == 30.35)
        let times = lyrics.lines.compactMap(\.time)
        #expect(times == times.sorted())
    }

    @Test func plainLyrics() throws {
        let lyrics = try #require(PageParser.lyrics(try Fixture.json("lyrics")))
        #expect(!lyrics.isSynced)
        #expect(lyrics.lines.first?.text == "One more time")
        #expect(lyrics.lines.count > 50)
        #expect(lyrics.source == "Source: LyricFind")
    }
}

@Suite struct StreamParsing {
    @Test func playerResponse() throws {
        let info = PlayerInfo(try Fixture.json("player_visionos"))
        #expect(info.status == "OK")
        let best = try #require(info.bestDirectAudio)
        #expect(best.itag == 140)
        #expect(best.mimeType.hasPrefix("audio/mp4"))
        #expect(best.loudnessDb != nil)
        #expect(info.hlsManifestURL != nil)
        #expect(info.expiresIn == 21540)
        // WebM/Opus formats exist but AVPlayer can't play them.
        #expect(info.formats.contains { $0.mimeType.hasPrefix("audio/webm") })
    }

    @Test func hlsAudioRendition() throws {
        let master = try Fixture.text("hls_master", ext: "m3u8")
        let r = try #require(YouTubeStreamResolver.audioRendition(fromMaster: master))
        #expect(r.itag == 234)
        #expect(r.url.absoluteString.contains("/itag/234/"))
        // YT-EXT-ABSOLUTE-LOUDNESS=-12.350 LUFS → +1.65 dB relative to YouTube's -14 LUFS reference (= itag 140's loudnessDb).
        let loud = try #require(r.loudnessDb)
        #expect(abs(loud - 1.65) < 0.001)
    }

    @Test func hlsAttributes() {
        let attrs = YouTubeStreamResolver.parseAttributes(#"URI="https://x/a,b",TYPE=AUDIO,GROUP-ID="234",YT-EXT-ABSOLUTE-LOUDNESS=-13.010"#)
        #expect(attrs["URI"] == "https://x/a,b")
        #expect(attrs["TYPE"] == "AUDIO")
        #expect(attrs["GROUP-ID"] == "234")
        #expect(attrs["YT-EXT-ABSOLUTE-LOUDNESS"] == "-13.010")
    }

    @Test func serviceWorkerData() throws {
        let text = try Fixture.text("sw_js_data", ext: "txt")
        #expect(InnerTubeClient.serviceWorkerVisitor(text) == "CgtGSVhUVVJFX1ZJU0lUT1IoAQ==")
        #expect(InnerTubeClient.firstMatch(#"\b1\.20\d{6}\.\d{2}\.\d{2}\b"#, in: text) == "1.20261027.10.00")
    }
}

@Suite struct Helpers {
    @Test func durations() {
        #expect(YTText.duration("3:47") == 227)
        #expect(YTText.duration("1:02:03") == 3723)
        #expect(YTText.duration("10:01") == 601)
        #expect(YTText.duration("2013") == nil)
        #expect(YTText.duration("1.2B plays") == nil)
    }

    @Test func artworkResizing() throws {
        let url = try #require(URL(string: "https://lh3.googleusercontent.com/abc=w60-h60-l90-rj"))
        let images = try #require(YTArtwork.resizable(url))
        #expect(images.map(\.width) == YTArtwork.squareSizes)
        #expect(images.last?.url.absoluteString == "https://lh3.googleusercontent.com/abc=w1080-h1080-l90-rj")
        let videoURL = try #require(URL(string: "https://i.ytimg.com/vi/dQw4w9WgXcQ/sddefault.jpg?sqp=x"))
        let video = try #require(YTArtwork.videoThumbnails(videoURL))
        #expect(video.last?.url.absoluteString == "https://i.ytimg.com/vi/dQw4w9WgXcQ/sddefault.jpg")
    }

    @Test func playlistTrackCount() {
        #expect(PageParser.trackCount("29K views • 1,000 songs • 3+ hours") == 1000)
        #expect(PageParser.trackCount("119 songs • 6+ hours") == 119)
        #expect(PageParser.trackCount("2026 • 12 views") == nil)
    }

    @Test func moreTokenRoundTrip() {
        let token = MoreToken.browse(browseId: "FEmusic_moods_and_genres_category", params: "ggMPOg1uX1JOQWZFeDByc2Jm")
        #expect(MoreToken(token.encoded) == token)
        #expect(MoreToken("browse|FEmusic_new_releases_albums|") == .browse(browseId: "FEmusic_new_releases_albums", params: nil))
        #expect(MoreToken("garbage") == nil)
    }

    @Test func artistNameSplitting() {
        #expect(ItemParser.artistNames("Calvin Harris & Rihanna").map(\.name) == ["Calvin Harris", "Rihanna"])
        #expect(ItemParser.artistNames("Unjaps, 404NR & June Boii").map(\.name) == ["Unjaps", "404NR", "June Boii"])
    }

    @Test func searchParamsPerScope() {
        #expect(InnerTubeClient.searchParams(.all) == nil)
        #expect(Set(SearchScope.allCases.compactMap(InnerTubeClient.searchParams)).count == 4)
    }
}

@Suite struct Credentials {
    @Test func parsesCookieHeader() throws {
        let creds = try #require(YTMCredentials(cookieHeader: "cookie: SID=sid1; HSID=h; SAPISID=SAPISIDVALUE; __Secure-3PAPISID=P3VALUE; PREF=\"f6=40000000\""))
        #expect(creds.cookies["SID"] == "sid1")
        #expect(creds.cookies["PREF"] == "f6=40000000")
        #expect(creds.sapisid == "SAPISIDVALUE")
        #expect(creds.cookieHeader.contains("SAPISID=SAPISIDVALUE"))
    }

    @Test func rejectsHeaderWithoutSession() {
        #expect(YTMCredentials(cookieHeader: "PREF=x; YSC=y") == nil)
        #expect(YTMCredentials(cookieHeader: "SAPISID=x") == nil)
    }

    @Test func sapisidHash() throws {
        let creds = YTMCredentials(cookies: ["SID": "s", "SAPISID": "SAPISIDVALUE", "__Secure-3PAPISID": "P3VALUE"])
        let auth = try #require(creds.authorization(now: Date(timeIntervalSince1970: 1_700_000_000)))
        // sha1("1700000000 SAPISIDVALUE https://music.youtube.com"), computed independently with Python's hashlib.
        #expect(auth.hasPrefix("SAPISIDHASH 1700000000_7ef7126262ab644136fc1ceef792ef2dac969ed5"))
        #expect(auth.contains("SAPISID3PHASH 1700000000_af8f394de379e582818793b4e8a0649f3559ab9b"))
        let headers = creds.headers()
        #expect(headers["X-Origin"] == "https://music.youtube.com")
        #expect(headers["X-Goog-AuthUser"] == "0")
        #expect(headers["Cookie"]?.contains("SID=s") == true)
    }

    @Test func mergesRotatedCookies() throws {
        var creds = YTMCredentials(cookies: ["SID": "s", "SAPISID": "a", "__Secure-1PSIDTS": "old"])
        let url = try #require(URL(string: "https://music.youtube.com/youtubei/v1/browse"))
        let changed = creds.merge(setCookieHeaders: ["Set-Cookie": "__Secure-1PSIDTS=new; Domain=.youtube.com; Path=/; Secure; HttpOnly"], url: url)
        #expect(changed)
        #expect(creds.cookies["__Secure-1PSIDTS"] == "new")
    }
}
