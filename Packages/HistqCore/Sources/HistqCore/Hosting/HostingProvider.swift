// The small surface the app needs from a code host: which repository a remote URL names, its pull requests and
// issues, and the few actions Histq offers on them. The protocol speaks in GitHub's models (`HostedModels.swift`):
// GitHub (and GitHub Enterprise) serves them as they are, GitLab (`GitLabClient`) maps its JSON into them.
import Foundation

/// A repository on a code host: `host` is lowercase and keeps an https port (`ghe.example.com:8443`); `path` is
/// the full path that names it (`owner/repo` on GitHub, `group/sub/repo` with subgroups), relative to the instance's
/// root: an account's base path (a GitLab under `https://host/gitlab`) is not part of it.
public struct HostedRepository: Codable, Sendable, Hashable {
    public var host: String
    public var path: [String]

    public init(host: String, path: [String]) {
        self.host = host
        self.path = path
    }

    /// `path` is `owner` split on `/`, then `name` (kept whole).
    public init(host: String, owner: String, name: String) {
        let owners = owner.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        self.init(host: host, path: owners + [name])
    }

    /// All of `path` but the last segment, joined by `/`.
    public var owner: String { path.dropLast().joined(separator: "/") }
    /// The last segment of `path`.
    public var name: String { path.last ?? "" }

    /// `owner/name`.
    public var fullName: String { "\(owner)/\(name)" }
}

/// Which pull requests or issues a list returns.
public enum HostedListState: String, Sendable {
    case open, closed, all
}

/// What a review says (`POST .../reviews` `event`).
public enum HostedReviewEvent: String, Sendable {
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"
    case comment = "COMMENT"
}

/// How a pull request is merged (`PUT .../merge` `merge_method`).
public enum HostedMergeMethod: String, Sendable {
    case merge, squash, rebase
}

/// Which code host a provider talks to. The raw value is saved in `profiles.json`: never change it.
public enum HostingKind: String, Codable, Sendable, Hashable {
    case github
    case gitlab
}

/// The id rule of `HostedReview` for values a host gives no stable numeric id: a 63-bit FNV-1a hash of the kind and
/// the key, and on a collision with an id already taken in the same pull request the next free value (linear
/// probing), so ids stay unique and the same on every load of the same data (assign them in a stable order).
struct SyntheticIDs {
    private var used: Set<Int> = []

    /// Takes an id the host gave itself, so no synthetic one lands on it.
    mutating func reserve(_ id: Int) {
        used.insert(id)
    }

    mutating func id(_ kind: String, _ key: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in kind.utf8 + [0] + key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        var id = Int(hash & UInt64(Int.max))
        while !used.insert(id).inserted { id = id == Int.max ? 0 : id + 1 }
        return id
    }
}

/// What a provider offers beyond lists and comments; the app hides an action its provider lacks.
public struct HostingCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let labels = HostingCapabilities(rawValue: 1 << 0)
    public static let assignees = HostingCapabilities(rawValue: 1 << 1)
    public static let issues = HostingCapabilities(rawValue: 1 << 2)
    public static let requestChanges = HostingCapabilities(rawValue: 1 << 3)
    public static let resolveThreads = HostingCapabilities(rawValue: 1 << 4)
    public static let draft = HostingCapabilities(rawValue: 1 << 5)
    public static let reopen = HostingCapabilities(rawValue: 1 << 6)
    public static let reviewRequests = HostingCapabilities(rawValue: 1 << 7)
}

/// A pull request or an issue: one number space on GitHub, two on hosts where merge request !5 and issue #5 differ.
public enum HostedItem: Hashable, Sendable {
    case pullRequest(Int)
    case issue(Int)

    public var number: Int {
        switch self {
        case .pullRequest(let number), .issue(let number): number
        }
    }
}

/// The review thread a reply goes to: `rootCommentID` is the thread's root comment, `hostKey` the host's own thread
/// id where replies post to it instead (nil on GitHub, which takes the root comment's).
public struct HostedThreadRef: Sendable, Hashable {
    public var rootCommentID: Int
    public var hostKey: String?

    public init(rootCommentID: Int, hostKey: String? = nil) {
        self.rootCommentID = rootCommentID
        self.hostKey = hostKey
    }
}

/// How a pull request's head is fetched locally: a ref of the base repository (`pull/<n>/head`, fetched under
/// `refs/`), a branch of a remote, or nothing, with the reason.
public enum HostedCheckout: Sendable, Equatable {
    case ref(String)
    case branch(remote: String, name: String)
    case unavailable(reason: String)
}

/// A page of a repository on the host's website.
public enum HostedWebTarget: Sendable, Equatable {
    case repository
    case branch(String)
    case commit(String)
    case pullRequest(Int)
    case issue(Int)
}

/// A pull request to open: `head` is the branch with the changes (`owner:branch` for a fork), `base` the
/// branch it goes into.
public struct NewPullRequest: Sendable, Equatable {
    public var title: String
    public var head: String
    public var base: String
    public var body: String?
    public var draft: Bool

    public init(title: String, head: String, base: String, body: String? = nil, draft: Bool = false) {
        self.title = title
        self.head = head
        self.base = base
        self.body = body
        self.draft = draft
    }
}

