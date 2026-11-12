using System.Text.Json.Nodes;
using Medley.Core;
using Medley.Providers.YouTube;
using Medley.Providers.YouTube.InnerTube;
using Medley.Providers.YouTube.Json;
using Medley.Providers.YouTube.Parsing;
using Medley.Providers.YouTube.Playback;
using Xunit;

namespace Medley.Providers.YouTube.Tests;

/// <summary>
/// Real, signed-out InnerTube responses. The Swift fixtures (captured 2026-10-31, scrubbed) are the same files the Swift
/// ParserTests use, so both parsers are held to the same expectations; <c>live_*</c> fixtures were recorded with this
/// probe on 2026-11-07 and trimmed.
/// </summary>
internal static class Fixture
{
    public static string PathOf(string name) => Path.Combine(AppContext.BaseDirectory, "Fixtures", name);
    public static byte[] Bytes(string name) => File.ReadAllBytes(PathOf(name));
    public static string Text(string name) => File.ReadAllText(PathOf(name));
    public static JsonObject Json(string name) => (JsonObject)JsonNav.Parse(Bytes(name.EndsWith(".json", StringComparison.Ordinal) ? name : name + ".json"))!;
}

internal static class ItemExtensions
{
    public static Track? AsTrack(this MediaItem? i) => (i as MediaItem.TrackItem)?.Track;
    public static Album? AsAlbum(this MediaItem? i) => (i as MediaItem.AlbumItem)?.Album;
    public static Artist? AsArtist(this MediaItem? i) => (i as MediaItem.ArtistItem)?.Artist;
    public static Playlist? AsPlaylist(this MediaItem? i) => (i as MediaItem.PlaylistItem)?.Playlist;
}

public class BrowseParsing
{
    [Fact]
    public void Home()
    {
        var root = Fixture.Json("home");
        var shelves = PageParser.Shelves(root);
        var quick = shelves.Single(s => s.Title == "Quick picks");
        Assert.Equal(ShelfStyle.TrackList, quick.Style);
        Assert.Equal(20, quick.Items.Count);
        var first = quick.Items[0].AsTrack()!;
        Assert.Equal(11, first.ProviderID.Length);
        Assert.NotEmpty(first.Artists);
        Assert.NotNull(first.Album);
        Assert.NotNull(first.Artwork?.Url(500));

        var throwbacks = shelves.Single(s => s.Title == "Throwbacks");
        Assert.Equal("CLASSICS FROM EVERY DECADE", throwbacks.Subtitle);
        Assert.Equal(ShelfStyle.Carousel, throwbacks.Style);
        Assert.All(throwbacks.Items, i => Assert.NotNull(i.AsPlaylist()));

        var token = PageParser.SectionsContinuation(root);
        Assert.StartsWith("q:", token);
    }

    /// <summary>Signed out, Home keeps YouTube's public shelves and leaves out any made from this machine's listening.</summary>
    [Fact]
    public void AnonymousHomeLeavesOutPersonalShelves()
    {
        var shelves = PageParser.Shelves(Fixture.Json("home"));
        Assert.Equal(shelves.Select(s => s.Title), YouTubeMusicProvider.AnonymousHome(shelves).Select(s => s.Title));

        var liked = new Playlist { Provider = ProviderId.YouTubeMusic, ProviderID = "LM", Title = "Liked Music" };
        var mix = new Playlist { Provider = ProviderId.YouTubeMusic, ProviderID = "RDTMAK5uy_x", Title = "Supermix" };
        var personal = new List<Shelf>
        {
            new("a", "Listen again", ShelfStyle.Carousel, [MediaItem.Of(mix)]),
            new("b", "Mixed for you", ShelfStyle.Hero, [MediaItem.Of(mix)]),
            new("c", "Throwbacks", ShelfStyle.Carousel, [MediaItem.Of(liked), MediaItem.Of(mix)]),
            new("d", "Only liked", ShelfStyle.Carousel, [MediaItem.Of(liked)]),
        };
        var kept = YouTubeMusicProvider.AnonymousHome(personal);
        Assert.Equal(["Throwbacks"], kept.Select(s => s.Title));
        Assert.Single(kept[0].Items);
    }

