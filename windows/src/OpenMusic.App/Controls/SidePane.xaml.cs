using OpenMusic.App.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace OpenMusic.App.Controls;

public enum SidePaneTab { Lyrics, UpNext }

public sealed partial class SidePane : UserControl
{
    private SidePaneTab _tab = SidePaneTab.Lyrics;
    private bool _isOverlay;

    public PlayerViewModel Player { get; } = App.Services.PlayerViewModel;

    public event Action? CloseRequested;

    public SidePane()
    {
        InitializeComponent();
        Tabs.SelectedItem = LyricsTab;
        ListHelpers.AttachContextMenu(UpNextList, item => item is QueueRow row ? UpNextMenu(row) : null);
        ListHelpers.AttachContextMenu(HistoryList, item => item is QueueRow row ? Services.MediaMenus.ForTrack(row.Entry.Track) : null);
        var player = App.Services.Player;
        Loaded += (_, _) =>
        {
            _settingAutoplay = true;
            AutoplaySwitch.IsOn = player.Autoplay;
            _settingAutoplay = false;
            player.PropertyChanged += Player_PropertyChanged;
        };
        Unloaded += (_, _) => player.PropertyChanged -= Player_PropertyChanged;
    }

    private bool _settingAutoplay;

    private void Player_PropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(OpenMusic.Core.PlayerController.Autoplay)) return;
        _settingAutoplay = true;
        AutoplaySwitch.IsOn = App.Services.Player.Autoplay;
        _settingAutoplay = false;
    }

    private void AutoplaySwitch_Toggled(object sender, RoutedEventArgs e)
    {
        if (!_settingAutoplay) App.Services.Player.Autoplay = AutoplaySwitch.IsOn;
    }

    /// <summary>The Now Playing row's mark: a speaker while playing, a pause mark while paused.</summary>
    public static string Indicator(bool playing) => playing ? "\uE995" : "\uE769";

    private int _dragFrom = -1;

    private void UpNextList_DragItemsStarting(object sender, DragItemsStartingEventArgs e) =>
        _dragFrom = e.Items.FirstOrDefault() is QueueRow row ? Player.UpNext.IndexOf(row) : -1;

    /// <summary>The list moved the row in its collection; move the entry in the queue the same way (SwiftUI onMove
    /// semantics: before the entry that was at the destination).</summary>
    private void UpNextList_DragItemsCompleted(ListViewBase sender, DragItemsCompletedEventArgs args)
    {
        if (_dragFrom < 0 || args.DropResult != Windows.ApplicationModel.DataTransfer.DataPackageOperation.Move || args.Items.FirstOrDefault() is not QueueRow row) return;
        var to = Player.UpNext.IndexOf(row);
        var from = _dragFrom;
        _dragFrom = -1;
        if (to < 0 || to == from) return;
        Player.Player.MoveUpNext([from], to > from ? to + 1 : to);
    }

    private void UpNextList_KeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
    {
        if (e.Key is not (Windows.System.VirtualKey.Delete or Windows.System.VirtualKey.Back) || UpNextList.SelectedItem is not QueueRow row) return;
        Remove(row);
        e.Handled = true;
    }

    private void Remove(QueueRow row) => Player.Player.RemoveUpNext([row.Entry.Uid], App.Services.Undo);

    /// <summary>The song's usual menu, with Remove from Up Next after its play actions.</summary>
    private MenuFlyout UpNextMenu(QueueRow row)
    {
        var menu = Services.MediaMenus.ForTrack(row.Entry.Track);
        menu.Opening += (_, _) =>
        {
            // Runs after the menu filled itself: Play jumps to this entry instead of starting a new queue.
            if (menu.Items.FirstOrDefault() is MenuFlyoutItem play)
            {
                menu.Items.RemoveAt(0);
                var jump = new MenuFlyoutItem { Text = "Play", Icon = new FontIcon { Glyph = "\uE768" } };
                jump.Click += (_, _) => Player.Play(row);
                menu.Items.Insert(0, jump);
            }
            var remove = new MenuFlyoutItem { Text = "Remove from Up Next", Icon = new FontIcon { Glyph = "\uE74D" } };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(remove, "MenuRemoveFromQueue");
            remove.Click += (_, _) => Remove(row);
            menu.Items.Insert(Math.Min(3, menu.Items.Count), remove);
        };
        return menu;
    }

    private void Clear_Click(object sender, RoutedEventArgs e)
    {
        Player.Player.ClearUpNext(App.Services.Undo);
        App.MainWindow?.Shell.ShowNotice("Cleared Up Next", InfoBarSeverity.Informational);
    }

    public SidePaneTab Tab
    {
        get => _tab;
        set
        {
            _tab = value;
            Tabs.SelectedItem = value == SidePaneTab.Lyrics ? LyricsTab : UpNextTab;
            Apply();
        }
    }

    /// <summary>Over the content (narrow windows): opaque, with a shadow.</summary>
    public bool IsOverlay
    {
        get => _isOverlay;
        set
        {
            _isOverlay = value;
            OverlayBackground.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
            PaneRoot.Translation = value ? new System.Numerics.Vector3(0, 0, 32) : default;
            PaneRoot.Shadow = value ? new ThemeShadow() : null;
        }
    }

    public static Visibility EmptyVisibility(int count) => count == 0 ? Visibility.Visible : Visibility.Collapsed;

    public static Visibility CountVisibility(int count) => count > 0 ? Visibility.Visible : Visibility.Collapsed;

    private void Tabs_SelectionChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        _tab = sender.SelectedItem == UpNextTab ? SidePaneTab.UpNext : SidePaneTab.Lyrics;
        Apply();
    }

    private void Apply()
    {
        Lyrics.Visibility = _tab == SidePaneTab.Lyrics ? Visibility.Visible : Visibility.Collapsed;
        UpNextPanel.Visibility = _tab == SidePaneTab.UpNext ? Visibility.Visible : Visibility.Collapsed;
        if (_tab == SidePaneTab.Lyrics) DispatcherQueue.TryEnqueue(() => Lyrics.ScrollTo(Player.CurrentLyricIndex, animate: false));
    }

    private void Close_Click(object sender, RoutedEventArgs e) => CloseRequested?.Invoke();

    private void UpNextList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is QueueRow row) Player.Play(row);
    }

    private void History_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is QueueRow row) Player.PlayFromHistory(row);
    }
}
