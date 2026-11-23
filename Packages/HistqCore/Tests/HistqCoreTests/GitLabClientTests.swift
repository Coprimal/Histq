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
            // The discussions load also asks GraphQL for rights and awards, and `/user` for the viewer (both 404
            // here, so the load falls back).
            let path = request.url?.path(percentEncoded: true) ?? ""
            #expect(path.hasPrefix("/gitlab/api/v4/projects/group%2Fsub%2Fproj/")
                || ["/gitlab/api/v4/user", "/gitlab/api/graphql"].contains(path), "\(path)")
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
        // The load's GraphQL read is a POST too.
        let post = try #require(stub.requests.last { $0.httpMethod == "POST" })
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

    @Test("member roles: one members/all read filtered by the unique user ids, GitLab's words by access level")
    func memberRoles() async throws {
        let stub = StubServer { _ in
            .init(body: #"[{"id": 3, "username": "o", "access_level": 50}, {"id": 4, "username": "d", "access_level": 30}, {"id": 5, "username": "m", "access_level": 5}]"#)
        }
        let client = try Self.client(stub, refreshes: Self.refreshed())

        let roles = try await client.memberRoles(of: [4, 3, 4, 5, 9], in: Self.writeRepo)
        let none = try await client.memberRoles(of: [], in: Self.writeRepo)

        #expect(roles == [3: "Owner", 4: "Developer"], "minimal access (5) has no badge; a non-member is left out")
        #expect(none.isEmpty)
        let requests = stub.requests
        #expect(requests.count == 1, "no request without ids")
        let url = try #require(requests.first?.url)
        #expect(url.path(percentEncoded: true) == "/gitlab/api/v4/projects/group%2Fproj/members/all")
        let ids = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .filter { $0.name == "user_ids[]" }.map(\.value)
        #expect(ids == ["3", "4", "5", "9"])
    }

    @Test("a commit-list system note: its HTML list becomes a Markdown list, each sha an 8-character commit link, <code> a code span, titles plain; the compare link resolves on the host")
    func commitListSystemNote() async throws {
        let body = "added 3 commits\n\n<ul><li>b4e5f17a1934f0d791b8af65d1f9c6e4159d066e...16ae9ad775e427262903c27c0499e5af353bee10 - 2 commits from branch <code>main</code></li>"
            + "<li>b11661e081418cbdc5366e80e72ab2498fbc35f1 - Fix &lt;b&gt; *bold* [x](javascript:alert(1)) &amp; more</li></ul>\n\n"
            + "[Compare with previous version](/group/proj/-/merge_requests/5/diffs?diff_id=1&start_sha=b11661e081418cbdc5366e80e72ab2498fbc35f1)"
        let note = #"{"id": 900, "type": null, "body": \#(String(data: try JSONEncoder().encode(body), encoding: .utf8)!), "author": \#(Self.user(8, "u8")), "created_at": "2026-11-02T10:00:00Z", "system": true}"#
        let discussions = "[" + Self.restDiscussion(Self.systemID, individual: true, [note]) + "]"
        let stub = StubServer { request in
            request.url?.path(percentEncoded: true) == Self.mrPath + "/5/discussions"
                ? .init(body: discussions) : .init(status: 404, body: #"{"message": "404 Not Found"}"#)
        }
        let client = try Self.client(stub, refreshes: Self.refreshed())

        let events = try await client.timelineEvents(of: .pullRequest(5), in: Self.writeRepo)
        let html = try #require(events.first { $0.id == "note-900" }?.textHTML)

        let commit = "https://git.example.com/gitlab/group/proj/-/commit/"
        #expect(html.hasPrefix("<p>added 3 commits</p>\n<ul>"))
        #expect(html.contains("<li><a href=\"\(commit)b4e5f17a1934f0d791b8af65d1f9c6e4159d066e\"><code>b4e5f17a</code></a>...<a href=\"\(commit)16ae9ad775e427262903c27c0499e5af353bee10\"><code>16ae9ad7</code></a> - 2 commits from branch <code>main</code></li>"))
        #expect(html.contains("<li><a href=\"\(commit)b11661e081418cbdc5366e80e72ab2498fbc35f1\"><code>b11661e0</code></a> - Fix &lt;b&gt; *bold* [x](javascript:alert(1)) &amp; more</li>"),
                "a title is plain text: no HTML, emphasis or link")
        #expect(html.contains("<a href=\"https://git.example.com/group/proj/-/merge_requests/5/diffs?diff_id=1&amp;start_sha=b11661e081418cbdc5366e80e72ab2498fbc35f1\">Compare with previous version</a>"))
        #expect(!html.contains("javascript:alert(1)\""))

        let comment = #"{"id": 77, "body": "see [log.txt](/uploads/abc/log.txt)", "author": \#(Self.user(8, "u8"))}"#
        let commentStub = StubServer { _ in .init(status: 201, body: comment) }
        let posted = try await Self.client(commentStub, refreshes: Self.refreshed())
            .comment(on: .pullRequest(5), in: Self.writeRepo, body: "x")
        #expect(posted.bodyHTML == "<p>see log.txt</p>\n",
                "a comment's root-relative attachment link is project-relative on GitLab: it stays text")
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

    // MARK: - Comment interactions

    static let issuePath = "/gitlab/api/v4/projects/group%2Fproj/issues"
    static let graphQLPath = "/gitlab/api/graphql"

    /// A REST note of a discussions fixture: `diff` gives it a position on new line 1 of `a.swift`.
    static func restNote(
        _ id: Int, by author: Int, type: String? = "DiscussionNote", resolvable: Bool = false, resolved: Bool = false,
        system: Bool = false, diff: Bool = false
    ) -> String {
        let position = diff ? #", "position": {"old_path": "a.swift", "new_path": "a.swift", "new_line": 1}"# : ""
        return """
            {"id": \(id), "type": \(type.map { "\"\($0)\"" } ?? "null"), "body": "note \(id)",
             "author": \(Self.user(author, "u\(author)")), "created_at": "2026-11-02T10:00:00Z", "system": \(system),
             "resolvable": \(resolvable), "resolved": \(resolved)\(position)}
            """
    }

    static func restDiscussion(_ id: String, individual: Bool = false, _ notes: [String]) -> String {
        #"{"id": "\#(id)", "individual_note": \#(individual), "notes": [\#(notes.joined(separator: ", "))]}"#
    }

    /// A GraphQL note: its global id, `adminNote`, `resolveNote` and awards (emoji name, user id).
    static func graphQLNote(_ gid: String, admin: Bool, resolve: Bool? = nil, awards: [(String, Int)] = []) -> String {
        let nodes = awards.map { #"{"name": "\#($0.0)", "user": {"id": "gid://gitlab/User/\#($0.1)"}}"# }
        let resolveNote = resolve.map { #", "resolveNote": \#($0)"# } ?? ""
        return """
            {"id": "\(gid)", "userPermissions": {"adminNote": \(admin)\(resolveNote)},
             "awardEmoji": {"nodes": [\(nodes.joined(separator: ", "))]}}
            """
    }

    /// A `NoteStates` answer page for a merge request (`field` `mergeRequest`, global id `MergeRequest/9005`, awards
    /// thumbsup by user 8 and thumbsdown and clap by the viewer 7) or an issue (`issue`, `Issue/9003`, no awards):
    /// discussions as (REST id, resolved, notes), `next` the end cursor when another page follows.
    static func noteStatesPage(field: String, _ discussions: [(String, Bool?, [String])], next: String? = nil)
        -> String
    {
        let nodes = discussions.map { id, resolved, notes in
            #"{"id": "gid://gitlab/Discussion/\#(id)", "resolved": \#(resolved.map(String.init) ?? "null"), "#
                + #""notes": {"nodes": [\#(notes.joined(separator: ", "))]}}"#
        }
        let cursor = next.map { "\"\($0)\"" } ?? "null"
        let item = field == "issue" ? #""id": "gid://gitlab/Issue/9003", "awardEmoji": {"nodes": []}"#
            : #""id": "gid://gitlab/MergeRequest/9005", "awardEmoji": {"nodes": ["#
                + [("thumbsup", 8), ("thumbsdown", 7), ("clap", 7)]
                    .map { #"{"name": "\#($0.0)", "user": {"id": "gid://gitlab/User/\#($0.1)"}}"# }
                    .joined(separator: ", ") + "]}"
        return """
            {"data": {"project": {"\(field)": {\(item), "discussions": {"nodes": [\(nodes.joined(separator: ", "))],
             "pageInfo": {"hasNextPage": \(next != nil), "endCursor": \(cursor)}}}}}}
            """
    }

    static let individualID = "1111111111111111111111111111111111111111"
    static let threadID = "2222222222222222222222222222222222222222"
    static let diffID = "3333333333333333333333333333333333333333"
    static let systemID = "4444444444444444444444444444444444444444"
    static let issueThreadID = "5555555555555555555555555555555555555555"
    static let newThreadID = "6666666666666666666666666666666666666666"

    /// Merge request !5's discussions: an individual note 100 by the viewer (7); a resolvable general thread (root
    /// 200 by user 8, reply 201 by the viewer, a system note 202 inside); a resolvable diff thread (300 by user 8,
    /// reply 301 by the viewer); an individual system note 400. Issue #3: a resolvable general thread, root 500.
    static let mrDiscussions = "[" + [
        restDiscussion(individualID, individual: true, [restNote(100, by: 7, type: nil)]),
        restDiscussion(threadID, [
            restNote(200, by: 8, resolvable: true), restNote(201, by: 7, resolvable: true),
            restNote(202, by: 8, type: nil, system: true),
        ]),
        restDiscussion(diffID, [
            restNote(300, by: 8, type: "DiffNote", resolvable: true, diff: true),
            restNote(301, by: 7, type: "DiffNote", resolvable: true, diff: true),
        ]),
        restDiscussion(systemID, individual: true, [restNote(400, by: 8, type: nil, system: true)]),
    ].joined(separator: ", ") + "]"
    static let issueDiscussions = "[" + restDiscussion(issueThreadID, [restNote(500, by: 8, resolvable: true)]) + "]"

    /// The GraphQL answers for !5 (two pages: the general discussions, then the diff one) and issue #3.
    static func noteStates(_ request: URLRequest) -> String {
        let body = Self.json(request)
        let query = body["query"] as? String ?? ""
        let after = (body["variables"] as? [String: Any])?["after"] as? String
        if query.contains("issue(iid:") {
            return noteStatesPage(field: "issue", [
                (issueThreadID, true, [graphQLNote("gid://gitlab/Note/500", admin: false, resolve: true)]),
            ])
        }
        if after == "page2" {
            return noteStatesPage(field: "mergeRequest", [
                (diffID, false, [
                    graphQLNote("gid://gitlab/DiffNote/300", admin: false, resolve: false, awards: [("eyes", 7)]),
                    graphQLNote("gid://gitlab/DiffNote/301", admin: true, resolve: false),
                ]),
            ])
        }
        return noteStatesPage(field: "mergeRequest", [
            (individualID, nil, [
                graphQLNote("gid://gitlab/Note/100", admin: true, awards: [("thumbsup", 7), ("100", 8), ("thumbsup", 8)]),
            ]),
            (threadID, false, [
                graphQLNote("gid://gitlab/DiscussionNote/200", admin: false, resolve: true,
                            awards: [("rocket", 7), ("tada", 8)]),
                graphQLNote("gid://gitlab/DiscussionNote/201", admin: true, resolve: true),
                graphQLNote("gid://gitlab/Note/202", admin: false),
            ]),
        ], next: "page2")
    }

    /// The reads of the comment fixtures; `graphQL` answers a `NoteStates` query (nil: the fixtures').
    static func commentReads(_ request: URLRequest, graphQL: String? = nil) -> StubServer.Reply? {
        let path = request.url?.path(percentEncoded: true) ?? ""
        switch (request.httpMethod ?? "GET", path) {
        case ("GET", mrPath + "/5/discussions"): return .init(body: mrDiscussions)
        case ("GET", issuePath + "/3/discussions"): return .init(body: issueDiscussions)
        case ("GET", "/gitlab/api/v4/user"): return .init(body: Self.user(7, "me"))
        case ("POST", graphQLPath) where (Self.json(request)["query"] as? String)?.contains("NoteStates") == true:
            return .init(body: graphQL ?? noteStates(request))
        default: return nil
        }
    }

    @Test("discussions split into general comments (roots, one level of replies, hostKey, resolvable) and diff threads; rights and reactions come from one GraphQL read per page, else the author and no reactions")
    func commentNestingRightsAndReactions() async throws {
        let stub = StubServer { request in
            Self.commentReads(request) ?? .init(status: 404, body: #"{"message": "404 Not Found"}"#)
        }
        let client = try Self.client(stub, refreshes: Self.refreshed())

        let comments = try await client.comments(on: .pullRequest(5), in: Self.writeRepo)
        #expect(comments.map(\.id) == [100, 200, 201], "no system note, no diff thread")
        #expect(comments.map(\.parentID) == [nil, nil, 200])
        #expect(comments.map(\.hostKey) == [Self.individualID, Self.threadID, Self.threadID])
        #expect(comments.map(\.resolvable) == [nil, true, nil])
        #expect(comments.map(\.resolved) == [nil, false, nil])
        #expect(comments.map(\.viewerCanEdit) == [true, false, true])
        #expect(comments.map(\.viewerCanDelete) == [true, false, true])
        #expect(comments[0].reactions == [
            HostedReaction(kind: "thumbsup", count: 2, viewerReacted: true), HostedReaction(kind: "100", count: 1),
        ], "the default kinds first, another name still shown")
        #expect(comments[1].reactions == [
            HostedReaction(kind: "tada", count: 1), HostedReaction(kind: "rocket", count: 1, viewerReacted: true),
        ], "in reactionKinds order")
        #expect(comments[2].reactions.isEmpty)
        #expect(comments[1].htmlURL == "https://git.example.com/gitlab/group/proj/-/merge_requests/5#note_200")

        let reviewComments = try await client.reviewComments(of: 5, in: Self.writeRepo)
        #expect(reviewComments.map(\.id) == [300, 301] && reviewComments.map(\.inReplyToID) == [nil, 300])
        #expect(reviewComments.map(\.hostKey) == [Self.diffID, Self.diffID])
        #expect(reviewComments.map(\.viewerCanEdit) == [false, true])
        #expect(reviewComments[0].reactions == [HostedReaction(kind: "eyes", count: 1, viewerReacted: true)])
        let states = try await client.reviewThreadStates(of: 5, in: Self.writeRepo)
        #expect(states.map(\.id) == [Self.diffID])
        #expect(states.first?.viewerCanResolve == true, "resolveNote is read but not applied yet")

        let queries = stub.requests.filter { $0.url?.path() == Self.graphQLPath }
        #expect(queries.count == 6, "two pages per load, three loads one after another")
        let first = Self.json(queries[0])
        let variables = first["variables"] as? [String: Any] ?? [:]
        #expect(variables["projectPath"] as? String == "group/proj" && variables["iid"] as? String == "5")
        #expect(variables["after"] == nil || variables["after"] is NSNull)
        #expect((Self.json(queries[1])["variables"] as? [String: Any])?["after"] as? String == "page2")
        let query = first["query"] as? String ?? ""
        #expect(query.contains("mergeRequest(iid: $iid)") && query.contains("discussions(first: 20"))
        #expect(!query.contains("group/proj"), "values only in variables")
        #expect(!stub.requests.contains { $0.url?.path().hasSuffix("/award_emoji") == true }, "no REST per note")
        #expect(!stub.requests.contains { $0.url?.path().hasSuffix("/notes") == true })

        // GraphQL refused: rights fall back to author == viewer, reactions hidden; the issue reads its own path.
        let failing = StubServer { request in
            Self.commentReads(request, graphQL: #"{"errors": [{"message": "boom"}], "data": null}"#)
                ?? .init(status: 404, body: #"{"message": "404 Not Found"}"#)
        }
        let fallback = try Self.client(failing, refreshes: Self.refreshed())
        let degraded = try await fallback.comments(on: .pullRequest(5), in: Self.writeRepo)
        #expect(degraded.map(\.viewerCanEdit) == [true, false, true])
        #expect(degraded.allSatisfy { $0.reactions.isEmpty })
        #expect(degraded.map(\.resolved) == [nil, false, nil], "REST's resolved without GraphQL")
        let issueComments = try await fallback.comments(on: .issue(3), in: Self.writeRepo)
        #expect(issueComments.map(\.id) == [500] && issueComments.first?.resolvable == true)
        #expect(issueComments.first?.viewerCanEdit == false)
        let issueQuery = failing.requests.last { $0.url?.path() == Self.graphQLPath }.map { Self.json($0)["query"] }
        #expect((issueQuery as? String)?.contains("issue(iid: $iid)") == true)
    }

    @Test("the five reads of one detail load share one discussions fetch and one GraphQL read; a later read fetches again")
    func discussionsLoadedOnce() async throws {
        let stub = StubServer { request in
            if request.url?.path(percentEncoded: true) == Self.mrPath + "/5/discussions" {
                Thread.sleep(forTimeInterval: 0.3)  // keeps the load running while the other reads join it
            }
            if request.url?.path(percentEncoded: true) == Self.mrPath + "/5" { return .init(body: Self.minimalMR()) }
            if request.url?.path().hasSuffix("_events") == true { return .init(body: "[]") }
            return Self.commentReads(request) ?? .init(status: 404, body: #"{"message": "404 Not Found"}"#)
        }
        let client = try Self.client(stub, refreshes: Self.refreshed())
        func count(_ path: String) -> Int { stub.requests.count { $0.url?.path(percentEncoded: true) == path } }

        async let comments = client.comments(on: .pullRequest(5), in: Self.writeRepo)
        async let reviewComments = client.reviewComments(of: 5, in: Self.writeRepo)
        async let states = client.reviewThreadStates(of: 5, in: Self.writeRepo)
        async let itemReactions = client.itemReactions(of: .pullRequest(5), in: Self.writeRepo)
        async let events = client.timelineEvents(of: .pullRequest(5), in: Self.writeRepo)
        let loaded = try await (comments, reviewComments, states, itemReactions, events)

        #expect(loaded.0.map(\.id) == [100, 200, 201] && loaded.1.map(\.id) == [300, 301] && loaded.2.count == 1)
        #expect(loaded.3.map(\.kind) == ["thumbsup", "thumbsdown", "clap"], "the item's awards join the same load")
        #expect(loaded.4.map(\.id) == ["note-202", "note-400"], "the system notes join the same load")
        #expect(count(Self.mrPath + "/5/discussions") == 1)
        #expect(count(Self.graphQLPath) == 2, "one NoteStates read of two pages")

        _ = try await client.comments(on: .pullRequest(5), in: Self.writeRepo)
        #expect(count(Self.mrPath + "/5/discussions") == 2, "the finished load is not kept")
    }

    @Test("comment writes send GitLab's method, path and body, on a merge request and an issue; refusals send nothing")
    func commentWrites() async throws {
        let mrWithRefs = """
            {"id": 9005, "iid": 5, "title": "T", "state": "opened", "sha": "abc1",
             "web_url": "https://git.example.com/gitlab/group/proj/-/merge_requests/5",
             "source_branch": "feature", "target_branch": "main",
             "diff_refs": {"base_sha": "b0", "start_sha": "s0", "head_sha": "abc1"}}
            """
        let stub = StubServer { request in
            if let read = Self.commentReads(request) { return read }
            let path = request.url?.path(percentEncoded: true) ?? ""
            let query = Self.json(request)["query"] as? String ?? ""
            switch request.httpMethod ?? "" {
            case "DELETE": return .init(status: 204, body: "")
            case "PUT" where path.hasSuffix("/discussions/\(Self.threadID)"):
                return .init(body: Self.restDiscussion(Self.threadID, [
                    Self.restNote(200, by: 8, resolvable: true, resolved: true),
                ]))
            case "PUT": return .init(body: Self.restNote(200, by: 7))
            case "GET" where path == Self.mrPath + "/5": return .init(body: mrWithRefs)
            case "POST" where path == Self.graphQLPath:
                if query.contains("discussionToggleResolve") {
                    return .init(body: #"{"data": {"discussionToggleResolve": {"errors": [], "discussion": {"resolved": true}}}}"#)
                }
                let name = query.contains("awardEmojiAdd") ? "awardEmojiAdd" : "awardEmojiRemove"
                return .init(body: #"{"data": {"\#(name)": {"errors": []}}}"#)
            case "POST" where path == Self.mrPath + "/5/discussions" && Self.json(request)["position"] == nil:
                return .init(status: 201, body: Self.restDiscussion(Self.newThreadID, [
                    Self.restNote(700, by: 7, resolvable: true),
                ]))
            case "POST" where path == Self.mrPath + "/5/discussions":
                return .init(status: 201, body: Self.restDiscussion(Self.diffID, [
                    Self.restNote(310, by: 7, type: "DiffNote", resolvable: true, diff: true),
                ]))
            case "POST": return .init(status: 201, body: Self.restNote(600, by: 7))
            default: return .init(status: 404, body: "{}")
            }
        }
        let client = try Self.client(stub, refreshes: Self.refreshed())
        let repo = Self.writeRepo
        // The loads the detail did: they give the resolvable threads and the global ids the mutations take.
        _ = try await client.comments(on: .pullRequest(5), in: repo)
        _ = try await client.comments(on: .issue(3), in: repo)
        // The item's own awards ride the same GraphQL read, counted as a note's (default kinds first).
        #expect(try await client.itemReactions(of: .pullRequest(5), in: repo) == [
            HostedReaction(kind: "thumbsup", count: 1), HostedReaction(kind: "thumbsdown", count: 1, viewerReacted: true),
            HostedReaction(kind: "clap", count: 1, viewerReacted: true),
        ])
        #expect(try await client.itemReactions(of: .issue(3), in: repo).isEmpty)
        let mrRoot = HostedCommentRef(kind: .general, id: 200, hostKey: Self.threadID)
        let issueRoot = HostedCommentRef(kind: .general, id: 500, hostKey: Self.issueThreadID)
        let diffNote = HostedCommentRef(kind: .review, id: 300, hostKey: Self.diffID)
        func inline(_ position: HostedInlinePosition) async throws {
            let created = try await client.createInlineComment(at: position, on: 5, in: repo, body: "Hm")
            #expect(created.id == 310 && created.hostKey == Self.diffID && created.viewerCanEdit)
        }
        func base(_ old: String = "a.swift", _ new: String = "a.swift") -> [String: Any] {
            ["position_type": "text", "base_sha": "b0", "start_sha": "s0", "head_sha": "abc1", "old_path": old,
             "new_path": new]
        }
        func merged(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] { a.merging(b) { _, new in new } }
        let discussions = Self.mrPath + "/5/discussions"
        let rows: [(method: String, path: String, query: String?, body: [String: Any]?, run: () async throws -> Void)] = [
            ("POST", Self.mrPath + "/5/discussions/\(Self.threadID)/notes", nil, ["body": "hi"], {
                let reply = try await client.reply(toGeneral: mrRoot, on: .pullRequest(5), in: repo, body: "hi")
                #expect(reply.parentID == 200 && reply.hostKey == Self.threadID)
            }),
            ("POST", Self.issuePath + "/3/discussions/\(Self.issueThreadID)/notes", nil, ["body": "hi"], {
                _ = try await client.reply(toGeneral: issueRoot, on: .issue(3), in: repo, body: "hi")
            }),
            ("PUT", Self.mrPath + "/5/discussions/\(Self.threadID)", "resolved=true", nil, {
                let resolved = try await client.setGeneralThread(mrRoot, on: .pullRequest(5), in: repo, resolved: true)
                #expect(resolved)
            }),
            ("POST", Self.graphQLPath, nil, ["id": "gid://gitlab/Discussion/\(Self.issueThreadID)", "resolve": true], {
                let resolved = try await client.setGeneralThread(issueRoot, on: .issue(3), in: repo, resolved: true)
                #expect(resolved)
            }),
            ("PUT", Self.mrPath + "/5/notes/200", nil, ["body": "new"], {
                try await client.editComment(mrRoot, on: .pullRequest(5), in: repo, body: "new")
            }),
            ("PUT", Self.mrPath + "/5/notes/300", nil, ["body": "new"], {
                try await client.editComment(diffNote, on: .pullRequest(5), in: repo, body: "new")
            }),
            ("PUT", Self.issuePath + "/3/notes/500", nil, ["body": "new"], {
                try await client.editComment(issueRoot, on: .issue(3), in: repo, body: "new")
            }),
            ("DELETE", Self.mrPath + "/5/notes/200", nil, nil, {
                try await client.deleteComment(mrRoot, on: .pullRequest(5), in: repo)
            }),
            ("DELETE", Self.issuePath + "/3/notes/500", nil, nil, {
                try await client.deleteComment(issueRoot, on: .issue(3), in: repo)
            }),
            ("POST", Self.graphQLPath, nil, ["awardableId": "gid://gitlab/DiscussionNote/200", "name": "thumbsup"], {
                try await client.addReaction("thumbsup", to: mrRoot, on: .pullRequest(5), in: repo)
            }),
            ("POST", Self.graphQLPath, nil, ["awardableId": "gid://gitlab/Note/500", "name": "eyes"], {
                try await client.removeReaction("eyes", from: issueRoot, on: .issue(3), in: repo)
            }),
            ("POST", Self.graphQLPath, nil, ["awardableId": "gid://gitlab/MergeRequest/9005", "name": "thumbsup"], {
                try await client.addItemReaction("thumbsup", to: .pullRequest(5), in: repo)
            }),
            ("POST", Self.graphQLPath, nil, ["awardableId": "gid://gitlab/Issue/9003", "name": "thumbsdown"], {
                try await client.removeItemReaction("thumbsdown", from: .issue(3), in: repo)
            }),
            ("POST", discussions, nil, ["body": "Start"], {
                let thread = try await client.startThread(on: .pullRequest(5), in: repo, body: "Start")
                #expect(thread.id == 700 && thread.hostKey == Self.newThreadID && thread.parentID == nil)
                #expect(thread.resolvable == true && thread.resolved == false && thread.viewerCanEdit)
            }),
            ("POST", discussions, nil, ["body": "Hm", "position": merged(base(), ["new_line": 12])], {
                try await inline(.init(path: "a.swift", oldLine: nil, newLine: 12, lineKind: .added, headSHA: "abc1"))
            }),
            ("POST", discussions, nil, ["body": "Hm", "position": merged(base(), ["old_line": 8])], {
                try await inline(.init(path: "a.swift", oldLine: 8, newLine: nil, lineKind: .removed, headSHA: "abc1"))
            }),
            ("POST", discussions, nil,
             ["body": "Hm", "position": merged(base("old.swift", "b.swift"), [
                 "old_line": 10, "new_line": 14,
                 "line_range": ["start": ["old_line": 7, "new_line": 11], "end": ["old_line": 10, "new_line": 14]],
             ])], {
                try await inline(.init(
                    path: "b.swift", oldPath: "old.swift", oldLine: 10, newLine: 14, lineKind: .context,
                    startOldLine: 7, startNewLine: 11, headSHA: "abc1"))
            }),
            ("POST", discussions, nil,
             ["body": "Hm", "position": merged(base(), [
                 "new_line": 5,
                 "line_range": ["start": ["type": "new", "new_line": 3], "end": ["type": "new", "new_line": 5]],
             ])], {
                try await inline(.init(
                    path: "a.swift", oldLine: nil, newLine: 5, lineKind: .added, startNewLine: 3, headSHA: "abc1"))
            }),
        ]

        for (index, row) in rows.enumerated() {
            try await row.run()
            let request = try #require(stub.requests.last)
            #expect(request.httpMethod == row.method, "row \(index)")
            #expect(request.url?.host() == "git.example.com", "row \(index)")
            #expect(request.url?.path(percentEncoded: true) == row.path, "row \(index)")
            #expect(request.url?.query() == row.query, "row \(index)")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)", "row \(index)")
            guard let expected = row.body else {
                #expect(request.httpBody?.isEmpty ?? true, "row \(index)")
                continue
            }
            let body = Self.json(request)
            if row.path == Self.graphQLPath {
                let query = body["query"] as? String ?? ""
                for value in expected.values.compactMap({ $0 as? String }) {
                    #expect(!query.contains(value), "row \(index): a value in the query text")
                }
                #expect(NSDictionary(dictionary: body["variables"] as? [String: Any] ?? [:]).isEqual(to: expected),
                        "row \(index): \(body)")
            } else {
                #expect(NSDictionary(dictionary: body).isEqual(to: expected), "row \(index): \(body)")
            }
        }
        let graphQL = stub.requests.filter { $0.httpMethod == "POST" && $0.url?.path() == Self.graphQLPath }
            .compactMap { Self.json($0)["query"] as? String }
        #expect(graphQL.contains { $0.contains("discussionToggleResolve(input:") })
        #expect(graphQL.contains { $0.contains("awardEmojiAdd(input:") })
        #expect(graphQL.contains { $0.contains("awardEmojiRemove(input:") })

        let sent = stub.requests.count
        await #expect(throws: HostingError.self, "no discussion id") {
            _ = try await client.reply(
                toGeneral: .init(kind: .general, id: 200), on: .pullRequest(5), in: repo, body: "hi")
        }
        await #expect(throws: HostingError.self, "an individual note is not resolvable") {
            let individual = HostedCommentRef(kind: .general, id: 100, hostKey: Self.individualID)
            _ = try await client.setGeneralThread(individual, on: .pullRequest(5), in: repo, resolved: true)
        }
        await #expect(throws: HostingError.self, "a note without a global id") {
            try await client.addReaction("tada", to: .init(kind: .general, id: 999), on: .pullRequest(5), in: repo)
        }
        await #expect(throws: HostingError.self, "an added line without its new line") {
            try await inline(.init(path: "a.swift", oldLine: 4, newLine: nil, lineKind: .added, headSHA: "abc1"))
        }
        #expect(stub.requests.count == sent)
    }

    @Test("a new diff thread is refused unsent when the merge request has no diff_refs, or its head is not the patch's",
          arguments: [
              (#""diff_refs": null"#, false),
              (#""diff_refs": {"base_sha": "b0", "start_sha": "s0", "head_sha": "newer"}"#, true),
          ])
    func inlineCommentNeedsDiffRefs(refs: String, headChanged: Bool) async throws {
        let stub = StubServer { request in
            guard request.httpMethod == "GET" else { return .init(status: 201, body: "{}") }
            return .init(body: """
                {"id": 9005, "iid": 5, "title": "T", "state": "opened", "sha": "newer",
                 "web_url": "https://git.example.com/gitlab/group/proj/-/merge_requests/5",
                 "source_branch": "feature", "target_branch": "main", \(refs)}
                """)
        }
        let client = try Self.client(stub, refreshes: Self.refreshed())
        let position = HostedInlinePosition(
            path: "a.swift", oldLine: nil, newLine: 2, lineKind: .added, headSHA: "abc1")

        do {
            _ = try await client.createInlineComment(at: position, on: 5, in: Self.writeRepo, body: "Hm")
            Issue.record("expected a refusal")
        } catch HostingError.headChanged {
            #expect(headChanged)
        } catch HostingError.validationFailed {
            #expect(!headChanged)
        }
        #expect(stub.requests.map(\.httpMethod) == ["GET"], "only the merge request read, no POST")
    }

    @Test("history entries: every system note (inside a thread too) with GraphQL's action and icon, and the state, label and milestone events in Histq's words; resolved threads say who resolved them (GraphQL, else REST's resolved_by); a refused event list is left out")
    func historyEntriesAndResolvedBy() async throws {
        let resolvedNote = """
            {"id": 300, "type": "DiffNote", "body": "note 300", "author": \(Self.user(8, "u8")),
             "created_at": "2026-11-02T10:00:00Z", "system": false, "resolvable": true, "resolved": true,
             "resolved_by": \(Self.user(7, "u7")), "resolved_at": "2026-11-03T09:00:00Z",
             "position": {"old_path": "a.swift", "new_path": "a.swift", "new_line": 1}}
            """
        let discussions = "[" + [
            Self.restDiscussion(Self.threadID, [
                Self.restNote(200, by: 8, resolvable: true, resolved: true),
                Self.restNote(201, by: 7, resolvable: true, resolved: true),
                Self.restNote(202, by: 8, type: nil, system: true),
            ]),
            Self.restDiscussion(Self.diffID, [resolvedNote]),
            Self.restDiscussion(Self.systemID, individual: true, [Self.restNote(400, by: 8, type: nil, system: true)]),
        ].joined(separator: ", ") + "]"
        let graphQL = """
            {"data": {"project": {"mergeRequest": {"id": "gid://gitlab/MergeRequest/9005", "awardEmoji": {"nodes": []},
             "discussions": {"nodes": [
              {"id": "gid://gitlab/Discussion/\(Self.threadID)", "resolved": true,
               "resolvedAt": "2026-11-04T08:00:00Z", "resolvedBy": {"id": "gid://gitlab/User/8", "username": "u8",
               "name": "User 8", "avatarUrl": "https://git.example.com/a/8.png"},
               "notes": {"nodes": [
                {"id": "gid://gitlab/DiscussionNote/200", "userPermissions": {"adminNote": false}},
                {"id": "gid://gitlab/Note/202", "systemNoteIconName": "comment",
                 "systemNoteMetadata": {"action": "discussion"}}]}},
              {"id": "gid://gitlab/Discussion/\(Self.diffID)", "resolved": true, "resolvedAt": null,
               "resolvedBy": null, "notes": {"nodes": []}},
              {"id": "gid://gitlab/Discussion/\(Self.systemID)", "resolved": null,
               "notes": {"nodes": [{"id": "gid://gitlab/Note/400", "systemNoteIconName": "commit",
                                    "systemNoteMetadata": {"action": "commit"}}]}}],
             "pageInfo": {"hasNextPage": false, "endCursor": null}}}}}}
            """
        let stub = StubServer { request in
            let path = request.url?.path(percentEncoded: true) ?? ""
            switch path {
            case Self.mrPath + "/5/discussions": return .init(body: discussions)
            case Self.graphQLPath: return .init(body: graphQL)
            case "/gitlab/api/v4/user": return .init(body: Self.user(7, "me"))
            case Self.mrPath + "/5/resource_state_events":
                return .init(body: """
                    [{"id": 11, "user": \(Self.user(8, "u8")), "created_at": "2026-11-05T10:00:00Z", "state": "closed",
                      "source_merge_request": {"iid": 9}},
                     {"id": 12, "user": \(Self.user(8, "u8")), "created_at": "2026-11-06T10:00:00Z", "state": "opened"},
                     {"id": 13, "user": \(Self.user(7, "u7")), "created_at": "2026-11-07T10:00:00Z", "state": "merged"}]
                    """)
            case Self.mrPath + "/5/resource_label_events":
                return .init(body: """
                    [{"id": 21, "user": \(Self.user(7, "u7")), "created_at": "2026-11-05T11:00:00Z", "action": "add",
                      "label": {"id": 1, "name": "bug", "color": "#d73a4a"}},
                     {"id": 22, "user": \(Self.user(7, "u7")), "created_at": "2026-11-05T12:00:00Z",
                      "action": "remove", "label": {"id": 2, "name": "needs <b>review</b> *now*"}},
                     {"id": 23, "user": null, "created_at": "2026-11-05T13:00:00Z", "action": "add", "label": null}]
                    """)
            case Self.mrPath + "/5/resource_milestone_events":
                return .init(status: 403, body: #"{"message": "403 Forbidden"}"#)
            default: return .init(status: 404, body: #"{"message": "404 Not Found"}"#)
            }
        }
        let client = try Self.client(stub, refreshes: Self.refreshed())

        let events = try await client.timelineEvents(of: .pullRequest(5), in: Self.writeRepo)
        #expect(events.map(\.id) == [
            "note-202", "note-400", "state-11", "state-12", "state-13", "label-21", "label-22", "label-23",
        ])
        #expect(events.map(\.text) == [
            "note 202", "note 400", "closed via merge request !9", "reopened", "merged", "added ~bug label",
            #"removed ~"needs <b>review</b> *now*" label"#, "added a label",
        ])
        #expect(events[6].textHTML == "<p>removed ~&quot;needs &lt;b&gt;review&lt;/b&gt; *now*&quot; label</p>",
                "a host's label name is escaped plain text, never Markdown or HTML")
        #expect(events.map(\.action) == [
            "discussion", "commit", "state", "state", "state", "label", "label", "label",
        ])
        #expect(events.map(\.icon) == [
            "comment", "commit", "merge-request-close", "work-item-issue", "merge", "label", "label", "label",
        ])
        #expect(events[0].actor?.login == "u8" && events[2].actor?.login == "u8" && events[7].actor == nil)
        #expect(events[2].createdAt == ISO8601DateFormatter().date(from: "2026-11-05T10:00:00Z"))
        #expect(events[0].textHTML == "<p>note 202</p>\n", "the body through MarkdownHTML, never raw")
        #expect(!events.contains { $0.id.hasPrefix("milestone-") }, "a refused list is left out")

        let comments = try await client.comments(on: .pullRequest(5), in: Self.writeRepo)
        #expect(comments.map(\.id) == [200, 201], "system notes stay out of the comments")
        #expect(comments[0].resolvedBy?.login == "u8" && comments[0].resolvedBy?.id == 8, "GraphQL's resolver")
        #expect(comments[0].resolvedAt == ISO8601DateFormatter().date(from: "2026-11-04T08:00:00Z"))
        #expect(comments[1].resolvedBy == nil, "only the root")
        let reviewComments = try await client.reviewComments(of: 5, in: Self.writeRepo)
        #expect(reviewComments.first?.resolvedBy?.login == "u7", "REST's resolved_by without GraphQL's")
        #expect(reviewComments.first?.resolvedAt == ISO8601DateFormatter().date(from: "2026-11-03T09:00:00Z"))

        let query = stub.requests.first { $0.url?.path() == Self.graphQLPath }.map { Self.json($0)["query"] }
        #expect((query as? String)?.contains("systemNoteMetadata { action }") == true)
    }

    @Test("GitLab offers the comment interactions and its 8 default reactions")
    func commentCapabilities() throws {
        let client = try GitLabClient(host: "gitlab.com", session: .shared) { _ in Self.token }
        let wanted: HostingCapabilities = [
            .generalReplies, .resolveGeneralThreads, .editComments, .deleteComments, .reactions, .newInlineComments,
            .multiLineInlineComments,
        ]
        #expect(client.capabilities.isSuperset(of: wanted))
        #expect(client.reactionKinds == [
            "thumbsup", "thumbsdown", "laughing", "tada", "confused", "heart", "rocket", "eyes",
        ])
    }

    // MARK: - Approval box and merge box

    @Test("the merge box's fields map from the single merge request, the approval box's from approvals (none on Community Edition), the merge rules from the project; reviews and approvals share one approvals read")
    func mergeBoxFields() async throws {
        let mr = """
            {"id": 9005, "iid": 5, "title": "T", "state": "opened", "draft": false,
             "web_url": "https://git.example.com/gitlab/group/proj/-/merge_requests/5", "source_branch": "feature",
             "target_branch": "main", "sha": "abc1", "detailed_merge_status": "not_approved",
             "diverged_commits_count": 6, "rebase_in_progress": false, "user": {"can_merge": false},
             "force_remove_source_branch": true, "squash_on_merge": true, "merge_error": "Rebase failed"}
            """
        let stub = StubServer { request in
            let path = request.url?.path(percentEncoded: true) ?? ""
            if path == Self.mrPath + "/5/approvals" { Thread.sleep(forTimeInterval: 0.3) }
            return switch path {
            case Self.mrPath + "/5": .init(body: mr)
            case Self.mrPath + "/6": .init(body: Self.minimalMR(iid: 6))
            case Self.mrPath + "/5/approvals":
                .init(body: """
                    {"approved": false, "approvals_required": 2, "approvals_left": 1, "user_can_approve": true,
                     "user_has_approved": false, "approved_by": [{"user": \(Self.user(7, "ann")),
                     "approved_at": "2026-11-12T15:00:00Z"}]}
                    """)
            case Self.mrPath + "/6/approvals":
                .init(body: #"{"approved": false, "approved_by": [], "user_can_approve": true, "user_has_approved": false}"#)
            case Self.mrPath + "/5/reviewers": .init(body: "[]")
            case "/gitlab/api/v4/projects/group%2Fproj":
                .init(body: #"{"id": 1, "name": "proj", "path_with_namespace": "group/proj", "default_branch": "main", "merge_method": "ff", "squash_option": "default_on"}"#)
            default: .init(status: 404, body: "{}")
            }
        }
        let client = try Self.client(stub, refreshes: Self.refreshed())

        let pull = try await client.pullRequest(5, in: Self.writeRepo)
        let query = stub.requests.first?.url?.query() ?? ""
        #expect(query.contains("include_diverged_commits_count=true") && query.contains("include_rebase_in_progress=true"))
        #expect(pull.mergeDetails == HostedMergeDetails(
            status: "not_approved", commitsBehind: 6, viewerCanMerge: false, deletesSourceBranch: true,
            squashOnMerge: true, mergeError: "Rebase failed", rebaseInProgress: false))
        #expect(pull.mergeableState == "blocked", "the shared mapping is unchanged")
        let bare = try await client.pullRequest(6, in: Self.writeRepo)
        #expect(bare.mergeDetails == HostedMergeDetails(), "fields GitLab leaves out stay nil")

        async let reviews = client.reviews(of: 5, in: Self.writeRepo)
        async let approvals = client.approvals(of: 5, in: Self.writeRepo)
        let (reviewed, approved) = try await (reviews, approvals)
        #expect(reviewed.map(\.state) == ["APPROVED"])
        #expect(approved.required == 2 && approved.left == 1 && !approved.isOptional)
        #expect(approved.approvedBy.map(\.login) == ["ann"])
        #expect(approved.viewerCanApprove == true && approved.viewerHasApproved == false)
        #expect(stub.requests.count { $0.url?.path(percentEncoded: true) == Self.mrPath + "/5/approvals" } == 1)

        let community = try await client.approvals(of: 6, in: Self.writeRepo)
        #expect(community.required == nil && community.left == nil && community.isOptional)

        let info = try await client.repositoryInfo(Self.writeRepo)
        #expect(info.defaultBranch == "main" && info.mergeCommit == false && info.squashOption == .defaultOn)
        #expect(client.supportedMergeOptions == [.deleteSourceBranch])
        #expect(client.capabilities.contains(.rebaseSourceBranch))
    }

    @Test("the sidebar's milestone and time stats map from the single merge request and issue; left out or null, none", arguments: [
        (#", "milestone": {"id": 61, "iid": 1, "title": "1.0", "due_date": "2026-12-01"}, "time_stats": {"time_estimate": 5400, "total_time_spent": 1800, "human_time_estimate": "1h 30m", "human_total_time_spent": "30m"}"#,
         HostedMilestone?.some(HostedMilestone(title: "1.0", dueDate: "2026-12-01")),
         HostedTimeStats?.some(HostedTimeStats(estimate: 5400, spent: 1800, humanEstimate: "1h 30m", humanSpent: "30m"))),
        (#", "milestone": null, "time_stats": {"time_estimate": 0, "total_time_spent": 0, "human_time_estimate": null, "human_total_time_spent": null}"#,
         HostedMilestone?.none, HostedTimeStats?.some(HostedTimeStats())),
        ("", HostedMilestone?.none, HostedTimeStats?.none),
    ])
    func sidebarFields(fields: String, milestone: HostedMilestone?, timeStats: HostedTimeStats?) async throws {
        let issuePath = "/gitlab/api/v4/projects/group%2Fproj/issues"
        let stub = StubServer { request in
            switch request.url?.path(percentEncoded: true) ?? "" {
            case Self.mrPath + "/5":
                .init(body: String(Self.minimalMR().dropLast()) + fields + "}")
            case issuePath + "/3":
                .init(body: #"{"id": 9003, "iid": 3, "title": "I", "state": "opened", "#
                    + #""web_url": "https://git.example.com/gitlab/group/proj/-/issues/3"\#(fields)}"#)
            default: .init(status: 404, body: "{}")
            }
        }
        let client = try Self.client(stub, refreshes: Self.refreshed())

        let pull = try await client.pullRequest(5, in: Self.writeRepo)
        let issue = try await client.issue(3, in: Self.writeRepo)
        #expect(pull.milestone == milestone && pull.timeStats == timeStats)
        #expect(issue.milestone == milestone && issue.timeStats == timeStats)
        #expect(pull.timeStats?.isEmpty == timeStats.map { $0.estimate == 0 && $0.spent == 0 },
                "zero seconds read as no estimate or time spent")
        #expect(stub.requests.count == 2, "no request beyond the item's own read")
    }

    @Test("a merge sends should_remove_source_branch only when the options set it, true or false", arguments: [
        (Bool?.none, Bool?.none), (true, true), (false, false),
    ])
    func mergeOptionsBody(delete: Bool?, sent: Bool?) async throws {
        let stub = StubServer { _ in .init(body: Self.minimalMR()) }
        let client = try Self.client(stub, refreshes: Self.refreshed())

        try await client.merge(
            5, in: Self.writeRepo, method: .squash, sha: "abc1", options: HostedMergeOptions(deleteSourceBranch: delete))
        let body = Self.json(try #require(stub.requests.first))
        #expect(body["sha"] as? String == "abc1" && body["squash"] as? Bool == true)
        #expect(body["should_remove_source_branch"] as? Bool == sent)
        #expect(Set(body.keys) == (sent == nil ? ["sha", "squash"] : ["sha", "squash", "should_remove_source_branch"]))
    }

    /// What the rebase test's merge request reads answer, one after the other: the first is the head check.
    enum RebaseCase: Sendable, CustomTestStringConvertible {
        case done, failed, staleHead, stillRunning

        var testDescription: String { "\(self)" }
    }

    @Test("rebase checks the head, PUTs .../rebase, then polls the merge request until rebase_in_progress is false; merge_error is the failure, a moved head sends nothing, a rebase past the polls is still running", arguments: [
        RebaseCase.done, .failed, .staleHead, .stillRunning,
    ])
    func rebaseFlow(rebaseCase: RebaseCase) async throws {
        let reads = Mutex(0)
        let stub = StubServer { request in
            let path = request.url?.path(percentEncoded: true) ?? ""
            if request.httpMethod == "PUT", path == Self.mrPath + "/5/rebase" {
                return .init(status: 202, body: #"{"rebase_in_progress": true}"#)
            }
            guard request.httpMethod == "GET", path == Self.mrPath + "/5" else {
                return .init(status: 404, body: "{}")
            }
            let read = reads.withLock { count in
                count += 1
                return count
            }
            let sha = rebaseCase == .staleHead ? "moved" : "abc1"
            // The head check, one poll still running, then the answer.
            let running = read <= 2 || rebaseCase == .stillRunning
            let error = rebaseCase == .failed && !running ? #""Rebase failed. Please rebase locally""# : "null"
            return .init(body: """
                {"id": 9005, "iid": 5, "title": "T", "state": "opened", "source_branch": "feature",
                 "target_branch": "main", "sha": "\(sha)", "rebase_in_progress": \(running && read > 1),
                 "merge_error": \(error), "web_url": "https://git.example.com/gitlab/group/proj/-/merge_requests/5"}
                """)
        }
        var client = try Self.client(stub, refreshes: Self.refreshed())
        client.rebasePollDelays = [.zero, .zero, .zero]

        let result: (any Error)?
        do {
            try await client.rebaseSourceBranch(5, in: Self.writeRepo, sha: "abc1")
            result = nil
        } catch {
            result = error
        }
        let methods = stub.requests.map { $0.httpMethod ?? "" }
        switch rebaseCase {
        case .done:
            #expect(result == nil)
            #expect(methods == ["GET", "PUT", "GET", "GET"], "the head check, the rebase, a running poll, the done one")
            let put = stub.requests[1]
            #expect(put.httpBody == nil || put.httpBody?.isEmpty == true, "GitLab's rebase takes no sha")
            #expect(stub.requests[2].url?.query()?.contains("include_rebase_in_progress=true") == true)
        case .failed:
            #expect(result as? HostingError == .validationFailed(message: "Rebase failed. Please rebase locally"))
            #expect(methods == ["GET", "PUT", "GET", "GET"])
        case .staleHead:
            #expect(result as? HostingError == .headChanged)
            #expect(methods == ["GET"], "no rebase once the head moved")
        case .stillRunning:
            guard case HostingError.validationFailed(let message)? = result as? HostingError else {
                Issue.record("expected the still-running failure, got \(String(describing: result))")
                return
            }
            #expect(message.contains("still rebasing"))
            #expect(methods == ["GET", "PUT", "GET", "GET", "GET"], "one read per delay, then it stops")
        }
    }
}
