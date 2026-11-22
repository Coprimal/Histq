// A workspace file (`*.histqworkspace`): a working set of windows, their app tabs, the profiles those tabs use and each
// repo's graph view. Paths are stored twice: `path` relative to the file's folder and `home` in the `~/…` form, so
// the file opens on another Mac or after a move. The app works with absolute paths: `resolved` maps the file to them,
// `init(windows:…)` maps them back, reusing the stored strings of every path the file already had, so an unchanged
// workspace encodes to the same model on every launch and every Mac. Files can come from a download or a cloned
// repo: nothing read here is trusted, and a path only counts when the caller's `isRepository` holds.
import Foundation

public struct WorkspaceFile: Codable, Sendable, Equatable {
    /// The file format; a file of another version is refused.
    public static let currentVersion = 1

    public var version: Int
    public var windows: [Window]
    public var repos: [Repo]
    public var profiles: [Profile]

    public init(version: Int = Self.currentVersion, windows: [Window], repos: [Repo] = [], profiles: [Profile] = []) {
        self.version = version
        self.windows = windows
        self.repos = repos
        self.profiles = profiles
    }

    /// A window: its manual tab groups (nil when none) and its app tabs, archived ones last.
    public struct Window: Codable, Sendable, Equatable {
        public var id: UUID
        public var tabGroups: [TabGroup]?
        public var tabs: [Tab]

        public init(id: UUID, tabGroups: [TabGroup]? = nil, tabs: [Tab]) {
            self.id = id
            self.tabGroups = tabGroups
            self.tabs = tabs
        }
    }

    /// A manual tab group. Whether it is collapsed is machine-local (`WorkspaceLayout.Window.collapsedGroups`).
    public struct TabGroup: Codable, Sendable, Equatable {
        public var id: UUID
        public var name: String?
        /// 0 is grey, 1–8 a lane color, as `SavedTabGroup.color`.
        public var color: Int

        public init(id: UUID, name: String? = nil, color: Int) {
            self.id = id
            self.name = name
            self.color = color
        }
    }

    /// An app tab, as `SavedTab` with the repo stored as `path` / `home`; both nil for a Welcome tab.
    public struct Tab: Codable, Sendable, Equatable {
        public var path: String?
        public var home: String?
        public var profile: SavedProfile?
        public var alias: String?
        public var emoji: String?
        public var pinned: Bool?
        public var iconColor: Int?
        public var archived: Bool?
        /// The id of its window's manual tab group; nil for none.
        public var group: UUID?

        public init(path: String? = nil, home: String? = nil, profile: SavedProfile? = nil, alias: String? = nil,
                    emoji: String? = nil, pinned: Bool? = nil, iconColor: Int? = nil, archived: Bool? = nil,
                    group: UUID? = nil) {
            self.path = path
            self.home = home
            self.profile = profile
            self.alias = alias
            self.emoji = emoji
            self.pinned = pinned
            self.iconColor = iconColor
            self.archived = archived
            self.group = group
        }
    }

    /// A repo's graph view.
    public struct Repo: Codable, Sendable, Equatable {
        public var path: String?
        public var home: String?
        public var view: RepoViewState?

        public init(path: String? = nil, home: String? = nil, view: RepoViewState? = nil) {
            self.path = path
            self.home = home
            self.view = view
        }
    }

    /// A window with absolute paths, as the app holds it: what `resolved` returns and `init(windows:…)` takes.
    public struct LiveWindow: Sendable, Equatable {
        public var id: UUID
        public var tabGroups: [TabGroup]?
        /// The tabs with absolute repo paths (`tabGroup` is the tab's `group`).
        public var tabs: [SavedTab]

        public init(id: UUID, tabGroups: [TabGroup]? = nil, tabs: [SavedTab]) {
            self.id = id
            self.tabGroups = tabGroups
            self.tabs = tabs
        }
    }

    /// The `path` / `home` strings a tab or repo was stored with.
    public struct Original: Sendable, Equatable {
        public var path: String?
        public var home: String?

        public init(path: String?, home: String?) {
            self.path = path
            self.home = home
        }
    }

    public enum FileError: Error, Equatable {
        /// The file is not a workspace this build can decode.
        case undecodable
        /// The file has another `version`.
        case unsupportedVersion(Int)
        /// A workspace is never written with no window, or with a window that has no tab.
        case empty
    }

