using Medley.App.ViewModels;
using Medley.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Medley.App.Controls;

public sealed partial class TrackList : UserControl
{
    private IReadOnlyList<TrackRow> _rows = [];
    private bool _numbered;

    public TrackList()
    {
        InitializeComponent();
        // A UserControl doesn't apply its own Padding: it belongs to the list (and its header), so pages can inset rows.
        RegisterPropertyChangedCallback(PaddingProperty, (_, _) => List.Padding = Padding);
        ListHelpers.AttachContextMenu(List, item => item is TrackRow row
            ? Services.MediaMenus.ForTrack(row.Track, () => (_rows.Select(r => r.Track).ToList(), row.Index, Context), Playlist, Removed)
            : null);
        ListHelpers.OnNearEnd(List, () => NearEnd?.Invoke());
    }

    /// <summary>The playlist these rows belong to: its songs' menus offer Remove from Playlist when it's editable.</summary>
    internal Playlist? Playlist { get; set; }

    /// <summary>A song was removed from <see cref="Playlist"/> through its menu.</summary>
    public event Action? Removed;

    /// <summary>The list's own scroller came near its end (load the next page).</summary>
    public event Action? NearEnd;

    /// <summary>Album style: track numbers instead of covers, no album column.</summary>
    public bool Numbered
    {
        get => _numbered;
        set
        {
            _numbered = value;
            List.ItemTemplate = (DataTemplate)Resources[value ? "NumberedTemplate" : "CoverTemplate"];
        }
    }

    /// <summary>Content above the rows. Setting it makes the list the page's (virtualized) scroller.</summary>
    public object? Header
    {
        get => List.Header;
        set
        {
            List.Header = value;
            ScrollViewer.SetVerticalScrollMode(List, ScrollMode.Enabled);
        }
    }

    /// <summary>Lists inside a page's own scroller don't scroll themselves.</summary>
    public bool Embedded
    {
        set
        {
            ScrollViewer.SetVerticalScrollMode(List, value ? ScrollMode.Disabled : ScrollMode.Enabled);
            ScrollViewer.SetVerticalScrollBarVisibility(List, value ? ScrollBarVisibility.Disabled : ScrollBarVisibility.Auto);
        }
    }

    internal PlaybackContext? Context { get; set; }

    public IReadOnlyList<TrackRow> Rows
    {
        get => _rows;
        set
        {
            if (_rows is System.Collections.Specialized.INotifyCollectionChanged old) old.CollectionChanged -= Rows_CollectionChanged;
            _rows = value;
            List.ItemsSource = value;
            NowPlayingMarker.Track(value);
            if (value is System.Collections.Specialized.INotifyCollectionChanged live) live.CollectionChanged += Rows_CollectionChanged;
        }
    }

    private void Rows_CollectionChanged(object? sender, System.Collections.Specialized.NotifyCollectionChangedEventArgs e)
    {
        if (e.NewItems is { } added) NowPlayingMarker.Mark(added.OfType<TrackRow>());
    }

    public static Visibility Not(bool value) => value ? Visibility.Collapsed : Visibility.Visible;

    /// <summary>No gap before a title without the explicit mark (its column is empty then).</summary>
    public static double BadgeGap(bool explicitMark) => explicitMark ? 6 : 0;

    public static Visibility VisibleIfText(string text) => string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;

    public static int TitleSpan(string album) => string.IsNullOrEmpty(album) ? 2 : 1;

    /// <summary>The playing row's title is semibold, beside its playing indicator.</summary>
    public static Windows.UI.Text.FontWeight Weight(bool current) => current ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal;

    private void List_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not TrackRow row) return;
        App.Services.Player.Play(_rows.Select(r => r.Track).ToList(), startAt: row.Index, context: Context);
    }
}
