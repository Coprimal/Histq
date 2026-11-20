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

/// `GET .../approvals`: on every tier `approved_by` lists the users who approved.
struct GitLabApprovals: Decodable {
    var approvedBy: [Approver]?

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
