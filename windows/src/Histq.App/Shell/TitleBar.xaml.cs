using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Windows.Foundation;
using Windows.System;
using Windows.UI.Core;

namespace Histq.App.Shell;

/// <summary>
/// The window's title bar (design header-and-tab-row.md §1, ported from the logo of App/Window/HeaderToolbar.swift and
/// the main menu of App/HistqApp.swift at 6fa6d40): the logo, which opens the app menu (File, Edit, View, Window, Help;
/// Windows has no menu bar), the tab strip (still the phase 5 spike strip until phase 9), a free drag area and the
/// caption buttons' inset. Only the logo and the shown tabs are Passthrough (<see cref="TitleBarRegions"/>); the rest
/// is caption. The menu holds only the items whose action works in this build; Mac-only items (Hide, Hide Others,
/// Minimize, Customize Toolbar, Merge All Windows) are left out. Its shortcuts (Ctrl for Cmd) work with the menu closed,
/// and a lone Alt press or F10 opens it.
/// </summary>
public sealed partial class TitleBar : UserControl
{
    private MainWindow _window = null!;
    private MenuFlyoutSubItem _windowMenu = null!;

    /// <summary>Alt went down with no other key or click since: its release opens the app menu.</summary>
    private bool _altAlone;

    public TitleBar()
    {
        InitializeComponent();
    }

    /// <summary>The title bar's Passthrough regions; call <see cref="TitleBarRegions.Refresh"/> after a tab-model change.</summary>
    internal TitleBarRegions Regions { get; private set; } = null!;

    /// <summary>The spike tab strip (phase 9 replaces it with the real row).</summary>
    internal SpikeTabStrip TabStrip => Strip;

#if HISTQ_QA
    /// <summary>Counts each TransformToVisual call this title bar makes (the window's QA counter).</summary>
    internal Action? QaTransformCounted { get; set; }
#endif

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
            () => Strip.Tabs.Where(IsTabShown).Prepend(LogoButton));
        Strip.TitleBarRegions = Regions;

        BuildAppMenu(keyScope);
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
    /// True when the tab ends before the free drag column. A tab that a narrow window clips takes no input and gets no
    /// sheet bump, so the drag column stays caption (phase 9 replaces this with the scrolling track).
    /// </summary>
    internal bool IsTabShown(FrameworkElement tab)
    {
        if (tab.XamlRoot is null || tab.ActualWidth <= 0)
            return false;
        // The inset width, not the star column's ActualWidth: Refresh sets it just before it asks for the elements.
        double limit = BarGrid.ActualWidth - RightInsetColumn.Width.Value - DragColumn.MinWidth;
#if HISTQ_QA
        QaTransformCounted?.Invoke();
#endif
        double right = tab.TransformToVisual(BarGrid).TransformPoint(new Point(tab.ActualWidth, 0)).X;
        return right <= limit + 0.5;
    }

    /// <summary>
    /// The app menu (HistqApp.swift makeMainMenu): File has New Window, Open…, Close Window and Exit (the app menu's
    /// Quit); Window has Maximize / Restore (Zoom) and the open windows. Edit, View and Help keep their place but stay
    /// disabled until the phases that bring their items (the undo journal and text fields, the terminal and layouts,
    /// the onboarding).
    /// </summary>
    private void BuildAppMenu(UIElement keyScope)
    {
        var file = new MenuFlyoutSubItem { Text = "File" };
        file.Items.Add(Item("New Window", VirtualKey.N, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, keyScope,
            () => _window.Manager.NewWindow()));
        file.Items.Add(Item("Open…", VirtualKey.O, VirtualKeyModifiers.Control, keyScope,
            () => _window.Manager.ChooseFolder(_window)));
        file.Items.Add(new MenuFlyoutSeparator());
        file.Items.Add(Item("Close Window", VirtualKey.W, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift,
            keyScope, () => _window.Close()));
        file.Items.Add(Item("Exit", VirtualKey.Q, VirtualKeyModifiers.Control, keyScope,
            () => _window.Manager.QuitAll()));

        _windowMenu = new MenuFlyoutSubItem { Text = "Window" };
        AppMenu.Items.Add(file);
        AppMenu.Items.Add(new MenuFlyoutSubItem { Text = "Edit", IsEnabled = false });
        AppMenu.Items.Add(new MenuFlyoutSubItem { Text = "View", IsEnabled = false });
        AppMenu.Items.Add(_windowMenu);
        AppMenu.Items.Add(new MenuFlyoutSubItem { Text = "Help", IsEnabled = false });
        AppMenu.Opening += (_, _) => FillWindowMenu();

        var f10 = new KeyboardAccelerator { Key = VirtualKey.F10 };
        f10.Invoked += (_, args) =>
        {
            args.Handled = true;
            OpenAppMenu();
        };
        keyScope.KeyboardAccelerators.Add(f10);
    }

    /// <summary>
    /// A menu item that runs <paramref name="action"/>, and its shortcut on <paramref name="keyScope"/>: there it works
    /// with the menu closed (the item only shows its text, so the shortcut never runs twice).
    /// </summary>
    private static MenuFlyoutItem Item(
        string text, VirtualKey key, VirtualKeyModifiers modifiers, UIElement keyScope, Action action)
    {
        var item = new MenuFlyoutItem { Text = text, KeyboardAcceleratorTextOverride = ShortcutText(key, modifiers) };
        item.Click += (_, _) => action();

        var accelerator = new KeyboardAccelerator { Key = key, Modifiers = modifiers };
        accelerator.Invoked += (_, args) =>
        {
            args.Handled = true;
            action();
        };
        keyScope.KeyboardAccelerators.Add(accelerator);
        return item;
    }

    private static string ShortcutText(VirtualKey key, VirtualKeyModifiers modifiers) =>
        (modifiers.HasFlag(VirtualKeyModifiers.Control) ? "Ctrl+" : string.Empty)
        + (modifiers.HasFlag(VirtualKeyModifiers.Shift) ? "Shift+" : string.Empty)
        + key;

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
    // Alt+F4, a shortcut) or AltGr (Ctrl+Alt) does not.

    private void OnPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (!IsAlt(e.Key))
        {
            _altAlone = false;
            return;
        }

        if (!e.KeyStatus.WasKeyDown)
            _altAlone = !InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(CoreVirtualKeyStates.Down);
    }

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
