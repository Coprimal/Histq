using Histq.App.Theme;
using Histq.Core;

namespace Histq.App.Shell.Tabs;

/// <summary>The tab row's sizes (design header-and-tab-row.md §3), read once from Theme/Palette.xaml.</summary>
internal sealed record TabMetrics(
    double Height,
    double Gap,
    double Radius,
    double Flare,
    double MinWidth,
    double MaxWidth,
    double PinnedWidth,
    double ArchivedWidth,
    double HeadWidth,
    double BoxInset,
    double BottomInset,
    double ChipHeight,
    double ChipPadding,
    double ChipMaxWidth,
    double ButtonSize,
    double SquareSize,
    double StowGap,
    double DividerHeight,
    double DividerSpacing,
    double ArrowSpacing,
    double EdgeFade,
    double GroupLine,
    double Outline)
{
    /// <summary>The metrics from the app's resources; call on the UI thread.</summary>
    public static TabMetrics FromPalette() => new(
        Height: PaletteResources.Double("TabHeight"),
        Gap: PaletteResources.Double("TabGap"),
        Radius: PaletteResources.Double("TabRadius"),
        Flare: PaletteResources.Double("TabFlare"),
        MinWidth: PaletteResources.Double("TabMinWidth"),
        MaxWidth: PaletteResources.Double("TabMaxWidth"),
        PinnedWidth: PaletteResources.Double("PinnedTabWidth"),
        ArchivedWidth: PaletteResources.Double("ArchivedTabWidth"),
        HeadWidth: PaletteResources.Double("WorktreeHeadWidth"),
        BoxInset: PaletteResources.Double("WorktreeBoxInset"),
        BottomInset: PaletteResources.Double("TabRowBottomInset"),
        ChipHeight: PaletteResources.Double("ChipHeight"),
        ChipPadding: PaletteResources.Double("ChipPadding"),
        ChipMaxWidth: PaletteResources.Double("ChipMaxWidth"),
        ButtonSize: PaletteResources.Double("TabRowButtonSize"),
        SquareSize: PaletteResources.Double("SquareButtonSize"),
        StowGap: PaletteResources.Double("StowButtonGap"),
        DividerHeight: PaletteResources.Double("PinnedDividerHeight"),
        DividerSpacing: PaletteResources.Double("PinnedDividerSpacing"),
        ArrowSpacing: PaletteResources.Double("TabArrowSpacing"),
        EdgeFade: PaletteResources.Double("TabTrackEdgeFade"),
        GroupLine: PaletteResources.Double("GroupLineThickness"),
        Outline: PaletteResources.Double("TabOutlineThickness"));
}

/// <summary>
/// Where the window's tabs stand along the tab row (ported from TabTrack's sizing, App/Window/TabStrip.swift): the
/// unpinned tabs share one width between <see cref="TabMetrics.MinWidth"/> and <see cref="TabMetrics.MaxWidth"/>
/// (whole epx), from what the chips, the worktree heads and the gaps leave of the track; past the minimum the track
/// scrolls. One <see cref="TabGroupSpans"/> over every tab places them all, by their real indices: the pinned tabs first
/// (the pinned well, which does not scroll), then the track's chips, heads and tabs (a collapsed group's tabs take no
/// room), the popped-out archived tab last with no room (it stands beside the archive button). A worktree box outside
/// the well starts with its head, which is part of its first tab's extent, so the box's span covers it.
/// </summary>
internal sealed class TabTrackLayout
{
    private readonly TabMetrics _metrics;

    private TabTrackLayout(
        TabMetrics metrics, IReadOnlyList<WindowTabs.Tab> tabs, IReadOnlyList<TabGroup> groups,
        IReadOnlyList<WorktreeBox> boxes, TabGroupSpans spans, TabGroupSpans.Positions positions, int pinnedCount,
        double tabWidth, double origin, double rowWidth, double wellWidth, bool overflows, IReadOnlySet<int> headed,
        IReadOnlySet<int> hidden)
    {
        _metrics = metrics;
        Tabs = tabs;
        Groups = groups;
        Boxes = boxes;
        Spans = spans;
        Positions = positions;
        PinnedCount = pinnedCount;
        TabWidth = tabWidth;
        Origin = origin;
        RowWidth = rowWidth;
        WellWidth = wellWidth;
        Overflows = overflows;
        Headed = headed;
        Hidden = hidden;
    }

    public IReadOnlyList<WindowTabs.Tab> Tabs { get; }

    /// <summary>The manual groups' runs (<see cref="WindowTabs.ManualGroups"/>).</summary>
    public IReadOnlyList<TabGroup> Groups { get; }

    /// <summary>The worktree boxes (<see cref="WindowTabs.WorktreeBoxes"/>), pinned ones included.</summary>
    public IReadOnlyList<WorktreeBox> Boxes { get; }

    public TabGroupSpans Spans { get; }

    /// <summary>Every tab's and group header's start, in the spans' space (the well's first tab at 0).</summary>
    public TabGroupSpans.Positions Positions { get; }

    public int PinnedCount { get; }

    /// <summary>The unpinned tabs' shared width.</summary>
    public double TabWidth { get; }

    /// <summary>Where the track's first item starts in the spans' space (after the pinned tabs and their gap).</summary>
    public double Origin { get; }

    /// <summary>The track's content width: its items and gaps, plus a flare's room at each end.</summary>
    public double RowWidth { get; }

    /// <summary>The pinned well's width (0 without pinned tabs).</summary>
    public double WellWidth { get; }

    /// <summary>The track's content is wider than the room it was given: it scrolls.</summary>
    public bool Overflows { get; }

    /// <summary>The first tab of each worktree box drawn in the track: it carries the box's head before it.</summary>
    public IReadOnlySet<int> Headed { get; }

