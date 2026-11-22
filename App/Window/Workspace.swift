// An open workspace file (`*.histqws`): its windows' membership, and everything capture needs to write the
// file back as it was read: the stored path strings, the repos and profiles in file order, the repos that did not
// resolve, the graph views and the embedded profiles. The file is read and resolved off the main thread.
import Foundation
import HistqCore
import Observation

/// One open workspace. Its windows point to it (`WindowModel.workspace`); capture builds its `WorkspaceFile` from
/// them and the state kept here, so an unchanged workspace writes the same model it was read as.
@Observable
@MainActor
final class Workspace {
    /// A file refused before it is read.
    enum OpenError: LocalizedError {
        /// Larger than `maxFileSize`: no workspace is that big.
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .tooLarge: "The file is too large to be a Histq workspace."
            }
        }
    }

    /// The largest file `open` reads.
    nonisolated static let maxFileSize = 8 * 1024 * 1024
    /// The folder `~` stands for in the file's `home` strings.
    nonisolated static let homeURL = FileManager.default.homeDirectoryForCurrentUser

    private(set) var url: URL
    /// The file's identity key (`WorkspaceFile.identityKey(for:)`).
    private(set) var key: String
    /// The file name without its extension.
    private(set) var name: String
    /// The file has keys this build would drop (`WorkspaceFile.Read.isLossless == false`): it is never written. Save
    /// As makes a writable copy.
    private(set) var isReadOnly: Bool
    /// Close Workspace is under way: closing its windows captures nothing.
    var isClosing = false
    /// The last write of the file failed; cleared by the next successful one.
    var writeFailed = false
    /// Why the last write failed (shown in the toolbar); nil once a write succeeds.
    var writeError: String?
    /// The file and layout from before its windows started closing by hand, kept until the close burst settles.
    var preCloseSnapshot: (file: WorkspaceFile, layout: WorkspaceLayout)?
    /// The profiles embedded in the file, as read.
    var profiles: [Profile]
    /// The library's definition of each embedded profile id when the workspace opened; an id the library did not
    /// have is absent.
    private(set) var profileBaseline: [UUID: Profile] = [:]
    /// The stored `path` / `home` strings by absolute path (`WorkspaceFile.Resolved.originals`).
    var originals: [String: WorkspaceFile.Original]
    /// The absolute path of each repo, in file order; repos added later are appended.
    var repoOrder: [String]
    /// The profile ids in file order; profiles added later are appended.
    var profileOrder: [UUID]
    /// The window ids in file order; windows added later are appended.
    var windowOrder: [UUID]
    /// The `repos[]` entries that did not resolve, by absolute path, written back verbatim.
    var repos: [String: WorkspaceFile.Repo]
    /// The absolute paths of the tabs that did not resolve ("Repo not found").
    var missing: Set<String>
    /// The graph views by absolute repo path: those read from the file, then each tab's as it is first shown or
    /// changes (`setView`). Capture writes those of the repos the windows' tabs have.
    var views: [String: RepoViewState]

    /// A workspace this build just wrote to `url` (New Workspace, Save As from Untitled windows): writable, with no
    /// stored strings, carried repos, views or embedded profiles yet.
    init(url: URL) {
        self.url = url
        key = WorkspaceFile.identityKey(for: url)
        name = url.deletingPathExtension().lastPathComponent
        isReadOnly = false
        profiles = []
        originals = [:]
        repoOrder = []
        profileOrder = []
        windowOrder = []
        repos = [:]
        missing = []
        views = [:]
    }

    private init(url: URL, key: String, read: WorkspaceFile.Read, resolved: WorkspaceFile.Resolved) {
        self.url = url
        self.key = key
        name = url.deletingPathExtension().lastPathComponent
        isReadOnly = !read.isLossless
        profiles = read.file.profiles
        originals = resolved.originals
        repoOrder = resolved.repoOrder
        profileOrder = resolved.profileOrder
        windowOrder = resolved.windows.map(\.id)
        repos = resolved.carried
        missing = resolved.missing
        views = resolved.views
    }

    /// Reads and resolves the file at `url` off the main thread, with the repo key (`RepoGroupKey`) of every resolved
    /// tab by its absolute path, then sets the profile baseline once the library is read, so the caller can restore
    /// the windows and seed the writer at once. A window with no tab is dropped; a file left with no window gets one
    /// with a Welcome tab. Throws `OpenError` and `WorkspaceFile.read`'s errors.
    static func open(_ url: URL) async throws -> (Workspace, WorkspaceFile.Resolved, repoKeys: [String: String]) {
        let (key, read, resolved, repoKeys) = try await Task.detached(priority: .userInitiated) {
            let key = WorkspaceFile.identityKey(for: url)
            let size = try URL(fileURLWithPath: key).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maxFileSize else { throw OpenError.tooLarge }
            let read = try WorkspaceFile.read(url)
            var resolved = read.file.resolved(fileURL: url, homeURL: homeURL, isRepository: SavedSession.isRepository)
            resolved.windows.removeAll { $0.tabs.isEmpty }
            if resolved.windows.isEmpty { resolved.windows = [.init(id: UUID(), tabs: [SavedTab()])] }
            var repoKeys: [String: String] = [:]
            let paths = Set(resolved.windows.flatMap { $0.tabs.compactMap(\.path) }).subtracting(resolved.missing)
            for path in paths {
                repoKeys[path] = RepoGroupKey.of(URL(fileURLWithPath: path, isDirectory: true))
            }
            return (key, read, resolved, repoKeys)
        }.value
        let workspace = Workspace(url: url, key: key, read: read, resolved: resolved)
        let library = await ProfileLibrary.shared.loaded()
        for profile in workspace.profiles {
            if let defined = library?.profile(id: profile.id) { workspace.profileBaseline[profile.id] = defined }
        }
        return (workspace, resolved, repoKeys)
    }

    /// Profiles just imported from this file (`ProfileImportSheet`): each becomes the baseline of the id it embeds, so
    /// a later edit in Settings is written to the file, as for a profile the library had when the workspace opened.
    func adoptBaseline(_ imported: [Profile]) {
        for profile in imported where profiles.contains(where: { $0.id == profile.id }) {
            profileBaseline[profile.id] = profile
        }
    }

    /// A tab moved in from another workspace with a profile this Mac does not have (`WindowModel.adopt`): the file
    /// embeds `profile`'s definition too, so the tab's picker keeps its Import entry. An id embedded already stays.
    func adoptProfile(_ profile: Profile) {
        guard !profiles.contains(where: { $0.id == profile.id }) else { return }
        profiles.append(profile)
        if !profileOrder.contains(profile.id) { profileOrder.append(profile.id) }
    }

    /// The graph view the workspace has for the repo at `url` (keyed by its standardized absolute path); nil when it
    /// has none.
    func view(for url: URL) -> RepoViewState? {
        views[WorkspaceFile.standardized(url.path)]
    }

    /// Sets the graph view of the repo at `url` and schedules a save of the file; an unchanged view changes nothing.
    func setView(_ view: RepoViewState, for url: URL) {
        let key = WorkspaceFile.standardized(url.path)
        guard views[key] != view else { return }
        views[key] = view
        SessionStore.schedule()
    }

    /// Points the workspace at `url` after Save As: the resolved paths get fresh strings relative to the new folder,
    /// the missing tabs and carried repos keep their `home` with a `path` from the new folder, and the new file is
    /// writable.
    func rebind(to url: URL) {
        let rebased = WorkspaceFile.rebased(originals: originals, missing: missing, carried: repos, fileURL: url,
                                            homeURL: Self.homeURL)
        self.url = url
        key = WorkspaceFile.identityKey(for: url)
        name = url.deletingPathExtension().lastPathComponent
        originals = rebased.originals
        repos = rebased.carried
        isReadOnly = false
        writeFailed = false
        writeError = nil
    }
}

/// A weak reference to a workspace (`RepoSession.ViewRoute`): a session never keeps its closed workspace alive.
@MainActor
final class WeakWorkspace {
    weak var workspace: Workspace?

    init(_ workspace: Workspace) {
        self.workspace = workspace
    }
}
