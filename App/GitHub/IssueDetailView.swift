// An issue in panel2, laid out like the pull request detail, each part in its own card: the header (back, title,
// number, state pill, "author opened this issue on <date> · N comments"), the Conversation (the body and the comments
// in one `HostedHTMLView` with native avatars on it, the same page as a pull request's, `PRTimelinePage`) and the
// comment box in one scroll, and a side column with Close/Reopen (confirmed), the assignees and the labels. The row
// click shows the header and skeleton cards in the same frame (`PlaceholderCard`); the issue and its comments load
// off the main actor in one go (`IssueDetailModel`). The actions call GitHub through the tab's `HostingStore` client.
import AppKit
import HistqCore
import SwiftUI

// MARK: - Model

/// Everything the detail shows, read in one load.
struct IssueDetail: Sendable {
    let loadID: Int
    /// The load's "now" (`PRPageDates.loadNow()`), as `PullRequestDetail.now`.
    let now: Date
    /// The account kind's page layout (`PRPageLayout.for`).
    let layout: PRPageLayout
    /// As loaded, or with the award bar's optimistic reaction (`issue.reactions`).
    var issue: HostedIssue
    var commentCount: Int
    /// The body, then the comments by date (`PRTimeline.page`). Rebuilt with `comments` by a general thread action,
    /// before its write (optimistic).
    var timeline: PRTimelineHTML
    /// The page's comments, as loaded (or as an optimistic action patched them).
    var comments: [HostedComment]
    /// The token's user, where the host has general replies (the author of an optimistic reply); nil when unknown.
    let viewer: HostedUser?
    /// The award bar's kinds, as `PullRequestDetail.reactionKinds` (`PRPageLayout.reactionBar`), with
    /// `issue.reactions` the issue's own reactions; empty (no bar) otherwise or when their read failed.
    var reactionKinds: [String] = []
    /// The Activity's history entries (`PRPageLayout.issueActivity`): nil without an Activity, or when their read
    /// failed (the page then shows the comments alone).
    var events: [HostedTimelineEvent]? = nil
    /// The sidebar's Edit menus (`PRPageLayout.sidebar`): who may be assigned and the project's labels; empty
    /// otherwise or when their read failed (no menu).
    var candidates: [HostedUser] = []
    var labelChoices: [HostedLabel] = []

    var isOpen: Bool { issue.state == "open" }
}

/// A GitHub action of the issue detail.
enum IssueAction: Equatable, Sendable {
    case comment(String)
    case setOpen(Bool)
    /// A reply to or a resolve of a general thread, or an edit or delete of an own comment (`PRGeneralAction`), shown
    /// before the host answers (optimistic).
    case general(PRGeneralAction)
    /// The viewer's reaction `kind` added to (`add`) or removed from the issue itself, from the award bar, shown
    /// before the host answers (optimistic).
    case itemReaction(kind: String, add: Bool)
    /// Assigns `users` or adds the labels named (the sidebar's Edit menus, "assign yourself"); adds only.
    case addAssignees([HostedUser])
    case addLabels([String])

    var progressTitle: String {
        switch self {
        case .comment: "Commenting…"
        case .setOpen(let open): open ? "Reopening…" : "Closing…"
        case .general(let action): action.progressTitle
        case .itemReaction(_, let add): add ? "Adding the reaction…" : "Removing the reaction…"
        case .addAssignees: "Assigning…"
        case .addLabels: "Adding the label…"
        }
    }

    var failureTitle: String {
        switch self {
        case .comment: "The comment was not posted"
        case .setOpen(let open): open ? "Reopen failed" : "Close failed"
        case .general(let action): action.failureTitle
        case .itemReaction(_, let add): add ? "The reaction was not added" : "The reaction was not removed"
        case .addAssignees: "The assignee was not added"
        case .addLabels: "The label was not added"
        }
    }

    /// The failure's title when another issue shows by the time it returns: it names `number`.
    func failureTitle(of number: Int) -> String {
        switch self {
        case .comment: "The comment on #\(number) was not posted"
        case .setOpen(let open): open ? "Reopen of #\(number) failed" : "Close of #\(number) failed"
        case .general(let action): action.failureTitle(of: "#\(number)")
        case .itemReaction(_, let add): add ? "The reaction on #\(number) was not added"
            : "The reaction on #\(number) was not removed"
        case .addAssignees: "The assignee of #\(number) was not added"
        case .addLabels: "The label of #\(number) was not added"
        }
    }

