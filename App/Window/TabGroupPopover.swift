// A manual tab group's popover, opened from its chip (top tabs) or its header (vertical tabs).
import SwiftUI

/// A group's popover, styled as the tab list's (`TabListPopover`): its name (live, empty for none; focused when it
/// opens), its 9 swatches (the current one ringed), then New Tab in Group, Move Group to New Window, Close Group (hides
/// the group in the window's closed groups), Delete Group (closes its tabs) and Ungroup. Move and Delete are off while
/// the group holds every normal tab of the window. A row closes the popover before it acts; Return and Esc close it.
struct TabGroupPopover: View {
    let model: WindowModel
    let groupID: UUID
    /// Seeded once: the model trims the name, so a field bound to it would eat a space as it is typed.
    @State private var name: String
    @FocusState private var nameFocused: Bool

    init(model: WindowModel, groupID: UUID) {
        self.model = model
        self.groupID = groupID
        _name = State(initialValue: model.groups.first { $0.id == groupID }?.name ?? "")
    }

    var body: some View {
        let colorIndex = model.groups.first { $0.id == groupID }?.colorIndex
        let holdsAll = model.groupHoldsAllNormalTabs(groupID)
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: $name, prompt: Text("Name this group"))
                .textFieldStyle(.settings)
                .labelsHidden()
                .focused($nameFocused)
                .onChange(of: name) { _, name in model.setGroupName(groupID, name) }
                .onSubmit(close)
                .padding(.horizontal, 10)
            swatches(selected: colorIndex)
                .padding(.horizontal, 10)
            VStack(spacing: SidebarItemStyle.spacing) {
                row("New Tab in Group", systemImage: "plus") { model.newTabInGroup(groupID) }
                row("Move Group to New Window", systemImage: "macwindow.badge.plus", disabled: holdsAll,
                    help: holdsAll ? Self.holdsAllHelp
                        : "Terminals and AI jobs in its tabs stop; the tabs reopen in the new window.") {
                    model.moveGroupToNewWindow(groupID)
                }
                row("Close Group", systemImage: "xmark.circle",
                    help: "Hide the group; reopen it from Closed Groups.") {
                    model.closeGroup(groupID)
                }
                row("Delete Group", systemImage: "trash", disabled: holdsAll,
                    help: holdsAll ? Self.holdsAllHelp : "Close the group and its tabs; ⇧⌘T brings them back.") {
                    model.confirmDeleteGroup(groupID)
                }
                row("Ungroup", systemImage: "square.dashed") { model.ungroup(groupID) }
            }
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 10)
        .frame(width: 280)
        .onExitCommand(perform: close)
        // Next run-loop turn, once the popover's window exists.
        .onAppear { DispatchQueue.main.async { nameFocused = true } }
    }

    /// Why Delete Group and Move Group to New Window are off.
    private static let holdsAllHelp = "The group holds every tab of the window."

    /// The 9 colors as circles, spread over the row; a click recolors the group at once.
    private func swatches(selected: Int?) -> some View {
        HStack(spacing: 0) {
            ForEach(0...8, id: \.self) { index in
                Button { model.setGroupColor(groupID, index) } label: {
                    Circle()
                        .fill(TabGroupColors.line(index))
                        .frame(width: 16, height: 16)
                        .padding(3)
                        .overlay {
                            if index == selected { Circle().strokeBorder(Color.primary, lineWidth: 1.5) }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(index == 0 ? "Grey" : "Color \(index)")
                .accessibilityAddTraits(index == selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 2)
    }

    /// One action row, as the tab list's rows; it closes the popover, then acts.
    private func row(_ title: String, systemImage: String, disabled: Bool = false, help: String? = nil,
                     action: @escaping () -> Void) -> some View {
        Button {
            close()
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
        }
        .buttonStyle(SidebarItemStyle(selected: false))
        .disabled(disabled)
        // `SidebarItemStyle` does not dim a disabled row; the other button styles' dim.
        .opacity(disabled ? 0.45 : 1)
        .help(help ?? "")
    }

    private func close() {
        if model.groupPopoverID == groupID { model.groupPopoverID = nil }
    }
}

/// Opens a group's popover from its chip or vertical header: a right click or ⌃-click on it sets
/// `WindowModel.groupPopoverID`, and the popover shows while that is its group, its arrow on `arrowEdge`.
struct TabGroupPopoverAnchor: ViewModifier {
    let model: WindowModel
    let groupID: UUID
    let arrowEdge: Edge
    @State private var showing = false

    func body(content: Content) -> some View {
        content
            // Not under the palette, Settings or a modal: the click is theirs.
            .background(RightClickCatcher {
                guard !model.isShowingModal else { return false }
                model.groupPopoverID = groupID
                return true
            })
            .popover(isPresented: Binding(get: { showing }, set: { shown in
                showing = shown
                // Only its own: another group's popover may be opening.
                if !shown, model.groupPopoverID == groupID { model.groupPopoverID = nil }
            }), arrowEdge: arrowEdge) {
                TabGroupPopover(model: model, groupID: groupID)
            }
            // Initial too: a new group's chip appears with the id already set (Add Tab to New Group).
            .onChange(of: model.groupPopoverID == groupID, initial: true) { _, open in
                guard open else {
                    showing = false
                    return
                }
                // Two turns later: the chip may have just been added, the row scrolls it into view on the next turn
                // (and the tab's menu is closing), so the popover anchors where the chip ends up.
                DispatchQueue.main.async {
                    DispatchQueue.main.async { showing = model.groupPopoverID == groupID }
                }
            }
    }
}

extension View {
    /// The group's popover on this chip or header (`TabGroupPopoverAnchor`).
    func tabGroupPopover(model: WindowModel, groupID: UUID, arrowEdge: Edge) -> some View {
        modifier(TabGroupPopoverAnchor(model: model, groupID: groupID, arrowEdge: arrowEdge))
    }
}
