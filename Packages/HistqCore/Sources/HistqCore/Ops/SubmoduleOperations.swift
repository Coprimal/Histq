// Submodule writes: update (level by level), auto-update after a write, sync, add, remove, set URL and set branch.
// Each takes the lane once and only calls `exec` inside (the update step of `addSubmodule`, and the gitlink step of
// `discard`, is the same helper as `updateSubmodules`).
// Nothing is journaled: the undo journal skips gitlinks.
//
// Safety: URLs and paths are checked first (`validateSubmoduleURL`, `validateSubmodulePath`) and always come after
// `--`, with `--literal-pathspecs`. Names come from `.gitmodules`, which the repo controls: they only build config
// keys and the `modules/<name>` folder, which `modulesFolder(name:gitDir:)` keeps inside the git folder. No
// `protocol.*.allow` is ever set here.
//
// Token: the gate (`NetworkTarget.submodule(path:)`) decides per submodule, one level at a time (never `--recursive`
// on a git command). The token reaches the network step alone: a fetch inside a submodule that already has a git
// folder, then a checkout without it (`--no-fetch`), so the submodule's own filters and hooks never see it. A
// submodule's configured `update` mode other than `checkout` (`rebase`, `merge`, `none`, `!command`) is skipped, except
// by `discard`, which puts the submodule back on its recorded commit as `submodule update --checkout` does.
import Foundation

public enum SubmoduleOperationError: Error, Equatable, Sendable {
    /// Not an `https://`, `ssh://`, scp-like (`user@host:path`) or `./` `../` relative URL, or one git could run as a
    /// command or a local path.
    case invalidURL(String)
    /// Empty, absolute, with a `.`, `..` or `.git` component, a leading `-` or a control character.
    case invalidPath(String)
    /// A submodule name with a `..` component or absolute, or whose `modules/<name>` folder resolves outside the git
    /// folder's `modules/`.
    case invalidName(String)
    /// `.gitmodules` has no (or more than one) submodule at this path.
    case notASubmodule(String)
}

/// A submodule `updateSubmodules` left alone because its configured `update` mode is not `checkout`.
public struct SkippedSubmodule: Sendable, Equatable {
    /// From the top of the repository (a nested one starts with its parents' paths).
    public let path: String
    /// `rebase`, `merge`, `none` or `!command`.
    public let mode: String

    public init(path: String, mode: String) {
        self.path = path
        self.mode = mode
    }
}

/// Some submodules failed to update; the others were updated.
public struct SubmoduleUpdateFailure: Error, Sendable, Equatable {
    public struct Failure: Sendable, Equatable {
        public let path: String
        /// git's message.
        public let message: String

        public init(path: String, message: String) {
            self.path = path
            self.message = message
        }
    }

    public let failures: [Failure]
    /// The submodules skipped for their update mode (as `updateSubmodules` returns them on success).
    public let skipped: [SkippedSubmodule]

    public init(failures: [Failure], skipped: [SkippedSubmodule]) {
        self.failures = failures
        self.skipped = skipped
    }
}

/// What `autoUpdateSubmodules` did after a write that moved gitlinks. Paths are from the top of the repository.
public struct SubmoduleAutoUpdate: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// The write added the gitlink: there was no commit to have sat at.
        case notRecordedBefore
        /// The configured `update` mode is not `checkout` (`rebase`, `merge`, `none`, `!command`).
        case updateMode(String)
        /// The checkout was not on the commit recorded before the write.
        case moved
        /// The checkout is on this branch, not detached.
        case onBranch(String)
        /// The checkout has changes (untracked files included).
        case dirty
    }

    public struct Skipped: Sendable, Equatable {
        public let path: String
        public let reason: Reason

        public init(path: String, reason: Reason) {
            self.path = path
            self.reason = reason
        }
    }

    public var updated: [String]
    public var skipped: [Skipped]
    /// An empty path: the repository's own submodules could not be read.
    public var failed: [SubmoduleUpdateFailure.Failure]

    public init(updated: [String] = [], skipped: [Skipped] = [], failed: [SubmoduleUpdateFailure.Failure] = []) {
        self.updated = updated
        self.skipped = skipped
        self.failed = failed
    }
}

