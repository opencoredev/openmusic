using System.Globalization;
using System.Reflection;
using System.Text.Json.Serialization;
using OpenMusic.Core.Support;

namespace OpenMusic.Core.Mock;

// The demo dataset: real, current chart albums, played by a made-up listener, for screenshots. Titles, track lengths
// and release dates come from DemoCatalogData.json, which scripts/windows-fixtures/generate.sh writes from the Swift
// DemoCatalogData.swift. Cover art is downloaded at run time by scripts/demo-art.sh (MockArtwork.DemoDirectory), with
// procedural covers when it's missing. Lyrics are the mock layer's own placeholder lines. Port of DemoCatalog.swift.

internal sealed record DemoSongSource(
    [property: JsonPropertyName("title")] string Title,
    [property: JsonPropertyName("seconds")] int Seconds,
    [property: JsonPropertyName("explicit")] bool Explicit,
    [property: JsonPropertyName("artists")] List<string>? Artists);

internal sealed record DemoAlbumSource(
    [property: JsonPropertyName("key")] string Key,
    [property: JsonPropertyName("service")] ProviderId Service,
    [property: JsonPropertyName("title")] string Title,
    [property: JsonPropertyName("artists")] List<string> Artists,
    [property: JsonPropertyName("released")] string Released,
    [property: JsonPropertyName("kind")] AlbumKind Kind,
    [property: JsonPropertyName("genre")] string Genre,
    [property: JsonPropertyName("copyright")] string Copyright,
    [property: JsonPropertyName("tracks")] List<DemoSongSource> Tracks);

internal sealed record DemoCatalogSource(
    [property: JsonPropertyName("albums")] List<DemoAlbumSource> Albums,
    [property: JsonPropertyName("artistPhotos")] Dictionary<string, string> ArtistPhotos)
{
    private static readonly Lazy<DemoCatalogSource> Shared = new(() =>
    {
        using var stream = typeof(DemoCatalogSource).Assembly.GetManifestResourceStream("OpenMusic.Core.Mock.DemoCatalogData.json")
            ?? throw new InvalidOperationException("DemoCatalogData.json is missing");
        return System.Text.Json.JsonSerializer.Deserialize(stream, DemoJsonContext.Default.DemoCatalogSource)!;
    });

    public static DemoCatalogSource Load() => Shared.Value;
}

[JsonSerializable(typeof(DemoCatalogSource))]
internal sealed partial class DemoJsonContext : JsonSerializerContext;

/// <summary>The made-up account every demo service is signed in as. Not a real person.</summary>
public static class DemoAccount
{
    public const string Name = "Riley Calder";
    public const string Initials = "RC";
}

/// <summary>What the demo plays: an album, the song to start at, and where in the song.</summary>
public sealed record DemoNowPlaying(Album Album, IReadOnlyList<Track> Tracks, int Index, double Position);

public sealed partial class MockCatalog
{
    private enum Pick { Random, Newest, Liked }
    private enum Art { Mosaic, Liked }

    private sealed record PlaylistSpec(string Title, string? Summary = null, bool Mine = false, Pick Pick = Pick.Random, int Count = 40, Art Art = Art.Mosaic);

