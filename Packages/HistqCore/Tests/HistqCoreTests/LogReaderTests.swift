// Security tests for LogReader: commit text comes from the repo, so a crafted author name or message
// must not forge graph rows, and a repo's output encoding must not break the NUL-terminated records.
import Foundation
import HistqCore
import Testing

struct LogReaderTests {
    @Test(
        "a name or body holding a crafted record separator and fields gives no extra row and keeps the body",
        arguments: [false, true])
    func craftedRecordIsNoRow(inAuthorName: Bool) async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")
        let root = try await sandbox.git(["rev-parse", "HEAD"], in: repo)
        let tree = try await sandbox.git(["rev-parse", "HEAD^{tree}"], in: repo)
        // A forged record of the old `\x1e`-terminated format that repeats the root commit's hash.
        let forged = "\u{1E}\(root)\u{1F}\u{1F}1\u{1F}1\u{1F}Forger\u{1F}forger@histq.invalid\u{1F}forged\u{1F}forged body"
        let author = inAuthorName ? "Real\(forged)" : "Real Author"
        let body = inAuthorName ? "plain body" : "line one\n\(forged)\n\u{1E}\n\(forged)\u{1E}tail"
        let raw = """
            tree \(tree)
            parent \(root)
            author \(author) <real@histq.invalid> 1700000000 +0000
            committer Real Committer <committer@histq.invalid> 1700000100 +0000

            crafted subject

            \(body)

            """
        let commit = try await sandbox.git(
            ["hash-object", "-t", "commit", "-w", "--stdin"], in: repo, stdin: Data(raw.utf8))
        try await sandbox.git(["update-ref", "refs/heads/main", commit], in: repo)

        let env = try await GitInvocation.readEnvironment(
            profile: nil, base: sandbox.base, runner: sandbox.runner, cwd: repo)
        var commits: [Commit] = []
        for try await page in LogReader.pages(runner: sandbox.runner, cwd: repo, env: env) { commits += page }

