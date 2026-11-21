// Contract tests for the Bitbucket Cloud client, served by `StubServer` (GitHubClientTests.swift) with inline JSON: no
// test reaches the network. They guard the token (only in the `Authorization` header, only under
// `https://api.bitbucket.org/2.0`, refreshed once after a 401, never sent to a `next` page or a merge's `Location`
// elsewhere), the merge's head check, and the mapping of a pull request's threads into the hosted models.
import Foundation
import HistqCore
import Synchronization
import Testing

struct BitbucketCloudClientTests {
    /// Made-up tokens; the tests look for them where they must never be.
    static let token = "histq-fake-fresh-0123456789"
    static let staleToken = "histq-fake-stale-0123456789"

    static let repo = HostedRepository(host: "bitbucket.org", path: ["ws", "repo"])
    static let repoPath = "/2.0/repositories/ws/repo"
    static let prPath = repoPath + "/pullrequests/5"

    static func account(_ uuid: String, _ nickname: String) -> String {
        #"{"uuid": "{\#(uuid)}", "display_name": "User \#(nickname)", "nickname": "\#(nickname)", "links": {"avatar": {"href": "https://avatar.example/\#(nickname).png"}}}"#
    }

    /// A pull request #`id` whose source is `hash` on `feature`, in `ws/repo` or (`fork`) in another repository.
    static func pullRequest(id: Int = 5, hash: String = "abc123def456", fork: Bool = false) -> String {
        """
        {"id": \(id), "title": "Add feature", "state": "OPEN", "draft": true, "author": \(account("u1", "me")),
         "summary": {"raw": "Body", "markup": "markdown", "html": "<p>Body</p>"},
         "rendered": {"description": {"raw": "Body", "html": "<p>Rendered</p>"}},
         "source": {"branch": {"name": "feature"}, "commit": {"hash": "\(hash)"},
                    "repository": {"uuid": "{\(fork ? "r2" : "r1")}", "full_name": "\(fork ? "someone/repo" : "ws/repo")"}},
         "destination": {"branch": {"name": "main", "merge_strategies": ["merge_commit", "squash"]},
                         "commit": {"hash": "0011223344aa"}, "repository": {"uuid": "{r1}", "full_name": "ws/repo"}},
         "reviewers": [\(account("u2", "rev"))],
         "participants": [{"user": \(account("u2", "rev")), "role": "REVIEWER", "approved": true, "state": "approved",
                           "participated_on": "2026-11-03T10:00:00.123456+00:00"},
                          {"user": \(account("u3", "other")), "role": "PARTICIPANT", "approved": false,
                           "state": "changes_requested"},
                          {"user": \(account("u4", "quiet")), "role": "PARTICIPANT", "approved": false, "state": null}],
         "comment_count": 3, "created_on": "2026-11-01T10:00:00.123456+00:00",
         "updated_on": "2026-11-02T10:00:00+00:00",
         "links": {"html": {"href": "https://bitbucket.org/ws/repo/pull-requests/\(id)"}}}
        """
    }

    /// Counts a provider's forced refreshes.
    final class Refreshes: Sendable {
        let count = Mutex(0)
    }

    /// A provider that already refreshed: it hands out `token` from the first request.
    static func refreshed() -> Refreshes {
        let refreshes = Refreshes()
        refreshes.count.withLock { $0 = 1 }
        return refreshes
    }

    /// A client whose provider hands out `staleToken` until it is told that token was refused, then `token`, and
    /// whose merge polls do not wait.
    static func client(_ stub: StubServer, refreshes: Refreshes = refreshed()) -> BitbucketCloudClient {
        var client = BitbucketCloudClient(session: stub.session) { rejected in
            refreshes.count.withLock { count in
                if let rejected { count += rejected == Self.staleToken ? 1 : 1000 }
                return count > 0 ? Self.token : Self.staleToken
            }
        }
        client.mergePollDelay = .zero
        return client
    }

