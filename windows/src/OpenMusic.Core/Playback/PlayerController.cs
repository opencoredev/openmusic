using System.ComponentModel;
using System.Runtime.CompilerServices;
using OpenMusic.Core.Support;

namespace OpenMusic.Core;

/// <summary>
/// The one place playback is controlled from. Owns the queue and routes each track to its provider's engine.
/// Port of Sources/OpenMusicCore/Playback/PlayerController.swift with the same semantics.
/// <para>
/// Queue model: <see cref="Queue"/> holds the entries before <see cref="CurrentIndex"/> (<see cref="PreviousEntries"/>),
/// the current entry, and Up Next (after it). Entries come from the played context (album, playlist), from the user
/// (Play Next, Add to Queue, insert), or from autoplay radio. Shuffle reorders only context entries in Up Next;
/// user-queued entries stay in front and autoplay entries stay at the end. Earlier entries are never reordered, so
/// Previous walks back through the queue in order. What the listener actually heard is a separate list,
/// <see cref="ListeningHistory"/>.
/// </para>
/// <para>
/// Threading: like Swift's <c>@MainActor</c>, use it from one thread that has a <see cref="SynchronizationContext"/>
/// (the UI thread; <see cref="Threading.MainThreadContext"/> elsewhere). Loads and radio fetches start on a later turn of
/// that context, as Swift's <c>Task { }</c> does, and resume on it.
/// </para>
/// </summary>
public sealed class PlayerController : INotifyPropertyChanged
{
    // MARK: Published state

    private readonly List<QueueEntry> _queue = [];
    private QueueEntry[]? _queueView;
    private int? _currentIndex;
    private PlaybackState _state = PlaybackState.Idle;
    private double _currentTime;
    private double? _duration;
    private string? _lastError;
    private List<PlayedTrack> _recentlyPlayed = [];
    private SleepTimer _sleepTimer = SleepTimer.Off;
    private RepeatMode _repeatMode = RepeatMode.Off;
    private bool _autoplay = true;
    private bool _normalizationEnabled = true;
    private string? _outputDeviceId;

    /// <summary>The whole queue, earlier entries included. A snapshot: it doesn't change under the caller.</summary>
    public IReadOnlyList<QueueEntry> Queue => _queueView ??= [.. _queue];

    /// <summary>Index into <see cref="Queue"/> of the current entry, null when nothing is loaded.</summary>
    public int? CurrentIndex
    {
        get => _currentIndex;
        private set
        {
            if (_currentIndex == value) return;
            _currentIndex = value;
            Raise();
            RaiseCursorDerived();
        }
    }

    public PlaybackState State
    {
        get => _state;
        private set
        {
            if (_state == value) return;
            _state = value;
            Raise();
            Raise(nameof(IsPlaying));
        }
    }

    public double CurrentTime
    {
        get => _currentTime;
        private set
        {
            if (_currentTime.Equals(value)) return;
            _currentTime = value;
            Raise();
        }
    }

    public double? Duration
    {
        get => _duration;
        private set
        {
            if (Nullable.Equals(_duration, value)) return;
            _duration = value;
            Raise();
        }
    }

    public string? LastError
    {
        get => _lastError;
        private set
        {
            if (_lastError == value) return;
            _lastError = value;
            Raise();
        }
    }

    /// <summary>Tracks the listener heard for 30 s (or half their length), newest first, one entry per track. Includes the
    /// current song once it counts; <see cref="ListeningHistory"/> is the list to show.</summary>
    public IReadOnlyList<PlayedTrack> RecentlyPlayed => _recentlyPlayed;

    public SleepTimer SleepTimer
    {
        get => _sleepTimer;
        private set
        {
            if (_sleepTimer == value) return;
            _sleepTimer = value;
            Raise();
            Raise(nameof(SleepTimerRemaining));
        }
    }

    public bool Shuffle
    {
        get => _shuffleEnabled;
        set => SetShuffle(value);
    }

    public RepeatMode RepeatMode
    {
        get => _repeatMode;
        set
        {
            if (_repeatMode == value) return;
            _repeatMode = value;
            Raise();
            QueueDidChange();
        }
    }

    /// <summary>Continue with radio tracks when the queue runs out.</summary>
    public bool Autoplay
    {
        get => _autoplay;
        set
        {
            var old = _autoplay;
            _autoplay = value;
            if (old != value) Raise();
            if (value && !old) ExtendWithRadioIfNeeded();
        }
    }

    /// <summary>0…1</summary>
    public float Volume
    {
        get => _volumeLevel;
        set
        {
            _volumeLevel = Math.Clamp(value, 0, 1);
            if (_activeEngine is not null) _activeEngine.Volume = _volumeLevel;
            Raise();
        }
    }

    /// <summary>Loudness normalization for engines that support it (<see cref="IConfigurableAudioEngine"/>).</summary>
    public bool NormalizationEnabled
    {
        get => _normalizationEnabled;
        set
        {
            _normalizationEnabled = value;
            ApplyAudioSettingsToAllEngines();
            Raise();
        }
    }

    /// <summary>Crossfade in seconds, 0…12. 0 (the default) means a gapless-style handoff with no overlap.</summary>
    public double CrossfadeDuration
    {
        get => _crossfadeSeconds;
        set
        {
            _crossfadeSeconds = Math.Clamp(value, 0, MaxCrossfade);
            ApplyAudioSettingsToAllEngines();
            Raise();
        }
    }

    /// <summary>Audio endpoint id, null for the system default.</summary>
    public string? OutputDeviceId
    {
        get => _outputDeviceId;
        set
        {
            _outputDeviceId = value;
            ApplyAudioSettingsToAllEngines();
            Raise();
        }
    }

    /// <summary>Called once each time a track counts as played (see <see cref="RecentlyPlayed"/>).</summary>
    public Action<PlayedTrack>? OnTrackPlayed { get; set; }

    public event PropertyChangedEventHandler? PropertyChanged;

    // MARK: Derived state

    public Track? Current => CurrentEntry?.Track;

    public QueueEntry? CurrentEntry => _currentIndex is { } i && i >= 0 && i < _queue.Count ? _queue[i] : null;

    /// <summary>Where the current entry came from.</summary>
    public PlaybackContext? CurrentContext => CurrentEntry?.Context;

    /// <summary>"Playing from &lt;album/playlist&gt;", or null when the current entry has no context.</summary>
    public string? SourceLabel => CurrentContext?.Label;

    /// <summary>Index in <see cref="Queue"/> where Up Next begins. Converts Up Next offsets to queue indices.</summary>
    public int UpNextStartIndex => _currentIndex is { } i ? Math.Min(i + 1, _queue.Count) : 0;

    public IReadOnlyList<QueueEntry> UpNext => new ArraySegment<QueueEntry>((QueueEntry[])Queue, UpNextStartIndex, _queue.Count - UpNextStartIndex);

    /// <summary>Queue entries before the current one, in queue order. Not a record of listening.</summary>
    public IReadOnlyList<QueueEntry> PreviousEntries =>
        _currentIndex is { } i ? new ArraySegment<QueueEntry>((QueueEntry[])Queue, 0, Math.Min(i, _queue.Count)) : [];

