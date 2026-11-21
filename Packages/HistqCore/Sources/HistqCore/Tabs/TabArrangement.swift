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
