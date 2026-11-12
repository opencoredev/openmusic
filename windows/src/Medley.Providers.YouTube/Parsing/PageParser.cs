using System.Globalization;
using System.Text.Json.Nodes;
using Medley.Core;
using Medley.Providers.YouTube.Json;

namespace Medley.Providers.YouTube.Parsing;

/// <summary>Page-level parsers (Swift: PageParsers.swift).</summary>
internal static class PageParser
{
    // MARK: Shelves (home, explore, charts, artist pages)

    /// <summary>Section-list contents from a browse response or a continuation response.</summary>
    public static List<JsonObject> Sections(JsonObject root) => Sections(root.Get("contents"), root);

    /// <summary>
    /// Sections under <paramref name="contents"/>, plus the continuation forms on <paramref name="root"/> when given.
    /// (Swift builds <c>["contents": node]</c>; a JsonNode can't take a second parent, so the parts are passed apart.)
    /// </summary>
    public static List<JsonObject> Sections(JsonNode? contents, JsonObject? root)
    {
        var output = new List<JsonObject>();
        foreach (var list in JsonWalk.All("sectionListRenderer", contents))
        {
            output.AddRange(list.A("contents").OfType<JsonObject>());
        }
        if (root == null) return output;
        if (root.O("continuationContents", "sectionListContinuation") is { } cont) output.AddRange(cont.A("contents").OfType<JsonObject>());
        foreach (var action in root.A("onResponseReceivedActions"))
        {
            output.AddRange(action.A("appendContinuationItemsAction", "continuationItems").OfType<JsonObject>());
        }
        return output;
    }

    /// <summary>The section list's own continuation (more shelves), not one nested in a shelf.</summary>
    public static string? SectionsContinuation(JsonObject root)
    {
        if (JsonWalk.FirstObject("sectionListRenderer", root.Get("contents")) is { } list &&
            list.A("continuations").FirstOrDefault().S("nextContinuationData", "continuation") is { } token)
        {
            return ContinuationToken.EncodeQuery(token);
        }
        if (root.O("continuationContents", "sectionListContinuation") is { } cont &&
            cont.A("continuations").FirstOrDefault().S("nextContinuationData", "continuation") is { } t2)
        {
            return ContinuationToken.EncodeQuery(t2);
        }
        return null;
    }

    public static List<Shelf> Shelves(JsonObject root, IReadOnlySet<string>? skipTitles = null)
    {
        var output = new List<Shelf>();
        var sections = Sections(root);
        for (var i = 0; i < sections.Count; i++)
        {
            if (Shelf(sections[i], i) is { } shelf && !(skipTitles?.Contains(shelf.Title) ?? false)) output.Add(shelf);
        }
        return output;
    }

    public static Shelf? Shelf(JsonObject section, int index)
    {
        if (section.RendererKey() is not { } key || section.Obj(key) is not { } r) return null;
        string title;
        string? subtitle = null;
        YTEndpoint? moreEndpoint = null;
        List<MediaItem> items;
        var hero = false;
        switch (key)
        {
            case "musicCarouselShelfRenderer":
            case "musicImmersiveCarouselShelfRenderer":
                var header = r.O("header", "musicCarouselShelfBasicHeaderRenderer") ?? r.O("header", "musicImmersiveCarouselShelfHeaderRenderer") ?? new JsonObject();
                title = header.Text("title") ?? "";
                subtitle = header.Text("strapline");
                moreEndpoint = YTEndpoint.From(header.O("moreContentButton", "buttonRenderer", "navigationEndpoint"))
                    ?? YTEndpoint.From(YTText.Runs(header.Obj("title")).FirstOrDefault()?.Obj("navigationEndpoint"));
                items = ItemParser.Items(r.A("contents"));
                hero = key == "musicImmersiveCarouselShelfRenderer";
                break;
            case "musicShelfRenderer":
                title = r.Text("title") ?? "";
                moreEndpoint = YTEndpoint.From(r.Obj("bottomEndpoint")) ?? YTEndpoint.From(r.O("moreContentButton", "buttonRenderer", "navigationEndpoint"));
                items = ItemParser.Items(r.A("contents"));
                break;
            case "gridRenderer":
                title = r.Text("header", "gridHeaderRenderer", "title") ?? "";
                items = ItemParser.Items(r.A("items"));
                break;
            case "musicCardShelfRenderer":
                title = r.Text("header", "musicCardShelfHeaderBasicRenderer", "title") ?? "Top result";
                items = ItemParser.Items(r.A("contents"));
                break;
            default:
                return null;
        }
        if (items.Count == 0) return null;
        var moreToken = moreEndpoint is { Kind: EndpointKind.Browse } b ? new MoreToken(b.Id, b.Params).Encoded : null;
        return new Shelf($"ytm-{index}-{title}", title, Style(items, hero), items) { Subtitle = subtitle, MoreToken = moreToken };
    }