    [Fact]
    public void HomeContinuation()
    {
        var root = Fixture.Json("home_continuation");
        var shelves = PageParser.Shelves(root);
        Assert.Contains("Today's biggest hits", shelves.Select(s => s.Title));
        Assert.All(shelves, s => Assert.NotEmpty(s.Items));
        Assert.NotNull(PageParser.SectionsContinuation(root));
    }

    [Fact]
    public void Explore()
    {
        var shelves = PageParser.Shelves(Fixture.Json("explore"));
        var releases = shelves.Single(s => s.Title == "New albums & singles");
        Assert.Equal(ShelfStyle.Carousel, releases.Style);
        Assert.Contains(releases.Items, i => i.AsAlbum() != null);
        Assert.Equal("browse|FEmusic_new_releases_albums|", releases.MoreToken);

        var moods = shelves.Single(s => s.Title == "Moods & genres");
        Assert.Equal(40, moods.Items.Count);
        var chill = moods.Items[0].AsPlaylist()!;
        Assert.Equal("1", chill.Extra["category"]);
        Assert.StartsWith("category:browse|FEmusic_moods_and_genres_category|", chill.ProviderID);
        Assert.NotNull(MoreToken.Parse(chill.ProviderID["category:".Length..]));
    }

    [Fact]
    public void Charts()
    {
        var shelves = PageParser.Shelves(Fixture.Json("charts"));
        var artists = shelves.Single(s => s.Title == "Top artists");
        Assert.Equal(ShelfStyle.Artists, artists.Style);
        Assert.Equal(40, artists.Items.Count);
        Assert.Contains("subscribers", artists.Items[0].AsArtist()!.Subtitle);
        var albums = shelves.Single(s => s.Title == "Top albums");
        Assert.All(albums.Items, i => Assert.NotNull(i.AsAlbum()));
    }

    [Fact]
    public void MoodsPageExpandsToCategories()
    {
        var shelf = PageParser.ExpandedShelf(Fixture.Json("moods"), "browse|FEmusic_moods_and_genres|");
        Assert.Equal(40, shelf.Items.Count);
        Assert.All(shelf.Items, i => Assert.Equal("1", i.AsPlaylist()?.Extra["category"]));
    }
}

public class SearchParsing
{
    [Fact]
    public void All()
    {
        var r = PageParser.Search(Fixture.Json("search_all"), SearchScope.All);
        var top = r.Top.AsArtist()!;
        Assert.Equal("Daft Punk", top.Name);
        Assert.Equal("UCRr1xG_2WIDs18a6cIiCxeA", top.ProviderID);
        Assert.Equal("Daft Punk", r.Artists[0].Name);
        // Songs from the top-result card inherit the artist.
        var card = r.Tracks.Single(t => t.ProviderID == "4j064xpolDw");
        Assert.Equal("Daft Punk", card.Artists[0].Name);
        Assert.Equal(135.0, card.Duration);
        Assert.Contains(r.Albums, a => a.ProviderID == "MPREb_7ltM34kr0mH" && a.Year == 2001);
        Assert.Contains(r.Playlists, p => p.ProviderID == "RDCLAK5uy_n20FRYQXNt1p1wS55Nj2r14IouO5weaYU" && p.TrackCount == 35);
        // Songs come before music videos.
        var firstVideo = r.Tracks.ToList().FindIndex(t => t.Extra.GetValueOrDefault("musicVideoType") == "MUSIC_VIDEO_TYPE_OMV");
        if (firstVideo < 0) firstVideo = r.Tracks.Count;
        Assert.All(r.Tracks.Take(firstVideo), t => Assert.NotEqual("MUSIC_VIDEO_TYPE_OMV", t.Extra.GetValueOrDefault("musicVideoType")));
        Assert.All(r.Tracks.Skip(firstVideo), t => Assert.Equal("MUSIC_VIDEO_TYPE_OMV", t.Extra.GetValueOrDefault("musicVideoType")));
    }

