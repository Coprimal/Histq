using System.Reflection;
#if HISTQ_QA
using Histq.App.Graph;
#endif
using Histq.App.Shell;
using Histq.App.Shell.Tabs;
using Histq.App.Theme;
using Histq.Core;
using Microsoft.UI;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
#if HISTQ_QA
using Microsoft.UI.Xaml.Automation;
#endif
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.Graphics;
using WinRT.Interop;

namespace Histq.App;

/// <summary>
/// The main window: Mica (BaseAlt) where supported, else DesktopAcrylic, else a solid WindowBaseColor (macOS WindowGlass
/// base, Theme/Palette.xaml).
/// The content extends into a 48 epx title bar that is the tab row (design header-and-tab-row.md §1, layout B; Shell/
/// TitleBar, with the app menu); the page sheet under it is joined to the selected tab (§3.2), with the command bar
/// (Shell/CommandBar) on top and the selected tab's content (<see cref="TabContentHost"/>) under it; the 30 epx footer
/// is the gap under the sheet; toasts (<see cref="ToastHost"/>) show at its bottom right. One window's tabs are a
/// <see cref="WindowTabs"/>, changed only through <see cref="Apply"/>, which brings the title bar's tab row
/// (<see cref="TabStrip"/>) in line with them.
/// </summary>
public sealed partial class MainWindow : Window
{
    /// <summary>The entry assembly's informational version without its +commit suffix (the build's Version).</summary>
    private static string Version { get; } =
        (Assembly.GetEntryAssembly()?.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
            ?? "0.0.0").Split('+')[0];

    /// <summary>A saved frame smaller than this (physical pixels) is not restored.</summary>
    private const int MinRestoredWidth = 400;
    private const int MinRestoredHeight = 300;

    /// <summary>The app's windows: the app menu's and the command bar's actions go through it.</summary>
    internal WindowManager Manager { get; }

    /// <summary>This window's tabs; change them only through <see cref="Apply"/>.</summary>
    internal WindowTabs Tabs { get; }

    /// <summary>The window in the Window menu: its selected tab's title.</summary>
    internal string MenuTitle => Tabs.SelectedIndex is { } index ? DisplayText.Sanitize(Tabs.Tabs[index].Title) : "Histq";

    /// <summary>The window as Move Tab to Window › lists it (TabMenu.windowTitle): its selected tab's title, then its
    /// workspace's name or "Untitled", sanitized.</summary>
    internal string MoveTitle =>
        (Tabs.SelectedIndex is { } index ? DisplayText.Sanitize(Tabs.Tabs[index].Title) : "New Tab") + " \u2014 "
        + (Workspace is { } workspace ? DisplayText.Sanitize(workspace.Name) : "Untitled");

    /// <summary>The workspace the window belongs to; null for an Untitled window. Setting it shows its label in the
    /// command bar.</summary>
    internal WorkspaceDocument? Workspace
    {
        get => _workspace;
        set
        {
            _workspace = value;
            ShowWorkspace();
        }
    }

    /// <summary>The window's id in its workspace file: the file's on restore, else a new one. Stable while it is open.</summary>
    internal Guid WindowId { get; set; } = Guid.NewGuid();

    /// <summary>The window's place in the order the windows opened (a workspace's windows that are not in its file yet
    /// are written in this order).</summary>
    internal long Sequence { get; init; }

    /// <summary>The window's handle (a tab dropped on it is found by the window under the pointer).</summary>
    internal nint Handle => WindowNative.GetWindowHandle(this);

    /// <summary>The tabs or the frame changed: the session is saved (<see cref="WindowManager"/>).</summary>
    internal event EventHandler? StateChanged;

    // The inputs SheetPath was last built from, so a layout pass that changed nothing does not rebuild it.
    private Rect _sheetRect;
    private Rect? _sheetTab;
    private bool _sheetBuilt;

    /// <summary>The window's last frame in the normal (not minimized or maximized) state, in physical screen pixels:
    /// what the session saves, read without touching a closing window.</summary>
    private RectInt32 _frame;

    private WorkspaceDocument? _workspace;

#if HISTQ_QA
    private GraphCanvas? _qaGraph;

    /// <summary>
    /// The commit graph the spike harness sets its rows in and drives: made on first use and shown in place of the
    /// selected tab's content (the graph is the tab content of a spike run).
    /// </summary>
    internal GraphCanvas GraphCanvas => _qaGraph ??= ContentHost.ShowQaContent(NewQaGraph());

    /// <summary>
    /// QA bisect switch: while true, RootGrid.LayoutUpdated no longer rebuilds the sheet (selection and RootGrid size
    /// changes still do). The spike harness sets it for the scroll probe only.
    /// </summary>
    internal bool QaNoSheetLayoutHook { get; set; }

    /// <summary>QA counters, reset and read by the spike harness around the scroll probe.</summary>
    internal int QaLayoutUpdatedCount { get; set; }

    /// <summary><see cref="UpdateSheet"/> calls that ran past its early return (the sheet was rebuilt).</summary>
    internal int QaSheetUpdateCount { get; set; }

