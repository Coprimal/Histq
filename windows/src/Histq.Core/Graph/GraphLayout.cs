// Lays out the commit graph as a streaming fold over `LogReader` pages: lanes are slots waiting for a parent hash, so
// each row needs only the open lanes, never the rows above it, and a page can be laid out as soon as git delivers it.
// Free slots are reused, which keeps the width bounded by the number of branches open at that point of the history.
// Ported from GraphLayout.swift at 6fa6d40.
using System.Collections.Immutable;
using System.Runtime.InteropServices;

namespace Histq.Core;

/// <summary>The shape of a <see cref="GraphSegment"/>.</summary>
public enum GraphSegmentShape : byte
{
    /// <summary>Stays in its lane (<c>From == To</c>): a lane passing by, or the node's own lane.</summary>
    Straight,

    /// <summary>Top half only: a child's line coming down lane <c>From</c> and bending into the node (<c>To</c>).</summary>
    BendIn,

    /// <summary>
    /// Bottom half only: a line leaving the node (<c>From</c>) and bending out to lane <c>To</c>, towards a merge's
    /// other parent.
    /// </summary>
    BendOut,
}

/// <summary>
/// One line piece in one half of a row. A top segment runs from the row's top edge at lane <c>From</c> to the row's
/// center at lane <c>To</c>; a bottom segment from the center at lane <c>From</c> to the bottom edge at lane
/// <c>To</c>. Lanes never shift, so only the lines that meet the node bend.
/// </summary>
/// <param name="Color">Index into the lane palette, <c>0..&lt;ColorCount</c> of <see cref="GraphLayout.Coloring"/>,
/// or <see cref="GraphLayout.StashColor"/>.</param>
/// <param name="IsDashed">The line between a synthetic row (WIP, stash) and its base commit.</param>
/// <param name="Owner">The commit the line leaves from, by its index among every commit the layout was fed (the child
/// of the edge it draws); -1 for a synthetic row's line. A merge's line that joins a lane already waiting for the same
/// parent keeps that lane's owner below the join.</param>
public readonly record struct GraphSegment(
    GraphSegmentShape Shape, int From, int To, int Color, bool IsDashed, int Owner = -1);

/// <summary>The kind of a <see cref="GraphSyntheticRow"/>.</summary>
public enum GraphSyntheticRowKind : byte
{
    Wip,
    Stash,
    WorktreeWip,
}

/// <summary>
/// A row that is not a commit of the log: the working tree changes, a stash, or another worktree's changes. It is
/// drawn on a lane that leads to its base commit's node.
/// </summary>
/// <param name="Id">Identifies the row for the app, e.g. the stash hash or the worktree path.</param>
/// <param name="Base">The commit the row hangs from (HEAD, the stash's base, the worktree's HEAD); null in an unborn
/// repo.</param>
public sealed record GraphSyntheticRow(GraphSyntheticRowKind Kind, string Id, string? Base);

/// <summary>A row's node: a commit of the log (<see cref="Commit"/>) or a synthetic row (<see cref="Synthetic"/>).</summary>
public readonly record struct GraphNode
{
    private GraphNode(string? hash, bool isMerge, GraphSyntheticRow? syntheticRow)
    {
        Hash = hash;
        IsMerge = isMerge;
        SyntheticRow = syntheticRow;
    }

    /// <summary>The commit's hash; null for a synthetic row.</summary>
    public string? Hash { get; }

    public bool IsMerge { get; }

    /// <summary>The synthetic row; null for a commit.</summary>
    public GraphSyntheticRow? SyntheticRow { get; }

    public bool IsSynthetic => SyntheticRow is not null;

    public static GraphNode Commit(string hash, bool isMerge) => new(hash, isMerge, null);

    public static GraphNode Synthetic(GraphSyntheticRow row) => new(null, false, row);
}

