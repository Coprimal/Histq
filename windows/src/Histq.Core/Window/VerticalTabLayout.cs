namespace Histq.Core;

/// <summary>
/// Where the vertical tabs' list puts its rows (design header-and-tab-row.md §4, ported from VerticalTabList's rows,
/// App/Window/VerticalTabsPanel.swift at 6fa6d40): one <see cref="TabGroupSpans"/> over every tab by its real index,
/// each manual group's header row before its first row, the items <see cref="Metrics.Gap"/> apart. The pinned tabs (the
/// grid above the list) and the popped-out archived tab (above the footer) take no height; the pinned tabs' gaps are
/// taken off every position (<see cref="Origin"/>, as the Mac's <c>base</c>), so the first item stands at 0. A worktree
/// box in the list starts with its head line (a Windows addition: the branch glyph and the repo's folder name), part of
/// its first row's extent, so the box's span covers it. A collapsed group is its header alone: its rows and boxes are
/// not shown. Positions are along the list, from its first item's top; the panel adds its own padding. A drag draws the
/// list with its unit at its target through <see cref="WithPositions"/> (as TabTrackLayout.WithPositions for the strip).
/// </summary>
public sealed class VerticalTabLayout
{
    /// <param name="RowHeight">A tab row's height.</param>
    /// <param name="Gap">Between two items (rows, headers).</param>
    /// <param name="HeaderHeight">A manual group's header row.</param>
    /// <param name="HeadHeight">A worktree box's head line, above its first row.</param>
    public sealed record Metrics(double RowHeight, double Gap, double HeaderHeight, double HeadHeight);

    private readonly IReadOnlyList<WindowTabs.Tab> tabs;
    private readonly IReadOnlyList<TabGroup> groups;
    private readonly IReadOnlyList<WorktreeBox> listBoxes;
    private readonly Metrics metrics;

    private VerticalTabLayout(
        IReadOnlyList<WindowTabs.Tab> tabs, IReadOnlyList<TabGroup> groups, IReadOnlyList<WorktreeBox> listBoxes,
        Metrics metrics, TabGroupSpans spans, TabGroupSpans.Positions positions, double origin)
    {
        this.tabs = tabs;
        this.groups = groups;
        this.listBoxes = listBoxes;
        this.metrics = metrics;
        Spans = spans;
        Positions = positions;
        Origin = origin;
        Place();
    }

    /// <summary>The spans every position comes from (a drag's <see cref="TabGroupSpans.DragTarget"/> runs on them).</summary>
    public TabGroupSpans Spans { get; }

    /// <summary>The tabs' and headers' positions in the spans' space, as this layout places them (at rest, or a drag's
    /// target).</summary>
    public TabGroupSpans.Positions Positions { get; }

    /// <summary>Where the list's first item stands in the spans' space (the pinned tabs' gaps): a list position plus
    /// this is a spans position.</summary>
    public double Origin { get; }

    /// <summary>Each shown row's top by tab index (past its box's head line when it is its box's first row). Pinned
    /// tabs, the popped-out archived tab and a collapsed group's tabs have none.</summary>
    public IReadOnlyDictionary<int, double> Rows { get; private set; } = new Dictionary<int, double>();

    /// <summary>Each manual group's header row top (none for a group a drag leaves empty).</summary>
    public IReadOnlyDictionary<Guid, double> Headers { get; private set; } = new Dictionary<Guid, double>();

    /// <summary>Each expanded group's color rail: from a gap under its header to a gap short of its last row's end.</summary>
    public IReadOnlyDictionary<Guid, (double Start, double End)> Rails { get; private set; } =
        new Dictionary<Guid, (double Start, double End)>();

    /// <summary>Each shown worktree box's head line top, by its repository key.</summary>
    public IReadOnlyDictionary<string, double> Heads { get; private set; } = new Dictionary<string, double>(StringComparer.Ordinal);

    /// <summary>Each shown worktree box's span by its repository key: from its head line's top to its last row's end.</summary>
    public IReadOnlyDictionary<string, (double Start, double End)> Boxes { get; private set; } =
        new Dictionary<string, (double Start, double End)>(StringComparer.Ordinal);

    /// <summary>From the first item's top to the last one's end; 0 with no item.</summary>
    public double Height { get; private set; }

