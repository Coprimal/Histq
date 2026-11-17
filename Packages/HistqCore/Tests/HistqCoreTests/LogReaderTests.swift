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

    @Test(
        "an excluded ref's own commits leave the log, shared ones stay, a remote's HEAD does not keep them; a glob or non-refs/ entry is ignored")
    func excludedRefLeavesTheLog() async throws {
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
        /// The hashes of the whole log read with `excluding`.
        func hashes(excluding refNames: [String]) async throws -> Set<String> {
            var commits: [Commit] = []
            for try await page in LogReader.pages(runner: sandbox.runner, cwd: repo, env: env, excluding: refNames) {
                commits += page
            }
            return Set(commits.map(\.hash))
        }

        let all = try await hashes(excluding: [])
        #expect(all.contains(sideOnly) && all.contains(shared) && all.count == 3)
        let hidden = try await hashes(excluding: ["refs/heads/side"])
        #expect(!hidden.contains(sideOnly), "the side branch's own commit is gone")
        #expect(hidden.contains(shared), "main still reaches the shared commit")
        #expect(hidden.count == 2)
        #expect(try await hashes(excluding: ["refs/heads/*"]) == all, "a glob would hide every branch")
        #expect(try await hashes(excluding: ["heads/side", "side"]) == all, "only full refs/ names count")

        // A remote's HEAD is a symref the user cannot hide: hiding its branch must still drop the branch's commits.
        try await sandbox.git(["update-ref", "refs/remotes/origin/main", sideOnly], in: repo)
        try await sandbox.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], in: repo)
        let remoteHidden = try await hashes(excluding: ["refs/heads/side", "refs/remotes/origin/main"])
        #expect(!remoteHidden.contains(sideOnly), "origin/HEAD does not bring back the hidden origin/main")
        #expect(remoteHidden.count == 2)
    }
}
