namespace Medley.Core;

// Port of Sources/MedleyCore/Contracts/PlaybackEngine.swift.

public enum PlaybackState { Idle, Loading, Playing, Paused, Buffering, Ended, Failed }

/// <summary>Events an engine reports to its owner (<see cref="PlayerController"/>).</summary>
public abstract record PlaybackEvent
{
    private protected PlaybackEvent() { }

    public sealed record StateChanged(PlaybackState State) : PlaybackEvent;
    /// <summary>Periodic progress, at least every 0.5 s while playing.</summary>
    public sealed record Time(double Current, double? Duration) : PlaybackEvent;
    /// <summary>The current item played to the end on its own.</summary>
    public sealed record Finished : PlaybackEvent
    {
        public static Finished Instance { get; } = new();
    }
    public sealed record Failed(string Message) : PlaybackEvent;
}

/// <summary>
/// Plays tracks for one provider. Engines that can resolve a direct stream URL use the app's MediaPlayer engine with an
/// <see cref="IStreamResolver"/>; providers that can't (Spotify) supply their own.
/// <para>Threading: called on the UI thread, and must raise <see cref="OnEvent"/> on the UI thread.</para>
/// </summary>
public interface IPlaybackEngine
{
    /// <summary>Set by <see cref="PlayerController"/>.</summary>
    Action<PlaybackEvent>? OnEvent { get; set; }

    /// <summary>Load and (optionally) start a track. Throws if the track can't be resolved. Cancelled when a newer load
    /// replaces it.</summary>
    Task LoadAsync(Track track, double startAt, bool autoplay, CancellationToken ct);
    void Play();
    void Pause();
    void Stop();
    void Seek(double seconds);
    /// <summary>0…1</summary>
    float Volume { get; set; }
    double CurrentTime { get; }
    double? Duration { get; }
    /// <summary>Hint for gapless playback and preloading. Engines may ignore it.</summary>
    void PrepareNext(Track? track);
}

/// <summary>A resolved, directly playable stream.</summary>
public sealed record PlayableStream(Uri Url)
{
    public IReadOnlyDictionary<string, string> HttpHeaders { get; init; } = new Dictionary<string, string>();
    public DateTimeOffset? ExpiresAt { get; init; }
    /// <summary>Loudness normalization in dB if the provider reports it (YouTube <c>loudnessDb</c>).</summary>
    public double? LoudnessDb { get; init; }
    public string? MimeType { get; init; }
    public int? Bitrate { get; init; }
    /// <summary>The stream's length in seconds if the service reports it. It can differ from the catalog's when the
    /// service plays another cut of the song.</summary>
    public double? Duration { get; init; }
}

/// <summary>Turns a track into a playable stream. Implemented by providers that use the MediaPlayer engine. Thread-safe.</summary>
public interface IStreamResolver
{
    /// <summary><paramref name="forceRefresh"/> skips any cached stream and asks the service again (recovery after a
    /// stream failed uses it, so a URL revoked before its nominal expiry isn't handed back).</summary>
    Task<PlayableStream> ResolveStreamAsync(Track track, bool forceRefresh, CancellationToken ct);
}

/// <summary>Optional engine features: loudness normalization, crossfade, output device. Engines that drive another app
/// (Spotify) don't implement it and the controller skips them.</summary>
public interface IConfigurableAudioEngine : IPlaybackEngine
{
    bool NormalizationEnabled { get; set; }
    /// <summary>Seconds to overlap the end of a track with the start of the next one. 0 disables.</summary>
    double CrossfadeDuration { get; set; }
    /// <summary>Audio endpoint id to play through, null for the system default.</summary>
    string? OutputDeviceId { get; set; }
}

/// <summary>Optional engine feature: reporting a song's real length as soon as its stream is resolved, before it plays.</summary>
public interface IDurationReportingEngine : IPlaybackEngine
{
    /// <summary>Set by <see cref="PlayerController"/>: the stream for the song with this <see cref="Track.Id"/> is this
    /// many seconds long.</summary>
    Action<string, double>? OnDurationResolved { get; set; }
}