    /// <summary>
    /// Songs the listener actually heard, newest first: the queue panel's History. A song is listed once it has played
    /// for 30 seconds of listening time, or half its length if that's shorter (Spotify's stream count). Seeking ahead
    /// doesn't add listening time. One entry per song; it outlives the queue; capped at <see cref="MaxRecentlyPlayed"/>.
    /// The song playing now isn't listed while it plays.
    /// </summary>
    public IReadOnlyList<PlayedTrack> ListeningHistory
    {
        get
        {
            if (Current?.Id is not { } id) return _recentlyPlayed;
            return _recentlyPlayed.Where(p => p.Track.Id != id).ToList();
        }
    }

    public bool IsPlaying => _state is PlaybackState.Playing or PlaybackState.Buffering || (_state == PlaybackState.Loading && LoadAutoplays);

    /// <summary>Seconds until the sleep timer pauses playback, null when it isn't a timed one.</summary>
    public double? SleepTimerRemaining =>
        _sleepTimer is { Kind: SleepTimerKind.At, Deadline: { } d } ? Math.Max(0, (d - _scheduler.Now).TotalSeconds) : null;

    // MARK: Wiring

    private readonly Dictionary<ProviderId, IMusicProvider> _providers = [];
    private IPlaybackEngine? _activeEngine;
    private readonly IPlaybackScheduler _scheduler;
    private readonly Dictionary<Guid, Action<PlayerChange>> _changeHandlers = [];

    private bool _shuffleEnabled;
    private float _volumeLevel = 0.8f;
    private double _crossfadeSeconds;
    /// <summary>Rank of each entry before shuffle was turned on.</summary>
    private Dictionary<Guid, int>? _originalRank;

    private Task? _loadTask;
    private CancellationTokenSource? _loadCts;
    private int _loadToken;
    private bool _loadAutoplaysValue = true;
    /// <summary>True after <see cref="Restore"/> (or <see cref="Stop"/>) until the current entry is loaded into an engine.</summary>
    private bool _needsLoad;
    private int _consecutiveFailures;

    private Task? _radioTask;
    private CancellationTokenSource? _radioCts;
    /// <summary>Set while the queue ran out and the player waits on a radio fetch to move on: whether the next track should
    /// play (true) or be cued paused (false). Null when no advance is pending.</summary>
    private bool? _pendingRadioAdvance;
    /// <summary>Bumped whenever the queue is replaced, so a radio fetch for an old queue is discarded.</summary>
    private int _queueGeneration;
    private string? _exhaustedRadioSeed;

    private ScheduledAction? _sleepAction;

    private double _listenedSeconds;
    private double _lastTickTime;
    private bool _playRecorded;

    public const int MaxRecentlyPlayed = 100;
    public const int MaxRadioBatch = 25;
    public const double MaxCrossfade = 12;
    internal const int MaxConsecutiveFailures = 5;

    private bool LoadAutoplays
    {
        get => _loadAutoplaysValue;
        set
        {
            if (_loadAutoplaysValue == value) return;
            _loadAutoplaysValue = value;
            Raise(nameof(IsPlaying));
        }
    }

    public PlayerController(IPlaybackScheduler? scheduler = null) => _scheduler = scheduler ?? new SystemScheduler();

    public void Register(IMusicProvider provider)
    {
        _providers[provider.Id] = provider;
        var engine = provider.PlaybackEngine;
        ApplyAudioSettings(engine);
        engine.OnEvent = ev =>
        {
            if (ReferenceEquals(engine, _activeEngine)) Handle(ev);
        };
        if (engine is IDurationReportingEngine reporting)
        {
            // Not limited to the active engine: the length of a prepared next track is worth keeping too.
            reporting.OnDurationResolved = (trackId, seconds) => LearnStreamDuration(seconds, trackId);
        }
    }

    public IMusicProvider? Provider(ProviderId id) => _providers.GetValueOrDefault(id);

    public IReadOnlyCollection<IMusicProvider> Providers => _providers.Values;

    /// <summary>Subscribe to coarse player changes. Keep the returned id to unsubscribe.</summary>
    public Guid AddChangeHandler(Action<PlayerChange> handler)
    {
        var id = Guid.NewGuid();
        _changeHandlers[id] = handler;
        return id;
    }

    public void RemoveChangeHandler(Guid id) => _changeHandlers.Remove(id);

    // MARK: Queue commands

    /// <summary>Replace the queue with <paramref name="tracks"/> and start playing.</summary>
    /// <param name="startAt">The track to start with. Null starts at the first track, or a random one when shuffling.</param>
    /// <param name="shuffled">True or false turns shuffle on or off; null keeps the current setting.</param>
    /// <param name="context">Shown as "Playing from &lt;title&gt;".</param>
    public void Play(IReadOnlyList<Track> tracks, int? startAt = null, bool? shuffled = null, PlaybackContext? context = null)
    {
        var playable = Enumerable.Range(0, tracks.Count).Where(i => tracks[i].IsPlayable).ToList();
        if (playable.Count == 0) return;
        var useShuffle = shuffled ?? _shuffleEnabled;

        // The first playable track at or after the requested index.
        int startSource;
        if (startAt is { } index) startSource = playable.Cast<int?>().FirstOrDefault(i => i >= index) ?? playable[0];
        else if (useShuffle) startSource = playable[Random.Shared.Next(playable.Count)];
        else startSource = playable[0];

        LearnCatalogDurations(tracks);
        var entries = new List<QueueEntry>();
        var start = 0;
        foreach (var i in playable)
        {
            if (i == startSource) start = entries.Count;
            entries.Add(new QueueEntry(WithKnownDuration(tracks[i]), context: context));
        }

        ResetQueueState();
        SetShuffleEnabled(useShuffle);
        if (useShuffle)
        {
            _originalRank = RankMap(entries);
            var first = entries[start];
            entries.RemoveAt(start);
            ShuffleInPlace(entries);
            entries.Insert(0, first);
            start = 0;
        }
        ReplaceQueue(entries);
        CurrentIndex = null;
        Notify(PlayerChange.Queue);
        StartEntry(start);
    }

    public void Play(Track track, PlaybackContext? context = null) => Play([track], context: context);

    /// <summary>Replace the queue with <paramref name="entries"/> exactly as given (uids, flags and contexts kept, nothing
    /// reshuffled), make <paramref name="index"/> current and load it at <paramref name="position"/>. With
    /// <paramref name="autoplay"/> false the track is cued paused once the engine is ready, so a caller can seek to a
    /// fresher position and then <see cref="Resume"/>. Used by cross-device handoff.</summary>
    public void Load(IReadOnlyList<QueueEntry> entries, int index, double position, bool shuffle, RepeatMode repeatMode, bool autoplay)
    {
        if (index < 0 || index >= entries.Count) return;
        LearnCatalogDurations(entries.Select(e => e.Track).ToList());
        ResetQueueState();
        SetShuffleEnabled(shuffle);
        RepeatMode = repeatMode;
        ReplaceQueue(entries.Select(e => e with { Track = WithKnownDuration(e.Track) }));
        CurrentIndex = null;
        Notify(PlayerChange.Queue);
        StartEntry(index, Math.Max(0, position), autoplay);
    }

