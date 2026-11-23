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
    /// Not part of the JSON (GitHub's `reactions` rollup is another shape): the host's mapping sets these.
    public var viewerCanEdit = false
    public var viewerCanDelete = false
    public var reactions: [HostedReaction] = []
    /// A resolved root's resolver and when, where the host says (GitLab); not part of the JSON.
    public var resolvedBy: HostedUser? = nil
    public var resolvedAt: Date? = nil

    enum CodingKeys: String, CodingKey {
        case id, user, body
        case hostKey = "node_id"
        case bodyHTML = "body_html"
        case htmlURL = "html_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
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

    public init(
        id: String, actor: HostedUser?, createdAt: Date?, text: String, textHTML: String? = nil,
        action: String? = nil, icon: String? = nil
    ) {
        self.id = id
        self.actor = actor
        self.createdAt = createdAt
        self.text = text
        self.textHTML = textHTML
        self.action = action
        self.icon = icon
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

    enum CodingKeys: String, CodingKey {
        case id, user, state, body
        case bodyHTML = "body_html"
        case htmlURL = "html_url"
        case submittedAt = "submitted_at"
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
    /// As in `HostedComment`: not part of the JSON, the host's mapping sets these.
    public var viewerCanEdit = false
    public var viewerCanDelete = false
    public var reactions: [HostedReaction] = []
    /// As in `HostedComment`: a resolved thread's resolver and when, on its root (GitLab).
    public var resolvedBy: HostedUser? = nil
    public var resolvedAt: Date? = nil

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

    public init(
        id: String, isResolved: Bool, isOutdated: Bool, viewerCanResolve: Bool, viewerCanUnresolve: Bool,
        rootCommentID: Int? = nil
    ) {
        self.id = id
        self.isResolved = isResolved
        self.isOutdated = isOutdated
        self.viewerCanResolve = viewerCanResolve
        self.viewerCanUnresolve = viewerCanUnresolve
        self.rootCommentID = rootCommentID
    }
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
