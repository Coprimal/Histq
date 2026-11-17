// The tab strip under the toolbar: the window's tabs, then New tab and the tab list (the command palette is the
// toolbar's Search), on the window glass. The selected tab is a tab of the page's sheet under it (`TabSheetShape`).
import AppKit
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
    /// A tab group's name chip, before its first tab: as tall as New Tab, at most `groupChipMaxWidth` wide.
    static let groupChipHeight: CGFloat = 20
    static let groupChipMaxWidth: CGFloat = 120
    static let groupChipPadding: CGFloat = 8
    static var groupChipFont: NSFont { .systemFont(ofSize: 11, weight: .semibold) }

    /// A group's chip width for its name.
    static func groupChipWidth(_ name: String) -> CGFloat {
        let text = (name as NSString).size(withAttributes: [.font: groupChipFont]).width
        return min(groupChipMaxWidth, ceil(text) + 2 * groupChipPadding)
    }
}

/// A tab group's color (`Palette.graphLanes`, by its repo) and its chip's fill (the graph badges' fill).
enum TabGroupColors {
    static func line(_ key: String) -> Color {
        Color(nsColor: Palette.graphLanes[RepoGroupKey.colorIndex(of: key, count: Palette.graphLanes.count)])
    }

    static func chip(_ key: String) -> Color {
        Color(nsColor: Palette.graphBadgeFills[RepoGroupKey.colorIndex(of: key, count: Palette.graphLanes.count)])
    }
}

/// The window's tabs, then New Tab and the tab list. A press on a tab selects it at once (on mouse-down); a drag past a
/// few points reorders it.
struct TabStrip: View {
    @Environment(WindowModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            TabTrack(model: model)
            TabStripButtons(model: model, popoverEdge: .bottom, buttonHeight: TabStripMetrics.buttonHeight)
        }
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
/// selection. A tab group (a repo's worktrees, `WindowModel.tabGroups`) has its name chip
/// before its first tab, its color as one line under the chip and its tabs (`TabGroupLine`, open where the selected
/// tab stands, live during a drag), and as the selected tab's outline.
private struct TabTrack: View {
    let model: WindowModel
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The tab under the current mouse press, so a press selects once.
    @State private var pressedID: WindowModel.Tab.ID?
    /// The dragged tab, its offset, and the index it came from and would land at. `dragFrom`/`dragTarget` stay stale
    /// after a cancelled drag on purpose: clearing them would change the neighbors' animation value and cancel the
    /// slide back.
    @State private var draggedID: WindowModel.Tab.ID?
    @State private var dragOffset: CGFloat = 0
    @State private var dragFrom = 0
    @State private var dragTarget = 0

    var body: some View {
        GeometryReader { proxy in
            let groups = model.tabGroups
            // A collapsed group's tabs take no room.
            let hidden = Set(groups.filter { model.collapsedGroups.contains($0.key) }.flatMap(\.range))
            let shown = model.tabs.indices.filter { !hidden.contains($0) }
            let pinned = CGFloat(shown.filter { model.tabs[$0].pinned }.count)
            let count = shown.count
            let unpinned = CGFloat(count) - pinned
            let chips = groups.reduce(0) { $0 + TabStripMetrics.groupChipWidth($1.name) }
            let items = count + groups.count
            let gaps = TabStripMetrics.gap * CGFloat(max(items - 1, 0)) + 2 * TabStripMetrics.flare
            let pinnedWidth = pinned * TabStripMetrics.pinnedTabWidth
            // The unpinned tabs share what the pinned ones, the chips and the gaps leave.
            let tabWidth = min(TabStripMetrics.maxTabWidth,
                               max(TabStripMetrics.minTabWidth,
                                   (proxy.size.width - gaps - chips - pinnedWidth) / max(unpinned, 1)))
            let rowWidth = tabWidth * unpinned + pinnedWidth + chips + gaps
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    row(layout: TabGroupLayout(tabs: model.tabs, groups: groups,
                                               collapsed: model.collapsedGroups, tabExtent: tabWidth,
                                               gap: TabStripMetrics.gap,
                                               extent: { model.tabs[$0].pinned ? TabStripMetrics.pinnedTabWidth
                                                   : tabWidth },
                                               headerExtent: { TabStripMetrics.groupChipWidth($0.name) }))
                }
                .scrollDisabled(rowWidth <= proxy.size.width)
                .frame(width: min(rowWidth, proxy.size.width))
                .background(WindowDragBlocker())
                .onChange(of: model.selectedTabID) { _, id in
                    guard let id else { return }
                    withAnimation(animation) { scroller.scrollTo(id) }
                }
            }
            // Only the tabs take clicks: the empty space after them drags the window.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: TabStripMetrics.tabHeight + TabStripMetrics.rowInset)
    }

