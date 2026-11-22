// The pull request's Conversation page: one locked-down `HostedHTMLView` holding the description, then the comments,
// the reviews and the threads of no shown review by date (`HostedTimelineOrder`), each review with its inline review
// threads under it (the path and lines, the commented diff rows, the comments), replies indented under the comment
// they answer, and native views drawn on the empty slots the page reserves for them (avatars, a chevron in
// each thread's header, a reply row under each thread; the same on general threads where the host replies to and
// resolves them). An issue's page is the same, with its description and comments only. The page is built off the main actor with the rest of the detail. Only GitHub's `body_html` goes in
// as is; every other value GitHub sent (logins, paths, diff lines, dates) is escaped. Slot ids come from GitHub's ids,
// never from positions, so a new comment never moves another one's view.
import AppKit
import HistqCore
import SwiftUI

/// The Conversation's HTML (a pull request's or an issue's): each item in a bordered box with its author, what they did
/// and when. Only GitHub's `body_html` is inserted as is; every other value is escaped.
enum PRTimeline {
    /// GitHub's HTML, or (when an answer has none) the markdown source as escaped plain text.
    nonisolated static func bodyHTML(_ html: String?, _ markdown: String?) -> String? {
        if let html, !html.isEmpty { return html }
        guard let markdown, !markdown.isEmpty else { return nil }
        return "<p class=\"plain\">\(HostedHTML.escape(markdown))</p>"
    }
}

/// The Conversation's page and what its slots show.
struct PRTimelineHTML: Sendable {
    let html: String
    /// The account drawn on each avatar slot, by slot id; a deleted account (ghost) has none.
    let avatars: [String: HostedUser]
    /// The comments and reviews it shows, the description aside.
    let count: Int
    /// The general threads with a reply row (and a chevron when resolvable), by root comment id.
    var general: [Int: PRGeneralThread] = [:]
    /// The comments with a "…" menu (and an in-place editor), by `PRCommentTarget.key`.
    var comments: [String: PRCommentTarget] = [:]
    /// Every comment's reactions, by `PRReactionTarget.key` (none where the host has no reactions), and the kinds the
    /// host lets the viewer add, in its picker's order. Not in `html`: a reaction toggled on a comment that keeps its
    /// row changes only these.
    var reactions: [String: PRReactionTarget] = [:]
    var reactionKinds: [String] = []
}

/// The ids an optimistic page gives what the host has not answered yet (a reply, a new inline thread and its comment):
/// above any comment or thread id a host gives, so they never meet a real one, and digits only, as the page's slot ids
/// are. Nothing on the page acts on such a comment or thread (no menu, no reactions, no reply row) until the reload
/// brings the host's id: a write would name an id the host does not know. Only for comment and thread ids: a
/// synthetic review or user id (`SyntheticIDs`) may be this high.
enum PRPlaceholderID {
    /// The models count up from it (`PullRequestDetailModel.optimisticID`, `IssueDetailModel.optimisticID`).
    nonisolated static let base = 1 << 62

    nonisolated static func isPlaceholder(_ id: Int) -> Bool { id >= base }
}

/// A comment's reactions on the page, where the host has reactions (`PRGeneralOptions.reactions`): every comment but
/// the description and a review's body has an add button in its header (`cadd-<key>`, before the "…" menu), and one
/// with reactions a row of chips after its body (`creact-<key>`: emoji and count, the viewer's own highlighted; a
/// click toggles it), as on GitHub's page. A first reaction or the last one removed adds or drops the row, so only
/// those change the page's HTML.
struct PRReactionTarget: Equatable, Sendable {
    let kind: HostedCommentRef.Kind
    let id: Int
    let hostKey: String?
    var reactions: [HostedReaction]
    /// Its author's login, for VoiceOver.
    let author: String

    /// `PRCommentTarget.key`'s format: `g<id>` or `r<id>`.
    var key: String { "\(kind == .general ? "g" : "r")\(id)" }
    var ref: HostedCommentRef { HostedCommentRef(kind: kind, id: id, hostKey: hostKey) }
    /// Whether the page has a chip row for it.
    var hasRow: Bool { Self.hasRow(reactions) }

    nonisolated static func hasRow(_ reactions: [HostedReaction]) -> Bool { reactions.contains { $0.count > 0 } }

    /// The comment's reactions when `options` offer reactions; nil otherwise.
    nonisolated init?(
        _ kind: HostedCommentRef.Kind, id: Int, hostKey: String?, reactions: [HostedReaction], user: HostedUser?,
        options: PRGeneralOptions
    ) {
        guard !options.reactions.isEmpty, !PRPlaceholderID.isPlaceholder(id) else { return nil }
        self.kind = kind
        self.id = id
        self.hostKey = hostKey
        self.reactions = reactions
        author = user?.login ?? "ghost"
    }
}

/// A comment the viewer may edit or delete on the page (the host's `editComments`/`deleteComments` and the comment's
/// own rights): it has a "…" menu in its header (slot `cmenu-<key>`) and, after its body, the in-place editor's slot
/// (`cedit-<key>`), shown only while it is edited.
struct PRCommentTarget: Equatable, Sendable {
    let kind: HostedCommentRef.Kind
    let id: Int
    let hostKey: String?
    /// The raw markdown the editor starts from (`HostedComment.body`).
    let body: String
    /// Its author's login, for VoiceOver.
    let author: String
    let canEdit: Bool
    let canDelete: Bool

    /// `g<id>` for a general comment, `r<id>` for a review comment: the two id spaces apart, digits after the letter,
    /// as the page's slot ids are.
    var key: String { "\(kind == .general ? "g" : "r")\(id)" }
    var ref: HostedCommentRef { HostedCommentRef(kind: kind, id: id, hostKey: hostKey) }

    /// What `options` offer on a comment with these rights; nil when neither Edit nor Delete.
    nonisolated init?(
        _ kind: HostedCommentRef.Kind, id: Int, hostKey: String?, body: String?, user: HostedUser?, canEdit: Bool,
        canDelete: Bool, options: PRGeneralOptions
    ) {
        let edit = options.edit && canEdit, delete = options.delete && canDelete
        guard edit || delete, !PRPlaceholderID.isPlaceholder(id) else { return nil }
        self.kind = kind
        self.id = id
        self.hostKey = hostKey
        self.body = body ?? ""
        author = user?.login ?? "ghost"
        self.canEdit = edit
        self.canDelete = delete
    }
}

/// A general (non-inline) thread's root on the page, with what its reply row offers.
struct PRGeneralThread: Sendable {
    let root: HostedComment
    /// The host resolves general threads (`resolveGeneralThreads`) and this root may be: its row offers Resolve, its
    /// header a chevron.
    let resolvable: Bool

    var isResolved: Bool { resolvable && root.resolved == true }
}

/// What a page offers on its general threads (the host's `generalReplies` and `resolveGeneralThreads`), and the
/// resolved ones the user expanded or collapsed (`expanded`, by root comment id), and on every comment (the host's
/// `editComments` and `deleteComments`, and its reaction kinds where it has `reactions`). None by default.
struct PRGeneralOptions: Sendable {
    var replies = false
    var resolve = false
    var expanded: [Int: Bool] = [:]
    var edit = false
    var delete = false
    /// The kinds the viewer may add, in the host's order; empty without `reactions` (no reaction row at all).
    var reactions: [String] = []

    init(replies: Bool = false, resolve: Bool = false, expanded: [Int: Bool] = [:], edit: Bool = false,
         delete: Bool = false, reactions: [String] = []) {
        self.replies = replies
        self.resolve = resolve
        self.expanded = expanded
        self.edit = edit
        self.delete = delete
        self.reactions = reactions
    }

    /// What `client` offers, with `expanded`.
    init(_ client: any HostingProvider, expanded: [Int: Bool]) {
        let capabilities = client.capabilities
        self.init(replies: capabilities.contains(.generalReplies),
                  resolve: capabilities.contains(.resolveGeneralThreads), expanded: expanded,
                  edit: capabilities.contains(.editComments), delete: capabilities.contains(.deleteComments),
                  reactions: capabilities.contains(.reactions) ? client.reactionKinds : [])
    }
}

/// A comment action of the Conversation page, on a pull request or an issue (`PullRequestAction.general`,
/// `IssueAction.general`): a general thread's reply or resolve, an edit or delete of the viewer's own comment
/// (general or inline), or the viewer's reaction added to or removed from any comment.
enum PRGeneralAction: Equatable, Sendable {
    /// `root`: the thread's root comment, which the reply goes under.
    case reply(root: HostedComment, body: String)
    case resolve(root: HostedComment, resolved: Bool)
    /// `body`: the new raw markdown.
    case edit(PRCommentTarget, body: String)
    case delete(PRCommentTarget)
    /// `kind`: the host's name of the reaction; `add` false removes the viewer's.
    case react(PRReactionTarget, kind: String, add: Bool)

