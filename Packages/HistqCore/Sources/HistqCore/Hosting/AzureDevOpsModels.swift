// The parts of Azure DevOps Services' REST API 7.1 JSON that `AzureDevOpsClient` maps into the hosted models
// (`HostedModels.swift`). Keys are camel case as sent; dates stay strings and are parsed by `GitLabDate` (ISO 8601,
// Azure's with seven fractional digits), so one odd date never makes a list fail. Every field is optional, and the
// enums Azure may send as a name or a number (a thread's `status`, a comment's `commentType`) decode as their names.
// Deprecated fields are never read: no `imageUrl`, no `uniqueName`.
import Foundation

/// A list answer: `value` holds the items.
struct AzureDevOpsList<Item: Decodable>: Decodable {
    var value: [Item]?
}

/// `GET https://app.vssps.visualstudio.com/_apis/profile/profiles/me`.
struct AzureDevOpsProfile: Decodable {
    /// A GUID: the same id as a pull request's `createdBy.id` and its reviewers' ids.
    var id: String?
    var displayName: String?
    var emailAddress: String?
    var publicAlias: String?
}

/// An organization of `GET https://app.vssps.visualstudio.com/_apis/accounts?memberId=…`.
struct AzureDevOpsAccount: Decodable {
    var accountName: String?
}

/// An identity (`IdentityRef`): a user or a group (`isContainer`), by its GUID.
struct AzureDevOpsIdentity: Decodable {
    var id: String?
    var displayName: String?
    var isContainer: Bool?

    /// `id` a hash of the GUID (Azure has no numeric user id, and views tell users apart by it), `login` the display
    /// name (the user name is only in a deprecated field), `reviewerID` the GUID, which reviewer writes take. No
    /// avatar: the app draws Azure DevOps avatars itself.
    var hosted: HostedUser {
        let guid = (id ?? "").lowercased()
        let login = displayName ?? guid
        return HostedUser(
            id: AzureDevOpsClient.userID(guid.isEmpty ? login : guid), login: login, name: displayName,
            reviewerID: id)
    }
}

struct AzureDevOpsProject: Decodable {
    var id: String?
    var name: String?
    /// `private` or `public`.
    var visibility: String?
}

/// `GET {org}/_apis/git/repositories` and `GET {R}`.
struct AzureDevOpsRepository: Decodable {
    var id: String?
    var name: String?
    var project: AzureDevOpsProject?
    /// The https clone URL (`https://org@dev.azure.com/org/project/_git/repo`).
    var remoteUrl: String?
    /// `refs/heads/main`; nil for an empty repository.
    var defaultBranch: String?
    var isDisabled: Bool?
    var isFork: Bool?
}

/// A commit a pull request points at (`lastMergeSourceCommit`, …).
struct AzureDevOpsCommitRef: Decodable {
    var commitId: String?
}

/// A reviewer: `vote` 10 approved, 5 approved with suggestions, 0 none, -5 waiting for the author, -10 rejected.
struct AzureDevOpsReviewer: Decodable {
    var id: String?
    var displayName: String?
    var vote: Int?
    var isRequired: Bool?
    var hasDeclined: Bool?
    var isContainer: Bool?

    var identity: AzureDevOpsIdentity {
        AzureDevOpsIdentity(id: id, displayName: displayName, isContainer: isContainer)
    }
}

/// A pull request's label (a free tag): only the `active` ones show.
struct AzureDevOpsLabel: Decodable {
    var id: String?
    var name: String?
    var active: Bool?
}

struct AzureDevOpsPullRequest: Decodable {
    var pullRequestId: Int
    /// `active`, `abandoned` or `completed`.
    var status: String?
    var isDraft: Bool?
    /// `notSet`, `queued`, `conflicts`, `succeeded`, `rejectedByPolicy` or `failure`.
    var mergeStatus: String?
    /// Why the last completion failed, when it did.
    var mergeFailureMessage: String?
    var title: String?
    /// Raw markdown.
    var description: String?
    var createdBy: AzureDevOpsIdentity?
    var creationDate: String?
    var closedDate: String?
    /// `refs/heads/<branch>`.
    var sourceRefName: String?
    var targetRefName: String?
    /// The head of the source branch, as the last merge evaluation read it.
    var lastMergeSourceCommit: AzureDevOpsCommitRef?
    var lastMergeTargetCommit: AzureDevOpsCommitRef?
    /// The merge commit (a completed pull request's).
    var lastMergeCommit: AzureDevOpsCommitRef?
    /// Set (any content) for a pull request from a fork.
    var forkSource: Present?
    var reviewers: [AzureDevOpsReviewer]?
    var labels: [AzureDevOpsLabel]?
    var repository: AzureDevOpsRepository?

