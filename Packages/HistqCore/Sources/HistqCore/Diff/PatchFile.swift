// Patch files: exports (one or several commits as a mail series, the working tree's changes, one file) and the
// read side of applying one (input validation and a preview of what it touches and whether it applies).
//
// Every command is a read: `env` is the read environment of `cwd`, and `cwd` must be the worktree's top level
// (`git apply` run from a subfolder silently skips the paths outside it). Exports pin the output format with
// `DiffReader.formatOptions` (no external diff, no textconv, no color, `a/`/`b/` prefixes, no relative paths) and
// pass `--binary`, so binary changes apply too; mail exports also override the user's `format.*` config (no cover
// letter, base, sign-off, threading, attachment or signature). Revisions go after `--end-of-options`, paths after `--` with
// `--literal-pathspecs`. A patch to preview is untrusted input: `validate` first, then it only ever goes to git on
// stdin, never with `--unsafe-paths`, `--directory` or `--reject`.
import Foundation

public enum PatchFile {
    /// The largest patch accepted (20 MB). The app checks a file's size against it before reading it.
    public static let maxBytes = 20 * 1024 * 1024

    public enum InputError: Error, Equatable, Sendable {
        /// Larger than `maxBytes`.
        case tooLarge
        /// Holds NUL bytes, so it is not a text patch.
        case notText
        /// Has no `diff --git` line and no `---`/`+++` pair.
        case noDiff
        /// The export came out empty (no changes, or a merge commit, which `format-patch` skips).
        case nothingToExport

        /// A sentence for the UI.
        public var message: String {
            switch self {
            case .tooLarge: "The patch is larger than \(PatchFile.maxBytes / 1024 / 1024) MB."
            case .notText: "This is not a text patch."
            case .noDiff: "This text has no diff in it."
            case .nothingToExport: "There are no changes to put in a patch."
            }
        }
    }

    // MARK: Input

    /// `data` checked as a patch to apply: at most `maxBytes`, no NUL byte, a `diff --git` line or a `---` line
    /// followed by a `+++` line. Returned with a final newline added when it lacks one (git reads a patch without
    /// it as corrupt).
    public static func validate(_ data: Data) throws -> Data {
        guard data.count <= maxBytes else { throw InputError.tooLarge }
        guard !data.contains(0) else { throw InputError.notText }
        guard hasDiffHeader(data) else { throw InputError.noDiff }
        return data.last == newline ? data : data + [newline]
    }

    /// The patch is a mail series (`format-patch` output): its first line is `From <object id> `.
    public static func isMailbox(_ data: Data) -> Bool {
        isMailStart(lines(data).first ?? Data())
    }

    /// The number of mails in a series (lines `From <object id> `).
    public static func mailCount(_ data: Data) -> Int {
        lines(data).count(where: isMailStart)
    }

    // MARK: Exports

    /// `hashes` as a mail series. One commit is `format-patch -1`; several go in the order given (graph order,
    /// newest first) with `--no-walk=unsorted`, which outputs them oldest first as `[PATCH i/N]`, whether or not
    /// they follow each other. Merge commits are left out by git (the caller refuses them).
    public static func commits(
        _ hashes: [String], runner: GitRunner, cwd: URL, env: [String: String]
    ) async throws -> Data {
        guard !hashes.isEmpty else { throw InputError.nothingToExport }
        for hash in hashes where !GitOperations.isObjectID(hash) { throw GitOperationError.invalidObjectID(hash) }
        // A single revision without `-1` would read as `<rev>..HEAD`.
        let range = hashes.count == 1 ? ["-1"] : ["--no-walk=unsorted"]
        let args = ["format-patch", "--stdout", "--binary"] + mailOptions + DiffReader.formatOptions + range
            + ["--end-of-options"] + hashes
        return try nonEmpty(try await runner.run(args, cwd: cwd, env: env).stdout)
    }

    /// Which working tree changes `workingTree` exports.
    public enum WorkingTreePart: Sendable, Hashable {
        /// The working tree against the index, plus the untracked files.
        case unstaged
        /// The index against HEAD.
        case staged
        /// The working tree against HEAD (against the empty tree on an unborn branch), plus the untracked files.
        case all
    }

