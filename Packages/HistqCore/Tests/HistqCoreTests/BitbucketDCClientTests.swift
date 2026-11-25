// Contract tests for the Bitbucket Data Center client, served by `StubServer` (GitHubClientTests.swift) with inline
// JSON shaped as the REST 10.4 spec (activities as the 7.21 reference example): no test reaches the network. They
// guard the token (only in the `Authorization` header, only under `https://<host>/<context path>/rest/`, never to a
// redirect elsewhere, and paging only moves a numeric `start`), the merge's head and version checks, the mapping of
// a pull request's activities into threads, and the order of a review's writes.
import Foundation
import HistqCore
import Synchronization
import Testing

struct BitbucketDCClientTests {
    /// Made-up tokens; the tests look for them where they must never be.
    static let token = "histq-fake-dc-fresh-0123456789"
    static let staleToken = "histq-fake-dc-stale-0123456789"

    static let origin = "https://bb.example.com"
    static let api = "/bitbucket/rest/api/latest"
    static let repo = HostedRepository(host: "bb.example.com", path: ["PROJ", "repo"])
    static let repoPath = api + "/projects/PROJ/repos/repo"
    static let prPath = repoPath + "/pull-requests/5"
    static let head = "abc123def4567890abc123def4567890abc12345"
    /// 2025-11-02 10:00 UTC in milliseconds, the fixtures' first date.
    static let t0 = 1_762_077_600_000

    static func user(_ name: String, slug: String, id: Int) -> String {
        """
        {"name": "\(name)", "emailAddress": "\(slug)@example.com", "id": \(id), "displayName": "User \(name)",
         "active": true, "slug": "\(slug)", "type": "NORMAL"}
        """
    }

    /// The token's user: its slug differs from its name, as Data Center allows.
    static let me = user("Jane.Doe", slug: "jane.doe", id: 101)
    static let reviewer = user("rev", slug: "rev", id: 102)

    /// Pull request #`id`, at `version`, whose source `feature` is at `hash`, in `source` (`PROJ/repo` by default,
    /// the destination).
    static func pullRequest(
        id: Int = 5, version: Int = 3, hash: String = head, state: String = "OPEN",
        source: (key: String, slug: String)? = nil
    ) -> String {
        let repository = #"{"slug": "repo", "id": 1, "name": "repo", "project": {"key": "PROJ", "id": 1}}"#
        let fromRepository = source.map {
            #"{"slug": "\#($0.slug)", "id": 2, "name": "\#($0.slug)", "project": {"key": "\#($0.key)", "id": 2}}"#
        } ?? repository
        return """
            {"id": \(id), "version": \(version), "title": "Add feature", "description": "Body", "state": "\(state)",
             "open": \(state == "OPEN"), "closed": \(state != "OPEN"), "createdDate": \(t0), "updatedDate": \(t0 + 1000),
             "locked": false,
             "fromRef": {"id": "refs/heads/feature", "displayId": "feature", "latestCommit": "\(hash)",
                         "repository": \(fromRepository)},
             "toRef": {"id": "refs/heads/main", "displayId": "main",
                       "latestCommit": "0011223344aa0011223344aa0011223344aa0011", "repository": \(repository)},
             "author": {"user": \(me), "role": "AUTHOR", "approved": false, "status": "UNAPPROVED"},
             "reviewers": [{"user": \(reviewer), "role": "REVIEWER", "approved": false, "status": "UNAPPROVED"}],
             "participants": [],
             "links": {"self": [{"href": "https://bb.example.com/bitbucket/projects/PROJ/repos/repo/pull-requests/\(id)"}]}}
            """
    }

    /// A comment as the activities and comment endpoints send it, with its replies nested: `deletable` follows
    /// `editable` unless given, and a nil `editable` leaves out `permittedOperations`.
    static func comment(
        _ id: Int, version: Int = 0, text: String, at created: Int, replies: [String] = [], resolved: Bool? = nil,
        editable: Bool? = true, deletable: Bool? = nil
    ) -> String {
        let rights = editable.map { editable in
            #""permittedOperations": {"editable": \#(editable), "deletable": \#(deletable ?? editable), "transitionable": true},"#
        } ?? ""
        return """
            {"properties": {"repositoryId": 1}, "id": \(id), "version": \(version), "text": "\(text)", "author": \(me),
             "createdDate": \(created), "updatedDate": \(created), "comments": [\(replies.joined(separator: ", "))],
             \(rights) "severity": "NORMAL", "state": "OPEN"
             \(resolved.map { #", "threadResolved": \#($0)"# } ?? "")}
            """
    }