/// <summary>One laid-out row: where its node sits, its color, and the line pieces of both halves.</summary>
/// <param name="Lane">The node's lane (column index, 0 = leftmost).</param>
/// <param name="Color">The node's palette index (also the row band and badge line color).</param>
/// <param name="Top">Segments from the top edge to the center, ordered by <c>From</c>.</param>
/// <param name="Bottom">Segments from the center to the bottom edge: lanes passing by and the node's own lane
/// (straight), then the node's lines to a merge's other parents (bendOut).</param>
/// <param name="Width">Number of lanes this row draws in (highest lane used + 1).</param>
public readonly record struct GraphRow(
    GraphNode Node,
    int Lane,
    int Color,
    ImmutableArray<GraphSegment> Top,
    ImmutableArray<GraphSegment> Bottom,
    int Width)
{
    /// <summary>Value equality, segments compared element by element (rows of a straight stretch share buffers).</summary>
    public bool Equals(GraphRow other) =>
        Node == other.Node
        && Lane == other.Lane
        && Color == other.Color
        && Width == other.Width
        && Top.AsSpan().SequenceEqual(other.Top.AsSpan())
        && Bottom.AsSpan().SequenceEqual(other.Bottom.AsSpan());

    public override int GetHashCode() =>
        HashCode.Combine(Node, Lane, Color, Width, Top.IsDefault ? 0 : Top.Length, Bottom.IsDefault ? 0 : Bottom.Length);
}

/// <summary>A synthetic row laid out just above its base commit (<see cref="GraphLayout.Hang"/>).</summary>
/// <param name="Above">The index of the base commit among every commit the layout was fed: the row sits right above
/// it.</param>
public readonly record struct GraphHungRow(int Above, GraphSyntheticRow Synthetic, GraphRow Row);

/// <summary>
/// The resumable layout state. Feed the synthetic rows that sit at the top first, hang the ones that sit above their
/// base commit, then feed every <see cref="LogReader"/> page in order; each call returns the rows for what it was given,
/// and hung rows land in <see cref="Hung"/> as their base comes. <see cref="Copy"/> keeps a copy to resume later (the
/// Swift layout is a value).
/// <para>
/// A parent that never gets a row (shallow or partial history, a record the parser dropped, a synthetic row fed after
/// its base) keeps its lane open to the end; a duplicate hash is laid out as a new tip.
/// </para>
/// </summary>
public sealed class GraphLayout
{
    /// <summary>How lanes get their palette index.</summary>
    public enum Coloring
    {
        /// <summary>Each new line takes the next of 8 colors in turn and keeps it to its end, whatever its column.</summary>
        Branch,

        /// <summary>A line takes its column's color, <c>lane % 10</c>, so side-by-side lanes step through the palette in
        /// order.</summary>
        Column,
    }

    /// <summary>
    /// The color of a stash row, another worktree's WIP row, and their lines to their base: outside every lane palette
    /// (the app draws it grey), so such a row never takes a branch's color, and the commit it hangs from never takes
    /// the row's.
    /// </summary>
    public const int StashColor = 10;

    /// <summary>
    /// The most lanes a row may open; a row that would need more throws <see cref="GraphTooWideException"/>. Windows
    /// hardening that the macOS app does not have: it bounds the time and memory a hostile repository can make a page
    /// take (every row writes one segment per open lane). A normal repository never comes near it.
    /// </summary>
    public const int MaxLanes = 4096;

    /// <summary>
    /// Above this many parents a merge dedupes its parents and finds their lanes through hash lookups instead of
    /// scans; both give the same rows, the scans being cheaper for the usual 2 or 3 parents.
    /// </summary>
    private const int SmallMerge = 8;

    /// <summary>
    /// Which kind of edge a lane is waiting along; when several lanes wait for the same commit, the node continues the
    /// most important one so a branch's first-parent chain keeps its lane and color.
    /// </summary>
    private enum Edge : byte
    {
        FirstParent,
        MergeParent,
        Synthetic,
    }

    /// <summary>One slot; free when <see cref="WaitingFor"/> is null.</summary>
    private readonly record struct Lane(string? WaitingFor, int Color, Edge Edge, int Owner);

    private readonly Coloring coloring;

    /// <summary>Lanes <c>0..&lt;reserved</c> are kept for the pinned branches' first-parent chains.</summary>
    private readonly int reserved;

    /// <summary>Each pinned tip's lane, until the tip is laid out.</summary>
    private readonly Dictionary<string, int> pins;

