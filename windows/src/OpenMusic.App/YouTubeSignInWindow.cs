using OpenMusic.App.Services;
using OpenMusic.Core;
using OpenMusic.Providers.YouTube;
using OpenMusic.Providers.YouTube.Auth;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.Web.WebView2.Core;
using Windows.Graphics;

namespace OpenMusic.App;

/// <summary>
/// Sign in to YouTube Music: Google's own sign-in page in WebView2 (the only web view the app has), then YouTube's
/// account and channel picker when the Google account has more than one. Follows the provider's <c>WebSignIn</c> flow:
/// cookies are read once the page lands on music.youtube.com, handed to <see cref="YouTubeMusicProvider.SignInWithWebCookiesAsync"/>,
/// and committed for the chosen account.
/// <para>The web view keeps its own persistent profile (%LOCALAPPDATA%\OpenMusic\WebView2-signin), so signing in again is
/// one click. Its cookies never leave the profile except into the provider, which saves them with DPAPI; nothing is
/// logged. Sign-out clears the profile (<see cref="ClearWebProfileAsync"/>) so the next sign-in can pick another account.</para>
/// </summary>
public sealed class YouTubeSignInWindow : Window
{
    private static readonly string ProfileFolder = Path.Combine(AppServices.DataDirectory, "WebView2-signin");
    private static readonly string ClearMarker = Path.Combine(AppServices.DataDirectory, "WebView2-signin.clear");
    private static YouTubeSignInWindow? _open;

    private readonly YouTubeMusicProvider _provider;
    private readonly WebView2 _web = new();
    private readonly Grid _picker = new() { Visibility = Visibility.Collapsed, Padding = new Thickness(32, 24, 32, 24), RowSpacing = 12 };
    private readonly ListView _accounts = new() { SelectionMode = ListViewSelectionMode.None, IsItemClickEnabled = true };
    private readonly InfoBar _status = new() { IsClosable = false, Margin = new Thickness(12, 8, 12, 0) };
    private readonly ProgressBar _progress = new() { IsIndeterminate = true, Visibility = Visibility.Collapsed, VerticalAlignment = VerticalAlignment.Top };
    private bool _delivered;
    private bool _finished;
    private int _attempt;

    /// <summary>Raised once when the sign-in committed (the window then closes itself).</summary>
    public event Action<AccountInfo?>? SignedIn;

#if DEBUG
    /// <summary>Debug self-test: closes the sign-in window if it's open.</summary>
    public static void CloseOpen() => _open?.Close();

    public static IntPtr? OpenHandle => _open is { } w ? WinRT.Interop.WindowNative.GetWindowHandle(w) : null;
#endif

    public static void Show(YouTubeMusicProvider provider, ElementTheme theme)
    {
        if (_open is { } existing)
        {
            existing.Activate();
            return;
        }
        var window = new YouTubeSignInWindow(provider, theme);
        _open = window;
        window.Activate();
    }

    /// <summary>The system title bar in the app's theme, not Windows' (OpenMusic can be dark on a light system).</summary>
    private void ApplyTitleBarTheme(ElementTheme theme)
    {
        var dark = theme == ElementTheme.Dark
            || theme == ElementTheme.Default && Application.Current.RequestedTheme == ApplicationTheme.Dark;
        var bar = AppWindow.TitleBar;
        var background = dark ? Windows.UI.Color.FromArgb(0xFF, 0x20, 0x20, 0x20) : Windows.UI.Color.FromArgb(0xFF, 0xF3, 0xF3, 0xF3);
        var foreground = dark ? Microsoft.UI.Colors.White : Microsoft.UI.Colors.Black;
        var dim = dark ? Windows.UI.Color.FromArgb(0x80, 0xFF, 0xFF, 0xFF) : Windows.UI.Color.FromArgb(0x80, 0, 0, 0);
        bar.BackgroundColor = bar.InactiveBackgroundColor = bar.ButtonBackgroundColor = bar.ButtonInactiveBackgroundColor = background;
        bar.ForegroundColor = bar.ButtonForegroundColor = bar.ButtonHoverForegroundColor = bar.ButtonPressedForegroundColor = foreground;
        bar.InactiveForegroundColor = bar.ButtonInactiveForegroundColor = dim;
        bar.ButtonHoverBackgroundColor = dark ? Windows.UI.Color.FromArgb(0xFF, 0x2D, 0x2D, 0x2D) : Windows.UI.Color.FromArgb(0xFF, 0xE5, 0xE5, 0xE5);
        bar.ButtonPressedBackgroundColor = dark ? Windows.UI.Color.FromArgb(0xFF, 0x29, 0x29, 0x29) : Windows.UI.Color.FromArgb(0xFF, 0xD9, 0xD9, 0xD9);
    }

