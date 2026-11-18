// The graph's per-worktree view: hidden branches and tags, soloed and pinned branches and the "hide stale branches"
// switch, saved as JSON in `StatePaths.directory("repo-view")/<RepoSession.stateKey>.json` (never in `.git`). Small
// files, read and written synchronously; callable off the main thread.
import Foundation

struct RepoViewState: Codable, Equatable, Sendable {
    static let empty = RepoViewState()

    /// Full ref names (`refs/heads/x`, `refs/remotes/o/x`); `hidden` also tags (`refs/tags/v1`).
    var hidden: [String] = []
    var solo: [String] = []
    var pinned: [String] = []
    var hideStale = false

    init() {}

    /// A missing field reads as its default, so a file from an older build still loads.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hidden = try container.decodeIfPresent([String].self, forKey: .hidden) ?? []
        solo = try container.decodeIfPresent([String].self, forKey: .solo) ?? []
        pinned = try container.decodeIfPresent([String].self, forKey: .pinned) ?? []
        hideStale = try container.decodeIfPresent(Bool.self, forKey: .hideStale) ?? false
    }

    /// The saved state for `key` (`RepoSession.stateKey`); a missing or unreadable file reads as `empty`.
    static func load(key: String) -> RepoViewState {
        guard let data = try? Data(contentsOf: file(key)),
              let state = try? JSONDecoder().decode(RepoViewState.self, from: data)
        else { return .empty }
        return state
    }

    /// Writes the state for `key` atomically (a temp file, then a rename).
    func save(key: String) throws {
        try JSONEncoder().encode(self).write(to: Self.file(key), options: .atomic)
    }

    private static func file(_ key: String) -> URL {
        StatePaths.directory("repo-view").appending(path: "\(key).json", directoryHint: .notDirectory)
    }
}
