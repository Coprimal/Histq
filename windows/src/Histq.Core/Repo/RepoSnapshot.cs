// What one load of a repo's log produced: the commits with their graph rows, the WIP, other-worktree and stash rows
// laid out around them, and what the next reload needs to read only the new commits (the tips, the filter, the order).
// Ported from LogSnapshot in App/Repo/RepoSession.swift at 6fa6d40, with its table-row mapping (entry(at:),
// row(ofCommit:), row(where:)).
using System.Collections.Frozen;

namespace Histq.Core;

/// <summary>
/// The log of a repo with its graph rows, in its <see cref="Order"/> (after an incremental reload the new commits are
/// merged in, see <see cref="RepoLoader.ReloadAsync"/>). <c>Rows[i]</c> is <c>Commits[i]</c>'s row; the WIP row above
/// the commits is in <see cref="SyntheticRows"/>, the other worktrees' and the stash rows in <see cref="Hung"/>, each
/// right above its base. A snapshot never changes once handed out: a later load makes a new one, so it can be read on
/// any thread.
/// </summary>
public sealed record RepoSnapshot
{
    public IReadOnlyList<Commit> Commits { get; init; } = [];

    public IReadOnlyList<GraphRow> Rows { get; init; } = [];

    /// <summary>
    /// Laid out before the commits, shown above them: the WIP row when the working tree has changes; once the log is
    /// complete, the other worktrees' and stash rows whose base is not in it (without a line).
    /// </summary>
    public IReadOnlyList<GraphRow> SyntheticRows { get; init; } = [];

    /// <summary>
    /// The other worktrees' rows, then the stash rows (newest first), each laid out right above its base commit; top
    /// first.
    /// </summary>
    public IReadOnlyList<GraphHungRow> Hung { get; init; } = [];

    /// <summary>What the synthetic rows were laid out from (<see cref="RepoLoader.SyntheticRows"/>).</summary>
    public IReadOnlyList<GraphSyntheticRow> Synthetic { get; init; } = [];

    /// <summary>The stashes of the stash rows, newest first.</summary>
    public IReadOnlyList<Stash> Stashes { get; init; } = [];

    /// <summary><see cref="Commits"/>' index of each hash: a click finds its commit here.</summary>
    public IReadOnlyDictionary<string, int> CommitIndex { get; init; } = FrozenDictionary<string, int>.Empty;

    /// <summary>
    /// Once the log is complete, the hashes of its commits no other commit lists as a parent
    /// (<see cref="LogReader.Tips"/>): an incremental reload reads only what is new since them.
    /// </summary>
    public IReadOnlyList<string> Tips { get; init; } = [];

    /// <summary>
    /// The most lanes a row of <see cref="SyntheticRows"/>, <see cref="Rows"/> or <see cref="Hung"/> draws in
    /// (<see cref="GraphRow.Width"/>): the graph column fits it without going over every row.
    /// </summary>
    public int Lanes { get; init; }

    /// <summary>The other worktrees with changes whose WIP rows are laid out (after the WIP row, before the stashes).</summary>
    public IReadOnlyList<Worktree> Worktrees { get; init; } = [];

    /// <summary>Every page has been parsed and laid out; false while only the first page is in.</summary>
    public bool IsComplete { get; init; }

    /// <summary>
    /// The repo was shallow when the log was read (<c>&lt;common dir&gt;/shallow</c>): a deepening fetch gives old
    /// commits new parents, so a reload reads the whole history again rather than only the new commits.
    /// </summary>
    public bool IsShallow { get; init; }

    /// <summary>
    /// The same for every snapshot of one load (its first page, then the whole log), new for each load: the graph
    /// inserts the rows a snapshot of the same load adds and reloads for a new one.
    /// </summary>
    public int Generation { get; init; }

    /// <summary>The hidden, soloed and pinned branches the log was read and laid out with.</summary>
    public LogFilter Filter { get; init; } = LogFilter.None;

