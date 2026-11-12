using System.Collections.ObjectModel;
using System.ComponentModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using OpenMusic.App.Services;
using OpenMusic.Core;

namespace OpenMusic.App.ViewModels;

/// <summary>
/// What the now-playing bar, the lyrics and Up Next pane, Now Playing and the mini player show, from the
/// <see cref="PlayerController"/>. One instance for the app (<see cref="AppServices.PlayerViewModel"/>); everything runs
/// on the UI thread.
/// </summary>
public sealed partial class PlayerViewModel : ObservableObject
{
    public const string PlayGlyph = "";
    public const string PauseGlyph = "";

    private readonly PlayerController _player;
    private readonly LyricsService _lyrics;
    private string? _lyricsTrackId;
    private string? _likedTrackId;
    /// <summary>Bumped per lyrics request: only the latest one may fill the list (A, B, A again before A's first
    /// answer would otherwise add A's lines twice).</summary>
    private int _lyricsRequest;
    private Lyrics? _currentLyrics;

    public PlayerController Player => _player;

    public ObservableCollection<LyricRow> LyricLines { get; } = [];
    public ObservableCollection<QueueRow> UpNext { get; } = [];
    public ObservableCollection<QueueRow> History { get; } = [];

    /// <summary>Raised when the highlighted lyric line changes (views scroll it into place).</summary>
    public event Action<int>? LyricIndexChanged;

    public PlayerViewModel(PlayerController player, LyricsService lyrics)
    {
        _player = player;
        _lyrics = lyrics;
        _player.PropertyChanged += OnPlayerChanged;
        SyncAll();
    }

