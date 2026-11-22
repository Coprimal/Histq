// The saved shape of the open windows and their app tabs: `session.json` (the app's `SessionStore`). Plain values, so
// the file format lives beside the code that will read and write workspace files.
import Foundation

/// What the last run had open: one entry per document window, front group first.
public struct SavedSession: Codable, Equatable, Sendable {
    /// The file format; a file of another version is ignored.
    public static let currentVersion = 1

    public var version = Self.currentVersion
    /// The Untitled windows: those in no workspace.
    public var windows: [SavedWindow]
    /// The layouts of open and recently closed workspaces, one per file; nil when none, so the key stays absent.
    /// Absent from files of older builds.
    public var workspaces: [WorkspaceLayout]?

    public init(version: Int = Self.currentVersion, windows: [SavedWindow], workspaces: [WorkspaceLayout]? = nil) {
        self.version = version
        self.windows = windows
        self.workspaces = workspaces
    }

    /// The session as read: one workspace layout per `path` (the first kept), and nil for an empty list.
    public func normalized() -> SavedSession {
        var paths = Set<String>()
        let layouts = workspaces?.filter { paths.insert($0.path).inserted }
        return SavedSession(version: version, windows: windows, workspaces: layouts?.isEmpty == false ? layouts : nil)
    }

    /// The windows by native tab group, groups front first, each group in its tab order.
    public var groups: [[SavedWindow]] {
        Set(windows.map(\.group)).sorted().map { group in
            windows.filter { $0.group == group }.sorted { $0.tabIndex < $1.tabIndex }
        }
    }

    /// Whether `path` still opens as a repo: a folder inside a work tree (`.git` is a folder, or a file for a linked
    /// worktree or a submodule, in it or in a parent), or a bare repository. File checks only, no git.
    public static func isRepository(_ path: String) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        let folder = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let bare = ["HEAD", "objects", "refs"].allSatisfy { fm.fileExists(atPath: folder.appending(path: $0).path) }
        if bare { return true }
        var current = folder
        while true {
            if fm.fileExists(atPath: current.appending(path: ".git").path) { return true }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return false }
            current = parent
        }
    }
}

/// A document window: its frame, its place in a native tab group, and its app tabs.
public struct SavedWindow: Codable, Equatable, Sendable {
    /// Screen points, origin at the bottom left (`NSWindow.frame`).
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Windows with the same group are native tabs of one window; groups are numbered front to back.
    public var group: Int
    /// The window's place in its group's tab bar.
    public var tabIndex: Int
    /// The native tab its group shows.
    public var isSelectedInGroup: Bool
    public var tabs: [SavedTab]
    /// The selected app tab's index.
    public var selectedTab: Int?
    /// The window's manual tab groups, in order; nil when it has none. Absent from files of older builds.
    public var manualTabGroups: [SavedTabGroup]?
    /// The window's closed groups (a group's Close Group), most recently closed first; nil when it has none. Absent
    /// from files of older builds.
    public var closedTabGroups: [SavedClosedTabGroup]?

    public init(x: Double, y: Double, width: Double, height: Double, group: Int, tabIndex: Int,
                isSelectedInGroup: Bool, tabs: [SavedTab], selectedTab: Int? = nil,
                manualTabGroups: [SavedTabGroup]? = nil, closedTabGroups: [SavedClosedTabGroup]? = nil) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.group = group
        self.tabIndex = tabIndex
        self.isSelectedInGroup = isSelectedInGroup
        self.tabs = tabs
        self.selectedTab = selectedTab
        self.manualTabGroups = manualTabGroups
        self.closedTabGroups = closedTabGroups
    }
}

/// An app tab: a repo folder with its profile, or a Welcome tab.
public struct SavedTab: Codable, Equatable, Sendable {
    /// The repo folder; nil for a Welcome tab.
    public var path: String?
    /// The tab's profile as chosen in that session; nil when it was not known yet (the repo then resolves its own,
    /// as a new tab does).
    public var profile: SavedProfile?
    /// The tab's alias (its menu's Set Alias…); nil shows the folder's name. Absent from files of older builds.
    public var alias: String?
    /// The tab's emoji (its menu's Set Emoji…); nil shows none. Absent from files of older builds.
    public var emoji: String?
    /// The tab is pinned; nil reads as false, and an unpinned tab is written as nil so files stay small. Absent from
    /// files of older builds.
    public var pinned: Bool?
    /// The tab's book icon color (its menu's Icon Color), an index into `Palette.graphLanes`; nil for the default.
    /// Absent from files of older builds.
    public var iconColor: Int?
    /// The tab is in the window's archive (its menu's Archive This Tab); nil reads as false, and a tab not archived is
    /// written as nil. Archived entries come after every other tab; the selected one is the tab popped out beside the
    /// archive button. Absent from files of older builds.
    public var archived: Bool?
    /// The manual group it is in (`SavedWindow.manualTabGroups`); nil for none. Absent from files of older builds.
    public var tabGroup: UUID?

    public init(path: String? = nil, profile: SavedProfile? = nil, alias: String? = nil, emoji: String? = nil,
                pinned: Bool? = nil, iconColor: Int? = nil, archived: Bool? = nil, tabGroup: UUID? = nil) {
        self.path = path
        self.profile = profile
        self.alias = alias
        self.emoji = emoji
        self.pinned = pinned
        self.iconColor = iconColor
        self.archived = archived
        self.tabGroup = tabGroup
    }

    /// The alias, else the repo folder's name, or "New Tab" for a Welcome tab: an archived tab's row in the archive's
    /// list.
    public var title: String {
        alias ?? path.map { URL(fileURLWithPath: $0, isDirectory: true).lastPathComponent } ?? "New Tab"
    }
}

/// A manual tab group of a window. Absent from files of older builds.
public struct SavedTabGroup: Codable, Equatable, Sendable {
    public var id: UUID
    /// The name the user gave it; nil for none.
    public var name: String?
    /// Its swatch: 0 is grey, 1–8 a lane color (`Palette.graphLanes`); clamped to 0...8 on restore.
    public var color: Int
    /// The group shows only its chip; nil reads as false, and an expanded group is written as nil.
    public var collapsed: Bool?

    public init(id: UUID, name: String? = nil, color: Int, collapsed: Bool? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.collapsed = collapsed
    }
}

/// A manual tab group stowed by its Close Group, with its tabs, until it opens again. Absent from files of older
/// builds.
public struct SavedClosedTabGroup: Codable, Equatable, Sendable {
    public var id: UUID
    /// The name the user gave it; nil for none.
    public var name: String?
    /// Its swatch, as `SavedTabGroup.color`; clamped to 0...8 on restore.
    public var color: Int
    /// Its tabs in order, each with `tabGroup`, `pinned` and `archived` nil.
    public var tabs: [SavedTab]

    public init(id: UUID, name: String? = nil, color: Int, tabs: [SavedTab]) {
        self.id = id
        self.name = name
        self.color = color
        self.tabs = tabs
    }
}

/// A tab's profile choice. Stored as one string: a profile id, or "none" (git uses the user's own config).
public enum SavedProfile: Codable, Equatable, Sendable {
    case none
    case id(UUID)

    public var profileID: UUID? {
        if case .id(let id) = self { id } else { nil }
    }

    public init(_ profileID: UUID?) {
        self = profileID.map(Self.id) ?? .none
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        self = UUID(uuidString: text).map(Self.id) ?? .none
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(profileID?.uuidString ?? "none")
    }
}
