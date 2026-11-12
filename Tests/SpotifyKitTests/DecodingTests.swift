import Foundation
import MedleyCore
import Testing
@testable import SpotifyKit

/// Every fixture is shaped like the Web API reference after the February 2026 changes.
@Suite struct DecodingTests {
    @Test func user() throws {
        let user = try Fixture.decode(SP.User.self, "me")
        #expect(user.id == "ada.listener")
        #expect(user.product == nil) // removed for development-mode apps
        let account = SpotifyMapping.account(user)
        #expect(account.name == "Ada Listener")
        #expect(account.avatar?.absoluteString.hasSuffix("large") == true) // largest image
        #expect(account.detail == nil)

        let extended = SpotifyMapping.account(try Fixture.decode(SP.User.self, "me-extended"))
        #expect(extended.detail == "Premium")
        #expect(extended.name == "ada.listener") // display_name null → id
    }

    @Test func album() throws {
        let album = try Fixture.decode(SP.Album.self, "album")
        #expect(album.tracks?.items.count == 2)
        #expect(album.tracks?.next != nil)
        #expect(album.label == nil)
        let model = SpotifyMapping.album(album.simplified)
        #expect(model.title == "Random Access Memories")
        #expect(model.year == 2013)
        #expect(model.kind == .album)
        #expect(model.trackCount == 13)
        #expect(model.artwork?.images.count == 3)
        #expect(model.artwork?.url(minPixels: 200)?.absoluteString.hasSuffix("300") == true)
        #expect(model.extra["uri"] == "spotify:album:4m2880jivSbbyEGAKfITCa")

        let track = try #require(SpotifyMapping.track(album.tracks!.items[0], album: album.simplified))
        #expect(track.album == AlbumRef(id: "4m2880jivSbbyEGAKfITCa", title: "Random Access Memories"))
        #expect(track.artwork == model.artwork) // album tracks borrow the album art
        #expect(track.duration == 274)
    }

    @Test func fullTrack() throws {
        let page = try Fixture.decode(SP.Paging<SP.Track>.self, "top-tracks")
        let track = try #require(page.items.first.flatMap(SpotifyMapping.track))
        #expect(track.provider == .spotify)
        #expect(track.providerID == "5W3cjX2J3tjhG8zb6u0qHn")
        #expect(track.title == "Harder, Better, Faster, Stronger")
        #expect(track.artists == [ArtistRef(id: "4tZwfgrHOc3mvqYlEYSvVi", name: "Daft Punk")])
        #expect(track.album?.title == "Discovery")
        #expect(abs((track.duration ?? 0) - 224.693) < 0.001)
        #expect(track.trackNumber == 4)
        #expect(track.isPlayable)
        #expect(track.extra["uri"] == "spotify:track:5W3cjX2J3tjhG8zb6u0qHn")
        #expect(track.extra["isrc"] != nil) // external_ids came back in March 2026
        #expect(track.id == "spotify:5W3cjX2J3tjhG8zb6u0qHn")
    }

    @Test func artistAndAlbums() throws {
        let artist = SpotifyMapping.artist(try Fixture.decode(SP.Artist.self, "artist"))
        #expect(artist.name == "Daft Punk")
        #expect(artist.subtitle == "Artist")
        #expect(artist.extra["genres"] == "french house,electro")

        let singles = try Fixture.decode(SP.Paging<SP.SimplifiedAlbum>.self, "artist-singles").items.map(SpotifyMapping.album)
        #expect(singles.map(\.kind) == [.single, .ep]) // 1-track single, 4-track "single" shown as EP
        #expect(singles[1].year == 2001) // year-precision date
    }

    @Test func searchSkipsNullEntries() throws {
        let response = try Fixture.decode(SP.SearchResponse.self, "search")
        #expect(response.tracks?.items.count == 4)
        #expect(response.tracks?.total == 812)
        #expect(response.playlists?.items.count == 2) // the null entry is dropped
        #expect(response.albums?.items.count == 3)
        #expect(response.artists?.items.count == 2)
    }

    @Test func ownedPlaylistUsesItemsField() throws {
        let playlist = try Fixture.decode(SP.Playlist.self, "playlist-owned")
        let contents = try #require(playlist.contents)
        #expect(contents.total == 104)
        #expect(contents.next?.contains("offset=100") == true)
        // A track, an episode, a local file, a removed (null) item.
        let tracks = contents.items.compactMap(\.content).compactMap(SpotifyMapping.track)
        #expect(tracks.map(\.title) == ["Get Lucky (feat. Pharrell Williams and Nile Rodgers)"])

        let model = SpotifyMapping.playlist(playlist.simplified, currentUserID: "ada.listener")
        #expect(model.isEditable)
        #expect(model.owner == "Ada Listener")
        #expect(model.trackCount == 104)
    }

    @Test func otherPlaylistHasNoItems() throws {
        let playlist = try Fixture.decode(SP.Playlist.self, "playlist-other")
        #expect(playlist.contents == nil)
        let model = SpotifyMapping.playlist(playlist.simplified, currentUserID: "ada.listener")
        #expect(!model.isEditable)
        #expect(model.summary == "This is Daft Punk.")
    }

