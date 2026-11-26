// The order rules of a window's tabs: worktree tabs of one repo sit side by side in a box, manual groups hold whole
// boxes and plain tabs, pinned tabs come first and are never grouped, and the popped-out archived tab stays last.
// Works on plain values, so the app maps its tabs in and reads the order, groups and pins back out.
// Ported from TabArrangement.swift at 6fa6d40.
namespace Histq.Core;

public static class TabArrangement
{
    /// <summary>One tab as the rules see it.</summary>
    /// <param name="Repo">The repository key its worktree tabs share; null for a tab with no repository.</param>
    /// <param name="Group">The manual group it is in.</param>
    /// <param name="Archived">The popped-out archived tab.</param>
    public readonly record struct Entry(
        Guid Id, string? Repo = null, Guid? Group = null, bool Pinned = false, bool Archived = false);

    /// <summary>The tabs in their new order, with their group and pin updated, and the groups that still have a tab.</summary>
    public sealed record Arrangement(IReadOnlyList<Entry> Tabs, IReadOnlySet<Guid> Groups)
    {
        public bool Equals(Arrangement? other) =>
            other is not null && Tabs.SequenceEqual(other.Tabs) && Groups.SetEquals(other.Groups);

        public override int GetHashCode() => HashCode.Combine(Tabs.Count, Groups.Count);
    }

    /// <summary>
    /// A part of the tab row: a manual group (of boxes and tabs), a worktree box (of tabs), or a plain tab.
    /// </summary>
    public abstract record Segment
    {
        private Segment()
        {
        }

        public sealed record Group(Guid Id, IReadOnlyList<Segment> Parts) : Segment
        {
            public bool Equals(Group? other) => other is not null && Id == other.Id && Parts.SequenceEqual(other.Parts);

            public override int GetHashCode() => HashCode.Combine(Id, Parts.Count);
        }

        public sealed record Box(string Repo, IReadOnlyList<Guid> Tabs) : Segment
        {
            public bool Equals(Box? other) =>
                other is not null && string.Equals(Repo, other.Repo, StringComparison.Ordinal)
                && Tabs.SequenceEqual(other.Tabs);

            public override int GetHashCode() => HashCode.Combine(StringComparer.Ordinal.GetHashCode(Repo), Tabs.Count);
        }

        public sealed record Tab(Guid Id) : Segment;
    }

    /// <summary>What a drag moves: one tab, a whole worktree box (the non-archived tabs of its repo), or a whole manual group.</summary>
    public abstract record Unit
    {
        private Unit()
        {
        }

        public sealed record Tab(Guid Id) : Unit;

        public sealed record Box(string Repo) : Unit;

        public sealed record Group(Guid Id) : Unit;
    }

    /// <summary>
    /// Puts <paramref name="tabs"/> in order. The archived tab goes last, ungrouped and unpinned. Each repo's tabs
    /// gather right after its first tab, the others keeping their order; a box with a pinned tab is pinned whole, else
    /// it takes the group of its first grouped tab. Each group's boxes and tabs gather right after its first one.
    /// Pinned tabs lose their group and come first, each side keeping its order.
    /// </summary>
    public static Arrangement Normalized(IReadOnlyList<Entry> tabs)
    {
        var archived = tabs.Where(entry => entry.Archived)
            .Select(entry => entry with { Group = null, Pinned = false });
        var rest = tabs.Where(entry => !entry.Archived).ToList();

        // Boxes: a repo's tabs at its first tab; a tab with no repo is a unit of its own.
        var units = new List<List<Entry>>();
        var placed = new HashSet<string>(StringComparer.Ordinal);
        foreach (var entry in rest)
        {
            if (entry.Repo is not { } repo)
            {
                units.Add([entry]);
                continue;
            }

            if (!placed.Add(repo))
            {
                continue;
            }

            units.Add(rest.Where(other => SameRepo(other.Repo, repo)).ToList());
        }

        // A box is pinned whole, or takes the group of its first grouped tab.
        units = units.Select(unit =>
        {
            var pinned = unit.Any(entry => entry.Pinned);
            var group = pinned ? null : unit.FirstOrDefault(entry => entry.Group is not null).Group;
            return unit.Select(entry => entry with { Pinned = pinned, Group = group }).ToList();
        }).ToList();

        // Groups: a group's units at its first unit.
        var unpinned = units.Where(unit => !unit[0].Pinned).ToList();
        var gathered = new List<List<Entry>>();
        var seen = new HashSet<Guid>();
        foreach (var unit in unpinned)
        {
            if (unit[0].Group is not { } group)
            {
                gathered.Add(unit);
                continue;
            }

            if (!seen.Add(group))
            {
                continue;
            }

            gathered.AddRange(unpinned.Where(other => other[0].Group == group));
        }

        var ordered = units.Where(unit => unit[0].Pinned).SelectMany(unit => unit)
            .Concat(gathered.SelectMany(unit => unit))
            .Concat(archived)
            .ToList();
        var groups = ordered.Where(entry => entry.Group is not null).Select(entry => entry.Group!.Value).ToHashSet();
        return new Arrangement(ordered, groups);
    }

