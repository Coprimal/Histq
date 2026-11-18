// The parts of GitHub's REST v3 JSON that Histq shows. Requests ask for `application/vnd.github.full+json`, so
// bodies come as markdown (`body`) and as GitHub's sanitized HTML (`body_html`). States stay strings: GitHub adds
// values over time, and an unknown one must not make a whole list fail to decode. Dates are ISO 8601.
import Foundation

public struct GitHubUser: Codable, Sendable, Equatable {
    public var id: Int
    public var login: String
    public var avatarURL: String?
    public var htmlURL: String?
    /// Only `GET /user` and single-user requests have it.
    public var name: String?

    public init(id: Int, login: String, avatarURL: String? = nil, htmlURL: String? = nil, name: String? = nil) {
        self.id = id
        self.login = login
        self.avatarURL = avatarURL
        self.htmlURL = htmlURL
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case id, login, name
        case avatarURL = "avatar_url"
        case htmlURL = "html_url"
    }
}

/// A repository as `GET /repos/<owner>/<name>` returns it: only what a new pull request needs.
public struct GitHubRepositoryInfo: Codable, Sendable, Equatable {
    public var fullName: String?
    public var defaultBranch: String

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case defaultBranch = "default_branch"
    }
}

/// A repository as `GET /user/repos` lists it: what the Welcome page's clone picker needs.
public struct GitHubRepository: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    /// `owner/name`.
    public var fullName: String
    public var owner: GitHubUser
    /// The https URL `git clone` takes.
    public var cloneURL: String
    public var isPrivate: Bool
    public var fork: Bool?

    public init(
        id: Int, name: String, fullName: String, owner: GitHubUser, cloneURL: String, isPrivate: Bool,
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

public struct GitHubLabel: Codable, Sendable, Equatable {
    public var name: String
    /// `RRGGBB` without `#`.
    public var color: String?
    public var description: String?
}

/// One end of a pull request: the branch and the commit it points at.
public struct GitHubBranchRef: Codable, Sendable, Equatable {
    /// `owner:branch`.
    public var label: String?
    public var ref: String
    public var sha: String
}

public struct GitHubPullRequest: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var number: Int
    public var title: String
    /// `open` or `closed` (a merged pull request is `closed` with `mergedAt` set).
    public var state: String
    public var draft: Bool?
    public var user: GitHubUser?
    public var body: String?
    public var bodyHTML: String?
    public var htmlURL: String
    public var head: GitHubBranchRef
    public var base: GitHubBranchRef
    public var labels: [GitHubLabel]?
    public var assignees: [GitHubUser]?
    public var requestedReviewers: [GitHubUser]?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var mergedAt: Date?
    /// Only a single pull request (`GET .../pulls/<n>`) has these.
    public var merged: Bool?
    public var mergeable: Bool?
    /// Why it merges or not: `clean`, `unstable` (failing checks that are not required), `has_hooks`, `blocked`
    /// (required reviews or checks), `behind` (out of date with the base), `dirty` (conflicts), `draft`, or `unknown`
    /// while GitHub still computes it.
    public var mergeableState: String?
    public var commits: Int?
    public var additions: Int?
    public var deletions: Int?
    public var changedFiles: Int?

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

public struct GitHubIssue: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var number: Int
    public var title: String
    /// `open` or `closed`.
    public var state: String
    public var user: GitHubUser?
    public var body: String?
    public var bodyHTML: String?
    public var htmlURL: String
    public var labels: [GitHubLabel]?
    public var assignees: [GitHubUser]?
    /// The number of comments.
    public var comments: Int?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var closedAt: Date?
    /// Set when this "issue" is a pull request (GitHub's issue lists include them).
    public var pullRequest: PullRequestLink?
    /// Only a pull request's search result has it (`GET /search/issues`).
    public var draft: Bool?

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

/// A conversation comment of an issue or a pull request.
public struct GitHubComment: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var user: GitHubUser?
    public var body: String?
    public var bodyHTML: String?
    public var htmlURL: String?
    public var createdAt: Date?
    public var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, user, body
        case bodyHTML = "body_html"
        case htmlURL = "html_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct GitHubReview: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var user: GitHubUser?
    /// `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, `DISMISSED` or `PENDING`.
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
/// must not make every thread of the pull request fail to decode.
public struct GitHubReviewComment: Codable, Sendable, Equatable, Identifiable {
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
    public var body: String?
    public var bodyHTML: String?
    public var user: GitHubUser?
    public var createdAt: Date?
    public var htmlURL: String?

    enum CodingKeys: String, CodingKey {
        case id, path, line, side, body, user
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
/// whether it is resolved. `rootCommentID` joins it to the thread's root `GitHubReviewComment`.
public struct GitHubReviewThreadState: Sendable, Equatable, Identifiable {
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
public struct GitHubCommit: Codable, Sendable, Equatable, Identifiable {
    public var sha: String
    public var htmlURL: String?
    public var commit: Details
    /// The GitHub account of the commit's author; nil when its email belongs to no account.
    public var author: GitHubUser?

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
public struct GitHubPullRequestFile: Codable, Sendable, Equatable, Identifiable {
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

public struct GitHubCheckRun: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    /// `queued`, `in_progress` or `completed` (and a few newer waiting states).
    public var status: String
    /// Set once completed: `success`, `failure`, `neutral`, `cancelled`, `skipped`, `timed_out`,
    /// `action_required`...
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
