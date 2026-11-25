// The parts of GitHub's REST v3 JSON that Histq shows. Requests ask for `application/vnd.github.full+json`, so
// bodies come as markdown (`body`) and as GitHub's sanitized HTML (`body_html`). States stay strings: GitHub adds
// values over time, and an unknown one must not make a whole list fail to decode. Dates are ISO 8601.
import Foundation

public struct HostedUser: Codable, Sendable, Equatable {
    public var id: Int
    public var login: String
    public var avatarURL: String?
    public var htmlURL: String?
    /// Only `GET /user` and single-user requests have it.
    public var name: String?
    /// What requesting a review from this user or assigning them sends, when a host takes something else than the
    /// login; nil means the login (GitHub). Not part of the JSON: the host's mapping sets it.
    public var reviewerID: String?

    public init(
        id: Int, login: String, avatarURL: String? = nil, htmlURL: String? = nil, name: String? = nil,
        reviewerID: String? = nil
    ) {
        self.id = id
        self.login = login
        self.avatarURL = avatarURL
        self.htmlURL = htmlURL
        self.name = name
        self.reviewerID = reviewerID
    }

    enum CodingKeys: String, CodingKey {
        case id, login, name
        case avatarURL = "avatar_url"
        case htmlURL = "html_url"
    }
}

/// A repository as `GET /repos/<owner>/<name>` returns it: only what a new pull request needs.
public struct HostedRepositoryInfo: Codable, Sendable, Equatable {
    public var fullName: String?
    public var defaultBranch: String
    /// Not part of GitHub's JSON: where a host says it (GitLab's project `merge_method`), whether a merge adds a merge
    /// commit (`merge`, `rebase_merge`) or not (`ff`); nil when unknown.
    public var mergeCommit: Bool? = nil
    /// Not part of GitHub's JSON: the project's squash rule where a host has one (GitLab's `squash_option`).
    public var squashOption: HostedSquashOption? = nil

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case defaultBranch = "default_branch"
    }
}

/// Whether a merge squashes, as a project rules it (GitLab's `squash_option`): never, always, or the user's choice
/// starting checked (`defaultOn`) or not (`defaultOff`).
public enum HostedSquashOption: String, Sendable, Equatable {
    case never, always
    case defaultOn = "default_on"
    case defaultOff = "default_off"
}

/// What a host's approval box shows (GitLab's `GET .../approvals`): `required` nil or 0 means approval is optional
/// (GitLab Community Edition sends no `approvals_required`); `left` how many are still missing; who approved; and
/// whether the token's user may approve and already has (nil when the host does not say).
public struct HostedApprovals: Sendable, Equatable {
    public var required: Int?
    public var left: Int?
    public var approvedBy: [HostedUser]
    public var viewerCanApprove: Bool?
    public var viewerHasApproved: Bool?

    public init(
        required: Int? = nil, left: Int? = nil, approvedBy: [HostedUser] = [], viewerCanApprove: Bool? = nil,
        viewerHasApproved: Bool? = nil
    ) {
        self.required = required
        self.left = left
        self.approvedBy = approvedBy
        self.viewerCanApprove = viewerCanApprove
        self.viewerHasApproved = viewerHasApproved
    }

    /// No approval is required.
    public var isOptional: Bool { (required ?? 0) <= 0 }
}

/// What a host's merge box shows beyond `mergeable`/`mergeableState`, from the single pull request where the host
/// gives it (GitLab's merge request): `status` is the host's own word for why it merges or not (GitLab's
/// `detailed_merge_status`, kept as sent: the app words the known values and treats any other as blocked);
/// `commitsBehind` how far the source branch is behind the target; whether the token's user may merge; whether the
/// merge deletes the source branch as it stands (`deletesSourceBranch`) and squashes (`squashOnMerge`); the last merge
/// or rebase error; and whether a rebase runs now.
public struct HostedMergeDetails: Sendable, Equatable {
    public var status: String?
    public var commitsBehind: Int?
    public var viewerCanMerge: Bool?
    public var deletesSourceBranch: Bool?
    public var squashOnMerge: Bool?
    public var mergeError: String?
    public var rebaseInProgress: Bool

    public init(
        status: String? = nil, commitsBehind: Int? = nil, viewerCanMerge: Bool? = nil,
        deletesSourceBranch: Bool? = nil, squashOnMerge: Bool? = nil, mergeError: String? = nil,
        rebaseInProgress: Bool = false
    ) {
        self.status = status
        self.commitsBehind = commitsBehind
        self.viewerCanMerge = viewerCanMerge
        self.deletesSourceBranch = deletesSourceBranch
        self.squashOnMerge = squashOnMerge
        self.mergeError = mergeError
        self.rebaseInProgress = rebaseInProgress
    }
}

