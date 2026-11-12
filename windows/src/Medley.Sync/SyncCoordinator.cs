using System.ComponentModel;
using Medley.Core;
using Medley.Core.Sync;

namespace Medley.Sync;

public enum SyncPlayerState { Idle, Loading, Buffering, Playing, Paused, Ended, Failed }

/// <summary>
/// What <see cref="SyncCoordinator"/> needs from the player. The app adapts Medley.Core's PlayerController to it; the probe
/// uses a silent fake. Called on the sync actor; the adapter marshals to its own thread when it needs to.
/// </summary>
public interface ISyncPlayer
{
    IReadOnlyList<QueueEntry> Queue { get; }
    int? CurrentIndex { get; }
    QueueEntry? CurrentEntry { get; }
    SyncPlayerState State { get; }
    /// <summary>Seconds; the engine's time while playing or buffering.</summary>
    double CurrentTime { get; }
    double? Duration { get; }
    /// <summary>0…1</summary>
    double Volume { get; set; }
    bool Shuffle { get; }
    RepeatMode RepeatMode { get; }
    bool IsPlaying { get; }
    string? LastError { get; }
    /// <summary>Whether a track of this service can play here (signed in and available).</summary>
    bool CanPlay(ProviderId provider);
    void Load(IReadOnlyList<QueueEntry> queue, int index, double position, bool shuffle, RepeatMode repeatMode, bool autoplay);
    void Resume();
    void Pause();
    void TogglePlayPause();
    void Next();
    void Previous();
    void Stop();
    void Seek(double seconds);
    /// <summary>Raised whenever anything above changes.</summary>
    event Action? Changed;
}

public abstract record HandoffPhase
{
    public sealed record Idle : HandoffPhase;
    public sealed record Pulling(DeviceId From) : HandoffPhase;
    public sealed record Pushing(DeviceId To) : HandoffPhase;
    public static readonly HandoffPhase IdlePhase = new Idle();
}

/// <summary>"Continue from &lt;device&gt;": the most recently active other device that is playing, or paused under 30 minutes ago.</summary>
public sealed record ContinueSuggestion(SyncDevice Device, RemotePlayback Playback, bool IsPlaying);

public enum HandoffKind { Pull, Push }

/// <summary>Timings of the last handoff, for diagnostics and the probe.</summary>
public sealed record HandoffReport(HandoffKind Kind, DeviceId Device, double FetchMs, double ReadyMs, double TotalMs, double? PositionDeltaMs, CommandResult? SourcePaused);

