// The tab strip under the toolbar: the window's tabs, then New tab and the tab list (the command palette is the
// toolbar's Search), on the window glass. The selected tab is a tab of the page's sheet under it (`TabSheetShape`).
import AppKit
import HistqCore
import SwiftUI

/// Sizes of the tab strip. The unpinned tabs share one width, between `minTabWidth` and `maxTabWidth`; past that the
/// row scrolls. A pinned tab is `pinnedTabWidth` wide. The vertical tabs (`VerticalTabsPanel`) use the same drag threshold, slot and icon.
enum TabStripMetrics {
    /// Tall enough that New Tab and the tab list sit inside the row, clear of the sheet under it.
    static let tabHeight: CGFloat = 34
    /// Between two tabs.
    static let gap: CGFloat = 5
    /// Above the row inside its scroll view, so the hover fill's edge is not clipped. None below: the tabs' bottom is
    /// the sheet's top.
    static let rowInset: CGFloat = 1
    /// The selected tab's top corners: half its height, so its top reads as a capsule's.
    static let tabRadius: CGFloat = tabHeight / 2
    /// The concave curve at each bottom corner of the selected tab, into the sheet's top edge. The row has this much
    /// room on each side inside its scroll view, so the first and last tab's flares are not clipped.
    static let flare: CGFloat = 9
    /// The selected tab's soft shadow (`SelectedTabShadow`).
    static let selectedShadowRadius: CGFloat = 5
    /// New Tab and the tab list beside the tabs: smaller than the tabs, so they float above the sheet.
    static let buttonHeight: CGFloat = 24
    static let minTabWidth: CGFloat = 96
    static let maxTabWidth: CGFloat = 200
    /// The close button's square, and the matching empty slot before the title that keeps it centered.
    static let slot: CGFloat = 16
    /// The square a tab's emoji or book fills (`TabIcon`): the same as `slot`, so the icon takes the slot before the
    /// name and the name stays centered.
    static let icon: CGFloat = 16
    /// A pinned tab: its icon alone. At least 2 × `tabRadius`, so the selected tab's top arcs (`TabSheetShape`) fit.
    static let pinnedTabWidth: CGFloat = 44
    /// The profile color dot on a tab's icon's lower-right corner, and the white ring around it (outside the color).
    static let iconDot: CGFloat = 6
    static let iconDotRing: CGFloat = 1
    /// How far a press moves before it reorders the tab.
    static let dragThreshold: CGFloat = 5
    /// A tab group's line: under its chip and tabs, around its selected tab (and the vertical tabs' bar).
    static let groupLine: CGFloat = 1.5
    /// A manual group's chip, before its first tab: as tall as New Tab, a color square without a name, else as wide as
    /// its name, at most `groupChipMaxWidth`; a rounded rect, not a capsule.
    static let groupChipHeight: CGFloat = 20
    static let groupChipMaxWidth: CGFloat = 120
    static let groupChipPadding: CGFloat = 8
    static let groupChipRadius: CGFloat = 6
    static var groupChipFont: NSFont { .systemFont(ofSize: 11, weight: .semibold) }
    /// The closed groups and archive buttons at the strip's start: a rounded square, taller than a group's chip, and
    /// the gap between the two, wider than `gap` so the two squares read apart.
    static let stowButtonSize: CGFloat = 26
    static let stowButtonGap: CGFloat = 8
    /// The archived tab popped out beside the archive button (`ArchiveCluster`): one fixed width, outside the track.
    static let archivedTabWidth: CGFloat = 160
    /// How far the archive button sits left of the strip's start, and the room it adds after itself, so it stands as
    /// far from the sheet's left edge (`HeaderMetrics.tabRowLeading` minus this) as from what follows it (`gap` plus
    /// this). The tabs after it do not move. The closed groups button, when shown before it, is pulled the same
    /// (`TabStrip`).
    static let archiveShift: CGFloat = (HeaderMetrics.tabRowLeading - gap) / 2

    /// A worktree box (`WorktreeBoxShape`): this far in from its first and last tab's edges, so two boxes side by side
    /// (and a box beside a plain tab) keep a clear line between them; from the tabs' top to the hover fill's bottom,
    /// 3 pt clear of a group's line along the strip's bottom (and of the sheet). A capsule: with that inset its round
    /// ends sit inside the selected tab's top arcs, so a selected first or last tab hides the box's end.
    static let boxInset: CGFloat = 1.5
    static let boxBottomInset: CGFloat = 4.5
    static let boxRadius: CGFloat = .infinity

    /// A group's chip width for its name: a square without one.
    static func groupChipWidth(_ name: String) -> CGFloat {
        guard !name.isEmpty else { return groupChipHeight }
        let text = (name as NSString).size(withAttributes: [.font: groupChipFont]).width
        return max(groupChipHeight, min(groupChipMaxWidth, ceil(text) + 2 * groupChipPadding))
    }
}

/// A manual group's color by its swatch (`ManualTabGroup.colorIndex`: 0 the grey, 1–8 `Palette.graphLanes`) and its
/// chip's fill (the graph badges' fill), and the archive's fixed pair.
enum TabGroupColors {
    static func line(_ colorIndex: Int) -> Color {
        let index = swatch(colorIndex)
        return Color(nsColor: index == 0 ? Palette.groupGrey : Palette.graphLanes[index - 1])
    }

    static func chip(_ colorIndex: Int) -> Color {
        let index = swatch(colorIndex)
        return Color(nsColor: index == 0 ? Palette.groupGreyFill : Palette.graphBadgeFills[index - 1])
    }

    /// The swatch, wrapped into range: a hand-edited `session.json` may hold any number.
    private static func swatch(_ colorIndex: Int) -> Int {
        let count = Palette.graphLanes.count + 1
        return (colorIndex % count + count) % count
    }

    /// A dot in the group's line color, for its entry in a tab's Add Tab to Group menu. Not a template image, so the
    /// menu keeps its color.
    static func dot(_ colorIndex: Int) -> NSImage {
        let color = NSColor(line(colorIndex))
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { _ in
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 8, height: 8)).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Group color"
        return image
    }

    /// The archive's lane: index 1, the orange (#FC9F30), whatever the repos' groups take.
    private static let archiveLane = 1

    /// The archive's line, under the archive button and the popped-out archived tab, and that tab's outline.
    static let archiveLine = Color(nsColor: Palette.graphLanes[archiveLane])
    /// The archive button's fill.
    static let archiveChip = Color(nsColor: Palette.graphBadgeFills[archiveLane])
}

/// The closed groups button (once the window has closed groups), the archive button with the popped-out archived tab
/// (once the window has an archive), the window's tabs, then New Tab and the tab list. A press on a tab selects it at
/// once (on mouse-down); a drag past a few points reorders it.
struct TabStrip: View {
    @Environment(WindowModel.self) private var model
    /// Shared by the track and the archive's popped-out tab, so the selected tab's shape slides between them.
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 12) {
            // The archive sits `gap` from the first tab, as the track's items sit from each other: the cluster ends with
            // flare room (the button's or the popped tab's) and the track starts with its first tab's, so the two
            // overlap by both. Above the track, so the overlap's clicks reach the button or the popped tab.
            HStack(spacing: 0) {
                let archive = !model.archivedTabs.isEmpty || model.archivedOut != nil
                if !model.closedGroups.isEmpty {
                    closedGroupsButton(beforeArchive: archive)
                }
                if archive {
                    ArchiveCluster(model: model, namespace: namespace)
                        .padding(.trailing, TabStripMetrics.gap - 2 * TabStripMetrics.flare)
                        .zIndex(1)
                }
                TabTrack(model: model, namespace: namespace)
            }
            TabStripButtons(model: model, popoverEdge: .bottom, buttonHeight: TabStripMetrics.buttonHeight)
        }
        .spotlightTarget(.tabStrip)
    }

    /// The closed groups button at the strip's start, pulled `archiveShift` left as the archive button is alone. Before
    /// the archive, it leaves `stowButtonGap` to the archive button (whose own pull takes back `archiveShift`), so the archive
    /// button, its line and popped tab keep their place against the tabs. Alone, it ends as the archive button does
    /// alone: flare room and `archiveShift` after it, overlapping the track's first flare room.
    private func closedGroupsButton(beforeArchive: Bool) -> some View {
        let flare = TabStripMetrics.flare
        let shift = TabStripMetrics.archiveShift
        return ClosedGroupsButton(model: model, popoverEdge: .bottom, height: TabStripMetrics.stowButtonSize)
            .frame(height: TabStripMetrics.tabHeight)
            .padding(.leading, -shift)
            .padding(.trailing, beforeArchive ? TabStripMetrics.stowButtonGap + shift
                                              : flare + shift + TabStripMetrics.gap - 2 * flare)
            .padding(.top, TabStripMetrics.rowInset)
            .frame(height: TabStripMetrics.tabHeight + TabStripMetrics.rowInset)
            .zIndex(1)
    }
}

/// New Tab and the tab list's chevron: secondary filled circles, as tall as the tabs, so they
/// read as buttons inside the tab row's container. The vertical tabs show the same two at their bottom.
struct TabStripButtons: View {
    let model: WindowModel
    /// Where the tab list's popover opens from the chevron.
    let popoverEdge: Edge
    /// The vertical tabs' default: as tall as their rows.
    var buttonHeight = SidebarItemStyle.height
    @State private var showingTabList = false

