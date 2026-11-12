using System.Globalization;
using System.Text.Json.Nodes;
using OpenMusic.Core;
using OpenMusic.Providers.YouTube.Json;

namespace OpenMusic.Providers.YouTube.Parsing;

/// <summary>
/// Turns the InnerTube item renderers YouTube Music uses everywhere into OpenMusic models (Swift: ItemParser.swift).
/// Classification relies on endpoints (watch vs. browse + page type) rather than display text, so it works the same in
/// search, shelves, library grids, playlists and album pages.
/// </summary>
internal static class ItemParser
{
    // MARK: Entry points

    /// <summary>Any supported renderer wrapper (<c>{"musicResponsiveListItemRenderer": {...}}</c> etc.).</summary>
    public static MediaItem? Item(JsonNode? wrapperNode)
    {
        if (wrapperNode is not JsonObject wrapper) return null;
        if (wrapper.Obj("musicResponsiveListItemRenderer") is { } li) return ListItem(li);
        if (wrapper.Obj("musicTwoRowItemRenderer") is { } two) return TwoRowItem(two);
        if (wrapper.Obj("playlistPanelVideoRenderer") is { } pv) return PanelVideo(pv) is { } t ? new MediaItem.TrackItem(t) : null;
        if (wrapper.O("playlistPanelVideoWrapperRenderer", "primaryRenderer", "playlistPanelVideoRenderer") is { } pw)
        {
            return PanelVideo(pw) is { } t ? new MediaItem.TrackItem(t) : null;
        }
        if (wrapper.Obj("musicNavigationButtonRenderer") is { } nav) return Category(nav) is { } p ? new MediaItem.PlaylistItem(p) : null;
        if (wrapper.Obj("musicMultiRowListItemRenderer") is { }) return null; // podcast episodes: skipped
        return null;
    }

    public static List<MediaItem> Items(IEnumerable<JsonNode?> list) => list.Select(Item).OfType<MediaItem>().ToList();

    public static List<Track> Tracks(IEnumerable<JsonNode?> list) =>
        Items(list).OfType<MediaItem.TrackItem>().Select(t => t.Track).ToList();

    // MARK: Subtitle runs

    /// <summary>What could be read out of a "Song • Daft Punk &amp; Todd Edwards • Discovery • 3:47" run list.</summary>
    internal sealed class Meta
    {
        public string? TypeLabel;
        public List<ArtistRef> Artists = [];
        public AlbumRef? Album;
        public double? Duration;
        public int? Year;
        /// <summary>Counts like "1.2B plays", "68.3M monthly audience", "35 songs".</summary>
        public List<string> Stats = [];
        public List<string> Plain = [];
    }

    public static readonly HashSet<string> TypeLabels =
        ["Song", "Video", "Album", "Single", "EP", "Artist", "Playlist", "Episode", "Podcast", "Profile", "Station", "Mix"];

    static string RunText(JsonObject run) => JsonNav.AsString(run.Get("text")) ?? "";

    public static Meta ParseMeta(IReadOnlyList<JsonObject> runs)
    {
        var meta = new Meta();
        var segments = new List<List<JsonObject>> { new() };
        foreach (var run in runs)
        {
            if (YTText.TrimInline(RunText(run)) == "•") { segments.Add([]); continue; }
            segments[^1].Add(run);
        }
        foreach (var segment in segments)
        {
            if (segment.Count == 0) continue;
            var text = YTText.TrimInline(string.Concat(segment.Select(r => JsonNav.AsString(r.Get("text"))).Where(t => t != null)));
            var navigable = segment.Where(r => r.ContainsKey("navigationEndpoint")).ToList();
            if (navigable.Count > 0)
            {
                foreach (var run in navigable)
                {
                    var name = RunText(run);
                    var ep = YTEndpoint.From(run.Obj("navigationEndpoint"));
                    if (ep?.BrowseId is not { } id) { meta.Plain.Add(name); continue; }
                    if (id.StartsWith("MPRE", StringComparison.Ordinal) || ep.BrowsePageType == "MUSIC_PAGE_TYPE_ALBUM")
                    {
                        meta.Album = new AlbumRef(id, name);
                    }
                    else if (id.StartsWith("UC", StringComparison.Ordinal) || id.StartsWith("MPLA", StringComparison.Ordinal) ||
                             ep.BrowsePageType?.Contains("ARTIST", StringComparison.Ordinal) == true)
                    {
                        meta.Artists.Add(new ArtistRef(NormalizeArtistId(id), name));
                    }
                    else
                    {
                        meta.Plain.Add(name);
                    }
                }
                continue;
            }
            if (text.Length == 0) continue;
            if (meta.TypeLabel == null && TypeLabels.Contains(text)) { meta.TypeLabel = text; continue; }
            if (YTText.Duration(text) is { } d) { meta.Duration = d; continue; }
            if (YTText.IsYear(text)) { meta.Year = int.Parse(text, CultureInfo.InvariantCulture); continue; }
            if (IsStat(text)) { meta.Stats.Add(text); continue; }
            meta.Plain.Add(text);
        }
        return meta;
    }