    @Test func legacyTrackFieldStillDecodes() throws {
        let page = try Fixture.decode(SP.Paging<SP.PlaylistItem>.self, "playlist-items-page2")
        #expect(page.items.compactMap(\.content).map(\.name) == ["One More Time", "Harder, Better, Faster, Stronger"])
    }

    @Test func playlistsList() throws {
        let page = try Fixture.decode(SP.Paging<SP.SimplifiedPlaylist>.self, "my-playlists")
        let models = page.items.map { SpotifyMapping.playlist($0, currentUserID: "ada.listener") }
        #expect(models.map(\.isEditable) == [true, true, false]) // own, collaborative, followed
        #expect(models[1].artwork == nil) // `images: null`
        #expect(models.map(\.trackCount) == [104, 12, 50])
    }

    @Test func descriptionsAreCleaned() {
        #expect(SpotifyMapping.cleanDescription(#"Best of <a href="spotify:artist:x">Daft Punk</a> &amp; more"#) == "Best of Daft Punk & more")
        #expect(SpotifyMapping.cleanDescription("") == nil)
        #expect(SpotifyMapping.cleanDescription(nil) == nil)
    }

    @Test func savedAndFollowed() throws {
        let saved = try Fixture.decode(SP.Paging<SP.SavedTrack>.self, "saved-tracks")
        let tracks = saved.items.compactMap { SpotifyMapping.track($0.track) }
        #expect(tracks.map(\.isPlayable) == [true, false])
        #expect(saved.next != nil)

        let albums = try Fixture.decode(SP.Paging<SP.SavedAlbum>.self, "saved-albums")
        #expect(albums.items.first?.album.name == "Random Access Memories")

        let followed = try Fixture.decode(SP.FollowedArtists.self, "followed-artists")
        #expect(followed.artists.items.map(\.name) == ["Daft Punk", "Pharrell Williams"])
        #expect(followed.artists.cursors?.after == "2RdwBSPQiwcmiDo9kixcl8")
        #expect(followed.artists.next?.contains("after=") == true)
    }

    @Test func recentlyPlayed() throws {
        let page = try Fixture.decode(SP.CursorPaging<SP.PlayHistory>.self, "recently-played")
        #expect(page.items.count == 4)
        #expect(page.items[0].context?.type == "album")
        #expect(page.cursors?.before == "1761900000000")
    }

    @Test func playerAndDevices() throws {
        let devices = try Fixture.decode(SP.Devices.self, "devices").devices.compactMap(SpotifyDevice.init)
        #expect(devices.map(\.name) == ["Ada's MacBook", "Kitchen TV"]) // device without id is dropped
        #expect(devices[0].isActive)
        #expect(devices[1].isRestricted)

        let state = try Fixture.decode(SP.PlaybackState.self, "player-state")
        let sample = ConnectRoute.sample(from: state, timestamp: 10)
        #expect(sample.state == .playing)
        #expect(sample.trackURI == "spotify:track:69kOkLUCkxIZYexIgSG8rq")
        #expect(abs(sample.position - 123.456) < 0.001)
        #expect(abs((sample.duration ?? 0) - 369.626) < 0.001)
    }

    @Test func createdPlaylistAndMisc() throws {
        let created = try Fixture.decode(SP.Playlist.self, "created-playlist")
        #expect(created.contents?.total == 0)
        #expect(created.public == false)
        #expect(try Fixture.decode([Bool].self, "library-contains") == [true, false])
        #expect(try Fixture.decode(SP.Snapshot.self, "snapshot").snapshot_id == "AAAAC1x1abc")
        #expect(try Fixture.decode(SP.NewReleases.self, "new-releases").albums.items.count == 2)
        #expect(try Fixture.decode(SP.APIErrorBody.self, "error-quota").error.reason == "QUOTA_EXCEEDED")
    }

    @Test func footnote() {
        #expect(SpotifyMapping.albumFootnote(trackCount: 13, totalSeconds: 4475, releaseDate: "2013-05-17", copyright: "℗ 2013 Daft Life")
                == "13 songs, 1 hr 15 min · May 17, 2013\n℗ 2013 Daft Life")
        #expect(SpotifyMapping.albumFootnote(trackCount: 1, totalSeconds: 248, releaseDate: "2013", copyright: nil) == "1 song, 4 minutes · 2013")
    }

    @Test func uris() {
        let track = Track(providerID: "abc", provider: .spotify, title: "x")
        #expect(SpotifyMapping.uri(track) == "spotify:track:abc")
        #expect(SpotifyMapping.uri(.artist(Artist(providerID: "a1", provider: .spotify, name: "A"))) == "spotify:artist:a1")
        #expect(SpotifyMapping.uri(.playlist(Playlist(providerID: "p1", provider: .spotify, title: "P"))) == "spotify:playlist:p1")
        #expect(SpotifyMapping.uri(.album(Album(providerID: "al", provider: .spotify, title: "A", extra: ["uri": "spotify:album:al"]))) == "spotify:album:al")
    }
}
