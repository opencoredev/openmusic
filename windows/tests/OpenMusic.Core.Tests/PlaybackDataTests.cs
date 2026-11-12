using static OpenMusic.Core.Tests.T;

namespace OpenMusic.Core.Tests;

// Ports of PlaybackDataTests.swift and the player parts of PlayerSystemTests.swift.

/// <summary>The queue panel's History: songs that actually played, not the queue's earlier entries.</summary>
public class ListeningHistoryTests
{
    private readonly ManualScheduler _scheduler = new();

    private (PlayerController, FakeProvider) Make()
    {
        var player = new PlayerController(_scheduler);
        var provider = new FakeProvider();
        player.Register(provider);
        player.Autoplay = false;
        return (player, provider);
    }

    private static List<string> HistoryIds(PlayerController p) => p.ListeningHistory.Select(h => h.Track.Id).ToList();

    [Fact]
    public void StartingMidListLeavesHistoryEmpty() => OnMain(async () =>
    {
        var (player, _) = Make();
        player.Play(MakeTracks(6), startAt: 4);
        await player.SettleAsync();
        Assert.Equal(4, player.PreviousEntries.Count);
        Assert.Empty(player.ListeningHistory);
    });

    [Fact]
    public void OnlySongsHeardForThirtySecondsAreListed() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = MakeTracks(4);
        player.Play(tracks);
        await player.SettleAsync();
        provider.Engine.PlayUntil(10); // skipped early: doesn't count
        player.Next();
        await player.SettleAsync();
        provider.Engine.PlayUntil(45);
        player.Next();
        await player.SettleAsync();
        Assert.Equal([tracks[1].Id], HistoryIds(player));
    });

    [Fact]
    public void DoubleClickingAnotherRowRecordsOnlyWhatPlayed() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = MakeTracks(5);
        player.Play(tracks, startAt: 1);
        await player.SettleAsync();
        provider.Engine.PlayUntil(60);
        player.Jump(player.Queue[4].Uid);
        await player.SettleAsync();
        Assert.Equal(tracks[4].Id, player.Current?.Id);
        Assert.Equal([tracks[1].Id], HistoryIds(player));
    });

    [Fact]
    public void CurrentSongIsNotListedWhileItPlays() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = MakeTracks(2);
        player.Play(tracks);
        await player.SettleAsync();
        provider.Engine.PlayUntil(40);
        Assert.Equal([tracks[0].Id], player.RecentlyPlayed.Select(p => p.Track.Id));
        Assert.Empty(player.ListeningHistory);
        player.Next();
        await player.SettleAsync();
        Assert.Equal([tracks[0].Id], HistoryIds(player));
    });

    [Fact]
    public void ASongHeardBeforeIsHiddenWhileItPlaysAgain() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = MakeTracks(2);
        player.Play(tracks);
        await player.SettleAsync();
        provider.Engine.PlayUntil(31);
        player.Next();
        await player.SettleAsync();
        provider.Engine.PlayUntil(31);
        player.Jump(player.Queue[0].Uid);
        await player.SettleAsync();
        provider.Engine.PlayUntil(5);
        Assert.Equal([tracks[1].Id, tracks[0].Id], player.RecentlyPlayed.Select(p => p.Track.Id));
        Assert.Equal([tracks[1].Id], HistoryIds(player));
    });

    [Fact]
    public void SurvivesANewQueue() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var album = MakeTracks(3, prefix: "a");
        player.Play(album);
        await player.SettleAsync();
        provider.Engine.PlayUntil(31);
        player.Play(MakeTracks(3, prefix: "p"));
        await player.SettleAsync();
        Assert.Equal([album[0].Id], HistoryIds(player));
    });

    [Fact]
    public void IsCapped() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var count = PlayerController.MaxRecentlyPlayed + 5;
        player.Play(MakeTracks(count, duration: 40));
        await player.SettleAsync();
        for (var i = 0; i < count; i++)
        {
            provider.Engine.CurrentTime = 0;
            provider.Engine.PlayUntil(21);
            player.Next();
            await player.SettleAsync();
        }
        Assert.Equal(PlayerController.MaxRecentlyPlayed, player.RecentlyPlayed.Count);
    });

    [Fact]
    public void PersistsWithTheQueue() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = MakeTracks(3);
        player.Play(tracks);
        await player.SettleAsync();
        provider.Engine.PlayUntil(31);
        player.Next();
        await player.SettleAsync();
        var restored = new PlayerController(_scheduler);
        restored.Register(new FakeProvider());
        restored.Restore(player.Snapshot());
        Assert.Equal(tracks[1].Id, restored.Current?.Id);
        Assert.Equal([tracks[0].Id], HistoryIds(restored));
    });

    [Fact]
    public void PlayNowFromHistoryKeepsTheQueue() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = MakeTracks(4);
        player.Play(tracks);
        await player.SettleAsync();
        provider.Engine.PlayUntil(31);
        player.Next();
        await player.SettleAsync();
        var played = player.ListeningHistory[0];
        player.PlayNow(played.Track, played.Context);
        await player.SettleAsync();
        Assert.Equal(tracks[0].Id, player.Current?.Id);
        Assert.Equal(5, player.Queue.Count);
        Assert.Equal([tracks[2].Id, tracks[3].Id], player.UpNext.Select(e => e.Track.Id));
        Assert.Equal(tracks[0].Id, provider.Engine.LastLoad?.TrackId);
    });
}

