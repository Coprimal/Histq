// Key feature tests for the undo journal (task 9.1), each on a private copy of the dirty `graph` fixture (staged,
// unstaged, renamed, binary and untracked changes, an untracked file named `-rf`): undo of a commit, a discard and
// a branch delete puts the whole state back (HEAD, branch, index, files), a discard made from a subfolder too; redo
// replays a commit; undo and redo of tags (an annotated one comes back as the same tag object) and of a stage; a stage
// between two commits is undone in turn, and one the index moved on from (a staged line, a terminal `git add`) is
// skipped, by redo and in the history Undo shows too, but never lets a checkout under it run; an unstage all that ends
// a stopped pull names the stash git saved; undo of a stash save puts the stashed paths back (a partial one leaves another
// staged and edited file alone) and drops only that stash, undo of a drop stores it back (during a stopped merge too),
// an empty push and an auto-stash record nothing; undo of a stash apply keeps a staged edit in another hunk of the
// applied file and other files' changes, brings back a path the stash renamed, and redo applies again; undo of a pop
// stores the stash back once; a conflicting apply or pop, or one whose edit lands in a file renamed since, records
// nothing (a pop keeps its stash), and one during a stopped merge keeps the merge's pending undo; undo refuses once a
// commit was made outside Histq or a stashed or applied file was edited, and refuses a tampered journal (a path into
// `.git`, an upstream that is no remote name, a bad tag name or hash, a short stash hash) unchanged. On the `conflict`
// fixture: undo of a resolved file brings back its stages and markers and redo resolves it again, undo refuses once the
// resolved file was edited, and resolves undone and redone during a merge Histq started keep the merge's own undo.
import Foundation
import HistqCore
import Testing

struct UndoJournalTests {
    /// A fixture copy and journaled operations on one of its repos (`graph` by default); the journal file lives
    /// outside the repo.
    struct Repo {
        let copy: FixtureCopy
        let repo: URL
        let journal: UndoJournal
        let ops: GitOperations

        /// `folder`: the operations run in this subfolder of the repo (as when a subfolder was opened).
        init(folder: String? = nil, fixture: String = "graph") async throws {
            copy = try await Fixtures.copy()
            let repo = copy.repo(fixture)
            self.repo = repo
            journal = UndoJournal(file: copy.folder.appending(path: "state/undo/graph.json"))
            ops = GitOperations(
                runner: copy.runner, cwd: folder.map { repo.appending(path: $0, directoryHint: .isDirectory) } ?? repo,
                env: GitInvocation.environment(profile: nil, base: copy.base), networkTimeout: .seconds(30),
                journal: journal)
        }

