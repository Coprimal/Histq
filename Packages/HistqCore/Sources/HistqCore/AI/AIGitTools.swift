// The read-only git tools the AI chat may call: `git_log`, `git_show`, `git_diff`, `git_blame`, `git_grep` and
// `read_file`. They read committed revisions only (never the working tree, never the network) and never take a model
// argv: arguments are typed and strictly decoded (unknown keys, values starting with `-`, control characters and
// over-long values refused), a revision is resolved to a commit id with `rev-parse --verify --end-of-options
// <rev>^{commit}` and only that id reaches git (no `rev:path`, blob or tree ids), and a path must be a plain
// root-relative path. `.aiignore` is privacy-grade here too: a path argument it matches (as a file or a folder) is
// refused, diffs go through `AIPrompts.filtered`, every path git prints is read from NUL-separated output and parsed
// verbatim (fail closed), and a `-S`/`-G` search or a path-limited log drops the commits whose listed files are all
// ignored, silently (no probing). Each call has a 15 s deadline and a 32 KB output cap, reading through
// `GitRunner.stream` and stopping git early. A line (or `-z` record) longer than `rawLimit` arrives as its start (the
// rest is dropped as git writes it), so one huge line is never held whole: `read_file` and `git_grep` show it
// shortened ("[Histq: line cut]") and read on, the other tools stop there with the cut note. The cut note means only
// that output was cut at the cap.
//
// `run` returns the raw (already filtered) output: `AIToolLoop` wraps every tool result in a data block with the
// data notice on both protocols (`AIPrompts.toolOutputContent`, `AITextToolProtocol.resultText`), so it is not
// wrapped twice. Error results are fixed app sentences that never echo model input or git's stderr.
import Foundation

/// The answer to one git tool call, and a short count for the chat's tool row ("3 commits"); nil when it failed.
public struct AIGitToolOutput: Sendable, Equatable {
    public let result: AIToolResult
    public let summary: String?
}

public enum AIGitTools {
    /// Output bytes one call returns at most (well under `AIToolLoop.outputBudget`).
    public static let maxOutputBytes = 32 * 1024
    /// Raw output read before `.aiignore` filtering and the cap (filtering may drop most of it).
    static let rawLimit = 4 * maxOutputBytes
    public static let timeout: Duration = .seconds(15)
    public static let maxLogCount = 50
    static let defaultLogCount = 20
    /// Files `git_log` lists per commit, so one big commit can't fill the whole output.
    static let maxLogFiles = 50
    static let maxRevisionLength = 256
    static let maxPathLength = 1_024
    static let maxPatternLength = 512
    static let maxLineNumber = 10_000_000
    /// Characters of one file line shown by `git_grep`, `read_file` and `git_blame` (a minified line stays short).
    static let maxLineCharacters = 2_000
    static let cutNote = "[Histq: output cut at 32 KB]"
    /// Bytes of output before the cut note, so output and note stay within `maxOutputBytes`.
    static let room = maxOutputBytes - cutNote.utf8.count - 1

    // MARK: - Specs

    public static let specs: [AIToolSpec] = [
        AIToolSpec(
            name: "git_log",
            description: "List commits (newest first) with their changed files. Optionally only commits touching "
                + "a path, or whose changes add or remove a string (search, like git log -S) or change lines "
                + "matching a regular expression (regex, like git log -G). Committed history only.",
            schema: schema([
                "revision": revision("Commit to start from (default HEAD)."),
                "path": path("Only commits touching this file or folder."),
                "search": text("Only commits that change the number of occurrences of this string."),
                "regex": text("Only commits whose added or removed lines match this regular expression."),
                "max_count": integer("Most commits to list (default 20).", min: 1, max: maxLogCount),
            ], required: [])),
        AIToolSpec(
            name: "git_show",
            description: "Show one commit: author, date, full message and its diff (against the first parent).",
            schema: schema([
                "revision": revision("The commit to show."),
                "path": path("Only the diff of this file or folder."),
            ], required: ["revision"])),
        AIToolSpec(
            name: "git_diff",
            description: "Diff between two commits.",
            schema: schema([
                "from": revision("The older commit."),
                "to": revision("The newer commit (default HEAD)."),
                "path": path("Only the diff of this file or folder."),
            ], required: ["from"])),
        AIToolSpec(
            name: "git_blame",
            description: "Show which commit last changed each line of a file at a revision.",
            schema: schema([
                "path": path("The file."),
                "revision": revision("The commit to blame at (default HEAD)."),
                "start_line": integer("First line (1-based).", min: 1, max: maxLineNumber),
                "end_line": integer("Last line.", min: 1, max: maxLineNumber),
            ], required: ["path"])),
        AIToolSpec(
            name: "git_grep",
            description: "Search the files of a revision for lines matching a pattern (extended regular expression, "
                + "or a fixed string). Prints path, line number and line.",
            schema: schema([
                "pattern": text("What to search for."),
                "revision": revision("The commit to search (default HEAD)."),
                "path": path("Only search this file or folder."),
                "fixed_strings": .object([
                    "type": .string("boolean"),
                    "description": .string("Match the pattern as a fixed string, not a regular expression."),
                ]),
            ], required: ["pattern"])),
        AIToolSpec(
            name: "read_file",
            description: "Read a file as it is at a revision, with line numbers.",
            schema: schema([
                "path": path("The file."),
                "revision": revision("The commit to read from (default HEAD)."),
                "start_line": integer("First line (1-based).", min: 1, max: maxLineNumber),
                "end_line": integer("Last line.", min: 1, max: maxLineNumber),
            ], required: ["path"])),
    ]

