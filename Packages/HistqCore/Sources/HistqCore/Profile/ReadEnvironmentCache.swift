// Remembers the filter and diff driver names `GitInvocation.readEnvironment` lists in a folder, so a repeated read
// there runs no `git config` process. Those names are a security guard (a read must never run a filter or textconv
// the repo configures), so the rule is that every doubt is a miss: a stale hit would let a read run without a newly
// configured driver neutralised.
//
// A miss runs one `git config -z --show-origin --list` (both driver lists, and the file every entry came from) and
// one `git rev-parse` (the work tree's root, its git dir, config, `config.worktree` and HEAD). The entry is kept with
// a stat signature (device, inode, owner, mode, size, mtime and ctime in ns, or "absent") of every file whose change
// could change that listing:
// - every `file:` origin it shows (each must exist: git just read it);
// - the repo config, `config.worktree`, the git dir's `commondir` and the root's `.git` (a folder by identity and
//   owner only, since its times move with every lock file; a gitfile in full);
// - the global and system config paths git itself names (`git var GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM`, git
//   2.42 and later), the `share/git-core/gitconfig` next to git's `--exec-path` (Apple's git reads one) and
//   `/etc/gitconfig`, absent ones as absent; these are memoized per git (its real path) and environment;
// - the target of every `include.path` and `includeIf.<condition>.path`, taken or not: absolute, `~/` (against HOME)
//   or relative to the file that holds it;
// - the per-worktree HEAD when an `includeIf` condition is `onbranch:`;
// - what makes the git dir a git dir (else git searches the parent folders for another repo): its HEAD (present as a
//   file) and the common dir's `objects` and `refs` folders (by identity).
// The repo config, when it is a non-empty file, must be among the listing's origins (the listing and rev-parse saw
// the same repo). Entries are keyed on the git binary's real path, inode and ctime, so an updated git lists again.
// A hit re-stats them all and checks that the folder's real path (symlinks resolved) is still the root the entry was
// listed for, and runs nothing. Nothing is cached when the folder's real path is not a work tree's root (relative
// origins are relative to the root), a file is on a volume that is not local (a network volume may serve stale
// attributes while git reads fresh content, and stamps times with the server's clock), an include cannot be
// resolved (`~user/`, `%(prefix)/`, a relative path from the command line), an origin is not a file, the command
// line, standard input or a blob, `onbranch:` meets a ref storage setting (HEAD may then be a stub), a file is not a
// regular file (but `/dev/null`), a stat fails, a git older than 2.42 cannot name its config paths, or a present
// file changed less than 2 s before the listing started or later (a margin for a clock stepped back or a coarse
// file system clock).
import Darwin
import Foundation
import Synchronization

/// The driver names of recent read environments, one entry per folder, git and listing environment. Safe to share
/// between tasks; pass it to `GitInvocation.readEnvironment(profile:base:runner:cwd:cache:)`.
public final class ReadEnvironmentCache: Sendable {
    /// The most entries it keeps; the least recently used goes first.
    static let capacity = 32

    /// How long before the listing a file change still counts as "during the listing", in ns.
    static let raceMargin: Int64 = 2_000_000_000

    /// What an entry is for: the standardized folder path, the git binary (real path, device, inode and ctime) and
    /// the exact listing environment, so a different base, profile or git (or an updated one) never shares an entry.
    struct Key: Hashable, Sendable {
        let cwd: String
        let executable: String
        let env: [String: String]

        /// The key of the global and system config paths, which depend on the git and the environment only.
        var scope: Key { Key(cwd: "", executable: executable, env: env) }
    }

    /// One file whose change could change the listing, as it was when the entry was filled.
    struct Validator: Sendable {
        let path: String
        let signature: FileSignature
        /// Only its kind (absent, file, device, folder) must stay the same, not its identity or times.
        var kindOnly = false

        /// Whether the file still looks as it did.
        var holds: Bool {
            guard let now = FileSignature.at(path) else { return false }
            return kindOnly ? now.kind == signature.kind : now == signature
        }
    }

    /// The listed driver names, the work tree root they were listed for and the files they depend on.
    struct Entry: Sendable {
        let root: String
        let filters: [String]
        let diffs: [String]
        let validators: [Validator]
    }

