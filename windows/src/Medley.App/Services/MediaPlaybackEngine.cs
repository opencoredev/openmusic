using Medley.Core;
using Microsoft.UI.Dispatching;
using Windows.Devices.Enumeration;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Media.Streaming.Adaptive;

namespace Medley.App.Services;

/// <summary>
/// <see cref="IPlaybackEngine"/> on <see cref="MediaPlayer"/> (Windows.Media.Playback) for providers that resolve a
/// direct stream (<see cref="IStreamResolver"/>). The media keys, the Windows media flyout and the lock screen go
/// through this player's <see cref="MediaPlayer.SystemMediaTransportControls"/>, driven by
/// <see cref="SystemMediaControls"/> (the player's own command manager is off).
/// <para>Threading: called on the UI thread; MediaPlayer's events arrive on worker threads and are posted back to the
/// UI thread's DispatcherQueue before <see cref="OnEvent"/> fires. Time ticks come from a DispatcherQueueTimer that
/// runs only while playing, so a paused player costs no CPU.</para>
/// </summary>
public sealed class MediaPlaybackEngine : IConfigurableAudioEngine, IDurationReportingEngine, IDisposable
{
    private readonly MediaPlayer _player;
    private readonly DispatcherQueue _dispatcher;
    private readonly IStreamResolver _resolver;
    private readonly DispatcherQueueTimer _ticker;
    /// <summary>Bumped by every load and stop; a load that finds a newer generation after an await gives up.</summary>
    private int _generation;
    /// <summary>The item this engine loaded last. The player's events are matched to the item they came from (read on
    /// the event's thread), so a late callback from a replaced item never lands on its successor.</summary>
    private MediaPlaybackItem? _item;
    /// <summary>True once <see cref="_item"/> has opened, until a stop, a new load or a failure.</summary>
    private bool _opened;
    /// <summary>Set when the item played to its end; the player's own state changes are ignored until Play or Seek.</summary>
    private bool _ended;
    /// <summary>What the controller last asked for: play or pause. A load in progress follows it when the item opens, as
    /// Swift's AVPlaybackEngine does with wantsToPlay, so a Pause or Play during the load wins over its autoplay.</summary>
    private bool _wantsToPlay;
    private string? _outputDeviceId;

    public Action<PlaybackEvent>? OnEvent { get; set; }
    public Action<string, double>? OnDurationResolved { get; set; }

    public MediaPlayer Player => _player;
    public double CurrentTime { get; private set; }
    public double? Duration { get; private set; }
    public bool NormalizationEnabled { get; set; } = true;
    /// <summary>Not implemented yet (one MediaPlayer has no overlap); kept so settings round-trip.</summary>
    public double CrossfadeDuration { get; set; }

    public float Volume
    {
        get => (float)_player.Volume;
        set => _player.Volume = Math.Clamp(value, 0, 1);
    }

    public string? OutputDeviceId
    {
        get => _outputDeviceId;
        set
        {
            _outputDeviceId = value;
            _ = ApplyOutputDevice(value);
        }
    }

    public MediaPlaybackEngine(IStreamResolver resolver, DispatcherQueue dispatcher)
    {
        _resolver = resolver;
        _dispatcher = dispatcher;
        _player = new MediaPlayer
        {
            AutoPlay = false,
            AudioCategory = MediaPlayerAudioCategory.Media,
            IsLoopingEnabled = false,
        };
        _player.CommandManager.IsEnabled = false;
        _player.MediaEnded += (p, _) =>
        {
            var from = p.Source;
            _dispatcher.TryEnqueue(() => Ended(from));
        };
        _player.MediaFailed += (p, e) =>
        {
            var from = p.Source;
            var message = string.IsNullOrEmpty(e.ErrorMessage) ? e.Error.ToString() : e.ErrorMessage;
            Log.Error($"engine: media failed: {e.Error} 0x{e.ExtendedErrorCode?.HResult:X8} {message}");
            _dispatcher.TryEnqueue(() => Failed(from, message));
        };
        _player.PlaybackSession.PlaybackStateChanged += (s, _) =>
        {
            var state = s.PlaybackState;
            var from = s.MediaPlayer.Source;
            _dispatcher.TryEnqueue(() => SessionStateChanged(from, state));
        };
        _ticker = dispatcher.CreateTimer();
        _ticker.Interval = TimeSpan.FromMilliseconds(250);
        _ticker.IsRepeating = true;
        _ticker.Tick += (_, _) => EmitTime();
    }