    /// <summary>TransformToVisual calls made by this window for the selected tab's bounds (the joined sheet).</summary>
    internal int QaTransformToVisualCount { get; set; }
#endif

    /// <param name="manager">The app's windows.</param>
    /// <param name="tabs">The window's tabs; the caller restores them through <see cref="Apply"/>.</param>
    /// <param name="saved">The saved window whose frame it takes, when that frame fits on a display; null for a new
    /// window.</param>
    internal MainWindow(WindowManager manager, WindowTabs tabs, SavedWindow? saved)
    {
        Manager = manager;
        Tabs = tabs;
        InitializeComponent();
        Title = "Histq";

        // In the constructor, so the system title bar never shows first. Tall needs ExtendsContentIntoTitleBar first.
        ExtendsContentIntoTitleBar = true;
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        StyleCaptionButtons(AppWindow.TitleBar);

        // The app menu's shortcuts, Alt and F10 on the root, so they work wherever the focus is.
        AppTitleBar.Attach(this, RootGrid);
        AppCommandBar.Attach(this);
        ContentHost.Attach(this);

        // Apply rebuilds the joined sheet in the same input event, so it moves in the same frame as the tab highlight;
        // the strip's scroll and selection slide steps (no layout pass) and every layout pass (resize, scale change,
        // title bar insets) catch position changes.
        AppTitleBar.TabStrip.GeometryChanged += (_, _) => UpdateSheet();
#if HISTQ_QA
        RootGrid.LayoutUpdated += (_, _) =>
        {
            QaLayoutUpdatedCount++;
            if (!QaNoSheetLayoutHook)
                UpdateSheet();
        };
        // Only while the bisect switch is on, so a size change still rebuilds the sheet without the layout hook.
        RootGrid.SizeChanged += (_, _) =>
        {
            if (QaNoSheetLayoutHook)
                UpdateSheet();
        };
#else
        RootGrid.LayoutUpdated += (_, _) => UpdateSheet();
#endif

        if (MicaController.IsSupported())
            SystemBackdrop = new MicaBackdrop { Kind = MicaKind.BaseAlt };
        else if (DesktopAcrylicController.IsSupported())
            SystemBackdrop = new DesktopAcrylicBackdrop();
        else
            RootGrid.Background = PaletteResources.Brush("WindowBaseBrush");

        VersionText.Text = $"v{Version}";

        if (saved is not null)
            RestoreFrame(saved);
        _frame = new RectInt32(AppWindow.Position.X, AppWindow.Position.Y, AppWindow.Size.Width, AppWindow.Size.Height);
        AppWindow.Changed += OnAppWindowChanged;
    }

