// Key feature test for the local pull request diff (`GitOperations.pullRequestFiles`, for hosts with no diff API):
// the branches are fetched without touching a ref or FETCH_HEAD (a stale tracking ref stays stale), and the files and
// patches are those of `git diff <target>...<source>`. A pull request from a fork gets the fork message without a
// fetch; a commit the fetch did not bring says the pull request changed.
import Foundation
import HistqCore
import Testing

struct PullRequestDiffTests {
    /// A bare `origin.git` with `main` and `feature`, `seed` (which pushes to it) and `clone`, cloned and fetched
    /// before `seed` pushed one more commit to `feature`: the clone's `origin/feature` is stale and `source` (the new
    /// head) is not in the clone. `main` moved on after `feature` forked, so `target..source` is not `target...source`.
    struct Fixture {
        let sandbox: Sandbox
        let seed: URL
        let clone: URL
        let source: String
        let target: String
        let ops: GitOperations

        init() async throws {
            sandbox = try await Sandbox()
            let origin = sandbox.root.appending(path: "origin.git", directoryHint: .isDirectory)
            try await sandbox.git(["init", "-q", "--bare", "-b", "main", origin.path], in: sandbox.root)
            seed = try await sandbox.makeRepo("seed")
            let lines = (1...20).map { "line \($0)\n" }.joined()
            try Data(lines.utf8).write(to: seed.appending(path: "moved.txt"))
            try await sandbox.git(["add", "moved.txt"], in: seed)
            try await sandbox.git(["commit", "-q", "-m", "moved"], in: seed)
            try await sandbox.git(["remote", "add", "origin", origin.path], in: seed)
            try await sandbox.git(["push", "-q", "origin", "main"], in: seed)

            try await sandbox.git(["checkout", "-q", "-b", "feature"], in: seed)
            try Data("hello\nfeature\n".utf8).write(to: seed.appending(path: "tracked.txt"))
            try Data("added\n".utf8).write(to: seed.appending(path: "added.txt"))
            try await sandbox.git(["add", "tracked.txt", "added.txt"], in: seed)
            try await sandbox.git(["mv", "moved.txt", "renamed.txt"], in: seed)
            try await sandbox.git(["commit", "-q", "-m", "feature"], in: seed)
            try await sandbox.git(["push", "-q", "origin", "feature"], in: seed)

            try await sandbox.git(["checkout", "-q", "main"], in: seed)
            try Data("main only\n".utf8).write(to: seed.appending(path: "main-only.txt"))
            try await sandbox.git(["add", "main-only.txt"], in: seed)
            try await sandbox.git(["commit", "-q", "-m", "main moves on"], in: seed)
            try await sandbox.git(["push", "-q", "origin", "main"], in: seed)

            clone = sandbox.root.appending(path: "clone", directoryHint: .isDirectory)
            try await sandbox.git(["clone", "-q", origin.path, clone.path], in: sandbox.root)
            // A FETCH_HEAD that must stay byte for byte.
            try await sandbox.git(["fetch", "-q", "origin"], in: clone)

            try await sandbox.git(["checkout", "-q", "feature"], in: seed)
            try Data("added\nmore\n".utf8).write(to: seed.appending(path: "added.txt"))
            try await sandbox.git(["commit", "-q", "-a", "-m", "feature again"], in: seed)
            try await sandbox.git(["push", "-q", "origin", "feature"], in: seed)
            source = try await sandbox.git(["rev-parse", "feature"], in: seed)
            target = try await sandbox.git(["rev-parse", "main"], in: seed)
            ops = GitOperations(
                runner: sandbox.runner, cwd: clone, env: GitInvocation.environment(profile: nil, base: sandbox.base),
                networkTimeout: .seconds(30))
        }

        func has(_ sha: String) async -> Bool {
            let result = try? await sandbox.runner.run(
                ["cat-file", "-e", "\(sha)^{commit}"], cwd: clone, env: sandbox.base, allowedExitCodes: [0, 1, 128])
            return result?.exitCode == 0
        }

