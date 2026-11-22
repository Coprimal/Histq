// Builds the throwaway demo repository the onboarding tour runs on: branches, a merge, a tag, a stash, a
// linked worktree and uncommitted changes, made with git under an isolated config (no global or system
// config, no signing, no hooks), and removes it again only when the folder carries the generator's marker.
import Foundation

public enum DemoRepository {
    /// Why `remove` refused to delete a folder.
    public enum RemoveError: Error, Equatable, Sendable {
        /// No `.histq-demo` marker file (or the folder is not a real directory).
        case notADemo(String)
        /// The folder does not sit directly inside the expected parent.
        case wrongParent(String)
        /// `/` or the home folder.
        case protectedFolder(String)
    }

    /// The marker file at the top of a demo base folder.
    public static let marker = ".histq-demo"
    /// The main repository's folder name inside the base folder.
    public static let repoName = "histq-demo"
    /// The linked worktree's folder name, next to the main repository.
    public static let worktreeName = "histq-demo-fix-typo"

    /// Makes `<parent>/demo-<short id>/` holding the marker, the repository `histq-demo` and its linked worktree,
    /// and returns the repository's URL. On any failure (cancellation included) the half-built folder is removed.
    public static func create(in parent: URL, runner: GitRunner, baseEnv: [String: String]) async throws -> URL {
        let fm = FileManager.default
        let id = UUID().uuidString.prefix(8).lowercased()
        let base = parent.appending(path: "demo-\(id)", directoryHint: .isDirectory)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        do {
            try Data().write(to: base.appending(path: marker))
            let repo = base.appending(path: repoName, directoryHint: .isDirectory)
            var builder = Builder(runner: runner, env: isolatedEnvironment(baseEnv, home: base), repo: repo)
            try await builder.build(base: base)
            return repo
        } catch {
            try? fm.removeItem(at: base)
            throw error
        }
    }

    /// Deletes a demo base folder (and so its worktree registration, since both folders live in it). Refuses
    /// unless `base` is a real directory holding the `.histq-demo` marker as a regular file, sits directly inside
    /// `parent`, and is neither `/` nor the home folder.
    public static func remove(base: URL, parent: URL) throws {
        let fm = FileManager.default
        let folder = normalized(base)
        if folder.pathComponents == ["/"] || isHome(folder) {
            throw RemoveError.protectedFolder(folder.path(percentEncoded: false))
        }
        guard normalized(base.deletingLastPathComponent()).pathComponents == normalized(parent).pathComponents else {
            throw RemoveError.wrongParent(folder.path(percentEncoded: false))
        }
        let basePath = base.standardizedFileURL.path(percentEncoded: false)
        let markerPath = base.standardizedFileURL.appending(path: marker).path(percentEncoded: false)
        guard (try? fm.attributesOfItem(atPath: basePath)[.type] as? FileAttributeType) == .typeDirectory,
              (try? fm.attributesOfItem(atPath: markerPath)[.type] as? FileAttributeType) == .typeRegular
        else {
            throw RemoveError.notADemo(folder.path(percentEncoded: false))
        }
        try fm.removeItem(at: base)
    }

    // MARK: - Helpers