/// A repository as `GET /user/repos` lists it: what the Welcome page's clone picker needs.
public struct HostedCloneRepository: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    /// `owner/name`.
    public var fullName: String
    public var owner: HostedUser
    /// The https URL `git clone` takes.
    public var cloneURL: String
    public var isPrivate: Bool
    public var fork: Bool?

    public init(
        id: Int, name: String, fullName: String, owner: HostedUser, cloneURL: String, isPrivate: Bool,
        fork: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.fullName = fullName
        self.owner = owner
        self.cloneURL = cloneURL
        self.isPrivate = isPrivate
        self.fork = fork
    }

    enum CodingKeys: String, CodingKey {
        case id, name, owner, fork
        case fullName = "full_name"
        case cloneURL = "clone_url"
        case isPrivate = "private"
    }
}

public struct HostedLabel: Codable, Sendable, Equatable {
    public var name: String
    /// `RRGGBB` without `#`.
    public var color: String?
    public var description: String?
}

/// A pull request's or issue's milestone where the host has milestones (GitLab's `milestone`): its title, and its
/// due date as the host wrote it (`YYYY-MM-DD`).
public struct HostedMilestone: Sendable, Equatable {
    public var title: String
    public var dueDate: String?

    public init(title: String, dueDate: String? = nil) {
        self.title = title
        self.dueDate = dueDate
    }
}

/// A pull request's or issue's time tracking where the host has it (GitLab's `time_stats`): the estimate and the time
/// spent in seconds, and the host's own words for them ("1h 30m"), nil when not set.
public struct HostedTimeStats: Sendable, Equatable {
    public var estimate: Int
    public var spent: Int
    public var humanEstimate: String?
    public var humanSpent: String?

    public init(estimate: Int = 0, spent: Int = 0, humanEstimate: String? = nil, humanSpent: String? = nil) {
        self.estimate = estimate
        self.spent = spent
        self.humanEstimate = humanEstimate
        self.humanSpent = humanSpent
    }

    /// Neither an estimate nor time spent (GitLab's "No estimate or time spent").
    public var isEmpty: Bool { estimate <= 0 && spent <= 0 }
}

/// One end of a pull request: the branch and the commit it points at.
public struct HostedBranchRef: Codable, Sendable, Equatable {
    /// `owner:branch`.
    public var label: String?
    public var ref: String
    public var sha: String
}

public struct HostedPullRequest: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var number: Int
    public var title: String
    /// `open` or `closed` (a merged pull request is `closed` with `mergedAt` set).
    public var state: String
    public var draft: Bool?
    public var user: HostedUser?
    public var body: String?
    public var bodyHTML: String?
    public var htmlURL: String
    public var head: HostedBranchRef
    public var base: HostedBranchRef
    public var labels: [HostedLabel]?
    public var assignees: [HostedUser]?
    public var requestedReviewers: [HostedUser]?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var mergedAt: Date?
    /// Only a single pull request (`GET .../pulls/<n>`) has these.
    public var merged: Bool?
    public var mergeable: Bool?
    /// Why it merges or not: `clean`, `unstable` (failing checks that are not required), `has_hooks`, `blocked`
    /// (required reviews or checks), `behind` (out of date with the base), `dirty` (conflicts), `draft`, or `unknown`
    /// while GitHub still computes it. The app tells apart only `dirty`, `blocked` and `behind`, which other hosts map
    /// into; any other value or nil is no obstacle, and the branch shows as mergeable only with `mergeable` true. A
    /// draft is read from `draft`, not from here.
    public var mergeableState: String?
    public var commits: Int?
    public var additions: Int?
    public var deletions: Int?
    public var changedFiles: Int?
    /// The reactions on the pull request itself (not on its comments), where the host has `itemReactions`: not part of
    /// the JSON (GitHub's `reactions` rollup is another shape); the app sets it from `itemReactions(of:in:)`.
    public var reactions: [HostedReaction] = []
    /// The merge box's details where the host gives them (GitLab); not part of the JSON: the host's mapping sets it.
    public var mergeDetails: HostedMergeDetails? = nil
    /// The sidebar's milestone and time tracking where the host gives them (GitLab); not part of the JSON: the host's
    /// mapping sets them.
    public var milestone: HostedMilestone? = nil
    public var timeStats: HostedTimeStats? = nil
    /// The merged box's "<mergedBy> merged commit <mergeCommitSHA>", and whether the token's user may push to the
    /// base repository (Delete branch), where the host gives them (GitHub); not part of the JSON: the host's mapping
    /// sets them.
    public var mergedBy: HostedUser? = nil
    public var mergeCommitSHA: String? = nil
    public var viewerCanPush: Bool? = nil
    /// The merge methods this pull request may use and the one it starts at, where the host sets them per pull
    /// request (Bitbucket: the destination branch's strategies); nil falls back to the client's `mergeMethods`. Not
    /// part of the JSON: the host's mapping sets them.
    public var allowedMergeMethods: [HostedMergeMethod]? = nil
    public var defaultMergeMethod: HostedMergeMethod? = nil
    /// Whether merging closes (deletes) the source branch, as the pull request was created (Bitbucket's
    /// `close_source_branch`); nil where the host has no such setting. Not part of the JSON.
    public var closesSourceBranch: Bool? = nil
    /// How many of its tasks are open (Bitbucket's `task_count`); nil where the host has none. Not part of the JSON.
    public var openTaskCount: Int? = nil
    /// Whether the token's user may edit the description (`editDescription`), where the host's mapping knows it; nil
    /// leaves it to the author (the app compares the viewer with `user`). Not part of the JSON.
    public var viewerCanEditDescription: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id, number, title, state, draft, user, body, head, base, labels, assignees, merged, mergeable
        case commits, additions, deletions
        case bodyHTML = "body_html"
        case htmlURL = "html_url"
        case requestedReviewers = "requested_reviewers"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case mergedAt = "merged_at"
        case mergeableState = "mergeable_state"
        case changedFiles = "changed_files"
    }
}