    /// <summary>The order the log was read in (the commitOrder preference).</summary>
    public LogReader.Order Order { get; init; } = LogReader.Order.Date;

    /// <summary>How the rows took their lane colors (the laneColors preference).</summary>
    public GraphLayout.Coloring Coloring { get; init; } = GraphLayout.Coloring.Branch;

    /// <summary>The working tree's status the WIP row was laid out from; null before it was read.</summary>
    public WorkingStatus? Status { get; init; }

    /// <summary>The graph's rows: the top rows (<see cref="SyntheticRows"/>), then the commits with the hung rows
    /// between them.</summary>
    public long RowCount => (long)SyntheticRows.Count + Hung.Count + Commits.Count;

    /// <summary>What graph row <paramref name="row"/> shows; null outside the rows. O(log hung rows).</summary>
    public RepoRowEntry? EntryAt(long row)
    {
        if (row < 0 || row >= RowCount)
        {
            return null;
        }

        if (row < SyntheticRows.Count)
        {
            var top = SyntheticRows[(int)row];
            return top.Node.SyntheticRow is { } synthetic ? new RepoRowEntry(synthetic, top, -1) : null;
        }

        // The hung row k sits at position Hung[k].Above + k among the rows below the top ones (strictly increasing):
        // the hung rows at or above `position` are found by binary search.
        var position = row - SyntheticRows.Count;
        int low = 0, high = Hung.Count;
        while (low < high)
        {
            var middle = (low + high) / 2;
            if ((long)Hung[middle].Above + middle <= position)
            {
                low = middle + 1;
            }
            else
            {
                high = middle;
            }
        }

        if (low > 0 && (long)Hung[low - 1].Above + low - 1 == position)
        {
            var hung = Hung[low - 1];
            return new RepoRowEntry(hung.Synthetic, hung.Row, -1);
        }

        var index = position - low;
        return index < Commits.Count ? new RepoRowEntry(null, Rows[(int)index], (int)index) : null;
    }

    /// <summary>The graph row of <c>Commits[index]</c>.</summary>
    public long RowOfCommit(int index)
    {
        // The hung rows above it: those whose base comes at or before it.
        int low = 0, high = Hung.Count;
        while (low < high)
        {
            var middle = (low + high) / 2;
            if (Hung[middle].Above <= index)
            {
                low = middle + 1;
            }
            else
            {
                high = middle;
            }
        }

        return (long)SyntheticRows.Count + index + low;
    }

    /// <summary>The graph row of the first synthetic row of <paramref name="kind"/> with <paramref name="id"/>; -1 for
    /// none.</summary>
    public long RowOfSynthetic(GraphSyntheticRowKind kind, string id)
    {
        for (var top = 0; top < SyntheticRows.Count; top++)
        {
            if (SyntheticRows[top].Node.SyntheticRow is { } synthetic && Matches(synthetic))
            {
                return top;
            }
        }

        for (var k = 0; k < Hung.Count; k++)
        {
            if (Matches(Hung[k].Synthetic))
            {
                return (long)SyntheticRows.Count + Hung[k].Above + k;
            }
        }

        return -1;

        bool Matches(GraphSyntheticRow synthetic) =>
            synthetic.Kind == kind && string.Equals(synthetic.Id, id, StringComparison.Ordinal);
    }
}

/// <summary>What one graph row of a <see cref="RepoSnapshot"/> shows (<see cref="RepoSnapshot.EntryAt"/>).</summary>
/// <param name="Synthetic">The WIP, other worktree's or stash row; null for a commit.</param>
/// <param name="Row">The row as laid out.</param>
/// <param name="CommitIndex">The commit's index in <see cref="RepoSnapshot.Commits"/>; -1 for a synthetic row.</param>
public readonly record struct RepoRowEntry(GraphSyntheticRow? Synthetic, GraphRow Row, int CommitIndex);
