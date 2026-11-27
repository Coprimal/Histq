// The read-only parts of the repo's ref menus (ported from RepoMenus in App/Graph/GraphMenus.swift at 6fa6d40: visibility,
// the Copy submenus, branchView): a branch's or tag's Hide / Show, a branch's Solo / Unsolo and Pin to Left / Unpin,
// Copy › Branch Name or Tag Name, and the Local and Remote cards' Hide Stale Branches and Show All Branches. The
// operation items (checkout, pull, push, merge, rename, delete, pull requests) come with their milestones.
using Histq.App.Shell.Tabs;
using Histq.Core;
using Microsoft.UI.Xaml.Controls;

namespace Histq.App.Sidebar;

/// <summary>What the ref and commit menus read and do: the repo layout of their tab. UI thread.</summary>
internal interface IRepoMenuHost
{
    /// <summary>The refs last read; null before.</summary>
    Refs? Refs { get; }

    /// <summary>The graph's saved view (hidden, soloed, pinned, hide stale).</summary>
    RepoViewState View { get; }

    /// <summary>The saved view is known (given by the workspace or read from the folder's file): until then the view
    /// items are disabled, so a change never starts from an empty view and overwrites the saved one.</summary>
    bool ViewKnown { get; }

    /// <summary>What the graph leaves out now (<see cref="LogFilter.For"/> of <see cref="View"/>).</summary>
    LogFilter Visibility { get; }

    /// <summary><paramref name="refName"/>'s tip is older than <see cref="LogFilter.StaleAge"/>.</summary>
    bool IsStale(string refName);

    void Hide(string refName);

    void Show(string refName);

    void Solo(string refName);

    void Unsolo(string refName);

    void Pin(string refName);

    void Unpin(string refName);

    void SetHideStale(bool on);

    void ShowAll();

    /// <summary>Puts <paramref name="text"/> on the clipboard (<paramref name="what"/> names it in a failure's toast).</summary>
    void Copy(string text, string what);

    /// <summary>The author's emoji; null when none is set or the author cannot have one.</summary>
    string? AuthorEmoji(string email, string name);

    /// <summary>Opens Set Author Emoji… for the author.</summary>
    void AskAuthorEmoji(string email, string name);

    void RemoveAuthorEmoji(string email, string name);
}

internal static class RefMenus
{
    /// <summary>
    /// A branch's or tag's menu items (<paramref name="kind"/> Local, Remote or Tag; <paramref name="name"/> its short
    /// name, raw): its visibility, then Copy › Branch Name or Tag Name.
    /// </summary>
    public static List<MenuFlyoutItemBase> Ref(
        SidebarRowKind kind, string name, IRepoMenuHost host, TabContextMenu.MenuActions actions)
    {
        var items = new List<MenuFlyoutItemBase>();
        switch (kind)
        {
            case SidebarRowKind.Local:
                bool isCurrent = host.Refs?.Head is Head.Branch head && string.Equals(head.Name, name, StringComparison.Ordinal);
                items.AddRange(Visibility("refs/heads/" + name, !isCurrent, true, host, actions));
                items.Add(Copy(host, actions, ("Branch Name", name)));
                break;
            case SidebarRowKind.Remote:
                items.AddRange(Visibility("refs/remotes/" + name, true, true, host, actions));
                items.Add(Copy(host, actions, ("Branch Name", name)));
                break;
            case SidebarRowKind.Tag:
                items.AddRange(Visibility("refs/tags/" + name, true, false, host, actions));
                items.Add(Copy(host, actions, ("Tag Name", name)));
                break;
        }

        return items;
    }

    /// <summary>The Local and Remote cards' menu: Hide Stale Branches (checked while on), then Show All Branches.</summary>
    public static List<MenuFlyoutItemBase> BranchView(IRepoMenuHost host, TabContextMenu.MenuActions actions)
    {
        bool hideStale = host.View.HideStale;
        LogFilter visibility = host.Visibility;
        ToggleMenuFlyoutItem stale = actions.Toggle("Hide Stale Branches", hideStale, () => host.SetHideStale(!hideStale));
        stale.IsEnabled = host.ViewKnown;
        return
        [
            stale,
            actions.Item("Show All Branches", host.ShowAll,
                enabled: host.ViewKnown && (visibility.Hidden.Count > 0 || visibility.Solo.Count > 0)),
        ];
    }

