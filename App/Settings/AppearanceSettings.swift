// Settings › Appearance: where the tabs show, the commit graph's avatars, date format, row height and text columns.
// No theme choice: Histq is dark only. The window, the graph and `AvatarStore` read these keys and update at once.
import SwiftUI

struct AppearanceSettings: View {
    @AppStorage(PrefKey.tabPosition.rawValue, store: Preferences.defaults) private var tabPosition = "top"
    @AppStorage(PrefKey.avatarMode.rawValue, store: Preferences.defaults) private var avatarMode = "generated"
    @AppStorage(PrefKey.dateFormat.rawValue, store: Preferences.defaults) private var dateFormat = "MM/dd/yy @ HH:mm"
    @AppStorage(PrefKey.rowDensity.rawValue, store: Preferences.defaults) private var rowDensity = "regular"
    @AppStorage(PrefKey.graphShowMessage.rawValue, store: Preferences.defaults) private var showMessage = true
    @AppStorage(PrefKey.graphShowAuthor.rawValue, store: Preferences.defaults) private var showAuthor = true
    @AppStorage(PrefKey.graphShowDate.rawValue, store: Preferences.defaults) private var showDate = true

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
                    Text("Real avatars send each author's email hash to gravatar.com, and GitHub logins to GitHub, "
                        + "to download their pictures.")
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
        } skeleton: {
            EmptyView()
        }
    }

    private var formats: [String] {
        Self.dateFormats.contains(dateFormat) ? Self.dateFormats : Self.dateFormats + [dateFormat]
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
