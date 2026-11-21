// Tab groups: the tabs of one repository's worktrees sit side by side in a worktree box, and manual groups (as
// Chrome's) gather tabs and boxes under one color and an optional name.
import HistqCore
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
        /// Each group's last tab's end (its header's end when collapsed); set by `positions(order:moving:membership:)`.
        var ends: [String: CGFloat] = [:]
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

    // MARK: Dragging a unit

    // A drag moves a `TabArrangement.Unit`: a tab, a whole worktree box or a whole group. `entries` are the tabs as
    // `TabArrangement` sees them, in order: `entries[i]` is the tab at index `i`. An index is where the unit's first
    // tab stands once moved, as `TabArrangement.destinations(for:targetGroup:in:)` and `move(unit:to:group:in:)` read
    // it.

    /// The tab indices of `unit` (always neighbors); nil when it has none.
    static func range(of unit: TabArrangement.Unit, in entries: [TabArrangement.Entry]) -> ClosedRange<Int>? {
        let indices = entries.indices.filter { index in
            let entry = entries[index]
            switch unit {
            case .tab(let id): return entry.id == id
            case .box(let repo): return entry.repo == repo && !entry.archived
            case .group(let id): return entry.group == id && !entry.pinned && !entry.archived
            }
        }
        guard let first = indices.first, let last = indices.last else { return nil }
        return first...last
    }

    /// The tab indices in order with the tabs at `range` (a unit's) dropped at `destination`, their first tab's index
    /// once moved.
    static func moved(_ count: Int, _ range: ClosedRange<Int>, to destination: Int) -> [Int] {
        var order = Array(0..<count)
        guard range.lowerBound >= 0, range.upperBound < count, (0...(count - range.count)).contains(destination)
        else { return order }
        order.removeSubrange(range)
        order.insert(contentsOf: range, at: destination)
        return order
    }

    /// Where the tabs and headers stand with the tabs in `order` and the tabs at `moving` (the dragged unit's) in the
    /// group `membership` (pass `dragTarget`'s group; `moving: nil` at rest). A group left with no tab (its only unit
    /// dragged into another group) has no header position: it would go.
    func positions(order: [Int], moving: ClosedRange<Int>?, membership: UUID?) -> Positions {
        var positions = Positions()
        var x: CGFloat = 0
        var previous: String?
        for index in order {
            let key = moving?.contains(index) == true ? membership?.uuidString : groupKey[index]
            if let key, key != previous {
                positions.headers[key] = x
                x += (headerExtents[key] ?? 0) + gap
            }
            previous = key
            positions.tabs[index] = x
            // A collapsed group's tabs stand at its header's end, with no room.
            if let key, collapsed.contains(key) {
                positions.ends[key] = x - gap
                continue
            }
            if let key { positions.ends[key] = x + extent(of: index) }
            x += extent(of: index) + gap
        }
        return positions
    }

    /// From a group's header start to its last tab's end (its header's end when collapsed) at `positions` (from
    /// `positions(order:moving:membership:)`); nil when it has no tab there.
    func span(of key: String, at positions: Positions) -> CGFloat? {
        guard let start = positions.headers[key], let end = positions.ends[key] else { return nil }
        return end - start
    }

    /// The group `unit`'s tabs are in before it moves: a `.group` unit's own id, nil for a pinned unit. The drag's
    /// first `current` for `dragTarget`.
    func group(of unit: TabArrangement.Unit, in entries: [TabArrangement.Entry]) -> UUID? {
        if case .group(let id) = unit { return id }
        return Self.range(of: unit, in: entries).flatMap { group(at: $0.lowerBound)?.id }
    }

    /// Where `unit` would drop, dragged `translation` along the axis (x for the top tabs, y for the vertical ones).
    /// `index` is its first tab's index once moved, the allowed one (`TabArrangement.destinations`) nearest the
    /// pointer; `group` is the group its tabs are in once dropped (a `.group` unit's own id, a box tab's box's group,
    /// nil for a pinned unit). Draw the drag with `positions(order: moved(count, range, to: index), moving: range,
    /// membership: group)`, drop it with `TabArrangement.move(unit:to:group:in:)`, and pass `group` back as the next
    /// call's `current` (`group(of:in:)` at the drag's start).
    func dragTarget(unit: TabArrangement.Unit, translation: CGFloat, current: UUID?,
                    entries: [TabArrangement.Entry]) -> (index: Int, group: UUID?) {
        guard let range = Self.range(of: unit, in: entries) else { return (0, current) }
        let group = membership(of: unit, range: range, translation: translation, current: current, entries: entries)
        // A group moves by its header, the others by their first tab.
        let anchor: (Positions) -> CGFloat = { positions in
            if case .group(let id) = unit { return positions.headers[id.uuidString] ?? 0 }
            return positions.tabs[range.lowerBound] ?? 0
        }
        let pointer = anchor(positions(order: Array(entries.indices), moving: nil, membership: nil)) + translation
        let distances = TabArrangement.destinations(for: unit, targetGroup: group, in: entries).map { destination in
            let order = Self.moved(entries.count, range, to: destination)
            return (destination, abs(anchor(positions(order: order, moving: range, membership: group)) - pointer))
        }
        return (distances.min { $0.1 < $1.1 }?.0 ?? range.lowerBound, group)
    }

    /// The group the unit at `range` is dragged into: the expanded group whose span, measured without the unit, holds
    /// the unit's center taken into that frame (moved back by half the room the unit takes, its extent and a gap: its
    /// start + `translation` - half a gap, where it would be inserted). Leaving `current` takes a quarter tab past its
    /// edge and joining another a quarter tab inside it, so it never flickers at an edge. A collapsed group is never
    /// joined. A unit that is its group's only content keeps that group (`TabArrangement.destinations`) unless it
    /// joins another. A `.group` unit, a pinned unit and a box tab's own unit keep their group.
    private func membership(of unit: TabArrangement.Unit, range: ClosedRange<Int>, translation: CGFloat,
                            current: UUID?, entries: [TabArrangement.Entry]) -> UUID? {
        if case .group(let id) = unit { return id }
        let first = entries[range.lowerBound]
        if first.pinned { return nil }
        let own = group(at: range.lowerBound)
        if case .tab = unit, let repo = first.repo, !first.archived,
           entries.contains(where: { $0.id != first.id && $0.repo == repo && !$0.archived }) {
            return own?.id
        }
        let start = positions(order: Array(entries.indices), moving: nil, membership: nil).tabs[range.lowerBound] ?? 0
        let probe = start + translation - gap / 2
        let rest = positions(order: entries.indices.filter { !range.contains($0) }, moving: nil, membership: nil)
        let margin = tabExtent / 4
        // Each expanded group's span without the unit; none for a group the unit is all of.
        let spans = groupByKey.values.filter { !collapsed.contains($0.key) }.compactMap {
            group -> (id: UUID, start: CGFloat, end: CGFloat)? in
            guard let start = rest.headers[group.key],
                  let last = group.range.last(where: { !range.contains($0) })
            else { return nil }
            return (id: group.id, start: start, end: (rest.tabs[last] ?? 0) + extent(of: last))
        }
        if let span = spans.first(where: { $0.id == current }),
           probe >= span.start - margin, probe <= span.end + margin { return current }
        if let span = spans.first(where: { span in
            span.id != current && probe >= span.start + margin && probe <= span.end - margin
        }) { return span.id }
        if let own, rest.headers[own.key] == nil { return own.id }
        return nil
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