    public async Task LoadAsync(Track track, double startAt, bool autoplay, CancellationToken ct)
    {
        try
        {
            await LoadCoreAsync(track, startAt, autoplay, ct);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            Log.Error($"engine: load failed for {track.Title}", e);
            throw;
        }
    }

    private async Task LoadCoreAsync(Track track, double startAt, bool autoplay, CancellationToken ct)
    {
        var gen = ++_generation;
        _opened = false;
        _ended = false;
        _wantsToPlay = autoplay;
        _ticker.Stop();
        _player.Pause();
        var stream = await _resolver.ResolveStreamAsync(track, false, ct);
        ct.ThrowIfCancellationRequested();
        if (gen != _generation) throw new OperationCanceledException();
        if (stream.Duration is { } known) OnDurationResolved?.Invoke(track.Id, known);

        var opened = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        MediaSource source;
        try
        {
            source = await CreateSourceAsync(stream, ct);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            Log.Error($"engine: couldn't open the stream for {track.Title}", e);
            throw;
        }
        if (gen != _generation)
        {
            source.Dispose();
            throw new OperationCanceledException();
        }
        ReplaceSource(source);
        var item = new MediaPlaybackItem(source);
        // Only this item's open counts: the handlers see every item the shared player opens.
        void OnOpened(MediaPlayer p, object e)
        {
            if (ReferenceEquals(p.Source, item)) opened.TrySetResult();
        }
        void OnFailed(MediaPlayer p, MediaPlayerFailedEventArgs e)
        {
            if (ReferenceEquals(p.Source, item))
                opened.TrySetException(ProviderException.Unplayable(string.IsNullOrEmpty(e.ErrorMessage) ? e.Error.ToString() : e.ErrorMessage));
        }
        _player.MediaOpened += OnOpened;
        _player.MediaFailed += OnFailed;
        try
        {
            _item = item;
            _player.Source = item;
            using (ct.Register(() => opened.TrySetCanceled()))
                await opened.Task;
        }
        finally
        {
            _player.MediaOpened -= OnOpened;
            _player.MediaFailed -= OnFailed;
        }
        // The open may have completed just before a cancellation arrived: the task can't be cancelled any more, so check.
        ct.ThrowIfCancellationRequested();
        if (gen != _generation) throw new OperationCanceledException();

        var session = _player.PlaybackSession;
        var natural = session.NaturalDuration.TotalSeconds;
        Duration = natural > 0 ? natural : stream.Duration ?? track.Duration;
        if (startAt > 0) session.Position = TimeSpan.FromSeconds(startAt);
        CurrentTime = startAt;
        _opened = true;
        OnEvent?.Invoke(new PlaybackEvent.Time(CurrentTime, Duration));
        if (_wantsToPlay) Play();
        else OnEvent?.Invoke(new PlaybackEvent.StateChanged(PlaybackState.Paused));
    }

