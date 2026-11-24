// A pull request in panel2, laid out like GitHub's page, each part in its own card: the header (back, title, number,
// state pill, "author wants to merge N commits into base from head", the tabs), then the selected tab: Conversation
// (the description, comments and reviews in one `HostedHTMLView`, the comment and review box, and a side column with
// the actions, reviewers, assignees and labels), Commits, Files changed (the file list and the selected file's patch in
// a read-only `DiffLineTable`, parsed from GitHub's `patch` with git's diff parser, so no local git is needed) and
// Checks. The row click shows the header and skeleton cards in the same frame (`PlaceholderCard`); everything loads
// off the main actor (`PullRequestDetailModel`): the Conversation's parts first, then commits, files and checks as each
// arrives. The actions call GitHub through the tab's `HostingStore`
// client; Merge and Close/Reopen ask first; Checkout locally is a repo write (`RepoSession.Write.checkoutPullRequest`).
import AppKit
import HistqCore
import SwiftUI

// MARK: - Model

/// The detail's tabs.
enum PRTab: String, CaseIterable, Hashable, Sendable {
    case conversation, commits, files, checks

    var title: String {
        switch self {
        case .conversation: "Conversation"
        case .commits: "Commits"
        case .files: "Files changed"
        case .checks: "Checks"
        }
    }

    var systemImage: String {
        switch self {
        case .conversation: "text.bubble"
        case .commits: "point.3.connected.trianglepath.dotted"
        case .files: "doc.on.doc"
        case .checks: "checkmark.seal"
        }
    }
}

/// A changed file of the pull request, with its rows built off the main actor; no section when GitHub sent no patch
/// (a binary file, or a diff too large for the API).
struct PRFile: Identifiable, Sendable {
    let file: HostedPullRequestFile
    let change: FileChange
    let section: DiffSection?
    /// The review threads on this file (joined by path, `PullRequestDetailModel.joined`), oldest first; Files
    /// changed draws those with a line in the current diff under it.
    var threads: [HostedReviewThread] = []

    var id: String { file.filename }
}

/// A reviewer and where their review stands: requested (no review yet), or their latest review's state.
struct PRReviewer: Identifiable, Sendable {
    let login: String
    /// The account's user id, for its avatar.
    let userID: Int?
    /// The API's avatar URL of the account (`HostAvatars.gitlab` loads it).
    let avatarURL: String?
    /// nil while the review is only requested.
    let state: String?

    var id: String { login }
}

/// The pull request's review threads, grouped by `HostedReviewThread.group`: their comments come from REST and only
/// whether each is resolved from GraphQL, so a GraphQL failure, or states that join no thread, leave the threads
/// without a state and say why.
struct PRThreads: Sendable {
    /// The threads of each review (its id), each review's oldest root first.
    let byReview: [Int: [HostedReviewThread]]
    /// The reviews that only hold replies to other reviews' threads: GitHub hides them from the timeline.
    let replyOnlyReviewIDs: Set<Int>
    /// The threads whose root has no review, shown in the timeline at their first comment's time.
    let unattached: [HostedReviewThread]
    /// Why resolving is unavailable: the GraphQL load failed, or its states joined none of the threads. nil when
    /// the states loaded and joined, even only some of the threads, or when there are no threads.
    let resolveUnavailable: String?
    /// The GraphQL load failed, which `resolveUnavailable` alone does not tell from states that joined nothing.
    let statesFailed: Bool

    /// Every thread in one stable order: by review id, each review's own order, then the unattached ones.
    var all: [HostedReviewThread] {
        byReview.keys.sorted().flatMap { byReview[$0] ?? [] } + unattached
    }
}

/// Everything the detail shows, read in one load. Commits, files, checks and threads may fail on their own (a token
/// without the checks permission still reads the pull request): their tab or part then says why. Commits, files and
/// checks are `.loading` until they fill in, after the Conversation's parts.
struct PullRequestDetail: Sendable {
    let loadID: Int
    /// The load's "now" (`PRPageDates.loadNow()`): every date of this load, its rebuilds and patches included, is
    /// relative to it.
    let now: Date
    /// The account kind's page layout (`PRPageLayout.for`).
    let layout: PRPageLayout
    /// Replaced alone by the model's re-poll while GitHub still computes whether the branch merges.
    var pull: HostedPullRequest
    var timelineCount: Int
    /// The Conversation's page: the description, then comments and reviews by date, each review with its threads
    /// (`PRTimeline.page`). Rebuilt with `comments` by a general thread action, before its write (optimistic).
    var timeline: PRTimelineHTML
    /// The page's general comments and reviews, as loaded (or as an optimistic action patched them).
    var comments: [HostedComment]
    let reviews: [HostedReview]
    /// The token's user, where the host has general replies or revokes approvals (the author of an optimistic reply);
    /// nil when unknown.
    let viewer: HostedUser?
    let reviewers: [PRReviewer]
    var commits: Loadable<[HostedCommit]>
    /// Each with its threads, joined again whenever `threads` changes.
    var files: Loadable<[PRFile]>
    var checks: Loadable<[HostedCheckRun]>
    /// As loaded, or as an optimistic edit or delete of a review comment patched them.
    var threads: Loadable<PRThreads>
    /// The token's user's latest review is an approval, on a provider that can revoke it (`unapprove`): the Review
    /// box offers Revoke Approval.
    let viewerApproved: Bool
    /// The award bar's kinds, in the host's picker order (its first two always shown), with `pull.reactions` the
    /// pull request's own reactions; empty (no bar) when the layout has no bar, the provider no `itemReactions`, or
    /// their read failed.
    let reactionKinds: [String]
    /// The approval box's data, the project's merge rules and who may be asked to review, read only where the layout
    /// has the approval and merge boxes (`PRPageLayout.mergeBoxes`); nil (or empty) otherwise or when their read
    /// failed, which only leaves out what they say.
    var approvals: HostedApprovals? = nil
    var repositoryInfo: HostedRepositoryInfo? = nil
    var reviewerCandidates: [HostedUser] = []
    /// The project's labels, the sidebar's Labels Edit menu (`PRPageLayout.sidebar`); empty otherwise or when their
    /// read failed (no menu).
    var labelChoices: [HostedLabel] = []
    /// The Activity's history entries (`PRPageLayout.activity`): nil without an Activity, or when their read failed
    /// (the page then shows the comments alone).
    var events: [HostedTimelineEvent]? = nil
    /// The commenters' member roles by user id (`PRPageLayout.roleBadges`): nil without badges; empty when their read
    /// failed (only "Author" shows).
    var memberRoles: [Int: String]? = nil
    /// Whether a merged pull request's head branch still exists, for the merged box's Delete branch / Restore branch
    /// (`PRPageLayout.githubMergeBox`): nil when it was not read (not merged, a fork's branch, no push permission, no
    /// `deleteHeadBranch`) or the read failed, which shows neither.
    var headBranchExists: Bool? = nil
    /// The sidebar's Projects and Development (`PRPageLayout.githubSidebar`, the provider's `pullRequestExtras`); nil
    /// otherwise or when their read failed (no such cards).
    var extras: HostedPullRequestExtras? = nil
    /// Bitbucket's Tasks and Merge checks cards (`PRPageLayout.bitbucketSidebar`, the provider's `tasks` and
    /// `mergeChecks`); nil otherwise or when their read failed (no card).
    var tasks: [HostedTask]? = nil
    var mergeChecks: [HostedMergeCheck]? = nil
    /// Bitbucket's Reports card (the head's Code Insights reports, the provider's `reports`): loading until read,
    /// idle where the layout or host has none (no card).
    var reports: Loadable<[HostedReport]> = .idle

    var isMerged: Bool { pull.mergedAt != nil || pull.merged == true }
    var isOpen: Bool { pull.state == "open" }
}

/// A GitHub action of the detail.
enum PullRequestAction: Equatable, Sendable {
    /// `sha`: the head the user saw when confirming; GitHub refuses the merge once the head moved. `options`: the
    /// merge box's choices where the provider takes them (GitLab's delete-source-branch); empty elsewhere.
    case merge(HostedMergeMethod, sha: String, options: HostedMergeOptions = HostedMergeOptions())
    case review(HostedReviewEvent, body: String)
    case comment(String)
    /// A new resolvable general thread (GitLab's "Start thread" of the bottom composer).
    case startThread(String)
    case setOpen(Bool)
    /// `rootID`: the thread's root comment, the only one GitHub takes a reply to.
    case reply(rootID: Int, body: String)
    /// `thread`: the thread's state, whose GraphQL node id resolving takes.
    case resolve(thread: HostedReviewThreadState, resolved: Bool)
    /// Revokes the token's user's approval (GitLab).
    case unapprove
    /// A reply to or a resolve of a general thread, or an edit or delete of an own comment (`PRGeneralAction`), shown
    /// before the host answers (optimistic).
    case general(PRGeneralAction)
    /// A new inline comment from Files changed, shown under its line and in the Conversation before the host answers
    /// (optimistic).
    case newInline(PRNewInline)
    /// The viewer's reaction `kind` added to (`add`) or removed from the pull request itself, from the award bar,
    /// shown before the host answers (optimistic).
    case itemReaction(kind: String, add: Bool)
    /// Rebases the source branch onto the target on the host, while its head is still `sha` (GitLab's merge box); the
    /// host's answer comes only once the rebase finished.
    case rebase(sha: String)
    /// Asks `users` to review (the approval box's Assign reviewers, the sidebar's Reviewers).
    case requestReviewers([HostedUser])
    /// Assigns `users` (the sidebar's Assignees: Edit, "assign yourself"); adds only.
    case addAssignees([HostedUser])
    /// Adds the labels named (the sidebar's Labels: Edit); adds only.
    case addLabels([String])
    /// Merges the base into the out-of-date head on the host, while the head is still `sha` (GitHub's Update branch).
    case updateBranch(sha: String)
    /// Deletes the merged pull request's head branch on the host (GitHub's merged box), shown gone at once.
    case deleteBranch(String)
    /// Makes the deleted head branch again at `sha` (Restore branch), shown back at once.
    case restoreBranch(String, sha: String)
    /// Adds a task with this text (Bitbucket's Tasks card), shown at once.
    case createTask(String)
    /// Marks task `id` done or not, shown at once.
    case setTask(id: Int, resolved: Bool)
    /// Deletes task `id`, shown gone at once.
    case deleteTask(id: Int)

    var progressTitle: String {
        switch self {
        case .merge: "Merging…"
        case .review: "Submitting the review…"
        case .comment: "Commenting…"
        case .startThread: "Starting the thread…"
        case .setOpen(let open): open ? "Reopening…" : "Closing…"
        case .reply: "Replying…"
        case .resolve(_, let resolved): resolved ? "Resolving…" : "Unresolving…"
        case .unapprove: "Revoking the approval…"
        case .general(let action): action.progressTitle
        case .newInline: "Commenting…"
        case .itemReaction(_, let add): add ? "Adding the reaction…" : "Removing the reaction…"
        case .rebase: "Rebasing the source branch…"
        case .requestReviewers: "Assigning the reviewer…"
        case .addAssignees: "Assigning…"
        case .addLabels: "Adding the label…"
        case .updateBranch: "Updating the branch…"
        case .deleteBranch: "Deleting the branch…"
        case .restoreBranch: "Restoring the branch…"
        case .createTask: "Adding the task…"
        case .setTask(_, let resolved): resolved ? "Resolving the task…" : "Reopening the task…"
        case .deleteTask: "Deleting the task…"
        }
    }

    var failureTitle: String {
        switch self {
        case .merge: "Merge failed"
        case .review: "The review was not submitted"
        case .comment: "The comment was not posted"
        case .startThread: "The thread was not started"
        case .setOpen(let open): open ? "Reopen failed" : "Close failed"
        case .reply: "The reply was not posted"
        case .resolve(_, let resolved): resolved ? "Resolve failed" : "Unresolve failed"
        case .unapprove: "The approval was not revoked"
        case .general(let action): action.failureTitle
        case .newInline: "The comment was not posted"
        case .itemReaction(_, let add): add ? "The reaction was not added" : "The reaction was not removed"
        case .rebase: "Rebase failed"
        case .requestReviewers: "The reviewer was not assigned"
        case .addAssignees: "The assignee was not added"
        case .addLabels: "The label was not added"
        case .updateBranch: "The branch was not updated"
        case .deleteBranch: "The branch was not deleted"
        case .restoreBranch: "The branch was not restored"
        case .createTask: "The task was not added"
        case .setTask(_, let resolved): resolved ? "The task was not resolved" : "The task was not reopened"
        case .deleteTask: "The task was not deleted"
        }
    }

    /// The failure's title when another pull request shows by the time it returns: it names `number` (`#12`, `!12`).
    func failureTitle(of number: String) -> String {
        switch self {
        case .merge: "Merge of \(number) failed"
        case .review: "The review of \(number) was not submitted"
        case .comment: "The comment on \(number) was not posted"
        case .startThread: "The thread on \(number) was not started"
        case .setOpen(let open): open ? "Reopen of \(number) failed" : "Close of \(number) failed"
        case .reply: "The reply on \(number) was not posted"
        case .resolve(_, let resolved): resolved ? "Resolve on \(number) failed" : "Unresolve on \(number) failed"
        case .unapprove: "The approval of \(number) was not revoked"
        case .general(let action): action.failureTitle(of: number)
        case .newInline: "The comment on \(number) was not posted"
        case .itemReaction(_, let add): add ? "The reaction on \(number) was not added"
            : "The reaction on \(number) was not removed"
        case .rebase: "Rebase of \(number) failed"
        case .requestReviewers: "The reviewer of \(number) was not assigned"
        case .addAssignees: "The assignee of \(number) was not added"
        case .addLabels: "The label of \(number) was not added"
        case .updateBranch: "The branch of \(number) was not updated"
        case .deleteBranch: "The branch of \(number) was not deleted"
        case .restoreBranch: "The branch of \(number) was not restored"
        case .createTask: "The task on \(number) was not added"
        case .setTask(_, let resolved): resolved ? "The task on \(number) was not resolved"
            : "The task on \(number) was not reopened"
        case .deleteTask: "The task on \(number) was not deleted"
        }
    }

    /// The timing log's word (`content pr 1 action merge ok`).
    var timingName: String {
        switch self {
        case .merge(let method, _, _): "merge-\(method.rawValue)"
        case .review(let event, _): "review-\(event.rawValue.lowercased())"
        case .comment: "comment"
        case .startThread: "start-thread"
        case .setOpen(let open): open ? "reopen" : "close"
        case .reply: "reply"
        case .resolve(_, let resolved): resolved ? "resolve" : "unresolve"
        case .unapprove: "unapprove"
        case .general(let action): action.timingName
        case .newInline: "new-inline-post"
        case .itemReaction: "mr-react"
        case .rebase: "rebase"
        case .requestReviewers: "assign-reviewer"
        case .addAssignees: "assign"
        case .addLabels: "add-label"
        case .updateBranch: "update-branch"
        case .deleteBranch: "delete-branch"
        case .restoreBranch: "restore-branch"
        case .createTask: "task"
        case .setTask(_, let resolved): resolved ? "task-resolve" : "task-reopen"
        case .deleteTask: "task-delete"
        }
    }
}

/// A new inline comment: the file (its `PRFile.id`) and the box it was written in (put back with its text when the
/// write fails), the position the host gets (`position`), and the text.
struct PRNewInline: Equatable, Sendable {
    let path: String
    let composer: DiffInlineComposer
    let position: HostedInlinePosition
    let body: String

    /// The comment written in `composer` on `file` of a patch loaded at `headSHA`: the last line's numbers by its
    /// kind (an added line its new number, a removed line its old one, a context line both), the first line's the
    /// same way for a range, and the old path of a renamed file.
    init(_ composer: DiffInlineComposer, on file: HostedPullRequestFile, headSHA: String, body: String) {
        func numbers(_ line: DiffInlineLine) -> (old: Int?, new: Int?) {
            switch line.kind {
            case .added: (nil, line.newLine)
            case .removed: (line.oldLine, nil)
            case .context: (line.oldLine, line.newLine)
            }
        }
        let end = numbers(composer.end)
        let start = composer.start.map(numbers)
        path = file.filename
        self.composer = composer
        position = HostedInlinePosition(
            path: file.filename, oldPath: file.previousFilename, oldLine: end.old, newLine: end.new,
            lineKind: composer.end.kind, startOldLine: start?.old, startNewLine: start?.new, headSHA: headSHA)
        self.body = body
    }

    /// Why `kind`'s client refuses a range from `start` to `end` unsent (the same rule): Bitbucket takes a range on
    /// one side only (its first line needs a number on the last line's side); GitHub and GitLab take any. nil when
    /// the host takes it.
    static func rangeRefusal(_ kind: HostingKind, start: DiffInlineLine, end: DiffInlineLine) -> String? {
        guard kind == .bitbucketCloud else { return nil }
        let newSide = end.kind != .removed
        guard (newSide ? start.newLine : start.oldLine) == nil else { return nil }
        let lines = newSide ? "an added or unchanged" : "a removed or unchanged"
        return "Bitbucket ranges stay on one side: start on \(lines) line."
    }

    /// The thread the comment makes, for the optimistic page: by `viewer` (else "you"), now, under its last line on its
    /// side, id `id` (`PullRequestDetailModel.optimisticID`); nil when the comment cannot be read back.
    func thread(id: Int, viewer: HostedUser?) -> HostedReviewThread? {
        let removed = position.lineKind == .removed
        // Only `id` and `path` are required: the rest is set below (the model's init is the core's own).
        guard let data = try? JSONSerialization.data(withJSONObject: ["id": id, "path": position.path]),
              var comment = try? JSONDecoder().decode(HostedReviewComment.self, from: data)
        else { return nil }
        comment.line = removed ? position.oldLine : position.newLine
        comment.originalLine = comment.line
        // The first line's number on the last line's side, else (a removed line before an added one) its other side.
        comment.startLine = removed ? position.startOldLine ?? position.startNewLine
            : position.startNewLine ?? position.startOldLine
        comment.originalStartLine = comment.startLine
        comment.side = removed ? "LEFT" : "RIGHT"
        comment.body = body
        comment.user = viewer ?? HostedUser(id: 0, login: "you")
        comment.createdAt = .now
        return HostedReviewThread.group([comment], states: []).unattached.first
    }
}

/// The open new inline comment box of Files changed: its file (`PRFile.id`) and where it is.
struct PRInlineComposer: Equatable {
    let path: String
    var composer: DiffInlineComposer
}

extension HostedMergeMethod {
    /// Every method, the hosts' common three first; a client lists only its own (`GitHubStore.mergeMethods`), and a
    /// pull request may list Bitbucket's (`HostedPullRequest.allowedMergeMethods`).
    static let all: [HostedMergeMethod] = [
        .merge, .squash, .rebase, .fastForward, .squashFastForward, .rebaseFastForward, .fastForwardIfPossible,
    ]

    var title: String {
        switch self {
        case .merge: "Merge commit"
        case .squash: "Squash"
        case .rebase: "Rebase"
        case .fastForward: "Fast forward"
        case .squashFastForward: "Squash, fast-forward only"
        case .rebaseFastForward: "Rebase, fast-forward"
        case .fastForwardIfPossible: "Fast-forward if possible"
        }
    }

    /// The title on `kind`'s merge area: Bitbucket's rebase is "Rebase, merge"; Data Center's own names for its
    /// `ff-only`, `rebase-no-ff` and `rebase-ff-only`; Azure DevOps's for its `noFastForward`, `squash` and `rebase`.
    func title(on kind: HostingKind) -> String {
        switch (kind, self) {
        case (.azureDevOps, .merge): "Merge (no fast forward)"
        case (.azureDevOps, .squash): "Squash commit"
        case (.azureDevOps, .rebase): "Rebase and fast-forward"
        case (.bitbucketCloud, .rebase): "Rebase, merge"
        case (.bitbucketDataCenter, .fastForward): "Fast-forward only"
        case (.bitbucketDataCenter, .rebase): "Rebase and merge"
        case (.bitbucketDataCenter, .rebaseFastForward): "Rebase and fast-forward"
        default: title
        }
    }

    var buttonTitle: String {
        switch self {
        case .merge, .fastForward, .squashFastForward, .rebaseFastForward, .fastForwardIfPossible: "Merge"
        case .squash: "Squash and Merge"
        case .rebase: "Rebase and Merge"
        }
    }
}

extension HostedReviewEvent {
    static let all: [HostedReviewEvent] = [.approve, .requestChanges, .comment]

    var title: String {
        switch self {
        case .approve: "Approve"
        case .requestChanges: "Request changes"
        case .comment: "Comment"
        }
    }
}

/// The open pull request of a repo tab: its load, the selected tab and file, the comment box and the running action.
/// `RepoSession.selectHosted` starts a load in the click's call (`state` is `.loading` when it returns); a newer
/// select or `close` drops an older load's answer.
@Observable
@MainActor
final class PullRequestDetailModel {
    enum Composer: String, CaseIterable, Hashable {
        case comment, review

        var title: String {
            switch self {
            case .comment: "Comment"
            case .review: "Review"
            }
        }
    }

    private(set) var number: Int?
    private(set) var state: Loadable<PullRequestDetail> = .idle {
        didSet { if let detail = state.value, let repository { remember(detail, of: repository) } }
    }
    var tab: PRTab = .conversation
    /// The Files changed tab's file (its `filename`).
    var selectedFile: String?
    var composer: Composer = .comment
    var draft = ""
    /// The Comment box posts a new thread instead of a plain comment (GitLab's "Start thread"), where the layout and
    /// the provider offer it.
    var startsThread = false
    /// The Activity's filter and sort (`PRPageLayout.activity`): the filter is the detail's, the sort the app's
    /// (`PRActivityView.newestFirstKey`, read again by each load).
    private(set) var activityView = PRActivityView()
    /// A reload asked from the header's button (`reload`) is running: its icon spins until the detail is in.
    private(set) var reloading = false
    var reviewEvent: HostedReviewEvent = .approve
    /// The merge method the user picked last, kept across pull requests where the client's methods apply
    /// (`shownMergeMethod`); nil: a merge commit.
    var mergeMethod: HostedMergeMethod?
    /// The method picked for this pull request where it has its own list (Bitbucket's), reset for each one; nil: its
    /// default.
    var ownMergeMethod: HostedMergeMethod?
    /// Bitbucket's Close source branch as the user set it for this pull request; nil: the pull request's own.
    var closeSourceBranchChoice: Bool?
    /// The Tasks card's new task as typed: cleared when it is sent, put back when the write fails.
    var taskDraft = ""
    /// GitLab's merge box (`PRPageLayout.mergeBoxes`): its details shown (open at first), and the user's squash and
    /// delete-source-branch choices, nil until they click one (the merge request's own setting then).
    var mergeDetailsExpanded = true
    var squashChoice: Bool?
    var deleteSourceBranchChoice: Bool?
    /// Each review thread's reply box, by the thread's root comment id. Kept across a reload, so a reply typed while
    /// another action reloads the detail stays.
    var replyDrafts: [Int: String] = [:]
    /// The threads the user expanded (true) or collapsed (false) against their default, by root comment id; a thread
    /// the user resolves is collapsed here too.
    var threadExpanded: [Int: Bool] = [:]
    /// The same for general threads (`PRGeneralThreadModel`), by root comment id: an id space apart from the review
    /// threads'.
    var generalReplyDrafts: [Int: String] = [:]
    var generalExpanded: [Int: Bool] = [:]
    /// The comments being edited in place and their editors' text, by `PRCommentTarget.key` (`PRGeneralThreadModel`).
    var editingComments: Set<String> = []
    var commentEditDrafts: [String: String] = [:]
    /// The open new inline comment box (one at a time) and its text. The text is not observed: the box reads it when
    /// it shows and writes it as it is typed, so typing never redraws the detail.
    var inlineComposer: PRInlineComposer?
    @ObservationIgnored var inlineDraft = ""
    #if DEBUG
    var launchDelete: (target: PRCommentTarget, confirm: Bool)?
    #endif
    /// The actions running on GitHub, by pull request: one at a time for each. An action belongs to the pull request it
    /// started on, not to the detail, which may show another one by the time it returns.
    private(set) var busy: [Int: PullRequestAction] = [:]
    /// The last action's failure (or a failed reload after it), above the tabs until dismissed or the next action.
    var actionError: String?

    /// The shown pull request's running action.
    var running: PullRequestAction? { number.flatMap { busy[$0] } }

    /// Shows an action in the tab's footer until the returned closure is called (`RepoSession.beginOperation`). Set by
    /// the session.
    @ObservationIgnored var beginOperation: @MainActor (String) -> @MainActor () -> Void = { _ in {} }
    /// Azure DevOps's files with their patches, from a local diff of the pull request's branches fetched from the
    /// remote named (`RepoSession.pullRequestFiles`). Set by the session.
    @ObservationIgnored var localFiles: @MainActor @Sendable (HostedPullRequest, String) async
        -> Loadable<[HostedPullRequestFile]> = { _, _ in .idle }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadCount = 0
    /// The repository of the load that is shown or on its way, for `cache`.
    @ObservationIgnored private var repository: HostedRepository?
    /// The last 8 loaded details, newest last, one per pull request, so a revisit shows at once while it loads
    /// again. Memory only, for this session: third-party content, never written to disk.
    @ObservationIgnored private var cache: [(repository: HostedRepository, detail: PullRequestDetail)] = []
    /// The ids of optimistic replies and new inline threads (`PRPlaceholderID`: no menu, reactions or reply row on
    /// them until the reload brings the host's).
    @ObservationIgnored private var optimisticID = PRPlaceholderID.base

    /// DEBUG `-HistqPRTab commits|files|checks`: the tab a pull request opens on (QA shots of each tab).
    private static let launchTab = AppState.launchFlag("-HistqPRTab").flatMap(PRTab.init(rawValue:))
    #if DEBUG
    /// DEBUG `-HistqPRAction <action>` (`comment`, `start-thread`, `approve`, `request-changes`, `unapprove`, `merge`, `merge-stale`,
    /// `merge-stale-closed`, `close`, `reopen`, `rebase`, `update-branch`, `delete-branch`, `restore-branch`): runs
    /// that action once, on the first load, without its confirmation
    /// (the stub answers it), so a launch exercises the action path and its reload. Only with `-HistqGitHubStub YES`:
    /// never an unconfirmed action on a real account.
    /// `resolve-manual` is the merge box's own (`PRActionsCard.launchResolve`): a local merge, not a GitHub action.
    private static var launchAction: PullRequestAction? = switch GitHubStub.isEnabled
        ? AppState.launchFlag("-HistqPRAction") : nil {
    case "comment": .comment("QA comment")
    case "start-thread": .startThread("QA thread")
    case "approve": .review(.approve, body: "")
    case "request-changes": .review(.requestChanges, body: "QA change request")
    case "unapprove": .unapprove
    case "merge": .merge(.squash, sha: GitHubStub.headSHA)
    // A head the stub's PR #1 no longer has: the stub answers 409, as GitHub does after a push.
    case "merge-stale", "merge-stale-closed": .merge(.squash, sha: GitHubStub.staleSHA)
    case "close": .setOpen(false)
    case "reopen": .setOpen(true)
    case "rebase": .rebase(sha: GitHubStub.headSHA)
    case "update-branch": .updateBranch(sha: GitHubStub.headSHA)
    case "delete-branch": .deleteBranch("feature")
    case "restore-branch": .restoreBranch("feature", sha: GitHubStub.headSHA)
    // Bitbucket's Tasks card (`-HistqHostingStubKind bitbucket -HistqStubPageSeed YES`): a new task, and seeded task 701
    // resolved.
    case "task": .createTask("Check the usage text")
    case "task-resolve": .setTask(id: 701, resolved: true)
    default: nil
    }
    /// DEBUG `-HistqPRAction reply|resolve|unresolve|greply|gresolve|edit|edit-save|delete|delete-confirm|react|`
    /// `react-new|new-inline|new-inline-post|mr-react`: like `launchAction`, on a review thread (or a general thread:
    /// `greply`, `gresolve`; or the first own comment: `edit` opens its editor, `edit-save` saves "edited" into it,
    /// `delete` opens its confirmation, `delete-confirm` confirms it; or the first comment with reactions, `react`, or
    /// with none, `react-new`, gets a reaction (`react` toggles it with one kind); or the first added line of the
    /// first file: `new-inline` opens a new comment box under it, `new-inline-post` posts "stub inline" there; or the
    /// award bar's first kind (👍) toggled on the pull request itself: `mr-react`) of the first load, which picks it
    /// (`threadLaunchAction(_:in:)`): only with `-HistqGitHubStub YES` too.
    private static var threadLaunchActionName: String? = GitHubStub.isEnabled
        ? AppState.launchFlag("-HistqPRAction").flatMap {
            ["reply", "resolve", "unresolve", "greply", "gresolve", "edit", "edit-save", "delete", "delete-confirm",
             "react", "react-new", "new-inline", "new-inline-post", "mr-react"].contains($0) ? $0 : nil
        }
        : nil
    /// `merge-stale-closed`: the detail closes while the merge runs, so its failure is another detail's (the PRs tab's
    /// notice).
    private static let closesAfterLaunchAction = AppState.launchFlag("-HistqPRAction") == "merge-stale-closed"

