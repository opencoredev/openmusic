using System.Globalization;
using System.Text;

namespace OpenMusic.Core.Mock;

/// <summary>Which sample data a mock provider serves.</summary>
public enum MockDataset
{
    /// <summary>Invented artists and procedural artwork (tests, UI work).</summary>
    Sample,
    /// <summary>Real chart albums with real cover art and a made-up listener, for screenshots (DemoCatalog.cs).</summary>
    Demo,
}

/// <summary>
/// A deterministic music catalog for one mock provider. The sample dataset is invented: none of its names refers to a
/// real artist or release. The demo dataset uses real chart albums (titles and lengths only). Both are built exactly as
/// the Swift <c>MockCatalog</c> builds them, so ids, picks and lyrics match the Mac app's. Port of MockCatalog.swift.
/// </summary>
public sealed partial class MockCatalog
{
    public ProviderId Provider { get; }
    public MockDataset Dataset { get; }
    public List<Artist> Artists { get; } = [];
    public List<Album> Albums { get; } = [];
    public Dictionary<string, List<Track>> AlbumTracks { get; } = [];
    public List<Playlist> Playlists { get; } = [];
    public Dictionary<string, List<Track>> PlaylistTracks { get; } = [];
    public Dictionary<string, string> Bios { get; } = [];

    public List<Track> AllTracks => Albums.SelectMany(a => AlbumTracks.GetValueOrDefault(a.ProviderID) ?? []).ToList();

    public MockCatalog(ProviderId provider, MockDataset dataset = MockDataset.Sample)
    {
        Provider = provider;
        Dataset = dataset;
        if (dataset == MockDataset.Demo) BuildDemo();
        else BuildSample();
    }

    private void BuildSample()
    {
        var provider = Provider;
        var s = provider.Short();
        var rng = new SeededRandom(SeededRandom.Fnv1a($"catalog-{provider.RawValue()}"));
        var names = provider == ProviderId.YouTubeMusic ? YtArtists : SpArtists;
        var albumTitles = provider == ProviderId.YouTubeMusic ? YtAlbums : SpAlbums;
        var titlePool = rng.Shuffled(SongTitles);
        var albumCursor = 0;

        for (var ai = 0; ai < names.Length; ai++)
        {
            var name = names[ai];
            var artistId = $"{s}-ar{ai}";
            var listeners = 1 + rng.Int(0, 40);
            // Swift evaluates the interpolation left to right: listeners first (above), then the decimal digit.
            var subtitle = provider == ProviderId.Spotify
                ? $"{listeners}.{rng.Int(0, 10)}M monthly listeners"
                : $"{listeners}.{rng.Int(0, 10)}M subscribers";
            Artists.Add(new Artist
            {
                ProviderID = artistId, Provider = provider, Name = name,
                Artwork = MockArtwork.Artwork("portrait", artistId), Subtitle = subtitle,
            });
            Bios[artistId] = Bio(name, ref rng);

            var count = 2 + rng.Int(0, 2);
            for (var k = 0; k < count; k++)
            {
                var title = albumTitles[albumCursor % albumTitles.Length];
                albumCursor++;
                var albumId = $"{s}-al{Albums.Count}";
                AlbumKind kind;
                if (k == count - 1 && rng.Unit() > 0.4) kind = rng.Unit() > 0.5 ? AlbumKind.Single : AlbumKind.Ep;
                else kind = AlbumKind.Album;
                var trackCount = kind == AlbumKind.Album ? 8 + rng.Int(0, 5) : kind == AlbumKind.Ep ? 4 : 1 + rng.Int(0, 2);
                var tracks = new List<Track>();
                for (var t = 0; t < trackCount; t++)
                {
                    if (titlePool.Count == 0) titlePool = rng.Shuffled(SongTitles);
                    string songTitle;
                    if (kind == AlbumKind.Single && t == 0) songTitle = title;
                    else
                    {
                        songTitle = titlePool[^1];
                        titlePool.RemoveAt(titlePool.Count - 1);
                    }
                    var artists = new List<ArtistRef> { new(artistId, name) };
                    if (rng.Unit() > 0.88)
                    {
                        var other = (ai + 3) % names.Length;
                        artists.Add(new ArtistRef($"{s}-ar{other}", names[other]));
                    }
                    var duration = 140 + rng.Int(0, 170);
                    var isExplicit = rng.Unit() > 0.82;
                    tracks.Add(new Track
                    {
                        ProviderID = $"{albumId}-t{t}", Provider = provider, Title = songTitle, Artists = artists,
                        Album = new AlbumRef(albumId, title), Duration = duration, Artwork = MockArtwork.Artwork("art", albumId),
                        IsExplicit = isExplicit, TrackNumber = t + 1,
                    });
                }
                AlbumTracks[albumId] = tracks;
                Albums.Add(new Album
                {
                    ProviderID = albumId, Provider = provider, Title = title, Artists = [new ArtistRef(artistId, name)],
                    Year = 2014 + rng.Int(0, 12), Artwork = MockArtwork.Artwork("art", albumId), Kind = kind,
                    TrackCount = trackCount, IsExplicit = tracks.Any(t => t.IsExplicit),
                });
            }
        }

        var all = AllTracks;
        var playlistNames = provider == ProviderId.YouTubeMusic ? YtPlaylists : SpPlaylists;
        for (var pi = 0; pi < playlistNames.Length; pi++)
        {
            var (ptitle, summary, mine) = playlistNames[pi];
            var id = $"{s}-pl{pi}";
            var size = 18 + rng.Int(0, 50);
            var picked = new List<Track>();
            var seen = new HashSet<string>();
            while (picked.Count < Math.Min(size, all.Count))
            {
                var t = all[rng.Int(0, all.Count)];
                if (seen.Add(t.Id)) picked.Add(t);
            }
            PlaylistTracks[id] = picked;
            Playlists.Add(new Playlist
            {
                ProviderID = id, Provider = provider, Title = ptitle, Owner = mine ? "Sample Listener" : provider.DisplayName(),
                Artwork = MockArtwork.Artwork("art", id), TrackCount = picked.Count, Summary = summary, IsEditable = mine,
                Extra = ptitle == "Liked Music" ? new Dictionary<string, string> { [Core.Playlist.LikedSongsKey] = "1" } : Support.Eq.EmptyExtra,
            });
        }
    }

