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
    let issue: HostedIssue
    var commentCount: Int
    /// The body, then the comments by date (`PRTimeline.page`). Rebuilt with `comments` by a general thread action,
    /// before its write (optimistic).
    var timeline: PRTimelineHTML
    /// The page's comments, as loaded (or as an optimistic action patched them).
    var comments: [HostedComment]
    /// The token's user, where the host has general replies (the author of an optimistic reply); nil when unknown.
    let viewer: HostedUser?

    var isOpen: Bool { issue.state == "open" }
}

/// A GitHub action of the issue detail.
enum IssueAction: Equatable, Sendable {
    case comment(String)
    case setOpen(Bool)
    /// A reply to or a resolve of a general thread, or an edit or delete of an own comment (`PRGeneralAction`), shown
    /// before the host answers (optimistic).
    case general(PRGeneralAction)

    var progressTitle: String {
        switch self {
        case .comment: "Commenting…"
        case .setOpen(let open): open ? "Reopening…" : "Closing…"
        case .general(let action): action.progressTitle
        }
    }

    var failureTitle: String {
        switch self {
        case .comment: "The comment was not posted"
        case .setOpen(let open): open ? "Reopen failed" : "Close failed"
        case .general(let action): action.failureTitle
        }
    }

    /// The failure's title when another issue shows by the time it returns: it names `number`.
    func failureTitle(of number: Int) -> String {
        switch self {
        case .comment: "The comment on #\(number) was not posted"
        case .setOpen(let open): open ? "Reopen of #\(number) failed" : "Close of #\(number) failed"
        case .general(let action): action.failureTitle(of: "#\(number)")
        }
    }

    /// The timing log's word (`content issue 2 action comment ok`).
    var timingName: String {
        switch self {
        case .comment: "comment"
        case .setOpen(let open): open ? "reopen" : "close"
        case .general(let action): action.timingName
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
    @ObservationIgnored private var optimisticID = 1 << 62

    #if DEBUG
    /// DEBUG `-HistqIssueAction comment|close|reopen|greply|gresolve|edit|edit-save|delete|delete-confirm`: runs
    /// that action once, on the first load, without its confirmation, so a launch exercises the action path and its
    /// reload. Only with `-HistqGitHubStub YES`: never an unconfirmed action on a real account. `greply` and
    /// `gresolve` act on the first general thread of that load, `edit-save` on its first own comment
    /// (`PRGeneralAction.launchAction`); `edit`, `delete` and `delete-confirm` open its editor or its confirmation
    /// (`openLaunchStep`).
    private static var launchActionName: String? = GitHubStub.isEnabled
        ? AppState.launchFlag("-HistqIssueAction") : nil

    private static func launchAction(_ name: String, in detail: IssueDetail) -> IssueAction? {
        switch name {
        case "comment": .comment("QA comment")
        case "close": .setOpen(false)
        case "reopen": .setOpen(true)
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
            actionError = nil
        }
        self.number = number
        if !quiet || state.value == nil { state = .loading }
        guard let api = github.api else {
            state = .failed("No account is connected for this tab: connect one in Settings › Integrations.")
            return
        }
        let generation = generation
        let general = PRGeneralOptions(api.client.capabilities, expanded: generalExpanded)
        task = Task { [weak self] in
            let result = await Self.fetch(api.client, api.repository, number: number, loadID: generation,
                                          general: general)
            guard let self, generation == self.generation, !Task.isCancelled else { return }
            switch result {
            case .success(let detail):
                state = .loaded(detail)
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
        if case .general(let general) = action, self.number == number, let shown = state.value {
            if case .resolve(let root, true) = general { generalExpanded[root.id] = nil }
            if case .edit(let target, _) = general { editingComments.remove(target.key) }
            optimisticID &+= 1
            optimistic = (shown, PRTimeline.patched(shown.comments, general, viewer: shown.viewer,
                                                    replyID: optimisticID),
                          PRGeneralOptions(api.client.capabilities, expanded: generalExpanded))
        }
        Task { [weak self] in
            if let optimistic {
                let page = await Self.page(optimistic.shown.issue, comments: optimistic.comments,
                                           general: optimistic.general)
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
                if case .general(.edit(let target, let body)) = action, self.number == number {
                    reopenEdit(target.key, body: body)
                    if editingComments.contains(target.key) {
                        UITiming.content("issue \(number) action edit reopened cedit-\(target.key) open")
                    }
                }
                let message = PullRequestDetailModel.message(for: error, kind: api.client.kind)
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

    /// The page of `issue`: its body, then `comments`.
    @concurrent
    private nonisolated static func page(
        _ issue: HostedIssue, comments: [HostedComment], general: PRGeneralOptions
    ) async -> PRTimelineHTML {
        timeline(issue, comments: comments, general: general)
    }

    private nonisolated static func timeline(
        _ issue: HostedIssue, comments: [HostedComment], general: PRGeneralOptions
    ) -> PRTimelineHTML {
        PRTimeline.page(
            author: issue.user, action: "opened this issue", date: issue.createdAt, html: issue.bodyHTML,
            markdown: issue.body, comments: comments, general: general)
    }

    /// `loadID` is the load's generation: a new one measures the page again, even when its HTML did not change.
    /// Where the host has general replies, the token's user is asked too (a failure only draws an optimistic reply
    /// as "you").
    @concurrent
    private nonisolated static func fetch(
        _ client: any HostingProvider, _ repository: HostedRepository, number: Int, loadID: Int,
        general: PRGeneralOptions
    ) async -> Result<IssueDetail, any Error> {
        async let issue = client.issue(number, in: repository)
        async let comments = client.comments(on: .issue(number), in: repository)
        async let viewer = general.replies ? try? await client.currentUser() : nil
        do {
            let (issue, comments) = try await (issue, comments)
            let timeline = timeline(issue, comments: comments, general: general)
            return .success(IssueDetail(loadID: loadID, issue: issue, commentCount: comments.count,
                                        timeline: timeline, comments: comments, viewer: await viewer))
        } catch {
            return .failure(error)
        }
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
                        IssueStatePill(isOpen: value.isOpen)
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
                    if let value {
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

    /// "reviewer opened this issue on Nov 11, 2026 · 1 comment".
    private func summary(_ value: IssueDetail) -> Text {
        let issue = value.issue
        let date = issue.createdAt.map { " on \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
        let count = value.commentCount
        return Text(issue.user?.login ?? "ghost").fontWeight(.semibold)
            + Text(" opened this issue\(date) · \(count) \(count == 1 ? "comment" : "comments")")
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

    /// The column's cards, each as tall as its content: a long conversation pushes the comment box down.
    private func main(sideCards: Bool) -> some View {
        VStack(spacing: SectionCardMetrics.spacing) {
            SectionCard("Conversation", systemImage: "text.bubble", count: detail.commentCount) {
                // The page fits its content and never scrolls itself: a wheel over it scrolls this column.
                PRTimelinePage(session: session, number: detail.issue.number, timeline: detail.timeline,
                               loadID: detail.loadID, kind: "issue",
                               avatars: .of(session.github), general: session.issueDetail)
                    .frame(maxWidth: .infinity)
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

/// The right column: the actions, then assignees and labels, each in its own card.
private struct IssueSideColumn: View {
    let session: RepoSession
    let detail: IssueDetail
    @Environment(WindowModel.self) private var model

    var body: some View {
        let busy = session.issueDetail.busy[detail.issue.number]
        VStack(spacing: SectionCardMetrics.spacing) {
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