    /// The working tree's `part` as a patch. `untracked` (root-relative paths) are added as new files for
    /// `.unstaged` and `.all`.
    public static func workingTree(
        _ part: WorkingTreePart, untracked: [String], runner: GitRunner, cwd: URL, env: [String: String]
    ) async throws -> Data {
        let side: [String] = switch part {
        case .unstaged: []
        case .staged: ["--cached"]
        case .all: ["--end-of-options", try await headOrEmptyTree(runner: runner, cwd: cwd, env: env)]
        }
        var patch = try await runner.run(diffArguments + side + ["--"], cwd: cwd, env: env).stdout
        if part != .staged {
            for path in untracked { patch += try await untrackedDiff(path, runner: runner, cwd: cwd, env: env) }
        }
        return try nonEmpty(patch)
    }

    /// Where `file` takes a file's change from.
    public enum FileSource: Sendable, Hashable {
        case unstaged, staged, untracked
        /// The change the commit made, as a mail with its message.
        case commit(String)
    }

    /// One file's change as a patch; `originalPath` is a rename's old path (both are root-relative).
    public static func file(
        path: String, originalPath: String?, source: FileSource, runner: GitRunner, cwd: URL, env: [String: String]
    ) async throws -> Data {
        let paths = (originalPath.map { [$0] } ?? []) + [path]
        let args: [String]
        switch source {
        case .unstaged: args = diffArguments + ["--"] + paths
        case .staged: args = diffArguments + ["--cached", "--"] + paths
        case .untracked: return try await untrackedDiff(path, runner: runner, cwd: cwd, env: env)
        case .commit(let hash):
            guard GitOperations.isObjectID(hash) else { throw GitOperationError.invalidObjectID(hash) }
            // `--no-walk`: with a path, `-1` alone walks back to the last commit that touched it.
            args = ["--literal-pathspecs", "format-patch", "-1", "--no-walk", "--stdout", "--binary"] + mailOptions
                + DiffReader.formatOptions + ["--end-of-options", hash, "--"] + paths
        }
        return try nonEmpty(try await runner.run(args, cwd: cwd, env: env).stdout)
    }

    // MARK: Preview