    var body: some View {
        HStack(spacing: TabStripMetrics.gap) {
            Button { model.openTab(nil) } label: {
                Label("New Tab", systemImage: "plus")
            }
            .help("New Tab")
            Button { showingTabList.toggle() } label: {
                Label("All Tabs", systemImage: "chevron.down")
            }
            .help("All Tabs")
            .popover(isPresented: $showingTabList, arrowEdge: popoverEdge) {
                TabListPopover(model: model, isPresented: $showingTabList)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(BottomBarButtonStyle(height: buttonHeight, horizontalPadding: 0))
        .padding(TabStripMetrics.rowInset)
        .background(WindowDragBlocker())
    }
}

/// The tabs with a small gap: the pinned tabs first, narrow (`pinnedTabWidth`, their icon alone), then the others in
/// equal widths; no fill (a subtle one on hover), and the selected tab's sheet-colored shape that slides to the next
/// selection. A manual tab group (`WindowModel.manualGroups`) has its name chip
/// before its first tab, its color as one line under the chip and its tabs (`TabGroupLine`, open where the selected
/// tab stands, live during a drag), and as the selected tab's outline. A worktree box (`WorktreeBoxShape`) is drawn
/// behind its tabs, with the selected tab's shape cut out of it. Two arrows at the strip's end (before New Tab)
/// scroll the row a page each way, disabled while the tabs fit; a cut edge fades out. The popped-out archived tab is not here: it
/// stands beside the archive button (`ArchiveCluster`); last in `tabs`, it takes no room, so no other tab moves.
private struct TabTrack: View {
    let model: WindowModel
    /// The strip's, shared with `ArchiveCluster`.
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The tab under the current mouse press, so a press selects once.
    @State private var pressedID: WindowModel.Tab.ID?
    /// The group chip under the current mouse press, so its mouse-up collapses only a press it took.
    @State private var pressedChip: UUID?
    /// A drag is under way (a tab, a worktree box or a group by its chip), its offset along the row, and what it moves
    /// and where it would land. `drag` stays stale after a drag on purpose: clearing it would change the neighbors'
    /// animation value and cancel the slide back.
    @State private var dragging = false
    @State private var dragOffset: CGFloat = 0
    @State private var drag: TabDrag?
    /// Where the scroll arrows move the row; a selection still scrolls through the `ScrollViewReader`.
    @State private var position = ScrollPosition()
    /// Whether the row can scroll each way: the arrows' enabled states, set only when one flips.
    @State private var edges = ScrollEdges()
    /// The row's last scroll geometry, outside the view's state so scrolling does not redraw the tabs.
    @State private var scrollGeometry = ScrollGeometryBox()

    /// The row's coordinate space: a press's pointer along the row, where the layout's positions stand (each item's
    /// frame starts at its position).
    private static let rowSpace = "tabRow"
    /// Between the tabs and the scroll arrows: as far as the strip puts New Tab from the tabs.
    private static let arrowSpacing: CGFloat = 12
    /// The scroll arrows, with their spacing before them.
    private static let arrowsWidth = arrowSpacing + 2 * TabStripMetrics.buttonHeight + TabStripMetrics.gap
        + 2 * TabStripMetrics.rowInset

    var body: some View {
        GeometryReader { proxy in
            let groups = model.manualGroups
            // A collapsed group's tabs take no room.
            let hidden = Set(groups.filter { model.isCollapsed($0.id) }.flatMap(\.range))
            let shown = model.tabs.indices.filter { !hidden.contains($0) && !model.tabs[$0].archived }
            let pinned = CGFloat(shown.filter { model.tabs[$0].pinned }.count)
            let count = shown.count
            let unpinned = CGFloat(count) - pinned
            let chips = groups.reduce(0) { $0 + TabStripMetrics.groupChipWidth($1.name) }
            let items = count + groups.count
            let gaps = TabStripMetrics.gap * CGFloat(max(items - 1, 0)) + 2 * TabStripMetrics.flare
            let pinnedWidth = pinned * TabStripMetrics.pinnedTabWidth
            // The scroll arrows always stand at the strip's end, before New Tab; the tabs get the rest.
            let available = proxy.size.width - Self.arrowsWidth
            // The unpinned tabs share what the pinned ones, the chips and the gaps leave. Whole points, so the tabs'
            // frames stand where the layout says, unsnapped: a worktree box's hole then meets the selected tab exactly.
            let tabWidth = min(TabStripMetrics.maxTabWidth,
                               max(TabStripMetrics.minTabWidth,
                                   floor((available - gaps - chips - pinnedWidth) / max(unpinned, 1))))
            let rowWidth = tabWidth * unpinned + pinnedWidth + chips + gaps
            let overflows = rowWidth > available
            HStack(spacing: 0) {
                ScrollViewReader { scroller in
                    ScrollView(.horizontal, showsIndicators: false) {
                        row(layout: TabGroupLayout(tabs: model.tabs, groups: groups, boxes: model.worktreeBoxes,
                                                   tabExtent: tabWidth,
                                                   gap: TabStripMetrics.gap,
                                                   extent: { model.tabs[$0].archived ? 0
                                                       : model.tabs[$0].pinned ? TabStripMetrics.pinnedTabWidth
                                                       : tabWidth },
                                                   headerExtent: { TabStripMetrics.groupChipWidth($0.name) }))
                    }
                    .scrollPosition($position)
                    .scrollDisabled(!overflows)
                    .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, geometry in
                        scrollGeometry.value = geometry
                        let next = ScrollEdges(geometry)
                        if next != edges { withAnimation(animation) { edges = next } }
                    }
                    // The tabs cut by an edge fade out into the strip, rather than end on a hard line.
                    .mask(EdgeFade(leading: edges.leading, trailing: edges.trailing))
                    .frame(width: min(rowWidth, available))
                    .background(WindowDragBlocker())
                    .onChange(of: model.selectedTabID) { _, id in
                        guard let id else { return }
                        // On the next turn: a new tab is selected in the same update that adds it, before the row
                        // has laid it out, so scrolling now would stop short of it.
                        DispatchQueue.main.async { withAnimation(animation) { scroller.scrollTo(id) } }
                    }
                    .onChange(of: model.groupPopoverID) { _, id in
                        guard let id else { return }
                        // On the next turn, as a selection (a new group's chip is not laid out yet), and unanimated,
                        // so the popover (`TabGroupPopoverAnchor`) anchors to the chip where it stops.
                        DispatchQueue.main.async { scroller.scrollTo(id) }
                    }
                }
                Spacer(minLength: 0)
                scrollArrows
                    .padding(.leading, Self.arrowSpacing)
            }
            // Only the tabs take clicks: the empty space after them drags the window.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: TabStripMetrics.tabHeight + TabStripMetrics.rowInset)
    }

    private var animation: Animation? { reduceMotion ? nil : Motion.standard }

    /// Scroll the row a page left or right, styled as New Tab and the tab list; each is disabled at its end, both
    /// while the tabs fit.
    private var scrollArrows: some View {
        HStack(spacing: TabStripMetrics.gap) {
            Button { scrollRow(by: -1) } label: {
                Label("Scroll Tabs Left", systemImage: "chevron.left")
            }
            .help("Scroll Tabs Left")
            .disabled(!edges.leading)
            Button { scrollRow(by: 1) } label: {
                Label("Scroll Tabs Right", systemImage: "chevron.right")
            }
            .help("Scroll Tabs Right")
            .disabled(!edges.trailing)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(BottomBarButtonStyle(height: TabStripMetrics.buttonHeight, horizontalPadding: 0))
        .padding(TabStripMetrics.rowInset)
        .background(WindowDragBlocker())
    }

    /// Scrolls the row by its visible width less one tab (so a tab stays in view across the jump), within its ends.
    private func scrollRow(by direction: CGFloat) {
        guard let geometry = scrollGeometry.value else { return }
        let visible = geometry.visibleRect
        let step = max(visible.width - TabStripMetrics.minTabWidth, TabStripMetrics.minTabWidth)
        let end = max(geometry.contentSize.width - visible.width, 0)
        let x = min(max(visible.minX + direction * step, 0), end)
        withAnimation(animation) { position.scrollTo(x: x) }
    }

    private func row(layout: TabGroupLayout) -> some View {
        let current = layout.positions(order: Array(model.tabs.indices), moving: nil, membership: nil)
        let active = dragging ? drag : nil
        // While a unit is dragged, the others (and the chips) stand where they would with it dropped at its target, in
        // the group it would be in; its own tabs (and a dragged group's chip) follow the pointer.
        let target = active.map { drag in
            layout.positions(order: TabGroupLayout.moved(model.tabs.count, drag.range, to: drag.index),
                             moving: drag.range, membership: drag.group)
        } ?? current
        // The selected tab's start as drawn, so each group's line opens right under it and each box's hole follows it:
        // a tab or box drag holds the selected tab (a drag selects the pressed tab), which follows the pointer; a chip
        // drag selects nothing, so the selected tab follows it when in the dragged group, else stands at its target.
        // None while the popped-out archived tab is selected: it stands beside the archive button, not at its
        // zero-width place here.
        let selected = model.selectedIndex.flatMap { model.tabs[$0].archived ? nil : $0 }
        let selectedX = selected.map { index in
            active?.range.contains(index) == true ? (current.tabs[index] ?? 0) + dragOffset : target.tabs[index] ?? 0
        }
        // Each item carries its flares' room on both sides (overlapping its neighbors' by the negative spacing), so
        // scrolling to a tab at an edge keeps its flares in view; the items still sit `gap` apart.
        return HStack(spacing: TabStripMetrics.gap - 2 * TabStripMetrics.flare) {
            ForEach(layout.items.filter(isShown)) { item in
                switch item {
                case .header(let group):
                    let dragged = active?.unit == .group(group.id)
                    // A group left with no tab by the drag has no target header: hidden (still in the row, which
                    // `current` counts), it goes on the drop.
                    let targetX = target.headers[group.key]
                    let chipX = dragged ? (current.headers[group.key] ?? 0) + dragOffset : targetX ?? 0
                    // The selected tab, flares included, along the line (outside it when no tab of the group is).
                    let opening = selectedX.map { $0 - chipX - TabStripMetrics.flare } ?? -.greatestFiniteMagnitude
                    TabGroupChip(model: model, group: group, collapsed: layout.collapsed.contains(group.key),
                                 width: layout.headerExtents[group.key] ?? 0,
                                 span: layout.span(of: group.key, at: target) ?? 0, opening: opening,
                                 openingWidth: (selected.map(layout.extent(of:)) ?? layout.tabExtent)
                                     + 2 * TabStripMetrics.flare,
                                 press: chipPress(group, layout: layout),
                                 onToggle: { withAnimation(animation) { model.toggleGroup(group.id) } })
                        .padding(.horizontal, TabStripMetrics.flare)
                        .offset(x: chipX - (current.headers[group.key] ?? 0))
                        .opacity(dragged || targetX != nil ? 1 : 0)
                        .allowsHitTesting(dragged || targetX != nil)
                        // Others slide aside; the dragged chip tracks the pointer without lag.
                        .animation(dragging && !dragged ? animation : nil, value: drag)
                        .zIndex(dragged ? 2 : 0)
                        // So its popover's opening can scroll it into view.
                        .id(group.id)
                case .tab(let index, let tab):
                    tabView(index: index, tab: tab, layout: layout, current: current, target: target)
                }
            }
        }
        // Inside the selection's animation, so each box's hole slides with the selected tab's shape.
        .background { boxes(layout: layout, current: current, target: target, selectedX: selectedX) }
        .coordinateSpace(.named(Self.rowSpace))
        .padding(.top, TabStripMetrics.rowInset)
        // The selected tab's shape slides, also for a selection made elsewhere (a menu, the tab list).
        .animation(animation, value: model.selectedTabID)
    }

    /// The worktree boxes behind their tabs, at the tabs' target positions (so they move with a drag; a dragged box,
    /// or one in a dragged group, follows the pointer with its tabs), each with the selected tab's shape cut out where
    /// it reaches: at `selectedX` (as drawn), or the popped-out archived tab's beside the archive button, whose flare
    /// reaches a first box. Decorative.
    private func boxes(layout: TabGroupLayout, current: TabGroupLayout.Positions, target: TabGroupLayout.Positions,
                       selectedX: CGFloat?) -> some View {
        let flare = TabStripMetrics.flare
        // The selected shape's rect along the row: a tab's frame stands at its position plus its flare room.
        var hole: (start: CGFloat, end: CGFloat) = (0, 0)
        if let selectedX, let index = model.selectedIndex {
            hole = (selectedX, selectedX + layout.extent(of: index) + 2 * flare)
        } else if model.archivedOut != nil, model.selectedTabID == model.archivedOut?.id {
            // The popped tab's frame ends `gap` before the track's first item (`TabStrip`).
            hole = (-TabStripMetrics.gap - TabStripMetrics.archivedTabWidth, 2 * flare - TabStripMetrics.gap)
        }
        return ZStack {
            ForEach(layout.boxes, id: \.key) { box in
                let follows = followsDrag(box)
                let drawn = follows
                    ? layout.boxSpan(box, at: current).map { (start: $0.start + dragOffset, end: $0.end + dragOffset) }
                    : layout.boxSpan(box, at: target)
                if let span = drawn {
                    let shape = WorktreeBoxShape(axis: .horizontal,
                                                 start: span.start + flare + TabStripMetrics.boxInset,
                                                 end: span.end + flare - TabStripMetrics.boxInset,
                                                 holeStart: hole.start, holeEnd: hole.end,
                                                 crossStart: 0,
                                                 crossEndInset: TabStripMetrics.boxBottomInset,
                                                 holeCrossStart: 0, radius: TabStripMetrics.boxRadius,
                                                 holeRadius: TabStripMetrics.tabRadius, flare: flare)
                    ZStack {
                        shape.fill(Palette.worktreeBoxFill)
                        shape.edge.fill(Palette.worktreeBoxBorder)
                    }
                    // Others slide with their tabs; a box that follows the pointer does so without lag.
                    .animation(dragging && !follows ? animation : nil, value: drag)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The box moves with the drag: it is the dragged box or in the dragged group (not while one of its tabs reorders
    /// inside it).
    private func followsDrag(_ box: WorktreeBox) -> Bool {
        guard dragging, let drag else { return false }
        if case .tab = drag.unit { return false }
        return drag.range.contains(box.range.lowerBound)
    }

    /// Every item but the popped-out archived tab, which `ArchiveCluster` draws.
    private func isShown(_ item: TabGroupLayout.Item) -> Bool {
        if case .tab(_, let tab) = item { return !tab.archived }
        return true
    }

    private func tabView(index: Int, tab: WindowModel.Tab, layout: TabGroupLayout, current: TabGroupLayout.Positions,
                         target: TabGroupLayout.Positions) -> some View {
        let selected = tab.id == model.selectedTabID
        // In the dragged unit: the tab, its box or its group.
        let dragged = dragging && drag?.range.contains(index) == true
        let profile = model.profile(of: tab)
        // A dragged tab's outline takes the group it would drop in, so its flares meet that group's line.
        let group = dragged ? drag?.group.flatMap { id in model.manualGroups.first { $0.id == id } }
            : layout.group(at: index)
        let offset = dragged ? dragOffset : (target.tabs[index] ?? 0) - (current.tabs[index] ?? 0)
        return TabItem(title: tab.title, help: tab.repoURL?.path ?? tab.title, emoji: tab.emoji,
                       symbol: TabIcon.symbol(of: tab), pinned: tab.pinned, iconColor: tab.iconColor,
                       profileColor: profile?.color,
                       profileName: profile?.name, groupName: group?.group.name,
                       groupColor: group.map { TabGroupColors.line($0.group.colorIndex) },
                       selected: selected, multiSelected: !selected && model.multiSelection.contains(tab.id),
                       dragged: dragged, namespace: namespace,
                       onSelect: { model.selectTab(id: tab.id) },
                       onClose: { close(tab.id) })
            .frame(width: layout.extent(of: index), height: TabStripMetrics.tabHeight)
            // The tab itself, not its flares' room, which overlaps its neighbors'.
            .background(MiddleClickCatcher { TabMenu.middleClick(tab.id, model) })
            .padding(.horizontal, TabStripMetrics.flare)
            .offset(x: offset)
            // Neighbors slide aside; the dragged tabs track the pointer without lag.
            .animation(dragging && !dragged ? animation : nil, value: drag)
            // The dragged tabs above the others; the selected tab's flares lie over its neighbors' edges.
            .zIndex((dragged ? 2 : 0) + (selected ? 1 : 0))
            .gesture(press(tab.id, index: index, layout: layout))
            .contextMenu { MenuEntriesView(entries: TabMenu.entries(for: tab.id, model: model, vertical: false)) }
            .id(tab.id)
    }

    /// Zero distance, so the tab is selected on mouse-down (a tap would wait for mouse-up); ⇧/⌘ pick it into the
    /// multi-selection instead (`TabPress`). Past `dragThreshold` it moves as a `TabArrangement.Unit` to the allowed
    /// place nearest the pointer (`TabGroupLayout.dragTarget`): a plain tab joins or leaves groups (a pinned one never
    /// joins); a worktree box's tab reorders inside its box until the pointer leaves the box, then drags the whole box.
    private func press(_ id: WindowModel.Tab.ID, index: Int, layout: TabGroupLayout) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.rowSpace))
            .onChanged { value in
                // `!= id` rather than `== nil`: a press that never ends (`onEnded` skipped) blocks only this tab.
                if pressedID != id {
                    // A ⌃-click is a right-click: its menu acts on the tab or the multi-selection, so nothing changes
                    // and the press is not taken (its menu may skip `onEnded`), nor ever drags.
                    guard TabPress.current.pick(id, in: model) else { return }
                    pressedID = id
                }
                let translation = value.translation.width
                guard dragging || abs(translation) >= TabStripMetrics.dragThreshold else { return }
                let entries = model.arrangementEntries
                if !dragging {
                    // A ⇧/⌘ press turns into a plain drag: the dragged tab is always the selected one, alone.
                    model.clearSelection()
                    model.selectTab(id: id)
                    startDrag(.tab(id), layout: layout, entries: entries)
                }
                guard dragging, var next = drag else { return }
                // Once the pointer leaves its box (as the box stands at rest), a box tab drags the whole box, to the
                // drag's end. A tab's frame starts at its position, its content `flare` in.
                if case .tab = next.unit, let box = layout.boxes.first(where: { $0.range.contains(index) }),
                   let span = layout.boxSpan(box, at: layout.positions(order: Array(entries.indices), moving: nil,
                                                                      membership: nil)) {
                    let pointer = value.location.x - TabStripMetrics.flare
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

    /// Zero distance, so the chip tells a click from a drag itself. Released before `dragThreshold` it collapses or
    /// shows the group, on mouse-up: a deliberate exception to "a click reacts at once", needed to tell the click from
    /// a drag. Past it the whole group moves among the top-level places (`TabGroupLayout.dragTarget`), selecting
    /// nothing. A ⌃-click is a right-click (`RightClickCatcher` opens the popover): never taken, so it never collapses.
    private func chipPress(_ group: TabGroup, layout: TabGroupLayout) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.rowSpace))
            .onChanged { value in
                if pressedChip != group.id {
                    guard TabPress.current != .secondary else { return }
                    pressedChip = group.id
                }
                let translation = value.translation.width
                guard dragging || abs(translation) >= TabStripMetrics.dragThreshold else { return }
                let entries = model.arrangementEntries
                if !dragging { startDrag(.group(group.id), layout: layout, entries: entries) }
                guard dragging, let next = drag else { return }
                dragOffset = translation
                retarget(next, translation: translation, layout: layout, entries: entries)
            }
            .onEnded { _ in
                guard pressedChip == group.id else { return }
                pressedChip = nil
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

    /// The drag `next` aimed at the place and group it would drop in, dragged `translation` along the row.
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
            // Reset without animation before the move, so the tabs render at their new places directly.
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

/// What a tab drag moves (a tab, a worktree box or a whole group), its tabs' indices before it moves, and where it
/// would land: its first tab's index once moved and the group it would be in (`TabGroupLayout.dragTarget`), with the
/// group it started in. Shared by the tab strip and the vertical tabs.
struct TabDrag: Equatable {
    var unit: TabArrangement.Unit
    var range: ClosedRange<Int>
    var index: Int
    var group: UUID?
    let origin: UUID?
}

/// A tab drag that ends with the pointer outside its window (in screen coordinates) never reorders: a lone tab moves to
/// the Histq window under the pointer (`AppDelegate.moveTab`); a worktree box or a group, a refused move (its reason
/// as a toast in the source window) or no Histq window there snaps back. Shared by the tab strip and the vertical tabs;
/// Move Tab to Window › and the palette move through `move` too.
@MainActor
enum TabDragOut {
    /// What the end of a drag of `unit` out of `model`'s window does.
    enum Outcome {
        /// The pointer is inside the window: an in-window drop.
        case inside
        /// The tab may move to `destination` (no refusal): the drag's state resets before `move`.
        case move(WindowModel.Tab.ID, to: WindowModel)
        /// Back into place, the order, pins and groups as before the drag.
        case snapBack
    }

    static func outcome(of unit: TabArrangement.Unit, in model: WindowModel) -> Outcome {
        let point = NSEvent.mouseLocation
        guard let window = model.window, !window.frame.contains(point) else { return .inside }
        guard case .tab(let id) = unit, let app = NSApp.delegate as? AppDelegate else { return .snapBack }
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard let destination = app.moveDestinations(for: model).first(where: { $0.window?.windowNumber == number })
        else { return .snapBack }
        if let reason = app.moveRefusal(id, from: model, to: destination) {
            refused(reason, in: model)
            return .snapBack
        }
        return .move(id, to: destination)
    }

    /// Moves the tab (`AppDelegate.moveTab`); a late refusal shows as a toast in the source window.
    static func move(_ id: WindowModel.Tab.ID, from model: WindowModel, to destination: WindowModel) {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        if case .refused(let reason) = app.moveTab(id, from: model, to: destination) { refused(reason, in: model) }
    }

    private static func refused(_ reason: String, in model: WindowModel) {
        model.showToast(.warning("Move Tab to Window", detail: reason))
    }
}

/// Whether a scrolled row has more to show before (`leading`) and after (`trailing`) its visible part.
private struct ScrollEdges: Equatable {
    var leading = false
    var trailing = false

    init() {}

    init(_ geometry: ScrollGeometry) {
        leading = geometry.visibleRect.minX > 0.5
        trailing = geometry.visibleRect.maxX < geometry.contentSize.width - 0.5
    }
}

/// The scrolled row's mask: opaque, fading out over `width` at each edge that has more beyond it.
private struct EdgeFade: View {
    let leading: Bool
    let trailing: Bool
    static let width: CGFloat = 28

    var body: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [leading ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: Self.width)
            Rectangle()
            LinearGradient(colors: [.black, trailing ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: Self.width)
        }
    }
}

/// Holds the latest scroll geometry without being observed, so writing it on every scroll frame redraws nothing.
private final class ScrollGeometryBox {
    var value: ScrollGeometry?
}

/// The strip's far left (after the closed groups button, when shown), before the pinned tabs: the archive button and
/// the archived tab popped out beside it (`WindowModel.archivedOut`), one group marked by the archive's line under both
/// (`TabGroupLine`), open under the popped tab while it is selected, as a group's line is. With nothing popped out, the
/// button alone, with no line. A press selects the popped tab at once (on mouse-down); it never reorders.
private struct ArchiveCluster: View {
    let model: WindowModel
    /// The strip's, shared with `TabTrack`, so the selected tab's shape slides between them.
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The popped tab under the current mouse press, so a press selects once.
    @State private var pressedID: WindowModel.Tab.ID?

    var body: some View {
        let buttonWidth = ArchiveButton.width(height: TabStripMetrics.stowButtonSize)
        // The popped tab carries its flares' room on both sides, the button only on its trailing side (none before it,
        // at the strip's start); the two sit `gap` apart, plus `archiveShift`: the button moves that much left of the
        // strip's start and keeps the room after it, so it has as much space on each side.
        HStack(spacing: TabStripMetrics.gap - 2 * TabStripMetrics.flare) {
            ArchiveButton(model: model, popoverEdge: .bottom, height: TabStripMetrics.stowButtonSize)
                .frame(height: TabStripMetrics.tabHeight)
                .overlay(alignment: .bottomLeading) {
                    if let tab = model.archivedOut {
                        line(tabStart: buttonWidth + TabStripMetrics.gap + TabStripMetrics.archiveShift,
                             selected: tab.id == model.selectedTabID)
                    }
                }
                .padding(.trailing, TabStripMetrics.flare + TabStripMetrics.archiveShift)
            if let tab = model.archivedOut {
                tabView(tab)
            }
        }
        .padding(.leading, -TabStripMetrics.archiveShift)
        .padding(.top, TabStripMetrics.rowInset)
        // The selected tab's shape slides, also for a selection made elsewhere (the archive's list, the tab list).
        .animation(reduceMotion ? nil : Motion.standard, value: model.selectedTabID)
        .frame(height: TabStripMetrics.tabHeight + TabStripMetrics.rowInset)
    }

    /// The archive's line from the button's start to the popped tab's end (`tabStart` from the button's start), open
    /// under the tab, flares included, while it is selected.
    private func line(tabStart: CGFloat, selected: Bool) -> some View {
        let opening = selected ? tabStart - TabStripMetrics.flare : -.greatestFiniteMagnitude
        return TabGroupLine(opening: opening,
                            openingEnd: opening + TabStripMetrics.archivedTabWidth + 2 * TabStripMetrics.flare)
            .fill(TabGroupColors.archiveLine)
            .frame(width: tabStart + TabStripMetrics.archivedTabWidth)
            .allowsHitTesting(false)
    }

    /// The popped-out tab, as the track draws a tab, in the archive's color (its outline meets the archive's line).
    private func tabView(_ tab: WindowModel.Tab) -> some View {
        let selected = tab.id == model.selectedTabID
        let profile = model.profile(of: tab)
        return TabItem(title: tab.title, help: tab.repoURL?.path ?? tab.title, emoji: tab.emoji,
                       symbol: TabIcon.symbol(of: tab), pinned: false, iconColor: tab.iconColor,
                       profileColor: profile?.color, profileName: profile?.name, groupName: nil,
                       groupColor: TabGroupColors.archiveLine,
                       selected: selected, multiSelected: false, dragged: false, namespace: namespace,
                       onSelect: { model.selectTab(id: tab.id) },
                       onClose: { TabMenu.close(tab.id, model) })
            .frame(width: TabStripMetrics.archivedTabWidth, height: TabStripMetrics.tabHeight)
            // The tab itself, not its flares' room. Its own blocker: one around the whole cluster would let the window
            // move again once the pointer leaves the button's (each blocker's exit makes the window movable).
            .background(MiddleClickCatcher { TabMenu.middleClick(tab.id, model) })
            .background(WindowDragBlocker())
            .padding(.horizontal, TabStripMetrics.flare)
            // The selected tab's flares lie over the button's edge.
            .zIndex(selected ? 1 : 0)
            .gesture(press(tab.id))
            .contextMenu { MenuEntriesView(entries: TabMenu.entries(for: tab.id, model: model, vertical: false)) }
            .id(tab.id)
    }

    /// Zero distance, so the tab is selected on mouse-down (a tap would wait for mouse-up); no drag reorder. It is
    /// never in a multi-selection: ⇧/⌘ press it as a plain click, ⌃ leaves everything alone (`TabPress.pickAlone`).
    private func press(_ id: WindowModel.Tab.ID) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { _ in
                // `!= id` rather than `== nil`: a press that never ends (`onEnded` skipped) blocks only this tab.
                if pressedID != id, TabPress.current.pickAlone(id, in: model) {
                    pressedID = id
                }
            }
            .onEnded { _ in pressedID = nil }
    }
}

/// What a mouse-down on a tab does, from the modifier keys held as it goes down: a plain click ends the
/// multi-selection and selects the tab; ⇧ extends the multi-selection to it and ⌘ toggles it, neither changing the
/// shown tab; ⌃ (a right-click on macOS) changes nothing, so the tab's menu can act on the multi-selection.
enum TabPress {
    case plain, extend, toggle, secondary

    static var current: TabPress {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) { return .secondary }
        if flags.contains(.command) { return .toggle }
        if flags.contains(.shift) { return .extend }
        return .plain
    }

    /// Applies the press to the tab `id` of the tab list; false for a ⌃ press, which does nothing.
    @MainActor
    func pick(_ id: WindowModel.Tab.ID, in model: WindowModel) -> Bool {
        switch self {
        case .plain:
            model.clearSelection()
            model.selectTab(id: id)
        case .extend: model.extendSelection(to: id)
        case .toggle: model.toggleSelection(id)
        case .secondary: return false
        }
        return true
    }

    /// Applies the press to a tab that is never grouped (a vertical pinned cell, the popped-out archived tab): ⇧/⌘
    /// count as a plain click; false for a ⌃ press, which does nothing.
    @MainActor
    func pickAlone(_ id: WindowModel.Tab.ID, in model: WindowModel) -> Bool {
        (self == .secondary ? self : .plain).pick(id, in: model)
    }
}

/// A tab's right-click menu, in the tab strip and the vertical tabs (as Chrome's): Close Tab, Close Other Tabs, Close
/// Tabs to the Right (Below), each off when it has no tab to close (they never close the popped-out archived tab), with
/// Close Tabs on a multi-selection; then the group items (`groupEntries`): Add Tab to New Group, Add Tab to Group ›
/// and Remove from Group, plural on a multi-selection, which they act on whole when the tab is in it; then
/// Copy Path (off for a Welcome tab), Reveal in Finder (the tab's repo or worktree folder; off for a Welcome tab or a
/// missing folder), Set Alias…, Set Icon…, Icon Color (the book's), Pin Tab / Unpin Tab (Pin Worktree Tabs / Unpin
/// Worktree Tabs for a tab of a worktree box, which pins with it) and Archive This Tab, these five off for a Welcome
/// tab, then Move Tab to Window › (`moveToWindow`). On the popped-out archived tab, Unarchive Tab replaces Archive This Tab, and Pin Tab and Close Tabs to the
/// Right (Below) are off. Every item but Close Tabs and the group items acts on the right-clicked tab alone, even in a
/// multi-selection.
@MainActor
enum TabMenu {
    static func entries(for id: WindowModel.Tab.ID, model: WindowModel, vertical: Bool) -> [MenuEntry] {
        guard let index = model.tabs.firstIndex(where: { $0.id == id }) else { return [] }
        let tab = model.tabs[index]
        let isRepo = tab.repoURL != nil
        let revealable = isRepo && !tab.isMissing
        let boxed = model.worktreeBoxes.contains { $0.range.contains(index) }
        let pinTitle = (tab.pinned ? "Unpin " : "Pin ") + (boxed ? "Worktree Tabs" : "Tab")
        // The normal tabs: the popped-out archived tab, last, is never closed with others.
        let normalCount = model.tabs.count - (model.archivedOut == nil ? 0 : 1)
        // A right-click in a multi-selection acts on all of it; outside it, on this tab alone (the selection stays).
        let targets = model.multiSelection.contains(id) ? model.multiSelection : [id]
        let closeAll: [MenuEntry] = targets.count > 1
            ? [.action("Close Tabs") { if !model.closeTabs(targets) { model.closeWindow() } }] : []
        return [.action("Close Tab") { close(id, model) }] + closeAll + [
            .action("Close Other Tabs", enabled: normalCount - (tab.archived ? 0 : 1) > 0) {
                model.closeOtherTabs(id)
            },
            .action(vertical ? "Close Tabs Below" : "Close Tabs to the Right",
                    enabled: !tab.archived && index < normalCount - 1) { model.closeTabs(after: id) },
            .separator,
        ] + groupEntries(targets, model) + [
            .separator,
            .action("Copy Path", enabled: isRepo, toolTip: isRepo ? nil : "A new tab has no repository.") {
                if let url = tab.repoURL { RepoMenus.copy(url.path(percentEncoded: false)) }
            },
            .action("Reveal in Finder", enabled: revealable,
                    toolTip: revealable ? nil
                        : isRepo ? "The repository's folder is gone." : "A new tab has no repository.") {
                if let url = tab.repoURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            },
            .action("Set Alias…", enabled: isRepo, toolTip: isRepo ? nil : "A new tab has no repository to name.") {
                model.presentModal(.tabAlias(tabID: id))
            },
            .action("Set Icon…", enabled: isRepo, toolTip: isRepo ? nil : "A new tab has no repository to mark.") {
                model.presentModal(.tabEmoji(tabID: id))
            },
            isRepo ? .submenu("Icon Color", iconColors(id, tab, model))
                : .action("Icon Color", enabled: false, toolTip: "A new tab has no repository to mark.") {},
            .action(pinTitle, enabled: isRepo && !tab.archived,
                    toolTip: tab.archived ? "Unarchive the tab to pin it."
                        : isRepo ? nil : "A new tab has no repository to pin.") {
                model.setPinned(!tab.pinned, for: id)
            },
            archive(id, tab, isRepo, model),
            moveToWindow(id, tab, model),
        ] + profile(id, tab, revealable, model)
    }

    /// Add Tab(s) to New Group (its popover opens), Add Tab(s) to Group › (each other group: its color dot and its
    /// name, else its first two tabs' titles and "+N" for more) and Remove from Group (when one of the tabs is
    /// grouped), for the tabs `ids`; the model brings each worktree tab's whole box. All off when a tab is pinned or is
    /// the popped-out archived tab, which are never grouped.
    private static func groupEntries(_ ids: Set<WindowModel.Tab.ID>, _ model: WindowModel) -> [MenuEntry] {
        let tabs = model.tabs.filter { ids.contains($0.id) }
        let noun = ids.count > 1 ? "Tabs" : "Tab"
        let blocked = tabs.contains(where: \.pinned) ? "Unpin the tab to group it."
            : tabs.contains(where: \.archived) ? "Unarchive the tab to group it." : nil
        let groupIDs = Set(tabs.compactMap(\.groupID))
        // A group every tab is already in is left out: adding to it would do nothing.
        let others = model.manualGroups.filter { group in !tabs.allSatisfy { $0.groupID == group.id } }
        var entries: [MenuEntry] = [
            .action("Add \(noun) to New Group", enabled: blocked == nil, toolTip: blocked) { [weak model] in
                guard let model, let group = model.createGroup(from: ids) else { return }
                model.groupPopoverID = group
            },
        ]
        if !others.isEmpty {
            let title = "Add \(noun) to Group"
            entries.append(blocked.map { .action(title, enabled: false, toolTip: $0) {} }
                ?? .submenu(title, others.map { group in
                    .action(groupTitle(group, model), image: TabGroupColors.dot(group.group.colorIndex)) {
                        [weak model] in model?.addToGroup(group.id, ids: ids)
                    }
                }))
        }
        if !groupIDs.isEmpty {
            entries.append(.action("Remove from Group", enabled: blocked == nil, toolTip: blocked) { [weak model] in
                model?.removeFromGroup(ids: ids)
            })
        }
        return entries
    }

    /// A group's entry in Add Tab to Group ›: its name, else its first two tabs' titles, with "+N" for the rest.
    private static func groupTitle(_ group: TabGroup, _ model: WindowModel) -> String {
        if !group.name.isEmpty { return group.name }
        let titles = model.tabs[group.range].map(\.title)
        let more = titles.count > 2 ? " +\(titles.count - 2)" : ""
        return titles.prefix(2).joined(separator: ", ") + more
    }

    /// Archive This Tab (off for a Welcome tab), or Unarchive Tab on the popped-out archived tab.
    private static func archive(_ id: WindowModel.Tab.ID, _ tab: WindowModel.Tab, _ isRepo: Bool,
                                _ model: WindowModel) -> MenuEntry
    {
        if tab.archived { return .action("Unarchive Tab") { [weak model] in model?.unarchiveTab(id) } }
        return .action("Archive This Tab", enabled: isRepo,
                       toolTip: isRepo ? nil : "A new tab has no repository to archive.") {
            [weak model] in model?.archiveTab(id)
        }
    }

    /// Move Tab to Window ›: each other window (`windowTitle`), off with the reason as its tooltip when the move would
    /// be refused (`AppDelegate.moveRefusal`, no I/O). The right-clicked tab moves alone, even in a multi-selection. Its
    /// entries are built when it opens (`lazySubmenu`): the tab strip's body never reads the other windows, so a tab
    /// switch in one window redraws no tab in another, and the list is current when shown.
    private static func moveToWindow(_ id: WindowModel.Tab.ID, _ tab: WindowModel.Tab, _ model: WindowModel)
        -> MenuEntry
    {
        let title = "Move Tab to Window"
        guard let app = NSApp.delegate as? AppDelegate else { return .action(title, enabled: false) {} }
        let blocked = tab.archived ? "Unarchive the tab to move it." : tab.isMissing ? "Locate the repo first" : nil
        if let blocked { return .action(title, enabled: false, toolTip: blocked) {} }
        return .lazySubmenu(title) {
            let destinations = app.moveDestinations(for: model)
            if destinations.isEmpty { return [.action("No other window is open.", enabled: false) {}] }
            return destinations.map { destination in
                let refusal = app.moveRefusal(id, from: model, to: destination)
                return .action(windowTitle(destination), enabled: refusal == nil, toolTip: refusal) {
                    [weak model, weak destination] in
                    guard let model, let destination else { return }
                    TabDragOut.move(id, from: model, to: destination)
                }
            }
        }
    }

    /// A window as Move Tab to Window lists it: its selected tab's title, then its workspace's name or "Untitled".
    static func windowTitle(_ model: WindowModel) -> String {
        let tab = model.selectedIndex.map { model.tabs[$0].title } ?? "New Tab"
        return "\(tab) — \(model.workspace?.name ?? "Untitled")"
    }

    /// The Icon Color menu: Default (Settings › Appearance's default tab icon), then each lane color with its dot; the
    /// tab's own is checked.
    private static func iconColors(_ id: WindowModel.Tab.ID, _ tab: WindowModel.Tab, _ model: WindowModel)
        -> [MenuEntry]
    {
        let colors = ProfileColors.hexes.indices.map { index in
            MenuEntry.action(TabIcon.colorName(index), checked: tab.iconColor == index, image: ProfilePicker.dot(hex: ProfileColors.hexes[index])) {
                [weak model] in model?.setIconColor(index, for: id)
            }
        }
        return [.action("Default", checked: tab.iconColor == nil) { [weak model] in model?.setIconColor(nil, for: id) },
                .separator] + colors
    }

    /// The tab's profiles, as the toolbar chip lists them, so a tab switches without being selected first. Only for a
    /// repo tab whose folder is there.
    private static func profile(_ id: WindowModel.Tab.ID, _ tab: WindowModel.Tab, _ revealable: Bool,
                                _ model: WindowModel) -> [MenuEntry]
    {
        guard revealable else { return [] }
        let current = model.profile(of: tab)?.id
        return [.separator, .submenu("Profile", ProfilePicker.entries(tab: id, current: current, model: model))]
    }

    /// Closes a tab; closing the last tab closes the window, like ⌘W.
    static func close(_ id: WindowModel.Tab.ID, _ model: WindowModel) {
        if !model.closeTab(id: id) { model.closeWindow() }
    }

    /// A middle click on a tab closes it without selecting it, as Chrome's; not while a modal covers the window or
    /// the onboarding runs (its tour leaves `isShowingModal` false).
    static func middleClick(_ id: WindowModel.Tab.ID, _ model: WindowModel) {
        guard !(model.isShowingModal || model.isOnboarding) else { return }
        close(id, model)
    }
}

/// A manual group's chip before its first tab: a rounded rect in the group's color, a plain square without a name, else
/// wider with the name inside; the group's line under it and its tabs (`span` long), open at `opening` for
/// `openingWidth`: the selected tab, its flares included. `press` (the track's) tells a click from a drag: a click
/// collapses the group to the chip alone, with no line, and shows its tabs again, as Chrome's; a drag moves the whole
/// group. A right click or ⌃-click opens its popover (`TabGroupPopover`).
private struct TabGroupChip<Press: Gesture>: View {
    let model: WindowModel
    let group: TabGroup
    let collapsed: Bool
    let width: CGFloat
    let span: CGFloat
    let opening: CGFloat
    let openingWidth: CGFloat
    let press: Press
    /// The click's action, for accessibility (`press` runs it for a real click).
    let onToggle: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TabStripMetrics.groupChipRadius, style: .continuous)
        Text(group.name)
            .font(Font(TabStripMetrics.groupChipFont))
            .foregroundStyle(Color(nsColor: Palette.graphBadgeText))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, group.name.isEmpty ? 0 : TabStripMetrics.groupChipPadding)
            .frame(width: width, height: TabStripMetrics.groupChipHeight)
            .background(shape.fill(TabGroupColors.chip(group.group.colorIndex)))
            .contentShape(shape)
            .gesture(press)
            .tabGroupPopover(model: model, groupID: group.id, arrowEdge: .bottom)
        .frame(height: TabStripMetrics.tabHeight)
        .overlay(alignment: .bottomLeading) {
            if !collapsed {
                TabGroupLine(opening: opening, openingEnd: opening + openingWidth)
                    .fill(TabGroupColors.line(group.group.colorIndex))
                    .frame(width: span)
                    .allowsHitTesting(false)
            }
        }
        .help(group.help(collapsed: collapsed))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(group.accessibilityLabel)
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onToggle)
    }
}

/// A group's line along the strip's bottom, open from `opening` to `openingEnd` (its own x), where the selected tab's
/// outline takes over: its ends meet the outline's flares, with no spur. Animatable, so the opening slides with the
/// selected tab's shape when the selection changes. The archive's line (`ArchiveCluster`) is one too. It fills the
/// bottom `groupLine` of a tab-tall rect, not a rect that tall: SwiftUI rounds a view's frame to whole pixels, so a
/// 1.5 pt frame would stand up to half a pixel off the outline on a 1x screen.
struct TabGroupLine: Shape {
    var opening: CGFloat
    var openingEnd: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(opening, openingEnd) }
        set {
            opening = newValue.first
            openingEnd = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let start = min(max(opening, 0), rect.width)
        let end = min(max(openingEnd, start), rect.width)
        let line = TabStripMetrics.groupLine
        let top = rect.maxY - line
        var path = Path()
        if start > 0 { path.addRect(CGRect(x: 0, y: top, width: start, height: line)) }
        if end < rect.width { path.addRect(CGRect(x: end, y: top, width: rect.width - end, height: line)) }
        return path
    }
}