public protocol HostingProvider: Sendable {
    /// The repository a remote URL names, or nil when the URL is not a host/owner/repo URL.
    static func repository(fromRemoteURL url: String) -> HostedRepository?

    var kind: HostingKind { get }
    var capabilities: HostingCapabilities { get }
    /// The ways a pull request can be merged.
    var mergeMethods: Set<HostedMergeMethod> { get }
    /// How pull request `pullRequest`'s head is fetched locally.
    func checkout(of pullRequest: HostedPullRequest) -> HostedCheckout
    /// The web page of `target` in `repo`; nil when it has none.
    func webURL(_ target: HostedWebTarget, in repo: HostedRepository) -> URL?

    /// The account the token belongs to.
    func currentUser() async throws -> HostedUser
    /// The token's user's repositories, for a clone picker.
    func userRepositories() async throws -> [HostedCloneRepository]

    func pullRequests(in repo: HostedRepository, state: HostedListState) async throws -> [HostedPullRequest]
    func pullRequest(_ number: Int, in repo: HostedRepository) async throws -> HostedPullRequest
    /// Issues only: the pull requests GitHub also lists as issues are left out.
    func issues(in repo: HostedRepository, state: HostedListState) async throws -> [HostedIssue]
    func issue(_ number: Int, in repo: HostedRepository) async throws -> HostedIssue
    /// The open pull requests the token's user opened, as issue-shaped search results (no `head`/`base`;
    /// `draft` is set).
    func myOpenPullRequests(in repo: HostedRepository) async throws -> [HostedIssue]
    /// The open pull requests that ask the token's user (or one of their teams) for a review, as search results.
    func reviewRequestedPullRequests(in repo: HostedRepository) async throws -> [HostedIssue]
    /// The open issues (no pull requests) assigned to the token's user, as search results.
    func assignedOpenIssues(in repo: HostedRepository) async throws -> [HostedIssue]
    /// The conversation comments of an issue or a pull request.
    func comments(on item: HostedItem, in repo: HostedRepository) async throws -> [HostedComment]
    func reviews(of number: Int, in repo: HostedRepository) async throws -> [HostedReview]
    /// The inline comments of every review of pull request `number`, roots and replies.
    func reviewComments(of number: Int, in repo: HostedRepository) async throws -> [HostedReviewComment]
    /// Whether each review thread of pull request `number` is resolved or outdated and whether the token's user may
    /// resolve it; `rootCommentID` joins a state to its thread's root in `reviewComments(of:in:)`.
    func reviewThreadStates(of number: Int, in repo: HostedRepository) async throws -> [HostedReviewThreadState]
    /// A pull request's commits, oldest first (GitHub lists at most 250).
    func pullRequestCommits(_ number: Int, in repo: HostedRepository) async throws -> [HostedCommit]
    /// The files a pull request changes, with their patches (GitHub lists at most 3000).
    func pullRequestFiles(_ number: Int, in repo: HostedRepository) async throws -> [HostedPullRequestFile]
    /// The check runs of a commit (`ref` is a commit id or a branch name).
    func checkRuns(for ref: String, in repo: HostedRepository) async throws -> [HostedCheckRun]

    /// The repository's own data (its default branch).
    func repositoryInfo(_ repo: HostedRepository) async throws -> HostedRepositoryInfo
    /// The repository's labels, for a new pull request.
    func labels(in repo: HostedRepository) async throws -> [HostedLabel]
    /// The users an issue or a pull request can be assigned to.
    func assignableUsers(in repo: HostedRepository) async throws -> [HostedUser]
    /// The repository's collaborators, the users a review can be requested from (403 without push access).
    func collaborators(in repo: HostedRepository) async throws -> [HostedUser]

    func createPullRequest(_ pullRequest: NewPullRequest, in repo: HostedRepository) async throws
        -> HostedPullRequest
    /// Asks `users` to review pull request `number` (each by its `reviewerID`, else its login).
    func requestReviewers(_ users: [HostedUser], on number: Int, in repo: HostedRepository) async throws
    /// Adds labels (by name) to an issue or a pull request.
    func addLabels(_ names: [String], to item: HostedItem, in repo: HostedRepository) async throws
    /// Assigns `users` to an issue or a pull request (each by its `reviewerID`, else its login).
    func addAssignees(_ users: [HostedUser], to item: HostedItem, in repo: HostedRepository) async throws
    func comment(on item: HostedItem, in repo: HostedRepository, body: String) async throws -> HostedComment
    /// Replies to review thread `thread` on pull request `number`.
    func reply(to thread: HostedThreadRef, on number: Int, in repo: HostedRepository, body: String) async throws
        -> HostedReviewComment
    /// Resolves (`resolved` true) or unresolves the review thread `state` is of, and returns whether it is resolved
    /// as the host answers it.
    func setReviewThread(_ state: HostedReviewThreadState, resolved: Bool) async throws -> Bool
    func review(_ number: Int, in repo: HostedRepository, event: HostedReviewEvent, body: String?)
        async throws -> HostedReview
    /// Merges only while the head is still `sha` (409 otherwise, `HostingError.headChanged` for GitHub).
    func merge(_ number: Int, in repo: HostedRepository, method: HostedMergeMethod, sha: String) async throws
    /// Closes (`open` false) or reopens an issue or a pull request.
    func setOpen(_ open: Bool, item: HostedItem, in repo: HostedRepository) async throws
}
