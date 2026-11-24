// GitHub's REST v3 API for github.com (`https://api.github.com`) and GitHub Enterprise Server
// (`https://<host>/api/v3`). The `URLSession` is injected, so tests serve inline JSON through a stub `URLProtocol`
// and never reach the network. Review thread states and resolving go through GitHub's GraphQL API on the same host
// (`https://api.github.com/graphql`, `https://<host>/api/graphql`), the only API that has them.
//
// The token is a secret: it only ever goes in the `Authorization` header of a request to the client's own API
// host. A `Link: rel="next"` URL on another origin is refused, a redirect is followed only on the same origin (on
// Enterprise also only under `/api`, which holds REST and GraphQL), no error or description holds it, and `print`, `dump` and
// `String(reflecting:)` of a client show only its host.
import Foundation

public enum HostingError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A host name that is not a plain DNS name with an optional port.
    case invalidHost(String)
    /// A token with whitespace, control or non-ASCII characters (it would break the header).
    case invalidToken
    /// The repository is on another host than the client's.
    case wrongHost(String)
    /// 401: the token is missing, revoked or expired.
    case unauthorized
    /// 403 that is not a rate limit (missing scope, SSO not authorized, blocked).
    case forbidden(message: String)
    /// 404, which GitHub also answers for a private repository the token cannot see.
    case notFound
    /// The hourly quota is used up (`X-RateLimit-Remaining: 0`); `resetsAt` from `X-RateLimit-Reset`.
    case rateLimited(resetsAt: Date?)
    /// A secondary (abuse) limit: 429, `Retry-After`, or a 403 that says so.
    case secondaryRateLimited(retryAfterSeconds: Int?)
    /// 422: GitHub refused the request's fields (a pull request that already exists, an unknown branch).
    case validationFailed(message: String)
    /// 409 on a merge: the head is no longer the commit the merge pinned (pushed to since it was reviewed).
    case headChanged
    /// A GraphQL request GitHub answered with 200 and an `errors` array (an unknown thread, no permission); the
    /// first error's message.
    case graphQL(message: String)
    case http(status: Int, message: String)
    /// A body that is not the expected JSON, or a `Link` to another origin.
    case invalidResponse(String)
    /// The request did not complete (offline, timeout, TLS).
    case transport(String)

    public var description: String { description(host: "GitHub", pullRequest: "pull request") }

    /// The description with `host` as the host's product name ("GitLab") and `pullRequest` as what it calls a pull
    /// request ("merge request"): `description` is GitHub's.
    public func description(host: String, pullRequest: String) -> String {
        switch self {
        case .invalidHost(let name): "Not a valid \(host) host: \(name)"
        case .invalidToken: "The \(host) token has characters a token cannot have."
        case .wrongHost(let other): "The repository is on \(other), not on this account's host."
        case .unauthorized: "\(host) refused the token (revoked or expired). Connect the account again."
        case .forbidden(let message): "\(host) refused the request: \(message)"
        case .notFound: "Not found on \(host) (or the account cannot see it)."
        case .rateLimited(let resetsAt):
            if let resetsAt { "\(host)'s rate limit is used up until \(resetsAt.formatted(date: .omitted, time: .shortened))." }
            else { "\(host)'s rate limit is used up." }
        case .secondaryRateLimited(let seconds):
            if let seconds { "\(host) asks to slow down; retry in \(seconds) s." } else { "\(host) asks to slow down." }
        case .validationFailed(let message): "\(host) refused the request: \(message)"
        case .headChanged: "The \(pullRequest)'s head changed: reload and review it again."
        case .graphQL(let message): "\(host) refused the request: \(message)"
        case .http(let status, let message): "\(host) answered \(status): \(message)"
        case .invalidResponse(let detail): "Unexpected answer from \(host): \(detail)"
        case .transport(let detail): "Could not reach \(host): \(detail)"
        }
    }
}

