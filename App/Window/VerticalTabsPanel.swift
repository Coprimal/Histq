// Panel 0, the vertical tabs (General › Tab position: Left): the window's tabs as rows on the window glass, left of
// every page, the selected row joined to the page's sheet, the pinned tabs as a grid of icons above the rows, with the
// archive button (once the window has an archive), New tab and the tab list at the bottom, and the popped-out archived
// tab right above them. The tab strip under the toolbar does not show then.
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
    static let groupHeaderRadius: CGFloat = 6
    static let groupHeaderFont = Font.system(size: 12, weight: .semibold)
    /// A group's rows sit this far right of the others; its line runs down the middle of that room.
    static let groupIndent: CGFloat = 12
    /// A pinned tab's cell in the grid above the rows (`VerticalPinnedGrid`): about this square, 4 to a row in the
    /// panel, `pinnedSpacing` apart.
    static let pinnedCell: CGFloat = 30
    static let pinnedCellMax: CGFloat = 34
    static let pinnedSpacing: CGFloat = 4
    static let pinnedRadius: CGFloat = 8
    /// A worktree box (`WorktreeBoxShape`) down the list: this far above and below its rows, inside the spacing, so two
    /// boxes one above the other (and a box beside a plain row) keep a clear line between them; from the rows' leading
    /// inset to `boxTrailing` short of the sheet.
    static let boxOutset: CGFloat = 2
    static let boxTrailing: CGFloat = 1
    static let boxRadius: CGFloat = 8
}

/// The window's tabs top to bottom (the pinned ones first, as a grid of icons) in their own scroll view, the selected
/// tab's running operation, then the popped-out archived tab and the archive button, New tab and the tab list
/// (`VerticalArchiveFooter`), with no container: the selected row is a tab of the page's sheet beside it
/// (`VerticalTabSheetShape`).
struct VerticalTabsPanel: View {
    @Environment(WindowModel.self) private var model
    /// Shared by the list and the popped-out archived row, so the selected row's shape slides between them.
    @Namespace private var namespace

    var body: some View {
        VStack(alignment: .leading, spacing: SectionCardMetrics.spacing) {
            VerticalTabList(model: model, namespace: namespace)
            VerticalTabsStatus(model: model)
                .padding(.trailing, PanelContainerMetrics.padding)
            VerticalArchiveFooter(model: model, namespace: namespace)
        }
        .padding(.top, VerticalTabsMetrics.listTop)
        .frame(width: VerticalTabsMetrics.width)
    }
}

