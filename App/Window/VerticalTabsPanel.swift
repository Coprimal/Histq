// Panel 0, the vertical tabs (General › Tab position: Left): the window's tabs as rows on the window glass, left of
// every page, the selected row joined to the page's sheet, the pinned tabs as a grid of icons above the rows, with the
// archive button (once the window has an archive), New tab and the tab list at the bottom, and the popped-out archived
// tab right above them. The tab strip under the toolbar does not show then.
import HistqCore
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
        .spotlightTarget(.verticalTabs)
    }
}

/// The pinned tabs as a grid of icons (`VerticalPinnedGrid`), then the others as Settings sidebar rows
/// (`VerticalTabRow`), in a scroll view that takes the panel's free height and shows its scroller: a press selects at
/// once (on mouse-down), a drag past a few points moves a row, its worktree box or (by its header) its group, as the
/// tab strip does (pinned tabs are reordered in the top strip only).
/// The popped-out archived tab is not here: it stands above the footer (`VerticalArchiveFooter`); last in `tabs`, it
/// takes no room, so no other row moves.
private struct VerticalTabList: View {
    let model: WindowModel
    /// The panel's, shared with the popped-out archived row.
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The tab under the current mouse press, so a press selects once.
    @State private var pressedID: WindowModel.Tab.ID?
    /// The group header under the current mouse press, so its mouse-up collapses only a press it took.
    @State private var pressedHeader: UUID?
    /// A drag is under way (a tab, a worktree box or a group by its header), its offset down the list, and what it
    /// moves and where it would land. `drag` stays stale after a drag on purpose, as in the tab strip: clearing it would
    /// change the neighbors' animation value and cancel the slide back.
    @State private var dragging = false
    @State private var dragOffset: CGFloat = 0
    @State private var drag: TabDrag?

    /// The rows' coordinate space: a press's pointer down the list, where a row's frame starts at its position less
    /// `base`.
    private static let listSpace = "verticalTabList"

    private var animation: Animation? { reduceMotion ? nil : Motion.standard }

    /// The pinned tabs' gaps before the first row, which positions count (a pinned tab takes no height): taken off
    /// wherever a position meets the rows' frames, which start at the list's top.
    private var base: CGFloat { CGFloat(model.pinnedCount) * SidebarItemStyle.spacing }

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
            .onChange(of: model.groupPopoverID) { _, id in
                guard let id else { return }
                // On the next turn (a new group's header is not laid out yet), and unanimated, so the popover
                // (`TabGroupPopoverAnchor`) anchors to the header where it stops.
                DispatchQueue.main.async { scroller.scrollTo(id) }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The unpinned tabs and their groups' names. The pinned tabs and the popped-out archived tab are not rows: they
    /// take no height, and their items are skipped. The archived tab is last, so it shifts nothing. The pinned tabs'
    /// gaps still count in `positions`, but only as one shift of every row (`base`), since they stand first in every
    /// order a drag can make (`TabArrangement.destinations`). Indices stay `model.tabs`' own.
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
        let current = layout.positions(order: Array(model.tabs.indices), moving: nil, membership: nil)
        let active = dragging ? drag : nil
        // While a unit is dragged, the others (and the group names) stand where they would with it dropped at its
        // target, in the group it would be in; its own rows (and a dragged group's name) follow the pointer.
        let target = active.map { drag in
            layout.positions(order: TabGroupLayout.moved(model.tabs.count, drag.range, to: drag.index),
                             moving: drag.range, membership: drag.group)
        } ?? current
        return VStack(alignment: .leading, spacing: SidebarItemStyle.spacing) {
            ForEach(items) { item in
                switch item {
                case .header(let group):
                    let dragged = active?.unit == .group(group.id)
                    // A group left with no tab by the drag has no target header: hidden (still in the list, which
                    // `current` counts), it goes on the drop.
                    let targetY = target.headers[group.key]
                    let headerY = dragged ? (current.headers[group.key] ?? 0) + dragOffset : targetY ?? 0
                    // The line runs from under the name to a gap short of the group's last row's end, as the group
                    // stands at its target (its span ends at that row's end).
                    VerticalTabGroupHeader(model: model, group: group,
                                           collapsed: layout.collapsed.contains(group.key),
                                           lineLength: (layout.span(of: group.key, at: target) ?? 0)
                                               - VerticalTabsMetrics.groupHeaderHeight - 2 * SidebarItemStyle.spacing,
                                           press: headerPress(group, layout: layout),
                                           onToggle: { withAnimation(animation) { model.toggleGroup(group.id) } })
                        .offset(y: headerY - (current.headers[group.key] ?? 0))
                        .opacity(dragged || targetY != nil ? 1 : 0)
                        .allowsHitTesting(dragged || targetY != nil)
                        // Others slide aside; the dragged header tracks the pointer without lag.
                        .animation(dragging && !dragged ? animation : nil, value: drag)
                        .zIndex(dragged ? 2 : 0)
                        // So its popover's opening can scroll it into view.
                        .id(group.id)
                case .tab(let index, let tab):
                    row(index: index, tab: tab, layout: layout, current: current, target: target)
                }
            }
        }
        // Inside the selection's animation, so each box's hole slides with the selected row's shape.
        .background { boxes(layout: layout, current: current, target: target) }
        .coordinateSpace(.named(Self.listSpace))
        // Room for the selected row's flares inside the scroll view, which clips; none on the trailing side, where
        // the selected row meets the sheet.
        .padding(.vertical, TabStripMetrics.flare)
        .padding(.leading, TabStripMetrics.rowInset)
        // The selected row's shape slides, also for a selection made elsewhere (a menu, the tab list).
        .animation(animation, value: model.selectedTabID)
    }