    // MARK: - Identity

    /// The one key of a workspace file: `realpath(3)` of the file when it exists, else `realpath(3)` of its folder plus
    /// its name, so a symlink, `/tmp` and `/private/tmp`, and the file before and after it is created share one key.
    public static func identityKey(for url: URL) -> String {
        let path = standardized(url.path(percentEncoded: false))
        if let real = realPath(path) { return real }
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        return ((realPath(folder) ?? folder) as NSString).appendingPathComponent(name)
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - Reading

    /// A decoded file and whether this build keeps everything in it.
    public struct Read: Sendable, Equatable {
        public var file: WorkspaceFile
        /// False when re-encoding drops a key the file has (a later build's field): the workspace opens read-only.
        public var isLossless: Bool

        public init(file: WorkspaceFile, isLossless: Bool) {
            self.file = file
            self.isLossless = isLossless
        }
    }

    /// Reads the file at `url`. Throws `FileError.unsupportedVersion` for another version and `.undecodable` for
    /// anything else that is not a workspace; duplicate ids in the file are normalized (see `normalized()`).
    public static func read(_ url: URL) throws -> Read {
        let data = try Data(contentsOf: url)
        struct Probe: Decodable { var version: Int }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else { throw FileError.undecodable }
        guard probe.version == currentVersion else { throw FileError.unsupportedVersion(probe.version) }
        guard let file = try? JSONDecoder().decode(WorkspaceFile.self, from: data),
              let original = try? JSONSerialization.jsonObject(with: data),
              let encoded = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(file))
        else { throw FileError.undecodable }
        return Read(file: file.normalized(), isLossless: keeps(original, in: encoded))
    }

    /// Whether every key of `original` (a `null` value counts as absent) is in `encoded`, through objects and arrays.
    private static func keeps(_ original: Any, in encoded: Any) -> Bool {
        if let object = original as? [String: Any] {
            guard let other = encoded as? [String: Any] else { return false }
            return object.allSatisfy { key, value in
                if value is NSNull { return true }
                guard let kept = other[key] else { return false }
                return keeps(value, in: kept)
            }
        }
        if let array = original as? [Any] {
            guard let other = encoded as? [Any], other.count == array.count else { return false }
            return zip(array, other).allSatisfy { keeps($0, in: $1) }
        }
        return true
    }

    /// The file with untrusted duplicates removed: the first profile of an id, a fresh id for a window whose id an
    /// earlier window has, the first tab group of an id within a window.
    private func normalized() -> WorkspaceFile {
        var copy = self
        var profileIDs = Set<UUID>()
        copy.profiles = profiles.filter { profileIDs.insert($0.id).inserted }
        var windowIDs = Set<UUID>()
        for index in copy.windows.indices {
            if !windowIDs.insert(copy.windows[index].id).inserted {
                copy.windows[index].id = UUID()
                windowIDs.insert(copy.windows[index].id)
            }
            var groupIDs = Set<UUID>()
            copy.windows[index].tabGroups = copy.windows[index].tabGroups?.filter { groupIDs.insert($0.id).inserted }
        }
        return copy
    }

    // MARK: - Resolving

    /// The file in absolute paths. Every key is standardized (`standardized(_:)`).
    public struct Resolved: Sendable, Equatable {
        /// The windows in file order.
        public var windows: [LiveWindow]
        /// The views of the repos that resolved, by absolute path; a repo stored without a view reads as `.empty`.
        public var views: [String: RepoViewState]
        /// The absolute paths of the tabs that did not resolve ("Repo not found").
        public var missing: Set<String>
        /// The `repos[]` entries that did not resolve, by absolute path, written back verbatim.
        public var carried: [String: Repo]
        /// The stored strings of every tab and repo by the absolute path it resolved to, or its missing key.
        public var originals: [String: Original]
        /// The absolute path of each `repos[]` entry, in file order.
        public var repoOrder: [String]
        /// The profile ids in file order.
        public var profileOrder: [UUID]

        public init(windows: [LiveWindow], views: [String: RepoViewState], missing: Set<String>,
                    carried: [String: Repo], originals: [String: Original], repoOrder: [String],
                    profileOrder: [UUID]) {
            self.windows = windows
            self.views = views
            self.missing = missing
            self.carried = carried
            self.originals = originals
            self.repoOrder = repoOrder
            self.profileOrder = profileOrder
        }
    }

