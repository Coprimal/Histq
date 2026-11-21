// The order rules of a window's tabs: worktree tabs of one repo sit side by side in a box, manual groups hold whole
// boxes and plain tabs, pinned tabs come first and are never grouped, and the popped-out archived tab stays last.
// Works on plain values, so the app maps its tabs in and reads the order, groups and pins back out.
import Foundation

public enum TabArrangement {
    /// One tab as the rules see it.
    public struct Entry: Equatable, Sendable {
        public var id: UUID
        /// The repository key its worktree tabs share; nil for a tab with no repository.
        public var repo: String?
        /// The manual group it is in.
        public var group: UUID?
        public var pinned: Bool
        /// The popped-out archived tab.
        public var archived: Bool

        public init(id: UUID, repo: String? = nil, group: UUID? = nil, pinned: Bool = false, archived: Bool = false) {
            self.id = id
            self.repo = repo
            self.group = group
            self.pinned = pinned
            self.archived = archived
        }
    }

    /// The tabs in their new order, with their group and pin updated, and the groups that still have a tab.
    public struct Arrangement: Equatable, Sendable {
        public var tabs: [Entry]
        public var groups: Set<UUID>

        public init(tabs: [Entry], groups: Set<UUID>) {
            self.tabs = tabs
            self.groups = groups
        }
    }

    /// A part of the tab row: a manual group (of boxes and tabs), a worktree box (of tabs), or a plain tab.
    public indirect enum Segment: Equatable, Sendable {
        case group(UUID, [Segment])
        case box(String, [UUID])
        case tab(UUID)
    }

    /// Puts `tabs` in order. The archived tab goes last, ungrouped and unpinned. Each repo's tabs gather right after
    /// its first tab, the others keeping their order; a box with a pinned tab is pinned whole, else it takes the group
    /// of its first grouped tab. Each group's boxes and tabs gather right after its first one. Pinned tabs lose their
    /// group and come first, each side keeping its order.
    public static func normalized(_ tabs: [Entry]) -> Arrangement {
        let archived = tabs.filter(\.archived).map { entry in
            var entry = entry
            entry.group = nil
            entry.pinned = false
            return entry
        }
        let rest = tabs.filter { !$0.archived }

        // Boxes: a repo's tabs at its first tab; a tab with no repo is a unit of its own.
        var units: [[Entry]] = []
        var placed = Set<String>()
        for entry in rest {
            guard let repo = entry.repo else {
                units.append([entry])
                continue
            }
            guard placed.insert(repo).inserted else { continue }
            units.append(rest.filter { $0.repo == repo })
        }

        // A box is pinned whole, or takes the group of its first grouped tab.
        units = units.map { unit in
            let pinned = unit.contains(where: \.pinned)
            let group = pinned ? nil : unit.first(where: { $0.group != nil })?.group
            return unit.map { entry in
                var entry = entry
                entry.pinned = pinned
                entry.group = group
                return entry
            }
        }

        // Groups: a group's units at its first unit.
        let unpinned = units.filter { !$0[0].pinned }
        var gathered: [[Entry]] = []
        var seen = Set<UUID>()
        for unit in unpinned {
            guard let group = unit[0].group else {
                gathered.append(unit)
                continue
            }
            guard seen.insert(group).inserted else { continue }
            gathered += unpinned.filter { $0[0].group == group }
        }

        let ordered = units.filter { $0[0].pinned }.flatMap { $0 } + gathered.flatMap { $0 } + archived
        return Arrangement(tabs: ordered, groups: Set(ordered.compactMap(\.group)))
    }

    /// The row's parts in order, read from neighbors only (pass tabs in `normalized` order): a run of two or more tabs
    /// of one repo is a box, a run of one group's boxes and tabs is a group. Pinned and archived tabs are in no group,
    /// and the archived tab in no box.
    public static func segments(_ tabs: [Entry]) -> [Segment] {
        var segments: [Segment] = []
        var start = 0
        while start < tabs.count {
            let group = groupOf(tabs[start])
            var end = start
            while end + 1 < tabs.count, groupOf(tabs[end + 1]) == group { end += 1 }
            let parts = boxes(tabs[start...end])
            if let group { segments.append(.group(group, parts)) } else { segments += parts }
            start = end + 1
        }
        return segments
    }

    /// What a drag moves: one tab, a whole worktree box (the non-archived tabs of its repo), or a whole manual group.
    public enum Unit: Equatable, Sendable {
        case tab(UUID)
        case box(String)
        case group(UUID)
    }

