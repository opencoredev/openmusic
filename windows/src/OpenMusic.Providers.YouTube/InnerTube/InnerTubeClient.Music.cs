using System.Text.Json;
using System.Text.Json.Nodes;
using OpenMusic.Core;
using OpenMusic.Providers.YouTube.Json;
using OpenMusic.Providers.YouTube.Parsing;
using OpenMusic.Providers.YouTube.Playback;

namespace OpenMusic.Providers.YouTube.InnerTube;

/// <summary>A playlist write (Swift: <c>PlaylistEdit</c>).</summary>
public abstract record PlaylistEdit
{
    public sealed record Add(string VideoId) : PlaylistEdit;
    public sealed record Remove(string VideoId, string SetVideoId) : PlaylistEdit;
}

/// <summary>YouTube Music operations (Swift: InnerTubeClient+Music.swift). Raw JSON stays here; only models leave.</summary>
public sealed partial class InnerTubeClient
{
    // MARK: Browse

    public async Task<IReadOnlyList<Shelf>> HomeAsync(CancellationToken ct = default)
    {
        var root = await BrowseAsync("FEmusic_home", cancellationToken: ct).ConfigureAwait(false);
        var shelves = PageParser.Shelves(root);
        var token = PageParser.SectionsContinuation(root);
        var pages = 0;
        // Signed-out home is short; signed-in home pages in more shelves on scroll. Load a few pages up front.
        while (token != null && pages < 4 && shelves.Count < 18)
        {
            root = await BrowseContinuationAsync(token, cancellationToken: ct).ConfigureAwait(false);
            shelves.AddRange(PageParser.Shelves(root));
            token = PageParser.SectionsContinuation(root);
            pages++;
        }
        return UniqueIds(shelves, "home");
    }

    public async Task<IReadOnlyList<Shelf>> ExploreAsync(CancellationToken ct = default)
    {
        var explorePage = ShelvesAsync("FEmusic_explore", ct);
        var chartsPage = ShelvesAsync("FEmusic_charts", ct);
        static bool Skip(Shelf shelf)
        {
            var t = shelf.Title.ToLowerInvariant();
            // The untitled grid at the top only links to New releases / Charts / Moods / Podcasts.
            return t.Length == 0 || t.Contains("podcast", StringComparison.Ordinal) || t.Contains("episode", StringComparison.Ordinal);
        }
        List<Shelf> charts;
        try { charts = await chartsPage.ConfigureAwait(false); }
        catch (Exception e) when (e is not OperationCanceledException) { charts = []; }
        var shelves = (await explorePage.ConfigureAwait(false)).Where(s => !Skip(s)).ToList();
        shelves.AddRange(charts.Where(s => !Skip(s)));
        return UniqueIds(shelves, "explore");
    }

    async Task<List<Shelf>> ShelvesAsync(string browseId, CancellationToken ct) =>
        PageParser.Shelves(await BrowseAsync(browseId, cancellationToken: ct).ConfigureAwait(false));

    public async Task<Shelf> ShelfAsync(string moreToken, CancellationToken ct = default)
    {
        if (MoreToken.Parse(moreToken) is not { } token) throw ProviderException.NotFound();
        if (token.BrowseId.StartsWith("VL", StringComparison.Ordinal))
        {
            var detail = await PlaylistAsync(ItemParser.PlaylistIdFromBrowseId(token.BrowseId), ct: ct).ConfigureAwait(false);
            return new Shelf("more-" + moreToken, detail.Playlist.Title, ShelfStyle.TrackList,
                detail.Tracks.Select(t => (MediaItem)new MediaItem.TrackItem(t)).ToList());
        }
        var root = await BrowseAsync(token.BrowseId, token.Params, cancellationToken: ct).ConfigureAwait(false);
        return PageParser.ExpandedShelf(root, moreToken);
    }

    internal static List<Shelf> UniqueIds(IReadOnlyList<Shelf> shelves, string prefix) =>
        shelves.Select((shelf, i) => shelf with { Id = $"{prefix}-{i}-{shelf.Title}" }).ToList();

    // MARK: Search

