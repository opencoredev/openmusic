using Medley.Core;

namespace Medley.App.ViewModels;

/// <summary>Marks the rows whose song is playing (<see cref="TrackRow.IsCurrent"/>) across every list on screen, keeps
/// them marked as the song changes, and gives rows the real length once a stream reports one (KnownLengths.Learned).
/// Lists register their rows; rows of pages that went away are dropped.</summary>
public static class NowPlayingMarker
{
    private static readonly List<WeakReference<IReadOnlyList<TrackRow>>> Lists = [];
    private static string? _currentId;
    private static bool _playing;
    private static bool _attached;

    public static void Track(IReadOnlyList<TrackRow> rows)
    {
        Attach();
        // A recycled shelf view tracks the same model's rows again: register each list once.
        Lists.RemoveAll(w => !w.TryGetTarget(out _));
        if (!Lists.Any(w => w.TryGetTarget(out var known) && ReferenceEquals(known, rows)))
            Lists.Add(new WeakReference<IReadOnlyList<TrackRow>>(rows));
        var lengths = App.Services.Player.KnownLengths;
        foreach (var row in rows)
        {
            row.IsCurrent = row.Track.Id == _currentId;
            row.IsPlaying = row.IsCurrent && _playing;
            if (lengths.Length(row.Track.Id) is not null) row.ApplyKnownLength(lengths);
        }
    }

    /// <summary>Rows added to a list already tracked (a playlist's later pages).</summary>
    public static void Mark(IEnumerable<TrackRow> rows)
    {
        var lengths = App.Services.Player.KnownLengths;
        foreach (var row in rows)
        {
            row.IsCurrent = row.Track.Id == _currentId;
            row.IsPlaying = row.IsCurrent && _playing;
            if (lengths.Length(row.Track.Id) is not null) row.ApplyKnownLength(lengths);
        }
    }

    private static void Attach()
    {
        if (_attached) return;
        _attached = true;
        var player = App.Services.Player;
        _currentId = player.Current?.Id;
        _playing = player.IsPlaying;
        player.KnownLengths.Learned += (trackId, seconds) =>
        {
            Lists.RemoveAll(w => !w.TryGetTarget(out _));
            foreach (var weak in Lists)
            {
                if (!weak.TryGetTarget(out var rows)) continue;
                foreach (var row in rows)
                    if (row.Track.Id == trackId) row.ApplyKnownLength(player.KnownLengths);
            }
        };
        player.AddChangeHandler(change =>
        {
            if (change is not (PlayerChange.Track or PlayerChange.State)) return;
            if (player.Current?.Id == _currentId && player.IsPlaying == _playing) return;
            _currentId = player.Current?.Id;
            _playing = player.IsPlaying;
            Lists.RemoveAll(w => !w.TryGetTarget(out _));
            foreach (var weak in Lists)
            {
                if (!weak.TryGetTarget(out var rows)) continue;
                foreach (var row in rows)
                {
                    row.IsCurrent = row.Track.Id == _currentId;
                    row.IsPlaying = row.IsCurrent && _playing;
                }
            }
        });
    }
}
