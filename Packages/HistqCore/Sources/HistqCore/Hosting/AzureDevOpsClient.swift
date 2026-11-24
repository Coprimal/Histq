// Azure DevOps Services (`dev.azure.com`). A repository is `<organization>/<project>/<repo>`: a `HostedRepository`'s
// `path` is exactly those three segments (owner `org/project`), names decoded (projects and repos may hold spaces),
// and its host is always `dev.azure.com`, the host its accounts are on, whichever host the remote reaches (the
// legacy `org.visualstudio.com` and the ssh hosts): git keeps using the remote URL itself.
//
// The `URLSession` is injected, so tests serve inline JSON through a stub `URLProtocol` and never reach the network.
// The token (a Microsoft Entra access token, opaque: never decoded or logged) is a secret: the client asks its provider
// for it on every request, and after a 401 asks once more with the refused token (so an expired one is refreshed) and
// retries that request once. It only ever goes in the `Authorization: Bearer` header of an https request to
// `https://dev.azure.com/<org>/…` or `https://app.vssps.visualstudio.com/_apis/…`: a redirect to another origin, or
// out of the request's organization (`/_apis` on the profile host), is not followed, every next page is built by the
// client (never taken from an answer), no error or description holds the token, and `print`, `dump` and
// `String(reflecting:)` of a client show only its host. Every request carries `api-version=7.1` (7.1-preview.1 for the
// policy evaluations, the one preview API, read best-effort). Writes go through the same guard; a merge reads the
// pull request again first and sends nothing when its head moved.
import Foundation
import Synchronization

