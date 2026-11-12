using System.Globalization;
using System.Net;
using Medley.Core;
using Medley.Providers.YouTube.InnerTube;

namespace Medley.Providers.YouTube.Playback;

/// <summary>Which rendition of one client's answer is tried first.</summary>
public enum StreamPreference
{
    /// <summary>
    /// The progressive itag-140 AAC/MP4 URL, then the HLS audio rendition. The Windows default: Media Foundation plays
    /// progressive MP4 with range requests natively. (The Swift client prefers HLS only because AVFoundation reports
    /// twice the real length for YouTube's fragmented MP4s.)
    /// </summary>
    Direct,

    /// <summary>The HLS audio-only rendition (itag 234), then the direct URL: the Swift client's order.</summary>
    Hls,
}

/// <summary>A resolved stream and which client produced it.</summary>
public sealed record StreamResolution(PlayableStream Stream, string Client, int? Itag);

/// <summary>
/// Resolves a YouTube Music track to a playable audio stream (Swift: <c>YouTubeStreamResolver</c>).
/// Asks the InnerTube clients that still return playable googlevideo URLs without a PO token or player-JS deciphering,
/// in order, and verifies what they return before handing it out:
/// 1. VISIONOS: HLS manifest + direct itag 140 URLs.
/// 2. ANDROID_VR 1.60.19: direct itag 140 URLs (no HLS for VOD), also reports <c>loudnessDb</c>.
/// 3. IOS: HLS manifest only (its direct formats need a PO token).
/// The client that worked last is tried first next time. A "confirm you're not a bot" refusal gets one retry with a
/// fresh visitor id.
/// </summary>
public sealed class YouTubeStreamResolver : IStreamResolver
{
    public static readonly IReadOnlyList<(string Name, InnerTubeProfile Profile)> Order =
    [
        ("VISIONOS", InnerTubeProfile.VisionOS),
        ("ANDROID_VR", InnerTubeProfile.AndroidVR),
        ("IOS", InnerTubeProfile.IOS),
    ];

    public const string HlsMimeType = "application/vnd.apple.mpegurl";

    readonly InnerTubeClient _client;
    readonly Func<string, CancellationToken, Task<StreamResolution>>? _fetchOverride;
    readonly TimeProvider _time;
    readonly Lock _lock = new();
    readonly Dictionary<string, StreamResolution> _cache = new(StringComparer.Ordinal);
    readonly Dictionary<string, Task<StreamResolution>> _inFlight = new(StringComparer.Ordinal);
    string? _preferred;
    int _fetchCount;

    public StreamPreference Preference { get; }

    /// <summary>Uncached lookups performed. Tests and the probe.</summary>
    public int FetchCount { get { lock (_lock) return _fetchCount; } }

    /// <summary>The client tried first next time.</summary>
    public string? PreferredClient { get { lock (_lock) return _preferred; } }

    /// <param name="fetchOverride">Replaces the InnerTube lookup. Tests only.</param>
    public YouTubeStreamResolver(InnerTubeClient client, StreamPreference preference = StreamPreference.Direct,
        Func<string, CancellationToken, Task<StreamResolution>>? fetchOverride = null, TimeProvider? time = null)
    {
        _client = client;
        Preference = preference;
        _fetchOverride = fetchOverride;
        _time = time ?? TimeProvider.System;
    }

    public async Task<PlayableStream> ResolveStreamAsync(Track track, bool forceRefresh = false, CancellationToken ct = default) =>
        (await ResolveAsync(track.ProviderID, forceRefresh, ct).ConfigureAwait(false)).Stream;

