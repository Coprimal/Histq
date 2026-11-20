// The repository's pull request template (a GitLab merge request template), read from a commit (the host reads it
// from the default branch), never from the working tree. Its text is repo content, so it only ever goes into an AI prompt's data block. A symlink entry
// is refused (its target could be any path, or point outside the repository), and so is anything but a regular
// file; a big file is skipped, and the text is cut to `maxBytes`. The blob is read by the object id `ls-tree`
// listed, so the bytes are those whose mode and size were checked.
import Foundation

public enum PullRequestTemplate {
    /// The file name GitHub looks for, compared case-insensitively.
    static let fileName = "pull_request_template.md"
    /// The folders searched, in order: the root, then `.github/`, then `docs/` (as GitHub does).
    static let folders = ["", ".github/", "docs/"]
    /// GitLab's folder of merge request templates: every `.md` file in it is one, `Default.md` (any case) the default.
    static let gitLabFolder = ".gitlab/merge_request_templates/"
    /// A larger blob is skipped, not read.
    static let maxBlobBytes = 64 * 1024
    /// The longest text returned, cut at a line break (or at least between UTF-8 characters).
    static let maxBytes = 8 * 1024

    /// The template's text at `ref` (a branch, tag or commit), from the first regular file named
    /// `pull_request_template.md` in any case in the root, `.github/` or `docs/` (GitLab: `Default.md` in any case in
    /// `.gitlab/merge_request_templates/`, else that folder's first `.md` file by name); nil when there is none or the
    /// read fails (a missing ref, too). A candidate whose root-relative path `ignore` (the worktree's `.aiignore`) matches
    /// is skipped, and the search goes on. `env` must be the read environment for `cwd`.
    public static func read(
        ref: String, runner: GitRunner, cwd: URL, env: [String: String], ignore: AIIgnore? = nil,
        kind: HostingKind = .github
    ) async -> String? {
        let paths = switch kind {
        case .github: ["."] + folders.filter { !$0.isEmpty }
        case .gitlab: [gitLabFolder]
        }
        guard let listing = try? await runner.run(
            ["ls-tree", "-z", "-l", "--full-tree", "--end-of-options", ref, "--"] + paths,
            cwd: cwd, env: env, timeout: .seconds(30))
        else { return nil }
        for oid in candidates(in: listing.stdout, ignore: ignore, kind: kind) {
            guard let blob = try? await runner.run(
                ["show", "--no-ext-diff", "--no-textconv", "--end-of-options", oid], cwd: cwd, env: env,
                timeout: .seconds(30))
            else { continue }
            return text(of: blob.stdout)
        }
        return nil
    }

    /// The object ids of the template files `ls-tree -z -l` lists, in search order: regular files (mode 100644 or
    /// 100755) of at most `maxBlobBytes`, directly in one of `folders` (GitLab: in `gitLabFolder`, `Default.md`
    /// first), and not matched by `ignore`.
    static func candidates(in listing: Data, ignore: AIIgnore? = nil, kind: HostingKind = .github) -> [String] {
        var found: [(rank: Int, oid: String)] = []
        for record in listing.split(separator: 0) {
            // `<mode> SP <type> SP <oid> SP <padded size> TAB <path>`: the path can hold any byte but NUL.
            guard let tab = record.firstIndex(of: 0x09) else { continue }
            let meta = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
            let path = String(decoding: record[(tab + 1)...], as: UTF8.self)
            guard meta.count == 4, ["100644", "100755"].contains(meta[0]), meta[1] == "blob",
                  let size = Int(meta[3]), size <= maxBlobBytes
            else { continue }
            let slash = path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex
            let name = path[slash...].lowercased(), folder = String(path[..<slash])
            let rank: Int? = switch kind {
            case .github: name == fileName ? folders.firstIndex(of: folder) : nil
            case .gitlab: folder == gitLabFolder && name.hasSuffix(".md") ? (name == "default.md" ? 0 : 1) : nil
            }
            guard let rank, ignore?.matches(path) != true else { continue }
            found.append((rank, String(meta[2])))
        }
        // Stable: within a rank, ls-tree's own order (by name).
        return found.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .map(\.element.oid)
    }

    /// `data` as text, cut to `maxBytes` after its last line break that fits, or between UTF-8 characters when no
    /// line break fits. Invalid UTF-8 shows as U+FFFD.
    static func text(of data: Data) -> String {
        let bytes = [UInt8](data)
        guard bytes.count > maxBytes else { return String(decoding: bytes, as: UTF8.self) }
        var end = maxBytes
        if let newline = bytes[..<end].lastIndex(of: 0x0A) {
            end = newline + 1
        } else {
            while end > 0, bytes[end] & 0xC0 == 0x80 { end -= 1 }
        }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }
}
