// Tab groups: the tabs of one repository's worktrees sit side by side in a worktree box, and manual groups gather tabs
// and boxes under one color and an optional name. RepoGroupKey reads the repository a folder belongs to from small
// files, no git process; TabGroupSpans places the tabs and group headers along the tab row (or column) and finds where
// a dragged tab, box or group drops. Ported from TabGroups.swift (10-46, 72-290) at 6fa6d40.
using System.Text;

namespace Histq.Core;

/// <summary>
/// The repository a folder belongs to: its git common dir, which all its worktrees share. Read from the folder's
/// <c>.git</c> (the repo's own folder, or a worktree's <c>gitdir:</c> file and that dir's <c>commondir</c>): small files,
/// read off the UI thread by the app. Nothing is read under a UNC or device path, and a <c>gitdir:</c> or
/// <c>commondir</c> that points to one gives no key.
/// </summary>
public static class RepoGroupKey
{
    /// <summary>The most bytes read from a <c>.git</c> or <c>commondir</c> file; a longer file is not git's.</summary>
    public const int MaxFileBytes = 4096;

    /// <summary>The folder's common dir as a standardized path; null when the folder has no <c>.git</c> that can be read.</summary>
    public static string? Of(string folder) =>
        Of(folder, PathFlavor.Host, Directory.Exists, ReadSmallFile);

    /// <summary>
    /// <see cref="Of(string)"/> for a folder the user gave this machine (a tab of their own <c>session.json</c>, a folder
    /// they picked): a UNC or device folder (<c>\\wsl.localhost\Ubuntu\home\me\repo</c>) is read too. A <c>gitdir:</c>
    /// or <c>commondir</c> that points to one still gives no key. Never for a path read from a received <c>.histqws</c>.
    /// </summary>
    public static string? OfUserFolder(string folder) =>
        Of(folder, PathFlavor.Host, Directory.Exists, ReadSmallFile, allowUncOrDeviceFolder: true);

    /// <summary><see cref="Of(string)"/> with the path rules of <paramref name="flavor"/> and the given probes, so tests
    /// check the UNC guard on any host. <paramref name="readFile"/> gives a file's text, or null when it cannot be read.
    /// <paramref name="allowUncOrDeviceFolder"/> lifts the refusal of a UNC or device <paramref name="folder"/> only
    /// (<see cref="OfUserFolder"/>).</summary>
    internal static string? Of(
        string folder, PathFlavor flavor, Func<string, bool> directoryExists, Func<string, string?> readFile,
        bool allowUncOrDeviceFolder = false)
    {
        if (!allowUncOrDeviceFolder && flavor.IsUncOrDevice(folder))
        {
            return null;
        }

        var dotGit = flavor.Resolve(folder, ".git");
        if (directoryExists(dotGit))
        {
            return dotGit;
        }

        const string prefix = "gitdir:";
        var line = readFile(dotGit)?.Split('\n', '\r').FirstOrDefault(part => part.Length > 0);
        if (line is null || !line.StartsWith(prefix, StringComparison.Ordinal))
        {
            return null;
        }

        var gitDirPath = line[prefix.Length..].Trim(' ', '\t');
        if (gitDirPath.Length == 0 || flavor.IsUncOrDevice(gitDirPath))
        {
            return null;
        }

        var gitDir = flavor.Resolve(folder, gitDirPath);
        if (readFile(flavor.Resolve(gitDir, "commondir")) is not { } common)
        {
            return gitDir;
        }

        var commonPath = common.Trim();
        return flavor.IsUncOrDevice(commonPath) ? null : flavor.Resolve(gitDir, commonPath);
    }

    /// <summary>The file's text when it holds at most <see cref="MaxFileBytes"/> bytes and no NUL; null when it is
    /// longer, holds a NUL (never a path), or cannot be read (a path that is not one included).</summary>
    private static string? ReadSmallFile(string path)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            var buffer = new byte[MaxFileBytes + 1];
            var count = stream.ReadAtLeast(buffer, buffer.Length, throwOnEndOfStream: false);
            var text = Encoding.UTF8.GetString(buffer, 0, Math.Min(count, MaxFileBytes));
            return count > MaxFileBytes || text.AsSpan().Contains('\0') ? null : text;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return null;
        }
    }
}

/// <summary>A manual tab group of one window (<see cref="WindowTabs.Groups"/>).</summary>
/// <param name="Name">The name the user gave it; null shows just its color.</param>
/// <param name="ColorIndex">Its swatch: 0 is grey, 1-8 a lane color.</param>
/// <param name="Collapsed">It shows only its chip.</param>
public sealed record ManualTabGroup(Guid Id, string? Name, int ColorIndex, bool Collapsed);