    /// <summary>
    /// Resolve (or reuse a cached resolution with more than 10 minutes left) and report which client produced it.
    /// <paramref name="forceRefresh"/> drops the cached entry first: googlevideo can revoke a URL before it expires.
    /// </summary>
    public async Task<StreamResolution> ResolveAsync(string videoId, bool forceRefresh = false, CancellationToken ct = default)
    {
        Task<StreamResolution> task;
        TaskCompletionSource<StreamResolution>? started = null;
        lock (_lock)
        {
            if (forceRefresh)
            {
                _cache.Remove(videoId);
            }
            else if (_cache.TryGetValue(videoId, out var hit) && hit.Stream.ExpiresAt is { } expiry && expiry - _time.GetUtcNow() > TimeSpan.FromSeconds(600))
            {
                return hit;
            }
            // An in-flight lookup is a new request to InnerTube, not the cached URL, so joining it is fine.
            if (!_inFlight.TryGetValue(videoId, out task!))
            {
                started = new TaskCompletionSource<StreamResolution>(TaskCreationOptions.RunContinuationsAsynchronously);
                task = started.Task;
                _inFlight[videoId] = task;
            }
        }
        // The lookup starts outside the lock: nothing that can post to a synchronization context or block runs while
        // it's held.
        if (started is not null) _ = RunAsync(videoId, started);
        return await task.WaitAsync(ct).ConfigureAwait(false);
    }

    async Task RunAsync(string videoId, TaskCompletionSource<StreamResolution> done)
    {
        try
        {
            var result = await Task.Run(() => ResolveUncachedAsync(videoId, CancellationToken.None)).ConfigureAwait(false);
            lock (_lock)
            {
                _cache[videoId] = result;
                if (_cache.Count > 64)
                {
                    var oldest = _cache.MinBy(kv => kv.Value.Stream.ExpiresAt ?? DateTimeOffset.MinValue).Key;
                    _cache.Remove(oldest);
                }
                _inFlight.Remove(videoId);
            }
            done.TrySetResult(result);
        }
        catch (Exception e)
        {
            lock (_lock) _inFlight.Remove(videoId);
            if (e is OperationCanceledException oce) done.TrySetCanceled(oce.CancellationToken);
            else done.TrySetException(e);
        }
    }

    /// <summary>Warms the cache for the next track so next-track starts don't wait on InnerTube.</summary>
    public void Prefetch(string videoId) => _ = ResolveAsync(videoId).ContinueWith(t => _ = t.Exception, TaskScheduler.Default);

    public void Invalidate(string videoId)
    {
        lock (_lock) _cache.Remove(videoId);
    }

    async Task<StreamResolution> ResolveUncachedAsync(string videoId, CancellationToken ct)
    {
        lock (_lock) _fetchCount++;
        if (_fetchOverride != null) return await _fetchOverride(videoId, ct).ConfigureAwait(false);
        try
        {
            return await ResolveOnceAsync(videoId, ct).ConfigureAwait(false);
        }
        catch (ProviderException e) when (e.Kind == ProviderErrorKind.Unplayable && e.Detail?.Contains("not a bot", StringComparison.Ordinal) == true)
        {
            // The visitor id got flagged; a fresh one usually clears it.
            await _client.RefreshVisitorAsync().ConfigureAwait(false);
            return await ResolveOnceAsync(videoId, ct).ConfigureAwait(false);
        }
    }

    /// <summary>The clients in the order they are tried now: the last one that worked first.</summary>
    internal List<(string Name, InnerTubeProfile Profile)> ClientsInOrder()
    {
        var clients = Order.ToList();
        if (Environment.GetEnvironmentVariable("MEDLEY_YTM_CLIENT") is { Length: > 0 } only) // testing: force one client
        {
            clients = clients.Where(c => c.Name == only).ToList();
        }
        string? preferred;
        lock (_lock) preferred = _preferred;
        var i = clients.FindIndex(c => c.Name == preferred);
        if (i > 0)
        {
            var p = clients[i];
            clients.RemoveAt(i);
            clients.Insert(0, p);
        }
        return clients;
    }

