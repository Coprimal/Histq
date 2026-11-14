// Key feature tests for BranchAttribution (task 3.3): HEAD's branch claims its first-parent chain before a branch
// that sorts first, a merged-and-deleted side branch's commits take the branch it was merged into, and a commit only a
// remote branch reaches is named after that remote branch.
import Foundation
import HistqCore
import Testing

struct BranchAttributionTests {
    @Test("HEAD's branch wins its first-parent chain over another branch that also contains it")
    func headBranchWinsItsChain() {
        // `feature` (sorts before `main`) sits on top of main's tip: both contain main's chain.
        let commits = [commit("f1", ["m2"]), commit("m2", ["m1"]), commit("m1", [])]
        let refs = Refs(
            head: .branch("main", commit: "m2"),
            localBranches: [local("feature", "f1"), local("main", "m2", isHead: true)],
            remoteBranches: [], tags: [])

        let map = BranchAttribution.map(commits: commits, refs: refs)

        #expect(map == ["f1": "feature", "m2": "main", "m1": "main"])
    }

    @Test("a merged-and-deleted side branch's commits take the branch it was merged into")
    func deletedSideBranchInheritsTheMerge() {
        // M merges S2 (whose branch is gone) into main; S1 forks from B.
        let commits = [
            commit("m", ["a", "s2"]), commit("s2", ["s1"]), commit("a", ["b"]), commit("s1", ["b"]), commit("b", []),
        ]
        let refs = Refs(
            head: .branch("main", commit: "m"), localBranches: [local("main", "m", isHead: true)], remoteBranches: [],
            tags: [])

        let map = BranchAttribution.map(commits: commits, refs: refs)

        #expect(map == ["m": "main", "a": "main", "b": "main", "s2": "main", "s1": "main"])
    }

    @Test("a commit only a remote branch reaches gets the remote branch's name")
    func remoteOnlyCommitGetsTheRemote() {
        // origin/main is one commit ahead of the local main.
        let commits = [commit("r", ["m"]), commit("m", ["root"]), commit("root", [])]
        let refs = Refs(
            head: .branch("main", commit: "m"), localBranches: [local("main", "m", isHead: true)],
            remoteBranches: [RemoteBranch(name: "origin/main", refName: "refs/remotes/origin/main", remote: "origin",
                                          commit: "r")],
            tags: [])

        let map = BranchAttribution.map(commits: commits, refs: refs)

        #expect(map == ["r": "origin/main", "m": "main", "root": "main"])
    }

    // MARK: - Helpers

    private func commit(_ hash: String, _ parents: [String]) -> Commit {
        Commit(
            hash: hash, parents: parents, authorName: "A", authorEmail: "a@histq.invalid", authorDate: .distantPast,
            committerDate: .distantPast, subject: hash, body: "")
    }

    private func local(_ name: String, _ commit: String, isHead: Bool = false) -> LocalBranch {
        LocalBranch(
            name: name, refName: "refs/heads/\(name)", commit: commit, upstream: nil, ahead: 0, behind: 0,
            upstreamGone: false, isHead: isHead)
    }
}