    /// `reply` posts "QA reply" to the first thread, `resolve` resolves the first unresolved one and `unresolve`
    /// unresolves the first resolved one, whatever `viewerCanResolve` says (the stub answers both); `greply` and
    /// `gresolve` act on the first general thread, `edit-save` on the first own comment and `react`/`react-new` on
    /// the first comment with or without reactions (`PRGeneralAction.launchAction`); nil when no thread fits, and for
    /// `edit`, `delete` and `delete-confirm` (`openLaunchStep`).
    private static func threadLaunchAction(_ name: String, in detail: PullRequestDetail) -> PullRequestAction? {
        let threads = detail.threads.value?.all ?? []
        switch name {
        case "greply", "gresolve", "edit-save", "react", "react-new":
            return PRGeneralAction.launchAction(
                name, in: detail.comments, reviewComments: threads.flatMap(\.comments), page: detail.timeline
            ).map { .general($0) }
        case "mr-react":
            return detail.reactionKinds.first.map { kind in
                .itemReaction(kind: kind, add: !detail.pull.reactions.contains { $0.kind == kind && $0.viewerReacted })
            }
        case "new-inline-post":
            return launchInline(in: detail).map { file, composer in
                .newInline(PRNewInline(composer, on: file.file, headSHA: detail.pull.head.sha, body: "stub inline"))
            }
        case "reply":
            return threads.first.map { .reply(rootID: $0.id, body: "QA reply") }
        case "resolve", "unresolve":
            let resolved = name == "resolve"
            return threads.lazy.compactMap(\.state).first { $0.isResolved != resolved }
                .map { .resolve(thread: $0, resolved: resolved) }
        default:
            return nil
        }
    }

    /// DEBUG `new-inline` and `new-inline-post`: a box under the first added line of the first file; nil when that
    /// file has none (or the files did not load).
    private static func launchInline(in detail: PullRequestDetail) -> (file: PRFile, composer: DiffInlineComposer)? {
        guard let file = detail.files.value?.first,
              let line = file.section?.rows(.diff).first(where: { $0.kind == .added }).flatMap(DiffInlineLine.init)
        else { return nil }
        return (file, DiffInlineComposer(end: line))
    }

    /// `edit` opens the first own comment's editor, `delete` and `delete-confirm` its confirmation (the page opens it,
    /// `launchDelete`), `new-inline` a new comment box in Files changed (`launchInline`); nothing for another name or
    /// when no comment fits.
    private func openLaunchStep(_ name: String, in detail: PullRequestDetail) {
        if name == "new-inline" {
            guard let (file, composer) = Self.launchInline(in: detail) else { return }
            openInline(composer, in: file.id)
            return
        }
        let target = PRGeneralAction.launchTarget(
            name, in: detail.comments, reviewComments: detail.threads.value?.all.flatMap(\.comments) ?? [],
            page: detail.timeline)
        guard let target, let number else { return }
        switch name {
        case "edit":
            beginEdit(target)
            UITiming.content("pr \(number) action edit open")
        case "delete", "delete-confirm": launchDelete = (target, name == "delete-confirm")
        default: break
        }
    }
    #endif

    /// The header's reload: the shown detail loaded again from the host, kept on screen (with its drafts, open
    /// editors and tab) until the new one is in; a failure shows above the cards. Azure's files are diffed again.
    func reload(github: HostingStore) {
        guard let number, state.value != nil else { return }
        load(number, github: github, quiet: true, rediffs: true)
        reloading = true
    }

    /// Loads pull request `number`; `quiet` keeps the shown detail until the new one is in (after an action).
    /// Azure's files (`localFiles`) are diffed again only for another head or base, or with `rediffs`.
    func load(_ number: Int, github: HostingStore, quiet: Bool = false, rediffs: Bool = false) {
        task?.cancel()
        generation &+= 1
        reloading = false
        if number != self.number {
            // Another pull request: its own tab, file and box. The same one opened again keeps them (and the draft).
            tab = Self.launchTab ?? .conversation
            selectedFile = nil
            composer = .comment
            draft = ""
            startsThread = false
            activityView.filter = PRActivity.all
            reviewEvent = .approve
            mergeDetailsExpanded = true
            squashChoice = nil
            deleteSourceBranchChoice = nil
            ownMergeMethod = nil
            closeSourceBranchChoice = nil
            taskDraft = ""
            replyDrafts = [:]
            threadExpanded = [:]
            generalReplyDrafts = [:]
            generalExpanded = [:]
            editingComments = []
            commentEditDrafts = [:]
            inlineComposer = nil
            inlineDraft = ""
            actionError = nil
        }
        self.number = number
        repository = github.api?.repository
        if !quiet || state.value == nil {
            // A detail loaded before in this session shows at once, until this load replaces it.
            state = cache.last { $0.repository == repository && $0.detail.pull.number == number }
                .map { .loaded($0.detail) } ?? .loading
        }
        guard let api = github.api else {
            state = .failed("No account is connected for this tab: connect one in Settings › Integrations.")
            return
        }
        let generation = generation
        loadCount &+= 1
        let loadID = loadCount
        // The page is built with the threads the user expanded or collapsed by now.
        let expanded = threadExpanded
        let general = PRGeneralOptions(api.client, expanded: generalExpanded)
        let now = PRPageDates.loadNow()
        // The sort is the app's: another tab may have changed it since.
        activityView.newestFirst = Preferences.defaults.bool(forKey: PRActivityView.newestFirstKey)
        let activityView = activityView
        let rowSHA = github.row(for: .pullRequest(number))?.headSHA
        let warmsUp = state.value == nil
        // Azure serves no patch: its files are diffed here once the pull request's commits are known.
        let diffsLocally = api.client.kind == .azureDevOps
        task = Task { [weak self] in
            let (client, repository) = (api.client, api.repository)
            await withTaskGroup(of: Part?.self) { [weak self] group in
                // Commits, files and checks load beside the Conversation's parts and fill in as each arrives; the
                // checks start with the row's head, asked again below only when the pull request's is another one.
                group.addTask { await Self.fetchCommits(client, repository, number: number) }
                if !diffsLocally { group.addTask { await Self.fetchFiles(client, repository, number: number) } }
                if let rowSHA { group.addTask { await Self.fetchChecks(client, repository, sha: rowSHA) } }
                async let fetched = Self.fetch(
                    client, repository, number: number, loadID: loadID, expanded: expanded, general: general,
                    now: now, activityView: activityView)
                // A first visit's page takes a web view started meanwhile: the main actor is free while the host
                // answers. It starts after the placeholder's frame, never in front of it.
                if warmsUp {
                    try? await Task.sleep(for: .milliseconds(20))
                    if !Task.isCancelled { HostedHTMLView.warmUp() }
                }
                let result = await fetched
                guard let self, generation == self.generation, !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                reloading = false
                switch result {
                case .success(var detail):
                    let sha = detail.pull.head.sha
                    if sha != rowSHA { group.addTask { await Self.fetchChecks(client, repository, sha: sha) } }
                    if detail.layout.bitbucketSidebar, client.capabilities.contains(.reports) {
                        detail.reports = .loading
                        group.addTask { await Self.fetchReports(client, repository, sha: sha) }
                    }
                    if diffsLocally {
                        let pull = detail.pull
                        // A revisit or an action's reload keeps the files diffed for the same head and base.
                        let kept = state.value.map {
                            $0.pull.number == number && $0.pull.head.sha == sha && $0.pull.base.sha == pull.base.sha
                                && $0.files.value != nil
                        } ?? false
                        if pull.head.sha.isEmpty || pull.base.sha.isEmpty {
                            // Azure has not computed the merge yet: its file list, without patches.
                            group.addTask { await Self.fetchFiles(client, repository, number: number) }
                        } else if rediffs || !kept {
                            let (read, remote) = (localFiles, api.remote)
                            group.addTask { await Self.fetchLocalFiles(read, pull, remote: remote) }
                        } else if selectedFile == nil {
                            // No files part comes to pick the first file, as it does for a new diff.
                            selectedFile = state.value?.files.value?.first?.id
                        }
                    }
                    // The parts shown for the same head stay until this load's arrive (a revisit, a reload after an
                    // action), so their tabs do not go back to loading.
                    if let shown = state.value, shown.pull.number == number, shown.pull.head.sha == sha {
                        detail.commits = shown.commits
                        detail.files = Self.joined(shown.files, detail.threads)
                        detail.checks = shown.checks
                        if detail.reports.value == nil, shown.reports.value != nil { detail.reports = shown.reports }
                    }
                    state = .loaded(detail)
                    UITiming.content("pr \(number) layout \(detail.layout.name)")
                    Self.logMergeable(detail.pull)
                    Self.logThreads(detail)
                    if quiet { UITiming.content("pr \(number) reloaded") }
                    #if DEBUG
                    if let action = Self.launchAction {
                        Self.launchAction = nil
                        // As typed in the box: a failure must leave it there.
                        if case .startThread(let body) = action { draft = body }
                        if GitHubHTMLProbe.slotsEnabled {
                            // The slot probe's reload comes after its passes at both widths, so the page is laid out
                            // and the reload measures it again (`measureKey`).
                            Task { [weak self] in
                                try? await Task.sleep(for: .seconds(6))
                                self?.perform(action, on: number, github: github)
                            }
                        } else {
                            PRLaunchActionGate.run { [weak self] in self?.perform(action, on: number, github: github) }
                        }
                        if Self.closesAfterLaunchAction { close() }
                    }
                    // A new inline comment needs the files, which come after the Conversation: it waits for them
                    // (the `.files` part below).
                    if let name = Self.threadLaunchActionName,
                       !name.hasPrefix("new-inline") || detail.files.value != nil {
                        Self.threadLaunchActionName = nil
                        runThreadLaunch(name, in: detail, number: number, github: github)
                    }
                    #endif
                    // A host that never says whether a branch merges (Bitbucket) is not asked again.
                    if client.kind.reportsMergeability {
                        group.addTask {
                            await self.pollMergeable(client, repository, number: number, generation: generation)
                            return nil
                        }
                    }
                    // Each part as it arrives, into the detail as it is now (the re-poll may have replaced its pull).
                    for await part in group {
                        guard generation == self.generation, !Task.isCancelled else {
                            group.cancelAll()
                            return
                        }
                        guard let part, case .loaded(var shown) = state else { continue }
                        switch part {
                        case .commits(let commits):
                            shown.commits = commits
                        case .files(let files):
                            shown.files = Self.joined(files, shown.threads)
                            let names = files.value?.map(\.id) ?? []
                            if selectedFile.map({ !names.contains($0) }) ?? true { selectedFile = names.first }
                            #if DEBUG || HISTQ_PERF
                            UITiming.content("pr \(number) files loaded")
                            #endif
                        case .checks(let sha, let checks):
                            // The row's head, when the pull request has moved on since the list was read.
                            guard sha == shown.pull.head.sha else { continue }
                            shown.checks = checks
                            #if DEBUG || HISTQ_PERF
                            UITiming.content("pr \(number) checks loaded")
                            #endif
                        case .reports(let sha, let reports):
                            guard sha == shown.pull.head.sha else { continue }
                            shown.reports = reports
                        }
                        state = .loaded(shown)
                        #if DEBUG
                        if case .files = part, shown.files.value != nil, let name = Self.threadLaunchActionName,
                           name.hasPrefix("new-inline") {
                            Self.threadLaunchActionName = nil
                            runThreadLaunch(name, in: shown, number: number, github: github)
                        }
                        #endif
                    }
                case .failure(let error):
                    group.cancelAll()
                    let kind = client.kind
                    if quiet, state.value != nil {
                        actionError = "Could not reload the \(kind.pullRequestNoun.lowercased()): "
                            + Self.message(for: error, kind: kind)
                    } else {
                        state = .failed(Self.message(for: error, kind: kind))
                    }
                }
            }
        }
    }