public struct GitHubClient: HostingProvider, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    /// The lowercase host the client talks to (`github.com` or an Enterprise host, with an optional port).
    public let host: String
    /// `https://api.github.com` or `https://<host>/api/v3`.
    public let apiBase: URL
    /// The most pages one list follows (100 items each), so a huge repository cannot keep a list loading.
    public var maxPages = 10
    private let token: String?
    private let session: URLSession

    /// `token` nil reads public data only. Throws `HostingError.invalidHost` or `.invalidToken`.
    public init(host: String = "github.com", token: String?, session: URLSession = HostingHTTP.session) throws {
        guard let host = HostingHTTP.validatedHost(host), let apiBase = Self.apiBase(forHost: host) else {
            throw HostingError.invalidHost(host)
        }
        if let token { guard HostingHTTP.isUsableToken(token) else { throw HostingError.invalidToken } }
        self.host = host
        self.apiBase = apiBase
        self.token = token
        self.session = session
    }

    public var description: String { "GitHubClient(\(host), token: \(token == nil ? "none" : "set"))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["host": host, "apiBase": apiBase]) }

    // MARK: - Hosts and remote URLs

    /// The REST base of `host` (already validated).
    static func apiBase(forHost host: String) -> URL? {
        host == "github.com" ? URL(string: "https://api.github.com") : URL(string: "https://\(host)/api/v3")
    }

    /// The repository of a GitHub remote URL on any host (the forms of `RemoteURL`): its path must be exactly
    /// `owner/repo`, with ASCII letters, digits, `-` and `_` (and `.` in the name). Anything else is nil: other
    /// schemes, local paths, and other paths.
    public static func repository(fromRemoteURL url: String) -> HostedRepository? {
        guard let remote = RemoteURL(url), remote.segments.count == 2 else { return nil }
        let owner = remote.segments[0]
        let name = remote.segments[1]
        guard isSafeSegment(owner, extra: "-_"), isSafeSegment(name, extra: "-_.") else { return nil }
        return HostedRepository(host: remote.host, owner: owner, name: name)
    }

    private static func isSafeSegment(_ text: String, extra: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || extra.unicodeScalars.contains($0))
        }
    }

    // MARK: - HostingProvider

    public var kind: HostingKind { .github }

    public var capabilities: HostingCapabilities {
        [
            .labels, .assignees, .issues, .requestChanges, .resolveThreads, .draft, .reopen, .reviewRequests,
            .editComments, .deleteComments, .reactions, .newInlineComments, .multiLineInlineComments, .itemReactions,
            .timelineEvents, .updateBranch, .deleteHeadBranch, .issueExtras, .pullRequestExtras,
        ]
    }

    public var mergeMethods: Set<HostedMergeMethod> { [.merge, .squash, .rebase] }

    /// REST `content` names, in the order GitHub's reaction picker shows them.
    public var reactionKinds: [String] { Self.reactionContents.map(\.rest) }

    /// Each reaction's REST `content` name and GraphQL `ReactionContent` value.
    static let reactionContents: [(rest: String, graphQL: String)] = [
        ("+1", "THUMBS_UP"), ("-1", "THUMBS_DOWN"), ("laugh", "LAUGH"), ("hooray", "HOORAY"),
        ("confused", "CONFUSED"), ("heart", "HEART"), ("rocket", "ROCKET"), ("eyes", "EYES"),
    ]

    /// `pull/<n>/head`, the ref GitHub keeps for every pull request in the base repository, forks' too.
    public func checkout(of pullRequest: HostedPullRequest) -> HostedCheckout {
        .ref("pull/\(pullRequest.number)/head")
    }

    /// `https://<host>/<owner>/<name>`, then `tree/<branch>` (a `/` in the branch splits it into segments, as on
    /// GitHub), `commit/<sha>`, `pull/<n>` or `issues/<n>`, each segment percent-encoded. Nil for a repository on
    /// another host than the client's, an empty, `.` or `..` segment, or a sha that is not hex.
    public func webURL(_ target: HostedWebTarget, in repo: HostedRepository) -> URL? {
        guard repo.host.lowercased() == host else { return nil }
        var segments = [repo.owner, repo.name]
        switch target {
        case .repository: break
        case .branch(let name):
            segments += ["tree"] + name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        case .commit(let sha):
            guard !sha.isEmpty, sha.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
            segments += ["commit", sha]
        case .pullRequest(let number): segments += ["pull", String(number)]
        case .issue(let number): segments += ["issues", String(number)]
        }
        guard !(repo.path + segments).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        let encoded = segments.compactMap { $0.addingPercentEncoding(withAllowedCharacters: allowed) }
        guard encoded.count == segments.count else { return nil }
        return URL(string: "https://\(host)/" + encoded.joined(separator: "/"))
    }

    public func currentUser() async throws -> HostedUser {
        try await get(url(["user"]))
    }

    /// `GET /user/repos?sort=full_name`: the token's user's repositories by name. GitHub's defaults
    /// (`affiliation=owner,collaborator,organization_member`, `visibility=all`) already include personal,
    /// collaborator and organization repositories. Up to 30 pages (3000 repositories) rather than `maxPages`: a clone
    /// picker must list all of an account's repositories.
    public func userRepositories() async throws -> [HostedCloneRepository] {
        var client = self
        client.maxPages = 30
        return try await client.list(url(["user", "repos"], query: ["sort": "full_name"]))
    }

    public func pullRequests(in repo: HostedRepository, state: HostedListState) async throws -> [HostedPullRequest] {
        try await list(url(try repoPath(repo) + ["pulls"], query: ["state": state.rawValue]))
    }

    /// The single pull request, with what the merge box and the sidebar read beside `HostedPullRequest`'s JSON keys:
    /// who merged it and its merge commit, whether the token's user may push to the base repository (`permissions`,
    /// only on a single pull request), and its milestone.
    public func pullRequest(_ number: Int, in repo: HostedRepository) async throws -> HostedPullRequest {
        let (data, _) = try await perform(request("GET", url(try repoPath(repo) + ["pulls", String(number)])))
        var pull: HostedPullRequest = try HostingHTTP.decode(data)
        struct Extra: Decodable {
            struct Base: Decodable {
                struct Repo: Decodable {
                    struct Permissions: Decodable { var push: Bool? }
                    var permissions: Permissions?
                }
                var repo: Repo?
            }
            struct Milestone: Decodable {
                var title: String
                var dueOn: String?
                enum CodingKeys: String, CodingKey { case title, dueOn = "due_on" }
            }
            var mergedBy: HostedUser?
            var mergeCommitSHA: String?
            var base: Base?
            var milestone: Milestone?
            enum CodingKeys: String, CodingKey {
                case base, milestone
                case mergedBy = "merged_by"
                case mergeCommitSHA = "merge_commit_sha"
            }
        }
        if let extra = try? HostingHTTP.decode(data) as Extra {
            pull.mergedBy = extra.mergedBy
            pull.mergeCommitSHA = extra.mergeCommitSHA
            pull.viewerCanPush = extra.base?.repo?.permissions?.push
            pull.milestone = extra.milestone.map { HostedMilestone(title: $0.title, dueDate: $0.dueOn) }
        }
        return pull
    }

    public func issues(in repo: HostedRepository, state: HostedListState) async throws -> [HostedIssue] {
        let all: [HostedIssue] = try await list(url(try repoPath(repo) + ["issues"], query: ["state": state.rawValue]))
        return all.filter { !$0.isPullRequest }
    }

    public func myOpenPullRequests(in repo: HostedRepository) async throws -> [HostedIssue] {
        try await search(["is:pr", "is:open", "author:@me"], in: repo)
    }

    public func reviewRequestedPullRequests(in repo: HostedRepository) async throws -> [HostedIssue] {
        try await search(["is:pr", "is:open", "review-requested:@me"], in: repo)
    }

    public func assignedOpenIssues(in repo: HostedRepository) async throws -> [HostedIssue] {
        try await search(["is:issue", "is:open", "assignee:@me"], in: repo)
    }

    /// The single issue, with its milestone (the sidebar's) read beside `HostedIssue`'s JSON keys.
    public func issue(_ number: Int, in repo: HostedRepository) async throws -> HostedIssue {
        let (data, _) = try await perform(request("GET", url(try repoPath(repo) + ["issues", String(number)])))
        var issue: HostedIssue = try HostingHTTP.decode(data)
        struct Extra: Decodable {
            struct Milestone: Decodable {
                var title: String
                var dueOn: String?
                enum CodingKeys: String, CodingKey { case title, dueOn = "due_on" }
            }
            var milestone: Milestone?
        }
        if let milestone = (try? HostingHTTP.decode(data) as Extra)?.milestone {
            issue.milestone = HostedMilestone(title: milestone.title, dueDate: milestone.dueOn)
        }
        return issue
    }

    /// A pull request's conversation comments are its issue's. The reaction counts come from each comment's REST
    /// rollup, the viewer's rights and own reactions from `withViewerStates`.
    public func comments(on item: HostedItem, in repo: HostedRepository) async throws -> [HostedComment] {
        let page: [WithReactions<HostedComment>] =
            try await list(url(try repoPath(repo) + ["issues", String(item.number), "comments"]))
        return await withViewerStates(page.map(\.comment))
    }

    public func reviews(of number: Int, in repo: HostedRepository) async throws -> [HostedReview] {
        try await list(url(try repoPath(repo) + ["pulls", String(number), "reviews"]))
    }

    /// The inline comments of every review of pull request `number`, roots and replies, on files and lines. The
    /// reviews themselves only hold their summary body: without these, a review's threads never show.
    public func reviewComments(of number: Int, in repo: HostedRepository) async throws -> [HostedReviewComment] {
        let page: [WithReactions<HostedReviewComment>] =
            try await list(url(try repoPath(repo) + ["pulls", String(number), "comments"]))
        return await withViewerStates(page.map(\.comment))
    }

    /// Whether each review thread of pull request `number` is resolved or outdated and whether the token's user may
    /// resolve it, which only GraphQL has; 100 threads a page, up to `maxPages` pages. `rootCommentID` joins a
    /// state to the thread's root in `reviewComments(of:in:)`.
    public func reviewThreadStates(of number: Int, in repo: HostedRepository) async throws
        -> [HostedReviewThreadState]
    {
        _ = try repoPath(repo)
        struct Variables: Encodable {
            var owner, name: String
            var number: Int
            var after: String?
        }
        struct Answer: Decodable { var repository: Repository? }
        struct Repository: Decodable { var pullRequest: PullRequest? }
        struct PullRequest: Decodable { var reviewThreads: Threads }
        struct Threads: Decodable {
            var nodes: [Thread]
            var pageInfo: PageInfo
        }
        struct PageInfo: Decodable {
            var hasNextPage: Bool
            var endCursor: String?
        }
        struct Thread: Decodable {
            var id: String
            var isResolved, isOutdated, viewerCanResolve, viewerCanUnresolve: Bool
            var comments: Comments
        }
        struct Comments: Decodable { var nodes: [DatabaseID] }
        let query = """
            query ReviewThreadStates($owner: String!, $name: String!, $number: Int!, $after: String) {
              repository(owner: $owner, name: $name) {
                pullRequest(number: $number) {
                  reviewThreads(first: 100, after: $after) {
                    nodes {
                      id isResolved isOutdated viewerCanResolve viewerCanUnresolve
                      comments(first: 1) { nodes { \(commentIDField) } }
                    }
                    pageInfo { hasNextPage endCursor }
                  }
                }
              }
            }
            """
        var states: [HostedReviewThreadState] = []
        var after: String?
        var pages = 0
        repeat {
            let answer: Answer = try await graphQL(
                query, variables: Variables(owner: repo.owner, name: repo.name, number: number, after: after))
            guard let threads = answer.repository?.pullRequest?.reviewThreads else { throw HostingError.notFound }
            states += threads.nodes.map {
                HostedReviewThreadState(
                    id: $0.id, isResolved: $0.isResolved, isOutdated: $0.isOutdated,
                    viewerCanResolve: $0.viewerCanResolve, viewerCanUnresolve: $0.viewerCanUnresolve,
                    rootCommentID: $0.comments.nodes.first?.id)
            }
            pages += 1
            after = threads.pageInfo.hasNextPage ? threads.pageInfo.endCursor : nil
        } while after != nil && pages < maxPages
        return states
    }

    /// GitHub deprecated `databaseId` for `fullDatabaseId`, a BigInt it sends as a string or a number: the full one
    /// wins, else the old one. A value that does not decode only leaves the id nil, so the thread or comment misses
    /// its GraphQL state instead of the whole load failing.
    private struct DatabaseID: Decodable {
        var id: Int?
        enum CodingKeys: CodingKey { case databaseId, fullDatabaseId }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? values.decode(String.self, forKey: .fullDatabaseId)).flatMap { Int($0) }
                ?? (try? values.decode(Int.self, forKey: .fullDatabaseId))
                ?? (try? values.decode(Int.self, forKey: .databaseId))
        }
    }

    /// An unknown field fails the whole query: github.com may drop the deprecated `databaseId` and older Enterprise
    /// servers may not know `fullDatabaseId`, so each host is asked only for the one it serves.
    private var commentIDField: String { host == "github.com" ? "fullDatabaseId" : "databaseId" }

    /// `comments` with the token's user's rights and own reactions, which REST lacks: one GraphQL `nodes(ids:)`
    /// query per 100 comments that have a node id (`hostKey`), without connections (1 point each). A node joins its
    /// comment on (`__typename`, database id), not on the node id string, which GitHub may return in another format
    /// than REST's `node_id`; the issue-comment and review-comment ids are separate spaces. A comment gone since the
    /// REST read (a `NOT_FOUND` node), or every comment of a query that fails, keeps no rights and no viewer
    /// reactions, and the page still loads. Without a token there is no viewer, so nothing is asked.
    private func withViewerStates<Comment: GitHubViewerStateful>(_ comments: [Comment]) async -> [Comment] {
        let ids = comments.compactMap(\.hostKey)
        guard token != nil, !ids.isEmpty else { return comments }
        let states = await viewerStates(ofNodes: ids)
        return comments.map { comment in
            guard let state = states["\(Comment.graphQLTypename) \(comment.id)"] else { return comment }
            var comment = comment
            comment.viewerCanEdit = state.canEdit
            comment.viewerCanDelete = state.canDelete
            for index in comment.reactions.indices where state.reacted.contains(comment.reactions[index].kind) {
                comment.reactions[index].viewerReacted = true
            }
            return comment
        }
    }

    /// The `nodes(ids:)` part of `withViewerStates`: each found comment node's rights and the REST names of the
    /// viewer's own reactions, keyed by `"<__typename> <database id>"`.
    private func viewerStates(ofNodes ids: [String]) async
        -> [String: (canEdit: Bool, canDelete: Bool, reacted: Set<String>)]
    {
        struct Variables: Encodable { var ids: [String] }
        struct Answer: Decodable { var nodes: [Node?] }
        struct Node: Decodable {
            var typename: String?
            var id: Int?
            var viewerCanUpdate, viewerCanDelete: Bool?
            var reactionGroups: [Group]?
            struct Group: Decodable {
                var content: String
                var viewerHasReacted: Bool
            }
            enum CodingKeys: String, CodingKey {
                case typename = "__typename"
                case viewerCanUpdate, viewerCanDelete, reactionGroups
            }
            init(from decoder: any Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                typename = try? values.decode(String.self, forKey: .typename)
                id = try? DatabaseID(from: decoder).id
                viewerCanUpdate = try? values.decode(Bool.self, forKey: .viewerCanUpdate)
                viewerCanDelete = try? values.decode(Bool.self, forKey: .viewerCanDelete)
                reactionGroups = try? values.decode([Group].self, forKey: .reactionGroups)
            }
        }
        let fields = "\(commentIDField) viewerCanUpdate viewerCanDelete reactionGroups { content viewerHasReacted }"
        let query = """
            query CommentViewerStates($ids: [ID!]!) {
              nodes(ids: $ids) {
                __typename
                ... on IssueComment { \(fields) }
                ... on PullRequestReviewComment { \(fields) }
              }
            }
            """
        let restByGraphQL = Dictionary(uniqueKeysWithValues: Self.reactionContents.map { ($0.graphQL, $0.rest) })
        var states: [String: (canEdit: Bool, canDelete: Bool, reacted: Set<String>)] = [:]
        for start in stride(from: 0, to: ids.count, by: 100) {
            let chunk = Array(ids[start..<min(start + 100, ids.count)])
            let answer: Answer? = try? await graphQL(query, variables: Variables(ids: chunk), allowingNotFound: true)
            guard let answer else { continue }
            for case let node? in answer.nodes {
                guard let typename = node.typename, let id = node.id else { continue }
                let reacted = (node.reactionGroups ?? []).filter(\.viewerHasReacted)
                    .compactMap { restByGraphQL[$0.content] }
                states["\(typename) \(id)"] =
                    (node.viewerCanUpdate ?? false, node.viewerCanDelete ?? false, Set(reacted))
            }
        }
        return states
    }

    public func pullRequestCommits(_ number: Int, in repo: HostedRepository) async throws -> [HostedCommit] {
        try await list(url(try repoPath(repo) + ["pulls", String(number), "commits"]))
    }

    public func pullRequestFiles(_ number: Int, in repo: HostedRepository) async throws -> [HostedPullRequestFile] {
        try await list(url(try repoPath(repo) + ["pulls", String(number), "files"]))
    }

    public func checkRuns(for ref: String, in repo: HostedRepository) async throws -> [HostedCheckRun] {
        struct Page: Decodable {
            var checkRuns: [HostedCheckRun]
            enum CodingKeys: String, CodingKey { case checkRuns = "check_runs" }
        }
        let first = url(try repoPath(repo) + ["commits", ref, "check-runs"])
        return try await paginated(first) { (page: Page) in page.checkRuns }
    }

    public func repositoryInfo(_ repo: HostedRepository) async throws -> HostedRepositoryInfo {
        try await get(url(try repoPath(repo)))
    }

    public func labels(in repo: HostedRepository) async throws -> [HostedLabel] {
        try await list(url(try repoPath(repo) + ["labels"]))
    }

    public func assignableUsers(in repo: HostedRepository) async throws -> [HostedUser] {
        try await list(url(try repoPath(repo) + ["assignees"]))
    }

    public func collaborators(in repo: HostedRepository) async throws -> [HostedUser] {
        try await list(url(try repoPath(repo) + ["collaborators"]))
    }

    public func createPullRequest(_ pullRequest: NewPullRequest, in repo: HostedRepository) async throws
        -> HostedPullRequest
    {
        struct Body: Encodable { var title, head, base: String; var body: String?; var draft: Bool }
        let body = Body(
            title: pullRequest.title, head: pullRequest.head, base: pullRequest.base, body: pullRequest.body,
            draft: pullRequest.draft)
        return try await send("POST", url(try repoPath(repo) + ["pulls"]), body: body)
    }

    public func requestReviewers(_ users: [HostedUser], on number: Int, in repo: HostedRepository) async throws {
        struct Result: Decodable { var number: Int }
        let _: Result = try await send(
            "POST", url(try repoPath(repo) + ["pulls", String(number), "requested_reviewers"]),
            body: ["reviewers": users.map { $0.reviewerID ?? $0.login }])
    }

    public func addLabels(_ names: [String], to item: HostedItem, in repo: HostedRepository) async throws {
        let _: [HostedLabel] = try await send(
            "POST", url(try repoPath(repo) + ["issues", String(item.number), "labels"]), body: ["labels": names])
    }

    public func addAssignees(_ users: [HostedUser], to item: HostedItem, in repo: HostedRepository) async throws {
        struct Result: Decodable { var number: Int }
        let _: Result = try await send(
            "POST", url(try repoPath(repo) + ["issues", String(item.number), "assignees"]),
            body: ["assignees": users.map { $0.reviewerID ?? $0.login }])
    }

    public func comment(on item: HostedItem, in repo: HostedRepository, body: String) async throws -> HostedComment {
        try await send(
            "POST", url(try repoPath(repo) + ["issues", String(item.number), "comments"]), body: ["body": body])
    }

    /// Replies to the review thread whose root comment is `thread.rootCommentID` on pull request `number`. Always
    /// the root's id: GitHub refuses a reply to a reply. Only the root's id is needed, so a reply works without the
    /// thread's GraphQL state.
    public func reply(to thread: HostedThreadRef, on number: Int, in repo: HostedRepository, body: String)
        async throws -> HostedReviewComment
    {
        try await send(
            "POST",
            url(try repoPath(repo) + ["pulls", String(number), "comments", String(thread.rootCommentID), "replies"]),
            body: ["body": body])
    }

    /// Resolves (`resolved` true) or unresolves the review thread whose GraphQL node id is `state.id`, which only
    /// GraphQL can, and returns the thread's `isResolved` as GitHub answers it.
    public func setReviewThread(_ state: HostedReviewThreadState, resolved: Bool) async throws -> Bool {
        struct Variables: Encodable { var threadId: String }
        struct Payload: Decodable {
            var thread: Thread?
            struct Thread: Decodable { var isResolved: Bool }
        }
        struct Answer: Decodable { var resolveReviewThread, unresolveReviewThread: Payload? }
        let query = resolved
            ? """
                mutation ResolveReviewThread($threadId: ID!) {
                  resolveReviewThread(input: {threadId: $threadId}) { thread { isResolved } }
                }
                """
            : """
                mutation UnresolveReviewThread($threadId: ID!) {
                  unresolveReviewThread(input: {threadId: $threadId}) { thread { isResolved } }
                }
                """
        let answer: Answer = try await graphQL(query, variables: Variables(threadId: state.id))
        let payload = resolved ? answer.resolveReviewThread : answer.unresolveReviewThread
        guard let isResolved = payload?.thread?.isResolved else {
            throw HostingError.invalidResponse("no review thread in the answer")
        }
        return isResolved
    }

    public func review(_ number: Int, in repo: HostedRepository, event: HostedReviewEvent, body: String?)
        async throws -> HostedReview
    {
        struct Body: Encodable { var event: String; var body: String? }
        return try await send(
            "POST", url(try repoPath(repo) + ["pulls", String(number), "reviews"]),
            body: Body(event: event.rawValue, body: body))
    }

    /// Merges only while the head is still `sha`, the commit the user reviewed: a push in between makes GitHub answer
    /// 409, thrown as `HostingError.headChanged`, rather than merging commits nobody saw.
    public func merge(_ number: Int, in repo: HostedRepository, method: HostedMergeMethod, sha: String) async throws {
        struct Body: Encodable {
            var method: String
            var sha: String
            enum CodingKeys: String, CodingKey { case method = "merge_method", sha }
        }
        struct Result: Decodable { var merged: Bool? }
        do {
            let _: Result = try await send(
                "PUT", url(try repoPath(repo) + ["pulls", String(number), "merge"]),
                body: Body(method: method.rawValue, sha: sha))
        } catch HostingError.http(status: 409, message: _) {
            // Mapped here only: a 409 of another endpoint means something else.
            throw HostingError.headChanged
        }
    }

    public func setOpen(_ open: Bool, item: HostedItem, in repo: HostedRepository) async throws {
        struct Result: Decodable { var number: Int }
        let _: Result = try await send(
            "PATCH", url(try repoPath(repo) + ["issues", String(item.number)]),
            body: ["state": open ? "open" : "closed"])
    }

    /// `PATCH` the comment's REST path (`issues/comments/<id>`, a pull request's conversation comments included, or
    /// `pulls/comments/<id>`): only the body changes.
    public func editComment(_ comment: HostedCommentRef, on item: HostedItem, in repo: HostedRepository, body: String)
        async throws
    {
        struct Result: Decodable { var id: Int }
        let _: Result = try await send("PATCH", url(try commentPath(comment, in: repo)), body: ["body": body])
    }

    /// `DELETE` the comment's REST path, answered 204 without a body.
    public func deleteComment(_ comment: HostedCommentRef, on item: HostedItem, in repo: HostedRepository)
        async throws
    {
        _ = try await perform(request("DELETE", url(try commentPath(comment, in: repo))))
    }

    /// GraphQL `addReaction` on the comment's node id: REST would need the reaction's own id to remove it again.
    public func addReaction(
        _ kind: String, to comment: HostedCommentRef, on item: HostedItem, in repo: HostedRepository
    ) async throws {
        try await setReaction(kind, on: comment, in: repo, added: true)
    }

    /// GraphQL `removeReaction` on the comment's node id, so no reaction id is needed.
    public func removeReaction(
        _ kind: String, from comment: HostedCommentRef, on item: HostedItem, in repo: HostedRepository
    ) async throws {
        try await setReaction(kind, on: comment, in: repo, added: false)
    }

    /// `POST /pulls/<n>/comments` on `line` and `side` (`RIGHT` for an added or context line, `LEFT` for a removed
    /// one), and `start_line`/`start_side` for a range, on the head the patch was loaded at; never the deprecated
    /// `position`. A renamed file's comment goes on its new path, LEFT side included (not stated by GitHub).
    public func createInlineComment(
        at position: HostedInlinePosition, on number: Int, in repo: HostedRepository, body: String
    ) async throws -> HostedReviewComment {
        struct Body: Encodable {
            var body, commitID, path: String
            var line: Int
            var side: String
            var startLine: Int?
            var startSide: String?
            enum CodingKeys: String, CodingKey {
                case body, path, line, side
                case commitID = "commit_id"
                case startLine = "start_line"
                case startSide = "start_side"
            }
        }
        let (line, side) = position.lineKind == .removed ? (position.oldLine, "LEFT") : (position.newLine, "RIGHT")
        guard let line else { throw HostingError.validationFailed(message: "no line on the \(side) side") }
        let start: (line: Int, side: String)? =
            if let new = position.startNewLine { (new, "RIGHT") }
            else if let old = position.startOldLine { (old, "LEFT") }
            else { nil }
        var comment: HostedReviewComment = try await send(
            "POST", url(try repoPath(repo) + ["pulls", String(number), "comments"]),
            body: Body(
                body: body, commitID: position.headSHA, path: position.path, line: line, side: side,
                startLine: start?.line, startSide: start?.side))
        // The token's user wrote it: theirs to edit and delete (the REST answer does not say).
        (comment.viewerCanEdit, comment.viewerCanDelete) = (true, true)
        return comment
    }

    // MARK: - History entries

    /// `GET /repos/{o}/{r}/issues/{n}/timeline`, every page: the item's events that are not comments or reviews (read
    /// elsewhere), each in Histq's words (`text`, its HTML escaped: a label, title or branch is plain text) with
    /// GitHub's event name as `action`. Consecutive commits by the same author are one "added N commits" entry with
    /// a list of their short ids (links to the commits) and subjects. An event GitHub adds later is left out.
    public func timelineEvents(of item: HostedItem, in repo: HostedRepository) async throws
        -> [HostedTimelineEvent]
    {
        let read: [Lossy<GitHubTimelineEvent>] = try await list(url(try repoPath(repo)
            + ["issues", String(item.number), "timeline"]))
        let events = read.compactMap(\.value)
        var entries: [HostedTimelineEvent] = []
        var commits: [GitHubTimelineEvent] = []
        func flushCommits() {
            guard let first = commits.first else { return }
            let count = commits.count
            let text = "added \(count) \(count == 1 ? "commit" : "commits")"
            let items = commits.map { commit -> String in
                let sha = commit.sha ?? ""
                let short = MarkdownHTML.escape(String(sha.prefix(7)))
                let link = webURL(.commit(sha), in: repo).map {
                    "<a href=\"\(MarkdownHTML.escape($0.absoluteString))\"><code>\(short)</code></a>"
                } ?? "<code>\(short)</code>"
                let subject = (commit.message ?? "").split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
                return "<li>\(link) \(MarkdownHTML.escape(subject))</li>"
            }
            // The commits' git author by name only (not an account: no id, avatar or role is looked up for it; the
            // entry shows the name alone).
            let author = first.author?.name.map { HostedUser(id: 0, login: $0) }
            entries.append(HostedTimelineEvent(
                id: "commits-\(first.sha ?? "")", actor: author, createdAt: first.author?.date,
                text: text, textHTML: "<p>\(text)</p><ul>\(items.joined())</ul>", action: "committed",
                icon: "commit"))
            commits = []
        }
        for (index, event) in events.enumerated() {
            if event.event == "committed" {
                if let last = commits.last, last.author?.name != event.author?.name { flushCommits() }
                commits.append(event)
                continue
            }
            flushCommits()
            guard let text = Self.wording(event, item: item) else { continue }
            entries.append(HostedTimelineEvent(
                id: "event-\(event.id.map(String.init) ?? "at\(index)")", actor: event.actor,
                createdAt: event.createdAt, text: text,
                textHTML: "<p>\(MarkdownHTML.escape(text))</p>", action: event.event, icon: event.event))
        }
        flushCommits()
        // GitHub lists a merged pull request's `closed` beside its `merged`, at the same time; its page shows only
        // the merge. An earlier close (closed, reopened, then merged) stays.
        let mergedAt = Set(entries.filter { $0.action == "merged" }.compactMap(\.createdAt))
        entries.removeAll { $0.action == "closed" && $0.createdAt.map(mergedAt.contains) == true }
        return entries
    }

    /// An event in GitHub's words, without its actor ("added the bug label"); nil for comments, reviews and events
    /// Histq does not word.
    static func wording(_ event: GitHubTimelineEvent, item: HostedItem) -> String? {
        let noun = if case .pullRequest = item { "pull request" } else { "issue" }
        let someone = event.assignee?.login ?? event.requestedReviewer?.login ?? event.requestedTeam?.name
        switch event.event {
        case "labeled": return event.label.map { "added the \($0.name) label" }
        case "unlabeled": return event.label.map { "removed the \($0.name) label" }
        case "assigned":
            guard let someone else { return nil }
            return someone == event.actor?.login ? "self-assigned this" : "assigned \(someone)"
        case "unassigned":
            guard let someone else { return nil }
            return someone == event.actor?.login ? "removed their assignment" : "unassigned \(someone)"
        case "review_requested": return someone.map { "requested a review from \($0)" }
        case "review_request_removed": return someone.map { "removed the request for review from \($0)" }
        case "milestoned": return event.milestone.map { "added this to the \($0.title) milestone" }
        case "demilestoned": return event.milestone.map { "removed this from the \($0.title) milestone" }
        case "renamed":
            guard let rename = event.rename else { return nil }
            return "changed the title from \"\(rename.from)\" to \"\(rename.to)\""
        case "closed": return "closed this \(noun)"
        case "reopened": return "reopened this \(noun)"
        case "merged": return event.commitID.map { "merged commit \($0.prefix(7))" } ?? "merged this pull request"
        case "head_ref_force_pushed": return "force-pushed the branch"
        case "head_ref_deleted": return "deleted the branch"
        case "head_ref_restored": return "restored the branch"
        case "ready_for_review": return "marked this pull request as ready for review"
        case "convert_to_draft": return "marked this pull request as draft"
        case "base_ref_changed": return "changed the base branch"
        case "referenced": return event.commitID.map { "added a commit that referenced this \(noun): \($0.prefix(7))" }
        case "cross-referenced":
            guard let source = event.source?.issue else { return nil }
            return "mentioned this \(noun) in #\(source.number) \(source.title)"
        default: return nil
        }
    }

    // MARK: - Merge box: update and head branch

    /// `PUT …/pulls/{n}/update-branch` with `expected_head_sha`: GitHub merges the base into the head and answers 202
    /// at once (it finishes later). A 422 that names the expected sha is `headChanged` (pushed to since it was shown);
    /// any other 422 stays `validationFailed`.
    public func updateBranch(_ number: Int, in repo: HostedRepository, expectedHeadSHA sha: String) async throws {
        struct Body: Encodable {
            var sha: String
            enum CodingKeys: String, CodingKey { case sha = "expected_head_sha" }
        }
        struct Result: Decodable { var message: String? }
        do {
            let _: Result = try await send(
                "PUT", url(try repoPath(repo) + ["pulls", String(number), "update-branch"]), body: Body(sha: sha))
        } catch HostingError.validationFailed(let message) where message.localizedCaseInsensitiveContains("sha") {
            throw HostingError.headChanged
        }
    }

    /// `GET git/ref/heads/<branch>`: whether the branch still exists (404: deleted).
    public func headBranchExists(_ branch: String, in repo: HostedRepository) async throws -> Bool {
        struct Ref: Decodable { var ref: String }
        do {
            let found: Ref = try await get(url(try repoPath(repo) + ["git", "ref"] + Self.headsPath(branch)))
            return found.ref == "refs/heads/\(branch)"
        } catch HostingError.notFound {
            return false
        }
    }

    /// `DELETE git/refs/heads/<branch>`, answered 204 without a body.
    public func deleteHeadBranch(_ branch: String, in repo: HostedRepository) async throws {
        _ = try await perform(request("DELETE", url(try repoPath(repo) + ["git", "refs"] + Self.headsPath(branch))))
    }

    /// `POST git/refs` with `refs/heads/<branch>` at `sha`: the deleted branch made again where it was.
    public func restoreHeadBranch(_ branch: String, sha: String, in repo: HostedRepository) async throws {
        _ = try Self.headsPath(branch)
        struct Result: Decodable { var ref: String }
        let _: Result = try await send(
            "POST", url(try repoPath(repo) + ["git", "refs"]), body: ["ref": "refs/heads/\(branch)", "sha": sha])
    }

    /// `heads` then the branch's segments (`feature/x` is two), each percent-encoded by `url`; a branch with an
    /// empty, `.` or `..` segment is refused, so the path never leaves `git/refs`.
    private static func headsPath(_ branch: String) throws -> [String] {
        let segments = branch.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !segments.isEmpty, !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw HostingError.validationFailed(message: "not a branch name: \(branch)")
        }
        return ["heads"] + segments
    }

    // MARK: - Issue extras

    /// The issue page's extras from GraphQL: the pinned comment, the type, the fields (the type's pinned ones, else
    /// the repository's, each with its value, then any other field with a value), the relationships, and in a second
    /// query the projects (their titles need the `read:project` scope: without it, only how many).
    public func issueExtras(_ number: Int, in repo: HostedRepository) async throws -> HostedIssueExtras {
        _ = try repoPath(repo)
        let variables = ItemVariables(owner: repo.owner, name: repo.name, number: number)
        // Beside the main query, so a token without `read:project` (two reads) adds no round trip after it.
        async let projects = projects(of: .issue(number), in: repo)
        let answer: IssueExtrasAnswer = try await graphQL(Self.issueExtrasQuery, variables: variables)
        guard let issue = answer.repository?.issue else { throw HostingError.notFound }
        var extras = HostedIssueExtras(
            type: issue.issueType?.name, subIssues: issue.subIssuesSummary?.total ?? 0,
            subIssuesCompleted: issue.subIssuesSummary?.completed ?? 0,
            blockedBy: issue.issueDependenciesSummary?.blockedBy ?? 0,
            blocking: issue.issueDependenciesSummary?.blocking ?? 0)
        if let parent = issue.parent { extras.parent = .init(number: parent.number, title: parent.title) }
        if let pinned = issue.pinnedIssueComment, let id = pinned.issueComment?.databaseId {
            let by = pinned.pinnedBy.map {
                HostedUser(id: $0.databaseId ?? 0, login: $0.login, avatarURL: $0.avatarUrl)
            }
            extras.pin = .init(commentID: id, pinnedBy: by,
                               pinnedAt: pinned.pinnedAt.flatMap { ISO8601DateFormatter().date(from: $0) })
        }
        let values = (issue.issueFieldValues?.nodes ?? []).compactMap { $0 }
        let pinned = (issue.issueType?.pinnedFields?.compactMap(\.name)).flatMap { $0.isEmpty ? nil : $0 }
            ?? (answer.repository?.pinnedIssueFields?.nodes ?? []).compactMap { $0?.name }
        func value(of name: String) -> String? { values.first { $0.field?.name == name }?.text }
        extras.fields = pinned.map { .init(name: $0, value: value(of: $0)) }
            + values.compactMap { node in
                guard let name = node.field?.name, !pinned.contains(name) else { return nil }
                return .init(name: name, value: node.text)
            }
        (extras.projects, extras.projectCount) = await projects
        return extras
    }

    /// The pull request's projects and the issues it closes: one GraphQL query for those issues (each with its
    /// repository, which may be another one; nil when that query fails, so the projects still show), the projects
    /// read beside it as for an issue.
    public func pullRequestExtras(_ number: Int, in repo: HostedRepository) async throws -> HostedPullRequestExtras {
        _ = try repoPath(repo)
        struct Answer: Decodable {
            struct Repository: Decodable {
                struct Pull: Decodable {
                    struct Closing: Decodable {
                        struct Node: Decodable {
                            struct Owner: Decodable { var nameWithOwner: String }
                            var number: Int
                            var title: String
                            var state: String?
                            var url: String?
                            var repository: Owner?
                        }
                        var nodes: [Node?]?
                    }
                    var closingIssuesReferences: Closing?
                }
                var pullRequest: Pull?
            }
            var repository: Repository?
        }
        let query = """
            query PullRequestExtras($owner: String!, $name: String!, $number: Int!) {
              repository(owner: $owner, name: $name) {
                pullRequest(number: $number) {
                  closingIssuesReferences(first: 20) {
                    nodes { number title state url repository { nameWithOwner } }
                  }
                }
              }
            }
            """
        async let projects = projects(of: .pullRequest(number), in: repo)
        let answer: Answer? = try? await graphQL(
            query, variables: ItemVariables(owner: repo.owner, name: repo.name, number: number))
        let closing = answer?.repository?.pullRequest.map { pull in
            (pull.closingIssuesReferences?.nodes ?? []).compactMap { node -> HostedPullRequestExtras.ClosingIssue? in
                guard let node else { return nil }
                return .init(number: node.number, title: node.title, isOpen: node.state == "OPEN",
                             repository: node.repository?.nameWithOwner ?? repo.fullName, url: node.url)
            }
        }
        let (titles, count) = await projects
        return HostedPullRequestExtras(projects: titles, projectCount: count, closingIssues: closing)
    }

    /// The item's projects: their titles, or without the `read:project` scope only how many (nil, the count); nil,
    /// nil when neither could be read. `issueOrPullRequest`, so both kinds share the query. Both reads run at once,
    /// so a token without the scope waits for no failed request first.
    private func projects(of item: HostedItem, in repo: HostedRepository) async -> ([String]?, Int?) {
        struct Items: Decodable {
            struct Node: Decodable {
                struct Project: Decodable { var title: String }
                var project: Project?
            }
            var totalCount: Int
            var nodes: [Node?]?
        }
        struct Answer: Decodable {
            struct Repository: Decodable {
                struct Item: Decodable { var projectItems: Items? }
                var issueOrPullRequest: Item?
            }
            var repository: Repository?
        }
        let variables = ItemVariables(owner: repo.owner, name: repo.name, number: item.number)
        let titled = """
            query ItemProjects($owner: String!, $name: String!, $number: Int!) {
              repository(owner: $owner, name: $name) {
                issueOrPullRequest(number: $number) {
                  ... on Issue { projectItems(first: 20) { totalCount nodes { project { title } } } }
                  ... on PullRequest { projectItems(first: 20) { totalCount nodes { project { title } } } }
                }
              }
            }
            """
        let counted = """
            query ItemProjectCount($owner: String!, $name: String!, $number: Int!) {
              repository(owner: $owner, name: $name) {
                issueOrPullRequest(number: $number) {
                  ... on Issue { projectItems { totalCount } }
                  ... on PullRequest { projectItems { totalCount } }
                }
              }
            }
            """
        async let titles: Answer? = try? await graphQL(titled, variables: variables)
        async let count: Answer? = try? await graphQL(counted, variables: variables)
        if let items = await titles?.repository?.issueOrPullRequest?.projectItems {
            return ((items.nodes ?? []).compactMap { $0?.project?.title }, items.totalCount)
        }
        return (nil, await count?.repository?.issueOrPullRequest?.projectItems?.totalCount)
    }

    private struct ItemVariables: Encodable {
        var owner, name: String
        var number: Int
    }

    private static let issueExtrasQuery = """
        query IssueExtras($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pinnedIssueFields(first: 20) { nodes { ...FieldName } }
            issue(number: $number) {
              issueType { name pinnedFields { ...FieldName } }
              pinnedIssueComment {
                pinnedAt
                pinnedBy { login avatarUrl ... on User { databaseId } }
                issueComment { databaseId }
              }
              parent { number title }
              subIssuesSummary { total completed }
              issueDependenciesSummary { blockedBy blocking }
              issueFieldValues(first: 20) {
                nodes {
                  ... on IssueFieldDateValue { value field { ...FieldName } }
                  ... on IssueFieldTextValue { value field { ...FieldName } }
                  ... on IssueFieldNumberValue { numberValue: value field { ...FieldName } }
                  ... on IssueFieldSingleSelectValue { value field { ...FieldName } }
                  ... on IssueFieldMultiSelectValue { value field { ...FieldName } }
                }
              }
            }
          }
        }
        fragment FieldName on IssueFields {
          ... on IssueFieldDate { name } ... on IssueFieldText { name } ... on IssueFieldNumber { name }
          ... on IssueFieldSingleSelect { name } ... on IssueFieldMultiSelect { name }
        }
        """

    private struct IssueExtrasAnswer: Decodable {
        struct FieldName: Decodable { var name: String? }
        struct Repository: Decodable {
            struct Fields: Decodable { var nodes: [FieldName?]? }
            struct Issue: Decodable {
                struct IssueType: Decodable {
                    var name: String
                    var pinnedFields: [FieldName]?
                }
                struct Pinned: Decodable {
                    struct Actor: Decodable {
                        var login: String
                        var avatarUrl: String?
                        var databaseId: Int?
                    }
                    struct Comment: Decodable { var databaseId: Int? }
                    var pinnedAt: String?
                    var pinnedBy: Actor?
                    var issueComment: Comment?
                }
                struct Parent: Decodable {
                    var number: Int
                    var title: String
                }
                struct SubIssues: Decodable {
                    var total: Int?
                    var completed: Int?
                }
                struct Dependencies: Decodable {
                    var blockedBy: Int?
                    var blocking: Int?
                }
                struct Values: Decodable {
                    struct Node: Decodable {
                        var value: String?
                        var numberValue: Double?
                        var field: FieldName?
                        /// The value as the page shows it: a number without a trailing ".0".
                        var text: String? {
                            value ?? numberValue.map {
                                $0.rounded() == $0 && abs($0) < 1e15 ? String(Int64($0)) : String($0)
                            }
                        }
                    }
                    var nodes: [Node?]?
                }
                var issueType: IssueType?
                var pinnedIssueComment: Pinned?
                var parent: Parent?
                var subIssuesSummary: SubIssues?
                var issueDependenciesSummary: Dependencies?
                var issueFieldValues: Values?
            }
            var pinnedIssueFields: Fields?
            var issue: Issue?
        }
        var repository: Repository?
    }

    // MARK: - Reactions on the item itself

    /// The pull request's or issue's own reactions, from GraphQL `reactionGroups` (REST's `reactions` rollup has no
    /// viewer state): each kind with a reaction, in `reactionKinds` order, the token's user's marked.
    public func itemReactions(of item: HostedItem, in repo: HostedRepository) async throws -> [HostedReaction] {
        let groups = try await itemNode(item, in: repo).reactionGroups ?? []
        return Self.reactionContents.compactMap { content in
            guard let group = groups.first(where: { $0.content == content.graphQL }),
                  let count = group.reactors?.totalCount, count > 0 else { return nil }
            return HostedReaction(kind: content.rest, count: count, viewerReacted: group.viewerHasReacted == true)
        }
    }

    /// GraphQL `addReaction` on the item's node id, read first (`itemNode`).
    public func addItemReaction(_ kind: String, to item: HostedItem, in repo: HostedRepository) async throws {
        try await setItemReaction(kind, on: item, in: repo, added: true)
    }

    /// GraphQL `removeReaction` on the item's node id, read first (`itemNode`).
    public func removeItemReaction(_ kind: String, from item: HostedItem, in repo: HostedRepository) async throws {
        try await setItemReaction(kind, on: item, in: repo, added: false)
    }

    private func setItemReaction(_ kind: String, on item: HostedItem, in repo: HostedRepository, added: Bool)
        async throws
    {
        guard Self.reactionContents.contains(where: { $0.rest == kind }) else {
            throw HostingError.validationFailed(message: "not a GitHub reaction: \(kind)")
        }
        let node = try await itemNode(item, in: repo)
        try await setReaction(kind, on: HostedCommentRef(kind: .general, id: item.number, hostKey: node.id), in: repo,
                              added: added)
    }

    /// The item's node id and reaction groups: `repository.issueOrPullRequest(number:)`, so a pull request and an
    /// issue share one query. A number that names the other kind of item is refused.
    private func itemNode(_ item: HostedItem, in repo: HostedRepository) async throws -> ItemNode {
        _ = try repoPath(repo)
        struct Variables: Encodable { var owner, name: String; var number: Int }
        struct Answer: Decodable {
            struct Repository: Decodable { var issueOrPullRequest: ItemNode? }
            var repository: Repository?
        }
        let query = """
            query ItemReactions($owner: String!, $name: String!, $number: Int!) {
              repository(owner: $owner, name: $name) {
                issueOrPullRequest(number: $number) {
                  __typename
                  ... on Issue { id reactionGroups { content viewerHasReacted reactors { totalCount } } }
                  ... on PullRequest { id reactionGroups { content viewerHasReacted reactors { totalCount } } }
                }
              }
            }
            """
        let answer: Answer = try await graphQL(
            query, variables: Variables(owner: repo.owner, name: repo.name, number: item.number))
        let isPullRequest = if case .pullRequest = item { true } else { false }
        guard let node = answer.repository?.issueOrPullRequest,
              node.typename == (isPullRequest ? "PullRequest" : "Issue"), !node.id.isEmpty
        else { throw HostingError.notFound }
        return node
    }

    private struct ItemNode: Decodable {
        struct Group: Decodable {
            struct Reactors: Decodable { var totalCount: Int }
            var content: String
            var viewerHasReacted: Bool?
            var reactors: Reactors?
        }
        var typename: String
        var id: String
        var reactionGroups: [Group]?
        enum CodingKeys: String, CodingKey {
            case typename = "__typename", id, reactionGroups
        }
    }

    // MARK: - Requests

    /// The REST path of a conversation (`issues/comments/<id>`) or review (`pulls/comments/<id>`) comment.
    private func commentPath(_ comment: HostedCommentRef, in repo: HostedRepository) throws -> [String] {
        try repoPath(repo) + [comment.kind == .general ? "issues" : "pulls", "comments", String(comment.id)]
    }

    /// Adds or removes the token's user's reaction `kind` (a REST name of `reactionKinds`) on the comment's node id;
    /// a kind GitHub lacks or a comment without a node id is refused unsent.
    private func setReaction(_ kind: String, on comment: HostedCommentRef, in repo: HostedRepository, added: Bool)
        async throws
    {
        _ = try repoPath(repo)
        guard let content = Self.reactionContents.first(where: { $0.rest == kind })?.graphQL else {
            throw HostingError.validationFailed(message: "not a GitHub reaction: \(kind)")
        }
        guard let subjectId = comment.hostKey else {
            throw HostingError.validationFailed(message: "the comment has no node id")
        }
        struct Variables: Encodable { var subjectId, content: String }
        struct Payload: Decodable {}
        struct Answer: Decodable { var addReaction, removeReaction: Payload? }
        let name = added ? "addReaction" : "removeReaction"
        let query = """
            mutation \(added ? "AddReaction" : "RemoveReaction")($subjectId: ID!, $content: ReactionContent!) {
              \(name)(input: {subjectId: $subjectId, content: $content}) { reaction { content } }
            }
            """
        let _: Answer = try await graphQL(query, variables: Variables(subjectId: subjectId, content: content))
    }

    private func repoPath(_ repo: HostedRepository) throws -> [String] {
        guard repo.host.lowercased() == host else { throw HostingError.wrongHost(repo.host) }
        return ["repos", repo.owner, repo.name]
    }

    /// `GET /search/issues?q=repo:<owner>/<name> <qualifiers>`, most recently updated first, every page up to
    /// `maxPages`. `@me` is the token's user. The owner and name go into the query text, so they must be plain
    /// segments (as `repository(fromRemoteURL:)` makes them): a space or a quote would add qualifiers of its own.
    private func search(_ qualifiers: [String], in repo: HostedRepository) async throws -> [HostedIssue] {
        _ = try repoPath(repo)
        guard Self.isSafeSegment(repo.owner, extra: "-_"), Self.isSafeSegment(repo.name, extra: "-_.") else {
            throw HostingError.validationFailed(message: "not a repository name: \(repo.fullName)")
        }
        struct Page: Decodable { var items: [HostedIssue] }
        let query = (["repo:\(repo.owner)/\(repo.name)"] + qualifiers).joined(separator: " ")
        let first = url(["search", "issues"], query: ["q": query, "sort": "updated", "order": "desc"])
        return try await paginated(first) { (page: Page) in page.items }
    }

    /// `apiBase` plus `segments`, each percent-encoded as one path segment (a `/` in a branch name stays inside
    /// its segment), and `query`.
    private func url(_ segments: [String], query: [String: String] = [:]) -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        var components = URLComponents(url: apiBase, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath += segments
            .map { "/" + ($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.joined()
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let (data, _) = try await perform(request("GET", url))
        return try HostingHTTP.decode(data)
    }

    private func send<T: Decodable, Body: Encodable>(_ method: String, _ url: URL, body: Body) async throws -> T {
        var request = request(method, url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, _) = try await perform(request)
        return try HostingHTTP.decode(data)
    }

    /// GitHub's GraphQL endpoint on `apiBase`'s origin: `https://api.github.com/graphql`, or
    /// `https://<host>/api/graphql` for Enterprise (whose REST base is `/api/v3`). Only the validated host goes in,
    /// so the token travels nowhere `apiBase` does not.
    private var graphQLURL: URL {
        var components = URLComponents(url: apiBase, resolvingAgainstBaseURL: false)!
        components.path = host == "github.com" ? "/graphql" : "/api/graphql"
        return components.url!
    }

    /// POSTs a GraphQL operation through `request` and `perform`, so it carries the token, headers and redirect
    /// guard of every REST call. Values only go in `variables`, never into the `query` text, where a quote would
    /// change the operation. GitHub answers a failed operation with 200, an `errors` array and a partial or null
    /// `data`: the errors are read first, and the first one is thrown. With `allowingNotFound`, `NOT_FOUND` errors
    /// (a node of a `nodes(ids:)` lookup gone since, answered as null) are skipped, so the rest of `data` is used.
    private func graphQL<Value: Decodable, Variables: Encodable>(
        _ query: String, variables: Variables, allowingNotFound: Bool = false
    ) async throws -> Value {
        var request = request("POST", graphQLURL)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(GraphQLRequest(query: query, variables: variables))
        let (data, _) = try await perform(request)
        let failure: GraphQLErrors = try HostingHTTP.decode(data)
        let errors = (failure.errors ?? []).filter { !(allowingNotFound && $0.type == "NOT_FOUND") }
        if let first = errors.first { throw HostingError.graphQL(message: String(first.message.prefix(500))) }
        let answer: GraphQLAnswer<Value> = try HostingHTTP.decode(data)
        guard let value = answer.data else { throw HostingError.invalidResponse("a GraphQL answer without data") }
        return value
    }

    private struct GraphQLRequest<Variables: Encodable>: Encodable {
        var query: String
        var variables: Variables
    }

    private struct GraphQLErrors: Decodable {
        struct Message: Decodable {
            var message: String
            var type: String?
        }
        var errors: [Message]?
    }

    private struct GraphQLAnswer<Value: Decodable>: Decodable { var data: Value? }

    /// Every page of a list endpoint that answers a JSON array.
    private func list<T: Decodable>(_ first: URL) async throws -> [T] {
        try await paginated(first) { (page: [T]) in page }
    }

    /// Follows `Link: rel="next"` from `first` (with `per_page=100`), up to `maxPages` pages. A next URL on
    /// another origin than `apiBase` throws: following it would send the token there.
    private func paginated<Page: Decodable, Item>(_ first: URL, items: (Page) -> [Item]) async throws -> [Item] {
        var components = URLComponents(url: first, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "per_page", value: "100")]
        var next: URL? = components.url!
        var result: [Item] = []
        var pages = 0
        while let url = next, pages < maxPages {
            let (data, response) = try await perform(request("GET", url))
            let page: Page = try HostingHTTP.decode(data)
            result += items(page)
            pages += 1
            next = HostingHTTP.nextLink(response.value(forHTTPHeaderField: "Link"))
            if let next, !HostingHTTP.isSameOrigin(next, apiBase) {
                throw HostingError.invalidResponse("a next-page link to another host")
            }
        }
        return result
    }

    private func request(_ method: String, _ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        // `full+json` adds `body_html` (GitHub's sanitized HTML) next to the markdown `body`.
        request.setValue("application/vnd.github.full+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Histq", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // Enterprise serves its web pages on the API's origin: a redirect keeps the token only under `/api`.
        let prefix = apiBase.path(percentEncoded: true).hasPrefix("/api/") ? "/api" : nil
        let (data, response) = try await HostingHTTP.load(request, session: session, allowedPathPrefix: prefix)
        guard (200..<300).contains(response.statusCode) else { throw HostingHTTP.error(for: response, data: data) }
        return (data, response)
    }
}

/// A REST comment with GitHub's `reactions` rollup (`url`, `total_count` and a count per `content`) mapped into its
/// `reactions`, the kinds with a count, in `reactionKinds` order. A missing or other-shaped rollup leaves none.
private struct WithReactions<Comment: GitHubViewerStateful>: Decodable {
    var comment: Comment

    private struct Keys: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: any Decoder) throws {
        comment = try Comment(from: decoder)
        guard let rollup = try? decoder.container(keyedBy: Keys.self)
            .nestedContainer(keyedBy: Keys.self, forKey: Keys(stringValue: "reactions"))
        else { return }
        comment.reactions = GitHubClient.reactionContents.compactMap { content in
            guard let count = try? rollup.decode(Int.self, forKey: Keys(stringValue: content.rest)), count > 0 else {
                return nil
            }
            return HostedReaction(kind: content.rest, count: count)
        }
    }
}

