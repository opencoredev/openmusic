using System.ComponentModel;
using System.Net;
using System.Text;
using OpenMusic.Core;
using OpenMusic.Core.Threading;
using OpenMusic.Providers.YouTube.Json;
using OpenMusic.Providers.YouTube.Parsing;
using Xunit;

namespace OpenMusic.Providers.YouTube.Tests;

/// <summary>Responses recorded live with openmusic-probe on 2026-11-07 (tools/record-fixtures.sh), signed out, scrubbed.</summary>
public class LiveFixtureTests
{
    [Fact]
    public void Home()
    {
        var root = Fixture.Json("live_home");
        var shelves = PageParser.Shelves(root);
        var quick = shelves.Single(s => s.Title == "Quick picks");
        Assert.Equal(ShelfStyle.TrackList, quick.Style);
        Assert.Equal(20, quick.Items.Count);
        Assert.All(quick.Items, i => Assert.Equal(11, i.AsTrack()!.ProviderID.Length));
        Assert.Contains(shelves, s => s.MoreToken?.StartsWith("browse|FEmusic_new_releases_albums|", StringComparison.Ordinal) == true);
        Assert.StartsWith("q:", PageParser.SectionsContinuation(root));
    }

    [Fact]
    public void Explore()
    {
        var shelves = PageParser.Shelves(Fixture.Json("live_explore"));
        Assert.Contains(shelves, s => s.Items.Any(i => i.AsAlbum() != null));
        Assert.All(shelves, s => Assert.NotEmpty(s.Items));
    }

    [Fact]
    public void SearchDaftPunk()
    {
        var r = PageParser.Search(Fixture.Json("live_search_all"), SearchScope.All);
        Assert.Equal("Daft Punk", r.Top.AsArtist()?.Name);
        Assert.Equal("UCRr1xG_2WIDs18a6cIiCxeA", r.Top.AsArtist()?.ProviderID);
        Assert.Contains(r.Albums, a => a.Title == "Discovery" && a.ProviderID == "MPREb_7ltM34kr0mH" && a.Year == 2001);
        Assert.True(r.Tracks.Count >= 5);
        Assert.All(r.Tracks, t => Assert.NotEmpty(t.Artists));
    }

    [Fact]
    public void AlbumDiscovery()
    {
        var d = PageParser.Album(Fixture.Json("live_album"), "MPREb_7ltM34kr0mH");
        Assert.Equal("Discovery", d.Album.Title);
        Assert.Equal("Daft Punk", d.Album.ArtistLine);
        Assert.Equal(14, d.Tracks.Count);
        Assert.Equal("One More Time", d.Tracks[0].Title);
        Assert.Equal("FGBhQbmPwH8", d.Tracks[0].ProviderID);
        Assert.Equal("OLAK5uy_mz6eafmqdRHSaR4IwG0ll6J6rgv0_ZpGw", d.Album.Extra["playlistId"]);
    }

    [Fact]
    public void ArtistDaftPunk()
    {
        var d = PageParser.Artist(Fixture.Json("live_artist"), "UCRr1xG_2WIDs18a6cIiCxeA");
        Assert.Equal("Daft Punk", d.Artist.Name);
        Assert.StartsWith("RDEM", d.RadioSeed);
        Assert.NotEmpty(d.TopTracks);
        Assert.Contains(d.Albums, a => a.Title == "Discovery");
        Assert.NotEmpty(d.Related);
    }

    /// <summary>A 493-song user playlist: 100 on the first page, the header's total, then the next page and its token.</summary>
    [Fact]
    public void LongPlaylistAndContinuation()
    {
        var d = PageParser.Playlist(Fixture.Json("live_playlist"), "PLgVLQgm4lkANkwLnIYZiwf6o2jKIc5Th3");
        Assert.Equal(493, d.Playlist.TrackCount);
        Assert.Equal(100, d.Tracks.Count);
        Assert.StartsWith("b:", d.Continuation);
        var (items, next) = PageParser.ContinuationItems(Fixture.Json("live_playlist_continuation"));
        Assert.Equal(100, items.Count);
        Assert.StartsWith("b:", next);
        Assert.Empty(items.Select(i => i.AsTrack()!.ProviderID).Intersect(d.Tracks.Select(t => t.ProviderID)));
    }

    [Fact]
    public void RadioQueue()
    {
        var next = PageParser.ParseWatchNext(Fixture.Json("live_next"));
        Assert.True(next.Tracks.Count >= 20);
        Assert.Equal("kOn-HdEg6AQ", next.Tracks[0].ProviderID);
        Assert.StartsWith("MPLY", next.LyricsBrowseId);
    }

