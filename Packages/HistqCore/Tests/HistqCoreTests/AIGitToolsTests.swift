// Security tests for the chat's read-only git tools (task 6.2), each on a small temp repo built inline: refused
// arguments (option-like, unknown, `rev:path`, an ignored or escaping path) answer a fixed sentence and run no git
// process; an `.aiignore`d file (`secret.env`, `bí-mật/key.txt`, `deploy.key`) never shows in `git_grep`,
// `git_show`, `git_diff` or `git_log -S`/`-G` output, also by blob id, with a non-ASCII path quoted by
// `core.quotePath`, and with `color.ui=always` and diff prefixes in the repo's config; output stops at 32 KB; and
// `read_file`/`git_grep` show a line over the raw limit shortened and read on past it.
// The `.aiignore` is in memory (`AIIgnore(text:)`), so no committed file names the ignored paths.
import Foundation
import HistqCore
import Testing

struct AIGitToolsTests {
    static let ignore = AIIgnore(text: "secret.env\nbí-mật/\n*.key\n")
    static let cutNote = "[Histq: output cut at 32 KB]"

    /// A temp repo on `main` with a local identity, the hermetic environment, and a runner whose git is a script
    /// that logs one line per process before running the real git (setup runs through the plain runner).
    struct Repo {
        let folder: URL
        let repo: URL
        let base: [String: String]
        let runner = GitRunner(executable: Fixtures.git)
        let counting: GitRunner
        let log: URL