/// One tab: its icon (`TabIcon`: the emoji or uploaded image, else the book) in the slot before its name, with the
/// profile's color dot on the icon's corner; the name centered (the close button's slot balances the icon's) and cut
/// with "…", and a close button while hovered. A pinned tab shows only its icon, with no close button; its tooltip
/// carries the name.
struct TabItem: View {
    let title: String
    let help: String
    /// The tab's emoji (`WindowModel.Tab.emoji`); nil for none.
    let emoji: String?
    /// The symbol shown without an emoji (`TabIcon.symbol(of:)`).
    let symbol: String
    /// A pinned tab: its icon alone, no name and no close button.
    let pinned: Bool
    /// The book's own color (`TabIcon`); nil for the default tab icon.
    let iconColor: Int?
    /// The profile's `#RRGGBB`; nil without a profile (no dot).
    let profileColor: String?
    let profileName: String?
    /// The tab's manual group (`WindowModel.manualGroups`): its name and color (the selected tab's outline); nil
    /// outside a group. The popped-out archived tab has no name but the archive's color (`TabGroupColors.archiveLine`).
    let groupName: String?
    let groupColor: Color?
    let selected: Bool
    /// In the multi-selection (`WindowModel.multiSelection`) but not the shown tab: a dim capsule.
    let multiSelected: Bool
    let dragged: Bool
    let namespace: Namespace.ID
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovered = false