    /// The allowed places for `unit` once moved (pass `tabs` in `normalized` order). A place is the index of the
    /// unit's first tab in the resulting order, that is where its tabs go among the other tabs. The unit stays in the
    /// pinned or unpinned area, before the archived tab; it never splits a box, nor a group other than
    /// `targetGroup`; with `targetGroup` set it stays inside that group's tabs (either edge joins it), with nil it stays
    /// out of every group. A box tab's own unit only reorders inside its box. `targetGroup` is ignored for a pinned
    /// unit, a box tab's own unit and a `.group` unit (always among top-level places), and when the move leaves the
    /// target group with no other tab (the unit then keeps it, at any top-level place). Empty for the archived tab.
    public static func destinations(for unit: Unit, targetGroup: UUID?, in tabs: [Entry]) -> [Int] {
        let moved = members(of: unit, in: tabs)
        guard !moved.isEmpty, !moved.contains(where: \.archived) else { return [] }
        let ids = Set(moved.map(\.id))
        let rest = tabs.filter { !ids.contains($0.id) }

        if case .tab = unit, let start = boxStart(of: moved[0], in: rest) {
            let end = rest[start...].firstIndex { $0.repo != moved[0].repo || $0.archived } ?? rest.count
            return Array(start...end)
        }

        let pinnedCount = rest.prefix { $0.pinned }.count
        let normalEnd = rest.firstIndex(where: \.archived) ?? rest.count
        let pinned = moved[0].pinned
        var target = pinned ? nil : targetGroup
        if case .group = unit { target = nil }
        let span = target.flatMap { group -> ClosedRange<Int>? in
            guard let first = rest.firstIndex(where: { groupOf($0) == group }),
                  let last = rest.lastIndex(where: { groupOf($0) == group })
            else { return nil }
            return first...(last + 1)
        }
        let area = pinned ? 0...pinnedCount : pinnedCount...normalEnd
        return area.filter { index in
            if splitsBox(at: index, in: rest) { return false }
            if let span { return span.contains(index) }
            return insideGroup(at: index, in: rest) == nil
        }
    }

    /// Moves `unit` to `index`, one of `destinations(for:targetGroup:in:)` with `targetGroup` = `group` (pass `tabs`
    /// in `normalized` order; any other index leaves the order as it is). The unit's tabs take `group`, except a pinned
    /// tab (never in a group), a `.group` unit (keeps its id) and a box tab's own unit (keeps its box's group).
    public static func move(unit: Unit, to index: Int, group: UUID?, in tabs: [Entry]) -> Arrangement {
        guard destinations(for: unit, targetGroup: group, in: tabs).contains(index) else { return normalized(tabs) }
        var moved = members(of: unit, in: tabs)
        let ids = Set(moved.map(\.id))
        var rest = tabs.filter { !ids.contains($0.id) }
        var keepsGroup = false
        if case .group = unit { keepsGroup = true }
        if case .tab = unit, boxStart(of: moved[0], in: rest) != nil { keepsGroup = true }
        if !keepsGroup {
            moved = moved.map { entry in
                var entry = entry
                entry.group = entry.pinned ? nil : group
                return entry
            }
        }
        rest.insert(contentsOf: moved, at: index)
        return normalized(rest)
    }

    /// The tabs `unit` stands for, in order.
    private static func members(of unit: Unit, in tabs: [Entry]) -> [Entry] {
        switch unit {
        case let .tab(id): tabs.filter { $0.id == id }
        case let .box(repo): tabs.filter { $0.repo == repo && !$0.archived }
        case let .group(id): tabs.filter { groupOf($0) == id }
        }
    }

    /// Where the rest of `entry`'s box starts in `rest` (the tabs without it), or nil when no other tab shares its box.
    private static func boxStart(of entry: Entry, in rest: [Entry]) -> Int? {
        guard let repo = entry.repo, !entry.archived else { return nil }
        return rest.firstIndex { $0.repo == repo && !$0.archived }
    }

    /// A place between two tabs of one box.
    private static func splitsBox(at index: Int, in tabs: [Entry]) -> Bool {
        guard index > 0, index < tabs.count, let repo = tabs[index].repo else { return false }
        return tabs[index - 1].repo == repo && !tabs[index].archived && !tabs[index - 1].archived
    }

    /// The group a place sits strictly inside, between two of its tabs.
    private static func insideGroup(at index: Int, in tabs: [Entry]) -> UUID? {
        guard index > 0, index < tabs.count, let group = groupOf(tabs[index]) else { return nil }
        return groupOf(tabs[index - 1]) == group ? group : nil
    }

    /// The group a tab is drawn in: none for a pinned or archived tab.
    private static func groupOf(_ entry: Entry) -> UUID? {
        entry.pinned || entry.archived ? nil : entry.group
    }

    /// The boxes (runs of two or more tabs of one repo, never the archived tab) and plain tabs of `tabs`.
    private static func boxes(_ tabs: ArraySlice<Entry>) -> [Segment] {
        var parts: [Segment] = []
        var start = tabs.startIndex
        while start < tabs.endIndex {
            var end = start
            if let repo = tabs[start].repo, !tabs[start].archived {
                while end + 1 < tabs.endIndex, tabs[end + 1].repo == repo, !tabs[end + 1].archived { end += 1 }
                if end > start {
                    parts.append(.box(repo, tabs[start...end].map(\.id)))
                    start = end + 1
                    continue
                }
            }
            parts.append(.tab(tabs[start].id))
            start = end + 1
        }
        return parts
    }
}
