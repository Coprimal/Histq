// Security tests for GitInvocation: the profile reaches git and ssh intact, and an automatic read in a
// hostile repo (its `.git/config`, `.git/info/attributes`, hooks, submodules) runs none of the commands the
// repo configures. Every marker case first proves, with the plain (write) environment, that its repo does
// run the marker script, so a passing guard means the override works, not that the fixture never fires.
import Foundation
import HistqCore
import Testing

struct GitInvocationTests {
    static let profile = Profile(
        name: "Work", color: "#E5B13A",
        identity: .init(name: "Profile Person", email: "profile@histq.invalid"))

    /// The automatic status read (StatusReader, task 2.4) and the WIP diff (diff loaders, task 3.2).
    static let statusRead = StatusReader.arguments
    static let wipDiffRead = ["diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=dirty"]

    // MARK: - Profile injection

    @Test("the profile identity wins over the repo's own user.*, author.* and committer.* config")
    func profileIdentityWinsOverRepoConfig() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")
        try await sandbox.git(["config", "author.name", "Repo Author"], in: repo)
        try await sandbox.git(["config", "committer.email", "committer@repo.invalid"], in: repo)

        let plain = GitInvocation.environment(profile: nil, base: sandbox.base)
        let repoAuthor = try await sandbox.runner.run(["var", "GIT_AUTHOR_IDENT"], cwd: repo, env: plain).text
        #expect(repoAuthor.hasPrefix("Repo Author <local@histq.invalid> "), "the repo config is in effect")

