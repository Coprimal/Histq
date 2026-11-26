// Key feature tests for GraphLayout: a merge's second parent opens a lane that is freed after the join and reused
// later, pages lay out like one batch, the `graph` fixture stays narrow with its first-parent chain in one color and its
// stashes right above their bases, pinned branches keep the leftmost lanes and no pins changes nothing. Ported from
// GraphLayoutTests.swift at 6fa6d40 (its benchmark, enabled only with HISTQ_BIG_FIXTURE, is not ported: layout speed is
// measured by the spike's fullLoadMs).
namespace Histq.Core.Tests;

public sealed class GraphLayoutTests
{
    private static CancellationToken Token => TestContext.Current.CancellationToken;

    // A merge's second parent opens a lane that is freed at the fork and reused, page by page.
    [Fact]
    public void SecondParentLaneIsFreedAndReused()
    {
        // M2 merges T2; M merges S; S and A fork from F. Children before parents, as --topo-order gives.
        Commit[] commits =
        [
            Make("m2", "m", "t2"), Make("t2", "m"), Make("m", "a", "s"), Make("s", "f"), Make("a", "f"), Make("f", "r"),
            Make("r"),
        ];
        var rows = new GraphLayout().Append(commits, Token);

        Assert.Equal([0, 1, 0, 1, 0, 0, 0], rows.Select(row => row.Lane));
        Assert.Equal([2, 2, 2, 2, 2, 2, 1], rows.Select(row => row.Width));
        var merge = rows[2];
        Assert.DoesNotContain(merge.Top, s => s.From == 1 && s.To == 1); // T2's line ended at M: slot 1 is free.
        // M's second parent reopens slot 1, in S's color.
        Assert.Contains(new GraphSegment(GraphSegmentShape.BendOut, 0, 1, rows[3].Color, false, 2), merge.Bottom);
        Assert.Equal(3, rows[5].Top.First(s => s.Shape == GraphSegmentShape.BendIn).Owner); // S's line to F is S's.
        Assert.Contains(rows[5].Top, s => s.Shape == GraphSegmentShape.BendIn && s.From == 1 && s.To == 0); // S's lane joins at F,
        Assert.Equal([0], rows[5].Bottom.Select(s => s.From)); // and is freed there.
        Assert.NotEqual(rows[3].Color, rows[4].Color); // The opened lane has its own color.
        ExpectConnected(rows);

        foreach (var size in new[] { 1, 3 })
        {
            Assert.Equal(rows, LayOutInPages(new GraphLayout(), commits, size)); // Pages lay out like one batch.
        }
    }

    // Graph fixture: bounded width, main's first-parent chain keeps its lane and color, stashes reach their base.
    [Fact]
    public async Task GraphFixture()
    {
        using var copy = await Fixtures.CopyAsync();
        var repo = copy.Repo("graph");
        var env = await GitInvocation.ReadEnvironmentAsync(null, copy.Base, copy.Runner, repo, ct: Token);
        var head = await copy.GitAsync(["rev-parse", "HEAD"], repo, ct: Token);
        var stashes = await StashWorktreeReader.StashesAsync(copy.Runner, repo, env, Token);
        Assert.Equal(2, stashes.Count);

        var layout = new GraphLayout();
        var rows = new List<GraphRow>(layout.Append([new GraphSyntheticRow(GraphSyntheticRowKind.Wip, "wip", head)]));
        layout.Hang(StashRows(stashes));
        await foreach (var page in LogReader.PagesAsync(copy.Runner, repo, env, pageSize: 4, ct: Token))
        {
            rows.AddRange(layout.Append(page, Token));
        }

        Assert.Empty(layout.Waiting); // Every stash's base came.
        // As the graph shows them: each hung row right above its base commit (after the WIP row).
        for (var offset = 0; offset < layout.Hung.Count; offset++)
        {
            var hung = layout.Hung[offset];
            rows.Insert(1 + hung.Above + offset, hung.Row);
        }

        ExpectConnected(rows);
        int Index(string hash) => rows.FindIndex(row => row.Node.Hash == hash);

        // 4 branches open at once (main, develop, origin/feature, series) plus stash@{1}'s line.
        Assert.True(rows.Max(row => row.Width) <= 5);

        // The develop merge's second parent line joins main again at the fork, after which one lane is left.
        var merge = await copy.GitAsync(["rev-parse", "v1.0^{commit}"], repo, ct: Token);
        var fork = await copy.GitAsync(["merge-base", "v1.0^1", "v1.0^2"], repo, ct: Token);
        var mergeRow = Index(merge);
        Assert.True(mergeRow >= 0);
        Assert.Contains(rows[mergeRow].Bottom, s => s.Shape == GraphSegmentShape.BendOut);
        var forkRow = Index(fork);
        Assert.True(forkRow >= 0);
        Assert.Contains(rows[forkRow].Top, s => s.Shape == GraphSegmentShape.BendIn);
        Assert.All(rows[forkRow].Bottom, s => Assert.True(s.From == rows[forkRow].Lane && s.To == rows[forkRow].Lane));
        Assert.All(rows.Skip(forkRow + 1), row => Assert.Equal(1, row.Width)); // Every other lane is freed at the join.

        var chain = (await copy.GitAsync(["rev-list", "--first-parent", "main"], repo, ct: Token)).Split('\n');
        var chainRows = chain.Select(Index).ToArray();
        Assert.All(chainRows, row => Assert.True(row >= 0));
        Assert.Single(chainRows.Select(row => rows[row].Color).Distinct()); // Main keeps one color
        Assert.Single(chainRows.Select(row => rows[row].Lane).Distinct()); // and one lane.
        Assert.Equal(rows[chainRows[0]].Lane, rows[0].Lane); // WIP sits on HEAD's lane.

        foreach (var stash in stashes)
        {
            var node = GraphNode.Synthetic(new GraphSyntheticRow(GraphSyntheticRowKind.Stash, stash.Hash, stash.Base));
            var row = rows.FindIndex(r => r.Node == node);
            Assert.True(row >= 0);
            var stashBase = Index(stash.Base);
            Assert.True(stashBase >= 0);
            Assert.Equal(stashBase, LineEnd(rows, row)); // The stash hangs from its base
            // and sits right above it.
            Assert.All(rows.Skip(row + 1).Take(stashBase - row - 1), r => Assert.True(r.Node.IsSynthetic));
        }
    }

