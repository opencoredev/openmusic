using System.Text.Json.Nodes;
using Medley.Core;
using Medley.Providers.YouTube.Json;

namespace Medley.Providers.YouTube.Parsing;

internal enum EndpointKind { Watch, WatchPlaylist, Browse }

/// <summary>What a tap on an InnerTube item leads to (Swift: <c>YTEndpoint</c>).</summary>
internal sealed record YTEndpoint(EndpointKind Kind, string Id, string? PlaylistId = null, string? MusicVideoType = null,
    string? Params = null, string? PageType = null)
{
    public static YTEndpoint? From(JsonObject? node)
    {
        if (node == null) return null;
        var w = node.Obj("watchEndpoint");
        if (w != null && w.S("videoId") is { } videoId)
        {
            return new YTEndpoint(EndpointKind.Watch, videoId, PlaylistId: w.S("playlistId"),
                MusicVideoType: w.S("watchEndpointMusicSupportedConfigs", "watchEndpointMusicConfig", "musicVideoType"));
        }
        var b = node.Obj("browseEndpoint");
        if (b != null && b.S("browseId") is { } browseId)
        {
            return new YTEndpoint(EndpointKind.Browse, browseId, Params: b.S("params"),
                PageType: b.S("browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig", "pageType"));
        }
        if (node.Obj("watchPlaylistEndpoint")?.S("playlistId") is { } pid) return new YTEndpoint(EndpointKind.WatchPlaylist, pid);
        if (w?.S("playlistId") is { } wpid) return new YTEndpoint(EndpointKind.WatchPlaylist, wpid);
        return null;
    }

    public string? BrowseId => Kind == EndpointKind.Browse ? Id : null;
    public string? BrowsePageType => Kind == EndpointKind.Browse ? PageType : null;
}

/// <summary>Image renditions for Google image-server and i.ytimg.com URLs (Swift: <c>YTArtwork</c>).</summary>
internal static class YTArtwork
{
    /// <summary>Square sizes offered for Google image-server URLs (resized by rewriting the suffix).</summary>
    public static readonly int[] SquareSizes = [60, 120, 226, 544, 1080];

    /// <summary>Finds the first <c>thumbnails</c> array within <paramref name="node"/> and expands it into sizes.</summary>
    public static Artwork? From(JsonNode? node) =>
        JsonWalk.First("thumbnails", node) is JsonArray list ? FromThumbnails(list) : null;

    public static Artwork? FromThumbnails(IEnumerable<JsonNode?> list)
    {
        var given = new List<ArtworkImage>();
        foreach (var item in list)
        {
            if (item is not JsonObject t || t.S("url") is not { } raw) continue;
            if (raw.StartsWith("//", StringComparison.Ordinal)) raw = "https:" + raw;
            if (!Uri.TryCreate(raw, UriKind.Absolute, out var url)) continue;
            given.Add(new ArtworkImage(url, t.I("width"), t.I("height")));
        }
        ArtworkImage? best = null;
        foreach (var g in given)
        {
            if (best == null || (best.Width ?? 0) < (g.Width ?? 0)) best = g;
        }
        if (best == null) return null;
        if (Resizable(best.Url) is { } resized) return new Artwork(resized);
        if (VideoThumbnails(best.Url) is { } video) return new Artwork(video);
        return new Artwork(given);
    }

    /// <summary>lh3/yt3.googleusercontent.com and yt3.ggpht.com URLs end in <c>=w60-h60-l90-rj</c> (or <c>=s120…</c>).</summary>
    public static List<ArtworkImage>? Resizable(Uri url)
    {
        var s = url.OriginalString;
        var host = url.Host;
        if (!(host.EndsWith("googleusercontent.com", StringComparison.Ordinal) || host.EndsWith("ggpht.com", StringComparison.Ordinal))) return null;
        var eq = s.LastIndexOf('=');
        if (eq < 0) return null;
        var baseUrl = s[..eq];
        var suffix = s[(eq + 1)..];
        // Keep flags other than size/crop (e.g. "l90", "rj") so the server returns the same format.
        var flags = suffix.Split('-', StringSplitOptions.RemoveEmptyEntries).Where(part =>
            !(part.StartsWith('w') || part.StartsWith('h') || part.StartsWith('s')) || !YTText.SwiftInt(part[1..], out _)).ToList();
        var tail = flags.Count == 0 ? "" : "-" + string.Join("-", flags);
        var output = new List<ArtworkImage>();
        foreach (var size in SquareSizes)
        {
            if (Uri.TryCreate($"{baseUrl}=w{size}-h{size}{tail}", UriKind.Absolute, out var u)) output.Add(new ArtworkImage(u, size, size));
        }
        return output;
    }

    /// <summary>i.ytimg.com/vi/&lt;id&gt;/&lt;name&gt;.jpg: offer the standard renditions.</summary>
    public static List<ArtworkImage>? VideoThumbnails(Uri url)
    {
        if (!url.Host.EndsWith("ytimg.com", StringComparison.Ordinal)) return null;
        var comps = url.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (comps.Length < 3 || !(comps[0] == "vi" || comps[0] == "vi_webp")) return null;
        var id = Uri.UnescapeDataString(comps[1]);
        (string Name, int W, int H)[] variants = [("mqdefault", 320, 180), ("hqdefault", 480, 360), ("sddefault", 640, 480)];
        return variants.Select(v => new ArtworkImage(new Uri($"https://i.ytimg.com/vi/{id}/{v.Name}.jpg"), v.W, v.H)).ToList();
    }

    /// <summary>Artwork for a video id, used when a response has no thumbnail.</summary>
    public static Artwork? ForVideo(string videoId) =>
        Uri.TryCreate($"https://i.ytimg.com/vi/{videoId}/hqdefault.jpg", UriKind.Absolute, out var u) && VideoThumbnails(u) is { } v ? new Artwork(v) : null;
}

/// <summary>Opaque "See All" / category tokens handed to the UI: <c>browse|&lt;browseId&gt;|&lt;params&gt;</c>.</summary>
internal sealed record MoreToken(string BrowseId, string? Params)
{
    public string Encoded => $"browse|{BrowseId}|{Params ?? ""}";

    public static MoreToken? Parse(string text)
    {
        var parts = text.Split('|');
        if (parts.Length != 3 || parts[0] != "browse" || parts[1].Length == 0) return null;
        return new MoreToken(parts[1], parts[2].Length == 0 ? null : parts[2]);
    }
}

/// <summary>
/// Continuation tokens come in two flavours: the newer <c>continuationCommand.token</c> (sent in the body) and the older
/// <c>nextContinuationData.continuation</c> (sent as <c>ctoken</c>/<c>continuation</c> query params). They are
/// prefixed (<c>b:</c>, <c>q:</c>) so callers hand back a single opaque string.
/// </summary>
internal static class ContinuationToken
{
    public static string EncodeBody(string token) => "b:" + token;
    public static string EncodeQuery(string token) => "q:" + token;

    public static string? Find(JsonNode? node) => Find(node == null ? [] : [node]);

    public static string? Find(IEnumerable<JsonNode?> nodes)
    {
        var list = nodes as IList<JsonNode?> ?? nodes.ToList();
        if (JsonWalk.FirstObject("continuationItemRenderer", list) is { } item &&
            JsonWalk.FirstObject("continuationCommand", item)?.S("token") is { } token)
        {
            return EncodeBody(token);
        }
        if (JsonWalk.FirstObject("nextContinuationData", list)?.S("continuation") is { } next) return EncodeQuery(next);
        return null;
    }
}