/// <summary>Two or more neighboring tabs of one repository (<see cref="WindowTabs.WorktreeBoxes"/>), at the tab
/// indices <paramref name="First"/> to <paramref name="Last"/>. A repo with a single tab has no box.</summary>
public sealed record WorktreeBox(string Key, int First, int Last)
{
    public bool Contains(int index) => index >= First && index <= Last;
}

/// <summary>The neighboring tabs of one manual group (<see cref="WindowTabs.ManualGroups"/>), at the tab indices
/// <paramref name="First"/> to <paramref name="Last"/>, with its entry in the group table.</summary>
public sealed record TabGroup(ManualTabGroup Group, int First, int Last)
{
    public Guid Id => Group.Id;

    public int Count => Last - First + 1;

    public bool Contains(int index) => index >= First && index <= Last;
}

/// <summary>
/// The tabs in order with each manual group's header (the top tabs' chip, the vertical tabs' name row) before its first
/// tab, and where they stand along the row or column: each item's start, the items <see cref="Gap"/> apart. A worktree
/// box takes no room of its own: it is drawn around its tabs (<see cref="BoxSpan"/>), inside the gaps. Shared by the tab
/// strip and the vertical tabs, so a drag can place every item (and box) where it would stand with the unit dropped at
/// its target.
/// </summary>
public sealed class TabGroupSpans
{
    private readonly double[] extents;
    private readonly Dictionary<Guid, double> headerExtents = [];
    private readonly Dictionary<int, Guid> groupKey = [];
    private readonly HashSet<Guid> collapsed;

    /// <summary>Each group once, in the order given (first entry kept).</summary>
    private readonly List<TabGroup> groups = [];

    /// <param name="extent">The tab at an index's own extent; without it every tab takes <paramref name="tabExtent"/>.</param>
    public TabGroupSpans(
        IReadOnlyList<WindowTabs.Tab> tabs, IReadOnlyList<TabGroup> groups, IReadOnlyList<WorktreeBox> boxes,
        double tabExtent, double gap, Func<TabGroup, double> headerExtent, Func<int, double>? extent = null)
    {
        collapsed = groups.Where(group => group.Group.Collapsed).Select(group => group.Id).ToHashSet();
        var items = new List<Item>();
        for (var index = 0; index < tabs.Count; index++)
        {
            if (groups.FirstOrDefault(group => group.Contains(index)) is { } group)
            {
                if (group.First == index)
                {
                    items.Add(new Item.Header(group));
                }

                groupKey[index] = group.Id;
                if (collapsed.Contains(group.Id))
                {
                    continue;
                }
            }

            items.Add(new Item.Tab(index, tabs[index]));
        }

        foreach (var group in groups)
        {
            if (headerExtents.TryAdd(group.Id, headerExtent(group)))
            {
                this.groups.Add(group);
            }
        }

        Items = items;
        TabExtent = tabExtent;
        Gap = gap;
        Boxes = boxes;
        extents = Enumerable.Range(0, tabs.Count).Select(index => extent?.Invoke(index) ?? tabExtent).ToArray();
    }

    /// <summary>A row item: a group's header, or a tab (none for the tabs of a collapsed group).</summary>
    public abstract record Item
    {
        private Item()
        {
        }

        public sealed record Header(TabGroup Group) : Item;

        public sealed record Tab(int Index, WindowTabs.Tab Value) : Item;
    }

    /// <summary>Where the tabs (by index) and the group headers (by group) start, and where each group ends (its last
    /// tab's end, its header's end when collapsed).</summary>
    public sealed class Positions
    {
        public Dictionary<int, double> Tabs { get; } = [];

        public Dictionary<Guid, double> Headers { get; } = [];

        public Dictionary<Guid, double> Ends { get; } = [];
    }

    public IReadOnlyList<Item> Items { get; }

    /// <summary>A tab's width (top tabs) or height (vertical tabs) when every tab shares one.</summary>
    public double TabExtent { get; }

    public double Gap { get; }

    /// <summary>The worktree boxes drawn around their tabs.</summary>
    public IReadOnlyList<WorktreeBox> Boxes { get; }

    /// <summary>Where the box's tabs stand at <paramref name="positions"/>: from its first tab's start to its last tab's
    /// end (its tabs in any order, so a drag inside the box keeps it whole); null while a collapsed group hides it.</summary>
    public (double Start, double End)? BoxSpan(WorktreeBox box, Positions positions)
    {
        if (groupKey.TryGetValue(box.First, out var key) && collapsed.Contains(key))
        {
            return null;
        }

        var indices = Enumerable.Range(box.First, box.Last - box.First + 1)
            .Where(index => positions.Tabs.ContainsKey(index)).ToList();
        if (indices.Count == 0)
        {
            return null;
        }

        return (indices.Min(index => positions.Tabs[index]), indices.Max(index => positions.Tabs[index] + ExtentOf(index)));
    }