    /// <summary>Start a radio station seeded by <paramref name="seed"/>. The seed plays first.</summary>
    public async Task PlayRadioAsync(Track seed)
    {
        if (!_providers.TryGetValue(seed.Provider, out var provider))
        {
            Fail($"{seed.Provider.DisplayName()} isn't available.");
            return;
        }
        var context = PlaybackContext.Radio(seed.Title, seed.ProviderID, seed.Provider);
        try
        {
            var tracks = await provider.RadioAsync(seed);
            LearnCatalogDurations(tracks);
            var seen = new HashSet<string> { seed.Id };
            Play([seed, .. tracks.Where(t => seen.Add(t.Id))], startAt: 0, shuffled: false, context: context);
        }
        catch (Exception)
        {
            Play([seed], context: context);
        }
    }

    /// <summary>Start a radio from an artist or playlist seed (<see cref="ArtistDetail.RadioSeed"/>, a playlist id).</summary>
    public async Task PlayRadioAsync(string seedId, ProviderId providerId, string title)
    {
        if (!_providers.TryGetValue(providerId, out var provider))
        {
            Fail($"{providerId.DisplayName()} isn't available.");
            return;
        }
        try
        {
            var tracks = await provider.RadioAsync(seedId);
            Play(Dedupe(tracks), startAt: 0, shuffled: false, context: PlaybackContext.Radio(title, seedId, providerId));
        }
        catch (Exception e)
        {
            Fail(e.Message);
        }
    }

    /// <summary>Play <paramref name="track"/> now, keeping the rest of the queue: it goes in right after the current entry
    /// and starts, and Up Next carries on after it. Used for songs picked from History.</summary>
    public void PlayNow(Track track, PlaybackContext? context = null)
    {
        if (!track.IsPlayable) return;
        if (_currentIndex is null)
        {
            Play([track], context: context);
            return;
        }
        // A radio fetch still running at the end of the queue would otherwise advance past this song when it lands.
        if (_pendingRadioAdvance is not null) _pendingRadioAdvance = null;
        var at = UpNextStartIndex;
        InsertUserEntries([track], at, context);
        StartEntry(at);
    }

    /// <summary>Insert right after the current entry ("Play Next").</summary>
    public void PlayNext(IReadOnlyList<Track> tracks, PlaybackContext? context = null)
    {
        if (_currentIndex is null)
        {
            Play(tracks, context: context);
            return;
        }
        InsertUserEntries(tracks, UpNextStartIndex, context);
    }

    /// <summary>Add after everything the user and the context queued, before autoplay entries ("Play Later").</summary>
    public void AddToQueue(IReadOnlyList<Track> tracks, PlaybackContext? context = null)
    {
        if (_currentIndex is null)
        {
            Play(tracks, context: context);
            return;
        }
        var firstAuto = _queue.Count;
        for (var i = UpNextStartIndex; i < _queue.Count; i++)
        {
            if (_queue[i].IsAutoplay)
            {
                firstAuto = i;
                break;
            }
        }
        InsertUserEntries(tracks, firstAuto, context);
    }

    /// <summary>Insert at an absolute queue index. Indices at or before the current entry go to the start of Up Next.</summary>
    public void Insert(IReadOnlyList<Track> tracks, int index, PlaybackContext? context = null)
    {
        if (_currentIndex is null)
        {
            Play(tracks, context: context);
            return;
        }
        InsertUserEntries(tracks, Math.Max(UpNextStartIndex, Math.Min(index, _queue.Count)), context);
    }

    /// <summary>Insert at an offset within Up Next (0 = play next). For drag and drop into the Up Next list.</summary>
    public void InsertAtUpNextOffset(IReadOnlyList<Track> tracks, int offset, PlaybackContext? context = null) =>
        Insert(tracks, UpNextStartIndex + Math.Max(0, offset), context);

    /// <summary>Remove an entry. Removing the current entry moves on to the next one (keeping play/pause state).</summary>
    public void Remove(Guid uid) => Remove([uid]);

    public void Remove(IEnumerable<Guid> uids)
    {
        var doomed = uids.ToHashSet();
        if (doomed.Count == 0 || !_queue.Any(e => doomed.Contains(e.Uid))) return;
        var currentUid = CurrentEntry?.Uid;
        var removingCurrent = currentUid is { } cu && doomed.Contains(cu);

        if (removingCurrent && _currentIndex is { } c)
        {
            // The new current is the first surviving entry after the old one.
            var autoplay = ShouldAutoplayOnSkip;
            var nextUid = _queue.Skip(c + 1).FirstOrDefault(e => !doomed.Contains(e.Uid))?.Uid;
            MutateQueue(q => q.RemoveAll(e => doomed.Contains(e.Uid)));
            _originalRank = _originalRank?.Where(kv => !doomed.Contains(kv.Key)).ToDictionary();
            CurrentIndex = null;
            var n = nextUid is { } nu ? _queue.FindIndex(e => e.Uid == nu) : -1;
            if (n >= 0)
            {
                Notify(PlayerChange.Queue);
                Go(n, autoplay);
            }
            else if (_queue.Count == 0)
            {
                ClearQueue();
            }
            else
            {
                CurrentIndex = _queue.Count - 1;
                EndQueue();
                Notify(PlayerChange.Queue);
                Notify(PlayerChange.Track);
            }
            return;
        }

        MutateQueue(q => q.RemoveAll(e => doomed.Contains(e.Uid)));
        _originalRank = _originalRank?.Where(kv => !doomed.Contains(kv.Key)).ToDictionary();
        CurrentIndex = currentUid is { } uid ? IndexOf(uid) : null;
        QueueDidChange();
    }

    /// <summary>Remove Up Next entries by their offsets within Up Next.</summary>
    public void RemoveUpNext(IEnumerable<int> offsets)
    {
        var b = UpNextStartIndex;
        Remove(offsets.Where(o => b + o >= 0 && b + o < _queue.Count).Select(o => _queue[b + o].Uid).ToList());
    }

    /// <summary>SwiftUI <c>onMove</c> semantics on absolute queue indices: the entries at <paramref name="source"/> move to
    /// before the entry that was at <paramref name="destination"/>.</summary>
    public void Move(IEnumerable<int> source, int destination)
    {
        var valid = source.Where(i => i >= 0 && i < _queue.Count).Distinct().Order().ToList();
        if (valid.Count == 0) return;
        destination = Math.Clamp(destination, 0, _queue.Count);
        var currentUid = CurrentEntry?.Uid;
        var validSet = valid.ToHashSet();
        var moving = valid.Select(i => _queue[i]).ToList();
        var remaining = _queue.Where((_, i) => !validSet.Contains(i)).ToList();
        var removedBefore = valid.Count(i => i < destination);
        remaining.InsertRange(Math.Min(destination - removedBefore, remaining.Count), moving);
        if (remaining.Select(e => e.Uid).SequenceEqual(_queue.Select(e => e.Uid))) return;
        ReplaceQueue(remaining);
        CurrentIndex = currentUid is { } uid ? IndexOf(uid) : null;
        QueueDidChange();
    }

    /// <summary><see cref="Move"/> on offsets within Up Next.</summary>
    public void MoveUpNext(IEnumerable<int> source, int destination)
    {
        var b = UpNextStartIndex;
        Move(source.Select(o => o + b).ToList(), destination + b);
    }

