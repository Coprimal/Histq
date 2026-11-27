// The graph rows' read-only menus (ported from RepoMenus in App/Graph/GraphMenus.swift at 6fa6d40): a commit's Copy
// submenu (SHA, Short SHA, Message: the subject, a blank line and the body), its author's Set Author Emoji… and Remove
// Author Emoji, then a submenu per ref at the commit ("Branch main", "Remote Branch origin/main", "Tag v1.0") with that
// ref's menu (RefMenus: hide, solo, pin, copy its name); a stash's Copy SHA. Checkout, reset, cherry-pick, patches and
// the other operations come with their milestones; Copy › Link on <remote> with the hosting integrations (M8). A badge
// has no menu of its own yet: its ref's menu is the commit menu's submenu.
using Histq.App.Shell.Tabs;
using Histq.App.Sidebar;
using Histq.Core;
using Microsoft.UI.Xaml.Controls;

namespace Histq.App.Graph;

internal static class GraphMenus
{
    /// <summary>The menu of <paramref name="item"/>'s row in <paramref name="data"/>; null for a row without one (the
    /// WIP rows).</summary>
    public static MenuFlyout? For(GraphItem item, GraphData data, IRepoMenuHost host) => item.Kind switch
    {
        GraphItemKind.Commit => RefMenus.Build(actions => Commit(item.Id, data, host, actions)),
        GraphItemKind.Stash => RefMenus.Build(actions => [actions.Item("Copy SHA", () => host.Copy(item.Id, "SHA"))]),
        _ => null,
    };

    private static List<MenuFlyoutItemBase> Commit(
        string hash, GraphData data, IRepoMenuHost host, TabContextMenu.MenuActions actions)
    {
        RepoSnapshot snapshot = data.Snapshot;
        Commit? commit = snapshot.CommitIndex.TryGetValue(hash, out int index) && index < snapshot.Commits.Count
            ? snapshot.Commits[index]
            : null;
        string shortHash = hash[..Math.Min(7, hash.Length)];
        var copy = new MenuFlyoutSubItem { Text = "Copy" };
        copy.Items.Add(actions.Item("SHA", () => host.Copy(hash, "SHA")));
        copy.Items.Add(actions.Item("Short SHA", () => host.Copy(shortHash, "Short SHA")));
        copy.Items.Add(actions.Item("Message", () =>
        {
            if (commit is not null)
                host.Copy(commit.Body.Length == 0 ? commit.Subject : commit.Subject + "\n\n" + commit.Body, "Message");
        }, enabled: commit is not null));
        var items = new List<MenuFlyoutItemBase> { copy };

        // The author's emoji (AvatarStore.canSetEmoji: an email, not a provider's no-reply address, not a bot).
        if (commit is not null && AvatarRenderer.AllowsEmoji(AvatarRenderer.Identity(commit.AuthorEmail, commit.AuthorName)))
        {
            items.Add(actions.Item("Set Author Emoji…", () => host.AskAuthorEmoji(commit.AuthorEmail, commit.AuthorName)));
            if (host.AuthorEmoji(commit.AuthorEmail, commit.AuthorName) is not null)
                items.Add(actions.Item("Remove Author Emoji", () => host.RemoveAuthorEmoji(commit.AuthorEmail, commit.AuthorName)));
        }

        // The commit's refs (also those behind the badge column's "+N"), in the badges' order.
        if (data.Refs is { } refs)
        {
            items.Add(new MenuFlyoutSeparator());
            foreach (LocalBranch branch in refs.LocalBranches.Where(branch => branch.Commit == hash))
                items.Add(RefSubmenu("Branch ", SidebarRowKind.Local, branch.Name, host, actions));
            foreach (RemoteBranch branch in refs.RemoteBranches.Where(branch => branch.Commit == hash))
                items.Add(RefSubmenu("Remote Branch ", SidebarRowKind.Remote, branch.Name, host, actions));
            foreach (TagRef tag in refs.Tags.Where(tag => (tag.Commit ?? tag.Target) == hash))
                items.Add(RefSubmenu("Tag ", SidebarRowKind.Tag, tag.Name, host, actions));
        }

        return items;
    }

    private static MenuFlyoutSubItem RefSubmenu(
        string title, SidebarRowKind kind, string name, IRepoMenuHost host, TabContextMenu.MenuActions actions)
    {
        var submenu = new MenuFlyoutSubItem { Text = title + DisplayText.Sanitize(name) };
        foreach (MenuFlyoutItemBase item in RefMenus.Ref(kind, name, host, actions))
        {
            if (item is MenuFlyoutSeparator && (submenu.Items.Count == 0 || submenu.Items[^1] is MenuFlyoutSeparator))
                continue;
            submenu.Items.Add(item);
        }

        while (submenu.Items.Count > 0 && submenu.Items[^1] is MenuFlyoutSeparator)
            submenu.Items.RemoveAt(submenu.Items.Count - 1);
        return submenu;
    }
}
