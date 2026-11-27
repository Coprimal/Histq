using Histq.App.Shell.Tabs;
using Histq.Core;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Windows.System;
using Windows.UI.Core;

namespace Histq.App.Shell;

/// <summary>
/// The window's title bar (design header-and-tab-row.md §1, ported from the logo of App/Window/HeaderToolbar.swift and
/// the main menu of App/HistqApp.swift at 6fa6d40): the logo, which opens the app menu (File with the workspace items,
/// Edit, View, Window, Help; Windows has no menu bar), the tab strip (<see cref="Tabs.TabStrip"/>), a free drag area and the caption buttons'
/// inset. Only the logo and the strip's items are Passthrough (<see cref="TitleBarRegions"/>); the rest is caption.
/// The menu holds only the items whose action works in this build; Mac-only items (Hide, Hide Others, Minimize,
/// Customize Toolbar, Merge All Windows) are left out. Its shortcuts and the tab shortcuts (<see cref="Accelerators"/>,
/// Ctrl for Cmd) work with the menu closed, and a lone Alt press or F10 opens it. While a tab press is held (a drag) the
/// Passthrough regions stay as they are.
/// </summary>
public sealed partial class TitleBar : UserControl
{
    private MainWindow _window = null!;
    private MenuFlyoutSubItem _windowMenu = null!;
    private MenuFlyoutItem _reopenItem = null!;
    private MenuFlyoutSubItem _recentWorkspacesMenu = null!;
    private MenuFlyoutItem _closeWorkspaceItem = null!;
    private MenuFlyoutItem _tabPositionItem = null!;

    /// <summary>Alt went down with no other key or click since: its release opens the app menu.</summary>
    private bool _altAlone;

    /// <summary>The tabs show in the vertical panel: the bar holds only the logo, a drag area and the caption buttons.
    /// </summary>
    private bool _tabsOnLeft;

    public TitleBar()
    {
        InitializeComponent();
    }

    /// <summary>The title bar's Passthrough regions; refreshed whenever the tab strip's geometry changes.</summary>
    internal TitleBarRegions Regions { get; private set; } = null!;

    /// <summary>The tab row, bound to the window's tabs (<see cref="MainWindow.Apply"/> syncs it).</summary>
    internal TabStrip TabStrip => Strip;

    /// <summary>
    /// Wires the title bar to <paramref name="window"/>: its Passthrough regions, and the app menu, whose shortcuts and
    /// Alt / F10 are taken on <paramref name="keyScope"/> (the window's root, so they work wherever the focus is).
    /// </summary>
    internal void Attach(MainWindow window, UIElement keyScope)
    {
        _window = window;
        Regions = new TitleBarRegions(
            window,
            BarGrid,
            LeftInsetColumn,
            RightInsetColumn,
            () => _tabsOnLeft ? [LogoButton] : Strip.InteractiveElements().Prepend(LogoButton),
            element => ReferenceEquals(element, LogoButton) ? null : Strip.ClipOf(element));
        Strip.Attach(window);
        Strip.GeometryChanged += (_, _) => Regions.Refresh();
        Strip.PressHeldChanged += (_, held) => Regions.Frozen = held;
        // A flyout anchored in the row (group, archive, closed groups, All Tabs) closed: the rects are set again.
        Strip.FlyoutClosed += (_, _) => Regions.RefreshAll();

        BuildAppMenu();
        Accelerators.Register(keyScope, window, OpenAppMenu);
        keyScope.KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        keyScope.PreviewKeyDown += OnPreviewKeyDown;
        keyScope.PreviewKeyUp += OnPreviewKeyUp;
        keyScope.AddHandler(PointerPressedEvent, new PointerEventHandler((_, _) => _altAlone = false), true);
        window.Activated += (_, _) => _altAlone = false;
    }

    /// <summary>
    /// With the tabs on the left (design §4) the strip is not shown and only the logo stays Passthrough: the rest of
    /// the bar is caption. With the tabs on top, the strip is back. Its Passthrough rects are set again at once.
    /// </summary>
    internal void SetTabsOnLeft(bool left)
    {
        if (_tabsOnLeft == left)
            return;
        _tabsOnLeft = left;
        TabStripHost.Visibility = left ? Visibility.Collapsed : Visibility.Visible;
        Regions?.RefreshAll();
    }