    /// The timing log's word (`content issue 2 action comment ok`).
    var timingName: String {
        switch self {
        case .comment: "comment"
        case .setOpen(let open): open ? "reopen" : "close"
        case .general(let action): action.timingName
        case .itemReaction: "issue-react"
        case .addAssignees: "assign"
        case .addLabels: "add-label"
        }
    }
}

/// The open issue of a repo tab: its load, the comment box and the running action. `RepoSession.selectHosted` starts a
/// load in the click's call (`state` is `.loading` when it returns); a newer select or `close` drops an older load's
/// answer.
@Observable
@MainActor
final class IssueDetailModel {
    private(set) var number: Int?
    private(set) var state: Loadable<IssueDetail> = .idle
    var draft = ""
    /// The actions running on GitHub, by issue: one at a time for each. An action belongs to the issue it started on,
    /// not to the detail, which may show another one by the time it returns.
    private(set) var busy: [Int: IssueAction] = [:]
    /// The last action's failure (or a failed reload after it), above the cards until dismissed or the next action.
    var actionError: String?
    /// Each general thread's reply box and the ones the user expanded or collapsed, by root comment id
    /// (`PRGeneralThreadModel`).
    var generalReplyDrafts: [Int: String] = [:]
    var generalExpanded: [Int: Bool] = [:]
    /// The comments being edited in place and their editors' text, by `PRCommentTarget.key` (`PRGeneralThreadModel`).
    var editingComments: Set<String> = []
    var commentEditDrafts: [String: String] = [:]
    /// The Activity's filter and sort (`PRPageLayout.issueActivity`), as `PullRequestDetailModel.activityView`: the
    /// filter is the issue's, the sort the app's.
    private(set) var activityView = PRActivityView()
    #if DEBUG
    var launchDelete: (target: PRCommentTarget, confirm: Bool)?
    #endif

    /// The shown issue's running action.
    var running: IssueAction? { number.flatMap { busy[$0] } }

    /// Shows an action in the tab's footer until the returned closure is called (`RepoSession.beginOperation`). Set by
    /// the session.
    @ObservationIgnored var beginOperation: @MainActor (String) -> @MainActor () -> Void = { _ in {} }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// The ids of optimistic replies (`PullRequestDetailModel`'s rule).
    @ObservationIgnored private var optimisticID = PRPlaceholderID.base

    #if DEBUG
    /// DEBUG `-HistqIssueAction comment|close|reopen|greply|gresolve|edit|edit-save|delete|delete-confirm|react|`
    /// `react-new|issue-react` (`issue-react`: the award bar's first kind, 👍, toggled on the issue itself): runs that action once, on the first load, without its confirmation, so a launch exercises the
    /// action path and its reload. Only with `-HistqGitHubStub YES`: never an unconfirmed action on a real account.
    /// `greply` and `gresolve` act on the first general thread of that load, `edit-save` on its first own comment and
    /// `react` (`react-new`) on its first comment with (without) reactions (`PRGeneralAction.launchAction`); `edit`,
    /// `delete` and `delete-confirm` open its editor or its confirmation (`openLaunchStep`).
    private static var launchActionName: String? = GitHubStub.isEnabled
        ? AppState.launchFlag("-HistqIssueAction") : nil

    private static func launchAction(_ name: String, in detail: IssueDetail) -> IssueAction? {
        switch name {
        case "comment": .comment("QA comment")
        case "close": .setOpen(false)
        case "reopen": .setOpen(true)
        case "issue-react":
            detail.reactionKinds.first.map { kind in
                IssueAction.itemReaction(
                    kind: kind, add: !detail.issue.reactions.contains { $0.kind == kind && $0.viewerReacted })
            }
        default: PRGeneralAction.launchAction(name, in: detail.comments, page: detail.timeline).map { .general($0) }
        }
    }

    /// `edit` opens the first own comment's editor, `delete` and `delete-confirm` its confirmation (the page opens it,
    /// `launchDelete`); nothing for another name or when no comment fits.
    private func openLaunchStep(_ name: String, in detail: IssueDetail) {
        guard let target = PRGeneralAction.launchTarget(name, in: detail.comments, page: detail.timeline),
              let number else { return }
        switch name {
        case "edit":
            beginEdit(target)
            UITiming.content("issue \(number) action edit open")
        case "delete", "delete-confirm": launchDelete = (target, name == "delete-confirm")
        default: break
        }
    }
    #endif