extension GitOperations {
    // MARK: - Submodules

    /// After a write that moved this repo's pointers: updates each submodule whose gitlink in the index changed from
    /// `before` (the gitlinks of HEAD before the write, by path) only when it is checked out, detached, clean and still
    /// on its `before` commit, with mode `checkout`; then the same, one level down, inside each updated one. A
    /// submodule already on its new commit, not initialized or not checked out is left out (never initialized or
    /// cloned); the others are skipped with a reason. `base` builds the read environment of each submodule, read in
    /// its own folder. Without `.gitmodules` it runs no git. Throws only `CancellationError`.
    public func autoUpdateSubmodules(before: [String: String], base: [String: String]) async throws
        -> SubmoduleAutoUpdate
    {
        guard Self.hasGitmodules(cwd) else { return SubmoduleAutoUpdate() }
        do {
            return try await lane { ops in try await ops.autoUpdateLevel(before: before, base: base, prefix: "") }
        } catch let error as CancellationError {
            throw error
        } catch {
            return SubmoduleAutoUpdate(failed: [.init(path: "", message: Self.message(error))])
        }
    }

    /// Updates the submodules at `paths` (empty = every submodule of the repo) to the commit the index records:
    /// `initialize` runs `git submodule init` first, `recursive` then does the same for every submodule of each
    /// updated one, level by level. Returns the submodules skipped for their update mode; throws
    /// `SubmoduleUpdateFailure` when some failed (the others are still updated).
    @discardableResult
    public func updateSubmodules(_ paths: [String], initialize: Bool, recursive: Bool) async throws
        -> [SkippedSubmodule]
    {
        for path in paths { try Self.validateSubmodulePath(path) }
        let report = try await lane { ops in
            try await ops.updateLevel(paths, initialize: initialize, recursive: recursive, prefix: "")
        }
        guard report.failures.isEmpty else { throw report }
        return report.skipped
    }

