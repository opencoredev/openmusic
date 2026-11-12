using System.Net;
using System.Text.Json.Nodes;
using Medley.Core;
using Medley.Providers.YouTube.InnerTube;
using Medley.Providers.YouTube.Json;
using Medley.Providers.YouTube.Playback;
using Xunit;

namespace Medley.Providers.YouTube.Tests;

/// <summary>
/// A fake InnerTube player endpoint and googlevideo. Each client answers as configured: refused, OK with a direct URL
/// (whose 2-byte probe answers <c>Probe</c>), and/or an HLS manifest.
/// </summary>
internal sealed class FakeYouTube
{
    public sealed class ClientAnswer
    {
        public string Status = "OK";
        public string? Reason;
        public bool Direct = true;
        public HttpStatusCode Probe = HttpStatusCode.PartialContent;
        public bool Hls;
        public bool HlsMediaLoads = true;
    }

    public readonly Dictionary<string, ClientAnswer> Answers = new()
    {
        ["VISIONOS"] = new(), ["ANDROID_VR"] = new(), ["IOS"] = new() { Direct = true, Hls = true },
    };

    public int ServiceWorkerFetches;
    public Func<string, ClientAnswer, ClientAnswer>? Override;

    public FakeHandler Handler { get; }

    public FakeYouTube()
    {
        Handler = new FakeHandler(Respond);
    }

    HttpResponseMessage Respond(SeenRequest r)
    {
        var path = r.Url.AbsolutePath;
        if (path == "/sw.js_data")
        {
            Interlocked.Increment(ref ServiceWorkerFetches);
            return FakeHandler.ServiceWorker();
        }
        if (path == "/youtubei/v1/player")
        {
            var client = r.ClientName!;
            var a = Answers[client];
            if (Override != null) a = Override(client, a);
            var root = new JsonObject { ["playabilityStatus"] = new JsonObject { ["status"] = a.Status } };
            if (a.Reason != null) root["playabilityStatus"]!["reason"] = a.Reason;
            if (a.Status == "OK")
            {
                var videoId = r.Json.S("videoId");
                var formats = new JsonArray
                {
                    new JsonObject { ["itag"] = 251, ["mimeType"] = "audio/webm; codecs=\"opus\"", ["bitrate"] = 140000, ["url"] = $"https://rr1.googlevideo.com/{client}/251/{videoId}" },
                };
                if (a.Direct)
                {
                    formats.Add(new JsonObject
                    {
                        ["itag"] = 140, ["mimeType"] = "audio/mp4; codecs=\"mp4a.40.2\"", ["bitrate"] = 130000, ["averageBitrate"] = 129000,
                        ["url"] = $"https://rr1.googlevideo.com/{client}/140/{videoId}", ["loudnessDb"] = -1.5,
                    });
                }
                var streaming = new JsonObject { ["adaptiveFormats"] = formats, ["expiresInSeconds"] = "21540" };
                if (a.Hls) streaming["hlsManifestUrl"] = $"https://manifest.googlevideo.com/{client}/master/{videoId}.m3u8";
                root["streamingData"] = streaming;
                root["videoDetails"] = new JsonObject { ["videoId"] = videoId, ["lengthSeconds"] = "321" };
            }
            return FakeHandler.Json(root);
        }
        if (r.Url.Host == "manifest.googlevideo.com")
        {
            var client = r.Url.Segments[1].TrimEnd('/');
            if (path.Contains("/master/", StringComparison.Ordinal))
            {
                return FakeHandler.Text("#EXTM3U\n" +
                    $"#EXT-X-MEDIA:URI=\"https://manifest.googlevideo.com/{client}/media/233.m3u8\",TYPE=AUDIO,GROUP-ID=\"233\",NAME=\"low\"\n" +
                    $"#EXT-X-MEDIA:URI=\"https://manifest.googlevideo.com/{client}/media/234.m3u8\",TYPE=AUDIO,GROUP-ID=\"234\",NAME=\"high\",YT-EXT-ABSOLUTE-LOUDNESS=-12.350\n");
            }
            return Answers[client].HlsMediaLoads ? FakeHandler.Text("#EXTM3U\n#EXTINF:5.0,\nseg0.ts\n") : FakeHandler.Status(HttpStatusCode.Forbidden);
        }
        if (r.Url.Host == "rr1.googlevideo.com")
        {
            var client = r.Url.Segments[1].TrimEnd('/');
            Assert.Equal("bytes=0-1", r.Headers["Range"]);
            return FakeHandler.Status(Answers[client].Probe);
        }
        return FakeHandler.Status(HttpStatusCode.NotFound);
    }

