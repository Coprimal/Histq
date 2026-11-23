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

    var isMerged: Bool { pull.mergedAt != nil || pull.merged == true }
    var isOpen: Bool { pull.state == "open" }
}

/// A GitHub action of the detail.
enum PullRequestAction: Equatable, Sendable {
    /// `sha`: the head the user saw when confirming; GitHub refuses the merge once the head moved.
    case merge(HostedMergeMethod, sha: String)
    case review(HostedReviewEvent, body: String)
    case comment(String)
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

    var progressTitle: String {
        switch self {
        case .merge: "Merging…"
        case .review: "Submitting the review…"
        case .comment: "Commenting…"
        case .setOpen(let open): open ? "Reopening…" : "Closing…"
        case .reply: "Replying…"
        case .resolve(_, let resolved): resolved ? "Resolving…" : "Unresolving…"
        case .unapprove: "Revoking the approval…"
        case .general(let action): action.progressTitle
        case .newInline: "Commenting…"
        }
    }

    var failureTitle: String {
        switch self {
        case .merge: "Merge failed"
        case .review: "The review was not submitted"
        case .comment: "The comment was not posted"
        case .setOpen(let open): open ? "Reopen failed" : "Close failed"
        case .reply: "The reply was not posted"
        case .resolve(_, let resolved): resolved ? "Resolve failed" : "Unresolve failed"
        case .unapprove: "The approval was not revoked"
        case .general(let action): action.failureTitle
        case .newInline: "The comment was not posted"
        }
    }

    /// The failure's title when another pull request shows by the time it returns: it names `number` (`#12`, `!12`).
    func failureTitle(of number: String) -> String {
        switch self {
        case .merge: "Merge of \(number) failed"
        case .review: "The review of \(number) was not submitted"
        case .comment: "The comment on \(number) was not posted"
        case .setOpen(let open): open ? "Reopen of \(number) failed" : "Close of \(number) failed"
        case .reply: "The reply on \(number) was not posted"
        case .resolve(_, let resolved): resolved ? "Resolve on \(number) failed" : "Unresolve on \(number) failed"
        case .unapprove: "The approval of \(number) was not revoked"
        case .general(let action): action.failureTitle(of: number)
        case .newInline: "The comment on \(number) was not posted"
        }
    }

