using Medley.App.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Medley.App.Controls;

public sealed partial class NowPlayingView : UserControl
{
    public PlayerViewModel Player { get; } = App.Services.PlayerViewModel;

    public event Action? CloseRequested;

    public NowPlayingView()
    {
        InitializeComponent();
        Lyrics.Large = true;
        Cover.Translation = new System.Numerics.Vector3(0, 0, 48);
        Cover.Shadow = new Microsoft.UI.Xaml.Media.ThemeShadow();
        SizeChanged += (_, e) => LayoutFor(e.NewSize);
    }

    public void OnShown() => DispatcherQueue.TryEnqueue(() => Lyrics.ScrollTo(Player.CurrentLyricIndex, animate: false));

    /// <summary>Keeps the cover square and as large as fits; narrow windows drop the lyrics column.</summary>
    private void LayoutFor(Windows.Foundation.Size size)
    {
        var narrow = size.Width < 900;
        LyricsColumn.Width = narrow ? new GridLength(0) : new GridLength(6, GridUnitType.Star);
        Lyrics.Visibility = narrow ? Visibility.Collapsed : Visibility.Visible;
        var columnWidth = narrow ? size.Width - 112 : (size.Width - 152) * 5 / 11;
        var side = Math.Max(160, Math.Min(Math.Min(columnWidth, 480), size.Height - 230));
        Cover.Width = side;
        Cover.Height = side;
        ArtPanel.HorizontalAlignment = narrow ? HorizontalAlignment.Center : HorizontalAlignment.Stretch;
    }

    private void Close_Click(object sender, RoutedEventArgs e) => CloseRequested?.Invoke();
}
