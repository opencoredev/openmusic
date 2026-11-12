using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Markup;

namespace Medley.App.Controls;

/// <summary>
/// The marks sign-in buttons and service rows show: Apple's logo (in the text color, as Apple's guidelines ask for a
/// plain button), Google's "G" in its four colors, Spotify's and YouTube Music's logos. Drawn as paths at any size.
/// </summary>
public static class BrandMarks
{
    private const string Ns = "xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\"";

    public static FrameworkElement Apple(double size = 16) => Load($$"""
        <Viewbox {{Ns}} Width="{{size}}" Height="{{size}}" Stretch="Uniform">
          <Path Fill="{ThemeResource TextFillColorPrimaryBrush}" Data="M 788.1 340.9 c -5.8 4.5 -108.2 62.2 -108.2 190.5 c 0 148.4 130.3 200.9 134.2 202.2 c -0.6 3.2 -20.7 71.9 -68.7 141.9 c -42.8 61.6 -87.5 123.1 -155.5 123.1 s -85.5 -39.5 -164 -39.5 c -76.5 0 -103.7 40.8 -165.9 40.8 s -105.6 -57 -155.5 -127 C 46.7 790.7 0 663 0 541.8 c 0 -194.4 126.4 -297.5 250.8 -297.5 c 66.1 0 121.2 43.4 162.7 43.4 c 39.5 0 101.1 -46 176.3 -46 c 28.5 0 130.9 2.6 198.3 99.2 Z m -234 -181.5 c 31.1 -36.9 53.1 -88.1 53.1 -139.3 c 0 -7.1 -0.6 -14.3 -1.9 -20.1 c -50.6 1.9 -110.8 33.7 -147.1 75.8 c -28.5 32.4 -55.1 83.6 -55.1 135.5 c 0 7.8 1.3 15.6 1.9 18.1 c 3.2 0.6 8.4 1.3 13.6 1.3 c 45.4 0 102.5 -30.4 135.5 -71.3 Z" />
        </Viewbox>
        """);

    public static FrameworkElement Google(double size = 16) => Load($$"""
        <Viewbox {{Ns}} Width="{{size}}" Height="{{size}}" Stretch="Uniform">
          <Canvas Width="18" Height="18">
            <Path Fill="#4285F4" Data="M 17.64 9.2 c 0 -0.637 -0.057 -1.251 -0.164 -1.84 H 9 v 3.481 h 4.844 c -0.209 1.125 -0.843 2.078 -1.796 2.717 v 2.258 h 2.908 c 1.702 -1.567 2.684 -3.874 2.684 -6.615 Z" />
            <Path Fill="#34A853" Data="M 9 18 c 2.43 0 4.467 -0.806 5.956 -2.18 l -2.908 -2.259 c -0.806 0.54 -1.837 0.86 -3.048 0.86 c -2.344 0 -4.328 -1.584 -5.036 -3.711 H 0.957 v 2.332 A 8.997 8.997 0 0 0 9 18 Z" />
            <Path Fill="#FBBC05" Data="M 3.964 10.71 A 5.41 5.41 0 0 1 3.682 9 c 0 -0.593 0.102 -1.17 0.282 -1.71 V 4.958 H 0.957 A 8.996 8.996 0 0 0 0 9 c 0 1.452 0.348 2.827 0.957 4.042 l 3.007 -2.332 Z" />
            <Path Fill="#EA4335" Data="M 9 3.58 c 1.321 0 2.508 0.454 3.44 1.345 l 2.582 -2.58 C 13.463 0.891 11.426 0 9 0 A 8.997 8.997 0 0 0 0.957 4.958 L 3.964 7.29 C 4.672 5.163 6.656 3.58 9 3.58 Z" />
          </Canvas>
        </Viewbox>
        """);

    public static FrameworkElement Spotify(double size = 40) => Load($$"""
        <Viewbox {{Ns}} Width="{{size}}" Height="{{size}}" Stretch="Uniform">
          <Canvas Width="24" Height="24">
            <Ellipse Width="20" Height="20" Canvas.Left="2" Canvas.Top="2" Fill="#191414" />
            <Path Fill="#1ED760" Data="F0 M 12 0 C 5.4 0 0 5.4 0 12 s 5.4 12 12 12 s 12 -5.4 12 -12 S 18.66 0 12 0 Z m 5.521 17.34 c -0.24 0.359 -0.66 0.48 -1.021 0.24 c -2.82 -1.74 -6.36 -2.101 -10.561 -1.141 c -0.418 0.122 -0.779 -0.179 -0.899 -0.539 c -0.12 -0.421 0.18 -0.78 0.54 -0.9 c 4.56 -1.021 8.52 -0.6 11.64 1.32 c 0.42 0.18 0.479 0.659 0.301 1.02 Z m 1.44 -3.3 c -0.301 0.42 -0.841 0.6 -1.262 0.3 c -3.239 -1.98 -8.159 -2.58 -11.939 -1.38 c -0.479 0.12 -1.02 -0.12 -1.14 -0.6 c -0.12 -0.48 0.12 -1.021 0.6 -1.141 C 9.6 9.9 15 10.561 18.72 12.84 c 0.361 0.181 0.54 0.78 0.241 1.2 Z m 0.12 -3.36 C 15.24 8.4 8.82 8.16 5.16 9.301 c -0.6 0.179 -1.2 -0.181 -1.38 -0.721 c -0.18 -0.601 0.18 -1.2 0.72 -1.381 c 4.26 -1.26 11.28 -1.02 15.721 1.621 c 0.539 0.3 0.719 1.02 0.419 1.56 c -0.299 0.421 -1.02 0.599 -1.559 0.3 Z" />
          </Canvas>
        </Viewbox>
        """);

    public static FrameworkElement YouTubeMusic(double size = 40) => Load($$"""
        <Viewbox {{Ns}} Width="{{size}}" Height="{{size}}" Stretch="Uniform">
          <Canvas Width="24" Height="24">
            <Ellipse Width="24" Height="24" Fill="#FF0033" />
            <Ellipse Width="13" Height="13" Canvas.Left="5.5" Canvas.Top="5.5" Stroke="White" StrokeThickness="1.3" />
            <Path Fill="White" Data="M 10.2 8.9 L 15.1 12 L 10.2 15.1 Z" />
          </Canvas>
        </Viewbox>
        """);

    private static FrameworkElement Load(string xaml) => (FrameworkElement)XamlReader.Load(xaml);
}