    /// <summary>What "Clear Up Next" removed, so it can be put back (<see cref="RestoreUpNext"/>).</summary>
    public sealed class ClearedUpNext
    {
        /// <summary>The removed entries, in queue order, flags and context unchanged.</summary>
        public IReadOnlyList<QueueEntry> Entries { get; }
        /// <summary>Every entry after the current one before the clear, removed or kept, in order.</summary>
        internal IReadOnlyList<Guid> Order { get; }
        /// <summary>The removed entries' places in the order from before shuffle was turned on, if it was on.</summary>
        internal IReadOnlyDictionary<Guid, int> Ranks { get; }
        /// <summary>The queue they came from: once another album or playlist replaced it, they don't come back.</summary>
        internal int Generation { get; }

        internal ClearedUpNext(IReadOnlyList<QueueEntry> entries, IReadOnlyList<Guid> order, IReadOnlyDictionary<Guid, int> ranks, int generation)
        {
            Entries = entries;
            Order = order;
            Ranks = ranks;
            Generation = generation;
        }
    }

    /// <summary>
    /// Empty the Up Next group: everything after the current song that autoplay didn't add. Autoplay's entries stay, and
    /// the current song plays on. Returns what was removed, for undo; null when there was nothing to remove.
    /// <paramref name="includingAutoplay"/> empties everything after the current song and stops a radio fetch.
    /// </summary>
    public ClearedUpNext? ClearUpNext(bool includingAutoplay = false)
    {
        if (includingAutoplay)
        {
            // As before for that list: with nothing current, the whole queue goes.
            if (_currentIndex is null)
            {
                ClearQueue();
                return null;
            }
            CancelRadio();
        }
        return ClearUpNextWhere(e => includingAutoplay || !e.IsAutoplay);
    }

    /// <summary>Removes the Up Next entries <paramref name="include"/> picks (never the current one), keeping what's needed
    /// to put them back.</summary>
    private ClearedUpNext? ClearUpNextWhere(Func<QueueEntry, bool> include)
    {
        var after = UpNext.ToList();
        var removed = after.Where(include).ToList();
        if (removed.Count == 0) return null;
        var doomed = removed.Select(e => e.Uid).ToHashSet();
        var ranks = _originalRank?.Where(kv => doomed.Contains(kv.Key)).ToDictionary() ?? [];
        var currentUid = CurrentEntry?.Uid;
        MutateQueue(q => q.RemoveAll(e => doomed.Contains(e.Uid)));
        _originalRank = _originalRank?.Where(kv => !doomed.Contains(kv.Key)).ToDictionary();
        CurrentIndex = currentUid is { } uid ? IndexOf(uid) : null;
        // No radio fetch here: Autoplay carries on as it was, and Undo gets back exactly the queue from before.
        QueueDidChange();
        return new ClearedUpNext(removed, after.Select(e => e.Uid).ToList(), ranks, _queueGeneration);
    }

    /// <summary>
    /// Undo <see cref="ClearUpNext"/>: the removed entries go back after the current song, each in its old place relative
    /// to the entries still queued from before; songs queued since stay in their group. The current song isn't touched.
    /// Entries already back in the queue are skipped, and nothing comes back once a new album or playlist replaced the queue.
    /// </summary>
    public void RestoreUpNext(ClearedUpNext cleared)
    {
        if (cleared.Generation != _queueGeneration) return;
        var present = _queue.Select(e => e.Uid).ToHashSet();
        var missing = cleared.Entries.Where(e => !present.Contains(e.Uid)).ToList();
        if (missing.Count == 0) return;
        var byUid = new Dictionary<Guid, QueueEntry>();
        foreach (var e in missing) byUid.TryAdd(e.Uid, e);
        var start = UpNextStartIndex;
        var head = _queue.Take(start).ToList();
        var tail = _queue.Skip(start).ToList();
        var tailByUid = new Dictionary<Guid, QueueEntry>();
        foreach (var e in tail) tailByUid.TryAdd(e.Uid, e);
        // The old order, with what is still queued and what comes back; anything queued since goes after it.
        var rebuilt = new List<QueueEntry>();
        var placed = new HashSet<Guid>();
        foreach (var uid in cleared.Order)
        {
            if (byUid.TryGetValue(uid, out var entry) || tailByUid.TryGetValue(uid, out entry))
            {
                rebuilt.Add(entry);
                placed.Add(uid);
            }
        }
        // Songs queued since stay in their group: the listener's before autoplay's, new autoplay songs at the end.
        var since = tail.Where(e => !placed.Contains(e.Uid)).ToList();
        var firstAuto = rebuilt.FindIndex(e => e.IsAutoplay);
        if (firstAuto < 0) firstAuto = rebuilt.Count;
        rebuilt.InsertRange(firstAuto, since.Where(e => !e.IsAutoplay));
        rebuilt.AddRange(since.Where(e => e.IsAutoplay));
        ReplaceQueue([.. head, .. rebuilt]);
        if (_originalRank is not null)
        {
            foreach (var (uid, rank) in cleared.Ranks)
            {
                if (byUid.ContainsKey(uid)) _originalRank[uid] = rank;
            }
        }
        QueueDidChange();
    }

    public const string ClearUpNextActionName = "Clear Up Next";

    /// <summary><see cref="ClearUpNext"/>, registered with <paramref name="undo"/> as "Clear Up Next": Undo puts the songs
    /// back and Redo removes those same songs again (not ones queued since).</summary>
    public void ClearUpNext(UndoStack? undo)
    {
        if (ClearUpNext() is not { } cleared) return;
        RegisterUndo(cleared, undo);
    }

    /// <summary>Removes queued entries after the current song ("Remove from Queue"), registered with <paramref name="undo"/>
    /// as "Remove “&lt;song&gt;”" (or "Remove 3 Songs"). The current song or earlier entries are removed the plain way.</summary>
    public void RemoveUpNext(IEnumerable<Guid> uids, UndoStack? undo)
    {
        var doomed = uids.ToHashSet();
        var elsewhere = doomed.Except(UpNext.Select(e => e.Uid)).ToList();
        if (elsewhere.Count > 0) Remove(elsewhere);
        if (ClearUpNextWhere(e => doomed.Contains(e.Uid)) is not { } removed) return;
        RegisterUndo(removed, undo, RemoveActionName(removed.Entries));
    }

    /// <summary>"Remove “Espresso”", "Remove 3 Songs".</summary>
    public static string RemoveActionName(IReadOnlyList<QueueEntry> entries) =>
        entries.Count == 1 ? $"Remove “{entries[0].Track.Title}”" : $"Remove {entries.Count} Songs";

    private void RegisterUndo(ClearedUpNext cleared, UndoStack? undo, string actionName = ClearUpNextActionName)
    {
        if (undo is null) return;
        undo.Register(actionName, () =>
        {
            RestoreUpNext(cleared);
            undo.Register(actionName, () =>
            {
                var uids = cleared.Entries.Select(e => e.Uid).ToHashSet();
                if (ClearUpNextWhere(e => uids.Contains(e.Uid)) is not { } again) return;
                RegisterUndo(again, undo, actionName);
            });
        });
    }

