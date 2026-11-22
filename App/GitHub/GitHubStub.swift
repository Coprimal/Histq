#if DEBUG
// DEBUG `-HistqGitHubStub YES`: the PRs tab, the PR and issue details and the create form without GitHub. `HostingStore`
// then uses the repository `stub/stub` on github.com (the fixtures' origin is a local bare repo, which names no GitHub
// repo), a fake token, and a `URLSession` whose only protocol is `GitHubStubProtocol`: it answers every request from
// the JSON below (PR #1's merge, a 409 when it is not pinned to its head, review, comment, close/reopen and a reply to
// a review thread's root, an edit or delete of a seeded comment and a new inline comment (kept in memory for the
// next load), issue #2's
// comment and close/reopen, a create that always makes PR #3 with its reviewers,
// labels and assignees succeed, and on `/graphql` the review threads' states and resolve/unresolve, the comments'
// viewer states and `stub`'s reactions added or removed (kept in memory for the next load), by operation name) and
// 404 for anything else, so a stub run never reaches the network. The data: user
// `stub`, open pull request #1 "Add feature" (`feature` into `main`, 2 commits, 1 changed file, 1 review, 2 comments,
// 1 check run) by `stub` with two review threads on `feature.txt` in review 701 (A on lines 4-6 with `stub`'s reply,
// unresolved; B on line 10, resolved) between `reviewer`'s comment and `stub`'s, mergeable as `-HistqPRMergeable
// true|false|null` says (default true), open issue #2 assigned to `stub` with 2 comments (`reviewer`'s and `stub`'s),
// every comment with its node id, reactions (one by `stub`) and rights (`stub` may edit and delete only its own, each a
// leaf), the repository's labels, assignable users and collaborators (`stub`, `reviewer`), default branch
// `main`, and the Welcome clone picker's `/user/repos` (`stub`'s and `acme`'s). The JSON has GitHub's shapes (search
// results are issue-shaped), so the stub exercises the same decoding as the real API.
//
// DEBUG `-HistqHostingStubKind gitlab` (with `-HistqGitHubStub YES`): the PRs tab and the details talk to `GitLabStub`
// instead, the same data in GitLab's v4 shapes through `GitLabClient` (the repository `stub/stub` on gitlab.com), on
// the same session (`GitHubStubProtocol` answers gitlab.com from `GitLabStub`). `-HistqHostingStubKind bitbucket`
// does the same with `BitbucketStub` (Bitbucket's 2.0 shapes through `BitbucketCloudClient`, the repository `stub/stub`
// on bitbucket.org, answered on api.bitbucket.org). The Welcome clone picker stays GitHub's.
//
// DEBUG `-HistqStubFailWrites YES`: every stub answers each write and GraphQL mutation with a 500 (reads still answer),
// so a launch checks how an action's failure rolls back.
import Foundation
import HistqCore
import os

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
    /// DEBUG `-HistqStubFailWrites YES`: every host's stub answers each write and GraphQL mutation with a 500; reads,
    /// GraphQL queries included, still answer (`GitHubStubProtocol`), so a launch checks an action's rollback.
    static let failsWrites = AppState.launchFlag("-HistqStubFailWrites") == "YES"

    /// `text` as the inside of a JSON string literal (quotes, backslashes and control characters escaped), for a
    /// request's text going into the stubs' JSON.
    static func jsonText(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode(text), let quoted = String(data: data, encoding: .utf8),
              quoted.count >= 2 else { return "" }
        return String(quoted.dropFirst().dropLast())
    }

    /// Whether a request is a write: anything but a GET, except a GraphQL query (a read sent as a POST).
    static func isWrite(method: String, url: URL, body: Data?) -> Bool {
        guard method != "GET" else { return false }
        guard url.path().hasSuffix("/graphql") else { return true }
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let query = (json?["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return query.hasPrefix("mutation")
    }

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
        case ("POST", "\(repo)/pulls/1/comments"): return newReviewComment(body)
        // GitHub refuses a reply to a reply or to an unknown comment: only the two roots take one.
        case let ("POST", path) where path.hasPrefix("\(repo)/pulls/1/comments/") && path.hasSuffix("/replies"):
            let root = Int(path.split(separator: "/").dropLast().last ?? "")
            guard let root, [811, 813].contains(root) else { return notFound }
            return (201, reviewComment(814, review: 703, root: root, body: "Thanks, done.", at: "17:00"))
        case let (method, path) where ["PATCH", "DELETE"].contains(method)
            && (path.hasPrefix("\(repo)/issues/comments/") || path.hasPrefix("\(repo)/pulls/comments/")):
            return write(method, String(path.dropFirst(repo.count + 1)), body)
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
        case "\(repo)/issues/2/comments":
            return (200, "[" + written(issueSeed).map { conversationComment($0, on: 2) }.joined(separator: ", ") + "]")
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

    /// What this run wrote to the seeded comments: their new bodies (raw markdown) and the deleted ones, by REST path
    /// after the repository (`issues/comments/<id>`, `pulls/comments/<id>`: the two id spaces apart), and whether
    /// `stub` has each reaction it added or removed, by node id and REST content. Each load reads it, so the next load
    /// after a write shows it.
    private struct Writes {
        var edits: [String: String] = [:]
        var deleted: Set<String> = []
        var reactions: [String: [String: Bool]] = [:]
        /// The new inline comments, in order (`newReviewComment`).
        var inline: [NewReviewComment] = []
    }

    private static let writes = OSAllocatedUnfairLock(initialState: Writes())

    /// A new inline comment on #1 as it was posted: where (`path`, `line`/`side`, `start_line`/`start_side`) and the
    /// text (raw markdown).
    private struct NewReviewComment {
        let id: Int
        let path: String
        let line: Int
        let side: String
        let startLine: Int?
        let startSide: String?
        let body: String
    }

    /// `POST /pulls/1/comments`: a new inline comment by `stub` on the head (`commit_id`), at the line and side it
    /// names (and the range's first line), kept for the next load and answered with it (201); one without a body, a
    /// path, a line or a side, on another commit or with the closing-down `position`, is GitHub's 422.
    private static func newReviewComment(_ body: Data?) -> (status: Int, body: String) {
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        guard let text = json["body"] as? String, !text.isEmpty, let path = json["path"] as? String,
              let line = json["line"] as? Int, let side = json["side"] as? String, ["LEFT", "RIGHT"].contains(side),
              json["commit_id"] as? String == headSHA, json["position"] == nil
        else { return (422, #"{"message": "Validation Failed"}"#) }
        let startLine = json["start_line"] as? Int, startSide = json["start_side"] as? String
        let comment = writes.withLock { writes in
            let comment = NewReviewComment(
                id: 830 + writes.inline.count, path: path, line: line, side: side, startLine: startLine,
                startSide: startSide, body: text)
            writes.inline.append(comment)
            return comment
        }
        return (201, writtenReviewComment(comment))
    }

    /// A new inline comment as GitHub lists it: by `stub`, in no review the stub lists (so it shows at its time), at
    /// 17:3n on 2026-11-12 (after every seed).
    private static func writtenReviewComment(_ comment: NewReviewComment) -> String {
        let startSide = comment.startSide ?? comment.side
        let start = comment.startLine.map {
            #""start_line": \#($0), "original_start_line": \#($0), "start_side": "\#(startSide)""#
        } ?? #""start_line": null, "original_start_line": null, "start_side": null"#
        let time = "17:" + String(format: "%02d", 30 + min(comment.id - 830, 29))
        return """
            {"id": \(comment.id), "node_id": "PRRC_stub\(comment.id)", "pull_request_review_id": null,
             "path": "\(jsonText(comment.path))", \(start), "line": \(comment.line), "original_line": \(comment.line),
             "side": "\(comment.side)", "commit_id": "\(headSHA)", "original_commit_id": "\(headSHA)",
             "user": \(user), "body": "\(jsonText(comment.body))",
             "body_html": "<p>\(jsonText(HostedHTML.escape(comment.body)))</p>",
             "html_url": "https://github.com/stub/stub/pull/1#discussion_r\(comment.id)",
             "created_at": "2026-11-12T\(time):00Z", "updated_at": "2026-11-12T\(time):00Z"}
            """
    }

    /// `PATCH` (`{body}`, answered with the comment's id) or `DELETE` (204) of a seeded conversation comment
    /// (`issues/comments/<id>`) or review comment (`pulls/comments/<id>`, 811 to 813), kept for the next load; a
    /// deleted or unknown one is 404, as on GitHub.
    private static func write(_ method: String, _ path: String, _ body: Data?) -> (status: Int, body: String) {
        let id = Int(path.split(separator: "/").last ?? "") ?? 0
        let known = path.hasPrefix("issues/") ? (pullSeed + issueSeed).contains { $0.id == id } : (811...813) ~= id
        guard known, !writes.withLock({ $0.deleted.contains(path) }) else { return notFound }
        if method == "DELETE" {
            writes.withLock { _ = $0.deleted.insert(path) }
            return (204, "")
        }
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        guard let text = json?["body"] as? String else { return (422, #"{"message": "Body is required"}"#) }
        writes.withLock { $0.edits[path] = text }
        return (200, #"{"id": \#(id)}"#)
    }

    /// `seeds` with this run's writes: deleted ones left out, edited ones with their new body.
    private static func written(_ seeds: [Seed]) -> [Seed] {
        let writes = writes.withLock { $0 }
        return seeds.compactMap { seed in
            let path = "issues/comments/\(seed.id)"
            guard !writes.deleted.contains(path) else { return nil }
            var seed = seed
            if let body = writes.edits[path] { seed.body = body }
            seed.reactions = reacted(seed.reactions, writes.reactions["IC_stub\(seed.id)"] ?? [:])
            return seed
        }
    }

    /// `reactions` (REST content, count, whether `stub` gave one) with `stub`'s written ones (`Writes.reactions` of
    /// one node): one added counts it once more, one removed once less; a kind left at 0 goes.
    private static func reacted(
        _ reactions: [(kind: String, count: Int, mine: Bool)], _ written: [String: Bool]
    ) -> [(kind: String, count: Int, mine: Bool)] {
        var reactions = reactions
        for (kind, mine) in written.sorted(by: { $0.key < $1.key }) {
            if let index = reactions.firstIndex(where: { $0.kind == kind }) {
                guard reactions[index].mine != mine else { continue }
                reactions[index].count += mine ? 1 : -1
                reactions[index].mine = mine
            } else if mine {
                reactions.append((kind, 1, true))
            }
        }
        return reactions.filter { $0.count > 0 }
    }

    /// The REST base of the stub's comments, for their `reactions` rollup's `url`.
    private static let reactionsBase = "https://api.github.com/repos/stub/stub"

    /// GitHub's `reactions` rollup of a comment at `url`: counts only (who reacted is in the GraphQL answer).
    private static func rollup(_ url: String, _ reactions: [(kind: String, count: Int, mine: Bool)]) -> String {
        let counts = reactionNames.map { rest, _ in
            "\"\(rest)\": \(reactions.first { $0.kind == rest }?.count ?? 0)"
        }.joined(separator: ", ")
        return #"{"url": "\#(url)/reactions", "total_count": \#(reactions.reduce(0) { $0 + $1.count }), \#(counts)}"#
    }

    /// GraphQL `addReaction` or `removeReaction` (`added`) of `stub`'s on a seeded comment (its node id), kept for
    /// the next load; an unknown node or content gets 200 with `errors`, as on GitHub.
    private static func setReaction(_ variables: [String: Any]?, added: Bool) -> (status: Int, body: String) {
        let subject = variables?["subjectId"] as? String ?? ""
        let content = variables?["content"] as? String
        guard viewerState(of: subject) != nil, let rest = reactionNames.first(where: { $0.1 == content })?.0 else {
            return (200, #"{"data": null, "errors": [{"type": "NOT_FOUND", "#
                + #""message": "Could not resolve to a node."}]}"#)
        }
        writes.withLock { $0.reactions[subject, default: [:]][rest] = added }
        let field = added ? "addReaction" : "removeReaction"
        return (200, #"{"data": {"\#(field)": {"reaction": {"content": "\#(content ?? "")"}}}}"#)
    }

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

    /// `stub`'s comment on issue #2, also what a comment posted there answers.
    private static let issueComment = conversationComment(issueSeed[1], on: 2)

    /// PR #1 as the issues API and search return it: issue-shaped, with `pull_request` and `draft`.
    private static let pullAsIssue = """
        {"id": 501, "number": 1, "title": "Add feature", "state": "open", "draft": false,
         "html_url": "https://github.com/stub/stub/pull/1", "user": \(user), "comments": 2,
         "body": "Adds the feature branch's work.", "labels": [{"name": "enhancement", "color": "a2eeef"}],
         "assignees": [\(user)], "created_at": "2026-11-10T09:00:00Z", "updated_at": "2026-11-12T16:30:00Z",
         "pull_request": {"url": "https://api.github.com/repos/stub/stub/pulls/1"}}
        """

    private static let issue = """
        {"id": 602, "number": 2, "title": "Crash when opening an empty repository", "state": "open",
         "html_url": "https://github.com/stub/stub/issues/2", "user": \(reviewer), "comments": 2,
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

    /// `reviewer`'s comment on PR #1, also what a comment posted there answers.
    private static let comment = conversationComment(pullSeed[0], on: 1)

    /// A seeded conversation comment: `stub`'s when `own` (`stub` may edit and delete it), else `reviewer`'s, at
    /// `time` on 2026-11-12; `reactions`: REST content, count, and whether `stub` gave one of them.
    private struct Seed {
        let id: Int
        let own: Bool
        var body: String
        let time: String
        var reactions: [(kind: String, count: Int, mine: Bool)] = []
    }

    /// PR #1's conversation comments: `reviewer`'s 801 before review 701's threads (a +1 by `stub`) and `stub`'s 805
    /// after them, so the threads sit between two comments by time.
    private static let pullSeed = [
        Seed(id: 801, own: false, body: "Nice work.", time: "14:00",
             reactions: [("+1", 2, true), ("rocket", 1, false)]),
        Seed(id: 805, own: true, body: "Rebased on main; the usage is in the readme too.", time: "15:30",
             reactions: [("heart", 1, false)]),
    ]

    /// Issue #2's comments: `reviewer`'s 820 (a +1 by `stub`), then `stub`'s 802.
    private static let issueSeed = [
        Seed(id: 820, own: false, body: "It also happens on a fresh clone.", time: "10:00",
             reactions: [("+1", 1, true)]),
        Seed(id: 802, own: true, body: "I can reproduce it on 0.1.", time: "11:00"),
    ]

    /// GitHub's reactions, in its picker's order: REST `content` and GraphQL `ReactionContent`.
    private static let reactionNames = [
        ("+1", "THUMBS_UP"), ("-1", "THUMBS_DOWN"), ("laugh", "LAUGH"), ("hooray", "HOORAY"),
        ("confused", "CONFUSED"), ("heart", "HEART"), ("rocket", "ROCKET"), ("eyes", "EYES"),
    ]

    /// A seeded comment as `issues/<number>/comments` lists it, with its node id and GitHub's `reactions` rollup
    /// (counts only: who reacted is in the GraphQL answer). Its body goes in as JSON text (an edited one may have any
    /// character), its HTML escaped.
    private static func conversationComment(_ seed: Seed, on number: Int) -> String {
        let page = number == 1 ? "pull/1" : "issues/\(number)"
        return """
            {"id": \(seed.id), "node_id": "IC_stub\(seed.id)", "user": \(seed.own ? user : reviewer),
             "body": "\(jsonText(seed.body))", "body_html": "<p>\(jsonText(HostedHTML.escape(seed.body)))</p>",
             "html_url": "https://github.com/stub/stub/\(page)#issuecomment-\(seed.id)",
             "created_at": "2026-11-12T\(seed.time):00Z", "updated_at": "2026-11-12T\(seed.time):00Z",
             "reactions": \(rollup("\(reactionsBase)/issues/comments/\(seed.id)", seed.reactions))}
            """
    }

    /// PR #1's issue comments: `pullSeed`'s with this run's writes, or the generated ones of `-HistqPRStubComments`.
    private static var pullComments: String {
        generatedComments ?? written(pullSeed).map { conversationComment($0, on: 1) }.joined(separator: ", ")
    }

    /// DEBUG `-HistqPRStubComments <n>` (up to 600): PR #1's issue comments are n generated ones instead of
    /// `pullSeed`'s, a minute apart from 12:00, for a conversation longer than the panel. Every third has a long line
    /// of code, which a fit page must wrap. Each has a node id: `stub`'s (every second) are its to edit and delete
    /// (the stub keeps no write to them).
    private static let generatedComments: String? = {
        guard let count = AppState.launchFlag("-HistqPRStubComments").flatMap(Int.init), count >= 0 else {
            return nil
        }
        return (0..<min(count, 600)).map { index in
            let id = 10_000 + index
            let text = "Comment \(index + 1) of a long conversation."
            let line = "let total = items.map { $0.price * $0.count }.reduce(0, +); "
            let code = index % 3 != 2 ? "" : "<pre><code>\(String(repeating: line, count: 4))</code></pre>"
            let date = String(format: "2026-11-12T%02d:%02d:00Z", 12 + index / 60, index % 60)
            return """
                {"id": \(id), "node_id": "IC_stub\(id)", "user": \(index.isMultiple(of: 2) ? reviewer : user),
                 "body": "\(text)",
                 "body_html": "<p>\(text)</p>\(code)",
                 "html_url": "https://github.com/stub/stub/pull/1#issuecomment-\(id)",
                 "created_at": "\(date)", "updated_at": "\(date)"}
                """
        }.joined(separator: ", ")
    }()

    /// PR #1's inline review comments on `feature.txt`, as GitHub lists them: thread A (root 811 on lines 4-6,
    /// unresolved) with `stub`'s reply 812, which GitHub files in a review of its own (`replyReview`, 702), and
    /// thread B (root 813 on line 10, resolved), both roots in review 701; with this run's edits and deletions, then
    /// its new inline comments.
    private static var reviewComments: String {
        let writes = writes.withLock { $0 }
        let seeds: [(id: Int, review: Int, root: Int?, body: String, time: String)] = [
            (811, 701, nil, "Could the three steps be one sentence?", "14:55"),
            (812, 702, 811, "I kept the list: it reads better.", "16:00"),
            (813, 701, nil, "Show the output flag in the usage too.", "14:57"),
        ]
        return "[" + (seeds.compactMap { seed in
            let path = "pulls/comments/\(seed.id)"
            guard !writes.deleted.contains(path) else { return nil }
            return reviewComment(seed.id, review: seed.review, root: seed.root, body: writes.edits[path] ?? seed.body,
                                 at: seed.time)
        } + writes.inline.map(writtenReviewComment)).joined(separator: ", ") + "]"
    }

    /// A comment of thread A (root 811: lines 4-6, the numbered list) or B (root 813: line 10, the usage line), by
    /// `reviewer` for a root and `stub` for a reply (`ownReviewComments`). Its `diff_hunk` is GitHub's: the file
    /// patch's hunk header, then its rows down to the commented line; a reply repeats its root's lines and hunk. Its
    /// reactions are the ones `stub` gave it in this run (none seeded).
    private static func reviewComment(_ id: Int, review: Int, root: Int?, body: String, at time: String) -> String {
        let reactions = reacted([], writes.withLock { $0.reactions["PRRC_stub\(id)"] } ?? [:])
        let onList = (root ?? id) == 811
        let lines = onList
            ? #""start_line": 4, "original_start_line": 4, "start_side": "RIGHT", "line": 6, "original_line": 6"#
            : #""start_line": null, "original_start_line": null, "start_side": null, "line": 10, "original_line": 10"#
        let hunk = onList ? listHunk : listHunk + #"\n+\n+Usage:\n+\n+    feature --input file"#
        let reply = root.map { #" "in_reply_to_id": \#($0),"# } ?? ""
        return """
            {"id": \(id), "node_id": "PRRC_stub\(id)", "pull_request_review_id": \(review),\(reply)
             "path": "feature.txt", \(lines),
             "side": "RIGHT", "diff_hunk": "\(hunk)", "commit_id": "\(headSHA)", "original_commit_id": "\(headSHA)",
             "user": \(root == nil ? reviewer : user), "body": "\(jsonText(body))",
             "body_html": "<p>\(jsonText(HostedHTML.escape(body)))</p>",
             "html_url": "https://github.com/stub/stub/pull/1#discussion_r\(id)",
             "created_at": "2026-11-12T\(time):00Z", "updated_at": "2026-11-12T\(time):00Z",
             "reactions": \(rollup("\(reactionsBase)/pulls/comments/\(id)", reactions))}
            """
    }

    /// `feature.txt`'s hunk in `files` down to new line 6, the end of the numbered list.
    private static let listHunk = #"@@ -1,5 +1,14 @@\n # Feature\n-TODO: write the feature\n-old line"#
        + #"\n-another old line\n+The feature does three things:\n+\n+1. reads the input\n+2. checks it"#
        + #"\n+3. writes the output"#

    /// The GraphQL node ids of threads A and B.
    private static let threadA = "PRRT_stub811", threadB = "PRRT_stub813"

    /// The review comments `stub` wrote: its reply 812 in thread A and the reply 814 a reply posts.
    private static let ownReviewComments: Set<Int> = [812, 814]

    /// GitHub's GraphQL API, matched by the operation's name in the query: `ReviewThreadStates` (the two threads'
    /// states, joined on their roots' ids, so another PR's empty comments join none), `CommentViewerStates` (the
    /// asked comments' rights and `stub`'s reactions), `stub`'s reaction added or removed (`setReaction`) and a
    /// resolve or unresolve of thread A or B, which succeeds without changing anything. Like GitHub, an unknown
    /// operation or thread gets 200 with `errors`.
    private static func graphQL(_ body: Data?) -> (status: Int, body: String) {
        let request = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let query = request?["query"] as? String ?? ""
        if query.contains("CommentViewerStates") {
            return commentViewerStates((request?["variables"] as? [String: Any])?["ids"] as? [String] ?? [])
        }
        // Neither name contains the other.
        if query.contains("AddReaction") || query.contains("RemoveReaction") {
            return setReaction(request?["variables"] as? [String: Any], added: query.contains("AddReaction"))
        }
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

    /// `CommentViewerStates`: the asked node ids' comments as `nodes(ids:)` answers them, in the order asked, each
    /// with its database id as github.com gives it (`fullDatabaseId`, a string), `stub`'s rights (edit and delete its
    /// own only) and the 8 reaction groups with the ones it gave marked. An unknown id is null with a `NOT_FOUND`
    /// error, as GitHub answers a comment deleted since the REST read.
    private static func commentViewerStates(_ ids: [String]) -> (status: Int, body: String) {
        let nodes = ids.map { nodeID -> String in
            guard let state = viewerState(of: nodeID) else { return "null" }
            let groups = reactionNames.map { rest, graphQL in
                #"{"content": "\#(graphQL)", "viewerHasReacted": \#(state.mine.contains(rest))}"#
            }.joined(separator: ", ")
            return """
                {"__typename": "\(state.typename)", "fullDatabaseId": "\(state.id)", "viewerCanUpdate": \(state.own),
                 "viewerCanDelete": \(state.own), "reactionGroups": [\(groups)]}
                """
        }.joined(separator: ", ")
        let errors = ids.filter { viewerState(of: $0) == nil }.map {
            #"{"type": "NOT_FOUND", "path": ["nodes"], "#
                + #""message": "Could not resolve to a node with the global id of '\#($0)'."}"#
        }
        let tail = errors.isEmpty ? "" : #", "errors": [\#(errors.joined(separator: ", "))]"#
        return (200, #"{"data": {"nodes": [\#(nodes)]}\#(tail)}"#)
    }

    /// A node id's comment: a conversation comment (`IC_stub<id>`: `pullSeed`, `issueSeed`, or a generated one of
    /// `-HistqPRStubComments`, `stub`'s at an odd index) or a review comment (`PRRC_stub<id>`: 811 to 814); whether
    /// `stub` wrote it, and the REST names of the reactions it gave.
    private static func viewerState(of nodeID: String) -> (typename: String, id: Int, own: Bool, mine: [String])? {
        if nodeID.hasPrefix("IC_stub"), let id = Int(nodeID.dropFirst("IC_stub".count)) {
            if id >= 10_000 { return ("IssueComment", id, !(id - 10_000).isMultiple(of: 2), []) }
            guard let seed = (pullSeed + issueSeed).first(where: { $0.id == id }) else { return nil }
            let written = writes.withLock { $0.reactions[nodeID] } ?? [:]
            return ("IssueComment", id, seed.own, reacted(seed.reactions, written).filter(\.mine).map(\.kind))
        }
        if nodeID.hasPrefix("PRRC_stub"), let id = Int(nodeID.dropFirst("PRRC_stub".count)), (811...814).contains(id) {
            let written = writes.withLock { $0.reactions[nodeID] } ?? [:]
            return ("PullRequestReviewComment", id, ownReviewComments.contains(id),
                    reacted([], written).filter(\.mine).map(\.kind))
        }
        return nil
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
/// open merge request !1 "Add feature" (`feature` into `main` of the same project, 2 commits, 1 changed file, approved
/// by `reviewer`, a head pipeline and 1 commit status) with `reviewer`'s general thread and `stub`'s reply (resolvable,
/// open), two diff discussions on `feature.txt` (A on lines 4-6 with `stub`'s reply, unresolved; B on line 10,
/// resolved), then `stub`'s comment and a system note, its `detailed_merge_status` as `-HistqPRMergeable
/// true|false|null` says (`mergeable`, `conflict`, `checking`), open issue #2 assigned to `stub` with `reviewer`'s
/// thread and `stub`'s reply, then `stub`'s note, the project's labels and users. The GraphQL `NoteStates` read gives
/// each note's rights (`stub` may edit and delete only its own) and awards (one by `stub`). A reply to a general
/// thread or comment (!1's and issue #2's) and a resolve of a general thread (REST on !1, GraphQL
/// `discussionToggleResolve` on issue #2) are kept in memory (`writes`), so the next load shows them. The other
/// writes answer as GitLab does and change nothing: a note, a reply to A or B, resolve/unresolve of A or B, approve,
/// unapprove, a change request (GraphQL), a merge (409 unless pinned to the head), close/reopen, and a create that
/// always makes !3. Anything else is 404.
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
            if (json["query"] as? String)?.contains("NoteStates") == true { return noteStates(json) }
            if (json["query"] as? String)?.contains("discussionToggleResolve") == true { return toggleResolve(json) }
            // Neither name contains the other.
            if let query = json["query"] as? String,
               query.contains("awardEmojiAdd") || query.contains("awardEmojiRemove") {
                return setAward(json, added: query.contains("awardEmojiAdd"))
            }
            guard (json["query"] as? String)?.contains("mergeRequestRequestChanges") == true else { return notFound }
            return (200, #"{"data": {"mergeRequestRequestChanges": {"errors": [], "mergeRequest": {"iid": "1"}}}}"#)
        case ("POST", "\(mr1)/notes"): return (201, note(803, by: user, body: "Thanks.", at: "17:00"))
        case ("POST", "\(mr1)/discussions"): return newDiffDiscussion(json)
        case ("PUT", mr1): return (200, mergeRequest(1, full: true))
        case ("POST", "\(project)/issues/2/notes"): return (201, note(804, by: user, body: "Thanks.", at: "17:00"))
        case ("PUT", "\(project)/issues/2"): return (200, issue)
        // A create always makes !3, whatever the form sent; its follow-ups (reviewers, labels, assignees) succeed.
        case ("POST", "\(project)/merge_requests"): return (201, mergeRequest(3, full: true))
        case ("PUT", mr3): return (200, mergeRequest(3, full: true))
        case let ("POST", path) where path.hasPrefix("\(mr1)/discussions/") && path.hasSuffix("/notes"):
            let id = path.split(separator: "/").dropLast().last.map(String.init)
            if let id, mrGeneral.contains(id) { return replyToGeneral(id, json) }
            guard let id, [threadA, threadB].contains(id) else { return notFound }
            return (201, diffNote(814, by: user, body: "Thanks, done.", onList: id == threadA, resolved: id == threadB,
                                  at: "17:00"))
        case let ("POST", path) where path.hasPrefix("\(project)/issues/2/discussions/") && path.hasSuffix("/notes"):
            let id = path.split(separator: "/").dropLast().last.map(String.init)
            guard let id, issueGeneral.contains(id) else { return notFound }
            return replyToGeneral(id, json)
        case let (method, path) where ["PUT", "DELETE"].contains(method)
            && (path.hasPrefix("\(mr1)/notes/") || path.hasPrefix("\(project)/issues/2/notes/")):
            let discussions = path.hasPrefix(mr1) ? mrDiscussions : issueDiscussions
            return editOrDelete(method, Int(path.split(separator: "/").last ?? "") ?? 0, json, in: discussions)
        case let ("PUT", path) where path.hasPrefix("\(mr1)/discussions/"):
            let id = String(path.dropFirst("\(mr1)/discussions/".count))
            if id == generalThread {
                writes.withLock { $0.resolved[id] = query.contains("resolved=true") }
                return (200, mrDiscussions[0].json)
            }
            guard [threadA, threadB].contains(id) else { return notFound }
            return (200, discussion(id, resolved: query.contains("resolved=true")).json)
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
        case "\(mr1)/discussions": return (200, "[" + mrDiscussions.map(\.json).joined(separator: ", ") + "]")
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
        case "\(project)/issues/2/discussions":
            return (200, "[" + issueDiscussions.map(\.json).joined(separator: ", ") + "]")
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
             "user_notes_count": \(created ? 0 : 6)\(pipeline)}
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
         "user_notes_count": 3, "created_at": "2026-11-11T08:00:00Z", "updated_at": "2026-11-12T10:00:00Z"}
        """

    /// A plain note (a comment) at `time` on 2026-11-12, or a general thread's note (`DiscussionNote`, resolvable)
    /// when `resolved` is given. `body` goes in as JSON text (`GitHubStub.jsonText` for a written one).
    private static func note(_ id: Int, by author: String, body: String, at time: String, resolved: Bool? = nil)
        -> String
    {
        let kind = resolved.map { #""type": "DiscussionNote", "resolvable": true, "resolved": \#($0)"# }
            ?? #""type": null, "resolvable": false"#
        return """
            {"id": \(id), \(kind), "body": "\(body)", "author": \(author), "created_at": "2026-11-12T\(time):00Z",
             "system": false}
            """
    }

    /// A seeded note, its REST JSON with what GitLab's GraphQL adds: its global id's type (`Note`, `DiscussionNote`,
    /// `DiffNote`), whether `stub` may edit and delete it (`adminNote`: its own), whether it may be resolved
    /// (`resolveNote`), and its awards (emoji name and the awarding user's id).
    private struct SeedNote {
        let id: Int
        let json: String
        let type: String
        let admin: Bool
        let resolvable: Bool
        var awards: [(name: String, user: Int)] = []
    }

    /// A seeded discussion: its REST id (the last segment of its global id), whether it is a lone comment, and
    /// GraphQL's `resolved`.
    private struct SeedDiscussion {
        let id: String
        let individual: Bool
        let resolved: Bool
        let notes: [SeedNote]

        var json: String {
            let notes = notes.map(\.json).joined(separator: ", ")
            return #"{"id": "\#(id)", "individual_note": \#(individual), "notes": [\#(notes)]}"#
        }
    }

    /// A general note: `stub`'s when `own`, else `reviewer`'s, in a resolvable thread (open unless `resolved`) when
    /// `threaded`, else a lone comment.
    private static func generalNote(
        _ id: Int, own: Bool, body: String, at time: String, threaded: Bool, resolved: Bool = false,
        awards: [(name: String, user: Int)] = []
    ) -> SeedNote {
        let json = note(id, by: own ? user : reviewer, body: body, at: time, resolved: threaded ? resolved : nil)
        return SeedNote(id: id, json: json, type: threaded ? "DiscussionNote" : "Note", admin: own,
                        resolvable: threaded, awards: awards)
    }

    /// The ids of !1's and issue #2's general threads, and of their lone general comments (805, 802).
    private static let generalThread = "c801c801c801c801c801c801c801c801c801c801"
    private static let issueThread = "c820c820c820c820c820c820c820c820c820c820"
    private static let mrComment = "0000000000000000000000000000000000000805"
    private static let issueComment = "0000000000000000000000000000000000000802"
    /// The general discussions a reply may go to, !1's and issue #2's.
    private static let mrGeneral: Set = [generalThread, mrComment]
    private static let issueGeneral: Set = [issueThread, issueComment]

    /// What this run wrote to the general discussions, by discussion id: the replies (id and body as JSON text) and
    /// the threads resolved or reopened. Each load reads it, so the next load after a write shows it.
    private struct Writes {
        var nextID = 900
        var replies: [String: [(id: Int, body: String)]] = [:]
        var resolved: [String: Bool] = [:]
        /// The notes edited (their new raw body) and deleted, by note id, on !1 and issue #2.
        var edits: [Int: String] = [:]
        var deleted: Set<Int> = []
        /// Whether `stub` (user 1001) has each award it added or removed, by note id and emoji name.
        var awards: [Int: [String: Bool]] = [:]
        /// The new diff discussions on !1, in order (`newDiffDiscussion`).
        var diffDiscussions: [SeedDiscussion] = []
    }

    /// `POST .../merge_requests/1/discussions` with a `position`: a new diff thread by `stub` on the head, kept for
    /// the next load and answered with it (201). Its position is GitLab's as sent (`position_type` text, the three
    /// shas of `diff_refs`, `old_path`/`new_path`, the line numbers, `line_range`); one without a body, or whose shas
    /// or paths are not !1's diff, is GitLab's 400.
    private static func newDiffDiscussion(_ json: [String: Any]) -> (status: Int, body: String) {
        guard let body = json["body"] as? String, !body.isEmpty, let position = json["position"] as? [String: Any],
              position["position_type"] as? String == "text", position["base_sha"] as? String == GitHubStub.baseSHA,
              position["start_sha"] as? String == GitHubStub.baseSHA,
              position["head_sha"] as? String == GitHubStub.headSHA, position["old_path"] is String,
              position["new_path"] is String, position["old_line"] is Int || position["new_line"] is Int,
              let positionData = try? JSONSerialization.data(withJSONObject: position, options: [.sortedKeys])
        else { return (400, #"{"message": "400 Bad request - position is invalid"}"#) }
        let discussion = writes.withLock { writes in
            writes.nextID += 1
            let id = writes.nextID
            let note = """
                {"id": \(id), "type": "DiffNote", "body": "\(GitHubStub.jsonText(body))", "author": \(user),
                 "created_at": "2026-11-12T\(replyTime(id)):00Z", "system": false, "resolvable": true,
                 "resolved": false, "position": \(String(decoding: positionData, as: UTF8.self))}
                """
            let discussion = SeedDiscussion(
                id: "d" + String(format: "%039d", id), individual: false, resolved: false,
                notes: [SeedNote(id: id, json: note, type: "DiffNote", admin: true, resolvable: true)])
            writes.diffDiscussions.append(discussion)
            return discussion
        }
        return (201, discussion.json)
    }

    private static let writes = OSAllocatedUnfairLock(uncheckedState: Writes())

    /// `PUT .../notes/<id>` (`{body}`, answered with the note) or `DELETE` (204) of a note of `discussions` (seeded
    /// or written, not a system note), kept for the next load; another one is 404.
    private static func editOrDelete(
        _ method: String, _ id: Int, _ json: [String: Any], in discussions: [SeedDiscussion]
    ) -> (status: Int, body: String) {
        guard id != 850, discussions.contains(where: { $0.notes.contains { $0.id == id } }) else { return notFound }
        if method == "DELETE" {
            writes.withLock { _ = $0.deleted.insert(id) }
            return (204, "")
        }
        guard let body = json["body"] as? String else { return (400, #"{"message": "body is missing"}"#) }
        writes.withLock { $0.edits[id] = body }
        let note = discussions.lazy.flatMap(\.notes).first { $0.id == id }
        return (200, note.map { edited($0.json, body: body) } ?? #"{"id": \#(id)}"#)
    }

    /// A note's JSON with `body` as its body (any text: the JSON is written again).
    private static func edited(_ json: String, body: String) -> String {
        guard var note = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            return json
        }
        note["body"] = body
        guard let data = try? JSONSerialization.data(withJSONObject: note) else { return json }
        return String(decoding: data, as: UTF8.self)
    }

    /// `discussion` with this run's edits and deletions: nil once its last note is deleted, as GitLab drops it.
    private static func withEdits(_ discussion: SeedDiscussion) -> SeedDiscussion? {
        let (edits, deleted) = writes.withLock { ($0.edits, $0.deleted) }
        let notes = discussion.notes.filter { !deleted.contains($0.id) }.map { note in
            edits[note.id].map { body in
                SeedNote(id: note.id, json: edited(note.json, body: body), type: note.type, admin: note.admin,
                         resolvable: note.resolvable, awards: note.awards)
            } ?? note
        }
        guard !notes.isEmpty else { return nil }
        return SeedDiscussion(id: discussion.id, individual: discussion.individual, resolved: discussion.resolved,
                              notes: notes)
    }

    /// A reply by `stub` to the general discussion `id`, kept for the next load; answered with its note.
    private static func replyToGeneral(_ id: String, _ json: [String: Any]) -> (status: Int, body: String) {
        let body = GitHubStub.jsonText(json["body"] as? String ?? "")
        let noteID = writes.withLock { writes in
            writes.nextID += 1
            writes.replies[id, default: []].append((writes.nextID, body))
            return writes.nextID
        }
        let threaded = id == generalThread || id == issueThread
        let resolved = writes.withLock { $0.resolved[id] } ?? false
        return (201, generalNote(noteID, own: true, body: body, at: replyTime(noteID), threaded: threaded,
                                 resolved: resolved).json)
    }

    /// A written reply's time on 2026-11-12: after every seeded note, in the order they were written.
    private static func replyTime(_ id: Int) -> String {
        "17:" + String(format: "%02d", min(id - 900, 59))
    }

    /// GraphQL `awardEmojiAdd` or `awardEmojiRemove` (`added`) of `stub`'s on a note of !1 or issue #2 (by its global
    /// id, whose last segment is the note id), kept for the next load; another note gets the payload's `errors`.
    private static func setAward(_ json: [String: Any], added: Bool) -> (status: Int, body: String) {
        let variables = json["variables"] as? [String: Any] ?? [:]
        let field = added ? "awardEmojiAdd" : "awardEmojiRemove"
        let id = (variables["awardableId"] as? String)?.split(separator: "/").last.flatMap { Int($0) }
        let known = (mrDiscussions + issueDiscussions).contains { $0.notes.contains { $0.id == id } }
        guard let id, known, let name = variables["name"] as? String, !name.isEmpty else {
            return (200, #"{"data": {"\#(field)": {"errors": ["Not found"]}}}"#)
        }
        writes.withLock { $0.awards[id, default: [:]][name] = added }
        return (200, #"{"data": {"\#(field)": {"errors": []}}}"#)
    }

    /// `note`'s awards with `stub`'s written ones (`Writes.awards`): one added once, one removed gone.
    private static func awarded(_ note: SeedNote) -> [(name: String, user: Int)] {
        var awards = note.awards
        for (name, added) in (writes.withLock { $0.awards[note.id] } ?? [:]).sorted(by: { $0.key < $1.key }) {
            let mine = awards.contains { $0 == (name, 1001) }
            if added, !mine { awards.append((name, 1001)) }
            if !added { awards.removeAll { $0 == (name, 1001) } }
        }
        return awards
    }

    /// GraphQL `discussionToggleResolve` on issue #2's thread (by its global id), kept for the next load.
    private static func toggleResolve(_ json: [String: Any]) -> (status: Int, body: String) {
        let variables = json["variables"] as? [String: Any] ?? [:]
        guard variables["id"] as? String == "gid://gitlab/Discussion/\(issueThread)",
              let resolve = variables["resolve"] as? Bool
        else { return (200, #"{"data": {"discussionToggleResolve": null}, "errors": [{"message": "Not found"}]}"#) }
        writes.withLock { $0.resolved[issueThread] = resolve }
        return (200, #"{"data": {"discussionToggleResolve": {"errors": [], "discussion": {"resolved": \#(resolve)}}}}"#)
    }

    /// `discussion` with the replies this run wrote to it, after its own notes.
    private static func withReplies(_ discussion: SeedDiscussion) -> SeedDiscussion {
        let replies = writes.withLock { $0.replies[discussion.id] } ?? []
        guard !replies.isEmpty else { return discussion }
        let threaded = discussion.id == generalThread || discussion.id == issueThread
        let notes = replies.map { reply in
            generalNote(reply.id, own: true, body: reply.body, at: replyTime(reply.id), threaded: threaded,
                        resolved: discussion.resolved)
        }
        return SeedDiscussion(id: discussion.id, individual: false, resolved: discussion.resolved,
                              notes: discussion.notes + notes)
    }

    /// !1's discussions in GitLab's order: `reviewer`'s thread 801 (a thumbsup by `stub` and one by `reviewer`) with
    /// `stub`'s reply 806, diff discussions A and B, `stub`'s comment 805 after them (a heart by `reviewer`), so the
    /// diff threads sit between two general comments by time, and the push's system note; with this run's writes (its
    /// new diff threads last).
    private static var mrDiscussions: [SeedDiscussion] {
        let resolved = writes.withLock { $0.resolved[generalThread] } ?? false
        return [SeedDiscussion]([
            withReplies(SeedDiscussion(id: generalThread, individual: false, resolved: resolved, notes: [
                generalNote(801, own: false, body: "Nice work.", at: "14:00", threaded: true, resolved: resolved,
                            awards: [("thumbsup", 1001), ("thumbsup", 1002)]),
                generalNote(806, own: true, body: "Thanks for the quick review.", at: "14:10", threaded: true,
                            resolved: resolved),
            ])),
            discussion(threadA, resolved: false), discussion(threadB, resolved: true),
            withReplies(SeedDiscussion(id: mrComment, individual: true, resolved: false, notes: [
                generalNote(805, own: true, body: "Rebased on main; the usage is in the readme too.", at: "15:30",
                            threaded: false, awards: [("heart", 1002)]),
            ])),
            SeedDiscussion(id: "0000000000000000000000000000000000000850", individual: true, resolved: false, notes: [
                SeedNote(id: 850, json: systemNote, type: "Note", admin: false, resolvable: false),
            ]),
        ] + writes.withLock { $0.diffDiscussions }).compactMap(withEdits)
    }

    /// Issue #2's discussions: `reviewer`'s thread 820 (a thumbsup by `stub`) with `stub`'s reply 821, then `stub`'s
    /// comment 802; with this run's writes.
    private static var issueDiscussions: [SeedDiscussion] {
        let resolved = writes.withLock { $0.resolved[issueThread] } ?? false
        return [SeedDiscussion]([
            withReplies(SeedDiscussion(id: issueThread, individual: false, resolved: resolved, notes: [
                generalNote(820, own: false, body: "It also happens on a fresh clone.", at: "10:00", threaded: true,
                            resolved: resolved, awards: [("thumbsup", 1001)]),
                generalNote(821, own: true, body: "Thanks, I am on it.", at: "10:30", threaded: true,
                            resolved: resolved),
            ])),
            withReplies(SeedDiscussion(id: issueComment, individual: true, resolved: false, notes: [
                generalNote(802, own: true, body: "I can reproduce it on 0.1.", at: "11:00", threaded: false),
            ])),
        ]).compactMap(withEdits)
    }

    /// `NoteStates`: !1's or issue #2's discussions (another item's are none) on one page, with what GraphQL adds to
    /// REST: global ids whose last segment is the REST id, each discussion's `resolved`, each note's rights and its
    /// awards with the user's global id (this run's by `stub` included).
    private static func noteStates(_ json: [String: Any]) -> (status: Int, body: String) {
        let isIssue = (json["query"] as? String)?.contains("issue(iid:") == true
        let iid = (json["variables"] as? [String: Any])?["iid"] as? String
        let discussions = isIssue ? (iid == "2" ? issueDiscussions : []) : (iid == "1" ? mrDiscussions : [])
        let nodes = discussions.map { discussion in
            let notes = discussion.notes.map { note in
                let awards = awarded(note).map { award in
                    #"{"name": "\#(award.name)", "user": {"id": "gid://gitlab/User/\#(award.user)"}}"#
                }
                return """
                    {"id": "gid://gitlab/\(note.type)/\(note.id)",
                     "userPermissions": {"adminNote": \(note.admin), "resolveNote": \(note.resolvable)},
                     "awardEmoji": {"nodes": [\(awards.joined(separator: ", "))]}}
                    """
            }.joined(separator: ", ")
            return #"{"id": "gid://gitlab/Discussion/\#(discussion.id)", "resolved": \#(discussion.resolved), "#
                + #""notes": {"nodes": [\#(notes)]}}"#
        }.joined(separator: ", ")
        return (200, #"{"data": {"project": {"\#(isIssue ? "issue" : "mergeRequest")": {"discussions": {"#
            + #""nodes": [\#(nodes)], "pageInfo": {"hasNextPage": false, "endCursor": null}}}}}}"#)
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
    private static func discussion(_ id: String, resolved: Bool) -> SeedDiscussion {
        func seed(_ id: Int, own: Bool, body: String, onList: Bool, at time: String) -> SeedNote {
            SeedNote(id: id, json: diffNote(id, by: own ? user : reviewer, body: body, onList: onList,
                                            resolved: resolved, at: time),
                     type: "DiffNote", admin: own, resolvable: true)
        }
        let notes = id == threadA
            ? [seed(811, own: false, body: "Could the three steps be one sentence?", onList: true, at: "14:55"),
               seed(812, own: true, body: "I kept the list: it reads better.", onList: true, at: "16:00")]
            : [seed(813, own: false, body: "Show the output flag in the usage too.", onList: false, at: "14:57")]
        return SeedDiscussion(id: id, individual: false, resolved: resolved, notes: notes)
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
/// file, approved by `reviewer`, 1 commit status) with `reviewer`'s comment, their reply and `stub`'s reply to that,
/// two inline threads on `feature.txt` (A on lines 4-6 with `stub`'s reply, unresolved; B on line 10, resolved), a
/// deleted comment with `reviewer`'s live reply, then `stub`'s comment (the author's uuid against `/2.0/user` makes
/// `stub`'s comments editable and deletable, each a leaf), and open pull request #2 "Fix typo" by `reviewer` from the
/// fork `reviewer/stub` with `stub` as its reviewer (Checkout Locally is unavailable for it). Heads are abbreviated to
/// 12 hex digits, as Bitbucket gives them. The only writes are on #1's comments: a general comment or a reply
/// (`parent`), a new inline comment (`inline`), a resolve or reopen of a top-level one, and an edit or delete of any
/// comment, kept in memory
/// (`writes`), so the next load shows them. Any other write, and anything else, is 404.
enum BitbucketStub {
    static let repository = HostedRepository(host: "bitbucket.org", owner: "stub", name: "stub")
    /// The host the client's requests go to.
    static let apiHost = "api.bitbucket.org"

    static func client() -> BitbucketCloudClient {
        BitbucketCloudClient(session: GitHubStub.session) { _ in GitHubStub.token }
    }

    /// The status and JSON (or, for a diff, text) body for a request of the stub session to api.bitbucket.org
    /// (`body`: the request's).
    static func reply(method: String, url: URL, body: Data?) -> (status: Int, body: String) {
        let repo = "/2.0/repositories/stub/stub", pr1 = "\(repo)/pullrequests/1", pr2 = "\(repo)/pullrequests/2"
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
        guard method == "GET" else { return write(method, url.path(percentEncoded: false), body, pr1: pr1) }
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
        case "\(pr1)/comments": return page(comments)
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

    /// #1's comments: a general thread two replies deep, the inline threads, a deleted comment kept for its reply, and
    /// `stub`'s comment after the threads, so they sit between general comments by time; then this run's comments,
    /// and its edits and deletions (a deleted comment stays in the list, `deleted: true`, as Bitbucket keeps it).
    private static var comments: [String] {
        let writes = writes.withLock { $0 }
        let resolved = writes.resolved
        let comments = [
            comment(801, by: reviewer, body: "Nice work.", at: "14:00", resolved: resolved.contains(801)),
            comment(806, by: reviewer, body: "One more thing: a test for an empty input?", at: "14:10",
                    parent: 801),
            comment(807, by: user, body: "Added one in the second commit.", at: "14:20", parent: 806),
            comment(811, by: reviewer, body: "Could the three steps be one sentence?", at: "14:55",
                    inline: #"{"path": "feature.txt", "from": null, "to": 6, "start_from": null, "start_to": 4}"#),
            comment(812, by: user, body: "I kept the list: it reads better.", at: "16:00", parent: 811,
                    inline: #"{"path": "feature.txt", "from": null, "to": 6}"#),
            comment(813, by: reviewer, body: "Show the output flag in the usage too.", at: "14:57",
                    inline: #"{"path": "feature.txt", "from": null, "to": 10}"#, resolved: true),
            comment(809, by: reviewer, body: "", at: "15:00", deleted: true),
            comment(810, by: reviewer, body: "The link I removed is in the docs now.", at: "15:05", parent: 809),
            comment(805, by: user, body: "Rebased on main; the usage is in the readme too.", at: "15:30",
                    resolved: resolved.contains(805)),
        ] + writes.comments
        guard !writes.edits.isEmpty || !writes.deleted.isEmpty else { return comments }
        return comments.map { json in
            guard var comment = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
                  let id = comment["id"] as? Int else { return json }
            if writes.deleted.contains(id) {
                comment["deleted"] = true
                comment["content"] = ["raw": "", "markup": "markdown", "html": ""]
            } else if let raw = writes.edits[id] {
                comment["content"] = ["raw": raw, "markup": "markdown", "html": "<p>\(HostedHTML.escape(raw))</p>"]
            } else {
                return json
            }
            guard let data = try? JSONSerialization.data(withJSONObject: comment) else { return json }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// What this run wrote on #1: its new general and inline comments (JSON, in order), the top-level ones it
    /// resolved, and the comments it edited (their new raw body) or deleted, by id.
    private struct Writes {
        var nextID = 900
        var comments: [String] = []
        var resolved: Set<Int> = []
        var edits: [Int: String] = [:]
        var deleted: Set<Int> = []
    }

    private static let writes = OSAllocatedUnfairLock(initialState: Writes())

    /// #1's comment writes: `POST .../comments` (a reply has `parent`, a new inline comment `inline`), answered with
    /// the comment by `stub`, and `POST`/`DELETE .../comments/<801|805>/resolve`; and on any of its comments not
    /// deleted, `PUT .../comments/<id>` (`content.raw`, answered with the comment) and `DELETE` (204). Anything else
    /// is 404.
    private static func write(_ method: String, _ path: String, _ body: Data?, pr1: String)
        -> (status: Int, body: String)
    {
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if ["PUT", "DELETE"].contains(method), path.hasPrefix("\(pr1)/comments/"),
           let id = Int(path.dropFirst("\(pr1)/comments/".count)) {
            return editOrDelete(method, id, json)
        }
        if method == "POST", path == "\(pr1)/comments", json["inline"] == nil,
           let raw = (json["content"] as? [String: Any])?["raw"] as? String {
            let parent = (json["parent"] as? [String: Any])?["id"] as? Int
            let created = writes.withLock { writes in
                writes.nextID += 1
                let time = "17:" + String(format: "%02d", min(writes.nextID - 900, 59))
                let created = comment(
                    writes.nextID, by: user, body: GitHubStub.jsonText(raw), at: time, parent: parent,
                    html: GitHubStub.jsonText("<p>\(HostedHTML.escape(raw))</p>"))
                writes.comments.append(created)
                return created
            }
            return (201, created)
        }
        // A new inline comment: `inline` as sent (`path`, `to` new side or `from` old side, `start_to`/`start_from`).
        if method == "POST", path == "\(pr1)/comments", let inline = json["inline"] as? [String: Any],
           let raw = (json["content"] as? [String: Any])?["raw"] as? String, !raw.isEmpty,
           (inline["path"] as? String)?.isEmpty == false, inline["to"] is Int || inline["from"] is Int,
           let inlineData = try? JSONSerialization.data(withJSONObject: inline, options: [.sortedKeys]) {
            let created = writes.withLock { writes in
                writes.nextID += 1
                let time = "17:" + String(format: "%02d", min(writes.nextID - 900, 59))
                let created = comment(
                    writes.nextID, by: user, body: GitHubStub.jsonText(raw), at: time,
                    inline: String(decoding: inlineData, as: UTF8.self),
                    html: GitHubStub.jsonText("<p>\(HostedHTML.escape(raw))</p>"))
                writes.comments.append(created)
                return created
            }
            return (201, created)
        }
        let roots: Set = [801, 805]
        let parts = path.split(separator: "/")
        guard path.hasPrefix("\(pr1)/comments/"), path.hasSuffix("/resolve"), parts.count >= 2,
              let id = Int(parts[parts.count - 2]), roots.contains(id) else { return notFound }
        switch method {
        case "POST":
            writes.withLock { _ = $0.resolved.insert(id) }
            return (200, #"{"type": "comment_resolution", "user": \#(user), "#
                + #""created_on": "2026-11-12T17:00:00.000000+00:00"}"#)
        case "DELETE":
            writes.withLock { _ = $0.resolved.remove(id) }
            return (204, "")
        default:
            return notFound
        }
    }

    /// `PUT` (`content.raw`) or `DELETE` of #1's comment `id`, kept for the next load; a deleted or unknown one is
    /// 404.
    private static func editOrDelete(_ method: String, _ id: Int, _ json: [String: Any]) -> (status: Int, body: String) {
        func object(_ comment: String) -> [String: Any]? {
            (try? JSONSerialization.jsonObject(with: Data(comment.utf8))) as? [String: Any]
        }
        guard comments.contains(where: { object($0)?["id"] as? Int == id && object($0)?["deleted"] as? Bool == false })
        else { return notFound }
        if method == "DELETE" {
            writes.withLock { _ = $0.deleted.insert(id) }
            return (204, "")
        }
        guard let raw = (json["content"] as? [String: Any])?["raw"] as? String else {
            return (400, #"{"type": "error", "error": {"message": "content.raw is missing"}}"#)
        }
        writes.withLock { $0.edits[id] = raw }
        return comments.first { object($0)?["id"] as? Int == id }.map { (200, $0) } ?? notFound
    }

    /// A list page without a `next`.
    private static func page(_ values: String...) -> (status: Int, body: String) {
        page(values)
    }

    private static func page(_ values: [String]) -> (status: Int, body: String) {
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
             "comment_count": \(fork ? 0 : 8), "created_on": "2026-11-1\(fork ? 3 : 0)T09:00:00.000000+00:00",
             "updated_on": "2026-11-1\(fork ? 3 : 2)T16:30:00.000000+00:00",
             "links": {"html": {"href": "https://bitbucket.org/stub/stub/pull-requests/\(id)"}}}
            """
    }

    /// A comment at `time` on 2026-11-12: global, inline (`inline`), a reply (`parent`), a resolved thread's root, or
    /// deleted (Bitbucket keeps it in the list, `deleted: true`). `body` (and `html`, else `<p>body</p>`) go in as
    /// JSON text (`GitHubStub.jsonText` for a written one).
    private static func comment(
        _ id: Int, by author: String, body: String, at time: String, parent: Int? = nil, inline: String? = nil,
        resolved: Bool = false, deleted: Bool = false, html: String? = nil
    ) -> String {
        let extra = (parent.map { #", "parent": {"id": \#($0)}"# } ?? "")
            + (inline.map { #", "inline": \#($0)"# } ?? "")
            + (resolved ? #", "resolution": {"user": \#(user), "created_on": "2026-11-12T16:10:00.000000+00:00"}"# : "")
        return """
            {"type": "pullrequest_comment", "id": \(id), "content": {"raw": "\(body)", "markup": "markdown",
             "html": "\(html ?? (body.isEmpty ? "" : "<p>\(body)</p>"))"}, "user": \(author), "deleted": \(deleted),
             "pending": false,
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
        let reply = request.url.map { url -> (status: Int, body: String) in
            let method = request.httpMethod ?? "GET"
            let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
            if GitHubStub.failsWrites, GitHubStub.isWrite(method: method, url: url, body: body) {
                return url.host() == BitbucketStub.apiHost
                    ? (500, #"{"type": "error", "error": {"message": "Stub write failure"}}"#)
                    : (500, #"{"message": "Stub write failure"}"#)
            }
            return switch url.host() {
            case GitLabStub.repository.host: GitLabStub.reply(method: method, url: url, body: body)
            case BitbucketStub.apiHost: BitbucketStub.reply(method: method, url: url, body: body)
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
