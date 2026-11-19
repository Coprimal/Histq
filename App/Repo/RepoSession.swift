// One tab's repository: its git runner, what it has read (status, refs, the log and its graph layout), the selected
// detail with its loading state, and the watcher that keeps them current. Every git call runs off the main actor;
// the main actor only publishes results.
import CryptoKit
import Foundation
import HistqCore
import os

/// The git executable and the read base environment, resolved off the main actor (`git --version` from the fixed
/// folders, never the login shell) and kept, a failure too, until `reset()`. Reads and writes run the same git.
/// Writes and network commands take `writeBase()`: the login shell's PATH, cached in `StatePaths.root`.
/// `prepare()` starts both at launch.
enum GitToolchain {
    struct Resolved: Sendable {
        let executable: GitExecutable
        /// `GitInvocation.baseEnvironment()` with the fixed PATH: what every automatic read starts from. Never
        /// for writes or network commands: use `writeBase()`.
        let readBase: [String: String]
    }

    /// The login shell's PATH for writes, cached across launches; the shell runs once per launch.
    private static let loginPath = LoginShellPath(
        cacheFile: StatePaths.root.appending(path: "login-path", directoryHint: .notDirectory))

    /// What write and network commands (clone, init, fetch, push, commit) start from: the login shell's PATH, so
    /// git-lfs, gpg, credential helpers and hooks find the user's tools. The cached PATH at once, else it waits for
    /// the login shell (seconds).
    static func writeBase() async -> [String: String] {
        GitInvocation.baseEnvironment(path: await loginPath.value())
    }

    /// The resolution in flight or done; nil after `reset()`, until the next `resolve()` starts a new one.
    private static let current = OSAllocatedUnfairLock<Task<Resolved, Error>?>(initialState: nil)

    /// Starts resolving git and the login shell's PATH; call once at launch so the first repo does not wait for it.
    static func prepare() {
        _ = task()
        loginPath.prepare()
    }

    static func resolve() async throws -> Resolved { try await task().value }

    /// Forgets the result, so the next `resolve()` looks for git again: after the `gitPath` preference changed or
    /// the Command Line Tools were installed. Sessions whose setup failed retry on their next load. The login
    /// shell's PATH is kept.
    static func reset() {
        current.withLock { $0 = nil }
    }

    private static func task() -> Task<Resolved, Error> {
        current.withLock { task in
            if let task { return task }
            let new = Task.detached(priority: .userInitiated) { () async throws -> Resolved in
                let override = Preferences.defaults.string(forKey: PrefKey.gitPath.rawValue)
                let executable = try await GitExecutable.resolve(override: override)
                return Resolved(executable: executable, readBase: GitInvocation.baseEnvironment())
            }
            task = new
            return new
        }
    }
}

/// What the graph leaves out and pins, from a `RepoViewState` against the refs it was resolved with
/// (`RepoSession.logFilter(view:refs:)`).
struct LogFilter: Equatable, Sendable {
    /// Full ref names left out of the graph (its log, its badges) and of the sidebar's lists: the hidden branches and
    /// tags, the own upstreams of the hidden local branches and, with "hide stale branches" on, the stale branches.
    /// Never the current branch, nor its upstream unless hidden itself.
    var hidden: Set<String> = []
    /// Full ref names: when any, the graph reads only them and HEAD.
    var solo: [String] = []
    /// The pinned branches' tip hashes, in pin order, one each: `GraphLayout(pinned:)`.
    var pinned: [String] = []
}

/// The log of a repo with its graph rows, in its `order` (git's `--date-order` or `--topo-order`; after an incremental
/// reload, the new commits merged in, see `RepoSession.readLogIncrementally`). `rows[i]` is `commits[i]`'s row; the
/// WIP row above the commits is in `syntheticRows`, the other worktrees' and the stash rows in `hung`, each right above
/// its base.
struct LogSnapshot: Sendable {
    var commits: [Commit] = []
    var rows: [GraphRow] = []
    /// Laid out before the commits, shown above them: the WIP row when the working tree has changes; once the log is
    /// complete, the other worktrees' and stash rows whose base is not in it (without a line).
    var syntheticRows: [GraphRow] = []
    /// The other worktrees' rows, then the stash rows (newest first), each laid out right above its base commit; top
    /// first.
    var hung: [GraphHungRow] = []
    /// What the synthetic rows were laid out from (`RepoSession.syntheticRows(status:stashes:worktrees:)`).
    var synthetic: [GraphSyntheticRow] = []
    /// The stashes of the stash rows, newest first.
    var stashes: [Stash] = []
    /// `commits`' index of each hash, filled with the pages off the main actor: a click finds its commit's header here.
    var commitIndex: [String: Int] = [:]
    /// Once the log is complete, the hashes of its commits no other commit lists as a parent
    /// (`LogReader.tips(of:index:)`): an incremental reload reads only what is new since them.
    var tips: [String] = []
    /// The most lanes a row of `syntheticRows`, `rows` or `hung` draws in (`GraphRow.width`), kept with the rows off
    /// the main actor: the graph column fits it without going over every row.
    var lanes = 0
    /// The other worktrees with changes whose WIP rows are laid out (after the WIP row, before the stashes).
    var worktrees: [WorktreeInfo] = []
    /// Every page has been parsed and laid out; false while only the first pages are in.
    var isComplete = false
    /// The repo was shallow when the log was read (`<common dir>/shallow`): a deepening fetch gives old commits new
    /// parents, so a reload reads the whole history again rather than only the new commits.
    var isShallow = false
    /// The same for every snapshot of one load (its first page, then the whole log), new for each load: the graph
    /// inserts the rows a snapshot of the same load adds and reloads for a new one.
    var generation = 0
    /// The hidden, soloed and pinned branches the log was read and laid out with.
    var filter = LogFilter()
    /// The order the log was read in (`PrefKey.commitOrder`).
    var order = LogReader.Order.date
    /// Timing only: the step times of the incremental read that made it (`readLogIncrementally`), for its
    /// `log-reload` line.
    var readSteps = ""

    /// What a table row of the graph shows.
    enum Entry {
        case synthetic(GraphSyntheticRow, GraphRow)
        /// `commits[index]`.
        case commit(Int)
    }

    /// The graph's table rows: the top rows, then the commits with the stash rows between them.
    var rowCount: Int { syntheticRows.count + hung.count + commits.count }

    func entry(at row: Int) -> Entry? {
        guard row >= 0 else { return nil }
        if row < syntheticRows.count {
            let graphRow = syntheticRows[row]
            guard case .synthetic(let synthetic) = graphRow.node else { return nil }
            return .synthetic(synthetic, graphRow)
        }
        let position = row - syntheticRows.count
        var above = 0
        for (offset, hung) in hung.enumerated() {
            let at = hung.above + offset
            if at == position { return .synthetic(hung.synthetic, hung.row) }
            if at > position { break }
            above += 1
        }
        let index = position - above
        return index < commits.count ? .commit(index) : nil
    }

    /// The graph row drawn at table row `row`.
    func graphRow(at row: Int) -> GraphRow? {
        switch entry(at: row) {
        case .synthetic(_, let graphRow): graphRow
        case .commit(let index): rows[index]
        case nil: nil
        }
    }

    /// The table row of `commits[index]`.
    func row(ofCommit index: Int) -> Int {
        syntheticRows.count + index + hung.prefix { $0.above <= index }.count
    }

    /// The table row of the first synthetic row that matches.
    func row(where matches: (GraphSyntheticRow) -> Bool) -> Int? {
        if let top = syntheticRows.firstIndex(where: { if case .synthetic(let s) = $0.node { matches(s) } else { false } }) {
            return top
        }
        return hung.firstIndex { matches($0.synthetic) }.map { syntheticRows.count + hung[$0].above + $0 }
    }
}

/// Which branch each commit of a log snapshot is on (`BranchAttribution.claims`), for the graph's faded badge:
/// `claims[i]` is `commits[i]`'s branch, an index into `names` (-1 for none). `logGeneration` and `claims.count` tell
/// the snapshot it was computed for; `generation` is new for each computed map: the graph compares it, never the claims.
struct BranchMap: Sendable {
    var names: [String] = []
    var claims: [Int32] = []
    var logGeneration = -1
    var generation = 0

    /// The branch of `commits[index]` in `log`, if this map was computed for `log`'s commits.
    func branch(at index: Int, in log: LogSnapshot) -> String? {
        guard logGeneration == log.generation, claims.count == log.commits.count, claims.indices.contains(index),
              claims[index] >= 0
        else { return nil }
        return names[Int(claims[index])]
    }
}

/// A commit or a stash as the detail panel shows it: its message, people, dates, parents and changed files (against
/// its first parent; a stash adds the untracked files it saved).
struct CommitDetail: Sendable {
    let hash: String
    /// First parent first. A stash's are its base, its index commit and, with untracked files, their commit.
    let parents: [String]
    let authorName: String
    let authorEmail: String
    let authorDate: Date
    let committerName: String
    let committerEmail: String
    let committerDate: Date
    let subject: String
    let body: String
    /// Nil while they load: a header built from the log's commit (`init(header:)`) shows in the click's frame.
    let files: [FileChange]?
    let isStash: Bool
}

extension CommitDetail {
    /// The log's commit as a detail whose files are still loading.
    init(header commit: Commit) {
        self.init(
            hash: commit.hash, parents: commit.parents, authorName: commit.authorName, authorEmail: commit.authorEmail,
            authorDate: commit.authorDate, committerName: commit.committerName, committerEmail: commit.committerEmail,
            committerDate: commit.committerDate, subject: commit.subject, body: commit.body, files: nil, isStash: false)
    }

    /// This detail with `files`.
    func with(files: [FileChange]) -> CommitDetail {
        CommitDetail(
            hash: hash, parents: parents, authorName: authorName, authorEmail: authorEmail, authorDate: authorDate,
            committerName: committerName, committerEmail: committerEmail, committerDate: committerDate,
            subject: subject, body: body, files: files, isStash: isStash)
    }
}

/// The last commit details read, `capacity` at most, the least recently used dropped first. Commits never change, so
/// an entry is never stale.
struct CommitDetailCache {
    struct Key: Hashable {
        let hash: String
        let isStash: Bool
    }

    static let capacity = 200
    private var entries: [Key: CommitDetail] = [:]
    /// Least recently used first.
    private var order: [Key] = []

    /// The detail of `key`, now the most recently used.
    mutating func value(_ key: Key) -> CommitDetail? {
        guard let detail = entries[key] else { return nil }
        touch(key)
        return detail
    }

    /// Whether `key` is kept, without making it the most recently used.
    func contains(_ key: Key) -> Bool {
        entries[key] != nil
    }

    /// Keeps `detail` once its files are read.
    mutating func insert(_ detail: CommitDetail) {
        guard detail.files != nil else { return }
        let key = Key(hash: detail.hash, isStash: detail.isStash)
        if entries.updateValue(detail, forKey: key) != nil {
            touch(key)
            return
        }
        order.append(key)
        if order.count > Self.capacity { entries[order.removeFirst()] = nil }
    }

    private mutating func touch(_ key: Key) {
        if let index = order.lastIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }
}

/// The diffs of commits' files read lately (a commit's diff never changes), so a file history row clicked again, or
/// prefetched, shows its diff in the click's frame. Bounded by the rows kept, not by the diffs: one big file weighs
/// as much as many small ones.
struct FileDiffCache {
    struct Key: Hashable {
        let target: FileTarget
        let ignoresWhitespace: Bool
    }

    static let rowCapacity = 100_000
    private var entries: [Key: (detail: FileDiffDetail, rows: Int)] = [:]
    /// Least recently used first.
    private var order: [Key] = []
    private var rows = 0

    /// The diff of `key`, now the most recently used.
    mutating func value(_ key: Key) -> FileDiffDetail? {
        guard let entry = entries[key] else { return nil }
        if let index = order.lastIndex(of: key) { order.remove(at: index) }
        order.append(key)
        return entry.detail
    }

    func contains(_ key: Key) -> Bool {
        entries[key] != nil
    }

    /// Keeps `detail`, dropping the least recently used diffs over `rowCapacity`. Only a commit's file is kept, and
    /// never an image's versions (decoded bitmaps, far heavier than their row count) or a submodule's pointer change
    /// (its commits depend on the submodule's checkout, which a fetch or an update changes).
    mutating func insert(_ detail: FileDiffDetail, for key: Key) {
        guard case .commit = key.target.source, !key.target.file.isSubmodule, entries[key] == nil else { return }
        let weight = switch detail.content {
        case .sections(let sections): sections.reduce(1) { $0 + $1.rows.count + $1.fullRows.count + $1.splitRows.count }
        case .images: Self.rowCapacity + 1
        default: 1
        }
        guard weight <= Self.rowCapacity else { return }
        entries[key] = (detail, weight)
        order.append(key)
        rows += weight
        while rows > Self.rowCapacity, !order.isEmpty {
            rows -= entries.removeValue(forKey: order.removeFirst())?.rows ?? 0
        }
    }
}

/// The head of one `git diff --raw` record, `:<old mode> <new mode> <old sha> <new sha> <status>` (its path follows,
/// after a NUL with `-z`).
struct RawDiffRecord {
    private static let gitlinkMode = "160000"

    let oldMode: String
    let newMode: String
    let oldSHA: String
    let newSHA: String
    /// `M`, `A`, `D`, `T`, `R100`, `C75`.
    let status: String

    init?(_ record: String) {
        guard record.first == ":" else { return nil }
        let parts = record.dropFirst().split(separator: " ").map(String.init)
        guard parts.count == 5 else { return nil }
        (oldMode, newMode, oldSHA, newSHA, status) = (parts[0], parts[1], parts[2], parts[3], parts[4])
    }

    /// A submodule's pointer (mode 160000) on either side.
    var isGitlink: Bool { oldMode == Self.gitlinkMode || newMode == Self.gitlinkMode }

    /// The commits the first record's gitlink points to before and after (nil on a side with no gitlink: added,
    /// removed, or a type change); nil when that record is no gitlink. `output` is `--raw -z`.
    static func gitlinks(in output: Data) -> (from: String?, to: String?)? {
        guard let first = output.split(separator: 0).first,
              let record = RawDiffRecord(String(decoding: first, as: UTF8.self)), record.isGitlink
        else { return nil }
        return (record.oldMode == gitlinkMode ? record.oldSHA : nil,
                record.newMode == gitlinkMode ? record.newSHA : nil)
    }
}

/// A worktree of the repo as the sidebar card and the graph show it.
struct WorktreeInfo: Hashable, Sendable {
    let worktree: Worktree
    /// The tab's own worktree: its changes are `RepoSession.status`, never read here.
    let isCurrent: Bool
    /// Another worktree's uncommitted changes; nil for the current one, a bare or missing one, or one whose status
    /// could not be read.
    let changes: WorktreeChanges?

    var path: String { worktree.path }
    /// The folder's name: the graph row's label and the sidebar row's title.
    var name: String { URL(filePath: worktree.path).lastPathComponent }
    /// Its branch (`wt`), or its short HEAD when detached.
    var headLabel: String {
        if let branch = worktree.branch { return RefBadge.shortBranch(branch) }
        return worktree.head.map { String($0.prefix(7)) } ?? (worktree.isBare ? "bare" : "")
    }
    var isDirty: Bool { changes?.isEmpty == false }
}

/// A working tree's change counts: "3 unstaged · 2 staged" (untracked and conflicted files count as unstaged), and the
/// WIP row's edited, added and deleted files (each file once, staged or not).
struct WorktreeChanges: Hashable, Sendable {
    let unstaged: Int
    let staged: Int
    /// Modified, renamed, copied, type-changed or conflicted files.
    let edited: Int
    /// New files: added (staged, or `git add -N`) or untracked.
    let added: Int
    let deleted: Int

    init(_ status: WorkingStatus) {
        var unstaged = 0
        var staged = 0
        var edited = 0
        var added = 0
        var deleted = 0
        for entry in status.entries where entry.kind != .ignored {
            if entry.isStaged { staged += 1 }
            if entry.isUnstaged || entry.kind == .untracked || entry.kind == .unmerged { unstaged += 1 }
            // A conflict's letters are both sides' (`DU`, `AA`): it is edited.
            if entry.kind == .unmerged {
                edited += 1
            } else if entry.index == .deleted || entry.worktree == .deleted {
                deleted += 1
            } else if entry.kind == .untracked || entry.index == .added || entry.worktree == .added {
                added += 1
            } else {
                edited += 1
            }
        }
        self.unstaged = unstaged
        self.staged = staged
        self.edited = edited
        self.added = added
        self.deleted = deleted
    }

    /// "5 edited · 1 added": the WIP row's counts as text (its tooltip and accessibility label).
    var kindSummary: String {
        var parts: [String] = []
        if edited > 0 { parts.append("\(edited) edited") }
        if added > 0 { parts.append("\(added) added") }
        if deleted > 0 { parts.append("\(deleted) deleted") }
        return parts.joined(separator: " · ")
    }

    var isEmpty: Bool { unstaged == 0 && staged == 0 }

    var detail: String {
        var parts: [String] = []
        if unstaged > 0 { parts.append("\(unstaged) unstaged") }
        if staged > 0 { parts.append("\(staged) staged") }
        return parts.joined(separator: " · ")
    }
}

/// A remote and its fetch URL.
struct RemoteInfo: Hashable, Sendable {
    let name: String
    let url: String
}

extension Refs {
    /// These refs without the ones `hidden` names (full ref names); the checked-out branch always stays.
    func hiding(_ hidden: Set<String>) -> Refs {
        guard !hidden.isEmpty else { return self }
        return Refs(
            head: head,
            localBranches: localBranches.filter { $0.isHead || !hidden.contains($0.refName) },
            remoteBranches: remoteBranches.filter { !hidden.contains($0.refName) },
            tags: tags.filter { !hidden.contains($0.refName) })
    }
}

/// The undo journal's next entries (their titles, `Commit "Fix login"`), or that the journal cannot be read.
struct UndoStatus: Equatable, Sendable {
    var undo: String?
    var redo: String?
    /// What Undo and Redo do while the merge, rebase, cherry-pick or revert in progress is stopped: its resolved files.
    var resolveUndo: String?
    var resolveRedo: String?
    var isUnreadable = false

    init() {}

    /// Reads the journal file without the stage and unstage entries the index moved on from, which Undo and Redo skip
    /// (`UndoJournal.load(_:)`), so the titles name what they will do (off the main actor: file I/O and git).
    nonisolated init(_ journal: UndoJournal, ops: GitOperations) async {
        do {
            let state = try await journal.load(ops)
            undo = state.nextUndo?.title
            redo = state.nextRedo?.title
            resolveUndo = state.nextResolveUndo?.title
            resolveRedo = state.nextResolveRedo?.title
        } catch {
            isUnreadable = true
        }
    }
}

/// What a write did, for its toast.
enum WriteOutcome: Equatable, Sendable {
    case done
    /// A pull or an interactive rebase stopped (on conflicts, at an `edit`); git holds the local changes until it is
    /// continued or aborted.
    case autostashPending
    /// A stash apply or pop: whether it applied cleanly and undo can take it back.
    case stash(GitOperations.StashApplyOutcome, pop: Bool)
    /// A patch applied to the working tree: plainly, with a 3-way merge, or with conflicts.
    case patch(GitOperations.PatchApplyOutcome)
}

/// A user operation in flight: what the action bar shows while it runs.
struct RunningOperation: Identifiable, Hashable {
    let id: Int
    /// "Pull", "Merge develop into main".
    let title: String
    /// The action bar button that shows its progress, if it started there.
    let key: ActionBarAction?
}

/// A user operation that failed, shown in its toast, with the write (to retry it or force it) and the error
/// (`GitError` cases get a hint).
struct OperationFailure: Identifiable {
    let id = UUID()
    let title: String
    let write: RepoSession.Write
    let error: Error
    let message: String
}

/// The Apply Patch preview (`ApplyPatchModal`): a patch from a file or the clipboard, `source` its label (the file's
/// name, "Clipboard"). Loading until `data` and `preview` are read, or `error` says why it cannot be applied.
struct PatchPreviewRequest: Identifiable {
    let id = UUID()
    var source: String
    /// The patch as `PatchFile.validate` returned it: what the apply writes take.
    var data: Data?
    var preview: PatchPreview?
    var error: String?

    var isLoading: Bool { preview == nil && error == nil }
}

/// A tool panel2 shows instead of the graph: a file's history (of `rev`, HEAD when nil; across renames with `follow`),
/// its blame (at `rev`, the working tree when nil) or HEAD's reflog. `path` is root-relative.
enum RepoTool: Equatable, Sendable {
    case fileHistory(path: String, rev: String?, follow: Bool)
    case blame(path: String, rev: String?)
    case reflog

    /// The timing log's detail: `history src/app.swift`, `blame src/app.swift`.
    var timingDetail: String {
        switch self {
        case .fileHistory(let path, _, _): "history \(path)"
        case .blame(let path, _): "blame \(path)"
        case .reflog: "reflog"
        }
    }
}

/// What a tool read: the file's commits, newest first, its blame or the reflog; a blame refuses a binary file and one
/// over `RepoSession.fileSizeLimit` (its size in bytes), as the diff does.
enum ToolContent: Sendable {
    case history([FileHistoryEntry])
    case blame([BlameGroup])
    case reflog([ReflogEntry])
    case binary
    case tooLarge(Int)
}

/// One tab's repository. `select(_:)` switches the detail at once (`detail` becomes `.loading` in the same call)
/// and loads it in a cancellable task; a newer select cancels the older load. `refresh(scope:)` rereads status, refs
/// or the log (the watcher calls it). All git runs on `GitRunner`, with the read environment for this folder.
@Observable
@MainActor
final class RepoSession: Identifiable {
    /// What the detail area shows.
    enum Selection: Hashable, Sendable {
        /// Nothing picked yet (a tab just opened): it loads as the WIP when the working tree has changes, else as
        /// HEAD's commit, and `selection` becomes that; the overview cards only for an unborn branch.
        case overview
        /// The working tree: unstaged and staged files, the commit box.
        case wip
        case commit(String)
        /// A stash, by its commit hash.
        case stash(String)
        /// Several graph rows; the count.
        case multiple(Int)
        /// A sidebar ref picked before the refs were read (a launch request): it loads as its commit, and
        /// `selection` becomes `.commit` with the graph on that row.
        case ref(SidebarItem)
        /// Another worktree's changes (its graph row), by its path.
        case worktree(String)
        /// `base` against `head` (commit hashes or ref names), or against the working tree when `head` is nil.
        case compare(base: String, head: String?)
        /// A submodule's state and its commits (its sidebar row), by its path.
        case submodule(String)
    }

    /// The loaded detail of a selection; the views read `status`, `refs` and `log` for its values.
    enum Detail: Sendable {
        /// The overview cards (an unborn branch: no commit, no change).
        case overview
        /// The WIP panel, which reads the live `status`.
        case wip
        /// A commit or a stash.
        case commit(CommitDetail)
        /// Several graph rows (`graphSelection` at the select, graph order), the diff they show together
        /// (`RepoMenus.combinedDiff`, nil for none) and its files (nil without a diff).
        case multiple([GraphItem], diff: CombinedDiff?, files: [FileChange]?)
        /// Another worktree's changes, read-only: its path and its status.
        case worktree(String, WorkingStatus)
        /// A compare's files (`base` against `head`, nil for the working tree; untracked files left out).
        case compare(base: String, head: String?, files: [FileChange])
        case submodule(SubmoduleDetail)

        /// False for a commit whose files are still loading.
        var isReady: Bool {
            if case .commit(let commit) = self { return commit.files != nil }
            return true
        }
    }

    /// The diff a multi-row selection shows: `base` against `head` (nil for the working tree). `isRange`: the selected
    /// commits' changes together (a first-parent chain, `base` the oldest one's parent); else the difference between
    /// two rows (`RepoMenus.comparePair`).
    struct CombinedDiff: Hashable, Sendable {
        let base: String
        let head: String?
        let isRange: Bool
    }

    /// A user-initiated write (the WIP panel, the action bar, the menus and dialogs), run by `perform` with the write
    /// environment through `GitOperations`. Names come from the refs or from a dialog; the operations validate new
    /// names and put `--end-of-options` / `--` where they belong.
    enum Write: Sendable {
        case stage([String])
        case stageAll
        case unstage([String])
        case unstageAll
        /// Tracked files: their working tree takes the index version.
        case discard([String])
        /// Untracked files: deleted.
        case removeUntracked([String])
        /// Index and tracked files back to HEAD (`reset --hard`), untracked files too when asked.
        case discardAll(includingUntracked: Bool)
        case commit(message: String)
        case amend(message: String)
        /// The message of HEAD (full id, the commit the editor opened on): only the message changes, not the index.
        case editMessage(commit: String, message: String)
        /// Selected lines of a diff (`PatchBuilder.patch`): staged, unstaged or discarded with `git apply`.
        case applyPatch(Data, PatchBuilder.Action)
        /// A patch file (a diff or a mail series) applied to the working tree, not journaled: plain `git apply`, else
        /// `--3way` (`GitOperations.applyPatchToWorkingTree`).
        case applyPatchToWorkingTree(Data)
        /// A mail series of `count` patches applied as commits with `git am --3way`; a conflict leaves the am in
        /// progress for the operation banner.
        case applyPatchCommits(Data, count: Int)

        case checkoutBranch(String, autostash: Bool = false)
        /// A local branch `localName` tracking the remote branch (`origin/x`), checked out.
        case checkoutTracking(remoteBranch: String, as: String, autostash: Bool = false)
        /// A detached HEAD.
        case checkoutCommit(String)
        case checkoutFiles([String], from: String)
        /// A GitHub pull request's Checkout locally: fetches `pull/<n>/head` from `remote` into the new branch `pr/<n>`
        /// (never over an existing one: the PR detail checks that first), then checks it out.
        case checkoutPullRequest(number: Int, remote: String)

        case fetchAll(prune: Bool)
        /// `autostash`: `--autostash` (git stashes the local changes and puts them back after the pull).
        case pull(GitOperations.PullMode, autostash: Bool = false)
        /// A branch that is not checked out, fast-forwarded to `remoteBranch` of `remote` (its upstream) by a fetch
        /// straight into it; git refuses anything but a fast-forward.
        case pullBranch(String, remote: String, remoteBranch: String)
        case push(branch: String, remote: String, remoteBranch: String?, setUpstream: Bool, forceWithLease: String?)
        case pushTag(String, remote: String)
        case pushMirror(remote: String)
        case deleteRemoteBranch(String, remote: String)
        /// A local branch and its upstream `remoteBranch` on `remote`, both at the same commit: the local one first
        /// (`branch -d`, which git checks against the upstream still there), then the remote one.
        case deleteBranchAndRemote(String, remote: String, remoteBranch: String)
        case deleteRemoteTag(String, remote: String)

        case createBranch(String, from: String, checkout: Bool)
        case renameBranch(String, to: String)
        case deleteBranch(String, force: Bool)
        case setUpstream(branch: String, upstream: String)

        case addRemote(String, url: String)
        case removeRemote(String)
        case renameRemote(String, to: String)
        case setRemoteURL(String, url: String)

        /// A worktree at `path` (absolute, new) checking out `source`, or a new branch started there.
        case addWorktree(path: String, source: GitOperations.WorktreeSource, newBranch: String?)
        /// A linked worktree by its listed path; `force` loses its changes (only after the user chose that).
        case removeWorktree(String, force: Bool)
        case pruneWorktrees

        /// The submodules at these paths (empty = all) checked out at their recorded commits, nested ones too;
        /// `initialize` runs `git submodule init` first.
        case updateSubmodules([String], initialize: Bool)
        /// The URLs of `.gitmodules` copied into the config and each submodule's remote (empty = all).
        case syncSubmodules([String])
        /// A new submodule cloned from `url` at `path` (staged), on `branch` (nil = the remote's default).
        case addSubmodule(url: String, path: String, branch: String?, recursive: Bool)
        /// `force` loses its local changes and unpushed commits (only after the user chose that).
        case removeSubmodule(String, force: Bool)
        case setSubmoduleURL(String, url: String)
        /// An empty `branch`: the remote's default branch.
        case setSubmoduleBranch(String, branch: String)

        /// `git commit-graph write` (Optimize Repository): no timeout, no undo entry.
        case optimizeRepository
        /// One line (a `GitOperations.ignorePattern`) added to `.gitignore` or `.git/info/exclude`: no undo entry.
        case ignore(pattern: String, in: GitOperations.IgnoreFile)

        /// Merges `revision` into the current branch; `checkoutFirst` switches to that branch first; nil `mode` lets
        /// git's config decide. A fast-forward-only merge into `checkoutFirst` that has diverged from `revision` is
        /// refused before the checkout.
        case merge(String, checkoutFirst: String?, mode: GitOperations.MergeMode?)
        /// Rebases the current branch onto `upstream`; `checkoutFirst` switches to that branch first.
        case rebase(onto: String, checkoutFirst: String?)
        /// Fast-forwards the local branch to a full ref (`refs/heads/x`, `refs/remotes/origin/x`).
        case fastForward(String, to: String)
        case cherryPick(String, mainline: Int?)
        case revert(String, mainline: Int?)
        case reset(to: String, mode: GitOperations.ResetMode)

        case stashPush(message: String?)
        /// Only these paths (a WIP file or folder, untracked ones too); the whole index is recorded in the stash.
        case stashPaths([String])
        /// By the stash's commit hash: its `stash@{n}` is looked up when it runs, so a stale index never hits
        /// another stash.
        case stashApply(hash: String)
        case stashPop(hash: String)
        case stashDrop(hash: String)
        /// One file of a stash written to the working tree; `untracked`: from its untracked-files commit.
        case stashRestoreFile(hash: String, path: String, untracked: Bool)

        /// Annotated when `message` is given.
        case createTag(String, at: String, message: String?)
        case deleteTag(String)

        /// A conflicted file resolved by the conflict editor: `content` written to it (atomically, keeping its mode),
        /// or the file deleted when nil, then `git add` so the path leaves the unmerged list.
        case resolveConflict(path: String, content: Data?)
        /// The conflict editor's Create Conflict Chunks: `content` (git's conflict markers) written to a conflicted file
        /// like `resolveConflict`, without `git add`, so the path stays conflicted.
        case writeConflictChunks(path: String, content: Data)
        /// `git mergetool` on one conflicted path: `tool` is `PrefKey.mergeTool`, nil for git's configured tool. It runs
        /// the repo's configured merge command, so only on the user's click.
        case mergeTool(path: String, tool: String?)

        /// The operation banner's buttons: `git <merge|rebase|cherry-pick|revert> --continue|--abort|--skip` (never
        /// waits for an editor: `GitOperations` passes `-c core.editor=true`).
        case continueOperation(RepoState.Operation)
        case abortOperation(RepoState.Operation)
        case skipOperation(RepoState.Operation)

        /// The undo journal's next entry taken back, or the last undone one replayed (Undo / Redo, ⌘Z / ⇧⌘Z).
        case undo
        case redo
        /// An interactive rebase or a squash (the rebase sheet); its todo and message files go to the tab's rebase folder.
        case interactiveRebase(RebaseTodo)

        /// The remote a network write talks to, for the host-key check of its failure.
        var remote: String? {
            switch self {
            case .push(_, let remote, _, _, _), .pushTag(_, let remote), .pushMirror(let remote),
                 .deleteRemoteBranch(_, let remote), .deleteBranchAndRemote(_, let remote, _),
                 .deleteRemoteTag(_, let remote), .checkoutPullRequest(_, let remote), .pullBranch(_, let remote, _):
                remote
            default:
                nil
            }
        }

        /// What the journal cannot take back about this write (the greyed Undo's tooltip); nil for a local write.
        var notUndoable: UndoJournal.NotUndoable? {
            switch self {
            case .push, .pushMirror: .push
            case .fetchAll: .fetch
            case .pull, .pullBranch: .pull
            case .deleteRemoteBranch, .deleteBranchAndRemote: .deleteRemoteBranch
            case .deleteRemoteTag: .deleteRemoteTag
            case .pushTag: .pushTag
            default: nil
            }
        }

        /// The writes that talk to a remote: the only ones that read the profile's GitHub token.
        var isNetwork: Bool {
            switch self {
            case .fetchAll, .pull, .pullBranch, .push, .pushTag, .pushMirror, .deleteRemoteBranch,
                 .deleteBranchAndRemote, .deleteRemoteTag, .checkoutPullRequest, .updateSubmodules, .addSubmodule:
                true
            default: false
            }
        }
    }

