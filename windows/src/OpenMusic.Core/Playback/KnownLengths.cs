using System.ComponentModel;

namespace OpenMusic.Core;

/// <summary>
/// The real length of each song, learned from its stream (by <see cref="Track.Id"/>), for rows anywhere in the app.
/// A service's listing can be wrong about a song (YouTube Music lists Veridis Quo at 5:46 while its video plays 6:46).
/// Once a stream said how long a song is, rows show that length. Each song has its own observable slot, so a row
/// re-renders only when its own song's length is learned. Session only. Port of KnownLengths.swift.
/// </summary>
public sealed class KnownLengths
{
    /// <summary>Beyond this a listed length and the real one are different recordings worth explaining.</summary>
    public const double NoteThreshold = 10;

    /// <summary>One song's learned length. Bind a row to <see cref="Seconds"/> to follow that song only.</summary>
    public sealed class Slot : INotifyPropertyChanged
    {
        private double? _seconds;

        public double? Seconds
        {
            get => _seconds;
            internal set
            {
                _seconds = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Seconds)));
            }
        }

        public event PropertyChangedEventHandler? PropertyChanged;
    }

    private readonly Dictionary<string, Slot> _slots = [];

    /// <summary>Raised when a song's length is learned or changes: (track id, seconds). One subscription can keep any
    /// number of rows current without each row holding a slot.</summary>
    public event Action<string, double>? Learned;

    /// <summary>The stream length learned for <paramref name="trackId"/>, null until one is.</summary>
    public double? Length(string trackId) => SlotFor(trackId).Seconds;

    /// <summary>Records the stream length. Repeats and sub-second jitter don't count as a change.</summary>
    public void Learn(double seconds, string trackId)
    {
        if (!double.IsFinite(seconds) || seconds <= 0) return;
        var slot = SlotFor(trackId);
        if (slot.Seconds is { } known && Math.Abs(known - seconds) < 0.5) return;
        slot.Seconds = seconds;
        Learned?.Invoke(trackId, seconds);
    }

    /// <summary>The length a row should show: the listing's while the stream agrees with it (within
    /// <see cref="PlayerController.DurationTolerance"/>) or hasn't been heard from, otherwise the stream's.</summary>
    public double? DisplayDuration(Track track) => PlayerController.ReconciledDuration(track.Duration, Length(track.Id));

    /// <summary>When the stream is more than <see cref="NoteThreshold"/> away from the listing, both lengths.</summary>
    public (double Listed, double Real)? Mismatch(Track track)
    {
        if (track.Duration is not { } listed || !double.IsFinite(listed) || listed <= 0) return null;
        if (Length(track.Id) is not { } real || Math.Abs(real - listed) <= NoteThreshold) return null;
        return (listed, real);
    }

    public Slot SlotFor(string trackId)
    {
        if (_slots.TryGetValue(trackId, out var s)) return s;
        s = new Slot();
        _slots[trackId] = s;
        return s;
    }
}