public struct HostedIssue: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var number: Int
    public var title: String
    /// `open` or `closed`.
    public var state: String
    public var user: HostedUser?
    public var body: String?
    public var bodyHTML: String?
    public var htmlURL: String
    public var labels: [HostedLabel]?
    public var assignees: [HostedUser]?
    /// The number of comments.
    public var comments: Int?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var closedAt: Date?
    /// Set when this "issue" is a pull request (GitHub's issue lists include them).
    public var pullRequest: PullRequestLink?
    /// Only a pull request's search result has it (`GET /search/issues`).
    public var draft: Bool?
    /// The reactions on the issue itself, as `HostedPullRequest.reactions`.
    public var reactions: [HostedReaction] = []
    /// The sidebar's milestone and time tracking, as `HostedPullRequest.milestone` and `timeStats`.
    public var milestone: HostedMilestone? = nil
    public var timeStats: HostedTimeStats? = nil
    /// As `HostedPullRequest.viewerCanEditDescription`.
    public var viewerCanEditDescription: Bool? = nil

    public struct PullRequestLink: Codable, Sendable, Equatable {
        public var url: String?
    }

    public var isPullRequest: Bool { pullRequest != nil }

    enum CodingKeys: String, CodingKey {
        case id, number, title, state, user, body, labels, assignees, comments, draft
        case bodyHTML = "body_html"
        case htmlURL = "html_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case closedAt = "closed_at"
        case pullRequest = "pull_request"
    }
}

/// One reaction kind on a comment: `kind` is the host's own name (GitHub's `content`, GitLab's emoji name), so a
/// host may show kinds beyond its `reactionKinds`.
public struct HostedReaction: Sendable, Hashable {
    public var kind: String
    public var count: Int
    /// Whether the token's user is one of the `count`.
    public var viewerReacted: Bool

    public init(kind: String, count: Int, viewerReacted: Bool = false) {
        self.kind = kind
        self.count = count
        self.viewerReacted = viewerReacted
    }
}

