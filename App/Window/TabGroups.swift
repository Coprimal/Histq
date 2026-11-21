// Tab groups: the tabs of one repository's worktrees sit side by side in a worktree box, and manual groups (as
// Chrome's) gather tabs and boxes under one color and an optional name.
import Observation
import SwiftUI

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
}

/// A manual tab group of one window (`WindowModel.groups`): its color, an optional name, and whether it is collapsed
/// to its chip.
struct ManualTabGroup: Equatable, Identifiable {
    let id: UUID
    /// The name the user gave it; nil shows just its color.
    var name: String?
    /// Its swatch: 0 is grey, 1–8 a lane color (`Palette.graphLanes`).
    var colorIndex: Int
    var collapsed: Bool
}

/// Two or more neighboring tabs of one repository (`WindowModel.worktreeBoxes`). A repo with a single tab has no box.
struct WorktreeBox: Equatable {
    let key: String
    /// The tabs' indices; the tabs of a repo are always neighbors (`WindowModel.normalize`).
    let range: ClosedRange<Int>
}

/// The neighboring tabs of one manual group (`WindowModel.manualGroups`), with its entry in the group table.
struct TabGroup: Equatable {
    let group: ManualTabGroup
    /// The tabs' indices; a group's tabs are always neighbors (`WindowModel.normalize`).
    let range: ClosedRange<Int>

    var id: UUID { group.id }
    /// The layout's key for the group.
    var key: String { group.id.uuidString }
    /// The group's name; empty when it has none.
    var name: String { group.name ?? "" }

    /// The header's spoken label: "Group Work, 3 tabs" ("Group, 3 tabs" without a name).
    var accessibilityLabel: String {
        let tabs = range.count == 1 ? "1 tab" : "\(range.count) tabs"
        return name.isEmpty ? "Group, \(tabs)" : "Group \(name), \(tabs)"
    }

    /// The header's tooltip: what a click does.
    func help(collapsed: Bool) -> String {
        "\(accessibilityLabel). Click to \(collapsed ? "show" : "hide") its tabs."
    }
}