    [Fact]
    public void Songs()
    {
        var r = PageParser.Search(Fixture.Json("search_songs"), SearchScope.Songs);
        Assert.Equal(20, r.Tracks.Count);
        var first = r.Tracks[0];
        Assert.Equal("Instant Crush (feat. Julian Casablancas)", first.Title);
        Assert.Equal(["Daft Punk", "Julian Casablancas"], first.Artists.Select(a => a.Name));
        Assert.Equal("UCRr1xG_2WIDs18a6cIiCxeA", first.Artists[0].Id);
        Assert.Equal(new AlbumRef("MPREb_K8qWMWVqXGi", "Random Access Memories"), first.Album);
        Assert.Equal(338.0, first.Duration);
        Assert.Equal("MUSIC_VIDEO_TYPE_ATV", first.Extra["musicVideoType"]);
    }

    [Fact]
    public void AlbumsArtistsPlaylists()
    {
        var albums = PageParser.Search(Fixture.Json("search_albums"), SearchScope.Albums).Albums;
        Assert.Equal("Random Access Memories", albums[0].Title);
        Assert.Equal(2013, albums[0].Year);
        Assert.Equal(AlbumKind.Album, albums[0].Kind);
        Assert.Equal("Daft Punk", albums[0].Artists[0].Name);

        var artists = PageParser.Search(Fixture.Json("search_artists"), SearchScope.Artists).Artists;
        Assert.Equal("Daft Punk", artists[0].Name);
        Assert.Equal("68.3M monthly audience", artists[0].Subtitle);

        var playlists = PageParser.Search(Fixture.Json("search_playlists"), SearchScope.Playlists).Playlists;
        Assert.True(playlists.Count >= 10);
        Assert.Equal("GotWub", playlists[0].Owner);
        Assert.All(playlists, p => Assert.False(p.ProviderID.StartsWith("VL", StringComparison.Ordinal)));
    }

    [Fact]
    public void Suggestions()
    {
        var s = PageParser.Suggestions(Fixture.Json("suggestions"));
        Assert.Equal("daft punk", s[0]);
        Assert.Contains("daft punk get lucky", s);
    }

    /// <summary>The direct matches under the completions: the artist first, then songs with their albums.</summary>
    [Fact]
    public void SuggestionItems()
    {
        var items = PageParser.SuggestionItems(Fixture.Json("suggestions"));
        var artist = items[0].AsArtist()!;
        Assert.Equal("Daft Punk", artist.Name);
        Assert.Equal("UCRr1xG_2WIDs18a6cIiCxeA", artist.ProviderID);
        Assert.NotNull(artist.Artwork);
        var songs = items.Select(i => i.AsTrack()).OfType<Track>().ToList();
        Assert.Equal(4, songs.Count);
        Assert.Equal("Discovery", songs[0].Album?.Title);
    }

    /// <summary>Search rows without an album take the album and artist links from the watch queue's listing.</summary>
    [Fact]
    public void LinkedTrackFillsMissingLinks()
    {
        var row = new Track { Provider = ProviderId.YouTubeMusic, ProviderID = "abc", Title = "Patient Zero", Artists = [new ArtistRef(null, "Taylor Swift")], Duration = 226.0 };
        var listing = new Track { Provider = ProviderId.YouTubeMusic, ProviderID = "abc", Title = "?", Artists = [new ArtistRef("UCx", "Taylor Swift")], Album = new AlbumRef("MPREb_1", "The Life of a Showgirl"),
            Duration = 999.0,
        };
        var filled = YouTubeMusicProvider.Filling(row, listing);
        Assert.Equal("Patient Zero", filled.Title);
        Assert.Equal("MPREb_1", filled.Album?.Id);
        Assert.Equal("UCx", filled.Artists[0].Id);
        Assert.Equal(226.0, filled.Duration);
        Assert.Null(filled.Artwork);
    }

