using Medley.App.Services;
using Medley.App.ViewModels;
using Medley.Core;
using Medley.Core.Sync;
using Medley.Sync;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Medley.App.Controls;

/// <summary>
/// Your other devices: what each plays and where it is (live), Play Here (pull this device's playback to this PC), Play
/// on (push this PC's playback there), and remote controls for a device that's playing. Used in the now-playing bar's
/// Devices flyout and on the Devices page. A one-second tick runs only while it's on screen.
/// </summary>
public sealed partial class DevicesView : UserControl
{
    private readonly StackPanel _list = new() { Spacing = 8 };
    private readonly DispatcherQueueTimer _tick;
    private readonly Dictionary<DeviceId, TextBlock> _positions = [];
    private string _shape = "";
    private bool _compact;

    public DevicesView()
    {
        Content = _list;
        _tick = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _tick.Interval = TimeSpan.FromSeconds(1);
        _tick.Tick += (_, _) => Tick();
        Loaded += (_, _) =>
        {
            if (App.Services.Sync is { } sync) sync.PropertyChanged += Sync_PropertyChanged;
            Rebuild(force: true);
            _tick.Start();
        };
        Unloaded += (_, _) =>
        {
            _tick.Stop();
            if (App.Services.Sync is { } sync) sync.PropertyChanged -= Sync_PropertyChanged;
        };
    }

    /// <summary>Flyout size: narrower rows.</summary>
    public bool Compact
    {
        get => _compact;
        set { _compact = value; Width = value ? 420 : double.NaN; }
    }

