using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using OpenMusic.App.Services;
using OpenMusic.Core;
using OpenMusic.Core.Support;

namespace OpenMusic.App.ViewModels;

// One view model per screen. Each loads through BrowseCache, so coming back to a screen draws it at once with no
// spinner. Home and New also come from the disk cache at launch and refresh behind it. A load that fails says so in
// the shell's InfoBar (with Try Again, or Sign In for library pages), never in a dialog. All run on the UI thread.

public abstract partial class PageViewModel : ObservableObject
{
    protected static AppServices Services => App.Services;
    protected static IMusicProvider Provider => App.Services.Provider;

    [ObservableProperty] public partial bool IsLoading { get; set; }
    [ObservableProperty] public partial string? Error { get; set; }
    /// <summary>The page needs a YouTube Music sign-in to show anything.</summary>
    [ObservableProperty] public partial bool NeedsSignIn { get; set; }

    /// <summary>What Try Again runs: the page's last load.</summary>
    protected Func<Task>? Retry { get; set; }

    protected async Task Run(Func<Task> load, string what)
    {
        Retry = () => Run(load, what);
        Error = null;
        NeedsSignIn = false;
        IsLoading = true;
        try
        {
            await load();
            ShellPage.Current?.ClearPageError();
        }
        catch (ProviderException e) when (e.Kind == ProviderErrorKind.NotSignedIn)
        {
            NeedsSignIn = true;
            ShellPage.Current?.ShowPageError("Sign in to YouTube Music", $"Sign in to see your {what}.", "Sign In",
                () => { ShellPage.Current.SignInToYouTube(); return Task.CompletedTask; });
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception e)
        {
            Error = e.Message;
            Log.Error($"page load ({what}): {e.GetType().Name}: {e.Message}");
            ShellPage.Current?.ShowPageError($"Couldn't load {what}", Friendly(e), "Try Again", Retry);
        }
        finally
        {
            IsLoading = false;
        }
    }

    public static string Friendly(Exception e) => e switch
    {
        ProviderException { Kind: ProviderErrorKind.Network } or HttpRequestException => "Check your internet connection.",
        ProviderException { Kind: ProviderErrorKind.RateLimited } => $"YouTube Music asked {ProductInfo.Name} to slow down. Try again in a minute.",
        _ => e.Message,
    };

    protected static bool SignedOutLibrary => !Provider.IsSignedIn;
}

/// <summary>Home and New: a column of shelves, drawn from the cache first and refreshed behind it.</summary>
public sealed partial class ShelvesViewModel : PageViewModel
{
    [ObservableProperty] public partial IReadOnlyList<ShelfModel> Shelves { get; set; } = [];
    /// <summary>The shelves shown came from disk and a refresh is running.</summary>
    [ObservableProperty] public partial bool IsRefreshing { get; set; }

    private int _request;

    public Task LoadAsync(string kind) => Run(async () =>
    {
        var request = ++_request;
        var key = $"shelves:{kind}";
        if (Services.Cache.TryGet<List<ShelfModel>>(key, out var memory))
        {
            Shelves = memory;
            return;
        }
        var session = Provider.Session;
        var page = kind == "new" ? "new" : "home";
        // From disk at once (off the UI thread: it's a few hundred kB of JSON).
        var saved = await Task.Run(() => Services.DiskCache.Load(page, Provider.Id, session));
        if (request != _request) return;
        if (saved is not null && Provider.Session == session)
        {
            Shelves = saved.Select(s => new ShelfModel(s)).ToList();
            IsRefreshing = true;
        }
        try
        {
            var fresh = kind == "new" ? await Provider.ExploreAsync() : await Provider.HomeAsync();
            if (request != _request) return;
            // Keep only what came back for the account that is still current.
            if (Provider.Session != session || session.Identity.Kind == SessionIdentityKind.Changing) return;
            var models = fresh.Select(s => new ShelfModel(s)).ToList();
            Services.Cache.Set(key, models);
            if (saved is null || !SameShelves(saved, fresh)) Shelves = models;
            // Saved under the session it came back for; a session that ended meanwhile writes nothing (its files are gone).
            var provider = Provider;
            var cache = Services.DiskCache;
            _ = Task.Run(() =>
            {
                if (provider.Session == session) cache.Save(page, provider.Id, session, fresh);
            });
        }
        catch (Exception) when (saved is not null)
        {
            // Offline with something saved: keep showing it, and say it may be old.
            ShellPage.Current?.ShowPageError($"Couldn't refresh {(kind == "new" ? "New" : "Home")}", "Showing what was saved. Check your internet connection.", "Try Again", Retry);
            throw new OperationCanceledException();
        }
        finally
        {
            if (request == _request) IsRefreshing = false;
        }
    }, kind == "new" ? "New" : "Home");

