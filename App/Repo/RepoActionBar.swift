// The repo actions the toolbar's buttons run (`HeaderToolbar`): Pull (its menu: fetch all, pull fast-forward if
// possible, fast-forward only, rebase), Push (its menu: force with lease, confirmed), Fetch, Branch, Stash and Pop. A
// button shows its operation's progress on itself from the click's frame (`ActionBarAction`); every operation, the
// buttons' too, also shows in `RunningStatus`. A failure shows in its toast, with a hint mapped from `GitError`
// (sign-in, unknown or changed host key, "Pull first", index.lock, conflicts) and the hint's action (`FailureHints`); an
// unknown host key opens the host-key sheet, which scans the host and appends its keys to known_hosts only on "Trust
// Host".
import HistqCore
import SwiftUI

/// The toolbar's buttons: the key of the operation each one shows. `checkout` is the branch menu's (every checkout,
/// wherever it started); `undo` and `redo` are the history buttons' (also ⌘Z / ⇧⌘Z and the palette).
enum ActionBarAction: Hashable, Sendable {
    case pull, push, fetch, branch, stash, pop, checkout, undo, redo
}

/// The host-key sheet's state: the host, whether ssh reported a changed key (then it only warns), and the scan.
struct HostKeyCheck: Identifiable {
    enum State {
        case scanning
        /// A changed key: never scanned for trust.
        case changed
        case scanned(HostKeyTrust.Scan)
        /// Appending to known_hosts.
        case trusting(HostKeyTrust.Scan)
        case failed(String)
    }

    let id = UUID()
    let host: HostKeyTrust.Host?
    let isChanged: Bool
    var state: State
    /// The operation to run again once the host is trusted.
    let failure: OperationFailure
}

// MARK: - Actions

extension RepoSession {
    /// The remote a branch without upstream is pushed to: `origin`, else the first remote.
    var defaultRemote: String? {
        remotes.first { $0.name == "origin" }?.name ?? remotes.first?.name
    }

