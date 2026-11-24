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

    public init(session: URLSession = HostingHTTP.session, token: @escaping TokenProvider) {
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

    /// No labels, assignees or issues (Bitbucket has reviewers only, and its issue tracker is out of scope), no
    /// reopen (a declined pull request stays declined), and no reactions (the public API has no like endpoint).
    public var capabilities: HostingCapabilities {
        [.requestChanges, .resolveThreads, .draft, .reviewRequests, .unapprove, .generalReplies,
         .resolveGeneralThreads, .editComments, .deleteComments, .newInlineComments, .multiLineInlineComments,
         .timelineEvents, .tasks, .mergeChecks, .reports]
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
        let path = try pullRequestPath(number, in: repo)
        let pr: BitbucketPullRequest = try await get(url(path, query: Self.strategyFields))
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

    /// The comments of a pull request outside its inline threads, oldest first, replies included, each with its
    /// direct `parentID` (Bitbucket nests to any depth): not pending (a draft only its author sees), and not deleted
    /// unless a comment below it is not, then shown as `deletedText` with no rights. A top-level comment is
    /// `resolvable`, resolved when it has a `resolution`. Rights: the author is the token's user (Bitbucket has no
    /// flag; none when the user cannot be read). `bodyHTML` is Bitbucket's rendered HTML.
    public func comments(on item: HostedItem, in repo: HostedRepository) async throws -> [HostedComment] {
        guard case .pullRequest(let number) = item else { throw Self.noIssues }
        let comments = try await pullRequestComments(number, in: repo)
        let roots = Self.roots(comments)
        let general = comments.filter { roots[$0.id]?.inline == nil && $0.pending != true }
        let kept = Self.keptDeleted(general)
        let shown = general.filter { $0.deleted != true || kept.contains($0.id) }
        guard !shown.isEmpty else { return [] }
        let me = try? await myUUID()
        return shown.map { Self.comment($0, viewer: me) }
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
        let me = try? await myUUID()
        let files = (try? await pullRequestFiles(number, in: repo)) ?? []
        let patches = Dictionary(
            files.compactMap { file in file.patch.map { (file.filename, $0) } }, uniquingKeysWith: { a, _ in a })
        return threaded.compactMap { comment in
            guard let root = roots[comment.id], let inline = root.inline else { return nil }
            let place = Self.place(inline)
            let hunk = place.line.flatMap { line in
                patches[place.path].flatMap { GitLabClient.hunk($0, side: place.side, line: line) }
            }
            var mapped = HostedReviewComment(
                id: comment.id, inReplyToID: comment.id == root.id ? nil : root.id, path: place.path,
                line: place.line, originalLine: place.line, startLine: place.startLine,
                originalStartLine: place.startLine, side: place.side, diffHunk: hunk,
                body: comment.deleted == true ? nil : comment.content?.raw,
                bodyHTML: comment.deleted == true ? nil : Self.html(comment.content), user: comment.user?.hosted,
                createdAt: GitLabDate.parse(comment.createdOn), htmlURL: comment.links?.html?.href)
            let own = Self.isOwn(comment, viewer: me)
            (mapped.viewerCanEdit, mapped.viewerCanDelete) = (own, own)
            return mapped
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
        return Self.created(try await postComment(body, parent: nil, on: number, in: repo))
    }

    /// A comment whose `parent` is the thread's root comment.
    public func reply(to thread: HostedThreadRef, on number: Int, in repo: HostedRepository, body: String)
        async throws -> HostedReviewComment
    {
        let comment = try await postComment(body, parent: thread.rootCommentID, on: number, in: repo)
        return Self.created(comment, inReplyTo: thread.rootCommentID, fallbackPath: "")
    }

    /// `POST` (resolve) or `DELETE` (reopen) `.../comments/<root>/resolve`, for a thread this client mapped in
    /// `reviewThreadStates(of:in:)` (the state has no repository or pull request). Bitbucket's 409 on resolving says
    /// it already is.
    public func setReviewThread(_ state: HostedReviewThreadState, resolved: Bool) async throws -> Bool {
        guard let root = Int(state.id), let target = memo.pullRequestByThread.withLock({ $0[root] }) else {
            throw HostingError.validationFailed(message: "an unknown Bitbucket thread: reload the pull request")
        }
        let path = target.path + ["pullrequests", String(target.number), "comments", String(root), "resolve"]
        return try await setResolution(path, resolved: resolved)
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
        try await merge(number, in: repo, method: method, sha: sha, options: HostedMergeOptions())
    }

    /// Close source branch (`deleteSourceBranch`), sent only when set.
    public var supportedMergeOptions: Set<HostedMergeOption> { [.deleteSourceBranch] }

    /// `merge(_:in:method:sha:)` with `close_source_branch` when `options.deleteSourceBranch` is set.
    public func merge(
        _ number: Int, in repo: HostedRepository, method: HostedMergeMethod, sha: String, options: HostedMergeOptions
    ) async throws {
        guard sha.count >= 7, sha.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw HostingError.headChanged }
        let path = try pullRequestPath(number, in: repo)
        let current: BitbucketPullRequest = try await get(url(path, query: Self.strategyFields))
        let head = (current.source?.commit?.hash ?? "").lowercased()
        let expected = sha.lowercased()
        guard head.count >= 7, head.hasPrefix(expected) || expected.hasPrefix(head) else {
            throw HostingError.headChanged
        }
        guard let strategy = Self.strategy(of: method) else {
            throw HostingError.validationFailed(message: "Bitbucket Cloud has no such merge strategy")
        }
        if let allowed = current.destination?.branch?.mergeStrategies, !allowed.contains(strategy) {
            throw HostingError.validationFailed(message: "this repository does not allow the \(strategy) strategy")
        }
        struct Body: Encodable {
            var strategy: String
            /// Left out when nil: the pull request's own setting applies.
            var closeSourceBranch: Bool?
            enum CodingKeys: String, CodingKey {
                case strategy = "merge_strategy"
                case closeSourceBranch = "close_source_branch"
            }
        }
        let response: HTTPURLResponse
        do {
            (_, response) = try await perform(
                "POST", url(path + ["merge"]),
                body: try JSONEncoder().encode(Body(strategy: strategy, closeSourceBranch: options.deleteSourceBranch)))
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

    // MARK: - Comment interactions

    /// `POST .../comments` with `parent` the general comment answered (any comment: Bitbucket nests to any depth).
    /// A review comment's ref is refused unsent (`reply(to:on:in:body:)` answers inline threads).
    public func reply(
        toGeneral comment: HostedCommentRef, on item: HostedItem, in repo: HostedRepository, body: String
    ) async throws -> HostedComment {
        let number = try Self.generalTarget(comment, on: item)
        var reply = Self.created(try await postComment(body, parent: comment.id, on: number, in: repo))
        reply.parentID = reply.parentID ?? comment.id
        return reply
    }

    /// `POST` (resolve) or `DELETE` (reopen) `.../comments/<root>/resolve` on a top-level general comment (Bitbucket
    /// answers 403 for a reply); its 409 on resolving says it already is.
    public func setGeneralThread(
        _ root: HostedCommentRef, on item: HostedItem, in repo: HostedRepository, resolved: Bool
    ) async throws -> Bool {
        let number = try Self.generalTarget(root, on: item)
        let path = try pullRequestPath(number, in: repo) + ["comments", String(root.id), "resolve"]
        return try await setResolution(path, resolved: resolved)
    }

    /// `PUT .../comments/<id>` with only the new `content.raw`, a general or an inline comment alike.
    public func editComment(_ comment: HostedCommentRef, on item: HostedItem, in repo: HostedRepository, body: String)
        async throws
    {
        guard case .pullRequest(let number) = item else { throw Self.noIssues }
        struct Content: Encodable { var raw: String }
        struct Body: Encodable { var content: Content }
        let _: BitbucketComment = try await send(
            "PUT", url(try pullRequestPath(number, in: repo) + ["comments", String(comment.id)]),
            body: Body(content: Content(raw: body)))
    }

    /// `DELETE .../comments/<id>`, answered 204 without a body.
    public func deleteComment(_ comment: HostedCommentRef, on item: HostedItem, in repo: HostedRepository)
        async throws
    {
        guard case .pullRequest(let number) = item else { throw Self.noIssues }
        _ = try await perform("DELETE", url(try pullRequestPath(number, in: repo) + ["comments", String(comment.id)]))
    }

    /// `POST .../comments` with `inline`: `path` (the new path; Bitbucket has no old path), `to` the new line for an
    /// added or context line, `from` the old line for a removed one, and for a range `start_to` or `start_from` on the
    /// same side. Refused unsent when the line, or a range's first line, is missing on its side (a range across sides
    /// is not documented). Bitbucket takes no commit, so `headSHA` is not sent.
    public func createInlineComment(
        at position: HostedInlinePosition, on number: Int, in repo: HostedRepository, body: String
    ) async throws -> HostedReviewComment {
        struct Content: Encodable { var raw: String }
        struct Inline: Encodable {
            var path: String
            var from, to, startFrom, startTo: Int?
            enum CodingKeys: String, CodingKey {
                case path, from, to, startFrom = "start_from", startTo = "start_to"
            }
        }
        struct Body: Encodable { var content: Content; var inline: Inline }
        let newSide = position.lineKind != .removed
        let (line, start) = newSide
            ? (position.newLine, position.startNewLine) : (position.oldLine, position.startOldLine)
        guard let line else {
            throw HostingError.validationFailed(message: "no line on the \(newSide ? "new" : "old") side")
        }
        guard start != nil || (position.startOldLine == nil && position.startNewLine == nil) else {
            throw HostingError.validationFailed(message: "a range must start on the same side it ends")
        }
        let inline = newSide
            ? Inline(path: position.path, to: line, startTo: start)
            : Inline(path: position.path, from: line, startFrom: start)
        let comment: BitbucketComment = try await send(
            "POST", url(try pullRequestPath(number, in: repo) + ["comments"]),
            body: Body(content: Content(raw: body), inline: inline))
        return Self.created(comment, inReplyTo: nil, fallbackPath: position.path)
    }

    /// The pull request number of a general comment write; an issue or a review comment's ref is refused unsent.
    private static func generalTarget(_ comment: HostedCommentRef, on item: HostedItem) throws -> Int {
        guard case .pullRequest(let number) = item else { throw noIssues }
        guard comment.kind == .general else {
            throw HostingError.validationFailed(message: "not a general Bitbucket comment")
        }
        return number
    }

    /// `POST` (resolve) or `DELETE` (reopen) the resolve path of a top-level comment: a 409 on resolving says it
    /// already is.
    private func setResolution(_ path: [String], resolved: Bool) async throws -> Bool {
        do {
            _ = try await perform(resolved ? "POST" : "DELETE", url(path))
        } catch HostingError.http(status: 409, message: _) where resolved {
            return true
        }
        return resolved
    }

    // MARK: - Activity, tasks and merge checks

    /// The history entries of `/activity` in Bitbucket's words, oldest first, from its `update` snapshots taken in
    /// date order (the first "Opened the pull request"; then each change of the source commit "Updated the pull
    /// request with N commits: <links>", the commits between the two from the pull request's commits; of the state
    /// "Merged" / "Declined the pull request"; of the title or description "edited the title" / "edited the
    /// description"; of the reviewers "added" / "removed N reviewer(s)" with their names), and its `approval` and
    /// `changes_requested` entries; then the tasks' "created a task" and "resolved a task" with their text (the v2.0
    /// activity has no task entries: they come from `/tasks`, the last resolution only). Comments are left out (read
    /// on their own). Histq's words are escaped in `textHTML` and `detailHTML`.
    public func timelineEvents(of item: HostedItem, in repo: HostedRepository) async throws -> [HostedTimelineEvent] {
        guard case .pullRequest(let number) = item else { throw Self.noIssues }
        async let commits = (try? await pullRequestCommits(number, in: repo)) ?? []
        async let tasks = (try? await tasks(of: number, in: repo)) ?? []
        let activity: [BitbucketActivity] = try await list(url(try pullRequestPath(number, in: repo) + ["activity"]))
        return Self.events(activity, commits: await commits, tasks: await tasks) { [self] sha in
            webURL(.commit(sha), in: repo)?.absoluteString
        }
    }

    /// `timelineEvents`' entries from `activity`, with `commits` (oldest first) naming each update's commits, and
    /// `tasks`' creations and resolutions.
    static func events(
        _ activity: [BitbucketActivity], commits: [HostedCommit], tasks: [HostedTask] = [],
        commitURL: (String) -> String?
    ) -> [HostedTimelineEvent] {
        var events: [HostedTimelineEvent] = []
        func add(_ id: String, _ actor: HostedUser?, _ date: Date?, _ text: String, action: String,
                 html: String? = nil, detail: String? = nil) {
            events.append(HostedTimelineEvent(
                id: id, actor: actor, createdAt: date, text: text,
                textHTML: html ?? "<p>\(MarkdownHTML.escape(text))</p>", action: action, detailHTML: detail))
        }
        func add(_ id: String, _ actor: BitbucketAccount?, _ date: String?, _ text: String, action: String,
                 html: String? = nil, detail: String? = nil) {
            add(id, actor?.hosted, GitLabDate.parse(date), text, action: action, html: html, detail: detail)
        }
        /// "+ Ann, Bob": the names of the reviewers an update added or removed.
        func names(_ sign: String, _ accounts: [BitbucketAccount]) -> String? {
            let list = accounts.map { $0.hosted.name ?? $0.hosted.login }
            guard !list.isEmpty else { return nil }
            return "<p>\(sign) " + list.map { "<b>\(MarkdownHTML.escape($0))</b>" }.joined(separator: ", ") + "</p>"
        }
        let updates = activity.compactMap(\.update).enumerated()
            .sorted { (GitLabDate.parse($0.element.date) ?? .distantPast, $0.offset)
                < (GitLabDate.parse($1.element.date) ?? .distantPast, $1.offset) }
            .map(\.element)
        var previous: BitbucketActivity.Update?
        for (index, update) in updates.enumerated() {
            let id = "update-\(index)"
            guard let before = previous else {
                add(id, update.author, update.date, "Opened the pull request", action: "opened")
                previous = update
                continue
            }
            let old = before.source?.commit?.hash ?? "", new = update.source?.commit?.hash ?? ""
            if !new.isEmpty, !old.isEmpty, !old.hasPrefix(new), !new.hasPrefix(old) {
                let between = Self.commits(commits, after: old, upTo: new)
                let noun = between.count == 1 ? "commit" : "commits"
                let links = between.map { commit in
                    let short = MarkdownHTML.escape(String(commit.sha.prefix(7)))
                    return commitURL(commit.sha).map { "<a href=\"\(MarkdownHTML.escape($0))\">\(short)</a>" } ?? short
                }
                // Commits not found (a force push dropped the old head from the list): no count rather than a wrong one.
                let text = between.isEmpty ? "Updated the pull request"
                    : "Updated the pull request with \(between.count) \(noun)"
                add(id + "-commits", update.author, update.date, text, action: "commit",
                    html: "<p>\(text)" + (links.isEmpty ? "" : ": " + links.joined(separator: ", ")) + "</p>")
            }
            if update.state != before.state {
                switch update.state {
                case "MERGED": add(id + "-state", update.author, update.date, "Merged the pull request", action: "merged")
                case "DECLINED":
                    add(id + "-state", update.author, update.date, "Declined the pull request", action: "declined")
                default: break
                }
            }
            if let title = update.title, let was = before.title, title != was {
                add(id + "-title", update.author, update.date, "edited the title", action: "title")
            }
            if let text = update.description, let was = before.description, text != was {
                add(id + "-description", update.author, update.date, "edited the description", action: "description")
            }
            // The update's own list of what changed, else the two snapshots' difference.
            var added: [BitbucketAccount] = [], removed: [BitbucketAccount] = []
            if let change = update.changes?.reviewers {
                added = change.added ?? []
                removed = change.removed ?? []
            } else if let now = update.reviewers, let was = before.reviewers {
                let nowIDs = Set(now.compactMap(\.uuid)), wasIDs = Set(was.compactMap(\.uuid))
                added = now.filter { $0.uuid.map { !wasIDs.contains($0) } ?? false }
                removed = was.filter { $0.uuid.map { !nowIDs.contains($0) } ?? false }
            }
            func reviewers(_ n: Int) -> String { "\(n) \(n == 1 ? "reviewer" : "reviewers")" }
            if !added.isEmpty {
                add(id + "-added", update.author, update.date, "added \(reviewers(added.count))", action: "reviewer",
                    detail: names("+", added))
            }
            if !removed.isEmpty {
                add(id + "-removed", update.author, update.date, "removed \(reviewers(removed.count))",
                    action: "reviewer", detail: names("−", removed))
            }
            previous = update
        }
        for (index, entry) in activity.enumerated() {
            if let approval = entry.approval {
                add("approval-\(index)", approval.user, approval.date, "Approved the pull request", action: "approved")
            }
            if let request = entry.changesRequested {
                add("changes-\(index)", request.user, request.date, "Requested changes", action: "changes_requested")
            }
        }
        for task in tasks {
            let text = MarkdownHTML.escape(task.body)
            add("task-\(task.id)-created", task.creator, task.createdAt, "created a task", action: "task",
                detail: "<p class=\"task\">☐ \(text)</p>")
            if task.isResolved, let date = task.resolvedAt {
                add("task-\(task.id)-resolved", task.resolvedBy, date, "resolved a task", action: "task",
                    detail: "<p class=\"task done\">☑ \(text)</p>")
            }
        }
        return events
    }

    /// The commits after `old` up to and with `new` in `commits` (oldest first), matched by prefix (Bitbucket's
    /// snapshots abbreviate hashes); none when either is not there.
    private static func commits(_ commits: [HostedCommit], after old: String, upTo new: String) -> [HostedCommit] {
        func index(_ hash: String) -> Int? {
            commits.firstIndex { $0.sha.hasPrefix(hash) || hash.hasPrefix($0.sha) }
        }
        guard let end = index(new) else { return [] }
        let start = index(old).map { $0 + 1 } ?? 0
        return start <= end ? Array(commits[start...end]) : []
    }

    /// The pull request's tasks, oldest first.
    public func tasks(of number: Int, in repo: HostedRepository) async throws -> [HostedTask] {
        let tasks: [BitbucketTask] = try await list(url(try pullRequestPath(number, in: repo) + ["tasks"]))
        return tasks.map(Self.task)
    }

    /// `POST .../tasks` with the raw text.
    public func createTask(on number: Int, in repo: HostedRepository, body: String) async throws -> HostedTask {
        struct Body: Encodable { var content: [String: String] }
        let task: BitbucketTask = try await send(
            "POST", url(try pullRequestPath(number, in: repo) + ["tasks"]), body: Body(content: ["raw": body]))
        return Self.task(task)
    }

    /// `PUT .../tasks/{id}` with the state only.
    public func setTask(_ id: Int, resolved: Bool, on number: Int, in repo: HostedRepository) async throws {
        _ = try await perform(
            "PUT", url(try pullRequestPath(number, in: repo) + ["tasks", String(id)]),
            body: try JSONEncoder().encode(["state": resolved ? "RESOLVED" : "UNRESOLVED"]))
    }

    /// `DELETE .../tasks/{id}`.
    public func deleteTask(_ id: Int, on number: Int, in repo: HostedRepository) async throws {
        _ = try await perform("DELETE", url(try pullRequestPath(number, in: repo) + ["tasks", String(id)]))
    }

    private static func task(_ task: BitbucketTask) -> HostedTask {
        HostedTask(
            id: task.id, body: task.content?.raw ?? "", isResolved: task.state == "RESOLVED",
            creator: task.creator?.hosted, createdAt: GitLabDate.parse(task.createdOn), commentID: task.comment?.id,
            resolvedAt: GitLabDate.parse(task.resolvedOn), resolvedBy: task.resolvedBy?.hosted)
    }

    /// `GET .../commit/{sha}/reports`: the Code Insights reports, named by their title (else their reporter), their
    /// page only when it is https.
    public func reports(commit sha: String, in repo: HostedRepository) async throws -> [HostedReport] {
        guard sha.count >= 7, sha.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return [] }
        let reports: [BitbucketReport] = try await list(url(try repoPath(repo) + ["commit", sha, "reports"]))
        return reports.enumerated().map { index, report in
            let link = report.link.flatMap(URL.init(string:)).flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }
            return HostedReport(
                id: report.uuid ?? report.externalId ?? "report-\(index)",
                title: report.title ?? report.reporter ?? "Report", result: report.result,
                reportType: report.reportType, reporter: report.reporter, link: link)
        }
    }

    /// `GET .../mergeability/checks`, each named by Bitbucket where it gives a name, else by its type.
    public func mergeChecks(of number: Int, in repo: HostedRepository) async throws -> [HostedMergeCheck] {
        let checks: [BitbucketMergeCheck] = try await list(
            url(try pullRequestPath(number, in: repo) + ["mergeability", "checks"]))
        return checks.map { check in
            HostedMergeCheck(
                name: check.name ?? Self.checkNames[check.type ?? ""] ?? "Merge check",
                status: check.status ?? "UNKNOWN", required: check.required ?? false,
                blocking: check.blocking ?? false)
        }
    }

    /// The merge checks' types in words, for a check Bitbucket gives no name.
    private static let checkNames = [
        "pullrequest_state_check": "Pull request is open", "current_user_permission_check": "You can merge",
        "git_mergeability_check": "No conflicts", "standard_merge_check": "Merge check",
        "custom_pre_merge_check": "Custom merge check", "custom_on_merge_check": "Runs on merge",
        "merge_queue_check": "Merge queue",
    ]

    // MARK: - Mapping

    /// The head's `owner:branch` label is set only for a branch of the same repository (nil for a fork's, or when
    /// Bitbucket leaves out the repositories). A merged pull request's `mergedAt` is its last update.
    private func pullRequest(_ pr: BitbucketPullRequest, in repo: HostedRepository) -> HostedPullRequest {
        let source = pr.source?.branch?.name ?? ""
        let target = pr.destination?.branch?.name ?? ""
        let merged = pr.state == "MERGED"
        var pull = HostedPullRequest(
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
        (pull.allowedMergeMethods, pull.defaultMergeMethod) = Self.mergeMethods(pr.destination?.branch)
        pull.closesSourceBranch = pr.closeSourceBranch
        pull.openTaskCount = pr.taskCount
        pull.mergedBy = merged ? pr.closedBy?.hosted : nil
        pull.mergeCommitSHA = merged ? pr.mergeCommit?.hash : nil
        return pull
    }

    /// Bitbucket Cloud's strategy ids and the methods they are, in the merge dialog's order.
    private static let strategies: [(id: String, method: HostedMergeMethod)] = [
        ("merge_commit", .merge), ("squash", .squash), ("fast_forward", .fastForward),
        ("squash_fast_forward", .squashFastForward), ("rebase_fast_forward", .rebaseFastForward),
        ("rebase_merge", .rebase),
    ]

    /// The destination branch's strategies and default, which a pull request's response leaves out unless asked for
    /// (the rest of the response stays as it is).
    private static let strategyFields = [
        ("fields", "+destination.branch.merge_strategies,+destination.branch.default_merge_strategy"),
    ]

    /// The strategy id of `method`; nil for Data Center's `fastForwardIfPossible`.
    static func strategy(of method: HostedMergeMethod) -> String? {
        strategies.first { $0.method == method }?.id
    }

    /// The pull request's allowed methods from its destination branch, in the dialog's order (unknown ids left out;
    /// none left reads as nil), and its default when that is one of them.
    static func mergeMethods(_ branch: BitbucketPullRequest.Endpoint.Branch?)
        -> (allowed: [HostedMergeMethod]?, default: HostedMergeMethod?)
    {
        guard let ids = branch?.mergeStrategies else { return (nil, nil) }
        let allowed = strategies.filter { ids.contains($0.id) }.map(\.method)
        guard !allowed.isEmpty else { return (nil, nil) }
        let preferred = strategies.first { $0.id == branch?.defaultMergeStrategy }?.method
        return (allowed, preferred.flatMap { allowed.contains($0) ? $0 : nil })
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

    /// The body a deleted comment kept for its replies shows.
    static let deletedText = "This comment was deleted"

    /// The deleted comments to keep: those with a comment below them (any depth) that is not deleted.
    private static func keptDeleted(_ comments: [BitbucketComment]) -> Set<Int> {
        let parents = Dictionary(comments.map { ($0.id, $0.parent?.id) }, uniquingKeysWith: { a, _ in a })
        var kept: Set<Int> = []
        for comment in comments where comment.deleted != true {
            var next = comment.parent?.id
            var steps = 0
            while let id = next, steps < comments.count, kept.insert(id).inserted {
                next = parents[id] ?? nil
                steps += 1
            }
        }
        return kept
    }

    /// Whether the token's user (`viewer`, its uuid) wrote `comment`, and it is not deleted.
    private static func isOwn(_ comment: BitbucketComment, viewer: String?) -> Bool {
        guard let viewer, let author = comment.user?.uuid, comment.deleted != true else { return false }
        return author == viewer
    }

    /// A general comment: `parentID` its direct parent, a top-level one `resolvable`, rights when `viewer` wrote it,
    /// and `deletedText` (no rights) for a deleted one.
    private static func comment(_ comment: BitbucketComment, viewer: String? = nil) -> HostedComment {
        let deleted = comment.deleted == true
        let own = isOwn(comment, viewer: viewer)
        let topLevel = comment.parent == nil
        var mapped = HostedComment(
            id: comment.id, user: comment.user?.hosted, body: deleted ? deletedText : comment.content?.raw,
            bodyHTML: deleted ? MarkdownHTML.html(deletedText) : html(comment.content),
            htmlURL: comment.links?.html?.href, createdAt: GitLabDate.parse(comment.createdOn),
            updatedAt: GitLabDate.parse(comment.updatedOn), parentID: comment.parent?.id,
            resolvable: topLevel ? !deleted : nil, resolved: topLevel ? comment.resolution != nil : nil)
        (mapped.viewerCanEdit, mapped.viewerCanDelete) = (own, own)
        return mapped
    }

    /// A general comment the token's user just wrote: theirs to edit and delete.
    private static func created(_ comment: BitbucketComment) -> HostedComment {
        var mapped = Self.comment(comment)
        (mapped.viewerCanEdit, mapped.viewerCanDelete) = (true, true)
        return mapped
    }

    /// An inline comment the token's user just wrote, placed by its `inline` (else on `fallbackPath`).
    private static func created(_ comment: BitbucketComment, inReplyTo root: Int?, fallbackPath: String)
        -> HostedReviewComment
    {
        let place = comment.inline.map(Self.place)
        var mapped = HostedReviewComment(
            id: comment.id, inReplyToID: root, path: place?.path ?? fallbackPath, line: place?.line,
            originalLine: place?.line, startLine: place?.startLine, originalStartLine: place?.startLine,
            side: place?.side, body: comment.content?.raw, bodyHTML: Self.html(comment.content),
            user: comment.user?.hosted, createdAt: GitLabDate.parse(comment.createdOn),
            htmlURL: comment.links?.html?.href)
        (mapped.viewerCanEdit, mapped.viewerCanDelete) = (true, true)
        return mapped
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
