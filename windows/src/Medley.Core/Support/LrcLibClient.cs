using System.Globalization;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Serialization;
using Medley.Core.Support;

namespace Medley.Core;

/// <summary>
/// Client for LRCLIB (https://lrclib.net), a free, keyless lyrics database with synced (LRC) lyrics. Lookup order:
/// <c>/api/get</c> with the exact signature (title, artist, album, duration), then <c>/api/search</c> by title and artist,
/// picking the closest match by duration. Usable by any provider as a lyrics source or fallback. Port of LRCLib.swift.
/// Thread-safe; does its work off the caller's context.
/// </summary>
public sealed class LrcLibClient
{
    /// <summary>Performs one GET and returns the status code and body. Injected in tests.</summary>
    public delegate Task<(int Status, byte[] Body)> Fetch(HttpRequestMessage request, CancellationToken ct);

    public const string Source = "LRCLIB";
    public const string UserAgent = $"{ProductInfo.Name}/0.1 (native Windows music player)";

    private static readonly Lazy<HttpClient> SharedClient = new(() => new HttpClient { Timeout = TimeSpan.FromSeconds(20) });

    private readonly Uri _baseUrl;
    private readonly Fetch _fetch;

    public LrcLibClient(Uri? baseUrl = null, Fetch? fetch = null)
    {
        _baseUrl = baseUrl ?? new Uri("https://lrclib.net");
        _fetch = fetch ?? DefaultFetch;
    }