    /// <summary>The manual group the tab at <paramref name="index"/> is in; null for none.</summary>
    public TabGroup? GroupAt(int index) =>
        groupKey.TryGetValue(index, out var key) ? groups.Find(group => group.Id == key) : null;

    /// <summary>The tab at <paramref name="index"/>'s extent; <see cref="TabExtent"/> outside the tabs.</summary>
    public double ExtentOf(int index) => index >= 0 && index < extents.Length ? extents[index] : TabExtent;

    // A drag moves a TabArrangement.Unit: a tab, a whole worktree box or a whole group. `entries` are the tabs as
    // TabArrangement sees them, in order: entries[i] is the tab at index i. An index is where the unit's first tab
    // stands once moved, as TabArrangement.Destinations and Move read it.

    /// <summary>The tab indices of <paramref name="unit"/> (always neighbors); null when it has none.</summary>
    public static (int First, int Last)? RangeOf(TabArrangement.Unit unit, IReadOnlyList<TabArrangement.Entry> entries)
    {
        bool Holds(TabArrangement.Entry entry) => unit switch
        {
            TabArrangement.Unit.Tab tab => entry.Id == tab.Id,
            TabArrangement.Unit.Box box => string.Equals(entry.Repo, box.Repo, StringComparison.Ordinal) && !entry.Archived,
            TabArrangement.Unit.Group group => entry.Group == group.Id && !entry.Pinned && !entry.Archived,
            _ => false,
        };

        var first = -1;
        var last = -1;
        for (var index = 0; index < entries.Count; index++)
        {
            if (Holds(entries[index]))
            {
                first = first < 0 ? index : first;
                last = index;
            }
        }

        return first < 0 ? null : (first, last);
    }

    /// <summary>The tab indices in order with the tabs at <paramref name="range"/> (a unit's) dropped at
    /// <paramref name="destination"/>, their first tab's index once moved.</summary>
    public static int[] Moved(int count, (int First, int Last) range, int destination)
    {
        var order = Enumerable.Range(0, count).ToList();
        var length = range.Last - range.First + 1;
        if (range.First < 0 || range.Last >= count || destination < 0 || destination > count - length)
        {
            return order.ToArray();
        }

        order.RemoveRange(range.First, length);
        order.InsertRange(destination, Enumerable.Range(range.First, length));
        return order.ToArray();
    }

    /// <summary>Where the tabs and headers stand with the tabs in <paramref name="order"/> and the tabs at
    /// <paramref name="moving"/> (the dragged unit's) in the group <paramref name="membership"/> (pass
    /// <see cref="DragTarget"/>'s group; <paramref name="moving"/> null at rest). A group left with no tab has no header
    /// position: it would go.</summary>
    public Positions PositionsFor(IReadOnlyList<int> order, (int First, int Last)? moving, Guid? membership)
    {
        var positions = new Positions();
        var x = 0.0;
        Guid? previous = null;
        foreach (var index in order)
        {
            Guid? key = moving is { } range && index >= range.First && index <= range.Last
                ? membership
                : groupKey.TryGetValue(index, out var own) ? own : null;
            if (key is { } header && key != previous)
            {
                positions.Headers[header] = x;
                x += headerExtents.GetValueOrDefault(header) + Gap;
            }

            previous = key;
            positions.Tabs[index] = x;
            if (key is not { } group)
            {
                x += ExtentOf(index) + Gap;
                continue;
            }

            // A collapsed group's tabs stand at its header's end, with no room.
            if (collapsed.Contains(group))
            {
                positions.Ends[group] = x - Gap;
                continue;
            }

            positions.Ends[group] = x + ExtentOf(index);
            x += ExtentOf(index) + Gap;
        }

        return positions;
    }

    /// <summary>From a group's header start to its last tab's end (its header's end when collapsed) at
    /// <paramref name="positions"/>; null when it has no tab there.</summary>
    public static double? Span(Guid group, Positions positions) =>
        positions.Headers.TryGetValue(group, out var start) && positions.Ends.TryGetValue(group, out var end)
            ? end - start
            : null;

    /// <summary>The group <paramref name="unit"/>'s tabs are in before it moves: a group unit's own id, null for a
    /// pinned unit. The drag's first <c>current</c> for <see cref="DragTarget"/>.</summary>
    public Guid? GroupOf(TabArrangement.Unit unit, IReadOnlyList<TabArrangement.Entry> entries)
    {
        if (unit is TabArrangement.Unit.Group group)
        {
            return group.Id;
        }

        return RangeOf(unit, entries) is { } range ? GroupAt(range.First)?.Id : null;
    }

