import Foundation
import OpenMusicCore
import Testing
@testable import OpenMusic

/// What a row's or card's second line says when it would only repeat itself: a hero card's artist list on one line,
/// an artist's Top Songs without nine copies of one album, the Songs table without a Service column for one service.
@MainActor
@Suite struct SecondLineTests {
    private func track(_ n: Int, album: String?, provider: ProviderID = .youtubeMusic, artists: [String] = ["Olivia Rodrigo"]) -> Track {
        Track(providerID: "t\(n)", provider: provider, title: "Song \(n)", artists: artists.map { ArtistRef(name: $0) },
              album: album.map { AlbumRef(title: $0) })
    }

    @Test func heroCardFitsNameListsOnOneLine() {
        let mix = Playlist(providerID: "mix", provider: .spotify, title: "Daily Mix 2", summary: "Kendrick Lamar, Dominic Fike, ADÉLA and more")
        #expect(HeroCard.detailLayout(item: .playlist(mix), detail: mix.summary!) == .nameList)
        let weekly = Playlist(providerID: "dw", provider: .spotify, title: "Discover Weekly",
                              summary: "Your weekly mixtape of fresh music. Enjoy new music and deep cuts picked for you.")
        #expect(HeroCard.detailLayout(item: .playlist(weekly), detail: weekly.summary!) == .description)
        let duet = Album(providerID: "a", provider: .spotify, title: "Duet", artists: [ArtistRef(name: "SZA"), ArtistRef(name: "Phoebe Bridgers")])
        #expect(HeroCard.detailLayout(item: .album(duet), detail: duet.artistLine) == .names(["SZA", "Phoebe Bridgers"]))
    }

    @Test func topSongsFromOneAlbumHaveNoAlbumLine() {
        let album = "you seem pretty sad for a girl so sad"
        let one = (0..<9).map { track($0, album: $0 == 3 ? " You Seem Pretty Sad For A Girl So Sad" : album) }
        #expect(TopSongs.sharesOneAlbum(one))
        #expect(TopSongs.subtitle(for: one[0], oneAlbum: true) == "")
        let mixed = one + [track(9, album: "GUTS")]
        #expect(!TopSongs.sharesOneAlbum(mixed))
        #expect(TopSongs.subtitle(for: mixed[9], oneAlbum: false) == "GUTS")
        // A song without an album shows its artists (nil: the row's default line).
        #expect(TopSongs.subtitle(for: track(10, album: nil), oneAlbum: false) == nil)
        #expect(!TopSongs.sharesOneAlbum([track(0, album: album)]))
        #expect(!TopSongs.sharesOneAlbum([track(0, album: album), track(1, album: nil)]))
    }

    @Test func songsTableShowsServiceOnlyForMixedLists() {
        let youtube = (0..<3).map { track($0, album: "A") }
        #expect(!SongsTable.showsServiceColumn(youtube))
        #expect(!SongsTable.showsServiceColumn([]))
        #expect(SongsTable.showsServiceColumn(youtube + [track(9, album: "B", provider: .spotify)]))
    }
}
