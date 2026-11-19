// Reads a repository's submodules: their `.gitmodules` entries, the commit the index records for each
// (its gitlink) and the state of each checkout, read in the submodule's own folder with its own read
// environment; and the commits between two pointers of one submodule. Names and paths come from
// `.gitmodules`, which the repo controls: they only ever reach git after `--`, as literal pathspecs.
import Foundation

public struct Submodule: Sendable, Hashable, Identifiable {
    public enum State: Sendable, Hashable {
        /// No `submodule.<name>.url` in the parent's config (`git submodule init` was not run).
        case notInitialized
        /// Initialized, but its folder holds no checkout.
        case notCheckedOut
        /// `head` is the checked-out commit; `branch` the short branch name, nil when detached.
        case checkedOut(head: String, branch: String?)
    }

    public let name: String
    /// From the repository root; a nested submodule's path starts with its parents' paths.
    public let path: String
    public let url: String?
    /// The branch `.gitmodules` configures (`submodule.<name>.branch`).
    public let branch: String?
    /// The commit the parent's index records (the gitlink).
    public let recordedCommit: String
    public let state: State
    /// The submodule's status entries, untracked files included; 0 unless checked out.
    public let changeCount: Int

    public var id: String { path }
    public init(
        name: String, path: String, url: String?, branch: String?, recordedCommit: String, state: State,
        changeCount: Int
    ) {
        self.name = name
        self.path = path
        self.url = url
        self.branch = branch
        self.recordedCommit = recordedCommit
        self.state = state
        self.changeCount = changeCount
    }

    /// The checkout is on another commit than the recorded one.
    public var isMoved: Bool {
        if case .checkedOut(let head, _) = state { head != recordedCommit } else { false }
    }
}

/// The commits between two pointers of one submodule.
public struct SubmoduleChange: Sendable, Hashable {
    public struct Commit: Sendable, Hashable, Identifiable {
        public let sha: String
        public let subject: String
        public let author: String
        public let date: Date
        /// The refs pointing at it, as git decorates them (`HEAD -> main`, `tag: v1`, `origin/main`).
        public let refs: [String]
        /// In `to` but not in `from`; false for a commit the pointer moved back past.
        public let isNew: Bool

        public var id: String { sha }

        public init(sha: String, subject: String, author: String, date: Date, refs: [String], isNew: Bool) {
            self.sha = sha
            self.subject = subject
            self.author = author
            self.date = date
            self.refs = refs
            self.isNew = isNew
        }
    }

    /// nil for a newly added submodule.
    public let from: String?
    public let to: String
    /// false when `from` or `to` is not in the submodule's checkout (not fetched, or no checkout); nothing
    /// else is read then.
    public let available: Bool
    /// Commits in `to` but not in `from` (every commit of `to` for a new submodule).
    public let ahead: Int
    /// Commits in `from` but not in `to`.
    public let behind: Int
    /// Up to `commitLimit` of the commits on either side, newest first.
    public let commits: [Commit]

    public init(from: String?, to: String, available: Bool, ahead: Int, behind: Int, commits: [Commit]) {
        self.from = from
        self.to = to
        self.available = available
        self.ahead = ahead
        self.behind = behind
        self.commits = commits
    }
}

public enum SubmoduleReader {
    public static let commitLimit = 50