    /// <summary>The player calls, in order, as client names.</summary>
    public List<string> PlayerCalls() => Handler.Seen.Where(r => r.Url.AbsolutePath == "/youtubei/v1/player").Select(r => r.ClientName!).ToList();
}

public class StreamResolverFallbackTests
{
    static (YouTubeStreamResolver, FakeYouTube, InnerTubeClient) Make(StreamPreference preference = StreamPreference.Direct)
    {
        var fake = new FakeYouTube();
        var client = new InnerTubeClient(handler: fake.Handler);
        return (new YouTubeStreamResolver(client, preference), fake, client);
    }

    [Fact]
    public void OrderIsTheSwiftClientsOrder() =>
        Assert.Equal(["VISIONOS", "ANDROID_VR", "IOS"], YouTubeStreamResolver.Order.Select(o => o.Name));

    [Fact]
    public async Task FirstClientsDirectUrlWins()
    {
        var (resolver, fake, _) = Make();
        var r = await resolver.ResolveAsync("vid1");
        Assert.Equal("VISIONOS", r.Client);
        Assert.Equal(140, r.Itag);
        Assert.Equal("https://rr1.googlevideo.com/VISIONOS/140/vid1", r.Stream.Url.OriginalString);
        Assert.StartsWith("audio/mp4", r.Stream.MimeType);
        Assert.Equal(129000, r.Stream.Bitrate);
        Assert.Equal(-1.5, r.Stream.LoudnessDb);
        Assert.Equal(321.0, r.Stream.Duration);
        Assert.Equal(InnerTubeProfile.VisionOS.UserAgent, r.Stream.HttpHeaders["User-Agent"]);
        Assert.Equal(["VISIONOS"], fake.PlayerCalls());
    }

    /// <summary>A refusal (LOGIN_REQUIRED, as recorded live from ANDROID_VR) moves on to the next client.</summary>
    [Fact]
    public async Task RefusedClientFallsThroughInOrder()
    {
        var (resolver, fake, _) = Make();
        fake.Answers["VISIONOS"].Status = "UNPLAYABLE";
        fake.Answers["VISIONOS"].Reason = "This video is not available";
        var r = await resolver.ResolveAsync("vid1");
        Assert.Equal("ANDROID_VR", r.Client);
        Assert.Equal(["VISIONOS", "ANDROID_VR"], fake.PlayerCalls());
        // The client that worked is tried first next time.
        Assert.Equal("ANDROID_VR", resolver.PreferredClient);
        fake.Handler.Requests.Clear();
        await resolver.ResolveAsync("vid2");
        Assert.Equal(["ANDROID_VR"], fake.PlayerCalls());
    }

    /// <summary>A direct URL that answers 403 to the 2-byte probe (it needs a PO token) is never handed out.</summary>
    [Fact]
    public async Task ForbiddenProbeFallsBackToHlsThenNextClient()
    {
        var (resolver, fake, _) = Make();
        fake.Answers["VISIONOS"].Probe = HttpStatusCode.Forbidden;
        fake.Answers["VISIONOS"].Hls = true;
        var r = await resolver.ResolveAsync("vid1");
        Assert.Equal("VISIONOS HLS", r.Client);
        Assert.Equal(234, r.Itag);
        Assert.Equal(YouTubeStreamResolver.HlsMimeType, r.Stream.MimeType);
        Assert.Equal("https://manifest.googlevideo.com/VISIONOS/media/234.m3u8", r.Stream.Url.OriginalString);
        Assert.InRange(r.Stream.LoudnessDb!.Value, 1.649, 1.651);

        var (resolver2, fake2, _) = Make();
        fake2.Answers["VISIONOS"].Probe = HttpStatusCode.Forbidden;
        var r2 = await resolver2.ResolveAsync("vid1");
        Assert.Equal("ANDROID_VR", r2.Client);
    }