/// <summary>One length per song across the player, the queue and History.</summary>
public class DurationReconciliationTests
{
    private static (PlayerController, FakeProvider) Make()
    {
        var player = new PlayerController(new ManualScheduler());
        var provider = new FakeProvider();
        player.Register(provider);
        player.Autoplay = false;
        return (player, provider);
    }

    private static List<Track> WithoutDurations(List<Track> tracks) => tracks.Select(t => t with { Duration = null }).ToList();

    [Fact]
    public void Rule()
    {
        static double? R(double? c, double? s) => PlayerController.ReconciledDuration(c, s);
        Assert.Equal(406, R(346, 406)); // another cut: the stream wins
        Assert.Equal(346, R(346, 347.5)); // the same recording: keep the catalog's
        Assert.Equal(346, R(346, 344.5));
        Assert.Equal(231, R(null, 231));
        Assert.Equal(200, R(200, null));
        Assert.Equal(200, R(200, double.NaN));
        Assert.Equal(100, R(0, 100));
        Assert.Null(R(null, null));
    }

    [Fact]
    public void DifferentCutUpdatesPlayerAndEveryQueuedCopy() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var veridis = MakeTracks(1, prefix: "vq", duration: 346)[0];
        player.Play([veridis, MakeTracks(1)[0], veridis]);
        await player.SettleAsync();
        provider.Engine.Duration = 406;
        provider.Engine.Tick(1);
        Assert.Equal(406, player.Duration);
        Assert.All(player.Queue.Where(e => e.Track.Id == veridis.Id), e => Assert.Equal(406, e.Track.Duration));
    });

    [Fact]
    public void SmallDifferenceKeepsTheCatalogLength() => OnMain(async () =>
    {
        var (player, provider) = Make();
        player.Play(MakeTracks(1, duration: 346));
        await player.SettleAsync();
        provider.Engine.Duration = 347.4;
        provider.Engine.Tick(1);
        Assert.Equal(346, player.Duration);
        Assert.Equal(346, player.Current?.Duration);
    });

    [Fact]
    public void CurrentEntryGetsTheLengthThePlayerKnows() => OnMain(async () =>
    {
        var (player, provider) = Make();
        player.Play(WithoutDurations(MakeTracks(2)));
        await player.SettleAsync();
        Assert.Null(player.Current?.Duration);
        provider.Engine.Duration = 231;
        provider.Engine.Tick(1);
        Assert.Equal(231, player.Duration);
        Assert.Equal(231, player.Current?.Duration);
        Assert.Null(player.UpNext[0].Track.Duration);
    });

    [Fact]
    public void HistoryKeepsTheLengthThatPlayed() => OnMain(async () =>
    {
        var (player, provider) = Make();
        player.Play(MakeTracks(2, duration: 346));
        await player.SettleAsync();
        provider.Engine.Duration = 406;
        provider.Engine.PlayUntil(31);
        player.Next();
        await player.SettleAsync();
        Assert.Equal(406, player.ListeningHistory[0].Track.Duration);
    });

    [Fact]
    public void LengthResolvedForTheNextSongFillsItsRow() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = WithoutDurations(MakeTracks(3));
        player.Play(tracks);
        await player.SettleAsync();
        provider.Engine.OnDurationResolved?.Invoke(tracks[1].Id, 200);
        Assert.Equal([200, null], player.UpNext.Select(e => e.Track.Duration));
    });

    [Fact]
    public void ResolvedLengthBeforeTheFirstTickShowsInThePlayer() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = MakeTracks(1, duration: 346);
        player.Play(tracks);
        await player.SettleAsync();
        provider.Engine.OnDurationResolved?.Invoke(tracks[0].Id, 406);
        Assert.Equal(406, player.Duration);
        Assert.Equal(406, player.Current?.Duration);
    });

    [Fact]
    public void RadioListingsFillQueuedSongsWithoutLengths() => OnMain(async () =>
    {
        var (player, provider) = Make();
        // Artist top songs: no lengths. Autoplay radio returns one of them with a length.
        var top = WithoutDurations(MakeTracks(2, prefix: "top"));
        var listed = top[0] with { Duration = 180 };
        provider.RadioResult = [listed, .. MakeTracks(3, prefix: "r", duration: 210)];
        player.Autoplay = true;
        player.Play(top, startAt: 1);
        await player.SettleAsync();
        Assert.Equal(180, player.Queue[0].Track.Duration);
        Assert.All(player.UpNext, e => Assert.Equal(210, e.Track.Duration));
    });

    [Fact]
    public void LearnedLengthsApplyToLaterQueues() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var song = MakeTracks(1, duration: 346);
        player.Play(song);
        await player.SettleAsync();
        provider.Engine.Duration = 406;
        provider.Engine.Tick(1);
        player.Play([.. MakeTracks(2, prefix: "x"), .. song], startAt: 0);
        await player.SettleAsync();
        Assert.Equal(406, player.Queue[^1].Track.Duration);
    });

    [Fact]
    public void KnownLengthsAnnounceWhatTheyLearn()
    {
        var lengths = new KnownLengths();
        var heard = new List<(string, double)>();
        lengths.Learned += (id, s) => heard.Add((id, s));
        lengths.Learn(406, "a");
        lengths.Learn(406.2, "a"); // jitter: not a change
        lengths.Learn(410, "a");
        lengths.Learn(double.NaN, "b");
        Assert.Equal([("a", 406.0), ("a", 410.0)], heard);
    }

    [Fact]
    public void KnownLengthsFollowStreams() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var song = MakeTracks(1, duration: 346)[0];
        player.Play([song]);
        await player.SettleAsync();
        provider.Engine.Duration = 406;
        provider.Engine.Tick(1);
        Assert.Equal(406, player.KnownLengths.DisplayDuration(song));
        Assert.Equal((346.0, 406.0), player.KnownLengths.Mismatch(song));
    });
}

