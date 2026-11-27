// The machine-local side of workspace windows: how a window read from a workspace file comes back with its saved
// layout (selected tab, collapsed groups), and which layouts of workspaces not open now session.json keeps. String work
// only, no I/O. Ported from restoreWindows, selectedTab(of:) and currentSession in App/HistqApp.swift at 6fa6d40.
namespace Histq.Core;

public static class WorkspaceLayouts
{
    /// <summary>
    /// The tab to select in <paramref name="window"/> (its offset in <see cref="WorkspaceFile.LiveWindow.Tabs"/>,
    /// archived entries included): the tab at <paramref name="selectedPath"/>; with none, the first tab outside a
    /// collapsed manual group (a pinned one counts), so a saved collapse is not undone; else the first.
    /// </summary>
    public static int SelectedTab(WorkspaceFile.LiveWindow window, string? selectedPath, IReadOnlySet<Guid> collapsed)
    {
        var flavor = PathFlavor.Host;
        if (selectedPath is not null)
        {
            var wanted = flavor.Standardized(selectedPath);
            for (var index = 0; index < window.Tabs.Count; index++)
            {
                if (window.Tabs[index].Path is { } path && flavor.KeysEqual(flavor.Standardized(path), wanted))
                {
                    return index;
                }
            }
        }

        for (var index = 0; index < window.Tabs.Count; index++)
        {
            var tab = window.Tabs[index];
            if (tab.Archived != true && (tab.Pinned == true || tab.TabGroup is not { } group || !collapsed.Contains(group)))
            {
                return index;
            }
        }

        return 0;
    }

    /// <summary>The manual groups of <paramref name="window"/> as a window restores them, those in
    /// <paramref name="collapsed"/> collapsed; null when it has none.</summary>
    public static IReadOnlyList<SavedTabGroup>? TabGroups(WorkspaceFile.LiveWindow window, IReadOnlySet<Guid> collapsed) =>
        window.TabGroups?.Select(group =>
            new SavedTabGroup(group.Id, group.Color, group.Name, collapsed.Contains(group.Id) ? true : null)).ToList();

    /// <summary>
    /// The layouts of the workspaces not open now that <c>session.json</c> keeps: those of <paramref name="layouts"/>
    /// whose file is not in <paramref name="live"/>, each kept while it is <c>open</c> (it failed to reopen this launch,
    /// so the next one tries again) or its file is in <paramref name="recent"/> (Recent Workspaces); their groups are
    /// numbered after the <paramref name="liveGroups"/> live ones, in their own order, so a reopened workspace's
    /// windows never take an unrelated window's place. Paths compare as keys of this OS.
    /// </summary>
    public static IReadOnlyList<WorkspaceLayout> Kept(
        IReadOnlyList<WorkspaceLayout> layouts, IEnumerable<string> live, IEnumerable<string> recent, int liveGroups)
    {
        var flavor = PathFlavor.Host;
        var open = new HashSet<string>(live, flavor.KeyComparer);
        var listed = new HashSet<string>(recent.Select(path => flavor.Standardized(path)), flavor.KeyComparer);
        var kept = layouts
            .Where(layout => !open.Contains(layout.Path)
                && (layout.Open || listed.Contains(flavor.Standardized(layout.Path))))
            .ToList();
        var numbers = kept.SelectMany(layout => layout.Windows).Select(window => window.Group).Distinct().Order().ToList();
        var renumbered = numbers.Select((number, index) => (number, index)).ToDictionary(
            pair => pair.number, pair => liveGroups + pair.index);
        return kept.Select(layout => layout with
        {
            Windows = layout.Windows.Select(window => window with { Group = renumbered[window.Group] }).ToList(),
        }).ToList();
    }
}