    let id = UUID()
    /// The folder the tab opened.
    let url: URL
    private(set) var selection: Selection = .overview
    private(set) var detail: Loadable<Detail> = .idle
    /// Changes with every `select`, even of the same selection: the placeholder logs a line per select.
    private(set) var selectToken = 0
    /// The timing log's detail of the last select (`wip`, `commit <hash>`, `overview <repo>`): its placeholder,
    /// spinner and content lines carry it.
    private(set) var selectDetail = ""
    /// The graph's selected rows, in row order. The graph follows it (a parent jump, the default selection), and a
    /// click in the graph sets it through `selectGraph(_:)`.
    private(set) var graphSelection: [GraphItem] = []
    /// The WIP panel's commit box, kept while other rows are selected.
    var commitDraft = CommitDraft()
    private(set) var status: Loadable<WorkingStatus> = .idle
    /// Counts the status reads, even those that found the same status (an edit to a file already modified): the WIP
    /// panel reads its files' sizes again on each.
    private(set) var statusReads = 0
    private(set) var refs: Loadable<Refs> = .idle
    private(set) var log: Loadable<LogSnapshot> = .idle {
        didSet { graphSearch.logDidChange() }
    }
    /// The graph's ⌘F search (`GraphSearch`): searched again with every new log snapshot.
    let graphSearch = GraphSearch()
    /// The branch each commit of `log` is on, computed off the main actor for each log snapshot and refs change.
    private(set) var branchMap = BranchMap()
    /// The merge, rebase, cherry-pick or revert in progress (the operation banner), read with every status read; nil
    /// until the first one.
    private(set) var repoState: RepoState?

    /// The sidebar's tab, its selected row and its expanded section cards, kept per tab. A click sets them at once; the
    /// branch actions come in Phase 5.
    private(set) var sidebarTab: SidebarTab = .branches
    private(set) var sidebarSelection: SidebarItem?
    var localExpanded = true
    var remoteExpanded = true
    var tagsExpanded = true
    var worktreesExpanded = true
    var submodulesExpanded = true
    /// The Stashes card, last in the Branches tab: collapsed until opened.
    var stashesExpanded = false
    /// The Local, Remote and Tags cards list their hidden rows too (dimmed), so they can be shown again: the card
    /// header's eye button.
    var localShowsHidden = false
    var remoteShowsHidden = false
    var tagsShowHidden = false

    /// The repo's worktrees (the main one first) with the other worktrees' change counts: read after the first log
    /// page, so they never delay the tab's first content, then with every refs read and when the tab is shown again.
    private(set) var worktrees: Loadable<[WorktreeInfo]> = .idle
    /// The repo's submodules, nested ones included: read after the first log page, then with every status or refs read
    /// (a write rereads both). `.loaded([])` without a read when the repo has no `.gitmodules`.
    private(set) var submodules: Loadable<[Submodule]> = .idle
    /// Opens a folder in a tab of this tab's window, selecting the tab that already shows it (a worktree's "Open in
    /// New Tab", a double-click on its sidebar row). Set by `WindowModel` when it makes the session.
    @ObservationIgnored var openInTab: @MainActor (URL) -> Void = { _ in }
    /// Opens another repo in a tab of this tab's window, outside this tab's group (a submodule's "Open in New Tab").
    /// Set by `WindowModel` when it makes the session.
    @ObservationIgnored var openRepoInTab: @MainActor (URL) -> Void = { _ in }
    /// Shows an operation's outcome as a toast in the tab's window (`ToastHost`). Set by `WindowModel` when it makes
    /// the session.
    @ObservationIgnored var postToast: @MainActor (OperationToast) -> Void = { _ in }
    /// Closes the tabs of a worktree this tab just removed (its folder is gone). Set by `WindowModel` when it makes the
    /// session.
    @ObservationIgnored var worktreeRemoved: @MainActor (String) -> Void = { _ in }

    /// The repo's remotes and their fetch URLs (`git remote -v`), read with the refs: a remote with no fetched branch
    /// shows too.
    private(set) var remotes: [RemoteInfo] = []
    /// The operations started from the action bar, the menus and the dialogs that are still running, oldest first.
    private(set) var running: [RunningOperation] = []
    /// The last operation that failed (its toast shows it, `report`). A new operation clears it.
    var failure: OperationFailure?
    /// The form a menu or a button asked for (create branch, tag, reset, remotes); `OperationDialogs` presents it.
    var dialog: OperationDialog?
    /// The destructive operation that waits for its confirmation.
    var confirmation: OperationConfirmation?
    /// The host-key sheet: the scan of the failure's host, then "Trust host".
    var hostKeyCheck: HostKeyCheck?
    /// The interactive rebase or squash sheet (`InteractiveRebaseView`); it builds its todo once it shows.
    var rebaseRequest: RebaseRequest?
    /// The Add Worktree form (`AddWorktreeView`).
    var worktreeForm: WorktreeForm?
    /// The Create Pull Request form (`CreatePRView`).
    var pullRequestForm: PullRequestForm?
    /// The Apply Patch preview (`ApplyPatchModal`), loading or read.
    var patchPreview: PatchPreviewRequest?
    /// The AI result card (`AIResultSheet`, task 12.3): the job it shows, running or finished.
    private(set) var aiRun: AIRun?
    /// The Suggest All card (`AIBatchSheet`): every unresolved conflict region of the open file, asked in turn.
    private(set) var aiBatch: AIBatch?
    /// The conflict editor's Save asks how to write the conflicts left unresolved (`ConflictSaveModal`).
    var conflictSavePrompt = false
    /// Leaving a conflict editor with unsaved ticks or edits asks first (`ConflictLeaveModal`): the way out waits here.
    private(set) var conflictLeave: ConflictLeave?
    /// The way out the leave prompt's Save took on: applied once the write succeeds, after the save prompt
    /// (`conflictSavePrompt`) when conflicts are left; dropped when that prompt is cancelled.
    private var pendingLeave: ConflictLeave?

    /// The conflict editor before the last AI Apply (Undo AI): valid only while the editor shows the same load of the
    /// same file. Any other change to the resolution (tick, edit, Reset), a reload, Save or leaving drops it.
    private var conflictAIUndo: ConflictAIUndo?

    struct ConflictAIUndo {
        let loadID: Int
        let path: String
        let merge: ThreeWayMerge
        let current: Int
    }

    /// A way out of a dirty conflict editor (another file, graph row, ref, pull request, or its close button): `name`
    /// is the open file's name; `navigate` runs once the editor is closed (Save or Don't Save).
    struct ConflictLeave {
        let name: String
        let navigate: @MainActor () -> Void
    }

    /// A form, confirmation, host-key or rebase modal is open (`ModalHost` shows it over the window).
    var hasModal: Bool {
        dialog != nil || confirmation != nil || hostKeyCheck != nil || rebaseRequest != nil || worktreeForm != nil
            || pullRequestForm != nil || aiRun != nil || aiBatch != nil || conflictSavePrompt || conflictLeave != nil
            || patchPreview != nil
    }

    /// Cancels every open modal, as their Cancel buttons do (a tab or page change).
    func closeModals() {
        dialog = nil
        confirmation = nil
        hostKeyCheck = nil
        rebaseRequest = nil
        worktreeForm = nil
        pullRequestForm = nil
        patchPreview = nil
        cancelConflictSave()
        conflictLeave = nil
        closeAI()
    }
    /// The undo journal's next entries, read with the refs; the toolbar, the Edit menu and the palette show them.
    private(set) var undoStatus = UndoStatus()
    /// The last write when the journal cannot take it back (a push, a fetch): the greyed Undo says why. A later write
    /// clears it.
    private(set) var lastNotUndoable: UndoJournal.NotUndoable?
    /// Interactive rebases being started: their files must stay while one runs (no rebase shows in `repoState` until
    /// git has read the todo).
    @ObservationIgnored private var rebaseStarts = 0
    /// The tab's rebase folder may hold files of a rebase that has ended (or of one from before a relaunch): the next
    /// state read without a rebase removes it.
    @ObservationIgnored private var rebaseFilesMayExist = true
    /// Bumped as an interactive rebase starts, before it writes its files. The folder's removal (off the main actor)
    /// compares it with the value it saw at its check and removes under the same lock, so a Start clicked in between
    /// never has its todo deleted.
    @ObservationIgnored private let rebaseGeneration = OSAllocatedUnfairLock(initialState: 0)
    @ObservationIgnored private var nextOperationID = 0

    /// The tab's profile: the id the user picked or the repo resolved to; nil = none (git uses the user's own config).
    /// The profile itself is looked up in `ProfileLibrary` at each use (`profile`), so a Settings edit reaches the
    /// tab's next write.
    private(set) var profileID: UUID?
    /// The profile store's read when it was still running as the tab opened; a write waits for it, so it never runs
    /// with no profile before the repo's own is known.
    @ObservationIgnored private var profileTask: Task<Void, Never>?
    /// Set once the repo resolved its profile or the user picked one; a late store read then changes nothing.
    @ObservationIgnored private(set) var profileResolved = false
    /// The selection came from session restore and is not loaded yet: if its commit is gone, the tab opens as a new
    /// one does instead of showing an error.
    @ObservationIgnored private var selectionIsRestored = false

    /// The runner and the folders, set up once (`backend()`).
    @ObservationIgnored private var setUpTask: Task<Backend, Error>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    /// Reads the neighbours of the commit a select settled on into `commitCache` (`prefetchNeighbours`).
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var commitCache = CommitDetailCache()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// The scope of the refresh in flight: a newer refresh cancels it and takes over its scope.
    @ObservationIgnored private var refreshScope: RefreshScope = []
    @ObservationIgnored private var logTask: Task<Void, Never>?
    @ObservationIgnored private var branchMapTask: Task<Void, Never>?
    /// The refs moved since `branchMap` was last computed: the log reload that follows maps them, or its failure does.
    @ObservationIgnored private var branchMapRefsStale = false
    /// The last load's `LogSnapshot.generation`.
    @ObservationIgnored private var logGeneration = 0
    /// The stashes, read with the refs; nil until the first read. Compared with the log's to reload it when they change.
    @ObservationIgnored private var stashes: [Stash]?
    /// The graph's hidden, soloed and pinned branches and its "hide stale branches" switch, saved per worktree; read
    /// with the setup (`backend()`), before the first log load.
    private(set) var view = RepoViewState()
    /// What `view` leaves out and pins against the latest refs; recomputed with each refs read and each view change.
    private(set) var visibility = LogFilter()
    @ObservationIgnored private var viewLoaded = false
    /// The last save of `view`: each save waits for the one before, so the file ends with the latest state.
    @ObservationIgnored private var viewSave: Task<Void, Never>?
    @ObservationIgnored private var worktreeTask: Task<Void, Never>?
    @ObservationIgnored private var submoduleTask: Task<Void, Never>?
    @ObservationIgnored private let watcher = RepoWatcher()
    /// The auto-fetch timer while `PrefKey.autoFetchMinutes` is on; cancelled when the tab closes.
    @ObservationIgnored private var autoFetchTask: Task<Void, Never>?
    /// The interval the timer runs at; 0 = off.
    @ObservationIgnored private var autoFetchMinutes = 0
    /// The order the log is read in: `PrefKey.commitOrder`, read in `init` and followed by `followCommitOrder`.
    @ObservationIgnored private var commitOrder = LogReader.Order.date
    /// Watches `PrefKey.autoFetchMinutes` and `PrefKey.commitOrder`; dropping it (close, deinit) stops the observation.
    @ObservationIgnored private var preferencesObserver: PreferencesObserver?

    /// The file panel2 shows instead of the graph (a click in the WIP panel or a commit's files); nil shows the graph.
    private(set) var openFile: FileTarget?
    /// The pull request or issue panel2 shows instead of the graph (a click in the PRs tab); nil shows the graph or
    /// the open file. Only one of the two (and `openTool`) is ever set.
    private(set) var openHosted: HostedItem?
    /// Changes with every PR or issue select: its placeholder logs a line per select.
    private(set) var hostedToken = 0
    /// The blame or reflog panel2 shows instead of the graph, or the file history panel 1 shows instead of the sidebar;
    /// nil shows the graph, the open file or the open pull request or issue. Never set with them: a diff opened from a tool keeps the tool in `returnTool`.
    private(set) var openTool: RepoTool?
    /// The tool the open diff was opened from (a history row): its read stays, and a file history keeps panel 1.
    private(set) var returnTool: RepoTool?
    /// The file history while it shows: panel 1 lists its commits instead of the sidebar, panel 2 the file's diff at the
    /// selected one. The open tool, or the tool the open diff was opened from.
    var historyTool: RepoTool? {
        let tool = openTool ?? (openFile != nil ? returnTool : nil)
        if case .fileHistory? = tool { return tool }
        return nil
    }
    /// The open diff is a commit's (in the file history, or picked in the graph): its hunks can be reverted in the
    /// working tree. Not a stash's or a compare's.
    var revertsCommitHunks: Bool {
        if historyTool != nil { return true }
        if case .commit = selection, case .commit? = openFile?.source { return true }
        return false
    }
    /// The last selected tool's read: `.loading` in the same call as the click, then its content. Kept while the tool
    /// is closed, so a diff opened from it returns to it as it was; the next `selectTool` replaces it.
    private(set) var toolState: Loadable<ToolContent> = .idle
    /// Changes with every tool select: its placeholder logs a line per select.
    private(set) var toolToken = 0
    /// The tool `toolState` was read for.
    @ObservationIgnored private var loadedTool: RepoTool?
    @ObservationIgnored private var toolTask: Task<Void, Never>?
    /// The tab's terminal (task 13.1): made on the first open the user asks for (`openTerminal`; a drawer shown with a
    /// new tab has none until clicked), kept while the drawer is closed or another tab shows, ended with the tab
    /// (`close()`) or its window. Nil until then, and again after its shell exited on its own.
    private(set) var terminal: RepoTerminal?
    /// The terminal drawer shows under the graph.
    private(set) var isTerminalOpen = false
    /// The tab's GitHub repository and lists (the PRs tab).
    let github = GitHubStore()
    /// The open pull request's detail (panel2), loaded when its row is selected.
    let pullDetail = PullRequestDetailModel()
    /// The open issue's detail (panel2), loaded when its row is selected.
    let issueDetail = IssueDetailModel()
    /// The open file's diff: `.loading` in the same call as the click, then its cards.
    private(set) var fileDiff: Loadable<FileDiffDetail> = .idle
    /// Changes with every file select (and "Load anyway"): the diff placeholder logs a line per select.
    private(set) var fileToken = 0
    /// Hunks only, side by side, or the whole file with its changes; kept while other files are opened. Starts in
    /// `PrefKey.diffDefaultMode`; DEBUG `-HistqDiffMode diff|split|full` overrides it.
    var diffMode: DiffMode = AppState.launchFlag("-HistqDiffMode").flatMap(DiffMode.init(rawValue:))
        ?? Preferences.defaults.string(forKey: PrefKey.diffDefaultMode.rawValue).flatMap(DiffMode.init(rawValue:))
        ?? .diff
    /// The diffs ignore whitespace changes (`git diff -w`, `PrefKey.diffIgnoreWhitespace`, one pref for every window):
    /// set with `setIgnoresWhitespace`, which reads the open file again; `DiffView` calls it when the pref changes
    /// elsewhere (Settings, another window), and each file load reads the pref again.
    private(set) var ignoresWhitespace = Preferences.defaults.bool(forKey: PrefKey.diffIgnoreWhitespace.rawValue)
    /// The last Previous / Next Change press: the open file's tables scroll to that change.
    private(set) var diffJump: DiffJump?
    @ObservationIgnored private var fileTask: Task<Void, Never>?
    /// The user chose "Load anyway" on the open file's size card.
    @ObservationIgnored private var fileIgnoresSizeLimit = false
    /// Numbers the file loads, so the diff tables tell a reloaded diff (after a stage) from a redraw.
    @ObservationIgnored private var fileLoadCount = 0
    /// The commits' file diffs read lately (`FileDiffCache`), and the read of a file history's neighbouring rows into it.
    @ObservationIgnored private var fileDiffCache = FileDiffCache()
    @ObservationIgnored private var fileDiffPrefetch: Task<Void, Never>?
    /// The open conflicted file's stages and its resolution so far (`openFile` is a WIP file of kind `.conflicted`):
    /// `.loading` in the same call as the click. Ticks and edits live here, so a tab switch keeps them.
    private(set) var conflict: Loadable<ConflictDocument> = .idle
    /// The conflict editor's write in flight ("Saving…"), which disables its buttons.
    private(set) var conflictBusy: String?
    /// The conflict editor's last failed write, shown in its header card.
    var conflictError: String?
    /// The conflicted path a pull request's Resolve with AI opened (`resolvePullRequestConflicts`): its Suggest All
    /// can only start once the file has loaded, so it waits here. Selecting another file, closing the editor or a
    /// failed load drops it.
    @ObservationIgnored private var pendingAIBatchPath: String?

    private static let logger = Logger(subsystem: "com.math2it.histq", category: "repo")

    /// What every read needs: the tab's runner, the base environment, the repo's folders.
    struct Backend: Sendable {
        let runner: GitRunner
        let base: [String: String]
        let directories: RepoDirectories
        /// The worktree's undo journal and rebase folder under `StatePaths` (never in `.git`).
        let journal: UndoJournal
        let rebaseFolder: URL
        /// The graph's view as saved when the tab opened.
        let view: RepoViewState

        /// The read environment for this folder, built once per load: it lists the repo's filter and diff drivers
        /// first, so they can be disabled. Never with the tab's profile: a read needs no identity, signing or SSH key,
        /// and a profile's signing settings have no business in an automatic read of an untrusted repo.
        func readEnvironment(cwd: URL) async throws -> [String: String] {
            try await GitInvocation.readEnvironment(profile: nil, base: base, runner: runner, cwd: cwd)
        }
    }

