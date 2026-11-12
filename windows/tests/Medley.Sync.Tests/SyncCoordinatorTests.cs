using Medley.Core;
using Medley.Core.Sync;
using static Medley.Sync.Tests.TestUtil;

namespace Medley.Sync.Tests;

public sealed class FakePlayer : ISyncPlayer
{
    public List<QueueEntry> Entries = new();
    public IReadOnlyList<QueueEntry> Queue => Entries;
    public int? CurrentIndex { get; set; }
    public QueueEntry? CurrentEntry => CurrentIndex is { } i && i < Entries.Count ? Entries[i] : null;
    public SyncPlayerState State { get; set; } = SyncPlayerState.Idle;
    public double CurrentTime { get; set; }
    public double? Duration { get; set; } = 200;
    public double Volume { get; set; } = 1;
    public bool Shuffle { get; set; }
    public RepeatMode RepeatMode { get; set; }
    public bool IsPlaying => State is SyncPlayerState.Playing or SyncPlayerState.Buffering;
    public string? LastError { get; set; }
    public HashSet<ProviderId> Playable { get; } = [ProviderId.YouTubeMusic, ProviderId.Spotify];
    public List<string> Calls { get; } = new();
    public event Action? Changed;
    public bool CanPlay(ProviderId provider) => Playable.Contains(provider);
    public void Load(IReadOnlyList<QueueEntry> queue, int index, double position, bool shuffle, RepeatMode repeatMode, bool autoplay)
    {
        Calls.Add($"load {index} {position:F0}");
        Entries = queue.ToList();
        CurrentIndex = index;
        CurrentTime = position;
        State = SyncPlayerState.Paused;
        Changed?.Invoke();
    }
    public void Resume() { Calls.Add("resume"); State = SyncPlayerState.Playing; Changed?.Invoke(); }
    public void Pause() { Calls.Add("pause"); State = SyncPlayerState.Paused; Changed?.Invoke(); }
    public void TogglePlayPause() { if (IsPlaying) Pause(); else Resume(); }
    public void Next() { Calls.Add("next"); CurrentIndex++; Changed?.Invoke(); }
    public void Previous() { Calls.Add("previous"); CurrentIndex--; Changed?.Invoke(); }
    public void Stop() { Calls.Add("stop"); State = SyncPlayerState.Idle; Changed?.Invoke(); }
    public void Seek(double seconds) { Calls.Add($"seek {seconds:F0}"); CurrentTime = seconds; Changed?.Invoke(); }
}

public sealed class FakeHub : ISyncServicing
{
    public event System.ComponentModel.PropertyChangedEventHandler? PropertyChanged;
    private IReadOnlyDictionary<DeviceId, RemotePlayback> _playback = new Dictionary<DeviceId, RemotePlayback>();
    public DeviceId? SelfId { get; set; } = new DeviceId("here");
    public IReadOnlyList<SyncDevice> Devices { get; set; } = [];
    public IReadOnlyDictionary<DeviceId, RemotePlayback> Playback
    {
        get => _playback;
        set { _playback = value; PropertyChanged?.Invoke(this, new(nameof(Playback))); }
    }
    public ServerClock Clock { get; } = new();
    public Func<IncomingCommand, Task<CommandResult>>? CommandHandler { get; set; }
    /// <summary>Bump to make work started before it stale (another account).</summary>
    public int Session;
    public SyncIdentity Identity => new(0, Volatile.Read(ref Session));
    public bool IsCurrent(SyncIdentity identity) => identity == Identity;
    public List<(PlaybackAnchor Anchor, QueueWindow? Queue)> Published { get; } = new();
    public List<(SyncCommand Command, DeviceId To)> Sent { get; } = new();
    public Dictionary<DeviceId, QueueWindow> Queues { get; } = new();
    public Func<SyncCommand, DeviceId, CommandResult> Answer { get; set; } = (_, _) => CommandResult.Success;
    public int Clears;

