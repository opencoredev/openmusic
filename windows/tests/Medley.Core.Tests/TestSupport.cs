using System.ComponentModel;
using Medley.Core.Threading;

namespace Medley.Core.Tests;

// Port of Tests/MedleyCoreTests/TestSupport.swift. Every test that touches PlayerController runs inside
// MainThreadContext.Run, the stand-in for Swift's main actor.

internal static class T
{
    public static List<Track> MakeTracks(int count, string prefix = "t", ProviderId provider = ProviderId.YouTubeMusic, double? duration = 200) =>
        Enumerable.Range(0, count).Select(i => new Track
        {
            ProviderID = $"{prefix}{i}", Provider = provider, Title = $"{prefix.ToUpperInvariant()} {i}",
            Artists = [new ArtistRef(null, "Artist")], Album = new AlbumRef(null, "Album"), Duration = duration,
        }).ToList();

    public static void OnMain(Func<Task> body) => MainThreadContext.Run(body);

    /// <summary>Polls <paramref name="condition"/> on the context until it's true or the timeout passes.</summary>
    public static async Task<bool> WaitUntil(Func<bool> condition, double timeout = 10)
    {
        var deadline = DateTime.UtcNow.AddSeconds(timeout);
        while (DateTime.UtcNow < deadline)
        {
            if (condition()) return true;
            await Task.Delay(20);
        }
        return condition();
    }

    public static string Fixture(string name) => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", name + ".json"));
}

/// <summary>Time only moves when the test says so.</summary>
internal sealed class ManualScheduler : IPlaybackScheduler
{
    public DateTimeOffset Now { get; set; } = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
    private readonly List<(int Id, DateTimeOffset At, Action Action)> _items = [];
    private int _nextId;

    public int PendingCount => _items.Count;

    public ScheduledAction Schedule(double delaySeconds, Action action)
    {
        var id = ++_nextId;
        _items.Add((id, Now.AddSeconds(delaySeconds), action));
        return new ScheduledAction(() => _items.RemoveAll(i => i.Id == id));
    }

    public void Advance(double seconds)
    {
        var target = Now.AddSeconds(seconds);
        while (_items.Where(i => i.At <= target).OrderBy(i => i.At).Cast<(int Id, DateTimeOffset At, Action Action)?>().FirstOrDefault() is { } next)
        {
            _items.RemoveAll(i => i.Id == next.Id);
            if (next.At > Now) Now = next.At;
            next.Action();
        }
        Now = target;
    }
}

/// <summary>Scriptable engine: records commands, can hold or fail loads, and emits events on demand.</summary>
internal sealed class FakeEngine : IDurationReportingEngine
{
    public Action<PlaybackEvent>? OnEvent { get; set; }
    public Action<string, double>? OnDurationResolved { get; set; }
    public float Volume { get; set; } = 1;
    public double CurrentTime { get; set; }
    public double? Duration { get; set; }

    public sealed record LoadCall(string TrackId, double StartAt, bool Autoplay);

    public List<LoadCall> Loads { get; } = [];
    /// <summary>Each <see cref="PrepareNext"/> call's track id (null for none).</summary>
    public List<string?> Prepared { get; } = [];
    public int Plays { get; private set; }
    public int Pauses { get; private set; }
    public int Stops { get; private set; }
    public List<double> Seeks { get; } = [];
    public HashSet<string> FailingIds { get; set; } = [];
    public bool HoldLoads { get; set; }
    private readonly List<(string Id, TaskCompletionSource Gate)> _held = [];

    public LoadCall? LastLoad => Loads.LastOrDefault();
    /// <summary>Whether anything was prepared, and the last id (null = "nothing next").</summary>
    public (bool Any, string? Id) LastPrepared => Prepared.Count == 0 ? (false, null) : (true, Prepared[^1]);
    public int HeldCount => _held.Count;

    public async Task LoadAsync(Track track, double startAt, bool autoplay, CancellationToken ct)
    {
        Loads.Add(new LoadCall(track.Id, startAt, autoplay));
        if (HoldLoads)
        {
            var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            _held.Add((track.Id, gate));
            await gate.Task;
        }
        if (FailingIds.Contains(track.Id)) throw ProviderException.Unplayable($"fake failure for {track.Id}");
        Duration = track.Duration;
        CurrentTime = startAt;
        OnEvent?.Invoke(new PlaybackEvent.StateChanged(autoplay ? PlaybackState.Playing : PlaybackState.Paused));
    }

    /// <summary>Resume a held load (by position in the held list).</summary>
    public void Release(int index)
    {
        var item = _held[index];
        _held.RemoveAt(index);
        item.Gate.SetResult();
    }

    public void ReleaseAll()
    {
        while (_held.Count > 0) Release(0);
    }

    public void Play()
    {
        Plays++;
        OnEvent?.Invoke(new PlaybackEvent.StateChanged(PlaybackState.Playing));
    }

    public void Pause()
    {
        Pauses++;
        OnEvent?.Invoke(new PlaybackEvent.StateChanged(PlaybackState.Paused));
    }

    public void Stop()
    {
        Stops++;
        OnEvent?.Invoke(new PlaybackEvent.StateChanged(PlaybackState.Idle));
    }

