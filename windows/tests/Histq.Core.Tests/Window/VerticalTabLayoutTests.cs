// The vertical tabs' list placement (Shell/Tabs/VerticalTabsPanel on Windows): the pinned tabs (the grid's) and the
// popped-out archived tab take no height and the first item stands at 0; each group's header row comes before its rows,
// with a rail from under it to a gap short of its last row's end; a worktree box in the list starts with its head line,
// which pushes its first row down; a collapsed group is its header alone, its rows and boxes not shown. A drag draws the
// list with its unit at its target (WithPositions over TabGroupSpans.DragTarget's positions).
namespace Histq.Core.Tests;

public sealed class VerticalTabLayoutTests
{
    private const double Row = 28;
    private const double Gap = 6;
    private const double Header = 22;
    private const double Head = 16;

    private static readonly VerticalTabLayout.Metrics Metrics = new(Row, Gap, Header, Head);

    private static readonly Guid Scratch = Guid.Parse("5E5510A0-0000-4000-8000-000000000001");
    private static readonly Guid Unnamed = Guid.Parse("5E5510A0-0000-4000-8000-000000000002");
    private static readonly Guid Docs = Guid.Parse("5E5510A0-0000-4000-8000-000000000003");

    /// <summary>The QA tab-states window (Fixtures/qa-session-tab-states.json): pinned docs, notes and the lib worktree
    /// pair; Scratch (scratch); the collapsed unnamed group (the tmp pair); Docs (the api worktree pair, readme); the
    /// histq worktree pair; t1-t6; the popped-out archived web tab.</summary>
    private static (WindowTabs.Tab[] Tabs, TabGroup[] Groups, WorktreeBox[] Boxes) QaWindow()
    {
        WindowTabs.Tab[] tabs =
        [
            new("/r/docs", Pinned: true),
            new("/r/notes", Pinned: true),
            new("/r/lib", RepoKey: "/r/lib/.git", Pinned: true),
            new("/r/lib-w2", RepoKey: "/r/lib/.git", Pinned: true),
            new("/r/scratch", GroupId: Scratch),
            new("/r/tmp1", RepoKey: "/r/tmp/.git", GroupId: Unnamed),
            new("/r/tmp2", RepoKey: "/r/tmp/.git", GroupId: Unnamed),
            new("/r/api", RepoKey: "/r/api/.git", GroupId: Docs),
            new("/r/api-w2", RepoKey: "/r/api/.git", GroupId: Docs),
            new("/r/readme", GroupId: Docs),
            new("/r/histq", RepoKey: "/r/histq/.git"),
            new("/r/histq-w3", RepoKey: "/r/histq/.git"),
            new("/r/t1"),
            new("/r/t2"),
            new("/r/web", Archived: true),
        ];
        TabGroup[] groups =
        [
            new(new ManualTabGroup(Scratch, "Scratch", 0, Collapsed: false), 4, 4),
            new(new ManualTabGroup(Unnamed, null, 7, Collapsed: true), 5, 6),
            new(new ManualTabGroup(Docs, "Docs", 1, Collapsed: false), 7, 9),
        ];
        WorktreeBox[] boxes =
        [
            new("/r/lib/.git", 2, 3),
            new("/r/tmp/.git", 5, 6),
            new("/r/api/.git", 7, 8),
            new("/r/histq/.git", 10, 11),
        ];
        return (tabs, groups, boxes);
    }

    [Fact]
    public void PinnedAndArchivedTabsTakeNoHeightAndTheListStartsAtZero()
    {
        var (tabs, groups, boxes) = QaWindow();

        var layout = VerticalTabLayout.Compute(tabs, groups, boxes, Metrics);

        Assert.Equal(0, layout.Headers[Scratch]);
        Assert.Equal(Header + Gap, layout.Rows[4]);
        Assert.DoesNotContain(0, layout.Rows.Keys);
        Assert.DoesNotContain(3, layout.Rows.Keys);
        Assert.DoesNotContain(14, layout.Rows.Keys);
        // The pinned lib box is the grid's: no head line in the list.
        Assert.False(layout.Heads.ContainsKey("/r/lib/.git"));
    }

