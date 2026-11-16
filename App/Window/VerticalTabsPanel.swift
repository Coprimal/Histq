// Panel 0, the vertical tabs (General › Tab position: Left): the window's tabs as rows on the window glass, left of
// every page, the selected row joined to the page's sheet, with New tab and the tab list at the bottom. The tab strip
// under the toolbar does not show then.
import SwiftUI

/// Where the window's app tabs show: the strip under the toolbar, or panel 0 on the left.
enum TabPosition: String {
    case top, left

    /// DEBUG `-HistqTabPosition left|top`, read once. It wins over the preference (as `-HistqAvatarMode` does) and is
    /// never written to it: outside a state dir the preferences are the user's own.
    private static let launchOverride = AppState.launchFlag("-HistqTabPosition").flatMap(TabPosition.init(rawValue:))

    /// The position for a stored `PrefKey.tabPosition` value; anything unknown reads as top.
    static func resolved(_ stored: String) -> TabPosition {
        launchOverride ?? TabPosition(rawValue: stored) ?? .top
    }

    /// The position for the preference stored now.
    static var current: TabPosition {
        resolved(Preferences.defaults.string(forKey: PrefKey.tabPosition.rawValue) ?? "")
    }
}

enum VerticalTabsMetrics {
    /// Panel 0's width, up to the page's sheet. Fixed: the window's minimum width counts it.
    static let width: CGFloat = 150
    /// Above the first row: the sheet's corner, so the selected row's top flare sits on its straight left edge.
    @MainActor static var listTop: CGFloat { PageSheetMetrics.cornerRadius }
    /// The selected row's leading corners: half its height, so its leading edge reads as a capsule's.
    @MainActor static var rowRadius: CGFloat { SidebarItemStyle.height / 2 }
    /// Between an unselected row's hover capsule and the sheet.
    static let hoverTrailing: CGFloat = 3
    /// A tab group's name row (as Chrome's vertical tabs): above its rows, clear of the sheet by `groupHeaderTrailing`.
    static let groupHeaderHeight: CGFloat = 22
    static let groupHeaderTrailing: CGFloat = 6
    static let groupHeaderRadius: CGFloat = 7
    static let groupHeaderFont = Font.system(size: 12, weight: .semibold)
    /// A group's rows sit this far right of the others; its line runs down the middle of that room.
    static let groupIndent: CGFloat = 12
}

/// The window's tabs top to bottom, the selected tab's running operation, then New tab and the tab list, with no
/// container: the selected row is a tab of the page's sheet beside it (`VerticalTabSheetShape`).
struct VerticalTabsPanel: View {
    @Environment(WindowModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: SectionCardMetrics.spacing) {
            VerticalTabList(model: model)
            VerticalTabsStatus(model: model)
                .padding(.trailing, PanelContainerMetrics.padding)
            TabStripButtons(model: model, popoverEdge: .trailing)
        }
        .padding(.top, VerticalTabsMetrics.listTop)
        .frame(width: VerticalTabsMetrics.width)
    }
}

/// The tabs as Settings sidebar rows (`VerticalTabRow`): a press selects at once (on mouse-down), a drag past a few points
/// reorders.
private struct VerticalTabList: View {
    let model: WindowModel
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The tab under the current mouse press, so a press selects once.
    @State private var pressedID: WindowModel.Tab.ID?
    /// The dragged tab, its offset, and the index it came from and would land at. `dragFrom`/`dragTarget` stay stale
    /// after a cancelled drag on purpose, as in the tab strip: clearing them would cancel the neighbors' slide back.
    @State private var draggedID: WindowModel.Tab.ID?
    @State private var dragOffset: CGFloat = 0
    @State private var dragFrom = 0
    @State private var dragTarget = 0

