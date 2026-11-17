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

    @Test("no hidden or soloed ref gives the shipped arguments, with the extra revisions at the end as before")
    func emptyHideAndSoloKeepArguments() {
        #expect(LogReader.arguments(hidden: [], solo: []) == LogReader.arguments)
        let hash = String(repeating: "a", count: 40)
        #expect(LogReader.arguments(hidden: [], solo: [], alsoFrom: [hash]) == LogReader.arguments + [hash])
    }

    @Test("hidden refs are excludes after the stash and notes excludes and before --all")
    func hiddenRefsPrecedeAll() throws {
        let args = LogReader.arguments(hidden: ["refs/heads/series", "refs/remotes/origin/HEAD"], solo: [])
        let all = try #require(args.firstIndex(of: "--all"))
        #expect(Array(args[..<all].suffix(4)) == [
            "--exclude=refs/stash", "--exclude=refs/notes/*", "--exclude=refs/heads/series",
            "--exclude=refs/remotes/origin/HEAD",
        ])
        #expect(args.filter { $0 != "--exclude=refs/heads/series" && $0 != "--exclude=refs/remotes/origin/HEAD" }
            == LogReader.arguments)
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

    @Test("names that are not full branch or remote refs, or that git forbids, are dropped")
    func invalidRefsAreDropped() {
        let invalid = [
            "main", "refs/tags/v1.0", "refs/heads/", "refs/heads/-x", "refs/heads/a..b", "refs/heads/a b",
            "refs/heads/x.lock", "refs/heads/a@{1}", "refs/heads/a~1", "refs/heads/a^", "refs/heads/a:b",
            "refs/heads/a?", "refs/heads/a*", "refs/heads/a[", "refs/heads/a\\b", "refs/heads/a\u{7}",
            "refs/heads/x/", "refs/heads/a//b", "refs/heads/.x", "refs/heads/x.", "refs/remotes/origin",
            "--all", "refs/heads/a..\u{301}b", "refs/heads/a~\u{301}1",
        ]
        #expect(LogReader.arguments(hidden: invalid, solo: []) == LogReader.arguments)
        #expect(LogReader.arguments(hidden: [], solo: invalid) == LogReader.arguments, "no valid solo ref: all refs")
        #expect(LogReader.arguments(hidden: [], solo: invalid + ["refs/heads/ok"]).suffix(4)
            == ["--end-of-options", "refs/heads/ok", "HEAD", "--"])
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