/// A conversation comment of an issue or a pull request. Its `id` follows the id rule of `HostedReview`. `body` is
/// the host's raw markdown on every host (what Edit starts from); `bodyHTML` is only for showing it.
public struct HostedComment: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var user: HostedUser?
    public var body: String?
    public var bodyHTML: String?
    public var htmlURL: String?
    public var createdAt: Date?
    public var updatedAt: Date?
    /// The comment this one answers directly (a reply to a reply keeps its own parent); nil for a root.
    public var parentID: Int?
    /// A root's thread state where the host has one: nil when it cannot be resolved.
    public var resolvable: Bool?
    public var resolved: Bool?
    /// The host's own key that writes on the comment take, where its id is not enough: GitLab's discussion id,
    /// Bitbucket Data Center's comment version, Azure DevOps' thread id, GitHub's `node_id` (JSON `node_id`).
    public var hostKey: String?
    /// The author's relation to the repository where the host gives it (GitHub's `author_association`: `OWNER`,
    /// `MEMBER`, `COLLABORATOR`, `CONTRIBUTOR`, `FIRST_TIME_CONTRIBUTOR`, `FIRST_TIMER`, `NONE`…), for the comment's
    /// badge; nil elsewhere.
    public var authorAssociation: String?
    /// Not part of the JSON (GitHub's `reactions` rollup is another shape): the host's mapping sets these.
    public var viewerCanEdit = false
    public var viewerCanDelete = false
    public var reactions: [HostedReaction] = []
    /// A resolved root's resolver and when, where the host says (GitLab); not part of the JSON.
    public var resolvedBy: HostedUser? = nil
    public var resolvedAt: Date? = nil
    /// A root's thread status in the host's own words, where it has more than resolved or not (Azure DevOps' `active`,
    /// `pending`, `fixed`, `wontFix`, `closed`, `byDesign`); nil elsewhere. Not part of the JSON.
    public var threadStatus: String? = nil
    /// Hidden (minimized) on the host for everyone, and why in the host's words (GitHub's `minimizedReason`:
    /// `outdated`, `off-topic`, `low-quality`…), and whether the token's user may hide or unhide it; false and nil
    /// elsewhere. Not part of the JSON (GitHub's GraphQL read sets them).
    public var isMinimized = false
    public var minimizedReason: String? = nil
    public var viewerCanMinimize = false
    public var viewerCanUnminimize = false

    enum CodingKeys: String, CodingKey {
        case id, user, body
        case hostKey = "node_id"
        case bodyHTML = "body_html"
        case htmlURL = "html_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case authorAssociation = "author_association"
    }
}

/// A history entry of a pull request's or an issue's timeline that is not a comment: a host's system note ("added 2
/// commits", "resolved all threads") or a state, label or milestone change. Its shape is open, so a host adds kinds
/// without a change here or in the app: `text` is the wording (a system note's Markdown body as the host sent it, or
/// Histq's plain words built from an event's fields), `textHTML` its HTML (the note through `MarkdownHTML`, Histq's
/// words escaped), `action` the host's own
/// kind (GitLab's `systemNoteMetadata.action`, or `state`, `label`, `milestone` for a resource event) and `icon` its
/// icon name (GitLab's `systemNoteIconName`), both nil when unknown. Never a comment: no reply, edit or reaction.
/// `id` is unique within its item (`note-<id>`, `state-<id>`…).
public struct HostedTimelineEvent: Sendable, Equatable, Identifiable {
    public var id: String
    public var actor: HostedUser?
    public var createdAt: Date?
    public var text: String
    public var textHTML: String?
    public var action: String?
    public var icon: String?
    /// Sanitized HTML under the entry's line (Bitbucket's task text or the reviewers added), or nil.
    public var detailHTML: String?

    public init(
        id: String, actor: HostedUser?, createdAt: Date?, text: String, textHTML: String? = nil,
        action: String? = nil, icon: String? = nil, detailHTML: String? = nil
    ) {
        self.id = id
        self.actor = actor
        self.createdAt = createdAt
        self.text = text
        self.textHTML = textHTML
        self.action = action
        self.icon = icon
        self.detailHTML = detailHTML
    }
}

/// A submitted (or pending) review of a pull request.
///
/// The id rule, for this, `HostedCheckRun`, `HostedComment` and `HostedReviewComment`: every value a host maps has an
/// `id` unique within its pull request, since views key on it (`ForEach(runs)`). A host without stable numeric ids
/// uses a synthetic `Int` from a stable key (a 63-bit FNV-1a hash of the kind and the key, a collision resolved by
/// probing), and each host's mapping test asserts that the ids are unique.
public struct HostedReview: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var user: HostedUser?
    /// `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, `DISMISSED` or `PENDING`: the app tells all five apart, and other
    /// hosts map into them.
    public var state: String
    public var body: String?
    public var bodyHTML: String?
    public var htmlURL: String?
    public var submittedAt: Date?
    /// As in `HostedComment`.
    public var authorAssociation: String?
    /// The reviewer's own vote where the host has more than the state (Azure DevOps' 10 approved, 5 approved with
    /// suggestions, 0 no vote, -5 waiting for the author, -10 rejected), and whether they must review; nil elsewhere.
    /// Not part of the JSON.
    public var vote: Int? = nil
    public var isRequired: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id, user, state, body
        case bodyHTML = "body_html"
        case htmlURL = "html_url"
        case submittedAt = "submitted_at"
        case authorAssociation = "author_association"
    }
}