    var body: some View {
        label
            .padding(.horizontal, 6)
            .frame(maxHeight: .infinity)
            .background {
                if selected {
                    // The sheet's opaque fill, flares included (outside the tab's frame): the tab and the sheet read as
                    // one shape. No edge, which would draw a line where they meet.
                    TabSheetShape(radius: TabStripMetrics.tabRadius, flare: TabStripMetrics.flare)
                        .fill(Palette.sheet)
                        .overlay {
                            // A grouped tab's outline in the group's color, its flares meeting the group's line
                            // (`TabGroupLine`); the open shape insets half the line so the strip does not clip it.
                            if let groupColor {
                                TabSheetShape(radius: TabStripMetrics.tabRadius, flare: TabStripMetrics.flare,
                                              closed: false)
                                    .stroke(groupColor, lineWidth: TabStripMetrics.groupLine)
                            }
                        }
                        .background { SelectedTabShadow() }
                        .padding(.horizontal, -TabStripMetrics.flare)
                        .matchedGeometryEffect(id: "selectedTab", in: namespace)
                } else {
                    Capsule(style: .circular)
                        .fill(multiSelected ? Palette.multiSelectFill : hovered || dragged ? Palette.tabFill : .clear)
                        .padding(.bottom, TabStripMetrics.boxBottomInset)
                }
            }
            .contentShape(Capsule(style: .circular))
            .animation(Motion.hover, value: hovered)
            .onHover { hovered = $0 }
            // A pinned tab shows no name: its tooltip leads with it (an alias the path does not show).
            .help(pinned && help != title ? "\(title)\n\(help)" : help)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
            .accessibilityValue([pinned ? "Pinned" : nil, groupName.map { "Group \($0)" },
                                 profileName.map { "Profile \($0)" }]
                .compactMap(\.self).joined(separator: ", "))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, onSelect)
    }

    /// A pinned tab's icon alone, centered; else the name between the icon's slot and the close button's.
    @ViewBuilder private var label: some View {
        if pinned {
            icon.frame(maxWidth: .infinity)
        } else {
            titled
        }
    }

    private var icon: TabIcon {
        TabIcon(emoji: emoji, symbol: symbol, iconColor: iconColor, selected: selected,
                profileColor: profileColor, profileName: profileName)
    }

    /// The name, centered: the icon's slot balances the close button's.
    private var titled: some View {
        HStack(spacing: 4) {
            icon.frame(width: TabStripMetrics.slot, height: TabStripMetrics.slot)
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
            if hovered && !dragged {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: TabStripMetrics.slot, height: TabStripMetrics.slot)
                }
                .buttonStyle(CloseButtonStyle())
                .help("Close Tab")
                .accessibilityLabel("Close \(title)")
            } else {
                Color.clear.frame(width: TabStripMetrics.slot, height: TabStripMetrics.slot)
            }
        }
    }

    /// A small round highlight on hover, darker while pressed. The vertical tabs' rows use it too.
    struct CloseButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            Highlight(configuration: configuration)
        }

        private struct Highlight: View {
            let configuration: ButtonStyleConfiguration
            @State private var hovered = false

            var body: some View {
                configuration.label
                    .foregroundStyle(hovered ? Color.primary : Color.secondary)
                    .background(Circle().fill(configuration.isPressed ? Palette.pressedFill
                                              : hovered ? Palette.hoverFill : .clear))
                    .contentShape(Circle())
                    .animation(Motion.hover, value: hovered)
                    .onHover { hovered = $0 }
            }
        }
    }
}

