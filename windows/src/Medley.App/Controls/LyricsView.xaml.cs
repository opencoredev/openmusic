using Medley.App.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Medley.App.Controls;

public sealed partial class LyricsView : UserControl
{
    private ScrollViewer? _scroller;

    public PlayerViewModel ViewModel { get; } = App.Services.PlayerViewModel;

    /// <summary>Large type, for Now Playing.</summary>
    public bool Large
    {
        get => Lines.ItemTemplate == Resources["LargeLineTemplate"];
        set => Lines.ItemTemplate = (DataTemplate)Resources[value ? "LargeLineTemplate" : "LineTemplate"];
    }

    /// <summary>Where the current line sits, as a fraction of the visible height.</summary>
    public double Anchor { get; set; } = 0.3;

    public LyricsView()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            ViewModel.LyricIndexChanged += OnLyricIndexChanged;
            ScrollTo(ViewModel.CurrentLyricIndex, animate: false);
        };
        Unloaded += (_, _) => ViewModel.LyricIndexChanged -= OnLyricIndexChanged;
        // Shown or resized (Now Playing opening, the pane switching tabs): put the current line back in place.
        Lines.SizeChanged += (_, _) => ScrollTo(ViewModel.CurrentLyricIndex, animate: false);
    }

    public static double LineOpacity(bool isCurrent, bool isPast) => isCurrent ? 1.0 : isPast ? 0.56 : 0.66;

    public static Visibility StatusVisibility(bool hasLyrics, string status) =>
        status.Length > 0 && !hasLyrics ? Visibility.Visible : Visibility.Collapsed;

    private void Lines_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is LyricRow row) ViewModel.SeekToLyric(row);
    }

    private void OnLyricIndexChanged(int index)
    {
        if (Visibility == Visibility.Visible) ScrollTo(index, animate: true);
    }

    /// <summary>Scrolls so line <paramref name="index"/> sits at <see cref="Anchor"/> of the view.</summary>
    public void ScrollTo(int index, bool animate)
    {
        if (index < 0 || index >= ViewModel.LyricLines.Count) return;
        _scroller ??= FindScroller(Lines);
        if (_scroller is null || _scroller.ViewportHeight <= 0) return;
        if (Lines.ContainerFromIndex(index) is not UIElement container)
        {
            Lines.ScrollIntoView(ViewModel.LyricLines[index], ScrollIntoViewAlignment.Leading);
            Lines.UpdateLayout();
            if (Lines.ContainerFromIndex(index) is not UIElement retry) return;
            container = retry;
        }
        var top = container.TransformToVisual((UIElement)_scroller.Content).TransformPoint(default).Y;
        var target = Math.Max(0, top - _scroller.ViewportHeight * Anchor);
        _scroller.ChangeView(null, target, null, !animate);
    }

    private static ScrollViewer? FindScroller(DependencyObject root)
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is ScrollViewer sv) return sv;
            if (FindScroller(child) is { } found) return found;
        }
        return null;
    }
}
