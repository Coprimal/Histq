// The parts of GitLab's REST v4 JSON that `GitLabClient` maps into the hosted models (`HostedModels.swift`). Keys are
// snake case (decoded with `convertFromSnakeCase`); dates stay strings and are parsed by `GitLabDate`, so one odd
// date never makes a whole list fail. Only fields that are not deprecated are read: `detailed_merge_status`, not
// `merge_status` or `has_conflicts`; `draft`, not `work_in_progress`; `assignees`, not `assignee`.
import Foundation

/// GitLab's ISO 8601 dates, with or without fractional seconds, in UTC (`Z`) or with an offset (`+03:00`).
enum GitLabDate {
    static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(text, strategy: Date.ISO8601FormatStyle())
    }
}

struct GitLabUser: Decodable {
    var id: Int
    var username: String
    var name: String?
    var avatarUrl: String?
    var webUrl: String?

    /// `reviewerID` is the numeric id, which GitLab's `assignee_ids` and `reviewer_ids` take.
    var hosted: HostedUser {
        HostedUser(
            id: id, login: username, avatarURL: avatarUrl, htmlURL: webUrl, name: name, reviewerID: String(id))
    }
}

/// A project member (`GET /projects/:id/members/all`): only what the role badge needs.
struct GitLabMember: Decodable {
    var id: Int
    var accessLevel: Int
}

struct GitLabNamespace: Decodable {
    var id: Int
    var fullPath: String
    var avatarUrl: String?
    var webUrl: String?
}

/// A project as `GET /projects?simple=true` and `GET /projects/:id` return it.
struct GitLabProject: Decodable {
    var id: Int
    var name: String
    var pathWithNamespace: String
    var httpUrlToRepo: String?
    var defaultBranch: String?
    /// `public`, `internal` or `private`; the simple list may leave it out.
    var visibility: String?
    var namespace: GitLabNamespace?
    var forkedFromProject: Forked?
    /// `merge`, `rebase_merge` or `ff`; and `never`, `always`, `default_on` or `default_off` (a single project only).
    var mergeMethod: String?
    var squashOption: String?

    struct Forked: Decodable { var id: Int }
}

/// A label of an item: its name alone, or the details (`with_labels_details=true`, and `GET /projects/:id/labels`).
struct GitLabLabel: Decodable {
    var name: String
    var color: String?
    var description: String?

    enum CodingKeys: CodingKey { case name, color, description }

    init(from decoder: any Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            self.name = name
            return
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        color = try values.decodeIfPresent(String.self, forKey: .color)
        description = try values.decodeIfPresent(String.self, forKey: .description)
    }

    /// The color as `RRGGBB` (GitLab sends `#RRGGBB`); nil for any other form.
    var hosted: HostedLabel {
        let hex = color.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
        let valid = hex.flatMap { $0.count == 6 && $0.allSatisfy { $0.isASCII && $0.isHexDigit } ? $0 : nil }
        return HostedLabel(name: name, color: valid, description: description)
    }
}

struct GitLabPipeline: Decodable {
    var id: Int
    var status: String
    var ref: String?
    var sha: String?
    var webUrl: String?
    var createdAt: String?
    var startedAt: String?
    var finishedAt: String?
}