    /// The submodules of the worktree at `cwd`, nested ones included, in index order (each before its own
    /// nested ones). Only `.gitmodules` entries with a gitlink in the index are listed. Without a
    /// `.gitmodules` file it returns `[]` and runs no git. A checked-out submodule is read in its folder with
    /// the read environment built there, so its own filters stay off; a submodule git cannot read (a broken
    /// `.git` file) is listed as not checked out (a timeout still throws), and one with its own `.git` as
    /// checked out even when not initialized. Throws `GitError`.
    public static func list(runner: GitRunner, cwd: URL, base: [String: String]) async throws -> [Submodule] {
        guard hasGitmodules(cwd) else { return [] }
        let env = parentEnvironment(base)
        let entries = try await gitmodules(runner: runner, cwd: cwd, env: env)
        guard !entries.isEmpty else { return [] }
        let gitlinks = try await gitlinks(
            ["ls-files", "-s", "-z"], paths: entries.map(\.path), runner: runner, cwd: cwd, env: env)
        let initialized = try await initializedNames(runner: runner, cwd: cwd, env: env)
        // One submodule at a time, so a repo with many submodules does not start dozens of git processes.
        var submodules: [Submodule] = []
        for link in gitlinks {
            guard let entry = entries.first(where: { $0.path == link.path }) else { continue }
            submodules += try await read(
                entry, recorded: link.sha, initialized: initialized.contains(entry.name), runner: runner, cwd: cwd,
                base: base)
        }
        return submodules
    }

    /// The commit each submodule of `.gitmodules` (as the worktree has it) points to in `revision`, by path;
    /// a path with no gitlink there is left out. Without a `.gitmodules` file it returns `[:]` and runs no
    /// git. Throws `GitError`.
    public static func recorded(
        runner: GitRunner, cwd: URL, base: [String: String], revision: String
    ) async throws -> [String: String] {
        guard hasGitmodules(cwd) else { return [:] }
        let env = parentEnvironment(base)
        let entries = try await gitmodules(runner: runner, cwd: cwd, env: env)
        guard !entries.isEmpty else { return [:] }
        let links = try await gitlinks(
            ["ls-tree", "-z", "--end-of-options", revision], paths: entries.map(\.path), runner: runner, cwd: cwd,
            env: env)
        return Dictionary(links.map { ($0.path, $0.sha) }, uniquingKeysWith: { first, _ in first })
    }

    /// The commits between `from` and `to` in the submodule checked out at `folder`, read with the read
    /// environment built there. `from` nil: a newly added submodule, every commit of `to` is new. Throws
    /// `GitError`.
    public static func change(
        runner: GitRunner, in folder: URL, base: [String: String], from: String?, to: String
    ) async throws -> SubmoduleChange {
        let unavailable = SubmoduleChange(from: from, to: to, available: false, ahead: 0, behind: 0, commits: [])
        let revisions = [from, to].compactMap { $0 }
        guard revisions.allSatisfy({ LogParser.isHash(Substring($0)) }),
              FileManager.default.fileExists(atPath: folder.appending(path: ".git").path)
        else { return unavailable }
        let env = try await GitInvocation.readEnvironment(
            profile: nil, base: ownRepository(base, folder), runner: runner, cwd: folder)
        let check = try await runner.run(
            ["cat-file", "--batch-check"], cwd: folder, env: env,
            stdin: Data(revisions.map { "\($0)^{commit}\n" }.joined().utf8))
        let found = check.text.split(separator: "\n").filter { $0.contains(" commit ") }
        guard found.count == revisions.count else { return unavailable }

        let range = from.map { ["--left-right", "\($0)...\(to)"] } ?? [to]
        let counts = try await runner.run(["rev-list", "--count"] + range + ["--"], cwd: folder, env: env).text
            .split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        let format = "--format=%m%x1f%H%x1f%at%x1f%D%x1f%an%x1f%s"
        let log = try await runner.run(
            ["log", "-z", "--max-count=\(commitLimit)", format] + range + ["--"], cwd: folder, env: env)
        let commits = log.text.split(separator: "\0").compactMap(parseCommit)
        return SubmoduleChange(
            from: from, to: to, available: true, ahead: counts.last ?? 0,
            behind: counts.count == 2 ? counts[0] : 0, commits: commits)
    }

    // MARK: - Private

    private struct Entry {
        let name: String
        let path: String
        var url: String?
        var branch: String?
    }

