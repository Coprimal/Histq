// Reads HEAD's reflog (`git log -g HEAD`): every move of HEAD, newest first, with the commit it moved to, so a commit
// that no branch holds any more (after a reset or an amend) can still be found.
import Foundation

/// One entry of HEAD's reflog. `action` and `message` come from the repo and are untrusted.
public struct ReflogEntry: Sendable, Hashable, Identifiable {
    /// The entry's position: `HEAD@{index}`. A commit can show in several entries, so this is the id.
    public let index: Int
    /// The commit HEAD moved to.
    public let hash: String
    /// What moved HEAD: `checkout`, `commit`, `commit (amend)`, `reset`, `rebase (finish)`…; empty when the entry
    /// has no `<action>: ` prefix.
    public let action: String
    /// The rest of the reflog subject: `moving from main to feature`, the commit's subject.
    public let message: String
    /// When HEAD moved.
    public let date: Date

    public var id: Int { index }

    public init(index: Int, hash: String, action: String, message: String, date: Date) {
        self.index = index
        self.hash = hash
        self.action = action
        self.message = message
        self.date = date
    }
}

public enum ReflogReader {
    /// One NUL-ended record per entry: the hash, the selector and the reflog subject, `\x1f`-separated. With
    /// `--date=unix` the selector holds the entry's time instead of its index (`HEAD@{1767301200}`).
    public static let arguments = [
        "log", "-g", "-z", "--no-show-signature", "--date=unix", "--format=%H%x1f%gd%x1f%gs",
        "--end-of-options", "HEAD", "--",
    ]

    /// HEAD's reflog, newest first. `env` must be the read environment built by `GitInvocation.readEnvironment` for
    /// this `cwd`. Throws `GitError`.
    public static func read(runner: GitRunner, cwd: URL, env: [String: String]) async throws -> [ReflogEntry] {
        parse(try await runner.run(arguments, cwd: cwd, env: env).stdout)
    }

    /// A record without a hash or a time is skipped; the subject is the last field, so a stray `\x1f` in it stays.
    static func parse(_ output: Data) -> [ReflogEntry] {
        var entries: [ReflogEntry] = []
        for (index, record) in output.split(separator: 0).enumerated() {
            let fields = String(decoding: record, as: UTF8.self)
                .split(separator: "\u{1F}", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, LogParser.isHash(fields[0]), fields[1].last == "}",
                  let open = fields[1].lastIndex(of: "{"),
                  let time = TimeInterval(fields[1][fields[1].index(after: open)...].dropLast())
            else { continue }
            let subject = fields[2]
            let colon = subject.range(of: ": ")
            entries.append(ReflogEntry(
                index: index, hash: String(fields[0]),
                action: colon.map { String(subject[..<$0.lowerBound]) } ?? "",
                message: colon.map { String(subject[$0.upperBound...]) } ?? String(subject),
                date: Date(timeIntervalSince1970: time)))
        }
        return entries
    }
}
