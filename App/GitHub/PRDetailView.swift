// A pull request in panel2, laid out like GitHub's page, each part in its own card: the header (back, title, number,
// state pill, "author wants to merge N commits into base from head", the tabs), then the selected tab: Conversation
// (the description, comments and reviews in one `HostedHTMLView`, the comment and review box, and a side column with
// the actions, reviewers, assignees and labels), Commits, Files changed (the file list and the selected file's patch in
// a read-only `DiffLineTable`, parsed from GitHub's `patch` with git's diff parser, so no local git is needed) and
// Checks. The row click shows the header and skeleton cards in the same frame (`PlaceholderCard`); everything loads
// off the main actor in one go (`PullRequestDetailModel`). The actions call GitHub through the tab's `HostingStore`
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
    /// The threads whose root has no review, shown at the end of the timeline.
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
/// without the checks permission still reads the pull request): their tab or part then says why.
struct PullRequestDetail: Sendable {
    let loadID: Int
    /// Replaced alone by the model's re-poll while GitHub still computes whether the branch merges.
    var pull: HostedPullRequest
    let timelineCount: Int
    /// The Conversation's page: the description, then comments and reviews by date, each review with its threads
    /// (`PRTimeline.page`).
    let timeline: PRTimelineHTML
    let reviewers: [PRReviewer]
    let commits: Loadable<[HostedCommit]>
    let files: Loadable<[PRFile]>
    let checks: Loadable<[HostedCheckRun]>
    let threads: Loadable<PRThreads>
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

    var progressTitle: String {
        switch self {
        case .merge: "Merging…"
        case .review: "Submitting the review…"
        case .comment: "Commenting…"
        case .setOpen(let open): open ? "Reopening…" : "Closing…"
        case .reply: "Replying…"
        case .resolve(_, let resolved): resolved ? "Resolving…" : "Unresolving…"
        case .unapprove: "Revoking the approval…"
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
        }
    }
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
    private(set) var state: Loadable<PullRequestDetail> = .idle
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
    /// The actions running on GitHub, by pull request: one at a time for each. An action belongs to the pull request it
    /// started on, not to the detail, which may show another one by the time it returns.
    private(set) var busy: [Int: PullRequestAction] = [:]
    /// The last action's failure (or a failed reload after it), above the tabs until dismissed or the next action.
    var actionError: String?

    /// The shown pull request's running action.
    var running: PullRequestAction? { number.flatMap { busy[$0] } }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadCount = 0

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
    /// DEBUG `-HistqPRAction reply|resolve|unresolve`: like `launchAction`, on a review thread of the first load,
    /// which picks it (`threadLaunchAction(_:in:)`): only with `-HistqGitHubStub YES` too.
    private static var threadLaunchActionName: String? = GitHubStub.isEnabled
        ? AppState.launchFlag("-HistqPRAction").flatMap { ["reply", "resolve", "unresolve"].contains($0) ? $0 : nil }
        : nil
    /// `merge-stale-closed`: the detail closes while the merge runs, so its failure is another detail's (the PRs tab's
    /// notice).
    private static let closesAfterLaunchAction = AppState.launchFlag("-HistqPRAction") == "merge-stale-closed"