        let write = GitInvocation.environment(profile: Self.profile, base: sandbox.base)
        let read = try await GitInvocation.readEnvironment(
            profile: Self.profile, base: sandbox.base, runner: sandbox.runner, cwd: repo)
        for env in [write, read] {
            for variable in ["GIT_AUTHOR_IDENT", "GIT_COMMITTER_IDENT"] {
                let ident = try await sandbox.runner.run(["var", variable], cwd: repo, env: env).text
                #expect(ident.hasPrefix("Profile Person <profile@histq.invalid> "), "\(variable): \(ident)")
            }
        }
    }

    /// The identity keys of `env`'s command-scope config, in order.
    static func identityEntries(_ env: [String: String]) -> [String] {
        configEntries(env).filter { entry in
            ["user.name=", "user.email=", "author.", "committer."].contains { entry.hasPrefix($0) }
        }
    }

    @Test(
        "an empty or blank profile name or email passes no key for it, in the write and terminal environments",
        arguments: [
            ("", "", [String]()),
            (" \t", "\n ", []),
            ("Profile Person", "", ["user.name=Profile Person", "author.name=Profile Person",
                                    "committer.name=Profile Person"]),
            ("  ", "profile@histq.invalid", ["user.email=profile@histq.invalid", "author.email=profile@histq.invalid",
                                             "committer.email=profile@histq.invalid"]),
            ("Profile Person", "profile@histq.invalid", [
                "user.name=Profile Person", "user.email=profile@histq.invalid",
                "author.name=Profile Person", "author.email=profile@histq.invalid",
                "committer.name=Profile Person", "committer.email=profile@histq.invalid",
            ]),
        ])
    func identityConfigSkipsEmptyFields(name: String, email: String, expected: [String]) {
        let profile = Profile(name: "Work", color: "#E5B13A", identity: .init(name: name, email: email))
        let write = GitInvocation.environment(profile: profile, base: [:])
        let terminal = GitInvocation.terminalEnvironment(profile: profile)
        #expect(Self.identityEntries(write) == expected)
        #expect(Self.identityEntries(terminal) == expected)
    }

    @Test("git falls back to its own config for what the profile leaves empty, never an empty ident")
    func emptyProfileIdentityFallsBackToGitConfig() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")
        let cases: [(name: String, email: String, ident: String)] = [
            ("", "", "Repo Local <local@histq.invalid> "),
            ("Profile Person", " ", "Profile Person <local@histq.invalid> "),
            ("", "profile@histq.invalid", "Repo Local <profile@histq.invalid> "),
        ]
        for (name, email, expected) in cases {
            let profile = Profile(name: "Work", color: "#E5B13A", identity: .init(name: name, email: email))
            let env = GitInvocation.environment(profile: profile, base: sandbox.base)
            for variable in ["GIT_AUTHOR_IDENT", "GIT_COMMITTER_IDENT"] {
                let ident = try await sandbox.runner.run(["var", variable], cwd: repo, env: env).text
                #expect(ident.hasPrefix(expected), "\(variable) for (\(name), \(email)): \(ident)")
            }
        }
    }

    @Test("an SSH key path with a space and a single quote reaches ssh as one -i argument")
    func sshKeyPathIsOneArgument() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let fakeBin = sandbox.root.appending(path: "fakebin")
        try Fixtures.writeScript(#"printf '%s\0' "$@""#, to: fakeBin.appending(path: "ssh"))
        let keyPath = sandbox.root.appending(path: "my key's dir/id_ed25519").path
        var profile = Self.profile
        profile.ssh = .keyFile(path: keyPath)
        let env = GitInvocation.environment(profile: profile, base: sandbox.base)
        let command = try #require(env["GIT_SSH_COMMAND"])

        // Git runs GIT_SSH_COMMAND through `/bin/sh -c`; the fake `ssh` prints its argv NUL-separated.
        let shell = GitRunner(executable: URL(filePath: "/bin/sh"))
        let output = try await shell.run(
            ["-c", command], cwd: sandbox.root, env: ["PATH": "\(fakeBin.path):/usr/bin:/bin"],
            timeout: .seconds(10))
        let argv = output.text.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
        #expect(argv == ["-o", "BatchMode=yes", "-i", keyPath, "-o", "IdentitiesOnly=yes"])
    }

    @Test(
        "a signing method with a blank key and sign-by-default gives git no user.signingKey and no signing",
        arguments: [Profile.Signing.gpg(keyID: ""), .gpg(keyID: "  "), .ssh(keyPath: ""), .ssh(keyPath: " \n")])
    func blankSigningKeyDoesNotSign(signing: Profile.Signing) async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")
        var profile = Self.profile
        profile.signing = signing
        profile.signByDefault = true
        let env = GitInvocation.environment(profile: profile, base: sandbox.base)

        // Exit 1: the key is not set in any scope.
        let key = try await sandbox.runner.run(
            ["config", "--get", "user.signingKey"], cwd: repo, env: env, allowedExitCodes: [0, 1])
        #expect(key.exitCode == 1, "user.signingKey: \(key.text)")
        let sign = try await sandbox.runner.run(["config", "--get", "commit.gpgSign"], cwd: repo, env: env)
        #expect(sign.text.trimmingCharacters(in: .whitespacesAndNewlines) == "false")
    }

    // MARK: - Untrusted repo config

    @Test("a repo's core.fsmonitor hook does not run during a read")
    func fsmonitorHookDoesNotRun() async throws {
        try await expectReadsRunNothing(controls: [{ _ in ["status"] }], reads: [{ _ in Self.statusRead }]) { sandbox in
            let repo = try await sandbox.makeRepo("repo")
            try await sandbox.git(["config", "core.fsmonitor", sandbox.evil.path], in: repo)
            return Built(repo: repo)
        }
    }

    @Test(
        "a filter driver named by .git/info/attributes does not run on a stat-dirty file during a read",
        arguments: [("clean", "evil"), ("process", "evil"), ("clean", "\u{301}evil.x")])
    func filterDriverDoesNotRun(variable: String, driver: String) async throws {
        try await expectReadsRunNothing(
            controls: [{ _ in ["status"] }, { _ in ["diff"] }],
            reads: [{ _ in Self.statusRead }, { _ in Self.wipDiffRead }]
        ) { sandbox in
            let repo = try await sandbox.makeRepo("repo")
            try await sandbox.git(["config", "filter.\(driver).\(variable)", sandbox.evil.path], in: repo)
            try Data("* filter=\(driver)\n".utf8).write(to: repo.appending(path: ".git/info/attributes"))
            try Sandbox.makeStatDirty(repo.appending(path: "tracked.txt"))
            return Built(repo: repo)
        }
    }

    @Test(
        "a read fails closed when the config names a filter or diff driver that is not valid UTF-8",
        arguments: [("filter", GitInvocation.ReadSafetyError.filterDriverNotUTF8), ("diff", .diffDriverNotUTF8)])
    func nonUTF8DriverFailsClosed(section: String, error: GitInvocation.ReadSafetyError) async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")
        // No environment string can carry this name, so its override cannot be expressed.
        let config = try FileHandle(forWritingTo: repo.appending(path: ".git/config"))
        try config.seekToEnd()
        try config.write(contentsOf: Data("[\(section) \"".utf8) + Data([0xFF, 0xFE]) + Data("\"]\n\tx = y\n".utf8))
        try config.close()
        for cache in [nil, ReadEnvironmentCache()] {
            await #expect(throws: error) {
                try await GitInvocation.readEnvironment(
                    profile: Self.profile, base: sandbox.base, runner: sandbox.runner, cwd: repo, cache: cache)
            }
        }
    }

    @Test("a populated submodule's own clean filter does not run during a read")
    func submoduleFilterDoesNotRun() async throws {
        // The control drops --ignore-submodules=dirty: that flag is the guard here, since the submodule's
        // filters are not configured in the superproject and so are not listed by the read environment.
        try await expectReadsRunNothing(
            controls: [{ _ in ["status"] }, { _ in ["diff"] }],
            reads: [{ _ in Self.statusRead }, { _ in Self.wipDiffRead }]
        ) { sandbox in
            let source = try await sandbox.makeRepo("sub-source")
            try Data("* filter=evil\n".utf8).write(to: source.appending(path: ".gitattributes"))
            try await sandbox.git(["add", ".gitattributes"], in: source)
            try await sandbox.git(["commit", "-q", "-m", "attributes"], in: source)
            let repo = try await sandbox.makeRepo("super")
            let sub = try await sandbox.addSubmodule(source, as: "sub", in: repo)
            try await sandbox.git(["config", "filter.evil.clean", sandbox.evil.path], in: sub)
            try Sandbox.makeStatDirty(sub.appending(path: "tracked.txt"))
            return Built(repo: repo)
        }
    }

    @Test("a repo's gpg.program does not run for a signed stash commit with log.showSignature set")
    func signatureProgramDoesNotRun() async throws {
        let show: Command = { ["show", "--no-ext-diff", "--no-textconv", $0.revs[0]] }
        try await expectReadsRunNothing(
            controls: [{ _ in ["stash", "list"] }, show], reads: [{ _ in ["stash", "list"] }, show]
        ) { sandbox in
            let repo = try await sandbox.makeRepo("repo")
            try await sandbox.git(["config", "log.showSignature", "true"], in: repo)
            try await sandbox.git(["config", "gpg.program", sandbox.evil.path], in: repo)
            let tree = try await sandbox.git(["rev-parse", "HEAD^{tree}"], in: repo)
            let parent = try await sandbox.git(["rev-parse", "HEAD"], in: repo)
            let commit = """
                tree \(tree)
                parent \(parent)
                author Repo Local <local@histq.invalid> 1700000000 +0000
                committer Repo Local <local@histq.invalid> 1700000000 +0000
                gpgsig -----BEGIN PGP SIGNATURE-----
                 iQEzBAABCAAdFiEEZmFrZWZha2VmYWtlZmFrZWZha2U=
                 =fake
                 -----END PGP SIGNATURE-----

                On main: signed stash

                """
            let sha = try await sandbox.git(
                ["hash-object", "-t", "commit", "-w", "--stdin"], in: repo, stdin: Data(commit.utf8))
            try await sandbox.git(
                ["update-ref", "--create-reflog", "-m", "On main: signed stash", "refs/stash", sha], in: repo)
            return Built(repo: repo, revs: [sha])
        }
    }

    @Test("a submodule's diff.external does not run when the superproject sets diff.submodule=diff")
    func submoduleExternalDiffDoesNotRun() async throws {
        let show: Command = { ["show", "--no-ext-diff", "--no-textconv", $0.revs[1]] }
        let diff: Command = { ["diff", "--no-ext-diff", "--no-textconv", $0.revs[0], $0.revs[1]] }
        try await expectReadsRunNothing(controls: [show, diff], reads: [show, diff]) { sandbox in
            let source = try await sandbox.makeRepo("sub-source")
            let repo = try await sandbox.makeRepo("super")
            let sub = try await sandbox.addSubmodule(source, as: "sub", in: repo)
            let before = try await sandbox.git(["rev-parse", "HEAD"], in: repo)
            try await sandbox.git(["config", "user.name", "Repo Local"], in: sub)
            try await sandbox.git(["config", "user.email", "local@histq.invalid"], in: sub)
            try Data("changed\n".utf8).write(to: sub.appending(path: "tracked.txt"))
            try await sandbox.git(["commit", "-q", "-a", "-m", "change"], in: sub)
            try await sandbox.git(["commit", "-q", "-a", "-m", "bump sub"], in: repo)
            let after = try await sandbox.git(["rev-parse", "HEAD"], in: repo)
            try await sandbox.git(["config", "diff.submodule", "diff"], in: repo)
            try await sandbox.git(["config", "diff.external", sandbox.evil.path], in: sub)
            return Built(repo: repo, revs: [before, after])
        }
    }

    @Test("a repo's diff.external does not run for a porcelain diff during a read")
    func externalDiffDoesNotRun() async throws {
        // The read omits --no-ext-diff, so the override is the guard (the read then fails: it may).
        try await expectReadsRunNothing(
            controls: [{ _ in ["diff"] }], reads: [{ _ in ["diff"] }], readsMayFail: true
        ) { sandbox in
            let repo = try await sandbox.makeRepo("repo")
            try await sandbox.git(["config", "diff.external", sandbox.evil.path], in: repo)
            try Data("changed\n".utf8).write(to: repo.appending(path: "tracked.txt"))
            return Built(repo: repo)
        }
    }

    @Test(
        "a diff driver named by .git/info/attributes does not run during a read",
        arguments: [("textconv", "evil"), ("command", "evil"), ("textconv", "\u{301}evil.x")])
    func diffDriverDoesNotRun(variable: String, driver: String) async throws {
        // The reads omit --no-ext-diff and --no-textconv, so the overrides are the guard (a read may fail).
        let show: Command = { _ in ["show", "HEAD"] }
        let controls: [Command] = [{ _ in ["diff"] }] + (variable == "textconv" ? [show] : [])
        try await expectReadsRunNothing(
            controls: controls, reads: [{ _ in ["diff"] }, show, { _ in ["log", "-p"] }], readsMayFail: true
        ) { sandbox in
            let repo = try await sandbox.makeRepo("repo")
            try await sandbox.git(["config", "diff.\(driver).\(variable)", sandbox.evil.path], in: repo)
            try Data("* diff=\(driver)\n".utf8).write(to: repo.appending(path: ".git/info/attributes"))
            try Data("changed\n".utf8).write(to: repo.appending(path: "tracked.txt"))
            return Built(repo: repo)
        }
    }

    @Test("a filter driver and a diff driver in the repo config are both disabled by one read environment")
    func filterAndDiffDriversFromOneListing() async throws {
        // Each control fires one driver only: status runs the clean filter on the stat-dirty file, show runs
        // the textconv; the reads omit --no-ext-diff and --no-textconv, so the overrides are the guard.
        let show: Command = { _ in ["show", "HEAD"] }
        try await expectReadsRunNothing(
            controls: [{ _ in ["status"] }, show], reads: [{ _ in Self.statusRead }, show, { _ in ["diff"] }],
            readsMayFail: true
        ) { sandbox in
            let repo = try await sandbox.makeRepo("repo")
            try await sandbox.git(["config", "filter.evilfilter.clean", sandbox.evil.path], in: repo)
            try await sandbox.git(["config", "diff.evildiff.textconv", sandbox.evil.path], in: repo)
            try Data("* filter=evilfilter diff=evildiff\n".utf8)
                .write(to: repo.appending(path: ".git/info/attributes"))
            try Sandbox.makeStatDirty(repo.appending(path: "tracked.txt"))
            return Built(repo: repo)
        }
    }

    @Test(
        "a partial clone's promisor remote does not fetch a missing blob or branch tip through its uploadpack during a read",
        arguments: [nil, "GIT_NO_LAZY_FETCH", "GIT_ALLOW_PROTOCOL"])
    func lazyFetchDoesNotRun(withoutVariable: String?) async throws {
        // Each guard alone must hold: without GIT_NO_LAZY_FETCH (as on git < 2.44) the transport block
        // stops the fetch, and without the transport block GIT_NO_LAZY_FETCH does. The repo allows the
        // file protocol itself, which beats a command-scope `protocol.allow=never`. The read fails on the
        // missing objects: it may. The shipped log and ref reads touch the branch whose tip is missing.
        let show: Command = { ["show", "--no-ext-diff", "--no-textconv", $0.revs[0]] }
        let shipped: [Command] = [{ _ in LogReader.arguments }, { _ in RefReader.arguments }]
        try await expectReadsRunNothing(
            controls: [show] + shipped, reads: [show] + shipped, readsMayFail: true,
            withoutVariable: withoutVariable
        ) { sandbox in
            let source = try await sandbox.makeRepo("source")
            try Data("only in the source\n".utf8).write(to: source.appending(path: "remote-only.txt"))
            try await sandbox.git(["add", "remote-only.txt"], in: source)
            try await sandbox.git(["commit", "-q", "-m", "remote only"], in: source)
            let blob = try await sandbox.git(["rev-parse", "HEAD:remote-only.txt"], in: source)
            let repo = try await sandbox.makeRepo("repo")
            for (key, value) in [
                ("core.repositoryformatversion", "1"), ("extensions.partialClone", "origin"),
                ("remote.origin.url", source.path), ("remote.origin.promisor", "true"),
                ("remote.origin.uploadpack", sandbox.evil.path), ("protocol.file.allow", "always"),
            ] {
                try await sandbox.git(["config", key, value], in: repo)
            }
            let tree = try await sandbox.git(
                ["mktree", "--missing"], in: repo, stdin: Data("100644 blob \(blob)\tremote-only.txt\n".utf8))
            let commit = try await sandbox.git(["commit-tree", "-m", "missing blob", tree], in: repo)
            // A branch whose tip commit only the source has (`update-ref` would refuse it).
            let sourceHead = try await sandbox.git(["rev-parse", "HEAD"], in: source)
            try Data("\(sourceHead)\n".utf8).write(to: repo.appending(path: ".git/refs/heads/gone"))
            return Built(repo: repo, revs: [commit])
        }
    }

    @Test("a post-index-change hook does not run and the index is not written by a read on a stat-dirty file")
    func indexIsNotRefreshedByRead() async throws {
        try await expectReadsRunNothing(
            controls: [{ _ in ["diff"] }], reads: [{ _ in Self.statusRead }, { _ in Self.wipDiffRead }]
        ) { sandbox in
            let repo = try await sandbox.makeRepo("repo")
            try Fixtures.writeScript(
                "touch '\(sandbox.marker.path)'", to: repo.appending(path: ".git/hooks/post-index-change"))
            try Sandbox.makeStatDirty(repo.appending(path: "tracked.txt"))
            return Built(repo: repo)
        }
    }

    // MARK: - Read environment cache

    /// Where a filter driver configured after the cache was filled comes from.
    enum DriverOrigin: String, CaseIterable, Sendable {
        case repoConfig, worktreeConfig, globalCreated, relativeInclude, includeIfGitdir, onBranchInclude
    }

    @Test(
        "a cache hit runs no git process, and a filter driver configured after the fill is still neutralised",
        arguments: DriverOrigin.allCases)
    func cacheSeesNewDriver(origin: DriverOrigin) async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let counted = try sandbox.countingRunner()
        let repo = try await sandbox.makeRepo("repo")
        let evil = sandbox.evil.path
        var base = sandbox.base
        var cwd = repo
        let file = { (name: String) in sandbox.root.appending(path: name).path }
        switch origin {
        case .repoConfig:
            break
        case .worktreeConfig:
            try await sandbox.git(["config", "extensions.worktreeConfig", "true"], in: repo)
            cwd = sandbox.root.appending(path: "linked", directoryHint: .isDirectory)
            try await sandbox.git(["worktree", "add", "-q", cwd.path], in: repo)
        case .globalCreated:
            base["GIT_CONFIG_GLOBAL"] = nil
        case .relativeInclude:
            try await sandbox.git(["config", "-f", file("included.cfg"), "core.abbrev", "12"], in: sandbox.root)
            try await sandbox.git(["config", "include.path", "../../included.cfg"], in: repo)
        case .includeIfGitdir:
            // The target is absent when the cache is filled: creating it must invalidate. A pattern, since the
            // temp folder's path and the git dir's real path differ by `/private`.
            try await sandbox.git(["config", "includeIf.gitdir:**/repo/.git.path", file("gitdir.cfg")], in: repo)
        case .onBranchInclude:
            try await sandbox.git(["config", "-f", file("branch.cfg"), "filter.evil.clean", evil], in: sandbox.root)
            try await sandbox.git(["config", "includeIf.onbranch:x.path", "../../branch.cfg"], in: repo)
        }
        // A file changed less than 2 s before a listing is never cached (ctime cannot be set back).
        try await Task.sleep(for: .milliseconds(2100))
        let cache = ReadEnvironmentCache()
        let read = { [base, cwd] in
            try await GitInvocation.readEnvironment(
                profile: nil, base: base, runner: counted.runner, cwd: cwd, cache: cache)
        }
        let filled = try await read()
        #expect(!filled.values.contains("filter.evil.clean"))
        let processes = try counted.count()
        #expect(processes > 0)
        #expect(try await read() == filled, "a hit returns the same environment")
        #expect(try counted.count() == processes, "a hit runs no git process")

        switch origin {
        case .repoConfig:
            try await sandbox.git(["config", "filter.evil.clean", evil], in: repo)
        case .worktreeConfig:
            try await sandbox.git(["config", "--worktree", "filter.evil.clean", evil], in: cwd)
        case .globalCreated:
            try await sandbox.git(
                ["config", "-f", sandbox.root.appending(path: "home/.gitconfig").path, "filter.evil.clean", evil],
                in: sandbox.root)
        case .relativeInclude:
            try await sandbox.git(["config", "-f", file("included.cfg"), "filter.evil.clean", evil], in: sandbox.root)
        case .includeIfGitdir:
            try await sandbox.git(["config", "-f", file("gitdir.cfg"), "filter.evil.clean", evil], in: sandbox.root)
        case .onBranchInclude:
            try await sandbox.git(["checkout", "-q", "-b", "x"], in: repo)
        }
        let changed = try await read()
        #expect(changed.values.contains("filter.evil.clean"), "the new driver is neutralised")

        // The plain environment runs the new driver on a stat-dirty file; the cached read environment does not.
        try Data("* filter=evil\n".utf8).write(to: cwd.appending(path: ".gitattributes"))
        try Sandbox.makeStatDirty(cwd.appending(path: "tracked.txt"))
        let plain = GitInvocation.environment(profile: nil, base: base)
        _ = try? await sandbox.runner.run(["status"], cwd: cwd, env: plain, allowedExitCodes: Set(0...255))
        #expect(sandbox.markerExists, "positive control: the plain status runs the new driver")
        try? FileManager.default.removeItem(at: sandbox.marker)
        try Sandbox.makeStatDirty(cwd.appending(path: "tracked.txt"))
        _ = try await sandbox.runner.run(Self.statusRead, cwd: cwd, env: changed, allowedExitCodes: Set(0...255))
        #expect(!sandbox.markerExists, "the read ran the new driver")
    }

    @Test("a cached read environment is not shared between a superproject and its submodule")
    func cacheKeyedByFolder() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let source = try await sandbox.makeRepo("sub-source")
        let repo = try await sandbox.makeRepo("super")
        let sub = try await sandbox.addSubmodule(source, as: "sub", in: repo)
        try await sandbox.git(["config", "filter.evil.clean", sandbox.evil.path], in: sub)
        // Past the 2 s race margin, so the superproject's entry is cached and a shared key would be a stale hit.
        try await Task.sleep(for: .milliseconds(2100))
        let counted = try sandbox.countingRunner()
        let cache = ReadEnvironmentCache()
        let read = { (cwd: URL) in
            try await GitInvocation.readEnvironment(
                profile: nil, base: sandbox.base, runner: counted.runner, cwd: cwd, cache: cache)
        }
        let superEnv = try await read(repo)
        #expect(!superEnv.values.contains("filter.evil.clean"))
        let processes = try counted.count()
        #expect(try await read(repo) == superEnv)
        #expect(try counted.count() == processes, "the superproject's second read is a hit")
        #expect(try await read(sub).values.contains("filter.evil.clean"))
    }

    @Test("a nested repo whose git dir breaks after the fill gives the drivers of the repo git falls back to")
    func cacheMissesWhenGitDirBreaks() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let outer = try await sandbox.makeRepo("outer")
        try await sandbox.git(["config", "filter.evil.clean", sandbox.evil.path], in: outer)
        let inner = try await sandbox.makeRepo("outer/inner")
        // Past the 2 s race margin, so the inner repo's entry is cached.
        try await Task.sleep(for: .milliseconds(2100))
        let cache = ReadEnvironmentCache()
        let read = {
            try await GitInvocation.readEnvironment(
                profile: nil, base: sandbox.base, runner: sandbox.runner, cwd: inner, cache: cache)
        }
        #expect(try await !read().values.contains("filter.evil.clean"))
        // Without HEAD the folder is no git dir, so git searches the parent folders and finds the outer repo.
        try FileManager.default.removeItem(at: inner.appending(path: ".git/HEAD"))
        #expect(try await read().values.contains("filter.evil.clean"))
    }

    @Test("a folder symlink repointed to another repo after the fill gives that repo's drivers")
    func cacheFollowsRepointedSymlink() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let first = try await sandbox.makeRepo("first")
        let second = try await sandbox.makeRepo("second")
        try await sandbox.git(["config", "filter.evil.clean", sandbox.evil.path], in: second)
        let link = sandbox.root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        // Past the 2 s race margin, so the first read is cached and the second would be a stale hit.
        try await Task.sleep(for: .milliseconds(2100))
        let counted = try sandbox.countingRunner()
        let cache = ReadEnvironmentCache()
        let read = {
            try await GitInvocation.readEnvironment(
                profile: nil, base: sandbox.base, runner: counted.runner, cwd: link, cache: cache)
        }
        #expect(try await !read().values.contains("filter.evil.clean"))
        let processes = try counted.count()
        _ = try await read()
        #expect(try counted.count() == processes, "the second read through the link is a hit")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        #expect(try await read().values.contains("filter.evil.clean"))
    }

    /// Listings a fake `git config --show-origin --list` prints, and the error the read must fail with (nil: it
    /// lists `filter.bare` from a key without a value and `diff.d` from the record after it).
    static let listings: [(String, GitInvocation.ReadSafetyError?)] = [
        ("file:.git/config\0filter.bare.required\0file:.git/config\0diff.d.textconv\nx\0", nil),
        ("file:.git/config\0filter.cut.clean\nx", .configListingMalformed),
        ("file:.git/config\0filter.odd.clean\nx\0file:.git/config\0", .configListingMalformed),
    ]

    @Test("the cache reads its config listing as whole records and fails closed on anything else", arguments: listings)
    func cacheListingRecords(listing: String, error: GitInvocation.ReadSafetyError?) async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")
        let output = sandbox.root.appending(path: "listing")
        try Data(listing.utf8).write(to: output)
        let script = sandbox.root.appending(path: "bin/listing-git")
        try Fixtures.writeScript(
            "if [ \"$1\" = config ] && [ \"$3\" = --show-origin ]; then cat '\(output.path)'; exit 0; fi\n"
                + "exec '\(Fixtures.git.path)' \"$@\"", to: script)
        let read = {
            try await GitInvocation.readEnvironment(
                profile: nil, base: sandbox.base, runner: GitRunner(executable: script), cwd: repo,
                cache: ReadEnvironmentCache())
        }
        if let error {
            await #expect(throws: error) { try await read() }
        } else {
            let env = try await read()
            #expect(env.values.contains("filter.bare.clean"))
            #expect(env.values.contains("diff.d.textconv"))
        }
    }

    @Test("a read environment whose config includes a path the cache cannot resolve is never cached")
    func unresolvableIncludeIsNotCached() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let counted = try sandbox.countingRunner()
        let repo = try await sandbox.makeRepo("repo")
        // Git expands `%(prefix)/` to its own install folder; the cache does not resolve it.
        try await sandbox.git(["config", "include.path", "%(prefix)/histq-absent.cfg"], in: repo)
        // Past the 2 s race margin, so only the include keeps it out of the cache.
        try await Task.sleep(for: .milliseconds(2100))
        let cache = ReadEnvironmentCache()
        let read = {
            try await GitInvocation.readEnvironment(
                profile: nil, base: sandbox.base, runner: counted.runner, cwd: repo, cache: cache)
        }
        _ = try await read()
        let processes = try counted.count()
        _ = try await read()
        #expect(try counted.count() > processes, "the second read listed again")
    }

    // MARK: - GitHub token

    /// A made-up token; the tests look for it where it must never be. The hosts are `.invalid`, so no real
    /// credential can ever answer for them.
    static let token = "ghp_HistqFakeToken0123456789"
    static let tokenHost = "git.histq.invalid"
    static let tokenHelperKey = "credential.https://git.histq.invalid.helper"
    static let credential = GitCredential(kind: .github, host: tokenHost, username: "x-access-token", token: token)
    static let credentials = [credential]

    static var tokenProfile: Profile {
        var profile = profile
        profile.setAccount(HostingAccount(kind: .github, host: tokenHost, login: "octo"))
        profile.ssh = .keyFile(path: "/keys/id_ed25519")
        return profile
    }

    /// Whether `env` has any variable that carries a credential (`HISTQ_GIT_TOKEN*`, `HISTQ_GIT_USER_*`).
    static func hasCredentialVariable(_ env: [String: String]) -> Bool {
        env.keys.contains { $0.hasPrefix("HISTQ_GIT_TOKEN") || $0.hasPrefix("HISTQ_GIT_USER_") }
    }

    /// The command-scope config entries of `env`, in order, as `key=value`.
    static func configEntries(_ env: [String: String]) -> [String] {
        (0..<(Int(env["GIT_CONFIG_COUNT"] ?? "") ?? 0)).map {
            "\(env["GIT_CONFIG_KEY_\($0)"] ?? "")=\(env["GIT_CONFIG_VALUE_\($0)"] ?? "")"
        }
    }

    /// A user helper in a temp global config (after a reset, so no system helper runs) that touches
    /// `user-helper-ran` and answers `user`/`user-secret`; returns the base using it and the marker.
    static func baseWithUserHelper(_ sandbox: Sandbox) throws -> (base: [String: String], marker: URL, helper: String) {
        let marker = sandbox.root.appending(path: "user-helper-ran")
        let script = sandbox.root.appending(path: "bin/user-helper.sh")
        try Fixtures.writeScript(
            "touch '\(marker.path)'\nprintf 'username=user\\npassword=user-secret\\n'", to: script)
        let helper = "!'\(script.path)'"
        let global = sandbox.root.appending(path: "home/.gitconfig")
        try Data("[credential]\n\thelper =\n\thelper = \(helper)\n".utf8).write(to: global)
        var base = sandbox.base
        base["GIT_CONFIG_GLOBAL"] = global.path
        return (base, marker, helper)
    }

    @Test("only network environments carry the token, in HISTQ_GIT_TOKEN_0 alone; reads, writes and the terminal never")
    func tokenOnlyInNetworkEnvironments() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")
        let profile = Self.tokenProfile
        let ops = GitOperations(
            runner: sandbox.runner, cwd: repo, profile: profile, base: sandbox.base, credentials: Self.credentials)

        // Stale credential variables in the base (another index, the old single variable) never get through.
        var stale = sandbox.base
        let staleKeys = ["HISTQ_GIT_TOKEN", "HISTQ_GIT_TOKEN_0", "HISTQ_GIT_TOKEN_3", "HISTQ_GIT_USER_0", "HISTQ_GIT_USER_3"]
        for key in staleKeys {
            stale[key] = "stale-value"
        }
        let network = GitInvocation.environment(
            profile: profile, base: stale, access: .network(.fetch), credentials: Self.credentials)
        // The operations hold the token for the gate only: no environment of theirs carries it.
        #expect(ops.networkEnv == ops.env)
        #expect(ops.credential?.credentials == Self.credentials)
        // Compared first, so a failure never prints an environment that holds the token.
        let tokenKeys = network.filter { $0.value.contains(Self.token) }.map(\.key)
        let histqKeys = network.keys.filter { $0.hasPrefix("HISTQ_") }.sorted()
        let username = network["HISTQ_GIT_USER_0"]
        let staleKept = network.values.contains("stale-value")
        let staleWrite = Self.hasCredentialVariable(
            GitInvocation.environment(profile: profile, base: stale, access: .write))
        let networkEntries = Self.configEntries(network)
        #expect(tokenKeys == ["HISTQ_GIT_TOKEN_0"])
        #expect(histqKeys == ["HISTQ_GIT_TOKEN_0", "HISTQ_GIT_USER_0"])
        #expect(username == "x-access-token")
        #expect(!staleKept)
        #expect(!staleWrite)
        #expect(networkEntries.suffix(2) == [
            "\(Self.tokenHelperKey)=", "\(Self.tokenHelperKey)=\(GitInvocation.tokenHelper(0))",
        ])
        let networkKeys = try await sandbox.runner.run(
            ["config", "--name-only", "--get-regexp", "^credential\\."], cwd: repo, env: network).text
        #expect(networkKeys.contains(Self.tokenHelperKey), "positive control: git sees the helper")

        let terminal = GitInvocation.terminalEnvironment(profile: profile)
        #expect(Self.configEntries(terminal).contains("user.email=profile@histq.invalid"))
        #expect(terminal["GIT_SSH_COMMAND"] == "ssh -i '/keys/id_ed25519' -o IdentitiesOnly=yes")
        let others: [(String, [String: String])] = [
            ("write", GitInvocation.environment(
                profile: profile, base: sandbox.base, access: .write, credentials: Self.credentials)),
            ("read", GitInvocation.environment(
                profile: profile, base: sandbox.base, access: .read(filterDrivers: []), credentials: Self.credentials)),
            ("read in repo", try await GitInvocation.readEnvironment(
                profile: profile, base: sandbox.base, runner: sandbox.runner, cwd: repo)),
            ("operations write", ops.env),
            ("operations network", ops.networkEnv),
            ("terminal", terminal),
        ]
        for (name, env) in others {
            let carries = Self.hasCredentialVariable(env)
            let leaked = env.values.contains { $0.contains(Self.token) }
            let helper = Self.configEntries(env).contains { $0.hasPrefix("credential.") }
            #expect(!carries, "\(name)")
            #expect(!leaked, "\(name)")
            #expect(!helper, "\(name)")
            if name != "terminal" {
                // Exit 1: no credential key in any scope.
                let keys = try await sandbox.runner.run(
                    ["config", "--get-regexp", "^credential\\."], cwd: repo, env: env, allowedExitCodes: [0, 1])
                #expect(keys.exitCode == 1, "\(name): \(keys.text)")
            }
        }
    }

    @Test("the terminal's shell gets none of Histq's token, git config list, loader or askpass variables")
    func terminalProcessEnvironmentDropsHistqVariables() {
        // What Histq's own process could carry: a token, a command-scope config list (with a stale higher index the
        // profile's shorter list would not overwrite), a loader injection and the askpass programs of its git runs.
        let base = [
            "HOME": "/Users/someone", "PATH": "/usr/bin:/bin", "LANG": "fr_FR.UTF-8", "TERM": "dumb",
            "HISTQ_GIT_TOKEN": Self.token, "HISTQ_GIT_TOKEN_0": Self.token, "HISTQ_GIT_USER_0": "x-access-token",
            "HISTQ_OTHER": "histq",
            "GIT_CONFIG_COUNT": "41", "GIT_CONFIG_KEY_0": "core.fsmonitor", "GIT_CONFIG_VALUE_0": "/tmp/evil",
            "GIT_CONFIG_KEY_40": "core.pager", "GIT_CONFIG_VALUE_40": "/tmp/evil-pager",
            "GIT_CONFIG_PARAMETERS": "'alias.st'='!/tmp/evil'",
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib",
            "GIT_ASKPASS": "/usr/bin/false", "SSH_ASKPASS": "/usr/bin/false",
        ]
        let dropped = ["HISTQ_GIT_TOKEN", "HISTQ_GIT_TOKEN_0", "HISTQ_GIT_USER_0", "HISTQ_OTHER", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_KEY_40",
                       "GIT_CONFIG_VALUE_40", "DYLD_INSERT_LIBRARIES", "GIT_ASKPASS", "SSH_ASKPASS"]
        let profile = Self.tokenProfile

        let env = GitInvocation.terminalProcessEnvironment(base: base, profile: profile)
        for key in dropped { #expect(env[key] == nil, "\(key)") }
        #expect(!env.values.contains { $0.contains("evil") || $0.contains(Self.token) })
        // The config list is the profile's alone, from 0.
        #expect(Self.configEntries(env) == Self.configEntries(GitInvocation.terminalEnvironment(profile: profile)))
        #expect(Self.configEntries(env).contains("user.name=Profile Person"))
        #expect(Self.configEntries(env).contains("user.email=profile@histq.invalid"))
        #expect(!Self.configEntries(env).contains { $0.hasPrefix("credential.") })
        #expect(env["GIT_SSH_COMMAND"] == "ssh -i '/keys/id_ed25519' -o IdentitiesOnly=yes")
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["COLORTERM"] == "truecolor")
        // The user's own variables stay.
        #expect(env["HOME"] == "/Users/someone")
        #expect(env["PATH"] == "/usr/bin:/bin")
        #expect(env["LANG"] == "fr_FR.UTF-8")

        // Without a profile no config list at all: nothing of the base's survives.
        let plain = GitInvocation.terminalProcessEnvironment(base: base, profile: nil)
        #expect(plain.keys.filter { $0.hasPrefix("GIT_CONFIG_") || $0.hasPrefix("HISTQ_") }.isEmpty)
        for key in dropped { #expect(plain[key] == nil, "\(key)") }
        #expect(plain["TERM"] == "xterm-256color")
        #expect(plain["COLORTERM"] == "truecolor")
        #expect(!(plain["LANG"] ?? "").isEmpty)
        #expect(!(GitInvocation.terminalProcessEnvironment(base: [:], profile: nil)["LANG"] ?? "").isEmpty)
    }

    /// The network side (fetch, pull and push hooks, with and without the token) is in NetworkTokenTests.
    @Test("a commit's hooks never see the token")
    func commitHooksDoNotSeeToken() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")
        let dumps = sandbox.root.appending(path: "dumps", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dumps, withIntermediateDirectories: true)
        for hook in ["pre-commit", "commit-msg", "post-commit"] {
            try Fixtures.writeScript("env > '\(dumps.appending(path: hook).path)'", to: repo.appending(path: ".git/hooks/\(hook)"))
        }
        let ops = GitOperations(
            runner: sandbox.runner, cwd: repo, profile: Self.tokenProfile, base: sandbox.base,
            credentials: Self.credentials)

        try Data("changed\n".utf8).write(to: repo.appending(path: "tracked.txt"))
        try await ops.stage(["tracked.txt"])
        try await ops.commit(message: "change")

        for hook in ["pre-commit", "commit-msg", "post-commit"] {
            let dump = try String(contentsOf: dumps.appending(path: hook), encoding: .utf8)
            #expect(dump.contains("GIT_CONFIG_COUNT="), "the \(hook) hook ran")
            let saw = dump.contains("HISTQ_GIT_TOKEN") || dump.contains("HISTQ_GIT_USER_") || dump.contains(Self.token)
            #expect(!saw, "\(hook) saw the token")
        }
    }

    @Test("git credential fill gives the token for the profile's host only, runs no other helper, and the token is in no argument")
    func credentialFillIsScopedToTheHost() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let (base, userMarker, _) = try Self.baseWithUserHelper(sandbox)
        let trace = sandbox.root.appending(path: "trace.txt")
        var env = GitInvocation.environment(
            profile: Self.tokenProfile, base: base, access: .network(.fetch), credentials: Self.credentials)
        // GIT_TRACE logs the argv of every command git runs, the helper's shell included.
        env["GIT_TRACE"] = trace.path
        let fill = ["credential", "fill"]

        let mine = try await sandbox.runner.run(
            fill, cwd: sandbox.root, env: env, stdin: Data("protocol=https\nhost=\(Self.tokenHost)\n\n".utf8),
            timeout: .seconds(30))
        #expect(mine.text.contains("username=x-access-token\n"))
        let filled = mine.text.contains("password=\(Self.token)\n")
        #expect(filled, "git credential fill did not give the token")
        #expect(!FileManager.default.fileExists(atPath: userMarker.path), "the user's helper ran for the profile's host")
        let traced = try String(contentsOf: trace, encoding: .utf8)
        #expect(traced.contains("run_command"), "positive control: the trace lists the helper's command")
        let traceHasToken = traced.contains(Self.token)
        #expect(!traceHasToken, "the token is in an argument")

        let other = try await sandbox.runner.run(
            fill, cwd: sandbox.root, env: env, stdin: Data("protocol=https\nhost=other.histq.invalid\n\n".utf8),
            timeout: .seconds(30), allowedExitCodes: Set(0...255))
        let otherHasToken = other.text.contains(Self.token) || other.stderrTail.contains(Self.token)
        #expect(!otherHasToken, "another host got the token")
        // A token-carrying command resets every helper: the user's own would run with HISTQ_GIT_TOKEN in its
        // environment (another host is only reached after a redirect; the gate let no other URL through).
        #expect(!other.text.contains("password="), "a helper answered for another host")
        #expect(!FileManager.default.fileExists(atPath: userMarker.path), "the user's helper ran")
    }

    @Test("a GitLab credential's helper answers the username it was given (oauth2) with its token")
    func gitLabCredentialAnswersOAuth2() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let credential = GitCredential(kind: .gitlab, host: Self.tokenHost, username: "oauth2", token: Self.token)
        let env = GitInvocation.environment(
            profile: Self.tokenProfile, base: sandbox.base, access: .network(.fetch), credentials: [credential])
        #expect(env["HISTQ_GIT_USER_0"] == "oauth2")
        let fill = try await sandbox.runner.run(
            ["credential", "fill"], cwd: sandbox.root, env: env,
            stdin: Data("protocol=https\nhost=\(Self.tokenHost)\n\n".utf8), timeout: .seconds(30))
        let answered = fill.text == "protocol=https\nhost=\(Self.tokenHost)\nusername=oauth2\npassword=\(Self.token)\n"
        #expect(answered, "the helper did not answer username=oauth2 with the token")
    }

    @Test(
        "a host that could widen or bend the config key, or a token that could break the helper, adds nothing",
        arguments: [
            ("*.histq.invalid", token), ("histq.invalid/x", token), ("user@histq.invalid", token),
            ("histq .invalid", token), ("histq.invalid\n", token), (tokenHost, "two words"),
            (tokenHost, "tok\nhost=evil.invalid"), (tokenHost, #"tok\nhost=evil.invalid"#), (tokenHost, ""),
        ])
    func unsafeHostOrTokenAddsNothing(host: String, token: String) {
        let credential = GitCredential(kind: .github, host: host, username: "x-access-token", token: token)
        let env = GitInvocation.environment(
            profile: Self.tokenProfile, base: [:], access: .network(.fetch), credentials: [credential])
        let carries = Self.hasCredentialVariable(env)
        let helper = Self.configEntries(env).contains { $0.hasPrefix("credential.") }
        #expect(!carries)
        #expect(!helper)
    }

    @Test("a credential's description, debug description and dump never show its token")
    func credentialDescriptionRedactsToken() {
        var dumped = ""
        dump(Self.credential, to: &dumped)
        let decision = GitInvocation.TokenDecision.attach(Self.credentials)
        let texts = [String(describing: Self.credential), String(reflecting: Self.credential), dumped,
                     String(describing: decision), String(reflecting: decision)]
        let leaked = texts.contains { $0.contains(Self.token) }
        let hostShown = texts.allSatisfy { $0.contains(Self.tokenHost) }
        #expect(!leaked, "a description shows the token")
        #expect(hostShown, "positive control: the descriptions show the credential")
    }

    @Test("the background fetch adds the token helper after its reset and the user's replayed helpers")
    func backgroundFetchCarriesTokenHelperLast() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let (base, _, userHelper) = try Self.baseWithUserHelper(sandbox)
        let repo = try await sandbox.makeRepo("repo")
        try await sandbox.git(["remote", "add", "origin", "https://\(Self.tokenHost)/octo/repo.git"], in: repo)
        // As `GitOperations.backgroundFetchAll` lists them and gives them to a remote the gate let through.
        let helpers = try await GitInvocation.credentialHelpers(
            runner: sandbox.runner, cwd: repo,
            env: GitInvocation.environment(profile: nil, base: base, access: .read(filterDrivers: [])))
        let access = GitInvocation.Access.backgroundFetch(credentialHelpers: helpers)
        let decision = await GitInvocation.networkToken(
            for: .fetch(remotes: ["origin"]), credentials: Self.credentials, base: base, runner: sandbox.runner,
            cwd: repo)
        #expect(decision == .attach(Self.credentials))

        let env = GitInvocation.environment(
            profile: Self.tokenProfile, base: base, access: access, credentials: Self.credentials)
        let entries = Self.configEntries(env)
        let reset = try #require(entries.lastIndex(of: "credential.helper="))
        let replayed = try #require(entries.lastIndex(of: "credential.helper=\(userHelper)"))
        #expect(reset < replayed)
        #expect(entries.suffix(2) == [
            "\(Self.tokenHelperKey)=", "\(Self.tokenHelperKey)=\(GitInvocation.tokenHelper(0))",
        ])
        let carries = env["HISTQ_GIT_TOKEN_0"] == Self.token
        #expect(carries, "the background fetch does not carry the token")
        #expect(env["GIT_ALLOW_PROTOCOL"] == "https")
        let filled = try await sandbox.runner.run(
            ["credential", "fill"], cwd: repo, env: env,
            stdin: Data("protocol=https\nhost=\(Self.tokenHost)\n\n".utf8), timeout: .seconds(30))
        let gaveToken = filled.text.contains("password=\(Self.token)\n")
        #expect(gaveToken, "git credential fill did not give the token")

        let withoutToken = GitInvocation.environment(profile: Self.tokenProfile, base: base, access: access)
        let withoutCarries = Self.hasCredentialVariable(withoutToken)
        #expect(!withoutCarries)
        #expect(!Self.configEntries(withoutToken).contains { $0.hasPrefix(Self.tokenHelperKey) })
        #expect(withoutToken["GIT_ALLOW_PROTOCOL"] == "ssh:https:git")

        // Each remote is gated on its own: origin keeps its token beside a remote on another host, which gets none.
        try await sandbox.git(["remote", "add", "other", "https://other.histq.invalid/octo/repo.git"], in: repo)
        let originDecision = await GitInvocation.networkToken(
            for: .fetch(remotes: ["origin"]), credentials: Self.credentials, base: base, runner: sandbox.runner,
            cwd: repo)
        let otherDecision = await GitInvocation.networkToken(
            for: .fetch(remotes: ["other"]), credentials: Self.credentials, base: base, runner: sandbox.runner,
            cwd: repo)
        #expect(originDecision == .attach(Self.credentials))
        #expect(otherDecision == .otherURL)
    }

    // MARK: - Harness

    typealias Command = @Sendable (Built) -> [String]

    /// For each control, a fresh repo from `build` runs the marker with the plain (write) environment. Then
    /// a fresh repo runs every read, in order, with the read environment (less `withoutVariable`, to test
    /// one guard alone): no marker after any of them, each exits 0 (any code if `readsMayFail`), and
    /// `.git/index` is never rewritten.
    func expectReadsRunNothing(
        controls: [Command], reads: [Command], readsMayFail: Bool = false, withoutVariable: String? = nil,
        build: @Sendable (Sandbox) async throws -> Built
    ) async throws {
        for control in controls {
            let sandbox = try await Sandbox()
            defer { sandbox.remove() }
            let built = try await build(sandbox)
            let args = control(built)
            #expect(!sandbox.markerExists, "the setup itself ran the marker")
            let plain = GitInvocation.environment(profile: Self.profile, base: sandbox.base)
            // A control may fail once its marker script exits 1; only the marker matters.
            _ = try? await sandbox.runner.run(
                args, cwd: built.repo, env: plain, timeout: .seconds(30), allowedExitCodes: Set(0...255))
            #expect(sandbox.markerExists, "positive control: `git \(args.joined(separator: " "))` must run the marker")
        }

        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let built = try await build(sandbox)
        let index = built.repo.appending(path: ".git/index")
        let indexDate = try Sandbox.modificationDate(index)
        var env = try await GitInvocation.readEnvironment(
            profile: Self.profile, base: sandbox.base, runner: sandbox.runner, cwd: built.repo)
        // The cache's own listing (`--show-origin --list`) must find the same drivers.
        let cached = try await GitInvocation.readEnvironment(
            profile: Self.profile, base: sandbox.base, runner: sandbox.runner, cwd: built.repo,
            cache: ReadEnvironmentCache())
        #expect(cached == env, "the cached read environment differs from the listed one")
        if let withoutVariable {
            #expect(env.removeValue(forKey: withoutVariable) != nil, "the read environment sets \(withoutVariable)")
        }
        for read in reads {
            let args = read(built)
            _ = try await sandbox.runner.run(
                args, cwd: built.repo, env: env, timeout: .seconds(30),
                allowedExitCodes: readsMayFail ? Set(0...255) : [0])
            #expect(!sandbox.markerExists, "`git \(args.joined(separator: " "))` ran the marker")
            #expect(try Sandbox.modificationDate(index) == indexDate, "`git \(args.joined(separator: " "))` wrote the index")
        }
    }
}