/// A tab's icon in a `size` square: its emoji or uploaded image (Set Icon…; an image whose file is missing counts
/// as none), else its symbol (`symbol(of:)`, the book of a repo tab) in its icon color, with the profile's color dot
/// on its lower-right corner in a white ring. A book with neither its own icon nor its own color takes
/// Settings › Appearance's default tab icon: its emoji or image, else its color. The top tabs and the vertical tabs
/// share it.
struct TabIcon: View {
    /// The tab's own emoji or image reference (`WindowModel.Tab.emoji`); nil for none.
    let emoji: String?
    /// The SF Symbol drawn when there is no emoji or image.
    let symbol: String
    /// The tab's own book color (`WindowModel.Tab.iconColor`), an index into `Palette.graphLanes`; nil for none.
    let iconColor: Int?
    /// The tab is selected: a book without a color takes the selected text's color.
    let selected: Bool
    /// The profile's `#RRGGBB`; nil without a profile (no dot).
    let profileColor: String?
    let profileName: String?
    var size: CGFloat = TabStripMetrics.icon

    /// The emoji's font size as a share of `size`: an emoji glyph is drawn smaller than its point size, so this fills
    /// the square about as the symbol does. Tuned against a zoomed shot.
    static let emojiScale: CGFloat = 0.8
    /// Around the dot, to hover for the profile's name, not just the small dot.
    private static let dotHoverMargin: CGFloat = 3
    /// How far the dot's center sits inside the icon's corner.
    private static let dotInset: CGFloat = 2.5
    @AppStorage(PrefKey.defaultTabEmoji.rawValue, store: Preferences.defaults) private var defaultEmoji = ""
    @AppStorage(PrefKey.defaultTabIconColor.rawValue, store: Preferences.defaults) private var defaultColor = -1
    /// Bumped on `CustomIconImages.didChange`, so an image that loaded (or was found missing) redraws the icon.
    @State private var imagesVersion = 0

