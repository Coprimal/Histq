// SubmoduleReader: a submodule's state is read in its own folder with its own read environment (so its
// own filters stay off), and a pointer change counts the commits between the two commits.
import Foundation
import HistqCore
import Testing

struct SubmoduleTests {
    /// A superproject `super` with the populated submodule `sub` whose own config names the marker as the
    /// clean filter of every file, with `tracked.txt` stat-dirty and one untracked file.
    static func filterFixture(_ sandbox: Sandbox) async throws -> (repo: URL, sub: URL) {
        let source = try await sandbox.makeRepo("sub-source")
        try Data("* filter=evil\n".utf8).write(to: source.appending(path: ".gitattributes"))
        try await sandbox.git(["add", ".gitattributes"], in: source)
        try await sandbox.git(["commit", "-q", "-m", "attributes"], in: source)
        let repo = try await sandbox.makeRepo("super")
        let sub = try await sandbox.addSubmodule(source, as: "sub", in: repo)
        try await sandbox.git(["config", "filter.evil.clean", sandbox.evil.path], in: sub)
        try Sandbox.makeStatDirty(sub.appending(path: "tracked.txt"))
        try Data("new\n".utf8).write(to: sub.appending(path: "untracked.txt"))
        return (repo, sub)
    }

    @Test("A submodule's status is read without running its own clean filter")
    func submoduleFilterDoesNotRun() async throws {
        // Positive control: a plain status in the submodule does run the marker.
        let control = try await Sandbox()
        defer { control.remove() }
        let built = try await Self.filterFixture(control)
        #expect(!control.markerExists, "the setup itself ran the marker")
        let plain = GitInvocation.environment(profile: nil, base: control.base)
        _ = try? await control.runner.run(["status"], cwd: built.sub, env: plain, allowedExitCodes: Set(0...255))
        #expect(control.markerExists, "positive control: `git status` in the submodule must run the marker")

        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let (repo, sub) = try await Self.filterFixture(sandbox)
        let list = try await SubmoduleReader.list(runner: sandbox.runner, cwd: repo, base: sandbox.base)
        #expect(!sandbox.markerExists, "listing the submodules ran the submodule's clean filter")
        let head = try await sandbox.git(["rev-parse", "HEAD"], in: sub)
        #expect(list.count == 1)
        #expect(list.first?.path == "sub")
        #expect(list.first?.state == .checkedOut(head: head, branch: "main"))
        #expect(list.first?.changeCount == 1, "the untracked file, read by the submodule's status")
        #expect(list.first?.isMoved == false)

        // No .gitmodules: no git call at all (a runner that cannot launch would throw).
        let noGit = GitRunner(executable: URL(filePath: "/nonexistent/git"))
        #expect(try await SubmoduleReader.list(runner: noGit, cwd: sub, base: sandbox.base).isEmpty)
        #expect(try await SubmoduleReader.recorded(runner: noGit, cwd: sub, base: sandbox.base, revision: "HEAD")
            .isEmpty)
    }

    @Test("A pointer change counts the commits between, and a new submodule has no old commit")
    func pointerChange() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let source = try await sandbox.makeRepo("sub-source")
        let repo = try await sandbox.makeRepo("super")
        let sub = try await sandbox.addSubmodule(source, as: "libs/sub", in: repo)
        let old = try await sandbox.git(["rev-parse", "HEAD"], in: sub)
        try await sandbox.git(["config", "user.name", "Sub Author"], in: sub)
        try await sandbox.git(["config", "user.email", "sub@histq.invalid"], in: sub)
        for subject in ["second", "third"] {
            try Data("\(subject)\n".utf8).write(to: sub.appending(path: "tracked.txt"))
            try await sandbox.git(["commit", "-q", "-a", "-m", subject], in: sub)
        }
        let new = try await sandbox.git(["rev-parse", "HEAD"], in: sub)

        // Moved but not committed in the parent: the index still records the old commit.
        let moved = try await SubmoduleReader.list(runner: sandbox.runner, cwd: repo, base: sandbox.base)
        #expect(moved.first?.recordedCommit == old)
        #expect(moved.first?.isMoved == true)

        let change = try await SubmoduleReader.change(
            runner: sandbox.runner, in: sub, base: sandbox.base, from: old, to: new)
        #expect(change.available)
        #expect(change.ahead == 2 && change.behind == 0)
        #expect(change.commits.map(\.subject) == ["third", "second"])
        #expect(change.commits.allSatisfy { $0.isNew && $0.author == "Sub Author" })
        #expect(change.commits.first?.refs.contains("HEAD -> main") == true)

        let back = try await SubmoduleReader.change(
            runner: sandbox.runner, in: sub, base: sandbox.base, from: new, to: old)
        #expect(back.ahead == 0 && back.behind == 2 && back.commits.allSatisfy { !$0.isNew })

        let added = try await SubmoduleReader.change(
            runner: sandbox.runner, in: sub, base: sandbox.base, from: nil, to: old)
        #expect(added.from == nil && added.available)
        #expect(added.ahead == 1 && added.behind == 0 && added.commits.map(\.subject) == ["initial"])

        let missing = String(repeating: "1", count: 40)
        let unknown = try await SubmoduleReader.change(
            runner: sandbox.runner, in: sub, base: sandbox.base, from: missing, to: new)
        #expect(!unknown.available && unknown.commits.isEmpty)

        // The parent records the bump; each revision has its own pointer.
        try await sandbox.git(["commit", "-q", "-a", "-m", "bump sub"], in: repo)
        let before = try await SubmoduleReader.recorded(
            runner: sandbox.runner, cwd: repo, base: sandbox.base, revision: "HEAD~1")
        let after = try await SubmoduleReader.recorded(
            runner: sandbox.runner, cwd: repo, base: sandbox.base, revision: "HEAD")
        #expect(before == ["libs/sub": old] && after == ["libs/sub": new])

        // A plain clone has the gitlink but no submodule.<name>.url; `submodule init` adds it.
        let clone = sandbox.root.appending(path: "clone", directoryHint: .isDirectory)
        try await sandbox.git(["clone", "-q", repo.path, clone.path], in: sandbox.root)
        let fresh = try await SubmoduleReader.list(runner: sandbox.runner, cwd: clone, base: sandbox.base)
        #expect(fresh.map(\.state) == [.notInitialized])
        #expect(fresh.first?.recordedCommit == new && fresh.first?.url == source.path)
        try await sandbox.git(["submodule", "init", "-q"], in: clone)
        let initialized = try await SubmoduleReader.list(runner: sandbox.runner, cwd: clone, base: sandbox.base)
        #expect(initialized.map(\.state) == [.notCheckedOut])
        // An empty `.git` folder is no checkout: git must not walk up and read the parent as the submodule.
        try FileManager.default.createDirectory(
            at: clone.appending(path: "libs/sub/.git"), withIntermediateDirectories: true)
        let empty = try await SubmoduleReader.list(runner: sandbox.runner, cwd: clone, base: sandbox.base)
        #expect(empty.map(\.state) == [.notCheckedOut])
    }

    @Test("The commits read by sha come back in the order given, without the ones the submodule lacks")
    func commitsBySha() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let source = try await sandbox.makeRepo("sub-source")
        let repo = try await sandbox.makeRepo("super")
        let sub = try await sandbox.addSubmodule(source, as: "sub", in: repo)
        let old = try await sandbox.git(["rev-parse", "HEAD"], in: sub)
        try await sandbox.git(["config", "user.name", "Sub Author"], in: sub)
        try await sandbox.git(["config", "user.email", "sub@histq.invalid"], in: sub)
        try Data("second\n".utf8).write(to: sub.appending(path: "tracked.txt"))
        try await sandbox.git(["commit", "-q", "-a", "-m", "second"], in: sub)
        let new = try await sandbox.git(["rev-parse", "HEAD"], in: sub)
        let newTime = try #require(TimeInterval(try await sandbox.git(["log", "-1", "--format=%at", new], in: sub)))

        // Oldest first, unlike git's date order, with a full sha the submodule lacks in between.
        let missing = String(repeating: "1", count: 40)
        let commits = try await SubmoduleReader.commits(
            runner: sandbox.runner, in: sub, base: sandbox.base, shas: [old, missing, new])
        #expect(commits.map(\.sha) == [old, new])
        #expect(commits.map(\.subject) == ["initial", "second"])
        #expect(commits.last?.author == "Sub Author")
        #expect(commits.last?.date == Date(timeIntervalSince1970: newTime))
        #expect(commits.allSatisfy { $0.refs.isEmpty })

        // A name that is not a full hash reads nothing.
        #expect(try await SubmoduleReader.commits(
            runner: sandbox.runner, in: sub, base: sandbox.base, shas: [old, "HEAD"]).isEmpty)
        #expect(try await SubmoduleReader.commits(
            runner: sandbox.runner, in: sub, base: sandbox.base, shas: [String(old.prefix(12))]).isEmpty)
    }

    // MARK: - Writes

    @Test("Submodule URLs and paths are checked before git sees them")
    func validation() {
        let urls: [(String, Bool)] = [
            ("https://github.com/octo/lib.git", true),
            ("ssh://git@github.com/octo/lib.git", true),
            ("git@github.com:octo/lib.git", true),
            ("github.com:octo/lib", true),
            ("./lib", true),
            ("../lib.git", true),
            ("", false),
            ("-oProxyCommand=touch% /tmp/x", false),
            ("https://github.com/octo/lib\n", false),
            ("https://git\u{1}hub.com/octo/lib", false),
            ("ext::sh -c touch% /tmp/x", false),
            ("fd::3", false),
            ("::lib", false),
            ("file:///tmp/lib", false),
            ("/tmp/lib", false),
            ("~/lib", false),
            ("http://github.com/octo/lib", false),
            ("git://github.com/octo/lib", false),
            ("ftp://github.com/octo/lib", false),
            ("lib", false),
            ("dir/lib:x", false),
            ("git@-oProxyCommand=x:lib", false),
            ("git@:lib", false),
        ]
        for (url, valid) in urls {
            #expect(((try? GitOperations.validateSubmoduleURL(url)) != nil) == valid, "URL \(url.debugDescription)")
        }
        #expect(throws: SubmoduleOperationError.invalidURL("ext::sh")) { try GitOperations.validateSubmoduleURL("ext::sh") }

        let paths: [(String, Bool)] = [
            ("lib", true),
            ("libs/sub", true),
            ("libs/a.git", true),
            (":(glob)*", true),
            ("", false),
            ("/tmp/lib", false),
            ("-lib", false),
            (".", false),
            ("a/./b", false),
            ("..", false),
            ("../lib", false),
            ("libs/..", false),
            (".git", false),
            (".git/modules/x", false),
            ("libs/.GIT/x", false),
            ("a//b", false),
            ("lib/", false),
            ("li\nb", false),
            ("li\tb", false),
        ]
        for (path, valid) in paths {
            #expect(((try? GitOperations.validateSubmodulePath(path)) != nil) == valid, "path \(path.debugDescription)")
        }
        #expect(throws: SubmoduleOperationError.invalidPath("../lib")) { try GitOperations.validateSubmodulePath("../lib") }
    }

    @Test("Remove deletes a submodule completely")
    func remove() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let source = try await sandbox.makeRepo("sub-source")
        let repo = try await sandbox.makeRepo("super")
        // Named apart from its path.
        for (name, path) in [("mod", "lib"), ("ev", "ev")] {
            try await sandbox.git(
                ["-c", "protocol.file.allow=always", "submodule", "add", "-q", "--name", name, "--", source.path, path],
                in: repo)
        }
        try await sandbox.git(["commit", "-q", "-m", "add lib and ev"], in: repo)
        let ops = GitOperations(
            runner: sandbox.runner, cwd: repo, env: GitInvocation.environment(profile: nil, base: sandbox.base))
        let gitDir = repo.appending(path: ".git", directoryHint: .isDirectory)
        let modules = gitDir.appending(path: "modules/mod")
        #expect(try GitOperations.modulesFolder(name: "mod", gitDir: gitDir).standardizedFileURL.path
            == modules.standardizedFileURL.path)

        // Local changes: refused without force, nothing removed.
        try Data("edit\n".utf8).write(to: repo.appending(path: "lib/tracked.txt"))
        await #expect(throws: GitError.self) { try await ops.removeSubmodule("lib", force: false) }
        #expect(try await sandbox.git(["ls-files", "-s", "--", "lib"], in: repo).hasPrefix("160000 "))
        #expect(FileManager.default.fileExists(atPath: modules.path))

        try await ops.removeSubmodule("lib", force: true)
        let lookup = { (args: [String]) async throws -> String in
            try await sandbox.runner.run(args, cwd: repo, env: sandbox.base, allowedExitCodes: [0, 1]).text
        }
        #expect(try await lookup(["ls-files", "-s", "--", "lib"]).isEmpty, "gitlink")
        #expect(try await lookup(["config", "-f", ".gitmodules", "--get-regexp", #"^submodule\.mod\."#]).isEmpty)
        #expect(try await lookup(["config", "--get-regexp", #"^submodule\.mod\."#]).isEmpty, "config section")
        #expect(!FileManager.default.fileExists(atPath: modules.path), ".git/modules/mod")
        #expect(!FileManager.default.fileExists(atPath: repo.appending(path: "lib").path))
        let staged = try await sandbox.git(["diff", "--cached", "--name-status"], in: repo)
        #expect(staged == "M\t.gitmodules\nD\tlib", "the removal stays staged")

        // `modulesFolder` keeps to `<git dir>/modules/`.
        for name in ["../x", "a/../../x", "/tmp/x", ""] {
            #expect(throws: SubmoduleOperationError.invalidName(name)) {
                try GitOperations.modulesFolder(name: name, gitDir: gitDir)
            }
        }
        // A modules folder symlinked out of the git folder: refused before git runs, the target left alone.
        let outside = sandbox.root.appending(path: "outside-ev", directoryHint: .isDirectory)
        let evModules = gitDir.appending(path: "modules/ev")
        try FileManager.default.moveItem(at: evModules, to: outside)
        try FileManager.default.createSymbolicLink(at: evModules, withDestinationURL: outside)
        #expect(throws: SubmoduleOperationError.invalidName("ev")) {
            try GitOperations.modulesFolder(name: "ev", gitDir: gitDir)
        }
        await #expect(throws: SubmoduleOperationError.invalidName("ev")) {
            try await ops.removeSubmodule("ev", force: true)
        }
        #expect(FileManager.default.fileExists(atPath: outside.appending(path: "HEAD").path))
        #expect(try await sandbox.git(["ls-files", "-s", "--", "ev"], in: repo).hasPrefix("160000 "))
    }

    @Test("A submodule update fetches with the token and checks out without it")
    func updateTokenHygiene() async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let lib = try await box.sandbox.makeRepo("lib")
        let old = try await box.sandbox.git(["rev-parse", "HEAD"], in: lib)
        let parent = try await box.sandbox.makeRepo("parent")
        try await box.sandbox.git(["config", "-f", ".gitmodules", "submodule.mod.path", "lib"], in: parent)
        try await box.sandbox.git(["config", "-f", ".gitmodules", "submodule.mod.url", box.url(lib)], in: parent)
        try await box.sandbox.git(["update-index", "--add", "--cacheinfo", "160000,\(old),lib"], in: parent)
        try await box.sandbox.git(["add", ".gitmodules"], in: parent)
        try await box.sandbox.git(["commit", "-q", "-m", "add lib"], in: parent)
        let ops = box.operations(naive: false, in: parent)
        let checkout = parent.appending(path: "lib", directoryHint: .isDirectory)

        // Not cloned yet: the clone is the network step and gets the token.
        #expect(try await ops.updateSubmodules(["lib"], initialize: true, recursive: false).isEmpty)
        #expect(box.transportGotToken)
        #expect(try await box.sandbox.git(["rev-parse", "HEAD"], in: checkout) == old)

        // The submodule's own config runs a marker as the smudge filter of every file (`smudge.ran`, and
        // `smudge.token` when it sees a credential variable or a token, `TokenSandbox.sawCredential`); it passes the
        // content through.
        let smudge = box.sandbox.root.appending(path: "bin/smudge.sh")
        let marker = box.sandbox.root.appending(path: "smudge").path
        try Fixtures.writeScript(
            "touch '\(marker).ran'\n\(TokenSandbox.sawCredential) && touch '\(marker).token'\ncat", to: smudge)
        try await box.sandbox.git(["config", "filter.evil.smudge", smudge.path], in: checkout)
        try Data("* filter=evil\n".utf8).write(to: parent.appending(path: ".git/modules/mod/info/attributes"))
        // A new commit that changes the file, recorded in the parent and not fetched yet.
        try Data("two\n".utf8).write(to: lib.appending(path: "tracked.txt"))
        try await box.sandbox.git(["commit", "-q", "-a", "-m", "two"], in: lib)
        let new = try await box.sandbox.git(["rev-parse", "HEAD"], in: lib)
        try await box.sandbox.git(["update-index", "--cacheinfo", "160000,\(new),lib"], in: parent)
        try await box.sandbox.git(["commit", "-q", "-m", "bump lib"], in: parent)
        try box.clearTransport()

        #expect(try await ops.updateSubmodules(["lib"], initialize: false, recursive: false).isEmpty)
        #expect(box.transportGotToken, "the fetch gets the token")
        #expect(try await box.sandbox.git(["rev-parse", "HEAD"], in: checkout) == new)
        #expect(box.ran("smudge"), "the checkout ran the submodule's filter")
        #expect(!box.sawToken("smudge"), "the submodule's filter saw the token")

        // A git folder a deinit left in `.git/modules` is reused with its config: its checkout runs without the token.
        try await box.sandbox.git(["submodule", "deinit", "-q", "-f", "--", "lib"], in: parent)
        try FileManager.default.removeItem(atPath: marker + ".ran")
        #expect(try await ops.updateSubmodules(["lib"], initialize: false, recursive: false).isEmpty)
        #expect(!box.ran("smudge"), "not initialized: left alone")
        #expect(try await ops.updateSubmodules(["lib"], initialize: true, recursive: false).isEmpty)
        #expect(try await box.sandbox.git(["rev-parse", "HEAD"], in: checkout) == new)
        #expect(box.ran("smudge") && !box.sawToken("smudge"))

        // Positive control: a plain `submodule update` in the token's environment hands the token to that filter.
        try await box.sandbox.git(["checkout", "-q", "--detach", old], in: checkout)
        for marker in ["smudge.ran", "smudge.token"] {
            try? FileManager.default.removeItem(at: box.sandbox.root.appending(path: marker))
        }
        try await box.sandbox.git(
            ["submodule", "update", "--checkout", "--", "lib"], in: parent, env: box.naiveEnvironment())
        #expect(box.sawToken("smudge"), "positive control: the naive environment must reach the filter")
    }

    @Test("Cloning submodules keeps git's refusal of file:// submodules")
    func cloneSubmodulesRefusesFile() async throws {
        let box = try await TokenSandbox()
        defer { box.remove() }
        let sandbox = box.sandbox
        let local = try await sandbox.makeRepo("local")
        let remote = try await sandbox.makeRepo("remote")
        let parent = try await sandbox.makeRepo("parent")
        // `local` by its path and by `file://`, `remote` over the fake https transport; none checked out.
        for (path, source, url) in [
            ("bypath", local, local.path), ("byfile", local, "file://\(local.path)"), ("https", remote, box.url(remote)),
        ] {
            let head = try await sandbox.git(["rev-parse", "HEAD"], in: source)
            try await sandbox.git(["config", "-f", ".gitmodules", "submodule.\(path).path", path], in: parent)
            try await sandbox.git(["config", "-f", ".gitmodules", "submodule.\(path).url", url], in: parent)
            try await sandbox.git(["update-index", "--add", "--cacheinfo", "160000,\(head),\(path)"], in: parent)
        }
        try await sandbox.git(["add", ".gitmodules"], in: parent)
        try await sandbox.git(["commit", "-q", "-m", "add submodules"], in: parent)
        let clone = sandbox.root.appending(path: "clone", directoryHint: .isDirectory)
        try await sandbox.git(["clone", "-q", parent.path, clone.path], in: sandbox.root)

        // The production environment: no `protocol.file.allow`.
        await #expect {
            try await GitOperations.cloneSubmodules(
                in: clone, runner: sandbox.runner, profile: NetworkTokenTests.profile, base: box.base,
                credentials: NetworkTokenTests.credentials) { _ in }
        } throws: { error in
            guard let failure = error as? SubmoduleUpdateFailure else { return false }
            return failure.failures.map(\.path).sorted() == ["byfile", "bypath"]
                && failure.failures.allSatisfy { $0.message.contains("transport 'file' not allowed") }
        }
        for path in ["bypath", "byfile"] {
            #expect(!FileManager.default.fileExists(atPath: clone.appending(path: "\(path)/.git").path), "\(path)")
        }
        #expect(box.transportGotToken, "the https submodule is cloned with the token")
        #expect(try await sandbox.git(["rev-parse", "HEAD"], in: clone.appending(path: "https"))
            == sandbox.git(["rev-parse", "HEAD"], in: remote))
    }

    @Test("Add leaves a new submodule detached, and update skips a mode other than checkout")
    func addAndSkip() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let inner = try await sandbox.makeRepo("inner")
        let source = try await sandbox.makeRepo("sub-source")
        _ = try await sandbox.addSubmodule(inner, as: "inner", in: source)
        let repo = try await sandbox.makeRepo("super")
        let ops = GitOperations(runner: sandbox.runner, cwd: repo, env: Self.fileEnvironment(sandbox))
        let sub = repo.appending(path: "libs/sub", directoryHint: .isDirectory)
        let head = { (folder: URL) async throws -> String in try await sandbox.git(["rev-parse", "HEAD"], in: folder) }

        await #expect(throws: SubmoduleOperationError.invalidURL(source.path)) {
            try await ops.addSubmodule(url: source.path, path: "libs/sub", branch: nil, recursive: true)
        }
        try await ops.addSubmodule(url: "../sub-source", path: "libs/sub", branch: nil, recursive: true)
        let onBranch = try await sandbox.runner.run(
            ["symbolic-ref", "-q", "HEAD"], cwd: sub, env: sandbox.base, allowedExitCodes: [0, 1])
        #expect(onBranch.exitCode == 1, "detached")
        let recorded = try await head(source)
        #expect(try await head(sub) == recorded)
        #expect(try await sandbox.git(["ls-files", "-s", "--", "libs/sub"], in: repo).hasPrefix("160000 \(recorded)"))
        #expect(try await head(sub.appending(path: "inner")) == head(inner), "its own submodule, one level down")
        try await sandbox.git(["commit", "-q", "-m", "add libs/sub"], in: repo)

        // Moved off the recorded commit; a configured mode other than checkout is skipped and named, never run.
        try await sandbox.git(["checkout", "-q", "--detach", "HEAD~1"], in: sub)
        let moved = try await head(sub)
        for mode in ["rebase", "!\(sandbox.evil.path)"] {
            try await sandbox.git(["config", "submodule.libs/sub.update", mode], in: repo)
            let skipped = try await ops.updateSubmodules([], initialize: false, recursive: true)
            #expect(skipped == [SkippedSubmodule(path: "libs/sub", mode: mode)])
            #expect(try await head(sub) == moved)
        }
        #expect(!sandbox.markerExists)

        // Back to checkout: a path that is no submodule and one whose commit git cannot find fail alone, the other
        // is updated.
        try await sandbox.git(["config", "--unset", "submodule.libs/sub.update"], in: repo)
        try await sandbox.git(["config", "-f", ".gitmodules", "submodule.bad.path", "bad"], in: repo)
        try await sandbox.git(["config", "-f", ".gitmodules", "submodule.bad.url", "../sub-source"], in: repo)
        let missing = String(repeating: "1", count: 40)
        try await sandbox.git(["update-index", "--add", "--cacheinfo", "160000,\(missing),bad"], in: repo)
        await #expect {
            try await ops.updateSubmodules(["nope", "bad", "libs/sub"], initialize: true, recursive: false)
        } throws: { error in
            (error as? SubmoduleUpdateFailure)?.failures.map(\.path) == ["nope", "bad"]
        }
        #expect(try await head(sub) == recorded)

        // Branch and URL.
        try await ops.setSubmoduleBranch("libs/sub", branch: "dev")
        #expect(try await sandbox.git(["config", "-f", ".gitmodules", "submodule.libs/sub.branch"], in: repo) == "dev")
        try await ops.setSubmoduleBranch("libs/sub", branch: "")
        let branch = try await sandbox.runner.run(
            ["config", "-f", ".gitmodules", "submodule.libs/sub.branch"], cwd: repo, env: sandbox.base,
            allowedExitCodes: [0, 1])
        #expect(branch.exitCode == 1)
        await #expect(throws: GitOperationError.invalidBranchName("-x")) {
            try await ops.setSubmoduleBranch("libs/sub", branch: "-x")
        }
        try await ops.setSubmoduleURL("libs/sub", url: "../other")
        let url = try await sandbox.git(["config", "submodule.libs/sub.url"], in: repo)
        #expect(url.hasPrefix("/") && url.hasSuffix("/other"), "synced into the config: \(url)")
        try await ops.syncSubmodules(["libs/sub"])
    }

    @Test("Discard on a moved submodule puts it back on the recorded commit")
    func discardMovedSubmodule() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let source = try await sandbox.makeRepo("sub-source")
        let repo = try await sandbox.makeRepo("super")
        let sub = try await sandbox.addSubmodule(source, as: "libs/sub", in: repo)
        let recorded = try await sandbox.git(["rev-parse", "HEAD"], in: sub)
        let ops = GitOperations(runner: sandbox.runner, cwd: repo, env: Self.fileEnvironment(sandbox))
        let head = { try await sandbox.git(["rev-parse", "HEAD"], in: sub) }
        let status = { try await sandbox.git(["status", "--porcelain"], in: repo) }
        let move = {
            try Data("moved \(UUID())\n".utf8).write(to: sub.appending(path: "tracked.txt"))
            try await sandbox.git(["commit", "-q", "-a", "-m", "moved"], in: sub)
        }

        // The gitlink alone.
        try await move()
        #expect(try await head() != recorded)
        try await ops.discard(["libs/sub"])
        #expect(try await head() == recorded)
        #expect(try await status().isEmpty, "the parent no longer shows the submodule modified")

        // A file and the gitlink in one call: both come back.
        try await move()
        try Data("edited\n".utf8).write(to: repo.appending(path: "tracked.txt"))
        try await ops.discard(["tracked.txt", "libs/sub"])
        #expect(try await head() == recorded)
        #expect(try String(contentsOf: repo.appending(path: "tracked.txt"), encoding: .utf8) == "hello\n")
        #expect(try await status().isEmpty)

        // A configured mode other than checkout does not stop a discard (as `submodule update --checkout`).
        for mode in ["none", "rebase"] {
            try await sandbox.git(["config", "submodule.libs/sub.update", mode], in: repo)
            try await move()
            try await ops.discard(["libs/sub"])
            #expect(try await head() == recorded, "\(mode)")
            #expect(try await status().isEmpty, "\(mode)")
        }
        try await sandbox.git(["config", "--unset", "submodule.libs/sub.update"], in: repo)

        // Checked out but not initialized: a moved one is reported, never a silent success; one only dirty is fine.
        try await sandbox.git(["config", "--unset", "submodule.libs/sub.url"], in: repo)
        try Data("dirty\n".utf8).write(to: sub.appending(path: "untracked.txt"))
        try await ops.discard(["libs/sub"])
        try FileManager.default.removeItem(at: sub.appending(path: "untracked.txt"))
        try await move()
        await #expect {
            try await ops.discard(["libs/sub"])
        } throws: { error in
            (error as? SubmoduleUpdateFailure)?.failures.map(\.path) == ["libs/sub"]
        }
        #expect(try await head() != recorded)

        // Initialized but not checked out: nothing to do, never cloned.
        let clone = sandbox.root.appending(path: "clone", directoryHint: .isDirectory)
        try await sandbox.git(["clone", "-q", repo.path, clone.path], in: sandbox.root)
        try await sandbox.git(["submodule", "init", "-q"], in: clone)
        try await GitOperations(runner: sandbox.runner, cwd: clone, env: Self.fileEnvironment(sandbox))
            .discard(["libs/sub"])
        #expect(!FileManager.default.fileExists(atPath: clone.appending(path: "libs/sub/.git").path))
    }

    @Test("A conflicted gitlink is not read as its merge base, nor updated to it")
    func conflictedGitlink() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let lib = try await sandbox.makeRepo("lib")
        let repo = try await sandbox.makeRepo("super")
        let sub = try await sandbox.addSubmodule(lib, as: "sub", in: repo)
        let base = try await sandbox.git(["rev-parse", "HEAD"], in: sub)
        // Two commits of the submodule that both start at `base`, neither containing the other.
        let commit = { (text: String) async throws -> String in
            try await sandbox.git(["checkout", "-q", "--detach", base], in: sub)
            try Data("\(text)\n".utf8).write(to: sub.appending(path: "tracked.txt"))
            try await sandbox.git(["commit", "-q", "-a", "-m", text], in: sub)
            return try await sandbox.git(["rev-parse", "HEAD"], in: sub)
        }
        let left = try await commit("left")
        let right = try await commit("right")
        try await sandbox.git(["checkout", "-q", "-b", "left"], in: repo)
        try await sandbox.git(["update-index", "--cacheinfo", "160000,\(left),sub"], in: repo)
        try await sandbox.git(["commit", "-q", "-m", "sub to left"], in: repo)
        try await sandbox.git(["checkout", "-q", "main"], in: repo)
        try await sandbox.git(["update-index", "--cacheinfo", "160000,\(right),sub"], in: repo)
        try await sandbox.git(["commit", "-q", "-m", "sub to right"], in: repo)
        // The checkout sits, clean and detached, on the commit HEAD records.
        #expect(try await sandbox.git(["rev-parse", "HEAD"], in: sub) == right)

        let before = try await SubmoduleReader.recorded(
            runner: sandbox.runner, cwd: repo, base: sandbox.base, revision: "HEAD")
        let merge = try await sandbox.runner.run(
            ["merge", "-q", "--no-edit", "left"], cwd: repo, env: sandbox.base, allowedExitCodes: [0, 1])
        #expect(merge.exitCode == 1)
        #expect(try await !sandbox.git(["ls-files", "-u", "--", "sub"], in: repo).isEmpty, "conflicted")

        let listed = try await SubmoduleReader.list(runner: sandbox.runner, cwd: repo, base: sandbox.base)
        #expect(!listed.contains { $0.path == "sub" })
        let ops = GitOperations(runner: sandbox.runner, cwd: repo, env: Self.fileEnvironment(sandbox))
        #expect(try await ops.autoUpdateSubmodules(before: before, base: sandbox.base) == SubmoduleAutoUpdate())
        #expect(try await ops.updateSubmodules([], initialize: false, recursive: true).isEmpty)
        #expect(try await sandbox.git(["rev-parse", "HEAD"], in: sub) == right, "never moved to the merge base")
    }

    @Test("Auto-update moves only clean, detached submodules that sat at the old recorded commit")
    func autoUpdate() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let inner = try await sandbox.makeRepo("inner")
        let innerOld = try await sandbox.git(["rev-parse", "HEAD"], in: inner)
        let lib = try await sandbox.makeRepo("lib")
        let first = try await sandbox.git(["rev-parse", "HEAD"], in: lib)
        _ = try await sandbox.addSubmodule(inner, as: "inner", in: lib)
        let old = try await sandbox.git(["rev-parse", "HEAD"], in: lib)
        let repo = try await sandbox.makeRepo("super")
        let names = ["already", "branch", "broken", "clean", "dirty", "gone", "moved", "none"]
        for name in names { _ = try await sandbox.addSubmodule(lib, as: name, in: repo) }
        // `lib`'s new commit changes a file and records a new commit of `inner`.
        try Data("two\n".utf8).write(to: inner.appending(path: "tracked.txt"))
        try await sandbox.git(["commit", "-q", "-a", "-m", "two"], in: inner)
        let innerNew = try await sandbox.git(["rev-parse", "HEAD"], in: inner)
        try await sandbox.git(["update-index", "--cacheinfo", "160000,\(innerNew),inner"], in: lib)
        try Data("two\n".utf8).write(to: lib.appending(path: "tracked.txt"))
        try await sandbox.git(["add", "tracked.txt"], in: lib)
        try await sandbox.git(["commit", "-q", "-m", "two"], in: lib)
        let new = try await sandbox.git(["rev-parse", "HEAD"], in: lib)

        // One reason per submodule; every one but `branch` is detached.
        let folder = { (name: String) in repo.appending(path: name, directoryHint: .isDirectory) }
        let head = { (name: String) async throws -> String in
            try await sandbox.git(["rev-parse", "HEAD"], in: folder(name))
        }
        for name in names where name != "branch" && name != "gone" {
            try await sandbox.git(["checkout", "-q", "--detach"], in: folder(name))
        }
        try await sandbox.git(["checkout", "-q", "--detach", first], in: folder("moved"))
        // A `.git` git cannot read: not checked out, left out.
        try FileManager.default.removeItem(at: folder("broken").appending(path: ".git"))
        try FileManager.default.createDirectory(
            at: folder("broken").appending(path: ".git"), withIntermediateDirectories: true)
        try Data("new\n".utf8).write(to: folder("dirty").appending(path: "untracked.txt"))
        try await sandbox.git(["submodule", "deinit", "-q", "-f", "--", "gone"], in: repo)
        try await sandbox.git(["config", "submodule.none.update", "none"], in: repo)
        try await sandbox.git(["fetch", "-q", "origin"], in: folder("already"))
        try await sandbox.git(["checkout", "-q", "--detach", new], in: folder("already"))
        try await sandbox.git(
            ["-c", "protocol.file.allow=always", "submodule", "update", "--init", "-q"], in: folder("clean"))
        #expect(try await sandbox.git(["rev-parse", "HEAD"], in: folder("clean/inner")) == innerOld)

        // The write: every gitlink bumped to `new`.
        let before = try await SubmoduleReader.recorded(
            runner: sandbox.runner, cwd: repo, base: sandbox.base, revision: "HEAD")
        #expect(before == Dictionary(uniqueKeysWithValues: names.map { ($0, old) }))
        for name in names {
            try await sandbox.git(["update-index", "--cacheinfo", "160000,\(new),\(name)"], in: repo)
        }
        try await sandbox.git(["commit", "-q", "-m", "bump"], in: repo)

        let ops = GitOperations(runner: sandbox.runner, cwd: repo, env: Self.fileEnvironment(sandbox))
        let result = try await ops.autoUpdateSubmodules(before: before, base: sandbox.base)
        #expect(result.failed.isEmpty)
        #expect(result.updated == ["clean", "clean/inner"], "one level down too")
        #expect(result.skipped == [
            .init(path: "branch", reason: .onBranch("main")),
            .init(path: "dirty", reason: .dirty),
            .init(path: "moved", reason: .moved),
            .init(path: "none", reason: .updateMode("none")),
        ])
        #expect(try await head("clean") == new)
        #expect(try await sandbox.git(["rev-parse", "HEAD"], in: folder("clean/inner")) == innerNew)
        #expect(try await head("already") == new)
        #expect(try await head("moved") == first)
        for name in ["branch", "dirty", "none"] { #expect(try await head(name) == old, "\(name)") }
        #expect(try await sandbox.git(["symbolic-ref", "--short", "HEAD"], in: folder("branch")) == "main")
        #expect(FileManager.default.fileExists(atPath: folder("dirty").appending(path: "untracked.txt").path))
        #expect(!FileManager.default.fileExists(atPath: folder("gone").appending(path: ".git").path), "never cloned")

        // No .gitmodules: no git call at all (a runner that cannot launch would throw).
        let noGit = GitOperations(runner: GitRunner(executable: URL(filePath: "/nonexistent/git")), cwd: inner, env: [:])
        #expect(try await noGit.autoUpdateSubmodules(before: [:], base: sandbox.base) == SubmoduleAutoUpdate())
    }

    @Test("Undo of a merge that moved a gitlink, then auto-update, puts the submodule back")
    func autoUpdateAfterUndo() async throws {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let lib = try await sandbox.makeRepo("lib")
        let repo = try await sandbox.makeRepo("super")
        let sub = try await sandbox.addSubmodule(lib, as: "sub", in: repo)
        let old = try await sandbox.git(["rev-parse", "HEAD"], in: sub)
        try await sandbox.git(["checkout", "-q", "--detach"], in: sub)
        try Data("two\n".utf8).write(to: lib.appending(path: "tracked.txt"))
        try await sandbox.git(["commit", "-q", "-a", "-m", "two"], in: lib)
        let new = try await sandbox.git(["rev-parse", "HEAD"], in: lib)
        // A branch that bumps the gitlink.
        try await sandbox.git(["checkout", "-q", "-b", "bump"], in: repo)
        try await sandbox.git(["update-index", "--cacheinfo", "160000,\(new),sub"], in: repo)
        try await sandbox.git(["commit", "-q", "-m", "bump sub"], in: repo)
        try await sandbox.git(["checkout", "-q", "main"], in: repo)

        let ops = GitOperations(
            runner: sandbox.runner, cwd: repo, env: Self.fileEnvironment(sandbox),
            journal: UndoJournal(file: sandbox.root.appending(path: "undo.json")))
        let head = { try await sandbox.git(["rev-parse", "HEAD"], in: sub) }
        let snapshot = {
            try await SubmoduleReader.recorded(runner: sandbox.runner, cwd: repo, base: sandbox.base, revision: "HEAD")
        }

        let beforeMerge = try await snapshot()
        try await ops.merge("bump")
        #expect(try await ops.autoUpdateSubmodules(before: beforeMerge, base: sandbox.base)
            == SubmoduleAutoUpdate(updated: ["sub"]))
        #expect(try await head() == new)

        let beforeUndo = try await snapshot()
        #expect(try await ops.undo().kind == .merge)
        #expect(try await sandbox.git(["ls-files", "-s", "--", "sub"], in: repo).hasPrefix("160000 \(old)"))
        #expect(try await ops.autoUpdateSubmodules(before: beforeUndo, base: sandbox.base)
            == SubmoduleAutoUpdate(updated: ["sub"]))
        #expect(try await head() == old)
        #expect(try await sandbox.git(["status", "--porcelain"], in: repo).isEmpty)
    }

    /// The write environment plus `protocol.file.allow=always`: test only, the fixtures' submodules are local folders.
    static func fileEnvironment(_ sandbox: Sandbox) -> [String: String] {
        var env = GitInvocation.environment(profile: nil, base: sandbox.base)
        let index = Int(env["GIT_CONFIG_COUNT"] ?? "") ?? 0
        env["GIT_CONFIG_KEY_\(index)"] = "protocol.file.allow"
        env["GIT_CONFIG_VALUE_\(index)"] = "always"
        env["GIT_CONFIG_COUNT"] = String(index + 1)
        return env
    }
}