    /// <summary>
    /// Runs <paramref name="change"/> on the tabs, then brings the content, the command bar and the footer in line with
    /// them (the tab's content swaps in this call, so in the same frame) and saves the session.
    /// </summary>
    internal void Apply(Action<WindowTabs> change)
    {
        change(Tabs);
        AppTitleBar.TabStrip.Sync(Tabs);
        ContentHost.Sync(Tabs);
        AppCommandBar.Update();
        UpdateFooter();
        UpdateSheet();
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Shows a warning toast at the window's bottom right (a refused tab move, a session not saved).</summary>
    internal void ShowToast(string title, string? detail) => Toasts.Show(title, detail);

    /// <summary>The recent repos changed (saved after an open): its Welcome page lists them again.</summary>
    internal void ShowRecentRepos() => ContentHost.ShowRecentRepos();

    /// <summary>
    /// The window as the session saves it: its own native "group" <paramref name="order"/> (front first; Windows has no
    /// native window tabs, so each window is alone in its group), its normal frame in physical screen pixels, its tabs.
    /// </summary>
    internal SavedWindow Saved(int order) =>
        new(_frame.X, _frame.Y, _frame.Width, _frame.Height, Group: order, TabIndex: 0, IsSelectedInGroup: true,
            Tabs.SavedTabs, Tabs.SavedSelectedIndex, Tabs.SavedTabGroups, Tabs.SavedClosedGroups);

    /// <summary>The window as <c>session.json</c> keeps a workspace window (<see cref="WorkspaceLayout"/>): as
    /// <see cref="Saved"/>, with its selected tab's path and its collapsed groups instead of its tabs (those are in
    /// the workspace file).</summary>
    internal WorkspaceLayout.Window LayoutWindow(int order) =>
        Tabs.LayoutWindow(WindowId, _frame.X, _frame.Y, _frame.Width, _frame.Height, order);

    /// <summary>The workspace label in the command bar from <see cref="Workspace"/> as it is now (name, read-only, last
    /// write's error).</summary>
    internal void ShowWorkspace() => AppCommandBar.ShowWorkspace(_workspace);

    /// <summary>
    /// Takes the saved frame (physical screen pixels, as <see cref="Saved"/> writes it) when it is big enough and its
    /// top edge lies on a display's work area, so the title bar can always be reached; else the system places the window.
    /// </summary>
    private void RestoreFrame(SavedWindow saved)
    {
        if (!double.IsFinite(saved.X) || !double.IsFinite(saved.Y) || !double.IsFinite(saved.Width)
            || !double.IsFinite(saved.Height) || saved.Width < MinRestoredWidth || saved.Height < MinRestoredHeight
            || Math.Abs(saved.X) > int.MaxValue / 2 || Math.Abs(saved.Y) > int.MaxValue / 2
            || saved.Width > int.MaxValue / 2 || saved.Height > int.MaxValue / 2)
            return;

        var frame = new RectInt32((int)saved.X, (int)saved.Y, (int)saved.Width, (int)saved.Height);
        if (DisplayArea.GetFromRect(frame, DisplayAreaFallback.None) is not { } display)
            return;
        RectInt32 work = display.WorkArea;
        bool topOnScreen = frame.Y >= work.Y && frame.Y < work.Y + work.Height
            && frame.X < work.X + work.Width && frame.X + frame.Width > work.X;
        if (topOnScreen)
            AppWindow.MoveAndResize(frame);
    }

    private void OnAppWindowChanged(AppWindow sender, AppWindowChangedEventArgs args)
    {
        if (!args.DidPositionChange && !args.DidSizeChange)
            return;
        if (sender.Presenter is OverlappedPresenter { State: not OverlappedPresenterState.Restored })
            return;
        _frame = new RectInt32(sender.Position.X, sender.Position.Y, sender.Size.Width, sender.Size.Height);
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>The footer's path: the selected tab's folder, sanitized (none for a Welcome tab), its tooltip the same.</summary>
    private void UpdateFooter()
    {
        string path = DisplayText.Sanitize(Tabs.SelectedIndex is { } index ? Tabs.Tabs[index].Path : null);
        if (string.Equals(PathText.Text, path, StringComparison.Ordinal))
            return;
        PathText.Text = path;
        ToolTipService.SetToolTip(PathText, path.Length == 0 ? null : path);
    }

#if HISTQ_QA
    private static GraphCanvas NewQaGraph()
    {
        var graph = new GraphCanvas();
        AutomationProperties.SetName(graph, "Commit graph");
        return graph;
    }
#endif

    /// <summary>
    /// Rebuilds the joined sheet: inset 8 epx from the window's left and right edges, from the title bar's bottom edge
    /// down to the footer's top, with the selected tab joined to it.
    /// </summary>
    private void UpdateSheet()
    {
        double inset = SheetTabShape.SheetInset;
        double top = AppTitleBar.ActualHeight;
        var sheet = new Rect(
            inset,
            top,
            Math.Max(0, RootGrid.ActualWidth - 2 * inset),
            Math.Max(0, RootGrid.ActualHeight - top - Footer.ActualHeight));
        Rect? tab = SelectedTabBounds();
        if (_sheetBuilt && sheet == _sheetRect && tab == _sheetTab)
            return;
        // A new Data lays the window out again (RootGrid.LayoutUpdated calls back here): counted by the strip's
        // layout-loop tripwire, which holds the sheet as it is for the rest of a turn that loops.
        if (!AppTitleBar.TabStrip.CountPass("MainWindow.UpdateSheet"))
            return;

#if HISTQ_QA
        QaSheetUpdateCount++;
#endif
        _sheetBuilt = true;
        _sheetRect = sheet;
        _sheetTab = tab;
        SheetPath.Data = SheetTabShape.Create(sheet, tab);
    }

    /// <summary>
    /// The selected tab's bounds in RootGrid (and so SheetPath) coordinates as the strip shows it (mid-slide included),
    /// or null before layout, or while the tab is hidden or cut by the track's edge or a narrow window.
    /// </summary>
    private Rect? SelectedTabBounds()
    {
        TabStrip strip = AppTitleBar.TabStrip;
        if (strip.XamlRoot is null || strip.SelectedTabRect() is not { } tab)
            return null;
#if HISTQ_QA
        QaTransformToVisualCount++;
#endif
        return strip.TransformToVisual(RootGrid).TransformBounds(tab);
    }

    /// <summary>
    /// Caption buttons (design §1): transparent backgrounds, hover fill white at 0.10, pressed 0.20; Close hover stays
    /// the system red. The system ignores alpha on foreground colors, so white at 0.85 (active) and 0.45 (inactive) are
    /// pre-blended over the window base (CaptionForegroundColor, CaptionInactiveForegroundColor).
    /// </summary>
    private static void StyleCaptionButtons(AppWindowTitleBar bar)
    {
        var foreground = PaletteResources.Color("CaptionForegroundColor");
        bar.ButtonBackgroundColor = Colors.Transparent;
        bar.ButtonInactiveBackgroundColor = Colors.Transparent;
        bar.ButtonHoverBackgroundColor = PaletteResources.Color("HoverFillColor");
        bar.ButtonPressedBackgroundColor = PaletteResources.Color("PressedFillColor");
        bar.ButtonForegroundColor = foreground;
        bar.ButtonHoverForegroundColor = foreground;
        bar.ButtonPressedForegroundColor = foreground;
        bar.ButtonInactiveForegroundColor = PaletteResources.Color("CaptionInactiveForegroundColor");
    }
}
