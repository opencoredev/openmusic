using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using Medley.Core;

namespace Medley.App.ViewModels;

/// <summary>Formatting helpers for x:Bind function bindings and view models.</summary>
public static class Format
{
    /// <summary>"3:07", "1:02:03"; "" for unknown.</summary>
    public static string Time(double? seconds)
    {
        if (seconds is not { } s || !double.IsFinite(s) || s < 0) return "";
        var t = TimeSpan.FromSeconds(Math.Floor(s));
        return t.TotalHours >= 1 ? t.ToString(@"h\:mm\:ss", CultureInfo.InvariantCulture) : t.ToString(@"m\:ss", CultureInfo.InvariantCulture);
    }

    /// <summary>"-1:23" remaining.</summary>
    public static string Remaining(double position, double? duration) =>
        duration is { } d && d > 0 ? "-" + Time(Math.Max(0, d - position)) : "";

    public static string AlbumKind(AlbumKind kind) => kind switch
    {
        Core.AlbumKind.Single => "Single",
        Core.AlbumKind.Ep => "EP",
        Core.AlbumKind.Compilation => "Compilation",
        _ => "Album",
    };

    public static string Songs(int count, double totalSeconds)
    {
        var minutes = (int)(totalSeconds / 60);
        return $"{count} song{(count == 1 ? "" : "s")}, {minutes} minute{(minutes == 1 ? "" : "s")}";
    }
}

/// <summary>A card in a shelf or grid: an album, playlist, artist, mix or mood.</summary>
public sealed class CardItem
{
    /// <summary>A card with its own second line (radio stations).</summary>
    public CardItem(MediaItem item, string subtitle) : this(item) => Subtitle = subtitle;

    /// <summary>A station played before (Radio › Your Stations).</summary>
    public Services.AppSettings.RecentStation? Station { get; init; }

    public CardItem(MediaItem item)
    {
        Item = item;
        Title = item.Title;
        Subtitle = item switch
        {
            MediaItem.AlbumItem a => a.Album.Kind == AlbumKind.Album
                ? a.Album.ArtistLine
                : $"{Format.AlbumKind(a.Album.Kind)} · {a.Album.ArtistLine}",
            MediaItem.PlaylistItem p => p.Playlist.Summary ?? p.Playlist.Owner ?? "",
            MediaItem.ArtistItem a => a.Artist.Subtitle ?? "Artist",
            MediaItem.TrackItem t => t.Track.ArtistLine,
            _ => "",
        };
        // Cards are 172 px (a hero card 360): the smallest rendition that covers them at 2x, not a 600 px file.
        Artwork = item.Artwork?.Url(360);
        IsArtist = item is MediaItem.ArtistItem;
        if (item is MediaItem.PlaylistItem { Playlist: var pl } && pl.Extra.TryGetValue("category", out var cat) && cat == "1")
        {
            IsCategory = true;
            CategoryColor = pl.Extra.GetValueOrDefault("color") ?? "#808080";
        }
    }

    public MediaItem Item { get; }
    public string Title { get; }
    public string Subtitle { get; private set; }
    /// <summary>The list item's accessible name (UI Automation reads ToString when the template sets none).</summary>
    public override string ToString() => Subtitle.Length > 0 ? $"{Title}, {Subtitle}" : Title;
    public Uri? Artwork { get; }
    public bool IsArtist { get; }
    public bool IsCategory { get; }
    public string CategoryColor { get; } = "#808080";
}

/// <summary>A song row in a list (album, playlist, search, library, shelf).</summary>
public sealed partial class TrackRow : ObservableObject
{
    public TrackRow(Track track, int index, bool showNumber = false)
    {
        Track = track;
        Index = index;
        Number = showNumber ? (track.TrackNumber ?? index + 1).ToString(CultureInfo.InvariantCulture) : "";
        Title = track.Title;
        Artist = track.ArtistLine;
        Album = track.Album?.Title ?? "";
        DurationText = Format.Time(track.Duration);
        Artwork = track.Artwork?.Url(120);
        IsExplicit = track.IsExplicit;
    }

    /// <summary>The length the row shows: the listing's, or the stream's once one said otherwise
    /// (<see cref="KnownLengths"/>); <see cref="NowPlayingMarker"/> keeps it current.</summary>
    [ObservableProperty]
    public partial string DurationText { get; set; }

    internal void ApplyKnownLength(KnownLengths lengths) => DurationText = Format.Time(lengths.DisplayDuration(Track));