    /// <summary>IOS's direct formats need a PO token: only its HLS is used, even when the direct URL would probe fine.</summary>
    [Fact]
    public async Task IosOnlyGivesHls()
    {
        var (resolver, fake, _) = Make();
        fake.Answers["VISIONOS"].Status = "LOGIN_REQUIRED";
        fake.Answers["ANDROID_VR"].Status = "LOGIN_REQUIRED";
        var r = await resolver.ResolveAsync("vid1");
        Assert.Equal("IOS HLS", r.Client);
        Assert.DoesNotContain(fake.Handler.Seen, s => s.Url.Host == "rr1.googlevideo.com" && s.Url.AbsolutePath.StartsWith("/IOS", StringComparison.Ordinal));
    }

    [Fact]
    public async Task HlsPreferenceIsTheSwiftOrderWithinAClient()
    {
        var (resolver, fake, _) = Make(StreamPreference.Hls);
        fake.Answers["VISIONOS"].Hls = true;
        Assert.Equal("VISIONOS HLS", (await resolver.ResolveAsync("vid1")).Client);
        // An HLS media playlist that doesn't load falls back to the direct URL.
        var (resolver2, fake2, _) = Make(StreamPreference.Hls);
        fake2.Answers["VISIONOS"].Hls = true;
        fake2.Answers["VISIONOS"].HlsMediaLoads = false;
        Assert.Equal("VISIONOS", (await resolver2.ResolveAsync("vid1")).Client);
    }

    [Fact]
    public async Task EveryClientFailingSaysWhy()
    {
        var (resolver, fake, _) = Make();
        fake.Answers["VISIONOS"].Status = "LOGIN_REQUIRED";
        fake.Answers["VISIONOS"].Reason = "Sign in to confirm your age";
        fake.Answers["ANDROID_VR"].Direct = false;
        fake.Answers["IOS"].Hls = false;
        var e = await Assert.ThrowsAsync<ProviderException>(() => resolver.ResolveAsync("vid1"));
        Assert.Equal(ProviderErrorKind.Unplayable, e.Kind);
        Assert.Equal("VISIONOS: Sign in to confirm your age; ANDROID_VR: no playable audio; IOS: no playable audio", e.Detail);
    }

    /// <summary>"Confirm you're not a bot" everywhere: a fresh visitor id (sw.js_data again), then one more round.</summary>
    [Fact]
    public async Task BotCheckRefreshesTheVisitorOnce()
    {
        var (resolver, fake, _) = Make();
        var rounds = 0;
        fake.Override = (client, a) =>
        {
            if (client == "VISIONOS") Interlocked.Increment(ref rounds);
            return Volatile.Read(ref rounds) <= 1 ? new FakeYouTube.ClientAnswer { Status = "LOGIN_REQUIRED", Reason = "Sign in to confirm you’re not a bot" } : a;
        };
        var r = await resolver.ResolveAsync("vid1");
        Assert.Equal("VISIONOS", r.Client);
        Assert.Equal(2, fake.ServiceWorkerFetches);
        Assert.Equal(["VISIONOS", "ANDROID_VR", "IOS", "VISIONOS"], fake.PlayerCalls());
    }

