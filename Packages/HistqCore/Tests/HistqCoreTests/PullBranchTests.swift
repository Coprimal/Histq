// `GitOperations.pullBranch`: a branch that is not checked out pulled from its upstream without a checkout. Fast-forward,
// in-memory merge and rebase move only the branch; conflicts, a diverged fast-forward-only pull, a signed rebase,
// merge commits to rebase and a branch checked out in a worktree leave the branch, HEAD, the index and the files as
// they were.
import Foundation
import HistqCore
import Testing

struct PullBranchTests {
    /// `up` (the remote, `main` checked out) and its clone `local` (`main` checked out), whose local `dev` tracks
    /// `origin/dev`; both start at the same commit.
    struct Setup {
        let sandbox: Sandbox
        let up: URL
        let local: URL
        let ops: GitOperations

        init() async throws {
            sandbox = try await Sandbox()
            up = try await sandbox.makeRepo("up")
            try await sandbox.git(["branch", "dev"], in: up)
            local = sandbox.root.appending(path: "local", directoryHint: .isDirectory)
            try await sandbox.git(["clone", "-q", up.path, local.path], in: sandbox.root)
            try await sandbox.git(["config", "user.name", "Local"], in: local)
            try await sandbox.git(["config", "user.email", "local@histq.invalid"], in: local)
            try await sandbox.git(["branch", "--track", "dev", "origin/dev"], in: local)
            ops = GitOperations(
                runner: sandbox.runner, cwd: local, env: GitInvocation.environment(profile: nil, base: sandbox.base),
                networkTimeout: .seconds(30))
        }

        /// Commits `text` to `file` on `dev` of `repo` without leaving `main` checked out there.
        @discardableResult
        func commit(_ file: String, _ text: String, in repo: URL, message: String) async throws -> String {
            try await sandbox.git(["checkout", "-q", "dev"], in: repo)
            try Data(text.utf8).write(to: repo.appending(path: file))
            try await sandbox.git(["add", file], in: repo)
            try await sandbox.git(["commit", "-q", "-m", message], in: repo)
            let hash = try await sandbox.git(["rev-parse", "HEAD"], in: repo)
            try await sandbox.git(["checkout", "-q", "main"], in: repo)
            return hash
        }

        func rev(_ revision: String) async throws -> String {
            try await sandbox.git(["rev-parse", revision], in: local)
        }

        /// HEAD, the checked-out branch, the index's tree and the porcelain status of `local`.
        func checkout() async throws -> [String] {
            [try await rev("HEAD"), try await sandbox.git(["symbolic-ref", "HEAD"], in: local),
             try await sandbox.git(["write-tree"], in: local), try await sandbox.git(["status", "--porcelain"], in: local)]
        }
    }

    @Test("behind only: every mode fast-forwards dev; up to date changes nothing; HEAD and files stay")
    func fastForward() async throws {
        let fx = try await Setup()
        defer { fx.sandbox.remove() }
        try Data("wip\n".utf8).write(to: fx.local.appending(path: "tracked.txt"))
        let before = try await fx.checkout()
        let remote = try await fx.commit("b.txt", "b\n", in: fx.up, message: "remote b")

        try await fx.ops.pullBranch("dev", remote: "origin", remoteBranch: "dev", mode: .fastForwardOnly)
        #expect(try await fx.rev("dev") == remote)
        #expect(try await fx.rev("origin/dev") == remote)
        try await fx.ops.pullBranch("dev", remote: "origin", remoteBranch: "dev", mode: .rebase)
        #expect(try await fx.rev("dev") == remote)
        #expect(try await fx.checkout() == before)
    }