    // MARK: Lookups

    public Album? Album(string id) => Albums.FirstOrDefault(a => a.ProviderID == id);
    public Artist? Artist(string id) => Artists.FirstOrDefault(a => a.ProviderID == id);
    public Playlist? Playlist(string id) => Playlists.FirstOrDefault(p => p.ProviderID == id);
    public List<Album> AlbumsBy(string artistId) => Albums.Where(a => a.Artists.FirstOrDefault()?.Id == artistId).ToList();
    public List<Track> TracksBy(string artistId) => AllTracks.Where(t => t.Artists.Any(a => a.Id == artistId)).ToList();

    public void AddPlaylist(Playlist playlist)
    {
        Playlists.Insert(0, playlist);
        PlaylistTracks[playlist.ProviderID] = [];
    }

    public void Append(IReadOnlyList<Track> tracks, string playlistId)
    {
        if (!PlaylistTracks.TryGetValue(playlistId, out var list)) PlaylistTracks[playlistId] = list = [];
        list.AddRange(tracks);
        UpdateCount(playlistId);
    }

    public void Insert(IReadOnlyList<Track> tracks, int position, string playlistId)
    {
        if (!PlaylistTracks.TryGetValue(playlistId, out var list)) PlaylistTracks[playlistId] = list = [];
        list.InsertRange(Math.Clamp(position, 0, list.Count), tracks);
        UpdateCount(playlistId);
    }

    public void Remove(IReadOnlySet<string> ids, string playlistId)
    {
        if (PlaylistTracks.TryGetValue(playlistId, out var list)) list.RemoveAll(t => ids.Contains(t.Id));
        UpdateCount(playlistId);
    }

    private void UpdateCount(string playlistId)
    {
        var i = Playlists.FindIndex(p => p.ProviderID == playlistId);
        if (i >= 0) Playlists[i] = Playlists[i] with { TrackCount = PlaylistTracks.GetValueOrDefault(playlistId)?.Count };
    }

    // MARK: Lyrics

