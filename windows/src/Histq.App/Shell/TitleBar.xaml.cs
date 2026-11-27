using Histq.App.Shell.Tabs;
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
/// the main menu of App/HistqApp.swift at 6fa6d40): the logo, which opens the app menu (File, Edit, View, Window, Help;
/// Windows has no menu bar), the tab strip (<see cref="Tabs.TabStrip"/>), a free drag area and the caption buttons'
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

    /// <summary>Alt went down with no other key or click since: its release opens the app menu.</summary>
    private bool _altAlone;

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
            () => Strip.InteractiveElements().Prepend(LogoButton),
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
    /// The app menu (HistqApp.swift makeMainMenu): File has New Window, New Tab, Open…, Close Tab, Reopen Closed Tab,
    /// Close Window and Exit (the app menu's Quit); Window has Maximize / Restore (Zoom) and the open windows. Edit, View
    /// and Help keep their place but stay disabled until the phases that bring their items (the undo journal and text
    /// fields, the terminal and layouts, the onboarding).
    /// </summary>
    private void BuildAppMenu()
    {
        var file = new MenuFlyoutSubItem { Text = "File" };
        file.Items.Add(Item("New Window", AppCommand.NewWindow));
        file.Items.Add(Item("New Tab", AppCommand.NewTab));
        file.Items.Add(Item("Open…", AppCommand.Open));
        file.Items.Add(new MenuFlyoutSeparator());
        file.Items.Add(Item("Close Tab", AppCommand.CloseTab));
        _reopenItem = Item("Reopen Closed Tab", AppCommand.ReopenClosedTab);
        file.Items.Add(_reopenItem);
        file.Items.Add(Item("Close Window", AppCommand.CloseWindow));
        file.Items.Add(new MenuFlyoutSeparator());
        file.Items.Add(Item("Exit", AppCommand.Exit));

        _windowMenu = new MenuFlyoutSubItem { Text = "Window" };
        AppMenu.Items.Add(file);
        AppMenu.Items.Add(new MenuFlyoutSubItem { Text = "Edit", IsEnabled = false });
        AppMenu.Items.Add(new MenuFlyoutSubItem { Text = "View", IsEnabled = false });
        AppMenu.Items.Add(_windowMenu);
        AppMenu.Items.Add(new MenuFlyoutSubItem { Text = "Help", IsEnabled = false });
        AppMenu.Opening += (_, _) =>
        {
            _reopenItem.IsEnabled = _window.Tabs.CanReopenClosedTab;
            FillWindowMenu();
        };
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