    private static bool SameShelves(IReadOnlyList<Shelf> a, IReadOnlyList<Shelf> b) =>
        a.Count == b.Count && a.Zip(b).All(p => p.First.Title == p.Second.Title && p.First.Items.Count == p.Second.Items.Count
            && p.First.Items.Zip(p.Second.Items).All(i => i.First.Id == i.Second.Id));
}

public sealed partial class AlbumViewModel : PageViewModel
{
    [ObservableProperty] public partial Album? Album { get; set; }
    [ObservableProperty] public partial string Title { get; set; } = "";
    [ObservableProperty] public partial string ArtistName { get; set; } = "";
    [ObservableProperty] public partial string Meta { get; set; } = "";
    [ObservableProperty] public partial Uri? Artwork { get; set; }
    [ObservableProperty] public partial string Footnote { get; set; } = "";
    [ObservableProperty] public partial string Summary { get; set; } = "";
    [ObservableProperty] public partial IReadOnlyList<TrackRow> Tracks { get; set; } = [];
    [ObservableProperty] public partial ShelfModel? MoreByArtist { get; set; }

    public PlaybackContext? Context => Album is { } a ? PlaybackContext.ForAlbum(a) : null;

    /// <summary>The header's Play / Pause button.</summary>
    public ListPlayState PlayState { get; }

    public AlbumViewModel() => PlayState = new ListPlayState(() => Tracks.Select(t => t.Track.Id).ToHashSet(), Play);

    public Task LoadAsync(string id) => Run(async () =>
    {
        var detail = await Services.Cache.GetAsync($"album:{id}", () => Provider.AlbumAsync(id));
        var a = detail.Album;
        Album = a;
        Title = a.Title;
        ArtistName = a.ArtistLine;
        Artwork = a.Artwork?.Url(600);
        var genre = a.Extra.GetValueOrDefault("genre");
        var minutes = (int)(detail.Tracks.Sum(t => t.Duration ?? 0) / 60);
        Meta = string.Join(" · ", new[] { Format.AlbumKind(a.Kind), genre, a.Year?.ToString(System.Globalization.CultureInfo.InvariantCulture),
            detail.Tracks.Count > 0 ? $"{detail.Tracks.Count} song{(detail.Tracks.Count == 1 ? "" : "s")}, {minutes} min" : null }.Where(x => !string.IsNullOrEmpty(x)));
        Summary = detail.Summary ?? "";
        Footnote = detail.Footnote ?? "";
        Tracks = detail.Tracks.Select((t, i) => new TrackRow(t, i, showNumber: true) { ShowArtist = t.ArtistLine != a.ArtistLine }).ToList();
        MoreByArtist = detail.MoreByArtist.Count == 0 ? null
            : ShelfModel.Of($"more-{id}", $"More by {a.Artists.FirstOrDefault()?.Name ?? a.ArtistLine}", ShelfStyle.Carousel, detail.MoreByArtist.Select(MediaItem.Of));
        OnPropertyChanged(nameof(Context));
        PlayState.Update();
    }, "this album");

    [RelayCommand]
    public void Play() => Services.Player.Play(Tracks.Select(t => t.Track).ToList(), shuffled: false, context: Context);

    [RelayCommand]
    public void Shuffle() => Services.Player.Play(Tracks.Select(t => t.Track).ToList(), shuffled: true, context: Context);

    public void OpenArtist()
    {
        if (Album?.Artists.FirstOrDefault(a => a.Id is not null)?.Id is { } id) ShellPage.Current.Navigate("artist", id);
    }
}

