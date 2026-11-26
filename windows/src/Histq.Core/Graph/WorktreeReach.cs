// Tells which worktrees' HEADs reach each commit of the log, so the graph can fade every worktree's commits but the
// selected one's, from where they fork off its history. One pass over the log, O(n).
// Ported from WorktreeReach.swift at 6fa6d40.
namespace Histq.Core;

public static class WorktreeReach
{
    /// <summary>The most worktrees told apart (one bit each); later ones are left out.</summary>
    public const int MaxTips = 64;

    /// <summary>
    /// <c>masks[i]</c> has bit <c>k</c> set when <c>commits[i]</c> is reachable from <c>tips[k]</c>; 0 for a commit no
    /// tip reaches. <paramref name="commits"/> is in log order (children first, in either
    /// <see cref="LogReader.Order"/>); <paramref name="index"/> is each hash's position in <paramref name="commits"/>. A
    /// tip outside the log reaches nothing. A cancelled token gives a partial result early.
    /// </summary>
    public static ulong[] Masks(
        IReadOnlyList<Commit> commits, IReadOnlyDictionary<string, int> index, IReadOnlyList<string?> tips,
        CancellationToken ct = default)
    {
        var masks = new ulong[commits.Count];
        var count = Math.Min(tips.Count, MaxTips);
        for (var bit = 0; bit < count; bit++)
        {
            if (tips[bit] is { } tip && index.TryGetValue(tip, out var position))
            {
                masks[position] |= 1UL << bit;
            }
        }

        for (var position = 0; position < masks.Length; position++)
        {
            if ((position & 0xFFFF) == 0 && ct.IsCancellationRequested)
            {
                return masks;
            }

            var mask = masks[position];
            if (mask == 0)
            {
                continue;
            }

            var parents = commits[position].Parents;
            for (var p = 0; p < parents.Count; p++)
            {
                if (index.TryGetValue(parents[p], out var at) && at > position)
                {
                    masks[at] |= mask;
                }
            }
        }

        return masks;
    }
}
