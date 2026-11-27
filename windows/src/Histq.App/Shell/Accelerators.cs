using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using Windows.System;
using Windows.UI.Core;

namespace Histq.App.Shell;

/// <summary>A command of the app menu's File menu (HistqApp.swift makeMainMenu), with its shortcut.</summary>
internal enum AppCommand
{
    NewWindow,
    NewTab,
    Open,
    CloseTab,
    ReopenClosedTab,
    CloseWindow,
    Exit,
}

/// <summary>
/// The window's keyboard shortcuts, all in one place (the File menu of App/HistqApp.swift at 6fa6d40, Ctrl for Cmd, and
/// design header-and-tab-row.md §3.12): New Window Ctrl+Shift+N (in the window's workspace), New Tab Ctrl+T (Ctrl+N too, unlisted, as on the Mac),
/// Open… Ctrl+O, Close Tab Ctrl+W (the window closes with its last tab), Reopen Closed Tab Ctrl+Shift+T, Close Window
/// Ctrl+Shift+W, Exit Ctrl+Q; Ctrl+Tab / Ctrl+Shift+Tab cycle the shown tabs, Ctrl+1…8 select the nth shown tab and
/// Ctrl+9 the last (Windows additions); F10 opens the app menu. Registered once on the window's root, so they work
/// wherever the focus is and each fires once; the menu items only show their text.
/// </summary>
internal static class Accelerators
{
    private const VirtualKeyModifiers Ctrl = VirtualKeyModifiers.Control;
    private const VirtualKeyModifiers CtrlShift = VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift;

    private static readonly (AppCommand Command, VirtualKey Key, VirtualKeyModifiers Modifiers)[] Shortcuts =
    [
        (AppCommand.NewWindow, VirtualKey.N, CtrlShift),
        (AppCommand.NewTab, VirtualKey.T, Ctrl),
        (AppCommand.NewTab, VirtualKey.N, Ctrl),
        (AppCommand.Open, VirtualKey.O, Ctrl),
        (AppCommand.CloseTab, VirtualKey.W, Ctrl),
        (AppCommand.ReopenClosedTab, VirtualKey.T, CtrlShift),
        (AppCommand.CloseWindow, VirtualKey.W, CtrlShift),
        (AppCommand.Exit, VirtualKey.Q, Ctrl),
    ];

    /// <summary>The shortcut a menu item shows: the command's first one ("Ctrl+Shift+T").</summary>
    public static string ShortcutText(AppCommand command)
    {
        var (_, key, modifiers) = Array.Find(Shortcuts, shortcut => shortcut.Command == command);
        return (modifiers.HasFlag(VirtualKeyModifiers.Control) ? "Ctrl+" : string.Empty)
            + (modifiers.HasFlag(VirtualKeyModifiers.Shift) ? "Shift+" : string.Empty)
            + key;
    }

    /// <summary>Runs <paramref name="command"/> in <paramref name="window"/> (a menu click or its shortcut).</summary>
    public static void Run(AppCommand command, MainWindow window)
    {
        switch (command)
        {
            case AppCommand.NewWindow:
                window.Manager.NewWindow(window);
                break;
            case AppCommand.NewTab:
                window.Apply(model => model.OpenTab(null));
                break;
            case AppCommand.Open:
                window.Manager.ChooseFolder(window);
                break;
            case AppCommand.CloseTab:
                bool keep = true;
                window.Apply(model => keep = model.CloseSelectedTab());
                if (!keep)
                    window.Close();
                break;
            case AppCommand.ReopenClosedTab:
                // At once: the reopened tab's folder is checked off the UI thread (WindowTabs.FolderChecksNeeded).
                window.Apply(model => model.ReopenClosedTab());
                break;
            case AppCommand.CloseWindow:
                window.Close();
                break;
            case AppCommand.Exit:
                window.Manager.QuitAll();
                break;
        }
    }

    /// <summary>Registers every shortcut on <paramref name="scope"/> (the window's root) for
    /// <paramref name="window"/>; F10 runs <paramref name="openAppMenu"/>.</summary>
    public static void Register(UIElement scope, MainWindow window, Action openAppMenu)
    {
        foreach (var (command, key, modifiers) in Shortcuts)
            Add(scope, key, modifiers, () => Run(command, window));

        for (int n = 0; n < 9; n++)
        {
            int nth = n;
            Add(scope, VirtualKey.Number1 + n, Ctrl, () => SelectNth(window, nth));
        }

        Add(scope, VirtualKey.F10, VirtualKeyModifiers.None, openAppMenu);

        // Ctrl+Tab on the way down, before the focused control can take Tab for focus moves (an accelerator on Tab is
        // the fallback should this not see it in the VM).
        scope.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != VirtualKey.Tab || !IsDown(VirtualKey.Control) || IsDown(VirtualKey.Menu)
                || IsDown(VirtualKey.LeftWindows) || IsDown(VirtualKey.RightWindows))
                return;
            e.Handled = true;
            Cycle(window, IsDown(VirtualKey.Shift) ? -1 : 1);
        };
    }

    private static void Add(UIElement scope, VirtualKey key, VirtualKeyModifiers modifiers, Action action)
    {
        var accelerator = new KeyboardAccelerator { Key = key, Modifiers = modifiers };
        accelerator.Invoked += (_, args) =>
        {
            args.Handled = true;
            action();
        };
        scope.KeyboardAccelerators.Add(accelerator);
    }

    private static bool IsDown(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);

    /// <summary>Ctrl+Tab / Ctrl+Shift+Tab: the next (previous) shown tab, round the end.</summary>
    private static void Cycle(MainWindow window, int step)
    {
        IReadOnlyList<Guid> shown = window.Tabs.ShownTabs;
        if (shown.Count < 2)
            return;
        int at = window.Tabs.SelectedTabId is { } selected ? IndexOf(shown, selected) : -1;
        int next = at < 0 ? 0 : (at + step + shown.Count) % shown.Count;
        window.Apply(model => model.SelectTab(shown[next]));
    }

    /// <summary>Ctrl+1…8: the nth shown tab (0-based <paramref name="n"/>); Ctrl+9 (n 8): the last.</summary>
    private static void SelectNth(MainWindow window, int n)
    {
        IReadOnlyList<Guid> shown = window.Tabs.ShownTabs;
        if (shown.Count == 0 || (n < 8 && n >= shown.Count))
            return;
        Guid id = n < 8 ? shown[n] : shown[^1];
        window.Apply(model => model.SelectTab(id));
    }

    private static int IndexOf(IReadOnlyList<Guid> ids, Guid id)
    {
        for (int index = 0; index < ids.Count; index++)
        {
            if (ids[index] == id)
                return index;
        }

        return -1;
    }
}