    init(url: URL) {
        self.url = url
        graphSearch.session = self
        resolveProfile()
        scheduleAutoFetch()
        followCommitOrder()
        // Posted for every key, possibly off the main thread; only a change of the interval restarts the timer, only a
        // change of the commit order reads the log again.
        preferencesObserver = PreferencesObserver { [weak self] in
            self?.scheduleAutoFetch()
            self?.followCommitOrder()
        }
        #if DEBUG
        // `-HistqOpenTerminal YES`: the drawer opens with the tab and starts its shell, as an explicit open does (QA
        // shots of the terminal).
        if AppState.launchFlag("-HistqOpenTerminal") == "YES" { openTerminal() }
        // `-HistqShowHidden YES`: the Local, Remote and Tags cards list their hidden rows, as their eye button does (QA
        // shots).
        if AppState.launchFlag("-HistqShowHidden") == "YES" {
            localShowsHidden = true
            remoteShowsHidden = true
            tagsShowHidden = true
        }
        // `-HistqRun`: menu actions on a fixture copy, once the refs and the whole log are in.
        if let spec = AppState.launchFlag("-HistqRun") {
            Task { [weak self] in
                for _ in 0..<100 {
                    // The worktree and submodule menus need the worktrees and the submodules, read after the first log
                    // page.
                    if self?.refs.value != nil, self?.log.value?.isComplete == true, self?.worktrees.value != nil,
                       self?.debugSubmodulesReady(spec) == true { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard let self else { return }
                await RepoMenus.debugRun(spec, session: self)
            }
        }
        // `-HistqShow`: one menu item whose confirmation or form stays open (QA shots of the modals).
        if let step = AppState.launchFlag("-HistqShow") {
            Task { [weak self] in
                for _ in 0..<100 {
                    if self?.refs.value != nil, self?.log.value?.isComplete == true, self?.worktrees.value != nil,
                       self?.debugSubmodulesReady(step) == true { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard let self else { return }
                RepoMenus.debugShow(step, session: self)
            }
        }
        // `-HistqOpenCreatePR <branch>`: the branch menu's Create Pull Request… once the refs and the GitHub connection
        // are in (QA shots of the form; with `-HistqGitHubStub YES` its Create makes the stub's PR #3).
        if let branch = AppState.launchFlag("-HistqOpenCreatePR") {
            Task { [weak self] in
                for _ in 0..<100 {
                    if self?.refs.value != nil, self?.github.api != nil { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard let self else { return }
                if let reason = RepoMenus.createPullRequestUnavailableReason(head: .local(branch), base: nil, self) {
                    return RepoMenus.debugLog("create-pr \(branch): \(reason)")
                }
                RepoMenus.openCreatePullRequest(head: .local(branch), base: nil, self)
            }
        }
        // `-HistqCommit "<message>"`: commits the staged changes of a fixture copy through the WIP panel's write path
        // (with the tab's profile), once the status is read; the outcome goes to `operations.txt`.
        if let message = AppState.launchFlag("-HistqCommit") {
            Task { [weak self] in
                for _ in 0..<100 {
                    if self?.status.value != nil { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard let self else { return }
                let outcome: String
                do {
                    try await perform(.commit(message: message))
                    outcome = "ok commit"
                } catch {
                    outcome = "fail commit: \(Self.writeMessage(for: error))"
                }
                // Appended: the toolbar's `-HistqLogUndo` lines and the history seams share the file.
                RepoMenus.debugLog(outcome)
            }
        }
        if let revision = AppState.launchFlag("-HistqOpenRebase") {
            Task { [weak self] in await self?.runLaunchRebase([revision], squash: false) }
        }
        // `-HistqApplyPatch <file>`: the Apply Patch preview of that file once the refs are in (QA shots).
        if let path = AppState.launchFlag("-HistqApplyPatch") {
            Task { [weak self] in
                for _ in 0..<100 {
                    if self?.refs.value != nil { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                let file = URL(filePath: path)
                guard let self, let data = try? Data(contentsOf: file) else {
                    RepoMenus.debugLog("fail apply patch: cannot read \(path)")
                    return
                }
                openPatchPreview(data: data, source: file.lastPathComponent)
            }
        }
        if let revisions = AppState.launchFlag("-HistqOpenSquash") {
            Task { [weak self] in
                await self?.runLaunchRebase(revisions.split(separator: ",").map(String.init), squash: true)
            }
        }
        let undos = AppState.launchFlag("-HistqUndo").flatMap(Int.init) ?? 0
        let redos = AppState.launchFlag("-HistqRedo").flatMap(Int.init) ?? 0
        if undos + redos > 0 {
            Task { [weak self] in await self?.runLaunchHistory(undos: undos, redos: redos) }
        }
        // `-HistqSelectWalk <n>[,<ms>]`: times switches between commits (`runSelectWalk`).
        if let spec = AppState.launchFlag("-HistqSelectWalk") {
            Task { [weak self] in await self?.runSelectWalk(spec) }
        }
        // `-HistqHistoryWalk <n>[,<ms>]` (with `-HistqSelect history:<path>`): times switches between history rows.
        if let spec = AppState.launchFlag("-HistqHistoryWalk") {
            Task { [weak self] in await self?.runHistoryWalk(spec) }
        }
        // `-HistqOperation`: the operation banner's buttons on a fixture copy, once the state is read.
        if let step = AppState.launchFlag("-HistqOperation") {
            Task { [weak self] in
                for _ in 0..<100 {
                    if self?.status.value != nil, self?.repoState?.isOperationInProgress == true { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                self?.runLaunchOperation(step)
            }
        }
        #endif
    }

    deinit {
        // A window closing drops its sessions without `close()`.
        watcher.stop()
        detailTask?.cancel()
        prefetchTask?.cancel()
        fileTask?.cancel()
        toolTask?.cancel()
        refreshTask?.cancel()
        logTask?.cancel()
        branchMapTask?.cancel()
        worktreeTask?.cancel()
        submoduleTask?.cancel()
        setUpTask?.cancel()
        autoFetchTask?.cancel()
        profileTask?.cancel()
    }

    /// Stops loading, watching and auto-fetching; the tab closed.
    func close() {
        watcher.stop()
        detailTask?.cancel()
        prefetchTask?.cancel()
        fileTask?.cancel()
        toolTask?.cancel()
        refreshTask?.cancel()
        logTask?.cancel()
        branchMapTask?.cancel()
        worktreeTask?.cancel()
        submoduleTask?.cancel()
        setUpTask?.cancel()
        autoFetchTask?.cancel()
        autoFetchTask = nil
        preferencesObserver = nil
        profileTask?.cancel()
        github.stop()
        // The tab is removed before the selection moves, so `ModalHost` never closes its modals: a running AI job
        // must stop here, before it sends the diff.
        closeAI()
        endTerminal()
    }

    // MARK: Terminal

    /// The drawer is open but its shell has not started: shown with a new tab (`showTerminalDrawer`), it waits for the
    /// user to click into it.
    var isTerminalPending: Bool { isTerminalOpen && terminal == nil }

    /// The toolbar's Terminal button and View › Show Terminal (⌃`). A pending drawer starts its shell instead of
    /// hiding: the user asked for the terminal.
    func toggleTerminal() {
        if isTerminalOpen, !isTerminalPending { closeTerminal() } else { openTerminal() }
    }

    /// Shows the drawer in this frame and gives the terminal the focus; the first open also starts the shell, once the
    /// tab's profile is known (until then the drawer shows the empty terminal). Only for what the user asked: the
    /// toolbar, ⌃`, a click into a pending drawer.
    func openTerminal() {
        let terminal = terminal ?? makeTerminal()
        terminal.wantsFocus = true
        isTerminalOpen = true
    }

    /// Settings › Terminal "Open terminal with each new tab": shows the drawer without starting a shell (a running
    /// one just shows). A shell prompt (oh-my-zsh, starship, p10k) runs `git status` in the repo, so the repo's own
    /// `.git/config` (`core.fsmonitor`, a pager, an alias) would run its commands only because a tab opened; the
    /// drawer waits for a click into it. The graph keeps the keyboard.
    func showTerminalDrawer() {
        isTerminalOpen = true
    }

    /// Hides the drawer; the shell keeps running. The graph gets the focus back.
    func closeTerminal() {
        guard isTerminalOpen else { return }
        terminal?.returnFocusToGraph()
        isTerminalOpen = false
    }

    /// Ends the tab's shell (the tab or its window closes).
    func endTerminal() {
        terminal?.end()
        terminal = nil
        isTerminalOpen = false
    }

    private func makeTerminal() -> RepoTerminal {
        let terminal = RepoTerminal()
        // `exit` in the shell: the drawer closes, and the next open starts a new shell.
        terminal.onExit = { [weak self, weak terminal] in
            guard let self, let terminal, self.terminal === terminal else { return }
            closeTerminal()
            self.terminal = nil
        }
        self.terminal = terminal
        Task { [weak self, weak terminal] in
            guard let self else { return }
            // A shell started before the profile store's first read would have the user's global identity for good.
            let profile = await writeProfile()
            guard let terminal, self.terminal === terminal else { return }
            terminal.start(in: url, profile: profile)
        }
        return terminal
    }

    // MARK: Profile

    /// The tab's profile as the store has it now. An id the store no longer has (the profile was deleted) falls back
    /// to the default profile, as deleting it promised; nil while the store is not read.
    var profile: Profile? {
        guard let profileID, let store = ProfileLibrary.shared.store else { return nil }
        return store.profile(id: profileID) ?? store.defaultProfile
    }

    /// Resolves the repo's remembered profile, else the default: from memory when the store is read (it is read at
    /// launch), else once its read ends. Only here and after that read: `profile(forRepo:)` resolves the real path.
    private func resolveProfile() {
        let library = ProfileLibrary.shared
        if let store = library.store {
            profileID = store.profile(forRepo: url)?.id
            profileResolved = true
            return
        }
        profileTask = Task { [weak self] in
            let store = await library.loaded()
            guard let self, !profileResolved else { return }
            profileID = store?.profile(forRepo: url)?.id
            profileResolved = true
        }
    }

    /// The profile picker's click: the tab shows `id` at once, the next write uses it, and the repo remembers it (the
    /// store saves off the main thread). nil = none; the repo then forgets its profile and opens with the default.
    func setProfile(_ id: UUID?) {
        profileResolved = true
        profileTask?.cancel()
        profileTask = nil
        if profileID != id { profileID = id }
        let url = url
        Task {
            // A pick before the store is read is saved once it is.
            let library = ProfileLibrary.shared
            guard await library.loaded() != nil else { return }
            library.update { $0.remember(id, forRepo: url) }
        }
    }

    /// Session restore: the tab's profile as that session had it, which wins over the repo's remembered one. Unlike
    /// `setProfile`, the repo's remembered profile is left as it is. A write still waits for the store's first read.
    func restoreProfile(_ id: UUID?) {
        profileResolved = true
        profileTask?.cancel()
        let library = ProfileLibrary.shared
        profileTask = library.store == nil ? Task { _ = await library.loaded() } : nil
        if profileID != id { profileID = id }
    }

    /// Session restore: the graph's commit before the tab's first `select`, which loads it (no `select` timing line:
    /// no click). A commit that is gone falls back to `.overview`.
    func restoreSelection(_ commit: String) {
        selection = .commit(commit)
        graphSelection = [.commit(commit)]
        selectionIsRestored = true
    }

    /// The profile a write runs with: waits for the store's first read when the tab opened before it ended.
    private func writeProfile() async -> Profile? {
        await profileTask?.value
        return profile
    }

    // MARK: Auto-fetch

    /// A `UserDefaults.didChangeNotification` observation of `Preferences.defaults` that ends when it is released.
    private final class PreferencesObserver: @unchecked Sendable {
        /// Only read in `deinit`; `removeObserver` is thread-safe.
        private let token: NSObjectProtocol

        init(_ onChange: @escaping @MainActor () -> Void) {
            token = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: Preferences.defaults, queue: .main
            ) { _ in
                MainActor.assumeIsolated { onChange() }
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Starts, restarts or stops the auto-fetch timer when `PrefKey.autoFetchMinutes` changed. Only the offered
    /// intervals count; any other value (a hand-written default) reads as off, so it can never fetch in a tight loop.
    private func scheduleAutoFetch() {
        let stored = Preferences.defaults.integer(forKey: PrefKey.autoFetchMinutes.rawValue)
        let minutes = [3, 5, 10, 30].contains(stored) ? stored : 0
        guard minutes != autoFetchMinutes else { return }
        autoFetchMinutes = minutes
        autoFetchTask?.cancel()
        autoFetchTask = nil
        guard minutes > 0 else { return }
        autoFetchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard (try? await Task.sleep(for: .seconds(minutes * 60))) != nil else { return }
                await self?.autoFetch()
            }
        }
    }

    /// Follows `PrefKey.commitOrder`; any other value (a hand-written default) reads as by date. A change reads the
    /// whole log again in the new order, unless no load has started yet (`log` is `.idle`): the first one reads it.
    private func followCommitOrder() {
        let stored = Preferences.defaults.string(forKey: PrefKey.commitOrder.rawValue)
        let order = stored.flatMap(LogReader.Order.init(rawValue:)) ?? .date
        guard order != commitOrder else { return }
        commitOrder = order
        if case .idle = log { return }
        refresh(scope: .log)
    }

    /// One automatic fetch: skipped while a user operation runs; a failure is only logged (failure toasts are for
    /// the user's own operations). It shows as running (the action bar's spinner and title), so a user write that
    /// waits behind it in the write lane does not wait silently.
    private func autoFetch() async {
        guard running.isEmpty else { return }
        let prune = Preferences.defaults.bool(forKey: PrefKey.pruneOnFetch.rawValue)
        nextOperationID &+= 1
        let operation = RunningOperation(id: nextOperationID, title: "Auto-fetch", key: nil)
        running.append(operation)
        defer { running.removeAll { $0.id == operation.id } }
        do {
            let backend = try await backend()
            let profile = await writeProfile()
            try await Self.autoFetch(prune: prune, profile: profile, backend: backend, cwd: url)
        } catch {
            if !Self.isCancellation(error) {
                Self.logger.notice("auto-fetch failed: \(Self.message(for: error), privacy: .public)")
            }
            return
        }
        refresh(scope: [.status, .refs])
    }

    /// `git fetch --all [--prune]` in the write lane with the background fetch environment and the tab's profile (a
    /// fetch is network: the profile's SSH key). Nobody clicked it in a repo that may be downloaded, so the repo's
    /// config, hooks and credential helpers run nothing (see `GitInvocation.Access.backgroundFetch`), and no gc or
    /// maintenance runs after it. A failure to list the user's credential helpers, or a repo that sets its own http or
    /// proxy config, skips the tick (logged; a click on Fetch still fetches). Two minutes at most, so it never holds
    /// the write lane long.
    @concurrent
    private nonisolated static func autoFetch(prune: Bool, profile: Profile?, backend: Backend, cwd: URL) async throws {
        let base = await GitToolchain.writeBase()
        let runner = backend.runner
        // Passed to the gate: it reaches git only when every remote is https on the profile's host.
        let token = await GitHubTokens.token(for: profile)
        let environment = try await GitInvocation.backgroundFetchEnvironment(
            profile: profile, base: base, runner: runner, cwd: cwd, token: token)
        let args = ["fetch", "--all"] + (prune ? ["--prune"] : [])
        _ = try await runner.mutate {
            try await runner.run(args, cwd: cwd, env: environment, timeout: .seconds(120))
        }
    }

    // MARK: Select

    /// Switches the detail to `selection` now, in the click's frame: a commit read before shows whole from the cache
    /// (no load), a commit of the log shows its header with its files loading, the WIP shows from the last status (a
    /// read refreshes it), anything else is `.loading` (the placeholder). The load runs in a task that a newer select
    /// cancels. Selecting the current selection again (a tab switch) reloads it, unless the cache has it. A commit on
    /// screen whole prefetches its neighbours (`prefetchNeighbours`); a newer select cancels that too. `keepsPanel2`:
    /// another selection leaves panel2 as it is (a blame gutter's click keeps the blame).
    func select(_ selection: Selection, keepsPanel2: Bool = false) {
        // Another row (a parent jump, a vanished WIP) shows the graph again; a tab switch keeps the open file.
        if selection != self.selection, !keepsPanel2 { closePanel2() }
        self.selection = selection
        selectToken &+= 1
        selectDetail = timingDetail(selection)
        detailTask?.cancel()
        prefetchTask?.cancel()
        let token = selectToken
        let isRestored = selectionIsRestored
        selectionIsRestored = false
        let instant: CommitDetail? = switch selection {
        case .commit(let hash): instantDetail(hash, isStash: false)
        case .stash(let hash): instantDetail(hash, isStash: true)
        default: nil
        }
        // The WIP panel reads the live status: once one is loaded it shows at once, and the read below refreshes it.
        detail = if let instant { .loaded(.commit(instant)) }
            else if selection == .wip, status.value != nil { .loaded(.wip) }
            else { .loading }
        if instant?.files != nil {
            detailTask = nil
            if case .commit(let hash) = selection { prefetchNeighbours(of: hash) }
            return
        }
        detailTask = Task { [weak self] in
            await self?.loadDetail(selection, token: token, isRestored: isRestored)
        }
    }

    /// Selects graph rows: the path a click in the graph takes (and `-HistqSelect wip|commit:<sha>`, a parent
    /// jump). One row shows its detail, several a count; none keeps the detail as it is. `keepsPanel2` (nil:
    /// `keepsPanel2OnSelect`): the pane keeps what it shows until a file of the new row swaps in it.
    func selectGraph(_ items: [GraphItem], keepsPanel2: Bool? = nil) {
        let keepsPanel2 = keepsPanel2 ?? keepsPanel2OnSelect
        if !keepsPanel2, asksBeforeLeavingConflict({ [weak self] in self?.selectGraph(items, keepsPanel2: false) }) {
            return
        }
        // Another worktree's row is a selection alone (its changes); several rows leave it out.
        let items = items.count > 1 ? items.filter { if case .worktree = $0 { false } else { true } } : items
        if !keepsPanel2 { closePanel2() }
        graphSelection = items
        guard let first = items.first else { return }
        let selection: Selection
        if items.count > 1 {
            selection = .multiple(items.count)
        } else {
            switch first {
            case .wip: selection = .wip
            case .stash(let hash): selection = .stash(hash)
            case .commit(let hash): selection = .commit(hash)
            case .worktree(let path): selection = .worktree(path)
            }
        }
        UITiming.select(timingDetail(selection))
        select(selection, keepsPanel2: keepsPanel2)
    }

    /// A graph row's default: Stacked keeps its bottom pane (the graph stays clickable above it), Columns its diff
    /// column (the open file or file history) while the graph shows in panel 2; a blame, reflog, pull request, issue or
    /// conflict editor over the graph closes as in Classic and Focus.
    private var keepsPanel2OnSelect: Bool {
        switch LayoutPreset.current {
        case .stacked: return true
        case .columns:
            if openHosted != nil || openFile?.isConflict == true { return false }
            switch openTool ?? returnTool {
            case .blame?, .reflog?: return false
            case .fileHistory?, nil: return true
            }
        case .classic, .focus: return false
        }
    }

    /// Compares `base` with `head` (nil: the working tree) now, in the click's frame: the detail shows its placeholder
    /// until the files are read. The graph keeps its selected rows.
    func selectCompare(base: String, head: String?) {
        if asksBeforeLeavingConflict({ [weak self] in self?.selectCompare(base: base, head: head) }) { return }
        let selection = Selection.compare(base: base, head: head)
        UITiming.select(timingDetail(selection))
        select(selection)
    }

    /// A blame gutter's click: selects commit `hash` like a graph click (its row, panel3's detail), but panel2 keeps
    /// the open tool.
    func selectKeepingTool(_ hash: String) {
        graphSelection = [.commit(hash)]
        UITiming.select(timingDetail(.commit(hash)))
        select(.commit(hash), keepsPanel2: true)
    }

    /// What a select can show at once: the cached detail, else (a commit, not a stash) the log's header with its files
    /// still to load; nil when neither has it.
    private func instantDetail(_ hash: String, isStash: Bool) -> CommitDetail? {
        if let cached = commitCache.value(.init(hash: hash, isStash: isStash)) { return cached }
        return isStash ? nil : logHeader(hash)
    }

    /// `readCommit` through the cache. A commit of the log reads only its files: its header is the log's.
    private func readCommitCached(_ backend: Backend, hash: String, isStash: Bool) async throws -> CommitDetail {
        if let cached = commitCache.value(.init(hash: hash, isStash: isStash)) { return cached }
        let detail = if !isStash, let header = logHeader(hash) {
            try await Self.readFiles(backend, cwd: url, of: header)
        } else {
            try await Self.readCommit(backend, cwd: url, hash: hash, isStash: isStash)
        }
        commitCache.insert(detail)
        return detail
    }

    /// Once a select settled on commit `hash` of the log (its files on screen): reads the files of the commits just
    /// above and below it in the log into `commitCache`, both at once (two git processes at most, off the main actor),
    /// so the next click up or down shows whole. Skips cached commits; stashes are not in the log. Never touches
    /// `detail` or the selection, drops its errors; the next select cancels it and its git processes.
    private func prefetchNeighbours(of hash: String) {
        prefetchTask?.cancel()
        prefetchTask = nil
        guard let log = log.value, let index = log.commitIndex[hash] else { return }
        let headers = [index - 1, index + 1]
            .filter { log.commits.indices.contains($0) }
            .map { CommitDetail(header: log.commits[$0]) }
            .filter { !commitCache.contains(.init(hash: $0.hash, isStash: false)) }
        guard !headers.isEmpty else { return }
        let url = url
        prefetchTask = Task { [weak self] in
            guard let backend = try? await self?.backend() else { return }
            await withTaskGroup(of: CommitDetail?.self) { group in
                for header in headers {
                    group.addTask { try? await Self.readFiles(backend, cwd: url, of: header) }
                }
                for await detail in group {
                    if let detail { self?.commitCache.insert(detail) }
                }
            }
        }
    }

    /// The log's commit `hash` as a detail whose files are still loading; nil when the log does not have it.
    private func logHeader(_ hash: String) -> CommitDetail? {
        guard let log = log.value, let index = log.commitIndex[hash] else { return nil }
        return CommitDetail(header: log.commits[index])
    }

    private func timingDetail(_ selection: Selection) -> String {
        switch selection {
        case .overview: "overview \(url.lastPathComponent)"
        case .wip: "wip"
        case .commit(let hash): "commit \(hash)"
        case .stash(let hash): "stash \(hash)"
        case .multiple(let count): "commits \(count)"
        case .worktree(let path): "worktree-wip \(URL(filePath: path).lastPathComponent)"
        case .ref(let item): item.timingDetail
        case .compare(let base, let head): "compare \(base) \(head ?? "worktree")"
        case .submodule(let path): "submodule \(path)"
        }
    }

    private func loadDetail(_ selection: Selection, token: Int, isRestored: Bool = false) async {
        do {
            let backend = try await backend()
            // The log loads once per session, beside the detail; a tab switch does not restart it.
            if log.value == nil, logTask == nil { loadLog(backend) }
            let loaded: Detail
            switch selection {
            case .overview, .wip:
                if try await readStatusAndRefs(backend, scope: [.status, .refs]) { loadLog(backend) }
                guard token == selectToken else { return }
                if selection == .wip {
                    loaded = .wip
                } else if let status = status.value, !status.entries.isEmpty {
                    self.selection = .wip
                    graphSelection = [.wip]
                    loaded = .wip
                } else if let head = status.value?.branch.commit {
                    let commit = try await readCommitCached(backend, hash: head, isStash: false)
                    guard token == selectToken else { return }
                    self.selection = .commit(head)
                    graphSelection = [.commit(head)]
                    loaded = .commit(commit)
                } else {
                    loaded = .overview
                }
            case .commit(let hash), .stash(let hash):
                // A first select that is not the overview (`-HistqSelect commit:`) still loads the sidebar's refs.
                if status.value == nil || refs.value == nil,
                   try await readStatusAndRefs(backend, scope: [.status, .refs])
                {
                    loadLog(backend)
                }
                let isStash = if case .stash = selection { true } else { false }
                loaded = .commit(try await readCommitCached(backend, hash: hash, isStash: isStash))
            case .multiple:
                let items = graphSelection
                let diff = RepoMenus.combinedDiff(self)
                let files: [FileChange]? = if let diff {
                    try await Self.readCompareFiles(backend, cwd: url, base: diff.base, head: diff.head)
                } else {
                    nil
                }
                loaded = .multiple(items, diff: diff, files: files)
            case .worktree(let path):
                loaded = .worktree(path, try await Self.readWorktreeStatus(backend, path: path))
            case .compare(let base, let head):
                loaded = .compare(base: base, head: head,
                                  files: try await Self.readCompareFiles(backend, cwd: url, base: base, head: head))
            case .submodule(let path):
                // A first select (`-HistqSelect submodule:`) still loads the sidebar's refs and the graph.
                if status.value == nil || refs.value == nil,
                   try await readStatusAndRefs(backend, scope: [.status, .refs])
                {
                    loadLog(backend)
                }
                loaded = .submodule(try await Self.readSubmoduleDetail(backend, path: path, list: submodules.value))
            case .ref(let item):
                if refs.value == nil, try await readStatusAndRefs(backend, scope: [.status, .refs]) {
                    loadLog(backend)
                }
                guard token == selectToken else { return }
                guard let refs = refs.value, case let (resolved, hash)? = Self.resolve(item, in: refs) else {
                    throw CommitReadError.refGone(item.timingDetail)
                }
                if resolved != item { sidebarSelection = resolved }
                if changesRow(of: resolved, in: refs) == .wip {
                    self.selection = .wip
                    graphSelection = [.wip]
                    loaded = .wip
                    break
                }
                self.selection = .commit(hash)
                graphSelection = [.commit(hash)]
                // Resolved: the cached detail, or the log's header while its files load, as a click on its row.
                if let instant = instantDetail(hash, isStash: false) {
                    detail = .loaded(.commit(instant))
                    if instant.files != nil { return prefetchNeighbours(of: hash) }
                }
                loaded = .commit(try await readCommitCached(backend, hash: hash, isStash: false))
            }
            guard token == selectToken else { return }
            detail = .loaded(loaded)
            if case .commit(let commit) = loaded, !commit.isStash { prefetchNeighbours(of: commit.hash) }
        } catch {
            guard token == selectToken, !Self.isCancellation(error) else { return }
            if isRestored, case .commit = selection {
                // A restored commit that was amended, rebased away or collected: open as a new tab does.
                graphSelection = []
                select(.overview)
                return
            }
            let message = Self.message(for: error)
            detail = .failed(message)
            failUnread(message)
        }
    }

    /// After a failed setup or read: whatever has never loaded shows `message` too (the sidebar, the commit list), so
    /// no panel stays on its placeholder. Loaded values stay; a log still loading ends on its own.
    private func failUnread(_ message: String) {
        if status.value == nil { status = .failed(message) }
        if refs.value == nil { refs = .failed(message) }
        if log.value == nil, logTask == nil { log = .failed(message) }
    }

    // MARK: Sidebar

    /// Shows a sidebar tab: the path a click on its capsule takes.
    func selectSidebarTab(_ tab: SidebarTab) {
        UITiming.select("sidebar \(tab.rawValue)")
        sidebarTab = tab
    }

    /// Selects a sidebar row now, showing its tab and opening its accordion.
    func selectSidebarItem(_ item: SidebarItem) {
        UITiming.select(item.timingDetail)
        sidebarSelection = item
        switch item {
        case .local: sidebarTab = .branches; localExpanded = true
        case .remote: sidebarTab = .branches; remoteExpanded = true
        case .tag: sidebarTab = .tags
        }
    }

    /// A click on a sidebar row: selects it, and the graph and the detail jump to its commit (the branch tip, the tag's
    /// commit) in the same call; the graph scrolls that row into view. A branch checked out with uncommitted changes
    /// jumps to their row instead (`changesRow`). Before the refs are read (a launch request), the detail shows the
    /// commit placeholder at once and jumps once they are in (`Selection.ref`).
    func selectRef(_ item: SidebarItem) {
        if asksBeforeLeavingConflict({ [weak self] in self?.selectRef(item) }) { return }
        closePanel2()
        selectSidebarItem(item)
        guard let refs = refs.value else { return select(.ref(item)) }
        guard let (resolved, commit) = Self.resolve(item, in: refs) else { return }
        selectGraph([changesRow(of: resolved, in: refs) ?? .commit(commit)])
    }

    /// Whether this worktree has uncommitted changes: the graph then has a WIP row above HEAD.
    private var hasChanges: Bool { status.value?.entries.isEmpty == false }

    /// The row of a local branch's uncommitted changes: this worktree's WIP row when it is checked out here, another
    /// worktree's row when it is checked out there; nil when it is not checked out or has no changes.
    private func changesRow(of item: SidebarItem, in refs: Refs) -> GraphItem? {
        guard case .local(let name) = item else { return nil }
        if refs.localBranches.contains(where: { $0.name == name && $0.isHead }) { return hasChanges ? .wip : nil }
        return dirtyWorktrees.first { $0.worktree.branch == "refs/heads/\(name)" }.map { .worktree($0.path) }
    }

    /// Selects a branch by name (DEBUG `-HistqSelect branch:<name>`) through `selectRef`, the path a click takes: a
    /// remote branch when the refs are in and only a remote branch has that name, else a local one (the refs may not be
    /// read yet; the load then falls back to a remote branch of that name).
    func selectBranch(named name: String) {
        let isRemote = refs.value.map { refs in
            !refs.localBranches.contains { $0.name == name } && refs.remoteBranches.contains { $0.name == name }
        } ?? false
        selectRef(isRemote ? .remote(name) : .local(name))
    }

    /// The commit a sidebar ref points at, with the ref as found: a local branch that does not exist resolves to the
    /// remote branch of that name, if any.
    private static func resolve(_ item: SidebarItem, in refs: Refs) -> (SidebarItem, String)? {
        switch item {
        case .local(let name):
            if let commit = refs.localBranches.first(where: { $0.name == name })?.commit { return (item, commit) }
            return refs.remoteBranches.first { $0.name == name }.map { (.remote(name), $0.commit) }
        case .remote(let name):
            return refs.remoteBranches.first { $0.name == name }.map { (item, $0.commit) }
        case .tag(let name):
            return refs.tags.first { $0.name == name }.map { (item, $0.commit ?? $0.target) }
        }
    }

    // MARK: Keeping the selection

    /// Another worktree or a submodule that went: the WIP takes over when this worktree has changes.
    private static func movesToWIP(_ selection: Selection) -> Bool {
        switch selection {
        case .worktree, .submodule: true
        default: false
        }
    }

    /// After a refresh or a log reload, a selected row that is gone moves to HEAD (the detail shows it): the WIP once the
    /// working tree is clean (a commit, a stash, a discard), a stash once dropped or popped, a commit that was in the
    /// previous complete log and is not in the new one (an amend, a reset), and another worktree's row once it is clean
    /// or gone (to this worktree's WIP row when it has changes). A selection that still exists stays, and the graph
    /// selects its row again after the reload. `previousLog` is nil outside a log reload: commits are not checked.
    private func dropVanishedSelection(previousLog: LogSnapshot? = nil) {
        let vanished: Bool
        switch selection {
        case .wip:
            vanished = status.value?.entries.isEmpty == true
        case .stash(let hash):
            vanished = stashes.map { !$0.contains { $0.hash == hash } } ?? false
        case .commit(let hash):
            guard let previousLog, previousLog.isComplete, let log = log.value, log.isComplete else { return }
            vanished = previousLog.commitIndex[hash] != nil && log.commitIndex[hash] == nil
        case .worktree(let path):
            // Its graph row goes once it is clean, removed or unreadable.
            guard worktrees.value != nil else { return }
            vanished = !dirtyWorktrees.contains { $0.path == path }
        case .submodule(let path):
            // Removed (or its `.gitmodules` entry gone); not before the submodules are read.
            guard let submodules = submodules.value else { return }
            vanished = !submodules.contains { $0.path == path }
        case .overview, .multiple, .ref, .compare:
            return
        }
        guard vanished else { return }
        // The pane closes in Stacked too: what it shows (a WIP file once the tree is clean) may be gone. A removed
        // submodule leaves its removal staged: the WIP shows it.
        if hasChanges, Self.movesToWIP(selection) {
            selectGraph([.wip], keepsPanel2: false)
        } else if let head = status.value?.branch.commit {
            selectGraph([.commit(head)], keepsPanel2: false)
        } else {
            // An unborn branch: the overview cards.
            graphSelection = []
            UITiming.select(timingDetail(.overview))
            select(.overview)
        }
    }

    // MARK: Refresh

    /// Rereads what `scope` names. A refresh in flight is cancelled and its scope added to this one. `refs` also
    /// reloads the log when a ref moved.
    func refresh(scope: RefreshScope) {
        let scope = refreshTask == nil ? scope : scope.union(refreshScope)
        refreshTask?.cancel()
        refreshScope = scope
        refreshTask = Task { [weak self] in
            await self?.performRefresh(scope)
        }
    }

    private func performRefresh(_ scope: RefreshScope) async {
        do {
            let backend = try await backend()
            // A newer refresh took over (it owns `refreshTask` now).
            try Task.checkCancellation()
            let readStart = DispatchTime.now().uptimeNanoseconds
            let refsMoved = try await readStatusAndRefs(backend, scope: scope)
            UITiming.refreshRead(since: readStart)
            if scope.contains(.log) || refsMoved { loadLog(backend) }
            // A worktree added or removed, or a commit made in one, shows as a refs change. Never before the first log
            // page: that one starts the first read.
            if scope.contains(.refs), log.value != nil { loadWorktrees(backend) }
            // A checkout, an edit inside a submodule or a submodule write: after the first log page, as the worktrees.
            if !scope.isDisjoint(with: [.status, .refs]), log.value != nil { loadSubmodules(backend) }
            refreshTask = nil
            refreshScope = []
        } catch {
            guard !Self.isCancellation(error) else { return }
            Self.logger.error("refresh \(scope.description, privacy: .public) failed: \(error, privacy: .public)")
            failUnread(Self.message(for: error))
            refreshTask = nil
            refreshScope = []
        }
    }

    /// Reads the status and the refs (those `scope` names) off the main actor, then publishes them. Returns whether
    /// a ref moved since the last read (a commit, a checkout, a fetch: the log changed). Throws `CancellationError`
    /// when cancelled, so nothing stale is published.
    private func readStatusAndRefs(_ backend: Backend, scope: RefreshScope) async throws -> Bool {
        guard scope.contains(.status) || scope.contains(.refs) else { return false }
        let (newStatus, newState, newRefs, newStashes, newRemotes, newUndo) = try await Self.read(
            backend, cwd: url, status: scope.contains(.status), refs: scope.contains(.refs))
        try Task.checkCancellation()
        if let newState, newState != repoState { repoState = newState }
        if let newUndo, newUndo != undoStatus { undoStatus = newUndo }
        if newState != nil { removeRebaseFilesIfDone() }
        if let newStatus {
            status = .loaded(newStatus)
            statusReads &+= 1
            if let target = openFile, target.source == .wip {
                if target.isConflict {
                    // The conflict editor keeps its ticks and edits; it closes once the path is resolved (its Save, the
                    // merge tool, a `git add` in a terminal).
                    if !newStatus.conflicted.contains(where: { $0.path == target.path }) { closeFile() }
                } else {
                    // A stage, a discard or an edit changed the open WIP file: its diff follows without a placeholder.
                    loadFile(quietly: true)
                }
            }
        }
        if let newStashes { stashes = newStashes }
        if let newRemotes, newRemotes != remotes { remotes = newRemotes }
        var moved = false
        if let newRefs {
            moved = refs.value.map { $0 != newRefs } ?? false
            let changed = refs.value != newRefs
            refs = .loaded(newRefs)
            pruneView(newRefs)
            let filter = visibility
            updateVisibility()
            // Moved refs reload the log (every caller), whose completion maps them; else after the filter: the branch
            // map attributes commits to the shown refs only.
            if moved { branchMapRefsStale = true } else if changed || filter != visibility { updateBranchMap() }
        }
        dropVanishedSelection()
        return moved || syntheticRowsChanged
    }

    /// Whether the loaded log's WIP and stash rows no longer match the status and the stashes (the working tree
    /// became clean or dirty, HEAD moved, a stash was pushed or dropped): the graph is laid out again. False while a
    /// log load runs; its completion checks again. Other worktrees' rows count as the log has them: a change there is
    /// `updateWorktreeRows`' (a new layout, no new `git log`).
    private var syntheticRowsChanged: Bool {
        guard logTask == nil, let log = log.value, log.isComplete, let status = status.value, let stashes else {
            return false
        }
        return Self.syntheticRows(status: status, stashes: stashes, worktrees: log.worktrees) != log.synthetic
    }

    /// The synthetic rows: the WIP row when the working tree has changes (hanging from HEAD, above the commits), then
    /// one per other worktree with changes (right above its HEAD), then the stashes (each right above the commit it was
    /// made on), newest first.
    nonisolated static func syntheticRows(status: WorkingStatus, stashes: [Stash], worktrees: [WorktreeInfo])
        -> [GraphSyntheticRow]
    {
        var rows: [GraphSyntheticRow] = []
        if !status.entries.isEmpty {
            rows.append(GraphSyntheticRow(kind: .wip, id: "wip", base: status.branch.commit))
        }
        rows += worktreeRows(worktrees)
        for stash in stashes {
            rows.append(GraphSyntheticRow(kind: .stash, id: stash.hash, base: stash.base))
        }
        return rows
    }

    @concurrent
    private nonisolated static func read(_ backend: Backend, cwd: URL, status: Bool, refs: Bool) async throws
        -> (WorkingStatus?, RepoState?, Refs?, [Stash]?, [RemoteInfo]?, UndoStatus?)
    {
        let env = try await backend.readEnvironment(cwd: cwd)
        async let newStatus = status ? StatusReader.read(runner: backend.runner, cwd: cwd, env: env) : nil
        // The banner is secondary: a state that cannot be read keeps the last one rather than failing the status.
        async let newState = status ? (try? await RepoState.read(runner: backend.runner, cwd: cwd, env: env)) : nil
        async let newRefs = refs ? RefReader.read(runner: backend.runner, cwd: cwd, env: env) : nil
        // `refs/stash` is a ref: the watcher reports a stash change as `.refs`.
        async let newStashes = refs ? StashWorktreeReader.stashes(runner: backend.runner, cwd: cwd, env: env) : nil
        // The remotes live in the config, which the watcher does not follow: read with every refs read (each write
        // rereads the refs).
        async let newRemotes = refs ? readRemotes(backend, cwd: cwd, env: env) : nil
        // Every journaled write moves a ref or comes with one (each write rereads the refs), so the journal is read
        // with them; and with the status, since an index change made outside Histq (a terminal `git add`) makes the
        // stage entries on top stale.
        async let newUndo = status || refs
            ? UndoStatus(backend.journal, ops: GitOperations(runner: backend.runner, cwd: cwd, env: env)) : nil
        return (
            try await newStatus, await newState, try await newRefs, try await newStashes, try await newRemotes,
            await newUndo
        )
    }

    /// `git remote -v`: each remote's fetch URL, in git's order.
    private nonisolated static func readRemotes(_ backend: Backend, cwd: URL, env: [String: String]) async throws
        -> [RemoteInfo]
    {
        let output = try await backend.runner.run(["remote", "-v"], cwd: cwd, env: env).text
        var remotes: [RemoteInfo] = []
        for line in output.split(separator: "\n") where line.hasSuffix(" (fetch)") {
            let fields = line.dropLast(" (fetch)".count).split(separator: "\t", maxSplits: 1)
            guard fields.count == 2 else { continue }
            remotes.append(RemoteInfo(name: String(fields[0]), url: String(fields[1])))
        }
        return remotes
    }

    /// `refs` without the refs the graph leaves out (`visibility.hidden`; the checked-out branch always stays): what
    /// the graph labels and attributes its commits to.
    var visibleRefs: Refs? {
        refs.value.map { $0.hiding(visibility.hidden) }
    }

    // MARK: Log

    /// (Re)loads the log and lays out its graph off the main actor. The first load publishes the first page as soon as
    /// it is parsed; a reload first tries to read only the new commits (`readLogIncrementally`), else reads the whole
    /// log, and keeps the old log on screen until the new one is complete. A newer load cancels this one.
    private func loadLog(_ backend: Backend) {
        logTask?.cancel()
        let isFirstLoad = log.value == nil
        if isFirstLoad { log = .loading }
        let cwd = url
        logGeneration &+= 1
        let generation = logGeneration
        // The rows of the other worktrees as last read (none before the first read, which waits for this first page).
        let worktrees = dirtyWorktrees
        // The first load starts beside the first refs read: with a saved view and no refs yet, `readLog` reads them.
        let filter: LogFilter? = view == .empty || refs.value != nil ? visibility : nil
        let view = view
        let order = commitOrder
        // A complete log on screen read with the same hidden branches, none soloed, in the same order: a reload first
        // reads only the commits that are new since it. Hiding, showing or soloing a branch, or changing the order,
        // reads the whole log again (a soloed log always).
        let oldLog = log.value.flatMap { old in
            old.isComplete && filter?.hidden == old.filter.hidden && filter?.solo.isEmpty == true
                && old.filter.solo.isEmpty && old.order == order ? old : nil
        }
        logTask = Task { [weak self] in
            // Keeps App Nap from throttling the load while the app is in the background.
            let activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiated, reason: "Reloading the commit log")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                let start = DispatchTime.now().uptimeNanoseconds
                UITiming.logStart(generation: generation, incremental: oldLog != nil)
                var incremental: LogSnapshot?
                if let oldLog, let filter {
                    do {
                        incremental = try await Self.readLogIncrementally(
                            backend, previous: oldLog, cwd: cwd, generation: generation, worktrees: worktrees,
                            filter: filter, order: order)
                    } catch where !Self.isCancellation(error) {
                        Self.logger.error("incremental log reload failed: \(error, privacy: .public)")
                    }
                }
                let snapshot: LogSnapshot
                if let incremental {
                    snapshot = incremental
                } else {
                    snapshot = try await Self.readLog(
                        backend, cwd: cwd, generation: generation, worktrees: worktrees, filter: filter, view: view,
                        order: order
                    ) { first in
                        guard isFirstLoad, !Task.isCancelled else { return }
                        await MainActor.run {
                            self?.log = .loaded(first)
                            self?.updateBranchMap()
                            self?.loadWorktrees(backend)
                            self?.loadSubmodules(backend)
                        }
                    }
                }
                try Task.checkCancellation()
                if !isFirstLoad {
                    let ms = String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                    if let incremental, let oldLog {
                        UITiming.logReload("incremental \(incremental.commits.count - oldLog.commits.count) \(ms) "
                            + incremental.readSteps)
                    } else {
                        UITiming.logReload("full \(ms)")
                    }
                }
                guard let self else { return }
                let publishStart = DispatchTime.now().uptimeNanoseconds
                let previous = log.value
                log = .loaded(snapshot)
                logTask = nil
                UITiming.logComplete(commitCount: snapshot.commits.count)
                updateBranchMap()
                if !isFirstLoad { dropVanishedSelection(previousLog: previous) }
                UITiming.logPublish(since: publishStart)
                // A log without a page (an unborn branch) never started the worktrees' first read.
                if case .idle = self.worktrees { loadWorktrees(backend) }
                if case .idle = self.submodules { loadSubmodules(backend) }
                // The status or the stashes changed while it loaded, or the worktrees were read meanwhile; or the
                // refs it read itself differ from the session's.
                if syntheticRowsChanged || (filter == nil && refs.value != nil && snapshot.filter != visibility) {
                    UITiming.logAgain(syntheticRowsChanged ? "synthetic" : "filter")
                    loadLog(backend)
                } else {
                    updateWorktreeRows(backend)
                }
            } catch {
                guard !Self.isCancellation(error), let self else { return }
                logTask = nil
                if isFirstLoad || log.value == nil {
                    log = .failed(Self.message(for: error))
                } else {
                    Self.logger.error("log reload failed: \(error, privacy: .public)")
                    // The old log stays: map it to the refs that moved.
                    if branchMapRefsStale { updateBranchMap() }
                }
            }
        }
    }

    /// Parses every page and lays it out, off the main actor, below the WIP and stash rows (the status and the stashes
    /// are read while git walks the history). `firstPage` gets the first page (laid out) as soon as it is ready.
    /// `filter`: the graph's hidden, soloed and pinned branches; nil = resolve `view` against refs read here. `order`:
    /// the order git lists the commits in.
    /// Throws `CancellationError` when cancelled (the stream itself ends without an error then).
    @concurrent
    private nonisolated static func readLog(
        _ backend: Backend, cwd: URL, generation: Int, worktrees: [WorktreeInfo], filter: LogFilter?,
        view: RepoViewState, order: LogReader.Order, firstPage: @Sendable (LogSnapshot) async -> Void
    ) async throws -> LogSnapshot {
        let env = try await backend.readEnvironment(cwd: cwd)
        async let status = StatusReader.read(runner: backend.runner, cwd: cwd, env: env)
        var snapshot = LogSnapshot(generation: generation, order: order)
        if let filter {
            snapshot.filter = filter
        } else {
            snapshot.filter = logFilter(
                view: view, refs: try await RefReader.read(runner: backend.runner, cwd: cwd, env: env))
        }
        let filter = snapshot.filter
        snapshot.isShallow = isShallow(backend)
        // Read first: the log also reads the stashes' bases, which no branch may hold any more (not in solo mode).
        snapshot.stashes = try await StashWorktreeReader.stashes(runner: backend.runner, cwd: cwd, env: env)
        let pages = LogReader.pages(
            runner: backend.runner, cwd: cwd, env: env,
            alsoFrom: filter.solo.isEmpty ? snapshot.stashes.map(\.base) : [],
            hidden: filter.hidden.sorted(), solo: filter.solo, order: order)
        snapshot.worktrees = worktrees
        snapshot.synthetic = syntheticRows(status: try await status, stashes: snapshot.stashes, worktrees: worktrees)
        var (layout, top) = beginLayout(&snapshot)
        var isFirst = true
        for try await page in pages {
            for (offset, commit) in page.enumerated() {
                snapshot.commitIndex[commit.hash] = snapshot.commits.count + offset
            }
            snapshot.commits += page
            let rows = layout.append(page)
            snapshot.rows += rows
            snapshot.hung = layout.hung
            snapshot.lanes = max(snapshot.lanes, lanes(of: rows), lanes(of: snapshot.hung.map(\.row)))
            if isFirst {
                isFirst = false
                await firstPage(snapshot)
            }
        }
        try Task.checkCancellation()
        snapshot.syntheticRows += top.append(layout.waiting.map { .init(kind: $0.kind, id: $0.id, base: nil) })
        snapshot.lanes = max(snapshot.lanes, lanes(of: snapshot.syntheticRows))
        snapshot.isComplete = true
        snapshot.tips = LogReader.tips(of: snapshot.commits, index: snapshot.commitIndex)
        // Made shallow while git read the history: the next reload must not trust it.
        snapshot.isShallow = snapshot.isShallow || isShallow(backend)
        return snapshot
    }

    /// `row`'s base is not in the complete log `snapshot`.
    nonisolated private static func isMissingBase(_ row: GraphSyntheticRow, in snapshot: LogSnapshot) -> Bool {
        guard snapshot.isComplete, let base = row.base else { return false }
        return snapshot.commitIndex[base] == nil
    }

    /// A top row of the complete `log` (the WIP row; the other worktrees' rows hang) was laid out with a line to a base
    /// the log does not hold: its line runs to the end until it is laid out again (`beginLayout`).
    private static func hasLineToMissingBase(_ log: LogSnapshot) -> Bool {
        log.syntheticRows.contains { row in
            guard case .synthetic(let synthetic) = row.node else { return false }
            return isMissingBase(synthetic, in: log)
        }
    }

    /// The log after a reload, from `previous` (a complete snapshot) and only the commits that are new since it
    /// (`LogReader.newCommits`), with the status and stashes read again, every row laid out again off the main actor.
    /// `filter` has `previous`'s hidden branches and no soloed one (the caller checks): the new commits leave out the
    /// same refs, and its pinned tips (which move with their branches) lay the rows out. Nil when the new commits cannot be proven to be the whole difference (a commit of `previous` no longer
    /// reachable, a shallow repo, a graft file or a replace ref): the caller reads the whole log. Throws
    /// `CancellationError` when cancelled.
    ///
    /// `order` is `previous`'s (the caller checks). The result has the same commits as a fresh read, children before
    /// parents, the commits of `previous` in their order. By branch the new ones come on top, not always where git's
    /// `--topo-order` puts them: after a commit on a branch other than the newest one, a fresh read would list that
    /// branch's whole line first. By date they are merged in by committer date (`LogReader.mergedByDate`), where a
    /// fresh `--date-order` read puts them unless committer dates are skewed (a child older than its parent) or equal.
    @concurrent
    private nonisolated static func readLogIncrementally(
        _ backend: Backend, previous: LogSnapshot, cwd: URL, generation: Int, worktrees: [WorktreeInfo],
        filter: LogFilter, order: LogReader.Order
    ) async throws -> LogSnapshot? {
        var steps = UITiming.Steps()
        guard previous.isComplete, !previous.isShallow, !isShallow(backend), !hasGrafts(backend) else { return nil }
        let env = try await backend.readEnvironment(cwd: cwd)
        async let status = StatusReader.read(runner: backend.runner, cwd: cwd, env: env)
        steps.lap("env")
        var snapshot = LogSnapshot(generation: generation, order: order)
        snapshot.filter = filter
        snapshot.stashes = try await StashWorktreeReader.stashes(runner: backend.runner, cwd: cwd, env: env)
        steps.lap("stashes")
        let tips = previous.tips
        steps.lap("tips")
        guard let delta = try await LogReader.newCommits(
            runner: backend.runner, cwd: cwd, env: env, previousTips: tips,
            alsoFrom: snapshot.stashes.map(\.base), hidden: filter.hidden.sorted(), order: order),
            !delta.contains(where: { previous.commitIndex[$0.hash] != nil })
        else { return nil }
        steps.lap("delta")
        snapshot.tips = LogReader.tips(adding: delta, to: tips)
        steps.lap("tips")
        snapshot.worktrees = worktrees
        snapshot.synthetic = syntheticRows(status: try await status, stashes: snapshot.stashes, worktrees: worktrees)
        // The status's wait (it runs alongside the steps above) counts with the environment.
        steps.lap("env")
        try Task.checkCancellation()
        if delta.isEmpty {
            snapshot.commits = previous.commits
            steps.lap("concat")
            snapshot.commitIndex = previous.commitIndex
        } else {
            snapshot.commits = order == .date
                ? LogReader.mergedByDate(delta, into: previous.commits, index: previous.commitIndex)
                : delta + previous.commits
            steps.lap("concat")
            snapshot.commitIndex.reserveCapacity(snapshot.commits.count)
            for (index, commit) in snapshot.commits.enumerated() { snapshot.commitIndex[commit.hash] = index }
        }
        steps.lap("index")
        try Task.checkCancellation()
        snapshot.isComplete = true
        layOutAll(&snapshot)
        steps.lap("layout")
        snapshot.readSteps = steps.description
        try Task.checkCancellation()
        return snapshot
    }

    /// Whether the repo is a shallow clone now (`<common dir>/shallow` exists).
    nonisolated private static func isShallow(_ backend: Backend) -> Bool {
        FileManager.default.fileExists(atPath: backend.directories.commonDir.appending(path: "shallow").path)
    }

    /// Whether the repo has a graft file (`<common dir>/info/grafts`), which can give an old commit other parents.
    nonisolated private static func hasGrafts(_ backend: Backend) -> Bool {
        FileManager.default.fileExists(atPath: backend.directories.commonDir.appending(path: "info/grafts").path)
    }

    /// Lays out `snapshot.synthetic`'s WIP row at the top and hangs the other worktrees' rows and its stashes above
    /// their bases (another worktree's changes sit on its HEAD, not above every commit). Returns the
    /// layout to feed the commits, and the top rows' layout: the hung rows whose base never came are laid out with it
    /// once the log is complete, at the top without a line (they open no lane, so the commit rows stay as they are).
    /// The pinned branches take the leftmost lanes.
    nonisolated private static func beginLayout(_ snapshot: inout LogSnapshot) -> (layout: GraphLayout, top: GraphLayout) {
        var layout = GraphLayout(pinned: snapshot.filter.pinned)
        snapshot.syntheticRows = layout.append(snapshot.synthetic.filter { $0.kind == .wip }.map { row in
            isMissingBase(row, in: snapshot) ? GraphSyntheticRow(kind: row.kind, id: row.id, base: nil) : row
        })
        snapshot.lanes = lanes(of: snapshot.syntheticRows)
        let top = layout
        layout.hang(snapshot.synthetic.filter { $0.kind != .wip })
        return (layout, top)
    }

    // MARK: Branch visibility

    /// Branches older than this (their tip's committer date) are stale.
    private nonisolated static let staleAge: TimeInterval = 90 * 24 * 60 * 60

    /// The graph and the sidebar's lists leave `ref` (a full ref name) out: hidden, the own upstream of a hidden local
    /// branch, or stale.
    func isHidden(_ ref: String) -> Bool { visibility.hidden.contains(ref) }
    /// The user soloed `ref`.
    func isSoloed(_ ref: String) -> Bool { view.solo.contains(ref) }
    /// The user pinned `ref` to the left.
    func isPinned(_ ref: String) -> Bool { view.pinned.contains(ref) }
    /// The branches and tags the graph leaves out (the chip's count).
    var hiddenCount: Int { visibility.hidden.count }
    /// The graph shows only the soloed branches and HEAD.
    var isSoloActive: Bool { !visibility.solo.isEmpty }

    /// `ref`'s tip is older than 90 days (what "hide stale branches" hides).
    func isStale(_ ref: String) -> Bool {
        guard let refs = refs.value else { return false }
        let date = refs.localBranches.first { $0.refName == ref }?.tipDate
            ?? refs.remoteBranches.first { $0.refName == ref }?.tipDate
        return date.map { $0 < Date.now.addingTimeInterval(-Self.staleAge) } ?? false
    }

    /// Hides `ref` (a branch or a tag) from the graph and the sidebar's lists; never the current branch. Its row, if
    /// selected, no longer is.
    func hide(_ ref: String) {
        if case .branch(let name, _) = refs.value?.head, ref == "refs/heads/\(name)" { return }
        guard !view.hidden.contains(ref) else { return }
        view.hidden.append(ref)
        if sidebarSelection?.fullRefName == ref { sidebarSelection = nil }
        viewChanged()
    }

    /// Shows `ref` again, and the hidden local branches it is the own upstream of. A stale branch stays hidden while
    /// "hide stale branches" is on.
    func show(_ ref: String) {
        let locals = refs.value?.localBranches.filter { local in
            Self.tracksOwnName(local) && local.upstream.map { "refs/remotes/\($0)" } == ref
        }.map(\.refName) ?? []
        let hidden = view.hidden.filter { $0 != ref && !locals.contains($0) }
        guard hidden != view.hidden else { return }
        view.hidden = hidden
        viewChanged()
    }

    func solo(_ ref: String) {
        guard !view.solo.contains(ref) else { return }
        view.solo.append(ref)
        viewChanged()
    }

    func unsolo(_ ref: String) {
        guard view.solo.contains(ref) else { return }
        view.solo.removeAll { $0 == ref }
        viewChanged()
    }

    func pin(_ ref: String) {
        guard !view.pinned.contains(ref) else { return }
        view.pinned.append(ref)
        viewChanged()
    }

    func unpin(_ ref: String) {
        guard view.pinned.contains(ref) else { return }
        view.pinned.removeAll { $0 == ref }
        viewChanged()
    }

    func setHideStale(_ on: Bool) {
        guard view.hideStale != on else { return }
        view.hideStale = on
        viewChanged()
    }

    /// Shows every branch: no hidden or soloed one, stale ones too. Pins stay.
    func showAll() {
        guard !view.hidden.isEmpty || !view.solo.isEmpty || view.hideStale else { return }
        view.hidden = []
        view.solo = []
        view.hideStale = false
        viewChanged()
    }

    /// Folds the refs an earlier build hid for this folder (`PrefKey.hiddenRefs`) into `view` once, then drops them
    /// from that key.
    private func migrateHiddenRefs() {
        let key = PrefKey.hiddenRefs.rawValue
        guard var stored = Preferences.defaults.dictionary(forKey: key) as? [String: [String]],
              let old = stored.removeValue(forKey: url.path)
        else { return }
        view.hidden += old.filter { !view.hidden.contains($0) }
        Preferences.defaults.set(stored, forKey: key)
        saveView()
    }

    /// After a change of `view`, in the click's frame: the graph's filter follows, the view is saved and the log read
    /// again off the main actor (the old one stays on screen until then; a selected commit still in it stays selected).
    private func viewChanged() {
        updateVisibility()
        saveView()
        refresh(scope: .log)
    }

    private func updateVisibility() {
        let new = view == .empty ? LogFilter() : refs.value.map { Self.logFilter(view: view, refs: $0) } ?? LogFilter()
        if new != visibility { visibility = new }
    }

    /// Drops the branches (and hidden tags) `refs` no longer has from `view` (deleted, pruned, renamed outside Histq):
    /// a soloed one would make `git log` fail.
    private func pruneView(_ refs: Refs) {
        guard view != .empty else { return }
        let names = Set(refs.localBranches.map(\.refName) + refs.remoteBranches.map(\.refName))
        let tags = Set(refs.tags.map(\.refName))
        var pruned = view
        pruned.hidden.removeAll { !names.contains($0) && !tags.contains($0) }
        pruned.solo.removeAll { !names.contains($0) }
        pruned.pinned.removeAll { !names.contains($0) }
        guard pruned != view else { return }
        view = pruned
        saveView()
    }

    /// Saves `view` off the main actor, after the saves before it.
    private func saveView() {
        let (state, cwd, previous) = (view, url, viewSave)
        viewSave = Task {
            await previous?.value
            do {
                try await Self.save(state, cwd: cwd)
            } catch {
                Self.logger.error("view save failed: \(error, privacy: .public)")
            }
        }
    }

    @concurrent
    private nonisolated static func save(_ state: RepoViewState, cwd: URL) async throws {
        try state.save(key: stateKey(cwd))
    }

    /// `view` against `refs`. Hidden: the hidden branches and tags that exist but the current branch, each hidden local one's
    /// own upstream (see `tracksOwnName`) and, with "hide stale branches" on, every branch whose tip is older than
    /// `staleAge`; the last two never hide the current branch's upstream, and stale never a pinned branch. Solo: the soloed branches that exist; none on an unborn branch (git cannot read its
    /// HEAD). Pinned: the tips of the pinned branches that are shown (in solo mode only the soloed ones and the
    /// current branch), each tip once.
    nonisolated static func logFilter(view: RepoViewState, refs: Refs, now: Date = .now) -> LogFilter {
        let remotes = Dictionary(refs.remoteBranches.map { ($0.name, $0.refName) }) { first, _ in first }
        let upstream = { (local: LocalBranch) in local.upstream.flatMap { remotes[$0] } }
        let head = refs.localBranches.first(where: \.isHead)
        let kept = Set([head?.refName, head.flatMap(upstream)].compactMap(\.self))
        let hiddenNames = Set(view.hidden)
        let pinnedNames = Set(view.pinned)
        let cutoff = now.addingTimeInterval(-staleAge)
        let isStale = { (ref: String, date: Date?) in
            view.hideStale && !kept.contains(ref) && !pinnedNames.contains(ref) && date.map { $0 < cutoff } ?? false
        }
        var hidden: Set<String> = []
        for local in refs.localBranches {
            if hiddenNames.contains(local.refName) {
                hidden.insert(local.refName)
                if tracksOwnName(local), let ref = upstream(local), !kept.contains(ref) { hidden.insert(ref) }
            } else if isStale(local.refName, local.tipDate) {
                hidden.insert(local.refName)
            }
        }
        for remote in refs.remoteBranches
        where hiddenNames.contains(remote.refName) || isStale(remote.refName, remote.tipDate) {
            hidden.insert(remote.refName)
        }
        // A tag is only ever hidden by hand: never stale, soloed or pinned.
        for tag in refs.tags where hiddenNames.contains(tag.refName) { hidden.insert(tag.refName) }
        // The current branch shows even when hidden before it was checked out.
        if let head { hidden.remove(head.refName) }

        let tips = Dictionary(
            refs.localBranches.map { ($0.refName, $0.commit) } + refs.remoteBranches.map { ($0.refName, $0.commit) }
        ) { first, _ in first }
        let solo = refs.head.commit == nil ? [] : view.solo.filter { tips[$0] != nil }
        var pinned: [String] = []
        for ref in view.pinned where !hidden.contains(ref) && (solo.isEmpty || solo.contains(ref) || ref == head?.refName) {
            if let tip = tips[ref], !pinned.contains(tip) { pinned.append(tip) }
        }
        return LogFilter(hidden: hidden, solo: solo, pinned: pinned)
    }

    /// `local`'s upstream is its own remote counterpart (`feature` → `origin/feature`), which hiding `local` hides too;
    /// not a branch others may track as well (`feature` made from `origin/main`).
    private nonisolated static func tracksOwnName(_ local: LocalBranch) -> Bool {
        local.upstream.map { $0.drop { $0 != "/" }.dropFirst() == local.name } ?? false
    }

    /// Lays out `snapshot`'s synthetic rows and all its commits in one go (`beginLayout`); once the log is complete,
    /// the hung rows whose base is not in it go at the top without a line.
    nonisolated private static func layOutAll(_ snapshot: inout LogSnapshot) {
        var (layout, top) = beginLayout(&snapshot)
        snapshot.rows = layout.append(snapshot.commits)
        snapshot.hung = layout.hung
        if snapshot.isComplete {
            snapshot.syntheticRows += top.append(layout.waiting.map { .init(kind: $0.kind, id: $0.id, base: nil) })
        }
        snapshot.lanes = max(
            lanes(of: snapshot.syntheticRows), lanes(of: snapshot.rows), lanes(of: snapshot.hung.map(\.row)))
    }

    /// The most lanes one of `rows` draws in (`LogSnapshot.lanes`).
    nonisolated private static func lanes(of rows: [GraphRow]) -> Int {
        rows.reduce(0) { max($0, $1.width) }
    }

    // MARK: Worktrees

    /// The other worktrees whose changes get a graph row, in `git worktree list` order.
    private var dirtyWorktrees: [WorktreeInfo] {
        (worktrees.value ?? []).filter { !$0.isCurrent && $0.isDirty }
    }

    nonisolated static func worktreeRows(_ worktrees: [WorktreeInfo]) -> [GraphSyntheticRow] {
        worktrees.map { GraphSyntheticRow(kind: .worktreeWIP, id: $0.path, base: $0.worktree.head) }
    }

    /// Rereads the worktrees when the tab is shown again: another worktree's files may have changed in its own tab (the
    /// watcher only follows this worktree's). Nothing before the first log page, which starts the first read.
    func refreshWorktrees() {
        guard log.value != nil, worktreeTask == nil else { return }
        Task { [weak self] in
            guard let backend = try? await self?.backend() else { return }
            self?.loadWorktrees(backend)
        }
    }

    /// Reads the worktree list and the other worktrees' change counts off the main actor, then publishes them and lays
    /// out their graph rows. A newer read cancels this one.
    private func loadWorktrees(_ backend: Backend) {
        worktreeTask?.cancel()
        if worktrees.value == nil { worktrees = .loading }
        let cwd = url
        worktreeTask = Task { [weak self] in
            do {
                let list = try await Self.readWorktrees(backend, cwd: cwd)
                try Task.checkCancellation()
                guard let self else { return }
                worktreeTask = nil
                if worktrees.value != list {
                    worktrees = .loaded(list)
                    refreshWorktreeSelection(backend)
                }
                updateWorktreeRows(backend)
            } catch {
                guard !Self.isCancellation(error), let self else { return }
                worktreeTask = nil
                Self.logger.error("worktree read failed: \(error, privacy: .public)")
                if worktrees.value == nil { worktrees = .failed(Self.message(for: error)) }
            }
        }
    }

    /// `git worktree list` here, then each other worktree's status in its own folder, with the read environment built
    /// for that folder (its filter and diff drivers). A worktree whose status cannot be read gets no counts rather than
    /// failing the list; bare and missing (prunable) ones are not read.
    @concurrent
    private nonisolated static func readWorktrees(_ backend: Backend, cwd: URL) async throws -> [WorktreeInfo] {
        let env = try await backend.readEnvironment(cwd: cwd)
        let list = try await StashWorktreeReader.worktrees(runner: backend.runner, cwd: cwd, env: env)
        let current = backend.directories.worktree.resolvingSymlinksInPath().path
        var changes: [Int: WorktreeChanges] = [:]
        try await withThrowingTaskGroup(of: (Int, WorktreeChanges?).self) { group in
            for (index, worktree) in list.enumerated() {
                let folder = URL(filePath: worktree.path, directoryHint: .isDirectory)
                guard !worktree.isBare, !worktree.isPrunable, folder.resolvingSymlinksInPath().path != current
                else { continue }
                group.addTask {
                    var isFolder: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue,
                          let env = try? await backend.readEnvironment(cwd: folder),
                          let status = try? await StatusReader.read(runner: backend.runner, cwd: folder, env: env)
                    else { return (index, nil) }
                    return (index, WorktreeChanges(status))
                }
            }
            for try await (index, change) in group { changes[index] = change }
        }
        try Task.checkCancellation()
        return list.enumerated().map { index, worktree in
            WorktreeInfo(
                worktree: worktree,
                isCurrent: URL(filePath: worktree.path).resolvingSymlinksInPath().path == current,
                changes: changes[index])
        }
    }

    /// Reads the submodules off the main actor (`SubmoduleReader.list`), then publishes them when they changed. A newer
    /// read cancels this one. A repo without `.gitmodules` gets `.loaded([])` at once, with no read.
    private func loadSubmodules(_ backend: Backend) {
        submoduleTask?.cancel()
        let cwd = backend.directories.worktree
        guard FileManager.default.fileExists(atPath: cwd.appending(path: ".gitmodules").path) else {
            submoduleTask = nil
            if submodules.value != [] {
                submodules = .loaded([])
                refreshSubmoduleSelection(backend)
            }
            return
        }
        if submodules.value == nil { submodules = .loading }
        submoduleTask = Task { [weak self] in
            do {
                let list = try await Self.readSubmodules(backend, cwd: cwd)
                try Task.checkCancellation()
                guard let self else { return }
                submoduleTask = nil
                if submodules.value != list {
                    submodules = .loaded(list)
                    refreshSubmoduleSelection(backend)
                }
            } catch {
                guard !Self.isCancellation(error), let self else { return }
                submoduleTask = nil
                Self.logger.error("submodule read failed: \(error, privacy: .public)")
                if submodules.value == nil { submodules = .failed(Self.message(for: error)) }
            }
        }
    }

    @concurrent
    private nonisolated static func readSubmodules(_ backend: Backend, cwd: URL) async throws -> [Submodule] {
        try await SubmoduleReader.list(runner: backend.runner, cwd: cwd, base: backend.base)
    }

    /// After the submodules are read again: a selected submodule moves on once it is gone (`dropVanishedSelection`),
    /// else its detail is read again in place (no placeholder; a failed read keeps it as it was).
    private func refreshSubmoduleSelection(_ backend: Backend) {
        guard case .submodule(let path) = selection else { return }
        dropVanishedSelection()
        guard selection == .submodule(path), case .loaded(.submodule) = detail else { return }
        let token = selectToken
        let list = submodules.value
        detailTask?.cancel()
        detailTask = Task { [weak self] in
            guard let loaded = try? await Self.readSubmoduleDetail(backend, path: path, list: list), let self,
                  token == selectToken
            else { return }
            detail = .loaded(.submodule(loaded))
        }
    }

    /// A submodule's detail, off the main actor: its entry of `list` (read here when nil), then in its checkout the
    /// recorded and checked-out commits and, when they differ, the commits between them (`SubmoduleReader`).
    @concurrent
    private nonisolated static func readSubmoduleDetail(_ backend: Backend, path: String, list: [Submodule]?)
        async throws -> SubmoduleDetail
    {
        let cwd = backend.directories.worktree
        let list = if let list { list } else {
            try await SubmoduleReader.list(runner: backend.runner, cwd: cwd, base: backend.base)
        }
        guard let submodule = list.first(where: { $0.path == path }) else {
            throw SubmoduleOperationError.notASubmodule(path)
        }
        let isNested = SubmoduleDetail.isNested(path, in: list)
        guard case .checkedOut(let head, _) = submodule.state else {
            return SubmoduleDetail(submodule: submodule, isNested: isNested, recorded: nil, checkedOut: nil, change: nil)
        }
        let folder = cwd.appending(path: path, directoryHint: .isDirectory)
        let recorded = submodule.recordedCommit
        async let commits = SubmoduleReader.commits(
            runner: backend.runner, in: folder, base: backend.base,
            shas: submodule.isMoved ? [recorded, head] : [recorded])
        let change: SubmoduleChange? = if submodule.isMoved {
            try await SubmoduleReader.change(runner: backend.runner, in: folder, base: backend.base, from: recorded,
                                             to: head)
        } else { nil }
        let found = try await commits
        return SubmoduleDetail(
            submodule: submodule, isNested: isNested, recorded: found.first { $0.sha == recorded },
            checkedOut: found.first { $0.sha == head }, change: change)
    }

    /// After the worktrees are read again: another worktree's changes on screen move on once it is clean or gone
    /// (`dropVanishedSelection`), else are read again in place (no placeholder; a failed read keeps them as they were).
    private func refreshWorktreeSelection(_ backend: Backend) {
        guard case .worktree(let path) = selection else { return }
        dropVanishedSelection()
        guard selection == .worktree(path), case .loaded(.worktree) = detail else { return }
        let token = selectToken
        detailTask?.cancel()
        detailTask = Task { [weak self] in
            guard let status = try? await Self.readWorktreeStatus(backend, path: path), let self, token == selectToken
            else { return }
            detail = .loaded(.worktree(path, status))
        }
    }

    /// Another worktree's status, read in its own folder with the read environment built for it (as `readWorktrees`).
    @concurrent
    private nonisolated static func readWorktreeStatus(_ backend: Backend, path: String) async throws -> WorkingStatus {
        let folder = URL(filePath: path, directoryHint: .isDirectory)
        let env = try await backend.readEnvironment(cwd: folder)
        return try await StatusReader.read(runner: backend.runner, cwd: folder, env: env)
    }

    /// Lays the graph out again when the other worktrees' rows no longer match the loaded log's: from the commits in
    /// memory, off the main actor, as a new generation (the graph reloads, keeping its scroll). Waits for a log load in
    /// flight; its completion calls this again.
    private func updateWorktreeRows(_ backend: Backend) {
        guard logTask == nil, let current = log.value, current.isComplete else { return }
        let worktrees = dirtyWorktrees
        guard worktrees != current.worktrees || Self.hasLineToMissingBase(current) else { return }
        UITiming.logAgain("worktree")
        logGeneration &+= 1
        let generation = logGeneration
        logTask = Task { [weak self] in
            let activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiated, reason: "Laying out the commit graph")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let snapshot = await Self.relayout(current, worktrees: worktrees, generation: generation)
            guard !Task.isCancelled, let self else { return }
            log = .loaded(snapshot)
            logTask = nil
            updateBranchMap()
            if syntheticRowsChanged {
                UITiming.logAgain("synthetic")
                loadLog(backend)
            } else {
                updateWorktreeRows(backend)
            }
        }
    }

    /// Computes `branchMap` for the log and refs now, off the main actor; a newer run cancels this one. Nothing until
    /// both are read.
    private func updateBranchMap() {
        guard let log = log.value, let refs = visibleRefs else { return }
        branchMapRefsStale = false
        branchMapTask?.cancel()
        UITiming.branchMapStart(generation: log.generation)
        branchMapTask = Task { [weak self] in
            let activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiated, reason: "Mapping commits to branches")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let (names, claims, ms) = await Self.attributeBranches(log, refs: refs)
            guard !Task.isCancelled else { return UITiming.branchMapCancelled(ms: ms) }
            guard let self else { return }
            branchMap = BranchMap(
                names: names, claims: claims, logGeneration: log.generation, generation: branchMap.generation &+ 1)
            branchMapTask = nil
            UITiming.branchMap(count: claims.count, ms: ms)
        }
    }

    /// `BranchAttribution.claims` of `log` and `refs`, with how long it took (ms).
    @concurrent
    private nonisolated static func attributeBranches(_ log: LogSnapshot, refs: Refs) async
        -> ([String], [Int32], Double)
    {
        let start = DispatchTime.now().uptimeNanoseconds
        let (names, claims) = BranchAttribution.claims(commits: log.commits, refs: refs, index: log.commitIndex)
        return (names, claims, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }

    /// `log` with `worktrees`' rows in place of its own (after the WIP row, before the stashes), every row laid out again.
    @concurrent
    private nonisolated static func relayout(_ log: LogSnapshot, worktrees: [WorktreeInfo], generation: Int) async
        -> LogSnapshot
    {
        var snapshot = log
        snapshot.generation = generation
        snapshot.worktrees = worktrees
        snapshot.synthetic = log.synthetic.filter { $0.kind == .wip } + worktreeRows(worktrees)
            + log.synthetic.filter { $0.kind == .stash }
        layOutAll(&snapshot)
        return snapshot
    }

    /// A problem of the Add Worktree form, worded for it.
    struct FormProblem: Error {
        let message: String
    }

    /// The Add Worktree form's write once its input checks out (off the main actor): a folder name without `/`, `.`
    /// or control characters; an existing parent folder and no item at the new path; a revision that resolves to a
    /// commit (passed on as its id); a valid new branch name.
    func addWorktreeWrite(parent: String, name: String, start: WorktreeForm.Start, newBranch: String?) async
        -> Result<Write, FormProblem>
    {
        guard let backend = try? await backend() else { return .failure(FormProblem(message: "The repository is not ready.")) }
        return await Self.addWorktreeWrite(
            parent: parent, name: name, start: start, newBranch: newBranch, backend: backend, cwd: url)
    }

    @concurrent
    private nonisolated static func addWorktreeWrite(
        parent: String, name: String, start: WorktreeForm.Start, newBranch: String?, backend: Backend, cwd: URL
    ) async -> Result<Write, FormProblem> {
        let hasControl = { (text: String) in
            text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        guard !name.isEmpty, !name.contains("/"), name != ".", name != "..", !hasControl(name) else {
            return .failure(FormProblem(message: "\"\(name)\" cannot be a folder name."))
        }
        guard let parent = ProfileLibrary.absolutePath(parent) else {
            return .failure(FormProblem(message: "Choose the folder to create the worktree in."))
        }
        let path = (parent as NSString).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: path) {
            return .failure(FormProblem(message: "\(ProfileLibrary.abbreviated(path)) already exists."))
        }
        do {
            try GitOperations.validateWorktreePath(path)
        } catch {
            return .failure(FormProblem(message: "\(ProfileLibrary.abbreviated(parent)) is not a folder."))
        }
        guard let env = try? await backend.readEnvironment(cwd: cwd) else {
            return .failure(FormProblem(message: "The repository could not be read."))
        }
        if let newBranch {
            let ops = GitOperations(runner: backend.runner, cwd: cwd, env: env)
            do { try await ops.validateBranchName(newBranch) } catch {
                return .failure(FormProblem(message: message(for: error)))
            }
        }
        let source: GitOperations.WorktreeSource
        switch start {
        case .branch(let branch):
            source = .branch(branch)
        case .revision(let text):
            let revision = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // `--end-of-options`: a revision typed as `-x` is a revision, never an option.
            let result = hasControl(revision) ? nil : try? await backend.runner.run(
                ["rev-parse", "--verify", "--quiet", "--end-of-options", revision + "^{commit}"], cwd: cwd, env: env,
                allowedExitCodes: [0, 1])
            let id = result?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard result?.exitCode == 0, GitOperations.isObjectID(id) else {
                return .failure(FormProblem(message: "\(revision) is not a commit."))
            }
            source = .commit(id)
        }
        return .success(.addWorktree(path: path, source: source, newBranch: newBranch))
    }

    /// A click on a worktree's sidebar row: its changes when it has any (this tab's own: the WIP row; another's: its
    /// row), else its HEAD commit.
    func selectWorktree(_ info: WorktreeInfo) {
        // A sidebar click shows the graph, in Stacked too (as `selectRef`).
        if info.isCurrent, hasChanges { return selectGraph([.wip], keepsPanel2: false) }
        if !info.isCurrent, dirtyWorktrees.contains(where: { $0.path == info.path }) {
            return selectGraph([.worktree(info.path)], keepsPanel2: false)
        }
        guard let head = info.worktree.head else { return }
        selectGraph([.commit(head)], keepsPanel2: false)
    }

    /// This tab opened as a worktree from another tab (a double-click in the sidebar, "Open in New Tab"): its changes
    /// (the WIP row) when it has any, else its HEAD commit, whatever row it showed before. A tab still reading its
    /// status is already on `.overview`, which ends on the same row.
    func showWorkingState() {
        guard let status = status.value else {
            if selection != .overview { select(.overview) }
            return
        }
        guard let item: GraphItem = status.entries.isEmpty ? status.branch.commit.map({ .commit($0) }) : .wip else {
            return select(.overview)
        }
        if graphSelection != [item] { selectGraph([item]) }
    }

    /// Opens another worktree of the repo in a tab of this window (a double-click on its sidebar row, "Open in New Tab"
    /// in its context menus): the tab switches at once, its detail loading.
    func openWorktree(_ path: String) {
        UITiming.select("worktree \(URL(filePath: path).lastPathComponent)")
        openInTab(URL(filePath: path, directoryHint: .isDirectory))
    }

    // MARK: Submodules

    /// A click on a submodule's sidebar row: selects it at once, its detail on its placeholder in the click's frame until
    /// its status is read.
    func selectSubmodule(_ path: String) {
        if asksBeforeLeavingConflict({ [weak self] in self?.selectSubmodule(path) }) { return }
        // No graph row or branch row stands for it.
        graphSelection = []
        sidebarSelection = nil
        let selection = Selection.submodule(path)
        UITiming.select(timingDetail(selection))
        select(selection)
    }

    /// Opens a checked-out submodule's folder in a tab of this window (a double-click on its sidebar row, "Open in New
    /// Tab"): its own repo, so its tab joins no group of this repo's.
    func openSubmodule(_ path: String) {
        UITiming.select("submodule tab \(path)")
        Task { [weak self] in
            guard let url = await self?.submoduleURL(path) else { return }
            self?.openRepoInTab(url)
        }
    }

    /// A submodule's folder: `path` under this repo's worktree; nil while the repo is not set up.
    func submoduleURL(_ path: String) async -> URL? {
        guard let backend = try? await backend() else { return nil }
        return backend.directories.worktree.appending(path: path, directoryHint: .isDirectory)
    }

    // MARK: File diff

    /// Files over this size (any side of the diff) show a "Load anyway" card instead of their diff.
    nonisolated static let fileSizeLimit = 2 * 1024 * 1024
    /// The context of a "Full file" diff: more lines than any file has, so its one hunk is the whole file.
    private nonisolated static let fullFileContext = 10_000_000

    /// The timing log's detail of the open file (`file src/app.swift`, `conflict long.txt`).
    var fileDetail: String { openFile.map(fileDetail) ?? "" }

    /// Shows `target`'s diff in panel2 instead of the graph now: `fileDiff` is `.loading` when this returns, so the
    /// placeholder shows in the click's frame. The diff loads in a task that a newer select cancels.
    /// A conflicted WIP file opens the conflict editor instead of a diff (`FileTarget.isConflict`). A diff opened from a
    /// tool (a history row) passes it as `returnTool`: a file history keeps panel 1 while the diff shows.
    /// While a file history shows, a commit's file (panel 3) shows that file's history instead, at the same commit; while
    /// a blame shows, a file of panel 3 shows its blame.
    func selectFile(_ target: FileTarget, returnTool: RepoTool? = nil) {
        // While a blame shows, a file of panel 3 shows its blame instead, at the file's revision. A file blame can't
        // read (untracked, deleted, an image, a conflict, a submodule) opens its diff.
        if returnTool == nil, case .blame? = openTool, !target.isConflict, !target.isImage,
           target.file.kind != .untracked, target.file.kind != .deleted, !target.file.isSubmodule
        {
            let blame = RepoTool.blame(path: target.path, rev: Self.blameRev(of: target.source))
            if blame != openTool { selectTool(blame) }
            return
        }
        var returnTool = returnTool
        if returnTool == nil, case .commit = target.source, !target.file.isSubmodule,
           case .fileHistory(_, let rev, let follow)? = historyTool
        {
            returnTool = .fileHistory(path: target.path, rev: rev, follow: follow)
        }
        if isConflictDirty {
            // The open conflict's row again keeps its ticks (a reload would drop them).
            if target == openFile { return }
            if asksBeforeLeavingConflict({ [weak self] in self?.selectFile(target, returnTool: returnTool) }) { return }
        }
        // A pending Suggest All belongs to the conflict Resolve with AI opened, never to another file.
        if !(target.isConflict && target.path == pendingAIBatchPath) { pendingAIBatchPath = nil }
        UITiming.select(fileDetail(target))
        if openHosted != nil {
            openHosted = nil
            pullDetail.close()
            issueDetail.close()
        }
        openTool = nil
        self.returnTool = returnTool
        openFile = target
        fileIgnoresSizeLimit = false
        startFileLoad()
        // Another file's history: panel 1 reads it while panel 2 loads the diff.
        if let returnTool, returnTool != loadedTool { loadTool(returnTool) }
    }

    /// A file history's row (or its newest, when the history loads): selects the commit as a graph click does (panel 3
    /// switches at once) and opens the file's diff at that commit in panel 2; panel 1 keeps the history.
    func openHistoryEntry(_ entry: FileHistoryEntry, of tool: RepoTool) {
        selectGraph([.commit(entry.commit.hash)])
        selectFile(Self.historyTarget(entry), returnTool: tool)
    }

    /// The file of a history row at its commit.
    private static func historyTarget(_ entry: FileHistoryEntry) -> FileTarget {
        let file = FileChange(letter: entry.status ?? "M", path: entry.path, originalPath: entry.oldPath)
        return FileTarget(source: .commit(entry.commit.hash), file: file)
    }

    /// Once the diff of a file history's row is on screen: reads the diffs of the rows just above and below it into
    /// `fileDiffCache`, both at once, so the next click up or down shows whole. Skips cached diffs; never touches
    /// `fileDiff`, drops its errors; the next file select cancels it and its git processes.
    private func prefetchHistoryNeighbours(of target: FileTarget) {
        fileDiffPrefetch?.cancel()
        fileDiffPrefetch = nil
        guard case .commit(let hash) = target.source, case .fileHistory? = returnTool, loadedTool == returnTool,
              case .loaded(.history(let entries)) = toolState,
              let index = entries.firstIndex(where: { $0.commit.hash == hash })
        else { return }
        let ignoresWhitespace = ignoresWhitespace
        // An image's versions are not cached (`FileDiffCache.insert`): reading them ahead would be wasted.
        let targets = [index - 1, index + 1]
            .filter { entries.indices.contains($0) }
            .map { Self.historyTarget(entries[$0]) }
            .filter { !$0.isImage && !fileDiffCache.contains(.init(target: $0, ignoresWhitespace: ignoresWhitespace)) }
        guard !targets.isEmpty else { return }
        let url = url
        fileDiffPrefetch = Task { [weak self] in
            guard let backend = try? await self?.backend() else { return }
            await withTaskGroup(of: (FileTarget, FileDiffDetail?).self) { group in
                for target in targets {
                    group.addTask {
                        let detail = try? await Self.readFileDiff(
                            backend, cwd: url, target: target, ignoresSizeLimit: false,
                            ignoresWhitespace: ignoresWhitespace, loadID: 0)
                        return (target, detail)
                    }
                }
                for await (target, detail) in group {
                    guard let detail, !Task.isCancelled else { continue }
                    self?.fileDiffCache.insert(detail, for: .init(target: target, ignoresWhitespace: ignoresWhitespace))
                }
            }
        }
    }

    /// Opens a WIP file by its path (DEBUG `-HistqSelect file:<path>`) as its row in the WIP panel would: an
    /// untracked file as untracked, a file with unstaged changes as its Unstaged row, else as its Staged row.
    func selectWIPFile(_ path: String) {
        let entry = status.value?.entries.first { $0.path == path }
        let isSubmodule = entry?.isSubmodule ?? false
        let file: FileChange = switch entry {
        case let entry? where entry.kind == .untracked: FileChange(kind: .untracked, path: path)
        case let entry? where entry.kind == .unmerged: FileChange(kind: .conflicted, path: path)
        case let entry? where entry.isUnstaged:
            FileChange(letter: entry.worktree.rawValue, path: path, isSubmodule: isSubmodule)
        case let entry?:
            FileChange(letter: entry.index.rawValue, path: path, originalPath: entry.originalPath,
                       isSubmodule: isSubmodule)
        case nil: FileChange(kind: .modified, path: path)
        }
        selectFile(FileTarget(source: .wip, file: file))
    }

    /// Shows the graph again (Esc, the back button, the conflict editor's close, another graph row or sidebar ref).
    /// The conflict editor's unsaved ticks and edits go with it. An open pull request, issue or tool closes too. A diff
    /// opened from a blame or the reflog (`returnTool`) shows that tool again instead, with its read (read again only if
    /// replaced); one opened from a file history closes it, except in Columns (the history stays in panel 1, its diff
    /// column empty).
    func closeFile() {
        if openHosted != nil {
            openHosted = nil
            pullDetail.close()
            issueDetail.close()
        }
        openTool = nil
        var back = openFile != nil ? returnTool : nil
        // A file history lists its commits in panel 1 beside the diff: closing the diff closes the history too
        // (Columns keeps it: its diff has a column of its own, beside the graph).
        if case .fileHistory? = back, LayoutPreset.current != .columns { back = nil }
        returnTool = nil
        pendingAIBatchPath = nil
        guard openFile != nil else { return }
        fileTask?.cancel()
        fileTask = nil
        fileDiffPrefetch?.cancel()
        fileDiffPrefetch = nil
        openFile = nil
        fileDiff = .idle
        conflict = .idle
        conflictAIUndo = nil
        conflictBusy = nil
        conflictError = nil
        cancelConflictSave()
        conflictLeave = nil
        if let back {
            openTool = back
            if back != loadedTool { loadTool(back) }
        }
    }

    /// Shows the graph whatever panel2 shows (another graph row, ref, pull request or tool, a blame's or the reflog's
    /// close): a diff opened from a tool closes with it instead of going back to it.
    func closePanel2() {
        returnTool = nil
        closeFile()
    }

    /// The conflict editor's close button: shows the graph again, asking first when there are unsaved resolutions.
    func closeConflictEditor() {
        if asksBeforeLeavingConflict({}) { return }
        closeFile()
    }

    /// The open conflict editor has ticks or edits that are not saved.
    var isConflictDirty: Bool {
        openFile?.isConflict == true && conflict.value?.merge?.hasResolutions == true
    }

    /// Leaving a dirty conflict editor (`isConflictDirty`) shows the leave prompt in this call (nothing read) and
    /// returns true: `navigate` waits for its Save or Don't Save. False when nothing is unsaved: go on at once.
    private func asksBeforeLeavingConflict(_ navigate: @escaping @MainActor () -> Void) -> Bool {
        // While a merge editor with unsaved choices is being written (Save, Save Output, Create Conflict Chunks), it
        // can't be left: the click is dropped, so a Save's own way out is never raced by a newer one. A chooser's
        // write (nothing unsaved) never holds a click.
        if conflictBusy != nil, isConflictDirty { return true }
        guard isConflictDirty, let target = openFile else { return false }
        if conflictLeave == nil {
            conflictLeave = ConflictLeave(name: (target.path as NSString).lastPathComponent, navigate: navigate)
        }
        return true
    }

    /// The leave prompt's Save: the editor's Save (with conflicts left, the save prompt follows); the way out runs once
    /// the file is written.
    func leaveConflictSaving() {
        guard let leave = conflictLeave else { return }
        conflictLeave = nil
        pendingLeave = leave
        if saveConflict() == nil, !conflictSavePrompt { pendingLeave = nil }
    }

    /// The leave prompt's Don't Save: drops the ticks and edits and takes the way out.
    func leaveConflictDiscarding() {
        guard let leave = conflictLeave else { return }
        closeFile()
        leave.navigate()
    }

    /// The leave prompt's Cancel (Escape): the editor stays as it was.
    func cancelConflictLeave() {
        conflictLeave = nil
    }

    /// The save prompt's Cancel (Escape): nothing is written, and a way out waiting on the save is dropped.
    func cancelConflictSave() {
        conflictSavePrompt = false
        pendingLeave = nil
    }

    /// Shows a pull request or an issue of the PRs tab in panel2 now (a click on its row): the open file closes and the
    /// item's placeholder shows in the click's frame; a pull request's detail starts loading in the same call.
    func selectHosted(_ item: HostedItem) {
        if asksBeforeLeavingConflict({ [weak self] in self?.selectHosted(item) }) { return }
        UITiming.select(item.timingDetail)
        closePanel2()
        openHosted = item
        hostedToken &+= 1
        switch item {
        case .pullRequest(let number): pullDetail.load(number, github: github)
        case .issue(let number): issueDetail.load(number, github: github)
        }
    }

    /// The timing log's detail of the open tool (`history src/app.swift`).
    var toolDetail: String { openTool?.timingDetail ?? "" }

    /// The path of the blame panel2 shows when it is a file of `source` (panel 3 draws its row as selected).
    func blamePath(in source: FileTarget.Source) -> String? {
        guard case .blame(let path, let rev)? = openTool, rev == Self.blameRev(of: source) else { return nil }
        return path
    }

    /// The revision a file of `source` is blamed at: a commit's, a compare's head; nil (the working tree) for a WIP
    /// file or a compare with the working tree.
    private static func blameRev(of source: FileTarget.Source) -> String? {
        switch source {
        case .wip: nil
        case .commit(let hash): hash
        case .compare(_, let head): head
        }
    }

    /// The worktree's tracked files (`git ls-files`), relative to its folder: the palette's File History… searches them.
    func trackedFiles() async throws -> [String] {
        let backend = try await backend()
        return try await Self.readTrackedFiles(backend, cwd: url)
    }

    @concurrent
    private nonisolated static func readTrackedFiles(_ backend: Backend, cwd: URL) async throws -> [String] {
        let env = try await backend.readEnvironment(cwd: cwd)
        let output = try await backend.runner.run(["ls-files", "-z"], cwd: cwd, env: env).stdout
        return output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Shows a file's history or blame, or the reflog, in panel2 now: the open file, pull request or issue closes and
    /// `toolState` is `.loading` when this returns, so the placeholder shows in the click's frame. Selecting a tool again
    /// (another `follow`) reads it again.
    func selectTool(_ tool: RepoTool) {
        if asksBeforeLeavingConflict({ [weak self] in self?.selectTool(tool) }) { return }
        UITiming.select(tool.timingDetail)
        closePanel2()
        openTool = tool
        loadTool(tool)
    }

    /// Reads `tool` off the main actor into `toolState`; a newer tool select cancels it.
    private func loadTool(_ tool: RepoTool) {
        toolTask?.cancel()
        toolToken &+= 1
        let token = toolToken
        loadedTool = tool
        toolState = .loading
        toolTask = Task { [weak self] in
            guard let self else { return }
            do {
                let backend = try await backend()
                let content = try await Self.readTool(backend, cwd: url, tool: tool)
                try Task.checkCancellation()
                guard token == toolToken else { return }
                toolState = .loaded(content)
                // A file history opens its newest commit, unless a diff already shows (a file of panel 3).
                if case .history(let entries) = content, openTool == tool, openFile == nil, let newest = entries.first {
                    openHistoryEntry(newest, of: tool)
                }
            } catch {
                guard token == toolToken, !Self.isCancellation(error) else { return }
                toolState = .failed(Self.message(for: error))
            }
        }
    }

    /// A file's history or blame, or the reflog, with the read environment (no textconv, no external diff, the repo's
    /// filters blanked: a working tree blame of a filtered file fails instead of running the filter), off the main actor.
    @concurrent
    private nonisolated static func readTool(_ backend: Backend, cwd: URL, tool: RepoTool) async throws -> ToolContent {
        let env = try await backend.readEnvironment(cwd: cwd)
        switch tool {
        case .fileHistory(let path, let rev, let follow):
            return .history(try await FileHistoryReader.read(
                path, revision: rev, follow: follow, runner: backend.runner, cwd: cwd, env: env))
        case .blame(let path, let rev):
            // The diff's gates: the size first (so a huge blob is never read), then git's NUL test. A read that
            // fails leaves the error to blame.
            let target = FileTarget(source: rev.map { .commit($0) } ?? .wip,
                                    file: FileChange(kind: .unchanged, path: path))
            let size = await largestSize(of: target, runner: backend.runner, cwd: cwd, env: env)
            if size > fileSizeLimit { return .tooLarge(size) }
            let data = if let rev {
                try? await DiffReader.file(at: rev, path: path, runner: backend.runner, cwd: cwd, env: env)
            } else {
                (try? worktreeData(path, cwd: cwd)) ?? nil
            }
            if data?.prefix(8000).contains(0) == true { return .binary }
            return .blame(try await BlameReader.read(path, revision: rev, runner: backend.runner, cwd: cwd, env: env))
        case .reflog:
            return .reflog(try await ReflogReader.read(runner: backend.runner, cwd: cwd, env: env))
        }
    }

    /// The subjects of the commits a pull request from `head` into `base` would have, newest first, at most `limit`
    /// (both full refs, the remote-tracking branches GitHub compares); nil when git cannot read them. Read
    /// environment, off the main actor.
    func commitSubjects(base: String, head: String, limit: Int) async -> [String]? {
        guard let backend = try? await backend() else { return nil }
        return try? await Self.readSubjects(backend, cwd: url, range: "\(base)..\(head)", limit: limit)
    }

    @concurrent
    private nonisolated static func readSubjects(_ backend: Backend, cwd: URL, range: String, limit: Int) async throws
        -> [String]
    {
        let env = try await backend.readEnvironment(cwd: cwd)
        let output = try await backend.runner.run(
            ["log", "-z", "--no-show-signature", "--format=%s", "--max-count=\(limit)", "--end-of-options", range, "--"],
            cwd: cwd, env: env)
        return output.text.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
    }

    /// Turns whitespace ignoring on or off for every diff (stored), and reads the open file again with it.
    func setIgnoresWhitespace(_ ignores: Bool) {
        guard ignores != ignoresWhitespace else { return }
        ignoresWhitespace = ignores
        Preferences.defaults.set(ignores, forKey: PrefKey.diffIgnoreWhitespace.rawValue)
        guard let openFile, !openFile.isConflict else { return }
        startFileLoad()
    }

    /// Scrolls the open file's diff to its previous or next change (the controls card's arrows).
    func jumpToChange(_ direction: DiffJump.Direction) {
        diffJump = DiffJump(direction: direction, serial: (diffJump?.serial ?? 0) &+ 1)
    }

    /// Loads the open file past the size limit: its card's "Load anyway".
    func loadFileAnyway() {
        guard openFile != nil else { return }
        fileIgnoresSizeLimit = true
        startFileLoad()
    }

    /// Stages, unstages, discards or reverts `lines` of `file` (the diff a table shows, so the patch matches what the
    /// user selected) through the write path. Discarding and reverting ask first: they change the working tree.
    func apply(_ action: PatchBuilder.Action, lines: Set<DiffLineID>, of file: FileDiff) {
        let patch: Data
        do {
            patch = try PatchBuilder.patch(for: file, selecting: lines, action: action)
        } catch {
            Self.logger.error("no patch for \(file.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
        let count = lines.count { id in
            file.hunks.indices.contains(id.hunk) && file.hunks[id.hunk].lines.indices.contains(id.line)
                && file.hunks[id.hunk].lines[id.line].isChange
        }
        let what = count == 1 ? "1 line" : "\(count) lines"
        let name = (file.path as NSString).lastPathComponent
        switch action {
        case .stage:
            run(.applyPatch(patch, .stage), title: "Stage \(what) of \(name)")
        case .unstage:
            run(.applyPatch(patch, .unstage), title: "Unstage \(what) of \(name)")
        case .discard:
            confirm("Discard \(what) of \(name)?", message: "This cannot be undone.", button: "Discard",
                    write: .applyPatch(patch, .discard), operation: "Discard \(what) of \(name)")
        case .revert:
            confirm("Revert \(what) of \(name)?",
                    message: "The working tree gets these lines back as they were before the commit.",
                    button: "Revert", write: .applyPatch(patch, .revert), operation: "Revert \(what) of \(name)",
                    isDestructive: false)
        }
    }

    private func fileDetail(_ target: FileTarget) -> String {
        target.isConflict ? "conflict \(target.path)" : "file \(target.path)"
    }

    private func startFileLoad() {
        fileToken &+= 1
        cancelConflictSave()
        conflictLeave = nil
        if openFile?.isConflict == true {
            conflict = .loading
            conflictBusy = nil
            conflictError = nil
            return loadConflict()
        }
        // A commit's file read lately (or prefetched) shows whole in the click's frame.
        if let target = openFile, !fileIgnoresSizeLimit,
           var cached = fileDiffCache.value(.init(target: target, ignoresWhitespace: ignoresWhitespace))
        {
            fileTask?.cancel()
            fileTask = nil
            fileLoadCount &+= 1
            cached.loadID = fileLoadCount
            fileDiff = .loaded(cached)
            return prefetchHistoryNeighbours(of: target)
        }
        fileDiffPrefetch?.cancel()
        fileDiffPrefetch = nil
        fileDiff = .loading
        loadFile(quietly: false)
    }

    /// Reads the open file's diff off the main actor. A quiet load (after a status change) keeps the diff on screen
    /// until the new one is in, and goes back to the graph when the file no longer has a change.
    private func loadFile(quietly: Bool) {
        guard let target = openFile else { return }
        // Quiet only over a loaded diff: during the first load the placeholder stays and this load takes its place.
        let quietly = quietly && fileDiff.value != nil
        fileTask?.cancel()
        let token = fileToken
        let ignoresSizeLimit = fileIgnoresSizeLimit
        // Settings or another window may have changed the pref while no diff of this session was on screen.
        let stored = Preferences.defaults.bool(forKey: PrefKey.diffIgnoreWhitespace.rawValue)
        if stored != ignoresWhitespace { ignoresWhitespace = stored }
        let ignoresWhitespace = ignoresWhitespace
        fileLoadCount &+= 1
        let loadID = fileLoadCount
        fileTask = Task { [weak self] in
            guard let self else { return }
            do {
                let backend = try await backend()
                let loaded = try await Self.readFileDiff(
                    backend, cwd: url, target: target, ignoresSizeLimit: ignoresSizeLimit,
                    ignoresWhitespace: ignoresWhitespace, loadID: loadID)
                try Task.checkCancellation()
                guard token == fileToken, openFile == target else { return }
                // Ignoring whitespace, no diff can mean a whitespace-only change: the file stays open.
                if quietly, !ignoresWhitespace, case .unchanged = loaded.content { return closeFile() }
                fileDiff = .loaded(loaded)
                if !ignoresSizeLimit {
                    fileDiffCache.insert(loaded, for: .init(target: target, ignoresWhitespace: ignoresWhitespace))
                }
                if !quietly { prefetchHistoryNeighbours(of: target) }
            } catch {
                guard token == fileToken, openFile == target, !Self.isCancellation(error) else { return }
                // A failed quiet reload keeps the diff on screen; the next status change tries again.
                if !quietly { fileDiff = .failed(Self.message(for: error)) }
            }
        }
    }

    /// The diff of `target` (`readLineDiff`), off the main actor; an image git calls binary, or whose diff has no lines
    /// (a pure rename, a mode change), shows its versions instead.
    @concurrent
    private nonisolated static func readFileDiff(
        _ backend: Backend, cwd: URL, target: FileTarget, ignoresSizeLimit: Bool, ignoresWhitespace: Bool, loadID: Int
    ) async throws -> FileDiffDetail {
        var detail = try await readLineDiff(
            backend, cwd: cwd, target: target, ignoresSizeLimit: ignoresSizeLimit,
            ignoresWhitespace: ignoresWhitespace, loadID: loadID)
        detail.ignoresWhitespace = ignoresWhitespace
        let hasNoLines = switch detail.content {
        case .binary: true
        case .sections(let sections): sections.allSatisfy { $0.rows.isEmpty }
        default: false
        }
        guard hasNoLines, target.isImage else { return detail }
        let env = try await backend.readEnvironment(cwd: cwd)
        guard let images = await imageSides(of: target, runner: backend.runner, cwd: cwd, env: env) else { return detail }
        return FileDiffDetail(loadID: loadID, content: .images(images))
    }

    /// The diff of `target` with the read environment (no textconv, no external diff, no filters), off the main actor:
    /// a WIP file's unstaged and staged changes, or a commit's changes against its first parent. Each comes twice, with
    /// git's context (Diff mode) and with the whole file as context (Full file mode, and the syntax state of every
    /// line). Untracked files are read from disk. `ignoresWhitespace` reads git's diffs with `-w`.
    @concurrent
    private nonisolated static func readLineDiff(
        _ backend: Backend, cwd: URL, target: FileTarget, ignoresSizeLimit: Bool, ignoresWhitespace: Bool, loadID: Int
    ) async throws -> FileDiffDetail {
        if case .commit(let hash) = target.source, !GitOperations.isObjectID(hash) {
            throw CommitReadError.notACommit(hash)
        }
        var steps = UITiming.Steps()
        let env = try await backend.readEnvironment(cwd: cwd)
        steps.lap("env")
        let runner = backend.runner
        let file = target.file
        // A gitlink has no blob to size or diff: its pointer change instead.
        if file.isSubmodule {
            let pointers = try await readSubmodulePointers(backend, cwd: cwd, env: env, target: target)
            return FileDiffDetail(loadID: loadID, content: pointers.isEmpty ? .unchanged : .submodule(pointers))
        }
        let language = LanguageTable.language(forPath: file.path)
        if !ignoresSizeLimit {
            let size = await largestSize(of: target, runner: runner, cwd: cwd, env: env)
            if size > fileSizeLimit { return FileDiffDetail(loadID: loadID, content: .tooLarge(size)) }
        }
        steps.lap("size")
        let paths = [file.originalPath, file.path].compactMap { $0 }
        let full = fullFileContext
        switch target.source {
        case .wip where file.kind == .untracked:
            return FileDiffDetail(loadID: loadID, content: try untrackedContent(file.path, cwd: cwd, language: language))
        case .wip:
            async let unstaged = DiffReader.unstaged(
                runner: runner, cwd: cwd, env: env, paths: [file.path], ignoringWhitespace: ignoresWhitespace)
            async let unstagedFull = DiffReader.unstaged(
                runner: runner, cwd: cwd, env: env, paths: [file.path], context: full,
                ignoringWhitespace: ignoresWhitespace)
            async let staged = DiffReader.staged(
                runner: runner, cwd: cwd, env: env, paths: paths, ignoringWhitespace: ignoresWhitespace)
            async let stagedFull = DiffReader.staged(
                runner: runner, cwd: cwd, env: env, paths: paths, context: full, ignoringWhitespace: ignoresWhitespace)
            let sections = [
                DiffSection(side: .unstaged, diff: pick(try await unstaged, file), full: pick(try await unstagedFull, file),
                            language: language),
                DiffSection(side: .staged, diff: pick(try await staged, file), full: pick(try await stagedFull, file),
                            language: language),
            ]
            return FileDiffDetail(loadID: loadID, sections: sections.compactMap { $0 })
        case .commit(let hash) where file.kind == .unchanged:
            // A file the commit did not change ("View all files"): its blob at that commit, every line as context.
            let data = try await runner.run(["cat-file", "blob", "\(hash):\(file.path)"], cwd: cwd, env: env).stdout
            if data.prefix(8000).contains(0) { return FileDiffDetail(loadID: loadID, content: .binary) }
            return FileDiffDetail(loadID: loadID, content: .sections([DiffSection(unchanged: data, language: language)]))
        case .commit(let hash):
            // A stash's untracked file is only in its untracked-files commit (a root commit: every line added).
            let revision = file.kind == .untracked ? "\(hash)^3" : hash
            async let diff = DiffReader.commit(
                revision, runner: runner, cwd: cwd, env: env, paths: paths, ignoringWhitespace: ignoresWhitespace)
            async let diffFull = DiffReader.commit(
                revision, runner: runner, cwd: cwd, env: env, paths: paths, context: full,
                ignoringWhitespace: ignoresWhitespace)
            let picked = (pick(try await diff, file), pick(try await diffFull, file))
            steps.lap("diff")
            let section = DiffSection(side: .commit, diff: picked.0, full: picked.1, language: language)
            steps.lap("rows")
            UITiming.fileLoad("\(file.path) \(steps.description)")
            return FileDiffDetail(loadID: loadID, sections: [section].compactMap { $0 })
        case .compare(let base, let head):
            // Read-only (no hunk buttons).
            async let diff = DiffReader.compare(
                base: base, head: head, runner: runner, cwd: cwd, env: env, paths: paths,
                ignoringWhitespace: ignoresWhitespace)
            async let diffFull = DiffReader.compare(
                base: base, head: head, runner: runner, cwd: cwd, env: env, paths: paths, context: full,
                ignoringWhitespace: ignoresWhitespace)
            let section = DiffSection(side: .commit, diff: pick(try await diff, file), full: pick(try await diffFull, file),
                                      language: language)
            return FileDiffDetail(loadID: loadID, sections: [section].compactMap { $0 })
        }
    }

    /// A submodule row's pointer change, one per side that has one: a commit's or a stash's against its first parent
    /// (`diff-tree --raw`, as `DiffReader.commit` picks it); a WIP row's unstaged change (the index's gitlink → the
    /// checkout's HEAD, with its uncommitted files, from `SubmoduleReader.list`) and staged one (HEAD's gitlink → the
    /// index's, `diff-index --cached --raw`). The commits between are read in the submodule's checkout
    /// (`SubmoduleReader.change`); none without one. Off the main actor.
    private nonisolated static func readSubmodulePointers(
        _ backend: Backend, cwd: URL, env: [String: String], target: FileTarget
    ) async throws -> [SubmodulePointer] {
        let path = target.path
        let runner = backend.runner
        var sides: [(side: DiffSide, from: String?, to: String?, uncommitted: Int)] = []
        switch target.source {
        case .commit(let hash):
            let output = try await runner.run(
                ["--literal-pathspecs", "diff-tree", "-r", "-z", "--raw", "--no-abbrev", "--root",
                 "--diff-merges=first-parent", "--no-commit-id", "--end-of-options", hash, "--", path],
                cwd: cwd, env: env)
            if let link = RawDiffRecord.gitlinks(in: output.stdout) { sides.append((.commit, link.from, link.to, 0)) }
        case .wip:
            // An unborn HEAD (exit 128) has nothing staged against it to read.
            async let staged = runner.run(
                ["--literal-pathspecs", "diff-index", "--cached", "-z", "--raw", "--no-abbrev",
                 "--ignore-submodules=dirty", "--end-of-options", "HEAD", "--", path],
                cwd: cwd, env: env, allowedExitCodes: [0, 128])
            let list = try await SubmoduleReader.list(runner: runner, cwd: cwd, base: backend.base)
            // Uncommitted files alone are no pointer change (status leaves such a submodule out).
            if let submodule = list.first(where: { $0.path == path }), case .checkedOut(let head, _) = submodule.state,
               head != submodule.recordedCommit
            {
                sides.append((.unstaged, submodule.recordedCommit, head, submodule.changeCount))
            }
            if let link = RawDiffRecord.gitlinks(in: try await staged.stdout) {
                sides.append((.staged, link.from, link.to, 0))
            }
        case .compare:
            // A compare's file list never marks a submodule.
            break
        }
        let folder = cwd.appending(path: path, directoryHint: .isDirectory)
        let isCheckedOut = FileManager.default.fileExists(atPath: folder.appending(path: ".git").path)
        var pointers: [SubmodulePointer] = []
        for side in sides {
            var change: SubmoduleChange?
            if isCheckedOut, let to = side.to, side.from != to {
                change = try await SubmoduleReader.change(
                    runner: runner, in: folder, base: backend.base, from: side.from, to: to)
            }
            pointers.append(SubmodulePointer(
                side: side.side, from: side.from, to: side.to, isCheckedOut: isCheckedOut, change: change,
                uncommitted: side.uncommitted))
        }
        return pointers
    }

    /// The diff of `file` among those git printed for its paths (a rename's old path is in the pathspec too).
    private nonisolated static func pick(_ diffs: [FileDiff], _ file: FileChange) -> FileDiff? {
        diffs.first { $0.path == file.path || $0.oldPath == file.path } ?? diffs.first
    }

    /// The largest size of the file on any side its diff reads: for a WIP file the working tree (the entry itself,
    /// never a symlink's target), the index and HEAD; for a commit, the commit and its first parent. A side that does
    /// not exist counts as 0.
    private nonisolated static func largestSize(
        of target: FileTarget, runner: GitRunner, cwd: URL, env: [String: String]
    ) async -> Int {
        let file = target.file
        let oldPath = file.originalPath ?? file.path
        var size = 0
        let objects: [String]
        switch target.source {
        case .wip:
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: cwd.appending(path: file.path, directoryHint: .notDirectory).path)
            size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            objects = [":0:\(file.path)", "HEAD:\(oldPath)"]
        case .commit(let hash):
            objects = switch file.kind {
            case .untracked: ["\(hash)^3:\(file.path)"]
            case .unchanged: ["\(hash):\(file.path)"]
            default: ["\(hash):\(file.path)", "\(hash)^:\(oldPath)"]
            }
        case .compare(let base, let head):
            if let head {
                objects = ["\(head):\(file.path)", "\(base):\(oldPath)"]
            } else {
                let attributes = try? FileManager.default.attributesOfItem(
                    atPath: cwd.appending(path: file.path, directoryHint: .notDirectory).path)
                size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
                objects = ["\(base):\(oldPath)"]
            }
        }
        // One cat-file for every side, names on stdin. A line break in a name would split it (git also drops a CR at
        // the end of a line), so such a name takes one call per object below.
        if !objects.contains(where: { $0.utf8.contains { $0 == 0x0A || $0 == 0x0D } }) {
            let input = Data(objects.map { $0 + "\n" }.joined().utf8)
            // One line per object, in order; "<name> missing" (no such object on that side) counts as 0.
            if let result = try? await runner.run(
                ["cat-file", "--batch-check=%(objectsize)"], cwd: cwd, env: env, stdin: input) {
                for line in result.text.split(separator: "\n") { size = max(size, Int(line) ?? 0) }
            }
            return size
        }
        for object in objects {
            // Exit 128: no such object on that side (an added file, a root commit, an unborn branch).
            guard let result = try? await runner.run(
                ["cat-file", "-s", object], cwd: cwd, env: env, allowedExitCodes: [0, 128]),
                result.exitCode == 0,
                let bytes = Int(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
            else { continue }
            size = max(size, bytes)
        }
        return size
    }

    /// The versions of an image on each side with changes, decoded: a WIP file's unstaged side (index → working tree)
    /// and staged side (HEAD → index), each when its two versions differ; a commit's change against its first parent
    /// (a stash's untracked file has no before); an untracked file, or a file the commit did not change, alone. A side
    /// without the file (added, deleted, a root commit) has no image there. Nil when nothing decodes.
    private nonisolated static func imageSides(
        of target: FileTarget, runner: GitRunner, cwd: URL, env: [String: String]
    ) async -> [ImageDiffSide]? {
        let file = target.file
        let oldPath = file.originalPath ?? file.path
        // A missing object (exit 128) or a missing working-tree file reads as no version.
        func blob(_ revision: String, _ path: String) async -> Data? {
            try? await DiffReader.file(at: revision, path: path, runner: runner, cwd: cwd, env: env)
        }
        func worktree() -> Data? { (try? worktreeData(file.path, cwd: cwd)) ?? nil }
        var versions: [(side: DiffSide, before: Data?, after: Data?)] = []
        switch target.source {
        case .wip where file.kind == .untracked:
            versions = [(.untracked, nil, worktree())]
        case .wip:
            let head = await blob("HEAD", oldPath)
            let index = await blob("", file.path)
            let work = worktree()
            if index != work { versions.append((.unstaged, index, work)) }
            if head != index { versions.append((.staged, head, index)) }
        case .commit(let hash) where file.kind == .unchanged:
            versions = [(.file, nil, await blob(hash, file.path))]
        case .commit(let hash) where file.kind == .untracked:
            versions = [(.commit, nil, await blob("\(hash)^3", file.path))]
        case .commit(let hash):
            let before = file.kind == .added ? nil : await blob("\(hash)^", oldPath)
            let after = file.kind == .deleted ? nil : await blob(hash, file.path)
            versions = [(.commit, before, after)]
        case .compare(let base, let head):
            let before = file.kind == .added ? nil : await blob(base, oldPath)
            let after: Data? = if file.kind == .deleted { nil } else if let head { await blob(head, file.path) } else {
                worktree()
            }
            versions = [(.commit, before, after)]
        }
        let sides = versions
            .map { ImageDiffSide(side: $0.side, before: DiffImage(data: $0.before), after: DiffImage(data: $0.after)) }
            .filter { $0.before != nil || $0.after != nil }
        return sides.isEmpty ? nil : sides
    }

    /// A working-tree file's bytes, read without following a symlink and without blocking, and only from a regular
    /// file, so a planted link or FIFO cannot point the read at a device; a symlink gives its target, which is what git
    /// would stage. Nil for anything else (a FIFO, a directory).
    private nonisolated static func worktreeData(_ path: String, cwd: URL) throws -> Data? {
        let fullPath = cwd.appending(path: path, directoryHint: .notDirectory).path
        let fd = open(fullPath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd >= 0 {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            return try handle.readToEnd() ?? Data()
        } else if errno == ELOOP {
            return Data(try FileManager.default.destinationOfSymbolicLink(atPath: fullPath).utf8)
        } else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: fullPath])
        }
    }

    /// An untracked file has no git diff: its lines read from disk (`worktreeData`), all added (display only).
    private nonisolated static func untrackedContent(_ path: String, cwd: URL, language: Language?) throws
        -> FileDiffDetail.Content
    {
        guard let data = try worktreeData(path, cwd: cwd) else { return .unchanged }
        // git's own test: a NUL in the first 8000 bytes makes a file binary.
        if data.prefix(8000).contains(0) { return .binary }
        return .sections([DiffSection(untracked: data, language: language)])
    }

    // MARK: Conflict editor

    /// Opens the conflict editor on a conflicted WIP path (DEBUG `-HistqSelect conflict:<path>`) as a click on its row
    /// in the WIP panel does: through `selectFile`, so panel2 shows its placeholder in the same call.
    func selectConflict(_ path: String) {
        selectFile(FileTarget(source: .wip, file: FileChange(kind: .conflicted, path: path)))
    }

    /// Reads the open conflicted file's stages off the main actor (read environment) and builds its 3-way merge.
    private func loadConflict() {
        guard let target = openFile else { return }
        fileTask?.cancel()
        conflictAIUndo = nil
        let token = fileToken
        fileLoadCount &+= 1
        let loadID = fileLoadCount
        fileTask = Task { [weak self] in
            guard let self else { return }
            do {
                let backend = try await backend()
                let loaded = try await Self.readConflict(backend, cwd: url, path: target.path, loadID: loadID)
                try Task.checkCancellation()
                guard token == fileToken, openFile == target else { return }
                conflict = .loaded(loaded)
                // Resolve with AI opened this file: Suggest All starts on its first load only (a reload after a
                // write finds the path dropped). Without a text conflict (only modify/delete or binary ones), it
                // says so rather than open without AI.
                if pendingAIBatchPath == target.path {
                    pendingAIBatchPath = nil
                    if aiResolutionTargets().isEmpty {
                        postToast(.warning("Resolve with AI", detail: "No text conflicts for AI to suggest — resolve "
                            + "them in the conflict editor."))
                    } else {
                        startAIBatch()
                    }
                }
                #if DEBUG
                runLaunchResolve()
                #endif
            } catch {
                guard token == fileToken, openFile == target, !Self.isCancellation(error) else { return }
                pendingAIBatchPath = nil
                conflict = .failed(Self.message(for: error))
            }
        }
    }

    /// The stages of `path` (`ConflictSource.load`), the pane labels of the operation in progress and the short hashes
    /// of the commits A and B come from: HEAD, and the merged, replayed, picked or reverted commit. The merge itself
    /// is built here too, off the main actor.
    @concurrent
    private nonisolated static func readConflict(_ backend: Backend, cwd: URL, path: String, loadID: Int) async throws
        -> ConflictDocument
    {
        let env = try await backend.readEnvironment(cwd: cwd)
        let runner = backend.runner
        let state = try await RepoState.read(runner: runner, cwd: cwd, env: env)
        let incoming: String? = switch state.operation {
        case .merge: "MERGE_HEAD"
        case .rebase: "REBASE_HEAD"
        case .cherryPick: "CHERRY_PICK_HEAD"
        case .revert: "REVERT_HEAD"
        case .am, .none: nil
        }
        async let source = ConflictSource.load(path: path, labels: state.labels, runner: runner, cwd: cwd, env: env)
        async let aCommit = shortHash("HEAD", runner: runner, cwd: cwd, env: env)
        async let bCommit = incoming == nil ? nil : shortHash(incoming ?? "", runner: runner, cwd: cwd, env: env)
        var document = ConflictDocument(loadID: loadID, source: try await source, aCommit: try await aCommit,
                                        bCommit: try await bCommit)
        // Suggest Resolution's `.aiignore` check; one that can't be read counts as excluding the file (fail closed).
        do {
            document.isAIIgnored = try AIIgnore.load(worktree: backend.directories.worktree)?.matches(path) == true
        } catch {
            document.isAIIgnored = true
            document.aiIgnoreUnreadable = true
        }
        return document
    }

    /// The short hash of the commit a fixed pseudo-ref (`HEAD`, `MERGE_HEAD`) names; nil when it does not exist.
    private nonisolated static func shortHash(
        _ name: String, runner: GitRunner, cwd: URL, env: [String: String]
    ) async throws -> String? {
        let result = try await runner.run(
            ["rev-parse", "-q", "--short", "--verify", "\(name)^{commit}"], cwd: cwd, env: env, allowedExitCodes: [0, 1])
        let hash = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.exitCode == 0 && !hash.isEmpty ? hash : nil
    }

    /// Changes the loaded conflict's merge and tells the panes (`revision`). Drops Undo AI's snapshot (a tick, an edit,
    /// Reset, Undo AI itself); the AI Apply takes its own after the change.
    private func updateConflict(_ change: (inout ConflictDocument) -> Void) {
        guard case .loaded(var document) = conflict, document.merge != nil else { return }
        conflictAIUndo = nil
        change(&document)
        document.revision &+= 1
        conflict = .loaded(document)
    }

    /// A line checkbox of pane A or B: ticks or unticks those lines (indices in that pane).
    func setConflictTicked(_ ticked: Bool, side: ThreeWayMerge.Side, lines: [Int]) {
        updateConflict { $0.merge?.setTicked(ticked, side: side, lines: lines) }
    }

    /// A hunk checkbox: every line of one side of conflict `k` (0-based); "conflict k of N" follows it.
    func setConflictTicked(_ ticked: Bool, side: ThreeWayMerge.Side, conflict k: Int) {
        updateConflict { document in
            guard let merge = document.merge, merge.conflictRegions.indices.contains(k) else { return }
            document.merge?.setTicked(ticked, side: side, conflict: k)
            document.current = k
        }
    }

    /// A pane header's checkbox: every conflict line of one side.
    func setConflictTickedAll(_ ticked: Bool, side: ThreeWayMerge.Side) {
        updateConflict { $0.merge?.setTickedAll(ticked, side: side) }
    }

    /// The user typed in Output: `text` becomes the manual edit of the first region of `regions`, and the other regions
    /// the edit swallowed become empty. Only regions the edit touched are changed. Returns the new merge, so Output can
    /// match it at once (the merge adds back a line break the edit removed between two regions).
    func editConflictOutput(_ text: String, regions: ClosedRange<Int>) -> ThreeWayMerge? {
        updateConflict { document in
            guard let merge = document.merge, merge.regions.indices.contains(regions.upperBound) else { return }
            document.merge?.setManualText(text, region: regions.lowerBound)
            for index in regions.dropFirst() { document.merge?.setManualText("", region: index) }
        }
        return conflict.value?.merge
    }

    /// "conflict k of N": the conflict the ▲ ▼ buttons moved to (0-based).
    func showConflict(_ k: Int) {
        guard case .loaded(var document) = conflict, let merge = document.merge,
              merge.conflictRegions.indices.contains(k)
        else { return }
        document.current = k
        conflict = .loaded(document)
    }

    /// Save: with every conflict resolved, writes Output's bytes to the file, then `git add`. With conflicts left
    /// unresolved (and at least one tick or edit), asks how to write them first (`conflictSavePrompt`). Returns the
    /// write's task when it started one.
    @discardableResult
    func saveConflict() -> Task<Bool, Never>? {
        guard conflictBusy == nil, let merge = conflict.value?.merge,
              merge.unresolvedCount == 0 || merge.hasResolutions
        else { return nil }
        guard merge.unresolvedCount == 0 else {
            conflictSavePrompt = true
            return nil
        }
        return resolveConflict(keeping: merge.outputData, title: "Saving…")
    }

    /// The save prompt's Save Output: writes Output as shown (unresolved conflicts keep their base lines) and marks
    /// the file resolved (`git add`).
    @discardableResult
    func saveConflictOutput() -> Task<Bool, Never>? {
        conflictSavePrompt = false
        guard let merge = conflict.value?.merge else { return nil }
        return resolveConflict(keeping: merge.outputData, title: "Saving…")
    }

    /// The save prompt's Create Conflict Chunks: writes Output with git's conflict markers for every unresolved conflict
    /// (A as `HEAD`, as git labels it, B by its pane's name), without `git add`. The file stays conflicted and the
    /// editor loads it again from its stages.
    @discardableResult
    func saveConflictChunks() -> Task<Bool, Never>? {
        conflictSavePrompt = false
        guard let document = conflict.value, let merge = document.merge else { return nil }
        let labels = ConflictLabels(a: "HEAD", b: document.source.labels.b)
        let content = merge.outputDataWithConflictMarkers(labels: labels)
        return writeConflict(title: "Saving…", reload: true) { .writeConflictChunks(path: $0, content: content) }
    }

    /// Output's Reset: drops every tick and manual edit (Output as freshly loaded), back to conflict 1. The file on
    /// disk is untouched.
    func resetConflict() {
        guard conflictBusy == nil else { return }
        updateConflict { document in
            document.merge?.reset()
            document.current = 0
        }
    }

    /// Resolves the open conflicted file with `content` (Output, the version a chooser keeps), or deletes it when nil,
    /// through the write path; the status refresh after it closes the editor once git no longer lists the path.
    @discardableResult
    func resolveConflict(keeping content: Data?, title: String) -> Task<Bool, Never>? {
        writeConflict(title: title) { .resolveConflict(path: $0, content: content) }
    }

    /// Runs a conflict editor write (`write` of the open path) with `title` as its busy label; a failure shows in the
    /// header card. `reload`: the editor loads the file's stages again after a successful write. The task's value says
    /// whether the write succeeded; nil when nothing started (no conflict open, or a write in flight).
    private func writeConflict(title: String, reload: Bool = false, _ write: (String) -> Write) -> Task<Bool, Never>? {
        // The leave prompt's way out, if this write is its Save: taken now, applied only if the write succeeds.
        guard let target = openFile, target.isConflict, conflictBusy == nil else { return nil }
        let leave = pendingLeave
        pendingLeave = nil
        conflictAIUndo = nil
        conflictBusy = title
        conflictError = nil
        let token = fileToken
        let write = write(target.path)
        return Task { [weak self] in
            guard let self else { return false }
            do {
                try await perform(write)
            } catch {
                guard token == fileToken else { return false }
                conflictError = Self.message(for: error)
                conflictBusy = nil
                return false
            }
            guard token == fileToken else { return true }
            conflictBusy = nil
            if let leave {
                closeFile()
                leave.navigate()
                return true
            }
            if reload, openFile == target {
                conflict = .loading
                loadConflict()
            }
            return true
        }
    }

    /// "Open in external merge tool": `git mergetool --no-prompt [--tool=<PrefKey.mergeTool>] -- <path>` with the write
    /// environment, as an operation (the action bar shows it running, its failure shows in a toast). A tool
    /// name that is not a plain name is refused rather than passed to git.
    func openMergeTool() {
        guard let target = openFile, target.isConflict else { return }
        let setting = (Preferences.defaults.string(forKey: PrefKey.mergeTool.rawValue) ?? "")
            .trimmingCharacters(in: .whitespaces)
        let isPlainName = (setting.first.map { $0.isLetter || $0.isNumber } ?? true)
            && setting.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
        guard isPlainName else {
            conflictError = "The merge tool setting \"\(setting)\" is not a tool name."
            return
        }
        conflictError = nil
        let name = (target.path as NSString).lastPathComponent
        run(.mergeTool(path: target.path, tool: setting.isEmpty ? nil : setting), title: "Merge tool for \(name)")
    }

    // MARK: AI (task 12.3)

    /// An AI button's click: the result card opens in this call (its skeleton shows in the click's frame); the job's
    /// content is read and its prompt built off the main actor, then the answer streams in. Only a click gets here.
    /// `onApply`: a form's AI button (the card shows over the form) gets the answer at Apply instead of the job's own.
    func startAI(_ job: AIJob, onApply: (@MainActor (String) -> Void)? = nil) {
        aiRun?.cancel()
        let setup = AISetup.shared
        let run = AIRun(job: job, provider: setup.provider, model: setup.model(for: setup.provider), onApply: onApply)
        UITiming.select("ai \(job.logName)")
        aiRun = run
        run.start(prompt: aiPrompt(for: job))
    }

    /// What `AIRun.start` runs for `job` (the result card's, or a Suggest All region's): Settings › AI's languages and
    /// the job's instructions as they are now, then `aiPrompt` off the main actor. Holds the session weakly.
    func aiPrompt(for job: AIJob) -> @Sendable () async throws -> AIPrompt {
        let url = url
        let languages = Self.aiLanguages()
        let instructionsKey: PrefKey = switch job {
        case .commitMessage, .improveMessage: .aiCommitInstructions
        case .explainCommit, .explainWorkingChanges: .aiExplainInstructions
        case .resolution: .aiConflictInstructions
        case .pullRequest: .aiPullRequestInstructions
        }
        let instructions = Preferences.defaults.string(forKey: instructionsKey.rawValue) ?? ""
        let branch = currentBranch
        return { [weak self] in
            guard let backend = try await self?.backend() else { throw CancellationError() }
            return try await Self.aiPrompt(job, backend: backend, cwd: url, languages: languages,
                                           instructions: instructions, branch: branch)
        }
    }

    /// Cancel, Escape, Close, Apply, a tab or page change, closing the tab or window: stops the stream (if any) and
    /// closes the card, and the Suggest All card with its batch.
    func closeAI() {
        aiRun?.cancel()
        aiRun = nil
        closeAIBatch()
    }

    /// Suggest All's click: the card opens in this call; its regions (`aiResolutionTargets`) are asked one after
    /// another. Nothing happens when no conflict is left unresolved.
    func startAIBatch() {
        let targets = aiResolutionTargets()
        guard !targets.isEmpty else { return }
        closeAI()
        let setup = AISetup.shared
        let batch = AIBatch(targets: targets, provider: setup.provider, model: setup.model(for: setup.provider))
        UITiming.select("ai resolve-all")
        aiBatch = batch
        batch.start(session: self)
    }

    /// Suggest All's Cancel, Close or Apply (and `closeAI`): stops the region being asked and closes the card.
    func closeAIBatch() {
        aiBatch?.cancel()
        aiBatch = nil
    }

    /// The languages of Settings › AI: explanations, then commit messages (English for a missing or unknown value).
    private static func aiLanguages() -> (response: AIResponseLanguage, commit: AIResponseLanguage) {
        func language(_ key: PrefKey) -> AIResponseLanguage {
            Preferences.defaults.string(forKey: key.rawValue).flatMap(AIResponseLanguage.init(rawValue:)) ?? .english
        }
        return (language(.aiResponseLanguage), language(.aiCommitLanguage))
    }

    /// The job's prompt: the staged (or, when amending, the whole amended commit's), WIP or commit diff read with the
    /// read environment (never a profile), without what the worktree's `.aiignore` and the skip list leave out
    /// (`AIPrompts.filtered`), cut to the prompt's budget. `instructions` are the job's own (Settings › AI); `branch`
    /// (taken at the click) and the last commit subjects go only into a commit message's prompt. A resolution's text
    /// was taken at the click; it is never translated. Its intent (`resolutionIntent`) is read here, after the
    /// `.aiignore` check. A pull request's: the full messages of its last 50 commits (`noCommits` without one), the
    /// branch diff (`PatchSource.branch`) and the template at `templateRef`, in the commit messages' language.
    @concurrent
    private nonisolated static func aiPrompt(
        _ job: AIJob, backend: Backend, cwd: URL,
        languages: (response: AIResponseLanguage, commit: AIResponseLanguage), instructions: String, branch: String?
    ) async throws -> AIPrompt {
        let worktree = backend.directories.worktree
        switch job {
        case .commitMessage(let summaryOnly, let amend, let currentMessage):
            let env = try await backend.readEnvironment(cwd: cwd)
            let diff = try await DiffReader.patchText(
                amend ? .stagedAgainstParent : .staged, runner: backend.runner, cwd: cwd, env: env)
            guard amend || !diff.isEmpty else { throw AIJobError.nothingStaged }
            let filtered = try aiFiltered(diff, worktree: worktree)
            let subjects = (try? await readSubjects(backend, cwd: cwd, range: amend ? "HEAD^" : "HEAD", limit: 5)) ?? []
            let current = currentMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            return AIPrompts.commitMessage(stagedDiff: filtered, language: languages.commit, summaryOnly: summaryOnly,
                                           instructions: instructions, branch: branch, recentSubjects: subjects,
                                           currentMessage: amend && !current.isEmpty ? currentMessage : nil)
        case .explainCommit(let hash, let message):
            guard GitOperations.isObjectID(hash) else { throw AIJobError.noChanges }
            let env = try await backend.readEnvironment(cwd: cwd)
            let diff = try await DiffReader.patchText(.commit(hash), runner: backend.runner, cwd: cwd, env: env)
            return AIPrompts.explainCommit(
                message: message, diff: try aiFiltered(diff, worktree: worktree),
                language: languages.response, instructions: instructions)
        case .improveMessage(let hash, let message):
            // Never summary only: Apply replaces the whole message, so the body must stay.
            guard GitOperations.isObjectID(hash) else { throw AIJobError.noChanges }
            let env = try await backend.readEnvironment(cwd: cwd)
            let diff = try await DiffReader.patchText(.commit(hash), runner: backend.runner, cwd: cwd, env: env)
            return AIPrompts.commitMessage(
                stagedDiff: try aiFiltered(diff, worktree: worktree), language: languages.commit, summaryOnly: false,
                instructions: instructions, currentMessage: message)
        case .explainWorkingChanges:
            // Staged then unstaged: `git diff HEAD` would fail on an unborn branch.
            let env = try await backend.readEnvironment(cwd: cwd)
            async let staged = DiffReader.patchText(.staged, runner: backend.runner, cwd: cwd, env: env)
            async let unstaged = DiffReader.patchText(.unstaged, runner: backend.runner, cwd: cwd, env: env)
            let diff = try await staged + unstaged
            guard !diff.isEmpty else { throw AIJobError.noChanges }
            return AIPrompts.explainWorkingChanges(
                diff: try aiFiltered(diff, worktree: worktree), language: languages.response,
                instructions: instructions)
        case .resolution(let target):
            if try aiIgnore(worktree: worktree)?.matches(target.path) == true { throw AIJobError.fileIgnored }
            return AIPrompts.suggestResolution(path: target.path, base: target.base, a: target.a, b: target.b,
                                               intent: await resolutionIntent(target, backend: backend, cwd: cwd),
                                               instructions: instructions)
        case .pullRequest(let base, let head, let templateRef):
            let env = try await backend.readEnvironment(cwd: cwd)
            let log = try await backend.runner.run(
                ["log", "-z", "--no-show-signature", "--format=%B", "--max-count=50", "--end-of-options",
                 "\(base)..\(head)", "--"], cwd: cwd, env: env)
            let messages = log.text.split(separator: "\0").map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !messages.isEmpty else { throw AIJobError.noCommits }
            let diff = try await DiffReader.patchText(
                .branch(base: base, head: head), runner: backend.runner, cwd: cwd, env: env)
            let filtered = try aiFiltered(diff, worktree: worktree)
            let template = await PullRequestTemplate.read(
                ref: templateRef, runner: backend.runner, cwd: cwd, env: env, ignore: try aiIgnore(worktree: worktree))
            return AIPrompts.pullRequest(commitMessages: messages, diff: filtered, template: template,
                                         language: languages.commit, instructions: instructions)
        }
    }

    /// What the operation of a resolution is about (see `AIPrompts.suggestResolution`): the full message of the commit
    /// being replayed or cherry-picked (the pseudo-ref the B pane reads), or the branches being merged (the pane
    /// labels). nil for a revert, no operation, or when git can't read the message.
    private nonisolated static func resolutionIntent(
        _ target: AIResolutionTarget, backend: Backend, cwd: URL
    ) async -> (label: String, text: String)? {
        let (label, ref): (String, String)
        switch target.operation {
        case .merge:
            return ("intent: the branches being merged", "merge \(target.labels.b) into \(target.labels.a)")
        case .rebase:
            (label, ref) = ("intent of side B: message of the commit being replayed", "REBASE_HEAD")
        case .cherryPick:
            (label, ref) = ("intent of side B: message of the commit being cherry-picked", "CHERRY_PICK_HEAD")
        case .revert, .am, .none:
            return nil
        }
        guard let env = try? await backend.readEnvironment(cwd: cwd),
              let output = try? await backend.runner.run(
                ["log", "-1", "--no-show-signature", "--format=%B", "--end-of-options", ref, "--"], cwd: cwd, env: env)
        else { return nil }
        return (label, output.text)
    }

    /// `diff` through `AIPrompts.filtered` with the worktree's `.aiignore`; throws `allIgnored` when `.aiignore` left
    /// out every file (only the closing note would be sent). An empty diff is returned as it is.
    private nonisolated static func aiFiltered(_ diff: String, worktree: URL) throws -> String {
        guard let kept = AIPrompts.filteredUnlessAllIgnored(diff, ignore: try aiIgnore(worktree: worktree))
        else { throw AIJobError.allIgnored }
        return kept
    }

    /// The worktree's `.aiignore` (`AIIgnore.load`): nil when it is missing; one that can't be read safely throws
    /// `aiIgnoreUnreadable`, so nothing is sent unfiltered. Its text is never sent.
    private nonisolated static func aiIgnore(worktree: URL) throws -> AIIgnore? {
        do { return try AIIgnore.load(worktree: worktree) } catch { throw AIJobError.aiIgnoreUnreadable }
    }

    /// Apply of a commit message: its first line is the summary, the rest (after the blank line) the description.
    /// With `summaryOnly`, only the summary is filled and the description the user typed stays.
    func applyAICommitMessage(_ message: String, summaryOnly: Bool) {
        var lines = message.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        }
        let summary = lines.isEmpty ? "" : lines.removeFirst().trimmingCharacters(in: .whitespaces)
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        commitDraft.summary = summary
        guard !summaryOnly else { return }
        commitDraft.description = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The open conflict's current region ("conflict k of N") for Suggest Resolution; nil when there is none (not a
    /// text conflict, not UTF-8, so Output is read-only, or not loaded).
    func aiResolutionTarget() -> AIResolutionTarget? {
        guard let document = conflict.value, let merge = document.merge, merge.conflictCount > 0 else { return nil }
        return aiResolutionTarget(conflict: min(document.current, merge.conflictCount - 1))
    }

    /// Suggest All's regions: every unresolved conflict of the open file, in order (none when Output is read-only).
    func aiResolutionTargets() -> [AIResolutionTarget] {
        guard let merge = conflict.value?.merge else { return [] }
        return merge.conflictRegions.indices.filter { merge.regions[merge.conflictRegions[$0]].isUnresolved }
            .compactMap { aiResolutionTarget(conflict: $0) }
    }

    /// Conflict `k` (0-based) of the open file as an AI target; nil when it is not a loaded UTF-8 text conflict.
    private func aiResolutionTarget(conflict k: Int) -> AIResolutionTarget? {
        guard case .loaded(let document) = conflict, document.isUTF8, let merge = document.merge,
              let path = openFile?.path, merge.conflictRegions.indices.contains(k)
        else { return nil }
        let index = merge.conflictRegions[k]
        let region = merge.regions[index]
        let hasBase = if case .text(let base, _, _) = document.source.content { base != nil } else { false }
        return AIResolutionTarget(
            path: path, loadID: document.loadID, conflict: k, region: index,
            base: hasBase ? merge.baseLines[region.base].joined() : nil,
            a: merge.aLines[region.a].joined(), b: merge.bLines[region.b].joined(),
            lineBreak: merge.lineBreak, needsFinalBreak: merge.needsFinalBreak(region: index),
            operation: repoState?.operation ?? .none, labels: repoState?.labels ?? document.source.labels)
    }

    /// Apply of suggested resolutions (one region from the result card, the chosen ones from Suggest All): replaces
    /// only each target region's Output, as a manual edit, with the file's line breaks, in one step that Undo AI takes
    /// back (`conflictAIUndo`). Never saves or stages (Save does). Writes nothing and returns why, when the editor no
    /// longer shows that load of that file or one of those conflicts.
    func applyAIResolutions(_ items: [(AIResolutionTarget, String)]) -> String? {
        guard let first = items.first else { return nil }
        guard case .loaded(let document) = conflict, let merge = document.merge, let path = openFile?.path,
              items.allSatisfy({ target, _ in
                  document.loadID == target.loadID && path == target.path
                      && merge.conflictRegions.indices.contains(target.conflict)
                      && merge.conflictRegions[target.conflict] == target.region
              })
        else { return "The conflict editor changed since the suggestion was asked for. Ask again." }
        let undo = ConflictAIUndo(loadID: document.loadID, path: path, merge: merge, current: document.current)
        updateConflict { document in
            for (target, answer) in items {
                let text = AIPrompts.resolutionText(answer, lineBreak: target.lineBreak,
                                                    finalBreak: target.needsFinalBreak)
                document.merge?.setManualText(text, region: target.region)
            }
            document.current = first.0.conflict
        }
        conflictAIUndo = undo
        return nil
    }

    /// The editor still shows the load and file the last AI Apply changed (Undo AI's button).
    var canUndoAIResolutions: Bool {
        guard let undo = conflictAIUndo, let document = conflict.value else { return false }
        return document.loadID == undo.loadID && openFile?.path == undo.path
    }

    /// Undo AI: puts back the resolution as it was before the last AI Apply (ticks, edits, the current conflict).
    func undoAIResolutions() {
        guard canUndoAIResolutions, let undo = conflictAIUndo else { return }
        updateConflict { document in
            document.merge = undo.merge
            document.current = undo.current
        }
    }

    #if DEBUG
    /// Whether `-HistqResolve` already ran in this launch.
    private static var launchResolveDone = false

    /// DEBUG `-HistqResolve A1,B2,AB3[,save|save-output|save-chunks|reset]`: once, when the first conflict loads, ticks
    /// the named sides of conflict k (1-based) through the hunk checkboxes' path, then presses Save when `save` is
    /// listed (with conflicts left, the save prompt stays open). `save-output` / `save-chunks` press Save, then the
    /// prompt's Save Output / Create Conflict Chunks (a plain save when every conflict is resolved); `reset` presses
    /// Output's Reset. `keep` or `delete` presses the modify/delete chooser's Keep File or Delete File instead. A short
    /// wait lets the editor show first. The outcome goes to `operations.txt` (`resolve <step>: …`).
    /// DEBUG `-HistqSelectAfter <path>` (with or without `-HistqResolve`): then selects that WIP file as its row's click
    /// does, to drive the leave prompt; `leave-save`, `dontsave` or `cancel` in `-HistqResolve` press that prompt's
    /// Save, Don't Save or Cancel after it (`leave-save-output`: Save, then the save prompt's Save Output). The open file and the prompt go to `operations.txt` (`select after …`).
    private func runLaunchResolve() {
        let spec = AppState.launchFlag("-HistqResolve")
        let after = AppState.launchFlag("-HistqSelectAfter")
        guard !Self.launchResolveDone, spec != nil || after != nil else { return }
        Self.launchResolveDone = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            var save: Substring?
            var leave: Substring?
            for item in (spec ?? "").split(separator: ",") {
                if item == "save" || item == "save-output" || item == "save-chunks" {
                    save = item
                    continue
                }
                if item == "leave-save" || item == "leave-save-output" || item == "dontsave" || item == "cancel" {
                    leave = item
                    continue
                }
                if item == "reset" {
                    resetConflict()
                    continue
                }
                if item == "keep" || item == "delete" {
                    guard case .modifyDelete(_, let a, let b)? = conflict.value?.source.content else {
                        Self.logger.error("-HistqResolve: \(item, privacy: .public) needs a modify/delete conflict")
                        return
                    }
                    resolveConflict(keeping: item == "keep" ? a ?? b : nil,
                                    title: item == "keep" ? "Keeping…" : "Deleting…")
                    return
                }
                let sides = item.prefix { $0 == "A" || $0 == "B" }
                guard let k = Int(item.dropFirst(sides.count)), k >= 1 else {
                    Self.logger.error("-HistqResolve: bad item \(item, privacy: .public)")
                    return
                }
                if sides.contains("A") { setConflictTicked(true, side: .a, conflict: k - 1) }
                if sides.contains("B") { setConflictTicked(true, side: .b, conflict: k - 1) }
            }
            if let save { await runLaunchSave(String(save)) }
            if let merge = conflict.value?.merge {
                RepoMenus.debugLog("resolve state: unresolved=\(merge.unresolvedCount)/\(merge.conflictCount) "
                    + "resolutions=\(merge.hasResolutions) prompt=\(conflictSavePrompt)")
            }
            guard let after else { return }
            selectWIPFile(after)
            logLaunchLeave("select after \(after)")
            switch leave {
            case "leave-save": leaveConflictSaving()
            case "leave-save-output":
                leaveConflictSaving()
                if conflictSavePrompt, let task = saveConflictOutput() { _ = await task.value }
            case "dontsave": leaveConflictDiscarding()
            case "cancel": cancelConflictLeave()
            default: return
            }
            logLaunchLeave("\(leave ?? "")")
        }
    }

    /// Logs the open file and the conflict prompts after a `-HistqSelectAfter` step.
    private func logLaunchLeave(_ step: String) {
        RepoMenus.debugLog("\(step): open=\(openFile?.path ?? "graph") leavePrompt=\(conflictLeave?.name ?? "none") "
            + "savePrompt=\(conflictSavePrompt)")
    }

    /// `-HistqResolve`'s Save step: Save, then (with conflicts left) the prompt's button `step` names; logs the write's
    /// outcome.
    private func runLaunchSave(_ step: String) async {
        var task = saveConflict()
        if !conflictSavePrompt {
            // Every conflict resolved: Save wrote the file.
            guard let task else { return RepoMenus.debugLog("fail resolve \(step): Save did nothing") }
            let ok = await task.value
            return RepoMenus.debugLog(
                ok ? "ok resolve \(step): saved" : "fail resolve \(step): \(conflictError ?? "stale")")
        }
        switch step {
        case "save-output": task = saveConflictOutput()
        case "save-chunks": task = saveConflictChunks()
        default: return RepoMenus.debugLog("ok resolve \(step): prompt shown")
        }
        guard let task else { return RepoMenus.debugLog("fail resolve \(step): nothing written") }
        let ok = await task.value
        RepoMenus.debugLog(ok ? "ok resolve \(step)" : "fail resolve \(step): \(conflictError ?? "stale")")
    }
    #endif

    // MARK: Operation in progress

    /// A button of the operation banner.
    enum OperationStep: Sendable {
        case `continue`, abort, skip
    }

    /// The running operation's title of `step` ("Continue Merge", "Abort Rebase", "Skip Commit"): the banner finds its
    /// step in `running` by it, also when the step started from a confirmation.
    static func title(of step: OperationStep, _ operation: RepoState.Operation) -> String {
        let name = switch operation {
        case .merge: "Merge"
        case .rebase: "Rebase"
        case .cherryPick: "Cherry-pick"
        case .revert: "Revert"
        case .am: "Patch Apply"
        case .none: "Operation"
        }
        return switch step {
        case .continue: "Continue \(name)"
        case .abort: "Abort \(name)"
        case .skip: operation == .am ? "Skip Patch" : "Skip Commit"
        }
    }

    /// Whether one of the banner's steps is running: its buttons wait, so a second click cannot start another.
    var isOperationStepRunning: Bool {
        guard let operation = repoState?.operation, operation != .none else { return false }
        let titles = [OperationStep.continue, .abort, .skip].map { Self.title(of: $0, operation) }
        return running.contains { titles.contains($0.title) }
    }

    /// Continue needs an operation in progress and no file left with a conflict (git refuses otherwise).
    var canContinueOperation: Bool {
        guard repoState?.isOperationInProgress == true, let status = status.value else { return false }
        return status.conflicted.isEmpty && !isOperationStepRunning
    }

    /// The banner's Continue: commits the resolution (a merge, cherry-pick or revert) or goes on with the next commit
    /// of a rebase, which may stop on new conflicts. The status read after it updates the banner.
    func continueOperation() {
        guard canContinueOperation, let operation = repoState?.operation else { return }
        run(.continueOperation(operation), title: Self.title(of: .continue, operation))
    }

    /// The banner's Abort, after a confirmation: the branch, the index and the files go back to before the operation,
    /// and the resolutions made so far are lost.
    func abortOperation() {
        guard let operation = repoState?.operation, operation != .none, !isOperationStepRunning else { return }
        let noun = Self.title(of: .abort, operation).dropFirst("Abort ".count).lowercased()
        confirm("Abort the \(noun)?",
                message: "The branch and the working tree go back to how they were before the \(noun). The conflicts "
                    + "resolved so far are lost.",
                button: Self.title(of: .abort, operation), write: .abortOperation(operation),
                operation: Self.title(of: .abort, operation))
    }

    /// The banner's Skip (a rebase or a patch apply), after a confirmation: the commit being replayed, or the patch
    /// being applied, is left out of the branch.
    func skipOperation() {
        guard let operation = repoState?.operation, operation == .rebase || operation == .am, !isOperationStepRunning
        else { return }
        let title = Self.title(of: .skip, operation)
        if operation == .am {
            confirm("Skip this patch?", message: "The branch will not have its changes.", button: title,
                    write: .skipOperation(.am), operation: title)
        } else {
            confirm("Skip this commit?", message: "The rebased branch will not have its changes.", button: title,
                    write: .skipOperation(.rebase), operation: title)
        }
    }

    #if DEBUG
    /// DEBUG `-HistqOperation continue|abort|skip`: once the status and the operation in progress are read, presses the
    /// banner's button through the same method; a confirmation is accepted as the user would.
    private func runLaunchOperation(_ step: String) {
        switch step {
        case "continue":
            if !canContinueOperation { Self.logger.error("-HistqOperation continue: Continue is disabled") }
            continueOperation()
        case "abort": abortOperation()
        case "skip": skipOperation()
        default: Self.logger.error("-HistqOperation: unknown step \(step, privacy: .public)")
        }
        if let confirmation {
            self.confirmation = nil
            run(confirmation.write, title: confirmation.operation, key: confirmation.key)
        }
    }

    /// DEBUG `-HistqRun` / `-HistqShow`: a spec with a `submodule:<path>` or `submodules` root, or the repo menu's
    /// Submodules submenu, waits for the submodule list, read in its own task after the first log page; any other spec
    /// does not.
    func debugSubmodulesReady(_ spec: String) -> Bool {
        let usesSubmodules = spec.components(separatedBy: ";;").contains {
            $0.hasPrefix("submodule:") || $0.hasPrefix("submodules|") || $0.hasPrefix("repo|Submodules|")
        }
        return !usesSubmodules || submodules.value != nil
    }
    #endif

    /// "Checkout this version" of a commit's file (its diff header): `git checkout <commit> -- <path>` through the write
    /// path, after a confirmation that says what the working tree loses. A stash's untracked file comes from the
    /// stash's untracked-files commit.
    func checkoutVersion(of target: FileTarget) {
        guard case .commit(let hash) = target.source, target.file.kind != .deleted else { return }
        let file = target.file
        let revision = file.kind == .untracked ? "\(hash)^3" : hash
        let short = String(hash.prefix(7))
        let isChanged = status.value?.entries.contains { $0.path == file.path } ?? false
        confirm("Replace \(file.name) with its version from \(short)?",
                message: isChanged
                    ? "Its staged and unstaged changes are lost."
                    : "The file in the working tree and the index becomes this version.",
                button: "Checkout This Version", write: .checkoutFiles([file.path], from: revision),
                operation: "Checkout \(file.name) from \(short)", isDestructive: isChanged)
    }

    // MARK: Undo, redo and rebase

    /// Whether Undo (or Redo) can run now, and its tooltip: `Undo Commit "Fix login"`, else why not. The toolbar, the
    /// Edit menu and the palette show the same.
    func historyAvailability(redo: Bool) -> (isEnabled: Bool, toolTip: String) {
        let verb = redo ? "Redo" : "Undo"
        if isRunning(.undo) || isRunning(.redo) { return (false, "\(verb): running…") }
        // The toolbar stays live above a modal: an undo there would change the state a confirmation or form describes.
        if hasModal { return (false, "\(verb): close the open dialog first") }
        if repoState?.isOperationInProgress == true {
            // Only a file resolved during this operation can be taken back (`UndoJournal.step` checks it is the same).
            guard let title = redo ? undoStatus.resolveRedo : undoStatus.resolveUndo else {
                return (false, UndoError.operationInProgress.message)
            }
            return (true, "\(verb) \(title)")
        }
        if undoStatus.isUnreadable { return (false, UndoError.unreadableJournal.message) }
        if let title = redo ? undoStatus.redo : undoStatus.undo { return (true, "\(verb) \(title)") }
        if !redo, let lastNotUndoable { return (false, lastNotUndoable.reason) }
        return (false, redo ? "Nothing to redo" : "Nothing to undo")
    }

    /// Takes back the journal's next entry (⌘Z in the graph, the toolbar, the palette). A refusal (the repository
    /// moved on, objects pruned) shows in a toast with `UndoError.message`; nothing changed then. No
    /// confirmation: an undo or a redo only moves between recorded states and can itself be taken back.
    func undo() {
        let availability = historyAvailability(redo: false)
        guard availability.isEnabled else { return }
        run(.undo, title: availability.toolTip, key: .undo)
    }

    func redo() {
        let availability = historyAvailability(redo: true)
        guard availability.isEnabled else { return }
        run(.redo, title: availability.toolTip, key: .redo)
    }

    /// HEAD and its first parents down to the first merge (excluded), newest first, from the loaded log: the commits
    /// an interactive rebase can start at or squash (`RebaseTodo` refuses merges in the range).
    private func rebaseLine() -> (line: [String], pastMerge: Set<String>) {
        guard let head = refs.value?.head.commit, let commits = log.value?.commits else { return ([], []) }
        let byHash = Dictionary(commits.map { ($0.hash, $0) }, uniquingKeysWith: { first, _ in first })
        var line: [String] = []
        var pastMerge = Set<String>()
        var next: String? = head
        while let hash = next, let commit = byHash[hash] {
            if commit.isMerge || !pastMerge.isEmpty { pastMerge.insert(hash) } else { line.append(hash) }
            next = commit.parents.first
        }
        return (line, pastMerge)
    }

    /// Why "Interactive Rebase from Here" cannot start at `commit` (its menu item's tooltip); nil when it can.
    func rebaseUnavailableReason(from commit: String) -> String? {
        if repoState?.isOperationInProgress == true { return UndoError.operationInProgress.message }
        let (line, pastMerge) = rebaseLine()
        if line.contains(commit) { return nil }
        if pastMerge.contains(commit) { return "A merge lies between this commit and HEAD; an interactive rebase would flatten it." }
        return "This commit is not on the current branch."
    }

    /// The selected commits "Squash N Commits" would fold, oldest last as in the graph, with why it cannot when the
    /// selection is not a run of commits on the current branch.
    func squashSelection() -> (commits: [String], reason: String?) {
        let selected = graphSelection.compactMap { item -> String? in
            if case .commit(let hash) = item { hash } else { nil }
        }
        guard selected.count >= 2 else { return (selected, RebaseTodoError.selectionTooSmall.message) }
        if repoState?.isOperationInProgress == true { return (selected, UndoError.operationInProgress.message) }
        let line = rebaseLine().line
        let positions = selected.compactMap { line.firstIndex(of: $0) }
        guard positions.count == selected.count, let low = positions.min(), let high = positions.max(),
              high - low + 1 == selected.count
        else { return (selected, RebaseTodoError.nonContiguousSelection.message) }
        return (selected, nil)
    }

    /// Opens the rebase sheet at once; it builds the todo off the main actor (`loadRebaseTodo`).
    /// With `reword`, the sheet opens with that commit's row set to reword.
    func openInteractiveRebase(from commit: String, reword: Bool = false) {
        rebaseRequest = RebaseRequest(kind: .fromCommit(commit), reword: reword ? commit : nil)
    }

    func openSquash(_ commits: [String]) {
        rebaseRequest = RebaseRequest(kind: .squash(commits))
    }

    /// "Interactive Rebase <current> onto <name>": the current branch's commits that `commit` (the tip of `name`) lacks,
    /// replayed onto it.
    func openInteractiveRebase(onto commit: String, name: String) {
        rebaseRequest = RebaseRequest(kind: .onto(commit, name: name))
    }

    /// Why "Interactive Rebase … onto …" cannot start (its tooltip); nil when it can. The sheet shows the rest
    /// (nothing to replay, a merge in the range).
    func rebaseOntoUnavailableReason() -> String? {
        repoState?.isOperationInProgress == true ? UndoError.operationInProgress.message : nil
    }

    /// Opens the Apply Patch preview on `data` at once, loading (UI rule: the click reacts first), then checks the
    /// patch (`PatchFile.validate`) and reads its preview off the main actor at the worktree's top level. A preview
    /// closed or replaced meanwhile is left alone.
    func openPatchPreview(data: Data, source: String) {
        openPatchPreview(source: source) { data }
    }

    /// Opens the Apply Patch preview at once, loading, then reads the patch with `load` (a file's read, off the main
    /// actor) before checking it as `openPatchPreview(data:source:)` does; `load`'s error shows in the preview.
    func openPatchPreview(source: String, load: @escaping @Sendable () async throws -> Data) {
        let request = PatchPreviewRequest(source: source)
        patchPreview = request
        Task { [weak self] in
            guard let self else { return }
            let result: Result<(Data, PatchPreview), Error>
            do {
                let data = try await load()
                let backend = try await backend()
                result = .success(try await Self.readPatchPreview(data, backend: backend, cwd: url))
            } catch {
                result = .failure(error)
            }
            guard patchPreview?.id == request.id else { return }
            switch result {
            case .success(let (patch, preview)):
                patchPreview?.data = patch
                patchPreview?.preview = preview
            case .failure(let error):
                patchPreview?.error = Self.message(for: error)
            }
        }
    }

    @concurrent
    private nonisolated static func readPatchPreview(_ data: Data, backend: Backend, cwd: URL) async throws
        -> (Data, PatchPreview)
    {
        let patch = try PatchFile.validate(data)
        let env = try await backend.readEnvironment(cwd: cwd)
        let preview = try await PatchFile.preview(
            patch, runner: backend.runner, cwd: backend.directories.worktree, env: env)
        return (patch, preview)
    }

    /// The todo of a rebase sheet: the commits from `commit` to HEAD, or the squash of the selected commits. Read
    /// environment, off the main actor; throws `RebaseTodoError` when the commits do not allow it.
    func loadRebaseTodo(_ kind: RebaseRequest.Kind) async throws -> RebaseTodo {
        let backend = try await backend()
        return try await Self.buildTodo(kind, backend: backend, cwd: url)
    }

    @concurrent
    private nonisolated static func buildTodo(_ kind: RebaseRequest.Kind, backend: Backend, cwd: URL) async throws
        -> RebaseTodo
    {
        let env = try await backend.readEnvironment(cwd: cwd)
        switch kind {
        case .fromCommit(let commit):
            return try await RebaseTodo.fromCommit(commit, runner: backend.runner, cwd: cwd, env: env)
        case .squash(let commits):
            return try await RebaseTodo.squash(commits, runner: backend.runner, cwd: cwd, env: env)
        case .onto(let commit, let name):
            return try await RebaseTodo.onto(commit, name: name, runner: backend.runner, cwd: cwd, env: env)
        }
    }

    /// The sheet's Start: runs the todo as a write; a conflict stops it and the operation banner takes over.
    func startRebase(_ todo: RebaseTodo) {
        run(.interactiveRebase(todo), title: todo.title)
    }

    /// Removes the tab's rebase folder once no rebase is in progress or starting: the `exec` lines of a stopped rebase
    /// read their message files only on Continue, so the folder lives exactly as long as the rebase.
    private func removeRebaseFilesIfDone() {
        guard rebaseFilesMayExist, rebaseStarts == 0, let state = repoState, state.operation != .rebase else { return }
        rebaseFilesMayExist = false
        let generation = rebaseGeneration.withLock { $0 }
        let lock = rebaseGeneration
        Task { [weak self] in
            guard let backend = try? await self?.backend() else { return }
            await Self.removeFolder(backend.rebaseFolder, ifStill: generation, lock)
        }
    }

    /// Removes the folder only while no rebase started since `generation` was read; the start bumps it under `lock`
    /// before it writes, so the removal either ends first or does nothing.
    @concurrent
    private nonisolated static func removeFolder(
        _ folder: URL, ifStill generation: Int, _ lock: OSAllocatedUnfairLock<Int>
    ) async {
        lock.withLock { current in
            guard current == generation else { return }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    #if DEBUG
    /// DEBUG `-HistqOpenRebase <rev>` / `-HistqOpenSquash "<rev>,<rev>…"`: once the refs and the whole log are in,
    /// resolves the revisions (`series~4`) and opens the sheet as the menu does (with `-HistqStartRebase`, runs it).
    /// For QA on fixture copies only.
    private func runLaunchRebase(_ revisions: [String], squash: Bool) async {
        for _ in 0..<100 {
            if refs.value != nil, log.value?.isComplete == true { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let backend = try? await backend() else { return }
        var commits: [String] = []
        for revision in revisions {
            guard let oid = try? await Self.resolveDebugRevision(revision, backend: backend, cwd: url) else {
                RepoMenus.debugLog("fail open rebase: \(revision) is not a commit")
                return
            }
            commits.append(oid)
        }
        if squash {
            selectGraph(commits.map { .commit($0) })
            openSquash(commits)
        } else if let first = commits.first {
            openInteractiveRebase(from: first)
        }
        // `-HistqStartRebase`: Start as the sheet would, with the todo as built (all picks; a squash with its default
        // message), then the outcome goes to `operations.txt`.
        guard ProcessInfo.processInfo.arguments.contains("-HistqStartRebase"), let kind = rebaseRequest?.kind else { return }
        rebaseRequest = nil
        do {
            startRebase(try await loadRebaseTodo(kind))
            while !running.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
            RepoMenus.debugLog(failure.map { "fail rebase: \($0.message)" } ?? "ok rebase")
        } catch {
            RepoMenus.debugLog("fail rebase todo: \(Self.writeMessage(for: error))")
        }
    }

    @concurrent
    private nonisolated static func resolveDebugRevision(_ revision: String, backend: Backend, cwd: URL) async throws
        -> String
    {
        let env = try await backend.readEnvironment(cwd: cwd)
        return try await backend.runner.run(
            ["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"], cwd: cwd, env: env
        ).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// DEBUG `-HistqUndo N` / `-HistqRedo N`: once the status and the journal are read, N undos (then N redos), one
    /// after the other through the toolbar's path; each outcome is appended to `operations.txt`.
    private func runLaunchHistory(undos: Int, redos: Int) async {
        for _ in 0..<100 {
            if status.value != nil, refs.value != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        for redo in Array(repeating: false, count: undos) + Array(repeating: true, count: redos) {
            let availability = historyAvailability(redo: redo)
            let verb = redo ? "redo" : "undo"
            guard availability.isEnabled else {
                RepoMenus.debugLog("fail \(verb): disabled (\(availability.toolTip))")
                continue
            }
            if redo { self.redo() } else { undo() }
            while !running.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
            RepoMenus.debugLog(failure.map { "fail \(verb): \($0.message)" } ?? "ok \(availability.toolTip)")
            failure = nil
        }
        RepoMenus.debugLog("done history")
    }

    /// DEBUG `-HistqSelectWalk <n>[,<ms>]` (timing of commit switches): once the whole log is laid out and the launch's
    /// detail is loaded, selects the log's first n commit rows one by one (the WIP and stash rows are not commits)
    /// through `selectGraph`, the click path, `ms` apart (default 250), then walks back up from row n-1 to row 1
    /// (revisits), and logs `walk done`. Each select logs its own `select`, `content-info` (a commit of the log; else
    /// `placeholder`) and `content` lines.
    private func runSelectWalk(_ spec: String) async {
        let parts = spec.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let count = parts.first ?? nil, count > 0 else {
            return Self.logger.error("-HistqSelectWalk: expected <n>[,<ms>], got \(spec, privacy: .public)")
        }
        let interval = (parts.count > 1 ? parts[1] : nil) ?? 250
        for _ in 0..<600 {
            if log.value?.isComplete == true, detail.value != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Lets the launch's last frames go by, so the first select is not timed against them.
        try? await Task.sleep(for: .milliseconds(500))
        let hashes = (log.value?.commits ?? []).prefix(count).map(\.hash)
        UITiming.walk("start \(hashes.count) every \(interval) ms")
        for hash in hashes + hashes.dropLast().reversed() {
            selectGraph([.commit(hash)])
            try? await Task.sleep(for: .milliseconds(interval))
        }
        UITiming.walk("done")
    }

    /// DEBUG `-HistqHistoryWalk <n>[,<ms>]`: once a file history is read, clicks its first `n` rows down and back up,
    /// one every `ms` (default 250), as a click on a row does.
    private func runHistoryWalk(_ spec: String) async {
        let parts = spec.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let count = parts.first ?? nil, count > 0 else {
            return Self.logger.error("-HistqHistoryWalk: expected <n>[,<ms>], got \(spec, privacy: .public)")
        }
        let interval = (parts.count > 1 ? parts[1] : nil) ?? 250
        var history: (RepoTool, [FileHistoryEntry])?
        for _ in 0..<600 {
            if let tool = historyTool, case .loaded(.history(let entries)) = toolState, fileDiff.value != nil {
                history = (tool, entries)
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let (tool, entries) = history else { return Self.logger.error("-HistqHistoryWalk: no file history") }
        try? await Task.sleep(for: .milliseconds(500))
        let rows = Array(entries.prefix(count))
        UITiming.walk("start history \(rows.count) every \(interval) ms")
        for entry in rows.dropFirst() + rows.dropLast().reversed() {
            openHistoryEntry(entry, of: tool)
            try? await Task.sleep(for: .milliseconds(interval))
        }
        UITiming.walk("done")
    }
    #endif

    // MARK: Commit detail

    /// One commit's message, people, dates and parents (`git log -1`, the log's fields: `%an`/`%cn`, the body's
    /// trailing newlines dropped), then its files (`readFileChanges`). Read environment, off the main actor.
    @concurrent
    private nonisolated static func readCommit(_ backend: Backend, cwd: URL, hash: String, isStash: Bool) async throws
        -> CommitDetail
    {
        guard GitOperations.isObjectID(hash) else { throw CommitReadError.notACommit(hash) }
        let env = try await backend.readEnvironment(cwd: cwd)
        let format = "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%cn%x1f%ce%x1f%ct%x1f%s%x1f%b"
        let info = try await backend.runner.run(
            ["log", "-1", "-z", "--no-show-signature", format, "--end-of-options", hash, "--"], cwd: cwd, env: env)
        var text = info.text
        while text.last == "\0" || text.last == "\n" { text.removeLast() }
        let fields = text.split(separator: "\u{1F}", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 10 else { throw CommitReadError.notACommit(hash) }
        let parents = fields[1].split(separator: " ").map(String.init)
        let date = { (field: String) in Date(timeIntervalSince1970: TimeInterval(field) ?? 0) }
        let files = try await readFileChanges(backend, cwd: cwd, env: env, hash: fields[0], parents: parents,
                                              isStash: isStash)
        return CommitDetail(
            hash: fields[0], parents: parents, authorName: fields[2], authorEmail: fields[3],
            authorDate: date(fields[4]), committerName: fields[5], committerEmail: fields[6],
            committerDate: date(fields[7]), subject: fields[8], body: fields[9], files: files, isStash: isStash)
    }

    /// `header` (the log's commit, its files nil) with its files: `readCommit`'s second half only, one git process.
    @concurrent
    private nonisolated static func readFiles(_ backend: Backend, cwd: URL, of header: CommitDetail) async throws
        -> CommitDetail
    {
        guard GitOperations.isObjectID(header.hash) else { throw CommitReadError.notACommit(header.hash) }
        let env = try await backend.readEnvironment(cwd: cwd)
        let files = try await readFileChanges(backend, cwd: cwd, env: env, hash: header.hash, parents: header.parents,
                                              isStash: header.isStash)
        return header.with(files: files)
    }

    /// The files of commit `hash` against its first parent (`diff-tree --raw`, whose modes tell a submodule; a root
    /// commit against the empty tree, a merge against its first parent, a stash adds its untracked files).
    private nonisolated static func readFileChanges(
        _ backend: Backend, cwd: URL, env: [String: String], hash: String, parents: [String], isStash: Bool
    ) async throws -> [FileChange] {
        let fileOptions = ["diff-tree", "-r", "-z", "--raw", "-M", "--no-ext-diff", "--no-textconv",
                           "--no-commit-id"]
        let revisions = parents.first.map { ["--end-of-options", $0, hash] } ?? ["--root", "--end-of-options", hash]
        var files = parseRaw(
            try await backend.runner.run(fileOptions + revisions + ["--"], cwd: cwd, env: env).stdout)
        if isStash, parents.count > 2 {
            let untracked = parseRaw(try await backend.runner.run(
                fileOptions + ["--root", "--end-of-options", parents[2], "--"], cwd: cwd, env: env).stdout)
            let known = Set(files.map(\.path))
            files += untracked.filter { !known.contains($0.path) }.map { FileChange(kind: .untracked, path: $0.path) }
        }
        return files
    }

    /// The files of a compare (`base` against `head`, nil for the working tree), off the main actor. Untracked files are
    /// not part of it.
    @concurrent
    private nonisolated static func readCompareFiles(_ backend: Backend, cwd: URL, base: String, head: String?)
        async throws -> [FileChange]
    {
        let env = try await backend.readEnvironment(cwd: cwd)
        return parseNameStatus(
            try await DiffReader.compareFiles(base: base, head: head, runner: backend.runner, cwd: cwd, env: env))
    }

    /// Every file of commit `commit`'s tree (its Files card's "View all files"), path order: the changed ones as
    /// `commit.files` has them (a deleted file, gone from the tree, too), the others `.unchanged`. Submodules are left
    /// out unless changed (no blob to show). Read environment, off the main actor; nothing is cached.
    func readAllFiles(of commit: CommitDetail) async throws -> [FileChange] {
        let backend = try await backend()
        return try await Self.readTreeFiles(backend, cwd: url, hash: commit.hash, changed: commit.files ?? [])
    }

    @concurrent
    private nonisolated static func readTreeFiles(
        _ backend: Backend, cwd: URL, hash: String, changed: [FileChange]
    ) async throws -> [FileChange] {
        guard GitOperations.isObjectID(hash) else { throw CommitReadError.notACommit(hash) }
        let env = try await backend.readEnvironment(cwd: cwd)
        // `<mode> SP <type> SP <object> TAB <path>`, NUL-terminated.
        let output = try await backend.runner.run(
            ["ls-tree", "-r", "-z", "--full-tree", "--end-of-options", hash], cwd: cwd, env: env).stdout
        var byPath = Dictionary(changed.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in output.split(separator: 0) {
            let line = String(decoding: entry, as: UTF8.self)
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let path = String(line[line.index(after: tab)...])
            guard byPath[path] == nil, line[..<tab].split(separator: " ").dropFirst().first == "blob" else { continue }
            byPath[path] = FileChange(kind: .unchanged, path: path)
        }
        return byPath.values.sorted { $0.path < $1.path }
    }

    /// `--name-status -z`: a status (`M`, `A`, `D`, `T`, `R100`, `C75`), then the path; renames and copies give the
    /// old path, then the new one.
    private nonisolated static func parseNameStatus(_ output: Data) -> [FileChange] {
        var fields = output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.makeIterator()
        var files: [FileChange] = []
        while let status = fields.next(), let letter = status.first {
            guard let path = fields.next() else { break }
            if letter == "R" || letter == "C" {
                guard let newPath = fields.next() else { break }
                files.append(FileChange(letter: letter, path: newPath, originalPath: path))
            } else {
                files.append(FileChange(letter: letter, path: path))
            }
        }
        return files
    }

    /// `--raw -z`: `:<old mode> <new mode> <old sha> <new sha> <status>`, then the path; renames and copies give the old
    /// path, then the new one. A gitlink (mode 160000) on either side is a submodule.
    private nonisolated static func parseRaw(_ output: Data) -> [FileChange] {
        var fields = output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.makeIterator()
        var files: [FileChange] = []
        while let field = fields.next() {
            guard let record = RawDiffRecord(field), let letter = record.status.first, let path = fields.next()
            else { break }
            let isSubmodule = record.isGitlink
            if letter == "R" || letter == "C" {
                guard let newPath = fields.next() else { break }
                files.append(FileChange(letter: letter, path: newPath, originalPath: path, isSubmodule: isSubmodule))
            } else {
                files.append(FileChange(letter: letter, path: path, isSubmodule: isSubmodule))
            }
        }
        return files
    }

    private enum CommitReadError: LocalizedError {
        case notACommit(String)
        case refGone(String)

        var errorDescription: String? {
            switch self {
            case .notACommit(let text): "\(text) is not a commit."
            case .refGone(let ref): "The \(ref) no longer exists."
            }
        }
    }

    /// HEAD's message (subject, then body), for the commit box's Amend. Read environment.
    func lastCommitMessage() async throws -> (subject: String, body: String) {
        let backend = try await backend()
        guard let head = status.value?.branch.commit else { return ("", "") }
        let commit = try await Self.readCommit(backend, cwd: url, hash: head, isStash: false)
        return (commit.subject, commit.body)
    }

    // MARK: Writes

    /// Runs a user-initiated write of the WIP panel with the write environment (the login shell's PATH, for hooks
    /// and signing tools), off the main actor, then rereads the status and the refs (also when it failed: it may have
    /// done part of its work). Throws the write's error; `writeMessage(for:)` words it for the panel. Returns a pull's
    /// or an interactive rebase's outcome (`.autostashPending`: it stopped, on conflicts or at an `edit`, with git
    /// holding the local changes) or a stash apply's.
    @discardableResult
    func perform(_ write: Write) async throws -> WriteOutcome {
        let backend = try await backend()
        // The profile as it is when the write starts; its environment is built off the main actor in `run`.
        let profile = await writeProfile()
        let isRebase = if case .interactiveRebase = write { true } else { false }
        if isRebase {
            rebaseStarts += 1
            rebaseFilesMayExist = true
            rebaseGeneration.withLock { $0 += 1 }
        }
        defer {
            if isRebase {
                rebaseStarts -= 1
                // The read after the write skipped the folder while the start counted: a rebase that completed (or
                // failed before it began) leaves it now.
                removeRebaseFilesIfDone()
            }
        }
        let outcome: WriteOutcome
        do {
            outcome = try await Self.run(write, profile: profile, backend: backend, cwd: url)
        } catch GitError.autostashKept(let hash) where { if case .commit = write { true } else { false } }() {
            // A commit that concluded a stopped pull is made (the WIP panel calls `perform`, not `run`).
            postToast(.warning("Commit", detail: "Changes kept in stash \(hash.prefix(7))."))
            outcome = .done
        } catch {
            // A pull or an interactive rebase whose local changes stayed in a stash still ran.
            let ran = switch write { case .pull, .interactiveRebase: true; default: false }
            if case GitError.autostashKept = error, ran, lastNotUndoable != write.notUndoable {
                lastNotUndoable = write.notUndoable
            }
            await refreshAfterWrite()
            throw error
        }
        if case .optimizeRepository = write {
            // Outside the write lane, it may end after later writes; it changes nothing undo covers.
        } else if lastNotUndoable != write.notUndoable {
            lastNotUndoable = write.notUndoable
        }
        await refreshAfterWrite()
        return outcome
    }

    /// Waits for the reread to publish: the watcher may see the write's own changes and start a refresh that cancels
    /// this one (and takes its scope over), so it waits for the newer one too, a few times at most.
    private func refreshAfterWrite() async {
        refresh(scope: [.status, .refs])
        for _ in 0..<5 {
            guard let task = refreshTask else { break }
            await task.value
        }
    }

    /// Returns the pull's, the interactive rebase's or the stash apply's outcome (`.done` for every other write).
    @concurrent
    private nonisolated static func run(_ write: Write, profile: Profile?, backend: Backend, cwd: URL) async throws
        -> WriteOutcome
    {
        var outcome = WriteOutcome.done
        let base = await GitToolchain.writeBase()
        // The profile's GitHub token, from the Keychain off the main actor (cached), for network writes alone: their
        // operations hand it to git only when the gate lets them (`GitInvocation.networkToken`).
        let token = write.isNetwork ? await GitHubTokens.token(for: profile) : nil
        // The tab's identity, signing and SSH key, as command-scope config: `.git/config` is never edited.
        let ops = GitOperations(
            runner: backend.runner, cwd: cwd, profile: profile, base: base, token: token, journal: backend.journal)
        // Local writes (patches, the merge tool) never get the token.
        let environment = ops.env
        switch write {
        case .stage(let paths): try await ops.stage(paths)
        case .stageAll: try await ops.stageAll()
        case .unstage(let paths): try await ops.unstage(paths)
        case .unstageAll: try await ops.unstageAll()
        case .discard(let paths): try await ops.discard(paths)
        case .removeUntracked(let paths): try await ops.removeUntracked(paths)
        case .discardAll(let includingUntracked): try await ops.discardAll(includingUntracked: includingUntracked)
        case .commit(let message): try await ops.commit(message: message)
        case .amend(let message): try await ops.amend(message: message)
        case .editMessage(let commit, let message): try await ops.editHeadMessage(commit, message: message)
        case .applyPatch(let patch, let action):
            // `apply` takes the runner's write lane itself, like the operations.
            try await PatchBuilder.apply(patch, action: action, runner: backend.runner, cwd: cwd, env: environment)
        case .applyPatchToWorkingTree(let patch): outcome = .patch(try await ops.applyPatchToWorkingTree(patch))
        case .applyPatchCommits(let patch, let count): try await ops.applyMailbox(patch, count: count)

        case .checkoutBranch(let name, let autostash): try await ops.checkout(branch: name, autostash: autostash)
        case .checkoutTracking(let remoteBranch, let localName, let autostash):
            try await ops.checkoutTracking(remoteBranch: remoteBranch, as: localName, autostash: autostash)
        case .checkoutCommit(let revision): try await ops.checkout(commit: revision)
        case .checkoutFiles(let paths, let revision): try await ops.checkoutFiles(paths, from: revision)
        case .checkoutPullRequest(let number, let remote):
            try await ops.fetchRefspec(remote: remote, refspec: "pull/\(number)/head:pr/\(number)")
            try await ops.checkout(branch: "pr/\(number)")

        case .fetchAll(let prune): try await ops.fetchAll(prune: prune)
        case .pullBranch(let branch, let remote, let remoteBranch):
            try await ops.fetchRefspec(remote: remote, refspec: "heads/\(remoteBranch):\(branch)")
        case .pull(let mode, let autostash):
            if try await ops.pull(mode, autostash: autostash) == .autostashPending { outcome = .autostashPending }
        case .push(let branch, let remote, let remoteBranch, let setUpstream, let lease):
            try await ops.push(
                branch: branch, to: remote, as: remoteBranch, setUpstream: setUpstream, forceWithLease: lease)
        case .pushTag(let name, let remote): try await ops.pushTag(name, to: remote)
        case .pushMirror(let remote): try await ops.pushMirror(to: remote)
        case .deleteRemoteBranch(let name, let remote): try await ops.deleteRemoteBranch(name, on: remote)
        case .deleteBranchAndRemote(let name, let remote, let remoteBranch):
            try await ops.deleteBranch(name, force: false)
            try await ops.deleteRemoteBranch(remoteBranch, on: remote)
        case .deleteRemoteTag(let name, let remote): try await ops.deleteRemoteTag(name, on: remote)

        case .createBranch(let name, let revision, let checkout):
            try await ops.createBranch(name, from: revision, checkout: checkout)
        case .renameBranch(let name, let newName): try await ops.renameBranch(name, to: newName)
        case .deleteBranch(let name, let force): try await ops.deleteBranch(name, force: force)
        case .setUpstream(let branch, let upstream): try await ops.setUpstream(of: branch, to: upstream)

        case .addRemote(let name, let url): try await ops.addRemote(name, url: url)
        case .removeRemote(let name): try await ops.removeRemote(name)
        case .renameRemote(let name, let newName): try await ops.renameRemote(name, to: newName)
        case .setRemoteURL(let name, let url): try await ops.setRemoteURL(name, url: url)

        case .addWorktree(let path, let source, let newBranch):
            try await ops.addWorktree(at: path, from: source, newBranch: newBranch)
        case .removeWorktree(let path, let force): try await ops.removeWorktree(path, force: force)
        case .pruneWorktrees: try await ops.pruneWorktrees()

        case .updateSubmodules(let paths, let initialize):
            try await ops.updateSubmodules(paths, initialize: initialize, recursive: true)
        case .syncSubmodules(let paths): try await ops.syncSubmodules(paths)
        case .addSubmodule(let url, let path, let branch, let recursive):
            try await ops.addSubmodule(url: url, path: path, branch: branch, recursive: recursive)
        case .removeSubmodule(let path, let force): try await ops.removeSubmodule(path, force: force)
        case .setSubmoduleURL(let path, let url): try await ops.setSubmoduleURL(path, url: url)
        case .setSubmoduleBranch(let path, let branch): try await ops.setSubmoduleBranch(path, branch: branch)
        case .optimizeRepository: try await ops.optimizeRepository()
        case .ignore(let pattern, let file): try await ops.ignore(pattern: pattern, in: file)

        case .merge(let revision, let checkoutFirst, let mode):
            if let checkoutFirst {
                // Diverged branches are refused before the checkout, so the user stays on their branch. A branch that
                // already contains `revision` goes on: git's `--ff-only` reports it up to date.
                let target = "refs/heads/\(checkoutFirst)"
                if mode == .fastForwardOnly, try await !ops.isAncestor(target, of: revision),
                   try await !ops.isAncestor(revision, of: target) {
                    let name = ["refs/heads/", "refs/remotes/"].first { revision.hasPrefix($0) }
                        .map { String(revision.dropFirst($0.count)) } ?? revision
                    throw GitError.nonFastForward(exit: 1, stderrTail: "\(checkoutFirst) has commits that \(name) "
                        + "does not have, so it cannot be fast-forwarded to \(name).")
                }
                try await ops.checkout(branch: checkoutFirst)
            }
            try await ops.merge(revision, mode: mode)
        case .rebase(let upstream, let checkoutFirst):
            if let checkoutFirst { try await ops.checkout(branch: checkoutFirst) }
            try await ops.rebase(onto: upstream)
        case .fastForward(let branch, let source): try await ops.fastForward(branch, to: source)
        case .cherryPick(let commit, let mainline): try await ops.cherryPick([commit], mainline: mainline)
        case .revert(let commit, let mainline): try await ops.revert(commit, mainline: mainline)
        case .reset(let revision, let mode): try await ops.reset(to: revision, mode: mode)

        case .stashPush(let message): try await ops.stashPush(message: message, includeUntracked: true)
        case .stashApply(let hash): outcome = .stash(try await ops.stashApply(hash), pop: false)
        case .stashPop(let hash): outcome = .stash(try await ops.stashPop(hash), pop: true)
        case .stashDrop(let hash): try await ops.stashDrop(hash)
        case .stashPaths(let paths): try await ops.stashPush(message: nil, includeUntracked: true, paths: paths)
        case .stashRestoreFile(let hash, let path, let untracked):
            try await ops.stashRestoreFile(hash, path: path, untracked: untracked)

        case .createTag(let name, let revision, let message):
            try await ops.createTag(name, at: revision, message: message)
        case .deleteTag(let name): try await ops.deleteTag(name)

        case .resolveConflict(let path, let content): try await ops.resolve(path: path, content: content)
        case .writeConflictChunks(let path, let content):
            try GitOperations.writeResolution(content, to: path, cwd: cwd)
        case .mergeTool(let path, let tool):
            let runner = backend.runner
            let args = ["--literal-pathspecs", "mergetool", "--no-prompt"] + (tool.map { ["--tool=\($0)"] } ?? [])
                + ["--", path]
            _ = try await runner.mutate { try await runner.run(args, cwd: cwd, env: environment) }

        case .continueOperation(let operation): try await ops.continueOperation(operation)
        case .abortOperation(let operation): try await ops.abortOperation(operation)
        case .skipOperation(let operation): try await ops.skipOperation(operation)

        case .undo: try await ops.undo()
        case .redo: try await ops.redo()
        case .interactiveRebase(let todo):
            // The folder may hold the files of a rebase still stopped at a conflict: never replace them then.
            let env = try await backend.readEnvironment(cwd: cwd)
            if try await RepoState.read(runner: backend.runner, cwd: cwd, env: env).isOperationInProgress {
                throw UndoError.operationInProgress
            }
            let folder = backend.rebaseFolder
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if try await ops.interactiveRebase(todo, files: folder) { outcome = .autostashPending }
        }
        return outcome
    }

    // MARK: Operations

    /// Runs a user operation (the action bar, a menu, a dialog) through `perform` without blocking: it is in `running`
    /// when this returns (with `key`, the action bar button that shows it). Its outcome shows as a toast
    /// (`postToast`); a failure also goes to `failure` (`report`), which a new operation clears.
    func run(_ write: Write, title: String, key: ActionBarAction? = nil) {
        nextOperationID &+= 1
        let operation = RunningOperation(id: nextOperationID, title: title, key: key)
        running.append(operation)
        failure = nil
        Task { [weak self] in
            guard let self else { return }
            let wasInProgress = repoState?.isOperationInProgress == true
            // What a push, pull or fetch changed is read from the refs before it and after it.
            let refsBefore = refs.value
            // The commits HEAD records for the submodules, when this write may move them (`autoUpdateSubmodules`).
            let submodulesBefore = movesSubmodules(write) ? await recordedSubmodules() : nil
            do {
                let outcome = try await perform(write)
                if case .removeWorktree(let path, _) = write { worktreeRemoved(path) }
                // Started one (a rebase at an `edit` step), or Continue / Skip went on to the next stop.
                let resumes = switch write { case .continueOperation, .skipOperation: true; default: false }
                let stopped = repoState?.isOperationInProgress == true && (!wasInProgress || resumes)
                if outcome == .autostashPending {
                    let conflicts = repoState?.conflictedPaths.isEmpty == false
                    postToast(.warning(conflicts ? "\(title) stopped on conflicts" : "\(title) stopped",
                                       detail: "Changes come back after continue or abort."))
                } else if case .stash(let stash, let pop) = outcome, !stash.undoable {
                    // Undo would skip it and take back the operation before it.
                    postToast(.warning(title, detail: stash.applied
                        ? "Applied, but this apply cannot be undone."
                        : "Applied with conflicts: this apply cannot be undone." + (pop ? " The stash is kept." : "")))
                } else if case .patch(let patch) = outcome {
                    switch patch {
                    case .applied:
                        postToast(.success(title, detail: "Applied to the working tree (unstaged). Discard the changes "
                            + "to take it back."))
                    case .merged:
                        postToast(.success(title, detail: "Applied with a 3-way merge; the changes are staged."))
                    case .conflicts:
                        postToast(.warning(title, detail: "Applied with conflicts"))
                        // `perform` reread the status: the conflicted paths include the apply's.
                        if let first = status.value?.conflicted.first { selectConflict(first.path) }
                    }
                } else if case .optimizeRepository = write {
                    // Before `stopped`: a merge or rebase may stop on conflicts while it runs (it is outside the lane).
                    postToast(.success(title, detail: "Repository optimized: history and the graph load faster."))
                } else if stopped {
                    postToast(.stopped(title))
                } else if case .applyPatch = write {
                    // Lines staged, unstaged or discarded from a diff: no success toast, as the WIP panel's files.
                } else if case .applyPatchCommits(_, let count) = write {
                    postToast(.success(title, detail: count == 1 ? "Applied 1 commit." : "Applied \(count) commits."))
                } else if case .ignore(let pattern, let file) = write {
                    let name = switch file { case .gitignore: ".gitignore"; case .infoExclude: ".git/info/exclude" }
                    postToast(.success(title, detail: "Added \(pattern) to \(name)."))
                } else {
                    postToast(.success(title, detail: OperationToast.outcome(of: write, before: refsBefore,
                                                                             after: refs.value)))
                }
                // Only after a write that went through: not stopped, no conflicts, no operation in progress.
                if let submodulesBefore, outcome == .done, !stopped, repoState?.isOperationInProgress != true,
                   status.value?.conflicted.isEmpty ?? true
                {
                    autoUpdateSubmodules(submodulesBefore.backend, before: submodulesBefore.recorded)
                }
            } catch GitError.autostashKept(let hash) {
                // A warning, not a failure, and before any cancellation check: the changes may be only in that stash.
                postToast(.warning(title, detail: "Changes kept in stash \(hash.prefix(7))."))
            } catch {
                if !(error is CancellationError) {
                    // `ignore` refuses to write through a symlink or into something that is not a plain file.
                    let message = if case .ignore = write, case UndoError.unsafePath = error {
                        "The ignore file or its folder is a symlink or not a plain file; Histq won't write through it."
                    } else {
                        Self.message(for: error)
                    }
                    let failure = OperationFailure(title: title, write: write, error: error, message: message)
                    if !offerForcePush(after: failure, key: key) { report(failure) }
                }
            }
            running.removeAll { $0.id == operation.id }
        }
    }

    /// The writes after which the submodules may have to follow the commits this repository records: those that move
    /// HEAD or the working tree to other commits (a fast-forward of the current branch only).
    private func movesSubmodules(_ write: Write) -> Bool {
        switch write {
        case .checkoutBranch, .checkoutTracking, .checkoutCommit, .checkoutPullRequest, .pull, .merge, .rebase,
             .cherryPick, .applyPatchCommits, .revert, .interactiveRebase, .continueOperation, .skipOperation, .undo,
             .redo:
            true
        case .fastForward(let branch, _): branch == currentBranch
        case .reset(_, let mode): mode == .hard
        default: false
        }
    }

    /// The commits HEAD records for the submodules, read off the main actor, with the backend that read them. Nil when
    /// Update submodules automatically is off, without `.gitmodules`, or when the read failed: no update then.
    private func recordedSubmodules() async -> (backend: Backend, recorded: [String: String])? {
        guard Preferences.defaults.bool(forKey: PrefKey.autoUpdateSubmodules.rawValue),
              let backend = try? await backend(),
              FileManager.default.fileExists(atPath: backend.directories.worktree.appending(path: ".gitmodules").path),
              let recorded = try? await Self.readRecordedSubmodules(backend)
        else { return nil }
        return (backend, recorded)
    }

    @concurrent
    private nonisolated static func readRecordedSubmodules(_ backend: Backend) async throws -> [String: String] {
        try await SubmoduleReader.recorded(
            runner: backend.runner, cwd: backend.directories.worktree, base: backend.base, revision: "HEAD")
    }

    /// After a write that moved this repository's pointers: the clean submodules still on the commit recorded `before`
    /// move to the one recorded now (`GitOperations.autoUpdateSubmodules`), as an operation of its own. Its toasts name
    /// the submodules updated, those left alone and why, and those that failed; never a failure of the write. Then the
    /// status, the refs and the submodules are read again.
    private func autoUpdateSubmodules(_ backend: Backend, before: [String: String]) {
        guard FileManager.default.fileExists(atPath: backend.directories.worktree.appending(path: ".gitmodules").path)
        else { return }
        nextOperationID &+= 1
        let operation = RunningOperation(id: nextOperationID, title: "Updating submodules", key: nil)
        running.append(operation)
        Task { [weak self] in
            guard let self else { return }
            defer { running.removeAll { $0.id == operation.id } }
            let profile = await writeProfile()
            guard let result = try? await Self.autoUpdateSubmodules(backend, profile: profile, before: before) else {
                return
            }
            let updated = result.updated.count
            if updated > 0 {
                postToast(.success("Updated \(updated) submodule\(updated == 1 ? "" : "s")",
                                   detail: Self.listed(result.updated, separator: ", ")))
            }
            if !result.skipped.isEmpty {
                let count = result.skipped.count
                postToast(.warning("\(count) submodule\(count == 1 ? "" : "s") not updated",
                                   detail: Self.listed(result.skipped.map(Self.skipReason), separator: "\n")))
            }
            if !result.failed.isEmpty {
                let lines = result.failed.map { failure in
                    let message = failure.message.split(separator: "\n").first.map(String.init) ?? "git failed."
                    return failure.path.isEmpty
                        ? "The repository's submodule list could not be read: \(message)"
                        : "\(failure.path): \(message)"
                }
                postToast(.warning("Updating submodules failed", detail: Self.listed(lines, separator: "\n")))
            }
            if updated > 0 || !result.failed.isEmpty { await refreshAfterWrite() }
        }
    }

    /// Throws only `CancellationError`.
    @concurrent
    private nonisolated static func autoUpdateSubmodules(
        _ backend: Backend, profile: Profile?, before: [String: String]
    ) async throws -> SubmoduleAutoUpdate {
        // It may fetch a recorded commit a submodule lacks: the profile's token, as `.updateSubmodules` gets it.
        let ops = GitOperations(
            runner: backend.runner, cwd: backend.directories.worktree, profile: profile,
            base: await GitToolchain.writeBase(), token: await GitHubTokens.token(for: profile))
        return try await ops.autoUpdateSubmodules(before: before, base: backend.base)
    }

    /// "vendor/moved has new commits".
    private nonisolated static func skipReason(_ skipped: SubmoduleAutoUpdate.Skipped) -> String {
        switch skipped.reason {
        case .moved: "\(skipped.path) has new commits"
        case .onBranch(let branch): "\(skipped.path) is on branch \(branch), use Update"
        case .dirty: "\(skipped.path) has uncommitted changes"
        case .updateMode(let mode): "\(skipped.path) uses update mode \(mode)"
        case .notRecordedBefore: "\(skipped.path) is new"
        }
    }

    /// The first six, then "and N more".
    private nonisolated static func listed(_ items: [String], separator: String) -> String {
        let shown = items.prefix(6).joined(separator: separator)
        return items.count > 6 ? "\(shown)\(separator)and \(items.count - 6) more" : shown
    }

    /// A pull request's Resolve with AI / Resolve manually (its merge box): fetches every remote without pruning (only
    /// that refreshes `<remote>/<base>`), checks out `head` (tracking `<remote>/<head>` when there is no local branch)
    /// and merges `<remote>/<base>` into it, so the conflicts GitHub reports show here. A local `head` that is only
    /// behind `<remote>/<head>` (checked out before a teammate pushed) is fast-forwarded first; one with commits of its
    /// own is refused, never merged into: its conflicts would not be GitHub's, and its push would be rejected. The
    /// click's checks (a clean tree, no operation in progress, nothing else running) are made again after the fetch
    /// and before the merge, since changes made meanwhile would be carried onto `head`: a stop is a warning toast. Each
    /// step goes through `perform` (the journal takes back the checkout and the merge, not the fast-forward) and the
    /// banner can abort the merge. Like `run`, it is in `running` when this returns. A merge that stops on conflicts is
    /// the expected outcome, not a failure: the conflict editor opens on the first conflicted file, and `withAI`
    /// starts Suggest All once it has loaded. The caller checks that the pull request is from this repository.
    func resolvePullRequestConflicts(head: String, base: String, remote: String, number: Int, withAI: Bool) {
        let title = "Merge \(base) into \(head)"
        nextOperationID &+= 1
        let operation = RunningOperation(id: nextOperationID, title: title, key: nil)
        running.append(operation)
        failure = nil
        let timing = "resolve pr \(number) \(withAI ? "ai" : "manual")"
        Task { [weak self] in
            guard let self else { return }
            defer { running.removeAll { $0.id == operation.id } }
            // Why the next step must not run (a timing token and the toast's text), read after a write: `perform`
            // rereads the status and the refs, so it sees what changed while that write ran.
            @MainActor func refusal() -> (reason: String, detail: String)? {
                if running.contains(where: { $0.id != operation.id }) {
                    return ("busy", "Another operation started meanwhile: resolve again once it has finished.")
                }
                if repoState?.isOperationInProgress == true {
                    return ("in-progress", "A merge, rebase, cherry-pick, revert or patch apply is in progress: "
                        + "finish or abort it, then resolve again.")
                }
                guard let status = status.value, status.conflicted.isEmpty, status.staged.isEmpty,
                      status.unstaged.isEmpty
                else { return ("dirty", "The working tree has uncommitted changes: commit or stash them, then resolve "
                    + "again.") }
                return nil
            }
            @MainActor func refuse(_ refusal: (reason: String, detail: String)) {
                UITiming.content("\(timing) refused \(refusal.reason)")
                postToast(.warning("\(title) not started", detail: refusal.detail))
            }
            // The step in flight: a failure names it, and only the merge's conflicts are expected.
            var write = Write.fetchAll(prune: false)
            do {
                try await perform(write)
                if let refusal = refusal() {
                    refuse(refusal)
                    return
                }
                // Read after the fetch: its write reread the refs, so `tip` is the pull request's head as pushed.
                let local = refs.value?.localBranches.first { $0.name == head }?.commit
                let tip = refs.value?.remoteBranches.first { $0.name == "\(remote)/\(head)" }?.commit
                if let local, local != tip {
                    let backend = try await self.backend()
                    let env = try await backend.readEnvironment(cwd: url)
                    guard let tip, try await backend.runner.run(
                        ["merge-base", "--is-ancestor", local, tip], cwd: url, env: env, allowedExitCodes: [0, 1]
                    ).exitCode == 0 else {
                        refuse(("diverged", "The local branch \(head) has commits that are not on \(remote)/\(head): "
                            + "pull and push it (or reset it) first, then resolve again."))
                        return
                    }
                    write = .fastForward(head, to: "refs/remotes/\(remote)/\(head)")
                    try await perform(write)
                }
                write = local != nil
                    ? .checkoutBranch(head) : .checkoutTracking(remoteBranch: "\(remote)/\(head)", as: head)
                try await perform(write)
                if let refusal = refusal() {
                    refuse(refusal)
                    return
                }
                write = .merge("\(remote)/\(base)", checkoutFirst: nil, mode: nil)
                try await perform(write)
                UITiming.content("\(timing) clean")
                postToast(.success(title, detail: "Merged \(base) into \(head) with no conflicts. "
                    + "Push to update the pull request."))
            } catch {
                // `perform` reread the status before it threw: the conflicted paths are the merge's.
                let conflicted = status.value?.conflicted ?? []
                if case GitError.conflict = error, case .merge = write, let first = conflicted.first {
                    UITiming.content("\(timing) stopped \(conflicted.count)")
                    let count = conflicted.count == 1 ? "1 conflict" : "\(conflicted.count) conflicts"
                    postToast(.warning("\(title) stopped on conflicts", detail: "\(count) — resolve them, commit, "
                        + "then push to update the pull request."))
                    // Suggest All needs both sides as text: with AI, the first path both sides still have (UU or
                    // AA, never a modify/delete; a binary one only shows once loaded), else the first: its load then
                    // says AI has nothing to suggest.
                    let opened = withAI
                        ? conflicted.first { $0.index == $0.worktree && $0.index != .deleted } ?? first : first
                    pendingAIBatchPath = withAI ? opened.path : nil
                    selectConflict(opened.path)
                    return
                }
                UITiming.content("\(timing) failed")
                if !(error is CancellationError) {
                    let message = Self.message(for: error)
                    report(OperationFailure(title: title, write: write, error: error, message: message))
                }
            }
        }
    }

    /// Keeps `failure` as the last failure and shows it in its toast, the only place it is reported: its hint, the
    /// hint's action and git's whole message (the toast's copy button).
    func report(_ failure: OperationFailure) {
        self.failure = failure
        let hint = FailureHints.hint(for: failure)
        let action = hint.action.map { action in
            OperationToast.Action(title: action.title) { [weak self] in
                guard let self else { return }
                FailureHints.perform(action, for: failure, in: self)
            }
        }
        postToast(.failure(failure.title, error: failure.error, message: failure.message, hint: hint.text,
                           action: action))
    }

    /// Whether the action bar's `key` operation is running.
    func isRunning(_ key: ActionBarAction) -> Bool {
        running.contains { $0.key == key }
    }

    /// Asks for a confirmation before `write` (a destructive operation); `OperationDialogs` shows it, naming the
    /// target, and runs the write on confirm. `secondary`: a second button and its write; `asksAlways`: the auto-stash
    /// dialog's "Always do this" (`OperationConfirmation.asksAlways`).
    func confirm(_ title: String, message: String, button: String, write: Write, operation: String,
                 key: ActionBarAction? = nil, isDestructive: Bool = true,
                 secondary: (button: String, write: Write)? = nil, asksAlways: Bool = false)
    {
        confirmation = OperationConfirmation(
            title: title, message: message, button: button, write: write, operation: operation, key: key,
            isDestructive: isDestructive, secondary: secondary, asksAlways: asksAlways)
    }

    /// The checked-out branch; nil on a detached HEAD or before the refs are read.
    var currentBranch: String? {
        switch refs.value?.head {
        case .branch(let name, _), .unborn(let name): name
        case .detached, nil: nil
        }
    }

    enum NameKind: Sendable { case branch, tag, remote }

    /// Checks a new branch, tag or remote name as the operation will (no leading `-`, `git check-ref-format`), off the
    /// main actor with the read environment. Nil when valid, else the reason.
    func validate(_ kind: NameKind, _ name: String) async -> String? {
        guard let backend = try? await backend() else { return nil }
        return await Self.validate(kind, name, backend: backend, cwd: url)
    }

    @concurrent
    private nonisolated static func validate(_ kind: NameKind, _ name: String, backend: Backend, cwd: URL) async
        -> String?
    {
        guard let env = try? await backend.readEnvironment(cwd: cwd) else { return nil }
        let ops = GitOperations(runner: backend.runner, cwd: cwd, env: env)
        do {
            switch kind {
            case .branch: try await ops.validateBranchName(name)
            case .tag: try await ops.validateTagName(name)
            case .remote: try await ops.validateRemoteName(name)
            }
            return nil
        } catch {
            return message(for: error)
        }
    }

    // MARK: Host keys

    /// Opens the host-key sheet at once (scanning), then scans the host of `failure` (named by ssh, else the remote's
    /// URL) with `HostKeyTrust`, which writes nothing. A changed key is never scanned for trust: the sheet only warns.
    func checkHostKey(for failure: OperationFailure) {
        guard let error = failure.error as? GitError else { return }
        let isChanged = HostKeyTrust.isKeyChanged(error)
        guard let host = HostKeyTrust.host(from: error) ?? remoteHost(for: failure.write) else {
            hostKeyCheck = HostKeyCheck(
                host: nil, isChanged: isChanged, state: .failed("Histq could not tell which host this is."),
                failure: failure)
            return
        }
        hostKeyCheck = HostKeyCheck(host: host, isChanged: isChanged, state: isChanged ? .changed : .scanning,
                                    failure: failure)
        guard !isChanged else { return }
        Task { [weak self] in
            let state: HostKeyCheck.State
            do {
                state = .scanned(try await Self.scan(host))
            } catch {
                state = .failed(Self.message(for: error))
            }
            guard let self, hostKeyCheck?.host == host else { return }
            hostKeyCheck?.state = state
        }
    }

    /// Appends the scanned keys to `~/.ssh/known_hosts` (only here, on the user's "Trust Host"), closes the sheet and
    /// runs the failed operation again.
    func trustHost(_ scan: HostKeyTrust.Scan) {
        guard let check = hostKeyCheck, !check.isChanged else { return }
        hostKeyCheck?.state = .trusting(scan)
        Task { [weak self] in
            do {
                try await Self.trust(scan)
                guard let self else { return }
                hostKeyCheck = nil
                run(check.failure.write, title: check.failure.title)
            } catch {
                self?.hostKeyCheck?.state = .failed(Self.message(for: error))
            }
        }
    }

    /// The ssh host of the remote `write` talks to: its own remote, else the current branch's upstream's, else the first
    /// remote with an ssh URL.
    private func remoteHost(for write: Write) -> HostKeyTrust.Host? {
        let upstreamRemote = refs.value.flatMap { refs -> String? in
            guard let upstream = refs.localBranches.first(where: \.isHead)?.upstream else { return nil }
            return refs.remoteBranches.first { $0.name == upstream }?.remote
        }
        for name in [write.remote, upstreamRemote].compactMap({ $0 }) {
            if let url = remotes.first(where: { $0.name == name })?.url,
               let host = HostKeyTrust.host(fromRemoteURL: url)
            {
                return host
            }
        }
        return remotes.lazy.compactMap { HostKeyTrust.host(fromRemoteURL: $0.url) }.first
    }

    @concurrent
    private nonisolated static func scan(_ host: HostKeyTrust.Host) async throws -> HostKeyTrust.Scan {
        try await HostKeyTrust(environment: await GitToolchain.writeBase()).scan(host)
    }

    @concurrent
    private nonisolated static func trust(_ scan: HostKeyTrust.Scan) async throws {
        try HostKeyTrust(environment: await GitToolchain.writeBase()).trust(scan)
    }

    /// A short message for a failed write, shown in the card that started it.
    static func writeMessage(for error: Error) -> String {
        message(for: error)
    }

    // MARK: Setup

    /// The runner and the repo's folders, set up on first use; starts the watcher once the folders are known.
    func backend() async throws -> Backend {
        if setUpTask == nil {
            let cwd = url
            let watcher = watcher
            let onChange: @MainActor @Sendable (RefreshScope) -> Void = { [weak self] scope in
                self?.refresh(scope: scope)
            }
            setUpTask = Task.detached(priority: .userInitiated) {
                let toolchain = try await GitToolchain.resolve()
                let runner = GitRunner(executable: toolchain.executable.url)
                let env = try await GitInvocation.readEnvironment(
                    profile: nil, base: toolchain.readBase, runner: runner, cwd: cwd)
                let directories = try await RepoDirectories.resolve(runner: runner, cwd: cwd, env: env)
                watcher.start(directories, onChange: onChange)
                let key = RepoSession.stateKey(cwd)
                return Backend(
                    runner: runner, base: toolchain.readBase, directories: directories,
                    journal: UndoJournal(file: StatePaths.directory("undo").appending(
                        path: "\(key).json", directoryHint: .notDirectory)),
                    rebaseFolder: StatePaths.root.appending(path: "rebase/\(key)", directoryHint: .isDirectory),
                    view: RepoViewState.load(key: key))
            }
        }
        guard let setUpTask else { throw CancellationError() }
        // Not cancelled with the caller: another select still needs it.
        do {
            let backend = try await setUpTask.value
            if !viewLoaded {
                viewLoaded = true
                view = backend.view
                migrateHiddenRefs()
                updateVisibility()
            }
            return backend
        } catch {
            // A failed setup (no git, not a repo) is retried by the next load.
            if !Self.isCancellation(error), self.setUpTask == setUpTask { self.setUpTask = nil }
            throw error
        }
    }

    /// A file name for the worktree's state: the SHA-256 of its real path (`ProfileStore.repoKey`), so each worktree
    /// of a repo has its own journal and no path character reaches a file name.
    nonisolated static func stateKey(_ cwd: URL) -> String {
        SHA256.hash(data: Data(ProfileStore.repoKey(cwd).utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Errors

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || Task.isCancelled
    }

    /// A short message for the detail's failed state.
    nonisolated static func message(for error: Error) -> String {
        switch error {
        case GitError.other(_, let stderrTail) where stderrTail.contains("not a git repository"):
            "This folder is not a git repository."
        case let error as GitError:
            error.stderrTail.isEmpty ? "git failed." : error.stderrTail
        case DiffReadError.missingObjects:
            "This file's contents are not downloaded yet (a partial clone): fetch to see them."
        case ConflictSourceError.notConflicted:
            "This file has no conflict left."
        case let error as UndoError:
            error.message
        case let error as RebaseTodoError:
            error.message
        case let error as PatchFile.InputError:
            error.message
        case let error as GitOperationError:
            switch error {
            case .invalidBranchName(let name): "\"\(name)\" is not a valid branch name."
            case .invalidTagName(let name): "\"\(name)\" is not a valid tag name."
            case .invalidRemoteName(let name): "\"\(name)\" is not a valid remote name."
            case .invalidRemoteURL: "That is not a valid remote URL."
            case .invalidObjectID(let text): "\(text) is not a commit id."
            case .noPaths: "No files were given."
            case .invalidRefspec(let refspec): "\"\(refspec)\" is not a ref and a new branch name."
            case .stashNotFound: "That stash no longer exists."
            case .invalidMainline(let parent): "A merge has no parent \(parent)."
            case .noOperationInProgress: "No merge, rebase, cherry-pick, revert or patch apply is in progress."
            case .unsupported(let what): "Not supported: \(what)."
            case .invalidWorktreePath(let path):
                "\(path) cannot be a new worktree: its parent folder must exist and it must not."
            case .notAWorktree(let path): "\(path) is not a worktree of this repository."
            case .mainWorktree: "The main worktree cannot be removed."
            case .currentWorktree: "This tab's own worktree cannot be removed from here."
            }
        case let error as SubmoduleOperationError:
            switch error {
            case .invalidURL(let url): "\"\(url)\" is not a submodule URL Histq accepts (https, ssh or a relative path)."
            case .invalidPath(let path): "\"\(path)\" is not a valid submodule folder."
            case .invalidName(let name): "The submodule name \"\(name)\" is not safe to use."
            case .notASubmodule(let path): "\(path) is not a submodule of this repository."
            }
        case let error as SubmoduleUpdateFailure:
            // Each failed submodule with git's words, then those left alone for their configured update mode.
            (error.failures.map { "\($0.path): \($0.message.trimmingCharacters(in: .whitespacesAndNewlines))" }
                + (error.skipped.isEmpty ? [] : [
                    "Skipped for their update mode: "
                        + error.skipped.map { "\($0.path) (\($0.mode))" }.joined(separator: ", ") + ".",
                ])).joined(separator: "\n")
        case GitInvocation.BackgroundFetchError.repoSetsNetworkConfig(let keys):
            "The repo sets its own http or proxy config (\(keys.joined(separator: ", "))); "
                + "auto-fetch skipped, fetch manually."
        case let error as NetworkTokenWithheld:
            // Git's own words; the banner's hint says why the token was not sent.
            error.error.stderrTail.isEmpty ? "git failed." : error.error.stderrTail
        case let error as HostKeyTrust.TrustError:
            switch error {
            case .invalidHost(let host): "\(host) is not a host name Histq can check."
            case .invalidPort(let port): "\(port) is not a valid port."
            case .noKeys(let host): "\(host) sent no SSH host key."
            case .toolNotFound(let tool): "\(tool) was not found."
            case .fingerprintFailed(let detail): "The key could not be fingerprinted: \(detail)"
            }
        case let error as GitExecutableError:
            switch error {
            case .commandLineToolsMissing: "Git needs the Command Line Tools."
            case .notFound: "Git was not found."
            case .notExecutable(let path): "Git at \(path) cannot run."
            case .tooOld(let version): "Git \(version) is too old; Histq needs \(GitExecutable.minimumVersion)."
            case .unrecognizedVersion: "Git did not report its version."
            }
        default:
            error.localizedDescription
        }
    }
}