    /// A value only checked for being there: any JSON shape decodes.
    struct Present: Decodable {
        init(from decoder: any Decoder) throws {}
    }
}

/// A commit of `GET {PR}/commits`.
struct AzureDevOpsCommit: Decodable {
    var commitId: String?
    var author: Signature?
    /// The message (Azure may cut a long one short).
    var comment: String?

    struct Signature: Decodable {
        var name: String?
        var email: String?
        var date: String?
    }
}

/// An iteration of `GET {PR}/iterations` (one per push).
struct AzureDevOpsIteration: Decodable {
    var id: Int?
}

/// `GET {PR}/iterations/{n}/changes`: one page of the files the pull request changes, the next at `nextSkip`.
struct AzureDevOpsIterationChanges: Decodable {
    var changeEntries: [Entry]?
    var nextSkip: Int?

    struct Entry: Decodable {
        var changeTrackingId: Int?
        var item: Item?
        /// `add`, `edit`, `delete`, `rename`, or several joined by `, ` (`edit, rename`).
        var changeType: String?
        /// A renamed file's old path (with a leading `/`).
        var originalPath: String?
    }

    struct Item: Decodable {
        /// With a leading `/`.
        var path: String?
        var isFolder: Bool?
    }
}

/// A position in a file of a thread's `threadContext`.
struct AzureDevOpsFilePosition: Codable {
    var line: Int?
    var offset: Int?
}

/// Where an inline thread is: the file (with a leading `/`) and its lines on the new (`right…`) or old (`left…`) side;
/// a new inline thread sends one (nil fields left out).
struct AzureDevOpsThreadContext: Codable {
    var filePath: String?
    var leftFileStart: AzureDevOpsFilePosition?
    var leftFileEnd: AzureDevOpsFilePosition?
    var rightFileStart: AzureDevOpsFilePosition?
    var rightFileEnd: AzureDevOpsFilePosition?
}

struct AzureDevOpsComment: Decodable {
    /// Unique within its thread.
    var id: Int?
    /// The comment this one answers; 0 for none.
    var parentCommentId: Int?
    var author: AzureDevOpsIdentity?
    var content: String?
    /// `unknown`, `text`, `codeChange` or `system`.
    var commentType: String?
    var publishedDate: String?
    var lastUpdatedDate: String?
    var isDeleted: Bool?
    /// The users who liked it (Azure's one reaction).
    var usersLiked: [AzureDevOpsIdentity]?

    private enum CodingKeys: String, CodingKey {
        case id, parentCommentId, author, content, commentType, publishedDate, lastUpdatedDate, isDeleted, usersLiked
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decodeIfPresent(Int.self, forKey: .id)
        parentCommentId = try? container.decodeIfPresent(Int.self, forKey: .parentCommentId)
        author = try? container.decodeIfPresent(AzureDevOpsIdentity.self, forKey: .author)
        content = try? container.decodeIfPresent(String.self, forKey: .content)
        commentType = AzureDevOpsEnumName.decode(
            container, .commentType, names: ["unknown", "text", "codeChange", "system"])
        publishedDate = try? container.decodeIfPresent(String.self, forKey: .publishedDate)
        lastUpdatedDate = try? container.decodeIfPresent(String.self, forKey: .lastUpdatedDate)
        isDeleted = try? container.decodeIfPresent(Bool.self, forKey: .isDeleted)
        usersLiked = try? container.decodeIfPresent([AzureDevOpsIdentity].self, forKey: .usersLiked)
    }
}

struct AzureDevOpsThread: Decodable {
    var id: Int?
    /// `unknown`, `active`, `fixed`, `wontFix`, `closed`, `byDesign` or `pending`; nil when not sent.
    var status: String?
    /// nil for a thread on the pull request itself.
    var threadContext: AzureDevOpsThreadContext?
    var comments: [AzureDevOpsComment]?
    /// The thread's `properties` (each a `{"$type", "$value"}` pair) by name, each `$value` as text (a number or a
    /// flag written out; "" when it is neither, so every name sent is kept): a system thread has
    /// `CodeReviewThreadType` (`VoteUpdate`, `ReviewersUpdate`, `RefUpdate`, `MergeAttempt`…) and the fields of its
    /// kind (`CodeReviewVoteResult`, `CodeReviewVotedByTfId`…).
    var properties: [String: String]
    var isDeleted: Bool?

