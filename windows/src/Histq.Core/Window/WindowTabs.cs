// One window's tabs, UI-free: each is a repo folder or a Welcome tab (no repo), with the selection, the archive and its
// popped-out tab, pins, worktree boxes, manual groups (collapse, closed groups), the multi-selection, the stack that
// Ctrl+Shift+T reopens and the tabs whose layouts stay mounted. The app holds the repo sessions, the unsaved-edits
// prompts and the pages, and reads the tabs back after each call. Ported from WindowModel.swift at 6fa6d40 (its tab
// parts; sessions, Settings, toasts, the onboarding demo tab and moves between windows stay in the app).
using System.Globalization;

namespace Histq.Core;

public sealed class WindowTabs
{
    /// <summary>At most this many repo layouts stay mounted (<see cref="RecentlyShown"/>).</summary>
    public const int KeptLayouts = 4;

    private const int ClosedTabsLimit = 25;

    private readonly PathFlavor flavor;
    private readonly Func<string, bool> folderExists;
    private readonly List<Tab> tabs = [new Tab()];
    private readonly List<SavedTab> archivedTabs = [];
    private readonly List<SavedClosedTabGroup> closedGroups = [];
    private readonly List<ClosedTab> closedTabs = [];
    private readonly List<ManualTabGroup> groups = [];
    private readonly HashSet<Guid> multiSelection = [];
    private List<Guid> recentlyShown;
    private Guid? selectedTabId;

    /// <summary>One Welcome tab, selected; folders are checked on this OS, never under a UNC or device path.</summary>
    public WindowTabs()
        : this(PathFlavor.Host, null)
    {
    }

    /// <summary>
    /// One Welcome tab, selected, for a window whose tabs are all the user's own (their <c>session.json</c>, folders they
    /// picked): a folder is there when it still opens as a repo, a UNC or device one included
    /// (<see cref="SavedSession.IsUserRepository"/>). Never for a window holding tabs read from a received
    /// <c>.histqws</c>: those use <see cref="WindowTabs()"/>.
    /// </summary>
    public static WindowTabs ForUserTabs() => new(PathFlavor.Host, SavedSession.IsUserRepository);

    /// <param name="folderExists">Whether a repo folder is there (else its tab shows "Repo not found").</param>
    internal WindowTabs(PathFlavor flavor, Func<string, bool>? folderExists)
    {
        this.flavor = flavor;
        this.folderExists = folderExists ?? (path => !flavor.IsUncOrDevice(path) && Directory.Exists(path));
        selectedTabId = tabs[0].Id;
        recentlyShown = [tabs[0].Id];
    }

    /// <summary>An app tab.</summary>
    /// <param name="Path">The repo's folder; null for a Welcome tab.</param>
    /// <param name="IsMissing">The folder is gone or no longer a repository: the tab shows "Repo not found".</param>
    /// <param name="RepoKey">The repository's common dir (<see cref="RepoGroupKey"/>), shared by its worktrees' tabs;
    /// null until read or for a Welcome tab. Tabs with the same key sit side by side, in a worktree box.</param>
    /// <param name="Emoji">The tab's emoji, or an uploaded image's reference (<see cref="CustomIcon.Ref"/>); null for none.</param>
    /// <param name="Pinned">In the pinned area at the far left; a worktree box is pinned whole, and in no manual group.</param>
    /// <param name="IconColor">The book icon's color, an index into the graph lane palette; null for the default.</param>
    /// <param name="Archived">The archived tab popped out beside the archive button: always the last tab, at most one,
    /// never pinned, in no box and in no manual group.</param>
    /// <param name="GroupId">The manual group it is in; null for none.</param>
    /// <param name="Profile">Its profile as last known (restored, or set by the app from its session); null when not
    /// known yet.</param>
    public sealed record Tab(
        string? Path = null, bool IsMissing = false, string? RepoKey = null, string? Alias = null, string? Emoji = null,
        bool Pinned = false, int? IconColor = null, bool Archived = false, Guid? GroupId = null,
        SavedProfile? Profile = null)
    {
        public Guid Id { get; init; } = Guid.NewGuid();

        /// <summary>The alias, else the repo folder's name, or "New Tab" for a Welcome tab.</summary>
        public string Title => Alias ?? (Path is null ? "New Tab" : PathFlavor.Host.LastComponent(Path));
    }

    /// <summary>A closed group to open in a new window (<see cref="OpenClosedGroupInNewWindow"/>): its tabs in its
    /// group, the group table, and the folders that are gone. Its first tab is selected.</summary>
    public sealed record GroupWindow(IReadOnlyList<SavedTab> Tabs, SavedTabGroup Group, IReadOnlySet<string> Missing);

    /// <summary>A closed repo tab that <see cref="ReopenClosedTab"/> reopens: as saved, its box's key, its manual group as
    /// it was, the batch it closed with (Delete Group), and its index when it closed.</summary>
    private sealed record ClosedTab(SavedTab Saved, string? RepoKey, ManualTabGroup? Group, Guid? Batch, int Index);

    public IReadOnlyList<Tab> Tabs => tabs;

    /// <summary>The window's archive: the stowed archived tabs, most recently archived first, each with
    /// <c>archived</c> set. <see cref="OpenArchived"/> pops one out as the last tab.</summary>
    public IReadOnlyList<SavedTab> ArchivedTabs => archivedTabs;

    /// <summary>The window's closed groups, most recently closed first, each with its tabs (<c>tabGroup</c>,
    /// <c>pinned</c> and <c>archived</c> null).</summary>
    public IReadOnlyList<SavedClosedTabGroup> ClosedGroups => closedGroups;

    /// <summary>The manual groups, in a stable order. Each has at least one tab; a collapsed one never holds the
    /// selected tab.</summary>
    public IReadOnlyList<ManualTabGroup> Groups => groups;

    /// <summary>The tabs picked with Shift/Ctrl clicks: empty, or two or more with the selected tab among them.</summary>
    public IReadOnlySet<Guid> MultiSelection => multiSelection;

    /// <summary>The tabs shown last, most recent first, at most <see cref="KeptLayouts"/>: the app keeps their layouts
    /// mounted. An older entry stays only while its tab has a repo that is not missing.</summary>
    public IReadOnlyList<Guid> RecentlyShown => recentlyShown;

    public Guid? SelectedTabId => selectedTabId;

    /// <summary>
    /// Called with the repo tabs whose <see cref="Tab.RepoKey"/> must be read (<see cref="RepoGroupKey"/>), last in the
    /// call that needs them; the app reads them off the UI thread and hands them to <see cref="ApplyRepoKeys"/>.
    /// </summary>
    public Action<IReadOnlyList<(Guid Id, string Path)>>? RepoKeysNeeded { get; set; }

    /// <summary>
    /// When set, a tab that Ctrl+Shift+T reopens or that pops out of the archive comes back as found, and this is called
    /// with its folder (last in the call that needs it): the app checks the folders off the UI thread and hands the
    /// result to <see cref="ApplyFolderChecks"/>. Unset, the folder is checked in the call.
    /// </summary>
    public Action<IReadOnlyList<(Guid Id, string Path)>>? FolderChecksNeeded { get; set; }

    public int? SelectedIndex => IndexOf(selectedTabId);

    /// <summary>The tabs the row shows, in order: every tab but those of a collapsed group (Ctrl+Tab cycles them,
    /// Ctrl+1..9 picks one).</summary>
    public IReadOnlyList<Guid> ShownTabs =>
        tabs.Where((_, index) => !IsHidden(index)).Select(tab => tab.Id).ToList();

    /// <summary>The archived tab popped out, the last tab; null when none is out.</summary>
    public Tab? ArchivedOut => tabs.Count > 0 && tabs[^1].Archived ? tabs[^1] : null;

