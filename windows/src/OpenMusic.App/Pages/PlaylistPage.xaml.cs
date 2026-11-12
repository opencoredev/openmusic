using OpenMusic.App.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace OpenMusic.App.Pages;

public sealed partial class PlaylistPage : Page
{
    public PlaylistViewModel ViewModel { get; } = new();

    public PlaylistPage()
    {
        InitializeComponent();
        // Rows start at the page inset (36 px, PagePadding): 28 here plus the row's own 8; the header adds 8 to match.
        Songs.Padding = new Thickness(28, 0, 28, 24);
        SizeChanged += (_, e) => HeaderLayout.Apply(e.NewSize.Width, Cover, HeaderText, TitleText);
        Loaded += (_, _) => ViewModel.PlayState.Attach();
        Unloaded += (_, _) => ViewModel.PlayState.Detach();
        // Long playlists load their next page as the list nears its end.
        Songs.NearEnd += () => _ = ViewModel.LoadMoreAsync();
        Songs.Removed += () => _ = ViewModel.ReloadAsync();
        Songs.Rows = ViewModel.Tracks;
        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(PlaylistViewModel.Playlist))
            {
                Songs.Context = ViewModel.Context;
                Songs.Playlist = ViewModel.Playlist;
            }
        };
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        if (e.Parameter is not string id) return;
        await ViewModel.LoadAsync(id);
    }

    private void Play_Click(object sender, RoutedEventArgs e) => ViewModel.PlayState.Press();

    private void More_Click(object sender, RoutedEventArgs e)
    {
        if (ViewModel.Playlist is { } p) Services.MediaMenus.ForPlaylist(p).ShowAt((FrameworkElement)sender);
    }
}
