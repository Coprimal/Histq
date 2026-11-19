// Key feature and untrusted-input tests for patch files, each on a small temp repo built inline: applying to the
// working tree gives `.applied` (unstaged) for a clean patch, `.conflicts` with unmerged stages for a conflicting one,
// and throws with the tree untouched when git refuses; a conflicting mail series stops as `.am` with a
// "Patch N/M: <subject>" label and abort restores HEAD, while a conflict-free failure leaves no am session (also mid
// series, keeping unrelated local changes); a skip into the next conflict drops the skipped patch's resolves from the
// journal; a non-contiguous multi-commit export applies oldest first, and ignores the user's `format.*` config;
// `validate` refuses NUL bytes, over-cap input and text without a diff header.
import Foundation
import HistqCore
import Testing

struct PatchFileTests {
    /// A temp repo on `main` with a local identity, journaled operations on it (the journal file outside the repo)
    /// and the hermetic environment.
    struct Repo {
        let folder: URL
        let repo: URL
        let base: [String: String]
        let runner = GitRunner(executable: Fixtures.git)
        let journal: UndoJournal
        let ops: GitOperations

        init() async throws {
            folder = try Fixtures.makeTempDirectory("HistqPatch")
            repo = folder.appending(path: "repo", directoryHint: .isDirectory)
            let home = folder.appending(path: "home", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            base = Fixtures.hermeticEnvironment(home: home)
            journal = UndoJournal(file: folder.appending(path: "state/undo.json"))
            ops = GitOperations(
                runner: runner, cwd: repo, env: GitInvocation.environment(profile: nil, base: base),
                networkTimeout: .seconds(30), journal: journal)
            try await git(["init", "-q", "-b", "main"])
            try await git(["config", "user.name", "Patch Test"])
            try await git(["config", "user.email", "patch@histq.invalid"])
        }

        func remove() { Fixtures.removeTempDirectory(folder) }

        @discardableResult
        func git(_ args: [String]) async throws -> String {
            let text = try await runner.run(args, cwd: repo, env: base, timeout: .seconds(30)).text
            return text.hasSuffix("\n") ? String(text.dropLast()) : text
        }

        func write(_ path: String, _ text: String) throws {
            try Data(text.utf8).write(to: repo.appending(path: path))
        }

        func read(_ path: String) throws -> String {
            try String(contentsOf: repo.appending(path: path), encoding: .utf8)
        }

        /// Writes `files`, stages everything and commits; returns the new commit's hash.
        @discardableResult
        func commit(_ message: String, _ files: [String: String]) async throws -> String {
            for (path, text) in files { try write(path, text) }
            try await git(["add", "-A"])
            try await git(["commit", "-q", "-m", message])
            return try await git(["rev-parse", "HEAD"])
        }

        func readEnv() async throws -> [String: String] {
            try await GitInvocation.readEnvironment(profile: nil, base: base, runner: runner, cwd: repo)
        }

        func state() async throws -> RepoState {
            try await RepoState.read(runner: runner, cwd: repo, env: try await readEnv())
        }

        /// The mail series of `hashes` (graph order, newest first).
        func export(_ hashes: [String]) async throws -> Data {
            try await PatchFile.commits(hashes, runner: runner, cwd: repo, env: try await readEnv())
        }
    }

    /// `f.txt` is five lines; `text((index, value))` changes one of them.
    static let lines = ["a", "b", "c", "d", "e"]

