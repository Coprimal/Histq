// The parts of Bitbucket Data Center's REST API 1.0 JSON that `BitbucketDCClient` maps into the hosted models
// (`HostedModels.swift`). Keys are camel case as sent; dates are milliseconds since 1970 (read as `Double`, so a
// fractional value never makes a list fail). The 10.4 spec leaves `links`, a pull request's `properties` and an
// activity's comment fields untyped or out of its schema: every field here is optional, and the untyped ones decode
// leniently (a shape Histq does not expect reads as nil rather than failing the whole response).
import Foundation

/// A page of a list: the next page starts at `nextPageStart`, unless `isLastPage`.
struct BitbucketDCPage<Item: Decodable>: Decodable {
    var values: [Item]?
    var isLastPage: Bool?
    var nextPageStart: Int?
}

/// `GET /application-properties`: the instance's version (`8.19.1`).
struct BitbucketDCApplicationProperties: Decodable {
    var version: String?
}

struct BitbucketDCUser: Decodable {
    /// The username, what `X-AUSERNAME` says.
    var name: String?
    /// What `/users/{userSlug}` and `/participants/{userSlug}` take; it may differ from `name`.
    var slug: String?
    var displayName: String?
    var emailAddress: String?
    var id: Int?

    /// `id` the numeric id (else a hash of the username), `login` the username, `reviewerID` the slug, which
    /// participant writes take. No avatar: the app draws Data Center avatars itself.
    var hosted: HostedUser {
        let login = name ?? slug ?? ""
        return HostedUser(
            id: id ?? BitbucketDCClient.stableID("user", login), login: login, name: displayName,
            reviewerID: slug ?? name)
    }
}

/// A `links` object: only a repository's `clone` URLs (`name` `http` or `ssh`) are read.
struct BitbucketDCLinks: Decodable {
    var clone: [Link]?

    struct Link: Decodable {
        var href: String?
        var name: String?
    }

    private enum CodingKeys: String, CodingKey { case clone }

    init(from decoder: any Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        clone = (try? container?.decodeIfPresent([Link].self, forKey: .clone)) ?? nil
    }
}

struct BitbucketDCRepository: Decodable {
    var id: Int?
    var slug: String?
    var name: String?
    var project: Project?
    var `public`: Bool?
    /// The repository this one was forked from.
    var origin: Origin?
    var links: BitbucketDCLinks?

    /// `key` is `PROJ`, or `~USER` for a personal repository.
    struct Project: Decodable { var key: String? }
    struct Origin: Decodable { var slug: String? }
}

/// One end of a pull request: `id` is the full ref (`refs/heads/x`), `displayId` the branch, `latestCommit` its sha.
struct BitbucketDCRef: Decodable {
    var id: String?
    var displayId: String?
    var latestCommit: String?
    var repository: BitbucketDCRepository?
}

/// An author, reviewer or participant: `status` is `UNAPPROVED`, `NEEDS_WORK` or `APPROVED`.
struct BitbucketDCParticipant: Decodable {
    var user: BitbucketDCUser?
    /// `AUTHOR`, `REVIEWER` or `PARTICIPANT`.
    var role: String?
    var approved: Bool?
    var status: String?
}

struct BitbucketDCPullRequest: Decodable {
    var id: Int
    /// The pull request's version, which every write on it must send (a stale one is refused with 409).
    var version: Int?
    var title: String?
    /// Raw markdown.
    var description: String?
    /// `OPEN`, `MERGED` or `DECLINED`.
    var state: String?
    /// Data Center 8.18 and later.
    var draft: Bool?
    var createdDate: Double?
    var updatedDate: Double?
    var closedDate: Double?
    var fromRef: BitbucketDCRef?
    var toRef: BitbucketDCRef?
    var author: BitbucketDCParticipant?
    var reviewers: [BitbucketDCParticipant]?
    var participants: [BitbucketDCParticipant]?
    var properties: Properties?

    /// Untyped in the spec: only `commentCount` is read.
    struct Properties: Decodable {
        var commentCount: Int?

        private enum CodingKeys: String, CodingKey { case commentCount }

        init(from decoder: any Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            commentCount = (try? container?.decodeIfPresent(Int.self, forKey: .commentCount)) ?? nil
        }
    }
}

/// A commit of a pull request: `author` is a user when its email belongs to one (with `id` and `slug`), else only
/// the git author's `name` and `emailAddress`.
struct BitbucketDCCommit: Decodable {
    var id: String
    var message: String?
    var author: BitbucketDCUser?
    var authorTimestamp: Double?
}

/// `GET {R}/default-branch`.
struct BitbucketDCBranch: Decodable {
    var id: String?
    var displayId: String?
}

/// `GET /rest/build-status/latest/commits/stats/{commitId}`: how many builds of the commit are in each state.
struct BitbucketDCBuildStats: Decodable {
    var successful: Int?
    var failed: Int?
    var inProgress: Int?
    var cancelled: Int?
    var unknown: Int?
}

