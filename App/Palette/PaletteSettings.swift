// The command palette's Settings rows: every app-wide switch of the Settings pages as one row that flips it, and every
// choice of 4 options or fewer as one row per option, the stored one marked "(current)". A row writes the preference
// its page writes (`Preferences.defaults`), so the windows follow at once; the palette closes after a row runs and
// reads the rows again on its next open, so the titles and marks never go stale.
import Foundation

@MainActor
extension PaletteCommands {
    /// One row: its title, its Settings page and group (nil: the page's first, unnamed group), whether it is the
    /// stored choice, and its write.
    private struct SettingsRow {
        let title: String
        let section: SettingsSection
        let group: String?
        var isCurrent = false
        let write: @MainActor () -> Void
    }

    /// The Settings rows, in the pages' order (General, Appearance, AI, Terminal). The tab position and the layout
    /// presets are `app`'s rows.
    static func settings(into snapshot: inout PaletteSnapshot) {
        let defaults = Preferences.defaults
        let hiddenSections = SidebarSections.hiddenIDs
        let scrollback = defaults.integer(forKey: PrefKey.terminalScrollback.rawValue)
        let rows: [[SettingsRow]] = [
            choice(.pullMode, .general, "Pull and fetch", "Pull",
                   GeneralSettings.pullModes.map { ($0, GeneralSettings.pullTitle($0)) }),
            choice(.autoStash, .general, "Pull and fetch", "Uncommitted Changes",
                   ["ask", "always", "never"].map { ($0, GeneralSettings.autoStashTitle($0)) }),
            toggle(.pruneOnFetch, "Prune on Fetch", .general, "Pull and fetch"),
            toggle(.autoUpdateSubmodules, "Update Submodules Automatically", .general, "Pull and fetch"),
            choice(.toastLevel, .general, "Notifications", "Operation Toasts",
                   ToastLevel.allCases.map { ($0.rawValue, $0.title) }),
            toggle(.cardBorders, "Card Borders", show: true, .appearance, "Panels"),
            choice(.avatarMode, .appearance, "Avatars", "Commit Avatars",
                   ["generated", "real", "initials"].map { ($0, AppearanceSettings.avatarTitle($0)) }),
            choice(.rowDensity, .appearance, "Commit list", "Row Height",
                   ["compact", "regular", "comfortable"].map { ($0, $0.capitalized) }),
            choice(.textSize, .appearance, "Commit list", "Text Size",
                   TextSize.allCases.map { ($0.rawValue, $0.rawValue.capitalized) }),
            choice(.commitOrder, .appearance, "Commit list", "Commit Order",
                   [("date", "By date"), ("branch", "By branch")]),
            choice(.laneColors, .appearance, "Commit list", "Lane Colors",
                   LaneColors.allCases.map { ($0.rawValue, $0.title) }),
            toggle(.graphFadeOtherWorktrees, "Fade Other Worktrees", .appearance, "Commit list"),
            SidebarSectionID.allCases.flatMap { id in
                toggle("Sidebar Section \(id.title)", show: true, .appearance, "Sidebar",
                       isOn: !hiddenSections.contains(id)) { SidebarSections.setHidden(id, !$0) }
            },
            toggle(.graphShowMessage, "Commit Message Column", show: true, .appearance, "Graph columns"),
            toggle(.graphShowAuthor, "Author Column", show: true, .appearance, "Graph columns"),
            toggle(.graphShowDate, "Time Column", show: true, .appearance, "Graph columns"),
            // Every card follows the new layout, as the page's `onChange` does.
            choice(.fileListMode, .appearance, "File lists", "File List Layout",
                   [(FileListMode.tree.rawValue, "Tree"), (FileListMode.path.rawValue, "Flat")]) { mode in
                defaults.set(mode, forKey: PrefKey.fileListMode.rawValue)
                for card in FileListCard.allCases { defaults.set(mode, forKey: card.key) }
            },
            toggle(.showFileSizes, "File Sizes", show: true, .appearance, "File lists"),
            choice(.commitBoxPosition, .appearance, "WIP panel", "Commit Box",
                   ["top", "bottom"].map { ($0, $0.capitalized) }),
            choice(.stagedPosition, .appearance, "WIP panel", "Staged Card",
                   ["above", "below"].map { ($0, $0.capitalized) }),
            choice(.diffDefaultMode, .appearance, "Diff", "Diff Default View",
                   DiffMode.allCases.map { ($0.rawValue, $0.title) }),
            toggle(.diffIgnoreWhitespace, "Ignore Whitespace", .appearance, "Diff"),
            toggle(.diffWrapLines, "Wrap Long Lines", .appearance, "Diff"),
            toggle(.aiShowFeatures, "AI Features", show: true, .ai, nil),
            toggle(.aiCommitSummaryOnly, "Summary-Only Commit Messages", .ai, "Commit messages"),
            toggle(.aiChatReadsRepository, "Repository Reading in Chat", .ai, "Chat"),
            choice(.terminalCursor, .terminal, "Display", "Terminal Cursor",
                   ["block", "underline", "bar"].map { ($0, $0.capitalized) }),
            // An Int, as the page stores it.
            TerminalSettings.offeredScrollbacks.map { count in
                SettingsRow(title: "Terminal Scrollback: \(count.formatted()) lines", section: .terminal,
                            group: "Display", isCurrent: count == scrollback) {
                    defaults.set(count, forKey: PrefKey.terminalScrollback.rawValue)
                }
            },
            toggle(.terminalBoldText, "Terminal Bold Text", .terminal, "Display"),
            toggle(.terminalOpenWithNewTab, "Open Terminal with Each New Tab", .terminal, "New tabs"),
        ]
        for row in rows.joined() {
            let path = ["Settings", row.section.label.title] + (row.group.map { [$0] } ?? [])
            let detail = path.joined(separator: " › ")
            snapshot.add(row.title, detail: row.isCurrent ? detail + " (current)" : detail, section: .settings,
                         systemImage: row.section.label.icon, perform: row.write)
        }
    }

