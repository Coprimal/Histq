// Tells which commits of the log are on another worktree's branch only, from where it forks off this worktree's
// history: reachable from that worktree's HEAD and not from this one's. One pass over the log, O(n).
import Foundation

public enum WorktreeReach {
    /// The most worktrees told apart (one bit each); later ones are left out.
    public static let maxTips = 64

    /// `masks[i]` has bit `k` set when `commits[i]` is reachable from `tips[k]` but not from `head`; 0 for a commit
    /// `head` reaches or no tip reaches. `commits` is in log order (children first, in either `LogReader.Order`);
    /// `index` is each hash's position in `commits`. A tip or head outside the log reaches nothing. A cancelled task
    /// gets a partial result early.
    public static func masks(commits: [Commit], index: [String: Int], head: String?, tips: [String?]) -> [UInt64] {
        var masks = [UInt64](repeating: 0, count: commits.count)
        var isHeads = [Bool](repeating: false, count: commits.count)
        if let head, let position = index[head] { isHeads[position] = true }
        for (bit, tip) in tips.prefix(maxTips).enumerated() {
            if let tip, let position = index[tip] { masks[position] |= 1 << UInt64(bit) }
        }
        for position in commits.indices {
            if position & 0xFFFF == 0, Task.isCancelled { return masks }
            let isHead = isHeads[position]
            if isHead { masks[position] = 0 }
            let mask = masks[position]
            guard isHead || mask != 0 else { continue }
            for parent in commits[position].parents {
                guard let at = index[parent], at > position else { continue }
                if isHead { isHeads[at] = true } else { masks[at] |= mask }
            }
        }
        return masks
    }
}