public sealed partial class ArtistViewModel : PageViewModel
{
    [ObservableProperty] public partial Artist? Artist { get; set; }
    [ObservableProperty] public partial string Name { get; set; } = "";
    [ObservableProperty] public partial string Subtitle { get; set; } = "";
    [ObservableProperty] public partial Uri? Artwork { get; set; }
    [ObservableProperty] public partial string Bio { get; set; } = "";
    [ObservableProperty] public partial IReadOnlyList<TrackRow> TopTracks { get; set; } = [];
    [ObservableProperty] public partial IReadOnlyList<ShelfModel> Shelves { get; set; } = [];
    [ObservableProperty] public partial bool HasRadio { get; set; }
    private string? _radioSeed;

    public PlaybackContext? Context => Artist is { } a ? PlaybackContext.ForArtist(a) : null;

    public Task LoadAsync(string id) => Run(async () =>
    {
        var detail = await Services.Cache.GetAsync($"artist:{id}", () => Provider.ArtistAsync(id));
        Artist = detail.Artist;
        Name = detail.Artist.Name;
        // The header already says "Artist" above the name: the line under it is for real details only.
        Subtitle = detail.Artist.Subtitle is { } sub && !sub.Equals("Artist", StringComparison.OrdinalIgnoreCase) ? sub : "";
        Artwork = detail.Artist.Artwork?.Url(900);
        Bio = detail.Bio ?? "";
        _radioSeed = detail.RadioSeed;
        HasRadio = _radioSeed is not null;
        TopTracks = detail.TopTracks.Take(10).Select((t, i) => new TrackRow(t, i)).ToList();
        var shelves = new List<ShelfModel>();
        if (detail.Albums.Count > 0) shelves.Add(ShelfModel.Of("albums", "Albums", ShelfStyle.Carousel, detail.Albums.Select(MediaItem.Of)));
        if (detail.Singles.Count > 0) shelves.Add(ShelfModel.Of("singles", "Singles & EPs", ShelfStyle.Carousel, detail.Singles.Select(MediaItem.Of)));
        if (detail.AppearsOn.Count > 0) shelves.Add(ShelfModel.Of("appears", "Appears On", ShelfStyle.Carousel, detail.AppearsOn.Select(MediaItem.Of)));
        if (detail.Playlists.Count > 0) shelves.Add(ShelfModel.Of("playlists", "Featured On", ShelfStyle.Carousel, detail.Playlists.Select(MediaItem.Of)));
        if (detail.Related.Count > 0) shelves.Add(ShelfModel.Of("related", "Similar Artists", ShelfStyle.Artists, detail.Related.Select(MediaItem.Of)));
        Shelves = shelves;
        OnPropertyChanged(nameof(Context));
    }, "this artist");

    [RelayCommand]
    public void Play() => Services.Player.Play(TopTracks.Select(t => t.Track).ToList(), shuffled: false, context: Context);

    [RelayCommand]
    public async Task Radio()
    {
        if (_radioSeed is { } seed && Artist is { } a) await MediaMenus.StartSeedRadioAsync(seed, a.Name, a.Artwork?.Url(300), "artist");
    }
}

/// <summary>A playlist: the first page at once, the rest through <see cref="PlaylistPager"/> (each song once).</summary>
public sealed partial class PlaylistViewModel : PageViewModel
{
    [ObservableProperty] public partial Playlist? Playlist { get; set; }
    [ObservableProperty] public partial string Title { get; set; } = "";
    [ObservableProperty] public partial string Owner { get; set; } = "";
    [ObservableProperty] public partial string Summary { get; set; } = "";
    [ObservableProperty] public partial string Meta { get; set; } = "";
    [ObservableProperty] public partial Uri? Artwork { get; set; }
    [ObservableProperty] public partial bool IsLoadingMore { get; set; }

    /// <summary>The rows, appended to as pages arrive (the list is bound to it).</summary>
    public System.Collections.ObjectModel.ObservableCollection<TrackRow> Tracks { get; } = [];

    private PlaylistPager? _pager;
    private string? _id;
    private int _generation;

    public PlaybackContext? Context => Playlist is { } p ? PlaybackContext.ForPlaylist(p) : null;

    /// <summary>The header's Play / Pause button.</summary>
    public ListPlayState PlayState { get; }

    public PlaylistViewModel()
    {
        PlayState = new ListPlayState(() => Tracks.Select(t => t.Track.Id).ToHashSet(), Play);
        Tracks.CollectionChanged += (_, _) => PlayState.Update();
    }