        var fetchHead: Data? { try? Data(contentsOf: clone.appending(path: ".git/FETCH_HEAD")) }
    }

    /// Each file's lines of a git diff from its first `@@` (empty for a file with no hunk), in the diff's order.
    static func patches(_ diff: String) -> [String] {
        var chunks: [[Substring]] = []
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                chunks.append([])
            } else if !chunks.isEmpty {
                chunks[chunks.count - 1].append(line)
            }
        }
        return chunks.map { lines in
            guard let start = lines.firstIndex(where: { $0.hasPrefix("@@") }) else { return "" }
            var body = Array(lines[start...])
            while body.last?.isEmpty == true { body.removeLast() }
            return body.joined(separator: "\n")
        }
    }

    @Test("the files and patches are git diff target...source, and no ref or FETCH_HEAD changes")
    func diffMatchesThreeDotDiffAndLeavesRefs() async throws {
        let fx = try await Fixture()
        defer { fx.sandbox.remove() }
        let refsBefore = try await fx.sandbox.git(["for-each-ref"], in: fx.clone)
        let fetchHeadBefore = fx.fetchHead
        #expect(fetchHeadBefore != nil)
        #expect(!(await fx.has(fx.source)), "the clone already had the new head")

        let files = try await fx.ops.pullRequestFiles(
            remote: "origin", sourceBranch: "feature", targetBranch: "main", sourceCommit: fx.source,
            targetCommit: fx.target, fromFork: false)

        #expect(await fx.has(fx.source), "the fetch did not bring the new head")
        #expect(try await fx.sandbox.git(["for-each-ref"], in: fx.clone) == refsBefore)
        #expect(fx.fetchHead == fetchHeadBefore)

        let range = "\(fx.target)...\(fx.source)"
        let flags = ["--no-color", "--no-ext-diff", "--no-textconv", "-M"]
        let names = try await fx.sandbox.git(["diff"] + flags + ["--name-only", range], in: fx.seed)
        let reference = try await fx.sandbox.git(["diff"] + flags + [range], in: fx.seed)
        #expect(files.map(\.filename) == names.split(separator: "\n").map(String.init))
        #expect(files.map(\.filename) == ["added.txt", "renamed.txt", "tracked.txt"])
        #expect(files.map { $0.patch ?? "" } == Self.patches(reference))
        #expect(files.first { $0.filename == "renamed.txt" }?.previousFilename == "moved.txt")
        #expect(files.first { $0.filename == "added.txt" }?.status == "added")
        #expect(files.first { $0.filename == "added.txt" }?.additions == 2)
    }

    @Test("a pull request from a fork gets the fork message and fetches nothing")
    func forkIsSkipped() async throws {
        let fx = try await Fixture()
        defer { fx.sandbox.remove() }
        await #expect(throws: PullRequestDiffError.fromFork) {
            try await fx.ops.pullRequestFiles(
                remote: "origin", sourceBranch: "feature", targetBranch: "main", sourceCommit: fx.source,
                targetCommit: fx.target, fromFork: true)
        }
        #expect(PullRequestDiffError.fromFork.message == "Files of pull requests from forks are shown on the web")
        #expect(!(await fx.has(fx.source)), "a fork pull request ran a fetch")
    }

    @Test("a commit the fetch did not bring says the pull request changed; a commit that is not hex is refused")
    func missingCommitSaysChanged() async throws {
        let fx = try await Fixture()
        defer { fx.sandbox.remove() }
        let gone = String(repeating: "1", count: 40)
        await #expect(throws: PullRequestDiffError.changed) {
            try await fx.ops.pullRequestFiles(
                remote: "origin", sourceBranch: "feature", targetBranch: "main", sourceCommit: gone,
                targetCommit: fx.target, fromFork: false)
        }
        await #expect(throws: GitOperationError.invalidObjectID("--output=x")) {
            try await fx.ops.pullRequestFiles(
                remote: "origin", sourceBranch: "feature", targetBranch: "main", sourceCommit: fx.source,
                targetCommit: "--output=x", fromFork: false)
        }
    }
}
