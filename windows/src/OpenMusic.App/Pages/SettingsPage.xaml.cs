using System.ComponentModel;
using OpenMusic.App.Services;
using OpenMusic.Core;
using OpenMusic.Sync;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Navigation;

namespace OpenMusic.App.Pages;

public sealed partial class SettingsPage : Page
{
    private bool _ready;
    private bool _rebuildPending;

    public SettingsPage()
    {
        InitializeComponent();
        var services = App.Services;
        ThemeBox.SelectedIndex = services.Settings.Values.Theme switch { "light" => 1, "dark" => 2, _ => 0 };
        StreamBox.SelectedIndex = services.Settings.Values.StreamPreference == "hls" ? 1 : 0;
        AutoplaySwitch.IsOn = services.Player.Autoplay;
        SoundCheckSwitch.IsOn = services.Player.NormalizationEnabled;
        VersionText.Text = $"Version {typeof(SettingsPage).Assembly.GetName().Version?.ToString(3)} · Windows App SDK 1.8 · .NET {Environment.Version}";
        Loaded += (_, _) =>
        {
            services.Provider.PropertyChanged += Changed;
            if (services.Sync is { } sync) sync.PropertyChanged += Changed;
            Rebuild();
        };
        Unloaded += (_, _) =>
        {
            services.Provider.PropertyChanged -= Changed;
            if (services.Sync is { } sync) sync.PropertyChanged -= Changed;
        };
        _ready = true;
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        if (e.Parameter as string == "about") DispatcherQueue.TryEnqueue(() => AboutHeader.StartBringIntoView());
    }