public class SleepTimerTests
{
    private readonly ManualScheduler _scheduler = new();

    private (PlayerController, FakeProvider) Make()
    {
        var player = new PlayerController(_scheduler);
        var provider = new FakeProvider();
        player.Register(provider);
        player.Autoplay = false;
        return (player, provider);
    }

    [Fact]
    public void PausesAfterMinutes() => OnMain(async () =>
    {
        var (player, provider) = Make();
        player.Play(MakeTracks(3));
        await player.SettleAsync();
        player.SetSleepTimer(10);
        Assert.Equal(SleepTimer.At(_scheduler.Now.AddSeconds(600)), player.SleepTimer);
        _scheduler.Advance(9 * 60);
        Assert.Equal(PlaybackState.Playing, player.State);
        Assert.Equal(60, player.SleepTimerRemaining);
        _scheduler.Advance(60);
        Assert.Equal(PlaybackState.Paused, player.State);
        Assert.Equal(1, provider.Engine.Pauses);
        Assert.Equal(SleepTimer.Off, player.SleepTimer);
        Assert.Null(player.SleepTimerRemaining);
    });

    [Fact]
    public void ResettingReplacesTheDeadline() => OnMain(async () =>
    {
        var (player, provider) = Make();
        player.Play(MakeTracks(3));
        await player.SettleAsync();
        player.SetSleepTimer(5);
        player.SetSleepTimer(20);
        Assert.Equal(1, _scheduler.PendingCount);
        _scheduler.Advance(6 * 60);
        Assert.Equal(PlaybackState.Playing, player.State);
        _scheduler.Advance(15 * 60);
        Assert.Equal(PlaybackState.Paused, player.State);
        Assert.Equal(1, provider.Engine.Pauses);
    });