    private void BuildDemo()
    {
        var provider = Provider;
        var s = provider.Short();
        var source = DemoCatalogSource.Load();
        var albums = source.Albums.Where(a => a.Service == provider).ToList();
        string ArtistId(string name) => $"{s}-ar-{Slug(name)}";

        var artistOrder = new List<string>();
        var firstCover = new Dictionary<string, string>();
        foreach (var album in albums)
        {
            foreach (var name in album.Artists)
            {
                if (artistOrder.Contains(name)) continue;
                artistOrder.Add(name);
                firstCover[name] = album.Key;
            }
        }

        foreach (var album in albums)
        {
            var albumId = $"{s}-{album.Key}";
            var art = MockArtwork.Artwork("demo", album.Key);
            var refs = album.Artists.Select(n => new ArtistRef(ArtistId(n), n)).ToList();
            var tracks = album.Tracks.Select((song, i) => new Track
            {
                ProviderID = $"{albumId}-t{i}", Provider = provider, Title = song.Title,
                Artists = (song.Artists ?? album.Artists).Select(n => new ArtistRef(ArtistId(n), n)).ToList(),
                Album = new AlbumRef(albumId, album.Title), Duration = song.Seconds, Artwork = art, IsExplicit = song.Explicit,
                TrackNumber = i + 1,
            }).ToList();
            AlbumTracks[albumId] = tracks;
            Albums.Add(new Album
            {
                ProviderID = albumId, Provider = provider, Title = album.Title, Artists = refs,
                Year = int.Parse(album.Released[..4], CultureInfo.InvariantCulture), Artwork = art, Kind = album.Kind,
                TrackCount = tracks.Count, IsExplicit = tracks.Any(t => t.IsExplicit),
                Extra = new Dictionary<string, string> { ["released"] = album.Released, ["genre"] = album.Genre, ["copyright"] = album.Copyright },
            });
        }

        foreach (var name in artistOrder)
        {
            var photo = source.ArtistPhotos.GetValueOrDefault(name) ?? firstCover.GetValueOrDefault(name);
            Artists.Add(new Artist
            {
                ProviderID = ArtistId(name), Provider = provider, Name = name,
                Artwork = photo is null ? null : MockArtwork.Artwork("demo", photo),
            });
        }

        // Mixes and the listener's own playlists, each from a fixed, seeded pick of this service's songs.
        var all = AllTracks;
        var rng = new SeededRandom(SeededRandom.Fnv1a($"demo-{provider.RawValue()}"));
        var specs = PlaylistSpecs(provider);
        for (var i = 0; i < specs.Count; i++)
        {
            var spec = specs[i];
            var id = $"{s}-pl{i}";
            List<Track> picked;
            switch (spec.Pick)
            {
                case Pick.Newest:
                    var recent = Albums.OrderByDescending(a => a.Extra.GetValueOrDefault("released") ?? "", StringComparer.Ordinal).Take(8);
                    picked = recent.SelectMany(a => (AlbumTracks.GetValueOrDefault(a.ProviderID) ?? []).Take(3)).ToList();
                    break;
                case Pick.Liked:
                    picked = all.Where((_, n) => n % 5 == 0).ToList();
                    break;
                default:
                    picked = rng.Shuffled(all).Take(spec.Count).ToList();
                    break;
            }
            var covers = DistinctAlbums(picked, 4);
            Artwork? artwork = spec.Art switch
            {
                Art.Mosaic => covers.Count == 4 ? MockArtwork.Artwork("mosaic", string.Join("+", covers))
                    : covers.Count > 0 ? MockArtwork.Artwork("demo", covers[0]) : null,
                _ => MockArtwork.Artwork("liked", provider.RawValue()),
            };
            var names = LeadArtists(picked, 3);
            PlaylistTracks[id] = picked;
            var extra = new Dictionary<string, string>();
            if (spec.Pick == Pick.Liked) extra[Core.Playlist.LikedSongsKey] = "1";
            Playlists.Add(new Playlist
            {
                ProviderID = id, Provider = provider, Title = spec.Title,
                Owner = spec.Mine ? DemoAccount.Name : provider.DisplayName(),
                Artwork = artwork, TrackCount = picked.Count,
                Summary = spec.Summary ?? (spec.Mine || names.Count == 0 ? null : $"{string.Join(", ", names)} and more"),
                IsEditable = spec.Mine, Extra = extra,
            });
        }
    }

    /// <summary>The first <paramref name="count"/> different album covers among <paramref name="tracks"/> (their artwork keys).</summary>
    private static List<string> DistinctAlbums(List<Track> tracks, int count)
    {
        var keys = new List<string>();
        foreach (var t in tracks)
        {
            if (t.Artwork?.Images.FirstOrDefault()?.Url is not { } url) continue;
            var key = url.Segments[^1];
            if (keys.Contains(key)) continue;
            keys.Add(key);
            if (keys.Count == count) break;
        }
        return keys;
    }

    private static List<string> LeadArtists(List<Track> tracks, int count)
    {
        var names = new List<string>();
        foreach (var t in tracks)
        {
            if (t.Artists.FirstOrDefault()?.Name is not { } name || names.Contains(name)) continue;
            names.Add(name);
            if (names.Count == count) break;
        }
        return names;
    }

    private static List<PlaylistSpec> PlaylistSpecs(ProviderId provider) => provider == ProviderId.YouTubeMusic
        ?
        [
            new("Liked Music", "Auto playlist", Pick: Pick.Liked, Art: Art.Liked),
            new("My Supermix", Count: 50),
            new("My Mix 1"),
            new("My Mix 2"),
            new("Discover Mix", "New music picked for you, refreshed every Wednesday"),
            new("New Release Mix", Pick: Pick.Newest),
            new("late night drive", Mine: true, Count: 28),
            new("gym", Mine: true, Count: 32),
            new("Sunday Reset", Mine: true, Count: 22),
        ]
        :
        [
            new("Daily Mix 1"),
            new("Discover Weekly", "Your weekly mixtape of fresh music. Enjoy new music and deep cuts picked for you. Updates every Monday."),
            new("Release Radar", "Catch all the latest music from artists you follow, plus new singles picked for you.", Pick: Pick.Newest),
            new("Daily Mix 2"),
            new("On Repeat", "Songs you love right now", Count: 30),
            new("fall 2026", Mine: true, Count: 34),
            new("road trip", Mine: true, Count: 40),
        ];
}

