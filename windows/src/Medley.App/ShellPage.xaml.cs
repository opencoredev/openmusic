using Medley.App.Controls;
using Medley.App.Pages;
using Medley.App.Services;
using Medley.App.ViewModels;
using Medley.Core;
using Medley.Sync;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Navigation;
using Windows.System;

namespace Medley.App;

/// <summary>
/// The shell: navigation, search, the right pane, Now Playing, the InfoBars above the page and the account menu.
/// Screens navigate through <see cref="Open(MediaItem)"/> and <see cref="Navigate(string, object?)"/> so every page goes
/// through one place.
/// </summary>
public sealed partial class ShellPage : Page
{
    private readonly MainWindow _window;
    private readonly Dictionary<string, NavigationViewItem> _playlistItems = [];
    private bool _syncingSelection;
    private int _suggestionGeneration;
    private Func<Task>? _pageErrorAction;
    private DispatcherTimerLite? _noticeTimer;
    private int _playlistsGeneration;

    public static ShellPage Current { get; private set; } = null!;

    public UIElement TitleBarElement => AppTitleBar;
    public Frame ContentFrameElement => ContentFrame;
    public NowPlayingBarAccess BarAccess => new(Bar);

    public ShellPage(MainWindow window)
    {
        _window = window;
        Current = this;
        InitializeComponent();
        AddHandler(PreviewKeyDownEvent, new KeyEventHandler(Root_PreviewKeyDown), true);
        // No player shortcuts during the first run (its buttons and fields take the keys).
        Shortcuts.Register(this, () => IsTyping(XamlRoot) || IsOnboarding);
        Loaded += OnLoaded;
        SizeChanged += (_, e) => LayoutForWidth(e.NewSize.Width);
        ActualThemeChanged += (_, _) => _window.UpdateCaptionColors();
        Bar.LyricsToggled += on => ShowPane(on ? SidePaneTab.Lyrics : null);
        Bar.QueueToggled += on => ShowPane(on ? SidePaneTab.UpNext : null);
        Bar.NowPlayingRequested += () => ShowNowPlaying(!IsNowPlayingOpen);
        Bar.MiniPlayerRequested += () => _window.ShowMiniPlayer();
        SidePane.CloseRequested += () => ShowPane(null);
        NowPlaying.CloseRequested += () => ShowNowPlaying(false);
        ContinueBar.IsOpen = false;
        ApproveBar.IsOpen = false;
        PageErrorBar.IsOpen = false;
        NoticeBar.IsOpen = false;
        Onboarding.Finished += FinishOnboarding;
        foreach (var bar in new[] { ContinueBar, ApproveBar, PageErrorBar, NoticeBar })
            bar.RegisterPropertyChangedCallback(InfoBar.IsOpenProperty, (_, _) => UpdateInfoBars());
        UpdateInfoBars();
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        var services = App.Services;
        UpdateAccount();
        services.SessionChanged += OnSessionChanged;
        services.Provider.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(IMusicProvider.AuthStatus)) DispatcherQueue.TryEnqueue(UpdateAccount);
        };
        if (services.Sync is { } sync) AttachSync(sync);
        else if (services.Options.DemoSync)
        {
            ContinueBar.Title = "Continue from Riley's iPhone";
            ContinueBar.Message = "One More Time · Daft Punk";
            ContinueBar.IsOpen = true;
        }
        _ = LoadPlaylistsAsync();
        // The first run covers the window from the start (Home loads behind it), so nothing flashes before it.
        if (OnboardingStartStep() is { } first) ShowOnboarding(first);
        var screen = services.Options.Screen ?? "home";
        await OpenScreenAsync(screen);
        if (services.Options.Pane == "lyrics") ShowPane(SidePaneTab.Lyrics);
        if (services.Options.Pane == "queue") ShowPane(SidePaneTab.UpNext);
        if (services.Options.Link is { } link) HandleLink(link);
    }

    /// <summary>Opens a screen by its command-line name (<c>--screen</c>): a tag, or <c>album:&lt;id&gt;</c>,
    /// <c>artist:&lt;id&gt;</c>, <c>playlist:&lt;id&gt;</c>, <c>search:&lt;query&gt;</c>. Demo runs pick sample items.</summary>
    public async Task OpenScreenAsync(string screen)
    {
        var colon = screen.IndexOf(':');
        if (colon > 0)
        {
            var (tag, arg) = (screen[..colon], screen[(colon + 1)..]);
            if (tag == "search") SearchBox.Text = arg;
            Navigate(tag, arg);
            await Task.Yield();
            return;
        }
        var mock = App.Services.Mock;
        switch (screen)
        {
            case "album" when mock is not null:
                Navigate("album", mock.DemoNowPlaying?.Album.ProviderID ?? mock.Catalog.Albums.First().ProviderID);
                break;
            case "artist" when mock is not null:
                Navigate("artist", mock.DemoNowPlaying?.Album.Artists.FirstOrDefault()?.Id ?? mock.Catalog.Artists.First().ProviderID);
                break;
            case "playlist" when mock is not null:
                var playlist = mock.Catalog.Playlists.FirstOrDefault(x => x.IsEditable) ?? mock.Catalog.Playlists.First();
                Navigate("playlist", playlist.ProviderID);
                break;
            case "search":
                var query = mock is not null ? "olivia" : "daft punk";
                SearchBox.Text = query;
                Navigate("search", query);
                break;
            case "nowplaying":
                Navigate("home");
                ShowNowPlaying(true);
                break;
            default:
                Navigate(screen);
                break;
        }
        await Task.Yield();
    }

    // MARK: Account

    private void UpdateAccount()
    {
        var account = App.Services.Provider.AuthStatus.Account;
        AccountPicture.DisplayName = account?.Name ?? "";
        AccountPicture.ProfilePicture = account?.Avatar is { } avatar ? new BitmapImage(avatar) { DecodePixelWidth = 56 } : null;
        ToolTipService.SetToolTip(AccountButton, account is null ? "Sign in" : $"{account.Name}{(account.Detail is { } d ? " · " + d : "")}");
    }

    private void OnSessionChanged()
    {
        UpdateAccount();
        App.Services.PlayerViewModel.RefreshLiked();
        _ = LoadPlaylistsAsync();
        // Pages showing the account's things load again for the new one.
        if (ContentFrame.Content is ShelvesPage or SongsPage or LibraryGridPage or PlaylistPage) Reload();
    }

    /// <summary>Loads the current page again (Try Again, a new account).</summary>
    public void Reload()
    {
        if (ContentFrame.Content is not Page page) return;
        var parameter = ContentFrame.Tag;
        ContentFrame.Tag = null;
        ContentFrame.Navigate(page.GetType(), parameter, new SuppressNavigationTransitionInfo());
        if (ContentFrame.BackStack.Count > 0) ContentFrame.BackStack.RemoveAt(ContentFrame.BackStack.Count - 1);
    }

    private void AccountMenu_Opening(object? sender, object e)
    {
        var menu = AccountMenu;
        menu.Items.Clear();
        var services = App.Services;
        var status = services.Provider.AuthStatus;
        var header = new MenuFlyoutItem
        {
            Text = status.Account is { } account ? $"YouTube Music: {account.Name}" : "YouTube Music: not signed in",
            IsEnabled = false,
            Icon = new FontIcon { Glyph = "\uE8D6" },
        };
        menu.Items.Add(header);
        if (services.YouTube is not null)
        {
            if (status.IsSignedIn)
            {
                menu.Items.Add(Item("Switch Account…", "\uE8AB", () => _ = SwitchYouTubeAccountAsync(), "MenuSwitchYouTube"));
                menu.Items.Add(Item("Sign Out of YouTube Music…", "\uF3B1", () => _ = SignOutOfYouTubeAsync(), "MenuSignOutYouTube"));
            }
            else
            {
                menu.Items.Add(Item("Sign In to YouTube Music…", "\uE77B", SignInToYouTube, "MenuSignInYouTube"));
            }
        }
        if (services.Sync is { } sync)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(sync.Account.User is { } user
                ? new MenuFlyoutItem { Text = $"{ProductInfo.Name}: {user.DisplayName}", IsEnabled = false, Icon = new FontIcon { Glyph = "\uE77B" } }
                : Item($"Sign In to {ProductInfo.Name}…", "\uE8AF", () => _ = SignInToMedleyAsync(), "MenuSignInMedley"));
        }
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item("Settings", "\uE713", () => Navigate("settings"), "MenuSettings"));
        var help = new MenuFlyoutSubItem { Text = "Help", Icon = new FontIcon { Glyph = "\uE897" } };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(help, "MenuHelp");
        var keys = Item("Keyboard Shortcuts", "\uE765", () => _ = Shortcuts.ShowDialogAsync(), "MenuShortcuts");
        keys.KeyboardAcceleratorTextOverride = "Ctrl+/";
        help.Items.Add(keys);
        help.Items.Add(Item($"About {ProductInfo.Name}", "\uE946", () => Navigate("settings", "about"), "MenuAbout"));
        menu.Items.Add(help);
    }

    private static MenuFlyoutItem Item(string text, string glyph, Action run, string id)
    {
        var item = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph } };
        item.Click += (_, _) => run();
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(item, id);
        return item;
    }

    public void OpenAccountMenu() => AccountMenu.ShowAt(AccountButton);

    public void SignInToYouTube()
    {
        if (App.Services.YouTube is { } youtube) YouTubeSignInWindow.Show(youtube, ActualTheme);
    }

    /// <summary>Signs out of YouTube Music here, or on every device when sync can (the question names both).</summary>
    public async Task SignOutOfYouTubeAsync()
    {
        var services = App.Services;
        var sync = services.Sync;
        var everywhere = false;
        if (sync?.CanSignOutEverywhere == true)
        {
            var dialog = new ContentDialog
            {
                Title = "Sign out of YouTube Music?",
                Content = $"Sign out on this PC only, or on all your devices that use {ProductInfo.Name}.",
                PrimaryButtonText = "This PC",
                SecondaryButtonText = "All Devices",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Primary,
            };
            var result = await Dialogs.ShowAsync(dialog);
            if (result == ContentDialogResult.None) return;
            everywhere = result == ContentDialogResult.Secondary;
        }
        try
        {
            if (sync is not null) await sync.SignOutOfYouTubeAsync(everywhere);
            else await services.Provider.TrySignOutAsync();
            ShowNotice(everywhere ? "Signed out of YouTube Music on all your devices" : "Signed out of YouTube Music", InfoBarSeverity.Informational);
        }
        catch (Exception e)
        {
            ShowNotice($"Couldn't remove the saved sign-in. {e.Message}", InfoBarSeverity.Error);
        }
    }

    /// <summary>The accounts and brand channels this sign-in can switch to.</summary>
    public async Task SwitchYouTubeAccountAsync()
    {
        if (App.Services.YouTube is not { } youtube) return;
        try
        {
            var list = await youtube.SwitchableAccountsAsync();
            if (list.Accounts.Count <= 1)
            {
                ShowNotice("This Google account has one YouTube channel. To use another Google account, sign out and sign in again.", InfoBarSeverity.Informational);
                return;
            }
            var picker = new ListView { SelectionMode = ListViewSelectionMode.Single, MaxHeight = 360 };
            foreach (var choice in list.Accounts) picker.Items.Add(new ListViewItem { Content = $"{choice.Info.Name}{(choice.Info.Detail is { } d ? " · " + d : "")}", Tag = choice });
            var dialog = new ContentDialog { Title = "Switch account", Content = picker, PrimaryButtonText = "Switch", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
            if (await Dialogs.ShowAsync(dialog) != ContentDialogResult.Primary || (picker.SelectedItem as ListViewItem)?.Tag is not Medley.Providers.YouTube.Auth.AccountChoice picked) return;
            await youtube.CommitSignInAsync(picked);
            ShowNotice($"Switched to {picked.Info.Name}", InfoBarSeverity.Success);
        }
        catch (Exception e)
        {
            ShowNotice($"Couldn't switch accounts. {e.Message}", InfoBarSeverity.Error);
        }
    }

    public async Task SignInToMedleyAsync()
    {
        if (App.Services.Sync is not { } sync) return;
        if (await MedleySignInDialog.ShowAsync(sync)) await sync.DidSignInAsync();
    }

    // MARK: Sync

    private void AttachSync(SyncHub sync)
    {
        sync.Notice += (text, problem) => ShowNotice(text, problem ? InfoBarSeverity.Warning : InfoBarSeverity.Success);
        sync.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(SyncHub.ContinueSuggestion) or nameof(SyncHub.Service)) UpdateContinueBar();
            if (e.PropertyName is nameof(SyncHub.Service) or nameof(SyncHub.Account)) UpdateApproveBar();
            // Approved since: the "needs to be approved" message is no longer true.
            if (_approvalShown && sync.HasKey)
            {
                _approvalShown = false;
                PageErrorBar.IsOpen = false;
            }
        };
        sync.PlayHereFailed += (device, title, error) => ShowPlayHereFailed(sync, device, title, error);
        // The first run shows the codes on its own Approve step (also when they arrive before it gets there); elsewhere they
        // come up as a dialog.
        sync.CompareRequested += comparison =>
        {
            if (!IsOnboarding) _ = KeyDialogs.CompareAsync(sync, comparison);
        };
        sync.KeyRequested += request => _ = KeyDialogs.AllowAsync(sync, request);
        UpdateContinueBar();
    }

    private string? _continueShown;
    /// <summary>The suggestion a failed Play Here was for: its InfoBar stays closed (the failure's warning, with Try
    /// Again, takes its place) until the other device plays something else.</summary>
    private string? _continueSuppressed;

    /// <summary>One warning for a Play Here that didn't start, in place of the Continue InfoBar: what failed, where it
    /// still plays, and Try Again. The technical reason goes to the log.</summary>
    private void ShowPlayHereFailed(SyncHub sync, Medley.Sync.DeviceId device, string? title, Medley.Sync.SyncException error)
    {
        _continueSuppressed = _continueShown;
        ContinueBar.IsOpen = false;
        var name = sync.DeviceName(device);
        var where = sync.IsPlayingOn(device) ? $"It's still playing on {name}." : $"Nothing changed on {name}.";
        var heading = title is null ? "Couldn't continue here" : $"Couldn't play {title} on this PC";
        // A failure Try Again can't fix (a service not signed in, no sign-in key yet) says why and points to Settings.
        if (error.Kind is Medley.Sync.SyncErrorKind.ProviderUnavailable or Medley.Sync.SyncErrorKind.NeedsKey or Medley.Sync.SyncErrorKind.NotSignedIn)
            ShowPageError(heading, $"{error.Message} {where}", "Open Settings", () =>
            {
                Navigate("settings");
                return Task.CompletedTask;
            });
        else ShowPageError(heading, where, "Try Again", () => sync.PlayHereAsync(device));
    }

    private void UpdateContinueBar()
    {
        var suggestion = App.Services.Sync?.ContinueSuggestion;
        if (suggestion is null)
        {
            _continueShown = null;
            ContinueBar.IsOpen = false;
            return;
        }
        var track = suggestion.Playback.Track;
        var key = $"{suggestion.Device.Id.Value}|{track?.Id ?? "sealed"}|{suggestion.IsPlaying}";
        if (key == _continueSuppressed) return;
        _continueSuppressed = null;
        if (key == _continueShown && ContinueBar.IsOpen) return;
        _continueShown = key;
        ContinueBar.Title = $"Continue from {suggestion.Device.Name}";
        if (track is not null)
        {
            ContinueBar.Message = $"{track.Title} · {track.ArtistLine}{(suggestion.IsPlaying ? "" : " (paused)")}";
        }
        else
        {
            // Sealed: this PC isn't approved yet, so it sees that the device plays and where, not the song.
            var at = App.Services.Sync?.Coordinator.LivePosition(suggestion.Device.Id) is { } p ? $" · {Format.Time(p)}" : "";
            ContinueBar.Message = $"{(suggestion.IsPlaying ? "Playing" : "Paused")} on {suggestion.Device.Name}{at}";
        }
        ContinueBar.Tag = suggestion.Device.Id;
        ContinueBar.IsOpen = true;
    }

    private async void ContinuePlayHere_Click(object sender, RoutedEventArgs e)
    {
        if (App.Services.Sync is not { } sync || ContinueBar.Tag is not Medley.Sync.DeviceId device) return;
        if (!sync.HasKey)
        {
            ShowNeedsApproval(sync.DeviceName(device));
            return;
        }
        ContinuePlayHere.IsEnabled = false;
        try { await sync.PlayHereAsync(device); }
        finally { ContinuePlayHere.IsEnabled = true; }
        UpdateContinueBar();
    }

    private void ContinueBar_CloseButtonClick(InfoBar sender, object args) => App.Services.Sync?.Coordinator.DismissSuggestion();

    /// <summary><c>openmusic://</c> links (the sign-in callback from the browser).</summary>
    public void HandleLink(Uri link)
    {
        Log.Info($"link: {link.Scheme}://{link.Host}");
        if (!BrowserSignIn.HandleCallback(link)) Log.Info("link: not one OpenMusic handles; ignored");
    }

    // MARK: First run

    public bool IsOnboarding => Onboarding.Visibility == Visibility.Visible;

    /// <summary>Where the first run starts at launch, or null when it's done (or this is a demo or snapshot run).</summary>
    private static OnboardingView.Step? OnboardingStartStep()
    {
        var services = App.Services;
        if (services.Options.Onboarding) return OnboardingView.Step.Welcome;
        if (services.IsDemo || services.Options.IsSnapshot || services.Sync is null) return null;
        var values = services.Settings.Values;
        // A restart to switch servers comes back to Sync, even when the flow had been finished before (--onboarding).
        if (values.OnboardingResume == "sync") return OnboardingView.Step.Sync;
        return values.WelcomeDone ? null : OnboardingView.Step.Welcome;
    }

    /// <summary>Shows the first run over the window: the shell's own controls hide (and leave the tab order) until it's done.</summary>
    public void ShowOnboarding(OnboardingView.Step step = OnboardingView.Step.Welcome)
    {
        ShowNowPlaying(false);
        Onboarding.Visibility = Visibility.Visible;
        Nav.Visibility = Visibility.Collapsed;
        Bar.Visibility = Visibility.Collapsed;
        SearchBox.Visibility = Visibility.Collapsed;
        AccountButton.Visibility = Visibility.Collapsed;
        AppTitleBar.IsPaneToggleButtonVisible = false;
        Onboarding.Start(step);
        Log.Info($"onboarding: shown at {step}");
    }

