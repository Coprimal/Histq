// Security tests for the account tokens on user-initiated network commands: the gate
// (`GitInvocation.networkToken`) gives a command only the credentials of the hosts its URLs reach, and only when
// every URL is `https://<account host>/…` in a repo without network config of its own; then nothing the repo
// configures but git-lfs's pre-push stub runs with a `HISTQ_GIT_TOKEN_<n>` or `HISTQ_GIT_USER_<n>` variable. The
// profile has two accounts, on `git.histq.invalid` and `second.histq.invalid`. Each marker case first proves, with the
// naive token environment (the write environment plus every token and its helper for every child, as before the
// gate), that its marker does see a token. No case touches the network or the Keychain: `https://<host>/<path>`
// reaches the local folder `<path>` through a fake `git-remote-https` in a copy of git's exec path, and HOME and the
// global config are temporary. A token is never put in a failure message: checks compare first, then report a Bool.
import Foundation
import HistqCore
import Testing

struct NetworkTokenTests {
    static let token = GitInvocationTests.token
    static let host = GitInvocationTests.tokenHost
    static let credential = GitInvocationTests.credential
    /// The profile's second account, on another host, with a token of its own.
    static let secondHost = "second.histq.invalid"
    static let secondToken = "ghp_HistqSecondFakeToken9876543210"
    static let secondCredential = GitCredential(
        kind: .github, host: secondHost, username: "x-access-token", token: secondToken)
    static let credentials = [credential, secondCredential]
    static var profile: Profile {
        var profile = GitInvocationTests.tokenProfile
        profile.setAccount(HostingAccount(kind: .github, host: secondHost, login: "octo2"))
        return profile
    }

    // MARK: - URL rules