    private func row(index: Int, tab: WindowModel.Tab, layout: TabGroupLayout, current: TabGroupLayout.Positions,
                     target: TabGroupLayout.Positions) -> some View {
        // In the dragged unit: the tab, its box or its group.
        let dragged = dragging && drag?.range.contains(index) == true
        let selected = tab.id == model.selectedTabID
        let profile = model.profile(of: tab)
        // A dragged row takes the group it would drop in, with its indent.
        let group = dragged ? drag?.group.flatMap { id in model.manualGroups.first { $0.id == id } }
            : layout.group(at: index)
        let offset = dragged ? dragOffset : (target.tabs[index] ?? 0) - (current.tabs[index] ?? 0)
        return VerticalTabRow(title: tab.title, systemImage: TabIcon.symbol(of: tab), emoji: tab.emoji,
                              iconColor: tab.iconColor,
                              help: tab.repoURL?.path ?? tab.title, profileColor: profile?.color, profileName: profile?.name,
                              groupName: group?.group.name,
                              selected: selected, multiSelected: !selected && model.multiSelection.contains(tab.id),
                              dragged: dragged, namespace: namespace,
                              onSelect: { model.selectTab(id: tab.id) },
                              onClose: { close(tab.id) })
            .frame(height: SidebarItemStyle.height)
            .background(MiddleClickCatcher { TabMenu.middleClick(tab.id, model) })
            // A group's rows sit right of its line.
            .padding(.leading, group == nil ? 0 : VerticalTabsMetrics.groupIndent)
            .offset(y: offset)
            // Neighbors slide aside; the dragged rows track the pointer without lag.
            .animation(dragging && !dragged ? animation : nil, value: drag)
            // The dragged rows above the others; the selected row's flares lie over its neighbors' edges.
            .zIndex((dragged ? 2 : 0) + (selected ? 1 : 0))
            .gesture(press(tab.id, index: index, layout: layout))
            .contextMenu { MenuEntriesView(entries: TabMenu.entries(for: tab.id, model: model, vertical: true)) }
            .id(tab.id)
    }

