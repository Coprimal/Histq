// Contract tests for the GitHub client and the device flow, served by a stub `URLProtocol` with inline JSON: no
// test reaches the network. They also guard the token: it only travels in the `Authorization` header to the API
// host, and no error or description shows it.
import Foundation
import HistqCore
import Synchronization
import Testing

struct GitHubClientTests {
    /// A made-up token; the tests look for it where it must never be.
    static let token = "ghp_HistqFakeToken0123456789"

    static func pullJSON(_ number: Int) -> String {
        """
        {"id": \(number), "number": \(number), "title": "PR \(number)", "state": "open", "draft": false,
         "html_url": "https://github.com/octo/hello/pull/\(number)",
         "user": {"id": 1, "login": "octo", "avatar_url": "https://avatars.example/u/1"},
         "head": {"label": "octo:feature", "ref": "feature", "sha": "aaaa"}, "base": {"ref": "main", "sha": "bbbb"},
         "body": "Hi", "body_html": "<p>Hi</p>", "created_at": "2026-11-01T10:00:00Z", "labels": []}
        """
    }

    // MARK: - Pagination

    @Test("a list follows Link rel=\"next\" with the token only in the Authorization header")
    func paginationFollowsNextLink() async throws {
        let stub = StubServer { request in
            let page2 = "https://api.github.com/repositories/1/pulls?state=open&per_page=100&page=2"
            if request.url?.query()?.contains("page=2") == true {
                return .init(body: "[\(Self.pullJSON(2))]")
            }
            return .init(
                headers: ["Link": "<\(page2)>; rel=\"next\", <\(page2)>; rel=\"last\""],
                body: "[\(Self.pullJSON(1))]")
        }
        let client = try GitHubClient(token: Self.token, session: stub.session)
        let repo = try #require(GitHubClient.repository(fromRemoteURL: "https://github.com/octo/hello.git"))

        let pulls = try await client.pullRequests(in: repo, state: .open)

        #expect(pulls.map(\.number) == [1, 2])
        #expect(pulls.first?.bodyHTML == "<p>Hi</p>")
        let requests = stub.requests
        #expect(requests.count == 2)
        #expect(requests.first?.url?.path() == "/repos/octo/hello/pulls")
        #expect(requests.first?.url?.query()?.contains("per_page=100") == true)
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
            #expect(request.url?.host() == "api.github.com")
            #expect(request.url?.absoluteString.contains(Self.token) == false)
        }
    }

    @Test("no read comes from a URL cache: a reload right after a merge sees the merged pull request")
    func readsNeverUseTheURLCache() async throws {
        let stub = StubServer { _ in
            .init(headers: ["Cache-Control": "private, max-age=60"], body: Self.pullJSON(1))
        }
        let client = try GitHubClient(token: Self.token, session: stub.session)
        let repo = try #require(GitHubClient.repository(fromRemoteURL: "https://github.com/octo/hello.git"))

        _ = try await client.pullRequest(1, in: repo)

        #expect(stub.requests.map(\.cachePolicy) == [.reloadIgnoringLocalCacheData])
        #expect(HostingHTTP.session.configuration.urlCache == nil)
        #expect(HostingHTTP.session.configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test("the user's repositories come sorted by name from every page, with the token only in the header")
    func userRepositoriesFollowPages() async throws {
        @Sendable func repoJSON(_ id: Int, owner: String, name: String, isPrivate: Bool) -> String {
            """
            {"id": \(id), "name": "\(name)", "full_name": "\(owner)/\(name)", "private": \(isPrivate), "fork": false,
             "owner": {"id": \(id * 10), "login": "\(owner)"}, "clone_url": "https://github.com/\(owner)/\(name).git"}
            """
        }
        let stub = StubServer { request in
            let page2 = "https://api.github.com/user/repos?sort=full_name&per_page=100&page=2"
            if request.url?.query()?.contains("page=2") == true {
                return .init(body: "[\(repoJSON(2, owner: "acme", name: "tools", isPrivate: true))]")
            }
            return .init(
                headers: ["Link": "<\(page2)>; rel=\"next\", <\(page2)>; rel=\"last\""],
                body: "[\(repoJSON(1, owner: "octo", name: "hello", isPrivate: false))]")
        }
        let client = try GitHubClient(token: Self.token, session: stub.session)

        let repos = try await client.userRepositories()

        #expect(repos.map(\.fullName) == ["octo/hello", "acme/tools"])
        #expect(repos.map(\.owner.login) == ["octo", "acme"])
        #expect(repos.map(\.cloneURL) == ["https://github.com/octo/hello.git", "https://github.com/acme/tools.git"])
        #expect(repos.map(\.isPrivate) == [false, true])
        let requests = stub.requests
        #expect(requests.count == 2)
        #expect(requests.first?.url?.path() == "/user/repos")
        #expect(requests.first?.url?.query()?.contains("sort=full_name") == true)
        #expect(requests.first?.url?.query()?.contains("per_page=100") == true)
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
            #expect(request.url?.host() == "api.github.com")
            #expect(request.url?.absoluteString.contains(Self.token) == false)
        }
    }

    @Test("GitHub's capabilities: comment edit, delete, reactions and new inline comments, but no unapprove (refused unsent) and no general replies or resolve")
    func capabilitiesWithoutUnapprove() async throws {
        let stub = StubServer { _ in .init(body: "{}") }
        let client = try GitHubClient(token: Self.token, session: stub.session)

        #expect(client.capabilities == [
            .labels, .assignees, .issues, .requestChanges, .resolveThreads, .draft, .reopen, .reviewRequests,
            .editComments, .deleteComments, .reactions, .newInlineComments, .multiLineInlineComments, .itemReactions,
            .timelineEvents, .updateBranch, .deleteHeadBranch,
        ])
        #expect(client.reactionKinds == ["+1", "-1", "laugh", "hooray", "confused", "heart", "rocket", "eyes"])
        await #expect(throws: HostingError.self) {
            try await client.unapprove(1, in: HostedRepository(host: "github.com", owner: "octo", name: "hello"))
        }
        #expect(stub.requests.isEmpty)
    }

    @Test("a next-page link to another host is refused, so the token never goes there")
    func paginationRefusesOtherOrigin() async throws {
        let stub = StubServer { _ in
            .init(headers: ["Link": "<https://evil.example/repos/octo/hello/pulls?page=2>; rel=\"next\""],
                  body: "[\(Self.pullJSON(1))]")
        }
        let client = try GitHubClient(token: Self.token, session: stub.session)
        let repo = HostedRepository(host: "github.com", owner: "octo", name: "hello")

        await #expect(throws: HostingError.invalidResponse("a next-page link to another host")) {
            try await client.pullRequests(in: repo, state: .open)
        }
        #expect(stub.requests.allSatisfy { $0.url?.host() == "api.github.com" })
    }

    @Test("a redirect to another host is not followed (one on the API host is)", arguments: [
        ("https://api.github.com/moved", true), ("https://evil.example/user", false),
    ])
    func redirectToOtherOriginIsNotFollowed(target: String, isFollowed: Bool) async throws {
        let stub = StubServer { request in
            if request.url?.path() == "/user" {
                return .init(status: 302, headers: ["Location": target], body: "", redirect: URL(string: target))
            }
            return .init(body: #"{"id": 9, "login": "moved"}"#)
        }
        let client = try GitHubClient(token: Self.token, session: stub.session)

        if isFollowed {
            #expect(try await client.currentUser().login == "moved", "positive control: the stub redirects")
            #expect(stub.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
        } else {
            await #expect(throws: HostingError.self) { try await client.currentUser() }
            #expect(stub.requests.allSatisfy { $0.url?.host() == "api.github.com" })
        }
    }

    @Test("on Enterprise a same-host redirect is followed with the token only under /api", arguments: [
        ("https://ghe.example.com/api/v3/moved", true), ("https://ghe.example.com/api/graphql", true),
        ("https://ghe.example.com/login", false), ("https://ghe.example.com/api/v3/../../login", false),
    ])
    func enterpriseRedirectStaysUnderAPI(target: String, isFollowed: Bool) async throws {
        let stub = StubServer { request in
            if request.url?.path() == "/api/v3/user" {
                return .init(status: 302, headers: ["Location": target], body: "", redirect: URL(string: target))
            }
            return .init(body: #"{"id": 9, "login": "moved"}"#)
        }
        let client = try GitHubClient(host: "ghe.example.com", token: Self.token, session: stub.session)

        if isFollowed {
            #expect(try await client.currentUser().login == "moved", "positive control: the stub redirects")
            #expect(stub.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
        } else {
            await #expect(throws: HostingError.self) { try await client.currentUser() }
            #expect(stub.requests.map { $0.url?.path() } == ["/api/v3/user"], "nothing reaches the target")
        }
    }

    // MARK: - Typed errors

    struct ErrorCase: Sendable, CustomTestStringConvertible {
        var status: Int
        var headers: [String: String] = [:]
        var body: String
        var expected: HostingError
        var testDescription: String { "\(status) \(expected)" }
    }

    @Test("HTTP failures become typed errors whose descriptions never show the token", arguments: [
        ErrorCase(status: 401, body: #"{"message": "Bad credentials"}"#, expected: .unauthorized),
        ErrorCase(status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1800000000"],
                  body: #"{"message": "API rate limit exceeded"}"#,
                  expected: .rateLimited(resetsAt: Date(timeIntervalSince1970: 1_800_000_000))),
        ErrorCase(status: 429, headers: ["Retry-After": "60"], body: "{}",
                  expected: .secondaryRateLimited(retryAfterSeconds: 60)),
        ErrorCase(status: 403, headers: ["X-RateLimit-Remaining": "4000"],
                  body: #"{"message": "You have exceeded a secondary rate limit."}"#,
                  expected: .secondaryRateLimited(retryAfterSeconds: nil)),
        ErrorCase(status: 403, headers: ["X-RateLimit-Remaining": "4000"],
                  body: #"{"message": "Resource not accessible by integration"}"#,
                  expected: .forbidden(message: "Resource not accessible by integration")),
        ErrorCase(status: 404, body: #"{"message": "Not Found"}"#, expected: .notFound),
        ErrorCase(status: 200, body: "not json", expected: .invalidResponse("unexpected JSON for HostedUser")),
    ])
    func httpFailuresAreTyped(_ errorCase: ErrorCase) async throws {
        let stub = StubServer { _ in .init(status: errorCase.status, headers: errorCase.headers, body: errorCase.body) }
        let client = try GitHubClient(token: Self.token, session: stub.session)

        let error = await #expect(throws: HostingError.self) { try await client.currentUser() }
        #expect(error == errorCase.expected)
        var dumped = ""
        dump(client, to: &dumped)
        for text in [String(describing: error), String(reflecting: error), String(describing: client),
                     String(reflecting: client), dumped] {
            #expect(!text.contains(Self.token), "\(text)")
        }
    }

    // MARK: - Search

    /// One `/search/issues` item as GitHub sends it: issue-shaped, with `pull_request` and `draft` for a PR.
    static func searchJSON(number: Int, isPullRequest: Bool) -> String {
        let pull = isPullRequest
            ? #", "draft": true, "pull_request": {"url": "https://api.github.com/repos/octo/hello/pulls/\#(number)"}"#
            : ""
        return """
            {"total_count": 1, "incomplete_results": false, "items": [
             {"id": \(number), "number": \(number), "title": "Item \(number)", "state": "open",
              "html_url": "https://github.com/octo/hello/issues/\(number)", "comments": 0,
              "user": {"id": 1, "login": "octo"}, "labels": [], "updated_at": "2026-11-01T10:00:00Z"\(pull)}]}
            """
    }

    enum SearchList: String, CaseIterable, Sendable {
        case mine, reviewRequested, assigned
    }

    @Test("the My PRs, Review requested and Assigned lists search this repo for @me, with the token to the API host",
          arguments: [
              (SearchList.mine, "repo:octo/hello is:pr is:open author:@me", true),
              (SearchList.reviewRequested, "repo:octo/hello is:pr is:open review-requested:@me", true),
              (SearchList.assigned, "repo:octo/hello is:issue is:open assignee:@me", false),
          ])
    func searchListsQueryTheRepo(list: SearchList, query: String, isPullRequest: Bool) async throws {
        let stub = StubServer { _ in .init(body: Self.searchJSON(number: 7, isPullRequest: isPullRequest)) }
        let client = try GitHubClient(token: Self.token, session: stub.session)
        let repo = HostedRepository(host: "github.com", owner: "octo", name: "hello")

        let items = switch list {
        case .mine: try await client.myOpenPullRequests(in: repo)
        case .reviewRequested: try await client.reviewRequestedPullRequests(in: repo)
        case .assigned: try await client.assignedOpenIssues(in: repo)
        }

        #expect(items.map(\.number) == [7])
        #expect(items.first?.isPullRequest == isPullRequest)
        #expect(items.first?.draft == (isPullRequest ? true : nil))
        let request = try #require(stub.requests.first)
        #expect(stub.requests.count == 1)
        #expect(request.url?.host() == "api.github.com")
        #expect(request.url?.path() == "/search/issues")
        let queryItems = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(queryItems.first { $0.name == "q" }?.value == query)
        #expect(queryItems.first { $0.name == "per_page" }?.value == "100")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
        #expect(request.url?.absoluteString.contains(Self.token) == false)
    }

    @Test("a search refuses a repository name that would add its own qualifiers, or a repo on another host")
    func searchRefusesUnsafeRepository() async throws {
        let stub = StubServer { _ in .init(body: Self.searchJSON(number: 1, isPullRequest: true)) }
        let client = try GitHubClient(token: Self.token, session: stub.session)

        let injected = HostedRepository(host: "github.com", owner: "octo", name: "hello is:closed repo:evil/x")
        await #expect(throws: HostingError.self) { try await client.myOpenPullRequests(in: injected) }
        let otherHost = HostedRepository(host: "ghe.example.com", owner: "octo", name: "hello")
        await #expect(throws: HostingError.wrongHost("ghe.example.com")) {
            try await client.assignedOpenIssues(in: otherHost)
        }
        #expect(stub.requests.isEmpty)
    }

    // MARK: - Merge

    @Test("a merge pins the reviewed head: the body carries the method and the head sha")
    func mergeSendsHeadSHA() async throws {
        let stub = StubServer { _ in .init(body: #"{"sha": "cafe", "merged": true, "message": "Merged"}"#) }
        let client = try GitHubClient(token: Self.token, session: stub.session)
        let repo = HostedRepository(host: "github.com", owner: "octo", name: "hello")

        try await client.merge(7, in: repo, method: .squash, sha: "abc123")

        let request = try #require(stub.requests.first)
        #expect(stub.requests.count == 1)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path() == "/repos/octo/hello/pulls/7/merge")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["merge_method"] as? String == "squash")
        #expect(body["sha"] as? String == "abc123")
    }

    @Test("a merge GitHub refuses with 409 (the head moved) throws headChanged; another endpoint's 409 stays http")
    func mergeConflictIsHeadChanged() async throws {
        let stub = StubServer { _ in
            .init(status: 409, body: #"{"message": "Head branch was modified. Review and try the merge again."}"#)
        }
        let client = try GitHubClient(token: Self.token, session: stub.session)
        let repo = HostedRepository(host: "github.com", owner: "octo", name: "hello")

        await #expect(throws: HostingError.headChanged) {
            try await client.merge(7, in: repo, method: .merge, sha: "abc123")
        }
        #expect(HostingError.headChanged.description == "The pull request's head changed: reload and review it again.")
        await #expect(throws: HostingError.http(
            status: 409, message: "Head branch was modified. Review and try the merge again.")) {
            try await client.setOpen(false, item: .pullRequest(7), in: repo)
        }
    }

    // MARK: - Pull request commits and files

    @Test("a PR's commits and files come from its endpoints; a file without a patch or a commit without an account decodes, and a patch parses as read-only hunks")
    func pullRequestCommitsAndFiles() async throws {
        let stub = StubServer { request in
            if request.url?.path() == "/repos/octo/hello/pulls/7/commits" {
                return .init(body: """
                    [{"sha": "aaaa", "html_url": "https://github.com/octo/hello/commit/aaaa",
                      "commit": {"message": "First\\n\\nBody", "author": {"name": "Octo", "email": "o@x.invalid",
                                 "date": "2026-11-01T10:00:00Z"}}, "author": null}]
                    """)
            }
            return .init(body: """
                [{"filename": "src/new.swift", "status": "renamed", "previous_filename": "src/old.swift",
                  "additions": 1, "deletions": 1, "changes": 2, "patch": "@@ -1,2 +1,2 @@ func a()\\n keep\\n-old\\n+new"},
                 {"filename": "logo.png", "status": "added", "additions": 0, "deletions": 0, "changes": 0}]
                """)
        }
        let client = try GitHubClient(token: Self.token, session: stub.session)
        let repo = HostedRepository(host: "github.com", owner: "octo", name: "hello")

        let commits = try await client.pullRequestCommits(7, in: repo)
        let files = try await client.pullRequestFiles(7, in: repo)

        #expect(commits.map(\.sha) == ["aaaa"])
        #expect(commits.first?.author == nil)
        #expect(commits.first?.commit.author?.name == "Octo")
        #expect(files.map(\.filename) == ["src/new.swift", "logo.png"])
        #expect(files.last?.patch == nil)
        #expect(files.last?.diff == nil)
        let diff = try #require(files.first?.diff)
        #expect(diff.change == .renamed)
        #expect(diff.oldPath == "src/old.swift")
        #expect(diff.newPath == "src/new.swift")
        #expect(diff.hunks.count == 1)
        #expect(diff.hunks.first?.section == "func a()")
        #expect(diff.hunks.first?.lines.map(\.kind) == [.context, .removed, .added])
        #expect(diff.hunks.first?.lines.map(\.text) == ["keep", "old", "new"])
        #expect((diff.additions, diff.deletions) == (1, 1))
        #expect(stub.requests.map { $0.url?.path() } == ["/repos/octo/hello/pulls/7/commits", "/repos/octo/hello/pulls/7/files"])
        for request in stub.requests {
            #expect(request.url?.host() == "api.github.com")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
        }
    }

    // MARK: - Creating a pull request

    @Test("a new PR's form reads the default branch, labels, assignable users and collaborators from the repo's endpoints")
    func createFormListsComeFromTheirEndpoints() async throws {
        let stub = StubServer { request in
            switch request.url?.path() {
            case "/repos/octo/hello": .init(body: #"{"full_name": "octo/hello", "default_branch": "trunk"}"#)
            case "/repos/octo/hello/labels": .init(body: #"[{"name": "bug", "color": "d73a4a"}]"#)
            case "/repos/octo/hello/assignees": .init(body: #"[{"id": 1, "login": "octo"}]"#)
            default: .init(status: 403, headers: ["X-RateLimit-Remaining": "4000"],
                           body: #"{"message": "Must have push access to view repository collaborators."}"#)
            }
        }
        let client = try GitHubClient(token: Self.token, session: stub.session)
        let repo = HostedRepository(host: "github.com", owner: "octo", name: "hello")

        #expect(try await client.repositoryInfo(repo).defaultBranch == "trunk")
        #expect(try await client.labels(in: repo).map(\.name) == ["bug"])
        #expect(try await client.assignableUsers(in: repo).map(\.login) == ["octo"])
        // A token without push access: the form leaves the reviewers out instead of failing.
        await #expect(throws: HostingError.forbidden(message: "Must have push access to view repository collaborators.")) {
            try await client.collaborators(in: repo)
        }
        #expect(stub.requests.map { $0.url?.path() } == [
            "/repos/octo/hello", "/repos/octo/hello/labels", "/repos/octo/hello/assignees",
            "/repos/octo/hello/collaborators",
        ])
    }

    @Test("after a create, reviewers, labels and assignees are POSTed to their endpoints with GitHub's body keys")
    func createFollowUpsPostTheirBodies() async throws {
        let stub = StubServer { request in
            request.url?.path().hasSuffix("/labels") == true
                ? .init(body: #"[{"name": "bug"}]"#)
                : .init(status: 201, body: Self.pullJSON(7))
        }
        let client = try GitHubClient(token: Self.token, session: stub.session)
        let repo = HostedRepository(host: "github.com", owner: "octo", name: "hello")

        let created = try await client.createPullRequest(
            NewPullRequest(title: "Add a", head: "feature/a", base: "main", body: "Why", draft: true), in: repo)
        try await client.requestReviewers(
            [HostedUser(id: 1, login: "alice"), HostedUser(id: 2, login: "bob")], on: created.number, in: repo)
        try await client.addLabels(["bug"], to: .pullRequest(created.number), in: repo)
        try await client.addAssignees([HostedUser(id: 3, login: "octo")], to: .pullRequest(created.number), in: repo)

        let requests = stub.requests
        #expect(requests.map { $0.httpMethod } == ["POST", "POST", "POST", "POST"])
        #expect(requests.map { $0.url?.path() } == [
            "/repos/octo/hello/pulls", "/repos/octo/hello/pulls/7/requested_reviewers",
            "/repos/octo/hello/issues/7/labels", "/repos/octo/hello/issues/7/assignees",
        ])
        let bodies = try requests.map { request in
            try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        }
        #expect(bodies[0]["head"] as? String == "feature/a")
        #expect(bodies[0]["base"] as? String == "main")
        #expect(bodies[0]["draft"] as? Bool == true)
        #expect(bodies[1]["reviewers"] as? [String] == ["alice", "bob"])
        #expect(bodies[2]["labels"] as? [String] == ["bug"])
        #expect(bodies[3]["assignees"] as? [String] == ["octo"])
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        }
    }

    // MARK: - Review threads

    @Test("review comments decode with file, line, reply root, review and HTML; a reply POSTs to the root's /replies")
    func reviewCommentsAndReply() async throws {
        let stub = StubServer { request in
            if request.httpMethod == "POST" {
                return .init(status: 201, body: #"{"id": 12, "in_reply_to_id": 10, "path": "a.swift", "body": "Done"}"#)
            }
            return .init(body: """
                [{"id": 10, "pull_request_review_id": 701, "path": "a.swift", "line": 4, "side": "RIGHT",
                  "body": "Why?", "body_html": "<p>Why?</p>", "created_at": "2026-11-01T10:00:00Z",
                  "user": {"id": 1, "login": "octo"}},
                 {"id": 11, "pull_request_review_id": 702, "in_reply_to_id": 10, "path": "a.swift", "line": null,
                  "original_line": 4, "body_html": "<p>Because</p>"}]
                """)
        }
        let client = try GitHubClient(token: Self.token, session: stub.session)
        let repo = HostedRepository(host: "github.com", owner: "octo", name: "hello")

        let comments = try await client.reviewComments(of: 7, in: repo)
        let reply = try await client.reply(to: HostedThreadRef(rootCommentID: 10), on: 7, in: repo, body: "Done")

        #expect(comments.map(\.path) == ["a.swift", "a.swift"])
        #expect(comments.map(\.line) == [4, nil])
        #expect(comments.map(\.inReplyToID) == [nil, 10])
        #expect(comments.map(\.pullRequestReviewID) == [701, 702])
        #expect(comments.map(\.bodyHTML) == ["<p>Why?</p>", "<p>Because</p>"])
        #expect(reply.id == 12)
        let requests = stub.requests
        #expect(requests.map { $0.httpMethod } == ["GET", "POST"])
        #expect(requests.map { $0.url?.path() } == [
            "/repos/octo/hello/pulls/7/comments", "/repos/octo/hello/pulls/7/comments/10/replies",
        ])
        let body = try #require(JSONSerialization.jsonObject(with: requests.last?.httpBody ?? Data()) as? [String: Any])
        #expect(body["body"] as? String == "Done")
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
        }
    }

    @Test("thread states come from the host's GraphQL endpoint with the token; owner, name and number go in variables",
          arguments: [
              ("github.com", "https://api.github.com/graphql", #"{"fullDatabaseId": "10"}"#),
              ("github.com", "https://api.github.com/graphql", #"{"fullDatabaseId": 10}"#),
              ("ghe.example.com", "https://ghe.example.com/api/graphql", #"{"databaseId": 10}"#),
          ])
    func reviewThreadStatesUseGraphQLVariables(host: String, endpoint: String, rootComment: String) async throws {
        // Also: github.com is asked for `fullDatabaseId` alone, a BigInt it sends as a string or a number, and
        // Enterprise for `databaseId` alone; each row's root id decodes to the same REST id.
        let stub = StubServer { _ in
            .init(body: """
                {"data": {"repository": {"pullRequest": {"reviewThreads": {
                  "nodes": [{"id": "PRRT_1", "isResolved": true, "isOutdated": false, "viewerCanResolve": false,
                             "viewerCanUnresolve": true, "comments": {"nodes": [\(rootComment)]}}],
                  "pageInfo": {"hasNextPage": false, "endCursor": null}}}}}}
                """)
        }
        let client = try GitHubClient(host: host, token: Self.token, session: stub.session)
        let repo = HostedRepository(host: host, owner: "octo", name: "hello")

        let states = try await client.reviewThreadStates(of: 4242, in: repo)

        #expect(states == [HostedReviewThreadState(
            id: "PRRT_1", isResolved: true, isOutdated: false, viewerCanResolve: false, viewerCanUnresolve: true,
            rootCommentID: 10)])
        let request = try #require(stub.requests.first)
        #expect(stub.requests.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == endpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        let variables = try #require(body["variables"] as? [String: Any])
        #expect(variables["owner"] as? String == "octo")
        #expect(variables["name"] as? String == "hello")
        #expect(variables["number"] as? Int == 4242)
        let query = try #require(body["query"] as? String)
        for value in ["octo", "hello", "4242"] {
            #expect(!query.contains(value), "\(value) is in the query text")
        }
        #expect(query.contains("fullDatabaseId") == (host == "github.com"))
        #expect(query.contains("databaseId") == (host != "github.com"))
    }

    @Test("a GraphQL answer with errors throws its first message, even with status 200")
    func graphQLErrorsThrow() async throws {
        let stub = StubServer { _ in
            .init(body: """
                {"data": null, "errors": [{"message": "Could not resolve to a node with the global id of 'PRRT_x'"},
                                          {"message": "second"}]}
                """)
        }
        let client = try GitHubClient(token: Self.token, session: stub.session)

        await #expect(throws: HostingError.graphQL(
            message: "Could not resolve to a node with the global id of 'PRRT_x'")) {
            try await client.setReviewThread(
                HostedReviewThreadState(
                    id: "PRRT_x", isResolved: false, isOutdated: false, viewerCanResolve: true,
                    viewerCanUnresolve: false),
                resolved: true)
        }
        let body = try #require(
            JSONSerialization.jsonObject(with: stub.requests.first?.httpBody ?? Data()) as? [String: Any])
        #expect((body["variables"] as? [String: Any])?["threadId"] as? String == "PRRT_x")
        #expect((body["query"] as? String)?.contains("PRRT_x") == false)
    }

    @Test("comment writes: edit and delete per comment kind, inline comments on line and side, reactions by GraphQL")
    func commentWrites() async throws {
        // Also: every write goes to the API host with the token, and a kind GitHub lacks, a comment without a node id
        // or a position without a line on its side is refused unsent.
        let stub = StubServer { request in
            switch request.httpMethod {
            case "DELETE": return .init(status: 204, body: "")
            case "PATCH": return .init(body: #"{"id": 5}"#)
            default:
                if request.url?.path() == "/graphql" { return .init(body: #"{"data": {}}"#) }
                return .init(status: 201, body: #"{"id": 99, "path": "a.swift", "node_id": "PRRC_new"}"#)
            }
        }
        let client = try GitHubClient(token: Self.token, session: stub.session)
        let repo = HostedRepository(host: "github.com", owner: "octo", name: "hello")
        let general = HostedCommentRef(kind: .general, id: 5, hostKey: "IC_5")
        let review = HostedCommentRef(kind: .review, id: 6, hostKey: "PRRC_6")
        func inline(_ position: HostedInlinePosition) async throws {
            #expect(try await client.createInlineComment(at: position, on: 7, in: repo, body: "Hm").id == 99)
        }
        let comments = "/repos/octo/hello/pulls/7/comments"
        let sha = "abc123"
        let rows: [(method: String, path: String, body: [String: Any]?, run: () async throws -> Void)] = [
            ("PATCH", "/repos/octo/hello/issues/comments/5", ["body": "new"],
             { try await client.editComment(general, on: .pullRequest(7), in: repo, body: "new") }),
            ("PATCH", "/repos/octo/hello/pulls/comments/6", ["body": "new"],
             { try await client.editComment(review, on: .pullRequest(7), in: repo, body: "new") }),
            ("DELETE", "/repos/octo/hello/issues/comments/5", nil,
             { try await client.deleteComment(general, on: .issue(7), in: repo) }),
            ("DELETE", "/repos/octo/hello/pulls/comments/6", nil,
             { try await client.deleteComment(review, on: .pullRequest(7), in: repo) }),
            ("POST", comments,
             ["body": "Hm", "commit_id": "abc123", "path": "a.swift", "line": 12, "side": "RIGHT"],
             { try await inline(.init(path: "a.swift", oldLine: nil, newLine: 12, lineKind: .added, headSHA: sha)) }),
            ("POST", comments,
             ["body": "Hm", "commit_id": "abc123", "path": "a.swift", "line": 8, "side": "LEFT"],
             { try await inline(.init(path: "a.swift", oldLine: 8, newLine: nil, lineKind: .removed, headSHA: sha)) }),
            ("POST", comments,
             ["body": "Hm", "commit_id": "abc123", "path": "b.swift", "line": 14, "side": "RIGHT",
              "start_line": 11, "start_side": "RIGHT"],
             { try await inline(.init(
                 path: "b.swift", oldPath: "old.swift", oldLine: 10, newLine: 14, lineKind: .context,
                 startOldLine: 7, startNewLine: 11, headSHA: "abc123")) }),
            ("POST", comments,
             ["body": "Hm", "commit_id": "abc123", "path": "a.swift", "line": 5, "side": "RIGHT",
              "start_line": 3, "start_side": "LEFT"],
             { try await inline(.init(
                 path: "a.swift", oldLine: nil, newLine: 5, lineKind: .added, startOldLine: 3, headSHA: "abc123")) }),
            ("POST", "/graphql", ["subjectId": "PRRC_6", "content": "THUMBS_UP"],
             { try await client.addReaction("+1", to: review, on: .pullRequest(7), in: repo) }),
            ("POST", "/graphql", ["subjectId": "IC_5", "content": "EYES"],
             { try await client.removeReaction("eyes", from: general, on: .issue(7), in: repo) }),
        ]

        for (index, row) in rows.enumerated() {
            try await row.run()
            let request = try #require(stub.requests.last)
            #expect(stub.requests.count == index + 1, "row \(index)")
            #expect(request.httpMethod == row.method, "row \(index)")
            #expect(request.url?.host() == "api.github.com", "row \(index)")
            #expect(request.url?.path() == row.path, "row \(index)")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)", "row \(index)")
            guard let expected = row.body else {
                #expect(request.httpBody?.isEmpty ?? true, "row \(index)")
                continue
            }
            let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
            if row.path == "/graphql" {
                let query = try #require(body["query"] as? String)
                // The last row removes, the one before adds.
                let mutation = index == rows.count - 1 ? "removeReaction(input:" : "addReaction(input:"
                #expect(query.contains(mutation), "row \(index)")
                #expect(!query.contains(expected["subjectId"] as? String ?? "?"), "row \(index): id in the query")
                #expect(NSDictionary(dictionary: body["variables"] as? [String: Any] ?? [:]).isEqual(to: expected),
                        "row \(index)")
            } else {
                #expect(NSDictionary(dictionary: body).isEqual(to: expected), "row \(index): \(body)")
            }
        }

        let sent = stub.requests.count
        await #expect(throws: HostingError.self) {
            try await client.addReaction("tada", to: review, on: .pullRequest(7), in: repo)
        }
        await #expect(throws: HostingError.self) {
            try await client.addReaction("+1", to: .init(kind: .review, id: 6), on: .pullRequest(7), in: repo)
        }
        await #expect(throws: HostingError.self) {
            try await inline(.init(path: "a.swift", oldLine: 4, newLine: nil, lineKind: .added, headSHA: "abc123"))
        }
        #expect(stub.requests.count == sent)
    }

    @Test("the item's own reactions: one issueOrPullRequest query (values in variables), groups in GitHub's order with the viewer's; a write reads the node id, then adds or removes on it; the wrong kind of item or an unknown kind is refused")
    func itemReactions() async throws {
        let stub = StubServer { request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            let query = body?["query"] as? String ?? ""
            guard query.contains("issueOrPullRequest") else { return .init(body: #"{"data": {}}"#) }
            return .init(body: """
                {"data": {"repository": {"issueOrPullRequest": {"__typename": "PullRequest", "id": "PR_n7",
                 "reactionGroups": [
                  {"content": "HEART", "viewerHasReacted": false, "reactors": {"totalCount": 1}},
                  {"content": "THUMBS_UP", "viewerHasReacted": true, "reactors": {"totalCount": 3}},
                  {"content": "EYES", "viewerHasReacted": false, "reactors": {"totalCount": 0}}]}}}}
                """)
        }
        let client = try GitHubClient(token: Self.token, session: stub.session)
        let repo = HostedRepository(host: "github.com", owner: "octo", name: "hello")

        let reactions = try await client.itemReactions(of: .pullRequest(7), in: repo)
        try await client.addItemReaction("heart", to: .pullRequest(7), in: repo)
        try await client.removeItemReaction("+1", from: .pullRequest(7), in: repo)

        #expect(reactions == [HostedReaction(kind: "+1", count: 3, viewerReacted: true),
                              HostedReaction(kind: "heart", count: 1)], "GitHub's order; a zero group left out")
        let bodies = try stub.requests.map { request in
            #expect(request.url?.path() == "/graphql")
            return try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        }
        #expect(bodies.count == 5, "a read, then a read and a mutation per write")
        let read = try #require(bodies.first)
        #expect(NSDictionary(dictionary: read["variables"] as? [String: Any] ?? [:])
            .isEqual(to: ["owner": "octo", "name": "hello", "number": 7]))
        #expect((bodies[2]["query"] as? String)?.contains("addReaction(input:") == true)
        #expect(NSDictionary(dictionary: bodies[2]["variables"] as? [String: Any] ?? [:])
            .isEqual(to: ["subjectId": "PR_n7", "content": "HEART"]))
        #expect((bodies[4]["query"] as? String)?.contains("removeReaction(input:") == true)
        #expect(NSDictionary(dictionary: bodies[4]["variables"] as? [String: Any] ?? [:])
            .isEqual(to: ["subjectId": "PR_n7", "content": "THUMBS_UP"]))

        let sent = stub.requests.count
        await #expect(throws: HostingError.self) {
            try await client.addItemReaction("tada", to: .pullRequest(7), in: repo)
        }
        #expect(stub.requests.count == sent, "an unknown kind is refused unsent")
        await #expect(throws: HostingError.self) { _ = try await client.itemReactions(of: .issue(7), in: repo) }
    }

    @Test("history entries from the REST timeline: comments and reviews left out, consecutive commits by one author grouped with links, GitHub's words escaped, a merged pull request's closed left out, an unknown or malformed event left out")
    func timelineEvents() async throws {
        let actor = #"{"id": 7, "login": "octo"}"#
        let other = #"{"id": 8, "login": "mona"}"#
        let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40)
        let body = "[" + [
            #"{"event": "committed", "sha": "\#(a)", "message": "First <b>\n\nmore", "author": {"name": "Octo", "date": "2026-11-01T10:00:00Z"}}"#,
            #"{"event": "committed", "sha": "\#(b)", "message": "Second", "author": {"name": "Octo", "date": "2026-11-01T11:00:00Z"}}"#,
            #"{"id": 1, "event": "commented", "actor": \#(actor), "created_at": "2026-11-02T10:00:00Z"}"#,
            #"{"id": 2, "event": "reviewed", "user": \#(other), "submitted_at": "2026-11-02T11:00:00Z"}"#,
            #"{"id": 3, "event": "labeled", "actor": \#(actor), "created_at": "2026-11-03T10:00:00Z", "label": {"name": "<img src=x>"}}"#,
            #"{"id": 4, "event": "assigned", "actor": \#(actor), "created_at": "2026-11-03T11:00:00Z", "assignee": \#(actor)}"#,
            #"{"id": 5, "event": "review_requested", "actor": \#(actor), "created_at": "2026-11-03T12:00:00Z", "requested_reviewer": \#(other)}"#,
            #"{"id": 6, "event": "merged", "actor": \#(actor), "created_at": "2026-11-04T10:00:00Z", "commit_id": "\#(b)"}"#,
            #"{"id": 8, "event": "closed", "actor": \#(actor), "created_at": "2026-11-04T10:00:00Z"}"#,
            #"{"id": 7, "event": "subscribed", "actor": \#(actor), "created_at": "2026-11-04T11:00:00Z"}"#,
            #"{"id": "not a number", "event": "closed"}"#,
        ].joined(separator: ", ") + "]"
        let stub = StubServer { _ in .init(body: body) }
        let client = try GitHubClient(token: Self.token, session: stub.session)
        let repo = HostedRepository(host: "github.com", owner: "octo", name: "hello")

        let events = try await client.timelineEvents(of: .pullRequest(7), in: repo)

        #expect(stub.requests.first?.url?.path() == "/repos/octo/hello/issues/7/timeline")
        #expect(events.map(\.text) == [
            "added 2 commits", "added the <img src=x> label", "self-assigned this", "requested a review from mona",
            "merged commit bbbbbbb",
        ])
        #expect(events.map(\.action) == ["committed", "labeled", "assigned", "review_requested", "merged"])
        #expect(events[0].actor?.login == "Octo" && events[1].actor?.login == "octo")
        #expect(events[0].textHTML == "<p>added 2 commits</p><ul>"
            + "<li><a href=\"https://github.com/octo/hello/commit/\(a)\"><code>aaaaaaa</code></a> First &lt;b&gt;</li>"
            + "<li><a href=\"https://github.com/octo/hello/commit/\(b)\"><code>bbbbbbb</code></a> Second</li></ul>")
        #expect(events[1].textHTML == "<p>added the &lt;img src=x&gt; label</p>", "a label name is plain text")
        #expect(Set(events.map(\.id)).count == events.count)
    }

    @Test("update branch: PUT with expected_head_sha, 202 is done; a 422 naming the sha is headChanged, another 422 stays a validation error")
    func updateBranch() async throws {
        let answers = Mutex([
            (202, #"{"message": "Updating pull request branch.", "url": "https://github.com/octo/hello/pull/7"}"#),
            (422, #"{"message": "expected head sha didn't match current head ref."}"#),
            (422, #"{"message": "merge conflict between base and head"}"#),
        ])
        let stub = StubServer { _ in
            let (status, body) = answers.withLock { $0.removeFirst() }
            return .init(status: status, body: body)
        }
        let client = try GitHubClient(token: Self.token, session: stub.session)
        let repo = HostedRepository(host: "github.com", owner: "octo", name: "hello")

        try await client.updateBranch(7, in: repo, expectedHeadSHA: "abc123")
        await #expect(throws: HostingError.headChanged) {
            try await client.updateBranch(7, in: repo, expectedHeadSHA: "abc123")
        }
        await #expect(throws: HostingError.validationFailed(message: "merge conflict between base and head")) {
            try await client.updateBranch(7, in: repo, expectedHeadSHA: "abc123")
        }
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "PUT" && request.url?.path() == "/repos/octo/hello/pulls/7/update-branch")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String])
        #expect(body == ["expected_head_sha": "abc123"])
    }

    @Test("head branch: exists by git/ref (404 is gone), delete by DELETE git/refs (a 422 is an error), restore by POST git/refs at the sha; a branch with a dot segment is refused unsent")
    func headBranch() async throws {
        let stub = StubServer { request in
            switch (request.httpMethod, request.url?.path(percentEncoded: true)) {
            case ("GET", "/repos/octo/hello/git/ref/heads/feature/x"):
                return .init(body: #"{"ref": "refs/heads/feature/x", "object": {"sha": "abc"}}"#)
            case ("GET", _): return .init(status: 404, body: #"{"message": "Not Found"}"#)
            case ("DELETE", "/repos/octo/hello/git/refs/heads/main"):
                return .init(status: 422, body: #"{"message": "Cannot delete the default branch"}"#)
            case ("DELETE", _): return .init(status: 204, body: "")
            default: return .init(status: 201, body: #"{"ref": "refs/heads/feature/x"}"#)
            }
        }
        let client = try GitHubClient(token: Self.token, session: stub.session)
        let repo = HostedRepository(host: "github.com", owner: "octo", name: "hello")

        #expect(try await client.headBranchExists("feature/x", in: repo))
        #expect(try await client.headBranchExists("gone", in: repo) == false)
        try await client.deleteHeadBranch("feature/x", in: repo)
        await #expect(throws: HostingError.self) { try await client.deleteHeadBranch("main", in: repo) }
        try await client.restoreHeadBranch("feature/x", sha: "abc", in: repo)

        let requests = stub.requests
        #expect(requests.map(\.httpMethod) == ["GET", "GET", "DELETE", "DELETE", "POST"])
        #expect(requests[2].url?.path(percentEncoded: true) == "/repos/octo/hello/git/refs/heads/feature/x")
        #expect(requests[4].url?.path() == "/repos/octo/hello/git/refs")
        let body = try #require(JSONSerialization.jsonObject(with: requests[4].httpBody ?? Data()) as? [String: String])
        #expect(body == ["ref": "refs/heads/feature/x", "sha": "abc"])
        await #expect(throws: HostingError.self) { try await client.deleteHeadBranch("a/../b", in: repo) }
        #expect(stub.requests.count == 5)
    }

    @Test("the single pull request carries who merged it, its merge commit, the viewer's push permission and its milestone")
    func pullRequestExtras() async throws {
        let stub = StubServer { _ in
            .init(body: """
                {"id": 1, "number": 7, "title": "T", "state": "closed", "html_url": "https://github.com/octo/hello/pull/7",
                 "head": {"ref": "f", "sha": "h", "label": "octo:f"},
                 "base": {"ref": "main", "sha": "b", "label": "octo:main", "repo": {"permissions": {"push": true}}},
                 "merged_at": "2026-11-01T10:00:00Z", "merged_by": {"id": 7, "login": "octo"},
                 "merge_commit_sha": "m123", "milestone": {"title": "1.0", "due_on": "2026-12-01T08:00:00Z"}}
                """)
        }
        let client = try GitHubClient(token: Self.token, session: stub.session)
        let pull = try await client.pullRequest(7, in: HostedRepository(host: "github.com", owner: "octo", name: "hello"))

        #expect(pull.mergedBy?.login == "octo" && pull.mergeCommitSHA == "m123" && pull.viewerCanPush == true)
        #expect(pull.milestone == HostedMilestone(title: "1.0", dueDate: "2026-12-01T08:00:00Z"))
    }

    @Test("a comment with GitHub's reactions rollup and node_id decodes its counts and node id; one without both too")
    func commentReactionsRollupDecodes() async throws {
        // Without a token there is no viewer: no GraphQL request, and no rights.
        let rollup = """
            "node_id": "IC_kwDO1", "reactions": {"url": "https://api.github.com/x", "total_count": 3, "+1": 2,
            "-1": 0, "laugh": 0, "hooray": 0, "confused": 0, "heart": 1, "rocket": 0, "eyes": 0}
            """
        let stub = StubServer { request in
            if request.url?.path() == "/repos/octo/hello/pulls/7/comments" {
                let review = rollup.replacingOccurrences(of: "IC_", with: "PRRC_")
                return .init(body: #"[{"id": 20, "path": "a.swift", \#(review)}]"#)
            }
            return .init(body: #"[{"id": 10, "body": "Hi", \#(rollup)}, {"id": 11, "body": "Old"}]"#)
        }
        let client = try GitHubClient(token: nil, session: stub.session)
        let repo = HostedRepository(host: "github.com", owner: "octo", name: "hello")

        let comments = try await client.comments(on: .pullRequest(7), in: repo)
        let reviewComments = try await client.reviewComments(of: 7, in: repo)

        let counts = [HostedReaction(kind: "+1", count: 2), HostedReaction(kind: "heart", count: 1)]
        #expect(comments.map(\.id) == [10, 11])
        #expect(comments.map(\.hostKey) == ["IC_kwDO1", nil])
        #expect(comments.map(\.reactions) == [counts, []])
        #expect(reviewComments.first?.hostKey == "PRRC_kwDO1")
        #expect(reviewComments.first?.reactions == counts)
        #expect((comments.map(\.viewerCanEdit) + comments.map(\.viewerCanDelete)).allSatisfy { !$0 })
        #expect(stub.requests.map { $0.httpMethod } == ["GET", "GET"])
    }

    @Test("rights and the viewer's reactions come from one nodes(ids:) query, joined on type and database id; a NOT_FOUND node or a failed query leaves the rest",
          arguments: [
              ("github.com", "https://api.github.com/graphql"),
              ("ghe.example.com", "https://ghe.example.com/api/graphql"),
          ])
    func commentViewerStatesMerge(host: String, endpoint: String) async throws {
        // Issue comment 10 and review comment 10 share an id in separate id spaces; the answer for issue comment 12
        // is a review comment node with that id, which must not join. github.com is asked for `fullDatabaseId` (sent
        // here as a string), Enterprise for `databaseId`.
        @Sendable func node(_ type: String, _ id: Int, edit: Bool, delete: Bool, groups: String) -> String {
            let databaseID = host == "github.com" ? #""fullDatabaseId": "\#(id)""# : #""databaseId": \#(id)"#
            return """
                {"__typename": "\(type)", \(databaseID), "viewerCanUpdate": \(edit), "viewerCanDelete": \(delete),
                 "reactionGroups": [\(groups)]}
                """
        }
        let stub = StubServer { request in
            let path = request.url?.path() ?? ""
            if path.hasSuffix("/graphql") {
                let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let ids = (body?["variables"] as? [String: Any])?["ids"] as? [String] ?? []
                if ids == ["IC_10", "IC_11", "IC_12"] {
                    let groups = #"{"content": "THUMBS_UP", "viewerHasReacted": true}, "#
                        + #"{"content": "LAUGH", "viewerHasReacted": false}"#
                    return .init(body: """
                        {"data": {"nodes": [\(node("IssueComment", 10, edit: true, delete: true, groups: groups)), null,
                          \(node("PullRequestReviewComment", 12, edit: true, delete: true, groups: ""))]},
                         "errors": [{"type": "NOT_FOUND", "path": ["nodes", 1],
                                     "message": "Could not resolve to a node with the global id of 'IC_11'."}]}
                        """)
                }
                if ids == ["PRRC_10"] {
                    let groups = #"{"content": "EYES", "viewerHasReacted": true}"#
                    return .init(body: """
                        {"data": {"nodes": [
                          \(node("PullRequestReviewComment", 10, edit: false, delete: true, groups: groups))]}}
                        """)
                }
                return .init(body: #"{"data": null, "errors": [{"type": "FORBIDDEN", "message": "Not accessible"}]}"#)
            }
            if path.hasSuffix("/pulls/7/comments") {
                return .init(body: #"[{"id": 10, "path": "a.swift", "node_id": "PRRC_10", "reactions": {"eyes": 3}}]"#)
            }
            let prefix = path.hasSuffix("/issues/8/comments") ? "IC_8" : "IC_1"
            return .init(body: """
                [{"id": 10, "node_id": "\(prefix)0", "reactions": {"total_count": 3, "+1": 2, "laugh": 1}},
                 {"id": 11, "node_id": "\(prefix)1", "reactions": {"heart": 1}},
                 {"id": 12, "node_id": "\(prefix)2"}]
                """)
        }
        let client = try GitHubClient(host: host, token: Self.token, session: stub.session)
        let repo = HostedRepository(host: host, owner: "octo", name: "hello")

        let comments = try await client.comments(on: .pullRequest(7), in: repo)
        let reviewComments = try await client.reviewComments(of: 7, in: repo)
        let failed = try await client.comments(on: .issue(8), in: repo)

        #expect(comments.map(\.viewerCanEdit) == [true, false, false])
        #expect(comments.map(\.viewerCanDelete) == [true, false, false])
        #expect(comments.map(\.reactions) == [
            [HostedReaction(kind: "+1", count: 2, viewerReacted: true), HostedReaction(kind: "laugh", count: 1)],
            [HostedReaction(kind: "heart", count: 1)], [],
        ])
        #expect(reviewComments.map(\.viewerCanEdit) == [false])
        #expect(reviewComments.map(\.viewerCanDelete) == [true])
        #expect(reviewComments.first?.reactions == [HostedReaction(kind: "eyes", count: 3, viewerReacted: true)])
        #expect(failed.map(\.viewerCanEdit) == [false, false, false])
        #expect(failed.first?.reactions
            == [HostedReaction(kind: "+1", count: 2), HostedReaction(kind: "laugh", count: 1)])
        let queries = stub.requests.filter { $0.httpMethod == "POST" }
        #expect(queries.count == 3)
        for request in queries {
            #expect(request.url?.absoluteString == endpoint)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
            let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
            let query = try #require(body["query"] as? String)
            #expect(query.contains("nodes(ids: $ids)"))
            #expect(!query.contains("IC_1") && !query.contains("PRRC_"))
            #expect(query.contains("fullDatabaseId") == (host == "github.com"))
            #expect(query.contains("databaseId") == (host != "github.com"))
        }
    }

    @Test("no inline comment is lost: replies join their root's review, and a comment without a review stays")
    func reviewThreadsGroup() throws {
        // Also: a review that only holds a reply is reported, and states join by root id. The reply comes before its
        // root, and the states come in the other order than the threads.
        let json = """
            [{"id": 11, "pull_request_review_id": 702, "in_reply_to_id": 10, "path": "a.swift", "line": 4,
              "created_at": "2026-11-01T11:00:00Z"},
             {"id": 20, "pull_request_review_id": 701, "path": "b.swift", "line": 9,
              "created_at": "2026-11-01T10:01:00Z"},
             {"id": 10, "pull_request_review_id": 701, "path": "a.swift", "line": 4,
              "created_at": "2026-11-01T10:00:00Z"},
             {"id": 30, "pull_request_review_id": null, "path": "c.swift", "line": 1,
              "created_at": "2026-11-01T09:00:00Z"}]
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let comments = try decoder.decode([HostedReviewComment].self, from: Data(json.utf8))
        let states = [
            HostedReviewThreadState(id: "PRRT_20", isResolved: false, isOutdated: false, viewerCanResolve: true,
                                    viewerCanUnresolve: false, rootCommentID: 20),
            HostedReviewThreadState(id: "PRRT_10", isResolved: true, isOutdated: false, viewerCanResolve: false,
                                    viewerCanUnresolve: true, rootCommentID: 10),
        ]

        let grouped = HostedReviewThread.group(comments, states: states)

        #expect(Array(grouped.threadsByReview.keys) == [701])
        let threads = try #require(grouped.threadsByReview[701])
        #expect(threads.map(\.id) == [10, 20])
        #expect(threads.first?.comments.map(\.id) == [10, 11])
        #expect(grouped.replyOnlyReviewIDs == [702])
        #expect(threads.map { $0.state?.id } == ["PRRT_10", "PRRT_20"])
        #expect(threads.map { $0.state?.isResolved } == [true, false])
        #expect(grouped.unattached.map(\.id) == [30])
        #expect(grouped.unattached.first?.reviewID == nil)
    }

    // MARK: - Remote URLs

    @Test("remote URLs resolve to host/owner/repo, Enterprise scp-style ones included", arguments: [
        ("git@ghe.example.com:Team/app.git", "ghe.example.com", "Team", "app"),
        ("org-1@GHE.Example.com:/team/my.repo", "ghe.example.com", "team", "my.repo"),
        ("https://github.com/octo/hello.git", "github.com", "octo", "hello"),
        ("https://user@ghe.example.com:8443/team/app/", "ghe.example.com:8443", "team", "app"),
        ("ssh://git@ghe.example.com:2222/team/app.git", "ghe.example.com", "team", "app"),
    ])
    func remoteURLResolves(url: String, host: String, owner: String, name: String) throws {
        #expect(GitHubClient.repository(fromRemoteURL: url) == HostedRepository(host: host, owner: owner, name: name))
        let client = try GitHubClient(host: host, token: nil)
        let expectedBase = host == "github.com" ? "https://api.github.com" : "https://\(host)/api/v3"
        #expect(client.apiBase.absoluteString == expectedBase)
    }

    @Test("URLs that are not host/owner/repo, or whose host could widen a config key, resolve to nothing",
          arguments: ["https://github.com/octo", "https://gitlab.com/group/sub/repo.git", "/srv/repo:x", "../repo",
                      "git@host:owner/repo/extra", "https://*.example.com/o/r", "file:///tmp/o/r", "git@ho st:o/r",
                      "http://github.com/o/r", "git@-oops:o/r"])
    func otherURLsDoNotResolve(url: String) {
        #expect(GitHubClient.repository(fromRemoteURL: url) == nil)
    }

    // MARK: - Device flow

    @Test("the device flow waits the interval, polls through authorization_pending and adds 5 s on slow_down")
    func deviceFlowHonoursSlowDown() async throws {
        let polls = Mutex(0)
        let stub = StubServer { request in
            if request.url?.path() == "/login/device/code" {
                return .init(body: """
                    {"device_code": "dev123", "user_code": "ABCD-1234", "verification_uri": "https://github.com/login/device",
                     "expires_in": 900, "interval": 5}
                    """)
            }
            let poll = polls.withLock { count in count += 1; return count }
            switch poll {
            case 1: return .init(body: #"{"error": "authorization_pending"}"#)
            case 2: return .init(body: #"{"error": "slow_down", "error_description": "Too many requests"}"#)
            default: return .init(body: #"{"access_token": "\#(Self.token)", "token_type": "bearer", "scope": "repo"}"#)
            }
        }
        let sleeps = Mutex<[Duration]>([])
        let flow = try DeviceFlow(
            clientID: "Iv1.test", session: stub.session, sleep: { duration in sleeps.withLock { $0.append(duration) } })

        let code = try await flow.start()
        #expect(code.userCode == "ABCD-1234")
        let token = try await flow.waitForToken(code)

        #expect(token == DeviceFlow.Token(accessToken: Self.token))
        #expect(sleeps.withLock { $0 } == [.seconds(5), .seconds(5), .seconds(10)])
        let requests = stub.requests
        #expect(requests.allSatisfy { $0.url?.host() == "github.com" }, "the web host, not the API host")
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        let pollBody = String(decoding: requests.last?.httpBody ?? Data(), as: UTF8.self)
        #expect(pollBody.contains("device_code=dev123"))
        #expect(pollBody.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"))
    }

    @Test("the device flow stops on expired_token, access_denied, and once expires_in has passed", arguments: [
        ("expired_token", 900, DeviceFlow.DeviceFlowError.expired),
        ("access_denied", 900, .accessDenied),
        ("authorization_pending", 12, .expired),
    ])
    func deviceFlowStops(answer: String, expiresIn: Int, expected: DeviceFlow.DeviceFlowError) async throws {
        let stub = StubServer { _ in .init(body: #"{"error": "\#(answer)"}"#) }
        let flow = try DeviceFlow(clientID: "Iv1.test", session: stub.session, sleep: { _ in })
        let code = DeviceFlow.DeviceCode(
            deviceCode: "dev", userCode: "U", verificationURI: "https://github.com/login/device",
            expiresIn: expiresIn, interval: 5)

        await #expect(throws: expected) { try await flow.waitForToken(code) }
    }

    @Test("GitLab's device flow asks under the base path, polls through 400 answers and reads optional fields",
          arguments: [
              (#", "refresh_token": "glrt-refresh01", "expires_in": 7200"#, "glrt-refresh01" as String?, 7200 as Int?),
              ("", nil, nil),
          ])
    func gitLabDeviceFlow(extra: String, refreshToken: String?, expiresIn: Int?) async throws {
        let polls = Mutex(0)
        let stub = StubServer { request in
            if request.url?.path() == "/gitlab/oauth/authorize_device" {
                return .init(body: """
                    {"device_code": "dev123", "user_code": "ABCD-1234", "verification_uri": "https://gitlab.example.com/gitlab/oauth/device",
                     "verification_uri_complete": "https://gitlab.example.com/gitlab/oauth/device?user_code=ABCD-1234",
                     "expires_in": 300, "interval": 5}
                    """)
            }
            let poll = polls.withLock { count in count += 1; return count }
            switch poll {
            case 1: return .init(status: 400, body: #"{"error": "authorization_pending", "error_description": "Pending"}"#)
            case 2: return .init(status: 400, body: #"{"error": "slow_down"}"#)
            default: return .init(body: #"{"access_token": "\#(Self.token)", "token_type": "Bearer"\#(extra)}"#)
            }
        }
        let sleeps = Mutex<[Duration]>([])
        let flow = try DeviceFlow(
            kind: .gitlab, host: "GitLab.example.com", basePath: "/gitlab/", clientID: "app-id", session: stub.session,
            sleep: { duration in sleeps.withLock { $0.append(duration) } })

        let code = try await flow.start()
        let token = try await flow.waitForToken(code)

        #expect(code.verificationURIComplete == "https://gitlab.example.com/gitlab/oauth/device?user_code=ABCD-1234")
        #expect(token == DeviceFlow.Token(accessToken: Self.token, refreshToken: refreshToken, expiresIn: expiresIn))
        #expect(!String(describing: token).contains(Self.token) && !String(reflecting: token).contains(Self.token))
        #expect(!String(describing: token).contains("glrt-") && !String(reflecting: token).contains("glrt-"))
        #expect(sleeps.withLock { $0 } == [.seconds(5), .seconds(5), .seconds(10)])
        let requests = stub.requests
        #expect(requests.map { $0.url?.absoluteString } == ["https://gitlab.example.com/gitlab/oauth/authorize_device"]
            + Array(repeating: "https://gitlab.example.com/gitlab/oauth/token", count: 3))
        #expect(requests.allSatisfy {
            $0.httpMethod == "POST" && $0.value(forHTTPHeaderField: "Accept") == "application/json"
                && $0.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded"
                && $0.value(forHTTPHeaderField: "Authorization") == nil
        })
        let startBody = String(decoding: requests.first?.httpBody ?? Data(), as: UTF8.self)
        #expect(startBody == "client_id=app-id&scope=api%20read_user%20read_repository%20write_repository")
        let pollBody = String(decoding: requests.last?.httpBody ?? Data(), as: UTF8.self)
        #expect(pollBody
            == "client_id=app-id&device_code=dev123&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code")
    }

    @Test("GitLab's device flow fails on a 400 with another error code, and never follows a redirect off its base path")
    func gitLabDeviceFlowFailures() async throws {
        let code = DeviceFlow.DeviceCode(
            deviceCode: "dev", userCode: "U", verificationURI: "https://gitlab.example.com/oauth/device",
            expiresIn: 300, interval: 5)
        let denied = StubServer { _ in .init(status: 400, body: #"{"error": "access_denied"}"#) }
        let deniedFlow = try DeviceFlow(
            kind: .gitlab, host: "gitlab.example.com", clientID: "app-id", session: denied.session, sleep: { _ in })
        await #expect(throws: DeviceFlow.DeviceFlowError.accessDenied) { try await deniedFlow.waitForToken(code) }
        let invalid = StubServer { _ in .init(status: 400, body: #"{"error": "invalid_grant"}"#) }
        let invalidFlow = try DeviceFlow(
            kind: .gitlab, host: "gitlab.example.com", clientID: "app-id", session: invalid.session, sleep: { _ in })
        await #expect(throws: DeviceFlow.DeviceFlowError.failed(code: "invalid_grant", description: nil)) {
            try await invalidFlow.waitForToken(code)
        }
        let missing = StubServer { _ in .init(status: 404, body: #"{"status": 404, "error": "Not Found"}"#) }
        let missingFlow = try DeviceFlow(
            kind: .gitlab, host: "gitlab.example.com", clientID: "app-id", session: missing.session, sleep: { _ in })
        await #expect(throws: HostingError.notFound) { try await missingFlow.start() }

        let redirected = StubServer { request in
            request.url?.path() == "/gitlab/oauth/token"
                ? .init(status: 307, body: "", redirect: URL(string: "https://gitlab.example.com/other/oauth/token"))
                : .init(body: #"{"access_token": "\#(Self.token)"}"#)
        }
        let flow = try DeviceFlow(
            kind: .gitlab, host: "gitlab.example.com", basePath: "gitlab", clientID: "app-id",
            session: redirected.session, sleep: { _ in })
        await #expect(throws: HostingError.self) { try await flow.waitForToken(code) }
        #expect(redirected.requests.map { $0.url?.path() } == ["/gitlab/oauth/token"])
    }

    @Test("GitLab's refresh posts the refresh grant under the base path, and a 400 or 401 is the rejection the refresher reads")
    func gitLabRefresh() async throws {
        let stub = StubServer { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            if body.contains("refresh_token=fake-refresh-dead") {
                return .init(status: 400, body: #"{"error": "invalid_grant", "error_description": "The grant is invalid."}"#)
            }
            if body.contains("refresh_token=fake-refresh-401") {
                return .init(status: 401, body: #"{"error": "invalid_client"}"#)
            }
            return .init(body: #"{"access_token": "\#(Self.token)", "refresh_token": "fake-refresh-next", "expires_in": 7200}"#)
        }
        let flow = try DeviceFlow(
            kind: .gitlab, host: "GitLab.example.com", basePath: "/gitlab/", clientID: "app-id", session: stub.session,
            sleep: { _ in })

        let token = try await flow.refresh("fake-refresh-old")
        let expected = token == DeviceFlow.Token(accessToken: Self.token, refreshToken: "fake-refresh-next", expiresIn: 7200)
        #expect(expected)
        let request = try #require(stub.requests.first)
        #expect(request.url?.absoluteString == "https://gitlab.example.com/gitlab/oauth/token")
        #expect(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            == "client_id=app-id&grant_type=refresh_token&refresh_token=fake-refresh-old"
        #expect(body)

        await #expect(throws: HostingError.http(status: 400, message: "The grant is invalid.")) {
            try await flow.refresh("fake-refresh-dead")
        }
        await #expect(throws: HostingError.unauthorized) { try await flow.refresh("fake-refresh-401") }
    }

    // MARK: - Web URLs

    @Test("web URLs keep GitHub's layout on the client's host")
    func webURLs() throws {
        let client = try GitHubClient(token: nil)
        let repo = HostedRepository(host: "github.com", owner: "octo", name: "hello.world")
        let sha = "0123456789abcdef0123456789ABCDEF01234567"
        let expected: [(HostedWebTarget, String)] = [
            (.repository, "https://github.com/octo/hello.world"),
            (.branch("main"), "https://github.com/octo/hello.world/tree/main"),
            (.branch("feature/a-b_c.d"), "https://github.com/octo/hello.world/tree/feature/a-b_c.d"),
            (.branch("my fix#2"), "https://github.com/octo/hello.world/tree/my%20fix%232"),
            (.commit(sha), "https://github.com/octo/hello.world/commit/\(sha)"),
            (.pullRequest(12), "https://github.com/octo/hello.world/pull/12"),
            (.issue(7), "https://github.com/octo/hello.world/issues/7"),
        ]
        for (target, url) in expected {
            #expect(client.webURL(target, in: repo)?.absoluteString == url)
        }
        let enterprise = try GitHubClient(host: "GHE.example.com:8443", token: nil)
        let enterpriseRepo = HostedRepository(host: "ghe.example.com:8443", owner: "team", name: "app")
        #expect(enterprise.webURL(.pullRequest(3), in: enterpriseRepo)?.absoluteString
            == "https://ghe.example.com:8443/team/app/pull/3")
    }

    @Test("no web URL for another host, a dot segment or a sha that is not hex")
    func webURLRejects() throws {
        let client = try GitHubClient(token: nil)
        let repo = HostedRepository(host: "github.com", owner: "octo", name: "hello")
        #expect(client.webURL(.repository, in: HostedRepository(host: "evil.example", owner: "octo", name: "hello"))
            == nil)
        #expect(client.webURL(.repository, in: HostedRepository(host: "github.com", owner: "octo", name: "..")) == nil)
        #expect(client.webURL(.repository, in: HostedRepository(host: "github.com", owner: ".", name: "x")) == nil)
        #expect(client.webURL(.repository, in: HostedRepository(host: "github.com", path: ["a", "..", "x"])) == nil)
        for branch in ["..", "../../evil", "a/../b", "a/./b", "a//b", ""] {
            #expect(client.webURL(.branch(branch), in: repo) == nil, "\(branch)")
        }
        for sha in ["", "xyz", "abc/def", "../abc", "\u{FF10}\u{FF11}"] {
            #expect(client.webURL(.commit(sha), in: repo) == nil, "\(sha)")
        }
    }
}

/// Serves every request of its own `URLSession` through `StubURLProtocol` and records them (body included).
final class StubServer: Sendable {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body: String
        /// Answer with a redirect to this URL instead (the new request keeps the original's headers but
        /// `Authorization`, as URLSession does).
        var redirect: URL?
    }

    let id = UUID().uuidString
    let session: URLSession
    private let state: Mutex<[URLRequest]> = Mutex([])
    let handler: @Sendable (URLRequest) -> Reply

    init(handler: @escaping @Sendable (URLRequest) -> Reply) {
        self.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = [StubURLProtocol.serverHeader: id]
        session = URLSession(configuration: configuration)
        // Kept for the whole test run: a test's server is tiny, and removing it would race late callbacks.
        StubURLProtocol.servers.withLock { $0[id] = self }
    }

    var requests: [URLRequest] { state.withLock { $0 } }

    fileprivate func record(_ request: URLRequest) { state.withLock { $0.append(request) } }
}

/// Finds the request's `StubServer` by a header the session adds, so concurrent tests never share a handler.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let serverHeader = "X-Histq-Stub"
    static let servers = Mutex<[String: StubServer]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            request.httpBody = Self.read(stream)
        }
        let id = request.value(forHTTPHeaderField: Self.serverHeader) ?? ""
        guard let server = Self.servers.withLock({ $0[id] }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        server.record(request)
        let reply = server.handler(request)
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        if let redirect = reply.redirect {
            // With the original headers but `Authorization`, as URLSession builds the new request before its
            // delegate decides (it drops that one): a test sees whether the delegate put it back.
            var next = URLRequest(url: redirect)
            next.allHTTPHeaderFields = request.allHTTPHeaderFields
            next.setValue(nil, forHTTPHeaderField: "Authorization")
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