/// The pinned tabs as a grid of icons (`VerticalPinnedGrid`), then the others as Settings sidebar rows
/// (`VerticalTabRow`), in a scroll view that takes the panel's free height and shows its scroller: a press selects at
/// once (on mouse-down), a drag past a few points reorders a row (pinned tabs are reordered in the top strip only).
/// The popped-out archived tab is not here: it stands above the footer (`VerticalArchiveFooter`); last in `tabs`, it
/// takes no room, so no other row moves.
private struct VerticalTabList: View {
    let model: WindowModel
    /// The panel's, shared with the popped-out archived row.
    let namespace: Namespace.ID
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
            ScrollView(.vertical, showsIndicators: true) {
                // In the scroll view, so `scrollTo` reaches a pinned tab's cell and a press on it does not drag the
                // window.
                VStack(alignment: .leading, spacing: 0) {
                    if model.pinnedCount > 0 {
                        VerticalPinnedGrid(model: model)
                            .padding(.top, TabStripMetrics.flare)
                    }
                    rows
                }
                .background(OverlayScroller())
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

    /// The unpinned tabs and their groups' names. The pinned tabs (and their groups' names) and the popped-out archived
    /// tab are not rows: they take no height, and their items are skipped. The archived tab is last, so it shifts
    /// nothing. Their gaps (and names) still count in `positions`, but only as one shift
    /// of every row, since they stand first in every order a row's drag can make (`WindowModel.moveDestinations`), and
    /// the rows use positions only as differences. Indices stay `model.tabs`' own.
    private var rows: some View {
        // A pinned box shows in the grid (`VerticalPinnedGrid`), each cell on the box's fill.
        let listBoxes = model.worktreeBoxes.filter { !model.tabs[$0.range.lowerBound].pinned }
        let layout = TabGroupLayout(tabs: model.tabs, groups: model.manualGroups, boxes: listBoxes,
                                    tabExtent: SidebarItemStyle.height, gap: SidebarItemStyle.spacing,
                                    extent: { model.tabs[$0].pinned || model.tabs[$0].archived
                                        ? 0 : SidebarItemStyle.height },
                                    headerExtent: { _ in VerticalTabsMetrics.groupHeaderHeight })
        // A pinned group is pinned whole, so its first tab tells.
        let items = layout.items.filter { item in
            switch item {
            case .header(let group): !model.tabs[group.range.lowerBound].pinned
            case .tab(_, let tab): !tab.pinned && !tab.archived
            }
        }
        let current = layout.positions(order: Array(model.tabs.indices))
        // While a tab is dragged, the others (and the group names) stand where they would with it dropped at its target.
        let target = draggedID == nil ? current
            : layout.positions(order: TabGroupLayout.moved(model.tabs.count, dragFrom, dragTarget))
        return VStack(alignment: .leading, spacing: SidebarItemStyle.spacing) {
            ForEach(items) { item in
                switch item {
                case .header(let group):
                    // The line runs from under the name to the group's last row's end.
                    VerticalTabGroupHeader(group: group, collapsed: layout.collapsed.contains(group.key),
                                           lineLength: layout.span(of: group.key)
                                               - VerticalTabsMetrics.groupHeaderHeight - 2 * SidebarItemStyle.spacing,
                                           onToggle: { withAnimation(animation) { model.toggleGroup(group.id) } })
                        .offset(y: (target.headers[group.key] ?? 0) - (current.headers[group.key] ?? 0))
                        .animation(draggedID != nil ? animation : nil, value: dragTarget)
                case .tab(let index, let tab):
                    row(index: index, tab: tab, layout: layout, current: current, target: target)
                }
            }
        }
        // Inside the selection's animation, so each box's hole slides with the selected row's shape.
        .background { boxes(layout: layout, current: current, target: target) }
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
        let profile = model.profile(of: tab)
        let group = layout.group(at: index)
        let offset = dragged ? dragOffset : (target.tabs[index] ?? 0) - (current.tabs[index] ?? 0)
        return VerticalTabRow(title: tab.title, systemImage: TabIcon.symbol(of: tab), emoji: tab.emoji,
                              iconColor: tab.iconColor,
                              help: tab.repoURL?.path ?? tab.title, profileColor: profile?.color, profileName: profile?.name,
                              groupName: group?.group.name,
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

    /// The worktree boxes behind their rows, at the rows' target positions (so they move with a drag), each with the
    /// selected row's shape cut out where it reaches, as drawn (following the pointer while dragged). Positions count
    /// the pinned tabs' gaps before the first row: taken off here, as the rows' frames start at the list's top.
    /// Decorative.
    private func boxes(layout: TabGroupLayout, current: TabGroupLayout.Positions,
                       target: TabGroupLayout.Positions) -> some View {
        let base = CGFloat(model.pinnedCount) * SidebarItemStyle.spacing
        let flare = TabStripMetrics.flare
        var hole: (start: CGFloat, end: CGFloat) = (0, 0)
        var holeLeading: CGFloat = 0
        if let index = model.selectedIndex, !model.tabs[index].pinned, !model.tabs[index].archived {
            let y = (model.tabs[index].id == draggedID ? (current.tabs[index] ?? 0) + dragOffset
                : target.tabs[index] ?? 0) - base
            hole = (y - flare, y + SidebarItemStyle.height + flare)
            holeLeading = layout.group(at: index) == nil ? 0 : VerticalTabsMetrics.groupIndent
        }
        return ZStack {
            ForEach(layout.boxes, id: \.key) { box in
                if let span = layout.boxSpan(box, at: target) {
                    // A grouped box's rows sit right of the group's line.
                    let leading = layout.group(at: box.range.lowerBound) == nil ? 0 : VerticalTabsMetrics.groupIndent
                    let shape = WorktreeBoxShape(axis: .vertical,
                                                 start: span.start - base - VerticalTabsMetrics.boxOutset,
                                                 end: span.end - base + VerticalTabsMetrics.boxOutset,
                                                 holeStart: hole.start, holeEnd: hole.end,
                                                 crossStart: leading - TabStripMetrics.rowInset,
                                                 crossEndInset: VerticalTabsMetrics.boxTrailing,
                                                 holeCrossStart: holeLeading, radius: VerticalTabsMetrics.boxRadius,
                                                 holeRadius: VerticalTabsMetrics.rowRadius, flare: flare)
                    shape.fill(Palette.worktreeBoxFill)
                    shape.edge.fill(Palette.worktreeBoxBorder)
                }
            }
        }
        .animation(draggedID != nil ? animation : nil, value: dragTarget)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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

    /// A tab's close button; closing the last tab closes the window, like ⌘W.
    private func close(_ id: WindowModel.Tab.ID) {
        TabMenu.close(id, model)
    }
}

/// Keeps the enclosing scroll view's scroller in the overlay style, also when the system prefers the legacy one (a
/// mouse connected, or Show scroll bars: Always): a legacy scroller takes its width from the list, so the selected row
/// would stop short of the page's sheet. Re-applied when the system's preferred style changes, after the scroll view's
/// own reset. Decorative: it never takes a click.
private struct OverlayScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { OverlayScrollerView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class OverlayScrollerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard window != nil else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(styleChanged),
                                                   name: NSScroller.preferredScrollerStyleDidChangeNotification,
                                                   object: nil)
            apply()
        }

        /// The scroll view resets its style on the same notification: apply ours once that has run.
        @objc private func styleChanged() {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.apply() }
            }
        }

