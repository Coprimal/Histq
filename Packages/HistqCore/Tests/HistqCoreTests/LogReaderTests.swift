// Security tests for LogReader: commit text comes from the repo, so a crafted author name or message
// must not forge graph rows, and a repo's output encoding must not break the NUL-terminated records.
// Key feature tests (task 3.1): the log arguments for hidden and soloed branches, built from full ref names
// only, and a real log of the `graph` fixture with a branch hidden and with a branch soloed.
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

    @Test(
        "a hidden ref's own commits leave the log, shared ones stay, a remote's HEAD does not keep them, a tag does until hidden; a glob or non-refs/ entry is ignored")
    func hiddenRefLeavesTheLog() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")
        let shared = try await sandbox.git(["rev-parse", "HEAD"], in: repo)
        try await sandbox.git(["checkout", "-q", "-b", "side"], in: repo)
        try await sandbox.git(["commit", "-q", "--allow-empty", "-m", "side only"], in: repo)
        let sideOnly = try await sandbox.git(["rev-parse", "HEAD"], in: repo)
        try await sandbox.git(["checkout", "-q", "main"], in: repo)
        try await sandbox.git(["commit", "-q", "--allow-empty", "-m", "main only"], in: repo)

        let env = try await GitInvocation.readEnvironment(
            profile: nil, base: sandbox.base, runner: sandbox.runner, cwd: repo)
        /// The hashes of the whole log read with `hidden`.
        func hashes(hidden refNames: [String]) async throws -> Set<String> {
            var commits: [Commit] = []
            for try await page in LogReader.pages(runner: sandbox.runner, cwd: repo, env: env, hidden: refNames) {
                commits += page
            }
            return Set(commits.map(\.hash))
        }

        let all = try await hashes(hidden: [])
        #expect(all.contains(sideOnly) && all.contains(shared) && all.count == 3)
        let hidden = try await hashes(hidden: ["refs/heads/side"])
        #expect(!hidden.contains(sideOnly), "the side branch's own commit is gone")
        #expect(hidden.contains(shared), "main still reaches the shared commit")
        #expect(hidden.count == 2)
        #expect(try await hashes(hidden: ["refs/heads/*"]) == all, "a glob would hide every branch")
        #expect(try await hashes(hidden: ["heads/side", "side"]) == all, "only full refs/ names count")

        // A remote's HEAD is a symref the user cannot hide: hiding its branch must still drop the branch's commits.
        try await sandbox.git(["update-ref", "refs/remotes/origin/main", sideOnly], in: repo)
        try await sandbox.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], in: repo)
        let remoteHidden = try await hashes(hidden: ["refs/heads/side", "refs/remotes/origin/main"])
        #expect(!remoteHidden.contains(sideOnly), "origin/HEAD does not bring back the hidden origin/main")
        #expect(remoteHidden.count == 2)

        // A tag on the side commit keeps it, until the tag is hidden too.
        try await sandbox.git(["tag", "side-tag", sideOnly], in: repo)
        let refs = ["refs/heads/side", "refs/remotes/origin/main"]
        #expect(try await hashes(hidden: refs).contains(sideOnly), "the tag still reaches the side commit")
        #expect(try await !hashes(hidden: refs + ["refs/tags/side-tag"]).contains(sideOnly), "a hidden tag does not")
    }

    @Test("no hidden or soloed ref gives the shipped arguments, with the extra revisions at the end as before")
    func emptyHideAndSoloKeepArguments() {
        #expect(LogReader.arguments(hidden: [], solo: []) == LogReader.arguments)
        let hash = String(repeating: "a", count: 40)
        #expect(LogReader.arguments(hidden: [], solo: [], alsoFrom: [hash]) == LogReader.arguments + [hash])
        #expect(LogReader.arguments(hidden: [], solo: [], order: .date)
            == LogReader.arguments.map { $0 == "--topo-order" ? "--date-order" : $0 }, "date order reaches git")
    }

    @Test("hidden refs, tags too, are excludes after the stash, notes, prefetch and remote HEAD excludes and before --all")
    func hiddenRefsPrecedeAll() throws {
        let hidden = ["--exclude=refs/heads/series", "--exclude=refs/remotes/origin/main", "--exclude=refs/tags/v1.0"]
        let args = LogReader.arguments(
            hidden: ["refs/heads/series", "refs/remotes/origin/main", "refs/tags/v1.0"], solo: [])
        let all = try #require(args.firstIndex(of: "--all"))
        #expect(Array(args[..<all].suffix(7)) == [
            "--exclude=refs/stash", "--exclude=refs/notes/*", "--exclude=refs/prefetch/*", "--exclude=refs/remotes/*/HEAD",
        ] + hidden)
        #expect(args.filter { !hidden.contains($0) } == LogReader.arguments)
    }

    @Test("soloed refs drop --all and come after every option and --end-of-options, then HEAD, extras and --")
    func soloRefsComeLast() throws {
        let hash = String(repeating: "b", count: 40)
        let args = LogReader.arguments(
            hidden: ["refs/heads/old"], solo: ["refs/heads/series", "refs/remotes/origin/feature"],
            alsoFrom: [hash, "-x"])
        #expect(!args.contains("--all"))
        let end = try #require(args.firstIndex(of: "--end-of-options"))
        #expect(args[..<end].contains("--topo-order"))
        #expect(args[..<end].contains { $0.hasPrefix("--format=") })
        #expect(args[..<end].contains("--exclude=refs/heads/old"))
        #expect(Array(args[end...]) == [
            "--end-of-options", "refs/heads/series", "refs/remotes/origin/feature", "HEAD", hash, "--",
        ])
    }

    @Test("names that are not full branch, remote or tag refs, or that git forbids, are dropped")
    func invalidRefsAreDropped() {
        let invalid = [
            "main", "refs/tags/", "refs/tags/-x", "refs/tags/v1..0", "refs/heads/", "refs/heads/-x", "refs/heads/a..b",
            "refs/heads/a b",
            "refs/heads/x.lock", "refs/heads/a@{1}", "refs/heads/a~1", "refs/heads/a^", "refs/heads/a:b",
            "refs/heads/a?", "refs/heads/a*", "refs/heads/a[", "refs/heads/a\\b", "refs/heads/a\u{7}",
            "refs/heads/x/", "refs/heads/a//b", "refs/heads/.x", "refs/heads/x.", "refs/remotes/origin",
            "--all", "refs/heads/a..\u{301}b", "refs/heads/a~\u{301}1",
        ]
        #expect(LogReader.arguments(hidden: invalid, solo: []) == LogReader.arguments)
        #expect(LogReader.arguments(hidden: [], solo: invalid) == LogReader.arguments, "no valid solo ref: all refs")
        #expect(LogReader.arguments(hidden: [], solo: invalid + ["refs/heads/ok"]).suffix(4)
            == ["--end-of-options", "refs/heads/ok", "HEAD", "--"])
        // A tag can be hidden but not soloed.
        #expect(LogReader.arguments(hidden: [], solo: ["refs/tags/v1.0"]) == LogReader.arguments)
    }

    @Test("graph fixture: a hidden branch's own commits are no rows; a soloed branch shows only it and HEAD")
    func hideAndSoloOnGraphFixture() async throws {
        let copy = try await Fixtures.copy()
        defer { copy.remove() }
        let repo = copy.repo("graph")
        let env = try await GitInvocation.readEnvironment(profile: nil, base: copy.base, runner: copy.runner, cwd: repo)
        // A file named HEAD in the worktree must not make the soloed log's HEAD ambiguous.
        try Data("not a revision\n".utf8).write(to: repo.appending(path: "HEAD"))
        func subjects(hidden: [String] = [], solo: [String] = []) async throws -> Set<String> {
            var commits: [Commit] = []
            for try await page in LogReader.pages(
                runner: copy.runner, cwd: repo, env: env, hidden: hidden, solo: solo) { commits += page }
            return Set(commits.map(\.subject))
        }

        let all = try await subjects()
        let hidden = try await subjects(hidden: ["refs/heads/series"])
        #expect(all.contains("Series step 5"))
        #expect(all.subtracting(hidden) == Set((1...5).map { "Series step \($0)" }))

        let solo = try await subjects(solo: ["refs/heads/series"])
        #expect(solo.contains("Series step 5"))
        #expect(solo.contains("Bump version"), "HEAD (main) is kept")
        #expect(!solo.contains("Update changelog (not pushed)"))
        #expect(!solo.contains("Polish feature (pushed)"))
    }

    // MARK: Incremental reload

    /// A full history read (`pages`) of `repo` in `order`, all pages joined.
    private func readAll(
        _ sandbox: Sandbox, _ repo: URL, alsoFrom: [String] = [], order: LogReader.Order = .branch
    ) async throws -> [Commit] {
        let env = try await GitInvocation.readEnvironment(
            profile: nil, base: sandbox.base, runner: sandbox.runner, cwd: repo)
        var commits: [Commit] = []
        for try await page in LogReader.pages(
            runner: sandbox.runner, cwd: repo, env: env, alsoFrom: alsoFrom, order: order) { commits += page }
        return commits
    }

    /// The tips of a full read of `repo` (`pages`, then `tips(of:index:)`), as the app takes them from its log.
    private func tipsOfFullRead(_ sandbox: Sandbox, _ repo: URL, alsoFrom: [String] = []) async throws -> [String] {
        let commits = try await readAll(sandbox, repo, alsoFrom: alsoFrom)
        return LogReader.tips(of: commits, index: Self.index(commits))
    }

    /// `newCommits` for `repo` with its read environment.
    private func newCommits(
        _ sandbox: Sandbox, _ repo: URL, previousTips: [String], alsoFrom: [String] = [],
        order: LogReader.Order = .branch
    ) async throws -> [Commit]? {
        let env = try await GitInvocation.readEnvironment(
            profile: nil, base: sandbox.base, runner: sandbox.runner, cwd: repo)
        return try await LogReader.newCommits(
            runner: sandbox.runner, cwd: repo, env: env, previousTips: previousTips, alsoFrom: alsoFrom, order: order)
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

    @Test(
        "date order: fetched commits older than the local tip merge where a fresh read puts them; a clock-skewed child stays above its parent")
    func dateOrderMergesNewCommits() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")
        let tree = try await sandbox.git(["rev-parse", "HEAD^{tree}"], in: repo)
        /// A commit of `tree` on `parent`, authored and committed `seconds` after 1970.
        func commit(_ subject: String, at seconds: Int, parent: String? = nil) async throws -> String {
            let date = "@\(seconds) +0000"
            let env = sandbox.base.merging(["GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date]) { $1 }
            let parents = parent.map { ["-p", $0] } ?? []
            let result = try await sandbox.runner.run(
                ["commit-tree"] + parents + ["-m", subject, tree], cwd: repo, env: env, timeout: .seconds(30))
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // main: initial(100) → M1(250) → M2(450), replacing makeRepo's commit dated now.
        let initial = try await commit("initial", at: 100)
        let m1 = try await commit("M1", at: 250, parent: initial)
        let m2 = try await commit("M2", at: 450, parent: m1)
        try await sandbox.git(["update-ref", "refs/heads/main", m2], in: repo)
        let old = try await readAll(sandbox, repo, order: .date)
        #expect(old.map(\.hash) == [m2, m1, initial])
        // Fetched: R1(200) → R2(300) off initial, both older than the local tip.
        let r1 = try await commit("R1", at: 200, parent: initial)
        let r2 = try await commit("R2", at: 300, parent: r1)
        try await sandbox.git(["update-ref", "refs/remotes/origin/main", r2], in: repo)

        let oldIndex = Self.index(old)
        let delta = try #require(try await newCommits(
            sandbox, repo, previousTips: LogReader.tips(of: old, index: oldIndex), order: .date))
        let merged = LogReader.mergedByDate(delta, into: old, index: oldIndex)

        let expected = [m2, r2, m1, r1, initial]
        #expect(try await readAll(sandbox, repo, order: .date).map(\.hash) == expected, "a fresh read, by date")
        #expect(merged.map(\.hash) == expected)

        // S(50), a child of M2 dated before it: still above M2, though a fresh read may list it elsewhere.
        let skewed = try await commit("S", at: 50, parent: m2)
        try await sandbox.git(["update-ref", "refs/heads/main", skewed], in: repo)
        let mergedIndex = Self.index(merged)
        let next = try #require(try await newCommits(
            sandbox, repo, previousTips: LogReader.tips(of: merged, index: mergedIndex), order: .date))
        let again = LogReader.mergedByDate(next, into: merged, index: mergedIndex)

        let fresh = try await readAll(sandbox, repo, order: .date)
        #expect(Set(again.map(\.hash)) == Set(fresh.map(\.hash)))
        #expect(again.count == fresh.count)
        let row = Self.index(again)
        for (position, commit) in again.enumerated() {
            for parent in commit.parents {
                let parentRow = try #require(row[parent], "every parent is listed")
                #expect(parentRow > position, "\(commit.subject) above its parent")
            }
        }
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