    /// <summary>Holds a publish in flight until the returned task completes (a test can change the key meanwhile).</summary>
    public Func<Task>? PublishGate { get; set; }
    public async Task PublishAsync(PlaybackAnchor anchor, QueueWindow? queue)
    {
        if (PublishGate is { } gate) await gate();
        lock (Published) Published.Add((anchor, queue));
    }
    public Task ClearPlaybackAsync() { Clears++; return Task.CompletedTask; }
    public Action? WillFetchQueue { get; set; }
    public Task<QueueWindow?> FetchQueueAsync(DeviceId device) { WillFetchQueue?.Invoke(); return Task.FromResult(Queues.GetValueOrDefault(device)); }
    public Task<CommandId> SendAsync(SyncCommand command, DeviceId device) { Sent.Add((command, device)); return Task.FromResult(new CommandId($"c{Sent.Count}")); }
    public Task<CommandResult> WaitForAckAsync(CommandId command, TimeSpan timeout) => Task.FromResult(Answer(Sent[int.Parse(command.Value[1..]) - 1].Command, Sent[int.Parse(command.Value[1..]) - 1].To));
    public void SetPlaying(bool playing) { }
    /// <summary>Every fake hub holds the key unless a test takes it away.</summary>
    public bool CanSealContent { get; set; } = true;
    public event Action? ContentKeyChanged;
    public void RaiseContentKeyChanged() => ContentKeyChanged?.Invoke();
}

public class SyncCoordinatorTests
{
    private static List<QueueEntry> Tracks(int n) => Enumerable.Range(0, n)
        .Select(i => new QueueEntry(new Track { ProviderID = $"t{i}", Provider = ProviderId.YouTubeMusic, Title = $"Song {i}", Duration = 200 })).ToList();

    private static SyncDevice Other(string id, double lastSeen) => new() { Id = new DeviceId(id), Name = id, Platform = DevicePlatform.Mac, Model = "m", AppVersion = "1", LastSeenAt = lastSeen };

    [Fact]
    public async Task PublishesTheQueueOnlyWhenItChangesAndRunsCommands()
    {
        var actor = SyncActor.CreateDedicated("coordinator");
        var hub = new FakeHub();
        var player = new FakePlayer { Entries = Tracks(3), CurrentIndex = 0, State = SyncPlayerState.Playing };
        var coordinator = new SyncCoordinator(hub, player, actor);
        await coordinator.AttachAsync();
        Assert.True(await Eventually(() => { lock (hub.Published) return hub.Published.Count == 1; }));
        Assert.NotNull(hub.Published[0].Queue);
        await actor.Run(() => player.Seek(30));
        Assert.True(await Eventually(() => { lock (hub.Published) return hub.Published.Count == 2; }));
        Assert.Null(hub.Published[1].Queue);   // anchor only
        Assert.Equal(30_000, hub.Published[1].Anchor.PositionMs, 0);

        var result = await hub.CommandHandler!(new IncomingCommand { Id = new CommandId("x"), FromDeviceId = new DeviceId("mac"), Command = SyncCommand.Next, ExpiresAt = double.MaxValue });
        Assert.True(result.Ok);
        Assert.Equal(1, player.CurrentIndex);
        Assert.True(await Eventually(() => { lock (hub.Published) return hub.Published[^1].Queue?.Index == 1; }));
        await hub.CommandHandler!(new IncomingCommand { Id = new CommandId("y"), FromDeviceId = new DeviceId("mac"), Command = SyncCommand.SetVolumeTo(0.3), ExpiresAt = double.MaxValue });
        Assert.Equal(0.3, player.Volume, 3);
        await coordinator.DetachAsync();
    }

    [Fact]
    public async Task APullHandoffContinuesAtTheLivePositionAndPausesTheSource()
    {
        var actor = SyncActor.CreateDedicated("coordinator");
        var hub = new FakeHub();
        var now = hub.Clock.Now();
        var queue = Tracks(4);
        hub.Devices = [Other("here", now), Other("mac", now)];
        hub.Playback = new Dictionary<DeviceId, RemotePlayback>
        {
            [new DeviceId("mac")] = new() { DeviceId = new DeviceId("mac"), Track = queue[1].Track, Index = 1, Anchor = new PlaybackAnchor { PositionMs = 40_000, PositionAt = now - 2_000, IsPlaying = true, Rate = 1, Volume = 1 }, UpdatedAt = now },
        };
        hub.Queues[new DeviceId("mac")] = new QueueWindow { Entries = queue, Index = 1 };
        var player = new FakePlayer();
        var coordinator = new SyncCoordinator(hub, player, actor);
        await coordinator.PlayHereAsync(new DeviceId("mac"));
        Assert.Equal(1, player.CurrentIndex);
        Assert.Equal(SyncPlayerState.Playing, player.State);
        Assert.InRange(player.CurrentTime, 41.5, 43);   // 40 s + the 2 s since the anchor
        Assert.Equal((SyncCommand.Pause, new DeviceId("mac")), hub.Sent[0]);
        Assert.Equal(HandoffKind.Pull, coordinator.LastHandoff!.Kind);
    }

