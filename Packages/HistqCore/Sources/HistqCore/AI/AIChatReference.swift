// What a chat message can point at (commits, working changes, a file of a commit, a branch, a pull request) and the
// hidden context it resolves to. The chip label is UI only; the resolved text is data blocks with fixed app labels
// (`AIPrompts.dataBlocks`) and fixed app notes, so paths, branch names, commit messages and PR text only ever sit
// inside a block. Nothing is read when a reference is attached: `resolve` runs at send, with the read environment.
import Foundation

public enum AIChatReference: Codable, Sendable, Hashable {
    /// Commits by object id, in the order given.
    case commits([String])
    /// The staged changes, or the unstaged ones.
    case wip(staged: Bool)
    /// One file's changes in one commit (`path` root-relative).
    case fileInCommit(hash: String, path: String)
    /// What branch `name` changed since it left `base` (both commit-ishes the app chose, such as
    /// `refs/heads/feature-x` and `refs/remotes/origin/main`), as a pull request shows it.
    case branch(name: String, base: String)
    /// A pull request: its title and description from the hosting model at click; `base` and `head` are local ref
    /// names the app chose (the core does not know the remote). Nothing is fetched: when either ref is missing,
    /// only the description is sent, with a note.
    case pullRequest(number: Int, title: String, body: String, base: String, head: String)

    /// The chip shown in the chat (UI only, never sent).
    public var label: String {
        switch self {
        case .commits(let hashes):
            hashes.count == 1 ? "Commit \(hashes[0].prefix(7))" : "\(hashes.count) commits"
        case .wip(let staged):
            staged ? "Staged changes" : "Unstaged changes"
        case .fileInCommit(let hash, let path):
            "\(hash.prefix(7)) · \(path.split(separator: "/").last.map(String.init) ?? path)"
        case .branch(let name, let base):
            "\(Self.shortName(name)) vs \(Self.shortName(base))"
        case .pullRequest(let number, _, _, _, _):
            "PR #\(number)"
        }
    }

    /// `ref` without `refs/heads/` or `refs/remotes/` (the app passes full ref names, so a tag of the same name never
    /// wins): `refs/remotes/origin/main` shows as `origin/main`.
    private static func shortName(_ ref: String) -> String {
        for prefix in ["refs/heads/", "refs/remotes/"] where ref.hasPrefix(prefix) {
            return String(ref.dropFirst(prefix.count))
        }
        return ref
    }

    // MARK: - Codable

    // A flat object with a "kind" key. An unknown kind (from a later build) throws, so the caller decodes a list of
    // references leniently, element by element, and drops just that one.
    private enum Kind: String, Codable { case commits, wip, fileInCommit, branch, pullRequest }

    private enum CodingKeys: String, CodingKey {
        case kind, hashes, staged, hash, path, name, base, number, title, body, head
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .commits:
            self = .commits(try container.decode([String].self, forKey: .hashes))
        case .wip:
            self = .wip(staged: try container.decode(Bool.self, forKey: .staged))
        case .fileInCommit:
            self = .fileInCommit(
                hash: try container.decode(String.self, forKey: .hash),
                path: try container.decode(String.self, forKey: .path))
        case .branch:
            self = .branch(
                name: try container.decode(String.self, forKey: .name),
                base: try container.decode(String.self, forKey: .base))
        case .pullRequest:
            self = .pullRequest(
                number: try container.decode(Int.self, forKey: .number),
                title: try container.decode(String.self, forKey: .title),
                body: try container.decode(String.self, forKey: .body),
                base: try container.decode(String.self, forKey: .base),
                head: try container.decode(String.self, forKey: .head))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .commits(let hashes):
            try container.encode(Kind.commits, forKey: .kind)
            try container.encode(hashes, forKey: .hashes)
        case .wip(let staged):
            try container.encode(Kind.wip, forKey: .kind)
            try container.encode(staged, forKey: .staged)
        case .fileInCommit(let hash, let path):
            try container.encode(Kind.fileInCommit, forKey: .kind)
            try container.encode(hash, forKey: .hash)
            try container.encode(path, forKey: .path)
        case .branch(let name, let base):
            try container.encode(Kind.branch, forKey: .kind)
            try container.encode(name, forKey: .name)
            try container.encode(base, forKey: .base)
        case .pullRequest(let number, let title, let body, let base, let head):
            try container.encode(Kind.pullRequest, forKey: .kind)
            try container.encode(number, forKey: .number)
            try container.encode(title, forKey: .title)
            try container.encode(body, forKey: .body)
            try container.encode(base, forKey: .base)
            try container.encode(head, forKey: .head)
        }
    }
}

