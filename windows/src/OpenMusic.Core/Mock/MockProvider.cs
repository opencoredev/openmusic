using System.ComponentModel;
using System.Globalization;

namespace OpenMusic.Core.Mock;

/// <summary>
/// Offline provider with sample data, for UI work, snapshots and tests without network or accounts. Each
/// <see cref="ProviderId"/> gets its own catalog, so two mocks look like two services. Port of MockProvider.swift
/// (minus the SwiftUI sign-in sheet). Use it on the UI thread.
/// </summary>
public sealed class MockProvider : IMusicProvider
{
    public ProviderId Id { get; }
    /// <summary>Settable so tests can take capabilities away.</summary>
    public ProviderCapabilities Capabilities { get; set; } =
        ProviderCapabilities.Search | ProviderCapabilities.Home | ProviderCapabilities.Library | ProviderCapabilities.Lyrics
        | ProviderCapabilities.SyncedLyrics | ProviderCapabilities.Radio | ProviderCapabilities.Like | ProviderCapabilities.PlaylistEditing
        | ProviderCapabilities.PlaylistInsert | ProviderCapabilities.Follow | ProviderCapabilities.Playback | ProviderCapabilities.Explore;

    private AuthStatus _authStatus;

    public AuthStatus AuthStatus
    {
        get => _authStatus;
        private set
        {
            _authStatus = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(AuthStatus)));
        }
    }

    public IPlaybackEngine PlaybackEngine { get; }
    /// <summary>Artificial delay for every call, to exercise loading states.</summary>
    public TimeSpan Latency { get; set; } = TimeSpan.Zero;
    public MockCatalog Catalog { get; }

    private readonly HashSet<string> _liked;
    /// <summary>Saved albums and playlists and followed artists, by <see cref="MediaItem.Id"/>.</summary>
    private readonly HashSet<string> _saved = [];
    private const int PageSize = 25;

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <param name="engine">The engine that plays this provider's tracks. Defaults to <see cref="MockPlaybackEngine"/>
    /// (a timer, no audio); the Windows app passes its MediaPlayer engine with a tone resolver.</param>
    public MockProvider(ProviderId id, bool signedIn = true, MockDataset dataset = MockDataset.Sample, IPlaybackEngine? engine = null)
    {
        Id = id;
        Catalog = new MockCatalog(id, dataset);
        _authStatus = signedIn ? AuthStatus.SignedIn(Account(id, dataset)) : AuthStatus.SignedOut;
        PlaybackEngine = engine ?? new MockPlaybackEngine();
        // Every fifth song starts out liked.
        _liked = Catalog.AllTracks.Where((_, i) => i % 5 == 0).Select(t => t.Id).ToHashSet();
    }

    private static AccountInfo Account(ProviderId id, MockDataset dataset)
    {
        var detail = id == ProviderId.Spotify ? "Premium" : "YouTube Music Premium";
        return dataset == MockDataset.Demo
            ? new AccountInfo(DemoAccount.Name, MockArtwork.Url("avatar", DemoAccount.Initials), detail)
            : new AccountInfo("Sample Listener", MockArtwork.Url("portrait", $"me-{id.RawValue()}"), detail);
    }

    public Task RestoreSessionAsync(CancellationToken ct = default) => Task.CompletedTask;

    /// <summary>Stands in for the sign-in sheet: signs in as the sample account.</summary>
    public void SignIn() => AuthStatus = AuthStatus.SignedIn(Account(Id, Catalog.Dataset));

    public Task SignOutAsync()
    {
        AuthStatus = AuthStatus.SignedOut;
        return Task.CompletedTask;
    }

    /// <summary>Shows a sign-in in progress, as a real provider does while it still sends the previous account's credentials.</summary>
    public void BeginSignIn() => AuthStatus = AuthStatus.SigningIn;

    // Test seams (as in the Swift mock).

    /// <summary>Who requests go out as, when set; otherwise what <see cref="AuthStatus"/> implies.</summary>
    public ProviderSession? SessionOverride { get; set; }
    public ProviderSession Session => SessionOverride ?? ProviderSession.Derived(AuthStatus);
    /// <summary>Browse calls (<see cref="HomeAsync"/>, <see cref="ExploreAsync"/>) throw this when set.</summary>
    public ProviderException? BrowseFailure { get; set; }
    public TimeSpan LibraryDelay { get; set; } = TimeSpan.Zero;
    public ProviderException? LibraryFailure { get; set; }
    /// <summary>Every library call made ("likedSongs:first", "likedSongs:50").</summary>
    public List<string> LibraryRequests { get; } = [];
    /// <summary>Single library pages that throw, by "kind:continuation", each for <c>Times</c> more calls.</summary>
    public Dictionary<string, (ProviderException Error, int Times)> LibraryPageFailures { get; } = [];
    /// <summary>Album, artist and playlist pages throw this when set.</summary>
    public ProviderException? DetailFailure { get; set; }
    /// <summary>Later playlist pages that throw, by continuation token ("&lt;playlist id&gt;|25").</summary>
    public Dictionary<string, (ProviderException Error, int Times)> PlaylistPageFailures { get; } = [];
    /// <summary>Awaited by every later playlist page before it answers, with its token.</summary>
    public Func<string, Task>? PlaylistPageGate { get; set; }
    public List<string> PlaylistPageRequests { get; } = [];
    /// <summary>When set, likes, saves, follows and playlist edits throw this.</summary>
    public ProviderException? FailingWrites { get; set; }
    /// <summary>The most songs one playlist removal or insertion takes, as Spotify's 100.</summary>
    public int? EditBatchSize { get; set; }
    public int? PlaylistEditBatchSize => EditBatchSize;
    /// <summary>Playlist removals and insertions that throw, by their number among those calls (1 is the first), each once.</summary>
    public Dictionary<int, Exception> PlaylistEditFailures { get; } = [];
    /// <summary>Every playlist removal and insertion asked for: "remove a, b", "insert a, b at 3".</summary>
    public List<string> PlaylistEdits { get; } = [];
    /// <summary>Playlist entries left out of every page, as Spotify leaves out local files and episodes.</summary>
    public HashSet<string> UnlistedTrackIds { get; } = [];
    public Func<string, Task>? PlaylistEditGate { get; set; }
    public bool UnlistedEntriesAnonymous { get; set; }
    public bool RepeatsContinuations { get; set; }
    /// <summary>The next playlist add appends its first <c>After</c> songs, then throws (once).</summary>
    public (int After, Exception Error)? AddFailure { get; set; }
    /// <summary>The account the mock's network side holds right now. Null: the account <see cref="Session"/> names.</summary>
    public string? CredentialsAccountId { get; set; }
    /// <summary>Every playlist read: "cached …" through the cached reads, "fresh …" through the uncached ones.</summary>
    public List<string> PlaylistReads { get; } = [];

    private async Task Delay(CancellationToken ct)
    {
        if (Latency > TimeSpan.Zero) await Task.Delay(Latency, ct);
    }

    private void RequireSignIn()
    {
        if (!AuthStatus.IsSignedIn) throw ProviderException.NotSignedIn();
    }

    private void RequireWritable()
    {
        RequireSignIn();
        if (FailingWrites is not null) throw FailingWrites;
    }

    private void NotePlaylistEdit(string description)
    {
        PlaylistEdits.Add(description);
        if (PlaylistEditFailures.Remove(PlaylistEdits.Count, out var failure)) throw failure;
    }

    /// <summary>The entries offset..&lt;offset + pageSize of a playlist: the ones listed, with their places, and how many there were.</summary>
    private (List<Track> Tracks, List<int>? Positions, int Count, Dictionary<int, string>? Unlisted) Entries(List<Track> tracks, int offset)
    {
        var slice = tracks.Skip(offset).Take(PageSize).ToList();
        if (UnlistedTrackIds.Count == 0) return (slice, null, slice.Count, null);
        var listed = slice.Select((t, i) => (t, i)).Where(x => !UnlistedTrackIds.Contains(x.t.Id)).ToList();
        var unlisted = new Dictionary<int, string>();
        if (!UnlistedEntriesAnonymous)
        {
            for (var i = 0; i < slice.Count; i++)
            {
                if (UnlistedTrackIds.Contains(slice[i].Id)) unlisted[offset + i] = $"local:{slice[i].Id}";
            }
        }
        return (listed.Select(x => x.t).ToList(), listed.Select(x => offset + x.i).ToList(), slice.Count, unlisted.Count == 0 ? null : unlisted);
    }

    // MARK: Browse

    public async Task<IReadOnlyList<Shelf>> HomeAsync(CancellationToken ct = default)
    {
        await Delay(ct);
        if (BrowseFailure is not null) throw BrowseFailure;
        var c = Catalog;
        // Signed out there is no listening to draw on: charts, new releases and moods.
        if (!AuthStatus.IsSignedIn) return AnonymousHome();
        if (c.Dataset == MockDataset.Demo) return DemoShelves.Home(c);
        var tracks = c.AllTracks;
        if (Id == ProviderId.YouTubeMusic)
        {
            return
            [
                new("yt-quick", "Quick picks", ShelfStyle.TrackList, Stride(3, tracks.Count, 3).Take(16).Select(i => MediaItem.Of(tracks[i])).ToList()) { MoreToken = "quick" },
                new("yt-listen", "Listen again", ShelfStyle.Carousel, [.. c.Albums.Take(4).Select(MediaItem.Of), .. c.Playlists.Take(4).Select(MediaItem.Of)]) { MoreToken = "listen" },
                new("yt-mixed", "Mixed for you", ShelfStyle.Hero, c.Playlists.Where(p => !p.IsEditable).Select(MediaItem.Of).ToList()) { Subtitle = "Mixes made from your listening" },
                new("yt-albums", "Albums for you", ShelfStyle.Carousel, c.Albums.Skip(6).Take(12).Select(MediaItem.Of).ToList()) { MoreToken = "albums" },
                new("yt-artists", "Artists you listen to", ShelfStyle.Artists, c.Artists.Select(MediaItem.Of).ToList()),
            ];
        }
        return
        [
            new("sp-made", "Made For You", ShelfStyle.Hero, c.Playlists.Where(p => !p.IsEditable).Select(MediaItem.Of).ToList()) { Subtitle = "Mixes updated daily" },
            new("sp-jump", "Jump back in", ShelfStyle.Carousel, c.Albums.TakeLast(10).Select(MediaItem.Of).ToList()) { MoreToken = "jump" },
            new("sp-top", "Your top songs this month", ShelfStyle.TrackList, Stride(1, tracks.Count, 4).Take(12).Select(i => MediaItem.Of(tracks[i])).ToList()),
            new("sp-artists", "Your top artists", ShelfStyle.Artists, Enumerable.Reverse(c.Artists).Select(MediaItem.Of).ToList()),
            new("sp-recent", "Recently played", ShelfStyle.Carousel, [.. c.Playlists.Take(6).Select(MediaItem.Of), .. c.Albums.Take(4).Select(MediaItem.Of)]),
        ];
    }

    /// <summary>Home for a listener who isn't signed in: nothing personal.</summary>
    private List<Shelf> AnonymousHome()
    {
        var c = Catalog;
        var p = Id.Short();
        var moods = Moods.Select(m => MediaItem.Of(Category(m.Name, m.Color))).ToList();
        if (c.Dataset == MockDataset.Demo) return DemoShelves.AnonymousHome(c, moods);
        var tracks = c.AllTracks;
        return
        [
            new($"{p}-top", "Top songs", ShelfStyle.TrackList, Stride(0, tracks.Count, 2).Take(12).Select(i => MediaItem.Of(tracks[i])).ToList()) { MoreToken = "charts" },
            new($"{p}-new", "New releases", ShelfStyle.Carousel, c.Albums.OrderByDescending(a => a.Year ?? 0).Take(14).Select(MediaItem.Of).ToList()) { MoreToken = "new" },
            new($"{p}-moods", "Moods & genres", ShelfStyle.Carousel, moods) { MoreToken = "moods" },
            new($"{p}-popular", "Popular artists", ShelfStyle.Artists, c.Artists.Select(MediaItem.Of).ToList()),
        ];
    }

    public async Task<IReadOnlyList<Shelf>> ExploreAsync(CancellationToken ct = default)
    {
        await Delay(ct);
        if (BrowseFailure is not null) throw BrowseFailure;
        var c = Catalog;
        var moods = Moods.Select(m => MediaItem.Of(Category(m.Name, m.Color))).ToList();
        if (c.Dataset == MockDataset.Demo) return DemoShelves.Explore(c, moods);
        var tracks = c.AllTracks;
        var prefix = Id.Short();
        var rng = new SeededRandom(SeededRandom.Fnv1a(prefix));
        return
        [
            new($"{prefix}-new", "New releases", ShelfStyle.Carousel, c.Albums.OrderByDescending(a => a.Year ?? 0).Take(14).Select(MediaItem.Of).ToList()) { MoreToken = "new" },
            new($"{prefix}-moods", "Moods & genres", ShelfStyle.Carousel, moods) { MoreToken = "moods" },
            new($"{prefix}-charts", Id == ProviderId.Spotify ? "Top 50 · Global" : "Top songs", ShelfStyle.TrackList,
                Stride(0, tracks.Count, 2).Take(16).Select(i => MediaItem.Of(tracks[i])).ToList()) { MoreToken = "charts" },
            new($"{prefix}-singles", "New singles & EPs", ShelfStyle.Carousel, c.Albums.Where(a => a.Kind != AlbumKind.Album).Select(MediaItem.Of).ToList()),
            new($"{prefix}-rising", "Rising artists", ShelfStyle.Artists, rng.Shuffled(c.Artists).Select(MediaItem.Of).ToList()),
        ];
    }

    public async Task<Shelf> ShelfAsync(string moreToken, CancellationToken ct = default)
    {
        await Delay(ct);
        var c = Catalog;
        if (moreToken.StartsWith("mood:", StringComparison.Ordinal))
        {
            var name = moreToken["mood:".Length..];
            var rng = new SeededRandom(SeededRandom.Fnv1a(name));
            return new Shelf(moreToken, name, ShelfStyle.Carousel, rng.Shuffled(c.Playlists).Select(MediaItem.Of).ToList());
        }
        switch (moreToken)
        {
            case "moods":
                return new Shelf(moreToken, "Moods & genres", ShelfStyle.Carousel, Moods.Select(m => MediaItem.Of(Category(m.Name, m.Color))).ToList());
            case "quick" or "charts":
                var songs = c.AllTracks.Take(50).ToList();
                if (c.Dataset == MockDataset.Demo)
                {
                    var chart = DemoShelves.Chart(c);
                    songs = [.. chart, .. c.AllTracks.Where(t => !chart.Contains(t)).Take(20)];
                }
                return new Shelf(moreToken, moreToken == "quick" ? "Quick picks" : "Top songs", ShelfStyle.TrackList, songs.Select(MediaItem.Of).ToList());
            case "listen" or "jump":
                return new Shelf(moreToken, moreToken == "jump" ? "Jump back in" : "Listen again", ShelfStyle.Carousel,
                    [.. c.Albums.Select(MediaItem.Of), .. c.Playlists.Select(MediaItem.Of)]);
            default:
                return new Shelf(moreToken, moreToken == "new" ? "New releases" : "Albums for you", ShelfStyle.Carousel, c.Albums.Select(MediaItem.Of).ToList());
        }
    }

    /// <summary>Mood and genre entries, shaped like YouTube Music's (<c>extra["category"]</c>, a "#RRGGBB" stripe color, a browse token).</summary>
    private static readonly (string Name, string Color)[] Moods =
    [
        ("Chill", "#5FA8D3"), ("Commute", "#F2A541"), ("Energize", "#F25F5C"), ("Feel good", "#FFE066"),
        ("Focus", "#6A8EAE"), ("Party", "#C86BFA"), ("Romance", "#FF8FAB"), ("Sleep", "#3D348B"),
        ("Workout", "#E4572E"), ("Hip-hop", "#76B041"), ("Pop", "#FF5D8F"), ("Rock", "#8C5E58"),
        ("Jazz", "#2E86AB"), ("Classical", "#C9ADA7"),
    ];

    private Playlist Category(string name, string color) => new()
    {
        ProviderID = $"category:mood:{name}", Provider = Id, Title = name,
        Extra = new Dictionary<string, string> { ["category"] = "1", ["color"] = color, ["moreToken"] = $"mood:{name}" },
    };

    private static IEnumerable<int> Stride(int from, int to, int by)
    {
        for (var i = from; i < to; i += by) yield return i;
    }

    // MARK: Search

    public async Task<SearchResults> SearchAsync(string query, SearchScope scope, CancellationToken ct = default)
    {
        await Delay(ct);
        var q = query.Trim().ToLowerInvariant();
        if (q.Length == 0) return new SearchResults();
        var c = Catalog;
        bool Hit(string? s) => s is not null && s.ToLowerInvariant().Contains(q, StringComparison.Ordinal);
        var artists = c.Artists.Where(a => Hit(a.Name)).ToList();
        var artistIds = artists.Select(a => a.ProviderID).ToHashSet();
        var tracks = c.AllTracks.Where(t => Hit(t.Title) || t.Artists.Any(a => Hit(a.Name)) || Hit(t.Album?.Title ?? "")).ToList();
        var albums = c.Albums.Where(a => Hit(a.Title) || artistIds.Contains(a.Artists.FirstOrDefault()?.Id ?? "")).ToList();
        var playlists = c.Playlists.Where(p => Hit(p.Title) || Hit(p.Summary ?? "")).ToList();
        MediaItem? top = artists.Count > 0 ? MediaItem.Of(artists[0]) : albums.Count > 0 ? MediaItem.Of(albums[0])
            : tracks.Count > 0 ? MediaItem.Of(tracks[0]) : playlists.Count > 0 ? MediaItem.Of(playlists[0]) : null;
        return scope switch
        {
            SearchScope.Songs => new SearchResults { Tracks = tracks.Take(50).ToList() },
            SearchScope.Albums => new SearchResults { Albums = albums },
            SearchScope.Artists => new SearchResults { Artists = artists },
            SearchScope.Playlists => new SearchResults { Playlists = playlists },
            _ => new SearchResults
            {
                Top = top, Tracks = tracks.Take(20).ToList(), Albums = albums.Take(16).ToList(),
                Artists = artists.Take(12).ToList(), Playlists = playlists.Take(12).ToList(),
            },
        };
    }

    public Task<IReadOnlyList<string>> SearchSuggestionsAsync(string query, CancellationToken ct = default)
    {
        var q = query.ToLowerInvariant();
        if (q.Length == 0) return Task.FromResult<IReadOnlyList<string>>([]);
        var c = Catalog;
        var names = c.Artists.Select(a => a.Name).Concat(c.Albums.Select(a => a.Title)).Concat(c.AllTracks.Select(t => t.Title));
        var seen = new HashSet<string>();
        IReadOnlyList<string> result = names
            .Where(n => n.ToLowerInvariant().StartsWith(q, StringComparison.Ordinal) || n.ToLowerInvariant().Contains(" " + q, StringComparison.Ordinal))
            .Where(n => seen.Add(n.ToLowerInvariant()))
            .Take(6).ToList();
        return Task.FromResult(result);
    }

    /// <summary>Completions plus the matching artist and songs, as YouTube Music's suggestions show them.</summary>
    public async Task<SearchSuggestions> RichSearchSuggestionsAsync(string query, CancellationToken ct = default)
    {
        var queries = await SearchSuggestionsAsync(query, ct);
        var q = query.Trim().ToLowerInvariant();
        if (q.Length == 0) return SearchSuggestions.Empty;
        var c = Catalog;
        var items = new List<MediaItem>();
        items.AddRange(c.Artists.Where(a => a.Name.ToLowerInvariant().StartsWith(q, StringComparison.Ordinal)).Take(1).Select(MediaItem.Of));
        items.AddRange(c.AllTracks.Where(t => t.Title.ToLowerInvariant().StartsWith(q, StringComparison.Ordinal)).Take(2).Select(MediaItem.Of));
        return new SearchSuggestions(queries, items);
    }

    // MARK: Entities

    public async Task<AlbumDetail> AlbumAsync(string albumId, CancellationToken ct = default)
    {
        await Delay(ct);
        if (DetailFailure is not null) throw DetailFailure;
        var c = Catalog;
        if (c.Album(albumId) is not { } album) throw ProviderException.NotFound();
        // The saved flag as YouTube Music's toggle button reports it.
        album = album with { Extra = new Dictionary<string, string>(album.Extra) { ["saved"] = _saved.Contains(MediaItem.Of(album).Id) ? "1" : "0" } };
        var tracks = c.AlbumTracks.GetValueOrDefault(albumId) ?? [];
        var minutes = (int)(tracks.Sum(t => t.Duration ?? 0) / 60);
        var more = c.AlbumsBy(album.Artists.FirstOrDefault()?.Id ?? "").Where(a => a.ProviderID != albumId).ToList();
        string[] months = ["January", "March", "April", "June", "September", "October", "November"];
        var date = $"{months[(int)(SeededRandom.Fnv1a(albumId) % 7)]} {1 + albumId.Length % 27}, {album.Year ?? 2024}";
        var songs = $"{tracks.Count} song{(tracks.Count == 1 ? "" : "s")}, {minutes} minute{(minutes == 1 ? "" : "s")}";
        if (c.Dataset == MockDataset.Demo)
        {
            // Real albums: their real release date and label line, and no invented liner notes.
            var day = album.Extra.TryGetValue("released", out var released)
                && DateTime.TryParseExact(released, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d)
                ? d.ToString("MMMM d, yyyy", CultureInfo.GetCultureInfo("en-US")) : date;
            return new AlbumDetail(album, tracks, Footnote: $"{day}\n{songs}\n{album.Extra.GetValueOrDefault("copyright") ?? ""}",
                MoreByArtist: more.Count == 0 ? c.Albums.Take(6).ToList() : more);
        }
        return new AlbumDetail(album, tracks,
            Summary: album.Kind == AlbumKind.Album ? "A warm, widescreen record built from late-night demos, tape loops and a borrowed upright piano. Most of it was tracked live in a converted church hall over two winter weeks, with the band sharing two microphones and a single reel of tape. The songs drift between hushed ballads and loose, swinging grooves, held together by the piano's warped tuning and the room's long natural reverb. Strings were added later, recorded one player at a time in a kitchen." : null,
            Footnote: $"{date}\n{songs}\n℗ {album.Year ?? 2024} {album.ArtistLine} under exclusive license to Sample Records",
            MoreByArtist: more.Count == 0 ? c.Albums.Take(5).ToList() : more);
    }

    public async Task<ArtistDetail> ArtistAsync(string artistId, CancellationToken ct = default)
    {
        await Delay(ct);
        if (DetailFailure is not null) throw DetailFailure;
        var c = Catalog;
        if (c.Artist(artistId) is not { } artist) throw ProviderException.NotFound();
        var all = c.AlbumsBy(artistId);
        var index = Math.Max(0, c.Artists.IndexOf(artist));
        var related = Enumerable.Range(1, 6).Select(k => c.Artists[(index + k * 3) % c.Artists.Count]).Where(a => a != artist);
        return new ArtistDetail(artist)
        {
            TopTracks = c.TracksBy(artistId).Take(10).ToList(),
            Albums = all.Where(a => a.Kind == AlbumKind.Album).ToList(),
            Singles = all.Where(a => a.Kind != AlbumKind.Album).ToList(),
            Playlists = c.Playlists.Where(p => !p.IsEditable).Take(3).ToList(),
            Related = related.Distinct().OrderBy(a => a.Name, StringComparer.Ordinal).ToList(),
            Bio = c.Bios.GetValueOrDefault(artistId),
            RadioSeed = $"radio-{artistId}",
            IsFollowed = _saved.Contains(MediaItem.Of(artist).Id),
        };
    }

    public Task<PlaylistDetail> PlaylistAsync(string id, CancellationToken ct = default)
    {
        PlaylistReads.Add($"cached {id}");
        return Detail(id, ct);
    }

    public Task<PlaylistDetail> UncachedPlaylistAsync(string id, CancellationToken ct = default)
    {
        PlaylistReads.Add($"fresh {id}");
        return Detail(id, ct);
    }

    public Task<Page<Track>> PlaylistTracksAsync(string continuation, CancellationToken ct = default)
    {
        PlaylistReads.Add($"cached {continuation}");
        return PageOf(continuation, ct);
    }

    public Task<Page<Track>> UncachedPlaylistTracksAsync(string continuation, CancellationToken ct = default)
    {
        PlaylistReads.Add($"fresh {continuation}");
        return PageOf(continuation, ct);
    }

    private async Task<PlaylistDetail> Detail(string playlistId, CancellationToken ct)
    {
        await Delay(ct);
        if (DetailFailure is not null) throw DetailFailure;
        if (Catalog.Playlist(playlistId) is not { } playlist) throw ProviderException.NotFound();
        if (!playlist.IsEditable)
            playlist = playlist with { Extra = new Dictionary<string, string>(playlist.Extra) { ["saved"] = _saved.Contains(MediaItem.Of(playlist).Id) ? "1" : "0" } };
        var tracks = Catalog.PlaylistTracks.GetValueOrDefault(playlistId) ?? [];
        var first = Entries(tracks, 0);
        return new PlaylistDetail(playlist, first.Tracks)
        {
            Continuation = tracks.Count > PageSize ? $"{playlistId}|{PageSize}" : null,
            Positions = first.Positions,
            EntryCount = first.Positions is null ? null : first.Count,
            UnlistedEntries = first.Unlisted,
        };
    }

    private async Task<Page<Track>> PageOf(string continuation, CancellationToken ct)
    {
        PlaylistPageRequests.Add(continuation);
        await Delay(ct);
        if (PlaylistPageGate is not null) await PlaylistPageGate(continuation);
        if (PlaylistPageFailures.TryGetValue(continuation, out var failure) && failure.Times > 0)
        {
            if (failure.Times == 1) PlaylistPageFailures.Remove(continuation);
            else PlaylistPageFailures[continuation] = (failure.Error, failure.Times - 1);
            throw failure.Error;
        }
        var parts = continuation.Split('|');
        if (parts.Length != 2 || !int.TryParse(parts[1], CultureInfo.InvariantCulture, out var offset)) throw ProviderException.Decoding("bad continuation");
        var tracks = Catalog.PlaylistTracks.GetValueOrDefault(parts[0]) ?? [];
        var page = Entries(tracks, offset);
        var next = offset + PageSize;
        var token = RepeatsContinuations ? continuation : next < tracks.Count ? $"{parts[0]}|{next}" : null;
        return new Page<Track>(page.Tracks)
        {
            Continuation = token, Positions = page.Positions,
            EntryCount = page.Positions is null ? null : page.Count, UnlistedEntries = page.Unlisted,
        };
    }

    // MARK: Library

    public async Task<Page<MediaItem>> LibraryAsync(LibraryKind kind, string? continuation, CancellationToken ct = default)
    {
        RequireSignIn();
        var pageName = $"{kind.RawValue()}:{continuation ?? "first"}";
        LibraryRequests.Add(pageName);
        await Delay(ct);
        if (LibraryDelay > TimeSpan.Zero) await Task.Delay(LibraryDelay, ct);
        if (LibraryFailure is not null) throw LibraryFailure;
        if (LibraryPageFailures.TryGetValue(pageName, out var failure) && failure.Times > 0)
        {
            if (failure.Times == 1) LibraryPageFailures.Remove(pageName);
            else LibraryPageFailures[pageName] = (failure.Error, failure.Times - 1);
            throw failure.Error;
        }
        var c = Catalog;
        var all = c.AllTracks;
        List<MediaItem> items = kind switch
        {
            LibraryKind.LikedSongs => all.Where(t => _liked.Contains(t.Id)).Select(MediaItem.Of).ToList(),
            LibraryKind.Songs => all.Where((t, i) => i % 2 == 0 || _liked.Contains(t.Id)).Select(MediaItem.Of).ToList(),
            LibraryKind.Albums => c.Albums.Where((_, i) => i % 3 != 1).Select(MediaItem.Of).ToList(),
            LibraryKind.Artists => c.Artists.Select(MediaItem.Of).ToList(),
            LibraryKind.Playlists => c.Playlists.Select(MediaItem.Of).ToList(),
            _ => Stride(5, all.Count, 7).Take(16).Select(i => MediaItem.Of(all[i])).ToList(),
        };
        var offset = int.TryParse(continuation ?? "0", CultureInfo.InvariantCulture, out var o) ? o : 0;
        const int page = 50;
        return new Page<MediaItem>(items.Skip(offset).Take(page).ToList())
        {
            Continuation = offset + page < items.Count ? (offset + page).ToString(CultureInfo.InvariantCulture) : null,
        };
    }

    public Task SetLikedAsync(Track track, bool liked, CancellationToken ct = default)
    {
        RequireWritable();
        if (liked) _liked.Add(track.Id);
        else _liked.Remove(track.Id);
        return Task.CompletedTask;
    }

    public Task<bool> IsLikedAsync(Track track, CancellationToken ct = default) => Task.FromResult(_liked.Contains(track.Id));

    /// <summary>Synchronous like state, for rows that draw before any request (the mock has it locally).</summary>
    public bool IsLiked(Track track) => _liked.Contains(track.Id);

    public Task SetSavedAsync(MediaItem item, bool saved, CancellationToken ct = default)
    {
        RequireWritable();
        if (saved) _saved.Add(item.Id);
        else _saved.Remove(item.Id);
        return Task.CompletedTask;
    }

    public Task<Playlist> CreatePlaylistAsync(string title, string? description, CancellationToken ct = default) =>
        CreatePlaylist(title, description, null);

    public Task<Playlist> CreatePlaylistAsync(string title, string? description, PlaylistWriteAccount account, CancellationToken ct = default) =>
        CreatePlaylist(title, description, account);

    private async Task<Playlist> CreatePlaylist(string title, string? description, PlaylistWriteAccount? account)
    {
        if (PlaylistEditGate is not null) await PlaylistEditGate("create");
        CheckBinding(account);
        RequireSignIn();
        var playlist = new Playlist
        {
            ProviderID = $"{Id.Short()}-new-{Guid.NewGuid().ToString("N")[..8].ToUpperInvariant()}", Provider = Id, Title = title,
            Owner = Catalog.Dataset == MockDataset.Demo ? DemoAccount.Name : "Sample Listener",
            Artwork = MockArtwork.Artwork("art", $"new-{title}"), TrackCount = 0, Summary = description, IsEditable = true,
        };
        Catalog.AddPlaylist(playlist);
        return playlist;
    }

    public Task AddAsync(IReadOnlyList<Track> tracks, string playlistId, CancellationToken ct = default) => Add(tracks, playlistId, null);

    public Task AddAsync(IReadOnlyList<Track> tracks, string playlistId, PlaylistWriteAccount account, CancellationToken ct = default) =>
        Add(tracks, playlistId, account);

    public Task RemoveAsync(IReadOnlyList<Track> tracks, string playlistId, CancellationToken ct = default) => Remove(tracks, playlistId, null);

    public Task RemoveAsync(IReadOnlyList<Track> tracks, string playlistId, PlaylistWriteAccount account, CancellationToken ct = default) =>
        Remove(tracks, playlistId, account);

    public Task InsertAsync(IReadOnlyList<Track> tracks, string playlistId, int position, CancellationToken ct = default) =>
        Insert(tracks, playlistId, position, null);

    public Task InsertAsync(IReadOnlyList<Track> tracks, string playlistId, int position, PlaylistWriteAccount account, CancellationToken ct = default) =>
        Insert(tracks, playlistId, position, account);

    /// <summary>Where a real provider's network side picks a request's credentials: a bound write goes only while the account
    /// they belong to is the one it was checked for.</summary>
    private void CheckBinding(PlaylistWriteAccount? account)
    {
        if (account is null) return;
        bool held;
        if (CredentialsAccountId is { } creds) held = account.AccountId == creds;
        else
        {
            var session = Session;
            held = session.Identity.Kind switch
            {
                SessionIdentityKind.Changing => true,
                SessionIdentityKind.Account => account.AccountId is { } a ? a == session.Identity.AccountId : session == account.Session,
                _ => false,
            };
        }
        if (!held) throw PlaylistEditException.AccountChanged();
    }

    private async Task Add(IReadOnlyList<Track> tracks, string playlistId, PlaylistWriteAccount? account)
    {
        if (PlaylistEditGate is not null) await PlaylistEditGate("add");
        CheckBinding(account);
        RequireWritable();
        if (AddFailure is { } failure)
        {
            AddFailure = null;
            Catalog.Append(tracks.Take(failure.After).ToList(), playlistId);
            throw failure.Error;
        }
        Catalog.Append(tracks, playlistId);
    }

    /// <summary>Like Spotify's: every occurrence of each song goes, in requests of <see cref="EditBatchSize"/> songs.</summary>
    private async Task Remove(IReadOnlyList<Track> tracks, string playlistId, PlaylistWriteAccount? account)
    {
        RequireWritable();
        foreach (var chunk in Requests(tracks, EditBatchSize))
        {
            if (PlaylistEditGate is not null) await PlaylistEditGate("remove");
            CheckBinding(account);
            NotePlaylistEdit($"remove {string.Join(", ", chunk.Select(t => t.ProviderID))}");
            Catalog.Remove(chunk.Select(t => t.Id).ToHashSet(), playlistId);
        }
    }

    private async Task Insert(IReadOnlyList<Track> tracks, string playlistId, int position, PlaylistWriteAccount? account)
    {
        if (!Capabilities.HasFlag(ProviderCapabilities.PlaylistInsert)) throw ProviderException.NotSupported("Adding songs at a position in a playlist");
        RequireWritable();
        var at = position;
        foreach (var chunk in Requests(tracks, EditBatchSize))
        {
            if (PlaylistEditGate is not null) await PlaylistEditGate("insert");
            CheckBinding(account);
            NotePlaylistEdit($"insert {string.Join(", ", chunk.Select(t => t.ProviderID))} at {at}");
            Catalog.Insert(chunk, at, playlistId);
            at += chunk.Count;
        }
    }

    private static List<List<Track>> Requests(IReadOnlyList<Track> tracks, int? size)
    {
        if (size is not { } n || n <= 0 || tracks.Count <= n) return [tracks.ToList()];
        return tracks.Chunk(n).Select(c => c.ToList()).ToList();
    }

    // MARK: Playback support

    public Task<IReadOnlyList<Track>> RadioAsync(Track seed, CancellationToken ct = default)
    {
        var rng = new SeededRandom(SeededRandom.Fnv1a($"radio-{seed.Id}"));
        IReadOnlyList<Track> result = rng.Shuffled(Catalog.AllTracks.Where(t => t.Id != seed.Id)).Take(15).ToList();
        return Task.FromResult(result);
    }

    public Task<IReadOnlyList<Track>> RadioAsync(string seedId, CancellationToken ct = default)
    {
        var rng = new SeededRandom(SeededRandom.Fnv1a($"radio-{seedId}"));
        var artistId = seedId.Replace("radio-", "", StringComparison.Ordinal);
        var own = Catalog.TracksBy(artistId);
        var first = rng.Shuffled(own).Take(6);
        var second = rng.Shuffled(Catalog.AllTracks).Take(14);
        IReadOnlyList<Track> result = first.Concat(second).Take(20).ToList();
        return Task.FromResult(result);
    }

    public async Task<Lyrics?> LyricsAsync(Track track, CancellationToken ct = default)
    {
        await Delay(ct);
        return Catalog.Lyrics(track);
    }

    // MARK: Sample data

    public List<Track> SampleTracks(int count = 12) => Catalog.AllTracks.Take(count).ToList();

    /// <summary>The demo's now-playing pick, when this provider serves the demo dataset.</summary>
    public DemoNowPlaying? DemoNowPlaying => Catalog.Dataset == MockDataset.Demo ? DemoShelves.NowPlaying(Catalog) : null;

    /// <summary>A demo album by its key (see DemoCatalogData.json).</summary>
    public Album? DemoAlbum(string key) => Catalog.Dataset == MockDataset.Demo ? DemoShelves.Album(Catalog, key) : null;

    /// <summary>A demo song by album key and title.</summary>
    public Track? DemoTrack(string albumKey, string title) => Catalog.Dataset == MockDataset.Demo ? DemoShelves.Track(Catalog, albumKey, title) : null;
}

