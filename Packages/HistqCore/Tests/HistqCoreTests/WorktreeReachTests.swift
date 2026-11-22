// WorktreeReach: each worktree's HEAD reaches its own branch and the history it shares; two worktrees sharing a stretch
// both own it.
import Foundation
import HistqCore
import Testing

struct WorktreeReachTests {
    @Test("each tip reaches its own branch and the shared history below it")
    func masksFromForkPoint() {
        // HEAD at h2; worktree A at a2 forks at r; worktree B at b1 forks from a1; worktree C at r (behind HEAD).
        let commits = [
            commit("b1", ["a1"]), commit("h2", ["h1"]), commit("a2", ["a1"]), commit("a1", ["r"]),
            commit("h1", ["r"]), commit("r", []),
        ]
        let index = Dictionary(uniqueKeysWithValues: commits.enumerated().map { ($1.hash, $0) })
        let masks = WorktreeReach.masks(commits: commits, index: index, tips: ["a2", "b1", "r", nil, "h2"])

        #expect(masks == [0b00010, 0b10000, 0b00001, 0b00011, 0b10000, 0b10111])
    }

    private func commit(_ hash: String, _ parents: [String]) -> Commit {
        Commit(
            hash: hash, parents: parents, authorName: "A", authorEmail: "a@histq.invalid", authorDate: .distantPast,
            committerDate: .distantPast, subject: hash, body: "")
    }
}