    /// The timing log's word (`content pr 1 action merge ok`).
    var timingName: String {
        switch self {
        case .merge(let method, _): "merge-\(method.rawValue)"
        case .review(let event, _): "review-\(event.rawValue.lowercased())"
        case .comment: "comment"
        case .setOpen(let open): open ? "reopen" : "close"
        case .reply: "reply"
        case .resolve(_, let resolved): resolved ? "resolve" : "unresolve"
        case .unapprove: "unapprove"
        case .general(let action): action.timingName
        case .newInline: "new-inline-post"
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
    static let all: [HostedMergeMethod] = [.merge, .squash, .rebase]

    var title: String {
        switch self {
        case .merge: "Merge commit"
        case .squash: "Squash"
        case .rebase: "Rebase"
        }
    }

    var buttonTitle: String {
        switch self {
        case .merge: "Merge"
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
    var reviewEvent: HostedReviewEvent = .approve
    var mergeMethod: HostedMergeMethod = .merge
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
    /// DEBUG `-HistqPRAction <action>` (`comment`, `approve`, `request-changes`, `unapprove`, `merge`, `merge-stale`,
    /// `merge-stale-closed`, `close`, `reopen`): runs that action once, on the first load, without its confirmation
    /// (the stub answers it), so a launch exercises the action path and its reload. Only with `-HistqGitHubStub YES`:
    /// never an unconfirmed action on a real account.
    /// `resolve-manual` is the merge box's own (`PRActionsCard.launchResolve`): a local merge, not a GitHub action.
    private static var launchAction: PullRequestAction? = switch GitHubStub.isEnabled
        ? AppState.launchFlag("-HistqPRAction") : nil {
    case "comment": .comment("QA comment")
    case "approve": .review(.approve, body: "")
    case "request-changes": .review(.requestChanges, body: "QA change request")
    case "unapprove": .unapprove
    case "merge": .merge(.squash, sha: GitHubStub.headSHA)
    // A head the stub's PR #1 no longer has: the stub answers 409, as GitHub does after a push.
    case "merge-stale", "merge-stale-closed": .merge(.squash, sha: GitHubStub.staleSHA)
    case "close": .setOpen(false)
    case "reopen": .setOpen(true)
    default: nil
    }
    /// DEBUG `-HistqPRAction reply|resolve|unresolve|greply|gresolve|edit|edit-save|delete|delete-confirm|react|`
    /// `react-new|new-inline|new-inline-post`: like `launchAction`, on a review thread (or a general thread:
    /// `greply`, `gresolve`; or the first own comment: `edit` opens its editor, `edit-save` saves "edited" into it,
    /// `delete` opens its confirmation, `delete-confirm` confirms it; or the first comment with reactions, `react`, or
    /// with none, `react-new`, gets a reaction; or the first added line of the first file: `new-inline` opens a new
    /// comment box under it, `new-inline-post` posts "stub inline" there) of the first load, which picks it
    /// (`threadLaunchAction(_:in:)`): only with `-HistqGitHubStub YES` too.
    private static var threadLaunchActionName: String? = GitHubStub.isEnabled
        ? AppState.launchFlag("-HistqPRAction").flatMap {
            ["reply", "resolve", "unresolve", "greply", "gresolve", "edit", "edit-save", "delete", "delete-confirm",
             "react", "react-new", "new-inline", "new-inline-post"].contains($0) ? $0 : nil
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

    /// Loads pull request `number`; `quiet` keeps the shown detail until the new one is in (after an action).
    func load(_ number: Int, github: HostingStore, quiet: Bool = false) {
        task?.cancel()
        generation &+= 1
        if number != self.number {
            // Another pull request: its own tab, file and box. The same one opened again keeps them (and the draft).
            tab = Self.launchTab ?? .conversation
            selectedFile = nil
            composer = .comment
            draft = ""
            reviewEvent = .approve
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
        let rowSHA = github.row(for: .pullRequest(number))?.headSHA
        let warmsUp = state.value == nil
        task = Task { [weak self] in
            let (client, repository) = (api.client, api.repository)
            await withTaskGroup(of: Part?.self) { [weak self] group in
                // Commits, files and checks load beside the Conversation's parts and fill in as each arrives; the
                // checks start with the row's head, asked again below only when the pull request's is another one.
                group.addTask { await Self.fetchCommits(client, repository, number: number) }
                group.addTask { await Self.fetchFiles(client, repository, number: number) }
                if let rowSHA { group.addTask { await Self.fetchChecks(client, repository, sha: rowSHA) } }
                async let fetched = Self.fetch(
                    client, repository, number: number, loadID: loadID, expanded: expanded, general: general)
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
                switch result {
                case .success(var detail):
                    let sha = detail.pull.head.sha
                    if sha != rowSHA { group.addTask { await Self.fetchChecks(client, repository, sha: sha) } }
                    // The parts shown for the same head stay until this load's arrive (a revisit, a reload after an
                    // action), so their tabs do not go back to loading.
                    if let shown = state.value, shown.pull.number == number, shown.pull.head.sha == sha {
                        detail.commits = shown.commits
                        detail.files = Self.joined(shown.files, detail.threads)
                        detail.checks = shown.checks
                    }
                    state = .loaded(detail)
                    Self.logMergeable(detail.pull)
                    Self.logThreads(detail)
                    if quiet { UITiming.content("pr \(number) reloaded") }
                    #if DEBUG
                    if let action = Self.launchAction {
                        Self.launchAction = nil
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
            detail.pull = pull
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
        let expanded = threadExpanded
        // "#12 Merging…" in the footer.
        let reference = github.kind.reference(.pullRequest(number))
        let endOperation = beginOperation("\(reference) \(action.progressTitle.dropLast())")
        Task { [weak self, ready, threadShown] in
            if let optimistic, ready == nil {
                let page = await Self.page(
                    optimistic.shown, comments: optimistic.comments, threads: optimistic.threads,
                    noun: api.client.kind.pullRequestNoun, expanded: expanded, general: optimistic.general)
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
                if case .general(.edit(let target, let body)) = action, self.number == number {
                    reopenEdit(target.key, body: body)
                    if editingComments.contains(target.key) {
                        UITiming.content("pr \(number) action edit reopened cedit-\(target.key) open")
                    }
                }
                // The box comes back with the text, unless another one was opened meanwhile.
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
            case .comment, .review: if self.number == number { draft = "" }
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
            case .unapprove, .newInline: break
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

    /// The Conversation's page of `detail` with `comments` and `threads` instead of its own (an optimistic action's).
    @concurrent
    private nonisolated static func page(
        _ detail: PullRequestDetail, comments: [HostedComment], threads: Loadable<PRThreads>, noun: String,
        expanded: [Int: Bool], general: PRGeneralOptions
    ) async -> PRTimelineHTML {
        timeline(detail.pull, noun: noun, comments: comments, reviews: detail.reviews, threads: threads,
                 expanded: expanded, general: general)
    }

    /// The Conversation's page: the description of `pull` (a `noun`), then `comments`, `reviews` and `threads`.
    private nonisolated static func timeline(
        _ pull: HostedPullRequest, noun: String, comments: [HostedComment], reviews: [HostedReview],
        threads: Loadable<PRThreads>, expanded: [Int: Bool], general: PRGeneralOptions
    ) -> PRTimelineHTML {
        PRTimeline.page(
            author: pull.user, action: "opened this \(noun.lowercased())", date: pull.createdAt, html: pull.bodyHTML,
            markdown: pull.body, comments: comments, reviews: reviews, threads: threads, expanded: expanded,
            general: general)
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
        general: PRGeneralOptions
    ) async -> Result<PullRequestDetail, any Error> {
        async let pullRequest = client.pullRequest(number, in: repository)
        async let comments = client.comments(on: .pullRequest(number), in: repository)
        async let reviews = client.reviews(of: number, in: repository)
        async let reviewComments = part(client.kind) { try await client.reviewComments(of: number, in: repository) }
        async let threadStates = part(client.kind) { try await client.reviewThreadStates(of: number, in: repository) }
        // Only a provider that can revoke an approval or reply to general comments asks who the token's user is; a
        // failure only hides the button (or draws an optimistic reply as "you").
        let asksViewer = !client.capabilities.isDisjoint(with: [.unapprove, .generalReplies])
        async let viewer = asksViewer ? try? await client.currentUser() : nil
        do {
            let pull = try await pullRequest
            let (comments, reviews) = try await (comments, reviews)
            let threads = Self.threads(await reviewComments, await threadStates, hostName: client.kind.name)
            let timeline = timeline(
                pull, noun: client.kind.pullRequestNoun, comments: comments, reviews: reviews, threads: threads,
                expanded: expanded, general: general)
            let reviewers = reviewers(pull, reviews)
            let viewer = await viewer
            let viewerApproved = viewer.map { viewer in
                client.capabilities.contains(.unapprove)
                    && reviewers.contains { $0.userID == viewer.id && $0.state == "APPROVED" }
            } ?? false
            return .success(PullRequestDetail(
                loadID: loadID, pull: pull, timelineCount: timeline.count, timeline: timeline, comments: comments,
                reviews: reviews, viewer: viewer, reviewers: reviewers, commits: .loading,
                files: .loading, checks: .loading, threads: threads,
                viewerApproved: viewerApproved))
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
        let read = await part(client.kind) { try await client.pullRequestFiles(number, in: repository) }
        let files: Loadable<[PRFile]> = switch read {
        case .loaded(let files): .loaded(files.map(prFile))
        case .failed(let message): .failed(message)
        case .idle, .loading: .idle
        }
        return .files(files)
    }

    @concurrent
    private nonisolated static func fetchChecks(
        _ client: any HostingProvider, _ repository: HostedRepository, sha: String
    ) async -> Part? {
        .checks(sha: sha, await part(client.kind) { try await client.checkRuns(for: sha, in: repository) })
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

    private nonisolated static func part<T: Sendable>(
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
            case .merge(let method, let sha): try await client.merge(number, in: repository, method: method, sha: sha)
            case .review(let event, let body):
                _ = try await client.review(number, in: repository, event: event, body: body.isEmpty ? nil : body)
            case .comment(let body): _ = try await client.comment(on: .pullRequest(number), in: repository, body: body)
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

/// Back, the title and number, the state pill and Open on GitHub; the "wants to merge" line; the tabs with their
/// counts. The title comes from the PRs tab's row until the pull request is in.
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
                        PRStatePill(detail: value)
                            .fixedSize()
                        if narrow {
                            Button {
                                GitHubLinks.open(session.github.webURL(.pullRequest(value.pull.number)))
                            } label: {
                                Image(systemName: "safari")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(RowIconButtonStyle())
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
                        summary(value)
                    } else {
                        SkeletonLine(width: 260, height: 12)
                            .frame(height: 20)
                    }
                }
                // As tall as the sentence while it loads too (a chip's height a line), so the tabs do not move when
                // it comes.
                .frame(height: narrow ? 46 : 20, alignment: .topLeading)
                .padding(.leading, 8)
                // At its own width, scrolled sideways in a panel narrower than it, never wider than the card.
                ViewThatFits(in: .horizontal) {
                    tabs(value)
                    ScrollView(.horizontal) {
                        tabs(value)
                    }
                    .scrollIndicators(.never)
                }
                .padding(.leading, 4)
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
    private func summary(_ value: PullRequestDetail) -> some View {
        let pull = value.pull
        let count = pull.commits ?? value.commits.value?.count ?? 0
        let verb = value.isMerged ? "merged" : value.isOpen ? "wants to merge" : "wanted to merge"
        let layout = narrow
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        return layout {
            HStack(spacing: 6) {
                Text(pull.user?.login ?? "ghost")
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
            }
        }
        .font(.body)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
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

    private func tabs(_ value: PullRequestDetail?) -> some View {
        @Bindable var detail = session.pullDetail
        return CapsuleTabs(selection: $detail.tab, tabs: PRTab.allCases, title: { tab in tabTitle(tab, value) },
                           compact: true, raisedTrack: true)
            .fixedSize()
    }

    private func tabTitle(_ tab: PRTab, _ value: PullRequestDetail?) -> Text {
        let count: Int? = switch tab {
        case .conversation: value?.timelineCount
        case .commits: value?.commits.value?.count
        case .files: value?.files.value?.count
        case .checks: value?.checks.value?.count
        }
        guard let count else { return Text(tab.title) }
        return Text(tab.title) + Text(" \(count)").monospacedDigit()
    }
}

/// Open (green), Draft, Merged (the brand blue) or Closed (red), as on GitHub.
private struct PRStatePill: View {
    let detail: PullRequestDetail

    var body: some View {
        let (title, symbol, fill, text): (String, String, Color, Color) =
            if detail.isMerged {
                ("Merged", "arrow.triangle.merge", Palette.mergedTone, Palette.onAccent)
            } else if !detail.isOpen {
                ("Closed", "xmark.circle", Color(nsColor: Palette.diffRemovedFill), Color(nsColor: Palette.diffRemovedSign))
            } else if detail.pull.draft == true {
                ("Draft", "circle.dashed", Palette.inputSurface, .secondary)
            } else {
                ("Open", "lucide-git-pull-request-arrow", Color(nsColor: Palette.diffAddedFill), Color(nsColor: Palette.diffAddedSign))
            }
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
            PRCommitsTab(commits: detail.commits, github: session.github)
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

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= Self.wideEnough
            // One tree at both widths: the middle column keeps its page (and its web view) when panel2 crosses
            // `wideEnough`, and only the side cards move.
            HStack(alignment: .top, spacing: Self.columnGap) {
                ScrollView {
                    main(sideCards: !wide)
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
            SectionCard("Conversation", systemImage: "text.bubble", count: detail.timelineCount) {
                // The page fits its content and never scrolls itself: a wheel over the text or over a native view on
                // the page scrolls this column.
                PRTimelinePage(session: session, number: detail.pull.number, timeline: detail.timeline,
                               loadID: detail.loadID, threads: detail.threads.value,
                               avatars: .of(session.github), general: session.pullDetail)
                    .frame(maxWidth: .infinity)
            }
            PRActionsCard(session: session, detail: detail)
            PRComposerCard(session: session, detail: detail)
            if sideCards {
                PRSideColumn(session: session, detail: detail)
            }
        }
    }
}

/// The comment box: a plain comment, or a review (approve, request changes, comment) with its body.
private struct PRComposerCard: View {
    let session: RepoSession
    let detail: PullRequestDetail

    var body: some View {
        @Bindable var model = session.pullDetail
        let isReview = model.composer == .review
        SectionCard(isReview ? "Review" : "Comment", systemImage: isReview ? "checkmark.bubble" : "square.and.pencil") {
            VStack(alignment: .leading, spacing: 8) {
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
                    if isReview {
                        CapsuleMenuPicker(label: "Review", selection: $model.reviewEvent,
                                          title: Text(model.reviewEvent.title)) {
                            ForEach(reviewEvents, id: \.self) { Text($0.title).tag($0) }
                        }
                    }
                    Spacer(minLength: 8)
                    if isReview, detail.viewerApproved, session.github.offers(.unapprove) {
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
                            Text(isReview ? "Submit Review" : "Comment")
                        }
                    }
                    .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                    .disabled(!canSubmit(model))
                    .help(isReview && model.reviewEvent != .approve && trimmed(model).isEmpty
                          ? "A review that requests changes or comments needs a text" : "")
                }
            }
            // Room between the header (with its Comment / Review choice) and the text box (user, 2026-11-17).
            .padding(.top, 8)
        } accessory: {
            CapsuleTabs(selection: $model.composer, tabs: PullRequestDetailModel.Composer.allCases,
                        title: { Text($0.title) }, compact: true, small: true, raisedTrack: true)
                .fixedSize()
        }
    }

    /// The review events the provider takes: Request changes only where it has them.
    private var reviewEvents: [HostedReviewEvent] {
        HostedReviewEvent.all.filter { $0 != .requestChanges || session.github.offers(.requestChanges) }
    }

    private func placeholder(_ model: PullRequestDetailModel) -> String {
        guard model.composer == .review else { return "Leave a comment" }
        return model.reviewEvent == .approve ? "Approve, with an optional comment" : "Say what to change"
    }

    private func trimmed(_ model: PullRequestDetailModel) -> String {
        model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isBusy(_ model: PullRequestDetailModel) -> Bool {
        switch model.running {
        case .comment, .review: true
        default: false
        }
    }

    private func canSubmit(_ model: PullRequestDetailModel) -> Bool {
        guard model.running == nil else { return false }
        // GitHub requires a body for a change request and a comment review; an approval may have none.
        if model.composer == .review, model.reviewEvent == .approve { return true }
        return !trimmed(model).isEmpty
    }

    private func submit(_ model: PullRequestDetailModel) {
        guard canSubmit(model) else { return }
        let body = trimmed(model)
        let action: PullRequestAction = model.composer == .review
            ? .review(model.reviewEvent, body: body) : .comment(body)
        guard let number = model.number else { return }
        model.perform(action, on: number, github: session.github)
    }
}

/// The right column: reviewers, assignees and labels, each in its own card.
private struct PRSideColumn: View {
    let session: RepoSession
    let detail: PullRequestDetail

    var body: some View {
        let avatars = HostAvatars.of(session.github)
        VStack(spacing: SectionCardMetrics.spacing) {
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
        }
    }
}

/// The merge box under the timeline, as on GitHub: for an open pull request, a status box saying whether its branch
/// merges (green, red with conflicts, amber when blocked, neutral otherwise) and Merge (method, then a confirmation);
/// then Checkout locally, Close or Reopen (confirmed), and the running action. With conflicts, the red box holds
/// Resolve with AI and Resolve manually.
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
        let pull = detail.pull
        let busy = session.pullDetail.busy[pull.number]
        SectionCard("Actions", systemImage: "bolt") {
            VStack(alignment: .leading, spacing: 10) {
                if detail.isMerged {
                    mergedBox
                } else if detail.isOpen {
                    statusBox
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
    private var status: (tone: Color?, symbol: String, title: String, note: String?) {
        let pull = detail.pull
        let base = pull.base.ref
        if hasConflicts {
            return (Color(nsColor: Palette.diffRemovedSign), "exclamationmark.triangle.fill",
                    "This branch has conflicts that must be resolved",
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
            return (Color(nsColor: Palette.diffAddedSign), "checkmark.circle.fill", "No conflicts with \(base)",
                    "This branch can be merged.")
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

    /// `date` in the user's date format (Settings › Appearance), as the conversation's dates.
    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Locale.current.identifier)
        formatter.dateFormat = Preferences.defaults.string(forKey: PrefKey.dateFormat.rawValue) ?? "MM/dd/yy @ HH:mm"
        return formatter.string(from: date)
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
                    Text(verbatim: "On \(Self.dateText(date))")
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
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
    /// (user, 2026-11-17). The red one holds the Resolve buttons under its text.
    private var statusBox: some View {
        let status = status
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
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(status.tone?.opacity(0.14) ?? Palette.tabFill))
        .overlay(shape.strokeBorder(status.tone?.opacity(0.35) ?? Palette.surfaceBorder, lineWidth: 1))
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
        @Bindable var pullDetail = session.pullDetail
        let pull = detail.pull
        CapsuleMenuPicker(label: "Merge method", selection: $pullDetail.mergeMethod,
                          title: Text(pullDetail.mergeMethod.title)) {
            ForEach(session.github.mergeMethods, id: \.self) { Text($0.title).tag($0) }
        }
        Button("Merge") { confirmMerge(pullDetail.mergeMethod) }
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
                    Text(open ? "Close \(noun)" : "Reopen \(noun)")
                }
            }
            .buttonStyle(RowTextButtonStyle(formRow: true))
            .fixedSize()
            .disabled(busy != nil)
        }
    }

    /// Merges the head this detail shows: the sha goes with the merge, so a push after this confirmation fails it.
    private func confirmMerge(_ method: HostedMergeMethod) {
        let pull = detail.pull
        let count = pull.commits ?? detail.commits.value?.count ?? 0
        let how = switch method {
        case .merge: "with a merge commit"
        case .squash: "squashed into one commit"
        case .rebase: "rebased onto \(pull.base.ref)"
        }
        let kind = session.github.kind
        model.presentModal(.confirmation(ModalConfirmation(
            title: "\(method.buttonTitle) \(kind.reference(.pullRequest(pull.number)))?",
            message: "\(kind.name) merges \(count) \(count == 1 ? "commit" : "commits") of \(pull.head.ref) into "
                + "\(pull.base.ref), \(how). Histq cannot undo a merge on \(kind.name).",
            button: method.buttonTitle, isDestructive: false,
            perform: { [session, sha = pull.head.sha, number = pull.number, head = pull.head.ref,
                        sameRepository = pull.isFromSameRepository] in
                session.pullDetail.perform(.merge(method, sha: sha), on: number, github: session.github) {
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
        model.presentModal(.confirmation(ModalConfirmation(
            title: open ? "Reopen \(reference)?" : "Close \(reference)?",
            message: open
                ? "The \(noun) opens again on \(kind.name)."
                : "The \(noun) closes on \(kind.name) without merging; it can be reopened later.",
            button: open ? "Reopen" : "Close \(kind.pullRequestNoun.capitalized)", isDestructive: !open,
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
    /// The API's `avatar_url` of the account, in the real avatar mode only, from the repository's `host`
    /// (`AvatarStore.hostedAvatar`): GitLab.
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
        // `AvatarStore.hostedIdentity` loads only from the repository's own host, and Bitbucket's `links.avatar.href`
        // is expected on another one (Atlassian's avatar service or Gravatar; not yet seen on a real account).
        case .bitbucketCloud: return .drawn
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
    let github: HostingStore

    var body: some View {
        switch commits {
        case .loaded(let commits):
            SectionCard("Commits", systemImage: PRTab.commits.systemImage, count: commits.count, contentPadding: 6) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(commits) {
                            PRCommitRow(commit: $0, url: github.webURL(.commit($0.sha)), hostName: github.kind.name)
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
}

/// A commit: its subject, author and date, and its short id, which opens it on GitHub.
private struct PRCommitRow: View {
    let commit: HostedCommit
    /// The commit's page on the host.
    let url: URL?
    /// The host's product name ("GitHub", "GitLab").
    let hostName: String
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
                        Text(verbatim: "\(author) committed \(date.formatted(date: .abbreviated, time: .shortened))")
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
                Text(String(commit.sha.prefix(7)))
                    .font(.settingsCaption.monospaced())
            }
            .buttonStyle(RowTextButtonStyle())
            .help("Open this commit on \(hostName)")
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
                            ForEach(files) { file in
                                PRFileRow(file: file, selected: file.id == session.pullDetail.selectedFile) {
                                    session.pullDetail.selectedFile = file.id
                                }
                            }
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(width: Self.listWidth)
                .frame(maxHeight: .infinity)
                if let file = files.first(where: { $0.id == session.pullDetail.selectedFile }) ?? files.first {
                    diffCard(file)
                }
            }
        case .failed(let message):
            DiffNoticeCard(title: "Files changed", systemImage: "exclamationmark.triangle", message: message)
        case .loading:
            PRPartLoading(tab: .files)
        case .idle:
            DiffNoticeCard(title: "Files changed", systemImage: "exclamationmark.triangle", message: "Not loaded.")
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
        let dates = Self.dateFormatter()
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
                        author: comment.user?.login ?? "ghost", date: comment.createdAt.map(dates.string) ?? "",
                        body: (comment.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines), isReply: index > 0)
                })
        }
        return DiffInlineThreads(
            path: file.id, threads: threads,
            collapsed: Set(file.threads.filter { PRTimeline.isCollapsed($0, expanded: expanded) }.map(\.id)),
            onToggle: { [session] id, collapsed in session.pullDetail.threadExpanded[id] = !collapsed },
            onReply: { [session] in session.pullDetail.tab = .conversation },
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

    /// The user's date format (Settings › Appearance, 24 h by default), as the Conversation page dates its comments;
    /// made again only when the format changes.
    private static var dates: (format: String, formatter: DateFormatter)?

    private static func dateFormatter() -> DateFormatter {
        let format = Preferences.defaults.string(forKey: PrefKey.dateFormat.rawValue) ?? "MM/dd/yy @ HH:mm"
        if let dates, dates.format == format { return dates.formatter }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Locale.current.identifier)
        formatter.dateFormat = format
        dates = (format, formatter)
        return formatter
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
                if !file.change.folder.isEmpty {
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

    var body: some View {
        SectionCard(tab.title, systemImage: tab.systemImage, countIsLoading: true) {
            DelayedSpinner(detail: "pr \(tab.rawValue)")
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
        case .bitbucketCloud: false
        }
    }

    /// What follows a pull request's web URL for its changed files: GitHub's `/files`, GitLab's `/diffs`, Bitbucket's
    /// `/diff`.
    var filesPagePath: String {
        switch self {
        case .github: "/files"
        case .gitlab: "/diffs"
        case .bitbucketCloud: "/diff"
        }
    }
}