    /// What the host's write takes: the root, a general comment, with its host key (GitLab's discussion id), or the
    /// edited, deleted or reacted comment.
    var ref: HostedCommentRef {
        switch self {
        case .reply(let root, _), .resolve(let root, _):
            HostedCommentRef(kind: .general, id: root.id, hostKey: root.hostKey)
        case .edit(let target, _), .delete(let target): target.ref
        case .react(let target, _, _): target.ref
        }
    }

    var progressTitle: String {
        switch self {
        case .reply: "Replying…"
        case .resolve(_, let resolved): resolved ? "Resolving…" : "Unresolving…"
        case .edit: "Saving the comment…"
        case .delete: "Deleting the comment…"
        case .react(_, _, let add): add ? "Adding the reaction…" : "Removing the reaction…"
        }
    }

    var failureTitle: String {
        switch self {
        case .reply: "The reply was not posted"
        case .resolve(_, let resolved): resolved ? "Resolve failed" : "Unresolve failed"
        case .edit: "The comment was not saved"
        case .delete: "The comment was not deleted"
        case .react(_, _, let add): add ? "The reaction was not added" : "The reaction was not removed"
        }
    }

    /// The failure's title when another item shows by the time it returns: it names `number` (`#12`, `!12`).
    func failureTitle(of number: String) -> String {
        switch self {
        case .reply: "The reply on \(number) was not posted"
        case .resolve(_, let resolved): resolved ? "Resolve on \(number) failed" : "Unresolve on \(number) failed"
        case .edit: "The comment on \(number) was not saved"
        case .delete: "The comment on \(number) was not deleted"
        case .react(_, _, let add): add ? "The reaction on \(number) was not added"
            : "The reaction on \(number) was not removed"
        }
    }

    /// The timing log's word (`content pr 1 action greply ok`): the user's step for an edit (Save) or a delete (the
    /// confirmation), as the DEBUG launch actions name them.
    var timingName: String {
        switch self {
        case .reply: "greply"
        case .resolve(_, let resolved): resolved ? "gresolve" : "gunresolve"
        case .edit: "edit-save"
        case .delete: "delete-confirm"
        case .react: "react"
        }
    }

    /// Runs it on `item` (off the main actor, in the detail's `run`).
    func run(_ client: any HostingProvider, on item: HostedItem, in repository: HostedRepository) async throws {
        switch self {
        case .reply(_, let body): _ = try await client.reply(toGeneral: ref, on: item, in: repository, body: body)
        case .resolve(_, let resolved):
            _ = try await client.setGeneralThread(ref, on: item, in: repository, resolved: resolved)
        case .edit(_, let body): try await client.editComment(ref, on: item, in: repository, body: body)
        case .delete: try await client.deleteComment(ref, on: item, in: repository)
        case .react(_, let kind, true): try await client.addReaction(kind, to: ref, on: item, in: repository)
        case .react(_, let kind, false): try await client.removeReaction(kind, from: ref, on: item, in: repository)
        }
    }

    /// `message` (the error's text), and when GitHub refused a reaction, which permission a fine-grained token needs
    /// for it: Issues on a conversation comment (GitHub lists it there, not under Pull requests), Pull requests on a
    /// review comment (GitHub's fine-grained permission tables). The reaction is a GraphQL mutation, so the refusal may
    /// come as a 403 or as a GraphQL error naming the token's access. Another action, host or error: `message` alone.
    static func withPermissionHint(
        _ message: String, for action: PRGeneralAction, error: any Error, kind: HostingKind
    ) -> String {
        guard case .react(let target, _, _) = action, kind == .github else { return message }
        let refused = switch error {
        case HostingError.forbidden: true
        case HostingError.graphQL(let message):
            message.localizedCaseInsensitiveContains("not accessible")
                || message.localizedCaseInsensitiveContains("permission")
        default: false
        }
        guard refused else { return message }
        let permission = target.kind == .general ? "Issues" : "Pull requests"
        return message + (message.hasSuffix(".") ? " " : ". ")
            + "A fine-grained token needs the \(permission) permission (read and write) to react to this comment."
    }
}

#if DEBUG
extension PRGeneralAction {
    /// DEBUG `-HistqPRAction` or `-HistqIssueAction` `greply` (posts "stub reply" to the first general thread),
    /// `gresolve` (resolves the first resolvable one), `edit-save` (saves "edited" into the first own comment),
    /// `react` (adds a reaction to the first comment with reactions) or `react-new` (the first reaction of the first
    /// comment with none, whose row then comes in; both `launchReaction`): the first root of `comments`, as the host
    /// listed them, or the first comment `page` offers Edit on (`launchTarget`); nil when none fits. `delete-confirm`
    /// goes through the confirmation (`launchDelete`).
    static func launchAction(
        _ name: String, in comments: [HostedComment], reviewComments: [HostedReviewComment] = [],
        page: PRTimelineHTML
    ) -> PRGeneralAction? {
        let roots = comments.filter { $0.parentID == nil }
        let target = launchTarget(name, in: comments, reviewComments: reviewComments, page: page)
        return switch name {
        case "greply": roots.first.map { .reply(root: $0, body: "stub reply") }
        case "gresolve": roots.first { $0.resolvable == true }.map { .resolve(root: $0, resolved: true) }
        case "edit-save": target.map { .edit($0, body: "edited") }
        case "react", "react-new":
            launchReaction(in: comments, reviewComments: reviewComments, page: page, hasRow: name == "react")
        default: nil
        }
    }

    /// DEBUG `react` and `react-new`: the first comment with (`hasRow`) or without a reaction row (general comments as
    /// the host listed them, then review comments) gets the first of the host's kinds the viewer has not given it yet
    /// (on every stub the viewer already gave the first comment the first kind, which adding would only count twice);
    /// nil when none fits.
    private static func launchReaction(
        in comments: [HostedComment], reviewComments: [HostedReviewComment], page: PRTimelineHTML, hasRow: Bool
    ) -> PRGeneralAction? {
        let keys = comments.map { "g\($0.id)" } + reviewComments.map { "r\($0.id)" }
        guard let target = keys.lazy.compactMap({ page.reactions[$0] }).first(where: { $0.hasRow == hasRow })
        else { return nil }
        let mine = Set(target.reactions.filter(\.viewerReacted).map(\.kind))
        return page.reactionKinds.first { !mine.contains($0) }.map { .react(target, kind: $0, add: true) }
    }

    /// The comment the DEBUG launch action `name` (`edit`, `edit-save`, `delete`, `delete-confirm`) acts on: the first
    /// one `page` offers Edit (`edit…`) or Delete (`delete…`) on, general comments as the host listed them, then
    /// review comments; nil for another name or when none fits.
    static func launchTarget(
        _ name: String, in comments: [HostedComment], reviewComments: [HostedReviewComment] = [],
        page: PRTimelineHTML
    ) -> PRCommentTarget? {
        let editing = name.hasPrefix("edit")
        guard editing || name.hasPrefix("delete") else { return nil }
        let keys = comments.map { "g\($0.id)" } + reviewComments.map { "r\($0.id)" }
        return keys.lazy.compactMap { page.comments[$0] }.first { editing ? $0.canEdit : $0.canDelete }
    }
}

/// DEBUG `-HistqActionAfterShown YES` (stub runs only): a launch action (`-HistqPRAction`, `-HistqIssueAction`) waits
/// until the first timeline page is shown and measured (its `conversation html` line), as a real click does; without
/// it, the action runs as soon as the detail loads, before its page is shown.
@MainActor
enum PRLaunchActionGate {
    private static let waitsForPage = GitHubStub.isEnabled && AppState.launchFlag("-HistqActionAfterShown") == "YES"
    private static var pageShown = false
    private static var pending: [@MainActor () -> Void] = []

    static func run(_ action: @escaping @MainActor () -> Void) {
        guard waitsForPage, !pageShown else { return action() }
        pending.append(action)
    }

    /// A timeline page was shown: the waiting actions run.
    static func pageDidShow() {
        pageShown = true
        let actions = pending
        pending = []
        actions.forEach { $0() }
    }
}
#endif

