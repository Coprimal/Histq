// The parts of Bitbucket Cloud's API 2.0 JSON that `BitbucketCloudClient` maps into the hosted models
// (`HostedModels.swift`). Keys are snake case (decoded with `convertFromSnakeCase`); dates stay strings and are parsed
// by `GitLabDate` (ISO 8601, Bitbucket's with microseconds and an offset), so one odd date never makes a list fail.
// Accounts have no numeric id and no username, only a `uuid` (`{...}`), a `nickname` and a `display_name`.
import Foundation

/// A page of a list: `next` is the full URL of the next page, absent on the last one.
struct BitbucketPage<Item: Decodable>: Decodable {
    var values: [Item]?
    var next: String?
}

struct BitbucketLink: Decodable {
    var href: String?
    var name: String?
}

struct BitbucketLinks: Decodable {
    var html: BitbucketLink?
    var avatar: BitbucketLink?
    /// A repository's clone URLs, named `https` and `ssh`.
    var clone: [BitbucketLink]?
}

struct BitbucketAccount: Decodable {
    var uuid: String?
    var displayName: String?
    var nickname: String?
    var links: BitbucketLinks?

    /// `id` is a hash of the uuid (`BitbucketCloudClient.userID`), `login` the nickname (else the display name),
    /// `reviewerID` the uuid, which reviewers and BBQL filters take.
    var hosted: HostedUser {
        HostedUser(
            id: BitbucketCloudClient.userID(uuid ?? ""), login: nickname ?? displayName ?? uuid ?? "",
            avatarURL: links?.avatar?.href, htmlURL: links?.html?.href, name: displayName, reviewerID: uuid)
    }
}

/// `raw`, Bitbucket's rendered `html`, and the `markup` the raw text is in.
struct BitbucketContent: Decodable {
    var raw: String?
    var html: String?
}

struct BitbucketRepository: Decodable {
    var uuid: String?
    /// `workspace/repo_slug`.
    var fullName: String?
    var name: String?
    var isPrivate: Bool?
    var parent: Parent?
    var mainbranch: Branch?
    var links: BitbucketLinks?

    struct Parent: Decodable { var fullName: String? }
    struct Branch: Decodable { var name: String? }
}

/// `GET /user/workspaces`: one row per workspace the token's user can reach.
struct BitbucketWorkspaceAccess: Decodable {
    var workspace: Workspace?

    struct Workspace: Decodable { var slug: String? }
}

/// `GET /workspaces/{ws}/members`.
struct BitbucketMembership: Decodable {
    var user: BitbucketAccount?
}

struct BitbucketPullRequest: Decodable {
    var id: Int
    var title: String
    /// `OPEN`, `MERGED`, `DECLINED` or `SUPERSEDED`.
    var state: String
    var draft: Bool?
    var author: BitbucketAccount?
    var summary: BitbucketContent?
    var rendered: Rendered?
    var source: Endpoint?
    var destination: Endpoint?
    var reviewers: [BitbucketAccount]?
    /// Only a single pull request has them.
    var participants: [Participant]?
    var commentCount: Int?
    var taskCount: Int?
    var closeSourceBranch: Bool?
    var closedBy: BitbucketAccount?
    var mergeCommit: Endpoint.Commit?
    var createdOn: String?
    var updatedOn: String?
    var links: BitbucketLinks?

    struct Rendered: Decodable { var description: BitbucketContent? }

    /// One end: the branch, its commit (`hash`, often abbreviated to 12 hex digits) and the repository it is in
    /// (another one than the destination's for a fork's branch, none when that fork was deleted).
    struct Endpoint: Decodable {
        var branch: Branch?
        var commit: Commit?
        var repository: BitbucketRepository?

        struct Branch: Decodable {
            var name: String?
            /// The strategies the destination branch allows (`merge_commit`, `squash`, ...), and its default.
            var mergeStrategies: [String]?
            var defaultMergeStrategy: String?
        }

        struct Commit: Decodable { var hash: String? }
    }

    /// `state` is `approved`, `changes_requested` or null.
    struct Participant: Decodable {
        var user: BitbucketAccount?
        /// `PARTICIPANT` or `REVIEWER`.
        var role: String?
        var approved: Bool?
        var state: String?
        var participatedOn: String?
    }
}

