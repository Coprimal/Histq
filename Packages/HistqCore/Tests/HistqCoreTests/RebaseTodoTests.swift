// Key feature and security tests for the interactive rebase todo (task 9.2), on a fixture copy whose `graph` repo
// is first cleaned with `git stash -u` and switched to `series` (five commits "Series step 1" to "Series step 5" on
// top of the v1.0 merge): reorder + fixup + reword give the expected subjects; a squash runs from a folder whose path
// holds a space and a single quote (shell quoting of the sequence editor and the exec lines); a squash with staged and
// unstaged changes keeps both through it, its undo and redo; with local changes, a rebase that stops at an edit or on
// a conflict holds them until continue or abort, and ones that do not go back cleanly stay in a stash; merge and non-contiguous selections are refused; a root commit
// rebases with `--root`.
import Foundation
import HistqCore
import Testing

struct RebaseTodoTests {
    struct Repo {
        let copy: FixtureCopy
        let repo: URL
        let ops: GitOperations
        /// The commit `series` starts from (the v1.0 merge).
        let base: String

        init() async throws {
            copy = try await Fixtures.copy()
            repo = copy.repo("graph")
            ops = GitOperations(
                runner: copy.runner, cwd: repo, env: GitInvocation.environment(profile: nil, base: copy.base),
                networkTimeout: .seconds(30))
            try await copy.git(["stash", "-u"], in: repo)
            try await copy.git(["switch", "-q", "series"], in: repo)
            base = try await copy.git(["rev-parse", "series~5"], in: repo)
        }

        @discardableResult
        func git(_ args: [String]) async throws -> String { try await copy.git(args, in: repo) }

        func readEnv() async throws -> [String: String] {
            try await GitInvocation.readEnvironment(profile: nil, base: copy.base, runner: copy.runner, cwd: repo)
        }

        /// The subjects of the branch's commits after `base`, oldest first.
        func subjects() async throws -> [String] {
            try await git(["log", "--reverse", "--format=%s", "\(base)..HEAD"]).split(separator: "\n").map(String.init)
        }

        /// Operations on the repo with an undo journal (outside the repo).
        func journaled() -> GitOperations {
            GitOperations(
                runner: copy.runner, cwd: repo, env: GitInvocation.environment(profile: nil, base: copy.base),
                networkTimeout: .seconds(30), journal: UndoJournal(file: copy.folder.appending(path: "undo.json")))
        }

        /// A staged change to `docs/step-1.md` and an unstaged one to `docs/step-2.md`.
        func dirty() async throws {
            try "staged\n".write(to: repo.appending(path: "docs/step-1.md"), atomically: true, encoding: .utf8)
            try await git(["add", "docs/step-1.md"])
            try "unstaged\n".write(to: repo.appending(path: "docs/step-2.md"), atomically: true, encoding: .utf8)
        }

        /// A new folder for the rebase files inside this copy.
        func folder(_ name: String) throws -> URL {
            let url = copy.folder.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }

    @Test("reorder, fixup and reword in one todo give the expected subjects and keep every change")
    func reorderFixupReword() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        let tree = try await fx.git(["rev-parse", "HEAD^{tree}"])
        let step1 = try await fx.git(["rev-parse", "series~4"])
        var todo = try await RebaseTodo.fromCommit(step1, runner: fx.copy.runner, cwd: fx.repo, env: try await fx.readEnv())
        #expect(todo.items.map(\.subject) == (1...5).map { "Series step \($0)" })
        #expect(todo.base == .parent(fx.base))

        var items = todo.items
        items[1].action = .fixup
        items[3].action = .reword
        items[3].newMessage = "Step four, reworded\n\nWith a body."
        // Step 2 is moved after step 3 and folds into it.
        todo.items = [items[0], items[2], items[1], items[3], items[4]]
        try await fx.ops.interactiveRebase(todo, files: try fx.folder("rebase"))

        #expect(try await fx.subjects() == ["Series step 1", "Series step 3", "Step four, reworded", "Series step 5"])
        #expect(try await fx.git(["log", "-1", "--format=%B", "HEAD~1"]) == "Step four, reworded\n\nWith a body.\n")
        #expect(try await fx.git(["show", "--name-only", "--format=", "HEAD~2"]) == "docs/step-2.md\ndocs/step-3.md")
        #expect(try await fx.git(["rev-parse", "HEAD^{tree}"]) == tree)
        #expect(try await fx.git(["status", "--porcelain"]).isEmpty)
    }

