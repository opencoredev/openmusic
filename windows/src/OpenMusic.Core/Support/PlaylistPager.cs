namespace OpenMusic.Core.Support;

/// <summary>
/// A playlist's pages after the first (Swift: <c>PlaylistPager</c> in the Mac app): the songs, the next token, and
/// whether a request runs. Single-threaded: drive it from the UI thread.
/// <list type="bullet">
/// <item>Each song is listed once, by <see cref="Track.Id"/>: generated YouTube mixes (RDCLAK…) and hand-made playlists
/// can hold a song twice, on one page or across pages. The first place wins and <see cref="Copies"/> counts the rest.</item>
/// <item>A token the service already handed out (or hands back unchanged) ends the list instead of looping.</item>
/// <item>Opening loads the rest at once only for a playlist whose total is known and at most <see cref="EagerLoadLimit"/>
/// songs, for at most <see cref="EagerPageBudget"/> pages; longer ones load as the list scrolls to its end.</item>
/// <item>A request overtaken by a newer one, or cancelled, publishes nothing.</item>
/// </list>
/// </summary>
public sealed class PlaylistPager
{
    public const int EagerLoadLimit = 200;
    public const int EagerPageBudget = 8;
    public const int EmptyPageBudget = 5;

    private readonly List<Track> _tracks = [];
    private readonly HashSet<string> _ids = new(StringComparer.Ordinal);
    private readonly HashSet<string> _usedTokens = new(StringComparer.Ordinal);
    private readonly Dictionary<string, int> _copies = new(StringComparer.Ordinal);
    private int _generation;

    public PlaylistPager(IReadOnlyList<Track> firstPage, string? continuation, int? knownTotal, int? entryCount = null)
    {
        KnownTotal = knownTotal;
        Continuation = continuation;
        EntriesSeen = entryCount ?? firstPage.Count;
        FirstPageCount = Append(firstPage);
    }

    public PlaylistPager(PlaylistDetail detail)
        : this(detail.Tracks, detail.Continuation, detail.Playlist.TrackCount, detail.EntryCount) { }

    /// <summary>Every song listed so far, each once, in playlist order.</summary>
    public IReadOnlyList<Track> Tracks => _tracks;
    public int FirstPageCount { get; }
    public int? KnownTotal { get; }
    public string? Continuation { get; private set; }
    public bool IsLoading { get; private set; }
    /// <summary>The last request's failure. Loading stops until <see cref="ClearError"/>.</summary>
    public string? Error { get; private set; }
    public int PagesLoaded { get; private set; }
    public int EagerPages { get; private set; }
    public int EmptyPages { get; private set; }
    public bool StoppedOnRepeatedToken { get; private set; }
    /// <summary>Every entry the service listed, repeats included.</summary>
    public int EntriesSeen { get; private set; }
    public IReadOnlyDictionary<string, int> Copies => _copies;

    /// <summary>The header's song count: the service's total of entries, or the entries listed so far.</summary>
    public int EntryTotal => KnownTotal ?? EntriesSeen;

    public bool IsComplete => Continuation is null && !StoppedOnRepeatedToken && (KnownTotal is not { } total || EntriesSeen >= total);

    public bool WantsEagerPage =>
        _tracks.Count > 0 && Continuation is not null && Error is null && EagerPages < EagerPageBudget
        && KnownTotal is { } total && total <= EagerLoadLimit;

    public bool WantsEmptyPage =>
        _tracks.Count == 0 && Continuation is not null && Error is null && EmptyPages < EmptyPageBudget && EagerPages < EagerPageBudget;

    /// <summary>More to load when the listener scrolls to the end.</summary>
    public bool HasMore => Continuation is not null && Error is null;

    public void ClearError() => Error = null;

    /// <summary>Fetches the next page and appends its new songs. Returns how many rows it added (0 when nothing changed).</summary>
    public async Task<int> LoadNextAsync(Func<string, CancellationToken, Task<Page<Track>>> fetch, bool eager = false, bool empty = false,
        CancellationToken ct = default)
    {
        if (Error is not null || Continuation is not { } token || ct.IsCancellationRequested) return 0;
        var mine = ++_generation;
        IsLoading = true;
        Page<Track>? page = null;
        Exception? failure = null;
        try
        {
            page = await fetch(token, ct);
        }
        catch (Exception e)
        {
            failure = e;
        }
        // Overtaken by a newer request (which owns IsLoading now): publish nothing.
        if (mine != _generation) return 0;
        IsLoading = false;
        if (ct.IsCancellationRequested || failure is OperationCanceledException) return 0;
        if (failure is not null)
        {
            Error = failure.Message;
            return 0;
        }
        _usedTokens.Add(token);
        var added = Append(page!.Items);
        EntriesSeen += page.EntryCount ?? page.Items.Count;
        if (page.Continuation is { } next && _usedTokens.Contains(next))
        {
            Continuation = null;
            StoppedOnRepeatedToken = true;
        }
        else
        {
            Continuation = page.Continuation;
        }
        PagesLoaded++;
        if (eager || empty) EagerPages++;
        if (empty) EmptyPages++;
        return added;
    }

    private int Append(IReadOnlyList<Track> items)
    {
        var added = 0;
        foreach (var track in items)
        {
            _copies[track.Id] = _copies.GetValueOrDefault(track.Id) + 1;
            if (!_ids.Add(track.Id)) continue;
            _tracks.Add(track);
            added++;
        }
        return added;
    }
}