    /// Loads issue `number`; `quiet` keeps the shown detail until the new one is in (after an action).
    func load(_ number: Int, github: HostingStore, quiet: Bool = false) {
        task?.cancel()
        generation &+= 1
        if number != self.number {
            // Another issue: its own box. The same one opened again keeps its draft.
            draft = ""
            generalReplyDrafts = [:]
            generalExpanded = [:]
            editingComments = []
            commentEditDrafts = [:]
            activityView.filter = PRActivity.all
            actionError = nil
        }
        self.number = number
        if !quiet || state.value == nil { state = .loading }
        guard let api = github.api else {
            state = .failed("No account is connected for this tab: connect one in Settings › Integrations.")
            return
        }
        let generation = generation
        let general = PRGeneralOptions(api.client, expanded: generalExpanded)
        let now = PRPageDates.loadNow()
        // The sort is the app's: another tab may have changed it since.
        activityView.newestFirst = Preferences.defaults.bool(forKey: PRActivityView.newestFirstKey)
        let activityView = activityView
        task = Task { [weak self] in
            let result = await Self.fetch(api.client, api.repository, number: number, loadID: generation,
                                          general: general, now: now, activityView: activityView)
            guard let self, generation == self.generation, !Task.isCancelled else { return }
            switch result {
            case .success(let detail):
                state = .loaded(detail)
                UITiming.content("issue \(number) layout \(detail.layout.name)")
                if quiet { UITiming.content("issue \(number) reloaded") }
                #if DEBUG
                if let name = Self.launchActionName {
                    Self.launchActionName = nil
                    if let action = Self.launchAction(name, in: detail) {
                        PRLaunchActionGate.run { [weak self] in self?.perform(action, on: number, github: github) }
                    } else {
                        PRLaunchActionGate.run { [weak self] in self?.openLaunchStep(name, in: detail) }
                    }
                }
                #endif
            case .failure(let error):
                let message = PullRequestDetailModel.message(for: error, kind: api.client.kind)
                if quiet, state.value != nil {
                    actionError = "Could not reload the issue: \(message)"
                } else {
                    state = .failed(message)
                }
            }
        }
    }

    /// The detail closed (Esc, another selection): an answer still on its way is dropped.
    func close() {
        task?.cancel()
        task = nil
        generation &+= 1
        state = .idle
    }

    /// Runs `action` on issue `number` (the one whose detail the user acted on), then reloads it and the PRs tab's
    /// lists. A failure shows above the cards while that issue shows; otherwise it names the number in the PRs tab
    /// (`HostingStore.actionNotice`).
    func perform(_ action: IssueAction, on number: Int, github: HostingStore) {
        guard busy[number] == nil else { return }
        guard let api = github.api else {
            actionError = "No account is connected for this tab."
            return
        }
        busy[number] = action
        if self.number == number { actionError = nil }
        // "#5 Closing…" in the footer.
        let endOperation = beginOperation("#\(number) \(action.progressTitle.dropLast())")
        // A general thread action shows at once (`PullRequestDetailModel.perform`'s rule).
        var optimistic: (shown: IssueDetail, comments: [HostedComment], general: PRGeneralOptions)?
        // A reaction that keeps its row: the shown page with the row toggled, put in at once
        // (`PullRequestDetailModel.perform`).
        var ready: PRTimelineHTML?
        if case .general(let general) = action, self.number == number, let shown = state.value {
            if case .resolve(let root, true) = general { generalExpanded[root.id] = nil }
            // Where replies fold (the Activity), a thread just replied to opens, so the reply shows.
            if case .reply(let root, _) = general, shown.layout.collapsesReplies { generalExpanded[root.id] = true }
            if case .edit(let target, _) = general { editingComments.remove(target.key) }
            optimisticID &+= 1
            let options = PRGeneralOptions(api.client, expanded: generalExpanded)
            optimistic = (shown, PRTimeline.patched(shown.comments, general, viewer: shown.viewer,
                                                    replyID: optimisticID, kinds: options.reactions),
                          options)
            ready = PRTimeline.patched(shown.timeline, general)
        }
        if let optimistic, let ready,
           replacePage(of: optimistic.shown.loadID, number: number, comments: optimistic.comments, timeline: ready) {
            UITiming.content("issue \(number) action \(action.timingName) patched")
        }
        // An award bar click changes the bar at once, in the click's update (no HTML changes); a failure puts the
        // reactions back as they were, on the same load only (`PullRequestDetailModel.perform`).
        var reactionsShown: (loadID: Int, reactions: [HostedReaction])?
        if case .itemReaction(let kind, let add) = action, self.number == number, case .loaded(var shown) = state {
            reactionsShown = (shown.loadID, shown.issue.reactions)
            shown.issue.reactions = PRTimeline.toggled(shown.issue.reactions, kind, add: add,
                                                       kinds: shown.reactionKinds)
            state = .loaded(shown)
            UITiming.content("issue \(number) action \(action.timingName) patched")
        }
        let activityView = activityView
        Task { [weak self, ready] in
            if let optimistic, ready == nil {
                let page = await Self.page(optimistic.shown, comments: optimistic.comments,
                                           general: optimistic.general, activity: activityView)
                if self?.replacePage(of: optimistic.shown.loadID, number: number, comments: optimistic.comments,
                                     timeline: page) == true {
                    UITiming.content("issue \(number) action \(action.timingName) patched")
                }
            }
            let error = await Self.run(action, api.client, api.repository, number: number)
            endOperation()
            guard let self else { return }
            busy[number] = nil
            UITiming.content("issue \(number) action \(action.timingName) \(error == nil ? "ok" : "failed")")
            let showing = isShowing(number)
            if let error {
                if let optimistic {
                    replacePage(of: optimistic.shown.loadID, number: number, comments: optimistic.shown.comments,
                                timeline: optimistic.shown.timeline)
                }
                if let reactionsShown, self.number == number, case .loaded(var detail) = state,
                   detail.loadID == reactionsShown.loadID {
                    detail.issue.reactions = reactionsShown.reactions
                    state = .loaded(detail)
                }
                if case .general(.edit(let target, let body)) = action, self.number == number {
                    reopenEdit(target.key, body: body)
                    if editingComments.contains(target.key) {
                        UITiming.content("issue \(number) action edit reopened cedit-\(target.key) open")
                    }
                }
                var message = PullRequestDetailModel.message(for: error, kind: api.client.kind)
                if case .general(let general) = action {
                    message = PRGeneralAction.withPermissionHint(message, for: general, error: error,
                                                                 kind: api.client.kind)
                }
                if showing {
                    actionError = "\(action.failureTitle): \(message)"
                } else {
                    github.actionNotice = "\(action.failureTitle(of: number)): \(message)"
                }
                return
            }
            if case .comment = action, self.number == number { draft = "" }
            if case .general(.reply(let root, _)) = action, self.number == number { generalReplyDrafts[root.id] = nil }
            if case .general(.edit(let target, _)) = action, self.number == number { savedEdit(target.key) }
            github.refreshNow()
            if showing { load(number, github: github, quiet: true) }
        }
    }