    static func json(_ request: URLRequest) -> [String: Any] {
        request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    static func query(_ request: URLRequest, _ name: String) -> [String] {
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.filter { $0.name == name }.compactMap(\.value) ?? []
    }

    // MARK: - Token

    @Test("the token goes only in the Authorization header, only to api.bitbucket.org under /2.0; a 401 refreshes it once and retries")
    func tokenOnlyUnderAPIBase() async throws {
        @Sendable func repository(_ fullName: String, clone: String) -> String {
            """
            {"uuid": "{\(fullName)}", "full_name": "\(fullName)", "name": "Name", "is_private": true,
             "links": {"clone": [{"name": "https", "href": "\(clone)"}, {"name": "ssh", "href": "git@bitbucket.org:\(fullName).git"}]}}
            """
        }
        let stub = StubServer { request in
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)" else {
                return .init(status: 401, body: #"{"type": "error", "error": {"message": "Unauthorized"}}"#)
            }
            switch request.url?.path() ?? "" {
            case "/2.0/user": return .init(body: Self.account("u1", "me"))
            case "/2.0/user/workspaces":
                if Self.query(request, "page") == ["2"] {
                    return .init(body: #"{"values": [{"workspace": {"slug": "other"}}]}"#)
                }
                return .init(body: #"{"values": [{"workspace": {"slug": "ws"}}], "next": "https://api.bitbucket.org/2.0/user/workspaces?pagelen=50&page=2"}"#)
            case "/2.0/repositories/ws":
                return .init(body: """
                    {"values": [\(repository("ws/repo", clone: "https://me@bitbucket.org/ws/repo.git")),
                                \(repository("ws/elsewhere", clone: "https://evil.example/ws/elsewhere.git"))]}
                    """)
            case "/2.0/repositories/other":
                return .init(body: #"{"values": [\#(repository("other/tools", clone: "https://bitbucket.org/other/tools.git"))]}"#)
            default: return .init(status: 404, body: "{}")
            }
        }
        let refreshes = Refreshes()
        let client = Self.client(stub, refreshes: refreshes)

        let me = try await client.currentUser()
        #expect(me.login == "me" && me.reviewerID == "{u1}" && me.name == "User me")
        let repos = try await client.userRepositories()

        #expect(refreshes.count.withLock { $0 } == 1)
        #expect(repos.map(\.fullName) == ["other/tools", "ws/repo"], "a clone link off bitbucket.org is left out")
        #expect(repos.map(\.cloneURL) == ["https://bitbucket.org/other/tools.git", "https://me@bitbucket.org/ws/repo.git"])
        #expect(repos.map(\.owner.login) == ["other", "ws"] && repos.allSatisfy(\.isPrivate))
        let requests = stub.requests
        #expect(requests.map { $0.url?.path() } == [
            "/2.0/user", "/2.0/user", "/2.0/user/workspaces", "/2.0/user/workspaces", "/2.0/repositories/ws",
            "/2.0/repositories/other",
        ])
        let firstIsStale = requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.staleToken)"
        #expect(firstIsStale)
        for request in requests.dropFirst() {
            let carriesFresh = request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)"
            #expect(carriesFresh)
        }
        for request in requests {
            #expect(request.url?.scheme == "https" && request.url?.host() == "api.bitbucket.org")
            #expect(request.url?.absoluteString.contains(Self.token) == false)
            #expect(request.url?.absoluteString.contains(Self.staleToken) == false)
        }
        #expect(!String(describing: client).contains(Self.token))
        #expect(!String(reflecting: client).contains(Self.token))
    }

    @Test("a next page outside api.bitbucket.org/2.0 is refused, so the token never goes there", arguments: [
        "https://evil.example/2.0/repositories/ws/repo/pullrequests?page=2",
        "http://api.bitbucket.org/2.0/repositories/ws/repo/pullrequests?page=2",
        "https://api.bitbucket.org/internal/repositories/ws/repo/pullrequests?page=2",
        "https://api.bitbucket.org/2.0evil/repositories/ws/repo/pullrequests?page=2",
        "https://api.bitbucket.org/2.0/../internal?page=2",
        "https://bitbucket.org/2.0/repositories/ws/repo/pullrequests?page=2",
    ])
    func nextPageOutsideAPIIsRefused(next: String) async throws {
        let stub = StubServer { _ in .init(body: #"{"values": [\#(Self.pullRequest())], "next": "\#(next)"}"#) }
        let client = Self.client(stub)

        await #expect(throws: HostingError.invalidResponse("a next-page link to another host")) {
            try await client.pullRequests(in: Self.repo, state: .open)
        }
        #expect(stub.requests.map { $0.url?.path() } == [Self.repoPath + "/pullrequests"])
    }

    @Test("the diff's redirect to the repository diff (same origin, under /2.0) is followed with the token; one elsewhere is not", arguments: [
        ("https://api.bitbucket.org/2.0/repositories/ws/repo/diff/abc123def456..0011223344aa?topic=true", true),
        ("https://bitbucket.org/ws/repo/diff/abc..def", false),
        ("https://api.bitbucket.org/internal/diff/abc..def", false),
        ("https://evil.example/2.0/repositories/ws/repo/diff/abc..def", false),
    ])
    func diffRedirect(target: String, isFollowed: Bool) async throws {
        let diff = """
            diff --git a/src/app.swift b/src/app.swift
            index 1111111..2222222 100644
            --- a/src/app.swift
            +++ b/src/app.swift
            @@ -1,3 +1,3 @@
             line one
            -old two
            +new two
             line three
            diff --git a/new.txt b/new.txt
            new file mode 100644
            index 0000000..3333333
            --- /dev/null
            +++ b/new.txt
            @@ -0,0 +1 @@
            +hello
            diff --git a/old.txt b/renamed.txt
            similarity index 100%
            rename from old.txt
            rename to renamed.txt
            diff --git a/logo.png b/logo.png
            index 4444444..5555555 100644
            Binary files a/logo.png and b/logo.png differ

            """
        let stub = StubServer { request in
            if request.url?.path() == Self.prPath + "/diff" {
                return .init(status: 302, headers: ["Location": target], body: "", redirect: URL(string: target))
            }
            return .init(headers: ["Content-Type": "text/plain"], body: diff)
        }
        let client = Self.client(stub)

        if isFollowed {
            let files = try await client.pullRequestFiles(5, in: Self.repo)
            #expect(files.map(\.filename) == ["src/app.swift", "new.txt", "renamed.txt", "logo.png"])
            #expect(files.map(\.status) == ["modified", "added", "renamed", "modified"])
            #expect(files.map(\.additions) == [1, 1, 0, 0] && files.map(\.deletions) == [1, 0, 0, 0])
            #expect(files[0].patch == "@@ -1,3 +1,3 @@\n line one\n-old two\n+new two\n line three")
            #expect(files[1].patch == "@@ -0,0 +1 @@\n+hello")
            #expect(files[2].patch == nil && files[2].previousFilename == "old.txt")
            #expect(files[3].patch == nil, "a binary file has no patch")
            #expect(stub.requests.map { $0.url?.absoluteString } == ["https://api.bitbucket.org" + Self.prPath + "/diff", target])
            let carriesToken = stub.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)"
            #expect(carriesToken, "a followed redirect keeps the header, which is why only some are followed")
            #expect(stub.requests.first?.value(forHTTPHeaderField: "Accept") == "text/plain")
        } else {
            await #expect(throws: HostingError.self) { try await client.pullRequestFiles(5, in: Self.repo) }
            #expect(stub.requests.map { $0.url?.path() } == [Self.prPath + "/diff"], "nothing reaches the target")
        }
    }

    @Test("a file whose lines end in CRLF keeps them and does not swallow the next file")
    func crlfDiff() async throws {
        let diff = "diff --git a/win.txt b/win.txt\n--- a/win.txt\n+++ b/win.txt\n@@ -1 +1 @@\n-old\r\n+new\r\n"
            + "diff --git a/b.txt b/b.txt\n--- a/b.txt\n+++ b/b.txt\n@@ -1 +1 @@\n-x\n+y\n"
        let stub = StubServer { _ in .init(body: diff) }

        let files = try await Self.client(stub).pullRequestFiles(5, in: Self.repo)

        #expect(files.map(\.filename) == ["win.txt", "b.txt"])
        #expect(files.first?.patch == "@@ -1 +1 @@\n-old\r\n+new\r")
        #expect(files.last?.patch == "@@ -1 +1 @@\n-x\n+y")
        #expect(files.map(\.additions) == [1, 1] && files.map(\.deletions) == [1, 1])
    }

    @Test("Bitbucket's error body gives the message")
    func errorMessage() async throws {
        let stub = StubServer { _ in
            .init(status: 403, body: #"{"type": "error", "error": {"message": "Your credentials lack one or more required privilege scopes."}}"#)
        }
        await #expect(throws: HostingError.forbidden(message: "Your credentials lack one or more required privilege scopes.")) {
            try await Self.client(stub).currentUser()
        }
    }

    // MARK: - Merge

    /// A Bitbucket whose pull request #5 has source `hash` and whose merge answers `merge` (status, headers, body),
    /// and whose task status answers `tasks` in turn (the last one repeats; `Refreshes` counts the polls).
    static func mergeServer(
        hash: String = "abc123def456", merge: StubServer.Reply = .init(body: "{}"), tasks: [StubServer.Reply] = []
    ) -> StubServer {
        let polls = Refreshes()
        return StubServer { request in
            let path = request.url?.path() ?? ""
            if path == Self.prPath { return .init(body: Self.pullRequest(hash: hash)) }
            if path == Self.prPath + "/merge" { return merge }
            if path.hasPrefix(Self.prPath + "/merge/task-status/") {
                let index = polls.count.withLock { count in
                    defer { count += 1 }
                    return count
                }
                return tasks[min(index, tasks.count - 1)]
            }
            return .init(status: 404, body: "{}")
        }
    }

    @Test("a merge with the head's sha (the PR's abbreviated hash a prefix of it) POSTs the mapped strategy only")
    func mergeSendsStrategy() async throws {
        let stub = Self.mergeServer()
        try await Self.client(stub).merge(
            5, in: Self.repo, method: .squash, sha: "abc123def4567890abc123def4567890abc12345")

        let requests = stub.requests
        #expect(requests.map(\.httpMethod) == ["GET", "POST"])
        #expect(requests.map { $0.url?.path() } == [Self.prPath, Self.prPath + "/merge"])
        let body = Self.json(requests[1])
        #expect(Set(body.keys) == ["merge_strategy"] && body["merge_strategy"] as? String == "squash")
    }

    @Test("a merge is refused as headChanged when the source moved, before Bitbucket is asked to merge")
    func mergeRefusedWhenHeadMoved() async throws {
        let stub = Self.mergeServer(hash: "fff000fff000")
        await #expect(throws: HostingError.headChanged) {
            try await Self.client(stub).merge(5, in: Self.repo, method: .merge, sha: "abc123def456")
        }
        #expect(stub.requests.map { $0.url?.path() } == [Self.prPath])
    }

    @Test("a merge with an empty, too short or non-hex sha is refused as headChanged unsent", arguments: [
        "", "abc12", "abc123", "zzzzzzzz", "abc123de f",
    ])
    func mergeRefusedForBadSHA(sha: String) async throws {
        let stub = Self.mergeServer()
        await #expect(throws: HostingError.headChanged) {
            try await Self.client(stub).merge(5, in: Self.repo, method: .merge, sha: sha)
        }
        #expect(stub.requests.isEmpty)
    }

    @Test("a 409 from the merge is headChanged, a 400 is validationFailed with Bitbucket's message, a strategy the branch does not allow is refused unsent")
    func mergeErrors() async throws {
        let conflict = Self.mergeServer(merge: .init(status: 409, body: ""))
        await #expect(throws: HostingError.headChanged) {
            try await Self.client(conflict).merge(5, in: Self.repo, method: .merge, sha: "abc123def456")
        }
        #expect(Self.json(conflict.requests[1])["merge_strategy"] as? String == "merge_commit")

        let refused = Self.mergeServer(
            merge: .init(status: 400, body: #"{"type": "error", "error": {"message": "You can't merge until..."}}"#))
        await #expect(throws: HostingError.validationFailed(message: "You can't merge until...")) {
            try await Self.client(refused).merge(5, in: Self.repo, method: .merge, sha: "abc123def456")
        }

        let notOffered = Self.mergeServer()
        await #expect(throws: HostingError.self) {
            try await Self.client(notOffered).merge(5, in: Self.repo, method: .rebase, sha: "abc123def456")
        }
        #expect(notOffered.requests.map(\.httpMethod) == ["GET"], "rebase_merge is not in the branch's strategies")
    }

    @Test("a 202 is polled through the task status built from its Location's task id until SUCCESS")
    func mergeQueuedIsPolled() async throws {
        let location = "https://api.bitbucket.org/2.0/repositories/ws/repo/pullrequests/5/merge/task-status/task-1"
        let pending = StubServer.Reply(body: #"{"task_status": "PENDING"}"#)
        let stub = Self.mergeServer(
            merge: .init(status: 202, headers: ["Location": location], body: ""),
            tasks: [pending, pending, .init(body: #"{"task_status": "SUCCESS", "merge_result": {}}"#)])

        try await Self.client(stub).merge(5, in: Self.repo, method: .merge, sha: "abc123def456")

        let polls = stub.requests.filter { $0.url?.path().contains("/task-status/") == true }
        #expect(polls.map { $0.url?.absoluteString } == Array(repeating: location, count: 3))
        #expect(polls.allSatisfy { $0.httpMethod == "GET" })

        let failed = Self.mergeServer(
            merge: .init(status: 202, headers: ["Location": location], body: ""),
            tasks: [pending, .init(status: 400, body: #"{"type": "error", "error": {"message": "Left the merge queue"}}"#)])
        await #expect(throws: HostingError.validationFailed(message: "Left the merge queue")) {
            try await Self.client(failed).merge(5, in: Self.repo, method: .merge, sha: "abc123def456")
        }

        let endless = Self.mergeServer(
            merge: .init(status: 202, headers: ["Location": location], body: ""), tasks: [pending])
        let bounded = {
            var client = Self.client(endless)
            client.mergePolls = 4
            return client
        }()
        await #expect(throws: HostingError.self) {
            try await bounded.merge(5, in: Self.repo, method: .merge, sha: "abc123def456")
        }
        #expect(endless.requests.count { $0.url?.path().contains("/task-status/") == true } == 4, "bounded")
    }

    @Test("a 202 whose Location is not this pull request's task status is never requested", arguments: [
        "https://evil.example/2.0/repositories/ws/repo/pullrequests/5/merge/task-status/task-1",
        "//evil.example/2.0/repositories/ws/repo/pullrequests/5/merge/task-status/task-1",
        "http://api.bitbucket.org/2.0/repositories/ws/repo/pullrequests/5/merge/task-status/task-1",
        "https://api.bitbucket.org/2.0/user",
        "https://api.bitbucket.org/2.0/repositories/ws/repo/pullrequests/6/merge/task-status/task-1",
        "https://api.bitbucket.org/2.0/repositories/ws/repo/pullrequests/5/merge/task-status/a/../../../../../user",
        "https://api.bitbucket.org/2.0/repositories/ws/repo/pullrequests/5/merge/task-status/%2E%2E",
        "https://api.bitbucket.org/2.0/repositories/ws/repo/pullrequests/5/merge/task-status/",
    ])
    func hostileLocationIsNotRequested(location: String) async throws {
        let stub = Self.mergeServer(
            merge: .init(status: 202, headers: ["Location": location], body: ""),
            tasks: [.init(body: #"{"task_status": "SUCCESS"}"#)])

        await #expect(throws: HostingError.validationFailed(message: "Bitbucket queued the merge: reload to see when it is done")) {
            try await Self.client(stub).merge(5, in: Self.repo, method: .merge, sha: "abc123def456")
        }
        #expect(stub.requests.map { $0.url?.absoluteString } == [
            "https://api.bitbucket.org" + Self.prPath, "https://api.bitbucket.org" + Self.prPath + "/merge",
        ])
    }

    // MARK: - Mapping

    @Test("a pull request list and detail map with draft, rendered HTML, reviews and labels; inline comments become threads with old and new side lines, hunks and resolved states")
    func pullRequestsAndThreads() async throws {
        @Sendable func comment(
            _ id: Int, inline: String? = nil, parent: Int? = nil, resolved: Bool = false, deleted: Bool = false,
            pending: Bool = false
        ) -> String {
            """
            {"id": \(id), "content": {"raw": "note **\(id)**", "markup": "markdown", "html": "<p>note <strong>\(id)</strong></p>"},
             "user": \(Self.account("c\(id)", "u\(id)")), "deleted": \(deleted), "pending": \(pending),
             "created_on": "2026-11-02T10:\(id):00.000000+00:00",
             "links": {"html": {"href": "https://bitbucket.org/ws/repo/pull-requests/5/_/diff#comment-\(id)"}}
             \(inline.map { #", "inline": \#($0)"# } ?? "")\(parent.map { #", "parent": {"id": \#($0)}"# } ?? "")
             \(resolved ? #", "resolution": {"type": "comment_resolution", "created_on": "2026-11-03T10:00:00+00:00"}"# : "")}
            """
        }
        let newLine = #"{"path": "src/app.swift", "from": null, "to": 2}"#
        let oldLine = #"{"path": "src/app.swift", "from": 2, "to": null}"#
        let range = #"{"path": "src/app.swift", "from": null, "to": 3, "start_from": null, "start_to": 1}"#
        let comments = """
            {"values": [\(comment(10, inline: newLine, resolved: true)), \(comment(11, inline: newLine, parent: 10)),
                        \(comment(12, parent: 11)), \(comment(20, inline: oldLine)), \(comment(25, inline: range)),
                        \(comment(30)), \(comment(31, deleted: true)), \(comment(32, inline: newLine, pending: true)),
                        \(comment(33, parent: 30))]}
            """
        let diff = """
            diff --git a/src/app.swift b/src/app.swift
            --- a/src/app.swift
            +++ b/src/app.swift
            @@ -1,3 +1,3 @@
             line one
            -old two
            +new two
             line three

            """
        let stub = StubServer { request in
            let body = switch request.url?.path() ?? "" {
            case Self.repoPath + "/pullrequests":
                #"{"values": [\#(Self.pullRequest(id: 5)), \#(Self.pullRequest(id: 6, fork: true))]}"#
            case Self.prPath: Self.pullRequest()
            case Self.prPath + "/comments": comments
            case Self.prPath + "/diff": diff
            default: ""
            }
            return body.isEmpty ? .init(status: 404, body: "{}") : .init(body: body)
        }
        let client = Self.client(stub)
        let repo = try #require(BitbucketCloudClient.repository(fromRemoteURL: "git@bitbucket.org:ws/repo.git"))
        #expect(repo == Self.repo)

        let listed = try await client.pullRequests(in: repo, state: .open)
        #expect(Self.query(stub.requests[0], "state") == ["OPEN"])
        #expect(listed.map(\.number) == [5, 6] && listed.allSatisfy { $0.state == "open" && $0.draft == true })
        #expect(listed.map(\.head.label) == ["ws:feature", nil], "a fork's head has no label")
        #expect(listed.map { client.checkout(of: $0) } == [
            .ref("heads/feature"), .unavailable(reason: "Pull requests from forks can't be checked out here"),
        ])
        _ = try await client.pullRequests(in: repo, state: .closed)
        #expect(Self.query(stub.requests[1], "state") == ["MERGED", "DECLINED", "SUPERSEDED"])

        let pull = try await client.pullRequest(5, in: repo)
        #expect(pull.title == "Add feature" && pull.body == "Body" && pull.bodyHTML == "<p>Rendered</p>")
        #expect(pull.head.ref == "feature" && pull.head.sha == "abc123def456" && pull.base.ref == "main")
        #expect(pull.base.label == "ws:main" && pull.user?.login == "me" && pull.user?.reviewerID == "{u1}")
        #expect(pull.requestedReviewers?.map(\.login) == ["rev"] && pull.merged == false && pull.mergedAt == nil)
        #expect(pull.htmlURL == "https://bitbucket.org/ws/repo/pull-requests/5")
        #expect(abs((pull.createdAt?.timeIntervalSince1970 ?? 0) - 1_793_527_200.123) < 0.001, "microseconds")

        let reviews = try await client.reviews(of: 5, in: repo)
        #expect(reviews.map(\.user?.login) == ["rev", "other"])
        #expect(reviews.map(\.state) == ["APPROVED", "CHANGES_REQUESTED"])
        #expect(reviews.map(\.user?.reviewerID) == ["{u2}", "{u3}"])

        let conversation = try await client.comments(on: .pullRequest(5), in: repo)
        #expect(conversation.map(\.id) == [30, 33], "no inline thread, deleted or pending comment")
        #expect(conversation.first?.bodyHTML == "<p>note <strong>30</strong></p>")

        let reviewComments = try await client.reviewComments(of: 5, in: repo)
        let byID = Dictionary(uniqueKeysWithValues: reviewComments.map { ($0.id, $0) })
        #expect(Set(byID.keys) == [10, 11, 12, 20, 25])
        #expect(byID[10]?.side == "RIGHT" && byID[10]?.line == 2 && byID[10]?.inReplyToID == nil)
        #expect(byID[10]?.diffHunk == "@@ -1,3 +1,3 @@\n line one\n-old two\n+new two")
        #expect(byID[11]?.inReplyToID == 10 && byID[12]?.inReplyToID == 10, "a reply's reply joins the root")
        #expect(byID[12]?.path == "src/app.swift" && byID[12]?.line == 2)
        #expect(byID[20]?.side == "LEFT" && byID[20]?.line == 2)
        #expect(byID[20]?.diffHunk == "@@ -1,3 +1,3 @@\n line one\n-old two")
        #expect(byID[25]?.side == "RIGHT" && byID[25]?.line == 3 && byID[25]?.startLine == 1)

        let states = try await client.reviewThreadStates(of: 5, in: repo)
        #expect(states.map(\.rootCommentID) == [10, 20, 25])
        #expect(states.map(\.isResolved) == [true, false, false])
        let grouped = HostedReviewThread.group(reviewComments, states: states)
        #expect(grouped.unattached.map(\.id) == [10, 20, 25])
        #expect(grouped.unattached.map(\.comments.count) == [3, 1, 1])
        #expect(grouped.unattached.map { $0.state?.isResolved } == [true, false, false])

        let ids = reviews.map(\.id) + conversation.map(\.id) + reviewComments.map(\.id)
        #expect(Set(ids).count == ids.count)
        for request in stub.requests {
            #expect(request.url?.path().hasPrefix(Self.repoPath + "/pullrequests") == true)
        }
    }

    @Test("resolving POSTs and reopening DELETEs the root's resolve, for a thread the client mapped")
    func resolveThread() async throws {
        let stub = StubServer { request in
            let path = request.url?.path() ?? ""
            if path == Self.prPath + "/comments" {
                return .init(body: #"{"values": [{"id": 10, "inline": {"path": "a.swift", "to": 1}, "content": {"raw": "x"}}]}"#)
            }
            if path == Self.prPath + "/comments/10/resolve" {
                return request.httpMethod == "POST" ? .init(body: #"{"type": "comment_resolution"}"#) : .init(status: 204, body: "")
            }
            return .init(status: 404, body: "{}")
        }
        let client = Self.client(stub)
        let unknown = HostedReviewThreadState(
            id: "10", isResolved: false, isOutdated: false, viewerCanResolve: true, viewerCanUnresolve: true)
        await #expect(throws: HostingError.self) { try await client.setReviewThread(unknown, resolved: true) }
        #expect(stub.requests.isEmpty)

        let state = try #require(try await client.reviewThreadStates(of: 5, in: Self.repo).first)
        #expect(try await client.setReviewThread(state, resolved: true) == true)
        #expect(try await client.setReviewThread(state, resolved: false) == false)
        let writes = stub.requests.filter { $0.httpMethod != "GET" }
        #expect(writes.map(\.httpMethod) == ["POST", "DELETE"])
        #expect(writes.allSatisfy { $0.url?.path() == Self.prPath + "/comments/10/resolve" })
    }

    @Test("a reply posts a comment with the root as parent; requesting changes posts the body only after Bitbucket accepted")
    func replyAndRequestChanges() async throws {
        let stub = StubServer { request in
            switch request.url?.path() ?? "" {
            case Self.prPath + "/comments":
                .init(status: 201, body: #"{"id": 77, "content": {"raw": "ok"}, "user": \#(Self.account("u1", "me")), "parent": {"id": 10}, "inline": {"path": "a.swift", "to": 4}}"#)
            case Self.prPath + "/request-changes":
                .init(body: #"{"user": \#(Self.account("u1", "me")), "state": "changes_requested"}"#)
            default: .init(status: 404, body: "{}")
            }
        }
        let client = Self.client(stub)

        let reply = try await client.reply(
            to: HostedThreadRef(rootCommentID: 10), on: 5, in: Self.repo, body: "ok")
        #expect(reply.id == 77 && reply.inReplyToID == 10 && reply.path == "a.swift" && reply.line == 4)
        let post = Self.json(stub.requests[0])
        #expect((post["parent"] as? [String: Any])?["id"] as? Int == 10)
        #expect((post["content"] as? [String: Any])?["raw"] as? String == "ok")

        let review = try await client.review(5, in: Self.repo, event: .requestChanges, body: "Fix it")
        #expect(review.state == "CHANGES_REQUESTED" && review.user?.login == "me" && review.body == "Fix it")
        #expect(stub.requests.dropFirst().map { $0.url?.path() } == [
            Self.prPath + "/request-changes", Self.prPath + "/comments",
        ])
        #expect(Self.json(stub.requests[2])["parent"] == nil)
    }

    @Test("BBQL values are quoted with backslashes and quotes escaped: my and review-requested lists filter by the user's uuid")
    func bbqlEscaping() async throws {
        let stub = StubServer { request in
            request.url?.path() == "/2.0/user"
                ? .init(body: #"{"uuid": "{a\"b\\c}", "nickname": "me"}"#)
                : .init(body: #"{"values": [\#(Self.pullRequest())]}"#)
        }
        let client = Self.client(stub)

        let mine = try await client.myOpenPullRequests(in: Self.repo)
        _ = try await client.reviewRequestedPullRequests(in: Self.repo)

        #expect(mine.map(\.number) == [5] && mine.first?.isPullRequest == true && mine.first?.draft == true)
        let lists = stub.requests.filter { $0.url?.path() == Self.repoPath + "/pullrequests" }
        #expect(lists.map { Self.query($0, "q") } == [[#"author.uuid="{a\"b\\c}""#], [#"reviewers.uuid="{a\"b\\c}""#]])
        #expect(lists.allSatisfy { Self.query($0, "state") == ["OPEN"] })
        #expect(stub.requests.count { $0.url?.path() == "/2.0/user" } == 1, "the uuid is asked once")
    }

    @Test("web URLs use Bitbucket's layout; none for an issue, another host or a sha that is not hex")
    func webURLs() {
        let client = BitbucketCloudClient { _ in Self.token }
        let base = "https://bitbucket.org/ws/repo"
        #expect(client.webURL(.repository, in: Self.repo)?.absoluteString == base)
        #expect(client.webURL(.branch("feat/x y"), in: Self.repo)?.absoluteString == base + "/src/feat/x%20y")
        #expect(client.webURL(.commit("abc123"), in: Self.repo)?.absoluteString == base + "/commits/abc123")
        #expect(client.webURL(.pullRequest(5), in: Self.repo)?.absoluteString == base + "/pull-requests/5")
        #expect(client.webURL(.issue(6), in: Self.repo) == nil)
        #expect(client.webURL(.repository, in: HostedRepository(host: "github.com", path: ["ws", "repo"])) == nil)
        #expect(client.webURL(.commit("abc;x"), in: Self.repo) == nil)
        #expect(client.capabilities == [.requestChanges, .resolveThreads, .draft, .reviewRequests, .unapprove])
    }
}