    /// The entries (and their use order, oldest first) and the memoized global and system config paths per git and
    /// environment (`nil`: that git cannot name them, so nothing is cached).
    struct State: Sendable {
        var entries: [Key: Entry] = [:]
        var order: [Key] = []
        var scopePaths: [Key: [String]?] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    /// The filter and diff driver names git lists in `cwd` with `env`: the cached ones while every validator file
    /// is unchanged, else a new listing (cached when nothing is in doubt). Throws as
    /// `GitInvocation.drivers(runner:cwd:env:)` does.
    func drivers(runner: GitRunner, cwd: URL, env: [String: String]) async throws
        -> (filters: [String], diffs: [String])
    {
        guard let git = Self.realPath(runner.executable.path),
              case .file(let device, let inode, _, _, _, _, let ctime)? = FileSignature.at(git)
        else { return try await GitInvocation.drivers(runner: runner, cwd: cwd, env: env) }
        let key = Key(cwd: cwd.standardizedFileURL.path, executable: "\(git)\n\(device):\(inode):\(ctime)", env: env)
        if let entry = state.withLock({ $0.entries[key] }) {
            // A symlinked folder repointed elsewhere keeps its key but not its root.
            if Self.realPath(cwd.path) == entry.root, entry.validators.allSatisfy(\.holds) {
                state.withLock { $0.touch(key) }
                return (entry.filters, entry.diffs)
            }
            state.withLock { $0.remove(key) }
        }
        // A git that cannot name its config paths never gets an entry: list as without a cache, no rev-parse.
        if state.withLock({ $0.scopePaths[key.scope] }) == .some(nil) {
            return try await GitInvocation.drivers(runner: runner, cwd: cwd, env: env)
        }
        return try await fill(key, runner: runner, cwd: cwd, env: env)
    }

    /// Lists the drivers and, when nothing is in doubt, keeps them under `key`.
    private func fill(_ key: Key, runner: GitRunner, cwd: URL, env: [String: String]) async throws
        -> (filters: [String], diffs: [String])
    {
        let start = Int64(clock_gettime_nsec_np(CLOCK_REALTIME))
        let rootBefore = Self.realPath(cwd.path)
        async let listing = runner.run(
            ["config", "-z", "--show-origin", "--list"], cwd: cwd, env: env, timeout: .seconds(10))
        async let located = Located.find(runner: runner, cwd: cwd, env: env)
        async let scopes = scopePaths(key, runner: runner, cwd: cwd, env: env)
        let records = try ConfigRecord.parse(await listing.stdout)
        let drivers = try GitInvocation.drivers(in: records.map(\.key))
        if let located = await located, let scopes = await scopes,
           rootBefore == located.root, Self.realPath(cwd.path) == located.root,
           let validators = Self.validators(records, located: located, scopes: scopes, env: env, start: start)
        {
            let entry = Entry(
                root: located.root, filters: drivers.filters, diffs: drivers.diffs, validators: validators)
            state.withLock { $0.store(entry, for: key) }
        }
        return drivers
    }

    /// The global and system config paths git names for `env` (`git var`, git 2.42 and later) and the
    /// `share/git-core/gitconfig` next to its `--exec-path`, once per git and environment (`key.scope`). `nil` when
    /// that git cannot name them (memoized) or a command failed (not memoized: the next miss asks again).
    private func scopePaths(_ key: Key, runner: GitRunner, cwd: URL, env: [String: String]) async -> [String]? {
        if let known = state.withLock({ $0.scopePaths[key.scope] }) { return known }
        // Named even when `GIT_CONFIG_NOSYSTEM` hides it: stating one file more never makes a hit stale.
        var systemEnv = env
        systemEnv["GIT_CONFIG_NOSYSTEM"] = nil
        let paths: [String]?
        do {
            async let system = runner.run(
                ["var", "GIT_CONFIG_SYSTEM"], cwd: cwd, env: systemEnv, timeout: .seconds(10))
            async let global = runner.run(["var", "GIT_CONFIG_GLOBAL"], cwd: cwd, env: env, timeout: .seconds(10))
            async let execPath = runner.run(["--exec-path"], cwd: cwd, env: env, timeout: .seconds(10))
            let lines = try await (system.text + global.text).split(separator: "\n").map(String.init)
            let exec = try await execPath.text.trimmingCharacters(in: .newlines)
            guard lines.allSatisfy({ $0.hasPrefix("/") }), let real = Self.realPath(exec) else { return nil }
            // `<prefix>/libexec/git-core` -> `<prefix>/share/git-core/gitconfig`.
            let share = URL(filePath: real).deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "share/git-core/gitconfig").path
            paths = lines + [share]
        } catch let error as GitError where error.exitCode == 129 {
            // `git var` printed its usage: this git (older than 2.42) has no such variable, now or next time.
            paths = nil
        } catch {
            return nil
        }
        state.withLock { state in
            if state.scopePaths.count >= Self.capacity { state.scopePaths.removeAll() }
            state.scopePaths[key.scope] = paths
        }
        return paths
    }

