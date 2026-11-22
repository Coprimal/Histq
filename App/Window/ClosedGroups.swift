// The closed groups button and its popover: the manual tab groups stowed by Close Group (`WindowModel.closedGroups`).
import SwiftUI

/// The closed groups button: a grey capsule with the `app.grid.2x2` icon, shown while the window has closed groups
/// (`WindowModel.closedGroups`). A click opens their list (`ClosedGroupsPopover`). The tab strip shows it at its far
/// left, before the archive button; the vertical tabs first in their bottom row.
struct ClosedGroupsButton: View {
    let model: WindowModel
    /// Where the list's popover opens from the button.
    let popoverEdge: Edge
    /// The capsule's height: a group chip's in the tab strip, a row's in the vertical tabs' bottom row.
    let height: CGFloat
    @State private var showingList = false
    @State private var hovered = false

    /// The button's width for its `height`: as wide as the archive button.
    static func width(height: CGFloat) -> CGFloat {
        ArchiveButton.width(height: height)
    }

    var body: some View {
        Button { showingList.toggle() } label: {
            Image(systemName: "app.grid.2x2")
                .font(.system(size: height * 0.55, weight: .semibold))
                .foregroundStyle(Color(nsColor: Palette.graphBadgeText))
                .frame(width: Self.width(height: height), height: height)
                .background(Capsule().fill(Color(nsColor: Palette.groupGreyFill)))
                .overlay(Capsule().fill(hovered ? Palette.hoverFill : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(Motion.hover, value: hovered)
        .onHover { hovered = $0 }
        .help("Closed groups (\(model.closedGroups.count))")
        .accessibilityLabel("Closed Groups")
        .popover(isPresented: $showingList, arrowEdge: popoverEdge) {
            ClosedGroupsPopover(model: model, isPresented: $showingList)
        }
        .background(WindowDragBlocker())
    }
}

/// The closed groups button's popover: one row per closed group, most recently closed first. A click closes the
/// popover and opens the group (`WindowModel.openClosedGroup`); a row's menu opens it here or in a new window, deletes
/// it, or opens it with one of its tabs selected.
private struct ClosedGroupsPopover: View {
    let model: WindowModel
    @Binding var isPresented: Bool

    var body: some View {
        let groups = model.closedGroups
        ScrollView {
            VStack(spacing: SidebarItemStyle.spacing) {
                ForEach(groups, id: \.id) { group in
                    row(group)
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: min(320, CGFloat(groups.count) * (SidebarItemStyle.height + SidebarItemStyle.spacing)))
        // Vertical only: the rows' inset is inside the scroll view, so its scroller runs along the popover's edge.
        .padding(.vertical, 10)
        .frame(width: 280)
    }

    /// One closed group: its color square, its name in that color (when it has one), then its tab count.
    private func row(_ group: SavedClosedTabGroup) -> some View {
        let color = TabGroupColors.line(group.color)
        let name = group.name ?? ""
        let count = group.tabs.count == 1 ? "1 tab" : "\(group.tabs.count) tabs"
        return Button { act { model.openClosedGroup(group.id) } } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: 10, height: 10)
                if !name.isEmpty {
                    Text(name)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                // Never truncated: a long name gives way first.
                Text(count)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .buttonStyle(SidebarItemStyle(selected: false))
        .help(group.tabs.map(\.title).joined(separator: ", "))
        .accessibilityLabel(name.isEmpty ? "Group, \(count)" : "Group \(name), \(count)")
        .contextMenu { menu(group) }
    }

    /// A row's right-click menu: Open Group, Open Group in New Window (off with no way to open a window), Delete
    /// Group, then the group's tabs under a "Tabs in Group" header, each opening the group with that tab selected.
    @ViewBuilder
    private func menu(_ group: SavedClosedTabGroup) -> some View {
        Button("Open Group") { act { model.openClosedGroup(group.id) } }
        Button("Open Group in New Window") { act { model.openClosedGroupInNewWindow(group.id) } }
            .disabled(model.openWindow == nil)
        Button("Delete Group") { act { model.deleteClosedGroup(group.id) } }
        Divider()
        Button("Tabs in Group") {}
            .disabled(true)
        ForEach(Array(group.tabs.enumerated()), id: \.offset) { item in
            Button(item.element.title) { act { model.openClosedGroup(group.id, selecting: item.offset) } }
        }
    }

    /// Closes the popover, then runs `action`.
    private func act(_ action: () -> Void) {
        isPresented = false
        action()
    }
}