#if DEBUG
    public void OnboardingPreviewApprove(string holder, string code) => Onboarding.PreviewApprove(holder, code);
#endif

    /// <summary>The first run moved to another step: the title bar's Back follows it.</summary>
    public void OnboardingStepChanged()
    {
        if (IsOnboarding) AppTitleBar.IsBackButtonEnabled = Onboarding.CanGoBack;
    }

    private void FinishOnboarding()
    {
        Onboarding.Visibility = Visibility.Collapsed;
        Nav.Visibility = Visibility.Visible;
        Bar.Visibility = Visibility.Visible;
        SearchBox.Visibility = Visibility.Visible;
        AccountButton.Visibility = Visibility.Visible;
        AppTitleBar.IsPaneToggleButtonVisible = true;
        AppTitleBar.IsBackButtonEnabled = ContentFrame.CanGoBack;
        if (ContentFrame.Content?.GetType() != typeof(ShelvesPage)) Navigate("home");
        UpdateContinueBar();
        UpdateApproveBar();
        UpdateAccount();
        // Focus the page quietly, not the first control XAML finds.
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => ContentFrame.Focus(FocusState.Pointer));
    }

    private bool _approveBarDismissed;

    /// <summary>The quiet "Approve this PC" banner: signed in and registered, another device holds the key, this PC doesn't
    /// yet. It stays until the PC is approved (closing it hides it until the next launch).</summary>
    private void UpdateApproveBar()
    {
        if (App.Services.Sync is not { } sync || IsOnboarding)
        {
            ApproveBar.IsOpen = false;
            return;
        }
        var service = sync.Service;
        var needed = sync.Account.IsSignedIn && service.IsRegistered && service.KeyHolders.Count > 0
                     && service.KeyStatus is not (KeyStatus.Available or KeyStatus.None);
        if (!needed || _approveBarDismissed)
        {
            ApproveBar.IsOpen = false;
            if (!needed) _approveBarDismissed = false;
            return;
        }
        var holder = service.KeyStatus is KeyStatus.Comparing c ? c.Comparison.HolderName
            : service.KeyHolders is { Count: 1 } one ? one[0].Name : "your other device";
        ApproveBar.Title = "Approve this PC";
        ApproveBar.Message = service.KeyStatus is KeyStatus.Comparing
            ? $"{holder} is ready: compare the codes to finish."
            : $"Open {ProductInfo.Name} on {holder} to approve this PC. Until then, your sign-ins and what plays elsewhere stay locked here.";
        ApproveBarAction.Content = service.KeyStatus is KeyStatus.Comparing ? "Compare Codes" : "Details";
        ApproveBar.IsOpen = true;
    }

    private void ApproveBar_CloseButtonClick(InfoBar sender, object args) => _approveBarDismissed = true;

    private void ApproveBarAction_Click(object sender, RoutedEventArgs e)
    {
        if (App.Services.Sync is not { } sync) return;
        if (sync.Service.KeyStatus is KeyStatus.Comparing c) _ = KeyDialogs.CompareAsync(sync, c.Comparison);
        else Navigate("settings");
    }

    public void ShowDevices() => Bar.ShowDevices();

    public void CloseDevices() => Bar.CloseDevices();

    // MARK: InfoBars

    /// <summary>A short message above the page: closes by itself after a few seconds unless it's a problem.</summary>
    public void ShowNotice(string text, InfoBarSeverity severity)
    {
        NoticeBar.Title = "";
        NoticeBar.Message = Shown(text);
        NoticeBar.Severity = severity;
        NoticeBar.IsOpen = true;
        _noticeTimer?.Cancel();
        if (severity is InfoBarSeverity.Success or InfoBarSeverity.Informational)
            _noticeTimer = DispatcherTimerLite.After(TimeSpan.FromSeconds(5), () => NoticeBar.IsOpen = false);
    }

    /// <summary>A page couldn't load: say so above it, with an action (Try Again, or Sign In).</summary>
    public void ShowPageError(string title, string message, string action, Func<Task>? run)
    {
        PageErrorBar.Title = title;
        PageErrorBar.Message = Shown(message);
        PageErrorAction.Content = action;
        PageErrorAction.Visibility = run is null ? Visibility.Collapsed : Visibility.Visible;
        _pageErrorAction = run;
        PageErrorBar.Severity = action is "Sign In" or "Open Settings" ? InfoBarSeverity.Informational : InfoBarSeverity.Warning;
        PageErrorBar.IsOpen = true;
    }

    public void ClearPageError() => PageErrorBar.IsOpen = false;

    /// <summary>Play Here before this PC was given the vault key: what plays elsewhere can't be opened here yet.</summary>
    public void ShowNeedsApproval(string deviceName)
    {
        _approvalShown = true;
        ShowPageError("This PC needs to be approved first",
            $"To play what {deviceName} is playing, approve this PC on a device that's already set up. Settings › Account shows how.",
            "Open Settings", () =>
            {
                Navigate("settings");
                return Task.CompletedTask;
            });
    }

    private bool _approvalShown;

    /// <summary>Text for an InfoBar: secrets redacted, and only the first line of a server's error (Convex adds the
    /// request and its validator below it).</summary>
    private static string Shown(string text)
    {
        var redacted = Log.Redact(text);
        var line = redacted.Split('\n', 2)[0].Trim();
        return line.Length > 240 ? line[..240] + "…" : line;
    }

    private async void PageErrorAction_Click(object sender, RoutedEventArgs e)
    {
        PageErrorBar.IsOpen = false;
        if (_pageErrorAction is { } run) await run();
    }

    private void UpdateInfoBars() =>
        InfoBars.Visibility = ContinueBar.IsOpen || ApproveBar.IsOpen || PageErrorBar.IsOpen || NoticeBar.IsOpen ? Visibility.Visible : Visibility.Collapsed;

    // MARK: Playlists in the pane

    private async Task LoadPlaylistsAsync()
    {
        var generation = ++_playlistsGeneration;
        foreach (var item in _playlistItems.Values) Nav.MenuItems.Remove(item);
        _playlistItems.Clear();
        _playlistOrder.Clear();
        _groupChildren.Clear();
        PlaylistsGroup.MenuItems.Clear();
        PlaylistsGroup.Visibility = Visibility.Collapsed;
        // New items: fit them afresh (the last fit was for the old list).
        _shownPlaylists = -1;
        _shownCompact = null;
        var services = App.Services;
        PlaylistsHeader.Visibility = services.Provider.IsSignedIn ? Visibility.Visible : Visibility.Collapsed;
        if (!services.Provider.IsSignedIn) return;
        IReadOnlyList<MediaItem> items;
        try
        {
            var page = await services.Cache.GetAsync("library:playlists", () => services.Provider.LibraryAsync(LibraryKind.Playlists, null));
            items = page.Items;
        }
        catch (Exception e)
        {
            Log.Error($"playlists: {e.Message}");
            return;
        }
        if (generation != _playlistsGeneration) return;
        // The playlists go right after the header, the group item after them.
        Nav.MenuItems.Remove(PlaylistsGroup);
        var index = Nav.MenuItems.IndexOf(PlaylistsHeader) + 1;
        foreach (var item in items.OfType<MediaItem.PlaylistItem>().Where(p => !p.Playlist.IsLikedSongs))
        {
            if (_playlistItems.ContainsKey(item.Playlist.ProviderID)) continue;
            var nav = new NavigationViewItem
            {
                Content = item.Playlist.Title,
                Tag = "playlist:" + item.Playlist.ProviderID,
                Icon = new FontIcon { Glyph = "\uE8FD" },
            };
            ToolTipService.SetToolTip(nav, item.Playlist.Title);
            nav.ContextFlyout = MediaMenus.For(item);
            if (item.Playlist.Artwork?.Url(120) is { } art) _ = SetPlaylistIconAsync(nav, art);
            _playlistItems[item.Playlist.ProviderID] = nav;
            _playlistOrder.Add(nav);
            Nav.MenuItems.Insert(index++, nav);
            var child = new NavigationViewItem { Content = item.Playlist.Title, Tag = nav.Tag, Icon = new FontIcon { Glyph = "\uE8FD" } };
            ToolTipService.SetToolTip(child, item.Playlist.Title);
            if (item.Playlist.Artwork?.Url(120) is { } childArt) _ = SetPlaylistIconAsync(child, childArt);
            _groupChildren.Add(child);
        }
        Nav.MenuItems.Insert(index, PlaylistsGroup);
        UpdatePlaylistsForPane();
        // Once laid out, the pane knows how many rows fit above its footer.
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, UpdatePlaylistsForPane);
    }

    private readonly List<NavigationViewItem> _playlistOrder = [];
    private readonly List<NavigationViewItem> _groupChildren = [];
    private int _shownPlaylists = -1;
    private bool? _shownCompact;

    private void Nav_DisplayModeChanged(NavigationView sender, NavigationViewDisplayModeChangedEventArgs args) => UpdatePlaylistsForPane();

    /// <summary>Expanded, the pane lists the playlists by name, as many as fit in whole rows above the footer, and puts
    /// the rest under a More Playlists item (no row half hidden behind Devices); compact, one Playlists item holds them
    /// all in its flyout.</summary>
    private void UpdatePlaylistsForPane()
    {
        var compact = Nav.DisplayMode != NavigationViewDisplayMode.Expanded;
        var count = _playlistOrder.Count;
        var shown = compact ? 0 : Math.Min(count, PlaylistRowsThatFit(count));
        if (shown == _shownPlaylists && compact == _shownCompact) return;
        _shownPlaylists = shown;
        _shownCompact = compact;
        for (var i = 0; i < count; i++) _playlistOrder[i].Visibility = i < shown ? Visibility.Visible : Visibility.Collapsed;
        PlaylistsGroup.MenuItems.Clear();
        foreach (var child in _groupChildren.Skip(shown)) PlaylistsGroup.MenuItems.Add(child);
        PlaylistsGroup.Content = compact ? "Playlists" : "More Playlists";
        ToolTipService.SetToolTip(PlaylistsGroup, PlaylistsGroup.Content);
        PlaylistsGroup.Visibility = count > shown ? Visibility.Visible : Visibility.Collapsed;
        if (count > 0) PlaylistsHeader.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
    }

    /// <summary>How many playlist rows fit between the Playlists header and the pane's footer, leaving one for More
    /// Playlists when they don't all fit. Unknown before layout: all of them.</summary>
    private int PlaylistRowsThatFit(int count)
    {
        if (Nav.ContainerFromMenuItem(PlaylistsHeader) is not FrameworkElement header || Nav.FooterMenuItems.FirstOrDefault() is not { } first
            || Nav.ContainerFromMenuItem(first) is not FrameworkElement footer || header.ActualHeight <= 0) return count;
        var top = header.TransformToVisual(Nav).TransformPoint(new Windows.Foundation.Point(0, header.ActualHeight)).Y;
        var bottom = footer.TransformToVisual(Nav).TransformPoint(default).Y - 12; // the footer's divider and spacing
        const double row = 40;
        var rows = (int)Math.Floor((bottom - top) / row);
        return rows >= count ? count : Math.Max(0, rows - 1);
    }

    private void Nav_SizeChanged(object sender, SizeChangedEventArgs e) =>
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, UpdatePlaylistsForPane);

    /// <summary>A playlist's cover as its navigation icon, so playlists stay told apart when the pane is compact (the
    /// glyph stays until the cover arrives, or when there is none).</summary>
    private async Task SetPlaylistIconAsync(NavigationViewItem nav, Uri art)
    {
        var scale = XamlRoot?.RasterizationScale ?? 1.0;
        if (await ArtworkLoader.Shared.LoadAsync(art, Art.Bucket(20 * scale)) is { } source)
            nav.Icon = new ImageIcon { Source = source, Width = 20, Height = 20 };
    }

    /// <summary>The playlists changed (New Playlist): list them again.</summary>
    public void RefreshPlaylists()
    {
        App.Services.Cache.Remove("library:playlists");
        _ = LoadPlaylistsAsync();
    }

    public IReadOnlyList<Playlist> KnownPlaylists =>
        App.Services.Cache.TryGet<Page<MediaItem>>("library:playlists", out var page)
            ? page.Items.OfType<MediaItem.PlaylistItem>().Select(p => p.Playlist).Where(p => !p.IsLikedSongs).ToList()
            : [];

    // MARK: Navigation

    public void Navigate(string tag, object? parameter = null)
    {
        ShowNowPlaying(false);
        var (type, arg) = tag switch
        {
            "home" => (typeof(ShelvesPage), (object?)ShelvesPage.Home),
            "new" => (typeof(ShelvesPage), ShelvesPage.New),
            "radio" => (typeof(RadioPage), null),
            "recent" => (typeof(LibraryGridPage), LibraryGridPage.Recent),
            "albums" => (typeof(LibraryGridPage), LibraryGridPage.Albums),
            "artists" => (typeof(LibraryGridPage), LibraryGridPage.Artists),
            "songs" => (typeof(SongsPage), SongsPage.Songs),
            "liked" => (typeof(SongsPage), SongsPage.Liked),
            "album" => (typeof(AlbumPage), parameter),
            "artist" => (typeof(ArtistPage), parameter),
            "playlist" => (typeof(PlaylistPage), parameter),
            "search" => (typeof(SearchPage), parameter),
            "devices" => (typeof(DevicesPage), null),
            "settings" => (typeof(SettingsPage), parameter),
            _ when tag.StartsWith("playlist:", StringComparison.Ordinal) => (typeof(PlaylistPage), tag["playlist:".Length..]),
            _ => (typeof(ShelvesPage), ShelvesPage.Home),
        };
        // Same page with the same argument: nothing to do (clicking the selected item again).
        if (ContentFrame.Content?.GetType() == type && Equals(ContentFrame.Tag, arg)) return;
        ContentFrame.Tag = arg;
        ContentFrame.Navigate(type, arg, new EntranceNavigationTransitionInfo());
    }

    /// <summary>Opens an album, artist or playlist page, or plays a song.</summary>
    public void Open(MediaItem item)
    {
        switch (item)
        {
            case MediaItem.AlbumItem a: Navigate("album", a.Album.ProviderID); break;
            case MediaItem.ArtistItem a: Navigate("artist", a.Artist.ProviderID); break;
            case MediaItem.PlaylistItem p when p.Playlist.Extra.GetValueOrDefault("moreToken") is { } token:
                Navigate("search", "shelf:" + token); // a mood or genre ("mood:Chill"): its playlists
                break;
            case MediaItem.PlaylistItem p: Navigate("playlist", p.Playlist.ProviderID); break;
            case MediaItem.TrackItem t: App.Services.Player.Play(t.Track); break;
        }
    }

    private void Nav_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (_syncingSelection) return;
        if (args.SelectedItemContainer?.Tag is string tag) Navigate(tag);
    }

    private void ContentFrame_Navigated(object sender, NavigationEventArgs e)
    {
        // Back and Forward change the page without Navigate: keep the "already showing this" check honest.
        ContentFrame.Tag = e.Parameter;
        AppTitleBar.IsBackButtonEnabled = ContentFrame.CanGoBack || IsNowPlayingOpen;
        // A new page: the last one's load error isn't about it.
        PageErrorBar.IsOpen = false;
        var tag = e.SourcePageType.Name switch
        {
            nameof(ShelvesPage) => e.Parameter as string == ShelvesPage.New ? "new" : "home",
            nameof(RadioPage) => "radio",
            nameof(LibraryGridPage) => e.Parameter as string,
            nameof(SongsPage) => e.Parameter as string,
            nameof(PlaylistPage) => "playlist:" + e.Parameter,
            nameof(DevicesPage) => "devices",
            nameof(SettingsPage) => "settings",
            _ => null,
        };
        _syncingSelection = true;
        Nav.SelectedItem = tag is null ? null : FindItem(tag);
        _syncingSelection = false;
    }

    private NavigationViewItem? FindItem(string tag) =>
        Nav.MenuItems.Concat(Nav.FooterMenuItems).OfType<NavigationViewItem>().FirstOrDefault(i => i.Tag as string == tag);

    private void TitleBar_BackRequested(TitleBar sender, object args) => GoBack();

    public void GoBack()
    {
        if (IsOnboarding) Onboarding.GoBack();
        else if (IsNowPlayingOpen) ShowNowPlaying(false);
        else if (ContentFrame.CanGoBack) ContentFrame.GoBack();
    }

    private void TitleBar_PaneToggleRequested(TitleBar sender, object args) => Nav.IsPaneOpen = !Nav.IsPaneOpen;

    // MARK: Panes

    public bool IsNowPlayingOpen => NowPlaying.Visibility == Visibility.Visible;

    public void ShowNowPlaying(bool show)
    {
        if (show == IsNowPlayingOpen) return;
        // Closing: focus goes back to the page, quietly (programmatic focus draws no focus box), not to whatever
        // control XAML picks next, which was the bar's song tile, left with a keyboard focus box and its tooltip.
        var hadFocus = !show && FocusManager.GetFocusedElement(XamlRoot) is DependencyObject focused && ListHelpers.IsInside(focused, NowPlaying);
        NowPlaying.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        if (hadFocus) ContentFrame.Focus(FocusState.Programmatic);
        if (show) NowPlaying.OnShown();
        Bar.SetNowPlayingOpen(show);
        AppTitleBar.IsBackButtonEnabled = ContentFrame.CanGoBack || show;
    }

    public SidePaneTab? OpenPane => SidePane.Visibility == Visibility.Visible ? SidePane.Tab : null;

    /// <summary>Opens the right pane on <paramref name="tab"/>, or closes it (null).</summary>
    public void ShowPane(SidePaneTab? tab)
    {
        if (tab is { } t)
        {
            SidePane.Tab = t;
            SidePane.Visibility = Visibility.Visible;
        }
        else
        {
            SidePane.Visibility = Visibility.Collapsed;
        }
        Bar.SetPaneState(tab);
        LayoutForWidth(ActualWidth);
    }

    public void TogglePane(SidePaneTab tab) => ShowPane(OpenPane == tab ? null : tab);

    /// <summary>The pane pushes the content aside (pages then lay out for the narrower width); only a window too narrow
    /// to leave a page beside it lays the pane over the content.</summary>
    private void LayoutForWidth(double width)
    {
        var overlay = width < 900;
        Grid.SetColumn(SidePane, overlay ? 0 : 1);
        Grid.SetColumnSpan(SidePane, overlay ? 2 : 1);
        SidePane.HorizontalAlignment = overlay ? HorizontalAlignment.Right : HorizontalAlignment.Stretch;
        SidePane.IsOverlay = overlay;
        // The search box (and its suggestions, which take its width) is as wide as the title bar allows.
        SearchBox.Width = width >= 1200 ? 440 : width >= 960 ? 360 : 280;
        Bar.LayoutForWidth(width);
    }

    // MARK: Search

    public void ClearSearch()
    {
        SearchBox.Text = "";
        SearchBox.ItemsSource = null;
    }

    public void FocusSearch() => SearchBox.Focus(FocusState.Keyboard);