    [ObservableProperty] public partial string Title { get; set; } = "Not Playing";
    [ObservableProperty] public partial string Artist { get; set; } = "";
    [ObservableProperty] public partial string AlbumTitle { get; set; } = "";
    [ObservableProperty] public partial Uri? Artwork { get; set; }
    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(PlayPauseCommand), nameof(NextCommand), nameof(PreviousCommand))]
    public partial bool HasTrack { get; set; }
    [ObservableProperty] public partial string SourceLabel { get; set; } = "";
    [ObservableProperty] public partial bool IsPlaying { get; set; }
    [ObservableProperty] public partial string PlayPauseGlyphText { get; set; } = PlayGlyph;
    [ObservableProperty] public partial string PlayPauseLabel { get; set; } = "Play";
    [ObservableProperty] public partial double Position { get; set; }
    [ObservableProperty] public partial double DurationSeconds { get; set; } = 1;
    [ObservableProperty] public partial string PositionText { get; set; } = "0:00";
    [ObservableProperty] public partial string DurationText { get; set; } = "";
    [ObservableProperty] public partial bool IsShuffle { get; set; }
    [ObservableProperty] public partial bool IsRepeatOn { get; set; }
    [ObservableProperty] public partial string RepeatGlyph { get; set; } = "";
    [ObservableProperty] public partial string RepeatLabel { get; set; } = "Repeat: off";
    [ObservableProperty] public partial bool HasLyrics { get; set; }
    [ObservableProperty] public partial string LyricsStatus { get; set; } = "";
    [ObservableProperty] public partial int CurrentLyricIndex { get; set; } = -1;
    [ObservableProperty] public partial string UpNextHeader { get; set; } = "Playing Next";
    [ObservableProperty] public partial bool IsLoading { get; set; }

    /// <summary>0…100 for the volume slider.</summary>
    public double Volume
    {
        get => Math.Round(_player.Volume * 100);
        set
        {
            if (Math.Abs(_player.Volume * 100 - value) < 0.5) return;
            _player.Volume = (float)(value / 100);
            OnPropertyChanged();
            OnPropertyChanged(nameof(VolumeGlyph));
        }
    }

    public string VolumeGlyph => _player.Volume switch
    {
        <= 0 => "",
        < 0.34f => "",
        < 0.67f => "",
        _ => "",
    };

    partial void OnIsShuffleChanged(bool value)
    {
        if (_player.Shuffle != value) _player.Shuffle = value;
    }

    // Nothing loaded: the transport is disabled, as in Media Player, rather than inviting a Play that can't start.
    /// <summary>The heart beside the song: shown when the service can like songs for the signed-in account.</summary>
    [ObservableProperty] public partial bool CanLike { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(LikeGlyph), nameof(LikeLabel))]
    public partial bool IsLiked { get; set; }

    public string LikeGlyph => IsLiked ? "\uEB52" : "\uEB51";
    public string LikeLabel => IsLiked ? "Remove from Liked Songs" : "Like";

    private int _likeGeneration;

    /// <summary>The current song's liked state, asked once per song (the menu's Like asks the same).</summary>
    private async Task LoadLikedAsync(Track? track)
    {
        var generation = ++_likeGeneration;
        CanLike = track is not null && MediaMenus.CanLike && App.Services.Player.Provider(track.Provider) is not null;
        IsLiked = false;
        if (!CanLike || track is null) return;
        try
        {
            var liked = await App.Services.Player.Provider(track.Provider)!.IsLikedAsync(track);
            if (generation == _likeGeneration) IsLiked = liked;
        }
        catch (Exception)
        {
            // Unknown: an outline heart, as for a song not liked.
        }
    }

    /// <summary>The account changed (sign-in, switch, sign-out): ask again, for the account signed in now.</summary>
    public void RefreshLiked() => _ = LoadLikedAsync(_player.Current);

    [RelayCommand]
    public async Task ToggleLike()
    {
        if (_player.Current is not { } track || !CanLike) return;
        _likeGeneration++; // a read still in flight is older than this choice
        var want = !IsLiked;
        IsLiked = want; // at once; put back if the service refuses
        if (!await MediaMenus.SetLikedAsync(track, want) && _player.Current?.Id == track.Id) IsLiked = !want;
    }

    [RelayCommand(CanExecute = nameof(HasTrack))] public void PlayPause() => _player.TogglePlayPause();
    [RelayCommand(CanExecute = nameof(HasTrack))] public void Next() => _player.Next();
    [RelayCommand(CanExecute = nameof(HasTrack))] public void Previous() => _player.Previous();
    [RelayCommand] public void ToggleShuffle() => _player.Shuffle = !_player.Shuffle;

    [RelayCommand]
    public void CycleRepeat() => _player.RepeatMode = _player.RepeatMode switch
    {
        RepeatMode.Off => RepeatMode.All,
        RepeatMode.All => RepeatMode.One,
        _ => RepeatMode.Off,
    };

    public void Seek(double seconds) => _player.Seek(seconds);

    public void Play(QueueRow row) => _player.Jump(row.Entry.Uid);

    public void PlayFromHistory(QueueRow row) => _player.PlayNow(row.Entry.Track, row.Entry.Context);

    public void SeekToLyric(LyricRow row)
    {
        if (row.Line.Time is not { } t) return;
        _player.Seek(t);
        if (!_player.IsPlaying) _player.Resume();
    }

    private void OnPlayerChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(PlayerController.CurrentTime):
                SyncTime();
                break;
            case nameof(PlayerController.Duration):
                SyncTime();
                break;
            case nameof(PlayerController.State):
            case nameof(PlayerController.IsPlaying):
                SyncState();
                break;
            case nameof(PlayerController.Current):
                SyncTrack();
                break;
            case nameof(PlayerController.Queue):
            case nameof(PlayerController.CurrentIndex):
            case nameof(PlayerController.ListeningHistory):
                ScheduleQueueSync();
                break;
            case nameof(PlayerController.Shuffle):
                IsShuffle = _player.Shuffle;
                break;
            case nameof(PlayerController.RepeatMode):
                SyncRepeat();
                break;
            case nameof(PlayerController.Volume):
                OnPropertyChanged(nameof(Volume));
                OnPropertyChanged(nameof(VolumeGlyph));
                break;
        }
    }

    private void SyncAll()
    {
        SyncTrack();
        SyncState();
        SyncTime();
        SyncRepeat();
        IsShuffle = _player.Shuffle;
        SyncQueue();
    }

    private void SyncTrack()
    {
        var track = _player.Current;
        HasTrack = track is not null;
        Title = track?.Title ?? "Not Playing";
        Artist = track?.ArtistLine ?? "";
        AlbumTitle = track?.Album?.Title ?? "";
        Artwork = track?.Artwork?.Url(600);
        if (track is { Artwork: null }) _ = FillArtworkAsync(track);
        SourceLabel = _player.SourceLabel ?? "";
        if (track?.Id != _lyricsTrackId) _ = LoadLyrics(track);
        if (track?.Id != _likedTrackId)
        {
            _likedTrackId = track?.Id;
            _ = LoadLikedAsync(track);
        }
    }

    private void SyncState()
    {
        IsPlaying = _player.IsPlaying;
        IsLoading = _player.State is PlaybackState.Loading or PlaybackState.Buffering;
        PlayPauseGlyphText = IsPlaying ? PauseGlyph : PlayGlyph;
        PlayPauseLabel = IsPlaying ? "Pause" : "Play";
    }

    private void SyncTime()
    {
        var duration = _player.Duration ?? _player.Current?.Duration;
        DurationSeconds = duration is > 0 and var d ? d : 1;
        Position = Math.Min(_player.CurrentTime, DurationSeconds);
        PositionText = Format.Time(_player.CurrentTime);
        DurationText = duration is null ? "" : Format.Remaining(_player.CurrentTime, duration);
        UpdateLyricIndex();
    }

    private void SyncRepeat()
    {
        var mode = _player.RepeatMode;
        IsRepeatOn = mode != RepeatMode.Off;
        RepeatGlyph = mode == RepeatMode.One ? "" : "";
        RepeatLabel = mode switch { RepeatMode.All => "Repeat: all", RepeatMode.One => "Repeat: one", _ => "Repeat: off" };
    }

    private bool _queueSyncPending;

    /// <summary>Queue changes come in bursts (a play replaces the queue, sets the cursor, loads radio): rebuild the lists
    /// once per burst, on the next dispatcher turn.</summary>
    private void ScheduleQueueSync()
    {
        if (_queueSyncPending) return;
        _queueSyncPending = true;
        App.Services.Dispatcher.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            _queueSyncPending = false;
            SyncQueue();
        });
    }

    private void SyncQueue()
    {
        Replace(UpNext, _player.UpNext.Select(e => new QueueRow(e)));
        Replace(History, _player.ListeningHistory.Take(30).Select(p => new QueueRow(new QueueEntry(p.Track, context: p.Context))));
        SourceLabel = _player.SourceLabel ?? "";
        var next = _player.UpNext.FirstOrDefault();
        UpNextHeader = next?.IsAutoplay == true ? "Autoplay" : _player.SourceLabel is { } label ? $"Playing Next · {label.Replace("Playing from ", "")}" : "Playing Next";
    }

    private static void Replace<T>(ObservableCollection<T> target, IEnumerable<T> items)
    {
        target.Clear();
        foreach (var i in items) target.Add(i);
    }

    /// <summary>A song without artwork (handed over from another device): show its listing's once it's found.</summary>
    private async Task FillArtworkAsync(Track track)
    {
        var art = await TrackArtwork.FindAsync(track);
        if (art is not null && _player.Current?.Id == track.Id && Artwork is null) Artwork = art.Url(600);
    }

    private async Task LoadLyrics(Track? track)
    {
        _lyricsTrackId = track?.Id;
        var request = ++_lyricsRequest;
        _currentLyrics = null;
        LyricLines.Clear();
        CurrentLyricIndex = -1;
        HasLyrics = false;
        if (track is null)
        {
            LyricsStatus = "";
            return;
        }
        var cached = _lyrics.Cached(track);
        LyricsStatus = cached is null ? "Loading lyrics…" : "";
        var lyrics = cached ?? await _lyrics.LoadAsync(track);
        if (request != _lyricsRequest) return;
        _currentLyrics = lyrics;
        if (lyrics is null || lyrics.Lines.Count == 0)
        {
            LyricsStatus = "No lyrics for this song";
            return;
        }
        for (var i = 0; i < lyrics.Lines.Count; i++) LyricLines.Add(new LyricRow(lyrics.Lines[i], i));
        HasLyrics = true;
        LyricsStatus = lyrics.IsSynced ? "" : "These lyrics aren't synced";
        UpdateLyricIndex();
    }

    private void UpdateLyricIndex()
    {
        if (_currentLyrics is not { IsSynced: true } lyrics) return;
        // Show a line a moment early, as it reads more naturally with the singing.
        var index = lyrics.LineIndex(_player.CurrentTime + 0.25) ?? -1;
        if (index == CurrentLyricIndex) return;
        CurrentLyricIndex = index;
        foreach (var row in LyricLines)
        {
            row.IsCurrent = row.Index == index;
            row.IsPast = row.Index < index;
        }
        LyricIndexChanged?.Invoke(index);
    }
}