    static readonly string[] StatWords =
        ["plays", "views", "subscribers", "monthly", "audience", "songs", "song", "tracks", "episodes", "watching", "listeners", "likes", "videos", "followers"];

    public static bool IsStat(string text)
    {
        var lower = text.ToLowerInvariant();
        return lower.Length > 0 && char.IsDigit(lower[0]) && StatWords.Any(w => lower.Contains(w, StringComparison.Ordinal));
    }

    static readonly string[] NameSeparators = [", ", " & ", " x ", " feat. ", " ft. "];

    /// <summary>Splits an un-linked artist line like "Calvin Harris &amp; Rihanna" into names.</summary>
    public static List<ArtistRef> ArtistNames(string text)
    {
        IEnumerable<string> names = [text];
        foreach (var sep in NameSeparators)
        {
            var s = sep;
            names = names.SelectMany(n => n.Split(s)).ToList();
        }
        return names.Select(YTText.TrimInline).Where(n => n.Length > 0).Select(n => new ArtistRef(null, n)).ToList();
    }

    /// <summary>Library artist pages are <c>MPLAUC…</c>; the artist page itself is <c>UC…</c>.</summary>
    public static string NormalizeArtistId(string id) => id.StartsWith("MPLA", StringComparison.Ordinal) ? id[4..] : id;

    /// <summary>Playlist browse ids are <c>VL&lt;playlistId&gt;</c>; OpenMusic keeps the bare playlist id.</summary>
    public static string PlaylistIdFromBrowseId(string id) => id.StartsWith("VL", StringComparison.Ordinal) ? id[2..] : id;

    // MARK: Badges and flags

    public static bool IsExplicit(JsonObject r)
    {
        var badges = r.A("badges").Concat(r.A("subtitleBadges"));
        return badges.Any(b => b.S("musicInlineBadgeRenderer", "icon", "iconType") == "MUSIC_EXPLICIT_BADGE");
    }

    public static bool IsGreyedOut(JsonObject r) => r.S("musicItemRendererDisplayPolicy") == "MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT";

    /// <summary>Like status from a menu (signed-in only): "LIKE", "DISLIKE", "INDIFFERENT".</summary>
    public static string? LikeStatus(JsonObject r) => JsonWalk.FirstObject("likeButtonRenderer", r.Get("menu"))?.S("likeStatus");

    // MARK: musicResponsiveListItemRenderer

