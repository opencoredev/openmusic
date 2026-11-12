using System.Globalization;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Medley.Core;
using Medley.Providers.YouTube.Auth;
using Medley.Providers.YouTube.Json;
using Medley.Providers.YouTube.Parsing;

namespace Medley.Providers.YouTube.InnerTube;

/// <summary>
/// The account a write must go out as: its datasync account id (<c>YouTubeMusicProvider.AccountIdOf</c>) the app checked,
/// or, without one, the client's credential generation it checked in.
/// </summary>
public sealed record WriteBinding(string? AccountId, int Generation);

/// <summary>
/// Low-level InnerTube transport (Swift: <c>InnerTubeClient</c>): client context, visitor id, auth headers, rotated
/// cookies, and a short in-memory response cache. Thread-safe; state changes happen under one lock, network and disk I/O
/// outside it. It never saves anything: the provider decides what is saved (<see cref="CredentialsRotated"/>).
/// </summary>
public sealed partial class InnerTubeClient : IDisposable
{
    public const string FallbackWebRemixVersion = "1.20261027.10.00";
    const string MusicHost = "music.youtube.com";
    static readonly TimeSpan CacheTtl = TimeSpan.FromSeconds(300);
    const int CacheLimit = 48;
    static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(20);

    readonly Lock _lock = new();
    readonly HttpClient _http;
    readonly bool _ownsHttp;
    readonly TimeProvider _time;

    string _webRemixVersion = FallbackWebRemixVersion;
    string? _visitorData;
    YouTubeMusicCredentials? _credentials;
    Task? _bootstrapTask;
    readonly Dictionary<string, (DateTimeOffset Expires, byte[] Data)> _cache = new(StringComparer.Ordinal);
    readonly LinkedList<string> _cacheOrder = new();

    /// <summary>
    /// Bumped on every replacement of the credentials (sign-in, swap, sign-out; not a cookie rotation). A response's
    /// <c>Set-Cookie</c> updates apply only if the generation it was sent in is still current, so a slow answer to account A
    /// never rewrites account B's cookies.
    /// </summary>
    int _credentialGeneration;

    /// <summary>"en" always: a few heuristics read English labels ("Single", "EP", "songs").</summary>
    public string Hl { get; private set; } = "en";

    /// <summary>The user's region, so charts and availability match where they are.</summary>
    public string Gl { get; private set; } = DefaultRegion();

    /// <param name="credentials">Initial credentials (generation 0).</param>
    /// <param name="handler">Tests only: a fake handler. The app uses a pooled handler without cookies or cache.</param>
    public InnerTubeClient(YouTubeMusicCredentials? credentials = null, HttpMessageHandler? handler = null, TimeProvider? time = null)
    {
        _credentials = credentials;
        _time = time ?? TimeProvider.System;
        if (handler != null)
        {
            _http = new HttpClient(handler, disposeHandler: false) { Timeout = Timeout.InfiniteTimeSpan };
        }
        else
        {
            _http = new HttpClient(CreateHandler(), disposeHandler: true) { Timeout = Timeout.InfiniteTimeSpan };
        }
        _ownsHttp = true;
    }

    /// <summary>The shared HTTP pipeline: gzip/deflate/brotli, no cookie container, at most 6 connections per host.</summary>
    public static SocketsHttpHandler CreateHandler() => new()
    {
        AutomaticDecompression = DecompressionMethods.All,
        UseCookies = false,
        MaxConnectionsPerServer = 6,
        PooledConnectionLifetime = TimeSpan.FromMinutes(5),
        ConnectTimeout = TimeSpan.FromSeconds(15),
        AllowAutoRedirect = true,
    };

    internal HttpClient Http => _http;

    static string DefaultRegion()
    {
        try
        {
            var region = RegionInfo.CurrentRegion.TwoLetterISORegionName;
            return region.Length == 2 && region != "IV" ? region : "US";
        }
        catch (ArgumentException)
        {
            return "US";
        }
    }

    public bool IsSignedIn { get { lock (_lock) return _credentials != null; } }

    /// <summary>The session's cookies as they are now (rotations included). For the sign-in transfer.</summary>
    public YouTubeMusicCredentials? CurrentCredentials { get { lock (_lock) return _credentials; } }

    public string WebRemixVersion { get { lock (_lock) return _webRemixVersion; } }