    /// <summary>Stop and empty the queue.</summary>
    public void ClearQueue()
    {
        _activeEngine?.Stop();
        ResetQueueState();
        ReplaceQueue([]);
        CurrentIndex = null;
        CurrentTime = 0;
        Duration = null;
        State = PlaybackState.Idle;
        _needsLoad = false;
        QueueDidChange();
        Notify(PlayerChange.Track);
        Notify(PlayerChange.State);
    }

    public void Jump(Guid uid)
    {
        var i = IndexOf(uid);
        if (i is { } index) StartEntry(index);
    }

    // MARK: Transport

    public void TogglePlayPause()
    {
        if (IsPlaying) Pause();
        else Resume();
    }

    public void Pause()
    {
        if (_needsLoad) return;
        if (_state == PlaybackState.Loading) LoadAutoplays = false;
        // Waiting on radio after the last track: cue the next one paused when it arrives.
        if (_pendingRadioAdvance is not null) _pendingRadioAdvance = false;
        _activeEngine?.Pause();
    }

    /// <summary>Play from the current position. Loads the current entry first if needed (after restore, stop, end or failure).</summary>
    public void Resume()
    {
        if (_currentIndex is not { } i || i < 0 || i >= _queue.Count)
        {
            if (_queue.Count > 0) StartEntry(0);
            return;
        }
        if (_pendingRadioAdvance is not null)
        {
            // The listener already moved past this track; play the next one once radio delivers it.
            _pendingRadioAdvance = true;
            return;
        }
        if (_needsLoad || _activeEngine is null) StartEntry(i, _currentTime);
        else if (_state == PlaybackState.Ended) StartEntry(0);
        else if (_state == PlaybackState.Failed) StartEntry(i, _currentTime);
        else if (_state == PlaybackState.Loading)
        {
            LoadAutoplays = true;
            _activeEngine.Play();
        }
        else _activeEngine.Play();
    }

    /// <summary>Stop playback but keep the queue. Play resumes the current entry from the start.</summary>
    public void Stop()
    {
        _activeEngine?.Stop();
        CancelLoad();
        _loadToken++;
        _pendingRadioAdvance = null;
        _needsLoad = true;
        CurrentTime = 0;
        State = PlaybackState.Paused;
        Notify(PlayerChange.State);
        Notify(PlayerChange.Timing);
    }

    public void Next() => Advance(ShouldAutoplayOnSkip);

    /// <summary>Restarts the track if more than 3 seconds in (or at the start of the queue), else goes back one.</summary>
    public void Previous()
    {
        if (_currentIndex is not { } i) return;
        if (_currentTime > 3 || i == 0) Seek(0);
        else Go(i - 1, ShouldAutoplayOnSkip);
    }

    public void Seek(double seconds)
    {
        var target = Math.Max(0, Math.Min(seconds, _duration ?? double.MaxValue));
        if (!_needsLoad) _activeEngine?.Seek(target);
        CurrentTime = target;
        _lastTickTime = target;
        Notify(PlayerChange.Timing);
    }

    public void Skip(double seconds) => Seek(_currentTime + seconds);

    // MARK: Sleep timer

    /// <summary>Pause after <paramref name="minutes"/> of wall-clock time.</summary>
    public void SetSleepTimer(double minutes)
    {
        _sleepAction?.Cancel();
        var seconds = Math.Max(0, minutes * 60);
        SleepTimer = SleepTimer.At(_scheduler.Now.AddSeconds(seconds));
        _sleepAction = _scheduler.Schedule(seconds, SleepTimerFired);
        UpdatePrepareNext();
    }

    /// <summary>Pause when the current track ends. The next entry is loaded paused, so Play continues from there.</summary>
    public void SetSleepTimerEndOfTrack()
    {
        _sleepAction?.Cancel();
        _sleepAction = null;
        SleepTimer = SleepTimer.EndOfTrack;
        UpdatePrepareNext();
    }

    public void CancelSleepTimer()
    {
        _sleepAction?.Cancel();
        _sleepAction = null;
        SleepTimer = SleepTimer.Off;
        UpdatePrepareNext();
    }

    private void SleepTimerFired()
    {
        _sleepAction = null;
        SleepTimer = SleepTimer.Off;
        Pause();
        UpdatePrepareNext();
    }

    // MARK: Persistence

    public PlayerSnapshot Snapshot() => new()
    {
        Queue = Queue,
        CurrentIndex = _currentIndex,
        Position = _currentTime,
        Shuffle = _shuffleEnabled,
        RepeatMode = _repeatMode,
        OriginalOrder = _originalRank?.OrderBy(kv => kv.Value).Select(kv => kv.Key).ToList(),
        RecentlyPlayed = _recentlyPlayed.ToList(),
        SavedAt = _scheduler.Now,
    };

    /// <summary>Put back a saved queue, paused at the saved position. Nothing is resolved or loaded until Play, so launch
    /// stays instant and offline-safe.</summary>
    public void Restore(PlayerSnapshot snapshot)
    {
        _activeEngine?.Stop();
        _activeEngine = null;
        ResetQueueState();
        ReplaceQueue(snapshot.Queue);
        SetRecentlyPlayed(snapshot.RecentlyPlayed.Take(MaxRecentlyPlayed).ToList());
        SetShuffleEnabled(snapshot.Shuffle);
        if (snapshot.Shuffle && snapshot.OriginalOrder is { } order)
        {
            _originalRank = [];
            for (var r = 0; r < order.Count; r++) _originalRank.TryAdd(order[r], r);
        }
        RepeatMode = snapshot.RepeatMode;
        if (snapshot.CurrentIndex is { } i && i >= 0 && i < _queue.Count)
        {
            CurrentIndex = i;
            Duration = _queue[i].Track.Duration;
            CurrentTime = Math.Max(0, Math.Min(snapshot.Position, _duration ?? snapshot.Position));
            State = PlaybackState.Paused;
            _needsLoad = true;
        }
        else
        {
            CurrentIndex = null;
            CurrentTime = 0;
            Duration = null;
            State = PlaybackState.Idle;
            _needsLoad = false;
        }
        _lastTickTime = _currentTime;
        Notify(PlayerChange.Queue);
        Notify(PlayerChange.Track);
        Notify(PlayerChange.State);
        Notify(PlayerChange.Timing);
    }

    // MARK: Internals: loading

    private void StartEntry(int index, double startAt = 0, bool autoplay = true)
    {
        if (index < 0 || index >= _queue.Count) return;
        var track = _queue[index].Track;
        CurrentIndex = index;
        CurrentTime = startAt;
        _lastTickTime = startAt;
        Duration = track.Duration;
        LastError = null;
        _listenedSeconds = 0;
        _playRecorded = false;
        _needsLoad = false;
        LoadAutoplays = autoplay;
        _loadToken++;
        var token = _loadToken;
        CancelLoad();

        if (!_providers.TryGetValue(track.Provider, out var provider))
        {
            Notify(PlayerChange.Track);
            HandleLoadFailure($"{track.Provider.DisplayName()} isn't available.", token);
            return;
        }
        var engine = provider.PlaybackEngine;
        var previousEngine = _activeEngine;
        _activeEngine = engine;
        if (previousEngine is not null && !ReferenceEquals(previousEngine, engine))
        {
            // Switching providers: the old engine must go quiet before the new one starts.
            previousEngine.PrepareNext(null);
            previousEngine.Stop();
        }
        engine.Volume = _volumeLevel;
        ApplyAudioSettings(engine);
        State = PlaybackState.Loading;
        Notify(PlayerChange.Track);
        Notify(PlayerChange.State);

        var cts = new CancellationTokenSource();
        _loadCts = cts;
        _loadTask = RunLoad(engine, track, startAt, autoplay, token, cts.Token);
    }