    private void Sync_PropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e) => Rebuild();

    private void Tick()
    {
        if (App.Services.Sync is not { } sync) return;
        foreach (var (id, label) in _positions) label.Text = PositionText(sync, id);
        Rebuild();
    }

    private static string PositionText(SyncHub sync, DeviceId id)
    {
        if (!sync.Service.Playback.TryGetValue(id, out var row)) return "";
        var position = sync.Coordinator.LivePosition(id) ?? 0;
        var duration = row.Anchor.DurationMs is { } ms ? ms / 1000 : row.Track?.Duration;
        var state = sync.Coordinator.EffectiveAnchor(row).IsPlaying ? "Playing" : "Paused";
        return duration is { } d ? $"{state} · {Format.Time(position)} / {Format.Time(d)}" : $"{state} · {Format.Time(position)}";
    }

    private void Rebuild(bool force = false)
    {
        var sync = App.Services.Sync;
        // Rebuild only when what's listed changed (devices, tracks, online state), not every tick.
        var shape = sync is null ? "none" : string.Join(";", new[] { $"{sync.Account.IsSignedIn}{sync.Service.IsRegistered}{sync.Coordinator.Phase}|{App.Services.Player.Current?.Id}{App.Services.Player.IsPlaying}" }
            .Concat(sync.Service.OtherDevices.Select(d => $"{d.Id.Value}|{d.Name}|{sync.Service.IsOnline(d)}|{(sync.Service.Playback.TryGetValue(d.Id, out var r) ? (r.Track?.Id ?? "sealed") + r.Anchor.IsPlaying : "-")}")));
        if (!force && shape == _shape) return;
        _shape = shape;
        _list.Children.Clear();
        _positions.Clear();
        if (_compact) _list.Children.Add(new TextBlock { Text = "Devices", Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"], Margin = new Thickness(0, 0, 0, 4) });
        if (sync is null)
        {
            if (App.Services.Options.DemoSync) BuildPreview();
            else _list.Children.Add(Secondary($"{ProductInfo.Name} Sync isn't on in demo runs."));
            return;
        }
        if (!sync.Account.IsSignedIn)
        {
            _list.Children.Add(Secondary($"Sign in to {ProductInfo.Name} to play on your Mac and iPhone, and to pick up what they play."));
            var signIn = new Button { Content = "Sign In", Style = (Style)Application.Current.Resources["AccentButtonStyle"], Margin = new Thickness(0, 4, 0, 0) };
            AutomationProperties.SetAutomationId(signIn, "DevicesSignIn");
            signIn.Click += async (_, _) => await ShellPage.Current.SignInToMedleyAsync();
            _list.Children.Add(signIn);
            return;
        }
        if (!sync.Service.IsRegistered)
        {
            _list.Children.Add(Secondary(sync.ConnectFailure is { } why ? $"Not connected: {why}" : "Connecting…"));
            return;
        }
        var player = App.Services.Player;
        _list.Children.Add(DeviceCard(Glyph(DevicePlatform.Windows), $"{sync.Service.DeviceInfo.Name} (this PC)",
            player.Current is { } t ? $"{(player.IsPlaying ? "Playing" : "Paused")} · {t.Title}" : "Not playing", null, []));
        var others = sync.Service.OtherDevices.OrderByDescending(d => sync.Service.IsOnline(d)).ThenByDescending(d => d.LastSeenAt).ToList();
        if (others.Count == 0)
        {
            _list.Children.Add(Secondary($"Your other devices show up here once {ProductInfo.Name} on them is signed in to the same account."));
            return;
        }
        foreach (var device in others) _list.Children.Add(Device(sync, device));
    }

    /// <summary><c>--demo --demo-sync</c> (screenshots): made-up devices, as the Mac's SyncHub.preview. Buttons do nothing.</summary>
    private void BuildPreview()
    {
        var player = App.Services.Player;
        _list.Children.Add(DeviceCard(Glyph(DevicePlatform.Windows), "Riley's PC (this PC)",
            player.Current is { } t ? $"{(player.IsPlaying ? "Playing" : "Paused")} · {t.Title}" : "Not playing", null, []));
        foreach (var (name, platform, title, artist, playing, at, length) in new[]
        {
            ("Riley's iPhone", DevicePlatform.Ios, "One More Time", "Daft Punk", true, 83.0, 320.0),
            ("Riley's MacBook Pro", DevicePlatform.Mac, "Digital Love", "Daft Punk", false, 41.0, 301.0),
        })
        {
            var here = new Button { Content = ContinueHereLabel, Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
            var send = new Button { Content = PlayOnLabel(platform) };
            var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
            foreach (var glyph in new[] { "\uE892", playing ? "\uE769" : "\uE768", "\uE893" })
                controls.Children.Add(new Button { Content = new FontIcon { Glyph = glyph, FontSize = 14 }, Style = (Style)Application.Current.Resources["BarIconButtonStyle"] });
            var card = DeviceCard(Glyph(platform), name, $"{title} · {artist}", controls, [here, send]);
            ((StackPanel)((Grid)card.Child).Children[1]).Children.Insert(2, new TextBlock
            {
                Text = $"{(playing ? "Playing" : "Paused")} · {Format.Time(at)} / {Format.Time(length)}",
                Style = Ui.Style("MedleySecondaryCaptionStyle"),
            });
            _list.Children.Add(card);
        }
    }

    /// <summary>The two handoff buttons name where the music goes: "Continue on This PC" pulls the other device's song
    /// here, "Play on iPhone" sends this PC's there.</summary>
    public const string ContinueHereLabel = "Continue on This PC";

    public static string PlayOnLabel(DevicePlatform platform) => platform switch
    {
        DevicePlatform.Ios => "Play on iPhone",
        DevicePlatform.Mac => "Play on Mac",
        _ => "Play on PC",
    };

    private FrameworkElement Device(SyncHub sync, SyncDevice device)
    {
        var online = sync.Service.IsOnline(device);
        var busy = sync.Coordinator.Phase is HandoffPhase.Pulling p && p.From == device.Id || sync.Coordinator.Phase is HandoffPhase.Pushing q && q.To == device.Id;
        sync.Service.Playback.TryGetValue(device.Id, out var row);
        // Without the vault key this PC sees that another device plays, not what (sealed content).
        var detail = row switch
        {
            { Track: { } t } => $"{t.Title} · {t.ArtistLine}",
            not null => sync.Coordinator.EffectiveAnchor(row).IsPlaying ? $"Playing on {device.Name}" : $"Paused on {device.Name}",
            null => online ? "Not playing" : "Offline",
        };
        var buttons = new List<FrameworkElement>();
        // A finished handoff: this PC plays the song the device has paused, so there's nothing to continue.
        var player = App.Services.Player;
        var movedHere = row is { Track: { } moved } && player.IsPlaying && player.Current?.Id == moved.Id && !sync.Coordinator.EffectiveAnchor(row).IsPlaying;
        if (movedHere)
        {
            buttons.Add(new TextBlock { Text = "Playback moved to this PC", Style = Ui.Style("MedleySecondaryTextStyle"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) });
        }
        else if (row is not null)
        {
            var here = new Button { Content = ContinueHereLabel, Style = (Style)Application.Current.Resources["AccentButtonStyle"], IsEnabled = !busy };
            ToolTipService.SetToolTip(here, $"Continue what {device.Name} is playing, here");
            AutomationProperties.SetAutomationId(here, $"PlayHere-{Id(device.Name)}");
            here.Click += async (_, _) =>
            {
                if (!sync.HasKey)
                {
                    ShellPage.Current.CloseDevices();
                    ShellPage.Current.ShowNeedsApproval(device.Name);
                    return;
                }
                here.IsEnabled = false;
                await sync.PlayHereAsync(device.Id);
                ShellPage.Current.CloseDevices();
            };
            buttons.Add(here);
        }
        if (online && App.Services.Player.Current is not null)
        {
            var send = new Button { Content = PlayOnLabel(device.Platform), IsEnabled = !busy };
            ToolTipService.SetToolTip(send, $"Play what's playing here on {device.Name}");
            AutomationProperties.SetName(send, $"Play on {device.Name}");
            AutomationProperties.SetAutomationId(send, $"SendTo-{Id(device.Name)}");
            send.Click += async (_, _) =>
            {
                send.IsEnabled = false;
                await sync.SendToAsync(device.Id);
                ShellPage.Current.CloseDevices();
            };
            buttons.Add(send);
        }
        FrameworkElement? remote = null;
        if (row is not null && online)
        {
            var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
            controls.Children.Add(RemoteButton(sync, device, "\uE892", "Previous", r => r.Previous(), "previous"));
            var playing = sync.Coordinator.EffectiveAnchor(row).IsPlaying;
            controls.Children.Add(RemoteButton(sync, device, playing ? "\uE769" : "\uE768", playing ? "Pause" : "Play", r => playing ? r.Pause() : r.Play(), playing ? "pause" : "play"));
            controls.Children.Add(RemoteButton(sync, device, "\uE893", "Next", r => r.Next(), "next"));
            remote = controls;
        }
        var card = DeviceCard(Glyph(device.Platform), device.Name, detail, remote, buttons);
        if (row is not null)
        {
            var position = new TextBlock { Text = PositionText(sync, device.Id), Style = Ui.Style("MedleySecondaryCaptionStyle"), };
            AutomationProperties.SetAutomationId(position, $"Position-{Id(device.Name)}");
            _positions[device.Id] = position;
            ((StackPanel)((Grid)card.Child).Children[1]).Children.Insert(2, position);
        }
        AutomationProperties.SetName(card, device.Name);
        return card;
    }

    /// <summary>A device name usable in an AutomationId ("Riley's iPhone" → "RileysiPhone").</summary>
    internal static string Id(string name) => new(name.Where(char.IsAsciiLetterOrDigit).ToArray());

    private static string Short(string name) => name.Length > 14 ? name[..13] + "…" : name;

    private static Button RemoteButton(SyncHub sync, SyncDevice device, string glyph, string label, Func<RemoteControl, Task<CommandId>> action, string what)
    {
        var button = new Button { Content = new FontIcon { Glyph = glyph, FontSize = 14 }, Style = (Style)Application.Current.Resources["BarIconButtonStyle"] };
        AutomationProperties.SetName(button, $"{label} on {device.Name}");
        AutomationProperties.SetAutomationId(button, $"Remote{label}-{Id(device.Name)}");
        ToolTipService.SetToolTip(button, $"{label} on {device.Name}");
        button.Click += async (_, _) => await sync.RemoteAsync(device.Id, action, what);
        return button;
    }

    private static Border DeviceCard(string glyph, string name, string detail, FrameworkElement? remote, IReadOnlyList<FrameworkElement> buttons)
    {
        var grid = new Grid { ColumnSpacing = 14 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(new FontIcon { Glyph = glyph, FontSize = 22, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 0, 0) });
        var text = new StackPanel { Spacing = 1 };
        text.Children.Add(new TextBlock { Text = name, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], TextTrimming = TextTrimming.CharacterEllipsis });
        text.Children.Add(new TextBlock { Style = Ui.Style("MedleySecondaryTextStyle"), Text = detail, TextTrimming = TextTrimming.CharacterEllipsis, });
        // Children[1] is the text (callers insert a position line into it). The remote's transport sits at the card's
        // top right, beside the name; the handoff buttons get a row of their own under both, so their labels (which
        // name the destination) never get cut.
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        if (remote is not null)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            remote.HorizontalAlignment = HorizontalAlignment.Right;
            remote.VerticalAlignment = VerticalAlignment.Top;
            remote.Margin = new Thickness(0, -4, -6, 0);
            Grid.SetColumn(remote, 2);
            grid.Children.Add(remote);
        }
        if (buttons.Count > 0)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 10, 0, 0) };
            foreach (var b in buttons) actions.Children.Add(b);
            Grid.SetRow(actions, 1);
            Grid.SetColumn(actions, 1);
            Grid.SetColumnSpan(actions, 2);
            grid.Children.Add(actions);
        }
        return new Border
        {
            Padding = new Thickness(14, 12, 14, 12),
            Style = Ui.Style("MedleyCardStyle"),
            Child = grid,
        };
    }

    private static TextBlock Secondary(string text) => new()
    {
        Text = text,
        Style = Ui.Style("MedleySecondaryTextStyle"),
    };

    private static string Glyph(DevicePlatform platform) => platform switch
    {
        DevicePlatform.Ios => "\uE8EA",
        DevicePlatform.Mac => "\uE7F8",
        _ => "\uE770",
    };
}