    /// <summary>Placeholder lyrics (the mock layer's own lines, never a song's real words), synced for YouTube Music and
    /// most Spotify songs. About one sample track in eight is instrumental (null).</summary>
    public Lyrics? Lyrics(Track track)
    {
        var rng = new SeededRandom(SeededRandom.Fnv1a($"lyrics-{track.Id}"));
        if (rng.Unit() < 0.12 && Dataset == MockDataset.Sample) return null;
        var synced = Provider == ProviderId.YouTubeMusic || rng.Unit() > 0.3;
        var verses = rng.Shuffled(LyricVerses);
        var lines = new List<LyricLine>();
        var time = 6 + rng.Unit() * 6;
        var duration = track.Duration ?? 200;
        var vi = 0;
        foreach (var verse in verses.Take(5))
        {
            foreach (var line in verse)
            {
                lines.Add(new LyricLine(synced ? time : null, line));
                time += 3.2 + rng.Unit() * 2.6;
            }
            if (vi < 4)
            {
                lines.Add(new LyricLine(synced ? time : null, ""));
                time += 2.5;
            }
            vi++;
            if (time > duration - 10) break;
        }
        return new Lyrics(lines, synced ? "Synced lyrics" : "Lyrics");
    }

    // MARK: Pools

    private static readonly string[] YtArtists = ["Mara Vale", "The Lanterns", "Okapi", "June Harlow", "Echo Park Kids", "Sol Rivera", "Nova Lux", "Harbor & Pine", "Kestrel", "Lumen Drive"];
    private static readonly string[] SpArtists = ["Ivy Crane", "Coastal Static", "Rue Marlowe", "Night Swimmer", "Atlas Bloom", "The Velvet Arcade", "Tomo Hart", "Wren & Wilder", "Saffron Days", "Low Orbit"];

    private static readonly string[] YtAlbums = ["Glass Harbor", "Northern Lights", "Paper Moons", "Afterglow", "Static Bloom", "City of Echoes", "Golden Hour Radio", "Satellite Hearts", "Low Tide", "Wildflower Season", "Neon Rain", "Undertow", "Silver Lining", "Late Bloomer", "Overpass", "Field Notes", "Sunday Static", "Blue Hour", "Copper Sky", "Driftwood", "Parallel Lines", "Monochrome", "Soft Focus", "Heatwave", "The Long Way", "Kites", "Open Water", "Signals"];
    private static readonly string[] SpAlbums = ["Velvet Hours", "Midnight Drive", "Polaroid Summer", "Quiet Machines", "Gravity Well", "Lemon Light", "Tidal", "Cassette Dreams", "Hollow Pines", "Ultraviolet", "Slow Burn", "Arcade Fire Escape", "Sea Glass", "Moth & Flame", "Postcards", "Sundial", "Echo Chamber", "Paper Planes", "Night Market", "Small Hours", "Bright Side", "Rivers", "Cinder", "Orbit", "Hourglass", "Wanderer", "Lowlands", "Daybreak"];

    private static readonly string[] SongTitles =
    [
        "Midnight Drive", "Glass Harbor", "Paper Planes", "Northern Lights", "Slow Burn", "Afterglow", "Static Bloom",
        "Velvet Hours", "Low Tide", "City of Echoes", "Golden Hour", "Satellite", "Wildflower", "Neon Rain", "Undertow",
        "Silver Lining", "Coastline", "Daydreamer", "Half Light", "Tell Me Twice", "Runaway Sun", "Ghost Town Gold",
        "Chasing Planes", "Better Weather", "Ferris Wheel", "Lighthouse", "Two Hearts, One Radio", "Ocean Avenue",
        "Little Fires", "Phosphor", "Blue Static", "Honey & Smoke", "Sleepwalker", "Open Road", "Polaroids",
        "Carousel", "Every Other Summer", "Fault Lines", "Wishing Well", "Nightswimming in July", "Paper Crowns",
        "Strangers Again", "Signal Fire", "Slow Motion", "Fever Dream", "Tangerine", "Starlight Motel", "Echoes",
        "Rooftops", "Dreamland", "Heartbeat Radio", "Lost & Found", "Gravity", "Weightless", "Sugar Rush", "Hold On",
        "Gold Rush", "Driftwood", "Mirrorball", "Firefly", "Crystal Clear", "Holding Pattern", "After Hours",
        "Rewind", "Starling", "Bloom", "Cold Water", "Wonderland", "Kaleidoscope", "Moonlit", "Afterparty",
        "Shoreline", "Avalanche", "Daylight Savings", "Monday Morning", "Parade", "Skyline", "Lullaby",
    ];

