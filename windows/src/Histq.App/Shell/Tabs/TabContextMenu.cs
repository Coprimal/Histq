using System.Diagnostics;
using System.Globalization;
using Histq.App.Shell.Dialogs;
using Histq.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using Windows.UI;
using IOPath = System.IO.Path;

namespace Histq.App.Shell.Tabs;

/// <summary>
/// The right-click menus of a tab and of a worktree head (design header-and-tab-row.md §3.11, ported from TabMenu,
/// App/Window/TabStrip.swift:820-1000). A tab's: Close Tab, Close Tabs (a multi-selection), Close Other Tabs, Close Tabs
/// to the Right, each off when it has no tab to close (they never close the popped-out archived tab); the group items,
/// plural on a multi-selection, which they act on whole when the tab is in it; Copy Path, Show in Explorer, Set Alias…,
/// Set Icon…, Icon Color ›, Pin Tab / Unpin Tab (Pin / Unpin Worktree Tabs on a boxed tab) and Archive This Tab
/// (Unarchive Tab on the popped-out archived tab), off for a Welcome tab, then Move Tab to Window › (each other
/// window, off with its refusal as tooltip). Every item but Close Tabs and the group items acts on the right-clicked tab
/// alone. Profile › arrives with M5. A
/// worktree head's (a Windows addition, §3.5): Pin / Unpin Worktree Tabs, Move Worktree Tabs to New Group, Close
/// Worktree Tabs. Menus are built when they open; an item's action runs once the menu has closed, so the focus is back
/// on the row before the action syncs it.
/// </summary>
internal static class TabContextMenu
{
    /// <summary>The menu shown now, so a second request (Shift+F10 then its ContextRequested) opens no second one.</summary>
    private static MenuFlyout? _open;

    /// <summary>A tab's or worktree head's ContextRequested (right click, Shift+F10, the Menu key, touch hold): its menu
    /// at the pointer, or under the item from the keyboard.</summary>
    public static void OnContextRequested(FrameworkElement item, ContextRequestedEventArgs e)
    {
        e.Handled = true;
        Open(item, e.TryGetPosition(item, out Point at) ? at : null);
    }

    /// <summary>Opens <paramref name="item"/>'s menu at <paramref name="at"/> (in its coordinates), or under it when
    /// null (the keyboard). Nothing opens for an item that is not shown or while another of these menus is open.</summary>
    public static void Open(FrameworkElement item, Point? at)
    {
        if (_open is { IsOpen: true } || item.XamlRoot is null || item.Visibility != Visibility.Visible)
            return;
        MenuFlyout? menu = item switch
        {
            TabItemView tab when tab.Strip.IsPlaced(tab) => ForTab(tab.Strip, tab.Id),
            WorktreeHeadView head when head.Strip.IsPlaced(head) => ForHead(head.Strip, head.BoxKey),
            _ => null,
        };
        if (menu is null)
            return;

        _open = menu;
        menu.Closed += (_, _) =>
        {
            if (ReferenceEquals(_open, menu))
                _open = null;
        };
        menu.ShowAt(item, at is { } point
            ? new FlyoutShowOptions { Position = point }
            : new FlyoutShowOptions { Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft });
    }

    // The tab menu.