    // A pinned branch's first-parent chain stays in lane 0 even when other branches come first.
    [Fact]
    public void PinnedChainKeepsLaneZero()
    {
        // O is unrelated and comes first; M2 is a child of the pinned tip F2, so its line bends into lane 0.
        Commit[] commits = [Make("o1", "b"), Make("m2", "f2"), Make("f2", "f1"), Make("f1", "b"), Make("b")];
        Assert.Equal([0, 1, 1, 1, 0], new GraphLayout().Append(commits, Token).Select(row => row.Lane));

        var rows = new GraphLayout(pinned: ["f2"]).Append(commits, Token);
        Assert.Equal([1, 2, 0, 0, 0], rows.Select(row => row.Lane));
        // M2's line joins F2 in lane 0.
        Assert.Contains(rows[2].Top, s => s.Shape == GraphSegmentShape.BendIn && s.From == 2 && s.To == 0);
        Assert.Equal(rows[1].Color, rows[2].Color); // F2 continues M2's color.
        var columnRows = new GraphLayout(pinned: ["f2"], coloring: GraphLayout.Coloring.Column).Append(commits, Token);
        Assert.Equal(rows.Select(row => row.Lane), columnRows.Select(row => row.Lane)); // The coloring never moves a lane.
        // By column, each row takes its column's color.
        Assert.Equal(columnRows.Select(row => row.Lane), columnRows.Select(row => row.Color));
        ExpectConnected(rows);

        foreach (var size in new[] { 1, 2 })
        {
            Assert.Equal(rows, LayOutInPages(new GraphLayout(pinned: ["f2"]), commits, size)); // Pages lay out like one batch.
        }
    }

    // Two pins take lanes 0 and 1, in pin order.
    [Fact]
    public void TwoPinsTakeLanesInOrder()
    {
        Commit[] commits = [Make("y2", "y1"), Make("y1", "b"), Make("x1", "b"), Make("o1", "b"), Make("b")];
        var rows = new GraphLayout(pinned: ["x1", "y2"]).Append(commits, Token);
        Assert.Equal([1, 1, 0, 2, 0], rows.Select(row => row.Lane));
        ExpectConnected(rows);

        // A pinned tip on a lower pin's chain stays there; its own lane is left empty.
        var overlapping = new GraphLayout(pinned: ["a2", "a1"]);
        Assert.Equal([0, 0, 0], overlapping.Append([Make("a2", "a1"), Make("a1", "b"), Make("b")], Token).Select(row => row.Lane));
    }

