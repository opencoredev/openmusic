namespace Medley.Providers.YouTube.InnerTube;

/// <summary>One InnerTube client identity: what the request claims to be (Swift: <c>InnerTubeProfile</c>).</summary>
public sealed record InnerTubeProfile(
    string ClientName,
    string ClientVersion,
    int ClientId,
    string UserAgent,
    string Host,
    IReadOnlyDictionary<string, string>? ExtraContext = null,
    int? AndroidSdkVersion = null)
{
    public const string SafariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15";

    /// <summary>The music.youtube.com web client. The version is refreshed at runtime from <c>sw.js_data</c>.</summary>
    public static InnerTubeProfile WebRemix(string version) => new("WEB_REMIX", version, 67, SafariUserAgent, "music.youtube.com");

    /// <summary>The YouTube Music Android app. The only client that returns timed lyrics.</summary>
    public static readonly InnerTubeProfile AndroidMusic = new("ANDROID_MUSIC", "7.21.50", 21, SafariUserAgent, "music.youtube.com");

    // Stream clients (see YouTubeStreamResolver). Versions follow yt-dlp (2026-10), as in the Swift client.

    /// <summary>Apple Vision Pro app: direct (unciphered) URLs, no PO token, no player JS needed.</summary>
    public static readonly InnerTubeProfile VisionOS = new(
        "VISIONOS", "1.02", 101,
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        "www.youtube.com",
        new Dictionary<string, string> { ["deviceMake"] = "Apple", ["deviceModel"] = "RealityDevice17,1", ["osName"] = "visionOS", ["osVersion"] = "26.5.23O471" });

    /// <summary>Quest app: direct URLs and <c>loudnessDb</c>. Versions above 1.60 are SABR-only or blocked.</summary>
    public static readonly InnerTubeProfile AndroidVR = new(
        "ANDROID_VR", "1.60.19", 28,
        "com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
        "www.youtube.com",
        new Dictionary<string, string> { ["deviceMake"] = "Oculus", ["deviceModel"] = "Quest 3", ["osName"] = "Android", ["osVersion"] = "12L" },
        AndroidSdkVersion: 32);

    /// <summary>iPhone app: HLS manifests. Its direct formats need a PO token, so only HLS is used.</summary>
    public static readonly InnerTubeProfile IOS = new(
        "IOS", "21.26.4", 5,
        "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
        "www.youtube.com",
        new Dictionary<string, string> { ["deviceMake"] = "Apple", ["deviceModel"] = "iPhone16,2", ["osName"] = "iPhone", ["osVersion"] = "18.3.2.22D82" });
}