    #if DEBUG
    /// Runs the DEBUG thread action `name` (`threadLaunchActionName`) on `detail`, or opens its step, through its gate.
    private func runThreadLaunch(_ name: String, in detail: PullRequestDetail, number: Int, github: HostingStore) {
        // A new inline comment is Files changed's: it waits for that tab, not for the Conversation.
        let gate: @MainActor (@escaping @MainActor () -> Void) -> Void = name.hasPrefix("new-inline")
            ? PRFilesLaunchGate.run : PRLaunchActionGate.run
        if let action = Self.threadLaunchAction(name, in: detail) {
            if GitHubHTMLProbe.slotsEnabled {
                // Like `launchAction`: after the slot probe's passes at both widths.
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(6))
                    self?.perform(action, on: number, github: github)
                }
            } else {
                gate { [weak self] in self?.perform(action, on: number, github: github) }
            }
        } else {
            gate { [weak self] in self?.openLaunchStep(name, in: detail) }
        }
    }
    #endif

    /// Keeps `detail` as the newest of `cache`.
    private func remember(_ detail: PullRequestDetail, of repository: HostedRepository) {
        cache.removeAll { $0.repository == repository && $0.detail.pull.number == detail.pull.number }
        cache.append((repository, detail))
        if cache.count > 8 { cache.removeFirst() }
    }

    /// GitHub answers `mergeable` null while it still computes whether the branch merges (right after an open or a
    /// push): asks again for the pull request alone, 1, 2 then 3 s apart, so "Checking…" clears without a reload. It
    /// runs in the load's task, so a newer load or `close` stops it. An answer with another head than the shown one is
    /// dropped and ends it: Merge pins the head the user reviewed, and GitHub refuses it once it moved.
    private func pollMergeable(
        _ client: any HostingProvider, _ repository: HostedRepository, number: Int, generation: Int
    ) async {
        for delay in [1, 2, 3] {
            guard case .loaded(let shown) = state, shown.isOpen, shown.pull.mergeable == nil else { return }
            try? await Task.sleep(for: .seconds(delay))
            guard generation == self.generation, !Task.isCancelled else { return }
            // A failed fetch only uses up a try: the box keeps saying it checks.
            guard let pull = await Self.fetchPull(client, repository, number: number) else { continue }
            guard generation == self.generation, !Task.isCancelled, case .loaded(var detail) = state,
                  pull.head.sha == detail.pull.head.sha else { return }
            // The award bar's reactions come from their own read: the re-poll keeps them.
            let reactions = detail.pull.reactions
            detail.pull = pull
            detail.pull.reactions = reactions
            state = .loaded(detail)
            Self.logMergeable(pull)
        }
    }

    /// The timing log's `pr <n> mergeable true|false|null`, once for each answer (QA of the re-poll).
    private static func logMergeable(_ pull: HostedPullRequest) {
        UITiming.content("pr \(pull.number) mergeable \(pull.mergeable.map { "\($0)" } ?? "null")")
    }

    /// The timing log's `pr <n> threads <count> resolved <k> states <joined>/<count>|unavailable` once the threads
    /// loaded (QA of the REST and GraphQL parts and their join): `joined` counts the threads that got a state, so a
    /// failed join shows; `unavailable` when GraphQL failed.
    private static func logThreads(_ detail: PullRequestDetail) {
        guard let threads = detail.threads.value else { return }
        let all = threads.all
        let resolved = all.count { $0.state?.isResolved == true }
        let joined = all.count { $0.state != nil }
        let states = threads.statesFailed ? "unavailable" : "\(joined)/\(all.count)"
        UITiming.content("pr \(detail.pull.number) threads \(all.count) resolved \(resolved) states \(states)")
    }

    /// The detail closed (Esc, another selection): an answer still on its way is dropped.
    func close() {
        task?.cancel()
        task = nil
        generation &+= 1
        state = .idle
    }

    /// Runs `action` on pull request `number` (the one whose detail the user acted on), then reloads it and the PRs
    /// tab's lists. A failure shows above the tabs while that pull request shows; otherwise it names the number in
    /// the PRs tab (`HostingStore.actionNotice`), since the shown detail is another one's.
    func perform(_ action: PullRequestAction, on number: Int, github: HostingStore,
                 then afterSuccess: (@MainActor () -> Void)? = nil)
    {
        guard busy[number] == nil else { return }
        guard let api = github.api else {
            actionError = "No account is connected for this tab."
            return
        }
        busy[number] = action
        if self.number == number { actionError = nil }
        // A reply also names its thread's host key (the thread state's id): GitLab posts it to that discussion.
        var hostKey: String?
        if case .reply(let rootID, _) = action, self.number == number {
            hostKey = state.value?.threads.value?.all.first(where: { $0.id == rootID })?.state?.id
            if state.value?.layout.collapsesReplies == true { threadExpanded[rootID] = true }
        }
        // A general thread or own comment action shows at once: the shown detail's comments (and threads) patched,
        // its page rebuilt off the main actor before the write; a failure puts them and the page back.
        var optimistic: (shown: PullRequestDetail, comments: [HostedComment], threads: Loadable<PRThreads>,
                         general: PRGeneralOptions)?
        // A reaction on a comment that keeps its row changes no HTML: its page is the shown one with the row toggled,
        // put in at once, in the click's update, instead of being rebuilt off the main actor (a first reaction or the
        // last one removed adds or drops the row: rebuilt, as the other actions).
        var ready: PRTimelineHTML?
        if case .general(let general) = action, self.number == number, let shown = state.value {
            // A thread just resolved takes its default (collapsed), on the page and after; one being unresolved
            // stays as the user expanded it.
            if case .resolve(let root, true) = general { generalExpanded[root.id] = nil }
            // Where replies fold (the Activity), a thread just replied to opens, so the reply shows.
            if case .reply(let root, _) = general, shown.layout.collapsesReplies { generalExpanded[root.id] = true }
            // A saved edit closes its editor at once (the page shows the new body); its text stays until the write
            // is in, and a failure opens the editor again with it.
            if case .edit(let target, _) = general { editingComments.remove(target.key) }
            optimisticID &+= 1
            // Bitbucket keeps a deleted comment that has replies, as "This comment was deleted".
            let keepsDeleted = api.client.kind == .bitbucketCloud
            let options = PRGeneralOptions(api.client, expanded: generalExpanded)
            optimistic = (shown, PRTimeline.patched(shown.comments, general, viewer: shown.viewer,
                                                    replyID: optimisticID, keepsDeleted: keepsDeleted,
                                                    kinds: options.reactions),
                          PRTimeline.patched(shown.threads, general, keepsDeleted: keepsDeleted,
                                             kinds: options.reactions),
                          options)
            ready = PRTimeline.patched(shown.timeline, general)
        }
        // A new inline comment closes its box and shows its thread under the line at once, in the click's update
        // (the shown page until its rebuild with the thread, off the main actor, comes in); its text stays with the
        // action, and a failure opens the box again with it.
        var threadShown = false
        if case .newInline(let new) = action, self.number == number, let shown = state.value {
            if inlineComposer?.path == new.path { inlineComposer = nil }
            inlineDraft = ""
            optimisticID &+= 1
            var threads = shown.threads
            if case .loaded(let loaded) = threads, let thread = new.thread(id: optimisticID, viewer: shown.viewer) {
                threads = .loaded(PRThreads(
                    byReview: loaded.byReview, replyOnlyReviewIDs: loaded.replyOnlyReviewIDs,
                    unattached: loaded.unattached + [thread], resolveUnavailable: loaded.resolveUnavailable,
                    statesFailed: loaded.statesFailed))
            }
            optimistic = (shown, shown.comments, threads, PRGeneralOptions(api.client, expanded: generalExpanded))
            threadShown = replacePage(of: shown.loadID, number: number, comments: shown.comments, threads: threads,
                                      timeline: shown.timeline)
            if threadShown { UITiming.content("pr \(number) action \(action.timingName) patched") }
        }
        if let optimistic, let ready,
           replacePage(of: optimistic.shown.loadID, number: number, comments: optimistic.comments,
                       threads: optimistic.threads, timeline: ready) {
            UITiming.content("pr \(number) action \(action.timingName) patched")
        }
        // An award bar click changes the bar at once, in the click's update (no HTML changes); a failure puts the
        // reactions back as they were, on the same load only.
        var reactionsShown: (loadID: Int, reactions: [HostedReaction])?
        if case .itemReaction(let kind, let add) = action, self.number == number, case .loaded(var shown) = state {
            reactionsShown = (shown.loadID, shown.pull.reactions)
            shown.pull.reactions = PRTimeline.toggled(shown.pull.reactions, kind, add: add, kinds: shown.reactionKinds)
            state = .loaded(shown)
            UITiming.content("pr \(number) action \(action.timingName) patched")
        }
        // Delete branch and Restore branch change the merged box at once; a failure puts it back, on the same load only.
        var branchShown: (loadID: Int, exists: Bool?)?
        let branchTarget: Bool? = switch action {
        case .deleteBranch: false
        case .restoreBranch: true
        default: nil
        }
        if let branchTarget, self.number == number, case .loaded(var shown) = state {
            branchShown = (shown.loadID, shown.headBranchExists)
            shown.headBranchExists = branchTarget
            state = .loaded(shown)
            UITiming.content("pr \(number) action \(action.timingName) patched")
        }
        // A task written shows at once in the Tasks card; a failure puts the tasks back, on the same load only.
        var tasksShown: (loadID: Int, tasks: [HostedTask]?)?
        if self.number == number, case .loaded(var shown) = state, let tasks = shown.tasks {
            var changed: [HostedTask]?
            switch action {
            case .createTask(let body):
                optimisticID &+= 1
                changed = tasks + [HostedTask(id: optimisticID, body: body, isResolved: false, creator: shown.viewer,
                                              createdAt: .now)]
            case .setTask(let id, let resolved):
                changed = tasks.map { task in
                    var task = task
                    if task.id == id { task.isResolved = resolved }
                    return task
                }
            case .deleteTask(let id): changed = tasks.filter { $0.id != id }
            default: break
            }
            if let changed {
                tasksShown = (shown.loadID, tasks)
                shown.tasks = changed
                state = .loaded(shown)
                UITiming.content("pr \(number) action \(action.timingName) patched")
            }
        }
        let expanded = threadExpanded
        // "#12 Merging…" in the footer.
        let reference = github.kind.reference(.pullRequest(number))
        let endOperation = beginOperation("\(reference) \(action.progressTitle.dropLast())")
        let activityView = activityView
        Task { [weak self, ready, threadShown] in
            if let optimistic, ready == nil {
                let page = await Self.page(
                    optimistic.shown, comments: optimistic.comments, threads: optimistic.threads,
                    noun: api.client.kind.pullRequestNoun, expanded: expanded, general: optimistic.general,
                    activity: activityView)
                if self?.replacePage(of: optimistic.shown.loadID, number: number, comments: optimistic.comments,
                                     threads: optimistic.threads, timeline: page) == true {
                    UITiming.content("pr \(number) action \(action.timingName) "
                        + (threadShown ? "page" : "patched"))
                }
            }
            let error = await Self.run(action, hostKey: hostKey, api.client, api.repository, number: number)
            endOperation()
            guard let self else { return }
            busy[number] = nil
            UITiming.content("pr \(number) action \(action.timingName) \(error == nil ? "ok" : "failed")")
            let showing = isShowing(number)
            if let error {
                if let optimistic {
                    replacePage(of: optimistic.shown.loadID, number: number, comments: optimistic.shown.comments,
                                threads: optimistic.shown.threads, timeline: optimistic.shown.timeline)
                }
                if let reactionsShown, self.number == number, case .loaded(var detail) = state,
                   detail.loadID == reactionsShown.loadID {
                    detail.pull.reactions = reactionsShown.reactions
                    state = .loaded(detail)
                }
                if let branchShown, self.number == number, case .loaded(var detail) = state,
                   detail.loadID == branchShown.loadID {
                    detail.headBranchExists = branchShown.exists
                    state = .loaded(detail)
                }
                if let tasksShown, self.number == number, case .loaded(var detail) = state,
                   detail.loadID == tasksShown.loadID {
                    detail.tasks = tasksShown.tasks
                    state = .loaded(detail)
                }
                // The new task's text comes back, unless another one was typed meanwhile.
                if case .createTask(let body) = action, self.number == number, taskDraft.isEmpty { taskDraft = body }
                if case .general(.edit(let target, let body)) = action, self.number == number {
                    reopenEdit(target.key, body: body)
                    if editingComments.contains(target.key) {
                        UITiming.content("pr \(number) action edit reopened cedit-\(target.key) open")
                    }
                }
                // The box comes back with the text, unless another one was opened meanwhile.
                if case .startThread = action, self.number == number {
                    UITiming.content("pr \(number) action start-thread kept text \(draft.count)")
                }
                if case .newInline(let new) = action, self.number == number, inlineComposer == nil {
                    inlineComposer = PRInlineComposer(path: new.path, composer: new.composer)
                    inlineDraft = new.body
                    UITiming.content("pr \(number) action new-inline-post reopened \(new.path) "
                        + "\(new.composer.end.probe) text \(new.body.count)")
                }
                var message = Self.message(for: error, kind: api.client.kind)
                if case .general(let general) = action {
                    message = PRGeneralAction.withPermissionHint(message, for: general, error: error,
                                                                 kind: api.client.kind)
                }
                UITiming.content("pr \(number) action error \(message)")
                if showing {
                    actionError = "\(action.failureTitle): \(message)"
                } else {
                    let reference = github.kind.reference(.pullRequest(number))
                    github.actionNotice = "\(action.failureTitle(of: reference)): \(message)"
                    // Its kept detail may hold the optimistic change the failure could not put back.
                    cache.removeAll { $0.detail.pull.number == number }
                }
                // The head moved since the user reviewed it: show the new one, so they review it before merging.
                if case HostingError.headChanged = error {
                    github.refreshNow()
                    if showing { load(number, github: github, quiet: true) }
                }
                return
            }
            switch action {
            case .comment, .startThread: if self.number == number { draft = "" }
            // The header's Approve and Request changes send no text: the box keeps what is typed in it.
            case .review(_, let body): if self.number == number, !body.isEmpty { draft = "" }
            case .reply(let rootID, _): if self.number == number { replyDrafts[rootID] = nil }
            case .resolve(let thread, let resolved):
                // A thread just resolved collapses at once, and the reload builds it collapsed; one just unresolved
                // stays as the user expanded it.
                if resolved, self.number == number,
                   let root = state.value?.threads.value?.all.first(where: { $0.state?.id == thread.id })?.id {
                    threadExpanded[root] = false
                }
            case .general(let general):
                if case .reply(let root, _) = general, self.number == number { generalReplyDrafts[root.id] = nil }
                if case .edit(let target, _) = general, self.number == number { savedEdit(target.key) }
            case .merge, .setOpen:
                // The result shows at once (pill, Actions box); the reload below confirms it and, since it bumps the
                // generation, drops an older load's answer that would bring the old state back.
                if showing, case .loaded(var shown) = state, shown.pull.number == number {
                    if case .setOpen(let open) = action {
                        shown.pull.state = open ? "open" : "closed"
                    } else {
                        shown.pull.state = "closed"
                        shown.pull.merged = true
                        shown.pull.mergedAt = .now
                    }
                    state = .loaded(shown)
                    let result = shown.isMerged ? "merged" : shown.isOpen ? "open" : "closed"
                    UITiming.content("pr \(number) state \(result)")
                }
            case .unapprove, .newInline, .itemReaction, .rebase, .requestReviewers, .addAssignees, .addLabels,
                 .updateBranch, .deleteBranch, .restoreBranch, .createTask, .setTask, .deleteTask:
                break
            }
            afterSuccess?()
            github.refreshNow()
            if showing {
                load(number, github: github, quiet: true)
            } else {
                // Its kept detail is from before the action.
                cache.removeAll { $0.detail.pull.number == number }
            }
        }
    }

    /// Puts `comments`, `threads` and their page in the shown detail (in one change: the page's views read both),
    /// only while it is still load `loadID` of pull request `number` (a reload in between already has the host's
    /// answer). The rest of the detail stays as it is now (the re-poll may have replaced `pull`).
    @discardableResult
    private func replacePage(
        of loadID: Int, number: Int, comments: [HostedComment], threads: Loadable<PRThreads>, timeline: PRTimelineHTML
    ) -> Bool {
        guard self.number == number, case .loaded(var detail) = state, detail.loadID == loadID else { return false }
        detail.comments = comments
        detail.threads = threads
        detail.files = Self.joined(detail.files, threads)
        detail.timeline = timeline
        detail.timelineCount = timeline.count
        state = .loaded(detail)
        return true
    }

    /// The Conversation's page of `detail` with `comments` and `threads` instead of its own (an optimistic action's),
    /// its Activity as `activity` shows it.
    @concurrent
    private nonisolated static func page(
        _ detail: PullRequestDetail, comments: [HostedComment], threads: Loadable<PRThreads>, noun: String,
        expanded: [Int: Bool], general: PRGeneralOptions, activity: PRActivityView
    ) async -> PRTimelineHTML {
        timeline(detail.pull, noun: noun, comments: comments, reviews: detail.reviews, threads: threads,
                 expanded: expanded, general: general, now: detail.now,
                 activity: activityPage(detail.layout, events: detail.events, view: activity,
                                        roles: detail.memberRoles, viewerID: detail.viewer?.id),
                 layout: detail.layout, roles: detail.memberRoles, events: detail.events, view: activity,
                 viewerID: detail.viewer?.id)
    }

    /// The Activity of a page with `layout` (nil without one), its `events`, `view` and commenters' `roles`.
    private nonisolated static func activityPage(
        _ layout: PRPageLayout, events: [HostedTimelineEvent]?, view: PRActivityView, roles: [Int: String]?,
        viewerID: Int?
    ) -> PRActivityPage? {
        layout.activity.map {
            PRActivityPage(layout: $0, view: view, events: events, collapsesReplies: layout.collapsesReplies,
                           headerEdit: layout.headerEdit, headerDelete: layout.headerDelete,
                           roles: layout.roleBadges ? roles ?? [:] : nil, viewerID: viewerID)
        }
    }

    /// The Conversation's page: the description of `pull` (a `noun`), then `comments`, `reviews` and `threads`, dated
    /// against `now`, with the layout's Activity (`activity`).
    private nonisolated static func timeline(
        _ pull: HostedPullRequest, noun: String, comments: [HostedComment], reviews: [HostedReview],
        threads: Loadable<PRThreads>, expanded: [Int: Bool], general: PRGeneralOptions, now: Date,
        activity: PRActivityPage?, layout: PRPageLayout, roles: [Int: String]?, events: [HostedTimelineEvent]?,
        view: PRActivityView, viewerID: Int?
    ) -> PRTimelineHTML {
        PRTimeline.page(
            author: pull.user, action: layout.descriptionVerb ?? "opened this \(noun.lowercased())",
            date: pull.createdAt, html: pull.bodyHTML, markdown: pull.body, comments: comments, reviews: reviews,
            threads: threads, expanded: expanded, general: general, now: now, activity: activity,
            roles: layout.roleBadges ? roles ?? [:] : nil, authorOnly: layout.authorBadgeOnly,
            descriptionReactions: layout.descriptionReactions,
            events: layout.timelineEvents ? events : nil,
            commentFilter: layout.commentsCard && layout.activity == nil ? PRCommentFilter(filter: view.filter) : nil,
            viewerID: viewerID, splitsDescription: layout.commentsCard && layout.activity != nil)
    }

    /// The Activity's filter or sort changed (`view`): it shows at once in its controls, the page is rebuilt off the
    /// main actor and put in while the detail is still the same load with the same comments. The sort is kept for the
    /// app.
    func setActivity(_ view: PRActivityView, github: HostingStore) {
        guard view != activityView else { return }
        if view.newestFirst != activityView.newestFirst {
            Preferences.defaults.set(view.newestFirst, forKey: PRActivityView.newestFirstKey)
        }
        activityView = view
        guard let number, case .loaded(let shown) = state, shown.layout.activity != nil || shown.layout.commentsCard,
              let api = github.api
        else { return }
        let general = PRGeneralOptions(api.client, expanded: generalExpanded)
        let expanded = threadExpanded
        Task { [weak self] in
            let page = await Self.page(
                shown, comments: shown.comments, threads: shown.threads, noun: api.client.kind.pullRequestNoun,
                expanded: expanded, general: general, activity: view)
            guard let self, activityView == view, self.number == number, case .loaded(var detail) = state,
                  detail.loadID == shown.loadID, detail.comments == shown.comments
            else { return }
            detail.timeline = page
            detail.timelineCount = page.count
            state = .loaded(detail)
            UITiming.content("pr \(number) activity \(view.newestFirst ? "newest" : "oldest") \(view.filter)")
        }
    }

    /// Whether the detail shows pull request `number` (loading or loaded), not another one or nothing (closed).
    private func isShowing(_ number: Int) -> Bool {
        guard self.number == number else { return false }
        if case .idle = state { return false }
        return true
    }

    @concurrent
    private nonisolated static func fetch(
        _ client: any HostingProvider, _ repository: HostedRepository, number: Int, loadID: Int, expanded: [Int: Bool],
        general: PRGeneralOptions, now: Date, activityView: PRActivityView
    ) async -> Result<PullRequestDetail, any Error> {
        let layout = PRPageLayout.for(client.kind)
        async let pullRequest = client.pullRequest(number, in: repository)
        async let comments = client.comments(on: .pullRequest(number), in: repository)
        // The Activity's history entries, only where the layout has an Activity and the provider reads them; started
        // with the comments, so a host that reads both in one request (GitLab's discussions) shares it. A failure only
        // leaves them out.
        let readsEvents = (layout.activity != nil || layout.timelineEvents)
            && client.capabilities.contains(.timelineEvents)
        async let events: Loadable<[HostedTimelineEvent]> = !readsEvents ? .idle
            : await part(client.kind) { try await client.timelineEvents(of: .pullRequest(number), in: repository) }
        async let reviews = client.reviews(of: number, in: repository)
        async let reviewComments = part(client.kind) { try await client.reviewComments(of: number, in: repository) }
        async let threadStates = part(client.kind) { try await client.reviewThreadStates(of: number, in: repository) }
        // Only a provider that can revoke an approval or reply to general comments asks who the token's user is; a
        // failure only hides the button (or draws an optimistic reply as "you").
        // The "Comments" card's Mine filter needs it too.
        let asksViewer = !client.capabilities.isDisjoint(with: [.unapprove, .generalReplies]) || layout.commentsCard
        async let viewer = asksViewer ? try? await client.currentUser() : nil
        // The award bar's reactions, only where the layout has the bar and the provider reads them; started with the
        // comments, so a host that reads both in one request (GitLab's GraphQL note states) shares it. A failure only
        // hides the bar.
        let showsReactions = layout.reactionBar || layout.descriptionReactions
        let barKinds = showsReactions && client.capabilities.contains(.itemReactions) ? client.reactionKinds : []
        async let itemReactions: Loadable<[HostedReaction]> = barKinds.isEmpty ? .idle
            : await part(client.kind) { try await client.itemReactions(of: .pullRequest(number), in: repository) }
        // The approval and merge boxes' reads, only where the layout has them; started with the reviews, so a host that
        // reads both in one request (GitLab's approvals) shares it. A failure only leaves out what they say.
        let boxes = layout.mergeBoxes
        async let approvals: Loadable<HostedApprovals> = !boxes ? .idle
            : await part(client.kind) { try await client.approvals(of: number, in: repository) }
        async let repositoryInfo: Loadable<HostedRepositoryInfo> = !boxes ? .idle
            : await part(client.kind) { try await client.repositoryInfo(repository) }
        // The sidebar's Edit menus: who may be assigned or asked to review (the approval box's list too) and the
        // project's labels, only where the layout has the sidebar and the provider takes those writes.
        let sidebar = layout.sidebar
        let asksCandidates = boxes && client.capabilities.contains(.reviewRequests)
            || sidebar && !client.capabilities.isDisjoint(with: [.reviewRequests, .assignees])
        async let candidates: Loadable<[HostedUser]> = !asksCandidates ? .idle
            : await part(client.kind) { try await client.assignableUsers(in: repository) }
        let asksLabels = sidebar && client.capabilities.contains(.labels)
        async let labelChoices: Loadable<[HostedLabel]> = !asksLabels ? .idle
            : await part(client.kind) { try await client.labels(in: repository) }
        // Bitbucket's sidebar Tasks and Merge checks; a failure only leaves that card out.
        let bitbucketSide = layout.bitbucketSidebar
        async let tasks: Loadable<[HostedTask]> = !(bitbucketSide && client.capabilities.contains(.tasks)) ? .idle
            : await part(client.kind) { try await client.tasks(of: number, in: repository) }
        // Azure DevOps's policies, in its merge area.
        async let mergeChecks: Loadable<[HostedMergeCheck]> = !((bitbucketSide || layout.mergeChecksInMergeArea)
            && client.capabilities.contains(.mergeChecks)) ? .idle
            : await part(client.kind) { try await client.mergeChecks(of: number, in: repository) }
        // GitHub's sidebar Projects and Development; a failure only leaves those cards out.
        let asksExtras = layout.githubSidebar && client.capabilities.contains(.pullRequestExtras)
        async let extras: Loadable<HostedPullRequestExtras> = !asksExtras ? .idle
            : await part(client.kind) { try await client.pullRequestExtras(number, in: repository) }
        do {
            let pull = try await pullRequest
            let (comments, reviews) = try await (comments, reviews)
            let threads = Self.threads(await reviewComments, await threadStates, hostName: client.kind.name)
            let viewer = await viewer
            // The badges' roles: read once the commenters are known (the author, the viewer for an optimistic reply,
            // every general and diff comment's author). A failure only leaves the roles out.
            let threadComments = (threads.value?.all ?? []).flatMap(\.comments)
            let users = [pull.user, viewer] + comments.map(\.user) + threadComments.map(\.user)
            var roles: [Int: String]? = !layout.roleBadges ? nil : await part(client.kind) {
                try await client.memberRoles(of: users.compactMap { $0?.id }, in: repository)
            }.value
            if layout.roleBadges {
                // A host that says each author's relation on the comment itself (GitHub's `author_association`).
                let said = comments.map { ($0.user, $0.authorAssociation) }
                    + reviews.map { ($0.user, $0.authorAssociation) }
                    + threadComments.map { ($0.user, $0.authorAssociation) }
                roles = PRTimeline.associationRoles(said).merging(roles ?? [:]) { _, member in member }
            }
            let events = await events.value
            let timeline = timeline(
                pull, noun: client.kind.pullRequestNoun, comments: comments, reviews: reviews, threads: threads,
                expanded: expanded, general: general, now: now,
                activity: activityPage(layout, events: events, view: activityView, roles: roles,
                                       viewerID: viewer?.id), layout: layout,
                roles: roles, events: events, view: activityView, viewerID: viewer?.id)
            let reviewers = reviewers(pull, reviews)
            // The merged box's Delete branch / Restore branch: only a merged pull request's own branch (not a fork's)
            // of a repository the token's user may push to.
            let merged = pull.mergedAt != nil || pull.merged == true
            let readsBranch = layout.githubMergeBox && client.capabilities.contains(.deleteHeadBranch) && merged
                && pull.isFromSameRepository && pull.viewerCanPush == true && pull.head.ref != pull.base.ref
            let headBranchExists: Bool? = !readsBranch ? nil : await part(client.kind) {
                try await client.headBranchExists(pull.head.ref, in: repository)
            }.value
            let viewerApproved = viewer.map { viewer in
                client.capabilities.contains(.unapprove)
                    && reviewers.contains { $0.userID == viewer.id && $0.state == "APPROVED" }
            } ?? false
            let reactions = await itemReactions.value
            var shown = pull
            shown.reactions = reactions ?? []
            return .success(PullRequestDetail(
                loadID: loadID, now: now, layout: layout, pull: shown, timelineCount: timeline.count,
                timeline: timeline, comments: comments, reviews: reviews, viewer: viewer, reviewers: reviewers,
                commits: .loading, files: .loading, checks: .loading, threads: threads,
                viewerApproved: viewerApproved, reactionKinds: reactions == nil ? [] : barKinds,
                approvals: await approvals.value, repositoryInfo: await repositoryInfo.value,
                reviewerCandidates: await candidates.value ?? [], labelChoices: await labelChoices.value ?? [],
                events: events, memberRoles: roles, headBranchExists: headBranchExists, extras: await extras.value,
                tasks: await tasks.value, mergeChecks: await mergeChecks.value))
        } catch {
            return .failure(error)
        }
    }

    /// A part the Conversation does not need, read beside it (`load`).
    private enum Part: Sendable {
        case commits(Loadable<[HostedCommit]>)
        case files(Loadable<[PRFile]>)
        /// The check runs of head `sha`.
        case checks(sha: String, Loadable<[HostedCheckRun]>)
        /// The reports on head `sha` (Bitbucket's).
        case reports(sha: String, Loadable<[HostedReport]>)
    }

    @concurrent
    private nonisolated static func fetchCommits(
        _ client: any HostingProvider, _ repository: HostedRepository, number: Int
    ) async -> Part? {
        .commits(await part(client.kind) { try await client.pullRequestCommits(number, in: repository) })
    }

    @concurrent
    private nonisolated static func fetchFiles(
        _ client: any HostingProvider, _ repository: HostedRepository, number: Int
    ) async -> Part? {
        .files(prFiles(await part(client.kind) { try await client.pullRequestFiles(number, in: repository) }))
    }

    /// Azure DevOps's files with their patches, diffed by the session (`localFiles`). Logs `content pr <n> files
    /// local-diff <count> ok` or `… local-diff failed` (never git's words: they may hold a remote's URL).
    @concurrent
    private nonisolated static func fetchLocalFiles(
        _ read: @MainActor @Sendable (HostedPullRequest, String) async -> Loadable<[HostedPullRequestFile]>,
        _ pull: HostedPullRequest, remote: String
    ) async -> Part? {
        let files = prFiles(await read(pull, remote))
        UITiming.content("pr \(pull.number) files local-diff " + (files.value.map { "\($0.count) ok" } ?? "failed"))
        return .files(files)
    }

    private nonisolated static func prFiles(_ read: Loadable<[HostedPullRequestFile]>) -> Loadable<[PRFile]> {
        switch read {
        case .loaded(let files): .loaded(files.map(prFile))
        case .failed(let message): .failed(message)
        case .idle, .loading: .idle
        }
    }

    @concurrent
    private nonisolated static func fetchChecks(
        _ client: any HostingProvider, _ repository: HostedRepository, sha: String
    ) async -> Part? {
        .checks(sha: sha, await part(client.kind) { try await client.checkRuns(for: sha, in: repository) })
    }

    @concurrent
    private nonisolated static func fetchReports(
        _ client: any HostingProvider, _ repository: HostedRepository, sha: String
    ) async -> Part? {
        .reports(sha: sha, await part(client.kind) { try await client.reports(commit: sha, in: repository) })
    }

    /// Joins the threads' comments (REST) and states (GraphQL): without the comments there are no threads, so their
    /// failure is the part's; without the states the threads still show, only resolving is unavailable. States that
    /// loaded but joined none of the threads make it unavailable too, with a reason, instead of Resolve going
    /// missing without one.
    private nonisolated static func threads(
        _ comments: Loadable<[HostedReviewComment]>, _ states: Loadable<[HostedReviewThreadState]>, hostName: String
    ) -> Loadable<PRThreads> {
        switch comments {
        case .loaded(let comments):
            let grouped = HostedReviewThread.group(comments, states: states.value ?? [])
            var unavailable: String?
            var failed = false
            if case .failed(let message) = states {
                unavailable = message
                failed = true
            } else if states.value != nil {
                let all = grouped.threadsByReview.values.flatMap { $0 } + grouped.unattached
                if !all.isEmpty, all.allSatisfy({ $0.state == nil }) {
                    unavailable = "\(hostName) did not say which conversations these comments belong to."
                }
            }
            return .loaded(PRThreads(
                byReview: grouped.threadsByReview, replyOnlyReviewIDs: grouped.replyOnlyReviewIDs,
                unattached: grouped.unattached, resolveUnavailable: unavailable, statesFailed: failed))
        case .failed(let message): return .failed(message)
        case .idle, .loading: return .idle
        }
    }

    /// `files`, each with the threads on its path (`PRFile.threads`), oldest first. A load, an optimistic thread
    /// change and files that arrive after the threads (a host that loads them later) all join through here.
    nonisolated static func joined(_ files: Loadable<[PRFile]>, _ threads: Loadable<PRThreads>) -> Loadable<[PRFile]> {
        guard case .loaded(var list) = files else { return files }
        let byPath = Dictionary(grouping: threads.value?.all ?? [], by: \.path)
        for index in list.indices {
            list[index].threads = (byPath[list[index].id] ?? []).sorted { a, b in
                (a.comments.first?.createdAt ?? .distantPast, a.id) < (b.comments.first?.createdAt ?? .distantPast, b.id)
            }
        }
        return .loaded(list)
    }

    @concurrent
    private nonisolated static func fetchPull(
        _ client: any HostingProvider, _ repository: HostedRepository, number: Int
    ) async -> HostedPullRequest? {
        try? await client.pullRequest(number, in: repository)
    }

    /// A read that may fail on its own: its value, or its failure in the host's words (the issue page's reads too).
    nonisolated static func part<T: Sendable>(
        _ kind: HostingKind, _ body: () async throws -> T
    ) async -> Loadable<T> {
        do {
            return .loaded(try await body())
        } catch {
            return .failed(message(for: error, kind: kind))
        }
    }

    private nonisolated static func prFile(_ file: HostedPullRequestFile) -> PRFile {
        let letter: Character = switch file.status {
        case "added": "A"
        case "removed": "D"
        case "renamed": "R"
        case "copied": "C"
        default: "M"
        }
        let section = file.diff.flatMap {
            DiffSection(side: .commit, diff: $0, full: nil, language: LanguageTable.language(forPath: file.filename))
        }
        return PRFile(file: file, change: FileChange(letter: letter, path: file.filename,
                                                     originalPath: file.previousFilename), section: section)
    }

    /// The requested reviewers, then everyone who reviewed with their latest state (a later comment-only review does
    /// not hide an approval or a change request, as on GitHub).
    private nonisolated static func reviewers(_ pull: HostedPullRequest, _ reviews: [HostedReview]) -> [PRReviewer] {
        var latest: [String: String] = [:]
        var order: [HostedUser] = []
        for review in reviews where review.state != "PENDING" {
            guard let user = review.user else { continue }
            if latest[user.login] == nil { order.append(user) }
            if review.state != "COMMENTED" || latest[user.login] == nil { latest[user.login] = review.state }
        }
        let requested = (pull.requestedReviewers ?? []).filter { latest[$0.login] == nil }
        return requested.map { PRReviewer(login: $0.login, userID: $0.id, avatarURL: $0.avatarURL, state: nil) }
            + order.map {
                PRReviewer(login: $0.login, userID: $0.id, avatarURL: $0.avatarURL, state: latest[$0.login])
            }
    }

    @concurrent
    private nonisolated static func run(
        _ action: PullRequestAction, hostKey: String?, _ client: any HostingProvider, _ repository: HostedRepository,
        number: Int
    ) async -> (any Error)? {
        do {
            switch action {
            case .merge(let method, let sha, let options):
                try await client.merge(number, in: repository, method: method, sha: sha, options: options)
            case .review(let event, let body):
                _ = try await client.review(number, in: repository, event: event, body: body.isEmpty ? nil : body)
            case .comment(let body): _ = try await client.comment(on: .pullRequest(number), in: repository, body: body)
            case .startThread(let body):
                _ = try await client.startThread(on: .pullRequest(number), in: repository, body: body)
            case .setOpen(let open): try await client.setOpen(open, item: .pullRequest(number), in: repository)
            case .reply(let rootID, let body):
                _ = try await client.reply(
                    to: HostedThreadRef(rootCommentID: rootID, hostKey: hostKey), on: number, in: repository,
                    body: body)
            case .resolve(let thread, let resolved):
                _ = try await client.setReviewThread(thread, resolved: resolved)
            case .unapprove: try await client.unapprove(number, in: repository)
            case .general(let action): try await action.run(client, on: .pullRequest(number), in: repository)
            case .newInline(let new):
                _ = try await client.createInlineComment(at: new.position, on: number, in: repository, body: new.body)
            case .itemReaction(let kind, true):
                try await client.addItemReaction(kind, to: .pullRequest(number), in: repository)
            case .itemReaction(let kind, false):
                try await client.removeItemReaction(kind, from: .pullRequest(number), in: repository)
            case .rebase(let sha): try await client.rebaseSourceBranch(number, in: repository, sha: sha)
            case .requestReviewers(let users): try await client.requestReviewers(users, on: number, in: repository)
            case .addAssignees(let users): try await client.addAssignees(users, to: .pullRequest(number), in: repository)
            case .addLabels(let names): try await client.addLabels(names, to: .pullRequest(number), in: repository)
            case .updateBranch(let sha): try await client.updateBranch(number, in: repository, expectedHeadSHA: sha)
            case .deleteBranch(let branch): try await client.deleteHeadBranch(branch, in: repository)
            case .restoreBranch(let branch, let sha): try await client.restoreHeadBranch(branch, sha: sha, in: repository)
            case .createTask(let body): _ = try await client.createTask(on: number, in: repository, body: body)
            case .setTask(let id, let resolved): try await client.setTask(id, resolved: resolved, on: number, in: repository)
            case .deleteTask(let id): try await client.deleteTask(id, on: number, in: repository)
            }
            return nil
        } catch {
            return error
        }
    }

    /// The error's text in the words of the host `kind` ("GitLab", "merge request").
    nonisolated static func message(for error: any Error, kind: HostingKind) -> String {
        switch error {
        case HostingError.unauthorized:
            "\(kind.name) refused the token (revoked or expired). Reconnect in Settings › Integrations."
        case let error as HostingError:
            error.description(host: kind.name, pullRequest: kind.pullRequestNoun.lowercased())
        default:
            error.localizedDescription
        }
    }
}

extension PullRequestDetailModel: PRGeneralThreadModel {
    func isBusy(_ number: Int) -> Bool { busy[number] != nil }

    func runningGeneral(on number: Int) -> PRGeneralAction? {
        if case .general(let action)? = busy[number] { return action }
        return nil
    }

    func perform(_ action: PRGeneralAction, on number: Int, github: HostingStore) {
        perform(.general(action), on: number, github: github)
    }
}

extension PullRequestDetailModel {
    /// A "+" click in Files changed on `path` (its table already shows the box): the box is kept here, so a reload
    /// keeps it; its text moves with it.
    func openInline(_ composer: DiffInlineComposer, in path: String) {
        inlineComposer = PRInlineComposer(path: path, composer: composer)
        UITiming.content("pr \(number.map(String.init) ?? "?") action new-inline open \(path) \(composer.end.probe)"
            + (composer.start.map { " from \($0.probe)" } ?? "") + (composer.message.map { " refused: \($0)" } ?? ""))
    }

    /// Cancel: the box and its text go.
    func cancelInline() {
        inlineComposer = nil
        inlineDraft = ""
    }

    /// Comment: `body` posted at the box's line(s) of `file`, on the head the shown patch was loaded at (`perform`
    /// shows it at once).
    func postInline(_ body: String, file: PRFile, detail: PullRequestDetail, github: HostingStore) {
        guard let open = inlineComposer, open.path == file.id, let number, !body.isEmpty else { return }
        perform(.newInline(PRNewInline(open.composer, on: file.file, headSHA: detail.pull.head.sha, body: body)),
                on: number, github: github)
    }
}

#if DEBUG
/// DEBUG `-HistqPRAction new-inline|new-inline-post` with `-HistqPRTab files`: the action waits until Files changed
/// shows its loaded files and its table, as a click there does; on another tab it runs once the files loaded.
@MainActor
enum PRFilesLaunchGate {
    private static let waitsForFiles = AppState.launchFlag("-HistqPRTab") == "files"
    private static var shown = false
    private static var pending: [@MainActor () -> Void] = []

    static func run(_ action: @escaping @MainActor () -> Void) {
        guard waitsForFiles, !shown else { return action() }
        pending.append(action)
    }

    /// Files changed appeared: the waiting actions run after its table's first load (this update's).
    static func filesDidShow() {
        guard !shown else { return }
        shown = true
        let actions = pending
        pending = []
        DispatchQueue.main.async { actions.forEach { $0() } }
    }
}
#endif

extension HostedPullRequest {
    /// The head is a branch of the base's repository, not of a fork: its label's owner is the base's.
    var isFromSameRepository: Bool {
        head.label != nil && head.label?.split(separator: ":").first == base.label?.split(separator: ":").first
    }

    /// Whether the local commit `sha` (a full hash) is the head. Bitbucket gives an abbreviated head (12 hex digits),
    /// which matches as a prefix of at least 7 hex digits; a full head (GitHub, GitLab) only matches itself.
    func headIs(_ sha: String) -> Bool {
        let head = head.sha.lowercased()
        if head == sha.lowercased() { return !head.isEmpty }
        return head.count >= 7 && head.count < sha.count && head.allSatisfy(\.isHexDigit)
            && sha.lowercased().hasPrefix(head)
    }
}

// MARK: - Views

/// Panel2 while a pull request is open: the header card at once, then the tab's cards (skeletons until loaded).
struct PRDetailView: View {
    let session: RepoSession
    let number: Int
    @Environment(WindowModel.self) private var model