    /// <summary>The number of pinned tabs, which come first.</summary>
    public int PinnedCount => tabs.TakeWhile(tab => tab.Pinned).Count();

    /// <summary>A tab was closed in this window that <see cref="ReopenClosedTab"/> can reopen.</summary>
    public bool CanReopenClosedTab => closedTabs.Count > 0;

    /// <summary>Where the normal tabs end (the popped-out archived tab comes after them): new tabs go here.</summary>
    private int NormalEnd => tabs.Count - (ArchivedOut is null ? 0 : 1);

    // Open and select.

    /// <summary>
    /// Opens <paramref name="path"/> (null: a new Welcome tab) and selects it: its tab when one has it (a missing one is
    /// found again), its archive entry popped out, the selected Welcome tab filled, else a new tab at the end of the
    /// normal tabs, or right after <paramref name="opener"/>'s box in its box and group.
    /// </summary>
    public void OpenTab(string? path, Guid? opener = null)
    {
        if (path is null)
        {
            var welcome = new Tab();
            tabs.Insert(NormalEnd, welcome);
            Select(welcome.Id);
            return;
        }

        path = flavor.Standardized(path);
        var existing = tabs.FindIndex(tab => SamePath(tab.Path, path));
        if (existing >= 0)
        {
            var id = tabs[existing].Id;
            var found = tabs[existing].IsMissing;
            if (found)
            {
                tabs[existing] = tabs[existing] with { IsMissing = false };
            }

            Select(id);
            if (found)
            {
                RequestRepoKeys([id]);
            }
        }
        else if (ArchivedIndex(path) is { } archived)
        {
            OpenArchived(archived);
        }
        else if (SelectedIndex is { } index && tabs[index].Path is null)
        {
            // The shown tab stays, but it is another repo now: the multi-selection ends as on a switch.
            ClearSelection();
            tabs[index] = tabs[index] with { Path = path };
            RequestRepoKeys([tabs[index].Id]);
        }
        else if (IndexOf(opener) is { } at)
        {
            var tab = new Tab(path, RepoKey: tabs[at].RepoKey, GroupId: tabs[at].GroupId);
            tabs.Insert(Math.Min(BoxEnd(at) + 1, NormalEnd), tab);
            Normalize();
            Select(tab.Id);
            if (tab.RepoKey is null)
            {
                RequestRepoKeys([tab.Id]);
            }
        }
        else
        {
            var tab = new Tab(path);
            tabs.Insert(NormalEnd, tab);
            Select(tab.Id);
            RequestRepoKeys([tab.Id]);
        }
    }

    public void SelectTab(int index)
    {
        if (index >= 0 && index < tabs.Count)
        {
            Select(tabs[index].Id);
        }
    }

    public void SelectTab(Guid id)
    {
        if (IndexOf(id) is { } index)
        {
            SelectTab(index);
        }
    }

    /// <summary>The profile the app's session of the tab uses, kept for <see cref="SavedTabs"/>.</summary>
    public void SetProfile(Guid id, SavedProfile? profile) => Update(id, tab => tab with { Profile = profile });

    /// <summary>Sets the repo keys read for <see cref="RepoKeysNeeded"/> and puts the tabs in order. A tab closed or
    /// pointed elsewhere meanwhile keeps what it has; the popped-out archived tab never joins a box.</summary>
    public void ApplyRepoKeys(IEnumerable<(Guid Id, string Path, string? Key)> keys)
    {
        foreach (var (id, path, key) in keys)
        {
            if (IndexOf(id) is { } index && string.Equals(tabs[index].Path, path, StringComparison.Ordinal)
                && !tabs[index].Archived && !string.Equals(tabs[index].RepoKey, key, StringComparison.Ordinal))
            {
                tabs[index] = tabs[index] with { RepoKey = key };
            }
        }

        Normalize();
    }

    // Close and reopen.

    /// <summary>Closes the selected tab; false when no tab is left (the window closes).</summary>
    public bool CloseSelectedTab() => selectedTabId is { } id ? CloseTab(id) : tabs.Count > 0;

    /// <summary>
    /// Closes a tab; when it was the selected one, the next shown normal tab is selected, else the one before (a
    /// collapsed group stays collapsed unless nothing else is left), the popped-out archived tab only when no normal tab
    /// is left. False when no tab is left (the window closes). The popped-out archived tab goes back to the archive. A
    /// window whose archive or closed groups are not empty gets a Welcome tab when its last repo tab closes.
    /// </summary>
    public bool CloseTab(Guid id) => CloseTab(id, archiving: false);

    /// <summary>Close Other Tabs: every tab but <paramref name="id"/>, which is selected. The popped-out archived tab
    /// stays.</summary>
    public void CloseOtherTabs(Guid id)
    {
        var popped = ArchivedOut?.Id;
        var others = tabs.Select(tab => tab.Id).Where(other => other != id && other != popped).ToHashSet();
        CloseTabs(id, others.Contains);
    }

    /// <summary>Close Tabs to the Right: the tabs after <paramref name="id"/>, which is selected when the selected tab was
    /// one of them. The popped-out archived tab stays.</summary>
    public void CloseTabsAfter(Guid id)
    {
        if (IndexOf(id) is not { } index)
        {
            return;
        }

        var closing = tabs.Skip(index + 1).Where(tab => !tab.Archived).Select(tab => tab.Id).ToHashSet();
        CloseTabs(id, closing.Contains);
    }

    /// <summary>A multi-selection's Close Tabs: closes <paramref name="ids"/>, pinned ones too, left to right; the
    /// multi-selection ends. False when no tab is left (a Welcome tab takes their place when the archive or the closed
    /// groups are not empty).</summary>
    public bool CloseTabs(IReadOnlySet<Guid> ids)
    {
        var open = CloseTabs(ids, batch: null);
        ClearSelection();
        return open;
    }

    /// <summary>Reopens the last closed repo tab at its index, in its worktree box and its manual group (recreated with
    /// the same id, name and color when gone), and selects it. A repo open again meanwhile is selected instead, and one in
    /// the archive pops out. Tabs closed together (Delete Group) come back in one step.</summary>
    public void ReopenClosedTab()
    {
        if (closedTabs.Count == 0)
        {
            return;
        }

        if (closedTabs[^1].Batch is { } batch)
        {
            ReopenClosedBatch(batch);
            return;
        }

        var closed = closedTabs[^1];
        closedTabs.RemoveAt(closedTabs.Count - 1);
        if (closed.Saved.Path is not { } path)
        {
            return;
        }

        if (tabs.Find(tab => SamePath(tab.Path, path)) is { } existing)
        {
            SelectTab(existing.Id);
            return;
        }

        if (ArchivedIndex(path) is { } archived)
        {
            OpenArchived(archived);
            return;
        }

        var reopened = InsertClosed(closed, path);
        Normalize();
        Select(reopened.Id);
        if (!reopened.IsMissing && reopened.RepoKey is null)
        {
            RequestRepoKeys([reopened.Id]);
        }

        RequestFolderChecks([reopened.Id]);
    }

    /// <summary>The folder checks asked for by <see cref="FolderChecksNeeded"/>: a tab still there with the same folder
    /// shows "Repo not found" when its folder is not (or no longer) a repo, and its repo again when it is.</summary>
    public void ApplyFolderChecks(IEnumerable<(Guid Id, string Path, bool Exists)> checks)
    {
        foreach (var (id, path, exists) in checks)
        {
            if (IndexOf(id) is { } index && string.Equals(tabs[index].Path, path, StringComparison.Ordinal)
                && tabs[index].IsMissing == exists)
            {
                tabs[index] = tabs[index] with { IsMissing = !exists };
            }
        }
    }

