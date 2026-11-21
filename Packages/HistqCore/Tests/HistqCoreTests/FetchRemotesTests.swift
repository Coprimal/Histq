// Fetch All, Fetch <remote> and auto-fetch (`GitOperations.backgroundFetchAll`) run one `git fetch <remote>` per
// remote, each through the token gate on its own: a remote on an account's host gets that host's token, a remote on
// another host runs with the user's own helpers and no token, and one remote that fails does not stop the others. A
// remote named like a remote group (which `git fetch <remote>` would fetch instead) gets no token, and auto-fetch
// leaves it out; a group named like no remote changes nothing. Runs in `TokenSandbox` (fake https transport, no
// network, no Keychain). A token is never put in a failure message: checks compare first, then report a Bool.
import Foundation
import HistqCore
import Testing

struct FetchRemotesTests {
    static let otherHost = "other.histq.invalid"

    /// A repo whose `broken` remote (added first, so fetched first) is `source` on `otherHost`, which has no account,
    /// and whose `origin` is `source` on the profile's first account host.
    static func makeRepo(_ box: TokenSandbox) async throws -> (repo: URL, source: URL) {
        let source = try await box.sandbox.makeRepo("source")
        try await box.sandbox.git(["commit", "-q", "--allow-empty", "-m", "remote only"], in: source)
        let repo = try await box.sandbox.makeRepo("repo")
        try await box.sandbox.git(["remote", "add", "broken", box.url(source, host: otherHost)], in: repo)
        try await box.sandbox.git(["remote", "add", "origin", box.url(source)], in: repo)
        return (repo, source)
    }

    /// Whether the transport's last run on `host` had `HISTQ_GIT_TOKEN_0` set to `token`.
    static func carried(_ token: String, host: String, _ box: TokenSandbox) throws -> Bool {
        try box.transportEnvironment(host: host).split(separator: "\n").contains("HISTQ_GIT_TOKEN_0=\(token)")
    }

