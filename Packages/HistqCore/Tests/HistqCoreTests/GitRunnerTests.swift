// Key feature tests for the process layer (task 2.5): a failing git command surfaces its exit code and
// stderr tail, cancelling a stream really stops the child process, a stream cuts an over-long line (yielded
// before EOF) and resumes at the next one, and GitExecutable rejects a git older than 2.36 while accepting
// 2.36 itself.
import Foundation
import HistqCore
import Testing

struct GitRunnerTests {
    @Test("a failing command throws GitError with its exit code and stderr tail")
    func failingCommandReportsExitCodeAndStderrTail() async throws {
        let folder = try Fixtures.makeTempDirectory()
        defer { Fixtures.removeTempDirectory(folder) }
        let work = folder.appending(path: "not-a-repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var env = Fixtures.hermeticEnvironment(home: folder)
        // Never discover a repo above the temp folder, whatever the machine's temp path is inside.
        env["GIT_CEILING_DIRECTORIES"] = folder.path

        let runner = GitRunner(executable: Fixtures.git)
        let error = try await #require(throws: GitError.self) {
            try await runner.run(["rev-parse", "--git-dir"], cwd: work, env: env, timeout: .seconds(30))
        }
        #expect(error.exitCode == 128)
        #expect(error.stderrTail.contains("not a git repository"), "stderr tail: \(error.stderrTail)")
        #expect(error == .other(exit: 128, stderrTail: error.stderrTail))
    }

    @Test("cancelling the task that consumes a stream terminates the child process")
    func cancellingStreamTerminatesChild() async throws {
        let folder = try Fixtures.makeTempDirectory()
        defer { Fixtures.removeTempDirectory(folder) }
        // A fake git that prints forever, at a path unique to this test so `pgrep -f` matches only it.
        let fakeGit = folder.appending(path: "fake-git-\(UUID().uuidString)/git")
        try Fixtures.writeScript("while :; do echo tick; done", to: fakeGit)
        let marker = NSRegularExpression.escapedPattern(for: fakeGit.path)
        let env = Fixtures.hermeticEnvironment(home: folder)

        let runner = GitRunner(executable: fakeGit)
        let stream = await runner.stream(["log"], cwd: folder, env: env)
        let (ready, readyContinuation) = AsyncStream<Void>.makeStream()
        let consumer = Task {
            defer { readyContinuation.finish() }
            for try await _ in stream { readyContinuation.yield() }
            try Task.checkCancellation()
        }
        var readyIterator = ready.makeAsyncIterator()
        try #require(await readyIterator.next() != nil, "the fake git printed nothing")
        #expect(try await Self.isRunning(marker, cwd: folder), "the child runs before the cancel")

        consumer.cancel()
        let outcome = await consumer.result
        #expect(throws: CancellationError.self) { try outcome.get() }
        let gone = try await Self.poll(upTo: .seconds(5)) { try await !Self.isRunning(marker, cwd: folder) }
        #expect(gone, "the child process is still running 5 s after the cancel")
    }

    @Test("a stream cuts a stdout line at maxLineBytes, drops its rest and resumes at the next line")
    func streamCutsLongLineAndResumes() async throws {
        let folder = try Fixtures.makeTempDirectory()
        defer { Fixtures.removeTempDirectory(folder) }
        let fakeGit = folder.appending(path: "bin/git")
        try Fixtures.writeScript("head -c 1000000 /dev/zero | tr '\\0' q\nprintf '\\nshort\\n'", to: fakeGit)
        let env = Fixtures.hermeticEnvironment(home: folder)

        var lines: [GitRunner.Line] = []
        for try await line in await GitRunner(executable: fakeGit).stream(
            ["cat-file"], cwd: folder, env: env, timeout: .seconds(30), maxLineBytes: 4_096)
        where line.source == .stdout {
            lines.append(line)
        }
        try #require(lines.count == 2, "lines: \(lines.map(\.text.utf8.count))")
        #expect(lines[0].truncated)
        #expect(lines[0].text == String(repeating: "q", count: 4_096))
        #expect(lines[1].text == "short")
        #expect(!lines[1].truncated)
    }

    @Test("a cut line is yielded while git is still writing it, before any delimiter or EOF")
    func streamYieldsCutLineBeforeEOF() async throws {
        let folder = try Fixtures.makeTempDirectory()
        defer { Fixtures.removeTempDirectory(folder) }
        // Shell builtins only, so the stop's SIGINT ends it: one endless line.
        let fakeGit = folder.appending(path: "bin/git")
        try Fixtures.writeScript("while :; do printf 'qqqqqqqqqqqqqqqq'; done", to: fakeGit)
        let env = Fixtures.hermeticEnvironment(home: folder)

        var first: GitRunner.Line?
        for try await line in await GitRunner(executable: fakeGit).stream(
            ["cat-file"], cwd: folder, env: env, timeout: .seconds(30), maxLineBytes: 4_096) {
            first = line
            break
        }
        #expect(first?.source == .stdout)
        #expect(first?.truncated == true)
        #expect(first?.text.utf8.count == 4_096)
    }

    @Test("GitExecutable rejects git 2.35.1 as too old and accepts git 2.36.0")
    func executableEnforcesMinimumVersion() async throws {
        let folder = try Fixtures.makeTempDirectory()
        defer { Fixtures.removeTempDirectory(folder) }
        let old = folder.appending(path: "old/git")
        let current = folder.appending(path: "current/git")
        try Fixtures.writeScript("echo 'git version 2.35.1'", to: old)
        try Fixtures.writeScript("echo 'git version 2.36.0'", to: current)

        await #expect(throws: GitExecutableError.tooOld(GitVersion(2, 35, 1))) {
            try await GitExecutable.resolve(override: old.path)
        }
        let accepted = try await GitExecutable.resolve(override: current.path)
        #expect(accepted.version == GitVersion(2, 36, 0))
        #expect(accepted.url.path == current.path)
    }

    // MARK: - Helpers

    /// True while a process whose command line matches `pattern` exists (`pgrep -f`, scoped to the
    /// test's unique script path, never a broad name such as `git`).
    private static func isRunning(_ pattern: String, cwd: URL) async throws -> Bool {
        let pgrep = GitRunner(executable: URL(filePath: "/usr/bin/pgrep"))
        let result = try await pgrep.run(
            ["-f", pattern], cwd: cwd, env: ["PATH": "/usr/bin:/bin", "HOME": cwd.path], timeout: .seconds(5),
            allowedExitCodes: [0, 1])
        return result.exitCode == 0
    }

    /// Checks `condition` every 50 ms until it holds (true) or `limit` passes (false).
    private static func poll(upTo limit: Duration, _ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try await condition()
    }
}