public enum AIChatReferenceError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A commit reference whose hash is not an object id.
    case invalidCommit

    public var description: String {
        switch self {
        case .invalidCommit: "A referenced commit is not valid."
        }
    }
}

// MARK: - Resolving

extension AIChatReference {
    /// The bytes a diff block needs besides its text (app line, BEGIN and END lines, separator), with room to spare.
    static let blockReserve = 256
    /// A diff gets at least this many bytes, else it is left out with a note.
    static let minDiffShare = 512
    /// A reference is read only when at least this many bytes of the total are left.
    static let minRoom = 1_024
    /// Kept free of the total for the closing note of `resolve`.
    static let noteReserve = 128

    /// The hidden context of `references`: data blocks only (the caller adds any task rules before it). Diffs are
    /// read with `DiffReader.patchText` in `cwd` with `env` (the read environment, no profile), filtered with
    /// `ignore` (`AIPrompts.filtered`), each reference's diffs cut to `budget` together (`AIPrompts.budgeted`), and
    /// the whole text is at most 2 × `budget` UTF-8 bytes: a reference that no longer fits is left out and counted
    /// in a closing note. `hasData` is false when no reference read gave a diff or a commit message, PR title or PR
    /// description (only notes and names, such as empty diffs or a branch with nothing past its base), so the caller
    /// sends nothing; `allIgnored` is true when `.aiignore` left out every file of some diff read (the caller then
    /// says so instead of "no changes"). Throws `AIChatReferenceError.invalidCommit` for a hash that is not an object
    /// id, and `GitError` when git fails. `ignore` is the `.aiignore` whose `AIIgnore.digest` the caller stores with
    /// it.
    public static func resolve(
        _ references: [AIChatReference], runner: GitRunner, cwd: URL, env: [String: String], ignore: AIIgnore?,
        budget: Int = AIPrompts.diffBudget, token: @Sendable () -> String = AIPrompts.randomToken
    ) async throws -> (text: String, hasData: Bool, allIgnored: Bool) {
        let total = 2 * budget - noteReserve
        var out: [String] = []
        var used = 0
        var leftOut = 0
        var hasData = false
        var allIgnored = false
        for reference in references {
            let room = total - used
            guard room >= minRoom else {
                leftOut += 1
                continue
            }
            let parts = try await reference.parts(
                runner: runner, cwd: cwd, env: env, ignore: ignore, limit: min(room, budget))
            let text = render(parts, room: room, budget: budget, token: token)
            guard !text.isEmpty else { continue }
            out.append(text)
            used += text.utf8.count + 1
            hasData = hasData || parts.contains(where: \.hasData)
            allIgnored = allIgnored || parts.contains { if case .ignored = $0 { true } else { false } }
        }
        if leftOut > 0 { out.append("[Histq: \(leftOut) more references left out to fit the size limit]\n") }
        return (out.joined(separator: "\n"), hasData, allIgnored)
    }

    /// One piece of a resolved reference: a data block, a diff (budgeted at render), a fixed app note, or the fixed
    /// note that `.aiignore` left out every file of a diff.
    enum Part {
        case block(AIDataLabel, String)
        case diff(AIDataLabel, String)
        case note(String)
        case ignored(String)

