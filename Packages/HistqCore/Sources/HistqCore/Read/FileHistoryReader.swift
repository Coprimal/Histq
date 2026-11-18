// Reads the history of one file (`git log -- <path>`): the commits that changed it, newest first, each with
// the file's path at that commit. With `follow`, git follows the file across renames (`--follow`), so older
// commits carry the old path.
import Foundation

/// One commit of a file's history. Text fields come from the repo and are untrusted.
public struct FileHistoryEntry: Sendable, Hashable, Identifiable {
    public let commit: Commit
    /// The file's path at this commit (root-relative).
    public let path: String
    /// The path before this commit renamed or copied the file; nil otherwise.
    public let oldPath: String?
    /// git's status letter for the file in this commit (`A`, `M`, `D`, `R`, `C`, `T`); nil when git listed
    /// none (a merge).
    public let status: Character?

    public var id: String { commit.hash }

    public init(commit: Commit, path: String, oldPath: String?, status: Character?) {
        self.commit = commit
        self.path = path
        self.oldPath = oldPath
        self.status = status
    }
}

public enum FileHistoryReader {
    /// `-z` ends every commit's format with NUL and NUL-separates the name-status fields too, so a record is
    /// `\x1e<fields>\0` followed by `\n<status>\0<path>\0` (two paths for a rename or copy) per file. The
    /// fields are `LogReader`'s, parsed by `LogParser`. `--literal-pathspecs` keeps `*` in a path literal (and
    /// git's Bloom filters usable); `--follow` only when asked, since it turns them off.
    public static func arguments(path: String, revision: String?, follow: Bool) -> [String] {
        ["--literal-pathspecs", "log", "-z", "--no-ext-diff", "--no-textconv",
         "--format=%x1e%H%x1f%P%x1f%at%x1f%ct%x1f%an%x1f%ae%x1f%cn%x1f%ce%x1f%s%x1f%b", "--name-status"]
            + (follow ? ["--follow"] : []) + ["--end-of-options", revision ?? "HEAD", "--", path]
    }

    /// The commits of `revision` (HEAD when nil) that changed `path` (root-relative), newest first. `env`
    /// must be the read environment built by `GitInvocation.readEnvironment` for this `cwd`. Throws `GitError`.
    public static func read(
        _ path: String, revision: String? = nil, follow: Bool = false, runner: GitRunner, cwd: URL,
        env: [String: String]
    ) async throws -> [FileHistoryEntry] {
        parse(try await runner.run(arguments(path: path, revision: revision, follow: follow), cwd: cwd, env: env)
            .stdout, path: path)
    }

    /// Walks the NUL-separated tokens: a token starting with `\x1e` opens a commit, any other token is a
    /// status followed by one path (two for `R`/`C`). A commit body may hold `\x1e` but never NUL, so records
    /// are never split on it. A commit without a status (a merge) keeps the path tracked so far: `path`,
    /// then the old path once a newer commit renamed the file.
    static func parse(_ output: Data, path: String) -> [FileHistoryEntry] {
        let tokens = output.split(separator: 0, omittingEmptySubsequences: false)
        var entries: [FileHistoryEntry] = []
        var tracked = path
        var names: [Substring: String] = [:]
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            guard token.first == 0x1E,
                  let commit = LogParser.parse(
                      Substring(String(decoding: token.dropFirst(), as: UTF8.self)), names: &names)
            else { continue }
            var status: Character?
            var current = tracked
            var oldPath: String?
            // Every file of the record (one for a file path; a directory path lists several).
            while index < tokens.count, let letter = tokens[index].first(where: { $0 != 0x0A }),
                  tokens[index].first != 0x1E
            {
                let isPair = letter == UInt8(ascii: "R") || letter == UInt8(ascii: "C")
                let paths = tokens[(index + 1)..<min(tokens.count, index + (isPair ? 3 : 2))]
                    .map { String(decoding: $0, as: UTF8.self) }
                index += 1 + paths.count
                if status == nil, let last = paths.last {
                    status = Character(UnicodeScalar(letter))
                    current = last
                    oldPath = isPair && paths.count == 2 ? paths[0] : nil
                }
            }
            entries.append(FileHistoryEntry(commit: commit, path: current, oldPath: oldPath, status: status))
            tracked = oldPath ?? current
        }
        return entries
    }
}