    /// The submodule step of a clone: initializes and clones every submodule of the new repo at `folder`, level by
    /// level (`updateSubmodules([], initialize: true, recursive: true)`), as `profile` with `token` only where the
    /// gate lets each one have it. `progress` gets one line when it starts. Without `.gitmodules` it runs no git.
    /// Returns and throws as `updateSubmodules`.
    @discardableResult
    public static func cloneSubmodules(
        in folder: URL, runner: GitRunner, profile: Profile?, base: [String: String], token: String?,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> [SkippedSubmodule] {
        guard hasGitmodules(folder) else { return [] }
        progress("Cloning submodules…")
        let ops = GitOperations(runner: runner, cwd: folder, profile: profile, base: base, token: token)
        return try await ops.updateSubmodules([], initialize: true, recursive: true)
    }

    /// `git submodule sync --recursive` of `paths` (empty = every submodule): the URLs of `.gitmodules` copied into
    /// the repo's config and each submodule's remote.
    public func syncSubmodules(_ paths: [String]) async throws {
        for path in paths { try Self.validateSubmodulePath(path) }
        try await lane { ops in
            _ = try await ops.exec(["--literal-pathspecs", "submodule", "sync", "--recursive", "--"] + paths)
        }
    }

    /// Adds the repository at `url` as a submodule at `path` (staged), on `branch` (nil = the remote's default),
    /// with its own submodules when `recursive`; it is left detached at its recorded commit, as an update leaves it.
    /// The clone runs without the token: `submodule add` also stages `.gitmodules` and the gitlink in this repo, which
    /// runs this repo's own clean filters (the user's own helpers still answer). Throws
    /// `SubmoduleUpdateFailure` when only the update of its own submodules failed.
    public func addSubmodule(url: String, path: String, branch: String?, recursive: Bool) async throws {
        try Self.validateSubmoduleURL(url)
        try Self.validateSubmodulePath(path)
        if let branch, !branch.isEmpty { try await validateBranchName(branch) }
        let report = try await lane { ops in
            let branchFlags = branch.flatMap { $0.isEmpty ? nil : ["-b", $0] } ?? []
            try await ops.exec(["submodule", "add"] + branchFlags + ["--", url, path], network: true)
            try await ops.submodule(at: ops.cwd.appending(path: path, directoryHint: .isDirectory))
                .exec(["checkout", "-q", "--detach"])
            return try await ops.updateLevel([path], initialize: true, recursive: recursive, prefix: "")
        }
        guard report.failures.isEmpty else { throw report }
    }

    /// Removes the submodule at `path`: `deinit`, `git rm` (the removal stays staged: gitlink and `.gitmodules`
    /// entry) and its `modules/<name>` git folder. Without `force`, local changes in the submodule make git refuse
    /// (thrown, nothing removed).
    public func removeSubmodule(_ path: String, force: Bool) async throws {
        try Self.validateSubmodulePath(path)
        try await lane { ops in
            guard let name = try await ops.submoduleNames()[path] else {
                throw SubmoduleOperationError.notASubmodule(path)
            }
            let folder = try Self.modulesFolder(name: name, gitDir: try await ops.gitDir())
            let forceFlag = force ? ["-f"] : []
            try await ops.exec(["--literal-pathspecs", "submodule", "deinit", "-q"] + forceFlag + ["--", path])
            try await ops.exec(["--literal-pathspecs", "rm", "-q"] + forceFlag + ["--", path])
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        }
    }

    /// Sets the URL of the submodule at `path` in `.gitmodules`; `set-url` syncs it into the repo's config and the
    /// submodule's remote itself.
    public func setSubmoduleURL(_ path: String, url: String) async throws {
        try Self.validateSubmodulePath(path)
        try Self.validateSubmoduleURL(url)
        try await lane { ops in
            _ = try await ops.exec(["--literal-pathspecs", "submodule", "set-url", "--", path, url])
        }
    }

    /// Sets the branch of the submodule at `path` in `.gitmodules`; an empty `branch` removes it (the remote's
    /// default).
    public func setSubmoduleBranch(_ path: String, branch: String) async throws {
        try Self.validateSubmodulePath(path)
        if !branch.isEmpty { try await validateBranchName(branch) }
        let flags = branch.isEmpty ? ["-d"] : ["-b", branch]
        try await lane { ops in
            _ = try await ops.exec(["--literal-pathspecs", "submodule", "set-branch"] + flags + ["--", path])
        }
    }

    // MARK: - Submodule validation

    /// A submodule URL: `https://`, `ssh://`, scp-like `[user@]host:path`, or relative `./` `../` (resolved against
    /// this repo's remote). Refused: empty, a leading `-`, control characters, `<transport>::` (`ext::`, `fd::`),
    /// `file://` and every other scheme (`http://`, `git://`), and absolute or `~` local paths.
    public static func validateSubmoduleURL(_ url: String) throws {
        let invalid = SubmoduleOperationError.invalidURL(url)
        guard !url.isEmpty, !url.hasPrefix("-"),
              !url.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw invalid }
        // `<transport>::<address>` runs git's remote helper `git-remote-<transport>`.
        if url.wholeMatch(of: /[A-Za-z0-9+.\-]*::.*/) != nil { throw invalid }
        if url.hasPrefix("https://") || url.hasPrefix("ssh://") || url.hasPrefix("./") || url.hasPrefix("../") {
            return
        }
        // Any other `scheme://`, or a local path.
        guard !url.contains("://"), !url.hasPrefix("/"), !url.hasPrefix("~"), let colon = url.firstIndex(of: ":")
        else { throw invalid }
        // scp-like: no `/` before the first `:` (git reads it as a path otherwise), a host that is no ssh option.
        let address = url[..<colon]
        let host = address.split(separator: "@", omittingEmptySubsequences: false).last ?? ""
        guard !address.contains("/"), !host.isEmpty, !host.hasPrefix("-") else { throw invalid }
    }