    static bool IsVideoType(string? t) => t is "MUSIC_VIDEO_TYPE_OMV" or "MUSIC_VIDEO_TYPE_UGC";

    public static ShelfStyle Style(IReadOnlyList<MediaItem> items, bool hero)
    {
        if (hero) return ShelfStyle.Hero;
        var artists = items.Count(i => i is MediaItem.ArtistItem);
        if (artists * 2 > items.Count) return ShelfStyle.Artists;
        var tracks = items.Count(i => i is MediaItem.TrackItem t && !IsVideoType(t.Track.Extra.GetValueOrDefault("musicVideoType")));
        return tracks * 2 > items.Count ? ShelfStyle.TrackList : ShelfStyle.Carousel;
    }

    /// <summary>For "See All" pages: one shelf holding everything on the page.</summary>
    public static Shelf ExpandedShelf(JsonObject root, string token)
    {
        var shelves = Shelves(root);
        var pageTitle = root.Text("header", "musicHeaderRenderer", "title")
            ?? JsonWalk.FirstObject("musicResponsiveHeaderRenderer", root)?.Text("title")
            ?? shelves.FirstOrDefault()?.Title ?? "";
        if (shelves.Count == 1)
        {
            var only = shelves[0];
            return only with { Id = "more-" + token, Title = only.Title.Length == 0 ? pageTitle : only.Title, MoreToken = null };
        }
        var items = new List<MediaItem>();
        var seen = new HashSet<string>();
        foreach (var shelf in shelves)
        {
            foreach (var item in shelf.Items)
            {
                if (seen.Add(item.Id)) items.Add(item);
            }
        }
        return new Shelf("more-" + token, pageTitle, Style(items, false), items);
    }

    // MARK: Search

