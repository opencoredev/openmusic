using Medley.Core;
using Medley.Core.Support;

namespace Medley.Core.Tests;

public class BrowseDiskCacheTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "medley-browse-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch (DirectoryNotFoundException) { }
    }

    private static readonly ProviderSession Anon = new(1, SessionIdentity.SignedOut);
    private static readonly ProviderSession Alice = new(2, SessionIdentity.ForAccount("datasync:alice"));
    private static readonly ProviderSession Bob = new(3, SessionIdentity.ForAccount("datasync:bob"));

    private static List<Shelf> Shelves(string title)
    {
        var track = new Track { ProviderID = "abc", Provider = ProviderId.YouTubeMusic, Title = title, Duration = 200 };
        var album = new Album { ProviderID = "MPRE1", Provider = ProviderId.YouTubeMusic, Title = "Discovery" };
        return
        [
            new Shelf("quick", "Quick picks", ShelfStyle.TrackList, [MediaItem.Of(track)]) { MoreToken = "more" },
            new Shelf("albums", "Albums", ShelfStyle.Carousel, [MediaItem.Of(album)]) { Subtitle = "For you" },
        ];
    }

    [Fact]
    public void RoundTripsShelvesPerAccount()
    {
        var cache = new BrowseDiskCache(_dir);
        Assert.True(cache.Save("home", ProviderId.YouTubeMusic, Alice, Shelves("A")));
        Assert.True(cache.Save("home", ProviderId.YouTubeMusic, Anon, Shelves("anon")));
        var a = cache.Load("home", ProviderId.YouTubeMusic, Alice)!;
        Assert.Equal("A", ((MediaItem.TrackItem)a[0].Items[0]).Track.Title);
        Assert.Equal("more", a[0].MoreToken);
        Assert.Equal("For you", a[1].Subtitle);
        Assert.IsType<MediaItem.AlbumItem>(a[1].Items[0]);
        Assert.Null(cache.Load("home", ProviderId.YouTubeMusic, Bob));
        Assert.Equal("anon", ((MediaItem.TrackItem)cache.Load("home", ProviderId.YouTubeMusic, Anon)![0].Items[0]).Track.Title);
        Assert.Null(cache.Load("new", ProviderId.YouTubeMusic, Alice));
    }

    [Fact]
    public void NeverCachesChangingOrUnidentifiedSessions()
    {
        var cache = new BrowseDiskCache(_dir);
        Assert.False(cache.Save("home", ProviderId.YouTubeMusic, new ProviderSession(4, SessionIdentity.Changing), Shelves("x")));
        Assert.False(cache.Save("home", ProviderId.YouTubeMusic, new ProviderSession(5, SessionIdentity.ForAccount(null)), Shelves("x")));
        Assert.False(Directory.Exists(_dir) && Directory.EnumerateFiles(_dir).Any());
    }

    [Fact]
    public void RetainDeletesOtherAccountsButKeepsSignedOut()
    {
        var cache = new BrowseDiskCache(_dir);
        cache.Save("home", ProviderId.YouTubeMusic, Alice, Shelves("A"));
        cache.Save("new", ProviderId.YouTubeMusic, Alice, Shelves("A"));
        cache.Save("home", ProviderId.YouTubeMusic, Bob, Shelves("B"));
        cache.Save("home", ProviderId.YouTubeMusic, Anon, Shelves("anon"));
        cache.Retain(ProviderId.YouTubeMusic, Bob);
        Assert.Null(cache.Load("home", ProviderId.YouTubeMusic, Alice));
        Assert.Null(cache.Load("new", ProviderId.YouTubeMusic, Alice));
        Assert.NotNull(cache.Load("home", ProviderId.YouTubeMusic, Bob));
        Assert.NotNull(cache.Load("home", ProviderId.YouTubeMusic, Anon));
        cache.Retain(ProviderId.YouTubeMusic, Anon);
        Assert.Null(cache.Load("home", ProviderId.YouTubeMusic, Bob));
        Assert.Single(Directory.EnumerateFiles(_dir));
    }

    [Fact]
    public void CorruptOrOldFilesCountAsMissing()
    {
        var clock = new ManualTime(DateTimeOffset.Parse("2026-11-01T00:00:00Z", System.Globalization.CultureInfo.InvariantCulture));
        var cache = new BrowseDiskCache(_dir, clock);
        cache.Save("home", ProviderId.YouTubeMusic, Anon, Shelves("anon"));
        clock.Now += BrowseDiskCache.MaxAge + TimeSpan.FromMinutes(1);
        Assert.Null(cache.Load("home", ProviderId.YouTubeMusic, Anon));
        Assert.Empty(Directory.EnumerateFiles(_dir));
        cache.Save("home", ProviderId.YouTubeMusic, Anon, Shelves("anon"));
        File.WriteAllText(Directory.EnumerateFiles(_dir).Single(), "{ not json");
        Assert.Null(cache.Load("home", ProviderId.YouTubeMusic, Anon));
    }

    private sealed class ManualTime(DateTimeOffset now) : TimeProvider
    {
        public DateTimeOffset Now { get; set; } = now;
        public override DateTimeOffset GetUtcNow() => Now;
    }
}