    /// <summary>Each client's request carries its own identity (this caught ANDROID_VR's androidSdkVersion breaking the body).</summary>
    [Fact]
    public async Task PlayerRequestsCarryEachClientsContext()
    {
        var (resolver, fake, _) = Make();
        foreach (var name in new[] { "VISIONOS", "ANDROID_VR" }) fake.Answers[name].Status = "LOGIN_REQUIRED";
        fake.Answers["IOS"].Hls = false;
        await Assert.ThrowsAsync<ProviderException>(() => resolver.ResolveAsync("vid1"));
        var calls = fake.Handler.Seen.Where(r => r.Url.AbsolutePath == "/youtubei/v1/player").ToList();
        var vr = calls.First(c => c.ClientName == "ANDROID_VR");
        Assert.Equal(32, vr.Json.I("context", "client", "androidSdkVersion"));
        Assert.Equal("Quest 3", vr.Json.S("context", "client", "deviceModel"));
        Assert.Equal("28", vr.Headers["X-YouTube-Client-Name"]);
        Assert.Equal("www.youtube.com", vr.Url.Host);
        Assert.Equal(InnerTubeProfile.AndroidVR.UserAgent, vr.Headers["User-Agent"]);
        var vision = calls.First(c => c.ClientName == "VISIONOS");
        Assert.Equal("101", vision.Headers["X-YouTube-Client-Name"]);
        Assert.Equal("RealityDevice17,1", vision.Json.S("context", "client", "deviceModel"));
        Assert.True(vision.Json.B("contentCheckOk"));
        Assert.Equal("CgtGSVhUVVJFX1ZJU0lUT1IoAQ==", vision.Json.S("context", "client", "visitorData"));
        // Never signed: stream lookups go out without cookies.
        Assert.All(calls, c => Assert.False(c.Headers.ContainsKey("Cookie")));
    }

    [Fact]
    public void RecordedRefusalParses()
    {
        var info = new PlayerInfo(Fixture.Json("live_player_android_vr_refused"));
        Assert.Equal("LOGIN_REQUIRED", info.Status);
        Assert.Contains("not a bot", info.Reason);
        Assert.Empty(info.Formats);
    }
}

/// <summary>Cache policy (Swift: StreamResolverCache), with the lookup replaced by a counter.</summary>
public class StreamResolverCacheTests
{
    static YouTubeStreamResolver Make(TimeSpan validFor) =>
        new(new InnerTubeClient(handler: new FakeHandler(_ => FakeHandler.Status(HttpStatusCode.NotFound))), fetchOverride: (videoId, _) =>
        {
            var url = new Uri($"https://example.invalid/{videoId}/{Guid.NewGuid()}");
            return Task.FromResult(new StreamResolution(new PlayableStream(url) { ExpiresAt = DateTimeOffset.UtcNow + validFor }, "TEST", 234));
        });

    static readonly Track Track = new() { ProviderID = "FGBhQbmPwH8", Provider = ProviderId.YouTubeMusic, Title = "Test" };

    [Fact]
    public async Task ReusesAnUnexpiredStream()
    {
        var resolver = Make(TimeSpan.FromHours(6));
        var a = await resolver.ResolveStreamAsync(Track);
        var b = await resolver.ResolveStreamAsync(Track);
        Assert.Same(a, b);
        Assert.Equal(1, resolver.FetchCount);
    }

    [Fact]
    public async Task ForceRefreshSkipsTheCacheAndReplacesIt()
    {
        var resolver = Make(TimeSpan.FromHours(6));
        IStreamResolver generic = resolver;
        var cached = await generic.ResolveStreamAsync(Track, false, default);
        var fresh = await generic.ResolveStreamAsync(Track, true, default);
        Assert.NotEqual(cached, fresh);
        Assert.Equal(2, resolver.FetchCount);
        Assert.Same(fresh, await generic.ResolveStreamAsync(Track, false, default));
        Assert.Equal(2, resolver.FetchCount);
    }

    [Fact]
    public async Task RefetchesWhenLittleValidityIsLeft()
    {
        var resolver = Make(TimeSpan.FromSeconds(300));
        var a = await resolver.ResolveStreamAsync(Track);
        var b = await resolver.ResolveStreamAsync(Track);
        Assert.NotEqual(a, b);
        Assert.Equal(2, resolver.FetchCount);
    }

    [Fact]
    public async Task ConcurrentLookupsShareOneFetch()
    {
        var resolver = Make(TimeSpan.FromHours(6));
        var results = await Task.WhenAll(Enumerable.Range(0, 8).Select(_ => resolver.ResolveAsync("same")));
        Assert.Single(results.Select(r => r.Stream.Url).Distinct());
        Assert.Equal(1, resolver.FetchCount);
    }
}