/// <summary>Simulates playback with a 0.5 s timer. No audio. Use it on the UI thread (or a <see cref="Threading.MainThreadContext"/>).</summary>
public sealed class MockPlaybackEngine : IPlaybackEngine
{
    public Action<PlaybackEvent>? OnEvent { get; set; }
    public float Volume { get; set; } = 1;
    public double CurrentTime { get; private set; }
    public double? Duration { get; private set; }
    /// <summary>Track ids whose load throws, to test what happens when a stream can't be resolved.</summary>
    public HashSet<string> FailingTrackIds { get; } = [];

    private CancellationTokenSource? _timer;

    public Task LoadAsync(Track track, double startAt, bool autoplay, CancellationToken ct)
    {
        StopTimer();
        if (FailingTrackIds.Contains(track.Id)) throw ProviderException.NotFound();
        Duration = track.Duration ?? 200;
        CurrentTime = startAt;
        OnEvent?.Invoke(new PlaybackEvent.Time(startAt, Duration));
        if (autoplay) Play();
        else OnEvent?.Invoke(new PlaybackEvent.StateChanged(PlaybackState.Paused));
        return Task.CompletedTask;
    }

    public void Play()
    {
        StopTimer();
        var cts = new CancellationTokenSource();
        _timer = cts;
        _ = Tick(cts.Token);
        OnEvent?.Invoke(new PlaybackEvent.StateChanged(PlaybackState.Playing));
    }

    private async Task Tick(CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested)
            {
                await Task.Delay(500, ct);
                CurrentTime += 0.5;
                OnEvent?.Invoke(new PlaybackEvent.Time(CurrentTime, Duration));
                if (Duration is { } d && CurrentTime >= d)
                {
                    StopTimer();
                    OnEvent?.Invoke(new PlaybackEvent.StateChanged(PlaybackState.Ended));
                    OnEvent?.Invoke(PlaybackEvent.Finished.Instance);
                    return;
                }
            }
        }
        catch (OperationCanceledException)
        {
        }
    }

    private void StopTimer()
    {
        _timer?.Cancel();
        _timer = null;
    }

    public void Pause()
    {
        StopTimer();
        OnEvent?.Invoke(new PlaybackEvent.StateChanged(PlaybackState.Paused));
    }

    public void Stop()
    {
        StopTimer();
        CurrentTime = 0;
        OnEvent?.Invoke(new PlaybackEvent.StateChanged(PlaybackState.Idle));
    }

    public void Seek(double seconds)
    {
        CurrentTime = seconds;
        OnEvent?.Invoke(new PlaybackEvent.Time(seconds, Duration));
    }

    public void PrepareNext(Track? track) { }
}