    /// <summary>Opens the app menu under the logo, or closes it when it is open.</summary>
    internal void OpenAppMenu()
    {
        if (AppMenu.IsOpen)
        {
            AppMenu.Hide();
            return;
        }

        AppMenu.ShowAt(LogoButton, new FlyoutShowOptions
        {
            Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft,
            ShowMode = FlyoutShowMode.Standard,
        });
    }

    /// <summary>
    /// The app menu (HistqApp.swift makeMainMenu): File has New Window, New Tab, Open…, the workspace items (New
    /// Workspace, Open Workspace…, Recent Workspaces ›, Save Workspace As…, Close Workspace; WorkspaceCommands.cs), Close
    /// Tab, Reopen Closed Tab, Close Window and Exit (the app menu's Quit); View has Move Tabs to the Left (Move Tabs to
    /// the Top while they are there; HistqApp.swift:1674-1700); Window has Maximize / Restore (Zoom) and the open
    /// windows. Edit and Help keep their place but stay disabled until the phases that bring their items (the undo
    /// journal and text fields, the onboarding).
    /// </summary>
    private void BuildAppMenu()
    {
        var file = new MenuFlyoutSubItem { Text = "File" };
        file.Items.Add(Item("New Window", AppCommand.NewWindow));
        file.Items.Add(Item("New Tab", AppCommand.NewTab));
        file.Items.Add(Item("Open…", AppCommand.Open));
        file.Items.Add(new MenuFlyoutSeparator());
        file.Items.Add(Plain("New Workspace", () => _window.Manager.NewWorkspace(_window)));
        file.Items.Add(Plain("Open Workspace…", () => _window.Manager.ChooseWorkspace(_window)));
        _recentWorkspacesMenu = new MenuFlyoutSubItem { Text = "Recent Workspaces" };
        file.Items.Add(_recentWorkspacesMenu);
        file.Items.Add(Plain("Save Workspace As…", () => _window.Manager.SaveWorkspaceAs(_window)));
        _closeWorkspaceItem = Plain("Close Workspace", () => _window.Manager.CloseWorkspace(_window));
        file.Items.Add(_closeWorkspaceItem);
        file.Items.Add(new MenuFlyoutSeparator());
        file.Items.Add(Item("Close Tab", AppCommand.CloseTab));
        _reopenItem = Item("Reopen Closed Tab", AppCommand.ReopenClosedTab);
        file.Items.Add(_reopenItem);
        file.Items.Add(Item("Close Window", AppCommand.CloseWindow));
        file.Items.Add(new MenuFlyoutSeparator());
        file.Items.Add(Item("Exit", AppCommand.Exit));

        var view = new MenuFlyoutSubItem { Text = "View" };
        _tabPositionItem = Plain(TabPositionTitle(), ToggleTabPosition);
        view.Items.Add(_tabPositionItem);

        _windowMenu = new MenuFlyoutSubItem { Text = "Window" };
        AppMenu.Items.Add(file);
        AppMenu.Items.Add(new MenuFlyoutSubItem { Text = "Edit", IsEnabled = false });
        AppMenu.Items.Add(view);
        AppMenu.Items.Add(_windowMenu);
        AppMenu.Items.Add(new MenuFlyoutSubItem { Text = "Help", IsEnabled = false });
        AppMenu.Opening += (_, _) =>
        {
            _reopenItem.IsEnabled = _window.Tabs.CanReopenClosedTab;
            _closeWorkspaceItem.IsEnabled = _window.Workspace is { IsClosing: false };
            _tabPositionItem.Text = TabPositionTitle();
            FillRecentWorkspaces();
            FillWindowMenu();
        };
    }

    /// <summary>The View menu's tab position item: where the tabs would go.</summary>
    private string TabPositionTitle() =>
        _window.TabPosition == TabPosition.Left ? "Move Tabs to the Top" : "Move Tabs to the Left";

    /// <summary>Moves every window's tabs to the other side (<see cref="WindowManager.SetTabPosition"/>).</summary>
    private void ToggleTabPosition() => _window.Manager.SetTabPosition(
        _window.TabPosition == TabPosition.Left ? TabPosition.Top : TabPosition.Left);