    @Test("a squash with the default message runs from a folder whose path has a space and a single quote")
    func squashInQuotedFolder() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        let selected = try await [fx.git(["rev-parse", "series"]), fx.git(["rev-parse", "series~2"]),
                                  fx.git(["rev-parse", "series~1"])]
        var todo = try await RebaseTodo.squash(selected, runner: fx.copy.runner, cwd: fx.repo, env: try await fx.readEnv())
        let message = "Series step 3\n\nSeries step 4\n\nSeries step 5"
        #expect(todo.items.first?.newMessage == message)
        #expect(todo.items.map(\.action) == [.pick, .squash, .squash])
        // An edited message differs from git's own squash message, so it proves the quoted exec line ran.
        let edited = "Steps 3 to 5, it's squashed\n\n" + message
        todo.items[0].newMessage = edited

        let folder = try fx.folder("it's a rebase folder")
        try await fx.ops.interactiveRebase(todo, files: folder)

        #expect(try await fx.subjects() == ["Series step 1", "Series step 2", "Steps 3 to 5, it's squashed"])
        #expect(try await fx.git(["log", "-1", "--format=%B"]) == edited + "\n")
        #expect(try await fx.git(["status", "--porcelain"]).isEmpty)
    }

    @Test("a squash with staged and unstaged changes keeps both, staged or not, through the squash, its undo and redo")
    func squashWithLocalChanges() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        let ops = fx.journaled()
        try await fx.dirty()
        let status = try await fx.git(["status", "--porcelain", "--untracked-files=no"])
        let diff = try await fx.git(["diff", "HEAD"])
        let stashes = try await fx.git(["stash", "list"])
        let head = try await fx.git(["rev-parse", "HEAD"])
        let selected = try await [fx.git(["rev-parse", "series"]), fx.git(["rev-parse", "series~1"])]
        let todo = try await RebaseTodo.squash(selected, runner: fx.copy.runner, cwd: fx.repo, env: try await fx.readEnv())

        #expect(try await ops.interactiveRebase(todo, files: try fx.folder("rebase")) == false)
        let squashed = try await fx.git(["rev-parse", "HEAD"])
        #expect(try await fx.subjects().count == 4)
        #expect(try await fx.git(["status", "--porcelain", "--untracked-files=no"]) == status)
        #expect(try await fx.git(["diff", "HEAD"]) == diff)
        #expect(try await fx.git(["stash", "list"]) == stashes)

        try await ops.undo()
        #expect(try await fx.git(["rev-parse", "HEAD"]) == head)
        #expect(try await fx.git(["status", "--porcelain", "--untracked-files=no"]) == status)
        try await ops.redo()
        #expect(try await fx.git(["rev-parse", "HEAD"]) == squashed)
        #expect(try await fx.git(["status", "--porcelain", "--untracked-files=no"]) == status)
        #expect(try await fx.git(["diff", "HEAD"]) == diff)
    }

    @Test("an interactive rebase with local changes that stops at an edit holds them until it continues")
    func editStopWithLocalChanges() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.dirty()
        let diff = try await fx.git(["diff", "HEAD"])
        let stashes = try await fx.git(["stash", "list"])
        var todo = try await RebaseTodo.fromCommit(
            try await fx.git(["rev-parse", "series~1"]), runner: fx.copy.runner, cwd: fx.repo, env: try await fx.readEnv())
        todo.items[0].action = .edit

        let ops = fx.journaled()
        #expect(try await ops.interactiveRebase(todo, files: try fx.folder("rebase")))
        #expect(try await fx.git(["status", "--porcelain", "--untracked-files=no"]).isEmpty)
        try await ops.continueOperation(.rebase)

        #expect(try await fx.subjects() == (1...5).map { "Series step \($0)" })
        #expect(try await fx.git(["diff", "HEAD"]) == diff)
        #expect(try await fx.git(["stash", "list"]) == stashes)
    }

    @Test("an interactive rebase with local changes that stops on a conflict holds them; abort puts them back")
    func conflictWithLocalChanges() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        for text in ["first", "second"] {
            try "\(text)\n".write(to: fx.repo.appending(path: "clash.txt"), atomically: true, encoding: .utf8)
            try await fx.git(["add", "clash.txt"])
            try await fx.git(["commit", "-q", "-m", "Clash \(text)"])
        }
        try await fx.dirty()
        let head = try await fx.git(["rev-parse", "HEAD"])
        let diff = try await fx.git(["diff", "HEAD"])
        let stashes = try await fx.git(["stash", "list"])
        var todo = try await RebaseTodo.fromCommit(
            try await fx.git(["rev-parse", "HEAD~1"]), runner: fx.copy.runner, cwd: fx.repo, env: try await fx.readEnv())
        todo.items[0].action = .drop

        #expect(try await fx.ops.interactiveRebase(todo, files: try fx.folder("rebase")))
        #expect(try await fx.git(["status", "--porcelain", "--untracked-files=no"]) == "DU clash.txt")
        try await fx.ops.abortOperation(.rebase)

        #expect(try await fx.git(["rev-parse", "HEAD"]) == head)
        #expect(try await fx.git(["diff", "HEAD"]) == diff)
        #expect(try await fx.git(["stash", "list"]) == stashes)
    }

    @Test("a rebase whose local changes do not go back cleanly keeps them in a stash and throws autostashKept")
    func keptAutostash() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        // A change to the file the dropped commit adds: putting it back conflicts, so git keeps it in a stash.
        try "changed\n".write(to: fx.repo.appending(path: "docs/step-5.md"), atomically: true, encoding: .utf8)
        let stashes = try await fx.git(["stash", "list"]).split(separator: "\n").count
        var todo = try await RebaseTodo.fromCommit(
            try await fx.git(["rev-parse", "series"]), runner: fx.copy.runner, cwd: fx.repo, env: try await fx.readEnv())
        todo.items[0].action = .drop

        var kept: String?
        do {
            try await fx.ops.interactiveRebase(todo, files: try fx.folder("rebase"))
        } catch GitError.autostashKept(let hash) {
            kept = hash
        }

        #expect(kept == (try await fx.git(["rev-parse", "refs/stash"])))
        #expect(try await fx.git(["stash", "list"]).split(separator: "\n").count == stashes + 1)
        #expect(try await fx.subjects() == (1...4).map { "Series step \($0)" })
    }

    @Test("a selection with a merge commit or with commits that do not follow each other is refused")
    func refusedSelections() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        let env = try await fx.readEnv()
        let step1 = try await fx.git(["rev-parse", "series~4"])
        await #expect(throws: RebaseTodoError.mergeCommit(fx.base)) {
            try await RebaseTodo.squash([fx.base, step1], runner: fx.copy.runner, cwd: fx.repo, env: env)
        }
        await #expect(throws: RebaseTodoError.mergeCommit(fx.base)) {
            try await RebaseTodo.fromCommit(fx.base, runner: fx.copy.runner, cwd: fx.repo, env: env)
        }
        let gapped = try await [fx.git(["rev-parse", "series~3"]), fx.git(["rev-parse", "series~1"])]
        await #expect(throws: RebaseTodoError.nonContiguousSelection) {
            try await RebaseTodo.squash(gapped, runner: fx.copy.runner, cwd: fx.repo, env: env)
        }
        await #expect(throws: RebaseTodoError.invalidObjectID("--root")) {
            try await RebaseTodo.fromCommit("--root", runner: fx.copy.runner, cwd: fx.repo, env: env)
        }
    }

    @Test("from a root commit the rebase arguments use --root and never name the commit's parent")
    func rootCommitArguments() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.git(["switch", "-q", "--orphan", "solo"])
        try await fx.git(["commit", "-q", "--allow-empty", "-m", "Solo root"])
        try await fx.git(["commit", "-q", "--allow-empty", "-m", "Solo second"])
        let root = try await fx.git(["rev-parse", "HEAD~1"])

        let todo = try await RebaseTodo.fromCommit(root, runner: fx.copy.runner, cwd: fx.repo, env: try await fx.readEnv())
        #expect(todo.base == .root)
        #expect(todo.items.map(\.subject) == ["Solo root", "Solo second"])
        #expect(todo.arguments == ["-c", "core.editor=true", "rebase", "-i", "--autostash", "--root"])
        #expect(!todo.arguments.contains { $0.contains("^") || $0.contains(root) })
    }
}