/// <summary>The demo dataset's shelves (Swift <c>DemoShelves</c>).</summary>
internal static class DemoShelves
{
    /// <summary>A song by album key and title (or the start of its title), if this service has it.</summary>
    public static Track? Track(MockCatalog c, string albumKey, string title)
    {
        var tracks = c.AlbumTracks.GetValueOrDefault($"{c.Provider.Short()}-{albumKey}") ?? [];
        return tracks.FirstOrDefault(t => t.Title == title)
            ?? tracks.FirstOrDefault(t => t.Title.ToLowerInvariant().StartsWith(title.ToLowerInvariant(), StringComparison.Ordinal));
    }

    public static Album? Album(MockCatalog c, string key) => c.Album($"{c.Provider.Short()}-{key}");

    /// <summary>This service's chart songs, in chart order.</summary>
    public static List<Track> Chart(MockCatalog c)
    {
        (string, string)[] picks = c.Provider == ProviderId.YouTubeMusic
            ?
            [
                ("tate-mcrae-housewife", "Housewife"),
                ("olivia-rodrigo-you-seem-pretty-sad-for-a-girl-so", "the cure"),
                ("olivia-dean-the-art-of-loving", "Man I Need"),
                ("kpop-demon-hunters-cast-huntr-x-saja-boys-kpop-d", "Golden"),
                ("taylor-swift-the-life-of-a-showgirl", "The Fate of Ophelia"),
                ("olivia-rodrigo-you-seem-pretty-sad-for-a-girl-so", "stupid song"),
                ("rose-new-trick", "new trick"),
                ("olivia-rodrigo-chappell-roan-expectations", "expectations"),
                ("sabrina-carpenter-short-n-sweet", "Espresso"),
                ("bad-bunny-debi-tirar-mas-fotos", "DtMF"),
                ("billie-eilish-hit-me-hard-and-soft", "BIRDS OF A FEATHER"),
                ("ariana-grande-petal", "petal"),
                ("sombr-i-barely-know-her", "back to friends"),
                ("harry-styles-kiss-all-the-time-disco-occasionall", "Aperture"),
                ("chappell-roan-the-rise-and-fall-of-a-midwest-pri", "Pink Pony Club"),
                ("taylor-swift-the-life-of-a-showgirl", "Opalite"),
                ("steve-lacy-oh-yeah", "Oh yeah?"),
                ("karol-g-no-me-arrepiento-de-sentir-tanto", "BbY WOW"),
            ]
            :
            [
                ("ella-langley-dandelion", "Choosin' Texas"),
                ("zach-bryan-young-manhood-and-other-donatable-org", "Lies"),
                ("adela-prima", "Nicole Kidman"),
                ("morgan-wallen-im-the-problem", "I'm The Problem"),
                ("jhene-aiko-westside-whimsy", "So Good"),
                ("sienna-spiro-visitor", "Great Expectation"),
                ("tame-impala-dracula", "Dracula"),
                ("sza-sos", "Snooze"),
                ("noah-kahan-the-great-divide", "The Great Divide"),
                ("dominic-fike-how-to-quit-smoking", "HOW TO QUIT SMOKING"),
                ("kendrick-lamar-gnx", "luther"),
                ("the-weeknd-hurry-up-tomorrow", "Timeless"),
                ("djo-the-crux", "Basic Being Basic"),
                ("benson-boone-american-heart", "Mystical Magical"),
                ("remi-wolf-mud", "Mud"),
                ("don-toliver-octane", "OCTANE"),
            ];
        var output = new List<Track>();
        foreach (var (key, title) in picks)
        {
            if (Track(c, key, title) is { } t && !output.Contains(t)) output.Add(t);
        }
        // Fill up from each album's opener so a short list still makes full shelves.
        foreach (var album in c.Albums)
        {
            if (output.Count >= 16) break;
            if (c.AlbumTracks.GetValueOrDefault(album.ProviderID)?.FirstOrDefault() is { } t && !output.Contains(t)) output.Add(t);
        }
        return output;
    }

    public static List<Album> Newest(MockCatalog c) =>
        c.Albums.OrderByDescending(a => a.Extra.GetValueOrDefault("released") ?? "", StringComparer.Ordinal).ToList();