    // Archive.

    /// <summary>Archive This Tab: the repo tab goes to the archive's front, and its neighbor is selected as when it
    /// closes; Ctrl+Shift+T does not reopen it. The window never closes: its last tab gives way to a Welcome tab.</summary>
    public void ArchiveTab(Guid id)
    {
        if (tabs.Find(tab => tab.Id == id) is { Path: not null })
        {
            CloseTab(id, archiving: true);
        }
    }

    /// <summary>The archive's row <paramref name="index"/> pops out, last and selected. The tab popped out before goes
    /// back to the archive's front: at most one archived tab is out.</summary>
    public void OpenArchived(int index)
    {
        if (index < 0 || index >= archivedTabs.Count || archivedTabs[index].Path is not { } path)
        {
            return;
        }

        // The entry first, then the tab popped out before: stowing it shifts the archive's indices.
        var entry = archivedTabs[index];
        archivedTabs.RemoveAt(index);
        if (ArchivedOut is not null)
        {
            Remove(tabs.Count - 1);
        }

        var tab = new Tab(path, IsMissingNow(path), Alias: entry.Alias, Emoji: entry.Mark,
            IconColor: entry.IconColor, Archived: true, Profile: entry.Profile);
        tabs.Add(tab);
        Select(tab.Id);
        RequestFolderChecks([tab.Id]);
    }

    /// <summary>Unarchive Tab: the popped-out tab becomes a normal tab at the start of the unpinned area, in no group,
    /// and rejoins its worktree box once its repo is read. The selection stays.</summary>
    public void UnarchiveTab(Guid id)
    {
        if (IndexOf(id) is not { } index || !tabs[index].Archived)
        {
            return;
        }

        var tab = tabs[index] with { Archived = false };
        tabs.RemoveAt(index);
        tabs.Insert(PinnedCount, tab);
        if (!tab.IsMissing)
        {
            RequestRepoKeys([id]);
        }
    }

    /// <summary>The archive row's remove button: the entry leaves the archive, and Ctrl+Shift+T can reopen it.</summary>
    public void RemoveArchived(int index)
    {
        if (index < 0 || index >= archivedTabs.Count)
        {
            return;
        }

        var entry = archivedTabs[index] with { Archived = null };
        archivedTabs.RemoveAt(index);
        if (entry.Path is not null)
        {
            RememberClosed(new ClosedTab(entry, null, null, null, NormalEnd));
        }
    }

    /// <summary>Whether this window has the repo folder <paramref name="path"/> as a tab or in its archive. No I/O.</summary>
    public bool HasRepo(string path) => tabs.Exists(tab => SamePath(tab.Path, path)) || ArchivedIndex(path) is not null;

    // Tab marks and pins.

    /// <summary>Set Alias: <paramref name="alias"/> names the tab; empty or only spaces gives back the folder's name. At most
    /// <see cref="DisplayText.MaxLength"/> text elements are kept.</summary>
    public void SetAlias(string alias, Guid id)
    {
        var trimmed = DisplayText.Capped(alias.Trim());
        Update(id, tab => tab with { Alias = trimmed.Length == 0 ? null : trimmed });
    }

    /// <summary>Set Icon: an uploaded image's reference as is, else its last emoji only (<see cref="TabEmoji.Normalized"/>);
    /// null, or text with no emoji, removes it.</summary>
    public void SetEmoji(string? emoji, Guid id) =>
        Update(id, tab => tab with
        {
            Emoji = CustomIcon.IsRef(emoji) ? emoji : emoji is null ? null : TabEmoji.Normalized(emoji),
        });

    /// <summary>Icon Color: an index into the graph lane palette; null for the default.</summary>
    public void SetIconColor(int? color, Guid id) => Update(id, tab => tab with { IconColor = color });

    /// <summary>Pin Tab / Unpin Tab: the tab with its whole worktree box; they leave their manual group. Pinned tabs go
    /// to the end of the pinned area, unpinned ones to the start of the others. The selection stays.</summary>
    public void SetPinned(bool pinned, Guid id)
    {
        // The popped-out archived tab is never pinned.
        if (tabs.Find(tab => tab.Id == id) is not { Archived: false } target)
        {
            return;
        }

        bool Affected(Tab other) => target.RepoKey is { } key
            ? string.Equals(other.RepoKey, key, StringComparison.Ordinal)
            : other.Id == id;

        if (!tabs.Exists(tab => Affected(tab) && tab.Pinned != pinned))
        {
            return;
        }

        var moved = tabs.Where(Affected).Select(tab => tab with { Pinned = pinned, GroupId = null }).ToList();
        var rest = tabs.Where(tab => !Affected(tab)).ToList();
        var boundary = rest.TakeWhile(tab => tab.Pinned).Count();
        rest.InsertRange(boundary, moved);
        Replace(rest);
        if (pinned)
        {
            PruneSelection(moved.Select(tab => tab.Id));
        }

        Normalize();
    }

    // Boxes and groups.

    /// <summary>The runs of two or more neighboring tabs of one repository, in tab order; the popped-out archived tab is
    /// in none.</summary>
    public IReadOnlyList<WorktreeBox> WorktreeBoxes
    {
        get
        {
            var boxes = new List<WorktreeBox>();
            var start = 0;
            while (start < tabs.Count)
            {
                var end = start;
                if (tabs[start].RepoKey is { } key && !tabs[start].Archived)
                {
                    while (end + 1 < tabs.Count && string.Equals(tabs[end + 1].RepoKey, key, StringComparison.Ordinal)
                           && !tabs[end + 1].Archived)
                    {
                        end++;
                    }

                    if (end > start)
                    {
                        boxes.Add(new WorktreeBox(key, start, end));
                    }
                }

                start = end + 1;
            }

            return boxes;
        }
    }

    /// <summary>The runs of neighboring tabs of one manual group, in tab order, each with its table entry. Pinned tabs
    /// and the popped-out archived tab are in none.</summary>
    public IReadOnlyList<TabGroup> ManualGroups
    {
        get
        {
            var runs = new List<TabGroup>();
            var start = 0;
            while (start < tabs.Count)
            {
                var end = start;
                if (tabs[start] is { GroupId: { } id, Pinned: false, Archived: false })
                {
                    while (end + 1 < tabs.Count && tabs[end + 1] is { Pinned: false, Archived: false } next
                           && next.GroupId == id)
                    {
                        end++;
                    }

                    if (groups.Find(group => group.Id == id) is { } entry)
                    {
                        runs.Add(new TabGroup(entry, start, end));
                    }
                }

                start = end + 1;
            }

            return runs;
        }
    }

    /// <summary>The row's parts in order: manual groups, worktree boxes and plain tabs.</summary>
    public IReadOnlyList<TabArrangement.Segment> Segments => TabArrangement.Segments(ArrangementEntries);

    /// <summary>The tabs as <see cref="TabArrangement"/> sees them, in order; a group not in the table counts as none.</summary>
    public IReadOnlyList<TabArrangement.Entry> ArrangementEntries
    {
        get
        {
            var ids = groups.Select(group => group.Id).ToHashSet();
            return tabs.Select(tab => new TabArrangement.Entry(
                tab.Id, tab.RepoKey, tab.GroupId is { } group && ids.Contains(group) ? group : null, tab.Pinned,
                tab.Archived)).ToList();
        }
    }

    /// <summary>Drops a dragged tab, box or group at <paramref name="index"/> in <paramref name="group"/>, as
    /// <see cref="TabGroupSpans.DragTarget"/> gives them; any other place leaves the order. The selection stays.</summary>
    public void MoveUnit(TabArrangement.Unit unit, int index, Guid? group) =>
        Apply(TabArrangement.Move(unit, index, group, ArrangementEntries));

