using System.Globalization;
using System.Text.Json.Nodes;
using OpenMusic.Providers.YouTube.Json;

namespace OpenMusic.Providers.YouTube.Playback;

/// <summary>The parts of a <c>/player</c> response the resolver needs (Swift: <c>PlayerInfo</c>).</summary>
public sealed class PlayerInfo
{
    public sealed record Format(int Itag, string MimeType, int Bitrate, Uri? Url, bool IsCiphered, long? ContentLength, double? LoudnessDb, bool AudioTrackDefault)
    {
        public bool IsAudio => MimeType.StartsWith("audio/", StringComparison.Ordinal);

        /// <summary>AAC in MP4: plays everywhere (AVPlayer, Media Foundation). WebM/Opus is left out like in the Swift client.</summary>
        public bool IsAacMp4 => MimeType.StartsWith("audio/mp4", StringComparison.Ordinal);
    }

    public string Status { get; }
    public string? Reason { get; }
    public IReadOnlyList<Format> Formats { get; }
    public Uri? HlsManifestUrl { get; }
    public double? ExpiresIn { get; }
    public double? LoudnessDb { get; }
    public string? Title { get; }

    /// <summary>
    /// <c>videoDetails.lengthSeconds</c>: the length of what this video plays, which can differ from the catalog's for
    /// the song (an album track mapped to its official video).
    /// </summary>
    public double? LengthSeconds { get; }

    public PlayerInfo(JsonObject root)
    {
        Status = root.S("playabilityStatus", "status") ?? "ERROR";
        Reason = root.S("playabilityStatus", "reason") ?? root.Text("playabilityStatus", "errorScreen", "playerErrorMessageRenderer", "reason");
        var streaming = root.Obj("streamingData");
        var formats = new List<Format>();
        foreach (var item in streaming.A("adaptiveFormats").Concat(streaming.A("formats")))
        {
            if (item is not JsonObject f || f.I("itag") is not { } itag || f.S("mimeType") is not { } mime) continue;
            formats.Add(new Format(
                itag,
                mime,
                f.I("averageBitrate") ?? f.I("bitrate") ?? 0,
                f.S("url") is { } u && Uri.TryCreate(u, UriKind.Absolute, out var url) ? url : null,
                f.ContainsKey("signatureCipher") || f.ContainsKey("cipher"),
                f.S("contentLength") is { } cl && long.TryParse(cl, NumberStyles.None, CultureInfo.InvariantCulture, out var len) ? len : null,
                f.D("loudnessDb"),
                f.B("audioTrack", "audioIsDefault") ?? true));
        }
        Formats = formats;
        HlsManifestUrl = streaming.S("hlsManifestUrl") is { } h && Uri.TryCreate(h, UriKind.Absolute, out var hls) ? hls : null;
        ExpiresIn = streaming.S("expiresInSeconds") is { } e && double.TryParse(e, NumberStyles.Float, CultureInfo.InvariantCulture, out var exp) ? exp : null;
        LoudnessDb = root.D("playerConfig", "audioConfig", "loudnessDb");
        Title = root.S("videoDetails", "title");
        LengthSeconds = root.S("videoDetails", "lengthSeconds") is { } ls && double.TryParse(ls, NumberStyles.Float, CultureInfo.InvariantCulture, out var secs) && secs > 0 ? secs : null;
    }

    /// <summary>Best directly playable audio format: AAC, unciphered, default audio track, highest bitrate.</summary>
    public Format? BestDirectAudio
    {
        get
        {
            Format? best = null;
            foreach (var f in Formats)
            {
                if (!(f.IsAudio && f.IsAacMp4 && f.Url != null && !f.IsCiphered && f.AudioTrackDefault)) continue;
                if (best == null || best.Bitrate < f.Bitrate) best = f;
            }
            return best;
        }
    }
}