    private async Task RunLoad(IPlaybackEngine engine, Track track, double startAt, bool autoplay, int token, CancellationToken ct)
    {
        // Run on a later turn, as Swift's Task does. A newer command may have replaced this load before it got to run
        // (and already stopped this engine if it switched providers); starting it now would play over the new track.
        await Task.Yield();
        if (ct.IsCancellationRequested || token != _loadToken) return;
        try
        {
            await engine.LoadAsync(track, startAt, autoplay, ct);
            if (token != _loadToken) return;
            UpdatePrepareNext();
            ExtendWithRadioIfNeeded();
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception e)
        {
            if (token != _loadToken) return;
            HandleLoadFailure(e.Message, token);
        }
    }

    private void CancelLoad()
    {
        _loadCts?.Cancel();
        _loadCts = null;
    }

    /// <summary>Skips forward after a failed track, giving up after a few in a row (or once every entry failed), so a dead
    /// network or a queue of unplayable tracks can't loop forever.</summary>
    private void HandleLoadFailure(string message, int token)
    {
        if (token != _loadToken) return;
        LastError = message;
        _consecutiveFailures++;
        var limit = Math.Min(MaxConsecutiveFailures, _queue.Count);
        if (_consecutiveFailures < limit && NextIndex(_repeatMode == RepeatMode.All) is { } next)
        {
            StartEntry(next, autoplay: LoadAutoplays);
            return;
        }
        _activeEngine?.Stop();
        _consecutiveFailures = 0;
        _needsLoad = true;
        State = PlaybackState.Failed;
        Notify(PlayerChange.State);
    }

    private void Handle(PlaybackEvent ev)
    {
        switch (ev)
        {
            case PlaybackEvent.StateChanged { State: var s }:
                // Ended is decided by the controller (repeat, autoplay, sleep timer), not the engine.
                if (s == PlaybackState.Ended || s == _state) return;
                if (s == PlaybackState.Idle && CurrentEntry is not null && !_needsLoad) return;
                State = s;
                if (s == PlaybackState.Playing)
                {
                    _consecutiveFailures = 0;
                    LoadAutoplays = true;
                }
                if (s == PlaybackState.Paused) LoadAutoplays = false;
                Notify(PlayerChange.State);
                break;
            case PlaybackEvent.Time { Current: var current, Duration: var total }:
                var delta = current - _lastTickTime;
                if (delta > 0 && delta <= 2) _listenedSeconds += delta;
                _lastTickTime = current;
                CurrentTime = current;
                if (total is { } t && CurrentEntry is { } entry)
                {
                    // A no-op once known, so rows learn it even when the entry already agrees.
                    KnownLengths.Learn(t, entry.Track.Id);
                    // The stream's length wins when it's a different cut, and the queue entry follows it.
                    if (!Nullable.Equals(ReconciledDuration(entry.Track.Duration, t), entry.Track.Duration))
                        LearnStreamDuration(t, entry.Track.Id);
                    var shown = ReconciledDuration(CurrentEntry?.Track.Duration, t);
                    if (!Nullable.Equals(shown, _duration))
                    {
                        Duration = shown;
                        Notify(PlayerChange.Timing);
                    }
                }
                RecordPlayIfNeeded();
                break;
            case PlaybackEvent.Finished:
                TrackFinished();
                break;
            case PlaybackEvent.Failed { Message: var message }:
                HandleLoadFailure(message, _loadToken);
                break;
        }
    }

    private void TrackFinished()
    {
        if (_sleepTimer.Kind == SleepTimerKind.EndOfTrack)
        {
            SleepTimer = SleepTimer.Off;
            if (NextIndex(_repeatMode == RepeatMode.All) is { } next) StartEntry(next, autoplay: false);
            else EndQueue();
            return;
        }
        if (_repeatMode == RepeatMode.One)
        {
            _listenedSeconds = 0;
            _playRecorded = false;
            _lastTickTime = 0;
            _activeEngine?.Seek(0);
            _activeEngine?.Play();
            CurrentTime = 0;
            Notify(PlayerChange.Timing);
            return;
        }
        Advance(true);
    }

    /// <summary>Skips keep the current play/pause intent: paused (or restored) stays paused, everything else plays. After
    /// the player gave up on failures, a skip tries the next track.</summary>
    private bool ShouldAutoplayOnSkip => _state != PlaybackState.Paused && !(_needsLoad && _state != PlaybackState.Failed);

    /// <summary>Make <paramref name="index"/> current. When nothing is loaded (after restore or stop) and it shouldn't play,
    /// only the cursor moves and Play loads it later.</summary>
    private void Go(int index, bool autoplay)
    {
        if (index < 0 || index >= _queue.Count) return;
        if (_needsLoad && !autoplay)
        {
            CurrentIndex = index;
            CurrentTime = 0;
            _lastTickTime = 0;
            Duration = _queue[index].Track.Duration;
            Notify(PlayerChange.Track);
            Notify(PlayerChange.Timing);
        }
        else
        {
            StartEntry(index, autoplay: autoplay);
        }
    }

    private void Advance(bool shouldPlay)
    {
        if (_currentIndex is null) return;
        if (NextIndex(_repeatMode == RepeatMode.All) is { } next) Go(next, shouldPlay);
        else if (_needsLoad) return;
        else if (_autoplay)
        {
            _pendingRadioAdvance = shouldPlay;
            RequestRadio();
        }
        else EndQueue();
    }

    private int? NextIndex(bool wrapping)
    {
        if (_currentIndex is not { } i) return _queue.Count == 0 ? null : 0;
        if (i + 1 < _queue.Count) return i + 1;
        if (wrapping && _queue.Count > 0) return 0;
        return null;
    }

    private void EndQueue()
    {
        _activeEngine?.PrepareNext(null);
        _activeEngine?.Stop();
        _loadToken++;
        State = PlaybackState.Ended;
        CurrentTime = 0;
        Notify(PlayerChange.State);
    }

    /// <summary>Tell the engine what plays after the current entry so it can resolve and buffer it early.</summary>
    private void UpdatePrepareNext()
    {
        if (_activeEngine is not { } engine || _needsLoad) return;
        Track? next = null;
        if (_repeatMode != RepeatMode.One && _sleepTimer.Kind != SleepTimerKind.EndOfTrack
            && NextIndex(_repeatMode == RepeatMode.All) is { } n && n != _currentIndex)
        {
            next = _queue[n].Track;
        }
        if (next is not null && !ReferenceEquals(Provider(next.Provider)?.PlaybackEngine, engine)) next = null;
        engine.PrepareNext(next);
    }

    private void QueueDidChange()
    {
        UpdatePrepareNext();
        Notify(PlayerChange.Queue);
    }

    private void ResetQueueState()
    {
        CancelLoad();
        _loadToken++;
        _queueGeneration++;
        CancelRadio();
        _originalRank = null;
        _consecutiveFailures = 0;
        _exhaustedRadioSeed = null;
    }