    public bool IsCollapsed(Guid id) => groups.Exists(group => group.Id == id && group.Collapsed);

    /// <summary>A click on a group's chip: collapses it, or shows its tabs again. Collapsing the selected tab's group
    /// selects the next shown tab after it, else before it, else the popped-out archived tab, else a new Welcome tab.</summary>
    public void ToggleGroup(Guid id)
    {
        var collapsedAt = groups.FindIndex(group => group.Id == id && group.Collapsed);
        if (collapsedAt >= 0)
        {
            groups[collapsedAt] = groups[collapsedAt] with { Collapsed = false };
            return;
        }

        if (ManualGroups.FirstOrDefault(group => group.Id == id) is not { } run)
        {
            return;
        }

        var hidden = tabs.Skip(run.First).Take(run.Count).Select(tab => tab.Id).ToList();
        if (SelectedIndex is { } selected && run.Contains(selected))
        {
            var shown = Enumerable.Range(0, NormalEnd).Where(index => !run.Contains(index) && !IsHidden(index)).ToList();
            int? popped = ArchivedOut is null ? null : tabs.Count - 1;
            if ((FirstWhere(shown, index => index > run.Last) ?? LastOf(shown) ?? popped) is { } next)
            {
                SelectTab(next);
            }
            else
            {
                OpenTab(null);
            }
        }

        // Looked up again: the selection above may have changed the table.
        var at = groups.FindIndex(group => group.Id == id);
        if (at < 0)
        {
            return;
        }

        groups[at] = groups[at] with { Collapsed = true };
        PruneSelection(hidden);
    }

    /// <summary>Add Tab(s) to New Group: a new group (a random color, no name) of <paramref name="ids"/> and their boxes,
    /// gathered at the first one's place; null when no tab can be grouped.</summary>
    public Guid? CreateGroup(IEnumerable<Guid> ids)
    {
        var members = Groupable(ids);
        if (members.Count == 0)
        {
            return null;
        }

        // In the table first: normalizing drops a group it does not hold.
        var group = new ManualTabGroup(Guid.NewGuid(), null, Random.Shared.Next(0, 9), false);
        groups.Add(group);
        Replace(tabs.Select(tab => members.Contains(tab.Id) ? tab with { GroupId = group.Id } : tab).ToList());
        Normalize();
        ClearSelection();
        return group.Id;
    }

    /// <summary>Add Tab(s) to Group: <paramref name="ids"/> and their boxes join the group at its end.</summary>
    public void AddToGroup(Guid id, IEnumerable<Guid> ids)
    {
        var members = Groupable(ids);
        var moved = tabs.Where(tab => members.Contains(tab.Id) && tab.GroupId != id)
            .Select(tab => tab with { GroupId = id }).ToList();
        if (moved.Count == 0 || !groups.Exists(group => group.Id == id))
        {
            return;
        }

        var movedIds = moved.Select(tab => tab.Id).ToHashSet();
        var rest = tabs.Where(tab => !movedIds.Contains(tab.Id)).ToList();
        // Placed after the group's last tab before normalizing, which gathers a group at its first tab.
        var end = rest.FindLastIndex(tab => tab.GroupId == id);
        if (end < 0)
        {
            return;
        }

        rest.InsertRange(end + 1, moved);
        Replace(rest);
        Normalize();
        ClearSelection();
    }

    /// <summary>Remove from Group: <paramref name="ids"/> and their boxes leave their groups, each going right after
    /// what is left of its group (in place when nothing is).</summary>
    public void RemoveFromGroup(IEnumerable<Guid> ids)
    {
        var members = Groupable(ids);
        var leaving = tabs.Where(tab => members.Contains(tab.Id) && tab.GroupId is not null).ToList();
        if (leaving.Count == 0)
        {
            return;
        }

        var result = tabs.ToList();
        foreach (var group in leaving.Select(tab => tab.GroupId!.Value).Distinct())
        {
            var outIds = leaving.Where(tab => tab.GroupId == group).Select(tab => tab.Id).ToHashSet();
            var first = result.FindIndex(tab => outIds.Contains(tab.Id));
            if (first < 0)
            {
                continue;
            }

            var block = result.Where(tab => outIds.Contains(tab.Id)).Select(tab => tab with { GroupId = null }).ToList();
            result.RemoveAll(tab => outIds.Contains(tab.Id));
            var last = result.FindLastIndex(tab => tab.GroupId == group);
            result.InsertRange(last >= 0 ? last + 1 : first, block);
        }

        Replace(result);
        Normalize();
        ClearSelection();
    }

    /// <summary>Ungroup: the group's tabs stay where they are, in no group, and the group goes.</summary>
    public void Ungroup(Guid id)
    {
        if (!tabs.Exists(tab => tab.GroupId == id))
        {
            return;
        }

        Replace(tabs.Select(tab => tab.GroupId == id ? tab with { GroupId = null } : tab).ToList());
        Normalize();
        ClearSelection();
    }

    /// <summary>The group's name (live): trimmed, empty for no name, at most <see cref="DisplayText.MaxLength"/> text
    /// elements.</summary>
    public void SetGroupName(Guid id, string name)
    {
        var trimmed = DisplayText.Capped(name.Trim());
        var index = groups.FindIndex(group => group.Id == id);
        if (index >= 0)
        {
            groups[index] = groups[index] with { Name = trimmed.Length == 0 ? null : trimmed };
        }
    }

    /// <summary>The group's swatch: 0 is grey, 1-8 a lane color (clamped).</summary>
    public void SetGroupColor(Guid id, int colorIndex)
    {
        var index = groups.FindIndex(group => group.Id == id);
        if (index >= 0)
        {
            groups[index] = groups[index] with { ColorIndex = Math.Clamp(colorIndex, 0, 8) };
        }
    }

    /// <summary>New Tab in Group: a Welcome tab at the group's end, in the group, selected (a collapsed group opens).</summary>
    public void NewTabInGroup(Guid id)
    {
        var end = tabs.FindLastIndex(tab => tab.GroupId == id && !tab.Pinned && !tab.Archived);
        if (end < 0)
        {
            return;
        }

        var tab = new Tab(GroupId: id);
        tabs.Insert(end + 1, tab);
        Normalize();
        Select(tab.Id);
        ClearSelection();
    }

    /// <summary>The group holds every normal tab (pinned ones included): Delete Group and Move Group to New Window are
    /// disabled, as no tab would be left.</summary>
    public bool GroupHoldsAllNormalTabs(Guid id) =>
        NormalEnd > 0 && tabs.Take(NormalEnd).All(tab => tab.GroupId == id);

    /// <summary>Delete Group: closes the group's tabs as one batch, which one <see cref="ReopenClosedTab"/> reopens whole.</summary>
    public void DeleteGroup(Guid id)
    {
        if (GroupHoldsAllNormalTabs(id))
        {
            return;
        }

        var ids = tabs.Where(tab => tab.GroupId == id && !tab.Pinned && !tab.Archived).Select(tab => tab.Id).ToHashSet();
        if (ids.Count == 0)
        {
            return;
        }

        CloseTabs(ids, Guid.NewGuid());
        Normalize();
        ClearSelection();
    }

    // Closed groups.