    public static SearchResults Search(JsonObject root, SearchScope scope)
    {
        JsonNode tab = root.A("contents", "tabbedSearchResultsRenderer", "tabs").FirstOrDefault().O("tabRenderer", "content") ?? (JsonNode)root;
        MediaItem? top = null;
        var tracks = new List<Track>();
        var albums = new List<Album>();
        var artists = new List<Artist>();
        var playlists = new List<Playlist>();
        var seen = new HashSet<string>();
        void Add(MediaItem item)
        {
            if (!seen.Add(item.Id)) return;
            switch (item)
            {
                case MediaItem.TrackItem t: tracks.Add(t.Track); break;
                case MediaItem.AlbumItem a: albums.Add(a.Album); break;
                case MediaItem.ArtistItem a: artists.Add(a.Artist); break;
                case MediaItem.PlaylistItem p: playlists.Add(p.Playlist); break;
            }
        }
        foreach (var section in Sections(tab, null))
        {
            if (section.Obj("musicCardShelfRenderer") is { } card)
            {
                var cardTop = TopResult(card);
                if (top == null && cardTop != null)
                {
                    top = cardTop;
                    Add(cardTop);
                }
                foreach (var entry in ItemParser.Items(card.A("contents")))
                {
                    var item = entry;
                    // Songs in an artist's top-result card omit the artist name.
                    if (item is MediaItem.TrackItem { Track: var t } && t.Artists.Count == 0 && cardTop is MediaItem.ArtistItem { Artist: var a })
                    {
                        item = new MediaItem.TrackItem(t with { Artists = [new ArtistRef(a.ProviderID, a.Name)] });
                    }
                    Add(item);
                }
                continue;
            }
            foreach (var list in new[] { "itemSectionRenderer", "musicShelfRenderer" })
            {
                if (section.Obj(list) is { } r && r.Get("contents") is JsonArray contents)
                {
                    foreach (var item in ItemParser.Items(contents)) Add(item);
                }
            }
        }
        // Songs before videos in the combined list.
        if (scope == SearchScope.All)
        {
            bool IsVideo(Track t) => IsVideoType(t.Extra.GetValueOrDefault("musicVideoType") ?? "");
            tracks = tracks.Where(t => !IsVideo(t)).Concat(tracks.Where(IsVideo)).ToList();
        }
        return new SearchResults { Top = top, Tracks = tracks, Albums = albums, Artists = artists, Playlists = playlists };
    }

    public static MediaItem? TopResult(JsonObject card)
    {
        var titleRun = YTText.Runs(card.Obj("title")).FirstOrDefault();
        var title = YTText.Plain(card.Obj("title")) ?? "";
        var meta = ItemParser.ParseMeta(YTText.Runs(card.Obj("subtitle")));
        var artwork = YTArtwork.From(card.Get("thumbnail"));
        var endpoint = YTEndpoint.From(titleRun?.Obj("navigationEndpoint")) ?? YTEndpoint.From(card.Obj("onTap"));
        return endpoint?.Kind switch
        {
            EndpointKind.Watch => new MediaItem.TrackItem(ItemParser.MakeTrack(endpoint.Id, title, meta, artwork, card, endpoint.MusicVideoType)),
            EndpointKind.Browse => ItemParser.BrowseItem(endpoint.Id, endpoint.PageType, title, meta, artwork, card),
            _ => null,
        };
    }

    /// <summary>The direct matches YouTube Music lists under the completions (an artist, then songs and albums).</summary>
    public static List<MediaItem> SuggestionItems(JsonObject root) =>
        root.A("contents").SelectMany(section => ItemParser.Items(section.A("searchSuggestionsSectionRenderer", "contents"))).ToList();

    public static List<string> Suggestions(JsonObject root) =>
        root.A("contents")
            .SelectMany(section => section.A("searchSuggestionsSectionRenderer", "contents"))
            .Select(e => e.O("searchSuggestionRenderer").Text("suggestion") ?? e.O("historySuggestionRenderer").Text("suggestion"))
            .OfType<string>()
            .ToList();

    // MARK: Album