    /// The tab's own emoji or image reference; an image found missing counts as none.
    private var ownIcon: String? { Self.present(emoji) }
    /// The tab's own choice, else the default for a book that has none.
    private var usesDefault: Bool { ownIcon == nil && iconColor == nil && symbol == Self.book }

    var body: some View {
        let _ = imagesVersion
        let fallback = CustomIcon.isRef(defaultEmoji) ? Self.present(defaultEmoji) : TabEmoji.normalized(defaultEmoji)
        let emoji = ownIcon ?? (usesDefault ? fallback : nil)
        let ref = CustomIcon.isRef(emoji) ? emoji : nil
        ZStack {
            if let ref {
                // Fitted in the emoji's square, never cropped; empty until the image has loaded.
                Group {
                    if let image = CustomIconImages.shared.image(for: ref) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: size * Self.emojiScale, height: size * Self.emojiScale)
            } else if let emoji {
                Text(emoji)
                    .font(.system(size: size * Self.emojiScale))
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * Self.emojiScale))
                    .foregroundStyle(Self.tint(usesDefault && defaultColor >= 0 ? defaultColor : iconColor,
                                               selected: selected))
            }
        }
        .frame(width: size, height: size)
        // Keyed on the version too: an upload drops the cached image of its reference, which then loads again.
        .task(id: "\(ref ?? "")#\(imagesVersion)") {
            if let ref { await CustomIconImages.shared.load(ref) }
        }
        .onReceive(NotificationCenter.default.publisher(for: CustomIconImages.didChange)) { _ in imagesVersion &+= 1 }
        .overlay(alignment: .bottomTrailing) {
            if let profileColor {
                let ring = TabStripMetrics.iconDot / 2 + TabStripMetrics.iconDotRing
                // The aligned dot's center stands its radius and margin inside the corner; move it out to `dotInset`.
                let shift = ring + Self.dotHoverMargin - Self.dotInset
                Circle()
                    .fill(ProfileColors.color(profileColor))
                    .frame(width: TabStripMetrics.iconDot, height: TabStripMetrics.iconDot)
                    .padding(TabStripMetrics.iconDotRing)
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: TabStripMetrics.iconDotRing))
                    .padding(Self.dotHoverMargin)
                    .contentShape(Rectangle())
                    .help("Profile \(profileName ?? "")")
                    .offset(x: shift, y: shift)
                    .accessibilityHidden(true)
            }
        }
    }

    /// `value`, or nil when it is an image reference whose image was found missing.
    private static func present(_ value: String?) -> String? {
        guard let value, CustomIcon.isRef(value), CustomIconImages.shared.isMissing(value) else { return value }
        return nil
    }

    /// A tab's symbol: the book of a repo tab (as the toolbar's repo icon); a missing repo and a Welcome tab get their
    /// own.
    static func symbol(of tab: WindowModel.Tab) -> String {
        if tab.isMissing { return "questionmark.folder" }
        return tab.repoURL == nil ? "plus.square.dashed" : book
    }

    /// A repo tab's symbol, the one the default tab icon replaces.
    static let book = "book.closed"

    /// The names of `Palette.graphLanes`, in order, for the icon color menus.
    static let colorNames = ["Blue", "Orange", "Green", "Pink", "Cyan", "Yellow", "Purple", "Red"]

    /// The name of lane color `index` (`colorNames`).
    static func colorName(_ index: Int) -> String {
        colorNames.indices.contains(index) ? colorNames[index] : "Color \(index + 1)"
    }

    /// The symbol's color: `iconColor` in `Palette.graphLanes`, wrapped into range (a hand-edited `session.json` or
    /// preference may hold any number); without one, the tab's text color.
    private static func tint(_ iconColor: Int?, selected: Bool) -> Color {
        let lanes = Palette.graphLanes
        guard let iconColor, !lanes.isEmpty else { return selected ? .primary : .secondary }
        return Color(nsColor: lanes[(iconColor % lanes.count + lanes.count) % lanes.count])
    }
}

