#if DEBUG
// DEBUG `-HistqGitHubStub YES`: the PRs tab, the PR and issue details and the create form without GitHub. `HostingStore`
// then uses the repository `stub/stub` on github.com (the fixtures' origin is a local bare repo, which names no GitHub
// repo), a fake token, and a `URLSession` whose only protocol is `GitHubStubProtocol`: it answers every request from
// the JSON below (PR #1's merge, a 409 when it is not pinned to its head, review, comment, close/reopen and a reply to
// a review thread's root, issue #2's comment and close/reopen, a create that always makes PR #3 with its reviewers,
// labels and assignees succeed, and on `/graphql` the review threads' states and resolve/unresolve, by operation name)
// and 404 for anything else, so a stub run never reaches the network. The data: user `stub`, open pull request #1 "Add
// feature" (`feature` into `main`, 2 commits, 1 changed file, 1 review, 1 comment, 1 check run) by `stub` with two
// review threads on `feature.txt` in review 701 (A on lines 4-6 with `stub`'s reply, unresolved; B on line 10,
// resolved), mergeable as `-HistqPRMergeable true|false|null` says (default true), open issue #2 assigned to `stub`
// with 1 comment, the repository's labels, assignable users and collaborators (`stub`, `reviewer`), default branch
// `main`, and the Welcome clone picker's `/user/repos` (`stub`'s and `acme`'s). The JSON has GitHub's shapes (search
// results are issue-shaped), so the stub exercises the same decoding as the real API.
//
// DEBUG `-HistqHostingStubKind gitlab` (with `-HistqGitHubStub YES`): the PRs tab and the details talk to `GitLabStub`
// instead, the same data in GitLab's v4 shapes through `GitLabClient` (the repository `stub/stub` on gitlab.com), on
// the same session (`GitHubStubProtocol` answers gitlab.com from `GitLabStub`). `-HistqHostingStubKind bitbucket`
// does the same with `BitbucketStub` (Bitbucket's 2.0 shapes through `BitbucketCloudClient`, the repository `stub/stub`
// on bitbucket.org, answered on api.bitbucket.org). The Welcome clone picker stays GitHub's.
import Foundation
import HistqCore