    private static func schema(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        var object: [String: JSONValue] = [
            "type": .string("object"), "properties": .object(properties), "additionalProperties": .bool(false),
        ]
        if !required.isEmpty { object["required"] = .array(required.map(JSONValue.string)) }
        return .object(object)
    }

    private static func string(_ description: String, maxLength: Int) -> JSONValue {
        .object([
            "type": .string("string"), "description": .string(description), "minLength": .int(1),
            "maxLength": .int(maxLength),
        ])
    }

    private static func revision(_ description: String) -> JSONValue {
        string(description + " A branch, tag or commit id, optionally with ~ or ^; no ':'.",
               maxLength: maxRevisionLength)
    }

    private static func path(_ description: String) -> JSONValue {
        string(description + " Relative to the repository root.", maxLength: maxPathLength)
    }

    private static func text(_ description: String) -> JSONValue {
        string(description, maxLength: maxPatternLength)
    }

    private static func integer(_ description: String, min: Int, max: Int) -> JSONValue {
        .object([
            "type": .string("integer"), "description": .string(description), "minimum": .int(min),
            "maximum": .int(max),
        ])
    }

    // MARK: - Run

    /// Runs `call` in the repository at `cwd` with the read environment `env` (no profile). `ignore` is the
    /// repository's `.aiignore`, loaded by the caller for this call (nil: none). Never throws: a refusal, a git
    /// failure, the timeout or cancellation is an error result.
    public static func run(
        _ call: AIToolCall, runner: GitRunner, cwd: URL, env: [String: String], ignore: AIIgnore?
    ) async -> AIGitToolOutput {
        let git = Git(runner: runner, cwd: cwd, env: env, deadline: .now.advanced(by: timeout))
        do {
            let (content, summary) = try await output(call, git: git, ignore: ignore)
            return AIGitToolOutput(result: AIToolResult(id: call.id, content: content, isError: false),
                                   summary: summary)
        } catch {
            let message = (error as? ToolError)?.message
                ?? (error is CancellationError ? "The call was cancelled." : ToolError.gitFailed.message)
            return AIGitToolOutput(result: AIToolResult(id: call.id, content: message, isError: true), summary: nil)
        }
    }