    /// <summary>A song handed over from another device without artwork takes the listing's; its own is never replaced.</summary>
    [Fact]
    public void LinkedTrackFillsMissingArtworkOnly()
    {
        var art = Artwork.FromUrl(new Uri("https://lh3.googleusercontent.com/listing=w120-h120"));
        var listing = new Track { Provider = ProviderId.YouTubeMusic, ProviderID = "abc", Title = "?", Artwork = art };
        var bare = new Track { Provider = ProviderId.YouTubeMusic, ProviderID = "abc", Title = "One More Time" };
        Assert.Equal(art, YouTubeMusicProvider.Filling(bare, listing).Artwork);
        var own = Artwork.FromUrl(new Uri("https://lh3.googleusercontent.com/own=w120-h120"));
        Assert.Equal(own, YouTubeMusicProvider.Filling(bare with { Artwork = own }, listing).Artwork);
    }
}

public class EntityParsing
{
    [Fact]
    public void Album()
    {
        var d = PageParser.Album(Fixture.Json("album"), "MPREb_7ltM34kr0mH");
        Assert.Equal("Discovery", d.Album.Title);
        Assert.Equal(new ArtistRef("UCRr1xG_2WIDs18a6cIiCxeA", "Daft Punk"), d.Album.Artists[0]);
        Assert.Equal(2001, d.Album.Year);
        Assert.Equal(AlbumKind.Album, d.Album.Kind);
        Assert.Equal("OLAK5uy_mz6eafmqdRHSaR4IwG0ll6J6rgv0_ZpGw", d.Album.Extra["playlistId"]);
        Assert.Equal(14, d.Tracks.Count);
        Assert.Equal(Enumerable.Range(1, 14).Select(i => (int?)i), d.Tracks.Select(t => t.TrackNumber));
        Assert.Equal("One More Time", d.Tracks[0].Title);
        Assert.Equal(321.0, d.Tracks[0].Duration);
        Assert.True(d.Tracks[0].Extra.ContainsKey("setVideoId"));
        Assert.All(d.Tracks, t => Assert.True(t.Artists[0].Name == "Daft Punk" && t.Album?.Id == "MPREb_7ltM34kr0mH"));
        Assert.Contains(d.Album.Artwork!.Images, i => i.Width == 1080);
        Assert.Contains("14 songs", d.Footnote);
        Assert.StartsWith("Discovery is the second studio album", d.Summary);
        // "Releases for you" isn't "more by this artist".
        Assert.All(d.MoreByArtist!, a => Assert.Contains(a.Artists, x => x.Name == "Daft Punk"));
    }

    [Fact]
    public void Artist()
    {
        var d = PageParser.Artist(Fixture.Json("artist"), "UCRr1xG_2WIDs18a6cIiCxeA");
        Assert.Equal("Daft Punk", d.Artist.Name);
        Assert.Equal("68.3M monthly audience", d.Artist.Subtitle);
        Assert.Equal("UC_kRDKYrUlrbtrSiyu5Tflg", d.Artist.Extra["channelId"]);
        Assert.StartsWith("RDEM", d.RadioSeed);
        Assert.False(d.IsFollowed);
        Assert.Equal(5, d.TopTracks.Count);
        Assert.Equal(10, d.Albums.Count);
        Assert.Contains(d.Albums, a => a.Title == "Discovery" && a.Artists[0].Name == "Daft Punk");
        Assert.Equal(10, d.Singles.Count);
        Assert.True(d.Playlists.Count >= 10);
        Assert.Equal(10, d.Related.Count);
        Assert.StartsWith("Daft Punk were a French", d.Bio);
    }

    [Fact]
    public void PlaylistWithContinuation()
    {
        var d = PageParser.Playlist(Fixture.Json("playlist"), "RDCLAK5uy_mkXiaMATud8GJQ3aX7f0nCeCqvehA9wTQ");
        Assert.Equal("Dance Party Hits", d.Playlist.Title);
        Assert.Equal("YouTube Music", d.Playlist.Owner);
        Assert.Equal(119, d.Playlist.TrackCount);
        Assert.False(d.Playlist.IsEditable);
        Assert.Equal(100, d.Tracks.Count);
        Assert.All(d.Tracks, t => Assert.True(t.Extra.ContainsKey("setVideoId")));
        Assert.Equal(["Calvin Harris", "Rihanna"], d.Tracks[0].Artists.Select(a => a.Name));
        Assert.StartsWith("b:", d.Continuation);

        var (items, next) = PageParser.ContinuationItems(Fixture.Json("playlist_continuation"));
        Assert.Equal(19, items.Count);
        Assert.All(items, i => Assert.NotNull(i.AsTrack()));
        Assert.Null(next);
    }