/// The detail a page's general threads act through: the pull request's or the issue's model.
@MainActor
protocol PRGeneralThreadModel: AnyObject {
    /// Each general thread's reply box, by its root comment id (an id space apart from the review threads').
    var generalReplyDrafts: [Int: String] { get set }
    /// The general threads the user expanded (true) or collapsed (false) against their default, by root comment id.
    var generalExpanded: [Int: Bool] { get set }
    /// The comments shown with their in-place editor, by `PRCommentTarget.key`: the page reads only this, so a
    /// keystroke in an editor (`commentEditDrafts`) updates the editor, not the page.
    var editingComments: Set<String> { get set }
    /// Each open editor's text, by `PRCommentTarget.key`.
    var commentEditDrafts: [String: String] { get set }
    #if DEBUG
    /// DEBUG `-HistqPRAction`/`-HistqIssueAction` `delete` (`confirm` false) or `delete-confirm` (true): the comment
    /// whose delete confirmation the page opens (it holds the window's modal), and confirms when `confirm`.
    var launchDelete: (target: PRCommentTarget, confirm: Bool)? { get set }
    #endif
    /// Whether an action (any) runs on item `number`.
    func isBusy(_ number: Int) -> Bool
    /// The general thread action running on item `number`, if the running one is one.
    func runningGeneral(on number: Int) -> PRGeneralAction?
    func perform(_ action: PRGeneralAction, on number: Int, github: HostingStore)
}

extension PRGeneralThreadModel {
    /// Edit in a comment's menu: its editor opens in place of its body, holding its raw markdown.
    func beginEdit(_ target: PRCommentTarget) {
        commentEditDrafts[target.key] = target.body
        editingComments.insert(target.key)
    }

    /// Cancel in the editor: it closes, its text goes. Save closes it only (the edit then shows on the page at once):
    /// its text goes once the write is in (`savedEdit`), or the editor opens again with it (`reopenEdit`).
    func endEdit(_ key: String) {
        editingComments.remove(key)
        commentEditDrafts[key] = nil
    }

    /// A saved edit is in: its text goes, unless the user opened the editor again meanwhile.
    func savedEdit(_ key: String) {
        if !editingComments.contains(key) { commentEditDrafts[key] = nil }
    }

    /// A saved edit failed: its editor opens again with `body`, the text the user saved (one the user opened again
    /// meanwhile keeps its text).
    func reopenEdit(_ key: String, body: String) {
        guard editingComments.insert(key).inserted else { return }
        commentEditDrafts[key] = body
    }
}

extension PRTimeline {
    /// How many levels replies indent at most; deeper ones stay at the last level.
    private nonisolated static let maxReplyDepth = 4

    /// The page: the description (`author` did `action` on `date`, its `html` or else its `markdown`), then the
    /// comments, reviews and threads of no shown review oldest first (`HostedTimelineOrder`), each review with its
    /// threads, each general comment with its replies indented under it. A commented review GitHub only made to hold
    /// replies to other reviews' threads, with no text of its own, is hidden as on GitHub.
    /// Threads are collapsed per `isCollapsed(_:expanded:)`. Where `general` offers it, each general root and its
    /// replies end with a reply row (`greply-<root>`), and a resolvable root has a chevron (`gchevron-<root>`) and
    /// collapses like a thread when resolved (`gthread-<root>`). Where `general` offers reactions, every comment (not
    /// the description or a review's body) has an add-reaction button in its header (`cadd-<key>`), and one with
    /// reactions a row of chips after its body (`creact-<key>`). An issue's page has no
    /// reviews and no threads. Dates follow the user's date format (Settings › Appearance, 24 h by default).
    nonisolated static func page(
        author: HostedUser?, action: String, date: Date?, html: String?, markdown: String?,
        comments: [HostedComment], reviews: [HostedReview] = [], threads: Loadable<PRThreads> = .idle,
        expanded: [Int: Bool] = [:], general options: PRGeneralOptions = PRGeneralOptions()
    ) -> PRTimelineHTML {
        let dates = DateFormatter()
        dates.locale = Locale(identifier: Locale.current.identifier)
        dates.dateFormat = Preferences.defaults.string(forKey: PrefKey.dateFormat.rawValue) ?? "MM/dd/yy @ HH:mm"
        var avatars: [String: HostedUser] = [:]
        var general: [Int: PRGeneralThread] = [:]
        var targets: [String: PRCommentTarget] = [:]
        var reactionTargets: [String: PRReactionTarget] = [:]

        /// The comment's menu and editor target when `options` offer Edit or Delete on it, kept for the overlays.
        func target(_ target: PRCommentTarget?) -> PRCommentTarget? {
            if let target { targets[target.key] = target }
            return target
        }

        /// The comment's reaction row's slot, after its body and editor: only when it has reactions. Its key is `g`
        /// or `r` and an integer id, the format the measuring script accepts.
        func reactionSlot(_ target: PRReactionTarget?) -> String {
            guard let target, target.hasRow else { return "" }
            return "<div class=\"slot-react\" data-slot=\"creact-\(target.key)\"></div>"
        }

        /// The in-place editor's slot, right after the comment's body (the stylesheet hides that body while the slot
        /// is open): hidden, and so not measured, until the patch opens it.
        func editSlot(_ target: PRCommentTarget?) -> String {
            target.map { "<div class=\"slot-edit\" data-slot=\"cedit-\($0.key)\"></div>" } ?? ""
        }

        /// A header's content: the avatar slot, the login, what they did (none for a thread's comment), `extra` (a
        /// capsule), when, the add-reaction button's slot when `reactions` (kept for the overlays), and the "…" menu's
        /// slot when `menu` (the viewer's own comment).
        func head(
            _ slot: String, _ user: HostedUser?, action: String?, badge: String? = nil, extra: String = "", date: Date?,
            menu: PRCommentTarget? = nil, reactions: PRReactionTarget? = nil
        ) -> String {
            avatars[slot] = user
            let what = action.map { action in
                " " + (badge.map { "<span class=\"badge \($0)\">\(HostedHTML.escape(action))</span>" }
                    ?? HostedHTML.escape(action))
            } ?? ""
            let when = date.map { "<span class=\"date\">\(HostedHTML.escape(dates.string(from: $0)))</span>" } ?? ""
            // A key is `g` or `r` and an integer id: the format the measuring script accepts.
            let menu = menu.map { "<span class=\"slot-menu\" data-slot=\"cmenu-\($0.key)\"></span>" } ?? ""
            if let reactions { reactionTargets[reactions.key] = reactions }
            let add = reactions.map { "<span class=\"slot-add\" data-slot=\"cadd-\($0.key)\"></span>" } ?? ""
            // Slot ids are `avatar-d` or an integer id after a prefix, the formats the measuring script accepts
            // (`GitHubHTMLPage`); one made from a String would have to go through `HostedHTML.escape`.
            return "<span class=\"slot-avatar\" data-slot=\"\(slot)\"></span>"
                + "<b>\(HostedHTML.escape(user?.login ?? "ghost"))</b>\(what)\(extra)\(when)\(add)\(menu)"
        }

        /// A comment in a thread or a reply: its header (avatar slot, login, date, the add-reaction and menu slots),
        /// its body, the editor's slot and the reaction row's.
        func commentHTML(
            _ slot: String, _ user: HostedUser?, date: Date?, body: String?, menu: PRCommentTarget? = nil,
            reactions: PRReactionTarget? = nil
        ) -> String {
            let body = body.map { "<div class=\"body\">\($0)</div>" } ?? ""
            let header = head(slot, user, action: nil, date: date, menu: menu, reactions: reactions)
            return "<div class=\"comment\"><div class=\"comment-head\">\(header)</div>\(body)\(editSlot(menu))"
                + "\(reactionSlot(reactions))</div>"
        }

        /// Replies (their depth and HTML, each after the one it answers) in nested `replies` boxes, one per level up
        /// to `maxReplyDepth`, each drawing its thread line. Never inside a `.body`: the measuring script skips slots
        /// there.
        func replies(_ list: [(depth: Int, html: String)]) -> String {
            var html = ""
            var open = 0
            for reply in list {
                let level = min(max(reply.depth, 1), maxReplyDepth)
                while open < level { html += "<div class=\"replies\">"; open += 1 }
                while open > level { html += "</div>"; open -= 1 }
                html += reply.html
            }
            return html + String(repeating: "</div>", count: open)
        }

        /// A thread: its header (chevron slot, path, lines, state), then, unless collapsed, the commented diff rows,
        /// the first comment, the replies indented under it and the reply slot. Its id and `collapsed` class let the
        /// app expand it without a reload.
        func thread(_ thread: HostedReviewThread) -> String {
            let collapsed = isCollapsed(thread, expanded: expanded)
            let comments = thread.comments.map { comment in
                commentHTML("avatar-c\(comment.id)", comment.user, date: comment.createdAt,
                            body: bodyHTML(comment.bodyHTML, comment.body), menu: target(PRCommentTarget(
                                .review, id: comment.id, hostKey: comment.hostKey, body: comment.body,
                                user: comment.user, canEdit: comment.viewerCanEdit,
                                canDelete: comment.viewerCanDelete, options: options)),
                            reactions: PRReactionTarget(.review, id: comment.id, hostKey: comment.hostKey,
                                                        reactions: comment.reactions, user: comment.user,
                                                        options: options))
            }
            // `thread.id` is an integer: it goes in unescaped (a String id would need `HostedHTML.escape`). A thread
            // the host has not answered yet has no reply row (`PRPlaceholderID`).
            let reply = PRPlaceholderID.isPlaceholder(thread.id)
                ? "" : "<div class=\"slot-reply\" data-slot=\"reply-\(thread.id)\"></div>"
            return "<div class=\"thread\(collapsed ? " collapsed" : "")\" id=\"thread-\(thread.id)\">"
                + threadHead(thread, isResolved: thread.state?.isResolved == true) + excerptTable(thread)
                + (comments.first ?? "") + replies(comments.dropFirst().map { (1, $0) }) + reply + "</div>"
        }

        /// `generalThread`: a general thread's root, which gets its reply row, and when resolvable its chevron, its
        /// Resolved capsule and an id the patch collapses it by. `menu`: a general comment's menu and editor target;
        /// `reactions`: its add-reaction button's and reaction row's.
        func item(
            _ slot: String, _ user: HostedUser?, _ action: String, badge: String? = nil, date: Date?, body: String?,
            emptyText: String? = nil, threads: [HostedReviewThread] = [], replies: String = "",
            generalThread: PRGeneralThread? = nil, menu: PRCommentTarget? = nil, reactions: PRReactionTarget? = nil
        ) -> String {
            let content: String
            if let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                content = "<div class=\"body\">\(body)</div>"
            } else if let emptyText {
                content = "<div class=\"body empty\">\(HostedHTML.escape(emptyText))</div>"
            } else {
                content = ""
            }
            let list = threads.isEmpty ? "" : "<div class=\"threads\">\(threads.map(thread).joined())</div>"
            let edit = editSlot(menu) + reactionSlot(reactions)
            guard let generalThread else {
                let header = head(slot, user, action: action, badge: badge, date: date, menu: menu,
                                  reactions: reactions)
                return "<section class=\"item\"><div class=\"head\">\(header)</div>\(content)\(edit)\(replies)"
                    + "\(list)</section>"
            }
            // The root's id is an integer: it goes in unescaped (a String id would need `HostedHTML.escape`).
            let id = generalThread.root.id
            let chevron = generalThread.resolvable
                ? "<span class=\"slot-chevron\" data-slot=\"gchevron-\(id)\"></span>" : ""
            let cap = generalThread.isResolved ? "<span class=\"cap resolved\">✓ Resolved</span>" : ""
            let header = head(slot, user, action: action, badge: badge, extra: cap, date: date, menu: menu,
                              reactions: reactions)
            let collapsed = isCollapsed(generalThread, expanded: options.expanded) ? " collapsed" : ""
            return "<section class=\"item\(collapsed)\" id=\"gthread-\(id)\">"
                + "<div class=\"head\">\(chevron)\(header)</div>\(content)\(edit)\(replies)\(list)"
                + "<div class=\"slot-reply\" data-slot=\"greply-\(id)\"></div></section>"
        }