    @Test("diverged, fast-forward if possible: a merge commit with pull's message, local then fetched parent")
    func mergeInMemory() async throws {
        let fx = try await Setup()
        defer { fx.sandbox.remove() }
        let before = try await fx.checkout()
        let mine = try await fx.commit("a.txt", "a\n", in: fx.local, message: "local a")
        let remote = try await fx.commit("b.txt", "b\n", in: fx.up, message: "remote b")

        try await fx.ops.pullBranch("dev", remote: "origin", remoteBranch: "dev", mode: .fastForward)
        #expect(try await fx.rev("dev^1") == mine)
        #expect(try await fx.rev("dev^2") == remote)
        let subject = try await fx.sandbox.git(["log", "-1", "--format=%s", "dev"], in: fx.local)
        #expect(subject == "Merge branch 'dev' of \(fx.up.path) into dev")
        #expect(try await fx.sandbox.git(["ls-tree", "--name-only", "dev"], in: fx.local) == "a.txt\nb.txt\ntracked.txt")
        #expect(try await fx.checkout() == before)
    }

    @Test("diverged, fast-forward only: refused, dev unchanged")
    func fastForwardOnlyDiverged() async throws {
        let fx = try await Setup()
        defer { fx.sandbox.remove() }
        let mine = try await fx.commit("a.txt", "a\n", in: fx.local, message: "local a")
        try await fx.commit("b.txt", "b\n", in: fx.up, message: "remote b")

        await #expect {
            try await fx.ops.pullBranch("dev", remote: "origin", remoteBranch: "dev", mode: .fastForwardOnly)
        } throws: { error in
            if case GitError.nonFastForward = error { true } else { false }
        }
        #expect(try await fx.rev("dev") == mine)
    }

    @Test("conflicts: merge names the files, rebase does not; dev, HEAD, the index and the files are as they were",
          arguments: [GitOperations.PullMode.fastForward, .rebase])
    func conflicts(mode: GitOperations.PullMode) async throws {
        let fx = try await Setup()
        defer { fx.sandbox.remove() }
        let before = try await fx.checkout()
        let mine = try await fx.commit("tracked.txt", "local\n", in: fx.local, message: "local edit")
        try await fx.commit("tracked.txt", "remote\n", in: fx.up, message: "remote edit")

        await #expect(throws: GitOperationError.pullWouldConflict(
            branch: "dev", paths: mode == .rebase ? [] : ["tracked.txt"])
        ) {
            try await fx.ops.pullBranch("dev", remote: "origin", remoteBranch: "dev", mode: mode)
        }
        #expect(try await fx.rev("dev") == mine)
        #expect(try await fx.checkout() == before)
    }

    @Test("diverged, rebase: dev's own commit replayed onto the fetched one, HEAD and files unchanged")
    func rebaseInMemory() async throws {
        let fx = try await Setup()
        defer { fx.sandbox.remove() }
        let before = try await fx.checkout()
        try await fx.commit("a.txt", "a\n", in: fx.local, message: "local a")
        let remote = try await fx.commit("b.txt", "b\n", in: fx.up, message: "remote b")

        try await fx.ops.pullBranch("dev", remote: "origin", remoteBranch: "dev", mode: .rebase)
        #expect(try await fx.rev("dev^") == remote)
        #expect(try await fx.sandbox.git(["log", "-1", "--format=%s", "dev"], in: fx.local) == "local a")
        #expect(try await fx.checkout() == before)
    }

    @Test("rebase from the fork point: a commit the upstream dropped by a force push does not come back")
    func rebaseFromForkPoint() async throws {
        let fx = try await Setup()
        defer { fx.sandbox.remove() }
        try await fx.commit("r1.txt", "r1\n", in: fx.up, message: "remote r1")
        try await fx.sandbox.git(["fetch", "-q", "origin"], in: fx.local)
        try await fx.sandbox.git(["branch", "-f", "dev", "origin/dev"], in: fx.local)
        try await fx.commit("a.txt", "a\n", in: fx.local, message: "local a")
        // The upstream drops r1 and gets r2 instead.
        try await fx.sandbox.git(["branch", "-f", "dev", "dev~1"], in: fx.up)
        let remote = try await fx.commit("r2.txt", "r2\n", in: fx.up, message: "remote r2")

        try await fx.ops.pullBranch("dev", remote: "origin", remoteBranch: "dev", mode: .rebase)
        #expect(try await fx.rev("dev^") == remote)
        #expect(try await fx.sandbox.git(["log", "--format=%s", "dev"], in: fx.local) == "local a\nremote r2\ninitial")
    }

    @Test("a git too old for merge-tree or replay: a diverged merge or rebase needs a checkout; dev unchanged",
          arguments: [GitOperations.PullMode.fastForward, .rebase])
    func oldGitNeedsCheckout(mode: GitOperations.PullMode) async throws {
        let fx = try await Setup()
        defer { fx.sandbox.remove() }
        let script = fx.sandbox.root.appending(path: "bin/old-git")
        try Fixtures.writeScript(
            "[ \"$1\" = version ] && { echo 'git version 2.37.1'; exit 0; }\nexec '\(Fixtures.git.path)' \"$@\"",
            to: script)
        let ops = GitOperations(
            runner: GitRunner(executable: script), cwd: fx.local,
            env: GitInvocation.environment(profile: nil, base: fx.sandbox.base), networkTimeout: .seconds(30))
        let mine = try await fx.commit("a.txt", "a\n", in: fx.local, message: "local a")
        try await fx.commit("b.txt", "b\n", in: fx.up, message: "remote b")

        await #expect {
            try await ops.pullBranch("dev", remote: "origin", remoteBranch: "dev", mode: mode)
        } throws: { error in
            if case GitOperationError.pullNeedsCheckout(branch: "dev", let reason) = error {
                reason.contains("2.37.1")
            } else { false }
        }
        #expect(try await fx.rev("dev") == mine)
    }

    @Test("a rebase where commits are signed, or of merge commits, needs a checkout; dev unchanged")
    func rebaseNeedsCheckout() async throws {
        let fx = try await Setup()
        defer { fx.sandbox.remove() }
        try await fx.commit("b.txt", "b\n", in: fx.up, message: "remote b")
        // A merge commit on dev.
        try await fx.sandbox.git(["checkout", "-q", "-b", "side", "dev"], in: fx.local)
        try await fx.sandbox.git(["commit", "-q", "--allow-empty", "-m", "side"], in: fx.local)
        try await fx.sandbox.git(["checkout", "-q", "dev"], in: fx.local)
        try await fx.sandbox.git(["commit", "-q", "--allow-empty", "-m", "dev"], in: fx.local)
        try await fx.sandbox.git(["merge", "-q", "--no-ff", "--no-edit", "side"], in: fx.local)
        try await fx.sandbox.git(["checkout", "-q", "main"], in: fx.local)
        let mine = try await fx.rev("dev")

        let needsCheckout = { (error: any Error) in
            if case GitOperationError.pullNeedsCheckout(branch: "dev", _) = error { true } else { false }
        }
        await #expect {
            try await fx.ops.pullBranch("dev", remote: "origin", remoteBranch: "dev", mode: .rebase)
        } throws: { needsCheckout($0) }
        try await fx.sandbox.git(["config", "commit.gpgSign", "true"], in: fx.local)
        await #expect {
            try await fx.ops.pullBranch("dev", remote: "origin", remoteBranch: "dev", mode: .rebase)
        } throws: { needsCheckout($0) }
        #expect(try await fx.rev("dev") == mine)
    }

    @Test("a branch checked out in a worktree is refused before the fetch")
    func checkedOutInWorktree() async throws {
        let fx = try await Setup()
        defer { fx.sandbox.remove() }
        let mine = try await fx.rev("dev")
        let other = fx.sandbox.root.appending(path: "other", directoryHint: .isDirectory)
        try await fx.sandbox.git(["worktree", "add", "-q", other.path, "dev"], in: fx.local)
        try await fx.commit("b.txt", "b\n", in: fx.up, message: "remote b")

        await #expect {
            try await fx.ops.pullBranch("dev", remote: "origin", remoteBranch: "dev", mode: .fastForward)
        } throws: { error in
            if case GitError.other(_, let message) = error { message.contains("checked out in") } else { false }
        }
        #expect(try await fx.rev("dev") == mine)
        #expect(try await fx.rev("origin/dev") == mine)
    }
}
