using OpenMusic.Core.Mock;
using OpenMusic.Core.Support;
using static OpenMusic.Core.Tests.T;

namespace OpenMusic.Core.Tests;

/// <summary>Queue behavior against the shared MockProvider (the same one the UI uses). Port of
/// PlayerControllerMockProviderTests.</summary>
public class PlayerControllerMockProviderTests
{
    private static (PlayerController, MockProvider) Make()
    {
        var player = new PlayerController();
        var provider = new MockProvider(ProviderId.YouTubeMusic);
        player.Register(provider);
        player.Autoplay = false;
        return (player, provider);
    }

    [Fact]
    public void PlayStartsAtIndex() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = provider.SampleTracks(5);
        player.Play(tracks, startAt: 2);
        Assert.Equal(tracks[2].Id, player.Current?.Id);
        Assert.Equal(2, player.UpNext.Count);
        Assert.Equal(2, player.PreviousEntries.Count);
        await player.SettleAsync();
        Assert.Equal(PlaybackState.Playing, player.State);
        player.Pause();
    });

    [Fact]
    public void PlayNextInsertsAfterCurrent() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = provider.SampleTracks(3);
        player.Play(tracks);
        var extra = provider.SampleTracks(1);
        player.PlayNext(extra);
        Assert.Equal(extra[0].Id, player.UpNext[0].Track.Id);
        await player.SettleAsync();
        player.Pause();
    });

    [Fact]
    public void NextAndPreviousMove() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = provider.SampleTracks(3);
        player.Play(tracks);
        player.Next();
        Assert.Equal(tracks[1].Id, player.Current?.Id);
        player.Previous();
        Assert.Equal(tracks[0].Id, player.Current?.Id);
        await player.SettleAsync();
        player.Pause();
    });

    [Fact]
    public void ShuffleKeepsCurrentAndRestoresOrder() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = provider.SampleTracks(10);
        player.Play(tracks);
        player.Shuffle = true;
        Assert.Equal(tracks[0].Id, player.Current?.Id);
        Assert.Equal(10, player.Queue.Count);
        player.Shuffle = false;
        Assert.Equal(tracks.Select(t => t.Id), player.Queue.Select(e => e.Track.Id));
        await player.SettleAsync();
        player.Pause();
    });

    [Fact]
    public void AutoplayExtendsFromMockRadioWithoutDuplicates() => OnMain(async () =>
    {
        var (player, provider) = Make();
        player.Autoplay = true;
        var seeds = provider.SampleTracks(2);
        player.Play(seeds);
        await player.SettleAsync();
        // Up Next had fewer than 2 entries, so radio was fetched right away.
        var radio = await provider.RadioAsync(seeds[1]);
        var expected = radio.Select(t => t.Id).ToHashSet();
        expected.ExceptWith(seeds.Select(t => t.Id));
        Assert.True(expected.Count > 0);
        Assert.Equal(2 + Math.Min(expected.Count, 25), player.Queue.Count);
        Assert.Equal(player.Queue.Count, player.Queue.Select(e => e.Track.Id).Distinct().Count());
        Assert.All(player.Queue.Skip(2), e => Assert.True(e.IsAutoplay));
        Assert.Equal(PlaybackContext.Autoplay, player.Queue[^1].Context);
        player.Pause();
    });

    [Fact]
    public void MockEngineAdvancesTime() => OnMain(async () =>
    {
        var (player, provider) = Make();
        player.Play(provider.SampleTracks(2));
        await player.SettleAsync();
        Assert.True(await WaitUntil(() => player.CurrentTime >= 1, 5));
        player.Pause();
    });
}

/// <summary>Queue behavior with a scriptable engine, for failure, race and engine-call assertions. Port of
/// PlayerControllerTests.swift.</summary>
public class PlayerControllerTests
{
    private readonly ManualScheduler _scheduler = new();

    private (PlayerController, FakeProvider) Make(bool autoplay = false)
    {
        var player = new PlayerController(_scheduler);
        var provider = new FakeProvider();
        player.Register(provider);
        player.Autoplay = autoplay;
        return (player, provider);
    }

    private static List<string> Ids(IEnumerable<QueueEntry> entries) => entries.Select(e => e.Track.ProviderID).ToList();

    // MARK: play

    [Fact]
    public void PlaySkipsUnplayableStartTrack() => OnMain(() =>
    {
        var (player, _) = Make();
        var tracks = MakeTracks(5);
        tracks[2] = tracks[2] with { IsPlayable = false };
        player.Play(tracks, startAt: 2);
        Assert.Equal(tracks[3].Id, player.Current?.Id);
        Assert.Equal(4, player.Queue.Count);
        return Task.CompletedTask;
    });

    [Fact]
    public void PlayWithDuplicateTracksStartsAtExactIndex() => OnMain(() =>
    {
        var (player, _) = Make();
        var t = MakeTracks(1)[0];
        player.Play([t, t, t], startAt: 1);
        Assert.Equal(1, player.CurrentIndex);
        Assert.Single(player.PreviousEntries);
        Assert.Equal(3, player.Queue.Select(e => e.Uid).Distinct().Count());
        return Task.CompletedTask;
    });

    [Fact]
    public void PlayIgnoresAllUnplayable() => OnMain(() =>
    {
        var (player, _) = Make();
        var tracks = MakeTracks(2).Select(t => t with { IsPlayable = false }).ToList();
        player.Play(tracks);
        Assert.Empty(player.Queue);
        Assert.Equal(PlaybackState.Idle, player.State);
        return Task.CompletedTask;
    });