        init() async throws {
            folder = try Fixtures.makeTempDirectory("HistqGitTools")
            repo = folder.appending(path: "repo", directoryHint: .isDirectory)
            let home = folder.appending(path: "home", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            base = Fixtures.hermeticEnvironment(home: home)
            log = folder.appending(path: "git-processes.log")
            let script = folder.appending(path: "bin/counting-git")
            try Fixtures.writeScript("echo run >> '\(log.path)'\nexec '\(Fixtures.git.path)' \"$@\"", to: script)
            counting = GitRunner(executable: script)
            try await git(["init", "-q", "-b", "main"])
            try await git(["config", "user.name", "Tools Test"])
            try await git(["config", "user.email", "tools@histq.invalid"])
        }

        func remove() { Fixtures.removeTempDirectory(folder) }

        /// Git processes the tools ran so far.
        func processes() throws -> Int {
            guard FileManager.default.fileExists(atPath: log.path) else { return 0 }
            return try String(contentsOf: log, encoding: .utf8).split(separator: "\n").count
        }

        @discardableResult
        func git(_ args: [String]) async throws -> String {
            let text = try await runner.run(args, cwd: repo, env: base, timeout: .seconds(30)).text
            return text.hasSuffix("\n") ? String(text.dropLast()) : text
        }

        /// Writes `files` (creating folders), stages everything and commits; returns the new commit's hash.
        @discardableResult
        func commit(_ message: String, _ files: [String: String]) async throws -> String {
            for (path, text) in files {
                let url = URL(filePath: repo.path + "/" + path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }
            try await git(["add", "-A"])
            try await git(["commit", "-q", "-m", message])
            return try await git(["rev-parse", "HEAD"])
        }

        /// Runs one tool call through the counting runner with the read environment.
        func call(_ name: String, _ json: String, ignore: AIIgnore? = AIGitToolsTests.ignore
        ) async throws -> AIGitToolOutput {
            let env = try await GitInvocation.readEnvironment(profile: nil, base: base, runner: runner, cwd: repo)
            return await AIGitTools.run(AIToolCall(id: "t1", name: name, inputJSON: json), runner: counting,
                                        cwd: repo, env: env, ignore: ignore)
        }
    }

    /// Two commits touching a visible file and three ignored ones (one under a non-ASCII folder). Messages never name
    /// the ignored files or the secret marker. Returns the first commit.
    @discardableResult
    static func makeSecrets(_ repo: Repo) async throws -> String {
        let first = try await repo.commit("add files", [
            "ok.txt": "QUOKKA-OPEN alpha\n", "secret.env": "TOKEN=QUOKKA-SECRET-env\n",
            "bí-mật/key.txt": "QUOKKA-SECRET-bimat\n", "deploy.key": "QUOKKA-SECRET-key\n",
        ])
        try await repo.commit("update notes", [
            "ok.txt": "QUOKKA-OPEN alpha\nQUOKKA-OPEN beta\n",
            "secret.env": "TOKEN=QUOKKA-SECRET-env\nTOKEN2=QUOKKA-SECRET-two\n",
            "bí-mật/key.txt": "QUOKKA-SECRET-bimat\nQUOKKA-SECRET-bimat-two\n",
            "deploy.key": "QUOKKA-SECRET-key\nQUOKKA-SECRET-key-two\n",
        ])
        return first
    }

    /// Records an issue when `content` names an ignored file or holds its contents.
    static func expectNoSecret(_ content: String, _ label: String) {
        for leak in ["QUOKKA-SECRET", "secret.env", "bí-mật", "key.txt", "deploy.key", "\\303\\255"] {
            #expect(!content.contains(leak), "\(label) leaks \(leak)")
        }
    }

    // MARK: - Refused arguments

    @Test("option-like, unknown, rev:path, ignored or escaping arguments are refused and run no git")
    func refusedArgumentsRunNoGit() async throws {
        let repo = try await Repo()
        defer { repo.remove() }
        try await Self.makeSecrets(repo)

        let optionLike = "An argument starts with \"-\"; options can't be passed."
        let colon = "A revision can't contain \":\"; pass a file in the path argument."
        let ignored = "That path is excluded by .aiignore; it can't be read."
        let cases: [(name: String, json: String, message: String)] = [
            ("git_log", #"{"revision":"--output=quokka.out"}"#, optionLike),
            ("git_log", #"{"search":"--all"}"#, optionLike),
            ("git_log", #"{"regex":"-Gquokka"}"#, optionLike),
            ("git_show", #"{"revision":"HEAD","path":"-p"}"#, optionLike),
            ("git_diff", #"{"from":"HEAD~1","to":"--cached"}"#, optionLike),
            ("git_grep", #"{"pattern":"--open-files-in-pager=quokka"}"#, optionLike),
            ("git_blame", #"{"path":"ok.txt","revision":"-L1,1"}"#, optionLike),
            ("read_file", #"{"path":"--textconv"}"#, optionLike),
            ("git_log", #"{"revision":"HEAD","exec":"quokka"}"#,
             "The arguments include a name this tool does not take."),
            ("git_grep", #"{"pattern":"x","no_index":true}"#, "The arguments include a name this tool does not take."),
            ("git_push", #"{}"#, AIToolLoop.unknownTool),
            ("git_log", "not json", "The arguments are not valid for this tool."),
            ("git_log", #"{"max_count":500}"#, "A number is outside its allowed range."),
            ("git_show", #"{"revision":"HEAD:secret.env"}"#, colon),
            ("git_show", #"{"revision":"HEAD:bí-mật/key.txt"}"#, colon),
            ("git_diff", #"{"from":":secret.env"}"#, colon),
            ("git_diff", #"{"from":"HEAD~1","to":"HEAD:deploy.key"}"#, colon),
            ("read_file", #"{"path":"ok.txt","revision":"HEAD:secret.env"}"#, colon),
            ("read_file", #"{"path":"secret.env"}"#, ignored),
            ("read_file", #"{"path":"bí-mật/key.txt"}"#, ignored),
            ("git_blame", #"{"path":"deploy.key"}"#, ignored),
            ("git_show", #"{"revision":"HEAD","path":"secret.env"}"#, ignored),
            ("git_diff", #"{"from":"HEAD~1","path":"bí-mật/key.txt"}"#, ignored),
            ("git_grep", #"{"pattern":"QUOKKA","path":"deploy.key"}"#, ignored),
            ("git_log", #"{"path":"secret.env"}"#, ignored),
            ("read_file", #"{"path":"../secret.env"}"#,
             "The path must be relative to the repository root, without empty, \".\" or \"..\" parts."),
            ("read_file", #"{"path":"/etc/hosts"}"#,
             "The path must be relative to the repository root, without empty, \".\" or \"..\" parts."),
        ]
        for (name, json, message) in cases {
            let output = try await repo.call(name, json)
            #expect(output.result.isError, "\(name) \(json)")
            #expect(output.result.content == message, "\(name) \(json)")
            #expect(output.result.id == "t1")
            #expect(output.summary == nil)
            #expect(try repo.processes() == 0, "\(name) \(json) ran git")
        }

        // The counter works: an allowed call runs git.
        let allowed = try await repo.call("read_file", #"{"path":"ok.txt"}"#)
        #expect(!allowed.result.isError)
        #expect(allowed.result.content.contains("QUOKKA-OPEN beta"))
        #expect(try repo.processes() > 0)
    }

    // MARK: - .aiignore

    @Test("an ignored file never shows in git_grep, git_show or git_diff (also non-ASCII, quotePath on)")
    func ignoredFilesHiddenFromOutput() async throws {
        let repo = try await Repo()
        defer { repo.remove() }
        let first = try await Self.makeSecrets(repo)

        let grep = try await repo.call("git_grep", #"{"pattern":"QUOKKA"}"#)
        #expect(!grep.result.isError)
        #expect(grep.result.content == "ok.txt:1: QUOKKA-OPEN alpha\nok.txt:2: QUOKKA-OPEN beta\n")
        #expect(grep.summary == "2 matches")
        Self.expectNoSecret(grep.result.content, "git_grep")

        for pattern in ["QUOKKA-SECRET", "QUOKKA-SECRET-bimat", "bimat"] {
            let fixed = try await repo.call("git_grep", #"{"pattern":"\#(pattern)","fixed_strings":true}"#)
            #expect(fixed.result.content == "No matches.", "\(pattern)")
            #expect(fixed.summary == "0 matches")
        }

        let show = try await repo.call("git_show", #"{"revision":"HEAD"}"#)
        let diff = try await repo.call("git_diff", #"{"from":"\#(first)"}"#)
        let fromFirst = try await repo.call("git_show", #"{"revision":"\#(first)"}"#)
        for (label, output) in [("git_show", show), ("git_diff", diff), ("git_show first", fromFirst)] {
            #expect(!output.result.isError, "\(label)")
            #expect(output.result.content.contains("diff --git a/ok.txt b/ok.txt"), "\(label)")
            #expect(output.result.content.contains("QUOKKA-OPEN"), "\(label)")
            #expect(output.summary == "1 file", "\(label)")
            Self.expectNoSecret(output.result.content, label)
        }

        // The fixture holds the secrets: without .aiignore they show (the non-ASCII path C-quoted).
        let open = try await repo.call("git_show", #"{"revision":"HEAD"}"#, ignore: nil)
        #expect(open.result.content.contains("QUOKKA-SECRET-bimat-two"))
        #expect(open.result.content.contains("QUOKKA-SECRET-two"))
        #expect(open.result.content.contains("\"a/b\\303\\255-m\\341\\272\\255t/key.txt\""))
        let openGrep = try await repo.call("git_grep", #"{"pattern":"QUOKKA-SECRET-bimat"}"#, ignore: nil)
        #expect(openGrep.summary == "2 matches")
    }

    @Test("git_show and git_diff refuse a blob or tree id of an ignored file and never print its content")
    func objectIdsRefused() async throws {
        let repo = try await Repo()
        defer { repo.remove() }
        let first = try await Self.makeSecrets(repo)
        let blob = try await repo.git(["rev-parse", "HEAD:secret.env"])
        // `ls-tree`, not `rev-parse HEAD:<path>`: run through `GitRunner`, `rev-parse` doesn't find a non-ASCII path
        // in HEAD (it does in a shell), while `ls-tree` does.
        let unicodeBlob = try await repo.git(["ls-tree", "--object-only", "HEAD", "--", "bí-mật/key.txt"])
        let tree = try await repo.git(["ls-tree", "--object-only", "HEAD", "--", "bí-mật"])
        #expect(unicodeBlob.count == 40 && tree.count == 40)

        let notACommit = "The revision does not name a commit in this repository."
        let calls: [(String, String)] = [
            ("git_show", #"{"revision":"\#(blob)"}"#),
            ("git_show", #"{"revision":"\#(unicodeBlob)"}"#),
            ("git_show", #"{"revision":"\#(tree)"}"#),
            ("git_show", #"{"revision":"\#(blob.prefix(10))"}"#),
            ("git_diff", #"{"from":"\#(blob)","to":"\#(unicodeBlob)"}"#),
            ("git_diff", #"{"from":"\#(first)","to":"\#(blob)"}"#),
            ("git_diff", #"{"from":"\#(tree)"}"#),
            ("git_log", #"{"revision":"\#(blob)"}"#),
            ("read_file", #"{"path":"ok.txt","revision":"\#(unicodeBlob)"}"#),
        ]
        for (name, json) in calls {
            let output = try await repo.call(name, json)
            #expect(output.result.isError, "\(name) \(json)")
            #expect(output.result.content == notACommit, "\(name) \(json)")
            Self.expectNoSecret(output.result.content, name)
        }
    }

    @Test("git_log -S / -G for a string only ever in ignored files returns no commits (also non-ASCII)")
    func pickaxeSkipsIgnoredFiles() async throws {
        let repo = try await Repo()
        defer { repo.remove() }
        try await Self.makeSecrets(repo)
        let shared = try await repo.commit("shared word", [
            "ok.txt": "QUOKKA-OPEN alpha\nQUOKKA-OPEN beta\nQUOKKA-SHARED\n",
            "secret.env": "TOKEN=QUOKKA-SECRET-env\nTOKEN2=QUOKKA-SECRET-two\nQUOKKA-SHARED\n",
        ])

        for (key, value) in [("search", "QUOKKA-SECRET"), ("search", "QUOKKA-SECRET-env"),
                             ("search", "QUOKKA-SECRET-bimat"), ("search", "bimat-two"),
                             ("regex", "QUOKKA-SECRET"), ("regex", "SECRET-bimat"), ("regex", "TOKEN2=.*")] {
            let output = try await repo.call("git_log", #"{"\#(key)":"\#(value)"}"#)
            #expect(!output.result.isError, "\(key) \(value)")
            #expect(output.result.content == "No commits found.", "\(key) \(value)")
            #expect(output.summary == "0 commits", "\(key) \(value)")
        }

        // A string in a visible and an ignored file: the commit is listed with the visible file only.
        let both = try await repo.call("git_log", #"{"search":"QUOKKA-SHARED"}"#)
        #expect(both.summary == "1 commit")
        #expect(both.result.content.hasPrefix(shared))
        #expect(both.result.content.contains("    file: ok.txt\n"))
        Self.expectNoSecret(both.result.content, "git_log -S shared")

        // A plain log lists every commit but never an ignored file.
        let all = try await repo.call("git_log", "{}")
        #expect(all.summary == "3 commits")
        Self.expectNoSecret(all.result.content, "git_log")

        // The fixture holds the strings: without .aiignore the same searches find them.
        let open = try await repo.call("git_log", #"{"search":"QUOKKA-SECRET-bimat"}"#, ignore: nil)
        #expect(open.summary == "2 commits")
        #expect(open.result.content.contains("key.txt"))
        let openRegex = try await repo.call("git_log", #"{"regex":"QUOKKA-SECRET"}"#, ignore: nil)
        #expect(openRegex.summary == "2 commits")
    }

    @Test("color.ui=always and diff prefixes in the repo's config can't let an ignored diff through")
    func hostileDiffConfigStillFiltered() async throws {
        let repo = try await Repo()
        defer { repo.remove() }
        let first = try await Self.makeSecrets(repo)
        for (key, value) in [("color.ui", "always"), ("color.diff", "always"), ("diff.srcPrefix", "x/"),
                             ("diff.dstPrefix", "y/"), ("diff.mnemonicPrefix", "true")] {
            try await repo.git(["config", key, value])
        }

        let show = try await repo.call("git_show", #"{"revision":"HEAD"}"#)
        let diff = try await repo.call("git_diff", #"{"from":"\#(first)","to":"HEAD"}"#)
        for (label, output) in [("git_show", show), ("git_diff", diff)] {
            #expect(!output.result.isError, "\(label)")
            #expect(output.result.content.contains("diff --git a/ok.txt b/ok.txt"), "\(label)")
            #expect(!output.result.content.contains("\u{1B}"), "\(label) is colored")
            #expect(output.summary == "1 file", "\(label)")
            Self.expectNoSecret(output.result.content, label)
        }
    }

    // MARK: - Cap

    @Test("output stops at the 32 KB cap with the cut note")
    func outputStopsAtCap() async throws {
        let repo = try await Repo()
        defer { repo.remove() }
        let line = String(repeating: "q", count: 40)
        let big = (1...4_000).map { "line \($0) \(line)\n" }.joined()
        try await repo.commit("small file", ["big.txt": "start\n"])
        try await repo.commit("big file", ["big.txt": big])

        let calls: [(String, String, Bool)] = [
            ("read_file", #"{"path":"big.txt"}"#, true),
            ("git_grep", #"{"pattern":"line"}"#, true),
            ("git_blame", #"{"path":"big.txt"}"#, true),
            ("git_show", #"{"revision":"HEAD"}"#, false),
            ("git_diff", #"{"from":"HEAD~1"}"#, false),
        ]
        for (name, json, hasNote) in calls {
            let output = try await repo.call(name, json)
            #expect(!output.result.isError, "\(name)")
            #expect(output.result.content.utf8.count <= AIGitTools.maxOutputBytes, "\(name)")
            if hasNote { #expect(output.result.content.hasSuffix(Self.cutNote + "\n"), "\(name)") }
        }
        let show = try await repo.call("git_show", #"{"revision":"HEAD"}"#)
        #expect(show.result.content.contains("diff --git a/big.txt b/big.txt"))
        #expect(show.result.content.utf8.count > AIGitTools.maxOutputBytes / 2)
    }

    @Test("a 1 MB file on one line is read only from its start and shown shortened, without the cut note")
    func hugeSingleLineShownShortened() async throws {
        let repo = try await Repo()
        defer { repo.remove() }
        let size = 1_000_000
        try await repo.commit("one huge line", ["huge.txt": "QUOKKA-HUGE" + String(repeating: "q", count: size)])

        let read = try await repo.call("read_file", #"{"path":"huge.txt"}"#)
        let grep = try await repo.call("git_grep", #"{"pattern":"QUOKKA-HUGE"}"#)
        #expect(read.result.content.hasPrefix("1\tQUOKKA-HUGEqqq"))
        #expect(read.summary == "1 line")
        #expect(grep.result.content.hasPrefix("huge.txt:1: QUOKKA-HUGEqqq"))
        #expect(grep.summary == "1 match")
        for (name, output) in [("read_file", read), ("git_grep", grep)] {
            #expect(!output.result.isError, "\(name)")
            #expect(output.result.content.utf8.count <= AIGitTools.maxOutputBytes, "\(name)")
            #expect(output.result.content.hasSuffix("[Histq: line cut]\n"), "\(name)")
            #expect(!output.result.content.contains(Self.cutNote), "\(name)")
        }

        // The stream itself: the line comes as its first `maxLineBytes` bytes, marked, and the rest is dropped.
        var lines: [GitRunner.Line] = []
        for try await line in await repo.runner.stream(
            ["cat-file", "blob", "HEAD:huge.txt"], cwd: repo.repo, env: repo.base, timeout: .seconds(30),
            maxLineBytes: 4_096) {
            lines.append(line)
        }
        #expect(lines.count == 1)
        #expect(lines.first?.truncated == true)
        #expect(lines.first?.text.utf8.count == 4_096)
    }

    @Test("read_file and git_grep read on past a line longer than the raw limit")
    func readsPastHugeLine() async throws {
        let repo = try await Repo()
        defer { repo.remove() }
        let huge = "QUOKKA-HUGE" + String(repeating: "q", count: 300_000)
        try await repo.commit("huge second line", ["big.txt": "one\n\(huge)\nthree QUOKKA-AFTER\nfour\n"])

        let after = try await repo.call("read_file", #"{"path":"big.txt","start_line":3}"#)
        #expect(after.result.content == "3\tthree QUOKKA-AFTER\n4\tfour\n")
        #expect(after.summary == "2 lines")

        let all = try await repo.call("read_file", #"{"path":"big.txt"}"#)
        let lines = all.result.content.split(separator: "\n")
        #expect(all.summary == "4 lines")
        #expect(lines.count == 4 && lines[1].hasPrefix("2\tQUOKKA-HUGEqqq") && lines[1].hasSuffix("[Histq: line cut]"))
        #expect(all.result.content.hasSuffix("4\tfour\n"))
        #expect(!all.result.content.contains(Self.cutNote))

        let past = try await repo.call("read_file", #"{"path":"big.txt","start_line":9}"#)
        #expect(past.result.content == "The file has only 4 lines.")
        #expect(past.summary == "0 lines")

        let grep = try await repo.call("git_grep", #"{"pattern":"QUOKKA"}"#)
        #expect(grep.summary == "2 matches")
        #expect(grep.result.content.hasPrefix("big.txt:2: QUOKKA-HUGEqqq"))
        #expect(grep.result.content.hasSuffix("[Histq: line cut]\nbig.txt:3: three QUOKKA-AFTER\n"))
        #expect(!grep.result.content.contains(Self.cutNote))
    }
}
