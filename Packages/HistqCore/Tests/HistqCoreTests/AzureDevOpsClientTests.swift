// Contract tests for the Azure DevOps Services client, served by `StubServer` (GitHubClientTests.swift) with inline
// JSON shaped as the REST 7.1 reference (`{count, value}` lists, thread statuses and comment types as names,
// `properties` as `{"$type", "$value"}` pairs): no test reaches the network. They guard the token (only in the
// `Authorization` header, only to `https://dev.azure.com/<org>/…` or `https://app.vssps.visualstudio.com/_apis/…`,
// never to a redirect elsewhere, and a continuation only moves the token query parameter), the merge's head check and
// completion polling, the mapping of threads into combined comment ids, and the order of a review's writes.
import Foundation
import HistqCore
import Synchronization
import Testing

struct AzureDevOpsClientTests {
    /// Made-up tokens; the tests look for them where they must never be.
    static let token = "histq-fake-azure-fresh-0123456789"
    static let staleToken = "histq-fake-azure-stale-0123456789"

    static let api = "https://dev.azure.com"
    static let profileHost = "https://app.vssps.visualstudio.com"
    static let repo = HostedRepository(host: "dev.azure.com", path: ["fabrikam", "Web", "app"])
    static let repoPath = "/fabrikam/Web/_apis/git/repositories/app"
    static let prPath = repoPath + "/pullrequests/7"
    static let policyPath = "/fabrikam/Web/_apis/policy/configurations"
    static let profilePath = "/_apis/profile/profiles/me"
    static let head = "abc123def4567890abc123def4567890abc12345"
    static let meID = "d6245f20-2af8-44f4-9451-8107cb2767db"
    static let projectID = "a7573007-bbb3-4341-b726-0c4148a07853"
    static let repositoryID = "3411ebc1-d5aa-464f-9615-0b527bc66719"

    static func identity(_ name: String, id: String) -> String {
        #"{"displayName": "\#(name)", "url": "https://spsprodweu5.vssps.visualstudio.com/A0/_apis/Identities/\#(id)", "id": "\#(id)", "descriptor": "aad.ZmFrZQ"}"#
    }

    static let me = identity("Jane Doe", id: meID)

    static let profile = """
        {"displayName": "Jane Doe", "publicAlias": "\(meID)", "emailAddress": "jane@example.com",
         "coreRevision": 1, "timeStamp": "2026-01-02T10:00:00.1234567+00:00", "id": "\(meID)", "revision": 1}
        """

    /// Pull request #`id` from `feature` (at `hash`) into `main`, `status`, `mergeStatus` and `reviewers` (a JSON
    /// array; the token's user without a vote by default) as given.
    static func pullRequest(
        id: Int = 7, hash: String = head, status: String = "active", mergeStatus: String = "succeeded",
        failure: String? = nil, reviewers: String? = nil
    ) -> String {
        """
        {"repository": {"id": "\(repositoryID)", "name": "app",
                        "project": {"id": "\(projectID)", "name": "Web", "state": "wellFormed", "visibility": "private"}},
         "pullRequestId": \(id), "codeReviewId": \(id), "status": "\(status)", "createdBy": \(me),
         "creationDate": "2026-11-02T10:00:00.1234567Z", "title": "Add feature", "description": "Body",
         "sourceRefName": "refs/heads/feature", "targetRefName": "refs/heads/main", "mergeStatus": "\(mergeStatus)",
         \(failure.map { #""mergeFailureMessage": "\#($0)", "# } ?? "")"isDraft": false,
         "lastMergeSourceCommit": {"commitId": "\(hash)"},
         "lastMergeTargetCommit": {"commitId": "0011223344aa0011223344aa0011223344aa0011"},
         "reviewers": \(reviewers ?? """
             [{"reviewerUrl": "https://dev.azure.com/fabrikam/_apis/git/repositories/\(repositoryID)/pullRequests/\(id)/reviewers/\(meID)",
               "vote": 0, "hasDeclined": false, "isRequired": false, "displayName": "Jane Doe", "id": "\(meID)"}]
             """),
         "url": "https://dev.azure.com/fabrikam/\(projectID)/_apis/git/repositories/\(repositoryID)/pullRequests/\(id)",
         "supportsIterations": true}
        """
    }

    static func list(_ values: [String]) -> String {
        #"{"count": \#(values.count), "value": [\#(values.joined(separator: ", "))]}"#
    }

    static let empty = list([])

    /// An Azure DevOps error body.
    static func error(_ message: String, typeName: String = "Microsoft.TeamFoundation.Git.Server.GitPullRequestCannotBeActivated") -> String {
        """
        {"$id": "1", "innerException": null, "message": "\(message)", "typeName": "\(typeName), Microsoft.TeamFoundation.Git.Server",
         "typeKey": "GitPullRequestCannotBeActivated", "errorCode": 0, "eventId": 3000}
        """
    }

    static let notFound = StubServer.Reply(status: 404, body: error("TF401019: not found.", typeName: "Microsoft.TeamFoundation.Git.Server.GitRepositoryNotFoundException"))

    /// Counts a provider's forced refreshes, or a stub's reads.
    final class Counter: Sendable {
        let count = Mutex(0)

        /// The count before this call.
        func next() -> Int {
            count.withLock { count in
                defer { count += 1 }
                return count
            }
        }
    }

    /// A provider that already refreshed: it hands out `token` from the first request.
    static func refreshed() -> Counter {
        let refreshes = Counter()
        refreshes.count.withLock { $0 = 1 }
        return refreshes
    }

    /// A client whose provider hands out `staleToken` until it is told that token was refused, then `token`; merges
    /// poll without waiting.
    static func client(_ stub: StubServer, refreshes: Counter = refreshed()) -> AzureDevOpsClient {
        var client = AzureDevOpsClient(session: stub.session) { rejected in
            refreshes.count.withLock { count in
                if let rejected { count += rejected == Self.staleToken ? 1 : 1000 }
                return count > 0 ? Self.token : Self.staleToken
            }
        }
        client.mergePollDelay = .zero
        client.mergePolls = 3
        return client
    }