    public Task LoadAsync(string id) => Run(async () =>
    {
        var generation = ++_generation;
        _id = id;
        var (info, pager) = await Services.Cache.GetAsync($"playlist:{id}", async () =>
        {
            var detail = await Provider.PlaylistAsync(id);
            return (detail.Playlist, new PlaylistPager(detail));
        });
        if (generation != _generation) return;
        _pager = pager;
        Apply(info);
        Tracks.Clear();
        for (var i = 0; i < pager.Tracks.Count; i++) Tracks.Add(new TrackRow(pager.Tracks[i], i));
        UpdateMeta();
        // Short playlists load whole (a few requests) so the header can give their length.
        while (generation == _generation && (pager.WantsEagerPage || pager.WantsEmptyPage))
            await LoadMoreCore(eager: pager.WantsEagerPage, empty: pager.WantsEmptyPage);
    }, "this playlist");

    private void Apply(Playlist p)
    {
        Playlist = p;
        Title = p.Title;
        Owner = p.Owner ?? "";
        Summary = p.Summary ?? "";
        Artwork = p.Artwork?.Url(600);
        OnPropertyChanged(nameof(Context));
    }

    private void UpdateMeta()
    {
        if (_pager is not { } pager) return;
        var seconds = pager.Tracks.Sum(t => (t.Duration ?? 0) * pager.Copies.GetValueOrDefault(t.Id, 1));
        Meta = pager.IsComplete || pager.KnownTotal is null
            ? Format.Songs(pager.EntryTotal, seconds)
            : $"{pager.EntryTotal} songs";
    }

    /// <summary>The list scrolled near its end: the next page.</summary>
    public async Task LoadMoreAsync()
    {
        if (_pager is not { HasMore: true, IsLoading: false }) return;
        await LoadMoreCore(eager: false, empty: false);
    }

    private async Task LoadMoreCore(bool eager, bool empty)
    {
        if (_pager is not { } pager) return;
        var generation = _generation;
        IsLoadingMore = true;
        var before = pager.Tracks.Count;
        await pager.LoadNextAsync((token, ct) => Provider.PlaylistTracksAsync(token, ct), eager, empty);
        IsLoadingMore = false;
        if (generation != _generation) return;
        for (var i = before; i < pager.Tracks.Count; i++) Tracks.Add(new TrackRow(pager.Tracks[i], i));
        UpdateMeta();
        if (pager.Error is { } error)
            ShellPage.Current?.ShowPageError("Couldn't load more of this playlist", error, "Try Again", async () =>
            {
                pager.ClearError();
                await LoadMoreAsync();
            });
    }

    /// <summary>After Remove from Playlist: the playlist as the service has it now.</summary>
    public async Task ReloadAsync()
    {
        if (_id is not { } id) return;
        Services.Cache.Remove($"playlist:{id}");
        await LoadAsync(id);
    }

    [RelayCommand]
    public void Play() => Services.Player.Play(Tracks.Select(t => t.Track).ToList(), shuffled: false, context: Context);

    [RelayCommand]
    public void Shuffle() => Services.Player.Play(Tracks.Select(t => t.Track).ToList(), shuffled: true, context: Context);

    [RelayCommand]
    public async Task Radio()
    {
        if (Playlist is { } p) await MediaMenus.StartSeedRadioAsync(p.ProviderID, p.Title, p.Artwork?.Url(300));
    }
}

public sealed partial class SearchViewModel : PageViewModel
{
    [ObservableProperty] public partial string Query { get; set; } = "";
    [ObservableProperty] public partial CardItem? Top { get; set; }
    [ObservableProperty] public partial IReadOnlyList<TrackRow> Songs { get; set; } = [];
    [ObservableProperty] public partial IReadOnlyList<ShelfModel> Shelves { get; set; } = [];
    [ObservableProperty] public partial bool IsEmpty { get; set; }

    private int _request;