    private static func output(_ call: AIToolCall, git: Git, ignore: AIIgnore?) async throws -> (String, String) {
        switch call.name {
        case "git_log":
            let a = try Arguments(call.inputJSON, allowed: ["revision", "path", "search", "regex", "max_count"])
            let revision = try a.revision("revision")
            let path = try a.path("path", ignore: ignore)
            let search = try a.string("search", max: maxPatternLength)
            let regex = try a.string("regex", max: maxPatternLength)
            if search != nil, regex != nil { throw ToolError.bothSearches }
            let count = try a.int("max_count", in: 1...maxLogCount) ?? defaultLogCount
            let commit = try await git.commit(revision)
            return try await log(commit, path: path, pickaxe: search.map { "-S" + $0 } ?? regex.map { "-G" + $0 },
                                 count: count, git: git, ignore: ignore)
        case "git_show":
            let a = try Arguments(call.inputJSON, allowed: ["revision", "path"])
            let revision = try a.required(a.revision("revision"))
            let path = try a.path("path", ignore: ignore)
            let commit = try await git.commit(revision)
            return try await diff(
                ["--literal-pathspecs", "show", "--no-show-signature", "--no-notes", "--diff-merges=first-parent",
                 "--submodule=short", "--date=iso-strict",
                 "--format=commit %H%nAuthor: %an <%ae>%nDate:   %ad%n%n%w(0,4,4)%B"]
                    + DiffReader.formatOptions + ["--end-of-options", commit, "--"] + (path.map { [$0] } ?? []),
                git: git, ignore: ignore)
        case "git_diff":
            let a = try Arguments(call.inputJSON, allowed: ["from", "to", "path"])
            let from = try a.required(a.revision("from"))
            let to = try a.revision("to")
            let path = try a.path("path", ignore: ignore)
            // Both sides are always commits: one side alone would diff against the working tree.
            let base = try await git.commit(from)
            let head = try await git.commit(to)
            return try await diff(
                ["--literal-pathspecs", "diff"] + DiffReader.formatOptions
                    + ["--submodule=short", "--end-of-options", base, head, "--"] + (path.map { [$0] } ?? []),
                git: git, ignore: ignore)
        case "git_blame":
            let a = try Arguments(call.inputJSON, allowed: ["path", "revision", "start_line", "end_line"])
            let path = try a.required(a.path("path", ignore: ignore))
            let revision = try a.revision("revision")
            let range = try a.lineRange()
            let commit = try await git.commit(revision)
            try await git.requireBlob(commit, path)
            return try await blame(commit, path: path, range: range, git: git)
        case "git_grep":
            let a = try Arguments(call.inputJSON, allowed: ["pattern", "revision", "path", "fixed_strings"])
            let pattern = try a.required(a.string("pattern", max: maxPatternLength))
            let revision = try a.revision("revision")
            let path = try a.path("path", ignore: ignore)
            let fixed = try a.bool("fixed_strings") ?? false
            let commit = try await git.commit(revision)
            return try await grep(pattern, fixed: fixed, commit: commit, path: path, git: git, ignore: ignore)
        case "read_file":
            let a = try Arguments(call.inputJSON, allowed: ["path", "revision", "start_line", "end_line"])
            let path = try a.required(a.path("path", ignore: ignore))
            let revision = try a.revision("revision")
            let range = try a.lineRange()
            let commit = try await git.commit(revision)
            try await git.requireBlob(commit, path)
            return try await readFile(commit, path: path, range: range, git: git)
        default:
            throw ToolError.unknownTool
        }
    }

    // MARK: - Tools

    /// `git log` from `commit`, each commit with its changed files (`-z --name-only`, ignored paths dropped). A
    /// header carries a per-call random token, so a path can never pass for one. With `pickaxe` (`-S…`/`-G…`), git
    /// lists only the matching files (with `path`, only the files under it), and a commit whose listed files are all
    /// ignored (or unparseable) is dropped silently; the count and the cap apply to the commits kept, so neither
    /// tells whether one was dropped.
    private static func log(
        _ commit: String, path: String?, pickaxe: String?, count: Int, git: Git, ignore: AIIgnore?
    ) async throws -> (String, String) {
        let token = AIPrompts.randomToken()
        let args = ["--literal-pathspecs", "log", "--no-color", "--no-show-signature", "--no-notes", "--no-follow",
                    "--no-diff-merges", "--no-renames", "--no-relative", "--no-ext-diff", "--no-textconv", "-z",
                    "--name-only", "--date=short", "--format=\(token)%H%n%ad%n%an%n%s"]
            + (pickaxe.map { [$0] } ?? []) + ["--end-of-options", commit, "--"] + (path.map { [$0] } ?? [])

        var list = LogList(limit: count, needsVisibleFile: pickaxe != nil || path != nil)
        // A record cut at `rawLimit` is dropped with the commit it belongs to.
        if try await git.read(args, delimiter: 0, { record in
            if record.hasPrefix(token) {
                guard list.finish() else { return false }
                list.start(record.dropFirst(token.count))
                return true
            }
            list.add(record, ignore: ignore)
            return true
        }) { list.cut = true }
        if !list.cut { _ = list.finish() }
        if list.out.isEmpty { return (list.cut ? cutNote : "No commits found.", "0 commits") }
        return (list.cut ? list.out + "\n" + cutNote : list.out, counted(list.kept, "commit"))
    }

