// Settings › Appearance: where the tabs show and their default icon, the panels' layout preset, the commit graph's
// avatars, date format, row height and text columns, and the file lists' layout and file sizes.
// No theme choice: Histq is dark only. The window, the graph and `AvatarStore` read these keys and update at once.
import SwiftUI

struct AppearanceSettings: View {
    @AppStorage(PrefKey.tabPosition.rawValue, store: Preferences.defaults) private var tabPosition = "top"
    @AppStorage(PrefKey.layoutPreset.rawValue, store: Preferences.defaults) private var layoutPreset = "classic"
    @AppStorage(PrefKey.defaultTabEmoji.rawValue, store: Preferences.defaults) private var tabEmoji = ""
    @AppStorage(PrefKey.defaultTabIconColor.rawValue, store: Preferences.defaults) private var tabIconColor = -1
    @FocusState private var emojiFocused: Bool
    @AppStorage(PrefKey.avatarMode.rawValue, store: Preferences.defaults) private var avatarMode = "generated"
    @AppStorage(PrefKey.dateFormat.rawValue, store: Preferences.defaults) private var dateFormat = "MM/dd/yy @ HH:mm"
    @AppStorage(PrefKey.rowDensity.rawValue, store: Preferences.defaults) private var rowDensity = "regular"
    @AppStorage(PrefKey.graphShowMessage.rawValue, store: Preferences.defaults) private var showMessage = true
    @AppStorage(PrefKey.graphShowAuthor.rawValue, store: Preferences.defaults) private var showAuthor = true
    @AppStorage(PrefKey.graphShowDate.rawValue, store: Preferences.defaults) private var showDate = true
    @AppStorage(PrefKey.showFileSizes.rawValue, store: Preferences.defaults) private var showFileSizes = true
    @AppStorage(PrefKey.fileListMode.rawValue, store: Preferences.defaults) private var fileListMode =
        FileListMode.tree.rawValue

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
            }
            SettingsGroup("Panels") {
                LabeledContent {
                    // Through `LayoutPreset.choose`, as the View menu: turning Focus on remembers the preset to go
                    // back to.
                    CapsuleTabs(selection: Binding(get: { LayoutPreset.resolved(layoutPreset) },
                                                   set: { if $0 != LayoutPreset.current { LayoutPreset.choose($0) } }),
                                tabs: [LayoutPreset.classic, .stacked, .focus],
                                title: { Text($0.rawValue.capitalized) }, compact: true)
                        .fixedSize()
                } label: {
                    Text("Layout")
                    SettingsHint("Stacked: a file opens under the graph. Focus (⌥⌘F): the sidebar and detail panel hide.")
                }
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
                SettingsDivider()
                Label {
                    Text("Real avatars send each author's email hash to gravatar.com, GitHub logins to GitHub, and "
                        + "the owners of your remotes to GitHub, GitLab or Bitbucket, to download their pictures.")
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
                SettingsDivider()
                LabeledContent {
                    CapsuleTabs(selection: $rowDensity, tabs: ["compact", "regular", "comfortable"],
                                title: { Text($0.capitalized) }, compact: true)
                        .fixedSize()
                } label: {
                    Text("Row height")
                    SettingsHint("Compact fits more commits on screen.")
                }
            }
            SettingsGroup("Graph columns", description: "Branch / Tag and Graph always show.") {
                SettingsSwitchRow(title: "Commit message", isOn: $showMessage)
                SettingsDivider()
                SettingsSwitchRow(title: "Author", isOn: $showAuthor)
                SettingsDivider()
                SettingsSwitchRow(title: "Commit date", isOn: $showDate)
            }
            SettingsGroup("File lists") {
                LabeledContent {
                    CapsuleTabs(selection: $fileListMode,
                                tabs: [FileListMode.tree.rawValue, FileListMode.path.rawValue],
                                title: { $0 == FileListMode.path.rawValue ? Text("Flat") : Text("Tree") },
                                compact: true)
                        .fixedSize()
                } label: {
                    Text("Layout")
                    SettingsHint("Tree: files under their folders. Flat: one row per file. Also switched from each "
                        + "list's header.")
                }
                SettingsDivider()
                SettingsSwitchRow(title: "File sizes",
                                  hint: "In the Unstaged card: yellow from 1 MB, red from 10 MB.",
                                  isOn: $showFileSizes)
            }
        } skeleton: {
            EmptyView()
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