    /// Whether the detail shows issue `number` (loading or loaded), not another one or nothing (closed).
    private func isShowing(_ number: Int) -> Bool {
        guard self.number == number else { return false }
        if case .idle = state { return false }
        return true
    }

    /// Puts `comments` and their page in the shown detail, only while it is still load `loadID` of issue `number`.
    @discardableResult
    private func replacePage(of loadID: Int, number: Int, comments: [HostedComment], timeline: PRTimelineHTML)
        -> Bool
    {
        guard self.number == number, case .loaded(var detail) = state, detail.loadID == loadID else { return false }
        detail.comments = comments
        detail.commentCount = comments.count
        detail.timeline = timeline
        state = .loaded(detail)
        return true
    }

    /// The page of `detail` with `comments` instead of its own (an optimistic action's), its Activity as `activity`
    /// shows it.
    @concurrent
    private nonisolated static func page(
        _ detail: IssueDetail, comments: [HostedComment], general: PRGeneralOptions, activity: PRActivityView
    ) async -> PRTimelineHTML {
        timeline(detail.issue, comments: comments, general: general, now: detail.now,
                 activity: activityPage(detail.layout, events: detail.events, view: activity))
    }

    /// The Activity of an issue page with `layout` (nil without one), its `events` and `view`.
    private nonisolated static func activityPage(
        _ layout: PRPageLayout, events: [HostedTimelineEvent]?, view: PRActivityView
    ) -> PRActivityPage? {
        layout.issueActivity.map {
            PRActivityPage(layout: $0, view: view, events: events, collapsesReplies: layout.collapsesReplies)
        }
    }

    /// The page of `issue`: its body, then `comments`, dated against `now`, with the layout's Activity (`activity`).
    private nonisolated static func timeline(
        _ issue: HostedIssue, comments: [HostedComment], general: PRGeneralOptions, now: Date,
        activity: PRActivityPage?
    ) -> PRTimelineHTML {
        PRTimeline.page(
            author: issue.user, action: "opened this issue", date: issue.createdAt, html: issue.bodyHTML,
            markdown: issue.body, comments: comments, general: general, now: now, activity: activity)
    }