    /// The commits `log` keeps, rendered as they are read.
    private struct LogList {
        struct Entry {
            var header: [Substring]
            var paths: [String] = []
            var firstPath = true
            var broken = false
        }

        let limit: Int
        let needsVisibleFile: Bool
        var out = ""
        var kept = 0
        var cut = false
        var current: Entry?

        init(limit: Int, needsVisibleFile: Bool) {
            self.limit = limit
            self.needsVisibleFile = needsVisibleFile
        }

        /// A new commit from its header (`%H`, `%ad`, `%an`, `%s` on lines, the token removed).
        mutating func start(_ header: Substring) {
            let fields = header.split(separator: "\n", omittingEmptySubsequences: false)
            current = Entry(header: fields)
            if fields.count < 3 || !GitOperations.isObjectID(String(fields[0])) { current?.broken = true }
        }

        /// One file of the current commit, unless `.aiignore` excludes it or it can't be read for sure.
        mutating func add(_ record: String, ignore: AIIgnore?) {
            guard var entry = current else { return }
            var name = Substring(record)
            if entry.firstPath {
                // git starts a commit's file list with a newline; without it the record can't be read for sure.
                guard name.unicodeScalars.first == "\n" else {
                    entry.broken = true
                    current = entry
                    return
                }
                name = Substring(name.unicodeScalars.dropFirst())
                entry.firstPath = false
            }
            if let path = visiblePath(String(name), ignore: ignore) { entry.paths.append(path) }
            current = entry
        }

        /// Adds the finished current commit (with a pickaxe or a path, only when one of its files is shown); false
        /// once the count or the cap is reached.
        mutating func finish() -> Bool {
            guard let entry = current else { return true }
            current = nil
            guard !entry.broken, !(needsVisibleFile && entry.paths.isEmpty) else { return true }
            let subject = entry.header.count > 3 ? entry.header[3] : ""
            let more = entry.paths.count - maxLogFiles
            let text = "\(entry.header[0]) \(entry.header[1]) \(entry.header[2])\n    \(subject)\n"
                + entry.paths.prefix(maxLogFiles).map { "    file: \($0)\n" }.joined()
                + (more > 0 ? "    [Histq: \(more) more files]\n" : "")
            guard out.utf8.count + text.utf8.count + 1 <= room else {
                cut = true
                return false
            }
            out += (out.isEmpty ? "" : "\n") + text
            kept += 1
            return kept < limit
        }
    }

    /// A patch-producing command (`show`/`diff` with `DiffReader.formatOptions`): read up to `rawLimit`, filtered
    /// with `.aiignore` (`AIPrompts.filtered`), then cut at line boundaries to `maxOutputBytes`.
    private static func diff(_ args: [String], git: Git, ignore: AIIgnore?) async throws -> (String, String) {
        var raw = ""
        var cut = false
        if try await git.read(args, delimiter: UInt8(ascii: "\n"), { line in
            guard raw.utf8.count + line.utf8.count + 1 <= rawLimit else {
                cut = true
                return false
            }
            raw += line + "\n"
            return true
        }) { cut = true }
        let kept = AIPrompts.filtered(raw, ignore: ignore)
        var text = AIPrompts.budgeted(kept, budget: room)
        if cut { text += cutNote + "\n" }
        let files = text.split(separator: "\n").count {
            $0.hasPrefix("diff --git ") || $0.hasPrefix("diff --cc ") || $0.hasPrefix("diff --combined ")
        }
        return (text.isEmpty ? "No changes." : text, counted(files, "file"))
    }

