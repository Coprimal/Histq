// The repositories opened lately, most recent first, for the Welcome page, and the workspace files opened lately, for
// Recent Workspaces. Kept in `Preferences.defaults` (`PrefKey.recentRepos`, `.recentWorkspaces`), so reading them
// never touches the disk on the main thread.
import Foundation
import Observation

@Observable
@MainActor
final class RecentRepos {
    static let shared = RecentRepos(key: .recentRepos, limit: 10, directoryHint: .isDirectory)
    /// The workspace files, added by identity key (`WorkspaceFile.identityKey(for:)`) and stored standardized
    /// (`/private/tmp/…` as `/tmp/…`).
    static let workspaces = RecentRepos(key: .recentWorkspaces, limit: 10, directoryHint: .notDirectory)

    /// How many entries the list keeps.
    let limit: Int

    /// File URLs, most recent first.
    private(set) var urls: [URL]

    private let key: String

    private init(key: PrefKey, limit: Int, directoryHint: URL.DirectoryHint) {
        self.key = key.rawValue
        self.limit = limit
        urls = (Preferences.defaults.stringArray(forKey: key.rawValue) ?? [])
            .map { URL(filePath: $0, directoryHint: directoryHint) }
    }

    /// Puts `url` first (moving it up if already listed), keeping `limit` entries.
    func add(_ url: URL) {
        let url = url.standardizedFileURL
        var list = urls.filter { $0.path != url.path }
        list.insert(url, at: 0)
        urls = Array(list.prefix(limit))
        save()
    }

    func remove(_ url: URL) {
        urls.removeAll { $0.path == url.path }
        save()
    }

    /// Empties the list (Recent Workspaces › Clear Menu).
    func clear() {
        urls = []
        save()
    }

    private func save() {
        Preferences.defaults.set(urls.map(\.path), forKey: key)
    }
}