    /// Where `branch` pushes: its upstream's remote and branch (and the upstream's commit, the lease of a force push),
    /// else the default remote with `-u`. Nil without a remote.
    func pushTarget(of branch: String) -> (remote: String, remoteBranch: String?, setUpstream: Bool, lease: String?)? {
        let refs = refs.value
        if let upstream = refs?.localBranches.first(where: { $0.name == branch })?.upstream {
            if let tracking = refs?.remoteBranches.first(where: { $0.name == upstream }) {
                return (tracking.remote, String(upstream.dropFirst(tracking.remote.count + 1)), false, tracking.commit)
            }
            // The upstream is not fetched (or gone): its remote is the longest remote name it starts with.
            if let remote = remotes.map(\.name).filter({ upstream.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) {
                return (remote, String(upstream.dropFirst(remote.count + 1)), false, nil)
            }
        }
        return defaultRemote.map { ($0, nil, true, nil) }
    }

    /// Pushes `branch` to its upstream. A branch without one opens the first-push form (the remote and the remote
    /// branch's name, pushed with `-u`). `force` asks for a confirmation first, then pushes with `--force-with-lease`
    /// against the remote-tracking commit.
    func push(branch: String, force: Bool = false, key: ActionBarAction? = nil) {
        guard let target = pushTarget(of: branch) else {
            report(OperationFailure(title: "Push \(branch)", write: .push(branch: branch, remote: "", remoteBranch: nil,
                                    setUpstream: false, forceWithLease: nil),
                                    error: CocoaError(.featureUnsupported), message: "This repository has no remote. Add one first."))
            return
        }
        let destination = "\(target.remote)/\(target.remoteBranch ?? branch)"
        if target.setUpstream {
            dialog = .pushNewBranch(branch, key: key)
        } else if force {
            guard let lease = target.lease else { return }
            confirm("Force push `\(branch)` to `\(destination)`?",
                    message: "`\(destination)` is overwritten if it is still at `\(lease.prefix(7))`. Its commits that are not on `\(branch)` are lost.",
                    button: "Force Push",
                    write: .push(branch: branch, remote: target.remote, remoteBranch: target.remoteBranch,
                                 setUpstream: false, forceWithLease: lease),
                    operation: "Force push \(branch)", key: key)
        } else {
            run(.push(branch: branch, remote: target.remote, remoteBranch: target.remoteBranch,
                      setUpstream: target.setUpstream, forceWithLease: nil),
                title: "Push \(branch) to \(destination)", key: key)
        }
    }

    /// A normal push the remote rejected because its branch has commits this branch lacks: asks Force Push (with
    /// lease, against the remote-tracking commit) / Pull / Cancel instead of the "Pull first" toast; Pull only for
    /// the checked-out branch (a pull has no other). Only when the branch is behind that remote-tracking commit;
    /// never after a lease refusal (a push with a lease), so no loop. True when it asked.
    func offerForcePush(after failure: OperationFailure, key: ActionBarAction?) -> Bool {
        guard case .push(let branch, let remote, let remoteBranch, let setUpstream, nil) = failure.write,
              case .nonFastForward = failure.error as? GitError else { return false }
        let destination = "\(remote)/\(remoteBranch ?? branch)"
        guard let refs = refs.value,
              let lease = refs.remoteBranches.first(where: { $0.name == destination })?.commit,
              let local = refs.localBranches.first(where: { $0.name == branch }),
              local.upstream == destination, local.behind > 0 else { return false }
        self.failure = failure
        let count = "\(local.behind) \(local.behind == 1 ? "commit" : "commits")"
        let canPull = branch == currentBranch
        confirm("Force push `\(branch)` to `\(destination)`?",
                message: (local.ahead > 0 ? "`\(branch)` and `\(destination)` have diverged. " : "")
                    + "`\(destination)` has \(count) that `\(branch)` does not have. Force Push removes "
                    + (canPull ? "them from the remote; Pull brings them in first." : "them from the remote."),
                button: "Force Push",
                write: .push(branch: branch, remote: remote, remoteBranch: remoteBranch, setUpstream: setUpstream,
                             forceWithLease: lease),
                operation: "Force push \(branch)", key: key,
                secondary: canPull ? ("Pull", .pull(RepoSession.preferredPullMode)) : nil)
        return true
    }

    /// Every pull (the toolbar, the action bar, the Pull menus). With local changes and `PrefKey.autoStash` "ask", asks
    /// first: Stash & Pull (`--autostash`) or Cancel. Untracked files alone count as clean: `--autostash` leaves them
    /// out (`stash create`) and a plain pull already works with them.
    func pull(_ mode: GitOperations.PullMode) {
        let preference = Preferences.defaults.string(forKey: PrefKey.autoStash.rawValue)
        let dirty = status.value.map { !$0.staged.isEmpty || !$0.unstaged.isEmpty || !$0.conflicted.isEmpty } == true
        guard dirty, preference != "never" else { return run(.pull(mode), title: "Pull", key: .pull) }
        if preference == "always" { return run(.pull(mode, autostash: true), title: "Pull", key: .pull) }
        confirm("Pull with uncommitted changes?",
                message: "Stash & Pull puts your changes in a stash, pulls, then brings them back. If they conflict "
                    + "with what was pulled, they are kept safe in the stash.",
                button: "Stash & Pull", write: .pull(mode, autostash: true), operation: "Pull", key: .pull,
                isDestructive: false, asksAlways: true)
    }

    /// Pulls `name`, a local branch that is not checked out, from its `upstream` without a checkout, as `mode` says
    /// (`GitOperations.pullBranch`). When that stops with nothing changed, `offerCheckoutPull` asks what to do.
    func pullBranch(_ name: String, upstream: RemoteBranch, mode: GitOperations.PullMode) {
        let remoteBranch = String(upstream.name.dropFirst(upstream.remote.count + 1))
        run(.pullBranch(name, remote: upstream.remote, remoteBranch: remoteBranch, mode: mode), title: "Pull \(name)")
    }

    /// After a `pullBranch` that stopped on conflicts, or that cannot merge or rebase without a checkout, with nothing
    /// changed: Checkout & Pull checks the branch out (changes stashed and brought back when `PrefKey.autoStash` is
    /// "always", else carried along: git refuses when they conflict), then
    /// pulls it there with the same mode, so conflicts stop in the WIP panel; Abort leaves everything as it was. True
    /// when it asked.
    func offerCheckoutPull(after failure: OperationFailure) -> Bool {
        guard case .pullBranch(let branch, _, _, let mode) = failure.write,
              let error = failure.error as? GitOperationError
        else { return false }
        switch error {
        case .pullWouldConflict, .pullNeedsCheckout: break
        default: return false
        }
        let title = if case .pullWouldConflict = error { "Pulling \(branch) would conflict" }
            else { "\(branch) needs a checkout to pull" }
        let stash = Preferences.defaults.string(forKey: PrefKey.autoStash.rawValue) == "always"
            && status.value?.entries.contains(where: { !$0.isSubmodule }) == true
        confirm(title,
                message: Self.message(for: error) + " Checkout & Pull checks \(branch) out and pulls it there"
                    + (mode == .rebase ? " (rebase)" : "") + ". Abort leaves everything as it is.",
                button: "Checkout & Pull", write: .checkoutBranch(branch, autostash: stash),
                operation: "Checkout \(branch)",
                key: .checkout, isDestructive: false, cancel: "Abort") { [weak self] in self?.pull(mode) }
        return true
    }

    /// Rebases the checked-out branch onto `upstream` (a full ref). With local changes (untracked files and submodules
    /// aside, which a rebase leaves alone) and `PrefKey.autoStash` "ask", asks first: Stash & Rebase or Cancel.
    /// "always" stashes without asking, "never" leaves them to git, which refuses. A stashed rebase goes through only
    /// when nothing conflicts; otherwise nothing changes (`GitOperations.rebase(onto:autostash:)`).
    func rebase(onto upstream: String, title: String) {
        let preference = Preferences.defaults.string(forKey: PrefKey.autoStash.rawValue)
        let dirty = status.value?.entries.contains { !$0.isSubmodule && $0.kind != .untracked } == true
        let write = { (autostash: Bool) in RepoSession.Write.rebase(onto: upstream, checkoutFirst: nil, autostash: autostash) }
        guard dirty, preference != "never" else { return run(write(false), title: title) }
        if preference == "always" { return run(write(true), title: title) }
        confirm("\(title) with uncommitted changes?",
                message: "Stash & Rebase puts your changes in a stash, rebases, then brings them back. If the rebase "
                    + "or your changes would conflict, nothing is changed.",
                button: "Stash & Rebase", write: write(true), operation: title, isDestructive: false, asksAlways: true)
    }

    /// After a pull request of `branch` (a branch of the tab's hosting remote) merged: when the host deleted the branch,
    /// its remote-tracking branch goes and a toast says so. Quiet otherwise, a failure too (the merge went through). The
    /// host may delete the branch a moment after the merge (GitLab in a background job): a branch still there is asked
    /// about once more, 3 s later.
    func pruneMergedBranch(_ branch: String) {
        guard let remote = github.api?.remote else { return }
        let host = github.kind.name
        Task { [weak self] in
            var outcome = try? await self?.perform(.pruneMergedBranch(branch, remote: remote))
            if outcome == .done {
                try? await Task.sleep(for: .seconds(3))
                outcome = try? await self?.perform(.pruneMergedBranch(branch, remote: remote))
            }
            guard let self else { return }
            UITiming.content("pr merged-branch \(outcome == .remoteBranchPruned ? "pruned" : "kept")")
            guard outcome == .remoteBranchPruned else { return }
            postToast(.success("\(branch) was deleted on \(host)",
                               detail: "Its remote-tracking branch \(remote)/\(branch) is removed."))
        }
    }

    func fetchAll() {
        let prune = Preferences.defaults.bool(forKey: PrefKey.pruneOnFetch.rawValue)
        run(.fetchAll(prune: prune), title: "Fetch", key: .fetch)
    }

    /// One remote's Fetch (its menu), pruning as Fetch All does.
    func fetch(remote: String) {
        let prune = Preferences.defaults.bool(forKey: PrefKey.pruneOnFetch.rawValue)
        run(.fetchRemote(remote, prune: prune), title: "Fetch \(remote)", key: .fetch)
    }

    /// `PrefKey.pullMode` ("fastForward", "fastForwardOnly", "rebase").
    static var preferredPullMode: GitOperations.PullMode {
        switch Preferences.defaults.string(forKey: PrefKey.pullMode.rawValue) {
        case "fastForwardOnly": .fastForwardOnly
        case "rebase": .rebase
        default: .fastForward
        }
    }

    /// A short name for a commit in titles: its first branch, else its short sha.
    func label(of commit: String) -> String {
        if let branch = refs.value?.localBranches.first(where: { $0.commit == commit }) { return branch.name }
        return String(commit.prefix(7))
    }
}

// MARK: - Toolbar actions

extension RepoSession {
    /// The newest stash, the one Pop applies.
    var newestStash: Stash? { log.value?.stashes.first }

