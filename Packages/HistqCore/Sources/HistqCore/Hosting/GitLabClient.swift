// GitLab's REST v4 API for gitlab.com and GitLab Self-Managed (`https://<host>[/<basePath>]/api/v4`), mapped into the
// hosted models. The `URLSession` is injected, so tests serve inline JSON through a stub `URLProtocol` and never reach
// the network. A project is named by its URL-encoded full path (`group%2Fsub%2Fproject`); a `HostedRepository`'s
// `path` is that full path, relative to the instance's root (an account's base path is not part of it).
//
// The token is a secret: the client asks its provider for it on every request (a constant for a personal access
// token, a refresher for OAuth), and after a 401 asks once more with the refused token and retries that request once.
// It only ever goes in the `Authorization` header of a request under `apiBase` (its origin and base path), or to
// `graphQLURL` exactly (requesting changes, note rights and awards, award and issue-thread mutations, which REST
// lacks): a `Link: rel="next"` URL outside `apiBase` is refused, a redirect to another origin or outside the base path
// is not followed, no error or description holds it, and `print`, `dump` and `String(reflecting:)` of a client show
// only its host.
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
    /// `https://<host>[/<basePath>]/api/graphql`: the one URL outside `apiBase` the token goes to, this exact path
    /// only.
    public let graphQLURL: URL
    /// The most pages one list follows (100 items each), so a huge project cannot keep a list loading.
    public var maxPages = 10
    /// The waits between the reads of a merge request while GitLab rebases its source branch
    /// (`rebaseSourceBranch(_:in:sha:)`): short first, longer later, about a minute in all; past the last one the
    /// rebase is reported as still running.
    public var rebasePollDelays: [Duration] = [
        .milliseconds(250), .milliseconds(500), .seconds(1), .seconds(1), .seconds(2), .seconds(2), .seconds(3),
        .seconds(5), .seconds(5), .seconds(10), .seconds(10), .seconds(15),
    ]
    private let token: TokenProvider
    private let session: URLSession
    private let memo = Memo()

    /// `basePath` is the relative URL root (`gitlab` for `https://example.com/gitlab`), nil or empty at the root.
    /// Throws `HostingError.invalidHost` for a host or base path that is not plain.
    public init(
        host: String = "gitlab.com", basePath: String? = nil, session: URLSession = HostingHTTP.session,
        token: @escaping TokenProvider
    ) throws {
        guard let validHost = HostingHTTP.validatedHost(host), let segments = Self.basePathSegments(basePath),
            let apiBase = URL(string: "https://\(validHost)" + (segments + ["api", "v4"]).map { "/" + $0 }.joined()),
            let graphQLURL = URL(
                string: "https://\(validHost)" + (segments + ["api", "graphql"]).map { "/" + $0 }.joined())
        else {
            throw HostingError.invalidHost(host)
        }
        self.host = validHost
        self.basePath = segments
        self.apiBase = apiBase
        self.graphQLURL = graphQLURL
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
    /// `threadLoads` holds the running discussions load of each item (`itemKey`), so the reads of one detail load
    /// share it: removed when it finishes and by a write on the item. `globalIDs` keeps the GraphQL global id of
    /// each note and discussion a load read (`itemKey` + `note`/`discussion` + REST id), which the award and issue
    /// resolve mutations take, and `resolvableDiscussions` the general threads a load found resolvable.
    /// `approvalLoads` holds the running approvals read of each merge request (`itemKey`), as `threadLoads`, so the
    /// reviews and the approval box of one detail load share one `GET .../approvals`.
    private final class Memo: Sendable {
        let userID = Mutex<Int?>(nil)
        let mergeRequestByHead = Mutex<[String: Int]>([:])
        let headByMergeRequest = Mutex<[String: String]>([:])
        let mergeRequestByDiscussion = Mutex<[String: (projectID: String, iid: Int)]>([:])
        let discussionByNote = Mutex<[String: String]>([:])
        let threadLoads = Mutex<[String: (token: UUID, task: Task<GitLabThreads, any Error>)]>([:])
        let globalIDs = Mutex<[String: String]>([:])
        let resolvableDiscussions = Mutex<Set<String>>([])
        let approvalLoads = Mutex<[String: (token: UUID, task: Task<GitLabApprovals, any Error>)]>([:])
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

    /// All of them: requesting changes through GraphQL (REST has it only through draft notes), and revoking an
    /// approval, which GitHub lacks.
    public var capabilities: HostingCapabilities {
        [
            .labels, .assignees, .issues, .requestChanges, .resolveThreads, .draft, .reopen, .reviewRequests,
            .unapprove, .generalReplies, .resolveGeneralThreads, .editComments, .deleteComments, .reactions,
            .newInlineComments, .multiLineInlineComments, .itemReactions, .rebaseSourceBranch, .startThreads,
            .timelineEvents,
        ]
    }

    /// Deleting the source branch once merged (`should_remove_source_branch`).
    public var supportedMergeOptions: Set<HostedMergeOption> { [.deleteSourceBranch] }

    /// What `PUT .../merge` does: a merge (commit or fast-forward, as the project is set up) or a squash. A rebase is
    /// its own endpoint, not a merge method.
    public var mergeMethods: Set<HostedMergeMethod> { [.merge, .squash] }

    /// GitLab's default emoji reactions, as its picker shows them first. Any other emoji name a note already has
    /// still shows in its `reactions`.
    public var reactionKinds: [String] {
        ["thumbsup", "thumbsdown", "laughing", "tada", "confused", "heart", "rocket", "eyes"]
    }

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

    /// The general discussions of an issue or a merge request in GitLab's order, each root followed by its replies
    /// (`parentID` the root's id: GitLab nests one level), with HTML from `MarkdownHTML` (REST notes have none).
    /// `hostKey` is the discussion id, which replying and resolving take; a root is `resolvable` as its note is.
    /// System notes and diff threads, which `reviewComments(of:in:)` shows, are left out. Rights and reactions come
    /// from the load's GraphQL read (`threads(of:in:)`).
    public func comments(on item: HostedItem, in repo: HostedRepository) async throws -> [HostedComment] {
        let threads = try await threads(of: item, in: repo)
        let page = webURL(Self.webTarget(item), in: repo)
        let itemKey = try itemKey(item, in: repo)
        var result: [HostedComment] = []
        for discussion in threads.discussions {
            let notes = discussion.notes.filter { $0.system != true }
            guard let root = notes.first, !root.isDiffNote else { continue }
            let resolvableNotes = notes.filter { $0.resolvable == true }
            let resolvable = root.resolvable == true
            if resolvable {
                memo.resolvableDiscussions.withLock { _ = $0.insert(itemKey + "\u{0}" + discussion.id) }
            }
            for note in notes {
                var comment = self.comment(note, page: page)
                comment.parentID = note.id == root.id ? nil : root.id
                comment.hostKey = discussion.id
                if note.id == root.id, resolvable {
                    comment.resolvable = true
                    comment.resolved = threads.discussionResolved?[discussion.id]
                        ?? resolvableNotes.allSatisfy { $0.resolved == true }
                    if comment.resolved == true {
                        (comment.resolvedBy, comment.resolvedAt) = Self.resolution(
                            of: discussion.id, notes: resolvableNotes, in: threads)
                    }
                }
                let state = viewerState(of: note, in: threads)
                (comment.viewerCanEdit, comment.viewerCanDelete) = (state.canAdmin, state.canAdmin)
                comment.reactions = state.reactions
                result.append(comment)
            }
        }
        return result
    }

    /// One review per user: `APPROVED` for each user in the approvals' `approved_by`, else the reviewer's state
    /// (`requested_changes` as `CHANGES_REQUESTED`, `reviewed` as `COMMENTED`, `unapproved` as `DISMISSED`). A
    /// reviewer who has not reviewed yet is no review: the merge request lists them in `requestedReviewers`. Ids are
    /// synthetic, keyed by the user's id.
    public func reviews(of number: Int, in repo: HostedRepository) async throws -> [HostedReview] {
        let path = try projectPath(repo) + ["merge_requests", String(number)]
        async let approvalsAnswer = sharedApprovals(number, in: repo)
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
    /// `hostKey` is the discussion id; rights and reactions come from the load's GraphQL read, as in
    /// `comments(on:in:)`.
    public func reviewComments(of number: Int, in repo: HostedRepository) async throws -> [HostedReviewComment] {
        let (threads, load) = try await diffThreads(of: number, in: repo)
        guard !threads.isEmpty else { return [] }
        async let detail = try? mergeRequest(number, in: repo)
        async let files = try? pullRequestFiles(number, in: repo)
        let head = await detail.flatMap { $0.diffRefs?.headSha ?? $0.sha }
        let patches = Dictionary(
            (await files ?? []).compactMap { file in file.patch.map { (file.filename, $0) } },
            uniquingKeysWith: { a, _ in a })
        let page = webURL(.pullRequest(number), in: repo)
        var result: [HostedReviewComment] = []
        for (id, notes) in threads {
            guard let root = notes.first, let position = root.position else { continue }
            let resolvable = notes.filter { $0.resolvable == true }
            let resolution = !resolvable.isEmpty && resolvable.allSatisfy { $0.resolved == true }
                ? Self.resolution(of: id, notes: resolvable, in: load) : (nil, nil)
            let place = Self.place(position)
            let current = Self.isCurrent(position, head: head)
            let hunk = current
                ? place.line.flatMap { line in patches[place.path].flatMap { Self.hunk($0, side: place.side, line: line) } }
                : nil
            for note in notes {
                var comment = HostedReviewComment(
                    id: note.id, inReplyToID: note.id == root.id ? nil : root.id, path: place.path,
                    line: current ? place.line : nil, originalLine: place.line,
                    startLine: current ? place.startLine : nil, originalStartLine: place.startLine, side: place.side,
                    diffHunk: hunk, body: note.body, bodyHTML: note.body.map(markdownHTML),
                    user: note.author?.hosted, createdAt: GitLabDate.parse(note.createdAt),
                    htmlURL: Self.noteURL(page, note.id))
                comment.hostKey = id
                if note.id == root.id { (comment.resolvedBy, comment.resolvedAt) = resolution }
                let state = viewerState(of: note, in: load)
                (comment.viewerCanEdit, comment.viewerCanDelete) = (state.canAdmin, state.canAdmin)
                comment.reactions = state.reactions
                result.append(comment)
            }
        }
        return result
    }

    /// A state for each diff thread with resolvable notes: the discussion id is its key (resolving and replying
    /// take it), resolved when every resolvable note is, outdated as in `reviewComments(of:in:)`. GitLab does not say
    /// whether the token's user may resolve it (Developer and up, and the merge request's author, may): both flags are
    /// true, and GitLab refuses the others. (The load's GraphQL `resolveNote` is read but not applied yet.)
    public func reviewThreadStates(of number: Int, in repo: HostedRepository) async throws
        -> [HostedReviewThreadState]
    {
        let (threads, _) = try await diffThreads(of: number, in: repo)
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

    /// With the project's merge rules: `merge_method` `merge` and `rebase_merge` add a merge commit, `ff` does not;
    /// `squash_option` as sent (an unknown value is nil).
    public func repositoryInfo(_ repo: HostedRepository) async throws -> HostedRepositoryInfo {
        let project: GitLabProject = try await get(url(try projectPath(repo)))
        guard let defaultBranch = project.defaultBranch else {
            throw HostingError.invalidResponse("a project without a default branch")
        }
        let mergeCommit: Bool? = switch project.mergeMethod {
        case "merge", "rebase_merge": true
        case "ff": false
        default: nil
        }
        return HostedRepositoryInfo(
            fullName: project.pathWithNamespace, defaultBranch: defaultBranch, mergeCommit: mergeCommit,
            squashOption: project.squashOption.flatMap(HostedSquashOption.init(rawValue:)))
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

    /// `GET /projects/:id/members/all?user_ids[]=…`: the role of each of `userIDs` on the project, its groups' members
    /// included (GitLab returns a user's highest access), by user id, in GitLab's words; at most 100 ids a request.
    /// A user who is not a member, or has an access level Histq does not know, is left out.
    public func memberRoles(of userIDs: [Int], in repo: HostedRepository) async throws -> [Int: String] {
        let ids = Array(Set(userIDs.filter { $0 > 0 })).sorted()
        guard !ids.isEmpty else { return [:] }
        let path = try projectPath(repo) + ["members", "all"]
        var roles: [Int: String] = [:]
        for start in stride(from: 0, to: ids.count, by: 100) {
            var components = URLComponents(url: url(path), resolvingAgainstBaseURL: false)!
            components.percentEncodedQueryItems = ids[start..<min(start + 100, ids.count)]
                .map { URLQueryItem(name: "user_ids%5B%5D", value: String($0)) }
            let members: [GitLabMember] = try await list(components.url!)
            for member in members {
                if let role = Self.roleNames[member.accessLevel] { roles[member.id] = role }
            }
        }
        return roles
    }

    /// GitLab's access levels by name, as its page badges them.
    private static let roleNames = [
        10: "Guest", 15: "Planner", 20: "Reporter", 25: "Security Manager", 30: "Developer", 40: "Maintainer",
        50: "Owner",
    ]

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
        defer { forgetThreads(of: item, in: repo) }
        let note: GitLabNote = try await send(
            "POST", url(try itemPath(item, in: repo) + ["notes"]), body: ["body": body])
        var comment = self.comment(note, page: webURL(Self.webTarget(item), in: repo))
        // The token's user wrote it: theirs to edit and delete. `GitLabNote` decodes no discussion id, so `hostKey`
        // stays nil: the reload after the post maps it.
        (comment.viewerCanEdit, comment.viewerCanDelete) = (true, true)
        return comment
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
        defer { forgetThreads(of: .pullRequest(number), in: repo) }
        let note: GitLabNote = try await send(
            "POST", url(try itemPath(.pullRequest(number), in: repo) + ["discussions", discussion, "notes"]),
            body: ["body": body])
        let place = note.position.map(Self.place)
        return HostedReviewComment(
            id: note.id, inReplyToID: thread.rootCommentID, path: place?.path ?? "", line: place?.line,
            originalLine: place?.line, startLine: place?.startLine, originalStartLine: place?.startLine,
            side: place?.side, body: note.body, bodyHTML: note.body.map(markdownHTML), user: note.author?.hosted,
            createdAt: GitLabDate.parse(note.createdAt),
            htmlURL: Self.noteURL(webURL(.pullRequest(number), in: repo), note.id))
    }

    /// `PUT .../discussions/:discussion_id?resolved=`, for a thread this client mapped in `reviewThreadStates(of:in:)`
    /// (the state has no project or merge request); returns whether every resolvable note is resolved in the answer.
    public func setReviewThread(_ state: HostedReviewThreadState, resolved: Bool) async throws -> Bool {
        guard let target = memo.mergeRequestByDiscussion.withLock({ $0[state.id] }) else {
            throw HostingError.validationFailed(message: "an unknown GitLab thread: reload the merge request")
        }
        defer { forgetThreads(key: target.projectID + "\u{0}merge_requests\u{0}\(target.iid)") }
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
    /// `REQUEST_CHANGES` runs GraphQL's `mergeRequestRequestChanges` (REST has it only through draft notes), then
    /// posts a non-empty body as a note once it succeeded; a GraphQL error, top-level or the mutation's, is thrown
    /// as `HostingError.graphQL` and posts nothing. The review's id follows `reviews(of:in:)`.
    public func review(_ number: Int, in repo: HostedRepository, event: HostedReviewEvent, body: String?)
        async throws -> HostedReview
    {
        let path = try itemPath(.pullRequest(number), in: repo)
        let text = body.flatMap { $0.isEmpty ? nil : $0 }
        if event == .requestChanges { return try await requestChanges(number, in: repo, body: text) }
        let me = try await myID()
        var ids = SyntheticIDs()
        let id = ids.id("review", String(me))
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
            id: id, user: approver?.user.hosted, state: "APPROVED", body: text, bodyHTML: text.map(markdownHTML),
            submittedAt: GitLabDate.parse(approver?.approvedAt) ?? Date())
    }

    /// The `REQUEST_CHANGES` review: the mutation, with the project's full path and the merge request's iid as
    /// variables, then the body as a note only once it succeeded (a refused mutation leaves no note).
    private func requestChanges(_ number: Int, in repo: HostedRepository, body text: String?) async throws
        -> HostedReview
    {
        let projectPath = try projectID(repo)
        let me = try await currentUser()
        struct Variables: Encodable { var projectPath, iid: String }
        struct Payload: Decodable { var errors: [String]? }
        struct Answer: Decodable { var mergeRequestRequestChanges: Payload? }
        let answer: Answer = try await graphQL(
            "mutation($projectPath: ID!, $iid: String!) { mergeRequestRequestChanges(input: "
                + "{projectPath: $projectPath, iid: $iid}) { errors mergeRequest { iid } } }",
            variables: Variables(projectPath: projectPath, iid: String(number)))
        guard let payload = answer.mergeRequestRequestChanges else {
            throw HostingError.invalidResponse("a change request without its result")
        }
        if let errors = payload.errors, !errors.isEmpty {
            throw HostingError.graphQL(message: String(errors.joined(separator: "; ").prefix(500)))
        }
        if let text { _ = try await comment(on: .pullRequest(number), in: repo, body: text) }
        var ids = SyntheticIDs()
        return HostedReview(
            id: ids.id("review", String(me.id)), user: me, state: "CHANGES_REQUESTED", body: text,
            bodyHTML: text.map(markdownHTML), submittedAt: Date())
    }

    /// `POST .../unapprove`: revokes the token's user's approval. GitLab answers 404 when there is none to revoke (or
    /// it cannot see the merge request), and 401 when it refuses: a 401 that the forced token refresh does not clear
    /// is `validationFailed`, not `unauthorized`, as for approving.
    public func unapprove(_ number: Int, in repo: HostedRepository) async throws {
        let target = url(try itemPath(.pullRequest(number), in: repo) + ["unapprove"])
        do {
            _ = try await perform("POST", target)
        } catch HostingError.notFound {
            throw HostingError.validationFailed(
                message: "GitLab found no approval of yours to revoke on this merge request (or cannot see it).")
        } catch HostingError.unauthorized {
            throw HostingError.validationFailed(
                message: "GitLab refused to revoke the approval: you may not be allowed to on this merge request.")
        }
    }

    /// `PUT .../merge`, always with `sha`: a push since the user reviewed makes GitLab answer 409, thrown as
    /// `HostingError.headChanged`. `squash` is sent either way, so the method chosen is the one done.
    public func merge(_ number: Int, in repo: HostedRepository, method: HostedMergeMethod, sha: String) async throws {
        try await merge(number, in: repo, method: method, sha: sha, options: HostedMergeOptions())
    }

    /// As `merge(_:in:method:sha:)`, with `should_remove_source_branch` when `options` sets it (true or false: left
    /// out, GitLab follows the merge request's own `force_remove_source_branch`).
    public func merge(
        _ number: Int, in repo: HostedRepository, method: HostedMergeMethod, sha: String, options: HostedMergeOptions
    ) async throws {
        guard mergeMethods.contains(method) else {
            throw HostingError.validationFailed(message: "GitLab merges with a merge commit or a squash only")
        }
        guard !sha.isEmpty else { throw HostingError.validationFailed(message: "a merge needs the head's sha") }
        struct Body: Encodable {
            var sha: String
            var squash: Bool
            var shouldRemoveSourceBranch: Bool?

            enum CodingKeys: String, CodingKey {
                case sha, squash
                case shouldRemoveSourceBranch = "should_remove_source_branch"
            }
        }
        do {
            let _: Updated = try await send(
                "PUT", url(try itemPath(.pullRequest(number), in: repo) + ["merge"]),
                body: Body(sha: sha, squash: method == .squash, shouldRemoveSourceBranch: options.deleteSourceBranch))
        } catch HostingError.http(status: 409, message: _) {
            // Mapped here only: a 409 of another endpoint means something else.
            throw HostingError.headChanged
        }
    }

    /// `GET .../approvals` (shared with `reviews(of:in:)` in one detail load): `approvals_required` and
    /// `approvals_left` only where GitLab sends them (Community Edition does not: approval is optional there).
    public func approvals(of number: Int, in repo: HostedRepository) async throws -> HostedApprovals {
        let answer = try await sharedApprovals(number, in: repo)
        return HostedApprovals(
            required: answer.approvalsRequired, left: answer.approvalsLeft,
            approvedBy: (answer.approvedBy ?? []).map(\.user.hosted), viewerCanApprove: answer.userCanApprove,
            viewerHasApproved: answer.userHasApproved)
    }

    /// `PUT .../rebase`, then the merge request read again (`include_rebase_in_progress=true`) after each of
    /// `rebasePollDelays` until `rebase_in_progress` is false: done when `merge_error` is null, else that error is the
    /// failure. GitLab's rebase takes no sha, so the head is checked right before the `PUT` instead: not atomic, a push
    /// between the two is rebased too. GitLab's own refusals (403 protected or missing branch, 409 the rebase could not
    /// be queued) are thrown as they come (a 409 here is not `headChanged`).
    public func rebaseSourceBranch(_ number: Int, in repo: HostedRepository, sha: String) async throws {
        let path = try itemPath(.pullRequest(number), in: repo)
        guard try await mergeRequest(number, in: repo).sha == sha else { throw HostingError.headChanged }
        _ = try await perform("PUT", url(path + ["rebase"]))
        for delay in rebasePollDelays {
            try await Task.sleep(for: delay)
            let mr = try await mergeRequest(number, in: repo)
            guard mr.rebaseInProgress != true else { continue }
            if let error = mr.mergeError, !error.isEmpty {
                throw HostingError.validationFailed(message: String(error.prefix(500)))
            }
            return
        }
        throw HostingError.validationFailed(
            message: "GitLab is still rebasing the source branch: reload the merge request in a moment.")
    }

    /// `state_event=close|reopen`.
    public func setOpen(_ open: Bool, item: HostedItem, in repo: HostedRepository) async throws {
        let _: Updated = try await send(
            "PUT", url(try itemPath(item, in: repo)), body: ["state_event": open ? "reopen" : "close"])
    }

    // MARK: - Comment interactions

    /// `POST .../discussions/:discussion_id/notes` on the merge request or issue: `comment` is the thread's root
    /// (GitLab nests one level) and its `hostKey` the discussion id. An individual note becomes a thread, as on the
    /// web page. A ref without a discussion id is refused unsent.
    public func reply(
        toGeneral comment: HostedCommentRef, on item: HostedItem, in repo: HostedRepository, body: String
    ) async throws -> HostedComment {
        let discussion = try Self.discussionID(of: comment)
        let path = try itemPath(item, in: repo) + ["discussions", discussion, "notes"]
        defer { forgetThreads(of: item, in: repo) }
        let note: GitLabNote = try await send("POST", url(path), body: ["body": body])
        var reply = self.comment(note, page: webURL(Self.webTarget(item), in: repo))
        reply.parentID = comment.id
        reply.hostKey = discussion
        (reply.viewerCanEdit, reply.viewerCanDelete) = (true, true)
        return reply
    }

    /// Resolves or reopens a general thread the client's last load found `resolvable` (anything else is refused
    /// unsent): a merge request's with `PUT .../discussions/:discussion_id?resolved=`, an issue's with GraphQL
    /// `discussionToggleResolve` (REST has none for issues) on the discussion's global id from that load. Returns
    /// whether the answer says it is resolved.
    public func setGeneralThread(
        _ root: HostedCommentRef, on item: HostedItem, in repo: HostedRepository, resolved: Bool
    ) async throws -> Bool {
        let discussion = try Self.discussionID(of: root)
        let key = try itemKey(item, in: repo)
        guard memo.resolvableDiscussions.withLock({ $0.contains(key + "\u{0}" + discussion) }) else {
            throw HostingError.validationFailed(message: "a GitLab thread that cannot be resolved: reload it")
        }
        if Self.isMergeRequest(item) {
            let path = try itemPath(item, in: repo) + ["discussions", discussion]
            defer { forgetThreads(key: key) }
            let (data, _) = try await perform("PUT", url(path, query: ["resolved": resolved ? "true" : "false"]))
            let answer: GitLabDiscussion = try Self.decode(data)
            let notes = answer.notes.filter { $0.resolvable == true }
            return !notes.isEmpty && notes.allSatisfy { $0.resolved == true }
        }
        guard let globalID = memo.globalIDs.withLock({ $0[key + "\u{0}discussion\u{0}" + discussion] }) else {
            throw HostingError.validationFailed(message: "a GitLab thread without its GraphQL id: reload the issue")
        }
        struct Variables: Encodable { var id: String; var resolve: Bool }
        struct Payload: Decodable {
            var errors: [String]?
            var discussion: Discussion?
        }
        struct Discussion: Decodable { var resolved: Bool? }
        struct Answer: Decodable { var discussionToggleResolve: Payload? }
        defer { forgetThreads(key: key) }
        let answer: Answer = try await graphQL(
            "mutation DiscussionToggleResolve($id: DiscussionID!, $resolve: Boolean!) { discussionToggleResolve("
                + "input: {id: $id, resolve: $resolve}) { errors discussion { resolved } } }",
            variables: Variables(id: globalID, resolve: resolved))
        guard let payload = answer.discussionToggleResolve else {
            throw HostingError.invalidResponse("a thread resolve without its result")
        }
        try Self.throwMutationErrors(payload.errors)
        return payload.discussion?.resolved ?? resolved
    }

    /// `PUT .../notes/:note_id` with only the new body (never the deprecated `confidential`), on the merge request
    /// or issue, a general or a diff note alike.
    public func editComment(_ comment: HostedCommentRef, on item: HostedItem, in repo: HostedRepository, body: String)
        async throws
    {
        struct Edited: Decodable { var id: Int }
        let path = try itemPath(item, in: repo) + ["notes", String(comment.id)]
        defer { forgetThreads(of: item, in: repo) }
        let _: Edited = try await send("PUT", url(path), body: ["body": body])
    }

    /// `DELETE .../notes/:note_id` on the merge request or issue, answered 204 without a body.
    public func deleteComment(_ comment: HostedCommentRef, on item: HostedItem, in repo: HostedRepository)
        async throws
    {
        let path = try itemPath(item, in: repo) + ["notes", String(comment.id)]
        defer { forgetThreads(of: item, in: repo) }
        _ = try await perform("DELETE", url(path))
    }

    /// GraphQL `awardEmojiAdd` on the note's global id from the client's last load: no award id is needed, and no
    /// REST call per note. `kind` is an emoji name (one of `reactionKinds`, or one a note already has).
    public func addReaction(
        _ kind: String, to comment: HostedCommentRef, on item: HostedItem, in repo: HostedRepository
    ) async throws {
        try await setAward(kind, on: "note\u{0}\(comment.id)", item: item, in: repo, added: true)
    }

    /// GraphQL `awardEmojiRemove` on the note's global id, as `addReaction(_:to:on:in:)`.
    public func removeReaction(
        _ kind: String, from comment: HostedCommentRef, on item: HostedItem, in repo: HostedRepository
    ) async throws {
        try await setAward(kind, on: "note\u{0}\(comment.id)", item: item, in: repo, added: false)
    }

    /// The merge request's or issue's own award emoji, from the load's GraphQL read (`threads(of:in:)`: the item's
    /// `awardEmoji` rides the first `NoteStates` page, so a detail load that reads the comments too makes no extra
    /// request), counted as a note's are. Throws when that read failed: the awards are unknown and no award can be
    /// written without the item's global id.
    public func itemReactions(of item: HostedItem, in repo: HostedRepository) async throws -> [HostedReaction] {
        let load = try await threads(of: item, in: repo)
        guard let awards = load.itemAwards else {
            throw HostingError.invalidResponse("GitLab did not give the emoji reactions")
        }
        return reactions(awards, viewerID: load.viewerID)
    }

    /// GraphQL `awardEmojiAdd` on the merge request's or issue's global id from the client's last load.
    public func addItemReaction(_ kind: String, to item: HostedItem, in repo: HostedRepository) async throws {
        try await setAward(kind, on: "item", item: item, in: repo, added: true)
    }

    /// GraphQL `awardEmojiRemove` on the merge request's or issue's global id, as `addItemReaction(_:to:in:)`.
    public func removeItemReaction(_ kind: String, from item: HostedItem, in repo: HostedRepository) async throws {
        try await setAward(kind, on: "item", item: item, in: repo, added: false)
    }

    /// `POST .../merge_requests/:iid/discussions` with a text `position` on the merge request's current `diff_refs`
    /// (`base_sha`, `start_sha`, `head_sha`): `new_line` for an added line, `old_line` for a removed one, both for a
    /// context line, `old_path`/`new_path` (the same without a rename), and `line_range` from the start line for a
    /// range (each end's `type` `new` added, `old` removed, none for context; no `line_code`, which needs both line
    /// numbers). Refused unsent when a line its kind needs is missing, when the merge request has no `diff_refs`, and
    /// (`HostingError.headChanged`) when its head is not the one the patch was loaded at.
    public func createInlineComment(
        at position: HostedInlinePosition, on number: Int, in repo: HostedRepository, body: String
    ) async throws -> HostedReviewComment {
        struct Point: Encodable {
            var type: String?
            var oldLine, newLine: Int?
            enum CodingKeys: String, CodingKey {
                case type, oldLine = "old_line", newLine = "new_line"
            }
        }
        struct LineRange: Encodable { var start, end: Point }
        struct Position: Encodable {
            var positionType = "text"
            var baseSHA, startSHA, headSHA, oldPath, newPath: String
            var oldLine, newLine: Int?
            var lineRange: LineRange?
            enum CodingKeys: String, CodingKey {
                case positionType = "position_type", baseSHA = "base_sha", startSHA = "start_sha"
                case headSHA = "head_sha", oldPath = "old_path", newPath = "new_path", oldLine = "old_line"
                case newLine = "new_line", lineRange = "line_range"
            }
        }
        struct Body: Encodable {
            var body: String
            var position: Position
        }
        func point(_ kind: HostedInlinePosition.LineKind, old: Int?, new: Int?) throws -> Point {
            switch (kind, old, new) {
            case (.added, _, let new?): Point(type: "new", newLine: new)
            case (.removed, let old?, _): Point(type: "old", oldLine: old)
            case (.context, let old?, let new?): Point(oldLine: old, newLine: new)
            default: throw HostingError.validationFailed(message: "a diff line without the line numbers it needs")
            }
        }
        let end = try point(position.lineKind, old: position.oldLine, new: position.newLine)
        var range: LineRange?
        switch (position.startOldLine, position.startNewLine) {
        case (nil, nil): break
        case (let old?, let new?): range = LineRange(start: try point(.context, old: old, new: new), end: end)
        case (nil, let new): range = LineRange(start: try point(.added, old: nil, new: new), end: end)
        case (let old, nil): range = LineRange(start: try point(.removed, old: old, new: nil), end: end)
        }
        let detail = try await mergeRequest(number, in: repo)
        guard let refs = detail.diffRefs, let base = refs.baseSha, let start = refs.startSha, let head = refs.headSha,
            ![base, start, head].contains("")
        else {
            throw HostingError.validationFailed(message: "the merge request has no diff yet: reload it")
        }
        guard head == position.headSHA else { throw HostingError.headChanged }
        let path = try itemPath(.pullRequest(number), in: repo) + ["discussions"]
        defer { forgetThreads(of: .pullRequest(number), in: repo) }
        let discussion: GitLabDiscussion = try await send(
            "POST", url(path),
            body: Body(
                body: body,
                position: Position(
                    baseSHA: base, startSHA: start, headSHA: head, oldPath: position.oldPath ?? position.path,
                    newPath: position.path, oldLine: end.oldLine, newLine: end.newLine, lineRange: range)))
        guard let note = discussion.notes.first else {
            throw HostingError.invalidResponse("a new diff thread without its note")
        }
        let place = note.position.map(Self.place)
        var comment = HostedReviewComment(
            id: note.id, path: place?.path ?? position.path, line: place?.line, originalLine: place?.line,
            startLine: place?.startLine, originalStartLine: place?.startLine, side: place?.side, body: note.body,
            bodyHTML: note.body.map(markdownHTML), user: note.author?.hosted,
            createdAt: GitLabDate.parse(note.createdAt),
            htmlURL: Self.noteURL(webURL(.pullRequest(number), in: repo), note.id))
        comment.hostKey = discussion.id
        (comment.viewerCanEdit, comment.viewerCanDelete) = (true, true)
        return comment
    }

    /// `POST .../discussions` with only the body: a new resolvable general thread on the merge request or issue
    /// (GitLab's "Start thread"; `internal` is not taken there, so never sent).
    public func startThread(on item: HostedItem, in repo: HostedRepository, body: String) async throws
        -> HostedComment
    {
        defer { forgetThreads(of: item, in: repo) }
        let discussion: GitLabDiscussion = try await send(
            "POST", url(try itemPath(item, in: repo) + ["discussions"]), body: ["body": body])
        guard let note = discussion.notes.first else {
            throw HostingError.invalidResponse("a new thread without its note")
        }
        var comment = self.comment(note, page: webURL(Self.webTarget(item), in: repo))
        comment.hostKey = discussion.id
        comment.resolvable = note.resolvable ?? true
        comment.resolved = note.resolved ?? false
        (comment.viewerCanEdit, comment.viewerCanDelete) = (true, true)
        return comment
    }

    // MARK: - History entries

    /// The item's system notes (every `system` note of the load's discussions, inside a thread too, its body as
    /// GitLab sent it, kind and icon from the load's GraphQL read: no extra request) and its state, label and
    /// milestone changes (`resource_state_events`, `resource_label_events`, `resource_milestone_events`, read side by
    /// side, worded by Histq). A resource list GitLab refuses is left out; a failed discussions load fails the read.
    public func timelineEvents(of item: HostedItem, in repo: HostedRepository) async throws
        -> [HostedTimelineEvent]
    {
        let path = try itemPath(item, in: repo)
        async let load = threads(of: item, in: repo)
        async let states: [GitLabResourceEvent]? = try? list(url(path + ["resource_state_events"]))
        async let labels: [GitLabResourceEvent]? = try? list(url(path + ["resource_label_events"]))
        async let milestones: [GitLabResourceEvent]? = try? list(url(path + ["resource_milestone_events"]))
        let threads = try await load
        var events: [HostedTimelineEvent] = []
        for note in threads.discussions.flatMap(\.notes) where note.system == true {
            let state = threads.noteStates?[note.id]
            let text = note.body ?? ""
            events.append(HostedTimelineEvent(
                id: "note-\(note.id)", actor: note.author?.hosted, createdAt: GitLabDate.parse(note.createdAt),
                text: text, textHTML: systemNoteHTML(Self.systemNoteMarkdown(text) { webURL(.commit($0), in: repo) }),
                action: state?.systemAction, icon: state?.systemIcon))
        }
        let mergeRequest = Self.isMergeRequest(item)
        for event in await states ?? [] {
            guard let text = Self.stateWording(event) else { continue }
            let icon = switch event.state {
            case "closed": mergeRequest ? "merge-request-close" : "issue-close"
            case "merged": "merge"
            default: "work-item-issue"
            }
            events.append(Self.event(event, "state", text: text, icon: icon))
        }
        for event in await labels ?? [] {
            let name = event.label.map { " " + Self.reference("~", $0.name) } ?? ""
            let text = (event.action == "remove" ? "removed" : "added") + (name.isEmpty ? " a label" : name + " label")
            events.append(Self.event(event, "label", text: text, icon: "label"))
        }
        for event in await milestones ?? [] {
            let name = event.milestone.map { Self.reference("%", $0.title) }
            let text = event.action == "remove" ? "removed milestone" + (name.map { " " + $0 } ?? "")
                : "changed milestone" + (name.map { " to " + $0 } ?? "")
            events.append(Self.event(event, "milestone", text: text, icon: "milestone"))
        }
        return events
    }

    /// A state event's words: "closed" (with what closed it), "reopened" (GitLab records a reopen as `opened` or
    /// `reopened`), "merged", or the state as sent; nil without a state.
    private static func stateWording(_ event: GitLabResourceEvent) -> String? {
        guard let state = event.state, !state.isEmpty else { return nil }
        switch state {
        case "closed":
            if let iid = event.sourceMergeRequest?.iid { return "closed via merge request !\(iid)" }
            if let sha = event.sourceCommit, !sha.isEmpty { return "closed via commit \(sha.prefix(8))" }
            return "closed"
        case "opened", "reopened": return "reopened"
        default: return state
        }
    }

    /// GitLab's reference form of a label (`~`) or milestone (`%`): the name alone, quoted when it has a space.
    private static func reference(_ sigil: String, _ name: String) -> String {
        name.contains(where: \.isWhitespace) ? "\(sigil)\"\(name)\"" : sigil + name
    }

    private static func event(_ event: GitLabResourceEvent, _ kind: String, text: String, icon: String)
        -> HostedTimelineEvent
    {
        HostedTimelineEvent(
            id: "\(kind)-\(event.id)", actor: event.user?.hosted, createdAt: GitLabDate.parse(event.createdAt),
            // Histq's own wording around host names (labels, milestones): escaped as plain text, so a name written as
            // Markdown (emphasis, an image) never renders as such.
            text: text, textHTML: "<p>\(MarkdownHTML.escape(text))</p>", action: kind, icon: icon)
    }

    /// A resolved discussion's resolver and when: GraphQL's (`discussionResolution`), else the latest `resolved_by`
    /// of its REST notes (merge requests only).
    private static func resolution(of discussion: String, notes: [GitLabNote], in load: GitLabThreads)
        -> (HostedUser?, Date?)
    {
        if let read = load.discussionResolution?[discussion], read.user != nil || read.at != nil {
            return (read.user, read.at)
        }
        let latest = notes.filter { $0.resolvedBy != nil }
            .max { (GitLabDate.parse($0.resolvedAt) ?? .distantPast) < (GitLabDate.parse($1.resolvedAt) ?? .distantPast) }
        return (latest?.resolvedBy?.hosted, GitLabDate.parse(latest?.resolvedAt))
    }

    /// The discussion id a general write takes: the comment's `hostKey`; a ref without one is refused unsent.
    private static func discussionID(of comment: HostedCommentRef) throws -> String {
        guard let id = comment.hostKey, !id.isEmpty else {
            throw HostingError.validationFailed(message: "an unknown GitLab thread: reload it")
        }
        return id
    }

    /// Adds or removes the token's user's award `kind` on `awardable` of `item` (`note<NUL><id>` for a note, `item`
    /// for the merge request or issue itself), by its global id from the client's last load (refused unsent without
    /// one, or for an empty name). A mutation's `errors` are thrown.
    private func setAward(
        _ kind: String, on awardable: String, item: HostedItem, in repo: HostedRepository, added: Bool
    ) async throws {
        guard !kind.isEmpty else { throw HostingError.validationFailed(message: "an empty emoji name") }
        let key = try itemKey(item, in: repo)
        guard let awardableID = memo.globalIDs.withLock({ $0[key + "\u{0}" + awardable] }) else {
            let what = awardable == "item" ? "merge request or issue" : "comment"
            throw HostingError.validationFailed(message: "a GitLab \(what) without its GraphQL id: reload it")
        }
        struct Variables: Encodable { var awardableId, name: String }
        struct Payload: Decodable { var errors: [String]? }
        struct Answer: Decodable { var awardEmojiAdd, awardEmojiRemove: Payload? }
        let mutation = added ? "awardEmojiAdd" : "awardEmojiRemove"
        defer { forgetThreads(key: key) }
        let answer: Answer = try await graphQL(
            "mutation \(added ? "AwardEmojiAdd" : "AwardEmojiRemove")($awardableId: AwardableID!, $name: String!) { "
                + "\(mutation)(input: {awardableId: $awardableId, name: $name}) { errors } }",
            variables: Variables(awardableId: awardableID, name: kind))
        guard let payload = added ? answer.awardEmojiAdd : answer.awardEmojiRemove else {
            throw HostingError.invalidResponse("an emoji reaction without its result")
        }
        try Self.throwMutationErrors(payload.errors)
    }

    /// A GraphQL mutation payload's `errors` (GitLab answers 200 with them), the first 500 characters, as
    /// `HostingError.graphQL`.
    private static func throwMutationErrors(_ errors: [String]?) throws {
        if let errors, !errors.isEmpty {
            throw HostingError.graphQL(message: String(errors.joined(separator: "; ").prefix(500)))
        }
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

    /// With the merge box's extras: how far the source branch is behind, and whether a rebase runs.
    private func mergeRequest(_ number: Int, in repo: HostedRepository) async throws -> GitLabMergeRequest {
        try await get(url(
            try projectPath(repo) + ["merge_requests", String(number)],
            query: [
                "render_html": "true", "include_diverged_commits_count": "true",
                "include_rebase_in_progress": "true",
            ]))
    }

    /// The merge request's approvals, read once for the reads of one detail load (`approvalLoads`, as `threads`).
    private func sharedApprovals(_ number: Int, in repo: HostedRepository) async throws -> GitLabApprovals {
        let key = try itemKey(.pullRequest(number), in: repo)
        let target = url(try itemPath(.pullRequest(number), in: repo) + ["approvals"])
        let token = UUID()
        let task = memo.approvalLoads.withLock { loads -> Task<GitLabApprovals, any Error> in
            if let running = loads[key] { return running.task }
            let task = Task { [self] in
                defer { memo.approvalLoads.withLock { if $0[key]?.token == token { $0[key] = nil } } }
                let answer: GitLabApprovals = try await get(target)
                return answer
            }
            loads[key] = (token, task)
            return task
        }
        return try await task.value
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
            changedFiles: mr.changesCount.flatMap { Int($0) },
            mergeDetails: HostedMergeDetails(
                status: mr.detailedMergeStatus, commitsBehind: mr.divergedCommitsCount,
                viewerCanMerge: mr.user?.canMerge,
                deletesSourceBranch: mr.shouldRemoveSourceBranch ?? mr.forceRemoveSourceBranch,
                squashOnMerge: mr.squashOnMerge, mergeError: mr.mergeError,
                rebaseInProgress: mr.rebaseInProgress ?? false),
            milestone: mr.milestone?.hosted, timeStats: mr.timeStats?.hosted)
    }

    private func issue(_ issue: GitLabIssue) -> HostedIssue {
        HostedIssue(
            id: issue.id, number: issue.iid, title: issue.title, state: Self.isOpen(issue.state) ? "open" : "closed",
            user: issue.author?.hosted, body: issue.description, bodyHTML: issue.description.map(markdownHTML),
            htmlURL: issue.webUrl, labels: issue.labels?.map(\.hosted), assignees: issue.assignees?.map(\.hosted),
            comments: issue.userNotesCount, createdAt: GitLabDate.parse(issue.createdAt),
            updatedAt: GitLabDate.parse(issue.updatedAt), closedAt: GitLabDate.parse(issue.closedAt),
            milestone: issue.milestone?.hosted, timeStats: issue.timeStats?.hosted)
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

    /// The merge request's diff threads, as discussion id and non-system notes, in GitLab's order, from the shared
    /// load (`threads(of:in:)`), which is returned too. Also remembers the discussion of each of their notes, for a
    /// reply without a `hostKey`.
    private func diffThreads(of number: Int, in repo: HostedRepository) async throws
        -> (threads: [(String, [GitLabNote])], load: GitLabThreads)
    {
        let load = try await threads(of: .pullRequest(number), in: repo)
        let threads = load.discussions.compactMap { discussion -> (String, [GitLabNote])? in
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
        return (threads, load)
    }

    /// The item's discussions and their GraphQL states, loaded once for the reads of one detail load: a load still
    /// running for the item is joined, else a new one starts, and it leaves `threadLoads` when it finishes (only
    /// itself, never a newer load that replaced it after a write), so a later detail load fetches again.
    private func threads(of item: HostedItem, in repo: HostedRepository) async throws -> GitLabThreads {
        let key = try itemKey(item, in: repo)
        let projectPath = try projectID(repo)
        let first = url(try itemPath(item, in: repo) + ["discussions"])
        let token = UUID()
        let task = memo.threadLoads.withLock { loads -> Task<GitLabThreads, any Error> in
            if let running = loads[key] { return running.task }
            let task = Task { [self] in
                defer { memo.threadLoads.withLock { if $0[key]?.token == token { $0[key] = nil } } }
                return try await loadThreads(of: item, key: key, projectPath: projectPath, first: first)
            }
            loads[key] = (token, task)
            return task
        }
        return try await task.value
    }

    /// The REST discussions, the GraphQL note states and the token's user's id, side by side. A failed GraphQL read
    /// or user leaves its part nil (rights fall back to the author, reactions are hidden); a failed REST read
    /// fails the load.
    private func loadThreads(of item: HostedItem, key: String, projectPath: String, first: URL) async throws
        -> GitLabThreads
    {
        async let discussions: [GitLabDiscussion] = list(first)
        async let states = try? noteStates(of: item, key: key, projectPath: projectPath)
        async let viewerID = try? myID()
        let loaded = try await discussions
        let read = await states
        return GitLabThreads(
            discussions: loaded, noteStates: read?.notes, discussionResolved: read?.resolved,
            discussionResolution: read?.resolution, itemAwards: read?.itemAwards, viewerID: await viewerID)
    }

    /// Discussions per GraphQL page: the query nests notes and awards (100 each) under each discussion, so the page
    /// stays small to keep under GitLab's complexity limit of 250 per query.
    static let noteStatePageSize = 20

    /// GraphQL `discussions` of the merge request or issue, one query per `noteStatePageSize` discussions (up to
    /// as many discussions as the REST list reads): each note's rights and awards, each discussion's `resolved`,
    /// joined to REST on the trailing segment of their global ids (`gid://gitlab/<Type>/<id>`), and the item's own
    /// global id and awards (read from the first page). The global ids are remembered for the mutations that take
    /// them, never built. Values go in `variables` only.
    private func noteStates(of item: HostedItem, key: String, projectPath: String) async throws
        -> (notes: [Int: GitLabNoteState], resolved: [String: Bool], resolution: [String: GitLabResolution],
            itemAwards: [(name: String, userID: Int?)])
    {
        struct Variables: Encodable { var projectPath, iid: String; var after: String? }
        struct Answer: Decodable { var project: Project? }
        struct Project: Decodable { var mergeRequest, issue: Item? }
        struct Item: Decodable {
            var id: String?
            var awardEmoji: Awards?
            var discussions: Page
        }
        struct Page: Decodable {
            var nodes: [Discussion]
            var pageInfo: PageInfo
        }
        struct PageInfo: Decodable {
            var hasNextPage: Bool
            var endCursor: String?
        }
        struct Discussion: Decodable {
            var id: String
            var resolved: Bool?
            var resolvedAt: String?
            var resolvedBy: Resolver?
            var notes: Notes
        }
        struct Resolver: Decodable {
            var id: String
            var username: String
            var name: String?
            var avatarUrl: String?
            var webUrl: String?
        }
        struct Notes: Decodable { var nodes: [Note] }
        struct Note: Decodable {
            var id: String
            var userPermissions: Permissions?
            var awardEmoji: Awards?
            var systemNoteIconName: String?
            var systemNoteMetadata: Metadata?
        }
        struct Metadata: Decodable { var action: String? }
        struct Permissions: Decodable { var adminNote, resolveNote: Bool? }
        struct Awards: Decodable { var nodes: [Award] }
        struct Award: Decodable {
            var name: String
            var user: User?
        }
        struct User: Decodable { var id: String }
        let field = Self.isMergeRequest(item) ? "mergeRequest" : "issue"
        let query = """
            query NoteStates($projectPath: ID!, $iid: String!, $after: String) {
              project(fullPath: $projectPath) {
                \(field)(iid: $iid) {
                  id
                  awardEmoji(first: 100) { nodes { name user { id } } }
                  discussions(first: \(Self.noteStatePageSize), after: $after) {
                    nodes {
                      id resolved resolvedAt
                      resolvedBy { id username name avatarUrl webUrl }
                      notes(first: 100) {
                        nodes {
                          id
                          userPermissions { adminNote resolveNote }
                          awardEmoji(first: 100) { nodes { name user { id } } }
                          systemNoteIconName
                          systemNoteMetadata { action }
                        }
                      }
                    }
                    pageInfo { hasNextPage endCursor }
                  }
                }
              }
            }
            """
        var notes: [Int: GitLabNoteState] = [:]
        var resolved: [String: Bool] = [:]
        var resolution: [String: GitLabResolution] = [:]
        var globalIDs: [String: String] = [:]
        var itemAwards: [(name: String, userID: Int?)]?
        var after: String?
        for _ in 0..<(maxPages * 100 / Self.noteStatePageSize) {
            let answer: Answer = try await graphQL(
                query, variables: Variables(projectPath: projectPath, iid: String(item.number), after: after))
            guard let read = answer.project?.mergeRequest ?? answer.project?.issue else {
                throw HostingError.invalidResponse("a GraphQL answer without the item's discussions")
            }
            let page = read.discussions
            if itemAwards == nil {
                if let id = read.id { globalIDs[key + "\u{0}item"] = id }
                itemAwards = (read.awardEmoji?.nodes ?? []).map { award in
                    (award.name, award.user.flatMap { Int(Self.lastSegment($0.id)) })
                }
            }
            for discussion in page.nodes {
                let discussionID = Self.lastSegment(discussion.id)
                globalIDs[key + "\u{0}discussion\u{0}" + discussionID] = discussion.id
                if let value = discussion.resolved { resolved[discussionID] = value }
                if discussion.resolvedBy != nil || discussion.resolvedAt != nil {
                    let user = discussion.resolvedBy.flatMap { by in
                        Int(Self.lastSegment(by.id)).map { id in
                            HostedUser(id: id, login: by.username, avatarURL: absoluteAvatarURL(by.avatarUrl),
                                       htmlURL: by.webUrl,
                                       name: by.name, reviewerID: String(id))
                        }
                    }
                    resolution[discussionID] = GitLabResolution(user: user, at: GitLabDate.parse(discussion.resolvedAt))
                }
                for note in discussion.notes.nodes {
                    guard let noteID = Int(Self.lastSegment(note.id)) else { continue }
                    globalIDs[key + "\u{0}note\u{0}\(noteID)"] = note.id
                    notes[noteID] = GitLabNoteState(
                        canAdmin: note.userPermissions?.adminNote ?? false,
                        canResolve: note.userPermissions?.resolveNote,
                        awards: (note.awardEmoji?.nodes ?? []).map { award in
                            (award.name, award.user.flatMap { Int(Self.lastSegment($0.id)) })
                        },
                        systemAction: note.systemNoteMetadata?.action, systemIcon: note.systemNoteIconName)
                }
            }
            guard page.pageInfo.hasNextPage, let cursor = page.pageInfo.endCursor else { break }
            after = cursor
        }
        memo.globalIDs.withLock { $0.merge(globalIDs) { _, new in new } }
        return (notes, resolved, resolution, itemAwards ?? [])
    }

    /// GraphQL's `avatarUrl` is a path on the host for an uploaded avatar (`/uploads/-/system/user/avatar/...`,
    /// the relative URL root included) and absolute for Gravatar: the path becomes `https://<host><path>`, as REST's
    /// `avatar_url` gives it.
    private func absoluteAvatarURL(_ url: String?) -> String? {
        guard let url, url.hasPrefix("/"), !url.hasPrefix("//") else { return url }
        return "https://\(host)" + url
    }

    /// The text after a global id's last `/` (`gid://gitlab/DiffNote/12` is `12`).
    private static func lastSegment(_ globalID: String) -> String {
        globalID.split(separator: "/").last.map(String.init) ?? globalID
    }

    /// A note's rights and reactions in a load: with the GraphQL states, `adminNote` (edit and delete) and the
    /// awards counted per name, GitLab's default kinds first in `reactionKinds` order, then the others as first
    /// seen, each marked when one is the token's user's. Without them (the read failed, or a note past the query's
    /// 100 per discussion), the token's user may edit and delete their own notes, and there are no reactions.
    private func viewerState(of note: GitLabNote, in load: GitLabThreads)
        -> (canAdmin: Bool, reactions: [HostedReaction])
    {
        guard let state = load.noteStates?[note.id] else {
            return (load.viewerID != nil && note.author?.id == load.viewerID, [])
        }
        return (state.canAdmin, reactions(state.awards, viewerID: load.viewerID))
    }

    /// Awards counted per name, GitLab's default kinds first in `reactionKinds` order, then the others as first seen,
    /// each marked when one is `viewerID`'s.
    private func reactions(_ awards: [(name: String, userID: Int?)], viewerID: Int?) -> [HostedReaction] {
        var names: [String] = []
        var byName: [String: HostedReaction] = [:]
        for award in awards {
            if byName[award.name] == nil {
                names.append(award.name)
                byName[award.name] = HostedReaction(kind: award.name, count: 0)
            }
            byName[award.name]?.count += 1
            if award.userID != nil, award.userID == viewerID { byName[award.name]?.viewerReacted = true }
        }
        let kinds = reactionKinds
        let ordered = kinds.filter { byName[$0] != nil } + names.filter { !kinds.contains($0) }
        return ordered.compactMap { byName[$0] }
    }

    /// The memo key of an item: the project's path, the item's kind and its iid.
    private func itemKey(_ item: HostedItem, in repo: HostedRepository) throws -> String {
        let kind = Self.isMergeRequest(item) ? "merge_requests" : "issues"
        return try projectID(repo) + "\u{0}" + kind + "\u{0}\(item.number)"
    }

    private static func isMergeRequest(_ item: HostedItem) -> Bool {
        if case .pullRequest = item { true } else { false }
    }

    /// Drops the item's running discussions load after a write on it, so the next read fetches again.
    private func forgetThreads(of item: HostedItem, in repo: HostedRepository) {
        guard let key = try? itemKey(item, in: repo) else { return }
        forgetThreads(key: key)
    }

    private func forgetThreads(key: String) {
        _ = memo.threadLoads.withLock { $0.removeValue(forKey: key) }
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

    /// A note's or description's markdown as HTML, its `@username` mentions linked to their pages on this GitLab, as
    /// GitLab's page links them.
    private func markdownHTML(_ text: String) -> String {
        MarkdownHTML.html(text, mentionsAt: webRoot)
    }

    /// A system note's markdown as HTML (`markdownHTML`), its root-relative links (GitLab's "Compare with previous
    /// version", which carries the relative URL root) joined to the host. Only system notes: a comment's attachment
    /// link (`/uploads/<secret>/file`) is project-relative on GitLab's page, so it stays text there.
    private func systemNoteHTML(_ text: String) -> String {
        MarkdownHTML.html(text, mentionsAt: webRoot, origin: "https://\(host)")
    }

    /// `https://<host>[/<basePath>]`: the root of GitLab's pages.
    private var webRoot: String { "https://\(host)" + basePath.map { "/" + $0 }.joined() }

    /// A system note's body with the commit list GitLab writes in HTML ("added 2 commits" then
    /// `<ul><li><sha>[...<sha>] - <title></li>…</ul>`, the titles HTML-escaped, `<code>` around a branch name) as a
    /// Markdown list: each full sha a link to its commit (`commitURL`) showing its first 8 characters, as GitLab's page
    /// shows it, `<code>` a code span, the rest plain text (entities decoded, Markdown punctuation escaped). Any other
    /// HTML stays as it was, for `MarkdownHTML` to show as text; a body without such a list is returned unchanged.
    static func systemNoteMarkdown(_ body: String, commitURL: (String) -> URL?) -> String {
        guard let open = body.range(of: "<ul>"), let close = body.range(of: "</ul>", range: open.upperBound..<body.endIndex)
        else { return body }
        let list = body[open.upperBound..<close.lowerBound]
        let items = list.components(separatedBy: "<li>").dropFirst().map { item in
            "- " + itemMarkdown(item.components(separatedBy: "</li>")[0], commitURL: commitURL)
        }
        guard !items.isEmpty else { return body }
        let rest = systemNoteMarkdown(String(body[close.upperBound...]), commitURL: commitURL)
        return String(body[..<open.lowerBound]) + "\n\n" + items.joined(separator: "\n") + "\n\n" + rest
    }

    /// One list item: `<code>…</code>` as code spans, full shas as links, the rest plain.
    private static func itemMarkdown(_ html: String, commitURL: (String) -> URL?) -> String {
        var result = ""
        var rest = Substring(html)
        while let start = rest.range(of: "<code>") {
            result += plainMarkdown(rest[..<start.lowerBound], commitURL: commitURL)
            let after = rest[start.upperBound...]
            guard let end = after.range(of: "</code>") else {
                rest = rest[start.lowerBound...]
                break
            }
            result += codeSpan(decodeEntities(String(after[..<end.lowerBound])))
            rest = after[end.upperBound...]
        }
        return result + plainMarkdown(rest, commitURL: commitURL)
    }

    /// Text with its entities decoded and every ASCII punctuation mark escaped, each 40-hex word a commit link.
    private static func plainMarkdown(_ html: Substring, commitURL: (String) -> URL?) -> String {
        let text = decodeEntities(String(html))
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let previous = index > text.startIndex ? text[text.index(before: index)] : " "
            if character.isHexDigit, !(previous.isLetter || previous.isNumber),
               let end = text.index(index, offsetBy: 40, limitedBy: text.endIndex),
               text[index..<end].allSatisfy({ $0.isASCII && $0.isHexDigit }),
               end == text.endIndex || !(text[end].isLetter || text[end].isNumber),
               let url = commitURL(String(text[index..<end]).lowercased())
            {
                result += "[`\(text[index..<text.index(index, offsetBy: 8)])`](\(url.absoluteString))"
                index = end
                continue
            }
            if character.isASCII, character.isPunctuation || character.isSymbol {
                result += "\\"
            }
            result.append(character)
            index = text.index(after: index)
        }
        return result
    }

    /// `text` as one code span, fenced with one more backtick than its longest run.
    private static func codeSpan(_ text: String) -> String {
        var longest = 0, run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: longest + 1)
        return fence + " " + text + " " + fence
    }

    /// The five entities GitLab's `escape_html` writes, decoded (`&amp;` last).
    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func noteURL(_ page: URL?, _ id: Int) -> String? {
        page.map { $0.absoluteString + "#note_\(id)" }
    }

    /// A plain note as a comment, with HTML from `MarkdownHTML` (REST notes have none).
    private func comment(_ note: GitLabNote, page: URL?) -> HostedComment {
        HostedComment(
            id: note.id, user: note.author?.hosted, body: note.body, bodyHTML: note.body.map(markdownHTML),
            htmlURL: Self.noteURL(page, note.id), createdAt: GitLabDate.parse(note.createdAt))
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

    /// Whether `url` is `graphQLURL` itself: the same origin and exactly its path, no query, so `/api/graphqlx`,
    /// `/api/graphql/x` or anything else under `/api` is not.
    private func isGraphQLURL(_ url: URL) -> Bool {
        HostingHTTP.isSameOrigin(url, graphQLURL)
            && url.path(percentEncoded: true) == graphQLURL.path(percentEncoded: true) && url.query() == nil
    }

    /// POSTs a GraphQL operation to `graphQLURL` through `perform`, so it carries the token, headers, 401 refresh and
    /// redirect guard of every REST call. Values only go in `variables`, never into the `query` text. GitLab answers
    /// a failed operation with 200, an `errors` array and a partial or null `data`: the errors are read first, and the
    /// first one is thrown as `HostingError.graphQL`.
    private func graphQL<Value: Decodable, Variables: Encodable>(_ query: String, variables: Variables)
        async throws -> Value
    {
        let body = try JSONEncoder().encode(GraphQLRequest(query: query, variables: variables))
        let (data, _) = try await perform("POST", graphQLURL, body: body)
        let failure: GraphQLErrors = try Self.decode(data)
        if let first = failure.errors?.first { throw HostingError.graphQL(message: String(first.message.prefix(500))) }
        let answer: GraphQLAnswer<Value> = try Self.decode(data)
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

    /// The one place a request is made and the token attached, only to a URL under `apiBase` or to `graphQLURL`. A
    /// 401 asks the provider for a refreshed token and retries once; a second 401 is `unauthorized`.
    private func perform(_ method: String, _ url: URL, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        guard isUnderAPIBase(url) || isGraphQLURL(url) else {
            throw HostingError.invalidResponse("a URL outside the API")
        }
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