    /// <summary>
    /// The MediaSource for a resolved stream. A stream that needs headers (YouTube: its client's User-Agent) is read
    /// through <see cref="HttpRangeStream"/>, or for HLS through an AdaptiveMediaSource whose HttpClient sends them; any
    /// other URL (files, the mock's WAVs) opens directly.
    /// </summary>
    private static async Task<MediaSource> CreateSourceAsync(PlayableStream stream, CancellationToken ct)
    {
        if (stream.HttpHeaders.Count == 0 || stream.Url.IsFile || Environment.GetEnvironmentVariable("MEDLEY_STREAM_MODE") == "uri") return MediaSource.CreateFromUri(stream.Url);
        if (stream.MimeType?.Contains("mpegurl", StringComparison.OrdinalIgnoreCase) == true)
        {
            var http = new Windows.Web.Http.HttpClient();
            foreach (var (name, value) in stream.HttpHeaders) http.DefaultRequestHeaders.TryAppendWithoutValidation(name, value);
            var result = await AdaptiveMediaSource.CreateFromUriAsync(stream.Url, http);
            if (result.Status != AdaptiveMediaSourceCreationStatus.Success)
                throw ProviderException.Unplayable($"The stream couldn't be opened ({result.Status}).");
            return MediaSource.CreateFromAdaptiveMediaSource(result.MediaSource);
        }
        // YouTube's direct audio is a fragmented MP4, which Media Foundation's MP4 source ends at once: play its flat view.
        if (stream.MimeType?.StartsWith("audio/mp4", StringComparison.OrdinalIgnoreCase) == true)
        {
            var started = System.Diagnostics.Stopwatch.StartNew();
            if (await RemuxedStream.OpenAsync(stream.Url, stream.HttpHeaders, ct) is { } flat)
            {
                Log.Info($"engine: fragmented MP4, {flat.Layout.Segments.Count} fragments, {flat.Length / 1024} kB, {flat.Layout.Seconds:F0}s, indexed in {started.ElapsedMilliseconds} ms");
                return MediaSource.CreateFromStream(new HttpRandomAccessStream(flat, "audio/mp4"), "audio/mp4");
            }
        }
        var body = await HttpRangeStream.OpenAsync(stream.Url, stream.HttpHeaders, ct);
        Log.Info($"engine: stream {stream.MimeType ?? body.ContentType} {body.Length / 1024} kB, {stream.Duration:F0}s");
        var type = stream.MimeType ?? body.ContentType ?? "audio/mp4";
        var semicolon = type.IndexOf(';');
        var contentType = semicolon > 0 ? type[..semicolon] : type;
        return MediaSource.CreateFromStream(new HttpRandomAccessStream(body, contentType), contentType);
    }

    /// <summary>The source playing now; the one it replaces is closed (its HTTP stream with it).</summary>
    private MediaSource? _source;

    private void ReplaceSource(MediaSource? source)
    {
        var old = _source;
        _source = source;
        if (old is not null) _dispatcher.TryEnqueue(DispatcherQueuePriority.Low, () => old.Dispose());
    }

    public void Play()
    {
        _wantsToPlay = true;
        // While loading, only the intent changes: the load starts playback when the item opens.
        if (!_opened) return;
        _ended = false;
        _player.Play();
        _ticker.Start();
        OnEvent?.Invoke(new PlaybackEvent.StateChanged(PlaybackState.Playing));
    }

    public void Pause()
    {
        _wantsToPlay = false;
        if (!_opened) return; // the load cues it paused when it opens
        _player.Pause();
        _ticker.Stop();
        EmitTime();
        OnEvent?.Invoke(new PlaybackEvent.StateChanged(PlaybackState.Paused));
    }

    public void Stop()
    {
        _generation++;
        _item = null;
        _opened = false;
        _ended = false;
        _wantsToPlay = false;
        _ticker.Stop();
        _player.Pause();
        _player.Source = null;
        ReplaceSource(null);
        CurrentTime = 0;
        OnEvent?.Invoke(new PlaybackEvent.StateChanged(PlaybackState.Idle));
    }

    public void Seek(double seconds)
    {
        CurrentTime = seconds;
        _ended = false;
        if (_player.Source is not null) _player.PlaybackSession.Position = TimeSpan.FromSeconds(Math.Max(0, seconds));
    }

    /// <summary>Resolves the next song early so its length is known before it plays (the queue row shows it).</summary>
    public void PrepareNext(Track? track)
    {
        if (track is null || OnDurationResolved is null) return;
        _ = Prepare(track);
    }