    /// <summary>A Copy submenu of <paramref name="copies"/> (title, raw text).</summary>
    public static MenuFlyoutSubItem Copy(
        IRepoMenuHost host, TabContextMenu.MenuActions actions, params (string Title, string Text)[] copies)
    {
        var copy = new MenuFlyoutSubItem { Text = "Copy" };
        foreach ((string title, string text) in copies)
            copy.Items.Add(actions.Item(title, () => host.Copy(text, title)));
        return copy;
    }

    /// <summary>
    /// A menu of the items <paramref name="fill"/> makes (separators tidied: none leading, trailing or doubled); null
    /// when it makes none. Its actions run once it has closed.
    /// </summary>
    public static MenuFlyout? Build(Func<TabContextMenu.MenuActions, IEnumerable<MenuFlyoutItemBase>> fill)
    {
        var menu = new MenuFlyout();
        var actions = new TabContextMenu.MenuActions(menu);
        foreach (MenuFlyoutItemBase item in fill(actions))
        {
            if (item is MenuFlyoutSeparator && (menu.Items.Count == 0 || menu.Items[^1] is MenuFlyoutSeparator))
                continue;
            menu.Items.Add(item);
        }

        while (menu.Items.Count > 0 && menu.Items[^1] is MenuFlyoutSeparator)
            menu.Items.RemoveAt(menu.Items.Count - 1);
        return menu.Items.Count == 0 ? null : menu;
    }

    /// <summary>
    /// The graph's view of a branch or tag (<paramref name="refName"/>, full): a separator, Hide or Show, then for a
    /// branch Solo / Unsolo and Pin to Left / Unpin. A branch hidden as stale can be shown only once Hide Stale Branches
    /// is off.
    /// </summary>
    private static List<MenuFlyoutItemBase> Visibility(
        string refName, bool canHide, bool soloAndPin, IRepoMenuHost host, TabContextMenu.MenuActions actions)
    {
        var items = new List<MenuFlyoutItemBase> { new MenuFlyoutSeparator() };
        // Until the saved view is read, nothing here can change it.
        bool known = host.ViewKnown;
        string? waiting = known ? null : "The graph's saved view is still loading.";
        if (host.Visibility.Hidden.Contains(refName))
        {
            bool stale = IsHiddenAsStale(refName, host);
            items.Add(actions.Item("Show", () => host.Show(refName), enabled: known && !stale,
                toolTip: stale ? StaleReason : waiting));
        }
        else if (canHide)
        {
            items.Add(actions.Item("Hide", () => host.Hide(refName), enabled: known, toolTip: waiting));
        }

        if (!soloAndPin)
            return items;
        items.Add(host.View.Solo.Contains(refName)
            ? actions.Item("Unsolo", () => host.Unsolo(refName), enabled: known, toolTip: waiting)
            : actions.Item("Solo", () => host.Solo(refName), enabled: known, toolTip: waiting));
        items.Add(host.View.Pinned.Contains(refName)
            ? actions.Item("Unpin", () => host.Unpin(refName), enabled: known, toolTip: waiting)
            : actions.Item("Pin to Left", () => host.Pin(refName), enabled: known, toolTip: waiting));
        items.Add(new MenuFlyoutSeparator());
        return items;
    }

    /// <summary>Why a stale branch's Show is disabled.</summary>
    public const string StaleReason = "Hidden as a stale branch: turn off Hide Stale Branches";

    /// <summary><paramref name="refName"/> is hidden because Hide Stale Branches is on (it shows only once that is off).</summary>
    public static bool IsHiddenAsStale(string refName, IRepoMenuHost host) =>
        host.View.HideStale && host.IsStale(refName) && !host.View.Pinned.Contains(refName);
}