    public static AlbumDetail Album(JsonObject root, string browseId)
    {
        var header = JsonWalk.FirstObject("musicResponsiveHeaderRenderer", root.Get("contents"))
            ?? throw ProviderException.Decoding("album header missing");
        var title = header.Text("title") ?? "";
        var subtitle = ItemParser.ParseMeta(YTText.Runs(header.Obj("subtitle")));
        var artists = ItemParser.ParseMeta(YTText.Runs(header.Obj("straplineTextOne"))).Artists;
        if (artists.Count == 0 && header.Text("straplineTextOne") is { } name) artists = ItemParser.ArtistNames(name);
        var artwork = YTArtwork.From(header.Get("thumbnail"));
        var secondary = header.Text("secondSubtitle");
        var summary = header.Text("description", "musicDescriptionShelfRenderer", "description");

        var extra = new Dictionary<string, string>();
        if (AlbumPlaylistId(root, header) is { } pid) extra["playlistId"] = pid;
        if (JsonWalk.FirstObject("toggleButtonRenderer", header.Get("buttons")).B("isToggled") is { } saved) extra["saved"] = saved ? "1" : "0";

        var secondaryContents = root.O("contents", "twoColumnBrowseResultsRenderer", "secondaryContents");
        var shelfNode = JsonWalk.FirstObject("musicShelfRenderer", secondaryContents) ?? JsonWalk.FirstObject("musicShelfRenderer", root.Get("contents"));
        var albumRef = new AlbumRef(browseId, title);
        var tracks = ItemParser.Tracks(shelfNode.A("contents"));
        var isExplicit = false;
        for (var i = 0; i < tracks.Count; i++)
        {
            var t = tracks[i];
            var trackExtra = new Dictionary<string, string>(t.Extra);
            if (extra.TryGetValue("playlistId", out var playlistId)) trackExtra["playlistId"] = playlistId;
            t = t with
            {
                Artists = t.Artists.Count == 0 ? artists : t.Artists,
                Album = t.Album ?? albumRef,
                Artwork = artwork ?? t.Artwork,
                TrackNumber = t.TrackNumber ?? i + 1,
                Extra = trackExtra,
            };
            tracks[i] = t;
            isExplicit = isExplicit || t.IsExplicit;
        }
        var album = new Album
        {
            ProviderID = browseId, Provider = ProviderId.YouTubeMusic, Title = title, Artists = artists, Year = subtitle.Year, Artwork = artwork,
            Kind = ItemParser.AlbumKindFor(subtitle.TypeLabel), TrackCount = tracks.Count,
            IsExplicit = isExplicit || ItemParser.IsExplicit(header), Extra = extra,
        };
        var more = new List<Album>();
        foreach (var section in Sections(secondaryContents, null))
        {
            if (section.Obj("musicCarouselShelfRenderer") is not { } carousel) continue;
            // The carousel may be "More by <artist>" or a generic "Releases for you"; keep the artist's own.
            var names = artists.Select(a => a.Name).ToHashSet();
            foreach (var item in ItemParser.Items(carousel.A("contents")))
            {
                if (item is not MediaItem.AlbumItem { Album: var a }) continue;
                if (a.Artists.Count == 0) a = a with { Artists = artists };
                if (a.Artists.Any(x => names.Contains(x.Name))) more.Add(a);
            }
        }
        var footnote = string.Join(" · ", new[] { secondary, subtitle.Year?.ToString(CultureInfo.InvariantCulture) }.OfType<string>());
        return new AlbumDetail(album, tracks, summary, footnote.Length == 0 ? null : footnote, more);
    }

    public static string? AlbumPlaylistId(JsonObject root, JsonObject header)
    {
        foreach (var node in new[] { header.Get("buttons"), header.Get("menu"), root.Get("contents") })
        {
            foreach (var pid in JsonWalk.All("playlistId", node))
            {
                if (JsonNav.AsString(pid) is { } s && s.StartsWith("OLAK", StringComparison.Ordinal)) return s;
            }
        }
        if (root.S("microformat", "microformatDataRenderer", "urlCanonical") is { } canonical && QueryValue(canonical, "list") is { } list)
        {
            return list;
        }
        return null;
    }

    /// <summary>A query parameter from a relative or absolute URL (Swift <c>URLComponents.queryItems</c>).</summary>
    public static string? QueryValue(string url, string name)
    {
        var q = url.IndexOf('?');
        if (q < 0) return null;
        var query = url[(q + 1)..];
        var hash = query.IndexOf('#');
        if (hash >= 0) query = query[..hash];
        foreach (var pair in query.Split('&'))
        {
            var eq = pair.IndexOf('=');
            var key = eq < 0 ? pair : pair[..eq];
            if (Unescape(key) != name) continue;
            return eq < 0 ? null : Unescape(pair[(eq + 1)..]);
        }
        return null;
    }

    static string Unescape(string s)
    {
        try { return Uri.UnescapeDataString(s); } catch (UriFormatException) { return s; }
    }