struct GitLabMergeRequest: Decodable {
    var id: Int
    var iid: Int
    var title: String
    var description: String?
    /// Only with `render_html=true` (a single merge request).
    var descriptionHtml: String?
    /// `opened`, `closed`, `locked` (being merged) or `merged`.
    var state: String
    var draft: Bool?
    var author: GitLabUser?
    var assignees: [GitLabUser]?
    var reviewers: [GitLabUser]?
    var labels: [GitLabLabel]?
    var webUrl: String
    var sourceBranch: String
    var targetBranch: String
    /// The project of the source branch: another one than `targetProjectId` for a fork's branch.
    var sourceProjectId: Int?
    var targetProjectId: Int?
    var sha: String?
    var diffRefs: DiffRefs?
    var mergedAt: String?
    var createdAt: String?
    var updatedAt: String?
    var detailedMergeStatus: String?
    /// A number as a string, `1000+` past GitLab's limit, or nil.
    var changesCount: String?
    var userNotesCount: Int?
    /// Only a single merge request has it, and only for a user who can see pipelines.
    var headPipeline: GitLabPipeline?
    /// Only a single merge request: with `include_diverged_commits_count=true`, how many commits the source branch
    /// is behind the target; with `include_rebase_in_progress=true`, whether a rebase runs; the token's user's
    /// `can_merge`; the merge's branch deletion (`should_remove_source_branch` once set, else the merge request's own
    /// `force_remove_source_branch`) and squash; the last merge or rebase error.
    var divergedCommitsCount: Int?
    var rebaseInProgress: Bool?
    var user: Rights?
    var shouldRemoveSourceBranch: Bool?
    var forceRemoveSourceBranch: Bool?
    var squashOnMerge: Bool?
    var mergeError: String?
    /// The sidebar's milestone and time tracking (the list and the single merge request).
    var milestone: GitLabMilestone?
    var timeStats: GitLabTimeStats?

    struct Rights: Decodable {
        var canMerge: Bool?
    }

    struct DiffRefs: Decodable {
        var baseSha: String?
        var headSha: String?
        var startSha: String?
    }
}

struct GitLabIssue: Decodable {
    var id: Int
    var iid: Int
    var title: String
    var description: String?
    /// `opened` or `closed`.
    var state: String
    var author: GitLabUser?
    var assignees: [GitLabUser]?
    var labels: [GitLabLabel]?
    var webUrl: String
    var userNotesCount: Int?
    var createdAt: String?
    var updatedAt: String?
    var closedAt: String?
    var milestone: GitLabMilestone?
    var timeStats: GitLabTimeStats?
}

/// A merge request's or issue's `milestone`.
struct GitLabMilestone: Decodable {
    var title: String
    var dueDate: String?

    var hosted: HostedMilestone { HostedMilestone(title: title, dueDate: dueDate) }
}

/// A merge request's or issue's `time_stats`: seconds, and GitLab's words for them (nil when not set).
struct GitLabTimeStats: Decodable {
    var timeEstimate: Int?
    var totalTimeSpent: Int?
    var humanTimeEstimate: String?
    var humanTotalTimeSpent: String?

    var hosted: HostedTimeStats {
        HostedTimeStats(estimate: timeEstimate ?? 0, spent: totalTimeSpent ?? 0, humanEstimate: humanTimeEstimate,
                        humanSpent: humanTotalTimeSpent)
    }
}

/// A note (a comment), from `/notes` or inside a discussion. `type` is `DiffNote` for a comment on a diff line,
/// `DiscussionNote` in a thread, and nil for a plain comment.
struct GitLabNote: Decodable {
    var id: Int
    var type: String?
    var body: String?
    var author: GitLabUser?
    var createdAt: String?
    var system: Bool?
    var resolvable: Bool?
    var resolved: Bool?
    /// Only a merge request's notes: who resolved the note's thread, and when.
    var resolvedBy: GitLabUser?
    var resolvedAt: String?
    var position: Position?

    /// Where a diff note sits: an added line has only `newLine`, a removed one only `oldLine`, an unchanged one
    /// both. `headSha` is the head of the diff it sits on.
    struct Position: Decodable {
        var headSha: String?
        var oldPath: String?
        var newPath: String?
        var oldLine: Int?
        var newLine: Int?
        var lineRange: LineRange?
    }

    struct LineRange: Decodable {
        var start: Point?
        var end: Point?
    }

    struct Point: Decodable {
        var oldLine: Int?
        var newLine: Int?
    }

    var isDiffNote: Bool { type == "DiffNote" || position != nil }
}

/// A thread: `id` is a hex string, which replying and resolving take.
struct GitLabDiscussion: Decodable {
    var id: String
    var notes: [GitLabNote]
}

