// Settings › Appearance: where the tabs show and their default icon, the panels' layout preset, the commit graph's
// avatars, date format, row height, text size and commit order, the sidebar's sections (shown, and their order in each
// tab), the graph's text columns, the file lists' layout and file sizes, the WIP panel's order, and the diffs' default
// view and whitespace.
// No theme choice: Histq is dark only. The window, the graph and `AvatarStore` read these keys and update at once.
import SwiftUI

struct AppearanceSettings: View {
    @AppStorage(PrefKey.tabPosition.rawValue, store: Preferences.defaults) private var tabPosition = "top"
    @AppStorage(PrefKey.layoutPreset.rawValue, store: Preferences.defaults) private var layoutPreset = "classic"
    @AppStorage(PrefKey.cardBorders.rawValue, store: Preferences.defaults) private var cardBorders = true
    @AppStorage(PrefKey.defaultTabEmoji.rawValue, store: Preferences.defaults) private var tabEmoji = ""
    @AppStorage(PrefKey.defaultTabIconColor.rawValue, store: Preferences.defaults) private var tabIconColor = -1
    @FocusState private var emojiFocused: Bool
    @AppStorage(PrefKey.avatarMode.rawValue, store: Preferences.defaults) private var avatarMode = "generated"
    @AppStorage(PrefKey.dateFormat.rawValue, store: Preferences.defaults) private var dateFormat = "MM/dd/yy @ HH:mm"
    @AppStorage(PrefKey.rowDensity.rawValue, store: Preferences.defaults) private var rowDensity = "regular"
    @AppStorage(PrefKey.commitOrder.rawValue, store: Preferences.defaults) private var commitOrder = "date"
    @AppStorage(PrefKey.textSize.rawValue, store: Preferences.defaults) private var textSize = TextSize.regular.rawValue
    @AppStorage(PrefKey.graphShowMessage.rawValue, store: Preferences.defaults) private var showMessage = true
    @AppStorage(PrefKey.graphShowAuthor.rawValue, store: Preferences.defaults) private var showAuthor = true
    @AppStorage(PrefKey.graphShowDate.rawValue, store: Preferences.defaults) private var showDate = true
    @AppStorage(PrefKey.showFileSizes.rawValue, store: Preferences.defaults) private var showFileSizes = true
    @AppStorage(PrefKey.fileListMode.rawValue, store: Preferences.defaults) private var fileListMode =
        FileListMode.tree.rawValue
    @AppStorage(PrefKey.sidebarSectionOrder.rawValue, store: Preferences.defaults) private var sectionOrder = ""
    @AppStorage(PrefKey.hiddenSidebarSections.rawValue, store: Preferences.defaults) private var hiddenSections = ""
    @AppStorage(PrefKey.commitBoxPosition.rawValue, store: Preferences.defaults) private var commitBoxPosition = "bottom"
    @AppStorage(PrefKey.stagedPosition.rawValue, store: Preferences.defaults) private var stagedPosition = "below"
    @AppStorage(PrefKey.diffDefaultMode.rawValue, store: Preferences.defaults) private var diffDefaultMode =
        DiffMode.diff.rawValue
    @AppStorage(PrefKey.diffIgnoreWhitespace.rawValue, store: Preferences.defaults) private var ignoresWhitespace = false
    @AppStorage(PrefKey.diffWrapLines.rawValue, store: Preferences.defaults) private var wrapsLines = false
    @AppStorage(PrefKey.codeFontSize.rawValue, store: Preferences.defaults) private var codeFontSize = 12.0

    /// The date formats offered, the shortest (the default, 24 h) first; a format set by hand (`defaults write`) is
    /// listed too.
    private static let dateFormats = [
        "MM/dd/yy @ HH:mm", "MM/dd/yyyy @ h:mm a", "dd/MM/yyyy HH:mm", "yyyy-MM-dd HH:mm", "MMM d, yyyy h:mm a",
        "d MMM yyyy HH:mm",
    ]

