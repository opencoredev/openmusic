using OpenMusic.App.Controls;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;

namespace OpenMusic.App;

/// <summary>The mini player: an always-on-top compact overlay window (AppWindow's CompactOverlay presenter) with the
/// cover, the song and the transport.</summary>
public sealed class MiniPlayerWindow : Window
{
    public MiniPlayerView View { get; }

    public MiniPlayerWindow()
    {
        Title = $"{OpenMusic.Core.ProductInfo.Name} Mini Player";
        View = new MiniPlayerView();
        Content = View;
        SystemBackdrop = new MicaBackdrop { Kind = MicaKind.Base };
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(View.DragElement);
        var icon = Path.Combine(AppContext.BaseDirectory, "Assets", "OpenMusic.ico");
        if (File.Exists(icon)) AppWindow.SetIcon(icon);
        var presenter = CompactOverlayPresenter.Create();
        presenter.InitialSize = CompactOverlaySize.Medium;
        AppWindow.SetPresenter(presenter);
        var scale = Interop.Native.GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        // 320 wide; 344 high leaves room for the time under the progress line.
        AppWindow.Resize(new SizeInt32((int)(320 * scale), (int)(344 * scale)));
        AppWindow.TitleBar.ButtonBackgroundColor = Microsoft.UI.Colors.Transparent;
        AppWindow.TitleBar.ButtonInactiveBackgroundColor = Microsoft.UI.Colors.Transparent;
        AppWindow.TitleBar.ButtonForegroundColor = Microsoft.UI.Colors.White;
    }
}