    /// Opens the Create Branch form at HEAD.
    func createBranchAtHead() {
        guard let head = refs.value?.head.commit else { return }
        dialog = .createBranch(from: head, label: currentBranch ?? String(head.prefix(7)))
    }

    /// Stashes every change.
    func stashAll() {
        run(.stashPush(message: nil), title: "Stash", key: .stash)
    }

    /// Pops the newest stash.
    func popNewestStash() {
        guard let stash = newestStash else { return }
        run(.stashPop(hash: stash.hash), title: "Pop \(stash.selector)", key: .pop)
    }
}

/// The newest operation still running, whatever started it (a toolbar button, a menu, the palette, a panel's button,
/// the automatic fetch): a spinner and its title, from the click's frame on. A checkout's spinner fades in only after
/// 150 ms, so a fast checkout never flashes one.
struct RunningStatus: View {
    let session: RepoSession
    var font: Font = .settingsCaption

    var body: some View {
        if let operation = session.running.last {
            HStack(spacing: 6) {
                if operation.key == .checkout {
                    // The mini spinner's own place, filled after the delay (`DelayedSpinner` is a bigger one); not
                    // once the checkout has ended, as this view can outlive it by a display.
                    ProgressView().controlSize(.mini).hidden().overlay {
                        DelayedReveal(token: operation.id, detail: "status",
                                      isCurrent: { session.running.contains { $0.id == operation.id } }) {
                            ProgressView().controlSize(.mini)
                        }
                    }
                } else {
                    ProgressView().controlSize(.mini)
                }
                Text(operation.title + "…")
                    .font(font)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.trailing, 6)
            .layoutPriority(-1)
            .onChange(of: operation.id, initial: true) { UITiming.opFeedback("status \(operation.title)") }
        }
    }
}

// MARK: - Failure hints

/// A failure's hint for the known cases and the hint's action, shown in the failure's toast.
enum FailureHints {
    /// What the hint's button does.
    enum Action {
        case checkHostKey, pull, forceDelete(String)
        /// A worktree git refused to remove for its changes: the forced removal, confirmed.
        case forceRemoveWorktree(String)
        /// A submodule git refused to remove for its local changes: the forced removal, confirmed.
        case forceRemoveSubmodule(String)

