// The tab strip under the toolbar: the window's tabs, then New tab and the tab list (the command palette is the
// toolbar's Search), on the window glass. The selected tab is a tab of the page's sheet under it (`TabSheetShape`).
import AppKit
import SwiftUI

/// Sizes of the tab strip. The tabs share one width, between `minTabWidth` and `maxTabWidth`; past that the row
/// scrolls. The vertical tabs (`VerticalTabsPanel`) use the same drag threshold, slot and dot.
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
    /// The close button's square, and the matching slot before the title (the profile color dot).
    static let slot: CGFloat = 16
    /// The profile color dot in that slot.
    static let dot: CGFloat = 8
    /// How far a press moves before it reorders the tab.
    static let dragThreshold: CGFloat = 5
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

/// The tabs with a small gap: equal widths, no fill (a subtle one on hover), and the selected tab's sheet-colored
/// shape that slides to the next selection.
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
            let count = model.tabs.count
            let gaps = TabStripMetrics.gap * CGFloat(max(count - 1, 0)) + 2 * TabStripMetrics.flare
            let tabWidth = min(TabStripMetrics.maxTabWidth,
                               max(TabStripMetrics.minTabWidth, (proxy.size.width - gaps) / CGFloat(max(count, 1))))
            let rowWidth = tabWidth * CGFloat(count) + gaps
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    row(tabWidth: tabWidth)
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

    private func row(tabWidth: CGFloat) -> some View {
        // Each tab carries its flares' room on both sides (overlapping its neighbors' by the negative spacing), so
        // scrolling to a tab at an edge keeps its flares in view; the tabs still sit `gap` apart.
        HStack(spacing: TabStripMetrics.gap - 2 * TabStripMetrics.flare) {
            ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                let selected = tab.id == model.selectedTabID
                let dragged = tab.id == draggedID
                // A repo tab's profile; a tab not opened yet (filled in the background) has no session, so no dot.
                let profile = model.sessions[tab.id]?.profile
                TabItem(title: tab.title, help: tab.repoURL?.path ?? tab.title, profileColor: profile?.color,
                        profileName: profile?.name, selected: selected, dragged: dragged, namespace: namespace,
                        onSelect: { model.selectTab(id: tab.id) },
                        onClose: { close(tab.id) })
                    .frame(width: tabWidth, height: TabStripMetrics.tabHeight)
                    .padding(.horizontal, TabStripMetrics.flare)
                    .offset(x: offset(of: index, id: tab.id, step: tabWidth + TabStripMetrics.gap))
                    // Neighbors slide aside; the dragged tab tracks the pointer without lag.
                    .animation(draggedID != nil && !dragged ? animation : nil, value: dragTarget)
                    // The selected tab's flares lie over its neighbors' edges.
                    .zIndex(dragged ? 2 : selected ? 1 : 0)
                    .gesture(press(tab.id, index: index, step: tabWidth + TabStripMetrics.gap))
                    .id(tab.id)
            }
        }
        .padding(.top, TabStripMetrics.rowInset)
        // The selected tab's shape slides, also for a selection made elsewhere (a menu, the tab list).
        .animation(animation, value: model.selectedTabID)
    }

    /// The dragged tab follows the pointer; the tabs between its old and new place shift by one tab.
    private func offset(of index: Int, id: WindowModel.Tab.ID, step: CGFloat) -> CGFloat {
        guard let draggedID else { return 0 }
        if id == draggedID { return dragOffset }
        if dragFrom < dragTarget, index > dragFrom, index <= dragTarget { return -step }
        if dragTarget < dragFrom, index >= dragTarget, index < dragFrom { return step }
        return 0
    }

    /// Zero distance, so the tab is selected on mouse-down (a tap would wait for mouse-up); past `dragThreshold` it
    /// reorders.
    private func press(_ id: WindowModel.Tab.ID, index: Int, step: CGFloat) -> some Gesture {
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
                let target = min(max(dragFrom + Int((translation / step).rounded()), 0), model.tabs.count - 1)
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
        if !model.closeTab(id: id) { model.closeWindow() }
    }
}

/// One tab: its profile's color dot, its name, centered (leading in the vertical tabs) and cut with
/// "…", and a close button while hovered.
struct TabItem: View {
    let title: String
    let help: String
    /// The profile's `#RRGGBB`; nil without a profile (no dot).
    let profileColor: String?
    let profileName: String?
    let selected: Bool
    let dragged: Bool
    let namespace: Namespace.ID
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if let profileColor {
                    Circle()
                        .fill(ProfileColors.color(profileColor))
                        .frame(width: TabStripMetrics.dot, height: TabStripMetrics.dot)
                } else {
                    Color.clear
                }
            }
            .frame(width: TabStripMetrics.slot, height: TabStripMetrics.slot)
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
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
        .background {
            if selected {
                // The sheet's opaque fill, flares included (outside the tab's frame): the tab and the sheet read as
                // one shape. No edge, which would draw a line where they meet.
                TabSheetShape(radius: TabStripMetrics.tabRadius, flare: TabStripMetrics.flare)
                    .fill(Palette.sheet)
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
        .help(help)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(profileName.map { "Profile \($0)" } ?? "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onSelect)
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

/// The selected tab joined to the page's sheet under it: rounded top corners, and at each bottom corner a concave
/// flare that runs out into the sheet's top edge. `rect` includes the flares, `flare` wide on each side.
struct TabSheetShape: Shape {
    let radius: CGFloat
    let flare: CGFloat

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
        path.closeSubpath()
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
