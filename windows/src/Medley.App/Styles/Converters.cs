using Medley.App.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;

namespace Medley.App.Styles;

// Shared converters for {Binding}. x:Bind pages call the static helpers in Format directly (faster, no boxing).

public sealed partial class BoolToVisibilityConverter : IValueConverter
{
    public bool Invert { get; set; }

    public object Convert(object value, Type targetType, object parameter, string language) =>
        (value is true) != Invert ? Visibility.Visible : Visibility.Collapsed;

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        (value is Visibility.Visible) != Invert;
}

public sealed partial class NullToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language) =>
        value is null || value is string { Length: 0 } ? Visibility.Collapsed : Visibility.Visible;

    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

public sealed partial class DurationConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language) =>
        Format.Time(value is double d ? d : null);

    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}