    /// The Activity's filter or sort changed (`view`): it shows at once in its controls, the page is rebuilt off the
    /// main actor and put in while the detail is still the same load with the same comments. The sort is kept for the
    /// app (`PullRequestDetailModel.setActivity`).
    func setActivity(_ view: PRActivityView, github: HostingStore) {
        guard view != activityView else { return }
        if view.newestFirst != activityView.newestFirst {
            Preferences.defaults.set(view.newestFirst, forKey: PRActivityView.newestFirstKey)
        }
        activityView = view
        guard let number, case .loaded(let shown) = state, shown.layout.issueActivity != nil, let api = github.api
        else { return }
        let general = PRGeneralOptions(api.client, expanded: generalExpanded)
        Task { [weak self] in
            let page = await Self.page(shown, comments: shown.comments, general: general, activity: view)
            guard let self, activityView == view, self.number == number, case .loaded(var detail) = state,
                  detail.loadID == shown.loadID, detail.comments == shown.comments
            else { return }
            detail.timeline = page
            state = .loaded(detail)
            UITiming.content("issue \(number) activity \(view.newestFirst ? "newest" : "oldest") \(view.filter)")
        }
    }

    /// `loadID` is the load's generation: a new one measures the page again, even when its HTML did not change.
    /// Where the host has general replies, the token's user is asked too (a failure only draws an optimistic reply
    /// as "you").
    /// Where the layout has them, the Activity's history entries, the award bar's reactions and the sidebar's Edit
    /// lists are read beside them (`PullRequestDetailModel.fetch`'s rule: started with the comments, so a host that
    /// reads several in one request shares it; a failure only leaves out what they say).
    @concurrent
    private nonisolated static func fetch(
        _ client: any HostingProvider, _ repository: HostedRepository, number: Int, loadID: Int,
        general: PRGeneralOptions, now: Date, activityView: PRActivityView
    ) async -> Result<IssueDetail, any Error> {
        let layout = PRPageLayout.for(client.kind)
        async let issue = client.issue(number, in: repository)
        async let comments = client.comments(on: .issue(number), in: repository)
        async let viewer = general.replies ? try? await client.currentUser() : nil
        let readsEvents = layout.issueActivity != nil && client.capabilities.contains(.timelineEvents)
        async let events: Loadable<[HostedTimelineEvent]> = !readsEvents ? .idle
            : await part(client.kind) { try await client.timelineEvents(of: .issue(number), in: repository) }
        let barKinds = layout.reactionBar && client.capabilities.contains(.itemReactions) ? client.reactionKinds : []
        async let itemReactions: Loadable<[HostedReaction]> = barKinds.isEmpty ? .idle
            : await part(client.kind) { try await client.itemReactions(of: .issue(number), in: repository) }
        let asksCandidates = layout.sidebar && client.capabilities.contains(.assignees)
        async let candidates: Loadable<[HostedUser]> = !asksCandidates ? .idle
            : await part(client.kind) { try await client.assignableUsers(in: repository) }
        let asksLabels = layout.sidebar && client.capabilities.contains(.labels)
        async let labelChoices: Loadable<[HostedLabel]> = !asksLabels ? .idle
            : await part(client.kind) { try await client.labels(in: repository) }
        do {
            let (issue, comments) = try await (issue, comments)
            let events = await events.value
            let timeline = timeline(issue, comments: comments, general: general, now: now,
                                    activity: activityPage(layout, events: events, view: activityView))
            let reactions = await itemReactions.value
            var shown = issue
            if let reactions { shown.reactions = reactions }
            return .success(IssueDetail(loadID: loadID, now: now, layout: layout, issue: shown,
                                        commentCount: comments.count, timeline: timeline, comments: comments,
                                        viewer: await viewer, reactionKinds: reactions == nil ? [] : barKinds,
                                        events: events, candidates: await candidates.value ?? [],
                                        labelChoices: await labelChoices.value ?? []))
        } catch {
            return .failure(error)
        }
    }

    /// `PullRequestDetailModel.part`: a read that may fail on its own.
    private nonisolated static func part<T: Sendable>(
        _ kind: HostingKind, _ body: () async throws -> T
    ) async -> Loadable<T> {
        await PullRequestDetailModel.part(kind, body)
    }