    private void Fail(string message)
    {
        LastError = message;
        Notify(PlayerChange.State);
    }

    private void Notify(PlayerChange change)
    {
        foreach (var handler in _changeHandlers.Values.ToList()) handler(change);
    }

    // MARK: Internals: audio settings

    private void ApplyAudioSettingsToAllEngines()
    {
        foreach (var p in _providers.Values) ApplyAudioSettings(p.PlaybackEngine);
    }

    private void ApplyAudioSettings(IPlaybackEngine engine)
    {
        if (engine is not IConfigurableAudioEngine e) return;
        if (e.NormalizationEnabled != _normalizationEnabled) e.NormalizationEnabled = _normalizationEnabled;
        if (!e.CrossfadeDuration.Equals(_crossfadeSeconds)) e.CrossfadeDuration = _crossfadeSeconds;
        if (e.OutputDeviceId != _outputDeviceId) e.OutputDeviceId = _outputDeviceId;
    }

    // MARK: Internals: queue editing

    private void InsertUserEntries(IReadOnlyList<Track> tracks, int index, PlaybackContext? context)
    {
        LearnCatalogDurations(tracks);
        var entries = tracks.Where(t => t.IsPlayable).Select(t => new QueueEntry(WithKnownDuration(t), isUserQueued: true, context: context)).ToList();
        if (entries.Count == 0) return;
        MutateQueue(q => q.InsertRange(Math.Clamp(index, 0, q.Count), entries));
        if (_currentIndex is { } c && index <= c) CurrentIndex = c + entries.Count;
        QueueDidChange();
    }

    private static Dictionary<Guid, int> RankMap(IReadOnlyList<QueueEntry> entries)
    {
        var map = new Dictionary<Guid, int>();
        for (var i = 0; i < entries.Count; i++) map.TryAdd(entries[i].Uid, i);
        return map;
    }

    private static List<Track> Dedupe(IReadOnlyList<Track> tracks)
    {
        var seen = new HashSet<string>();
        return tracks.Where(t => seen.Add(t.Id)).ToList();
    }

    private static void ShuffleInPlace<T>(List<T> list)
    {
        for (var i = list.Count - 1; i > 0; i--)
        {
            var j = Random.Shared.Next(i + 1);
            (list[i], list[j]) = (list[j], list[i]);
        }
    }

    private void SetShuffle(bool on)
    {
        if (on == _shuffleEnabled) return;
        SetShuffleEnabled(on);
        var start = UpNextStartIndex;
        var head = _queue.Take(start).ToList();
        var tail = _queue.Skip(start).ToList();
        var pinned = tail.TakeWhile(e => e.IsUserQueued).ToList();
        var rest = tail.Skip(pinned.Count).ToList();
        var autoEntries = rest.Where(e => e.IsAutoplay).ToList();
        var body = rest.Where(e => !e.IsAutoplay).ToList();

        if (on)
        {
            _originalRank = RankMap(_queue);
            ShuffleInPlace(body);
            ReplaceQueue([.. head, .. pinned, .. body, .. autoEntries]);
        }
        else
        {
            var rank = _originalRank ?? [];
            var position = new Dictionary<Guid, int>();
            for (var i = 0; i < body.Count; i++) position.TryAdd(body[i].Uid, i);
            // Entries from before the shuffle return to their old order; ones added since keep theirs, after them.
            var sorted = body.Order(Comparer<QueueEntry>.Create((a, b) =>
            {
                var hasA = rank.TryGetValue(a.Uid, out var ra);
                var hasB = rank.TryGetValue(b.Uid, out var rb);
                if (hasA && hasB) return ra.CompareTo(rb);
                if (hasA) return -1;
                if (hasB) return 1;
                return position.GetValueOrDefault(a.Uid).CompareTo(position.GetValueOrDefault(b.Uid));
            })).ToList();
            ReplaceQueue([.. head, .. pinned, .. sorted, .. autoEntries]);
            _originalRank = null;
        }
        QueueDidChange();
    }

    private void SetShuffleEnabled(bool on)
    {
        if (_shuffleEnabled == on) return;
        _shuffleEnabled = on;
        Raise(nameof(Shuffle));
    }

    // MARK: Internals: autoplay radio

    private void ExtendWithRadioIfNeeded()
    {
        if (!_autoplay || _repeatMode == RepeatMode.All || _currentIndex is null || _queue.Count - UpNextStartIndex >= 2) return;
        RequestRadio();
    }

    private void RequestRadio()
    {
        if (_radioTask is not null) return; // a fetch is already running; it will honor _pendingRadioAdvance
        var seed = _queue.Count > 0 ? _queue[^1].Track : null;
        if (!_autoplay || seed is null || seed.Id == _exhaustedRadioSeed
            || !_providers.TryGetValue(seed.Provider, out var provider) || !provider.Capabilities.HasFlag(ProviderCapabilities.Radio))
        {
            if (_pendingRadioAdvance is not null)
            {
                _pendingRadioAdvance = null;
                EndQueue();
            }
            return;
        }
        var generation = _queueGeneration;
        var cts = new CancellationTokenSource();
        _radioCts = cts;
        _radioTask = RunRadio(provider, seed, generation, cts.Token);
    }

    private async Task RunRadio(IMusicProvider provider, Track seed, int generation, CancellationToken ct)
    {
        await Task.Yield();
        IReadOnlyList<Track> tracks;
        try
        {
            tracks = await provider.RadioAsync(seed, ct);
        }
        catch (Exception)
        {
            tracks = [];
        }
        if (ct.IsCancellationRequested || generation != _queueGeneration) return;
        _radioTask = null;
        _radioCts = null;
        AppendRadio(tracks, seed);
    }

    private void AppendRadio(IReadOnlyList<Track> tracks, Track seed)
    {
        // Radio listings carry lengths. Learn them before dropping songs already queued, so a queued copy that arrived
        // without one (artist top songs) gets it.
        LearnCatalogDurations(tracks);
        var seen = _queue.Select(e => e.Track.Id).ToHashSet();
        var fresh = tracks.Where(t => t.IsPlayable && seen.Add(t.Id)).Take(MaxRadioBatch).ToList();
        if (fresh.Count == 0)
        {
            _exhaustedRadioSeed = seed.Id;
        }
        else
        {
            MutateQueue(q => q.AddRange(fresh.Select(t => new QueueEntry(WithKnownDuration(t), isAutoplay: true, context: PlaybackContext.Autoplay))));
            QueueDidChange();
        }
        if (_pendingRadioAdvance is { } shouldPlay)
        {
            _pendingRadioAdvance = null;
            if (_currentIndex is { } i && i + 1 < _queue.Count) StartEntry(i + 1, autoplay: shouldPlay);
            else EndQueue();
        }
    }

    private void CancelRadio()
    {
        _radioCts?.Cancel();
        _radioCts = null;
        _radioTask = null;
        _pendingRadioAdvance = null;
    }

    // MARK: Durations

    /// <summary>Within this many seconds a stream's length and the catalog's describe the same recording, rounded
    /// differently. Beyond it the stream is a different cut, and the stream's length is what the listener will hear.</summary>
    public const double DurationTolerance = 2;

