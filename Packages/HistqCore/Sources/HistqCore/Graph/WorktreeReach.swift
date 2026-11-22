// Tells which worktrees' HEADs reach each commit of the log, so the graph can fade every worktree's commits but the
// selected one's, from where they fork off its history. One pass over the log, O(n).
import Foundation

public enum WorktreeReach {
    /// The most worktrees told apart (one bit each); later ones are left out.
    public static let maxTips = 64

    /// `masks[i]` has bit `k` set when `commits[i]` is reachable from `tips[k]`; 0 for a commit no tip reaches.
    /// `commits` is in log order (children first, in either `LogReader.Order`); `index` is each hash's position in
    /// `commits`. A tip outside the log reaches nothing. A cancelled task gets a partial result early.
    public static func masks(commits: [Commit], index: [String: Int], tips: [String?]) -> [UInt64] {
        var masks = [UInt64](repeating: 0, count: commits.count)
        for (bit, tip) in tips.prefix(maxTips).enumerated() {
            if let tip, let position = index[tip] { masks[position] |= 1 << UInt64(bit) }
        }
        for position in commits.indices {
            if position & 0xFFFF == 0, Task.isCancelled { return masks }
            let mask = masks[position]
            guard mask != 0 else { continue }
            for parent in commits[position].parents {
                guard let at = index[parent], at > position else { continue }
                masks[at] |= mask
            }
        }
        return masks
    }
}