    var body: some View {
        let detail = session.pullDetail
        VStack(spacing: SectionCardMetrics.spacing) {
            PRHeaderCard(session: session, number: number)
            PRTabsRow(session: session)
            if let error = detail.actionError {
                PRActionErrorCard(message: error) { detail.actionError = nil }
                    .onAppear { UITiming.content("pr \(number) action-error shown") }
            }
            Group {
                switch detail.state {
                case .idle, .loading:
                    PlaceholderCard(
                        token: session.hostedToken, detail: "pr \(number)",
                        isCurrent: { [model, session, number] in
                            model.selectedSession === session && session.openHosted == .pullRequest(number)
                        }
                    ) {
                        PRSkeleton()
                    }
                case .loaded(let value):
                    PRContent(session: session, detail: value)
                        .onAppear { UITiming.content("pr \(number)") }
                        // A kept detail replaces another pull request's in one frame: a new page, as after a load.
                        .id(number)
                case .failed(let message):
                    DiffNoticeCard(title: session.github.kind.pullRequestNoun, systemImage: "exclamationmark.triangle",
                                   message: message)
                        .onAppear { UITiming.content("pr \(number) failed") }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// Back, the title and number, the state pill and Open on GitHub; the "wants to merge" line (the tabs are
/// `PRTabsRow`'s, under it). The title comes from the PRs tab's row until the pull request is in.
private struct PRHeaderCard: View {
    let session: RepoSession
    let number: Int
    /// The card is narrower than `narrowWidth`.
    @State private var narrow = false

    /// Narrower than this (a stacked layout's panel), Open on GitHub shows its icon only and the "wants to merge"
    /// sentence takes two lines, so the title and the branch chips keep room to read.
    private static let narrowWidth: CGFloat = 480

    var body: some View {
        @Bindable var detail = session.pullDetail
        let value = detail.state.value
        let title = value?.pull.title ?? session.github.row(for: .pullRequest(number))?.title
        let kind = session.github.kind
        // The kind's, not the load's: the same value, known before the load, so the tabs never change title.
        let layout = PRPageLayout.for(kind)
        SectionCard(nil, contentPadding: 8) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button {
                        session.closeFile()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(RowIconButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .help("Back to the Graph (Esc)")
                    .accessibilityLabel("Back to the graph")
                    .padding(.leading, 4)
                    IconImage("lucide-git-pull-request-arrow")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    if let title {
                        Text(title)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(title)
                    } else {
                        SkeletonLine(width: 180, height: 14)
                    }
                    Text(kind.reference(.pullRequest(number)))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if let value {
                        if layout.mergeSentence == .wantsToMerge {
                            PRStatePill(detail: value)
                                .fixedSize()
                        }
                        if layout.reviewButtonsInHeader, value.isOpen {
                            PRHeaderReviewButtons(session: session, detail: value)
                        }
                        PRReloadButton(reloading: session.pullDetail.reloading,
                                       noun: kind.pullRequestNoun.lowercased()) { [session] in
                            session.pullDetail.reload(github: session.github)
                        }
                        if narrow {
                            Button {
                                GitHubLinks.open(session.github.webURL(.pullRequest(value.pull.number)))
                            } label: {
                                Image(systemName: "safari")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(RowTextButtonStyle(formRow: true, circle: true))
                            .help("Open on \(kind.name)")
                            .accessibilityLabel("Open on \(kind.name)")
                        } else {
                            // Labelled, so it reads at a glance (user, 2026-11-17); the title gives way first.
                            Button {
                                GitHubLinks.open(session.github.webURL(.pullRequest(value.pull.number)))
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "safari")
                                        .accessibilityHidden(true)
                                    Text("Open on \(kind.name)")
                                }
                            }
                            .buttonStyle(RowTextButtonStyle(formRow: true))
                            .fixedSize()
                            .help("Open the \(kind.pullRequestNoun.lowercased()) in the browser")
                        }
                    } else {
                        SkeletonLine(width: 56, height: 20)
                    }
                }
                .frame(height: 32)
                Group {
                    if let value {
                        switch layout.mergeSentence {
                        case .wantsToMerge: summary(value)
                        case .requestedToMerge: requestedSummary(value)
                        case .stateFirst: summary(value, stateFirst: true)
                        case .bitbucket: bitbucketSummary(value)
                        case .azureDevOps: azureSummary(value)
                        }
                    } else {
                        SkeletonLine(width: 260, height: 12)
                            .frame(height: 20)
                    }
                }
                // As tall as the sentence while it loads too (a chip's height a line), so the tabs do not move when
                // it comes.
                .frame(height: narrow ? 46 : 20, alignment: .topLeading)
                .padding(.leading, 8)
            }
            // The card's width, never its rows': a row wider than the card neither widens it nor hides the switch.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: Bool.self) { $0.size.width < Self.narrowWidth } action: { narrow = $0 }
        }
    }

    /// "stub wants to merge 2 commits into [main] from [stub:feature]" in GitHub's order (merged: "merged"; closed:
    /// "wanted to merge"), on one line, or on two before "into" in a narrow card. The two branches are blue chips, so
    /// which one goes into which reads at a glance (user, 2026-11-17); the words keep their width and the chips give
    /// way first.
    /// `stateFirst`: GitHub's order, the state pill first on the row (not by the title).
    private func summary(_ value: PullRequestDetail, stateFirst: Bool = false) -> some View {
        let pull = value.pull
        let count = pull.commits ?? value.commits.value?.count ?? 0
        let verb = value.isMerged ? "merged" : value.isOpen ? "wants to merge" : "wanted to merge"
        // GitHub's merged sentence names who merged it (not the author) and ends with when.
        let actor = stateFirst && value.isMerged ? pull.mergedBy?.login ?? pull.user?.login : pull.user?.login
        let dates = PRPageDates(now: value.now)
        let mergedWhen = stateFirst && value.isMerged ? pull.mergedAt : nil
        let layout = narrow
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        return layout {
            HStack(spacing: 6) {
                if stateFirst {
                    PRStatePill(detail: value)
                        .fixedSize()
                }
                Text(actor ?? "ghost")
                    .fontWeight(.semibold)
                Text("\(verb) \(count) \(count == 1 ? "commit" : "commits")")
                    .foregroundStyle(.secondary)
            }
            .frame(height: 20)
            .layoutPriority(1)
            HStack(spacing: 6) {
                Text("into")
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
                branchChip(pull.base.ref)
                Text("from")
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
                branchChip(headName(pull))
                if let mergedWhen {
                    Text(verbatim: dates.relative(mergedWhen))
                        .foregroundStyle(.secondary)
                        .help(dates.absolute(mergedWhen))
                        .layoutPriority(1)
                }
            }
        }
        .font(.body)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    /// GitLab's "[Open] stub requested to merge [feature] [copy] into [main] 1 week ago" (whatever the state, as
    /// GitLab writes it), on one line, or on two before "into" in a narrow card; the copy button puts the source
    /// branch's name on the pasteboard; the time is the creation's, relative, the absolute date in the tooltip.
    private func requestedSummary(_ value: PullRequestDetail) -> some View {
        let pull = value.pull
        let layout = narrow
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        return layout {
            HStack(spacing: 6) {
                PRStatePill(detail: value)
                    .fixedSize()
                Text(pull.user?.login ?? "ghost")
                    .fontWeight(.semibold)
                Text("requested to merge")
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
                branchChip(headName(pull))
                Button {
                    RepoMenus.copy(pull.head.ref)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(RowIconButtonStyle())
                .help("Copy branch name")
                .accessibilityLabel("Copy branch name")
                .layoutPriority(1)
            }
            .frame(height: 20)
            .layoutPriority(1)
            HStack(spacing: 6) {
                Text("into")
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
                branchChip(pull.base.ref)
                if let date = pull.createdAt {
                    let dates = PRPageDates(now: value.now)
                    Text(verbatim: dates.relative(date))
                        .foregroundStyle(.secondary)
                        .help(dates.absolute(date))
                        .layoutPriority(1)
                }
            }
        }
        .font(.body)
        .lineLimit(1)
        .accessibilityElement(children: .contain)
    }

    /// Bitbucket's "[avatar] stub [feature] → [main] [Open] · Created 1 week ago · Last updated 2 days ago", on one line,
    /// or on two before the dates in a narrow card.
    private func bitbucketSummary(_ value: PullRequestDetail) -> some View {
        let pull = value.pull
        let dates = PRPageDates(now: value.now)
        let layout = narrow
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        return layout {
            HStack(spacing: 6) {
                if let user = pull.user {
                    GitHubUserAvatar(login: user.login, id: user.id, avatarURL: user.avatarURL, size: 18,
                                     avatars: .of(session.github))
                        .help(user.name ?? user.login)
                }
                Text(pull.user?.name ?? pull.user?.login ?? "ghost")
                    .fontWeight(.semibold)
                    .layoutPriority(1)
                branchChip(headName(pull))
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("into")
                branchChip(pull.base.ref)
                PRStatePill(detail: value)
                    .fixedSize()
            }
            .frame(height: 20)
            .layoutPriority(1)
            HStack(spacing: 6) {
                if let created = pull.createdAt {
                    Text(verbatim: "· Created \(dates.relative(created))")
                        .help(dates.absolute(created))
                }
                if let updated = pull.updatedAt {
                    Text(verbatim: "· Last updated \(dates.relative(updated))")
                        .help(dates.absolute(updated))
                }
            }
            .foregroundStyle(.secondary)
            .layoutPriority(1)
        }
        .font(.body)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    /// Azure DevOps's "[Active] [avatar] stub proposes to merge [feature] [copy] into [main] 1/3 comments resolved"
    /// (the threads with a status, general and on files, as loaded), on one line, or on two before "into" in a narrow
    /// card; the copy button puts the source branch's name on the pasteboard.
    private func azureSummary(_ value: PullRequestDetail) -> some View {
        let pull = value.pull
        let roots = value.comments.filter { $0.parentID == nil && $0.resolvable == true }
        let states = (value.threads.value?.all ?? []).compactMap(\.state)
        let total = roots.count + states.count
        let resolved = roots.count { $0.resolved == true } + states.count { $0.isResolved }
        let layout = narrow
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        return layout {
            HStack(spacing: 6) {
                PRStatePill(detail: value, titles: value.layout.words.states)
                    .fixedSize()
                if let user = pull.user {
                    GitHubUserAvatar(login: user.login, id: user.id, avatarURL: user.avatarURL, size: 18,
                                     avatars: .of(session.github))
                        .help(user.name ?? user.login)
                }
                Text(pull.user?.name ?? pull.user?.login ?? "ghost")
                    .fontWeight(.semibold)
                    .layoutPriority(1)
                Text("proposes to merge")
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
                branchChip(headName(pull))
                Button {
                    RepoMenus.copy(pull.head.ref)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(RowIconButtonStyle())
                .help("Copy branch name")
                .accessibilityLabel("Copy branch name")
                .layoutPriority(1)
            }
            .frame(height: 20)
            .layoutPriority(1)
            HStack(spacing: 6) {
                Text("into")
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
                branchChip(pull.base.ref)
                if total > 0 {
                    Text(verbatim: "\(resolved)/\(total) comments resolved")
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                }
            }
        }
        .font(.body)
        .lineLimit(1)
        .accessibilityElement(children: .contain)
    }

    /// The head as the sentence names it: GitHub's `owner:branch`; on GitLab and Bitbucket the branch alone when it is
    /// in the same repository (its label's owner is the base's), as they write it.
    private func headName(_ pull: HostedPullRequest) -> String {
        session.github.kind != .github && pull.isFromSameRepository ? pull.head.ref : pull.head.label ?? pull.head.ref
    }

    /// A branch of the sentence: monospaced in a brand blue capsule, at most `maxWidth` wide and cut in the middle, so
    /// both ends of a long name stay (the full name in the tooltip).
    private func branchChip(_ name: String) -> some View {
        CappedWidth(maxWidth: 420) {
            Text(name)
                .font(.callout.monospaced())
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(Color.accentColor.opacity(0.22)))
        .help(name)
    }

    /// Its one subview at its own width, offered at most `maxWidth`: unlike `.frame(maxWidth:)`, which grows to what it
    /// is offered, a short branch keeps its chip as wide as its name, and a narrow sentence can still shrink it.
    private struct CappedWidth: Layout {
        let maxWidth: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let width = min(proposal.width ?? maxWidth, maxWidth)
            return subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)) ?? .zero
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}

/// The tabs with their counts, on their own row under the header card: only their track, standing on the panel as
/// a card does, a card's gap from the cards around it (user, 2026-11-24).
private struct PRTabsRow: View {
    let session: RepoSession

    var body: some View {
        let value = session.pullDetail.state.value
        // The kind's, not the load's: the same value, known before the load, so the tabs never change title.
        let layout = PRPageLayout.for(session.github.kind)
        // At its own width, scrolled sideways in a panel narrower than it.
        ViewThatFits(in: .horizontal) {
            tabs(value, layout)
            ScrollView(.horizontal) {
                tabs(value, layout)
            }
            .scrollIndicators(.never)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private func tabs(_ value: PullRequestDetail?, _ layout: PRPageLayout) -> some View {
        @Bindable var detail = session.pullDetail
        return CapsuleTabs(selection: $detail.tab, tabs: layout.tabs, title: { tab in tabTitle(tab, value, layout) },
                           compact: true, cardTrack: true)
            .fixedSize()
    }

    private func tabTitle(_ tab: PRTab, _ value: PullRequestDetail?, _ layout: PRPageLayout) -> Text {
        let count: Int? = switch tab {
        case .conversation: value?.timelineCount
        case .commits: value?.commits.value?.count
        case .files: value?.files.value?.count
        case .checks: value?.checks.value?.count
        }
        let title = layout.title(of: tab)
        guard let count else { return Text(title) }
        return Text(title) + Text(" \(count)").monospacedDigit()
    }
}

/// One column of GitHub's merge box (`gitHubColumns`): its word, what stands and a thin bar of how far it got, in
/// its tone (gray without one, no bar without a measure).
private struct PRMergeColumn: View {
    typealias Column = (title: String, note: String, tone: Color?, fraction: Double?)
    let column: Column

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(column.title)
                .font(.body.weight(.semibold))
            Text(column.note)
                .font(.settingsCaption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.surfaceBorder)
                    if let fraction = column.fraction {
                        Capsule()
                            .fill(column.tone.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                            .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                    }
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: SettingsInputMetrics.cornerRadius, style: .continuous)
            .fill(Palette.tabFill))
        .overlay(RoundedRectangle(cornerRadius: SettingsInputMetrics.cornerRadius, style: .continuous)
            .strokeBorder(Palette.surfaceBorder, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// Bitbucket's Approve and Request changes in the header (`PRPageLayout.reviewButtonsInHeader`): Approve, or
/// "Approved" (a click revokes it) once the viewer approved; Request changes, or "Changes requested" once they did
/// (Data Center's "Requested changes"). A click acts at once; both are off while an action runs on the pull request.
private struct PRHeaderReviewButtons: View {
    let session: RepoSession
    let detail: PullRequestDetail

    var body: some View {
        let model = session.pullDetail
        let number = detail.pull.number
        let busy = model.busy[number]
        let viewerState = detail.viewer.flatMap { viewer in
            detail.reviewers.first { $0.userID == viewer.id }?.state
        }
        let approved = detail.viewerApproved || viewerState == "APPROVED"
        let requested = viewerState == "CHANGES_REQUESTED"
        HStack(spacing: 6) {
            Button {
                model.perform(approved ? .unapprove : .review(.approve, body: ""), on: number, github: session.github)
            } label: {
                HStack(spacing: 6) {
                    if busy == .unapprove || busy == .review(.approve, body: "") {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: approved ? "checkmark.circle.fill" : "checkmark.circle")
                            .foregroundStyle(approved ? Color(nsColor: Palette.diffAddedSign) : .secondary)
                            .accessibilityHidden(true)
                    }
                    Text(approved ? "Approved" : "Approve")
                }
            }
            .buttonStyle(RowTextButtonStyle(formRow: true))
            .fixedSize()
            .disabled(busy != nil)
            .help(approved ? "Revoke your approval" : "Approve this pull request")
            Button {
                model.perform(.review(.requestChanges, body: ""), on: number, github: session.github)
            } label: {
                HStack(spacing: 6) {
                    if busy == .review(.requestChanges, body: "") {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(requested ? Palette.conflictTone : .secondary)
                            .accessibilityHidden(true)
                    }
                    let words = detail.layout.words
                    Text(!requested ? words.requestChanges ?? "Request changes"
                        : words.changesRequested
                            ?? (session.github.kind == .bitbucketDataCenter ? "Requested changes" : "Changes requested"))
                }
            }
            .buttonStyle(RowTextButtonStyle(formRow: true))
            .fixedSize()
            .disabled(busy != nil || requested)
            .help(requested ? "You requested changes" : "Ask for changes before this is merged")
        }
    }
}

/// The header's reload button, beside "Open on <host>": a click reloads the page from the host at once (its icon
/// turns into a spinner until the new detail is in), the shown one staying until then.
struct PRReloadButton: View {
    let reloading: Bool
    /// "pull request", "merge request", "issue".
    let noun: String
    let reload: () -> Void

    var body: some View {
        Button(action: reload) {
            ZStack {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.secondary)
                    .opacity(reloading ? 0 : 1)
                if reloading { ProgressView().controlSize(.mini) }
            }
        }
        .buttonStyle(RowTextButtonStyle(formRow: true, circle: true))
        .disabled(reloading)
        .help("Reload the \(noun)")
        .accessibilityLabel(reloading ? "Reloading the \(noun)" : "Reload the \(noun)")
    }
}

/// Open (green), Draft, Merged (the brand blue) or Closed (red), as on GitHub; `titles`: the host's words for them
/// (`PRPageWords.states`, Azure DevOps's Active, Completed, Abandoned).
private struct PRStatePill: View {
    let detail: PullRequestDetail
    var titles: [String: String] = [:]

    var body: some View {
        let (state, symbol, fill, text): (String, String, Color, Color) =
            if detail.isMerged {
                ("Merged", "arrow.triangle.merge", Palette.mergedTone, Palette.onAccent)
            } else if !detail.isOpen {
                ("Closed", "xmark.circle", Color(nsColor: Palette.diffRemovedFill), Color(nsColor: Palette.diffRemovedSign))
            } else if detail.pull.draft == true {
                ("Draft", "circle.dashed", Palette.inputSurface, .secondary)
            } else {
                ("Open", "lucide-git-pull-request-arrow", Color(nsColor: Palette.diffAddedFill), Color(nsColor: Palette.diffAddedSign))
            }
        let title = titles[state] ?? state
        Label { Text(title) } icon: { IconImage(symbol, size: 12) }
            .font(.settingsCaption.weight(.semibold))
            .foregroundStyle(text)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(fill))
            .accessibilityLabel("State: \(title)")
    }
}

/// A failed action, with a close button (the issue detail's too).
struct PRActionErrorCard: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        SectionCard(nil, contentPadding: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(nsColor: Palette.diffRemovedSign))
                    .padding(.leading, 4)
                    .accessibilityHidden(true)
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(RowIconButtonStyle())
                .help("Dismiss")
                .accessibilityLabel("Dismiss the error")
            }
        }
        .modifier(NoticeTint(tone: Color(nsColor: Palette.diffRemovedSign)))
    }
}

/// The loaded detail's selected tab.
private struct PRContent: View {
    let session: RepoSession
    let detail: PullRequestDetail

    var body: some View {
        let number = detail.pull.number
        switch session.pullDetail.tab {
        case .conversation:
            PRConversationTab(session: session, detail: detail)
                .onAppear { UITiming.content("pr \(number) conversation \(detail.timelineCount)") }
        case .commits:
            PRCommitsTab(commits: detail.commits, now: detail.now, github: session.github,
                         byDay: detail.layout.commitsByDay, verb: detail.layout.commitVerb)
                .onAppear { UITiming.content("pr \(number) commits \(Self.count(detail.commits))") }
        case .files:
            PRFilesTab(session: session, detail: detail)
                .onAppear {
                    UITiming.content("pr \(number) files \(Self.count(detail.files))")
                    #if DEBUG
                    if detail.files.value != nil { PRFilesLaunchGate.filesDidShow() }
                    #endif
                }
                #if DEBUG
                // The tab shows while its files still load (`PRPartLoading`): the gate opens once they are in.
                .onChange(of: detail.files.value != nil) { _, loaded in
                    if loaded { PRFilesLaunchGate.filesDidShow() }
                }
                #endif
        case .checks:
            PRChecksTab(checks: detail.checks, hostName: session.github.kind.name)
                .onAppear { UITiming.content("pr \(number) checks \(Self.count(detail.checks))") }
        }
    }

    private static func count<T>(_ part: Loadable<[T]>) -> String {
        if case .loading = part { return "loading" }
        return part.value.map { "\($0.count)" } ?? "failed"
    }
}

// MARK: Conversation

/// The timeline card, the merge box and the comment box in GitHub's order, in one scroll view as GitHub's page is,
/// with the side column on the right in its own (at the end of the same scroll when panel2 is narrow).
struct PRConversationTab: View {
    let session: RepoSession
    let detail: PullRequestDetail

    private static let sideWidth: CGFloat = 220
    /// Narrower than this, the side cards go at the end of the middle column. The skeleton's too.
    static let wideEnough: CGFloat = 560
    /// Between the middle column and the side column: wider than between stacked cards, so the two columns read apart
    /// (user, 2026-11-17). The skeleton's and the issue page's too.
    static let columnGap: CGFloat = 16
    /// The scroll ids of the merge box and the Conversation (Activity) card, for DEBUG `-HistqPRScrollTo`.
    static let mergeID = "merge"
    static let activityID = "activity"
    /// The "Comments" card's header row (`commentsCards`).
    private static let commentsHeaderHeight: CGFloat = 44

    /// The description's reaction row (`PRPageLayout.descriptionReactions`): the pull request's own reactions, written
    /// through the detail's optimistic `itemReaction`; nil without the row or when they did not load.
    private var itemReactions: PRItemReactions? {
        guard detail.layout.descriptionReactions, !detail.reactionKinds.isEmpty else { return nil }
        let number = detail.pull.number
        return PRItemReactions(
            kinds: detail.reactionKinds, given: detail.pull.reactions, busy: session.pullDetail.isBusy(number),
            noun: session.github.kind.pullRequestNoun.lowercased()) { [session] kind, add in
            session.pullDetail.perform(.itemReaction(kind: kind, add: add), on: number, github: session.github)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= Self.wideEnough
            // One tree at both widths: the middle column keeps its page (and its web view) when panel2 crosses
            // `wideEnough`, and only the side cards move.
            HStack(alignment: .top, spacing: Self.columnGap) {
                ScrollViewReader { proxy in
                    ScrollView {
                        main(sideCards: !wide)
                    }
                    #if DEBUG
                    .onAppear {
                        PRLaunchActionGate.registerScroller(ids: [Self.mergeID, Self.activityID]) { id in
                            proxy.scrollTo(id, anchor: .top)
                        }
                    }
                    #endif
                }
                if wide {
                    ScrollView {
                        PRSideColumn(session: session, detail: detail)
                    }
                    .scrollIndicators(.never)
                    .frame(width: Self.sideWidth)
                }
            }
        }
    }

    /// The column's cards, each as tall as its content: a long conversation pushes the merge and comment boxes down
    /// instead of sharing the panel's height with them.
    private func main(sideCards: Bool) -> some View {
        VStack(spacing: SectionCardMetrics.spacing) {
            if detail.layout.reactionBar, !detail.reactionKinds.isEmpty {
                let model = session.pullDetail
                let number = detail.pull.number
                PRAwardBarCard(kinds: detail.reactionKinds, given: detail.pull.reactions, busy: model.isBusy(number),
                               noun: session.github.kind.pullRequestNoun.lowercased()) { [session] kind, add in
                    session.pullDetail.perform(.itemReaction(kind: kind, add: add), on: number, github: session.github)
                }
            }
            // GitLab's order: the approval box and the merge box under the header, before the activity.
            if detail.layout.mergeBoxes {
                PRApprovalBoxCard(session: session, detail: detail)
                PRActionsCard(session: session, detail: detail)
                    .id(Self.mergeID)
            } else if detail.layout.githubMergeBox || detail.layout.bitbucketMergeArea {
                // GitHub's merge box and Bitbucket's merge area first, above the description.
                PRActionsCard(session: session, detail: detail)
                    .id(Self.mergeID)
            }
            if detail.layout.commentsCard, let split = detail.timeline.split {
                commentsCards(split)
            } else {
                conversationCard
            }
            if !detail.layout.mergeBoxes, !detail.layout.githubMergeBox, !detail.layout.bitbucketMergeArea {
                PRActionsCard(session: session, detail: detail)
                    .id(Self.mergeID)
            }
            if !detail.layout.commentsCard {
                PRComposerCard(session: session, detail: detail)
            }
            if sideCards {
                PRSideColumn(session: session, detail: detail)
            }
        }
    }

    /// GitHub's new page (`PRPageLayout.commentsCard`): the description in its own card, then "Comments" with its
    /// filter, the comment box first and the comments under it, each part its own page.
    @ViewBuilder private func commentsCards(_ split: (description: PRTimelineHTML, comments: PRTimelineHTML))
        -> some View {
        if let title = detail.layout.descriptionTitle {
            SectionCard(title, systemImage: "doc.text") {
                page(split.description)
            }
        } else {
            SectionCard(nil) {
                page(split.description)
            }
        }
        // A taller header, so the filter's tabs keep room above them and above the comment box (user, 2026-11-23).
        SectionCard(detail.layout.activity?.title ?? "Comments", systemImage: "text.bubble",
                    count: detail.timelineCount, headerHeight: Self.commentsHeaderHeight) {
            VStack(spacing: 10) {
                PRComposerCard(session: session, detail: detail, embedded: true)
                page(split.comments)
            }
            .padding(.top, 4)
        } accessory: {
            let model = session.pullDetail
            if let activity = detail.layout.activity {
                PRActivityControls(activity: activity, view: model.activityView,
                                   count: detail.timeline.entryCount) { [session] view in
                    session.pullDetail.setActivity(view, github: session.github)
                }
            } else {
                commentFilterTabs(model)
            }
        }
        .id(Self.activityID)
    }

    /// GitHub's All / Unresolved / Mine tabs of the "Comments" card.
    private func commentFilterTabs(_ model: PullRequestDetailModel) -> some View {
        CapsuleTabs(selection: Binding(
            get: { PRCommentFilter(filter: model.activityView.filter) },
            set: { [session] filter in
                var view = session.pullDetail.activityView
                view.filter = filter.rawValue
                session.pullDetail.setActivity(view, github: session.github)
            }), tabs: PRCommentFilter.allCases, title: { Text($0.rawValue) }, compact: true, small: true,
            raisedTrack: true)
            .fixedSize()
    }

    /// One page of the Conversation: the whole timeline, or one part of GitHub's new page.
    private func page(_ timeline: PRTimelineHTML) -> some View {
        // The page fits its content and never scrolls itself: a wheel over the text or over a native view on the
        // page scrolls this column.
        PRTimelinePage(session: session, number: detail.pull.number, timeline: timeline, loadID: detail.loadID,
                       threads: detail.threads.value, avatars: .of(session.github), general: session.pullDetail,
                       itemReactions: itemReactions)
            .frame(maxWidth: .infinity)
    }

    /// The Conversation (Activity) card: the whole timeline in one page.
    private var conversationCard: some View {
        SectionCard(detail.layout.activity?.title ?? "Conversation", systemImage: "text.bubble",
                    count: detail.timelineCount) {
            page(detail.timeline)
        } accessory: {
            if let activity = detail.layout.activity {
                let model = session.pullDetail
                PRActivityControls(activity: activity, view: model.activityView) { [session] view in
                    session.pullDetail.setActivity(view, github: session.github)
                }
            }
        }
        .id(Self.activityID)
    }
}

/// The Activity card's filter ("All activity" or one of the host's categories) and sort toggle (oldest or newest
/// first): a choice shows at once in its control, the page follows off the main actor (`setActivity`).
struct PRActivityControls: View {
    let activity: PRActivity
    /// What the Activity shows now (the model's `activityView`).
    let view: PRActivityView
    /// Every entry's count, after the host's `allTitle` ("Show everything (7)").
    var count: Int? = nil
    /// The model's `setActivity`.
    let set: (PRActivityView) -> Void

    var body: some View {
        let view = view
        let all = activity.allTitle.map { title in count.map { "\(title) (\($0))" } ?? title } ?? PRActivity.all
        let title = { (filter: String) in filter == PRActivity.all ? all : filter }
        HStack(spacing: 6) {
            CapsuleMenuPicker(
                label: "Show", selection: Binding(get: { view.filter }, set: { filter in
                    var changed = view
                    changed.filter = filter
                    set(changed)
                }), title: Text(title(view.filter))
            ) {
                ForEach([PRActivity.all] + activity.categories, id: \.self) { Text(title($0)).tag($0) }
            }
            // A host whose order is fixed (Bitbucket's newest first) has no toggle.
            if activity.newestFirst == nil {
                Button {
                    var changed = view
                    changed.newestFirst.toggle()
                    set(changed)
                } label: {
                    Image(systemName: view.newestFirst ? "arrow.down" : "arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(BottomBarButtonStyle(height: 24, horizontalPadding: 9))
                .help(view.newestFirst ? "Newest first: show oldest first" : "Oldest first: show newest first")
                .accessibilityLabel(view.newestFirst ? "Sorted newest first" : "Sorted oldest first")
            }
        }
        .fixedSize()
    }
}

/// The award bar (`PullRequestDetail.reactionKinds` not empty: GitLab's, under the tabs): a chip for each of the
/// host's first two kinds (👍 and 👎, even at 0) and then for every other kind given, the viewer's own highlighted, a
/// click toggling it, then the picker of the host's kinds. Each click changes the bar at once and writes off the main
/// actor (`PullRequestAction.itemReaction`); off while an action runs on the pull request.
struct PRAwardBarCard: View {
    /// The host's kinds in its picker's order and the item's reactions.
    let kinds: [String]
    let given: [HostedReaction]
    /// An action runs on the item: the bar is off.
    let busy: Bool
    /// "merge request", "issue": the picker's VoiceOver label.
    let noun: String
    /// Adds (true) or removes the viewer's reaction of a kind.
    let perform: (String, Bool) -> Void

    var body: some View {
        let pinned = kinds.prefix(2).map { kind in
            given.first { $0.kind == kind } ?? HostedReaction(kind: kind, count: 0)
        }
        let shown = pinned + given.filter { reaction in !pinned.contains { $0.kind == reaction.kind } }
        SectionCard(nil, contentPadding: 8) {
            HStack(spacing: 6) {
                ForEach(shown, id: \.kind) { reaction in
                    PRReactionChip(reaction: reaction, busy: busy) {
                        guard !busy else { return }
                        perform(reaction.kind, !reaction.viewerReacted)
                    }
                }
                PRReactionPicker(kinds: kinds, reactions: given, busy: busy, label: "Add a reaction to the \(noun)") {
                    kind, add in
                    perform(kind, add)
                }
            }
            .padding(.leading, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// GitLab's approval box (`PRPageLayout.mergeBoxes`), under the award bar: Approve or Revoke approval (the review and
/// unapprove actions), whether approval is optional or how many approvals are required, who approved, and Assign
/// reviewers (a menu of the users the merge request may be assigned to, `requestReviewers`). Each click shows its
/// action running at once and writes off the main actor.
private struct PRApprovalBoxCard: View {
    let session: RepoSession
    let detail: PullRequestDetail

    var body: some View {
        SectionCard(nil, contentPadding: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    leading
                    Spacer(minLength: 8)
                    assignMenu
                }
                VStack(alignment: .leading, spacing: 8) {
                    leading
                    assignMenu
                }
            }
            .padding(.leading, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var running: PullRequestAction? { session.pullDetail.busy[detail.pull.number] }

    /// The token's user approved: GitLab's `user_has_approved`, else their latest review.
    private var hasApproved: Bool { detail.approvals?.viewerHasApproved ?? detail.viewerApproved }

    private var leading: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.badge.shield.checkmark")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            approveButton
            if let requirement {
                Text(requirement.title)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                if let count = requirement.count {
                    Text(count)
                        .font(.settingsCaption)
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
            }
            approvedBy
        }
    }

    /// Approve, or Revoke approval once the token's user approved (where the provider can revoke), on an open merge
    /// request only, and Approve only where GitLab says the user may approve.
    @ViewBuilder private var approveButton: some View {
        let model = session.pullDetail
        let number = detail.pull.number
        let running = running
        if detail.isOpen, hasApproved, session.github.offers(.unapprove) {
            Button {
                model.perform(.unapprove, on: number, github: session.github)
            } label: {
                HStack(spacing: 6) {
                    if running == .unapprove { ProgressView().controlSize(.mini) }
                    Text("Revoke approval")
                }
            }
            .buttonStyle(RowTextButtonStyle(formRow: true))
            .fixedSize()
            .disabled(running != nil)
            .help("Revoke your approval")
        } else if detail.isOpen, !hasApproved, detail.approvals?.viewerCanApprove != false {
            Button {
                model.perform(.review(.approve, body: ""), on: number, github: session.github)
            } label: {
                HStack(spacing: 6) {
                    if case .review(.approve, _) = running { ProgressView().controlSize(.mini) }
                    Text("Approve")
                }
            }
            .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
            .fixedSize()
            .disabled(running != nil)
            .help("Approve this merge request")
        }
    }

    /// "Approval is optional", or "Requires N approvals from eligible users." with "k of M approvals"; nil when the
    /// approvals did not load.
    private var requirement: (title: String, count: String?)? {
        guard let approvals = detail.approvals else { return nil }
        if approvals.isOptional { return ("Approval is optional", nil) }
        let required = approvals.required ?? 0
        let left = min(max(approvals.left ?? required, 0), required)
        let count = "\(required - left) of \(required) approvals"
        guard left > 0 else { return ("Approved", count) }
        return ("Requires \(left) \(left == 1 ? "approval" : "approvals") from eligible users.", count)
    }

    /// "Approved by" and the approvers' avatars (GitLab's `approved_by`, else the reviewers who approved).
    @ViewBuilder private var approvedBy: some View {
        let users: [(login: String, id: Int?, avatarURL: String?)] = detail.approvals.map { approvals in
            approvals.approvedBy.map { ($0.login, $0.id, $0.avatarURL) }
        } ?? detail.reviewers.filter { $0.state == "APPROVED" }.map { ($0.login, $0.userID, $0.avatarURL) }
        if !users.isEmpty {
            let avatars = HostAvatars.of(session.github)
            HStack(spacing: 4) {
                Text("Approved by")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                ForEach(users, id: \.login) { user in
                    GitHubUserAvatar(login: user.login, id: user.id, avatarURL: user.avatarURL, size: 18,
                                     avatars: avatars)
                        .help(user.login)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Approved by " + users.map(\.login).joined(separator: ", ")))
        }
    }

    /// Assign reviewers: the users the merge request may be assigned to who are not asked yet, each asked with one
    /// click; on an open merge request where the provider takes review requests and the users loaded.
    @ViewBuilder private var assignMenu: some View {
        let pull = detail.pull
        let asked = Set((pull.requestedReviewers ?? []).map(\.login))
        let candidates = detail.reviewerCandidates.filter { !asked.contains($0.login) }
        if detail.isOpen, session.github.offers(.reviewRequests), !detail.reviewerCandidates.isEmpty {
            let running = running
            Menu {
                ForEach(candidates, id: \.login) { user in
                    Button(user.name.map { "\($0) (@\(user.login))" } ?? user.login) {
                        session.pullDetail.perform(.requestReviewers([user]), on: pull.number, github: session.github)
                    }
                }
            } label: {
                HStack(spacing: MenuChevron.gap) {
                    if case .requestReviewers = running { ProgressView().controlSize(.mini) }
                    Text("Assign reviewers").lineLimit(1)
                    MenuChevron()
                }
            }
            .menuStyle(.button)
            .buttonStyle(BottomBarButtonStyle(height: 24, horizontalPadding: 12, menu: true))
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(running != nil || candidates.isEmpty)
            .help(candidates.isEmpty ? "Everyone who can review is asked already" : "Ask someone to review")
        }
    }
}

/// The comment box: a plain comment, or a review (approve, request changes, comment) with its body.
private struct PRComposerCard: View {
    let session: RepoSession
    let detail: PullRequestDetail
    /// Inside the "Comments" card (`PRPageLayout.commentsCard`): no card of its own, the Comment / Review choice on
    /// the button row.
    var embedded = false

    var body: some View {
        @Bindable var model = session.pullDetail
        let isReview = model.composer == .review
        if embedded {
            // Bitbucket reviews from the header's Approve and Request changes: a plain comment box.
            form(model, tabs: !detail.layout.reviewButtonsInHeader)
        } else {
            SectionCard(isReview ? "Review" : "Comment",
                        systemImage: isReview ? "checkmark.bubble" : "square.and.pencil") {
                form(model, tabs: false)
                    // Room between the header (with its Comment / Review choice) and the text box (user, 2026-11-17).
                    .padding(.top, 8)
            } accessory: {
                tabs(model)
            }
        }
    }

    private func tabs(_ model: PullRequestDetailModel) -> some View {
        @Bindable var model = model
        return CapsuleTabs(selection: $model.composer, tabs: PullRequestDetailModel.Composer.allCases,
                           title: { Text($0.title) }, compact: true, small: true, raisedTrack: true)
            .fixedSize()
    }

    /// The text box and its buttons; `tabs`: the Comment / Review choice first on the button row.
    private func form(_ model: PullRequestDetailModel, tabs showsTabs: Bool) -> some View {
        @Bindable var model = model
        let isReview = model.composer == .review
        return VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $model.draft)
                    .font(.body)
                    .settingsTextEditor()
                    .frame(height: 64)
                    .overlay(alignment: .topLeading) {
                        if model.draft.isEmpty {
                            Text(placeholder(model))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                HStack(spacing: 8) {
                    if showsTabs { tabs(model) }
                    if isReview {
                        CapsuleMenuPicker(label: "Review", selection: Binding(
                            get: { event(model) }, set: { model.reviewEvent = $0 }),
                                          title: Text(event(model).title)) {
                            ForEach(reviewEvents, id: \.self) { Text($0.title).tag($0) }
                        }
                    } else if offersStartThread {
                        CapsuleMenuPicker(label: "Post as", selection: $model.startsThread,
                                          title: Text(model.startsThread ? "Start thread" : "Comment")) {
                            Text("Comment").tag(false)
                            Text("Start thread").tag(true)
                        }
                        .help("A comment, or a new thread others can reply to and resolve")
                    }
                    Spacer(minLength: 8)
                    // The approval box has it where the layout has one.
                    if isReview, detail.viewerApproved, session.github.offers(.unapprove), !detail.layout.mergeBoxes {
                        Button {
                            guard let number = model.number else { return }
                            model.perform(.unapprove, on: number, github: session.github)
                        } label: {
                            HStack(spacing: 6) {
                                if model.running == .unapprove { ProgressView().controlSize(.mini) }
                                Text("Revoke Approval")
                            }
                        }
                        .buttonStyle(RowTextButtonStyle(formRow: true))
                        .disabled(model.running != nil)
                        .help("Revoke your approval")
                    }
                    Button {
                        submit(model)
                    } label: {
                        HStack(spacing: 6) {
                            if isBusy(model) { ProgressView().controlSize(.mini) }
                            Text(isReview ? "Submit Review" : startsThread(model) ? "Start Thread" : "Comment")
                        }
                    }
                    .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                    .disabled(!canSubmit(model))
                    .help(isReview && event(model) != .approve && trimmed(model).isEmpty
                          ? "A review that requests changes or comments needs a text" : "")
                }
            }
    }

    /// The review events the provider takes: Request changes only where it has them; Approve not where the approval
    /// box has it (`PRPageLayout.mergeBoxes`).
    private var reviewEvents: [HostedReviewEvent] {
        HostedReviewEvent.all.filter { $0 != .requestChanges || session.github.offers(.requestChanges) }
            .filter { $0 != .approve || !detail.layout.mergeBoxes }
    }

    /// The review event the box submits: the chosen one when offered, else the first offered.
    private func event(_ model: PullRequestDetailModel) -> HostedReviewEvent {
        let events = reviewEvents
        return events.contains(model.reviewEvent) ? model.reviewEvent : events.first ?? .comment
    }

    /// The layout has GitLab's "Comment" / "Start thread" choice and the provider starts threads.
    private var offersStartThread: Bool {
        detail.layout.startThread && session.github.offers(.startThreads)
    }

    private func startsThread(_ model: PullRequestDetailModel) -> Bool {
        offersStartThread && model.startsThread
    }

    private func placeholder(_ model: PullRequestDetailModel) -> String {
        guard model.composer == .review else { return detail.layout.composerPrompt ?? "Leave a comment" }
        return event(model) == .approve ? "Approve, with an optional comment" : "Say what to change"
    }

    private func trimmed(_ model: PullRequestDetailModel) -> String {
        model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isBusy(_ model: PullRequestDetailModel) -> Bool {
        switch model.running {
        case .comment, .review, .startThread: true
        default: false
        }
    }

    private func canSubmit(_ model: PullRequestDetailModel) -> Bool {
        guard model.running == nil else { return false }
        // GitHub requires a body for a change request and a comment review; an approval may have none.
        if model.composer == .review, event(model) == .approve { return true }
        return !trimmed(model).isEmpty
    }

    private func submit(_ model: PullRequestDetailModel) {
        guard canSubmit(model) else { return }
        let body = trimmed(model)
        let action: PullRequestAction = model.composer == .review ? .review(event(model), body: body)
            : startsThread(model) ? .startThread(body) : .comment(body)
        guard let number = model.number else { return }
        model.perform(action, on: number, github: session.github)
    }
}

/// The right column: reviewers, assignees and labels, each in its own card.
private struct PRSideColumn: View {
    let session: RepoSession
    let detail: PullRequestDetail

    var body: some View {
        if detail.layout.sidebar {
            hostSidebar
        } else if detail.layout.bitbucketSidebar {
            PRBitbucketSidebar(session: session, detail: detail) { reviewersCard(HostAvatars.of(session.github)) }
        } else if detail.layout.azureSidebar {
            PRAzureSidebar(session: session, detail: detail)
        } else {
            sideCards
        }
    }

    /// Each reviewer with the state of their latest review.
    private func reviewersCard(_ avatars: HostAvatars) -> some View {
        SectionCard("Reviewers", systemImage: "person.2", count: detail.reviewers.count) {
            if detail.reviewers.isEmpty {
                PRSideEmpty(text: "No reviews")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(detail.reviewers) { reviewer in
                        PRPersonRow(login: reviewer.login, userID: reviewer.userID,
                                    avatarURL: reviewer.avatarURL, avatars: avatars,
                                    state: reviewer.state, showsState: true)
                    }
                }
            }
        }
    }

    /// The host's sidebar (`PRPageLayout.sidebar`), its Edit menus running the detail's add-only actions.
    private var hostSidebar: some View {
        let pull = detail.pull
        let model = session.pullDetail
        let running: HostSidebar.Part? = switch model.busy[pull.number] {
        case .addAssignees: .assignees
        case .requestReviewers: .reviewers
        case .addLabels: .labels
        default: nil
        }
        let approvalNote = detail.approvals.map { approvals -> String in
            guard !approvals.isOptional else { return "Approval is optional" }
            let required = approvals.required ?? 0
            return "Requires \(required) \(required == 1 ? "approval" : "approvals")"
        }
        // GitLab's "N Reviewers" are the merge request's `reviewers`, each with their latest state: someone who only
        // approved is not one.
        let requested = Set((pull.requestedReviewers ?? []).map(\.login))
        return HostSidebar(
            assignees: pull.assignees ?? [], reviewers: detail.reviewers.filter { requested.contains($0.login) },
            approvalNote: approvalNote,
            labels: pull.labels ?? [], milestone: pull.milestone, timeStats: pull.timeStats,
            participants: HostSidebar.participants(
                [pull.user] + (pull.assignees ?? []) + (pull.requestedReviewers ?? []) + detail.comments.map(\.user)
                    + (detail.threads.value?.all ?? []).flatMap { $0.comments.map(\.user) }),
            avatars: .of(session.github), candidates: detail.reviewerCandidates, labelChoices: detail.labelChoices,
            viewer: detail.viewer, canAssign: session.github.offers(.assignees),
            canReview: detail.isOpen && session.github.offers(.reviewRequests),
            canLabel: session.github.offers(.labels), running: running, busy: model.isBusy(pull.number)
        ) { [session] edit in
            let action: PullRequestAction = switch edit {
            case .assign(let user): .addAssignees([user])
            case .review(let user): .requestReviewers([user])
            case .label(let name): .addLabels([name])
            }
            session.pullDetail.perform(action, on: pull.number, github: session.github)
        }
    }

    /// Today's side cards: Reviewers, Assignees and Labels.
    private var sideCards: some View {
        let avatars = HostAvatars.of(session.github)
        return VStack(spacing: SectionCardMetrics.spacing) {
            reviewersCard(avatars)
            if session.github.offers(.assignees) {
                SectionCard("Assignees", systemImage: "person.crop.circle", count: detail.pull.assignees?.count ?? 0) {
                    let assignees = detail.pull.assignees ?? []
                    if assignees.isEmpty {
                        PRSideEmpty(text: "No one assigned")
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(assignees, id: \.id) {
                                PRPersonRow(login: $0.login, userID: $0.id, avatarURL: $0.avatarURL, avatars: avatars,
                                            state: nil, showsState: false)
                            }
                        }
                    }
                }
            }
            if session.github.offers(.labels) {
                SectionCard("Labels", systemImage: "tag", count: detail.pull.labels?.count ?? 0) {
                    let labels = detail.pull.labels ?? []
                    if labels.isEmpty {
                        PRSideEmpty(text: "None yet")
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(labels, id: \.name) { PRLabelChip(label: $0) }
                        }
                    }
                }
            }
            if detail.layout.githubSidebar {
                if let extras = detail.extras {
                    HostProjectsCard(projects: extras.projects, count: extras.projectCount,
                                     host: session.github.kind.name) { [session, number = detail.pull.number] in
                        GitHubLinks.open(session.github.webURL(.pullRequest(number)))
                    }
                }
                gitHubMilestoneAndParticipants(avatars: avatars)
            }
        }
    }

    /// GitHub's sidebar after Labels and Projects: Milestone ("No milestone"), Development (the issues it closes,
    /// where `pullRequestExtras` read them), then Participants (their avatars, as Histq knows them:
    /// `HostSidebar.participants`); Notifications stays on GitHub.
    @ViewBuilder private func gitHubMilestoneAndParticipants(avatars: HostAvatars) -> some View {
        let pull = detail.pull
        SectionCard("Milestone", systemImage: "flag") {
            if let milestone = pull.milestone {
                Text(milestone.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(milestone.title)
            } else {
                PRSideEmpty(text: "No milestone")
            }
        }
        if let issues = detail.extras?.closingIssues { development(issues) }
        let participants = HostSidebar.participants(
            [pull.user] + (pull.assignees ?? []) + (pull.requestedReviewers ?? []) + detail.comments.map(\.user)
                + detail.reviews.map(\.user) + (detail.threads.value?.all ?? []).flatMap { $0.comments.map(\.user) })
        SectionCard("Participants", systemImage: "person.3", count: participants.count) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 22, maximum: 22), spacing: 6)], alignment: .leading,
                      spacing: 6) {
                ForEach(participants, id: \.login) { user in
                    GitHubUserAvatar(login: user.login, id: user.id, avatarURL: user.avatarURL, size: 22,
                                     avatars: avatars)
                        .help(user.login)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Participants: " + participants.map(\.login).joined(separator: ", ")))
        }
    }
}

extension PRSideColumn {
    /// GitHub's Development card: the issues the pull request closes when merged, each a click target (one of this
    /// repository opens in the detail, another's on the host); "No linked issues" without any.
    fileprivate func development(_ issues: [HostedPullRequestExtras.ClosingIssue]) -> some View {
        let repository = session.github.api?.repository.fullName
        return SectionCard("Development", systemImage: "arrow.triangle.branch", count: issues.count) {
            if issues.isEmpty {
                PRSideEmpty(text: "No linked issues")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(issues, id: \.self) { issue in
                        let local = issue.repository.lowercased() == repository?.lowercased()
                        Button {
                            if local {
                                session.selectHosted(.issue(issue.number))
                            } else if let url = issue.url.flatMap(URL.init(string:)),
                                      url.host()?.lowercased() == session.github.api?.repository.host.lowercased() {
                                // Only a link on the account's own host.
                                GitHubLinks.open(url)
                            }
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: issue.isOpen ? "circle.circle" : "checkmark.circle")
                                    .font(.settingsCaption)
                                    .foregroundStyle(issue.isOpen ? Color(nsColor: Palette.diffAddedSign)
                                                     : Palette.mergedTone)
                                    .accessibilityHidden(true)
                                Text(verbatim: (local ? "" : issue.repository) + "#\(issue.number) \(issue.title)")
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(local ? "Open issue #\(issue.number)" : "Open on \(session.github.kind.name)")
                        .accessibilityLabel(Text("Issue \(issue.number), \(issue.title), "
                            + (issue.isOpen ? "open" : "closed")))
                    }
                }
            }
        }
    }
}

/// Bitbucket's sidebar (`PRPageLayout.bitbucketSidebar`), in its order: Builds (the head's statuses), Merge checks,
/// Reviewers, Tasks (list, add, resolve or reopen, delete: each shown at once), Jira work items (on Bitbucket, with
/// `jiraCard`). A part
/// whose read failed shows that it could not be read; Merge checks and Tasks are left out where the host has none.
private struct PRBitbucketSidebar<Reviewers: View>: View {
    let session: RepoSession
    let detail: PullRequestDetail
    @ViewBuilder let reviewers: () -> Reviewers

    var body: some View {
        VStack(spacing: SectionCardMetrics.spacing) {
            builds
            if detail.reports != .idle { reports }
            if let checks = detail.mergeChecks { mergeChecks(checks) }
            reviewers()
            if let tasks = detail.tasks { tasksCard(tasks) }
            if detail.layout.jiraCard {
                SectionCard("Jira work items", systemImage: "link") {
                    PRSideEmpty(text: "Shown on \(session.github.kind.name)")
                } accessory: {
                    openOnHost(help: "Open the Jira work items on \(session.github.kind.name)")
                }
            }
        }
    }

    private var builds: some View {
        let runs = detail.checks.value ?? []
        let passed = runs.count { $0.status == "completed" && $0.conclusion == "success" }
        return SectionCard("Builds", systemImage: "hammer", count: runs.count) {
            switch detail.checks {
            case .loaded(let runs) where runs.isEmpty: PRSideEmpty(text: "No builds")
            case .loaded(let runs):
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(passed) of \(runs.count) \(runs.count == 1 ? "build" : "builds") passed")
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                    ForEach(runs) { run in
                        Button { GitHubLinks.open(run.htmlURL) } label: {
                            PRSideStatusRow(symbol: Self.symbol(run), tone: Self.tone(run), text: run.name)
                        }
                        .buttonStyle(.plain)
                        .disabled(run.htmlURL == nil)
                        .help(run.htmlURL == nil ? run.name : "Open \(run.name)")
                    }
                }
            case .failed: PRSideEmpty(text: "Could not be read")
            case .loading, .idle: PRSideEmpty(text: "Loading…")
            }
        }
    }

    /// Bitbucket's Reports (Code Insights on the head): "N of M reports passed", each report's result and title, a
    /// click opening its page.
    private var reports: some View {
        let list = detail.reports.value ?? []
        let passed = list.count { $0.result == "PASSED" }
        return SectionCard("Reports", systemImage: "doc.text.magnifyingglass", count: list.count) {
            switch detail.reports {
            case .loaded(let list) where list.isEmpty: PRSideEmpty(text: "No reports")
            case .loaded(let list):
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(passed) of \(list.count) \(list.count == 1 ? "report" : "reports") passed")
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                    ForEach(list) { report in
                        let (symbol, tone): (String, Color?) = switch report.result {
                        case "PASSED": ("checkmark.circle.fill", Color(nsColor: Palette.diffAddedSign))
                        case "FAILED": ("xmark.circle.fill", Color(nsColor: Palette.diffRemovedSign))
                        case "PENDING": ("circle.dotted", Palette.conflictTone)
                        default: ("minus.circle", nil)
                        }
                        Button { GitHubLinks.open(report.link) } label: {
                            PRSideStatusRow(symbol: symbol, tone: tone, text: report.title)
                        }
                        .buttonStyle(.plain)
                        .disabled(report.link == nil)
                        .help(report.link == nil ? report.title : "Open \(report.title)")
                    }
                }
            case .failed: PRSideEmpty(text: "Could not be read")
            case .loading, .idle: PRSideEmpty(text: "Loading…")
            }
        }
    }

    private func mergeChecks(_ checks: [HostedMergeCheck]) -> some View {
        let passed = checks.count { $0.status == "PASSED" }
        return SectionCard("Merge checks", systemImage: "checklist", count: checks.count) {
            if checks.isEmpty {
                PRSideEmpty(text: "No merge checks")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(passed) of \(checks.count) \(checks.count == 1 ? "check" : "checks") passed")
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                        PRMergeCheckRow(check: check)
                    }
                }
            }
        }
    }

    /// The tasks, each with its box (a click resolves or reopens it) and a delete button, then a field that adds one.
    private func tasksCard(_ tasks: [HostedTask]) -> some View {
        let model = session.pullDetail
        let number = detail.pull.number
        let busy = model.isBusy(number)
        let open = tasks.count { !$0.isResolved }
        return SectionCard("Tasks", systemImage: "checkmark.square", count: open) {
            VStack(alignment: .leading, spacing: 6) {
                if tasks.isEmpty { PRSideEmpty(text: "No tasks") }
                ForEach(tasks) { task in
                    let pending = PRPlaceholderID.isPlaceholder(task.id)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Button {
                            model.perform(.setTask(id: task.id, resolved: !task.isResolved), on: number,
                                          github: session.github)
                        } label: {
                            Image(systemName: task.isResolved ? "checkmark.square.fill" : "square")
                                .foregroundStyle(task.isResolved ? Color(nsColor: Palette.diffAddedSign) : .secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(busy || pending)
                        .accessibilityLabel(task.isResolved ? "Reopen the task" : "Resolve the task")
                        Text(task.body)
                            .font(.callout)
                            .strikethrough(task.isResolved)
                            .foregroundStyle(task.isResolved ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            model.perform(.deleteTask(id: task.id), on: number, github: session.github)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(RowIconButtonStyle())
                        .disabled(busy || pending)
                        .help("Delete the task")
                        .accessibilityLabel("Delete the task")
                    }
                }
                @Bindable var model = model
                // Typing stays open while another action runs; only sending waits for it.
                TextField("Create a task", text: $model.taskDraft, prompt: Text("Create a task"))
                    .textFieldStyle(.settings)
                    .onSubmit {
                        let text = model.taskDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty, !model.isBusy(number) else { return }
                        model.taskDraft = ""
                        model.perform(.createTask(text), on: number, github: session.github)
                    }
            }
        }
    }

    private func openOnHost(help: String) -> some View {
        Button {
            GitHubLinks.open(session.github.webURL(.pullRequest(detail.pull.number)))
        } label: {
            Image(systemName: "arrow.up.forward.square")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(RowIconButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    private static func symbol(_ run: HostedCheckRun) -> String {
        guard run.status == "completed" else { return "circle.dotted" }
        return run.conclusion == "success" ? "checkmark.circle.fill"
            : ["failure", "timed_out", "cancelled"].contains(run.conclusion ?? "") ? "xmark.circle.fill" : "minus.circle"
    }

    private static func tone(_ run: HostedCheckRun) -> Color? {
        guard run.status == "completed" else { return Palette.conflictTone }
        return run.conclusion == "success" ? Color(nsColor: Palette.diffAddedSign)
            : ["failure", "timed_out", "cancelled"].contains(run.conclusion ?? "")
                ? Color(nsColor: Palette.diffRemovedSign) : nil
    }
}

/// A merge check's row (Bitbucket's Merge checks card, Azure DevOps's merge area): passed, failed, pending or other,
/// its name, and whether it blocks the merge as its tooltip.
private struct PRMergeCheckRow: View {
    let check: HostedMergeCheck

    var body: some View {
        let (symbol, tone): (String, Color?) = switch check.status {
        case "PASSED": ("checkmark.circle.fill", Color(nsColor: Palette.diffAddedSign))
        case "FAILED": ("xmark.circle.fill", Color(nsColor: Palette.diffRemovedSign))
        case "PENDING": ("circle.dotted", Palette.conflictTone)
        default: ("minus.circle", nil)
        }
        PRSideStatusRow(symbol: symbol, tone: tone, text: check.name)
            .help(check.blocking ? "Blocks the merge" : check.required ? "Required" : check.name)
    }
}

/// Azure DevOps's sidebar (`PRPageLayout.azureSidebar`): Reviewers under "Required" and "Optional", each with its
/// vote as Azure words it (`HostedReview.vote`, `isRequired`), then Tags (the labels, read-only: Azure keeps no list of
/// tags to pick from).
private struct PRAzureSidebar: View {
    let session: RepoSession
    let detail: PullRequestDetail

    var body: some View {
        let avatars = HostAvatars.of(session.github)
        let reviews = detail.reviews.filter { $0.vote != nil && $0.user != nil }
        let labels = detail.pull.labels ?? []
        VStack(spacing: SectionCardMetrics.spacing) {
            SectionCard("Reviewers", systemImage: "person.2", count: reviews.count) {
                VStack(alignment: .leading, spacing: 10) {
                    group("Required", reviews.filter { $0.isRequired == true }, empty: "No required reviewers",
                          avatars: avatars)
                    group("Optional", reviews.filter { $0.isRequired != true }, empty: "No optional reviewers",
                          avatars: avatars)
                }
            }
            SectionCard("Tags", systemImage: "tag", count: labels.count) {
                if labels.isEmpty {
                    PRSideEmpty(text: "No tags")
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(labels, id: \.name) { PRLabelChip(label: $0) }
                    }
                }
            }
        }
    }

    private func group(_ title: String, _ reviews: [HostedReview], empty: String, avatars: HostAvatars)
        -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.settingsCaption.weight(.semibold))
                .foregroundStyle(.secondary)
            if reviews.isEmpty { PRSideEmpty(text: empty) }
            ForEach(reviews, id: \.id) { review in
                let user = review.user ?? HostedUser(id: 0, login: "ghost")
                let (words, symbol, tone) = Self.vote(review.vote ?? 0)
                HStack(spacing: 8) {
                    GitHubUserAvatar(login: user.login, id: user.id, avatarURL: user.avatarURL, size: 22,
                                     avatars: avatars)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(user.name ?? user.login)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(words)
                            .font(.settingsCaption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: symbol)
                        .foregroundStyle(tone.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// A vote as Azure DevOps words it, its symbol and tone: 10 approved, 5 approved with suggestions, -5 waiting for
    /// the author, -10 rejected, else no vote.
    private static func vote(_ vote: Int) -> (String, String, Color?) {
        switch vote {
        case 10: ("Approved", "checkmark.circle.fill", Color(nsColor: Palette.diffAddedSign))
        case 5: ("Approved with suggestions", "checkmark.circle.fill", Color(nsColor: Palette.diffAddedSign))
        case -5: ("Waiting for author", "clock.fill", Palette.conflictTone)
        case -10: ("Rejected", "xmark.circle.fill", Color(nsColor: Palette.diffRemovedSign))
        default: ("No vote", "circle", nil)
        }
    }
}

/// A side card's status row: a symbol in its tone (gray without one) and a line of text.
private struct PRSideStatusRow: View {
    let symbol: String
    let tone: Color?
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.settingsCaption)
                .foregroundStyle(tone.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
    }
}

/// A Projects side card (GitHub's, pull request and issue): the projects' titles, only their count when the token may
/// not read them (`read:project`), and a button that opens the item on the host, where projects are set.
struct HostProjectsCard: View {
    let projects: [String]?
    let count: Int?
    /// The host's name ("GitHub").
    let host: String
    let openOnHost: () -> Void

    var body: some View {
        SectionCard("Projects", systemImage: "tablecells", count: count ?? projects?.count) {
            if let projects {
                if projects.isEmpty {
                    PRSideEmpty(text: "No projects")
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        // By position: two projects (an organization's, a user's) may share a title.
                        ForEach(Array(projects.enumerated()), id: \.offset) { _, title in
                            Text(title).lineLimit(1).truncationMode(.tail).help(title)
                        }
                    }
                }
            } else if let count {
                PRSideEmpty(text: count == 0 ? "No projects"
                            : "In \(count) \(count == 1 ? "project" : "projects") (names need the read:project "
                                + "permission)")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                PRSideEmpty(text: "Could not be read")
            }
        } accessory: {
            Button(action: openOnHost) {
                Image(systemName: "arrow.up.forward.square")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(RowIconButtonStyle())
            .help("Set projects on \(host)")
            .accessibilityLabel("Set projects on \(host)")
        }
    }
}

/// What the host's sidebar changes (`HostSidebar`), each add-only: assign a user, ask a user to review, add a label.
enum HostSidebarEdit: Equatable {
    case assign(HostedUser)
    case review(HostedUser)
    case label(String)
}

/// GitLab's right sidebar (`PRPageLayout.sidebar`) on the merge request and issue pages, in GitLab's order and words,
/// only what the API gives (the plan's phase 15 element map): "N Assignees" (Edit, "None - assign yourself"), on a
/// merge request "N Reviewers" (Edit, "Approval is optional · Assign", "None - assign yourself"), Labels (Edit),
/// Milestone, Time tracking (`time_stats`, where the host sent it) and "N Participants" (their avatars). Each part is a
/// card of its own. The Edit menus only add (assign, ask to review, add a label: the writes the client has); a click
/// shows its action running at once and the write runs off the main actor (the detail's model).
struct HostSidebar: View {
    enum Part: Equatable { case assignees, reviewers, labels }

    let assignees: [HostedUser]
    /// nil: no Reviewers part (an issue).
    let reviewers: [PRReviewer]?
    /// "Approval is optional" or "Requires 2 approvals"; nil when the approvals are unknown.
    let approvalNote: String?
    let labels: [HostedLabel]
    let milestone: HostedMilestone?
    /// nil: no Time tracking part (the host did not send it).
    let timeStats: HostedTimeStats?
    let participants: [HostedUser]
    let avatars: HostAvatars
    /// Who may be assigned or asked to review, and the project's labels: empty, no menu.
    let candidates: [HostedUser]
    let labelChoices: [HostedLabel]
    /// The token's user: nil, no "assign yourself".
    let viewer: HostedUser?
    /// The provider takes the write (and, for review requests, the item is open).
    let canAssign: Bool
    let canReview: Bool
    let canLabel: Bool
    /// The part whose edit runs now; `busy`: an action runs on the item, every edit is off.
    let running: Part?
    let busy: Bool
    let perform: (HostSidebarEdit) -> Void

    var body: some View {
        VStack(spacing: SectionCardMetrics.spacing) {
            SectionCard(Self.counted(assignees.count, "Assignee"), systemImage: "person.crop.circle") {
                people(assignees.map { ($0.login, $0.id, $0.avatarURL, nil) }, showsState: false,
                       yourself: canAssign ? viewer.map { viewer in { perform(.assign(viewer)) } } : nil)
            } accessory: {
                userMenu(.assignees, title: "Edit", enabled: canAssign, taken: assignees.map(\.login)) {
                    perform(.assign($0))
                }
            }
            if let reviewers {
                SectionCard(Self.counted(reviewers.count, "Reviewer"), systemImage: "person.2") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let approvalNote {
                            HStack(spacing: 8) {
                                Text(approvalNote)
                                    .font(.settingsCaption)
                                    .foregroundStyle(.secondary)
                                userMenu(.reviewers, title: "Assign", enabled: canReview,
                                         taken: reviewers.map(\.login), spinner: false) { perform(.review($0)) }
                            }
                        }
                        people(reviewers.map { ($0.login, $0.userID, $0.avatarURL, $0.state) }, showsState: true,
                               yourself: canReview ? viewer.map { viewer in { perform(.review(viewer)) } } : nil)
                    }
                } accessory: {
                    userMenu(.reviewers, title: "Edit", enabled: canReview, taken: reviewers.map(\.login)) {
                        perform(.review($0))
                    }
                }
            }
            SectionCard("Labels", systemImage: "tag") {
                if labels.isEmpty {
                    PRSideEmpty(text: "None")
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(labels, id: \.name) { PRLabelChip(label: $0) }
                    }
                }
            } accessory: {
                labelMenu
            }
            SectionCard("Milestone", systemImage: "flag") {
                if let milestone {
                    Text(milestone.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(milestone.dueDate.map { "\(milestone.title), due \($0)" } ?? milestone.title)
                } else {
                    PRSideEmpty(text: "None")
                }
            }
            if let timeStats {
                SectionCard("Time tracking", systemImage: "timer") {
                    if timeStats.isEmpty {
                        PRSideEmpty(text: "No estimate or time spent")
                    } else {
                        // GitLab's one row: "Spent: 45m" at the start, "Est: 1h 30m" at the end.
                        HStack(spacing: 8) {
                            if timeStats.spent > 0 {
                                Text("Spent: \(timeStats.humanSpent ?? Self.duration(timeStats.spent))")
                            }
                            Spacer(minLength: 0)
                            if timeStats.estimate > 0 {
                                Text("Est: \(timeStats.humanEstimate ?? Self.duration(timeStats.estimate))")
                                    .help("Estimate")
                            }
                        }
                        .font(.settingsCaption)
                        .lineLimit(1)
                    }
                }
            }
            SectionCard(Self.counted(participants.count, "Participant"), systemImage: "person.3") {
                if participants.isEmpty {
                    PRSideEmpty(text: "None")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 22, maximum: 22), spacing: 6)],
                              alignment: .leading, spacing: 6) {
                        ForEach(participants, id: \.login) { user in
                            GitHubUserAvatar(login: user.login, id: user.id, avatarURL: user.avatarURL, size: 22,
                                             avatars: avatars)
                                .help(user.name.map { "\($0) (@\(user.login))" } ?? user.login)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Participants: " + participants.map(\.login).joined(separator: ", ")))
                }
            }
        }
    }

    /// "0 Assignees", "1 Assignee": GitLab's titles.
    static func counted(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// Everyone in `users` once (by login), in order, without the deleted accounts: the participants as Histq knows
    /// them (the author, the assignees and reviewers, whoever commented), no request of their own.
    static func participants(_ users: [HostedUser?]) -> [HostedUser] {
        var seen = Set<String>()
        return users.compactMap { $0 }.filter { seen.insert($0.login).inserted }
    }

    /// Seconds as "1h 30m" (GitLab sends its own words; this is for a host that does not).
    private static func duration(_ seconds: Int) -> String {
        let hours = seconds / 3600, minutes = seconds % 3600 / 60
        return [hours > 0 ? "\(hours)h" : nil, minutes > 0 || hours == 0 ? "\(minutes)m" : nil]
            .compactMap { $0 }.joined(separator: " ")
    }

    /// The people of a part, or "None - assign yourself" (`yourself`: the click, nil for "None" alone).
    @ViewBuilder private func people(
        _ list: [(login: String, id: Int?, avatarURL: String?, state: String?)], showsState: Bool,
        yourself: (() -> Void)?
    ) -> some View {
        if list.isEmpty {
            HStack(spacing: 6) {
                PRSideEmpty(text: yourself == nil ? "None" : "None -")
                if let yourself {
                    Button("assign yourself", action: yourself)
                        .buttonStyle(BottomBarButtonStyle(height: 22, horizontalPadding: 9))
                        .font(.settingsCaption)
                        .fixedSize()
                        .disabled(busy)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(list, id: \.login) { person in
                    PRPersonRow(login: person.login, userID: person.id, avatarURL: person.avatarURL, avatars: avatars,
                                state: person.state, showsState: showsState)
                }
            }
        }
    }

    /// A part's menu of the users not `taken` yet, each added with one click; none when the write or the list is
    /// missing. `spinner`: it shows its part's edit running.
    @ViewBuilder private func userMenu(
        _ part: Part, title: String, enabled: Bool, taken: [String], spinner: Bool = true,
        add: @escaping (HostedUser) -> Void
    ) -> some View {
        let open = candidates.filter { !taken.contains($0.login) }
        if enabled, !candidates.isEmpty {
            Menu {
                ForEach(open, id: \.login) { user in
                    Button(user.name.map { "\($0) (@\(user.login))" } ?? user.login) { add(user) }
                }
            } label: {
                menuLabel(title, running: spinner && running == part)
            }
            .menuStyle(.button)
            .buttonStyle(BottomBarButtonStyle(height: 22, horizontalPadding: 10, menu: true))
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(busy || open.isEmpty)
            .help(open.isEmpty ? "Everyone is added already" : title == "Edit" ? "Add someone" : "Ask someone to review")
        }
    }

    /// The Labels part's menu of the project's labels not on the item yet.
    @ViewBuilder private var labelMenu: some View {
        let taken = Set(labels.map(\.name))
        let open = labelChoices.filter { !taken.contains($0.name) }
        if canLabel, !labelChoices.isEmpty {
            Menu {
                ForEach(open, id: \.name) { label in
                    Button(label.name) { perform(.label(label.name)) }
                }
            } label: {
                menuLabel("Edit", running: running == .labels)
            }
            .menuStyle(.button)
            .buttonStyle(BottomBarButtonStyle(height: 22, horizontalPadding: 10, menu: true))
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(busy || open.isEmpty)
            .help(open.isEmpty ? "Every label is added already" : "Add a label")
        }
    }

    private func menuLabel(_ title: String, running: Bool) -> some View {
        HStack(spacing: 6) {
            if running { ProgressView().controlSize(.mini) }
            Text(title)
                .font(.settingsCaption)
                .lineLimit(1)
        }
    }
}

/// The merge box under the timeline, as on GitHub: for an open pull request, a status box saying whether its branch
/// merges (green, red with conflicts, amber when blocked, neutral otherwise) and Merge (method, then a confirmation);
/// then Checkout locally, Close or Reopen (confirmed), and the running action. With conflicts, the red box holds
/// Resolve with AI and Resolve manually. On GitLab's layout (`PRPageLayout.mergeBoxes`) the same actions make GitLab's
/// merge box under the approval box instead (`mergeBoxCard`).
private struct PRActionsCard: View {
    let session: RepoSession
    let detail: PullRequestDetail
    @Environment(WindowModel.self) private var model

    #if DEBUG
    /// DEBUG `-HistqPRAction resolve-manual`: clicks Resolve manually once, as soon as it can start (the status read,
    /// no other operation running). Only with `-HistqGitHubStub YES`, like the detail's other launch actions.
    @MainActor private static var launchResolve = GitHubStub.isEnabled
        && AppState.launchFlag("-HistqPRAction") == "resolve-manual"
    #endif

    var body: some View {
        if detail.layout.mergeBoxes {
            mergeBoxCard
        } else if detail.layout.githubMergeBox {
            gitHubMergeCard
        } else if detail.layout.bitbucketMergeArea {
            bitbucketMergeCard
        } else {
            actionsCard
        }
    }

    /// The Actions card under the timeline (every layout but GitLab's).
    @ViewBuilder private var actionsCard: some View {
        let pull = detail.pull
        let busy = session.pullDetail.busy[pull.number]
        SectionCard("Actions", systemImage: "bolt") {
            VStack(alignment: .leading, spacing: 10) {
                if detail.isMerged {
                    mergedBox
                } else if detail.isOpen {
                    statusBox(status)
                }
                // One row in a wide column; narrower, the merge controls above the other buttons, side by side or
                // under each other.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        if detail.isOpen {
                            mergeControls(busy: busy)
                            Spacer(minLength: 8)
                        }
                        otherButtons(busy: busy)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        if detail.isOpen { HStack(spacing: 8) { mergeControls(busy: busy) } }
                        HStack(spacing: 8) { otherButtons(busy: busy) }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        if detail.isOpen { HStack(spacing: 8) { mergeControls(busy: busy) } }
                        otherButtons(busy: busy)
                    }
                }
                if case .unavailable(let reason) = checkoutWay {
                    Text(reason)
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let busy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(busy.progressTitle)
                            .font(.settingsCaption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// How the provider fetches this pull request's head (GitHub: `pull/<n>/head`); nil without a connected remote.
    private var checkoutWay: HostedCheckout? { session.github.api?.client.checkout(of: detail.pull) }

    /// GitHub's answer for an open pull request, from `mergeable` and `mergeable_state`: conflicts first, then a draft,
    /// a blocked or out-of-date branch, then a clean merge. `mergeable` true with any other state (`clean`, `unstable`,
    /// `has_hooks`, or none, as from the stub) merges; nil is GitHub still computing it.
    private var status: Status {
        let pull = detail.pull
        let base = pull.base.ref
        if hasConflicts {
            return (Color(nsColor: Palette.diffRemovedSign), "exclamationmark.triangle.fill",
                    detail.layout.words.conflicts ?? "This branch has conflicts that must be resolved",
                    "Resolve the conflicts with \(base) to merge it.")
        }
        if pull.draft == true {
            let kind = session.github.kind
            return (nil, "circle.dashed", "This \(kind.pullRequestNoun.lowercased()) is still a draft",
                    "Mark it ready for review on \(kind.name) to merge it.")
        }
        switch pull.mergeableState {
        case "blocked":
            return (Palette.conflictTone, "lock.fill", "Merging is blocked",
                    "Required reviews or checks have not passed yet.")
        case "behind":
            return (nil, "arrow.down.circle", "This branch is out-of-date with \(base)",
                    "Merge the latest changes from \(base) into it.")
        default:
            break
        }
        if mergesCleanly {
            return (Color(nsColor: Palette.diffAddedSign), "checkmark.circle.fill",
                    detail.layout.words.noConflicts ?? "No conflicts with \(base)", "This branch can be merged.")
        }
        let kind = session.github.kind
        guard kind.reportsMergeability else {
            return (nil, "info.circle", "\(kind.name) checks for conflicts when you merge",
                    "It refuses the merge if this branch conflicts with \(base).")
        }
        return (nil, "clock", "Checking whether this branch can be merged…", nil)
    }

    /// GitHub says the branch conflicts with its base: one test for the red box, its Resolve buttons and Merge off.
    private var hasConflicts: Bool {
        detail.pull.mergeable == false || detail.pull.mergeableState == "dirty"
    }

    /// GitHub says the branch merges as it is: the status box is green, and only then Merge too. Blocked, out of date
    /// or still checking keeps Merge neutral but on, since GitHub itself refuses a merge it cannot do.
    private var mergesCleanly: Bool {
        let pull = detail.pull
        return pull.mergeable == true && pull.draft != true
            && !["dirty", "blocked", "behind"].contains(pull.mergeableState ?? "")
    }

    /// A merged pull request: "Merged into <base>" and when, in a purple box like the open one's status, so the merge
    /// reads at a glance (user, 2026-11-20: the grey line was easy to miss).
    private var mergedBox: some View {
        let pull = detail.pull
        let shape = RoundedRectangle(cornerRadius: SettingsInputMetrics.cornerRadius, style: .continuous)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.mergedTone)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Merged into \(pull.base.ref)")
                    .font(.body.weight(.semibold))
                if let date = pull.mergedAt {
                    let dates = PRPageDates(now: detail.now)
                    Text(verbatim: dates.relative(date))
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                        .help(dates.absolute(date))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Palette.mergedTone.opacity(0.14)))
        .overlay(shape.strokeBorder(Palette.mergedTone.opacity(0.35), lineWidth: 1))
    }

    /// The status in a box tinted with its tone (neutral without one), so whether the branch merges reads at a glance
    /// (user, 2026-11-17). The red one holds the Resolve buttons under its text. `expanded`: GitLab's merge box, whose
    /// chevron shows or hides its details.
    private func statusBox(_ status: Status, expanded: Binding<Bool>? = nil, details: AnyView? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: SettingsInputMetrics.cornerRadius, style: .continuous)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: status.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(status.tone.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.title)
                        .font(.body.weight(.semibold))
                    if let note = status.note {
                        Text(note)
                            .font(.settingsCaption)
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                // The text reads as one element; the buttons under it stay buttons.
                .accessibilityElement(children: .combine)
                if hasConflicts { resolveControls }
                if let details { details }
            }
            if let expanded {
                Spacer(minLength: 8)
                Button { expanded.wrappedValue.toggle() } label: {
                    Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(RowIconButtonStyle())
                .help(expanded.wrappedValue ? "Hide the details" : "Show the details")
                .accessibilityLabel(Text(expanded.wrappedValue ? "Hide the details" : "Show the details"))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(status.tone?.opacity(0.14) ?? Palette.tabFill))
        .overlay(shape.strokeBorder(status.tone?.opacity(0.35) ?? Palette.surfaceBorder, lineWidth: 1))
    }

    private typealias Status = (tone: Color?, symbol: String, title: String, note: String?)

    // MARK: Bitbucket's merge area

    /// Bitbucket's merge area first on the Overview: for an open pull request, its state (conflicts, draft…), then
    /// the pull request's own strategies, Close source branch (a branch of this repository only) and Merge, with the
    /// other buttons; for a merged one, "Merged pull request"; for a declined one, its state.
    @ViewBuilder private var bitbucketMergeCard: some View {
        let pull = detail.pull
        let busy = session.pullDetail.busy[pull.number]
        SectionCard(nil) {
            VStack(alignment: .leading, spacing: 10) {
                if detail.isMerged {
                    bitbucketMergedBox
                } else if detail.isOpen {
                    statusBox(status)
                } else {
                    let abandoned = detail.layout.words.abandoned
                    statusBox((Color(nsColor: Palette.diffRemovedSign), "xmark.circle.fill", abandoned ?? "Declined",
                               "This pull request was \(abandoned?.lowercased() ?? "declined")."))
                }
                if detail.isOpen, detail.layout.mergeChecksInMergeArea, let checks = detail.mergeChecks,
                   !checks.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                            PRMergeCheckRow(check: check)
                        }
                    }
                    .padding(.leading, 4)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        if detail.isOpen {
                            mergeControls(busy: busy)
                            closeSourceBranchToggle
                            Spacer(minLength: 8)
                        }
                        otherButtons(busy: busy)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        if detail.isOpen {
                            HStack(spacing: 8) { mergeControls(busy: busy) }
                            closeSourceBranchToggle
                        }
                        HStack(spacing: 8) { otherButtons(busy: busy) }
                    }
                }
                if case .unavailable(let reason) = checkoutWay {
                    Text(reason)
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let busy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(busy.progressTitle)
                            .font(.settingsCaption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Bitbucket's "Close source branch": only for a branch of this repository, set as the pull request was created
    /// until the user changes it. Data Center's (`deleteSourceBranchTitle`): unchecked until the user checks it, where
    /// its client deletes the branch.
    @ViewBuilder private var closeSourceBranchToggle: some View {
        let pull = detail.pull
        let title = detail.layout.deleteSourceBranchTitle
        let offered = title == nil ? pull.closesSourceBranch != nil
            : session.github.api?.client.supportedMergeOptions.contains(.deleteSourceBranch) == true
        if pull.isFromSameRepository, offered {
            let model = session.pullDetail
            Toggle(title ?? "Close source branch", isOn: Binding(
                get: { model.closeSourceBranchChoice ?? pull.closesSourceBranch ?? false },
                set: { model.closeSourceBranchChoice = $0 }))
                .toggleStyle(.checkbox)
                .fixedSize()
                .help("Delete \(pull.head.ref) on \(session.github.kind.name) once merged")
        }
    }

    /// Bitbucket's "Merged pull request": "Merged in <source> (pull request #N)", then the merge commit's short hash,
    /// the builds, the author, who closed it and when, in the merged purple.
    private var bitbucketMergedBox: some View {
        let pull = detail.pull
        let shape = RoundedRectangle(cornerRadius: SettingsInputMetrics.cornerRadius, style: .continuous)
        let dates = PRPageDates(now: detail.now)
        var facts: [String] = []
        if let sha = pull.mergeCommitSHA { facts.append(String(sha.prefix(7))) }
        if let runs = detail.checks.value, !runs.isEmpty { facts.append("\(runs.count) \(runs.count == 1 ? "build" : "builds")") }
        if let author = pull.user { facts.append("Author: \(author.name ?? author.login)") }
        if let closer = pull.mergedBy { facts.append("Closed by: \(closer.name ?? closer.login)") }
        if let date = pull.mergedAt { facts.append(dates.relative(date)) }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.mergedTone)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(detail.layout.words.completed ?? "Merged pull request")
                    .font(.body.weight(.semibold))
                Text(verbatim: "Merged in \(pull.head.ref) (pull request #\(pull.number))")
                    .font(.callout)
                Text(verbatim: facts.joined(separator: " · "))
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                    .help(pull.mergedAt.map(dates.absolute) ?? "")
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Palette.mergedTone.opacity(0.14)))
        .overlay(shape.strokeBorder(Palette.mergedTone.opacity(0.35), lineWidth: 1))
    }

    // MARK: GitHub's merge box

    /// GitHub's merge box after the timeline: for an open pull request, the reviews and checks rows over the merge
    /// state (Update branch under an out-of-date one), then the merge method, Merge and the other buttons as in the
    /// Actions card; for a merged one, GitHub's merged box with Delete branch / Restore branch.
    @ViewBuilder private var gitHubMergeCard: some View {
        let pull = detail.pull
        let busy = session.pullDetail.busy[pull.number]
        SectionCard(nil) {
            VStack(alignment: .leading, spacing: 10) {
                if detail.isMerged {
                    gitHubMergedBox(busy: busy)
                } else if detail.isOpen {
                    statusBox(status, details: pull.mergeableState == "behind"
                        && session.github.offers(.updateBranch) ? AnyView(updateBranchButton(busy: busy)) : nil)
                    gitHubColumns
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        if detail.isOpen {
                            mergeControls(busy: busy)
                            Spacer(minLength: 8)
                        }
                        otherButtons(busy: busy)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        if detail.isOpen { HStack(spacing: 8) { mergeControls(busy: busy) } }
                        HStack(spacing: 8) { otherButtons(busy: busy) }
                    }
                }
                if case .unavailable(let reason) = checkoutWay {
                    Text(reason)
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let busy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(busy.progressTitle)
                            .font(.settingsCaption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// GitHub's three columns under the merge state: Checks, Comments and Approvals, each its word, a line of what
    /// stands and a bar of how far it got (the checks that passed, the conversations resolved, the reviewers who
    /// approved), side by side, under each other when the column is narrow.
    private var gitHubColumns: some View {
        let columns = [checksColumn, commentsColumn, approvalsColumn]
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(columns.indices, id: \.self) { PRMergeColumn(column: columns[$0]).frame(minWidth: 150) }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(columns.indices, id: \.self) { PRMergeColumn(column: columns[$0]) }
            }
        }
    }

    /// The checks of the head: how many are done (passed, skipped or neutral) of those that ran; "No checks" without
    /// runs, "Loading…" while they load, "Could not be read" when their read failed.
    private var checksColumn: PRMergeColumn.Column {
        let title = "Checks"
        let runs: [HostedCheckRun]
        switch detail.checks {
        case .loaded(let loaded) where !loaded.isEmpty: runs = loaded
        case .loaded: return (title, "No checks", nil, nil)
        case .failed: return (title, "Could not be read", nil, nil)
        case .loading, .idle: return (title, "Loading…", nil, nil)
        }
        let status = checksStatus
        // Skipped and neutral runs are done, as the status line counts them.
        let done = runs.count {
            $0.status == "completed" && ["success", "skipped", "neutral"].contains($0.conclusion ?? "")
        }
        return (title, status?.note ?? "", status?.tone, Double(done) / Double(runs.count))
    }

    /// The review conversations: how many are left to resolve; "No conversations" without threads.
    private var commentsColumn: PRMergeColumn.Column {
        let threads = detail.threads.value?.all ?? []
        guard !threads.isEmpty else { return ("Comments", "No conversations", nil, nil) }
        if detail.threads.value?.statesFailed == true {
            return ("Comments", "\(threads.count) \(threads.count == 1 ? "conversation" : "conversations"), "
                + "resolution unknown", nil, nil)
        }
        let resolved = threads.count { $0.state?.isResolved == true }
        let open = threads.count - resolved
        let tone = open == 0 ? Color(nsColor: Palette.diffAddedSign) : Palette.conflictTone
        return ("Comments", open == 0 ? "All conversations resolved" : "\(open) unresolved", tone,
                Double(resolved) / Double(threads.count))
    }

    /// The reviewers: how many approved and how many are pending (requested, no review yet), changes requested first.
    private var approvalsColumn: PRMergeColumn.Column {
        let reviewers = detail.reviewers
        guard !reviewers.isEmpty else { return ("Approvals", "No reviewers", nil, nil) }
        let approved = reviewers.count { $0.state == "APPROVED" }
        let changes = reviewers.count { $0.state == "CHANGES_REQUESTED" }
        let pending = reviewers.count { $0.state == nil }
        var parts: [String] = []
        if changes > 0 { parts.append("\(changes) requested changes") }
        if approved > 0 { parts.append("\(approved) approved") }
        if pending > 0 { parts.append("\(pending) pending") }
        let tone: Color? = changes > 0 ? Color(nsColor: Palette.diffRemovedSign)
            : approved > 0 ? Color(nsColor: Palette.diffAddedSign) : nil
        return ("Approvals", parts.isEmpty ? "Reviewed" : parts.joined(separator: ", "), tone,
                Double(approved) / Double(reviewers.count))
    }

    /// The checks row from the head's check runs: failures first, then runs not finished, then all passed; nil while
    /// they load, when they failed to load or without runs.
    private var checksStatus: Status? {
        guard let runs = detail.checks.value, !runs.isEmpty else { return nil }
        let failedConclusions: Set<String> = ["failure", "timed_out", "cancelled", "action_required", "startup_failure"]
        let failed = runs.count { $0.status == "completed" && failedConclusions.contains($0.conclusion ?? "") }
        let pending = runs.count { $0.status != "completed" }
        let passed = runs.count { $0.status == "completed" && $0.conclusion == "success" }
        let skipped = runs.count { $0.status == "completed" && ["skipped", "neutral"].contains($0.conclusion ?? "") }
        func plural(_ count: Int, _ word: String) -> String { "\(count) \(word) \(count == 1 ? "check" : "checks")" }
        if failed > 0 {
            return (Color(nsColor: Palette.diffRemovedSign), "xmark.circle.fill", "Some checks were not successful",
                    "\(plural(failed, "failing")), \(plural(passed, "successful"))")
        }
        if pending > 0 {
            return (Palette.conflictTone, "circle.dotted", "Some checks haven't completed yet",
                    "\(plural(pending, "pending")), \(plural(passed, "successful"))")
        }
        return (Color(nsColor: Palette.diffAddedSign), "checkmark.circle.fill", "All checks have passed",
                plural(passed, "successful") + (skipped > 0 ? ", \(skipped) skipped" : ""))
    }

    /// Update branch: GitHub merges the base into the head, the head pinned to the shown one; busy from the click
    /// until GitHub accepted it.
    private func updateBranchButton(busy: PullRequestAction?) -> some View {
        let pull = detail.pull
        let updating = { if case .updateBranch = busy { true } else { false } }()
        return Button {
            session.pullDetail.perform(.updateBranch(sha: pull.head.sha), on: pull.number, github: session.github)
        } label: {
            HStack(spacing: 6) {
                if updating { ProgressView().controlSize(.mini) }
                Text("Update branch")
            }
        }
        .buttonStyle(RowTextButtonStyle())
        .fixedSize()
        .disabled(busy != nil)
        .help("Merge \(pull.base.ref) into \(pull.head.ref) on \(session.github.kind.name)")
    }

    /// GitHub's merged box, in the merged purple: "Merged", "<who> merged commit <short sha> into <base> <time>",
    /// then "Delete the <head> branch to tidy up." with Delete branch while the branch exists, or "The <head> branch
    /// was deleted." with Restore branch once it is gone (only where the head branch was read:
    /// `PullRequestDetail.headBranchExists`).
    private func gitHubMergedBox(busy: PullRequestAction?) -> some View {
        let pull = detail.pull
        let shape = RoundedRectangle(cornerRadius: SettingsInputMetrics.cornerRadius, style: .continuous)
        let dates = PRPageDates(now: detail.now)
        let who = pull.mergedBy?.login ?? "Someone"
        let commit = pull.mergeCommitSHA.map { " commit \($0.prefix(7))" } ?? ""
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.mergedTone)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Merged")
                        .font(.body.weight(.semibold))
                    Text(verbatim: "\(who) merged\(commit) into \(pull.base.ref)"
                        + (pull.mergedAt.map { " " + dates.relative($0) } ?? ""))
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                        .help(pull.mergedAt.map(dates.absolute) ?? "")
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                if let exists = detail.headBranchExists {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(exists ? "Delete the \(pull.head.ref) branch to tidy up."
                             : "The \(pull.head.ref) branch was deleted.")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if exists {
                            Button { confirmDeleteBranch() } label: {
                                Text("Delete branch")
                            }
                            .buttonStyle(RowTextButtonStyle(formRow: true))
                            .fixedSize()
                            .disabled(busy != nil)
                        } else {
                            Button {
                                session.pullDetail.perform(.restoreBranch(pull.head.ref, sha: pull.head.sha),
                                                           on: pull.number, github: session.github)
                            } label: {
                                Text("Restore branch")
                            }
                            .buttonStyle(RowTextButtonStyle(formRow: true))
                            .fixedSize()
                            .disabled(busy != nil)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Palette.mergedTone.opacity(0.14)))
        .overlay(shape.strokeBorder(Palette.mergedTone.opacity(0.35), lineWidth: 1))
    }

    /// Delete branch's confirmation, in the window's modal: its button deletes the branch (shown gone at once).
    private func confirmDeleteBranch() {
        let pull = detail.pull
        let kind = session.github.kind
        model.presentModal(.confirmation(ModalConfirmation(
            title: "Delete branch \(pull.head.ref)?",
            message: "The branch is deleted on \(kind.name). Restore branch brings it back at its last commit.",
            button: "Delete Branch", isDestructive: true,
            perform: { [session, number = pull.number, branch = pull.head.ref] in
                session.pullDetail.perform(.deleteBranch(branch), on: number, github: session.github)
            })))
    }

    // MARK: GitLab's merge box

    /// GitLab's merge box: for an open merge request, its headline (ready, or why it is blocked) in the tinted status
    /// box with the Resolve buttons on conflicts and a chevron to its details (how far the source branch is behind
    /// with Rebase source branch, what the merge adds to the target, whether the source branch goes), then the
    /// delete-source-branch and squash options and Merge; a merged one's box; then Checkout locally and Close or Reopen,
    /// and the running action, as in the Actions card.
    @ViewBuilder private var mergeBoxCard: some View {
        @Bindable var pullDetail = session.pullDetail
        let pull = detail.pull
        let busy = pullDetail.busy[pull.number]
        SectionCard(nil) {
            VStack(alignment: .leading, spacing: 10) {
                if detail.isMerged {
                    mergedBox
                } else if detail.isOpen {
                    // The details open inside the status box, under its headline, as on GitLab.
                    statusBox(gitLabStatus(busy: busy), expanded: $pullDetail.mergeDetailsExpanded,
                              details: pullDetail.mergeDetailsExpanded ? AnyView(gitLabDetails(busy: busy)) : nil)
                    gitLabOptions(busy: busy)
                }
                // Merge first, on the row of Checkout Locally and Close; narrower, Merge above the other buttons.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        gitLabMergeButton(busy: busy)
                        otherButtons(busy: busy)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        gitLabMergeButton(busy: busy)
                        HStack(spacing: 8) { otherButtons(busy: busy) }
                    }
                }
                if case .unavailable(let reason) = checkoutWay {
                    Text(reason)
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let busy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(busy.progressTitle)
                            .font(.settingsCaption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// GitLab's headline for an open merge request, from `detailed_merge_status` (`HostedMergeDetails.status`) in
    /// GitLab's words: conflicts first, then a draft, a rebase running, then ready (to the token's user, or to the
    /// members who can write to the target branch when GitLab says they cannot merge), still checking, or the reason
    /// it is blocked (any value Histq does not know as a generic block).
    private func gitLabStatus(busy: PullRequestAction?) -> Status {
        let pull = detail.pull
        let details = pull.mergeDetails
        if hasConflicts {
            return (Color(nsColor: Palette.diffRemovedSign), "exclamationmark.triangle.fill",
                    "Merge blocked: merge conflicts must be resolved.",
                    "Resolve the conflicts with \(pull.base.ref) to merge it.")
        }
        if pull.draft == true || details?.status == "draft_status" {
            return (nil, "circle.dashed", "Merge blocked: this merge request is still a draft.",
                    "Mark it as ready on GitLab to merge it.")
        }
        if details?.rebaseInProgress == true || { if case .rebase = busy { true } else { false } }() {
            return (nil, "clock", "Rebasing the source branch onto \(pull.base.ref)…", nil)
        }
        let green = Color(nsColor: Palette.diffAddedSign)
        let blocked = Palette.conflictTone
        switch details?.status ?? (pull.mergeable == true ? "mergeable" : nil) {
        case "mergeable":
            return details?.viewerCanMerge == false
                ? (green, "checkmark.circle.fill", "Ready to merge by members who can write to the target branch.", nil)
                : (green, "checkmark.circle.fill", "Ready to merge!", nil)
        case nil, "checking", "unchecked", "preparing", "approvals_syncing":
            return (nil, "clock", "Checking whether this merge request can be merged…", nil)
        case "not_approved":
            return (blocked, "lock.fill", "Merge blocked: all required approvals must be given.", nil)
        case "discussions_not_resolved":
            return (blocked, "lock.fill", "Merge blocked: all threads must be resolved.", nil)
        case "ci_must_pass":
            return (blocked, "lock.fill", "Merge blocked: the pipeline must succeed.", nil)
        case "ci_still_running":
            return (blocked, "lock.fill", "Merge blocked: the pipeline is still running.", nil)
        case "need_rebase":
            return (blocked, "lock.fill", "Merge blocked: the source branch must be rebased onto the target branch.",
                    nil)
        case "requested_changes":
            return (blocked, "lock.fill", "Merge blocked: the requested changes must be approved by their reviewer.",
                    nil)
        case "merge_request_blocked":
            return (blocked, "lock.fill", "Merge blocked: another merge request must be merged first.", nil)
        case "status_checks_must_pass":
            return (blocked, "lock.fill", "Merge blocked: all status checks must pass.", nil)
        case "not_open":
            return (blocked, "lock.fill", "Merge blocked: the merge request must be open.", nil)
        default:
            return (blocked, "lock.fill", "Merge blocked: this merge request cannot be merged yet.",
                    "Open it on GitLab to see why.")
        }
    }

    /// The merge box's details, one line each: how far the source branch is behind the target with Rebase source
    /// branch, GitLab's last merge or rebase error, the commits the merge adds to the target, and whether the source
    /// branch goes.
    private func gitLabDetails(busy: PullRequestAction?) -> some View {
        let pull = detail.pull
        let details = pull.mergeDetails
        return VStack(alignment: .leading, spacing: 6) {
            if let behind = details?.commitsBehind, behind > 0 {
                detailLine {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("The source branch is \(behind) \(behind == 1 ? "commit" : "commits") behind the target "
                            + "branch.")
                        if session.github.offers(.rebaseSourceBranch) { rebaseButton(busy: busy) }
                    }
                }
            }
            if let error = details?.mergeError, !error.isEmpty {
                detailLine {
                    Text(error)
                        .foregroundStyle(Color(nsColor: Palette.diffRemovedSign))
                }
            }
            if let added = addedSentence {
                detailLine { added }
            }
            detailLine {
                Text(deletesSourceBranch ? "Source branch will be deleted." : "Source branch will not be deleted.")
            }
        }
        .padding(.leading, 4)
    }

    /// A bulleted line of the merge box's details.
    private func detailLine(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "•")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            content()
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "N commits and 1 merge commit will be added to <target>.": the merge request's commits (one when squashed),
    /// with the merge commit where the project's merge method makes one; nil while the commits are unknown.
    private var addedSentence: Text? {
        let pull = detail.pull
        guard let count = isSquashing ? 1 : pull.commits ?? detail.commits.value?.count else { return nil }
        let merge = detail.repositoryInfo?.mergeCommit == true ? " and 1 merge commit" : ""
        return Text("\(count) \(count == 1 ? "commit" : "commits")\(merge) will be added to ")
            + Text(pull.base.ref).font(.callout.monospaced())
            + Text(".")
    }

    /// Rebase source branch: GitLab rebases the source branch onto the target, the head pinned to the shown one; busy
    /// from the click until GitLab has finished.
    private func rebaseButton(busy: PullRequestAction?) -> some View {
        let pull = detail.pull
        let rebasing = { if case .rebase = busy { true } else { false } }()
        return Button {
            session.pullDetail.perform(.rebase(sha: pull.head.sha), on: pull.number, github: session.github)
        } label: {
            HStack(spacing: 6) {
                if rebasing { ProgressView().controlSize(.mini) }
                Text("Rebase source branch")
            }
        }
        .buttonStyle(RowTextButtonStyle())
        .fixedSize()
        .disabled(busy != nil || pull.mergeDetails?.rebaseInProgress == true)
        .help("Rebase \(pull.head.ref) onto \(pull.base.ref) on GitLab")
    }

    /// Whether the merge squashes: the user's choice, else the project's rule (`squash_option`: always, never, or the
    /// merge request's own `squash_on_merge`, else the rule's default).
    private var isSquashing: Bool {
        guard session.github.mergeMethods.contains(.squash) else { return false }
        switch detail.repositoryInfo?.squashOption {
        case .always: return true
        case .never: return false
        case .defaultOn, .defaultOff, nil:
            return session.pullDetail.squashChoice
                ?? detail.pull.mergeDetails?.squashOnMerge ?? (detail.repositoryInfo?.squashOption == .defaultOn)
        }
    }

    /// Whether the merge deletes the source branch: the user's choice, else the merge request's own setting.
    private var deletesSourceBranch: Bool {
        session.pullDetail.deleteSourceBranchChoice ?? detail.pull.mergeDetails?.deletesSourceBranch ?? false
    }

    /// Whether the provider takes GitLab's delete-source-branch option with a merge.
    private var supportsDeleteSourceBranch: Bool {
        session.github.api?.client.supportedMergeOptions.contains(.deleteSourceBranch) ?? false
    }

    /// The merge options: Delete source branch (where the provider takes it) and Squash commits (unless the project
    /// never squashes; locked on when it always does).
    @ViewBuilder
    private func gitLabOptions(busy: PullRequestAction?) -> some View {
        let model = session.pullDetail
        let supportsDelete = supportsDeleteSourceBranch
        let squashOption = detail.repositoryInfo?.squashOption
        let showsSquash = session.github.mergeMethods.contains(.squash) && squashOption != .never
        HStack(spacing: 14) {
            if supportsDelete {
                Toggle("Delete source branch", isOn: Binding(
                    get: { deletesSourceBranch }, set: { model.deleteSourceBranchChoice = $0 }))
                    .toggleStyle(.checkbox)
                    .disabled(busy != nil)
            }
            if showsSquash {
                Toggle("Squash commits", isOn: Binding(get: { isSquashing }, set: { model.squashChoice = $0 }))
                    .toggleStyle(.checkbox)
                    .disabled(busy != nil || squashOption == .always)
                    .help(squashOption == .always ? "The project always squashes" : "")
            }
        }
        .fixedSize()
    }

    /// Merge, for an open merge request and only members who may merge (GitLab's `can_merge`): green with the green
    /// headline, off with conflicts, for a draft or while an action runs.
    @ViewBuilder
    private func gitLabMergeButton(busy: PullRequestAction?) -> some View {
        let pull = detail.pull
        if detail.isOpen, pull.mergeDetails?.viewerCanMerge != false {
            Button("Merge") {
                confirmMerge(isSquashing ? .squash : .merge, options: HostedMergeOptions(
                    deleteSourceBranch: supportsDeleteSourceBranch ? deletesSourceBranch : nil))
            }
            .buttonStyle(RowTextButtonStyle(
                formRow: true, fill: mergesCleanly ? Color(nsColor: Palette.graphPullOpenFill) : nil))
            .disabled(busy != nil || pull.draft == true || hasConflicts)
            .fixedSize()
        }
    }

    /// "Merge <base> into <head>": the running entry `RepoSession.resolvePullRequestConflicts` adds for this pull
    /// request, so the buttons show it busy from the click on.
    private var resolveTitle: String { "Merge \(detail.pull.base.ref) into \(detail.pull.head.ref)" }

    /// Why Resolve cannot start now; nil when it can. The merge needs the head branch from the GitHub remote (a fork's
    /// lives elsewhere, and a branch of the same name there would be the wrong one), a clean tree and no operation in
    /// progress, and nothing else running (another resolve, or a write its checks would miss).
    private var resolveBlocked: String? {
        let pull = detail.pull
        guard session.github.api?.remote != nil else {
            return "No remote of this repository is on \(session.github.kind.name)"
        }
        let headOwner = pull.head.label?.split(separator: ":").first
        guard let headOwner, headOwner == pull.base.label?.split(separator: ":").first else {
            return "The branch is in a fork: resolve its conflicts there"
        }
        if let other = session.running.first { return "Waiting for \(other.title) to finish" }
        if session.repoState?.isOperationInProgress == true {
            return "A merge, rebase, cherry-pick or revert is in progress: finish or abort it first"
        }
        guard let status = session.status.value else { return "Reading the working tree…" }
        if !status.conflicted.isEmpty || !status.staged.isEmpty || !status.unstaged.isEmpty {
            return "Commit or stash the uncommitted changes first"
        }
        return nil
    }

    /// Resolve with AI and Resolve manually: both merge the base into the head branch here and open the conflict
    /// editor, the AI one with Suggest All. While one cannot start, both are off with the reason under them; the
    /// running merge shows there in the click's frame.
    private var resolveControls: some View {
        let pull = detail.pull
        let resolving = session.running.contains { $0.title == resolveTitle }
        let blocked = resolving ? "Merging \(pull.base.ref) into \(pull.head.ref)…" : resolveBlocked
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AIHookButton(title: "Resolve with AI", systemImage: "sparkles",
                             help: "Merge \(pull.base.ref) into \(pull.head.ref) here, then suggest resolutions "
                                 + "with AI", unavailable: blocked, seam: "pr-resolve-ai") {
                    resolve(withAI: true)
                }
                Button { resolve(withAI: false) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.merge")
                            .accessibilityHidden(true)
                        Text("Resolve manually")
                    }
                }
                .buttonStyle(RowTextButtonStyle())
                .fixedSize()
                .disabled(blocked != nil)
                .help(blocked ?? "Merge \(pull.base.ref) into \(pull.head.ref) here and open the conflict editor")
                #if DEBUG
                .task(id: blocked) {
                    guard blocked == nil, Self.launchResolve else { return }
                    Self.launchResolve = false
                    resolve(withAI: false)
                }
                #endif
            }
            if let blocked {
                HStack(spacing: 6) {
                    if resolving { ProgressView().controlSize(.mini) }
                    Text(blocked)
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The Resolve buttons' click (and their DEBUG hooks): checks again, since a hook or a second click may come after
    /// the render that enabled it. It never asks: only the refs read after the session's fetch tell a local head
    /// branch that is just behind (fast-forwarded) from one with commits of its own (refused), and the session checks
    /// the tree again then (`RepoSession.resolvePullRequestConflicts`).
    private func resolve(withAI: Bool) {
        let pull = detail.pull
        guard !session.running.contains(where: { $0.title == resolveTitle }), resolveBlocked == nil,
              let remote = session.github.api?.remote else { return }
        session.resolvePullRequestConflicts(
            head: pull.head.ref, base: pull.base.ref, remote: remote, number: pull.number, withAI: withAI)
    }

    /// The merge method and Merge: green (white text) with the green status box, neutral while blocked, out of date or
    /// checking, off with conflicts, for a draft or while an action runs.
    @ViewBuilder
    private func mergeControls(busy: PullRequestAction?) -> some View {
        let pullDetail = session.pullDetail
        let pull = detail.pull
        let methods = mergeMethods
        let kind = session.github.kind
        let shown = shownMergeMethod
        let ownList = detail.layout != .default && detail.pull.allowedMergeMethods?.isEmpty == false
        CapsuleMenuPicker(label: "Merge method", selection: Binding(get: { shown }, set: { method in
            if ownList { pullDetail.ownMergeMethod = method } else { pullDetail.mergeMethod = method }
        }),
                          title: Text(detail.layout == .default ? shown.title : shown.title(on: kind))) {
            ForEach(methods, id: \.self) { Text(detail.layout == .default ? $0.title : $0.title(on: kind)).tag($0) }
        }
        Button(detail.layout.words.complete ?? "Merge") { confirmMerge(shown, options: mergeOptions) }
            .buttonStyle(RowTextButtonStyle(
                formRow: true,
                fill: mergesCleanly ? Color(nsColor: Palette.graphPullOpenFill) : nil))
            .disabled(busy != nil || pull.draft == true || hasConflicts)
            .fixedSize()
    }

    /// Checkout Locally, and Close or Reopen unless merged: capsules with an icon, the close one red and the reopen one
    /// green like the state pill.
    @ViewBuilder
    private func otherButtons(busy: PullRequestAction?) -> some View {
        let pull = detail.pull
        let way = checkoutWay
        let help = switch way {
        case .ref(let ref): "Fetch \(ref) into the branch pr/\(pull.number) and check it out"
        case .branch(let remote, let name): "Fetch \(remote)/\(name) into the branch pr/\(pull.number) and check it out"
        case .unavailable(let reason): reason
        case nil:
            "Fetch the \(session.github.kind.pullRequestNoun.lowercased())'s head into the branch pr/\(pull.number) "
                + "and check it out"
        }
        Button { checkout() } label: {
            HStack(spacing: 6) {
                IconImage("lucide-laptop-minimal")
                    .accessibilityHidden(true)
                Text("Checkout Locally")
            }
        }
        .buttonStyle(RowTextButtonStyle(formRow: true))
        .fixedSize()
        .disabled({ if case .unavailable = way { true } else { false } }())
        .help(help)
        if !detail.isMerged, detail.isOpen || session.github.offers(.reopen) {
            let open = detail.isOpen
            Button { confirmSetOpen(!open) } label: {
                HStack(spacing: 6) {
                    IconImage(open ? "lucide-git-pull-request-closed" : "lucide-git-pull-request-arrow")
                        .foregroundStyle(Color(nsColor: open ? Palette.diffRemovedSign : Palette.diffAddedSign))
                        .accessibilityHidden(true)
                    let noun = session.github.kind.pullRequestNoun.capitalized
                    let words = detail.layout.words
                    Text(open ? words.close ?? "Close \(noun)" : words.reopen ?? "Reopen \(noun)")
                }
            }
            .buttonStyle(RowTextButtonStyle(formRow: true))
            .fixedSize()
            .disabled(busy != nil)
        }
    }

    /// The methods the picker offers: the pull request's own (Bitbucket's destination branch) where the host gives
    /// them, on every layout but `.default`, else the client's.
    private var mergeMethods: [HostedMergeMethod] {
        guard detail.layout != .default, let own = detail.pull.allowedMergeMethods, !own.isEmpty else {
            return session.github.mergeMethods
        }
        return own
    }

    /// The method the picker shows. A pull request with its own list (Bitbucket's): the user's choice for it, else
    /// its default, else a merge commit, else the first offered. Otherwise: the user's last choice (kept across pull
    /// requests, as before), else a merge commit.
    private var shownMergeMethod: HostedMergeMethod {
        let methods = mergeMethods
        let model = session.pullDetail
        if detail.layout != .default, detail.pull.allowedMergeMethods?.isEmpty == false {
            if let chosen = model.ownMergeMethod, methods.contains(chosen) { return chosen }
            if let preferred = detail.pull.defaultMergeMethod, methods.contains(preferred) { return preferred }
        } else if let chosen = model.mergeMethod, methods.contains(chosen) {
            return chosen
        }
        return methods.contains(.merge) ? .merge : methods.first ?? .merge
    }

    /// Bitbucket's Close source branch, where the merge area shows it (`bitbucketMergeArea`); none elsewhere.
    private var mergeOptions: HostedMergeOptions {
        guard detail.layout.bitbucketMergeArea, session.github.api?.client.supportedMergeOptions
            .contains(.deleteSourceBranch) == true, detail.pull.isFromSameRepository
        else { return HostedMergeOptions() }
        return HostedMergeOptions(deleteSourceBranch: session.pullDetail.closeSourceBranchChoice
            ?? detail.pull.closesSourceBranch ?? false)
    }

    /// Merges the head this detail shows: the sha goes with the merge, so a push after this confirmation fails it.
    /// `options`: GitLab's merge box choices (none from the Actions card).
    private func confirmMerge(_ method: HostedMergeMethod, options: HostedMergeOptions = HostedMergeOptions()) {
        let pull = detail.pull
        let count = pull.commits ?? detail.commits.value?.count ?? 0
        let how = switch method {
        case .merge: "with a merge commit"
        case .squash: "squashed into one commit"
        case .rebase: "rebased onto \(pull.base.ref)"
        case .fastForward: "fast-forwarded"
        case .squashFastForward: "squashed into one commit, fast-forward only"
        case .rebaseFastForward: "rebased onto \(pull.base.ref) and fast-forwarded"
        case .fastForwardIfPossible: "fast-forwarded if it can be, else with a merge commit"
        }
        let kind = session.github.kind
        model.presentModal(.confirmation(ModalConfirmation(
            title: "\(detail.layout.words.complete ?? method.buttonTitle) \(kind.reference(.pullRequest(pull.number)))?",
            message: "\(kind.name) merges \(count) \(count == 1 ? "commit" : "commits") of \(pull.head.ref) into "
                + "\(pull.base.ref), \(how)."
                + (options.deleteSourceBranch == true ? " It then deletes \(pull.head.ref) on \(kind.name)." : "")
                + " Histq cannot undo a merge on \(kind.name).",
            button: method.buttonTitle, isDestructive: false,
            perform: { [session, sha = pull.head.sha, number = pull.number, head = pull.head.ref,
                        sameRepository = pull.isFromSameRepository] in
                session.pullDetail.perform(.merge(method, sha: sha, options: options), on: number,
                                           github: session.github) {
                    // A fork's branch is not on this remote.
                    if sameRepository { session.pruneMergedBranch(head) }
                }
            })))
    }

    private func confirmSetOpen(_ open: Bool) {
        let number = detail.pull.number
        let kind = session.github.kind
        let reference = kind.reference(.pullRequest(number))
        let noun = kind.pullRequestNoun.lowercased()
        let words = detail.layout.words
        model.presentModal(.confirmation(ModalConfirmation(
            title: open ? "\(words.reopen ?? "Reopen") \(reference)?" : "\(words.close ?? "Close") \(reference)?",
            message: open
                ? "The \(noun) opens again on \(kind.name)."
                : "The \(noun) closes on \(kind.name) without merging; it can be reopened later.",
            button: open ? words.reopen ?? "Reopen" : words.close ?? "Close \(kind.pullRequestNoun.capitalized)",
            isDestructive: !open,
            perform: { [session] in session.pullDetail.perform(.setOpen(open), on: number, github: session.github) })))
    }

    /// Checks out `pr/<n>`: fetched from the repository's remote when it does not exist yet; checked out as is when it
    /// already points at the pull request's head; otherwise never overwritten (it may hold local commits), and the
    /// existing branch is offered instead.
    private func checkout() {
        let pull = detail.pull
        let branch = "pr/\(pull.number)"
        let way = checkoutWay
        if case .unavailable = way { return }
        if let local = session.refs.value?.localBranches.first(where: { $0.name == branch }) {
            if pull.headIs(local.commit) {
                session.run(.checkoutBranch(branch), title: "Checkout \(branch)")
                return
            }
            model.presentModal(.confirmation(ModalConfirmation(
                title: "\(branch) already exists",
                message: "The local branch \(branch) points at another commit than the "
                    + "\(session.github.kind.pullRequestNoun.lowercased())'s head "
                    + "(\(String(pull.head.sha.prefix(7)))). Histq does not overwrite it. Check out the existing branch?",
                button: "Checkout \(branch)", isDestructive: false,
                perform: { [session] in session.run(.checkoutBranch(branch), title: "Checkout \(branch)") })))
            return
        }
        guard let remote = session.github.api?.remote, let way else {
            session.pullDetail.actionError =
                "No remote of this repository is on \(session.github.kind.name): nothing to fetch from."
            return
        }
        session.run(.checkoutPullRequest(way, number: pull.number, remote: remote),
                    title: "Checkout \(session.github.kind.reference(.pullRequest(pull.number)))")
    }
}

struct PRSideEmpty: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.settingsCaption)
            .foregroundStyle(.secondary)
    }
}

/// A reviewer or an assignee: the avatar, the login, and for a reviewer the state of their review.
struct PRPersonRow: View {
    let login: String
    let userID: Int?
    let avatarURL: String?
    /// `HostAvatars.of` the repository.
    let avatars: HostAvatars
    let state: String?
    let showsState: Bool

    var body: some View {
        HStack(spacing: 6) {
            GitHubUserAvatar(login: login, id: userID, avatarURL: avatarURL, size: 16, avatars: avatars)
            Text(login)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if showsState {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .help(stateText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(showsState ? "\(login), \(stateText)" : login)
    }

    private var symbol: String {
        switch state {
        case "APPROVED": "checkmark"
        case "CHANGES_REQUESTED": "plus.forwardslash.minus"
        case nil: "circle"
        default: "text.bubble"
        }
    }

    private var tint: Color {
        switch state {
        case "APPROVED": Color(nsColor: Palette.diffAddedSign)
        case "CHANGES_REQUESTED": Color(nsColor: Palette.diffRemovedSign)
        default: .secondary
        }
    }

    private var stateText: String {
        switch state {
        case "APPROVED": "approved"
        case "CHANGES_REQUESTED": "requested changes"
        case "DISMISSED": "review dismissed"
        case nil: "review requested"
        default: "commented"
        }
    }
}

/// Where the accounts of a repository's PRs tab and pull request and issue pages get their avatars.
enum HostAvatars: Equatable {
    /// Drawn from the login, no request: the stub, Enterprise hosts, a tab still connecting.
    case drawn
    /// The account's GitHub avatar whatever the commit avatars' mode (user, 2026-11-17): github.com.
    case github
    /// The API's `avatar_url` of the account whatever the commit avatars' mode, from the repository's `host`
    /// (`AvatarStore.hostedAvatar`): GitLab and Bitbucket Cloud.
    case gitlab(host: String)

    /// The avatars of `store`'s repository. Drawn in a stub run, whose repository names a real host but must not
    /// reach it.
    @MainActor static func of(_ store: HostingStore) -> HostAvatars {
        #if DEBUG
        if GitHubStub.isEnabled { return .drawn }
        #endif
        guard case .connected(let repository) = store.connection else { return .drawn }
        switch store.kind {
        case .github: return repository.host == "github.com" ? .github : .drawn
        case .gitlab: return .gitlab(host: repository.host)
        // `AvatarStore.hostedIdentity` takes Bitbucket's `links.avatar.href` on bitbucket.org, Atlassian's avatar
        // service or Gravatar, whatever the commit avatars' mode (as GitLab's).
        case .bitbucketCloud: return .gitlab(host: repository.host)
        // Not loaded from the host until its client maps avatars.
        case .bitbucketDataCenter: return .drawn
        // Azure DevOps's pictures need the token: never fetched, always drawn.
        case .azureDevOps: return .drawn
        }
    }

    /// The avatar to draw now for an account: the mode's drawn avatar until a loaded one arrives.
    @MainActor func image(login: String, id: Int?, avatarURL: String?, pixels: Int) -> NSImage? {
        switch self {
        case .drawn: AvatarStore.shared.avatar(email: "", name: login, pixels: pixels)
        case .github: AvatarStore.shared.gitHubAvatar(login: login, id: id, pixels: pixels)
        case .gitlab(let host):
            AvatarStore.shared.hostedAvatar(url: avatarURL, host: host, name: login, pixels: pixels)
        }
    }

    /// Whether `changed`, the identity `AvatarStore.didChange` named, is the account's avatar.
    @MainActor func matches(_ changed: String, login: String, id: Int?, avatarURL: String?) -> Bool {
        switch self {
        case .drawn: false
        case .github: AvatarStore.matches(email: AvatarStore.gitHubEmail(login: login, id: id), name: login,
                                          changed: changed)
        case .gitlab(let host): AvatarStore.hostedIdentity(url: avatarURL, host: host) == changed
        }
    }
}

/// An account's avatar as `avatars` says (`HostAvatars`), the mode's generated or initials avatar until it arrives or
/// when it cannot load. Redrawn when `AvatarStore` has a new image for the account or the mode changed, like the PRs
/// tab's rows. Shared with the issue page.
struct GitHubUserAvatar: View {
    let login: String
    let id: Int?
    /// The API's avatar URL of the account (`HostAvatars.gitlab` loads it).
    let avatarURL: String?
    let size: CGFloat
    /// `HostAvatars.of` the repository.
    let avatars: HostAvatars
    /// Bumped when `AvatarStore` has a new image for this account (or the avatar mode changed).
    @State private var revision = 0
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .clipShape(Circle())
            } else {
                Circle().fill(Palette.skeletonFill)
            }
        }
        .frame(width: size, height: size)
        .id(revision)
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: AvatarStore.didChange)) { note in
            guard let changed = note.userInfo?[AvatarStore.emailKey] as? String else { return revision &+= 1 }
            if avatars.matches(changed, login: login, id: id, avatarURL: avatarURL) { revision &+= 1 }
        }
    }

    private var image: NSImage? {
        avatars.image(login: login, id: id, avatarURL: avatarURL, pixels: Int((size * displayScale).rounded(.up)))
    }
}

/// A label: its GitHub color as a dot (the label's own data), then its name.
struct PRLabelChip: View {
    let label: HostedLabel

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dot)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(label.name)
                .font(.settingsCaption)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(Palette.tabFill))
        .help(label.description ?? label.name)
    }

    /// `RRGGBB` from GitHub; the secondary color when it is not one.
    private var dot: Color {
        guard let hex = label.color, hex.count == 6, let value = UInt32(hex, radix: 16) else { return .secondary }
        return Color(nsColor: NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                                      green: CGFloat((value >> 8) & 0xFF) / 255,
                                      blue: CGFloat(value & 0xFF) / 255, alpha: 1))
    }
}

