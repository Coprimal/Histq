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
    /// internals (`stash@{n}` and its index and untracked commits), notes and `git maintenance`'s prefetch refs
    /// (hidden copies of the remotes, as scalar's `log.excludeDecoration` hides them) never become rows. `-z` ends
    /// every record with NUL, which git cannot emit inside a name or message (its formatter stops at a NUL,
    /// and the read environment pins UTF-8 output), so no commit text can start a record of its own. Fields
    /// are separated by `\x1f`, which git does not escape: the fixed-format fields come first and the body
    /// last, so a stray `\x1f` in a name or message cannot shift the hash, parents or dates (see `LogParser`).
    public static let arguments = [
        "log", "-z", "--exclude=refs/stash", "--exclude=refs/notes/*", "--exclude=refs/prefetch/*", "--all",
        "--topo-order",
        "--format=%H%x1f%P%x1f%at%x1f%ct%x1f%an%x1f%ae%x1f%cn%x1f%ce%x1f%s%x1f%b",
    ]

    /// Streams the history of the repository at `cwd` in pages of up to `pageSize` commits (the last page
    /// may be shorter; an empty repository yields no page). `env` must be the read environment built by
    /// `GitInvocation.readEnvironment` for this `cwd`. The stream throws `GitError` when git fails. Ending
    /// the iteration early stops git; a cancelled consumer's loop ends without an error.
    ///
    /// `alsoFrom`: commit hashes whose history is read too, e.g. the stashes' bases, so a stash made on a
    /// commit no branch holds any more still has its base in the log, as GitKraken shows it. Anything but a
    /// hex hash is left out, so it can never be read as an option.
    public static func pages(
        runner: GitRunner, cwd: URL, env: [String: String], pageSize: Int = defaultPageSize,
        alsoFrom hashes: [String] = []
    ) -> AsyncThrowingStream<[Commit], Error> {
        let command = arguments + hashes.filter { !$0.isEmpty && $0.allSatisfy(\.isHexDigit) }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [Commit].self)
        let task = Task {
            do {
                var page: [Commit] = []
                page.reserveCapacity(pageSize)
                var names: [Substring: String] = [:]
                let lines = await runner.stream(command, cwd: cwd, env: env, delimiter: 0)
                for try await line in lines where line.source == .stdout {
                    guard let commit = LogParser.parse(Substring(line.text), names: &names) else { continue }
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

    /// The hashes of the commits of `commits` that no other commit of it lists as a parent, in `commits`' order: the
    /// tips a history read from them reaches every commit of `commits` from. `index` is `commits`' index of each hash.
    public static func tips(of commits: [Commit], index: [String: Int]) -> [String] {
        var isParent = [Bool](repeating: false, count: commits.count)
        for commit in commits {
            for parent in commit.parents {
                if let position = index[parent] { isParent[position] = true }
            }
        }
        return commits.indices.filter { !isParent[$0] }.map { commits[$0].hash }
    }

    /// The tips of a history after `delta` (the commits new since a read whose tips were `previous`, `newCommits`) comes
    /// on top of it, as `tips(of:index:)` would give for the whole history: the delta commits no other delta commit
    /// lists as a parent, then the previous tips no delta commit lists as a parent.
    public static func tips(adding delta: [Commit], to previous: [String]) -> [String] {
        var parents = Set<String>()
        for commit in delta { parents.formUnion(commit.parents) }
        return delta.map(\.hash).filter { !parents.contains($0) } + previous.filter { !parents.contains($0) }
    }

    /// The commits a history read (`pages`) would list now that are not in a previous read whose tips were
    /// `previousTips` (`tips(of:index:)`), in git's order (children before parents); `[]` when none. Nil when this
    /// cannot be proven to be the whole difference, so the caller reads the whole history again: no previous tip,
    /// a previous tip that is not a hex hash, a replace ref (`git replace` can give an old commit other parents), or a
    /// commit of the previous read that the refs and `alsoFrom` no longer reach (a branch deleted, a reset, a
    /// force-push, a stash dropped). `env` and `alsoFrom` are as in
    /// `pages`; anything in `alsoFrom` but a hex hash is left out.
    ///
    /// The new commits followed by the previous ones are exactly the commits a fresh read lists, in a valid
    /// topological order (a new commit is never an ancestor of an old one), but not always in the order git's
    /// `--topo-order` gives a fresh read: after a commit on a branch other than the newest one, a fresh read lists
    /// that branch's whole line first, while here the old commits keep their order and the new ones come on top.
    /// Not valid across a change of the shallow boundary (a deepened clone gives old commits new parents): the caller
    /// reads the whole history of a shallow repo.
    public static func newCommits(
        runner: GitRunner, cwd: URL, env: [String: String], previousTips: [String], alsoFrom hashes: [String] = []
    ) async throws -> [Commit]? {
        let isHex = { (text: String) in !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isHexDigit } }
        guard !previousTips.isEmpty, previousTips.allSatisfy(isHex) else { return nil }
        let extra = hashes.filter(isHex)
        let replaced = try await runner.run(
            ["for-each-ref", "--count=1", "--format=%(refname)", "refs/replace/"], cwd: cwd, env: env)
        guard replaced.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Every previous commit must still be reachable. `--stdin` comes before `--not`, and git reads the
        // revisions on stdin as given whatever `--not` says on the command line, so the previous tips count as
        // positive and the refs (with the same exclusions as the log) and `extra` as negative.
        let check = try await runner.run(
            ["rev-list", "--count", "--stdin", "--not", "--exclude=refs/stash", "--exclude=refs/notes/*",
             "--exclude=refs/prefetch/*", "--all"]
                + extra,
            cwd: cwd, env: env, stdin: Data(previousTips.map { $0 + "\n" }.joined().utf8))
        let count = check.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard count == "0" else { return nil }
        var commits: [Commit] = []
        var names: [Substring: String] = [:]
        let lines = await runner.stream(
            arguments + extra + ["--stdin"], cwd: cwd, env: env,
            stdin: Data(previousTips.map { "^" + $0 + "\n" }.joined().utf8), delimiter: 0)
        for try await line in lines where line.source == .stdout {
            guard let commit = LogParser.parse(Substring(line.text), names: &names) else { continue }
            commits.append(commit)
        }
        try Task.checkCancellation()
        return commits
    }
}

/// Turns NUL-terminated records into commits, one record each.
enum LogParser {
    /// A record needs a hash, parents and both dates, or it is no commit. The body takes everything after
    /// the ninth `\x1f`, so a stray `\x1f` in a name, email or subject only misplaces text. `names` is the
    /// stream's cache of names and emails (`intern`), so the commits of one author share one String.
    static func parse(_ record: Substring, names: inout [Substring: String]) -> Commit? {
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
            hash: String(fields[0]), parents: parents.map(String.init), authorName: intern(text(4), &names),
            authorEmail: intern(text(5), &names), authorDate: Date(timeIntervalSince1970: authorTime),
            committerDate: Date(timeIntervalSince1970: commitTime), subject: String(text(8)), body: String(body),
            committerName: intern(text(6), &names), committerEmail: intern(text(7), &names))
    }

    /// `field` as the String `names` already holds for it, so equal names and emails share one storage. Up to
    /// 15 UTF-8 bytes a String is stored inline and is not cached; `names` stops growing at 10,000 entries. Each
    /// key is a slice of its own value, never of the record, so the cache keeps no record alive. Strings compare
    /// by canonical equivalence, so an NFD spelling seen after an equal NFC one gets the NFC bytes (same `==`).
    static func intern(_ field: Substring, _ names: inout [Substring: String]) -> String {
        guard field.utf8.count > 15 else { return String(field) }
        if let known = names[field] { return known }
        let value = String(field)
        if names.count < 10_000 { names[value[...]] = value }
        return value
    }

    /// A full SHA-1 (40) or SHA-256 (64) object name in lowercase hex.
    static func isHash(_ text: Substring) -> Bool {
        (text.utf8.count == 40 || text.utf8.count == 64)
            && text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}