    /// Every file whose change could change `records`, with its signature now; `nil` when anything is in doubt.
    static func validators(
        _ records: [ConfigRecord], located: Located, scopes: [String], env: [String: String], start: Int64
    ) -> [Validator]? {
        var mustExist: [String] = []
        var paths = scopes + ["/etc/gitconfig", located.config, located.worktreeConfig, located.gitDir + "/commondir"]
        var onBranch = false
        var refStorage = false
        for record in records {
            let holder: String?
            switch record.origin {
            case .file(let path):
                let absolute = path.hasPrefix("/") ? path : located.root + "/" + path
                mustExist.append(absolute)
                holder = absolute
            case .commandLine, .standardInput, .blob:
                holder = nil
            case .unknown:
                return nil
            }
            let key = String(decoding: record.key, as: UTF8.self).lowercased()
            if key == "extensions.refstorage" { refStorage = true }
            if key.hasPrefix("includeif.onbranch:") { onBranch = true }
            guard key == "include.path" || (key.hasPrefix("includeif.") && key.hasSuffix(".path")) else { continue }
            guard let value = record.value.flatMap({ String(validating: $0, as: UTF8.self) }),
                  let target = includeTarget(value, holder: holder, home: env["HOME"])
            else { return nil }
            paths.append(target)
        }
        if onBranch {
            // With reftable, HEAD is a stub that never changes while the branch does.
            guard !refStorage else { return nil }
            paths.append(located.head)
        }
        // A non-empty repo config that is not among the origins: the listing did not read the repo rev-parse found.
        if case .file(_, _, _, _, let size, _, _)? = FileSignature.at(located.config), size > 0,
           !mustExist.contains(located.config)
        {
            return nil
        }
        let since = start - raceMargin
        var validators: [Validator] = []
        var seen: Set<String> = []
        guard isLocal(located.root), isLocal(located.gitDir) else { return nil }
        for path in mustExist + paths where seen.insert(path).inserted {
            guard let signature = FileSignature.at(path) else { return nil }
            if signature != .absent, !isLocal(path) { return nil }
            switch signature {
            case .absent:
                if mustExist.contains(path) { return nil }
            case .file(_, _, _, _, _, let mtime, let ctime):
                // Changed while it was listed: the listing may have seen either version.
                if mtime >= since || ctime >= since { return nil }
            case .device:
                if path != "/dev/null" { return nil }
            case .directory:
                return nil
            }
            validators.append(Validator(path: path, signature: signature))
        }
        // The root's `.git`: a folder (its times move with every lock file, so who and where it is) or a gitfile.
        let anchor = located.root + "/.git"
        guard seen.insert(anchor).inserted, let signature = FileSignature.at(anchor), isLocal(anchor) else {
            return nil
        }
        switch signature {
        case .directory: break
        case .file(_, _, _, _, _, let mtime, let ctime) where mtime < since && ctime < since: break
        default: return nil
        }
        validators.append(Validator(path: anchor, signature: signature))
        // What makes the git dir a git dir: a HEAD file (rewritten by every checkout, so its kind only) and the
        // common dir's `objects` and `refs` folders.
        for (path, kind) in [(located.gitDir + "/HEAD", FileSignature.Kind.file),
                             (located.commonDir + "/objects", .directory), (located.commonDir + "/refs", .directory)]
        {
            guard let signature = FileSignature.at(path), signature.kind == kind, isLocal(path) else { return nil }
            validators.append(Validator(path: path, signature: signature, kindOnly: kind == .file))
        }
        return validators
    }