    /// <summary>
    /// The row's parts in order, read from neighbors only (pass tabs in <see cref="Normalized"/> order): a run of two
    /// or more tabs of one repo is a box, a run of one group's boxes and tabs is a group. Pinned and archived tabs are
    /// in no group, and the archived tab in no box.
    /// </summary>
    public static IReadOnlyList<Segment> Segments(IReadOnlyList<Entry> tabs)
    {
        var segments = new List<Segment>();
        var start = 0;
        while (start < tabs.Count)
        {
            var group = GroupOf(tabs[start]);
            var end = start;
            while (end + 1 < tabs.Count && GroupOf(tabs[end + 1]) == group)
            {
                end += 1;
            }

            var parts = Boxes(tabs, start, end + 1);
            if (group is { } id)
            {
                segments.Add(new Segment.Group(id, parts));
            }
            else
            {
                segments.AddRange(parts);
            }

            start = end + 1;
        }

        return segments;
    }

    /// <summary>
    /// The allowed places for <paramref name="unit"/> once moved (pass <paramref name="tabs"/> in
    /// <see cref="Normalized"/> order). A place is the index of the unit's first tab in the resulting order, that is
    /// where its tabs go among the other tabs. The unit stays in the pinned or unpinned area, before the archived tab;
    /// it never splits a box, nor a group other than <paramref name="targetGroup"/>; with <paramref name="targetGroup"/>
    /// set it stays inside that group's tabs (either edge joins it), with null it stays out of every group. A box tab's
    /// own unit only reorders inside its box. <paramref name="targetGroup"/> is ignored for a pinned unit, a box tab's
    /// own unit and a <see cref="Unit.Group"/> unit (always among top-level places), and when the move leaves the
    /// target group with no other tab (the unit then keeps it, at any top-level place). Empty for the archived tab.
    /// </summary>
    public static int[] Destinations(Unit unit, Guid? targetGroup, IReadOnlyList<Entry> tabs)
    {
        var moved = Members(unit, tabs);
        if (moved.Count == 0 || moved.Any(entry => entry.Archived))
        {
            return [];
        }

        var ids = moved.Select(entry => entry.Id).ToHashSet();
        var rest = tabs.Where(entry => !ids.Contains(entry.Id)).ToList();

        if (unit is Unit.Tab && BoxStart(moved[0], rest) is { } boxStart)
        {
            var boxEnd = boxStart;
            while (boxEnd < rest.Count && SameRepo(rest[boxEnd].Repo, moved[0].Repo) && !rest[boxEnd].Archived)
            {
                boxEnd += 1;
            }

            return Enumerable.Range(boxStart, boxEnd - boxStart + 1).ToArray();
        }

        var pinnedCount = rest.TakeWhile(entry => entry.Pinned).Count();
        var normalEnd = rest.FindIndex(entry => entry.Archived);
        if (normalEnd < 0)
        {
            normalEnd = rest.Count;
        }

        var pinned = moved[0].Pinned;
        var target = pinned || unit is Unit.Group ? null : targetGroup;
        (int First, int Last)? span = null;
        if (target is { } targetId)
        {
            var first = rest.FindIndex(entry => GroupOf(entry) == targetId);
            var last = rest.FindLastIndex(entry => GroupOf(entry) == targetId);
            if (first >= 0)
            {
                span = (first, last + 1);
            }
        }

        var (areaStart, areaEnd) = pinned ? (0, pinnedCount) : (pinnedCount, normalEnd);
        var places = new List<int>();
        for (var index = areaStart; index <= areaEnd; index++)
        {
            if (SplitsBox(index, rest))
            {
                continue;
            }

            var allowed = span is { } range
                ? index >= range.First && index <= range.Last
                : InsideGroup(index, rest) is null;
            if (allowed)
            {
                places.Add(index);
            }
        }

        return places.ToArray();
    }