public struct AzureDevOpsClient: HostingProvider, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    /// Hands out the access token: `rejected` is the token a 401 just refused, so an expired one is renewed unless it
    /// already was; nil otherwise.
    public typealias TokenProvider = @Sendable (_ rejected: String?) async throws -> String

    /// The host of every Azure DevOps Services account and of its API.
    public static let host = "dev.azure.com"
    /// `https://dev.azure.com`: every organization's API (`/<org>[/<project>]/_apis/…`).
    public static let apiOrigin = URL(string: "https://dev.azure.com")!
    /// `https://app.vssps.visualstudio.com`: the token's user's profile and organizations (`/_apis/…` only).
    public static let profileOrigin = URL(string: "https://app.vssps.visualstudio.com")!
    /// The REST version every request asks for.
    static let apiVersion = "7.1"

    /// The most pages one list follows (100 items each, 2000 for a pull request's files), so a huge repository
    /// cannot keep a list loading.
    public var maxPages = 10
    /// The most organizations the clone list reads.
    public var maxOrganizations = 20
    /// How many times a merge Azure has not completed yet is read again, `mergePollDelay` apart.
    public var mergePolls = 30
    public var mergePollDelay: Duration = .seconds(2)
    private let token: TokenProvider
    private let session: URLSession
    private let memo = Memo()

    public init(session: URLSession = HostingHTTP.session, token: @escaping TokenProvider) {
        self.token = token
        self.session = session
    }

    public var description: String { "AzureDevOpsClient(\(Self.host))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["host": Self.host]) }

    /// What the client remembers between calls: the token's user's profile id (the PR lists, the vote and the
    /// comments' edit rights take it), and for each pull request it read, by repository and head commit, its number
    /// and project id (`checkRuns(for:in:)` gets a commit only, but a pull request's statuses and policies are read by
    /// number). Shared by copies.
    private final class Memo: Sendable {
        let profileID = Mutex<String?>(nil)
        let pullRequestByHead = Mutex<[String: (number: Int, projectID: String?)]>([:])
    }

    // MARK: - Remote URLs

    /// The repository of an Azure DevOps remote URL: `https://[org@]dev.azure.com/org/project/_git/repo`,
    /// `https://org.visualstudio.com[/DefaultCollection]/project/_git/repo`,
    /// `git@ssh.dev.azure.com:v3/org/project/repo` (also `ssh://`) and
    /// `org@vs-ssh.visualstudio.com:v3/org/project/repo`, a trailing `.git` dropped. Each form only on its own scheme
    /// and host; a user name only, never a password. The organization is ASCII letters, digits and `-` (from the host
    /// it is lowercase); the project and repository pass `isSafeName(_:)`. nil otherwise.
    public static func repository(fromRemoteURL url: String) -> HostedRepository? {
        guard let remote = RemoteURL(url), !remote.hasPassword else { return nil }
        let https = url.lowercased().hasPrefix("https://")
        var path = remote.segments
        let org: String
        switch remote.host {
        case Self.host where https:
            guard path.count == 4, path[2].lowercased() == "_git" else { return nil }
            org = path[0]
            path = [path[1], path[3]]
        case "ssh.dev.azure.com", "vs-ssh.visualstudio.com":
            guard !https, path.count == 4, path[0].lowercased() == "v3" else { return nil }
            org = path[1]
            path = [path[2], path[3]]
        default:
            let labels = remote.host.split(separator: ".", omittingEmptySubsequences: false)
            guard https, labels.count == 3, labels[1] == "visualstudio", labels[2] == "com", labels[0] != "vs-ssh"
            else { return nil }
            if path.count == 4, path[0].lowercased() == "defaultcollection" { path.removeFirst() }
            // `DefaultCollection/_git/repo` (a project named as its repo, in the short form) is not read as a project.
            guard path.count == 3, path[0].lowercased() != "defaultcollection", path[1].lowercased() == "_git"
            else { return nil }
            org = String(labels[0])
            path = [path[0], path[2]]
        }
        guard isSafeOrganization(org), path.allSatisfy(isSafeName) else { return nil }
        return HostedRepository(host: host, path: [org] + path)
    }

    private static func isSafeOrganization(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-")
        }
    }

    /// A project or repository name by a conservative reading of Azure DevOps' naming rules (not checked against its
    /// docs): no control character, none of the reserved characters below (which also keeps a query, a fragment or a
    /// second encoding out), not starting with `_` or `.`, not ending with `.`.
    private static func isSafeName(_ text: String) -> Bool {
        !text.isEmpty && !text.hasPrefix("_") && !text.hasPrefix(".") && !text.hasSuffix(".")
            && text.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0) && !reservedCharacters.contains($0)
            }
    }

    private static let reservedCharacters = CharacterSet(charactersIn: "/:\\~&%;@'\"?<>|#$*{},+=[]")

    // MARK: - Ids

    /// A user's id: a hash of their GUID (or of their name when Azure sends none), the same on every call.
    static func userID(_ key: String) -> Int {
        stableID("user", key)
    }

    /// The same synthetic id for the same key on every call (no probing), for values without a numeric id.
    static func stableID(_ kind: String, _ key: String) -> Int {
        var ids = SyntheticIDs()
        return ids.id(kind, key)
    }

    /// A comment's id: `threadID << 20 | commentID` (a comment id is unique only within its thread). nil when either
    /// is not positive, the comment id needs more than 20 bits, or the shift would overflow.
    static func commentID(thread: Int, comment: Int) -> Int? {
        guard thread > 0, comment > 0, comment < 1 << 20, thread <= Int.max >> 20 else { return nil }
        return thread << 20 | comment
    }

    /// The thread and comment ids of a combined id (`commentID(thread:comment:)`); nil when it does not split back
    /// into the same id.
    static func split(_ id: Int) -> (thread: Int, comment: Int)? {
        let parts = (thread: id >> 20, comment: id & ((1 << 20) - 1))
        return commentID(thread: parts.thread, comment: parts.comment) == id ? parts : nil
    }

    /// An inline thread's state id: `<org>/<project>/<repo>#<number>/<thread>`, each name percent-encoded down to
    /// ASCII letters, digits, `-`, `.`, `_` and `~` (so a `/` or `#` in a name never splits it), as
    /// `setReviewThread(_:resolved:)` gets the state only, and a thread id is unique only within its pull request.
    static func threadKey(_ repo: HostedRepository, number: Int, thread: Int) -> String {
        let names = repo.path.map { $0.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? "" }
        return names.joined(separator: "/") + "#\(number)/\(thread)"
    }

    /// The repository, pull request and thread of a `threadKey(_:number:thread:)`; nil when it is not one (three
    /// non-empty names, a positive number and thread id).
    static func threadTarget(_ key: String) -> (repo: HostedRepository, number: Int, thread: Int)? {
        let halves = key.split(separator: "#", omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }
        let rawNames = halves[0].split(separator: "/", omittingEmptySubsequences: false)
        let rawIDs = halves[1].split(separator: "/", omittingEmptySubsequences: false)
        guard rawNames.count == 3, rawIDs.count == 2 else { return nil }
        let names = rawNames.compactMap { $0.removingPercentEncoding }
        let ids = rawIDs.compactMap { Int($0) }
        guard names.count == 3, !names.contains(where: \.isEmpty), ids.count == 2, ids.allSatisfy({ $0 > 0 }) else {
            return nil
        }
        return (HostedRepository(host: host, path: names), ids[0], ids[1])
    }

    // MARK: - HostingProvider

    public var kind: HostingKind { .azureDevOps }

    /// Labels, request changes (a vote of -5), resolvable threads, drafts, reopening (reactivating an abandoned pull
    /// request), reviewers, taking a vote back (a vote of 0), and the comment interactions: replies and resolving on
    /// general threads, editing and deleting one's own comments, likes (the one reaction) and new inline comments, on
    /// a range of lines too; the history entries (system threads) and the merge checks (policies and conflicts). No
    /// assignees, no issues (Azure Boards work items are not issues), and no reactions on the pull request itself
    /// (Azure has none).
    public var capabilities: HostingCapabilities {
        [
            .labels, .requestChanges, .resolveThreads, .draft, .reopen, .reviewRequests, .unapprove, .generalReplies,
            .resolveGeneralThreads, .editComments, .deleteComments, .reactions, .newInlineComments,
            .multiLineInlineComments, .timelineEvents, .mergeChecks,
        ]
    }

    /// A like, Azure's one reaction on a comment, under the thumbs-up's name.
    public var reactionKinds: [String] { [Self.like] }

    static let like = "+1"

    /// No fast-forward merge, squash and rebase, where no merge strategy policy applies (a pull request's own
    /// `allowedMergeMethods` lists them otherwise).
    public var mergeMethods: Set<HostedMergeMethod> { [.merge, .squash, .rebase] }

    /// The source branch, `refs/heads/<branch>` of the repository's own remote, for a pull request from the same
    /// repository (its head has an `owner:branch` label): the client cannot know the local remote's name, and Azure
    /// documents no pull request ref to fetch a fork's head from.
    public func checkout(of pullRequest: HostedPullRequest) -> HostedCheckout {
        guard pullRequest.head.label != nil, !pullRequest.head.ref.isEmpty else {
            return .unavailable(reason: "Pull requests from forks can't be checked out here")
        }
        return .ref("heads/\(pullRequest.head.ref)")
    }

    /// `https://dev.azure.com/<org>/<project>/_git/<repo>`, then `?version=GB<branch>`, `/commit/<sha>` or
    /// `/pullrequest/<n>`, each segment (and the branch) percent-encoded. Nil for an issue, a repository on another
    /// host or not org/project/repo, an empty, `.` or `..` segment, or a sha that is not hex.
    public func webURL(_ target: HostedWebTarget, in repo: HostedRepository) -> URL? {
        guard repo.host.lowercased() == Self.host, repo.path.count == 3 else { return nil }
        var segments = [repo.path[0], repo.path[1], "_git", repo.path[2]]
        var query = ""
        switch target {
        case .repository: break
        case .branch(let name):
            guard !name.isEmpty,
                let value = name.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed)
            else { return nil }
            query = "?version=GB" + value
        case .commit(let sha):
            guard !sha.isEmpty, sha.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
            segments += ["commit", sha]
        case .pullRequest(let number): segments += ["pullrequest", String(number)]
        case .issue: return nil
        }
        guard !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        let encoded = segments.compactMap { $0.addingPercentEncoding(withAllowedCharacters: Self.segmentAllowed) }
        guard encoded.count == segments.count else { return nil }
        return URL(string: "https://\(Self.host)/" + encoded.joined(separator: "/") + query)
    }

    /// `GET https://app.vssps.visualstudio.com/_apis/profile/profiles/me`: `login` is the email address (else the
    /// display name), `reviewerID` the profile's GUID, which is remembered (the PR lists take it).
    public func currentUser() async throws -> HostedUser {
        let profile: AzureDevOpsProfile = try await get(
            url(["_apis", "profile", "profiles", "me"], on: Self.profileOrigin))
        guard let id = profile.id, !id.isEmpty else {
            throw HostingError.invalidResponse("could not read the signed-in user")
        }
        memo.profileID.withLock { $0 = id }
        let login = [profile.emailAddress, profile.displayName, profile.publicAlias]
            .compactMap { $0 }.first { !$0.isEmpty } ?? id
        return HostedUser(id: Self.userID(id.lowercased()), login: login, name: profile.displayName, reviewerID: id)
    }

    /// The names of the organizations the token's user is a member of
    /// (`GET https://app.vssps.visualstudio.com/_apis/accounts?memberId=<id>`, at most `maxOrganizations`), in Azure's
    /// order, without duplicates or names that are not plain.
    public func organizations() async throws -> [String] {
        let me = try await myID()
        let accounts: AzureDevOpsList<AzureDevOpsAccount> = try await get(
            url(["_apis", "accounts"], query: [("memberId", me)], on: Self.profileOrigin))
        var organizations: [String] = []
        for name in (accounts.value ?? []).compactMap(\.accountName) where Self.isSafeOrganization(name)
            && !organizations.contains(where: { $0.lowercased() == name.lowercased() })
        {
            organizations.append(name)
        }
        return Array(organizations.prefix(maxOrganizations))
    }

    /// The repositories of every organization of `organizations()`, each organization's
    /// `GET /<org>/_apis/git/repositories` (one answer, no pages), sorted by full name, with the https `remoteUrl` as
    /// the clone URL. Disabled repositories, and those without an https remote URL naming them in their organization,
    /// are left out. An organization that cannot be read is skipped; the list fails only when every one
    /// fails, or on a 401.
    public func userRepositories() async throws -> [HostedCloneRepository] {
        let organizations = try await organizations()
        var result: [HostedCloneRepository] = []
        var lastError: (any Error)?
        var failures = 0
        for organization in organizations {
            do {
                let repos: AzureDevOpsList<AzureDevOpsRepository> = try await get(
                    url([organization, "_apis", "git", "repositories"]))
                result += (repos.value ?? []).compactMap { Self.cloneRepository($0, in: organization) }
            } catch HostingError.unauthorized {
                throw HostingError.unauthorized
            } catch {
                failures += 1
                lastError = error
            }
        }
        if let lastError, failures == organizations.count { throw lastError }
        return result.sorted { $0.fullName.lowercased() < $1.fullName.lowercased() }
    }

    /// `GET {R}/pullrequests?searchCriteria.status=…`: `active`, else `all` (with `.closed` keeping the completed and
    /// abandoned ones).
    public func pullRequests(in repo: HostedRepository, state: HostedListState) async throws -> [HostedPullRequest] {
        let prs: [AzureDevOpsPullRequest] = try await pagedList(
            try repoPath(repo) + ["pullrequests"],
            query: [("searchCriteria.status", state == .open ? "active" : "all")])
        return prs.filter { state != .closed || $0.status != "active" }.map { pullRequest($0, in: repo) }
    }

    /// `GET {R}/pullrequests/<n>`, then the merge strategy policies on its target branch as its
    /// `allowedMergeMethods` (nil when none applies or they cannot be read; Azure has no default strategy).
    public func pullRequest(_ number: Int, in repo: HostedRepository) async throws -> HostedPullRequest {
        let pr: AzureDevOpsPullRequest = try await get(url(try pullRequestPath(number, in: repo)))
        var pull = pullRequest(pr, in: repo)
        pull.allowedMergeMethods = Self.mergeMethods(await allowedStrategies(for: pr, in: repo))
        return pull
    }

    public func issues(in repo: HostedRepository, state: HostedListState) async throws -> [HostedIssue] {
        throw Self.noIssues
    }

    public func issue(_ number: Int, in repo: HostedRepository) async throws -> HostedIssue {
        throw Self.noIssues
    }

    /// The active pull requests the token's user created (`searchCriteria.creatorId`).
    public func myOpenPullRequests(in repo: HostedRepository) async throws -> [HostedIssue] {
        try await activePullRequests(in: repo, criterion: "searchCriteria.creatorId")
    }

    /// The active pull requests with the token's user as a reviewer (`searchCriteria.reviewerId`).
    public func reviewRequestedPullRequests(in repo: HostedRepository) async throws -> [HostedIssue] {
        try await activePullRequests(in: repo, criterion: "searchCriteria.reviewerId")
    }

    public func assignedOpenIssues(in repo: HostedRepository) async throws -> [HostedIssue] {
        throw Self.noIssues
    }

    /// The comments of the threads on the pull request itself (no `threadContext`), thread by thread (oldest first),
    /// each root then its replies with their direct `parentID`. A root is resolvable where its thread has a status
    /// (resolved for every status but `active`, `pending` and `unknown`); `hostKey` is the thread id. The token's
    /// user may edit and delete their own comments (Azure sends no rights: the author's GUID is the profile's, read
    /// best-effort), and the likes are each comment's one reaction.
    public func comments(on item: HostedItem, in repo: HostedRepository) async throws -> [HostedComment] {
        guard case .pullRequest(let number) = item else { throw Self.noIssues }
        let threads = try await threads(of: number, in: repo).filter { !$0.isInline }
        let viewer = try? await myID()
        return threads.flatMap { Self.comments($0, viewer: viewer) }
    }

    /// One review per reviewer, sorted by GUID: 10 (approved) and 5 (approved with suggestions) are `APPROVED`, -5
    /// (waiting for the author) and -10 (rejected) `CHANGES_REQUESTED`; a reviewer at 0 who has not declined has not
    /// reviewed: `PENDING` (the pull request also lists them in `requestedReviewers`), a declined one is left out. Each
    /// keeps its raw `vote` and `isRequired`. Ids are synthetic, keyed by the GUID. Azure gives no date.
    public func reviews(of number: Int, in repo: HostedRepository) async throws -> [HostedReview] {
        let pr: AzureDevOpsPullRequest = try await get(url(try pullRequestPath(number, in: repo)))
        return Self.reviews(pr)
    }

    /// The comments of every thread on a file (a `threadContext` with a path), roots and replies, each reply pointing
    /// at its thread's root. A thread with `rightFileStart` is on the new side (`RIGHT`), else on the old (`LEFT`);
    /// its line is the end line, and a multi-line one starts at the start line. No diff hunk: Azure serves no patch.
    /// Edit rights and likes as in `comments(on:in:)`.
    public func reviewComments(of number: Int, in repo: HostedRepository) async throws -> [HostedReviewComment] {
        let threads = try await inlineThreads(of: number, in: repo)
        let viewer = try? await myID()
        return threads.flatMap { Self.reviewComments($0, viewer: viewer) }
    }

    /// A state for each thread on a file: its id the `threadKey(_:number:thread:)` (repository, pull request and
    /// thread), joined to its root comment, resolved as in `comments(on:in:)`, with Azure's own `status`. Azure does
    /// not say whether a thread is
    /// outdated, nor whether the token's user may resolve it (both flags true; Azure refuses the others).
    public func reviewThreadStates(of number: Int, in repo: HostedRepository) async throws
        -> [HostedReviewThreadState]
    {
        try await inlineThreads(of: number, in: repo).map { thread in
            HostedReviewThreadState(
                id: Self.threadKey(repo, number: number, thread: thread.id), isResolved: Self.isResolved(thread.status),
                isOutdated: false, viewerCanResolve: true, viewerCanUnresolve: true,
                rootCommentID: thread.comments[0].id, status: thread.status)
        }
    }

    /// `GET {PR}/commits` (`$top`, then the `x-ms-continuationtoken` answer header as `continuationToken`), oldest
    /// first: Azure lists them newest first.
    public func pullRequestCommits(_ number: Int, in repo: HostedRepository) async throws -> [HostedCommit] {
        let path = try pullRequestPath(number, in: repo) + ["commits"]
        var commits: [AzureDevOpsCommit] = []
        var continuation: String?
        for _ in 0..<maxPages {
            let (data, response) = try await perform(
                "GET", url(path, query: [("$top", "100")] + (continuation.map { [("continuationToken", $0)] } ?? [])))
            let page: AzureDevOpsList<AzureDevOpsCommit> = try Self.decode(data)
            commits += page.value ?? []
            guard let next = response.value(forHTTPHeaderField: "x-ms-continuationtoken"), !next.isEmpty,
                next != continuation
            else { break }
            continuation = next
        }
        return commits.reversed().compactMap { commit in
            guard let sha = commit.commitId, !sha.isEmpty else { return nil }
            return HostedCommit(
                sha: sha, htmlURL: webURL(.commit(sha), in: repo)?.absoluteString,
                commit: .init(
                    message: commit.comment ?? "",
                    author: .init(
                        name: commit.author?.name, email: commit.author?.email,
                        date: GitLabDate.parse(commit.author?.date))),
                author: nil)
        }
    }

    /// The files of the last iteration's changes (`GET {PR}/iterations`, then `GET {PR}/iterations/<n>/changes`,
    /// 2000 at a time, the next page at `nextSkip`), without patches (Azure serves none: they are made locally) and
    /// without line counts.
    public func pullRequestFiles(_ number: Int, in repo: HostedRepository) async throws -> [HostedPullRequestFile] {
        Self.files(try await lastIterationChanges(of: number, in: repo)?.entries ?? [])
    }

    /// The last iteration's id and its change entries (`GET {PR}/iterations`, then `GET {PR}/iterations/<n>/changes`,
    /// 2000 at a time, the next page at `nextSkip`, at most `maxPages` pages); nil without an iteration.
    private func lastIterationChanges(of number: Int, in repo: HostedRepository) async throws
        -> (iteration: Int, entries: [AzureDevOpsIterationChanges.Entry])?
    {
        let path = try pullRequestPath(number, in: repo) + ["iterations"]
        let iterations: AzureDevOpsList<AzureDevOpsIteration> = try await get(url(path))
        guard let last = (iterations.value ?? []).compactMap(\.id).max() else { return nil }
        var entries: [AzureDevOpsIterationChanges.Entry] = []
        var skip = 0
        for _ in 0..<maxPages {
            var query = [("$top", "2000")]
            if skip > 0 { query.append(("$skip", String(skip))) }
            let page: AzureDevOpsIterationChanges = try await get(url(path + [String(last), "changes"], query: query))
            entries += page.changeEntries ?? []
            guard let next = page.nextSkip, next > skip else { break }
            skip = next
        }
        return (last, entries)
    }

    /// `pullRequestFiles(_:in:)`' files from the change entries: folders left out, each path once (the first entry),
    /// without its leading `/` (`entryPath(_:)`). A change type with `rename` is `renamed` (with the old path), else
    /// `add` is `added`, `delete` `removed`, anything else `modified`.
    static func files(_ entries: [AzureDevOpsIterationChanges.Entry]) -> [HostedPullRequestFile] {
        var seen: Set<String> = []
        return entries.compactMap { entry in
            guard entry.item?.isFolder != true, let path = entryPath(entry), seen.insert(path).inserted
            else { return nil }
            let types = (entry.changeType ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let status = types.contains("rename") ? "renamed"
                : types.contains("add") ? "added" : types.contains("delete") ? "removed" : "modified"
            return HostedPullRequestFile(
                filename: path, status: status, additions: 0, deletions: 0, patch: nil,
                previousFilename: status == "renamed" ? filePath(entry.originalPath) : nil)
        }
    }

    /// A change entry's file path without its leading `/`: the item's path, else the original path (the docs show no
    /// deleted file's entry).
    static func entryPath(_ entry: AzureDevOpsIterationChanges.Entry) -> String? {
        filePath(entry.item?.path) ?? filePath(entry.originalPath)
    }

    /// A repository path without its leading `/`; nil when empty.
    static func filePath(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The latest status of each context on commit `ref` (`GET {R}/commits/<sha>/statuses?latestOnly=true`), then, for
    /// a pull request this client read with `ref` as its head, the latest of each context on the pull request
    /// (`GET {PR}/statuses`) and its policies' evaluations (best-effort: a failure leaves them out). A `ref` that is not
    /// a full hex commit id (a branch name) has none.
    public func checkRuns(for ref: String, in repo: HostedRepository) async throws -> [HostedCheckRun] {
        let path = try repoPath(repo)
        guard ref.count == 40 || ref.count == 64, ref.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return [] }
        let commit: AzureDevOpsList<AzureDevOpsStatus> = try await get(
            url(path + ["commits", ref, "statuses"], query: [("latestOnly", "true")]))
        var ids = SyntheticIDs()
        var runs = Self.checkRuns(commit.value ?? [], source: "commit", ids: &ids)
        let key = Self.headKey(repo, ref)
        guard let pull = memo.pullRequestByHead.withLock({ $0[key] }) else { return runs }
        let statuses: AzureDevOpsList<AzureDevOpsStatus> = try await get(
            url(try pullRequestPath(pull.number, in: repo) + ["statuses"]))
        runs += Self.checkRuns(Self.latest(statuses.value ?? []), source: "pr", ids: &ids)
        let evaluations = await policyEvaluations(of: pull.number, projectID: pull.projectID, in: repo)
        runs += Self.checkRuns(evaluations, ids: &ids)
        return runs
    }

    /// The latest status (highest id) of each context, in the order the first of each came.
    static func latest(_ statuses: [AzureDevOpsStatus]) -> [AzureDevOpsStatus] {
        var order: [String] = []
        var latest: [String: AzureDevOpsStatus] = [:]
        for status in statuses {
            let key = (status.context?.genre ?? "") + "\n" + (status.context?.name ?? "")
            if let kept = latest[key] {
                if (status.id ?? 0) > (kept.id ?? 0) { latest[key] = status }
            } else {
                order.append(key)
                latest[key] = status
            }
        }
        return order.compactMap { latest[$0] }
    }

    /// Statuses as check runs, named `genre/name` (the name alone without a genre): `pending` is `in_progress`,
    /// `notSet` `queued`, `succeeded` a `success`, `failed` and `error` a `failure`, `notApplicable` `skipped`. The
    /// link only when it is https. Ids are synthetic, keyed by `source` and the status id (else its name).
    static func checkRuns(_ statuses: [AzureDevOpsStatus], source: String, ids: inout SyntheticIDs)
        -> [HostedCheckRun]
    {
        statuses.map { status in
            let name = [status.context?.genre, status.context?.name].compactMap { $0 }.filter { !$0.isEmpty }
                .joined(separator: "/")
            let (state, conclusion): (String, String?) = switch status.state {
            case "pending": ("in_progress", nil)
            case "succeeded": ("completed", "success")
            case "failed", "error": ("completed", "failure")
            case "notApplicable": ("completed", "skipped")
            default: ("queued", nil)
            }
            let shown = name.isEmpty ? status.description ?? "Status" : name
            return HostedCheckRun(
                id: ids.id("status-" + source, status.id.map(String.init) ?? shown), name: shown, status: state,
                conclusion: conclusion, htmlURL: httpsLink(status.targetUrl),
                startedAt: GitLabDate.parse(status.creationDate),
                completedAt: state == "completed" ? GitLabDate.parse(status.updatedDate) : nil)
        }
    }

    /// Policy evaluations as check runs, named by the policy type (" (optional)" after a policy that does not block):
    /// `queued` is `queued`, `running` `in_progress`, `approved` a `success`, `rejected` and `broken` a `failure`,
    /// `notApplicable` `skipped`. A disabled policy is left out.
    static func checkRuns(_ evaluations: [AzureDevOpsPolicyEvaluation], ids: inout SyntheticIDs) -> [HostedCheckRun] {
        evaluations.compactMap { evaluation in
            guard evaluation.configuration?.isEnabled != false else { return nil }
            let type = evaluation.configuration?.type?.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? "Policy"
            let name = evaluation.configuration?.isBlocking == false ? type + " (optional)" : type
            let (state, conclusion): (String, String?) = switch evaluation.status {
            case "running": ("in_progress", nil)
            case "approved": ("completed", "success")
            case "rejected", "broken": ("completed", "failure")
            case "notApplicable": ("completed", "skipped")
            default: ("queued", nil)
            }
            return HostedCheckRun(
                id: ids.id("policy", evaluation.evaluationId ?? name), name: name, status: state,
                conclusion: conclusion, startedAt: GitLabDate.parse(evaluation.startedDate),
                completedAt: GitLabDate.parse(evaluation.completedDate))
        }
    }

    /// `GET /<org>/<project>/_apis/policy/evaluations?artifactId=vstfs:///CodeReview/CodeReviewId/<projectId>/<n>`, a
    /// preview API (`7.1-preview.1`): any failure, or no project id, is no evaluation.
    private func policyEvaluations(of number: Int, projectID: String?, in repo: HostedRepository) async
        -> [AzureDevOpsPolicyEvaluation]
    {
        guard let projectID, !projectID.isEmpty,
            projectID.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == "-") }),
            let path = try? repoPath(repo)
        else { return [] }
        let evaluations: AzureDevOpsList<AzureDevOpsPolicyEvaluation>? = try? await get(
            url(
                [path[0], path[1], "_apis", "policy", "evaluations"],
                query: [("artifactId", "vstfs:///CodeReview/CodeReviewId/\(projectID)/\(number)")],
                apiVersion: "7.1-preview.1"))
        return evaluations?.value ?? []
    }

    /// `GET {R}`: its `defaultBranch` without `refs/heads/`.
    public func repositoryInfo(_ repo: HostedRepository) async throws -> HostedRepositoryInfo {
        let repository: AzureDevOpsRepository = try await get(url(try repoPath(repo)))
        guard let name = Self.branchName(repository.defaultBranch), !name.isEmpty else {
            throw HostingError.invalidResponse("a repository without a default branch")
        }
        return HostedRepositoryInfo(fullName: repo.fullName, defaultBranch: name)
    }

    /// None: Azure DevOps labels are free tags, with no repository list of them.
    public func labels(in repo: HostedRepository) async throws -> [HostedLabel] {
        []
    }

    /// `collaborators(in:)`: Azure DevOps pull requests have no assignees (no `assignees` capability), but the pull
    /// request page's reviewer menu reads this list.
    public func assignableUsers(in repo: HostedRepository) async throws -> [HostedUser] {
        try await collaborators(in: repo)
    }

    /// The members of the project's default team, any of whom can be asked to review:
    /// `GET /<org>/_apis/projects/<project>` for its id and `defaultTeam`, then
    /// `GET /<org>/_apis/projects/<projectId>/teams/<teamId>/members` (`$top`/`$skip`, at most `maxPages` pages), each
    /// identity once. Any error is no one.
    public func collaborators(in repo: HostedRepository) async throws -> [HostedUser] {
        do {
            let path = try repoPath(repo)
            let project: AzureDevOpsTeamProject = try await get(url([path[0], "_apis", "projects", path[1]]))
            guard let projectID = project.id, let teamID = project.defaultTeam?.id, !projectID.isEmpty,
                !teamID.isEmpty
            else { return [] }
            let members: [AzureDevOpsTeamMember] = try await pagedList(
                [path[0], "_apis", "projects", projectID, "teams", teamID, "members"], query: [])
            var seen: Set<String> = []
            return members.compactMap { member in
                guard let identity = member.identity, let id = identity.id?.lowercased(), !id.isEmpty,
                    seen.insert(id).inserted
                else { return nil }
                return identity.hosted
            }
        } catch {
            return []
        }
    }

    // MARK: - Writes

    /// The longest description Azure DevOps takes (in UTF-16 units, the safe reading of its limit).
    static let maxDescriptionLength = 4000

    /// `POST {R}/pullrequests?supportsIterations=true` from a branch of the same repository to another (a fork's
    /// `owner:branch` head is refused), with `isDraft`. A description longer than `maxDescriptionLength` is refused
    /// unsent. Reviewers and labels follow in their own calls.
    public func createPullRequest(_ pullRequest: NewPullRequest, in repo: HostedRepository) async throws
        -> HostedPullRequest
    {
        guard !pullRequest.head.contains(":") else {
            throw HostingError.validationFailed(message: "a pull request from a fork is not supported yet")
        }
        guard (pullRequest.body ?? "").utf16.count <= Self.maxDescriptionLength else {
            throw HostingError.validationFailed(
                message: "Azure DevOps takes a description of at most \(Self.maxDescriptionLength) characters")
        }
        struct Body: Encodable {
            var sourceRefName, targetRefName, title: String
            var description: String?
            var isDraft: Bool
        }
        let pr: AzureDevOpsPullRequest = try await send(
            "POST", url(try repoPath(repo) + ["pullrequests"], query: [("supportsIterations", "true")]),
            body: Body(
                sourceRefName: "refs/heads/" + pullRequest.head, targetRefName: "refs/heads/" + pullRequest.base,
                title: pullRequest.title, description: pullRequest.body, isDraft: pullRequest.draft))
        return self.pullRequest(pr, in: repo)
    }

    /// `PUT {PR}/reviewers/<guid>` with a vote of 0 for each of `users` (by its `reviewerID`, a GUID: refused unsent
    /// when one has none) not yet a reviewer of the pull request (read first), so no vote already cast is reset.
    public func requestReviewers(_ users: [HostedUser], on number: Int, in repo: HostedRepository) async throws {
        guard !users.isEmpty else { return }
        let ids = try users.map { user in
            guard let id = user.reviewerID, UUID(uuidString: id) != nil else {
                throw HostingError.validationFailed(message: "\(user.login) has no Azure DevOps id")
            }
            return id
        }
        let path = try pullRequestPath(number, in: repo)
        let current: AzureDevOpsPullRequest = try await get(url(path))
        var present = Set((current.reviewers ?? []).compactMap { $0.id?.lowercased() })
        struct Body: Encodable {
            var vote = 0
            var id: String
        }
        for id in ids where present.insert(id.lowercased()).inserted {
            let _: AzureDevOpsReviewer = try await send("PUT", url(path + ["reviewers", id]), body: Body(id: id))
        }
    }

    /// `POST {PR}/labels` with each name (Azure DevOps labels are free tags); issues are not supported.
    public func addLabels(_ names: [String], to item: HostedItem, in repo: HostedRepository) async throws {
        guard !names.isEmpty else { return }
        guard case .pullRequest(let number) = item else { throw Self.noIssues }
        let path = try pullRequestPath(number, in: repo) + ["labels"]
        struct Body: Encodable { var name: String }
        for name in names {
            _ = try await perform("POST", url(path), body: try JSONEncoder().encode(Body(name: name)))
        }
    }

    public func addAssignees(_ users: [HostedUser], to item: HostedItem, in repo: HostedRepository) async throws {
        guard !users.isEmpty else { return }
        throw HostingError.validationFailed(message: "Azure DevOps pull requests have no assignees")
    }

    /// A new active thread on the pull request itself (`POST {PR}/threads`), its root mapped as `comments(on:in:)`
    /// maps one, the token's user's own.
    public func comment(on item: HostedItem, in repo: HostedRepository, body: String) async throws -> HostedComment {
        guard case .pullRequest(let number) = item else { throw Self.noIssues }
        struct Comment: Encodable {
            var parentCommentId = 0
            var content: String
            var commentType = 1
        }
        struct Body: Encodable {
            var comments: [Comment]
            var status = 1
        }
        let raw: AzureDevOpsThread = try await send(
            "POST", url(try pullRequestPath(number, in: repo) + ["threads"]),
            body: Body(comments: [Comment(content: body)]))
        guard let thread = Self.threads([raw]).first, var root = Self.comments(thread, viewer: nil).first else {
            throw HostingError.invalidResponse("a thread without a comment")
        }
        (root.viewerCanEdit, root.viewerCanDelete) = (true, true)
        return root
    }

    /// `POST {PR}/threads/<thread>/comments` answering the thread's root: both come from the combined
    /// `rootCommentID` (`commentID(thread:comment:)`). A `hostKey` (the thread state's id,
    /// `threadKey(_:number:thread:)`, or the plain thread id) that names another thread, pull request or repository
    /// is refused unsent.
    public func reply(to thread: HostedThreadRef, on number: Int, in repo: HostedRepository, body: String)
        async throws -> HostedReviewComment
    {
        guard let parts = Self.split(thread.rootCommentID),
            thread.hostKey.map({ Self.isKey($0, of: parts.thread, on: number, in: repo) }) ?? true
        else {
            throw HostingError.validationFailed(message: "an unknown Azure DevOps thread: reload the pull request")
        }
        let threadID = parts.thread
        let comment = try await postReply(body, parent: parts.comment, thread: threadID, on: number, in: repo)
        guard let local = comment.id, let id = Self.commentID(thread: threadID, comment: local) else {
            throw HostingError.invalidResponse("a comment without an id")
        }
        var reply = HostedReviewComment(
            id: id, inReplyToID: thread.rootCommentID, path: "", body: comment.content,
            bodyHTML: comment.content.map(MarkdownHTML.html), user: comment.author?.hosted,
            createdAt: GitLabDate.parse(comment.publishedDate), hostKey: String(threadID))
        (reply.viewerCanEdit, reply.viewerCanDelete) = (true, true)
        return reply
    }

    /// Whether `key` names thread `threadID`: the plain thread id, or a `threadKey(_:number:thread:)` of that thread on
    /// pull request `number` of `repo` (its path without case).
    private static func isKey(_ key: String, of threadID: Int, on number: Int, in repo: HostedRepository) -> Bool {
        if key == String(threadID) { return true }
        guard let target = threadTarget(key) else { return false }
        return target.thread == threadID && target.number == number
            && target.repo.path.map { $0.lowercased() } == repo.path.map { $0.lowercased() }
    }

    /// `PATCH {PR}/threads/<thread>` with `status` `fixed` (resolved) or `active`, on the repository, pull request and
    /// thread the state's id names (`threadKey(_:number:thread:)`): an id that is not one, or names an invalid
    /// repository path, is refused unsent.
    public func setReviewThread(_ state: HostedReviewThreadState, resolved: Bool) async throws -> Bool {
        guard let target = Self.threadTarget(state.id) else {
            throw HostingError.validationFailed(message: "an unknown Azure DevOps thread: reload the pull request")
        }
        return try await setThread(target.thread, on: target.number, in: target.repo, resolved: resolved)
    }

    /// `PATCH {PR}/threads/<thread>` with `status` `fixed` or `active`; whether the answer's status reads as resolved.
    private func setThread(_ thread: Int, on number: Int, in repo: HostedRepository, resolved: Bool) async throws
        -> Bool
    {
        struct Body: Encodable { var status: String }
        let answer: AzureDevOpsThread = try await send(
            "PATCH", url(try pullRequestPath(number, in: repo) + ["threads", String(thread)]),
            body: Body(status: resolved ? "fixed" : "active"))
        return answer.status.map(Self.isResolved) ?? resolved
    }

    /// `POST {PR}/threads/<thread>/comments` with `parentCommentId` the comment answered.
    private func postReply(_ body: String, parent: Int, thread: Int, on number: Int, in repo: HostedRepository)
        async throws -> AzureDevOpsComment
    {
        struct Body: Encodable {
            var content: String
            var parentCommentId: Int
            var commentType = 1
        }
        return try await send(
            "POST", url(try pullRequestPath(number, in: repo) + ["threads", String(thread), "comments"]),
            body: Body(content: body, parentCommentId: parent))
    }

    /// `APPROVE` (10) and `REQUEST_CHANGES` (-5) set the token's user's vote first (`vote(_:on:in:)`), then post a
    /// non-empty body as a new thread, only once the vote was accepted. `COMMENT` posts the body as a thread only. The
    /// review's id follows `reviews(of:in:)`.
    public func review(_ number: Int, in repo: HostedRepository, event: HostedReviewEvent, body: String?)
        async throws -> HostedReview
    {
        let text = body.flatMap { $0.isEmpty ? nil : $0 }
        let me = try await myID()
        if event == .comment {
            guard let text else { throw HostingError.validationFailed(message: "a comment needs a body") }
            let comment = try await comment(on: .pullRequest(number), in: repo, body: text)
            return HostedReview(
                id: Self.stableID("review", me.lowercased()), user: comment.user, state: "COMMENTED",
                body: comment.body, bodyHTML: comment.bodyHTML, submittedAt: comment.createdAt)
        }
        let approve = event == .approve
        let reviewer = try await vote(approve ? 10 : -5, on: number, in: repo)
        if let text { _ = try await comment(on: .pullRequest(number), in: repo, body: text) }
        return HostedReview(
            id: Self.stableID("review", me.lowercased()), user: reviewer.identity.hosted,
            state: approve ? "APPROVED" : "CHANGES_REQUESTED", body: text, bodyHTML: text.map(MarkdownHTML.html),
            submittedAt: Date())
    }

    /// Takes the token's user's vote back: a vote of 0 (`vote(_:on:in:)`).
    public func unapprove(_ number: Int, in repo: HostedRepository) async throws {
        _ = try await vote(0, on: number, in: repo)
    }

    /// `PUT {PR}/reviewers/<guid>` with `vote` for the token's user; a 400 (the vote refused) is `validationFailed`
    /// with Azure's message.
    private func vote(_ vote: Int, on number: Int, in repo: HostedRepository) async throws -> AzureDevOpsReviewer {
        let path = try pullRequestPath(number, in: repo)
        let me = try await myID()
        struct Body: Encodable {
            var vote: Int
            var id: String
        }
        do {
            return try await send("PUT", url(path + ["reviewers", me]), body: Body(vote: vote, id: me))
        } catch HostingError.http(status: 400, let message) {
            throw HostingError.validationFailed(message: message.isEmpty ? "Azure DevOps refused the vote" : message)
        }
    }

    /// Azure's completion pins the head, but the pull request is read again first: its `lastMergeSourceCommit` must
    /// start with `sha` (hex, at least 7 digits, without case), else `HostingError.headChanged`. The method's
    /// strategy (`strategy(of:)`) must be one the merge strategy policies on the target branch allow, else, when none
    /// applies or they cannot be read, one of `mergeMethods`: refused unsent otherwise. Then `PATCH {PR}` with
    /// `status` `completed`, the head just read and the strategy. A 400 or 409 reads the pull request again: a new
    /// head is `headChanged`, anything else `validationFailed` with Azure's message. An answer already `completed` is
    /// done; otherwise (its `mergeStatus` may still be an earlier attempt's, so it is not judged) the pull request is
    /// read again up to `mergePolls` times until it is `completed`; a read with a `mergeStatus` of conflicts, a policy
    /// rejection or a failure is `validationFailed` (`mergeOutcome(_:)`), and running out of reads too.
    public func merge(_ number: Int, in repo: HostedRepository, method: HostedMergeMethod, sha: String) async throws {
        guard sha.count >= 7, sha.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw HostingError.headChanged }
        let path = try pullRequestPath(number, in: repo)
        let current: AzureDevOpsPullRequest = try await get(url(path))
        let latest = current.lastMergeSourceCommit?.commitId ?? ""
        let head = latest.lowercased()
        guard head.count >= 7, head.hasPrefix(sha.lowercased()) else { throw HostingError.headChanged }
        guard let strategy = Self.strategy(of: method) else {
            throw HostingError.validationFailed(message: "Azure DevOps has no such merge strategy")
        }
        guard await allowedStrategies(for: current, in: repo)?.contains(strategy) ?? mergeMethods.contains(method)
        else {
            throw HostingError.validationFailed(message: "this branch's policy does not allow this merge strategy")
        }
        struct Commit: Encodable { var commitId: String }
        struct Options: Encodable { var mergeStrategy: String }
        struct Body: Encodable {
            var status = "completed"
            var lastMergeSourceCommit: Commit
            var completionOptions: Options
        }
        let pr: AzureDevOpsPullRequest
        do {
            pr = try await send(
                "PATCH", url(path),
                body: Body(
                    lastMergeSourceCommit: Commit(commitId: latest),
                    completionOptions: Options(mergeStrategy: strategy)))
        } catch HostingError.http(let status, let message) where status == 400 || status == 409 {
            let now: AzureDevOpsPullRequest? = try? await get(url(path))
            if let now, (now.lastMergeSourceCommit?.commitId ?? "").lowercased() != head {
                throw HostingError.headChanged
            }
            throw HostingError.validationFailed(message: message.isEmpty ? "Azure DevOps did not merge it" : message)
        }
        guard pr.status != "completed" else { return }
        for _ in 0..<mergePolls {
            try await Task.sleep(for: mergePollDelay)
            switch Self.mergeOutcome(try await get(url(path))) {
            case .done: return
            case .failed(let message): throw HostingError.validationFailed(message: message)
            case .pending: continue
            }
        }
        throw HostingError.validationFailed(
            message: "Azure DevOps is still completing this pull request: reload it later.")
    }

    /// Abandons (`PATCH {PR}` with `status` `abandoned`) or reactivates (`active`) a pull request; Azure DevOps has no
    /// issues.
    public func setOpen(_ open: Bool, item: HostedItem, in repo: HostedRepository) async throws {
        guard case .pullRequest(let number) = item else { throw Self.noIssues }
        struct Body: Encodable { var status: String }
        let _: AzureDevOpsPullRequest = try await send(
            "PATCH", url(try pullRequestPath(number, in: repo)), body: Body(status: open ? "active" : "abandoned"))
    }

    private static let noIssues = HostingError.validationFailed(message: "Azure DevOps issues are not supported")

    // MARK: - Comment interactions

    /// `POST {PR}/threads/<thread>/comments` with `parentCommentId` the general comment answered (any comment of the
    /// thread: Azure nests to any depth), both from its combined id. A review comment's ref is refused unsent
    /// (`reply(to:on:in:body:)` answers inline threads).
    public func reply(
        toGeneral comment: HostedCommentRef, on item: HostedItem, in repo: HostedRepository, body: String
    ) async throws -> HostedComment {
        let (number, ids) = try Self.target(comment, on: item, general: true)
        let reply = try await postReply(body, parent: ids.comment, thread: ids.thread, on: number, in: repo)
        guard let local = reply.id, let id = Self.commentID(thread: ids.thread, comment: local) else {
            throw HostingError.invalidResponse("a comment without an id")
        }
        var mapped = HostedComment(
            id: id, user: reply.author?.hosted, body: reply.content, bodyHTML: reply.content.map(MarkdownHTML.html),
            createdAt: GitLabDate.parse(reply.publishedDate), updatedAt: GitLabDate.parse(reply.lastUpdatedDate),
            parentID: comment.id, hostKey: String(ids.thread))
        (mapped.viewerCanEdit, mapped.viewerCanDelete) = (true, true)
        return mapped
    }

    /// `PATCH {PR}/threads/<thread>` with `status` `fixed` or `active`, the thread from the root's combined id.
    public func setGeneralThread(
        _ root: HostedCommentRef, on item: HostedItem, in repo: HostedRepository, resolved: Bool
    ) async throws -> Bool {
        let (number, ids) = try Self.target(root, on: item, general: true)
        return try await setThread(ids.thread, on: number, in: repo, resolved: resolved)
    }

    /// `PATCH {PR}/threads/<thread>/comments/<comment>` with the new `content`, a general or an inline comment alike.
    public func editComment(_ comment: HostedCommentRef, on item: HostedItem, in repo: HostedRepository, body: String)
        async throws
    {
        let (number, ids) = try Self.target(comment, on: item)
        struct Body: Encodable { var content: String }
        let _: AzureDevOpsComment = try await send(
            "PATCH", url(try commentPath(ids, on: number, in: repo)), body: Body(content: body))
    }

    /// `DELETE {PR}/threads/<thread>/comments/<comment>` (Azure marks it deleted). What Azure does with a comment that
    /// has replies is not documented: a refusal with a message (other than 401, 403 and 404) is `validationFailed`
    /// with it.
    public func deleteComment(_ comment: HostedCommentRef, on item: HostedItem, in repo: HostedRepository)
        async throws
    {
        let (number, ids) = try Self.target(comment, on: item)
        do {
            _ = try await perform("DELETE", url(try commentPath(ids, on: number, in: repo)))
        } catch HostingError.http(_, let message) where !message.isEmpty {
            throw HostingError.validationFailed(message: message)
        }
    }

    /// `POST {PR}/threads/<thread>/comments/<comment>/likes`: a like, the only kind (`reactionKinds`); another is
    /// refused unsent.
    public func addReaction(
        _ kind: String, to comment: HostedCommentRef, on item: HostedItem, in repo: HostedRepository
    ) async throws {
        try await setLike(kind, on: comment, item: item, in: repo, added: true)
    }

    /// `DELETE {PR}/threads/<thread>/comments/<comment>/likes`, as `addReaction(_:to:on:in:)`.
    public func removeReaction(
        _ kind: String, from comment: HostedCommentRef, on item: HostedItem, in repo: HostedRepository
    ) async throws {
        try await setLike(kind, on: comment, item: item, in: repo, added: false)
    }

    private func setLike(
        _ kind: String, on comment: HostedCommentRef, item: HostedItem, in repo: HostedRepository, added: Bool
    ) async throws {
        guard kind == Self.like else {
            throw HostingError.validationFailed(message: "Azure DevOps has likes only")
        }
        let (number, ids) = try Self.target(comment, on: item)
        _ = try await perform(added ? "POST" : "DELETE", url(try commentPath(ids, on: number, in: repo) + ["likes"]))
    }

    /// `POST {PR}/threads`: a new active thread whose `threadContext` names the file (`/<path>`) and its lines on the
    /// new side (`rightFileStart`/`rightFileEnd`, an added or a context line's new line) or the old side
    /// (`leftFileStart`/`leftFileEnd`, a removed line's old line), each at offset 1, from the start line (the end line
    /// for one line) to the end line; its `pullRequestThreadContext` the file's `changeTrackingId` in the last
    /// iteration's changes and that iteration compared with the first. Refused unsent (no write) when the end line is
    /// missing on its side, a range's start line is not on that side or comes after the end, or the last iteration
    /// has no change tracking id for the file.
    public func createInlineComment(
        at position: HostedInlinePosition, on number: Int, in repo: HostedRepository, body: String
    ) async throws -> HostedReviewComment {
        struct Iterations: Encodable { var firstComparingIteration = 1; var secondComparingIteration: Int }
        struct ChangeContext: Encodable { var changeTrackingId: Int; var iterationContext: Iterations }
        struct Comment: Encodable {
            var parentCommentId = 0
            var content: String
            var commentType = 1
        }
        struct Body: Encodable {
            var comments: [Comment]
            var status = 1
            var threadContext: AzureDevOpsThreadContext
            var pullRequestThreadContext: ChangeContext
        }
        let newSide = position.lineKind != .removed
        guard let end = newSide ? position.newLine : position.oldLine else {
            throw HostingError.validationFailed(message: "no line on the \(newSide ? "new" : "old") side")
        }
        let ranged = position.startNewLine != nil || position.startOldLine != nil
        guard let start = ranged ? (newSide ? position.startNewLine : position.startOldLine) : end, start > 0,
            start <= end
        else {
            throw HostingError.validationFailed(message: "a range of lines must start on its last line's side")
        }
        let path = try pullRequestPath(number, in: repo)
        guard let changes = try await lastIterationChanges(of: number, in: repo),
            let tracking = changes.entries.first(where: { Self.entryPath($0) == position.path })?.changeTrackingId
        else {
            throw HostingError.validationFailed(
                message: "Azure DevOps does not list this file in the pull request: reload it")
        }
        let first = AzureDevOpsFilePosition(line: start, offset: 1)
        let last = AzureDevOpsFilePosition(line: end, offset: 1)
        var context = AzureDevOpsThreadContext(filePath: "/" + position.path)
        if newSide {
            (context.rightFileStart, context.rightFileEnd) = (first, last)
        } else {
            (context.leftFileStart, context.leftFileEnd) = (first, last)
        }
        let raw: AzureDevOpsThread = try await send(
            "POST", url(path + ["threads"]),
            body: Body(
                comments: [Comment(content: body)], threadContext: context,
                pullRequestThreadContext: ChangeContext(
                    changeTrackingId: tracking,
                    iterationContext: Iterations(secondComparingIteration: changes.iteration))))
        guard var thread = Self.threads([raw]).first else {
            throw HostingError.invalidResponse("a thread without a comment")
        }
        if !thread.isInline { thread.context = context }
        guard var root = Self.reviewComments(thread, viewer: nil).first else {
            throw HostingError.invalidResponse("a thread without a comment")
        }
        (root.viewerCanEdit, root.viewerCanDelete) = (true, true)
        return root
    }

    /// The thread and comment of a write on `comment` of pull request `item`, from its combined id: an issue, a ref
    /// that does not split, one whose `hostKey` names another thread, or (`general`) a review comment's ref is refused
    /// unsent.
    private static func target(_ comment: HostedCommentRef, on item: HostedItem, general: Bool = false) throws
        -> (number: Int, ids: (thread: Int, comment: Int))
    {
        guard case .pullRequest(let number) = item else { throw noIssues }
        guard !general || comment.kind == .general else {
            throw HostingError.validationFailed(message: "not a general Azure DevOps comment")
        }
        guard let ids = split(comment.id), comment.hostKey.map({ $0 == String(ids.thread) }) ?? true else {
            throw HostingError.validationFailed(message: "an unknown Azure DevOps comment: reload the pull request")
        }
        return (number, ids)
    }

    private func commentPath(_ ids: (thread: Int, comment: Int), on number: Int, in repo: HostedRepository) throws
        -> [String]
    {
        try pullRequestPath(number, in: repo) + ["threads", String(ids.thread), "comments", String(ids.comment)]
    }

    // MARK: - History and merge checks

    /// The pull request's system threads (`GET {PR}/threads`, `isSystem(_:)`), then "created the pull request" by its
    /// `createdBy` at its `creationDate` (`GET {PR}`), mapped by `events(_:pullRequest:)`.
    public func timelineEvents(of item: HostedItem, in repo: HostedRepository) async throws -> [HostedTimelineEvent] {
        guard case .pullRequest(let number) = item else { throw Self.noIssues }
        let path = try pullRequestPath(number, in: repo)
        async let pr: AzureDevOpsPullRequest = get(url(path))
        async let threads: AzureDevOpsList<AzureDevOpsThread> = get(url(path + ["threads"]))
        return Self.events(try await threads.value ?? [], pullRequest: try await pr)
    }

    /// One entry per system thread that is not deleted, from its first system comment (else its first comment), by
    /// `CodeReviewThreadType`: `VoteUpdate` "approved" (10), "approved with suggestions" (5), "is waiting for the
    /// author" (-5), "rejected" (-10), "reset their vote" (0) from `CodeReviewVoteResult` (else the comment's last
    /// word, "… voted -5"), action `approved`, `changes_requested` or `unapproved`; `ReviewersUpdate` "joined as a
    /// reviewer" (the one added is the one adding), "added <name> as a reviewer", "removed <name> from the reviewers",
    /// action `reviewer`; `RefUpdate` "pushed N commits" (`CodeReviewRefNewCommitsCount`) or "updated the pull
    /// request", action `commit`; anything else (`MergeAttempt`, a newer type, a system comment without a type) the
    /// comment's own words, action the type in lowercase (`mergeattempt`, else `system`), none when it has no words.
    /// Then "created the pull request", action `opened`. The actor is the identity the properties name
    /// (`…ByTfId` and `…ByDisplayName`), else the comment's author unless it is a group (Azure's service accounts
    /// write these comments); a comment's words lose a leading actor name (the page puts it first). Histq's words and
    /// the comment's are escaped in `textHTML`. Ids are `thread-<id>` and `created`.
    static func events(_ threads: [AzureDevOpsThread], pullRequest pr: AzureDevOpsPullRequest)
        -> [HostedTimelineEvent]
    {
        var events: [HostedTimelineEvent] = []
        func add(_ id: String, _ actor: HostedUser?, _ date: String?, _ text: String, action: String) {
            events.append(HostedTimelineEvent(
                id: id, actor: actor, createdAt: GitLabDate.parse(date), text: text,
                textHTML: "<p>\(MarkdownHTML.escape(text))</p>", action: action))
        }
        for thread in threads where thread.isDeleted != true && isSystem(thread) {
            guard let id = thread.id else { continue }
            let comments = (thread.comments ?? []).filter { $0.isDeleted != true }
            guard let comment = comments.first(where: { $0.commentType == "system" }) ?? comments.first else {
                continue
            }
            let properties = thread.properties
            func person(_ prefix: String) -> AzureDevOpsIdentity? {
                let name = (properties[prefix + "DisplayName"] ?? properties[prefix + "Displayname"])
                    .flatMap { $0.isEmpty ? nil : $0 }
                let guid = properties[prefix + "TfId"].flatMap(Self.guid)
                guard name != nil || guid != nil else { return nil }
                return AzureDevOpsIdentity(id: guid, displayName: name)
            }
            let type = properties["CodeReviewThreadType"]
            let byPrefix = [
                "VoteUpdate": "CodeReviewVotedBy", "ReviewersUpdate": "CodeReviewReviewersUpdatedBy",
                "RefUpdate": "CodeReviewRefUpdatedBy",
            ][type ?? ""]
            let actor = byPrefix.flatMap(person) ?? (comment.author?.isContainer == true ? nil : comment.author)
            var words = comment.content ?? ""
            if let name = actor?.displayName, !name.isEmpty, words.hasPrefix(name + " ") {
                words = String(words.dropFirst(name.count + 1))
            }
            let key = "thread-\(id)", date = comment.publishedDate
            switch type {
            case "VoteUpdate":
                let vote = properties["CodeReviewVoteResult"].flatMap { Int($0) }
                    ?? words.split(separator: " ").last.flatMap { Int($0) }
                let shown: (String, String)? = switch vote {
                case 10: ("approved", "approved")
                case 5: ("approved with suggestions", "approved")
                case -5: ("is waiting for the author", "changes_requested")
                case -10: ("rejected", "changes_requested")
                case 0: ("reset their vote", "unapproved")
                default: nil
                }
                if let shown { add(key, actor?.hosted, date, shown.0, action: shown.1); continue }
            case "ReviewersUpdate":
                let added = person("CodeReviewReviewersUpdatedAdded")
                let removed = person("CodeReviewReviewersUpdatedRemoved")
                if let added, added.id != nil, added.id == actor?.id?.lowercased() {
                    add(key, actor?.hosted, date, "joined as a reviewer", action: "reviewer")
                } else if let name = added?.displayName, !name.isEmpty {
                    add(key, actor?.hosted, date, "added \(name) as a reviewer", action: "reviewer")
                } else if let name = removed?.displayName, !name.isEmpty {
                    add(key, actor?.hosted, date, "removed \(name) from the reviewers", action: "reviewer")
                } else {
                    add(key, actor?.hosted, date, words.isEmpty ? "updated the reviewers" : words, action: "reviewer")
                }
                continue
            case "RefUpdate":
                let count = properties["CodeReviewRefNewCommitsCount"].flatMap { Int($0) } ?? 0
                let text = count > 0
                    ? "pushed \(count) \(count == 1 ? "commit" : "commits")" : "updated the pull request"
                add(key, actor?.hosted, date, text, action: "commit")
                continue
            default: break
            }
            guard !words.isEmpty else { continue }
            add(key, actor?.hosted, date, words, action: type.map { $0.lowercased() } ?? "system")
        }
        add("created", pr.createdBy?.hosted, pr.creationDate, "created the pull request", action: "opened")
        return events
    }

    /// A GUID in lowercase with its dashes, from Azure's `…TfId` (sent with or without dashes); nil when it is not one.
    static func guid(_ text: String) -> String? {
        let hex = text.replacingOccurrences(of: "-", with: "").lowercased()
        guard hex.count == 32, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        var parts: [Substring] = []
        var rest = Substring(hex)
        for length in [8, 4, 4, 4, 12] {
            parts.append(rest.prefix(length))
            rest = rest.dropFirst(length)
        }
        return parts.joined(separator: "-")
    }

    /// The enabled, blocking policies' evaluations (`policyEvaluations(of:projectID:in:)`, best-effort: a failure is
    /// none), each required: `approved` `PASSED`, `rejected` and `broken` `FAILED` (blocking), `queued` and `running`
    /// `PENDING` (blocking), `notApplicable` `SKIPPED`; then "Conflicts" (failed, blocking) when the pull request's
    /// `mergeStatus` is `conflicts`.
    public func mergeChecks(of number: Int, in repo: HostedRepository) async throws -> [HostedMergeCheck] {
        let pr: AzureDevOpsPullRequest = try await get(url(try pullRequestPath(number, in: repo)))
        let evaluations = await policyEvaluations(of: number, projectID: pr.repository?.project?.id, in: repo)
        var checks = evaluations.compactMap { evaluation -> HostedMergeCheck? in
            guard let configuration = evaluation.configuration, configuration.isEnabled != false,
                configuration.isBlocking != false
            else { return nil }
            let status = switch evaluation.status {
            case "approved": "PASSED"
            case "rejected", "broken": "FAILED"
            case "queued", "running": "PENDING"
            case "notApplicable": "SKIPPED"
            default: "UNKNOWN"
            }
            return HostedMergeCheck(
                name: configuration.type?.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? "Policy", status: status,
                required: true, blocking: status == "FAILED" || status == "PENDING")
        }
        if pr.mergeStatus == "conflicts" {
            checks.append(HostedMergeCheck(name: "Conflicts", status: "FAILED", required: true, blocking: true))
        }
        return checks
    }

    // MARK: - Merge strategies

    /// Where a completion stands: done, failed (with Azure's reason), or still going.
    enum MergeOutcome: Equatable {
        case done, pending
        case failed(String)
    }

    /// A pull request read after its completion was asked for: `completed` is done; abandoned, or a `mergeStatus` of
    /// `conflicts`, `rejectedByPolicy` or `failure`, failed with its `mergeFailureMessage` (else a reason of its own);
    /// anything else is still going.
    static func mergeOutcome(_ pr: AzureDevOpsPullRequest) -> MergeOutcome {
        if pr.status == "completed" { return .done }
        if pr.status == "abandoned" { return .failed("the pull request was abandoned") }
        let reason = pr.mergeFailureMessage.flatMap { $0.isEmpty ? nil : $0 }
        return switch pr.mergeStatus {
        case "conflicts": .failed(reason ?? "the pull request has merge conflicts")
        case "rejectedByPolicy": .failed(reason ?? "a branch policy rejected the merge")
        case "failure": .failed(reason ?? "Azure DevOps could not merge it")
        default: .pending
        }
    }

    /// The `mergeStrategy` a completion takes for `method`: no fast-forward, squash and rebase (rebase and
    /// fast-forward). Azure's `rebaseMerge` (rebase with a merge commit) is no method here. The one map of methods to
    /// strategies.
    static func strategy(of method: HostedMergeMethod) -> String? {
        switch method {
        case .merge: "noFastForward"
        case .squash: "squash"
        case .rebase: "rebase"
        default: nil
        }
    }

    /// The methods of `strategies` (Azure's names), in the merge dialog's order; nil for nil or none left.
    static func mergeMethods(_ strategies: Set<String>?) -> [HostedMergeMethod]? {
        guard let strategies else { return nil }
        let methods = [HostedMergeMethod.merge, .squash, .rebase].filter {
            strategy(of: $0).map(strategies.contains) ?? false
        }
        return methods.isEmpty ? nil : methods
    }

    /// "Require a merge strategy"'s policy type id.
    static let mergeStrategyPolicyType = "fa4e907d-c16b-4a4c-9dfa-4916e5d171ab"

    /// The strategies the merge strategy policies on `pr`'s target branch allow, by Azure's names
    /// (`GET /<org>/<project>/_apis/policy/configurations?policyType=…`, `$top`, then the `x-ms-continuationtoken`
    /// answer header as `continuationToken`, at most `maxPages` pages; `allowedStrategies(_:targetRef:repositoryID:)`).
    /// Nil when none applies, they allow none, or they cannot be read (any error).
    private func allowedStrategies(for pr: AzureDevOpsPullRequest, in repo: HostedRepository) async -> Set<String>? {
        guard let target = pr.targetRefName, !target.isEmpty, let path = try? repoPath(repo) else { return nil }
        var configurations: [AzureDevOpsPolicyConfiguration] = []
        var continuation: String?
        do {
            for _ in 0..<maxPages {
                let query = [("policyType", Self.mergeStrategyPolicyType), ("$top", "100")]
                    + (continuation.map { [("continuationToken", $0)] } ?? [])
                let (data, response) = try await perform(
                    "GET", url([path[0], path[1], "_apis", "policy", "configurations"], query: query))
                let page: AzureDevOpsList<AzureDevOpsPolicyConfiguration> = try Self.decode(data)
                configurations += page.value ?? []
                guard let next = response.value(forHTTPHeaderField: "x-ms-continuationtoken"), !next.isEmpty,
                    next != continuation
                else { break }
                continuation = next
            }
        } catch {
            return nil
        }
        return Self.allowedStrategies(configurations, targetRef: target, repositoryID: pr.repository?.id)
    }

    /// The strategies every enabled, blocking merge strategy policy whose scope takes `targetRef` in repository
    /// `repositoryID` allows (Azure checks each policy); nil when none applies or they allow none.
    static func allowedStrategies(
        _ configurations: [AzureDevOpsPolicyConfiguration], targetRef: String, repositoryID: String?
    ) -> Set<String>? {
        var allowed: Set<String>?
        for configuration in configurations where configuration.isEnabled == true
            && configuration.isBlocking != false && configuration.type?.id?.lowercased() == mergeStrategyPolicyType
        {
            guard let settings = configuration.settings,
                (settings.scope ?? []).contains(where: {
                    isInScope($0, targetRef: targetRef, repositoryID: repositoryID)
                })
            else { continue }
            let flags = [
                ("noFastForward", settings.allowNoFastForward), ("squash", settings.allowSquash),
                ("rebase", settings.allowRebase), ("rebaseMerge", settings.allowRebaseMerge),
            ]
            let names = Set(flags.filter { $0.1 == true }.map(\.0))
            allowed = allowed.map { $0.intersection(names) } ?? names
        }
        return allowed.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Whether a policy's scope takes `targetRef` in repository `repositoryID`, without case: a scope without a
    /// repository takes every repository of the project, one without a ref (nor a match kind) every branch; `exact`
    /// is the ref itself, `prefix` the ref itself or a ref under it. Another match kind (the default branch) takes
    /// none.
    static func isInScope(_ scope: AzureDevOpsPolicyConfiguration.Scope, targetRef: String, repositoryID: String?)
        -> Bool
    {
        if let id = scope.repositoryId, id.lowercased() != repositoryID?.lowercased() { return false }
        guard let name = scope.refName?.lowercased() else { return scope.matchKind == nil }
        let ref = targetRef.lowercased()
        switch scope.matchKind?.lowercased() {
        case "exact": return ref == name
        case "prefix": return ref == name || ref.hasPrefix(name.hasSuffix("/") ? name : name + "/")
        default: return false
        }
    }

    // MARK: - Mapping

    /// The head's `owner:branch` label is set only for a branch of the same repository (nil with a `forkSource`).
    /// `active` is open; `completed` (merged, at its `closedDate`, its `lastMergeCommit` the merge commit) and
    /// `abandoned` are closed. The requested reviewers are those who have not voted and not declined. `mergeable` and
    /// `mergeableState` from `mergeStatus` (`mergeable(_:)`, `mergeableState(_:)`); active labels only. The head commit
    /// is remembered with the number and project id, for `checkRuns(for:in:)`.
    private func pullRequest(_ pr: AzureDevOpsPullRequest, in repo: HostedRepository) -> HostedPullRequest {
        let source = Self.branchName(pr.sourceRefName) ?? ""
        let target = Self.branchName(pr.targetRefName) ?? ""
        let merged = pr.status == "completed"
        let head = pr.lastMergeSourceCommit?.commitId ?? ""
        if !head.isEmpty {
            memo.pullRequestByHead.withLock {
                $0[Self.headKey(repo, head)] = (pr.pullRequestId, pr.repository?.project?.id)
            }
        }
        let waiting = (pr.reviewers ?? []).filter { ($0.vote ?? 0) == 0 && $0.hasDeclined != true }
        let created = GitLabDate.parse(pr.creationDate)
        let closed = GitLabDate.parse(pr.closedDate)
        return HostedPullRequest(
            id: pr.pullRequestId, number: pr.pullRequestId, title: pr.title ?? "",
            state: pr.status == "active" ? "open" : "closed", draft: pr.isDraft, user: pr.createdBy?.hosted,
            body: pr.description, bodyHTML: pr.description.map(MarkdownHTML.html),
            htmlURL: webURL(.pullRequest(pr.pullRequestId), in: repo)?.absoluteString ?? "",
            head: HostedBranchRef(
                label: pr.forkSource == nil ? repo.owner + ":" + source : nil, ref: source, sha: head),
            base: HostedBranchRef(
                label: repo.owner + ":" + target, ref: target, sha: pr.lastMergeTargetCommit?.commitId ?? ""),
            labels: (pr.labels ?? []).filter { $0.active != false }.compactMap { label in
                label.name.flatMap { $0.isEmpty ? nil : HostedLabel(name: $0) }
            },
            requestedReviewers: waiting.map(\.identity.hosted), createdAt: created, updatedAt: closed ?? created,
            mergedAt: merged ? closed : nil, merged: merged, mergeable: Self.mergeable(pr.mergeStatus),
            mergeableState: Self.mergeableState(pr.mergeStatus),
            mergeCommitSHA: merged ? pr.lastMergeCommit?.commitId : nil)
    }

    /// `mergeStatus` as GitHub's conflict-free `mergeable`: true for `succeeded`, false for `conflicts`, else unknown.
    static func mergeable(_ status: String?) -> Bool? {
        switch status {
        case "succeeded": true
        case "conflicts": false
        default: nil
        }
    }

    /// `mergeStatus` in GitHub's `mergeable_state` words: `succeeded` is `clean`, `conflicts` `dirty`, `notSet` and
    /// `queued` (not yet evaluated) `unknown`, and `rejectedByPolicy`, `failure` and any newer value `blocked`.
    static func mergeableState(_ status: String?) -> String? {
        switch status {
        case nil: nil
        case "succeeded": "clean"
        case "conflicts": "dirty"
        case "notSet", "queued": "unknown"
        default: "blocked"
        }
    }

    /// The branch of a ref: without `refs/heads/`, else as given.
    private static func branchName(_ ref: String?) -> String? {
        guard let ref else { return nil }
        return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
    }

    /// `memo.pullRequestByHead`'s key: the repository's path and the head commit, without case.
    private static func headKey(_ repo: HostedRepository, _ sha: String) -> String {
        (repo.path + [sha]).joined(separator: "\n").lowercased()
    }

    /// `reviews(of:in:)`'s reviews from a pull request's reviewers (each GUID once).
    static func reviews(_ pr: AzureDevOpsPullRequest) -> [HostedReview] {
        var seen: Set<String> = []
        var rows: [(key: String, review: HostedReview)] = []
        for reviewer in pr.reviewers ?? [] {
            guard let id = reviewer.id?.lowercased(), !id.isEmpty, seen.insert(id).inserted else { continue }
            let vote = reviewer.vote ?? 0
            guard vote != 0 || reviewer.hasDeclined != true else { continue }
            var review = HostedReview(
                id: stableID("review", id), user: reviewer.identity.hosted,
                state: vote > 0 ? "APPROVED" : vote < 0 ? "CHANGES_REQUESTED" : "PENDING")
            (review.vote, review.isRequired) = (vote, reviewer.isRequired ?? false)
            rows.append((id, review))
        }
        return rows.sorted { $0.key < $1.key }.map(\.review)
    }

    /// The token's user's profile id, asked once (`currentUser()`).
    private func myID() async throws -> String {
        if let id = memo.profileID.withLock({ $0 }) { return id }
        guard let id = try await currentUser().reviewerID, !id.isEmpty else {
            throw HostingError.invalidResponse("a user without an id")
        }
        return id
    }

    /// The active pull requests of `repo` whose `criterion` (`searchCriteria.creatorId` or `…reviewerId`) is the token's
    /// user, as issue-shaped rows (`pullRequest` and `draft` set).
    private func activePullRequests(in repo: HostedRepository, criterion: String) async throws -> [HostedIssue] {
        let path = try repoPath(repo) + ["pullrequests"]
        let me = try await myID()
        let prs: [AzureDevOpsPullRequest] = try await pagedList(
            path, query: [("searchCriteria.status", "active"), (criterion, me)])
        return prs.map { pr in
            let pull = pullRequest(pr, in: repo)
            return HostedIssue(
                id: pull.id, number: pull.number, title: pull.title, state: pull.state, user: pull.user,
                body: pull.body, htmlURL: pull.htmlURL, labels: pull.labels, createdAt: pull.createdAt,
                updatedAt: pull.updatedAt, pullRequest: .init(url: pull.htmlURL), draft: pull.draft)
        }
    }

    /// A repository that is not disabled, with an https `remoteUrl` naming it in `organization` (else, without one
    /// that parses, named from its project and name when those are safe: the clone URL is still the remote URL).
    static func cloneRepository(_ repository: AzureDevOpsRepository, in organization: String)
        -> HostedCloneRepository?
    {
        guard repository.isDisabled != true, let link = repository.remoteUrl, link.lowercased().hasPrefix("https://")
        else { return nil }
        var named = Self.repository(fromRemoteURL: link)
        if named == nil, let project = repository.project?.name, let name = repository.name,
            isSafeName(project), isSafeName(name)
        {
            named = HostedRepository(host: host, path: [organization, project, name])
        }
        guard let named, named.path[0].lowercased() == organization.lowercased() else { return nil }
        return HostedCloneRepository(
            id: stableID("repository", repository.id ?? named.fullName), name: named.name, fullName: named.fullName,
            owner: HostedUser(id: stableID("project", named.owner), login: named.owner), cloneURL: link,
            isPrivate: repository.project?.visibility != "public", fork: repository.isFork)
    }

    // MARK: - Threads

    /// A comment of a thread, by its combined id, with the comment it answers directly (nil for the root).
    struct ThreadComment {
        var comment: AzureDevOpsComment
        var id: Int
        var parentID: Int?
    }

    /// A comment thread: its id, status and context (nil for one on the pull request itself), and its comments, the
    /// root first, then its replies oldest first.
    struct CommentThread {
        var id: Int
        var status: String?
        var context: AzureDevOpsThreadContext?
        var comments: [ThreadComment]

        /// A thread on a file: its context names one.
        var isInline: Bool { filePath(context?.filePath) != nil }
    }

    /// The threads on a file.
    private func inlineThreads(of number: Int, in repo: HostedRepository) async throws -> [CommentThread] {
        try await threads(of: number, in: repo).filter(\.isInline)
    }

    private func threads(of number: Int, in repo: HostedRepository) async throws -> [CommentThread] {
        let threads: AzureDevOpsList<AzureDevOpsThread> = try await get(
            url(try pullRequestPath(number, in: repo) + ["threads"]))
        return Self.threads(threads.value ?? [])
    }

    /// The comment threads of a pull request, oldest root first. Left out: deleted threads and comments, system threads
    /// (a `CodeReviewThreadType` property, or any comment of type `system`: votes, pushes, merges), comments whose
    /// combined id cannot be made, and threads with no comment left. The root is the first comment (by id) without a
    /// parent, else the first one left; a reply whose parent was left out answers the root.
    static func threads(_ raw: [AzureDevOpsThread]) -> [CommentThread] {
        raw.compactMap { thread -> CommentThread? in
            guard thread.isDeleted != true, let threadID = thread.id, !isSystem(thread) else { return nil }
            let kept = (thread.comments ?? [])
                .compactMap { comment -> (AzureDevOpsComment, Int, Int)? in
                    guard comment.isDeleted != true, let local = comment.id,
                        let id = commentID(thread: threadID, comment: local)
                    else { return nil }
                    return (comment, local, id)
                }
                .sorted { $0.1 < $1.1 }
            guard let root = kept.first(where: { ($0.0.parentCommentId ?? 0) == 0 }) ?? kept.first else { return nil }
            let ids = Set(kept.map(\.1))
            let replies = kept.filter { $0.2 != root.2 }.map { comment, _, id in
                let parent = comment.parentCommentId ?? 0
                let parentID = parent != root.1 && ids.contains(parent)
                    ? commentID(thread: threadID, comment: parent) ?? root.2 : root.2
                return ThreadComment(comment: comment, id: id, parentID: parentID)
            }
            func isOlder(_ a: ThreadComment, _ b: ThreadComment) -> Bool {
                (GitLabDate.parse(a.comment.publishedDate) ?? .distantPast, a.id)
                    < (GitLabDate.parse(b.comment.publishedDate) ?? .distantPast, b.id)
            }
            return CommentThread(
                id: threadID, status: thread.status, context: thread.threadContext,
                comments: [ThreadComment(comment: root.0, id: root.2, parentID: nil)] + replies.sorted(by: isOlder))
        }
        .sorted { a, b in
            (GitLabDate.parse(a.comments[0].comment.publishedDate) ?? .distantPast, a.id)
                < (GitLabDate.parse(b.comments[0].comment.publishedDate) ?? .distantPast, b.id)
        }
    }

    /// A system thread (votes, reviewers, pushes, merge attempts): a `CodeReviewThreadType` property, or a comment of
    /// type `system`. `threads(_:)` leaves them out and `events(_:pullRequest:)` reads only them.
    static func isSystem(_ thread: AzureDevOpsThread) -> Bool {
        thread.properties["CodeReviewThreadType"] != nil
            || (thread.comments ?? []).contains { $0.commentType == "system" }
    }

    /// Whether a thread status reads as resolved: every status but `active`, `pending` and `unknown` (`fixed`,
    /// `wontFix`, `closed`, `byDesign`, as Azure's page folds them); none is not.
    static func isResolved(_ status: String?) -> Bool {
        switch status {
        case nil, "active", "pending", "unknown": false
        default: true
        }
    }

    /// A general thread's comments: `parentID` the direct parent, the root resolvable when the thread has a status,
    /// and the thread id as `hostKey`; edit rights and likes as `isOwn(_:viewer:)` and `likes(_:viewer:)` read them.
    static func comments(_ thread: CommentThread, viewer: String?) -> [HostedComment] {
        thread.comments.map { entry in
            let comment = entry.comment
            let isRoot = entry.parentID == nil
            var mapped = HostedComment(
                id: entry.id, user: comment.author?.hosted, body: comment.content,
                bodyHTML: comment.content.map(MarkdownHTML.html), createdAt: GitLabDate.parse(comment.publishedDate),
                updatedAt: GitLabDate.parse(comment.lastUpdatedDate), parentID: entry.parentID,
                resolvable: isRoot ? thread.status != nil : nil,
                resolved: isRoot && thread.status != nil ? isResolved(thread.status) : nil,
                hostKey: String(thread.id))
            if isRoot { mapped.threadStatus = thread.status }
            let own = isOwn(comment, viewer: viewer)
            (mapped.viewerCanEdit, mapped.viewerCanDelete) = (own, own)
            mapped.reactions = likes(comment, viewer: viewer)
            return mapped
        }
    }

    /// Whether the token's user (`viewer`, their profile GUID) wrote `comment`: Azure sends no edit or delete rights,
    /// and lets only the author do either.
    static func isOwn(_ comment: AzureDevOpsComment, viewer: String?) -> Bool {
        guard let viewer, !viewer.isEmpty, let author = comment.author?.id else { return false }
        return author.lowercased() == viewer.lowercased()
    }

    /// A comment's likes (`usersLiked`, each GUID once) as one reaction of kind `like`, `viewerReacted` when the
    /// token's user is one of them; none without a like.
    static func likes(_ comment: AzureDevOpsComment, viewer: String?) -> [HostedReaction] {
        let ids = Set((comment.usersLiked ?? []).compactMap { $0.id?.lowercased() }.filter { !$0.isEmpty })
        guard !ids.isEmpty else { return [] }
        let mine = viewer.map { ids.contains($0.lowercased()) } ?? false
        return [HostedReaction(kind: like, count: ids.count, viewerReacted: mine)]
    }

    /// An inline thread's comments, each reply pointing at the root (`reviewComments(of:in:)`), with edit rights and
    /// likes as `comments(_:viewer:)`.
    static func reviewComments(_ thread: CommentThread, viewer: String?) -> [HostedReviewComment] {
        let context = thread.context
        let right = context?.rightFileStart != nil
        let start = (right ? context?.rightFileStart : context?.leftFileStart)?.line.flatMap { $0 > 0 ? $0 : nil }
        let end = (right ? context?.rightFileEnd : context?.leftFileEnd)?.line.flatMap { $0 > 0 ? $0 : nil } ?? start
        let first = start.flatMap { $0 != end ? $0 : nil }
        let path = filePath(context?.filePath) ?? ""
        let rootID = thread.comments[0].id
        return thread.comments.map { entry in
            let comment = entry.comment
            var mapped = HostedReviewComment(
                id: entry.id, inReplyToID: entry.id == rootID ? nil : rootID, path: path, line: end,
                originalLine: end, startLine: first, originalStartLine: first, side: right ? "RIGHT" : "LEFT",
                body: comment.content, bodyHTML: comment.content.map(MarkdownHTML.html), user: comment.author?.hosted,
                createdAt: GitLabDate.parse(comment.publishedDate), hostKey: String(thread.id))
            let own = isOwn(comment, viewer: viewer)
            (mapped.viewerCanEdit, mapped.viewerCanDelete) = (own, own)
            mapped.reactions = likes(comment, viewer: viewer)
            return mapped
        }
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

    /// A link that is https; nil otherwise.
    private static func httpsLink(_ link: String?) -> String? {
        guard let link, link.lowercased().hasPrefix("https://"), URL(string: link) != nil else { return nil }
        return link
    }

    /// `<org>/<project>/_apis/git/repositories/<repo>` for a repository on `dev.azure.com` named by exactly three
    /// segments, none empty, `.` or `..`, the organization a safe one (each is percent-encoded as one segment by `url`).
    private func repoPath(_ repo: HostedRepository) throws -> [String] {
        guard repo.host.lowercased() == Self.host else { throw HostingError.wrongHost(repo.host) }
        guard repo.path.count == 3, Self.isSafeOrganization(repo.path[0]),
            !repo.path.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            throw HostingError.validationFailed(message: "not a repository path: \(repo.path.joined(separator: "/"))")
        }
        return [repo.path[0], repo.path[1], "_apis", "git", "repositories", repo.path[2]]
    }

    private func pullRequestPath(_ number: Int, in repo: HostedRepository) throws -> [String] {
        try repoPath(repo) + ["pullrequests", String(number)]
    }

    /// `origin` (`apiOrigin` unless given) plus `segments`, each percent-encoded as one path segment, then `query` in
    /// order and `api-version`, with `+` as `%2B` so it never reads as a space.
    private func url(
        _ segments: [String], query: [(String, String)] = [], on origin: URL = Self.apiOrigin,
        apiVersion: String = Self.apiVersion
    ) -> URL {
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = segments
            .map { "/" + ($0.addingPercentEncoding(withAllowedCharacters: Self.segmentAllowed) ?? "") }.joined()
        components.queryItems = (query + [("api-version", apiVersion)]).map { URLQueryItem(name: $0.0, value: $0.1) }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// The percent-encoded path a request to `url` and its redirects must stay under: its first segment (the
    /// organization) on `https://dev.azure.com`, `/_apis` on `https://app.vssps.visualstudio.com`; nil for any other
    /// URL (another origin, not https, an empty, `.` or `..` organization).
    static func allowedPrefix(of url: URL) -> String? {
        if HostingHTTP.isSameOrigin(url, apiOrigin) {
            guard let first = url.path(percentEncoded: true).split(separator: "/").first.map(String.init) else {
                return nil
            }
            let decoded = first.removingPercentEncoding ?? first
            guard !decoded.isEmpty, decoded != ".", decoded != "..", !decoded.contains("/") else { return nil }
            let prefix = "/" + first
            return HostingHTTP.isPath(of: url, under: prefix) ? prefix : nil
        }
        if HostingHTTP.isSameOrigin(url, profileOrigin), HostingHTTP.isPath(of: url, under: "/_apis") {
            return "/_apis"
        }
        return nil
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

    /// Reads `segments` page by page (`$top=100`, then `$skip` by 100) until a short page or `maxPages` pages.
    private func pagedList<T: Decodable>(_ segments: [String], query: [(String, String)]) async throws -> [T] {
        var result: [T] = []
        for page in 0..<maxPages {
            let list: AzureDevOpsList<T> = try await get(
                url(segments, query: query + [("$top", "100"), ("$skip", String(page * 100))]))
            let values = list.value ?? []
            result += values
            guard values.count >= 100 else { break }
        }
        return result
    }

    /// The one place a request is made and the token attached, only to an https URL `allowedPrefix(of:)` accepts. A
    /// 401 asks the provider for a refreshed token and retries once; a second 401 is `unauthorized`.
    private func perform(_ method: String, _ url: URL, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let prefix = Self.allowedPrefix(of: url) else {
            throw HostingError.invalidResponse("a URL outside the API")
        }
        let token = try await self.token(nil)
        var (data, response) = try await load(method, url, body: body, token: token, prefix: prefix)
        if response.statusCode == 401 {
            (data, response) = try await load(method, url, body: body, token: try await self.token(token), prefix: prefix)
        }
        guard (200..<300).contains(response.statusCode) else { throw HostingHTTP.error(for: response, data: data) }
        return (data, response)
    }

    /// A redirect is followed only on the same origin and under `prefix`, the request's own organization (or `/_apis`).
    private func load(_ method: String, _ url: URL, body: Data?, token: String, prefix: String) async throws
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
        return try await HostingHTTP.load(request, session: session, allowedPathPrefix: prefix)
    }
}