/// An inline comment of a pull request review, on a file and a line (`GET .../pulls/<n>/comments`). A reply has
/// `inReplyToID` set to its thread's root comment; the root's `pullRequestReviewID` is the review the thread
/// belongs to. Only `id` and `path` are required: GitHub may leave out or null the rest, and one missing field
/// must not make every thread of the pull request fail to decode. Its `id` follows the id rule of `HostedReview`.
public struct HostedReviewComment: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var pullRequestReviewID: Int?
    /// The root comment of the thread this reply belongs to; nil for a root comment.
    public var inReplyToID: Int?
    public var path: String
    /// The line in the current diff, or the last line of a multi-line comment. It may be nil (an outdated comment),
    /// where `originalLine`, the line in the diff the comment was written on, takes over.
    public var line: Int?
    public var originalLine: Int?
    /// The first line of a multi-line comment; nil for a single line.
    public var startLine: Int?
    public var originalStartLine: Int?
    /// `LEFT` (the old file) or `RIGHT` (the new file).
    public var side: String?
    /// The diff hunk the comment was written on, ending at the commented line.
    public var diffHunk: String?
    /// The host's raw markdown, what Edit starts from.
    public var body: String?
    public var bodyHTML: String?
    public var user: HostedUser?
    public var createdAt: Date?
    public var htmlURL: String?
    /// As in `HostedComment`: the host's own key for writes (GitHub's `node_id`).
    public var hostKey: String?
    /// As in `HostedComment`.
    public var authorAssociation: String?
    /// As in `HostedComment`: not part of the JSON, the host's mapping sets these.
    public var viewerCanEdit = false
    public var viewerCanDelete = false
    public var reactions: [HostedReaction] = []
    /// As in `HostedComment`: a resolved thread's resolver and when, on its root (GitLab).
    public var resolvedBy: HostedUser? = nil
    public var resolvedAt: Date? = nil
    /// A comment of the token's user's pending review (`HostedPendingReview`), not published yet: its `id` is in
    /// `HostedPendingReview.idBase`'s band. Not part of the JSON.
    public var isPending = false
    /// Whether the token's user may react to it, where the host says (GitHub's `viewerCanReact` on a pending comment;
    /// false on GitLab's draft notes, which have no award emoji); nil: the host's reactions rule alone (any published
    /// comment). Not part of the JSON.
    public var viewerCanReact: Bool? = nil
    /// The suggested changes of the comment's body as the host knows them (GitLab's), in the body's order; empty
    /// elsewhere. Not part of the JSON.
    public var suggestions: [HostedSuggestion] = []
    /// As in `HostedComment`: hidden on the host, why, and the token's user's rights; not part of the JSON.
    public var isMinimized = false
    public var minimizedReason: String? = nil
    public var viewerCanMinimize = false
    public var viewerCanUnminimize = false

    enum CodingKeys: String, CodingKey {
        case id, path, line, side, body, user
        case hostKey = "node_id"
        case pullRequestReviewID = "pull_request_review_id"
        case inReplyToID = "in_reply_to_id"
        case originalLine = "original_line"
        case startLine = "start_line"
        case originalStartLine = "original_start_line"
        case diffHunk = "diff_hunk"
        case bodyHTML = "body_html"
        case createdAt = "created_at"
        case htmlURL = "html_url"
        case authorAssociation = "author_association"
    }
}

/// A suggested change in a diff comment, as GitLab's discussions list it (`notes[].suggestions[]`): the new-side lines
/// `fromLine...toLine` it replaces, their text then (`fromContent`) and its replacement (`toContent`), whether the
/// token's user may apply it now (`appliable`) and whether it was applied.
public struct HostedSuggestion: Sendable, Equatable {
    public var id: Int
    public var fromLine: Int?
    public var toLine: Int?
    public var appliable: Bool
    public var applied: Bool
    public var fromContent: String?
    public var toContent: String?

    public init(
        id: Int, fromLine: Int? = nil, toLine: Int? = nil, appliable: Bool, applied: Bool, fromContent: String? = nil,
        toContent: String? = nil
    ) {
        self.id = id
        self.fromLine = fromLine
        self.toLine = toLine
        self.appliable = appliable
        self.applied = applied
        self.fromContent = fromContent
        self.toContent = toContent
    }
}