        /// A diff, or a non-empty commit message, PR title or PR description: names and paths alone are no data.
        var hasData: Bool {
            switch self {
            case .diff: true
            case .block(let label, let text):
                [.commitMessage, .prTitle, .prDescription].contains(label)
                    && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .note, .ignored: false
            }
        }
    }

    private func parts(
        runner: GitRunner, cwd: URL, env: [String: String], ignore: AIIgnore?, limit: Int
    ) async throws -> [Part] {
        func patch(_ source: DiffReader.PatchSource) async throws -> String {
            try await DiffReader.patchText(source, runner: runner, cwd: cwd, env: env)
        }
        switch self {
        case .commits(let hashes):
            guard hashes.allSatisfy(GitOperations.isObjectID) else { throw AIChatReferenceError.invalidCommit }
            guard !hashes.isEmpty else { return [] }
            // Each commit read needs room for its message, two block wrappers and some diff, so a long selection
            // stops early.
            let count = min(hashes.count, max(1, limit / (4 * Self.minDiffShare)))
            let messageBytes = limit / (2 * count)
            var parts: [Part] = []
            for hash in hashes.prefix(count) {
                let message = try await runner.run(
                    ["log", "-1", "--no-show-signature", "--format=%B", "--end-of-options", hash, "--"],
                    cwd: cwd, env: env
                ).text
                parts.append(.block(.commitMessage, Self.prefix(
                    String(message.prefix(AIPrompts.maxMessageCharacters)), bytes: messageBytes)))
                parts.append(Self.diffPart(.commitDiff, try await patch(.commit(hash)), ignore: ignore))
            }
            if hashes.count > count {
                parts.append(.note("[Histq: \(hashes.count - count) more commits left out to fit the size limit]"))
            }
            return parts
        case .wip(let staged):
            return [Self.diffPart(staged ? .stagedDiff : .unstagedDiff, try await patch(staged ? .staged : .unstaged),
                                  ignore: ignore)]
        case .fileInCommit(let hash, let path):
            guard GitOperations.isObjectID(hash) else { throw AIChatReferenceError.invalidCommit }
            // The path itself is left out too, as `filtered` drops an ignored file's header.
            if ignore?.matches(path) == true { return [.ignored("[Histq: this file is left out by .aiignore]")] }
            let files = AIPrompts.splitFiles(try await patch(.commit(hash))).filter {
                AIPrompts.filePaths($0.lines).contains(path)
            }
            let diff = files.map { $0.lines.map { $0 + "\n" }.joined() }.joined()
            return [
                .block(.filePath, String(path.prefix(AIPrompts.maxHeaderCharacters))),
                diff.isEmpty ? .note("[Histq: this file has no changes in this commit]")
                    : Self.diffPart(.fileDiff, diff, ignore: ignore),
            ]
        case .branch(let name, let base):
            var parts: [Part] = [
                .block(.branchName, String(name.prefix(AIPrompts.maxHeaderCharacters))),
                .block(.baseBranchName, String(base.prefix(AIPrompts.maxHeaderCharacters))),
            ]
            if let head = try await Self.commitID(name, runner: runner, cwd: cwd, env: env),
               let baseID = try await Self.commitID(base, runner: runner, cwd: cwd, env: env) {
                parts.append(Self.diffPart(.branchDiff, try await patch(.branch(base: baseID, head: head)),
                                           ignore: ignore))
            } else {
                parts.append(.note(
                    "[Histq: the branch or its base is not in this repository, so its diff is left out]"))
            }
            return parts
        case .pullRequest(_, let title, let body, let base, let head):
            var parts: [Part] = [
                .block(.prTitle, String(title.prefix(AIPrompts.maxHeaderCharacters))),
                .block(.prDescription, Self.prefix(
                    String(body.prefix(AIPrompts.maxMessageCharacters)), bytes: limit / 4)),
                .block(.branchName, String(head.prefix(AIPrompts.maxHeaderCharacters))),
                .block(.baseBranchName, String(base.prefix(AIPrompts.maxHeaderCharacters))),
            ]
            if let headID = try await Self.commitID(head, runner: runner, cwd: cwd, env: env),
               let baseID = try await Self.commitID(base, runner: runner, cwd: cwd, env: env) {
                parts.append(Self.diffPart(.branchDiff, try await patch(.branch(base: baseID, head: headID)),
                                           ignore: ignore))
            } else {
                parts.append(.note(
                    "[Histq: the pull request's branches are not in this repository, so only its description is sent]"))
            }
            return parts
        }
    }