    [Fact]
    public void CancelLeavesPlaybackAlone() => OnMain(async () =>
    {
        var (player, provider) = Make();
        player.Play(MakeTracks(3));
        await player.SettleAsync();
        player.SetSleepTimer(1);
        player.CancelSleepTimer();
        _scheduler.Advance(3600);
        Assert.Equal(PlaybackState.Playing, player.State);
        Assert.Equal(0, provider.Engine.Pauses);
        Assert.Equal(0, _scheduler.PendingCount);
    });

    [Fact]
    public void EndOfTrackStopsAtTheBoundaryAndCuesTheNextTrack() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = MakeTracks(3);
        player.Play(tracks);
        await player.SettleAsync();
        Assert.Equal((true, tracks[1].Id), provider.Engine.LastPrepared);
        player.SetSleepTimerEndOfTrack();
        // No gapless handoff into a track that shouldn't play.
        Assert.Equal((true, (string?)null), provider.Engine.LastPrepared);
        player.Skip(30);
        Assert.Equal(PlaybackState.Playing, player.State);
        provider.Engine.Finish();
        await player.SettleAsync();
        Assert.Equal(tracks[1].Id, player.Current?.Id);
        Assert.Equal(new FakeEngine.LoadCall(tracks[1].Id, 0, false), provider.Engine.LastLoad);
        Assert.Equal(PlaybackState.Paused, player.State);
        Assert.Equal(SleepTimer.Off, player.SleepTimer);
        player.TogglePlayPause();
        Assert.Equal(PlaybackState.Playing, player.State);
    });

    [Fact]
    public void EndOfTrackOnLastTrackEnds() => OnMain(async () =>
    {
        var (player, provider) = Make();
        player.Play(MakeTracks(1));
        await player.SettleAsync();
        player.SetSleepTimerEndOfTrack();
        provider.Engine.Finish();
        Assert.Equal(PlaybackState.Ended, player.State);
    });
}

public class RecentlyPlayedTests
{
    private readonly ManualScheduler _scheduler = new();

    private (PlayerController, FakeProvider) Make()
    {
        var player = new PlayerController(_scheduler);
        var provider = new FakeProvider();
        player.Register(provider);
        player.Autoplay = false;
        return (player, provider);
    }