        let replyOnly = threads.value?.replyOnlyReviewIDs ?? []
        // Only a commented one: an approval or a change request submitted with a reply and no text still shows.
        let shown = reviews.filter { review in
            review.state != "PENDING" && !(review.state == "COMMENTED" && replyOnly.contains(review.id)
                && bodyHTML(review.bodyHTML, review.body) == nil)
        }
        // A thread whose review is not shown (pending, or missing from the reviews) would vanish: it goes in the
        // timeline at its first comment's time, in a fixed order, so the same answer always builds the same page (a
        // reload then only measures it again).
        let sorted = HostedTimelineOrder.entries(
            comments: comments, reviews: shown, threads: threads.value?.all ?? []
        ).map { entry in
            switch entry {
            case .comment(let root, let list):
                var generalThread: PRGeneralThread?
                // A root the host has not answered yet gets no reply row or chevron (`PRPlaceholderID`).
                if options.replies || options.resolve, !PRPlaceholderID.isPlaceholder(root.id) {
                    generalThread = PRGeneralThread(root: root, resolvable: options.resolve && root.resolvable == true)
                    general[root.id] = generalThread
                }
                return item(
                    "avatar-i\(root.id)", root.user, "commented", date: root.createdAt,
                    body: bodyHTML(root.bodyHTML, root.body), replies: replies(list.map { reply in
                        (reply.depth, commentHTML("avatar-i\(reply.comment.id)", reply.comment.user,
                                                  date: reply.comment.createdAt,
                                                  body: bodyHTML(reply.comment.bodyHTML, reply.comment.body),
                                                  menu: target(Self.target(reply.comment, options)),
                                                  reactions: Self.reactions(reply.comment, options)))
                    }), generalThread: generalThread, menu: target(Self.target(root, options)),
                    reactions: Self.reactions(root, options))
            case .review(let review, let threads):
                let (action, badge): (String, String?) = switch review.state {
                case "APPROVED": ("approved these changes", "approved")
                case "CHANGES_REQUESTED": ("requested changes", "changes")
                case "DISMISSED": ("reviewed (dismissed)", nil)
                default: ("reviewed", nil)
                }
                return item(
                    "avatar-r\(review.id)", review.user, action, badge: badge, date: review.submittedAt,
                    body: bodyHTML(review.bodyHTML, review.body), threads: threads)
            case .thread(let loose):
                return "<div class=\"threads loose\">\(thread(loose))</div>"
            }
        }
        let description = item(
            "avatar-d", author, action, date: date, body: bodyHTML(html, markdown),
            emptyText: "No description provided.")
        var end = ""
        if case .failed(let message) = threads {
            end += "<p class=\"empty\">The inline review comments did not load: \(HostedHTML.escape(message))</p>"
        }
        return PRTimelineHTML(
            html: ([description] + sorted).joined() + end, avatars: avatars, count: comments.count + shown.count,
            general: general, comments: targets, reactions: reactionTargets, reactionKinds: options.reactions)
    }

    /// A general comment's reaction row target, when `options` offer reactions.
    private nonisolated static func reactions(_ comment: HostedComment, _ options: PRGeneralOptions)
        -> PRReactionTarget?
    {
        PRReactionTarget(.general, id: comment.id, hostKey: comment.hostKey, reactions: comment.reactions,
                         user: comment.user, options: options)
    }

    /// A general comment's menu and editor target, when `options` offer Edit or Delete on it.
    private nonisolated static func target(_ comment: HostedComment, _ options: PRGeneralOptions) -> PRCommentTarget? {
        PRCommentTarget(.general, id: comment.id, hostKey: comment.hostKey, body: comment.body, user: comment.user,
                        canEdit: comment.viewerCanEdit, canDelete: comment.viewerCanDelete, options: options)
    }

    /// Whether the general thread `thread` shows collapsed (its header only): only a resolvable one can be, a resolved
    /// one is, unless the user chose otherwise (`expanded`, by root comment id).
    nonisolated static func isCollapsed(_ thread: PRGeneralThread, expanded: [Int: Bool]) -> Bool {
        thread.resolvable && !(expanded[thread.root.id] ?? !thread.isResolved)
    }

    /// `comments` as they are once `action` is done, for the optimistic page: a reply appended under its root, by
    /// `viewer` (a copy of the root with the reply's values, id `replyID`, no menu until the host gives it its id),
    /// the root's `resolved` flipped, a general comment's new body (as plain text until the reload brings the host's
    /// HTML), a general comment removed: a comment with replies stays as "This comment was deleted" where the host
    /// keeps it (`keepsDeleted`: Bitbucket), or the viewer's reaction toggled on a general comment (`toggled`, in the
    /// order of the host's `kinds`).
    nonisolated static func patched(
        _ comments: [HostedComment], _ action: PRGeneralAction, viewer: HostedUser?, replyID: Int,
        keepsDeleted: Bool = false, kinds: [String] = []
    ) -> [HostedComment] {
        switch action {
        case .reply(let root, let body):
            var reply = root
            reply.id = replyID
            reply.user = viewer ?? HostedUser(id: 0, login: "you")
            reply.body = body
            reply.bodyHTML = nil
            reply.htmlURL = nil
            reply.createdAt = .now
            reply.updatedAt = nil
            reply.parentID = root.id
            reply.resolvable = nil
            reply.resolved = nil
            reply.viewerCanEdit = false
            reply.viewerCanDelete = false
            reply.reactions = []
            return comments + [reply]
        case .resolve(let root, let resolved):
            return comments.map { comment in
                var comment = comment
                if comment.id == root.id { comment.resolved = resolved }
                return comment
            }
        case .edit(let target, let body) where target.kind == .general:
            return comments.map { comment in
                guard comment.id == target.id else { return comment }
                var comment = comment
                comment.body = body
                comment.bodyHTML = nil
                comment.updatedAt = .now
                return comment
            }
        case .delete(let target) where target.kind == .general:
            guard keepsDeleted, comments.contains(where: { $0.parentID == target.id }) else {
                return comments.filter { $0.id != target.id }
            }
            return comments.map { comment in
                guard comment.id == target.id else { return comment }
                var comment = comment
                comment.body = "This comment was deleted"
                comment.bodyHTML = nil
                comment.resolvable = false
                comment.viewerCanEdit = false
                comment.viewerCanDelete = false
                comment.reactions = []
                return comment
            }
        case .react(let target, let kind, let add) where target.kind == .general:
            return comments.map { comment in
                guard comment.id == target.id else { return comment }
                var comment = comment
                comment.reactions = toggled(comment.reactions, kind, add: add, kinds: kinds)
                return comment
            }
        case .edit, .delete, .react:
            return comments
        }
    }

    /// `reactions` with the viewer's `kind` added (count + 1, highlighted; a new kind goes where the host's `kinds`
    /// order puts it, one outside them last) or removed (count − 1, a chip at 0 gone). Already as asked: unchanged.
    nonisolated static func toggled(
        _ reactions: [HostedReaction], _ kind: String, add: Bool, kinds: [String]
    ) -> [HostedReaction] {
        var reactions = reactions
        if let index = reactions.firstIndex(where: { $0.kind == kind }) {
            guard reactions[index].viewerReacted != add else { return reactions }
            reactions[index].count += add ? 1 : -1
            reactions[index].viewerReacted = add
            if reactions[index].count <= 0 { reactions.remove(at: index) }
        } else if add {
            let rank = { (kind: String) in kinds.firstIndex(of: kind) ?? kinds.count }
            let index = reactions.firstIndex { rank($0.kind) > rank(kind) } ?? reactions.count
            reactions.insert(HostedReaction(kind: kind, count: 1, viewerReacted: true), at: index)
        }
        return reactions
    }

    /// `timeline` with a reaction toggled on its comment's row, for the optimistic page without a rebuild, when the
    /// comment keeps its row (the HTML stays); nil for another action, or for a first reaction or the last one
    /// removed, whose row comes or goes with a rebuilt page.
    nonisolated static func patched(_ timeline: PRTimelineHTML, _ action: PRGeneralAction) -> PRTimelineHTML? {
        guard case .react(let target, let kind, let add) = action else { return nil }
        var timeline = timeline
        let shown = timeline.reactions[target.key]?.reactions ?? target.reactions
        let reactions = toggled(shown, kind, add: add, kinds: timeline.reactionKinds)
        guard PRReactionTarget.hasRow(shown) == PRReactionTarget.hasRow(reactions) else { return nil }
        timeline.reactions[target.key]?.reactions = reactions
        return timeline
    }

    /// `threads` as they are once an edit, delete or reaction of a review comment is done, for the optimistic page: the
    /// comment's new body, or the comment removed (a thread left empty with it); a thread's first comment with replies
    /// stays without a body where the host keeps it (`keepsDeleted`: Bitbucket); the viewer's reaction toggled (in the
    /// order of the host's `kinds`). Any other action leaves them as they are.
    nonisolated static func patched(
        _ threads: Loadable<PRThreads>, _ action: PRGeneralAction, keepsDeleted: Bool, kinds: [String] = []
    ) -> Loadable<PRThreads> {
        guard case .loaded(let loaded) = threads else { return threads }
        let patch: (HostedReviewThread) -> HostedReviewThread?
        switch action {
        case .edit(let target, let body) where target.kind == .review:
            patch = { thread in
                var thread = thread
                thread.comments = thread.comments.map { comment in
                    guard comment.id == target.id else { return comment }
                    var comment = comment
                    comment.body = body
                    comment.bodyHTML = nil
                    return comment
                }
                return thread
            }
        case .delete(let target) where target.kind == .review:
            patch = { thread in
                var thread = thread
                if keepsDeleted, thread.comments.first?.id == target.id, thread.comments.count > 1 {
                    thread.comments[0].body = nil
                    thread.comments[0].bodyHTML = nil
                    thread.comments[0].viewerCanEdit = false
                    thread.comments[0].viewerCanDelete = false
                } else {
                    thread.comments.removeAll { $0.id == target.id }
                }
                return thread.comments.isEmpty ? nil : thread
            }
        case .react(let target, let kind, let add) where target.kind == .review:
            patch = { thread in
                var thread = thread
                thread.comments = thread.comments.map { comment in
                    guard comment.id == target.id else { return comment }
                    var comment = comment
                    comment.reactions = toggled(comment.reactions, kind, add: add, kinds: kinds)
                    return comment
                }
                return thread
            }
        default:
            return threads
        }
        return .loaded(PRThreads(
            byReview: loaded.byReview.mapValues { $0.compactMap(patch) }.filter { !$0.value.isEmpty },
            replyOnlyReviewIDs: loaded.replyOnlyReviewIDs, unattached: loaded.unattached.compactMap(patch),
            resolveUnavailable: loaded.resolveUnavailable, statesFailed: loaded.statesFailed))
    }

    /// Whether `thread` shows collapsed (its header only): a resolved one is, an unresolved one is not, unless the user
    /// chose otherwise (`expanded`, by root comment id). The page and the native views on it agree on it.
    nonisolated static func isCollapsed(_ thread: HostedReviewThread, expanded: [Int: Bool]) -> Bool {
        !(expanded[thread.id] ?? (thread.state?.isResolved != true))
    }

    /// The chevron slot, the path with its folders shortened in the middle when it is too long (the file name
    /// stays), "Line N" or "Lines a–b", and the Outdated and Resolved capsules (Resolved green with a check, so a
    /// resolved thread reads at a glance: user, 2026-11-20).
    private nonisolated static func threadHead(_ thread: HostedReviewThread, isResolved: Bool) -> String {
        let slash = thread.path.lastIndex(of: "/")
        let folder = slash.map { String(thread.path[..<$0]) } ?? ""
        let file = slash.map { String(thread.path[$0...]) } ?? thread.path
        let lines: String? = switch (thread.startLine, thread.line) {
        case let (start?, end?) where start != end: "Lines \(start)–\(end)"
        case let (_, end?): "Line \(end)"
        default: nil
        }
        // `thread.id` is an integer: it goes in unescaped (a String id would need `HostedHTML.escape`).
        return "<div class=\"thread-head\"><span class=\"slot-chevron\" data-slot=\"chevron-\(thread.id)\"></span>"
            + "<span class=\"path\" title=\"\(HostedHTML.escape(thread.path))\">"
            + "<span class=\"folder\">\(HostedHTML.escape(folder))</span>"
            + "<span class=\"file\">\(HostedHTML.escape(file))</span></span>"
            + (lines.map { "<span class=\"lines\">\($0)</span>" } ?? "")
            + (thread.isOutdated ? "<span class=\"cap outdated\">Outdated</span>" : "")
            + (isResolved ? "<span class=\"cap resolved\">✓ Resolved</span>" : "") + "</div>"
    }

    /// The commented diff rows as the Files tab shows them: old and new line numbers, the sign, the text on a green or
    /// red band.
    private nonisolated static func excerptTable(_ thread: HostedReviewThread) -> String {
        let rows = excerpt(thread).map { line in
            let (kind, sign) = switch line.kind {
            case .added: ("add", "+")
            case .removed: ("del", "−")
            case .context: ("ctx", "")
            }
            return "<tr class=\"\(kind)\"><td class=\"num\">\(line.oldLine.map(String.init) ?? "")</td>"
                + "<td class=\"num\">\(line.newLine.map(String.init) ?? "")</td><td class=\"sign\">\(sign)</td>"
                + "<td class=\"code\">\(HostedHTML.escape(line.text))</td></tr>"
        }
        return rows.isEmpty ? "" : "<table class=\"excerpt\">\(rows.joined())</table>"
    }

    /// The rows of `thread`'s diff hunk, which ends at the commented line: from its first line for a range (the rows
    /// of the other side in between included), else the last 4. The hunk goes through the Files tab's patch parser,
    /// `HostedPullRequestFile.diff`, the parser's only public way in, as the patch of a file.
    private nonisolated static func excerpt(_ thread: HostedReviewThread) -> ArraySlice<DiffLine> {
        let file: [String: Any] = [
            "filename": thread.path, "status": "modified", "additions": 0, "deletions": 0,
            "patch": thread.diffHunk ?? "",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: file),
              let lines = (try? JSONDecoder().decode(HostedPullRequestFile.self, from: data))?.diff?.hunks.last?.lines
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
/// expanded thread, and the same on general threads where the host has general replies or resolving (`general`, the
/// pull request's or the issue's model). The views are clipped to the page's frame, and the slots live with the page,
/// so a new page never shows the old one's views. A quiet reload measures the page again (`measureKey`), so the views follow it even when
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
    let avatars: HostAvatars
    /// What the general threads' rows, and the comments' menus and editors, act through; nil draws none.
    var general: (any PRGeneralThreadModel)?
    @Environment(WindowModel.self) private var window
    @State private var slots: [HostedHTMLSlot] = []
    /// Each reply row's height with its margins, by slot id: its slot takes it, so a field grown to more lines pushes
    /// the rest of the page down instead of covering it.
    @State private var replyHeights: [String: CGFloat] = [:]

    var body: some View {
        let threads = Dictionary(
            (self.threads?.all ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let expanded = session.pullDetail.threadExpanded
        let generalExpanded = general?.generalExpanded ?? [:]
        // `thread-<integer id>` and `gthread-<integer id>`, the page's ids and the only ones the patch accepts
        // (`GitHubHTMLPage`).
        let collapsed = Dictionary(uniqueKeysWithValues: threads.values.map { thread in
            ("thread-\(thread.id)", PRTimeline.isCollapsed(thread, expanded: expanded))
        } + timeline.general.values.filter(\.resolvable).map { thread in
            ("gthread-\(thread.root.id)", PRTimeline.isCollapsed(thread, expanded: generalExpanded))
        })
        // `cedit-<key>`, the editor slots' format the patch accepts.
        let editing = Set((general?.editingComments ?? []).map { "cedit-\($0)" })
        // Read once for every comment menu, not by each.
        let busy = general?.isBusy(number) ?? false
        HostedHTMLView(
            html: timeline.html, measureKey: loadID,
            patch: HostedHTMLPatch(slotHeights: replyHeights, collapsed: collapsed, editing: editing)
        ) { [kind, number] in
            UITiming.content("\(kind) \(number) conversation html")
            #if DEBUG
            PRLaunchActionGate.pageDidShow()
            #endif
        } onSlots: {
            slots = $0
        }
        .overlay(alignment: .topLeading) {
            // Its own top-leading stack: the overlay's implicit one centers its views in their union (the widest
            // one's box), which shifted every avatar off its slot.
            ZStack(alignment: .topLeading) {
                ForEach(slots, id: \.id) { slot in
                    overlay(slot, threads: threads, expanded: expanded, generalExpanded: generalExpanded, busy: busy)
                        .frame(width: slot.frame.width, height: slot.frame.height, alignment: .top)
                        .slotProbeFrame(slot.id)
                        .offset(x: slot.frame.minX, y: slot.frame.minY)
                }
            }
        }
        .clipped()
        #if DEBUG
        .onChange(of: probedReactions, initial: true) {
            // The chips are native, so no page snapshot shows them: the slot probe logs what each row holds.
            for (key, target) in probedReactions.sorted(by: { $0.key < $1.key }) {
                let chips = target.reactions.map { "\($0.kind):\($0.count)\($0.viewerReacted ? "*" : "")" }
                let text = chips.isEmpty ? "none" : chips.joined(separator: ",")
                UITiming.probe("slot-probe", "creact-\(key) reactions \(text)")
            }
        }
        .onChange(of: general?.launchDelete?.target, initial: true) {
            guard let general, let request = general.launchDelete else { return }
            general.launchDelete = nil
            let confirmation = PRCommentMenu.deleteConfirmation(
                request.target, number: number, model: general, github: session.github)
            window.presentModal(.confirmation(confirmation))
            UITiming.content("\(kind) \(number) action delete open")
            // As the modal's button does (`ModalHost`): the modal closes, then its action runs.
            if request.confirm {
                window.closeModal()
                confirmation.perform()
            } else {
                // Whether the modal is still up a second later (a tab or page change would have cancelled it).
                Task { [window, kind, number] in
                    try? await Task.sleep(for: .seconds(1))
                    UITiming.content("\(kind) \(number) action delete modal \(window.modal == nil ? "gone" : "shown")")
                }
            }
        }
        #endif
    }

    #if DEBUG
    /// The reaction rows the slot probe logs (none without it, so nothing is compared on a long page).
    private var probedReactions: [String: PRReactionTarget] {
        GitHubHTMLProbe.slotsEnabled ? timeline.reactions : [:]
    }
    #endif

    /// Only the slots this page's HTML made get a view: the avatars of `timeline.avatars` (a deleted account's as
    /// "ghost"), the chevrons and the reply rows, of review threads and of general threads (`timeline.general`), and
    /// each comment's menu, editor, reaction row and add-reaction button. A thread collapsed by a click drops its reply
    /// row at once, before the page is measured again without its slot.
    @ViewBuilder private func overlay(
        _ slot: HostedHTMLSlot, threads: [Int: HostedReviewThread], expanded: [Int: Bool],
        generalExpanded: [Int: Bool], busy: Bool
    ) -> some View {
        if slot.id.hasPrefix("avatar-") {
            let user = timeline.avatars[slot.id]
            GitHubUserAvatar(login: user?.login ?? "ghost", id: user?.id, avatarURL: user?.avatarURL,
                             size: slot.frame.width, avatars: avatars)
        } else if let thread = Self.thread(of: slot, "chevron-", in: threads) {
            chevron(thread, collapsed: PRTimeline.isCollapsed(thread, expanded: expanded))
        } else if let thread = Self.thread(of: slot, "reply-", in: threads),
                  !PRTimeline.isCollapsed(thread, expanded: expanded) {
            measured(PRReplyRow(session: session, number: number, thread: thread,
                                resolveUnavailable: self.threads?.resolveUnavailable, width: slot.frame.width),
                     slot: slot)
        } else if let general, let thread = Self.general(of: slot, "gchevron-", in: timeline.general) {
            let collapsed = PRTimeline.isCollapsed(thread, expanded: generalExpanded)
            PRThreadChevron(collapsed: collapsed, subject: "\(thread.root.user?.login ?? "ghost")'s comment") {
                general.generalExpanded[thread.root.id] = collapsed
            }
        } else if let general, let thread = Self.general(of: slot, "greply-", in: timeline.general),
                  !PRTimeline.isCollapsed(thread, expanded: generalExpanded) {
            measured(PRGeneralReplyRow(session: session, number: number, kind: kind, thread: thread, model: general,
                                       width: slot.frame.width),
                     slot: slot)
        } else if let general, let target = Self.comment(of: slot, "cmenu-", in: timeline.comments) {
            PRCommentMenu(session: session, number: number, kind: kind, target: target, model: general,
                          window: window, busy: busy)
        } else if let general, let target = Self.comment(of: slot, "cedit-", in: timeline.comments),
                  general.editingComments.contains(target.key) {
            measured(PRCommentEditor(session: session, number: number, target: target, model: general), slot: slot)
        } else if let general, let target = Self.reactions(of: slot, "creact-", in: timeline.reactions) {
            PRReactionRow(session: session, number: number, target: target, model: general, busy: busy)
        } else if let general, let target = Self.reactions(of: slot, "cadd-", in: timeline.reactions) {
            PRReactionAddButton(session: session, number: number, target: target, kinds: timeline.reactionKinds,
                                model: general, busy: busy)
        }
    }

    /// The comment of a `creact-<key>` or `cadd-<key>` slot.
    private static func reactions(
        of slot: HostedHTMLSlot, _ prefix: String, in reactions: [String: PRReactionTarget]
    ) -> PRReactionTarget? {
        guard slot.id.hasPrefix(prefix) else { return nil }
        return reactions[String(slot.id.dropFirst(prefix.count))]
    }

    /// The comment of a `cmenu-<key>` or `cedit-<key>` slot.
    private static func comment(
        of slot: HostedHTMLSlot, _ prefix: String, in comments: [String: PRCommentTarget]
    ) -> PRCommentTarget? {
        guard slot.id.hasPrefix(prefix) else { return nil }
        return comments[String(slot.id.dropFirst(prefix.count))]
    }

    /// A reply row on its slot: its own height, not the slot's, which takes it (`replyHeights`).
    private func measured(_ row: some View, slot: HostedHTMLSlot) -> some View {
        row
            .padding(.vertical, 8)
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

    /// The general thread of a `gchevron-<root>` or `greply-<root>` slot.
    private static func general(
        of slot: HostedHTMLSlot, _ prefix: String, in threads: [Int: PRGeneralThread]
    ) -> PRGeneralThread? {
        guard slot.id.hasPrefix(prefix) else { return nil }
        return Int(slot.id.dropFirst(prefix.count)).flatMap { threads[$0] }
    }

    /// The thread of a `chevron-<root>` or `reply-<root>` slot.
    private static func thread(
        of slot: HostedHTMLSlot, _ prefix: String, in threads: [Int: HostedReviewThread]
    ) -> HostedReviewThread? {
        guard slot.id.hasPrefix(prefix) else { return nil }
        return Int(slot.id.dropFirst(prefix.count)).flatMap { threads[$0] }
    }

    /// The thread's chevron: a click expands or collapses it at once (the user's choice, kept across reloads), and
    /// the page follows with the patch.
    private func chevron(_ thread: HostedReviewThread, collapsed: Bool) -> some View {
        PRThreadChevron(collapsed: collapsed, subject: thread.path) {
            session.pullDetail.threadExpanded[thread.id] = collapsed
        }
    }
}

/// A thread's chevron, review or general: `toggle` expands or collapses it.
private struct PRThreadChevron: View {
    let collapsed: Bool
    /// What the conversation is on, for VoiceOver (a path, "reviewer's comment").
    let subject: String
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(RowIconButtonStyle())
        .help(collapsed ? "Show the conversation" : "Hide the conversation")
        .accessibilityLabel(collapsed ? "Expand the conversation on \(subject)"
                            : "Collapse the conversation on \(subject)")
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
    let thread: HostedReviewThread
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
            PRReplyEditor(draft: draft, focused: $focused, isFocused: focused, disabled: replying(running),
                          label: "Reply to the conversation on \(thread.path)")
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
                if session.github.offers(.resolveThreads) { resolveControl(running) }
            }
            .fixedSize()
        }
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
                session.pullDetail.perform(.resolve(thread: state, resolved: !state.isResolved), on: number,
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
        if case .resolve(let state, _)? = action { return state.id == thread.state?.id }
        return false
    }
}

/// A reply row's comment box: the comment box's look (`settingsTextEditor`), with the row's own focus (`focused`):
/// ⌘↩ belongs to the focused row only. A `TextEditor` has no height of its own, so a hidden copy of the draft gives it
/// one: 1 to 6 lines at its width (NSTextView's 5 pt line padding on each side; a trailing new line is a line), with
/// the editor drawn on it. Its scroller never shows, so its lines wrap where the copy's do.
private struct PRReplyEditor: View {
    let draft: Binding<String>
    let focused: FocusState<Bool>.Binding
    /// The row's focus as a value: the chrome redraws when it changes.
    let isFocused: Bool
    let disabled: Bool
    /// VoiceOver's name for the box.
    let label: String
    /// What the empty box says.
    var placeholder = "Write a reply"
    /// The most lines it grows to before it scrolls.
    var maxLines = 6
    @Environment(\.tabIsShown) private var tabIsShown

    var body: some View {
        let text = draft.wrappedValue
        Text(verbatim: text.isEmpty || text.hasSuffix("\n") ? text + " " : text)
            .font(.body)
            .lineLimit(1...maxLines)
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hidden()
            .overlay {
                // Unmounted in a kept-alive tab that is not shown, out of the key view loop (`settingsTextEditor`).
                if tabIsShown {
                    TextEditor(text: draft)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.never)
                        .focused(focused)
                        .accessibilityLabel(label)
                }
            }
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .modifier(SettingsInputChrome(focused: isFocused))
            .disabled(disabled)
    }
}

