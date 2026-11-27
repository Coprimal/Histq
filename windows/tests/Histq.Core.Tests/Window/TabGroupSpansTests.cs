// The tab row's placement math the Windows tab strip relies on (Shell/Tabs/TabTrackLayout): one TabGroupSpans over every
// tab by its real index places the pinned tabs first, then the first unpinned item right after them a gap on (the
// track's origin), each group's header before its first tab; a collapsed group is its header alone (its tabs take no
// room and its end is the header's end); a worktree box spans its tabs (its first tab's extent included, where the
// strip puts the box's head) and is not drawn while its group is collapsed. Ported from TabGroupLayout
// (TabGroups.swift) at 6fa6d40, which has no tests of its own.
namespace Histq.Core.Tests;

public sealed class TabGroupSpansTests
{
    private const double Gap = 5;
    private const double Pinned = 44;
    private const double Tab = 100;
    private const double Head = 20;

    private static readonly Guid Docs = Guid.Parse("5E5510A0-0000-4000-8000-000000000003");
    private static readonly Guid Hidden = Guid.Parse("5E5510A0-0000-4000-8000-000000000002");

    /// <summary>Two pinned tabs, a group of a worktree box (its first tab carries a head) and a plain tab, then the
    /// popped-out archived tab with no room.</summary>
    private static (TabGroupSpans Spans, TabGroup Group, WorktreeBox Box) Row()
    {
        WindowTabs.Tab[] tabs =
        [
            new("/r/docs", Pinned: true),
            new("/r/notes", Pinned: true),
            new("/r/api", RepoKey: "/r/api/.git", GroupId: Docs),
            new("/r/api-w2", RepoKey: "/r/api/.git", GroupId: Docs),
            new("/r/t1"),
            new("/r/web", Archived: true),
        ];
        var group = new TabGroup(new ManualTabGroup(Docs, "Docs", 1, Collapsed: false), 2, 3);
        var box = new WorktreeBox("/r/api/.git", 2, 3);
        double Extent(int index) => index switch
        {
            0 or 1 => Pinned,
            2 => Tab + Head,
            5 => 0,
            _ => Tab,
        };

        return (new TabGroupSpans(tabs, [group], [box], Tab, Gap, _ => 30, Extent), group, box);
    }

    [Fact]
    public void PinnedTabsComeFirstAndTheTrackStartsAGapAfterThem()
    {
        var (spans, group, _) = Row();

        var positions = spans.PositionsFor(Enumerable.Range(0, 6).ToList(), null, null);

        Assert.Equal(0, positions.Tabs[0]);
        Assert.Equal(Pinned + Gap, positions.Tabs[1]);
        // The track's origin: the last pinned tab's end plus a gap, where the group's header stands.
        Assert.Equal(positions.Tabs[1] + Pinned + Gap, positions.Headers[group.Id]);
        Assert.Equal(positions.Headers[group.Id] + 30 + Gap, positions.Tabs[2]);
        // The box's first tab carries the head in its extent; the next tab stands after both.
        Assert.Equal(positions.Tabs[2] + Tab + Head + Gap, positions.Tabs[3]);
        Assert.Equal(positions.Tabs[3] + Tab, positions.Ends[group.Id]);
        Assert.Equal(positions.Ends[group.Id] + Gap, positions.Tabs[4]);
    }

    [Fact]
    public void GroupSpanRunsFromItsHeaderToItsLastTab()
    {
        var (spans, group, _) = Row();

        var positions = spans.PositionsFor(Enumerable.Range(0, 6).ToList(), null, null);

        Assert.Equal(30 + Gap + Tab + Head + Gap + Tab, TabGroupSpans.Span(group.Id, positions));
        Assert.Same(group, spans.GroupAt(3));
        Assert.Null(spans.GroupAt(4));
    }

    [Fact]
    public void BoxSpanCoversItsTabsIncludingTheHead()
    {
        var (spans, _, box) = Row();
        var positions = spans.PositionsFor(Enumerable.Range(0, 6).ToList(), null, null);

        var span = spans.BoxSpan(box, positions);

        Assert.Equal((positions.Tabs[2], positions.Tabs[3] + Tab), span);
    }

    [Fact]
    public void CollapsedGroupIsItsHeaderAlone()
    {
        WindowTabs.Tab[] tabs =
        [
            new("/r/tmp1", RepoKey: "/r/tmp/.git", GroupId: Hidden),
            new("/r/tmp2", RepoKey: "/r/tmp/.git", GroupId: Hidden),
            new("/r/t1"),
        ];
        var group = new TabGroup(new ManualTabGroup(Hidden, null, 7, Collapsed: true), 0, 1);
        var box = new WorktreeBox("/r/tmp/.git", 0, 1);
        var spans = new TabGroupSpans(tabs, [group], [box], Tab, Gap, _ => 22);

        var positions = spans.PositionsFor([0, 1, 2], null, null);

        // Only the header and the plain tab are items; the collapsed tabs are not drawn.
        Assert.Equal(2, spans.Items.Count);
        Assert.IsType<TabGroupSpans.Item.Header>(spans.Items[0]);
        Assert.Equal(0, positions.Headers[Hidden]);
        Assert.Equal(22, positions.Ends[Hidden]);
        Assert.Equal(22, TabGroupSpans.Span(Hidden, positions));
        // The next tab stands a gap after the header; the hidden tabs take no room.
        Assert.Equal(22 + Gap, positions.Tabs[2]);
        Assert.Null(spans.BoxSpan(box, positions));
    }