    // MARK: Artist

    public static ArtistDetail Artist(JsonObject root, string browseId)
    {
        var headerWrapper = root.Obj("header") ?? new JsonObject();
        if (headerWrapper.RendererKey() is not { } key || headerWrapper.Obj(key) is not { } header) throw ProviderException.Decoding("artist header missing");
        var name = header.Text("title") ?? "";
        var subscribe = header.O("subscriptionButton", "subscribeButtonRenderer");
        var extra = new Dictionary<string, string>();
        if (subscribe.S("channelId") is { } channel) extra["channelId"] = channel;
        if (subscribe != null && YTText.Plain(subscribe.Obj("subscriberCountText")) is { } subs) extra["subscribers"] = subs;
        var artist = new Artist
        {
            ProviderID = browseId, Provider = ProviderId.YouTubeMusic, Name = name, Artwork = YTArtwork.From(header.Get("thumbnail")),
            Subtitle = header.Text("monthlyListenerCount") ?? (extra.TryGetValue("subscribers", out var s) ? $"{s} subscribers" : null),
            Extra = extra,
        };
        var me = new ArtistRef(browseId, name);
        var bio = header.Text("description");
        var isFollowed = subscribe.B("subscribed");
        var radioSeed = header.S("startRadioButton", "buttonRenderer", "navigationEndpoint", "watchEndpoint", "playlistId")
            ?? header.S("startRadioButton", "buttonRenderer", "navigationEndpoint", "watchPlaylistEndpoint", "playlistId")
            ?? header.S("playButton", "buttonRenderer", "navigationEndpoint", "watchEndpoint", "playlistId");
        var topTracks = new List<Track>();
        var albums = new List<Album>();
        var singles = new List<Album>();
        var playlists = new List<Playlist>();
        var related = new List<Artist>();

        foreach (var section in Sections(root))
        {
            if (section.Obj("musicShelfRenderer") is { } shelf)
            {
                topTracks.AddRange(ItemParser.Tracks(shelf.A("contents")));
                continue;
            }
            if (bio == null && section.Obj("musicDescriptionShelfRenderer") is { } desc)
            {
                bio = desc.Text("description");
                continue;
            }
            if (section.Obj("musicCarouselShelfRenderer") is not { } carousel) continue;
            var title = (carousel.O("header", "musicCarouselShelfBasicHeaderRenderer").Text("title") ?? "").ToLowerInvariant();
            foreach (var item in ItemParser.Items(carousel.A("contents")))
            {
                switch (item)
                {
                    case MediaItem.AlbumItem { Album: var a }:
                        if (a.Artists.Count == 0) a = a with { Artists = [me] };
                        if (title.Contains("single", StringComparison.Ordinal) || title.StartsWith("ep", StringComparison.Ordinal)) singles.Add(a);
                        else albums.Add(a);
                        break;
                    case MediaItem.PlaylistItem { Playlist: var p }: playlists.Add(p); break;
                    case MediaItem.ArtistItem { Artist: var a }: related.Add(a); break;
                    case MediaItem.TrackItem: break; // "Videos" / "Live performances" carousels
                }
            }
        }
        return new ArtistDetail(artist)
        {
            TopTracks = topTracks, Albums = albums, Singles = singles, Playlists = playlists, Related = related,
            Bio = bio, RadioSeed = radioSeed, IsFollowed = isFollowed,
        };
    }

    // MARK: Playlist

