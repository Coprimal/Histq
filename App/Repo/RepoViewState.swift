// Where the graph's per-worktree view (`RepoViewState`, in HistqCore) is saved for Untitled windows:
// `StatePaths.directory("repo-view")/<RepoSession.stateKey>.json` (never in `.git`). Small files, read and written
// synchronously; callable off the main thread.
import Foundation
import HistqCore

extension RepoViewState {
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