    /// <summary>
    /// Where <paramref name="unit"/> would drop, dragged <paramref name="translation"/> along the axis. Index is its first
    /// tab's index once moved, the allowed one (<see cref="TabArrangement.Destinations"/>) nearest the pointer; Group is
    /// the group its tabs are in once dropped (a group unit's own id, a box tab's box's group, null for a pinned unit).
    /// Draw the drag with <c>PositionsFor(Moved(count, range, index), range, group)</c>, drop it with
    /// <see cref="TabArrangement.Move"/>, and pass Group back as the next call's <paramref name="current"/>
    /// (<see cref="GroupOf"/> at the drag's start).
    /// </summary>
    public (int Index, Guid? Group) DragTarget(
        TabArrangement.Unit unit, double translation, Guid? current, IReadOnlyList<TabArrangement.Entry> entries)
    {
        if (RangeOf(unit, entries) is not { } range)
        {
            return (0, current);
        }

        var group = Membership(unit, range, translation, current, entries);

        // A group moves by its header, the others by their first tab.
        double Anchor(Positions positions) => unit is TabArrangement.Unit.Group moved
            ? positions.Headers.GetValueOrDefault(moved.Id)
            : positions.Tabs.GetValueOrDefault(range.First);

        var all = Enumerable.Range(0, entries.Count).ToList();
        var pointer = Anchor(PositionsFor(all, null, null)) + translation;
        var destinations = TabArrangement.Destinations(unit, group, entries);
        if (destinations.Length == 0)
        {
            return (range.First, group);
        }

        var nearest = destinations.MinBy(destination =>
            Math.Abs(Anchor(PositionsFor(Moved(entries.Count, range, destination), range, group)) - pointer));
        return (nearest, group);
    }

    /// <summary>
    /// The group the unit at <paramref name="range"/> is dragged into: the expanded group whose span, measured without
    /// the unit, holds the unit's start + translation - half a gap. Leaving <paramref name="current"/> takes a quarter
    /// tab past its edge and joining another a quarter tab inside it, so it never flickers at an edge. A collapsed group
    /// is never joined. A unit that is its group's only content keeps that group unless it joins another. A group unit,
    /// a pinned unit and a box tab's own unit keep their group.
    /// </summary>
    private Guid? Membership(
        TabArrangement.Unit unit, (int First, int Last) range, double translation, Guid? current,
        IReadOnlyList<TabArrangement.Entry> entries)
    {
        if (unit is TabArrangement.Unit.Group group)
        {
            return group.Id;
        }

        var first = entries[range.First];
        if (first.Pinned)
        {
            return null;
        }

        var own = GroupAt(range.First);
        if (unit is TabArrangement.Unit.Tab && first.Repo is { } repo && !first.Archived
            && entries.Any(entry => entry.Id != first.Id && string.Equals(entry.Repo, repo, StringComparison.Ordinal)
                                    && !entry.Archived))
        {
            return own?.Id;
        }

        var all = Enumerable.Range(0, entries.Count).ToList();
        var start = PositionsFor(all, null, null).Tabs.GetValueOrDefault(range.First);
        var probe = start + translation - Gap / 2;
        var rest = PositionsFor(all.Where(index => index < range.First || index > range.Last).ToList(), null, null);
        var margin = TabExtent / 4;

        // Each expanded group's span without the unit; none for a group the unit is all of.
        var spans = new List<(Guid Id, double Start, double End)>();
        foreach (var candidate in groups.Where(candidate => !collapsed.Contains(candidate.Id)))
        {
            var last = Enumerable.Range(candidate.First, candidate.Count)
                .LastOrDefault(index => index < range.First || index > range.Last, -1);
            if (rest.Headers.TryGetValue(candidate.Id, out var spanStart) && last >= 0)
            {
                spans.Add((candidate.Id, spanStart, rest.Tabs.GetValueOrDefault(last) + ExtentOf(last)));
            }
        }

        if (spans.FindIndex(span => span.Id == current) is var kept and >= 0
            && probe >= spans[kept].Start - margin && probe <= spans[kept].End + margin)
        {
            return current;
        }

        var joined = spans.FindIndex(span =>
            span.Id != current && probe >= span.Start + margin && probe <= span.End - margin);
        if (joined >= 0)
        {
            return spans[joined].Id;
        }

        return own is not null && !rest.Headers.ContainsKey(own.Id) ? own.Id : null;
    }
}