/// A general thread's reply row, on the slot under its root and replies, laid out like `PRReplyRow`: "Write a reply",
/// Reply (where the host has general replies), and "Resolve conversation" ("Unresolve conversation" on a resolved
/// thread) on a resolvable root. It acts through `model`, the pull request's or the issue's detail, which patches the
/// page at once and writes off the main actor (`PRGeneralThreadModel`); the draft is the model's
/// (`generalReplyDrafts`). A click shows its busy state at once (both buttons off, the box too while its reply posts),
/// the spinner after `DelayedSpinner.delay`.
private struct PRGeneralReplyRow: View {
    let session: RepoSession
    let number: Int
    /// The timing log's word for the item (`pr`, `issue`).
    let kind: String
    let thread: PRGeneralThread
    let model: any PRGeneralThreadModel
    /// The slot's width.
    let width: CGFloat
    @FocusState private var focused: Bool

    /// A box of about 200 pt beside Reply and "Unresolve conversation" (`PRReplyRow`'s).
    private static let oneLineWidth: CGFloat = 440

    var body: some View {
        let root = thread.root
        let draft = Binding {
            model.generalReplyDrafts[root.id] ?? ""
        } set: {
            model.generalReplyDrafts[root.id] = $0.isEmpty ? nil : $0
        }
        let text = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let busy = model.isBusy(number)
        let running = model.runningGeneral(on: number)
        let replying = if case .reply(let target, _)? = running { target.id == root.id } else { false }
        let resolving = if case .resolve(let target, _)? = running { target.id == root.id } else { false }
        let replies = session.github.offers(.generalReplies)
        let layout = width < Self.oneLineWidth
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .lastTextBaseline, spacing: 8))
        layout {
            if replies {
                PRReplyEditor(draft: draft, focused: $focused, isFocused: focused, disabled: replying,
                              label: "Reply to \(root.user?.login ?? "ghost")'s comment")
            }
            HStack(spacing: 8) {
                if replies {
                    Button {
                        guard !text.isEmpty else { return }
                        model.perform(.reply(root: root, body: text), on: number, github: session.github)
                    } label: {
                        HStack(spacing: 6) {
                            if replying { DelayedSpinner(detail: "\(kind) \(number) greply") }
                            Text("Reply")
                        }
                    }
                    .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                    .keyboardShortcut(focused ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    .disabled(text.isEmpty || busy)
                    .help("Reply (⌘↩)")
                }
                if thread.resolvable {
                    Button {
                        model.perform(.resolve(root: root, resolved: !thread.isResolved), on: number,
                                      github: session.github)
                    } label: {
                        HStack(spacing: 6) {
                            if resolving { DelayedSpinner(detail: "\(kind) \(number) gresolve") }
                            Text(thread.isResolved ? "Unresolve conversation" : "Resolve conversation")
                        }
                    }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
                    .disabled(busy)
                    .fixedSize()
                }
            }
            .fixedSize()
        }
    }
}