    /// <summary>The QA tab-states row (Fixtures/qa-session-tab-states.json) as the strip lays it out: pinned docs, notes
    /// and the lib worktree pair; Scratch; the collapsed unnamed group; Docs (the api worktree pair, readme); the histq
    /// worktree pair; t1-t6; the popped-out archived web tab.</summary>
    private static (TabGroupSpans Spans, IReadOnlyList<TabArrangement.Entry> Entries) QaRow()
    {
        var scratch = Guid.Parse("5E5510A0-0000-4000-8000-000000000001");
        WindowTabs.Tab[] tabs =
        [
            new("/r/docs", Pinned: true),
            new("/r/notes", Pinned: true),
            new("/r/lib", RepoKey: "/r/lib/.git", Pinned: true),
            new("/r/lib-w2", RepoKey: "/r/lib/.git", Pinned: true),
            new("/r/scratch", GroupId: scratch),
            new("/r/tmp1", GroupId: Hidden),
            new("/r/tmp2", GroupId: Hidden),
            new("/r/api", RepoKey: "/r/api/.git", GroupId: Docs),
            new("/r/api-w2", RepoKey: "/r/api/.git", GroupId: Docs),
            new("/r/readme", GroupId: Docs),
            new("/r/histq", RepoKey: "/r/histq/.git"),
            new("/r/histq-w3", RepoKey: "/r/histq/.git"),
            new("/r/t1"),
            new("/r/t2"),
            new("/r/t3"),
            new("/r/t4"),
            new("/r/t5"),
            new("/r/t6"),
            new("/r/web", Archived: true),
        ];
        TabGroup[] groups =
        [
            new(new ManualTabGroup(scratch, "Scratch", 0, Collapsed: false), 4, 4),
            new(new ManualTabGroup(Hidden, null, 7, Collapsed: true), 5, 6),
            new(new ManualTabGroup(Docs, "Docs", 1, Collapsed: false), 7, 9),
        ];
        WorktreeBox[] boxes = [new("/r/lib/.git", 2, 3), new("/r/api/.git", 7, 8), new("/r/histq/.git", 10, 11)];
        double Extent(int index) => index switch
        {
            <= 3 => Pinned,
            7 or 10 => Tab + Head,
            18 => 0,
            _ => Tab,
        };

        var spans = new TabGroupSpans(tabs, groups, boxes, Tab, Gap, group => group.Group.Name is null ? 22 : 60, Extent);
        var entries = tabs.Select(tab => new TabArrangement.Entry(tab.Id, tab.RepoKey, tab.GroupId, tab.Pinned, tab.Archived))
            .ToList();
        return (spans, entries);
    }

    [Fact]
    public void DraggingTabOverGroupsTabJoinsIt()
    {
        var (spans, entries) = QaRow();
        var rest = spans.PositionsFor(Enumerable.Range(0, entries.Count).ToList(), null, null);
        var t1 = new TabArrangement.Unit.Tab(entries[12].Id);

        // Pressed at t1's centre, released at readme's centre (both tabs are one tab wide, with no head).
        var target = spans.DragTarget(t1, rest.Tabs[9] - rest.Tabs[12], null, entries);

        Assert.Equal(Docs, target.Group);
        Assert.InRange(target.Index, 7, 10);
    }

    [Fact]
    public void JoiningGroupTakesAQuarterTabInsideIt()
    {
        var (spans, entries) = QaRow();
        var rest = spans.PositionsFor(Enumerable.Range(0, entries.Count).ToList(), null, null);
        var t1 = new TabArrangement.Unit.Tab(entries[12].Id);
        // The dragged tab's leading edge (its start + translation - half a gap) against Docs' end without t1: readme's end.
        double Translation(double edge) => edge + Gap / 2 - rest.Tabs[12];
        var docsEnd = rest.Tabs[9] + Tab;

        Assert.Null(spans.DragTarget(t1, Translation(docsEnd - Tab / 4 + 1), null, entries).Group);
        Assert.Equal(Docs, spans.DragTarget(t1, Translation(docsEnd - Tab / 4 - 1), null, entries).Group);
        // Over the histq worktree pair, between Docs and t1: no group.
        Assert.Null(spans.DragTarget(t1, -Tab / 2, null, entries).Group);
    }
}