/// The fields `withViewerStates` fills on both comment kinds, and the GraphQL type a kind's node has.
private protocol GitHubViewerStateful: Decodable {
    static var graphQLTypename: String { get }
    var id: Int { get }
    var hostKey: String? { get }
    var viewerCanEdit: Bool { get set }
    var viewerCanDelete: Bool { get set }
    var reactions: [HostedReaction] { get set }
}

extension HostedComment: GitHubViewerStateful {
    fileprivate static var graphQLTypename: String { "IssueComment" }
}

extension HostedReviewComment: GitHubViewerStateful {
    fileprivate static var graphQLTypename: String { "PullRequestReviewComment" }
}

/// An entry of GitHub's issue timeline (`GET …/issues/{n}/timeline`), only the fields Histq words; every one is
/// optional, as the shape differs per event (a `committed` entry has `sha`, `message` and `author` instead of an
/// `id`, `actor` and `created_at`).
struct GitHubTimelineEvent: Decodable {
    struct Label: Decodable { var name: String }
    struct Milestone: Decodable { var title: String }
    struct Rename: Decodable { var from, to: String }
    struct Team: Decodable { var name: String }
    struct Person: Decodable {
        var name: String?
        var date: Date?
    }
    struct Source: Decodable {
        struct Issue: Decodable {
            var number: Int
            var title: String
        }
        var issue: Issue?
    }

    var id: Int?
    var event: String?
    var actor: HostedUser?
    var createdAt: Date?
    var label: Label?
    var milestone: Milestone?
    var rename: Rename?
    var assignee: HostedUser?
    var requestedReviewer: HostedUser?
    var requestedTeam: Team?
    var commitID: String?
    var sha: String?
    var message: String?
    var author: Person?
    var source: Source?

    enum CodingKeys: String, CodingKey {
        case id, event, actor, label, milestone, rename, assignee, sha, message, author, source
        case createdAt = "created_at"
        case requestedReviewer = "requested_reviewer"
        case requestedTeam = "requested_team"
        case commitID = "commit_id"
    }
}

/// A list element that decodes to nil instead of failing the whole list: one event of a shape Histq does not expect
/// leaves only itself out.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}