    /// A switch, titled with what the row does now: "Turn Off <name>" while on, else "Turn On <name>" (with `show`,
    /// "Hide" / "Show"). `write` gets the new value.
    private static func toggle(_ name: String, show: Bool = false, _ section: SettingsSection, _ group: String?,
                               isOn: Bool, write: @escaping @MainActor (Bool) -> Void) -> [SettingsRow]
    {
        let verb = show ? (isOn ? "Hide" : "Show") : (isOn ? "Turn Off" : "Turn On")
        return [SettingsRow(title: "\(verb) \(name)", section: section, group: group) { write(!isOn) }]
    }

    /// A switch stored as a bool under `key`.
    private static func toggle(_ key: PrefKey, _ name: String, show: Bool = false, _ section: SettingsSection,
                               _ group: String?) -> [SettingsRow]
    {
        toggle(name, show: show, section, group, isOn: Preferences.defaults.bool(forKey: key.rawValue)) {
            Preferences.defaults.set($0, forKey: key.rawValue)
        }
    }

    /// A choice stored as a string under `key`: one row "<name>: <label>" per `(value, label)`, in the page's order.
    /// `write` replaces the plain write of the value.
    private static func choice(_ key: PrefKey, _ section: SettingsSection, _ group: String, _ name: String,
                               _ options: [(value: String, label: String)],
                               write: (@MainActor (String) -> Void)? = nil) -> [SettingsRow]
    {
        let stored = Preferences.defaults.string(forKey: key.rawValue)
        return options.map { option in
            SettingsRow(title: "\(name): \(option.label)", section: section, group: group,
                        isCurrent: option.value == stored) {
                guard let write else { return Preferences.defaults.set(option.value, forKey: key.rawValue) }
                write(option.value)
            }
        }
    }
}