    private YouTubeSignInWindow(YouTubeMusicProvider provider, ElementTheme theme)
    {
        _provider = provider;
        Title = "Sign in to YouTube Music";
        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = false;
        ApplyTitleBarTheme(theme);
        var icon = Path.Combine(AppContext.BaseDirectory, "Assets", "OpenMusic.ico");
        if (File.Exists(icon)) AppWindow.SetIcon(icon);
        var scale = Interop.Native.GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        AppWindow.Resize(new SizeInt32((int)(560 * scale), (int)(760 * scale)));

        var root = new Grid { RequestedTheme = theme };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var header = new StackPanel { Padding = new Thickness(24, 16, 24, 8), Spacing = 2 };
        header.Children.Add(new TextBlock { Text = "Sign in to YouTube Music", Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"] });
        header.Children.Add(new TextBlock
        {
            Text = App.Services.Sync?.CanSignOutEverywhere == true
                ? $"Sign in with Google. {ProductInfo.Name} encrypts this sign-in and shares it with the devices you approve."
                : $"Sign in with Google. Windows protects the sign-in {ProductInfo.Name} saves on this PC.",
            Style = Ui.Style("OpenMusicSecondaryCaptionStyle"),
            TextWrapping = TextWrapping.Wrap,
        });
        root.Children.Add(header);

        var body = new Grid();
        Grid.SetRow(body, 1);
        var webFrame = new Border
        {
            Margin = new Thickness(12, 4, 12, 0),
            Style = Ui.Style("OpenMusicFrameStyle"),
            Child = _web,
        };
        body.Children.Add(webFrame);
        body.Children.Add(_progress);
        BuildPicker();
        body.Children.Add(_picker);
        _status.IsOpen = false;
        _status.VerticalAlignment = VerticalAlignment.Bottom;
        body.Children.Add(_status);
        root.Children.Add(body);

        var footer = new Grid { Padding = new Thickness(24, 12, 24, 16), ColumnSpacing = 8 };
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var other = new HyperlinkButton { Content = "Use a different account", VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetAutomationId(other, "SignInDifferentAccount");
        other.Click += async (_, _) => await StartOverAsync();
        var cancel = new Button { Content = "Cancel", MinWidth = 96 };
        AutomationProperties.SetAutomationId(cancel, "SignInCancel");
        cancel.Click += (_, _) => Close();
        Grid.SetColumn(cancel, 1);
        footer.Children.Add(other);
        footer.Children.Add(cancel);
        Grid.SetRow(footer, 2);
        root.Children.Add(footer);
        Content = root;

        Closed += (_, _) =>
        {
            // Every cookie read or sign-in started by this window is over: nothing that finishes later may sign in.
            Invalidate();
            _open = null;
            if (!_finished)
            {
                _provider.DiscardPreparedSignIn();
                _provider.CancelSignIn();
            }
            _web.Close();
        };
        AutomationProperties.SetAutomationId(_web, "SignInWebView");
        _ = InitializeAsync();
    }

    private void BuildPicker()
    {
        _picker.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _picker.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _picker.Style = Ui.Style("OpenMusicSolidPanelStyle");
        var title = new StackPanel { Spacing = 4 };
        title.Children.Add(new TextBlock { Text = "Choose an account", Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"] });
        title.Children.Add(new TextBlock
        { Style = Ui.Style("OpenMusicSecondaryTextStyle"),
            Text = $"Your Google account has more than one YouTube channel. Pick the one {ProductInfo.Name} should use.",
            TextWrapping = TextWrapping.Wrap,
        });
        _picker.Children.Add(title);
        AutomationProperties.SetAutomationId(_accounts, "SignInAccounts");
        _accounts.ItemClick += async (_, e) =>
        {
            if (e.ClickedItem is FrameworkElement { Tag: AccountChoice choice }) await CommitAsync(choice);
        };
        Grid.SetRow(_accounts, 1);
        _picker.Children.Add(_accounts);
    }

    private async Task InitializeAsync()
    {
        try
        {
            Directory.CreateDirectory(ProfileFolder);
            var env = await CoreWebView2Environment.CreateWithOptionsAsync(null, ProfileFolder, new CoreWebView2EnvironmentOptions());
            await _web.EnsureCoreWebView2Async(env);
            var core = _web.CoreWebView2;
            core.Settings.AreDevToolsEnabled = false;
            core.Settings.IsStatusBarEnabled = false;
            core.Settings.AreDefaultContextMenusEnabled = false;
            core.Settings.IsPasswordAutosaveEnabled = false;
            core.Settings.IsGeneralAutofillEnabled = false;
            // New windows (Google's help links) open in the system browser, never in a second web view.
            core.NewWindowRequested += (sender, e) =>
            {
                e.Handled = true;
                if (Uri.TryCreate(e.Uri, UriKind.Absolute, out var u) && u.Scheme == Uri.UriSchemeHttps) _ = Windows.System.Launcher.LaunchUriAsync(u);
            };
            if (File.Exists(ClearMarker))
            {
                await ClearAsync(core);
                File.Delete(ClearMarker);
            }
            _web.NavigationStarting += (_, _) => _progress.Visibility = Visibility.Visible;
            _web.NavigationCompleted += Web_NavigationCompleted;
            _web.Source = WebSignIn.StartUrl;
        }
        catch (Exception e)
        {
            Log.Error($"sign-in window: web view failed: {e.GetType().Name}");
            ShowStatus("Couldn't open Google sign-in", "Microsoft Edge WebView2 is missing or failed to start. Install it from Microsoft, then try again.", InfoBarSeverity.Error);
        }
    }

    private static async Task ClearAsync(CoreWebView2 core)
    {
        core.CookieManager.DeleteAllCookies();
        await core.Profile.ClearBrowsingDataAsync();
    }

    private async void Web_NavigationCompleted(WebView2 sender, CoreWebView2NavigationCompletedEventArgs args)
    {
        _progress.Visibility = Visibility.Collapsed;
        if (_delivered || _finished || _closed || !WebSignIn.IsLanding(sender.Source)) return;
        _delivered = true;
        var attempt = _attempt;
        try
        {
            var cookies = await sender.CoreWebView2.CookieManager.GetCookiesAsync(WebSignIn.CookieUrl.AbsoluteUri);
            if (attempt != _attempt || _finished || _closed) return;
            var web = cookies.Select(c => new WebCookie(c.Name, c.Value, c.Domain)).ToList();
            if (WebSignIn.CredentialsFromCookies(web) is null)
            {
                // Landed on YouTube Music without signing in (Google skipped or the person backed out): keep the page.
                _delivered = false;
                return;
            }
            _progress.Visibility = Visibility.Visible;
            ShowStatus("Signing in…", null, InfoBarSeverity.Informational);
            var choices = await _provider.SignInWithWebCookiesAsync(web);
            if (attempt != _attempt || _finished || _closed)
            {
                // Overtaken while YouTube checked the cookies: hold no prepared choice for a window that's gone.
                _provider.DiscardPreparedSignIn();
                return;
            }
            _progress.Visibility = Visibility.Collapsed;
            if (choices is null)
            {
                Finish();
                return;
            }
            ShowPicker(choices);
        }
        catch (OperationCanceledException)
        {
            // Closed or started over.
        }
        catch (Exception e)
        {
            if (attempt != _attempt) return;
            _progress.Visibility = Visibility.Collapsed;
            _delivered = false;
            Log.Error($"sign-in window: {e.GetType().Name}");
            ShowStatus("Couldn't sign in", e.Message, InfoBarSeverity.Error);
        }
    }

    /// <summary>Drops whatever this window has in flight (a cookie read, a check, the account list).</summary>
    private void Invalidate()
    {
        _attempt++;
        _closed = true;
    }

    private bool _closed;

    private void ShowPicker(AccountChoiceList list)
    {
        _status.IsOpen = false;
        var items = new List<FrameworkElement>();
        foreach (var choice in list.Accounts)
        {
            var row = new Grid { ColumnSpacing = 12, Padding = new Thickness(4, 8, 4, 8), Tag = choice };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var picture = new PersonPicture { Width = 40, Height = 40, DisplayName = choice.Info.Name };
            if (choice.Info.Avatar is { } avatar) picture.ProfilePicture = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(avatar) { DecodePixelWidth = 80 };
            row.Children.Add(picture);
            var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            text.Children.Add(new TextBlock { Text = choice.Info.Name, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
            if (choice.Info.Detail is { Length: > 0 } detail)
                text.Children.Add(new TextBlock { Text = detail, Style = Ui.Style("OpenMusicSecondaryCaptionStyle"), });
            Grid.SetColumn(text, 1);
            row.Children.Add(text);
            AutomationProperties.SetName(row, choice.Info.Name);
            items.Add(row);
        }
        _accounts.ItemsSource = items;
        _picker.Visibility = Visibility.Visible;
    }

    private async Task CommitAsync(AccountChoice choice)
    {
        if (_closed) return;
        _progress.Visibility = Visibility.Visible;
        try
        {
            await _provider.CommitSignInAsync(choice);
            Finish();
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception e)
        {
            _progress.Visibility = Visibility.Collapsed;
            ShowStatus("Couldn't use that account", e.Message, InfoBarSeverity.Error);
        }
    }

    private void Finish()
    {
        _finished = true;
        SignedIn?.Invoke(_provider.AuthStatus.Account);
        App.MainWindow?.Shell.ShowNotice($"Signed in to YouTube Music as {_provider.AuthStatus.Account?.Name ?? "you"}", InfoBarSeverity.Success);
        Close();
    }

    /// <summary>"Use a different account": signs the web view out of Google and opens the account chooser again.</summary>
    private async Task StartOverAsync()
    {
        _attempt++;
        _delivered = false;
        _picker.Visibility = Visibility.Collapsed;
        _status.IsOpen = false;
        _provider.DiscardPreparedSignIn();
        _provider.CancelSignIn();
        if (_web.CoreWebView2 is { } core)
        {
            await ClearAsync(core);
            _web.Source = WebSignIn.StartUrl;
        }
    }

    private void ShowStatus(string title, string? message, InfoBarSeverity severity)
    {
        _status.Title = title;
        _status.Message = message ?? "";
        _status.Severity = severity;
        _status.IsOpen = true;
    }

    /// <summary>
    /// The provider's sign-out hook: signs the web view out of Google too, so the next sign-in can choose another
    /// account. With the window open, its cookies go now; otherwise at the next opening, before anything loads.
    /// </summary>
    public static Task ClearWebProfileAsync()
    {
        // The provider calls this from its own executor; the web view lives on the UI thread.
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!App.Services.Dispatcher.TryEnqueue(async () =>
            {
                await ClearNowAsync();
                done.TrySetResult();
            }))
            done.TrySetResult();
        return done.Task;
    }

    private static async Task ClearNowAsync()
    {
        try
        {
            if (_open?._web.CoreWebView2 is { } core)
            {
                // Signed out while the window is open: what it was delivering belongs to the sign-in that just ended.
                _open._attempt++;
                _open._delivered = false;
                await ClearAsync(core);
                return;
            }
            if (Directory.Exists(ProfileFolder)) await File.WriteAllTextAsync(ClearMarker, "");
        }
        catch (Exception e)
        {
            Log.Error($"sign-in window: couldn't clear the profile: {e.GetType().Name}");
        }
    }
}