    [Fact]
    public void RecordsAfterThirtySecondsOfListening() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = MakeTracks(2, duration: 240);
        var reported = new List<string>();
        player.OnTrackPlayed = p => reported.Add(p.Track.Id);
        player.Play(tracks, context: PlaybackContext.ForPlaylist(new Playlist { ProviderID = "p", Provider = ProviderId.YouTubeMusic, Title = "Mix" }));
        await player.SettleAsync();
        provider.Engine.PlayUntil(29);
        Assert.Empty(player.RecentlyPlayed);
        provider.Engine.PlayUntil(30);
        Assert.Equal([tracks[0].Id], player.RecentlyPlayed.Select(p => p.Track.Id));
        Assert.Equal(_scheduler.Now, player.RecentlyPlayed[0].PlayedAt);
        Assert.Equal("Mix", player.RecentlyPlayed[0].Context?.Title);
        provider.Engine.PlayUntil(120);
        Assert.Equal([tracks[0].Id], reported);
    });

    [Fact]
    public void ShortTracksCountAtHalfTheirLength() => OnMain(async () =>
    {
        var (player, provider) = Make();
        player.Play(MakeTracks(1, duration: 40));
        await player.SettleAsync();
        provider.Engine.PlayUntil(19);
        Assert.Empty(player.RecentlyPlayed);
        provider.Engine.PlayUntil(20);
        Assert.Single(player.RecentlyPlayed);
    });

    [Fact]
    public void SeekingAheadDoesNotCount() => OnMain(async () =>
    {
        var (player, provider) = Make();
        player.Play(MakeTracks(1));
        await player.SettleAsync();
        provider.Engine.Tick(5);
        player.Seek(150);
        provider.Engine.Tick(150);
        provider.Engine.Tick(160);
        Assert.Empty(player.RecentlyPlayed);
    });

    [Fact]
    public void ReplaysMoveToTheFrontWithoutDuplicates() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = MakeTracks(2);
        player.Play(tracks);
        await player.SettleAsync();
        provider.Engine.PlayUntil(31);
        player.Next();
        await player.SettleAsync();
        provider.Engine.PlayUntil(31);
        player.Previous(); // more than 3 s in: restart
        player.Previous(); // back to the first track
        await player.SettleAsync();
        provider.Engine.PlayUntil(31);
        Assert.Equal([tracks[0].Id, tracks[1].Id], player.RecentlyPlayed.Select(p => p.Track.Id));
    });

    [Fact]
    public void RepeatOneCountsEachPlay() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var reports = 0;
        player.OnTrackPlayed = _ => reports++;
        player.RepeatMode = RepeatMode.One;
        player.Play(MakeTracks(1, duration: 60));
        await player.SettleAsync();
        provider.Engine.PlayUntil(60);
        provider.Engine.Finish();
        provider.Engine.CurrentTime = 0;
        provider.Engine.PlayUntil(40);
        Assert.Equal(2, reports);
        Assert.Single(player.RecentlyPlayed);
    });
}

public class PersistenceTests
{
    private static QueueStore TempStore() =>
        new(Path.Combine(Path.GetTempPath(), "openmusic-tests", $"queue-{Guid.NewGuid():N}.json"));

    [Fact]
    public void SnapshotRoundTripsThroughDisk() => OnMain(async () =>
    {
        var scheduler = new ManualScheduler();
        var player = new PlayerController(scheduler);
        var provider = new FakeProvider();
        player.Register(provider);
        player.Autoplay = false;
        var tracks = MakeTracks(8);
        player.Play(tracks, startAt: 2, context: PlaybackContext.ForAlbum(new Album { ProviderID = "a", Provider = ProviderId.YouTubeMusic, Title = "Homework" }));
        await player.SettleAsync();
        player.PlayNext(MakeTracks(1, prefix: "q"));
        player.Shuffle = true;
        player.RepeatMode = RepeatMode.All;
        provider.Engine.PlayUntil(42);

        var store = TempStore();
        var snapshot = player.Snapshot();
        store.Save(snapshot);
        var loaded = store.Load();
        Assert.NotNull(loaded);
        Assert.Equal(snapshot, loaded);

        // A fresh player (next launch) comes back paused at the same spot, without touching the engine.
        var relaunched = new PlayerController(scheduler);
        var freshProvider = new FakeProvider();
        relaunched.Register(freshProvider);
        relaunched.Restore(loaded!);
        Assert.Equal(player.Queue, relaunched.Queue);
        Assert.Equal(player.CurrentIndex, relaunched.CurrentIndex);
        Assert.Equal(42, relaunched.CurrentTime);
        Assert.Equal(PlaybackState.Paused, relaunched.State);
        Assert.True(relaunched.Shuffle);
        Assert.Equal(RepeatMode.All, relaunched.RepeatMode);
        Assert.Equal("Playing from Homework", relaunched.SourceLabel);
        Assert.Equal([tracks[2].Id], relaunched.RecentlyPlayed.Select(p => p.Track.Id));
        Assert.Empty(freshProvider.Engine.Loads);

        // Unshuffle still works after the relaunch.
        relaunched.Shuffle = false;
        Assert.Equal("youtubeMusic:q0", relaunched.UpNext[0].Track.Id);
        Assert.Equal(tracks.Skip(3).Select(t => t.Id), relaunched.UpNext.Skip(1).Select(e => e.Track.Id));

        // Play loads the saved track at the saved position.
        relaunched.TogglePlayPause();
        await relaunched.SettleAsync();
        Assert.Equal(new FakeEngine.LoadCall(tracks[2].Id, 42, true), freshProvider.Engine.LastLoad);
        Assert.Equal(PlaybackState.Playing, relaunched.State);
    });