/// The selected tab joined to the page's sheet under it: rounded top corners, and at each bottom corner a concave
/// flare that runs out into the sheet's top edge. `rect` includes the flares, `flare` wide on each side.
struct TabSheetShape: Shape {
    let radius: CGFloat
    let flare: CGFloat
    /// False leaves out the bottom edge: the outline a grouped tab strokes, inset half a `groupLine` top and bottom
    /// inside the path (not by padding, whose frame SwiftUI rounds to whole pixels), so the stroke meets the group's
    /// line (`TabGroupLine`) exactly.
    var closed = true

    func path(in rect: CGRect) -> Path {
        let rect = closed ? rect : rect.insetBy(dx: 0, dy: TabStripMetrics.groupLine / 2)
        let left = rect.minX + flare
        let right = rect.maxX - flare
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: left, y: rect.maxY), tangent2End: CGPoint(x: left, y: rect.minY),
                    radius: flare)
        path.addArc(tangent1End: CGPoint(x: left, y: rect.minY), tangent2End: CGPoint(x: right, y: rect.minY),
                    radius: radius)
        path.addArc(tangent1End: CGPoint(x: right, y: rect.minY), tangent2End: CGPoint(x: right, y: rect.maxY),
                    radius: radius)
        path.addArc(tangent1End: CGPoint(x: right, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY),
                    radius: flare)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        if closed { path.closeSubpath() }
        return path
    }
}