/// What GitLab's GraphQL adds to a note that REST lacks: the token's user's rights (`adminNote`, which covers editing
/// and deleting; `resolveNote`) and the note's awards, each with its emoji name and the user's numeric id (the
/// trailing number of the user's global id).
struct GitLabNoteState {
    var canAdmin: Bool
    var canResolve: Bool?
    var awards: [(name: String, userID: Int?)]
    /// A system note's kind (`systemNoteMetadata.action`) and icon name (`systemNoteIconName`); nil when GitLab gives
    /// none.
    var systemAction: String? = nil
    var systemIcon: String? = nil
}

/// A discussion's resolver and when (GraphQL `resolvedBy`, `resolvedAt`), which issues have only there.
struct GitLabResolution {
    var user: HostedUser?
    var at: Date?
}

/// A resource event of a merge request or an issue (`resource_state_events`, `resource_label_events`,
/// `resource_milestone_events`): who and when, and the event's own fields (`state`; `label` or `milestone` with
/// `action` `add`/`remove`). A deleted label or milestone is null.
struct GitLabResourceEvent: Decodable {
    var id: Int
    var user: GitLabUser?
    var createdAt: String?
    var state: String?
    var action: String?
    var label: GitLabLabel?
    var milestone: Milestone?
    var sourceCommit: String?
    var sourceMergeRequest: Reference?

    struct Milestone: Decodable { var title: String }
    struct Reference: Decodable { var iid: Int? }
}

/// One load of an item's discussions: the REST threads, the GraphQL note states by REST note id, each
/// discussion's `resolved` by REST discussion id and the item's own awards (all three nil when the GraphQL read
/// failed), and the token's user's id (nil when unknown).
struct GitLabThreads {
    var discussions: [GitLabDiscussion]
    var noteStates: [Int: GitLabNoteState]?
    var discussionResolved: [String: Bool]?
    /// Each resolved discussion's resolver, by REST discussion id (nil when the GraphQL read failed).
    var discussionResolution: [String: GitLabResolution]? = nil
    var itemAwards: [(name: String, userID: Int?)]?
    var viewerID: Int?
}

struct GitLabCommit: Decodable {
    var id: String
    var message: String?
    var title: String?
    var authorName: String?
    var authorEmail: String?
    var authoredDate: String?
    var webUrl: String?
}

/// A file of `GET .../merge_requests/:iid/diffs`: `diff` is the file's hunks without a header, empty for a binary
/// file, and left out (`collapsed`, `tooLarge`) past GitLab's diff limits.
struct GitLabDiff: Decodable {
    var oldPath: String
    var newPath: String
    var diff: String?
    var newFile: Bool?
    var renamedFile: Bool?
    var deletedFile: Bool?
    var tooLarge: Bool?
    var collapsed: Bool?
}

/// `GET .../approvals`: on every tier `approved_by` lists the users who approved, and `user_can_approve` and
/// `user_has_approved` say what the token's user may do; `approvals_required` and `approvals_left` only on Enterprise
/// Edition (GitLab.com included).
struct GitLabApprovals: Decodable {
    var approvedBy: [Approver]?
    var approvalsRequired: Int?
    var approvalsLeft: Int?
    var userCanApprove: Bool?
    var userHasApproved: Bool?

    struct Approver: Decodable {
        var user: GitLabUser
        var approvedAt: String?
    }
}

/// `GET .../reviewers`: `state` is `unreviewed`, `review_started`, `reviewed`, `requested_changes`, `approved` or
/// `unapproved`.
struct GitLabReviewer: Decodable {
    var user: GitLabUser
    var state: String?
    var createdAt: String?
}

/// A commit status: a CI job of the commit's pipelines or a status an outside service posted.
struct GitLabCommitStatus: Decodable {
    var id: Int
    var name: String
    var status: String
    var allowFailure: Bool?
    var targetUrl: String?
    var startedAt: String?
    var finishedAt: String?
}
