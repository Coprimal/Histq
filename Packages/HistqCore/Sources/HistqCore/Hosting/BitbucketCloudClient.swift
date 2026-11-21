// Bitbucket Cloud's API 2.0 (`https://api.bitbucket.org/2.0`), mapped into the hosted models. The `URLSession` is
// injected, so tests serve inline JSON through a stub `URLProtocol` and never reach the network. A repository is
// `bitbucket.org/<workspace>/<repo_slug>`: a `HostedRepository`'s `path` is exactly those two segments.
//
// The token is a secret: the client asks its provider for it on every request (a constant for an API token, a
// refresher for OAuth), and after a 401 asks once more with the refused token and retries that request once. It only
// ever goes in the `Authorization` header of a request under `apiBase` (its origin and `/2.0`): a `next` page URL
// outside it is refused, a redirect to another origin or outside `/2.0` is not followed (the diff's redirect to the
// repository diff is), a merge's `Location` is never requested (only its task id is read from it), no error or
// description holds it, and `print`, `dump` and `String(reflecting:)` of a client show only its host.
import Foundation
import Synchronization

public struct BitbucketCloudClient: HostingProvider, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    /// Hands out the access token: `rejected` is the token a 401 just refused, so a refreshable one is renewed unless
    /// it already was (a constant API token ignores it); nil otherwise.
    public typealias TokenProvider = @Sendable (_ rejected: String?) async throws -> String

    /// The host of every Bitbucket Cloud repository (its web pages and remotes).
    public static let host = "bitbucket.org"
    /// `https://api.bitbucket.org/2.0`.
    public let apiBase = URL(string: "https://api.bitbucket.org/2.0")!
    /// The most pages one list follows (50 items each), so a huge repository cannot keep a list loading.
    public var maxPages = 20
    /// How many times a merge Bitbucket answered with 202 (queued or slow) is polled, `mergePollDelay` apart.
    public var mergePolls = 30
    public var mergePollDelay: Duration = .seconds(2)
    private let token: TokenProvider
    private let session: URLSession
    private let memo = Memo()

    public init(session: URLSession = .shared, token: @escaping TokenProvider) {
        self.token = token
        self.session = session
    }

    public var description: String { "BitbucketCloudClient(\(Self.host))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["host": Self.host, "apiBase": apiBase]) }

    /// What the client remembers between calls: the token's user's uuid, and the pull request of each thread it
    /// mapped (for `setReviewThread(_:resolved:)`, which gets the thread only). Shared by copies of the client.
    private final class Memo: Sendable {
        let userUUID = Mutex<String?>(nil)
        let pullRequestByThread = Mutex<[Int: (path: [String], number: Int)]>([:])
    }

    // MARK: - Remote URLs and ids

    /// The repository of a Bitbucket Cloud remote URL (`https://[user@]bitbucket.org/ws/repo[.git]`,
    /// `git@bitbucket.org:ws/repo[.git]`, `ssh://git@bitbucket.org/ws/repo[.git]`): host `bitbucket.org` only, exactly
    /// a workspace and a repository, each ASCII letters, digits, `-`, `_` and `.`. Anything else is nil.
    public static func repository(fromRemoteURL url: String) -> HostedRepository? {
        guard let remote = RemoteURL(url), remote.host == host, remote.segments.count == 2,
            remote.segments.allSatisfy(isSafeSegment)
        else { return nil }
        return HostedRepository(host: host, path: remote.segments)
    }

    private static func isSafeSegment(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0))
        }
    }

    /// A user's `HostedUser.id`: Bitbucket has only the uuid, hashed the same way on every call (no probing), so a
    /// user keeps one id across lists.
    static func userID(_ uuid: String) -> Int {
        stableID("user", uuid)
    }

    private static func stableID(_ kind: String, _ key: String) -> Int {
        var ids = SyntheticIDs()
        return ids.id(kind, key)
    }

    /// `value` as a BBQL string literal: in double quotes, with `\` and `"` escaped.
    static func bbqlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: - HostingProvider

    public var kind: HostingKind { .bitbucketCloud }

    /// No labels, assignees or issues (Bitbucket has reviewers only, and its issue tracker is out of scope), and no
    /// reopen (a declined pull request stays declined).
    public var capabilities: HostingCapabilities {
        [.requestChanges, .resolveThreads, .draft, .reviewRequests, .unapprove]
    }

    /// `merge_commit`, `squash` and `rebase_merge`; `merge(_:in:method:sha:)` refuses one the destination branch does
    /// not allow.
    public var mergeMethods: Set<HostedMergeMethod> { [.merge, .squash, .rebase] }

    /// The source branch, `refs/heads/<branch>` of the repository's own remote, for a pull request from the same
    /// repository (its head has an `owner:branch` label). Bitbucket keeps no pull request ref, so a fork's branch
    /// cannot be fetched from that remote.
    public func checkout(of pullRequest: HostedPullRequest) -> HostedCheckout {
        guard pullRequest.head.label != nil, !pullRequest.head.ref.isEmpty else {
            return .unavailable(reason: "Pull requests from forks can't be checked out here")
        }
        return .ref("heads/\(pullRequest.head.ref)")
    }

    /// `https://bitbucket.org/<ws>/<repo>`, then `src/<branch>` (a `/` in the branch splits it into segments),
    /// `commits/<sha>` or `pull-requests/<n>`, each segment percent-encoded. Nil for an issue, a repository on another
    /// host or not workspace/repo, an empty, `.` or `..` segment, or a sha that is not hex.
    public func webURL(_ target: HostedWebTarget, in repo: HostedRepository) -> URL? {
        guard repo.host.lowercased() == Self.host, repo.path.count == 2 else { return nil }
        var segments = repo.path
        switch target {
        case .repository: break
        case .branch(let name):
            segments += ["src"] + name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        case .commit(let sha):
            guard !sha.isEmpty, sha.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
            segments += ["commits", sha]
        case .pullRequest(let number): segments += ["pull-requests", String(number)]
        case .issue: return nil
        }
        guard !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        let encoded = segments.compactMap { $0.addingPercentEncoding(withAllowedCharacters: Self.segmentAllowed) }
        guard encoded.count == segments.count else { return nil }
        return URL(string: "https://\(Self.host)/" + encoded.joined(separator: "/"))
    }

    public func currentUser() async throws -> HostedUser {
        let user: BitbucketAccount = try await get(url(["user"]))
        memo.userUUID.withLock { $0 = user.uuid }
        return user.hosted
    }

    /// The repositories of every workspace the token's user can reach (`GET /user/workspaces`, then
    /// `GET /repositories/<ws>` for each), sorted by full name, with their https clone link. Up to 60 pages
    /// (3000 repositories) per workspace rather than `maxPages`: a clone picker must list all of them. A repository
    /// whose https link is not a `bitbucket.org` workspace/repo URL is left out.
    public func userRepositories() async throws -> [HostedCloneRepository] {
        var client = self
        client.maxPages = 60
        let workspaces: [BitbucketWorkspaceAccess] = try await client.list(url(["user", "workspaces"]))
        var result: [HostedCloneRepository] = []
        for slug in workspaces.compactMap(\.workspace?.slug) where Self.isSafeSegment(slug) {
            let repos: [BitbucketRepository] = try await client.list(url(["repositories", slug]))
            result += repos.compactMap(Self.cloneRepository)
        }
        return result.sorted { $0.fullName.lowercased() < $1.fullName.lowercased() }
    }

    /// `.closed` lists merged, declined and superseded pull requests (GitHub's `closed` does not tell them apart).
    public func pullRequests(in repo: HostedRepository, state: HostedListState) async throws -> [HostedPullRequest] {
        let states = switch state {
        case .open: ["OPEN"]
        case .closed: ["MERGED", "DECLINED", "SUPERSEDED"]
        case .all: ["OPEN", "MERGED", "DECLINED", "SUPERSEDED"]
        }
        let prs: [BitbucketPullRequest] = try await list(
            url(try repoPath(repo) + ["pullrequests"], query: states.map { ("state", $0) }))
        return prs.map { pullRequest($0, in: repo) }
    }

    /// With `participants`, and `bodyHTML` from Bitbucket's rendered description.
    public func pullRequest(_ number: Int, in repo: HostedRepository) async throws -> HostedPullRequest {
        let pr: BitbucketPullRequest = try await get(url(try pullRequestPath(number, in: repo)))
        return pullRequest(pr, in: repo)
    }

    public func issues(in repo: HostedRepository, state: HostedListState) async throws -> [HostedIssue] {
        throw Self.noIssues
    }

    public func issue(_ number: Int, in repo: HostedRepository) async throws -> HostedIssue {
        throw Self.noIssues
    }

    /// The repository's open pull requests by the token's user (BBQL `author.uuid`).
    public func myOpenPullRequests(in repo: HostedRepository) async throws -> [HostedIssue] {
        try await openPullRequests(where: "author.uuid", in: repo)
    }

    /// The repository's open pull requests with the token's user as a reviewer (BBQL `reviewers.uuid`).
    public func reviewRequestedPullRequests(in repo: HostedRepository) async throws -> [HostedIssue] {
        try await openPullRequests(where: "reviewers.uuid", in: repo)
    }

    public func assignedOpenIssues(in repo: HostedRepository) async throws -> [HostedIssue] {
        throw Self.noIssues
    }

    /// The comments of a pull request outside its inline threads, oldest first, replies included: neither deleted nor
    /// pending (a draft only its author sees). `bodyHTML` is Bitbucket's rendered HTML.
    public func comments(on item: HostedItem, in repo: HostedRepository) async throws -> [HostedComment] {
        guard case .pullRequest(let number) = item else { throw Self.noIssues }
        let comments = try await pullRequestComments(number, in: repo)
        let roots = Self.roots(comments)
        return comments
            .filter { roots[$0.id]?.inline == nil && $0.deleted != true && $0.pending != true }
            .map(Self.comment)
    }

    /// One review per participant who approved (`APPROVED`) or asked for changes (`CHANGES_REQUESTED`), sorted by
    /// uuid; the others have not reviewed (the pull request lists its reviewers in `requestedReviewers`). Ids are
    /// synthetic, keyed by the user's uuid.
    public func reviews(of number: Int, in repo: HostedRepository) async throws -> [HostedReview] {
        let pr: BitbucketPullRequest = try await get(url(try pullRequestPath(number, in: repo)))
        let rows = (pr.participants ?? []).compactMap { participant -> (String, HostedReview)? in
            guard let uuid = participant.user?.uuid else { return nil }
            let state = if participant.state == "changes_requested" { "CHANGES_REQUESTED" }
                else if participant.state == "approved" || participant.approved == true { "APPROVED" }
                else { "" }
            guard !state.isEmpty else { return nil }
            return (uuid, HostedReview(
                id: Self.stableID("review", uuid), user: participant.user?.hosted, state: state,
                submittedAt: GitLabDate.parse(participant.participatedOn)))
        }
        return rows.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// The comments of every inline thread (a top-level comment with `inline`), roots and replies, each reply
    /// pointing at its thread's top-level comment; not pending, and deleted only for a root that still has replies.
    /// The side and line come from the root's `inline`: `to` (the new line) is `RIGHT`, else `from` (the old line)
    /// `LEFT`; a multi-line comment starts at `start_to` or `start_from`. The diff hunk is cut from the file's
    /// current patch (`GitLabClient.hunk`), from its `@@` header to the commented line, and nil when that line is
    /// not in it.
    public func reviewComments(of number: Int, in repo: HostedRepository) async throws -> [HostedReviewComment] {
        let comments = try await pullRequestComments(number, in: repo)
        let roots = Self.roots(comments)
        let withReplies = Set(comments.compactMap(\.parent?.id))
        let threaded = comments.filter { comment in
            guard roots[comment.id]?.inline != nil, comment.pending != true else { return false }
            return comment.deleted != true || (comment.parent == nil && withReplies.contains(comment.id))
        }
        guard !threaded.isEmpty else { return [] }
        let files = (try? await pullRequestFiles(number, in: repo)) ?? []
        let patches = Dictionary(
            files.compactMap { file in file.patch.map { (file.filename, $0) } }, uniquingKeysWith: { a, _ in a })
        return threaded.compactMap { comment in
            guard let root = roots[comment.id], let inline = root.inline else { return nil }
            let place = Self.place(inline)
            let hunk = place.line.flatMap { line in
                patches[place.path].flatMap { GitLabClient.hunk($0, side: place.side, line: line) }
            }
            return HostedReviewComment(
                id: comment.id, inReplyToID: comment.id == root.id ? nil : root.id, path: place.path,
                line: place.line, originalLine: place.line, startLine: place.startLine,
                originalStartLine: place.startLine, side: place.side, diffHunk: hunk,
                body: comment.deleted == true ? nil : comment.content?.raw,
                bodyHTML: comment.deleted == true ? nil : Self.html(comment.content), user: comment.user?.hosted,
                createdAt: GitLabDate.parse(comment.createdOn), htmlURL: comment.links?.html?.href)
        }
    }

    /// A state for each inline thread: the root comment's id is its key (resolving takes it), resolved when the root
    /// has a `resolution`. Bitbucket says neither whether a thread is outdated (false) nor whether the token's user
    /// may resolve it (both flags true; Bitbucket refuses the others).
    public func reviewThreadStates(of number: Int, in repo: HostedRepository) async throws
        -> [HostedReviewThreadState]
    {
        let comments = try await pullRequestComments(number, in: repo)
        let roots = comments.filter { $0.parent == nil && $0.inline != nil && $0.pending != true }
        let path = try repoPath(repo)
        memo.pullRequestByThread.withLock { memo in
            for root in roots { memo[root.id] = (path, number) }
        }
        return roots.map { root in
            HostedReviewThreadState(
                id: String(root.id), isResolved: root.resolution != nil, isOutdated: false, viewerCanResolve: true,
                viewerCanUnresolve: true, rootCommentID: root.id)
        }
    }

    /// Oldest first: Bitbucket's list is reversed when its first commit's parent is the second (newest first).
    public func pullRequestCommits(_ number: Int, in repo: HostedRepository) async throws -> [HostedCommit] {
        let commits: [BitbucketCommit] = try await list(url(try pullRequestPath(number, in: repo) + ["commits"]))
        let newestFirst = commits.count > 1 && commits[0].parents?.contains { $0.hash == commits[1].hash } == true
        return (newestFirst ? commits.reversed() : commits).map { commit in
            let signature = Self.signature(commit.author?.raw)
            return HostedCommit(
                sha: commit.hash, htmlURL: commit.links?.html?.href,
                commit: .init(
                    message: commit.message ?? "",
                    author: .init(name: signature.name, email: signature.email, date: GitLabDate.parse(commit.date))),
                author: commit.author?.user?.hosted)
        }
    }

    /// `GET .../diff`, which Bitbucket redirects (same origin, under `/2.0`) to the repository diff of the pull
    /// request: one git diff, split into its files.
    public func pullRequestFiles(_ number: Int, in repo: HostedRepository) async throws -> [HostedPullRequestFile] {
        let (data, _) = try await perform(
            "GET", url(try pullRequestPath(number, in: repo) + ["diff"]), accept: "text/plain")
        return Self.files(fromDiff: data)
    }

    /// The statuses of commit `ref` (a sha, or a branch name), as check runs: `INPROGRESS` is `in_progress`, and
    /// `SUCCESSFUL`, `FAILED` and `STOPPED` are `completed` with `success`, `failure` and `cancelled`. Ids are
    /// synthetic, keyed by the status's key.
    public func checkRuns(for ref: String, in repo: HostedRepository) async throws -> [HostedCheckRun] {
        let statuses: [BitbucketCommitStatus] = try await list(
            url(try repoPath(repo) + ["commit", ref, "statuses"]))
        var ids = SyntheticIDs()
        return statuses.map { status in
            let state: (String, String?) = switch status.state {
            case "SUCCESSFUL": ("completed", "success")
            case "FAILED": ("completed", "failure")
            case "STOPPED": ("completed", "cancelled")
            case "INPROGRESS": ("in_progress", nil)
            default: (status.state, nil)
            }
            return HostedCheckRun(
                id: ids.id("status", status.key ?? status.name ?? ""), name: status.name ?? status.key ?? "",
                status: state.0, conclusion: state.1, htmlURL: status.url, startedAt: GitLabDate.parse(status.createdOn),
                completedAt: state.0 == "completed" ? GitLabDate.parse(status.updatedOn) : nil)
        }
    }

    public func repositoryInfo(_ repo: HostedRepository) async throws -> HostedRepositoryInfo {
        let repository: BitbucketRepository = try await get(url(try repoPath(repo)))
        guard let defaultBranch = repository.mainbranch?.name else {
            throw HostingError.invalidResponse("a repository without a main branch")
        }
        return HostedRepositoryInfo(fullName: repository.fullName, defaultBranch: defaultBranch)
    }

    /// None: Bitbucket pull requests have no labels.
    public func labels(in repo: HostedRepository) async throws -> [HostedLabel] {
        []
    }

    /// None: Bitbucket pull requests have no assignees.
    public func assignableUsers(in repo: HostedRepository) async throws -> [HostedUser] {
        []
    }

    /// `GET /workspaces/<ws>/members`: the workspace's members, any of whom can be asked to review.
    public func collaborators(in repo: HostedRepository) async throws -> [HostedUser] {
        let members: [BitbucketMembership] = try await list(url(["workspaces", try repoPath(repo)[1], "members"]))
        return members.compactMap { $0.user?.hosted }
    }

    // MARK: - Writes

    /// `POST .../pullrequests` with Bitbucket's `draft` field. Only a branch of the same repository: a fork's
    /// `owner:branch` head is refused.
    public func createPullRequest(_ pullRequest: NewPullRequest, in repo: HostedRepository) async throws
        -> HostedPullRequest
    {
        guard !pullRequest.head.contains(":") else {
            throw HostingError.validationFailed(message: "a pull request from a fork is not supported yet")
        }
        struct Branch: Encodable { var name: String }
        struct End: Encodable { var branch: Branch }
        struct Body: Encodable {
            var title: String
            var source, destination: End
            var description: String?
            var draft: Bool
        }
        let pr: BitbucketPullRequest = try await send(
            "POST", url(try repoPath(repo) + ["pullrequests"]),
            body: Body(
                title: pullRequest.title, source: End(branch: Branch(name: pullRequest.head)),
                destination: End(branch: Branch(name: pullRequest.base)), description: pullRequest.body,
                draft: pullRequest.draft))
        return self.pullRequest(pr, in: repo)
    }

    /// Adds `users` (each by its `reviewerID`, the uuid) to the reviewers, as GitHub does: Bitbucket's `reviewers`
    /// replaces the list, so the pull request's current reviewers are read first and kept, and its title is sent
    /// with them. A user without a uuid is refused before any request.
    public func requestReviewers(_ users: [HostedUser], on number: Int, in repo: HostedRepository) async throws {
        guard !users.isEmpty else { return }
        let added = users.compactMap(\.reviewerID)
        guard added.count == users.count else {
            throw HostingError.validationFailed(message: "a reviewer without a Bitbucket account id")
        }
        let path = try pullRequestPath(number, in: repo)
        let current: BitbucketPullRequest = try await get(url(path))
        var uuids = (current.reviewers ?? []).compactMap(\.uuid)
        for uuid in added where !uuids.contains(uuid) { uuids.append(uuid) }
        struct Reviewer: Encodable { var uuid: String }
        struct Body: Encodable { var title: String; var reviewers: [Reviewer] }
        let _: BitbucketPullRequest = try await send(
            "PUT", url(path), body: Body(title: current.title, reviewers: uuids.map(Reviewer.init)))
    }

    public func addLabels(_ names: [String], to item: HostedItem, in repo: HostedRepository) async throws {
        guard !names.isEmpty else { return }
        throw HostingError.validationFailed(message: "Bitbucket pull requests have no labels")
    }

    public func addAssignees(_ users: [HostedUser], to item: HostedItem, in repo: HostedRepository) async throws {
        guard !users.isEmpty else { return }
        throw HostingError.validationFailed(message: "Bitbucket pull requests have no assignees")
    }

    public func comment(on item: HostedItem, in repo: HostedRepository, body: String) async throws -> HostedComment {
        guard case .pullRequest(let number) = item else { throw Self.noIssues }
        return Self.comment(try await postComment(body, parent: nil, on: number, in: repo))
    }

    /// A comment whose `parent` is the thread's root comment.
    public func reply(to thread: HostedThreadRef, on number: Int, in repo: HostedRepository, body: String)
        async throws -> HostedReviewComment
    {
        let comment = try await postComment(body, parent: thread.rootCommentID, on: number, in: repo)
        let place = comment.inline.map(Self.place)
        return HostedReviewComment(
            id: comment.id, inReplyToID: thread.rootCommentID, path: place?.path ?? "", line: place?.line,
            originalLine: place?.line, startLine: place?.startLine, originalStartLine: place?.startLine,
            side: place?.side, body: comment.content?.raw, bodyHTML: Self.html(comment.content),
            user: comment.user?.hosted, createdAt: GitLabDate.parse(comment.createdOn),
            htmlURL: comment.links?.html?.href)
    }

    /// `POST` (resolve) or `DELETE` (reopen) `.../comments/<root>/resolve`, for a thread this client mapped in
    /// `reviewThreadStates(of:in:)` (the state has no repository or pull request). Bitbucket's 409 on resolving says
    /// it already is.
    public func setReviewThread(_ state: HostedReviewThreadState, resolved: Bool) async throws -> Bool {
        guard let root = Int(state.id), let target = memo.pullRequestByThread.withLock({ $0[root] }) else {
            throw HostingError.validationFailed(message: "an unknown Bitbucket thread: reload the pull request")
        }
        let path = target.path + ["pullrequests", String(target.number), "comments", String(root), "resolve"]
        do {
            _ = try await perform(resolved ? "POST" : "DELETE", url(path))
        } catch HostingError.http(status: 409, message: _) where resolved {
            return true
        }
        return resolved
    }

    /// `APPROVE` (`POST .../approve`) and `REQUEST_CHANGES` (`POST .../request-changes`) post a non-empty body as a
    /// comment only once Bitbucket accepted them; `COMMENT` posts the body as a comment. The review's id follows
    /// `reviews(of:in:)`.
    public func review(_ number: Int, in repo: HostedRepository, event: HostedReviewEvent, body: String?)
        async throws -> HostedReview
    {
        let path = try pullRequestPath(number, in: repo)
        let text = body.flatMap { $0.isEmpty ? nil : $0 }
        if event == .comment {
            guard let text else { throw HostingError.validationFailed(message: "a comment needs a body") }
            let id = Self.stableID("review", try await myUUID())
            let comment = Self.comment(try await postComment(text, parent: nil, on: number, in: repo))
            return HostedReview(
                id: id, user: comment.user, state: "COMMENTED", body: comment.body, bodyHTML: comment.bodyHTML,
                htmlURL: comment.htmlURL, submittedAt: comment.createdAt)
        }
        let approve = event == .approve
        let (data, _) = try await perform("POST", url(path + [approve ? "approve" : "request-changes"]))
        let participant: BitbucketPullRequest.Participant = try Self.decode(data)
        if let text { _ = try await postComment(text, parent: nil, on: number, in: repo) }
        var uuid = participant.user?.uuid
        if uuid == nil { uuid = try await myUUID() }
        return HostedReview(
            id: Self.stableID("review", uuid ?? ""), user: participant.user?.hosted,
            state: approve ? "APPROVED" : "CHANGES_REQUESTED", body: text, bodyHTML: text.map(MarkdownHTML.html),
            submittedAt: GitLabDate.parse(participant.participatedOn) ?? Date())
    }

    /// `DELETE .../approve`: withdraws the token's user's approval.
    public func unapprove(_ number: Int, in repo: HostedRepository) async throws {
        _ = try await perform("DELETE", url(try pullRequestPath(number, in: repo) + ["approve"]))
    }

    /// Bitbucket's merge takes no head to pin, so the pull request is read again first: its source commit (`hash`,
    /// usually abbreviated) and `sha` must name the same commit (one a prefix of the other, `sha` hex and at least 7
    /// digits), else `HostingError.headChanged`, as for Bitbucket's own 409 ("one of the refs changed"). The method is
    /// refused unsent when the destination branch does not allow it, and a 400 (cannot merge) is `validationFailed`.
    /// A 202 (a merge queue, or a slow merge) is polled through its task status, built from the task id at the end
    /// of `Location` (never requested as given), until `SUCCESS`.
    public func merge(_ number: Int, in repo: HostedRepository, method: HostedMergeMethod, sha: String) async throws {
        guard sha.count >= 7, sha.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw HostingError.headChanged }
        let path = try pullRequestPath(number, in: repo)
        let current: BitbucketPullRequest = try await get(url(path))
        let head = (current.source?.commit?.hash ?? "").lowercased()
        let expected = sha.lowercased()
        guard head.count >= 7, head.hasPrefix(expected) || expected.hasPrefix(head) else {
            throw HostingError.headChanged
        }
        let strategy = switch method {
        case .merge: "merge_commit"
        case .squash: "squash"
        case .rebase: "rebase_merge"
        }
        if let allowed = current.destination?.branch?.mergeStrategies, !allowed.contains(strategy) {
            throw HostingError.validationFailed(message: "this repository does not allow the \(strategy) strategy")
        }
        let response: HTTPURLResponse
        do {
            (_, response) = try await perform(
                "POST", url(path + ["merge"]), body: try JSONEncoder().encode(["merge_strategy": strategy]))
        } catch HostingError.http(status: 409, message: _) {
            throw HostingError.headChanged
        } catch HostingError.http(status: 400, let message) {
            throw HostingError.validationFailed(message: message.isEmpty ? "Bitbucket did not merge it" : message)
        }
        guard response.statusCode == 202 else { return }
        let statusPath = path + ["merge", "task-status"]
        // Bitbucket took the merge: a status link this client does not follow is no failure of it.
        guard let taskID = taskID(response.value(forHTTPHeaderField: "Location"), under: statusPath) else {
            throw HostingError.validationFailed(message: "Bitbucket queued the merge: reload to see when it is done")
        }
        try await waitForMerge(url(statusPath + [taskID]))
    }

    /// Polls a merge task up to `mergePolls` times: `PENDING` waits, `SUCCESS` is done, a 400 (the merge failed, or
    /// the pull request left the merge queue) is `validationFailed` with Bitbucket's message, a 409 `headChanged`.
    private func waitForMerge(_ status: URL) async throws {
        for _ in 0..<mergePolls {
            try await Task.sleep(for: mergePollDelay)
            let data: Data
            do {
                (data, _) = try await perform("GET", status)
            } catch HostingError.http(status: 400, let message) {
                throw HostingError.validationFailed(message: message.isEmpty ? "Bitbucket did not merge it" : message)
            } catch HostingError.http(status: 409, message: _) {
                throw HostingError.headChanged
            }
            let task: BitbucketMergeTask = try Self.decode(data)
            if task.taskStatus == "SUCCESS" { return }
        }
        throw HostingError.validationFailed(
            message: "Bitbucket is still merging this pull request (it may wait in a merge queue): reload it later.")
    }

    /// The task id of a 202's `Location`: resolved against `apiBase`, it must be on its origin with a path of exactly
    /// `segments` (compared without case, percent-encoded as `url` does) plus one plain segment, the id; nil
    /// otherwise.
    private func taskID(_ location: String?, under segments: [String]) -> String? {
        guard let location, let target = URL(string: location, relativeTo: apiBase)?.absoluteURL,
            HostingHTTP.isSameOrigin(target, apiBase)
        else { return nil }
        let prefix = url(segments).path(percentEncoded: true).lowercased() + "/"
        var path = target.path(percentEncoded: true)
        guard path.lowercased().hasPrefix(prefix) else { return nil }
        path.removeFirst(prefix.count)
        if path.hasSuffix("/") { path.removeLast() }
        guard !path.contains("/"), let id = path.removingPercentEncoding, !id.isEmpty, id != ".", id != "..",
            !id.contains("/")
        else { return nil }
        return id
    }

    /// Declines (`open` false) a pull request; Bitbucket cannot reopen one, and has no issues here.
    public func setOpen(_ open: Bool, item: HostedItem, in repo: HostedRepository) async throws {
        guard case .pullRequest(let number) = item else { throw Self.noIssues }
        guard !open else {
            throw HostingError.validationFailed(message: "Bitbucket cannot reopen a declined pull request")
        }
        _ = try await perform("POST", url(try pullRequestPath(number, in: repo) + ["decline"]))
    }

    private static let noIssues = HostingError.validationFailed(message: "Bitbucket issues are not supported")

    // MARK: - Mapping

    /// The head's `owner:branch` label is set only for a branch of the same repository (nil for a fork's, or when
    /// Bitbucket leaves out the repositories). A merged pull request's `mergedAt` is its last update.
    private func pullRequest(_ pr: BitbucketPullRequest, in repo: HostedRepository) -> HostedPullRequest {
        let source = pr.source?.branch?.name ?? ""
        let target = pr.destination?.branch?.name ?? ""
        let merged = pr.state == "MERGED"
        return HostedPullRequest(
            id: pr.id, number: pr.id, title: pr.title, state: pr.state == "OPEN" ? "open" : "closed", draft: pr.draft,
            user: pr.author?.hosted, body: pr.summary?.raw,
            bodyHTML: pr.rendered?.description?.html ?? pr.summary?.html,
            htmlURL: pr.links?.html?.href ?? webURL(.pullRequest(pr.id), in: repo)?.absoluteString ?? "",
            head: HostedBranchRef(
                label: Self.isSameRepository(pr) ? repo.owner + ":" + source : nil, ref: source,
                sha: pr.source?.commit?.hash ?? ""),
            base: HostedBranchRef(
                label: repo.owner + ":" + target, ref: target, sha: pr.destination?.commit?.hash ?? ""),
            requestedReviewers: pr.reviewers?.map(\.hosted), createdAt: GitLabDate.parse(pr.createdOn),
            updatedAt: GitLabDate.parse(pr.updatedOn), mergedAt: merged ? GitLabDate.parse(pr.updatedOn) : nil,
            merged: merged)
    }

    /// Whether the source branch is in the destination repository (by uuid, else by full name).
    private static func isSameRepository(_ pr: BitbucketPullRequest) -> Bool {
        guard let source = pr.source?.repository, let destination = pr.destination?.repository else { return false }
        if let a = source.uuid, let b = destination.uuid { return a == b }
        guard let a = source.fullName, let b = destination.fullName else { return false }
        return a.lowercased() == b.lowercased()
    }

    /// The open pull requests whose BBQL `field` is the token's user's uuid, as issue-shaped rows (`pullRequest`
    /// and `draft` set).
    private func openPullRequests(where field: String, in repo: HostedRepository) async throws -> [HostedIssue] {
        let query = [("state", "OPEN"), ("q", field + "=" + Self.bbqlString(try await myUUID()))]
        let prs: [BitbucketPullRequest] = try await list(url(try repoPath(repo) + ["pullrequests"], query: query))
        return prs.map { pr in
            let pull = pullRequest(pr, in: repo)
            return HostedIssue(
                id: pull.id, number: pull.number, title: pull.title, state: pull.state, user: pull.user,
                body: pull.body, htmlURL: pull.htmlURL, comments: pr.commentCount, createdAt: pull.createdAt,
                updatedAt: pull.updatedAt, pullRequest: .init(url: pull.htmlURL), draft: pull.draft)
        }
    }

    /// The token's user's uuid, asked once (`GET /user`).
    private func myUUID() async throws -> String {
        if let uuid = memo.userUUID.withLock({ $0 }) { return uuid }
        guard let uuid = try await currentUser().reviewerID else {
            throw HostingError.invalidResponse("a user without a uuid")
        }
        return uuid
    }

    private func pullRequestComments(_ number: Int, in repo: HostedRepository) async throws -> [BitbucketComment] {
        try await list(url(try pullRequestPath(number, in: repo) + ["comments"]))
    }

    private func postComment(_ body: String, parent: Int?, on number: Int, in repo: HostedRepository)
        async throws -> BitbucketComment
    {
        struct Content: Encodable { var raw: String }
        struct Parent: Encodable { var id: Int }
        struct Body: Encodable { var content: Content; var parent: Parent? }
        return try await send(
            "POST", url(try pullRequestPath(number, in: repo) + ["comments"]),
            body: Body(content: Content(raw: body), parent: parent.map(Parent.init)))
    }

    /// Each comment's thread root, the top-level comment up its `parent` chain (as far as the list has it).
    private static func roots(_ comments: [BitbucketComment]) -> [Int: BitbucketComment] {
        let byID = Dictionary(comments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var roots: [Int: BitbucketComment] = [:]
        for comment in comments {
            var root = comment
            var steps = 0
            while let parent = root.parent.flatMap({ byID[$0.id] }), steps < comments.count {
                root = parent
                steps += 1
            }
            roots[comment.id] = root
        }
        return roots
    }

    /// The path, side, line and first line of an inline comment: `to` is the new line (`RIGHT`), else `from` the old
    /// one (`LEFT`); the first line of a multi-line comment is `start_to` or `start_from` on the same side.
    private static func place(_ inline: BitbucketComment.Inline) -> (
        path: String, side: String, line: Int?, startLine: Int?
    ) {
        let (side, line, start) = if let to = inline.to { ("RIGHT", Optional(to), inline.startTo) }
            else { ("LEFT", inline.from, inline.startFrom) }
        let startLine = start.flatMap { start in line.flatMap { start < $0 ? start : nil } }
        return (inline.path ?? "", side, line, startLine)
    }

    private static func comment(_ comment: BitbucketComment) -> HostedComment {
        HostedComment(
            id: comment.id, user: comment.user?.hosted, body: comment.content?.raw, bodyHTML: html(comment.content),
            htmlURL: comment.links?.html?.href, createdAt: GitLabDate.parse(comment.createdOn),
            updatedAt: GitLabDate.parse(comment.updatedOn))
    }

    /// Bitbucket's rendered HTML, else the raw markdown through `MarkdownHTML`.
    private static func html(_ content: BitbucketContent?) -> String? {
        content?.html ?? content?.raw.map(MarkdownHTML.html)
    }

    /// The name and email of a commit author's `Name <email>`.
    private static func signature(_ raw: String?) -> (name: String?, email: String?) {
        guard let raw else { return (nil, nil) }
        guard let open = raw.lastIndex(of: "<"), raw.hasSuffix(">") else { return (raw, nil) }
        let name = raw[..<open].trimmingCharacters(in: .whitespaces)
        return (name.isEmpty ? nil : name, String(raw[raw.index(after: open)..<raw.index(before: raw.endIndex)]))
    }

    /// A repository with an https clone link that names it on `bitbucket.org`.
    private static func cloneRepository(_ repository: BitbucketRepository) -> HostedCloneRepository? {
        guard let link = repository.links?.clone?.first(where: { $0.name == "https" })?.href,
            link.lowercased().hasPrefix("https://"), let named = Self.repository(fromRemoteURL: link)
        else { return nil }
        let workspace = named.path[0]
        return HostedCloneRepository(
            id: stableID("repository", repository.uuid ?? named.fullName), name: named.name,
            fullName: named.fullName, owner: HostedUser(id: stableID("workspace", workspace), login: workspace),
            cloneURL: link, isPrivate: repository.isPrivate ?? false, fork: repository.parent.map { _ in true })
    }

    /// A git diff split into files at its `diff --git` lines (a hunk line never starts that way), on LF bytes as
    /// `DiffReader` reads it (a CRLF line stays one line), each parsed by `DiffReader` for its paths, change and line
    /// counts; the patch is the file's lines from its first `@@`, nil for a binary file.
    static func files(fromDiff diff: Data) -> [HostedPullRequestFile] {
        let newline = UInt8(ascii: "\n")
        var chunks: [[Data]] = []
        for line in diff.split(separator: newline, omittingEmptySubsequences: false) {
            if line.starts(with: "diff --git ".utf8) {
                chunks.append([line])
            } else if !chunks.isEmpty {
                chunks[chunks.count - 1].append(line)
            }
        }
        return chunks.compactMap { lines in
            guard let file = DiffReader.parse(Data(lines.joined(separator: [newline]))).first else { return nil }
            var body = lines.firstIndex { $0.starts(with: "@@".utf8) }.map { lines[$0...] } ?? []
            while body.last?.isEmpty == true { body.removeLast() }
            let status = switch file.change {
            case .added: "added"
            case .deleted: "removed"
            case .renamed: "renamed"
            case .copied: "copied"
            case .modified: "modified"
            }
            let moved = file.change == .renamed || file.change == .copied
            let patch = String(decoding: Data(body.joined(separator: [newline])), as: UTF8.self)
            return HostedPullRequestFile(
                filename: file.path, status: status, additions: file.additions, deletions: file.deletions,
                patch: file.isBinary || body.isEmpty ? nil : patch, previousFilename: moved ? file.oldPath : nil)
        }
    }

    // MARK: - Requests

    /// A path segment's characters: `urlPathAllowed` without `/`, so a `/` inside a segment is encoded.
    private static let segmentAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return allowed
    }()

    /// `repositories/<ws>/<repo>` for a repository on `bitbucket.org` named by exactly two segments, none empty, `.`
    /// or `..` (each is percent-encoded as one segment by `url`).
    private func repoPath(_ repo: HostedRepository) throws -> [String] {
        guard repo.host.lowercased() == Self.host else { throw HostingError.wrongHost(repo.host) }
        guard repo.path.count == 2, !repo.path.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw HostingError.validationFailed(message: "not a repository path: \(repo.path.joined(separator: "/"))")
        }
        return ["repositories"] + repo.path
    }

    private func pullRequestPath(_ number: Int, in repo: HostedRepository) throws -> [String] {
        try repoPath(repo) + ["pullrequests", String(number)]
    }

    /// `apiBase` plus `segments`, each percent-encoded as one path segment, and `query` in order (a name may repeat),
    /// with `+` as `%2B` so it never reads as a space.
    private func url(_ segments: [String], query: [(String, String)] = []) -> URL {
        var components = URLComponents(url: apiBase, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath += segments
            .map { "/" + ($0.addingPercentEncoding(withAllowedCharacters: Self.segmentAllowed) ?? "") }.joined()
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return components.url!
    }

    /// Whether `url` is under `apiBase`: the same origin, its path `/2.0` plus whole segments, none of them `.` or
    /// `..` (percent-decoded), so `/2.0evil` or `/2.0/../x` is not.
    private func isUnderAPIBase(_ url: URL) -> Bool {
        HostingHTTP.isSameOrigin(url, apiBase) && HostingHTTP.isPath(of: url, under: apiBase.path(percentEncoded: true))
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: data)
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

    /// Follows each page's `next` from `first` (with `pagelen=50`), up to `maxPages` pages. A next URL outside
    /// `apiBase` throws: following it would send the token there.
    private func list<T: Decodable>(_ first: URL) async throws -> [T] {
        var components = URLComponents(url: first, resolvingAgainstBaseURL: false)!
        components.percentEncodedQueryItems = (components.percentEncodedQueryItems ?? [])
            + [URLQueryItem(name: "pagelen", value: "50")]
        var next: URL? = components.url!
        var result: [T] = []
        var pages = 0
        while let url = next, pages < maxPages {
            let page: BitbucketPage<T> = try await get(url)
            result += page.values ?? []
            pages += 1
            next = nil
            if let text = page.next {
                guard let link = URL(string: text), isUnderAPIBase(link) else {
                    throw HostingError.invalidResponse("a next-page link to another host")
                }
                next = link
            }
        }
        return result
    }

    /// The one place a request is made and the token attached, only to a URL under `apiBase`. A 401 asks the provider
    /// for a refreshed token and retries once; a second 401 is `unauthorized`.
    private func perform(_ method: String, _ url: URL, body: Data? = nil, accept: String = "application/json")
        async throws -> (Data, HTTPURLResponse)
    {
        guard isUnderAPIBase(url) else { throw HostingError.invalidResponse("a URL outside the API") }
        let token = try await self.token(nil)
        var (data, response) = try await load(method, url, body: body, accept: accept, token: token)
        if response.statusCode == 401 {
            (data, response) = try await load(method, url, body: body, accept: accept, token: try await self.token(token))
        }
        guard (200..<300).contains(response.statusCode) else { throw HostingHTTP.error(for: response, data: data) }
        return (data, response)
    }

    private func load(_ method: String, _ url: URL, body: Data?, accept: String, token: String) async throws
        -> (Data, HTTPURLResponse)
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
        return try await HostingHTTP.load(
            request, session: session, allowedPathPrefix: apiBase.path(percentEncoded: true))
    }
}