    [Fact]
    public void CollapsedGroupIsItsHeaderAloneWithNoRail()
    {
        var (tabs, groups, boxes) = QaWindow();

        var layout = VerticalTabLayout.Compute(tabs, groups, boxes, Metrics);

        double unnamed = Header + Gap + Row + Gap;
        Assert.Equal(unnamed, layout.Headers[Unnamed]);
        Assert.DoesNotContain(5, layout.Rows.Keys);
        Assert.DoesNotContain(6, layout.Rows.Keys);
        Assert.False(layout.Heads.ContainsKey("/r/tmp/.git"));
        Assert.False(layout.Rails.ContainsKey(Unnamed));
        // The next group's header stands a gap after the collapsed header.
        Assert.Equal(unnamed + Header + Gap, layout.Headers[Docs]);
    }

    [Fact]
    public void BoxHeadLinePushesItsFirstRowDownAndTheBoxSpansIt()
    {
        var (tabs, groups, boxes) = QaWindow();

        var layout = VerticalTabLayout.Compute(tabs, groups, boxes, Metrics);

        double box = layout.Headers[Docs] + Header + Gap;
        Assert.Equal(box, layout.Heads["/r/api/.git"]);
        Assert.Equal(box + Head, layout.Rows[7]);
        Assert.Equal(box + Head + Row + Gap, layout.Rows[8]);
        Assert.Equal((box, layout.Rows[8] + Row), layout.Boxes["/r/api/.git"]);
        Assert.Equal(layout.Rows[8] + Row + Gap, layout.Rows[9]);
    }

    [Fact]
    public void RailRunsFromUnderTheHeaderToAGapShortOfTheLastRow()
    {
        var (tabs, groups, boxes) = QaWindow();

        var layout = VerticalTabLayout.Compute(tabs, groups, boxes, Metrics);

        Assert.Equal((Header + Gap, Header + Gap + Row - Gap), layout.Rails[Scratch]);
        Assert.Equal(
            (layout.Headers[Docs] + Header + Gap, layout.Rows[9] + Row - Gap), layout.Rails[Docs]);
    }

    [Fact]
    public void HeightEndsAtTheLastRow()
    {
        var (tabs, groups, boxes) = QaWindow();

        var layout = VerticalTabLayout.Compute(tabs, groups, boxes, Metrics);

        Assert.Equal(layout.Rows[10] - Head, layout.Heads["/r/histq/.git"]);
        Assert.Equal(layout.Rows[13] + Row, layout.Height);
    }

    [Fact]
    public void NoItemsHasNoHeight()
    {
        WindowTabs.Tab[] tabs = [new("/r/docs", Pinned: true), new("/r/web", Archived: true)];

        var layout = VerticalTabLayout.Compute(tabs, [], [], Metrics);

        Assert.Empty(layout.Rows);
        Assert.Equal(0, layout.Height);
    }
    private static TabArrangement.Entry[] Entries(WindowTabs.Tab[] tabs) =>
        tabs.Select(tab => new TabArrangement.Entry(tab.Id, tab.RepoKey, tab.GroupId, tab.Pinned, tab.Archived)).ToArray();

    /// <summary>The layout with <paramref name="unit"/> dragged <paramref name="translation"/> down the list, at its
    /// target, and the target DragTarget gave.</summary>
    private static (VerticalTabLayout Target, int Index, Guid? Group) Dragged(
        VerticalTabLayout layout, WindowTabs.Tab[] tabs, TabArrangement.Unit unit, double translation)
    {
        var entries = Entries(tabs);
        var range = TabGroupSpans.RangeOf(unit, entries)!.Value;
        var (index, group) = layout.Spans.DragTarget(unit, translation, layout.Spans.GroupOf(unit, entries), entries);
        var positions = layout.Spans.PositionsFor(TabGroupSpans.Moved(tabs.Length, range, index), range, group);
        return (layout.WithPositions(positions), index, group);
    }

