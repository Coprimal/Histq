// WorktreeReach: another worktree's commits count from where its branch forks off HEAD's history; a tip HEAD reaches
// has none; two worktrees sharing a stretch both own it.
import Foundation
import HistqCore
import Testing

struct WorktreeReachTests {
    @Test("another worktree's branch is its own from the fork point, shared history is not")
    func masksFromForkPoint() {
        // HEAD at h2; worktree A at a2 forks at r; worktree B at b1 forks from a1; worktree C at r (behind HEAD).
        let commits = [
            commit("b1", ["a1"]), commit("h2", ["h1"]), commit("a2", ["a1"]), commit("a1", ["r"]),
            commit("h1", ["r"]), commit("r", []),
        ]
        let index = Dictionary(uniqueKeysWithValues: commits.enumerated().map { ($1.hash, $0) })
        let masks = WorktreeReach.masks(commits: commits, index: index, head: "h2", tips: ["a2", "b1", "r", nil])

        #expect(masks == [0b010, 0, 0b001, 0b011, 0, 0])
    }

    private func commit(_ hash: String, _ parents: [String]) -> Commit {
        Commit(
            hash: hash, parents: parents, authorName: "A", authorEmail: "a@histq.invalid", authorDate: .distantPast,
            committerDate: .distantPast, subject: hash, body: "")
    }
}
