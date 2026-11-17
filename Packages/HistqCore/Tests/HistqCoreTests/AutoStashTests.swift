// Safety tests for auto-stash (task 4.2), each on a private copy of the `graph` fixture (which already holds two
// stashes): a checkout whose re-apply conflicts keeps the stash, names it and stays undoable; a checkout on a clean
// tree never pops an older stash; a failed checkout puts the dirty tree back and leaves the stashes as they were;
// a pull whose re-apply conflicts names the kept stash, and one that stops on a conflict reports that git holds
// the changes (abort puts them back, a continue or commit whose re-apply conflicts and a hard reset name the kept
// stash); the plain-apply fallback and an untracked-file collision keep the stash.
import Foundation
import HistqCore
import Testing

struct AutoStashTests {
    /// A fixture copy and journaled operations on its `graph` repo; the journal file lives outside the repo.
    struct Repo {
        let copy: FixtureCopy
        let repo: URL
        let journal: UndoJournal
        let ops: GitOperations

        init() async throws {
            copy = try await Fixtures.copy()
            repo = copy.repo("graph")
            journal = UndoJournal(file: copy.folder.appending(path: "state/undo/graph.json"))
            ops = GitOperations(
                runner: copy.runner, cwd: repo, env: GitInvocation.environment(profile: nil, base: copy.base),
                networkTimeout: .seconds(30), journal: journal)
        }

        @discardableResult
        func git(_ args: [String]) async throws -> String { try await copy.git(args, in: repo) }

        /// Drops the fixture's WIP (the stashes stay).
        func clean() async throws {
            try await git(["reset", "-q", "--hard"])
            try await git(["clean", "-fdq"])
        }

        func write(_ text: String, to path: String) throws {
            try Data(text.utf8).write(to: repo.appending(path: path))
        }

        func read(_ path: String) throws -> String {
            try String(decoding: Data(contentsOf: repo.appending(path: path)), as: UTF8.self)
        }

        func stashes() async throws -> [String] {
            try await git(["stash", "list", "--format=%H"]).split(separator: "\n").map(String.init)
        }

        func unmerged() async throws -> String { try await git(["ls-files", "--unmerged"]) }

        /// HEAD, its branch, the status and both diffs (as in `UndoJournalTests`).
        func state() async throws -> [String] {
            [
                try await git(["rev-parse", "HEAD"]),
                try await git(["symbolic-ref", "-q", "HEAD"]),
                try await git(["status", "--porcelain"]),
                try await git(["diff", "--cached", "--no-ext-diff", "--binary"]),
                try await git(["diff", "--no-ext-diff", "--binary"]),
            ]
        }

        /// Runs `operation`, which must throw `GitError.autostashKept`, and returns the kept stash's hash.
        func kept(_ operation: () async throws -> Void) async throws -> String {
            do {
                try await operation()
            } catch GitError.autostashKept(let hash) {
                return hash
            }
            Issue.record("expected GitError.autostashKept")
            return ""
        }
    }

    @Test("(a) a checkout whose re-apply conflicts keeps the stash, names it and records the checkout")
    func checkoutConflictKeepsStash() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.clean()
        let older = try await fx.stashes()
        // develop adds another line at the end of CHANGELOG.md.
        try fx.write(try fx.read("CHANGELOG.md") + "- local edit\n", to: "CHANGELOG.md")

        let hash = try await fx.kept { try await fx.ops.checkout(branch: "develop", autostash: true) }
        #expect(try await fx.git(["rev-parse", "refs/stash"]) == hash)
        #expect(try await fx.stashes() == [hash] + older)
        #expect(try await fx.git(["symbolic-ref", "HEAD"]) == "refs/heads/develop")
        #expect(try await !fx.unmerged().isEmpty)
        #expect(try fx.journal.load().nextUndo?.kind == .checkout)