/// A comment's "…" menu, on the slot at the end of its header: Edit (its editor opens in place of its body at once) and
/// Delete… (the app's own confirmation first), as the host and the comment's rights allow. Off while an action runs on
/// the item. A glyph with a hover circle (`RowIconButtonStyle`'s look) that opens an `NSMenu` on click, not a `Menu` or
/// a `Button`: a long page has one on each of the viewer's comments, and on the 600-comment stub PR (300 of them) the
/// page settled about 125 ms later with `Menu`s or `Button`s, about 60 ms with this.
private struct PRCommentMenu: View {
    let session: RepoSession
    let number: Int
    /// The timing log's word for the item (`pr`, `issue`).
    let kind: String
    let target: PRCommentTarget
    let model: any PRGeneralThreadModel
    /// The page's window, for Delete's confirmation, and whether an action runs on the item: read once by the page,
    /// not by each menu.
    let window: WindowModel
    let busy: Bool

    @State private var hovered = false

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
            .background { Circle().fill(hovered && !busy ? Palette.hoverFill : .clear).padding(-5) }
            .contentShape(Rectangle())
            .opacity(busy ? 0.45 : 1)
            .onHover { hovered = $0 }
            .onTapGesture { if !busy { open() } }
            .help("Edit or delete the comment")
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Actions on \(target.author)'s comment")
            .accessibilityAction { if !busy { open() } }
    }

    /// The menu, under the pointer (the click's place).
    private func open() {
        var entries: [MenuEntry] = []
        if target.canEdit {
            entries.append(.action("Edit") { [model, target, kind, number] in
                model.beginEdit(target)
                UITiming.content("\(kind) \(number) action edit open")
            })
        }
        if target.canDelete {
            entries.append(.action("Delete…", destructive: true) { [window, model, target, number, session] in
                window.presentModal(.confirmation(Self.deleteConfirmation(
                    target, number: number, model: model, github: session.github)))
            })
        }
        MenuBuilder.menu(entries).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Delete's confirmation, in the window's modal: its button deletes the comment (shown gone at once, then written).
    static func deleteConfirmation(
        _ target: PRCommentTarget, number: Int, model: any PRGeneralThreadModel, github: HostingStore
    ) -> ModalConfirmation {
        let host = github.kind.name
        return ModalConfirmation(
            title: "Delete this comment?",
            message: "The comment is deleted on \(host) for everyone. This cannot be undone.",
            button: "Delete Comment", isDestructive: true,
            perform: { model.perform(.delete(target), on: number, github: github) })
    }
}