    /// <summary>
    /// Close Group: the group goes to the front of the closed groups with its tabs, not onto the reopen stack. The
    /// selection moves as when the group collapses; when the group held every normal tab, a Welcome tab takes their
    /// place. A group of Welcome tabs only just closes. A group whose id is stowed already adds its tabs to that entry,
    /// which moves to the front.
    /// </summary>
    public void CloseGroup(Guid id)
    {
        if (groups.Find(group => group.Id == id) is not { } group)
        {
            return;
        }

        var members = tabs.Where(tab => tab.GroupId == id && !tab.Pinned && !tab.Archived).ToList();
        if (members.Count == 0)
        {
            return;
        }

        var entries = members.Select(tab => Saved(tab) with { TabGroup = null, Pinned = null, Archived = null }).ToList();
        var leaving = members.Select(tab => tab.Id).ToHashSet();
        if (selectedTabId is { } selected && leaving.Contains(selected))
        {
            int? popped = ArchivedOut is null ? null : tabs.Count - 1;
            if ((ShownNeighbor(leaving) ?? popped) is { } next)
            {
                SelectTab(next);
            }
            else
            {
                OpenTab(null);
            }
        }

        int index;
        while ((index = tabs.FindIndex(tab => leaving.Contains(tab.Id))) >= 0)
        {
            Remove(index, remembering: false);
        }

        if (entries.Exists(entry => entry.Path is not null))
        {
            var earlier = closedGroups.FindIndex(closed => closed.Id == id);
            IReadOnlyList<SavedTab> kept = [];
            if (earlier >= 0)
            {
                kept = closedGroups[earlier].Tabs;
                closedGroups.RemoveAt(earlier);
            }

            closedGroups.Insert(0, new SavedClosedTabGroup(id, group.ColorIndex, [.. kept, .. entries], group.Name));
        }

        Normalize();
        ClearSelection();
    }

    /// <summary>
    /// Open Group: the closed group comes back at the end of the normal tabs, expanded, with its id, name and color, and
    /// its tab <paramref name="tabIndex"/> (its first one for null) is selected. A member whose repo is open in this
    /// window or in the archive is skipped: that open tab is selected when it is the one picked, or when every member is
    /// skipped. A folder gone shows "Repo not found".
    /// </summary>
    public void OpenClosedGroup(Guid id, int? tabIndex = null)
    {
        var at = closedGroups.FindIndex(group => group.Id == id);
        if (at < 0)
        {
            return;
        }

        var entry = closedGroups[at];
        closedGroups.RemoveAt(at);
        // In the table first: normalizing drops a group it does not hold. Ctrl+Shift+T may have recreated it already.
        if (!groups.Exists(group => group.Id == id))
        {
            groups.Add(new ManualTabGroup(id, entry.Name, entry.Color, false));
        }

        Guid? OpenId(SavedTab member) =>
            member.Path is { } path ? tabs.Find(tab => SamePath(tab.Path, path))?.Id : null;

        var opened = new Dictionary<int, Guid>();
        for (var offset = 0; offset < entry.Tabs.Count; offset++)
        {
            var member = entry.Tabs[offset];
            if (member.Path is { } path && (OpenId(member) is not null || ArchivedIndex(path) is not null))
            {
                continue;
            }

            var tab = new Tab(member.Path, member.Path is { } folder && !folderExists(folder), Alias: member.Alias,
                Emoji: member.Mark, IconColor: member.IconColor, GroupId: id, Profile: member.Profile);
            tabs.Insert(NormalEnd, tab);
            opened[offset] = tab.Id;
        }

        Normalize();
        var reopened = opened.Values.ToHashSet();
        Guid? picked = tabIndex is { } wanted && wanted >= 0 && wanted < entry.Tabs.Count
            ? opened.TryGetValue(wanted, out var tabId) ? tabId : OpenId(entry.Tabs[wanted])
            : null;
        Guid? first = Enumerable.Range(0, entry.Tabs.Count).Where(opened.ContainsKey).Select(offset => opened[offset])
            .Cast<Guid?>().FirstOrDefault();
        var target = picked ?? first ?? (entry.Tabs.Count > 0 ? OpenId(entry.Tabs[0]) : null);
        if (target is { } shown)
        {
            Select(shown);
        }

        RequestRepoKeys(tabs.Where(tab => reopened.Contains(tab.Id) && !tab.IsMissing).Select(tab => tab.Id));
    }

    /// <summary>Open Group in New Window: the group leaves the closed groups; the caller opens a new window with what it
    /// returns. Null when there is no such group.</summary>
    public GroupWindow? OpenClosedGroupInNewWindow(Guid id)
    {
        var at = closedGroups.FindIndex(group => group.Id == id);
        if (at < 0)
        {
            return null;
        }

        var entry = closedGroups[at];
        closedGroups.RemoveAt(at);
        var entries = entry.Tabs.Select(member => member with { TabGroup = id }).ToList();
        var missing = entries.Select(member => member.Path).OfType<string>().Where(path => !folderExists(path))
            .ToHashSet(flavor.KeyComparer);
        return new GroupWindow(entries, new SavedTabGroup(id, entry.Color, entry.Name), missing);
    }

    /// <summary>A closed group's Delete Group: it leaves the closed groups and its repo tabs go on the reopen stack as one
    /// batch with the group, at the end of the normal tabs, so one <see cref="ReopenClosedTab"/> reopens them whole.</summary>
    public void DeleteClosedGroup(Guid id)
    {
        var at = closedGroups.FindIndex(group => group.Id == id);
        if (at < 0)
        {
            return;
        }

        var entry = closedGroups[at];
        closedGroups.RemoveAt(at);
        var group = new ManualTabGroup(id, entry.Name, entry.Color, false);
        var batch = Guid.NewGuid();
        foreach (var member in entry.Tabs.Where(member => member.Path is not null))
        {
            RememberClosed(new ClosedTab(member, null, group, batch, NormalEnd));
        }
    }

    // Multi-selection.

    /// <summary>Shift-click: the multi-selection becomes the shown tabs from the selected tab to <paramref name="id"/>.</summary>
    public void ExtendSelection(Guid id)
    {
        if (SelectedIndex is not { } selected || IndexOf(id) is not { } target)
        {
            return;
        }

        var picked = Enumerable.Range(Math.Min(selected, target), Math.Abs(selected - target) + 1)
            .Where(index => !IsHidden(index)).Select(index => tabs[index].Id).ToHashSet();
        picked.Add(tabs[selected].Id);
        SetMultiSelection(picked);
    }

    /// <summary>Ctrl-click: adds the tab to the multi-selection, or takes it out. The selected tab always stays in it.</summary>
    public void ToggleSelection(Guid id)
    {
        if (selectedTabId is not { } selected || id == selected || IndexOf(id) is null)
        {
            return;
        }

        HashSet<Guid> picked = multiSelection.Count == 0 ? [selected] : multiSelection.ToHashSet();
        if (!picked.Remove(id))
        {
            picked.Add(id);
        }

        SetMultiSelection(picked);
    }

    /// <summary>A plain click: the multi-selection ends.</summary>
    public void ClearSelection() => multiSelection.Clear();

    // Session state.

