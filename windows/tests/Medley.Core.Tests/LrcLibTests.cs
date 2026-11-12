using System.Text;
using System.Web;
using Medley.Core.Mock;
using Medley.Core.Support;
using static Medley.Core.Tests.T;

namespace Medley.Core.Tests;

// Port of Tests/SpotifyKitTests/LyricsTests.swift.

public class LrcParsingTests
{
    [Fact]
    public void ParsesTimestampFormats()
    {
        var lines = LrcLibClient.ParseLrc(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "sample.lrc")));
        Assert.Equal(
            ["Like the legend of the phoenix, huh", "All ends with beginnings", "Colon hundredths form", "No fraction", "",
             "We're up all night to get lucky", "We're up all night to get lucky"],
            lines.Select(l => l.Text));
        var times = lines.Select(l => l.Time).OfType<double>().ToList();
        Assert.Equal(lines.Count, times.Count);
        Assert.Equal(31.48, times[0], 3);
        Assert.Equal(40.12, times[2], 3); // [00:40:12]
        Assert.Equal(45, times[3]); // [00:45]
        Assert.Equal(62.5, times[5], 3); // [01:02.5]
        Assert.Equal(130.25, times[6], 3); // [02:10.250], second stamp on the same line
        Assert.Equal(times.Order(), times);
    }

    [Fact]
    public void AppliesOffset()
    {
        var lines = LrcLibClient.ParseLrc("[offset:+500]\n[00:10.00]a\n[00:00.20]b");
        Assert.Equal(["b", "a"], lines.Select(l => l.Text));
        Assert.Equal([0, 9.5], lines.Select(l => l.Time)); // shifted earlier, clamped at 0
    }

    [Fact]
    public void IgnoresMetadataAndJunk() => Assert.Empty(LrcLibClient.ParseLrc("[ar:Someone]\n[ti:Song]\nplain text\n[99:99.99] bad"));

    [Fact]
    public void LineIndexFollowsTime()
    {
        var lyrics = new Lyrics(LrcLibClient.ParseLrc("[00:01.00]a\n[00:05.00]b\n[00:09.00]c"));
        Assert.Null(lyrics.LineIndex(0.5));
        Assert.Equal(0, lyrics.LineIndex(1));
        Assert.Equal(1, lyrics.LineIndex(8.99));
        Assert.Equal(2, lyrics.LineIndex(100));
    }
}

public class LrcLibClientTests
{
    private static byte[] SearchFixture() => Encoding.UTF8.GetBytes(Fixture("lrclib-search"));

    [Fact]
    public async Task GetThenSearchFallback()
    {
        var urls = new List<Uri>();
        var client = new LrcLibClient(fetch: (request, _) =>
        {
            urls.Add(request.RequestUri!);
            Assert.StartsWith("OpenMusic/", request.Headers.UserAgent.ToString());
            return Task.FromResult(request.RequestUri!.AbsolutePath == "/api/get"
                ? (404, Encoding.UTF8.GetBytes("""{"code":404,"name":"TrackNotFound"}"""))
                : (200, SearchFixture()));
        });
        var lyrics = await client.LyricsAsync("Get Lucky", "Daft Punk", "Random Access Memories", 369.6);
        Assert.NotNull(lyrics);
        Assert.True(lyrics!.IsSynced);
        Assert.Equal("LRCLIB", lyrics.Source);
        Assert.Equal("Like the legend of the phoenix, huh", lyrics.Lines[0].Text); // record 103: close duration and synced
        Assert.Equal(["/api/get", "/api/search"], urls.Select(u => u.AbsolutePath));
        var get = HttpUtility.ParseQueryString(urls[0].Query);
        Assert.Equal("370", get["duration"]);
        Assert.Equal("Random Access Memories", get["album_name"]);
    }

    [Fact]
    public async Task SkipsGetWithoutAlbumOrDuration()
    {
        var urls = new List<Uri>();
        var client = new LrcLibClient(fetch: (request, _) =>
        {
            urls.Add(request.RequestUri!);
            return Task.FromResult((200, SearchFixture()));
        });
        await client.LyricsAsync("Get Lucky", "Daft Punk");
        Assert.Equal(["/api/search"], urls.Select(u => u.AbsolutePath));
    }

    [Fact]
    public void BestMatchPrefersCloseDurationThenSynced()
    {
        var records = MedleyJson.Deserialize(SearchFixture(), MedleyJsonContext.Default.ListRecord)!;
        Assert.Equal(103, LrcLibClient.BestMatch(records, 369)?.Id);
        Assert.Equal(101, LrcLibClient.BestMatch(records, 248)?.Id);
        Assert.False(string.IsNullOrEmpty(LrcLibClient.BestMatch(records, null)?.SyncedLyrics));
        Assert.Null(LrcLibClient.BestMatch(records, 30)); // nothing within 10 s
    }

