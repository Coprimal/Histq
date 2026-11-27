using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Histq.App.Theme;

/// <summary>
/// Theme/Palette.xaml values for code that cannot use <c>{StaticResource}</c> (Win2D draws, AppWindow caption colors,
/// brushes made in code). Reads <c>Application.Current.Resources</c>: call it on the UI thread, after the App's
/// InitializeComponent, never from a static field initializer.
/// </summary>
internal static class PaletteResources
{
    public static Color Color(string key) => (Color)Application.Current.Resources[key];

    public static Brush Brush(string key) => (Brush)Application.Current.Resources[key];

    public static double Double(string key) => (double)Application.Current.Resources[key];

    /// <summary>A motion resource (an x:String time span such as "00:00:00.250").</summary>
    public static TimeSpan TimeSpan(string key) =>
        System.TimeSpan.Parse((string)Application.Current.Resources[key], CultureInfo.InvariantCulture);
}