    /// <summary>
    /// Restores the tabs saved by the session. The archived entries go back to the archive, but the selected one: it is
    /// popped out again, last and selected. A tab's group not in <paramref name="groups"/> is dropped, as is a table entry
    /// no tab is in; a closed group with no repo tab is dropped. <paramref name="repoKeys"/> (by repo path) are set
    /// before the tabs are put in order.
    /// </summary>
    public void Restore(
        IReadOnlyList<SavedTab> saved, int? selected, IReadOnlySet<string> missing,
        IReadOnlyList<SavedTabGroup>? groups = null, IReadOnlyList<SavedClosedTabGroup>? closedGroups = null,
        IReadOnlyDictionary<string, string>? repoKeys = null)
    {
        if (saved.Count == 0)
        {
            return;
        }

        this.closedGroups.Clear();
        this.closedGroups.AddRange((closedGroups ?? []).Where(group => group.Tabs.Any(tab => tab.Path is not null))
            .Select(group => group with { Color = Math.Clamp(group.Color, 0, 8) }));
        var entries = new List<SavedTab>();
        SavedTab? popped = null;
        int? selectedEntry = null;
        archivedTabs.Clear();
        for (var offset = 0; offset < saved.Count; offset++)
        {
            var entry = saved[offset];
            if (entry.Archived != true)
            {
                selectedEntry = offset == selected ? entries.Count : selectedEntry;
                entries.Add(entry);
            }
            else if (entry.Path is not null)
            {
                // An archived tab is in no group.
                var stowed = entry with { TabGroup = null };
                if (offset == selected)
                {
                    popped = stowed;
                }
                else
                {
                    archivedTabs.Add(stowed);
                }
            }
        }

        if (popped is not null)
        {
            selectedEntry = entries.Count;
            entries.Add(popped);
        }

        Replace(entries.Select(entry =>
        {
            var archived = entry.Archived == true;
            var isMissing = entry.Path is { } path && missing.Contains(path);
            string? key = null;
            if (!archived && !isMissing && entry.Path is { } repo)
            {
                repoKeys?.TryGetValue(repo, out key);
            }

            return new Tab(entry.Path, isMissing, key, entry.Alias, entry.Mark, !archived && entry.Pinned == true,
                entry.IconColor, archived, archived ? null : entry.TabGroup, entry.Profile);
        }).ToList());
        if (tabs.Count == 0)
        {
            tabs.Add(new Tab());
        }

        // The table first (normalizing drops a group it does not hold), then the order. The selection is kept by id,
        // as normalizing may reorder the tabs, and set last: it opens the selected tab's group.
        var selectedId = tabs[selectedEntry ?? 0].Id;
        this.groups.Clear();
        this.groups.AddRange((groups ?? []).Select(group =>
            new ManualTabGroup(group.Id, group.Name, Math.Clamp(group.Color, 0, 8), group.Collapsed ?? false)));
        Normalize();
        Select(selectedId);
        RequestRepoKeys(tabs.Where(tab => !tab.IsMissing && !tab.Archived).Select(tab => tab.Id));
    }

    /// <summary>The tabs as the session saves them, in order, then the stowed archived tabs.</summary>
    public IReadOnlyList<SavedTab> SavedTabs => [.. tabs.Select(Saved), .. archivedTabs];

    /// <summary>The selected tab's index in <see cref="SavedTabs"/>.</summary>
    public int? SavedSelectedIndex => SelectedIndex;

    /// <summary>The manual groups as the session saves them, those with a tab only; null when there is none.</summary>
    public IReadOnlyList<SavedTabGroup>? SavedTabGroups
    {
        get
        {
            var used = tabs.Select(tab => tab.GroupId).OfType<Guid>().ToHashSet();
            var saved = groups.Where(group => used.Contains(group.Id))
                .Select(group => new SavedTabGroup(group.Id, group.ColorIndex, group.Name, group.Collapsed ? true : null))
                .ToList();
            return saved.Count == 0 ? null : saved;
        }
    }

    /// <summary>The closed groups as the session saves them; null when there is none.</summary>
    public IReadOnlyList<SavedClosedTabGroup>? SavedClosedGroups => closedGroups.Count == 0 ? null : closedGroups.ToList();

    // Helpers.

    /// <summary>
    /// Sets the selected tab. The selected tab's collapsed group opens. On a change the multi-selection ends and the tab
    /// goes first in <see cref="RecentlyShown"/>, which keeps the older tabs that have a layout.
    /// </summary>
    private void Select(Guid? id)
    {
        var old = selectedTabId;
        selectedTabId = id;
        ExpandSelectedGroup();
        if (old == id)
        {
            return;
        }

        ClearSelection();
        if (id is { } shown)
        {
            var older = recentlyShown.Where(other => other != shown && HasLayout(other)).Take(KeptLayouts - 1);
            recentlyShown = [shown, .. older];
        }
    }

    /// <summary>The tab has a layout to keep: it is still here with a repo that is not missing.</summary>
    private bool HasLayout(Guid id) => tabs.Exists(tab => tab.Id == id && tab.Path is not null && !tab.IsMissing);

    private bool CloseTab(Guid id, bool archiving)
    {
        if (IndexOf(id) is not { } index)
        {
            return tabs.Count > 0;
        }

        var wasWelcome = tabs[index].Path is null;
        Remove(index, archiving);
        // A lone Welcome tab still closes the window, its archive and closed groups with it.
        if (tabs.Count == 0 && (archivedTabs.Count > 0 || closedGroups.Count > 0) && !wasWelcome)
        {
            AddWelcome();
            return true;
        }

        if (selectedTabId == id)
        {
            SelectNeighbor(index);
        }

        return tabs.Count > 0;
    }

    /// <summary>After the selected tab at <paramref name="index"/> left: the next shown normal tab, else the one
    /// before, else a tab of a collapsed group; the popped-out archived tab only when no normal tab is left.</summary>
    private void SelectNeighbor(int index)
    {
        if (tabs.Count == 0)
        {
            Select(null);
            return;
        }

        var next = Math.Min(index, NormalEnd - 1);
        var shown = Enumerable.Range(0, NormalEnd).Where(at => !IsHidden(at)).ToList();
        var fallback = NormalEnd > 0 ? next : tabs.Count - 1;
        Select(tabs[FirstWhere(shown, at => at >= next) ?? LastOf(shown) ?? fallback].Id);
    }

    /// <summary>Closes the tabs <paramref name="closes"/> picks, left to right; the selection moves to
    /// <paramref name="keeping"/> first when the selected tab is closed.</summary>
    private void CloseTabs(Guid keeping, Func<Guid, bool> closes)
    {
        if (selectedTabId is { } selected && closes(selected))
        {
            SelectTab(keeping);
        }

        int index;
        while ((index = tabs.FindIndex(tab => closes(tab.Id))) >= 0)
        {
            Remove(index);
        }
    }

    /// <summary><see cref="CloseTabs(IReadOnlySet{Guid})"/>, each closed tab on the reopen stack with
    /// <paramref name="batch"/>. The selection moves first: to the next shown tab after the last closed one, else the
    /// one before, else a tab of a collapsed group, else the popped-out archived tab.</summary>
    private bool CloseTabs(IReadOnlySet<Guid> ids, Guid? batch)
    {
        var last = tabs.FindLastIndex(tab => ids.Contains(tab.Id));
        if (last < 0)
        {
            return tabs.Count > 0;
        }

        if (selectedTabId is { } selected && ids.Contains(selected))
        {
            var rest = Enumerable.Range(0, NormalEnd).Where(index => !ids.Contains(tabs[index].Id)).ToList();
            int? popped = ArchivedOut is { } outTab && !ids.Contains(outTab.Id) ? tabs.Count - 1 : null;
            if ((ShownNeighbor(ids) ?? FirstWhere(rest, index => index > last) ?? LastOf(rest) ?? popped) is { } next)
            {
                SelectTab(next);
            }
        }

        int at;
        while ((at = tabs.FindIndex(tab => ids.Contains(tab.Id))) >= 0)
        {
            Remove(at, batch: batch);
        }

        // After the removals: a popped-out archived tab in the set has just gone to the archive.
        if (tabs.Count == 0)
        {
            if (archivedTabs.Count == 0 && closedGroups.Count == 0)
            {
                Select(null);
                return false;
            }

            AddWelcome();
            return true;
        }

        Normalize();
        return true;
    }