    async Task<StreamResolution> ResolveOnceAsync(string videoId, CancellationToken ct)
    {
        var failures = new List<string>();
        foreach (var (name, profile) in ClientsInOrder())
        {
            try
            {
                var info = await _client.PlayerAsync(videoId, profile, ct).ConfigureAwait(false);
                if (info.Status != "OK")
                {
                    // LOGIN_REQUIRED ("confirm you're not a bot"), age gates and "made for kids" differ per client.
                    failures.Add($"{name}: {info.Reason ?? info.Status}");
                    continue;
                }
                if (await UsableAsync(info, name, profile, ct).ConfigureAwait(false) is { } resolution)
                {
                    lock (_lock) _preferred = name;
                    return resolution;
                }
                failures.Add($"{name}: no playable audio");
            }
            catch (Exception e) when (e is not OperationCanceledException)
            {
                failures.Add($"{name}: {e.Message}");
            }
        }
        throw ProviderException.Unplayable(string.Join("; ", failures));
    }

    async Task<StreamResolution?> UsableAsync(PlayerInfo info, string name, InnerTubeProfile profile, CancellationToken ct)
    {
        var expires = _time.GetUtcNow() + TimeSpan.FromSeconds(info.ExpiresIn ?? 6 * 3600);
        var headers = new Dictionary<string, string> { ["User-Agent"] = profile.UserAgent };
        var mode = Environment.GetEnvironmentVariable("MEDLEY_YTM_STREAM"); // "hls" | "direct" (testing)
        var duration = info.LengthSeconds;

        async Task<StreamResolution?> Hls()
        {
            if (mode == "direct" || info.HlsManifestUrl is not { } manifest) return null;
            HlsRendition? audio;
            try { audio = await AudioRenditionAsync(manifest, headers, ct).ConfigureAwait(false); }
            catch (Exception) when (!ct.IsCancellationRequested) { audio = null; } // Swift: try?
            if (audio == null) return null;
            var stream = new PlayableStream(audio.Url)
            {
                HttpHeaders = headers, ExpiresAt = expires, LoudnessDb = audio.LoudnessDb ?? info.BestDirectAudio?.LoudnessDb ?? info.LoudnessDb,
                MimeType = HlsMimeType, Bitrate = audio.Bitrate, Duration = duration,
            };
            return new StreamResolution(stream, name + " HLS", audio.Itag);
        }

        async Task<StreamResolution?> Direct()
        {
            // Not from IOS: its direct formats need a PO token.
            if (name == "IOS" || mode == "hls" || info.BestDirectAudio is not { Url: { } url } format) return null;
            if (!await ProbeAsync(url, headers, ct).ConfigureAwait(false)) return null;
            var stream = new PlayableStream(url)
            {
                HttpHeaders = headers, ExpiresAt = expires, LoudnessDb = format.LoudnessDb ?? info.LoudnessDb, MimeType = format.MimeType,
                Bitrate = format.Bitrate, Duration = duration,
            };
            return new StreamResolution(stream, name, format.Itag);
        }

        return Preference == StreamPreference.Hls
            ? await Hls().ConfigureAwait(false) ?? await Direct().ConfigureAwait(false)
            : await Direct().ConfigureAwait(false) ?? await Hls().ConfigureAwait(false);
    }