    private var animation: Animation? { reduceMotion ? nil : Motion.standard }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView(.vertical, showsIndicators: false) {
                rows
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(WindowDragBlocker())
            .onChange(of: model.selectedTabID) { _, id in
                guard let id else { return }
                withAnimation(animation) { scroller.scrollTo(id) }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var rows: some View {
        let layout = TabGroupLayout(tabs: model.tabs, groups: model.tabGroups, tabExtent: SidebarItemStyle.height,
                                    gap: SidebarItemStyle.spacing,
                                    headerExtent: { _ in VerticalTabsMetrics.groupHeaderHeight })
        let current = layout.positions(order: Array(model.tabs.indices))
        // While a tab is dragged, the others (and the group names) stand where they would with it dropped at its target.
        let target = draggedID == nil ? current
            : layout.positions(order: TabGroupLayout.moved(model.tabs.count, dragFrom, dragTarget))
        return VStack(alignment: .leading, spacing: SidebarItemStyle.spacing) {
            ForEach(layout.items) { item in
                switch item {
                case .header(let group):
                    // The line runs from under the name to the group's last row's end.
                    VerticalTabGroupHeader(group: group, lineLength: layout.span(of: group.key)
                                           - VerticalTabsMetrics.groupHeaderHeight - 2 * SidebarItemStyle.spacing)
                        .offset(y: (target.headers[group.key] ?? 0) - (current.headers[group.key] ?? 0))
                        .animation(draggedID != nil ? animation : nil, value: dragTarget)
                case .tab(let index, let tab):
                    row(index: index, tab: tab, layout: layout, current: current, target: target)
                }
            }
        }
        // Room for the selected row's flares inside the scroll view, which clips; none on the trailing side, where
        // the selected row meets the sheet.
        .padding(.vertical, TabStripMetrics.flare)
        .padding(.leading, TabStripMetrics.rowInset)
        // The selected row's shape slides, also for a selection made elsewhere (a menu, the tab list).
        .animation(animation, value: model.selectedTabID)
    }

    private func row(index: Int, tab: WindowModel.Tab, layout: TabGroupLayout, current: TabGroupLayout.Positions,
                     target: TabGroupLayout.Positions) -> some View {
        let dragged = tab.id == draggedID
        let selected = tab.id == model.selectedTabID
        // A tab not opened yet (filled in the background) has no session, so no dot.
        let profile = model.sessions[tab.id]?.profile
        let group = layout.groupKey[index]
        let offset = dragged ? dragOffset : (target.tabs[index] ?? 0) - (current.tabs[index] ?? 0)
        return VerticalTabRow(title: tab.title, systemImage: Self.icon(of: tab), help: tab.repoURL?.path ?? tab.title,
                              profileColor: profile?.color, profileName: profile?.name,
                              groupName: group.map(RepoGroupKey.name(of:)),
                              selected: selected, dragged: dragged, namespace: namespace,
                              onSelect: { model.selectTab(id: tab.id) },
                              onClose: { close(tab.id) })
            .frame(height: SidebarItemStyle.height)
            .background(MiddleClickCatcher { TabMenu.middleClick(tab.id, model) })
            // A group's rows sit right of its line.
            .padding(.leading, group == nil ? 0 : VerticalTabsMetrics.groupIndent)
            .offset(y: offset)
            // Neighbors slide aside; the dragged tab tracks the pointer without lag.
            .animation(draggedID != nil && !dragged ? animation : nil, value: dragTarget)
            // The selected row's flares lie over its neighbors' edges.
            .zIndex(dragged ? 2 : selected ? 1 : 0)
            .gesture(press(tab.id, index: index, layout: layout))
            .contextMenu { MenuEntriesView(entries: TabMenu.entries(for: tab.id, model: model, vertical: true)) }
            .id(tab.id)
    }

    /// The tab strip's press, vertically: zero distance, so the tab is selected on mouse-down; past
    /// `dragThreshold` it reorders, to the allowed place (`WindowModel.moveDestinations`) nearest the pointer.
    private func press(_ id: WindowModel.Tab.ID, index: Int, layout: TabGroupLayout) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if pressedID != id {
                    pressedID = id
                    model.selectTab(id: id)
                }
                let translation = value.translation.height
                guard draggedID != nil || abs(translation) >= TabStripMetrics.dragThreshold else { return }
                if draggedID == nil {
                    draggedID = id
                    dragFrom = index
                    dragTarget = index
                }
                dragOffset = translation
                let target = layout.nearestDestination(from: dragFrom, count: model.tabs.count,
                                                       translation: translation,
                                                       destinations: model.moveDestinations(from: dragFrom))
                if target != dragTarget { dragTarget = target }
            }
            .onEnded { _ in
                pressedID = nil
                guard draggedID != nil else { return }
                if dragFrom == dragTarget {
                    withAnimation(animation) {
                        dragOffset = 0
                        draggedID = nil
                    }
                } else {
                    draggedID = nil
                    dragOffset = 0
                    model.moveTab(from: dragFrom, to: dragTarget)
                }
            }
    }

    /// The toolbar's repo icon for a repo tab; a missing repo and a Welcome tab get their own.
    private static func icon(of tab: WindowModel.Tab) -> String {
        if tab.isMissing { return "questionmark.folder" }
        return tab.repoURL == nil ? "plus.square.dashed" : "book.closed"
    }

    /// A tab's close button; closing the last tab closes the window, like ⌘W.
    private func close(_ id: WindowModel.Tab.ID) {
        TabMenu.close(id, model)
    }
}

/// The selected repo's operation started from a menu, which the tab row shows in the top position.
private struct VerticalTabsStatus: View {
    let model: WindowModel

    var body: some View {
        // No modifiers around it: an idle `RunningStatus` is empty and must take no slot (nor spacing) in the panel.
        if let session = model.selectedSession {
            RunningStatus(session: session)
        }
    }
}

/// A tab group's name above its rows, as Chrome's vertical tabs: white text on the group's color, then the group's
/// line down the left of its rows (`lineLength` long, from under the name to the last row's end).
private struct VerticalTabGroupHeader: View {
    let group: TabGroup
    let lineLength: CGFloat

