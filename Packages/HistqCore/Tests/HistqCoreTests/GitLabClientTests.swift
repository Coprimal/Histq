// Contract tests for the GitLab client, served by `StubServer` (GitHubClientTests.swift) with inline JSON: no test
// reaches the network. They guard the token (only in the `Authorization` header, only under the API's origin and base
// path, refreshed once after a 401) and the mapping of a merge request's threads into the hosted models.
import Foundation
import HistqCore
import Synchronization
import Testing

struct GitLabClientTests {
    /// Made-up tokens; the tests look for them where they must never be.
    static let token = "histq-fake-fresh-0123456789"
    static let staleToken = "histq-fake-stale-0123456789"

    static let api = "https://git.example.com/gitlab/api/v4"

    static func user(_ id: Int, _ username: String) -> String {
        #"{"id": \#(id), "username": "\#(username)", "name": "User \#(id)", "avatar_url": "https://git.example.com/a/\#(id).png", "web_url": "https://git.example.com/gitlab/\#(username)"}"#
    }

    /// Counts a provider's forced refreshes.
    final class Refreshes: Sendable {
        let count = Mutex(0)
    }

    /// A client of a GitLab under `https://git.example.com/gitlab` whose provider hands out `staleToken` until it is
    /// told that token was refused, then `token`. Any other refused token is counted as wrong.
    static func client(_ stub: StubServer, refreshes: Refreshes = Refreshes()) throws -> GitLabClient {
        try GitLabClient(host: "git.example.com", basePath: "/gitlab/", session: stub.session) { rejected in
            refreshes.count.withLock { count in
                if let rejected { count += rejected == Self.staleToken ? 1 : 1000 }
                return count > 0 ? Self.token : Self.staleToken
            }
        }
    }

    // MARK: - Token

    @Test("the token goes only in the Authorization header, only under the API's origin and base path; a 401 refreshes it once and retries")
    func tokenOnlyUnderAPIBase() async throws {
        @Sendable func project(_ id: Int, _ path: String, _ visibility: String) -> String {
            """
            {"id": \(id), "name": "Name \(id)", "path_with_namespace": "\(path)", "visibility": "\(visibility)",
             "http_url_to_repo": "https://git.example.com/gitlab/\(path).git",
             "namespace": {"id": \(id * 10), "full_path": "\(path.split(separator: "/").dropLast().joined(separator: "/"))"}}
            """
        }
        let stub = StubServer { request in
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)" else {
                return .init(status: 401, body: #"{"message": "401 Unauthorized"}"#)
            }
            if request.url?.path() == "/gitlab/api/v4/user" { return .init(body: Self.user(7, "me")) }
            if request.url?.query()?.contains("page=2") == true {
                return .init(body: "[\(project(2, "acme/tools", "public"))]")
            }
            let page2 = "\(Self.api)/projects?membership=true&simple=true&per_page=100&page=2"
            return .init(
                headers: ["Link": "<\(page2)>; rel=\"next\""],
                body: "[\(project(1, "group/sub/proj", "private"))]")
        }
        let refreshes = Refreshes()
        let client = try Self.client(stub, refreshes: refreshes)

        #expect(try await client.currentUser().login == "me")
        let repos = try await client.userRepositories()

