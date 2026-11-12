using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;

namespace Medley.App.Controls;

/// <summary>Right-click (and Shift+F10 / the menu key) menus for list and grid items, and "scrolled near the end".</summary>
public static class ListHelpers
{
    /// <summary>Shows <paramref name="build"/>'s menu for the item under the pointer (or the focused item).</summary>
    public static void AttachContextMenu(ListViewBase list, Func<object, MenuFlyout?> build)
    {
        list.ContextRequested += (_, e) =>
        {
            if (e.OriginalSource is not DependencyObject source) return;
            var container = Ancestor<SelectorItem>(source);
            var item = container?.Content ?? (source as FrameworkElement)?.DataContext;
            if (item is null || build(item) is not { } menu) return;
            var target = (FrameworkElement?)container ?? list;
            ShowMenu(menu, target, e.TryGetPosition(target, out var point) ? point : null);
            e.Handled = true;
        };
    }

    /// <summary>Opens <paramref name="menu"/> on <paramref name="target"/>; a row or card it opens on stays highlighted
    /// until the menu closes, so it's clear which song Add to Queue or Like acts on.</summary>
    public static void ShowMenu(MenuFlyout menu, FrameworkElement target, Windows.Foundation.Point? position)
    {
        // The row's own content panel gets the fill (the item's Background never reaches the presenter that draws
        // list fills), widened over the item's padding so the whole row reads as the target.
        if (target is SelectorItem selector && selector.ContentTemplateRoot is Panel row)
        {
            var (background, margin, padding, corner) = (row.Background, row.Margin, (row as Grid)?.Padding, (row as Grid)?.CornerRadius);
            var inset = selector.Padding;
            // The list's pointer-over fill made stronger, in the row's own theme: a brush looked up in the app's
            // resources is the app theme's, not the element's.
            row.Background = new SolidColorBrush(selector.ActualTheme == ElementTheme.Dark
                ? Windows.UI.Color.FromArgb(0x15, 0xFF, 0xFF, 0xFF) : Windows.UI.Color.FromArgb(0x0F, 0x00, 0x00, 0x00));
            row.Margin = new Thickness(margin.Left - inset.Left, margin.Top, margin.Right - inset.Right, margin.Bottom);
            if (row is Grid grid)
            {
                grid.Padding = new Thickness(inset.Left, grid.Padding.Top, inset.Right, grid.Padding.Bottom);
                grid.CornerRadius = new CornerRadius(4);
            }
            void Closed(object? sender, object e)
            {
                menu.Closed -= Closed;
                row.Background = background;
                row.Margin = margin;
                if (row is Grid g)
                {
                    g.Padding = padding ?? default;
                    g.CornerRadius = corner ?? default;
                }
            }
            menu.Closed += Closed;
        }
        if (position is { } p) menu.ShowAt(target, new FlyoutShowOptions { Position = p });
        else menu.ShowAt(target);
    }

    /// <summary>Calls <paramref name="nearEnd"/> when <paramref name="list"/>'s own scroller comes within a screen of its end.</summary>
    public static void OnNearEnd(ListViewBase list, Action nearEnd)
    {
        ScrollViewer? scroller = null;
        list.Loaded += (_, _) =>
        {
            if (scroller is not null) return;
            scroller = Descendant<ScrollViewer>(list);
            if (scroller is null) return;
            scroller.ViewChanged += (_, _) =>
            {
                if (scroller.ScrollableHeight > 0 && scroller.VerticalOffset > scroller.ScrollableHeight - Math.Max(600, scroller.ViewportHeight)) nearEnd();
            };
        };
    }

    public static bool IsInside(DependencyObject start, DependencyObject container)
    {
        for (var node = start; node is not null; node = VisualTreeHelper.GetParent(node))
            if (ReferenceEquals(node, container)) return true;
        return false;
    }

    public static T? Ancestor<T>(DependencyObject start) where T : DependencyObject
    {
        for (var node = start; node is not null; node = VisualTreeHelper.GetParent(node))
            if (node is T match) return match;
        return null;
    }

    public static T? Descendant<T>(DependencyObject root) where T : DependencyObject
    {
        var count = VisualTreeHelper.GetChildrenCount(root);
        for (var i = 0; i < count; i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is T match) return match;
            if (Descendant<T>(child) is { } deeper) return deeper;
        }
        return null;
    }
}