        var title: String {
            switch self {
            case .checkHostKey: "Check Host Key"
            case .pull: "Pull"
            case .forceDelete: "Delete Anyway"
            case .forceRemoveWorktree, .forceRemoveSubmodule: "Remove Anyway"
            }
        }

        /// A forced delete or removal: the toast's button is red.
        var isDestructive: Bool {
            switch self {
            case .checkHostKey, .pull: false
            case .forceDelete, .forceRemoveWorktree, .forceRemoveSubmodule: true
            }
        }
    }

    struct Hint {
        var text: String?
        var action: Action?
    }

    static func hint(for failure: OperationFailure) -> Hint {
        if case .deleteBranch(let name, false) = failure.write, failure.message.contains("not fully merged") {
            return Hint(text: "\(name) has commits that no other branch has.", action: .forceDelete(name))
        }
        if case .removeWorktree(let path, false) = failure.write, failure.message.contains("modified or untracked") {
            return Hint(text: "The worktree has uncommitted changes or untracked files.",
                        action: .forceRemoveWorktree(path))
        }
        if case .removeSubmodule(let path, false) = failure.write, failure.message.contains("local modifications") {
            return Hint(text: "The submodule has uncommitted changes, untracked files or commits not recorded here.",
                        action: .forceRemoveSubmodule(path))
        }
        // Each failed submodule's git message is kept as text: a sign-in refusal among them gets the auth hint.
        if let update = failure.error as? SubmoduleUpdateFailure,
           update.failures.contains(where: { isAuthMessage($0.message) })
        {
            return Hint(text: authText + " " + submoduleAuthText)
        }
        // Fetch All with several remotes: one failed remote gets its own hint and action; several get the sign-in hint
        // once, then each other hint and each host without an account.
        if let fetch = failure.error as? RemoteFetchFailure {
            let failures = fetch.failures.map {
                OperationFailure(title: failure.title, write: failure.write, error: $0.error, message: failure.message)
            }
            if failures.count == 1, let only = failures.first { return hint(for: only) }
            var texts: [String] = []
            var notes: [String] = []
            for item in failures {
                if let withheld = item.error as? NetworkTokenWithheld, case .noAccount(let host) = withheld.reason {
                    texts.append(authText)
                    notes.append(noAccountText(host))
                } else if let text = hint(for: item).text {
                    texts.append(text)
                }
            }
            let unique = (texts + notes).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            return Hint(text: unique.isEmpty ? nil : unique.joined(separator: " "))
        }
        if let withheld = failure.error as? NetworkTokenWithheld {
            switch withheld.reason {
            case .repoNetworkConfig(let keys):
                return Hint(text: "This repository sets its own network settings (\(keys.joined(separator: ", "))), "
                    + "so Histq did not send your account token. Remove them from its config, or sign in with a "
                    + "credential helper of your own.")
            case .submoduleRecursion(let keys):
                return Hint(text: "Submodule recursion is on (\(keys.joined(separator: ", "))), so Histq did not send "
                    + "your account token. Turn it off, or sign in with a credential helper of your own.")
            case .noAccount(let host):
                return Hint(text: authText + " " + noAccountText(host))
            case .remoteGroup(let name):
                return Hint(text: "A remote group has the name \(name) (remotes.\(name) in your git config), so git "
                    + "fetches the group's remotes and Histq did not send your account token. Rename or remove the "
                    + "group, or sign in with a credential helper of your own.")
            }
        }
        if case GitOperationError.rebaseWouldConflict = failure.error {
            return Hint(text: "Commit or stash your changes, then rebase again to resolve the conflicts.")
        }
        guard let error = failure.error as? GitError else { return Hint() }
        switch error {
        case .auth:
            return Hint(text: authText + (isSubmoduleWrite(failure.write) ? " " + submoduleAuthText : ""))
        case .hostKey:
            if HostKeyTrust.isKeyChanged(error) {
                return Hint(text: "The host's SSH key has changed since the last connection. Someone may be intercepting "
                    + "it. Histq will not trust the new key: check it with the host, then fix ~/.ssh/known_hosts yourself.",
                    action: .checkHostKey)
            }
            return Hint(text: "This host's SSH key is not trusted yet. Compare its fingerprints before trusting it.",
                        action: .checkHostKey)
        case .nonFastForward:
            if case .push = failure.write {
                return Hint(text: "The remote has commits this branch does not have. Pull first, then push again.",
                            action: .pull)
            }
            return Hint(text: "The branches have diverged: this cannot be done as a fast-forward.")
        case .indexLock:
            return Hint(text: "Another git process holds the index (index.lock). Wait for it to finish; if no git is "
                + "running, delete .git/index.lock.")
        case .conflict:
            return Hint(text: "It stopped on conflicts. Resolve the conflicted files in the WIP panel, then commit.")
        case .timeout:
            return Hint(text: "Git took too long and was stopped.")
        case .autostashKept:
            return Hint(text: "Your changes could not all be put back, so they stay in that stash. Sort out the "
                + "working tree, then apply or drop the stash from the graph.")
        case .other, .launchFailed:
            return Hint()
        }
    }