    private enum CodingKeys: String, CodingKey {
        case id, status, threadContext, comments, properties, isDeleted
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// A property's `$value` as text; "" for any other shape.
    private struct PropertyValue: Decodable {
        var text = ""

        private enum CodingKeys: String, CodingKey { case value = "$value" }

        init(from decoder: any Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { return }
            if let text = try? container.decode(String.self, forKey: .value) {
                self.text = text
            } else if let number = try? container.decode(Int.self, forKey: .value) {
                text = String(number)
            } else if let flag = try? container.decode(Bool.self, forKey: .value) {
                text = String(flag)
            }
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decodeIfPresent(Int.self, forKey: .id)
        status = AzureDevOpsEnumName.decode(
            container, .status, names: ["unknown", "active", "fixed", "wontFix", "closed", "byDesign", "pending"])
        threadContext = try? container.decodeIfPresent(AzureDevOpsThreadContext.self, forKey: .threadContext)
        comments = try? container.decodeIfPresent([AzureDevOpsComment].self, forKey: .comments)
        let bag = try? container.nestedContainer(keyedBy: AnyKey.self, forKey: .properties)
        var properties: [String: String] = [:]
        for key in bag?.allKeys ?? [] {
            properties[key.stringValue] = (try? bag?.decode(PropertyValue.self, forKey: key))?.text ?? ""
        }
        self.properties = properties
        isDeleted = try? container.decodeIfPresent(Bool.self, forKey: .isDeleted)
    }
}

/// A status a service posted on a pull request or a commit: `state` `notSet`, `pending`, `succeeded`, `failed`,
/// `error` or `notApplicable`, named by its `context` (`genre/name`).
struct AzureDevOpsStatus: Decodable {
    var id: Int?
    var state: String?
    var description: String?
    var context: Context?
    var targetUrl: String?
    var creationDate: String?
    var updatedDate: String?

    struct Context: Decodable {
        var name: String?
        var genre: String?
    }
}

/// A branch policy's evaluation on a pull request (`policy/evaluations`, a 7.1 preview API): `status` `queued`,
/// `running`, `approved`, `rejected`, `notApplicable` or `broken`.
struct AzureDevOpsPolicyEvaluation: Decodable {
    var evaluationId: String?
    var status: String?
    var configuration: Configuration?
    var startedDate: String?
    var completedDate: String?

    struct Configuration: Decodable {
        var isEnabled: Bool?
        var isBlocking: Bool?
        var type: PolicyType?
    }

    struct PolicyType: Decodable {
        var displayName: String?
    }
}

/// `GET /<org>/_apis/projects/<project>`: its id and default team.
struct AzureDevOpsTeamProject: Decodable {
    var id: String?
    var defaultTeam: Team?

    struct Team: Decodable {
        var id: String?
    }
}

/// A member of `GET /<org>/_apis/projects/<projectId>/teams/<teamId>/members`.
struct AzureDevOpsTeamMember: Decodable {
    var identity: AzureDevOpsIdentity?
}

/// A branch policy of `GET /<org>/<project>/_apis/policy/configurations`; only "Require a merge strategy"'s settings
/// are read.
struct AzureDevOpsPolicyConfiguration: Decodable {
    var isEnabled: Bool?
    var isBlocking: Bool?
    var type: PolicyType?
    var settings: Settings?

    struct PolicyType: Decodable {
        var id: String?
    }

    struct Settings: Decodable {
        var allowNoFastForward: Bool?
        var allowSquash: Bool?
        var allowRebase: Bool?
        var allowRebaseMerge: Bool?
        var scope: [Scope]?
    }

    /// Where a policy applies: a ref (`refs/heads/main`) matched `exact`ly or as a `prefix`, in one repository (nil
    /// for every repository of the project).
    struct Scope: Decodable {
        var refName: String?
        var matchKind: String?
        var repositoryId: String?
    }
}

/// An enum Azure sends as its name or as its number (the index in `names`); nil for anything else.
enum AzureDevOpsEnumName {
    static func decode<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, _ key: Key, names: [String])
        -> String?
    {
        if let name = try? container.decodeIfPresent(String.self, forKey: key) { return name }
        guard let number = try? container.decodeIfPresent(Int.self, forKey: key), names.indices.contains(number)
        else { return nil }
        return names[number]
    }
}