    /// <param name="tabs">The window's tabs in order (pinned first, the popped-out archived tab last).</param>
    /// <param name="groups">The manual groups' runs.</param>
    /// <param name="boxes">The worktree boxes of the list: the pinned ones (the grid's) left out.</param>
    public static VerticalTabLayout Compute(
        IReadOnlyList<WindowTabs.Tab> tabs, IReadOnlyList<TabGroup> groups, IReadOnlyList<WorktreeBox> boxes,
        Metrics metrics)
    {
        var listBoxes = boxes.Where(box => box.First < tabs.Count && !tabs[box.First].Pinned).ToList();
        var boxStarts = listBoxes.Select(box => box.First).ToHashSet();

        double Extent(int index) =>
            tabs[index].Pinned || tabs[index].Archived ? 0
            : metrics.RowHeight + (boxStarts.Contains(index) ? metrics.HeadHeight : 0);

        var spans = new TabGroupSpans(tabs, groups, listBoxes, metrics.RowHeight, metrics.Gap, _ => metrics.HeaderHeight,
            Extent);
        var positions = spans.PositionsFor(Enumerable.Range(0, tabs.Count).ToList(), null, null);

        // The pinned tabs stand first and take no height, but each still counts its gap.
        var origin = tabs.TakeWhile(tab => tab.Pinned).Count() * metrics.Gap;
        return new VerticalTabLayout(tabs, groups, listBoxes, metrics, spans, positions, origin);
    }

    /// <summary>This layout with its tabs and headers at <paramref name="positions"/> (a drag's target,
    /// <see cref="TabGroupSpans.PositionsFor"/> over <see cref="Spans"/>): the rows, headers, rails, boxes and heads
    /// follow.</summary>
    public VerticalTabLayout WithPositions(TabGroupSpans.Positions positions) =>
        new(tabs, groups, listBoxes, metrics, Spans, positions, Origin);

    /// <summary>
    /// Places every item from <see cref="Positions"/>. A box's head line stands at its span's start and its rows follow
    /// it in their order there, a gap apart: the head's extent belongs to the box's first tab by index, which a drag
    /// inside the box may move down, but the head always heads the box.
    /// </summary>
    private void Place()
    {
        var rows = new Dictionary<int, double>();
        var heads = new Dictionary<string, double>(StringComparer.Ordinal);
        var shownBoxes = new Dictionary<string, (double Start, double End)>(StringComparer.Ordinal);
        var boxed = new HashSet<int>();
        var end = 0.0;

        foreach (var box in listBoxes)
        {
            if (Spans.BoxSpan(box, Positions) is not { } span)
            {
                continue;
            }

            shownBoxes[box.Key] = (span.Start - Origin, span.End - Origin);
            heads[box.Key] = span.Start - Origin;
            var top = span.Start - Origin + metrics.HeadHeight;
            foreach (var index in Enumerable.Range(box.First, box.Last - box.First + 1)
                         .Where(index => Positions.Tabs.ContainsKey(index) && !tabs[index].Archived)
                         .OrderBy(index => Positions.Tabs[index]))
            {
                rows[index] = top;
                boxed.Add(index);
                end = Math.Max(end, top + metrics.RowHeight);
                top += metrics.RowHeight + metrics.Gap;
            }
        }

        foreach (var item in Spans.Items)
        {
            if (item is not TabGroupSpans.Item.Tab tab || tabs[tab.Index].Pinned || tabs[tab.Index].Archived
                || boxed.Contains(tab.Index) || !Positions.Tabs.TryGetValue(tab.Index, out var position))
            {
                continue;
            }

            var top = position - Origin;
            rows[tab.Index] = top;
            end = Math.Max(end, top + metrics.RowHeight);
        }

        var headers = new Dictionary<Guid, double>();
        var rails = new Dictionary<Guid, (double Start, double End)>();
        foreach (var group in groups)
        {
            if (!Positions.Headers.TryGetValue(group.Id, out var header))
            {
                continue;
            }

            var top = header - Origin;
            headers[group.Id] = top;
            end = Math.Max(end, top + metrics.HeaderHeight);
            if (!group.Group.Collapsed && Positions.Ends.TryGetValue(group.Id, out var groupEnd))
            {
                rails[group.Id] = (top + metrics.HeaderHeight + metrics.Gap, groupEnd - Origin - metrics.Gap);
            }
        }

        Rows = rows;
        Headers = headers;
        Rails = rails;
        Heads = heads;
        Boxes = shownBoxes;
        Height = end;
    }
}