/// The state of a pull request's review thread, from GitHub's GraphQL API: REST has a thread's comments but not
/// whether it is resolved. `rootCommentID` joins it to the thread's root `HostedReviewComment`.
public struct HostedReviewThreadState: Sendable, Equatable, Identifiable {
    /// The thread's GraphQL node id, which resolving and unresolving take.
    public var id: String
    public var isResolved: Bool
    /// The diff changed under the thread since it was written.
    public var isOutdated: Bool
    /// Whether the token's user may resolve or unresolve it (GitHub allows it to writers and the author).
    public var viewerCanResolve: Bool
    public var viewerCanUnresolve: Bool
    /// The REST `id` of the thread's first comment (GraphQL's `fullDatabaseId`, else `databaseId`); nil when GitHub
    /// leaves both out.
    public var rootCommentID: Int?
    /// As `HostedComment.threadStatus`: the host's own status next to `isResolved` (Azure DevOps); nil elsewhere.
    public var status: String?

    public init(
        id: String, isResolved: Bool, isOutdated: Bool, viewerCanResolve: Bool, viewerCanUnresolve: Bool,
        rootCommentID: Int? = nil, status: String? = nil
    ) {
        self.id = id
        self.isResolved = isResolved
        self.isOutdated = isOutdated
        self.viewerCanResolve = viewerCanResolve
        self.viewerCanUnresolve = viewerCanUnresolve
        self.rootCommentID = rootCommentID
        self.status = status
    }
}

/// The token's user's pending review of a pull request (`HostingProvider.pendingReview(of:in:)`): comments only they
/// see until they submit it. Empty (`isEmpty`) when there is none.
public struct HostedPendingReview: Sendable, Equatable {
    /// The review's own key (GitHub's `PullRequestReview` node id); nil when there is none, and on hosts whose drafts
    /// belong to no review (GitLab's draft notes).
    public var hostKey: String?
    /// The review's REST id (GitHub's), so a published list that also returns its comments leaves them out.
    public var reviewID: Int?
    /// The pull request's own key a new review is made on (GitHub's node id); nil when unknown.
    public var pullRequestKey: String?
    /// Its comments on diff lines and replies to threads, each `isPending`, ids in the `idBase` band.
    public var comments: [HostedReviewComment]

    public init(
        hostKey: String? = nil, reviewID: Int? = nil, pullRequestKey: String? = nil,
        comments: [HostedReviewComment] = []
    ) {
        self.hostKey = hostKey
        self.reviewID = reviewID
        self.pullRequestKey = pullRequestKey
        self.comments = comments
    }

    /// No review and no comment: nothing is pending.
    public var isEmpty: Bool { hostKey == nil && comments.isEmpty }

    /// The first id of the pending comments' band: digits only (the app's slot ids take them as they are), below the
    /// app's optimistic ids (`1 << 62`) and above any id a host gives a comment, so a draft's id never meets a note's.
    public static let idBase = 1 << 61

    /// The id of the pending comment the host numbers `hostID`.
    public static func id(_ hostID: Int) -> Int { idBase + (hostID & (idBase - 1)) }

    /// Whether `id` is a pending comment's (`id(_:)`'s band, `idBase` up to the app's optimistic ids).
    public static func isPending(_ id: Int) -> Bool { id >= idBase && id < idBase << 1 }

    /// The host's own number of the pending comment `id` (a GitLab draft note's id), nil for an id outside the band:
    /// a published comment's id never goes to a pending comment's endpoint, nor a draft's to a published one's.
    public static func hostID(of id: Int) -> Int? { isPending(id) ? id - idBase : nil }

    /// `published` (the host's review comments) without any comment of this review (a host that lists them there too),
    /// then this review's comments, a reply the host names by its thread's key only (no `path`, no `inReplyToID`; the
    /// key in `hostKey`, GitLab's `discussion_id`) joined to that thread's root, whose path it takes. A reply whose thread is not in `published` is left out: it has no line
    /// to show on.
    public func merged(into published: [HostedReviewComment]) -> [HostedReviewComment] {
        let pendingIDs = Set(comments.map { $0.id - Self.idBase })
        let kept = published.filter { comment in
            !pendingIDs.contains(comment.id) && (reviewID == nil || comment.pullRequestReviewID != reviewID)
        }
        let roots = Dictionary(
            kept.compactMap { comment in
                comment.inReplyToID == nil ? comment.hostKey.map { ($0, comment) } : nil
            },
            uniquingKeysWith: { first, _ in first })
        let joined = comments.compactMap { comment -> HostedReviewComment? in
            guard comment.inReplyToID == nil, comment.path.isEmpty else { return comment }
            guard let key = comment.hostKey, let root = roots[key] else { return nil }
            var reply = comment
            reply.inReplyToID = root.id
            reply.path = root.path
            return reply
        }
        return kept + joined
    }
}