    @concurrent
    private nonisolated static func run(
        _ action: IssueAction, _ client: any HostingProvider, _ repository: HostedRepository, number: Int
    ) async -> (any Error)? {
        do {
            switch action {
            case .comment(let body): _ = try await client.comment(on: .issue(number), in: repository, body: body)
            case .setOpen(let open): try await client.setOpen(open, item: .issue(number), in: repository)
            case .general(let action): try await action.run(client, on: .issue(number), in: repository)
            case .itemReaction(let kind, true): try await client.addItemReaction(kind, to: .issue(number), in: repository)
            case .itemReaction(let kind, false):
                try await client.removeItemReaction(kind, from: .issue(number), in: repository)
            case .addAssignees(let users): try await client.addAssignees(users, to: .issue(number), in: repository)
            case .addLabels(let names): try await client.addLabels(names, to: .issue(number), in: repository)
            }
            return nil
        } catch {
            return error
        }
    }
}

extension IssueDetailModel: PRGeneralThreadModel {
    func isBusy(_ number: Int) -> Bool { busy[number] != nil }

    func runningGeneral(on number: Int) -> PRGeneralAction? {
        if case .general(let action)? = busy[number] { return action }
        return nil
    }

    func perform(_ action: PRGeneralAction, on number: Int, github: HostingStore) {
        perform(.general(action), on: number, github: github)
    }
}

// MARK: - Views

/// Panel2 while an issue is open: the header card at once, then the conversation's cards (skeletons until loaded).
struct IssueDetailView: View {
    let session: RepoSession
    let number: Int
    @Environment(WindowModel.self) private var model