    private static MenuFlyout? ForTab(TabStrip strip, Guid id)
    {
        if (strip.Window is not { } window || strip.Model is not { } model)
            return null;
        IReadOnlyList<WindowTabs.Tab> tabs = model.Tabs;
        int index = -1;
        for (int at = 0; at < tabs.Count; at++)
        {
            if (tabs[at].Id == id)
            {
                index = at;
                break;
            }
        }

        if (index < 0)
            return null;

        WindowTabs.Tab tab = tabs[index];
        bool isRepo = tab.Path is not null;
        bool revealable = isRepo && !tab.IsMissing;
        bool boxed = model.WorktreeBoxes.Any(box => box.Contains(index));
        string pinTitle = (tab.Pinned ? "Unpin " : "Pin ") + (boxed ? "Worktree Tabs" : "Tab");
        // The normal tabs: the popped-out archived tab, last, is never closed with others.
        int normalCount = tabs.Count - (model.ArchivedOut is null ? 0 : 1);
        // A right click in a multi-selection acts on all of it; outside it, on this tab alone (the selection stays).
        // A copy: closing and grouping end the live multi-selection.
        IReadOnlySet<Guid> targets = model.MultiSelection.Contains(id)
            ? new HashSet<Guid>(model.MultiSelection)
            : new HashSet<Guid> { id };

        var menu = new MenuFlyout();
        var actions = new MenuActions(menu);
        menu.Items.Add(actions.Item("Close Tab", () => strip.CloseTab(id)));
        if (targets.Count > 1)
            menu.Items.Add(actions.Item("Close Tabs", () => CloseAll(window, targets)));
        menu.Items.Add(actions.Item("Close Other Tabs", () => window.Apply(m => m.CloseOtherTabs(id)),
            enabled: normalCount - (tab.Archived ? 0 : 1) > 0));
        menu.Items.Add(actions.Item("Close Tabs to the Right", () => window.Apply(m => m.CloseTabsAfter(id)),
            enabled: !tab.Archived && index < normalCount - 1));
        menu.Items.Add(new MenuFlyoutSeparator());
        foreach (MenuFlyoutItemBase entry in GroupEntries(actions, strip, window, model, targets))
            menu.Items.Add(entry);
        menu.Items.Add(new MenuFlyoutSeparator());

        const string NoRepo = "A new tab has no repository.";
        menu.Items.Add(actions.Item("Copy Path", () => CopyPath(window, tab.Path!), enabled: isRepo,
            toolTip: isRepo ? null : NoRepo));
        menu.Items.Add(actions.Item("Show in Explorer", () => ShowInExplorer(window, tab.Path!), enabled: revealable,
            toolTip: revealable ? null : isRepo ? "The repository's folder is gone." : NoRepo));
        menu.Items.Add(actions.Item("Set Alias…", () => SetAlias(window, id), enabled: isRepo,
            toolTip: isRepo ? null : "A new tab has no repository to name."));
        menu.Items.Add(actions.Item("Set Icon…", () => SetIcon(window, id), enabled: isRepo,
            toolTip: isRepo ? null : "A new tab has no repository to mark."));
        menu.Items.Add(isRepo
            ? IconColors(actions, window, id, tab.IconColor)
            : actions.Item("Icon Color", () => { }, enabled: false, toolTip: "A new tab has no repository to mark."));
        menu.Items.Add(actions.Item(pinTitle, () => window.Apply(m => m.SetPinned(!tab.Pinned, id)),
            enabled: isRepo && !tab.Archived,
            toolTip: tab.Archived ? "Unarchive the tab to pin it." : isRepo ? null : "A new tab has no repository to pin."));
        menu.Items.Add(tab.Archived
            ? actions.Item("Unarchive Tab", () => window.Apply(m => m.UnarchiveTab(id)))
            : actions.Item("Archive This Tab", () => window.Apply(m => m.ArchiveTab(id)), enabled: isRepo,
                toolTip: isRepo ? null : "A new tab has no repository to archive."));
        menu.Items.Add(MoveToWindow(actions, window, tab));
        return menu;
    }

    /// <summary>
    /// Move Tab to Window › (TabMenu.moveToWindow): each other window (<see cref="MainWindow.MoveTitle"/>), off with the
    /// reason as its tooltip when the move would be refused (<see cref="WindowManager.MoveRefusal"/>, no I/O); the
    /// whole entry is off for an archived or missing tab. The right-clicked tab moves alone, even in a
    /// multi-selection; a late refusal shows as a toast in this window.
    /// </summary>
    private static MenuFlyoutItemBase MoveToWindow(MenuActions actions, MainWindow window, WindowTabs.Tab tab)
    {
        const string Title = "Move Tab to Window";
        string? blocked = tab.Archived ? "Unarchive the tab to move it." : tab.IsMissing ? "Locate the repo first" : null;
        if (blocked is not null)
            return actions.Item(Title, () => { }, enabled: false, toolTip: blocked);

        var submenu = new MenuFlyoutSubItem { Text = Title };
        IReadOnlyList<MainWindow> destinations = window.Manager.MoveDestinations(window);
        if (destinations.Count == 0)
            submenu.Items.Add(actions.Item("No other window is open.", () => { }, enabled: false));
        Guid id = tab.Id;
        foreach (MainWindow destination in destinations)
        {
            string? refusal = window.Manager.MoveRefusal(id, window, destination);
            submenu.Items.Add(actions.Item(destination.MoveTitle, () => window.Manager.MoveTab(id, window, destination),
                enabled: refusal is null, toolTip: refusal is null ? null : DisplayText.Sanitize(refusal)));
        }

        return submenu;
    }