    static func text(_ change: (Int, String)? = nil) -> String {
        var lines = lines
        if let (index, value) = change { lines[index] = value }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A repo with `f.txt` committed on main and a patch changing its line 2 to "B" (made from a side commit, so
    /// its blobs exist for a 3-way merge), the tree back on main.
    static func repoWithPatch() async throws -> (Repo, Data) {
        let fx = try await Repo()
        try await fx.commit("Base", ["f.txt": text()])
        try await fx.git(["checkout", "-q", "-b", "topic"])
        try await fx.commit("Change b", ["f.txt": text((1, "B"))])
        let patch = Data((try await fx.git(["diff", "main", "topic"]) + "\n").utf8)
        try await fx.git(["checkout", "-q", "main"])
        return (fx, patch)
    }

    // MARK: - Apply to the working tree

    @Test("a clean patch applies to the working tree unstaged")
    func applyClean() async throws {
        let (fx, patch) = try await Self.repoWithPatch()
        defer { fx.remove() }

        #expect(try await fx.ops.applyPatchToWorkingTree(patch) == .applied)
        #expect(try fx.read("f.txt") == Self.text((1, "B")))
        #expect(try await fx.git(["diff", "--name-only"]) == "f.txt")
        #expect(try await fx.git(["diff", "--cached", "--name-only"]).isEmpty)
    }

    @Test("a conflicting patch falls back to a 3-way merge and leaves unmerged stages")
    func applyConflicts() async throws {
        let (fx, patch) = try await Self.repoWithPatch()
        defer { fx.remove() }
        try await fx.commit("Other b", ["f.txt": Self.text((1, "X"))])

        #expect(try await fx.ops.applyPatchToWorkingTree(patch) == .conflicts)
        let stages = try await fx.git(["ls-files", "-u", "--", "f.txt"]).split(separator: "\n")
        #expect(stages.count == 3)
        #expect(try await fx.state().conflictedPaths == ["f.txt"])
    }

    @Test("a patch git refuses (its file has unstaged edits it does not fit) throws and leaves the tree unchanged")
    func applyRefused() async throws {
        let (fx, patch) = try await Self.repoWithPatch()
        defer { fx.remove() }
        try fx.write("f.txt", Self.text((1, "X")))
        let status = try await fx.git(["status", "--porcelain"])

        await #expect(throws: (any Error).self) { try await fx.ops.applyPatchToWorkingTree(patch) }
        #expect(try fx.read("f.txt") == Self.text((1, "X")))
        #expect(try await fx.git(["status", "--porcelain"]) == status)
        #expect(try await fx.git(["ls-files", "-u"]).isEmpty)
    }

    // MARK: - Apply as commits

    @Test("a conflicting mail series stops as am with a Patch N/M label, and abort restores HEAD")
    func amConflictThenAbort() async throws {
        let fx = try await Repo()
        defer { fx.remove() }
        try await fx.commit("Base", ["a.txt": "a\n", "b.txt": "b\n"])
        try await fx.git(["checkout", "-q", "-b", "topic"])
        let one = try await fx.commit("Change a", ["a.txt": "A1\n"])
        let two = try await fx.commit("Change b", ["b.txt": "B1\n"])
        let series = try await fx.export([two, one])
        try await fx.git(["checkout", "-q", "main"])
        let head = try await fx.commit("Main", ["a.txt": "A2\n"])

        await #expect {
            try await fx.ops.applyMailbox(series, count: 2)
        } throws: { error in
            if case GitError.conflict = error { true } else { false }
        }
        let stopped = try await fx.state()
        #expect(stopped.operation == .am)
        #expect(stopped.conflictedPaths == ["a.txt"])
        #expect(stopped.labels.b == "Patch 1/2: Change a")

        try await fx.ops.abortOperation(.am)
        #expect(try await fx.state().operation == .none)
        #expect(try await fx.git(["rev-parse", "HEAD"]) == head)
        #expect(try await fx.git(["status", "--porcelain"]).isEmpty)
    }

    @Test("an am that fails without conflicts (no blobs for a 3-way merge) throws and leaves no am session")
    func amFailureWithoutConflicts() async throws {
        // The patch comes from an unrelated repo, so its preimage blob is missing here and 3-way cannot run.
        let other = try await Repo()
        defer { other.remove() }
        try await other.commit("Other base", ["f.txt": "one\ntwo\n"])
        let foreign = try await other.export([try await other.commit("Foreign", ["f.txt": "one\nTWO\n"])])

        let fx = try await Repo()
        defer { fx.remove() }
        let head = try await fx.commit("Base", ["f.txt": "other\ncontent\n"])

        await #expect(throws: (any Error).self) { try await fx.ops.applyMailbox(foreign, count: 1) }
        #expect(try await fx.state().operation == .none)
        #expect(try await fx.git(["rev-parse", "HEAD"]) == head)
        #expect(try await fx.git(["status", "--porcelain"]).isEmpty)
    }

    @Test("a series whose second patch fails without conflicts is aborted and keeps unrelated local changes")
    func amSeriesFailureKeepsLocalChanges() async throws {
        // Patch 1 adds a new file (applies anywhere); patch 2 edits a file whose preimage blob is missing here.
        let other = try await Repo()
        defer { other.remove() }
        try await other.commit("Other base", ["f.txt": "one\ntwo\n"])
        let one = try await other.commit("Add n", ["n.txt": "new\n"])
        let two = try await other.commit("Foreign", ["f.txt": "one\nTWO\n"])
        let series = try await other.export([two, one])

        let fx = try await Repo()
        defer { fx.remove() }
        let head = try await fx.commit("Base", ["f.txt": "other\ncontent\n", "u.txt": "unrelated\n"])
        try fx.write("u.txt", "unrelated edit\n")
        try fx.write("x.txt", "untracked\n")
        let unstaged = try Data(contentsOf: fx.repo.appending(path: "u.txt"))
        let untracked = try Data(contentsOf: fx.repo.appending(path: "x.txt"))

        await #expect(throws: (any Error).self) { try await fx.ops.applyMailbox(series, count: 2) }
        #expect(try await fx.state().operation == .none)
        #expect(try await fx.git(["rev-parse", "HEAD"]) == head)
        // Patch 1 was committed before patch 2 stopped the am, and the abort undid it.
        #expect(try await fx.git(["reflog", "--format=%gs"]).contains("am: Add n"))
        #expect(try Data(contentsOf: fx.repo.appending(path: "u.txt")) == unstaged)
        #expect(try Data(contentsOf: fx.repo.appending(path: "x.txt")) == untracked)
        #expect(!FileManager.default.fileExists(atPath: fx.repo.appending(path: "n.txt").path))
        #expect(try await fx.git(["status", "--porcelain"]) == " M u.txt\n?? x.txt")
    }

    @Test("a skip into the next conflicting patch drops the skipped patch's resolves from the journal")
    func amSkipDropsResolves() async throws {
        let fx = try await Repo()
        defer { fx.remove() }
        try await fx.commit("Base", ["a.txt": "a\n", "b.txt": "b\n"])
        try await fx.git(["checkout", "-q", "-b", "topic"])
        let one = try await fx.commit("Change a", ["a.txt": "A1\n"])
        let two = try await fx.commit("Change b", ["b.txt": "B1\n"])
        let series = try await fx.export([two, one])
        try await fx.git(["checkout", "-q", "main"])
        try await fx.commit("Main", ["a.txt": "A2\n", "b.txt": "B2\n"])

        await #expect(throws: (any Error).self) { try await fx.ops.applyMailbox(series, count: 2) }
        try await fx.ops.resolve(path: "a.txt", content: Data("resolved\n".utf8))
        #expect(try await fx.journal.load(fx.ops).nextResolveUndo != nil)

        // HEAD stays the same across the skip: only the patch number tells the two stops apart.
        await #expect(throws: (any Error).self) { try await fx.ops.skipOperation(.am) }
        let second = try await fx.state()
        #expect(second.operation == .am)
        #expect(second.conflictedPaths == ["b.txt"])
        #expect(second.labels.b == "Patch 2/2: Change b")
        #expect(try await fx.journal.load(fx.ops).nextResolveUndo == nil)
    }

    @Test("a non-contiguous selection given newest first exports a series that lands oldest first")
    func multiCommitExport() async throws {
        let fx = try await Repo()
        defer { fx.remove() }
        let base = try await fx.commit("Base", ["base.txt": "base\n"])
        let one = try await fx.commit("One", ["one.txt": "1\n"])
        try await fx.commit("Two", ["two.txt": "2\n"])
        let three = try await fx.commit("Three", ["three.txt": "3\n"])

        let series = try await fx.export([three, one])
        #expect(PatchFile.isMailbox(series))
        #expect(PatchFile.mailCount(series) == 2)

        try await fx.git(["checkout", "-q", "-b", "target", base])
        try await fx.ops.applyMailbox(series, count: PatchFile.mailCount(series))
        #expect(try await fx.git(["log", "--reverse", "--format=%s", "\(base)..HEAD"]) == "One\nThree")
        #expect(try await fx.git(["ls-files"]) == "base.txt\none.txt\nthree.txt")
    }

    @Test("an export ignores format.coverLetter, format.signOff and format.useAutoBase and still applies")
    func exportIgnoresFormatConfig() async throws {
        let fx = try await Repo()
        defer { fx.remove() }
        try await fx.git(["config", "format.coverLetter", "true"])
        try await fx.git(["config", "format.signOff", "true"])
        try await fx.git(["config", "format.useAutoBase", "true"])
        let base = try await fx.commit("Base", ["base.txt": "base\n"])
        let one = try await fx.commit("One", ["one.txt": "1\n"])
        let two = try await fx.commit("Two", ["two.txt": "2\n"])

        let series = try await fx.export([two, one])
        let text = String(decoding: series, as: UTF8.self)
        #expect(PatchFile.mailCount(series) == 2)
        #expect(!text.contains("Signed-off-by:"))
        #expect(!text.contains("base-commit:"))

        try await fx.git(["checkout", "-q", "-b", "target", base])
        try await fx.ops.applyMailbox(series, count: PatchFile.mailCount(series))
        #expect(try await fx.git(["log", "--reverse", "--format=%s", "\(base)..HEAD"]) == "One\nTwo")
    }

    // MARK: - Untrusted input

    @Test("validate refuses NUL bytes, over-cap input and text without a diff header")
    func validateRefusesBadInput() throws {
        let diff = Data("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+b\n".utf8)
        #expect(try PatchFile.validate(diff) == diff)
        #expect(throws: PatchFile.InputError.notText) { try PatchFile.validate(diff + [0]) }
        #expect(throws: PatchFile.InputError.tooLarge) { try PatchFile.validate(Data(count: PatchFile.maxBytes + 1)) }
        #expect(throws: PatchFile.InputError.noDiff) { try PatchFile.validate(Data("just some text\n".utf8)) }
    }
}