    [Fact]
    public async Task APushHandoffSendsTheQueueAndPausesHereOnceItPlaysThere()
    {
        var actor = SyncActor.CreateDedicated("coordinator");
        var hub = new FakeHub();
        hub.Devices = [Other("here", hub.Clock.Now()), Other("phone", hub.Clock.Now())];
        var player = new FakePlayer { Entries = Tracks(5), CurrentIndex = 2, State = SyncPlayerState.Playing, CurrentTime = 12 };
        var coordinator = new SyncCoordinator(hub, player, actor);
        await coordinator.SendToAsync(new DeviceId("phone"));
        var (command, to) = hub.Sent[0];
        Assert.Equal(SyncCommandKind.TakeOver, command.Kind);
        Assert.Equal(new DeviceId("phone"), to);
        Assert.Equal(2, command.State!.Index);
        Assert.Equal(5, command.State.Queue.Count);
        Assert.Equal(SyncPlayerState.Paused, player.State);

        // A refused takeover keeps playing here and says why.
        hub.Answer = (_, _) => new CommandResult(false, "Spotify isn't signed in on phone.");
        player.Resume();
        var e = await Assert.ThrowsAsync<SyncException>(() => coordinator.SendToAsync(new DeviceId("phone")));
        Assert.Contains("Spotify", e.Message);
        Assert.Equal(SyncPlayerState.Playing, player.State);
        // An offline device isn't offered.
        hub.Devices = [Other("here", hub.Clock.Now()), Other("phone", hub.Clock.Now() - 200_000)];
        Assert.Equal(SyncErrorKind.DeviceOffline, (await Assert.ThrowsAsync<SyncException>(() => coordinator.SendToAsync(new DeviceId("phone")))).Kind);
    }

    /// <summary>Review finding: the suggestion never told bindings it changed, and X→Y→X between reads stayed dismissed.</summary>
    [Fact]
    public async Task TheContinueSuggestionAnnouncesItsChangesAndADismissalEndsWithTheTrack()
    {
        var actor = SyncActor.CreateDedicated("coordinator");
        var hub = new FakeHub();
        var now = hub.Clock.Now();
        hub.Devices = [Other("here", now), Other("mac", now)];
        var coordinator = new SyncCoordinator(hub, new FakePlayer(), actor);
        var raised = 0;
        coordinator.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(SyncCoordinator.ContinueSuggestion)) Interlocked.Increment(ref raised); };
        var tracks = Tracks(2);
        RemotePlayback Row(int track) => new() { DeviceId = new DeviceId("mac"), Track = tracks[track].Track, Anchor = new PlaybackAnchor { PositionMs = 0, PositionAt = now, IsPlaying = true, Rate = 1, Volume = 1 }, UpdatedAt = now };
        hub.Playback = new Dictionary<DeviceId, RemotePlayback> { [new DeviceId("mac")] = Row(0) };
        Assert.True(await Eventually(() => Volatile.Read(ref raised) >= 1));
        Assert.Equal("Song 0", (await actor.Run(() => coordinator.ContinueSuggestion))?.Playback.Track?.Title);
        var before = Volatile.Read(ref raised);
        await actor.Run(coordinator.DismissSuggestion);
        Assert.True(Volatile.Read(ref raised) > before);
        Assert.Null(await actor.Run(() => coordinator.ContinueSuggestion));
        // Another track and back again, with nobody reading in between: offered again.
        hub.Playback = new Dictionary<DeviceId, RemotePlayback> { [new DeviceId("mac")] = Row(1) };
        hub.Playback = new Dictionary<DeviceId, RemotePlayback> { [new DeviceId("mac")] = Row(0) };
        Assert.True(await Eventually(actor, () => coordinator.ContinueSuggestion?.Playback.Track?.Title == "Song 0"));
    }

    [Fact]
    public void ADeviceThatWentOfflineWhilePlayingCountsAsPausedWhereItWasLastSeen()
    {
        var hub = new FakeHub();
        var now = hub.Clock.Now();
        hub.Devices = [Other("mac", now - 300_000)];
        var row = new RemotePlayback { DeviceId = new DeviceId("mac"), Track = Tracks(1)[0].Track, Anchor = new PlaybackAnchor { PositionMs = 10_000, PositionAt = now - 310_000, IsPlaying = true, Rate = 1, Volume = 1 }, UpdatedAt = now - 310_000 };
        var coordinator = new SyncCoordinator(hub, new FakePlayer(), SyncActor.CreateDedicated("c"));
        var effective = coordinator.EffectiveAnchor(row);
        Assert.False(effective.IsPlaying);
        Assert.Equal(20_000, effective.PositionMs, 0);
    }
}