    [Fact]
    public void PlainAndInstrumental()
    {
        var plain = new LrcLibClient.Record { Id = 1, PlainLyrics = "one\ntwo" };
        Assert.Equal([new LyricLine(null, "one"), new LyricLine(null, "two")], LrcLibClient.LyricsFrom(plain)!.Lines);
        Assert.False(LrcLibClient.LyricsFrom(plain)!.IsSynced);
        Assert.Equal("Instrumental", LrcLibClient.LyricsFrom(new LrcLibClient.Record { Id = 2, Instrumental = true })!.Lines[0].Text);
        Assert.Null(LrcLibClient.LyricsFrom(new LrcLibClient.Record { Id = 3 }));
    }

    [Fact]
    public async Task RateLimitIsReported()
    {
        var client = new LrcLibClient(fetch: (_, _) => Task.FromResult((429, Array.Empty<byte>())));
        var e = await Assert.ThrowsAsync<ProviderException>(() => client.LyricsAsync("x", "y"));
        Assert.Equal(ProviderErrorKind.RateLimited, e.Kind);
    }
}

public class MockProviderTests
{
    [Fact]
    public void DemoHomeHasShelvesAndNowPlaying() => OnMain(async () =>
    {
        var provider = new MockProvider(ProviderId.YouTubeMusic, dataset: MockDataset.Demo);
        var home = await provider.HomeAsync();
        Assert.Equal(["Quick picks", "Listen again", "Your mixes", "Top songs", "Artists you listen to"], home.Select(s => s.Title));
        Assert.All(home, s => Assert.NotEmpty(s.Items));
        var now = provider.DemoNowPlaying!;
        Assert.Equal("the cure", now.Tracks[now.Index].Title);
        var album = await provider.AlbumAsync(now.Album.ProviderID);
        Assert.StartsWith("June 12, 2026\n13 songs, ", album.Footnote);
        var lyrics = await provider.LyricsAsync(now.Tracks[now.Index]);
        Assert.True(lyrics!.IsSynced);
    });

    [Fact]
    public void SearchFindsArtistsAlbumsAndSongs() => OnMain(async () =>
    {
        var provider = new MockProvider(ProviderId.YouTubeMusic, dataset: MockDataset.Demo);
        var results = await provider.SearchAsync("olivia", SearchScope.All);
        Assert.IsType<MediaItem.ArtistItem>(results.Top);
        Assert.NotEmpty(results.Tracks);
        Assert.NotEmpty(results.Albums);
        var suggestions = await ((IMusicProvider)provider).RichSearchSuggestionsAsync("oli");
        Assert.NotEmpty(suggestions.Queries);
    });

    [Fact]
    public void PlaylistPagesAndEdits() => OnMain(async () =>
    {
        var provider = new MockProvider(ProviderId.Spotify);
        var playlist = provider.Catalog.Playlists.First(p => (p.TrackCount ?? 0) > 25);
        var detail = await provider.PlaylistAsync(playlist.ProviderID);
        Assert.Equal(25, detail.Tracks.Count);
        Assert.NotNull(detail.Continuation);
        var page = await provider.PlaylistTracksAsync(detail.Continuation!);
        Assert.NotEmpty(page.Items);
        var mine = provider.Catalog.Playlists.First(p => p.IsEditable);
        var before = provider.Catalog.PlaylistTracks[mine.ProviderID].Count;
        await provider.AddAsync(provider.SampleTracks(2), mine.ProviderID);
        Assert.Equal(before + 2, provider.Catalog.Playlist(mine.ProviderID)!.TrackCount);
        await provider.SignOutAsync();
        await Assert.ThrowsAsync<ProviderException>(() => provider.LibraryAsync(LibraryKind.Songs, null));
    });

    [Fact]
    public void ArtworkRendersEveryKind()
    {
        foreach (var url in new[] { "medley-mock://art/yt-al0", "medley-mock://portrait/yt-ar0", "medley-mock://liked/spotify", "medley-mock://avatar/RC", "medley-mock://demo/missing-key" })
        {
            var pixels = MockArtwork.Render(new Uri(url), 64);
            Assert.Equal(64 * 64 * 4, pixels.Length);
            Assert.Contains(pixels, b => b != 0);
            Assert.Equal(pixels, MockArtwork.Render(new Uri(url), 64)); // deterministic
        }
    }
}