        private func apply() {
            enclosingScrollView?.scrollerStyle = .overlay
        }

        override nonisolated func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The panel's bottom: the archived tab popped out (`WindowModel.archivedOut`) as a row indented as a group's, then the
/// archive button (once the window has an archive), New tab and the tab list in one row. The archive's line runs down
/// the popped row's indent to the archive button, marking the two as one group, as a group's line does under its name.
/// With nothing popped out, the button row alone, with no line. A press selects the popped row at once (on
/// mouse-down); it never reorders.
private struct VerticalArchiveFooter: View {
    let model: WindowModel
    /// The panel's, shared with the list, so the selected row's shape slides between them.
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The popped row under the current mouse press, so a press selects once.
    @State private var pressedID: WindowModel.Tab.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let tab = model.archivedOut {
                poppedRow(tab)
                    // Room for the selected row's flares above and below, as the list has inside its scroll view.
                    .padding(.vertical, TabStripMetrics.flare)
            }
            // `TabStripButtons` pads itself by `rowInset`: the archive button takes the same inset on its leading side,
            // and the spacing gives back the other one, so the three buttons stand `gap` apart.
            HStack(spacing: TabStripMetrics.gap - TabStripMetrics.rowInset) {
                if !model.archivedTabs.isEmpty || model.archivedOut != nil {
                    ArchiveButton(model: model, popoverEdge: .trailing, height: SidebarItemStyle.height)
                        .padding(.leading, TabStripMetrics.rowInset)
                }
                TabStripButtons(model: model, popoverEdge: .trailing)
            }
        }
        .overlay(alignment: .topLeading) {
            if model.archivedOut != nil {
                line
            }
        }
        // The selected row's shape slides, also for a selection made elsewhere (the archive's list, the tab list).
        .animation(reduceMotion ? nil : Motion.standard, value: model.selectedTabID)
    }

    /// The archive's line, down the middle of the popped row's indent from its top to the archive button's edge (the
    /// button's center lies right of the indent, so the line keeps to the indent as a group's does). The exact x and
    /// end are tuned against a QA shot. Decorative.
    private var line: some View {
        // The button is a capsule: at the line's x (half the indent in from its leading edge) its top edge lies lower
        // than its frame's top, by this much, so the line runs on to meet the edge instead of stopping short of it.
        let radius = SidebarItemStyle.height / 2
        let dx = radius - VerticalTabsMetrics.groupIndent / 2
        let dip = radius - (radius * radius - dx * dx).squareRoot()
        return Capsule()
            .fill(TabGroupColors.archiveLine)
            // The row, its flares' room under it, then the button row's `rowInset` above the archive button.
            .frame(width: TabStripMetrics.groupLine,
                   height: SidebarItemStyle.height + TabStripMetrics.flare + TabStripMetrics.rowInset + dip)
            .offset(x: TabStripMetrics.rowInset + (VerticalTabsMetrics.groupIndent - TabStripMetrics.groupLine) / 2,
                    y: TabStripMetrics.flare)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// The popped-out tab, as the list draws a row (no group name), right of the archive's line.
    private func poppedRow(_ tab: WindowModel.Tab) -> some View {
        let profile = model.profile(of: tab)
        return VerticalTabRow(title: tab.title, systemImage: TabIcon.symbol(of: tab), emoji: tab.emoji,
                              iconColor: tab.iconColor,
                              help: tab.repoURL?.path ?? tab.title, profileColor: profile?.color,
                              profileName: profile?.name, groupName: nil,
                              selected: tab.id == model.selectedTabID, dragged: false, namespace: namespace,
                              onSelect: { model.selectTab(id: tab.id) },
                              onClose: { TabMenu.close(tab.id, model) })
            .frame(height: SidebarItemStyle.height)
            .background(MiddleClickCatcher { TabMenu.middleClick(tab.id, model) })
            // Outside the list's scroll view, so it needs its own: a press on the row never drags the window.
            .background(WindowDragBlocker())
            // Lined up with a group's rows in the list, right of the archive's line; none on the trailing side,
            // where the selected row meets the sheet.
            .padding(.leading, TabStripMetrics.rowInset + VerticalTabsMetrics.groupIndent)
            .gesture(press(tab.id))
            .contextMenu { MenuEntriesView(entries: TabMenu.entries(for: tab.id, model: model, vertical: true)) }
            .id(tab.id)
    }

    /// Zero distance, so the row is selected on mouse-down (a tap would wait for mouse-up); no drag reorder.
    private func press(_ id: WindowModel.Tab.ID) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { _ in
                // `!= id` rather than `== nil`: a press that never ends (`onEnded` skipped) blocks only this row.
                if pressedID != id {
                    pressedID = id
                    model.selectTab(id: id)
                }
            }
            .onEnded { _ in pressedID = nil }
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

/// A manual group's header above its rows, as Chrome's vertical tabs: a rounded rect in the group's color, a plain
/// square without a name, else the row's width with the name in white; then the group's line down the left of its rows
/// (`lineLength` long, from under the header to the last row's end). A click collapses the group to its header alone,
/// with no line, and shows its rows again.
private struct VerticalTabGroupHeader: View {
    let group: TabGroup
    let collapsed: Bool
    let lineLength: CGFloat
    let onToggle: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: VerticalTabsMetrics.groupHeaderRadius, style: .continuous)
        let named = !group.name.isEmpty
        Button(action: onToggle) {
            Text(group.name)
                .font(VerticalTabsMetrics.groupHeaderFont)
                .foregroundStyle(Color(nsColor: Palette.graphBadgeText))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, named ? 8 : 0)
                .frame(maxWidth: named ? .infinity : VerticalTabsMetrics.groupHeaderHeight, alignment: .leading)
                .frame(height: VerticalTabsMetrics.groupHeaderHeight)
                .background(shape.fill(TabGroupColors.chip(group.group.colorIndex)))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topLeading) {
            if !collapsed {
                Capsule()
                    .fill(TabGroupColors.line(group.group.colorIndex))
                    .frame(width: TabStripMetrics.groupLine, height: max(lineLength, 0))
                    .offset(x: (VerticalTabsMetrics.groupIndent - TabStripMetrics.groupLine) / 2,
                            y: VerticalTabsMetrics.groupHeaderHeight + SidebarItemStyle.spacing)
                    .allowsHitTesting(false)
            }
        }
        .padding(.trailing, VerticalTabsMetrics.groupHeaderTrailing)
        .help(group.help(collapsed: collapsed))
        .accessibilityLabel(group.accessibilityLabel)
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
    }
}

