using Medley.App.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Medley.App.Controls;

public sealed partial class MiniPlayerView : UserControl
{
    public PlayerViewModel Player { get; } = App.Services.PlayerViewModel;

    public UIElement DragElement => DragRegion;

    public MiniPlayerView()
    {
        InitializeComponent();
        // Start with focus on Play, without a keyboard focus rectangle on the first button.
        Loaded += (_, _) => PlayButton.Focus(FocusState.Programmatic);
    }

    private void BackToMain_Click(object sender, RoutedEventArgs e)
    {
        App.MainWindow?.Activate();
        App.MainWindow?.MiniPlayer?.Close();
    }
}