    [Fact]
    public void WithTheRestPositionsPlacesEverythingAsAtRest()
    {
        var (tabs, groups, boxes) = QaWindow();
        var layout = VerticalTabLayout.Compute(tabs, groups, boxes, Metrics);

        var same = layout.WithPositions(layout.Positions);

        Assert.Equal(layout.Rows, same.Rows);
        Assert.Equal(layout.Headers, same.Headers);
        Assert.Equal(layout.Rails, same.Rails);
        Assert.Equal(layout.Heads, same.Heads);
        Assert.Equal(layout.Boxes, same.Boxes);
        Assert.Equal(layout.Height, same.Height);
        // The four pinned tabs' gaps.
        Assert.Equal(4 * Gap, layout.Origin);
    }

    [Fact]
    public void RowDraggedOneRowDownSwapsWithTheNextRow()
    {
        var (tabs, groups, boxes) = QaWindow();
        var layout = VerticalTabLayout.Compute(tabs, groups, boxes, Metrics);

        var (target, index, group) = Dragged(layout, tabs, new TabArrangement.Unit.Tab(tabs[12].Id), Row + Gap);

        Assert.Equal(13, index);
        Assert.Null(group);
        Assert.Equal(layout.Rows[13], target.Rows[12]);
        Assert.Equal(layout.Rows[12], target.Rows[13]);
        Assert.Equal(layout.Height, target.Height);
    }

    [Fact]
    public void BoxFirstRowMovedDownKeepsTheHeadLineOnTop()
    {
        var (tabs, groups, boxes) = QaWindow();
        var layout = VerticalTabLayout.Compute(tabs, groups, boxes, Metrics);

        var (target, index, group) = Dragged(layout, tabs, new TabArrangement.Unit.Tab(tabs[7].Id), Row + Gap);

        Assert.Equal(8, index);
        Assert.Equal(Docs, group);
        Assert.Equal(layout.Heads["/r/api/.git"], target.Heads["/r/api/.git"]);
        Assert.Equal(layout.Rows[7], target.Rows[8]);
        Assert.Equal(layout.Rows[8], target.Rows[7]);
        Assert.Equal(layout.Boxes["/r/api/.git"], target.Boxes["/r/api/.git"]);
    }

    [Fact]
    public void GroupDraggedByItsHeaderBelowABoxSwapsPlacesWithIt()
    {
        var (tabs, groups, boxes) = QaWindow();
        var layout = VerticalTabLayout.Compute(tabs, groups, boxes, Metrics);
        var histq = layout.Boxes["/r/histq/.git"];

        var (target, index, group) = Dragged(
            layout, tabs, new TabArrangement.Unit.Group(Docs), histq.End - histq.Start + Gap);

        Assert.Equal(9, index);
        Assert.Equal(Docs, group);
        Assert.Equal(layout.Headers[Docs], target.Heads["/r/histq/.git"]);
        Assert.Equal(histq.End - histq.Start + Gap, target.Headers[Docs] - layout.Headers[Docs]);
        Assert.Equal(layout.Rows[12], target.Rows[12]);
    }

    [Fact]
    public void RowDraggedIntoAGroupJoinsItAndItsRailGrows()
    {
        var (tabs, groups, boxes) = QaWindow();
        var layout = VerticalTabLayout.Compute(tabs, groups, boxes, Metrics);

        // t1's top onto the middle of readme, Docs' last row.
        var (target, _, group) = Dragged(
            layout, tabs, new TabArrangement.Unit.Tab(tabs[12].Id), layout.Rows[9] + Row / 2 - layout.Rows[12]);

        Assert.Equal(Docs, group);
        var rail = target.Rails[Docs];
        Assert.Equal(layout.Rails[Docs].End + Row + Gap, rail.End);
        Assert.InRange(target.Rows[12], rail.Start, rail.End);
    }

    [Fact]
    public void RowDraggedOutOfItsGroupLeavesItAndItsRailShrinks()
    {
        var (tabs, groups, boxes) = QaWindow();
        var layout = VerticalTabLayout.Compute(tabs, groups, boxes, Metrics);

        // readme, Docs' last row, below the histq box.
        var (target, _, group) = Dragged(
            layout, tabs, new TabArrangement.Unit.Tab(tabs[9].Id), layout.Rows[11] + Row + Gap - layout.Rows[9]);

        Assert.Null(group);
        Assert.Equal(layout.Rails[Docs].End - Row - Gap, target.Rails[Docs].End);
        Assert.True(target.Rows[9] > target.Rows[11]);
    }
}