/// A comment's in-place editor, on the slot after its body (hidden meanwhile): its raw markdown in a box that grows
/// to 12 lines, Cancel and Save (⌘↩). Save shows the new body at once and writes it off the main actor
/// (`PRGeneralAction.edit`); it is off while the box is empty or an action runs on the item. The text is the model's
/// (`commentEditDrafts`), written on every keystroke and read here only.
private struct PRCommentEditor: View {
    let session: RepoSession
    let number: Int
    let target: PRCommentTarget
    let model: any PRGeneralThreadModel
    @FocusState private var focused: Bool

    var body: some View {
        let key = target.key
        let draft = Binding {
            model.commentEditDrafts[key] ?? ""
        } set: {
            model.commentEditDrafts[key] = $0
        }
        // Trimmed only to tell an empty box: Save sends the text as typed (indented code, trailing newlines).
        let isEmpty = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .trailing, spacing: 8) {
            PRReplyEditor(draft: draft, focused: $focused, isFocused: focused, disabled: false,
                          label: "Edit \(target.author)'s comment", placeholder: "Write a comment", maxLines: 12)
            HStack(spacing: 8) {
                Button("Cancel") { model.endEdit(key) }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
                Button("Save") {
                    model.perform(.edit(target, body: draft.wrappedValue), on: number, github: session.github)
                }
                    .buttonStyle(RowTextButtonStyle(formRow: true, prominent: true))
                    // Each open editor has a Save button: the shortcut is only the focused one's.
                    .keyboardShortcut(focused ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    .disabled(isEmpty || model.isBusy(number))
                    .help("Save (⌘↩)")
            }
            .fixedSize()
        }
    }
}