    public static PlaylistDetail Playlist(JsonObject root, string playlistId)
    {
        var header = JsonWalk.FirstObject("musicResponsiveHeaderRenderer", root.Get("contents"))
            ?? JsonWalk.FirstObject("musicDetailHeaderRenderer", root)
            ?? throw ProviderException.Decoding("playlist header missing");
        var editable = JsonWalk.First("musicEditablePlaylistDetailHeaderRenderer", root.Get("contents")) != null;
        var title = header.Text("title") ?? "";
        var ownerMeta = ItemParser.ParseMeta(YTText.Runs(header.Obj("straplineTextOne")));
        var owner = ownerMeta.Artists.FirstOrDefault()?.Name ?? header.Text("straplineTextOne")
            ?? header.Text("facepile", "avatarStackViewModel", "text") ?? ownerMeta.Plain.FirstOrDefault();
        var second = header.Text("secondSubtitle");
        var extra = new Dictionary<string, string>();
        if (second != null) extra["stats"] = second;
        if (JsonWalk.FirstObject("toggleButtonRenderer", header.Get("buttons")).B("isToggled") is { } saved) extra["saved"] = saved ? "1" : "0";
        var shelf = JsonWalk.FirstObject("musicPlaylistShelfRenderer", root.Get("contents"))
            ?? JsonWalk.FirstObject("musicShelfRenderer", root.O("contents", "twoColumnBrowseResultsRenderer", "secondaryContents"));
        var contents = shelf.A("contents");
        var tracks = ItemParser.Tracks(contents);
        var continuation = ContinuationToken.Find(contents);
        var playlist = new Playlist
        {
            ProviderID = playlistId, Provider = ProviderId.YouTubeMusic, Title = title, Owner = owner, Artwork = YTArtwork.From(header.Get("thumbnail")),
            // The header's own total. Without one, the first page's length is the total only when there is no later
            // page; otherwise null, so the app never takes 100 loaded songs for a 100-song playlist.
            TrackCount = TrackCount(second) ?? (continuation == null ? tracks.Count : null),
            Summary = header.Text("description", "musicDescriptionShelfRenderer", "description"),
            IsEditable = editable, Extra = extra,
        };
        return new PlaylistDetail(playlist, tracks) { Continuation = continuation };
    }

    /// <summary>"29K views • 1,000 songs • 3+ hours" → 1000.</summary>
    public static int? TrackCount(string? text)
    {
        if (text == null) return null;
        var segment = text.Split('•').FirstOrDefault(s =>
            s.Contains("song", StringComparison.Ordinal) || s.Contains("track", StringComparison.Ordinal) ||
            s.Contains("episode", StringComparison.Ordinal) || s.Contains("video", StringComparison.Ordinal));
        return segment == null ? null : YTText.Number(YTText.TrimInline(segment));
    }

    /// <summary>A continuation of a playlist or any list (library, history).</summary>
    public static (List<MediaItem> Items, string? Continuation) ContinuationItems(JsonObject root)
    {
        var list = new List<JsonNode?>();
        foreach (var action in root.A("onResponseReceivedActions"))
        {
            list.AddRange(action.A("appendContinuationItemsAction", "continuationItems"));
        }
        if (root.Obj("continuationContents") is { } cc)
        {
            foreach (var (_, value) in cc)
            {
                if (value is not JsonObject v) continue;
                list.AddRange(v.A("contents"));
                list.AddRange(v.A("items"));
                if (v.A("continuations").FirstOrDefault().S("nextContinuationData", "continuation") is { } token)
                {
                    return (ItemParser.Items(list), ContinuationToken.EncodeQuery(token));
                }
            }
        }
        return (ItemParser.Items(list), ContinuationToken.Find(list));
    }

    // MARK: Library pages (grids and shelves with continuations)

    public static Page<MediaItem> LibraryPage(JsonObject root)
    {
        var items = new List<MediaItem>();
        string? continuation = null;
        foreach (var section in Sections(root))
        {
            if (section.RendererKey() is not { } key || section.Obj(key) is not { } r) continue;
            var list = r.A("items").Concat(r.A("contents")).ToList();
            items.AddRange(ItemParser.Items(list));
            if (continuation == null)
            {
                continuation = ContinuationToken.Find(list);
                if (continuation == null && r.A("continuations").FirstOrDefault().S("nextContinuationData", "continuation") is { } t)
                {
                    continuation = ContinuationToken.EncodeQuery(t);
                }
            }
        }
        return new Page<MediaItem>(items) { Continuation = continuation };
    }