    /// <summary>The tab to select when <paramref name="leaving"/> go: the next shown normal tab after the last of them,
    /// else the shown one before; null when no shown normal tab is left.</summary>
    private int? ShownNeighbor(IReadOnlySet<Guid> leaving)
    {
        var last = Math.Max(tabs.FindLastIndex(tab => leaving.Contains(tab.Id)), 0);
        var shown = Enumerable.Range(0, NormalEnd)
            .Where(index => !leaving.Contains(tabs[index].Id) && !IsHidden(index)).ToList();
        return FirstWhere(shown, index => index > last) ?? LastOf(shown);
    }

    /// <summary>
    /// Removes the tab at <paramref name="index"/>; a repo tab goes on the reopen stack with its manual group and
    /// <paramref name="batch"/>. The popped-out archived tab, or any tab when <paramref name="archiving"/>, goes to the
    /// archive's front instead (unpinned, in no group); with <paramref name="remembering"/> false it goes nowhere. A
    /// manual group left with no tab is dropped. The tab leaves the multi-selection and the kept layouts.
    /// </summary>
    private void Remove(int index, bool archiving = false, Guid? batch = null, bool remembering = true)
    {
        var tab = tabs[index];
        if (!remembering)
        {
            // Saved by the caller.
        }
        else if (tab.Archived || archiving)
        {
            archivedTabs.Insert(0, Saved(tab) with { Archived = true, Pinned = null, TabGroup = null });
        }
        else if (tab.Path is not null && !tab.IsMissing)
        {
            var group = tab.GroupId is { } groupId ? groups.Find(entry => entry.Id == groupId) : null;
            RememberClosed(new ClosedTab(Saved(tab), tab.RepoKey, group, batch, index));
        }

        tabs.RemoveAt(index);
        if (tab.GroupId is { } id && !tabs.Exists(other => other.GroupId == id))
        {
            groups.RemoveAll(group => group.Id == id);
        }

        PruneSelection([tab.Id]);
        recentlyShown.Remove(tab.Id);
    }

    private void RememberClosed(ClosedTab closed)
    {
        closedTabs.Add(closed);
        if (closedTabs.Count > ClosedTabsLimit)
        {
            closedTabs.RemoveAt(0);
        }
    }

    /// <summary>Every closed tab of <paramref name="batch"/> comes back at its index (last closed first) in its recreated
    /// group, and the first of them in tab order is selected. A member open again or in the archive is skipped; when
    /// every member is, the first one's open tab is selected.</summary>
    private void ReopenClosedBatch(Guid batch)
    {
        var entries = new List<ClosedTab>();
        while (closedTabs.Count > 0 && closedTabs[^1].Batch == batch)
        {
            entries.Add(closedTabs[^1]);
            closedTabs.RemoveAt(closedTabs.Count - 1);
        }

        var reopened = new HashSet<Guid>();
        foreach (var closed in entries)
        {
            if (closed.Saved.Path is { } path && !tabs.Exists(tab => SamePath(tab.Path, path))
                && ArchivedIndex(path) is null)
            {
                reopened.Add(InsertClosed(closed, path).Id);
            }
        }

        if (reopened.Count == 0)
        {
            if (entries[^1].Saved.Path is { } path && tabs.Find(tab => SamePath(tab.Path, path)) is { } existing)
            {
                SelectTab(existing.Id);
            }

            return;
        }

        Normalize();
        Select(tabs.Find(tab => reopened.Contains(tab.Id))?.Id);
        RequestRepoKeys(tabs.Where(tab => reopened.Contains(tab.Id) && !tab.IsMissing && tab.RepoKey is null)
            .Select(tab => tab.Id));
        RequestFolderChecks(reopened);
    }

    /// <summary>Puts a closed tab back at its index (a folder gone shows "Repo not found") in its manual group, recreated
    /// (same id, name and color) when gone. Neither normalizes nor selects.</summary>
    private Tab InsertClosed(ClosedTab closed, string path)
    {
        var saved = closed.Saved;
        var tab = new Tab(path, IsMissingNow(path), closed.RepoKey, saved.Alias, saved.Mark, saved.Pinned ?? false,
            saved.IconColor, GroupId: closed.Group?.Id, Profile: saved.Profile);
        if (closed.Group is { } group && !groups.Exists(entry => entry.Id == group.Id))
        {
            groups.Add(group with { Collapsed = false });
        }

        tabs.Insert(Math.Min(closed.Index, NormalEnd), tab);
        return tab;
    }

    /// <summary>One tab as the session saves it, and as the reopen stack keeps it.</summary>
    private static SavedTab Saved(Tab tab) =>
        new SavedTab(tab.Path, tab.Profile, tab.Alias, Pinned: tab.Pinned ? true : null, IconColor: tab.IconColor,
            Archived: tab.Archived ? true : null, TabGroup: tab.GroupId).WithMark(tab.Emoji);

    private void AddWelcome()
    {
        var welcome = new Tab();
        tabs.Add(welcome);
        Select(welcome.Id);
    }

    /// <summary>The tabs a manual group can hold among <paramref name="ids"/>, each with its whole worktree box: pinned
    /// tabs and the popped-out archived tab are skipped.</summary>
    private HashSet<Guid> Groupable(IEnumerable<Guid> ids)
    {
        var picked = ids.ToHashSet();
        var eligible = tabs.Where(tab => !tab.Pinned && !tab.Archived).ToList();
        var keys = eligible.Where(tab => picked.Contains(tab.Id)).Select(tab => tab.RepoKey).OfType<string>()
            .ToHashSet(StringComparer.Ordinal);
        return eligible.Where(tab => picked.Contains(tab.Id) || (tab.RepoKey is { } key && keys.Contains(key)))
            .Select(tab => tab.Id).ToHashSet();
    }

    /// <summary>The tab at <paramref name="index"/> is in a collapsed group.</summary>
    private bool IsHidden(int index) => tabs[index].GroupId is { } id && IsCollapsed(id);

    /// <summary>Opens the selected tab's group when it is collapsed.</summary>
    private void ExpandSelectedGroup()
    {
        if (SelectedIndex is not { } selected || tabs[selected].GroupId is not { } id)
        {
            return;
        }

        var index = groups.FindIndex(group => group.Id == id && group.Collapsed);
        if (index >= 0)
        {
            groups[index] = groups[index] with { Collapsed = false };
        }
    }

    /// <summary>Two or more picked tabs, else none.</summary>
    private void SetMultiSelection(HashSet<Guid> picked)
    {
        multiSelection.Clear();
        if (picked.Count > 1)
        {
            multiSelection.UnionWith(picked);
        }
    }

    /// <summary>The tabs leave the multi-selection; one tab left, or the selected tab gone from it, is none.</summary>
    private void PruneSelection(IEnumerable<Guid> ids)
    {
        var kept = multiSelection.Except(ids).ToHashSet();
        if (kept.Count == multiSelection.Count)
        {
            return;
        }

        SetMultiSelection(selectedTabId is { } selected && kept.Contains(selected) ? kept : []);
    }

    /// <summary>The last index of the worktree box the tab at <paramref name="index"/> is in; itself when in none.</summary>
    private int BoxEnd(int index)
    {
        if (tabs[index].RepoKey is not { } key)
        {
            return index;
        }

        var end = index;
        while (end + 1 < tabs.Count && string.Equals(tabs[end + 1].RepoKey, key, StringComparison.Ordinal))
        {
            end++;
        }

        return end;
    }

    private void RequestRepoKeys(IEnumerable<Guid> ids)
    {
        var targets = ids.Select(id => tabs.Find(tab => tab.Id == id)).OfType<Tab>()
            .Where(tab => tab.Path is not null).Select(tab => (tab.Id, tab.Path!)).ToList();
        if (targets.Count > 0)
        {
            RepoKeysNeeded?.Invoke(targets);
        }
    }

    /// <summary>A reopened or popped-out tab's folder checked in the call; false (found) when the app checks it later
    /// (<see cref="FolderChecksNeeded"/>).</summary>
    private bool IsMissingNow(string path) => FolderChecksNeeded is null && !folderExists(path);