    /// <summary>
    /// Add Tab(s) to New Group, Add Tab(s) to Group › (each other group: its color dot and its name, else its first two
    /// tabs' titles and "+N" for more) and Remove from Group (when one of the tabs is grouped), for the tabs
    /// <paramref name="ids"/>; the model brings each worktree tab's whole box. All off when a tab is pinned or is the
    /// popped-out archived tab, which are never grouped. A new group's flyout opens (<see cref="GroupFlyout"/>).
    /// </summary>
    private static List<MenuFlyoutItemBase> GroupEntries(MenuActions actions, TabStrip strip, MainWindow window,
        WindowTabs model, IReadOnlySet<Guid> ids)
    {
        List<WindowTabs.Tab> tabs = model.Tabs.Where(tab => ids.Contains(tab.Id)).ToList();
        string noun = ids.Count > 1 ? "Tabs" : "Tab";
        string? blocked = tabs.Exists(tab => tab.Pinned) ? "Unpin the tab to group it."
            : tabs.Exists(tab => tab.Archived) ? "Unarchive the tab to group it." : null;
        bool grouped = tabs.Exists(tab => tab.GroupId is not null);
        // A group every tab is already in is left out: adding to it would do nothing.
        List<TabGroup> others = model.ManualGroups.Where(group => !tabs.TrueForAll(tab => tab.GroupId == group.Id)).ToList();

        var entries = new List<MenuFlyoutItemBase>
        {
            actions.Item($"Add {noun} to New Group", () => NewGroup(strip, window, ids),
                enabled: blocked is null, toolTip: blocked),
        };
        if (others.Count > 0)
        {
            string title = $"Add {noun} to Group";
            if (blocked is not null)
            {
                entries.Add(actions.Item(title, () => { }, enabled: false, toolTip: blocked));
            }
            else
            {
                var submenu = new MenuFlyoutSubItem { Text = title };
                foreach (TabGroup group in others)
                {
                    Guid groupId = group.Id;
                    MenuFlyoutItem item = actions.Item(GroupTitle(group, model),
                        () => window.Apply(m => m.AddToGroup(groupId, ids)));
                    item.Icon = Dot(TabColors.Group(group.Group.ColorIndex));
                    submenu.Items.Add(item);
                }

                entries.Add(submenu);
            }
        }

        if (grouped)
        {
            entries.Add(actions.Item("Remove from Group", () => window.Apply(m => m.RemoveFromGroup(ids)),
                enabled: blocked is null, toolTip: blocked));
        }

        return entries;
    }

    /// <summary>A group's entry in Add Tab to Group ›: its name, else its first two tabs' titles, with "+N" for the rest;
    /// sanitized.</summary>
    private static string GroupTitle(TabGroup group, WindowTabs model)
    {
        string name = DisplayText.Sanitize(group.Group.Name);
        if (name.Length > 0)
            return name;
        List<string> titles = model.Tabs.Skip(group.First).Take(group.Count)
            .Select(tab => DisplayText.Sanitize(tab.Title)).ToList();
        string more = titles.Count > 2
            ? " +" + (titles.Count - 2).ToString(CultureInfo.InvariantCulture)
            : string.Empty;
        return string.Join(", ", titles.Take(2)) + more;
    }

