// Key feature and security tests for the onboarding demo repository: `create` builds the full demo (merge, tag,
// stash, linked worktree, uncommitted changes) even under a hostile global config (signing on, a failing pre-commit
// hook, another default branch), and `remove` deletes a real demo base but refuses a folder without the marker or
// one under another parent, leaving it in place.
import Foundation
import HistqCore
import Testing

struct DemoRepositoryTests {
    @Test("create works under a hostile global config and remove deletes the demo base")
    func createUnderHostileConfig() async throws {
        let temp = try Fixtures.makeTempDirectory("HistqDemo")
        defer { Fixtures.removeTempDirectory(temp) }
        let runner = GitRunner(executable: Fixtures.git)
        let home = temp.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let hooks = temp.appending(path: "hooks", directoryHint: .isDirectory)
        try Fixtures.writeScript("exit 1", to: hooks.appending(path: "pre-commit"))
        let hostile = temp.appending(path: "hostile.gitconfig")
        try Data("""
            [commit]
            \tgpgsign = true
            [tag]
            \tgpgsign = true
            [init]
            \tdefaultBranch = trunk
            [core]
            \thooksPath = \(hooks.path(percentEncoded: false))

            """.utf8).write(to: hostile)
        let baseEnv = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home.path(percentEncoded: false),
            "GIT_CONFIG_GLOBAL": hostile.path(percentEncoded: false),
        ]
        // The hostile file is really read by git under that env.
        let signing = try await runner.run(["config", "--get", "commit.gpgsign"], cwd: temp, env: baseEnv).text
        #expect(signing.trimmingCharacters(in: .whitespacesAndNewlines) == "true")

        let parent = temp.appending(path: "onboarding", directoryHint: .isDirectory)
        let repo = try await DemoRepository.create(in: parent, runner: runner, baseEnv: baseEnv)
        let base = repo.deletingLastPathComponent()
        let readEnv = Fixtures.hermeticEnvironment(home: home)
        func git(_ args: [String]) async throws -> [String] {
            try await runner.run(args, cwd: repo, env: readEnv).text.split(separator: "\n").map(String.init)
        }

        #expect(FileManager.default.fileExists(atPath: base.appending(path: DemoRepository.marker).path))
        #expect(try await git(["rev-parse", "--abbrev-ref", "HEAD"]) == ["main"])
        #expect(try await !git(["rev-list", "--merges", "main"]).isEmpty)
        #expect(try await git(["tag", "-l", "v1.0"]) == ["v1.0"])
        #expect(try await git(["stash", "list"]).count == 1)
        #expect(try await git(["worktree", "list", "--porcelain"]).filter { $0.hasPrefix("worktree ") }.count == 2)
        #expect(try await !git(["status", "--porcelain"]).isEmpty)

        try DemoRepository.remove(base: base, parent: parent)
        #expect(!FileManager.default.fileExists(atPath: base.path))
    }

    @Test("remove refuses a folder without the marker and a marked folder under another parent, and keeps both")
    func removeRefuses() throws {
        let temp = try Fixtures.makeTempDirectory("HistqDemoRemove")
        defer { Fixtures.removeTempDirectory(temp) }
        let fm = FileManager.default
        let parent = temp.appending(path: "onboarding", directoryHint: .isDirectory)

        let unmarked = parent.appending(path: "demo-unmarked", directoryHint: .isDirectory)
        try fm.createDirectory(at: unmarked, withIntermediateDirectories: true)
        let noMarker = #expect(throws: DemoRepository.RemoveError.self) {
            try DemoRepository.remove(base: unmarked, parent: parent)
        }
        guard case .notADemo = noMarker else {
            Issue.record("expected notADemo, got \(String(describing: noMarker))")
            return
        }
        #expect(fm.fileExists(atPath: unmarked.path))

        let elsewhere = temp.appending(path: "other/demo-marked", directoryHint: .isDirectory)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data().write(to: elsewhere.appending(path: DemoRepository.marker))
        let otherParent = #expect(throws: DemoRepository.RemoveError.self) {
            try DemoRepository.remove(base: elsewhere, parent: parent)
        }
        guard case .wrongParent = otherParent else {
            Issue.record("expected wrongParent, got \(String(describing: otherParent))")
            return
        }
        #expect(fm.fileExists(atPath: elsewhere.appending(path: DemoRepository.marker).path))
    }
}
