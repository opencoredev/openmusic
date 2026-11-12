using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using OpenMusic.Providers.YouTube.Json;

namespace OpenMusic.Providers.YouTube.Auth;

/// <summary>
/// Google session cookies for music.youtube.com and the auth headers the web client derives from them
/// (Swift: <c>YTMCredentials</c>). Immutable: changes return a new value.
/// </summary>
/// <remarks>
/// <see cref="ToJson"/> / <see cref="FromJson(string)"/> use the Swift Codable shape
/// (<c>{"authUser":0,"cookies":{…},"datasyncId":"…"}</c>), so the same value can be stored by the app and sent inside
/// the sign-in transfer.
/// </remarks>
public sealed class YouTubeMusicCredentials : IEquatable<YouTubeMusicCredentials>
{
    public const string Origin = "https://music.youtube.com";

    readonly SortedDictionary<string, string> _cookies;

    /// <summary>Cookie name → value, for cookies scoped to .youtube.com.</summary>
    public IReadOnlyDictionary<string, string> Cookies => _cookies;

    /// <summary>Multi-login index (<c>X-Goog-AuthUser</c>): which Google account signed in to the browser.</summary>
    public int AuthUser { get; }

    /// <summary>
    /// The chosen channel's datasync id as the account switcher gives it: <c>delegatedSessionId||userSessionId</c> for a
    /// brand channel, no delegated prefix for a personal account. Null means the account's default channel.
    /// </summary>
    public string? DatasyncId { get; }