    public static string? SearchParams(SearchScope scope) => scope switch
    {
        SearchScope.Songs => "EgWKAQIIAWoMEA4QChADEAQQCRAF",
        SearchScope.Albums => "EgWKAQIYAWoMEA4QChADEAQQCRAF",
        SearchScope.Artists => "EgWKAQIgAWoMEA4QChADEAQQCRAF",
        SearchScope.Playlists => "Eg-KAQwIABAAGAAgACgBMABqChAEEAMQCRAFEAo%3D",
        _ => null,
    };

    public async Task<SearchResults> SearchAsync(string query, SearchScope scope, CancellationToken ct = default)
    {
        var body = new JsonObject { ["query"] = query };
        if (SearchParams(scope) is { } p) body["params"] = p;
        var root = await PostAsync("search", body, cacheable: true, cancellationToken: ct).ConfigureAwait(false);
        return PageParser.Search(root, scope);
    }

    public async Task<SearchSuggestions> SuggestionsAsync(string query, CancellationToken ct = default)
    {
        var root = await PostAsync("music/get_search_suggestions", new JsonObject { ["input"] = query }, cacheable: true, cancellationToken: ct).ConfigureAwait(false);
        return new SearchSuggestions(PageParser.Suggestions(root), PageParser.SuggestionItems(root));
    }

    /// <summary>The song as the watch queue describes it, whose byline links the artist and the album.</summary>
    public async Task<Track?> LinkedTrackAsync(string videoId, CancellationToken ct = default)
    {
        var root = await PostAsync("next", new JsonObject { ["videoId"] = videoId, ["isAudioOnly"] = true }, authenticated: false, cacheable: true, cancellationToken: ct).ConfigureAwait(false);
        return PageParser.ParseWatchNext(root).Tracks.FirstOrDefault(t => t.ProviderID == videoId);
    }

    // MARK: Entities

    public async Task<AlbumDetail> AlbumAsync(string id, CancellationToken ct = default) =>
        PageParser.Album(await BrowseAsync(id, cancellationToken: ct).ConfigureAwait(false), id);

    public async Task<ArtistDetail> ArtistAsync(string id, CancellationToken ct = default)
    {
        var browseId = ItemParser.NormalizeArtistId(id);
        return PageParser.Artist(await BrowseAsync(browseId, cancellationToken: ct).ConfigureAwait(false), browseId);
    }

    /// <param name="uncached">Never read from or written to the response cache (the reads a playlist edit compares).</param>
    public async Task<PlaylistDetail> PlaylistAsync(string id, bool uncached = false, CancellationToken ct = default)
    {
        if (id.StartsWith("category:", StringComparison.Ordinal)) return await CategoryPlaylistAsync(id["category:".Length..], ct).ConfigureAwait(false);
        var playlistId = ItemParser.PlaylistIdFromBrowseId(id);
        var cacheable = !uncached && !IsSignedIn;
        if (!playlistId.StartsWith("RD", StringComparison.Ordinal))
        {
            return PageParser.Playlist(await BrowseAsync("VL" + playlistId, cacheable: cacheable, cancellationToken: ct).ConfigureAwait(false), playlistId);
        }
        // Generated mixes (RDTMAK…, RDCLAK…) sometimes come back empty for a given visitor id; retry once without it,
        // then fall back to reading the mix as a watch queue.
        bool[] attempts = [true, false, false];
        for (var attempt = 0; attempt < attempts.Length; attempt++)
        {
            if (attempt == 2) await Task.Delay(400, ct).ConfigureAwait(false);
            try
            {
                var detail = PageParser.Playlist(await BrowseAsync("VL" + playlistId, cacheable: cacheable, sendVisitor: attempts[attempt], cancellationToken: ct).ConfigureAwait(false), playlistId);
                if (detail.Tracks.Count > 0) return detail;
            }
            catch (Exception e) when (e is ProviderException)
            {
            }
            if (IsSignedIn) break; // signed-in mixes are personal; the visitor id isn't the problem
        }
        var queue = await WatchQueueAsync(null, playlistId, null, ct).ConfigureAwait(false);
        if (queue.Count == 0) queue = await WatchQueueAsync(null, playlistId, "wAEB", ct).ConfigureAwait(false);
        // YouTube occasionally generates nothing for a mix; report it so the UI can offer a retry.
        if (queue.Count == 0) throw ProviderException.Network("YouTube Music returned an empty mix. Try again.");
        var playlist = new Playlist
        {
            ProviderID = playlistId, Provider = ProviderId.YouTubeMusic, Title = "Mix", Owner = "YouTube Music", Artwork = queue[0].Artwork, TrackCount = queue.Count,
        };
        return new PlaylistDetail(playlist, queue);
    }

