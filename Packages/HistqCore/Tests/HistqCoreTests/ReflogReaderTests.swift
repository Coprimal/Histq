// Tests for the reflog reader (task 7.3): a real reflog of the `graph` fixture after a reset lists every entry of git's
// own `git reflog`, newest first, split into action and message, with the commit the reset left behind.
import Foundation
import HistqCore
import Testing

struct ReflogReaderTests {
    @Test("after a reset the reflog lists git's entries in order, the reset first and the orphaned commit next")
    func reflogAfterReset() async throws {
        let copy = try await Fixtures.copy()
        defer { copy.remove() }
        let repo = copy.repo("graph")
        let orphan = try await copy.git(["rev-parse", "HEAD"], in: repo)
        try await copy.git(["reset", "--hard", "HEAD~2"], in: repo)
        let env = try await GitInvocation.readEnvironment(profile: nil, base: copy.base, runner: copy.runner, cwd: repo)

        let entries = try await ReflogReader.read(runner: copy.runner, cwd: repo, env: env)

        let expected = try await copy.git(["reflog", "--format=%H%x1f%gs"], in: repo).split(separator: "\n")
        #expect(entries.map { "\($0.hash)\u{1F}\($0.action): \($0.message)" } == expected.map(String.init))
        #expect(entries.map(\.index) == Array(entries.indices))
        #expect(entries.first?.action == "reset")
        #expect(entries.first?.message == "moving to HEAD~2")
        #expect(entries.dropFirst().first?.hash == orphan)
        #expect(zip(entries, entries.dropFirst()).allSatisfy { $0.date >= $1.date })
    }
}