    /// Maps the file saved at `fileURL` to absolute paths: `path` first (relative to the file's folder), then `home`
    /// (`~` meaning `homeURL`); a candidate counts only when `isRepository` holds. A tab or repo where neither holds is
    /// missing, keyed by its expanded `home` when it has one, else by its `path` against the file's folder.
    public func resolved(fileURL: URL, homeURL: URL, isRepository: (String) -> Bool) -> Resolved {
        let base = Base(fileURL: fileURL, homeURL: homeURL)
        let file = normalized()
        var originals: [String: Original] = [:]
        var missing = Set<String>()

        /// The absolute path of a stored pair and whether it resolved; nil when it names no path at all.
        func resolve(path: String?, home: String?) -> (key: String, found: Bool)? {
            let candidates = [path.map(base.fromPath), home.flatMap(base.fromHome)].compactMap { $0 }
            let key = candidates.first(where: isRepository).map { ($0, true) }
                ?? base.missingKey(path: path, home: home).map { ($0, false) }
            if let key, originals[key.0] == nil { originals[key.0] = Original(path: path, home: home) }
            return key
        }

        let windows = file.windows.map { window in
            LiveWindow(id: window.id, tabGroups: window.tabGroups, tabs: window.tabs.map { tab in
                let key = resolve(path: tab.path, home: tab.home)
                if let key, !key.found { missing.insert(key.key) }
                return SavedTab(path: key?.key, profile: tab.profile, alias: tab.alias, emoji: tab.emoji,
                                pinned: tab.pinned, iconColor: tab.iconColor, archived: tab.archived,
                                tabGroup: tab.group)
            })
        }

        var views: [String: RepoViewState] = [:]
        var carried: [String: Repo] = [:]
        var repoOrder: [String] = []
        for repo in file.repos {
            guard let key = resolve(path: repo.path, home: repo.home),
                  views[key.key] == nil, carried[key.key] == nil else { continue }
            repoOrder.append(key.key)
            if key.found {
                views[key.key] = repo.view ?? .empty
            } else {
                carried[key.key] = repo
            }
        }

        return Resolved(windows: windows, views: views, missing: missing, carried: carried, originals: originals,
                        repoOrder: repoOrder, profileOrder: file.profiles.map(\.id))
    }

    // MARK: - Building

    /// Builds the file saved at `fileURL` from absolute paths. A path in `originals` keeps its stored strings; any
    /// other gets fresh ones: `path` relative to the file's folder, `home` as `~/…` under `homeURL`, else absolute.
    /// `repos` holds one entry per key of `views` and `carried` (a live view wins), in `repoOrder`, new ones appended
    /// sorted by `path`; `profiles` follow `profileOrder`, new ones appended sorted by id.
    public init(windows: [LiveWindow], views: [String: RepoViewState], profiles: [Profile],
                carried: [String: Repo], originals: [String: Original], repoOrder: [String], profileOrder: [UUID],
                fileURL: URL, homeURL: URL) {
        let base = Base(fileURL: fileURL, homeURL: homeURL)

        func stored(_ absolute: String) -> Original {
            originals[Self.standardized(absolute)] ?? base.fresh(Self.standardized(absolute))
        }

        let windows = windows.map { window in
            Window(id: window.id, tabGroups: window.tabGroups?.isEmpty == false ? window.tabGroups : nil,
                   tabs: window.tabs.map { tab in
                       let strings = tab.path.map(stored)
                       return Tab(path: strings?.path, home: strings?.home, profile: tab.profile, alias: tab.alias,
                                  emoji: tab.emoji, pinned: tab.pinned, iconColor: tab.iconColor,
                                  archived: tab.archived, group: tab.tabGroup)
                   })
        }

        var repos: [String: Repo] = [:]
        for (key, repo) in carried { repos[Self.standardized(key)] = repo }
        for (key, view) in views {
            let strings = stored(key)
            repos[Self.standardized(key)] = Repo(path: strings.path, home: strings.home, view: view)
        }
        var ordered: [Repo] = []
        for key in repoOrder {
            if let repo = repos.removeValue(forKey: Self.standardized(key)) { ordered.append(repo) }
        }
        ordered += repos.values.sorted { ($0.path ?? "", $0.home ?? "") < ($1.path ?? "", $1.home ?? "") }

        var byID: [UUID: Profile] = [:]
        for profile in profiles where byID[profile.id] == nil { byID[profile.id] = profile }
        var orderedProfiles: [Profile] = []
        for id in profileOrder {
            if let profile = byID.removeValue(forKey: id) { orderedProfiles.append(profile) }
        }
        orderedProfiles += byID.values.sorted { $0.id.uuidString < $1.id.uuidString }

        self.init(windows: windows, repos: ordered, profiles: orderedProfiles)
    }