    public static MediaItem? ListItem(JsonObject r)
    {
        var flex = r.A("flexColumns").Select(c => c.O("musicResponsiveListItemFlexColumnRenderer", "text")).OfType<JsonObject>().ToList();
        var fixedCols = r.A("fixedColumns").Select(c => c.O("musicResponsiveListItemFixedColumnRenderer", "text")).OfType<JsonObject>().ToList();
        var titleNode = flex.FirstOrDefault();
        var title = YTText.Plain(titleNode) ?? "";
        var rest = new List<JsonObject>();
        foreach (var col in flex.Skip(1))
        {
            // Treat each column as its own " • " segment.
            var runs = YTText.Runs(col);
            if (runs.Count == 0) continue;
            rest.AddRange(runs);
            rest.Add(new JsonObject { ["text"] = " • " });
        }
        var meta = ParseMeta(rest);
        foreach (var col in fixedCols)
        {
            if (YTText.Duration(YTText.Plain(col)) is { } d) meta.Duration = d;
        }

        var artwork = YTArtwork.From(r.Get("thumbnail"));
        var titleEndpoint = YTEndpoint.From(YTText.Runs(titleNode).FirstOrDefault()?.Obj("navigationEndpoint"));
        var rowEndpoint = YTEndpoint.From(r.Obj("navigationEndpoint"));
        var overlayEndpoint = YTEndpoint.From(r.O("overlay", "musicItemThumbnailOverlayRenderer", "content", "musicPlayButtonRenderer", "playNavigationEndpoint"));

        var videoId = r.S("playlistItemData", "videoId") ?? WatchId(titleEndpoint) ?? WatchId(rowEndpoint) ?? WatchId(overlayEndpoint);
        if (videoId != null)
        {
            string? videoType = null;
            foreach (var ep in new[] { titleEndpoint, rowEndpoint, overlayEndpoint })
            {
                if (ep is { Kind: EndpointKind.Watch, MusicVideoType: { } t }) { videoType = t; break; }
            }
            if (videoType == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE" || meta.TypeLabel == "Episode") return null;
            return new MediaItem.TrackItem(MakeTrack(videoId, title, meta, artwork, r, videoType));
        }

        var browse = rowEndpoint ?? titleEndpoint;
        if (browse is not { Kind: EndpointKind.Browse })
        {
            // Mixes and radios can be watch-playlist only.
            if ((overlayEndpoint ?? rowEndpoint) is { Kind: EndpointKind.WatchPlaylist } wp)
            {
                return new MediaItem.PlaylistItem(new Playlist
                {
                    ProviderID = wp.Id, Provider = ProviderId.YouTubeMusic, Title = title, Owner = meta.Plain.FirstOrDefault() ?? meta.Artists.FirstOrDefault()?.Name, Artwork = artwork,
                });
            }
            return null;
        }
        return BrowseItem(browse.Id, browse.PageType, title, meta, artwork, r);
    }

    static string? WatchId(YTEndpoint? ep) => ep is { Kind: EndpointKind.Watch } ? ep.Id : null;

    public static Track MakeTrack(string videoId, string title, Meta meta, Artwork? artwork, JsonObject r, string? videoType)
    {
        var artists = meta.Artists;
        if (artists.Count == 0 && meta.Plain.Count > 0 && meta.TypeLabel != "Episode") artists = ArtistNames(meta.Plain[0]);
        var extra = new Dictionary<string, string>();
        if ((r.S("playlistItemData", "playlistSetVideoId") ?? r.S("playlistSetVideoId")) is { } set) extra["setVideoId"] = set;
        if (videoType != null) extra["musicVideoType"] = videoType;
        if (LikeStatus(r) is { } like) extra["likeStatus"] = like;
        if (meta.Stats.Count > 0) extra["stats"] = meta.Stats[0];
        int? number = YTText.Plain(r.Obj("index")) is { } idx && YTText.SwiftInt(idx, out var n) && n is >= int.MinValue and <= int.MaxValue ? (int)n : null;
        return new Track
        {
            ProviderID = videoId,
            Provider = ProviderId.YouTubeMusic,
            Title = title,
            Artists = artists,
            Album = meta.Album,
            Duration = meta.Duration,
            Artwork = artwork ?? YTArtwork.ForVideo(videoId),
            IsExplicit = IsExplicit(r),
            IsPlayable = !IsGreyedOut(r),
            TrackNumber = number,
            Extra = extra,
        };
    }

    public static MediaItem? BrowseItem(string browseId, string? pageType, string title, Meta meta, Artwork? artwork, JsonObject r)
    {
        var page = pageType ?? "";
        if (page == "MUSIC_PAGE_TYPE_ALBUM" || browseId.StartsWith("MPREb", StringComparison.Ordinal))
        {
            return new MediaItem.AlbumItem(MakeAlbum(browseId, title, meta, artwork, r));
        }
        if (page.Contains("ARTIST", StringComparison.Ordinal) || (page.Length == 0 && browseId.StartsWith("UC", StringComparison.Ordinal)))
        {
            var subtitle = meta.Stats.FirstOrDefault() ?? meta.TypeLabel;
            return new MediaItem.ArtistItem(new Artist { ProviderID = NormalizeArtistId(browseId), Provider = ProviderId.YouTubeMusic, Name = title, Artwork = artwork, Subtitle = subtitle });
        }
        if (page == "MUSIC_PAGE_TYPE_PLAYLIST" || browseId.StartsWith("VL", StringComparison.Ordinal))
        {
            var owner = meta.Artists.FirstOrDefault()?.Name ?? meta.Plain.FirstOrDefault();
            var countStat = meta.Stats.FirstOrDefault(s => s.Contains("song", StringComparison.Ordinal) || s.Contains("track", StringComparison.Ordinal));
            var extra = new Dictionary<string, string>();
            if (meta.Stats.FirstOrDefault(s => s.Contains("view", StringComparison.Ordinal)) is { } views) extra["stats"] = views;
            return new MediaItem.PlaylistItem(new Playlist
            {
                ProviderID = PlaylistIdFromBrowseId(browseId), Provider = ProviderId.YouTubeMusic, Title = title, Owner = owner, Artwork = artwork,
                TrackCount = countStat == null ? null : YTText.Number(countStat), Extra = extra,
            });
        }
        return null; // podcasts, profiles, audiobooks
    }

    public static Album MakeAlbum(string browseId, string title, Meta meta, Artwork? artwork, JsonObject r)
    {
        var artists = meta.Artists;
        if (artists.Count == 0 && meta.Plain.Count > 0) artists = ArtistNames(meta.Plain[0]);
        var extra = new Dictionary<string, string>();
        // The album's audio playlist (OLAK5uy_…) is used to save it and to play it.
        var overlay = r.ContainsKey("overlay") && r["overlay"] != null ? r["overlay"] : r.Get("thumbnailOverlay");
        if ((JsonNav.AsString(JsonWalk.All("playlistId", overlay, 1).FirstOrDefault()) ??
             JsonNav.AsString(JsonWalk.All("playlistId", r.Get("menu"), 1).FirstOrDefault())) is { } pid)
        {
            extra["playlistId"] = pid;
        }
        return new Album
        {
            ProviderID = browseId, Provider = ProviderId.YouTubeMusic, Title = title, Artists = artists, Year = meta.Year, Artwork = artwork,
            Kind = AlbumKindFor(meta.TypeLabel), IsExplicit = IsExplicit(r), Extra = extra,
        };
    }

    public static AlbumKind AlbumKindFor(string? label) => label switch
    {
        "Album" => AlbumKind.Album,
        "Single" => AlbumKind.Single,
        "EP" => AlbumKind.Ep,
        "Compilation" => AlbumKind.Compilation,
        null => AlbumKind.Album,
        _ => AlbumKind.Unknown,
    };

    // MARK: musicTwoRowItemRenderer (cards in carousels and grids)

    public static MediaItem? TwoRowItem(JsonObject r)
    {
        var titleNode = r.Obj("title");
        var title = YTText.Plain(titleNode) ?? "";
        var meta = ParseMeta(YTText.Runs(r.Obj("subtitle")));
        var artwork = YTArtwork.From(r.Get("thumbnailRenderer"));
        var endpoint = YTEndpoint.From(r.Obj("navigationEndpoint")) ?? YTEndpoint.From(YTText.Runs(titleNode).FirstOrDefault()?.Obj("navigationEndpoint"));
        return endpoint?.Kind switch
        {
            EndpointKind.Watch => new MediaItem.TrackItem(MakeTrack(endpoint.Id, title, meta, artwork, r, endpoint.MusicVideoType)),
            EndpointKind.WatchPlaylist => new MediaItem.PlaylistItem(new Playlist
            {
                ProviderID = endpoint.Id, Provider = ProviderId.YouTubeMusic, Title = title, Owner = meta.Plain.FirstOrDefault() ?? meta.Artists.FirstOrDefault()?.Name, Artwork = artwork,
            }),
            EndpointKind.Browse => BrowseItem(endpoint.Id, endpoint.PageType, title, meta, artwork, r),
            _ => null,
        };
    }

    // MARK: playlistPanelVideoRenderer (watch queue / radio)

    public static Track? PanelVideo(JsonObject r)
    {
        if (r.S("videoId") is not { } videoId) return null;
        var meta = ParseMeta(YTText.Runs(r.Obj("longBylineText")));
        var navType = YTEndpoint.From(r.Obj("navigationEndpoint")) is { Kind: EndpointKind.Watch } w ? w.MusicVideoType : null;
        var t = MakeTrack(videoId, r.Text("title") ?? "", meta, YTArtwork.From(r.Get("thumbnail")), r, navType);
        if (YTText.Duration(r.Text("lengthText")) is { } d) t = t with { Duration = d };
        if (t.Artists.Count == 0 && r.Text("shortBylineText") is { } byline) t = t with { Artists = ArtistNames(byline) };
        if (r.ContainsKey("unplayableText")) t = t with { IsPlayable = false };
        return t;
    }

    // MARK: Moods & genres

    /// <summary>
    /// Mood/genre buttons aren't media. They become playlist-shaped entries whose id starts with <c>category:</c>;
    /// the provider's playlist and shelf calls understand them.
    /// </summary>
    public static Playlist? Category(JsonObject r)
    {
        if (r.Text("buttonText") is not { } title || YTEndpoint.From(r.Obj("clickCommand")) is not { Kind: EndpointKind.Browse } ep) return null;
        var token = new MoreToken(ep.Id, ep.Params).Encoded;
        var extra = new Dictionary<string, string> { ["category"] = "1", ["moreToken"] = token };
        if (r.L("solid", "leftStripeColor") is { } color) extra["color"] = "#" + (color & 0xFFFFFF).ToString("X6", CultureInfo.InvariantCulture);
        return new Playlist { ProviderID = "category:" + token, Provider = ProviderId.YouTubeMusic, Title = title, Extra = extra };
    }
}