struct Built: Sendable {
    let repo: URL
    var revs: [String] = []
}

/// A temp folder with its own HOME, hermetic environment and marker script (`evil`, which touches
/// `marker` and exits 1).
struct Sandbox: Sendable {
    let root: URL
    let base: [String: String]
    let runner: GitRunner

    var marker: URL { root.appending(path: "marker") }
    var evil: URL { root.appending(path: "bin/evil.sh") }
    var markerExists: Bool { FileManager.default.fileExists(atPath: marker.path) }

    init() async throws {
        root = try Fixtures.makeTempDirectory("HistqInvocation")
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        base = Fixtures.hermeticEnvironment(home: home)
        runner = GitRunner(executable: Fixtures.git)
        try Fixtures.writeScript("touch '\(marker.path)'\nexit 1", to: root.appending(path: "bin/evil.sh"))
    }

    func remove() { Fixtures.removeTempDirectory(root) }

    /// A runner whose git is a script that logs one line per process to a file before running the real git, and
    /// the number of processes it ran so far.
    func countingRunner() throws -> (runner: GitRunner, count: @Sendable () throws -> Int) {
        let log = root.appending(path: "git-processes.log")
        let script = root.appending(path: "bin/counting-git")
        try Fixtures.writeScript("echo run >> '\(log.path)'\nexec '\(Fixtures.git.path)' \"$@\"", to: script)
        let count: @Sendable () throws -> Int = {
            guard FileManager.default.fileExists(atPath: log.path) else { return 0 }
            return try String(contentsOf: log, encoding: .utf8).split(separator: "\n").count
        }
        return (GitRunner(executable: script), count)
    }