    [Fact]
    public void RestoredPlayerMovesCursorWithoutLoading() => OnMain(async () =>
    {
        var player = new PlayerController(new ManualScheduler());
        var provider = new FakeProvider();
        player.Register(provider);
        var tracks = MakeTracks(3);
        player.Restore(new PlayerSnapshot
        {
            Queue = tracks.Select(t => new QueueEntry(t)).ToList(), CurrentIndex = 1, Position = 12,
            RepeatMode = RepeatMode.Off, SavedAt = DateTimeOffset.UtcNow,
        });
        player.Next();
        Assert.Equal(tracks[2].Id, player.Current?.Id);
        Assert.Equal(0, player.CurrentTime);
        player.Seek(7);
        Assert.Empty(provider.Engine.Loads);
        player.Resume();
        await player.SettleAsync();
        Assert.Equal(new FakeEngine.LoadCall(tracks[2].Id, 7, true), provider.Engine.LastLoad);
    });

    [Fact]
    public void RestoreIgnoresABadIndex() => OnMain(() =>
    {
        var player = new PlayerController(new ManualScheduler());
        player.Restore(new PlayerSnapshot { Queue = [], CurrentIndex = 4, Position = 10, RepeatMode = RepeatMode.One, SavedAt = DateTimeOffset.UtcNow });
        Assert.Null(player.Current);
        Assert.Equal(PlaybackState.Idle, player.State);
        return Task.CompletedTask;
    });

    [Fact]
    public void StoreReturnsNullForMissingOrCorruptFiles()
    {
        var store = TempStore();
        Assert.Null(store.Load());
        Directory.CreateDirectory(Path.GetDirectoryName(store.Path)!);
        File.WriteAllText(store.Path, "{not json");
        Assert.Null(store.Load());
    }

    [Theory]
    [InlineData("""{"version":1,"queue":[null],"position":0,"shuffle":false,"repeatMode":"off","recentlyPlayed":[],"savedAt":0}""")]
    [InlineData("""{"version":1,"queue":[{"uid":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","track":{"providerID":"a","provider":"spotify","title":null}}],"position":0,"shuffle":false,"repeatMode":"off","recentlyPlayed":[],"savedAt":0}""")]
    [InlineData("""{"version":1,"queue":[{"uid":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","track":null}],"position":0,"shuffle":false,"repeatMode":"off","recentlyPlayed":[],"savedAt":0}""")]
    [InlineData("""{"version":2,"queue":[],"position":0,"shuffle":false,"repeatMode":"off","recentlyPlayed":[],"savedAt":0}""")]
    public void StoreRefusesSnapshotsSwiftWouldRefuse(string json) => OnMain(() =>
    {
        var store = TempStore();
        Directory.CreateDirectory(Path.GetDirectoryName(store.Path)!);
        File.WriteAllText(store.Path, json);
        Assert.Null(store.Load());
        return Task.CompletedTask;
    });