    // MARK: Watch next (radio, lyrics id, like status)

    internal sealed class WatchNext
    {
        public List<Track> Tracks = [];
        public string? LyricsBrowseId;
        public string? RelatedBrowseId;
        public string? LikeStatus;
        public string? Continuation;
    }

    public static WatchNext ParseWatchNext(JsonObject root)
    {
        var tabs = root.A("contents", "singleColumnMusicWatchNextResultsRenderer", "tabbedRenderer", "watchNextTabbedResultsRenderer", "tabs");
        var output = new WatchNext();
        foreach (var tabNode in tabs)
        {
            if (tabNode is not JsonObject tab || tab.Obj("tabRenderer") is not { } renderer) continue;
            if (YTEndpoint.From(renderer.Obj("endpoint"))?.BrowseId is { } id)
            {
                if (id.StartsWith("MPLY", StringComparison.Ordinal)) output.LyricsBrowseId = id;
                if (id.StartsWith("MPTR", StringComparison.Ordinal)) output.RelatedBrowseId = id;
            }
            if (JsonWalk.FirstObject("playlistPanelRenderer", renderer.Get("content")) is { } panel)
            {
                output.Tracks = ItemParser.Tracks(panel.A("contents"));
                if (panel.A("continuations").FirstOrDefault().S("nextRadioContinuationData", "continuation") is { } token) output.Continuation = token;
            }
        }
        // Continuation responses for the queue.
        if (root.O("continuationContents", "playlistPanelContinuation") is { } cont)
        {
            output.Tracks = ItemParser.Tracks(cont.A("contents"));
            output.Continuation = cont.A("continuations").FirstOrDefault().S("nextRadioContinuationData", "continuation");
        }
        output.LikeStatus = JsonWalk.FirstObject("likeButtonRenderer", root.Get("playerOverlays")).S("likeStatus");
        return output;
    }

    // MARK: Lyrics

    /// <summary>Timed lyrics (ANDROID_MUSIC client) or plain lyrics (WEB_REMIX).</summary>
    public static Lyrics? Lyrics(JsonObject root)
    {
        if (JsonWalk.FirstObject("timedLyricsModel", root.Get("contents"))?.Obj("lyricsData") is { } data)
        {
            var lines = new List<LyricLine>();
            foreach (var line in data.A("timedLyricsData").OfType<JsonObject>())
            {
                if (line.S("lyricLine") is not { } text) continue;
                double? start = line.S("cueRange", "startTimeMilliseconds") is { } ms &&
                                double.TryParse(ms, NumberStyles.Float, CultureInfo.InvariantCulture, out var v)
                    ? v / 1000
                    : null;
                lines.Add(new LyricLine(start, text == "♪" ? "" : text));
            }
            if (lines.Count > 0) return new Lyrics(lines, data.S("sourceMessage"));
        }
        if (JsonWalk.FirstObject("musicDescriptionShelfRenderer", root.Get("contents")) is not { } shelf || shelf.Text("description") is not { } description)
        {
            return null;
        }
        var plain = description.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n').Select(l => new LyricLine(null, l)).ToList();
        return new Lyrics(plain, shelf.Text("footer"));
    }

    // MARK: Account

    public static AccountInfo? Account(JsonObject root)
    {
        if (JsonWalk.FirstObject("activeAccountHeaderRenderer", root) is not { } header || header.Text("accountName") is not { } name) return null;
        var photo = header.A("accountPhoto", "thumbnails").LastOrDefault().S("url");
        var handle = header.Text("channelHandle");
        var email = header.Text("email");
        // No id: account_menu carries no immutable one. The provider sets it from the credentials' datasync id.
        return new AccountInfo(name, photo != null && Uri.TryCreate(photo, UriKind.Absolute, out var u) ? u : null, handle ?? email);
    }
}
