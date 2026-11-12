using OpenMusic.App.ViewModels;
using OpenMusic.Core;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace OpenMusic.App.Pages;

public sealed partial class LibraryGridPage : Page
{
    public const string Albums = "albums";
    public const string Artists = "artists";
    public const string Recent = "recent";

    private string? _kind;

    public LibraryViewModel ViewModel { get; } = new();

    public LibraryGridPage()
    {
        InitializeComponent();
        Controls.ListHelpers.AttachContextMenu(Grid, item => item is CardItem card ? Services.MediaMenus.For(card.Item) : null);
    }

    private int _version = -1;

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        var kind = e.Parameter as string ?? Albums;
        if (kind == _kind && _version == App.Services.SessionVersion) return;
        _kind = kind;
        _version = App.Services.SessionVersion;
        Heading.Text = kind switch { Artists => "Artists", Recent => "Recently Added", _ => "Albums" };
        await ViewModel.LoadCardsAsync(kind == Artists ? LibraryKind.Artists : LibraryKind.Albums, newestFirst: kind == Recent);
    }

    /// <summary>The cards' size at this width: as many columns as fit at 156 px or more, widened to fill the row (about
    /// Home's 172 px at most window sizes), 16 px apart.</summary>
    private double _art = 172;

    private const double Gap = 16, MinimumArt = 156, TextHeight = 72, RowGap = 24;

    private void Grid_SizeChanged(object sender, Microsoft.UI.Xaml.SizeChangedEventArgs e) => Fit(e.NewSize.Width);

    private void Fit(double width)
    {
        var usable = width - Grid.Padding.Left - Grid.Padding.Right;
        if (usable <= 0) return;
        // Each cell is a card plus the 16 px gap on its right (the panel lays out whole cells, the last gap too).
        var columns = Math.Max(2, Math.Floor(usable / (MinimumArt + Gap)));
        var cell = Math.Floor(usable / columns);
        _art = cell - Gap;
        if (Grid.ItemsPanelRoot is ItemsWrapGrid panel)
        {
            panel.ItemWidth = cell;
            panel.ItemHeight = _art + TextHeight + RowGap;
            foreach (var child in panel.Children) Size(child as GridViewItem);
        }
    }

    private void Grid_ContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        // The panel exists only once items arrive: fit it the first time it's there.
        if (Grid.ItemsPanelRoot is ItemsWrapGrid { ItemWidth: double.NaN }) Fit(Grid.ActualWidth);
        Size(args.ItemContainer as GridViewItem);
    }

    private void Size(GridViewItem? item)
    {
        if (item?.ContentTemplateRoot is not StackPanel card || card.Children.FirstOrDefault() is not Microsoft.UI.Xaml.FrameworkElement art) return;
        card.Width = _art;
        art.Width = art.Height = _art;
    }

    private void Grid_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is CardItem card) ShellPage.Current.Open(card.Item);
    }
}
