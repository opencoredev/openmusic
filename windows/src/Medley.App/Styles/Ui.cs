using Microsoft.UI.Xaml;

namespace Medley.App;

/// <summary>Styles for UI built in code (Styles/Theme.xaml). Their ThemeResource setters follow the element's theme,
/// which a brush read from Application.Current.Resources doesn't.</summary>
public static class Ui
{
    public static Style Style(string key) => (Style)Application.Current.Resources[key];
}