/// One tab as a Settings sidebar row (`SidebarItemStyle`, user 2026-11-13): 28 pt tall, 10 pt padding, a 20 pt icon
/// slot then the title (body font). The selected row is a tab of the page's sheet (`VerticalTabSheetShape` in
/// `Palette.sheet`, as the top tabs' selected tab; the shape slides between rows) with full-strength text; the others
/// are secondary with a hover capsule. A tab with an emoji shows it (`TabIcon`) in the icon slot instead of the symbol.
/// The profile's color is a dot on the icon's corner; the close button replaces the trailing slot on hover. A tab of a
/// manual group sits under its group's header, right of the group's line (`VerticalTabGroupHeader`).
private struct VerticalTabRow: View {
    let title: String
    let systemImage: String
    /// The tab's emoji (`WindowModel.Tab.emoji`), shown instead of `systemImage`; nil for none.
    let emoji: String?
    /// The book's own color (`TabIcon`); nil for the default tab icon.
    let iconColor: Int?
    let help: String
    /// The profile's `#RRGGBB`; nil without a profile (no dot).
    let profileColor: String?
    let profileName: String?
    /// The tab's manual group's name (`WindowModel.manualGroups`); nil outside a group or for an unnamed one.
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

    /// The tab's icon (`TabIcon`: the emoji, else the symbol in its color) in the rows' 20 pt slot, with the profile's
    /// white-ringed dot on its lower trailing corner.
    private var icon: some View {
        TabIcon(emoji: emoji, symbol: systemImage, iconColor: iconColor, selected: selected,
                profileColor: profileColor, profileName: profileName)
            .frame(width: 20)
            .accessibilityHidden(true)
    }
}