    static func anchor(line: Int, lineType: String, fileType: String?, path: String) -> String {
        let fileType = fileType.map { #""fileType": "\#($0)", "# } ?? ""
        return #"{"line": \#(line), "lineType": "\#(lineType)", \#(fileType)"path": "\#(path)", "srcPath": "\#(path)"}"#
    }

    static func commented(_ id: Int, _ commentAction: String, _ comment: String, anchor: String? = nil) -> String {
        """
        {"id": \(id), "createdDate": \(t0), "user": \(me), "action": "COMMENTED", "commentAction": "\(commentAction)",
         "comment": \(comment)\(anchor.map { ", \"commentAnchor\": \($0)" } ?? "")}
        """
    }

    static func page(_ values: [String], next: String? = nil) -> String {
        """
        {"size": \(values.count), "limit": 100, "start": 0, "isLastPage": \(next == nil),
         "values": [\(values.joined(separator: ", "))]\(next.map { ", \"nextPageStart\": \($0)" } ?? "")}
        """
    }

    static func errors(_ message: String) -> String {
        #"{"errors": [{"context": null, "message": "\#(message)", "exceptionName": "com.atlassian.bitbucket.ServiceException"}]}"#
    }

    static let notFound = StubServer.Reply(status: 404, body: errors("Not found"))

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

    /// A client of `bb.example.com` under `/bitbucket` whose provider hands out `staleToken` until it is told that
    /// token was refused, then `token`.
    static func client(_ stub: StubServer, refreshes: Counter = refreshed()) throws -> BitbucketDCClient {
        try BitbucketDCClient(host: "bb.example.com", basePath: "/bitbucket", session: stub.session) { rejected in
            refreshes.count.withLock { count in
                if let rejected { count += rejected == Self.staleToken ? 1 : 1000 }
                return count > 0 ? Self.token : Self.staleToken
            }
        }
    }

    static func json(_ request: URLRequest) -> [String: Any] {
        request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    static func query(_ request: URLRequest, _ name: String) -> [String] {
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.filter { $0.name == name }.compactMap(\.value) ?? []
    }

    static let properties = StubServer.Reply(
        headers: ["X-AUSERNAME": "Jane.Doe"],
        body: #"{"version": "8.19.1", "buildNumber": "8019001", "buildDate": "1730000000000", "displayName": "Bitbucket"}"#)

    // MARK: - Token

    @Test("the token goes only in the Authorization header, only under https://bb.example.com/bitbucket/rest/; a 401 asks for it again once")
    func tokenOnlyUnderContextPath() async throws {
        let stub = StubServer { request in
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)" else {
                return .init(status: 401, body: Self.errors("Authentication failed. Please check your credentials."))
            }
            switch request.url?.path() ?? "" {
            case Self.api + "/application-properties": return Self.properties
            case Self.api + "/users":
                return .init(body: Self.page([Self.user("Jane.Doer", slug: "jane.doer", id: 103), Self.me]))
            case "/bitbucket/rest/build-status/latest/commits/stats/\(Self.head)":
                return .init(body: #"{"successful": 2, "failed": 1, "inProgress": 0, "cancelled": 0, "unknown": 0}"#)
            default: return Self.notFound
            }
        }
        let refreshes = Counter()
        let client = try Self.client(stub, refreshes: refreshes)

        let me = try await client.currentUser()
        #expect(me.login == "Jane.Doe" && me.reviewerID == "jane.doe" && me.name == "User Jane.Doe" && me.id == 101)
        #expect(client.capabilities.contains(.draft), "8.19.1 has drafts")
        let runs = try await client.checkRuns(for: Self.head, in: Self.repo)
        #expect(runs.map(\.name) == ["2 successful builds", "1 failed build"])

        #expect(refreshes.count.withLock { $0 } == 1)
        let requests = stub.requests
        #expect(requests.map { $0.url?.path() } == [
            Self.api + "/application-properties", Self.api + "/application-properties", Self.api + "/users",
            "/bitbucket/rest/build-status/latest/commits/stats/\(Self.head)",
        ])
        #expect(Self.query(requests[2], "filter") == ["Jane.Doe"])
        let firstIsStale = requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.staleToken)"
        #expect(firstIsStale)
        for request in requests.dropFirst() {
            let carriesFresh = request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)"
            #expect(carriesFresh)
        }
        for request in requests {
            #expect(request.url?.absoluteString.hasPrefix(Self.origin + "/bitbucket/rest/") == true)
            #expect(request.url?.absoluteString.contains(Self.token) == false)
            #expect(request.url?.absoluteString.contains(Self.staleToken) == false)
        }
        #expect(!String(describing: client).contains(Self.token))
        #expect(!String(reflecting: client).contains(Self.token))
    }

    @Test("a redirect is followed with the token only on the same origin and under the request's own base, context path included", arguments: [
        ("https://bb.example.com/bitbucket/rest/api/latest/projects/PROJ/repos/repo/pull-requests/6", true),
        ("https://bb.example.com/rest/api/latest/projects/PROJ/repos/repo/pull-requests/6", false),
        ("https://bb.example.com/other/rest/api/latest/projects/PROJ/repos/repo/pull-requests/6", false),
        ("https://bb.example.com/bitbucket/rest/api/latestx/projects/PROJ/repos/repo/pull-requests/6", false),
        ("https://bb.example.com/bitbucket/rest/build-status/latest/commits/stats/abc1234", false),
        ("https://bb.example.com/bitbucket/rest/branch-utils/latest/projects/PROJ/repos/repo/branches", false),
        ("https://evil.example/bitbucket/rest/api/latest/projects/PROJ/repos/repo/pull-requests/6", false),
        ("http://bb.example.com/bitbucket/rest/api/latest/projects/PROJ/repos/repo/pull-requests/6", false),
        ("https://bb.example.com:8443/bitbucket/rest/api/latest/projects/PROJ/repos/repo/pull-requests/6", false),
    ])
    func redirects(target: String, isFollowed: Bool) async throws {
        let stub = StubServer { request in
            if request.url?.path() == Self.prPath {
                return .init(status: 302, headers: ["Location": target], body: "", redirect: URL(string: target))
            }
            return .init(body: Self.pullRequest(id: 6))
        }
        let client = try Self.client(stub)

        if isFollowed {
            #expect(try await client.pullRequest(5, in: Self.repo).number == 6, "positive control: the stub redirects")
            #expect(stub.requests.map { $0.url?.absoluteString } == [
                Self.origin + Self.prPath, target, Self.origin + Self.repoPath + "/settings/pull-requests",
            ], "the detail reads the repository's strategies after the pull request")
            let carriesToken = stub.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)"
            #expect(carriesToken, "URLSession drops the header on a redirect: the guard puts it back on one it follows")
        } else {
            await #expect(throws: HostingError.self) { try await client.pullRequest(5, in: Self.repo) }
            #expect(stub.requests.map { $0.url?.absoluteString } == [Self.origin + Self.prPath], "nothing reaches the target")
        }
    }

    @Test("paging moves only a numeric start on the same URL (limit=100) and stops at a page that does not move forward; a nextPageStart that is not a number fails the list unsent elsewhere")
    func pagingKeepsTheOrigin() async throws {
        let stub = StubServer { request in
            switch Self.query(request, "start") {
            case ["0"]: .init(body: Self.page([Self.me], next: "100"))
            case ["100"]: .init(body: Self.page([Self.reviewer], next: "50"))
            default: .init(body: Self.page([Self.user("late", slug: "late", id: 104)]))
            }
        }
        let users = try await Self.client(stub).collaborators(in: Self.repo)

        #expect(users.map(\.login) == ["Jane.Doe", "rev"])
        let requests = stub.requests
        #expect(requests.map { Self.query($0, "start") } == [["0"], ["100"]])
        for request in requests {
            #expect(request.url?.scheme == "https" && request.url?.host() == "bb.example.com")
            #expect(request.url?.path() == Self.api + "/users")
            #expect(Self.query(request, "limit") == ["100"])
            #expect(Self.query(request, "permission.1.projectKey") == ["PROJ"])
            #expect(Self.query(request, "permission.1.repositorySlug") == ["repo"])
        }

        let hostile = StubServer { _ in
            .init(body: Self.page([Self.me], next: #""https://evil.example/bitbucket/rest/api/latest/users?start=100""#))
        }
        await #expect(throws: HostingError.self) { try await Self.client(hostile).collaborators(in: Self.repo) }
        #expect(hostile.requests.map { $0.url?.absoluteString } == [
            Self.origin + Self.api + "/users?permission.1=REPO_READ&permission.1.projectKey=PROJ"
                + "&permission.1.repositorySlug=repo&limit=100&start=0",
        ])
    }

    @Test("currentUser without X-AUSERNAME (the token was not accepted) is unauthorized, and no user is looked up")
    func currentUserWithoutHeader() async throws {
        let stub = StubServer { _ in .init(body: #"{"version": "8.19.1", "displayName": "Bitbucket"}"#) }
        await #expect(throws: HostingError.unauthorized) { try await Self.client(stub).currentUser() }
        #expect(stub.requests.map { $0.url?.path() } == [Self.api + "/application-properties"])
    }

    // MARK: - Merge

    /// A Data Center whose pull request #5 reads at `versions` in turn (the last repeats) with source `hash`, and
    /// whose merge answers `merge`.
    static func mergeServer(versions: [Int] = [3], hash: String = head, merge: StubServer.Reply) -> StubServer {
        let reads = Counter()
        return StubServer { request in
            switch (request.httpMethod ?? "", request.url?.path() ?? "") {
            case ("GET", Self.prPath):
                .init(body: Self.pullRequest(version: versions[min(reads.next(), versions.count - 1)], hash: hash))
            case ("POST", Self.prPath + "/merge"): merge
            default: Self.notFound
            }
        }
    }

    @Test("a merge with the head's sha POSTs merge?version=N with the version just read and the strategy id")
    func mergeSendsVersionAndStrategy() async throws {
        let stub = Self.mergeServer(merge: .init(body: Self.pullRequest(version: 4, state: "MERGED")))
        try await Self.client(stub).merge(5, in: Self.repo, method: .merge, sha: Self.head)

        let requests = stub.requests
        #expect(requests.map(\.httpMethod) == ["GET", "GET", "POST"])
        #expect(requests.map { $0.url?.path() } == [
            Self.prPath, Self.repoPath + "/settings/pull-requests", Self.prPath + "/merge",
        ], "the strategies cannot be read (404): no-ff, of mergeMethods, is sent")
        #expect(requests[2].url?.query() == "version=3")
        let body = Self.json(requests[2])
        #expect(Set(body.keys) == ["version", "strategyId"])
        #expect(body["version"] as? Int == 3 && body["strategyId"] as? String == "no-ff")
    }

    @Test("a merge is refused as headChanged when the source moved, before Data Center is asked to merge")
    func mergeRefusedWhenHeadMoved() async throws {
        let stub = Self.mergeServer(merge: .init(body: "{}"))
        await #expect(throws: HostingError.headChanged) {
            try await Self.client(stub).merge(5, in: Self.repo, method: .merge, sha: "fff000fff000")
        }
        #expect(stub.requests.map(\.httpMethod) == ["GET"], "no POST sent")
    }

    @Test("a 409 from the merge reads the pull request again: a new version is headChanged, the same one validationFailed with Data Center's message", arguments: [
        ([3, 4], HostingError.headChanged),
        ([3, 3], HostingError.validationFailed(message: "The pull request has conflicts and cannot be merged.")),
    ])
    func mergeConflict(versions: [Int], expected: HostingError) async throws {
        let message = versions[1] == versions[0]
            ? "The pull request has conflicts and cannot be merged."
            : "You are attempting to modify a pull request based on out-of-date information."
        let stub = Self.mergeServer(versions: versions, merge: .init(status: 409, body: Self.errors(message)))
        await #expect(throws: expected) {
            try await Self.client(stub).merge(5, in: Self.repo, method: .merge, sha: Self.head)
        }
        #expect(stub.requests.map(\.httpMethod) == ["GET", "GET", "POST", "GET"])
    }

    // MARK: - Threads

    /// A pull request's activities, newest first: root 10 (inline, removed line, resolved) with reply 11 added then
    /// edited, root 20 (inline, old file's context line), root 30 (inline, added line), general root 40 with reply 41
    /// and its reply 42 (also as a REPLIED entry), and RESCOPED, APPROVED and MERGED entries.
    static var activities: String {
        let reply11 = comment(11, text: "Agreed", at: t0 + 60_000, editable: false)
        let anchor10 = anchor(line: 12, lineType: "REMOVED", fileType: nil, path: "src/app.swift")
        let reply42 = comment(42, text: "Third", at: t0 + 360_000)
        let reply41 = comment(41, text: "Second", at: t0 + 300_000, replies: [reply42])
        let rescoped = """
            {"id": 9008, "createdDate": \(t0 + 400_000), "user": \(me), "action": "RESCOPED",
             "fromHash": "\(head)", "previousFromHash": "1111111111111111111111111111111111111111",
             "previousToHash": "0011223344aa0011223344aa0011223344aa0011",
             "toHash": "0011223344aa0011223344aa0011223344aa0011",
             "added": {"commits": [{"id": "\(head)", "displayId": "abc123d", "message": "Fix"}], "total": 1},
             "removed": {"commits": [], "total": 0}}
            """
        return page([
            #"{"id": 9009, "createdDate": \#(t0 + 500_000), "user": \#(me), "action": "MERGED"}"#,
            rescoped,
            commented(
                9007, "EDITED",
                comment(10, version: 1, text: "Edited text", at: t0, replies: [reply11], resolved: true),
                anchor: anchor10),
            #"{"id": 9006, "createdDate": \#(t0 + 380_000), "user": \#(reviewer), "action": "APPROVED"}"#,
            commented(9005, "REPLIED", reply41),
            commented(9004, "ADDED", comment(40, text: "General", at: t0 + 240_000, replies: [reply41], resolved: false)),
            commented(
                9003, "ADDED", comment(30, text: "New line", at: t0 + 180_000, resolved: false),
                anchor: anchor(line: 4, lineType: "ADDED", fileType: "TO", path: "README.md")),
            commented(
                9002, "ADDED", comment(20, text: "Old context", at: t0 + 120_000, resolved: false),
                anchor: anchor(line: 7, lineType: "CONTEXT", fileType: "FROM", path: "src/old.swift")),
            commented(
                9001, "ADDED", comment(10, text: "Old text", at: t0, replies: [reply11], resolved: true),
                anchor: anchor10),
        ])
    }

    @Test("activities map into threads: anchored roots become review threads (side from fileType/lineType, resolved from threadResolved), a general root keeps its replies' direct parents, other actions add nothing, and an edited root is kept once at its highest version")
    func activitiesIntoThreads() async throws {
        let stub = StubServer { request in
            request.url?.path() == Self.prPath + "/activities" ? .init(body: Self.activities) : Self.notFound
        }
        let client = try Self.client(stub)

        let inline = try await client.reviewComments(of: 5, in: Self.repo)
        #expect(inline.map(\.id) == [10, 11, 20, 30])
        #expect(inline.map(\.inReplyToID) == [nil, 10, nil, nil])
        #expect(inline.map(\.path) == ["src/app.swift", "src/app.swift", "src/old.swift", "README.md"])
        #expect(inline.map(\.line) == [12, 12, 7, 4])
        #expect(inline.map(\.side) == ["LEFT", "LEFT", "LEFT", "RIGHT"])
        #expect(inline.map(\.body) == ["Edited text", "Agreed", "Old context", "New line"])
        #expect(inline.map(\.hostKey) == ["1", "0", "0", "0"])
        #expect(inline.map(\.viewerCanEdit) == [true, false, true, true])
        #expect(inline[0].createdAt == Date(timeIntervalSince1970: 1_762_077_600))
        #expect(inline.first?.user?.login == "Jane.Doe")

        let states = try await client.reviewThreadStates(of: 5, in: Self.repo)
        #expect(states.map(\.id) == ["10", "20", "30"])
        #expect(states.map(\.isResolved) == [true, false, false])
        #expect(states.map(\.rootCommentID) == [10, 20, 30])

        let general = try await client.comments(on: .pullRequest(5), in: Self.repo)
        #expect(general.map(\.id) == [40, 41, 42])
        #expect(general.map(\.parentID) == [nil, 40, 41])
        #expect(general.map(\.body) == ["General", "Second", "Third"])
        #expect(general.map(\.resolvable) == [true, nil, nil])
        #expect(general.map(\.resolved) == [false, nil, nil])

        let activityRequests = stub.requests.filter { $0.url?.path() == Self.prPath + "/activities" }
        #expect(activityRequests.count == 3)
        #expect(activityRequests.allSatisfy { Self.query($0, "limit") == ["100"] && Self.query($0, "start") == ["0"] })
    }

    @Test("nested general replies keep their own rights from permittedOperations (absent is false) and their own version as hostKey, which an edit sends")
    func nestedRepliesRightsAndVersions() async throws {
        let reply52 = Self.comment(52, version: 4, text: "Third", at: Self.t0 + 120_000, editable: nil)
        let reply51 = Self.comment(
            51, version: 1, text: "Second", at: Self.t0 + 60_000, replies: [reply52], editable: false)
        let root = Self.comment(
            50, version: 3, text: "General", at: Self.t0, replies: [reply51], resolved: false, editable: true,
            deletable: false)
        let stub = StubServer { request in
            switch (request.httpMethod ?? "", request.url?.path() ?? "") {
            case ("GET", Self.prPath + "/activities"): .init(body: Self.page([Self.commented(9001, "ADDED", root)]))
            case ("PUT", Self.prPath + "/comments/52"): .init(body: Self.comment(52, version: 5, text: "new", at: Self.t0))
            default: Self.notFound
            }
        }
        let client = try Self.client(stub)

        let general = try await client.comments(on: .pullRequest(5), in: Self.repo)
        #expect(general.map(\.id) == [50, 51, 52])
        #expect(general.map(\.hostKey) == ["3", "1", "4"])
        #expect(general.map(\.viewerCanEdit) == [true, false, false])
        #expect(general.map(\.viewerCanDelete) == [false, false, false])

        let last = try #require(general.last)
        try await client.editComment(
            HostedCommentRef(kind: .general, id: last.id, hostKey: last.hostKey), on: .pullRequest(5), in: Self.repo,
            body: "new")
        let put = try #require(stub.requests.last)
        #expect(put.httpMethod == "PUT" && put.url?.path() == Self.prPath + "/comments/52")
        #expect(NSDictionary(dictionary: Self.json(put)).isEqual(to: ["version": 4, "text": "new"]))
    }

    // MARK: - Writes

    @Test("comment interactions send the documented method, path, query and body; Data Center's 409 messages come back; an issue, a review ref on a general write, a ref without its version, a range and a line missing on its side are refused unsent; no reactions")
    func commentInteractions() async throws {
        let stale = "You are attempting to modify a comment based on out-of-date information."
        let hasReplies = "The comment has replies"
        let comments = Self.prPath + "/comments"
        let stub = StubServer { request in
            let body = Self.json(request)
            switch (request.httpMethod ?? "", request.url?.path() ?? "") {
            case ("GET", comments + "/40"): return .init(body: Self.comment(40, version: 3, text: "General", at: Self.t0))
            case ("PUT", comments + "/41"): return .init(status: 409, body: Self.errors(stale))
            case ("GET", Self.prPath): return .init(body: Self.pullRequest(version: 3))
            case ("PUT", Self.prPath): return .init(body: Self.pullRequest(version: 4))
            case ("PUT", let path):
                let id = Int(path.split(separator: "/").last ?? "") ?? 0
                let resolved = body["threadResolved"] as? Bool
                return .init(body: Self.comment(id, version: 8, text: "new", at: Self.t0, resolved: resolved))
            case ("DELETE", comments + "/42"): return .init(status: 409, body: Self.errors(hasReplies))
            case ("DELETE", _): return .init(status: 204, body: "")
            case ("POST", comments):
                let anchor = (body["anchor"] as? [String: Any]).flatMap {
                    try? JSONSerialization.data(withJSONObject: $0)
                }.map { #""anchor": \#(String(decoding: $0, as: UTF8.self)), "severity""# }
                let created = Self.comment(90, text: body["text"] as? String ?? "", at: Self.t0)
                return .init(status: 201, body: anchor.map { created.replacingOccurrences(of: #""severity""#, with: $0) } ?? created)
            default: return Self.notFound
            }
        }
        let client = try Self.client(stub)
        let pr = HostedItem.pullRequest(5)
        let root = HostedCommentRef(kind: .general, id: 40, hostKey: "7")
        let inlineRef = HostedCommentRef(kind: .review, id: 80, hostKey: "1")
        func inline(_ position: HostedInlinePosition) async throws -> HostedReviewComment {
            let created = try await client.createInlineComment(at: position, on: 5, in: Self.repo, body: "hi")
            #expect(created.id == 90 && created.path == "a.swift" && created.inReplyToID == nil)
            #expect(created.hostKey == "0" && created.viewerCanEdit && created.viewerCanDelete)
            return created
        }
        let rows: [(requests: [String], body: [String: Any]?, run: () async throws -> Void)] = [
            (["POST " + comments], ["text": "hi", "parent": ["id": 41]], {
                let reply = try await client.reply(
                    toGeneral: HostedCommentRef(kind: .general, id: 41, hostKey: "2"), on: pr, in: Self.repo,
                    body: "hi")
                #expect(reply.id == 90 && reply.parentID == 41 && reply.body == "hi" && reply.hostKey == "0")
                #expect(reply.viewerCanEdit && reply.viewerCanDelete)
            }),
            (["GET " + comments + "/40", "PUT " + comments + "/40"], ["version": 3, "threadResolved": true], {
                let resolved = try await client.setGeneralThread(root, on: pr, in: Self.repo, resolved: true)
                #expect(resolved)
            }),
            (["PUT " + comments + "/40"], ["version": 7, "text": "new"], {
                try await client.editComment(root, on: pr, in: Self.repo, body: "new")
            }),
            (["PUT " + comments + "/80"], ["version": 1, "text": "new"], {
                try await client.editComment(inlineRef, on: pr, in: Self.repo, body: "new")
            }),
            (["PUT " + comments + "/41"], ["version": 2, "text": "new"], {
                await #expect(throws: HostingError.validationFailed(message: stale + " Reload the pull request.")) {
                    try await client.editComment(
                        HostedCommentRef(kind: .general, id: 41, hostKey: "2"), on: pr, in: Self.repo, body: "new")
                }
            }),
            // The description: read first, then its version, title and reviewers sent back with the new text (the
            // answer's version 4 is not kept: a later write reads the pull request again).
            (["GET " + Self.prPath, "PUT " + Self.prPath],
             ["version": 3, "title": "Add feature", "description": "new", "reviewers": [["user": ["name": "rev"]]]], {
                try await client.editDescription(of: pr, in: Self.repo, body: "new")
            }),
            (["DELETE " + comments + "/40?version=7"], nil, {
                try await client.deleteComment(root, on: pr, in: Self.repo)
            }),
            (["DELETE " + comments + "/42?version=0"], nil, {
                await #expect(throws: HostingError.validationFailed(message: hasReplies)) {
                    try await client.deleteComment(
                        HostedCommentRef(kind: .general, id: 42, hostKey: "0"), on: pr, in: Self.repo)
                }
            }),
            (["POST " + comments], [
                "text": "hi",
                "anchor": ["path": "a.swift", "line": 12, "lineType": "ADDED", "fileType": "TO", "diffType": "EFFECTIVE"],
            ], {
                let created = try await inline(
                    .init(path: "a.swift", oldLine: nil, newLine: 12, lineKind: .added, headSHA: Self.head))
                #expect(created.side == "RIGHT" && created.line == 12)
            }),
            (["POST " + comments], [
                "text": "hi",
                "anchor": [
                    "path": "a.swift", "srcPath": "old.swift", "line": 14, "lineType": "CONTEXT", "fileType": "TO",
                    "diffType": "EFFECTIVE",
                ],
            ], {
                let created = try await inline(.init(
                    path: "a.swift", oldPath: "old.swift", oldLine: 10, newLine: 14, lineKind: .context,
                    headSHA: Self.head))
                #expect(created.side == "RIGHT" && created.line == 14)
            }),
            (["POST " + comments], [
                "text": "hi",
                "anchor": [
                    "path": "a.swift", "line": 8, "lineType": "REMOVED", "fileType": "FROM", "diffType": "EFFECTIVE",
                ],
            ], {
                let created = try await inline(.init(
                    path: "a.swift", oldPath: "a.swift", oldLine: 8, newLine: nil, lineKind: .removed,
                    headSHA: Self.head))
                #expect(created.side == "LEFT" && created.line == 8)
            }),
        ]

        for (index, row) in rows.enumerated() {
            let before = stub.requests.count
            try await row.run()
            let sent = Array(stub.requests.dropFirst(before))
            #expect(sent.map { "\($0.httpMethod ?? "") \($0.url?.absoluteString ?? "")" }
                == row.requests.map { request in
                    let parts = request.split(separator: " ", maxSplits: 1)
                    return "\(parts[0]) \(Self.origin)\(parts[1])"
                }, "row \(index)")
            let request = try #require(sent.last)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)", "row \(index)")
            guard let expected = row.body else {
                #expect(request.httpBody?.isEmpty ?? true, "row \(index)")
                continue
            }
            #expect(NSDictionary(dictionary: Self.json(request)).isEqual(to: expected), "row \(index): \(Self.json(request))")
        }

        let issue = HostedItem.issue(3)
        let refusals: [(String, () async throws -> Void)] = [
            ("issue reply", { _ = try await client.reply(toGeneral: root, on: issue, in: Self.repo, body: "hi") }),
            ("issue edit", { try await client.editComment(root, on: issue, in: Self.repo, body: "x") }),
            ("issue description", { try await client.editDescription(of: issue, in: Self.repo, body: "x") }),
            ("review ref reply", { _ = try await client.reply(toGeneral: inlineRef, on: pr, in: Self.repo, body: "hi") }),
            ("review ref resolve", {
                _ = try await client.setGeneralThread(inlineRef, on: pr, in: Self.repo, resolved: true)
            }),
            ("edit without a version", {
                try await client.editComment(HostedCommentRef(kind: .general, id: 40), on: pr, in: Self.repo, body: "x")
            }),
            ("delete without a version", {
                try await client.deleteComment(HostedCommentRef(kind: .general, id: 40), on: pr, in: Self.repo)
            }),
            ("removed without its old line", {
                _ = try await client.createInlineComment(
                    at: .init(path: "a.swift", oldLine: nil, newLine: 4, lineKind: .removed, headSHA: Self.head),
                    on: 5, in: Self.repo, body: "hi")
            }),
            ("a range", {
                _ = try await client.createInlineComment(
                    at: .init(
                        path: "a.swift", oldLine: nil, newLine: 4, lineKind: .added, startNewLine: 2,
                        headSHA: Self.head),
                    on: 5, in: Self.repo, body: "hi")
            }),
            ("a reaction", { try await client.addReaction("+1", to: root, on: pr, in: Self.repo) }),
        ]
        let sent = stub.requests.count
        for (name, run) in refusals {
            await #expect(throws: HostingError.self, "\(name)") { try await run() }
        }
        #expect(stub.requests.count == sent, "a refusal sends nothing")
        let capabilities: HostingCapabilities = [
            .generalReplies, .resolveGeneralThreads, .editComments, .deleteComments, .newInlineComments,
        ]
        #expect(client.capabilities.isSuperset(of: capabilities))
        #expect(client.capabilities.isDisjoint(with: [.reactions, .itemReactions, .multiLineInlineComments]))
        #expect(client.reactionKinds.isEmpty)
    }

    @Test("comment POSTs the text alone and reply the text with the root as parent, each mapped from Data Center's answer")
    func commentAndReply() async throws {
        let stub = StubServer { request in
            guard request.httpMethod == "POST", request.url?.path() == Self.prPath + "/comments" else {
                return Self.notFound
            }
            let parent = (Self.json(request)["parent"] as? [String: Any])?["id"] as? Int
            let text = Self.json(request)["text"] as? String ?? ""
            return .init(status: 201, body: Self.comment(parent == nil ? 77 : 78, text: text, at: Self.t0))
        }
        let client = try Self.client(stub)

        let comment = try await client.comment(on: .pullRequest(5), in: Self.repo, body: "Looks good")
        #expect(comment.id == 77 && comment.body == "Looks good" && comment.parentID == nil)
        #expect(comment.user?.login == "Jane.Doe" && comment.hostKey == "0")
        #expect(comment.viewerCanEdit && comment.viewerCanDelete)
        #expect(comment.createdAt == Date(timeIntervalSince1970: 1_762_077_600))
        let first = Self.json(stub.requests[0])
        #expect(Set(first.keys) == ["text"] && first["text"] as? String == "Looks good")

        let reply = try await client.reply(to: HostedThreadRef(rootCommentID: 10), on: 5, in: Self.repo, body: "Done")
        #expect(reply.id == 78 && reply.inReplyToID == 10 && reply.body == "Done" && reply.hostKey == "0")
        #expect(reply.user?.login == "Jane.Doe" && reply.viewerCanEdit && reply.viewerCanDelete)
        let second = Self.json(stub.requests[1])
        #expect((second["parent"] as? [String: Any])?["id"] as? Int == 10 && second["text"] as? String == "Done")
        #expect(stub.requests.map(\.httpMethod) == ["POST", "POST"])
    }

    /// A Data Center for a review by the token's user (slug `jane.doe`): its status write answers `status`.
    static func reviewServer(status: StubServer.Reply) -> StubServer {
        StubServer { request in
            switch (request.httpMethod ?? "", request.url?.path() ?? "") {
            case ("GET", Self.api + "/application-properties"): Self.properties
            case ("GET", Self.api + "/users"): .init(body: Self.page([Self.me]))
            case ("GET", Self.prPath): .init(body: Self.pullRequest())
            case ("PUT", Self.prPath + "/participants/jane.doe"): status
            case ("POST", Self.prPath + "/comments"): .init(status: 201, body: Self.comment(79, text: "Fix it", at: Self.t0))
            default: Self.notFound
            }
        }
    }

    @Test("requesting changes PUTs NEEDS_WORK with the head as lastReviewedCommit to participants/<slug> (no query), then posts the body")
    func requestChanges() async throws {
        let stub = Self.reviewServer(status: .init(body: """
            {"user": \(Self.me), "role": "PARTICIPANT", "approved": false, "status": "NEEDS_WORK",
             "lastReviewedCommit": "\(Self.head)"}
            """))
        let review = try await Self.client(stub).review(5, in: Self.repo, event: .requestChanges, body: "Fix it")

        #expect(review.state == "CHANGES_REQUESTED" && review.user?.login == "Jane.Doe" && review.body == "Fix it")
        let requests = stub.requests
        #expect(requests.map(\.httpMethod) == ["GET", "GET", "GET", "PUT", "POST"])
        #expect(requests.map { $0.url?.path() } == [
            Self.api + "/application-properties", Self.api + "/users", Self.prPath,
            Self.prPath + "/participants/jane.doe", Self.prPath + "/comments",
        ])
        #expect(requests[3].url?.query() == nil)
        let status = Self.json(requests[3])
        #expect(Set(status.keys) == ["status", "lastReviewedCommit"])
        #expect(status["status"] as? String == "NEEDS_WORK" && status["lastReviewedCommit"] as? String == Self.head)
        let comment = Self.json(requests[4])
        #expect(comment["text"] as? String == "Fix it" && comment["parent"] == nil)
    }

    @Test("a refused review status (400) is validationFailed with Data Center's message, and the body is never posted")
    func refusedReviewPostsNothing() async throws {
        let message = "You cannot approve your own pull request."
        let stub = Self.reviewServer(status: .init(status: 400, body: Self.errors(message)))
        await #expect(throws: HostingError.validationFailed(message: message)) {
            try await Self.client(stub).review(5, in: Self.repo, event: .approve, body: "LGTM")
        }
        let put = stub.requests.first { $0.httpMethod == "PUT" }
        #expect(put?.url?.path() == Self.prPath + "/participants/jane.doe" && put?.url?.query() == nil)
        #expect(put.map { Self.json($0)["status"] as? String } == "APPROVED")
        #expect(!stub.requests.contains { $0.url?.path().hasSuffix("/comments") == true }, "no stray comment")
    }

    @Test("resolving a thread PUTs the root's current version with threadResolved; a 409 is validationFailed with Data Center's message")
    func resolveThreadConflict() async throws {
        let message = "You are attempting to modify a comment based on out-of-date information."
        let commentPath = Self.prPath + "/comments/10"
        let stub = StubServer { request in
            switch (request.httpMethod ?? "", request.url?.path() ?? "") {
            case ("GET", Self.prPath + "/activities"): .init(body: Self.activities)
            case ("GET", commentPath): .init(body: Self.comment(10, version: 2, text: "Edited text", at: Self.t0))
            case ("PUT", commentPath): .init(status: 409, body: Self.errors(message))
            default: Self.notFound
            }
        }
        let client = try Self.client(stub)
        let state = try #require(try await client.reviewThreadStates(of: 5, in: Self.repo).first { $0.id == "10" })

        await #expect(throws: HostingError.validationFailed(message: message)) {
            try await client.setReviewThread(state, resolved: false)
        }
        let requests = stub.requests
        #expect(requests.map(\.httpMethod) == ["GET", "GET", "PUT"])
        #expect(requests.map { $0.url?.path() } == [Self.prPath + "/activities", commentPath, commentPath])
        let body = Self.json(requests[2])
        #expect(Set(body.keys) == ["version", "threadResolved"])
        #expect(body["version"] as? Int == 2 && body["threadResolved"] as? Bool == false)
    }

    @Test("reopening and declining POST with the version just read, as ?version=N and in the body", arguments: [
        (true, "reopen"), (false, "decline"),
    ])
    func reopenAndDecline(open: Bool, action: String) async throws {
        let stub = StubServer { request in
            switch (request.httpMethod ?? "", request.url?.path() ?? "") {
            case ("GET", Self.prPath): .init(body: Self.pullRequest(version: 7, state: open ? "DECLINED" : "OPEN"))
            case ("POST", Self.prPath + "/" + action): .init(body: Self.pullRequest(version: 8))
            default: Self.notFound
            }
        }
        try await Self.client(stub).setOpen(open, item: .pullRequest(5), in: Self.repo)

        let requests = stub.requests
        #expect(requests.map(\.httpMethod) == ["GET", "POST"])
        #expect(requests.last?.url?.path() == Self.prPath + "/" + action)
        #expect(requests.last?.url?.query() == "version=7")
        let body = requests.last.map(Self.json) ?? [:]
        #expect(Set(body.keys) == ["version"] && body["version"] as? Int == 7)
    }

    // MARK: - Page data

    @Test("activities that are not comments map into history entries: approved, requested changes (REVIEWED), a rescope's added and removed commits each with their list, merged, and an unknown action in its own words; comments add none")
    func timelineFromActivities() async throws {
        let other = "1111111111111111111111111111111111111111"
        let rescoped = """
            {"id": 9103, "createdDate": \(Self.t0 + 200_000), "user": \(Self.me), "action": "RESCOPED",
             "fromHash": "\(Self.head)", "previousFromHash": "\(other)",
             "added": {"commits": [{"id": "\(Self.head)", "displayId": "abc123d", "message": "Fix <b>\\nbody"},
                                   {"id": "2222222222222222222222222222222222222222", "displayId": "2222222",
                                    "message": "Two"}], "total": 2},
             "removed": {"commits": [{"id": "\(other)", "displayId": "1111111", "message": "Old"}], "total": 1}}
            """
        let stub = StubServer { request in
            guard request.url?.path() == Self.prPath + "/activities" else { return Self.notFound }
            return .init(body: Self.page([
                #"{"id": 9106, "createdDate": \#(Self.t0 + 500_000), "user": \#(Self.me), "action": "AUTO_MERGE_REQUESTED"}"#,
                #"{"id": 9105, "createdDate": \#(Self.t0 + 400_000), "user": \#(Self.me), "action": "MERGED"}"#,
                #"{"id": 9104, "createdDate": \#(Self.t0 + 300_000), "user": \#(Self.reviewer), "action": "REVIEWED"}"#,
                rescoped,
                Self.commented(9102, "ADDED", Self.comment(40, text: "General", at: Self.t0 + 100_000)),
                #"{"id": 9101, "createdDate": \#(Self.t0), "user": \#(Self.reviewer), "action": "APPROVED"}"#,
            ]))
        }
        let client = try Self.client(stub)
        #expect(client.capabilities.contains(.timelineEvents))

        let events = try await client.timelineEvents(of: .pullRequest(5), in: Self.repo)
        #expect(events.map(\.id) == [
            "activity-9106", "activity-9105", "activity-9104", "activity-9103-added", "activity-9103-removed",
            "activity-9101",
        ])
        #expect(events.map(\.text) == [
            "auto merge requested", "merged", "requested changes", "added 2 commits", "removed 1 commit", "approved",
        ])
        #expect(events.map(\.action) == [
            "auto_merge_requested", "merged", "changes_requested", "commit", "commit", "approved",
        ])
        #expect(events.map { $0.actor?.login } == ["Jane.Doe", "Jane.Doe", "rev", "Jane.Doe", "Jane.Doe", "rev"])
        #expect(events.last?.createdAt == Date(timeIntervalSince1970: 1_762_077_600))
        #expect(events[0].textHTML == "<p>auto merge requested</p>")
        let commitPage = "https://bb.example.com/bitbucket/projects/PROJ/repos/repo/commits/"
        #expect(events[3].detailHTML == "<p><a href=\"\(commitPage)\(Self.head)\">abc123d</a> Fix &lt;b&gt;</p>"
            + "<p><a href=\"\(commitPage)2222222222222222222222222222222222222222\">2222222</a> Two</p>")
        #expect(events[4].detailHTML == "<p>1111111 Old</p>", "a removed commit has no link")
        #expect(events.allSatisfy { $0.detailHTML == nil || $0.action == "commit" })
        #expect(Set(events.map(\.id)).count == events.count)
        await #expect(throws: HostingError.self) { try await client.timelineEvents(of: .issue(5), in: Self.repo) }
    }

    @Test("tasks are blocker comments: read oldest first (open and resolved, on a comment or not), created by POST blocker-comments {text}, resolved and reopened by PUT {version, state} with the version just read, deleted with ?version=N; a 409 is validationFailed with Data Center's message")
    func tasksAsBlockerComments() async throws {
        let blockers = Self.prPath + "/blocker-comments"
        let stale = "You are attempting to modify a comment based on out-of-date information."
        let late = """
            {"id": 61, "version": 2, "text": "Add tests", "author": \(Self.reviewer), "createdDate": \(Self.t0 + 60_000),
             "severity": "BLOCKER", "state": "RESOLVED", "parent": {"id": 40}, "resolvedDate": \(Self.t0 + 120_000),
             "resolver": \(Self.me)}
            """
        let early = """
            {"id": 60, "version": 0, "text": "Fix docs", "author": \(Self.me), "createdDate": \(Self.t0),
             "severity": "BLOCKER", "state": "OPEN"}
            """
        let stub = StubServer { request in
            switch (request.httpMethod ?? "", request.url?.path() ?? "") {
            case ("GET", blockers): return .init(body: Self.page([late, early]))
            case ("GET", blockers + "/61"): return .init(body: late)
            case ("GET", blockers + "/62"):
                return .init(body: #"{"id": 62, "version": 5, "text": "x", "severity": "BLOCKER", "state": "OPEN"}"#)
            case ("PUT", blockers + "/62"): return .init(status: 409, body: Self.errors(stale))
            case ("PUT", blockers + "/61"):
                let state = Self.json(request)["state"] as? String ?? ""
                return .init(body: late.replacingOccurrences(of: "\"RESOLVED\"", with: "\"\(state)\""))
            case ("POST", blockers):
                let text = Self.json(request)["text"] as? String ?? ""
                return .init(status: 201, body: """
                    {"id": 63, "version": 0, "text": "\(text)", "author": \(Self.me), "createdDate": \(Self.t0),
                     "severity": "BLOCKER", "state": "OPEN"}
                    """)
            case ("DELETE", blockers + "/61"): return .init(status: 204, body: "")
            default: return Self.notFound
            }
        }
        let client = try Self.client(stub)
        #expect(client.capabilities.contains(.tasks))

        let tasks = try await client.tasks(of: 5, in: Self.repo)
        #expect(tasks.map(\.id) == [60, 61])
        #expect(tasks.map(\.body) == ["Fix docs", "Add tests"])
        #expect(tasks.map(\.isResolved) == [false, true])
        #expect(tasks.map(\.commentID) == [nil, 40])
        #expect(tasks.map { $0.creator?.login } == ["Jane.Doe", "rev"])
        #expect(tasks[1].resolvedBy?.login == "Jane.Doe")
        #expect(tasks[1].resolvedAt == Date(timeIntervalSince1970: 1_762_077_720))
        #expect(tasks[0].resolvedAt == nil && tasks[0].resolvedBy == nil)

        let created = try await client.createTask(on: 5, in: Self.repo, body: "Ship it")
        #expect(created.id == 63 && created.body == "Ship it" && !created.isResolved && created.commentID == nil)
        try await client.setTask(61, resolved: true, on: 5, in: Self.repo)
        try await client.setTask(61, resolved: false, on: 5, in: Self.repo)
        try await client.deleteTask(61, on: 5, in: Self.repo)
        await #expect(throws: HostingError.validationFailed(message: stale)) {
            try await client.setTask(62, resolved: true, on: 5, in: Self.repo)
        }

        let writes = Array(stub.requests.dropFirst())
        #expect(writes.map { "\($0.httpMethod ?? "") \($0.url?.absoluteString ?? "")" } == [
            "POST \(Self.origin)\(blockers)",
            "GET \(Self.origin)\(blockers)/61", "PUT \(Self.origin)\(blockers)/61",
            "GET \(Self.origin)\(blockers)/61", "PUT \(Self.origin)\(blockers)/61",
            "GET \(Self.origin)\(blockers)/61", "DELETE \(Self.origin)\(blockers)/61?version=2",
            "GET \(Self.origin)\(blockers)/62", "PUT \(Self.origin)\(blockers)/62",
        ])
        #expect(NSDictionary(dictionary: Self.json(writes[0])).isEqual(to: ["text": "Ship it"]))
        #expect(NSDictionary(dictionary: Self.json(writes[2])).isEqual(to: ["version": 2, "state": "RESOLVED"]))
        #expect(NSDictionary(dictionary: Self.json(writes[4])).isEqual(to: ["version": 2, "state": "OPEN"]))
        #expect(writes[6].httpBody?.isEmpty ?? true)
        #expect(NSDictionary(dictionary: Self.json(writes[8])).isEqual(to: ["version": 5, "state": "RESOLVED"]))
        #expect(stub.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)" })
    }

    @Test("merge checks: one failing, blocking check per veto (its summary) and Conflicts when conflicted; a pull request that is not open (409) has none")
    func mergeChecksFromVetoes() async throws {
        let stub = StubServer { request in
            switch request.url?.path() ?? "" {
            case Self.prPath + "/merge":
                .init(body: """
                    {"canMerge": false, "conflicted": true, "outcome": "CONFLICTED", "vetoes": [
                     {"summaryMessage": "Not all required builds are successful yet", "detailedMessage": "1 of 2"},
                     {"summaryMessage": "Requires approvals", "detailedMessage": "You need 2 approvals"}]}
                    """)
            case Self.api + "/projects/PROJ/repos/repo/pull-requests/6/merge":
                .init(status: 409, body: Self.errors("The pull request is not open"))
            default: Self.notFound
            }
        }
        let client = try Self.client(stub)
        #expect(client.capabilities.contains(.mergeChecks))

        let checks = try await client.mergeChecks(of: 5, in: Self.repo)
        #expect(checks == [
            HostedMergeCheck(
                name: "Not all required builds are successful yet", status: "FAILED", required: true, blocking: true),
            HostedMergeCheck(name: "Requires approvals", status: "FAILED", required: true, blocking: true),
            HostedMergeCheck(name: "Conflicts", status: "FAILED", required: true, blocking: true),
        ])
        #expect(try await client.mergeChecks(of: 6, in: Self.repo).isEmpty)
        #expect(stub.requests.map(\.httpMethod) == ["GET", "GET"])
    }

    /// A Data Center whose pull request #5 is from `source` (the destination by default), whose settings answer
    /// `settings`, whose merge answers 200 and whose branch delete answers `delete`.
    static func strategyServer(
        settings: StubServer.Reply, source: (key: String, slug: String)? = nil,
        delete: StubServer.Reply = .init(status: 204, body: "")
    ) -> StubServer {
        StubServer { request in
            switch (request.httpMethod ?? "", request.url?.path() ?? "") {
            case ("GET", Self.prPath): .init(body: Self.pullRequest(source: source))
            case ("GET", Self.repoPath + "/settings/pull-requests"): settings
            case ("POST", Self.prPath + "/merge"): .init(body: Self.pullRequest(version: 4, state: "MERGED"))
            case ("DELETE", _): delete
            default: Self.notFound
            }
        }
    }

    /// Settings with `no-ff`, `squash`, `ff-only` and an id Histq does not know enabled, `rebase-no-ff` not, and
    /// `default` the default.
    static func settings(default id: String = "squash") -> StubServer.Reply {
        .init(body: """
            {"mergeConfig": {"type": "REPOSITORY", "defaultStrategy": {"id": "\(id)", "name": "Default"},
             "strategies": [
              {"id": "no-ff", "name": "Merge commit", "enabled": true},
              {"id": "squash", "name": "Squash", "enabled": true},
              {"id": "custom-x", "name": "Custom", "enabled": true},
              {"id": "rebase-no-ff", "name": "Rebase, merge", "enabled": false},
              {"id": "ff-only", "name": "Fast-forward only", "enabled": true}]},
             "requiredApprovers": 0}
            """)
    }

    @Test("the detail's allowed merge methods are the repository's enabled strategies in Data Center's order (an unknown id dropped) with its default; settings Histq cannot read (403) leave both nil and the detail still loads", arguments: [
        (200, "squash", [HostedMergeMethod.merge, .squash, .fastForward] as [HostedMergeMethod]?,
         HostedMergeMethod.squash as HostedMergeMethod?),
        (200, "rebase-no-ff", [.merge, .squash, .fastForward], nil),
        (403, "squash", nil, nil),
    ])
    func mergeStrategiesOfTheDetail(
        status: Int, defaultID: String, allowed: [HostedMergeMethod]?, preferred: HostedMergeMethod?
    ) async throws {
        let settings = status == 200
            ? Self.settings(default: defaultID)
            : StubServer.Reply(status: status, body: Self.errors("You are not permitted to access this resource"))
        let stub = Self.strategyServer(settings: settings)
        let pull = try await Self.client(stub).pullRequest(5, in: Self.repo)

        #expect(pull.number == 5 && pull.title == "Add feature")
        #expect(pull.allowedMergeMethods == allowed)
        #expect(pull.defaultMergeMethod == preferred)
        #expect(stub.requests.map { $0.url?.path() } == [Self.prPath, Self.repoPath + "/settings/pull-requests"])
    }

    @Test("a merge sends the method's strategy id when the repository enables it (ff-only for fastForward); a method it does not enable, or one outside mergeMethods when the strategies cannot be read, is refused unsent", arguments: [
        (HostedMergeMethod.fastForward, true, "ff-only" as String?),
        (.squash, true, "squash"),
        (.rebase, true, nil),
        (.fastForward, false, nil),
        (.rebase, false, "rebase-no-ff"),
    ])
    func mergeChecksTheEnabledStrategies(method: HostedMergeMethod, readable: Bool, sent: String?) async throws {
        let settings = readable ? Self.settings() : StubServer.Reply(status: 401, body: Self.errors("Unauthorized"))
        let stub = Self.strategyServer(settings: settings)
        let client = try Self.client(stub)

        if let sent {
            try await client.merge(5, in: Self.repo, method: method, sha: Self.head)
            let post = try #require(stub.requests.last)
            #expect(post.httpMethod == "POST" && post.url?.path() == Self.prPath + "/merge")
            #expect(Self.json(post)["strategyId"] as? String == sent)
        } else {
            await #expect(throws: HostingError.self) {
                try await client.merge(5, in: Self.repo, method: method, sha: Self.head)
            }
            #expect(!stub.requests.contains { $0.httpMethod != "GET" }, "nothing written")
        }
    }

    @Test("merging with deleteSourceBranch DELETEs the branch through branch-utils in the SOURCE repository (as Data Center names it) with the head read before the merge as endPoint; a refused delete keeps the merge; a false option deletes nothing", arguments: [
        (true, 204), (true, 400), (false, 204),
    ])
    func mergeDeletesTheSourceBranch(deletes: Bool, deleteStatus: Int) async throws {
        let delete = StubServer.Reply(
            status: deleteStatus, body: deleteStatus == 204 ? "" : Self.errors("The branch has changed"))
        let stub = Self.strategyServer(settings: Self.settings(), source: ("proj", "Repo"), delete: delete)
        let client = try Self.client(stub)
        #expect(client.supportedMergeOptions == [.deleteSourceBranch])

        try await client.merge(
            5, in: Self.repo, method: .merge, sha: String(Self.head.prefix(12)),
            options: HostedMergeOptions(deleteSourceBranch: deletes))

        let requests = stub.requests
        #expect(requests.map(\.httpMethod) == ["GET", "GET", "POST"] + (deletes ? ["DELETE"] : []))
        guard deletes else { return }
        let request = try #require(requests.last)
        #expect(request.url?.absoluteString
            == Self.origin + "/bitbucket/rest/branch-utils/latest/projects/proj/repos/Repo/branches")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
        #expect(NSDictionary(dictionary: Self.json(request)).isEqual(to: [
            "name": "refs/heads/feature", "endPoint": Self.head, "dryRun": false,
        ]))
        for request in requests {
            #expect(request.url?.absoluteString.hasPrefix(Self.origin + "/bitbucket/rest/") == true)
            #expect(request.url?.absoluteString.contains(Self.token) == false)
        }
    }

    @Test("deleteSourceBranch on a pull request from a fork is refused unsent: neither the merge nor a delete is sent")
    func forkRefusesDeletingTheSourceBranch() async throws {
        let stub = Self.strategyServer(settings: Self.settings(), source: ("~JANE", "repo"))
        let client = try Self.client(stub)

        await #expect(throws: HostingError.self) {
            try await client.merge(
                5, in: Self.repo, method: .merge, sha: Self.head, options: HostedMergeOptions(deleteSourceBranch: true))
        }
        #expect(stub.requests.map(\.httpMethod) == ["GET"])
        try await client.merge(5, in: Self.repo, method: .merge, sha: Self.head, options: HostedMergeOptions())
        #expect(stub.requests.map(\.httpMethod) == ["GET", "GET", "GET", "POST"], "positive control: a fork merges")
    }
}
