using OpenMusic.Core;

namespace OpenMusic.Providers.YouTube.Playback;

/// <summary>
/// The default engine when the app supplies none: resolves the stream (so a load fails the way a real engine's would when
/// a track can't be played) and then reports <see cref="PlaybackState.Failed"/>, since it has no audio output. The Windows
/// app passes its MediaPlayer engine through <see cref="YouTubeMusicProviderOptions.PlaybackEngineFactory"/>.
/// </summary>
public sealed class StreamOnlyPlaybackEngine(IStreamResolver resolver) : IPlaybackEngine
{
    public Action<PlaybackEvent>? OnEvent { get; set; }
    public float Volume { get; set; } = 1;
    public double CurrentTime => 0;
    public double? Duration { get; private set; }

    /// <summary>The stream the last load resolved.</summary>
    public PlayableStream? LastStream { get; private set; }

    public async Task LoadAsync(Track track, double startAt, bool autoplay, CancellationToken ct)
    {
        OnEvent?.Invoke(new PlaybackEvent.StateChanged(PlaybackState.Loading));
        LastStream = await resolver.ResolveStreamAsync(track, false, ct);
        Duration = LastStream.Duration ?? track.Duration;
        OnEvent?.Invoke(new PlaybackEvent.Failed("No audio engine: the app didn't supply one."));
        OnEvent?.Invoke(new PlaybackEvent.StateChanged(PlaybackState.Failed));
    }

    public void Play() { }
    public void Pause() { }
    public void Stop() => OnEvent?.Invoke(new PlaybackEvent.StateChanged(PlaybackState.Idle));
    public void Seek(double seconds) { }
    public void PrepareNext(Track? track)
    {
        if (track != null && resolver is YouTubeStreamResolver yt) yt.Prefetch(track.ProviderID);
    }
}
