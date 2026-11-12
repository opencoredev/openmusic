using Medley.App.Controls;
using Medley.App.ViewModels;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace Medley.App.Pages;

public sealed partial class ArtistPage : Page
{
    public ArtistViewModel ViewModel { get; } = new();

    public ArtistPage()
    {
        InitializeComponent();
        TopSongs.Embedded = true;
        SizeChanged += (_, e) =>
        {
            var side = e.NewSize.Width < 760 ? 140 : 200;
            Portrait.Width = Portrait.Height = side;
            Portrait.CornerRadius = new Microsoft.UI.Xaml.CornerRadius(side / 2);
        };
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        if (e.Parameter is not string id) return;
        await ViewModel.LoadAsync(id);
        TopSongs.Context = ViewModel.Context;
        TopSongs.Rows = ViewModel.TopTracks;
        ShelfHost.Children.Clear();
        foreach (var shelf in ViewModel.Shelves) ShelfHost.Children.Add(new ShelfView { Shelf = shelf });
    }
}