        /// Edits the journal file as an attacker could: every string value `old` becomes `new`.
        func tamper(_ old: String, with new: String) throws {
            func swap(_ value: Any) -> Any {
                switch value {
                case let text as String: text == old ? new : text
                case let array as [Any]: array.map(swap)
                case let object as [String: Any]: object.mapValues(swap)
                default: value
                }
            }
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: journal.file))
            try JSONSerialization.data(withJSONObject: swap(json)).write(to: journal.file)
        }

        func exists(_ path: String) -> Bool {
            var info = stat()
            return lstat(repo.appending(path: path).path, &info) == 0
        }

        @discardableResult
        func git(_ args: [String]) async throws -> String { try await copy.git(args, in: repo) }

        /// HEAD, the branch it is on, the status (staged, unstaged and untracked) and both diffs: equal states
        /// mean the index and the files came back too, not just the commit.
        func state() async throws -> [String] {
            [
                try await git(["rev-parse", "HEAD"]),
                try await git(["symbolic-ref", "-q", "HEAD"]),
                try await git(["status", "--porcelain"]),
                try await git(["diff", "--cached", "--no-ext-diff", "--binary"]),
                try await git(["diff", "--no-ext-diff", "--binary"]),
            ]
        }

        func bytes(_ path: String) throws -> Data { try Data(contentsOf: repo.appending(path: path)) }

        func stashes() async throws -> [String] {
            try await git(["stash", "list", "--format=%H"]).split(separator: "\n").map(String.init)
        }

        /// Stages the first changed line of `path` as line staging does (`PatchBuilder`, not journaled).
        func stageFirstLine(_ path: String) async throws {
            let readEnv = try await GitInvocation.readEnvironment(
                profile: nil, base: copy.base, runner: copy.runner, cwd: repo)
            let file = try #require(
                try await DiffReader.unstaged(runner: copy.runner, cwd: repo, env: readEnv, paths: [path]).first)
            let patch = try PatchBuilder.patch(for: file, selecting: Set(file.changedLineIDs.prefix(1)), action: .stage)
            try await PatchBuilder.apply(patch, action: .stage, runner: copy.runner, cwd: repo, env: ops.env)
        }
    }

    @Test("undo of a commit moves the branch back and the committed changes are staged again")
    func undoCommit() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        let before = try await fx.state()

        try await fx.ops.commit(message: "Commit to undo")
        #expect(try await fx.git(["log", "-1", "--format=%s"]) == "Commit to undo")
        #expect(try fx.journal.load().nextUndo?.kind == .commit)

        let undone = try await fx.ops.undo()
        #expect(undone.kind == .commit)
        #expect(try await fx.state() == before)
        #expect(try fx.journal.load().nextRedo?.id == undone.id)
    }

    @Test("undo of a discard of everything brings back the tracked and untracked files and the index")
    func undoDiscard() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        let before = try await fx.state()
        let paths = ["README.md", "src/app.swift", "image.bin", "untracked.txt", "-rf"]
        let contents = try paths.map(fx.bytes)

        try await fx.ops.discardAll(includingUntracked: true)
        #expect(try await fx.git(["status", "--porcelain"]).isEmpty)

        try await fx.ops.undo()
        #expect(try await fx.state() == before)
        #expect(try paths.map(fx.bytes) == contents)
    }

    @Test("undo of a discard of everything made from a subfolder brings back the changes outside it too")
    func undoDiscardFromSubfolder() async throws {
        let fx = try await Repo(folder: "src")
        defer { fx.copy.remove() }
        try Data("untracked in src\n".utf8).write(to: fx.repo.appending(path: "src/new.txt"))
        let before = try await fx.state()
        let paths = ["README.md", "no-newline.txt", "image.bin", "src/app.swift", "src/new.txt", "untracked.txt", "-rf"]
        let contents = try paths.map(fx.bytes)

        try await fx.ops.discardAll(includingUntracked: true)
        // `reset --hard` reset the whole worktree, `clean` only the subfolder.
        #expect(try await fx.git(["status", "--porcelain"]).split(separator: "\n").sorted() == ["?? -rf", "?? untracked.txt"])

        try await fx.ops.undo()
        #expect(try await fx.state() == before)
        #expect(try paths.map(fx.bytes) == contents)
    }

    @Test("undo of a discard of one file made from a subfolder brings that file back")
    func undoPartialDiscardFromSubfolder() async throws {
        let fx = try await Repo(folder: "src")
        defer { fx.copy.remove() }
        let before = try await fx.state()
        let readme = try fx.bytes("README.md")
        let app = try fx.bytes("src/app.swift")

        try await fx.ops.discard(["app.swift"])
        #expect(try fx.bytes("src/app.swift") != app)
        #expect(try fx.bytes("README.md") == readme)

        try await fx.ops.undo()
        #expect(try await fx.state() == before)
        #expect(try fx.bytes("src/app.swift") == app)
    }

    @Test("undo refuses a tampered journal whose untracked file would land in a .git folder, writing nothing",
          arguments: [".GIT/hooks/x", "sub/.git/hooks/x"])
    func undoRefusesGitFolderPath(_ path: String) async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        // A discard that also moved the index: a refusal after `read-tree` would show in `state()`.
        try await fx.ops.discardAll(includingUntracked: true)
        try fx.tamper("untracked.txt", with: path)
        let after = try await fx.state()

        await #expect(throws: UndoError.unsafePath(path)) { try await fx.ops.undo() }
        #expect(try await fx.state() == after)
        #expect(!fx.exists(".git/hooks/x") && !fx.exists("sub") && !fx.exists("untracked.txt"))
        #expect(try fx.journal.load().nextUndo != nil)
    }

    @Test("undo refuses a tampered journal whose branch upstream is not a remote name, writing nothing")
    func undoRefusesBadUpstreamRemote() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.ops.deleteBranch("feature", force: true)
        try fx.tamper("origin", with: "ext::sh -c touch% pwned")

        await #expect(throws: UndoError.unreadableJournal) { try await fx.ops.undo() }
        #expect(try await fx.git(["branch", "--list", "feature"]).isEmpty)
        #expect((try? await fx.git(["config", "--get", "branch.feature.remote"])) == nil)
        #expect(try fx.journal.load().nextUndo != nil)
    }

    @Test("undo of a branch delete recreates the branch at its commit with its upstream")
    func undoBranchDelete() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        let commit = try await fx.git(["rev-parse", "refs/heads/feature"])
        let upstream = try await fx.git(["rev-parse", "--abbrev-ref", "feature@{upstream}"])

        try await fx.ops.deleteBranch("feature", force: true)
        #expect(try await fx.git(["branch", "--list", "feature"]).isEmpty)

        try await fx.ops.undo()
        #expect(try await fx.git(["rev-parse", "refs/heads/feature"]) == commit)
        #expect(try await fx.git(["rev-parse", "--abbrev-ref", "feature@{upstream}"]) == upstream)
    }

    @Test("undo of a tag create deletes the tag; redo creates it again at the same commit")
    func undoRedoCreateTag() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        let head = try await fx.git(["rev-parse", "HEAD"])

        try await fx.ops.createTag("undo-me", at: "HEAD")
        #expect(try fx.journal.load().nextUndo?.title == "Create tag undo-me")

        #expect(try await fx.ops.undo().kind == .createTag)
        #expect(try await fx.git(["tag", "--list", "undo-me"]).isEmpty)
        #expect(try await fx.ops.redo().kind == .createTag)
        #expect(try await fx.git(["rev-parse", "refs/tags/undo-me"]) == head)
    }

    @Test("undo of an annotated tag create deletes it; redo puts back the same tag object")
    func undoRedoCreateAnnotatedTag() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.ops.createTag("annotated", at: "HEAD", message: "Release notes")
        let object = try await fx.git(["rev-parse", "refs/tags/annotated"])
        #expect(try await fx.git(["cat-file", "-t", object]) == "tag")

        try await fx.ops.undo()
        #expect(try await fx.git(["tag", "--list", "annotated"]).isEmpty)
        try await fx.ops.redo()
        #expect(try await fx.git(["rev-parse", "refs/tags/annotated"]) == object)
    }

    @Test("undo of an annotated tag delete puts back the same tag object")
    func undoDeleteAnnotatedTag() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        let object = try await fx.git(["rev-parse", "refs/tags/v1.0"])
        #expect(try await fx.git(["cat-file", "-t", object]) == "tag")

        try await fx.ops.deleteTag("v1.0")
        #expect(try await fx.git(["tag", "--list", "v1.0"]).isEmpty)

        #expect(try await fx.ops.undo().kind == .deleteTag)
        #expect(try await fx.git(["rev-parse", "refs/tags/v1.0"]) == object)
    }

    @Test("undo refuses a tampered journal with a bad tag name or tag hash, writing nothing",
          arguments: ["refs/tags/a..b", "refs/tags/-x", "refs/tags/x\nupdate refs/heads/main HEAD", "not-a-hash"])
    func undoRefusesBadTag(_ bad: String) async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        let object = try await fx.git(["rev-parse", "refs/tags/v1.0"])
        try await fx.ops.deleteTag("v1.0")
        try fx.tamper(bad.hasPrefix("refs/") ? "refs/tags/v1.0" : object, with: bad)
        let after = try await fx.git(["for-each-ref"])

        await #expect(throws: UndoError.unreadableJournal) { try await fx.ops.undo() }
        #expect(try await fx.git(["for-each-ref"]) == after)
        #expect(try fx.journal.load().nextUndo != nil)
    }

    @Test("redo after undoing a commit puts the same commit back with the same state")
    func redoCommit() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.ops.commit(message: "Commit to redo")
        let committed = try await fx.state()

        try await fx.ops.undo()
        #expect(try await fx.state() != committed)
        let redone = try await fx.ops.redo()
        #expect(redone.kind == .commit)
        #expect(try await fx.state() == committed)
        #expect(try fx.journal.load().nextRedo == nil)
    }

    @Test("a stage between two commits is undone in turn: commit, stage, commit")
    func undoCommitsAcrossStaging() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        let head = try await fx.git(["rev-parse", "HEAD"])
        let stagedBefore = try await fx.git(["diff", "--cached", "--name-only"])
        #expect(!stagedBefore.contains("README.md"))

        try await fx.ops.commit(message: "First commit")
        // Journaled too: its entry sits between the two commits.
        try await fx.ops.stage(["README.md"])
        try await fx.ops.commit(message: "Second commit")

        #expect(try await fx.ops.undo().title == "Commit \"Second commit\"")
        #expect(try await fx.ops.undo().kind == .stage)
        #expect(try await fx.ops.undo().title == "Commit \"First commit\"")
        #expect(try await fx.git(["rev-parse", "HEAD"]) == head)
        #expect(try await fx.git(["diff", "--cached", "--name-only"]) == stagedBefore)
    }

    @Test("undo of a stage puts the index back; redo stages again")
    func undoRedoStage() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        let before = try await fx.git(["write-tree"])
        try await fx.ops.stage(["README.md"])
        let staged = try await fx.git(["write-tree"])
        #expect(staged != before)

        #expect(try await fx.ops.undo().kind == .stage)
        #expect(try await fx.git(["write-tree"]) == before)
        #expect(try await fx.ops.redo().kind == .stage)
        #expect(try await fx.git(["write-tree"]) == staged)
    }

    @Test("a stage the index moved on from (a staged line, a terminal git add) is skipped: undo takes the commit under it",
          arguments: [true, false])
    func undoSkipsStaleStage(lineStage: Bool) async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        let head = try await fx.git(["rev-parse", "HEAD"])
        try await fx.ops.commit(message: "First commit")
        try await fx.ops.stage(["no-newline.txt"])
        if lineStage { try await fx.stageFirstLine("README.md") } else { try await fx.git(["add", "--", "README.md"]) }
        let index = try await fx.git(["write-tree"])

        #expect(try await fx.ops.undo().title == "Commit \"First commit\"")
        #expect(try await fx.git(["rev-parse", "HEAD"]) == head)
        #expect(try await fx.git(["write-tree"]) == index, "what was staged stays staged")
        #expect(try fx.journal.load().nextUndo == nil)
        #expect(try fx.journal.load().nextRedo?.kind == .commit)
    }

    @Test("redo skips an undone stage the index moved on from and redoes the commit under it")
    func redoSkipsStaleStage() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.ops.stage(["README.md"])
        try await fx.ops.commit(message: "Staged commit")
        let committed = try await fx.git(["rev-parse", "HEAD"])
        try await fx.ops.undo()
        #expect(try await fx.ops.undo().kind == .stage)
        try await fx.git(["add", "--", "no-newline.txt"])
        let index = try await fx.git(["write-tree"])

        #expect(try await fx.ops.redo().title == "Commit \"Staged commit\"")
        #expect(try await fx.git(["rev-parse", "HEAD"]) == committed)
        #expect(try await fx.git(["write-tree"]) == index)
        #expect(try fx.journal.load().nextRedo == nil)
    }

    @Test("the history Undo shows names the commit under a stale stage, and a fresh stage as itself")
    func historySkipsStaleStage() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.ops.commit(message: "First commit")
        try await fx.ops.stage(["no-newline.txt"])
        #expect(try await fx.journal.load(fx.ops).nextUndo?.kind == .stage)

        try await fx.stageFirstLine("README.md")
        let file = try Data(contentsOf: fx.journal.file)
        #expect(try await fx.journal.load(fx.ops).nextUndo?.title == "Commit \"First commit\"")
        #expect(try fx.journal.load().nextUndo?.kind == .stage, "reading drops nothing from the file")
        #expect(try Data(contentsOf: fx.journal.file) == file)
    }

    @Test("a stale stage over a checkout is skipped, but the checkout still refuses and nothing changes")
    func staleStageOverCheckoutRefuses() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.git(["reset", "-q", "--hard"])
        try await fx.git(["clean", "-fdq"])
        try await fx.ops.checkout(branch: "feature")
        try Data("notes\n".utf8).write(to: fx.repo.appending(path: "notes.txt"))
        try Data("more\n".utf8).write(to: fx.repo.appending(path: "more.txt"))
        try await fx.ops.stage(["notes.txt"])
        try await fx.git(["add", "--", "more.txt"])
        let state = try await fx.state()
        let journal = try Data(contentsOf: fx.journal.file)

        await #expect(throws: UndoError.repositoryChanged) { try await fx.ops.undo() }
        #expect(try await fx.state() == state)
        #expect(try Data(contentsOf: fx.journal.file) == journal)
    }

    @Test("unstage all ending a stopped pull names the stash git saved its held changes in; stage and unstage do not")
    func unstageAllEndingStoppedPullKeepsStash() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.git(["reset", "-q", "--hard"])
        try await fx.git(["clean", "-fdq"])
        // As in `AutoStashTests`: a local commit on feature conflicts with origin/feature's; README.md is held.
        try await fx.git(["switch", "-q", "feature"])
        let feature = String(decoding: try fx.bytes("src/feature.swift"), as: UTF8.self)
        try Data(feature.replacing("print(\"feature\")", with: "print(\"local\")").utf8)
            .write(to: fx.repo.appending(path: "src/feature.swift"))
        try await fx.git(["commit", "-q", "-am", "Local feature change"])
        let older = try await fx.git(["stash", "list", "--format=%H"])
        let readme = String(decoding: try fx.bytes("README.md"), as: UTF8.self)
        try Data((readme + "local edit\n").utf8).write(to: fx.repo.appending(path: "README.md"))
        #expect(try await fx.ops.pull(.fastForward, autostash: true) == .autostashPending)

        try Data("notes\n".utf8).write(to: fx.repo.appending(path: "notes.txt"))
        try await fx.ops.stage(["notes.txt"])
        try await fx.ops.unstage(["notes.txt"])
        #expect(try await fx.git(["stash", "list", "--format=%H"]) == older)

        // `reset` drops the merge's state, which saves MERGE_AUTOSTASH as a new stash.
        do {
            try await fx.ops.unstageAll()
            Issue.record("expected GitError.autostashKept")
        } catch GitError.autostashKept(let hash) {
            #expect(try await fx.git(["stash", "list", "--format=%H"]) == ([hash] + [older]).joined(separator: "\n"))
            #expect(try await fx.git(["show", "\(hash):README.md"]).contains("local edit"))
        }
    }

    @Test("undo of a stash drop stores it back at the top with its message; redo drops it again")
    func undoRedoStashDrop() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        let older = try await fx.stashes()
        let message = try await fx.git(["log", "-g", "--format=%gs", "refs/stash"]).split(separator: "\n")[1]

        try await fx.ops.stashDrop(older[1])
        #expect(try await fx.stashes() == [older[0]])
        #expect(try fx.journal.load().nextUndo?.kind == .stashDrop)

        #expect(try await fx.ops.undo().kind == .stashDrop)
        #expect(try await fx.stashes() == [older[1], older[0]])
        #expect(try await fx.git(["log", "-g", "-1", "--format=%gs", "refs/stash"]) == message)
        #expect(try await fx.ops.redo().kind == .stashDrop)
        #expect(try await fx.stashes() == [older[0]])
    }

    @Test("undo of a stash save brings back the staged and untracked changes and drops only that stash; redo saves again",
          arguments: [nil, "src"])
    func undoRedoStashSave(folder: String?) async throws {
        let fx = try await Repo(folder: folder)
        defer { fx.copy.remove() }
        // The fixture's WIP: staged, unstaged, renamed, binary and untracked changes, an untracked file named `-rf`.
        let before = try await fx.state()
        let paths = ["README.md", "src/app.swift", "image.bin", "staged.txt", "new-name.txt", "untracked.txt", "-rf"]
        let contents = try paths.map(fx.bytes)
        let older = try await fx.stashes()

        try await fx.ops.stashPush(message: "to undo")
        let saved = try await fx.state()
        let stashes = try await fx.stashes()
        #expect(stashes.count == older.count + 1 && Array(stashes.dropFirst()) == older)
        #expect(!fx.exists("untracked.txt") && !fx.exists("staged.txt"))
        #expect(try fx.journal.load().nextUndo?.kind == .stashSave)

        #expect(try await fx.ops.undo().kind == .stashSave)
        #expect(try await fx.state() == before, "staged stays staged, unstaged and untracked come back")
        #expect(try paths.map(fx.bytes) == contents)
        #expect(try await fx.stashes() == older)

        #expect(try await fx.ops.redo().kind == .stashSave)
        #expect(try await fx.state() == saved)
        #expect(try await fx.stashes() == stashes)
    }

    @Test("a partial stash, undone and redone, leaves another file's staged and unstaged content as they were")
    func partialStashKeepsOtherStagedFile() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        // `src/app.swift` is staged and also edited after (`MM`).
        let staged = try await fx.git(["show", ":src/app.swift"])
        let app = try fx.bytes("src/app.swift")
        #expect(try await fx.git(["diff", "--name-only", "--", "src/app.swift"]) == "src/app.swift")
        #expect(staged != String(decoding: app, as: UTF8.self))
        let before = try await fx.state()
        let readme = try fx.bytes("README.md")

        try await fx.ops.stashPush(paths: ["README.md"])
        let saved = try await fx.state()
        #expect(try await fx.git(["diff", "--name-only", "--", "README.md"]).isEmpty)
        #expect(try await fx.git(["show", ":src/app.swift"]) == staged && fx.bytes("src/app.swift") == app)

        try await fx.ops.undo()
        #expect(try await fx.state() == before)
        #expect(try fx.bytes("README.md") == readme)
        #expect(try await fx.git(["show", ":src/app.swift"]) == staged && fx.bytes("src/app.swift") == app)

        try await fx.ops.redo()
        #expect(try await fx.state() == saved)
        #expect(try await fx.git(["show", ":src/app.swift"]) == staged && fx.bytes("src/app.swift") == app)
    }

    @Test("an empty stash push and an auto-stash record no stash entry")
    func emptyStashAndAutostashRecordNothing() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.git(["reset", "-q", "--hard"])
        try await fx.git(["clean", "-fdq"])
        let older = try await fx.stashes()

        try await fx.ops.stashPush()
        #expect(try await fx.stashes() == older)
        #expect(try fx.journal.load().nextUndo == nil)

        try Data("notes\n".utf8).write(to: fx.repo.appending(path: "notes.txt"))
        try await fx.ops.checkout(branch: "develop", autostash: true)
        #expect(try await fx.stashes() == older)
        #expect(try fx.journal.load().undo.map(\.kind) == [.checkout])
    }

    @Test("a stash drop while a merge is stopped keeps the merge's pending undo")
    func stashDropDuringMergeKeepsPending() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.git(["reset", "-q", "--hard"])
        try await fx.git(["clean", "-fdq"])
        try await fx.git(["switch", "-q", "-c", "other"])
        try Data("other\n".utf8).write(to: fx.repo.appending(path: "README.md"))
        try await fx.git(["commit", "-qam", "Other"])
        try await fx.git(["switch", "-q", "main"])
        try Data("main\n".utf8).write(to: fx.repo.appending(path: "README.md"))
        try await fx.git(["commit", "-qam", "Main"])
        let main = try await fx.git(["rev-parse", "HEAD"])
        let older = try await fx.stashes()
        await #expect(throws: GitError.self) { try await fx.ops.merge("other") }

        try await fx.ops.stashDrop(older[0])
        try Data("resolved\n".utf8).write(to: fx.repo.appending(path: "README.md"))
        try await fx.git(["add", "--", "README.md"])
        try await fx.ops.continueOperation(.merge)
        #expect(try await fx.git(["rev-parse", "HEAD^1"]) == main)

        #expect(try await fx.ops.undo().kind == .merge)
        #expect(try await fx.git(["rev-parse", "HEAD"]) == main)
        #expect(try await fx.ops.undo().kind == .stashDrop)
        #expect(try await fx.stashes() == older)
    }

    @Test("a stash push that ends a stopped merge records nothing (with a held auto-stash, git's entry stays on top)",
          arguments: [true, false])
    func stashPushEndingStoppedMergeRecordsNothing(autostash: Bool) async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.git(["reset", "-q", "--hard"])
        try await fx.git(["clean", "-fdq"])
        // As in `AutoStashTests`: a local commit on feature conflicts with origin/feature's; README.md is held.
        try await fx.git(["switch", "-q", "feature"])
        let feature = String(decoding: try fx.bytes("src/feature.swift"), as: UTF8.self)
        try Data(feature.replacing("print(\"feature\")", with: "print(\"local\")").utf8)
            .write(to: fx.repo.appending(path: "src/feature.swift"))
        try await fx.git(["commit", "-q", "-am", "Local feature change"])
        let older = try await fx.stashes()
        if autostash {
            let readme = String(decoding: try fx.bytes("README.md"), as: UTF8.self)
            try Data((readme + "local edit\n").utf8).write(to: fx.repo.appending(path: "README.md"))
            #expect(try await fx.ops.pull(.fastForward, autostash: true) == .autostashPending)
        } else {
            await #expect(throws: GitError.self) { try await fx.ops.merge("origin/feature") }
        }
        // A push fails on a conflict: resolve it first. Editing README.md again puts the auto-stash's one path in the
        // pushed state too, so only the stash list and the ended merge tell git's entry from this push's.
        try Data("resolved\n".utf8).write(to: fx.repo.appending(path: "src/feature.swift"))
        try await fx.git(["add", "--", "src/feature.swift"])
        try Data("second edit\n".utf8).write(to: fx.repo.appending(path: "README.md"))

        try await fx.ops.stashPush()
        let stashes = try await fx.stashes()
        #expect(Array(stashes.dropFirst(autostash ? 2 : 1)) == older)
        if autostash { #expect(try await fx.git(["show", "\(stashes[0]):README.md"]).contains("local edit")) }
        #expect(try fx.journal.load().undo.allSatisfy { $0.kind != .stashSave })
    }

    @Test("undo of a stash save refuses and changes nothing once a stashed file was edited")
    func undoStashSaveRefusesAfterEdit() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.ops.stashPush()
        try Data("edited\n".utf8).write(to: fx.repo.appending(path: "README.md"))
        let state = try await fx.state()
        let stashes = try await fx.stashes()
        let journal = try Data(contentsOf: fx.journal.file)

        await #expect(throws: UndoError.repositoryChanged) { try await fx.ops.undo() }
        #expect(try await fx.state() == state)
        #expect(try await fx.stashes() == stashes)
        #expect(try Data(contentsOf: fx.journal.file) == journal)
    }

    @Test("undo refuses a tampered stash entry (a short stash hash, a path into .git) and changes nothing",
          arguments: [false, true])
    func undoRefusesTamperedStash(path: Bool) async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.ops.stashPush()
        let stashes = try await fx.stashes()
        try fx.tamper(path ? "README.md" : stashes[0], with: path ? ".git/hooks/x" : String(stashes[0].prefix(12)))
        let state = try await fx.state()
        let journal = try Data(contentsOf: fx.journal.file)

        await #expect(throws: path ? UndoError.unsafePath(".git/hooks/x") : UndoError.unreadableJournal) {
            try await fx.ops.undo()
        }
        #expect(try await fx.state() == state)
        #expect(try await fx.stashes() == stashes)
        #expect(try Data(contentsOf: fx.journal.file) == journal)
        #expect(!fx.exists(".git/hooks/x"))
    }

    @Test("undo of a stash apply keeps a staged edit in another hunk of that file and an unrelated change; redo applies again")
    func undoRedoStashApplyKeepsStagedHunk() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.git(["reset", "-q", "--hard"])
        try await fx.git(["clean", "-fdq"])
        let lines = (1...60).map { "line \($0)\n" }
        func write(_ lines: [String]) throws {
            try Data(lines.joined().utf8).write(to: fx.repo.appending(path: "long.txt"))
        }
        try write(lines)
        try await fx.git(["add", "--", "long.txt"])
        try await fx.git(["commit", "-qm", "Long file"])
        // The stash edits line 1; then line 50 is staged (Tower 5.1's undo dropped such an edit) and README.md edited.
        try write(["line one\n"] + lines.dropFirst())
        try await fx.git(["stash", "push", "-q", "-m", "first line"])
        let stashes = try await fx.stashes()
        try write(lines.prefix(49) + ["line fifty\n"] + lines.dropFirst(50))
        try await fx.git(["add", "--", "long.txt"])
        try Data("unrelated\n".utf8).write(to: fx.repo.appending(path: "README.md"))
        let before = try await fx.state()
        let staged = try await fx.git(["show", ":long.txt"])

        let outcome = try await fx.ops.stashApply(stashes[0])
        #expect(outcome.applied && outcome.undoable)
        let applied = try await fx.state()
        let both = try fx.bytes("long.txt")
        #expect(String(decoding: both, as: UTF8.self).hasPrefix("line one\n"))
        #expect(String(decoding: both, as: UTF8.self).contains("line fifty\n"))

        #expect(try await fx.ops.undo().kind == .stashApply)
        #expect(try await fx.state() == before)
        #expect(try await fx.git(["show", ":long.txt"]) == staged, "the staged hunk stays staged")
        #expect(try fx.bytes("README.md") == Data("unrelated\n".utf8))
        #expect(try await fx.stashes() == stashes, "an apply leaves the stash list alone")

        #expect(try await fx.ops.redo().kind == .stashApply)
        #expect(try await fx.state() == applied)
        #expect(try fx.bytes("long.txt") == both)
        #expect(try await fx.stashes() == stashes)
    }

    @Test("undo of a stash apply that renames a file brings the old path back and removes the new one")
    func undoStashApplyRename() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.git(["reset", "-q", "--hard"])
        try await fx.git(["clean", "-fdq"])
        let guide = try fx.bytes("docs/guide.md")
        try await fx.git(["mv", "docs/guide.md", "docs/manual.md"])
        try await fx.git(["stash", "push", "-q"])
        let before = try await fx.state()

        try await fx.ops.stashApply(try await fx.stashes()[0])
        #expect(fx.exists("docs/manual.md") && !fx.exists("docs/guide.md"))

        try await fx.ops.undo()
        #expect(try await fx.state() == before)
        #expect(try fx.bytes("docs/guide.md") == guide)
        #expect(!fx.exists("docs/manual.md"))
    }

    @Test("undo of a stash apply refuses and changes nothing once the applied file was edited")
    func undoStashApplyRefusesAfterEdit() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.git(["reset", "-q", "--hard"])
        try await fx.git(["clean", "-fdq"])
        // stash@{1} edits docs/guide.md.
        try await fx.ops.stashApply(try await fx.stashes()[1])
        try Data("edited\n".utf8).write(to: fx.repo.appending(path: "docs/guide.md"))
        let state = try await fx.state()
        let journal = try Data(contentsOf: fx.journal.file)

        await #expect(throws: UndoError.repositoryChanged) { try await fx.ops.undo() }
        #expect(try await fx.state() == state)
        #expect(try Data(contentsOf: fx.journal.file) == journal)
    }

    @Test("undo of a stash pop stores the stash back once with its message; redo pops it again")
    func undoRedoStashPop() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.git(["reset", "-q", "--hard"])
        try await fx.git(["clean", "-fdq"])
        let before = try await fx.state()
        let older = try await fx.stashes()
        let message = try await fx.git(["log", "-g", "-1", "--format=%gs", "refs/stash"])

        // stash@{0} edits VERSION and holds the untracked scratch.txt.
        let outcome = try await fx.ops.stashPop(older[0])
        #expect(outcome.applied && outcome.undoable)
        #expect(try await fx.stashes() == [older[1]])
        #expect(fx.exists("scratch.txt"))
        let popped = try await fx.state()

        #expect(try await fx.ops.undo().kind == .stashPop)
        #expect(try await fx.stashes() == older)
        #expect(try await fx.git(["log", "-g", "-1", "--format=%gs", "refs/stash"]) == message)
        #expect(try await fx.state() == before)
        #expect(!fx.exists("scratch.txt"))
        #expect(try fx.journal.load().nextUndo == nil)

        #expect(try await fx.ops.redo().kind == .stashPop)
        #expect(try await fx.stashes() == [older[1]])
        #expect(try await fx.state() == popped)
        #expect(try await fx.ops.undo().kind == .stashPop)
        #expect(try await fx.stashes() == older)
    }

    @Test("a conflicting stash apply or pop (from the top or a subfolder) records nothing and is not undoable; a pop keeps the stash",
          arguments: [false, true], [nil, "src"])
    func conflictingStashApplyRecordsNothing(pop: Bool, folder: String?) async throws {
        let fx = try await Repo(folder: folder)
        defer { fx.copy.remove() }
        try await fx.git(["reset", "-q", "--hard"])
        try await fx.git(["clean", "-fdq"])
        // stash@{0} changes VERSION from 1.0.1 to 1.0.2.
        try Data("1.0.3\n".utf8).write(to: fx.repo.appending(path: "VERSION"))
        try await fx.git(["commit", "-qam", "Competing version"])
        let older = try await fx.stashes()

        let outcome = pop ? try await fx.ops.stashPop(older[0]) : try await fx.ops.stashApply(older[0])
        #expect(!outcome.applied && !outcome.undoable)
        #expect(try await !fx.git(["ls-files", "--unmerged"]).isEmpty)
        #expect(try await fx.stashes() == older)
        #expect(try fx.journal.load().undo.allSatisfy { $0.kind != .stashApply && $0.kind != .stashPop })
    }

    @Test("a stash apply whose edit lands in a file renamed since records nothing")
    func stashApplyIntoRenamedFileRecordsNothing() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.git(["reset", "-q", "--hard"])
        try await fx.git(["clean", "-fdq"])
        try await fx.git(["mv", "docs/guide.md", "docs/manual.md"])
        try await fx.git(["commit", "-qm", "Rename guide"])

        // stash@{1} edits docs/guide.md: merge-ort follows the rename into docs/manual.md, outside the stash's paths.
        let outcome = try await fx.ops.stashApply(try await fx.stashes()[1])
        #expect(outcome.applied && !outcome.undoable)
        #expect(try await fx.git(["status", "--porcelain"]) == " M docs/manual.md")
        #expect(try fx.journal.load().nextUndo == nil)
    }

    @Test("a stash apply or pop while a merge is stopped keeps the merge's pending undo", arguments: [false, true])
    func stashApplyDuringMergeKeepsPending(pop: Bool) async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.git(["reset", "-q", "--hard"])
        try await fx.git(["clean", "-fdq"])
        try await fx.git(["switch", "-q", "-c", "other"])
        try Data("other\n".utf8).write(to: fx.repo.appending(path: "README.md"))
        try await fx.git(["commit", "-qam", "Other"])
        try await fx.git(["switch", "-q", "main"])
        try Data("main\n".utf8).write(to: fx.repo.appending(path: "README.md"))
        try await fx.git(["commit", "-qam", "Main"])
        let main = try await fx.git(["rev-parse", "HEAD"])
        let guide = try fx.bytes("docs/guide.md")
        let older = try await fx.stashes()
        await #expect(throws: GitError.self) { try await fx.ops.merge("other") }
        // A stash applies on an index without conflicts only.
        try Data("resolved\n".utf8).write(to: fx.repo.appending(path: "README.md"))
        try await fx.git(["add", "--", "README.md"])

        // stash@{1} edits docs/guide.md, which the merge leaves alone.
        let outcome = pop ? try await fx.ops.stashPop(older[1]) : try await fx.ops.stashApply(older[1])
        #expect(outcome.applied && outcome.undoable)
        try await fx.ops.continueOperation(.merge)
        #expect(try await fx.git(["rev-parse", "HEAD^1"]) == main)

        #expect(try await fx.ops.undo().kind == .merge)
        #expect(try await fx.git(["rev-parse", "HEAD"]) == main)
        #expect(try await fx.ops.undo().kind == (pop ? .stashPop : .stashApply))
        // A popped stash comes back at the top.
        #expect(try await fx.stashes() == (pop ? [older[1], older[0]] : older))
        #expect(try fx.bytes("docs/guide.md") == guide)
        #expect(try await fx.git(["status", "--porcelain"]).isEmpty)
    }

    @Test("undo refuses and changes nothing after a commit made outside Histq")
    func undoRefusesAfterOutsideCommit() async throws {
        let fx = try await Repo()
        defer { fx.copy.remove() }
        try await fx.ops.commit(message: "Journaled commit")
        try await fx.git(["commit", "--allow-empty", "-q", "-m", "Terminal commit"])
        let outside = try await fx.state()

        await #expect(throws: UndoError.repositoryChanged) { try await fx.ops.undo() }
        #expect(try await fx.state() == outside)
        #expect(try fx.journal.load().nextUndo != nil)
    }

    @Test("undo of a resolved file brings back its three stages and markers; redo resolves it again")
    func undoRedoResolve() async throws {
        let fx = try await Repo(fixture: "conflict")
        defer { fx.copy.remove() }
        let resolved = Data("resolved\n".utf8)

        try await fx.ops.resolve(path: "long.txt", content: resolved)
        #expect(try await fx.git(["status", "--porcelain", "--", "long.txt"]) == "M  long.txt")
        #expect(try fx.journal.load().nextUndo == nil)

        #expect(try await fx.ops.undo().kind == .resolve)
        #expect(try await fx.git(["status", "--porcelain", "--", "long.txt"]) == "UU long.txt")
        #expect(try await fx.git(["ls-files", "-u", "--", "long.txt"]).split(separator: "\n").count == 3)
        #expect(String(decoding: try fx.bytes("long.txt"), as: UTF8.self).contains("<<<<<<<"))

        #expect(try await fx.ops.redo().kind == .resolve)
        #expect(try await fx.git(["status", "--porcelain", "--", "long.txt"]) == "M  long.txt")
        #expect(try fx.bytes("long.txt") == resolved)
    }

    @Test("undo of a resolved file refuses and changes nothing once the file was edited")
    func undoResolveRefusesAfterEdit() async throws {
        let fx = try await Repo(fixture: "conflict")
        defer { fx.copy.remove() }
        try await fx.ops.resolve(path: "long.txt", content: Data("resolved\n".utf8))
        try Data("edited\n".utf8).write(to: fx.repo.appending(path: "long.txt"))
        let edited = try await fx.state()

        await #expect(throws: UndoError.repositoryChanged) { try await fx.ops.undo() }
        #expect(try await fx.state() == edited)
        #expect(try fx.bytes("long.txt") == Data("edited\n".utf8))
    }

    @Test("resolves undone and redone during a merge Histq started keep the merge's undo: continue, then undo it whole")
    func resolveUndoKeepsMergeUndo() async throws {
        let fx = try await Repo(fixture: "conflict")
        defer { fx.copy.remove() }
        // The fixture's merge started outside Histq (no pending entry): start it again through the journal.
        try await fx.git(["merge", "--abort"])
        let main = try await fx.git(["rev-parse", "HEAD"])
        await #expect(throws: GitError.self) { try await fx.ops.merge("feature") }

        try await fx.ops.resolve(path: "long.txt", content: Data("first\n".utf8))
        #expect(try await fx.ops.undo().kind == .resolve)
        try await fx.ops.resolve(path: "long.txt", content: Data("second\n".utf8))
        try await fx.ops.resolve(path: "add.txt", content: Data("add\n".utf8))
        try await fx.ops.resolve(path: "gone.txt", content: nil)
        try await fx.ops.continueOperation(.merge)
        #expect(try await fx.git(["rev-parse", "HEAD^1"]) == main)

        #expect(try await fx.ops.undo().kind == .merge)
        #expect(try await fx.git(["rev-parse", "HEAD"]) == main)
        #expect(try await fx.git(["status", "--porcelain"]).isEmpty)
    }
}