/// A comment of a pull request: global, inline (`inline` set) or a reply (`parent` set). `inline.from` is the old
/// line, `inline.to` the new line (the last line of a multi-line comment, whose first is `start_from` or
/// `start_to`). `resolution` is set on a resolved top-level comment, `pending` on an unpublished one.
struct BitbucketComment: Decodable {
    var id: Int
    var content: BitbucketContent?
    var user: BitbucketAccount?
    var deleted: Bool?
    var pending: Bool?
    var parent: Parent?
    var inline: Inline?
    var resolution: Resolution?
    var createdOn: String?
    var updatedOn: String?
    var links: BitbucketLinks?

    struct Parent: Decodable { var id: Int }

    struct Inline: Decodable {
        var path: String?
        var from: Int?
        var to: Int?
        var startFrom: Int?
        var startTo: Int?
    }

    struct Resolution: Decodable { var createdOn: String? }
}

struct BitbucketCommit: Decodable {
    var hash: String
    var message: String?
    var date: String?
    var author: Author?
    var parents: [Parent]?
    var links: BitbucketLinks?

    /// `raw` is `Name <email>`; `user` the account it maps to, when Bitbucket knows one.
    struct Author: Decodable {
        var raw: String?
        var user: BitbucketAccount?
    }

    struct Parent: Decodable { var hash: String? }
}

/// A commit status; `state` is `SUCCESSFUL`, `FAILED`, `INPROGRESS` or `STOPPED`.
struct BitbucketCommitStatus: Decodable {
    var key: String?
    var name: String?
    var state: String
    var url: String?
    var createdOn: String?
    var updatedOn: String?
}

/// `GET .../merge/task-status/{task_id}`: `PENDING` or `SUCCESS`.
struct BitbucketMergeTask: Decodable {
    var taskStatus: String?
}

/// One entry of a pull request's `/activity`: a comment (left out: the comments are read on their own), an `update`
/// (a snapshot of the pull request after it changed), an `approval` or a `changes_requested`.
struct BitbucketActivity: Decodable {
    var update: Update?
    var approval: Approval?
    var changesRequested: Approval?

    struct Update: Decodable {
        var state: String?
        var title: String?
        var description: String?
        var date: String?
        var author: BitbucketAccount?
        var source: BitbucketPullRequest.Endpoint?
        var reviewers: [BitbucketAccount]?
        /// What this update changed; only its reviewers are read (`added`, `removed`), and a shape Histq does not
        /// expect reads as nil rather than failing the whole activity.
        var changes: Changes?
    }

    struct Changes: Decodable {
        var reviewers: ReviewerChange?

        struct ReviewerChange: Decodable {
            var added: [BitbucketAccount]?
            var removed: [BitbucketAccount]?
        }

        private enum CodingKeys: String, CodingKey { case reviewers }

        init(from decoder: any Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            reviewers = (try? container?.decodeIfPresent(ReviewerChange.self, forKey: .reviewers)) ?? nil
        }
    }

    struct Approval: Decodable {
        var date: String?
        var user: BitbucketAccount?
    }
}

/// A pull request task: `state` is `RESOLVED` or `UNRESOLVED`; `comment` the one it was made on.
struct BitbucketTask: Decodable {
    var id: Int
    var content: BitbucketContent?
    var state: String?
    var creator: BitbucketAccount?
    var createdOn: String?
    var resolvedOn: String?
    var resolvedBy: BitbucketAccount?
    var comment: Comment?

    struct Comment: Decodable { var id: Int? }
}

/// A Code Insights report on a commit (`commit/{hash}/reports`).
struct BitbucketReport: Decodable {
    var uuid: String?
    var externalId: String?
    var title: String?
    var result: String?
    var reportType: String?
    var reporter: String?
    var link: String?
}

/// One merge check (`mergeability/checks`): `type`, `status`, `required`, `blocking`; a `name` when Bitbucket gives
/// one (not in the spec).
struct BitbucketMergeCheck: Decodable {
    var type: String?
    var name: String?
    var status: String?
    var required: Bool?
    var blocking: Bool?
}