// MARK: Commits

private struct PRCommitsTab: View {
    let commits: Loadable<[HostedCommit]>
    /// The detail load's "now" (`PullRequestDetail.now`).
    let now: Date
    let github: HostingStore
    /// The host's list (`PRPageLayout.commitsByDay`): the commits under day headings, each row with a copy button.
    var byDay = false
    /// "authored" (GitLab) or "committed" (GitHub), with `byDay`.
    var verb = "authored"

    var body: some View {
        switch commits {
        case .loaded(let commits):
            let dates = PRPageDates(now: now)
            SectionCard("Commits", systemImage: PRTab.commits.systemImage, count: commits.count, contentPadding: 6) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if byDay {
                            ForEach(Self.days(commits), id: \.id) { day in
                                PRCommitDayHeading(title: day.title)
                                ForEach(day.commits) { row($0, dates: dates) }
                            }
                        } else {
                            ForEach(commits) { row($0, dates: dates) }
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        case .failed(let message):
            DiffNoticeCard(title: "Commits", systemImage: "exclamationmark.triangle", message: message)
        case .loading:
            PRPartLoading(tab: .commits)
        case .idle:
            DiffNoticeCard(title: "Commits", systemImage: "exclamationmark.triangle", message: "Not loaded.")
        }
    }

    private func row(_ commit: HostedCommit, dates: PRPageDates) -> some View {
        PRCommitRow(commit: commit, url: github.webURL(.commit(commit.sha)), hostName: github.kind.name, dates: dates,
                     gitLabStyle: byDay, verb: byDay ? verb : "committed",
                     idLength: byDay && github.kind == .gitlab ? 8 : 7)
    }

    /// The day headings' format, GitLab's ("Nov 20, 2026"), in the pages' English.
    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    /// `commits` in their order, each run of one day (the author date's, in the Mac's time zone) under its heading
    /// (`id` its place); a commit without a date goes under the heading before it ("Unknown date" first).
    static func days(_ commits: [HostedCommit]) -> [(id: Int, title: String, commits: [HostedCommit])] {
        var days: [(id: Int, title: String, commits: [HostedCommit])] = []
        for commit in commits {
            let day = commit.commit.author?.date.map { dayFormat.string(from: $0) } ?? days.last?.title
                ?? "Unknown date"
            if days.last?.title == day {
                days[days.count - 1].commits.append(commit)
            } else {
                days.append((days.count, day, [commit]))
            }
        }
        return days
    }
}

/// A day heading of GitLab's Commits list: the date, a hairline under it.
private struct PRCommitDayHeading: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout.weight(.semibold))
            Divider()
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A commit: its subject, author and date, and its short id, which opens it on GitHub.
private struct PRCommitRow: View {
    let commit: HostedCommit
    /// The commit's page on the host.
    let url: URL?
    /// The host's product name ("GitHub", "GitLab").
    let hostName: String
    let dates: PRPageDates
    /// The host's own row (`commitsByDay`): a copy button beside the short id.
    var gitLabStyle = false
    /// "<author> <verb> <time>".
    var verb = "committed"
    /// The short id's length, the host's (GitLab 8, GitHub 7).
    var idLength = 7
    @State private var hovered = false

