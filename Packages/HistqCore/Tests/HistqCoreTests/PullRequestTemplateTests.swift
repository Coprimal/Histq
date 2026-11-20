// Security and core tests for the pull request template reader (task 5.1), each on a private temp repo read with the
// read environment: a template in `.github/` is found whatever its name's case, a GitLab repo's `Default.md` is
// preferred among its merge request templates, a symlink named like a template is
// never followed, a template `.aiignore` matches is skipped, and a ref without a template (or no such ref) gives nil.
import Foundation
import HistqCore
import Testing

struct PullRequestTemplateTests {
    /// Commits `files` (path → text) on top of `Sandbox.makeRepo`'s first commit, and `links` (path → target) as
    /// symlinks; returns the template `kind` reads at HEAD, skipping what `ignore` (`.aiignore` text) matches.
    private func read(
        files: [String: String] = [:], links: [String: String] = [:], ref: String = "HEAD", ignore: String? = nil,
        kind: HostingKind = .github
    ) async throws -> String?
    {
        let sandbox = try await Sandbox()
        defer { sandbox.remove() }
        let repo = try await sandbox.makeRepo("repo")
        for (path, text) in files {
            let url = repo.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        for (path, target) in links {
            let url = repo.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
        }
        try await sandbox.git(["add", "-A"], in: repo)
        try await sandbox.git(["commit", "-q", "--allow-empty", "-m", "files"], in: repo)
        let env = try await GitInvocation.readEnvironment(
            profile: nil, base: sandbox.base, runner: sandbox.runner, cwd: repo)
        return await PullRequestTemplate.read(
            ref: ref, runner: sandbox.runner, cwd: repo, env: env, ignore: ignore.map(AIIgnore.init(text:)), kind: kind)
    }

    @Test("a template in .github/ is found whatever its name's case")
    func foundCaseInsensitivelyInGitHubFolder() async throws {
        let text = "## Summary\n\n## Testing\n"
        #expect(try await read(files: [".github/Pull_Request_TEMPLATE.md": text, "docs/notes.md": "x\n"]) == text)
    }

    @Test("a GitLab repo's Default.md is preferred over its other merge request templates")
    func gitLabDefaultTemplate() async throws {
        let files = [".gitlab/merge_request_templates/Bug.md": "## Bug\n",
                     ".gitlab/merge_request_templates/Default.md": "## Default\n",
                     ".github/pull_request_template.md": "## GitHub\n"]
        #expect(try await read(files: files, kind: .gitlab) == "## Default\n")
    }

    @Test("a symlink named like a template is ignored, never followed")
    func symlinkEntryIsIgnored() async throws {
        let template = try await read(
            files: ["secret.txt": "pangolin secret\n"], links: [".github/PULL_REQUEST_TEMPLATE.md": "../secret.txt"])
        #expect(template == nil)
    }

    @Test("a template .aiignore matches is skipped")
    func aiIgnoredTemplateIsSkipped() async throws {
        #expect(try await read(files: [".github/pull_request_template.md": "## Summary\n"], ignore: ".github/") == nil)
    }

    @Test("a ref without a template, or a missing ref, gives nil")
    func missingGivesNil() async throws {
        #expect(try await read(files: ["docs/readme.md": "x\n"]) == nil)
        #expect(try await read(ref: "no-such-branch") == nil)
    }
}