    public YouTubeMusicCredentials(IEnumerable<KeyValuePair<string, string>> cookies, int authUser = 0, string? datasyncId = null)
    {
        _cookies = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var (k, v) in cookies) _cookies[k] = v;
        AuthUser = authUser;
        DatasyncId = datasyncId;
    }

    public YouTubeMusicCredentials WithAccount(int authUser, string? datasyncId) => new(_cookies, authUser, datasyncId);

    public YouTubeMusicCredentials WithCookie(string name, string? value)
    {
        var jar = new Dictionary<string, string>(_cookies);
        if (value == null) jar.Remove(name); else jar[name] = value;
        return new YouTubeMusicCredentials(jar, AuthUser, DatasyncId);
    }

    /// <summary>
    /// The delegated session id a brand channel is selected by (the part before <c>||</c>), sent as both
    /// <c>X-Goog-PageId</c> and context <c>onBehalfOfUser</c>. Null for a personal account.
    /// </summary>
    public string? DelegatedSessionId => DelegatedSessionIdOf(DatasyncId);

    public static string? DelegatedSessionIdOf(string? datasyncId)
    {
        if (datasyncId == null) return null;
        var sep = datasyncId.IndexOf("||", StringComparison.Ordinal);
        if (sep < 0) return null;
        var prefix = datasyncId[..sep];
        var suffix = datasyncId[(sep + 2)..];
        // A brand channel is `delegatedSessionId||userSessionId`: both sides present.
        return prefix.Length == 0 || suffix.Length == 0 ? null : prefix;
    }

    /// <summary>Parses a <c>Cookie:</c> header as copied from a browser's dev tools (with or without the prefix).</summary>
    public static YouTubeMusicCredentials? FromCookieHeader(string raw)
    {
        var text = raw.Trim();
        if (text.StartsWith("cookie:", StringComparison.OrdinalIgnoreCase)) text = text[7..];
        var jar = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var pair in text.Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            var trimmed = pair.Trim();
            var eq = trimmed.IndexOf('=');
            if (eq < 0) continue;
            var name = trimmed[..eq].Trim();
            var value = trimmed[(eq + 1)..].Trim();
            if (value.Length >= 2 && value.StartsWith('"') && value.EndsWith('"')) value = value[1..^1];
            if (name.Length > 0) jar[name] = value;
        }
        var creds = new YouTubeMusicCredentials(jar);
        return creds.IsUsable ? creds : null;
    }

    /// <summary>True when the jar has what InnerTube needs to authenticate a request.</summary>
    public bool IsUsable => Sapisid != null &&
        (_cookies.ContainsKey("SID") || _cookies.ContainsKey("__Secure-3PSID") || _cookies.ContainsKey("__Secure-1PSID"));

    public string? Sapisid => _cookies.GetValueOrDefault("SAPISID") ?? _cookies.GetValueOrDefault("__Secure-3PAPISID");

    /// <summary>The <c>Cookie</c> header value, names in ordinal order like the Swift client.</summary>
    public string CookieHeader => string.Join("; ", _cookies.Select(kv => $"{kv.Key}={kv.Value}"));

    /// <summary>
    /// <c>SAPISIDHASH &lt;ts&gt;_&lt;sha1("&lt;ts&gt; &lt;SAPISID&gt; &lt;origin&gt;")&gt;</c>, plus the 1P/3P variants the
    /// current web client sends.
    /// </summary>
    public string? Authorization(DateTimeOffset? now = null)
    {
        if (Sapisid is not { } sapisid) return null;
        var ts = (now ?? DateTimeOffset.UtcNow).ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture);
        string Hash(string secret)
        {
            var digest = SHA1.HashData(Encoding.UTF8.GetBytes($"{ts} {secret} {Origin}"));
            return ts + "_" + Convert.ToHexStringLower(digest);
        }
        var parts = new List<string> { "SAPISIDHASH " + Hash(sapisid) };
        if (_cookies.TryGetValue("__Secure-1PAPISID", out var p1)) parts.Add("SAPISID1PHASH " + Hash(p1));
        if (_cookies.TryGetValue("__Secure-3PAPISID", out var p3)) parts.Add("SAPISID3PHASH " + Hash(p3));
        return string.Join(" ", parts);
    }

    /// <summary>Headers for an authenticated InnerTube request.</summary>
    public Dictionary<string, string> Headers(DateTimeOffset? now = null)
    {
        var h = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["Cookie"] = CookieHeader,
            ["X-Origin"] = Origin,
            ["X-Goog-AuthUser"] = AuthUser.ToString(CultureInfo.InvariantCulture),
        };
        if (Authorization(now) is { } auth) h["Authorization"] = auth;
        if (DelegatedSessionId is { } pageId) h["X-Goog-PageId"] = pageId;
        return h;
    }

    /// <summary>
    /// Applies <c>Set-Cookie</c> updates from a response (Google rotates <c>__Secure-*PSIDTS</c> and friends).
    /// Returns the updated credentials, or null when nothing changed.
    /// </summary>
    public YouTubeMusicCredentials? Merge(IEnumerable<string> setCookieHeaders, Uri requestUrl, DateTimeOffset? now = null)
    {
        var clock = now ?? DateTimeOffset.UtcNow;
        Dictionary<string, string>? jar = null;
        foreach (var header in setCookieHeaders)
        {
            if (SetCookie.Parse(header, requestUrl, clock) is not { } cookie) continue;
            if (!cookie.Domain.EndsWith("youtube.com", StringComparison.OrdinalIgnoreCase)) continue;
            var current = jar ?? (IReadOnlyDictionary<string, string>)_cookies;
            if (cookie.Expired)
            {
                if (current.ContainsKey(cookie.Name)) (jar ??= new Dictionary<string, string>(_cookies)).Remove(cookie.Name);
            }
            else if (!current.TryGetValue(cookie.Name, out var old) || old != cookie.Value)
            {
                (jar ??= new Dictionary<string, string>(_cookies))[cookie.Name] = cookie.Value;
            }
        }
        return jar == null ? null : new YouTubeMusicCredentials(jar, AuthUser, DatasyncId);
    }

    // MARK: JSON (the Swift Codable shape)

    /// <summary>The Swift Codable shape, keys sorted: <c>{"authUser":…,"cookies":{…},"datasyncId":…}</c>.</summary>
    public string ToJson() => SwiftJson.Serialize(ToJsonNode());

    internal JsonObject ToJsonNode()
    {
        var cookies = new JsonObject();
        foreach (var (k, v) in _cookies) cookies[k] = v;
        var o = new JsonObject { ["authUser"] = AuthUser, ["cookies"] = cookies };
        if (DatasyncId != null) o["datasyncId"] = DatasyncId;
        return o;
    }

    public static YouTubeMusicCredentials FromJson(string json) =>
        FromJsonNode(JsonNav.Parse(json) as JsonObject ?? throw new FormatException("expected a JSON object"));

    public static YouTubeMusicCredentials FromJson(ReadOnlySpan<byte> utf8) =>
        FromJsonNode(JsonNav.Parse(utf8) as JsonObject ?? throw new FormatException("expected a JSON object"));

    /// <summary>
    /// Reads the Swift shape. Strict where Swift's synthesized Codable is (cookies must be a string map; authUser, when
    /// present, an integer); a missing authUser reads as 0.
    /// </summary>
    internal static YouTubeMusicCredentials FromJsonNode(JsonObject o)
    {
        if (o.Get("cookies") is not JsonObject cookieNode) throw new FormatException("cookies missing");
        var jar = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var (k, v) in cookieNode) jar[k] = JsonNav.AsString(v) ?? throw new FormatException($"cookie {k} is not a string");
        var authUser = 0;
        if (o.Get("authUser") is { } au) authUser = o.I("authUser") ?? throw new FormatException("authUser is not an integer");
        string? datasync = null;
        if (o.Get("datasyncId") is { } ds) datasync = JsonNav.AsString(ds) ?? throw new FormatException("datasyncId is not a string");
        return new YouTubeMusicCredentials(jar, authUser, datasync);
    }

    public bool Equals(YouTubeMusicCredentials? other) =>
        other != null && AuthUser == other.AuthUser && DatasyncId == other.DatasyncId &&
        _cookies.Count == other._cookies.Count && _cookies.All(kv => other._cookies.TryGetValue(kv.Key, out var v) && v == kv.Value);

    public override bool Equals(object? obj) => Equals(obj as YouTubeMusicCredentials);

    public override int GetHashCode()
    {
        var h = new HashCode();
        h.Add(AuthUser);
        h.Add(DatasyncId);
        foreach (var (k, v) in _cookies) { h.Add(k); h.Add(v); }
        return h.ToHashCode();
    }

    /// <summary>Never prints cookie values.</summary>
    public override string ToString() => $"YouTubeMusicCredentials(authUser: {AuthUser}, channel: {(DelegatedSessionId != null ? "brand" : "default")}, cookies: <{_cookies.Count} redacted>)";
}