    /// <summary>Moods &amp; genres: the category's first playlist; the full list is available via <see cref="ShelfAsync"/>.</summary>
    async Task<PlaylistDetail> CategoryPlaylistAsync(string token, CancellationToken ct)
    {
        var shelf = await ShelfAsync(token, ct).ConfigureAwait(false);
        var first = shelf.Items.OfType<MediaItem.PlaylistItem>().Select(p => p.Playlist).FirstOrDefault(p => !p.Extra.ContainsKey("category"))
            ?? throw ProviderException.NotFound();
        return await PlaylistAsync(first.ProviderID, ct: ct).ConfigureAwait(false);
    }

    public async Task<Page<Track>> PlaylistTracksAsync(string continuation, bool uncached = false, CancellationToken ct = default)
    {
        var root = await BrowseContinuationAsync(continuation, cacheable: !uncached && !IsSignedIn, cancellationToken: ct).ConfigureAwait(false);
        var (items, next) = PageParser.ContinuationItems(root);
        return new Page<Track>(items.OfType<MediaItem.TrackItem>().Select(t => t.Track).ToList()) { Continuation = next };
    }

    // MARK: Library

    public static string LibraryBrowseId(LibraryKind kind) => kind switch
    {
        LibraryKind.LikedSongs => "VLLM",
        LibraryKind.Songs => "FEmusic_liked_videos",
        LibraryKind.Albums => "FEmusic_liked_albums",
        LibraryKind.Artists => "FEmusic_library_corpus_track_artists",
        LibraryKind.Playlists => "FEmusic_liked_playlists",
        LibraryKind.RecentlyPlayed => "FEmusic_history",
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };

    public async Task<Page<MediaItem>> LibraryAsync(LibraryKind kind, string? continuation, CancellationToken ct = default)
    {
        if (!IsSignedIn) throw ProviderException.NotSignedIn();
        if (continuation != null)
        {
            var croot = await BrowseContinuationAsync(continuation, cacheable: false, cancellationToken: ct).ConfigureAwait(false);
            var (items, next) = PageParser.ContinuationItems(croot);
            return new Page<MediaItem>(items) { Continuation = next };
        }
        var root = await BrowseAsync(LibraryBrowseId(kind), cacheable: false, cancellationToken: ct).ConfigureAwait(false);
        if (kind == LibraryKind.LikedSongs)
        {
            var detail = PageParser.Playlist(root, "LM");
            return new Page<MediaItem>(detail.Tracks.Select(t => (MediaItem)new MediaItem.TrackItem(t)).ToList()) { Continuation = detail.Continuation };
        }
        var page = PageParser.LibraryPage(root);
        if (kind == LibraryKind.Playlists)
        {
            // Drop the "New playlist" tile and keep real playlists.
            page = page with { Items = page.Items.Where(i => i is MediaItem.PlaylistItem).ToList() };
        }
        return page;
    }

    // MARK: Mutations (signed in)

    async Task<JsonObject> MutateAsync(string endpoint, JsonObject body, WriteBinding? binding, CancellationToken ct)
    {
        if (!IsSignedIn) throw ProviderException.NotSignedIn();
        var result = await PostAsync(endpoint, body, binding: binding, idempotent: false, cancellationToken: ct).ConfigureAwait(false);
        ClearCache();
        return result;
    }