    /// <summary>Asks the app to check the folders of <paramref name="ids"/> (<see cref="FolderChecksNeeded"/>).</summary>
    private void RequestFolderChecks(IEnumerable<Guid> ids)
    {
        if (FolderChecksNeeded is not { } needed)
        {
            return;
        }

        var targets = ids.Select(id => tabs.Find(tab => tab.Id == id)).OfType<Tab>()
            .Where(tab => tab.Path is not null).Select(tab => (tab.Id, tab.Path!)).ToList();
        if (targets.Count > 0)
        {
            needed(targets);
        }
    }

    /// <summary>Puts the tabs in order (<see cref="TabArrangement.Normalized"/>) and drops the groups left with no tab.
    /// The selection stays.</summary>
    private void Normalize() => Apply(TabArrangement.Normalized(ArrangementEntries));

    private void Apply(TabArrangement.Arrangement arrangement)
    {
        var byId = tabs.ToDictionary(tab => tab.Id);
        Replace(arrangement.Tabs.Where(entry => byId.ContainsKey(entry.Id))
            .Select(entry => byId[entry.Id] with { GroupId = entry.Group, Pinned = entry.Pinned }).ToList());
        groups.RemoveAll(group => !arrangement.Groups.Contains(group.Id));
        // The selected tab may just have joined a collapsed group.
        ExpandSelectedGroup();
    }

    private void Replace(List<Tab> ordered)
    {
        tabs.Clear();
        tabs.AddRange(ordered);
    }

    private void Update(Guid id, Func<Tab, Tab> change)
    {
        if (IndexOf(id) is { } index)
        {
            tabs[index] = change(tabs[index]);
        }
    }

    private int? IndexOf(Guid? id)
    {
        var index = id is null ? -1 : tabs.FindIndex(tab => tab.Id == id);
        return index >= 0 ? index : null;
    }

    /// <summary>The index in the archive of the entry for <paramref name="path"/>; null when the archive has none.</summary>
    private int? ArchivedIndex(string path)
    {
        var index = archivedTabs.FindIndex(entry => SamePath(entry.Path, path));
        return index >= 0 ? index : null;
    }

    /// <summary>Two repo paths name one folder by this flavor's rules (null names none).</summary>
    private bool SamePath(string? a, string b) =>
        a is not null && flavor.KeysEqual(flavor.Standardized(a), flavor.Standardized(b));

    private static int? FirstWhere(List<int> indices, Func<int, bool> match)
    {
        var at = indices.FindIndex(index => match(index));
        return at >= 0 ? indices[at] : null;
    }

    private static int? LastOf(List<int> indices) => indices.Count > 0 ? indices[^1] : null;
}

/// <summary>A tab's emoji, as Set Icon keeps it: one emoji text element (a flag or a ZWJ sequence is one, kept whole).</summary>
public static class TabEmoji
{
    /// <summary>
    /// The last emoji of <paramref name="text"/> once trimmed ("a😀b🔥" gives "🔥"); null when it has none ("1", plain
    /// text). A text element counts when one of its scalars shows as an emoji by default (Emoji_Presentation), or is
    /// followed by U+FE0F (as "❤️").
    /// </summary>
    public static string? Normalized(string text)
    {
        string? last = null;
        var elements = StringInfo.GetTextElementEnumerator(text.Trim());
        while (elements.MoveNext())
        {
            var element = elements.GetTextElement();
            if (IsEmoji(element))
            {
                last = element;
            }
        }

        return last;
    }

    private static bool IsEmoji(string element)
    {
        var runes = element.EnumerateRunes().ToList();
        for (var index = 0; index < runes.Count; index++)
        {
            if (IsEmojiPresentation(runes[index].Value)
                || (index + 1 < runes.Count && runes[index + 1].Value == 0xFE0F))
            {
                return true;
            }
        }

        return false;
    }

    private static bool IsEmojiPresentation(int scalar)
    {
        int low = 0, high = EmojiPresentation.Length - 1;
        while (low <= high)
        {
            var middle = (low + high) / 2;
            var (first, last) = EmojiPresentation[middle];
            if (scalar < first)
            {
                high = middle - 1;
            }
            else if (scalar > last)
            {
                low = middle + 1;
            }
            else
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>The scalars with the Unicode property Emoji_Presentation, as ranges in order (the Mac's
    /// <c>isEmojiPresentation</c>, read from Swift 6.4's tables).</summary>
    private static readonly (int First, int Last)[] EmojiPresentation =
    [
        (0x231A, 0x231B), (0x23E9, 0x23EC), (0x23F0, 0x23F0), (0x23F3, 0x23F3), (0x25FD, 0x25FE), (0x2614, 0x2615),
        (0x2648, 0x2653), (0x267F, 0x267F), (0x2693, 0x2693), (0x26A1, 0x26A1), (0x26AA, 0x26AB), (0x26BD, 0x26BE),
        (0x26C4, 0x26C5), (0x26CE, 0x26CE), (0x26D4, 0x26D4), (0x26EA, 0x26EA), (0x26F2, 0x26F3), (0x26F5, 0x26F5),
        (0x26FA, 0x26FA), (0x26FD, 0x26FD), (0x2705, 0x2705), (0x270A, 0x270B), (0x2728, 0x2728), (0x274C, 0x274C),
        (0x274E, 0x274E), (0x2753, 0x2755), (0x2757, 0x2757), (0x2795, 0x2797), (0x27B0, 0x27B0), (0x27BF, 0x27BF),
        (0x2B1B, 0x2B1C), (0x2B50, 0x2B50), (0x2B55, 0x2B55), (0x1F004, 0x1F004), (0x1F0CF, 0x1F0CF),
        (0x1F18E, 0x1F18E), (0x1F191, 0x1F19A), (0x1F1E6, 0x1F1FF), (0x1F201, 0x1F201), (0x1F21A, 0x1F21A),
        (0x1F22F, 0x1F22F), (0x1F232, 0x1F236), (0x1F238, 0x1F23A), (0x1F250, 0x1F251), (0x1F300, 0x1F320),
        (0x1F32D, 0x1F335), (0x1F337, 0x1F37C), (0x1F37E, 0x1F393), (0x1F3A0, 0x1F3CA), (0x1F3CF, 0x1F3D3),
        (0x1F3E0, 0x1F3F0), (0x1F3F4, 0x1F3F4), (0x1F3F8, 0x1F43E), (0x1F440, 0x1F440), (0x1F442, 0x1F4FC),
        (0x1F4FF, 0x1F53D), (0x1F54B, 0x1F54E), (0x1F550, 0x1F567), (0x1F57A, 0x1F57A), (0x1F595, 0x1F596),
        (0x1F5A4, 0x1F5A4), (0x1F5FB, 0x1F64F), (0x1F680, 0x1F6C5), (0x1F6CC, 0x1F6CC), (0x1F6D0, 0x1F6D2),
        (0x1F6D5, 0x1F6D8), (0x1F6DC, 0x1F6DF), (0x1F6EB, 0x1F6EC), (0x1F6F4, 0x1F6FC), (0x1F7E0, 0x1F7EB),
        (0x1F7F0, 0x1F7F0), (0x1F90C, 0x1F93A), (0x1F93C, 0x1F945), (0x1F947, 0x1F9FF), (0x1FA70, 0x1FA7C),
        (0x1FA80, 0x1FA8A), (0x1FA8E, 0x1FAC6), (0x1FAC8, 0x1FAC8), (0x1FACD, 0x1FADC), (0x1FADF, 0x1FAEA),
        (0x1FAEF, 0x1FAF8),
    ];
}