    @Test("Fetch All: a remote on a host without an account fails alone, the account host's remote still fetches with its token")
    func failingRemoteDoesNotStopTheOthers() async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let (repo, _) = try await Self.makeRepo(box)
        await #expect {
            try await box.operations(naive: false, in: repo).fetchAll()
        } throws: { error in
            guard let fetch = error as? RemoteFetchFailure, fetch.failures.map(\.remote) == ["broken"],
                  let withheld = fetch.failures.first?.error as? NetworkTokenWithheld, case .auth = withheld.error
            else { return false }
            return withheld.reason == .noAccount(host: Self.otherHost)
        }
        #expect(try await box.hasRef("refs/remotes/origin/main", in: repo), "origin was not fetched")
        #expect(!(try await box.hasRef("refs/remotes/broken/main", in: repo)))

        let tokenOnAccountHost = try Self.carried(NetworkTokenTests.token, host: NetworkTokenTests.host, box)
        #expect(tokenOnAccountHost, "origin's fetch did not carry its host's token")
        let firstEnv = try box.transportEnvironment(host: NetworkTokenTests.host)
        let secondLeaked = firstEnv.contains(NetworkTokenTests.secondToken)
        #expect(!secondLeaked, "origin's fetch carried the other account's token")
        let otherEnv = try box.transportEnvironment(host: Self.otherHost)
        let leaked = box.hasCredential(envDump: otherEnv)
        #expect(!leaked, "the remote on a host without an account got a token")
    }

    @Test("Fetch All: the remote on a host without an account signs in with the user's own helper, never a token")
    func otherHostUsesUserHelper() async throws {
        let box = try await TokenSandbox(userHelper: true)
        defer { box.remove() }
        let (repo, _) = try await Self.makeRepo(box)
        try await box.operations(naive: false, in: repo).fetchAll()
        #expect(try await box.hasRef("refs/remotes/origin/main", in: repo))
        #expect(try await box.hasRef("refs/remotes/broken/main", in: repo))

        #expect(box.transportGot(NetworkTokenTests.token, host: NetworkTokenTests.host), "origin did not get its token")
        #expect(box.transportGot("user-secret", host: Self.otherHost), "the user's helper did not answer")
        let leaked = box.hasCredential(envDump: try box.transportEnvironment(host: Self.otherHost))
        #expect(!leaked, "the remote on a host without an account got a token")
    }

    @Test("Fetch <remote> fetches that remote alone; its sign-in failure on a host without an account says so")
    func fetchOneRemote() async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let (repo, _) = try await Self.makeRepo(box)
        let ops = box.operations(naive: false, in: repo)
        try await ops.fetch(remote: "origin")
        #expect(try await box.hasRef("refs/remotes/origin/main", in: repo))
        #expect(box.transportGot(NetworkTokenTests.token, host: NetworkTokenTests.host))
        #expect(box.transportAnswer(host: Self.otherHost).isEmpty, "Fetch origin also reached the other remote")

        await #expect {
            try await ops.fetch(remote: "broken")
        } throws: { error in
            guard let withheld = error as? NetworkTokenWithheld else { return false }
            return withheld.reason == .noAccount(host: Self.otherHost)
        }
        await #expect(throws: GitOperationError.invalidRemoteName("-x")) { try await ops.fetch(remote: "-x") }
    }

    @Test("A sign-in failure on a host whose account has an unusable token does not say the host has no account")
    func unusableTokenIsStillAnAccount() async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let (repo, _) = try await box.makeRepoWithRemote()
        var unusable = NetworkTokenTests.credential
        unusable.token = "two words"
        let ops = GitOperations(
            runner: box.sandbox.runner, cwd: repo, profile: NetworkTokenTests.profile, base: box.base,
            credentials: [unusable])
        await #expect {
            try await ops.fetch(remote: "origin")
        } throws: { error in
            guard let gitError = error as? GitError, case .auth = gitError else { return false }
            return true
        }
    }

    @Test("Fetch <remote> takes any remote git lists, team/fork too, and no other name")
    func fetchExistingRemoteNames() async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let (repo, source) = try await box.makeRepoWithRemote()
        try await box.sandbox.git(["remote", "add", "team/fork", box.url(source)], in: repo)
        let ops = box.operations(naive: false, in: repo)
        try await ops.fetch(remote: "team/fork")
        #expect(try await box.hasRef("refs/remotes/team/fork/main", in: repo))
        #expect(box.transportGot(NetworkTokenTests.token, host: NetworkTokenTests.host))
        await #expect(throws: GitOperationError.invalidRemoteName("nosuch")) { try await ops.fetch(remote: "nosuch") }
        await #expect(throws: GitOperationError.invalidRemoteName(source.path)) {
            try await ops.fetch(remote: source.path)
        }
    }

    @Test("Fetch All shares one time limit: a remote reached after it fails with a timeout and never runs")
    func fetchAllSharesOneDeadline() async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let (repo, _) = try await Self.makeRepo(box)
        let ops = GitOperations(
            runner: box.sandbox.runner, cwd: repo, profile: NetworkTokenTests.profile, base: box.base,
            credentials: NetworkTokenTests.credentials, networkTimeout: .zero)
        await #expect {
            try await ops.fetchAll()
        } throws: { error in
            guard let fetch = error as? RemoteFetchFailure else { return false }
            return fetch.failures.map(\.remote) == ["broken", "origin"]
                && fetch.failures.allSatisfy { ($0.error as? GitError) == .timeout }
        }
        #expect(!box.transportRan, "a remote fetched after the shared time limit")
    }

    // MARK: - Auto-fetch

    /// `GitOperations.backgroundFetchAll` in `repo` with the profile's two accounts.
    static func backgroundFetch(_ box: TokenSandbox, in repo: URL) async throws {
        try await GitOperations.backgroundFetchAll(
            prune: true, profile: NetworkTokenTests.profile, base: box.base, runner: box.sandbox.runner, cwd: repo,
            credentials: NetworkTokenTests.credentials)
    }

    @Test("Auto-fetch: a remote on a host without an account fails alone, the account host's remote still fetches with its token")
    func backgroundFailingRemoteDoesNotStopTheOthers() async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let (repo, _) = try await Self.makeRepo(box)
        await #expect {
            try await Self.backgroundFetch(box, in: repo)
        } throws: { error in
            guard let fetch = error as? RemoteFetchFailure, fetch.failures.map(\.remote) == ["broken"],
                  let gitError = fetch.failures.first?.error as? GitError, case .auth = gitError
            else { return false }
            return true
        }
        #expect(try await box.hasRef("refs/remotes/origin/main", in: repo), "origin was not fetched")
        #expect(!(try await box.hasRef("refs/remotes/broken/main", in: repo)))

        let tokenOnAccountHost = try Self.carried(NetworkTokenTests.token, host: NetworkTokenTests.host, box)
        #expect(tokenOnAccountHost, "origin's fetch did not carry its host's token")
        let firstEnv = try box.transportEnvironment(host: NetworkTokenTests.host)
        let secondLeaked = firstEnv.contains(NetworkTokenTests.secondToken)
        #expect(!secondLeaked, "origin's fetch carried the other account's token")
        let otherEnv = try box.transportEnvironment(host: Self.otherHost)
        let leaked = box.hasCredential(envDump: otherEnv)
        #expect(!leaked, "the remote on a host without an account got a token")
    }

    // MARK: - Remote groups

    @Test("A remote named like a remote group gets no token from Fetch All or Fetch origin, and auto-fetch skips it alone")
    func remoteGroupGetsNoToken() async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let (repo, source) = try await box.makeRepoWithRemote()
        // Two members, so `git fetch origin` fetches them instead of origin (one member falls back to the remote).
        try await box.sandbox.git(
            ["config", "remotes.origin", "\(box.url(source, host: Self.otherHost)) \(box.url(source))"], in: repo)

        // Positive control: with every token in every child's environment, fetching origin reaches the other host.
        _ = try? await box.operations(naive: true, in: repo).fetch(remote: "origin")
        let controlLeaked = box.hasCredential(envDump: try box.transportEnvironment(host: Self.otherHost))
        #expect(controlLeaked, "positive control: fetching origin must reach the group's member on the other host")

        #expect(await box.decision(.fetch(remotes: ["origin"]), in: repo) == .remoteGroup(name: "origin"))
        let ops = box.operations(naive: false, in: repo)
        for what in ["Fetch All", "Fetch origin"] {
            try box.clearTransport()
            if what == "Fetch All" {
                _ = try? await ops.fetchAll()
            } else {
                _ = try? await ops.fetch(remote: "origin")
            }
            let otherLeaked = box.hasCredential(envDump: try box.transportEnvironment(host: Self.otherHost))
            let accountHostLeaked = box.hasCredential(envDump: try box.transportEnvironment(host: NetworkTokenTests.host))
            #expect(!otherLeaked, "\(what): the group's member on the other host got a token")
            #expect(!accountHostLeaked, "\(what): a fetch in a repo with a remote group got a token")
        }

        // Auto-fetch leaves origin out (it would reach the other host) and still fetches the repo's other remote.
        try await box.sandbox.git(["remote", "add", "second", box.url(source)], in: repo)
        // No user helper here: origin's group fetched without the token would fail on the other host and throw.
        try box.clearTransport()
        try await Self.backgroundFetch(box, in: repo)
        #expect(box.transportAnswer(host: Self.otherHost).isEmpty, "auto-fetch fetched the group named like origin")
        #expect(try await box.hasRef("refs/remotes/second/main", in: repo), "auto-fetch skipped the other remote")
        let secondCarried = try Self.carried(NetworkTokenTests.token, host: NetworkTokenTests.host, box)
        #expect(secondCarried, "the other remote's auto-fetch lost its token")
    }

    @Test("A remote group named like no remote (remotes.all) leaves origin's fetch, push and auto-fetch token alone")
    func groupNamedAllChangesNothing() async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let (repo, source) = try await box.makeRepoWithRemote()
        try await box.sandbox.git(["remote", "add", "upstream", box.url(source)], in: repo)
        try await box.sandbox.git(["config", "remotes.all", "origin upstream"], in: repo)
        #expect(await box.decision(.fetch(remotes: ["origin"]), in: repo) == .attach([NetworkTokenTests.credential]))
        #expect(await box.decision(.push(remote: "origin"), in: repo) == .attach([NetworkTokenTests.credential]))

        try await box.operations(naive: false, in: repo).fetch(remote: "origin")
        #expect(try await box.hasRef("refs/remotes/origin/main", in: repo))
        #expect(box.transportGot(NetworkTokenTests.token, host: NetworkTokenTests.host), "Fetch origin lost the token")

        // No user helper here: a remote fetched without the token would fail the auto-fetch.
        try box.clearTransport()
        try await Self.backgroundFetch(box, in: repo)
        #expect(try await box.hasRef("refs/remotes/upstream/main", in: repo))
        let carried = try Self.carried(NetworkTokenTests.token, host: NetworkTokenTests.host, box)
        #expect(carried, "auto-fetch lost the token in a repo with a remote group named all")
    }

    @Test("Fetch All leaves out a remote with skipFetchAll, as fetch --all does")
    func skipFetchAll() async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let (repo, source) = try await box.makeRepoWithRemote()
        try await box.sandbox.git(["remote", "add", "skipped", box.url(source)], in: repo)
        try await box.sandbox.git(["remote", "add", "older", box.url(source)], in: repo)
        try await box.sandbox.git(["config", "remote.skipped.skipFetchAll", "true"], in: repo)
        try await box.sandbox.git(["config", "remote.older.skipDefaultUpdate", "yes"], in: repo)
        #expect(try await GitOperations.fetchAllRemotes(runner: box.sandbox.runner, cwd: repo, env: box.sandbox.base)
            == ["origin"])
        try await box.operations(naive: false, in: repo).fetchAll()
        #expect(try await box.hasRef("refs/remotes/origin/main", in: repo))
        #expect(!(try await box.hasRef("refs/remotes/skipped/main", in: repo)))
        #expect(!(try await box.hasRef("refs/remotes/older/main", in: repo)))
    }

    @Test("After a merge: a branch the host deleted loses its remote-tracking ref alone (with the token); one still there is kept")
    func pruneMergedBranch() async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let (repo, source) = try await Self.makeRepo(box)
        for branch in ["feature", "kept", "stale"] {
            try await box.sandbox.git(["branch", branch], in: source)
        }
        let ops = box.operations(naive: false, in: repo)
        try await ops.fetch(remote: "origin")
        try await box.sandbox.git(["branch", "-D", "feature", "stale"], in: source)

        #expect(try await ops.pruneRemoteBranchIfDeleted(remote: "origin", branch: "feature"))
        #expect(!(try await box.hasRef("refs/remotes/origin/feature", in: repo)))
        // Only that branch: another one gone from the remote stays until a prune.
        #expect(try await box.hasRef("refs/remotes/origin/stale", in: repo))
        #expect(box.transportGot(NetworkTokenTests.token, host: NetworkTokenTests.host), "ls-remote got no token")

        #expect(!(try await ops.pruneRemoteBranchIfDeleted(remote: "origin", branch: "kept")))
        #expect(try await box.hasRef("refs/remotes/origin/kept", in: repo))
        // Already gone locally: nothing to delete.
        #expect(!(try await ops.pruneRemoteBranchIfDeleted(remote: "origin", branch: "feature")))
        await #expect(throws: GitOperationError.self) {
            try await ops.pruneRemoteBranchIfDeleted(remote: "-x", branch: "kept")
        }
    }
}