    public string? VisitorData { get { lock (_lock) return _visitorData; } }

    /// <summary>Bumped by every replacement of the credentials; a cookie rotation keeps it.</summary>
    public int Generation { get { lock (_lock) return _credentialGeneration; } }

    /// <summary>The credentials and their generation, read together.</summary>
    public (YouTubeMusicCredentials? Credentials, int Generation) Installed { get { lock (_lock) return (_credentials, _credentialGeneration); } }

    /// <summary>
    /// Called after a response rotated the current credentials' cookies, with their generation, outside the client's lock.
    /// The provider saves them (when the sign-in is saved) as an account operation.
    /// </summary>
    internal Action<int>? CredentialsRotated { get; set; }

    /// <summary>Replaces the credentials (null: signed out) and drops the cache. Returns the new generation.</summary>
    public int SetCredentials(YouTubeMusicCredentials? credentials)
    {
        lock (_lock)
        {
            _credentials = credentials;
            _credentialGeneration = unchecked(_credentialGeneration + 1);
            ClearCacheLocked();
            return _credentialGeneration;
        }
    }

    public void ClearCache()
    {
        lock (_lock) ClearCacheLocked();
    }

    void ClearCacheLocked()
    {
        _cache.Clear();
        _cacheOrder.Clear();
    }

    /// <summary>Throws <see cref="PlaylistEditException"/> (account changed) when the credentials a write would go out with aren't the account it was checked for.</summary>
    public void CheckWriteBinding(WriteBinding? binding)
    {
        lock (_lock) CheckWriteBindingLocked(binding);
    }

    void CheckWriteBindingLocked(WriteBinding? binding)
    {
        if (binding == null) return;
        if (_credentials == null) throw PlaylistEditException.AccountChanged();
        var held = binding.AccountId is { } expected
            ? YouTubeMusicProvider.AccountIdOf(_credentials) == expected
            : _credentialGeneration == binding.Generation;
        if (!held) throw PlaylistEditException.AccountChanged();
    }

    public void SetLocale(string hl, string gl)
    {
        lock (_lock)
        {
            Hl = hl;
            Gl = gl;
        }
    }

    /// <summary>
    /// The account switcher music.youtube.com shows under the avatar: every Google account signed in to the session and
    /// every channel under each. Throws on a network or server failure; an unreadable body yields an empty list.
    /// </summary>
    public async Task<IReadOnlyList<AccountIdentity>> AccountIdentitiesAsync(CancellationToken cancellationToken = default)
    {
        YouTubeMusicCredentials creds;
        int generation;
        lock (_lock)
        {
            creds = _credentials ?? throw ProviderException.NotSignedIn();
            generation = _credentialGeneration;
        }
        var url = new Uri("https://music.youtube.com/getAccountSwitcherEndpoint");
        HttpRequestMessage Build()
        {
            var request = new HttpRequestMessage(HttpMethod.Get, url);
            request.Headers.TryAddWithoutValidation("User-Agent", InnerTubeProfile.SafariUserAgent);
            request.Headers.TryAddWithoutValidation("Origin", "https://music.youtube.com");
            request.Headers.TryAddWithoutValidation("Referer", "https://music.youtube.com/");
            foreach (var (k, v) in creds.Headers(_time.GetUtcNow())) request.Headers.TryAddWithoutValidation(k, v);
            return request;
        }
        var data = await SendAsync(Build, authenticated: true, generation, idempotent: true, cancellationToken).ConfigureAwait(false);
        var text = Encoding.UTF8.GetString(data);
        if (text.StartsWith(")]}'", StringComparison.Ordinal)) text = text[4..];
        return AccountSwitcherParser.Identities(text);
    }

    // MARK: Bootstrap

    /// <summary>Reads the current WEB_REMIX version and a visitor id from <c>music.youtube.com/sw.js_data</c> (2.5 KB), once.</summary>
    public Task BootstrapAsync()
    {
        lock (_lock) return _bootstrapTask ??= LoadServiceWorkerDataAsync();
    }

    /// <summary>Drops the visitor id and fetches a new one.</summary>
    public async Task RefreshVisitorAsync()
    {
        lock (_lock) _visitorData = null;
        await LoadServiceWorkerDataAsync().ConfigureAwait(false);
    }