    private static let authText = "Git could not sign in to the remote. Check that your SSH key is loaded (ssh-add) or "
        + "that a credential helper knows this host."

    /// Added to `authText` for an https remote on a host the tab's profile has no account for.
    private static func noAccountText(_ host: String) -> String {
        "\(host) has no account in this tab's profile: add one in Settings › Integrations, or use SSH."
    }
    static let submoduleAuthText =
        "Submodule fetches use your SSH key, or the connected account's token for https URLs on its host."

    private static func isSubmoduleWrite(_ write: RepoSession.Write) -> Bool {
        switch write {
        case .updateSubmodules, .syncSubmodules, .addSubmodule, .removeSubmodule, .setSubmoduleURL,
             .setSubmoduleBranch:
            true
        default: false
        }
    }

    /// git's sign-in refusals, as `GitError` classifies them (its classifier is internal to the core).
    static func isAuthMessage(_ message: String) -> Bool {
        let text = message.lowercased()
        return ["permission denied (publickey", "authentication failed", "could not read username",
                "could not read password", "terminal prompts disabled", "invalid username or password"]
            .contains { text.contains($0) }
    }

    @MainActor
    static func perform(_ action: Action, for failure: OperationFailure, in session: RepoSession) {
        switch action {
        case .checkHostKey:
            session.checkHostKey(for: failure)
        case .pull:
            session.pull(RepoSession.preferredPullMode)
        case .forceDelete(let name):
            session.confirm("Delete branch \(name) anyway?",
                            message: "Its commits that no other branch has will be lost.", button: "Delete Branch",
                            write: .deleteBranch(name, force: true), operation: "Delete branch \(name)")
        case .forceRemoveWorktree(let path):
            let name = URL(filePath: path).lastPathComponent
            let changes = session.worktrees.value?.first { $0.path == path }?.changes?.detail
            RepoMenus.confirmForceRemove(path, name: name, changes: changes, session)
        case .forceRemoveSubmodule(let path):
            session.confirm("Remove the submodule \(path) anyway?",
                            message: "Its folder with its uncommitted changes and untracked files, its clone in "
                                + ".git/modules and any commits not pushed from it are deleted. This cannot be undone.",
                            button: "Remove Submodule", write: .removeSubmodule(path, force: true),
                            operation: "Remove submodule \(path)")
        }
    }
}

// MARK: - Host key sheet

/// The host's SHA256 fingerprints to compare, and "Trust Host", which appends them to known_hosts. A changed key gets a
/// warning and no Trust button.
struct HostKeySheet: View {
    let session: RepoSession
    let check: HostKeyCheck
    let onClose: () -> Void