    /// `.gitmodules` at the worktree root, a regular file (not followed through a symlink).
    private static func hasGitmodules(_ cwd: URL) -> Bool {
        let path = cwd.appending(path: ".gitmodules").path
        return (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeRegular
    }

    /// The parent's reads (`config`, `ls-files -s`, `ls-tree`) run no filter or diff driver, so the read
    /// environment needs no driver list.
    private static func parentEnvironment(_ base: [String: String]) -> [String: String] {
        GitInvocation.environment(profile: nil, base: base, access: .read(filterDrivers: []))
    }

    /// The `.gitmodules` entries with a path, in file order. Includes are not followed (`--no-includes`); a
    /// path that is empty, absolute or has a `.` or `..` component is skipped, as is a second entry for a path.
    private static func gitmodules(runner: GitRunner, cwd: URL, env: [String: String]) async throws -> [Entry] {
        let output = try await runner.run(
            ["config", "-z", "--no-includes", "--file", ".gitmodules", "--get-regexp",
             #"^submodule\..*\.(path|url|branch)$"#],
            cwd: cwd, env: env, allowedExitCodes: [0, 1]).stdout
        var order: [String] = []
        var values: [String: [String: String]] = [:]
        for (name, variable, value) in configEntries(output) {
            if values[name] == nil { order.append(name) }
            values[name, default: [:]][variable] = values[name]?[variable] ?? value
        }
        var entries: [Entry] = []
        for name in order {
            guard let path = values[name]?["path"], isSafePath(path), !entries.contains(where: { $0.path == path })
            else { continue }
            entries.append(Entry(name: name, path: path, url: values[name]?["url"], branch: values[name]?["branch"]))
        }
        return entries
    }

    /// The names with a `submodule.<name>.url` in the parent's config.
    private static func initializedNames(runner: GitRunner, cwd: URL, env: [String: String]) async throws
        -> Set<String>
    {
        let output = try await runner.run(
            ["config", "-z", "--get-regexp", #"^submodule\..*\.url$"#], cwd: cwd, env: env,
            allowedExitCodes: [0, 1]).stdout
        return Set(configEntries(output).map(\.name))
    }

    /// `submodule.<name>.<variable>` entries of `git config -z --get-regexp` (`key\nvalue\0`); the name may
    /// hold dots, the variable has none.
    private static func configEntries(_ output: Data) -> [(name: String, variable: String, value: String)] {
        output.split(separator: 0).compactMap { record in
            let parts = record.split(separator: UInt8(ascii: "\n"), maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(decoding: parts[0], as: UTF8.self)
            guard key.hasPrefix("submodule."), let dot = key.lastIndex(of: "."), parts.count == 2 else { return nil }
            let name = String(key[key.index(key.startIndex, offsetBy: 10)..<dot])
            guard !name.isEmpty else { return nil }
            return (name, String(key[key.index(after: dot)...]), String(decoding: parts[1], as: UTF8.self))
        }
    }

    private static func isSafePath(_ path: String) -> Bool {
        !path.hasPrefix("/") && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    /// The gitlinks (mode 160000) among `paths` that `command` (`ls-files -s -z` or `ls-tree -z <rev>`) lists,
    /// in its order, the first entry of a path only; a conflicted gitlink in the index (stages 1 to 3) is left out.
    /// `--literal-pathspecs`: a path is never a pattern or magic.
    private static func gitlinks(
        _ command: [String], paths: [String], runner: GitRunner, cwd: URL, env: [String: String]
    ) async throws -> [(path: String, sha: String)] {
        let output = try await runner.run(["--literal-pathspecs"] + command + ["--"] + paths, cwd: cwd, env: env)
        var links: [(path: String, sha: String)] = []
        for record in output.stdout.split(separator: 0) {
            // `<mode> <sha> <stage>\t<path>` (ls-files) or `<mode> commit <sha>\t<path>` (ls-tree).
            guard let tab = record.firstIndex(of: UInt8(ascii: "\t")) else { continue }
            let fields = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
            let path = String(decoding: record[record.index(after: tab)...], as: UTF8.self)
            guard fields.count == 3, fields[0] == "160000", fields[1] == "commit" || fields[2] == "0",
                  let sha = fields.first(where: { LogParser.isHash($0) }),
                  paths.contains(path), !links.contains(where: { $0.path == path })
            else { continue }
            links.append((path, String(sha)))
        }
        return links
    }

    /// One submodule and its nested ones.
    private static func read(
        _ entry: Entry, recorded: String, initialized: Bool, runner: GitRunner, cwd: URL, base: [String: String]
    ) async throws -> [Submodule] {
        let folder = cwd.appending(path: entry.path, directoryHint: .isDirectory)
        var state: Submodule.State = initialized ? .notCheckedOut : .notInitialized
        var changeCount = 0
        var nested: [Submodule] = []
        if isCheckout(folder, inside: cwd) {
            do {
                let env = try await GitInvocation.readEnvironment(
                    profile: nil, base: ownRepository(base, folder), runner: runner, cwd: folder)
                async let head = runner.run(
                    ["rev-parse", "--verify", "-q", "HEAD"], cwd: folder, env: env, allowedExitCodes: [0, 1])
                async let branch = runner.run(
                    ["symbolic-ref", "-q", "--short", "HEAD"], cwd: folder, env: env, allowedExitCodes: [0, 1])
                async let status = StatusReader.read(runner: runner, cwd: folder, env: env)
                let sha = try await head.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = try await branch.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let entries = try await status.entries
                if LogParser.isHash(Substring(sha)) {
                    state = .checkedOut(head: sha, branch: name.isEmpty ? nil : name)
                    changeCount = entries.count
                }
            } catch let error as GitError where error != .timeout {}
            if case .checkedOut = state {
                do {
                    nested = try await list(runner: runner, cwd: folder, base: base)
                } catch let error as GitError where error != .timeout {}
            }
        }
        let submodule = Submodule(
            name: entry.name, path: entry.path, url: entry.url, branch: entry.branch, recordedCommit: recorded,
            state: state, changeCount: changeCount)
        return [submodule] + nested.map {
            Submodule(
                name: $0.name, path: entry.path + "/" + $0.path, url: $0.url, branch: $0.branch,
                recordedCommit: $0.recordedCommit, state: $0.state, changeCount: $0.changeCount)
        }
    }

    /// `folder` has its own `.git` (without one, git would read the parent) and, symlinks resolved, stays
    /// inside `parent`.
    static func isCheckout(_ folder: URL, inside parent: URL) -> Bool {
        let resolved = folder.resolvingSymlinksInPath().path
        return resolved.hasPrefix(parent.resolvingSymlinksInPath().path + "/")
            && FileManager.default.fileExists(atPath: folder.appending(path: ".git").path)
    }

    /// `base` with the folder's parent as git's ceiling: a `.git` that is no repository (an empty folder) makes
    /// git fail instead of walking up and reading the parent repository as the submodule.
    static func ownRepository(_ base: [String: String], _ folder: URL) -> [String: String] {
        var env = base
        env["GIT_CEILING_DIRECTORIES"] = folder.deletingLastPathComponent().path
        return env
    }

    /// One `%m\x1f%H\x1f%at\x1f%D\x1f%an\x1f%s` record; the subject comes last, so it may hold anything.
    private static func parseCommit(_ record: Substring) -> SubmoduleChange.Commit? {
        let fields = record.split(separator: "\u{1F}", maxSplits: 5, omittingEmptySubsequences: false)
        guard fields.count == 6, LogParser.isHash(fields[1]), let time = TimeInterval(fields[2]) else { return nil }
        let refs = fields[3].isEmpty ? [] : fields[3].components(separatedBy: ", ")
        return SubmoduleChange.Commit(
            sha: String(fields[1]), subject: String(fields[5]), author: String(fields[4]),
            date: Date(timeIntervalSince1970: time), refs: refs, isNew: fields[0] != "<")
    }
}
