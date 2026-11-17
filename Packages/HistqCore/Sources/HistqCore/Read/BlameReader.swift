// Reads `git blame --porcelain` of one file, at a commit or of the working tree, as runs of consecutive lines
// that come from the same commit.
import Foundation

/// A run of consecutive lines that come from one commit. Text fields come from the repo and are untrusted.
public struct BlameGroup: Sendable, Hashable {
    public struct Line: Sendable, Hashable {
        /// The line's number in the commit that added it (1-based).
        public let originalLine: Int
        /// The line's number in the blamed file (1-based).
        public let finalLine: Int
        /// The line without its newline (invalid UTF-8 shows as U+FFFD).
        public let text: String

        public init(originalLine: Int, finalLine: Int, text: String) {
            self.originalLine = originalLine
            self.finalLine = finalLine
            self.text = text
        }
    }

    /// The commit; all zeros for lines not committed yet (a working tree blame).
    public let hash: String
    public let authorName: String
    public let authorDate: Date
    public let summary: String
    public let lines: [Line]

    /// False for "Not Committed Yet" lines.
    public var isCommitted: Bool { hash.contains { $0 != "0" } }

    public init(hash: String, authorName: String, authorDate: Date, summary: String, lines: [Line]) {
        self.hash = hash
        self.authorName = authorName
        self.authorDate = authorDate
        self.summary = summary
        self.lines = lines
    }
}

public enum BlameReader {
    public static func resolveArguments(_ revision: String) -> [String] {
        ["rev-parse", "--verify", "--end-of-options", "\(revision)^{commit}"]
    }

    /// No `--end-of-options`: after it, git 2.54 blame reads `--` as a path (`fatal: bad revision`). `commit`
    /// is always an object ID `resolve` checked, so it can never be read as an option.
    public static func blameArguments(path: String, commit: String?) -> [String] {
        ["blame", "--porcelain", "--no-textconv"] + (commit.map { [$0] } ?? []) + ["--", path]
    }

    /// The blame of `path` (root-relative) at `revision` (any commit-ish), or of the working tree when nil, so
    /// uncommitted lines show as "Not Committed Yet". `env` must be the read environment built by
    /// `GitInvocation.readEnvironment` for this `cwd`, which blanks the repo's filter and textconv commands, so a
    /// working tree blame never runs a filter. Throws `GitError`; a failure is never retried with another
    /// environment.
    public static func read(
        _ path: String, revision: String? = nil, runner: GitRunner, cwd: URL, env: [String: String]
    ) async throws -> [BlameGroup] {
        var commit: String?
        if let revision {
            commit = try await resolve(revision, runner: runner, cwd: cwd, env: env)
        }
        return parse(try await runner.run(blameArguments(path: path, commit: commit), cwd: cwd, env: env).stdout)
    }

    private static func resolve(_ revision: String, runner: GitRunner, cwd: URL, env: [String: String])
        async throws -> String
    {
        let oid = try await runner.run(resolveArguments(revision), cwd: cwd, env: env).text
            .trimmingCharacters(in: .newlines)
        guard GitOperations.isObjectID(oid) else {
            throw GitError.other(exit: 1, stderrTail: "Not a commit: \(revision)")
        }
        return oid
    }

    /// Porcelain gives each line a `<hash> <original> <final>[ <count>]` header, the commit's `key value`
    /// lines only the first time the commit shows up, then the line's text after a TAB.
    static func parse(_ output: Data) -> [BlameGroup] {
        struct Info {
            var author = ""
            var time: TimeInterval = 0
            var summary = ""
        }
        var infos: [String: Info] = [:]
        var runs: [(hash: String, lines: [BlameGroup.Line])] = []
        var hash: String?
        var original = 0
        var final = 0
        for raw in output.split(separator: UInt8(ascii: "\n")) {
            if raw.first == UInt8(ascii: "\t") {
                guard let current = hash else { continue }
                let line = BlameGroup.Line(
                    originalLine: original, finalLine: final, text: String(decoding: raw.dropFirst(), as: UTF8.self))
                if runs.last?.hash == current {
                    runs[runs.count - 1].lines.append(line)
                } else {
                    runs.append((current, [line]))
                }
                hash = nil
                continue
            }
            let text = String(decoding: raw, as: UTF8.self)
            guard let space = text.firstIndex(of: " ") else { continue }
            let key = String(text[..<space])
            let value = String(text[text.index(after: space)...])
            if hash == nil {
                let numbers = value.split(separator: " ")
                guard LogParser.isHash(Substring(key)), numbers.count >= 2,
                      let originalLine = Int(numbers[0]), let finalLine = Int(numbers[1])
                else { continue }
                hash = key
                original = originalLine
                final = finalLine
                continue
            }
            guard let current = hash else { continue }
            switch key {
            case "author": infos[current, default: Info()].author = value
            case "author-time": infos[current, default: Info()].time = TimeInterval(value) ?? 0
            case "summary": infos[current, default: Info()].summary = value
            default: break
            }
        }
        return runs.map { run in
            let info = infos[run.hash] ?? Info()
            return BlameGroup(
                hash: run.hash, authorName: info.author, authorDate: Date(timeIntervalSince1970: info.time),
                summary: info.summary, lines: run.lines)
        }
    }
}