/// The tabs in order with each manual group's header (the top tabs' chip, the vertical tabs' name row) before its first
/// tab, and where they stand along the row or column: each item's start, the items `gap` apart. A worktree box takes no
/// room of its own: it is drawn around its tabs (`boxSpan`), inside the gaps. Shared by the tab strip and the vertical
/// tabs, so a drag can place every item (and box) where it would stand with the tab dropped at its target.
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
    /// A tab's width (top tabs) or height (vertical tabs) when every tab shares one; `extent(of:)` gives each tab's.
    let tabExtent: CGFloat
    /// Each tab's extent, by index (a pinned top tab is narrower than the others).
    private let extents: [CGFloat]
    let headerExtents: [String: CGFloat]
    let gap: CGFloat
    /// The group of each grouped tab, by index.
    let groupKey: [Int: String]
    /// The collapsed groups (`ManualTabGroup.collapsed`), by key: their header only, their tabs take no room.
    let collapsed: Set<String>
    /// Each group's tab indices, by key.
    private let groupRange: [String: ClosedRange<Int>]
    /// Each group, by key.
    private let groupByKey: [String: TabGroup]
    /// The worktree boxes drawn around their tabs.
    let boxes: [WorktreeBox]

    /// `extent` gives the tab at an index its own extent; without it every tab takes `tabExtent`.
    init(tabs: [WindowModel.Tab], groups: [TabGroup], boxes: [WorktreeBox] = [], tabExtent: CGFloat, gap: CGFloat,
         extent: ((Int) -> CGFloat)? = nil, headerExtent: (TabGroup) -> CGFloat) {
        let collapsed = Set(groups.filter(\.group.collapsed).map(\.key))
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
        extents = tabs.indices.map { extent?($0) ?? tabExtent }
        self.gap = gap
        self.groupKey = groupKey
        self.collapsed = collapsed
        headerExtents = Dictionary(groups.map { ($0.key, headerExtent($0)) }, uniquingKeysWith: { first, _ in first })
        groupRange = Dictionary(groups.map { ($0.key, $0.range) }, uniquingKeysWith: { first, _ in first })
        groupByKey = Dictionary(groups.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        self.boxes = boxes
    }

    /// Where the box's tabs stand at `positions`: from its first tab's start to its last tab's end (its tabs in any
    /// order, so a drag inside the box keeps it whole); nil while a collapsed group hides it (a box is in one group).
    func boxSpan(_ box: WorktreeBox, at positions: Positions) -> (start: CGFloat, end: CGFloat)? {
        if let key = groupKey[box.range.lowerBound], collapsed.contains(key) { return nil }
        let starts = box.range.compactMap { positions.tabs[$0] }
        let ends = box.range.compactMap { index in positions.tabs[index].map { $0 + extent(of: index) } }
        guard let start = starts.min(), let end = ends.max() else { return nil }
        return (start, end)
    }

    /// The manual group the tab at `index` is in; nil for none.
    func group(at index: Int) -> TabGroup? {
        groupKey[index].flatMap { groupByKey[$0] }
    }

    /// The tab at `index`'s width (top tabs) or height (vertical tabs); `tabExtent` outside the tabs.
    func extent(of index: Int) -> CGFloat {
        extents.indices.contains(index) ? extents[index] : tabExtent
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
            x += extent(of: index) + gap
        }
        return positions
    }

    /// From a group's header start to its last tab's end (its header's end when collapsed).
    func span(of key: String) -> CGFloat {
        let range = collapsed.contains(key) ? nil : groupRange[key]
        let tabs = range.map { $0.reduce(0) { $0 + extent(of: $1) + gap } } ?? 0
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

/// A worktree box behind its tabs, drawn at row level (the tab strip's row, the vertical tabs' list) from the layout's
/// target positions, so it moves with its tabs during a drag. The selected tab's shape (`TabSheetShape` along a row,
/// `VerticalTabSheetShape` down a column, flares included) is cut out of it with `Path.subtracting`, so the translucent
/// selected tab never sits on the box's fill. `border` gives the box's 1 pt edge, cut the same way (never the outline
/// of the cut shape). Animatable, so the box follows its tabs and the hole slides with the selected tab.
struct WorktreeBoxShape: Shape {
    enum Axis { case horizontal, vertical }

    let axis: Axis
    /// The box along the axis, in the row's (column's) space.
    var start: CGFloat
    var end: CGFloat
    /// The selected tab's shape along the axis, flares included; empty (`holeEnd <= holeStart`) for none.
    var holeStart: CGFloat
    var holeEnd: CGFloat
    /// The box across the axis: its top (leading edge down a column) in `rect`'s space, and its bottom (trailing edge)
    /// this far inside `rect`'s far side.
    let crossStart: CGFloat
    let crossEndInset: CGFloat
    /// The selected shape across the axis: from here to the far side of `rect` (the tab's bottom along a row, the
    /// sheet's edge down a column); a row's starts at `rect`'s top.
    let holeCrossStart: CGFloat
    let radius: CGFloat
    /// The selected shape's rounded corners and flares.
    let holeRadius: CGFloat
    let flare: CGFloat
    var border = false

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(start, end), AnimatablePair(holeStart, holeEnd)) }
        set {
            start = newValue.first.first
            end = newValue.first.second
            holeStart = newValue.second.first
            holeEnd = newValue.second.second
        }
    }

    /// The same box's edge.
    var edge: WorktreeBoxShape {
        var shape = self
        shape.border = true
        return shape
    }

    func path(in rect: CGRect) -> Path {
        let box = axis == .horizontal
            ? CGRect(x: start, y: crossStart, width: end - start, height: rect.maxY - crossEndInset - crossStart)
            : CGRect(x: crossStart, y: start, width: rect.maxX - crossEndInset - crossStart, height: end - start)
        guard box.width > 0, box.height > 0 else { return Path() }
        let shape: Path
        if border {
            // The edge inside the box, so cutting it keeps exactly the part on the shown box.
            let inner = box.insetBy(dx: 1, dy: 1)
            shape = Path(roundedRect: box, cornerRadius: radius, style: .continuous)
                .subtracting(Path(roundedRect: inner, cornerRadius: max(radius - 1, 0), style: .continuous))
        } else {
            shape = Path(roundedRect: box, cornerRadius: radius, style: .continuous)
        }
        guard holeEnd > holeStart else { return shape }
        let hole = axis == .horizontal
            ? CGRect(x: holeStart, y: rect.minY, width: holeEnd - holeStart, height: rect.height)
            : CGRect(x: holeCrossStart, y: holeStart, width: rect.maxX - holeCrossStart, height: holeEnd - holeStart)
        guard hole.intersects(box) else { return shape }
        let selected = axis == .horizontal
            ? TabSheetShape(radius: holeRadius, flare: flare).path(in: hole)
            : VerticalTabSheetShape(radius: holeRadius, flare: flare).path(in: hole)
        return shape.subtracting(selected)
    }
}