    /// <summary>The open slots are <c>lanes[0..&lt;laneCount]</c>; every slot past <c>laneCount</c> is free.</summary>
    private Lane[] lanes;

    private int laneCount;

    /// <summary>The next color <see cref="Coloring.Branch"/> hands out.</summary>
    private int nextColor;

    /// <summary>Hung rows whose base has not come yet, in the order they were hung.</summary>
    private readonly List<GraphSyntheticRow> waiting;

    private readonly HashSet<string> waitingBases;

    /// <summary>The hung rows laid out so far, top first.</summary>
    private readonly List<GraphHungRow> hung;

    /// <summary>Commits laid out so far.</summary>
    private int placed;

    /// <summary>The last row's bottom half, which equal halves of the next row reuse (one shared buffer).</summary>
    private GraphSegment[] lastBottom = [];

    // Per-row scratch buffers: a row's halves are built here and copied out only when they differ from the last row's.
    private GraphSegment[] scratchTop = new GraphSegment[8];
    private GraphSegment[] scratchBottom = new GraphSegment[8];
    private GraphSegment[] outgoing = new GraphSegment[4];
    private int[] opened = new int[4];

    /// <summary><c>isOpened[lane]</c>: the current merge opened that lane (<see cref="PassingSegments"/> skips it).</summary>
    private bool[] isOpened = new bool[8];

    /// <summary>
    /// <paramref name="pinned"/> are the tips of the pinned branches, in pin order: each tip and its first-parent chain
    /// take the lane of its index, and every other line goes right of them. A tip that never comes leaves its lane
    /// empty.
    /// </summary>
    public GraphLayout(IReadOnlyList<string>? pinned = null, Coloring coloring = Coloring.Branch)
    {
        pinned ??= [];
        reserved = pinned.Count;
        this.coloring = coloring;
        pins = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var lane = 0; lane < pinned.Count; lane++)
        {
            pins.TryAdd(pinned[lane], lane);
        }

