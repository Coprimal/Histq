// Streams the commit history for the graph: every ref but the stash and notes, in topological order, parsed
// as git writes it and published in pages so the first rows can show before git has finished.
import Foundation

/// One commit of the history. Text fields come from the repo and are untrusted.
public struct Commit: Sendable, Hashable, Identifiable {
    public let hash: String
    /// First parent first; empty for a root commit, two or more for a merge.
    public let parents: [String]
    public let authorName: String
    public let authorEmail: String
    public let authorDate: Date
    public let committerName: String
    public let committerEmail: String
    public let committerDate: Date
    public let subject: String
    public let body: String

    public var id: String { hash }
    public var isMerge: Bool { parents.count > 1 }

    public init(
        hash: String, parents: [String], authorName: String, authorEmail: String, authorDate: Date,
        committerDate: Date, subject: String, body: String, committerName: String = "", committerEmail: String = ""
    ) {
        self.hash = hash
        self.parents = parents
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authorDate = authorDate
        self.committerName = committerName
        self.committerEmail = committerEmail
        self.committerDate = committerDate
        self.subject = subject
        self.body = body
    }
}

public enum LogReader {
    public static let defaultPageSize = 500

    /// `--exclude` must come before `--all` (git applies it to the next `--all`/`--branches`/...), so stash
    /// internals (`stash@{n}` and its index and untracked commits) and notes never become rows. `-z` ends
    /// every record with NUL, which git cannot emit inside a name or message (its formatter stops at a NUL,
    /// and the read environment pins UTF-8 output), so no commit text can start a record of its own. Fields
    /// are separated by `\x1f`, which git does not escape: the fixed-format fields come first and the body
    /// last, so a stray `\x1f` in a name or message cannot shift the hash, parents or dates (see `LogParser`).
    public static let arguments = [
        "log", "-z", "--exclude=refs/stash", "--exclude=refs/notes/*", "--all", "--topo-order",
        "--format=%H%x1f%P%x1f%at%x1f%ct%x1f%an%x1f%ae%x1f%cn%x1f%ce%x1f%s%x1f%b",
    ]

    /// `arguments` with branches hidden or soloed, and with the `alsoFrom` hashes (see `pages`); with no
    /// hidden or soloed ref it is `arguments` followed by those hashes, as before. Hide puts an `--exclude`
    /// per ref before `--all`. Solo drops `--all` and ends the command with `--end-of-options <refs> HEAD
    /// <hashes> --`: HEAD keeps the WIP row's base, and the trailing `--` keeps a worktree file named `HEAD`
    /// (or a hash) from being read as a path. A ref both hidden and soloed is shown: its `--exclude` is still
    /// passed, but git applies it only to a following `--all`, which solo mode has not. Only full ref names
    /// under `refs/heads/` or `refs/remotes/` that git would accept are passed, the rest are dropped; if no
    /// soloed ref is left, every ref is read.
    public static func arguments(hidden: [String], solo: [String], alsoFrom hashes: [String] = []) -> [String] {
        let revisions = hashes.filter { !$0.isEmpty && $0.allSatisfy(\.isHexDigit) }
        let excludes = hidden.filter(isBranchRef).map { "--exclude=\($0)" }
        let solo = solo.filter(isBranchRef)
        var command = arguments
        let all = command.firstIndex(of: "--all")!
        if solo.isEmpty {
            command.insert(contentsOf: excludes, at: all)
            return command + revisions
        }
        command.replaceSubrange(all...all, with: excludes)
        return command + ["--end-of-options"] + solo + ["HEAD"] + revisions + ["--"]
    }

