using OpenMusic.Core.Support;

namespace OpenMusic.Core;

/// <summary>Reads and writes <see cref="PlayerSnapshot"/> JSON (the Swift app's queue.json format). Thread-safe: saves run
/// off the UI thread, and a save never writes an older snapshot over a newer one. Port of QueueStore in
/// Sources/OpenMusicCore/System/QueuePersistence.swift.</summary>
public sealed class QueueStore
{
    private readonly Lock _lock = new();
    private long _newest = long.MinValue;

    public string Path { get; }

    public QueueStore(string path) => Path = path;

    /// <summary><c>%LOCALAPPDATA%\OpenMusic\queue.json</c> (<c>~/.local/share/OpenMusic/queue.json</c> on Linux).</summary>
    public static string DefaultPath =>
        System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), ProductInfo.FolderName, "queue.json");

    /// <summary>The saved snapshot, or null when there is none, it's corrupt, or it's from a newer version.</summary>
    public PlayerSnapshot? Load()
    {
        try
        {
            if (!File.Exists(Path)) return null;
            var snapshot = OpenMusicJson.Deserialize(File.ReadAllBytes(Path), OpenMusicJsonContext.Default.PlayerSnapshot);
            return snapshot is not null && snapshot.Version <= PlayerSnapshot.CurrentVersion && IsWellFormed(snapshot) ? snapshot : null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    public Task<PlayerSnapshot?> LoadAsync() => Task.Run(Load);

    /// <summary>System.Text.Json accepts an explicit <c>null</c> for a non-nullable reference (<c>"queue":null</c>,
    /// a track without a title) where Swift's decoder refuses the file; refuse those here too, so a damaged file means
    /// "nothing saved" instead of a crash in <see cref="PlayerController.Restore"/>.</summary>
    internal static bool IsWellFormed(PlayerSnapshot s) =>
        s.Queue is not null && s.RecentlyPlayed is not null
        && s.Queue.All(e => e is not null && IsWellFormed(e.Track))
        && s.RecentlyPlayed.All(p => p is not null && IsWellFormed(p.Track));

    internal static bool IsWellFormed(Track? t) =>
        t is not null && t.ProviderID is not null && t.Title is not null && t.Artists is not null && t.Extra is not null
        && t.Artists.All(a => a is not null && a.Name is not null)
        && (t.Album is null || t.Album.Title is not null)
        && (t.Artwork is null || (t.Artwork.Images is not null && t.Artwork.Images.All(i => i is not null && i.Url is not null)));

    public void Save(PlayerSnapshot snapshot) => Write(snapshot, null);

    /// <summary>Saves unless a snapshot with a later <paramref name="generation"/> was already written. Returns whether it wrote.</summary>
    public bool Save(PlayerSnapshot snapshot, long generation) => Write(snapshot, generation);

    public void Clear()
    {
        lock (_lock)
        {
            try { File.Delete(Path); }
            catch (IOException) { }
        }
    }

    private bool Write(PlayerSnapshot snapshot, long? generation)
    {
        var data = OpenMusicJson.SerializeToUtf8(snapshot, OpenMusicJsonContext.Default.PlayerSnapshot);
        lock (_lock)
        {
            if (generation is { } g && g <= _newest) return false;
            var dir = System.IO.Path.GetDirectoryName(Path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            var tmp = Path + ".tmp";
            File.WriteAllBytes(tmp, data);
            File.Move(tmp, Path, overwrite: true);
            if (generation is { } gen) _newest = gen;
            return true;
        }
    }
}

/// <summary>Saves the queue, position, shuffle and repeat whenever they change (debounced), and puts them back at launch,
/// paused at the saved position. Use it on the UI thread. Call <see cref="FlushSynchronously"/> when the app closes.</summary>
public sealed class QueuePersistence
{
    private readonly PlayerController _player;
    private readonly IPlaybackScheduler _scheduler;
    private readonly double _debounce;
    /// <summary>While playing, the position is saved this often so a crash loses little.</summary>
    private readonly double _playingInterval;
    private ScheduledAction? _pending;
    private DateTimeOffset? _pendingFireDate;
    private Guid? _handlerId;
    private Task? _saveTask;
    /// <summary>Numbers snapshots in the order they're taken; the store keeps only the newest.</summary>
    private long _generation;

    public QueueStore Store { get; }
    internal int SaveCount { get; private set; }

    public QueuePersistence(PlayerController player, QueueStore store, IPlaybackScheduler? scheduler = null, double debounce = 1.5, double playingInterval = 20)
    {
        _player = player;
        Store = store;
        _scheduler = scheduler ?? new SystemScheduler();
        _debounce = debounce;
        _playingInterval = playingInterval;
    }

    /// <summary>Load the saved snapshot into the player. Returns false when there was nothing to restore.</summary>
    public async Task<bool> RestoreAsync()
    {
        if (await Store.LoadAsync() is not { } snapshot) return false;
        _player.Restore(snapshot);
        return true;
    }

    /// <summary>Start saving on changes.</summary>
    public void Start()
    {
        if (_handlerId is not null) return;
        _handlerId = _player.AddChangeHandler(_ => ScheduleSave(_debounce));
    }

    public void Stop()
    {
        if (_handlerId is { } id) _player.RemoveChangeHandler(id);
        _handlerId = null;
        _pending?.Cancel();
        _pending = null;
    }

    /// <summary>Save now, skipping the debounce.</summary>
    public async Task FlushAsync()
    {
        _pending?.Cancel();
        _pending = null;
        if (_saveTask is { } t) await t;
        var snapshot = _player.Snapshot();
        SaveCount++;
        var generation = ++_generation;
        await Task.Run(() => Store.Save(snapshot, generation));
    }

    /// <summary>The app is closing: write now, on this thread. A background save still queued holds an older snapshot and
    /// is dropped by the store.</summary>
    public void FlushSynchronously()
    {
        _pending?.Cancel();
        _pending = null;
        var snapshot = _player.Snapshot();
        SaveCount++;
        try { Store.Save(snapshot, ++_generation); }
        catch (IOException) { }
    }

    /// <summary>Waits for background saves already started. For tests.</summary>
    internal Task WaitForPendingSavesAsync() => _saveTask ?? Task.CompletedTask;

    private void ScheduleSave(double delay)
    {
        // Throttle: the first change schedules a save and later ones ride along with it, unless they need it sooner
        // (a pause shouldn't wait for the slow while-playing save).
        var fireDate = _scheduler.Now.AddSeconds(delay);
        if (_pending is not null && _pendingFireDate is { } pf && pf <= fireDate) return;
        _pending?.Cancel();
        _pendingFireDate = fireDate;
        _pending = _scheduler.Schedule(delay, SaveNow);
    }

    private void SaveNow()
    {
        _pending = null;
        _pendingFireDate = null;
        var snapshot = _player.Snapshot();
        SaveCount++;
        var generation = ++_generation;
        var previous = _saveTask;
        _saveTask = Task.Run(async () =>
        {
            if (previous is not null) await previous.ConfigureAwait(false);
            try { Store.Save(snapshot, generation); }
            catch (IOException) { }
        });
        if (_player.IsPlaying) ScheduleSave(_playingInterval);
    }
}