/// A comment's reaction row, on the slot after its body (only a comment with reactions has one): a chip per kind
/// (its emoji and count, highlighted when the viewer gave it; a click adds or removes the viewer's own). Each click
/// changes the row at once and writes off the main actor through `model` (`PRGeneralAction.react`). Off while an
/// action runs on the item. Glyphs with a tap, not `Button`s, as `PRCommentMenu`: a long page has many.
private struct PRReactionRow: View {
    let session: RepoSession
    let number: Int
    let target: PRReactionTarget
    let model: any PRGeneralThreadModel
    let busy: Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(target.reactions, id: \.kind) { reaction in
                PRReactionChip(reaction: reaction, busy: busy) {
                    guard !busy else { return }
                    model.perform(.react(target, kind: reaction.kind, add: !reaction.viewerReacted), on: number,
                                  github: session.github)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One reaction: its emoji and count in a capsule, in the accent color when the viewer gave it.
private struct PRReactionChip: View {
    let reaction: HostedReaction
    let busy: Bool
    let toggle: () -> Void
    @State private var hovered = false

    var body: some View {
        let mine = reaction.viewerReacted
        let name = PRReactionGlyph.name(reaction.kind)
        HStack(spacing: 4) {
            Text(PRReactionGlyph.glyph(reaction.kind))
                .font(.system(size: 12))
            Text("\(reaction.count)")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(mine ? Color.accentColor : .secondary)
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background {
            Capsule().fill(mine ? Color.accentColor.opacity(0.18) : hovered && !busy ? Palette.hoverFill : .clear)
        }
        .overlay { Capsule().strokeBorder(mine ? Color.accentColor.opacity(0.7) : Palette.surfaceBorder) }
        .contentShape(Capsule())
        .opacity(busy ? 0.45 : 1)
        .onHover { hovered = $0 }
        .onTapGesture { toggle() }
        .help(mine ? "Remove your \(name) reaction" : "React with \(name)")
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(name), \(reaction.count)\(mine ? ", including you" : "")")
        .accessibilityAction { toggle() }
    }
}

/// A comment's add-reaction button, on its slot in the header before the "…" menu: a smiley with `PRCommentMenu`'s
/// hover circle; a click opens the host's kinds under the pointer (the viewer's checked; a pick toggles one, through
/// `model` as a chip's click). Off while an action runs on the item.
private struct PRReactionAddButton: View {
    let session: RepoSession
    let number: Int
    let target: PRReactionTarget
    /// The host's kinds, in its picker's order.
    let kinds: [String]
    let model: any PRGeneralThreadModel
    let busy: Bool
    @State private var hovered = false

    var body: some View {
        let author = target.author
        Image(systemName: "face.smiling")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
            .background { Circle().fill(hovered && !busy ? Palette.hoverFill : .clear) }
            .contentShape(Circle())
            .opacity(busy ? 0.45 : 1)
            .onHover { hovered = $0 }
            .onTapGesture { if !busy { open() } }
            .help("Add a reaction")
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Add a reaction to \(author)'s comment")
            .accessibilityAction { if !busy { open() } }
    }

    /// The host's kinds under the pointer (the click's place), the viewer's checked.
    private func open() {
        let mine = Set(target.reactions.filter(\.viewerReacted).map(\.kind))
        let entries = kinds.map { kind in
            MenuEntry.action("\(PRReactionGlyph.glyph(kind))  \(PRReactionGlyph.name(kind))",
                             checked: mine.contains(kind)) {
                guard !busy else { return }
                model.perform(.react(target, kind: kind, add: !mine.contains(kind)), on: number,
                              github: session.github)
            }
        }
        MenuBuilder.menu(entries).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// A reaction's emoji and name, by the host's name for it: GitHub's 8 kinds (REST `content`), GitLab's default 8 and
/// some other common GitLab emoji names. Another name shows as `:name:` (the host's own text for it, cut to
/// `maxUnknown` characters with "…"). For native views only (chips, menus, VoiceOver), never the page's HTML: an award
/// name is the host's text.
enum PRReactionGlyph {
    private nonisolated static let maxUnknown = 24

    private nonisolated static let table: [String: (glyph: String, name: String)] = [
        "+1": ("👍", "Thumbs up"), "-1": ("👎", "Thumbs down"), "laugh": ("😄", "Laugh"), "hooray": ("🎉", "Hooray"),
        "thumbsup": ("👍", "Thumbs up"), "thumbsdown": ("👎", "Thumbs down"), "laughing": ("😆", "Laughing"),
        "tada": ("🎉", "Tada"), "confused": ("😕", "Confused"), "heart": ("❤️", "Heart"), "rocket": ("🚀", "Rocket"),
        "eyes": ("👀", "Eyes"), "smile": ("😄", "Smile"), "smiley": ("😃", "Smiley"), "joy": ("😂", "Joy"),
        "slight_smile": ("🙂", "Slight smile"), "thinking": ("🤔", "Thinking"), "fire": ("🔥", "Fire"),
        "clap": ("👏", "Clap"), "raised_hands": ("🙌", "Raised hands"), "pray": ("🙏", "Pray"),
        "ok_hand": ("👌", "OK hand"), "muscle": ("💪", "Muscle"), "wave": ("👋", "Wave"), "100": ("💯", "100"),
        "star": ("⭐", "Star"), "sparkles": ("✨", "Sparkles"), "white_check_mark": ("✅", "Check mark"),
        "heavy_check_mark": ("✔️", "Check mark"), "x": ("❌", "Cross"), "warning": ("⚠️", "Warning"),
    ]

    nonisolated static func glyph(_ kind: String) -> String { table[kind]?.glyph ?? ":\(shown(kind)):" }
    nonisolated static func name(_ kind: String) -> String { table[kind]?.name ?? shown(kind) }

    /// An unknown name as shown: at most `maxUnknown` characters, the last one "…" when cut.
    private nonisolated static func shown(_ kind: String) -> String {
        kind.count > maxUnknown ? String(kind.prefix(maxUnknown - 1)) + "…" : kind
    }
}