    /// A submodule path, relative to the top of the repo: not empty, no leading `-`, no control characters, not
    /// absolute, and no empty, `.`, `..` or `.git` (in any case) component.
    public static func validateSubmodulePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("-"), !path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" })
        else { throw SubmoduleOperationError.invalidPath(path) }
    }

    /// The git folder of submodule `name`: `<gitDir>/modules/<name>`, where `gitDir` is the folder git keeps
    /// `modules` in (`rev-parse --git-path modules`: the worktree's own git folder in a linked worktree). Refuses an
    /// empty or absolute name, one with a `..` component, and a folder that resolves (symlinks followed) outside
    /// `<gitDir>/modules/`.
    public static func modulesFolder(name: String, gitDir: URL) throws -> URL {
        guard !name.isEmpty, !name.hasPrefix("/"),
              !name.split(separator: "/", omittingEmptySubsequences: false).contains("..")
        else { throw SubmoduleOperationError.invalidName(name) }
        let folder = gitDir.appending(path: "modules/" + name, directoryHint: .isDirectory)
        // Strictly inside: a name such as `.` would be `modules` itself.
        guard realPath(folder).hasPrefix(realPath(gitDir) + "/modules/") else {
            throw SubmoduleOperationError.invalidName(name)
        }
        return folder
    }

    /// `url`'s path with every symlink resolved (`realpath`) as far as it exists; the rest is appended as it is.
    private static func realPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        var rest = ""
        while true {
            if let resolved = realpath(path, nil) {
                defer { free(resolved) }
                return String(cString: resolved) + rest
            }
            let parent = (path as NSString).deletingLastPathComponent
            guard parent != path else { return path + rest }
            rest = "/" + (path as NSString).lastPathComponent + rest
            path = parent
        }
    }

    // MARK: - Submodule helpers

    /// Updates one level (`paths` of this repo, empty = all), then, when `recursive`, the submodules of each updated
    /// one. Only calls `exec`: it runs inside the caller's lane (`discard` uses it too, for gitlinks). `restoring`
    /// (discard): the configured update mode is not skipped, and a submodule that is not initialized but checked out
    /// away from its recorded commit is a failure, not left alone.
    func updateLevel(
        _ paths: [String], initialize: Bool, recursive: Bool, prefix: String, restoring: Bool = false
    ) async throws -> SubmoduleUpdateFailure {
        var failures: [SubmoduleUpdateFailure.Failure] = []
        var skipped: [SkippedSubmodule] = []
        let entries = try await submoduleEntries()
        var targets: [(name: String, path: String, commit: String)] = []
        if paths.isEmpty {
            targets = entries
        } else {
            for path in paths {
                if let entry = entries.first(where: { $0.path == path }) {
                    targets.append(entry)
                } else {
                    failures.append(.init(path: prefix + path, message: "No submodule at \(path)."))
                }
            }
        }
        var updated: [String] = []
        for target in targets {
            do {
                if !restoring, let mode = try await updateMode(target.name), mode != "checkout" {
                    skipped.append(SkippedSubmodule(path: prefix + target.path, mode: mode))
                    continue
                }
                if initialize {
                    try await exec(["--literal-pathspecs", "submodule", "init", "-q", "--", target.path])
                } else if try await exec(
                    ["config", "--get", "submodule.\(target.name).url"], allowedExitCodes: [0, 1]).exitCode != 0
                {
                    // Not initialized: left alone, as git does (a git folder a deinit left is not fetched into).
                    if restoring, try await checkoutHead(target.path) != target.commit {
                        let message = "The submodule at \(target.path) is not initialized."
                        failures.append(.init(path: prefix + target.path, message: message))
                    }
                    continue
                }
                try await updateOne(name: target.name, path: target.path, commit: target.commit)
                updated.append(target.path)
            } catch let error as CancellationError {
                throw error
            } catch {
                failures.append(.init(path: prefix + target.path, message: Self.message(error)))
            }
        }
        guard recursive else { return SubmoduleUpdateFailure(failures: failures, skipped: skipped) }
        for path in updated {
            let folder = cwd.appending(path: path, directoryHint: .isDirectory)
            // Without its own `.git`, git would walk up and read this repo again.
            guard FileManager.default.fileExists(atPath: folder.appending(path: ".git").path) else { continue }
            do {
                let nested = try await submodule(at: folder)
                    .updateLevel([], initialize: initialize, recursive: true, prefix: prefix + path + "/")
                failures += nested.failures
                skipped += nested.skipped
            } catch let error as CancellationError {
                throw error
            } catch {
                failures.append(.init(path: prefix + path, message: Self.message(error)))
            }
        }
        return SubmoduleUpdateFailure(failures: failures, skipped: skipped)
    }

    /// One level of `autoUpdateSubmodules`. Only calls `exec` (and reads in the submodules' own folders): it runs
    /// inside the caller's lane. Throws only when this level's submodules cannot be listed.
    private func autoUpdateLevel(before: [String: String], base: [String: String], prefix: String) async throws
        -> SubmoduleAutoUpdate
    {
        var result = SubmoduleAutoUpdate()
        let changed = try await submoduleEntries().filter { before[$0.path] != $0.commit }
        for target in changed {
            let folder = cwd.appending(path: target.path, directoryHint: .isDirectory)
            let skip = { (reason: SubmoduleAutoUpdate.Reason) in
                result.skipped.append(.init(path: prefix + target.path, reason: reason))
            }
            do {
                guard SubmoduleReader.isCheckout(folder, inside: cwd),
                      try await exec(
                          ["config", "--get", "submodule.\(target.name).url"], allowedExitCodes: [0, 1]).exitCode == 0
                else { continue }
                let status: WorkingStatus
                do {
                    let readEnv = try await GitInvocation.readEnvironment(
                        profile: nil, base: SubmoduleReader.ownRepository(base, folder), runner: runner, cwd: folder)
                    status = try await StatusReader.read(runner: runner, cwd: folder, env: readEnv)
                } catch let error as GitError where error != .timeout {
                    // A `.git` git cannot read (as `SubmoduleReader` lists it): not checked out.
                    continue
                }
                guard let head = status.branch.commit, head != target.commit else { continue }
                guard let old = before[target.path] else { skip(.notRecordedBefore); continue }
                if let mode = try await updateMode(target.name), mode != "checkout" { skip(.updateMode(mode)); continue }
                guard head == old else { skip(.moved); continue }
                if let branch = status.branch.name { skip(.onBranch(branch)); continue }
                guard status.entries.isEmpty else { skip(.dirty); continue }
                try await updateOne(name: target.name, path: target.path, commit: target.commit)
                result.updated.append(prefix + target.path)
                let nestedBefore = try await SubmoduleReader.recorded(
                    runner: runner, cwd: folder, base: SubmoduleReader.ownRepository(base, folder), revision: old)
                let nested = try await submodule(at: folder)
                    .autoUpdateLevel(before: nestedBefore, base: base, prefix: prefix + target.path + "/")
                result.updated += nested.updated
                result.skipped += nested.skipped
                result.failed += nested.failed
            } catch let error as CancellationError {
                throw error
            } catch {
                result.failed.append(.init(path: prefix + target.path, message: Self.message(error)))
            }
        }
        return result
    }

    /// Checks out the recorded `commit` of one submodule of this level, fetching only what is missing.
    private func updateOne(name: String, path: String, commit: String) async throws {
        let decision = await tokenDecision(for: .submodule(path: path))
        let attach = decision == .attach && credential != nil
        guard let repo = try await submoduleRepo(name: name, path: path) else {
            // Not cloned yet: the clone is the network step, so `submodule update` itself runs in the gated
            // environment. The new repo has no config of its own yet and `.network` runs no hook, so nothing the
            // submodule could configure sees the token.
            _ = try await withheldExec(decision) {
                try await exec(
                    ["--literal-pathspecs", "submodule", "update", "--checkout", "--", path], network: true,
                    environment: attach ? credential.map { tokenEnvironment(.fetch, $0) } : nil)
            }
            return
        }
        // Already cloned: its own config (filters, hooks) would run on checkout, so only the fetch, inside it, gets
        // the token; the checkout then runs without it and without fetching.
        let sub = submodule(at: repo)
        if await !sub.hasCommit(commit) {
            let fetchEnv = attach ? sub.credential.map { sub.tokenEnvironment(.fetch, $0) } : nil
            // As `git submodule update`: a submodule's URL is not the user's own choice.
            let notFromUser = ["GIT_PROTOCOL_FROM_USER": "0"]
            try await withheldExec(decision) {
                try await sub.exec(
                    ["fetch", "--no-recurse-submodules"], network: true, extraEnv: notFromUser, environment: fetchEnv)
                if await !sub.hasCommit(commit) {
                    // Not on any fetched ref: by its id, from the only remote (else `origin`), as git does.
                    let remotes = try await GitInvocation.remoteNames(runner: sub.runner, cwd: sub.cwd, env: sub.env)
                    let remote = remotes.count == 1 ? remotes[0] : "origin"
                    try await sub.exec(
                        ["fetch", "--no-recurse-submodules", "--end-of-options", remote, commit], network: true,
                        extraEnv: notFromUser, environment: fetchEnv)
                }
            }
        }
        try await exec(["--literal-pathspecs", "submodule", "update", "--checkout", "--no-fetch", "--", path])
    }

    /// The commit checked out in the submodule at `path` of this level; nil without a checkout or a commit.
    private func checkoutHead(_ path: String) async throws -> String? {
        let folder = cwd.appending(path: path, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: folder.appending(path: ".git").path) else { return nil }
        let result = try await submodule(at: folder).exec(
            ["rev-parse", "--verify", "-q", "HEAD"], allowedExitCodes: [0, 1])
        return result.exitCode == 0 ? result.text.trimmingCharacters(in: .newlines) : nil
    }

    /// The operations run in a submodule's `folder` (its worktree or its git folder), git kept from walking up into
    /// this repo (`GIT_CEILING_DIRECTORIES`).
    private func submodule(at folder: URL) -> GitOperations {
        let ceiling = ["GIT_CEILING_DIRECTORIES": folder.deletingLastPathComponent().path]
        return GitOperations(
            runner: runner, cwd: folder, env: env.merging(ceiling) { $1 },
            networkEnv: networkEnv.merging(ceiling) { $1 },
            credential: credential.map {
                NetworkCredential(profile: $0.profile, base: $0.base.merging(ceiling) { $1 }, token: $0.token)
            },
            networkTimeout: networkTimeout)
    }

    /// The submodule's repo when it has one: its worktree when checked out, else the git folder a deinit left in
    /// `modules/<name>` (which `submodule update` reuses with its config). Nil when it was never cloned.
    private func submoduleRepo(name: String, path: String) async throws -> URL? {
        let worktree = cwd.appending(path: path, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: worktree.appending(path: ".git").path) { return worktree }
        let folder = try Self.modulesFolder(name: name, gitDir: try await gitDir())
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) && isFolder.boolValue
            ? folder : nil
    }

    /// Whether this repo has `commit`, without a lazy fetch.
    private func hasCommit(_ commit: String) async -> Bool {
        let result = try? await exec(
            ["cat-file", "-e", "\(commit)^{commit}"], allowedExitCodes: [0, 1, 128],
            extraEnv: ["GIT_NO_LAZY_FETCH": "1"])
        return result?.exitCode == 0
    }

    /// The folder git keeps `modules` in (`rev-parse --git-path modules`, absolute).
    private func gitDir() async throws -> URL {
        let modules = try await exec(["rev-parse", "--path-format=absolute", "--git-path", "modules"]).text
            .trimmingCharacters(in: .newlines)
        return URL(filePath: modules, directoryHint: .isDirectory).deletingLastPathComponent()
    }

    /// `submodule.<name>.update` from the repo's config, else from `.gitmodules`; nil when neither sets it.
    private func updateMode(_ name: String) async throws -> String? {
        let key = "submodule.\(name).update"
        for source in [[], ["--no-includes", "--file", ".gitmodules"]] {
            let result = try await exec(["config"] + source + ["--get", key], allowedExitCodes: [0, 1])
            if result.exitCode == 0 { return result.text.trimmingCharacters(in: .newlines) }
        }
        return nil
    }

    /// The `.gitmodules` names by path (a path given twice is left out).
    private func submoduleNames() async throws -> [String: String] {
        guard Self.hasGitmodules(cwd) else { return [:] }
        let output = try await exec(
            ["config", "-z", "--no-includes", "--file", ".gitmodules", "--get-regexp", #"^submodule\..*\.path$"#],
            allowedExitCodes: [0, 1]).stdout
        var names: [String: [String]] = [:]
        // `<key>\n<value>\0` per entry.
        for record in output.split(separator: 0) {
            let parts = String(decoding: record, as: UTF8.self)
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            names[String(parts[1]), default: []].append(
                String(parts[0].dropFirst("submodule.".count).dropLast(".path".count)))
        }
        return names.compactMapValues { $0.count == 1 ? $0[0] : nil }
    }

    /// The submodules of this level: `.gitmodules` entries whose path has a gitlink at stage 0 in the index, in index
    /// order, with the recorded commit.
    private func submoduleEntries() async throws -> [(name: String, path: String, commit: String)] {
        let names = try await submoduleNames().filter { (try? Self.validateSubmodulePath($0.key)) != nil }
        guard !names.isEmpty else { return [] }
        let output = try await exec(["--literal-pathspecs", "ls-files", "-s", "-z", "--"] + names.keys.sorted())
        var entries: [(name: String, path: String, commit: String)] = []
        // `<mode> <sha> <stage>\t<path>` per entry.
        for record in output.stdout.split(separator: 0) {
            guard let tab = record.firstIndex(of: UInt8(ascii: "\t")) else { continue }
            let fields = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
            let path = String(decoding: record[record.index(after: tab)...], as: UTF8.self)
            // A conflicted gitlink (stages 1 to 3) is left out, as `discard` leaves it.
            guard fields.count == 3, fields[0] == "160000", fields[2] == "0", Self.isObjectID(String(fields[1])),
                  let name = names[path], !entries.contains(where: { $0.path == path })
            else { continue }
            entries.append((name, path, String(fields[1])))
        }
        return entries
    }

    /// `.gitmodules` at the worktree root, a regular file (not followed through a symlink).
    private static func hasGitmodules(_ cwd: URL) -> Bool {
        let path = cwd.appending(path: ".gitmodules").path
        return (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeRegular
    }

    /// One path's failure for `SubmoduleUpdateFailure`: git's own words when git failed.
    private static func message(_ error: any Error) -> String {
        switch error {
        case let error as GitError: error.stderrTail.isEmpty ? "git failed." : error.stderrTail
        case let error as NetworkTokenWithheld: message(error.error)
        case SubmoduleOperationError.invalidName(let name): "The submodule name \"\(name)\" is not safe to use."
        default: String(describing: error)
        }
    }
}