#if DEBUG
    /// <summary>Debug self-test: types <paramref name="text"/> into the search box and opens its suggestions.</summary>
    public async Task ShowSuggestionsAsync(string text)
    {
        SearchBox.Focus(FocusState.Keyboard);
        SearchBox.Text = text;
        await UpdateSuggestionsAsync(SearchBox, text);
        SearchBox.IsSuggestionListOpen = true;
    }

    public void CloseSuggestions()
    {
        SearchBox.IsSuggestionListOpen = false;
        ClearSearch();
        ContentFrame.Focus(FocusState.Programmatic);
    }

    /// <summary>Debug self-test: shows or hides the Continue InfoBar (screens without it in a --demo-sync run).</summary>
    public void SetContinueBarOpen(bool open)
    {
        if (open && App.Services.Sync is null) ContinueBar.IsOpen = true;
        else if (!open) ContinueBar.IsOpen = false;
    }
#endif

    private async void SearchBox_TextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (args.Reason != AutoSuggestionBoxTextChangeReason.UserInput) return;
        await UpdateSuggestionsAsync(sender, sender.Text);
    }

    private async Task UpdateSuggestionsAsync(AutoSuggestBox sender, string text)
    {
        var gen = ++_suggestionGeneration;
        if (string.IsNullOrWhiteSpace(text))
        {
            // An empty box offers the recent searches.
            sender.ItemsSource = App.Services.Settings.Values.RecentSearches.Take(8).Select(SearchSuggestion.ForRecent).ToList();
            return;
        }
        // Wait for a pause in typing before asking the service.
        await Task.Delay(120);
        if (gen != _suggestionGeneration) return;
        SearchSuggestions suggestions;
        try
        {
            suggestions = await App.Services.Provider.RichSearchSuggestionsAsync(text);
        }
        catch (Exception)
        {
            return; // suggestions are a convenience: offline just means none
        }
        if (gen != _suggestionGeneration) return;
        sender.ItemsSource = suggestions.Queries.Select(SearchSuggestion.ForQuery)
            .Concat(suggestions.Items.Select(SearchSuggestion.ForItem)).ToList();
    }

    private void SearchBox_GotFocus(object sender, RoutedEventArgs e)
    {
        if (SearchBox.Text.Length == 0 && App.Services.Settings.Values.RecentSearches.Count > 0)
        {
            SearchBox.ItemsSource = App.Services.Settings.Values.RecentSearches.Take(8).Select(SearchSuggestion.ForRecent).ToList();
            SearchBox.IsSuggestionListOpen = true;
        }
    }

    private void SearchBox_SuggestionChosen(AutoSuggestBox sender, AutoSuggestBoxSuggestionChosenEventArgs args)
    {
        if (args.SelectedItem is SearchSuggestion { IsQuery: true } s) sender.Text = s.Text;
    }

    private void SearchBox_QuerySubmitted(AutoSuggestBox sender, AutoSuggestBoxQuerySubmittedEventArgs args)
    {
        if (args.ChosenSuggestion is SearchSuggestion { Item: { } item })
        {
            Open(item);
            return;
        }
        var query = (args.ChosenSuggestion as SearchSuggestion)?.Text ?? args.QueryText;
        if (string.IsNullOrWhiteSpace(query)) return;
        App.Services.Settings.AddRecentSearch(query);
        Navigate("search", query.Trim());
    }

    // MARK: Keyboard

    private static bool IsTyping(XamlRoot? root) =>
        FocusManager.GetFocusedElement(root) is TextBox or AutoSuggestBox or RichEditBox or PasswordBox;

    private void Root_PreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        // Space plays and pauses anywhere except in a text field (and it doesn't press the focused button).
        if (e.Key == VirtualKey.Space && !IsTyping(XamlRoot) && Dialogs.Current is null && !IsOnboarding)
        {
            App.Services.Player.TogglePlayPause();
            e.Handled = true;
        }
    }
}

/// <summary>Lets the snapshotter reach the bar without exposing its internals.</summary>
public readonly record struct NowPlayingBarAccess(Controls.NowPlayingBar Bar);

/// <summary>A one-shot delay on the UI thread that can be cancelled (no timer object kept running).</summary>
public sealed class DispatcherTimerLite
{
    private bool _cancelled;

    public static DispatcherTimerLite After(TimeSpan delay, Action action)
    {
        var timer = new DispatcherTimerLite();
        _ = Run(timer, delay, action);
        return timer;
    }

    private static async Task Run(DispatcherTimerLite timer, TimeSpan delay, Action action)
    {
        await Task.Delay(delay);
        if (!timer._cancelled) action();
    }

    public void Cancel() => _cancelled = true;
}