    var body: some View {
        SettingsPageGate(section: .appearance, isLoaded: true) {
            SettingsGroup("Tabs") {
                LabeledContent {
                    CapsuleTabs(selection: $tabPosition, tabs: [TabPosition.top.rawValue, TabPosition.left.rawValue],
                                title: { $0 == TabPosition.left.rawValue ? Text("Left") : Text("Top") }, compact: true)
                        .fixedSize()
                } label: {
                    Text("Tab position")
                    SettingsHint("Top: a strip under the toolbar. Left: a column beside the panels.")
                }
                .settingsSearchAnchor("Tab position")
                SettingsDivider()
                LabeledContent {
                    HStack(spacing: 8) {
                        TextField("Emoji", text: $tabEmoji, prompt: Text("None"))
                            .textFieldStyle(.settings)
                            .frame(width: 64)
                            .labelsHidden()
                            .autocorrectionDisabled()
                            .focused($emojiFocused)
                            .onChange(of: tabEmoji) { _, new in
                                // One emoji only, as a tab's Set Emoji… keeps it.
                                let kept = TabEmoji.normalized(new) ?? ""
                                if kept != new { tabEmoji = kept }
                            }
                        Button("Choose…", action: chooseEmoji)
                            .buttonStyle(RowTextButtonStyle(formRow: true))
                    }
                } label: {
                    Text("Default tab emoji")
                    SettingsHint("Shown instead of the book on tabs without their own emoji or icon color. Empty: "
                        + "the book.")
                }
                .settingsSearchAnchor("Default tab emoji")
                SettingsDivider()
                LabeledContent {
                    CapsuleMenuPicker(label: "Default icon color", selection: $tabIconColor,
                                      title: Self.colorTitle(tabIconColor)) {
                        Text("Default").tag(-1)
                        ForEach(ProfileColors.hexes.indices, id: \.self) { index in
                            Self.colorTitle(index).tag(index)
                        }
                    }
                    .disabled(!tabEmoji.isEmpty)
                } label: {
                    Text("Default icon color")
                    SettingsHint("The book's color on tabs without their own. Default: the tab's text color.")
                }
                .settingsSearchAnchor("Default icon color")
            }
            SettingsGroup("Panels") {
                LabeledContent {
                    // Through `LayoutPreset.choose`, as the View menu: turning Focus on remembers the preset to go
                    // back to.
                    CapsuleTabs(selection: Binding(get: { LayoutPreset.resolved(layoutPreset) },
                                                   set: { if $0 != LayoutPreset.current { LayoutPreset.choose($0) } }),
                                tabs: [LayoutPreset.classic, .stacked, .columns, .focus],
                                title: { Text($0.rawValue.capitalized) }, compact: true)
                        .fixedSize()
                } label: {
                    Text("Layout")
                    SettingsHint("Stacked: a file opens under the graph. Columns: a file opens in a 4th column. "
                        + "Focus (⌥⌘F): the sidebar and detail panel hide.")
                }
                .settingsSearchAnchor("Layout")
                SettingsDivider()
                SettingsSwitchRow(title: "Card borders", hint: "A thin light edge around each card.",
                                  isOn: $cardBorders)
            }
            SettingsGroup("Avatars") {
                LabeledContent {
                    CapsuleTabs(selection: $avatarMode, tabs: ["generated", "real", "initials"],
                                title: { Text(Self.avatarTitle($0)) }, compact: true)
                        .fixedSize()
                } label: {
                    Text("Commit avatars")
                    SettingsHint("Generated: a pattern from each author's email, drawn on this Mac.")
                }
                .settingsSearchAnchor("Commit avatars")
                SettingsDivider()
                Label {
                    Text("Real avatars send each author's email hash to gravatar.com and GitHub logins to GitHub "
                        + "to download their pictures. GitHub's bots always show theirs, and your remotes always "
                        + "show their owners' logos (the owner's name goes to GitHub, GitLab or Bitbucket). GitHub "
                        + "accounts on the PRs tab and the pull request and issue pages always show their GitHub "
                        + "avatars (their logins go to GitHub).")
                        .font(.settingsCaption)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: avatarMode == "real" ? "exclamationmark.triangle" : "info.circle")
                }
                .foregroundStyle(.secondary)
            }
            SettingsGroup("Commit list") {
                LabeledContent {
                    CapsuleMenuPicker(label: "Date format", selection: $dateFormat,
                                      title: Text(Self.sample(dateFormat))) {
                        ForEach(formats, id: \.self) { format in
                            Text(Self.sample(format)).tag(format)
                        }
                    }
                } label: {
                    Text("Date format")
                    SettingsHint("The commit list's Date column.")
                }
                .settingsSearchAnchor("Date format")
                SettingsDivider()
                LabeledContent {
                    CapsuleTabs(selection: $rowDensity, tabs: ["compact", "regular", "comfortable"],
                                title: { Text($0.capitalized) }, compact: true)
                        .fixedSize()
                } label: {
                    Text("Row height")
                    SettingsHint("Compact fits more commits on screen.")
                }
                .settingsSearchAnchor("Row height")
                SettingsDivider()
                LabeledContent {
                    CapsuleTabs(selection: $textSize, tabs: TextSize.allCases.map(\.rawValue),
                                title: { Text($0.capitalized) }, compact: true)
                        .fixedSize()
                } label: {
                    Text("Text size")
                    SettingsHint("The graph, sidebar and file lists. Separate from row height.")
                }
                .settingsSearchAnchor("Text size")
                SettingsDivider()
                LabeledContent {
                    CapsuleTabs(selection: $commitOrder, tabs: ["date", "branch"],
                                title: { $0 == "branch" ? Text("By branch") : Text("By date") }, compact: true)
                        .fixedSize()
                } label: {
                    Text("Commit order")
                    SettingsHint("By date: newest first across branches. By branch: each branch's commits stay "
                        + "together.")
                }
                .settingsSearchAnchor("Commit order")
            }
            SettingsGroup("Sidebar", description: "A tab with no section left goes away, except Branches.") {
                let order = sidebarOrder
                let hidden = hiddenSidebarIDs
                ForEach(SidebarTab.allCases, id: \.self) { tab in
                    if tab != SidebarTab.allCases.first { SettingsDivider() }
                    Text(tab.title)
                        .font(.settingsCaption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 6)
                    let ids = order.filter { $0.tab == tab }
                    ForEach(ids, id: \.self) { id in
                        if id != ids.first { SettingsDivider() }
                        sidebarRow(id, in: ids, isHidden: hidden.contains(id))
                    }
                }
            }
            SettingsGroup("Graph columns", description: "Branch / Tag and Graph always show.") {
                SettingsSwitchRow(title: "Commit message", isOn: $showMessage)
                SettingsDivider()
                SettingsSwitchRow(title: "Author", isOn: $showAuthor)
                SettingsDivider()
                SettingsSwitchRow(title: "Time", isOn: $showDate)
            }
            SettingsGroup("File lists") {
                LabeledContent {
                    CapsuleTabs(selection: $fileListMode,
                                tabs: [FileListMode.tree.rawValue, FileListMode.path.rawValue],
                                title: { $0 == FileListMode.path.rawValue ? Text("Flat") : Text("Tree") },
                                compact: true)
                        .fixedSize()
                        // Every card follows the new layout; a card's header switches only that card.
                        .onChange(of: fileListMode) { _, new in
                            for card in FileListCard.allCases { Preferences.defaults.set(new, forKey: card.key) }
                        }
                } label: {
                    Text("Layout")
                    SettingsHint("Tree: files under their folders. Flat: one row per file. For every "
                        + "list; each list's header switches only that list.")
                }
                .settingsSearchAnchor("Layout")
                SettingsDivider()
                SettingsSwitchRow(title: "File sizes",
                                  hint: "In the Unstaged card: yellow from 1 MB, red from 10 MB.",
                                  isOn: $showFileSizes)
            }
            SettingsGroup("WIP panel") {
                LabeledContent {
                    CapsuleTabs(selection: $commitBoxPosition, tabs: ["top", "bottom"],
                                title: { Text($0.capitalized) }, compact: true)
                        .fixedSize()
                } label: {
                    Text("Commit box")
                    SettingsHint("Above or under the file cards.")
                }
                .settingsSearchAnchor("Commit box")
                SettingsDivider()
                LabeledContent {
                    CapsuleTabs(selection: $stagedPosition, tabs: ["above", "below"],
                                title: { Text($0.capitalized) }, compact: true)
                        .fixedSize()
                } label: {
                    Text("Staged")
                    SettingsHint("The Staged card, above or below Unstaged; also in another worktree's changes.")
                }
                .settingsSearchAnchor("Staged")
            }
            SettingsGroup("Diff") {
                LabeledContent {
                    CapsuleTabs(selection: Binding(get: { DiffMode(rawValue: diffDefaultMode) ?? .diff },
                                                   set: { diffDefaultMode = $0.rawValue }),
                                tabs: DiffMode.allCases, title: { Text($0.title) }, compact: true)
                        .fixedSize()
                } label: {
                    Text("Default view")
                    SettingsHint("Where a newly opened repository's diffs start. Split: old and new side by side.")
                }
                .settingsSearchAnchor("Default view")
                SettingsDivider()
                SettingsSwitchRow(title: "Ignore whitespace",
                                  hint: "Line staging is off while whitespace is ignored.",
                                  isOn: $ignoresWhitespace)
                SettingsDivider()
                LabeledContent {
                    CapsuleMenuPicker(label: "Code font size", selection: $codeFontSize,
                                      title: Text("\(Int(codeFontSize)) pt")) {
                        ForEach([11.0, 12, 13, 14, 16], id: \.self) { size in
                            Text("\(Int(size)) pt").tag(size)
                        }
                    }
                } label: {
                    Text("Code font size")
                    SettingsHint("The diff, Blame and the conflict editor.")
                }
                .settingsSearchAnchor("Code font size")
                SettingsDivider()
                SettingsSwitchRow(title: "Wrap long lines", isOn: $wrapsLines)
            }
        } skeleton: {
            EmptyView()
        }
    }

    /// Every sidebar section, hidden ones too, in the user's order.
    private var sidebarOrder: [SidebarSectionID] {
        SidebarSections(order: sectionOrder, hidden: "").visible
    }

    private var hiddenSidebarIDs: Set<SidebarSectionID> {
        Set(SidebarSectionID.allCases).subtracting(SidebarSections(order: sectionOrder, hidden: hiddenSections).visible)
    }

    /// A section's row: up and down (inside its tab, `ids`; none for a tab of one section), then its switch.
    private func sidebarRow(_ id: SidebarSectionID, in ids: [SidebarSectionID], isHidden: Bool) -> some View {
        let title = Self.sectionTitle(id)
        return LabeledContent {
            HStack(spacing: 8) {
                if ids.count > 1 {
                    HStack(spacing: 4) {
                        moveButton(id, title: title, up: true, disabled: id == ids.first)
                        moveButton(id, title: title, up: false, disabled: id == ids.last)
                    }
                }
                Toggle(title, isOn: Binding(get: { !isHidden }, set: { setHidden(id, !$0) }))
                    .toggleStyle(CompactSwitch())
                    .labelsHidden()
            }
        } label: {
            Text(title)
            if id == .allOpen {
                SettingsHint("Still loads when hidden: it feeds the graph's pull request badges.")
            } else if id == .submodules {
                SettingsHint("Only in a repository that has submodules.")
            }
        }
    }

    private func moveButton(_ id: SidebarSectionID, title: String, up: Bool, disabled: Bool) -> some View {
        Button { move(id, up: up) } label: {
            Image(systemName: up ? "chevron.up" : "chevron.down")
        }
        .buttonStyle(RowTextButtonStyle(formRow: true))
        .disabled(disabled)
        .help(up ? "Move Up" : "Move Down")
        .accessibilityLabel(up ? "Move \(title) up" : "Move \(title) down")
    }

    /// Swaps `id` with its neighbor in its tab, and writes the whole order back.
    private func move(_ id: SidebarSectionID, up: Bool) {
        var order = sidebarOrder
        let tabIDs = order.filter { $0.tab == id.tab }
        guard let index = tabIDs.firstIndex(of: id) else { return }
        let neighbor = index + (up ? -1 : 1)
        guard tabIDs.indices.contains(neighbor), let from = order.firstIndex(of: id),
              let to = order.firstIndex(of: tabIDs[neighbor]) else { return }
        order.swapAt(from, to)
        sectionOrder = order.map(\.rawValue).joined(separator: ",")
    }

    private func setHidden(_ id: SidebarSectionID, _ hides: Bool) {
        var hidden = hiddenSidebarIDs
        if hides { hidden.insert(id) } else { hidden.remove(id) }
        hiddenSections = SidebarSectionID.allCases.filter(hidden.contains).map(\.rawValue).joined(separator: ",")
    }

    /// The section's title in the sidebar.
    private static func sectionTitle(_ id: SidebarSectionID) -> String {
        switch id {
        case .local: "Local"
        case .remote: "Remote"
        case .worktrees: "Worktrees"
        case .submodules: "Submodules"
        case .tags: "Tags"
        case .mine, .reviewRequested, .allOpen, .assigned: GitHubStore.List(rawValue: id.rawValue)?.title ?? id.rawValue
        }
    }

    private var formats: [String] {
        Self.dateFormats.contains(dateFormat) ? Self.dateFormats : Self.dateFormats + [dateFormat]
    }

    /// Focuses the emoji field, then opens the Character Viewer on the next turn, so its pick goes into the field.
    private func chooseEmoji() {
        emojiFocused = true
        DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
    }

    /// A lane color's name after its dot; "Default" for -1 (or a number out of range).
    private static func colorTitle(_ index: Int) -> Text {
        guard ProfileColors.hexes.indices.contains(index) else { return Text("Default") }
        return Text("\(Image(nsImage: ProfilePicker.dot(hex: ProfileColors.hexes[index], gap: 4)))\(TabIcon.colorName(index))")
    }

    private static func avatarTitle(_ mode: String) -> String {
        switch mode {
        case "real": "Real"
        case "initials": "Initials"
        default: "Generated"
        }
    }

    /// Today's date in `format`, as the menu shows it.
    private static func sample(_ format: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter.string(from: .now)
    }
}