    private var animation: Animation? { reduceMotion ? nil : Motion.standard }

    private func row(layout: TabGroupLayout) -> some View {
        let current = layout.positions(order: Array(model.tabs.indices))
        // While a tab is dragged, the others (and the chips) stand where they would with the tab dropped at its target.
        let order = draggedID == nil ? Array(model.tabs.indices)
            : TabGroupLayout.moved(model.tabs.count, dragFrom, dragTarget)
        let target = draggedID == nil ? current : layout.positions(order: order)
        // The selected tab's start as drawn: it follows the pointer while dragged (the dragged tab is the selected one,
        // a press selects it), so each group's line opens right under it.
        let selected = model.selectedIndex
        let selectedX = selected.map { index in
            (current.tabs[index] ?? 0) + (model.tabs[index].id == draggedID ? dragOffset : 0)
        }
        // Each item carries its flares' room on both sides (overlapping its neighbors' by the negative spacing), so
        // scrolling to a tab at an edge keeps its flares in view; the items still sit `gap` apart.
        return HStack(spacing: TabStripMetrics.gap - 2 * TabStripMetrics.flare) {
            ForEach(layout.items) { item in
                switch item {
                case .header(let group):
                    let chipX = target.headers[group.key] ?? 0
                    // The selected tab, flares included, along the line (outside it when no tab of the group is).
                    let opening = selectedX.map { $0 - chipX - TabStripMetrics.flare } ?? -.greatestFiniteMagnitude
                    TabGroupChip(group: group, collapsed: layout.collapsed.contains(group.key),
                                 width: layout.headerExtents[group.key] ?? 0,
                                 span: layout.span(of: group.key), opening: opening,
                                 openingWidth: (selected.map(layout.extent(of:)) ?? layout.tabExtent)
                                     + 2 * TabStripMetrics.flare,
                                 onToggle: { withAnimation(animation) { model.toggleGroup(group.key) } })
                        .contextMenu { MenuEntriesView(entries: TabMenu.groupEntries(for: group.key, model: model)) }
                        .padding(.horizontal, TabStripMetrics.flare)
                        .offset(x: chipX - (current.headers[group.key] ?? 0))
                        .animation(draggedID != nil ? animation : nil, value: dragTarget)
                case .tab(let index, let tab):
                    tabView(index: index, tab: tab, layout: layout, current: current, target: target)
                }
            }
        }
        .padding(.top, TabStripMetrics.rowInset)
        // The selected tab's shape slides, also for a selection made elsewhere (a menu, the tab list).
        .animation(animation, value: model.selectedTabID)
    }

    private func tabView(index: Int, tab: WindowModel.Tab, layout: TabGroupLayout, current: TabGroupLayout.Positions,
                         target: TabGroupLayout.Positions) -> some View {
        let selected = tab.id == model.selectedTabID
        let dragged = tab.id == draggedID
        let profile = model.profile(of: tab)
        let group = layout.groupKey[index]
        let offset = dragged ? dragOffset : (target.tabs[index] ?? 0) - (current.tabs[index] ?? 0)
        return TabItem(title: tab.title, help: tab.repoURL?.path ?? tab.title, emoji: tab.emoji,
                       symbol: TabIcon.symbol(of: tab), pinned: tab.pinned, iconColor: tab.iconColor,
                       profileColor: profile?.color,
                       profileName: profile?.name, groupName: group.map(TabGroupNames.shared.name(of:)),
                       groupColor: group.map(TabGroupColors.line),
                       selected: selected, dragged: dragged, namespace: namespace,
                       onSelect: { model.selectTab(id: tab.id) },
                       onClose: { close(tab.id) })
            .frame(width: layout.extent(of: index), height: TabStripMetrics.tabHeight)
            // The tab itself, not its flares' room, which overlaps its neighbors'.
            .background(MiddleClickCatcher { TabMenu.middleClick(tab.id, model) })
            .padding(.horizontal, TabStripMetrics.flare)
            .offset(x: offset)
            // Neighbors slide aside; the dragged tab tracks the pointer without lag.
            .animation(draggedID != nil && !dragged ? animation : nil, value: dragTarget)
            // The selected tab's flares lie over its neighbors' edges.
            .zIndex(dragged ? 2 : selected ? 1 : 0)
            .gesture(press(tab.id, index: index, layout: layout))
            .contextMenu { MenuEntriesView(entries: TabMenu.entries(for: tab.id, model: model, vertical: false)) }
            .id(tab.id)
    }