    private async Task Prepare(Track track)
    {
        try
        {
            var stream = await _resolver.ResolveStreamAsync(track, false, CancellationToken.None);
            if (stream.Duration is { } d) OnDurationResolved?.Invoke(track.Id, d);
        }
        catch (Exception)
        {
            // Only a hint: the real load reports its own failure.
        }
    }

    private void EmitTime()
    {
        if (_player.Source is null) return;
        var session = _player.PlaybackSession;
        CurrentTime = session.Position.TotalSeconds;
        var natural = session.NaturalDuration.TotalSeconds;
        if (natural > 0) Duration = natural;
        OnEvent?.Invoke(new PlaybackEvent.Time(CurrentTime, Duration));
    }

    private bool AtEnd()
    {
        var session = _player.PlaybackSession;
        var total = session.NaturalDuration.TotalSeconds;
        return total > 0 && session.Position.TotalSeconds >= total - 0.75;
    }

    private bool IsCurrent(object? from) => _opened && from is not null && ReferenceEquals(from, _item);

    private void Ended(object? from)
    {
        if (!IsCurrent(from) || _ended) return;
        var session = _player.PlaybackSession;
        Log.Info($"engine: ended at {session.Position.TotalSeconds:F1}s of {session.NaturalDuration.TotalSeconds:F1}s");
        _ended = true;
        _ticker.Stop();
        if (Duration is { } d) OnEvent?.Invoke(new PlaybackEvent.Time(d, d));
        OnEvent?.Invoke(new PlaybackEvent.StateChanged(PlaybackState.Ended));
        OnEvent?.Invoke(PlaybackEvent.Finished.Instance);
    }

    private void Failed(object? from, string message)
    {
        // A failure while opening is LoadAsync's to report; this is for a stream that dies mid-song.
        if (!IsCurrent(from)) return;
        _opened = false;
        _ticker.Stop();
        OnEvent?.Invoke(new PlaybackEvent.StateChanged(PlaybackState.Failed));
        OnEvent?.Invoke(new PlaybackEvent.Failed(message));
    }

    private void SessionStateChanged(object? from, MediaPlaybackState state)
    {
        if (!IsCurrent(from) || _ended) return;
        switch (state)
        {
            case MediaPlaybackState.Buffering:
                OnEvent?.Invoke(new PlaybackEvent.StateChanged(PlaybackState.Buffering));
                break;
            case MediaPlaybackState.Playing when _wantsToPlay:
                _ticker.Start();
                OnEvent?.Invoke(new PlaybackEvent.StateChanged(PlaybackState.Playing));
                break;
            case MediaPlaybackState.Paused when _wantsToPlay && !AtEnd():
                // Paused from outside (an audio device went away); our own Pause already said so. At the end of the
                // item MediaPlayer reports Paused just before MediaEnded: that one is the end, not a pause. A network
                // stream also reports a short Paused right after its first Buffering and then plays on, so only a pause
                // that lasts counts.
                var item = _item;
                _ = ConfirmOutsidePause(item);
                break;
        }
    }

    private async Task ConfirmOutsidePause(MediaPlaybackItem? item)
    {
        await Task.Delay(600);
        if (!ReferenceEquals(item, _item) || !_wantsToPlay || _ended || AtEnd()) return;
        if (_player.PlaybackSession.PlaybackState != MediaPlaybackState.Paused) return;
        Log.Info("engine: paused from outside");
        _wantsToPlay = false;
        _ticker.Stop();
        OnEvent?.Invoke(new PlaybackEvent.StateChanged(PlaybackState.Paused));
    }

    private async Task ApplyOutputDevice(string? id)
    {
        try
        {
            _player.AudioDevice = id is null ? null : await DeviceInformation.CreateFromIdAsync(id);
        }
        catch (Exception)
        {
            _player.AudioDevice = null;
        }
    }

    public void Dispose()
    {
        _ticker.Stop();
        _player.Dispose();
    }
}