        lanes = new Lane[Math.Max(8, reserved)];
        waiting = [];
        waitingBases = new HashSet<string>(StringComparer.Ordinal);
        hung = [];
    }

    private GraphLayout(GraphLayout other)
    {
        coloring = other.coloring;
        reserved = other.reserved;
        pins = new Dictionary<string, int>(other.pins, StringComparer.Ordinal);
        lanes = (Lane[])other.lanes.Clone();
        laneCount = other.laneCount;
        nextColor = other.nextColor;
        waiting = [.. other.waiting];
        waitingBases = new HashSet<string>(other.waitingBases, StringComparer.Ordinal);
        hung = [.. other.hung];
        placed = other.placed;
        lastBottom = other.lastBottom; // Never written to once handed out.
    }

    /// <summary>Hung rows whose base has not come yet, in the order they were hung.</summary>
    public IReadOnlyList<GraphSyntheticRow> Waiting => waiting;

    /// <summary>The hung rows laid out so far, top first.</summary>
    public IReadOnlyList<GraphHungRow> Hung => hung;

    /// <summary>An independent copy of this state, to resume later.</summary>
    public GraphLayout Copy() => new(this);

    /// <summary>Lays out synthetic rows, each on a new lane that leads down to its base commit.</summary>
    public GraphRow[] Append(IReadOnlyList<GraphSyntheticRow> synthetic)
    {
        var rows = new GraphRow[synthetic.Count];
        for (var i = 0; i < rows.Length; i++)
        {
            rows[i] = Place(synthetic[i]);
        }

        return rows;
    }

    /// <summary>
    /// Hangs synthetic rows above their base commit: each is laid out (into <see cref="Hung"/>) right before that
    /// commit's row, in the order given. A row without a base, or whose base never comes, stays in
    /// <see cref="Waiting"/>.
    /// </summary>
    public void Hang(IReadOnlyList<GraphSyntheticRow> synthetic)
    {
        waiting.AddRange(synthetic);
        foreach (var row in synthetic)
        {
            if (row.Base is { } baseHash)
            {
                waitingBases.Add(baseHash);
            }
        }
    }

    /// <summary>
    /// Lays out one page of commits (children before parents, in either <see cref="LogReader.Order"/>). Throws
    /// <see cref="OperationCanceledException"/> when <paramref name="ct"/> is cancelled and
    /// <see cref="GraphTooWideException"/> when a row would need more than <see cref="MaxLanes"/> lanes; after either,
    /// the state is half-way through the page: discard it.
    /// </summary>
    public GraphRow[] Append(IReadOnlyList<Commit> commits, CancellationToken ct = default)
    {
        var rows = new GraphRow[commits.Count];
        for (var i = 0; i < rows.Length; i++)
        {
            ct.ThrowIfCancellationRequested();
            var commit = commits[i];
            if (waitingBases.Count > 0 && waitingBases.Remove(commit.Hash))
            {
                HangAbove(commit.Hash);
            }

            rows[i] = Place(commit, ct);
            placed++;
        }

        return rows;
    }

    /// <summary>Lays out the waiting rows whose base is <paramref name="hash"/>, in the order they were hung.</summary>
    private void HangAbove(string hash)
    {
        for (var i = 0; i < waiting.Count; i++)
        {
            var row = waiting[i];
            if (string.Equals(row.Base, hash, StringComparison.Ordinal))
            {
                hung.Add(new GraphHungRow(placed, row, Place(row)));
            }
        }

        waiting.RemoveAll(row => string.Equals(row.Base, hash, StringComparison.Ordinal));
    }

    private GraphRow Place(GraphSyntheticRow row)
    {
        var lane = FreeSlot();
        var color = row.Kind == GraphSyntheticRowKind.Wip ? NewColor(lane) : StashColor;
        var topCount = PassingSegments(ref scratchTop, 0);
        if (row.Base is { } baseHash)
        {
            lanes[lane] = new Lane(baseHash, color, Edge.Synthetic, -1);
        }

        TrimFreeSlots();
        var bottomCount = PassingSegments(ref scratchBottom, 0);
        return MakeRow(
            GraphNode.Synthetic(row), lane, color, scratchTop.AsSpan(0, topCount), scratchBottom.AsSpan(0, bottomCount));
    }

    private GraphRow Place(Commit commit, CancellationToken ct)
    {
        var hash = commit.Hash;
        // Lanes waiting for this commit end at its node; the node continues the best of them.
        var node = -1;
        var best = Edge.FirstParent;
        for (var index = 0; index < laneCount; index++)
        {
            var lane = lanes[index];
            if (lane.WaitingFor is null || !string.Equals(lane.WaitingFor, hash, StringComparison.Ordinal))
            {
                continue;
            }

            // Among the lines of synthetic rows, this worktree's WIP's (colored) wins over a grey one's.
            if (node < 0 || lane.Edge < best || (lane.Edge == best && lanes[node].Color == StashColor))
            {
                node = index;
                best = lane.Edge;
            }
        }

        // A pinned tip moves to its reserved lane, unless it continues a lane further left (another pin's).
        var pin = reserved > 0 && pins.Remove(hash, out var pinLane) ? pinLane : -1;
        // The color of the lane the node continues; a tip, or a commit only grey rows hang from, gets its own.
        var continued = node >= 0 && lanes[node].Color != StashColor ? lanes[node].Color : -1;
        if (node < 0 && pin < 0)
        {
            node = FreeSlot();
        }

        if (pin >= 0 && (node < 0 || pin < node))
        {
            node = pin;
            if (laneCount <= pin)
            {
                Grow(pin + 1);
            }
        }

        var color = coloring == Coloring.Column ? NewColor(node) : continued >= 0 ? continued : NewColor(node);
        var topCount = 0;
        for (var index = 0; index < laneCount; index++)
        {
            var lane = lanes[index];
            if (lane.WaitingFor is null)
            {
                continue;
            }

            var dashed = lane.Edge == Edge.Synthetic;
            if (string.Equals(lane.WaitingFor, hash, StringComparison.Ordinal))
            {
                var shape = index == node ? GraphSegmentShape.Straight : GraphSegmentShape.BendIn;
                Add(ref scratchTop, ref topCount, new GraphSegment(shape, index, node, lane.Color, dashed, lane.Owner));
                lanes[index] = default;
            }
            else
            {
                Add(ref scratchTop, ref topCount,
                    new GraphSegment(GraphSegmentShape.Straight, index, index, lane.Color, dashed, lane.Owner));
            }
        }

        // The first parent continues the node's lane; the others join a lane already waiting for them, or open one.
        var parents = commit.Parents;
        var outgoingCount = 0;
        var openedCount = 0;
        var owner = placed;
        if (parents.Count > 0)
        {
            lanes[node] = new Lane(parents[0], color, Edge.FirstParent, owner);
        }

        // A wide merge: a parent seen once, and the lane each hash is waiting in (the leftmost, as the scan finds it).
        // Lanes the loop opens wait for parents already seen, so the map stays right through the loop.
        HashSet<string>? seen = null;
        Dictionary<string, int>? waitingIn = null;
        if (parents.Count > SmallMerge)
        {
            seen = new HashSet<string>(StringComparer.Ordinal) { parents[0] };
            waitingIn = new Dictionary<string, int>(StringComparer.Ordinal);
            for (var index = 0; index < laneCount; index++)
            {
                var lane = lanes[index];
                if (lane.WaitingFor is not null && lane.Edge != Edge.Synthetic)
                {
                    waitingIn.TryAdd(lane.WaitingFor, index);
                }
            }
        }

        for (var p = 1; p < parents.Count; p++)
        {
            if ((p & 0x3FF) == 0)
            {
                ct.ThrowIfCancellationRequested();
            }

            var parent = parents[p];
            if (seen is null ? IsRepeated(parents, p) : !seen.Add(parent))
            {
                continue;
            }

            var target = -1;
            if (waitingIn is not null)
            {
                target = waitingIn.GetValueOrDefault(parent, -1);
            }
            else
            {
                for (var index = 0; index < laneCount; index++)
                {
                    var lane = lanes[index];
                    if (lane.WaitingFor is not null && lane.Edge != Edge.Synthetic
                        && string.Equals(lane.WaitingFor, parent, StringComparison.Ordinal))
                    {
                        target = index;
                        break;
                    }
                }
            }

            if (target < 0)
            {
                // Slots fill left to right in the loop, so a wide merge looks right of the last one it opened.
                target = FreeSlot(waitingIn is not null && openedCount > 0 ? opened[openedCount - 1] + 1 : reserved);
                lanes[target] = new Lane(parent, NewColor(target), Edge.MergeParent, owner);
                if (openedCount == opened.Length)
                {
                    Array.Resize(ref opened, opened.Length * 2);
                }

                opened[openedCount++] = target;
            }

            Add(ref outgoing, ref outgoingCount,
                new GraphSegment(GraphSegmentShape.BendOut, node, target, lanes[target].Color, false, owner));
        }

        TrimFreeSlots();

        var bottomCount = PassingSegments(ref scratchBottom, openedCount);
        for (var i = 0; i < outgoingCount; i++)
        {
            Add(ref scratchBottom, ref bottomCount, outgoing[i]);
        }

        return MakeRow(
            GraphNode.Commit(hash, commit.IsMerge), node, color, scratchTop.AsSpan(0, topCount),
            scratchBottom.AsSpan(0, bottomCount));
    }

    /// <summary><paramref name="parents"/>[<paramref name="at"/>] is also listed before it (a parent counts once).</summary>
    private static bool IsRepeated(IReadOnlyList<string> parents, int at)
    {
        var parent = parents[at];
        for (var i = 0; i < at; i++)
        {
            if (string.Equals(parents[i], parent, StringComparison.Ordinal))
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>
    /// Writes a straight segment for every open lane, except the first <paramref name="skipped"/> of
    /// <see cref="opened"/>, into <paramref name="buffer"/>; returns how many.
    /// </summary>
    private int PassingSegments(ref GraphSegment[] buffer, int skipped)
    {
        if (skipped > 0 && isOpened.Length < laneCount)
        {
            Array.Resize(ref isOpened, Math.Max(laneCount, isOpened.Length * 2));
        }

        for (var i = 0; i < skipped; i++)
        {
            isOpened[opened[i]] = true;
        }

        var count = 0;
        for (var index = 0; index < laneCount; index++)
        {
            var lane = lanes[index];
            if (lane.WaitingFor is null || (skipped > 0 && isOpened[index]))
            {
                continue;
            }

            Add(ref buffer, ref count, new GraphSegment(
                GraphSegmentShape.Straight, index, index, lane.Color, lane.Edge == Edge.Synthetic, lane.Owner));
        }

        for (var i = 0; i < skipped; i++)
        {
            isOpened[opened[i]] = false;
        }

        return count;
    }

    private static void Add(ref GraphSegment[] buffer, ref int count, GraphSegment segment)
    {
        if (count == buffer.Length)
        {
            Array.Resize(ref buffer, buffer.Length * 2);
        }

        buffer[count++] = segment;
    }

    private GraphRow MakeRow(
        GraphNode node, int lane, int color, ReadOnlySpan<GraphSegment> top, ReadOnlySpan<GraphSegment> bottom)
    {
        // On a straight stretch both halves equal the last row's bottom: keep one buffer for all of them.
        var topArray = top.SequenceEqual(lastBottom) ? lastBottom : top.ToArray();
        var bottomArray = bottom.SequenceEqual(topArray) ? topArray : bottom.ToArray();
        lastBottom = bottomArray;
        var highest = lane;
        foreach (var segment in topArray)
        {
            highest = Math.Max(highest, Math.Max(segment.From, segment.To));
        }

        foreach (var segment in bottomArray)
        {
            highest = Math.Max(highest, Math.Max(segment.From, segment.To));
        }

        return new GraphRow(
            node, lane, color, ImmutableCollectionsMarshal.AsImmutableArray(topArray),
            ImmutableCollectionsMarshal.AsImmutableArray(bottomArray), highest + 1);
    }

    /// <summary>
    /// The leftmost free slot right of the reserved lanes, growing the lane list when none is free. The slot stays
    /// free until set. <paramref name="from"/> skips slots known to be taken.
    /// </summary>
    private int FreeSlot(int from = 0)
    {
        if (laneCount < reserved)
        {
            Grow(reserved);
        }

        for (var index = Math.Max(from, reserved); index < laneCount; index++)
        {
            if (lanes[index].WaitingFor is null)
            {
                return index;
            }
        }

        Grow(laneCount + 1);
        return laneCount - 1;
    }

    /// <summary>Opens free slots up to <paramref name="count"/>.</summary>
    private void Grow(int count)
    {
        if (count > MaxLanes)
        {
            throw new GraphTooWideException(count);
        }

        if (lanes.Length < count)
        {
            Array.Resize(ref lanes, Math.Max(count, lanes.Length * 2));
        }

        Array.Clear(lanes, laneCount, count - laneCount);
        laneCount = count;
    }

    private void TrimFreeSlots()
    {
        while (laneCount > 0 && lanes[laneCount - 1].WaitingFor is null)
        {
            laneCount--;
        }
    }

    /// <summary>A new line's color in column <paramref name="lane"/>: the column's, or the next in turn.</summary>
    private int NewColor(int lane)
    {
        if (coloring != Coloring.Branch)
        {
            return lane % coloring.ColorCount;
        }

        var color = nextColor;
        nextColor = (nextColor + 1) % coloring.ColorCount;
        return color;
    }
}

/// <summary>
/// A row of the graph would need more than <see cref="GraphLayout.MaxLanes"/> lanes: the graph is too wide to draw.
/// Windows hardening against a hostile repository (an octopus merge of thousands of parents, thousands of parents that
/// never come); the macOS app has no such limit, and a normal repository never reaches it.
/// </summary>
public sealed class GraphTooWideException(int lanes)
    : Exception($"This graph is too wide to draw ({lanes} lanes, at most {GraphLayout.MaxLanes}).")
{
    /// <summary>How many lanes the row would have needed.</summary>
    public int Lanes { get; } = lanes;
}

public static class GraphLayoutColoringExtensions
{
    extension(GraphLayout.Coloring coloring)
    {
        /// <summary>The palette size the indices cycle through.</summary>
        public int ColorCount => coloring == GraphLayout.Coloring.Branch ? 8 : 10;
    }
}