    /// `git grep --null` in `commit`: each record is `<commit>:<path>\0<line>\0<text>`, read verbatim; a record that
    /// is not exactly that, or whose path is ignored, is dropped silently.
    private static func grep(
        _ pattern: String, fixed: Bool, commit: String, path: String?, git: Git, ignore: AIIgnore?
    ) async throws -> (String, String) {
        let args = ["--literal-pathspecs", "grep", "--null", "--no-color", "--full-name", "--no-column",
                    "--no-recurse-submodules", "--no-textconv", "-n", "-I", fixed ? "-F" : "-E", "-e", pattern,
                    commit, "--"] + (path.map { [$0] } ?? [])
        let prefix = Array((commit + ":").utf8)
        var out = ""
        var matches = 0
        var cut = false
        if try await git.read(args, delimiter: UInt8(ascii: "\n"), noMatchIsEmpty: true, stopAtCutLine: false, { line in
            let bytes = Array(line.utf8)
            guard bytes.starts(with: prefix),
                  let pathEnd = bytes[prefix.count...].firstIndex(of: 0),
                  let numberEnd = bytes[(pathEnd + 1)...].firstIndex(of: 0),
                  numberEnd > pathEnd + 1,
                  bytes[(pathEnd + 1)..<numberEnd].allSatisfy({ (48...57).contains($0) }),
                  let name = visiblePath(String(decoding: bytes[prefix.count..<pathEnd], as: UTF8.self),
                                         ignore: ignore)
            else { return true }
            let number = String(decoding: bytes[(pathEnd + 1)..<numberEnd], as: UTF8.self)
            let text = shortened(String(decoding: bytes[(numberEnd + 1)...], as: UTF8.self))
            let entry = "\(name):\(number): \(text)\n"
            guard out.utf8.count + entry.utf8.count <= room else {
                cut = true
                return false
            }
            out += entry
            matches += 1
            return true
        }) { cut = true }
        if out.isEmpty { return (cut ? cutNote : "No matches.", "0 matches") }
        return (cut ? out + cutNote + "\n" : out, counted(matches, "match", plural: "matches"))
    }

    /// The lines `range` of the blob `<commit>:<path>` (checked to be a blob), numbered.
    private static func readFile(
        _ commit: String, path: String, range: ClosedRange<Int>, git: Git
    ) async throws -> (String, String) {
        var out = ""
        var number = 0
        var shown = 0
        var cut = false
        var binary = false
        let args = ["--literal-pathspecs", "cat-file", "blob", "\(commit):\(path)"]
        if try await git.read(args, delimiter: UInt8(ascii: "\n"), stopAtCutLine: false, { line in
            if line.utf8.contains(0) {
                binary = true
                return false
            }
            number += 1
            guard number >= range.lowerBound else { return true }
            guard number <= range.upperBound else { return false }
            let entry = "\(number)\t\(shortened(line))\n"
            guard out.utf8.count + entry.utf8.count <= room else {
                cut = true
                return false
            }
            out += entry
            shown += 1
            return true
        }) { cut = true }
        if binary { throw ToolError.binary }
        if shown == 0, !cut {
            return (number == 0 ? "The file is empty." : "The file has only \(counted(number, "line")).", "0 lines")
        }
        return (cut ? out + cutNote + "\n" : out, counted(shown, "line"))
    }

    /// `git blame --porcelain` of `path` at `commit` (checked to be a blob), parsed by `BlameReader.parse` and
    /// rendered as commit, date, author and summary per run of lines: the porcelain `filename`/`previous` lines,
    /// which may name an older (ignored) path, are never shown. Porcelain output has no color; `--no-color` is
    /// ambiguous for blame (git 2.54), so its two color options are turned off by name.
    private static func blame(
        _ commit: String, path: String, range: ClosedRange<Int>, git: Git
    ) async throws -> (String, String) {
        let lines = "-L\(range.lowerBound)," + (range.upperBound == maxLineNumber ? "" : "\(range.upperBound)")
        // No `--end-of-options`: blame then reads `--` as a path (see `BlameReader.blameArguments`); `commit` is an id.
        let args = ["--literal-pathspecs", "blame", "--porcelain", "--no-textconv", "--no-color-lines",
                    "--no-color-by-age", lines, commit, "--", path]
        var raw = Data()
        var cut = false
        if try await git.read(args, delimiter: UInt8(ascii: "\n"), { line in
            guard raw.count + line.utf8.count + 1 <= rawLimit else {
                cut = true
                return false
            }
            raw.append(contentsOf: Array(line.utf8) + [UInt8(ascii: "\n")])
            return true
        }) { cut = true }
        var out = ""
        var shown = 0
        groups: for group in BlameReader.parse(raw) {
            let date = group.authorDate.formatted(.iso8601.year().month().day())
            let header = "\(group.hash.prefix(12)) \(date) \(group.authorName): \(group.summary)\n"
            guard out.utf8.count + header.utf8.count <= room else {
                cut = true
                break
            }
            out += header
            for line in group.lines {
                let entry = "\(line.finalLine)\t\(shortened(line.text))\n"
                guard out.utf8.count + entry.utf8.count <= room else {
                    cut = true
                    break groups
                }
                out += entry
                shown += 1
            }
        }
        if out.isEmpty { return (cut ? cutNote : "No lines.", "0 lines") }
        return (cut ? out + cutNote + "\n" : out, counted(shown, "line"))
    }