/// The selected tab's depth, behind it: a soft shadow drawn outside the tab's shape only (the shape is clipped out, so
/// no edge and no darker core under the translucent fill), in a canvas wider and taller than the shadow reaches, so
/// nothing cuts it on a straight line. It fades out toward the tab's top, which the strip's scroll view clips 1 pt
/// above, and stops at the tab's bottom, where it joins the sheet. On a worktree box it darkens the box around the
/// hole cut for the tab.
private struct SelectedTabShadow: View {
    var body: some View {
        let radius = TabStripMetrics.selectedShadowRadius
        let reach = 3 * radius
        Canvas { context, size in
            let tab = CGRect(x: reach, y: reach, width: size.width - 2 * reach, height: size.height - reach)
            let shape = TabSheetShape(radius: TabStripMetrics.tabRadius, flare: TabStripMetrics.flare).path(in: tab)
            var outside = Path(CGRect(origin: .zero, size: size))
            outside.addPath(shape)
            context.clip(to: outside, style: FillStyle(eoFill: true))
            context.addFilter(.shadow(color: Palette.selectedTabShadow, radius: radius, options: .shadowOnly))
            context.fill(shape, with: .color(.black))
        }
        .padding(.horizontal, -reach)
        .padding(.top, -reach)
        .mask {
            GeometryReader { proxy in
                let top = reach / proxy.size.height
                LinearGradient(stops: [.init(color: .clear, location: top),
                                       .init(color: .black, location: min(top + 0.5 * (1 - top), 1))],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The chevron's popover: a search field and the tabs that match it: the window's tabs, then the tabs the strip no
/// longer shows, the stowed archived tabs (`WindowModel.archivedTabs`) and the closed groups' tabs
/// (`WindowModel.closedGroups`), each with its button's icon saying where it is (the popped-out archived tab has the
/// archive's too). A click selects the tab at once and closes the popover; an archived one pops out
/// (`WindowModel.openArchived(at:)`), a closed group's reopens its whole group with that tab selected
/// (`WindowModel.openClosedGroup(_:selecting:)`).
private struct TabListPopover: View {
    let model: WindowModel
    @Binding var isPresented: Bool
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    /// One row: a tab of the window, an archived tab by its index in `archivedTabs`, or a closed group's tab by its
    /// offset in the group.
    private enum Row: Identifiable {
        case open(WindowModel.Tab)
        case archived(index: Int, SavedTab)
        case closed(SavedClosedTabGroup, index: Int)

        var id: String {
            switch self {
            case .open(let tab): "open-\(tab.id)"
            case .archived(let index, _): "archived-\(index)"
            case .closed(let group, let index): "closed-\(group.id)-\(index)"
            }
        }

        var title: String {
            switch self {
            case .open(let tab): tab.title
            case .archived(_, let entry): entry.title
            case .closed(let group, let index): group.tabs[index].title
            }
        }

        var path: String? {
            switch self {
            case .open(let tab): tab.repoURL?.path
            case .archived(_, let entry): entry.path
            case .closed(let group, let index): group.tabs[index].path
            }
        }
    }

    var body: some View {
        let matches = matchingRows
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search", text: $query, prompt: Text("Search tabs"))
                .textFieldStyle(.settings)
                .labelsHidden()
                .focused($searchFocused)
                .padding(.horizontal, 10)
            if matches.isEmpty {
                Text("No matching tabs")
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .frame(minHeight: SidebarItemStyle.height)
            } else {
                ScrollView {
                    VStack(spacing: SidebarItemStyle.spacing) {
                        ForEach(matches) { row in
                            rowView(row)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .frame(height: min(320, CGFloat(matches.count) * (SidebarItemStyle.height + SidebarItemStyle.spacing)))
            }
        }
        // Vertical only: the rows' inset is inside the scroll view, so its scroller runs along the popover's edge.
        .padding(.vertical, 10)
        .frame(width: 280)
        // Next run-loop turn, once the popover's window exists.
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
    }

    /// A row's button: its icon and title, then its label (never truncated: the title gives way first).
    private func rowView(_ row: Row) -> some View {
        let selected = if case .open(let tab) = row { tab.id == model.selectedTabID } else { false }
        return Button {
            isPresented = false
            switch row {
            case .open(let tab): model.selectTab(id: tab.id)
            case .archived(let index, _): model.openArchived(at: index)
            case .closed(let group, let index): model.openClosedGroup(group.id, selecting: index)
            }
        } label: {
            Label {
                HStack(spacing: 6) {
                    Text(row.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    badge(row)
                }
            } icon: {
                Image(systemName: row.path == nil ? "house" : "folder")
            }
        }
        .buttonStyle(SidebarItemStyle(selected: selected))
        .help(help(row))
    }

    /// The archive button's capsule and icon, or the closed groups button's icon in the group's chip fill; none for a
    /// shown tab.
    @ViewBuilder
    private func badge(_ row: Row) -> some View {
        switch row {
        case .open(let tab) where tab.archived: chip("archivebox", "Archived", fill: TabGroupColors.archiveChip)
        case .open: EmptyView()
        case .archived: chip("archivebox", "Archived", fill: TabGroupColors.archiveChip)
        case .closed(let group, _):
            chip("app.grid.2x2", "In closed group", fill: TabGroupColors.chip(group.color))
        }
    }

    /// As the archive and closed groups buttons draw their rounded square, a group chip's height.
    private func chip(_ icon: String, _ label: String, fill: Color) -> some View {
        let height = TabStripMetrics.groupChipHeight
        return Image(systemName: icon)
            .font(.system(size: height * 0.55, weight: .semibold))
            .foregroundStyle(Color(nsColor: Palette.graphBadgeText))
            .frame(width: ArchiveButton.width(height: height), height: height)
            .background(ArchiveButton.shape(height: height).fill(fill))
            .accessibilityLabel(label)
    }

    /// The folder (or title), and where a hidden tab is.
    private func help(_ row: Row) -> String {
        let place = row.path ?? row.title
        switch row {
        case .open(let tab) where tab.archived: return "\(place)\nArchived"
        case .open: return place
        case .archived: return "\(place)\nArchived: opens beside the archive button"
        case .closed(let group, _):
            let name = group.name.map { " \"\($0)\"" } ?? ""
            return "\(place)\nIn closed group\(name): opens the whole group"
        }
    }

    /// The window's tabs, then the stowed archived tabs, then the closed groups' tabs, whose name or folder contains
    /// the query (case- and diacritic-insensitive); all of them for an empty query.
    private var matchingRows: [Row] {
        let rows = model.tabs.map(Row.open)
            + model.archivedTabs.enumerated().map { Row.archived(index: $0.offset, $0.element) }
            + model.closedGroups.flatMap { group in group.tabs.indices.map { Row.closed(group, index: $0) } }
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return rows }
        return rows.filter {
            $0.title.localizedStandardContains(text) || ($0.path?.localizedStandardContains(text) ?? false)
        }
    }
}

/// The archive button: a rounded square in the archive's color with its `archivebox` icon, shown once the window has an
/// archive (`WindowModel.archivedTabs`, or a tab popped out). A click opens the archived tabs' list
/// (`ArchiveListPopover`). The tab strip shows it at its far left (after the closed groups button, when shown), the
/// vertical tabs in their bottom row.
struct ArchiveButton: View {
    let model: WindowModel
    /// Where the list's popover opens from the button.
    let popoverEdge: Edge
    /// The square's side: `stowButtonSize` in the tab strip, a row's height in the vertical tabs' bottom row.
    let height: CGFloat
    @State private var showingList = false
    @State private var hovered = false

    /// The button's width for its `height`: a square.
    static func width(height: CGFloat) -> CGFloat {
        height
    }

    /// The square's corners, as a group chip rounds its own (`groupChipRadius` at its height).
    static func radius(height: CGFloat) -> CGFloat {
        (height * TabStripMetrics.groupChipRadius / TabStripMetrics.groupChipHeight).rounded()
    }

    /// The button's rounded square for its `height`, shared with the closed groups button.
    static func shape(height: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius(height: height), style: .continuous)
    }

    var body: some View {
        Button { showingList.toggle() } label: {
            Image(systemName: "archivebox")
                .font(.system(size: height * 0.55, weight: .semibold))
                .foregroundStyle(Color(nsColor: Palette.graphBadgeText))
                .frame(width: Self.width(height: height), height: height)
                .background(Self.shape(height: height).fill(TabGroupColors.archiveChip))
                .overlay(Self.shape(height: height).fill(hovered ? Palette.hoverFill : .clear))
                .contentShape(Self.shape(height: height))
        }
        .buttonStyle(.plain)
        .animation(Motion.hover, value: hovered)
        .onHover { hovered = $0 }
        .help("Archived tabs (\(model.archivedTabs.count + (model.archivedOut == nil ? 0 : 1)))")
        .accessibilityLabel("Archived Tabs")
        .popover(isPresented: $showingList, arrowEdge: popoverEdge) {
            ArchiveListPopover(model: model, isPresented: $showingList)
        }
        .background(WindowDragBlocker())
        // DEBUG `-HistqOpenPopover archive` (website and QA shots): the list opens once the window has settled.
        .task {
            guard AppState.launchFlag("-HistqOpenPopover") == "archive" else { return }
            try? await Task.sleep(for: .seconds(2))
            showingList = true
        }
    }
}

/// The archive button's popover: a search field and the stowed archived tabs that match it, most recently archived
/// first. A click pops the tab out at once (`WindowModel.openArchived(at:)`) and closes the popover; a row's × (on
/// hover) removes it from the archive.
private struct ArchiveListPopover: View {
    let model: WindowModel
    @Binding var isPresented: Bool
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let matches = matchingEntries
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search", text: $query, prompt: Text("Search archived tabs"))
                .textFieldStyle(.settings)
                .labelsHidden()
                .focused($searchFocused)
                .padding(.horizontal, 10)
            if matches.isEmpty {
                // Only the popped-out tab is archived: the list has no other.
                Text(model.archivedTabs.isEmpty ? "No other archived tabs" : "No matching archived tabs")
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .frame(minHeight: SidebarItemStyle.height)
            } else {
                ScrollView {
                    VStack(spacing: SidebarItemStyle.spacing) {
                        ForEach(matches, id: \.offset) { match in
                            ArchiveRow(entry: match.element,
                                       onOpen: {
                                           model.openArchived(at: match.offset)
                                           isPresented = false
                                       },
                                       onRemove: { model.removeArchived(at: match.offset) })
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .frame(height: min(320, CGFloat(matches.count) * SidebarItemStyle.height
                    + CGFloat(max(matches.count - 1, 0)) * SidebarItemStyle.spacing))
            }
        }
        // Vertical only: the rows' inset is inside the scroll view, so its scroller runs along the popover's edge.
        .padding(.vertical, 10)
        .frame(width: 280)
        // Next run-loop turn, once the popover's window exists.
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
    }

    /// The archived entries whose name or folder contains the query (case- and diacritic-insensitive), each with its
    /// index in `WindowModel.archivedTabs`; all of them for an empty query.
    private var matchingEntries: [EnumeratedSequence<[SavedTab]>.Element] {
        let entries = Array(model.archivedTabs.enumerated())
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return entries }
        return entries.filter {
            $0.element.title.localizedStandardContains(text)
                || ($0.element.path?.localizedStandardContains(text) ?? false)
        }
    }

    /// One archived tab: a click opens it; its × on hover removes it from the archive.
    private struct ArchiveRow: View {
        let entry: SavedTab
        let onOpen: () -> Void
        let onRemove: () -> Void
        @State private var hovered = false

        var body: some View {
            Button(action: onOpen) {
                Label(entry.title, systemImage: "archivebox")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // The × stands over the row's end.
                    .padding(.trailing, TabStripMetrics.slot)
            }
            .buttonStyle(SidebarItemStyle(selected: false))
            .help(entry.path ?? entry.title)
            .overlay(alignment: .trailing) {
                if hovered {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: TabStripMetrics.slot, height: TabStripMetrics.slot)
                    }
                    .buttonStyle(TabItem.CloseButtonStyle())
                    .help("Remove from Archive")
                    .accessibilityLabel("Remove \(entry.title) from Archive")
                    .padding(.trailing, 6)
                }
            }
            .onHover { hovered = $0 }
        }
    }
}