    /// <summary>The Icon Color submenu: Default (Settings › Appearance's default tab icon), then each lane color with its
    /// dot; the tab's own is checked.</summary>
    private static MenuFlyoutSubItem IconColors(MenuActions actions, MainWindow window, Guid id, int? current)
    {
        var submenu = new MenuFlyoutSubItem { Text = "Icon Color" };
        submenu.Items.Add(actions.Toggle("Default", current is null, () => window.Apply(m => m.SetIconColor(null, id))));
        submenu.Items.Add(new MenuFlyoutSeparator());
        for (int index = 0; index < TabColors.LaneCount; index++)
        {
            int color = index;
            ToggleMenuFlyoutItem item = actions.Toggle(TabColors.LaneName(color), current == color,
                () => window.Apply(m => m.SetIconColor(color, id)));
            item.Icon = Dot(TabColors.Lane(color));
            submenu.Items.Add(item);
        }

        return submenu;
    }

    // The worktree head menu.

    /// <summary>A worktree head's menu (design §3.11): the box's tabs pin or unpin together, move into a new group, or
    /// close together. Heads show only for unpinned boxes.</summary>
    private static MenuFlyout? ForHead(TabStrip strip, string boxKey)
    {
        if (strip.Window is not { } window || strip.Model is not { } model
            || model.WorktreeBoxes.FirstOrDefault(box => string.Equals(box.Key, boxKey, StringComparison.Ordinal))
                is not { } box)
            return null;
        IReadOnlyList<WindowTabs.Tab> tabs = model.Tabs;
        Guid first = tabs[box.First].Id;
        bool pinned = tabs[box.First].Pinned;
        var ids = new HashSet<Guid>();
        for (int index = box.First; index <= box.Last; index++)
            ids.Add(tabs[index].Id);

        var menu = new MenuFlyout();
        var actions = new MenuActions(menu);
        menu.Items.Add(actions.Item(pinned ? "Unpin Worktree Tabs" : "Pin Worktree Tabs",
            () => window.Apply(m => m.SetPinned(!pinned, first))));
        menu.Items.Add(actions.Item("Move Worktree Tabs to New Group", () => NewGroup(strip, window, ids),
            enabled: !pinned, toolTip: pinned ? "Unpin the tabs to group them." : null));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(actions.Item("Close Worktree Tabs", () => CloseAll(window, ids)));
        return menu;
    }

    // Actions.

    /// <summary>A new group of <paramref name="ids"/>; its flyout opens once its chip is laid out, so it can be named
    /// and colored at once (the Mac's popover after Add Tab to New Group).</summary>
    private static void NewGroup(TabStrip strip, MainWindow window, IReadOnlySet<Guid> ids)
    {
        Guid? group = null;
        window.Apply(m => group = m.CreateGroup(ids));
        if (group is { } id)
            strip.ShowGroupFlyoutWhenPlaced(id);
    }

    /// <summary>Closes <paramref name="ids"/>; the window closes when no tab is left.</summary>
    private static void CloseAll(MainWindow window, IReadOnlySet<Guid> ids)
    {
        bool keep = true;
        window.Apply(model => keep = model.CloseTabs(ids));
        if (!keep)
            window.Close();
    }

    /// <summary>Copy Path: the tab's folder as stored (as the footer shows it); a busy clipboard shows a toast.</summary>
    private static void CopyPath(MainWindow window, string path)
    {
        try
        {
            var data = new DataPackage();
            data.SetText(path);
            Clipboard.SetContent(data);
            Clipboard.Flush();
        }
        catch (Exception)
        {
            // Expected (another app holds the clipboard): a toast, not a crash.log entry.
            window.ShowToast("Copy Path", "The clipboard is in use by another app. Try again.");
        }
    }

    /// <summary>Show in Explorer (the Mac's Reveal in Finder): Explorer opens the folder's parent with the folder
    /// selected (a drive root opens itself). The folder check and the launch run off the UI thread; the path is passed
    /// as an argument, never through a shell. A folder that is gone, or an Explorer that does not start, shows a
    /// toast.</summary>
    private static async void ShowInExplorer(MainWindow window, string path)
    {
        string? problem;
        try
        {
            problem = await Task.Run(() => Reveal(path));
        }
        catch (Exception)
        {
            // Expected (a path Windows refuses, Explorer not starting): a toast, not a crash.log entry.
            problem = "Explorer could not be opened.";
        }

        if (problem is not null)
            window.ShowToast("Show in Explorer", problem);
    }

