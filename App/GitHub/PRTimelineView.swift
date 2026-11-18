// The pull request's Conversation page: one locked-down `GitHubHTMLView` holding the description, the comments and
// the reviews by date, each review with its inline review threads under it (the path and lines, the commented diff
// rows, the comments), and native views drawn on the empty slots the page reserves for them (avatars, a chevron in
// each thread's header, a reply row under each thread). An issue's page is the same, with its description and
// comments only. The page is built off the main actor with the rest of the detail. Only GitHub's `body_html` goes in
// as is; every other value GitHub sent (logins, paths, diff lines, dates) is escaped. Slot ids come from GitHub's ids,
// never from positions, so a new comment never moves another one's view.
import HistqCore
import SwiftUI

/// The Conversation's HTML (a pull request's or an issue's): each item in a bordered box with its author, what they did
/// and when. Only GitHub's `body_html` is inserted as is; every other value is escaped.
enum PRTimeline {
    /// GitHub's HTML, or (when an answer has none) the markdown source as escaped plain text.
    nonisolated static func bodyHTML(_ html: String?, _ markdown: String?) -> String? {
        if let html, !html.isEmpty { return html }
        guard let markdown, !markdown.isEmpty else { return nil }
        return "<p class=\"plain\">\(GitHubHTML.escape(markdown))</p>"
    }
}

/// The Conversation's page and what its slots show.
struct PRTimelineHTML: Sendable {
    let html: String
    /// The account drawn on each avatar slot, by slot id; a deleted account (ghost) has none.
    let avatars: [String: GitHubUser]
    /// The comments and reviews it shows, the description aside.
    let count: Int
}

extension PRTimeline {
    private struct Entry {
        let date: Date?
        let html: String
    }

    /// The page: the description (`author` did `action` on `date`, its `html` or else its `markdown`), then the
    /// comments and reviews oldest first, each review with its threads, then the threads of no shown review. A
    /// commented review GitHub only made to hold replies to other reviews' threads, with no text of its own, is hidden
    /// as on GitHub.
    /// Threads are collapsed per `isCollapsed(_:expanded:)`. An issue's page has no reviews and no threads. Dates
    /// follow the user's date format (Settings › Appearance, 24 h by default).
    nonisolated static func page(
        author: GitHubUser?, action: String, date: Date?, html: String?, markdown: String?,
        comments: [GitHubComment], reviews: [GitHubReview] = [], threads: Loadable<PRThreads> = .idle,
        expanded: [Int: Bool] = [:]
    ) -> PRTimelineHTML {
        let dates = DateFormatter()
        dates.locale = Locale(identifier: Locale.current.identifier)
        dates.dateFormat = Preferences.defaults.string(forKey: PrefKey.dateFormat.rawValue) ?? "MM/dd/yy @ HH:mm"
        var avatars: [String: GitHubUser] = [:]

        /// A header's content: the avatar slot, the login, what they did (none for a thread's comment) and when.
        func head(_ slot: String, _ user: GitHubUser?, action: String?, badge: String? = nil, date: Date?) -> String {
            avatars[slot] = user
            let what = action.map { action in
                " " + (badge.map { "<span class=\"badge \($0)\">\(GitHubHTML.escape(action))</span>" }
                    ?? GitHubHTML.escape(action))
            } ?? ""
            let when = date.map { "<span class=\"date\">\(GitHubHTML.escape(dates.string(from: $0)))</span>" } ?? ""
            // Slot ids are `avatar-d` or an integer id after a prefix, the formats the measuring script accepts
            // (`GitHubHTMLPage`); one made from a String would have to go through `GitHubHTML.escape`.
            return "<span class=\"slot-avatar\" data-slot=\"\(slot)\"></span>"
                + "<b>\(GitHubHTML.escape(user?.login ?? "ghost"))</b>\(what)\(when)"
        }

        /// A thread: its header (chevron slot, path, lines, state), then, unless collapsed, the commented diff rows,
        /// the comments and the reply slot. Its id and `collapsed` class let the app expand it without a reload.
        func thread(_ thread: GitHubReviewThread) -> String {
            let collapsed = isCollapsed(thread, expanded: expanded)
            let comments = thread.comments.map { comment in
                let body = bodyHTML(comment.bodyHTML, comment.body).map { "<div class=\"body\">\($0)</div>" } ?? ""
                let header = head("avatar-c\(comment.id)", comment.user, action: nil, date: comment.createdAt)
                return "<div class=\"comment\"><div class=\"comment-head\">\(header)</div>\(body)</div>"
            }
            // `thread.id` is an integer: it goes in unescaped (a String id would need `GitHubHTML.escape`).
            return "<div class=\"thread\(collapsed ? " collapsed" : "")\" id=\"thread-\(thread.id)\">"
                + threadHead(thread, isResolved: thread.state?.isResolved == true) + excerptTable(thread)
                + comments.joined() + "<div class=\"slot-reply\" data-slot=\"reply-\(thread.id)\"></div></div>"
        }

        func item(
            _ slot: String, _ user: GitHubUser?, _ action: String, badge: String? = nil, date: Date?, body: String?,
            emptyText: String? = nil, threads: [GitHubReviewThread] = []
        ) -> String {
            let content: String
            if let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                content = "<div class=\"body\">\(body)</div>"
            } else if let emptyText {
                content = "<div class=\"body empty\">\(GitHubHTML.escape(emptyText))</div>"
            } else {
                content = ""
            }
            let header = head(slot, user, action: action, badge: badge, date: date)
            let list = threads.isEmpty ? "" : "<div class=\"threads\">\(threads.map(thread).joined())</div>"
            return "<section class=\"item\"><div class=\"head\">\(header)</div>\(content)\(list)</section>"
        }