    /// <summary>A 2-byte range request: googlevideo answers 403 when a URL needs a PO token or is bound elsewhere.</summary>
    async Task<bool> ProbeAsync(Uri url, IReadOnlyDictionary<string, string> headers, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        foreach (var (k, v) in headers) request.Headers.TryAddWithoutValidation(k, v);
        request.Headers.TryAddWithoutValidation("Range", "bytes=0-1");
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(TimeSpan.FromSeconds(8));
        try
        {
            using var response = await _client.Http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cts.Token).ConfigureAwait(false);
            return response.StatusCode is HttpStatusCode.PartialContent or HttpStatusCode.OK;
        }
        catch (Exception e) when (e is HttpRequestException or IOException || (e is OperationCanceledException && !ct.IsCancellationRequested))
        {
            return false;
        }
    }

    public sealed record HlsRendition(Uri Url, int? Itag, int? Bitrate, double? LoudnessDb);

    /// <summary>Picks the AAC audio-only media playlist out of a YouTube HLS master playlist and checks it loads.</summary>
    async Task<HlsRendition?> AudioRenditionAsync(Uri manifest, IReadOnlyDictionary<string, string> headers, CancellationToken ct)
    {
        if (await FetchTextAsync(manifest, headers, ct).ConfigureAwait(false) is not { } master ||
            AudioRenditionFromMaster(master) is not { } rendition ||
            await FetchTextAsync(rendition.Url, headers, ct).ConfigureAwait(false) is not { } media ||
            !media.Contains("#EXTINF", StringComparison.Ordinal))
        {
            return null;
        }
        return rendition;
    }

    async Task<string?> FetchTextAsync(Uri url, IReadOnlyDictionary<string, string> headers, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        foreach (var (k, v) in headers) request.Headers.TryAddWithoutValidation(k, v);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(TimeSpan.FromSeconds(10));
        using var response = await _client.Http.SendAsync(request, cts.Token).ConfigureAwait(false);
        if (response.StatusCode != HttpStatusCode.OK) return null;
        return await response.Content.ReadAsStringAsync(cts.Token).ConfigureAwait(false);
    }

    /// <summary>itag 234 is AAC ~128 kbps, 233 is AAC ~48 kbps.</summary>
    public static HlsRendition? AudioRenditionFromMaster(string text)
    {
        HlsRendition? best = null;
        foreach (var raw in text.Split(['\n', '\r'], StringSplitOptions.RemoveEmptyEntries))
        {
            if (!raw.StartsWith("#EXT-X-MEDIA:", StringComparison.Ordinal) || !raw.Contains("TYPE=AUDIO", StringComparison.Ordinal)) continue;
            var attrs = ParseAttributes(raw["#EXT-X-MEDIA:".Length..]);
            if (!attrs.TryGetValue("URI", out var uri) || !Uri.TryCreate(uri, UriKind.Absolute, out var url)) continue;
            int? itag = attrs.TryGetValue("GROUP-ID", out var g) && int.TryParse(g, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var n) ? n : null;
            // YT-EXT-ABSOLUTE-LOUDNESS is LUFS; YouTube's loudnessDb is relative to -14 LUFS.
            double? loudness = attrs.TryGetValue("YT-EXT-ABSOLUTE-LOUDNESS", out var l) && double.TryParse(l, NumberStyles.Float, CultureInfo.InvariantCulture, out var lufs) ? lufs + 14 : null;
            var rank = itag == 234 ? 2 : itag == 233 ? 1 : 0;
            var bestRank = best?.Itag == 234 ? 2 : best?.Itag == 233 ? 1 : best == null ? -1 : 0;
            if (rank > bestRank) best = new HlsRendition(url, itag, itag == 234 ? 128_000 : itag == 233 ? 48_000 : null, loudness);
        }
        return best;
    }

    public static Dictionary<string, string> ParseAttributes(string text)
    {
        var output = new Dictionary<string, string>(StringComparer.Ordinal);
        var key = new System.Text.StringBuilder();
        var value = new System.Text.StringBuilder();
        var inKey = true;
        var quoted = false;
        void Flush()
        {
            if (key.Length > 0) output[key.ToString()] = value.ToString();
            key.Clear();
            value.Clear();
            inKey = true;
        }
        foreach (var ch in text)
        {
            if (inKey)
            {
                if (ch == '=') inKey = false; else key.Append(ch);
            }
            else if (ch == '"') quoted = !quoted;
            else if (ch == ',' && !quoted) Flush();
            else value.Append(ch);
        }
        Flush();
        return output;
    }
}