    /// `reply` posts "QA reply" to the first thread, `resolve` resolves the first unresolved one and `unresolve`
    /// unresolves the first resolved one, whatever `viewerCanResolve` says (the stub answers both); nil when no
    /// thread fits.
    private static func threadLaunchAction(_ name: String, in detail: PullRequestDetail) -> PullRequestAction? {
        let threads = detail.threads.value?.all ?? []
        switch name {
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
            actionError = nil
        }
        self.number = number
        if !quiet || state.value == nil { state = .loading }
        guard let api = github.api else {
            state = .failed("No account is connected for this tab: connect one in Settings › Integrations.")
            return
        }
        let generation = generation
        loadCount &+= 1
        let loadID = loadCount
        // The page is built with the threads the user expanded or collapsed by now.
        let expanded = threadExpanded
        task = Task { [weak self] in
            let result = await Self.fetch(
                api.client, api.repository, number: number, loadID: loadID, expanded: expanded)
            guard let self, generation == self.generation, !Task.isCancelled else { return }
            switch result {
            case .success(let detail):
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
                        perform(action, on: number, github: github)
                    }
                    if Self.closesAfterLaunchAction { close() }
                }
                if let name = Self.threadLaunchActionName {
                    Self.threadLaunchActionName = nil
                    if let action = Self.threadLaunchAction(name, in: detail) {
                        if GitHubHTMLProbe.slotsEnabled {
                            // Like `launchAction`: after the slot probe's passes at both widths.
                            Task { [weak self] in
                                try? await Task.sleep(for: .seconds(6))
                                self?.perform(action, on: number, github: github)
                            }
                        } else {
                            perform(action, on: number, github: github)
                        }
                    }
                }
                #endif
                let names = detail.files.value?.map(\.id) ?? []
                if selectedFile.map({ !names.contains($0) }) ?? true { selectedFile = names.first }
                await pollMergeable(api.client, api.repository, number: number, generation: generation)
            case .failure(let error):
                let kind = api.client.kind
                if quiet, state.value != nil {
                    actionError = "Could not reload the \(kind.pullRequestNoun.lowercased()): "
                        + Self.message(for: error, kind: kind)
                } else {
                    state = .failed(Self.message(for: error, kind: kind))
                }
            }
        }
    }

    /// GitHub answers `mergeable` null while it still computes whether the branch merges (right after an open or a
    /// push): asks again for the pull request alone, 3 s apart and at most 3 times, so "Checking…" clears without a
    /// reload. It runs in the load's task, so a newer load or `close` stops it. An answer with another head than the
    /// shown one is dropped and ends it: Merge pins the head the user reviewed, and GitHub refuses it once it moved.
    private func pollMergeable(
        _ client: any HostingProvider, _ repository: HostedRepository, number: Int, generation: Int
    ) async {
        for _ in 0..<3 {
            guard case .loaded(let shown) = state, shown.isOpen, shown.pull.mergeable == nil else { return }
            try? await Task.sleep(for: .seconds(3))
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
        Task { [weak self] in
            let error = await Self.run(action, hostKey: hostKey, api.client, api.repository, number: number)
            guard let self else { return }
            busy[number] = nil
            UITiming.content("pr \(number) action \(action.timingName) \(error == nil ? "ok" : "failed")")
            let showing = isShowing(number)
            if let error {
                let message = Self.message(for: error, kind: api.client.kind)
                UITiming.content("pr \(number) action error \(message)")
                if showing {
                    actionError = "\(action.failureTitle): \(message)"
                } else {
                    let reference = github.kind.reference(.pullRequest(number))
                    github.actionNotice = "\(action.failureTitle(of: reference)): \(message)"
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
            case .merge, .setOpen, .unapprove: break
            }
            afterSuccess?()
            github.refreshNow()
            if showing { load(number, github: github, quiet: true) }
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
        _ client: any HostingProvider, _ repository: HostedRepository, number: Int, loadID: Int, expanded: [Int: Bool]
    ) async -> Result<PullRequestDetail, any Error> {
        async let pullRequest = client.pullRequest(number, in: repository)
        async let comments = client.comments(on: .pullRequest(number), in: repository)
        async let reviews = client.reviews(of: number, in: repository)
        async let commits = part(client.kind) { try await client.pullRequestCommits(number, in: repository) }
        async let files = part(client.kind) { try await client.pullRequestFiles(number, in: repository) }
        async let reviewComments = part(client.kind) { try await client.reviewComments(of: number, in: repository) }
        async let threadStates = part(client.kind) { try await client.reviewThreadStates(of: number, in: repository) }
        // Only a provider that can revoke an approval asks who the token's user is; a failure only hides the button.
        let asksViewer = client.capabilities.contains(.unapprove)
        async let viewer = asksViewer ? try? await client.currentUser() : nil
        do {
            let pull = try await pullRequest
            async let checks = part(client.kind) { try await client.checkRuns(for: pull.head.sha, in: repository) }
            let (comments, reviews) = try await (comments, reviews)
            let fileList: Loadable<[PRFile]> = switch await files {
            case .loaded(let files): .loaded(files.map(prFile))
            case .failed(let message): .failed(message)
            case .idle, .loading: .idle
            }
            let threads = Self.threads(await reviewComments, await threadStates, hostName: client.kind.name)
            let timeline = PRTimeline.page(
                author: pull.user, action: "opened this \(client.kind.pullRequestNoun.lowercased())",
                date: pull.createdAt, html: pull.bodyHTML,
                markdown: pull.body, comments: comments, reviews: reviews, threads: threads, expanded: expanded)
            let reviewers = reviewers(pull, reviews)
            let viewerID = await viewer?.id
            let viewerApproved = viewerID.map { id in
                reviewers.contains { $0.userID == id && $0.state == "APPROVED" }
            } ?? false
            return .success(PullRequestDetail(
                loadID: loadID, pull: pull, timelineCount: timeline.count, timeline: timeline,
                reviewers: reviewers, commits: await commits, files: fileList, checks: await checks,
                threads: threads, viewerApproved: viewerApproved))
        } catch {
            return .failure(error)
        }
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

extension HostedPullRequest {
    /// The head is a branch of the base's repository, not of a fork: its label's owner is the base's.
    var isFromSameRepository: Bool {
        head.label != nil && head.label?.split(separator: ":").first == base.label?.split(separator: ":").first
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
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(title)
                    } else {
                        SkeletonLine(width: 180, height: 12)
                    }
                    Text(kind.reference(.pullRequest(number)))
                        .font(.body.weight(.semibold))
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

    /// The head as the sentence names it: GitHub's `owner:branch`; on GitLab the branch alone when it is in the same
    /// project (its label's owner is the base's), as GitLab writes it.
    private func headName(_ pull: HostedPullRequest) -> String {
        session.github.kind == .gitlab && pull.isFromSameRepository ? pull.head.ref : pull.head.label ?? pull.head.ref
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
                ("Merged", "arrow.triangle.merge", Palette.primaryFill, Palette.onAccent)
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
                .onAppear { UITiming.content("pr \(number) files \(Self.count(detail.files))") }
        case .checks:
            PRChecksTab(checks: detail.checks, hostName: session.github.kind.name)
                .onAppear { UITiming.content("pr \(number) checks \(Self.count(detail.checks))") }
        }
    }

    private static func count<T>(_ part: Loadable<[T]>) -> String {
        part.value.map { "\($0.count)" } ?? "failed"
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
                               avatars: .of(session.github))
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
                    Label("Merged into \(pull.base.ref)", systemImage: "arrow.triangle.merge")
                        .foregroundStyle(.secondary)
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
        Button("Merge…") { confirmMerge(pullDetail.mergeMethod) }
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
                    Text(open ? "Close \(noun)…" : "Reopen \(noun)…")
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
            if local.commit == pull.head.sha {
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
        case .idle, .loading:
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
        case .idle, .loading:
            DiffNoticeCard(title: "Files changed", systemImage: "exclamationmark.triangle", message: "Not loaded.")
        }
    }

    @ViewBuilder private func diffCard(_ file: PRFile) -> some View {
        if let section = file.section, !section.rows(.diff).isEmpty {
            SectionCard(file.change.name, systemImage: file.change.systemImage, contentPadding: 0) {
                DiffLineTable(section: section, mode: .diff, loadID: detail.loadID,
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
        case .idle, .loading:
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
    /// What follows a pull request's web URL for its changed files: GitHub's `/files`, GitLab's `/diffs`.
    var filesPagePath: String {
        switch self {
        case .github: "/files"
        case .gitlab: "/diffs"
        }
    }
}