    async Task LoadServiceWorkerDataAsync()
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, "https://music.youtube.com/sw.js_data");
            request.Headers.TryAddWithoutValidation("User-Agent", InnerTubeProfile.SafariUserAgent);
            using var cts = new CancellationTokenSource(RequestTimeout);
            using var response = await _http.SendAsync(request, cts.Token).ConfigureAwait(false);
            if (response.StatusCode != HttpStatusCode.OK) return;
            var text = await response.Content.ReadAsStringAsync(cts.Token).ConfigureAwait(false);
            var version = FirstMatch(VersionRegex(), text);
            var visitor = ServiceWorkerVisitor(text);
            lock (_lock)
            {
                if (version != null) _webRemixVersion = version;
                if (_visitorData == null && visitor != null) _visitorData = visitor;
            }
        }
        catch (Exception e) when (e is HttpRequestException or OperationCanceledException or IOException)
        {
            // Offline: keep the fallback version; a visitor id arrives with the first answer instead.
        }
    }

    [GeneratedRegex(@"\b1\.20[0-9]{6}\.[0-9]{2}\.[0-9]{2}\b")]
    internal static partial Regex VersionRegex();

    [GeneratedRegex(@"Cg[A-Za-z0-9_\-]{20,}={0,2}")]
    internal static partial Regex VisitorRegex();

    /// <summary><c>)]}'\n[["yt.sw.adr",null,[[[hl, gl, …, visitorData (index 13), …</c></summary>
    public static string? ServiceWorkerVisitor(string text)
    {
        var body = text.StartsWith(")]}'", StringComparison.Ordinal) ? text[4..] : text;
        try
        {
            if (JsonNav.Parse(body) is JsonArray json && json.Any("0", "2", "0", "0", "13") is { } v &&
                JsonNav.AsString(v) is { } visitor && visitor.StartsWith("Cg", StringComparison.Ordinal))
            {
                return visitor;
            }
        }
        catch (JsonException)
        {
        }
        return FirstMatch(VisitorRegex(), text);
    }

    public static string? FirstMatch(Regex regex, string text)
    {
        var m = regex.Match(text);
        return m.Success ? m.Value : null;
    }

    // MARK: Requests

    /// <summary>
    /// POST <c>youtubei/v1/&lt;endpoint&gt;</c> with the given client identity and return the parsed JSON.
    /// <paramref name="idempotent"/> reads are retried once on a dropped connection or a 502/503/504; writes never are.
    /// </summary>
    public async Task<JsonObject> PostAsync(
        string endpoint,
        JsonObject? body = null,
        InnerTubeProfile? profile = null,
        IReadOnlyList<KeyValuePair<string, string>>? query = null,
        bool authenticated = true,
        bool cacheable = false,
        bool sendVisitor = true,
        WriteBinding? binding = null,
        bool idempotent = true,
        CancellationToken cancellationToken = default)
    {
        await BootstrapAsync().WaitAsync(cancellationToken).ConfigureAwait(false);

        YouTubeMusicCredentials? creds;
        string? visitorData;
        int generation;
        string hl, gl;
        lock (_lock)
        {
            // A bound write: the cookies are picked here, under the same lock as the check.
            CheckWriteBindingLocked(binding);
            profile ??= InnerTubeProfile.WebRemix(_webRemixVersion);
            creds = _credentials;
            visitorData = sendVisitor ? _visitorData : null;
            generation = _credentialGeneration;
            hl = Hl;
            gl = Gl;
        }
        var useAuth = authenticated && creds != null && profile.Host == MusicHost;

        var client = new JsonObject
        {
            ["clientName"] = profile.ClientName,
            ["clientVersion"] = profile.ClientVersion,
            ["hl"] = hl,
            ["gl"] = gl,
            ["userAgent"] = profile.UserAgent,
        };
        if (profile.ExtraContext != null)
        {
            foreach (var (k, v) in profile.ExtraContext) client[k] = v;
        }
        if (profile.AndroidSdkVersion is { } sdk) client["androidSdkVersion"] = sdk;
        if (visitorData != null) client["visitorData"] = visitorData;
        var user = new JsonObject { ["lockedSafetyMode"] = false };
        // Act as the chosen brand channel, selected by its delegated session id (same value as X-Goog-PageId), the
        // way youtube.com's own client does. A personal account has none.
        if (useAuth && creds!.DelegatedSessionId is { } delegated) user["onBehalfOfUser"] = delegated;
        var payload = body ?? new JsonObject();
        payload["context"] = new JsonObject { ["client"] = client, ["user"] = user };
        var bodyText = SwiftJson.Serialize(payload);

        var urlText = new StringBuilder($"https://{profile.Host}/youtubei/v1/{endpoint}?prettyPrint=false");
        foreach (var (k, v) in query ?? [])
        {
            urlText.Append('&').Append(QueryEscape(k)).Append('=').Append(QueryEscape(v));
        }
        var url = new Uri(urlText.ToString());

        // Keyed by the credential generation too: two accounts' requests can be byte-identical (same authUser, no channel).
        var key = cacheable ? $"{(useAuth ? "true" : "false")}|{generation}|{urlText}|{bodyText}" : null;
        if (key != null)
        {
            byte[]? hit = null;
            lock (_lock)
            {
                if (_cache.TryGetValue(key, out var entry) && entry.Expires > _time.GetUtcNow()) hit = entry.Data;
            }
            if (hit != null) return ParseObject(hit);
        }

        if (Environment.GetEnvironmentVariable("MEDLEY_YTM_DEBUG") != null)
        {
            Console.Error.WriteLine($"→ {urlText}\n{(bodyText.Length > 600 ? bodyText[..600] : bodyText)}");
        }

        var sentProfile = profile;
        HttpRequestMessage Build()
        {
            var request = new HttpRequestMessage(HttpMethod.Post, url)
            {
                Content = new StringContent(bodyText, Encoding.UTF8, "application/json"),
            };
            request.Content.Headers.ContentType!.CharSet = null;
            request.Headers.TryAddWithoutValidation("User-Agent", sentProfile.UserAgent);
            request.Headers.TryAddWithoutValidation("X-YouTube-Client-Name", sentProfile.ClientId.ToString(CultureInfo.InvariantCulture));
            request.Headers.TryAddWithoutValidation("X-YouTube-Client-Version", sentProfile.ClientVersion);
            request.Headers.TryAddWithoutValidation("Origin", $"https://{sentProfile.Host}");
            request.Headers.TryAddWithoutValidation("Referer", $"https://{sentProfile.Host}/");
            if (visitorData != null) request.Headers.TryAddWithoutValidation("X-Goog-Visitor-Id", visitorData);
            if (useAuth)
            {
                foreach (var (k, v) in creds!.Headers(_time.GetUtcNow())) request.Headers.TryAddWithoutValidation(k, v);
            }
            return request;
        }

        var data = await SendAsync(Build, useAuth, generation, idempotent, cancellationToken).ConfigureAwait(false);
        var json = ParseObject(data);
        lock (_lock)
        {
            if (_visitorData == null && sendVisitor && json.S("responseContext", "visitorData") is { } v) _visitorData = v;
            // A late answer sent with replaced credentials never fills the new account's cache (Sol's review; Swift has
            // the same gap).
            if (key != null && generation == _credentialGeneration) StoreLocked(key, data);
        }
        return json;
    }

    /// <summary>
    /// Sends with rotation handling and the Swift client's status mapping. <paramref name="generation"/> names the
    /// credentials the request was built with.
    /// </summary>
    async Task<byte[]> SendAsync(Func<HttpRequestMessage> build, bool authenticated, int generation, bool idempotent, CancellationToken cancellationToken)
    {
        var attempts = idempotent ? 2 : 1;
        for (var attempt = 1; ; attempt++)
        {
            using var request = build();
            HttpResponseMessage response;
            byte[] data;
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            cts.CancelAfter(RequestTimeout);
            try
            {
                response = await _http.SendAsync(request, HttpCompletionOption.ResponseContentRead, cts.Token).ConfigureAwait(false);
                data = await response.Content.ReadAsByteArrayAsync(cts.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception e) when (e is HttpRequestException or OperationCanceledException or IOException)
            {
                if (attempt < attempts)
                {
                    await Task.Delay(300, cancellationToken).ConfigureAwait(false);
                    continue;
                }
                throw ProviderException.Network(e is OperationCanceledException ? "The request timed out." : e.Message, e);
            }

            using (response)
            {
                if (authenticated && response.Headers.TryGetValues("Set-Cookie", out var setCookies) && request.RequestUri is { } requestUrl)
                {
                    ApplyRotation(setCookies.ToList(), requestUrl, generation);
                }
                var status = (int)response.StatusCode;
                if (status is >= 200 and < 300) return data;
                if (attempt < attempts && status is 502 or 503 or 504)
                {
                    await Task.Delay(300, cancellationToken).ConfigureAwait(false);
                    continue;
                }
                throw status switch
                {
                    401 => ProviderException.NotSignedIn(),
                    403 => authenticated ? ProviderException.NotSignedIn() : ProviderException.Server(403, ErrorMessage(data)),
                    404 => ProviderException.NotFound(),
                    429 => ProviderException.RateLimited(),
                    _ => ProviderException.Server(status, ErrorMessage(data)),
                };
            }
        }
    }

    void ApplyRotation(List<string> setCookies, Uri url, int generation)
    {
        lock (_lock)
        {
            if (generation != _credentialGeneration || _credentials == null) return;
            if (_credentials.Merge(setCookies, url, _time.GetUtcNow()) is not { } merged) return;
            _credentials = merged;
        }
        CredentialsRotated?.Invoke(generation);
    }

    internal static string ErrorMessage(byte[] data)
    {
        try
        {
            if (JsonNav.Parse(data) is JsonObject json && json.S("error", "message") is { } message) return message;
        }
        catch (JsonException)
        {
        }
        var text = Encoding.UTF8.GetString(data, 0, Math.Min(200, data.Length));
        return text;
    }

    internal static JsonObject ParseObject(byte[] data)
    {
        try
        {
            return JsonNav.Parse(data) as JsonObject ?? throw ProviderException.Decoding("expected a JSON object");
        }
        catch (JsonException e)
        {
            throw ProviderException.Decoding(e.Message);
        }
    }

    void StoreLocked(string key, byte[] data)
    {
        if (!_cache.ContainsKey(key)) _cacheOrder.AddLast(key);
        _cache[key] = (_time.GetUtcNow() + CacheTtl, data);
        while (_cacheOrder.Count > CacheLimit)
        {
            var oldest = _cacheOrder.First!.Value;
            _cacheOrder.RemoveFirst();
            _cache.Remove(oldest);
        }
    }

    /// <summary>Characters Foundation's <c>URLComponents.queryItems</c> leaves as they are (checked on macOS 27).</summary>
    const string QueryAllowed = "!$'()*+,-./:;?@_~";

    /// <summary>Percent-encodes a query name or value exactly as the Swift client's <c>URLComponents</c> does.</summary>
    internal static string QueryEscape(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (var b in Encoding.UTF8.GetBytes(s))
        {
            var c = (char)b;
            if (b < 0x80 && (char.IsAsciiLetterOrDigit(c) || QueryAllowed.Contains(c))) sb.Append(c);
            else sb.Append('%').Append(b.ToString("X2", CultureInfo.InvariantCulture));
        }
        return sb.ToString();
    }

    // MARK: Convenience

    public Task<JsonObject> BrowseAsync(string browseId, string? @params = null, bool cacheable = true, bool sendVisitor = true, CancellationToken cancellationToken = default)
    {
        var body = new JsonObject { ["browseId"] = browseId };
        if (@params != null) body["params"] = @params;
        return PostAsync("browse", body, cacheable: cacheable, sendVisitor: sendVisitor, cancellationToken: cancellationToken);
    }

    /// <summary>Follows an encoded continuation token from <see cref="ContinuationToken"/>.</summary>
    public Task<JsonObject> BrowseContinuationAsync(string token, bool cacheable = true, CancellationToken cancellationToken = default)
    {
        if (token.StartsWith("q:", StringComparison.Ordinal))
        {
            var raw = token[2..];
            return PostAsync("browse", query: [new("ctoken", raw), new("continuation", raw), new("type", "next")], cacheable: cacheable, cancellationToken: cancellationToken);
        }
        var bodyToken = token.StartsWith("b:", StringComparison.Ordinal) ? token[2..] : token;
        return PostAsync("browse", new JsonObject { ["continuation"] = bodyToken }, cacheable: cacheable, cancellationToken: cancellationToken);
    }

    public void Dispose()
    {
        if (_ownsHttp) _http.Dispose();
    }
}