    /// <summary>A header without "119 songs": the first page's 100 songs aren't passed off as the total while a later page exists.</summary>
    [Fact]
    public void PlaylistWithoutTotal()
    {
        static void Strip(JsonNode? node)
        {
            switch (node)
            {
                case JsonObject o:
                    o.Remove("secondSubtitle");
                    foreach (var (_, v) in o) Strip(v);
                    break;
                case JsonArray a:
                    foreach (var v in a) Strip(v);
                    break;
            }
        }
        var root = Fixture.Json("playlist");
        Strip(root);
        var d = PageParser.Playlist(root, "RDCLAK5uy_mkXiaMATud8GJQ3aX7f0nCeCqvehA9wTQ");
        Assert.Equal(100, d.Tracks.Count);
        Assert.NotNull(d.Continuation);
        Assert.Null(d.Playlist.TrackCount);
    }

    [Fact]
    public void WatchNext()
    {
        var next = PageParser.ParseWatchNext(Fixture.Json("next"));
        Assert.Equal(50, next.Tracks.Count);
        Assert.Equal("wU26xVT_vBU", next.Tracks[0].ProviderID);
        Assert.Equal("Daft Punk", next.Tracks[0].Artists[0].Name);
        Assert.Equal(321.0, next.Tracks[0].Duration);
        Assert.Equal("MPLYt_uWQeJO6Z53u-2", next.LyricsBrowseId);
        Assert.Equal("INDIFFERENT", next.LikeStatus);
        Assert.NotNull(next.Continuation);
    }

    [Fact]
    public void TimedLyrics()
    {
        var lyrics = PageParser.Lyrics(Fixture.Json("lyrics_android"))!;
        Assert.True(lyrics.IsSynced);
        Assert.Equal("Source: LyricFind", lyrics.Source);
        var first = lyrics.Lines.First(l => l.Text.Length > 0);
        Assert.Equal("One more time", first.Text);
        Assert.Equal(30.35, first.Time);
        var times = lyrics.Lines.Select(l => l.Time).OfType<double>().ToList();
        Assert.Equal(times.Order(), times);
    }

    [Fact]
    public void PlainLyrics()
    {
        var lyrics = PageParser.Lyrics(Fixture.Json("lyrics"))!;
        Assert.False(lyrics.IsSynced);
        Assert.Equal("One more time", lyrics.Lines[0].Text);
        Assert.True(lyrics.Lines.Count > 50);
        Assert.Equal("Source: LyricFind", lyrics.Source);
    }
}

public class StreamParsing
{
    [Fact]
    public void PlayerResponse()
    {
        var info = new PlayerInfo(Fixture.Json("player_visionos"));
        Assert.Equal("OK", info.Status);
        var best = info.BestDirectAudio!;
        Assert.Equal(140, best.Itag);
        Assert.StartsWith("audio/mp4", best.MimeType);
        Assert.NotNull(best.LoudnessDb);
        Assert.NotNull(info.HlsManifestUrl);
        Assert.Equal(21540, info.ExpiresIn);
        // WebM/Opus formats exist but are left out.
        Assert.Contains(info.Formats, f => f.MimeType.StartsWith("audio/webm", StringComparison.Ordinal));
    }

    [Fact]
    public void HlsAudioRendition()
    {
        var r = YouTubeStreamResolver.AudioRenditionFromMaster(Fixture.Text("hls_master.m3u8"))!;
        Assert.Equal(234, r.Itag);
        Assert.Contains("/itag/234/", r.Url.OriginalString);
        // YT-EXT-ABSOLUTE-LOUDNESS=-12.350 LUFS → +1.65 dB relative to YouTube's -14 LUFS reference.
        Assert.InRange(r.LoudnessDb!.Value, 1.649, 1.651);
    }

