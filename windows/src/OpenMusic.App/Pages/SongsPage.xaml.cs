using OpenMusic.App.ViewModels;
using OpenMusic.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace OpenMusic.App.Pages;

public sealed partial class SongsPage : Page
{
    public const string Songs = "songs";
    public const string Liked = "liked";

    private string? _kind;
    private int _version = -1;

    public LibraryViewModel ViewModel { get; } = new();

    public SongsPage()
    {
        InitializeComponent();
        // Rows start at the page inset (36 px, PagePadding): 28 here plus the row's own 8.
        SongsList.Padding = new Thickness(28, 0, 28, 24);
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        var kind = e.Parameter as string ?? Songs;
        if (kind == _kind && _version == App.Services.SessionVersion) return;
        _kind = kind;
        _version = App.Services.SessionVersion;
        Heading.Text = kind == Liked ? "Liked Songs" : "Songs";
        await ViewModel.LoadSongsAsync(kind == Liked ? LibraryKind.LikedSongs : LibraryKind.Songs);
        SongsList.Context = new PlaybackContext(kind == Liked ? PlaybackContextKind.LikedSongs : PlaybackContextKind.Library, Heading.Text);
        SongsList.Rows = ViewModel.Songs;
    }

    private void Play_Click(object sender, RoutedEventArgs e) =>
        App.Services.Player.Play(ViewModel.Songs.Select(r => r.Track).ToList(), shuffled: false, context: SongsList.Context);

    private void Shuffle_Click(object sender, RoutedEventArgs e) =>
        App.Services.Player.Play(ViewModel.Songs.Select(r => r.Track).ToList(), shuffled: true, context: SongsList.Context);
}