    /// <summary>
    /// Moves <paramref name="unit"/> to <paramref name="index"/>, one of <see cref="Destinations"/> with
    /// <c>targetGroup</c> = <paramref name="group"/> (pass <paramref name="tabs"/> in <see cref="Normalized"/> order;
    /// any other index leaves the order as it is). The unit's tabs take <paramref name="group"/>, except a pinned tab
    /// (never in a group), a <see cref="Unit.Group"/> unit (keeps its id) and a box tab's own unit (keeps its box's
    /// group).
    /// </summary>
    public static Arrangement Move(Unit unit, int index, Guid? group, IReadOnlyList<Entry> tabs)
    {
        if (!Destinations(unit, group, tabs).Contains(index))
        {
            return Normalized(tabs);
        }

        var moved = Members(unit, tabs);
        var ids = moved.Select(entry => entry.Id).ToHashSet();
        var rest = tabs.Where(entry => !ids.Contains(entry.Id)).ToList();
        var keepsGroup = unit is Unit.Group || (unit is Unit.Tab && BoxStart(moved[0], rest) is not null);
        if (!keepsGroup)
        {
            moved = moved.Select(entry => entry with { Group = entry.Pinned ? null : group }).ToList();
        }

        rest.InsertRange(index, moved);
        return Normalized(rest);
    }

    /// <summary>The tabs <paramref name="unit"/> stands for, in order.</summary>
    private static List<Entry> Members(Unit unit, IReadOnlyList<Entry> tabs) => unit switch
    {
        Unit.Tab tab => tabs.Where(entry => entry.Id == tab.Id).ToList(),
        Unit.Box box => tabs.Where(entry => SameRepo(entry.Repo, box.Repo) && !entry.Archived).ToList(),
        Unit.Group group => tabs.Where(entry => GroupOf(entry) == group.Id).ToList(),
        _ => [],
    };

    /// <summary>
    /// Where the rest of <paramref name="entry"/>'s box starts in <paramref name="rest"/> (the tabs without it), or
    /// null when no other tab shares its box.
    /// </summary>
    private static int? BoxStart(Entry entry, List<Entry> rest)
    {
        if (entry.Repo is not { } repo || entry.Archived)
        {
            return null;
        }

        var index = rest.FindIndex(other => SameRepo(other.Repo, repo) && !other.Archived);
        return index >= 0 ? index : null;
    }

    /// <summary>A place between two tabs of one box.</summary>
    private static bool SplitsBox(int index, List<Entry> tabs)
    {
        if (index <= 0 || index >= tabs.Count || tabs[index].Repo is not { } repo)
        {
            return false;
        }

        return SameRepo(tabs[index - 1].Repo, repo) && !tabs[index].Archived && !tabs[index - 1].Archived;
    }

    /// <summary>The group a place sits strictly inside, between two of its tabs.</summary>
    private static Guid? InsideGroup(int index, List<Entry> tabs)
    {
        if (index <= 0 || index >= tabs.Count || GroupOf(tabs[index]) is not { } group)
        {
            return null;
        }

        return GroupOf(tabs[index - 1]) == group ? group : null;
    }

    /// <summary>The group a tab is drawn in: none for a pinned or archived tab.</summary>
    private static Guid? GroupOf(Entry entry) => entry.Pinned || entry.Archived ? null : entry.Group;

    private static bool SameRepo(string? a, string? b) => string.Equals(a, b, StringComparison.Ordinal);

    /// <summary>
    /// The boxes (runs of two or more tabs of one repo, never the archived tab) and plain tabs of
    /// <paramref name="tabs"/> from <paramref name="from"/> up to (not including) <paramref name="to"/>.
    /// </summary>
    private static List<Segment> Boxes(IReadOnlyList<Entry> tabs, int from, int to)
    {
        var parts = new List<Segment>();
        var start = from;
        while (start < to)
        {
            var end = start;
            if (tabs[start].Repo is { } repo && !tabs[start].Archived)
            {
                while (end + 1 < to && SameRepo(tabs[end + 1].Repo, repo) && !tabs[end + 1].Archived)
                {
                    end += 1;
                }

                if (end > start)
                {
                    var ids = new List<Guid>(end - start + 1);
                    for (var index = start; index <= end; index++)
                    {
                        ids.Add(tabs[index].Id);
                    }

                    parts.Add(new Segment.Box(repo, ids));
                    start = end + 1;
                    continue;
                }
            }

            parts.Add(new Segment.Tab(tabs[start].Id));
            start = end + 1;
        }

        return parts;
    }
}