        let byReview = threads.value?.byReview ?? [:]
        let replyOnly = threads.value?.replyOnlyReviewIDs ?? []
        // Only a commented one: an approval or a change request submitted with a reply and no text still shows.
        let shown = reviews.filter { review in
            review.state != "PENDING" && !(review.state == "COMMENTED" && replyOnly.contains(review.id)
                && bodyHTML(review.bodyHTML, review.body) == nil)
        }
        var entries = comments.map { comment in
            Entry(date: comment.createdAt, html: item(
                "avatar-i\(comment.id)", comment.user, "commented", date: comment.createdAt,
                body: bodyHTML(comment.bodyHTML, comment.body)))
        }
        for review in shown {
            let (action, badge): (String, String?) = switch review.state {
            case "APPROVED": ("approved these changes", "approved")
            case "CHANGES_REQUESTED": ("requested changes", "changes")
            case "DISMISSED": ("reviewed (dismissed)", nil)
            default: ("reviewed", nil)
            }
            entries.append(Entry(date: review.submittedAt, html: item(
                "avatar-r\(review.id)", review.user, action, badge: badge, date: review.submittedAt,
                body: bodyHTML(review.bodyHTML, review.body), threads: byReview[review.id] ?? [])))
        }
        // Stable for equal dates: comments before reviews, as appended.
        let sorted = entries.enumerated().sorted { a, b in
            switch (a.element.date, b.element.date) {
            case let (x?, y?) where x != y: x < y
            default: a.offset < b.offset
            }
        }.map(\.element.html)
        let description = item(
            "avatar-d", author, action, date: date, body: bodyHTML(html, markdown),
            emptyText: "No description provided.")
        // A thread whose review is not shown (pending, or missing from the reviews) would vanish: it goes at the end,
        // in a fixed order, so the same answer always builds the same page (a reload then only measures it again).
        let shownIDs = Set(shown.map(\.id))
        let loose = byReview.keys.filter { !shownIDs.contains($0) }.sorted().flatMap { byReview[$0] ?? [] }
            + (threads.value?.unattached ?? [])
        var end = loose.isEmpty ? "" : "<div class=\"threads loose\">\(loose.map(thread).joined())</div>"
        if case .failed(let message) = threads {
            end += "<p class=\"empty\">The inline review comments did not load: \(GitHubHTML.escape(message))</p>"
        }
        return PRTimelineHTML(
            html: ([description] + sorted).joined() + end, avatars: avatars, count: comments.count + shown.count)
    }

    /// Whether `thread` shows collapsed (its header only): a resolved one is, an unresolved one is not, unless the user
    /// chose otherwise (`expanded`, by root comment id). The page and the native views on it agree on it.
    nonisolated static func isCollapsed(_ thread: GitHubReviewThread, expanded: [Int: Bool]) -> Bool {
        !(expanded[thread.id] ?? (thread.state?.isResolved != true))
    }

    /// The chevron slot, the path with its folders shortened in the middle when it is too long (the file name
    /// stays), "Line N" or "Lines a–b", and the Outdated and Resolved capsules.
    private nonisolated static func threadHead(_ thread: GitHubReviewThread, isResolved: Bool) -> String {
        let slash = thread.path.lastIndex(of: "/")
        let folder = slash.map { String(thread.path[..<$0]) } ?? ""
        let file = slash.map { String(thread.path[$0...]) } ?? thread.path
        let lines: String? = switch (thread.startLine, thread.line) {
        case let (start?, end?) where start != end: "Lines \(start)–\(end)"
        case let (_, end?): "Line \(end)"
        default: nil
        }
        // `thread.id` is an integer: it goes in unescaped (a String id would need `GitHubHTML.escape`).
        return "<div class=\"thread-head\"><span class=\"slot-chevron\" data-slot=\"chevron-\(thread.id)\"></span>"
            + "<span class=\"path\" title=\"\(GitHubHTML.escape(thread.path))\">"
            + "<span class=\"folder\">\(GitHubHTML.escape(folder))</span>"
            + "<span class=\"file\">\(GitHubHTML.escape(file))</span></span>"
            + (lines.map { "<span class=\"lines\">\($0)</span>" } ?? "")
            + (thread.isOutdated ? "<span class=\"cap outdated\">Outdated</span>" : "")
            + (isResolved ? "<span class=\"cap\">Resolved</span>" : "") + "</div>"
    }

    /// The commented diff rows as the Files tab shows them: old and new line numbers, the sign, the text on a green or
    /// red band.
    private nonisolated static func excerptTable(_ thread: GitHubReviewThread) -> String {
        let rows = excerpt(thread).map { line in
            let (kind, sign) = switch line.kind {
            case .added: ("add", "+")
            case .removed: ("del", "−")
            case .context: ("ctx", "")
            }
            return "<tr class=\"\(kind)\"><td class=\"num\">\(line.oldLine.map(String.init) ?? "")</td>"
                + "<td class=\"num\">\(line.newLine.map(String.init) ?? "")</td><td class=\"sign\">\(sign)</td>"
                + "<td class=\"code\">\(GitHubHTML.escape(line.text))</td></tr>"
        }
        return rows.isEmpty ? "" : "<table class=\"excerpt\">\(rows.joined())</table>"
    }

    /// The rows of `thread`'s diff hunk, which ends at the commented line: from its first line for a range (the rows
    /// of the other side in between included), else the last 4. The hunk goes through the Files tab's patch parser,
    /// `GitHubPullRequestFile.diff`, the parser's only public way in, as the patch of a file.
    private nonisolated static func excerpt(_ thread: GitHubReviewThread) -> ArraySlice<DiffLine> {
        let file: [String: Any] = [
            "filename": thread.path, "status": "modified", "additions": 0, "deletions": 0,
            "patch": thread.diffHunk ?? "",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: file),
              let lines = (try? JSONDecoder().decode(GitHubPullRequestFile.self, from: data))?.diff?.hunks.last?.lines
        else { return [] }
        let left = thread.side == "LEFT"
        if let start = thread.startLine, start != thread.line,
           let first = lines.firstIndex(where: { (left ? $0.oldLine : $0.newLine) == start }) {
            return lines[first...]
        }
        return lines.suffix(4)
    }
}