    /// `diff` filtered with `ignore`; an empty diff becomes a note, and so does one whose every file `ignore` leaves
    /// out (`.ignored`).
    private static func diffPart(_ label: AIDataLabel, _ diff: String, ignore: AIIgnore?) -> Part {
        guard !diff.isEmpty else { return .note("[Histq: no changes]") }
        guard let kept = AIPrompts.filteredUnlessAllIgnored(diff, ignore: ignore) else {
            return .ignored("[Histq: every changed file is left out by .aiignore]")
        }
        return .diff(label, kept)
    }

    /// `ref` as a commit id, or nil when it names no commit. `--end-of-options` keeps a name starting with `-` from
    /// being read as an option; `^{commit}` refuses anything that is not a commit (a `rev:path` blob).
    private static func commitID(
        _ ref: String, runner: GitRunner, cwd: URL, env: [String: String]
    ) async throws -> String? {
        guard !ref.isEmpty else { return nil }
        let result = try await runner.run(
            ["rev-parse", "-q", "--verify", "--end-of-options", "\(ref)^{commit}"], cwd: cwd, env: env,
            allowedExitCodes: [0, 1])
        let id = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.exitCode == 0 && GitOperations.isObjectID(id) ? id : nil
    }

    /// `parts` rendered: data blocks and notes, a blank line between them. The diffs share what the other parts
    /// leave of `room`, each at most `budget` together; a share under `minDiffShare` leaves the diff out with a
    /// note. The result is cut to `room` bytes (`AIChatHistory.cut`, which never leaves a block open).
    static func render(_ parts: [Part], room: Int, budget: Int, token: () -> String) -> String {
        var rendered: [String?] = parts.map { part in
            switch part {
            case .block(let label, let text):
                AIPrompts.dataBlocks([AIDataBlock(label: label, text: text)], candidate: token)
            case .note(let text), .ignored(let text): text + "\n"
            case .diff: nil
            }
        }
        let fixed = rendered.reduce(0) { $0 + ($1?.utf8.count ?? 0) + 1 }
        let diffs = parts.filter { if case .diff = $0 { true } else { false } }.count
        let share = diffs == 0 ? 0 : min(budget, room - fixed - diffs * blockReserve) / diffs
        for (index, part) in parts.enumerated() {
            guard case .diff(let label, let diff) = part else { continue }
            rendered[index] = share < minDiffShare
                ? "[Histq: this diff was left out to fit the size limit]\n"
                : AIPrompts.dataBlocks([AIDataBlock(label: label, text: AIPrompts.budgeted(diff, budget: share))],
                                       candidate: token)
        }
        return AIChatHistory.cut(rendered.compactMap { $0 }.joined(separator: "\n"), toBytes: room)
    }

    /// The start of `text` in at most `bytes` UTF-8 bytes, cut between characters.
    private static func prefix(_ text: String, bytes: Int) -> String {
        var used = 0
        var end = text.startIndex
        for index in text.indices {
            let size = text[index].utf8.count
            guard used + size <= bytes else { break }
            used += size
            end = text.index(after: index)
        }
        return String(text[..<end])
    }
}
