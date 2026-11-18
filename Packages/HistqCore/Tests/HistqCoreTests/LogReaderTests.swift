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
    }

    @Test("hidden refs, tags too, are excludes after the stash, notes and remote HEAD excludes and before --all")
    func hiddenRefsPrecedeAll() throws {
        let hidden = ["--exclude=refs/heads/series", "--exclude=refs/remotes/origin/main", "--exclude=refs/tags/v1.0"]
        let args = LogReader.arguments(
            hidden: ["refs/heads/series", "refs/remotes/origin/main", "refs/tags/v1.0"], solo: [])
        let all = try #require(args.firstIndex(of: "--all"))
        #expect(Array(args[..<all].suffix(6)) == [
            "--exclude=refs/stash", "--exclude=refs/notes/*", "--exclude=refs/remotes/*/HEAD",
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
}