    [Theory]
    [InlineData("""{"version":1,"queue":null,"currentIndex":0,"position":0,"shuffle":false,"repeatMode":"off","recentlyPlayed":[],"savedAt":0}""")]
    [InlineData("""{"version":1,"queue":[],"position":0,"shuffle":false,"repeatMode":"off","recentlyPlayed":null,"savedAt":0}""")]
    public void NullListsLoadEmptyAndRestoreSafely(string json) => OnMain(() =>
    {
        var store = TempStore();
        Directory.CreateDirectory(Path.GetDirectoryName(store.Path)!);
        File.WriteAllText(store.Path, json);
        var loaded = store.Load();
        Assert.NotNull(loaded);
        var player = new PlayerController(new ManualScheduler());
        player.Restore(loaded!);
        Assert.Empty(player.Queue);
        Assert.Equal(PlaybackState.Idle, player.State);
        return Task.CompletedTask;
    });

    [Fact]
    public void StoreAcceptsAMinimalValidSnapshot()
    {
        var store = TempStore();
        Directory.CreateDirectory(Path.GetDirectoryName(store.Path)!);
        File.WriteAllText(store.Path, """{"version":1,"queue":[{"uid":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","track":{"providerID":"a","provider":"spotify","title":"x"}}],"currentIndex":0,"position":3,"shuffle":false,"repeatMode":"off","recentlyPlayed":[],"savedAt":0}""");
        var loaded = store.Load();
        Assert.NotNull(loaded);
        Assert.Equal("spotify:a", loaded!.Queue[0].Track.Id);
    }

    [Fact]
    public void StoreNeverWritesAnOlderGeneration()
    {
        var store = TempStore();
        var newer = new PlayerSnapshot { Position = 2, SavedAt = DateTimeOffset.UnixEpoch };
        var older = new PlayerSnapshot { Position = 1, SavedAt = DateTimeOffset.UnixEpoch };
        Assert.True(store.Save(newer, 2));
        Assert.False(store.Save(older, 1));
        Assert.Equal(2, store.Load()?.Position);
    }

    [Fact]
    public void PersistenceDebouncesAndRestores() => OnMain(async () =>
    {
        var scheduler = new ManualScheduler();
        var player = new PlayerController(scheduler);
        var provider = new FakeProvider();
        player.Register(provider);
        player.Autoplay = false;
        var store = TempStore();
        var persistence = new QueuePersistence(player, store, scheduler, debounce: 2, playingInterval: 20);
        persistence.Start();

        player.Play(MakeTracks(4));
        player.AddToQueue(MakeTracks(2, prefix: "u"));
        player.RepeatMode = RepeatMode.All;
        await player.SettleAsync();
        Assert.Equal(0, persistence.SaveCount);
        scheduler.Advance(2);
        Assert.Equal(1, persistence.SaveCount);
        // While playing, the position is saved periodically; pausing saves sooner.
        provider.Engine.PlayUntil(15);
        scheduler.Advance(10);
        Assert.Equal(1, persistence.SaveCount);
        player.Pause();
        scheduler.Advance(2);
        Assert.Equal(2, persistence.SaveCount);
        // Paused: nothing else is scheduled.
        Assert.Equal(0, scheduler.PendingCount);
        await persistence.FlushAsync();

        var relaunched = new PlayerController(scheduler);
        var restorer = new QueuePersistence(relaunched, store, scheduler);
        Assert.True(await restorer.RestoreAsync());
        Assert.Equal(player.Queue.Select(e => e.Track.Id), relaunched.Queue.Select(e => e.Track.Id));
        Assert.Equal(15, relaunched.CurrentTime);
        Assert.Equal(RepeatMode.All, relaunched.RepeatMode);
        Assert.Equal(PlaybackState.Paused, relaunched.State);
    });
}
