// Tells which branch each commit of the log is on, for the graph's faded badge on a selected commit that is not a
// branch tip (as GitKraken does). A heuristic, in two passes over the log, O(n):
//   1. First-parent walks from the branch tips in priority order: HEAD's branch, the other local branches by name,
//      then the remote branches by name. A walk stops at a commit an earlier walk claimed.
//   2. In log order (children before parents), a commit no walk reached takes the claim of its first claimed child:
//      the commits of a side branch that was merged, then deleted, get the branch it was merged into.
import Foundation

public enum BranchAttribution {
    /// Each commit's branch (a local branch's short name, or a remote branch's `origin/x`), by hash. `commits` is in
    /// log order (`git log --topo-order`, children first); `index` is each hash's position in `commits` (built when
    /// nil). Commits no branch reaches (only under a tag or a stash) are left out.
    public static func map(commits: [Commit], refs: Refs, index: [String: Int]? = nil) -> [String: String] {
        let (names, claims) = claims(commits: commits, refs: refs, index: index)
        var result: [String: String] = [:]
        result.reserveCapacity(commits.count)
        for (position, claim) in claims.enumerated() where claim >= 0 {
            result[commits[position].hash] = names[Int(claim)]
        }
        return result
    }

    /// The same as `map`, by position: `claims[i]` is `commits[i]`'s branch, an index into `names` (-1 for none).
    /// Cheaper for a long log than the map by hash. A cancelled task gets a partial result early (unclaimed commits).
    public static func claims(commits: [Commit], refs: Refs, index: [String: Int]? = nil)
        -> (names: [String], claims: [Int32])
    {
        let index = index ?? Dictionary(commits.enumerated().map { ($1.hash, $0) }, uniquingKeysWith: { a, _ in a })
        let tips = tips(refs)
        var claims = [Int32](repeating: -1, count: commits.count)
        // Every commit's parents by position (-1 for one outside the log), looked up once: commit `i`'s are
        // `parents[starts[i]..<starts[i + 1]]`, first parent first.
        var starts = [Int32]()
        starts.reserveCapacity(commits.count + 1)
        var parents = [Int32]()
        parents.reserveCapacity(commits.count + commits.count / 4)
        for commit in commits {
            if starts.count & 0xFFFF == 0, Task.isCancelled { return (tips.map(\.name), claims) }
            starts.append(Int32(parents.count))
            for parent in commit.parents { parents.append(index[parent].map(Int32.init) ?? -1) }
        }
        starts.append(Int32(parents.count))

        // Pass 1: first-parent walks.
        var steps = 0
        for (tip, branch) in tips.enumerated() {
            var position = index[branch.commit] ?? -1
            while position >= 0, claims[position] < 0 {
                steps += 1
                if steps & 0xFFFF == 0, Task.isCancelled { return (tips.map(\.name), claims) }
                claims[position] = Int32(tip)
                let start = Int(starts[position])
                position = start < Int(starts[position + 1]) ? Int(parents[start]) : -1
            }
        }

        // Pass 2: an unclaimed commit takes its first claimed child's claim, handed down in log order.
        for position in commits.indices {
            if position & 0xFFFF == 0, Task.isCancelled { return (tips.map(\.name), claims) }
            guard claims[position] >= 0 else { continue }
            for slot in Int(starts[position])..<Int(starts[position + 1]) {
                let parent = Int(parents[slot])
                if parent > position, claims[parent] < 0 { claims[parent] = claims[position] }
            }
        }
        return (tips.map(\.name), claims)
    }

    /// The branch tips in claim order: HEAD's branch, the other local branches, then the remote branches, each group by
    /// name.
    private static func tips(_ refs: Refs) -> [(name: String, commit: String)] {
        let headName: String? = if case .branch(let name, _) = refs.head { name } else { nil }
        let locals = refs.localBranches.sorted { a, b in
            let (aHead, bHead) = (a.name == headName, b.name == headName)
            return aHead != bHead ? aHead : a.name < b.name
        }
        let remotes = refs.remoteBranches.sorted { $0.name < $1.name }
        return locals.map { ($0.name, $0.commit) } + remotes.map { ($0.name, $0.commit) }
    }
}