public class PlaylistPagerTests
{
    private static Track T(string id) => new() { ProviderID = id, Provider = ProviderId.YouTubeMusic, Title = id };

    [Fact]
    public async Task ListsEachSongOnceAcrossPagesAndCountsCopies()
    {
        // A generated mix (RDCLAK…) repeats songs on the first page and on later ones.
        var pager = new PlaylistPager([T("a"), T("b"), T("a")], "p2", knownTotal: 6);
        Assert.Equal(["a", "b"], pager.Tracks.Select(t => t.ProviderID));
        var added = await pager.LoadNextAsync((token, _) => Task.FromResult(new Page<Track>([T("b"), T("c"), T("d")]) { Continuation = null }));
        Assert.Equal(2, added);
        Assert.Equal(["a", "b", "c", "d"], pager.Tracks.Select(t => t.ProviderID));
        Assert.Equal(2, pager.Copies[T("a").Id]);
        Assert.Equal(2, pager.Copies[T("b").Id]);
        Assert.Equal(6, pager.EntriesSeen);
        Assert.True(pager.IsComplete);
    }

    [Fact]
    public async Task RepeatedTokenEndsTheList()
    {
        var pager = new PlaylistPager([T("a")], "p2", knownTotal: null);
        await pager.LoadNextAsync((_, _) => Task.FromResult(new Page<Track>([T("b")]) { Continuation = "p2" }));
        Assert.Null(pager.Continuation);
        Assert.True(pager.StoppedOnRepeatedToken);
        Assert.False(pager.IsComplete);
        Assert.Equal(0, await pager.LoadNextAsync((_, _) => throw new InvalidOperationException("never asked")));
    }

    [Fact]
    public async Task EagerOnlyForShortKnownPlaylistsWithinBudget()
    {
        Assert.False(new PlaylistPager([T("a")], "p", knownTotal: 500).WantsEagerPage);
        Assert.False(new PlaylistPager([T("a")], "p", knownTotal: null).WantsEagerPage);
        var pager = new PlaylistPager([T("a")], "p0", knownTotal: 150);
        var n = 0;
        while (pager.WantsEagerPage)
        {
            var page = n;
            await pager.LoadNextAsync((_, _) => Task.FromResult(new Page<Track>([T($"s{page}")]) { Continuation = $"p{page + 1}" }), eager: true);
            n++;
        }
        Assert.Equal(PlaylistPager.EagerPageBudget, n);
        Assert.True(pager.HasMore);
    }

    [Fact]
    public async Task FailureStopsUntilClearedAndOvertakenRequestPublishesNothing()
    {
        var pager = new PlaylistPager([T("a")], "p2", knownTotal: null);
        await pager.LoadNextAsync((_, _) => throw new HttpRequestException("offline"));
        Assert.Equal("offline", pager.Error);
        Assert.False(pager.HasMore);
        pager.ClearError();
        var slow = new TaskCompletionSource<Page<Track>>();
        var first = pager.LoadNextAsync((_, _) => slow.Task);
        var second = await pager.LoadNextAsync((_, _) => Task.FromResult(new Page<Track>([T("c")])));
        slow.SetResult(new Page<Track>([T("b")]) { Continuation = "p3" });
        Assert.Equal(0, await first);
        Assert.Equal(1, second);
        Assert.Equal(["a", "c"], pager.Tracks.Select(t => t.ProviderID));
        Assert.Null(pager.Continuation);
    }
}