/// Where a pending comment goes: a diff line (a new thread) or a reply to a thread, `HostedThreadRef.hostKey` the
/// thread's own key (GitHub's thread node id, GitLab's discussion id).
public enum HostedPendingTarget: Sendable, Hashable {
    case line(HostedInlinePosition)
    case reply(HostedThreadRef)
}

/// A commit of a pull request (`GET .../pulls/<n>/commits`).
public struct HostedCommit: Codable, Sendable, Equatable, Identifiable {
    public var sha: String
    public var htmlURL: String?
    public var commit: Details
    /// The GitHub account of the commit's author; nil when its email belongs to no account.
    public var author: HostedUser?

    public var id: String { sha }

    public struct Details: Codable, Sendable, Equatable {
        public var message: String
        public var author: Signature?
    }

    public struct Signature: Codable, Sendable, Equatable {
        public var name: String?
        public var email: String?
        public var date: Date?
    }

    enum CodingKeys: String, CodingKey {
        case sha, commit, author
        case htmlURL = "html_url"
    }
}

/// A file a pull request changes (`GET .../pulls/<n>/files`). `patch` is GitHub's unified diff of the file without
/// its header, only the `@@` hunks; GitHub leaves it out for a binary file and for a diff too large to show.
public struct HostedPullRequestFile: Codable, Sendable, Equatable, Identifiable {
    public var filename: String
    /// `added`, `removed`, `modified`, `renamed`, `copied`, `changed` or `unchanged`.
    public var status: String
    public var additions: Int
    public var deletions: Int
    public var patch: String?
    /// A renamed or copied file's old path.
    public var previousFilename: String?

    public var id: String { filename }

    enum CodingKeys: String, CodingKey {
        case filename, status, additions, deletions, patch
        case previousFilename = "previous_filename"
    }

    /// `patch` parsed with git's diff parser, read-only (it has no header lines, so PatchBuilder cannot replay it);
    /// nil without a patch.
    public var diff: FileDiff? {
        guard let patch else { return nil }
        let change: FileDiff.Change = switch status {
        case "added": .added
        case "removed": .deleted
        case "renamed": .renamed
        case "copied": .copied
        default: .modified
        }
        let new = Data(filename.utf8)
        let old = previousFilename.map { Data($0.utf8) } ?? new
        return FileDiff(
            change: change, oldPath: change == .added ? nil : old, newPath: change == .deleted ? nil : new,
            oldMode: nil, newMode: nil, similarity: nil, isBinary: false, isCombined: false,
            hunks: DiffReader.parseHunks(Data(patch.utf8)), headerLines: [])
    }
}

/// A check run on a pull request's head commit. Its `id` follows the id rule of `HostedReview`.
public struct HostedCheckRun: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    /// `queued`, `in_progress` or `completed` (and a few newer waiting states). The app tells apart only `completed`
    /// from the rest, and shows any other value as it is (underscores as spaces), so other hosts map into `queued`,
    /// `in_progress` or `completed`.
    public var status: String
    /// Set once completed: `success`, `failure`, `neutral`, `cancelled`, `skipped`, `timed_out`,
    /// `action_required`, `startup_failure`... The app counts `failure`, `timed_out`, `cancelled`, `action_required`
    /// and `startup_failure` as failed and `success` as passed; any other value is neutral and shown as it is. Other
    /// hosts map into these.
    public var conclusion: String?
    public var htmlURL: String?
    public var startedAt: Date?
    public var completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion
        case htmlURL = "html_url"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}

/// What GitHub's issue page shows beside the issue's JSON (`HostingProvider.issueExtras`): the pinned comment, the
/// issue type, the custom fields, the projects and the relationships.
public struct HostedIssueExtras: Sendable, Equatable {
    /// The comment pinned on top of the issue: its REST id (`HostedComment.id`), who pinned it and when.
    public struct Pin: Sendable, Equatable {
        public var commentID: Int
        public var pinnedBy: HostedUser?
        public var pinnedAt: Date?

        public init(commentID: Int, pinnedBy: HostedUser? = nil, pinnedAt: Date? = nil) {
            self.commentID = commentID
            self.pinnedBy = pinnedBy
            self.pinnedAt = pinnedAt
        }
    }

    /// A custom field shown on the issue: the repository's pinned ones, then any other with a value; `value` nil
    /// when not set.
    public struct Field: Sendable, Equatable {
        public var name: String
        public var value: String?

        public init(name: String, value: String? = nil) {
            self.name = name
            self.value = value
        }
    }