    private static readonly (string Title, string? Summary, bool Mine)[] YtPlaylists =
    [
        ("Liked Music", "Your liked songs", false),
        ("Morning Coffee", "Gentle songs to start the day.", true),
        ("Supermix", "An endless mix of songs you love and new ones to discover.", false),
        ("Road Trip", null, true),
        ("Chill Mix", "Laid-back tracks based on your listening.", false),
        ("Focus Flow", "Instrumental-leaning picks to keep you in the zone.", false),
        ("Throwback Jams", null, true),
        ("Discover Mix", "New music picked for you, refreshed every Wednesday.", false),
    ];

    private static readonly (string Title, string? Summary, bool Mine)[] SpPlaylists =
    [
        ("Daily Mix 1", "Ivy Crane, Night Swimmer, Atlas Bloom and more", false),
        ("Discover Weekly", "Your weekly mixtape of fresh music. Enjoy new music and deep cuts picked for you.", false),
        ("Late Night Drive", "For the long way home.", true),
        ("Release Radar", "Catch all the latest music from artists you follow.", false),
        ("Workout", null, true),
        ("Rainy Day", "Cozy songs for grey skies.", true),
        ("Indie Gold", "The best indie tracks of the last decade.", false),
        ("Dinner Party", null, true),
    ];

    private static readonly string[][] LyricVerses =
    [
        ["I left the porch light on for you", "In case the night forgot your name", "The radio is humming low", "And every song still sounds the same"],
        ["We were running down the avenue", "With our pockets full of rain", "You said the city never sleeps", "But it was dreaming all the same"],
        ["Hold on, hold on", "To the shape of the morning", "Hold on, hold on", "Till the light comes pouring in"],
        ["Paper planes across the ceiling", "Every one a wish we made", "Counting down the summer evenings", "Watching all the colors fade"],
        ["And oh, it's a long way down", "From the top of the Ferris wheel", "But I'd ride it again and again", "Just to feel the way I feel"],
        ["Static on the line tonight", "Your voice is coming through in waves", "Tell me that you're on your way", "Tell me something that can stay"],
        ["We don't need the stars to shine", "We've got headlights and a song", "Turn it up and roll the windows down", "Sing it loud and sing along"],
        ["Low tide, low tide", "Leaves the secrets on the sand", "Low tide, low tide", "Puts the ocean in my hands"],
        ["Golden hour on the overpass", "Shadows long enough to hide", "I could stay here for a lifetime", "With the whole world passing by"],
        ["Every time I close my eyes", "I'm back where we began", "Two kids and a borrowed car", "And no idea of any plan"],
    ];

    private static string Bio(string name, ref SeededRandom rng)
    {
        var city = new[] { "Lisbon", "Melbourne", "Toronto", "Glasgow", "Portland", "Osaka", "Bristol", "Austin" }[rng.Int(0, 8)];
        var style = new[] { "dream pop", "indie rock", "synth-pop", "alt-folk", "electronic soul", "bedroom pop" }[rng.Int(0, 6)];
        var year = 2010 + rng.Int(0, 12);
        return $"{name} formed in {city} in {year}, mixing {style} with hazy field recordings and big, singable choruses. "
            + "Their self-released debut spread through late-night playlists before a run of sold-out club shows. "
            + "The newest record trades bedroom-scale production for a full band, recorded live to tape over two weeks in a converted church. "
            + "On stage the songs stretch out into long, droning codas, and the band has become known for inviting the opening act back on for the last number. "
            + "Between records they score short films and run a small cassette label for friends' projects.";
    }

    /// <summary>An id-safe form of a name: ASCII letters and digits, dashes between, at most 48.</summary>
    internal static string Slug(string s)
    {
        var folded = new StringBuilder();
        foreach (var ch in s.Normalize(NormalizationForm.FormD))
        {
            if (CharUnicodeInfo.GetUnicodeCategory(ch) != UnicodeCategory.NonSpacingMark) folded.Append(ch);
        }
        var lower = folded.ToString().Normalize(NormalizationForm.FormC).ToLowerInvariant();
        var output = new StringBuilder();
        var dash = false;
        foreach (var ch in lower)
        {
            if (ch < 128 && char.IsAsciiLetterOrDigit(ch))
            {
                output.Append(ch);
                dash = false;
            }
            else if (!dash && output.Length > 0)
            {
                output.Append('-');
                dash = true;
            }
        }
        var result = output.ToString().TrimEnd('-');
        return result.Length > 48 ? result[..48] : result;
    }
}
