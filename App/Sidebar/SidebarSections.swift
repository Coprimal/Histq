// The sidebar's sections as the user orders and hides them (`PrefKey.sidebarSectionOrder`, `.hiddenSidebarSections`):
// the Branches tab's cards, the Tags card and the PRs tab's lists. A section moves only inside its tab; a tab with
// nothing left to show goes away, except Branches, which then says all its sections are hidden.
import Foundation

/// A sidebar section, by its id in the prefs. The PR lists' ids are `GitHubStore.List`'s raw values.
enum SidebarSectionID: String, CaseIterable, Sendable {
    case local, remote, worktrees, tags, mine, reviewRequested, allOpen, assigned

    var tab: SidebarTab {
        switch self {
        case .local, .remote, .worktrees: .branches
        case .tags: .tags
        case .mine, .reviewRequested, .allOpen, .assigned: .prs
        }
    }
}

/// The visible sidebar sections in their order, parsed from the two prefs.
struct SidebarSections: Equatable, Sendable {
    let visible: [SidebarSectionID]

    /// Unknown and repeated ids are dropped. An id missing from `order` goes back after the nearest section that
    /// precedes it by default and is listed, else to the front.
    init(order: String, hidden: String) {
        var ids: [SidebarSectionID] = []
        for id in Self.parse(order) where !ids.contains(id) { ids.append(id) }
        let defaults = SidebarSectionID.allCases
        for (index, id) in defaults.enumerated() where !ids.contains(id) {
            let before = defaults[..<index].last(where: ids.contains).flatMap { ids.firstIndex(of: $0) }
            ids.insert(id, at: before.map { $0 + 1 } ?? 0)
        }
        let hidden = Set(Self.parse(hidden))
        visible = ids.filter { !hidden.contains($0) }
    }

    /// The sections as `Preferences.defaults` has them now (`GitHubStore`, which is not a view).
    static var current: SidebarSections {
        SidebarSections(order: Preferences.defaults.string(forKey: PrefKey.sidebarSectionOrder.rawValue) ?? "",
                        hidden: Preferences.defaults.string(forKey: PrefKey.hiddenSidebarSections.rawValue) ?? "")
    }

    /// The visible sections of `tab`, in order.
    func ids(in tab: SidebarTab) -> [SidebarSectionID] {
        visible.filter { $0.tab == tab }
    }

    /// The PRs tab's visible lists, in order.
    var pullRequestLists: [GitHubStore.List] {
        ids(in: .prs).compactMap { GitHubStore.List(rawValue: $0.rawValue) }
    }

    /// The tabs with a visible section; Branches always.
    var tabs: [SidebarTab] {
        SidebarTab.allCases.filter { $0 == .branches || !ids(in: $0).isEmpty }
    }

    /// The tab the sidebar shows for the session's `tab`: Branches when that one is hidden.
    func shownTab(_ tab: SidebarTab) -> SidebarTab {
        tabs.contains(tab) ? tab : .branches
    }

    private static func parse(_ list: String) -> [SidebarSectionID] {
        list.split(separator: ",").compactMap { SidebarSectionID(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
    }
}