    [Fact]
    public void TimedAndUntimedAndroidLyrics()
    {
        var timed = PageParser.Lyrics(Fixture.Json("live_lyrics_timed"))!;
        Assert.True(timed.IsSynced);
        // YouTube currently sends "One More Time" without timings: read as plain lines, so LRCLIB gets asked.
        var untimed = PageParser.Lyrics(Fixture.Json("live_lyrics_untimed"))!;
        Assert.False(untimed.IsSynced);
        Assert.Equal("One more time", untimed.Lines[0].Text);
    }
}

/// <summary>YouTube's lyrics first; LRCLIB when they're missing or unsynced; an outage is an error, not "no lyrics".</summary>
public class LyricsFallbackTests
{
    const string Lrc = "[00:30.35]One more time\n[00:45.81]One more time";

    static YouTubeMusicProvider Make(string androidFixture, Func<Uri, (int, byte[])> lrclib, bool youtubeDown = false) => new(new YouTubeMusicProviderOptions
    {
        Handler = new FakeHandler(r =>
        {
            if (r.Url.AbsolutePath == "/sw.js_data") return FakeHandler.ServiceWorker();
            if (youtubeDown) return FakeHandler.Status(HttpStatusCode.ServiceUnavailable);
            if (r.Url.AbsolutePath == "/youtubei/v1/next") return FakeHandler.Json(Fixture.Text("next.json"));
            return r.ClientName == "ANDROID_MUSIC" ? FakeHandler.Json(Fixture.Text(androidFixture)) : FakeHandler.Json(Fixture.Text("lyrics.json"));
        }),
        LrcLib = new LrcLibClient(fetch: (request, _) => Task.FromResult(lrclib(request.RequestUri!))),
    });

    static readonly Track OneMoreTime = new()
    {
        ProviderID = "FGBhQbmPwH8", Provider = ProviderId.YouTubeMusic, Title = "One More Time", Artists = [new ArtistRef(null, "Daft Punk")],
        Album = new AlbumRef("MPREb_7ltM34kr0mH", "Discovery"), Duration = 320,
    };

    static (int, byte[]) Found(Uri url) => url.AbsolutePath == "/api/get"
        ? (200, Encoding.UTF8.GetBytes($"{{\"id\":1,\"duration\":320,\"syncedLyrics\":{System.Text.Json.JsonSerializer.Serialize(Lrc)}}}"))
        : (404, []);

    [Fact]
    public async Task TimedYouTubeLyricsWinWithoutAskingLrclib()
    {
        var asked = 0;
        using var p = Make("lyrics_android.json", u => { asked++; return Found(u); });
        var lyrics = (await p.LyricsAsync(OneMoreTime))!;
        Assert.True(lyrics.IsSynced);
        Assert.Equal("Source: LyricFind", lyrics.Source);
        Assert.Equal(0, asked);
    }

    [Fact]
    public async Task UntimedYouTubeLyricsAskLrclib()
    {
        using var p = Make("live_lyrics_untimed.json", Found);
        var lyrics = (await p.LyricsAsync(OneMoreTime))!;
        Assert.True(lyrics.IsSynced);
        Assert.Equal(LrcLibClient.Source, lyrics.Source);
        Assert.Equal(30.35, lyrics.Lines[0].Time);
    }

    [Fact]
    public async Task UntimedLyricsStayWhenLrclibHasNothing()
    {
        using var p = Make("live_lyrics_untimed.json", _ => (404, []));
        var lyrics = (await p.LyricsAsync(OneMoreTime))!;
        Assert.False(lyrics.IsSynced);
        Assert.StartsWith("Source:", lyrics.Source);
    }

    [Fact]
    public async Task BothDownThrowsInsteadOfNoLyrics()
    {
        using var p = Make("lyrics_android.json", _ => (503, []), youtubeDown: true);
        await Assert.ThrowsAsync<ProviderException>(() => p.LyricsAsync(OneMoreTime));
    }
}

/// <summary>Core's threading rule: AuthStatus changes are raised on the UI thread (the provider's context).</summary>
public class PropertyChangedTests
{
    [Fact]
    public void ChangesArriveOnTheProvidersContext()
    {
        MainThreadContext.Run(async () =>
        {
            var uiThread = Environment.CurrentManagedThreadId;
            using var provider = Make.Provider(async (_, _) =>
            {
                await Task.Delay(10).ConfigureAwait(false); // the check finishes on a pool thread
                return new AccountInfo("Ada");
            });
            var seen = new List<(string?, int)>();
            provider.PropertyChanged += (_, e) => seen.Add((e.PropertyName, Environment.CurrentManagedThreadId));
            await Task.Run(() => provider.SignInAsync(Make.Creds(), persist: false));
            await Task.Delay(20);
            Assert.Contains(seen, s => s.Item1 == nameof(IMusicProvider.AuthStatus));
            Assert.All(seen, s => Assert.Equal(uiThread, s.Item2));
            Assert.True(provider.IsSignedIn);
        });
    }
}