    /// The stored strings for a workspace saved again at `fileURL` (Save As): the entries of resolved paths are dropped
    /// (they get fresh strings), and each missing tab and carried repo keeps its `home` and gets a `path` from its
    /// absolute path relative to the new folder. Only the keys in `missing` stay in `originals`.
    public static func rebased(originals: [String: Original], missing: Set<String>, carried: [String: Repo],
                               fileURL: URL, homeURL: URL) -> (originals: [String: Original], carried: [String: Repo]) {
        let base = Base(fileURL: fileURL, homeURL: homeURL)
        var newOriginals: [String: Original] = [:]
        for (key, original) in originals where missing.contains(key) {
            newOriginals[key] = Original(path: base.relative(key), home: original.home)
        }
        var newCarried: [String: Repo] = [:]
        for (key, repo) in carried {
            newCarried[key] = Repo(path: base.relative(key), home: repo.home, view: repo.view)
        }
        return (newOriginals, newCarried)
    }

    // MARK: - Writing

    /// Writes the file to `url`, or to its target when `url` is a symlink, atomically (a temp file in the same folder,
    /// then `rename(2)`) with mode 600. Throws `FileError.empty` for no window or a window with no tab.
    public func write(to url: URL) throws {
        guard !windows.isEmpty, windows.allSatisfy({ !$0.tabs.isEmpty }) else { throw FileError.empty }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        let file = URL(fileURLWithPath: Self.identityKey(for: url), isDirectory: false)
        let temp = file.deletingLastPathComponent()
            .appending(path: ".\(file.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path]) }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temp.path, file.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
            }
        } catch {
            unlink(temp.path)
            throw error
        }
    }

    // MARK: - Paths

    /// The one form of every absolute key: no `.` or `..`, no trailing slash.
    public static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    /// The file's folder and the home folder, for mapping stored strings to absolute paths and back. The folder is the
    /// lexical (standardized, not `realpath(3)`) parent of the file after following only the file's own symlinks, so a
    /// symlinked file uses its target's folder and resolved keys stay in the app's path space when an ancestor folder
    /// is a symlink.
    private struct Base {
        let folder: String
        let home: String

        init(fileURL: URL, homeURL: URL) {
            var path = WorkspaceFile.standardized(fileURL.path(percentEncoded: false))
            for _ in 0..<16 {
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { break }
                let linkFolder = (path as NSString).deletingLastPathComponent
                path = target.hasPrefix("/") ? WorkspaceFile.standardized(target) : Self.joined(linkFolder, target)
            }
            folder = WorkspaceFile.standardized((path as NSString).deletingLastPathComponent)
            home = WorkspaceFile.standardized(homeURL.path(percentEncoded: false))
        }

        /// A stored `path`: `~` is the home folder, an absolute path stays, anything else is under the file's folder.
        func fromPath(_ path: String) -> String {
            if path == "~" || path.hasPrefix("~/") { return fromHome(path) ?? folder }
            return path.hasPrefix("/") ? WorkspaceFile.standardized(path) : Self.joined(folder, path)
        }

        /// `relative` under `folder` by path components, a `..` dropping the last one as written: `standardized(_:)`
        /// alone would follow the folder's symlinks before a `..`.
        private static func joined(_ folder: String, _ relative: String) -> String {
            var parts = URL(fileURLWithPath: folder, isDirectory: true).pathComponents
            for part in relative.split(separator: "/") {
                switch part {
                case ".": continue
                case "..": if parts.count > 1 { parts.removeLast() }
                default: parts.append(String(part))
                }
            }
            return WorkspaceFile.standardized(NSString.path(withComponents: parts))
        }

        /// A stored `home`: only `~`, `~/…` or an absolute path; nil for anything else.
        func fromHome(_ home: String) -> String? {
            if home == "~" { return self.home }
            if home.hasPrefix("~/") { return WorkspaceFile.standardized(self.home + home.dropFirst(1)) }
            if home.hasPrefix("/") { return WorkspaceFile.standardized(home) }
            return nil
        }

        func missingKey(path: String?, home: String?) -> String? {
            home.flatMap(fromHome) ?? path.map(fromPath)
        }

        /// Fresh strings for an absolute path.
        func fresh(_ absolute: String) -> Original {
            Original(path: relative(absolute), home: tilde(absolute))
        }

        /// `absolute` relative to the file's folder, by path components; `.` for the folder itself. The standardized
        /// forms are compared, so a symlink inside the shared tree is kept as written. Only when they share nothing
        /// but `/` (two path spaces, as a symlinked prefix on one side) are their `realpath(3)`s compared instead,
        /// when both exist and share more than `/`.
        func relative(_ absolute: String) -> String {
            let target = WorkspaceFile.standardized(absolute)
            let lexical = Self.relative(from: folder, to: target)
            guard lexical.common <= 1, let realFolder = WorkspaceFile.realPath(folder),
                  let realTarget = WorkspaceFile.realPath(target) else { return lexical.path }
            let real = Self.relative(from: realFolder, to: realTarget)
            return real.common > 1 ? real.path : lexical.path
        }

        /// The relative path and the number of leading components (`/` included) both sides share.
        private static func relative(from folder: String, to target: String) -> (path: String, common: Int) {
            let from = URL(fileURLWithPath: folder, isDirectory: true).pathComponents
            let to = URL(fileURLWithPath: target, isDirectory: true).pathComponents
            var common = 0
            while common < from.count, common < to.count, from[common] == to[common] { common += 1 }
            let parts = Array(repeating: "..", count: from.count - common) + to[common...]
            return (parts.isEmpty ? "." : parts.joined(separator: "/"), common)
        }

        /// `absolute` as `~/…` when it is in the home folder, else as it is.
        func tilde(_ absolute: String) -> String {
            let from = URL(fileURLWithPath: home, isDirectory: true).pathComponents
            let to = URL(fileURLWithPath: absolute, isDirectory: true).pathComponents
            guard home != "/", to.count >= from.count, Array(to[..<from.count]) == from else { return absolute }
            let rest = to[from.count...]
            return rest.isEmpty ? "~" : "~/" + rest.joined(separator: "/")
        }
    }
}

