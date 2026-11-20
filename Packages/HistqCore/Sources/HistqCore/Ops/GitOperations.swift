// Every user-initiated write of a repository: checkout, commit, stage, fetch,
// pull, push, branches, remotes, worktrees, merge/rebase/cherry-pick/revert/reset, stashes, tags, continue/abort/skip,
// clone and init. Each public operation (but `optimizeRepository`, which git locks itself) takes the runner's `mutate`
// lane exactly once (compound operations run their steps inside that one lane; never call another public operation or
// `PatchBuilder.apply` from inside it: a nested `mutate` deadlocks).
//
// Safety: a user string never becomes an option. Paths go after `--` with `--literal-pathspecs` (no
// pathspec magic), revisions after `--end-of-options`, messages through stdin or `--message=`, new
// branch/tag/remote names are checked (no leading `-`, `git check-ref-format`; remote names
// `[A-Za-z0-9._-]+`), push refspecs are full refs (`refs/heads/x`, so a name can never mean `+force`), and
// a stash is named by its commit hash (its `stash@{n}` is looked up inside the lane). Merge, pull and revert pass `--no-edit`; continue/abort/skip run
// with `-c core.editor=true`, so git never waits for an editor.
//
// Token: with a `credential`, each network operation asks `GitInvocation.networkToken` first (inside its lane, for
// the remotes it contacts) and gets the tokens of the hosts it reaches only when the gate lets it; see `networkExec`.
//
// Undo: with a `journal`, the operations the journal can take back (commit, amend, checkout, reset, merge, rebase,
// cherry-pick, revert, am, local branch create/delete/rename, discard) are snapshotted before and after inside their
// own lane, so no other write can slip in between; `undo()` and `redo()` move between those snapshots.
import Foundation
import Synchronization

public enum GitOperationError: Error, Equatable, Sendable {
    case invalidBranchName(String)
    case invalidTagName(String)
    case invalidRemoteName(String)
    case invalidRemoteURL(String)
    /// An expected object id (force-with-lease) that is not 4 to 64 hex digits.
    case invalidObjectID(String)
    /// A path operation got no paths (`clean --`/`reset --` without paths would touch everything).
    case noPaths
    /// A `fetchRefspec` refspec that is not `<remote ref>:<new local branch>` (a force `+`, an option, a pattern).
    case invalidRefspec(String)
    /// A stash hash `git stash list` no longer has (dropped or popped meanwhile).
    case stashNotFound(String)
    case invalidMainline(Int)
    /// `continue`/`abort`/`skip` asked with no operation in progress.
    case noOperationInProgress
    /// The operation has no such step (`git merge` has no `--skip`).
    case unsupported(String)
    /// A new worktree's folder that is relative, has `..`, control characters, a missing parent or already exists.
    case invalidWorktreePath(String)
    /// A path `git worktree list` does not have.
    case notAWorktree(String)
    /// The main worktree cannot be removed.
    case mainWorktree(String)
    /// The worktree the operations run in (removing it deletes the caller's folder).
    case currentWorktree(String)
    /// A rebase with stashed local changes was rolled back: a commit did not replay cleanly (`localChanges` false) or
    /// the changes did not apply cleanly to the rebased branch (true). `paths` are the conflicted files.
    case rebaseWouldConflict(paths: [String], localChanges: Bool)
}

/// A network command that failed to sign in after the token gate kept the GitHub token back for `reason`; `error` is
/// git's own failure.
public struct NetworkTokenWithheld: Error, Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// The repository's own config sets these network keys.
        case repoNetworkConfig(keys: [String])
        /// The repository has submodules and these recursion keys are on.
        case submoduleRecursion(keys: [String])
        /// A fetch of a remote whose URL is `https://<host>/…` for a host the profile has no account for.
        case noAccount(host: String)
        /// A fetch of the remote `name`, which a remote group of the same name (`remotes.<name>`) shadows.
        case remoteGroup(name: String)
    }

    public let reason: Reason
    public let error: GitError

    public init(reason: Reason, error: GitError) {
        self.reason = reason
        self.error = error
    }
}

/// A fetch of several remotes in which some failed (`fetchAll`): the others were still fetched. Each failure is git's
/// own (`GitError`), or `NetworkTokenWithheld` when its sign-in failed after the token was kept back.
public struct RemoteFetchFailure: Error, Sendable {
    public struct Failure: Sendable {
        public let remote: String
        public let error: any Error

        public init(remote: String, error: any Error) {
            self.remote = remote
            self.error = error
        }
    }

    public let failures: [Failure]

    public init(failures: [Failure]) {
        self.failures = failures
    }
}

public struct GitOperations: Sendable {
    public enum ResetMode: String, Sendable { case soft, mixed, hard }

    public enum PullMode: Sendable {
        /// Fast-forward when possible, else a merge commit (`--no-rebase --ff --no-edit`).
        case fastForward
        /// Refuse unless a fast-forward is possible (`--no-rebase --ff-only`).
        case fastForwardOnly
        /// `--rebase`.
        case rebase
    }

    public enum MergeMode: Sendable {
        /// Fast-forward when possible, else a merge commit (`--ff`).
        case fastForward
        /// Refuse unless a fast-forward is possible (`--ff-only`, `GitError.nonFastForward`).
        case fastForwardOnly
        /// Always a merge commit (`--no-ff`).
        case noFastForward
    }

    /// Per-commit signing on top of the profile's `commit.gpgSign` default.
    public enum CommitSigning: Sendable {
        case profileDefault, sign, noSign
    }

    /// The profile's account tokens and what the token gate needs to decide, command by command, which git gets.
    public struct NetworkCredential: Sendable {
        public var profile: Profile?
        public var base: [String: String]
        public var credentials: [GitCredential]

        public init(profile: Profile?, base: [String: String], credentials: [GitCredential]) {
            self.profile = profile
            self.base = base
            self.credentials = credentials
        }
    }

    public let runner: GitRunner
    /// The worktree the operations run in.
    public let cwd: URL
    /// The write environment (`GitInvocation.environment(profile:base:)`): identity, signing, ssh.
    public let env: [String: String]
    /// The environment of network operations (fetch, pull, push and their compound steps) that do not get the
    /// token. Defaults to `env`.
    public let networkEnv: [String: String]
    /// The tokens for network operations that pass the gate (`networkExec`); nil = never a token.
    public let credential: NetworkCredential?
    /// The time limit of one network command (git is stopped after it).
    public let networkTimeout: Duration
    /// When set, network commands stop at this instant instead (`withNetworkDeadline`).
    private var networkDeadline: ContinuousClock.Instant?
    /// Records the undoable operations of this worktree; nil = no undo.
    public let journal: UndoJournal?

    public init(
        runner: GitRunner, cwd: URL, env: [String: String], networkEnv: [String: String]? = nil,
        credential: NetworkCredential? = nil, networkTimeout: Duration = .seconds(600), journal: UndoJournal? = nil
    ) {
        self.runner = runner
        self.cwd = cwd
        self.env = env
        self.networkEnv = networkEnv ?? env
        self.credential = credential
        self.networkTimeout = networkTimeout
        self.journal = journal
    }

    /// The usual setup for `profile`: `env` (and `networkEnv`) is its write environment, and each of `credentials`
    /// goes only to the network operations the gate lets have it.
    public init(
        runner: GitRunner, cwd: URL, profile: Profile?, base: [String: String], credentials: [GitCredential] = [],
        networkTimeout: Duration = .seconds(600), journal: UndoJournal? = nil
    ) {
        self.init(
            runner: runner, cwd: cwd, env: GitInvocation.environment(profile: profile, base: base, access: .write),
            credential: credentials.isEmpty
                ? nil : NetworkCredential(profile: profile, base: base, credentials: credentials),
            networkTimeout: networkTimeout, journal: journal)
    }

    // MARK: - Checkout

    /// Switches to the local branch `name`. `autostash`: the local changes are stashed first and put back on the
    /// branch (see `restoreAutostash`); throws `GitError.autostashKept` when they stay in the stash.
    public func checkout(branch name: String, autostash: Bool = false) async throws {
        try await journaled(
            .checkout, "Checkout \(name)", mode: .carry, before: autostash ? Self.saveAutostash : nil,
            after: autostash ? Self.restoreAutostash : nil
        ) { ops in
            try await ops.exec(["checkout", "--end-of-options", name, "--"])
        }
    }

    /// Creates the local branch `localName` tracking `remoteBranch` (e.g. `origin/feature`) and switches to it.
    /// `autostash` as for `checkout(branch:autostash:)`.
    public func checkoutTracking(remoteBranch: String, as localName: String, autostash: Bool = false) async throws {
        try await validateBranchName(localName)
        try await journaled(
            .checkout, "Checkout \(localName)", mode: .carry, refs: ["refs/heads/\(localName)"],
            before: autostash ? Self.saveAutostash : nil,
            after: autostash ? Self.restoreAutostash : nil
        ) { ops in
            try await ops.exec(["checkout", "--track", "-b", localName, "--end-of-options", remoteBranch, "--"])
        }
    }

    /// Detaches HEAD at `revision`.
    public func checkout(commit revision: String) async throws {
        try await journaled(.checkout, "Checkout \(Self.shortRevision(revision))", mode: .carry) { ops in
            try await ops.exec(["checkout", "--detach", "--end-of-options", revision, "--"])
        }
    }

    /// Replaces `paths` in the index and working tree with their content at `revision`.
    public func checkoutFiles(_ paths: [String], from revision: String) async throws {
        try requirePaths(paths)
        try await write(["--literal-pathspecs", "checkout", "--end-of-options", revision, "--"] + paths)
    }

    // MARK: - Commit

    /// Commits the index with `message` (passed on stdin, kept as written).
    public func commit(message: String, signing: CommitSigning = .profileDefault) async throws {
        try await journaled(.commit, "Commit \"\(Self.subject(message))\"", mode: .index, completesOperation: true) { ops in
            try await ops.exec(["commit", "--file=-"] + Self.signingFlags(signing), stdin: Data(message.utf8))
        }
    }

    /// Amends HEAD with the index; `message` nil keeps the current message.
    public func amend(message: String?, signing: CommitSigning = .profileDefault) async throws {
        let flags = ["commit", "--amend"] + Self.signingFlags(signing)
        try await journaled(.amend, "Amend last commit", mode: .index) { ops in
            if let message {
                try await ops.exec(flags + ["--file=-"], stdin: Data(message.utf8))
            } else {
                try await ops.exec(flags + ["--no-edit"])
            }
        }
    }

