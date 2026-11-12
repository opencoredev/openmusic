using Medley.App.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Medley.App.Controls;

/// <summary>
/// Cover art with rounded corners and a placeholder fill while it loads (or when there is none). Art comes through
/// <see cref="ArtworkLoader"/>, decoded at the size the view is laid out at (its longer side, in effective pixels,
/// times the display's scale). <see cref="Pixels"/> is only the size to ask for before the first layout.
/// <code>&lt;controls:ArtworkView Source="{x:Bind Artwork}" CornerRadius="8" Width="172" Height="172"/&gt;</code>
/// </summary>
public sealed partial class ArtworkView : Grid
{
    // An Image, not an ImageBrush on a Border: XAML draws an Image's source straight from its decoded surface. The
    // Grid's CornerRadius clips it.
    private readonly Image _brush = new() { Stretch = Stretch.UniformToFill, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };

    public static readonly DependencyProperty SourceProperty = DependencyProperty.Register(
        nameof(Source), typeof(Uri), typeof(ArtworkView), new PropertyMetadata(null, (d, _) => ((ArtworkView)d).Reload()));

    public static readonly DependencyProperty PixelsProperty = DependencyProperty.Register(
        nameof(Pixels), typeof(int), typeof(ArtworkView), new PropertyMetadata(200, (d, _) => ((ArtworkView)d).Reload()));

    public Uri? Source
    {
        get => (Uri?)GetValue(SourceProperty);
        set => SetValue(SourceProperty, value);
    }

    public int Pixels
    {
        get => (int)GetValue(PixelsProperty);
        set => SetValue(PixelsProperty, value);
    }

    public ArtworkView()
    {
        Children.Add(_brush);
        // Gray at low alpha reads as a placeholder on light and dark backgrounds alike.
        Background = new SolidColorBrush(Windows.UI.Color.FromArgb(0x26, 0x80, 0x80, 0x80));
        Loaded += (_, _) => Reload();
        // A view laid out larger than it asked for (or moved to a screen with another scale) asks again.
        SizeChanged += (_, _) => Reload();
    }

    private void Reload()
    {
        if (Source is null)
        {
            if (Art.GetSource(_brush) is not null) Art.Set(_brush, null, Pixels, 1);
            return;
        }
        var logical = Math.Max(ActualWidth, ActualHeight);
        if (logical <= 0)
        {
            var w = double.IsNaN(Width) ? 0 : Width;
            var h = double.IsNaN(Height) ? 0 : Height;
            logical = Math.Max(w, h);
            // Not laid out yet and no size of its own (a card's art fills its cell): wait for SizeChanged, so the first
            // request is already at the size shown.
            if (logical <= 0) return;
        }
        var scale = XamlRoot?.RasterizationScale ?? 1.0;
        var pixels = (int)Math.Ceiling(logical);
        if (Source == Art.GetSource(_brush) && Art.Bucket(pixels * scale) == Art.RequestedPixels(_brush)) return;
        Art.Set(_brush, Source, pixels, scale);
    }
}
