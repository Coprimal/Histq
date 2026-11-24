// Bitbucket Data Center (a server of its own, REST API 1.0). A repository is `<project key>/<repo slug>`, or
// `~<user>/<repo slug>` for a personal one: a `HostedRepository`'s `path` is exactly those two segments. The instance
// may live under a context path (`https://host/bitbucket`), kept as the account's `basePath`, never in `path`.
//
// The `URLSession` is injected, so tests serve inline JSON through a stub `URLProtocol` and never reach the network.
// The token (a personal HTTP access token) is a secret: the client asks its provider for it on every request, and
// after a 401 asks once more with the refused token and retries that request once. It only ever goes in the
// `Authorization: Bearer` header of a request under `apiBase` (`https://host[/ctx]/rest/api/latest`),
// `buildStatusBase` (`.../rest/build-status/latest`) or `branchUtilsBase` (`.../rest/branch-utils/latest`): a redirect
// to another origin or outside the request's base is not followed, no error or description holds it, and `print`,
// `dump` and `String(reflecting:)` of a client show only its host.
import Foundation
import Synchronization

public struct BitbucketDCClient: HostingProvider, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    /// Hands out the access token: `rejected` is the token a 401 just refused (a constant HTTP access token ignores
    /// it); nil otherwise.
    public typealias TokenProvider = @Sendable (_ rejected: String?) async throws -> String

    /// The lowercase host the client talks to, with an optional port.
    public let host: String
    /// The context path Bitbucket lives under on `host`, as segments; empty at the root.
    public let basePath: [String]
    /// `https://<host>[/<basePath>]/rest/api/latest`.
    public let apiBase: URL
    /// `https://<host>[/<basePath>]/rest/build-status/latest`: the builds' summary of a commit.
    public let buildStatusBase: URL
    /// `https://<host>[/<basePath>]/rest/branch-utils/latest`: deleting the source branch after a merge.
    public let branchUtilsBase: URL
    /// The most pages one list follows (100 items each), so a huge instance cannot keep a list loading.
    public var maxPages = 10
    private let token: TokenProvider
    private let session: URLSession
    private let memo = Memo()

    /// `basePath` is the context path (`bitbucket` for `https://example.com/bitbucket`), nil or empty at the root.
    /// Throws `HostingError.invalidHost` for a host or base path that is not plain.
    public init(
        host: String, basePath: String? = nil, session: URLSession = HostingHTTP.session,
        token: @escaping TokenProvider
    ) throws {
        guard let validHost = HostingHTTP.validatedHost(host), let segments = GitLabClient.basePathSegments(basePath),
            let apiBase = URL(
                string: "https://\(validHost)" + (segments + ["rest", "api", "latest"]).map { "/" + $0 }.joined()),
            let buildStatusBase = URL(
                string: "https://\(validHost)" + (segments + ["rest", "build-status", "latest"]).map { "/" + $0 }
                    .joined()),
            let branchUtilsBase = URL(
                string: "https://\(validHost)" + (segments + ["rest", "branch-utils", "latest"]).map { "/" + $0 }
                    .joined())
        else {
            throw HostingError.invalidHost(host)
        }
        self.host = validHost
        self.basePath = segments
        self.apiBase = apiBase
        self.buildStatusBase = buildStatusBase
        self.branchUtilsBase = branchUtilsBase
        self.token = token
        self.session = session
    }

    public var description: String { "BitbucketDCClient(\(([host] + basePath).joined(separator: "/")))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["host": host, "apiBase": apiBase]) }

    /// What the client remembers between calls: the instance's version (read by `currentUser()`, it gates `draft`),
    /// the token's user's slug (participant writes take it), and the pull request of each thread it mapped (for
    /// `setReviewThread(_:resolved:)`, which gets the thread only). Shared by copies of the client.
    private final class Memo: Sendable {
        let version = Mutex<String?>(nil)
        let userSlug = Mutex<String?>(nil)
        let pullRequestByThread = Mutex<[Int: (path: [String], number: Int)]>([:])
    }

    // MARK: - Remote URLs and ids

    /// The repository of a Bitbucket Data Center remote URL on an instance at the host's root.
    public static func repository(fromRemoteURL url: String) -> HostedRepository? {
        repository(fromRemoteURL: url, basePath: nil)
    }

    /// The repository of a Bitbucket Data Center remote URL:
    /// `https://[user@]host[:port][/<basePath>]/scm/PROJ/repo[.git]` (the instance's `basePath` is stripped, then
    /// `scm`), or `ssh://git@host[:port]/PROJ/repo[.git]` and the scp-like form, which carry neither. Exactly a project key (or `~user`) and a repository, each ASCII letters, digits, `-`,
    /// `_` and `.`, case kept. A remote with a password, another prefix or more segments is nil.
    public static func repository(fromRemoteURL url: String, basePath: String?) -> HostedRepository? {
        guard let remote = RemoteURL(url), !remote.hasPassword, let base = GitLabClient.basePathSegments(basePath)
        else { return nil }
        var path = remote.segments
        if url.lowercased().hasPrefix("https://") {
            let prefix = base + ["scm"]
            guard path.starts(with: prefix) else { return nil }
            path.removeFirst(prefix.count)
        }
        guard path.count == 2, isSafeSegment(path[0].hasPrefix("~") ? String(path[0].dropFirst()) : path[0]),
            isSafeSegment(path[1])
        else { return nil }
        return HostedRepository(host: remote.host, path: path)
    }

    private static func isSafeSegment(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0))
        }
    }

    /// The same synthetic id for the same key on every call (no probing), for values without a numeric id.
    static func stableID(_ kind: String, _ key: String) -> Int {
        var ids = SyntheticIDs()
        return ids.id(kind, key)
    }

    /// A Data Center timestamp (milliseconds since 1970) as a date.
    static func date(_ milliseconds: Double?) -> Date? {
        milliseconds.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    /// Whether `version` (`8.19.1`) is 8.18 or later, where pull requests can be drafts; false when unknown or not
    /// a version.
    static func supportsDraft(_ version: String?) -> Bool {
        guard let parts = version?.split(separator: ".", omittingEmptySubsequences: false), parts.count >= 2,
            let major = Int(parts[0].prefix { $0.isASCII && $0.isNumber }),
            let minor = Int(parts[1].prefix { $0.isASCII && $0.isNumber })
        else { return false }
        return (major, minor) >= (8, 18)
    }

    // MARK: - HostingProvider

    public var kind: HostingKind { .bitbucketDataCenter }

    /// No labels, assignees or issues (Data Center has reviewers only and no issue tracker), no reactions (no
    /// public read of them), a new inline comment on one line only, and no merged box's Delete branch (the app offers
    /// it only with GitHub's push right). `draft` only once `currentUser()` read a version of 8.18 or later.
    public var capabilities: HostingCapabilities {
        var capabilities: HostingCapabilities = [
            .requestChanges, .resolveThreads, .reopen, .reviewRequests, .generalReplies, .resolveGeneralThreads,
            .editComments, .deleteComments, .newInlineComments, .timelineEvents, .tasks, .mergeChecks,
        ]
        if Self.supportsDraft(memo.version.withLock({ $0 })) { capabilities.insert(.draft) }
        return capabilities
    }

    /// `no-ff`, `squash` and `rebase-no-ff`, where the repository's strategies cannot be read (a pull request's own
    /// `allowedMergeMethods` lists them otherwise).
    public var mergeMethods: Set<HostedMergeMethod> { [.merge, .squash, .rebase] }

    /// The source branch, `refs/heads/<branch>` of the repository's own remote, for a pull request from the same
    /// repository (its head has an `owner:branch` label). The pull request refs Data Center keeps are not documented,
    /// so a fork's branch cannot be fetched from that remote.
    public func checkout(of pullRequest: HostedPullRequest) -> HostedCheckout {
        guard pullRequest.head.label != nil, !pullRequest.head.ref.isEmpty else {
            return .unavailable(reason: "Pull requests from forks can't be checked out here")
        }
        return .ref("heads/\(pullRequest.head.ref)")
    }

    /// `https://<host>[/<basePath>]/projects/<P>/repos/<r>` (`users/<user>/repos/<r>` for a `~user` key), then
    /// `browse`, `browse?at=refs%2Fheads%2F<branch>`, `commits/<sha>` or `pull-requests/<n>`, each segment
    /// percent-encoded. Nil for an issue, a repository on another host or not key/repo, an empty, `.` or `..`
    /// segment, or a sha that is not hex.
    public func webURL(_ target: HostedWebTarget, in repo: HostedRepository) -> URL? {
        guard repo.host.lowercased() == host, repo.path.count == 2 else { return nil }
        let key = repo.path[0]
        var segments = key.hasPrefix("~")
            ? ["users", String(key.dropFirst()), "repos", repo.path[1]] : ["projects", key, "repos", repo.path[1]]
        var query = ""
        switch target {
        case .repository: segments.append("browse")
        case .branch(let name):
            guard !name.isEmpty,
                let value = ("refs/heads/" + name).addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed)
            else { return nil }
            segments.append("browse")
            query = "?at=" + value
        case .commit(let sha):
            guard !sha.isEmpty, sha.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
            segments += ["commits", sha]
        case .pullRequest(let number): segments += ["pull-requests", String(number)]
        case .issue: return nil
        }
        segments = basePath + segments
        guard !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        let encoded = segments.compactMap { $0.addingPercentEncoding(withAllowedCharacters: Self.segmentAllowed) }
        guard encoded.count == segments.count else { return nil }
        return URL(string: "https://\(host)/" + encoded.joined(separator: "/") + query)
    }

    /// `GET /application-properties` (with the token): its `X-AUSERNAME` header is the token's user, and its
    /// `version` is remembered (it gates `draft`). A 200 without the header means the token was not accepted:
    /// `HostingError.unauthorized`. The user is then the entry of `GET /users?filter=<name>` whose `name` is exactly
    /// the header's (raw or percent-decoded): a user slug may differ from the username.
    public func currentUser() async throws -> HostedUser {
        let (data, response) = try await perform("GET", url(["application-properties"]))
        let properties: BitbucketDCApplicationProperties? = try? Self.decode(data)
        memo.version.withLock { $0 = properties?.version }
        let header = response.value(forHTTPHeaderField: "X-AUSERNAME") ?? ""
        guard !header.isEmpty else { throw HostingError.unauthorized }
        let decoded = header.removingPercentEncoding ?? header
        let users: [BitbucketDCUser] = try await list(url(["users"], query: [("filter", decoded)]))
        guard let user = users.first(where: { $0.name == header || $0.name == decoded }) else {
            throw HostingError.invalidResponse("could not read the signed-in user")
        }
        memo.userSlug.withLock { $0 = user.slug ?? user.name }
        return user.hosted
    }

    /// `GET /repos?permission=REPO_READ`: every repository the token's user can read, sorted by full name, with its
    /// https clone link. Up to 60 pages (6000 repositories) rather than `maxPages`: a clone picker must list all of
    /// them. A repository without an https `http` clone link naming it on this instance is left out.
    public func userRepositories() async throws -> [HostedCloneRepository] {
        var client = self
        client.maxPages = 60
        let repos: [BitbucketDCRepository] = try await client.list(
            url(["repos"], query: [("permission", "REPO_READ")]))
        return repos.compactMap(cloneRepository).sorted { $0.fullName.lowercased() < $1.fullName.lowercased() }
    }

    /// `GET {R}/pull-requests?state=…`: `OPEN`, else `ALL` (the list takes one state), with `.closed` keeping the
    /// merged and declined ones.
    public func pullRequests(in repo: HostedRepository, state: HostedListState) async throws -> [HostedPullRequest] {
        let prs: [BitbucketDCPullRequest] = try await list(
            url(try repoPath(repo) + ["pull-requests"], query: [("state", state == .open ? "OPEN" : "ALL")]))
        return prs.filter { state != .closed || $0.state != "OPEN" }.map { pullRequest($0, in: repo) }
    }

    /// `GET {PR}`, then the repository's strategies (`GET {R}/settings/pull-requests`) as its `allowedMergeMethods`
    /// and `defaultMergeMethod`, both nil when they cannot be read.
    public func pullRequest(_ number: Int, in repo: HostedRepository) async throws -> HostedPullRequest {
        let pr: BitbucketDCPullRequest = try await get(url(try pullRequestPath(number, in: repo)))
        var pull = pullRequest(pr, in: repo)
        (pull.allowedMergeMethods, pull.defaultMergeMethod) = Self.mergeMethods(await strategies(in: repo))
        return pull
    }

    public func issues(in repo: HostedRepository, state: HostedListState) async throws -> [HostedIssue] {
        throw Self.noIssues
    }

    public func issue(_ number: Int, in repo: HostedRepository) async throws -> HostedIssue {
        throw Self.noIssues
    }

    /// The token's user's open pull requests (`GET /dashboard/pull-requests?role=AUTHOR`) into this repository.
    public func myOpenPullRequests(in repo: HostedRepository) async throws -> [HostedIssue] {
        try await dashboardPullRequests(role: "AUTHOR", in: repo)
    }

    /// The open pull requests into this repository with the token's user as a reviewer
    /// (`GET /dashboard/pull-requests?role=REVIEWER`).
    public func reviewRequestedPullRequests(in repo: HostedRepository) async throws -> [HostedIssue] {
        try await dashboardPullRequests(role: "REVIEWER", in: repo)
    }

    public func assignedOpenIssues(in repo: HostedRepository) async throws -> [HostedIssue] {
        throw Self.noIssues
    }

    /// The comments of a pull request outside its inline threads, thread by thread (oldest first), each root then
    /// its replies (oldest first) with their direct `parentID`. A root is `resolvable` where Data Center says whether
    /// its thread is resolved. Rights from the comment's `permittedOperations`; `hostKey` is its version.
    public func comments(on item: HostedItem, in repo: HostedRepository) async throws -> [HostedComment] {
        guard case .pullRequest(let number) = item else { throw Self.noIssues }
        return try await threads(of: number, in: repo).filter { !$0.isInline }.flatMap { thread in
            thread.comments.map(Self.comment)
        }
    }

    /// One review per reviewer or participant who approved (`APPROVED`) or asked for changes (`NEEDS_WORK`), sorted
    /// by slug; the others have not reviewed (the pull request lists them in `requestedReviewers`). Ids are
    /// synthetic, keyed by the slug. Data Center gives no date.
    public func reviews(of number: Int, in repo: HostedRepository) async throws -> [HostedReview] {
        let pr: BitbucketDCPullRequest = try await get(url(try pullRequestPath(number, in: repo)))
        return Self.reviews(pr)
    }

    /// The comments of every inline thread (a root with an anchor path), roots and replies, each reply pointing at
    /// its thread's root. The side comes from the anchor: `fileType` `FROM` or `lineType` `REMOVED` is `LEFT`, else
    /// `RIGHT`; an orphaned anchor (the line left the diff) has no current `line`. The diff hunk is cut from the file's
    /// current patch (`GitLabClient.hunk`), nil when the line is not in it.
    public func reviewComments(of number: Int, in repo: HostedRepository) async throws -> [HostedReviewComment] {
        let threads = try await threads(of: number, in: repo).filter(\.isInline)
        guard !threads.isEmpty else { return [] }
        let files = (try? await pullRequestFiles(number, in: repo)) ?? []
        let patches = Dictionary(
            files.compactMap { file in file.patch.map { (file.filename, $0) } }, uniquingKeysWith: { a, _ in a })
        return threads.flatMap { thread in
            let anchor = thread.anchor
            let path = anchor?.path ?? ""
            let side = anchor?.fileType == "FROM" || anchor?.lineType == "REMOVED" ? "LEFT" : "RIGHT"
            let line = anchor?.line.flatMap { $0 > 0 ? $0 : nil }
            let current = anchor?.orphaned != true
            let hunk = current
                ? line.flatMap { line in patches[path].flatMap { GitLabClient.hunk($0, side: side, line: line) } } : nil
            return thread.comments.map { entry in
                let comment = entry.comment
                let isRoot = entry.id == thread.rootID
                var mapped = HostedReviewComment(
                    id: entry.id, inReplyToID: isRoot ? nil : thread.rootID, path: path, line: current ? line : nil,
                    originalLine: line, side: side, diffHunk: hunk, body: comment.text,
                    bodyHTML: comment.text.map(MarkdownHTML.html), user: comment.author?.hosted,
                    createdAt: Self.date(comment.createdDate), hostKey: comment.version.map(String.init))
                mapped.viewerCanEdit = comment.permittedOperations?.editable ?? false
                mapped.viewerCanDelete = comment.permittedOperations?.deletable ?? false
                if isRoot, comment.threadResolved == true {
                    mapped.resolvedBy = comment.threadResolver?.hosted
                    mapped.resolvedAt = Self.date(comment.threadResolvedDate)
                }
                return mapped
            }
        }
    }

    /// A state for each inline thread: the root comment's id is its key, resolved from the root's `threadResolved`,
    /// outdated when its anchor is orphaned. Whether the token's user may resolve it is not said (both flags true;
    /// Data Center refuses the others).
    public func reviewThreadStates(of number: Int, in repo: HostedRepository) async throws
        -> [HostedReviewThreadState]
    {
        let threads = try await threads(of: number, in: repo).filter(\.isInline)
        let path = try repoPath(repo)
        memo.pullRequestByThread.withLock { memo in
            for thread in threads { memo[thread.rootID] = (path, number) }
        }
        return threads.map { thread in
            HostedReviewThreadState(
                id: String(thread.rootID), isResolved: thread.comments[0].comment.threadResolved == true,
                isOutdated: thread.anchor?.orphaned == true, viewerCanResolve: true, viewerCanUnresolve: true,
                rootCommentID: thread.rootID)
        }
    }

    /// Oldest first: Data Center lists a pull request's commits newest first.
    public func pullRequestCommits(_ number: Int, in repo: HostedRepository) async throws -> [HostedCommit] {
        let commits: [BitbucketDCCommit] = try await list(url(try pullRequestPath(number, in: repo) + ["commits"]))
        return commits.reversed().map { commit in
            HostedCommit(
                sha: commit.id, htmlURL: webURL(.commit(commit.id), in: repo)?.absoluteString,
                commit: .init(
                    message: commit.message ?? "",
                    author: .init(
                        name: commit.author?.displayName ?? commit.author?.name,
                        email: commit.author?.emailAddress, date: Self.date(commit.authorTimestamp))),
                author: commit.author?.id == nil ? nil : commit.author?.hosted)
        }
    }

    /// `GET {PR}.diff`, the raw diff of the pull request: one git diff (its `src://`/`dst://` path prefixes read as
    /// git's `a/`/`b/`), split into its files.
    public func pullRequestFiles(_ number: Int, in repo: HostedRepository) async throws -> [HostedPullRequestFile] {
        let (data, _) = try await perform(
            "GET", url(try repoPath(repo) + ["pull-requests", "\(number).diff"]), accept: "text/plain")
        return BitbucketCloudClient.files(fromDiff: Self.gitPrefixes(data))
    }

    /// `GET /rest/build-status/latest/commits/stats/{commitId}`: one summary entry per build state with builds
    /// ("2 successful builds", "1 failed build"), without a link (no build list is read). A `ref` that is not a hex
    /// commit id (a branch name) has none.
    public func checkRuns(for ref: String, in repo: HostedRepository) async throws -> [HostedCheckRun] {
        _ = try repoPath(repo)
        guard ref.count >= 7, ref.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return [] }
        let stats: BitbucketDCBuildStats = try await get(url(["commits", "stats", ref], under: buildStatusBase))
        return Self.checkRuns(stats)
    }

    /// `checkRuns(for:in:)`'s entries: successful (`success`), failed (`failure`), in progress, cancelled
    /// (`cancelled`) and unknown (`neutral`), in that order.
    static func checkRuns(_ stats: BitbucketDCBuildStats) -> [HostedCheckRun] {
        let rows: [(key: String, count: Int?, status: String, conclusion: String?)] = [
            ("successful", stats.successful, "completed", "success"),
            ("failed", stats.failed, "completed", "failure"),
            ("in progress", stats.inProgress, "in_progress", nil),
            ("cancelled", stats.cancelled, "completed", "cancelled"),
            ("unknown", stats.unknown, "completed", "neutral"),
        ]
        var ids = SyntheticIDs()
        return rows.compactMap { row in
            guard let count = row.count, count > 0 else { return nil }
            let noun = count == 1 ? "build" : "builds"
            let name = row.key == "in progress" ? "\(count) \(noun) in progress" : "\(count) \(row.key) \(noun)"
            return HostedCheckRun(
                id: ids.id("builds", row.key), name: name, status: row.status, conclusion: row.conclusion)
        }
    }

    /// `GET {R}/default-branch`.
    public func repositoryInfo(_ repo: HostedRepository) async throws -> HostedRepositoryInfo {
        let branch: BitbucketDCBranch = try await get(url(try repoPath(repo) + ["default-branch"]))
        guard let name = Self.branchName(branch.id, display: branch.displayId), !name.isEmpty else {
            throw HostingError.invalidResponse("a repository without a default branch")
        }
        return HostedRepositoryInfo(fullName: repo.fullName, defaultBranch: name)
    }

    /// None: Data Center pull requests have no labels.
    public func labels(in repo: HostedRepository) async throws -> [HostedLabel] {
        []
    }

    /// None: Data Center pull requests have no assignees.
    public func assignableUsers(in repo: HostedRepository) async throws -> [HostedUser] {
        []
    }

    /// `GET /users?permission.1=REPO_READ&permission.1.projectKey=…&permission.1.repositorySlug=…`: the users who
    /// can read the repository, any of whom can be asked to review.
    public func collaborators(in repo: HostedRepository) async throws -> [HostedUser] {
        let path = try repoPath(repo)
        let users: [BitbucketDCUser] = try await list(
            url(["users"], query: [
                ("permission.1", "REPO_READ"), ("permission.1.projectKey", path[1]),
                ("permission.1.repositorySlug", path[3]),
            ]))
        return users.map(\.hosted)
    }

    // MARK: - Writes

    /// `POST {R}/pull-requests` from a branch of the same repository to another (a fork's `owner:branch` head is
    /// refused). `draft` is sent only when asked for, and refused unsent on an instance without drafts (the
    /// capability).
    public func createPullRequest(_ pullRequest: NewPullRequest, in repo: HostedRepository) async throws
        -> HostedPullRequest
    {
        guard !pullRequest.head.contains(":") else {
            throw HostingError.validationFailed(message: "a pull request from a fork is not supported yet")
        }
        guard !pullRequest.draft || capabilities.contains(.draft) else {
            throw HostingError.validationFailed(message: "this Bitbucket Data Center has no draft pull requests")
        }
        let path = try repoPath(repo)
        struct Project: Encodable { var key: String }
        struct Repository: Encodable { var slug: String; var project: Project }
        struct Ref: Encodable { var id: String; var repository: Repository }
        struct Body: Encodable {
            var title: String
            var description: String?
            var fromRef, toRef: Ref
            /// Left out unless asked for.
            var draft: Bool?
        }
        let repository = Repository(slug: path[3], project: Project(key: path[1]))
        let pr: BitbucketDCPullRequest = try await send(
            "POST", url(path + ["pull-requests"]),
            body: Body(
                title: pullRequest.title, description: pullRequest.body,
                fromRef: Ref(id: "refs/heads/" + pullRequest.head, repository: repository),
                toRef: Ref(id: "refs/heads/" + pullRequest.base, repository: repository),
                draft: pullRequest.draft ? true : nil))
        return self.pullRequest(pr, in: repo)
    }

    /// Adds `users` (each by its login, the username Data Center's `user.name` takes) to the reviewers: `PUT {PR}`
    /// replaces the list, so the pull request is read first and its reviewers, title, description and draft state
    /// are sent back with its `version`.
    public func requestReviewers(_ users: [HostedUser], on number: Int, in repo: HostedRepository) async throws {
        guard !users.isEmpty else { return }
        let path = try pullRequestPath(number, in: repo)
        let (current, version) = try await versioned(path)
        var names = (current.reviewers ?? []).compactMap { $0.user?.name }
        for user in users where !names.contains(where: { $0.lowercased() == user.login.lowercased() }) {
            names.append(user.login)
        }
        struct Name: Encodable { var name: String }
        struct Reviewer: Encodable { var user: Name }
        struct Body: Encodable {
            var version: Int
            var title: String?
            var description: String?
            var reviewers: [Reviewer]
            var draft: Bool?
        }
        let _: BitbucketDCPullRequest = try await send(
            "PUT", url(path),
            body: Body(
                version: version, title: current.title, description: current.description,
                reviewers: names.map { Reviewer(user: Name(name: $0)) }, draft: current.draft))
    }

    public func addLabels(_ names: [String], to item: HostedItem, in repo: HostedRepository) async throws {
        guard !names.isEmpty else { return }
        throw HostingError.validationFailed(message: "Bitbucket pull requests have no labels")
    }

    public func addAssignees(_ users: [HostedUser], to item: HostedItem, in repo: HostedRepository) async throws {
        guard !users.isEmpty else { return }
        throw HostingError.validationFailed(message: "Bitbucket pull requests have no assignees")
    }

    /// `POST {PR}/comments`.
    public func comment(on item: HostedItem, in repo: HostedRepository, body: String) async throws -> HostedComment {
        guard case .pullRequest(let number) = item else { throw Self.noIssues }
        let comment = try await postComment(body, parent: nil, on: number, in: repo)
        guard let id = comment.id else { throw HostingError.invalidResponse("a comment without an id") }
        var mapped = Self.comment(ThreadComment(comment: comment, id: id, parentID: nil))
        (mapped.viewerCanEdit, mapped.viewerCanDelete) = (true, true)
        return mapped
    }

    /// `POST {PR}/comments` with `parent` the thread's root comment.
    public func reply(to thread: HostedThreadRef, on number: Int, in repo: HostedRepository, body: String)
        async throws -> HostedReviewComment
    {
        let comment = try await postComment(body, parent: thread.rootCommentID, on: number, in: repo)
        guard let id = comment.id else { throw HostingError.invalidResponse("a comment without an id") }
        var mapped = HostedReviewComment(
            id: id, inReplyToID: thread.rootCommentID, path: comment.anchor?.path ?? "", body: comment.text,
            bodyHTML: comment.text.map(MarkdownHTML.html), user: comment.author?.hosted,
            createdAt: Self.date(comment.createdDate), hostKey: comment.version.map(String.init))
        (mapped.viewerCanEdit, mapped.viewerCanDelete) = (true, true)
        return mapped
    }

    /// `PUT {PR}/comments/<root>` with `threadResolved` and the root's current version (`GET {PR}/comments/<root>`
    /// just before), for a thread this client mapped in `reviewThreadStates(of:in:)` (the state has no repository or
    /// pull request). A 409 (the comment changed in between) is `validationFailed` with Data Center's message.
    public func setReviewThread(_ state: HostedReviewThreadState, resolved: Bool) async throws -> Bool {
        guard let root = Int(state.id), let target = memo.pullRequestByThread.withLock({ $0[root] }) else {
            throw HostingError.validationFailed(message: "an unknown Bitbucket thread: reload the pull request")
        }
        return try await setThread(
            target.path + ["pull-requests", String(target.number), "comments", String(root)], resolved: resolved)
    }

    /// `PUT` the root comment at `path` with `threadResolved` and its current version (`GET` just before); a 409 (the
    /// comment changed in between) is `validationFailed` with Data Center's message.
    private func setThread(_ path: [String], resolved: Bool) async throws -> Bool {
        let current: BitbucketDCComment = try await get(url(path))
        guard let version = current.version else {
            throw HostingError.invalidResponse("a comment without a version")
        }
        struct Body: Encodable { var version: Int; var threadResolved: Bool }
        do {
            let comment: BitbucketDCComment = try await send(
                "PUT", url(path), body: Body(version: version, threadResolved: resolved))
            return comment.threadResolved ?? resolved
        } catch HostingError.http(status: 409, let message) {
            throw HostingError.validationFailed(
                message: message.isEmpty ? "the comment changed: reload the pull request" : message)
        }
    }

    /// `APPROVE` and `REQUEST_CHANGES` set the token's user's status first (`PUT {PR}/participants/<slug>`,
    /// `APPROVED` or `NEEDS_WORK`, with the head just read as `lastReviewedCommit`), then post a non-empty body as a
    /// comment, only once the status was accepted; a 400 (the author cannot review their own) is `validationFailed`
    /// with Data Center's message and posts nothing. `COMMENT` posts the body as a comment only. The review's id
    /// follows `reviews(of:in:)`.
    public func review(_ number: Int, in repo: HostedRepository, event: HostedReviewEvent, body: String?)
        async throws -> HostedReview
    {
        let path = try pullRequestPath(number, in: repo)
        let text = body.flatMap { $0.isEmpty ? nil : $0 }
        let slug = try await mySlug()
        if event == .comment {
            guard let text else { throw HostingError.validationFailed(message: "a comment needs a body") }
            let comment = try await postComment(text, parent: nil, on: number, in: repo)
            return HostedReview(
                id: Self.stableID("review", slug), user: comment.author?.hosted, state: "COMMENTED", body: comment.text,
                bodyHTML: comment.text.map(MarkdownHTML.html), submittedAt: Self.date(comment.createdDate))
        }
        let current: BitbucketDCPullRequest = try await get(url(path))
        let approve = event == .approve
        struct Body: Encodable { var status: String; var lastReviewedCommit: String? }
        let participant: BitbucketDCParticipant
        do {
            participant = try await send(
                "PUT", url(path + ["participants", slug]),
                body: Body(
                    status: approve ? "APPROVED" : "NEEDS_WORK", lastReviewedCommit: current.fromRef?.latestCommit))
        } catch HostingError.http(status: 400, let message) {
            throw HostingError.validationFailed(message: message.isEmpty ? "Bitbucket refused the review" : message)
        }
        if let text { _ = try await postComment(text, parent: nil, on: number, in: repo) }
        return HostedReview(
            id: Self.stableID("review", slug), user: participant.user?.hosted,
            state: approve ? "APPROVED" : "CHANGES_REQUESTED", body: text, bodyHTML: text.map(MarkdownHTML.html),
            submittedAt: Date())
    }

    /// Data Center's merge pins no head, so the pull request is read again first: its source's `latestCommit` must
    /// start with `sha` (hex, at least 7 digits, without case), else `HostingError.headChanged`. The method must be one
    /// of the repository's enabled strategies (`GET {R}/settings/pull-requests`), else, when they cannot be read, one
    /// of `mergeMethods`: refused unsent otherwise. Then `POST {PR}/merge?version=N` with the version just read and
    /// the method's strategy id. A 409 (a stale version, conflicts, a veto, not open) reads the pull request again: a
    /// new version or head is `headChanged`, anything else `validationFailed` with Data Center's message.
    public func merge(_ number: Int, in repo: HostedRepository, method: HostedMergeMethod, sha: String) async throws {
        try await merge(number, in: repo, method: method, sha: sha, options: HostedMergeOptions())
    }

    /// Delete source branch (`deleteSourceBranch`), a call of its own after the merge.
    public var supportedMergeOptions: Set<HostedMergeOption> { [.deleteSourceBranch] }

    /// `merge(_:in:method:sha:)`, then, with `options.deleteSourceBranch` true, `DELETE
    /// /rest/branch-utils/latest/projects/<P>/repos/<r>/branches` in the source's own repository, with the head read
    /// before the merge as `endPoint` (so a branch that moved since is kept). Refused unsent for a pull request from
    /// a fork. The merge is done once Data Center took it: a delete it then refuses is not a failure of the merge.
    public func merge(
        _ number: Int, in repo: HostedRepository, method: HostedMergeMethod, sha: String, options: HostedMergeOptions
    ) async throws {
        guard sha.count >= 7, sha.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw HostingError.headChanged }
        let path = try pullRequestPath(number, in: repo)
        let (current, version) = try await versioned(path)
        let latest = current.fromRef?.latestCommit ?? ""
        let head = latest.lowercased()
        guard head.count >= 7, head.hasPrefix(sha.lowercased()) else { throw HostingError.headChanged }
        var deletion: (key: String, slug: String, branch: String)?
        if options.deleteSourceBranch == true {
            let source = current.fromRef?.repository
            guard Self.isSameRepository(current), let key = source?.project?.key, let slug = source?.slug,
                let branch = current.fromRef?.id, branch.hasPrefix("refs/heads/")
            else {
                throw HostingError.validationFailed(message: "the source branch of a fork can't be deleted here")
            }
            deletion = (key, slug, branch)
        }
        guard let strategy = Self.strategyID(of: method),
            await strategies(in: repo)?.enabled.contains(strategy) ?? mergeMethods.contains(method)
        else {
            throw HostingError.validationFailed(message: "this repository does not allow this merge strategy")
        }
        struct Body: Encodable { var version: Int; var strategyId: String }
        do {
            _ = try await perform(
                "POST", url(path + ["merge"], query: [("version", String(version))]),
                body: try JSONEncoder().encode(Body(version: version, strategyId: strategy)))
        } catch HostingError.http(status: 409, let message) {
            let now: BitbucketDCPullRequest? = try? await get(url(path))
            if let now, now.version != version || (now.fromRef?.latestCommit ?? "").lowercased() != head {
                throw HostingError.headChanged
            }
            throw HostingError.validationFailed(message: message.isEmpty ? "Bitbucket did not merge it" : message)
        }
        guard let deletion else { return }
        struct Delete: Encodable { var name: String; var endPoint: String; var dryRun = false }
        // Merged: a branch Data Center keeps (it moved, or the user may not delete it) stays, without an error.
        _ = try? await perform(
            "DELETE", url(["projects", deletion.key, "repos", deletion.slug, "branches"], under: branchUtilsBase),
            body: try JSONEncoder().encode(Delete(name: deletion.branch, endPoint: latest)))
    }

    /// Declines (`POST {PR}/decline`) or reopens (`POST {PR}/reopen`) a pull request, each with the version just read
    /// (as `?version=N` and in the body); Data Center has no issues.
    public func setOpen(_ open: Bool, item: HostedItem, in repo: HostedRepository) async throws {
        guard case .pullRequest(let number) = item else { throw Self.noIssues }
        let path = try pullRequestPath(number, in: repo)
        let (_, version) = try await versioned(path)
        struct Body: Encodable { var version: Int }
        _ = try await perform(
            "POST", url(path + [open ? "reopen" : "decline"], query: [("version", String(version))]),
            body: try JSONEncoder().encode(Body(version: version)))
    }

    private static let noIssues = HostingError.validationFailed(message: "Bitbucket issues are not supported")

    // MARK: - Comment interactions

    /// `POST {PR}/comments` with `parent` the general comment answered (any comment: Data Center nests to any depth).
    /// A review comment's ref is refused unsent (`reply(to:on:in:body:)` answers inline threads).
    public func reply(
        toGeneral comment: HostedCommentRef, on item: HostedItem, in repo: HostedRepository, body: String
    ) async throws -> HostedComment {
        let number = try Self.generalTarget(comment, on: item)
        let reply = try await postComment(body, parent: comment.id, on: number, in: repo)
        guard let id = reply.id else { throw HostingError.invalidResponse("a comment without an id") }
        var mapped = Self.comment(ThreadComment(comment: reply, id: id, parentID: comment.id))
        (mapped.viewerCanEdit, mapped.viewerCanDelete) = (true, true)
        return mapped
    }

    /// `PUT {PR}/comments/<root>` with `threadResolved` and the root's current version, as `setReviewThread`.
    public func setGeneralThread(
        _ root: HostedCommentRef, on item: HostedItem, in repo: HostedRepository, resolved: Bool
    ) async throws -> Bool {
        let number = try Self.generalTarget(root, on: item)
        return try await setThread(
            try pullRequestPath(number, in: repo) + ["comments", String(root.id)], resolved: resolved)
    }

    /// `PUT {PR}/comments/<id>` with the new `text` and the version the comment was loaded at (its `hostKey`), a
    /// general or an inline comment alike. A 409 (it changed since) is `validationFailed` with Data Center's message
    /// and a reload hint.
    public func editComment(_ comment: HostedCommentRef, on item: HostedItem, in repo: HostedRepository, body: String)
        async throws
    {
        guard case .pullRequest(let number) = item else { throw Self.noIssues }
        let version = try Self.version(of: comment)
        struct Body: Encodable { var version: Int; var text: String }
        do {
            let _: BitbucketDCComment = try await send(
                "PUT", url(try pullRequestPath(number, in: repo) + ["comments", String(comment.id)]),
                body: Body(version: version, text: body))
        } catch HostingError.http(status: 409, let message) {
            throw HostingError.validationFailed(
                message: message.isEmpty ? "the comment changed: reload the pull request"
                    : message + (message.hasSuffix(".") ? " " : ". ") + "Reload the pull request.")
        }
    }

    /// `DELETE {PR}/comments/<id>?version=N` with the version the comment was loaded at (its `hostKey`), answered 204
    /// without a body. A 409 (it has replies, or it changed since) is `validationFailed` with Data Center's message.
    public func deleteComment(_ comment: HostedCommentRef, on item: HostedItem, in repo: HostedRepository)
        async throws
    {
        guard case .pullRequest(let number) = item else { throw Self.noIssues }
        let version = try Self.version(of: comment)
        do {
            _ = try await perform(
                "DELETE",
                url(try pullRequestPath(number, in: repo) + ["comments", String(comment.id)],
                    query: [("version", String(version))]))
        } catch HostingError.http(status: 409, let message) {
            throw HostingError.validationFailed(
                message: message.isEmpty ? "Bitbucket did not delete the comment: reload the pull request" : message)
        }
    }

    /// `POST {PR}/comments` with an `anchor` on one line of the effective diff (`diffType` `EFFECTIVE`, no commit
    /// hashes): an added line is `fileType` `TO`, `lineType` `ADDED` at its new line; a context line `TO`, `CONTEXT`
    /// at its new line; a removed line `FROM`, `REMOVED` at its old line. `srcPath` is the old path of a renamed file
    /// only. Refused unsent when the line is missing on its side, or for a range (Data Center anchors one line).
    public func createInlineComment(
        at position: HostedInlinePosition, on number: Int, in repo: HostedRepository, body: String
    ) async throws -> HostedReviewComment {
        struct Anchor: Encodable {
            var path: String
            var srcPath: String?
            var line: Int
            var lineType, fileType: String
            var diffType = "EFFECTIVE"
        }
        struct Body: Encodable { var text: String; var anchor: Anchor }
        guard position.startOldLine == nil && position.startNewLine == nil else {
            throw HostingError.validationFailed(message: "Bitbucket Data Center comments on one line only")
        }
        let newSide = position.lineKind != .removed
        guard let line = newSide ? position.newLine : position.oldLine else {
            throw HostingError.validationFailed(message: "no line on the \(newSide ? "new" : "old") side")
        }
        let lineType = switch position.lineKind {
        case .added: "ADDED"
        case .removed: "REMOVED"
        case .context: "CONTEXT"
        }
        let anchor = Anchor(
            path: position.path, srcPath: position.oldPath.flatMap { $0 == position.path ? nil : $0 }, line: line,
            lineType: lineType, fileType: newSide ? "TO" : "FROM")
        let comment: BitbucketDCComment = try await send(
            "POST", url(try pullRequestPath(number, in: repo) + ["comments"]),
            body: Body(text: body, anchor: anchor))
        guard let id = comment.id else { throw HostingError.invalidResponse("a comment without an id") }
        var mapped = HostedReviewComment(
            id: id, inReplyToID: nil, path: comment.anchor?.path ?? position.path, line: line, originalLine: line,
            side: newSide ? "RIGHT" : "LEFT", body: comment.text, bodyHTML: comment.text.map(MarkdownHTML.html),
            user: comment.author?.hosted, createdAt: Self.date(comment.createdDate),
            hostKey: comment.version.map(String.init))
        (mapped.viewerCanEdit, mapped.viewerCanDelete) = (true, true)
        return mapped
    }

    /// The pull request number of a general comment write; an issue or a review comment's ref is refused unsent.
    private static func generalTarget(_ comment: HostedCommentRef, on item: HostedItem) throws -> Int {
        guard case .pullRequest(let number) = item else { throw noIssues }
        guard comment.kind == .general else {
            throw HostingError.validationFailed(message: "not a general Bitbucket comment")
        }
        return number
    }

    /// The version a comment was loaded at, its `hostKey`; a ref without one is refused unsent.
    private static func version(of comment: HostedCommentRef) throws -> Int {
        guard let version = comment.hostKey.flatMap({ Int($0) }) else {
            throw HostingError.validationFailed(
                message: "a Bitbucket comment without its version: reload the pull request")
        }
        return version
    }

    /// Data Center's strategy ids and the methods they are, one to one.
    private static let strategies: [(id: String, method: HostedMergeMethod)] = [
        ("no-ff", .merge), ("ff-only", .fastForward), ("rebase-no-ff", .rebase),
        ("rebase-ff-only", .rebaseFastForward), ("squash", .squash), ("squash-ff-only", .squashFastForward),
        ("ff", .fastForwardIfPossible),
    ]

    /// The strategy id `POST {PR}/merge` takes for `method`.
    static func strategyID(of method: HostedMergeMethod) -> String? {
        strategies.first { $0.method == method }?.id
    }

    /// The method of strategy `id`; nil for an id Histq does not know.
    static func method(ofStrategy id: String?) -> HostedMergeMethod? {
        strategies.first { $0.id == id }?.method
    }

    /// The ids of the repository's enabled strategies in Data Center's order, and its default; nil when they cannot
    /// be read (no right, an error, an answer without them) or none is enabled.
    private func strategies(in repo: HostedRepository) async -> (enabled: [String], default: String?)? {
        guard let path = try? repoPath(repo),
            let settings: BitbucketDCPullRequestSettings = try? await get(url(path + ["settings", "pull-requests"]))
        else { return nil }
        let enabled = (settings.mergeConfig?.strategies ?? []).filter { $0.enabled != false }.compactMap(\.id)
        return enabled.isEmpty ? nil : (enabled, settings.mergeConfig?.defaultStrategy?.id)
    }

    /// A pull request's allowed methods from the repository's enabled strategies (unknown ids left out; none left
    /// reads as nil), and its default when that is one of them.
    static func mergeMethods(_ strategies: (enabled: [String], default: String?)?)
        -> (allowed: [HostedMergeMethod]?, default: HostedMergeMethod?)
    {
        let allowed = (strategies?.enabled ?? []).compactMap { method(ofStrategy: $0) }
        guard !allowed.isEmpty else { return (nil, nil) }
        let preferred = method(ofStrategy: strategies?.default)
        return (allowed, preferred.flatMap { allowed.contains($0) ? $0 : nil })
    }

    /// The pull request at `path` read again, with its `version` (which a write on it sends).
    private func versioned(_ path: [String]) async throws -> (BitbucketDCPullRequest, Int) {
        let pr: BitbucketDCPullRequest = try await get(url(path))
        guard let version = pr.version else { throw HostingError.invalidResponse("a pull request without a version") }
        return (pr, version)
    }

    /// The token's user's slug, asked once (`currentUser()`).
    private func mySlug() async throws -> String {
        if let slug = memo.userSlug.withLock({ $0 }) { return slug }
        guard let slug = try await currentUser().reviewerID, !slug.isEmpty else {
            throw HostingError.invalidResponse("a user without a slug")
        }
        return slug
    }

    /// `POST {PR}/comments` with `text`, and `parent` the comment answered.
    private func postComment(_ text: String, parent: Int?, on number: Int, in repo: HostedRepository)
        async throws -> BitbucketDCComment
    {
        struct Parent: Encodable { var id: Int }
        struct Body: Encodable { var text: String; var parent: Parent? }
        return try await send(
            "POST", url(try pullRequestPath(number, in: repo) + ["comments"]),
            body: Body(text: text, parent: parent.map(Parent.init)))
    }

    // MARK: - Activity, tasks and merge checks

    /// The entries of `GET {PR}/activities` that are not comments (read on their own), in Data Center's order (newest
    /// first): "approved", "removed their approval", "requested changes" (`REVIEWED`, Data Center's Needs work), "added
    /// N commits" and "removed N commits" (`RESCOPED`, one entry each, its commits listed under it), "merged",
    /// "declined", "reopened", "opened" and "updated the pull request"; any other action in its own words
    /// (`AUTO_MERGE_REQUESTED` "auto merge requested"). Histq's words and the commit messages are escaped in `textHTML`
    /// and `detailHTML`.
    public func timelineEvents(of item: HostedItem, in repo: HostedRepository) async throws -> [HostedTimelineEvent] {
        guard case .pullRequest(let number) = item else { throw Self.noIssues }
        let activities: [BitbucketDCActivity] = try await list(
            url(try pullRequestPath(number, in: repo) + ["activities"]))
        return Self.events(activities) { [self] sha in webURL(.commit(sha), in: repo)?.absoluteString }
    }

    /// `timelineEvents`' entries from `activities`, each id from the entry's own (its index when it has none).
    static func events(_ activities: [BitbucketDCActivity], commitURL: (String) -> String?) -> [HostedTimelineEvent] {
        var events: [HostedTimelineEvent] = []
        for (index, activity) in activities.enumerated() {
            guard let action = activity.action, !action.isEmpty, action != "COMMENTED" else { continue }
            let id = "activity-" + (activity.id.map(String.init) ?? "at-\(index)")
            func add(_ suffix: String, _ text: String, action: String, detail: String? = nil) {
                events.append(HostedTimelineEvent(
                    id: id + suffix, actor: activity.user?.hosted, createdAt: date(activity.createdDate), text: text,
                    textHTML: "<p>\(MarkdownHTML.escape(text))</p>", action: action, detailHTML: detail))
            }
            switch action {
            case "APPROVED": add("", "approved", action: "approved")
            case "UNAPPROVED": add("", "removed their approval", action: "unapproved")
            case "REVIEWED": add("", "requested changes", action: "changes_requested")
            case "RESCOPED":
                for (verb, commits) in [("added", activity.added), ("removed", activity.removed)] {
                    let count = commits?.total ?? commits?.commits?.count ?? 0
                    guard count > 0 else { continue }
                    // A removed commit may be gone from the server: only the added ones link to their page.
                    let listed = commits?.commits ?? []
                    add("-" + verb, "\(verb) \(count) \(count == 1 ? "commit" : "commits")", action: "commit",
                        detail: listed.isEmpty ? nil : commitList(listed) { verb == "added" ? commitURL($0) : nil })
                }
            case "MERGED": add("", "merged", action: "merged")
            case "DECLINED": add("", "declined", action: "declined")
            case "REOPENED": add("", "reopened", action: "reopened")
            case "OPENED": add("", "opened", action: "opened")
            case "UPDATED": add("", "updated the pull request", action: "updated")
            default: add("", action.lowercased().replacingOccurrences(of: "_", with: " "), action: action.lowercased())
            }
        }
        return events
    }

    /// A rescope's commits, one line each: the short id (linked through `link` when it gives a page) and the
    /// message's first line, escaped.
    private static func commitList(
        _ commits: [BitbucketDCActivity.Commits.Commit], link: (String) -> String?
    ) -> String {
        commits.map { commit in
            let id = commit.id ?? ""
            let short = MarkdownHTML.escape(commit.displayId ?? String(id.prefix(7)))
            let linked = link(id).map { "<a href=\"\(MarkdownHTML.escape($0))\">\(short)</a>" } ?? short
            let subject = commit.message?.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            return "<p>\(linked) \(MarkdownHTML.escape(subject))</p>"
        }.joined()
    }

    /// `GET {PR}/blocker-comments` (Data Center's tasks, open and resolved), oldest first; a task made on a comment
    /// has its `commentID`.
    public func tasks(of number: Int, in repo: HostedRepository) async throws -> [HostedTask] {
        let comments: [BitbucketDCComment] = try await list(
            url(try pullRequestPath(number, in: repo) + ["blocker-comments"]))
        return comments.sorted { ($0.createdDate ?? 0, $0.id ?? 0) < ($1.createdDate ?? 0, $1.id ?? 0) }
            .compactMap(Self.task)
    }

    /// `POST {PR}/blocker-comments` with the text.
    public func createTask(on number: Int, in repo: HostedRepository, body: String) async throws -> HostedTask {
        struct Body: Encodable { var text: String }
        let comment: BitbucketDCComment = try await Self.refusingConflict {
            try await send(
                "POST", url(try pullRequestPath(number, in: repo) + ["blocker-comments"]), body: Body(text: body))
        }
        guard let task = Self.task(comment) else { throw HostingError.invalidResponse("a task without an id") }
        return task
    }

    /// `PUT {PR}/blocker-comments/{id}` with `state` `RESOLVED` or `OPEN` and the task's current version (`GET` just
    /// before); a 409 is `validationFailed` with Data Center's message.
    public func setTask(_ id: Int, resolved: Bool, on number: Int, in repo: HostedRepository) async throws {
        let path = try pullRequestPath(number, in: repo) + ["blocker-comments", String(id)]
        let version = try await commentVersion(path)
        struct Body: Encodable { var version: Int; var state: String }
        let _: BitbucketDCComment = try await Self.refusingConflict {
            try await send("PUT", url(path), body: Body(version: version, state: resolved ? "RESOLVED" : "OPEN"))
        }
    }

    /// `DELETE {PR}/blocker-comments/{id}?version=N` with the task's current version (`GET` just before); a 409 is
    /// `validationFailed` with Data Center's message.
    public func deleteTask(_ id: Int, on number: Int, in repo: HostedRepository) async throws {
        let path = try pullRequestPath(number, in: repo) + ["blocker-comments", String(id)]
        let version = try await commentVersion(path)
        _ = try await Self.refusingConflict {
            try await perform("DELETE", url(path, query: [("version", String(version))]))
        }
    }

    /// The current version of the comment at `path`.
    private func commentVersion(_ path: [String]) async throws -> Int {
        let current: BitbucketDCComment = try await get(url(path))
        guard let version = current.version else { throw HostingError.invalidResponse("a comment without a version") }
        return version
    }

    /// `work`, with Data Center's 409 (the task changed since, or it has replies) as `validationFailed` with its
    /// message.
    private static func refusingConflict<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch HostingError.http(status: 409, let message) {
            throw HostingError.validationFailed(
                message: message.isEmpty ? "the task changed: reload the pull request" : message)
        }
    }

    /// A blocker comment as a task: resolved when its `state` is `RESOLVED`, on its `parent` comment if any.
    private static func task(_ comment: BitbucketDCComment) -> HostedTask? {
        guard let id = comment.id else { return nil }
        return HostedTask(
            id: id, body: comment.text ?? "", isResolved: comment.state == "RESOLVED", creator: comment.author?.hosted,
            createdAt: date(comment.createdDate), commentID: comment.parent?.id,
            resolvedAt: date(comment.resolvedDate), resolvedBy: comment.resolver?.hosted)
    }

    /// `GET {PR}/merge`: one failing, blocking check per veto, named by its summary, and "Conflicts" when the pull
    /// request has conflicts; none for a pull request that is not open (409).
    public func mergeChecks(of number: Int, in repo: HostedRepository) async throws -> [HostedMergeCheck] {
        let status: BitbucketDCMergeStatus
        do {
            status = try await get(url(try pullRequestPath(number, in: repo) + ["merge"]))
        } catch HostingError.http(status: 409, message: _) {
            return []
        }
        var checks = (status.vetoes ?? []).map { veto in
            HostedMergeCheck(
                name: veto.summaryMessage ?? veto.detailedMessage ?? "Merge check", status: "FAILED", required: true,
                blocking: true)
        }
        if status.conflicted == true {
            checks.append(HostedMergeCheck(name: "Conflicts", status: "FAILED", required: true, blocking: true))
        }
        return checks
    }

    // MARK: - Mapping

    /// The head's `owner:branch` label is set only for a branch of the same repository (nil for a fork's, or when
    /// Data Center leaves out the repositories). The requested reviewers are those who have not reviewed yet
    /// (`UNAPPROVED`). A merged pull request's `mergedAt` is its `closedDate`. `mergeable` is left unknown (the merge
    /// state is a call of its own). The pull request's `version` is not kept: a write reads it again.
    private func pullRequest(_ pr: BitbucketDCPullRequest, in repo: HostedRepository) -> HostedPullRequest {
        let source = Self.branchName(pr.fromRef?.id, display: pr.fromRef?.displayId) ?? ""
        let target = Self.branchName(pr.toRef?.id, display: pr.toRef?.displayId) ?? ""
        let merged = pr.state == "MERGED"
        let waiting = (pr.reviewers ?? []).filter { $0.status != "APPROVED" && $0.status != "NEEDS_WORK" }
        return HostedPullRequest(
            id: pr.id, number: pr.id, title: pr.title ?? "", state: pr.state == "OPEN" ? "open" : "closed",
            draft: pr.draft, user: pr.author?.user?.hosted, body: pr.description,
            bodyHTML: pr.description.map(MarkdownHTML.html),
            htmlURL: webURL(.pullRequest(pr.id), in: repo)?.absoluteString ?? "",
            head: HostedBranchRef(
                label: Self.isSameRepository(pr) ? repo.owner + ":" + source : nil, ref: source,
                sha: pr.fromRef?.latestCommit ?? ""),
            base: HostedBranchRef(label: repo.owner + ":" + target, ref: target, sha: pr.toRef?.latestCommit ?? ""),
            requestedReviewers: waiting.compactMap { $0.user?.hosted }, createdAt: Self.date(pr.createdDate),
            updatedAt: Self.date(pr.updatedDate), mergedAt: merged ? Self.date(pr.closedDate) : nil, merged: merged)
    }

    /// The branch of a ref: `id` without `refs/heads/`, else `display`.
    private static func branchName(_ id: String?, display: String?) -> String? {
        if let id, id.hasPrefix("refs/heads/") { return String(id.dropFirst("refs/heads/".count)) }
        return display
    }

    /// Whether `repository` is `repo` (the project key and the slug, without case).
    private static func isRepository(_ repository: BitbucketDCRepository?, _ repo: HostedRepository) -> Bool {
        guard let key = repository?.project?.key, let slug = repository?.slug, repo.path.count == 2 else {
            return false
        }
        return key.lowercased() == repo.path[0].lowercased() && slug.lowercased() == repo.path[1].lowercased()
    }

    /// Whether the source branch is in the destination repository (project key and slug, without case).
    private static func isSameRepository(_ pr: BitbucketDCPullRequest) -> Bool {
        guard let key = pr.fromRef?.repository?.project?.key, let slug = pr.fromRef?.repository?.slug else {
            return false
        }
        return isRepository(pr.toRef?.repository, HostedRepository(host: "", path: [key, slug]))
    }

    /// `reviews(of:in:)`'s reviews from a pull request's reviewers and participants (each user once).
    static func reviews(_ pr: BitbucketDCPullRequest) -> [HostedReview] {
        var seen: Set<String> = []
        var rows: [(key: String, review: HostedReview)] = []
        for participant in (pr.reviewers ?? []) + (pr.participants ?? []) {
            guard let user = participant.user, let key = user.slug ?? user.name, seen.insert(key).inserted else {
                continue
            }
            let state = switch participant.status {
            case "APPROVED": "APPROVED"
            case "NEEDS_WORK": "CHANGES_REQUESTED"
            default: participant.approved == true ? "APPROVED" : ""
            }
            guard !state.isEmpty else { continue }
            rows.append((key, HostedReview(id: stableID("review", key), user: user.hosted, state: state)))
        }
        return rows.sorted { $0.key < $1.key }.map(\.review)
    }

    /// The open pull requests of the token's user in `role` (`GET /dashboard/pull-requests`), those into `repo` only,
    /// as issue-shaped rows (`pullRequest` and `draft` set).
    private func dashboardPullRequests(role: String, in repo: HostedRepository) async throws -> [HostedIssue] {
        _ = try repoPath(repo)
        let prs: [BitbucketDCPullRequest] = try await list(
            url(["dashboard", "pull-requests"], query: [("role", role), ("state", "OPEN")]))
        return prs.filter { Self.isRepository($0.toRef?.repository, repo) }.map { pr in
            let pull = pullRequest(pr, in: repo)
            return HostedIssue(
                id: pull.id, number: pull.number, title: pull.title, state: pull.state, user: pull.user,
                body: pull.body, htmlURL: pull.htmlURL, comments: pr.properties?.commentCount,
                createdAt: pull.createdAt, updatedAt: pull.updatedAt, pullRequest: .init(url: pull.htmlURL),
                draft: pull.draft)
        }
    }

    /// A repository with an https `http` clone link that names it on this instance.
    private func cloneRepository(_ repository: BitbucketDCRepository) -> HostedCloneRepository? {
        guard let link = repository.links?.clone?.first(where: { $0.name == "http" })?.href,
            link.lowercased().hasPrefix("https://"),
            let named = Self.repository(fromRemoteURL: link, basePath: basePath.joined(separator: "/")),
            named.host == host
        else { return nil }
        let key = named.path[0]
        return HostedCloneRepository(
            id: repository.id ?? Self.stableID("repository", named.fullName), name: named.name,
            fullName: named.fullName, owner: HostedUser(id: Self.stableID("project", key), login: key),
            cloneURL: link, isPrivate: !(repository.public ?? false), fork: repository.origin.map { _ in true })
    }

    // MARK: - Threads

    /// A comment of a thread, with the comment it answers directly (nil for the root).
    struct ThreadComment {
        var comment: BitbucketDCComment
        var id: Int
        var parentID: Int?
    }

    /// A comment thread: its root's anchor (nil for a general comment) and its comments, the root first, then its
    /// replies (any depth) oldest first.
    struct CommentThread {
        var rootID: Int
        var anchor: BitbucketDCAnchor?
        var comments: [ThreadComment]

        /// An inline thread: its anchor names a file.
        var isInline: Bool { !(anchor?.path ?? "").isEmpty }
    }

    private func threads(of number: Int, in repo: HostedRepository) async throws -> [CommentThread] {
        let activities: [BitbucketDCActivity] = try await list(
            url(try pullRequestPath(number, in: repo) + ["activities"]))
        return Self.threads(activities)
    }

    /// The comment threads of a pull request's activities, oldest root first. Only `COMMENTED` entries count; several
    /// can carry the same comment (added, replied to, edited), so a root is kept once, at its highest `version`, and a
    /// comment some entry nests as a reply is never a root. The anchor is the entry's `commentAnchor`, else the
    /// comment's own. Left out: deleted comments (a `DELETED` entry), pending ones (a draft only its author sees) and
    /// tasks (`BLOCKER`), each with the replies under it.
    static func threads(_ activities: [BitbucketDCActivity]) -> [CommentThread] {
        let commented = activities.filter { $0.action == "COMMENTED" }
        let deleted = Set(commented.filter { $0.commentAction == "DELETED" }.compactMap(\.comment?.id))
        var nested: Set<Int> = []
        for activity in commented {
            var stack = activity.comment?.comments ?? []
            while let next = stack.popLast() {
                if let id = next.id { nested.insert(id) }
                stack += next.comments ?? []
            }
        }
        var roots: [Int: (comment: BitbucketDCComment, anchor: BitbucketDCAnchor?)] = [:]
        for activity in commented where activity.commentAction != "DELETED" {
            guard let comment = activity.comment, let id = comment.id, !nested.contains(id), !deleted.contains(id)
            else { continue }
            let anchor = activity.commentAnchor ?? comment.anchor ?? roots[id]?.anchor
            if let kept = roots[id], (kept.comment.version ?? 0) >= (comment.version ?? 0) {
                roots[id]?.anchor = anchor
                continue
            }
            roots[id] = (comment, anchor)
        }
        func isShown(_ comment: BitbucketDCComment) -> Bool {
            comment.state != "PENDING" && comment.severity != "BLOCKER" && !(comment.id.map(deleted.contains) ?? true)
        }
        func isOlder(_ a: ThreadComment, _ b: ThreadComment) -> Bool {
            (a.comment.createdDate ?? 0, a.id) < (b.comment.createdDate ?? 0, b.id)
        }
        return roots.filter { isShown($0.value.comment) }
            .map { id, root -> CommentThread in
                var seen: Set<Int> = [id]
                var replies: [ThreadComment] = []
                var stack = (root.comment.comments ?? []).map { ($0, id) }
                while let (comment, parent) = stack.popLast() {
                    guard isShown(comment), let replyID = comment.id, seen.insert(replyID).inserted else { continue }
                    replies.append(ThreadComment(comment: comment, id: replyID, parentID: parent))
                    stack += (comment.comments ?? []).map { ($0, replyID) }
                }
                let first = ThreadComment(comment: root.comment, id: id, parentID: nil)
                return CommentThread(rootID: id, anchor: root.anchor, comments: [first] + replies.sorted(by: isOlder))
            }
            .sorted { isOlder($0.comments[0], $1.comments[0]) }
    }

    /// A general comment: `parentID` its direct parent, a root `resolvable` where Data Center says whether its thread
    /// is resolved, rights from `permittedOperations`, and its version as `hostKey`.
    private static func comment(_ entry: ThreadComment) -> HostedComment {
        let comment = entry.comment
        let isRoot = entry.parentID == nil
        var mapped = HostedComment(
            id: entry.id, user: comment.author?.hosted, body: comment.text,
            bodyHTML: comment.text.map(MarkdownHTML.html), createdAt: date(comment.createdDate),
            updatedAt: date(comment.updatedDate), parentID: entry.parentID,
            resolvable: isRoot ? comment.threadResolved != nil : nil, resolved: isRoot ? comment.threadResolved : nil,
            hostKey: comment.version.map(String.init))
        mapped.viewerCanEdit = comment.permittedOperations?.editable ?? false
        mapped.viewerCanDelete = comment.permittedOperations?.deletable ?? false
        if isRoot, comment.threadResolved == true {
            mapped.resolvedBy = comment.threadResolver?.hosted
            mapped.resolvedAt = date(comment.threadResolvedDate)
        }
        return mapped
    }

    // MARK: - Diffs

    /// `diff` with Data Center's `src://` and `dst://` path prefixes as git's `a/` and `b/` (which `DiffReader`
    /// reads), only on a file's header lines (`diff --git`, `---`, `+++` before its first `@@`), quoted names too. A
    /// diff with git's prefixes is unchanged.
    static func gitPrefixes(_ diff: Data) -> Data {
        let newline = UInt8(ascii: "\n")
        var inHeader = false
        var lines: [Data] = []
        for slice in diff.split(separator: newline, omittingEmptySubsequences: false) {
            var line = Data(slice)
            if line.starts(with: "diff --git ".utf8) {
                inHeader = true
                line = swapping(line, at: 11, "src://", "a/")
                for marker in [" \"dst://", " dst://"] {
                    guard let range = line.range(of: Data(marker.utf8), options: .backwards) else { continue }
                    line.replaceSubrange((range.upperBound - 6)..<range.upperBound, with: Data("b/".utf8))
                    break
                }
            } else if line.starts(with: "@@".utf8) {
                inHeader = false
            } else if inHeader, line.starts(with: "--- ".utf8) {
                line = swapping(line, at: 4, "src://", "a/")
            } else if inHeader, line.starts(with: "+++ ".utf8) {
                line = swapping(line, at: 4, "dst://", "b/")
            }
            lines.append(line)
        }
        return Data(lines.joined(separator: [newline]))
    }

    /// `line` with `old` as `new` where `old` (or `"` and then `old`) starts at byte `offset`; else unchanged.
    private static func swapping(_ line: Data, at offset: Int, _ old: String, _ new: String) -> Data {
        var start = line.startIndex + offset
        if start < line.endIndex, line[start] == UInt8(ascii: "\"") { start += 1 }
        guard start <= line.endIndex, line[start...].starts(with: old.utf8) else { return line }
        var result = line
        result.replaceSubrange(start..<(start + old.utf8.count), with: Data(new.utf8))
        return result
    }

    // MARK: - Requests

    /// A path segment's characters: `urlPathAllowed` without `/`, so a `/` inside a segment is encoded.
    private static let segmentAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return allowed
    }()

    /// A web query value's characters: ASCII letters, digits, `-`, `.`, `_` and `~` (so `/` is `%2F`).
    private static let queryValueAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// `projects/<key>/repos/<slug>` for a repository on this instance named by exactly two segments, none empty, `.`
    /// or `..` (each is percent-encoded as one segment by `url`; a `~user` key is used as given).
    private func repoPath(_ repo: HostedRepository) throws -> [String] {
        guard repo.host.lowercased() == host else { throw HostingError.wrongHost(repo.host) }
        guard repo.path.count == 2, !repo.path.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw HostingError.validationFailed(message: "not a repository path: \(repo.path.joined(separator: "/"))")
        }
        return ["projects", repo.path[0], "repos", repo.path[1]]
    }

    private func pullRequestPath(_ number: Int, in repo: HostedRepository) throws -> [String] {
        try repoPath(repo) + ["pull-requests", String(number)]
    }

    /// `base` (`apiBase` unless given) plus `segments`, each percent-encoded as one path segment, and `query` in order,
    /// with `+` as `%2B` so it never reads as a space.
    private func url(_ segments: [String], query: [(String, String)] = [], under base: URL? = nil) -> URL {
        var components = URLComponents(url: base ?? apiBase, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath += segments
            .map { "/" + ($0.addingPercentEncoding(withAllowedCharacters: Self.segmentAllowed) ?? "") }.joined()
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return components.url!
    }

    /// The percent-encoded path of the base `url` is under (`apiBase`, `buildStatusBase` or `branchUtilsBase`: the
    /// same origin, and that path plus whole segments, none `.` or `..`); nil when it is under none.
    private func basePrefix(of url: URL) -> String? {
        [apiBase, buildStatusBase, branchUtilsBase].first { base in
            HostingHTTP.isSameOrigin(url, base) && HostingHTTP.isPath(of: url, under: base.path(percentEncoded: true))
        }?.path(percentEncoded: true)
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HostingError.invalidResponse("unexpected JSON for \(T.self)")
        }
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let (data, _) = try await perform("GET", url)
        return try Self.decode(data)
    }

    private func send<T: Decodable>(_ method: String, _ url: URL, body: some Encodable) async throws -> T {
        let (data, _) = try await perform(method, url, body: try JSONEncoder().encode(body))
        return try Self.decode(data)
    }

    /// Reads `first` page by page (`limit=100`, then `start` at each page's `nextPageStart`) until the last page, a
    /// `nextPageStart` that does not move forward, or `maxPages` pages.
    private func list<T: Decodable>(_ first: URL) async throws -> [T] {
        var result: [T] = []
        var start = 0
        for _ in 0..<maxPages {
            var components = URLComponents(url: first, resolvingAgainstBaseURL: false)!
            components.percentEncodedQueryItems = (components.percentEncodedQueryItems ?? [])
                + [URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "start", value: String(start))]
            let page: BitbucketDCPage<T> = try await get(components.url!)
            result += page.values ?? []
            guard page.isLastPage == false, let next = page.nextPageStart, next > start else { break }
            start = next
        }
        return result
    }

    /// The one place a request is made and the token attached, only to a URL under one of the three bases. A
    /// 401 asks the provider for the token again and retries once; a second 401 is `unauthorized`.
    private func perform(_ method: String, _ url: URL, body: Data? = nil, accept: String = "application/json")
        async throws -> (Data, HTTPURLResponse)
    {
        guard let prefix = basePrefix(of: url) else { throw HostingError.invalidResponse("a URL outside the API") }
        let token = try await self.token(nil)
        var (data, response) = try await load(method, url, body: body, accept: accept, token: token, prefix: prefix)
        if response.statusCode == 401 {
            (data, response) = try await load(
                method, url, body: body, accept: accept, token: try await self.token(token), prefix: prefix)
        }
        guard (200..<300).contains(response.statusCode) else { throw HostingHTTP.error(for: response, data: data) }
        return (data, response)
    }

    /// A redirect is followed only on the same origin and under `prefix`, the request's own base.
    private func load(_ method: String, _ url: URL, body: Data?, accept: String, token: String, prefix: String)
        async throws -> (Data, HTTPURLResponse)
    {
        guard HostingHTTP.isUsableToken(token) else { throw HostingError.invalidToken }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Histq", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return try await HostingHTTP.load(request, session: session, allowedPathPrefix: prefix)
    }
}