/// <summary>A minimal RFC 6265 <c>Set-Cookie</c> reader: name, value, domain and expiry.</summary>
internal sealed record SetCookie(string Name, string Value, string Domain, bool Expired)
{
    public static SetCookie? Parse(string header, Uri requestUrl, DateTimeOffset now)
    {
        var parts = header.Split(';');
        var first = parts[0];
        var eq = first.IndexOf('=');
        if (eq <= 0) return null;
        var name = first[..eq].Trim();
        var value = first[(eq + 1)..].Trim();
        if (value.Length >= 2 && value.StartsWith('"') && value.EndsWith('"')) value = value[1..^1];
        if (name.Length == 0) return null;
        var domain = requestUrl.Host;
        DateTimeOffset? expires = null;
        long? maxAge = null;
        foreach (var attr in parts.Skip(1))
        {
            var a = attr.Trim();
            var aeq = a.IndexOf('=');
            var key = (aeq < 0 ? a : a[..aeq]).Trim();
            var val = aeq < 0 ? "" : a[(aeq + 1)..].Trim();
            if (key.Equals("domain", StringComparison.OrdinalIgnoreCase) && val.Length > 0)
            {
                domain = val.TrimStart('.');
            }
            else if (key.Equals("max-age", StringComparison.OrdinalIgnoreCase) &&
                     long.TryParse(val, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var seconds))
            {
                maxAge = seconds;
            }
            else if (key.Equals("expires", StringComparison.OrdinalIgnoreCase) && ParseDate(val) is { } date)
            {
                expires = date;
            }
        }
        // Max-Age wins over Expires (RFC 6265 §5.3).
        var expired = maxAge is { } m ? m <= 0 : expires is { } e && e < now;
        return new SetCookie(name, value, domain, expired);
    }

    static readonly string[] DateFormats =
    [
        "ddd, dd MMM yyyy HH:mm:ss 'GMT'", "ddd, dd-MMM-yyyy HH:mm:ss 'GMT'", "dddd, dd-MMM-yy HH:mm:ss 'GMT'",
        "ddd, dd-MMM-yy HH:mm:ss 'GMT'", "ddd MMM d HH:mm:ss yyyy", "ddd, d MMM yyyy HH:mm:ss 'GMT'",
    ];

    static DateTimeOffset? ParseDate(string text) =>
        DateTimeOffset.TryParseExact(text, DateFormats, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var d)
            ? d
            : DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var d2) ? d2 : null;
}