    var body: some View {
        let detail = session.issueDetail
        VStack(spacing: SectionCardMetrics.spacing) {
            IssueHeaderCard(session: session, number: number)
            if let error = detail.actionError {
                PRActionErrorCard(message: error) { detail.actionError = nil }
            }
            Group {
                switch detail.state {
                case .idle, .loading:
                    PlaceholderCard(
                        token: session.hostedToken, detail: "issue \(number)",
                        isCurrent: { [model, session, number] in
                            model.selectedSession === session && session.openHosted == .issue(number)
                        }
                    ) {
                        IssueSkeleton()
                    }
                case .loaded(let value):
                    IssueContent(session: session, detail: value)
                        .onAppear { UITiming.content("issue \(number) conversation \(value.commentCount)") }
                case .failed(let message):
                    DiffNoticeCard(title: "Issue", systemImage: "exclamationmark.triangle", message: message)
                        .onAppear { UITiming.content("issue \(number) failed") }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// Back, the title and number, the state pill and Open on GitHub; the "opened" line. The title comes from the PRs
/// tab's row until the issue is in.
private struct IssueHeaderCard: View {
    let session: RepoSession
    let number: Int

    var body: some View {
        let value = session.issueDetail.state.value
        let title = value?.issue.title ?? session.github.row(for: .issue(number))?.title
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
                    Image(systemName: "smallcircle.filled.circle")
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
                    Text("#\(number)")
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if let value {
                        if value.layout.issueSentence == .openedThisIssue {
                            IssueStatePill(isOpen: value.isOpen)
                        }
                        Button {
                            GitHubLinks.open(session.github.webURL(.issue(value.issue.number)))
                        } label: {
                            Image(systemName: "safari")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(RowIconButtonStyle())
                        .help("Open on \(session.github.kind.name)")
                        .accessibilityLabel("Open on \(session.github.kind.name)")
                    } else {
                        SkeletonLine(width: 56, height: 20)
                    }
                }
                .frame(height: 32)
                Group {
                    if let value, value.layout.issueSentence == .created {
                        createdSummary(value)
                    } else if let value {
                        summary(value)
                            .font(.settingsCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        SkeletonLine(width: 260, height: 11)
                    }
                }
                .padding(.leading, 8)
                .padding(.bottom, 2)
            }
        }
    }

    /// "reviewer opened this issue 2 days ago · 1 comment", the absolute date as its tooltip.
    private func summary(_ value: IssueDetail) -> some View {
        let issue = value.issue
        let dates = PRPageDates(now: value.now)
        let date = issue.createdAt.map { " \(dates.relative($0))" } ?? ""
        let count = value.commentCount
        return (Text(issue.user?.login ?? "ghost").fontWeight(.semibold)
            + Text(" opened this issue\(date) · \(count) \(count == 1 ? "comment" : "comments")"))
            .help(issue.createdAt.map(dates.absolute) ?? "")
    }

    /// GitLab's header line, "[Open] reviewer opened this issue 2 days ago": the state badge first, then the author
    /// and the creation, relative (the absolute date in the tooltip).
    private func createdSummary(_ value: IssueDetail) -> some View {
        let issue = value.issue
        let dates = PRPageDates(now: value.now)
        let date = issue.createdAt.map { " \(dates.relative($0))" } ?? ""
        return HStack(spacing: 6) {
            IssueStatePill(isOpen: value.isOpen)
                .fixedSize()
            (Text(issue.user?.login ?? "ghost").fontWeight(.semibold)
                + Text(" opened this issue\(date)").foregroundStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(issue.createdAt.map(dates.absolute) ?? "")
        }
        .font(.settingsCaption)
        .accessibilityElement(children: .combine)
    }
}

/// Open (green) or Closed (GitHub's done purple is not a `Palette` color: the brand blue), as on GitHub.
private struct IssueStatePill: View {
    let isOpen: Bool

    var body: some View {
        let (title, symbol, fill, text): (String, String, Color, Color) = isOpen
            ? ("Open", "smallcircle.filled.circle", Color(nsColor: Palette.diffAddedFill), Color(nsColor: Palette.diffAddedSign))
            : ("Closed", "checkmark.circle", Palette.primaryFill, Palette.onAccent)
        Label(title, systemImage: symbol)
            .font(.settingsCaption.weight(.semibold))
            .foregroundStyle(text)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(fill))
            .accessibilityLabel("State: \(title)")
    }
}

/// The conversation and the comment box in one scroll view, as the pull request's Conversation tab, with the side
/// column on the right in its own (at the end of the same scroll when panel2 is narrow).
private struct IssueContent: View {
    let session: RepoSession
    let detail: IssueDetail

    private static let sideWidth: CGFloat = 220
    /// Narrower than this, the side cards go at the end of the conversation's column (`IssueSkeleton` too).
    static let wideEnough: CGFloat = 560

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= Self.wideEnough
            // One tree at both widths: the column keeps its page (and its web view) when panel2 crosses
            // `wideEnough`, and only the side cards move.
            HStack(alignment: .top, spacing: PRConversationTab.columnGap) {
                ScrollView {
                    main(sideCards: !wide)
                }
                if wide {
                    ScrollView {
                        IssueSideColumn(session: session, detail: detail)
                    }
                    .scrollIndicators(.never)
                    .frame(width: Self.sideWidth)
                }
            }
        }
    }

    /// The column's cards, each as tall as its content: a long conversation pushes the comment box down. Where the
    /// layout has them, the award bar first and the host's Activity (title, filter and sort) in place of the
    /// Conversation.
    private func main(sideCards: Bool) -> some View {
        VStack(spacing: SectionCardMetrics.spacing) {
            if !detail.reactionKinds.isEmpty {
                let number = detail.issue.number
                PRAwardBarCard(kinds: detail.reactionKinds, given: detail.issue.reactions,
                               busy: session.issueDetail.isBusy(number), noun: "issue") { [session] kind, add in
                    session.issueDetail.perform(.itemReaction(kind: kind, add: add), on: number,
                                                github: session.github)
                }
            }
            SectionCard(detail.layout.issueActivity?.title ?? "Conversation", systemImage: "text.bubble",
                        count: detail.commentCount) {
                // The page fits its content and never scrolls itself: a wheel over it scrolls this column.
                PRTimelinePage(session: session, number: detail.issue.number, timeline: detail.timeline,
                               loadID: detail.loadID, kind: "issue",
                               avatars: .of(session.github), general: session.issueDetail)
                    .frame(maxWidth: .infinity)
            } accessory: {
                if let activity = detail.layout.issueActivity {
                    PRActivityControls(activity: activity, view: session.issueDetail.activityView) { [session] view in
                        session.issueDetail.setActivity(view, github: session.github)
                    }
                }
            }
            IssueCommentCard(session: session)
            if sideCards {
                IssueSideColumn(session: session, detail: detail)
            }
        }
    }
}

/// The comment box.
private struct IssueCommentCard: View {
    let session: RepoSession

    var body: some View {
        @Bindable var model = session.issueDetail
        SectionCard("Comment", systemImage: "square.and.pencil") {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $model.draft)
                    .font(.body)
                    .settingsTextEditor()
                    .frame(height: 64)
                    .overlay(alignment: .topLeading) {
                        if model.draft.isEmpty {
                            Text("Leave a comment")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                HStack(spacing: 8) {
                    Spacer(minLength: 8)
                    Button {
                        submit(model)
                    } label: {
                        HStack(spacing: 6) {
                            if case .comment? = model.running { ProgressView().controlSize(.mini) }
                            Text("Comment")
                        }
                    }
                    .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                    .disabled(model.running != nil || trimmed(model).isEmpty)
                }
            }
        }
    }

    private func trimmed(_ model: IssueDetailModel) -> String {
        model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit(_ model: IssueDetailModel) {
        let body = trimmed(model)
        guard model.running == nil, !body.isEmpty, let number = model.number else { return }
        model.perform(.comment(body), on: number, github: session.github)
    }
}

/// The right column: the actions, then assignees and labels, each in its own card; on a layout with the host's
/// sidebar (`PRPageLayout.sidebar`), the actions, then `HostSidebar`.
private struct IssueSideColumn: View {
    let session: RepoSession
    let detail: IssueDetail
    @Environment(WindowModel.self) private var model

    var body: some View {
        let busy = session.issueDetail.busy[detail.issue.number]
        VStack(spacing: SectionCardMetrics.spacing) {
            actions(busy)
            if detail.layout.sidebar {
                hostSidebar(busy)
            } else {
                sideCards
            }
        }
    }

    /// The host's sidebar (`PRPageLayout.sidebar`) after the Actions card (Close/Reopen stays reachable), its Edit
    /// menus running the detail's add-only actions. No Reviewers part: an issue has none.
    private func hostSidebar(_ busy: IssueAction?) -> some View {
        let issue = detail.issue
        let running: HostSidebar.Part? = switch busy {
        case .addAssignees: .assignees
        case .addLabels: .labels
        default: nil
        }
        return HostSidebar(
            assignees: issue.assignees ?? [], reviewers: nil, approvalNote: nil, labels: issue.labels ?? [],
            milestone: issue.milestone, timeStats: issue.timeStats,
            participants: HostSidebar.participants([issue.user] + (issue.assignees ?? []) + detail.comments.map(\.user)),
            avatars: .of(session.github), candidates: detail.candidates, labelChoices: detail.labelChoices,
            viewer: detail.viewer, canAssign: session.github.offers(.assignees), canReview: false,
            canLabel: session.github.offers(.labels), running: running, busy: busy != nil
        ) { [session] edit in
            let action: IssueAction? = switch edit {
            case .assign(let user): .addAssignees([user])
            case .label(let name): .addLabels([name])
            case .review: nil
            }
            if let action { session.issueDetail.perform(action, on: issue.number, github: session.github) }
        }
    }

    /// Close or Reopen, and the running action.
    private func actions(_ busy: IssueAction?) -> some View {
        SectionCard("Actions", systemImage: "bolt") {
            VStack(alignment: .leading, spacing: 10) {
                if detail.isOpen || session.github.offers(.reopen) {
                    Button(detail.isOpen ? "Close Issue" : "Reopen Issue") { confirmSetOpen(!detail.isOpen) }
                        .buttonStyle(RowTextButtonStyle(formRow: true))
                        .disabled(busy != nil)
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

    /// Today's side cards: the assignees and the labels.
    @ViewBuilder private var sideCards: some View {
        if session.github.offers(.assignees) {
            SectionCard("Assignees", systemImage: "person.crop.circle", count: detail.issue.assignees?.count ?? 0) {
                let assignees = detail.issue.assignees ?? []
                if assignees.isEmpty {
                    PRSideEmpty(text: "No one assigned")
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        let avatars = HostAvatars.of(session.github)
                        ForEach(assignees, id: \.id) {
                            PRPersonRow(login: $0.login, userID: $0.id, avatarURL: $0.avatarURL, avatars: avatars,
                                        state: nil, showsState: false)
                        }
                    }
                }
            }
        }
        if session.github.offers(.labels) {
            SectionCard("Labels", systemImage: "tag", count: detail.issue.labels?.count ?? 0) {
                let labels = detail.issue.labels ?? []
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

    private func confirmSetOpen(_ open: Bool) {
        let number = detail.issue.number
        let host = session.github.kind.name
        model.presentModal(.confirmation(ModalConfirmation(
            title: open ? "Reopen #\(number)?" : "Close #\(number)?",
            message: open
                ? "The issue opens again on \(host)." : "The issue closes on \(host); it can be reopened later.",
            button: open ? "Reopen" : "Close Issue", isDestructive: !open,
            perform: { [session] in session.issueDetail.perform(.setOpen(open), on: number, github: session.github) })))
    }
}

/// The loading detail in the loaded issue's arrangement (`IssueContent`): the Conversation card's lines and the
/// comment box under it, and the side column's cards on the right, or at the end of the column when panel2 is narrow.
private struct IssueSkeleton: View {
    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= IssueContent.wideEnough
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
        ForEach(["Actions", "Assignees", "Labels"], id: \.self) { title in
            SectionCard(title, countIsLoading: true) {
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonLine(fraction: 0.8, height: 11)
                    SkeletonLine(fraction: 0.5, height: 11)
                }
            }
        }
    }
}