    /// <param name="binding">Sent only with the credentials it names (<see cref="CheckWriteBinding"/>); null: whatever is current.</param>
    public async Task RateVideoAsync(string videoId, bool like, WriteBinding? binding = null, CancellationToken ct = default) =>
        await MutateAsync(like ? "like/like" : "like/removelike", new JsonObject { ["target"] = new JsonObject { ["videoId"] = videoId } }, binding, ct).ConfigureAwait(false);

    public async Task RatePlaylistAsync(string playlistId, bool like, WriteBinding? binding = null, CancellationToken ct = default) =>
        await MutateAsync(like ? "like/like" : "like/removelike", new JsonObject { ["target"] = new JsonObject { ["playlistId"] = playlistId } }, binding, ct).ConfigureAwait(false);

    public async Task SubscribeAsync(string channelId, bool subscribe, WriteBinding? binding = null, CancellationToken ct = default) =>
        await MutateAsync(subscribe ? "subscription/subscribe" : "subscription/unsubscribe", new JsonObject { ["channelIds"] = new JsonArray(channelId) }, binding, ct).ConfigureAwait(false);

    public async Task<bool> IsLikedAsync(string videoId, CancellationToken ct = default)
    {
        if (!IsSignedIn) throw ProviderException.NotSignedIn();
        var root = await PostAsync("next", new JsonObject { ["videoId"] = videoId, ["isAudioOnly"] = true }, cancellationToken: ct).ConfigureAwait(false);
        return PageParser.ParseWatchNext(root).LikeStatus == "LIKE";
    }

    public async Task<string> CreatePlaylistAsync(string title, string? description, IReadOnlyList<string>? videoIds = null, WriteBinding? binding = null, CancellationToken ct = default)
    {
        var body = new JsonObject { ["title"] = title, ["description"] = description ?? "", ["privacyStatus"] = "PRIVATE" };
        if (videoIds is { Count: > 0 }) body["videoIds"] = new JsonArray(videoIds.Select(v => (JsonNode?)v).ToArray());
        var root = await MutateAsync("playlist/create", body, binding, ct).ConfigureAwait(false);
        return root.S("playlistId") ?? throw ProviderException.Decoding("playlist/create returned no id");
    }

    /// <summary><paramref name="binding"/>: sent only with the cookies of the account it was checked for.</summary>
    public async Task EditPlaylistAsync(string playlistId, IReadOnlyList<PlaylistEdit> edits, WriteBinding? binding = null, CancellationToken ct = default)
    {
        var actions = new JsonArray();
        foreach (var edit in edits)
        {
            actions.Add((JsonNode)(edit switch
            {
                PlaylistEdit.Add a => new JsonObject { ["action"] = "ACTION_ADD_VIDEO", ["addedVideoId"] = a.VideoId, ["dedupeOption"] = "DEDUPE_OPTION_SKIP" },
                PlaylistEdit.Remove r => new JsonObject { ["action"] = "ACTION_REMOVE_VIDEO", ["removedVideoId"] = r.VideoId, ["setVideoId"] = r.SetVideoId },
                _ => throw new ArgumentException("unknown edit", nameof(edits)),
            }));
        }
        var root = await MutateAsync("browse/edit_playlist",
            new JsonObject { ["playlistId"] = ItemParser.PlaylistIdFromBrowseId(playlistId), ["actions"] = actions }, binding, ct).ConfigureAwait(false);
        if (root.S("status") is { } status && status != "STATUS_SUCCEEDED") throw ProviderException.Server(200, status);
    }

    // MARK: Watch next: radio, lyrics

    public async Task<List<Track>> WatchQueueAsync(string? videoId, string? playlistId, string? @params, CancellationToken ct = default)
    {
        var body = new JsonObject { ["isAudioOnly"] = true, ["enablePersistentPlaylistPanel"] = true, ["tunerSettingValue"] = "AUTOMIX_SETTING_NORMAL" };
        if (videoId != null) body["videoId"] = videoId;
        if (playlistId != null) body["playlistId"] = playlistId;
        if (@params != null) body["params"] = @params;
        var root = await PostAsync("next", body, cacheable: true, cancellationToken: ct).ConfigureAwait(false);
        return PageParser.ParseWatchNext(root).Tracks;
    }