    /// What `data` (a validated patch) touches and whether it applies to the working tree.
    public static func preview(
        _ data: Data, runner: GitRunner, cwd: URL, env: [String: String]
    ) async throws -> PatchPreview {
        let numstat = try await runner.run(["apply", "--numstat", "-z"], cwd: cwd, env: env, stdin: data)
        // `--whitespace=nowarn` as `GitOperations.applyPatchToWorkingTree`, so a repo's `apply.whitespace` gives
        // the same verdict as the real apply. A plain check alone decides "clean": `--3way --check` passes even
        // when the real apply conflicts.
        let check = ["apply", "--check", "--whitespace=nowarn"]
        let plain = try await runner.run(check, cwd: cwd, env: env, stdin: data, allowedExitCodes: [0, 1])
        let verdict: PatchPreview.Verdict
        if plain.exitCode == 0 {
            verdict = .clean
        } else {
            let threeWay = try await runner.run(
                check + ["--3way"], cwd: cwd, env: env, stdin: data, allowedExitCodes: [0, 1])
            // The plain check's reason first: the 3-way one often starts with "lacks the necessary blob" and
            // "Falling back to direct application" before the real error.
            let tail = plain.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            verdict = threeWay.exitCode == 0
                ? .threeWay
                : .fails(tail.isEmpty ? threeWay.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines) : tail)
        }
        return PatchPreview(
            files: files(numstat: numstat.stdout), verdict: verdict, isMailbox: isMailbox(data),
            mailCount: mailCount(data))
    }

    // MARK: Helpers

    private static let newline = UInt8(ascii: "\n")

    /// Overrides `format.coverLetter`, `format.useAutoBase`, `format.signOff`, `format.thread`, `format.attach` and
    /// `format.signature`: a cover letter would count as a mail and stop `am`, an auto base fails with no upstream.
    private static let mailOptions =
        ["--no-cover-letter", "--no-base", "--no-signoff", "--no-thread", "--no-attach", "--no-signature"]

    private static let diffArguments =
        ["--literal-pathspecs", "diff"] + DiffReader.formatOptions + ["--binary", "--ignore-submodules=dirty"]

    private static func lines(_ data: Data) -> [Data] {
        data.split(separator: newline, omittingEmptySubsequences: false)
    }

    private static func hasDiffHeader(_ data: Data) -> Bool {
        var previous = Data()
        for line in lines(data) {
            if line.starts(with: Array("diff --git ".utf8)) { return true }
            if line.starts(with: Array("+++ ".utf8)), previous.starts(with: Array("--- ".utf8)) { return true }
            previous = line
        }
        return false
    }

    /// `From ` then 40 to 64 lowercase hex digits (an object id) then a space.
    private static func isMailStart(_ line: Data) -> Bool {
        guard line.starts(with: Array("From ".utf8)) else { return false }
        let rest = line.dropFirst(5)
        let hex = rest.prefix { (48...57).contains($0) || (97...102).contains($0) }
        return (40...64).contains(hex.count) && rest.dropFirst(hex.count).first == UInt8(ascii: " ")
    }

    private static func nonEmpty(_ patch: Data) throws -> Data {
        guard !patch.isEmpty else { throw InputError.nothingToExport }
        return patch
    }

    /// HEAD's commit, or the empty tree on an unborn branch (hashed by git, so it fits a SHA-256 repo).
    private static func headOrEmptyTree(runner: GitRunner, cwd: URL, env: [String: String]) async throws -> String {
        let head = try await runner.run(
            ["rev-parse", "-q", "--verify", "HEAD^{commit}"], cwd: cwd, env: env, allowedExitCodes: [0, 1])
        let id = head.exitCode == 0 ? head.text : try await runner.run(
            ["hash-object", "-t", "tree", "--stdin"], cwd: cwd, env: env).text
        return id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An untracked file as a new-file patch (`diff --no-index` against `/dev/null`; run from the top level, its
    /// headers carry the root-relative path). Exit 1 means "differs", and also "cannot read the path" with no
    /// output, which throws.
    private static func untrackedDiff(
        _ path: String, runner: GitRunner, cwd: URL, env: [String: String]
    ) async throws -> Data {
        let result = try await runner.run(
            ["diff", "--no-index"] + DiffReader.formatOptions + ["--binary", "--", "/dev/null", path], cwd: cwd,
            env: env, allowedExitCodes: [0, 1])
        guard !result.stdout.isEmpty else {
            throw GitError.other(exit: result.exitCode, stderrTail: result.stderrTail)
        }
        return result.stdout
    }

    /// `apply --numstat -z` records (`added\tdeleted\tpath\0`, `-\t-\t` for a binary file; a rename's empty path
    /// field is followed by `old\0new\0`), one per file and patch, summed by path in first-seen order.
    static func files(numstat: Data) -> [PatchPreview.File] {
        var fields = numstat.split(separator: 0, omittingEmptySubsequences: false)[...]
        var files: [PatchPreview.File] = []
        var index: [String: Int] = [:]
        while let record = fields.popFirst() {
            let parts = record.split(separator: UInt8(ascii: "\t"), maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            var name = parts[2]
            if name.isEmpty {
                _ = fields.popFirst()
                name = fields.popFirst() ?? Data()
            }
            let path = String(decoding: name, as: UTF8.self)
            let added = Int(String(decoding: parts[0], as: UTF8.self))
            let deleted = Int(String(decoding: parts[1], as: UTF8.self))
            let file = PatchPreview.File(
                path: path, additions: added ?? 0, deletions: deleted ?? 0, isBinary: added == nil || deleted == nil)
            if let at = index[path] {
                files[at].additions += file.additions
                files[at].deletions += file.deletions
                files[at].isBinary = files[at].isBinary || file.isBinary
            } else {
                index[path] = files.count
                files.append(file)
            }
        }
        return files
    }
}

/// What a patch would do: the files it touches and whether it applies to the working tree.
public struct PatchPreview: Sendable, Equatable {
    public struct File: Sendable, Hashable {
        /// Root-relative; a rename's new path.
        public var path: String
        public var additions: Int
        public var deletions: Int
        public var isBinary: Bool

        public init(path: String, additions: Int, deletions: Int, isBinary: Bool) {
            self.path = path
            self.additions = additions
            self.deletions = deletions
            self.isBinary = isBinary
        }
    }

    public enum Verdict: Sendable, Equatable {
        /// `git apply` applies it as it is.
        case clean
        /// Only a 3-way merge applies it (the result may still conflict).
        case threeWay
        /// It does not apply; git's message.
        case fails(String)
    }

    /// In patch order, each file once (summed over a series).
    public let files: [File]
    public let verdict: Verdict
    /// A mail series (`format-patch` output), which can also be applied as commits.
    public let isMailbox: Bool
    /// The number of mails (0 for a plain diff).
    public let mailCount: Int
}