    /// <summary>The tabs of collapsed groups: no element shows them.</summary>
    public IReadOnlySet<int> Hidden { get; }

    /// <summary>The popped-out archived tab's index (always the last tab), or null.</summary>
    public int? Popped => Tabs.Count > 0 && Tabs[^1].Archived ? Tabs.Count - 1 : null;

    /// <summary>
    /// Lays out <paramref name="model"/>'s tabs for a track <paramref name="available"/> epx wide (may be 0 or less in a
    /// narrow window: the tabs then take their minimum width and the track overflows).
    /// </summary>
    /// <param name="chipWidth">A group chip's width (its name, and its count while collapsed).</param>
    public static TabTrackLayout Compute(
        WindowTabs model, double available, TabMetrics metrics, Func<TabGroup, double> chipWidth)
    {
        // A snapshot: WindowTabs.Tabs is its live list, which the next Apply changes before the next layout pass.
        IReadOnlyList<WindowTabs.Tab> tabs = model.Tabs.ToList();
        var groups = model.ManualGroups;
        var boxes = model.WorktreeBoxes;
        int pinned = model.PinnedCount;

        var hidden = new HashSet<int>();
        foreach (TabGroup group in groups.Where(group => group.Group.Collapsed))
        {
            for (int index = group.First; index <= group.Last; index++)
                hidden.Add(index);
        }

        var headed = boxes.Where(box => !tabs[box.First].Pinned && !hidden.Contains(box.First))
            .Select(box => box.First).ToHashSet();
        int shown = Enumerable.Range(0, tabs.Count)
            .Count(index => !tabs[index].Pinned && !tabs[index].Archived && !hidden.Contains(index));
        double chips = groups.Sum(chipWidth);
        int items = shown + groups.Count;
        double gaps = metrics.Gap * Math.Max(items - 1, 0) + 2 * metrics.Flare;
        double heads = headed.Count * metrics.HeadWidth;
        double tabWidth = Math.Clamp(
            Math.Floor((available - gaps - chips - heads) / Math.Max(shown, 1)), metrics.MinWidth, metrics.MaxWidth);

        double Extent(int index) =>
            tabs[index].Archived ? 0
            : tabs[index].Pinned ? metrics.PinnedWidth
            : tabWidth + (headed.Contains(index) ? metrics.HeadWidth : 0);

        var spans = new TabGroupSpans(tabs, groups, boxes, tabWidth, metrics.Gap, chipWidth, Extent);
        var positions = spans.PositionsFor(Enumerable.Range(0, tabs.Count).ToList(), null, null);
        double wellWidth = pinned > 0 ? positions.Tabs[pinned - 1] + metrics.PinnedWidth : 0;
        double origin = pinned > 0 ? wellWidth + metrics.Gap : 0;
        double rowWidth = items == 0 ? 0 : shown * tabWidth + chips + heads + gaps;
        return new TabTrackLayout(
            metrics, tabs, groups, boxes, spans, positions, pinned, tabWidth, origin, rowWidth, wellWidth,
            items > 0 && rowWidth > available, headed, hidden);
    }

    /// <summary>This layout with its tabs and headers at <paramref name="positions"/> (a drag's target,
    /// <see cref="TabGroupSpans.PositionsFor"/> over the same spans): the boxes, group extents and elements follow.</summary>
    public TabTrackLayout WithPositions(TabGroupSpans.Positions positions) => new(
        _metrics, Tabs, Groups, Boxes, Spans, positions, PinnedCount, TabWidth, Origin, RowWidth, WellWidth, Overflows,
        Headed, Hidden);

    /// <summary>A spans-space position from a track content position (<see cref="ContentX"/>'s inverse).</summary>
    public double SpansX(double contentX) => contentX - _metrics.Flare + Origin;

    /// <summary>The tab at <paramref name="index"/> sits in the track (not pinned, not popped out, not collapsed).</summary>
    public bool InTrack(int index) =>
        index >= 0 && index < Tabs.Count && !Tabs[index].Pinned && !Tabs[index].Archived && !Hidden.Contains(index);

    /// <summary>A spans-space position along the track's content (which starts with a flare's room).</summary>
    public double ContentX(double position) => position - Origin + _metrics.Flare;

    /// <summary>Where the tab element at <paramref name="index"/> starts: in the track's content, or in the well; past
    /// its box's head when it carries one.</summary>
    public double TabX(int index)
    {
        double position = Positions.Tabs.GetValueOrDefault(index);
        if (index < PinnedCount)
            return position;
        return ContentX(position) + (Headed.Contains(index) ? _metrics.HeadWidth : 0);
    }

    /// <summary>The tab element's width at <paramref name="index"/>.</summary>
    public double TabElementWidth(int index) =>
        Tabs[index].Archived ? _metrics.ArchivedWidth
        : Tabs[index].Pinned ? _metrics.PinnedWidth
        : TabWidth;

    /// <summary>The box's span (its head included) in the track's content or the well, or null while it is hidden.</summary>
    public (double Start, double End)? BoxSpan(WorktreeBox box)
    {
        if (Spans.BoxSpan(box, Positions) is not { } span)
            return null;
        return box.First < PinnedCount ? span : (ContentX(span.Start), ContentX(span.End));
    }

    /// <summary>A group's extent in the track's content: from its chip's start to its last tab's end (the chip's end
    /// when collapsed).</summary>
    public (double Start, double End)? GroupExtent(TabGroup group)
    {
        if (!Positions.Headers.TryGetValue(group.Id, out double start) || !Positions.Ends.TryGetValue(group.Id, out double end))
            return null;
        return (ContentX(start), ContentX(end));
    }
}