    var body: some View {
        let subject = commit.commit.message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let author = commit.author?.login ?? commit.commit.author?.name ?? "ghost"
        HStack(spacing: 8) {
            Image(systemName: "circle.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(subject)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Group {
                    if let date = commit.commit.author?.date {
                        Text(verbatim: "\(author) \(verb) \(dates.relative(date))")
                            .help(dates.absolute(date))
                    } else {
                        Text(verbatim: author)
                    }
                }
                .font(.settingsCaption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                GitHubLinks.open(url)
            } label: {
                Text(String(commit.sha.prefix(idLength)))
                    .font(.settingsCaption.monospaced())
            }
            .buttonStyle(RowTextButtonStyle())
            .help("Open this commit on \(hostName)")
            if gitLabStyle {
                Button {
                    RepoMenus.copy(commit.sha)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(RowIconButtonStyle())
                .help("Copy commit SHA")
                .accessibilityLabel("Copy commit SHA")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovered ? Palette.hoverFill : .clear))
        .animation(Motion.hover, value: hovered)
        .onHover { hovered = $0 }
        .help(commit.commit.message)
    }
}

// MARK: Files changed

/// The file list on the left, the selected file's patch on the right (read-only, `DiffMode.diff`).
private struct PRFilesTab: View {
    let session: RepoSession
    let detail: PullRequestDetail