enum GitHubStub {
    static let isEnabled = AppState.launchFlag("-HistqGitHubStub") == "YES"
    static let repository = HostedRepository(host: "github.com", owner: "stub", name: "stub")
    /// Never a real token: nothing leaves the stub session.
    static let token = "histq_stub_fake_token"
    /// PR #1's head commit (the stub's check runs belong to it).
    static let headSHA = "1111111111111111111111111111111111111111"
    static let baseSHA = "2222222222222222222222222222222222222222"
    /// A head PR #1 had before a push: a merge pinned to it gets GitHub's 409 (`-HistqPRAction merge-stale`).
    static let staleSHA = "6666666666666666666666666666666666666666"

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubStubProtocol.self]
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    static func client() -> GitHubClient? {
        try? GitHubClient(host: repository.host, token: token, session: session)
    }

    /// DEBUG `-HistqHostingStubKind gitlab|bitbucket`: the PRs tab's stub serves GitLab's JSON (`GitLabStub`) or
    /// Bitbucket's (`BitbucketStub`), not GitHub's.
    static let kind: HostingKind = switch AppState.launchFlag("-HistqHostingStubKind") {
    case "gitlab": .gitlab
    case "bitbucket": .bitbucketCloud
    default: .github
    }

    /// The PRs tab's stub provider and repository: GitHub's, or GitLab's or Bitbucket's as `-HistqHostingStubKind`
    /// says.
    static func hosting() -> (client: (any HostingProvider)?, repository: HostedRepository) {
        switch kind {
        case .github: (client(), repository)
        case .gitlab: (GitLabStub.client(), GitLabStub.repository)
        case .bitbucketCloud: (BitbucketStub.client(), BitbucketStub.repository)
        }
    }

    /// The status and JSON body for a request of the stub session (`body`: the request's).
    static func reply(method: String, url: URL, body: Data?) -> (status: Int, body: String) {
        let repo = "/repos/\(repository.owner)/\(repository.name)"
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard url.host() == "api.github.com" else { return notFound }
        // The PR detail's actions answer as GitHub does, so their flows run in a stub launch; nothing changes (a
        // merged or closed #1 still reads as open on the reload).
        switch (method, url.path()) {
        case ("PUT", "\(repo)/pulls/1/merge"):
            // GitHub refuses a merge pinned to another head than the current one.
            let sha = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["sha"] as? String
            guard sha == headSHA else {
                return (409, #"{"message": "Head branch was modified. Review and try the merge again."}"#)
            }
            return (200, #"{"sha": "\#(headSHA)", "merged": true, "message": "Merged"}"#)
        case ("POST", "\(repo)/pulls/1/reviews"): return (200, review)
        case ("POST", "\(repo)/issues/1/comments"): return (201, comment)
        case ("PATCH", "\(repo)/issues/1"): return (200, pullAsIssue)
        case ("POST", "\(repo)/issues/2/comments"): return (201, issueComment)
        case ("PATCH", "\(repo)/issues/2"): return (200, issue)
        // A create always makes #3, whatever the form sent (the stub keeps no state); its follow-ups succeed.
        case ("POST", "\(repo)/pulls"): return (201, pull(3, full: true))
        case ("POST", "\(repo)/pulls/3/requested_reviewers"): return (201, pull(3, full: true))
        case ("POST", "\(repo)/issues/3/labels"): return (200, "[\(labels)]")
        case ("POST", "\(repo)/issues/3/assignees"): return (201, pull(3, full: true))
        // GitHub refuses a reply to a reply or to an unknown comment: only the two roots take one.
        case let ("POST", path) where path.hasPrefix("\(repo)/pulls/1/comments/") && path.hasSuffix("/replies"):
            let root = Int(path.split(separator: "/").dropLast().last ?? "")
            guard let root, [811, 813].contains(root) else { return notFound }
            return (201, reviewComment(814, review: 703, root: root, body: "Thanks, done.", at: "17:00"))
        case ("POST", "/graphql"): return graphQL(body)
        case ("GET", _): break
        default: return notFound
        }
        switch url.path() {
        case "/user": return (200, user)
        case "/user/repos": return (200, userRepos)
        case repo: return (200, #"{"full_name": "stub/stub", "default_branch": "main"}"#)
        case "\(repo)/labels": return (200, "[\(labels)]")
        case "\(repo)/assignees", "\(repo)/collaborators": return (200, "[\(user), \(reviewer)]")
        case "\(repo)/pulls": return (200, "[\(pull(1, full: false))]")
        case "\(repo)/pulls/1": return (200, pull(1, full: true))
        case "\(repo)/pulls/1/reviews": return (200, "[\(review), \(replyReview)]")
        case "\(repo)/pulls/1/comments": return (200, reviewComments)
        case "\(repo)/pulls/1/commits": return (200, commits)
        case "\(repo)/pulls/1/files": return (200, files)
        case "\(repo)/pulls/3": return (200, pull(3, full: true))
        case "\(repo)/pulls/3/reviews", "\(repo)/pulls/3/comments", "\(repo)/pulls/3/files",
             "\(repo)/issues/3/comments":
            return (200, "[]")
        case "\(repo)/pulls/3/commits": return (200, "[\(createdCommit)]")
        case "\(repo)/issues": return (200, "[\(issue), \(pullAsIssue)]")
        case "\(repo)/issues/1": return (200, pullAsIssue)
        case "\(repo)/issues/2": return (200, issue)
        case "\(repo)/issues/1/comments": return (200, "[\(pullComments)]")
        case "\(repo)/issues/2/comments": return (200, "[\(issueComment)]")
        case "\(repo)/commits/\(headSHA)/check-runs", "\(repo)/commits/feature/check-runs":
            return (200, #"{"total_count": 1, "check_runs": [\#(checkRun)]}"#)
        case let path where path.hasPrefix("\(repo)/commits/") && path.hasSuffix("/check-runs"):
            return (200, #"{"total_count": 0, "check_runs": []}"#)
        case "/search/issues":
            let q = query.first { $0.name == "q" }?.value ?? ""
            guard q.contains("repo:\(repository.fullName)") else { return (200, search([])) }
            if q.contains("author:@me") { return (200, search([pullAsIssue])) }
            if q.contains("assignee:@me") { return (200, search([issue])) }
            // `stub` opened #1, so no pull request asks them for a review: the card's empty state.
            return (200, search([]))
        default:
            return notFound
        }
    }

    private static let notFound = (404, #"{"message": "Not Found"}"#)

    private static let user = """
        {"id": 1001, "login": "stub", "name": "Stub User", "html_url": "https://github.com/stub",
         "avatar_url": "https://avatars.githubusercontent.com/u/1001"}
        """

    /// The Welcome page's clone picker: `stub`'s own repositories and an organization's, sorted by full name.
    private static let userRepos = "[" + [
        ("acme", "api-gateway", true), ("acme", "design-system", false), ("acme", "infra", true),
        ("stub", "dotfiles", false), ("stub", "stub", false),
    ].enumerated().map { index, repo in
        let (owner, name, isPrivate) = repo
        return """
            {"id": \(5000 + index), "name": "\(name)", "full_name": "\(owner)/\(name)", "private": \(isPrivate),
             "fork": false, "clone_url": "https://github.com/\(owner)/\(name).git",
             "owner": {"id": \(owner == "stub" ? 1001 : 2001), "login": "\(owner)"}}
            """
    }.joined(separator: ", ") + "]"

    private static let reviewer = """
        {"id": 1002, "login": "reviewer", "html_url": "https://github.com/reviewer",
         "avatar_url": "https://avatars.githubusercontent.com/u/1002"}
        """

    /// DEBUG `-HistqPRMergeable true|false|null|merged` (default true): PR #1's `mergeable` with the `mergeable_state`
    /// GitHub gives with it (`clean`, `dirty` for conflicts, `unknown` while it computes), for the merge box's states;
    /// `merged`: #1 is already merged (closed, `merged_at` set), for the Merged pill and box. The stub keeps no state,
    /// so null stays null on every fetch and the detail's re-poll runs out.
    private static let mergeable = switch AppState.launchFlag("-HistqPRMergeable") {
    case "false": #""mergeable": false, "mergeable_state": "dirty""#
    case "null", "merged": #""mergeable": null, "mergeable_state": "unknown""#
    default: #""mergeable": true, "mergeable_state": "clean""#
    }
    private static let isMerged = AppState.launchFlag("-HistqPRMergeable") == "merged"

    /// PR #1, or #3 as a create makes it (the fixture's one commit on `origin/feature` past `origin/main`).
    private static func pull(_ number: Int, full: Bool) -> String {
        let created = number == 3
        let detail = !full ? ""
            : created ? #", "merged": false, "mergeable": true, "commits": 1, "additions": 1, "deletions": 0, "changed_files": 0"#
            : isMerged ? #", "merged": true, "merged_at": "2026-11-12T17:00:00Z", \#(mergeable), "commits": 2, "additions": 12, "deletions": 3, "changed_files": 1"#
            : #", "merged": false, \#(mergeable), "commits": 2, "additions": 12, "deletions": 3, "changed_files": 1"#
        let title = created ? "Polish feature (pushed)" : "Add feature"
        let body = created ? "Polishes the feature." : "Adds the feature branch's work."
        return """
            {"id": \(500 + number), "number": \(number), "title": "\(title)",
             "state": "\(isMerged && !created && full ? "closed" : "open")", "draft": false,
             "html_url": "https://github.com/stub/stub/pull/\(number)", "user": \(user),
             "body": "\(body)", "body_html": "<p>\(body)</p>",
             "head": {"label": "stub:feature", "ref": "feature", "sha": "\(created ? createdSHA : headSHA)"},
             "base": {"label": "stub:main", "ref": "main", "sha": "\(baseSHA)"},
             "labels": [\(created ? "" : #"{"name": "enhancement", "color": "a2eeef", "description": "New feature"}"#)],
             "assignees": [\(user)], "requested_reviewers": [\(reviewer)],
             "created_at": "2026-11-10T09:00:00Z", "updated_at": "2026-11-12T16:30:00Z"\(detail)}
            """
    }

    /// PR #3's head commit.
    private static let createdSHA = "5555555555555555555555555555555555555555"

    private static let createdCommit = """
        {"sha": "\(createdSHA)", "html_url": "https://github.com/stub/stub/commit/5555555",
         "commit": {"message": "Polish feature (pushed)", "author": {"name": "Stub User", "email": "stub@histq.invalid",
                    "date": "2026-11-12T17:00:00Z"}}, "author": \(user)}
        """

    private static let labels = """
        {"name": "enhancement", "color": "a2eeef", "description": "New feature"},
        {"name": "bug", "color": "d73a4a", "description": "Something is not working"},
        {"name": "documentation", "color": "0075ca"}
        """

    private static let issueComment = """
        {"id": 802, "user": \(user), "body": "I can reproduce it on 0.1.", "body_html": "<p>I can reproduce it on 0.1.</p>",
         "html_url": "https://github.com/stub/stub/issues/2#issuecomment-802",
         "created_at": "2026-11-12T11:00:00Z", "updated_at": "2026-11-12T11:00:00Z"}
        """

    /// PR #1 as the issues API and search return it: issue-shaped, with `pull_request` and `draft`.
    private static let pullAsIssue = """
        {"id": 501, "number": 1, "title": "Add feature", "state": "open", "draft": false,
         "html_url": "https://github.com/stub/stub/pull/1", "user": \(user), "comments": 1,
         "body": "Adds the feature branch's work.", "labels": [{"name": "enhancement", "color": "a2eeef"}],
         "assignees": [\(user)], "created_at": "2026-11-10T09:00:00Z", "updated_at": "2026-11-12T16:30:00Z",
         "pull_request": {"url": "https://api.github.com/repos/stub/stub/pulls/1"}}
        """

    private static let issue = """
        {"id": 602, "number": 2, "title": "Crash when opening an empty repository", "state": "open",
         "html_url": "https://github.com/stub/stub/issues/2", "user": \(reviewer), "comments": 1,
         "body": "Steps: open an empty folder.", "body_html": "<p>Steps: open an empty folder.</p>",
         "labels": [{"name": "bug", "color": "d73a4a"}], "assignees": [\(user)],
         "created_at": "2026-11-11T08:00:00Z", "updated_at": "2026-11-12T10:00:00Z"}
        """

    private static let review = """
        {"id": 701, "user": \(reviewer), "state": "APPROVED", "body": "Looks good.", "body_html": "<p>Looks good.</p>",
         "html_url": "https://github.com/stub/stub/pull/1#pullrequestreview-701", "submitted_at": "2026-11-12T15:00:00Z"}
        """

    /// The review GitHub made for `stub`'s reply 812 in thread A, as it lists it: commented, without text of its own.
    /// The timeline hides it, as GitHub does.
    private static let replyReview = """
        {"id": 702, "user": \(user), "state": "COMMENTED", "body": "", "body_html": "",
         "html_url": "https://github.com/stub/stub/pull/1#pullrequestreview-702",
         "submitted_at": "2026-11-12T16:00:00Z"}
        """

    private static let comment = """
        {"id": 801, "user": \(reviewer), "body": "Nice work.", "body_html": "<p>Nice work.</p>",
         "html_url": "https://github.com/stub/stub/pull/1#issuecomment-801",
         "created_at": "2026-11-12T14:00:00Z", "updated_at": "2026-11-12T14:00:00Z"}
        """

    /// DEBUG `-HistqPRStubComments <n>` (up to 600): PR #1's issue comments are n generated ones instead of `comment`,
    /// a minute apart from 12:00, for a conversation longer than the panel. Every third has a long line of code, which
    /// a fit page must wrap.
    private static let pullComments: String = {
        guard let count = AppState.launchFlag("-HistqPRStubComments").flatMap(Int.init), count >= 0 else {
            return comment
        }
        return (0..<min(count, 600)).map { index in
            let id = 10_000 + index
            let text = "Comment \(index + 1) of a long conversation."
            let line = "let total = items.map { $0.price * $0.count }.reduce(0, +); "
            let code = index % 3 != 2 ? "" : "<pre><code>\(String(repeating: line, count: 4))</code></pre>"
            let date = String(format: "2026-11-12T%02d:%02d:00Z", 12 + index / 60, index % 60)
            return """
                {"id": \(id), "user": \(index.isMultiple(of: 2) ? reviewer : user), "body": "\(text)",
                 "body_html": "<p>\(text)</p>\(code)",
                 "html_url": "https://github.com/stub/stub/pull/1#issuecomment-\(id)",
                 "created_at": "\(date)", "updated_at": "\(date)"}
                """
        }.joined(separator: ", ")
    }()

    /// PR #1's inline review comments on `feature.txt`, as GitHub lists them: thread A (root 811 on lines 4-6,
    /// unresolved) with `stub`'s reply 812, which GitHub files in a review of its own (`replyReview`, 702), and
    /// thread B (root 813 on line 10, resolved), both roots in review 701.
    private static let reviewComments = "[" + [
        reviewComment(811, review: 701, root: nil, body: "Could the three steps be one sentence?", at: "14:55"),
        reviewComment(812, review: 702, root: 811, body: "I kept the list: it reads better.", at: "16:00"),
        reviewComment(813, review: 701, root: nil, body: "Show the output flag in the usage too.", at: "14:57"),
    ].joined(separator: ", ") + "]"

    /// A comment of thread A (root 811: lines 4-6, the numbered list) or B (root 813: line 10, the usage line), by
    /// `reviewer` for a root and `stub` for a reply. Its `diff_hunk` is GitHub's: the file patch's hunk header, then
    /// its rows down to the commented line; a reply repeats its root's lines and hunk.
    private static func reviewComment(_ id: Int, review: Int, root: Int?, body: String, at time: String) -> String {
        let onList = (root ?? id) == 811
        let lines = onList
            ? #""start_line": 4, "original_start_line": 4, "start_side": "RIGHT", "line": 6, "original_line": 6"#
            : #""start_line": null, "original_start_line": null, "start_side": null, "line": 10, "original_line": 10"#
        let hunk = onList ? listHunk : listHunk + #"\n+\n+Usage:\n+\n+    feature --input file"#
        let reply = root.map { #" "in_reply_to_id": \#($0),"# } ?? ""
        return """
            {"id": \(id), "pull_request_review_id": \(review),\(reply) "path": "feature.txt", \(lines),
             "side": "RIGHT", "diff_hunk": "\(hunk)", "commit_id": "\(headSHA)", "original_commit_id": "\(headSHA)",
             "user": \(root == nil ? reviewer : user), "body": "\(body)", "body_html": "<p>\(body)</p>",
             "html_url": "https://github.com/stub/stub/pull/1#discussion_r\(id)",
             "created_at": "2026-11-12T\(time):00Z", "updated_at": "2026-11-12T\(time):00Z"}
            """
    }

    /// `feature.txt`'s hunk in `files` down to new line 6, the end of the numbered list.
    private static let listHunk = #"@@ -1,5 +1,14 @@\n # Feature\n-TODO: write the feature\n-old line"#
        + #"\n-another old line\n+The feature does three things:\n+\n+1. reads the input\n+2. checks it"#
        + #"\n+3. writes the output"#

    /// The GraphQL node ids of threads A and B.
    private static let threadA = "PRRT_stub811", threadB = "PRRT_stub813"

    /// GitHub's GraphQL API, matched by the operation's name in the query: `ReviewThreadStates` (the two threads'
    /// states, joined on their roots' ids, so another PR's empty comments join none) and a resolve or unresolve of
    /// thread A or B, which succeeds without changing anything. Like GitHub, an unknown operation or thread gets 200
    /// with `errors`.
    private static func graphQL(_ body: Data?) -> (status: Int, body: String) {
        let request = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let query = request?["query"] as? String ?? ""
        // `contains` is case-sensitive, so neither operation's name is in the other's: the order does not matter.
        let unresolve = query.contains("UnresolveReviewThread")
        if unresolve || query.contains("ResolveReviewThread") {
            let id = (request?["variables"] as? [String: Any])?["threadId"] as? String
            guard let id, [threadA, threadB].contains(id) else {
                return (200, #"{"data": null, "errors": [{"message": "Could not resolve to a node with this id."}]}"#)
            }
            let field = unresolve ? "unresolveReviewThread" : "resolveReviewThread"
            return (200, #"{"data": {"\#(field)": {"thread": {"isResolved": \#(!unresolve)}}}}"#)
        }
        guard query.contains("ReviewThreadStates") else {
            return (200, #"{"data": null, "errors": [{"message": "Unknown operation."}]}"#)
        }
        // GitHub lets the viewer resolve only an unresolved thread and unresolve only a resolved one. The roots' ids
        // are in `fullDatabaseId`, the only id github.com is asked for, a string for A and a number for B, so both
        // threads joining proves each form decodes.
        let nodes = [(threadA, "\"811\"", false), (threadB, "813", true)].map { id, root, resolved in
            """
            {"id": "\(id)", "isResolved": \(resolved), "isOutdated": false, "viewerCanResolve": \(!resolved),
             "viewerCanUnresolve": \(resolved),
             "comments": {"nodes": [{"fullDatabaseId": \(root)}]}}
            """
        }.joined(separator: ", ")
        return (200, #"{"data": {"repository": {"pullRequest": {"reviewThreads": {"nodes": [\#(nodes)], "#
            + #""pageInfo": {"hasNextPage": false, "endCursor": null}}}}}}"#)
    }

    private static let checkRun = """
        {"id": 901, "name": "build", "status": "completed", "conclusion": "success",
         "html_url": "https://github.com/stub/stub/runs/901",
         "started_at": "2026-11-12T16:31:00Z", "completed_at": "2026-11-12T16:35:00Z"}
        """

    private static let commits = """
        [{"sha": "3333333333333333333333333333333333333333", "html_url": "https://github.com/stub/stub/commit/3333333",
          "commit": {"message": "Start the feature", "author": {"name": "Stub User", "email": "stub@histq.invalid",
                     "date": "2026-11-10T08:50:00Z"}}, "author": \(user)},
         {"sha": "\(headSHA)", "html_url": "https://github.com/stub/stub/commit/1111111",
          "commit": {"message": "Finish the feature", "author": {"name": "Stub User", "email": "stub@histq.invalid",
                     "date": "2026-11-12T16:20:00Z"}}, "author": \(user)}]
        """

    private static let files = """
        [{"sha": "4444444444444444444444444444444444444444", "filename": "feature.txt", "status": "modified",
          "additions": 12, "deletions": 3, "changes": 15,
          "patch": "@@ -1,5 +1,14 @@\\n # Feature\\n-TODO: write the feature\\n-old line\\n-another old line\\n+The feature does three things:\\n+\\n+1. reads the input\\n+2. checks it\\n+3. writes the output\\n+\\n+Usage:\\n+\\n+    feature --input file\\n+\\n+See the docs for details.\\n+Done.\\n End."}]
        """

    private static func search(_ items: [String]) -> String {
        #"{"total_count": \#(items.count), "incomplete_results": false, "items": [\#(items.joined(separator: ", "))]}"#
    }
}

/// `GitHubStub`'s data in GitLab's REST v4 shapes, for `GitLabClient` (`-HistqHostingStubKind gitlab`): user `stub`,
/// open merge request !1 "Add feature" (`feature` into `main` of the same project, 2 commits, 1 changed file, a comment
/// and a system note, approved by `reviewer`, a head pipeline and 1 commit status) with two diff discussions on
/// `feature.txt` (A on lines 4-6 with `stub`'s reply, unresolved; B on line 10, resolved), its `detailed_merge_status`
/// as `-HistqPRMergeable true|false|null` says (`mergeable`, `conflict`, `checking`), open issue #2 assigned to `stub`
/// with 1 note, the project's labels and users. The writes answer as GitLab does and change nothing: a note, a reply
/// to A or B, resolve/unresolve of A or B, approve, unapprove, a change request (GraphQL), a merge (409 unless pinned
/// to the head), close/reopen, and a create that always makes !3. Anything else is 404.
enum GitLabStub {
    static let repository = HostedRepository(host: "gitlab.com", owner: "stub", name: "stub")

    static func client() -> GitLabClient? {
        try? GitLabClient(host: repository.host, session: GitHubStub.session) { _ in GitHubStub.token }
    }

    /// The status and JSON body for a request of the stub session to gitlab.com (`body`: the request's).
    static func reply(method: String, url: URL, body: Data?) -> (status: Int, body: String) {
        let project = "/api/v4/projects/stub%2Fstub"
        let mr1 = "\(project)/merge_requests/1", mr3 = "\(project)/merge_requests/3"
        let query = url.query() ?? ""
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let path = url.path(percentEncoded: true)
        switch (method, path) {
        case ("PUT", "\(mr1)/merge"):
            guard json["sha"] as? String == GitHubStub.headSHA else {
                return (409, #"{"message": "SHA does not match HEAD of source branch"}"#)
            }
            return (200, mergeRequest(1, full: true))
        case ("POST", "\(mr1)/approve"):
            guard json["sha"].map({ $0 as? String == GitHubStub.headSHA }) ?? true else {
                return (409, #"{"message": "SHA does not match HEAD of source branch"}"#)
            }
            return (201, #"{"approved": true, "approved_by": [\#(approver(reviewer)), \#(approver(user))]}"#)
        case ("POST", "\(mr1)/unapprove"):
            return (201, #"{"approved": true, "approved_by": [\#(approver(reviewer))]}"#)
        case ("POST", "/api/graphql"):
            guard (json["query"] as? String)?.contains("mergeRequestRequestChanges") == true else { return notFound }
            return (200, #"{"data": {"mergeRequestRequestChanges": {"errors": [], "mergeRequest": {"iid": "1"}}}}"#)
        case ("POST", "\(mr1)/notes"): return (201, note(803, by: user, body: "Thanks.", at: "17:00"))
        case ("PUT", mr1): return (200, mergeRequest(1, full: true))
        case ("POST", "\(project)/issues/2/notes"): return (201, note(804, by: user, body: "Thanks.", at: "17:00"))
        case ("PUT", "\(project)/issues/2"): return (200, issue)
        // A create always makes !3, whatever the form sent; its follow-ups (reviewers, labels, assignees) succeed.
        case ("POST", "\(project)/merge_requests"): return (201, mergeRequest(3, full: true))
        case ("PUT", mr3): return (200, mergeRequest(3, full: true))
        case let ("POST", path) where path.hasPrefix("\(mr1)/discussions/") && path.hasSuffix("/notes"):
            let id = path.split(separator: "/").dropLast().last.map(String.init)
            guard let id, [threadA, threadB].contains(id) else { return notFound }
            return (201, diffNote(814, by: user, body: "Thanks, done.", onList: id == threadA, resolved: id == threadB,
                                  at: "17:00"))
        case let ("PUT", path) where path.hasPrefix("\(mr1)/discussions/"):
            let id = String(path.dropFirst("\(mr1)/discussions/".count))
            guard [threadA, threadB].contains(id) else { return notFound }
            return (200, discussion(id, resolved: query.contains("resolved=true")))
        case ("GET", _): break
        default: return notFound
        }
        switch path {
        case "/api/v4/user": return (200, user)
        case project:
            return (200, #"{"id": 3001, "name": "stub", "path_with_namespace": "stub/stub", "default_branch": "main", "#
                + #""visibility": "private", "http_url_to_repo": "https://gitlab.com/stub/stub.git"}"#)
        case "\(project)/labels": return (200, "[\(labels)]")
        case "\(project)/users": return (200, "[\(user), \(reviewer)]")
        // The open list and My MRs (`author_id`) have !1; no merge request asks `stub` for a review.
        case "\(project)/merge_requests":
            let open = query.contains("state=opened") && !query.contains("reviewer_id=")
            return (200, open ? "[\(mergeRequest(1, full: false))]" : "[]")
        case mr1: return (200, mergeRequest(1, full: true))
        case "\(mr1)/notes":
            return (200, "[\(note(801, by: reviewer, body: "Nice work.", at: "14:00")), \(systemNote)]")
        case "\(mr1)/discussions":
            return (200, "[\(discussion(threadA, resolved: false)), \(discussion(threadB, resolved: true)), "
                + #"{"id": "0000000000000000000000000000000000000801", "individual_note": true, "notes": ["#
                + note(801, by: reviewer, body: "Nice work.", at: "14:00") + "]}]")
        case "\(mr1)/approvals": return (200, #"{"approved": true, "approved_by": [\#(approver(reviewer))]}"#)
        case "\(mr1)/reviewers":
            return (200, #"[{"user": \#(reviewer), "state": "approved", "created_at": "2026-11-10T09:00:00Z"}]"#)
        // GitLab lists a merge request's commits newest first.
        case "\(mr1)/commits":
            return (200, "[\(commit(GitHubStub.headSHA, "Finish the feature", "2026-11-12T16:20:00Z")), "
                + "\(commit("3333333333333333333333333333333333333333", "Start the feature", "2026-11-10T08:50:00Z"))]")
        case "\(mr1)/diffs": return (200, diffs)
        case mr3: return (200, mergeRequest(3, full: true))
        case "\(mr3)/notes", "\(mr3)/discussions", "\(mr3)/diffs", "\(mr3)/reviewers": return (200, "[]")
        case "\(mr3)/approvals": return (200, #"{"approved": false, "approved_by": []}"#)
        case "\(mr3)/commits":
            return (200, "[\(commit(createdSHA, "Polish feature (pushed)", "2026-11-12T17:00:00Z"))]")
        case "\(project)/repository/commits/\(GitHubStub.headSHA)/statuses":
            return (200, """
                [{"id": 901, "name": "build", "status": "success", "allow_failure": false,
                  "target_url": "https://gitlab.com/stub/stub/-/jobs/901",
                  "started_at": "2026-11-12T16:31:00Z", "finished_at": "2026-11-12T16:35:00Z"}]
                """)
        case let path where path.hasPrefix("\(project)/repository/commits/") && path.hasSuffix("/statuses"):
            return (200, "[]")
        case "\(project)/issues": return (200, "[\(issue)]")
        case "\(project)/issues/2": return (200, issue)
        case "\(project)/issues/2/notes":
            return (200, "[\(note(802, by: user, body: "I can reproduce it on 0.1.", at: "11:00"))]")
        default: return notFound
        }
    }

    private static let notFound = (404, #"{"message": "404 Not Found"}"#)

    private static let user = """
        {"id": 1001, "username": "stub", "name": "Stub User", "web_url": "https://gitlab.com/stub",
         "avatar_url": "https://gitlab.com/uploads/-/system/user/avatar/1001/avatar.png"}
        """

    private static let reviewer = """
        {"id": 1002, "username": "reviewer", "name": "Reviewer", "web_url": "https://gitlab.com/reviewer",
         "avatar_url": "https://gitlab.com/uploads/-/system/user/avatar/1002/avatar.png"}
        """

    private static func approver(_ user: String) -> String {
        #"{"user": \#(user), "approved_at": "2026-11-12T15:00:00Z"}"#
    }

    /// `-HistqPRMergeable` (default true) as `detailed_merge_status`: `mergeable`, `conflict`, or `checking`.
    private static let mergeStatus = switch AppState.launchFlag("-HistqPRMergeable") {
    case "false": "conflict"
    case "null": "checking"
    default: "mergeable"
    }

    /// !3's head commit.
    private static let createdSHA = "5555555555555555555555555555555555555555"

    /// !1, or !3 as a create makes it; `full` is the single merge request (`render_html`, label names, the head
    /// pipeline), else a list's row (labels with details).
    private static func mergeRequest(_ iid: Int, full: Bool) -> String {
        let created = iid == 3
        let title = created ? "Polish feature (pushed)" : "Add feature"
        let body = created ? "Polishes the feature." : "Adds the feature branch's work."
        let head = created ? createdSHA : GitHubStub.headSHA
        let labels = created ? "" : full ? #""enhancement""#
            : ##"{"name": "enhancement", "color": "#a2eeef", "description": "New feature"}"##
        let pipeline = !full || created ? "" : """
            , "head_pipeline": {"id": 9001, "status": "success", "ref": "refs/merge-requests/1/head", "sha": "\(head)",
             "web_url": "https://gitlab.com/stub/stub/-/pipelines/9001", "created_at": "2026-11-12T16:30:00Z",
             "started_at": "2026-11-12T16:31:00Z", "finished_at": "2026-11-12T16:36:00Z"}
            """
        return """
            {"id": \(500 + iid), "iid": \(iid), "title": "\(title)", "description": "\(body)",
             "description_html": "<p>\(body)</p>", "state": "opened", "draft": false, "author": \(user),
             "assignees": [\(user)], "reviewers": [\(reviewer)], "labels": [\(labels)],
             "web_url": "https://gitlab.com/stub/stub/-/merge_requests/\(iid)", "source_branch": "feature",
             "target_branch": "main", "source_project_id": 3001, "target_project_id": 3001, "sha": "\(head)",
             "diff_refs": {"base_sha": "\(GitHubStub.baseSHA)", "head_sha": "\(head)",
                           "start_sha": "\(GitHubStub.baseSHA)"},
             "created_at": "2026-11-10T09:00:00Z", "updated_at": "2026-11-12T16:30:00Z",
             "detailed_merge_status": "\(created ? "mergeable" : mergeStatus)", "changes_count": "1",
             "user_notes_count": 4\(pipeline)}
            """
    }

    private static let labels = """
        {"id": 1, "name": "enhancement", "color": "#a2eeef", "description": "New feature"},
        {"id": 2, "name": "bug", "color": "#d73a4a", "description": "Something is not working"},
        {"id": 3, "name": "documentation", "color": "#0075ca"}
        """

    private static let issue = """
        {"id": 602, "iid": 2, "title": "Crash when opening an empty repository", "state": "opened",
         "description": "Steps: open an empty folder.", "author": \(reviewer), "assignees": [\(user)],
         "labels": [{"name": "bug", "color": "#d73a4a"}], "web_url": "https://gitlab.com/stub/stub/-/issues/2",
         "user_notes_count": 1, "created_at": "2026-11-11T08:00:00Z", "updated_at": "2026-11-12T10:00:00Z"}
        """

    /// A plain note (a comment) at `time` on 2026-11-12.
    private static func note(_ id: Int, by author: String, body: String, at time: String) -> String {
        """
        {"id": \(id), "type": null, "body": "\(body)", "author": \(author), "created_at": "2026-11-12T\(time):00Z",
         "system": false, "resolvable": false}
        """
    }

    /// GitLab's own note of a push: never a comment.
    private static let systemNote = """
        {"id": 850, "type": null, "body": "added 1 commit", "author": \(user), "created_at": "2026-11-12T16:20:00Z",
         "system": true, "resolvable": false}
        """

    /// The ids of diff discussions A and B.
    private static let threadA = "a811a811a811a811a811a811a811a811a811a811"
    private static let threadB = "b813b813b813b813b813b813b813b813b813b813"

    /// Discussion A (root 811 by `reviewer` on lines 4-6 with `stub`'s reply 812) or B (root 813 on line 10), every
    /// note `resolved` as given.
    private static func discussion(_ id: String, resolved: Bool) -> String {
        let notes = id == threadA
            ? [diffNote(811, by: reviewer, body: "Could the three steps be one sentence?", onList: true,
                        resolved: resolved, at: "14:55"),
               diffNote(812, by: user, body: "I kept the list: it reads better.", onList: true, resolved: resolved,
                        at: "16:00")]
            : [diffNote(813, by: reviewer, body: "Show the output flag in the usage too.", onList: false,
                        resolved: resolved, at: "14:57")]
        return #"{"id": "\#(id)", "individual_note": false, "notes": [\#(notes.joined(separator: ", "))]}"#
    }

    /// A note on `feature.txt` at the head: new lines 4-6 (the numbered list) or new line 10 (the usage line).
    private static func diffNote(
        _ id: Int, by author: String, body: String, onList: Bool, resolved: Bool, at time: String
    ) -> String {
        let range = !onList ? "" : #", "line_range": {"start": {"type": "new", "old_line": null, "new_line": 4}, "#
            + #""end": {"type": "new", "old_line": null, "new_line": 6}}"#
        return """
            {"id": \(id), "type": "DiffNote", "body": "\(body)", "author": \(author),
             "created_at": "2026-11-12T\(time):00Z", "system": false, "resolvable": true, "resolved": \(resolved),
             "position": {"base_sha": "\(GitHubStub.baseSHA)", "start_sha": "\(GitHubStub.baseSHA)",
              "head_sha": "\(GitHubStub.headSHA)", "old_path": "feature.txt", "new_path": "feature.txt",
              "position_type": "text", "old_line": null, "new_line": \(onList ? 6 : 10)\(range)}}
            """
    }

    private static func commit(_ sha: String, _ title: String, _ date: String) -> String {
        """
        {"id": "\(sha)", "short_id": "\(sha.prefix(8))", "title": "\(title)", "message": "\(title)",
         "author_name": "Stub User", "author_email": "stub@histq.invalid", "authored_date": "\(date)",
         "web_url": "https://gitlab.com/stub/stub/-/commit/\(sha)"}
        """
    }

    /// `feature.txt`'s diff, the same patch as `GitHubStub`'s `files`.
    private static let diffs = """
        [{"old_path": "feature.txt", "new_path": "feature.txt", "a_mode": "100644", "b_mode": "100644",
          "new_file": false, "renamed_file": false, "deleted_file": false, "generated_file": false,
          "collapsed": false, "too_large": false,
          "diff": "@@ -1,5 +1,14 @@\\n # Feature\\n-TODO: write the feature\\n-old line\\n-another old line\\n+The feature does three things:\\n+\\n+1. reads the input\\n+2. checks it\\n+3. writes the output\\n+\\n+Usage:\\n+\\n+    feature --input file\\n+\\n+See the docs for details.\\n+Done.\\n End."}]
        """
}

/// `GitHubStub`'s data in Bitbucket Cloud's 2.0 shapes, for `BitbucketCloudClient` (`-HistqHostingStubKind bitbucket`):
/// user `stub`, open pull request #1 "Add feature" (`feature` into `main` of the same repository, 2 commits, 1 changed
/// file, a comment, approved by `reviewer`, 1 commit status) with two inline threads on `feature.txt` (A on lines 4-6
/// with `stub`'s reply, unresolved; B on line 10, resolved), and open pull request #2 "Fix typo" by `reviewer` from the
/// fork `reviewer/stub` with `stub` as its reviewer (Checkout Locally is unavailable for it). Heads are abbreviated to
/// 12 hex digits, as Bitbucket gives them. Reads only: any write, and anything else, is 404.
enum BitbucketStub {
    static let repository = HostedRepository(host: "bitbucket.org", owner: "stub", name: "stub")
    /// The host the client's requests go to.
    static let apiHost = "api.bitbucket.org"

    static func client() -> BitbucketCloudClient {
        BitbucketCloudClient(session: GitHubStub.session) { _ in GitHubStub.token }
    }

    /// The status and JSON (or, for a diff, text) body for a GET of the stub session to api.bitbucket.org.
    static func reply(method: String, url: URL) -> (status: Int, body: String) {
        let repo = "/2.0/repositories/stub/stub", pr1 = "\(repo)/pullrequests/1", pr2 = "\(repo)/pullrequests/2"
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
        guard method == "GET" else { return notFound }
        switch url.path(percentEncoded: false) {
        case "/2.0/user": return (200, user)
        case repo:
            return (200, #"{"uuid": "{r-0001}", "full_name": "stub/stub", "name": "stub", "is_private": true, "#
                + #""mainbranch": {"name": "main"}}"#)
        case "/2.0/workspaces/stub/members": return page(#"{"user": \#(user)}"#, #"{"user": \#(reviewer)}"#)
        // All open has #1 and #2; `stub` opened #1 and is asked to review #2.
        case "\(repo)/pullrequests":
            if q?.hasPrefix("author.uuid") == true { return page(pullRequest(1)) }
            if q?.hasPrefix("reviewers.uuid") == true { return page(pullRequest(2)) }
            return page(pullRequest(1), pullRequest(2))
        case pr1: return (200, pullRequest(1))
        case pr2: return (200, pullRequest(2))
        case "\(pr1)/comments":
            return page(
                comment(801, by: reviewer, body: "Nice work.", at: "14:00"),
                comment(811, by: reviewer, body: "Could the three steps be one sentence?", at: "14:55",
                        inline: #"{"path": "feature.txt", "from": null, "to": 6, "start_from": null, "start_to": 4}"#),
                comment(812, by: user, body: "I kept the list: it reads better.", at: "16:00", parent: 811,
                        inline: #"{"path": "feature.txt", "from": null, "to": 6}"#),
                comment(813, by: reviewer, body: "Show the output flag in the usage too.", at: "14:57",
                        inline: #"{"path": "feature.txt", "from": null, "to": 10}"#, resolved: true))
        // Bitbucket lists a pull request's commits newest first.
        case "\(pr1)/commits":
            return page(commit(GitHubStub.headSHA, "Finish the feature", "2026-11-12T16:20:00", parent: startSHA),
                        commit(startSHA, "Start the feature", "2026-11-10T08:50:00", parent: GitHubStub.baseSHA))
        case "\(pr1)/diff": return (200, diff)
        case "\(pr2)/comments": return page()
        case "\(pr2)/commits":
            return page(commit(forkSHA, "Fix a typo", "2026-11-13T09:00:00", parent: GitHubStub.baseSHA))
        case "\(pr2)/diff": return (200, "")
        case "\(repo)/commit/\(GitHubStub.headSHA.prefix(12))/statuses":
            return page("""
                {"key": "build", "name": "build", "state": "SUCCESSFUL",
                 "url": "https://bitbucket.org/stub/stub/pipelines/results/901",
                 "created_on": "2026-11-12T16:31:00.000000+00:00", "updated_on": "2026-11-12T16:35:00.000000+00:00"}
                """)
        case let path where path.hasPrefix("\(repo)/commit/") && path.hasSuffix("/statuses"): return page()
        default: return notFound
        }
    }

    private static let notFound = (404, #"{"type": "error", "error": {"message": "Resource not found"}}"#)

    /// A list page without a `next`.
    private static func page(_ values: String...) -> (status: Int, body: String) {
        (200, #"{"pagelen": 50, "values": [\#(values.joined(separator: ", "))]}"#)
    }

    private static func account(_ uuid: String, _ nickname: String, _ name: String) -> String {
        """
        {"type": "user", "uuid": "{\(uuid)}", "nickname": "\(nickname)", "display_name": "\(name)",
         "links": {"html": {"href": "https://bitbucket.org/\(uuid)/"},
                   "avatar": {"href": "https://bitbucket.org/account/\(nickname)/avatar/"}}}
        """
    }

    private static let user = account("u-1001", "stub", "Stub User")
    private static let reviewer = account("u-1002", "reviewer", "Reviewer")

    private static func repository(_ uuid: String, _ fullName: String) -> String {
        #"{"type": "repository", "uuid": "{\#(uuid)}", "full_name": "\#(fullName)", "name": "stub"}"#
    }

    /// The second commit of #1, and #2's head.
    private static let startSHA = "3333333333333333333333333333333333333333"
    private static let forkSHA = "7777777777777777777777777777777777777777"

    /// #1 (from `feature` of this repository, by `stub`, approved by `reviewer`) or #2 (from `typo` of the fork
    /// `reviewer/stub`, by `reviewer`, `stub` asked to review).
    private static func pullRequest(_ id: Int) -> String {
        let fork = id == 2
        let title = fork ? "Fix typo" : "Add feature"
        let body = fork ? "Fixes a typo in the readme." : "Adds the feature branch's work."
        let head = String((fork ? forkSHA : GitHubStub.headSHA).prefix(12))
        let source = fork ? repository("r-0002", "reviewer/stub") : repository("r-0001", "stub/stub")
        let participants = fork ? "" : """
            {"type": "participant", "user": \(reviewer), "role": "REVIEWER", "approved": true, "state": "approved",
             "participated_on": "2026-11-12T15:00:00.000000+00:00"}
            """
        return """
            {"type": "pullrequest", "id": \(id), "title": "\(title)", "state": "OPEN", "draft": false,
             "author": \(fork ? reviewer : user),
             "summary": {"raw": "\(body)", "markup": "markdown", "html": "<p>\(body)</p>"},
             "rendered": {"description": {"raw": "\(body)", "markup": "markdown", "html": "<p>\(body)</p>"}},
             "source": {"branch": {"name": "\(fork ? "typo" : "feature")"}, "commit": {"hash": "\(head)"},
                        "repository": \(source)},
             "destination": {"branch": {"name": "main", "merge_strategies": ["merge_commit", "squash", "fast_forward"]},
                             "commit": {"hash": "\(GitHubStub.baseSHA.prefix(12))"},
                             "repository": \(repository("r-0001", "stub/stub"))},
             "reviewers": [\(fork ? user : reviewer)], "participants": [\(participants)],
             "comment_count": \(fork ? 0 : 4), "created_on": "2026-11-1\(fork ? 3 : 0)T09:00:00.000000+00:00",
             "updated_on": "2026-11-1\(fork ? 3 : 2)T16:30:00.000000+00:00",
             "links": {"html": {"href": "https://bitbucket.org/stub/stub/pull-requests/\(id)"}}}
            """
    }

    /// A comment at `time` on 2026-11-12: global, inline (`inline`), a reply (`parent`), or a resolved thread's root.
    private static func comment(
        _ id: Int, by author: String, body: String, at time: String, parent: Int? = nil, inline: String? = nil,
        resolved: Bool = false
    ) -> String {
        let extra = (parent.map { #", "parent": {"id": \#($0)}"# } ?? "")
            + (inline.map { #", "inline": \#($0)"# } ?? "")
            + (resolved ? #", "resolution": {"user": \#(user), "created_on": "2026-11-12T16:10:00.000000+00:00"}"# : "")
        return """
            {"type": "pullrequest_comment", "id": \(id), "content": {"raw": "\(body)", "markup": "markdown",
             "html": "<p>\(body)</p>"}, "user": \(author), "deleted": false, "pending": false,
             "created_on": "2026-11-12T\(time):00.000000+00:00",
             "links": {"html": {"href": "https://bitbucket.org/stub/stub/pull-requests/1#comment-\(id)"}}\(extra)}
            """
    }

    private static func commit(_ sha: String, _ message: String, _ date: String, parent: String) -> String {
        """
        {"type": "commit", "hash": "\(sha)", "message": "\(message)", "date": "\(date)+00:00",
         "author": {"raw": "Stub User <stub@histq.invalid>", "user": \(user)}, "parents": [{"hash": "\(parent)"}],
         "links": {"html": {"href": "https://bitbucket.org/stub/stub/commits/\(sha)"}}}
        """
    }

    /// `feature.txt`'s diff, the same patch as `GitHubStub`'s `files`, as the git diff Bitbucket serves.
    private static let diff = """
        diff --git a/feature.txt b/feature.txt
        index 2222222..4444444 100644
        --- a/feature.txt
        +++ b/feature.txt
        @@ -1,5 +1,14 @@
         # Feature
        -TODO: write the feature
        -old line
        -another old line
        +The feature does three things:
        +
        +1. reads the input
        +2. checks it
        +3. writes the output
        +
        +Usage:
        +
        +    feature --input file
        +
        +See the docs for details.
        +Done.
         End.

        """
}

/// Answers every request of `GitHubStub.session` itself: never passes one on to the network.
final class GitHubStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    /// The delayed answer's timer (`-HistqGitHubStubDelay`), dropped when the request is cancelled.
    private var delayTimer: Timer?

    override func stopLoading() {
        delayTimer?.invalidate()
        delayTimer = nil
    }

    /// DEBUG `-HistqGitHubStubDelay "<ms>[,<path part>=<ms>…]"`: every stub answer comes `ms` late, or the ms of the
    /// first path part its URL's path contains; none: at once.
    private static let delays: (all: Int, parts: [(String, Int)]) = {
        var all = 0
        var parts: [(String, Int)] = []
        for item in (AppState.launchFlag("-HistqGitHubStubDelay") ?? "").split(separator: ",") {
            let pair = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, let ms = Int(pair[1]) { parts.append((pair[0], ms)) }
            else if let ms = Int(pair[0]) { all = ms }
        }
        return (all, parts)
    }()

    override func startLoading() {
        let reply = request.url.map { url in
            let method = request.httpMethod ?? "GET"
            let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
            return switch url.host() {
            case GitLabStub.repository.host: GitLabStub.reply(method: method, url: url, body: body)
            case BitbucketStub.apiHost: BitbucketStub.reply(method: method, url: url)
            default: GitHubStub.reply(method: method, url: url, body: body)
            }
        }
        guard let url = request.url, let reply,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let answer: @Sendable () -> Void = { [self] in
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        let delay = Self.delays.parts.first { url.path.contains($0.0) }?.1 ?? Self.delays.all
        guard delay > 0 else { return answer() }
        // On the loading thread's run loop, where URLSession expects the client calls.
        let timer = Timer(timeInterval: Double(delay) / 1000, repeats: false) { _ in answer() }
        delayTimer = timer
        RunLoop.current.add(timer, forMode: .common)
    }

    /// A request's body: URLSession hands it to the protocol as a stream.
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
#endif