    public Track Track { get; }
    public int Index { get; }
    public string Number { get; }
    public string Title { get; }
    public string Artist { get; }
    /// <summary>The list item's accessible name (UI Automation reads ToString when the template sets none).</summary>
    public override string ToString() => Artist.Length > 0 ? $"{Title}, {Artist}" : Title;
    public string Album { get; }
    public Uri? Artwork { get; }
    public bool IsExplicit { get; }
    /// <summary>On album pages: the song's artists differ from the album's (a feature), so the row names them.</summary>
    public bool ShowArtist { get; init; }

    /// <summary>True while this row's song is the current one (the row's title is semibold, with an indicator).</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IndicatorGlyph))]
    public partial bool IsCurrent { get; set; }

    /// <summary>The current song is playing here (a speaker), not paused (a pause mark).</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IndicatorGlyph))]
    public partial bool IsPlaying { get; set; }

    public string IndicatorGlyph => IsPlaying ? "\uE995" : "\uE769";
}

/// <summary>One shelf on Home, New, an artist page or search results.</summary>
public sealed class ShelfModel
{
    public ShelfModel(Shelf shelf)
    {
        Shelf = shelf;
        Title = shelf.Title;
        Subtitle = shelf.Subtitle;
        Style = shelf.Style;
        Cards = shelf.Style == ShelfStyle.TrackList ? [] : shelf.Items.Select(i => new CardItem(i)).ToList();
        Tracks = shelf.Style == ShelfStyle.TrackList
            ? shelf.Items.OfType<MediaItem.TrackItem>().Select((t, i) => new TrackRow(t.Track, i)).ToList()
            : [];
    }

    public static ShelfModel Of(string id, string title, ShelfStyle style, IEnumerable<MediaItem> items, string? subtitle = null) =>
        new(new Shelf(id, title, style, items.ToList()) { Subtitle = subtitle });

    public Shelf Shelf { get; }
    public string Title { get; }
    public string? Subtitle { get; }
    public override string ToString() => Title;
    public ShelfStyle Style { get; }
    public IReadOnlyList<CardItem> Cards { get; }
    public IReadOnlyList<TrackRow> Tracks { get; }
}

/// <summary>A lyric line in the lyrics pane or Now Playing.</summary>
public sealed partial class LyricRow : ObservableObject
{
    public LyricRow(LyricLine line, int index)
    {
        Line = line;
        Index = index;
        Text = line.Text.Length == 0 ? "♪" : line.Text;
    }

    public LyricLine Line { get; }
    public int Index { get; }
    public string Text { get; }
    public override string ToString() => Text;

    [ObservableProperty]
    public partial bool IsCurrent { get; set; }

    [ObservableProperty]
    public partial bool IsPast { get; set; }
}

/// <summary>An Up Next or History row.</summary>
public sealed partial class QueueRow : ObservableObject
{
    public QueueRow(QueueEntry entry)
    {
        Entry = entry;
        Title = entry.Track.Title;
        Artist = entry.Track.ArtistLine;
        Artwork = entry.Track.Artwork?.Url(120);
        DurationText = Format.Time(entry.Track.Duration);
    }

    public QueueEntry Entry { get; }
    public string Title { get; }
    public string Artist { get; }
    public override string ToString() => Artist.Length > 0 ? $"{Title}, {Artist}" : Title;
    public Uri? Artwork { get; }
    public string DurationText { get; }
}

/// <summary>A row in the search box's suggestions: a query completion or a direct match.</summary>
public sealed class SearchSuggestion
{
    public string Text { get; private init; } = "";
    public string Detail { get; private init; } = "";
    public MediaItem? Item { get; private init; }
    public Uri? Artwork { get; private init; }
    public bool IsQuery => Item is null;
    public bool HasArtwork => Item is not null;
    public bool HasDetail => Detail.Length > 0;
    public Microsoft.UI.Xaml.CornerRadius Corner => Item is MediaItem.ArtistItem ? new(16) : new(4);

    public static SearchSuggestion ForQuery(string text) => new() { Text = text };

    /// <summary>A recent search (shown with a clock instead of the magnifier).</summary>
    public static SearchSuggestion ForRecent(string text) => new() { Text = text, IsRecent = true };

    public bool IsRecent { get; private init; }
    public string QueryGlyph => IsRecent ? "\uE81C" : "\uE721";

    public static SearchSuggestion ForItem(MediaItem item) => new()
    {
        Item = item,
        Text = item.Title,
        Detail = item switch
        {
            MediaItem.ArtistItem => "Artist",
            MediaItem.TrackItem t => $"Song · {t.Track.ArtistLine}",
            MediaItem.AlbumItem a => $"{Format.AlbumKind(a.Album.Kind)} · {a.Album.ArtistLine}",
            MediaItem.PlaylistItem p => $"Playlist · {p.Playlist.Owner}",
            _ => "",
        },
        Artwork = item.Artwork?.Url(64),
    };

    public override string ToString() => Text;
}