/// The pinned tabs (`WindowModel.pinnedCount`, first in `tabs`) as a grid of icon cells above the rows, about 4 to a
/// row: each its `TabIcon` (the emoji, else its book) with the profile's dot. The selected cell sits on the sheet's
/// color, a hovered one on a subtle fill, a worktree box's cells on the box's fill. A press selects on mouse-down; the
/// cells do not reorder (the top strip does).
private struct VerticalPinnedGrid: View {
    let model: WindowModel
    /// The tab under the current mouse press, so a press selects once.
    @State private var pressedID: WindowModel.Tab.ID?

    private let columns = [GridItem(.adaptive(minimum: VerticalTabsMetrics.pinnedCell,
                                              maximum: VerticalTabsMetrics.pinnedCellMax),
                                    spacing: VerticalTabsMetrics.pinnedSpacing)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: VerticalTabsMetrics.pinnedSpacing) {
            // Pinned tabs come first, so the offset is the tab's index in `model.tabs`.
            ForEach(Array(model.tabs.prefix(model.pinnedCount).enumerated()), id: \.element.id) { index, tab in
                cell(index: index, tab: tab)
            }
        }
        // Lined up with the rows on the leading side, clear of the sheet on the trailing one.
        .padding(.leading, TabStripMetrics.rowInset)
        .padding(.trailing, PanelContainerMetrics.padding)
    }

    /// One pinned tab's cell, with its press, menu, middle click and tooltip.
    private func cell(index: Int, tab: WindowModel.Tab) -> some View {
        let profile = model.profile(of: tab)
        // Pinned tabs are in no manual group; a pinned worktree box is pinned whole.
        let boxed = model.worktreeBoxes.contains { $0.range.contains(index) }
        let path = tab.repoURL?.path
        return VerticalPinnedCell(title: tab.title, emoji: tab.emoji, symbol: TabIcon.symbol(of: tab),
                                  iconColor: tab.iconColor,
                                  profileColor: profile?.color, profileName: profile?.name,
                                  boxed: boxed,
                                  selected: tab.id == model.selectedTabID,
                                  onSelect: { model.selectTab(id: tab.id) })
            .background(MiddleClickCatcher { TabMenu.middleClick(tab.id, model) })
            .gesture(press(tab.id))
            .contextMenu { MenuEntriesView(entries: TabMenu.entries(for: tab.id, model: model, vertical: true)) }
            // A pinned tab shows no name: its tooltip leads with it, then the path when that says more.
            .help(path.map { $0 == tab.title ? tab.title : "\(tab.title)\n\($0)" } ?? tab.title)
            .id(tab.id)
    }

    /// Selects the tab on mouse-down, once per press; no drag.
    private func press(_ id: WindowModel.Tab.ID) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard pressedID != id else { return }
                pressedID = id
                model.selectTab(id: id)
            }
            .onEnded { _ in pressedID = nil }
    }
}

/// A pinned tab's cell in `VerticalPinnedGrid`: its icon centered in a rounded square, on the sheet's color when
/// selected and a subtle fill on hover; a cell of a worktree box on the box's fill.
private struct VerticalPinnedCell: View {
    let title: String
    let emoji: String?
    /// The symbol shown without an emoji (`TabIcon.symbol(of:)`) and its own color (`TabIcon`).
    let symbol: String
    let iconColor: Int?
    /// The profile's `#RRGGBB`; nil without a profile (no dot).
    let profileColor: String?
    let profileName: String?
    /// The tab is in a worktree box: the box's fill when not selected.
    let boxed: Bool
    let selected: Bool
    let onSelect: () -> Void
    @State private var hovered = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: VerticalTabsMetrics.pinnedRadius, style: .continuous)
    }

    var body: some View {
        TabIcon(emoji: emoji, symbol: symbol, iconColor: iconColor, selected: selected,
                profileColor: profileColor, profileName: profileName)
            .accessibilityHidden(true)
            .frame(maxWidth: .infinity)
            .frame(height: VerticalTabsMetrics.pinnedCell)
            .background {
                if selected {
                    shape.fill(Palette.sheet)
                } else if hovered {
                    shape.fill(Palette.hoverFill)
                } else if boxed {
                    shape.fill(Palette.worktreeBoxFill)
                }
            }
            // The whole cell takes the press and the hover, not just the icon.
            .contentShape(shape)
            .animation(Motion.hover, value: hovered)
            .onHover { hovered = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
            .accessibilityValue(["Pinned", profileName.map { "Profile \($0)" }]
                .compactMap(\.self).joined(separator: ", "))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, onSelect)
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