    /// Replaces the message of `commit`, which must still be HEAD (else git refuses), keeping its tree, parents and
    /// author. Only the message changes: the index and working tree are left as they are. Git hooks do not run.
    /// `commit-tree` ignores `commit.gpgSign`, so with `.profileDefault` it is read here (the profile's config
    /// included) and the new commit is signed when it is true.
    public func editHeadMessage(_ commit: String, message: String, signing: CommitSigning = .profileDefault) async throws {
        guard Self.isObjectID(commit) else { throw GitOperationError.invalidObjectID(commit) }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitOperationError.unsupported("an empty commit message")
        }
        let text = message.hasSuffix("\n") ? message : message + "\n"
        try await journaled(.amend, "Edit message of \"\(Self.subject(message))\"", mode: .index) { ops in
            let info = try await ops.exec(
                ["log", "-1", "--no-show-signature", "--format=%P%x00%an%x00%ae%x00%ad", "--date=raw",
                 "--end-of-options", commit, "--"]
            ).text.trimmingCharacters(in: .newlines)
            let fields = info.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4 else { throw GitOperationError.invalidObjectID(commit) }
            let parents = fields[0].split(separator: " ").flatMap { ["-p", String($0)] }
            let author = ["GIT_AUTHOR_NAME": fields[1], "GIT_AUTHOR_EMAIL": fields[2], "GIT_AUTHOR_DATE": "@" + fields[3]]
            var signFlags = Self.signingFlags(signing)
            if case .profileDefault = signing {
                let gpgSign = try await ops.exec(
                    ["config", "--type=bool", "--get", "commit.gpgSign"], allowedExitCodes: [0, 1]
                ).text.trimmingCharacters(in: .whitespacesAndNewlines)
                if gpgSign == "true" { signFlags = ["--gpg-sign"] }
            }
            let new = try await ops.exec(
                ["commit-tree"] + signFlags + parents + ["-F", "-", "\(commit)^{tree}"],
                stdin: Data(text.utf8), extraEnv: author
            ).text.trimmingCharacters(in: .whitespacesAndNewlines)
            try await ops.exec(["update-ref", "-m", "commit (amend): \(Self.subject(message))", "HEAD", new, commit])
        }
    }

    // MARK: - Stage, unstage, discard

    /// Stages `paths` (new, modified and deleted files). Undo puts the index back as it was.
    public func stage(_ paths: [String]) async throws {
        try requirePaths(paths)
        try await journaled(.stage, "Stage changes", mode: .index) { ops in
            try await ops.exec(["--literal-pathspecs", "add", "-A", "--"] + paths)
        }
    }

    public func stageAll() async throws {
        try await journaled(.stage, "Stage all changes", mode: .index) { ops in
            try await ops.exec(["add", "-A"])
        }
    }

    /// Resets the index entries of `paths` to HEAD (works on an unborn branch too).
    public func unstage(_ paths: [String]) async throws {
        try requirePaths(paths)
        try await journaled(.unstage, "Unstage changes", mode: .index) { ops in
            try await ops.exec(["--literal-pathspecs", "reset", "-q", "--"] + paths)
        }
    }

    public func unstageAll() async throws {
        try await journaled(.unstage, "Unstage all changes", mode: .index) { ops in
            try await ops.exec(["reset", "-q"])
        }
    }

    /// Discards the unstaged changes of tracked `paths` (the working tree takes the index version). A gitlink (a moved
    /// submodule) goes back to its recorded commit by a submodule update in the same lane, after the files' journaled
    /// restore and not journaled (the journal skips gitlinks), whatever its configured update mode; one that is not
    /// checked out is left alone. Throws `SubmoduleUpdateFailure` when a submodule failed to update or, not
    /// initialized, stays away from its recorded commit.
    public func discard(_ paths: [String]) async throws {
        try requirePaths(paths)
        let links = try await gitlinks(among: paths)
        let files = paths.filter { !links.all.contains($0) }
        guard !files.isEmpty else {
            guard !links.checkedOut.isEmpty else { return }
            try await lane { ops in try await ops.updateGitlinks(links.checkedOut) }
            return
        }
        let content = UndoJournal.ContentScope(paths: files, untrackedPaths: nil)
        // In `after`: it runs once the files' entry is recorded, so a failed submodule update keeps that entry.
        try await journaled(
            .discard, "Discard changes", mode: .discard, content: content,
            after: { ops, _, error in
                if error == nil, !links.checkedOut.isEmpty { try await ops.updateGitlinks(links.checkedOut) }
            }
        ) { ops in
            try await ops.exec(["--literal-pathspecs", "restore", "--worktree", "--"] + files)
        }
    }

    /// Deletes the untracked files or folders `paths`.
    public func removeUntracked(_ paths: [String]) async throws {
        try requirePaths(paths)
        let content = UndoJournal.ContentScope(paths: [], untrackedPaths: paths)
        try await journaled(.discard, "Delete untracked files", mode: .discard, content: content) { ops in
            try await ops.exec(["--literal-pathspecs", "clean", "-f", "-d", "-q", "--"] + paths)
        }
    }

    /// "Discard all unstaged": `restore .` (staged changes and untracked files stay). A moved submodule stays on its
    /// commit (unless the user's config sets `submodule.recurse`).
    public func discardAllUnstaged() async throws {
        let content = UndoJournal.ContentScope(paths: ["."], untrackedPaths: nil)
        try await journaled(.discard, "Discard all unstaged changes", mode: .discard, content: content) { ops in
            try await ops.exec(["restore", "--worktree", "--", "."])
        }
    }

    /// "Discard all": `reset --hard` (index and tracked files back to HEAD), plus `clean -fd` when
    /// `includingUntracked`. The caller confirms first. A moved submodule stays on its commit (unless the user's config
    /// sets `submodule.recurse`).
    public func discardAll(includingUntracked: Bool) async throws {
        // `reset --hard` covers the whole worktree, `clean` (no pathspec) only the folder of `cwd`.
        let content = UndoJournal.ContentScope(
            paths: ["."], untrackedPaths: includingUntracked ? ["."] : nil, wholeWorktree: true)
        try await journaled(.discard, "Discard all changes", mode: .discard, content: content) { ops in
            try await ops.exec(["reset", "-q", "--hard"])
            if includingUntracked { try await ops.exec(["clean", "-f", "-d", "-q"]) }
        }
    }

    // MARK: - Fetch, pull, push

    /// Fetches every remote `fetch --all` goes through (`fetchAllRemotes`), one `fetch [--prune] <remote>` each in
    /// `git remote` order, so the gate decides for each remote on its own: a remote on an account's host gets that
    /// host's token, any other runs with the user's own helpers. A remote that fails does not stop the others; then the
    /// repo's one remote throws its error as is, several throw `RemoteFetchFailure` naming each failed remote. All the
    /// remotes share one `networkTimeout`, as the single `fetch --all` did: each git fetch gets the time left once its
    /// remote passed the gate, and a remote reached after it fails with `GitError.timeout`. A remote named like a remote
    /// group (`remotes.<name>`) runs without the token, as git runs it (the group's members). Git failing to list the
    /// remotes falls back to one `fetch --all` without the token.
    public func fetchAll(prune: Bool = true) async throws {
        try await lane { ops in
            let deadline = ContinuousClock.now + ops.networkTimeout
            guard let remotes = try? await Self.fetchAllRemotes(runner: ops.runner, cwd: ops.cwd, env: ops.env) else {
                try await ops.networkExec(["fetch", "--all"] + (prune ? ["--prune"] : []), target: nil)
                return
            }
            var failures: [RemoteFetchFailure.Failure] = []
            for remote in remotes {
                guard deadline - .now > .zero else {
                    failures.append(.init(remote: remote, error: GitError.timeout))
                    continue
                }
                do {
                    try await ops.withNetworkDeadline(deadline).fetchRemote(remote, prune: prune)
                } catch let error as GitError {
                    failures.append(.init(remote: remote, error: error))
                } catch let error as NetworkTokenWithheld {
                    failures.append(.init(remote: remote, error: error))
                }
            }
            guard let first = failures.first else { return }
            if remotes.count == 1 { throw first.error }
            throw RemoteFetchFailure(failures: failures)
        }
    }

    /// Fetches the existing remote `remote` alone (`fetch [--prune] <remote>`), through the gate like every network
    /// command. The name must be one `git remote` lists (`team/fork` too) and not start with `-`, else
    /// `GitOperationError.invalidRemoteName`.
    public func fetch(remote: String, prune: Bool = true) async throws {
        let remotes = try await GitInvocation.remoteNames(runner: runner, cwd: cwd, env: env)
        guard !remote.hasPrefix("-"), remotes.contains(remote) else {
            throw GitOperationError.invalidRemoteName(remote)
        }
        try await lane { ops in try await ops.fetchRemote(remote, prune: prune) }
    }

    /// A fetch nobody clicked (auto-fetch) of every remote `fetch --all` goes through (`fetchAllRemotes`), one
    /// `fetch [--prune] <remote>` each in the runner's write lane, with the background fetch environment and `profile`
    /// (a fetch is network: its SSH key). The repo may be downloaded, so its config, hooks and credential helpers run
    /// nothing (see `GitInvocation.Access.backgroundFetch`) and no gc or maintenance runs after it. The gate decides for
    /// each remote on its own: a remote on the host of one of `credentials` gets that host's token, any other the
    /// user's own helpers. A remote that fails does not stop the others; then `RemoteFetchFailure` names each failed
    /// remote with git's error, even in a repo with one remote. Listing the user's credential helpers, the remotes or
    /// the remote groups throws before anything runs, and so does a repo with its own network config
    /// (`GitInvocation.BackgroundFetchError.repoSetsNetworkConfig`, see `GitInvocation.credentialHelpers`): it is not
    /// fetched until the user asks. A remote named like a remote group of any config scope (`remotes.<name>`) is left
    /// out without a failure, since `git fetch <name>` would fetch the group's members, URLs nobody checked; a click
    /// on Fetch still fetches it. `timeout` bounds all the remotes together, from the moment the lane is free, so a
    /// fetch never holds the lane long: each git fetch gets the time left once its remote passed the gate, and a
    /// remote reached after it fails with `GitError.timeout`.
    public static func backgroundFetchAll(
        prune: Bool, profile: Profile?, base: [String: String], runner: GitRunner, cwd: URL,
        credentials: [GitCredential] = [], timeout: Duration = .seconds(120)
    ) async throws {
        // A read environment, so a token helper is never listed and replayed as one of the user's helpers.
        let listingEnv = GitInvocation.environment(profile: nil, base: base, access: .read(filterDrivers: []))
        let helpers = try await GitInvocation.credentialHelpers(runner: runner, cwd: cwd, env: listingEnv)
        let groups = try await GitInvocation.remoteGroups(runner: runner, cwd: cwd, env: listingEnv)
        let remotes = try await fetchAllRemotes(runner: runner, cwd: cwd, env: listingEnv).filter { !groups.contains($0) }
        try await runner.mutate {
            let deadline = ContinuousClock.now + timeout
            var failures: [RemoteFetchFailure.Failure] = []
            for remote in remotes {
                guard deadline - .now > .zero else {
                    failures.append(.init(remote: remote, error: GitError.timeout))
                    continue
                }
                var matched: [GitCredential] = []
                if !credentials.isEmpty, case .attach(let gated) = await GitInvocation.networkToken(
                    for: .fetch(remotes: [remote]), credentials: credentials, base: base, runner: runner, cwd: cwd)
                {
                    matched = gated
                }
                let environment = GitInvocation.environment(
                    profile: profile, base: base, access: .backgroundFetch(credentialHelpers: helpers),
                    credentials: matched)
                let args = ["fetch"] + (prune ? ["--prune"] : []) + ["--end-of-options", remote]
                // Measured after the gate, so the remotes together stay within `timeout`.
                let remaining = deadline - .now
                guard remaining > .zero else {
                    failures.append(.init(remote: remote, error: GitError.timeout))
                    continue
                }
                do {
                    _ = try await runner.run(args, cwd: cwd, env: environment, timeout: remaining)
                } catch let error as GitError {
                    failures.append(.init(remote: remote, error: error))
                }
            }
            if !failures.isEmpty { throw RemoteFetchFailure(failures: failures) }
        }
    }

    /// The remotes `git fetch --all` goes through: `git remote`, but those whose `remote.<name>.skipFetchAll` (or its
    /// older name `skipDefaultUpdate`) is true.
    public static func fetchAllRemotes(runner: GitRunner, cwd: URL, env: [String: String]) async throws -> [String] {
        let remotes = try await GitInvocation.remoteNames(runner: runner, cwd: cwd, env: env)
        let result = try await runner.run(
            ["config", "-z", "--type=bool", "--get-regexp", #"^remote\..*\.(skipfetchall|skipdefaultupdate)$"#],
            cwd: cwd, env: env, timeout: .seconds(10), allowedExitCodes: [0, 1])
        var skipped: [String: Bool] = [:]
        // `remote.<name>.<key>\n<true|false>\0` per entry, in git's order: the last one wins.
        for entry in result.stdout.split(separator: 0) {
            let parts = String(decoding: entry, as: UTF8.self).split(separator: "\n", maxSplits: 1)
            guard parts.count == 2, let dot = parts[0].lastIndex(of: ".") else { continue }
            let name = parts[0][parts[0].index(parts[0].startIndex, offsetBy: "remote.".count)..<dot]
            skipped[String(name)] = parts[1] == "true"
        }
        return remotes.filter { skipped[$0] != true }
    }

    /// Fetches one ref of `remote` into a local branch, never forced: `refspec` is `<ref>:<branch>`, e.g.
    /// `pull/12/head:pr/12` (a GitHub pull request's head). The ref is taken under `refs/` (`refs/pull/12/head`) and
    /// the branch under `refs/heads/`, both must pass `git check-ref-format`, neither may start with `-` or `+`, and the
    /// remote must be a remote name (not a URL or an option). An existing branch is only fast-forwarded (git refuses
    /// anything else, and a branch checked out anywhere). The token goes through the gate like every network command.
    public func fetchRefspec(remote: String, refspec: String) async throws {
        let parts = refspec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let source = parts.first, let branch = parts.last,
              !source.hasPrefix("-"), !source.hasPrefix("+"), !branch.hasPrefix("+"),
              !refspec.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) })
        else { throw GitOperationError.invalidRefspec(refspec) }
        let sourceRef = source.hasPrefix("refs/") ? source : "refs/\(source)"
        guard !source.isEmpty, await checkRefFormat(sourceRef) else { throw GitOperationError.invalidRefspec(refspec) }
        try await validateRemoteName(remote)
        try await validateBranchName(branch)
        try await lane { ops in
            try await ops.networkExec(
                ["fetch", "--end-of-options", remote, "\(sourceRef):refs/heads/\(branch)"],
                target: .fetch(remotes: [remote]))
        }
    }

    /// Pulls the current branch's upstream. With the token, it is split so that only the fetch carries it: a
    /// hardened `fetch <remote>` (which marks the upstream for merge in FETCH_HEAD, as `pull` does), then, with the
    /// write environment and the repo's hooks as usual, `merge FETCH_HEAD` with the mode's flags (pull's own merge
    /// message), or for a rebase what `pull --rebase` runs: `rebase --onto <fetched> <fork point>`, the fetched
    /// commit being FETCH_HEAD's for-merge one (not `@{upstream}`, which a refspec may not map, as for a
    /// `refs/pull/<n>/head` checkout, or may leave stale) and the fork point `merge-base --fork-point @{upstream}
    /// HEAD` taken before the fetch, else the fetched commit itself. Without the token (an upstream on another
    /// host, a local one, none at all) it is one `git pull`, as before.
    ///
    /// `autostash` adds `--autostash` (git stashes the local changes and puts them back after). git exits 0 even when
    /// putting them back conflicts and keeps them in `refs/stash`: a new stash top throws `GitError.autostashKept`.
    /// A merge or rebase that stops on conflicts keeps them in `MERGE_AUTOSTASH` / `rebase-*/autostash` instead and
    /// puts them back on continue or abort: that returns `.autostashPending` (the conflict is not thrown).
    @discardableResult
    public func pull(_ mode: PullMode, autostash: Bool = false) async throws -> PullOutcome {
        let flags: [String] = switch mode {
        case .fastForward: ["--no-rebase", "--ff", "--no-edit"]
        case .fastForwardOnly: ["--no-rebase", "--ff-only"]
        case .rebase: ["--rebase"]
        }
        let auto = autostash ? ["--autostash"] : []
        return try await lane { ops in
            let top = autostash ? try await ops.stashTop() : nil
            // One already there belongs to an earlier stopped pull: this one's failure is its own.
            let pending = autostash ? await ops.autostashPending() : false
            do {
                let remote = ops.credential == nil ? nil : try? await ops.upstreamRemote()
                let decision = await ops.tokenDecision(for: remote.map { .fetch(remotes: [$0]) })
                if case .attach(let matched) = decision, let remote, let credential = ops.credential {
                    // As `pull`, before the fetch moves the tracking ref; nil without one or without a fork point.
                    let forkPoint = mode == .rebase ? await ops.forkPoint() : nil
                    try await ops.exec(
                        ["fetch", "--end-of-options", remote], network: true,
                        environment: ops.tokenEnvironment(.fetch, credential, matched))
                    let candidates = try await ops.mergeCandidates()
                    switch mode {
                    case .fastForward: try await ops.exec(["merge"] + auto + ["--ff", "--no-edit", "FETCH_HEAD"])
                    case .fastForwardOnly: try await ops.exec(["merge"] + auto + ["--ff-only", "FETCH_HEAD"])
                    case .rebase:
                        guard candidates.count == 1, let fetched = candidates.first else {
                            throw GitError.other(exit: 1, stderrTail: "Cannot rebase onto multiple branches.")
                        }
                        try await ops.exec(["rebase"] + auto + ["--onto", fetched, forkPoint ?? fetched])
                    }
                } else {
                    try await ops.withheldExec(decision) { try await ops.exec(["pull"] + flags + auto, network: true) }
                }
            } catch {
                guard autostash else { throw error }
                if let now = try await ops.stashTop(), now != top { throw GitError.autostashKept(now) }
                guard !pending, await ops.autostashPending() else { throw error }
                return .autostashPending
            }
            if autostash, let now = try await ops.stashTop(), now != top { throw GitError.autostashKept(now) }
            return .done
        }
    }

    /// What `pull` did with an auto-stash that did not simply come back.
    public enum PullOutcome: Sendable, Equatable {
        /// Pulled; the local changes (if any were stashed) are back.
        case done
        /// The merge or rebase stopped on conflicts; git holds the local changes until it is continued or aborted.
        case autostashPending
    }

    /// The object ids the fetch marked for merge in FETCH_HEAD. Fails as `git pull` does when there is none (the
    /// upstream branch was deleted on the remote, or no `branch.<name>.merge`).
    private func mergeCandidates() async throws -> [String] {
        let path = try await runner.run(
            ["rev-parse", "--path-format=absolute", "--git-path", "FETCH_HEAD"], cwd: cwd, env: env).text
        let fetchHead = (try? String(contentsOfFile: path.trimmingCharacters(in: .newlines), encoding: .utf8)) ?? ""
        // `<oid>\t<empty or not-for-merge>\t<description>` per line.
        let candidates = fetchHead.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2, fields[1].isEmpty, Self.isObjectID(String(fields[0])) else { return nil }
            return String(fields[0])
        }
        guard candidates.isEmpty else { return candidates }
        throw GitError.other(
            exit: 1, stderrTail: "Your configuration specifies a branch to merge from the remote, but no such ref "
                + "was fetched.")
    }

    /// `merge-base --fork-point @{upstream} HEAD`, as `pull --rebase` computes it; nil when the upstream is not a
    /// tracking ref (git cannot resolve `@{upstream}`) or has no fork point, and `pull` then rebases from the fetched
    /// commit too.
    private func forkPoint() async -> String? {
        let result = try? await runner.run(
            ["merge-base", "--fork-point", "@{upstream}", "HEAD"], cwd: cwd, env: env, allowedExitCodes: [0, 1, 128])
        let text = result?.exitCode == 0 ? result?.text.trimmingCharacters(in: .newlines) : nil
        return text.flatMap { Self.isObjectID($0) ? $0 : nil }
    }

    /// The remote `pull` fetches from: `branch.<current branch>.remote`. Throws on a detached HEAD or without one.
    private func upstreamRemote() async throws -> String {
        let branch = try await runner.run(["symbolic-ref", "--short", "-q", "HEAD"], cwd: cwd, env: env).text
            .trimmingCharacters(in: .newlines)
        return try await runner.run(["config", "--get", "branch.\(branch).remote"], cwd: cwd, env: env).text
            .trimmingCharacters(in: .newlines)
    }

    /// Pushes the local `branch` to `remoteBranch` (default: the same name) on `remote`. `setUpstream`
    /// adds `-u`. `forceWithLease` is the sha the remote branch must still have
    /// (`--force-with-lease=refs/heads/<remoteBranch>:<sha>`); otherwise the push is refused
    /// (`GitError.nonFastForward`).
    public func push(
        branch: String, to remote: String, as remoteBranch: String? = nil, setUpstream: Bool = false,
        forceWithLease expected: String? = nil
    ) async throws {
        let target = "refs/heads/" + (remoteBranch ?? branch)
        var args = ["push"]
        if setUpstream { args.append("-u") }
        if let expected {
            guard Self.isObjectID(expected) else { throw GitOperationError.invalidObjectID(expected) }
            args.append("--force-with-lease=\(target):\(expected)")
        }
        try await push(args + ["--end-of-options", remote, "refs/heads/\(branch):\(target)"], to: remote)
    }

    /// Mirrors every ref to `remote` (`push --mirror`: deletes remote refs missing here). The caller confirms.
    public func pushMirror(to remote: String) async throws {
        try await push(["push", "--mirror", "--end-of-options", remote], to: remote)
    }

    /// One push to `remote` in the lane, through the token gate.
    private func push(_ args: [String], to remote: String) async throws {
        try await lane { ops in try await ops.networkExec(args, target: .push(remote: remote)) }
    }

    // MARK: - Branches

    /// Creates `name` at `revision` (a commit or branch); `checkout` also switches to it.
    public func createBranch(_ name: String, from revision: String, checkout: Bool = false) async throws {
        try await validateBranchName(name)
        try await journaled(
            .createBranch, "Create branch \(name)", mode: checkout ? .carry : .index, refs: ["refs/heads/\(name)"]
        ) { ops in
            if checkout {
                try await ops.exec(["checkout", "-b", name, "--end-of-options", revision, "--"])
            } else {
                try await ops.exec(["branch", "--end-of-options", name, revision])
            }
        }
    }

    public func renameBranch(_ name: String, to newName: String) async throws {
        try await validateBranchName(newName)
        try await journaled(
            .renameBranch, "Rename branch \(name) to \(newName)", mode: .index,
            refs: ["refs/heads/\(name)", "refs/heads/\(newName)"]
        ) { ops in
            try await ops.exec(["branch", "-m", "--end-of-options", name, newName])
        }
    }

    /// `-d` (refuses an unmerged branch) or `-D` with `force`.
    public func deleteBranch(_ name: String, force: Bool = false) async throws {
        try await journaled(.deleteBranch, "Delete branch \(name)", mode: .index, refs: ["refs/heads/\(name)"]) { ops in
            try await ops.exec(["branch", force ? "-D" : "-d", "--end-of-options", name])
        }
    }

    /// Renames a branch on `remote`: pushes `<remote>/<name>` as `newName`, then deletes `name` there.
    public func renameRemoteBranch(_ name: String, to newName: String, on remote: String) async throws {
        try await validateBranchName(newName)
        try await lane { ops in
            try await ops.networkExec(
                ["push", "--end-of-options", remote, "refs/remotes/\(remote)/\(name):refs/heads/\(newName)"],
                target: .push(remote: remote))
            try await ops.networkExec(
                ["push", "--end-of-options", remote, ":refs/heads/\(name)"], target: .push(remote: remote))
        }
    }

    public func deleteRemoteBranch(_ name: String, on remote: String) async throws {
        try await push(["push", "--end-of-options", remote, ":refs/heads/\(name)"], to: remote)
    }

    /// Sets the upstream of `branch` to `upstream` (e.g. `origin/main`).
    public func setUpstream(of branch: String, to upstream: String) async throws {
        try await write(["branch", "--set-upstream-to=\(upstream)", "--end-of-options", branch])
    }

    // MARK: - Remotes

    public func addRemote(_ name: String, url: String) async throws {
        try await validateRemoteName(name)
        try Self.validateRemoteURL(url)
        try await write(["remote", "add", "--end-of-options", name, url])
    }

    public func removeRemote(_ name: String) async throws {
        try await write(["remote", "remove", "--end-of-options", name])
    }

    public func renameRemote(_ name: String, to newName: String) async throws {
        try await validateRemoteName(newName)
        try await write(["remote", "rename", "--end-of-options", name, newName])
    }

    public func setRemoteURL(_ name: String, url: String) async throws {
        try Self.validateRemoteURL(url)
        try await write(["remote", "set-url", "--end-of-options", name, url])
    }

    // MARK: - Worktrees

    /// What a new worktree checks out.
    public enum WorktreeSource: Sendable, Equatable {
        /// An existing local branch by its short name (`develop`); git refuses one checked out elsewhere.
        case branch(String)
        /// A commit by its full or abbreviated object id (resolve a name with `rev-parse` first): detached, or the
        /// start of a new branch.
        case commit(String)
    }

    /// Adds a worktree at `path` (absolute; its parent must exist and it must not) checking out `source`, or a new
    /// branch `newBranch` started there. Not journaled: undo never touches another worktree's files.
    public func addWorktree(at path: String, from source: WorktreeSource, newBranch: String? = nil) async throws {
        if let newBranch { try await validateBranchName(newBranch) }
        if case .branch(let name) = source {
            // A short name: `refs/heads/x` would be taken as a commit and detach. Checked as a ref that exists, so a
            // name git would DWIM into a remote-tracking branch or a commit never gets that far.
            guard Self.isSafeName(name), await checkRefFormat("refs/heads/\(name)") else {
                throw GitOperationError.invalidBranchName(name)
            }
        }
        let args = try Self.addWorktreeArguments(path: path, source: source, newBranch: newBranch)
        try await lane { ops in
            if case .branch(let name) = source {
                let exists = try await ops.exec(
                    ["show-ref", "--verify", "--quiet", "refs/heads/\(name)"], allowedExitCodes: [0, 1])
                guard exists.exitCode == 0 else { throw GitOperationError.invalidBranchName(name) }
            }
            try await ops.exec(args)
        }
    }

    /// `worktree add [-b <new> | --detach] --end-of-options <path> <commit-ish>`: the path and the revision can never
    /// be read as options. Throws for a bad path, a commit that is not an object id, or a new branch name with a
    /// leading `-` (`addWorktree` also checks it with `check-ref-format`).
    public static func addWorktreeArguments(path: String, source: WorktreeSource, newBranch: String?) throws
        -> [String]
    {
        try validateWorktreePath(path)
        var args = ["worktree", "add"]
        if let newBranch {
            guard isSafeName(newBranch) else { throw GitOperationError.invalidBranchName(newBranch) }
            args += ["-b", newBranch]
        }
        let revision: String
        switch source {
        case .branch(let name):
            guard isSafeName(name) else { throw GitOperationError.invalidBranchName(name) }
            revision = name
        case .commit(let id):
            guard isObjectID(id) else { throw GitOperationError.invalidObjectID(id) }
            if newBranch == nil { args.append("--detach") }
            revision = id
        }
        return args + ["--end-of-options", path, revision]
    }

    /// A new worktree's folder: absolute, not `/`, no control characters, no `.`/`..` component, its parent an
    /// existing folder and itself not there yet.
    public static func validateWorktreePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard path.hasPrefix("/"), path.count > 1, !path.hasSuffix("/"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { throw GitOperationError.invalidWorktreePath(path) }
        var isFolder: ObjCBool = false
        let parent = (path as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: parent, isDirectory: &isFolder), isFolder.boolValue,
              (try? FileManager.default.attributesOfItem(atPath: path)) == nil
        else { throw GitOperationError.invalidWorktreePath(path) }
    }

    /// Removes the linked worktree `path` (as `git worktree list` gives it) and its folder. Refuses the main worktree
    /// and the one these operations run in (git would delete the folder under the caller), and any path the list,
    /// read in the same lane, does not have. Git refuses a worktree with changes or untracked files unless `force`;
    /// pass it only after the user chose to lose them.
    public func removeWorktree(_ path: String, force: Bool = false) async throws {
        try await lane { ops in
            let listed = try await ops.exec(StashWorktreeReader.worktreeArguments).stdout
            guard let worktree = StashWorktreeReader.parseWorktrees(listed).first(where: { $0.path == path }) else {
                throw GitOperationError.notAWorktree(path)
            }
            guard !worktree.isMain else { throw GitOperationError.mainWorktree(path) }
            let target = URL(filePath: path).resolvingSymlinksInPath().path
            let here = ops.cwd.resolvingSymlinksInPath().path
            guard here != target, !here.hasPrefix(target.hasSuffix("/") ? target : target + "/") else {
                throw GitOperationError.currentWorktree(path)
            }
            try await ops.exec(Self.removeWorktreeArguments(path: path, force: force))
        }
    }

    /// `worktree remove [--force] --end-of-options <path>`.
    public static func removeWorktreeArguments(path: String, force: Bool) -> [String] {
        ["worktree", "remove"] + (force ? ["--force"] : []) + ["--end-of-options", path]
    }

    /// Drops the records of worktrees whose folder is gone (`git worktree prune`).
    public func pruneWorktrees() async throws {
        try await write(["worktree", "prune"])
    }

    // MARK: - Maintenance

    /// Writes the commit-graph (with changed-path Bloom filters) so the log and the graph read faster in big repos.
    /// No timeout (a local write has none; a huge repo takes minutes) and not journaled: it changes no ref, index or
    /// working tree. Outside the lane, so the writes started meanwhile don't wait minutes behind it: git takes its own
    /// `commit-graph-chain.lock` (as `git maintenance` does when it runs the same write beside other commands).
    public func optimizeRepository() async throws {
        try await exec(["commit-graph", "write", "--reachable", "--split", "--changed-paths"])
    }

    // MARK: - Ignore

    /// Where `ignore(pattern:in:)` adds its line.
    public enum IgnoreFile: Sendable {
        /// The `.gitignore` at the worktree's top level (committed, shared).
        case gitignore
        /// `info/exclude` in the git dir (`rev-parse --git-path`; a linked worktree uses the main repo's): this clone only.
        case infoExclude
    }

    /// Appends `pattern` as one line to `file`, in one lane. The existing bytes stay as they are (a missing final
    /// newline is added first); the result is written to a temp file and renamed, keeping the file's mode. A
    /// symlinked file or `info` folder throws `UndoError.unsafePath` (a missing `info` folder is made); an empty
    /// pattern or one with a line break throws `GitOperationError.unsupported`. Not journaled: undo covers refs, the
    /// index and HEAD, not this file.
    public func ignore(pattern: String, in file: IgnoreFile) async throws {
        guard !pattern.isEmpty, !pattern.contains(where: \.isNewline) else {
            throw GitOperationError.unsupported("an ignore pattern that is empty or has a line break")
        }
        try await lane { ops in
            let args = switch file {
            case .gitignore: ["rev-parse", "--show-toplevel"]
            // Not `--path-format=absolute`: it resolves a symlinked `info` folder, which must be refused instead.
            case .infoExclude: ["rev-parse", "--git-path", "info/exclude"]
            }
            let text = try await ops.exec(args).text
            let path = text.hasSuffix("\n") ? String(text.dropLast()) : text
            let target = switch file {
            case .gitignore: URL(filePath: path, directoryHint: .isDirectory).appending(path: ".gitignore")
            case .infoExclude:
                // Relative to cwd as a folder (a cwd URL without a trailing slash would resolve against its parent).
                URL(filePath: path, relativeTo: URL(filePath: ops.cwd.path, directoryHint: .isDirectory)).absoluteURL
            }
            try Self.appendLine(Data((pattern + "\n").utf8), to: target)
        }
    }

    /// Appends `line` to `file` (atomic write, mode kept): refuses a symlinked file or parent folder, makes a missing
    /// parent folder, adds a final newline to content that lacks one.
    private static func appendLine(_ line: Data, to file: URL) throws {
        var info = stat()
        let folder = file.deletingLastPathComponent().path
        if lstat(folder, &info) != 0 {
            guard errno == ENOENT, mkdir(folder, 0o755) == 0 else { throw UndoError.unsafePath(file.path) }
        } else if info.st_mode & S_IFMT != S_IFDIR {
            throw UndoError.unsafePath(file.path)
        }
        var content = Data()
        var mode: mode_t?
        if lstat(file.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else { throw UndoError.unsafePath(file.path) }
            content = try Data(contentsOf: file)
            mode = info.st_mode & 0o7777
        } else if errno != ENOENT {
            throw UndoError.unsafePath(file.path)
        }
        if let last = content.last, last != UInt8(ascii: "\n") { content.append(UInt8(ascii: "\n")) }
        content.append(line)
        try content.write(to: file, options: .atomic)
        if let mode { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path) }
    }

    /// The ignore line for one file, anchored at the top level: `/<path>` (`path` relative to the worktree's top
    /// level, as `git status` gives it).
    public static func ignorePattern(file path: String) -> String { "/" + ignoreEscaped(path) }

    /// The ignore line for every file ending in `.<ext>`, in any folder: `*.<ext>`.
    public static func ignorePattern(extension ext: String) -> String { "*." + ignoreEscaped(ext) }

    /// The ignore line for one folder (relative to the top level, no trailing slash), anchored: `/<dir>/`.
    public static func ignorePattern(folder path: String) -> String { "/" + ignoreEscaped(path) + "/" }

    /// `text` with gitignore's special characters backslash-escaped so it matches only itself: `\ * ? [` anywhere, a
    /// leading `#` (comment) or `!` (negation), and each trailing space (git trims unescaped ones).
    private static func ignoreEscaped(_ text: String) -> String {
        let kept = text.count - text.reversed().prefix { $0 == " " }.count
        var escaped = ""
        for (offset, char) in text.enumerated() {
            if "\\*?[".contains(char) || offset == 0 && "#!".contains(char) || offset >= kept { escaped.append("\\") }
            escaped.append(char)
        }
        return escaped
    }

    // MARK: - Merge, rebase, cherry-pick, revert, reset

    /// Merges `revision` into the current branch; nil `mode` passes no flag (git's config decides). A conflict throws
    /// `GitError.conflict` and leaves the merge in progress (see `RepoState`); `.fastForwardOnly` throws
    /// `GitError.nonFastForward` when the branches diverged.
    public func merge(_ revision: String, mode: MergeMode? = nil) async throws {
        let flags: [String] = switch mode {
        case nil: []
        case .fastForward: ["--ff"]
        case .fastForwardOnly: ["--ff-only"]
        case .noFastForward: ["--no-ff"]
        }
        try await journaled(.merge, "Merge \(Self.shortRevision(revision))", mode: .carry) { ops in
            // An empty `merge.suppressDest` keeps "into <branch>" in the message for every branch (git drops it for main).
            try await ops.exec(["-c", "merge.suppressDest=", "merge", "--no-edit"] + flags + ["--end-of-options", revision])
        }
    }

    /// Whether `ancestor` is an ancestor of (or the same commit as) `descendant` (`merge-base --is-ancestor`). Throws
    /// when git fails otherwise (an unknown revision).
    public func isAncestor(_ ancestor: String, of descendant: String) async throws -> Bool {
        let result = try await runner.run(
            ["merge-base", "--is-ancestor", "--end-of-options", ancestor, descendant], cwd: cwd, env: env,
            allowedExitCodes: [0, 1])
        return result.exitCode == 0
    }

    /// Rebases the current branch onto `upstream`. `autostash`: the tracked local changes are stashed first (untracked
    /// files stay where they are) and put back on the rebased branch, and nothing changes when anything conflicts: a
    /// commit that does not replay cleanly (the rebase is aborted) or changes that do not apply cleanly to the rebased
    /// branch (a trial apply, then a hard reset to where the branch was). Both throw
    /// `GitOperationError.rebaseWouldConflict` once the branch and the changes are back as they were.
    public func rebase(onto upstream: String, autostash: Bool = false) async throws {
        let saved = StashHash()
        let save: @Sendable (GitOperations) async throws -> String? = { ops in
            let hash = try await ops.saveAutostash(includeUntracked: false)
            saved.value.withLock { $0 = hash }
            return hash
        }
        try await journaled(
            .rebase, "Rebase onto \(Self.shortRevision(upstream))", mode: .carry, before: autostash ? save : nil,
            after: autostash ? Self.restoreAutostash : nil
        ) { ops in
            if let hash = saved.value.withLock({ $0 }) {
                try await ops.rebaseOrRollBack(onto: upstream, stash: hash)
            } else {
                try await ops.exec(["rebase", "--end-of-options", upstream])
            }
        }
    }

    /// `rebase(onto:autostash:)`'s body with the changes in the stash `hash`: the tree is clean, so a failure leaves
    /// it as the stash push did and `restoreAutostash` pops the stash back. A clean trial apply is reset away too:
    /// the real one runs in `after`, once the journal has recorded the rebase.
    private func rebaseOrRollBack(onto upstream: String, stash hash: String) async throws {
        let original = try await exec(["rev-parse", "--verify", "HEAD"]).text.trimmingCharacters(in: .newlines)
        do {
            try await exec(["rebase", "--end-of-options", upstream])
        } catch {
            guard (try? await RepoState.readOperation(runner: runner, cwd: cwd, env: env)) == .rebase else { throw error }
            let paths = await unmergedPaths()
            try await exec(["rebase", "--abort"])
            throw GitOperationError.rebaseWouldConflict(paths: paths, localChanges: false)
        }
        let ref = try await stashRef(hash)
        let clean = await appliesCleanly(["stash", "apply", "--index", "--end-of-options", ref])
        let paths = clean ? [] : await unmergedPaths()
        try await exec(["reset", "-q", "--hard"] + (clean ? [] : ["--end-of-options", original, "--"]))
        if !clean { throw GitOperationError.rebaseWouldConflict(paths: paths, localChanges: true) }
    }

    /// The stash `rebase(onto:autostash:)`'s `before` pushed, for its body.
    private final class StashHash: Sendable {
        let value = Mutex<String?>(nil)
    }

    /// The unmerged paths, relative to the top level.
    private func unmergedPaths() async -> [String] {
        let text = (try? await exec(["diff", "--name-only", "--diff-filter=U", "-z"]))?.text ?? ""
        return text.split(separator: "\0").map(String.init)
    }

    /// Fast-forwards the local `branch` to `source`, a full ref (`refs/heads/x`, `refs/remotes/origin/x`). Refused
    /// (`GitError.nonFastForward`) unless `branch` is an ancestor of `source`. The checked-out branch moves with
    /// `merge --ff-only` (its index and files follow); another branch with a local `fetch . <source>:refs/heads/<branch>`,
    /// which also refuses a branch checked out in another worktree.
    public func fastForward(_ branch: String, to source: String) async throws {
        try await validateBranchName(branch)
        guard source.hasPrefix("refs/"), await checkRefFormat(source) else {
            throw GitOperationError.invalidBranchName(source)
        }
        try await lane { ops in
            let head = try await ops.exec(["symbolic-ref", "-q", "HEAD"], allowedExitCodes: [0, 1])
            if head.text.trimmingCharacters(in: .whitespacesAndNewlines) == "refs/heads/\(branch)" {
                try await ops.exec(["merge", "--ff-only", "--end-of-options", source])
            } else {
                try await ops.exec(
                    ["fetch", "--no-write-fetch-head", "--end-of-options", ".", "\(source):refs/heads/\(branch)"])
            }
        }
    }

    /// Cherry-picks `commits` in order; `mainline` (1 or 2) picks a merge relative to that parent.
    public func cherryPick(_ commits: [String], mainline: Int? = nil) async throws {
        guard !commits.isEmpty else { throw GitOperationError.unsupported("cherry-pick without commits") }
        let flags = try Self.mainlineFlags(mainline)
        let title = commits.count == 1 ? "Cherry-pick \(Self.shortRevision(commits[0]))" : "Cherry-pick \(commits.count) commits"
        try await journaled(.cherryPick, title, mode: .carry) { ops in
            try await ops.exec(["cherry-pick"] + flags + ["--end-of-options"] + commits)
        }
    }

    /// Reverts `commit`; a merge needs `mainline` (1 = keep the first parent's side, 2 = the second's).
    public func revert(_ commit: String, mainline: Int? = nil) async throws {
        let flags = try Self.mainlineFlags(mainline)
        try await journaled(.revert, "Revert \(Self.shortRevision(commit))", mode: .carry) { ops in
            try await ops.exec(["revert", "--no-edit"] + flags + ["--end-of-options", commit])
        }
    }

    // MARK: - Patches

    /// What `applyPatchToWorkingTree` did.
    public enum PatchApplyOutcome: Sendable {
        /// Plain `git apply`: the changes are unstaged, new files untracked.
        case applied
        /// `git apply --3way` merged it cleanly: the result is staged.
        case merged
        /// `git apply --3way` left conflicted files to resolve.
        case conflicts
    }

    /// Applies `patch` (a diff or a mail series, on stdin) to the working tree from the worktree's top level, not
    /// journaled: plain `apply` when `apply --check` passes, else `apply --3way`. Its exit 1 means conflicts or a
    /// refusal (nothing written), so the outcome comes from the unmerged paths before and after; a refusal throws.
    public func applyPatchToWorkingTree(_ patch: Data) async throws -> PatchApplyOutcome {
        try await lane { cwdOps in
            let ops = try await UndoJournal.topLevel(cwdOps).ops
            let unmerged = { Set(try await RepoState.conflictedPaths(runner: ops.runner, cwd: ops.cwd, env: ops.env)) }
            let unmergedBefore = try await unmerged()
            let check = try await ops.exec(
                ["apply", "--check", "--whitespace=nowarn"], stdin: patch, allowedExitCodes: [0, 1])
            if check.exitCode == 0 {
                try await ops.exec(["apply", "--whitespace=nowarn"], stdin: patch)
                return .applied
            }
            let result = try await ops.exec(
                ["apply", "--3way", "--whitespace=nowarn"], stdin: patch, allowedExitCodes: [0, 1])
            if !(try await unmerged()).subtracting(unmergedBefore).isEmpty { return .conflicts }
            guard result.exitCode == 0 else {
                throw GitError.other(exit: result.exitCode, stderrTail: result.stderrTail)
            }
            return .merged
        }
    }

    /// Applies the mail series `patch` (`count` patches, on stdin) as commits with `git am --3way` from the
    /// worktree's top level. A conflict leaves the am session for continue, skip or abort, pending in the journal
    /// like a stopped cherry-pick. A stop without conflicts (a patch that does not apply) is aborted before the error
    /// is rethrown, only when no operation was in progress before, am is in progress now and nothing is unmerged, so
    /// an am started elsewhere is never thrown away (`am --abort` keeps unrelated local changes).
    public func applyMailbox(_ patch: Data, count: Int) async throws {
        let title = count == 1 ? "Apply patch" : "Apply \(count) patches"
        try await journaled(.am, title, mode: .carry) { cwdOps in
            let ops = try await UndoJournal.topLevel(cwdOps).ops
            let operation = { try await RepoState.readOperation(runner: ops.runner, cwd: ops.cwd, env: ops.env) }
            let before = try await operation()
            do {
                try await ops.exec(["am", "--3way"], stdin: patch)
            } catch {
                if before == .none, (try? await operation()) == .am,
                   (try? await RepoState.conflictedPaths(runner: ops.runner, cwd: ops.cwd, env: ops.env))?.isEmpty
                    == true
                {
                    _ = try? await ops.exec(Self.sequencerArguments(.am, "--abort"))
                }
                throw error
            }
        }
    }

    /// Moves the current branch to `revision`: soft keeps index and files, mixed keeps files, hard resets both.
    public func reset(to revision: String, mode: ResetMode) async throws {
        // A hard reset throws the working tree's changes away: the journal keeps them like a discard.
        let content: UndoJournal.ContentScope? =
            mode == .hard ? .init(paths: ["."], untrackedPaths: nil, wholeWorktree: true) : nil
        try await journaled(
            .reset, "Reset to \(Self.shortRevision(revision))", mode: mode == .hard ? .discard : .index, content: content
        ) { ops in
            try await ops.exec(["reset", "-q", "--\(mode.rawValue)", "--end-of-options", revision, "--"])
        }
    }

    /// "Uncommit": soft reset to `HEAD~1` (the commit's changes stay staged).
    public func uncommit() async throws {
        try await reset(to: "HEAD~1", mode: .soft)
    }

    // MARK: - Conflicts

    /// Resolves the conflicted `path` (relative to `cwd`): writes `content` to it (`writeResolution`; nil deletes it)
    /// and stages it, in one lane. While a merge, rebase, cherry-pick or revert is stopped, undo puts the conflict back
    /// (`UndoJournal.stepResolve`) as long as that operation is still at the same stop.
    public func resolve(path: String, content: Data?) async throws {
        try await lane { ops in
            let start = await ops.journal?.beginResolve(path, ops: ops)
            try Self.writeResolution(content, to: path, cwd: ops.cwd)
            try await ops.exec(["--literal-pathspecs", "add", "-A", "--", path])
            if let start { await ops.journal?.finishResolve(start, title: "Resolve \(path)", ops: ops) }
        }
    }

    /// Writes a resolution into the working tree: atomically (a temporary file renamed over the old one, so a crash
    /// never leaves half a file and a symlink is replaced, not followed), keeping the old file's permissions. nil
    /// deletes the file. `path` must stay inside `cwd` (`UndoJournal.safeFile`: no absolute path, no `..`, no `.git`,
    /// no folder that is a symlink out; missing folders are created).
    public static func writeResolution(_ content: Data?, to path: String, cwd: URL) throws {
        let file = try UndoJournal.safeFile(path, in: cwd)
        let fm = FileManager.default
        // attributesOfItem does not follow a symlink at the file itself; the atomic write and the removal replace or
        // remove that link, never its target.
        let attributes = try? fm.attributesOfItem(atPath: file.path)
        guard let content else {
            if attributes != nil { try fm.removeItem(at: file) }
            return
        }
        try content.write(to: file, options: .atomic)
        if attributes?[.type] as? FileAttributeType == .typeRegular, let mode = attributes?[.posixPermissions] {
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        }
    }

    // MARK: - Continue, abort, skip

    /// A continue that completes the operation makes it undoable as a whole (back to before it started).
    public func continueOperation(_ operation: RepoState.Operation) async throws {
        let args = try Self.sequencerArguments(operation, "--continue")
        try await journaled(Self.journalKind(operation), "Continue", mode: .carry, completesOperation: true) { ops in
            try await ops.exec(args)
        }
    }

    /// `merge --abort` / `rebase --abort` also put back an auto-stash the stopped pull holds.
    public func abortOperation(_ operation: RepoState.Operation) async throws {
        let args = try Self.sequencerArguments(operation, "--abort")
        try await lane { ops in
            try await ops.exec(args)
            ops.journal?.clearPending()
        }
    }

    /// Skips the current commit of a rebase, cherry-pick or revert (`git merge` has no `--skip`).
    public func skipOperation(_ operation: RepoState.Operation) async throws {
        if operation == .merge { throw GitOperationError.unsupported("git merge has no --skip") }
        let args = try Self.sequencerArguments(operation, "--skip")
        try await journaled(Self.journalKind(operation), "Skip", mode: .carry, completesOperation: true) { ops in
            try await ops.exec(args)
        }
    }

    // MARK: - Stashes

    /// Stashes the working tree and index (`-u`: untracked files too). With `paths`, only their changes leave the
    /// working tree (git still records the whole index in the stash). Undo puts the touched paths back as they were
    /// and drops the stash (`UndoJournal.finishStashSave`).
    public func stashPush(message: String? = nil, includeUntracked: Bool = true, paths: [String] = []) async throws {
        let args = ["stash", "push"] + (includeUntracked ? ["-u"] : []) + (message.map { ["--message=\($0)"] } ?? [])
        let push = paths.isEmpty ? args : ["--literal-pathspecs"] + args + ["--"] + paths
        try await lane { ops in
            let start = await ops.journal?.beginStashSave(ops)
            try await ops.exec(push)
            if let start { await ops.journal?.finishStashSave(start, ops: ops) }
        }
    }

    /// What a `stash apply` or `pop` did.
    public struct StashApplyOutcome: Equatable, Sendable {
        /// It applied without conflicts. false: it left conflicted files to resolve (a pop then kept the stash).
        public var applied: Bool
        /// Undo can take it back: the journal recorded it (`UndoJournal.finishStashApply`).
        public var undoable: Bool
    }

    /// The stash ops take the stash's commit hash; a hash no longer listed throws `GitOperationError.stashNotFound`.
    /// Undo puts the paths the stash touched back as they were and, for a pop, stores the stash back.
    @discardableResult
    public func stashPop(_ hash: String) async throws -> StashApplyOutcome {
        try await stash("pop", hash)
    }

    @discardableResult
    public func stashApply(_ hash: String) async throws -> StashApplyOutcome {
        try await stash("apply", hash)
    }

    /// Undo stores the stash back at the top, with its message.
    public func stashDrop(_ hash: String) async throws {
        try await lane { ops in
            let stashes = try await ops.stashList()
            guard let position = stashes.firstIndex(where: { $0.hash == hash }) else {
                throw GitOperationError.stashNotFound(hash)
            }
            try await ops.exec(["stash", "drop", "--end-of-options", "stash@{\(position)}"])
            ops.journal?.recordStash(
                .stashDrop, title: "Drop stash", stash: UndoJournal.StashRef(hash: hash, message: stashes[position].message),
                paths: nil)
        }
    }

    /// Writes `path` as the stash `hash` has it into the working tree (the index stays); `untracked`: from the stash's
    /// untracked-files commit (`<hash>^3`).
    public func stashRestoreFile(_ hash: String, path: String, untracked: Bool) async throws {
        guard Self.isObjectID(hash) else { throw GitOperationError.invalidObjectID(hash) }
        try await write(
            ["--literal-pathspecs", "restore", "--source=\(hash)\(untracked ? "^3" : "")", "--worktree", "--", path])
    }

    /// One `stash apply` or `pop` of the stash whose commit is `hash`, its `stash@{n}` looked up in the lane. One that
    /// stops on conflicts returns `applied: false` instead of throwing; one git refused (nothing applied) throws.
    private func stash(_ verb: String, _ hash: String) async throws -> StashApplyOutcome {
        try await lane { ops in
            let ref = try await ops.stashRef(hash)
            // `:/`: the whole worktree, also when `cwd` is a subfolder.
            let unmerged = { (try? await ops.exec(["ls-files", "--unmerged", "--", ":/"]))?.stdout.isEmpty == false }
            let wasUnmerged = await unmerged()
            let start = await ops.journal?.beginStashApply(hash, ops: ops)
            do {
                try await ops.exec(["stash", verb, "--end-of-options", ref])
            } catch {
                guard !wasUnmerged, await unmerged() else { throw error }
                return StashApplyOutcome(applied: false, undoable: false)
            }
            guard let start, let journal = ops.journal else { return StashApplyOutcome(applied: true, undoable: false) }
            return StashApplyOutcome(
                applied: true, undoable: await journal.finishStashApply(start, pop: verb == "pop", ops: ops))
        }
    }

    /// `stash@{n}` of the stash whose commit is `hash`, from `stash list` (git takes no bare sha as a stash
    /// reference). Only call it from inside `lane`, so the index cannot go stale.
    private func stashRef(_ hash: String) async throws -> String {
        guard let index = try await stashList().firstIndex(where: { $0.hash == hash }) else {
            throw GitOperationError.stashNotFound(hash)
        }
        return "stash@{\(index)}"
    }

    /// The stashes, `stash@{0}` first: commit hash and reflog message (what `stash store -m` takes). Inside `lane`.
    func stashList() async throws -> [(hash: String, message: String)] {
        try await exec(["stash", "list", "--format=%H %gs"]).text.split(separator: "\n").map { line in
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
        }
    }

    /// The commit `refs/stash` points to; nil without stashes. Inside `lane`.
    func stashTop() async throws -> String? {
        let result = try await exec(["rev-parse", "-q", "--verify", "refs/stash"], allowedExitCodes: [0, 1])
        return result.exitCode == 0 ? result.text.trimmingCharacters(in: .newlines) : nil
    }

    /// `journaled`'s hooks for an auto-stash.
    private static let saveAutostash: @Sendable (GitOperations) async throws -> String? = { try await $0.saveAutostash() }
    private static let restoreAutostash: @Sendable (GitOperations, String?, (any Error)?) async throws -> Void = {
        try await $0.restoreAutostash($1, failure: $2)
    }

    /// `journaled`'s `before:` for an auto-stash: `stash push -u` (`-u` only with `includeUntracked`). Returns the new
    /// stash's hash; nil when there was nothing to save (an empty push leaves `refs/stash` as it was, so nothing is
    /// put back later).
    private func saveAutostash(includeUntracked: Bool = true) async throws -> String? {
        let top = try await stashTop()
        try await exec(["stash", "push"] + (includeUntracked ? ["-u"] : []))
        let saved = try await stashTop()
        return saved == top ? nil : saved
    }

    /// `journaled`'s `after:` for the auto-stash `hash`. When the body failed, `stash pop --index` (the tree is as the
    /// push left it). Else `stash apply --index`, and only when git refused before changing anything (status as
    /// before, e.g. "Conflicts in index") one plain `stash apply`. Only a clean `--index` apply (exit 0, nothing
    /// unmerged) drops the stash; anything else keeps it and throws `GitError.autostashKept` (a plain apply ignores
    /// the stashed index, so staged-only content would exist only in the stash).
    private func restoreAutostash(_ hash: String?, failure: (any Error)?) async throws {
        guard let hash else { return }
        // Every way out but a clean restore names the stash: the changes may be nowhere else.
        guard let ref = try? await stashRef(hash) else { throw GitError.autostashKept(hash) }
        if failure != nil {
            guard await appliesCleanly(["stash", "pop", "--index", "--end-of-options", ref]) else {
                throw GitError.autostashKept(hash)
            }
            return
        }
        let status = ["status", "--porcelain=v1", "-z", "--untracked-files=all"]
        let before = try? await exec(status).stdout
        if await appliesCleanly(["stash", "apply", "--index", "--end-of-options", ref]) {
            guard (try? await exec(["stash", "drop", "--end-of-options", ref])) != nil else {
                throw GitError.autostashKept(hash)
            }
            return
        }
        if let before, (try? await exec(status))?.stdout == before {
            _ = try? await exec(["stash", "apply", "--end-of-options", ref])
        }
        throw GitError.autostashKept(hash)
    }

    /// Runs a `stash apply` or `pop`: true when it exited 0 and left no unmerged entry.
    private func appliesCleanly(_ args: [String]) async -> Bool {
        guard (try? await exec(args)) != nil else { return false }
        return (try? await exec(["ls-files", "--unmerged"]))?.stdout.isEmpty == true
    }

    private static let autostashFiles = ["MERGE_AUTOSTASH", "rebase-merge/autostash", "rebase-apply/autostash"]

    /// Whether a stopped merge or rebase holds an auto-stash (`MERGE_AUTOSTASH`, `rebase-merge/autostash`,
    /// `rebase-apply/autostash`), which git puts back on continue or abort.
    func autostashPending() async -> Bool {
        let names = Self.autostashFiles
        guard let paths = try? await exec(["rev-parse", "--path-format=absolute"] + names.flatMap { ["--git-path", $0] })
        else { return false }
        return paths.text.split(separator: "\n").contains { FileManager.default.fileExists(atPath: String($0)) }
    }

    // MARK: - Tags

    /// A lightweight tag, or an annotated one when `message` is given (passed on stdin).
    /// Undo deletes it; undo of a delete puts back the same ref value (an annotated tag's own object).
    public func createTag(_ name: String, at revision: String, message: String? = nil) async throws {
        try await validateTagName(name)
        try await journaled(.createTag, "Create tag \(name)", mode: .index, refs: ["refs/tags/\(name)"]) { ops in
            if let message {
                try await ops.exec(["tag", "-a", "--file=-", "--end-of-options", name, revision], stdin: Data(message.utf8))
            } else {
                try await ops.exec(["tag", "--end-of-options", name, revision])
            }
        }
    }

    public func deleteTag(_ name: String) async throws {
        try await journaled(.deleteTag, "Delete tag \(name)", mode: .index, refs: ["refs/tags/\(name)"]) { ops in
            try await ops.exec(["tag", "-d", "--end-of-options", name])
        }
    }

    public func pushTag(_ name: String, to remote: String) async throws {
        try await push(["push", "--end-of-options", remote, "refs/tags/\(name):refs/tags/\(name)"], to: remote)
    }

    public func deleteRemoteTag(_ name: String, on remote: String) async throws {
        try await push(["push", "--end-of-options", remote, ":refs/tags/\(name)"], to: remote)
    }

    // MARK: - Clone and init

    /// Clones `url` into `destination` (which must not exist; its parent must), reporting git's
    /// `--progress` lines (stderr, split on `\r` and `\n`) as they arrive. `env` is
    /// `GitInvocation.cloneEnvironment(url:profile:base:credentials:runner:)`. Cancelling the task stops git, and so does
    /// `timeout` (1 h by default; nil = no limit, for huge repos).
    public static func clone(
        url: String, into destination: URL, runner: GitRunner, env: [String: String],
        timeout: Duration? = .seconds(3600),
        progress: @escaping @Sendable (String) -> Void
    ) async throws {
        try validateRemoteURL(url)
        let parent = destination.deletingLastPathComponent()
        try await runner.mutate {
            let lines = await runner.stream(
                ["clone", "--progress", "--", url, destination.path], cwd: parent, env: env, timeout: timeout)
            for try await line in lines where line.source == .stderr {
                progress(line.text)
            }
            // A cancelled stream finishes without an error.
            try Task.checkCancellation()
        }
    }

    /// Creates an empty repository at `destination` (created if missing; its parent must exist).
    public static func initRepository(at destination: URL, runner: GitRunner, env: [String: String]) async throws {
        let parent = destination.deletingLastPathComponent()
        _ = try await runner.mutate {
            try await runner.run(["init", "-q", "--", destination.path], cwd: parent, env: env)
        }
    }

    // MARK: - Undo and redo

    /// Puts the repository back in the state before the last journaled operation and returns that operation.
    /// Throws `UndoError` (`.repositoryChanged` when something else changed HEAD, a touched branch, the index or
    /// the discarded files since; `.objectsMissing` after `git gc` pruned what it needs).
    @discardableResult
    public func undo() async throws -> UndoJournal.Entry {
        guard let journal else { throw UndoError.noJournal }
        return try await lane { ops in try await journal.step(.undo, ops: ops) }
    }

    /// Replays the last undone operation's after-state and returns that operation. Throws like `undo()`.
    @discardableResult
    public func redo() async throws -> UndoJournal.Entry {
        guard let journal else { throw UndoError.noJournal }
        return try await lane { ops in try await journal.step(.redo, ops: ops) }
    }

    // MARK: - Validation

    /// A new local branch name: not empty, no leading `-`, not `HEAD`, and `refs/heads/<name>` passes
    /// `git check-ref-format`.
    public func validateBranchName(_ name: String) async throws {
        guard Self.isSafeName(name), name != "HEAD", await checkRefFormat("refs/heads/\(name)") else {
            throw GitOperationError.invalidBranchName(name)
        }
    }

    /// A new tag name: not empty, no leading `-`, and `refs/tags/<name>` passes `git check-ref-format`.
    public func validateTagName(_ name: String) async throws {
        guard Self.isSafeName(name), await checkRefFormat("refs/tags/\(name)") else {
            throw GitOperationError.invalidTagName(name)
        }
    }

    /// A new remote name: `[A-Za-z0-9._-]+`, no leading `-`, and `refs/remotes/<name>/x` passes
    /// `git check-ref-format` (no `..`, no leading `.`, no `.lock` suffix).
    public func validateRemoteName(_ name: String) async throws {
        let allowed = name.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0))
        }
        guard Self.isSafeName(name), allowed, await checkRefFormat("refs/remotes/\(name)/x") else {
            throw GitOperationError.invalidRemoteName(name)
        }
    }

    /// A remote URL or path: not empty, no leading `-` (ssh/transport option injection), no control characters.
    public static func validateRemoteURL(_ url: String) throws {
        guard !url.isEmpty, !url.hasPrefix("-"),
            !url.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw GitOperationError.invalidRemoteURL(url) }
    }

    /// 4 to 64 ASCII hex digits.
    public static func isObjectID(_ text: String) -> Bool {
        (4...64).contains(text.utf8.count)
            && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }
    }

    // MARK: - Helpers

    private static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-")
    }

    func checkRefFormat(_ ref: String) async -> Bool {
        let result = try? await runner.run(["check-ref-format", ref], cwd: cwd, env: env, allowedExitCodes: [0, 1])
        return result?.exitCode == 0
    }

    private func requirePaths(_ paths: [String]) throws {
        if paths.isEmpty { throw GitOperationError.noPaths }
    }

    /// The gitlinks (mode 160000, stage 0 in the index: a conflicted one stays with the files) among `paths`, by exact
    /// path, and those of them whose submodule is checked out (has its own `.git`). A read: runs before the lane.
    private func gitlinks(among paths: [String]) async throws -> (all: Set<String>, checkedOut: [String]) {
        let output = try await runner.run(
            ["--literal-pathspecs", "ls-files", "-s", "-z", "--"] + paths, cwd: cwd, env: env)
        var all = Set<String>()
        // `<mode> <sha> <stage>\t<path>` per entry.
        for record in output.stdout.split(separator: 0) {
            guard let tab = record.firstIndex(of: UInt8(ascii: "\t")) else { continue }
            let fields = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
            guard fields.count == 3, fields[0] == "160000", fields[2] == "0" else { continue }
            let path = String(decoding: record[record.index(after: tab)...], as: UTF8.self)
            if paths.contains(path) { all.insert(path) }
        }
        let checkedOut = all.sorted().filter {
            FileManager.default.fileExists(atPath: cwd.appending(path: $0 + "/.git").path)
        }
        return (all, checkedOut)
    }

    /// Puts the submodules at `gitlinks` back on their recorded commits (this level only, never initialized here).
    /// Only calls `exec`: it runs inside the caller's lane.
    private func updateGitlinks(_ gitlinks: [String]) async throws {
        let report = try await updateLevel(gitlinks, initialize: false, recursive: false, prefix: "", restoring: true)
        guard report.failures.isEmpty else { throw report }
    }

    private static func signingFlags(_ signing: CommitSigning) -> [String] {
        switch signing {
        case .profileDefault: []
        case .sign: ["--gpg-sign"]
        case .noSign: ["--no-gpg-sign"]
        }
    }

    private static func mainlineFlags(_ mainline: Int?) throws -> [String] {
        guard let mainline else { return [] }
        guard mainline >= 1 else { throw GitOperationError.invalidMainline(mainline) }
        return ["-m", String(mainline)]
    }

    static func sequencerArguments(_ operation: RepoState.Operation, _ step: String) throws -> [String] {
        let verb: String = switch operation {
        case .none: throw GitOperationError.noOperationInProgress
        case .merge: "merge"
        case .rebase: "rebase"
        case .cherryPick: "cherry-pick"
        case .revert: "revert"
        case .am: "am"
        }
        return ["-c", "core.editor=true", verb, step]
    }

    /// Runs an undoable operation in the lane between the journal's before- and after-snapshots (when there is a
    /// journal). `refs` are the branches or tags it creates, deletes or renames (the journal adds HEAD's branch itself).
    /// `completesOperation`: a commit, continue or skip, which may complete a merge, rebase, cherry-pick or revert
    /// that stopped earlier (it then becomes undoable as a whole). A stopped pull's auto-stash that git keeps in
    /// `refs/stash` during the operation throws `GitError.autostashKept`. `before` runs in the lane before the
    /// before-snapshot and returns a value for `after`, which runs once the entry is recorded (with the body's error
    /// when it threw, which is then rethrown); both also run without a journal.
    func journaled(
        _ kind: UndoJournal.Kind, _ title: String, mode: UndoJournal.Mode, refs: [String] = [],
        content: UndoJournal.ContentScope? = nil, completesOperation: Bool = false,
        before: (@Sendable (GitOperations) async throws -> String?)? = nil,
        after: (@Sendable (GitOperations, String?, (any Error)?) async throws -> Void)? = nil,
        _ body: @escaping @Sendable (GitOperations) async throws -> Void
    ) async throws {
        try await lane { ops in
            // A stopped pull's auto-stash comes back on a commit, continue or skip, and a reset, checkout or stash push
            // that drops a merge's state saves it: git keeps it in `refs/stash` and exits 0. Read before `before`,
            // whose stash push is such a drop. Without `before`, the same `rev-parse` looks for the files of
            // `RepoState.readOperation`: when none exists no operation is in progress, and `begin` need not read it.
            let stashes = Self.autostashFiles.count
            let files = Self.autostashFiles
                + RepoState.operationMarkers
            let found = before != nil ? nil : (try? await ops.exec(
                ["rev-parse", "--path-format=absolute"] + files.flatMap { ["--git-path", $0] }))?.text
                .split(separator: "\n").map { FileManager.default.fileExists(atPath: String($0)) }
            let read = found?.count == files.count
            let held = read ? found?.prefix(stashes).contains(true) == true : await ops.autostashPending()
            let noOperation = read && found?.dropFirst(stashes).contains(true) == false
            let top = held ? try await ops.stashTop() : nil
            let saved = try await before?(ops) ?? nil
            let start = await ops.journal?.begin(
                ops, refs: refs, content: content, completesOperation: completesOperation, noOperation: noOperation)
            do {
                try await body(ops)
            } catch {
                if let start {
                    await ops.journal?.finish(
                        start, kind: kind, title: title, mode: mode, refs: refs, succeeded: false, ops: ops)
                }
                try await after?(ops, saved, error)
                throw error
            }
            if let start {
                await ops.journal?.finish(start, kind: kind, title: title, mode: mode, refs: refs, succeeded: true, ops: ops)
            }
            try await after?(ops, saved, nil)
            if held, let now = try await ops.stashTop(), now != top { throw GitError.autostashKept(now) }
        }
    }

    private static func journalKind(_ operation: RepoState.Operation) -> UndoJournal.Kind {
        switch operation {
        case .none, .merge: .merge
        case .rebase: .rebase
        case .cherryPick: .cherryPick
        case .am: .am
        case .revert: .revert
        }
    }

    /// The first line of a commit message, cut for a menu title.
    static func subject(_ message: String) -> String {
        let line = message.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return line.count > 50 ? String(line.prefix(49)) + "…" : line
    }

    /// An object id cut to 7 digits for a title; names stay as they are.
    static func shortRevision(_ revision: String) -> String {
        isObjectID(revision) && revision.count > 7 ? String(revision.prefix(7)) : revision
    }

    /// One write in the lane.
    @discardableResult
    private func write(_ args: [String], stdin: Data? = nil, network: Bool = false) async throws -> GitResult {
        try await lane { ops in try await ops.exec(args, stdin: stdin, network: network) }
    }

    /// Runs `body` in the runner's write lane. `body` must only call `exec`, never another public operation.
    func lane<T: Sendable>(_ body: @escaping @Sendable (GitOperations) async throws -> T) async throws -> T {
        let ops = self
        return try await runner.mutate { try await body(ops) }
    }

    /// Runs one command without taking the lane: only call it from inside `lane` (or for `optimizeRepository`).
    /// `extraEnv` adds to the environment of this one command (the interactive rebase's sequence editor); `environment` replaces it (a
    /// token-carrying command).
    @discardableResult
    func exec(
        _ args: [String], stdin: Data? = nil, network: Bool = false, allowedExitCodes: Set<Int32> = [0],
        extraEnv: [String: String] = [:], environment: [String: String]? = nil
    ) async throws -> GitResult {
        var timeout = network ? networkTimeout : nil
        if network, let networkDeadline {
            timeout = networkDeadline - .now
            guard let left = timeout, left > .zero else { throw GitError.timeout }
        }
        return try await runner.run(
            args, cwd: cwd, env: (environment ?? (network ? networkEnv : env)).merging(extraEnv) { $1 }, stdin: stdin,
            timeout: timeout, allowedExitCodes: allowedExitCodes)
    }

    // MARK: - Token

    /// Runs one network command (inside the lane). The gate decides first: with `.attach` (every URL `target`
    /// contacts is `https://<profile host>/…` and the repo sets no network key) git gets the token in the hardened
    /// `.network` environment, with no hook at all for a fetch. A push keeps the repo's pre-push hook, run without
    /// the token by a wrapper (`GitInvocation.prePushHooksFolder`), unless it is git-lfs's stub, whose upload needs
    /// it. Anything else runs with `networkEnv` and no token. A nil `target` (git could not list the remotes) is no
    /// token.
    @discardableResult
    func networkExec(_ args: [String], target: GitInvocation.NetworkTarget?) async throws -> GitResult {
        let decision = await tokenDecision(for: target)
        guard case .attach(let matched) = decision, let credential else {
            return try await withheldExec(decision) { try await exec(args, network: true) }
        }
        guard case .push = target else {
            return try await exec(args, network: true, environment: tokenEnvironment(.fetch, credential, matched))
        }
        // The write environment of the credential's profile: where git finds the hook, and what the hook sees.
        let hookEnv = GitInvocation.environment(profile: credential.profile, base: credential.base, access: .write)
        let hooks = try await GitInvocation.prePushHooksFolder(
            runner: runner, cwd: cwd, env: hookEnv, credentials: matched)
        defer { try? FileManager.default.removeItem(at: hooks) }
        return try await exec(
            args, network: true, environment: tokenEnvironment(.push(hooksPath: hooks.path), credential, matched))
    }

    func tokenDecision(for target: GitInvocation.NetworkTarget?) async -> GitInvocation.TokenDecision {
        guard let credential else { return .noToken }
        guard let target else { return .lookupFailed }
        return await GitInvocation.networkToken(
            for: target, credentials: credential.credentials, base: credential.base, runner: runner, cwd: cwd)
    }

    /// The token-carrying environment of `kind` with `matched` alone: the credentials the gate's `.attach` gave for
    /// this command, never the whole set of `credential`.
    func tokenEnvironment(
        _ kind: GitInvocation.NetworkKind, _ credential: NetworkCredential, _ matched: [GitCredential]
    ) -> [String: String] {
        GitInvocation.environment(
            profile: credential.profile, base: credential.base, access: .network(kind), credentials: matched)
    }

    /// Runs a network command that did not get the token; when the repo's own network config, its submodule recursion
    /// or a remote group named like the fetched remote kept it back and git then could not sign in, throws
    /// `NetworkTokenWithheld` so the message can say why.
    func withheldExec<T: Sendable>(_ decision: GitInvocation.TokenDecision, _ body: () async throws -> T)
        async throws -> T
    {
        do {
            return try await body()
        } catch let error as GitError {
            guard case .auth = error else { throw error }
            switch decision {
            case .repoNetworkConfig(let keys): throw NetworkTokenWithheld(reason: .repoNetworkConfig(keys: keys), error: error)
            case .submoduleRecursion(let keys):
                throw NetworkTokenWithheld(reason: .submoduleRecursion(keys: keys), error: error)
            case .remoteGroup(let name): throw NetworkTokenWithheld(reason: .remoteGroup(name: name), error: error)
            case .attach, .noToken, .otherURL, .lookupFailed: throw error
            }
        }
    }

    /// A copy whose network commands stop at `deadline` (one remote of a Fetch All, within the shared limit): each
    /// gets the time left when git starts, after the gate, and none starts once it passed (`GitError.timeout`).
    private func withNetworkDeadline(_ deadline: ContinuousClock.Instant) -> GitOperations {
        var copy = self
        copy.networkDeadline = deadline
        return copy
    }

    /// `fetch [--prune] <remote>` through the gate (inside the lane). When git could not sign in to a remote whose
    /// fetch URL is `https://<host>/…` on a host the profile has no account for, throws `NetworkTokenWithheld` with
    /// `.noAccount`, so the message can say so.
    func fetchRemote(_ remote: String, prune: Bool) async throws {
        do {
            try await networkExec(
                ["fetch"] + (prune ? ["--prune"] : []) + ["--end-of-options", remote],
                target: .fetch(remotes: [remote]))
        } catch let error as GitError {
            guard case .auth = error, let host = await hostWithoutAccount(remote) else { throw error }
            throw NetworkTokenWithheld(reason: .noAccount(host: host), error: error)
        }
    }

    /// The host of the first fetch URL of `remote` (as git rewrites it) that is https on a host none of the profile's
    /// accounts has (a usable token or not: an account whose token is unusable is still an account); nil when there
    /// is none or git cannot list them.
    private func hostWithoutAccount(_ remote: String) async -> String? {
        let accountHosts = Set((credential?.credentials ?? []).compactMap { HostingHTTP.validatedHost($0.host) })
        guard let urls = try? await runner.run(
            ["remote", "get-url", "--all", "--end-of-options", remote], cwd: cwd, env: env, timeout: .seconds(10)).text
        else { return nil }
        for url in urls.split(separator: "\n") where url.hasPrefix("https://") {
            let authority = url.dropFirst("https://".count).prefix { $0 != "/" }
            // A userinfo part (`user@`) is not the host.
            guard let host = authority.split(separator: "@").last.flatMap({ HostingHTTP.validatedHost(String($0)) }),
                  !accountHosts.contains(host)
            else { continue }
            return host
        }
        return nil
    }
}