    var body: some View {
        ModalCard(title: check.isChanged ? "The host key has changed" : "Unknown host",
                  systemImage: check.isChanged ? "exclamationmark.octagon.fill" : "key.horizontal", width: 480,
                  takesFocus: true) {
            ModalSection(spacing: 10) {
                if let host = check.host {
                    Text(host.knownHostsName)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
                content
            }
        } actions: {
            Button(trustable == nil ? "Close" : "Cancel", action: onClose)
                .buttonStyle(RowTextButtonStyle(formRow: true))
                .keyboardShortcut(.cancelAction)
            if let scan = trustable {
                Button {
                    session.trustHost(scan)
                } label: {
                    HStack(spacing: 6) {
                        if case .trusting = check.state { ProgressView().controlSize(.mini) }
                        Text("Trust Host")
                    }
                }
                .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                .disabled(isTrusting)
            }
        }
    }

    /// The scan the user can trust: never for a changed key.
    private var trustable: HostKeyTrust.Scan? {
        guard !check.isChanged else { return nil }
        switch check.state {
        case .scanned(let scan), .trusting(let scan): return scan
        default: return nil
        }
    }

    private var isTrusting: Bool {
        if case .trusting = check.state { true } else { false }
    }

    @ViewBuilder private var content: some View {
        switch check.state {
        case .scanning:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the host's keys…").foregroundStyle(.secondary)
            }
        case .changed:
            Text("ssh reports that this host now has another key than the one in ~/.ssh/known_hosts. This can mean "
                + "someone is intercepting the connection. Histq will not replace the key: confirm the new key with the "
                + "host's administrator, then remove the old line from ~/.ssh/known_hosts yourself.")
                .foregroundStyle(Color(nsColor: Palette.graphLanes[6]))
                .fixedSize(horizontal: false, vertical: true)
        case .scanned(let scan), .trusting(let scan):
            Text("Compare these fingerprints with the ones the host publishes (for GitHub: its \"SSH key fingerprints\" "
                + "page). Trusting adds these keys to ~/.ssh/known_hosts.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(scan.keys, id: \.line) { key in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(key.type).font(.settingsCaption).foregroundStyle(.secondary)
                        Text(key.fingerprint).font(.body.monospaced()).textSelection(.enabled)
                    }
                }
            }
        case .failed(let message):
            ErrorText(message: message)
        }
    }
}
