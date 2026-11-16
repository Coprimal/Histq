// Tab groups (as Chrome's): the tabs of one repository's worktrees sit side by side, under the repo's name and one color.
import Foundation

/// The repository a folder belongs to: its git common dir, which all its worktrees share. Read from the folder's `.git`
/// (the repo's own folder, or a worktree's `gitdir:` file and that dir's `commondir`): small files, read off the main
/// thread by `WindowModel`.
enum RepoGroupKey {
    /// The folder's common dir as a path; nil when the folder has no `.git` that can be read.
    static func of(_ folder: URL) -> String? {
        let dotGit = folder.appending(path: ".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit.resolvingSymlinksInPath().path }
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:")
        else { return nil }
        let gitDirPath = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let gitDir = URL(filePath: gitDirPath, directoryHint: .isDirectory, relativeTo: folder).absoluteURL
        guard let common = try? String(contentsOf: gitDir.appending(path: "commondir"), encoding: .utf8)
        else { return gitDir.resolvingSymlinksInPath().path }
        let commonPath = common.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(filePath: commonPath, directoryHint: .isDirectory, relativeTo: gitDir).absoluteURL
            .resolvingSymlinksInPath().path
    }

    /// The group's name: the main worktree's folder (`…/graph/.git` → "graph"), or a bare repo's (`graph.git`).
    static func name(of key: String) -> String {
        let url = URL(filePath: key)
        if url.lastPathComponent == ".git" { return url.deletingLastPathComponent().lastPathComponent }
        let name = url.lastPathComponent
        return name.hasSuffix(".git") ? String(name.dropLast(4)) : name
    }

    /// The group's color, an index into `Palette.graphLanes`: the same for a repo at every launch (FNV-1a of the key;
    /// `hashValue` changes per launch).
    static func colorIndex(of key: String, count: Int) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return Int(hash % UInt64(max(count, 1)))
    }
}

/// Two or more neighboring tabs of one repository (`WindowModel.tabGroups`). A repo with a single tab has no group.
struct TabGroup: Equatable {
    let key: String
    /// The tabs' indices; the tabs of a repo are always neighbors (`WindowModel.gatherGroups`).
    let range: ClosedRange<Int>
    var name: String { RepoGroupKey.name(of: key) }
}

/// The tabs in order with each group's header (the top tabs' chip, the vertical tabs' name row) before its first tab,
/// and where they stand along the row or column: each item's start, the items `gap` apart. Shared by the tab strip and
/// the vertical tabs, so a drag can place every item where it would stand with the tab dropped at its target.
struct TabGroupLayout {
    enum Item: Identifiable {
        case header(TabGroup)
        case tab(Int, WindowModel.Tab)

        var id: AnyHashable {
            switch self {
            case .header(let group): "group \(group.key)"
            case .tab(_, let tab): tab.id
            }
        }
    }

    struct Positions {
        var tabs: [Int: CGFloat] = [:]
        var headers: [String: CGFloat] = [:]
    }

    let items: [Item]
    /// A tab's width (top tabs) or height (vertical tabs).
    let tabExtent: CGFloat
    let headerExtents: [String: CGFloat]
    let gap: CGFloat
    /// The group of each grouped tab, by index.
    let groupKey: [Int: String]
    /// The collapsed groups (`WindowModel.collapsedGroups`): their header only, their tabs take no room.
    let collapsed: Set<String>
    /// Each group's tab count, by key.
    private let groupSize: [String: Int]

    init(tabs: [WindowModel.Tab], groups: [TabGroup], collapsed: Set<String>, tabExtent: CGFloat, gap: CGFloat,
         headerExtent: (TabGroup) -> CGFloat) {
        var items: [Item] = []
        var groupKey: [Int: String] = [:]
        for (index, tab) in tabs.enumerated() {
            if let group = groups.first(where: { $0.range.contains(index) }) {
                if group.range.lowerBound == index { items.append(.header(group)) }
                groupKey[index] = group.key
                if collapsed.contains(group.key) { continue }
            }
            items.append(.tab(index, tab))
        }
        self.items = items
        self.tabExtent = tabExtent
        self.gap = gap
        self.groupKey = groupKey
        self.collapsed = collapsed
        headerExtents = Dictionary(groups.map { ($0.key, headerExtent($0)) }, uniquingKeysWith: { first, _ in first })
        groupSize = Dictionary(groups.map { ($0.key, $0.range.count) }, uniquingKeysWith: { first, _ in first })
    }

    /// The tab indices in order with the tab at `from` dropped at `to` (its index once moved).
    static func moved(_ count: Int, _ from: Int, _ to: Int) -> [Int] {
        var order = Array(0..<count)
        guard order.indices.contains(from), order.indices.contains(to) else { return order }
        order.insert(order.remove(at: from), at: to)
        return order
    }

    /// Where the tabs and headers stand with the tabs in `order` (a group's tabs stay neighbors in every allowed order).
    func positions(order: [Int]) -> Positions {
        var positions = Positions()
        var x: CGFloat = 0
        var previous: String?
        for index in order {
            let key = groupKey[index]
            if let key, key != previous {
                positions.headers[key] = x
                x += (headerExtents[key] ?? 0) + gap
            }
            previous = key
            positions.tabs[index] = x
            // A collapsed group's tabs stand at its header's end, with no room.
            if let key, collapsed.contains(key) { continue }
            x += tabExtent + gap
        }
        return positions
    }

    /// From a group's header start to its last tab's end (its header's end when collapsed).
    func span(of key: String) -> CGFloat {
        let tabs = collapsed.contains(key) ? 0 : CGFloat(groupSize[key] ?? 0) * (tabExtent + gap)
        return (headerExtents[key] ?? 0) + tabs
    }

    /// The allowed drop index (`destinations`) where the tab at `from` would stand nearest `from`'s start moved by
    /// `translation`.
    func nearestDestination(from: Int, count: Int, translation: CGFloat, destinations: [Int]) -> Int {
        let pointer = (positions(order: Array(0..<count)).tabs[from] ?? 0) + translation
        let distances = destinations.map { destination in
            (destination, abs((positions(order: Self.moved(count, from, destination)).tabs[from] ?? 0) - pointer))
        }
        return distances.min { $0.1 < $1.1 }?.0 ?? from
    }
}
