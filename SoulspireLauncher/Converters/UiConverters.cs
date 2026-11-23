using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;
using SoulspireLauncher.Models;

namespace SoulspireLauncher.Converters;

public sealed class BoolToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        var flag = value is bool b && b;
        if (parameter is string s && s.Equals("Invert", StringComparison.OrdinalIgnoreCase))
        {
            flag = !flag;
        }

        return flag ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is Visibility v && v == Visibility.Visible;
}

public sealed class BoolToStatusBrushConverter : IValueConverter
{
    private static readonly Brush OnlineBrush = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#39CFE5"));
    private static readonly Brush OfflineBrush = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#F87171"));

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is true ? OnlineBrush : OfflineBrush;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class ChannelToBrushConverter : IValueConverter
{
    private static readonly Brush StableBrush = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#39CFE5"));
    private static readonly Brush TestingBrush = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#8063BC"));

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is UpdateChannel.Testing or UpdateChannel.TestingRegistry24Hook ? TestingBrush : StableBrush;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class ChannelToBadgeBackgroundConverter : IValueConverter
{
    private static readonly Brush StableBg = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#122634"));
    private static readonly Brush TestingBg = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#241B3B"));

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is UpdateChannel.Testing or UpdateChannel.TestingRegistry24Hook ? TestingBg : StableBg;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class ChannelToLabelConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value switch
        {
            UpdateChannel.Stable => "Stable",
            UpdateChannel.Testing => "Testing (27-Hook Weapon Templates)",
            UpdateChannel.TestingRegistry24Hook => "Testing — Registry 24-Hook (Search Fix)",
            _ => value?.ToString() ?? string.Empty
        };

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class DiagStatusToBrushConverter : IValueConverter
{
    private static readonly Brush PassBrush = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#39CFE5"));
    private static readonly Brush FailBrush = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#F87171"));
    private static readonly Brush UnknownBrush = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#E8BD70"));

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        (value as string)?.Trim().ToUpperInvariant() switch
        {
            "PASS" => PassBrush,
            "FAIL" => FailBrush,
            _ => UnknownBrush
        };

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class BoolToReadyTextConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is true ? "READY" : "MISSING";

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class FpsCapLabelConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value switch
        {
            60 => "60 FPS (Smooth)",
            30 => "30 FPS (Classic)",
            0 => "Uncapped",
            _ => value?.ToString() ?? string.Empty
        };

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}