        #expect(refreshes.count.withLock { $0 } == 1)
        #expect(repos.map(\.fullName) == ["acme/tools", "group/sub/proj"])
        #expect(repos.map(\.name) == ["tools", "proj"])
        #expect(repos.map(\.owner.login) == ["acme", "group/sub"])
        #expect(repos.map(\.isPrivate) == [false, true])
        let requests = stub.requests
        #expect(requests.map { $0.url?.path() } == [
            "/gitlab/api/v4/user", "/gitlab/api/v4/user", "/gitlab/api/v4/projects", "/gitlab/api/v4/projects",
        ])
        let firstIsStale = requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.staleToken)"
        #expect(firstIsStale)
        #expect(requests.first { $0.url?.path() == "/gitlab/api/v4/projects" }?.url?.query()?
            .contains("membership=true") == true)
        for request in requests.dropFirst() {
            let carriesFresh = request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)"
            #expect(carriesFresh)
        }
        for request in requests {
            #expect(request.url?.host() == "git.example.com")
            #expect(request.url?.absoluteString.contains(Self.token) == false)
            #expect(request.url?.absoluteString.contains(Self.staleToken) == false)
        }
        #expect(!String(describing: client).contains(Self.token))
        #expect(!String(reflecting: client).contains(Self.token))
    }

    @Test("a 401 after the forced refresh is unauthorized: one retry only")
    func secondUnauthorizedStops() async throws {
        let stub = StubServer { _ in .init(status: 401, body: #"{"message": "401 Unauthorized"}"#) }
        let refreshes = Refreshes()
        let client = try Self.client(stub, refreshes: refreshes)

        await #expect(throws: HostingError.unauthorized) { try await client.currentUser() }
        #expect(stub.requests.count == 2)
        #expect(refreshes.count.withLock { $0 } == 1)
    }

    @Test("a next-page link outside the API's origin or base path is refused, so the token never goes there", arguments: [
        "https://evil.example/gitlab/api/v4/projects?page=2",
        "https://git.example.com/other/api/v4/projects?page=2",
        "https://git.example.com/gitlab/api/v4evil/projects?page=2",
        "https://git.example.com/gitlab/api/v4/../../x?page=2",
        "http://git.example.com/gitlab/api/v4/projects?page=2",
        "https://git.example.com/gitlab/api/graphql?page=2",
        "https://git.example.com/gitlab/api/graphqlx?page=2",
        "https://git.example.com/gitlab/api/other?page=2",
    ])
    func paginationRefusesOutsideAPIBase(next: String) async throws {
        let stub = StubServer { _ in .init(headers: ["Link": "<\(next)>; rel=\"next\""], body: "[]") }
        let client = try Self.client(stub)

        await #expect(throws: HostingError.invalidResponse("a next-page link to another host")) {
            try await client.labels(in: HostedRepository(host: "git.example.com", path: ["group", "proj"]))
        }
        #expect(stub.requests.count == 1)
        #expect(stub.requests.allSatisfy { $0.url?.path(percentEncoded: true) == "/gitlab/api/v4/projects/group%2Fproj/labels" })
    }

    @Test("a redirect to another host is not followed (one under the API is)", arguments: [
        ("https://git.example.com/gitlab/api/v4/moved", true), ("https://evil.example/user", false),
    ])
    func redirectToOtherOriginIsNotFollowed(target: String, isFollowed: Bool) async throws {
        let stub = StubServer { request in
            if request.url?.path() == "/gitlab/api/v4/user" {
                return .init(status: 302, headers: ["Location": target], body: "", redirect: URL(string: target))
            }
            return .init(body: Self.user(9, "moved"))
        }
        let client = try GitLabClient(host: "git.example.com", basePath: "gitlab", session: stub.session) { _ in
            Self.token
        }

        if isFollowed {
            #expect(try await client.currentUser().login == "moved", "positive control: the stub redirects")
            #expect(stub.requests.map { $0.url?.path() } == ["/gitlab/api/v4/user", "/gitlab/api/v4/moved"])
            let carriesToken = stub.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)"
            #expect(carriesToken, "URLSession drops the header on a redirect: the guard puts it back on one it follows")
        } else {
            await #expect(throws: HostingError.self) { try await client.currentUser() }
            #expect(stub.requests.map { $0.url?.absoluteString } == ["https://git.example.com/gitlab/api/v4/user"])
        }
    }

    @Test("a base path or host that is not plain is refused", arguments: ["../x", "a/../b", "a b", "a?b", "a//b"])
    func basePathIsValidated(basePath: String) {
        #expect(throws: HostingError.self) {
            try GitLabClient(host: "git.example.com", basePath: basePath) { _ in Self.token }
        }
    }

    // MARK: - Mapping

    @Test("a merge request, alone and in the open list, maps with its merge status, comments skip system and diff notes, and discussions become threads with sides, lines, hunks and resolved states")
    func mergeRequestAndThreads() async throws {
        let head = "aaaa1111"
        let mr = """
            {"id": 9005, "iid": 5, "title": "Add feature", "description": "Body", "description_html": "<p>Body</p>",
             "state": "opened", "draft": true, "author": \(Self.user(7, "me")), "assignees": [],
             "reviewers": [\(Self.user(8, "rev"))], "labels": ["bug"],
             "web_url": "https://git.example.com/gitlab/group/sub/proj/-/merge_requests/5",
             "source_branch": "feature", "target_branch": "main", "sha": "\(head)",
             "diff_refs": {"base_sha": "cccc", "head_sha": "\(head)", "start_sha": "dddd"},
             "created_at": "2026-11-01T10:00:00.123Z", "detailed_merge_status": "conflict", "changes_count": "1"}
            """
        @Sendable func note(
            _ id: Int, type: String?, system: Bool = false, resolved: Bool? = nil, position: String? = nil,
            minute: Int
        ) -> String {
            let resolvable = resolved == nil ? "false" : "true"
            return """
                {"id": \(id), "type": \(type.map { "\"\($0)\"" } ?? "null"), "body": "note **\(id)**",
                 "author": \(Self.user(id, "u\(id)")), "created_at": "2026-11-02T10:\(minute):00.000+00:00",
                 "system": \(system), "resolvable": \(resolvable), "resolved": \(resolved ?? false)
                 \(position.map { #", "position": \#($0)"# } ?? "")}
                """
        }
        @Sendable func position(old: Int?, new: Int?, head: String = head) -> String {
            """
            {"head_sha": "\(head)", "old_path": "src/app.swift", "new_path": "src/app.swift", "position_type": "text",
             "old_line": \(old.map(String.init) ?? "null"), "new_line": \(new.map(String.init) ?? "null")}
            """
        }
        let added = position(old: nil, new: 2)
        let removed = position(old: 2, new: nil)
        let outdated = position(old: 1, new: 1, head: "bbbb2222")
        let discussions = """
            [{"id": "6a9c1750b37d513a43987b574953fceb50b03ce7", "individual_note": false, "notes": [
               \(note(10, type: "DiffNote", resolved: true, position: added, minute: 10)),
               \(note(11, type: "DiffNote", resolved: true, position: added, minute: 11))]},
             {"id": "87805b7c09016a7058e91bdbe7b29d1f284a39e6", "individual_note": false, "notes": [
               \(note(20, type: "DiffNote", resolved: false, position: removed, minute: 20))]},
             {"id": "1f2e3d4c5b6a79881f2e3d4c5b6a79881f2e3d4c", "individual_note": false, "notes": [
               \(note(40, type: "DiffNote", resolved: false, position: outdated, minute: 40))]},
             {"id": "0000000000000000000000000000000000000030", "individual_note": true, "notes": [
               \(note(30, type: nil, minute: 30))]},
             {"id": "0000000000000000000000000000000000000031", "individual_note": true, "notes": [
               \(note(31, type: nil, system: true, minute: 31))]}]
            """
        let notes = """
            [\(note(10, type: "DiffNote", resolved: true, position: added, minute: 10)),
             \(note(30, type: nil, minute: 30)), \(note(31, type: nil, system: true, minute: 31))]
            """
        let diffs = #"""
            [{"old_path": "src/app.swift", "new_path": "src/app.swift", "a_mode": "100644", "b_mode": "100644",
              "diff": "@@ -1,3 +1,3 @@\n line one\n-old two\n+new two\n line three\n", "new_file": false,
              "renamed_file": false, "deleted_file": false, "collapsed": false, "too_large": false}]
            """#
        let approvals = #"{"approved": true, "approved_by": [{"user": \#(Self.user(8, "rev")), "approved_at": "2026-11-03T10:00:00Z"}]}"#
        let reviewers = """
            [{"user": \(Self.user(8, "rev")), "state": "reviewed", "created_at": "2026-11-01T10:00:00Z"},
             {"user": \(Self.user(9, "other")), "state": "requested_changes", "created_at": "2026-11-01T10:00:00Z"},
             {"user": \(Self.user(12, "waiting")), "state": "unreviewed", "created_at": "2026-11-01T10:00:00Z"}]
            """
        let stub = StubServer { request in
            let prefix = "/gitlab/api/v4/projects/group%2Fsub%2Fproj/merge_requests/5"
            let path = request.url?.path(percentEncoded: true) ?? ""
            let body = switch path {
            case "/gitlab/api/v4/projects/group%2Fsub%2Fproj/merge_requests": "[\(mr)]"
            case prefix: mr
            case prefix + "/discussions": discussions
            case prefix + "/notes": notes
            case prefix + "/diffs": diffs
            case prefix + "/approvals": approvals
            case prefix + "/reviewers": reviewers
            default: ""
            }
            return body.isEmpty ? .init(status: 404, body: #"{"message": "404 Not Found"}"#) : .init(body: body)
        }
        let client = try GitLabClient(host: "git.example.com", basePath: "gitlab", session: stub.session) { _ in
            Self.token
        }
        let repo = try #require(
            GitLabClient.repository(fromRemoteURL: "https://git.example.com/gitlab/group/sub/proj.git", basePath: "gitlab"))
        #expect(repo.path == ["group", "sub", "proj"])

        let pull = try await client.pullRequest(5, in: repo)
        #expect(pull.number == 5 && pull.state == "open" && pull.draft == true)
        #expect(pull.mergeableState == "dirty" && pull.mergeable == false)
        #expect(pull.bodyHTML == "<p>Body</p>")
        #expect(pull.head.ref == "feature" && pull.head.sha == head && pull.base.ref == "main")
        #expect(pull.labels?.map(\.name) == ["bug"] && pull.labels?.first?.color == nil, "a single MR's labels are names")
        #expect(pull.requestedReviewers?.map(\.login) == ["rev"])
        #expect(abs((pull.createdAt?.timeIntervalSince1970 ?? 0) - 1_793_527_200.123) < 0.001, "fractional seconds")
        #expect(client.checkout(of: pull) == .ref("merge-requests/5/head"))
        #expect(stub.requests.first?.url?.query()?.contains("render_html=true") == true)

        let listed = try await client.pullRequests(in: repo, state: .open)
        #expect(listed.map(\.number) == [5] && listed.first?.state == "open" && listed.first?.draft == true)
        #expect(listed.first?.mergeableState == "dirty")
        #expect(stub.requests.last?.url?.query()?.contains("state=opened") == true)

        let comments = try await client.comments(on: .pullRequest(5), in: repo)
        #expect(comments.map(\.id) == [30], "no system note, no diff note")
        #expect(comments.first?.bodyHTML?.contains("<strong>30</strong>") == true)
        #expect(comments.first?.htmlURL == "https://git.example.com/gitlab/group/sub/proj/-/merge_requests/5#note_30")

        let reviewComments = try await client.reviewComments(of: 5, in: repo)
        let byID = Dictionary(uniqueKeysWithValues: reviewComments.map { ($0.id, $0) })
        #expect(Set(byID.keys) == [10, 11, 20, 40])
        #expect(byID[10]?.side == "RIGHT" && byID[10]?.line == 2 && byID[10]?.inReplyToID == nil)
        #expect(byID[10]?.diffHunk == "@@ -1,3 +1,3 @@\n line one\n-old two\n+new two")
        #expect(byID[11]?.inReplyToID == 10)
        #expect(byID[20]?.side == "LEFT" && byID[20]?.line == 2)
        #expect(byID[20]?.diffHunk == "@@ -1,3 +1,3 @@\n line one\n-old two")
        #expect(byID[40]?.side == "RIGHT" && byID[40]?.line == nil && byID[40]?.originalLine == 1)
        #expect(byID[40]?.diffHunk == nil, "an outdated position gets no hunk from the current diff")

        let states = try await client.reviewThreadStates(of: 5, in: repo)
        let byRoot = Dictionary(uniqueKeysWithValues: states.compactMap { state in state.rootCommentID.map { ($0, state) } })
        #expect(byRoot[10]?.id == "6a9c1750b37d513a43987b574953fceb50b03ce7")
        #expect(byRoot[10]?.isResolved == true && byRoot[10]?.isOutdated == false)
        #expect(byRoot[20]?.isResolved == false)
        #expect(byRoot[40]?.isOutdated == true)

        let grouped = HostedReviewThread.group(reviewComments, states: states)
        #expect(grouped.threadsByReview.isEmpty)
        #expect(grouped.unattached.map(\.id) == [10, 20, 40])
        #expect(grouped.unattached.map(\.comments.count) == [2, 1, 1])
        #expect(grouped.unattached.map { $0.state?.isResolved } == [true, false, false])

        let reviews = try await client.reviews(of: 5, in: repo)
        #expect(reviews.map(\.user?.login) == ["rev", "other"])
        #expect(reviews.map(\.state) == ["APPROVED", "CHANGES_REQUESTED"])
        #expect(Set(reviews.map(\.id)).count == reviews.count)
        #expect(Set(reviews.map(\.id)).isDisjoint(with: Set(comments.map(\.id) + reviewComments.map(\.id))))

        for request in stub.requests {
            #expect(request.url?.path(percentEncoded: true).hasPrefix("/gitlab/api/v4/projects/group%2Fsub%2Fproj/") == true)
            let carriesToken = request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)"
            #expect(carriesToken)
        }
    }

    @Test("checks of a head sha: its open merge request's source-branch statuses, plus the head pipeline when that list misses it")
    func checkRunsOfHead() async throws {
        let mr = """
            {"id": 9005, "iid": 5, "title": "T", "state": "opened", "web_url": "https://git.example.com/gitlab/g/p/-/merge_requests/5",
             "source_branch": "feature", "target_branch": "main", "sha": "abc1",
             "head_pipeline": {"id": 77, "status": "running", "ref": "refs/merge-requests/5/head", "sha": "abc1",
                               "web_url": "https://git.example.com/gitlab/g/p/-/pipelines/77"}}
            """
        let statuses = """
            [{"id": 91, "name": "test", "status": "failed", "allow_failure": false, "started_at": "2026-11-02T10:00:00.000Z"},
             {"id": 92, "name": "lint", "status": "failed", "allow_failure": true},
             {"id": 93, "name": "deploy", "status": "manual"}]
            """
        let stub = StubServer { request in
            let path = request.url?.path(percentEncoded: true) ?? ""
            let base = "/gitlab/api/v4/projects/g%2Fp"
            if path == base + "/merge_requests" { return .init(body: "[\(mr)]") }
            if path == base + "/merge_requests/5" { return .init(body: mr) }
            if path == base + "/repository/commits/abc1/statuses" { return .init(body: statuses) }
            return .init(status: 404, body: "{}")
        }
        let client = try GitLabClient(host: "git.example.com", basePath: "gitlab", session: stub.session) { _ in
            Self.token
        }
        let repo = HostedRepository(host: "git.example.com", path: ["g", "p"])

        let runs = try await client.checkRuns(for: "abc1", in: repo)

        #expect(runs.map(\.name) == ["Pipeline #77", "test", "lint", "deploy"])
        #expect(runs.map(\.status) == ["in_progress", "completed", "completed", "completed"])
        #expect(runs.map(\.conclusion) == [nil, "failure", "neutral", "manual"])
        #expect(Set(runs.map(\.id)).count == runs.count)
        #expect(stub.requests.contains { $0.url?.query()?.contains("ref=feature") == true })
        #expect(try await client.checkRuns(for: "ffff", in: repo).isEmpty, "no open merge request has that head")
    }

    @Test("a merged-results head pipeline (its sha the temporary merge commit) is shown while the merge request's head is the ref; a + in the branch is %2B")
    func checkRunsOfMergedResultsPipeline() async throws {
        let mr = """
            {"id": 9005, "iid": 5, "title": "T", "state": "opened", "web_url": "https://git.example.com/gitlab/g/p/-/merge_requests/5",
             "source_branch": "feat+x", "target_branch": "main", "sha": "abc1",
             "head_pipeline": {"id": 77, "status": "success", "ref": "refs/merge-requests/5/merge", "sha": "e1e1",
                               "web_url": "https://git.example.com/gitlab/g/p/-/pipelines/77"}}
            """
        let stub = StubServer { request in
            let path = request.url?.path(percentEncoded: true) ?? ""
            let base = "/gitlab/api/v4/projects/g%2Fp"
            if path == base + "/merge_requests" { return .init(body: "[\(mr)]") }
            if path == base + "/merge_requests/5" { return .init(body: mr) }
            if path == base + "/repository/commits/abc1/statuses" { return .init(body: "[]") }
            return .init(status: 404, body: "{}")
        }
        let client = try GitLabClient(host: "git.example.com", basePath: "gitlab", session: stub.session) { _ in
            Self.token
        }
        let repo = HostedRepository(host: "git.example.com", path: ["g", "p"])

        let runs = try await client.checkRuns(for: "abc1", in: repo)

        #expect(runs.map(\.name) == ["Pipeline #77"])
        #expect(runs.map(\.conclusion) == ["success"])
        let statusesQuery = stub.requests.first { $0.url?.path().hasSuffix("/statuses") == true }?.url?.query()
        #expect(statusesQuery?.contains("ref=feat%2Bx") == true)
    }

    @Test("detailed_merge_status maps to a conflict-only mergeable and GitHub's mergeable_state words", arguments: [
        ("mergeable", true, "clean"), ("conflict", false, "dirty"), ("ci_still_running", true, "blocked"),
        ("ci_must_pass", true, "blocked"), ("not_approved", true, "blocked"), ("need_rebase", true, "behind"),
        ("draft_status", true, "draft"), ("checking", nil, "unknown"),
    ] as [(String, Bool?, String)])
    func mergeStatusMapping(status: String, mergeable: Bool?, state: String) async throws {
        let mr = """
            {"id": 9005, "iid": 5, "title": "T", "state": "opened", "web_url": "https://git.example.com/gitlab/g/p/-/merge_requests/5",
             "source_branch": "feature", "target_branch": "main", "sha": "abc1", "detailed_merge_status": "\(status)"}
            """
        let stub = StubServer { request in
            request.url?.path(percentEncoded: true) == "/gitlab/api/v4/projects/g%2Fp/merge_requests/5"
                ? .init(body: mr) : .init(status: 404, body: "{}")
        }
        let client = try GitLabClient(host: "git.example.com", basePath: "gitlab", session: stub.session) { _ in
            Self.token
        }

        let pull = try await client.pullRequest(5, in: HostedRepository(host: "git.example.com", path: ["g", "p"]))

        #expect(pull.mergeable == mergeable)
        #expect(pull.mergeableState == state)
    }

    @Test("web URLs keep GitLab's layout under the base path; none for another host, a dot segment or a sha that is not hex")
    func webURLs() throws {
        let client = try GitLabClient(host: "git.example.com", basePath: "gitlab") { _ in Self.token }
        let repo = HostedRepository(host: "git.example.com", path: ["group", "sub", "proj"])
        let base = "https://git.example.com/gitlab/group/sub/proj"
        #expect(client.webURL(.repository, in: repo)?.absoluteString == base)
        #expect(client.webURL(.branch("feat/x y"), in: repo)?.absoluteString == base + "/-/tree/feat/x%20y")
        #expect(client.webURL(.commit("abc123"), in: repo)?.absoluteString == base + "/-/commit/abc123")
        #expect(client.webURL(.pullRequest(5), in: repo)?.absoluteString == base + "/-/merge_requests/5")
        #expect(client.webURL(.issue(6), in: repo)?.absoluteString == base + "/-/issues/6")
        #expect(client.webURL(.repository, in: HostedRepository(host: "gitlab.com", path: ["group", "proj"])) == nil)
        #expect(client.webURL(.branch("a/../b"), in: repo) == nil)
        #expect(client.webURL(.commit("abc;x"), in: repo) == nil)
    }

    @Test("remote URLs resolve to the whole project path, the base path stripped from https ones")
    func remoteURLs() {
        #expect(GitLabClient.repository(fromRemoteURL: "https://gitlab.com/group/sub/proj.git")?.path
            == ["group", "sub", "proj"])
        #expect(GitLabClient.repository(fromRemoteURL: "git@git.example.com:group/proj.git", basePath: "gitlab")?.path
            == ["group", "proj"])
        #expect(GitLabClient.repository(fromRemoteURL: "https://git.example.com/other/group/proj.git", basePath: "gitlab")?
            .path == nil)
        #expect(GitLabClient.repository(fromRemoteURL: "https://gitlab.com/proj.git") == nil)
    }

    /// The stub's redirect drops `Authorization`, as URLSession's does: the followed one (the positive control) has
    /// it back from the guard, and a refused one must reach nothing.
    @Test("a same-origin redirect outside the API's base path is not followed; one under it is", arguments: [
        ("https://git.example.com/gitlab/api/v4/moved", true),
        ("https://git.example.com/other/user", false),
        ("https://git.example.com/gitlab/user", false),
        ("https://git.example.com/gitlab/api/v4evil/user", false),
        ("https://git.example.com/gitlab/api/v4/%2E%2E/%2E%2E/user", false),
        ("https://git.example.com/gitlab/api/v4/..%2F..%2Fuser", false),
        ("https://git.example.com/gitlab/api/graphql", false),
    ])
    func redirectOutsideBasePathIsNotFollowed(target: String, isFollowed: Bool) async throws {
        let stub = StubServer { request in
            if request.url?.path() == "/gitlab/api/v4/user" {
                return .init(status: 302, headers: ["Location": target], body: "", redirect: URL(string: target))
            }
            return .init(body: Self.user(9, "moved"))
        }
        let client = try Self.client(stub, refreshes: Self.refreshed())

        if isFollowed {
            #expect(try await client.currentUser().login == "moved", "positive control: the stub redirects")
            #expect(stub.requests.map { $0.url?.path() } == ["/gitlab/api/v4/user", "/gitlab/api/v4/moved"])
            let carriesToken = stub.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)"
            #expect(carriesToken, "the guard puts the header back on a redirect it follows")
        } else {
            await #expect(throws: HostingError.self) { try await client.currentUser() }
            #expect(stub.requests.map { $0.url?.path() } == ["/gitlab/api/v4/user"], "nothing reaches the target")
        }
    }

    @Test("GitLab error bodies give readable messages: error, error_description, an object or array message")
    func gitLabErrorBodies() async throws {
        let cases: [(status: Int, body: String, error: HostingError)] = [
            (403, #"{"error": "insufficient_scope", "error_description": "The request requires higher privileges."}"#,
             .forbidden(message: "The request requires higher privileges.")),
            (403, #"{"error": "insufficient_scope"}"#, .forbidden(message: "insufficient_scope")),
            (422, #"{"message": {"title": ["is too long"], "base": ["one", "two"]}}"#,
             .validationFailed(message: "base: one, two; title: is too long")),
            (400, #"{"message": ["source_branch is missing"]}"#,
             .http(status: 400, message: "source_branch is missing")),
            (405, #"{"message": "405 Method Not Allowed"}"#, .http(status: 405, message: "405 Method Not Allowed")),
        ]
        for (status, body, error) in cases {
            let stub = StubServer { _ in .init(status: status, body: body) }
            let client = try Self.client(stub, refreshes: Self.refreshed())
            await #expect(throws: error) { try await client.currentUser() }
        }
    }

    // MARK: - Writes

    static let writeRepo = HostedRepository(host: "git.example.com", path: ["group", "proj"])
    static let mrPath = "/gitlab/api/v4/projects/group%2Fproj/merge_requests"

    static func minimalMR(
        iid: Int = 5, title: String = "T", sha: String = "abc1", sourceProject: Int? = nil, targetProject: Int? = nil
    ) -> String {
        let projects = [("source_project_id", sourceProject), ("target_project_id", targetProject)]
            .compactMap { key, id in id.map { #", "\#(key)": \#($0)"# } }.joined()
        return """
            {"id": 900\(iid), "iid": \(iid), "title": "\(title)", "state": "opened",
             "web_url": "https://git.example.com/gitlab/group/proj/-/merge_requests/\(iid)",
             "source_branch": "feature", "target_branch": "main", "sha": "\(sha)"\(projects)}
            """
    }

    @Test("a same-project merge request's head is labeled owner:branch (the whole subgroup path), a fork's is not")
    func headLabelOnlyForSameProject() async throws {
        let stub = StubServer { request in
            let path = request.url?.path(percentEncoded: true) ?? ""
            let prefix = "/gitlab/api/v4/projects/group%2Fsub%2Fproj/merge_requests"
            return switch path {
            case prefix: .init(body: "[\(Self.minimalMR(iid: 5, sourceProject: 3, targetProject: 3)),"
                + "\(Self.minimalMR(iid: 6, sourceProject: 4, targetProject: 3))]")
            case prefix + "/5": .init(body: Self.minimalMR(iid: 5, sourceProject: 3, targetProject: 3))
            case prefix + "/6": .init(body: Self.minimalMR(iid: 6, sourceProject: 4, targetProject: 3))
            default: .init(status: 404, body: "{}")
            }
        }
        let client = try Self.client(stub, refreshes: Self.refreshed())
        let repo = HostedRepository(host: "git.example.com", path: ["group", "sub", "proj"])

        let same = try await client.pullRequest(5, in: repo)
        #expect(same.head.label == "group/sub:feature" && same.base.label == "group/sub:main")
        let fork = try await client.pullRequest(6, in: repo)
        #expect(fork.head.label == nil && fork.base.label == "group/sub:main")
        let listed = try await client.pullRequests(in: repo, state: .open)
        #expect(listed.map(\.head.label) == ["group/sub:feature", nil])
    }

    /// A provider that already refreshed: it hands out `token` from the first request.
    static func refreshed() -> Refreshes {
        let refreshes = Refreshes()
        refreshes.count.withLock { $0 = 1 }
        return refreshes
    }

    static func json(_ request: URLRequest) -> [String: Any] {
        request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    @Test("merge PUTs with the head's sha and the squash choice; a 409 is headChanged")
    func mergeSendsSHA() async throws {
        let stub = StubServer { request in
            Self.json(request)["sha"] as? String == "abc1"
                ? .init(body: Self.minimalMR())
                : .init(status: 409, body: #"{"message": "SHA does not match HEAD of source branch"}"#)
        }
        let client = try Self.client(stub, refreshes: Self.refreshed())

        try await client.merge(5, in: Self.writeRepo, method: .squash, sha: "abc1")
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path(percentEncoded: true) == Self.mrPath + "/5/merge")
        let body = Self.json(request)
        #expect(body["sha"] as? String == "abc1" && body["squash"] as? Bool == true)
        #expect(Set(body.keys) == ["sha", "squash"], "no deprecated merge_when_pipeline_succeeds")

        await #expect(throws: HostingError.headChanged) {
            try await client.merge(5, in: Self.writeRepo, method: .merge, sha: "old0")
        }
        #expect(Self.json(stub.requests[1])["squash"] as? Bool == false)
        await #expect(throws: HostingError.self) {
            try await client.merge(5, in: Self.writeRepo, method: .rebase, sha: "abc1")
        }
        #expect(stub.requests.count == 2, "a rebase is refused before any request")
    }

    @Test("a draft merge request gets a Draft: title prefix and GitLab's field names")
    func createDraftMergeRequest() async throws {
        let stub = StubServer { request in
            .init(status: 201, body: Self.minimalMR(iid: 12, title: Self.json(request)["title"] as? String ?? ""))
        }
        let client = try Self.client(stub, refreshes: Self.refreshed())

        let pull = try await client.createPullRequest(
            NewPullRequest(title: "Add it", head: "feature", base: "main", body: "Why", draft: true),
            in: Self.writeRepo)

        #expect(pull.number == 12 && pull.title == "Draft: Add it")
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "POST" && request.url?.path(percentEncoded: true) == Self.mrPath)
        let body = Self.json(request)
        #expect(Set(body.keys) == ["source_branch", "target_branch", "title", "description"])
        #expect(body["title"] as? String == "Draft: Add it" && body["source_branch"] as? String == "feature")
        #expect(body["target_branch"] as? String == "main" && body["description"] as? String == "Why")

        _ = try await client.createPullRequest(
            NewPullRequest(title: "Draft: Twice", head: "feature", base: "main", draft: true), in: Self.writeRepo)
        #expect(Self.json(stub.requests[1])["title"] as? String == "Draft: Twice", "no second prefix")
        for title in ["[Draft] Brackets", "(draft) Parens", "DRAFT: Loud"] {
            _ = try await client.createPullRequest(
                NewPullRequest(title: title, head: "feature", base: "main", draft: true), in: Self.writeRepo)
            #expect(Self.json(stub.requests.last!)["title"] as? String == title, "GitLab's draft prefixes are kept")
        }
        await #expect(throws: HostingError.self) {
            try await client.createPullRequest(
                NewPullRequest(title: "Fork", head: "someone:feature", base: "main"), in: Self.writeRepo)
        }
        #expect(stub.requests.count == 5)
    }

    @Test("a reply posts to the discussion's notes; a ref without the discussion id is refused")
    func replyGoesToDiscussion() async throws {
        let discussion = "6a9c1750b37d513a43987b574953fceb50b03ce7"
        let stub = StubServer { _ in
            .init(
                status: 201,
                body: #"{"id": 77, "type": "DiscussionNote", "body": "ok", "author": \#(Self.user(7, "me"))}"#)
        }
        let client = try Self.client(stub, refreshes: Self.refreshed())

        let reply = try await client.reply(
            to: HostedThreadRef(rootCommentID: 10, hostKey: discussion), on: 5, in: Self.writeRepo, body: "ok")

        #expect(reply.id == 77 && reply.inReplyToID == 10 && reply.user?.login == "me")
        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path(percentEncoded: true) == Self.mrPath + "/5/discussions/\(discussion)/notes")
        #expect(Self.json(request)["body"] as? String == "ok")

        await #expect(throws: HostingError.self) {
            try await client.reply(to: HostedThreadRef(rootCommentID: 10), on: 5, in: Self.writeRepo, body: "ok")
        }
        #expect(stub.requests.count == 1)
    }

    @Test("a reply without a discussion id goes to the discussion of its root note, once the client mapped the threads")
    func replyFindsDiscussionOfRoot() async throws {
        let discussion = "6a9c1750b37d513a43987b574953fceb50b03ce7"
        let stub = StubServer { request in
            let path = request.url?.path(percentEncoded: true) ?? ""
            if request.httpMethod == "GET", path == Self.mrPath + "/5/discussions" {
                return .init(body: """
                    [{"id": "\(discussion)", "notes": [{"id": 10, "type": "DiffNote", "body": "x", "resolvable": false,
                      "position": {"new_path": "a.swift", "old_path": "a.swift", "new_line": 1}}]}]
                    """)
            }
            if request.httpMethod == "POST" {
                return .init(
                    status: 201, body: #"{"id": 77, "type": "DiffNote", "body": "ok", "author": \#(Self.user(7, "me"))}"#)
            }
            return .init(status: 404, body: "{}")
        }
        let client = try Self.client(stub, refreshes: Self.refreshed())
        await #expect(throws: HostingError.self) {
            try await client.reply(to: HostedThreadRef(rootCommentID: 10), on: 5, in: Self.writeRepo, body: "ok")
        }
        #expect(stub.requests.isEmpty, "an unknown thread is refused unsent")

        _ = try await client.reviewComments(of: 5, in: Self.writeRepo)
        let reply = try await client.reply(
            to: HostedThreadRef(rootCommentID: 10), on: 5, in: Self.writeRepo, body: "ok")

        #expect(reply.id == 77 && reply.inReplyToID == 10)
        let post = try #require(stub.requests.first { $0.httpMethod == "POST" })
        #expect(post.url?.path(percentEncoded: true) == Self.mrPath + "/5/discussions/\(discussion)/notes")
        await #expect(throws: HostingError.self) {
            try await client.reply(to: HostedThreadRef(rootCommentID: 10), on: 6, in: Self.writeRepo, body: "ok")
        }
    }

    @Test("resolving PUTs the discussion with resolved=, for a thread the client mapped")
    func resolveThread() async throws {
        let discussion = "87805b7c09016a7058e91bdbe7b29d1f284a39e6"
        @Sendable func thread(resolved: Bool) -> String {
            """
            {"id": "\(discussion)", "notes": [{"id": 20, "type": "DiffNote", "body": "x", "resolvable": true,
             "resolved": \(resolved), "position": {"new_path": "a.swift", "old_path": "a.swift", "new_line": 1}}]}
            """
        }
        let stub = StubServer { request in
            let path = request.url?.path(percentEncoded: true) ?? ""
            if path == Self.mrPath + "/5/discussions" { return .init(body: "[\(thread(resolved: false))]") }
            if path == Self.mrPath + "/5/discussions/\(discussion)" {
                return .init(body: thread(resolved: request.url?.query()?.contains("resolved=true") == true))
            }
            if path == Self.mrPath + "/5" { return .init(body: Self.minimalMR()) }
            return .init(status: 404, body: "{}")
        }
        let client = try Self.client(stub, refreshes: Self.refreshed())
        let unknown = HostedReviewThreadState(
            id: discussion, isResolved: false, isOutdated: false, viewerCanResolve: true, viewerCanUnresolve: true)
        await #expect(throws: HostingError.self) { try await client.setReviewThread(unknown, resolved: true) }

        let state = try #require(try await client.reviewThreadStates(of: 5, in: Self.writeRepo).first)
        #expect(state.id == discussion)
        #expect(try await client.setReviewThread(state, resolved: true) == true)
        #expect(try await client.setReviewThread(state, resolved: false) == false)

        let puts = stub.requests.filter { $0.httpMethod == "PUT" }
        #expect(puts.map { $0.url?.path(percentEncoded: true) } == [
            Self.mrPath + "/5/discussions/\(discussion)", Self.mrPath + "/5/discussions/\(discussion)",
        ])
        #expect(puts.map { $0.url?.query() } == ["resolved=true", "resolved=false"])
    }

    @Test("approving pins the head the client last loaded (409 is headChanged)")
    func approvePinsHead() async throws {
        let stub = StubServer { request in
            let path = request.url?.path(percentEncoded: true) ?? ""
            if path == "/gitlab/api/v4/user" { return .init(body: Self.user(7, "me")) }
            if path == Self.mrPath + "/5" { return .init(body: Self.minimalMR(sha: "abc1")) }
            if path == Self.mrPath + "/5/approve" {
                return Self.json(request)["sha"] as? String == "abc1"
                    ? .init(status: 201, body: #"{"approved_by": [{"user": \#(Self.user(7, "me"))}]}"#)
                    : .init(status: 409, body: #"{"message": "SHA does not match HEAD of source branch"}"#)
            }
            return .init(status: 404, body: "{}")
        }
        let client = try Self.client(stub, refreshes: Self.refreshed())

        await #expect(throws: HostingError.headChanged) {
            try await client.review(5, in: Self.writeRepo, event: .approve, body: nil)
        }
        _ = try await client.pullRequest(5, in: Self.writeRepo)
        let review = try await client.review(5, in: Self.writeRepo, event: .approve, body: nil)
        #expect(review.state == "APPROVED" && review.user?.login == "me")
        let approvals = stub.requests.filter { $0.url?.path(percentEncoded: true) == Self.mrPath + "/5/approve" }
        #expect(approvals.map { Self.json($0)["sha"] as? String } == [nil, "abc1"])
    }

    @Test("an approve still 401 after the forced refresh is GitLab refusing the approval, not an expired token")
    func approveRefusedIsNotUnauthorized() async throws {
        let stub = StubServer { request in
            request.url?.path(percentEncoded: true) == "/gitlab/api/v4/user"
                ? .init(body: Self.user(7, "me"))
                : .init(status: 401, body: #"{"message": "401 Unauthorized"}"#)
        }
        let refreshes = Refreshes()
        let client = try Self.client(stub, refreshes: refreshes)

        await #expect {
            try await client.review(5, in: Self.writeRepo, event: .approve, body: nil)
        } throws: { error in
            guard case HostingError.validationFailed = error else { return false }
            return true
        }
        let approvals = stub.requests.filter { $0.url?.path(percentEncoded: true) == Self.mrPath + "/5/approve" }
        #expect(approvals.count == 2)
        #expect(refreshes.count.withLock { $0 } == 1)
    }

    @Test("unapprove POSTs .../unapprove with the token and no body; 404 and a 401 the refresh does not clear are refusals, 403 is forbidden")
    func unapprovePostsAndMapsErrors() async throws {
        let unapprovePath = Self.mrPath + "/5/unapprove"
        let ok = StubServer { request in
            request.url?.path(percentEncoded: true) == unapprovePath
                ? .init(status: 201, body: #"{"approved": false, "approved_by": []}"#)
                : .init(status: 404, body: "{}")
        }
        try await Self.client(ok, refreshes: Self.refreshed()).unapprove(5, in: Self.writeRepo)
        let sent = try #require(ok.requests.first)
        #expect(ok.requests.count == 1)
        #expect(sent.httpMethod == "POST" && sent.url?.absoluteString == "https://git.example.com\(unapprovePath)")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
        #expect(sent.httpBody == nil)

        for (status, refreshesAfter) in [(404, 0), (401, 1)] {
            let refused = StubServer { _ in .init(status: status, body: #"{"message": "\#(status) Refused"}"#) }
            let refreshes = Refreshes()
            await #expect {
                try await Self.client(refused, refreshes: refreshes).unapprove(5, in: Self.writeRepo)
            } throws: { error in
                guard case HostingError.validationFailed = error else { return false }
                return true
            }
            #expect(refused.requests.count == (status == 401 ? 2 : 1), "a 401 retries once after a refresh")
            #expect(refreshes.count.withLock { $0 } == refreshesAfter)
        }

        let forbidden = StubServer { _ in .init(status: 403, body: #"{"message": "403 Forbidden"}"#) }
        await #expect(throws: HostingError.forbidden(message: "403 Forbidden")) {
            try await Self.client(forbidden, refreshes: Self.refreshed()).unapprove(5, in: Self.writeRepo)
        }
    }

    /// A GitLab whose `/api/graphql` answers `graphQL`, with the user `me` and a note endpoint.
    static func requestChangesServer(graphQL: String) -> StubServer {
        StubServer { request in
            switch request.url?.path(percentEncoded: true) ?? "" {
            case "/gitlab/api/v4/user": .init(body: Self.user(7, "me"))
            case Self.mrPath + "/5/notes":
                .init(status: 201, body: #"{"id": 61, "body": "Fix it", "author": \#(Self.user(7, "me"))}"#)
            case "/gitlab/api/graphql": .init(body: graphQL)
            default: .init(status: 404, body: "{}")
            }
        }
    }

    @Test("request changes runs the GraphQL mutation with the project path and iid as variables and the token, then posts the body as a note; the review is the user's CHANGES_REQUESTED")
    func requestChangesRunsMutation() async throws {
        let stub = Self.requestChangesServer(
            graphQL: #"{"data": {"mergeRequestRequestChanges": {"errors": [], "mergeRequest": {"iid": "5"}}}}"#)
        let client = try Self.client(stub, refreshes: Self.refreshed())

        let review = try await client.review(5, in: Self.writeRepo, event: .requestChanges, body: "Fix it")

        #expect(review.state == "CHANGES_REQUESTED" && review.user?.login == "me" && review.body == "Fix it")
        #expect(stub.requests.map { $0.url?.path(percentEncoded: true) } == [
            "/gitlab/api/v4/user", "/gitlab/api/graphql", Self.mrPath + "/5/notes",
        ])
        let mutation = stub.requests[1]
        #expect(mutation.httpMethod == "POST")
        #expect(mutation.url == client.graphQLURL)
        #expect(mutation.url?.absoluteString == "https://git.example.com/gitlab/api/graphql")
        #expect(mutation.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
        #expect(mutation.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let json = Self.json(mutation)
        let query = try #require(json["query"] as? String)
        #expect(query.contains("mergeRequestRequestChanges(input: {projectPath: $projectPath, iid: $iid})"))
        #expect(query.contains("errors"))
        #expect(!query.contains("group/proj"), "values go only in the variables")
        let variables = try #require(json["variables"] as? [String: Any])
        #expect(variables["projectPath"] as? String == "group/proj")
        #expect(variables["iid"] as? String == "5")
        #expect(Self.json(stub.requests[2])["body"] as? String == "Fix it")

        let bare = Self.requestChangesServer(
            graphQL: #"{"data": {"mergeRequestRequestChanges": {"errors": [], "mergeRequest": {"iid": "5"}}}}"#)
        _ = try await Self.client(bare, refreshes: Self.refreshed())
            .review(5, in: Self.writeRepo, event: .requestChanges, body: nil)
        #expect(!bare.requests.contains { $0.url?.path(percentEncoded: true) == Self.mrPath + "/5/notes" },
                "no body, no note")
    }

    @Test("a change request GraphQL refuses, with top-level errors or the mutation's, or answers without its result, fails and posts no note", arguments: [
        (#"{"errors": [{"message": "The resource that you are attempting to access does not exist"}], "data": {"mergeRequestRequestChanges": null}}"#,
         HostingError.graphQL(message: "The resource that you are attempting to access does not exist")),
        (#"{"data": {"mergeRequestRequestChanges": {"errors": ["Not a reviewer", "Locked"], "mergeRequest": null}}}"#,
         HostingError.graphQL(message: "Not a reviewer; Locked")),
        (#"{"data": {"mergeRequestRequestChanges": null}}"#,
         HostingError.invalidResponse("a change request without its result")),
    ])
    func requestChangesErrorsFail(answer: String, expected: HostingError) async throws {
        let stub = Self.requestChangesServer(graphQL: answer)
        await #expect(throws: expected) {
            try await Self.client(stub, refreshes: Self.refreshed())
                .review(5, in: Self.writeRepo, event: .requestChanges, body: "Fix it")
        }
        #expect(!stub.requests.contains { $0.url?.path(percentEncoded: true) == Self.mrPath + "/5/notes" })
    }

    @Test("the token goes to /api/graphql itself; a redirect from it to /api/graphqlx, /api/other or below it is not followed", arguments: [
        "https://git.example.com/gitlab/api/graphqlx",
        "https://git.example.com/gitlab/api/other",
        "https://git.example.com/gitlab/api/graphql/x",
        "https://git.example.com/api/graphql",
    ])
    func graphQLTokenScope(target: String) async throws {
        let stub = StubServer { request in
            switch request.url?.path(percentEncoded: true) ?? "" {
            case "/gitlab/api/v4/user": .init(body: Self.user(7, "me"))
            case "/gitlab/api/graphql":
                .init(status: 307, headers: ["Location": target], body: "", redirect: URL(string: target))
            default: .init(body: #"{"data": {"mergeRequestRequestChanges": {"errors": []}}}"#)
            }
        }
        let client = try Self.client(stub, refreshes: Self.refreshed())

        await #expect(throws: HostingError.self) {
            try await client.review(5, in: Self.writeRepo, event: .requestChanges, body: nil)
        }
        let graphQL = try #require(stub.requests.last)
        #expect(graphQL.url?.absoluteString == "https://git.example.com/gitlab/api/graphql")
        #expect(graphQL.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
        #expect(!stub.requests.contains { $0.url?.absoluteString == target }, "nothing reaches the target")
    }

    @Test("requesting reviewers reads the merge request and PUTs the union of reviewer_ids (a user's reviewerID over its id)")
    func requestReviewersPutsUnion() async throws {
        let stub = StubServer { request in
            request.httpMethod == "GET"
                ? .init(body: Self.minimalMR().dropLast() + #", "reviewers": [\#(Self.user(8, "rev")), \#(Self.user(3, "old"))]}"#)
                : .init(body: #"{"iid": 5}"#)
        }
        let client = try Self.client(stub, refreshes: Self.refreshed())

        try await client.requestReviewers(
            [HostedUser(id: 8, login: "rev"), HostedUser(id: 9, login: "new"),
             HostedUser(id: 0, login: "mapped", reviewerID: "21")],
            on: 5, in: Self.writeRepo)
        try await client.requestReviewers([], on: 5, in: Self.writeRepo)

        let requests = stub.requests
        #expect(requests.map(\.httpMethod) == ["GET", "PUT"], "no request for an empty list")
        #expect(requests.map { $0.url?.path(percentEncoded: true) } == [Self.mrPath + "/5", Self.mrPath + "/5"])
        let body = Self.json(requests[1])
        #expect(Set(body.keys) == ["reviewer_ids"])
        #expect(body["reviewer_ids"] as? [Int] == [8, 3, 9, 21], "current first, no duplicate")
    }

    @Test("adding assignees reads the item and PUTs the union of assignee_ids, on a merge request and on an issue",
          arguments: [(HostedItem.pullRequest(5), "/merge_requests/5"), (HostedItem.issue(6), "/issues/6")])
    func addAssigneesPutsUnion(item: HostedItem, suffix: String) async throws {
        let stub = StubServer { request in
            request.httpMethod == "GET"
                ? .init(body: #"{"iid": 1, "assignees": [\#(Self.user(4, "a"))]}"#)
                : .init(body: #"{"iid": 1}"#)
        }
        let client = try Self.client(stub, refreshes: Self.refreshed())

        try await client.addAssignees(
            [HostedUser(id: 4, login: "a"), HostedUser(id: 6, login: "b")], to: item, in: Self.writeRepo)

        let path = "/gitlab/api/v4/projects/group%2Fproj" + suffix
        let requests = stub.requests
        #expect(requests.map(\.httpMethod) == ["GET", "PUT"])
        #expect(requests.map { $0.url?.path(percentEncoded: true) } == [path, path])
        let body = Self.json(requests[1])
        #expect(Set(body.keys) == ["assignee_ids"])
        #expect(body["assignee_ids"] as? [Int] == [4, 6])
    }

    @Test("labels, close and reopen, and a plain comment send only GitLab's field, on a merge request and on an issue",
          arguments: [(HostedItem.pullRequest(5), "/merge_requests/5"), (HostedItem.issue(6), "/issues/6")])
    func labelsStateAndComment(item: HostedItem, suffix: String) async throws {
        let stub = StubServer { request in
            request.url?.path().hasSuffix("/notes") == true
                ? .init(status: 201, body: #"{"id": 55, "body": "hi", "author": \#(Self.user(7, "me"))}"#)
                : .init(body: #"{"iid": 1}"#)
        }
        let client = try Self.client(stub, refreshes: Self.refreshed())
        let path = "/gitlab/api/v4/projects/group%2Fproj" + suffix

        try await client.addLabels(["bug", "needs review"], to: item, in: Self.writeRepo)
        try await client.addLabels([], to: item, in: Self.writeRepo)
        try await client.setOpen(false, item: item, in: Self.writeRepo)
        try await client.setOpen(true, item: item, in: Self.writeRepo)
        let comment = try await client.comment(on: item, in: Self.writeRepo, body: "hi")

        #expect(comment.id == 55 && comment.user?.login == "me")
        let requests = stub.requests
        #expect(requests.map(\.httpMethod) == ["PUT", "PUT", "PUT", "POST"], "no request for no labels")
        #expect(requests.map { $0.url?.path(percentEncoded: true) } == [path, path, path, path + "/notes"])
        let bodies = requests.map(Self.json)
        #expect(bodies.map { Set($0.keys) } == [["add_labels"], ["state_event"], ["state_event"], ["body"]],
                "a comment sends no confidential or internal flag")
        #expect(bodies[0]["add_labels"] as? String == "bug,needs review")
        #expect(bodies[1]["state_event"] as? String == "close" && bodies[2]["state_event"] as? String == "reopen")
        #expect(bodies[3]["body"] as? String == "hi")
    }

    // MARK: - Pages and the token provider

    /// The `page` query item of a request, nil on the first page (`per_page=100` holds `page=1` as text).
    static func page(_ request: URLRequest) -> String? {
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "page" }?.value
    }

    static let diffsPath = mrPath + "/5/diffs"

    static func diff(_ name: String) -> String {
        #"{"old_path": "\#(name)", "new_path": "\#(name)", "diff": "@@ -1 +1 @@\n-a\n+b\n"}"#
    }

    @Test("a second page comes from X-Next-Page, alone or beside a Link next on the API, with the token", arguments: [
        false, true,
    ])
    func pagesFollowNextPageWithToken(withLink: Bool) async throws {
        let stub = StubServer { request in
            if Self.page(request) == "2" { return .init(body: "[\(Self.diff("b.swift"))]") }
            var headers = ["X-Next-Page": "2"]
            if withLink {
                headers["Link"] = "<\(Self.api)/projects/group%2Fproj/merge_requests/5/diffs?page=2&per_page=100>; rel=\"next\""
            }
            return .init(headers: headers, body: "[\(Self.diff("a.swift"))]")
        }
        let client = try Self.client(stub, refreshes: Self.refreshed())

        let files = try await client.pullRequestFiles(5, in: Self.writeRepo)

        #expect(files.map(\.filename) == ["a.swift", "b.swift"])
        let requests = stub.requests
        #expect(requests.map { $0.url?.path(percentEncoded: true) } == [Self.diffsPath, Self.diffsPath])
        #expect(requests.map(Self.page) == [nil, "2"])
        #expect(requests.allSatisfy { $0.url?.query()?.contains("per_page=100") == true })
        let allCarryToken = requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)" }
        #expect(allCarryToken)
    }

    @Test("a Link next on another origin is refused even beside a usable X-Next-Page")
    func foreignLinkWinsOverNextPage() async throws {
        let stub = StubServer { _ in
            .init(
                headers: ["Link": "<https://evil.example/gitlab/api/v4/x?page=2>; rel=\"next\"", "X-Next-Page": "2"],
                body: "[\(Self.diff("a.swift"))]")
        }
        let client = try Self.client(stub, refreshes: Self.refreshed())

        await #expect(throws: HostingError.invalidResponse("a next-page link to another host")) {
            try await client.pullRequestFiles(5, in: Self.writeRepo)
        }
        #expect(stub.requests.map { $0.url?.path(percentEncoded: true) } == [Self.diffsPath])
    }

    struct ProviderFailure: Error, Equatable {}

    @Test("a provider that throws surfaces its error: before any request, or after a 401 without a retry")
    func throwingProviderSendsNothingStale() async throws {
        let failing = StubServer { _ in .init(body: Self.user(7, "me")) }
        let client = try GitLabClient(host: "git.example.com", basePath: "gitlab", session: failing.session) { _ in
            throw ProviderFailure()
        }
        await #expect(throws: ProviderFailure()) { try await client.currentUser() }
        #expect(failing.requests.isEmpty)

        let rejecting = StubServer { _ in .init(status: 401, body: #"{"message": "401 Unauthorized"}"#) }
        let refreshFails = try GitLabClient(host: "git.example.com", basePath: "gitlab", session: rejecting.session) {
            rejected in
            if rejected != nil { throw ProviderFailure() }
            return Self.staleToken
        }
        await #expect(throws: ProviderFailure()) { try await refreshFails.currentUser() }
        #expect(rejecting.requests.count == 1, "the stale token is not sent again")
    }
}
