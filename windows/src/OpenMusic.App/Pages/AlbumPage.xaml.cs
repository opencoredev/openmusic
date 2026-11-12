using OpenMusic.App.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace OpenMusic.App.Pages;

public sealed partial class AlbumPage : Page
{
    public AlbumViewModel ViewModel { get; } = new();

    public AlbumPage()
    {
        InitializeComponent();
        Songs.Numbered = true;
        Cover.Translation = new System.Numerics.Vector3(0, 0, 16);
        Cover.Shadow = new Microsoft.UI.Xaml.Media.ThemeShadow();
        Songs.Embedded = true;
        SizeChanged += (_, e) => HeaderLayout.Apply(e.NewSize.Width, Cover, HeaderText, TitleText);
        Loaded += (_, _) => ViewModel.PlayState.Attach();
        Unloaded += (_, _) => ViewModel.PlayState.Detach();
    }

    private void Play_Click(object sender, RoutedEventArgs e) => ViewModel.PlayState.Press();

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        if (e.Parameter is not string id) return;
        await ViewModel.LoadAsync(id);
        Songs.Context = ViewModel.Context;
        Songs.Rows = ViewModel.Tracks;
        MoreBy.Shelf = ViewModel.MoreByArtist;
        MoreBy.Visibility = ViewModel.MoreByArtist is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private void Artist_Click(object sender, RoutedEventArgs e) => ViewModel.OpenArtist();

    /// <summary>The whole album description, which the page cuts at three lines.</summary>
    private async void MoreSummary_Click(object sender, RoutedEventArgs e)
    {
        var text = new TextBlock { Text = ViewModel.Summary, TextWrapping = TextWrapping.Wrap, LineHeight = 22, IsTextSelectionEnabled = true };
        var panel = new StackPanel { Spacing = 12, MaxWidth = 560 };
        panel.Children.Add(text);
        if (ViewModel.Footnote.Length > 0) panel.Children.Add(new TextBlock { Text = ViewModel.Footnote, Style = Ui.Style("OpenMusicSecondaryCaptionStyle") });
        var dialog = new ContentDialog
        {
            Title = ViewModel.Title,
            Content = new ScrollViewer { Content = panel, MaxHeight = 480 },
            CloseButtonText = "Close",
            DefaultButton = ContentDialogButton.Close,
        };
        await Services.Dialogs.ShowAsync(dialog);
    }

    private void More_Click(object sender, RoutedEventArgs e)
    {
        if (ViewModel.Album is { } album) Services.MediaMenus.ForAlbum(album).ShowAt((FrameworkElement)sender);
    }
}
