using Medley.Core;
using Microsoft.UI.Dispatching;
using Windows.Media;
using Windows.Media.Playback;

namespace Medley.App.Services;

/// <summary>
/// Publishes the current song to the System Media Transport Controls (the Windows media flyout, media keys, the lock
/// screen, Bluetooth headsets) and routes their buttons back to the <see cref="PlayerController"/>. Updates only on
/// player changes (track, state, seek) and, while playing, the timeline about once a second from the player's own time
/// updates (the engine's ticker runs only while playing, so nothing runs while paused). The Windows media flyout shows
/// the position it was last given and doesn't move it on by itself.
/// </summary>
public sealed class SystemMediaControls
{
    private readonly SystemMediaTransportControls _smtc;
    private readonly PlayerController _player;
    private readonly DispatcherQueue _dispatcher;
    private string? _shownTrackId;
    private int _artGeneration;
    private double _timelineSentAt = double.NaN;
    private long _timelineSentTicks;

    public SystemMediaControls(MediaPlayer mediaPlayer, PlayerController player, DispatcherQueue dispatcher)
    {
        _player = player;
        _dispatcher = dispatcher;
        _smtc = mediaPlayer.SystemMediaTransportControls;
        _smtc.IsEnabled = true;
        _smtc.IsPlayEnabled = true;
        _smtc.IsPauseEnabled = true;
        _smtc.IsStopEnabled = false;
        _smtc.ButtonPressed += (_, e) =>
        {
            var button = e.Button;
            _dispatcher.TryEnqueue(() => Pressed(button));
        };
        _smtc.PlaybackPositionChangeRequested += (_, e) =>
        {
            var seconds = e.RequestedPlaybackPosition.TotalSeconds;
            _dispatcher.TryEnqueue(() => _player.Seek(seconds));
        };
        _smtc.ShuffleEnabledChangeRequested += (_, e) =>
        {
            var on = e.RequestedShuffleEnabled;
            _dispatcher.TryEnqueue(() => _player.Shuffle = on);
        };
        _smtc.AutoRepeatModeChangeRequested += (_, e) =>
        {
            var mode = e.RequestedAutoRepeatMode switch
            {
                MediaPlaybackAutoRepeatMode.List => RepeatMode.All,
                MediaPlaybackAutoRepeatMode.Track => RepeatMode.One,
                _ => RepeatMode.Off,
            };
            _dispatcher.TryEnqueue(() => _player.RepeatMode = mode);
        };
        player.AddChangeHandler(Changed);
        player.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(PlayerController.CurrentTime)) TimeAdvanced();
        };
        Update(PlayerChange.Track);
    }

    /// <summary>The position moved on while playing: refresh the flyout's timeline once a second at most.</summary>
    private void TimeAdvanced()
    {
        if (!_player.IsPlaying) return;
        var now = Environment.TickCount64;
        if (now - _timelineSentTicks < 1000 && Math.Abs(_player.CurrentTime - _timelineSentAt) < 2) return;
        UpdateTimeline();
    }

    private void UpdateTimeline()
    {
        var duration = _player.Duration ?? _player.Current?.Duration ?? 0;
        var position = Math.Clamp(_player.CurrentTime, 0, Math.Max(duration, 0));
        _smtc.UpdateTimelineProperties(new SystemMediaTransportControlsTimelineProperties
        {
            StartTime = TimeSpan.Zero,
            MinSeekTime = TimeSpan.Zero,
            EndTime = TimeSpan.FromSeconds(duration),
            MaxSeekTime = TimeSpan.FromSeconds(duration),
            Position = TimeSpan.FromSeconds(position),
        });
        _timelineSentAt = position;
        _timelineSentTicks = Environment.TickCount64;
    }

    private void Pressed(SystemMediaTransportControlsButton button)
    {
        switch (button)
        {
            case SystemMediaTransportControlsButton.Play: _player.Resume(); break;
            case SystemMediaTransportControlsButton.Pause: _player.Pause(); break;
            case SystemMediaTransportControlsButton.Next: _player.Next(); break;
            case SystemMediaTransportControlsButton.Previous: _player.Previous(); break;
            case SystemMediaTransportControlsButton.Stop: _player.Pause(); break;
        }
    }

    private void Changed(PlayerChange change) => Update(change);

    private void Update(PlayerChange change)
    {
        var current = _player.Current;
        if (change == PlayerChange.Track && current?.Id != _shownTrackId) _ = ShowTrack(current);
        _smtc.PlaybackStatus = current is null ? MediaPlaybackStatus.Closed
            : _player.IsPlaying ? MediaPlaybackStatus.Playing
            : _player.State == PlaybackState.Loading ? MediaPlaybackStatus.Changing
            : MediaPlaybackStatus.Paused;
        _smtc.IsNextEnabled = current is not null;
        _smtc.IsPreviousEnabled = current is not null;
        _smtc.ShuffleEnabled = _player.Shuffle;
        _smtc.AutoRepeatMode = _player.RepeatMode switch
        {
            RepeatMode.All => MediaPlaybackAutoRepeatMode.List,
            RepeatMode.One => MediaPlaybackAutoRepeatMode.Track,
            _ => MediaPlaybackAutoRepeatMode.None,
        };
        UpdateTimeline();
    }

    private async Task ShowTrack(Track? track)
    {
        _shownTrackId = track?.Id;
        var gen = ++_artGeneration;
        var updater = _smtc.DisplayUpdater;
        if (track is null)
        {
            updater.ClearAll();
            updater.Update();
            return;
        }
        updater.Type = MediaPlaybackType.Music;
        updater.AppMediaId = ProductInfo.Name;
        updater.MusicProperties.Title = track.Title;
        updater.MusicProperties.Artist = track.ArtistLine;
        updater.MusicProperties.AlbumArtist = track.Artists.FirstOrDefault()?.Name ?? "";
        updater.MusicProperties.AlbumTitle = track.Album?.Title ?? "";
        updater.MusicProperties.TrackNumber = (uint)(track.TrackNumber ?? 0);
        updater.Update();
        try
        {
            var art = track.Artwork ?? await TrackArtwork.FindAsync(track);
            if (gen != _artGeneration) return;
            var thumbnail = await ArtworkLoader.ThumbnailAsync(art?.Url(300));
            if (gen != _artGeneration) return;
            updater.Thumbnail = thumbnail;
            updater.Update();
        }
        catch (Exception)
        {
            // The flyout shows the title without art.
        }
    }
}
