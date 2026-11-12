using Medley.App.Controls;
using Medley.App.ViewModels;
using Medley.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace Medley.App.Pages;

public sealed partial class SearchPage : Page
{
    private string _query = "";
    private bool _loading;

    public SearchViewModel ViewModel { get; } = new();

    public SearchPage()
    {
        InitializeComponent();
        Songs.Embedded = true;
        SizeChanged += (_, e) => Layout(e.NewSize.Width);
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        _query = e.Parameter as string ?? "";
        var isShelf = _query.StartsWith("shelf:", StringComparison.Ordinal);
        Scopes.Visibility = isShelf ? Visibility.Collapsed : Visibility.Visible;
        await Load(SearchScope.All);
    }

    private async Task Load(SearchScope scope)
    {
        _loading = true;
        await ViewModel.LoadAsync(_query, scope);
        _loading = false;
        Heading.Text = _query.StartsWith("shelf:", StringComparison.Ordinal) ? ViewModel.Query : $"Results for “{_query}”";
        var top = ViewModel.Top;
        TopPanel.Visibility = top is null ? Visibility.Collapsed : Visibility.Visible;
        if (top is not null)
        {
            TopArt.Source = top.Artwork;
            TopArt.CornerRadius = new CornerRadius(top.IsArtist ? 60 : 8);
            TopTitle.Text = top.Title;
            TopSubtitle.Text = top.Item switch
            {
                MediaItem.ArtistItem => "Artist",
                MediaItem.AlbumItem a => $"{Format.AlbumKind(a.Album.Kind)} · {a.Album.ArtistLine}",
                MediaItem.TrackItem t => $"Song · {t.Track.ArtistLine}",
                MediaItem.PlaylistItem p => $"Playlist · {p.Playlist.Owner}",
                _ => "",
            };
        }
        SongsPanel.Visibility = ViewModel.Songs.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        Songs.Context = new PlaybackContext(PlaybackContextKind.Search, ViewModel.Query);
        Songs.Rows = ViewModel.Songs;
        TopRow.Visibility = top is null && ViewModel.Songs.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        ShelfHost.Children.Clear();
        foreach (var shelf in ViewModel.Shelves) ShelfHost.Children.Add(new ShelfView { Shelf = shelf });
        Empty.Visibility = ViewModel.IsEmpty ? Visibility.Visible : Visibility.Collapsed;
        Layout(ActualWidth);
    }

    /// <summary>Wide: the top result beside the songs. Narrow (or no top result): one column.</summary>
    private void Layout(double width)
    {
        var hasTop = TopPanel.Visibility == Visibility.Visible;
        var stacked = width < 820 || !hasTop;
        TopColumn.Width = stacked ? new GridLength(1, GridUnitType.Star) : new GridLength(320);
        SongsColumn.Width = stacked ? new GridLength(0) : new GridLength(1, GridUnitType.Star);
        Grid.SetRow(SongsPanel, stacked && hasTop ? 1 : 0);
        Grid.SetColumn(SongsPanel, stacked ? 0 : 1);
        SongsPanel.Margin = new Thickness(0, stacked && hasTop ? 20 : 0, 0, 0);
        TopCard.MaxWidth = stacked ? 420 : double.PositiveInfinity;
        TopCard.HorizontalAlignment = stacked ? HorizontalAlignment.Left : HorizontalAlignment.Stretch;
    }

    private async void Scopes_SelectionChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        if (_loading || _query.Length == 0) return;
        var scope = Enum.TryParse<SearchScope>(sender.SelectedItem?.Tag as string, out var s) ? s : SearchScope.All;
        await Load(scope);
    }

    private void TopCard_Click(object sender, RoutedEventArgs e)
    {
        if (ViewModel.Top is { } top) ShellPage.Current.Open(top.Item);
    }
}