    private static let listWidth: CGFloat = 240
    /// The tree's column (`PRPageLayout.filesTree`): its rows indent, so it takes more room.
    private static let treeWidth: CGFloat = 300

    var body: some View {
        switch detail.files {
        case .loaded(let files) where files.isEmpty:
            DiffNoticeCard(title: "Files changed", systemImage: "checkmark.circle",
                           message: "This \(session.github.kind.pullRequestNoun.lowercased()) changes no file.")
        case .loaded(let files):
            HStack(alignment: .top, spacing: SectionCardMetrics.spacing) {
                SectionCard("Files", systemImage: PRTab.files.systemImage, count: files.count, contentPadding: 6) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            if detail.layout.filesTree {
                                tree(files)
                            } else {
                                ForEach(files) { file in
                                    PRFileRow(file: file, selected: file.id == session.pullDetail.selectedFile) {
                                        session.pullDetail.selectedFile = file.id
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(width: detail.layout.filesTree ? Self.treeWidth : Self.listWidth)
                .frame(maxHeight: .infinity)
                if let file = files.first(where: { $0.id == session.pullDetail.selectedFile }) ?? files.first {
                    diffCard(file)
                }
            }
        case .failed(let message):
            DiffNoticeCard(title: "Files changed", systemImage: "exclamationmark.triangle", message: message)
        case .loading:
            PRPartLoading(tab: .files, isCurrent: { [model = session.pullDetail] in
                if case .loading = model.state.value?.files { true } else { false }
            })
        case .idle:
            DiffNoticeCard(title: "Files changed", systemImage: "exclamationmark.triangle", message: "Not loaded.")
        }
    }

    /// The files as a folder tree (`FileTree`): each folder once, then its files indented under it, sorted as the
    /// commit detail's tree.
    @ViewBuilder private func tree(_ files: [PRFile]) -> some View {
        let byPath = Dictionary(files.map { ($0.change.path, $0) }, uniquingKeysWith: { first, _ in first })
        ForEach(FileTree.rows(for: files.map(\.change))) { row in
            switch row.content {
            case .folder(let name, _):
                PRFolderRow(name: name, depth: row.depth)
            case .file(let change):
                if let file = byPath[change.path] {
                    PRFileRow(file: file, selected: file.id == session.pullDetail.selectedFile, depth: row.depth) {
                        session.pullDetail.selectedFile = file.id
                    }
                }
            }
        }
    }

    @ViewBuilder private func diffCard(_ file: PRFile) -> some View {
        if let section = file.section, !section.rows(.diff).isEmpty {
            SectionCard(file.change.name, systemImage: file.change.systemImage, contentPadding: 0) {
                DiffLineTable(section: section, mode: .diff, loadID: detail.loadID,
                              repo: session.url.lastPathComponent, inlineThreads: inlineThreads(file),
                              onApply: { _, _, _ in }, onClose: { [session] in session.closeFile() })
                    .frame(maxHeight: .infinity)
            } accessory: {
                counts(file.file)
            }
            .id(file.id)
        } else {
            DiffNoticeCard(
                title: file.change.name, systemImage: file.change.systemImage,
                message: file.file.patch == nil
                    ? "\(session.github.kind.name) shows no patch for this file (a binary file, or a diff too large "
                        + "for the API)."
                    : "No line changes.")
            {
                let kind = session.github.kind
                Button("Open on \(kind.name)") { GitHubLinks.open(detail.pull.htmlURL + kind.filesPagePath) }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
            }
        }
    }

    /// The file's threads with a line in the current diff, for its table: under the line of their side (an outdated
    /// thread, whose line is gone, stays in the Conversation only), collapsed as on the Conversation page (resolved,
    /// unless the user chose otherwise there or here: `threadExpanded` is shared).
    private func inlineThreads(_ file: PRFile) -> DiffInlineThreads {
        let expanded = session.pullDetail.threadExpanded
        let dates = PRPageDates(now: detail.now)
        let threads = file.threads.compactMap { thread -> DiffInlineThread? in
            // The root's own line: `thread.line` falls back to the line it was written on, of an older diff.
            guard let line = thread.comments.first?.line else { return nil }
            let start = thread.comments.first?.startLine
            return DiffInlineThread(
                id: thread.id, line: line, newSide: thread.side != "LEFT",
                title: start.map { $0 != line ? "Lines \($0)–\(line)" : "Line \(line)" } ?? "Line \(line)",
                isResolved: thread.state?.isResolved == true,
                comments: thread.comments.enumerated().map { index, comment in
                    DiffInlineThread.Comment(
                        author: comment.user?.login ?? "ghost", date: comment.createdAt.map(dates.relative) ?? "",
                        body: (comment.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines), isReply: index > 0)
                })
        }
        return DiffInlineThreads(
            path: file.id, threads: threads,
            collapsed: Set(file.threads.filter { PRTimeline.isCollapsed($0, expanded: expanded) }.map(\.id)),
            onToggle: { [session] id, collapsed in session.pullDetail.threadExpanded[id] = !collapsed },
            onReply: { [session] in session.pullDetail.tab = .conversation },
            replyTitle: "Reply in \(detail.layout.title(of: .conversation))",
            newComments: newComments(file))
    }

    /// The "+" and the new comment box of `file`'s table, where the host takes new inline comments (none without
    /// `.newInlineComments`; ⇧-click ranges only with `.multiLineInlineComments`, under the host's own range rule).
    private func newComments(_ file: PRFile) -> DiffNewComments? {
        guard let client = session.github.api?.client, client.capabilities.contains(.newInlineComments) else {
            return nil
        }
        let model = session.pullDetail
        let kind = client.kind
        return DiffNewComments(
            composer: model.inlineComposer.flatMap { $0.path == file.id ? $0.composer : nil },
            allowsRange: client.capabilities.contains(.multiLineInlineComments),
            isBusy: model.running != nil,
            refusal: { PRNewInline.rangeRefusal(kind, start: $0, end: $1) },
            draft: { [model] in model.inlineDraft },
            onOpen: { [model] composer in model.openInline(composer, in: file.id) },
            onDraft: { [model] text in model.inlineDraft = text },
            onCancel: { [model] in model.cancelInline() },
            onPost: { [session, detail] body in
                session.pullDetail.postInline(body, file: file, detail: detail, github: session.github)
            })
    }

    private func counts(_ file: HostedPullRequestFile) -> some View {
        HStack(spacing: 6) {
            Text("+\(file.additions)")
                .foregroundStyle(Color(nsColor: Palette.diffAddedSign))
            Text("−\(file.deletions)")
                .foregroundStyle(Color(nsColor: Palette.diffRemovedSign))
        }
        .font(.settingsCaption.monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(file.additions) added, \(file.deletions) removed")
    }
}

/// A file row: the status glyph, the name and folder, and GitHub's line counts. A click selects it at once (its rows
/// were built with the load).
private struct PRFileRow: View {
    let file: PRFile
    let selected: Bool
    /// Its level in the tree (`PRPageLayout.filesTree`), which also leaves out the folder under the name; nil in the
    /// flat list.
    var depth: Int?
    let onSelect: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: file.change.systemImage)
                .font(.settingsCaption.weight(.bold))
                .foregroundStyle(file.change.tint)
                .frame(width: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(file.change.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if depth == nil, !file.change.folder.isEmpty {
                    Text(file.change.folder)
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            Text("+\(file.file.additions) −\(file.file.deletions)")
                .font(.settingsCaption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(minHeight: SidebarItemStyle.height)
        .background(Capsule().fill(selected ? Palette.selectedFill : hovered ? Palette.hoverFill : .clear))
        .overlay(Capsule().strokeBorder(selected ? Palette.selectedBorder : .clear, lineWidth: 1))
        .contentShape(Capsule())
        .padding(.leading, CGFloat(depth ?? 0) * PRFolderRow.indent)
        .animation(Motion.hover, value: hovered)
        .onHover { hovered = $0 }
        .onTapGesture(perform: onSelect)
        .help(file.file.previousFilename.map { "\($0) → \(file.file.filename)" } ?? file.file.filename)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(accessibilityText)
        .accessibilityAction { onSelect() }
    }

    private var accessibilityText: String {
        let counts = "\(file.file.additions) added, \(file.file.deletions) removed"
        return "\(file.file.filename), \(file.change.kindName), \(counts)"
    }
}

/// A folder of the Files changed tree: its icon and name (single-child folders joined, `docs/help`), not a target.
private struct PRFolderRow: View {
    /// Each level's indent.
    static let indent: CGFloat = 14
    let name: String
    let depth: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.settingsCaption)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(minHeight: SidebarItemStyle.height)
        .padding(.leading, CGFloat(depth) * Self.indent)
        .help(name)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Checks

private struct PRChecksTab: View {
    let checks: Loadable<[HostedCheckRun]>
    /// The host's product name ("GitHub", "GitLab").
    let hostName: String

    var body: some View {
        switch checks {
        case .loaded(let runs):
            SectionCard("Checks", systemImage: PRTab.checks.systemImage, count: runs.count, contentPadding: 6) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary(runs))
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 2)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(runs) { PRCheckRow(run: $0, hostName: hostName) }
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        case .failed(let message):
            DiffNoticeCard(title: "Checks", systemImage: "exclamationmark.triangle", message: message)
        case .loading:
            PRPartLoading(tab: .checks)
        case .idle:
            DiffNoticeCard(title: "Checks", systemImage: "exclamationmark.triangle", message: "Not loaded.")
        }
    }

    private func summary(_ runs: [HostedCheckRun]) -> String {
        guard let state = ChecksState(runs) else { return "No checks ran on the head commit." }
        return switch state {
        case .success: "All checks passed."
        case .failure: "Some checks failed."
        case .pending: "Some checks are still running."
        }
    }
}

/// A check run: its state glyph, name, conclusion and duration; a click opens it on GitHub.
private struct PRCheckRow: View {
    let run: HostedCheckRun
    let hostName: String
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(run.name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(detail)
                .font(.settingsCaption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button {
                GitHubLinks.open(run.htmlURL)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(RowIconButtonStyle())
            .help("Open this check on \(hostName)")
            .accessibilityLabel("Open \(run.name) on \(hostName)")
        }
        .padding(.horizontal, 8)
        .frame(minHeight: SidebarItemStyle.height)
        .background(Capsule().fill(hovered ? Palette.hoverFill : .clear))
        .animation(Motion.hover, value: hovered)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
    }

    private var isFailure: Bool {
        ["failure", "timed_out", "cancelled", "action_required", "startup_failure"].contains(run.conclusion ?? "")
    }

    private var symbol: String {
        if run.status != "completed" { return "circle.dotted" }
        if isFailure { return "xmark.circle.fill" }
        return run.conclusion == "success" ? "checkmark.circle.fill" : "minus.circle"
    }

    private var tint: Color {
        if run.status != "completed" { return Color(nsColor: Palette.conflictB) }
        if isFailure { return Color(nsColor: Palette.diffRemovedSign) }
        return run.conclusion == "success" ? Color(nsColor: Palette.diffAddedSign) : .secondary
    }

    /// "success · 4m 0s", "in progress", "queued".
    private var detail: String {
        guard run.status == "completed" else { return run.status.replacingOccurrences(of: "_", with: " ") }
        let conclusion = (run.conclusion ?? "completed").replacingOccurrences(of: "_", with: " ")
        guard let start = run.startedAt, let end = run.completedAt, end >= start else { return conclusion }
        let seconds = Int(end.timeIntervalSince(start))
        let duration = seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
        return "\(conclusion) · \(duration)"
    }
}

// MARK: Skeleton

/// A tab's part while it still loads (the Conversation shows first): its card, with a spinner once that takes a while.
private struct PRPartLoading: View {
    let tab: PRTab
    /// The part still loads (`DelayedSpinner.isCurrent`): Azure's local diff may land just before the delay ends.
    var isCurrent: @MainActor () -> Bool = { true }

    var body: some View {
        SectionCard(tab.title, systemImage: tab.systemImage, countIsLoading: true) {
            DelayedSpinner(detail: "pr \(tab.rawValue)", isCurrent: isCurrent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The loading detail in the loaded Conversation's arrangement: the Conversation card's lines, the merge box and the
/// comment box under it, and the side column's cards on the right, or at the end of the column when panel2 is narrow.
private struct PRSkeleton: View {
    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= PRConversationTab.wideEnough
            HStack(alignment: .top, spacing: PRConversationTab.columnGap) {
                // A scroll view like the loaded column's (still: the placeholder takes no events), so a column taller
                // than the panel is cut at its bottom edge as the loaded one is.
                ScrollView {
                    VStack(spacing: SectionCardMetrics.spacing) {
                        SectionCard("Conversation", systemImage: "text.bubble", countIsLoading: true) {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 8) {
                                    SkeletonLine(width: 20, height: 20)
                                    SkeletonLine(width: 120, height: 11)
                                }
                                SkeletonLine(fraction: 0.9, height: 11)
                                SkeletonLine(fraction: 0.75, height: 11)
                                SkeletonLine(fraction: 0.55, height: 11)
                            }
                        }
                        SectionCard("Actions", systemImage: "bolt") {
                            VStack(alignment: .leading, spacing: 10) {
                                // The status box's shape, with its icon and two lines.
                                HStack(spacing: 10) {
                                    SkeletonLine(width: 18, height: 18)
                                    VStack(alignment: .leading, spacing: 6) {
                                        SkeletonLine(width: 160, height: 11)
                                        SkeletonLine(width: 110, height: 11)
                                    }
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: SettingsInputMetrics.cornerRadius,
                                                             style: .continuous).fill(Palette.tabFill))
                                HStack(spacing: 8) {
                                    SkeletonLine(width: 110, height: 24)
                                    SkeletonLine(width: 70, height: 24)
                                }
                            }
                        }
                        SectionCard("Comment", systemImage: "square.and.pencil") {
                            VStack(alignment: .leading, spacing: 8) {
                                RoundedRectangle(cornerRadius: SettingsInputMetrics.cornerRadius, style: .continuous)
                                    .fill(Palette.skeletonFill)
                                    .skeletonPulse()
                                    .frame(height: 64)
                                HStack {
                                    Spacer(minLength: 0)
                                    SkeletonLine(width: 90, height: 24)
                                }
                            }
                            .padding(.top, 8)
                        }
                        if !wide { sideCards }
                    }
                }
                if wide {
                    VStack(spacing: SectionCardMetrics.spacing) {
                        sideCards
                        Spacer(minLength: 0)
                    }
                    .frame(width: 220)
                }
            }
        }
    }

    private var sideCards: some View {
        ForEach(["Reviewers", "Assignees", "Labels"], id: \.self) { title in
            SectionCard(title, countIsLoading: true) {
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonLine(fraction: 0.8, height: 11)
                    SkeletonLine(fraction: 0.5, height: 11)
                }
            }
        }
    }
}

private extension HostingKind {
    /// Whether the host says if a pull request's branch merges cleanly (GitHub's `mergeable`, GitLab's merge status).
    /// Bitbucket Cloud's API has no such field: it only refuses a merge that conflicts.
    var reportsMergeability: Bool {
        switch self {
        case .github, .gitlab: true
        // Data Center: false until its client reads the merge state; Azure DevOps until its client reads `mergeStatus`.
        case .bitbucketCloud, .bitbucketDataCenter, .azureDevOps: false
        }
    }

    /// What follows a pull request's web URL for its changed files: GitHub's `/files`, GitLab's `/diffs`, Bitbucket's
    /// `/diff` (Cloud and Data Center), Azure DevOps' `?_a=files` (its Files tab).
    var filesPagePath: String {
        switch self {
        case .github: "/files"
        case .gitlab: "/diffs"
        case .bitbucketCloud, .bitbucketDataCenter: "/diff"
        case .azureDevOps: "?_a=files"
        }
    }
}