    /// <summary>Starts Explorer on <paramref name="path"/>; the reason it did not, or null.</summary>
    private static string? Reveal(string path)
    {
        // Explorer does not take the forward slashes git-style paths use: the full path has the host's separators.
        string full = IOPath.TrimEndingDirectorySeparator(IOPath.GetFullPath(path));
        if (!Directory.Exists(full))
            return "The repository's folder is gone.";

        string explorer = IOPath.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe");
        var start = new ProcessStartInfo(explorer) { UseShellExecute = false };
        if (IOPath.GetDirectoryName(full) is null)
        {
            start.ArgumentList.Add(full);
        }
        else
        {
            start.ArgumentList.Add("/select,");
            start.ArgumentList.Add(full);
        }

        // Explorer hands the window to its running instance and exits with 1: its exit code means nothing.
        using Process? process = Process.Start(start);
        return process is null ? "Explorer could not be opened." : null;
    }

    /// <summary>Set Alias…: <see cref="TabAliasDialog"/>; Save names the tab (an empty field gives back the folder's
    /// name).</summary>
    private static async void SetAlias(MainWindow window, Guid id)
    {
        try
        {
            if (window.Tabs.Tabs.FirstOrDefault(tab => tab.Id == id) is not { Path: { } path } tab
                || window.Content?.XamlRoot is not { } root)
                return;
            string? alias = await TabAliasDialog.AskAsync(root, PathFlavor.Host.LastComponent(path), tab.Alias);
            if (alias is not null)
                window.Apply(model => model.SetAlias(alias, id));
        }
        catch (Exception error)
        {
            CrashLog.Recovered("Set Alias (dialog not shown)", error);
        }
    }

    /// <summary>Set Icon…: <see cref="TabEmojiDialog"/>; Save sets the chosen emoji or image (none removes the icon),
    /// Remove removes it.</summary>
    private static async void SetIcon(MainWindow window, Guid id)
    {
        try
        {
            if (window.Tabs.Tabs.FirstOrDefault(tab => tab.Id == id) is not { Path: { } path } tab
                || window.Content?.XamlRoot is not { } root)
                return;
            TabIconChoice? choice =
                await TabEmojiDialog.AskAsync(root, window, PathFlavor.Host.LastComponent(path), tab.Emoji);
            // The tab may have closed while the dialog was up; SetEmoji then changes nothing.
            if (choice is not null)
                window.Apply(model => model.SetEmoji(choice.Mark, id));
        }
        catch (Exception error)
        {
            CrashLog.Recovered("Set Icon (dialog not shown)", error);
        }
    }

    /// <summary>A 16 epx menu icon: a filled dot in <paramref name="color"/>.</summary>
    private static PathIcon Dot(Color color) =>
        new()
        {
            Data = new EllipseGeometry { Center = new Point(8, 8), RadiusX = 5, RadiusY = 5 },
            Foreground = TabColors.Brush(color),
        };

    /// <summary>One menu's items: a clicked item's action is kept and runs once the menu has closed (an action that
    /// closes or moves the right-clicked tab then finds the focus back on the row, and no menu anchored to a view the
    /// sync takes out). A Click after the menu closed runs at once.</summary>
    private sealed class MenuActions
    {
        private Action? _pending;
        private bool _closed;

        public MenuActions(MenuFlyout menu) =>
            menu.Closed += (_, _) =>
            {
                _closed = true;
                Run();
            };

        public MenuFlyoutItem Item(string text, Action action, bool enabled = true, string? toolTip = null)
        {
            var item = new MenuFlyoutItem { Text = text, IsEnabled = enabled };
            if (toolTip is not null)
                ToolTipService.SetToolTip(item, toolTip);
            item.Click += (_, _) => Pick(action);
            return item;
        }

        public ToggleMenuFlyoutItem Toggle(string text, bool isChecked, Action action)
        {
            var item = new ToggleMenuFlyoutItem { Text = text, IsChecked = isChecked };
            item.Click += (_, _) => Pick(action);
            return item;
        }

        private void Pick(Action action)
        {
            _pending = action;
            if (_closed)
                Run();
        }

        private void Run()
        {
            if (_pending is not { } action)
                return;
            _pending = null;
            try
            {
                action();
            }
            catch (Exception error)
            {
                CrashLog.Recovered("Tab menu action (not done)", error);
            }
        }
    }
}
