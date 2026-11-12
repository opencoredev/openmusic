using Medley.App.Interop;
using Medley.App.Services;
using Microsoft.UI;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using WinRT.Interop;

namespace Medley.App;

/// <summary>
/// The main window: Mica Alt backdrop, content extended into the title bar (the shell draws its own, with back and
/// search), the media controls (SMTC) and the taskbar thumbnail buttons. The UI itself is <see cref="ShellPage"/>.
/// </summary>
public sealed class MainWindow : Window
{
    private readonly WindowHook _hook;
    private MiniPlayerWindow? _mini;

    public ShellPage Shell { get; }
    public IntPtr Hwnd { get; }

    public MainWindow()
    {
        var services = App.Services;
        Title = Medley.Core.ProductInfo.Name;
        Hwnd = WindowNative.GetWindowHandle(this);
        _hook = new WindowHook(Hwnd) { AllowOversize = services.Options.IsSnapshot, MinimumSize = (800, 560) };

        SystemBackdrop = new MicaBackdrop { Kind = MicaKind.BaseAlt };
        ExtendsContentIntoTitleBar = true;
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        var icon = Path.Combine(AppContext.BaseDirectory, "Assets", "Medley.ico");
        if (File.Exists(icon)) AppWindow.SetIcon(icon);

        Shell = new ShellPage(this);
        Content = Shell;
        SetTitleBar(Shell.TitleBarElement);

        var (w, h) = services.Options.IsSnapshot ? (1440, 900) : services.Options.Size ?? (1320, 860);
        ResizeClient(w, h);
        if (!services.Options.IsSnapshot) CenterOnScreen();

        _ = new TaskbarButtons(Hwnd, _hook, services.Player);
        _ = new SystemMediaControls(services.Engine.Player, services.Player, services.Dispatcher);

        var theme = services.Options.Theme ?? services.Settings.Values.Theme;
        if (theme is "dark" or "light") SetTheme(theme == "dark" ? ElementTheme.Dark : ElementTheme.Light);
        // Medley Sync heartbeats run while the window is in use (or playing): minimized or hidden, it goes quiet.
        AppWindow.Changed += (_, e) =>
        {
            if (e.DidPresenterChange || e.DidVisibilityChange) UpdateForeground();
        };
        VisibilityChanged += (_, _) => UpdateForeground();
        Closed += (_, _) =>
        {
            services.Persistence?.FlushSynchronously();
            _mini?.Close();
            services.Engine.Dispose();
        };
        Activated += (_, e) =>
        {
            UpdateCaptionColors();
            if (e.WindowActivationState != WindowActivationState.Deactivated) UpdateForeground();
        };
        if (services.Options.Mini) services.Dispatcher.TryEnqueue(ShowMiniPlayer);
    }

    private bool? _foreground;

    private void UpdateForeground()
    {
        var minimized = AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized };
        var inUse = AppWindow.IsVisible && !minimized;
        if (inUse == _foreground || App.Services.Sync is not { } sync) return;
        _foreground = inUse;
        _ = sync.Service.SetForegroundAsync(inUse);
    }

    /// <summary>Brings the window to the front (a second launch, the sign-in link coming back).</summary>
    public void BringToFront()
    {
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } p) p.Restore();
        Activate();
        Native.SetForegroundWindow(Hwnd);
    }

    /// <summary>Sizes the client area in effective pixels (scaled by the monitor's DPI).</summary>
    public void ResizeClient(int width, int height)
    {
        var scale = Native.GetDpiForWindow(Hwnd) / 96.0;
        AppWindow.ResizeClient(new SizeInt32((int)Math.Round(width * scale), (int)Math.Round(height * scale)));
    }

    private void CenterOnScreen()
    {
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Nearest).WorkArea;
        var size = AppWindow.Size;
        AppWindow.Move(new PointInt32(area.X + Math.Max(0, (area.Width - size.Width) / 2), area.Y + Math.Max(0, (area.Height - size.Height) / 2)));
    }

    public void SetTheme(ElementTheme theme)
    {
        Shell.RequestedTheme = theme;
        if (_mini?.Content is FrameworkElement mini) mini.RequestedTheme = theme;
        UpdateCaptionColors();
    }

    /// <summary>The caption buttons (minimize, maximize, close) follow the app's theme, not the system's.</summary>
    public void UpdateCaptionColors()
    {
        var dark = Shell.ActualTheme == ElementTheme.Dark;
        var bar = AppWindow.TitleBar;
        bar.ButtonBackgroundColor = Colors.Transparent;
        bar.ButtonInactiveBackgroundColor = Colors.Transparent;
        bar.ButtonForegroundColor = dark ? Colors.White : Colors.Black;
        bar.ButtonInactiveForegroundColor = dark ? ColorHelper.FromArgb(0x80, 0xFF, 0xFF, 0xFF) : ColorHelper.FromArgb(0x80, 0, 0, 0);
        bar.ButtonHoverBackgroundColor = dark ? ColorHelper.FromArgb(0x18, 0xFF, 0xFF, 0xFF) : ColorHelper.FromArgb(0x10, 0, 0, 0);
        bar.ButtonHoverForegroundColor = bar.ButtonForegroundColor;
        bar.ButtonPressedBackgroundColor = dark ? ColorHelper.FromArgb(0x10, 0xFF, 0xFF, 0xFF) : ColorHelper.FromArgb(0x0A, 0, 0, 0);
        bar.ButtonPressedForegroundColor = bar.ButtonForegroundColor;
    }

    public void ShowMiniPlayer()
    {
        if (_mini is null)
        {
            _mini = new MiniPlayerWindow();
            _mini.Closed += (_, _) => _mini = null;
            if (_mini.Content is FrameworkElement root) root.RequestedTheme = Shell.RequestedTheme;
        }
        _mini.Activate();
    }

    public MiniPlayerWindow? MiniPlayer => _mini;
}
