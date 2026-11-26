using System.Reflection;
using Histq.App.Graph;
using Histq.App.Shell;
using Microsoft.UI;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace Histq.App;

/// <summary>
/// The main window: Mica (BaseAlt) where supported, else DesktopAcrylic, else a solid #1C1C1E (macOS WindowGlass base).
/// The content extends into a 48 epx title bar that is the tab row (design header-and-tab-row.md §1, layout B); the
/// page sheet under it is joined to the selected tab (§3.2).
/// </summary>
public sealed partial class MainWindow : Window
{
    /// <summary>The entry assembly's informational version (the build's Version plus any +commit suffix).</summary>
    private static string Version { get; } =
        Assembly.GetEntryAssembly()?.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
        ?? "0.0.0";

    /// <summary>The title bar's Passthrough regions; call <see cref="TitleBarRegions.Refresh"/> after a tab-model change.</summary>
    internal TitleBarRegions TitleBarRegions { get; }

    /// <summary>The commit graph in the sheet (the spike harness sets its rows and drives it).</summary>
    internal GraphCanvas GraphCanvas => CommitGraph;

    // The inputs SheetPath was last built from, so a layout pass that changed nothing does not rebuild it.
    private Rect _sheetRect;
    private Rect? _sheetTab;
    private bool _sheetBuilt;

    public MainWindow()
    {
        InitializeComponent();
        Title = "Histq";

        // In the constructor, so the system title bar never shows first. Tall needs ExtendsContentIntoTitleBar first.
        ExtendsContentIntoTitleBar = true;
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        StyleCaptionButtons(AppWindow.TitleBar);

        TitleBarRegions = new TitleBarRegions(
            this,
            AppTitleBar,
            LeftInsetColumn,
            RightInsetColumn,
            () => TabStrip.Tabs.Where(IsTabShown).Prepend(LogoButton));
        TabStrip.TitleBarRegions = TitleBarRegions;

        // Selection rebuilds the joined sheet in the same input event, so it moves in the same frame as the tab
        // highlight; every layout pass (resize, scale change, title bar insets) catches position changes.
        TabStrip.SelectionChanged += (_, _) => UpdateSheet();
        RootGrid.LayoutUpdated += (_, _) => UpdateSheet();

        if (MicaController.IsSupported())
            SystemBackdrop = new MicaBackdrop { Kind = MicaKind.BaseAlt };
        else if (DesktopAcrylicController.IsSupported())
            SystemBackdrop = new DesktopAcrylicBackdrop();
        else
            RootGrid.Background = new SolidColorBrush(ColorHelper.FromArgb(0xFF, 0x1C, 0x1C, 0x1E));

        VersionText.Text = $"Histq {Version}";
    }

    /// <summary>
    /// Rebuilds the joined sheet: inset 8 epx from the window's left, right and bottom edges, from the title bar's bottom
    /// edge down, with the selected tab joined to it.
    /// </summary>
    private void UpdateSheet()
    {
        double inset = SheetTabShape.SheetInset;
        double top = AppTitleBar.ActualHeight;
        var sheet = new Rect(
            inset,
            top,
            Math.Max(0, RootGrid.ActualWidth - 2 * inset),
            Math.Max(0, RootGrid.ActualHeight - top - inset));
        Rect? tab = SelectedTabBounds();
        if (_sheetBuilt && sheet == _sheetRect && tab == _sheetTab)
            return;

        _sheetBuilt = true;
        _sheetRect = sheet;
        _sheetTab = tab;
        SheetPath.Data = SheetTabShape.Create(sheet, tab);
    }

    /// <summary>The selected tab's bounds in RootGrid (and so SheetPath) coordinates, or null before layout.</summary>
    private Rect? SelectedTabBounds()
    {
        FrameworkElement tab = TabStrip.Tabs[TabStrip.SelectedIndex];
        if (!IsTabShown(tab) || tab.ActualHeight <= 0)
            return null;
        return tab.TransformToVisual(RootGrid).TransformBounds(new Rect(0, 0, tab.ActualWidth, tab.ActualHeight));
    }

    /// <summary>
    /// True when the tab ends before the free drag column. A tab that a narrow window clips takes no input and gets no
    /// sheet bump, so the drag column stays caption (phase 9 replaces this with the scrolling track).
    /// </summary>
    private bool IsTabShown(FrameworkElement tab)
    {
        if (tab.XamlRoot is null || tab.ActualWidth <= 0)
            return false;
        // The inset width, not the star column's ActualWidth: Refresh sets it just before it asks for the elements.
        double limit = AppTitleBar.ActualWidth - RightInsetColumn.Width.Value - DragColumn.MinWidth;
        double right = tab.TransformToVisual(AppTitleBar).TransformPoint(new Point(tab.ActualWidth, 0)).X;
        return right <= limit + 0.5;
    }

    /// <summary>
    /// Caption buttons (design §1): transparent backgrounds, hover fill white at 0.10, pressed 0.20; Close hover stays
    /// the system red. The system ignores alpha on foreground colors, so white at 0.85 (active) and 0.45 (inactive) are
    /// pre-blended over the #1C1C1E window base.
    /// </summary>
    private static void StyleCaptionButtons(AppWindowTitleBar bar)
    {
        var foreground = ColorHelper.FromArgb(0xFF, 0xDD, 0xDD, 0xDD);
        bar.ButtonBackgroundColor = Colors.Transparent;
        bar.ButtonInactiveBackgroundColor = Colors.Transparent;
        bar.ButtonHoverBackgroundColor = ColorHelper.FromArgb(0x1A, 0xFF, 0xFF, 0xFF);
        bar.ButtonPressedBackgroundColor = ColorHelper.FromArgb(0x33, 0xFF, 0xFF, 0xFF);
        bar.ButtonForegroundColor = foreground;
        bar.ButtonHoverForegroundColor = foreground;
        bar.ButtonPressedForegroundColor = foreground;
        bar.ButtonInactiveForegroundColor = ColorHelper.FromArgb(0xFF, 0x82, 0x82, 0x83);
    }
}