    /// `path` with every symlink resolved, as git reports a work tree's root; `nil` when it cannot be resolved.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Whether `path` is on a local volume (not NFS, SMB, AFP or another network file system).
    static func isLocal(_ path: String) -> Bool {
        var info = statfs()
        return statfs(path, &info) == 0 && info.f_flags & UInt32(MNT_LOCAL) != 0
    }

    /// The file an include `value` held by the file `holder` (nil: not a file) names, as git opens it: absolute,
    /// `~/` against `home`, or relative to the holder's folder. `nil` for anything else (`~user/`, `%(prefix)/`, a
    /// relative path without a file).
    static func includeTarget(_ value: String, holder: String?, home: String?) -> String? {
        if value.hasPrefix("~/") {
            guard let home, home.hasPrefix("/") else { return nil }
            return home + value.dropFirst()
        }
        if value.hasPrefix("/") { return value }
        guard !value.isEmpty, !value.hasPrefix("~"), !value.hasPrefix("%("), let holder,
              let slash = holder.lastIndex(of: "/")
        else { return nil }
        return String(holder[...slash]) + value
    }
}

extension ReadEnvironmentCache.State {
    /// Marks `key` as the most recently used.
    mutating func touch(_ key: ReadEnvironmentCache.Key) {
        guard let index = order.firstIndex(of: key) else { return }
        order.append(order.remove(at: index))
    }

    /// Drops the entry of `key`.
    mutating func remove(_ key: ReadEnvironmentCache.Key) {
        entries[key] = nil
        order.removeAll { $0 == key }
    }

    /// Keeps `entry` under `key` as the most recently used, dropping the oldest beyond the capacity.
    mutating func store(_ entry: ReadEnvironmentCache.Entry, for key: ReadEnvironmentCache.Key) {
        remove(key)
        entries[key] = entry
        order.append(key)
        while order.count > ReadEnvironmentCache.capacity { entries[order.removeFirst()] = nil }
    }
}

/// How a file looked: compared as a whole, so any change (absent and present included) is a difference.
enum FileSignature: Equatable, Sendable {
    /// No such file (or a path component is not a folder, which git also reads as no file).
    case absent
    /// A regular file, with its times in ns.
    case file(device: Int64, inode: UInt64, owner: UInt32, mode: UInt16, size: Int64, mtime: Int64, ctime: Int64)
    /// A device such as `/dev/null`: its times move with every write, so only which device it is.
    case device(device: Int64, inode: UInt64, rdev: Int64)
    /// A folder: its times move with every entry added or removed, so only which folder it is and who owns it.
    case directory(device: Int64, inode: UInt64, owner: UInt32, mode: UInt16)

    /// What a signature is of, whatever its identity and times.
    enum Kind: Sendable { case absent, file, device, directory }

    var kind: Kind {
        switch self {
        case .absent: .absent
        case .file: .file
        case .device: .device
        case .directory: .directory
        }
    }

    /// The signature of `path` now, following symlinks as git does when it opens it; `nil` when it cannot be stated
    /// (other than missing) or is neither a regular file, a character device nor a folder.
    static func at(_ path: String) -> FileSignature? {
        var info = stat()
        guard stat(path, &info) == 0 else { return errno == ENOENT || errno == ENOTDIR ? .absent : nil }
        let nanoseconds = { (time: timespec) in Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec) }
        let device = Int64(info.st_dev)
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            return .file(
                device: device, inode: info.st_ino, owner: info.st_uid, mode: info.st_mode, size: info.st_size,
                mtime: nanoseconds(info.st_mtimespec), ctime: nanoseconds(info.st_ctimespec))
        case S_IFCHR:
            return .device(device: device, inode: info.st_ino, rdev: Int64(info.st_rdev))
        case S_IFDIR:
            return .directory(device: device, inode: info.st_ino, owner: info.st_uid, mode: info.st_mode)
        default:
            return nil
        }
    }
}

