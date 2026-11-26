// Tells which branch each commit of the log is on, for the graph's faded badge on a selected commit that is not a
// branch tip. A heuristic, in two passes over the log, O(n):
//   1. First-parent walks from the branch tips in priority order: HEAD's branch, the other local branches by name,
//      then the remote branches by name. A walk stops at a commit an earlier walk claimed.
//   2. In log order (children before parents), a commit no walk reached takes the claim of its first claimed child:
//      the commits of a side branch that was merged, then deleted, get the branch it was merged into.
// Ported from BranchAttribution.swift at 6fa6d40.
namespace Histq.Core;

public static class BranchAttribution
{
    /// <summary>
    /// Each commit's branch (a local branch's short name, or a remote branch's <c>origin/x</c>), by hash.
    /// <paramref name="commits"/> is in log order (children first, in either <see cref="LogReader.Order"/>);
    /// <paramref name="index"/> is each hash's position in <paramref name="commits"/> (built when null). Commits no
    /// branch reaches (only under a tag or a stash) are left out. A cancelled token gives a partial result early.
    /// </summary>
    public static Dictionary<string, string> Map(
        IReadOnlyList<Commit> commits, Refs refs, IReadOnlyDictionary<string, int>? index = null,
        CancellationToken ct = default)
    {
        var (names, claims) = Claims(commits, refs, index, ct);
        var result = new Dictionary<string, string>(commits.Count, StringComparer.Ordinal);
        for (var position = 0; position < claims.Length; position++)
        {
            if (claims[position] >= 0)
            {
                result[commits[position].Hash] = names[claims[position]];
            }
        }

        return result;
    }

    /// <summary>
    /// The same as <see cref="Map"/>, by position: <c>Claims[i]</c> is <c>commits[i]</c>'s branch, an index into
    /// <c>Names</c> (-1 for none). Cheaper for a long log than the map by hash. A cancelled token gives a partial result
    /// early (unclaimed commits).
    /// </summary>
    public static (IReadOnlyList<string> Names, int[] Claims) Claims(
        IReadOnlyList<Commit> commits, Refs refs, IReadOnlyDictionary<string, int>? index = null,
        CancellationToken ct = default)
    {
        index ??= BuildIndex(commits);
        var tips = Tips(refs);
        var names = new string[tips.Count];
        for (var i = 0; i < names.Length; i++)
        {
            names[i] = tips[i].Name;
        }

        var claims = new int[commits.Count];
        Array.Fill(claims, -1);
        // Every commit's parents by position (-1 for one outside the log), looked up once: commit `i`'s are
        // `parents[starts[i]..<starts[i + 1]]`, first parent first.
        var starts = new int[commits.Count + 1];
        var parents = new int[commits.Count + (commits.Count / 4)];
        var parentCount = 0;
        for (var position = 0; position < commits.Count; position++)
        {
            if ((position & 0xFFFF) == 0 && ct.IsCancellationRequested)
            {
                return (names, claims);
            }

            starts[position] = parentCount;
            var commitParents = commits[position].Parents;
            if (parentCount + commitParents.Count > parents.Length)
            {
                Array.Resize(ref parents, Math.Max(parents.Length * 2, parentCount + commitParents.Count));
            }

            for (var p = 0; p < commitParents.Count; p++)
            {
                parents[parentCount++] = index.TryGetValue(commitParents[p], out var at) ? at : -1;
            }
        }

        starts[commits.Count] = parentCount;

        // Pass 1: first-parent walks.
        var steps = 0;
        for (var tip = 0; tip < tips.Count; tip++)
        {
            var position = index.TryGetValue(tips[tip].Commit, out var at) ? at : -1;
            while (position >= 0 && claims[position] < 0)
            {
                steps++;
                if ((steps & 0xFFFF) == 0 && ct.IsCancellationRequested)
                {
                    return (names, claims);
                }

                claims[position] = tip;
                var start = starts[position];
                position = start < starts[position + 1] ? parents[start] : -1;
            }
        }

        // Pass 2: an unclaimed commit takes its first claimed child's claim, handed down in log order.
        for (var position = 0; position < commits.Count; position++)
        {
            if ((position & 0xFFFF) == 0 && ct.IsCancellationRequested)
            {
                return (names, claims);
            }

            if (claims[position] < 0)
            {
                continue;
            }

            for (var slot = starts[position]; slot < starts[position + 1]; slot++)
            {
                var parent = parents[slot];
                if (parent > position && claims[parent] < 0)
                {
                    claims[parent] = claims[position];
                }
            }
        }

        return (names, claims);
    }

    /// <summary>Each hash's first position in <paramref name="commits"/>.</summary>
    private static Dictionary<string, int> BuildIndex(IReadOnlyList<Commit> commits)
    {
        var index = new Dictionary<string, int>(commits.Count, StringComparer.Ordinal);
        for (var position = 0; position < commits.Count; position++)
        {
            index.TryAdd(commits[position].Hash, position);
        }

        return index;
    }

    /// <summary>
    /// The branch tips in claim order: HEAD's branch, the other local branches, then the remote branches, each group by
    /// name.
    /// </summary>
    private static List<(string Name, string Commit)> Tips(Refs refs)
    {
        var headName = refs.Head is Head.Branch branch ? branch.Name : null;
        var locals = refs.LocalBranches.ToArray();
        Array.Sort(locals, (a, b) =>
        {
            var (aHead, bHead) = (string.Equals(a.Name, headName, StringComparison.Ordinal),
                string.Equals(b.Name, headName, StringComparison.Ordinal));
            return aHead != bHead ? (aHead ? -1 : 1) : string.CompareOrdinal(a.Name, b.Name);
        });
        var remotes = refs.RemoteBranches.ToArray();
        Array.Sort(remotes, (a, b) => string.CompareOrdinal(a.Name, b.Name));

        var tips = new List<(string Name, string Commit)>(locals.Length + remotes.Length);
        foreach (var local in locals)
        {
            tips.Add((local.Name, local.Commit));
        }

        foreach (var remote in remotes)
        {
            tips.Add((remote.Name, remote.Commit));
        }

        return tips;
    }
}