    static func json(_ request: URLRequest) -> [String: Any] {
        request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    static func query(_ request: URLRequest, _ name: String) -> [String] {
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.filter { $0.name == name }.compactMap(\.value) ?? []
    }

    static func route(_ request: URLRequest) -> String {
        (request.httpMethod ?? "") + " " + (request.url?.path() ?? "")
    }

    // MARK: - Token

    @Test("the token goes only in the Authorization header of https requests to dev.azure.com/<org>/ or app.vssps.visualstudio.com/_apis/, each with api-version=7.1 once (7.1-preview.1 only on policy evaluations); a 401 asks for it again once")
    func tokenOnlyToAllowedOrigins() async throws {
        let stub = StubServer { request in
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)" else {
                return .init(status: 401, body: "")
            }
            switch request.url?.path() ?? "" {
            case Self.profilePath: return .init(body: Self.profile)
            case Self.prPath: return .init(body: Self.pullRequest())
            case Self.policyPath: return .init(body: Self.empty)
            case Self.repoPath + "/commits/\(Self.head)/statuses":
                return .init(body: Self.list([#"{"id": 1, "state": "succeeded", "context": {"name": "build", "genre": "ci"}}"#]))
            case Self.prPath + "/statuses":
                return .init(body: Self.list([#"{"id": 2, "state": "pending", "context": {"name": "deploy", "genre": "cd"}}"#]))
            case "/fabrikam/Web/_apis/policy/evaluations":
                return .init(body: Self.list([
                    #"{"evaluationId": "e1", "status": "approved", "configuration": {"isEnabled": true, "isBlocking": true, "type": {"displayName": "Minimum number of reviewers"}}}"#,
                ]))
            case Self.prPath + "/commits":
                return .init(body: Self.list([#"{"commitId": "\#(Self.head)", "comment": "Add feature", "author": {"name": "Jane Doe", "email": "jane@example.com", "date": "2026-11-02T10:00:00Z"}}"#]))
            default: return Self.notFound
            }
        }
        let refreshes = Counter()
        let client = Self.client(stub, refreshes: refreshes)

        let user = try await client.currentUser()
        #expect(user.login == "jane@example.com" && user.reviewerID == Self.meID)
        #expect(try await client.pullRequest(7, in: Self.repo).head.sha == Self.head)
        let runs = try await client.checkRuns(for: Self.head, in: Self.repo)
        #expect(runs.map(\.name) == ["ci/build", "cd/deploy", "Minimum number of reviewers"])
        #expect(try await client.pullRequestCommits(7, in: Self.repo).map(\.sha) == [Self.head])

        #expect(refreshes.count.withLock { $0 } == 1)
        let requests = stub.requests
        #expect(requests.map(Self.route) == [
            "GET " + Self.profilePath, "GET " + Self.profilePath, "GET " + Self.prPath, "GET " + Self.policyPath,
            "GET " + Self.repoPath + "/commits/\(Self.head)/statuses", "GET " + Self.prPath + "/statuses",
            "GET /fabrikam/Web/_apis/policy/evaluations", "GET " + Self.prPath + "/commits",
        ])
        let firstIsStale = requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.staleToken)"
        #expect(firstIsStale)
        for request in requests.dropFirst() {
            let carriesFresh = request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)"
            #expect(carriesFresh)
        }
        for request in requests {
            let url = try #require(request.url)
            let path = url.path()
            let onAPI = url.absoluteString.hasPrefix(Self.api + "/fabrikam/")
            let onProfile = url.absoluteString.hasPrefix(Self.profileHost + "/_apis/")
            #expect(url.scheme == "https" && (onAPI || onProfile), "\(url)")
            let version = path.hasSuffix("/_apis/policy/evaluations") ? "7.1-preview.1" : "7.1"
            #expect(Self.query(request, "api-version") == [version], "\(url)")
            #expect(!url.absoluteString.contains(Self.token) && !url.absoluteString.contains(Self.staleToken))
        }
        #expect(Self.query(requests[6], "artifactId") == ["vstfs:///CodeReview/CodeReviewId/\(Self.projectID)/7"])
        #expect(!String(describing: client).contains(Self.token))
        #expect(!String(reflecting: client).contains(Self.token))
    }

    @Test("a redirect is followed with the token only on https://dev.azure.com under the request's own organization", arguments: [
        ("https://dev.azure.com/fabrikam/Web/_apis/git/repositories/app/pullrequests/8?api-version=7.1", true),
        ("https://dev.azure.com/otherorg/Web/_apis/git/repositories/app/pullrequests/8?api-version=7.1", false),
        ("https://dev.azure.com/fabrikam/%2E%2E/otherorg/Web/_apis/git/repositories/app/pullrequests/8", false),
        ("https://evil.example/fabrikam/Web/_apis/git/repositories/app/pullrequests/8?api-version=7.1", false),
        ("http://dev.azure.com/fabrikam/Web/_apis/git/repositories/app/pullrequests/8?api-version=7.1", false),
        ("https://app.vssps.visualstudio.com/_apis/profile/profiles/me?api-version=7.1", false),
    ])
    func redirects(target: String, isFollowed: Bool) async throws {
        let stub = StubServer { request in
            switch request.url?.path() ?? "" {
            case Self.prPath: .init(status: 302, headers: ["Location": target], body: "", redirect: URL(string: target))
            case Self.policyPath: .init(body: Self.empty)
            default: .init(body: Self.pullRequest(id: 8))
            }
        }
        let client = Self.client(stub)

        if isFollowed {
            #expect(try await client.pullRequest(7, in: Self.repo).number == 8, "positive control: the stub redirects")
            #expect(stub.requests.map(Self.route) == ["GET " + Self.prPath, "GET " + Self.repoPath + "/pullrequests/8", "GET " + Self.policyPath])
            let carriesToken = stub.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)"
            #expect(carriesToken, "URLSession drops the header on a redirect: the guard puts it back on one it follows")
        } else {
            await #expect(throws: HostingError.self) { try await client.pullRequest(7, in: Self.repo) }
            #expect(stub.requests.map { $0.url?.absoluteString } == [Self.api + Self.prPath + "?api-version=7.1"],
                    "nothing reaches the target")
        }
    }

    @Test("a profile request's redirect out of /_apis on its own origin is not followed")
    func profileRedirectStaysUnderApis() async throws {
        let target = "https://app.vssps.visualstudio.com/other/profile/me"
        let stub = StubServer { request in
            request.url?.path() == Self.profilePath
                ? .init(status: 302, headers: ["Location": target], body: "", redirect: URL(string: target))
                : .init(body: Self.profile)
        }
        await #expect(throws: HostingError.self) { try await Self.client(stub).currentUser() }
        #expect(stub.requests.map { $0.url?.path() } == [Self.profilePath])
    }

    @Test("a continuation token holding a URL or junk only fills the continuationToken query parameter of the same URL (api-version still once), and a repeated token stops paging")
    func continuationKeepsTheOrigin() async throws {
        let foreign = "https://evil.example/fabrikam/Web/_apis/git/repositories/app/pullrequests/7/commits?api-version=7.1"
        let junk = "x&api-version=1.0#f"
        @Sendable func commit(_ n: Int) -> String {
            #"{"commitId": "\#(String(repeating: String(n), count: 40))", "comment": "c\#(n)"}"#
        }
        let stub = StubServer { request in
            switch Self.query(request, "continuationToken") {
            case []: .init(headers: ["x-ms-continuationtoken": foreign], body: Self.list([commit(1)]))
            case [foreign]: .init(headers: ["x-ms-continuationtoken": junk], body: Self.list([commit(2)]))
            default: .init(headers: ["x-ms-continuationtoken": junk], body: Self.list([commit(3)]))
            }
        }
        let commits = try await Self.client(stub).pullRequestCommits(7, in: Self.repo)

        #expect(commits.map(\.commit.message) == ["c3", "c2", "c1"], "oldest first")
        let requests = stub.requests
        #expect(requests.map { Self.query($0, "continuationToken") } == [[], [foreign], [junk]])
        for request in requests {
            #expect(request.url?.scheme == "https" && request.url?.host() == "dev.azure.com")
            #expect(request.url?.path() == Self.prPath + "/commits")
            #expect(Self.query(request, "api-version") == ["7.1"])
            #expect(Self.query(request, "$top") == ["100"])
        }
    }

    // MARK: - Merge

    /// Pull request #7 reads `first` once, then each of `polls` in turn (the last repeats); its PATCH answers `patch`
    /// and no merge strategy policy applies.
    static func mergeServer(first: String = pullRequest(), patch: StubServer.Reply, polls: [String] = []) -> StubServer {
        let reads = Counter()
        return StubServer { request in
            switch Self.route(request) {
            case "GET " + Self.prPath:
                let n = reads.next()
                return .init(body: n == 0 || polls.isEmpty ? first : polls[min(n - 1, polls.count - 1)])
            case "PATCH " + Self.prPath: return patch
            case "GET " + Self.policyPath: return .init(body: Self.empty)
            default: return Self.notFound
            }
        }
    }

    @Test("a merge PATCHes pullrequests/<n>?api-version=7.1 with status completed, the full head just read and the strategy, then reads the pull request until it is completed")
    func mergeSendsHeadAndPolls() async throws {
        let stub = Self.mergeServer(
            patch: .init(body: Self.pullRequest(mergeStatus: "queued")),
            polls: [Self.pullRequest(mergeStatus: "queued"), Self.pullRequest(status: "completed")])
        try await Self.client(stub).merge(7, in: Self.repo, method: .merge, sha: String(Self.head.prefix(12)))

        let requests = stub.requests
        #expect(requests.map(Self.route) == [
            "GET " + Self.prPath, "GET " + Self.policyPath, "PATCH " + Self.prPath, "GET " + Self.prPath,
            "GET " + Self.prPath,
        ])
        #expect(requests[2].url?.absoluteString == Self.api + Self.prPath + "?api-version=7.1")
        let expected: NSDictionary = [
            "status": "completed", "lastMergeSourceCommit": ["commitId": Self.head],
            "completionOptions": ["mergeStrategy": "noFastForward"],
        ]
        #expect(NSDictionary(dictionary: Self.json(requests[2])) == expected)
    }

