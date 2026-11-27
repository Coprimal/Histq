// What one load of a repo's log produced: the commits with their graph rows, the WIP, other-worktree and stash rows
// laid out around them, and what the next reload needs to read only the new commits (the tips, the filter, the order).
// Ported from LogSnapshot in App/Repo/RepoSession.swift at 6fa6d40 (its data only; the table-row mapping comes with
// the graph view).
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
}