    /// <summary>The length to show for a song whose listing says <paramref name="catalog"/> and whose stream says
    /// <paramref name="stream"/>: the catalog's when the two agree within <see cref="DurationTolerance"/>, otherwise the
    /// stream's. Either alone is used as is.</summary>
    public static double? ReconciledDuration(double? catalog, double? stream)
    {
        var c = catalog is { } cv && double.IsFinite(cv) && cv > 0 ? catalog : null;
        if (stream is not { } s || !double.IsFinite(s) || s <= 0) return c;
        if (c is not { } cat) return s;
        return Math.Abs(s - cat) > DurationTolerance ? s : cat;
    }

    /// <summary>Lengths learned for songs by <see cref="Track.Id"/>: from streams and from listings that came with one.
    /// Fills queue entries that arrived without a length. Session only.</summary>
    private readonly Dictionary<string, double> _knownDurations = [];
    internal const int MaxKnownDurations = 2000;

    /// <summary>Real lengths heard from streams, for album, playlist, search and queue rows. Observed per song, so learning
    /// a length never redraws rows on the time tick.</summary>
    public KnownLengths KnownLengths { get; } = new();

    /// <summary>Records the length of the stream for <paramref name="trackId"/> and updates every queued and played copy.</summary>
    internal void LearnStreamDuration(double seconds, string trackId)
    {
        if (!double.IsFinite(seconds) || seconds <= 0) return;
        Remember(seconds, trackId);
        KnownLengths.Learn(seconds, trackId);
        var changed = false;
        var queueChanged = false;
        for (var i = 0; i < _queue.Count; i++)
        {
            if (_queue[i].Track.Id != trackId) continue;
            var d = ReconciledDuration(_queue[i].Track.Duration, seconds);
            if (Nullable.Equals(d, _queue[i].Track.Duration)) continue;
            _queue[i] = _queue[i] with { Track = _queue[i].Track with { Duration = d } };
            changed = queueChanged = true;
        }
        var historyChanged = false;
        for (var i = 0; i < _recentlyPlayed.Count; i++)
        {
            if (_recentlyPlayed[i].Track.Id != trackId) continue;
            var d = ReconciledDuration(_recentlyPlayed[i].Track.Duration, seconds);
            if (Nullable.Equals(d, _recentlyPlayed[i].Track.Duration)) continue;
            _recentlyPlayed[i] = _recentlyPlayed[i] with { Track = _recentlyPlayed[i].Track with { Duration = d } };
            changed = historyChanged = true;
        }
        if (queueChanged) QueueMutated();
        if (historyChanged) RecentlyPlayedMutated();
        if (changed) Notify(PlayerChange.Queue);
        // Resolved before the item reports a length: show it now rather than jump at the first tick.
        if (CurrentEntry is { } entry && entry.Track.Id == trackId && entry.Track.Duration is { } dur
            && !Nullable.Equals(ReconciledDuration(_duration, dur), _duration))
        {
            Duration = dur;
            Notify(PlayerChange.Timing);
        }
    }

    /// <summary>Keeps the lengths a listing came with, and gives them to queued copies that have none.</summary>
    private void LearnCatalogDurations(IReadOnlyList<Track> tracks)
    {
        var learned = new Dictionary<string, double>();
        foreach (var t in tracks)
        {
            if (t.Duration is not { } d || !double.IsFinite(d) || d <= 0) continue;
            // A stream's length is better than a listing's: don't replace one.
            if (!_knownDurations.ContainsKey(t.Id))
            {
                Remember(d, t.Id);
                learned[t.Id] = d;
            }
        }
        if (learned.Count == 0) return;
        var changed = false;
        for (var i = 0; i < _queue.Count; i++)
        {
            if (_queue[i].Track.Duration is not null || !learned.TryGetValue(_queue[i].Track.Id, out var d)) continue;
            _queue[i] = _queue[i] with { Track = _queue[i].Track with { Duration = d } };
            changed = true;
        }
        if (changed)
        {
            QueueMutated();
            Notify(PlayerChange.Queue);
        }
    }

    private void Remember(double seconds, string trackId)
    {
        if (_knownDurations.Count >= MaxKnownDurations && !_knownDurations.ContainsKey(trackId)) _knownDurations.Clear();
        _knownDurations[trackId] = seconds;
    }

    /// <summary><paramref name="track"/> with the length learned for it, when its own is missing or a known stream says otherwise.</summary>
    private Track WithKnownDuration(Track track) =>
        _knownDurations.TryGetValue(track.Id, out var known) ? track with { Duration = ReconciledDuration(track.Duration, known) } : track;

    // MARK: Internals: history

    private void RecordPlayIfNeeded()
    {
        if (_playRecorded || CurrentEntry is not { } entry) return;
        var length = _duration ?? entry.Track.Duration;
        var threshold = Math.Min(30, (length ?? double.PositiveInfinity) / 2);
        if (_listenedSeconds < Math.Max(1, threshold)) return;
        _playRecorded = true;
        var played = new PlayedTrack(entry.Track, _scheduler.Now, entry.Context);
        _recentlyPlayed.RemoveAll(p => p.Track.Id == entry.Track.Id);
        _recentlyPlayed.Insert(0, played);
        if (_recentlyPlayed.Count > MaxRecentlyPlayed) _recentlyPlayed.RemoveRange(MaxRecentlyPlayed, _recentlyPlayed.Count - MaxRecentlyPlayed);
        RecentlyPlayedMutated();
        OnTrackPlayed?.Invoke(played);
        Notify(PlayerChange.Queue);
    }

    // MARK: Internals: change notification

    private int? IndexOf(Guid uid)
    {
        var i = _queue.FindIndex(e => e.Uid == uid);
        return i < 0 ? null : i;
    }

    private void ReplaceQueue(IEnumerable<QueueEntry> entries)
    {
        var list = entries.ToList();
        _queue.Clear();
        _queue.AddRange(list);
        QueueMutated();
    }

    private void MutateQueue(Action<List<QueueEntry>> change)
    {
        change(_queue);
        QueueMutated();
    }

    private void QueueMutated()
    {
        _queueView = null;
        Raise(nameof(Queue));
        RaiseCursorDerived();
    }

    private void SetRecentlyPlayed(List<PlayedTrack> list)
    {
        _recentlyPlayed = list;
        RecentlyPlayedMutated();
    }

    private void RecentlyPlayedMutated()
    {
        Raise(nameof(RecentlyPlayed));
        Raise(nameof(ListeningHistory));
    }

    private void RaiseCursorDerived()
    {
        Raise(nameof(Current));
        Raise(nameof(CurrentEntry));
        Raise(nameof(CurrentContext));
        Raise(nameof(SourceLabel));
        Raise(nameof(UpNext));
        Raise(nameof(UpNextStartIndex));
        Raise(nameof(PreviousEntries));
        Raise(nameof(ListeningHistory));
    }

    private void Raise([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    // MARK: Test support

    /// <summary>Waits for the in-flight load and radio fetch. Used by tests and probes.</summary>
    public async Task SettleAsync()
    {
        for (var n = 0; n < 10; n++)
        {
            var load = _loadTask;
            var radio = _radioTask;
            if (load is not null) await load;
            if (radio is not null) await radio;
            await Task.Yield();
            if (ReferenceEquals(load, _loadTask) && ReferenceEquals(radio, _radioTask)) return;
        }
    }
}