    // Graph fixture: no pins lays out exactly as before.
    [Fact]
    public async Task NoPinsIsUnchanged()
    {
        using var copy = await Fixtures.CopyAsync();
        var repo = copy.Repo("graph");
        var env = await GitInvocation.ReadEnvironmentAsync(null, copy.Base, copy.Runner, repo, ct: Token);
        var head = await copy.GitAsync(["rev-parse", "HEAD"], repo, ct: Token);
        var stashes = await StashWorktreeReader.StashesAsync(copy.Runner, repo, env, Token);
        var pages = new List<IReadOnlyList<Commit>>();
        await foreach (var page in LogReader.PagesAsync(copy.Runner, repo, env, pageSize: 4, ct: Token))
        {
            pages.Add(page);
        }

        var results = new List<(List<GraphRow> Rows, IReadOnlyList<GraphHungRow> Hung)>();
        foreach (var layout in new[] { new GraphLayout(), new GraphLayout(pinned: []) })
        {
            var rows = new List<GraphRow>(
                layout.Append([new GraphSyntheticRow(GraphSyntheticRowKind.Wip, "wip", head)]));
            layout.Hang(StashRows(stashes));
            foreach (var page in pages)
            {
                rows.AddRange(layout.Append(page, Token));
            }

            results.Add((rows, layout.Hung));
        }

        Assert.Equal(results[0].Rows, results[1].Rows);
        Assert.Equal(results[0].Hung, results[1].Hung);
        Assert.Equal(pages.Sum(page => page.Count) + 1, results[0].Rows.Count);
    }

    // Security regression: a merge needing more lanes than the limit throws GraphTooWideException instead of growing
    // without bound; a wide but legal octopus merge lays out in one lane per parent.
    [Fact]
    public void TooWideGraphThrows()
    {
        var octopus = Make("o", Enumerable.Range(0, 200).Select(p => $"p{p}").ToArray());
        var row = Assert.Single(new GraphLayout().Append([octopus], Token));
        Assert.Equal(200, row.Width);
        Assert.Empty(row.Top);
        Assert.Equal(200, row.Bottom.Length); // The node's own lane, then one bend per other parent.
        Assert.Equal(199, row.Bottom.Count(s => s.Shape == GraphSegmentShape.BendOut));
        Assert.Equal(Enumerable.Range(1, 199), row.Bottom.Where(s => s.Shape == GraphSegmentShape.BendOut).Select(s => s.To));

        var tooWide = Make("w", Enumerable.Range(0, GraphLayout.MaxLanes + 1).Select(p => $"p{p}").ToArray());
        var error = Assert.Throws<GraphTooWideException>(() => new GraphLayout().Append([tooWide], Token));
        Assert.Equal(GraphLayout.MaxLanes + 1, error.Lanes);
    }

    // Helpers.

    private static Commit Make(string hash, params string[] parents) =>
        new(hash, parents, "A", "a@histq.invalid", DateTimeOffset.MinValue, DateTimeOffset.MinValue, hash, "");

    private static List<GraphSyntheticRow> StashRows(IReadOnlyList<Stash> stashes) =>
        stashes.Select(stash => new GraphSyntheticRow(GraphSyntheticRowKind.Stash, stash.Hash, stash.Base)).ToList();

    private static List<GraphRow> LayOutInPages(GraphLayout layout, Commit[] commits, int size)
    {
        var rows = new List<GraphRow>();
        for (var start = 0; start < commits.Length; start += size)
        {
            rows.AddRange(layout.Append(commits[start..Math.Min(start + size, commits.Length)], Token));
        }

        return rows;
    }

    /// <summary>Every lane (with its color) leaving a row's bottom edge enters the next row's top edge.</summary>
    private static void ExpectConnected(IReadOnlyList<GraphRow> rows)
    {
        for (var i = 0; i + 1 < rows.Count; i++)
        {
            var leaving = rows[i].Bottom.Select(s => (s.To, s.Color)).ToHashSet();
            var entering = rows[i + 1].Top.Select(s => (s.From, s.Color)).ToHashSet();
            Assert.True(leaving.SetEquals(entering), $"rows {i} and {i + 1} do not connect");
        }
    }

    /// <summary>Follows the line leaving row <paramref name="start"/>'s node down its lane to the row whose node it ends
    /// in; -1 when it ends nowhere.</summary>
    private static int LineEnd(IReadOnlyList<GraphRow> rows, int start)
    {
        var lane = rows[start].Lane;
        if (!rows[start].Bottom.Any(s => s.From == lane && s.To == lane))
        {
            return -1;
        }

        for (var index = start + 1; index < rows.Count; index++)
        {
            var found = false;
            foreach (var segment in rows[index].Top)
            {
                if (segment.From != lane)
                {
                    continue;
                }

                if (segment.To == rows[index].Lane)
                {
                    return index;
                }

                found = true;
                break;
            }

            if (!found)
            {
                return -1;
            }
        }

        return -1;
    }
}