    // MARK: - Helpers

    /// `path` as git printed it, unless `.aiignore` excludes it or it can't be read or shown for sure (empty, bytes
    /// that are not UTF-8, or a control character such as a newline that would forge output lines): fail closed.
    private static func visiblePath(_ path: String, ignore: AIIgnore?) -> String? {
        guard !path.isEmpty,
              !path.unicodeScalars.contains(where: { $0 == "\u{FFFD}" || $0.properties.generalCategory == .control }),
              ignore?.matches(path) != true
        else { return nil }
        return path
    }

    private static func shortened(_ line: String) -> String {
        line.count > maxLineCharacters ? String(line.prefix(maxLineCharacters)) + " [Histq: line cut]" : line
    }

    private static func counted(_ n: Int, _ noun: String, plural: String? = nil) -> String {
        "\(n) \(n == 1 ? noun : plural ?? noun + "s")"
    }

    /// Why a call was refused or failed: fixed app sentences, never the model's input or git's stderr.
    enum ToolError: Error, Equatable {
        case unknownTool, badArguments, unknownArgument, missingArgument, optionLike, tooLong, revisionColon
        case notACommit, invalidPath, ignoredPath, notAFile, outOfRange, lineRange, bothSearches, binary, timeout
        case gitFailed

        var message: String {
            switch self {
            case .unknownTool: AIToolLoop.unknownTool
            case .badArguments: "The arguments are not valid for this tool."
            case .unknownArgument: "The arguments include a name this tool does not take."
            case .missingArgument: "A required argument is missing."
            case .optionLike: "An argument starts with \"-\"; options can't be passed."
            case .tooLong: "An argument is too long."
            case .revisionColon: "A revision can't contain \":\"; pass a file in the path argument."
            case .notACommit: "The revision does not name a commit in this repository."
            case .invalidPath:
                "The path must be relative to the repository root, without empty, \".\" or \"..\" parts."
            case .ignoredPath: "That path is excluded by .aiignore; it can't be read."
            case .notAFile: "The path is not a file at that revision."
            case .outOfRange: "A number is outside its allowed range."
            case .lineRange: "The line range is not valid."
            case .bothSearches: "Pass either search or regex, not both."
            case .binary: "The file is binary; it was not read."
            case .timeout: "git took longer than 15 seconds and was stopped."
            case .gitFailed: "git could not run this command."
            }
        }
    }

    /// The call's arguments: a JSON object with only `allowed` keys (null counts as absent).
    struct Arguments {
        let values: [String: JSONValue]

        init(_ json: String, allowed: Set<String>) throws {
            guard case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) else {
                throw ToolError.badArguments
            }
            guard Set(object.keys).isSubset(of: allowed) else { throw ToolError.unknownArgument }
            values = object.filter { $0.value != .null }
        }

        func required<T>(_ value: T?) throws -> T {
            guard let value else { throw ToolError.missingArgument }
            return value
        }

        /// A non-empty string of at most `max` characters, with no control character (a NUL would cut it short
        /// on its way to git) and not starting with `-`.
        func string(_ key: String, max: Int) throws -> String? {
            guard let value = values[key] else { return nil }
            guard case .string(let text) = value, !text.isEmpty,
                  !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
            else { throw ToolError.badArguments }
            guard text.unicodeScalars.count <= max else { throw ToolError.tooLong }
            guard !text.hasPrefix("-") else { throw ToolError.optionLike }
            return text
        }

        /// A revision without `:` (no `HEAD:file`, `:file` or `:/message`).
        func revision(_ key: String) throws -> String? {
            guard let text = try string(key, max: AIGitTools.maxRevisionLength) else { return nil }
            guard !text.contains(":") else { throw ToolError.revisionColon }
            return text
        }