    private static func normalized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isHome(_ url: URL) -> Bool {
        let homes = [URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory),
                     FileManager.default.homeDirectoryForCurrentUser]
        return homes.contains { normalized($0).pathComponents == url.pathComponents }
    }

    /// `base` without any inherited git variable, plus the isolation the demo needs: no global or system config,
    /// HOME in the demo folder, no prompt, no editor.
    static func isolatedEnvironment(_ base: [String: String], home: URL) -> [String: String] {
        var env = base.filter { !$0.key.hasPrefix("GIT_") && $0.key != "XDG_CONFIG_HOME" }
        env["HOME"] = home.path(percentEncoded: false)
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = "true"
        env["LC_ALL"] = "C"
        return env
    }

    /// The demo authors, so avatars and initials differ in the graph.
    private struct Author {
        let name: String
        let email: String
    }

    private static let ada = Author(name: "Ada Moreno", email: "ada@example.invalid")
    private static let ben = Author(name: "Ben Okafor", email: "ben@example.invalid")
    private static let chloe = Author(name: "Chloe Tran", email: "chloe@example.invalid")

    /// Runs the git steps in order, one hour apart, the last one about an hour before now.
    private struct Builder {
        /// The dated steps in `build` (commits, the merge, the tag, the stash).
        static let ticks = 18
        static let config = [
            "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", "-c", "core.hooksPath=/dev/null",
            "-c", "core.autocrlf=false", "-c", "gc.auto=0", "-c", "maintenance.auto=false",
            "-c", "advice.detachedHead=false",
        ]

        let runner: GitRunner
        let env: [String: String]
        let repo: URL
        let start = Date.now.addingTimeInterval(-Double(Builder.ticks + 1) * 3600)
        var tick = 0

        init(runner: GitRunner, env: [String: String], repo: URL) {
            self.runner = runner
            self.env = env
            self.repo = repo
        }

        mutating func build(base: URL) async throws {
            let worktree = base.appending(path: DemoRepository.worktreeName, directoryHint: .isDirectory)
            try await git(["init", "-q", "-b", "main", DemoRepository.repoName], in: base, as: ada, dated: false)

            try write("README.md", Content.readme(edited: false))
            try write("src/app.swift", Content.app(count: 3))
            try write(".gitignore", ".DS_Store\n")
            try await commit("Initial commit", by: ada)
            try write("docs/guide.md", "# Guide\n\nHow to run the demo app.\n")
            try await commit("Add guide", by: ben)
            try write("src/config.swift", "struct Config {\n    var debug = false\n}\n")
            try await commit("Add config", by: chloe)
            try write("src/greeter.swift", "func greet(_ name: String) -> String {\n    \"Hello, \\(name)!\"\n}\n")
            try await commit("Add greeter", by: ada)

            try await git(["switch", "-q", "-c", "feature/login"], as: ben, dated: false)
            try write("src/login.swift", "struct LoginForm {\n    var user = \"\"\n}\n")
            try await commit("Add login form", by: ben)
            try write("src/login.swift", "struct LoginForm {\n    var user = \"\"\n    var isValid: Bool { !user.isEmpty }\n}\n")
            try await commit("Validate login input", by: ben)

            try await git(["switch", "-q", "main"], as: ada, dated: false)
            try write("README.md", Content.readme(edited: true))
            try await commit("Describe the demo in README", by: ada)
            try await git(["merge", "-q", "--no-ff", "-m", "Merge branch 'feature/login'", "feature/login"], as: ada)
            try await git(["tag", "-a", "v1.0", "-m", "Release 1.0"], as: ada)
            try write("CHANGELOG.md", "# Changelog\n\n## 1.0\n\n- Login form\n")
            try await commit("Add changelog", by: chloe)

            try await git(["switch", "-q", "-c", "feature/search"], as: chloe, dated: false)
            try write("src/search.swift", "func search(_ query: String, in items: [String]) -> [String] {\n    items.filter { $0.contains(query) }\n}\n")
            try await commit("Add search", by: chloe)
            try write("src/rank.swift", "func rank(_ items: [String]) -> [String] {\n    items.sorted()\n}\n")
            try await commit("Rank search results", by: chloe)

            try await git(["switch", "-q", "main"], as: ada, dated: false)
            try write("src/config.swift", "struct Config {\n    var debug = false\n    var verbose = true\n}\n")
            try await commit("Add verbose flag", by: ben)
            try write("src/app.swift", Content.app(count: 5))
            try await commit("Greet more people", by: ada)
            try write("CONTRIBUTING.md", "# Contributing\n\nOpen a pull request against main.\n")
            try await commit("Add contributing guide", by: chloe)

            try write("docs/guide.md", "# Guide\n\nHow to run the demo app (draft edit).\n")
            try await git(["stash", "push", "-q", "-m", "guide tweaks"], as: ben)

            try write("VERSION", "1.0.1\n")
            try await commit("Bump version", by: ada)

            try await git(["worktree", "add", "-q", "-b", "fix/typo", worktree.path(percentEncoded: false), "main"],
                          as: chloe, dated: false)
            try write("docs/guide.md", "# Guide\n\nHow to run the demo app.\nSee README.md for the overview.\n",
                      in: worktree)
            try await commit("Fix typo in guide", by: chloe, in: worktree)

            try write("src/app.swift", Content.app(count: 8))
            try write("notes.txt", "Ideas for the next release.\n")
        }

        // MARK: Steps

        private func write(_ path: String, _ text: String, in folder: URL? = nil) throws {
            let url = (folder ?? repo).appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        private mutating func commit(_ message: String, by author: Author, in folder: URL? = nil) async throws {
            try await git(["add", "-A"], in: folder, as: author, dated: false)
            try await git(["commit", "-q", "-m", message], in: folder, as: author)
        }

        /// Runs git with the demo's config in `folder` (the main repository by default) as `author`; a dated step
        /// takes the next hour.
        private mutating func git(
            _ args: [String], in folder: URL? = nil, as author: Author, dated: Bool = true
        ) async throws {
            var env = env
            env["GIT_AUTHOR_NAME"] = author.name
            env["GIT_AUTHOR_EMAIL"] = author.email
            env["GIT_COMMITTER_NAME"] = author.name
            env["GIT_COMMITTER_EMAIL"] = author.email
            if dated {
                tick += 1
                let date = Self.gitDate(start.addingTimeInterval(Double(tick) * 3600))
                env["GIT_AUTHOR_DATE"] = date
                env["GIT_COMMITTER_DATE"] = date
            }
            _ = try await runner.run(Self.config + args, cwd: folder ?? repo, env: env, timeout: .seconds(30))
        }

        /// `<unix seconds> <±hhmm>` in the local time zone.
        private static func gitDate(_ date: Date) -> String {
            let offset = TimeZone.current.secondsFromGMT(for: date) / 60
            let sign = offset < 0 ? "-" : "+"
            let hours = abs(offset) / 60, minutes = abs(offset) % 60
            return "\(Int(date.timeIntervalSince1970)) \(sign)\(hours < 10 ? "0" : "")\(hours)\(minutes < 10 ? "0" : "")\(minutes)"
        }
    }

    /// File contents for the demo.
    private enum Content {
        static func readme(edited: Bool) -> String {
            "# Histq demo\n\nA small repository for the Histq tour.\n"
                + (edited ? "It has branches, a merge, a tag, a stash and a worktree.\n" : "")
        }

        static func app(count: Int) -> String {
            """
            import Foundation

            let names = ["Ada", "Ben", "Chloe"]
            let limit = \(count)

            for name in names.prefix(limit) {
                print(greet(name))
            }

            """
        }
    }
}