/// The machine-local layout of an open or recently closed workspace, kept in `session.json`: window frames, native
/// tab groups, selection and collapsed manual groups, so arranging windows never rewrites the shared file.
public struct WorkspaceLayout: Codable, Equatable, Sendable {
    /// The workspace file's identity key (`WorkspaceFile.identityKey(for:)`).
    public var path: String
    /// The workspace was open when the app quit, so the next launch reopens it.
    public var open: Bool
    public var windows: [Window]

    public init(path: String, open: Bool, windows: [Window]) {
        self.path = path
        self.open = open
        self.windows = windows
    }

    /// A workspace window by its id in the file.
    public struct Window: Codable, Equatable, Sendable {
        public var id: UUID
        /// Screen points, origin at the bottom left, as `SavedWindow`.
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        /// The native tab group, numbered with the Untitled windows' groups.
        public var group: Int
        public var tabIndex: Int
        public var isSelectedInGroup: Bool
        /// The selected tab's absolute repo path; nil for a Welcome tab or none.
        public var selectedPath: String?
        /// The ids of the window's collapsed manual tab groups; nil when none.
        public var collapsedGroups: [UUID]?

        public init(id: UUID, x: Double, y: Double, width: Double, height: Double, group: Int, tabIndex: Int,
                    isSelectedInGroup: Bool, selectedPath: String? = nil, collapsedGroups: [UUID]? = nil) {
            self.id = id
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.group = group
            self.tabIndex = tabIndex
            self.isSelectedInGroup = isSelectedInGroup
            self.selectedPath = selectedPath
            self.collapsedGroups = collapsedGroups
        }
    }
}