        /// A root-relative path: no leading `/`, no empty, `.` or `..` part; refused when `.aiignore` excludes it as a
        /// file or a folder.
        func path(_ key: String, ignore: AIIgnore?) throws -> String? {
            guard let text = try string(key, max: AIGitTools.maxPathLength) else { return nil }
            let parts = text.split(separator: "/", omittingEmptySubsequences: false)
            guard !text.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw ToolError.invalidPath
            }
            // As a file or a folder: a folder a folders-only rule excludes would otherwise pass.
            if ignore?.matches(text, orFolder: true) == true { throw ToolError.ignoredPath }
            return text
        }

        func int(_ key: String, in bounds: ClosedRange<Int>) throws -> Int? {
            guard let value = values[key] else { return nil }
            guard case .int(let number) = value else { throw ToolError.badArguments }
            guard bounds.contains(number) else { throw ToolError.outOfRange }
            return number
        }

        func bool(_ key: String) throws -> Bool? {
            guard let value = values[key] else { return nil }
            guard case .bool(let flag) = value else { throw ToolError.badArguments }
            return flag
        }

        /// `start_line`…`end_line`, each defaulting to the file's first or last line (`maxLineNumber`).
        func lineRange() throws -> ClosedRange<Int> {
            let start = try int("start_line", in: 1...AIGitTools.maxLineNumber) ?? 1
            let end = try int("end_line", in: 1...AIGitTools.maxLineNumber) ?? AIGitTools.maxLineNumber
            guard start <= end else { throw ToolError.lineRange }
            return start...end
        }
    }

    /// git in one repository with the call's deadline.
    struct Git {
        let runner: GitRunner
        let cwd: URL
        let env: [String: String]
        let deadline: ContinuousClock.Instant

        private func remaining() throws -> Duration {
            let left = deadline - .now
            guard left > .zero else { throw ToolError.timeout }
            return left
        }

        /// `revision` (HEAD when nil) as a commit id; anything else (a blob, a tree, a range, no object) is refused.
        func commit(_ revision: String?) async throws -> String {
            let result: GitResult
            do {
                result = try await runner.run(
                    ["rev-parse", "-q", "--verify", "--end-of-options", "\(revision ?? "HEAD")^{commit}"], cwd: cwd,
                    env: env, timeout: remaining(), allowedExitCodes: [0, 1])
            } catch {
                throw Self.mapped(error)
            }
            let id = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.exitCode == 0, GitOperations.isObjectID(id) else { throw ToolError.notACommit }
            return id
        }

        /// Refuses `path` unless it is a file (a blob) in `commit`: a tree would list the names inside it.
        func requireBlob(_ commit: String, _ path: String) async throws {
            let result: GitResult
            do {
                result = try await runner.run(
                    ["--literal-pathspecs", "cat-file", "-t", "\(commit):\(path)"], cwd: cwd, env: env,
                    timeout: remaining(), allowedExitCodes: [0, 1, 128])
            } catch {
                throw Self.mapped(error)
            }
            guard result.exitCode == 0, result.text.trimmingCharacters(in: .whitespacesAndNewlines) == "blob" else {
                throw ToolError.notAFile
            }
        }

        /// Streams git's stdout split on `delimiter` into `take` until it returns false (git is then stopped).
        /// A line longer than `rawLimit` reaches `take` as its start (its rest dropped). With `stopAtCutLine`, it
        /// then ends the read (git is stopped) and `read` returns true, so the caller adds its cut note; without,
        /// reading goes on with the next line. `noMatchIsEmpty`: exit 1 is a normal end (`git grep` found nothing).
        @discardableResult
        func read(
            _ args: [String], delimiter: UInt8, noMatchIsEmpty: Bool = false, stopAtCutLine: Bool = true,
            _ take: (String) throws -> Bool
        ) async throws -> Bool {
            var truncated = false
            do {
                let lines = try await runner.stream(
                    args, cwd: cwd, env: env, timeout: remaining(), delimiter: delimiter, maxLineBytes: rawLimit)
                for try await line in lines where line.source == .stdout {
                    if try !take(line.text) { break }
                    if line.truncated, stopAtCutLine {
                        truncated = true
                        break
                    }
                }
            } catch let error as GitError where noMatchIsEmpty && error.exitCode == 1 {
                // Nothing matched.
            } catch {
                throw Self.mapped(error)
            }
            try Task.checkCancellation()
            return truncated
        }

        private static func mapped(_ error: any Error) -> any Error {
            switch error {
            case let error as ToolError: error
            case is CancellationError: error
            case GitError.timeout: ToolError.timeout
            default: ToolError.gitFailed
            }
        }
    }
}