    /// <summary>A menu item with no shortcut that runs <paramref name="action"/>.</summary>
    private static MenuFlyoutItem Plain(string text, Action action)
    {
        var item = new MenuFlyoutItem { Text = text };
        item.Click += (_, _) => action();
        return item;
    }

    /// <summary>Recent Workspaces: the files opened lately, most recent first (a pick opens it; its path is the
    /// tooltip), then Clear Menu. Built from the list in memory each time the menu opens, never checking the disk.</summary>
    private void FillRecentWorkspaces()
    {
        _recentWorkspacesMenu.Items.Clear();
        PathFlavor flavor = PathFlavor.Host;
        foreach (string path in _window.Manager.RecentWorkspaces.Paths)
        {
            var item = new MenuFlyoutItem
            {
                Text = DisplayText.Sanitize(Path.GetFileNameWithoutExtension(flavor.LastComponent(path))),
            };
            ToolTipService.SetToolTip(item, DisplayText.Sanitize(path));
            item.Click += (_, _) => _window.Manager.OpenWorkspace(path, _window);
            _recentWorkspacesMenu.Items.Add(item);
        }

        if (_recentWorkspacesMenu.Items.Count > 0)
            _recentWorkspacesMenu.Items.Add(new MenuFlyoutSeparator());
        var clear = new MenuFlyoutItem
        {
            Text = "Clear Menu",
            IsEnabled = _window.Manager.RecentWorkspaces.Paths.Count > 0,
        };
        clear.Click += (_, _) => _window.Manager.ClearRecentWorkspaces();
        _recentWorkspacesMenu.Items.Add(clear);
    }

    /// <summary>A menu item that runs <paramref name="command"/>; it only shows the command's shortcut, which
    /// <see cref="Accelerators"/> registers once on the window's root (so it never runs twice).</summary>
    private MenuFlyoutItem Item(string text, AppCommand command)
    {
        var item = new MenuFlyoutItem { Text = text, KeyboardAcceleratorTextOverride = Accelerators.ShortcutText(command) };
        item.Click += (_, _) => Accelerators.Run(command, _window);
        return item;
    }

    /// <summary>Window: Maximize or Restore (the Mac's Zoom), then the open windows, this one checked; a pick brings
    /// that window forward. Filled each time the menu opens.</summary>
    private void FillWindowMenu()
    {
        _windowMenu.Items.Clear();
        bool maximized = _window.AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Maximized };
        var zoom = new MenuFlyoutItem { Text = maximized ? "Restore" : "Maximize" };
        zoom.Click += (_, _) =>
        {
            if (_window.AppWindow.Presenter is not OverlappedPresenter presenter)
                return;
            if (presenter.State == OverlappedPresenterState.Maximized)
                presenter.Restore();
            else
                presenter.Maximize();
        };
        _windowMenu.Items.Add(zoom);
        _windowMenu.Items.Add(new MenuFlyoutSeparator());

        foreach (MainWindow window in _window.Manager.Windows)
        {
            var item = new ToggleMenuFlyoutItem { Text = window.MenuTitle, IsChecked = window == _window };
            item.Click += (_, _) => _window.Manager.Show(window);
            _windowMenu.Items.Add(item);
        }
    }

    // A lone Alt press opens the app menu on its release, as a menu bar would; Alt with another key or a click (Alt+Tab,
    // Alt+F4, a shortcut), AltGr (Ctrl+Alt), or Alt pressed with Shift (the input-language switch) or Windows held
    // does not.

    private void OnPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (!IsAlt(e.Key))
        {
            _altAlone = false;
            return;
        }

        if (!e.KeyStatus.WasKeyDown)
        {
            _altAlone = !IsDown(VirtualKey.Control) && !IsDown(VirtualKey.Shift) && !IsDown(VirtualKey.LeftWindows)
                && !IsDown(VirtualKey.RightWindows);
        }
    }

    private static bool IsDown(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);

    private void OnPreviewKeyUp(object sender, KeyRoutedEventArgs e)
    {
        if (!IsAlt(e.Key) || !_altAlone)
            return;
        _altAlone = false;
        e.Handled = true;
        OpenAppMenu();
    }

    private static bool IsAlt(VirtualKey key) => key is VirtualKey.Menu or VirtualKey.LeftMenu or VirtualKey.RightMenu;
}