    var body: some View {
        Text(group.name)
            .font(VerticalTabsMetrics.groupHeaderFont)
            .foregroundStyle(Color(nsColor: Palette.graphBadgeText))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: VerticalTabsMetrics.groupHeaderHeight)
            .background(RoundedRectangle(cornerRadius: VerticalTabsMetrics.groupHeaderRadius, style: .continuous)
                .fill(TabGroupColors.chip(group.key)))
            .overlay(alignment: .topLeading) {
                Capsule()
                    .fill(TabGroupColors.line(group.key))
                    .frame(width: TabStripMetrics.groupLine, height: max(lineLength, 0))
                    .offset(x: (VerticalTabsMetrics.groupIndent - TabStripMetrics.groupLine) / 2,
                            y: VerticalTabsMetrics.groupHeaderHeight + SidebarItemStyle.spacing)
                    .allowsHitTesting(false)
            }
            .padding(.trailing, VerticalTabsMetrics.groupHeaderTrailing)
            .help("\(group.name): \(group.range.count) tabs of this repository")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Group \(group.name), \(group.range.count) tabs")
    }
}

/// One tab as a Settings sidebar row (`SidebarItemStyle`, user 2026-11-13): 28 pt tall, 10 pt padding, a 20 pt icon
/// slot then the title (body font). The selected row is a tab of the page's sheet (`VerticalTabSheetShape` in
/// `Palette.sheet`, as the top tabs' selected tab; the shape slides between rows) with full-strength text; the others
/// are secondary with a hover capsule. The profile's color is a dot on the icon's corner; the close button replaces the
/// trailing slot on hover. A grouped tab (a repo's worktrees) sits under its group's name, right of the group's line
/// (`VerticalTabGroupHeader`).
private struct VerticalTabRow: View {
    let title: String
    let systemImage: String
    let help: String
    /// The profile's `#RRGGBB`; nil without a profile (no dot).
    let profileColor: String?
    let profileName: String?
    /// The tab's group's name (`WindowModel.tabGroups`); nil outside a group.
    let groupName: String?
    let selected: Bool
    let dragged: Bool
    let namespace: Namespace.ID
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            icon
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hovered && !dragged {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: TabStripMetrics.slot, height: TabStripMetrics.slot)
                }
                .buttonStyle(TabItem.CloseButtonStyle())
                .help("Close Tab")
                .accessibilityLabel("Close \(title)")
            }
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background {
            if selected {
                // The sheet's fill, flares included (outside the row's frame): the row and the sheet read as one
                // shape, with no edge where they meet.
                VerticalTabSheetShape(radius: VerticalTabsMetrics.rowRadius, flare: TabStripMetrics.flare)
                    .fill(Palette.sheet)
                    .padding(.vertical, -TabStripMetrics.flare)
                    .matchedGeometryEffect(id: "selectedTab", in: namespace)
            } else if hovered || dragged {
                Capsule()
                    .fill(Palette.hoverFill)
                    .padding(.trailing, VerticalTabsMetrics.hoverTrailing)
            }
        }
        .contentShape(Capsule())
        .animation(Motion.hover, value: hovered)
        .onHover { hovered = $0 }
        .help(groupName.map { "\(help)\nGroup \($0)" } ?? help)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue([groupName.map { "Group \($0)" }, profileName.map { "Profile \($0)" }]
            .compactMap(\.self).joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onSelect)
    }

    /// The tab's icon in the rows' 20 pt slot, with the profile's dot on its lower trailing corner, ringed in the
    /// panel's color so it reads over the glyph.
    private var icon: some View {
        Image(systemName: systemImage)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .frame(width: 20)
            .overlay(alignment: .bottomTrailing) {
                if let profileColor {
                    Circle()
                        .fill(ProfileColors.color(profileColor))
                        .frame(width: TabStripMetrics.dot, height: TabStripMetrics.dot)
                        .overlay(Circle().strokeBorder(Palette.bgCard, lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityHidden(true)
    }
}

/// The selected vertical tab joined to the page's sheet on its right: rounded leading corners, and at each trailing
/// corner a concave flare that runs out into the sheet's left edge (`TabSheetShape` turned on its side). `rect`
/// includes the flares, `flare` tall above and below.
struct VerticalTabSheetShape: Shape {
    let radius: CGFloat
    let flare: CGFloat

    func path(in rect: CGRect) -> Path {
        let top = rect.minY + flare
        let bottom = rect.maxY - flare
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: top), tangent2End: CGPoint(x: rect.minX, y: top),
                    radius: flare)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: top), tangent2End: CGPoint(x: rect.minX, y: bottom),
                    radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: bottom), tangent2End: CGPoint(x: rect.maxX, y: bottom),
                    radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: bottom), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY),
                    radius: flare)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