/// The timeline page (a pull request's or an issue's) with native views on the slots it reserves, in the same scroll
/// content: each avatar, each thread's chevron (a click expands or collapses it), and the reply row under each
/// expanded thread. The views are clipped to the page's frame, and the slots live with the page, so a new page never
/// shows the old one's views. A quiet reload measures the page again (`measureKey`), so the views follow it even when
/// its HTML did not change. What changed since the page was built goes to it as a patch, without a reload: each
/// thread's `collapsed` class, by the page's own rule (`PRTimeline.isCollapsed`), and each reply slot's height, which
/// follows its row.
struct PRTimelinePage: View {
    let session: RepoSession
    /// The pull request's or the issue's number.
    let number: Int
    let timeline: PRTimelineHTML
    /// The detail's load: a new one measures the page again.
    let loadID: Int
    /// The pull request's review threads; none on an issue's page.
    var threads: PRThreads?
    /// The timing log's word for the page (`pr 1 conversation html`, `issue 2 conversation html`).
    var kind = "pr"
    let realAvatars: Bool
    @State private var slots: [GitHubHTMLSlot] = []
    /// Each reply row's height with its margins, by slot id: its slot takes it, so a field grown to more lines pushes
    /// the rest of the page down instead of covering it.
    @State private var replyHeights: [String: CGFloat] = [:]