    /// Zero distance, so the tab is selected on mouse-down (a tap would wait for mouse-up); past `dragThreshold` it
    /// reorders, to the allowed place (`WindowModel.moveDestinations`) nearest the pointer.
    private func press(_ id: WindowModel.Tab.ID, index: Int, layout: TabGroupLayout) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                // `!= id` rather than `== nil`: a press that never ends (`onEnded` skipped) blocks only this tab.
                if pressedID != id {
                    pressedID = id
                    model.selectTab(id: id)
                }
                let translation = value.translation.width
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
                    // Back into its slot with the lifted look.
                    withAnimation(animation) {
                        dragOffset = 0
                        draggedID = nil
                    }
                } else {
                    // Reset without animation before the move, so the tabs render at their new places directly.
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

/// A tab's right-click menu, in the tab strip and the vertical tabs (as Chrome's): Close Tab, Close Other Tabs, Close
/// Tabs to the Right (Below), each off when it has no tab to close, then Reveal in Finder (the tab's repo or worktree
/// folder; off for a Welcome tab or a missing folder), Set Alias…, Set Emoji…, Icon Color (the book's) and Pin Tab /
/// Unpin Tab (Pin Group / Unpin Group for a tab of a worktree group, which pins with it), these four off for a Welcome
/// tab.
@MainActor
enum TabMenu {
    static func entries(for id: WindowModel.Tab.ID, model: WindowModel, vertical: Bool) -> [MenuEntry] {
        guard let index = model.tabs.firstIndex(where: { $0.id == id }) else { return [] }
        let tab = model.tabs[index]
        let isRepo = tab.repoURL != nil
        let revealable = isRepo && !tab.isMissing
        let grouped = model.tabGroups.contains { $0.range.contains(index) }
        let pinTitle = (tab.pinned ? "Unpin " : "Pin ") + (grouped ? "Group" : "Tab")
        return [
            .action("Close Tab") { close(id, model) },
            .action("Close Other Tabs", enabled: model.tabs.count > 1) { model.closeOtherTabs(id) },
            .action(vertical ? "Close Tabs Below" : "Close Tabs to the Right",
                    enabled: index < model.tabs.count - 1) { model.closeTabs(after: id) },
            .separator,
            .action("Reveal in Finder", enabled: revealable,
                    toolTip: revealable ? nil
                        : isRepo ? "The repository's folder is gone." : "A new tab has no repository.") {
                if let url = tab.repoURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            },
            .action("Set Alias…", enabled: isRepo, toolTip: isRepo ? nil : "A new tab has no repository to name.") {
                model.presentModal(.tabAlias(tabID: id))
            },
            .action("Set Emoji…", enabled: isRepo, toolTip: isRepo ? nil : "A new tab has no repository to mark.") {
                model.presentModal(.tabEmoji(tabID: id))
            },
            isRepo ? .submenu("Icon Color", iconColors(id, tab, model))
                : .action("Icon Color", enabled: false, toolTip: "A new tab has no repository to mark.") {},
            .action(pinTitle, enabled: isRepo, toolTip: isRepo ? nil : "A new tab has no repository to pin.") {
                model.setPinned(!tab.pinned, for: id)
            },
        ] + profile(id, tab, revealable, model)
    }

    /// A tab group's name's right-click menu (the top tabs' chip, the vertical tabs' header): Rename Group….
    static func groupEntries(for key: String, model: WindowModel) -> [MenuEntry] {
        [.action("Rename Group…") { [weak model] in model?.presentModal(.groupName(key: key)) }]
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

    /// A middle click on a tab closes it without selecting it, as Chrome's; not while a modal covers the window.
    static func middleClick(_ id: WindowModel.Tab.ID, _ model: WindowModel) {
        guard !model.isShowingModal else { return }
        close(id, model)
    }
}

/// A tab group's name before its first tab, in the group's color, with the group's line under it and its tabs
/// (`span` long) open at `opening` for `openingWidth`: the selected tab, its flares included. A click collapses the
/// group to the chip alone, with no line, and shows its tabs again, as Chrome's.
private struct TabGroupChip: View {
    let group: TabGroup
    let collapsed: Bool
    let width: CGFloat
    let span: CGFloat
    let opening: CGFloat
    let openingWidth: CGFloat
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Text(group.name)
                .font(Font(TabStripMetrics.groupChipFont))
                .foregroundStyle(Color(nsColor: Palette.graphBadgeText))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, TabStripMetrics.groupChipPadding)
                .frame(width: width, height: TabStripMetrics.groupChipHeight)
                .background(Capsule().fill(TabGroupColors.chip(group.key)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(height: TabStripMetrics.tabHeight)
        .overlay(alignment: .bottomLeading) {
            if !collapsed {
                TabGroupLine(opening: opening, openingEnd: opening + openingWidth)
                    .fill(TabGroupColors.line(group.key))
                    .frame(width: span, height: TabStripMetrics.groupLine)
                    .allowsHitTesting(false)
            }
        }
        .help(help)
        .accessibilityLabel("Group \(group.name), \(group.range.count) tabs")
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
    }

    private var help: String {
        "\(group.name): \(group.range.count) tabs of this repository. Click to \(collapsed ? "show" : "hide") them."
    }
}

/// A group's line along the strip's bottom, open from `opening` to `openingEnd` (its own x), where the selected tab's
/// outline takes over: its ends meet the outline's flares, with no spur. Animatable, so the opening slides with the
/// selected tab's shape when the selection changes.
private struct TabGroupLine: Shape {
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
        var path = Path()
        if start > 0 { path.addRect(CGRect(x: 0, y: rect.minY, width: start, height: rect.height)) }
        if end < rect.width { path.addRect(CGRect(x: end, y: rect.minY, width: rect.width - end, height: rect.height)) }
        return path
    }
}

/// One tab: its icon (`TabIcon`: the emoji, else the book) in the slot before its name, with the profile's color dot on
/// the icon's corner; the name centered (the close button's slot balances the icon's) and cut with "…", and a close
/// button while hovered. A pinned tab shows only its icon, with no close button; its tooltip carries the name.
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
    /// The tab's group (`WindowModel.tabGroups`): its name and color (the selected tab's outline); nil outside a
    /// group.
    let groupName: String?
    let groupColor: Color?
    let selected: Bool
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
                            // (`TabGroupLine`); inset half the line so the strip does not clip it.
                            if let groupColor {
                                TabSheetShape(radius: TabStripMetrics.tabRadius, flare: TabStripMetrics.flare,
                                              closed: false)
                                    .stroke(groupColor, lineWidth: TabStripMetrics.groupLine)
                                    .padding(.vertical, TabStripMetrics.groupLine / 2)
                            }
                        }
                        .padding(.horizontal, -TabStripMetrics.flare)
                        .matchedGeometryEffect(id: "selectedTab", in: namespace)
                } else {
                    Capsule(style: .circular)
                        .fill(hovered || dragged ? Palette.tabFill : .clear)
                        .padding(.bottom, 3)
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

/// A tab's icon in a `size` square: its emoji, else its symbol (`symbol(of:)`, the book of a repo tab) in its icon
/// color, with the profile's color dot on its lower-right corner in a white ring. A book with neither its own emoji nor
/// its own color takes Settings › Appearance's default tab icon: its emoji, else its color. The top tabs and the
/// vertical tabs share it.
struct TabIcon: View {
    /// The tab's own emoji (`WindowModel.Tab.emoji`); nil for none.
    let emoji: String?
    /// The SF Symbol drawn when there is no emoji.
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

    /// The tab's own choice, else the default for a book that has none.
    private var usesDefault: Bool { emoji == nil && iconColor == nil && symbol == Self.book }

    var body: some View {
        let emoji = emoji ?? (usesDefault ? TabEmoji.normalized(defaultEmoji) : nil)
        ZStack {
            if let emoji {
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
    /// False leaves out the bottom edge: the outline a grouped tab strokes.
    var closed = true

    func path(in rect: CGRect) -> Path {
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

/// The chevron's popover: a search field and the tabs that match it. A click selects the tab at once and closes the
/// popover.
private struct TabListPopover: View {
    let model: WindowModel
    @Binding var isPresented: Bool
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let matches = matchingTabs
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search", text: $query, prompt: Text("Search tabs"))
                .textFieldStyle(.settings)
                .labelsHidden()
                .focused($searchFocused)
            if matches.isEmpty {
                Text("No matching tabs")
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(minHeight: SidebarItemStyle.height)
            } else {
                ScrollView {
                    VStack(spacing: SidebarItemStyle.spacing) {
                        ForEach(matches) { tab in
                            Button {
                                model.selectTab(id: tab.id)
                                isPresented = false
                            } label: {
                                Label(tab.title, systemImage: tab.repoURL == nil ? "house" : "folder")
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .buttonStyle(SidebarItemStyle(selected: tab.id == model.selectedTabID))
                            .help(tab.repoURL?.path ?? tab.title)
                        }
                    }
                }
                .frame(height: min(320, CGFloat(matches.count) * (SidebarItemStyle.height + SidebarItemStyle.spacing)))
            }
        }
        .padding(10)
        .frame(width: 280)
        // Next run-loop turn, once the popover's window exists.
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
    }

    /// Tabs whose name or folder contains the query (case- and diacritic-insensitive); all tabs for an empty query.
    private var matchingTabs: [WindowModel.Tab] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return model.tabs }
        return model.tabs.filter {
            $0.title.localizedStandardContains(text) || ($0.repoURL?.path.localizedStandardContains(text) ?? false)
        }
    }
}