/// <summary>
/// Bridges a player and the sync service (port of <c>SyncCoordinator.swift</c>): publishes local playback when it changes
/// (debounced 300 ms) and every 20 s while playing; runs incoming commands against the player and acks them;
/// <see cref="PlayHereAsync"/> pulls another device's playback here, <see cref="SendToAsync"/> pushes this device's playback
/// there, <see cref="Remote"/> controls another device.
/// <para>
/// Every public method dispatches to the actor first. A handoff, a publish and an incoming command capture the service's
/// <see cref="SyncIdentity"/> before their first await and check it before each effect (loading the player, pausing the
/// source, sending, recording a result): one that started for one account never acts for the next
/// (<see cref="SyncErrorKind.AuthChanged"/>).
/// </para>
/// </summary>
public sealed class SyncCoordinator : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    public ISyncServicing Service { get; }
    public ISyncPlayer Player { get; }
    private readonly SyncActor _actor;

    private HandoffPhase _phase = HandoffPhase.IdlePhase;
    private SyncException? _lastError;
    private HandoffReport? _lastHandoff;
    public HandoffPhase Phase { get => _phase; private set { _phase = value; Raise(nameof(Phase)); } }
    public SyncException? LastError { get => _lastError; private set { _lastError = value; Raise(nameof(LastError)); } }
    public HandoffReport? LastHandoff { get => _lastHandoff; private set { _lastHandoff = value; Raise(nameof(LastHandoff)); } }

    /// <summary>Called just before a remote command acts on the player (not volume): the app counts it as a transport choice.</summary>
    public Action? WillRunTransportCommand { get; set; }
    /// <summary>Called just before a handoff replaces the player's queue: the app makes it a new playback choice.</summary>
    public Action? WillReplaceQueue { get; set; }

    private bool _attached;
    private CancellationTokenSource? _debounce, _refresh;
    private (Guid[] Uids, int Index, int KeyGeneration)? _lastQueueSignature;
    /// <summary>Counts changes of the key this device seals with. Part of the queue signature, so a publish in flight when
    /// the key changed can't mark the queue as published under the new key.</summary>
    private int _contentKeyGeneration;
    private bool _hasPublished;
    private DeviceId? _publishedAs;
    private bool _publishing, _publishAgain;
    /// <summary>The suggestion the listener closed: that device, on that track (null while its track is sealed from here).</summary>
    private (DeviceId Device, string? Track)? _dismissed;

    public static readonly TimeSpan DebounceDelay = TimeSpan.FromMilliseconds(300);
    public static readonly TimeSpan RefreshInterval = TimeSpan.FromSeconds(20);

    public SyncCoordinator(ISyncServicing service, ISyncPlayer player, SyncActor actor)
    {
        Service = service;
        Player = player;
        _actor = actor;
        // The suggestion depends on other devices' playback and on the local player: say so when either changes.
        Service.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is not (null or nameof(ISyncServicing.Playback) or nameof(ISyncServicing.Devices))) return;
            // The playback as of this change (an immutable snapshot), so X→Y→X is seen as three changes, in order.
            var shown = Service.Playback;
            _actor.Post(() => PlaybackChanged(shown));
        };
        Player.Changed += () => _actor.Post(() => Raise(nameof(ContinueSuggestion)));
    }

    /// <summary>Another device's playback changed: a dismissal ends once that device shows another track or none.</summary>
    private void PlaybackChanged(IReadOnlyDictionary<DeviceId, RemotePlayback> shown)
    {
        if (_dismissed is { } d && (!shown.TryGetValue(d.Device, out var row) || row.Track?.Id != d.Track)) _dismissed = null;
        Raise(nameof(ContinueSuggestion));
    }

    private void Raise(string name)
    {
        _actor.AssertCurrent(name);
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    /// <summary>Throws AuthChanged when the account moved on since <paramref name="identity"/> was captured.</summary>
    private void Check(SyncIdentity identity)
    {
        _actor.AssertCurrent();
        if (!Service.IsCurrent(identity)) throw SyncException.AuthChanged;
    }

    // MARK: Attach

    /// <summary>Starts publishing and obeying commands.</summary>
    public async Task AttachAsync()
    {
        await _actor.Switch();
        if (_attached) return;
        _attached = true;
        Player.Changed += OnPlayerChanged;
        Service.CommandHandler = Execute;
        Service.ContentKeyChanged += OnContentKeyChanged;
        SchedulePublish(TimeSpan.Zero);
    }

    /// <summary>The key this device seals with changed (it got the key, a rotation, it lost it): publish the queue again,
    /// sealed under the new key or as no content, so others never keep reading it under a retired key.</summary>
    private void OnContentKeyChanged() => _actor.Post(() =>
    {
        if (!_attached) return;
        _contentKeyGeneration++;
        _lastQueueSignature = null;
        SchedulePublish(TimeSpan.Zero);
    });

    public async Task DetachAsync()
    {
        await _actor.Switch();
        if (!_attached) return;
        _attached = false;
        Player.Changed -= OnPlayerChanged;
        Service.CommandHandler = null;
        Service.ContentKeyChanged -= OnContentKeyChanged;
        _debounce?.Cancel();
        _refresh?.Cancel();
    }

    private void OnPlayerChanged() => _actor.Post(() =>
    {
        if (!_attached) return;
        Service.SetPlaying(Player.IsPlaying);
        SchedulePublish(DebounceDelay);
    });

    // MARK: Publishing

    private void SchedulePublish(TimeSpan delay)
    {
        _debounce?.Cancel();
        _debounce = Schedule(delay, () => _ = PublishNowAsync());
    }

    private CancellationTokenSource Schedule(TimeSpan delay, Action action)
    {
        var cts = new CancellationTokenSource();
        _ = Task.Delay(delay, cts.Token).ContinueWith(t =>
        {
            if (!t.IsCanceled) _actor.Post(() => { if (!cts.IsCancellationRequested) action(); });
        }, TaskScheduler.Default);
        return cts;
    }

    /// <summary>The local anchor now.</summary>
    public PlaybackAnchor CurrentAnchor() => _actor.Read(AnchorNow);

    private PlaybackAnchor AnchorNow() => new()
    {
        PositionMs = Player.CurrentTime * 1000,
        PositionAt = Service.Clock.Now(),
        IsPlaying = Player.State == SyncPlayerState.Playing,
        Rate = 1,
        DurationMs = Player.Duration is { } d ? d * 1000 : null,
        Volume = Player.Volume,
        Shuffle = Player.Shuffle,
        Repeat = Player.RepeatMode,
    };

    /// <summary>Publishes now (the debounce and the 20 s refresh call this). Sends the queue window only when it changed.</summary>
    public async Task PublishNowAsync()
    {
        await _actor.Switch();
        if (Service.SelfId is null) return;
        if (_publishing) { _publishAgain = true; return; }
        _publishing = true;
        try
        {
            var playing = false;
            do
            {
                _publishAgain = false;
                // Each round is for the account and device current as it starts; what it learns counts only for them.
                if (Service.SelfId is not { } me) break;
                var identity = Service.Identity;
                if (_publishedAs != me)
                {
                    _publishedAs = me;
                    _lastQueueSignature = null;
                    _hasPublished = false;
                }
                if (QueueWindow.Around(Player.Queue, Player.CurrentIndex) is not { } window)
                {
                    if (_hasPublished)
                    {
                        try
                        {
                            await Service.ClearPlaybackAsync();
                            if (Service.IsCurrent(identity)) { _hasPublished = false; _lastQueueSignature = null; }
                        }
                        catch (Exception e) { if (Service.IsCurrent(identity)) LastError = SyncException.From(e); }
                    }
                    playing = false;
                    if (!Service.IsCurrent(identity)) RestartForNewIdentity();
                    continue;
                }
                var signature = (Uids: window.Entries.Select(e => e.Uid).ToArray(), Index: window.Index, KeyGeneration: _contentKeyGeneration);
                var includeQueue = _lastQueueSignature is not { } last || !last.Uids.SequenceEqual(signature.Uids) || last.Index != signature.Index
                                   || last.KeyGeneration != signature.KeyGeneration;
                var anchor = AnchorNow();
                playing = anchor.IsPlaying;
                try
                {
                    await Service.PublishAsync(anchor, includeQueue ? window : null);
                    if (Service.IsCurrent(identity))
                    {
                        _lastQueueSignature = signature;
                        _hasPublished = true;
                    }
                }
                catch (Exception e)
                {
                    if (Service.IsCurrent(identity)) LastError = SyncException.From(e);
                    _lastQueueSignature = null;
                }
                if (!Service.IsCurrent(identity)) RestartForNewIdentity();
            } while (_publishAgain);
            _refresh?.Cancel();
            _refresh = null;
            if (playing) _refresh = Schedule(RefreshInterval, () => _ = PublishNowAsync());
        }
        finally { _publishing = false; }

        // The account changed during this round: nothing it learned counts, and the next account gets a full publish.
        void RestartForNewIdentity()
        {
            _publishedAs = null;
            _lastQueueSignature = null;
            _hasPublished = false;
            _publishAgain = Service.SelfId is not null;
        }
    }

    // MARK: Incoming commands

    internal async Task<CommandResult> Execute(IncomingCommand incoming)
    {
        await _actor.Switch();
        var identity = Service.Identity;
        try
        {
            var transport = WillRunTransportCommand ?? (() => { });
            var command = incoming.Command;
            switch (command.Kind)
            {
                case SyncCommandKind.Play:
                    if (Player.CurrentEntry is null && Player.Queue.Count == 0) return CommandResult.Failure(CommandFailure.NothingToPlay);
                    transport();
                    Player.Resume();
                    break;
                case SyncCommandKind.Pause: transport(); Player.Pause(); break;
                case SyncCommandKind.Toggle: transport(); Player.TogglePlayPause(); break;
                case SyncCommandKind.Next: transport(); Player.Next(); break;
                case SyncCommandKind.Previous: transport(); Player.Previous(); break;
                case SyncCommandKind.Stop: transport(); Player.Stop(); break;
                case SyncCommandKind.Seek: transport(); Player.Seek(Math.Max(0, (command.PositionMs ?? 0) / 1000)); break;
                case SyncCommandKind.SetVolume: Player.Volume = Math.Clamp(command.Volume ?? 0, 0, 1); break;
                case SyncCommandKind.TakeOver:
                    transport();
                    try
                    {
                        // Name this device in the message: the sender shows it.
                        await Adopt(command.State!, Service.Devices.FirstOrDefault(d => d.Id == Service.SelfId)?.Name, identity);
                    }
                    catch (Exception e)
                    {
                        var failure = SyncException.From(e);
                        LastError = failure;
                        // The message may name the song: the service sends it sealed, and the reason in the clear.
                        return CommandResult.Failure(ReasonFor(failure), failure.Message);
                    }
                    break;
            }
            return CommandResult.Success;
        }
        finally { SchedulePublish(TimeSpan.Zero); }
    }

    internal static CommandFailure ReasonFor(SyncException error) => error.Kind switch
    {
        SyncErrorKind.ProviderUnavailable => CommandFailure.ProviderUnavailable,
        SyncErrorKind.PlaybackFailed => CommandFailure.PlaybackFailed,
        SyncErrorKind.NeedsKey => CommandFailure.NeedsKey,
        SyncErrorKind.NothingPlaying => CommandFailure.NothingToPlay,
        _ => CommandFailure.Failed,
    };

    // MARK: Handoff

    /// <summary>Loads <paramref name="state"/> here and starts playing at its live position. Returns (cued, playing) times.</summary>
    private async Task<(DateTimeOffset Ready, DateTimeOffset Playing)> Adopt(HandoffState state, string? deviceName, SyncIdentity identity)
    {
        Check(identity);
        if (state.Index < 0 || state.Index >= state.Queue.Count) throw SyncException.PlaybackFailed("the queue is empty");
        var target = state.Queue[state.Index];
        if (!Player.CanPlay(target.Track.Provider)) throw SyncException.ProviderUnavailable(target.Track.Provider, deviceName);
        var cueAt = state.Anchor.Position(Service.Clock.Now());
        WillReplaceQueue?.Invoke();
        Player.Load(state.Queue, state.Index, cueAt, state.Anchor.Shuffle, state.Anchor.Repeat, autoplay: false);
        bool IsTarget() => Player.CurrentEntry?.Uid == target.Uid;
        var cued = await WaitForPlayer(TimeSpan.FromSeconds(20), () => Player.State != SyncPlayerState.Loading || !IsTarget());
        Check(identity);
        if (!cued || Player.State == SyncPlayerState.Failed) throw SyncException.PlaybackFailed(Player.LastError ?? "the track didn't load in time");
        if (!IsTarget()) throw WrongTrack(target, deviceName);
        var ready = DateTimeOffset.UtcNow;
        // Stream resolution took time; catch up to where the source is now.
        Player.Seek(state.Anchor.Position(Service.Clock.Now()));
        Player.Resume();
        if (!await WaitForPlayer(TimeSpan.FromSeconds(15), () => Player.State == SyncPlayerState.Playing || !IsTarget()))
            throw SyncException.PlaybackFailed(Player.LastError ?? "playback didn't start");
        Check(identity);
        if (!IsTarget()) throw WrongTrack(target, deviceName);
        return (ready, DateTimeOffset.UtcNow);
    }

    private SyncException WrongTrack(QueueEntry target, string? deviceName)
    {
        WillRunTransportCommand?.Invoke();
        Player.Pause();
        var place = deviceName is null ? "here" : $"on {deviceName}";
        var why = Player.LastError is { } e ? $" ({e})" : "";
        return SyncException.PlaybackFailed($"\"{target.Track.Title}\" couldn't be loaded {place}{why}.");
    }

    /// <summary>Pull handoff: continues <paramref name="source"/>'s queue here at its live position, then pauses it there.</summary>
    public async Task PlayHereAsync(DeviceId source)
    {
        await _actor.Switch();
        if (Phase is not HandoffPhase.Idle) return;
        if (Service.Devices.FirstOrDefault(d => d.Id == source) is not { } device) throw Fail(SyncException.UnknownDevice);
        Phase = new HandoffPhase.Pulling(source);
        var start = DateTimeOffset.UtcNow;
        var identity = Service.Identity;
        try
        {
            if (!Service.Playback.ContainsKey(source)) throw SyncException.NothingPlaying(device.Name);
            // What plays there is sealed with the account's key: without it this device can't know what to play.
            if (!Service.CanSealContent) throw SyncException.NeedsKey(null);
            var window = await Service.FetchQueueAsync(source);
            Check(identity);
            // The live row can move on while the queue loads; refetch once if they disagree.
            if (window is not null && Service.Playback.TryGetValue(source, out var moved) && moved.Track?.Id != window.Current.Track.Id)
            {
                window = await Service.FetchQueueAsync(source);
                Check(identity);
            }
            if (window is null || !Service.Playback.TryGetValue(source, out var row)) throw SyncException.NothingPlaying(device.Name);
            var fetched = DateTimeOffset.UtcNow;
            var provider = window.Current.Track.Provider;
            if (!Player.CanPlay(provider)) throw SyncException.ProviderUnavailable(provider, null);
            var times = await Adopt(new HandoffState { Queue = window.Entries, Index = window.Index, Anchor = EffectiveAnchor(row) }, null, identity);
            Check(identity);
            var local = AnchorNow().Position(Service.Clock.Now());
            var sourceNow = EffectiveAnchor(Service.Playback.GetValueOrDefault(source) ?? row).Position(Service.Clock.Now());
            var report = new HandoffReport(HandoffKind.Pull, source, Ms(fetched, start), Ms(times.Ready, start), Ms(times.Playing, start), (local - sourceNow) * 1000, null);
            LastHandoff = report;
            LastError = null;
            var pause = await Service.SendAsync(SyncCommand.Pause, source);
            _ = WatchPauseAck(pause, report);
        }
        catch (Exception e) { throw Fail(SyncException.From(e)); }
        finally { Phase = HandoffPhase.IdlePhase; }
    }

    private async Task WatchPauseAck(CommandId pause, HandoffReport report)
    {
        CommandResult result;
        try { result = await Service.WaitForAckAsync(pause, TimeSpan.FromSeconds(20)); }
        catch (Exception) { result = CommandResult.Failure(CommandFailure.Failed, "no ack"); }
        await _actor.Switch();
        if (LastHandoff != report) return;
        LastHandoff = report with { SourcePaused = result };
    }

    /// <summary>Push handoff: sends this device's playback to <paramref name="target"/> and pauses here once it plays there.</summary>
    public async Task SendToAsync(DeviceId target)
    {
        await _actor.Switch();
        if (Phase is not HandoffPhase.Idle) return;
        if (Service.Devices.FirstOrDefault(d => d.Id == target) is not { } device) throw Fail(SyncException.UnknownDevice);
        if (!device.IsOnline(Service.Clock.Now())) throw Fail(SyncException.DeviceOffline(device.Name));
        if (QueueWindow.Around(Player.Queue, Player.CurrentIndex) is not { } window) throw Fail(SyncException.NothingPlaying("this device"));
        // The queue goes sealed with the account's key: both devices need it.
        if (!Service.CanSealContent) throw Fail(SyncException.NeedsKey(null));
        if (device.KeyState is not (null or KeyStateKind.Holder)) throw Fail(SyncException.NeedsKey(device.Name));
        Phase = new HandoffPhase.Pushing(target);
        var start = DateTimeOffset.UtcNow;
        var identity = Service.Identity;
        try
        {
            var command = await Service.SendAsync(SyncCommand.TakeOver(new HandoffState { Queue = window.Entries, Index = window.Index, Anchor = AnchorNow() }), target);
            Check(identity);
            var sent = DateTimeOffset.UtcNow;
            var result = await Service.WaitForAckAsync(command, TimeSpan.FromSeconds(30));
            Check(identity);
            var acked = DateTimeOffset.UtcNow;
            if (!result.Ok) throw SyncException.CommandFailed(result.Message ?? $"{device.Name} couldn't take over.");
            WillRunTransportCommand?.Invoke();
            Player.Pause();
            LastHandoff = new HandoffReport(HandoffKind.Push, target, Ms(sent, start), Ms(acked, start), Ms(DateTimeOffset.UtcNow, start), null, null);
            LastError = null;
        }
        catch (Exception e) { throw Fail(SyncException.From(e)); }
        finally { Phase = HandoffPhase.IdlePhase; }
    }

    // MARK: Remote control

    /// <summary>Controls another device: play, pause, toggle, next, previous, seek, volume, stop.</summary>
    public RemoteControl Remote(DeviceId device) => new(this, device);

    internal async Task<CommandId> SendRemote(SyncCommand command, DeviceId device)
    {
        await _actor.Switch();
        if (command.Kind == SyncCommandKind.TakeOver) throw Fail(SyncException.CommandFailed("Use SendToAsync to move playback."));
        if (!Service.Devices.Any(d => d.Id == device)) throw Fail(SyncException.UnknownDevice);
        var identity = Service.Identity;
        try
        {
            var id = await Service.SendAsync(command, device);
            Check(identity);
            return id;
        }
        catch (Exception e) { throw Fail(SyncException.From(e)); }
    }

    // MARK: Continue suggestion

    public ContinueSuggestion? ContinueSuggestion => _actor.Read(SuggestionNow);

    private ContinueSuggestion? SuggestionNow()
    {
        _actor.AssertCurrent();
        if (Service.SelfId is not { } me || Player.IsPlaying) return null;
        var now = Service.Clock.Now();
        var devices = Service.Devices.GroupBy(d => d.Id).ToDictionary(g => g.Key, g => g.First());
        return Service.Playback.Values
            .Where(row => row.DeviceId != me && devices.ContainsKey(row.DeviceId))
            .Where(row => _dismissed is not { } d || d.Device != row.DeviceId || d.Track != row.Track?.Id)
            .Select(row =>
            {
                var device = devices[row.DeviceId];
                var playing = row.Anchor.IsPlaying && device.IsOnline(now);
                return playing || now - row.UpdatedAt < SyncLimits.ContinueWindow.TotalMilliseconds ? new ContinueSuggestion(device, row, playing) : null;
            })
            .OfType<ContinueSuggestion>()
            .OrderByDescending(s => s.IsPlaying ? 1 : 0).ThenByDescending(s => s.Playback.UpdatedAt)
            .FirstOrDefault();
    }

    /// <summary>Hides the current suggestion until that device plays another track.</summary>
    public void DismissSuggestion() => _actor.Perform(DismissNow);

    private void DismissNow()
    {
        if (SuggestionNow() is not { } s) return;
        _dismissed = (s.Device.Id, s.Playback.Track?.Id);
        Raise(nameof(ContinueSuggestion));
    }

    /// <summary>Live position (seconds) of another device.</summary>
    public double? LivePosition(DeviceId device) => _actor.Read(() =>
        Service.Playback.TryGetValue(device, out var row) ? EffectiveAnchorNow(row).Position(Service.Clock.Now()) : (double?)null);

    /// <summary>A row's anchor, except that a device that went offline while playing is taken as paused where it was last seen.</summary>
    public PlaybackAnchor EffectiveAnchor(RemotePlayback row) => _actor.Read(() => EffectiveAnchorNow(row));

    private PlaybackAnchor EffectiveAnchorNow(RemotePlayback row)
    {
        var now = Service.Clock.Now();
        if (!row.Anchor.IsPlaying || Service.Devices.FirstOrDefault(d => d.Id == row.DeviceId) is not { } device || device.IsOnline(now)) return row.Anchor;
        var lastSeen = Math.Max(device.LastSeenAt, row.UpdatedAt);
        return row.Anchor with { PositionMs = row.Anchor.Position(lastSeen) * 1000, PositionAt = lastSeen, IsPlaying = false };
    }

    // MARK: Helpers

    private SyncException Fail(SyncException error)
    {
        LastError = error;
        return error;
    }

    private static double Ms(DateTimeOffset a, DateTimeOffset b) => Math.Round((a - b).TotalMilliseconds);

    private async Task<bool> WaitForPlayer(TimeSpan timeout, Func<bool> condition)
    {
        await _actor.Switch();
        if (condition()) return true;
        var tcs = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        void Handler() => _actor.Post(() => { if (condition()) tcs.TrySetResult(true); });
        Player.Changed += Handler;
        try
        {
            var done = await Task.WhenAny(tcs.Task, Task.Delay(timeout));
            await _actor.Switch();
            return done == tcs.Task || condition();
        }
        finally { Player.Changed -= Handler; }
    }
}

/// <summary>Controls one other device. Each call sends a command and returns its id; WaitForAckAsync waits for it.</summary>
public readonly struct RemoteControl(SyncCoordinator coordinator, DeviceId device)
{
    public DeviceId Device => device;
    public Task<CommandId> Play() => coordinator.SendRemote(SyncCommand.Play, device);
    public Task<CommandId> Pause() => coordinator.SendRemote(SyncCommand.Pause, device);
    public Task<CommandId> Toggle() => coordinator.SendRemote(SyncCommand.Toggle, device);
    public Task<CommandId> Next() => coordinator.SendRemote(SyncCommand.Next, device);
    public Task<CommandId> Previous() => coordinator.SendRemote(SyncCommand.Previous, device);
    public Task<CommandId> Stop() => coordinator.SendRemote(SyncCommand.Stop, device);
    public Task<CommandId> Seek(double seconds) => coordinator.SendRemote(SyncCommand.Seek(Math.Max(0, seconds) * 1000), device);
    /// <summary>0…1</summary>
    public Task<CommandId> SetVolume(double volume) => coordinator.SendRemote(SyncCommand.SetVolumeTo(Math.Clamp(volume, 0, 1)), device);
}