    /// The worktree boxes behind their rows, at the rows' target positions (so they move with a drag; a dragged box, or
    /// one in a dragged group, follows the pointer with its rows), each with the selected row's shape cut out where it
    /// reaches, as drawn. Positions are taken off `base`, as the rows' frames start at the list's top. Decorative.
    private func boxes(layout: TabGroupLayout, current: TabGroupLayout.Positions,
                       target: TabGroupLayout.Positions) -> some View {
        let flare = TabStripMetrics.flare
        var hole: (start: CGFloat, end: CGFloat) = (0, 0)
        var holeLeading: CGFloat = 0
        if let index = model.selectedIndex, !model.tabs[index].pinned, !model.tabs[index].archived {
            // A tab or box drag holds the selected tab (a drag selects the pressed tab), which follows the pointer; a
            // header drag selects nothing, so the selected row follows it when in the dragged group, else stands at
            // its target.
            let y = (inDrag(index) ? (current.tabs[index] ?? 0) + dragOffset : target.tabs[index] ?? 0) - base
            hole = (y - flare, y + SidebarItemStyle.height + flare)
            holeLeading = indent(group(of: index, layout: layout))
        }
        return ZStack {
            ForEach(layout.boxes, id: \.key) { box in
                let follows = followsDrag(box)
                let drawn = follows
                    ? layout.boxSpan(box, at: current).map { (start: $0.start + dragOffset, end: $0.end + dragOffset) }
                    : layout.boxSpan(box, at: target)
                if let span = drawn {
                    // A grouped box's rows sit right of the group's line.
                    let leading = indent(group(of: box.range.lowerBound, layout: layout))
                    let shape = WorktreeBoxShape(axis: .vertical,
                                                 start: span.start - base - VerticalTabsMetrics.boxOutset,
                                                 end: span.end - base + VerticalTabsMetrics.boxOutset,
                                                 holeStart: hole.start, holeEnd: hole.end,
                                                 crossStart: leading - TabStripMetrics.rowInset,
                                                 crossEndInset: VerticalTabsMetrics.boxTrailing,
                                                 holeCrossStart: holeLeading, radius: VerticalTabsMetrics.boxRadius,
                                                 holeRadius: VerticalTabsMetrics.rowRadius, flare: flare)
                    ZStack {
                        shape.fill(Palette.worktreeBoxFill)
                        shape.edge.fill(Palette.worktreeBoxBorder)
                    }
                    // Others slide with their rows; a box that follows the pointer does so without lag.
                    .animation(dragging && !follows ? animation : nil, value: drag)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The tab at `index` is in the unit being dragged.
    private func inDrag(_ index: Int) -> Bool {
        dragging && drag?.range.contains(index) == true
    }

    /// The group the tab at `index` stands in as drawn: the one it would drop in while dragged.
    private func group(of index: Int, layout: TabGroupLayout) -> UUID? {
        inDrag(index) ? drag?.group : layout.group(at: index)?.id
    }

    /// A row's (or box's) leading room in a group, right of its line.
    private func indent(_ group: UUID?) -> CGFloat {
        group == nil ? 0 : VerticalTabsMetrics.groupIndent
    }

    /// The box moves with the drag: it is the dragged box or in the dragged group (not while one of its rows reorders
    /// inside it).
    private func followsDrag(_ box: WorktreeBox) -> Bool {
        guard dragging, let drag else { return false }
        if case .tab = drag.unit { return false }
        return drag.range.contains(box.range.lowerBound)
    }

    /// The tab strip's press, vertically: zero distance, so the tab is selected on mouse-down (⇧/⌘ pick it into the
    /// multi-selection instead, `TabPress`). Past `dragThreshold` it moves as a `TabArrangement.Unit` to the allowed
    /// place nearest the pointer (`TabGroupLayout.dragTarget`): a plain row joins or leaves groups; a worktree box's
    /// row reorders inside its box until the pointer leaves the box, then drags the whole box.
    private func press(_ id: WindowModel.Tab.ID, index: Int, layout: TabGroupLayout) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.listSpace))
            .onChanged { value in
                // `!= id` rather than `== nil`: a press that never ends (`onEnded` skipped) blocks only this row.
                if pressedID != id {
                    // A ⌃-click (a right-click) changes nothing and is not taken (its menu may skip `onEnded`), nor
                    // ever drags.
                    guard TabPress.current.pick(id, in: model) else { return }
                    pressedID = id
                }
                let translation = value.translation.height
                guard dragging || abs(translation) >= TabStripMetrics.dragThreshold else { return }
                let entries = model.arrangementEntries
                if !dragging {
                    // A ⇧/⌘ press turns into a plain drag: the dragged tab is always the selected one, alone.
                    model.clearSelection()
                    model.selectTab(id: id)
                    startDrag(.tab(id), layout: layout, entries: entries)
                }
                guard dragging, var next = drag else { return }
                // Once the pointer leaves its box (as the box stands at rest), a box row drags the whole box, to the
                // drag's end. A row's frame starts at its position less `base`.
                if case .tab = next.unit, let box = layout.boxes.first(where: { $0.range.contains(index) }),
                   let span = layout.boxSpan(box, at: layout.positions(order: Array(entries.indices), moving: nil,
                                                                      membership: nil)) {
                    let pointer = value.location.y + base
                    let unit = TabArrangement.Unit.box(box.key)
                    if pointer < span.start || pointer > span.end,
                       let range = TabGroupLayout.range(of: unit, in: entries) {
                        let group = layout.group(of: unit, in: entries)
                        next = TabDrag(unit: unit, range: range, index: range.lowerBound, group: group, origin: group)
                    }
                }
                dragOffset = translation
                retarget(next, translation: translation, layout: layout, entries: entries)
            }
            .onEnded { _ in
                pressedID = nil
                drop()
            }
    }

    /// The tab strip's chip press, vertically: zero distance, so the header tells a click from a drag itself. Released
    /// before `dragThreshold` it collapses or shows the group, on mouse-up (needed to tell the click from a drag). Past
    /// it the whole group moves among the top-level places (`TabGroupLayout.dragTarget`), selecting nothing. A ⌃-click
    /// is a right-click (`RightClickCatcher` opens the popover): never taken, so it never collapses.
    private func headerPress(_ group: TabGroup, layout: TabGroupLayout) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.listSpace))
            .onChanged { value in
                if pressedHeader != group.id {
                    guard TabPress.current != .secondary else { return }
                    pressedHeader = group.id
                }
                let translation = value.translation.height
                guard dragging || abs(translation) >= TabStripMetrics.dragThreshold else { return }
                let entries = model.arrangementEntries
                if !dragging { startDrag(.group(group.id), layout: layout, entries: entries) }
                guard dragging, let next = drag else { return }
                dragOffset = translation
                retarget(next, translation: translation, layout: layout, entries: entries)
            }
            .onEnded { _ in
                guard pressedHeader == group.id else { return }
                pressedHeader = nil
                if dragging {
                    drop()
                } else {
                    withAnimation(animation) { model.toggleGroup(group.id) }
                }
            }
    }

    /// A drag of `unit` begins where it stands, in its own group.
    private func startDrag(_ unit: TabArrangement.Unit, layout: TabGroupLayout, entries: [TabArrangement.Entry]) {
        guard let range = TabGroupLayout.range(of: unit, in: entries) else { return }
        let group = layout.group(of: unit, in: entries)
        drag = TabDrag(unit: unit, range: range, index: range.lowerBound, group: group, origin: group)
        dragging = true
    }

    /// The drag `next` aimed at the place and group it would drop in, dragged `translation` down the list.
    private func retarget(_ next: TabDrag, translation: CGFloat, layout: TabGroupLayout,
                          entries: [TabArrangement.Entry]) {
        var next = next
        let target = layout.dragTarget(unit: next.unit, translation: translation, current: next.group,
                                       entries: entries)
        next.index = target.index
        next.group = target.group
        if next != drag { drag = next }
    }

    /// Ends a drag: out of the window, to another window or back (`TabDragOut`); else back into its place with the
    /// lifted look when it would land where it stands, else moved there.
    private func drop() {
        guard dragging, let drag else { return }
        // Out of the window: never a reorder (`TabDragOut`).
        switch TabDragOut.outcome(of: drag.unit, in: model) {
        case .move(let id, let destination):
            // Reset without animation: the tab leaves this window.
            dragging = false
            dragOffset = 0
            TabDragOut.move(id, from: model, to: destination)
        case .inside where drag.index != drag.range.lowerBound || drag.group != drag.origin:
            // Reset without animation before the move, so the rows render at their new places directly.
            dragging = false
            dragOffset = 0
            model.moveUnit(drag.unit, to: drag.index, group: drag.group)
        case .inside, .snapBack:
            withAnimation(animation) {
                dragOffset = 0
                dragging = false
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
/// closed groups button (once the window has closed groups), the archive button (once the window has an archive), New
/// tab and the tab list in one row. The archive's line runs down the popped row's indent to the archive button, marking
/// the two as one group, as a group's line does under its name; with the closed groups button before the archive
/// button, the row and the line move right by that button and its gap (`archiveOffset`).
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
            // `TabStripButtons` pads itself by `rowInset`: the closed groups and archive buttons take the same inset on
            // their leading side, and the spacing gives back the other one, so the buttons stand `gap` apart.
            HStack(spacing: TabStripMetrics.gap - TabStripMetrics.rowInset) {
                if !model.closedGroups.isEmpty {
                    ClosedGroupsButton(model: model, popoverEdge: .trailing, height: SidebarItemStyle.height)
                        .padding(.leading, TabStripMetrics.rowInset)
                }
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

    /// How far the archive button stands right of the row's start: the closed groups button and its `gap` when shown.
    /// The popped row and the archive's line move by as much, so the line keeps meeting the archive button.
    private var archiveOffset: CGFloat {
        model.closedGroups.isEmpty ? 0 : ClosedGroupsButton.width(height: SidebarItemStyle.height) + TabStripMetrics.gap
    }

    /// The archive's line, down the middle of the popped row's indent from its top to the archive button's edge (the
    /// button's center lies right of the indent, so the line keeps to the indent as a group's does). The exact x and
    /// end are tuned against a QA shot. Decorative.
    private var line: some View {
        // The button is a rounded square: at the line's x (half the indent in from its leading edge), inside its
        // corner, its top edge lies lower than its frame's top, by this much, so the line runs on to meet the edge
        // instead of stopping short of it.
        let radius = ArchiveButton.radius(height: SidebarItemStyle.height)
        let dx = max(radius - VerticalTabsMetrics.groupIndent / 2, 0)
        let dip = radius - (radius * radius - dx * dx).squareRoot()
        return Capsule()
            .fill(TabGroupColors.archiveLine)
            // The row, its flares' room under it, then the button row's `rowInset` above the archive button.
            .frame(width: TabStripMetrics.groupLine,
                   height: SidebarItemStyle.height + TabStripMetrics.flare + TabStripMetrics.rowInset + dip)
            .offset(x: archiveOffset + TabStripMetrics.rowInset
                        + (VerticalTabsMetrics.groupIndent - TabStripMetrics.groupLine) / 2,
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
                              selected: tab.id == model.selectedTabID, multiSelected: false, dragged: false,
                              namespace: namespace,
                              onSelect: { model.selectTab(id: tab.id) },
                              onClose: { TabMenu.close(tab.id, model) })
            .frame(height: SidebarItemStyle.height)
            .background(MiddleClickCatcher { TabMenu.middleClick(tab.id, model) })
            // Outside the list's scroll view, so it needs its own: a press on the row never drags the window.
            .background(WindowDragBlocker())
            // Lined up with a group's rows in the list (moved by `archiveOffset`), right of the archive's line; none on
            // the trailing side, where the selected row meets the sheet.
            .padding(.leading, archiveOffset + TabStripMetrics.rowInset + VerticalTabsMetrics.groupIndent)
            .gesture(press(tab.id))
            .contextMenu { MenuEntriesView(entries: TabMenu.entries(for: tab.id, model: model, vertical: true)) }
            .id(tab.id)
    }

    /// Zero distance, so the row is selected on mouse-down (a tap would wait for mouse-up); no drag reorder. ⇧/⌘
    /// press it as a plain click, ⌃ leaves everything alone (`TabPress.pickAlone`).
    private func press(_ id: WindowModel.Tab.ID) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { _ in
                // `!= id` rather than `== nil`: a press that never ends (`onEnded` skipped) blocks only this row.
                if pressedID != id, TabPress.current.pickAlone(id, in: model) {
                    pressedID = id
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
/// (`lineLength` long, from under the header to the last row's end). `press` (the list's) tells a click from a drag: a
/// click collapses the group to its header alone, with no line, and shows its rows again; a drag moves the whole group.
/// A right click or ⌃-click opens its popover (`TabGroupPopover`).
private struct VerticalTabGroupHeader<Press: Gesture>: View {
    let model: WindowModel
    let group: TabGroup
    let collapsed: Bool
    let lineLength: CGFloat
    let press: Press
    /// The click's action, for accessibility (`press` runs it for a real click).
    let onToggle: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: VerticalTabsMetrics.groupHeaderRadius, style: .continuous)
        let named = !group.name.isEmpty
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
            .gesture(press)
            .tabGroupPopover(model: model, groupID: group.id, arrowEdge: .trailing)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(group.accessibilityLabel)
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onToggle)
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
    /// In the multi-selection (`WindowModel.multiSelection`) but not the shown tab: a dim capsule.
    let multiSelected: Bool
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
            } else if multiSelected || hovered || dragged {
                Capsule()
                    .fill(multiSelected ? Palette.multiSelectFill : Palette.hoverFill)
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
/// color, a multi-selected one on the multi-select fill, a hovered one on a subtle fill, a worktree box's cells on the box's fill. A press selects on mouse-down; the
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
                                  multiSelected: tab.id != model.selectedTabID && model.multiSelection.contains(tab.id),
                                  onSelect: { model.selectTab(id: tab.id) })
            .background(MiddleClickCatcher { TabMenu.middleClick(tab.id, model) })
            .gesture(press(tab.id))
            .contextMenu { MenuEntriesView(entries: TabMenu.entries(for: tab.id, model: model, vertical: true)) }
            // A pinned tab shows no name: its tooltip leads with it, then the path when that says more.
            .help(path.map { $0 == tab.title ? tab.title : "\(tab.title)\n\($0)" } ?? tab.title)
            .id(tab.id)
    }

    /// Selects the tab on mouse-down, once per press; no drag. ⇧/⌘ press it as a plain click (a cell joins the
    /// multi-selection only through a ⇧-click on a row), ⌃ leaves everything alone (`TabPress.pickAlone`).
    private func press(_ id: WindowModel.Tab.ID) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard pressedID != id, TabPress.current.pickAlone(id, in: model) else { return }
                pressedID = id
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
    /// In the multi-selection but not the selected tab: the multi-select fill.
    let multiSelected: Bool
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
                } else if multiSelected {
                    shape.fill(Palette.multiSelectFill)
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
