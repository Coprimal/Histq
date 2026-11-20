// GitHub's REST v3 API for github.com (`https://api.github.com`) and GitHub Enterprise Server
// (`https://<host>/api/v3`). The `URLSession` is injected, so tests serve inline JSON through a stub `URLProtocol`
// and never reach the network. Review thread states and resolving go through GitHub's GraphQL API on the same host
// (`https://api.github.com/graphql`, `https://<host>/api/graphql`), the only API that has them.
//
// The token is a secret: it only ever goes in the `Authorization` header of a request to the client's own API
// host. A `Link: rel="next"` URL on another origin is refused and a redirect to another origin is not followed (a
// redirected request would carry the header along), no error or description holds it, and `print`, `dump` and
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

    public var description: String {
        switch self {
        case .invalidHost(let host): "Not a valid GitHub host: \(host)"
        case .invalidToken: "The GitHub token has characters a token cannot have."
        case .wrongHost(let host): "The repository is on \(host), not on this account's host."
        case .unauthorized: "GitHub refused the token (revoked or expired). Connect the account again."
        case .forbidden(let message): "GitHub refused the request: \(message)"
        case .notFound: "Not found on GitHub (or the account cannot see it)."
        case .rateLimited(let resetsAt):
            if let resetsAt { "GitHub's rate limit is used up until \(resetsAt.formatted(date: .omitted, time: .shortened))." }
            else { "GitHub's rate limit is used up." }
        case .secondaryRateLimited(let seconds):
            if let seconds { "GitHub asks to slow down; retry in \(seconds) s." } else { "GitHub asks to slow down." }
        case .validationFailed(let message): "GitHub refused the request: \(message)"
        case .headChanged: "The pull request's head changed: reload and review it again."
        case .graphQL(let message): "GitHub refused the request: \(message)"
        case .http(let status, let message): "GitHub answered \(status): \(message)"
        case .invalidResponse(let detail): "Unexpected answer from GitHub: \(detail)"
        case .transport(let detail): "Could not reach GitHub: \(detail)"
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
    public init(host: String = "github.com", token: String?, session: URLSession = .shared) throws {
        guard let host = Self.validatedHost(host), let apiBase = Self.apiBase(forHost: host) else {
            throw HostingError.invalidHost(host)
        }
        if let token { guard Self.isUsableToken(token) else { throw HostingError.invalidToken } }
        self.host = host
        self.apiBase = apiBase
        self.token = token
        self.session = session
    }

    public var description: String { "GitHubClient(\(host), token: \(token == nil ? "none" : "set"))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["host": host, "apiBase": apiBase]) }

    // MARK: - Hosts and remote URLs

    /// `host` lowercased when it is a DNS name (letters, digits, `.`, `-`, `_`, not starting with `.` or `-`)
    /// with an optional `:port`; nil otherwise. The strict set keeps it safe in a URL and in a git config key
    /// (`credential.https://<host>.helper`), where `*` would be a wildcard and `/` or `@` would change the URL.
    public static func validatedHost(_ host: String) -> String? {
        let parts = host.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = parts[0]
        let nameOK = !name.isEmpty && name.utf8.count <= 253 && !name.hasPrefix(".") && !name.hasPrefix("-")
            && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
        guard nameOK else { return nil }
        if parts.count == 2 {
            guard parts[1].allSatisfy({ $0.isASCII && $0.isNumber }), let port = Int(parts[1]), (1...65535).contains(port) else {
                return nil
            }
        }
        return host.lowercased()
    }

    /// The REST base of `host` (already validated).
    static func apiBase(forHost host: String) -> URL? {
        host == "github.com" ? URL(string: "https://api.github.com") : URL(string: "https://\(host)/api/v3")
    }

    /// The repository of a GitHub remote URL on any host: `https://[user@]host[:port]/owner/repo[.git][/]`,
    /// `ssh://[user@]host[:port]/owner/repo[.git]` (also `git+ssh://`, `ssh+git://`) and the scp-like
    /// `[user@]host:owner/repo[.git]` (a colon before any slash, as in `HostKeyTrust.host(fromRemoteURL:)`). An
    /// https URL keeps its port (it is the API's port too); an ssh port is dropped. Anything else is nil: other
    /// schemes, local paths, and paths that are not exactly `owner/repo`.
    public static func repository(fromRemoteURL url: String) -> HostedRepository? {
        let lower = url.lowercased()
        var authority: Substring
        var path: Substring
        var keepsPort = false
        if let scheme = ["https://", "ssh://", "git+ssh://", "ssh+git://"].first(where: { lower.hasPrefix($0) }) {
            let rest = url.dropFirst(scheme.count)
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            authority = rest[..<slash]
            path = rest[rest.index(after: slash)...]
            keepsPort = scheme == "https://"
        } else {
            guard !url.contains("://"), let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") else {
                return nil
            }
            authority = url[..<colon]
            path = url[url.index(after: colon)...]
            if path.hasPrefix("/") { path = path.dropFirst() }
        }
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        if !keepsPort, let colon = authority.firstIndex(of: ":") { authority = authority[..<colon] }
        guard let host = validatedHost(String(authority)) else { return nil }

        while path.hasSuffix("/") { path = path.dropLast() }
        if path.lowercased().hasSuffix(".git") { path = path.dropLast(4) }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return nil }
        let owner = String(components[0])
        let name = String(components[1])
        guard isSafeSegment(owner, extra: "-_"), isSafeSegment(name, extra: "-_."), name != ".", name != ".." else {
            return nil
        }
        return HostedRepository(host: host, owner: owner, name: name)
    }

    /// Printable ASCII without spaces or backslashes: a newline would end the HTTP header (or a credential helper's
    /// line), and an `echo` that expands backslashes could print `\n` as one. GitHub tokens have neither.
    public static func isUsableToken(_ token: String) -> Bool {
        !token.isEmpty && token.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) && $0 != "\\" }
    }

    private static func isSafeSegment(_ text: String, extra: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || extra.unicodeScalars.contains($0))
        }
    }

    // MARK: - HostingProvider

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

    public func pullRequest(_ number: Int, in repo: HostedRepository) async throws -> HostedPullRequest {
        try await get(url(try repoPath(repo) + ["pulls", String(number)]))
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

    public func issue(_ number: Int, in repo: HostedRepository) async throws -> HostedIssue {
        try await get(url(try repoPath(repo) + ["issues", String(number)]))
    }

    public func comments(on number: Int, in repo: HostedRepository) async throws -> [HostedComment] {
        try await list(url(try repoPath(repo) + ["issues", String(number), "comments"]))
    }

    public func reviews(of number: Int, in repo: HostedRepository) async throws -> [HostedReview] {
        try await list(url(try repoPath(repo) + ["pulls", String(number), "reviews"]))
    }

    /// The inline comments of every review of pull request `number`, roots and replies, on files and lines. The
    /// reviews themselves only hold their summary body: without these, a review's threads never show.
    public func reviewComments(of number: Int, in repo: HostedRepository) async throws -> [HostedReviewComment] {
        try await list(url(try repoPath(repo) + ["pulls", String(number), "comments"]))
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
        struct Comments: Decodable { var nodes: [Comment] }
        /// GitHub deprecated `databaseId` for `fullDatabaseId`, a BigInt it sends as a string or a number: the full
        /// one wins, else the old one. A value that does not decode only leaves the id nil, so the thread misses its
        /// state instead of the whole load failing.
        struct Comment: Decodable {
            var id: Int?
            enum CodingKeys: CodingKey { case databaseId, fullDatabaseId }
            init(from decoder: any Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                id = (try? values.decode(String.self, forKey: .fullDatabaseId)).flatMap { Int($0) }
                    ?? (try? values.decode(Int.self, forKey: .fullDatabaseId))
                    ?? (try? values.decode(Int.self, forKey: .databaseId))
            }
        }
        // An unknown field fails the whole query: github.com may drop the deprecated `databaseId` and older Enterprise
        // servers may not know `fullDatabaseId`, so each host is asked only for the one it serves.
        let commentIDs = host == "github.com" ? "fullDatabaseId" : "databaseId"
        let query = """
            query ReviewThreadStates($owner: String!, $name: String!, $number: Int!, $after: String) {
              repository(owner: $owner, name: $name) {
                pullRequest(number: $number) {
                  reviewThreads(first: 100, after: $after) {
                    nodes {
                      id isResolved isOutdated viewerCanResolve viewerCanUnresolve
                      comments(first: 1) { nodes { \(commentIDs) } }
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

    public func requestReviewers(_ logins: [String], on number: Int, in repo: HostedRepository) async throws {
        struct Result: Decodable { var number: Int }
        let _: Result = try await send(
            "POST", url(try repoPath(repo) + ["pulls", String(number), "requested_reviewers"]),
            body: ["reviewers": logins])
    }

    public func addLabels(_ names: [String], to number: Int, in repo: HostedRepository) async throws {
        let _: [HostedLabel] = try await send(
            "POST", url(try repoPath(repo) + ["issues", String(number), "labels"]), body: ["labels": names])
    }

    public func addAssignees(_ logins: [String], to number: Int, in repo: HostedRepository) async throws {
        struct Result: Decodable { var number: Int }
        let _: Result = try await send(
            "POST", url(try repoPath(repo) + ["issues", String(number), "assignees"]), body: ["assignees": logins])
    }

    public func comment(on number: Int, in repo: HostedRepository, body: String) async throws -> HostedComment {
        try await send("POST", url(try repoPath(repo) + ["issues", String(number), "comments"]), body: ["body": body])
    }

    /// Replies to the review thread whose root comment is `rootID` on pull request `number`. Always the root's id:
    /// GitHub refuses a reply to a reply.
    public func replyToReviewComment(rootID: Int, on number: Int, in repo: HostedRepository, body: String)
        async throws -> HostedReviewComment
    {
        try await send(
            "POST", url(try repoPath(repo) + ["pulls", String(number), "comments", String(rootID), "replies"]),
            body: ["body": body])
    }

    /// Resolves (`resolved` true) or unresolves the review thread whose GraphQL node id is `id`
    /// (`HostedReviewThreadState.id`), which only GraphQL can, and returns the thread's `isResolved` as GitHub
    /// answers it.
    public func setReviewThread(_ id: String, resolved: Bool) async throws -> Bool {
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
        let answer: Answer = try await graphQL(query, variables: Variables(threadId: id))
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

    public func setOpen(_ open: Bool, number: Int, in repo: HostedRepository) async throws {
        struct Result: Decodable { var number: Int }
        let _: Result = try await send(
            "PATCH", url(try repoPath(repo) + ["issues", String(number)]),
            body: ["state": open ? "open" : "closed"])
    }

    // MARK: - Requests

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
    /// `data`: the errors are read first, and the first one is thrown.
    private func graphQL<Value: Decodable, Variables: Encodable>(_ query: String, variables: Variables)
        async throws -> Value
    {
        var request = request("POST", graphQLURL)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(GraphQLRequest(query: query, variables: variables))
        let (data, _) = try await perform(request)
        let failure: GraphQLErrors = try HostingHTTP.decode(data)
        if let first = failure.errors?.first { throw HostingError.graphQL(message: String(first.message.prefix(500))) }
        let answer: GraphQLAnswer<Value> = try HostingHTTP.decode(data)
        guard let value = answer.data else { throw HostingError.invalidResponse("a GraphQL answer without data") }
        return value
    }

    private struct GraphQLRequest<Variables: Encodable>: Encodable {
        var query: String
        var variables: Variables
    }

    private struct GraphQLErrors: Decodable {
        struct Message: Decodable { var message: String }
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
        let (data, response) = try await HostingHTTP.load(request, session: session)
        guard (200..<300).contains(response.statusCode) else { throw HostingHTTP.error(for: response, data: data) }
        return (data, response)
    }
}