    [Fact]
    public void PlayLoadsTrackAndPreparesNext() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = MakeTracks(3);
        player.Play(tracks);
        await player.SettleAsync();
        Assert.Equal(new FakeEngine.LoadCall(tracks[0].Id, 0, true), provider.Engine.LastLoad);
        Assert.Equal((true, tracks[1].Id), provider.Engine.LastPrepared);
        Assert.Equal(PlaybackState.Playing, player.State);
    });

    // MARK: context

    [Fact]
    public void ContextLabelFollowsTheCurrentEntry() => OnMain(() =>
    {
        var (player, _) = Make();
        var album = new Album { ProviderID = "al1", Provider = ProviderId.YouTubeMusic, Title = "Discovery" };
        player.Play(MakeTracks(2), context: PlaybackContext.ForAlbum(album));
        Assert.Equal("Playing from Discovery", player.SourceLabel);
        player.PlayNext(MakeTracks(1, prefix: "q"));
        player.Next();
        Assert.Equal("youtubeMusic:q0", player.Current?.Id);
        Assert.Null(player.SourceLabel);
        player.Next();
        Assert.Equal("Playing from Discovery", player.SourceLabel);
        Assert.Equal("Playing from Daft Punk Radio", PlaybackContext.Radio("Daft Punk").Label);
        Assert.Equal("Autoplay", PlaybackContext.Autoplay.Label);
        return Task.CompletedTask;
    });

    [Fact]
    public void PlayRadioStartsWithSeedAndRadioContext() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var seed = MakeTracks(1, prefix: "seed")[0];
        provider.RadioResult = [seed, .. MakeTracks(5, prefix: "r")];
        await player.PlayRadioAsync(seed);
        Assert.Equal([seed.Id, .. MakeTracks(5, prefix: "r").Select(t => t.Id)], player.Queue.Select(e => e.Track.Id));
        Assert.Equal("Playing from SEED 0 Radio", player.SourceLabel);
    });

    // MARK: insert / add / move / remove

    [Fact]
    public void PlayNextStacksMostRecentFirst() => OnMain(() =>
    {
        var (player, _) = Make();
        player.Play(MakeTracks(3));
        var a = MakeTracks(1, prefix: "a");
        var b = MakeTracks(1, prefix: "b");
        player.PlayNext(a);
        player.PlayNext(b);
        Assert.Equal([b[0].Id, a[0].Id], player.UpNext.Take(2).Select(e => e.Track.Id));
        Assert.All(player.UpNext.Take(2), e => Assert.True(e.IsUserQueued));
        return Task.CompletedTask;
    });

    [Fact]
    public void AddToQueueGoesBeforeAutoplayEntries() => OnMain(async () =>
    {
        var (player, provider) = Make(autoplay: true);
        provider.RadioResult = MakeTracks(3, prefix: "r");
        player.Play(MakeTracks(1));
        await player.SettleAsync();
        Assert.Equal(4, player.Queue.Count);
        var added = MakeTracks(1, prefix: "u");
        player.AddToQueue(added);
        Assert.Equal(added[0].Id, player.Queue[1].Track.Id);
        Assert.All(player.Queue.Skip(2), e => Assert.True(e.IsAutoplay));
    });

    [Fact]
    public void InsertAtIndexClampsIntoUpNext() => OnMain(() =>
    {
        var (player, _) = Make();
        var tracks = MakeTracks(5);
        player.Play(tracks, startAt: 2);
        var x = MakeTracks(1, prefix: "x");
        player.Insert(x, 0);
        Assert.Equal(2, player.CurrentIndex);
        Assert.Equal(x[0].Id, player.Queue[3].Track.Id);
        var y = MakeTracks(1, prefix: "y");
        player.Insert(y, 99);
        Assert.Equal(y[0].Id, player.Queue[^1].Track.Id);
        var z = MakeTracks(1, prefix: "z");
        player.InsertAtUpNextOffset(z, 1);
        Assert.Equal(z[0].Id, player.UpNext[1].Track.Id);
        Assert.Equal(tracks[2].Id, player.Current?.Id);
        return Task.CompletedTask;
    });

    [Fact]
    public void InsertWithEmptyQueuePlays() => OnMain(() =>
    {
        var (player, _) = Make();
        var x = MakeTracks(2, prefix: "x");
        player.Insert(x, 5);
        Assert.Equal(x[0].Id, player.Current?.Id);
        return Task.CompletedTask;
    });

    [Fact]
    public void MoveKeepsCurrentEntry() => OnMain(() =>
    {
        var (player, _) = Make();
        var tracks = MakeTracks(5);
        player.Play(tracks, startAt: 1);
        // Move the current entry to the end.
        player.Move([1], 5);
        Assert.Equal(tracks[1].Id, player.Current?.Id);
        Assert.Equal(4, player.CurrentIndex);
        // Move two entries to the front.
        player.Move([2, 3], 0);
        Assert.Equal(new[] { tracks[3], tracks[4], tracks[0], tracks[2], tracks[1] }.Select(t => t.Id), player.Queue.Select(e => e.Track.Id));
        Assert.Equal(tracks[1].Id, player.Current?.Id);
        // Out of range offsets are ignored.
        player.Move([42], 0);
        Assert.Equal(5, player.Queue.Count);
        return Task.CompletedTask;
    });

    [Fact]
    public void MoveUpNextUsesUpNextOffsets() => OnMain(() =>
    {
        var (player, _) = Make();
        var tracks = MakeTracks(5);
        player.Play(tracks, startAt: 1);
        // Up Next is t2 t3 t4; move t4 to the front.
        player.MoveUpNext([2], 0);
        Assert.Equal(new[] { tracks[4], tracks[2], tracks[3] }.Select(t => t.Id), player.UpNext.Select(e => e.Track.Id));
        Assert.Equal(tracks[1].Id, player.Current?.Id);
        return Task.CompletedTask;
    });

    [Fact]
    public void RemoveBeforeCurrentShiftsIndex() => OnMain(() =>
    {
        var (player, _) = Make();
        var tracks = MakeTracks(4);
        player.Play(tracks, startAt: 2);
        player.Remove(player.Queue[0].Uid);
        Assert.Equal(1, player.CurrentIndex);
        Assert.Equal(tracks[2].Id, player.Current?.Id);
        player.RemoveUpNext([0]);
        Assert.Empty(player.UpNext);
        return Task.CompletedTask;
    });

    [Fact]
    public void RemoveCurrentAdvances() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = MakeTracks(3);
        player.Play(tracks);
        await player.SettleAsync();
        player.Remove(player.Queue[0].Uid);
        await player.SettleAsync();
        Assert.Equal(tracks[1].Id, player.Current?.Id);
        Assert.Equal(tracks[1].Id, provider.Engine.LastLoad?.TrackId);
        Assert.Equal(PlaybackState.Playing, player.State);
    });

    [Fact]
    public void RemoveLastCurrentEnds() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = MakeTracks(2);
        player.Play(tracks, startAt: 1);
        await player.SettleAsync();
        player.Remove(player.Queue[1].Uid);
        Assert.Equal(PlaybackState.Ended, player.State);
        Assert.True(provider.Engine.Stops >= 1);
        player.Remove(player.Queue[0].Uid);
        Assert.Empty(player.Queue);
        Assert.Null(player.Current);
        Assert.Equal(PlaybackState.Idle, player.State);
    });

    [Fact]
    public void ClearUpNextKeepsHistoryAndCurrent() => OnMain(() =>
    {
        var (player, _) = Make();
        player.Play(MakeTracks(5), startAt: 2);
        player.ClearUpNext();
        Assert.Equal(3, player.Queue.Count);
        Assert.Equal(2, player.CurrentIndex);
        return Task.CompletedTask;
    });

    /// <summary>A queue of: the current song, one song queued with Play Next, the rest of the album, then autoplay's songs.</summary>
    private async Task<(PlayerController, FakeProvider)> QueueWithAutoplay()
    {
        var (player, provider) = Make(autoplay: true);
        provider.RadioResult = MakeTracks(3, prefix: "r");
        player.Play(MakeTracks(2));
        await player.SettleAsync();
        player.PlayNext(MakeTracks(1, prefix: "x"));
        return (player, provider);
    }

    [Fact]
    public void ClearUpNextLeavesAutoplay() => OnMain(async () =>
    {
        var (player, provider) = await QueueWithAutoplay();
        Assert.Equal(["t0", "x0", "t1", "r0", "r1", "r2"], Ids(player.Queue));
        var loads = provider.Engine.Loads.Count;
        var cleared = player.ClearUpNext();
        Assert.Equal(["x0", "t1"], Ids(cleared!.Entries));
        Assert.Equal(["t0", "r0", "r1", "r2"], Ids(player.Queue));
        Assert.All(player.Queue.Skip(1), e => Assert.True(e.IsAutoplay));
        Assert.Equal("t0", player.Current?.ProviderID);
        Assert.Equal(loads, provider.Engine.Loads.Count);
        // Nothing left to clear: autoplay's songs aren't Up Next.
        Assert.Null(player.ClearUpNext());
    });

    [Fact]
    public void UndoClearUpNextRestoresEntriesWithoutRestarting() => OnMain(async () =>
    {
        var (player, provider) = await QueueWithAutoplay();
        var before = player.Queue.ToList();
        var loads = provider.Engine.Loads.Count;
        var seeks = provider.Engine.Seeks.Count;
        var undo = new UndoStack();

        player.ClearUpNext(undo);
        Assert.Equal(["t0", "r0", "r1", "r2"], Ids(player.Queue));
        Assert.True(undo.CanUndo);
        Assert.Equal("Clear Up Next", undo.UndoActionName);

        undo.Undo();
        // Same entries (uids, so the same rows), in the same order, with their flags and contexts.
        Assert.Equal(before, player.Queue);
        Assert.True(player.Queue[1].IsUserQueued);
        Assert.True(!player.Queue[2].IsUserQueued && !player.Queue[2].IsAutoplay);
        Assert.Equal("t0", player.Current?.ProviderID);
        Assert.Equal(0, player.CurrentIndex);
        Assert.Equal(loads, provider.Engine.Loads.Count);
        Assert.Equal(seeks, provider.Engine.Seeks.Count);
        Assert.Equal(PlaybackState.Playing, player.State);

        // Redo removes those songs again; undoing that brings them back once more.
        Assert.True(undo.CanRedo);
        Assert.Equal("Clear Up Next", undo.RedoActionName);
        undo.Redo();
        Assert.Equal(["t0", "r0", "r1", "r2"], Ids(player.Queue));
        undo.Undo();
        Assert.Equal(before, player.Queue);
    });

    [Fact]
    public void ClearUpNextIncludingAutoplayEmptiesEverythingAfterCurrent() => OnMain(async () =>
    {
        var (player, _) = await QueueWithAutoplay();
        player.ClearUpNext(includingAutoplay: true);
        Assert.Equal(["t0"], Ids(player.Queue));
    });

    [Fact]
    public void UndoClearUpNextIgnoresAReplacedQueue() => OnMain(async () =>
    {
        var (player, _) = await QueueWithAutoplay();
        var cleared = player.ClearUpNext();
        player.Play(MakeTracks(2, prefix: "n"));
        var replaced = player.Queue.Select(e => e.Uid).ToList();
        if (cleared is not null) player.RestoreUpNext(cleared);
        Assert.Equal(replaced, player.Queue.Select(e => e.Uid));
    });

    [Fact]
    public void UndoClearUpNextKeepsSongsQueuedSince() => OnMain(async () =>
    {
        var (player, _) = await QueueWithAutoplay();
        var undo = new UndoStack();
        player.ClearUpNext(undo);
        player.AddToQueue(MakeTracks(1, prefix: "y"));
        undo.Undo();
        Assert.Equal(["t0", "x0", "t1", "y0", "r0", "r1", "r2"], Ids(player.Queue));
        Assert.Equal(player.Queue.Count, player.Queue.Select(e => e.Uid).Distinct().Count());
    });

    [Fact]
    public void UndoRemoveFromQueueRestoresTheEntryInPlaceWithoutRestarting() => OnMain(async () =>
    {
        var (player, provider) = await QueueWithAutoplay();
        var before = player.Queue.ToList();
        var loads = provider.Engine.Loads.Count;
        var seeks = provider.Engine.Seeks.Count;
        var undo = new UndoStack();

        // Remove a song from the middle of Up Next (t1, after the queued x0) and one of autoplay's (r1).
        var t1 = before[2];
        var r1 = before[4];
        player.RemoveUpNext([t1.Uid], undo);
        Assert.Equal(["t0", "x0", "r0", "r1", "r2"], Ids(player.Queue));
        Assert.Equal($"Remove “{t1.Track.Title}”", undo.UndoActionName);
        player.RemoveUpNext([r1.Uid], undo);
        Assert.Equal(["t0", "x0", "r0", "r2"], Ids(player.Queue));

        undo.Undo();
        Assert.Equal(["t0", "x0", "r0", "r1", "r2"], Ids(player.Queue));
        Assert.Equal(r1, player.Queue[3]);
        Assert.True(player.Queue[3].IsAutoplay);
        undo.Undo();
        // Same entries (uids, flags, contexts) in the same order; the current song wasn't touched.
        Assert.Equal(before, player.Queue);
        Assert.Equal(t1.Uid, player.Queue[2].Uid);
        Assert.True(!player.Queue[2].IsUserQueued && !player.Queue[2].IsAutoplay);
        Assert.True(player.Queue[1].IsUserQueued);
        Assert.Equal(0, player.CurrentIndex);
        Assert.Equal(loads, provider.Engine.Loads.Count);
        Assert.Equal(seeks, provider.Engine.Seeks.Count);
        Assert.Equal(PlaybackState.Playing, player.State);

        // Redo removes it again, and Undo brings it back once more.
        Assert.Equal($"Remove “{t1.Track.Title}”", undo.RedoActionName);
        undo.Redo();
        Assert.Equal(["t0", "x0", "r0", "r1", "r2"], Ids(player.Queue));
        undo.Undo();
        Assert.Equal(before, player.Queue);
    });

    [Fact]
    public void RemovingTheCurrentSongStillAdvancesWithoutUndo() => OnMain(async () =>
    {
        var (player, _) = await QueueWithAutoplay();
        var undo = new UndoStack();
        var current = player.Queue[0];
        player.RemoveUpNext([current.Uid], undo);
        Assert.Equal("x0", player.Current?.ProviderID);
        Assert.DoesNotContain(player.Queue, e => e.Uid == current.Uid);
    });

    // MARK: transport

    [Fact]
    public void PreviousRestartsAfterThreeSeconds() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = MakeTracks(3);
        player.Play(tracks, startAt: 1);
        await player.SettleAsync();
        provider.Engine.PlayUntil(10);
        player.Previous();
        Assert.Equal(tracks[1].Id, player.Current?.Id);
        Assert.Equal(0, provider.Engine.Seeks[^1]);
        player.Previous();
        Assert.Equal(tracks[0].Id, player.Current?.Id);
        player.Previous();
        Assert.Equal(tracks[0].Id, player.Current?.Id);
    });

    [Fact]
    public void SkipWhilePausedStaysPaused() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = MakeTracks(3);
        player.Play(tracks);
        await player.SettleAsync();
        player.Pause();
        Assert.Equal(PlaybackState.Paused, player.State);
        player.Next();
        await player.SettleAsync();
        Assert.Equal(new FakeEngine.LoadCall(tracks[1].Id, 0, false), provider.Engine.LastLoad);
        Assert.Equal(PlaybackState.Paused, player.State);
    });

    [Fact]
    public void FinishAdvancesAndPlays() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = MakeTracks(2);
        player.Play(tracks);
        await player.SettleAsync();
        provider.Engine.Finish();
        await player.SettleAsync();
        Assert.Equal(tracks[1].Id, player.Current?.Id);
        Assert.True(provider.Engine.LastLoad?.Autoplay);
    });

    [Fact]
    public void EndOfQueueStopsAndResumeRestarts() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = MakeTracks(2);
        player.Play(tracks, startAt: 1);
        await player.SettleAsync();
        provider.Engine.Finish();
        Assert.Equal(PlaybackState.Ended, player.State);
        Assert.Equal(1, provider.Engine.Stops);
        Assert.False(player.IsPlaying);
        player.TogglePlayPause();
        await player.SettleAsync();
        Assert.Equal(tracks[0].Id, player.Current?.Id);
        Assert.Equal(PlaybackState.Playing, player.State);
    });

    [Fact]
    public void RepeatAllWraps() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = MakeTracks(2);
        player.RepeatMode = RepeatMode.All;
        player.Play(tracks, startAt: 1);
        await player.SettleAsync();
        Assert.Equal((true, tracks[0].Id), provider.Engine.LastPrepared);
        provider.Engine.Finish();
        await player.SettleAsync();
        Assert.Equal(0, player.CurrentIndex);
        player.Next();
        player.Next();
        Assert.Equal(0, player.CurrentIndex);
    });

    [Fact]
    public void RepeatOneReplaysOnFinishButNextAdvances() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = MakeTracks(3);
        player.Play(tracks);
        await player.SettleAsync();
        player.RepeatMode = RepeatMode.One;
        Assert.Equal((true, (string?)null), provider.Engine.LastPrepared);
        provider.Engine.PlayUntil(50);
        provider.Engine.Finish();
        await player.SettleAsync();
        Assert.Equal(tracks[0].Id, player.Current?.Id);
        Assert.Single(provider.Engine.Loads);
        Assert.Equal(0, provider.Engine.Seeks[^1]);
        Assert.Equal(0, player.CurrentTime);
        player.Next();
        await player.SettleAsync();
        Assert.Equal(tracks[1].Id, player.Current?.Id);
    });

    [Fact]
    public void SeekClampsToDuration() => OnMain(async () =>
    {
        var (player, provider) = Make();
        player.Play(MakeTracks(1, duration: 100));
        await player.SettleAsync();
        player.Seek(500);
        Assert.Equal(100, player.CurrentTime);
        player.Skip(-250);
        Assert.Equal(0, player.CurrentTime);
        Assert.Equal([100, 0], provider.Engine.Seeks);
    });

    // MARK: shuffle

    [Fact]
    public void ShuffleKeepsHistoryAndCurrent() => OnMain(() =>
    {
        var (player, _) = Make();
        var tracks = MakeTracks(12);
        player.Play(tracks, startAt: 4);
        var history = player.PreviousEntries.Select(e => e.Uid).ToList();
        player.Shuffle = true;
        Assert.Equal(history, player.PreviousEntries.Select(e => e.Uid));
        Assert.Equal(tracks[4].Id, player.Current?.Id);
        Assert.Equal(tracks.Skip(5).Select(t => t.Id).ToHashSet(), player.UpNext.Select(e => e.Track.Id).ToHashSet());
        player.Shuffle = false;
        Assert.Equal(tracks.Select(t => t.Id), player.Queue.Select(e => e.Track.Id));
        return Task.CompletedTask;
    });

    [Fact]
    public void UnshuffleAfterSkippingKeepsWhatWasHeard() => OnMain(() =>
    {
        var (player, _) = Make();
        var tracks = MakeTracks(10);
        player.Play(tracks, shuffled: true);
        var start = player.Current!;
        player.Next();
        player.Next();
        var heard = player.Queue.Take(player.CurrentIndex!.Value + 1).Select(e => e.Uid).ToList();
        player.Shuffle = false;
        // History (what was actually played) and the current entry stay put.
        var through = player.Queue.Take(player.CurrentIndex!.Value + 1).ToList();
        Assert.Equal(heard, through.Select(e => e.Uid));
        // Up Next is the rest, back in album order.
        var rest = tracks.Where(t => !through.Any(e => e.Track.Id == t.Id)).Select(t => t.Id);
        Assert.Equal(rest, player.UpNext.Select(e => e.Track.Id));
        Assert.Equal(start.Id, player.Queue[0].Track.Id);
        return Task.CompletedTask;
    });

    [Fact]
    public void ShufflePinsPlayNextAndKeepsAutoplayLast() => OnMain(async () =>
    {
        var (player, provider) = Make(autoplay: true);
        provider.RadioResult = MakeTracks(3, prefix: "r");
        var album = MakeTracks(10, prefix: "c");
        player.Play(album);
        await player.SettleAsync();
        // Reach the end so autoplay appends radio, then go back to the start of the album.
        player.Jump(player.Queue[9].Uid);
        await player.SettleAsync();
        Assert.Equal(13, player.Queue.Count);
        player.Jump(player.Queue[0].Uid);
        await player.SettleAsync();
        var pinned = MakeTracks(2, prefix: "p");
        player.PlayNext(pinned);

        player.Shuffle = true;
        Assert.Equal(pinned.Select(t => t.Id), player.UpNext.Take(2).Select(e => e.Track.Id));
        Assert.Equal(album.Skip(1).Select(t => t.Id).ToHashSet(), player.UpNext.Skip(2).Take(9).Select(e => e.Track.Id).ToHashSet());
        Assert.All(player.Queue.TakeLast(3), e => Assert.True(e.IsAutoplay));

        // Play Next while shuffled lands next and stays next after unshuffle.
        var x = MakeTracks(1, prefix: "x");
        player.PlayNext(x);
        player.Shuffle = false;
        Assert.Equal(
            x.Concat(pinned).Concat(album.Skip(1)).Concat(MakeTracks(3, prefix: "r")).Select(t => t.Id),
            player.UpNext.Select(e => e.Track.Id));
    });

    [Fact]
    public void PlayShuffledPutsChosenTrackFirst() => OnMain(() =>
    {
        var (player, _) = Make();
        var tracks = MakeTracks(20);
        player.Play(tracks, startAt: 7, shuffled: true);
        Assert.Equal(0, player.CurrentIndex);
        Assert.Equal(tracks[7].Id, player.Current?.Id);
        Assert.True(player.Shuffle);
        Assert.Equal(tracks.Select(t => t.Id).ToHashSet(), player.Queue.Select(e => e.Track.Id).ToHashSet());
        // A new play keeps shuffle on unless told otherwise.
        player.Play(MakeTracks(5, prefix: "n"), startAt: 0);
        Assert.True(player.Shuffle);
        player.Play(MakeTracks(5, prefix: "m"), shuffled: false);
        Assert.False(player.Shuffle);
        Assert.Equal("youtubeMusic:m0", player.Current?.Id);
        return Task.CompletedTask;
    });

    // MARK: failures

    [Fact]
    public void FailedLoadsSkipToNextPlayable() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = MakeTracks(4);
        provider.Engine.FailingIds = [tracks[0].Id, tracks[1].Id];
        player.Play(tracks);
        await player.SettleAsync();
        Assert.Equal(tracks[2].Id, player.Current?.Id);
        Assert.Equal(PlaybackState.Playing, player.State);
        Assert.Equal(tracks.Take(3).Select(t => t.Id), provider.Engine.Loads.Select(l => l.TrackId));
    });

    [Fact]
    public void AllFailingStopsWithoutLooping() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = MakeTracks(3);
        provider.Engine.FailingIds = tracks.Select(t => t.Id).ToHashSet();
        player.RepeatMode = RepeatMode.All;
        player.Play(tracks);
        await player.SettleAsync();
        Assert.Equal(PlaybackState.Failed, player.State);
        Assert.Equal(3, provider.Engine.Loads.Count);
        Assert.Contains("fake failure", player.LastError);
        // Long queue: gives up after MaxConsecutiveFailures.
        var many = MakeTracks(20, prefix: "m");
        provider.Engine.FailingIds = many.Select(t => t.Id).ToHashSet();
        player.Play(many);
        await player.SettleAsync();
        Assert.Equal(3 + PlayerController.MaxConsecutiveFailures, provider.Engine.Loads.Count);
        Assert.Equal(PlaybackState.Failed, player.State);
    });

    [Fact]
    public void SkipAfterGivingUpTriesTheNextTrack() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = MakeTracks(7);
        provider.Engine.FailingIds = tracks.Select(t => t.Id).ToHashSet();
        player.Play(tracks);
        await player.SettleAsync();
        // Gave up after MaxConsecutiveFailures, on the 5th entry.
        Assert.Equal(PlaybackState.Failed, player.State);
        Assert.Equal(PlayerController.MaxConsecutiveFailures - 1, player.CurrentIndex);
        provider.Engine.FailingIds = [];
        player.Next();
        await player.SettleAsync();
        Assert.Equal(PlayerController.MaxConsecutiveFailures, player.CurrentIndex);
        Assert.Equal(PlaybackState.Playing, player.State);
    });

    [Fact]
    public void MidTrackFailureSkips() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = MakeTracks(3);
        player.Play(tracks);
        await player.SettleAsync();
        provider.Engine.FailMidTrack();
        await player.SettleAsync();
        Assert.Equal(tracks[1].Id, player.Current?.Id);
        Assert.Equal(PlaybackState.Playing, player.State);
    });

    [Fact]
    public void MissingProviderCountsAsFailure() => OnMain(async () =>
    {
        var (player, _) = Make();
        var spotify = MakeTracks(1, prefix: "s", provider: ProviderId.Spotify);
        var ytm = MakeTracks(1, prefix: "y");
        player.Play([.. spotify, .. ytm]);
        await player.SettleAsync();
        Assert.Equal(ytm[0].Id, player.Current?.Id);
    });

    // MARK: races and providers

    [Fact]
    public void RapidSkipsSettleOnTheLastTrack() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = MakeTracks(6);
        provider.Engine.HoldLoads = true;
        // Each load reaches the engine before the next skip, so three of them go stale mid-flight.
        player.Play(tracks);
        Assert.True(await WaitUntil(() => provider.Engine.HeldCount == 1));
        player.Next();
        Assert.True(await WaitUntil(() => provider.Engine.HeldCount == 2));
        player.Next();
        Assert.True(await WaitUntil(() => provider.Engine.HeldCount == 3));
        player.Next();
        Assert.Equal(tracks[3].Id, player.Current?.Id);
        Assert.True(await WaitUntil(() => provider.Engine.HeldCount == 4));
        // Finish the newest first, then let the stale ones complete.
        provider.Engine.Release(3);
        await WaitUntil(() => player.State == PlaybackState.Playing);
        var prepareCount = provider.Engine.Prepared.Count;
        provider.Engine.Release(0);
        provider.Engine.Release(0);
        provider.Engine.Release(0);
        await player.SettleAsync();
        await Task.Delay(50);
        Assert.Equal(tracks[3].Id, player.Current?.Id);
        Assert.Equal(3, player.CurrentIndex);
        // Stale loads finishing late don't re-prepare old neighbors.
        Assert.Equal(prepareCount, provider.Engine.Prepared.Count);
        Assert.Equal((true, tracks[4].Id), provider.Engine.LastPrepared);
    });

    [Fact]
    public void SkipsBeforeTheLoadTaskRunsNeverReachTheEngine() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var tracks = MakeTracks(4);
        player.Play(tracks);
        player.Next();
        player.Next();
        await player.SettleAsync();
        await Task.Delay(50);
        // The superseded loads would bump the engine's generation and cancel the real one.
        Assert.Equal([tracks[2].Id], provider.Engine.Loads.Select(l => l.TrackId));
        Assert.Equal(tracks[2].Id, player.Current?.Id);
        Assert.Equal(PlaybackState.Playing, player.State);
    });

    [Fact]
    public void SwitchingProvidersBeforeTheLoadRunsKeepsTheOldEngineSilent() => OnMain(async () =>
    {
        var player = new PlayerController(_scheduler);
        var ytm = new FakeProvider(ProviderId.YouTubeMusic);
        var spotify = new FakeProvider(ProviderId.Spotify);
        player.Register(ytm);
        player.Register(spotify);
        player.Autoplay = false;
        var a = MakeTracks(1, prefix: "a", provider: ProviderId.YouTubeMusic);
        var b = MakeTracks(1, prefix: "b", provider: ProviderId.Spotify);
        player.Play([.. a, .. b]);
        // Skip to the Spotify track before the queued YouTube load task gets to run.
        player.Next();
        await player.SettleAsync();
        await Task.Delay(50);
        Assert.Empty(ytm.Engine.Loads);
        Assert.Equal([b[0].Id], spotify.Engine.Loads.Select(l => l.TrackId));
        Assert.Equal(b[0].Id, player.Current?.Id);
        Assert.Equal(PlaybackState.Playing, player.State);
    });

    [Fact]
    public void SwitchingProvidersStopsTheOldEngine() => OnMain(async () =>
    {
        var player = new PlayerController(_scheduler);
        var ytm = new FakeProvider(ProviderId.YouTubeMusic);
        var spotify = new FakeProvider(ProviderId.Spotify);
        player.Register(ytm);
        player.Register(spotify);
        player.Autoplay = false;
        var a = MakeTracks(1, prefix: "a", provider: ProviderId.YouTubeMusic);
        var b = MakeTracks(1, prefix: "b", provider: ProviderId.Spotify);
        player.Play([.. a, .. b]);
        await player.SettleAsync();
        // The next track belongs to another engine, so nothing is prepared across providers.
        Assert.Equal((true, (string?)null), ytm.Engine.LastPrepared);
        player.Next();
        await player.SettleAsync();
        Assert.Equal(1, ytm.Engine.Stops);
        Assert.Equal(b[0].Id, spotify.Engine.LastLoad?.TrackId);
        // Late events from the old engine are ignored.
        ytm.Engine.Emit(new PlaybackEvent.StateChanged(PlaybackState.Paused));
        ytm.Engine.Emit(PlaybackEvent.Finished.Instance);
        Assert.Equal(PlaybackState.Playing, player.State);
        Assert.Equal(b[0].Id, player.Current?.Id);
    });

    // MARK: autoplay

    [Fact]
    public void AutoplayAtEndFetchesRadioOnceAndAdvances() => OnMain(async () =>
    {
        var (player, provider) = Make(autoplay: false);
        var tracks = MakeTracks(2);
        player.Play(tracks, startAt: 1);
        await player.SettleAsync();
        provider.RadioResult = [tracks[0], tracks[1], .. MakeTracks(3, prefix: "r"), .. MakeTracks(3, prefix: "r")];
        provider.HoldRadio = true;
        player.Autoplay = true;
        await WaitUntil(() => provider.RadioCalls.Count == 1);
        // Pressing Next repeatedly while the fetch runs doesn't start more fetches or skip ahead.
        player.Next();
        player.Next();
        provider.ReleaseRadio();
        await player.SettleAsync();
        Assert.Single(provider.RadioCalls);
        Assert.Equal(tracks.Concat(MakeTracks(3, prefix: "r")).Select(t => t.Id), player.Queue.Select(e => e.Track.Id));
        Assert.Equal("youtubeMusic:r0", player.Current?.Id);
    });

    /// <summary>Plays the last of two tracks with autoplay on and the radio fetch held, so the queue runs out while the
    /// fetch is pending.</summary>
    private async Task<(PlayerController, FakeProvider)> PlayLastTrackWithRadioHeld()
    {
        var (player, provider) = Make(autoplay: true);
        provider.HoldRadio = true;
        provider.RadioResult = MakeTracks(3, prefix: "r");
        player.Play(MakeTracks(2), startAt: 1);
        await WaitUntil(() => provider.RadioCalls.Count == 1);
        return (player, provider);
    }

    /// <summary>A song picked from History while the queue waits on autoplay radio keeps playing when the radio lands.</summary>
    [Fact]
    public void PlayNowWhileWaitingOnRadioIsNotSkipped() => OnMain(async () =>
    {
        var (player, provider) = await PlayLastTrackWithRadioHeld();
        provider.Engine.Finish();
        var picked = MakeTracks(1, prefix: "h")[0];
        player.PlayNow(picked);
        provider.ReleaseRadio();
        await player.SettleAsync();
        Assert.Equal(picked.Id, player.Current?.Id);
        Assert.Contains("youtubeMusic:r0", player.UpNext.Select(e => e.Track.Id));
    });

    [Fact]
    public void NextWhilePausedOnTheLastTrackCuesRadioPaused() => OnMain(async () =>
    {
        var (player, provider) = await PlayLastTrackWithRadioHeld();
        player.Pause();
        player.Next();
        provider.ReleaseRadio();
        await player.SettleAsync();
        Assert.Equal("youtubeMusic:r0", player.Current?.Id);
        Assert.Equal(new FakeEngine.LoadCall("youtubeMusic:r0", 0, false), provider.Engine.LastLoad);
        Assert.Equal(PlaybackState.Paused, player.State);
    });

    [Fact]
    public void PausingWhileWaitingOnRadioKeepsThePause() => OnMain(async () =>
    {
        var (player, provider) = await PlayLastTrackWithRadioHeld();
        provider.Engine.Finish();
        player.Pause();
        provider.ReleaseRadio();
        await player.SettleAsync();
        Assert.Equal("youtubeMusic:r0", player.Current?.Id);
        Assert.False(provider.Engine.LastLoad?.Autoplay);
        Assert.Equal(PlaybackState.Paused, player.State);
    });

    [Fact]
    public void PlayWhileWaitingOnRadioPlaysTheNextTrack() => OnMain(async () =>
    {
        var (player, provider) = await PlayLastTrackWithRadioHeld();
        player.Pause();
        player.Next();
        player.Resume();
        provider.ReleaseRadio();
        await player.SettleAsync();
        Assert.Equal("youtubeMusic:r0", player.Current?.Id);
        Assert.True(provider.Engine.LastLoad?.Autoplay);
        Assert.Equal(PlaybackState.Playing, player.State);
    });

    [Fact]
    public void StopWhileWaitingOnRadioDoesNotRestart() => OnMain(async () =>
    {
        var (player, provider) = await PlayLastTrackWithRadioHeld();
        var tracks = MakeTracks(2);
        provider.Engine.Finish();
        player.Stop();
        var loads = provider.Engine.Loads.Count;
        provider.ReleaseRadio();
        await player.SettleAsync();
        Assert.Equal(loads, provider.Engine.Loads.Count);
        Assert.Equal(tracks[1].Id, player.Current?.Id);
        Assert.Equal(PlaybackState.Paused, player.State);
        // The radio tracks still join Up Next for when the listener presses Play.
        Assert.Equal(3, player.UpNext.Count);
    });

    [Fact]
    public void AutoplayRadioForAReplacedQueueIsDiscarded() => OnMain(async () =>
    {
        var (player, provider) = Make(autoplay: true);
        provider.HoldRadio = true;
        provider.RadioResult = MakeTracks(3, prefix: "r");
        player.Play(MakeTracks(1, prefix: "old"));
        await WaitUntil(() => provider.RadioCalls.Count == 1);
        var fresh = MakeTracks(5, prefix: "new");
        provider.HoldRadio = false;
        player.Play(fresh);
        provider.ReleaseRadio();
        await player.SettleAsync();
        Assert.DoesNotContain(player.Queue, e => e.Track.Id.Contains(":r"));
        Assert.Equal(fresh.Select(t => t.Id), player.Queue.Select(e => e.Track.Id));
    });

    [Fact]
    public void AutoplayWithEmptyRadioEndsAndDoesNotRefetch() => OnMain(async () =>
    {
        var (player, provider) = Make(autoplay: true);
        provider.RadioResult = [];
        player.Play(MakeTracks(1));
        await player.SettleAsync();
        Assert.Single(provider.RadioCalls);
        provider.Engine.Finish();
        await player.SettleAsync();
        Assert.Equal(PlaybackState.Ended, player.State);
        Assert.Single(provider.RadioCalls);
    });

    // MARK: handoff

    [Fact]
    public void LoadKeepsEntriesAsGivenAndCuesPaused() => OnMain(async () =>
    {
        var (player, provider) = Make();
        var entries = MakeTracks(3).Select((t, i) => new QueueEntry(t, isUserQueued: i == 1)).ToList();
        player.Load(entries, 1, 42, shuffle: true, RepeatMode.All, autoplay: false);
        await player.SettleAsync();
        Assert.Equal(entries.Select(e => e.Uid), player.Queue.Select(e => e.Uid));
        Assert.True(player.Queue[1].IsUserQueued);
        Assert.True(player.Shuffle);
        Assert.Equal(RepeatMode.All, player.RepeatMode);
        Assert.Equal(new FakeEngine.LoadCall(entries[1].Track.Id, 42, false), provider.Engine.LastLoad);
        Assert.Equal(PlaybackState.Paused, player.State);
    });

    [Fact]
    public void PropertyChangesAreRaised() => OnMain(async () =>
    {
        var (player, _) = Make();
        var changed = new HashSet<string?>();
        player.PropertyChanged += (_, e) => changed.Add(e.PropertyName);
        player.Play(MakeTracks(2));
        await player.SettleAsync();
        Assert.Contains(nameof(PlayerController.Queue), changed);
        Assert.Contains(nameof(PlayerController.Current), changed);
        Assert.Contains(nameof(PlayerController.State), changed);
        Assert.Contains(nameof(PlayerController.IsPlaying), changed);
    });
}
