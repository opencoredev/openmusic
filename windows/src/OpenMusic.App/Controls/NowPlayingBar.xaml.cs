using System.ComponentModel;
using OpenMusic.App.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;

namespace OpenMusic.App.Controls;

public sealed partial class NowPlayingBar : UserControl
{
    private bool _scrubbing;
    private bool _settingScrubber;

    public PlayerViewModel ViewModel { get; } = App.Services.PlayerViewModel;

    public event Action<bool>? LyricsToggled;
    public event Action<bool>? QueueToggled;
    public event Action? NowPlayingRequested;
    public event Action? MiniPlayerRequested;

    public NowPlayingBar()
    {
        InitializeComponent();
        ViewModel.PropertyChanged += ViewModel_PropertyChanged;
        // The slider handles pointer events itself; listen to handled ones too, so a drag only seeks when it ends.
        Scrubber.AddHandler(PointerPressedEvent, new PointerEventHandler((_, _) => _scrubbing = true), true);
        Scrubber.AddHandler(PointerReleasedEvent, new PointerEventHandler((_, _) => EndScrub()), true);
        Scrubber.AddHandler(PointerCaptureLostEvent, new PointerEventHandler((_, _) => EndScrub()), true);
        Scrubber.ValueChanged += Scrubber_ValueChanged;
        SetScrubber(ViewModel.Position);
    }

    private void ViewModel_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(PlayerViewModel.Position) or nameof(PlayerViewModel.DurationSeconds) && !_scrubbing)
            SetScrubber(ViewModel.Position);
    }

    private void SetScrubber(double value)
    {
        _settingScrubber = true;
        Scrubber.Value = Math.Min(value, Scrubber.Maximum);
        _settingScrubber = false;
    }

    private void Scrubber_ValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (_settingScrubber) return;
        if (_scrubbing)
        {
            PositionLabel.Text = Format.Time(e.NewValue);
            return;
        }
        // Keyboard (arrows, Page Up/Down) or a click on the track.
        ViewModel.Seek(e.NewValue);
    }

    private void EndScrub()
    {
        if (!_scrubbing) return;
        _scrubbing = false;
        ViewModel.Seek(Scrubber.Value);
    }

    private void TrackButton_Click(object sender, RoutedEventArgs e) => NowPlayingRequested?.Invoke();

    private void RepeatButton_Click(object sender, RoutedEventArgs e)
    {
        ViewModel.CycleRepeat();
        RepeatButton.IsChecked = ViewModel.IsRepeatOn;
    }

    private void LyricsButton_Click(object sender, RoutedEventArgs e) => LyricsToggled?.Invoke(LyricsButton.IsChecked == true);

    private void QueueButton_Click(object sender, RoutedEventArgs e) => QueueToggled?.Invoke(QueueButton.IsChecked == true);

    private void DevicesFlyout_Opening(object? sender, object e) => DevicesFlyout.Content = new DevicesView { Compact = true };

    // The view stops its one-second tick when it leaves the tree.
    private void DevicesFlyout_Closed(object? sender, object e) => DevicesFlyout.Content = null;

    public void ShowDevices()
    {
        if (DevicesButton.Visibility == Visibility.Visible) DevicesFlyout.ShowAt(DevicesButton);
        else ShellPage.Current.Navigate("devices");
    }

    public void CloseDevices() => DevicesFlyout.Hide();

    private void MiniButton_Click(object sender, RoutedEventArgs e) => MiniPlayerRequested?.Invoke();

    /// <summary>Reflects the right pane's state on the two toggles.</summary>
    public void SetPaneState(SidePaneTab? tab)
    {
        LyricsButton.IsChecked = tab == SidePaneTab.Lyrics;
        QueueButton.IsChecked = tab == SidePaneTab.UpNext;
    }

    public void SetNowPlayingOpen(bool open) => TrackToolTip.Content = open ? "Close Now Playing" : "Now Playing";

    /// <summary>Narrow windows drop the inline volume slider (the button opens one) and shrink the scrubber.</summary>
    public void LayoutForWidth(double width)
    {
        VolumeSlider.Visibility = width >= 1180 ? Visibility.Visible : Visibility.Collapsed;
        VolumeButton.Flyout = width >= 1180 ? null : VolumeButton.Flyout ?? CreateVolumeFlyout();
        DevicesButton.Visibility = width >= 900 ? Visibility.Visible : Visibility.Collapsed;
        Center.Width = width switch { >= 1280 => 560, >= 1000 => 440, >= 880 => 360, _ => 300 };
        // The song's title trims before the heart beside it would be pushed under the transport.
        TrackButton.MaxWidth = Math.Max(140, (width - Center.Width - 28 - 24) / 2 - 44);
    }

    private Flyout CreateVolumeFlyout()
    {
        var slider = new Slider { Width = 180, Minimum = 0, Maximum = 100, Value = ViewModel.Volume };
        slider.ValueChanged += (_, e) => ViewModel.Volume = e.NewValue;
        return new Flyout { Content = slider, Placement = FlyoutPlacementMode.Top };
    }
}