    /// Runs a setup command with the hermetic environment; returns its trimmed stdout.
    @discardableResult
    func git(_ args: [String], in dir: URL, stdin: Data? = nil) async throws -> String {
        let result = try await runner.run(args, cwd: dir, env: base, stdin: stdin, timeout: .seconds(30))
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A repo with a repo-local identity and one commit of `tracked.txt`.
    func makeRepo(_ name: String) async throws -> URL {
        let repo = root.appending(path: name, directoryHint: .isDirectory)
        try await git(["init", "-q", "-b", "main", repo.path], in: root)
        try await git(["config", "user.name", "Repo Local"], in: repo)
        try await git(["config", "user.email", "local@histq.invalid"], in: repo)
        try Data("hello\n".utf8).write(to: repo.appending(path: "tracked.txt"))
        try await git(["add", "tracked.txt"], in: repo)
        try await git(["commit", "-q", "-m", "initial"], in: repo)
        return repo
    }

    /// Clones `source` as the populated submodule `path` of `repo` and commits it; returns its folder.
    func addSubmodule(_ source: URL, as path: String, in repo: URL) async throws -> URL {
        try await git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", source.path, path], in: repo)
        try await git(["commit", "-q", "-m", "add \(path)"], in: repo)
        return repo.appending(path: path, directoryHint: .isDirectory)
    }

    /// Changes the file's mtime but not its content, so git must re-read it to know it is unchanged.
    static func makeStatDirty(_ file: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: file.path)
    }

    static func modificationDate(_ file: URL) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
    }
}
