using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Medley.App.Pages;

/// <summary>
/// The album and playlist header at the page's width: a 232 px cover beside a 40 px title when there's room; a compact
/// one (128 px cover, 24 px title wrapping to two lines) when the page is narrow (a small window, or the lyrics pane
/// open beside it), so the songs stay in view; the cover above the title only when even that doesn't fit.
/// </summary>
public static class HeaderLayout
{
    /// <summary>Below this page width the header is compact.</summary>
    public const double CompactBelow = 640;
    /// <summary>Below this page width the header stacks.</summary>
    public const double StackBelow = 420;

    public static void Apply(double pageWidth, FrameworkElement cover, FrameworkElement text, TextBlock title)
    {
        var stacked = pageWidth < StackBelow;
        var compact = pageWidth < CompactBelow;
        cover.Width = cover.Height = stacked ? 160 : compact ? 128 : pageWidth < 860 ? 196 : 232;
        Grid.SetRow(text, stacked ? 1 : 0);
        Grid.SetColumn(text, stacked ? 0 : 1);
        Grid.SetColumnSpan(text, stacked ? 2 : 1);
        text.Margin = new Thickness(stacked || !compact ? 0 : -4, stacked ? 20 : 0, 0, 0);
        title.Style = Ui.Style(compact ? "TitleTextBlockStyle" : "TitleLargeTextBlockStyle");
        if (compact) title.FontSize = 24;
        else title.ClearValue(TextBlock.FontSizeProperty);
    }
}
