// Key feature test for manual tab groups: after the tabs are put in order, a group never splits a worktree box, an
// ungrouped tab joining a grouped box takes the box's group, and pinned tabs lose their group; a drop between two tabs
// of a group joins it, and a dragged box always moves whole. Ported from TabArrangementTests.swift at 6fa6d40.
namespace Histq.Core.Tests;

using Entry = TabArrangement.Entry;
using Segment = TabArrangement.Segment;
using Unit = TabArrangement.Unit;

public sealed class TabArrangementTests
{
    // A worktree box whose tabs sit apart gathers whole into the group of its first grouped tab.
    [Fact]
    public void GroupNeverSplitsBox()
    {
        Guid g = Guid.NewGuid(), h = Guid.NewGuid();
        var p1 = new Entry(Guid.NewGuid(), Group: g);
        var w1 = new Entry(Guid.NewGuid(), Repo: "r", Group: g);
        var q = new Entry(Guid.NewGuid());
        var w2 = new Entry(Guid.NewGuid(), Repo: "r", Group: h);
        var p2 = new Entry(Guid.NewGuid(), Group: h);
        var result = TabArrangement.Normalized([p1, w1, q, w2, p2]);
        Assert.Equal(
            [
                new Segment.Group(g, [new Segment.Tab(p1.Id), new Segment.Box("r", [w1.Id, w2.Id])]),
                new Segment.Tab(q.Id),
                new Segment.Group(h, [new Segment.Tab(p2.Id)]),
            ],
            TabArrangement.Segments(result.Tabs));
        Assert.True(result.Groups.SetEquals([g, h]));
    }

    // An ungrouped tab before a grouped box joins the box's group, which survives.
    [Fact]
    public void UngroupedTabJoinsBoxGroup()
    {
        var g = Guid.NewGuid();
        var w0 = new Entry(Guid.NewGuid(), Repo: "r");
        var w1 = new Entry(Guid.NewGuid(), Repo: "r", Group: g);
        var w2 = new Entry(Guid.NewGuid(), Repo: "r", Group: g);
        var result = TabArrangement.Normalized([w0, w1, w2]);
        Assert.Equal(
            [new Segment.Group(g, [new Segment.Box("r", [w0.Id, w1.Id, w2.Id])])],
            TabArrangement.Segments(result.Tabs));
        Assert.True(result.Groups.SetEquals([g]));
    }

    // A pinned tab pins its whole box, loses its group and comes first.
    [Fact]
    public void PinnedTabLosesGroup()
    {
        var g = Guid.NewGuid();
        var t = new Entry(Guid.NewGuid());
        var w1 = new Entry(Guid.NewGuid(), Repo: "r", Group: g);
        var w2 = new Entry(Guid.NewGuid(), Repo: "r", Group: g, Pinned: true);
        var result = TabArrangement.Normalized([t, w1, w2]);
        Assert.Equal([w1.Id, w2.Id, t.Id], result.Tabs.Select(entry => entry.Id));
        Assert.Equal([true, true, false], result.Tabs.Select(entry => entry.Pinned));
        Assert.All(result.Tabs, entry => Assert.Null(entry.Group));
        Assert.Empty(result.Groups);
        Assert.Equal(
            [new Segment.Box("r", [w1.Id, w2.Id]), new Segment.Tab(t.Id)],
            TabArrangement.Segments(result.Tabs));
    }

    // A tab dropped between two tabs of a group joins it.
    [Fact]
    public void DropBetweenGroupTabsJoins()
    {
        var g = Guid.NewGuid();
        var t = new Entry(Guid.NewGuid());
        var a = new Entry(Guid.NewGuid(), Group: g);
        var b = new Entry(Guid.NewGuid(), Group: g);
        Entry[] tabs = [t, a, b];
        // Without t, a and b sit at 0 and 1: place 1 is between them.
        Assert.Contains(1, TabArrangement.Destinations(new Unit.Tab(t.Id), g, tabs));
        Assert.DoesNotContain(1, TabArrangement.Destinations(new Unit.Tab(t.Id), null, tabs));
        var result = TabArrangement.Move(new Unit.Tab(t.Id), 1, g, tabs);
        Assert.Equal(
            [new Segment.Group(g, [new Segment.Tab(a.Id), new Segment.Tab(t.Id), new Segment.Tab(b.Id)])],
            TabArrangement.Segments(result.Tabs));
        Assert.True(result.Groups.SetEquals([g]));
    }

    // A dragged worktree box moves whole to every allowed place, in or out of a group.
    [Fact]
    public void BoxMovesWhole()
    {
        var g = Guid.NewGuid();
        var p = new Entry(Guid.NewGuid(), Pinned: true);
        var w1 = new Entry(Guid.NewGuid(), Repo: "r");
        var w2 = new Entry(Guid.NewGuid(), Repo: "r");
        var a = new Entry(Guid.NewGuid(), Group: g);
        var x = new Entry(Guid.NewGuid(), Repo: "s", Group: g);
        var y = new Entry(Guid.NewGuid(), Repo: "s", Group: g);
        var q = new Entry(Guid.NewGuid());
        var z = new Entry(Guid.NewGuid(), Repo: "r", Archived: true);
        var tabs = TabArrangement.Normalized([p, w1, w2, a, x, y, q, z]).Tabs;
        foreach (var target in new Guid?[] { g, null })
        {
            var places = TabArrangement.Destinations(new Unit.Box("r"), target, tabs);
            // Without the box: p, a, x, y, q, z. Never 3 (between x and y, the box of "s").
            Assert.Equal(target is null ? [1, 4, 5] : [1, 2, 4], places);
            foreach (var place in places)
            {
                var result = TabArrangement.Move(new Unit.Box("r"), place, target, tabs);
                var ids = result.Tabs.Select(entry => entry.Id).ToList();
                Assert.Equal(place, ids.IndexOf(w1.Id));
                Assert.Equal(place + 1, ids.IndexOf(w2.Id));
                Assert.Equal(target, result.Tabs[place].Group);
                Assert.Equal(target, result.Tabs[place + 1].Group);
                Assert.Equal(z.Id, ids[^1]);
            }
        }
    }
}