/// One entry of `git config -z --show-origin --list`: `<origin>\0<key>\n<value>\0`, or `<origin>\0<key>\0` for a key
/// without a value.
struct ConfigRecord: Sendable {
    /// Where git read an entry.
    enum Origin: Sendable {
        /// A config file, its path as git opened it (relative paths are relative to the work tree's root).
        case file(String)
        /// `GIT_CONFIG_COUNT`, `GIT_CONFIG_PARAMETERS` or `-c`: part of the cache key.
        case commandLine
        /// `--file -`.
        case standardInput
        /// `--blob`.
        case blob
        /// Anything else, or a file path that is not UTF-8.
        case unknown
    }

    let origin: Origin
    let key: Data.SubSequence
    let value: Data.SubSequence?

    /// The records of a listing. Throws `configListingMalformed` unless it is whole records, so a driver name is
    /// never read from the wrong field.
    static func parse(_ data: Data) throws -> [ConfigRecord] {
        guard !data.isEmpty else { return [] }
        guard data.last == 0 else { throw GitInvocation.ReadSafetyError.configListingMalformed }
        let fields = data.dropLast().split(separator: 0, omittingEmptySubsequences: false)
        guard fields.count.isMultiple(of: 2) else { throw GitInvocation.ReadSafetyError.configListingMalformed }
        return stride(from: 0, to: fields.count, by: 2).map { index in
            let entry = fields[index + 1]
            let newline = entry.firstIndex(of: UInt8(ascii: "\n"))
            return ConfigRecord(
                origin: Origin(fields[index]), key: entry[..<(newline ?? entry.endIndex)],
                value: newline.map { entry[entry.index(after: $0)...] })
        }
    }
}

extension ConfigRecord.Origin {
    /// The origin git printed: `file:<path>`, `command line:`, `standard input:` or `blob:<name>`.
    init(_ field: Data.SubSequence) {
        let text = String(validating: field, as: UTF8.self) ?? ""
        if text.hasPrefix("file:"), text.count > 5 {
            self = .file(String(text.dropFirst(5)))
        } else if text == "command line:" {
            self = .commandLine
        } else if text == "standard input:" {
            self = .standardInput
        } else if text.hasPrefix("blob:") {
            self = .blob
        } else {
            self = .unknown
        }
    }
}

/// What `git rev-parse` says about a work tree, for a folder that is its root.
struct Located: Sendable {
    /// The work tree's root (git's own folder while it lists).
    let root: String
    /// The worktree's own git dir (`.git/worktrees/<name>` for a linked worktree).
    let gitDir: String
    /// The git dir shared by every worktree (the main one's `.git`).
    let commonDir: String
    /// The repo config (the common one for a linked worktree).
    let config: String
    /// The worktree's `config.worktree`, read when `extensions.worktreeConfig` is on.
    let worktreeConfig: String
    /// The worktree's own HEAD.
    let head: String

    /// Asks git, in the listing environment (it runs nothing); `nil` when `cwd` is not a work tree's root or git
    /// fails (a bare repo, no repo).
    static func find(runner: GitRunner, cwd: URL, env: [String: String]) async -> Located? {
        let args = ["rev-parse", "--path-format=absolute", "--show-toplevel", "--show-prefix", "--absolute-git-dir",
                    "--git-common-dir", "--git-path", "config", "--git-path", "config.worktree", "--git-path", "HEAD"]
        guard let result = try? await runner.run(args, cwd: cwd, env: env, timeout: .seconds(10)) else { return nil }
        let lines = result.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Seven lines and the final newline; an empty prefix means `cwd` is the root.
        guard lines.count == 8, lines[7].isEmpty, lines[1].isEmpty,
              [lines[0], lines[2], lines[3], lines[4], lines[5], lines[6]].allSatisfy({ $0.hasPrefix("/") })
        else { return nil }
        return Located(
            root: lines[0], gitDir: lines[2], commonDir: lines[3], config: lines[4], worktreeConfig: lines[5],
            head: lines[6])
    }
}
