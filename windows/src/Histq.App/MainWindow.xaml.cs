using System.Reflection;
using Microsoft.UI;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace Histq.App;

/// <summary>
/// The main window: Mica (BaseAlt) where supported, else DesktopAcrylic, else a solid #1C1C1E (macOS WindowGlass base).
/// </summary>
public sealed partial class MainWindow : Window
{
    /// <summary>The entry assembly's informational version (the build's Version plus any +commit suffix).</summary>
    private static string Version { get; } =
        Assembly.GetEntryAssembly()?.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
        ?? "0.0.0";

    public MainWindow()
    {
        InitializeComponent();
        Title = "Histq";

        if (MicaController.IsSupported())
            SystemBackdrop = new MicaBackdrop { Kind = MicaKind.BaseAlt };
        else if (DesktopAcrylicController.IsSupported())
            SystemBackdrop = new DesktopAcrylicBackdrop();
        else
            RootGrid.Background = new SolidColorBrush(ColorHelper.FromArgb(0xFF, 0x1C, 0x1C, 0x1E));

        VersionText.Text = $"Histq {Version}";
    }
}