    @Test("a merge is refused as headChanged when the head moved, with no PATCH sent")
    func mergeRefusedWhenHeadMoved() async throws {
        let stub = Self.mergeServer(patch: .init(body: Self.pullRequest(status: "completed")))
        await #expect(throws: HostingError.headChanged) {
            try await Self.client(stub).merge(7, in: Self.repo, method: .merge, sha: "fff000fff000")
        }
        #expect(stub.requests.map(Self.route) == ["GET " + Self.prPath], "no PATCH sent")
    }

    @Test("a stale mergeStatus failure on the PATCH answer (an earlier attempt's) is not judged: a completed read after it is a success")
    func staleFailureOnThePatchAnswer() async throws {
        let stub = Self.mergeServer(
            patch: .init(body: Self.pullRequest(mergeStatus: "failure", failure: "An earlier attempt failed.")),
            polls: [Self.pullRequest(status: "completed")])
        try await Self.client(stub).merge(7, in: Self.repo, method: .merge, sha: Self.head)
        #expect(stub.requests.map(\.httpMethod) == ["GET", "GET", "PATCH", "GET"])
    }

    @Test("a read after the PATCH with conflicts is validationFailed with its mergeFailureMessage")
    func pollWithConflicts() async throws {
        let message = "Merge conflicts in src/app.swift."
        let stub = Self.mergeServer(
            patch: .init(body: Self.pullRequest(mergeStatus: "queued")),
            polls: [Self.pullRequest(mergeStatus: "conflicts", failure: message)])
        await #expect(throws: HostingError.validationFailed(message: message)) {
            try await Self.client(stub).merge(7, in: Self.repo, method: .merge, sha: Self.head)
        }
        #expect(stub.requests.map(\.httpMethod) == ["GET", "GET", "PATCH", "GET"])
    }

    // MARK: - Threads

    static func comment(_ id: Int, parent: Int = 0, text: String = "Text", type: String = "text", minute: Int, deleted: Bool = false) -> String {
        """
        {"id": \(id), "parentCommentId": \(parent), "author": \(me), "content": "\(text)",
         "publishedDate": "2026-11-02T10:\(String(format: "%02d", minute)):00.1234567Z",
         "lastUpdatedDate": "2026-11-02T10:\(String(format: "%02d", minute)):00.1234567Z",
         "lastContentUpdatedDate": "2026-11-02T10:\(String(format: "%02d", minute)):00.1234567Z",
         "commentType": "\(type)"\(deleted ? #", "isDeleted": true"# : "")}
        """
    }

    static func thread(
        _ id: Int, status: String? = "active", context: String? = nil, comments: [String], properties: String = "{}",
        deleted: Bool = false
    ) -> String {
        """
        {"id": \(id), "publishedDate": "2026-11-02T10:00:00.1234567Z", "lastUpdatedDate": "2026-11-02T10:00:00.1234567Z",
         "comments": [\(comments.joined(separator: ", "))], \(status.map { #""status": "\#($0)", "# } ?? "")
         \(context.map { #""threadContext": \#($0), "# } ?? "")"properties": \(properties), "identities": null,
         "isDeleted": \(deleted)}
        """
    }

    static func context(_ path: String, side: String, start: Int, end: Int) -> String {
        """
        {"filePath": "\(path)", "\(side)FileStart": {"line": \(start), "offset": 1}, "\(side)FileEnd": {"line": \(end), "offset": 5}}
        """
    }

    /// A PR-level thread 1 (root, reply, reply of the reply); file threads 2 (right side, lines 10-12, fixed, with a
    /// deleted reply), 3 (left side, line 4, wontFix), 4 closed, 5 byDesign, 6 pending (with a comment id of 1 << 20)
    /// and 8 active; a system thread 9 (property and comment type), a thread 10 with a system comment only, and a
    /// deleted thread 11.
    static let threads: String = {
        let file = context("/src/app.swift", side: "right", start: 2, end: 2)
        return list([
            thread(1, comments: [comment(1, minute: 1), comment(2, parent: 1, minute: 2), comment(3, parent: 2, minute: 3)]),
            thread(2, status: "fixed", context: context("/src/app.swift", side: "right", start: 10, end: 12), comments: [
                comment(1, text: "Rename this", minute: 4), comment(2, parent: 1, text: "Done", minute: 5),
                comment(3, parent: 1, text: "Gone", minute: 6, deleted: true),
            ]),
            thread(3, status: "wontFix", context: context("/src/old.swift", side: "left", start: 4, end: 4), comments: [comment(1, minute: 7)]),
            thread(4, status: "closed", context: file, comments: [comment(1, minute: 8)]),
            thread(5, status: "byDesign", context: file, comments: [comment(1, minute: 9)]),
            thread(6, status: "pending", context: file, comments: [comment(1, minute: 10), comment(1 << 20, parent: 1, minute: 11)]),
            thread(8, status: "active", context: file, comments: [comment(1, minute: 12)]),
            thread(9, status: nil, comments: [comment(1, text: "Jane Doe voted 10", type: "system", minute: 13)],
                   properties: #"{"CodeReviewThreadType": {"$type": "System.String", "$value": "VoteUpdate"}, "CodeReviewVoteResult": {"$type": "System.String", "$value": "10"}}"#),
            thread(10, status: nil, comments: [comment(1, text: "Jane Doe pushed", type: "system", minute: 14)]),
            thread(11, comments: [comment(1, text: "Deleted thread", minute: 15)], deleted: true),
        ])
    }()

    @Test("threads map into combined ids (thread << 20 | comment): the PR-level thread into general comments with their direct parents, file threads on either side into review comments, statuses into resolved flags; system, deleted and out-of-range entries are skipped")
    func threadsIntoCombinedIDs() async throws {
        let stub = StubServer { request in
            request.url?.path() == Self.prPath + "/threads" ? .init(body: Self.threads) : Self.notFound
        }
        let client = Self.client(stub)
        func id(_ thread: Int, _ comment: Int) -> Int { thread << 20 | comment }

        let general = try await client.comments(on: .pullRequest(7), in: Self.repo)
        #expect(general.map(\.id) == [id(1, 1), id(1, 2), id(1, 3)])
        #expect(general.map(\.parentID) == [nil, id(1, 1), id(1, 2)])
        #expect(general.map(\.hostKey) == ["1", "1", "1"])
        #expect(general[0].resolvable == true && general[0].resolved == false)

        let inline = try await client.reviewComments(of: 7, in: Self.repo)
        #expect(inline.map(\.id) == [id(2, 1), id(2, 2), id(3, 1), id(4, 1), id(5, 1), id(6, 1), id(8, 1)])
        let root = inline[0], reply = inline[1], left = inline[2]
        #expect(root.path == "src/app.swift" && root.side == "RIGHT" && root.line == 12 && root.startLine == 10)
        #expect(root.inReplyToID == nil && reply.inReplyToID == id(2, 1) && reply.body == "Done")
        #expect(left.path == "src/old.swift" && left.side == "LEFT" && left.line == 4 && left.startLine == nil)

        let states = try await client.reviewThreadStates(of: 7, in: Self.repo)
        #expect(states.map(\.id) == [2, 3, 4, 5, 6, 8].map { "fabrikam/Web/app#7/\($0)" })
        #expect(states.map(\.isResolved) == [true, true, true, true, false, false])
        #expect(states.map(\.rootCommentID) == [id(2, 1), id(3, 1), id(4, 1), id(5, 1), id(6, 1), id(8, 1)])
    }

    // MARK: - Small reads and writes

    @Test("currentUser reads profiles/me: login the email address, reviewerID the profile's GUID")
    func currentUserFromProfile() async throws {
        let stub = StubServer { _ in .init(body: Self.profile) }
        let user = try await Self.client(stub).currentUser()
        #expect(user.login == "jane@example.com" && user.name == "Jane Doe" && user.reviewerID == Self.meID)
        #expect(stub.requests.map { $0.url?.absoluteString } == [Self.profileHost + Self.profilePath + "?api-version=7.1"])
    }

    @Test("the clone list reads the member's organizations, each one's repositories, skips a disabled repository and an organization it cannot read, sorted by full name")
    func cloneList() async throws {
        let stub = StubServer { request in
            switch request.url?.path() ?? "" {
            case Self.profilePath: return .init(body: Self.profile)
            case "/_apis/accounts":
                return .init(body: Self.list([
                    #"{"accountId": "1", "accountUri": "https://fabrikam.vssps.visualstudio.com/", "accountName": "fabrikam"}"#,
                    #"{"accountId": "2", "accountUri": "https://contoso.vssps.visualstudio.com/", "accountName": "contoso"}"#,
                ]))
            case "/fabrikam/_apis/git/repositories":
                func repository(_ name: String, disabled: Bool = false) -> String {
                    """
                    {"id": "id-\(name)", "name": "\(name)", "project": {"id": "\(Self.projectID)", "name": "Web", "visibility": "private"},
                     "remoteUrl": "https://fabrikam@dev.azure.com/fabrikam/Web/_git/\(name)", "defaultBranch": "refs/heads/main",
                     "isDisabled": \(disabled)}
                    """
                }
                return .init(body: Self.list([repository("docs"), repository("old", disabled: true), repository("app")]))
            default: return .init(status: 403, body: Self.error("TF400813: not authorized."))
            }
        }
        let repos = try await Self.client(stub).userRepositories()

        #expect(repos.map(\.fullName) == ["fabrikam/Web/app", "fabrikam/Web/docs"])
        #expect(repos[0].cloneURL == "https://fabrikam@dev.azure.com/fabrikam/Web/_git/app" && repos[0].isPrivate)
        let requests = stub.requests
        #expect(requests.map { $0.url?.path() } == [
            Self.profilePath, "/_apis/accounts", "/fabrikam/_apis/git/repositories", "/contoso/_apis/git/repositories",
        ])
        #expect(Self.query(requests[1], "memberId") == [Self.meID])
    }

    /// Answers the profile, the vote with `vote`, and a new thread.
    static func reviewServer(vote: StubServer.Reply) -> StubServer {
        StubServer { request in
            switch Self.route(request) {
            case "GET " + Self.profilePath: .init(body: Self.profile)
            case "PUT " + Self.prPath + "/reviewers/\(Self.meID)": vote
            case "POST " + Self.prPath + "/threads":
                .init(body: Self.thread(42, comments: [Self.comment(1, text: "Looks good", minute: 1)]))
            default: Self.notFound
            }
        }
    }

    @Test("approving PUTs a vote of 10 for the token's user, then posts the body as a new thread")
    func approveVotesThenPosts() async throws {
        let stub = Self.reviewServer(vote: .init(body: #"{"vote": 10, "id": "\#(Self.meID)", "displayName": "Jane Doe"}"#))
        let review = try await Self.client(stub).review(7, in: Self.repo, event: .approve, body: "Looks good")

        #expect(review.state == "APPROVED")
        let requests = stub.requests
        #expect(requests.map(Self.route) == [
            "GET " + Self.profilePath, "PUT " + Self.prPath + "/reviewers/\(Self.meID)", "POST " + Self.prPath + "/threads",
        ])
        #expect(NSDictionary(dictionary: Self.json(requests[1])) == ["vote": 10, "id": Self.meID])
        let comments = Self.json(requests[2])["comments"] as? [[String: Any]]
        #expect(comments?.first?["content"] as? String == "Looks good")
    }

    @Test("a refused vote (400) is validationFailed with Azure's message, and the body is never posted")
    func refusedVotePostsNothing() async throws {
        let message = "TF401181: The pull request cannot be edited due to its state."
        let stub = Self.reviewServer(vote: .init(status: 400, body: Self.error(message)))
        await #expect(throws: HostingError.validationFailed(message: message)) {
            try await Self.client(stub).review(7, in: Self.repo, event: .approve, body: "Looks good")
        }
        #expect(!stub.requests.contains { $0.httpMethod == "POST" })
    }

    @Test("setReviewThread PATCHes the repository, pull request and thread its state's id names; an id that is not such a key, or names an invalid repository path, is refused unsent; a reply takes that key or the plain thread id as its hostKey, never another pull request's")
    func setReviewThreadNeedsAKnownThread() async throws {
        let stub = StubServer { request in
            switch Self.route(request) {
            case "PATCH " + Self.prPath + "/threads/2", "PATCH " + Self.repoPath + "/pullrequests/8/threads/2":
                .init(body: Self.thread(2, status: "fixed", comments: [Self.comment(1, minute: 1)]))
            case "POST " + Self.prPath + "/threads/2/comments": .init(body: Self.comment(2, parent: 1, minute: 2))
            default: Self.notFound
            }
        }
        let client = Self.client(stub)
        func state(_ id: String) -> HostedReviewThreadState {
            HostedReviewThreadState(id: id, isResolved: false, isOutdated: false, viewerCanResolve: true, viewerCanUnresolve: true)
        }

        for id in ["2", "", "fabrikam/Web#7/2", "fabrikam/Web/app/x#7/2", "fabrikam/Web/app#0/2", "fabrikam/Web/app#7/x",
                   "fabrikam/Web/app#7/2/3", "fabrikam/Web/app#7#2", "fabrikam//app#7/2", "bad org/Web/app#7/2",
                   "fabrikam/%2E%2E/app#7/2", "fabrikam/Web/app#7/x/2", "fabrikam/%ZZ/Web/app#7/2"] {
            await #expect(throws: HostingError.self, "\(id)") { try await client.setReviewThread(state(id), resolved: true) }
        }
        #expect(stub.requests.isEmpty, "refused unsent")

        #expect(try await client.setReviewThread(state("fabrikam/Web/app#7/2"), resolved: true))
        let patch = try #require(stub.requests.last)
        #expect(Self.route(patch) == "PATCH " + Self.prPath + "/threads/2" && Self.query(patch, "api-version") == ["7.1"])
        #expect(NSDictionary(dictionary: Self.json(patch)) == ["status": "fixed"])
        _ = try await client.setReviewThread(state("fabrikam/Web/app#8/2"), resolved: false)
        #expect(Self.route(stub.requests.last!) == "PATCH " + Self.repoPath + "/pullrequests/8/threads/2")
        #expect(NSDictionary(dictionary: Self.json(stub.requests.last!)) == ["status": "active"])

        let root = 2 << 20 | 1
        for key in ["fabrikam/Web/app#7/2", "2"] {
            let reply = try await client.reply(to: HostedThreadRef(rootCommentID: root, hostKey: key), on: 7, in: Self.repo, body: "Done")
            #expect(reply.id == 2 << 20 | 2 && reply.inReplyToID == root)
        }
        let sent = stub.requests.count
        for key in ["fabrikam/Web/app#8/2", "fabrikam/Web/app#7/3", "fabrikam/Web/other#7/2", "3"] {
            await #expect(throws: HostingError.self, "\(key)") {
                try await client.reply(to: HostedThreadRef(rootCommentID: root, hostKey: key), on: 7, in: Self.repo, body: "Done")
            }
        }
        #expect(stub.requests.count == sent, "refused unsent")
    }

    @Test("a blocking merge strategy policy on the target branch narrows allowedMergeMethods, and a merge with a method it does not allow is refused unsent")
    func mergeStrategyPolicy() async throws {
        @Sendable func policy(enabled: Bool = true, blocking: Bool = true, ref: String, squash: Bool, noFastForward: Bool, rebase: Bool) -> String {
            """
            {"isEnabled": \(enabled), "isBlocking": \(blocking), "isDeleted": false, "id": 3, "revision": 1,
             "type": {"id": "fa4e907d-c16b-4a4c-9dfa-4916e5d171ab", "displayName": "Require a merge strategy"},
             "settings": {"allowSquash": \(squash), "allowNoFastForward": \(noFastForward), "allowRebase": \(rebase),
                          "allowRebaseMerge": false,
                          "scope": [{"refName": "\(ref)", "matchKind": "Exact", "repositoryId": "\(Self.repositoryID)"}]}}
            """
        }
        let stub = StubServer { request in
            switch Self.route(request) {
            case "GET " + Self.prPath: .init(body: Self.pullRequest())
            case "GET " + Self.policyPath:
                .init(body: Self.list([
                    policy(ref: "refs/heads/main", squash: true, noFastForward: false, rebase: false),
                    policy(blocking: false, ref: "refs/heads/main", squash: true, noFastForward: true, rebase: true),
                    policy(ref: "refs/heads/release", squash: false, noFastForward: false, rebase: true),
                ]))
            default: Self.notFound
            }
        }
        let client = Self.client(stub)

        #expect(try await client.pullRequest(7, in: Self.repo).allowedMergeMethods == [.squash])
        #expect(Self.query(stub.requests[1], "policyType") == ["fa4e907d-c16b-4a4c-9dfa-4916e5d171ab"])
        await #expect(throws: HostingError.self) {
            try await client.merge(7, in: Self.repo, method: .merge, sha: Self.head)
        }
        #expect(!stub.requests.contains { $0.httpMethod == "PATCH" }, "refused unsent")
    }

    @Test("createPullRequest refuses a description over 4000 characters unsent")
    func createPullRequestRefusesLongDescription() async throws {
        let stub = StubServer { _ in Self.notFound }
        let pull = NewPullRequest(title: "Add feature", head: "feature", base: "main", body: String(repeating: "a", count: 4001))
        await #expect(throws: HostingError.self) { try await Self.client(stub).createPullRequest(pull, in: Self.repo) }
        #expect(stub.requests.isEmpty)
    }

    // MARK: - Comment interactions

    @Test("comment writes split the combined id into thread and comment: a general reply, resolving, editing, deleting, liking and unliking each go to their own URL and body; a new inline thread names its side's lines, the file's change tracking id and the last iteration; a refused delete is Azure's message; bad ids, an issue, a review comment's ref where a general one is needed, another reaction kind and a range across sides are refused unsent")
    func commentWrites() async throws {
        let deleteRefused = "TF401181: The comment cannot be deleted because it has replies."
        let stub = StubServer { request in
            let threads = Self.prPath + "/threads"
            switch Self.route(request) {
            case "POST " + threads + "/1/comments": return .init(body: Self.comment(4, parent: 2, text: "Thanks", minute: 4))
            case "PATCH " + threads + "/1": return .init(body: Self.thread(1, status: "fixed", comments: [Self.comment(1, minute: 1)]))
            case "PATCH " + Self.prPath: return .init(body: Self.pullRequest())
            case "PATCH " + threads + "/1/comments/2": return .init(body: Self.comment(2, parent: 1, text: "Edited", minute: 2))
            case "DELETE " + threads + "/1/comments/2", "POST " + threads + "/1/comments/2/likes",
                 "DELETE " + threads + "/1/comments/2/likes":
                return .init(body: "")
            case "DELETE " + threads + "/1/comments/3":
                return .init(status: 400, body: Self.error(deleteRefused, typeName: "Microsoft.TeamFoundation.Git.Server.GitPullRequestCommentCannotBeDeleted"))
            case "GET " + Self.prPath + "/iterations": return .init(body: Self.list([#"{"id": 1}"#, #"{"id": 3}"#, #"{"id": 2}"#]))
            case "GET " + Self.prPath + "/iterations/3/changes":
                return .init(body: """
                    {"changeEntries": [
                      {"changeTrackingId": 5, "changeId": 1, "item": {"objectId": "a1", "path": "/src/app.swift"}, "changeType": "edit"},
                      {"changeTrackingId": 6, "changeId": 2, "item": {"objectId": "a2", "path": "/src/old.swift"}, "changeType": "edit"}]}
                    """)
            case "POST " + threads:
                let sent = Self.json(request)
                let context = try! JSONSerialization.data(withJSONObject: sent["threadContext"] ?? [:])
                return .init(body: Self.thread(12, context: String(decoding: context, as: UTF8.self), comments: [Self.comment(1, text: "Nit", minute: 5)]))
            default: return Self.notFound
            }
        }
        let client = Self.client(stub)
        let id = 1 << 20 | 2
        let general = HostedCommentRef(kind: .general, id: id, hostKey: "1")
        let review = HostedCommentRef(kind: .review, id: id, hostKey: "1")
        let item = HostedItem.pullRequest(7)
        let newSide = HostedInlinePosition(path: "src/app.swift", oldLine: nil, newLine: 12, lineKind: .added, startNewLine: 10, headSHA: Self.head)
        let oldSide = HostedInlinePosition(path: "src/old.swift", oldLine: 4, newLine: 6, lineKind: .removed, headSHA: Self.head)
        let threads = Self.prPath + "/threads"
        let inline: (String, Int, Int, Int) -> NSDictionary = { side, start, end, tracking in
            [
                "comments": [["parentCommentId": 0, "content": "Nit", "commentType": 1]], "status": 1,
                "threadContext": ["filePath": "/src/\(side == "right" ? "app" : "old").swift",
                                  side + "FileStart": ["line": start, "offset": 1], side + "FileEnd": ["line": end, "offset": 1]],
                "pullRequestThreadContext": ["changeTrackingId": tracking,
                                             "iterationContext": ["firstComparingIteration": 1, "secondComparingIteration": 3]],
            ]
        }

        /// Each write, the request it must send last (nil: refused, nothing sent) and its JSON body (nil: none), and
        /// the error it must throw (nil: none).
        let writes: [(name: String, run: (AzureDevOpsClient) async throws -> Void, route: String?, body: NSDictionary?, error: HostingError?)] = [
            ("general reply", { c in
                let reply = try await c.reply(toGeneral: general, on: item, in: Self.repo, body: "Thanks")
                #expect(reply.id == 1 << 20 | 4 && reply.parentID == id && reply.hostKey == "1" && reply.viewerCanEdit && reply.viewerCanDelete)
            }, "POST " + threads + "/1/comments", ["content": "Thanks", "parentCommentId": 2, "commentType": 1], nil),
            ("resolve", { c in
                let resolved = try await c.setGeneralThread(general, on: item, in: Self.repo, resolved: true)
                #expect(resolved)
            },
             "PATCH " + threads + "/1", ["status": "fixed"], nil),
            ("edit", { c in try await c.editComment(review, on: item, in: Self.repo, body: "Edited") },
             "PATCH " + threads + "/1/comments/2", ["content": "Edited"], nil),
            ("delete", { c in try await c.deleteComment(general, on: item, in: Self.repo) },
             "DELETE " + threads + "/1/comments/2", nil, nil),
            ("like", { c in try await c.addReaction("+1", to: general, on: item, in: Self.repo) },
             "POST " + threads + "/1/comments/2/likes", nil, nil),
            ("unlike", { c in try await c.removeReaction("+1", from: review, on: item, in: Self.repo) },
             "DELETE " + threads + "/1/comments/2/likes", nil, nil),
            ("inline, new side", { c in
                let root = try await c.createInlineComment(at: newSide, on: 7, in: Self.repo, body: "Nit")
                #expect(root.id == 12 << 20 | 1 && root.path == "src/app.swift" && root.side == "RIGHT" && root.line == 12 && root.startLine == 10)
                #expect(root.viewerCanEdit && root.hostKey == "12")
            }, "POST " + threads, inline("right", 10, 12, 5), nil),
            ("inline, old side", { c in
                let root = try await c.createInlineComment(at: oldSide, on: 7, in: Self.repo, body: "Nit")
                #expect(root.path == "src/old.swift" && root.side == "LEFT" && root.line == 4 && root.startLine == nil)
            }, "POST " + threads, inline("left", 4, 4, 6), nil),
            ("description", { c in try await c.editDescription(of: item, in: Self.repo, body: "New") },
             "PATCH " + Self.prPath, ["description": "New"], nil),
            ("description over 4000 characters", { c in
                try await c.editDescription(of: item, in: Self.repo, body: String(repeating: "a", count: 4001))
            }, nil, nil, nil),
            ("delete refused", { c in try await c.deleteComment(HostedCommentRef(kind: .general, id: 1 << 20 | 3), on: item, in: Self.repo) },
             "DELETE " + threads + "/1/comments/3", nil, .validationFailed(message: deleteRefused)),
            ("no thread", { c in try await c.editComment(HostedCommentRef(kind: .general, id: 2), on: item, in: Self.repo, body: "x") }, nil, nil, nil),
            ("no comment", { c in try await c.deleteComment(HostedCommentRef(kind: .general, id: 1 << 20), on: item, in: Self.repo) }, nil, nil, nil),
            ("negative id", { c in try await c.addReaction("+1", to: HostedCommentRef(kind: .general, id: -id), on: item, in: Self.repo) }, nil, nil, nil),
            ("another thread's key", { c in
                try await c.editComment(HostedCommentRef(kind: .general, id: id, hostKey: "9"), on: item, in: Self.repo, body: "x")
            }, nil, nil, nil),
            ("issue", { c in try await c.addReaction("+1", to: general, on: .issue(7), in: Self.repo) }, nil, nil, nil),
            ("general reply to a review comment", { c in _ = try await c.reply(toGeneral: review, on: item, in: Self.repo, body: "x") }, nil, nil, nil),
            ("resolve a review comment's thread", { c in _ = try await c.setGeneralThread(review, on: item, in: Self.repo, resolved: true) }, nil, nil, nil),
            ("another reaction kind", { c in try await c.addReaction("heart", to: general, on: item, in: Self.repo) }, nil, nil, nil),
            ("range across sides", { c in
                let across = HostedInlinePosition(path: "src/app.swift", oldLine: nil, newLine: 12, lineKind: .added, startOldLine: 9, headSHA: Self.head)
                _ = try await c.createInlineComment(at: across, on: 7, in: Self.repo, body: "Nit")
            }, nil, nil, nil),
        ]
        for write in writes {
            let before = stub.requests.count
            if let route = write.route, write.error == nil {
                try await write.run(client)
                let last = try #require(stub.requests.last, "\(write.name)")
                #expect(Self.route(last) == route, "\(write.name)")
                #expect(Self.query(last, "api-version") == ["7.1"], "\(write.name)")
                if let body = write.body {
                    #expect(NSDictionary(dictionary: Self.json(last)) == body, "\(write.name)")
                } else {
                    #expect(last.httpBody == nil, "\(write.name)")
                }
            } else if let error = write.error {
                await #expect(throws: error, "\(write.name)") { try await write.run(client) }
                #expect(stub.requests.last.map(Self.route) == write.route, "\(write.name)")
            } else {
                await #expect(throws: HostingError.self, "\(write.name)") { try await write.run(client) }
                #expect(stub.requests.count == before, "\(write.name): refused unsent")
            }
        }
        #expect(client.capabilities.isSuperset(of: [.generalReplies, .resolveGeneralThreads, .editComments, .deleteComments, .reactions, .newInlineComments, .multiLineInlineComments]))
        #expect(!client.capabilities.contains(.itemReactions) && client.reactionKinds == ["+1"])
    }

    @Test("a PR-level thread's root, reply and reply of the reply chain their parent ids; the token's user may edit and delete only their own comments, and likes are one reaction with its count and whether the token's user is among them")
    func generalThreadNesting() async throws {
        let other = "0f6e5b3a-1c2d-4e5f-8a9b-0c1d2e3f4a5b"
        func comment(_ id: Int, parent: Int, author: String, likes: [String]) -> String {
            let liked = likes.map { Self.identity("User", id: $0) }.joined(separator: ", ")
            return """
                {"id": \(id), "parentCommentId": \(parent), "author": \(Self.identity(author == Self.meID ? "Jane Doe" : "John Roe", id: author)),
                 "content": "c\(id)", "publishedDate": "2026-11-02T10:0\(id):00.1234567Z", "commentType": "text",
                 "usersLiked": [\(liked)]}
                """
        }
        let threads = Self.list([Self.thread(1, comments: [
            comment(1, parent: 0, author: other, likes: [Self.meID.uppercased(), other]),
            comment(2, parent: 1, author: Self.meID, likes: [other]),
            comment(3, parent: 2, author: other, likes: []),
        ])])
        let stub = StubServer { request in
            switch request.url?.path() ?? "" {
            case Self.profilePath: .init(body: Self.profile)
            case Self.prPath + "/threads": .init(body: threads)
            default: Self.notFound
            }
        }
        let comments = try await Self.client(stub).comments(on: .pullRequest(7), in: Self.repo)
        func id(_ comment: Int) -> Int { 1 << 20 | comment }

        #expect(comments.map(\.id) == [id(1), id(2), id(3)])
        #expect(comments.map(\.parentID) == [nil, id(1), id(2)])
        #expect(comments.map(\.hostKey) == ["1", "1", "1"])
        #expect(comments[0].resolvable == true && comments[0].resolved == false)
        #expect(comments.map(\.viewerCanEdit) == [false, true, false])
        #expect(comments.map(\.viewerCanDelete) == [false, true, false])
        #expect(comments.map(\.reactions) == [
            [HostedReaction(kind: "+1", count: 2, viewerReacted: true)],
            [HostedReaction(kind: "+1", count: 1, viewerReacted: false)],
            [],
        ])
    }

    // MARK: - Page data

    /// A system comment by Azure's service accounts (a group), as the REST reference's sample has them.
    static func systemComment(_ text: String, minute: Int) -> String {
        """
        {"id": 1, "parentCommentId": 0, "author": {"id": "41113706-4320-4083-9150-925feb93fc22", "displayName": "[DefaultCollection]\\\\Project Collection Service Accounts", "isContainer": true},
         "content": "\(text)", "publishedDate": "2026-11-03T09:\(String(format: "%02d", minute)):00.74Z", "commentType": "system", "usersLiked": []}
        """
    }

    /// `properties` with a `CodeReviewThreadType` of `type` and `fields` (string values, a number as a number).
    static func properties(_ type: String, _ fields: [(String, Any)] = []) -> String {
        let pairs = [("CodeReviewThreadType", type as Any)] + fields
        return "{" + pairs.map { name, value in
            let json = value is Int ? "{\"$type\": \"System.Int32\", \"$value\": \(value)}"
                : "{\"$type\": \"System.String\", \"$value\": \"\(value)\"}"
            return "\"\(name)\": \(json)"
        }.joined(separator: ", ") + "}"
    }

    @Test("timelineEvents reads the system threads (votes of -5 and 10, from the property before the comment's words, else from those, a reviewer added and one who joined, a push with its commit count, a merge attempt and an unknown type in the comment's escaped words without the actor's name), actors from the properties (a GUID with or without dashes), never the service account group, then the created entry; user and deleted threads are left out")
    func timelineFromSystemThreads() async throws {
        let paulk = "b335b0d4578f4944b94ca45216eb1a1a", paulkGUID = "b335b0d4-578f-4944-b94c-a45216eb1a1a"
        let threads = Self.list([
            Self.thread(141, status: nil, comments: [Self.systemComment("The pull request is mergable and the target commit would be 39f52d2.", minute: 1)],
                        properties: Self.properties("MergeAttempt", [("CodeReviewMergeStatus", "Succeeded")])),
            Self.thread(142, status: nil, comments: [Self.systemComment("Normal Paulk added Johnnie McLeod as a reviewer", minute: 2)],
                        properties: Self.properties("ReviewersUpdate", [
                            ("CodeReviewReviewersUpdatedAddedDisplayName", "Johnnie McLeod"), ("CodeReviewReviewersUpdatedAddedTfId", "2428198325304a9caeb788d60d57acfd"),
                            ("CodeReviewReviewersUpdatedByDisplayname", "Normal Paulk"), ("CodeReviewReviewersUpdatedByTfId", paulk),
                            ("CodeReviewReviewersUpdatedNumAdded", 1), ("CodeReviewReviewersUpdatedNumRemoved", 0),
                        ])),
            Self.thread(143, status: nil, comments: [Self.systemComment("Jane Doe joined as a reviewer", minute: 3)],
                        properties: Self.properties("ReviewersUpdate", [
                            ("CodeReviewReviewersUpdatedAddedDisplayName", "Jane Doe"), ("CodeReviewReviewersUpdatedAddedTfId", Self.meID),
                            ("CodeReviewReviewersUpdatedByDisplayname", "Jane Doe"), ("CodeReviewReviewersUpdatedByTfId", Self.meID.replacingOccurrences(of: "-", with: "")),
                        ])),
            Self.thread(144, status: nil, comments: [Self.systemComment("Jane Doe voted 10", minute: 4)],
                        properties: Self.properties("VoteUpdate", [
                            ("CodeReviewVotedByDisplayName", "Jane Doe"), ("CodeReviewVotedByTfId", Self.meID), ("CodeReviewVoteResult", "-5"),
                        ])),
            Self.thread(145, status: nil, comments: [Self.systemComment("Normal Paulk voted 10", minute: 5)],
                        properties: Self.properties("VoteUpdate", [("CodeReviewVotedByDisplayName", "Normal Paulk"), ("CodeReviewVotedByTfId", paulkGUID)])),
            Self.thread(146, status: nil, comments: [Self.systemComment("The reference refs/heads/feature was updated.", minute: 6)],
                        properties: Self.properties("RefUpdate", [
                            ("CodeReviewRefNewCommitsCount", 2), ("CodeReviewRefUpdatedByDisplayName", "Jane Doe"), ("CodeReviewRefUpdatedByTfId", Self.meID),
                        ])),
            Self.thread(147, status: nil, comments: [Self.comment(1, text: "Jane Doe marked it <ready> & done", type: "system", minute: 7)],
                        properties: Self.properties("IsDraftUpdated")),
            Self.thread(148, comments: [Self.comment(1, text: "A user comment", minute: 8)],
                        properties: #"{"Microsoft.TeamFoundation.Discussion.SupportsMarkdown": {"$type": "System.Int32", "$value": 1}}"#),
            Self.thread(149, status: nil, comments: [Self.systemComment("Jane Doe voted 5", minute: 9)],
                        properties: Self.properties("VoteUpdate", [("CodeReviewVoteResult", "5")]), deleted: true),
        ])
        let stub = StubServer { request in
            switch request.url?.path() ?? "" {
            case Self.prPath: .init(body: Self.pullRequest())
            case Self.prPath + "/threads": .init(body: threads)
            default: Self.notFound
            }
        }
        let client = Self.client(stub)
        #expect(client.capabilities.isSuperset(of: [.timelineEvents, .mergeChecks]))
        let events = try await client.timelineEvents(of: .pullRequest(7), in: Self.repo)

        #expect(events.map(\.id) == ["thread-141", "thread-142", "thread-143", "thread-144", "thread-145", "thread-146", "thread-147", "created"])
        #expect(events.map(\.text) == [
            "The pull request is mergable and the target commit would be 39f52d2.", "added Johnnie McLeod as a reviewer",
            "joined as a reviewer", "is waiting for the author", "approved", "pushed 2 commits", "marked it <ready> & done",
            "created the pull request",
        ])
        #expect(events.map(\.action) == ["mergeattempt", "reviewer", "reviewer", "changes_requested", "approved", "commit", "isdraftupdated", "opened"])
        #expect(events[6].textHTML == "<p>marked it &lt;ready&gt; &amp; done</p>")
        #expect(events.map { $0.actor?.login } == [nil, "Normal Paulk", "Jane Doe", "Jane Doe", "Normal Paulk", "Jane Doe", "Jane Doe", "Jane Doe"])
        // The same user as the pull request's own `createdBy` (the created entry), whichever form the GUID came in.
        let jane = try #require(events[7].actor)
        #expect(events[2].actor == jane && events[3].actor == jane && events[5].actor == jane)
        #expect(events[1].actor?.id == events[4].actor?.id && events[1].actor?.reviewerID == paulkGUID)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(events[0].createdAt == iso.date(from: "2026-11-03T09:01:00.740Z"))
        #expect(events[7].createdAt.map { abs($0.timeIntervalSince(iso.date(from: "2026-11-02T10:00:00.123Z")!)) < 0.001 } == true)
    }

    @Test("the full thread status is kept next to the resolved flag: on general thread roots (not their replies) and on file thread states, wontFix, byDesign and pending alike")
    func rawThreadStatusKept() async throws {
        let file = Self.context("/src/app.swift", side: "right", start: 2, end: 2)
        let threads = Self.list([
            Self.thread(1, status: "wontFix", comments: [Self.comment(1, minute: 1)]),
            Self.thread(2, status: "byDesign", comments: [Self.comment(1, minute: 2)]),
            Self.thread(3, status: "pending", comments: [Self.comment(1, minute: 3), Self.comment(2, parent: 1, minute: 4)]),
            Self.thread(4, status: "wontFix", context: file, comments: [Self.comment(1, minute: 5)]),
            Self.thread(5, status: "byDesign", context: file, comments: [Self.comment(1, minute: 6)]),
            Self.thread(6, status: "pending", context: file, comments: [Self.comment(1, minute: 7)]),
        ])
        let stub = StubServer { request in
            request.url?.path() == Self.prPath + "/threads" ? .init(body: threads) : Self.notFound
        }
        let client = Self.client(stub)

        let general = try await client.comments(on: .pullRequest(7), in: Self.repo)
        #expect(general.map(\.threadStatus) == ["wontFix", "byDesign", "pending", nil])
        #expect(general.map(\.resolved) == [true, true, false, nil])
        let states = try await client.reviewThreadStates(of: 7, in: Self.repo)
        #expect(states.map(\.status) == ["wontFix", "byDesign", "pending"])
        #expect(states.map(\.isResolved) == [true, true, false])
    }

    @Test("each reviewer's raw vote (10, 5, 0, -5, -10) and required flag are kept next to the folded state; a reviewer without a vote is PENDING, a declined one is left out")
    func rawVotesKept() async throws {
        func reviewer(_ n: Int, vote: Int, required: Bool, declined: Bool = false) -> String {
            #"{"id": "00000000-0000-0000-0000-00000000000\#(n)", "displayName": "R\#(n)", "vote": \#(vote), "isRequired": \#(required), "hasDeclined": \#(declined)}"#
        }
        let reviewers = "[" + [
            reviewer(5, vote: -10, required: false), reviewer(1, vote: 10, required: true), reviewer(3, vote: 0, required: true),
            reviewer(2, vote: 5, required: false), reviewer(4, vote: -5, required: false), reviewer(6, vote: 0, required: false, declined: true),
        ].joined(separator: ", ") + "]"
        let stub = StubServer { request in
            request.url?.path() == Self.prPath ? .init(body: Self.pullRequest(reviewers: reviewers)) : Self.notFound
        }
        let reviews = try await Self.client(stub).reviews(of: 7, in: Self.repo)

        #expect(reviews.map { $0.user?.login } == ["R1", "R2", "R3", "R4", "R5"])
        #expect(reviews.map(\.vote) == [10, 5, 0, -5, -10])
        #expect(reviews.map(\.state) == ["APPROVED", "APPROVED", "PENDING", "CHANGES_REQUESTED", "CHANGES_REQUESTED"])
        #expect(reviews.map(\.isRequired) == [true, false, true, false, false])
        #expect(Set(reviews.map(\.id)).count == reviews.count)
    }

    @Test("merge checks are the enabled blocking policies' evaluations (passed, failed, pending), then Conflicts for a pull request with conflicts; an evaluation read that fails is no check")
    func mergeChecksFromPolicies() async throws {
        func evaluation(_ id: String, _ status: String, _ name: String, enabled: Bool = true, blocking: Bool = true) -> String {
            #"{"evaluationId": "\#(id)", "status": "\#(status)", "configuration": {"isEnabled": \#(enabled), "isBlocking": \#(blocking), "type": {"displayName": "\#(name)"}}}"#
        }
        let evaluations = Self.list([
            evaluation("e1", "approved", "Minimum number of reviewers"), evaluation("e2", "rejected", "Build"),
            evaluation("e3", "running", "Comment requirements"), evaluation("e4", "rejected", "Work item linking", blocking: false),
            evaluation("e5", "rejected", "Old policy", enabled: false),
        ])
        let stub = StubServer { request in
            switch request.url?.path() ?? "" {
            case Self.prPath: .init(body: Self.pullRequest(mergeStatus: "conflicts"))
            case "/fabrikam/Web/_apis/policy/evaluations": .init(body: evaluations)
            default: Self.notFound
            }
        }
        let checks = try await Self.client(stub).mergeChecks(of: 7, in: Self.repo)
        #expect(checks == [
            HostedMergeCheck(name: "Minimum number of reviewers", status: "PASSED", required: true, blocking: false),
            HostedMergeCheck(name: "Build", status: "FAILED", required: true, blocking: true),
            HostedMergeCheck(name: "Comment requirements", status: "PENDING", required: true, blocking: true),
            HostedMergeCheck(name: "Conflicts", status: "FAILED", required: true, blocking: true),
        ])
        #expect(Self.query(stub.requests[1], "api-version") == ["7.1-preview.1"])

        let failing = StubServer { request in
            switch request.url?.path() ?? "" {
            case Self.prPath: .init(body: Self.pullRequest())
            case "/fabrikam/Web/_apis/policy/evaluations": .init(status: 500, body: Self.error("TF500: broken."))
            default: Self.notFound
            }
        }
        #expect(try await Self.client(failing).mergeChecks(of: 7, in: Self.repo).isEmpty)
        #expect(failing.requests.map(Self.route) == ["GET " + Self.prPath, "GET /fabrikam/Web/_apis/policy/evaluations"])
    }
}