    private void Changed(object? sender, PropertyChangedEventArgs e)
    {
        // Sync raises often (devices' heartbeats); rebuild once per burst.
        if (_rebuildPending) return;
        _rebuildPending = true;
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            _rebuildPending = false;
            Rebuild();
        });
    }

    private string _accountShape = "";
    private string _youtubeShape = "";

    private void Rebuild()
    {
        BuildAccount();
        BuildYouTube();
        AutoplaySwitch.IsOn = App.Services.Player.Autoplay;
    }

    // MARK: OpenMusic account

    private void BuildAccount()
    {
        var sync = App.Services.Sync;
        var shape = sync is null ? "demo" : string.Join("|", sync.Account.User?.Id, sync.Account.Server.Url, sync.Service.IsRegistered, SyncHub.Describe(sync.Service.KeyStatus),
            sync.ConnectFailure, string.Join(",", sync.Service.Devices.Select(d => $"{d.Id.Value}{d.Name}{sync.Service.IsOnline(d)}{d.KeyState}")));
        if (shape == _accountShape) return;
        _accountShape = shape;
        var section = AccountSection;
        section.Children.Clear();
        if (sync is null)
        {
            section.Children.Add(Card("\uE895", $"{ProductInfo.Name} Sync", "Off in demo runs.", null));
            return;
        }
        var account = sync.Account;
        if (account.User is not { } user)
        {
            var signIn = Accent("Sign In", "SettingsSignInOpenMusic", async () => await ShellPage.Current.SignInToOpenMusicAsync());
            section.Children.Add(Card("\uE8AF", "Sign in to sync with your other devices",
                $"Continue what your Mac or iPhone plays, send music to them, and share your YouTube Music sign-in. {ProductInfo.Name} works fully without an account.", signIn));
            section.Children.Add(ServerCard(sync));
            return;
        }
        var picture = new PersonPicture { Width = 40, Height = 40, DisplayName = user.DisplayName };
        if (user.ImageUrl is { } image && Uri.TryCreate(image, UriKind.Absolute, out var u)) picture.ProfilePicture = new BitmapImage(u) { DecodePixelWidth = 80 };
        var signOut = Plain("Sign Out", "SettingsSignOutOpenMusic", async () =>
        {
            var dialog = new ContentDialog
            {
                Title = $"Sign out of {ProductInfo.Name}?",
                Content = "This PC stops syncing and leaves your devices. Your YouTube Music sign-in on this PC stays.",
                PrimaryButtonText = "Sign Out",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Close,
            };
            if (await Dialogs.ShowAsync(dialog) == ContentDialogResult.Primary) await sync.SignOutAsync();
        });
        section.Children.Add(Card(picture, user.DisplayName, user.Email ?? "Signed in", signOut, "SettingsAccountCard"));
        section.Children.Add(ServerCard(sync));
        section.Children.Add(KeyCard(sync));
        if (sync.ConnectFailure is { } why)
            section.Children.Add(Card("\uE871", "Not connected", why, Plain("Try Again", "SettingsReconnect", sync.ConnectAsync)));
        var devices = new StackPanel { Spacing = 4 };
        devices.Children.Add(new TextBlock { Text = "Devices", Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], Margin = new Thickness(0, 16, 0, 2) });
        var service = sync.Service;
        foreach (var device in service.Devices.OrderByDescending(d => d.Id == service.SelfId).ThenByDescending(d => d.LastSeenAt))
        {
            var self = device.Id == service.SelfId;
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            buttons.Children.Add(Plain("Rename", $"Rename-{Controls.DevicesView.Id(device.Name)}", () => RenameAsync(sync, device)));
            if (!self) buttons.Children.Add(Plain("Remove", $"Remove-{Controls.DevicesView.Id(device.Name)}", () => RemoveAsync(sync, device)));
            var seen = service.IsOnline(device) ? "Online" : $"Last seen {Ago(service.Clock.Now() - device.LastSeenAt)}";
            var key = device.KeyState switch
            {
                // Approval is about the account's sign-in key, not whether a service is signed in (YouTube Music's
                // own card below says that): an approved device receives the sign-ins you make anywhere.
                OpenMusic.Sync.KeyStateKind.Holder or OpenMusic.Sync.KeyStateKind.Granted => "approved",
                OpenMusic.Sync.KeyStateKind.Requested => "waiting for approval",
                OpenMusic.Sync.KeyStateKind.Denied => "not allowed",
                _ => null,
            };
            var glyph = self ? "\uE7F8" : device.Platform == OpenMusic.Core.Sync.DevicePlatform.Ios ? "\uE8EA" : "\uE7F8";
            devices.Children.Add(Card(glyph, self ? $"{device.Name} (this PC)" : device.Name, string.Join(" · ", new[] { seen, key }.Where(s => s is not null)), buttons, $"Device-{Controls.DevicesView.Id(device.Name)}"));
        }
        if (service.Devices.Count == 0) devices.Children.Add(Card("\uE8AF", "No devices yet", service.IsRegistered ? "Your devices show up here." : "Connecting…", null));
        section.Children.Add(devices);
    }

    private FrameworkElement ServerCard(SyncHub sync)
    {
        var server = sync.Account.Server;
        var change = Plain("Change…", "SettingsServer", () => OpenMusicSignInDialog.ShowServerAsync(sync));
        return Card("\uE968", "Server", server.IsCustom ? server.Url.AbsoluteUri : ProductInfo.Name, change, "ServerCard");
    }

    /// <summary>Whether this PC has the key that opens the synced sign-ins, and what to do when it doesn't.</summary>
    private FrameworkElement KeyCard(SyncHub sync)
    {
        var service = sync.Service;
        FrameworkElement? action = null;
        string title, caption;
        switch (service.KeyStatus)
        {
            case KeyStatus.Available:
                var shared = App.Services.Provider.IsSignedIn;
                title = shared ? "Sign-ins are shared" : "Sign-in sharing is on";
                caption = shared
                    ? "Your YouTube Music sign-in moves between this PC and the devices you approved, end-to-end encrypted."
                    : "Sign in to YouTube Music here or on another device and it arrives on the rest, end-to-end encrypted.";
                break;
            case KeyStatus.Comparing c:
                title = $"Compare the codes · {KeyDialogs.FormatCode(c.Comparison.Code)}";
                caption = c.Comparison.Instructions("this PC");
                action = Accent("Compare…", "SettingsCompare", () => KeyDialogs.CompareAsync(sync, c.Comparison));
                break;
            case KeyStatus.Waiting:
                title = "Waiting for another device";
                caption = $"Open {ProductInfo.Name} on your Mac or iPhone and allow this PC there.";
                break;
            case KeyStatus.Denied:
                title = "Another device didn't allow this PC";
                caption = "Ask again, then allow it on the other device.";
                action = AskAgain(sync);
                break;
            case KeyStatus.Mismatch:
                title = "The codes didn't match";
                caption = "Nothing was shared. Ask again and compare the new codes.";
                action = AskAgain(sync);
                break;
            case KeyStatus.Failed f:
                title = "Sign-ins aren't shared";
                caption = f.Message;
                action = AskAgain(sync);
                break;
            default:
                title = service.IsRegistered ? "Sign-ins aren't shared yet" : "Connecting…";
                caption = service.KeyWarning ?? "When your other devices allow this PC, your YouTube Music sign-in arrives here.";
                if (service.IsRegistered) action = AskAgain(sync);
                break;
        }
        return Card("\uE8D7", title, caption, action, "KeyCard");
    }

    private static Button AskAgain(SyncHub sync) => Plain("Ask Again", "SettingsAskAgain", async () =>
    {
        sync.ForgetDismissedRequests();
        try { await sync.Service.RequestKeyAgainAsync(); }
        catch (Exception e) { ShellPage.Current.ShowNotice($"Couldn't ask again. {e.Message}", InfoBarSeverity.Error); }
    });

    private static async Task RenameAsync(SyncHub sync, SyncDevice device)
    {
        var box = new TextBox { Text = device.Name, MaxLength = 64, MinWidth = 320 };
        AutomationProperties.SetAutomationId(box, "RenameBox");
        var dialog = new ContentDialog { Title = "Rename device", Content = box, PrimaryButtonText = "Rename", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
        if (await Dialogs.ShowAsync(dialog) != ContentDialogResult.Primary || box.Text.Trim() is not { Length: > 0 } name || name == device.Name) return;
        try
        {
            await sync.Service.RenameAsync(device.Id, name);
            if (device.Id == sync.Service.SelfId)
            {
                App.Services.Settings.Values.DeviceName = name;
                App.Services.Settings.Save();
            }
        }
        catch (Exception e)
        {
            ShellPage.Current.ShowNotice($"Couldn't rename it. {e.Message}", InfoBarSeverity.Error);
        }
    }

    private static async Task RemoveAsync(SyncHub sync, SyncDevice device)
    {
        var dialog = new ContentDialog
        {
            Title = $"Remove {device.Name}?",
            Content = $"{device.Name} stops syncing and loses your shared sign-ins. Sign in on it again to add it back.",
            PrimaryButtonText = "Remove",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await Dialogs.ShowAsync(dialog) != ContentDialogResult.Primary) return;
        try { await sync.Service.RemoveAsync(device.Id); }
        catch (Exception e) { ShellPage.Current.ShowNotice($"Couldn't remove it. {e.Message}", InfoBarSeverity.Error); }
    }

    private static string Ago(double ms)
    {
        var t = TimeSpan.FromMilliseconds(Math.Max(0, ms));
        return t.TotalMinutes < 2 ? "just now" : t.TotalHours < 1 ? $"{(int)t.TotalMinutes} minutes ago" : t.TotalDays < 1 ? $"{(int)t.TotalHours} hours ago" : $"{(int)t.TotalDays} days ago";
    }

    // MARK: YouTube Music

    private void BuildYouTube()
    {
        var services = App.Services;
        var status = services.Provider.AuthStatus;
        var sync = services.Sync;
        var synced = sync?.Service.SignIns.Status.GetValueOrDefault(ProviderId.YouTubeMusic);
        var shape = $"{status.State}|{status.Account?.Id}|{status.Account?.Name}|{synced}";
        if (shape == _youtubeShape) return;
        _youtubeShape = shape;
        var section = YouTubeSection;
        section.Children.Clear();
        if (services.YouTube is null)
        {
            section.Children.Add(Card("\uE8D6", status.Account?.Name ?? "Demo", "Sample data (demo run)", null));
            return;
        }
        if (status.Account is { } account && status.IsSignedIn)
        {
            var picture = new PersonPicture { Width = 40, Height = 40, DisplayName = account.Name };
            if (account.Avatar is { } avatar) picture.ProfilePicture = new BitmapImage(avatar) { DecodePixelWidth = 80 };
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            buttons.Children.Add(Plain("Switch Account…", "SettingsSwitchYouTube", () => ShellPage.Current.SwitchYouTubeAccountAsync()));
            buttons.Children.Add(Plain("Sign Out…", "SettingsSignOutYouTube", () => ShellPage.Current.SignOutOfYouTubeAsync()));
            section.Children.Add(Card(picture, account.Name, account.Detail ?? "Signed in", buttons, "YouTubeAccountCard"));
        }
        else
        {
            var signIn = Accent(status.State == AuthState.SigningIn ? "Signing In…" : "Sign In", "SettingsSignInYouTube", () =>
            {
                ShellPage.Current.SignInToYouTube();
                return Task.CompletedTask;
            });
            section.Children.Add(Card("\uE8D6", "Not signed in", "Browse and play without an account. Sign in with Google for your library, likes and playlists.", signIn, "YouTubeAccountCard"));
        }
        if (synced is not null && sync!.Account.IsSignedIn)
        {
            var text = synced switch
            {
                SignInStatus.Synced => "The same on all your devices",
                SignInStatus.NeedsKey => "Waiting until this PC is allowed to use your sign-ins",
                SignInStatus.SignedOutHere => "Signed out on this PC only",
                SignInStatus.SignedOutEverywhere => "Signed out on all your devices",
                SignInStatus.NotSignedIn => "Not signed in on any device",
                SignInStatus.Failed f => $"Not synced: {f.Message}",
                _ => "Syncing…",
            };
            section.Children.Add(Card("\uE895", "Sign-in sync", text, null, "YouTubeSyncCard"));
        }
    }

    // MARK: Pieces

    private static Grid Card(object icon, string title, string caption, FrameworkElement? right, string? id = null)
    {
        var grid = new Grid { Style = Ui.Style("OpenMusicCardGridStyle") };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var iconElement = icon as FrameworkElement ?? new FontIcon { Glyph = (string)icon };
        iconElement.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(iconElement);
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = title, TextWrapping = TextWrapping.Wrap });
        if (caption.Length > 0)
            text.Children.Add(new TextBlock
            {
                Text = caption,
                Style = Ui.Style("OpenMusicSecondaryCaptionStyle"),
                TextWrapping = TextWrapping.Wrap,
            });
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        if (right is not null)
        {
            right.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(right, 2);
            grid.Children.Add(right);
        }
        if (id is not null) AutomationProperties.SetAutomationId(grid, id);
        AutomationProperties.SetName(grid, title);
        return grid;
    }

    private static Button Plain(string text, string id, Func<Task> run)
    {
        var button = new Button { Content = text, MinWidth = 96 };
        AutomationProperties.SetAutomationId(button, id);
        button.Click += async (_, _) =>
        {
            button.IsEnabled = false;
            try { await run(); }
            finally { button.IsEnabled = true; }
        };
        return button;
    }

    private static Button Accent(string text, string id, Func<Task> run)
    {
        var button = Plain(text, id, run);
        button.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        return button;
    }

    // MARK: Simple settings

    private void ThemeBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_ready || App.MainWindow is not { } window) return;
        var tag = (ThemeBox.SelectedItem as ComboBoxItem)?.Tag as string ?? "system";
        App.Services.Settings.Values.Theme = tag;
        App.Services.Settings.Save();
        window.SetTheme(tag switch
        {
            "light" => ElementTheme.Light,
            "dark" => ElementTheme.Dark,
            _ => ElementTheme.Default,
        });
    }

    private void StreamBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_ready) return;
        App.Services.Settings.Values.StreamPreference = (StreamBox.SelectedItem as ComboBoxItem)?.Tag as string ?? "direct";
        App.Services.Settings.Save();
    }

    private void AutoplaySwitch_Toggled(object sender, RoutedEventArgs e)
    {
        if (_ready) App.Services.Player.Autoplay = AutoplaySwitch.IsOn;
    }

    private void SoundCheckSwitch_Toggled(object sender, RoutedEventArgs e)
    {
        if (_ready) App.Services.Player.NormalizationEnabled = SoundCheckSwitch.IsOn;
    }

    private async void Shortcuts_Click(object sender, RoutedEventArgs e) => await Shortcuts.ShowDialogAsync();
}