/// Where an inline comment sits: `fileType` `FROM` (the old file) or `TO` (the new one), `lineType` `ADDED`, `REMOVED`
/// or `CONTEXT`; `path` the new path, `srcPath` the old one; `orphaned` once the diff no longer has the line.
struct BitbucketDCAnchor: Decodable {
    var line: Int?
    var lineType: String?
    var fileType: String?
    var path: String?
    var srcPath: String?
    var orphaned: Bool?
}

/// A comment, with its replies nested in `comments` (to any depth). `severity` `BLOCKER` is a task; `state` `PENDING`
/// an unpublished comment only its author sees; `threadResolved` set on a thread's root.
struct BitbucketDCComment: Decodable {
    var id: Int?
    var version: Int?
    /// Raw markdown.
    var text: String?
    var author: BitbucketDCUser?
    var createdDate: Double?
    var updatedDate: Double?
    var comments: [BitbucketDCComment]?
    var anchor: BitbucketDCAnchor?
    var severity: String?
    var state: String?
    var threadResolved: Bool?
    var threadResolvedDate: Double?
    var threadResolver: BitbucketDCUser?
    var permittedOperations: PermittedOperations?
    /// The comment a reply answers (a task made on a comment); nil for a root.
    var parent: Parent?
    /// When and by whom a task (`BLOCKER`, `state` `RESOLVED`) was resolved.
    var resolvedDate: Double?
    var resolver: BitbucketDCUser?

    struct Parent: Decodable { var id: Int? }

    struct PermittedOperations: Decodable {
        var editable: Bool?
        var deletable: Bool?
        var transitionable: Bool?
    }
}

/// One entry of `GET {PR}/activities`: a `COMMENTED` entry's `comment`, as of now, and its `commentAnchor`; a
/// `RESCOPED` entry's commits `added` and `removed` and its source heads. The spec's schema has only `id`, `action`,
/// `createdDate` and `user`, so each field decodes on its own and one odd entry never fails the page.
struct BitbucketDCActivity: Decodable {
    var id: Int?
    var action: String?
    var createdDate: Double?
    var user: BitbucketDCUser?
    /// `ADDED`, `REPLIED`, `EDITED` or `DELETED`.
    var commentAction: String?
    var comment: BitbucketDCComment?
    var commentAnchor: BitbucketDCAnchor?
    var added: Commits?
    var removed: Commits?
    var fromHash: String?
    var previousFromHash: String?

    /// The commits a rescope added or removed: `total` may be more than `commits` lists.
    struct Commits: Decodable {
        var commits: [Commit]?
        var total: Int?

        struct Commit: Decodable {
            var id: String?
            var displayId: String?
            var message: String?
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, action, createdDate, user, commentAction, comment, commentAnchor, added, removed, fromHash
        case previousFromHash
    }

    init(from decoder: any Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        id = (try? container?.decodeIfPresent(Int.self, forKey: .id)) ?? nil
        action = (try? container?.decodeIfPresent(String.self, forKey: .action)) ?? nil
        createdDate = (try? container?.decodeIfPresent(Double.self, forKey: .createdDate)) ?? nil
        user = (try? container?.decodeIfPresent(BitbucketDCUser.self, forKey: .user)) ?? nil
        commentAction = (try? container?.decodeIfPresent(String.self, forKey: .commentAction)) ?? nil
        comment = (try? container?.decodeIfPresent(BitbucketDCComment.self, forKey: .comment)) ?? nil
        commentAnchor = (try? container?.decodeIfPresent(BitbucketDCAnchor.self, forKey: .commentAnchor)) ?? nil
        added = (try? container?.decodeIfPresent(Commits.self, forKey: .added)) ?? nil
        removed = (try? container?.decodeIfPresent(Commits.self, forKey: .removed)) ?? nil
        fromHash = (try? container?.decodeIfPresent(String.self, forKey: .fromHash)) ?? nil
        previousFromHash = (try? container?.decodeIfPresent(String.self, forKey: .previousFromHash)) ?? nil
    }
}

/// `GET {PR}/merge`: whether the pull request has conflicts, and the merge checks that veto it now.
struct BitbucketDCMergeStatus: Decodable {
    var conflicted: Bool?
    /// `CLEAN`, `CONFLICTED` or `UNKNOWN`.
    var outcome: String?
    var vetoes: [Veto]?

    struct Veto: Decodable {
        var summaryMessage: String?
        var detailedMessage: String?
    }
}

/// `GET {R}/settings/pull-requests`: the repository's merge strategies (`no-ff`, `squash`…), each `enabled` or not,
/// and its default.
struct BitbucketDCPullRequestSettings: Decodable {
    var mergeConfig: MergeConfig?

    struct MergeConfig: Decodable {
        var defaultStrategy: Strategy?
        var strategies: [Strategy]?
    }

    struct Strategy: Decodable {
        var id: String?
        var enabled: Bool?
    }
}