    [Fact]
    public void HlsAttributes()
    {
        var attrs = YouTubeStreamResolver.ParseAttributes("URI=\"https://x/a,b\",TYPE=AUDIO,GROUP-ID=\"234\",YT-EXT-ABSOLUTE-LOUDNESS=-13.010");
        Assert.Equal("https://x/a,b", attrs["URI"]);
        Assert.Equal("AUDIO", attrs["TYPE"]);
        Assert.Equal("234", attrs["GROUP-ID"]);
        Assert.Equal("-13.010", attrs["YT-EXT-ABSOLUTE-LOUDNESS"]);
    }

    [Fact]
    public void ServiceWorkerData()
    {
        var text = Fixture.Text("sw_js_data.txt");
        Assert.Equal("CgtGSVhUVVJFX1ZJU0lUT1IoAQ==", InnerTubeClient.ServiceWorkerVisitor(text));
        Assert.Equal("1.20261027.10.00", InnerTubeClient.FirstMatch(InnerTubeClient.VersionRegex(), text));
    }
}

public class Helpers
{
    [Fact]
    public void Durations()
    {
        Assert.Equal(227.0, YTText.Duration("3:47"));
        Assert.Equal(3723.0, YTText.Duration("1:02:03"));
        Assert.Equal(601.0, YTText.Duration("10:01"));
        Assert.Null(YTText.Duration("2013"));
        Assert.Null(YTText.Duration("1.2B plays"));
    }

    [Fact]
    public void ArtworkResizing()
    {
        var images = YTArtwork.Resizable(new Uri("https://lh3.googleusercontent.com/abc=w60-h60-l90-rj"))!;
        Assert.Equal(YTArtwork.SquareSizes.Select(s => (int?)s), images.Select(i => i.Width));
        Assert.Equal("https://lh3.googleusercontent.com/abc=w1080-h1080-l90-rj", images[^1].Url.OriginalString);
        var video = YTArtwork.VideoThumbnails(new Uri("https://i.ytimg.com/vi/dQw4w9WgXcQ/sddefault.jpg?sqp=x"))!;
        Assert.Equal("https://i.ytimg.com/vi/dQw4w9WgXcQ/sddefault.jpg", video[^1].Url.OriginalString);
    }

    [Fact]
    public void PlaylistTrackCount()
    {
        Assert.Equal(1000, PageParser.TrackCount("29K views • 1,000 songs • 3+ hours"));
        Assert.Equal(119, PageParser.TrackCount("119 songs • 6+ hours"));
        Assert.Null(PageParser.TrackCount("2026 • 12 views"));
    }

    [Fact]
    public void MoreTokenRoundTrip()
    {
        var token = new MoreToken("FEmusic_moods_and_genres_category", "ggMPOg1uX1JOQWZFeDByc2Jm");
        Assert.Equal(token, MoreToken.Parse(token.Encoded));
        Assert.Equal(new MoreToken("FEmusic_new_releases_albums", null), MoreToken.Parse("browse|FEmusic_new_releases_albums|"));
        Assert.Null(MoreToken.Parse("garbage"));
    }

    [Fact]
    public void ArtistNameSplitting()
    {
        Assert.Equal(["Calvin Harris", "Rihanna"], ItemParser.ArtistNames("Calvin Harris & Rihanna").Select(a => a.Name));
        Assert.Equal(["Unjaps", "404NR", "June Boii"], ItemParser.ArtistNames("Unjaps, 404NR & June Boii").Select(a => a.Name));
    }

    [Fact]
    public void SearchParamsPerScope()
    {
        Assert.Null(InnerTubeClient.SearchParams(SearchScope.All));
        Assert.Equal(4, Enum.GetValues<SearchScope>().Select(InnerTubeClient.SearchParams).OfType<string>().Distinct().Count());
    }

    /// <summary>Query values are percent-encoded exactly like Foundation's URLComponents (checked on macOS 27).</summary>
    [Fact]
    public void QueryEncodingMatchesUrlComponents()
    {
        Assert.Equal("4qmF+sg/K%3DAb%253D%253D%26x?y%20z%23h:@!$'()*,;~", InnerTubeClient.QueryEscape("4qmF+sg/K=Ab%3D%3D&x?y z#h:@!$'()*,;~"));
    }
}