    var body: some View {
        let threads = Dictionary(
            (self.threads?.all ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let expanded = session.pullDetail.threadExpanded
        // `thread-<integer id>`, the page's ids and the only ones the patch accepts (`GitHubHTMLPage`).
        let collapsed = Dictionary(uniqueKeysWithValues: threads.values.map { thread in
            ("thread-\(thread.id)", PRTimeline.isCollapsed(thread, expanded: expanded))
        })
        GitHubHTMLView(
            html: timeline.html, measureKey: loadID,
            patch: GitHubHTMLPatch(slotHeights: replyHeights, collapsed: collapsed)
        ) { [kind, number] in
            UITiming.content("\(kind) \(number) conversation html")
        } onSlots: {
            slots = $0
        }
        .overlay(alignment: .topLeading) {
            // Its own top-leading stack: the overlay's implicit one centers its views in their union (the widest
            // one's box), which shifted every avatar off its slot.
            ZStack(alignment: .topLeading) {
                ForEach(slots, id: \.id) { slot in
                    overlay(slot, threads: threads, expanded: expanded)
                        .frame(width: slot.frame.width, height: slot.frame.height, alignment: .top)
                        .slotProbeFrame(slot.id)
                        .offset(x: slot.frame.minX, y: slot.frame.minY)
                }
            }
        }
        .clipped()
    }

    /// Only the slots this page's HTML made get a view: the avatars of `timeline.avatars` (a deleted account's as
    /// "ghost"), the chevrons and the reply rows. A thread collapsed by a click drops its reply row at once, before
    /// the page is measured again without its slot.
    @ViewBuilder private func overlay(
        _ slot: GitHubHTMLSlot, threads: [Int: GitHubReviewThread], expanded: [Int: Bool]
    ) -> some View {
        if slot.id.hasPrefix("avatar-") {
            let user = timeline.avatars[slot.id]
            GitHubUserAvatar(login: user?.login ?? "ghost", id: user?.id, size: slot.frame.width, real: realAvatars)
        } else if let thread = Self.thread(of: slot, "chevron-", in: threads) {
            chevron(thread, collapsed: PRTimeline.isCollapsed(thread, expanded: expanded))
        } else if let thread = Self.thread(of: slot, "reply-", in: threads),
                  !PRTimeline.isCollapsed(thread, expanded: expanded) {
            PRReplyRow(session: session, number: number, thread: thread,
                       resolveUnavailable: self.threads?.resolveUnavailable, width: slot.frame.width)
                .padding(.vertical, 8)
                // Its own height, not the slot's: the slot takes it.
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { height in
                    replyHeights[slot.id] = height
                    #if DEBUG
                    if GitHubHTMLProbe.slotsEnabled {
                        UITiming.probe("slot-probe", "\(slot.id) row-height \(Int(height))")
                    }
                    #endif
                }
        }
    }

    /// The thread of a `chevron-<root>` or `reply-<root>` slot.
    private static func thread(
        of slot: GitHubHTMLSlot, _ prefix: String, in threads: [Int: GitHubReviewThread]
    ) -> GitHubReviewThread? {
        guard slot.id.hasPrefix(prefix) else { return nil }
        return Int(slot.id.dropFirst(prefix.count)).flatMap { threads[$0] }
    }

    /// The thread's chevron: a click expands or collapses it at once (the user's choice, kept across reloads), and
    /// the page follows with the patch.
    private func chevron(_ thread: GitHubReviewThread, collapsed: Bool) -> some View {
        Button {
            session.pullDetail.threadExpanded[thread.id] = collapsed
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(RowIconButtonStyle())
        .help(collapsed ? "Show the conversation" : "Hide the conversation")
        .accessibilityLabel(collapsed ? "Expand the conversation on \(thread.path)"
                            : "Collapse the conversation on \(thread.path)")
    }
}

/// A review thread's reply row, on the slot under its comments: "Write a reply" (a text box: Return starts a new line,
/// ⌘↩ sends; 1 to 6 lines, then it scrolls), Reply, and "Resolve conversation" ("Unresolve conversation" on a resolved
/// thread) when GitHub lets the user do it. When the threads' states did not load, a caption says resolving is
/// unavailable and its tooltip says why. In a slot narrower than `oneLineWidth`, the buttons go on their own line under
/// the box, which takes the whole width. The draft is the model's (`replyDrafts`), written on every keystroke and read
/// here only, so a keystroke updates this row, not the page, and nothing is lost when the box loses focus. A click
/// shows its busy state at once (both buttons off, the box too while its reply posts), the spinner after
/// `DelayedSpinner.delay`.
private struct PRReplyRow: View {
    let session: RepoSession
    let number: Int
    let thread: GitHubReviewThread
    let resolveUnavailable: String?
    /// The slot's width.
    let width: CGFloat
    @FocusState private var focused: Bool

    /// A box of about 200 pt beside Reply and "Unresolve conversation".
    private static let oneLineWidth: CGFloat = 440

    var body: some View {
        let model = session.pullDetail
        let draft = Binding {
            model.replyDrafts[thread.id] ?? ""
        } set: {
            model.replyDrafts[thread.id] = $0.isEmpty ? nil : $0
        }
        let text = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let running = model.busy[number]
        // One layout that changes, not two branches: the box keeps its focus when the slot crosses `oneLineWidth`.
        // Beside the box, the buttons sit on its last line, so they stay by the caret as it grows.
        let layout = width < Self.oneLineWidth
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .lastTextBaseline, spacing: 8))
        layout {
            editor(draft, disabled: replying(running))
            HStack(spacing: 8) {
                Button {
                    guard !text.isEmpty else { return }
                    model.perform(.reply(rootID: thread.id, body: text), on: number, github: session.github)
                } label: {
                    HStack(spacing: 6) {
                        if replying(running) { DelayedSpinner(detail: "pr \(number) reply") }
                        Text("Reply")
                    }
                }
                .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                // Each expanded thread has a Reply button: the shortcut is only the focused row's.
                .keyboardShortcut(focused ? KeyboardShortcut(.return, modifiers: .command) : nil)
                .disabled(text.isEmpty || running != nil)
                .help("Reply (⌘↩)")
                resolveControl(running)
            }
            .fixedSize()
        }
    }

    /// The comment box's look (`settingsTextEditor`), with the row's own focus: ⌘↩ belongs to the focused row only.
    /// A `TextEditor` has no height of its own, so a hidden copy of the draft gives it one: 1 to 6 lines at its width
    /// (NSTextView's 5 pt line padding on each side; a trailing new line is a line), with the editor drawn on it. Its
    /// scroller never shows, so its lines wrap where the copy's do.
    private func editor(_ draft: Binding<String>, disabled: Bool) -> some View {
        let text = draft.wrappedValue
        return Text(verbatim: text.isEmpty || text.hasSuffix("\n") ? text + " " : text)
            .font(.body)
            .lineLimit(1...6)
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hidden()
            .overlay {
                TextEditor(text: draft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .focused($focused)
                    .accessibilityLabel("Reply to the conversation on \(thread.path)")
            }
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Write a reply")
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .modifier(SettingsInputChrome(focused: focused))
            .disabled(disabled)
    }

    /// Resolve or Unresolve, as GitHub lets the user do it on this thread, or the caption saying why neither shows.
    @ViewBuilder private func resolveControl(_ running: PullRequestAction?) -> some View {
        if let reason = resolveUnavailable {
            Text("Resolving unavailable")
                .font(.settingsCaption)
                .foregroundStyle(.secondary)
                .fixedSize()
                .help(reason)
        } else if let state = thread.state, state.isResolved ? state.viewerCanUnresolve : state.viewerCanResolve {
            Button {
                session.pullDetail.perform(.resolve(threadID: state.id, resolved: !state.isResolved), on: number,
                                           github: session.github)
            } label: {
                HStack(spacing: 6) {
                    if resolving(running) { DelayedSpinner(detail: "pr \(number) resolve") }
                    Text(state.isResolved ? "Unresolve conversation" : "Resolve conversation")
                }
            }
            .buttonStyle(RowTextButtonStyle(formRow: true))
            .disabled(running != nil)
            .fixedSize()
        }
    }

    /// This thread's reply is posting.
    private func replying(_ action: PullRequestAction?) -> Bool {
        if case .reply(let root, _)? = action { return root == thread.id }
        return false
    }

    /// This thread is being resolved or unresolved.
    private func resolving(_ action: PullRequestAction?) -> Bool {
        if case .resolve(let id, _)? = action { return id == thread.state?.id }
        return false
    }
}