    public static List<Shelf> Home(MockCatalog c)
    {
        var p = c.Provider.Short();
        var chart = Chart(c);
        var mixes = c.Playlists.Where(x => !x.IsEditable).ToList();
        var mine = c.Playlists.Where(x => x.IsEditable).ToList();
        if (c.Provider == ProviderId.YouTubeMusic)
        {
            var listenAgain = new[]
            {
                "taylor-swift-the-life-of-a-showgirl", "olivia-dean-the-art-of-loving", "sabrina-carpenter-short-n-sweet",
                "harry-styles-kiss-all-the-time-disco-occasionall", "billie-eilish-hit-me-hard-and-soft", "bad-bunny-debi-tirar-mas-fotos",
            }.Select(k => Album(c, k)).OfType<Album>();
            return
            [
                new($"{p}-quick", "Quick picks", ShelfStyle.TrackList, chart.Take(12).Select(MediaItem.Of).ToList()) { MoreToken = "quick" },
                new($"{p}-listen", "Listen again", ShelfStyle.Carousel,
                    [.. listenAgain.Select(MediaItem.Of), .. mixes.Take(2).Select(MediaItem.Of), .. mine.Take(1).Select(MediaItem.Of)]) { MoreToken = "listen" },
                new($"{p}-mixes", "Your mixes", ShelfStyle.Hero, mixes.Skip(1).Select(MediaItem.Of).ToList()) { Subtitle = "Made from your listening" },
                new($"{p}-top", "Top songs", ShelfStyle.TrackList, Enumerable.Reverse(chart).Take(12).Select(MediaItem.Of).ToList()) { Subtitle = "United States", MoreToken = "charts" },
                new($"{p}-artists", "Artists you listen to", ShelfStyle.Artists, c.Artists.Take(12).Select(MediaItem.Of).ToList()),
            ];
        }
        return
        [
            new($"{p}-made", "Made For You", ShelfStyle.Hero, mixes.Select(MediaItem.Of).ToList()) { Subtitle = "Mixes updated daily" },
            new($"{p}-new", "New releases for you", ShelfStyle.Carousel, Newest(c).Take(10).Select(MediaItem.Of).ToList()) { MoreToken = "new" },
            new($"{p}-jump", "Jump back in", ShelfStyle.Carousel,
                [.. c.Albums.TakeLast(8).Select(MediaItem.Of), .. mine.Select(MediaItem.Of)]) { MoreToken = "jump" },
            new($"{p}-top", "Your top songs this month", ShelfStyle.TrackList, chart.Take(12).Select(MediaItem.Of).ToList()),
            new($"{p}-artists", "Your top artists", ShelfStyle.Artists, c.Artists.Take(12).Select(MediaItem.Of).ToList()),
        ];
    }

    /// <summary>Signed out: the charts, what's new and moods.</summary>
    public static List<Shelf> AnonymousHome(MockCatalog c, List<MediaItem> moods)
    {
        var p = c.Provider.Short();
        var albums = Newest(c).Where(a => a.Kind == AlbumKind.Album);
        return
        [
            new($"{p}-top", "Top songs", ShelfStyle.TrackList, Chart(c).Take(12).Select(MediaItem.Of).ToList()) { Subtitle = "United States", MoreToken = "charts" },
            new($"{p}-new", "New releases", ShelfStyle.Carousel, albums.Take(14).Select(MediaItem.Of).ToList()) { MoreToken = "new" },
            new($"{p}-moods", "Moods & genres", ShelfStyle.Carousel, moods) { MoreToken = "moods" },
            new($"{p}-trending", "Trending artists", ShelfStyle.Artists, Enumerable.Reverse(c.Artists).Select(MediaItem.Of).ToList()),
        ];
    }

    public static List<Shelf> Explore(MockCatalog c, List<MediaItem> moods)
    {
        var p = c.Provider.Short();
        return
        [
            new($"{p}-new", c.Provider == ProviderId.Spotify ? "Popular new releases" : "New releases", ShelfStyle.Carousel,
                Newest(c).Where(a => a.Kind == AlbumKind.Album).Take(14).Select(MediaItem.Of).ToList()) { MoreToken = "new" },
            new($"{p}-charts", c.Provider == ProviderId.Spotify ? "Top 50 · USA" : "Top songs", ShelfStyle.TrackList,
                Chart(c).Select(MediaItem.Of).ToList()) { MoreToken = "charts" },
            new($"{p}-moods", "Moods & genres", ShelfStyle.Carousel, moods) { MoreToken = "moods" },
            new($"{p}-singles", "New singles & EPs", ShelfStyle.Carousel, Newest(c).Where(a => a.Kind != AlbumKind.Album).Select(MediaItem.Of).ToList()),
            new($"{p}-trending", "Trending artists", ShelfStyle.Artists, Enumerable.Reverse(c.Artists).Select(MediaItem.Of).ToList()),
        ];
    }

    /// <summary>The song both apps show playing: "the cure" from Olivia Rodrigo's new album, 1:12 in.</summary>
    public static DemoNowPlaying? NowPlaying(MockCatalog c)
    {
        if (Album(c, "olivia-rodrigo-you-seem-pretty-sad-for-a-girl-so") is not { } album
            || c.AlbumTracks.GetValueOrDefault(album.ProviderID) is not { } tracks) return null;
        var index = tracks.FindIndex(t => t.Title == "the cure");
        return index < 0 ? null : new DemoNowPlaying(album, tracks, index, 72);
    }
}