        #expect(commits.map(\.hash) == [commit, root], "exactly the two real commits, in order")
        let crafted = try #require(commits.first)
        #expect(crafted.parents == [root])
        #expect(crafted.authorDate == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(crafted.committerDate == Date(timeIntervalSince1970: 1_700_000_100))
        if !inAuthorName {
            #expect(crafted.authorName == "Real Author")
            #expect(crafted.authorEmail == "real@histq.invalid")
            #expect(crafted.committerName == "Real Committer")
            #expect(crafted.committerEmail == "committer@histq.invalid")
            #expect(crafted.subject == "crafted subject")
            #expect(crafted.body == body, "the full, unmodified body")
        }
    }

    @Test("a repo's i18n.logOutputEncoding cannot put NUL bytes into the log records")
    func repoOutputEncodingIsIgnored() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")
        try await sandbox.git(["config", "i18n.logOutputEncoding", "UTF-16LE"], in: repo)
        let head = try await sandbox.git(["rev-parse", "HEAD"], in: repo)

        let env = try await GitInvocation.readEnvironment(
            profile: nil, base: sandbox.base, runner: sandbox.runner, cwd: repo)
        var commits: [Commit] = []
        for try await page in LogReader.pages(runner: sandbox.runner, cwd: repo, env: env) { commits += page }

        #expect(commits.map(\.hash) == [head])
        #expect(commits.first?.subject == "initial")
    }

    // MARK: Incremental reload

    /// A full history read (`pages`) of `repo`, all pages joined.
    private func readAll(_ sandbox: Sandbox, _ repo: URL, alsoFrom: [String] = []) async throws -> [Commit] {
        let env = try await GitInvocation.readEnvironment(
            profile: nil, base: sandbox.base, runner: sandbox.runner, cwd: repo)
        var commits: [Commit] = []
        for try await page in LogReader.pages(runner: sandbox.runner, cwd: repo, env: env, alsoFrom: alsoFrom) {
            commits += page
        }
        return commits
    }

    /// The tips of a full read of `repo` (`pages`, then `tips(of:index:)`), as the app takes them from its log.
    private func tipsOfFullRead(_ sandbox: Sandbox, _ repo: URL, alsoFrom: [String] = []) async throws -> [String] {
        let commits = try await readAll(sandbox, repo, alsoFrom: alsoFrom)
        return LogReader.tips(of: commits, index: Self.index(commits))
    }

    /// `newCommits` for `repo` with its read environment.
    private func newCommits(
        _ sandbox: Sandbox, _ repo: URL, previousTips: [String], alsoFrom: [String] = []
    ) async throws -> [Commit]? {
        let env = try await GitInvocation.readEnvironment(
            profile: nil, base: sandbox.base, runner: sandbox.runner, cwd: repo)
        return try await LogReader.newCommits(
            runner: sandbox.runner, cwd: repo, env: env, previousTips: previousTips, alsoFrom: alsoFrom)
    }

    /// `commits`' index of each hash, as the app's log keeps it.
    private static func index(_ commits: [Commit]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: commits.enumerated().map { ($1.hash, $0) })
    }

    @Test("tips are the commits no other commit lists as a parent, across a merge and two branches")
    func tipsOfMergeAndBranches() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")
        try await sandbox.git(["checkout", "-q", "-b", "feature"], in: repo)
        try await sandbox.git(["commit", "-q", "--allow-empty", "-m", "feature one"], in: repo)
        try await sandbox.git(["checkout", "-q", "main"], in: repo)
        try await sandbox.git(["commit", "-q", "--allow-empty", "-m", "main one"], in: repo)
        try await sandbox.git(["merge", "-q", "--no-ff", "-m", "merge", "feature"], in: repo)
        try await sandbox.git(["checkout", "-q", "-b", "side", "HEAD~1"], in: repo)
        try await sandbox.git(["commit", "-q", "--allow-empty", "-m", "side one"], in: repo)
        let main = try await sandbox.git(["rev-parse", "main"], in: repo)
        let side = try await sandbox.git(["rev-parse", "side"], in: repo)

        let commits = try await readAll(sandbox, repo)
        let tips = LogReader.tips(of: commits, index: Self.index(commits))

        #expect(commits.count == 5)
        #expect(Set(tips) == [main, side], "the merged feature branch is no tip")
        #expect(tips.count == 2)
    }

    @Test("a new commit on the current branch is the only new commit, and with the old ones makes a full read")
    func newCommitOnCurrentBranch() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")
        try await sandbox.git(["checkout", "-q", "-b", "side"], in: repo)
        try await sandbox.git(["commit", "-q", "--allow-empty", "-m", "side one"], in: repo)
        try await sandbox.git(["checkout", "-q", "main"], in: repo)
        let old = try await readAll(sandbox, repo)
        let tips = LogReader.tips(of: old, index: Self.index(old))
        try await sandbox.git(["commit", "-q", "--allow-empty", "-m", "main two"], in: repo)
        let head = try await sandbox.git(["rev-parse", "HEAD"], in: repo)

        let delta = try #require(try await newCommits(sandbox, repo, previousTips: tips))

        #expect(delta.map(\.hash) == [head])
        #expect(delta.first?.subject == "main two")
        let fresh = try await readAll(sandbox, repo)
        #expect(Set((delta + old).map(\.hash)) == Set(fresh.map(\.hash)))
        #expect(delta.count + old.count == fresh.count)
    }

    @Test("a new branch of two commits off an old commit gives both, children before parents")
    func newBranchOffOldCommit() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")
        try await sandbox.git(["commit", "-q", "--allow-empty", "-m", "main two"], in: repo)
        let tips = try await tipsOfFullRead(sandbox, repo)
        try await sandbox.git(["checkout", "-q", "-b", "topic", "HEAD~1"], in: repo)
        try await sandbox.git(["commit", "-q", "--allow-empty", "-m", "topic one"], in: repo)
        let first = try await sandbox.git(["rev-parse", "HEAD"], in: repo)
        try await sandbox.git(["commit", "-q", "--allow-empty", "-m", "topic two"], in: repo)
        let second = try await sandbox.git(["rev-parse", "HEAD"], in: repo)

        let delta = try #require(try await newCommits(sandbox, repo, previousTips: tips))

        #expect(delta.map(\.hash) == [second, first])
        #expect(delta.first?.parents == [first])
    }

    @Test("tips updated from a delta equal the tips of the whole log")
    func tipsFromDelta() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")
        try await sandbox.git(["checkout", "-q", "-b", "side"], in: repo)
        try await sandbox.git(["commit", "-q", "--allow-empty", "-m", "side one"], in: repo)
        try await sandbox.git(["checkout", "-q", "-b", "other", "main"], in: repo)
        try await sandbox.git(["commit", "-q", "--allow-empty", "-m", "other one"], in: repo)
        try await sandbox.git(["checkout", "-q", "main"], in: repo)
        try await sandbox.git(["commit", "-q", "--allow-empty", "-m", "main two"], in: repo)
        let oldTips = try await tipsOfFullRead(sandbox, repo)
        try await sandbox.git(["commit", "-q", "--allow-empty", "-m", "main three"], in: repo)
        try await sandbox.git(["merge", "-q", "--no-ff", "-m", "merge side", "side"], in: repo)
        try await sandbox.git(["checkout", "-q", "-b", "topic", "HEAD~2"], in: repo)
        try await sandbox.git(["commit", "-q", "--allow-empty", "-m", "topic one"], in: repo)

        let delta = try #require(try await newCommits(sandbox, repo, previousTips: oldTips))
        let tips = LogReader.tips(adding: delta, to: oldTips)

        let fresh = try await tipsOfFullRead(sandbox, repo)
        #expect(oldTips.count == 3)
        #expect(delta.count == 3)
        #expect(Set(tips) == Set(fresh), "the merged side tip and the old main tip are gone, other stays")
        #expect(tips.count == fresh.count)
    }

    @Test("nothing new gives no commit, not nil")
    func nothingChanged() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")
        try await sandbox.git(["commit", "-q", "--allow-empty", "-m", "main two"], in: repo)
        let tips = try await tipsOfFullRead(sandbox, repo)

        let delta = try await newCommits(sandbox, repo, previousTips: tips)

        #expect(delta == [])
    }

    @Test("a commit no ref reaches any more gives nil: a deleted branch, a hard reset")
    func unreachableOldCommit() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")
        try await sandbox.git(["checkout", "-q", "-b", "side"], in: repo)
        try await sandbox.git(["commit", "-q", "--allow-empty", "-m", "side one"], in: repo)
        try await sandbox.git(["checkout", "-q", "main"], in: repo)
        try await sandbox.git(["commit", "-q", "--allow-empty", "-m", "main two"], in: repo)
        let tips = try await tipsOfFullRead(sandbox, repo)
        try await sandbox.git(["branch", "-q", "-D", "side"], in: repo)

        #expect(try await newCommits(sandbox, repo, previousTips: tips) == nil, "the deleted branch's commit")

        let afterDelete = try await tipsOfFullRead(sandbox, repo)
        try await sandbox.git(["reset", "-q", "--hard", "HEAD~1"], in: repo)

        #expect(try await newCommits(sandbox, repo, previousTips: afterDelete) == nil, "the reset commit")
        #expect(try await newCommits(sandbox, repo, previousTips: []) == nil, "no previous tip")
        #expect(try await newCommits(sandbox, repo, previousTips: ["--all"]) == nil, "a tip that is no hash")
    }

    @Test("a stash whose base only the stash holds: no new commit while it is there, nil once it is dropped")
    func droppedStashBase() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")
        try await sandbox.git(["checkout", "-q", "-b", "temp"], in: repo)
        try Data("base\n".utf8).write(to: repo.appending(path: "tracked.txt"))
        try await sandbox.git(["commit", "-q", "-am", "stash base"], in: repo)
        let base = try await sandbox.git(["rev-parse", "HEAD"], in: repo)
        try Data("changed\n".utf8).write(to: repo.appending(path: "tracked.txt"))
        try await sandbox.git(["stash", "-q"], in: repo)
        try await sandbox.git(["checkout", "-q", "main"], in: repo)
        try await sandbox.git(["branch", "-q", "-D", "temp"], in: repo)
        let tips = try await tipsOfFullRead(sandbox, repo, alsoFrom: [base])
        #expect(tips.contains(base), "the stash base is a tip of the old read")

        #expect(try await newCommits(sandbox, repo, previousTips: tips, alsoFrom: [base]) == [])

        try await sandbox.git(["stash", "drop", "-q"], in: repo)

        #expect(try await newCommits(sandbox, repo, previousTips: tips) == nil)
    }

    @Test("a commit only a prefetch ref reaches is no row and no new commit")
    func prefetchRefIsHidden() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")
        let tips = try await tipsOfFullRead(sandbox, repo)
        try await sandbox.git(["checkout", "-q", "-b", "side"], in: repo)
        try await sandbox.git(["commit", "-q", "--allow-empty", "-m", "fetched"], in: repo)
        let fetched = try await sandbox.git(["rev-parse", "HEAD"], in: repo)
        try await sandbox.git(["update-ref", "refs/prefetch/remotes/origin/side", fetched], in: repo)
        try await sandbox.git(["checkout", "-q", "main"], in: repo)
        try await sandbox.git(["branch", "-q", "-D", "side"], in: repo)

        #expect(try await !readAll(sandbox, repo).contains { $0.hash == fetched })
        #expect(try await newCommits(sandbox, repo, previousTips: tips) == [])
    }

    @Test("a replace ref gives nil: it can give an old commit other parents")
    func replaceRef() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")
        try await sandbox.git(["commit", "-q", "--allow-empty", "-m", "main two"], in: repo)
        let tips = try await tipsOfFullRead(sandbox, repo)
        try await sandbox.git(["replace", "--graft", "HEAD"], in: repo)

        #expect(try await newCommits(sandbox, repo, previousTips: tips) == nil)
    }

    @Test("a tip of fullwidth digits is no hash")
    func fullwidthTip() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")

        #expect(try await newCommits(sandbox, repo, previousTips: ["\u{FF11}\u{FF12}"]) == nil)
    }
}