    @Test(
        "only https://<profile host>/… gets the token: no other host, scheme, port or userinfo",
        arguments: [
            ("https://git.histq.invalid/octo/repo.git", true),
            ("https://GIT.histq.invalid/octo/repo", true),
            ("https://git.histq.invalid", false),
            ("http://git.histq.invalid/octo/repo", false),
            ("HTTPS://git.histq.invalid/octo/repo", false),
            ("https://user@git.histq.invalid/octo/repo", false),
            ("https://user:pw@git.histq.invalid/octo/repo", false),
            ("https://git.histq.invalid:8443/octo/repo", false),
            ("https://git.histq.invalid./octo/repo", false),
            ("https://git.histq.invalid.evil.invalid/octo/repo", false),
            ("https://evil.invalid/git.histq.invalid/octo/repo", false),
            ("https://git.histq.invalid%2f@evil.invalid/x", false),
            ("https://git.histq.invalid?@evil.invalid/x", false),
            ("https://git.histq.invalid#@evil.invalid/x", false),
            (#"https://git.histq.invalid\@evil.invalid/x"#, false),
            ("https://git.histq.invalid/octo/re po", false),
            ("ssh://git.histq.invalid/octo/repo", false),
            ("git@git.histq.invalid:octo/repo", false),
            ("ext::sh -c touch% /tmp/x", false),
            ("file:///tmp/repo", false),
            ("/tmp/repo", false),
            ("", false),
        ])
    func urlRules(url: String, expected: Bool) {
        #expect(GitInvocation.isTokenURL(url, host: Self.host) == expected)
    }

    @Test("a profile host with a port only matches that port")
    func urlRulesWithPort() {
        let host = "ghe.histq.invalid:8443"
        #expect(GitInvocation.isTokenURL("https://ghe.histq.invalid:8443/o/r", host: host))
        #expect(!GitInvocation.isTokenURL("https://ghe.histq.invalid/o/r", host: host))
        #expect(!GitInvocation.isTokenURL("https://ghe.histq.invalid:443/o/r", host: host))
    }

    // MARK: - Gate decisions

    @Test("the gate resolves insteadOf, pushInsteadOf and pushurl, and runs no transport")
    func gateFollowsRewrites() async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let repo = try await box.sandbox.makeRepo("repo")
        try await box.sandbox.git(["remote", "add", "origin", box.url(repo)], in: repo)
        #expect(await box.decision(.fetch(remotes: ["origin"]), in: repo) == .attach([Self.credential]))
        #expect(await box.decision(.push(remote: "origin"), in: repo) == .attach([Self.credential]))
        #expect(!box.transportRan, "the gate ran the transport")

        // The user's global rewrites: to another host for fetch and push, then for push only.
        try box.writeGlobal("[url \"https://evil.histq.invalid/\"]\n\tinsteadOf = https://\(Self.host)/\n")
        #expect(await box.decision(.fetch(remotes: ["origin"]), in: repo) == .otherURL)
        #expect(await box.decision(.push(remote: "origin"), in: repo) == .otherURL)
        try box.writeGlobal("[url \"https://evil.histq.invalid/\"]\n\tpushInsteadOf = https://\(Self.host)/\n")
        #expect(await box.decision(.fetch(remotes: ["origin"]), in: repo) == .attach([Self.credential]))
        #expect(await box.decision(.push(remote: "origin"), in: repo) == .otherURL)
        // A rewrite that lands on the profile's host qualifies.
        try box.writeGlobal("[url \"https://\(Self.host)/\"]\n\tinsteadOf = gh:\n")
        try await box.sandbox.git(["remote", "add", "short", "gh:octo/repo"], in: repo)
        #expect(await box.decision(.fetch(remotes: ["origin", "short"]), in: repo) == .attach([Self.credential]))

        try await box.sandbox.git(["config", "remote.origin.pushurl", "ssh://\(Self.host)/octo/repo"], in: repo)
        #expect(await box.decision(.push(remote: "origin"), in: repo) == .otherURL)
        try await box.sandbox.git(["config", "--add", "remote.short.url", "http://\(Self.host)/octo/repo"], in: repo)
        #expect(await box.decision(.fetch(remotes: ["short"]), in: repo) == .otherURL)
        #expect(await box.decision(.fetch(remotes: ["nosuch"]), in: repo) == .lookupFailed)
        #expect(await box.decision(.fetch(remotes: []), in: repo) == .otherURL)
        #expect(!box.transportRan, "the gate ran the transport")

        #expect(await GitInvocation.networkToken(
            for: .fetch(remotes: ["origin"]), credentials: [], base: box.base, runner: box.sandbox.runner,
            cwd: repo) == .noToken)
        var unusable = Self.credential
        unusable.token = "two words"
        #expect(await GitInvocation.networkToken(
            for: .fetch(remotes: ["origin"]), credentials: [unusable], base: box.base, runner: box.sandbox.runner,
            cwd: repo) == .noToken)
    }

    @Test(
        "a repo that sets its own network config does not get the token",
        arguments: [
            ("http.proxy", "http://127.0.0.1:1", "http.proxy"),
            ("http.sslVerify", "false", "http.sslverify"),
            ("http.https://git.histq.invalid.sslVerify", "false", "http.https://git.histq.invalid.sslverify"),
            ("http.sslCAInfo", "/tmp/evil.pem", "http.sslcainfo"),
            ("http.curloptResolve", "git.histq.invalid:443:127.0.0.1", "http.curloptresolve"),
            ("http.extraHeader", "X: y", "http.extraheader"),
            ("remote.origin.proxy", "http://127.0.0.1:1", "remote.origin.proxy"),
            ("url.https://evil.invalid/.insteadOf", "nothing:", "url.https://evil.invalid/.insteadof"),
            ("url.https://evil.invalid/.pushInsteadOf", "nothing:", "url.https://evil.invalid/.pushinsteadof"),
            ("credential.helper", "!true", "credential.helper"),
            ("credential.https://other.histq.invalid.helper", "!true", "credential.https://other.histq.invalid.helper"),
            ("credential.username", "someone", "credential.username"),
        ])
    func repoNetworkConfigWithholdsToken(key: String, value: String, expected: String) async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let repo = try await box.sandbox.makeRepo("repo")
        try await box.sandbox.git(["remote", "add", "origin", box.url(repo)], in: repo)
        try await box.sandbox.git(["config", key, value], in: repo)
        #expect(await box.decision(.fetch(remotes: ["origin"]), in: repo) == .repoNetworkConfig(keys: [expected]))
        #expect(await box.decision(.push(remote: "origin"), in: repo) == .repoNetworkConfig(keys: [expected]))
    }

    @Test("a remote group named like the fetched remote, in any scope, withholds the fetch's token, never the push's")
    func remoteGroupWithholdsFetchOnly() async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let repo = try await box.sandbox.makeRepo("repo")
        try await box.sandbox.git(["remote", "add", "origin", box.url(repo)], in: repo)
        try await box.sandbox.git(["config", "remotes.origin", "../b ../a"], in: repo)
        #expect(await box.decision(.fetch(remotes: ["origin"]), in: repo) == .remoteGroup(name: "origin"))
        // `git push <remote>` never resolves remote groups.
        #expect(await box.decision(.push(remote: "origin"), in: repo) == .attach([Self.credential]))

        // The user's global group counts too: git reads it in every repo.
        try await box.sandbox.git(["config", "--unset", "remotes.origin"], in: repo)
        #expect(await box.decision(.fetch(remotes: ["origin"]), in: repo) == .attach([Self.credential]))
        try box.writeGlobal("[remotes]\n\torigin = a b\n")
        #expect(await box.decision(.fetch(remotes: ["origin"]), in: repo) == .remoteGroup(name: "origin"))
        #expect(await box.decision(.push(remote: "origin"), in: repo) == .attach([Self.credential]))
    }

    @Test("a file the repo includes counts as the repo's own config; the user's global network config does not")
    func includedAndGlobalNetworkConfig() async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let repo = try await box.sandbox.makeRepo("repo")
        try await box.sandbox.git(["remote", "add", "origin", box.url(repo)], in: repo)
        try box.writeGlobal("""
            [http]
            \tproxy = http://127.0.0.1:1
            [credential]
            \thelper = !true
            [url "https://elsewhere.histq.invalid/"]
            \tinsteadOf = elsewhere:

            """)
        #expect(await box.decision(.fetch(remotes: ["origin"]), in: repo) == .attach([Self.credential]))
        let included = box.sandbox.root.appending(path: "included.config")
        try Data("[http]\n\tsslVerify\n".utf8).write(to: included)
        try await box.sandbox.git(["config", "include.path", included.path], in: repo)
        #expect(await box.decision(.fetch(remotes: ["origin"]), in: repo)
            == .repoNetworkConfig(keys: ["http.sslverify"]))
    }

    // MARK: - Fetch

    @Test("a manual fetch with the token runs no hook: the reference-transaction hook never sees it")
    func fetchHookNeverSeesToken() async throws {
        for naive in [true, false] {
            let box = try await TokenSandbox()
            defer { box.remove() }
            let (repo, _) = try await box.makeRepoWithRemote()
            try box.writeMarker("rt", to: repo.appending(path: ".git/hooks/reference-transaction"))
            try await box.operations(naive: naive, in: repo).fetchAll()
            #expect(box.transportGotToken, "the fetch did not sign in with the token (naive: \(naive))")
            #expect(try await box.hasRef("refs/remotes/origin/main", in: repo))
            if naive {
                #expect(box.sawToken("rt"), "positive control: the hook sees the token in the naive environment")
            } else {
                #expect(!box.sawToken("rt"), "the reference-transaction hook saw the token")
            }
        }
    }

    @Test("a repo's http.proxy keeps the token back: the fetch runs with the user's helper and its hook sees no token")
    func repoProxyFetchRunsWithoutToken() async throws {
        for naive in [true, false] {
            let box = try await TokenSandbox(userHelper: true)
            defer { box.remove() }
            let (repo, _) = try await box.makeRepoWithRemote()
            // The fake transport ignores the proxy: only the decision matters here.
            try await box.sandbox.git(["config", "http.proxy", "http://127.0.0.1:1"], in: repo)
            try box.writeMarker("rt", to: repo.appending(path: ".git/hooks/reference-transaction"))
            try await box.operations(naive: naive, in: repo).fetchAll()
            #expect(box.ran("rt"), "the hook ran (naive: \(naive))")
            if naive {
                #expect(box.sawToken("rt"), "positive control: the hook sees the token in the naive environment")
            } else {
                #expect(!box.sawToken("rt"), "the hook saw the token")
                #expect(!box.transportGotToken, "the transport got the token")
                #expect(box.transportGotUserSecret, "the user's own helper answered")
            }
        }
    }

    @Test("a fetch that fails to sign in after the repo's config kept the token back says why")
    func withheldTokenAuthFailureSaysWhy() async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let (repo, _) = try await box.makeRepoWithRemote()
        try await box.sandbox.git(["config", "http.proxy", "http://127.0.0.1:1"], in: repo)
        await #expect {
            try await box.operations(naive: false, in: repo).fetchAll()
        } throws: { error in
            guard let withheld = error as? NetworkTokenWithheld, case .auth = withheld.error else { return false }
            return withheld.reason == .repoNetworkConfig(keys: ["http.proxy"])
        }
        // Without repo config, a failed sign-in on a host with no account says so, with git's own error.
        let other = try await box.sandbox.makeRepo("other")
        try await box.sandbox.git(["remote", "add", "origin", "https://other.histq.invalid\(repo.path)"], in: other)
        await #expect {
            try await box.operations(naive: false, in: other).fetchAll()
        } throws: { error in
            guard let withheld = error as? NetworkTokenWithheld, case .auth = withheld.error else { return false }
            return withheld.reason == .noAccount(host: "other.histq.invalid")
        }
    }

    @Test("a repo's credential helper for another host never sees the token")
    func repoHelperForAnotherHostNeverSeesToken() async throws {
        for naive in [true, false] {
            let box = try await TokenSandbox()
            defer { box.remove() }
            let (repo, _) = try await box.makeRepoWithRemote()
            let helper = box.sandbox.root.appending(path: "bin/helper.sh")
            try box.writeMarker("helper", to: helper)
            try await box.sandbox.git(
                ["config", "credential.https://other.histq.invalid.helper", "!'\(helper.path)'"], in: repo)
            // The fake transport asks for other.histq.invalid too, as a redirect would.
            _ = try? await box.operations(naive: naive, in: repo).fetchAll()
            #expect(box.ran("helper"), "the helper ran (naive: \(naive))")
            #expect(box.sawToken("helper") == naive, "the helper saw the token: \(box.sawToken("helper")) (naive: \(naive))")
        }
    }

    @Test(
        "an ext, file or remote-helper transport never runs with the token",
        arguments: ["ext", "file", "vcs"])
    func otherTransportsNeverSeeToken(transport: String) async throws {
        for naive in [true, false] {
            let box = try await TokenSandbox()
            defer { box.remove() }
            let repo = try await box.sandbox.makeRepo("repo")
            let source = try await box.sandbox.makeRepo("source")
            let marker = box.fakeBin.appending(path: "git-remote-evil")
            try box.writeMarker("transport", to: marker)
            let config: [(String, String)] = switch transport {
            case "ext": [("remote.origin.url", "ext::\(marker.path)"), ("protocol.ext.allow", "always")]
            case "file":
                [("remote.origin.url", "file://" + source.path), ("remote.origin.uploadpack", marker.path),
                 ("protocol.file.allow", "always")]
            // An https URL on the profile's host passes the gate; the helper it names must still not run.
            default: [("remote.origin.url", box.url(source)), ("remote.origin.vcs", "evil")]
            }
            for (key, value) in config {
                try await box.sandbox.git(["config", key, value], in: repo)
            }
            _ = try? await box.operations(naive: naive, in: repo).fetchAll()
            if naive {
                #expect(box.sawToken("transport"), "positive control: the \(transport) transport sees the token")
            } else {
                #expect(!box.sawToken("transport"), "the \(transport) transport saw the token")
            }
        }
    }

    @Test("Fetch All gates each remote on its own: one on another host or a local folder does not cost the others the token")
    func fetchAllGatesEachRemote() async throws {
        let box = try await TokenSandbox(userHelper: true)
        defer { box.remove() }
        let (repo, source) = try await box.makeRepoWithRemote()
        try await box.sandbox.git(["remote", "add", "mirror", box.url(source)], in: repo)
        try await box.operations(naive: false, in: repo).fetchAll()
        #expect(box.transportGotToken)

        try box.clearTransport()
        try await box.sandbox.git(["remote", "add", "local", source.path], in: repo)
        try await box.operations(naive: false, in: repo).fetchAll()
        #expect(box.transportGotToken, "the https remotes lost the token beside a local folder")
        #expect(try await box.hasRef("refs/remotes/local/main", in: repo))
    }

    // MARK: - Accounts on several hosts

    @Test("a command whose every URL is on one account's host gets that host's credential alone, never another's")
    func onlyTheReachedHostsCredential() async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let (repo, source) = try await box.makeRepoWithRemote(host: Self.secondHost)
        #expect(await box.decision(.fetch(remotes: ["origin"]), in: repo) == .attach([Self.secondCredential]))
        #expect(await box.decision(.push(remote: "origin"), in: repo) == .attach([Self.secondCredential]))

        try await box.operations(naive: false, in: repo).fetchAll()
        #expect(
            box.transportGot(Self.secondToken, host: Self.secondHost), "the fetch did not sign in to the second host")
        try box.expectOnlySecondCredential(in: box.transportEnvironment(host: Self.secondHost), "fetch")

        try await box.sandbox.git(["commit", "-q", "--allow-empty", "-m", "to push"], in: repo)
        try box.clearTransport()
        try await box.operations(naive: false, in: repo).push(branch: "main", to: "origin", as: "pushed")
        #expect(try await box.sandbox.git(["rev-parse", "pushed"], in: source)
            == box.sandbox.git(["rev-parse", "main"], in: repo))
        #expect(
            box.transportGot(Self.secondToken, host: Self.secondHost), "the push did not sign in to the second host")
        try box.expectOnlySecondCredential(in: box.transportEnvironment(host: Self.secondHost), "push")
    }

    @Test("a fetch across remotes on two account hosts gets both credentials, each helper bound to its own host")
    func fetchAcrossTwoAccountHosts() async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let (repo, source) = try await box.makeRepoWithRemote()
        try await box.sandbox.git(["remote", "add", "second", box.url(source, host: Self.secondHost)], in: repo)
        #expect(await box.decision(.fetch(remotes: ["origin", "second"]), in: repo) == .attach(Self.credentials))
        // The set's order, whatever order the remotes come in.
        #expect(await box.decision(.fetch(remotes: ["second", "origin"]), in: repo) == .attach(Self.credentials))

        try await box.operations(naive: false, in: repo).fetchAll()
        let first = box.transportAnswer(host: Self.host)
        let second = box.transportAnswer(host: Self.secondHost)
        let firstOK = first.contains("password=\(Self.token)\n") && !first.contains(Self.secondToken)
        let secondOK = second.contains("password=\(Self.secondToken)\n") && !second.contains(Self.token)
        #expect(firstOK, "the first host did not get its own token alone")
        #expect(secondOK, "the second host did not get its own token alone")

        // Each helper answers for its own host only, with its own token.
        let env = GitInvocation.environment(
            profile: Self.profile, base: box.base, access: .network(.fetch), credentials: Self.credentials)
        let entries = GitInvocationTests.configEntries(env)
        #expect(entries.suffix(4) == [
            "credential.https://\(Self.host).helper=",
            "credential.https://\(Self.host).helper=\(GitInvocation.tokenHelper(0))",
            "credential.https://\(Self.secondHost).helper=",
            "credential.https://\(Self.secondHost).helper=\(GitInvocation.tokenHelper(1))",
        ])
        for (host, mine, other) in [(Self.host, Self.token, Self.secondToken),
                                    (Self.secondHost, Self.secondToken, Self.token)] {
            let fill = try await box.sandbox.runner.run(
                ["credential", "fill"], cwd: repo, env: env, stdin: Data("protocol=https\nhost=\(host)\n\n".utf8),
                timeout: .seconds(30))
            let bound = fill.text == "protocol=https\nhost=\(host)\nusername=x-access-token\npassword=\(mine)\n"
                && !fill.text.contains(other)
            #expect(bound, "the helper for \(host) did not answer with its own token alone")
        }

        // All or nothing: one more remote on no account's host and the fetch gets neither token.
        try await box.sandbox.git(["remote", "add", "local", source.path], in: repo)
        #expect(await box.decision(.fetch(remotes: ["origin", "second", "local"]), in: repo) == .otherURL)
    }

    @Test(
        "a username a shell or the credential protocol could misread never reaches git: the credential is dropped",
        arguments: ["$(touch MARKER)", "`touch MARKER`", "a'b", "a\"b", "a\nb", "a\rb", "a$b", "a\\b", "a:b", "a@b",
                    "a/b", "a b", ""])
    func unsafeUsernameDropsCredential(username: String) async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let marker = box.sandbox.root.appending(path: "username-ran")
        var bad = Self.credential
        bad.username = username.replacing("MARKER", with: marker.path)
        let (repo, _) = try await box.makeRepoWithRemote()
        #expect(await GitInvocation.networkToken(
            for: .fetch(remotes: ["origin"]), credentials: [bad], base: box.base, runner: box.sandbox.runner,
            cwd: repo) == .noToken)

        // Beside a good credential for another host: only that one is kept, and numbered 0.
        let env = GitInvocation.environment(
            profile: Self.profile, base: box.base, access: .network(.fetch), credentials: [bad, Self.secondCredential])
        let entries = GitInvocationTests.configEntries(env)
        #expect(!entries.contains { $0.hasPrefix("credential.https://\(Self.host).") }, "a helper for the dropped one")
        #expect(entries.suffix(2) == [
            "credential.https://\(Self.secondHost).helper=",
            "credential.https://\(Self.secondHost).helper=\(GitInvocation.tokenHelper(0))",
        ])
        let names = env.keys.filter { $0.hasPrefix("HISTQ_") }.sorted()
        #expect(names == ["HISTQ_GIT_TOKEN_0", "HISTQ_GIT_USER_0"])
        let leaked = env.values.contains { $0.contains(Self.token) || (!bad.username.isEmpty && $0 == bad.username) }
        #expect(!leaked, "the dropped credential's token or username is in the environment")

        // End to end: the fetch runs without the token, and nothing the username holds ever ran.
        let ops = GitOperations(
            runner: box.sandbox.runner, cwd: repo, profile: Self.profile, base: box.base, credentials: [bad])
        _ = try? await ops.fetchAll()
        let fill = try await box.sandbox.runner.run(
            ["credential", "fill"], cwd: repo, env: env,
            stdin: Data("protocol=https\nhost=\(Self.host)\n\n".utf8), timeout: .seconds(30),
            allowedExitCodes: Set(0...255))
        #expect(box.transportRan && !box.transportGotToken, "the fetch signed in with the dropped credential")
        let answered = fill.text.contains("password=")
        #expect(!answered, "a helper answered for the dropped credential's host")
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the username ran in a shell")
    }

    // MARK: - Fetch refspec

    @Test("fetchRefspec fetches a pull request's head into pr/<n> through the gate: the transport gets the token, no hook")
    func fetchRefspecGoesThroughGate() async throws {
        for naive in [true, false] {
            let box = try await TokenSandbox()
            defer { box.remove() }
            let (repo, source) = try await box.makeRepoWithRemote()
            try await box.sandbox.git(["update-ref", "refs/pull/1/head", "HEAD"], in: source)
            try box.writeMarker("rt", to: repo.appending(path: ".git/hooks/reference-transaction"))
            try await box.operations(naive: naive, in: repo).fetchRefspec(remote: "origin", refspec: "pull/1/head:pr/1")
            #expect(box.transportGotToken, "the fetch did not sign in with the token (naive: \(naive))")
            #expect(try await box.hasRef("refs/heads/pr/1", in: repo))
            if naive {
                #expect(box.sawToken("rt"), "positive control: the hook sees the token in the naive environment")
            } else {
                #expect(!box.sawToken("rt"), "the reference-transaction hook saw the token")
            }
        }
    }

    @Test("fetchRefspec refuses a forced, option-like, pattern or malformed refspec, a bad branch and a non-remote")
    func fetchRefspecRefusesInjection() async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let (repo, source) = try await box.makeRepoWithRemote()
        try await box.sandbox.git(["update-ref", "refs/pull/1/head", "HEAD"], in: source)
        let ops = box.operations(naive: false, in: repo)
        let cases: [(remote: String, refspec: String, error: GitOperationError)] = [
            ("origin", "+pull/1/head:pr/1", .invalidRefspec("+pull/1/head:pr/1")),
            ("origin", "pull/1/head:+pr/1", .invalidRefspec("pull/1/head:+pr/1")),
            ("origin", "--upload-pack=touch x:pr/1", .invalidRefspec("--upload-pack=touch x:pr/1")),
            ("origin", "pull/1/head", .invalidRefspec("pull/1/head")),
            ("origin", ":pr/1", .invalidRefspec(":pr/1")),
            ("origin", "a:b:c", .invalidRefspec("a:b:c")),
            ("origin", "pull/*/head:pr/1", .invalidRefspec("pull/*/head:pr/1")),
            ("origin", "pull/1/head:pr/1 x", .invalidRefspec("pull/1/head:pr/1 x")),
            ("origin", "pull/1/head:-pr", .invalidBranchName("-pr")),
            ("origin", "pull/1/head:pr/1..2", .invalidBranchName("pr/1..2")),
            ("--upload-pack=touch x", "pull/1/head:pr/1", .invalidRemoteName("--upload-pack=touch x")),
            ("-o", "pull/1/head:pr/1", .invalidRemoteName("-o")),
            (box.url(source), "pull/1/head:pr/1", .invalidRemoteName(box.url(source))),
        ]
        for item in cases {
            await #expect(throws: item.error, "\(item.remote) \(item.refspec)") {
                try await ops.fetchRefspec(remote: item.remote, refspec: item.refspec)
            }
        }
        #expect(!box.transportRan, "a refused fetch still contacted the remote")
        #expect(!(try await box.hasRef("refs/heads/pr/1", in: repo)))
        // Positive control: the same fetch with a valid refspec runs.
        try await ops.fetchRefspec(remote: "origin", refspec: "pull/1/head:pr/1")
        #expect(box.transportRan)
        #expect(try await box.hasRef("refs/heads/pr/1", in: repo))
    }

    // MARK: - Pull

    @Test(
        "a pull fetches with the token, then merges or rebases without it: the merge's hooks never see it",
        arguments: [GitOperations.PullMode.fastForward, .fastForwardOnly, .rebase])
    func pullMergeHalfRunsWithoutToken(mode: GitOperations.PullMode) async throws {
        for naive in [true, false] {
            let box = try await TokenSandbox()
            defer { box.remove() }
            let (repo, source) = try await box.makeRepoWithRemote()
            try await box.sandbox.git(["fetch", "-q", "origin"], in: repo, env: box.naiveEnvironment())
            try await box.sandbox.git(["branch", "-q", "--set-upstream-to=origin/main", "main"], in: repo)
            try await box.sandbox.git(["reset", "-q", "--hard", "origin/main"], in: repo)
            try await box.sandbox.git(["commit", "-q", "--allow-empty", "-m", "remote two"], in: source)
            if mode == .fastForward {
                // A local commit too, so the pull makes a merge commit.
                try await box.sandbox.git(["commit", "-q", "--allow-empty", "-m", "local"], in: repo)
            }
            try box.clearTransport()
            try box.writeMarker("rt", to: repo.appending(path: ".git/hooks/reference-transaction"))
            try box.writeMarker("post-merge", to: repo.appending(path: ".git/hooks/post-merge"))

            try await box.operations(naive: naive, in: repo).pull(mode)

            #expect(box.transportGotToken, "the pull's fetch did not sign in with the token (naive: \(naive))")
            let upstream = try await box.sandbox.git(["rev-parse", "origin/main"], in: repo)
            let merged = try await box.sandbox.git(["merge-base", "--is-ancestor", upstream, "HEAD"], in: repo)
            #expect(merged.isEmpty, "HEAD has the upstream")
            if mode == .fastForward {
                let subject = try await box.sandbox.git(["log", "-1", "--format=%s"], in: repo)
                #expect(subject.hasPrefix("Merge branch 'main' of https://\(Self.host)/"), "\(subject)")
                #expect(box.ran("post-merge"), "the post-merge hook ran (naive: \(naive))")
            }
            #expect(box.ran("rt"), "the reference-transaction hook ran (naive: \(naive))")
            if naive {
                #expect(box.sawToken("rt"), "positive control: the merge's hooks see the token in the naive environment")
            } else {
                #expect(!box.sawToken("rt") && !box.sawToken("post-merge"), "a merge hook saw the token")
            }
        }
    }

    @Test(
        "a split pull fails as git pull does when the upstream branch is gone from the remote",
        arguments: [GitOperations.PullMode.fastForward, .fastForwardOnly, .rebase])
    func splitPullFailsWithoutUpstream(mode: GitOperations.PullMode) async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let (repo, source) = try await box.makeRepoWithRemote()
        try await box.sandbox.git(["branch", "feature"], in: source)
        try await box.sandbox.git(["fetch", "-q", "origin"], in: repo, env: box.naiveEnvironment())
        try await box.sandbox.git(["checkout", "-q", "-b", "feature", "--track", "origin/feature"], in: repo)
        try await box.sandbox.git(["commit", "-q", "--allow-empty", "-m", "local"], in: repo)
        try await box.sandbox.git(["branch", "-q", "-D", "feature"], in: source)
        let before = try await box.sandbox.git(["rev-parse", "HEAD"], in: repo)

        await #expect(throws: GitError.self) { try await box.operations(naive: false, in: repo).pull(mode) }
        #expect(box.transportGotToken, "the split ran (its fetch signed in with the token)")
        #expect(try await box.sandbox.git(["rev-parse", "HEAD"], in: repo) == before)
    }

    @Test(
        "a split pull --rebase rebases onto the fetched commit from its fork point, as git pull --rebase does",
        arguments: ["noTrackingRef", "rewrittenTrackingRef"])
    func splitRebaseMatchesPull(scenario: String) async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let naive = box.naiveEnvironment()
        let (repo, source) = try await box.makeRepoWithRemote()
        // A pull request ref outside the default refspec, as `gh pr checkout` leaves for a fork's branch.
        try Data("a\n".utf8).write(to: source.appending(path: "pr.txt"))
        try await box.sandbox.git(["add", "pr.txt"], in: source)
        try await box.sandbox.git(["commit", "-q", "-m", "pr one"], in: source)
        let first = try await box.sandbox.git(["rev-parse", "HEAD"], in: source)
        try await box.sandbox.git(["update-ref", "refs/pull/1/head", first], in: source)
        if scenario == "rewrittenTrackingRef" {
            // Mapped to a tracking ref, so `@{upstream}` and its fork point exist.
            try await box.sandbox.git(
                ["config", "--add", "remote.origin.fetch", "+refs/pull/*/head:refs/remotes/origin/pr/*"], in: repo)
        }
        try await box.sandbox.git(["fetch", "-q", "origin", "refs/pull/1/head"], in: repo, env: naive)
        if scenario == "rewrittenTrackingRef" {
            try await box.sandbox.git(["fetch", "-q", "origin"], in: repo, env: naive)
        }
        try await box.sandbox.git(["checkout", "-q", "-b", "feature", "FETCH_HEAD"], in: repo)
        try await box.sandbox.git(["config", "branch.feature.remote", "origin"], in: repo)
        try await box.sandbox.git(["config", "branch.feature.merge", "refs/pull/1/head"], in: repo)
        try Data("local\n".utf8).write(to: repo.appending(path: "local.txt"))
        try await box.sandbox.git(["add", "local.txt"], in: repo)
        try await box.sandbox.git(["commit", "-q", "-m", "local"], in: repo)
        // The remote moves the pull request: rewritten (the fork point drops "pr one") or one commit further.
        if scenario == "rewrittenTrackingRef" {
            try await box.sandbox.git(["reset", "-q", "--hard", "HEAD^"], in: source)
            try Data("a2\n".utf8).write(to: source.appending(path: "pr.txt"))
            try await box.sandbox.git(["add", "pr.txt"], in: source)
            try await box.sandbox.git(["commit", "-q", "-m", "pr one, rewritten"], in: source)
        } else {
            try await box.sandbox.git(["commit", "-q", "--allow-empty", "-m", "pr two"], in: source)
        }
        let moved = try await box.sandbox.git(["rev-parse", "HEAD"], in: source)
        try await box.sandbox.git(["update-ref", "refs/pull/1/head", moved], in: source)
        let copy = box.sandbox.root.appending(path: "repo-naive", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: repo, to: copy)

        try await box.operations(naive: true, in: copy).pull(.rebase)
        try await box.operations(naive: false, in: repo).pull(.rebase)

        let history = { (folder: URL) in
            try await box.sandbox.git(["log", "--format=%s %T", "-n", "4"], in: folder)
        }
        let expected = try await history(copy)
        #expect(try await history(repo) == expected)
        #expect(expected.hasPrefix("local "), "\(expected)")
        #expect(try await box.sandbox.git(["rev-parse", "HEAD^"], in: repo) == moved)
        #expect(box.transportGotToken, "the split ran (its fetch signed in with the token)")
    }

    // MARK: - Submodules

    @Test(
        "with submodules and recursion on, a command gets no token; recursion off or no submodules keeps it",
        arguments: [
            ("submodule.recurse", "true", true, ["submodule.recurse"]),
            ("fetch.recurseSubmodules", "on-demand", true, ["fetch.recursesubmodules"]),
            ("push.recurseSubmodules", "check", true, ["push.recursesubmodules"]),
            ("submodule.recurse", "false", true, []),
            ("push.recurseSubmodules", "no", true, []),
            ("submodule.recurse", "true", false, []),
        ])
    func submoduleRecursionWithholdsToken(key: String, value: String, submodules: Bool, expected: [String])
        async throws
    {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let repo = try await box.sandbox.makeRepo("repo")
        try await box.sandbox.git(["remote", "add", "origin", box.url(repo)], in: repo)
        if submodules {
            try Data("[submodule \"lib\"]\n\tpath = lib\n\turl = ../lib\n".utf8)
                .write(to: repo.appending(path: ".gitmodules"))
        }
        // The user's own config.
        try box.writeGlobal("[\(key.split(separator: ".")[0])]\n\t\(key.split(separator: ".")[1]) = \(value)\n")
        let decision: GitInvocation.TokenDecision =
            expected.isEmpty ? .attach([Self.credential]) : .submoduleRecursion(keys: expected)
        #expect(await box.decision(.fetch(remotes: ["origin"]), in: repo) == decision)
        #expect(await box.decision(.push(remote: "origin"), in: repo) == decision)
    }

    @Test("a submodule entry in the repo's config counts as submodules, and a failed sign-in then says why")
    func submoduleRecursionAuthFailureSaysWhy() async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let (repo, _) = try await box.makeRepoWithRemote()
        try await box.sandbox.git(["config", "submodule.lib.active", "true"], in: repo)
        try box.writeGlobal("[submodule]\n\trecurse = true\n")
        await #expect {
            try await box.operations(naive: false, in: repo).fetchAll()
        } throws: { error in
            guard let withheld = error as? NetworkTokenWithheld, case .auth = withheld.error else { return false }
            return withheld.reason == .submoduleRecursion(keys: ["submodule.recurse"])
        }
        #expect(box.transportRan && !box.transportGotToken)
    }

    // MARK: - Push

    @Test(
        "a push with the token runs the repo's own pre-push hook without it, and no other hook",
        arguments: ["file", "symlink"])
    func pushHooksNeverSeeToken(hookKind: String) async throws {
        for naive in [true, false] {
            let box = try await TokenSandbox()
            defer { box.remove() }
            let (repo, source) = try await box.makeRepoWithRemote()
            try await box.sandbox.git(["commit", "-q", "--allow-empty", "-m", "to push"], in: repo)
            // Pushed to both account hosts (two push URLs), so the push carries both credentials.
            try await box.sandbox.git(["config", "remote.origin.pushurl", box.url(source)], in: repo)
            try await box.sandbox.git(
                ["config", "--add", "remote.origin.pushurl", box.url(source, host: Self.secondHost)], in: repo)
            // The custom hook records its arguments, its input, its whole environment, and what a
            // `git credential fill` for the first account's host gives it.
            let root = box.sandbox.root.path
            let custom = box.sandbox.root.appending(path: "hooks-src/custom-pre-push")
            try Fixtures.writeScript("""
                echo "$*" >> '\(root)/pre-push.ran'
                cat >> '\(root)/pre-push.stdin'
                env > '\(root)/pre-push.envdump'
                printf 'protocol=https\\nhost=\(Self.host)\\n\\n' | git credential fill > '\(root)/pre-push.fill' 2>/dev/null
                echo "${GIT_ALLOW_PROTOCOL-unset} ${GIT_ASKPASS-unset} ${SSH_ASKPASS-unset}" > '\(root)/pre-push.env'
                git config --get core.hooksPath > '\(root)/pre-push.hookspath'
                exit 0
                """, to: custom)
            let hook = repo.appending(path: ".git/hooks/pre-push")
            if hookKind == "symlink" {
                try FileManager.default.createSymbolicLink(at: hook, withDestinationURL: custom)
            } else {
                try FileManager.default.copyItem(at: custom, to: hook)
            }
            try box.writeMarker("rt", to: repo.appending(path: ".git/hooks/reference-transaction"))

            try await box.operations(naive: naive, in: repo).push(branch: "main", to: "origin", as: "pushed")

            let signedIn = box.transportGot(Self.token, host: Self.host)
                && box.transportGot(Self.secondToken, host: Self.secondHost)
            #expect(signedIn, "the push did not sign in to both hosts with their tokens (naive: \(naive))")
            let pushed = try await box.sandbox.git(["rev-parse", "pushed"], in: source)
            let local = try await box.sandbox.git(["rev-parse", "main"], in: repo)
            #expect(pushed == local, "the push landed (naive: \(naive))")
            // The wrapper hands git's arguments and input on: the remote's name and URL, then the refs.
            #expect(box.firstArguments("pre-push") == "origin", "the pre-push hook ran (naive: \(naive))")
            let input = (try? String(contentsOfFile: "\(root)/pre-push.stdin", encoding: .utf8)) ?? ""
            #expect(input.hasPrefix("refs/heads/main \(local) refs/heads/pushed "), "\(input)")
            let fill = (try? String(contentsOfFile: "\(root)/pre-push.fill", encoding: .utf8)) ?? ""
            let fillHasToken = fill.contains(Self.token)
            let dump = try String(contentsOfFile: "\(root)/pre-push.envdump", encoding: .utf8)
            let dumpHasCredential = box.hasCredential(envDump: dump)
            if naive {
                #expect(dumpHasCredential && fillHasToken,
                        "positive control: the hook sees the token in the naive environment")
                #expect(box.sawToken("rt"), "positive control: reference-transaction sees the token")
            } else {
                #expect(!dumpHasCredential, "the pre-push hook's environment has a credential")
                #expect(!fillHasToken, "git credential fill in the pre-push hook gave the token")
                #expect(!box.ran("rt"), "the reference-transaction hook ran during a token-carrying push")
                // The hook sees what it would without the token: the base has no protocol list or askpass, and
                // a `git` in it reads the repo's hooks folder, not the wrapper's.
                let env = (try? String(contentsOfFile: "\(root)/pre-push.env", encoding: .utf8)) ?? ""
                #expect(env == "unset unset unset\n", "\(env)")
                let hooksPath = (try? String(contentsOfFile: "\(root)/pre-push.hookspath", encoding: .utf8)) ?? "?"
                #expect(hooksPath.isEmpty, "the hook's git sees core.hooksPath \(hooksPath)")
            }
        }
    }

    @Test(
        "git-lfs's generated pre-push stub gets the token for git-lfs; a repo-named transfer agent withholds it",
        arguments: ["3.x", "2.x", "1.x-minimal", "symlink", "customTransfer"])
    func lfsStubGetsToken(variant: String) async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let (repo, source) = try await box.makeRepoWithRemote()
        try await box.sandbox.git(["commit", "-q", "--allow-empty", "-m", "to push"], in: repo)
        // Pushed to both account hosts (two push URLs), so the push carries both credentials.
        try await box.sandbox.git(["config", "remote.origin.pushurl", box.url(source)], in: repo)
        try await box.sandbox.git(
            ["config", "--add", "remote.origin.pushurl", box.url(source, host: Self.secondHost)], in: repo)
        // A fake git-lfs on PATH: records its arguments, whether it sees a credential, and what
        // `git credential fill` gives it for each host, as git-lfs asks before an upload.
        let root = box.sandbox.root.path
        try Fixtures.writeScript("""
            echo "$*" >> '\(root)/lfs.ran'
            \(TokenSandbox.sawCredential) && touch '\(root)/lfs.token'
            printf 'protocol=https\\nhost=\(Self.host)\\n\\n' | git credential fill > '\(root)/lfs.fill' 2>/dev/null
            printf 'protocol=https\\nhost=\(Self.secondHost)\\n\\n' | git credential fill > '\(root)/lfs.fill2' 2>/dev/null
            exit 0
            """, to: box.fakeBin.appending(path: "git-lfs"))
        let stub = variant == "2.x" ? Self.lfsStub2 : variant == "1.x-minimal" ? Self.lfsStubMinimal : Self.lfsStub3
        let hook = repo.appending(path: ".git/hooks/pre-push")
        if variant == "symlink" {
            let target = box.sandbox.root.appending(path: "hooks-src/pre-push")
            try Fixtures.writeScript(stub, to: target)
            try FileManager.default.createSymbolicLink(at: hook, withDestinationURL: target)
        } else {
            try Fixtures.writeScript(stub, to: hook)
        }
        if variant == "customTransfer" {
            try await box.sandbox.git(["config", "lfs.customtransfer.evil.path", "/usr/bin/true"], in: repo)
        }

        try await box.operations(naive: false, in: repo).push(branch: "main", to: "origin", as: "pushed")

        #expect(try await box.sandbox.git(["rev-parse", "pushed"], in: source)
            == box.sandbox.git(["rev-parse", "main"], in: repo))
        #expect(box.firstArguments("lfs") == "pre-push", "git-lfs ran from the stub")
        let fill = (try? String(contentsOfFile: "\(root)/lfs.fill", encoding: .utf8)) ?? ""
        let fill2 = (try? String(contentsOfFile: "\(root)/lfs.fill2", encoding: .utf8)) ?? ""
        if variant == "customTransfer" {
            let got = box.sawToken("lfs") || fill.contains(Self.token) || fill2.contains(Self.secondToken)
            #expect(!got, "git-lfs got a token")
        } else {
            let first = fill.contains("password=\(Self.token)\n") && !fill.contains(Self.secondToken)
            let second = fill2.contains("password=\(Self.secondToken)\n") && !fill2.contains(Self.token)
            #expect(box.sawToken("lfs") && first && second, "git-lfs did not get each host's own token")
        }
    }

    /// git-lfs 3.x writes this (the message is translated in some locales); 1.x and 2.x used `echo`.
    static let lfsStub3 = #"""
        command -v git-lfs >/dev/null 2>&1 || { printf >&2 "\n%s\n\n" "This repository is configured for Git LFS but 'git-lfs' was not found on your path. If you no longer wish to use Git LFS, remove this hook by deleting the 'pre-push' file in the hooks directory (set by 'core.hookspath'; usually '.git/hooks')."; exit 2; }
        git lfs pre-push "$@"
        """#
    static let lfsStub2 = #"""
        command -v git-lfs >/dev/null 2>&1 || { echo >&2 "\nThis repository is configured for Git LFS but 'git-lfs' was not found on your path. If you no longer wish to use Git LFS, remove this hook by deleting .git/hooks/pre-push.\n"; exit 2; }
        git lfs pre-push "$@"
        """#
    static let lfsStubMinimal = #"git lfs pre-push "$@""#

    @Test("the git-lfs stub rule: exact lines only, and a message the shell expands nothing in")
    func lfsStubRule() {
        let accepted = [
            "#!/bin/sh\n" + Self.lfsStub3 + "\n",
            "#!/bin/sh\n" + Self.lfsStub2 + "\n",
            "#!/bin/sh\n" + Self.lfsStubMinimal + "\n",
            "#!/bin/sh\n# a comment\n\n  " + Self.lfsStub3.replacing("\n", with: "\n\t") + "  \n\n",
            Self.lfsStub3.replacing("Git LFS but", with: "Git LFS mais"),
        ]
        for text in accepted {
            #expect(GitInvocation.isLFSPrePushStub(text), "\(text)")
        }
        let rejected = [
            "",
            "#!/bin/sh\n",
            Self.lfsStub3 + "\ntouch /tmp/x",
            "touch /tmp/x\n" + Self.lfsStub3,
            Self.lfsStub3.replacing(#""$@""#, with: #""$@"; touch /tmp/x"#),
            Self.lfsStub3.replacing(#""$@""#, with: #""$@" && touch /tmp/x"#),
            Self.lfsStub3.replacing("Git LFS but", with: "$(touch /tmp/x)"),
            Self.lfsStub3.replacing("Git LFS but", with: "`touch /tmp/x`"),
            Self.lfsStub3.replacing("Git LFS but", with: #"\" ; touch /tmp/x ; echo \""#),
            Self.lfsStub3.replacing("Git LFS but", with: #"" ; touch /tmp/x ; echo ""#),
            Self.lfsStub3.replacing("exit 2; }", with: "exit 2; }; touch /tmp/x"),
            Self.lfsStub3.replacing("command -v git-lfs", with: "command -v evil"),
            Self.lfsStub3.replacing("git lfs pre-push", with: "git lfs post-checkout"),
            Self.lfsStubMinimal + "\n" + Self.lfsStubMinimal,
            Self.lfsStub2.replacing("\\nThis", with: "This"),
        ]
        for text in rejected {
            #expect(!GitInvocation.isLFSPrePushStub(text), "\(text)")
        }
    }

    @Test("a push to a pushInsteadOf rewrite on another host does not get the token")
    func pushRewriteGetsNoToken() async throws {
        let box = try await TokenSandbox(userHelper: true)
        defer { box.remove() }
        let (repo, _) = try await box.makeRepoWithRemote()
        try box.writeGlobal("""
            [credential]
            \thelper =
            \thelper = \(box.userHelper)
            [url "https://other.histq.invalid/"]
            \tpushInsteadOf = https://\(Self.host)/

            """)
        try box.writeMarker("pre-push", to: repo.appending(path: ".git/hooks/pre-push"))
        try await box.operations(naive: false, in: repo).push(branch: "main", to: "origin", as: "copy")
        #expect(box.transportRan)
        #expect(!box.transportGotToken)
        #expect(box.ran("pre-push") && !box.sawToken("pre-push"))
    }

    // MARK: - Clone

    @Test("a clone gets the token only for an https URL on the profile's host, after the user's rewrites")
    func cloneGate() async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let source = try await box.sandbox.makeRepo("source")
        let env = { (url: String) in
            await GitInvocation.cloneEnvironment(
                url: url, profile: Self.profile, base: box.base, credentials: Self.credentials,
                runner: box.sandbox.runner)
        }
        let good = await env(box.url(source))
        let goodCarries = good["HISTQ_GIT_TOKEN_0"] == Self.token
            && !good.values.contains { $0.contains(Self.secondToken) }
        #expect(goodCarries, "the clone does not carry the first host's token alone")
        #expect(good["GIT_ALLOW_PROTOCOL"] == "https")
        let second = await env(box.url(source, host: Self.secondHost))
        let secondCarries = second["HISTQ_GIT_TOKEN_0"] == Self.secondToken
            && !second.values.contains { $0.contains(Self.token) }
        #expect(secondCarries, "a clone from the second host does not carry its token alone")
        for url in ["https://other.histq.invalid/o/r", "http://\(Self.host)/o/r", "https://me@\(Self.host)/o/r",
                    "ssh://\(Self.host)/o/r", source.path] {
            let carries = GitInvocationTests.hasCredentialVariable(await env(url))
            #expect(!carries, "\(url)")
        }
        try box.writeGlobal("[url \"https://other.histq.invalid/\"]\n\tinsteadOf = https://\(Self.host)/\n")
        let rewrittenCarries = GitInvocationTests.hasCredentialVariable(await env(box.url(source)))
        #expect(!rewrittenCarries, "a rewrite to another host kept the token")
        try box.writeGlobal("")

        // The real clone signs in with the token through the fake transport.
        let destination = box.sandbox.root.appending(path: "clone")
        try await GitOperations.clone(
            url: box.url(source), into: destination, runner: box.sandbox.runner, env: good) { _ in }
        #expect(box.transportGotToken)
        #expect(try await box.hasRef("refs/remotes/origin/main", in: destination))
    }

    // MARK: - Submodule fetch

    @Test("A submodule fetch gets the token only for an https URL on the profile's host")
    func submoduleGate() async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let lib = try await box.sandbox.makeRepo("lib")
        let libHead = try await box.sandbox.git(["rev-parse", "HEAD"], in: lib)
        let target = GitInvocation.NetworkTarget.submodule(path: "lib")
        // A parent whose origin is on the profile's host and whose `.gitmodules` gives the submodule `mod` (named
        // apart from its path) at `lib` this URL, not checked out.
        let parent = { (name: String, url: String) async throws -> URL in
            let repo = try await box.sandbox.makeRepo(name)
            try await box.sandbox.git(["remote", "add", "origin", box.url(repo)], in: repo)
            try await box.sandbox.git(["config", "-f", ".gitmodules", "submodule.mod.path", "lib"], in: repo)
            try await box.sandbox.git(["config", "-f", ".gitmodules", "submodule.mod.url", url], in: repo)
            try await box.sandbox.git(["update-index", "--add", "--cacheinfo", "160000,\(libHead),lib"], in: repo)
            try await box.sandbox.git(["add", ".gitmodules"], in: repo)
            try await box.sandbox.git(["commit", "-q", "-m", "add lib"], in: repo)
            return repo
        }

        // 1. https on the profile's host; only the repo's config counts, so nothing before `submodule init`.
        let https = try await parent("https", box.url(lib))
        #expect(await box.decision(target, in: https) == .otherURL, "no URL in the config yet")
        try await box.sandbox.git(["submodule", "init", "--", "lib"], in: https)
        #expect(await box.decision(target, in: https) == .attach([Self.credential]))
        try box.writeGlobal("[submodule]\n\trecurse = true\n")
        #expect(await box.decision(target, in: https) == .attach([Self.credential]), "the caller never recurses")
        try box.writeGlobal("")
        #expect(await box.decision(.submodule(path: "other"), in: https) == .otherURL, "no submodule at that path")

        // 2. ssh.
        let ssh = try await parent("ssh", "ssh://\(Self.host)\(lib.path)")
        try await box.sandbox.git(["submodule", "init", "--", "lib"], in: ssh)
        #expect(await box.decision(target, in: ssh) == .otherURL)

        // 3. Checked out: the submodule repo's own fetch URLs and network keys count too.
        try await box.sandbox.git(["clone", "-q", lib.path, https.appending(path: "lib").path], in: box.sandbox.root)
        #expect(await box.decision(target, in: https) == .otherURL, "its origin is a local folder")
        let checkedOut = https.appending(path: "lib")
        try await box.sandbox.git(["remote", "set-url", "origin", box.url(lib)], in: checkedOut)
        #expect(await box.decision(target, in: https) == .attach([Self.credential]))
        try await box.sandbox.git(["config", "http.proxy", "http://127.0.0.1:1"], in: checkedOut)
        #expect(await box.decision(target, in: https) == .repoNetworkConfig(keys: ["http.proxy"]))

        // 4. A relative URL, resolved by `submodule init` against the parent's https remote.
        let relative = try await parent("relative", "../lib")
        try await box.sandbox.git(["submodule", "init", "--", "lib"], in: relative)
        #expect(try await box.sandbox.git(["config", "submodule.mod.url"], in: relative) == box.url(lib))
        #expect(await box.decision(target, in: relative) == .attach([Self.credential]))

        // 5. End to end: `submodule update` in the token's environment signs in with the token.
        #expect(!box.transportRan)
        let env = GitInvocation.environment(
            profile: Self.profile, base: box.base, access: .network(.fetch), credentials: [Self.credential])
        try await box.sandbox.git(["submodule", "update", "--init", "--", "lib"], in: relative, env: env)
        #expect(box.transportGotToken)
        #expect(try await box.sandbox.git(["rev-parse", "HEAD"], in: relative.appending(path: "lib")) == libHead)
        #expect(await box.decision(target, in: relative) == .attach([Self.credential]), "checked out with an https origin")

        // A git folder left in `.git/modules` after a deinit is reused by the next update: its config counts.
        try await box.sandbox.git(["submodule", "deinit", "-q", "-f", "--", "lib"], in: relative)
        try await box.sandbox.git(["submodule", "init", "--", "lib"], in: relative)
        try await box.sandbox.git(
            ["config", "http.proxy", "http://127.0.0.1:1"], in: relative.appending(path: ".git/modules/mod"))
        #expect(await box.decision(target, in: relative) == .repoNetworkConfig(keys: ["http.proxy"]))
        try await box.sandbox.git(["submodule", "update", "--", "lib"], in: relative)
        #expect(try await box.sandbox.git(["config", "http.proxy"], in: relative.appending(path: "lib"))
            == "http://127.0.0.1:1", "the update reused the left git folder")
    }
}

// MARK: - Harness

/// A `Sandbox` whose git reaches `https://<host>/<path>` as the local folder `<path>`: `GIT_EXEC_PATH` is a
/// copy of git's exec path (links) with a fake `git-remote-https`. The fake first asks `git credential fill` for its
/// own host, as git's https transport does (and keeps the answer in `transport.txt` and `transport.<host>.txt`, and
/// its environment in `transport.<host>.env`), then for
/// `other.histq.invalid`, as after a redirect, fails like GitHub without a password, and else serves the folder with
/// `git upload-pack`/`git receive-pack`. `fakeBin` comes first on PATH.
struct TokenSandbox {
    let sandbox: Sandbox
    let base: [String: String]
    let fakeBin: URL
    /// The user's own global helper (`!'<script>'`), answering `user`/`user-secret`; set with `userHelper: true`.
    let userHelper: String
    var global: URL { sandbox.root.appending(path: "home/.gitconfig") }
    var transportFile: URL { sandbox.root.appending(path: "transport.txt") }

    init(userHelper withUserHelper: Bool = false) async throws {
        sandbox = try await Sandbox()
        let execPath = try await sandbox.git(["--exec-path"], in: sandbox.root)
        let fakeExec = sandbox.root.appending(path: "exec", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fakeExec, withIntermediateDirectories: true)
        for name in try FileManager.default.contentsOfDirectory(atPath: execPath) where name != "git-remote-https" {
            try FileManager.default.createSymbolicLink(
                at: fakeExec.appending(path: name), withDestinationURL: URL(filePath: execPath).appending(path: name))
        }
        let out = sandbox.root.appending(path: "transport.txt").path
        let root = sandbox.root.path
        try Fixtures.writeScript(#"""
            host=$(printf '%s' "$2" | cut -d/ -f3)
            dir="/${2#https://*/}"
            printf 'protocol=https\nhost=%s\n\n' "$host" | git credential fill > '\#(out)' 2>/dev/null
            cp '\#(out)' '\#(root)'"/transport.$host.txt"
            env > '\#(root)'"/transport.$host.env"
            printf 'protocol=https\nhost=other.histq.invalid\n\n' | git credential fill > /dev/null 2>&1
            grep -q '^password=' '\#(out)' || { echo "fatal: Authentication failed for '$2'" >&2; exit 128; }
            while read -r line; do
              case "$line" in
                capabilities) printf 'connect\n\n' ;;
                "connect git-"*) printf '\n'; exec git "${line#connect git-}" "$dir" ;;
                *) exit 0 ;;
              esac
            done
            """#, to: fakeExec.appending(path: "git-remote-https"))
        fakeBin = sandbox.root.appending(path: "fakebin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)

        let script = sandbox.root.appending(path: "bin/user-helper.sh")
        try Fixtures.writeScript(
            "test \"$1\" = get && printf 'username=user\\npassword=user-secret\\n'\nexit 0", to: script)
        userHelper = "!'\(script.path)'"
        try Data((withUserHelper ? "[credential]\n\thelper =\n\thelper = \(userHelper)\n" : "").utf8)
            .write(to: sandbox.root.appending(path: "home/.gitconfig"))
        var base = sandbox.base
        base["GIT_EXEC_PATH"] = fakeExec.path
        base["GIT_CONFIG_GLOBAL"] = sandbox.root.appending(path: "home/.gitconfig").path
        base["PATH"] = fakeBin.path + ":" + (base["PATH"] ?? "")
        self.base = base
    }

    func remove() { sandbox.remove() }

    func url(_ folder: URL, host: String = NetworkTokenTests.host) -> String { "https://\(host)\(folder.path)" }

    func writeGlobal(_ text: String) throws { try Data(text.utf8).write(to: global) }

    /// A repo whose `origin` is the fake https URL on `host` of `source`, a folder with a commit the repo does not have.
    func makeRepoWithRemote(host: String = NetworkTokenTests.host) async throws -> (repo: URL, source: URL) {
        let source = try await sandbox.makeRepo("source")
        try await sandbox.git(["commit", "-q", "--allow-empty", "-m", "remote only"], in: source)
        let repo = try await sandbox.makeRepo("repo")
        try await sandbox.git(["remote", "add", "origin", url(source, host: host)], in: repo)
        return (repo, source)
    }

    func decision(_ target: GitInvocation.NetworkTarget, in repo: URL) async -> GitInvocation.TokenDecision {
        await GitInvocation.networkToken(
            for: target, credentials: NetworkTokenTests.credentials, base: base, runner: sandbox.runner, cwd: repo)
    }

    /// The operations with the gate, or (`naive`) with the naive environment for every command.
    func operations(naive: Bool, in repo: URL) -> GitOperations {
        naive
            ? GitOperations(runner: sandbox.runner, cwd: repo, env: naiveEnvironment())
            : GitOperations(
                runner: sandbox.runner, cwd: repo, profile: NetworkTokenTests.profile, base: base,
                credentials: NetworkTokenTests.credentials)
    }

    /// Before the gate: the write environment plus, for every credential, its `HISTQ_GIT_TOKEN_<n>`,
    /// `HISTQ_GIT_USER_<n>` and token helper, for every child.
    func naiveEnvironment() -> [String: String] {
        var env = GitInvocation.environment(profile: NetworkTokenTests.profile, base: base, access: .write)
        var index = Int(env["GIT_CONFIG_COUNT"] ?? "") ?? 0
        for (n, credential) in NetworkTokenTests.credentials.enumerated() {
            env["GIT_CONFIG_KEY_\(index)"] = "credential.https://\(credential.host).helper"
            env["GIT_CONFIG_VALUE_\(index)"] = GitInvocation.tokenHelper(n)
            env["HISTQ_GIT_TOKEN_\(n)"] = credential.token
            env["HISTQ_GIT_USER_\(n)"] = "x-access-token"
            index += 1
        }
        env["GIT_CONFIG_COUNT"] = String(index)
        return env
    }

    /// A shell test that succeeds when the environment has any `HISTQ_GIT_TOKEN*` or `HISTQ_GIT_USER_*` variable or
    /// either token's value.
    static var sawCredential: String {
        "{ env | grep -q -e '^HISTQ_GIT_TOKEN' -e '^HISTQ_GIT_USER_' || env | grep -qF -e '\(NetworkTokenTests.token)' "
            + "-e '\(NetworkTokenTests.secondToken)'; }"
    }

    /// A marker script: appends its arguments to `<name>.ran`, touches `<name>.token` when it sees a credential
    /// (`sawCredential`), prints nothing and succeeds (a hook, a credential helper or a transport).
    func writeMarker(_ name: String, to url: URL) throws {
        let ran = sandbox.root.appending(path: "\(name).ran").path
        let token = sandbox.root.appending(path: "\(name).token").path
        try Fixtures.writeScript(
            "echo \"$*\" >> '\(ran)'\n\(Self.sawCredential) && touch '\(token)'\nexit 0", to: url)
    }

    /// Whether an `env` dump has a variable that carries a credential (a line that starts with `HISTQ_GIT_TOKEN` or
    /// `HISTQ_GIT_USER_`; a `GIT_CONFIG_VALUE_<n>` with a helper's text only names them) or either token's value.
    func hasCredential(envDump dump: String) -> Bool {
        dump.split(separator: "\n").contains { $0.hasPrefix("HISTQ_GIT_TOKEN") || $0.hasPrefix("HISTQ_GIT_USER_") }
            || dump.contains(NetworkTokenTests.token) || dump.contains(NetworkTokenTests.secondToken)
    }

    /// Checks that `dump`, the environment of a command that reaches the second account's host alone, has that
    /// account's token as `HISTQ_GIT_TOKEN_0` and nothing of the first account's: not its token, nor its helper.
    func expectOnlySecondCredential(in dump: String, _ what: String) throws {
        let lines = dump.split(separator: "\n").map(String.init)
        let second = lines.contains("HISTQ_GIT_TOKEN_0=\(NetworkTokenTests.secondToken)")
        let firstToken = dump.contains(NetworkTokenTests.token)
        let firstHelper = lines.contains { $0.hasSuffix("=credential.https://\(NetworkTokenTests.host).helper") }
        let others = lines.contains { $0.hasPrefix("HISTQ_GIT_TOKEN_1") || $0.hasPrefix("HISTQ_GIT_USER_1") }
        #expect(second, "the \(what) does not carry the second host's token")
        #expect(!firstToken, "the \(what) carries the first host's token")
        #expect(!firstHelper, "the \(what) has a helper for the first host")
        #expect(!others, "the \(what) has a second credential's variables")
    }

    func ran(_ name: String) -> Bool { exists("\(name).ran") }
    func sawToken(_ name: String) -> Bool { exists("\(name).token") }

    /// The first word the marker's first run got.
    func firstArguments(_ name: String) -> String? {
        let text = try? String(contentsOf: sandbox.root.appending(path: "\(name).ran"), encoding: .utf8)
        return text?.split(separator: "\n").first?.split(separator: " ").first.map(String.init)
    }

    var transportRan: Bool { FileManager.default.fileExists(atPath: transportFile.path) }
    var transportGotToken: Bool { transportAnswer.contains("password=\(NetworkTokenTests.token)\n") }
    var transportGotUserSecret: Bool { transportAnswer.contains("password=user-secret\n") }
    private var transportAnswer: String { (try? String(contentsOf: transportFile, encoding: .utf8)) ?? "" }

    /// What the transport's `git credential fill` gave for `host` (its last run there).
    func transportAnswer(host: String) -> String {
        (try? String(contentsOf: sandbox.root.appending(path: "transport.\(host).txt"), encoding: .utf8)) ?? ""
    }

    /// Whether the transport's last run on `host` signed in with `token`.
    func transportGot(_ token: String, host: String) -> Bool {
        transportAnswer(host: host).contains("password=\(token)\n")
    }

    /// The environment the transport's last run on `host` had (`env`).
    func transportEnvironment(host: String) throws -> String {
        try String(contentsOf: sandbox.root.appending(path: "transport.\(host).env"), encoding: .utf8)
    }

    func clearTransport() throws {
        if transportRan { try FileManager.default.removeItem(at: transportFile) }
        for name in try FileManager.default.contentsOfDirectory(atPath: sandbox.root.path)
        where name.hasPrefix("transport.") {
            try FileManager.default.removeItem(at: sandbox.root.appending(path: name))
        }
    }

    func hasRef(_ ref: String, in repo: URL) async throws -> Bool {
        try await sandbox.runner.run(
            ["rev-parse", "--verify", "-q", ref], cwd: repo, env: sandbox.base, allowedExitCodes: [0, 1]).exitCode == 0
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: sandbox.root.appending(path: name).path)
    }
}

extension Sandbox {
    /// A setup command with another environment; returns its trimmed stdout.
    @discardableResult
    func git(_ args: [String], in dir: URL, env: [String: String]) async throws -> String {
        let result = try await runner.run(args, cwd: dir, env: env, timeout: .seconds(30))
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