        // Once the conflicted file is reset, undo goes back to main and the edit pops back from the kept stash.
        try await fx.git(["checkout", "HEAD", "--", "CHANGELOG.md"])
        #expect(try await fx.git(["status", "--porcelain"]).isEmpty)
        #expect(try await fx.ops.undo().kind == .checkout)
        #expect(try await fx.git(["symbolic-ref", "HEAD"]) == "refs/heads/main")
        try await fx.ops.stashPop(hash)
        #expect(try fx.read("CHANGELOG.md").hasSuffix("- local edit\n"))
        #expect(try await fx.stashes() == older)
    }

    @Test("(b) a checkout on a clean tree never pops an older, unrelated stash")
    func cleanCheckoutLeavesOlderStash() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.clean()
        let older = try await fx.stashes()

        try await fx.ops.checkout(branch: "develop", autostash: true)
        #expect(try await fx.git(["symbolic-ref", "HEAD"]) == "refs/heads/develop")
        #expect(try await fx.stashes() == older)
        #expect(try await fx.git(["status", "--porcelain", "--untracked-files=all"]).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fx.repo.appending(path: "scratch.txt").path))
    }

    @Test("(c) a checkout of a missing branch on a dirty tree throws and leaves the tree and the stashes as before")
    func failedCheckoutRestoresTree() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        // The fixture's WIP: staged, unstaged, renamed, binary and untracked changes, an untracked file named `-rf`.
        let before = try await fx.state()
        let paths = ["README.md", "src/app.swift", "image.bin", "untracked.txt", "-rf"]
        let contents = try paths.map { try Data(contentsOf: fx.repo.appending(path: $0)) }
        let older = try await fx.stashes()

        await #expect {
            try await fx.ops.checkout(branch: "does-not-exist", autostash: true)
        } throws: { error in
            if case GitError.autostashKept = error { false } else { error is GitError }
        }
        #expect(try await fx.state() == before)
        #expect(try paths.map { try Data(contentsOf: fx.repo.appending(path: $0)) } == contents)
        #expect(try await fx.stashes() == older)
    }

    @Test("(d) a fast-forward pull whose re-apply conflicts names the stash git kept")
    func pullConflictKeepsStash() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.clean()
        // feature is one commit behind origin/feature, which changes this line of src/feature.swift.
        try await fx.git(["switch", "-q", "feature"])
        let older = try await fx.stashes()
        try fx.write(try fx.read("src/feature.swift").replacing("print(\"feature\")", with: "print(\"local\")"),
                     to: "src/feature.swift")

        let hash = try await fx.kept { try await fx.ops.pull(.fastForward, autostash: true) }
        #expect(try await fx.stashes() == [hash] + older)
        #expect(try await fx.git(["rev-parse", "HEAD"]) == (try await fx.git(["rev-parse", "origin/feature"])))
        #expect(try await fx.git(["show", "\(hash):src/feature.swift"]).contains("print(\"local\")"))
    }

    @Test(
        "(d) a pull that stops on a conflict reports that git holds the changes, and abort puts them back",
        arguments: [GitOperations.PullMode.fastForward, .rebase])
    func stoppedPullHoldsAutostash(mode: GitOperations.PullMode) async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.clean()
        // A local commit on feature conflicts with origin/feature's; README.md is the local change to stash.
        try await fx.git(["switch", "-q", "feature"])
        try fx.write(try fx.read("src/feature.swift").replacing("print(\"feature\")", with: "print(\"local\")"),
                     to: "src/feature.swift")
        try await fx.git(["commit", "-q", "-am", "Local feature change"])
        let local = try await fx.git(["rev-parse", "HEAD"])
        let older = try await fx.stashes()
        let readme = try fx.read("README.md") + "local edit\n"
        try fx.write(readme, to: "README.md")

        #expect(try await fx.ops.pull(mode, autostash: true) == .autostashPending)
        #expect(try await fx.stashes() == older)
        #expect(try fx.read("README.md") != readme)
        #expect(try await !fx.unmerged().isEmpty)

        try await fx.ops.abortOperation(mode == .rebase ? .rebase : .merge)
        #expect(try fx.read("README.md") == readme)
        #expect(try await fx.git(["rev-parse", "HEAD"]) == local)
        #expect(try await fx.stashes() == older)
    }

    @Test(
        "(d) finishing a stopped pull whose held changes conflict on re-apply names the stash git kept",
        arguments: zip([GitOperations.PullMode.fastForward, .rebase, .fastForward], [false, false, true]))
    func finishedPullKeepsStash(mode: GitOperations.PullMode, commit: Bool) async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.clean()
        // As above; the resolution also stages a README.md edit that conflicts with the held local one.
        try await fx.git(["switch", "-q", "feature"])
        let feature = try fx.read("src/feature.swift")
        try fx.write(feature.replacing("print(\"feature\")", with: "print(\"local\")"), to: "src/feature.swift")
        try await fx.git(["commit", "-q", "-am", "Local feature change"])
        let older = try await fx.stashes()
        let readme = try fx.read("README.md")
        try fx.write(readme + "local edit\n", to: "README.md")

        #expect(try await fx.ops.pull(mode, autostash: true) == .autostashPending)
        try fx.write(feature, to: "src/feature.swift")
        try fx.write(readme + "other edit\n", to: "README.md")
        try await fx.git(["add", "src/feature.swift", "README.md"])

        let hash = try await fx.kept {
            if commit {
                try await fx.ops.commit(message: "Merge origin/feature")
            } else {
                try await fx.ops.continueOperation(mode == .rebase ? .rebase : .merge)
            }
        }
        #expect(try await fx.stashes() == [hash] + older)
        #expect(try await fx.git(["show", "\(hash):README.md"]).contains("local edit"))
        #expect(try await fx.git(["show", "HEAD:README.md"]).contains("other edit"))
    }

    @Test("(d) a hard reset that ends a stopped pull names the stash git saved its held changes in")
    func resetStoppedPullKeepsStash() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.clean()
        // As above; the merge stops and the reset drops its state, which saves MERGE_AUTOSTASH as a new stash.
        try await fx.git(["switch", "-q", "feature"])
        try fx.write(try fx.read("src/feature.swift").replacing("print(\"feature\")", with: "print(\"local\")"),
                     to: "src/feature.swift")
        try await fx.git(["commit", "-q", "-am", "Local feature change"])
        let older = try await fx.stashes()
        let readme = try fx.read("README.md")
        try fx.write(readme + "local edit\n", to: "README.md")

        #expect(try await fx.ops.pull(.fastForward, autostash: true) == .autostashPending)
        let hash = try await fx.kept { try await fx.ops.reset(to: "HEAD", mode: .hard) }
        #expect(try await fx.stashes() == [hash] + older)
        #expect(try await fx.git(["show", "\(hash):README.md"]).contains("local edit"))
        #expect(try fx.read("README.md") == readme)
    }

    @Test("(e) when apply --index refuses, the plain-apply fallback runs and the stash is still kept")
    func plainApplyFallbackKeepsStash() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.clean()
        let original = (1...12).map { "\($0)\n" }
        try fx.write(original.joined(), to: "lines.txt")
        try await fx.git(["add", "lines.txt"])
        try await fx.git(["commit", "-q", "-m", "Add lines"])
        try await fx.git(["switch", "-q", "-c", "other"])
        var other = original
        other[0] = "one on other\n"
        try fx.write(other.joined(), to: "lines.txt")
        try await fx.git(["commit", "-q", "-am", "Change line 1"])
        try await fx.git(["switch", "-q", "main"])
        // Line 2 is staged only (the worktree has it as committed); line 11 is an unstaged edit.
        var staged = original
        staged[1] = "staged only\n"
        try fx.write(staged.joined(), to: "lines.txt")
        try await fx.git(["add", "lines.txt"])
        var worktree = original
        worktree[10] = "eleven local\n"
        try fx.write(worktree.joined(), to: "lines.txt")
        let older = try await fx.stashes()

        let hash = try await fx.kept { try await fx.ops.checkout(branch: "other", autostash: true) }
        #expect(try await fx.stashes() == [hash] + older)
        #expect(try await fx.unmerged().isEmpty)
        // The plain apply put back the worktree edit, not the staged-only line, which only the stash's ^2 holds.
        var expected = other
        expected[10] = "eleven local\n"
        #expect(try fx.read("lines.txt") == expected.joined())
        #expect(try await fx.git(["diff", "--cached"]).isEmpty)
        #expect(try await fx.git(["show", "\(hash)^2:lines.txt"]).contains("staged only"))
    }

    @Test("(f) a re-apply that collides with an untracked file the branch tracks keeps the stash and that file")
    func untrackedCollisionKeepsStash() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.clean()
        try await fx.git(["switch", "-q", "-c", "other"])
        try fx.write("theirs\n", to: "collide.txt")
        try await fx.git(["add", "collide.txt"])
        try await fx.git(["commit", "-q", "-m", "Track collide.txt"])
        try await fx.git(["switch", "-q", "main"])
        try fx.write("mine\n", to: "collide.txt")
        let older = try await fx.stashes()

        let hash = try await fx.kept { try await fx.ops.checkout(branch: "other", autostash: true) }
        #expect(try await fx.stashes() == [hash] + older)
        #expect(try await fx.unmerged().isEmpty)
        #expect(try fx.read("collide.txt") == "theirs\n")
        #expect(try await fx.git(["show", "\(hash)^3:collide.txt"]) == "mine")
    }
}