    private static async Task<(int, byte[])> DefaultFetch(HttpRequestMessage request, CancellationToken ct)
    {
        try
        {
            using var response = await SharedClient.Value.SendAsync(request, ct).ConfigureAwait(false);
            return ((int)response.StatusCode, await response.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false));
        }
        catch (HttpRequestException e)
        {
            throw ProviderException.Network(e.Message, e);
        }
    }

    /// <summary>One LRCLIB record.</summary>
    public sealed record Record
    {
        [JsonPropertyName("id")] public int Id { get; init; }
        [JsonPropertyName("trackName")] public string? TrackName { get; init; }
        [JsonPropertyName("artistName")] public string? ArtistName { get; init; }
        [JsonPropertyName("albumName")] public string? AlbumName { get; init; }
        [JsonPropertyName("duration")] public double? Duration { get; init; }
        [JsonPropertyName("instrumental")] public bool? Instrumental { get; init; }
        [JsonPropertyName("plainLyrics")] public string? PlainLyrics { get; init; }
        [JsonPropertyName("syncedLyrics")] public string? SyncedLyrics { get; init; }
    }

    /// <summary>Lyrics for a song, synced when LRCLIB has them, else plain. Null when nothing matches.</summary>
    public async Task<Lyrics?> LyricsAsync(string title, string artist, string? album = null, double? duration = null, CancellationToken ct = default)
    {
        title = title.Trim();
        artist = artist.Trim();
        if (title.Length == 0) return null;

        // /api/get needs the full signature; LRCLIB matches duration within ±2 seconds.
        if (!string.IsNullOrEmpty(album) && duration is > 0 and var d)
        {
            if (await GetAsync(title, artist, album, d, ct).ConfigureAwait(false) is { } record && LyricsFrom(record) is { } lyrics)
                return lyrics;
        }
        var candidates = await SearchAsync(title, artist, ct).ConfigureAwait(false);
        return BestMatch(candidates, duration) is { } best ? LyricsFrom(best) : null;
    }

    public async Task<Record?> GetAsync(string title, string artist, string album, double duration, CancellationToken ct = default)
    {
        var items = new List<(string, string)>
        {
            ("track_name", title),
            ("artist_name", artist),
            ("album_name", album),
            ("duration", ((long)Math.Round(duration, MidpointRounding.AwayFromZero)).ToString(CultureInfo.InvariantCulture)),
        };
        items.RemoveAll(i => i.Item2.Length == 0);
        var (status, body) = await _fetch(Request("/api/get", items), ct).ConfigureAwait(false);
        return status switch
        {
            200 => TryDecode(body, MedleyJsonContext.Default.Record),
            404 => null,
            429 => throw ProviderException.RateLimited(),
            _ => throw ProviderException.Server(status, Source),
        };
    }

    public async Task<IReadOnlyList<Record>> SearchAsync(string title, string artist, CancellationToken ct = default)
    {
        var items = new List<(string, string)> { ("track_name", title) };
        if (artist.Length > 0) items.Add(("artist_name", artist));
        var (status, body) = await _fetch(Request("/api/search", items), ct).ConfigureAwait(false);
        return status switch
        {
            200 => TryDecode(body, MedleyJsonContext.Default.ListRecord) ?? [],
            404 => [],
            429 => throw ProviderException.RateLimited(),
            _ => throw ProviderException.Server(status, Source),
        };
    }

    private static T? TryDecode<T>(byte[] body, System.Text.Json.Serialization.Metadata.JsonTypeInfo<T> info) where T : class
    {
        try { return MedleyJson.Deserialize(body, info); }
        catch (System.Text.Json.JsonException) { return null; }
    }

    private HttpRequestMessage Request(string path, IEnumerable<(string Name, string Value)> query)
    {
        var qs = string.Join("&", query.Select(q => $"{Uri.EscapeDataString(q.Name)}={Uri.EscapeDataString(q.Value)}"));
        var request = new HttpRequestMessage(HttpMethod.Get, new Uri(_baseUrl, path + (qs.Length > 0 ? "?" + qs : "")));
        // LRCLIB asks clients to identify themselves.
        request.Headers.UserAgent.ParseAdd(UserAgent);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        return request;
    }

    // MARK: Matching and parsing

    /// <summary>Prefers records within 3 s of <paramref name="duration"/>, then synced lyrics, then the smallest duration gap.</summary>
    public static Record? BestMatch(IReadOnlyList<Record> records, double? duration)
    {
        var withText = records.Where(r => r.Instrumental == true || HasText(r.SyncedLyrics) || HasText(r.PlainLyrics)).ToList();
        List<Record> pool;
        if (duration is > 0 and var d)
        {
            var close = withText.Where(r => Math.Abs((r.Duration ?? double.PositiveInfinity) - d) <= 3).ToList();
            pool = close.Count == 0 ? withText.Where(r => Math.Abs((r.Duration ?? double.PositiveInfinity) - d) <= 10).ToList() : close;
        }
        else
        {
            pool = withText;
        }
        Record? best = null;
        foreach (var r in pool)
        {
            if (best is null || Less(r, best)) best = r;
        }
        return best;

        bool Less(Record a, Record b)
        {
            bool sa = HasText(a.SyncedLyrics), sb = HasText(b.SyncedLyrics);
            if (sa != sb) return sa;
            if (duration is not { } dd) return false;
            return Math.Abs((a.Duration ?? double.PositiveInfinity) - dd) < Math.Abs((b.Duration ?? double.PositiveInfinity) - dd);
        }
    }

    public static Lyrics? LyricsFrom(Record record)
    {
        if (record.SyncedLyrics is { } synced && HasText(synced))
        {
            var lines = ParseLrc(synced);
            if (lines.Count > 0) return new Lyrics(lines, Source);
        }
        if (record.PlainLyrics is { } plain && HasText(plain))
        {
            return new Lyrics(SplitLines(plain).Select(l => new LyricLine(null, TrimSpaces(l))).ToList(), Source);
        }
        if (record.Instrumental == true) return new Lyrics([new LyricLine(null, "Instrumental")], Source);
        return null;
    }

    /// <summary>
    /// Parses LRC text into time-ordered lines. Handles <c>[mm:ss.xx]</c>, <c>[mm:ss.xxx]</c>, <c>[mm:ss]</c>,
    /// <c>[mm:ss:xx]</c>, several timestamps on one line, and the <c>[offset:±ms]</c> tag (positive offsets shift lyrics
    /// earlier). Other tags are ignored.
    /// </summary>
    public static IReadOnlyList<LyricLine> ParseLrc(string text)
    {
        double offset = 0;
        var lines = new List<(double Time, int Order, string Text)>();
        var order = 0;
        foreach (var rawLine in SplitLines(text))
        {
            var rest = TrimSpaces(rawLine).AsSpan();
            var times = new List<double>();
            while (rest.StartsWith("[") && rest.IndexOf(']') is var close and >= 0)
            {
                var tag = rest[1..close];
                if (ParseTimestamp(tag) is { } time) times.Add(time);
                else if (tag.ToString().ToLowerInvariant().StartsWith("offset:", StringComparison.Ordinal))
                {
                    var value = TrimSpaces(tag["offset:".Length..].ToString());
                    if (double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var ms)) offset = ms / 1000;
                }
                rest = rest[(close + 1)..];
            }
            if (times.Count == 0) continue;
            var lyric = TrimSpaces(rest.ToString());
            foreach (var time in times) lines.Add((time, order++, lyric));
        }
        return lines
            .OrderBy(l => l.Time).ThenBy(l => l.Order)
            .Select(l => new LyricLine(Math.Max(0, l.Time - offset), l.Text))
            .ToList();
    }

    internal static double? ParseTimestamp(ReadOnlySpan<char> tag)
    {
        var parts = tag.ToString().Split(':');
        if (parts.Length is not (2 or 3) || !TryInt(parts[0], out var minutes) || minutes < 0) return null;
        double secondsPart;
        if (parts.Length == 3)
        {
            // [mm:ss:xx] (hundredths after a colon)
            if (!TryInt(parts[1], out var s) || !TryInt(parts[2], out var f)) return null;
            secondsPart = s + f / Math.Pow(10, parts[2].Length);
        }
        else
        {
            if (parts[1].Length == 0 || !char.IsNumber(parts[1][0])
                || !double.TryParse(parts[1], NumberStyles.AllowDecimalPoint | NumberStyles.AllowExponent, CultureInfo.InvariantCulture, out var s))
                return null;
            secondsPart = s;
        }
        if (secondsPart is < 0 or >= 60) return null;
        return minutes * 60 + secondsPart;
    }

    private static bool TryInt(string s, out int value) =>
        int.TryParse(s, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out value);

    /// <summary>Swift's <c>components(separatedBy: .newlines)</c>: every newline character splits, so "\r\n" leaves an
    /// empty piece between.</summary>
    private static string[] SplitLines(string s) => s.Split(['\n', '\r', '\u000B', '\u000C', '\u0085', (char)0x2028, (char)0x2029]);

    /// <summary>Swift's <c>trimmingCharacters(in: .whitespaces)</c>: spaces and tabs, not newlines.</summary>
    private static string TrimSpaces(string s) => s.Trim(' ', '\t', '\u00A0', '\u1680', '\u2000', '\u2001', '\u2002', '\u2003', '\u2004',
        '\u2005', '\u2006', '\u2007', '\u2008', '\u2009', '\u200A', '\u202F', '\u205F', '\u3000');

    private static bool HasText(string? s) => !string.IsNullOrWhiteSpace(s);
}