    public void Seek(double seconds)
    {
        Seeks.Add(seconds);
        CurrentTime = seconds;
    }

    public void PrepareNext(Track? track) => Prepared.Add(track?.Id);

    // Event helpers
    public void Tick(double t)
    {
        CurrentTime = t;
        OnEvent?.Invoke(new PlaybackEvent.Time(t, Duration));
    }

    /// <summary>Ticks once per second from the current time up to <paramref name="t"/>, like real playback.</summary>
    public void PlayUntil(double t)
    {
        var now = CurrentTime;
        while (now < t)
        {
            now = Math.Min(t, now + 1);
            Tick(now);
        }
    }

    public void Finish()
    {
        OnEvent?.Invoke(new PlaybackEvent.StateChanged(PlaybackState.Ended));
        OnEvent?.Invoke(PlaybackEvent.Finished.Instance);
    }

    public void FailMidTrack(string message = "stream died")
    {
        OnEvent?.Invoke(new PlaybackEvent.StateChanged(PlaybackState.Failed));
        OnEvent?.Invoke(new PlaybackEvent.Failed(message));
    }

    public void Emit(PlaybackEvent ev) => OnEvent?.Invoke(ev);
}

internal sealed class FakeProvider(ProviderId id = ProviderId.YouTubeMusic) : IMusicProvider
{
    public ProviderId Id { get; } = id;
    public ProviderCapabilities Capabilities { get; set; } = ProviderCapabilities.Radio | ProviderCapabilities.Playback;
    public AuthStatus AuthStatus { get; set; } = AuthStatus.SignedIn(new AccountInfo("Test"));
    public FakeEngine Engine { get; } = new();
    public IPlaybackEngine PlaybackEngine => Engine;

    public List<Track> RadioResult { get; set; } = [];
    public List<string> RadioCalls { get; } = [];
    public bool HoldRadio { get; set; }
    private readonly List<TaskCompletionSource> _heldRadio = [];

    public event PropertyChangedEventHandler? PropertyChanged { add { } remove { } }

    public void ReleaseRadio()
    {
        var pending = _heldRadio.ToList();
        _heldRadio.Clear();
        foreach (var g in pending) g.SetResult();
    }

    public Task RestoreSessionAsync(CancellationToken ct = default) => Task.CompletedTask;
    public Task SignOutAsync() => Task.CompletedTask;
    public Task<IReadOnlyList<Shelf>> HomeAsync(CancellationToken ct = default) => Task.FromResult<IReadOnlyList<Shelf>>([]);
    public Task<IReadOnlyList<Shelf>> ExploreAsync(CancellationToken ct = default) => Task.FromResult<IReadOnlyList<Shelf>>([]);
    public Task<Shelf> ShelfAsync(string moreToken, CancellationToken ct = default) => throw ProviderException.NotSupported("shelf");
    public Task<SearchResults> SearchAsync(string query, SearchScope scope, CancellationToken ct = default) => Task.FromResult(new SearchResults());
    public Task<IReadOnlyList<string>> SearchSuggestionsAsync(string query, CancellationToken ct = default) => Task.FromResult<IReadOnlyList<string>>([]);
    public Task<AlbumDetail> AlbumAsync(string id, CancellationToken ct = default) => throw ProviderException.NotFound();
    public Task<ArtistDetail> ArtistAsync(string id, CancellationToken ct = default) => throw ProviderException.NotFound();
    public Task<PlaylistDetail> PlaylistAsync(string id, CancellationToken ct = default) => throw ProviderException.NotFound();
    public Task<Page<Track>> PlaylistTracksAsync(string continuation, CancellationToken ct = default) => Task.FromResult(new Page<Track>([]));
    public Task<Page<MediaItem>> LibraryAsync(LibraryKind kind, string? continuation, CancellationToken ct = default) => Task.FromResult(new Page<MediaItem>([]));
    public Task SetLikedAsync(Track track, bool liked, CancellationToken ct = default) => Task.CompletedTask;
    public Task<bool> IsLikedAsync(Track track, CancellationToken ct = default) => Task.FromResult(false);
    public Task SetSavedAsync(MediaItem item, bool saved, CancellationToken ct = default) => Task.CompletedTask;
    public Task<Playlist> CreatePlaylistAsync(string title, string? description, CancellationToken ct = default) => throw ProviderException.NotSupported("create");
    public Task AddAsync(IReadOnlyList<Track> tracks, string playlistId, CancellationToken ct = default) => Task.CompletedTask;
    public Task RemoveAsync(IReadOnlyList<Track> tracks, string playlistId, CancellationToken ct = default) => Task.CompletedTask;

    public async Task<IReadOnlyList<Track>> RadioAsync(Track seed, CancellationToken ct = default)
    {
        RadioCalls.Add(seed.Id);
        if (HoldRadio)
        {
            var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            _heldRadio.Add(gate);
            await gate.Task;
        }
        return RadioResult.ToList();
    }

    public Task<IReadOnlyList<Track>> RadioAsync(string seedId, CancellationToken ct = default)
    {
        RadioCalls.Add(seedId);
        return Task.FromResult<IReadOnlyList<Track>>(RadioResult.ToList());
    }

    public Task<Lyrics?> LyricsAsync(Track track, CancellationToken ct = default) => Task.FromResult<Lyrics?>(null);
}