    /// A full branch or remote-tracking ref name git accepts (`git check-ref-format`), checked on its UTF-8
    /// bytes so a combining character cannot hide a forbidden one. The name after the prefix cannot start
    /// with `-`.
    static func isBranchRef(_ name: String) -> Bool {
        let prefix = ["refs/heads/", "refs/remotes/"].first { name.hasPrefix($0) }
        guard let prefix else { return false }
        let rest = Array(name.utf8.dropFirst(prefix.utf8.count))
        let forbidden = Set(" ~^:?*[\\".utf8)
        guard rest.first != UInt8(ascii: "-"), rest.last != UInt8(ascii: "."),
              rest.allSatisfy({ $0 >= 0x20 && $0 != 0x7F && !forbidden.contains($0) }),
              !["..", "@{"].contains(where: { rest.contains(Array($0.utf8)) }),
              prefix == "refs/heads/" || rest.contains(UInt8(ascii: "/"))
        else { return false }
        let parts = rest.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
        return parts.allSatisfy {
            !$0.isEmpty && $0.first != UInt8(ascii: ".") && !$0.suffix(5).elementsEqual(".lock".utf8)
        }
    }

    /// Streams the history of the repository at `cwd` in pages of up to `pageSize` commits (the last page
    /// may be shorter; an empty repository yields no page). `env` must be the read environment built by
    /// `GitInvocation.readEnvironment` for this `cwd`. The stream throws `GitError` when git fails. Ending
    /// the iteration early stops git; a cancelled consumer's loop ends without an error.
    ///
    /// `alsoFrom`: commit hashes whose history is read too, e.g. the stashes' bases, so a stash made on a
    /// commit no branch holds any more still has its base in the log, as GitKraken shows it. Anything but a
    /// hex hash is left out, so it can never be read as an option. `hidden` and `solo`: full ref names, see
    /// `arguments(hidden:solo:alsoFrom:)`.
    public static func pages(
        runner: GitRunner, cwd: URL, env: [String: String], pageSize: Int = defaultPageSize,
        alsoFrom hashes: [String] = [], hidden: [String] = [], solo: [String] = []
    ) -> AsyncThrowingStream<[Commit], Error> {
        let command = arguments(hidden: hidden, solo: solo, alsoFrom: hashes)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [Commit].self)
        let task = Task {
            do {
                var page: [Commit] = []
                page.reserveCapacity(pageSize)
                let lines = await runner.stream(command, cwd: cwd, env: env, delimiter: 0)
                for try await line in lines where line.source == .stdout {
                    guard let commit = LogParser.parse(Substring(line.text)) else { continue }
                    page.append(commit)
                    if page.count >= pageSize {
                        continuation.yield(page)
                        page.removeAll(keepingCapacity: true)
                    }
                }
                try Task.checkCancellation()
                if !page.isEmpty { continuation.yield(page) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

/// Turns NUL-terminated records into commits, one record each.
enum LogParser {
    /// A record needs a hash, parents and both dates, or it is no commit. The body takes everything after
    /// the ninth `\x1f`, so a stray `\x1f` in a name, email or subject only misplaces text.
    static func parse(_ record: Substring) -> Commit? {
        let fields = record.split(separator: "\u{1F}", maxSplits: 9, omittingEmptySubsequences: false)
        guard fields.count >= 4, isHash(fields[0]),
              let authorTime = TimeInterval(fields[2]), let commitTime = TimeInterval(fields[3])
        else { return nil }
        let parents = fields[1].split(separator: " ")
        guard parents.allSatisfy(isHash) else { return nil }
        let text = { (index: Int) in index < fields.count ? fields[index] : "" }
        var body = text(9)
        while body.last == "\n" { body.removeLast() }
        return Commit(
            hash: String(fields[0]), parents: parents.map(String.init), authorName: String(text(4)),
            authorEmail: String(text(5)), authorDate: Date(timeIntervalSince1970: authorTime),
            committerDate: Date(timeIntervalSince1970: commitTime), subject: String(text(8)), body: String(body),
            committerName: String(text(6)), committerEmail: String(text(7)))
    }

    /// A full SHA-1 (40) or SHA-256 (64) object name in lowercase hex.
    static func isHash(_ text: Substring) -> Bool {
        (text.utf8.count == 40 || text.utf8.count == 64)
            && text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}