    public Task LoadAsync(string query, SearchScope scope) => Run(async () =>
    {
        var request = ++_request;
        Query = query;
        // "shelf:<token>": a shelf's See All, or a mood's playlists.
        if (query.StartsWith("shelf:", StringComparison.Ordinal))
        {
            var token = query["shelf:".Length..];
            var shelf = await Services.Cache.GetAsync(query, () => Provider.ShelfAsync(token));
            if (request != _request) return;
            Query = shelf.Title;
            Top = null;
            if (shelf.Style == ShelfStyle.TrackList)
            {
                Songs = shelf.Items.OfType<MediaItem.TrackItem>().Select((t, i) => new TrackRow(t.Track, i)).ToList();
                Shelves = [];
            }
            else
            {
                Songs = [];
                Shelves = [new ShelfModel(shelf)];
            }
            IsEmpty = shelf.Items.Count == 0;
            return;
        }
        var started = System.Diagnostics.Stopwatch.StartNew();
        var results = await Services.Cache.GetAsync($"search:{scope}:{query}", () => Provider.SearchAsync(query, scope));
        if (request != _request) return;
        Log.Info($"timing: search ({scope}) answered in {started.ElapsedMilliseconds} ms");
        Top = results.Top is { } top && scope == SearchScope.All ? new CardItem(top) : null;
        Songs = results.Tracks.Take(scope == SearchScope.Songs ? 50 : 8).Select((t, i) => new TrackRow(t, i)).ToList();
        var shelves = new List<ShelfModel>();
        if (results.Artists.Count > 0) shelves.Add(ShelfModel.Of("artists", "Artists", ShelfStyle.Artists, results.Artists.Select(MediaItem.Of)));
        if (results.Albums.Count > 0) shelves.Add(ShelfModel.Of("albums", "Albums", ShelfStyle.Carousel, results.Albums.Select(MediaItem.Of)));
        if (results.Playlists.Count > 0) shelves.Add(ShelfModel.Of("playlists", "Playlists", ShelfStyle.Carousel, results.Playlists.Select(MediaItem.Of)));
        Shelves = shelves;
        IsEmpty = results.IsEmpty;
    }, "results");
}

/// <summary>Library lists: songs, liked songs, albums, artists, recently added. Need a YouTube Music sign-in.</summary>
public sealed partial class LibraryViewModel : PageViewModel
{
    [ObservableProperty] public partial IReadOnlyList<TrackRow> Songs { get; set; } = [];
    [ObservableProperty] public partial IReadOnlyList<CardItem> Cards { get; set; } = [];
    [ObservableProperty] public partial string Summary { get; set; } = "";

    private static string Noun(LibraryKind kind) => kind switch
    {
        LibraryKind.LikedSongs => "liked songs",
        LibraryKind.Songs => "songs",
        LibraryKind.Albums => "albums",
        LibraryKind.Artists => "artists",
        _ => "library",
    };

    public Task LoadSongsAsync(LibraryKind kind) => Run(async () =>
    {
        Songs = [];
        Summary = "";
        if (SignedOutLibrary) throw ProviderException.NotSignedIn();
        var items = await LoadAll(kind);
        var tracks = items.OfType<MediaItem.TrackItem>().Select(t => t.Track).ToList();
        Songs = tracks.Select((t, i) => new TrackRow(t, i)).ToList();
        Summary = Format.Songs(tracks.Count, tracks.Sum(t => t.Duration ?? 0));
    }, Noun(kind));

    public Task LoadCardsAsync(LibraryKind kind, bool newestFirst = false) => Run(async () =>
    {
        Cards = [];
        Summary = "";
        if (SignedOutLibrary) throw ProviderException.NotSignedIn();
        var items = await LoadAll(kind);
        // "Recently Added": the service lists saved albums newest first already for YouTube; the mock reverses.
        Cards = (newestFirst && Services.IsDemo ? Enumerable.Reverse(items) : items).Select(i => new CardItem(i)).ToList();
        Summary = $"{Cards.Count} {(kind == LibraryKind.Artists ? "artists" : "albums")}";
    }, Noun(kind));

    private static Task<List<MediaItem>> LoadAll(LibraryKind kind) => Services.Cache.GetAsync($"library:all:{kind}", async () =>
    {
        var all = new List<MediaItem>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        string? next = null;
        var used = new HashSet<string>(StringComparer.Ordinal);
        do
        {
            var page = await Provider.LibraryAsync(kind, next);
            foreach (var item in page.Items) if (seen.Add(item.Id)) all.Add(item);
            next = page.Continuation is { } c && used.Add(c) ? c : null;
        } while (next is not null && all.Count < 5000);
        return all;
    });
}
