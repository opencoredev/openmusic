using OpenMusic.App.ViewModels;
using OpenMusic.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace OpenMusic.App.Controls;

public sealed partial class ShelfView : UserControl
{
    private ShelfModel? _shelf;

    public ShelfView()
    {
        InitializeComponent();
        ListHelpers.AttachContextMenu(Cards, item => item is CardItem card && !card.IsCategory ? Services.MediaMenus.For(card.Item) : null);
        ListHelpers.AttachContextMenu(Songs, item => item is TrackRow row && _shelf is { } shelf
            ? Services.MediaMenus.ForTrack(row.Track, () => (shelf.Tracks.Select(t => t.Track).ToList(), row.Index, Context ?? new PlaybackContext(PlaybackContextKind.Other, shelf.Title)))
            : null);
    }

    public ShelfModel? Shelf
    {
        get => _shelf;
        set
        {
            if (ReferenceEquals(_shelf, value)) return;
            _shelf = value;
            Apply();
        }
    }

    /// <summary>The playback context for songs started from this shelf.</summary>
    internal PlaybackContext? Context { get; set; }

    private void Apply()
    {
        if (_shelf is not { } s) return;
        TitleText.Text = s.Title;
        SubtitleText.Text = s.Subtitle ?? "";
        SubtitleText.Visibility = string.IsNullOrEmpty(s.Subtitle) ? Visibility.Collapsed : Visibility.Visible;
        SeeAll.Visibility = s.Shelf.MoreToken is null ? Visibility.Collapsed : Visibility.Visible;
        var songs = s.Style == ShelfStyle.TrackList;
        Songs.Visibility = songs ? Visibility.Visible : Visibility.Collapsed;
        Cards.Visibility = songs ? Visibility.Collapsed : Visibility.Visible;
        if (songs)
        {
            Songs.ItemsSource = s.Tracks;
            Songs.Height = Math.Min(4, Math.Max(1, s.Tracks.Count)) * 60 + 8;
            Songs.Loaded -= Songs_Loaded;
            Songs.Loaded += Songs_Loaded;
            NowPlayingMarker.Track(s.Tracks);
        }
        else
        {
            Cards.ItemTemplate = (DataTemplate)Resources[s.Style switch
            {
                ShelfStyle.Artists => "ArtistTemplate",
                ShelfStyle.Hero => "HeroTemplate",
                _ => "CardTemplate",
            }];
            Cards.ItemsSource = s.Cards;
        }
    }

    public static CornerRadius CardCorner(bool round) => new(round ? 86 : 8);

    public static HorizontalAlignment CardAlignment(bool center) => center ? HorizontalAlignment.Center : HorizontalAlignment.Left;

    public static Visibility Not(bool value) => value ? Visibility.Collapsed : Visibility.Visible;

    public static Brush CategoryBrush(string hex)
    {
        var h = hex.TrimStart('#');
        if (h.Length != 6 || !uint.TryParse(h, System.Globalization.NumberStyles.HexNumber, null, out var rgb)) rgb = 0x808080;
        var c = Windows.UI.Color.FromArgb(0xFF, (byte)(rgb >> 16), (byte)(rgb >> 8 & 0xFF), (byte)(rgb & 0xFF));
        var dark = Windows.UI.Color.FromArgb(0xFF, (byte)(c.R * 0.55), (byte)(c.G * 0.55), (byte)(c.B * 0.55));
        return new LinearGradientBrush
        {
            StartPoint = new Windows.Foundation.Point(0, 0),
            EndPoint = new Windows.Foundation.Point(1, 1),
            GradientStops = { new GradientStop { Color = c, Offset = 0 }, new GradientStop { Color = dark, Offset = 1 } },
        };
    }

    /// <summary>Song shelves show whole columns: as many 300 px ones as fit, widened to fill the shelf, so no column is cut
    /// at its right edge (the next ones come by scrolling).</summary>
    private void Songs_SizeChanged(object sender, SizeChangedEventArgs e) => FitSongColumns(e.NewSize.Width);

    private void Songs_Loaded(object sender, RoutedEventArgs e) => FitSongColumns(Songs.ActualWidth);

    private void FitSongColumns(double width)
    {
        if (width <= 0 || Songs.ItemsPanelRoot is not ItemsWrapGrid grid) return;
        const double gutter = 16, minimum = 300;
        var usable = width - 12; // the list runs 6 px past the shelf on each side
        var columns = Math.Max(1, Math.Floor((usable + gutter) / (minimum + gutter)));
        var itemWidth = Math.Floor((usable + gutter) / columns);
        if (Math.Abs(grid.ItemWidth - itemWidth) > 0.5) grid.ItemWidth = itemWidth;
    }

    private void Card_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is CardItem card) ShellPage.Current.Open(card.Item);
    }

    private void Song_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not TrackRow row || _shelf is null) return;
        var tracks = _shelf.Tracks.Select(t => t.Track).ToList();
        App.Services.Player.Play(tracks, startAt: row.Index, context: Context ?? new PlaybackContext(PlaybackContextKind.Other, _shelf.Title));
    }

    private void SeeAll_Click(object sender, RoutedEventArgs e)
    {
        if (_shelf?.Shelf.MoreToken is { } token) ShellPage.Current.Navigate("search", "shelf:" + token);
    }
}
