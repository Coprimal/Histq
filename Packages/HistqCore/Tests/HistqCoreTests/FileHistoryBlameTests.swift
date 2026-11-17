// Tests for the file history and blame readers (task 1.1): paths and revisions from the repo never become
// options or pathspec magic, a real blame of the `graph` fixture groups lines by commit (at a commit and of the
// working tree, where an edit shows as not committed), and `--follow` keeps the old path across a rename.
import Foundation
import HistqCore
import Testing

struct FileHistoryBlameTests {
    /// A private copy of the fixtures, its `graph` repo and the read environment for it.
    struct Graph {
        let copy: FixtureCopy
        let repo: URL
        let env: [String: String]
        var runner: GitRunner { copy.runner }

        init() async throws {
            let copy = try await Fixtures.copy()
            self.copy = copy
            repo = copy.repo("graph")
            env = try await GitInvocation.readEnvironment(profile: nil, base: copy.base, runner: copy.runner, cwd: repo)
        }
    }

    // MARK: - Arguments

    @Test(
        "history keeps a dash or star path literal after --, the rev after --end-of-options, --follow only when asked")
    func historyArguments() {
        for path in ["-rf", "docs/*.md"] {
            let args = FileHistoryReader.arguments(path: path, revision: "--all", follow: false)
            #expect(args.first == "--literal-pathspecs")
            #expect(Array(args.suffix(2)) == ["--", path])
            let end = args.firstIndex(of: "--end-of-options")
            #expect(end.map { args[$0 + 1] } == "--all")
            #expect(args.contains("--no-ext-diff") && args.contains("--no-textconv"))
            #expect(!args.contains("--follow"))
        }
        #expect(FileHistoryReader.arguments(path: "a", revision: nil, follow: false).suffix(4)
            == ["--end-of-options", "HEAD", "--", "a"])
        let follow = FileHistoryReader.arguments(path: "a", revision: nil, follow: true)
        #expect(follow.filter { $0 == "--follow" }.count == 1)
        #expect(follow.firstIndex(of: "--follow")! < follow.firstIndex(of: "--end-of-options")!)
    }

    @Test("blame resolves the rev after --end-of-options and passes the path after -- without --end-of-options")
    func blameArguments() {
        #expect(BlameReader.resolveArguments("--output=x")
            == ["rev-parse", "--verify", "--end-of-options", "--output=x^{commit}"])
        #expect(BlameReader.blameArguments(path: "-rf", commit: nil)
            == ["blame", "--porcelain", "--no-textconv", "--", "-rf"])
        let oid = String(repeating: "a", count: 40)
        #expect(BlameReader.blameArguments(path: "docs/*.md", commit: oid)
            == ["blame", "--porcelain", "--no-textconv", oid, "--", "docs/*.md"])
    }

    // MARK: - Real reads

    @Test("blame at a commit oid groups the guide's lines by the two commits that wrote them")
    func blameAtCommit() async throws {
        let graph = try await Graph()
        defer { graph.copy.remove() }
        let head = try await graph.copy.git(["rev-parse", "HEAD"], in: graph.repo)
        let groups = try await BlameReader.read(
            "docs/guide.md", revision: head, runner: graph.runner, cwd: graph.repo, env: graph.env)

        #expect(groups.map(\.summary) == ["Add guide", "Link README from guide"])
        #expect(groups.allSatisfy { $0.isCommitted && $0.authorName == "Histq Fixture" })
        #expect(groups.map { $0.lines.map(\.text) }
            == [["# Guide", "", "How to use the fixture."], ["", "See README.md."]])
        #expect(groups.flatMap(\.lines).map(\.finalLine) == [1, 2, 3, 4, 5])
        #expect(groups[0].lines.map(\.originalLine) == [1, 2, 3])
        let added = try await graph.copy.git(["rev-parse", "v0.1"], in: graph.repo)
        #expect(groups[0].hash == added)
        #expect(groups[0].authorDate.timeIntervalSince1970 > 0)
    }

    @Test("a working tree blame reports an edited line as not committed")
    func blameWorkingTree() async throws {
        let graph = try await Graph()
        defer { graph.copy.remove() }
        let guide = graph.repo.appending(path: "docs/guide.md")
        var text = try String(contentsOf: guide, encoding: .utf8)
        text += "local edit\n"
        try text.write(to: guide, atomically: true, encoding: .utf8)

        let groups = try await BlameReader.read(
            "docs/guide.md", runner: graph.runner, cwd: graph.repo, env: graph.env)
        #expect(groups.map(\.summary).prefix(2) == ["Add guide", "Link README from guide"])
        let last = try #require(groups.last)
        #expect(groups.count == 3)
        #expect(!last.isCommitted && last.authorName == "Not Committed Yet")
        #expect(last.lines.map(\.text) == ["local edit"] && last.lines.map(\.finalLine) == [6])
    }

    @Test("blame refuses a revision that is not a commit")
    func blameRejectsOptionRevision() async throws {
        let graph = try await Graph()
        defer { graph.copy.remove() }
        await #expect(throws: GitError.self) {
            try await BlameReader.read(
                "docs/guide.md", revision: "--output=x", runner: graph.runner, cwd: graph.repo, env: graph.env)
        }
    }

    @Test("--follow lists the commits before a rename with the old path; without it the history starts at the rename")
    func followAcrossRename() async throws {
        let graph = try await Graph()
        defer { graph.copy.remove() }
        // The fixture has `old-name.txt` → `new-name.txt` staged; commit it in this copy.
        try await graph.copy.git(["commit", "-q", "-m", "Rename old-name"], in: graph.repo)

        let followed = try await FileHistoryReader.read(
            "new-name.txt", follow: true, runner: graph.runner, cwd: graph.repo, env: graph.env)
        #expect(followed.map(\.commit.subject) == ["Rename old-name", "Initial commit"])
        let rename = try #require(followed.first)
        #expect(rename.status == "R" && rename.path == "new-name.txt" && rename.oldPath == "old-name.txt")
        let initial = try #require(followed.last)
        #expect(initial.status == "A" && initial.path == "old-name.txt" && initial.oldPath == nil)
        #expect(initial.commit.authorName == "Histq Fixture" && initial.commit.parents.isEmpty)

        let plain = try await FileHistoryReader.read(
            "new-name.txt", runner: graph.runner, cwd: graph.repo, env: graph.env)
        #expect(plain.map(\.commit.subject) == ["Rename old-name"])
        #expect(plain.first?.status == "A" && plain.first?.path == "new-name.txt")
    }

    @Test("a history path holding a star is literal, so it matches no file")
    func historyStarIsLiteral() async throws {
        let graph = try await Graph()
        defer { graph.copy.remove() }
        let star = try await FileHistoryReader.read(
            "docs/*.md", runner: graph.runner, cwd: graph.repo, env: graph.env)
        #expect(star.isEmpty)
        let guide = try await FileHistoryReader.read(
            "docs/guide.md", runner: graph.runner, cwd: graph.repo, env: graph.env)
        #expect(guide.map(\.commit.subject) == ["Link README from guide", "Add guide"])
        #expect(guide.allSatisfy { $0.path == "docs/guide.md" })
    }
}
