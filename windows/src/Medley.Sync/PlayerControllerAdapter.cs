using Medley.Core;

namespace Medley.Sync;

/// <summary>
/// <see cref="ISyncPlayer"/> over Medley.Core's <see cref="PlayerController"/>. The player is single-threaded: create the
/// SyncService's <see cref="SyncActor"/> on the player's context (the app's UI SynchronizationContext, or a MainThreadContext
/// in tools), so every call here happens on that thread, as the Swift apps do everything on the main actor.
/// </summary>
public sealed class PlayerControllerAdapter : ISyncPlayer
{
    private readonly PlayerController _player;
    private Guid? _handler;
    private Action? _changed;

    public PlayerControllerAdapter(PlayerController player) => _player = player;

    public event Action? Changed
    {
        add
        {
            _changed += value;
            _handler ??= _player.AddChangeHandler(_ => _changed?.Invoke());
        }
        remove
        {
            _changed -= value;
            if (_changed is null && _handler is { } id) { _player.RemoveChangeHandler(id); _handler = null; }
        }
    }

    public IReadOnlyList<QueueEntry> Queue => _player.Queue;
    public int? CurrentIndex => _player.CurrentIndex;
    public QueueEntry? CurrentEntry => _player.CurrentEntry;
    public SyncPlayerState State => _player.State switch
    {
        PlaybackState.Idle => SyncPlayerState.Idle,
        PlaybackState.Loading => SyncPlayerState.Loading,
        PlaybackState.Buffering => SyncPlayerState.Buffering,
        PlaybackState.Playing => SyncPlayerState.Playing,
        PlaybackState.Paused => SyncPlayerState.Paused,
        PlaybackState.Ended => SyncPlayerState.Ended,
        _ => SyncPlayerState.Failed,
    };

    /// <summary>The engine's time while it plays (fresher than the player's last tick), the player's otherwise.</summary>
    public double CurrentTime =>
        _player.State is PlaybackState.Playing or PlaybackState.Buffering && _player.Current is { } track && _player.Provider(track.Provider) is { } provider
            ? provider.PlaybackEngine.CurrentTime
            : _player.CurrentTime;

    public double? Duration => _player.Duration;
    public double Volume { get => _player.Volume; set => _player.Volume = (float)Math.Clamp(value, 0, 1); }
    public bool Shuffle => _player.Shuffle;
    public RepeatMode RepeatMode => _player.RepeatMode;
    public bool IsPlaying => _player.IsPlaying;
    public string? LastError => _player.LastError;
    public bool CanPlay(ProviderId provider) => _player.Provider(provider)?.IsSignedIn == true;
    public void Load(IReadOnlyList<QueueEntry> queue, int index, double position, bool shuffle, RepeatMode repeatMode, bool autoplay) =>
        _player.Load(queue, index, position, shuffle, repeatMode, autoplay);
    public void Resume() => _player.Resume();
    public void Pause() => _player.Pause();
    public void TogglePlayPause() => _player.TogglePlayPause();
    public void Next() => _player.Next();
    public void Previous() => _player.Previous();
    public void Stop() => _player.Stop();
    public void Seek(double seconds) => _player.Seek(seconds);
}