    /// <summary>"Up next" for a song: its radio (<c>RDAMVM&lt;videoId&gt;</c>), without the seed itself.</summary>
    public async Task<IReadOnlyList<Track>> RadioForVideoAsync(string videoId, CancellationToken ct = default)
    {
        var tracks = await WatchQueueAsync(videoId, "RDAMVM" + videoId, "wAEB", ct).ConfigureAwait(false);
        return tracks.Where(t => t.ProviderID != videoId).ToList();
    }

    /// <summary>Radio from an artist (<c>UC…</c> or its <c>RDEM…</c> seed) or a playlist id.</summary>
    public async Task<IReadOnlyList<Track>> RadioForSeedAsync(string seedId, CancellationToken ct = default)
    {
        var playlistId = seedId;
        if (seedId.StartsWith("UC", StringComparison.Ordinal) || seedId.StartsWith("MPLA", StringComparison.Ordinal))
        {
            playlistId = (await ArtistAsync(seedId, ct).ConfigureAwait(false)).RadioSeed ?? throw ProviderException.NotFound();
        }
        else if (seedId.StartsWith("VL", StringComparison.Ordinal))
        {
            playlistId = "RDAMPL" + seedId[2..];
        }
        else if (!seedId.StartsWith("RD", StringComparison.Ordinal))
        {
            playlistId = "RDAMPL" + seedId;
        }
        return await WatchQueueAsync(null, playlistId, "wAEB", ct).ConfigureAwait(false);
    }

    /// <summary>YouTube's own lyrics: timed from the Android client when it has them, else the web client's plain text.</summary>
    public async Task<Lyrics?> LyricsAsync(string videoId, CancellationToken ct = default)
    {
        var next = await PostAsync("next", new JsonObject { ["videoId"] = videoId, ["isAudioOnly"] = true }, authenticated: false, cacheable: true, cancellationToken: ct).ConfigureAwait(false);
        if (PageParser.ParseWatchNext(next).LyricsBrowseId is not { } browseId) return null;
        // The Android app gets timed lyrics for the same browse id; the web client only gets plain text.
        try
        {
            var timed = await PostAsync("browse", new JsonObject { ["browseId"] = browseId }, InnerTubeProfile.AndroidMusic, authenticated: false, cacheable: true, cancellationToken: ct).ConfigureAwait(false);
            if (PageParser.Lyrics(timed) is { IsSynced: true } lyrics) return lyrics;
        }
        catch (ProviderException)
        {
        }
        var plain = await PostAsync("browse", new JsonObject { ["browseId"] = browseId }, authenticated: false, cacheable: true, cancellationToken: ct).ConfigureAwait(false);
        return PageParser.Lyrics(plain);
    }

    // MARK: Account

    public async Task<AccountInfo> AccountAsync(CancellationToken ct = default)
    {
        if (!IsSignedIn) throw ProviderException.NotSignedIn();
        var root = await PostAsync("account/account_menu", new JsonObject(), cancellationToken: ct).ConfigureAwait(false);
        return PageParser.Account(root) ?? throw ProviderException.NotSignedIn();
    }

    // MARK: Diagnostics

    public async Task<string> RawRequestAsync(string endpoint, string bodyJson, CancellationToken ct = default)
    {
        JsonObject body;
        try { body = JsonNav.Parse(bodyJson) as JsonObject ?? new JsonObject(); }
        catch (JsonException) { body = new JsonObject(); }
        var root = await PostAsync(endpoint, body, cancellationToken: ct).ConfigureAwait(false);
        return root.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
    }

    // MARK: Player

    public async Task<PlayerInfo> PlayerAsync(string videoId, InnerTubeProfile profile, CancellationToken ct = default)
    {
        var root = await PostAsync("player", new JsonObject { ["videoId"] = videoId, ["contentCheckOk"] = true, ["racyCheckOk"] = true },
            profile, authenticated: false, cancellationToken: ct).ConfigureAwait(false);
        return new PlayerInfo(root);
    }
}