    public var pin: Pin?
    /// The issue type's name ("Bug"); nil without one.
    public var type: String?
    public var fields: [Field]
    /// The projects' titles; nil when the token may not read them (GitHub's `read:project` scope), `projectCount`
    /// then says how many there are (nil when that could not be read either).
    public var projects: [String]?
    public var projectCount: Int?
    /// The parent issue.
    public var parent: Parent?
    public var subIssues: Int
    public var subIssuesCompleted: Int
    public var blockedBy: Int
    public var blocking: Int
    /// Whether the token's user may edit the issue (its description: `editDescription`); nil when not read.
    public var viewerCanUpdate: Bool? = nil

    public struct Parent: Sendable, Equatable {
        public var number: Int
        public var title: String

        public init(number: Int, title: String) {
            self.number = number
            self.title = title
        }
    }

    public init(
        pin: Pin? = nil, type: String? = nil, fields: [Field] = [], projects: [String]? = [], projectCount: Int? = 0,
        parent: Parent? = nil, subIssues: Int = 0, subIssuesCompleted: Int = 0, blockedBy: Int = 0, blocking: Int = 0
    ) {
        self.pin = pin
        self.type = type
        self.fields = fields
        self.projects = projects
        self.projectCount = projectCount
        self.parent = parent
        self.subIssues = subIssues
        self.subIssuesCompleted = subIssuesCompleted
        self.blockedBy = blockedBy
        self.blocking = blocking
    }
}

/// What GitHub's pull request sidebar shows beside the pull request's JSON (`HostingProvider.pullRequestExtras`): its
/// projects and the issues it closes (Development).
public struct HostedPullRequestExtras: Sendable, Equatable {
    /// An issue the pull request closes when merged, maybe of another repository (`repository` is "owner/name").
    public struct ClosingIssue: Sendable, Hashable {
        public var number: Int
        public var title: String
        public var isOpen: Bool
        public var repository: String
        public var url: String?

        public init(number: Int, title: String, isOpen: Bool, repository: String, url: String? = nil) {
            self.number = number
            self.title = title
            self.isOpen = isOpen
            self.repository = repository
            self.url = url
        }
    }

    /// As `HostedIssueExtras.projects` and `projectCount`.
    public var projects: [String]?
    public var projectCount: Int?
    /// nil when they could not be read (the projects may still have been).
    public var closingIssues: [ClosingIssue]?

    public init(projects: [String]? = [], projectCount: Int? = 0, closingIssues: [ClosingIssue]? = []) {
        self.projects = projects
        self.projectCount = projectCount
        self.closingIssues = closingIssues
    }
}

/// A pull request task (Bitbucket's): its text, whether it is done, who made it, and the comment it hangs on.
public struct HostedTask: Sendable, Equatable, Identifiable {
    public var id: Int
    public var body: String
    public var isResolved: Bool
    public var creator: HostedUser?
    public var createdAt: Date?
    /// The comment it was made on; nil for one of the pull request itself.
    public var commentID: Int?
    /// When and by whom it was last marked done (nil while open).
    public var resolvedAt: Date?
    public var resolvedBy: HostedUser?

    public init(
        id: Int, body: String, isResolved: Bool, creator: HostedUser? = nil, createdAt: Date? = nil,
        commentID: Int? = nil, resolvedAt: Date? = nil, resolvedBy: HostedUser? = nil
    ) {
        self.id = id
        self.body = body
        self.isResolved = isResolved
        self.creator = creator
        self.createdAt = createdAt
        self.commentID = commentID
        self.resolvedAt = resolvedAt
        self.resolvedBy = resolvedBy
    }
}

/// A report on a commit (Bitbucket's Code Insights): its title, `result` (`PASSED`, `FAILED`, `PENDING`, or nil when
/// the reporter gave none), its type (`SECURITY`, `COVERAGE`, `TEST`, `BUG`), who reported it and its page.
public struct HostedReport: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var result: String?
    public var reportType: String?
    public var reporter: String?
    public var link: URL?

    public init(
        id: String, title: String, result: String? = nil, reportType: String? = nil, reporter: String? = nil,
        link: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.result = result
        self.reportType = reportType
        self.reporter = reporter
        self.link = link
    }
}

/// One of a pull request's merge checks (Bitbucket's `mergeability/checks`): what it checks (the host's words, or its
/// type when the host names none), whether it passed (`PASSED`, `FAILED`, `PENDING`, `SKIPPED`, `UNKNOWN`), whether it
/// must pass, and whether it blocks the merge now.
public struct HostedMergeCheck: Sendable, Equatable {
    public var name: String
    public var status: String
    public var required: Bool
    public var blocking: Bool

    public init(name: String, status: String, required: Bool = false, blocking: Bool = false) {
        self.name = name
        self.status = status
        self.required = required
        self.blocking = blocking
    }
}

