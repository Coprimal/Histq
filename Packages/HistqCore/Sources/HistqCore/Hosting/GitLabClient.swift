// GitLab's REST v4 API for gitlab.com and GitLab Self-Managed (`https://<host>[/<basePath>]/api/v4`), mapped into the
// hosted models. The `URLSession` is injected, so tests serve inline JSON through a stub `URLProtocol` and never reach
// the network. A project is named by its URL-encoded full path (`group%2Fsub%2Fproject`); a `HostedRepository`'s
// `path` is that full path, relative to the instance's root (an account's base path is not part of it).
//
// The token is a secret: the client asks its provider for it on every request (a constant for a personal access
// token, a refresher for OAuth), and after a 401 asks once more with the refused token and retries that request once.
// It only ever goes in the `Authorization` header of a request under `apiBase` (its origin and base path): a
// `Link: rel="next"` URL outside it is refused, a redirect to another origin or outside the base path is not followed,
// no error or description holds it, and `print`, `dump` and `String(reflecting:)` of a client show only its host.
import Foundation
import Synchronization

public struct GitLabClient: HostingProvider, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    /// Hands out the access token: `rejected` is the token a 401 just refused, so a refreshable one is renewed unless
    /// it already was (a constant personal access token ignores it); nil otherwise.
    public typealias TokenProvider = @Sendable (_ rejected: String?) async throws -> String

    /// The lowercase host the client talks to, with an optional port.
    public let host: String
    /// The path GitLab lives under on `host` (a relative URL root), as segments; empty at the root.
    public let basePath: [String]
    /// `https://<host>[/<basePath>]/api/v4`.
    public let apiBase: URL
    /// The most pages one list follows (100 items each), so a huge project cannot keep a list loading.
    public var maxPages = 10
    private let token: TokenProvider
    private let session: URLSession
    private let memo = Memo()

    /// `basePath` is the relative URL root (`gitlab` for `https://example.com/gitlab`), nil or empty at the root.
    /// Throws `HostingError.invalidHost` for a host or base path that is not plain.
    public init(
        host: String = "gitlab.com", basePath: String? = nil, session: URLSession = .shared,
        token: @escaping TokenProvider
    ) throws {
        guard let validHost = HostingHTTP.validatedHost(host), let segments = Self.basePathSegments(basePath),
            let apiBase = URL(string: "https://\(validHost)" + (segments + ["api", "v4"]).map { "/" + $0 }.joined())
        else {
            throw HostingError.invalidHost(host)
        }
        self.host = validHost
        self.basePath = segments
        self.apiBase = apiBase
        self.token = token
        self.session = session
    }

    public var description: String { "GitLabClient(\(([host] + basePath).joined(separator: "/")))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["host": host, "apiBase": apiBase]) }

    /// What the client remembers between calls: the token's user id, the merge request of each head sha it mapped
    /// (for `checkRuns(for:in:)`, which gets a sha only), the last head of each merge request (for approving), and
    /// the merge request of each thread it mapped (for `setReviewThread(_:resolved:)`, which gets the thread only),
    /// and the discussion of each diff note it mapped (for `reply(to:on:in:body:)` without a `hostKey`). Shared by
    /// copies of the client.
    private final class Memo: Sendable {
        let userID = Mutex<Int?>(nil)
        let mergeRequestByHead = Mutex<[String: Int]>([:])
        let headByMergeRequest = Mutex<[String: String]>([:])
        let mergeRequestByDiscussion = Mutex<[String: (projectID: String, iid: Int)]>([:])
        let discussionByNote = Mutex<[String: String]>([:])
    }

    // MARK: - Hosts and remote URLs

    /// A base path's segments (outer `/` trimmed): letters, digits, `-`, `_`, `.` and `~`, never empty, `.` or `..`;
    /// nil for anything else, `[]` for nil or an empty path.
    static func basePathSegments(_ basePath: String?) -> [String]? {
        let trimmed = (basePath ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return [] }
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.allSatisfy({ isSafeSegment($0, extra: "-_.~") && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return segments
    }

    /// The project of a GitLab remote URL on an instance at the host's root.
    public static func repository(fromRemoteURL url: String) -> HostedRepository? {
        repository(fromRemoteURL: url, basePath: nil)
    }

    /// The project of a GitLab remote URL (the forms of `RemoteURL`): its whole path, subgroups included, at least
    /// a namespace and a project, each segment ASCII letters, digits, `-`, `_` and `.`. An https URL must start with
    /// the instance's `basePath`, which is stripped; an ssh one never carries it. Anything else is nil.
    public static func repository(fromRemoteURL url: String, basePath: String?) -> HostedRepository? {
        guard let remote = RemoteURL(url), let base = basePathSegments(basePath) else { return nil }
        var path = remote.segments
        if url.lowercased().hasPrefix("https://") {
            guard path.starts(with: base) else { return nil }
            path.removeFirst(base.count)
        }
        guard path.count >= 2, path.allSatisfy({ isSafeSegment($0, extra: "-_.") }) else { return nil }
        return HostedRepository(host: remote.host, path: path)
    }

    private static func isSafeSegment(_ text: String, extra: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || extra.unicodeScalars.contains($0))
        }
    }

    // MARK: - HostingProvider

    public var kind: HostingKind { .gitlab }

    /// Everything but requesting changes, which REST has only through draft notes (see Phase 10).
    public var capabilities: HostingCapabilities {
        [.labels, .assignees, .issues, .resolveThreads, .draft, .reopen, .reviewRequests]
    }

    /// What `PUT .../merge` does: a merge (commit or fast-forward, as the project is set up) or a squash. A rebase is
    /// its own endpoint, not a merge method.
    public var mergeMethods: Set<HostedMergeMethod> { [.merge, .squash] }

    /// `merge-requests/<iid>/head`, the ref GitLab keeps for every merge request in the target project, forks' too.
    public func checkout(of pullRequest: HostedPullRequest) -> HostedCheckout {
        .ref("merge-requests/\(pullRequest.number)/head")
    }

    /// `https://<host>[/<basePath>]/<path>`, then `-/tree/<branch>` (a `/` in the branch splits it into segments),
    /// `-/commit/<sha>`, `-/merge_requests/<iid>` or `-/issues/<iid>`, each segment percent-encoded. Nil for a
    /// project on another host than the client's, a path shorter than namespace/project, an empty, `.` or `..`
    /// segment, or a sha that is not hex.
    public func webURL(_ target: HostedWebTarget, in repo: HostedRepository) -> URL? {
        guard repo.host.lowercased() == host, repo.path.count >= 2 else { return nil }
        var segments = repo.path
        switch target {
        case .repository: break
        case .branch(let name):
            segments += ["-", "tree"] + name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        case .commit(let sha):
            guard !sha.isEmpty, sha.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
            segments += ["-", "commit", sha]
        case .pullRequest(let number): segments += ["-", "merge_requests", String(number)]
        case .issue(let number): segments += ["-", "issues", String(number)]
        }
        segments = basePath + segments
        guard !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        let encoded = segments.compactMap { $0.addingPercentEncoding(withAllowedCharacters: Self.segmentAllowed) }
        guard encoded.count == segments.count else { return nil }
        return URL(string: "https://\(host)/" + encoded.joined(separator: "/"))
    }

    public func currentUser() async throws -> HostedUser {
        let user: GitLabUser = try await get(url(["user"]))
        memo.userID.withLock { $0 = user.id }
        return user.hosted
    }

    /// `GET /projects?membership=true&simple=true`: the projects the token's user is a member of, sorted by full
    /// path. Up to 30 pages (3000 projects) rather than `maxPages`: a clone picker must list all of them. The simple
    /// list may leave out `visibility`; such a project shows as not private.
    public func userRepositories() async throws -> [HostedCloneRepository] {
        var client = self
        client.maxPages = 30
        let projects: [GitLabProject] = try await client.list(
            url(["projects"], query: ["membership": "true", "simple": "true"]))
        return projects.compactMap { project -> HostedCloneRepository? in
            guard let cloneURL = project.httpUrlToRepo else { return nil }
            let path = project.pathWithNamespace.split(separator: "/").map(String.init)
            let owner = project.namespace.map {
                HostedUser(id: $0.id, login: $0.fullPath, avatarURL: $0.avatarUrl, htmlURL: $0.webUrl)
            } ?? HostedUser(id: 0, login: path.dropLast().joined(separator: "/"))
            return HostedCloneRepository(
                id: project.id, name: path.last ?? project.name, fullName: project.pathWithNamespace, owner: owner,
                cloneURL: cloneURL, isPrivate: project.visibility.map { $0 != "public" } ?? false,
                fork: project.forkedFromProject.map { _ in true })
        }
        .sorted { $0.fullName.lowercased() < $1.fullName.lowercased() }
    }

    /// `.closed` lists closed and merged merge requests (GitLab tells them apart, GitHub's `closed` does not).
    public func pullRequests(in repo: HostedRepository, state: HostedListState) async throws -> [HostedPullRequest] {
        let path = try projectPath(repo) + ["merge_requests"]
        let states = switch state {
        case .open: ["opened"]
        case .closed: ["closed", "merged"]
        case .all: ["all"]
        }
        var result: [HostedPullRequest] = []
        for state in states {
            let page: [GitLabMergeRequest] = try await list(
                url(path, query: ["state": state, "with_labels_details": "true"]))
            result += page.map { pullRequest($0, in: repo) }
        }
        return result
    }

    /// With `render_html=true`, so `bodyHTML` is GitLab's rendered description.
    public func pullRequest(_ number: Int, in repo: HostedRepository) async throws -> HostedPullRequest {
        pullRequest(try await mergeRequest(number, in: repo), in: repo)
    }

    public func issues(in repo: HostedRepository, state: HostedListState) async throws -> [HostedIssue] {
        let state = state == .open ? "opened" : state.rawValue
        let issues: [GitLabIssue] = try await list(
            url(try projectPath(repo) + ["issues"], query: ["state": state, "with_labels_details": "true"]))
        return issues.map(issue)
    }

    public func issue(_ number: Int, in repo: HostedRepository) async throws -> HostedIssue {
        issue(try await get(url(try projectPath(repo) + ["issues", String(number)])))
    }

    /// The project's open merge requests by the token's user (`author_id`).
    public func myOpenPullRequests(in repo: HostedRepository) async throws -> [HostedIssue] {
        try await openMergeRequests(filter: "author_id", in: repo)
    }

    /// The project's open merge requests with the token's user as a reviewer (`reviewer_id`).
    public func reviewRequestedPullRequests(in repo: HostedRepository) async throws -> [HostedIssue] {
        try await openMergeRequests(filter: "reviewer_id", in: repo)
    }

    /// The project's open issues assigned to the token's user (`assignee_id`).
    public func assignedOpenIssues(in repo: HostedRepository) async throws -> [HostedIssue] {
        let query = ["assignee_id": String(try await myID()), "state": "opened", "with_labels_details": "true"]
        let issues: [GitLabIssue] = try await list(url(try projectPath(repo) + ["issues"], query: query))
        return issues.map(issue)
    }

    /// The notes of an issue or a merge request, oldest first, with HTML from `MarkdownHTML` (REST notes have
    /// none). System notes (`system: true`) and diff notes, which `reviewComments(of:in:)` shows in their threads,
    /// are left out.
    public func comments(on item: HostedItem, in repo: HostedRepository) async throws -> [HostedComment] {
        let notes: [GitLabNote] = try await list(
            url(try itemPath(item, in: repo) + ["notes"], query: ["sort": "asc", "order_by": "created_at"]))
        let page = webURL(Self.webTarget(item), in: repo)
        return notes.filter { $0.system != true && !$0.isDiffNote }.map { Self.comment($0, page: page) }
    }

    /// One review per user: `APPROVED` for each user in the approvals' `approved_by`, else the reviewer's state
    /// (`requested_changes` as `CHANGES_REQUESTED`, `reviewed` as `COMMENTED`, `unapproved` as `DISMISSED`). A
    /// reviewer who has not reviewed yet is no review: the merge request lists them in `requestedReviewers`. Ids are
    /// synthetic, keyed by the user's id.
    public func reviews(of number: Int, in repo: HostedRepository) async throws -> [HostedReview] {
        let path = try projectPath(repo) + ["merge_requests", String(number)]
        async let approvalsAnswer: GitLabApprovals = get(url(path + ["approvals"]))
        async let reviewersAnswer: [GitLabReviewer] = list(url(path + ["reviewers"]))
        let approvers = try await approvalsAnswer.approvedBy ?? []
        let reviewers = try await reviewersAnswer
        var rows: [Int: (user: GitLabUser, state: String, date: String?)] = [:]
        for approver in approvers { rows[approver.user.id] = (approver.user, "APPROVED", approver.approvedAt) }
        for reviewer in reviewers where rows[reviewer.user.id] == nil {
            guard let state = Self.reviewState(reviewer.state) else { continue }
            rows[reviewer.user.id] = (reviewer.user, state, reviewer.createdAt)
        }
        var ids = SyntheticIDs()
        return rows.keys.sorted().compactMap { userID in
            guard let row = rows[userID] else { return nil }
            return HostedReview(
                id: ids.id("review", String(userID)), user: row.user.hosted, state: row.state,
                submittedAt: GitLabDate.parse(row.date))
        }
    }

    /// The notes of every diff thread (`discussions` whose first note is a `DiffNote`), roots and replies, each
    /// reply pointing at its thread's first note. The side and line come from the root's `position`: an added line
    /// (`new_line` only) is `RIGHT`, a removed one (`old_line` only) `LEFT`, an unchanged one (both) `RIGHT` on the new
    /// line; a multi-line comment starts at `line_range.start` on the same side. A position on another head than the
    /// merge request's is outdated: only `originalLine` is set then. The diff hunk is cut from the file's current
    /// patch, from its `@@` header to the commented line, and nil when that line is not in it.
    public func reviewComments(of number: Int, in repo: HostedRepository) async throws -> [HostedReviewComment] {
        let threads = try await diffThreads(of: number, in: repo)
        guard !threads.isEmpty else { return [] }
        async let detail = try? mergeRequest(number, in: repo)
        async let files = try? pullRequestFiles(number, in: repo)
        let head = await detail.flatMap { $0.diffRefs?.headSha ?? $0.sha }
        let patches = Dictionary(
            (await files ?? []).compactMap { file in file.patch.map { (file.filename, $0) } },
            uniquingKeysWith: { a, _ in a })
        let page = webURL(.pullRequest(number), in: repo)
        var result: [HostedReviewComment] = []
        for (_, notes) in threads {
            guard let root = notes.first, let position = root.position else { continue }
            let place = Self.place(position)
            let current = Self.isCurrent(position, head: head)
            let hunk = current
                ? place.line.flatMap { line in patches[place.path].flatMap { Self.hunk($0, side: place.side, line: line) } }
                : nil
            for note in notes {
                result.append(HostedReviewComment(
                    id: note.id, inReplyToID: note.id == root.id ? nil : root.id, path: place.path,
                    line: current ? place.line : nil, originalLine: place.line,
                    startLine: current ? place.startLine : nil, originalStartLine: place.startLine, side: place.side,
                    diffHunk: hunk, body: note.body, bodyHTML: note.body.map(MarkdownHTML.html),
                    user: note.author?.hosted, createdAt: GitLabDate.parse(note.createdAt),
                    htmlURL: Self.noteURL(page, note.id)))
            }
        }
        return result
    }

    /// A state for each diff thread with resolvable notes: the discussion id is its key (resolving and replying
    /// take it), resolved when every resolvable note is, outdated as in `reviewComments(of:in:)`. GitLab does not say
    /// whether the token's user may resolve it (Developer and up, and the merge request's author, may): both flags are
    /// true, and GitLab refuses the others.
    public func reviewThreadStates(of number: Int, in repo: HostedRepository) async throws
        -> [HostedReviewThreadState]
    {
        let threads = try await diffThreads(of: number, in: repo)
        guard !threads.isEmpty else { return [] }
        let detail = try? await mergeRequest(number, in: repo)
        let head = detail.flatMap { $0.diffRefs?.headSha ?? $0.sha }
        let projectID = try projectID(repo)
        memo.mergeRequestByDiscussion.withLock { memo in
            for (id, _) in threads { memo[id] = (projectID, number) }
        }
        return threads.compactMap { id, notes in
            guard let root = notes.first else { return nil }
            let resolvable = notes.filter { $0.resolvable == true }
            guard !resolvable.isEmpty else { return nil }
            return HostedReviewThreadState(
                id: id, isResolved: resolvable.allSatisfy { $0.resolved == true },
                isOutdated: !Self.isCurrent(root.position, head: head), viewerCanResolve: true,
                viewerCanUnresolve: true, rootCommentID: root.id)
        }
    }

    /// GitLab lists them newest first; reversed.
    public func pullRequestCommits(_ number: Int, in repo: HostedRepository) async throws -> [HostedCommit] {
        let commits: [GitLabCommit] = try await list(
            url(try projectPath(repo) + ["merge_requests", String(number), "commits"]))
        return commits.reversed().map { commit in
            HostedCommit(
                sha: commit.id, htmlURL: commit.webUrl,
                commit: .init(
                    message: commit.message ?? commit.title ?? "",
                    author: .init(
                        name: commit.authorName, email: commit.authorEmail,
                        date: GitLabDate.parse(commit.authoredDate))),
                author: nil)
        }
    }

    /// `GET .../diffs`: GitLab's `diff` is already header-less hunks. A binary, collapsed or too large file has no
    /// patch; the line counts are read from the patch.
    public func pullRequestFiles(_ number: Int, in repo: HostedRepository) async throws -> [HostedPullRequestFile] {
        let diffs: [GitLabDiff] = try await list(
            url(try projectPath(repo) + ["merge_requests", String(number), "diffs"]))
        return diffs.map { diff in
            let patch = diff.diff.flatMap { $0.isEmpty || diff.tooLarge == true || diff.collapsed == true ? nil : $0 }
            let lines = patch?.split(separator: "\n", omittingEmptySubsequences: false) ?? []
            let status = if diff.newFile == true { "added" }
                else if diff.deletedFile == true { "removed" }
                else if diff.renamedFile == true { "renamed" }
                else { "modified" }
            return HostedPullRequestFile(
                filename: diff.newPath, status: status, additions: lines.count { $0.hasPrefix("+") },
                deletions: lines.count { $0.hasPrefix("-") }, patch: patch,
                previousFilename: diff.renamedFile == true ? diff.oldPath : nil)
        }
    }

    /// The checks of the open merge request whose head is `ref` (a commit sha; anything else, or a sha no open
    /// merge request has, gives none): the commit's statuses on the source branch (its CI jobs and outside statuses),
    /// and the merge request's head pipeline as one more run when that list misses it (a merge request pipeline,
    /// which runs on `refs/merge-requests/<iid>/head`, a merged-results one on `refs/merge-requests/<iid>/merge`
    /// whose sha is the temporary merge commit, or no status at all) and the merge request's head is still `ref`.
    /// Status ids are GitLab's; the pipeline's is synthetic, probed against them.
    public func checkRuns(for ref: String, in repo: HostedRepository) async throws -> [HostedCheckRun] {
        let projectID = try projectID(repo)
        let key = projectID + "\u{0}" + ref
        var iid = memo.mergeRequestByHead.withLock { $0[key] }
        if iid == nil {
            _ = try await pullRequests(in: repo, state: .open)
            iid = memo.mergeRequestByHead.withLock { $0[key] }
        }
        guard let iid else { return [] }
        let detail = try await mergeRequest(iid, in: repo)
        let statuses: [GitLabCommitStatus] = try await list(
            url(try projectPath(repo) + ["repository", "commits", ref, "statuses"], query: ["ref": detail.sourceBranch]))
        var ids = SyntheticIDs()
        for status in statuses { ids.reserve(status.id) }
        var runs = statuses.map { status in
            let state = Self.checkState(status.status, allowFailure: status.allowFailure ?? false)
            return HostedCheckRun(
                id: status.id, name: status.name, status: state.status, conclusion: state.conclusion,
                htmlURL: status.targetUrl, startedAt: GitLabDate.parse(status.startedAt),
                completedAt: GitLabDate.parse(status.finishedAt))
        }
        if let pipeline = detail.headPipeline, detail.sha == ref,
            pipeline.ref != detail.sourceBranch || statuses.isEmpty
        {
            let state = Self.checkState(pipeline.status, allowFailure: false)
            runs.insert(HostedCheckRun(
                id: ids.id("pipeline", String(pipeline.id)), name: "Pipeline #\(pipeline.id)", status: state.status,
                conclusion: state.conclusion, htmlURL: pipeline.webUrl,
                startedAt: GitLabDate.parse(pipeline.startedAt), completedAt: GitLabDate.parse(pipeline.finishedAt)),
                at: 0)
        }
        return runs
    }

    public func repositoryInfo(_ repo: HostedRepository) async throws -> HostedRepositoryInfo {
        let project: GitLabProject = try await get(url(try projectPath(repo)))
        guard let defaultBranch = project.defaultBranch else {
            throw HostingError.invalidResponse("a project without a default branch")
        }
        return HostedRepositoryInfo(fullName: project.pathWithNamespace, defaultBranch: defaultBranch)
    }

    public func labels(in repo: HostedRepository) async throws -> [HostedLabel] {
        let labels: [GitLabLabel] = try await list(url(try projectPath(repo) + ["labels"]))
        return labels.map(\.hosted)
    }

    /// `GET /projects/:id/users`: the users of the project, its groups' included.
    public func assignableUsers(in repo: HostedRepository) async throws -> [HostedUser] {
        let users: [GitLabUser] = try await list(url(try projectPath(repo) + ["users"]))
        return users.map(\.hosted)
    }

    /// The same users as `assignableUsers(in:)`: any of them can be asked to review.
    public func collaborators(in repo: HostedRepository) async throws -> [HostedUser] {
        try await assignableUsers(in: repo)
    }

    // MARK: - Writes

    /// `POST /projects/:id/merge_requests`. A draft is a `Draft: ` title prefix (GitLab has no draft field), not added
    /// to a title that already has one of GitLab's draft prefixes (`Draft:`, `[Draft]`, `(Draft)`). Only a branch of
    /// the same project: a fork's `owner:branch` head is refused.
    public func createPullRequest(_ pullRequest: NewPullRequest, in repo: HostedRepository) async throws
        -> HostedPullRequest
    {
        guard !pullRequest.head.contains(":") else {
            throw HostingError.validationFailed(message: "a merge request from a fork is not supported yet")
        }
        struct Body: Encodable {
            var sourceBranch, targetBranch, title: String
            var description: String?
            enum CodingKeys: String, CodingKey {
                case sourceBranch = "source_branch", targetBranch = "target_branch", title, description
            }
        }
        let lowered = pullRequest.title.lowercased()
        let isDraftTitle = ["draft:", "[draft]", "(draft)"].contains { lowered.hasPrefix($0) }
        let title = pullRequest.draft && !isDraftTitle ? "Draft: " + pullRequest.title : pullRequest.title
        let mr: GitLabMergeRequest = try await send(
            "POST", url(try projectPath(repo) + ["merge_requests"]),
            body: Body(
                sourceBranch: pullRequest.head, targetBranch: pullRequest.base, title: title,
                description: pullRequest.body))
        return self.pullRequest(mr, in: repo)
    }

    /// Adds `users` to the reviewers, as GitHub does: GitLab's `reviewer_ids` replaces the list, so the merge
    /// request's current reviewers are read first and kept.
    public func requestReviewers(_ users: [HostedUser], on number: Int, in repo: HostedRepository) async throws {
        guard !users.isEmpty else { return }
        let path = try itemPath(.pullRequest(number), in: repo)
        let current: GitLabMergeRequest = try await get(url(path))
        let _: Updated = try await send(
            "PUT", url(path), body: ["reviewer_ids": Self.ids(current.reviewers ?? [], adding: users)])
    }

    /// `add_labels`, which keeps the item's other labels (an unknown label is created).
    public func addLabels(_ names: [String], to item: HostedItem, in repo: HostedRepository) async throws {
        guard !names.isEmpty else { return }
        let _: Updated = try await send(
            "PUT", url(try itemPath(item, in: repo)), body: ["add_labels": names.joined(separator: ",")])
    }

    /// Adds `users` to the assignees, as GitHub does: the item's current assignees are read first and kept.
    public func addAssignees(_ users: [HostedUser], to item: HostedItem, in repo: HostedRepository) async throws {
        guard !users.isEmpty else { return }
        struct Assigned: Decodable { var assignees: [GitLabUser]? }
        let path = try itemPath(item, in: repo)
        let current: Assigned = try await get(url(path))
        let _: Updated = try await send(
            "PUT", url(path), body: ["assignee_ids": Self.ids(current.assignees ?? [], adding: users)])
    }

    public func comment(on item: HostedItem, in repo: HostedRepository, body: String) async throws -> HostedComment {
        let note: GitLabNote = try await send(
            "POST", url(try itemPath(item, in: repo) + ["notes"]), body: ["body": body])
        return Self.comment(note, page: webURL(Self.webTarget(item), in: repo))
    }

    /// `POST .../discussions/:discussion_id/notes`: `thread.hostKey` is the discussion id (the id of
    /// `reviewThreadStates(of:in:)`); without one, the discussion of `rootCommentID` this client mapped in
    /// `reviewComments(of:in:)`. A ref with neither is refused.
    public func reply(to thread: HostedThreadRef, on number: Int, in repo: HostedRepository, body: String)
        async throws -> HostedReviewComment
    {
        let key = try projectID(repo) + "\u{0}\(number)\u{0}\(thread.rootCommentID)"
        let mapped = memo.discussionByNote.withLock { $0[key] }
        guard let discussion = thread.hostKey.flatMap({ $0.isEmpty ? nil : $0 }) ?? mapped else {
            throw HostingError.validationFailed(message: "an unknown GitLab thread: reload the merge request")
        }
        let note: GitLabNote = try await send(
            "POST", url(try itemPath(.pullRequest(number), in: repo) + ["discussions", discussion, "notes"]),
            body: ["body": body])
        let place = note.position.map(Self.place)
        return HostedReviewComment(
            id: note.id, inReplyToID: thread.rootCommentID, path: place?.path ?? "", line: place?.line,
            originalLine: place?.line, startLine: place?.startLine, originalStartLine: place?.startLine,
            side: place?.side, body: note.body, bodyHTML: note.body.map(MarkdownHTML.html), user: note.author?.hosted,
            createdAt: GitLabDate.parse(note.createdAt),
            htmlURL: Self.noteURL(webURL(.pullRequest(number), in: repo), note.id))
    }

    /// `PUT .../discussions/:discussion_id?resolved=`, for a thread this client mapped in `reviewThreadStates(of:in:)`
    /// (the state has no project or merge request); returns whether every resolvable note is resolved in the answer.
    public func setReviewThread(_ state: HostedReviewThreadState, resolved: Bool) async throws -> Bool {
        guard let target = memo.mergeRequestByDiscussion.withLock({ $0[state.id] }) else {
            throw HostingError.validationFailed(message: "an unknown GitLab thread: reload the merge request")
        }
        let path = ["projects", target.projectID, "merge_requests", String(target.iid), "discussions", state.id]
        let (data, _) = try await perform("PUT", url(path, query: ["resolved": resolved ? "true" : "false"]))
        let discussion: GitLabDiscussion = try Self.decode(data)
        let notes = discussion.notes.filter { $0.resolvable == true }
        return !notes.isEmpty && notes.allSatisfy { $0.resolved == true }
    }

    /// `APPROVE` approves (pinned to the head this client last mapped, so a push since then is a 409, thrown as
    /// `HostingError.headChanged`) and posts a non-empty body as a note; `COMMENT` posts the body as a note. GitLab
    /// answers 401 when it refuses the approval (already approved, not allowed): a 401 that the forced token refresh
    /// does not clear is `validationFailed`, not `unauthorized`.
    /// `REQUEST_CHANGES` is refused (no `requestChanges` capability). The review's id follows `reviews(of:in:)`.
    public func review(_ number: Int, in repo: HostedRepository, event: HostedReviewEvent, body: String?)
        async throws -> HostedReview
    {
        guard event != .requestChanges else {
            throw HostingError.validationFailed(message: "GitLab merge requests cannot request changes here")
        }
        let path = try itemPath(.pullRequest(number), in: repo)
        let me = try await myID()
        var ids = SyntheticIDs()
        let id = ids.id("review", String(me))
        let text = body.flatMap { $0.isEmpty ? nil : $0 }
        if event == .comment {
            guard let text else { throw HostingError.validationFailed(message: "a comment needs a body") }
            let note = try await comment(on: .pullRequest(number), in: repo, body: text)
            return HostedReview(
                id: id, user: note.user, state: "COMMENTED", body: note.body, bodyHTML: note.bodyHTML,
                htmlURL: note.htmlURL, submittedAt: note.createdAt)
        }
        let key = try projectID(repo) + "\u{0}\(number)"
        let head = memo.headByMergeRequest.withLock { $0[key] }
        let approvals: GitLabApprovals
        do {
            approvals = try await send("POST", url(path + ["approve"]), body: head.map { ["sha": $0] } ?? [:])
        } catch HostingError.http(status: 409, message: _) {
            throw HostingError.headChanged
        } catch HostingError.unauthorized {
            throw HostingError.validationFailed(
                message: "GitLab refused the approval: you may already have approved, or you may not be allowed to "
                    + "approve this merge request.")
        }
        if let text { _ = try await comment(on: .pullRequest(number), in: repo, body: text) }
        let approver = approvals.approvedBy?.first { $0.user.id == me }
        return HostedReview(
            id: id, user: approver?.user.hosted, state: "APPROVED", body: text, bodyHTML: text.map(MarkdownHTML.html),
            submittedAt: GitLabDate.parse(approver?.approvedAt) ?? Date())
    }

    /// `PUT .../merge`, always with `sha`: a push since the user reviewed makes GitLab answer 409, thrown as
    /// `HostingError.headChanged`. `squash` is sent either way, so the method chosen is the one done.
    public func merge(_ number: Int, in repo: HostedRepository, method: HostedMergeMethod, sha: String) async throws {
        guard mergeMethods.contains(method) else {
            throw HostingError.validationFailed(message: "GitLab merges with a merge commit or a squash only")
        }
        guard !sha.isEmpty else { throw HostingError.validationFailed(message: "a merge needs the head's sha") }
        struct Body: Encodable { var sha: String; var squash: Bool }
        do {
            let _: Updated = try await send(
                "PUT", url(try itemPath(.pullRequest(number), in: repo) + ["merge"]),
                body: Body(sha: sha, squash: method == .squash))
        } catch HostingError.http(status: 409, message: _) {
            // Mapped here only: a 409 of another endpoint means something else.
            throw HostingError.headChanged
        }
    }

    /// `state_event=close|reopen`.
    public func setOpen(_ open: Bool, item: HostedItem, in repo: HostedRepository) async throws {
        let _: Updated = try await send(
            "PUT", url(try itemPath(item, in: repo)), body: ["state_event": open ? "reopen" : "close"])
    }

    /// The answer of an update: only its `iid` is read.
    private struct Updated: Decodable { var iid: Int }

    /// The ids of `current` and then of each of `users` not already in it (a user's `reviewerID`, else its `id`).
    private static func ids(_ current: [GitLabUser], adding users: [HostedUser]) -> [Int] {
        var ids = current.map(\.id)
        for user in users {
            let id = user.reviewerID.flatMap { Int($0) } ?? user.id
            if !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    // MARK: - Mapping

    private func mergeRequest(_ number: Int, in repo: HostedRepository) async throws -> GitLabMergeRequest {
        try await get(url(try projectPath(repo) + ["merge_requests", String(number)], query: ["render_html": "true"]))
    }

    /// Also remembers which merge request has the head, for `checkRuns(for:in:)`, and the head, for approving. The
    /// head's `owner:branch` label is set only for a branch of the same project (nil for a fork's branch, or when
    /// GitLab leaves out the project ids).
    private func pullRequest(_ mr: GitLabMergeRequest, in repo: HostedRepository) -> HostedPullRequest {
        if let sha = mr.sha, let projectID = try? projectID(repo) {
            memo.mergeRequestByHead.withLock { $0[projectID + "\u{0}" + sha] = mr.iid }
            memo.headByMergeRequest.withLock { $0[projectID + "\u{0}\(mr.iid)"] = sha }
        }
        let sameProject = mr.sourceProjectId != nil && mr.sourceProjectId == mr.targetProjectId
        return HostedPullRequest(
            id: mr.id, number: mr.iid, title: mr.title, state: Self.isOpen(mr.state) ? "open" : "closed",
            draft: mr.draft, user: mr.author?.hosted, body: mr.description, bodyHTML: mr.descriptionHtml,
            htmlURL: mr.webUrl,
            head: HostedBranchRef(
                label: sameProject ? repo.owner + ":" + mr.sourceBranch : nil, ref: mr.sourceBranch,
                sha: mr.sha ?? mr.diffRefs?.headSha ?? ""),
            base: HostedBranchRef(
                label: repo.owner + ":" + mr.targetBranch, ref: mr.targetBranch, sha: mr.diffRefs?.startSha ?? ""),
            labels: mr.labels?.map(\.hosted), assignees: mr.assignees?.map(\.hosted),
            requestedReviewers: mr.reviewers?.map(\.hosted), createdAt: GitLabDate.parse(mr.createdAt),
            updatedAt: GitLabDate.parse(mr.updatedAt), mergedAt: GitLabDate.parse(mr.mergedAt),
            merged: mr.state == "merged", mergeable: Self.mergeable(mr.detailedMergeStatus),
            mergeableState: Self.mergeableState(mr.detailedMergeStatus),
            changedFiles: mr.changesCount.flatMap { Int($0) })
    }

    private func issue(_ issue: GitLabIssue) -> HostedIssue {
        HostedIssue(
            id: issue.id, number: issue.iid, title: issue.title, state: Self.isOpen(issue.state) ? "open" : "closed",
            user: issue.author?.hosted, body: issue.description, bodyHTML: issue.description.map(MarkdownHTML.html),
            htmlURL: issue.webUrl, labels: issue.labels?.map(\.hosted), assignees: issue.assignees?.map(\.hosted),
            comments: issue.userNotesCount, createdAt: GitLabDate.parse(issue.createdAt),
            updatedAt: GitLabDate.parse(issue.updatedAt), closedAt: GitLabDate.parse(issue.closedAt))
    }

    /// The project's open merge requests whose `filter` (`author_id`, `reviewer_id`) is the token's user, as
    /// issue-shaped rows (`pullRequest` and `draft` set).
    private func openMergeRequests(filter: String, in repo: HostedRepository) async throws -> [HostedIssue] {
        let query = [filter: String(try await myID()), "state": "opened", "with_labels_details": "true"]
        let mrs: [GitLabMergeRequest] = try await list(url(try projectPath(repo) + ["merge_requests"], query: query))
        return mrs.map { mr in
            _ = pullRequest(mr, in: repo)
            return HostedIssue(
                id: mr.id, number: mr.iid, title: mr.title, state: Self.isOpen(mr.state) ? "open" : "closed",
                user: mr.author?.hosted, body: mr.description, htmlURL: mr.webUrl,
                labels: mr.labels?.map(\.hosted), assignees: mr.assignees?.map(\.hosted),
                comments: mr.userNotesCount, createdAt: GitLabDate.parse(mr.createdAt),
                updatedAt: GitLabDate.parse(mr.updatedAt), pullRequest: .init(url: mr.webUrl), draft: mr.draft)
        }
    }

    /// The token's user's id, asked once (`GET /user`).
    private func myID() async throws -> Int {
        if let id = memo.userID.withLock({ $0 }) { return id }
        return try await currentUser().id
    }

    /// The merge request's diff threads, as discussion id and non-system notes, in GitLab's order. Also remembers
    /// the discussion of each of their notes, for a reply without a `hostKey`.
    private func diffThreads(of number: Int, in repo: HostedRepository) async throws -> [(String, [GitLabNote])] {
        let discussions: [GitLabDiscussion] = try await list(
            url(try projectPath(repo) + ["merge_requests", String(number), "discussions"]))
        let threads = discussions.compactMap { discussion -> (String, [GitLabNote])? in
            let notes = discussion.notes.filter { $0.system != true }
            guard notes.first?.isDiffNote == true else { return nil }
            return (discussion.id, notes)
        }
        let prefix = try projectID(repo) + "\u{0}\(number)\u{0}"
        memo.discussionByNote.withLock { memo in
            for (id, notes) in threads {
                for note in notes { memo[prefix + String(note.id)] = id }
            }
        }
        return threads
    }

    /// `opened`, and `locked` (a merge request being merged), are open; `closed` and `merged` are not.
    private static func isOpen(_ state: String) -> Bool {
        state == "opened" || state == "locked"
    }

    /// `detailed_merge_status` as GitHub's conflict-free `mergeable`: false only for `conflict`, nil while GitLab
    /// still checks, else true (a pipeline, approval or rebase still pending shows in `mergeableState`).
    static func mergeable(_ status: String?) -> Bool? {
        switch status {
        case "conflict": false
        case nil, "checking", "unchecked", "preparing", "approvals_syncing": nil
        default: true
        }
    }

    /// `detailed_merge_status` in GitHub's `mergeable_state` words: `conflict` is `dirty`, `need_rebase` is
    /// `behind`, `mergeable` is `clean`, `draft_status` is `draft`, the checking states are `unknown`, and every
    /// other value (a pipeline, approval, thread or policy that must pass first, and any newer value) is `blocked`.
    static func mergeableState(_ status: String?) -> String? {
        switch status {
        case nil: nil
        case "mergeable": "clean"
        case "conflict": "dirty"
        case "need_rebase": "behind"
        case "draft_status": "draft"
        case "checking", "unchecked", "preparing", "approvals_syncing": "unknown"
        default: "blocked"
        }
    }

    /// A reviewer's state as a review state; nil for one who has not reviewed (`unreviewed`, `review_started`).
    private static func reviewState(_ state: String?) -> String? {
        switch state {
        case "approved": "APPROVED"
        case "requested_changes": "CHANGES_REQUESTED"
        case "reviewed": "COMMENTED"
        case "unapproved": "DISMISSED"
        default: nil
        }
    }

    /// A job's or pipeline's status as a check run's: waiting states are `queued`, `running` and `canceling`
    /// `in_progress`, and the rest `completed` with `success`, `failure` (`neutral` for a job allowed to fail),
    /// `cancelled`, `skipped`, or `manual` (a job waiting for a click, shown as neutral). Any other value is kept.
    static func checkState(_ status: String, allowFailure: Bool) -> (status: String, conclusion: String?) {
        switch status {
        case "created", "waiting_for_resource", "waiting_for_callback", "preparing", "pending", "scheduled":
            ("queued", nil)
        case "running", "canceling": ("in_progress", nil)
        case "success": ("completed", "success")
        case "failed": ("completed", allowFailure ? "neutral" : "failure")
        case "canceled": ("completed", "cancelled")
        case "skipped": ("completed", "skipped")
        case "manual": ("completed", "manual")
        default: (status, nil)
        }
    }

    /// The path, side, line and first line of a diff note's position. The path is the file's new path (a removed
    /// line of a renamed file is still under the file's name in the diff).
    static func place(_ position: GitLabNote.Position) -> (path: String, side: String, line: Int?, startLine: Int?) {
        let path = position.newPath ?? position.oldPath ?? ""
        let (side, line): (String, Int?) = switch (position.oldLine, position.newLine) {
        case (let old?, nil): ("LEFT", old)
        default: ("RIGHT", position.newLine)
        }
        let start = side == "LEFT" ? position.lineRange?.start?.oldLine : position.lineRange?.start?.newLine
        let startLine = start.flatMap { start in line.flatMap { start < $0 ? start : nil } }
        return (path, side, line, startLine)
    }

    /// Whether a position is on the merge request's current head; true when either sha is unknown.
    private static func isCurrent(_ position: GitLabNote.Position?, head: String?) -> Bool {
        guard let positionHead = position?.headSha, let head else { return true }
        return positionHead == head
    }

    /// The lines of `patch` from the `@@` header of the hunk that holds `line` on `side` (`LEFT` old, `RIGHT` new)
    /// through that line; nil when no hunk holds it.
    static func hunk(_ patch: String, side: String, line: Int) -> String? {
        let lines = patch.split(separator: "\n", omittingEmptySubsequences: false)
        var start: Int?
        var old = 0
        var new = 0
        for (index, text) in lines.enumerated() {
            if text.hasPrefix("@@") {
                let numbers = Self.hunkStarts(text)
                start = numbers == nil ? nil : index
                (old, new) = numbers ?? (0, 0)
                continue
            }
            guard let first = start else { continue }
            let isOld = !text.hasPrefix("+") && !text.hasPrefix("\\")
            let isNew = !text.hasPrefix("-") && !text.hasPrefix("\\")
            if (side == "LEFT" && isOld && old == line) || (side != "LEFT" && isNew && new == line) {
                return lines[first...index].joined(separator: "\n")
            }
            if isOld { old += 1 }
            if isNew { new += 1 }
        }
        return nil
    }

    /// The old and new start lines of a `@@ -a[,b] +c[,d] @@` header.
    private static func hunkStarts(_ header: Substring) -> (Int, Int)? {
        let fields = header.split(separator: " ")
        guard fields.count >= 3, fields[1].hasPrefix("-"), fields[2].hasPrefix("+"),
            let old = Int(fields[1].dropFirst().prefix { $0 != "," }),
            let new = Int(fields[2].dropFirst().prefix { $0 != "," })
        else { return nil }
        return (old, new)
    }

    private static func noteURL(_ page: URL?, _ id: Int) -> String? {
        page.map { $0.absoluteString + "#note_\(id)" }
    }

    /// A plain note as a comment, with HTML from `MarkdownHTML` (REST notes have none).
    private static func comment(_ note: GitLabNote, page: URL?) -> HostedComment {
        HostedComment(
            id: note.id, user: note.author?.hosted, body: note.body, bodyHTML: note.body.map(MarkdownHTML.html),
            htmlURL: noteURL(page, note.id), createdAt: GitLabDate.parse(note.createdAt))
    }

    private static func webTarget(_ item: HostedItem) -> HostedWebTarget {
        switch item {
        case .pullRequest(let number): .pullRequest(number)
        case .issue(let number): .issue(number)
        }
    }

    // MARK: - Requests

    /// A path segment's characters: `urlPathAllowed` without `/`, so a `/` inside a segment is encoded.
    private static let segmentAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return allowed
    }()

    /// The project's full path, the id GitLab's project endpoints take (URL-encoded as one segment by `url`).
    private func projectID(_ repo: HostedRepository) throws -> String {
        guard repo.host.lowercased() == host else { throw HostingError.wrongHost(repo.host) }
        guard repo.path.count >= 2, !repo.path.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw HostingError.validationFailed(message: "not a project path: \(repo.path.joined(separator: "/"))")
        }
        return repo.path.joined(separator: "/")
    }

    private func projectPath(_ repo: HostedRepository) throws -> [String] {
        ["projects", try projectID(repo)]
    }

    /// `projects/:id/merge_requests/:iid` or `projects/:id/issues/:iid`.
    private func itemPath(_ item: HostedItem, in repo: HostedRepository) throws -> [String] {
        switch item {
        case .pullRequest(let number): try projectPath(repo) + ["merge_requests", String(number)]
        case .issue(let number): try projectPath(repo) + ["issues", String(number)]
        }
    }

    /// `apiBase` plus `segments`, each percent-encoded as one path segment, and `query`, with `+` as `%2B` (GitLab
    /// reads a bare `+` in a query as a space).
    private func url(_ segments: [String], query: [String: String] = [:]) -> URL {
        var components = URLComponents(url: apiBase, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath += segments
            .map { "/" + ($0.addingPercentEncoding(withAllowedCharacters: Self.segmentAllowed) ?? "") }.joined()
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return components.url!
    }

    /// Whether `url` is under `apiBase`: the same origin, its path `apiBase`'s plus whole segments, none of them `.`
    /// or `..` (percent-decoded), so `/api/v4evil` or `/api/v4/../x` is not.
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

    private func list<T: Decodable>(_ first: URL) async throws -> [T] {
        try await paginated(first) { (page: [T]) in page }
    }

    /// Follows `Link: rel="next"` from `first` (with `per_page=100`), else `X-Next-Page`, up to `maxPages` pages. A
    /// next URL outside `apiBase` throws: following it would send the token there.
    private func paginated<Page: Decodable, Item>(_ first: URL, items: (Page) -> [Item]) async throws -> [Item] {
        var components = URLComponents(url: first, resolvingAgainstBaseURL: false)!
        components.percentEncodedQueryItems = (components.percentEncodedQueryItems ?? [])
            + [URLQueryItem(name: "per_page", value: "100")]
        var next: URL? = components.url!
        var result: [Item] = []
        var pages = 0
        while let url = next, pages < maxPages {
            let (data, response) = try await perform("GET", url)
            let page: Page = try Self.decode(data)
            result += items(page)
            pages += 1
            next = HostingHTTP.nextLink(response.value(forHTTPHeaderField: "Link"))
                ?? Self.nextPage(response.value(forHTTPHeaderField: "X-Next-Page"), of: url)
            if let next, !isUnderAPIBase(next) {
                throw HostingError.invalidResponse("a next-page link to another host")
            }
        }
        return result
    }

    /// `url` with `page` set to `header` when it is a page number, its other query values kept as encoded.
    private static func nextPage(_ header: String?, of url: URL) -> URL? {
        guard let header, let page = Int(header), page > 0,
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.percentEncodedQueryItems = (components.percentEncodedQueryItems ?? []).filter { $0.name != "page" }
            + [URLQueryItem(name: "page", value: String(page))]
        return components.url
    }

    /// The one place a request is made and the token attached, only to a URL under `apiBase`. A 401 asks the
    /// provider for a refreshed token and retries once; a second 401 is `unauthorized`.
    private func perform(_ method: String, _ url: URL, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        guard isUnderAPIBase(url) else { throw HostingError.invalidResponse("a URL outside the API") }
        let token = try await self.token(nil)
        var (data, response) = try await load(method, url, body: body, token: token)
        if response.statusCode == 401 {
            (data, response) = try await load(method, url, body: body, token: try await self.token(token))
        }
        guard (200..<300).contains(response.statusCode) else { throw HostingHTTP.error(for: response, data: data) }
        return (data, response)
    }

    private func load(_ method: String, _ url: URL, body: Data?, token: String) async throws
        -> (Data, HTTPURLResponse)
    {
        guard HostingHTTP.isUsableToken(token) else { throw HostingError.invalidToken }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
