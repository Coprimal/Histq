// Settings search: the header's magnifier grows into a search field, and while it has a query the sidebar lists the
// sections with a match and the page shows the matching rows; a click on one opens its section, scrolls to the row and
// flashes it.
import HistqCore
import SwiftUI

/// The search result to show on its page, once: the row (or group) with a matching `SettingsSearchAnchor` scrolls into
/// view and flashes. Each click sets a new target, so the same result clicked twice flashes twice; the anchor that
/// shows it clears it, and so does `clear` a moment later, so a row that appears afterwards never flashes on its own.
@MainActor @Observable
final class SettingsSearchReveal {
    struct Target: Equatable {
        let id = UUID()
        let item: SettingsSearchItem

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    }

    private(set) var target: Target?

    func reveal(_ item: SettingsSearchItem) {
        target = Target(item: item)
    }

    /// The anchor showing `target` takes it, so no other one shows it too.
    func take(_ id: UUID) -> Bool {
        guard target?.id == id else { return false }
        target = nil
        return true
    }
}

extension EnvironmentValues {
    /// Set on the Settings pages only: anchors elsewhere (a modal's rows) stay inert.
    @Entry var settingsSearchReveal: SettingsSearchReveal?
    @Entry var settingsPageSection: SettingsSection?
    @Entry var settingsScrollProxy: ScrollViewProxy?
    /// The title of the `SettingsGroup` a row is in.
    @Entry var settingsGroupTitle: String?
}

extension View {
    /// Marks a Settings row titled `title` (in the `SettingsGroup` around it) as a search result's place.
    func settingsSearchAnchor(_ title: String) -> some View {
        modifier(SettingsSearchAnchor(title: title, groupTitle: nil))
    }
}

/// A row's (or, with `groupTitle`, a whole group's) place for `SettingsSearchReveal`: when the target is it, the page
/// scrolls to it and a soft accent fill fades in behind it and out again. A group whose target row is not on the page
/// (it needs a profile, another provider) shows the target itself, a moment later.
struct SettingsSearchAnchor: ViewModifier {
    /// Nil for a group.
    let title: String?
    /// A group's own title; nil for a row, which reads its group from the environment.
    let groupTitle: String?
    @Environment(\.settingsSearchReveal) private var reveal
    @Environment(\.settingsPageSection) private var section
    @Environment(\.settingsScrollProxy) private var proxy
    @Environment(\.settingsGroupTitle) private var environmentGroup
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flash = false

    private var group: String? { title == nil ? groupTitle : environmentGroup }
    private var key: String { "settings-search:\(group ?? "")/\(title ?? "")" }

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(flash ? 0.22 : 0))
                    .padding(.horizontal, title == nil ? -4 : -8)
                    .padding(.vertical, title == nil ? -4 : -6)
                    .allowsHitTesting(false)
                    // On the fill, not the row: a row in a group with a changing title (AI's provider) keeps its
                    // identity, and its state.
                    .id(key)
            }
            .onChange(of: reveal?.target, initial: true) { _, target in
                guard let target, let reveal, target.item.section == section else { return }
                let item = target.item
                if item.title == title, item.group == nil || item.group == group {
                    if reveal.take(target.id) { show() }
                } else if title == nil, let group, item.group == group {
                    // The group of a row that is not on the page: its own rows answer first.
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) {
                        if reveal.take(target.id) { show() }
                    }
                }
            }
    }

    /// Scrolls here (a group to the top: it may be taller than the page) once laid out, then flashes.
    private func show() {
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? nil : Motion.standard) {
                proxy?.scrollTo(key, anchor: title == nil ? .top : .center)
            }
            flash = true
            withAnimation(.easeOut(duration: 1.2).delay(0.7)) { flash = false }
        }
    }
}

/// A Settings row (or a whole group) the search can find: its title as the page shows it, the group it is in, words
/// users may type instead, and its section.
struct SettingsSearchItem: Identifiable {
    let section: SettingsSection
    let group: String?
    /// Nil for a group searched as a whole (Sidebar, Passphrases).
    var title: String?
    var keywords: [String] = []

    var id: String { path }

    /// "Appearance › Diff › Wrap long lines": the section, then the group and the row when they have a title.
    var path: String {
        [section.label.title, group, title].compactMap { $0 }.joined(separator: " › ")
    }

    /// True when `term` (trimmed, not empty) is in the title, the group, the section's title or a keyword, ignoring
    /// case and accents.
    func matches(_ term: String) -> Bool {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return false }
        return ([section.label.title, group, title].compactMap { $0 } + keywords)
            .contains { $0.localizedStandardContains(term) }
    }

    /// The rows matching `query`, in the order of the sidebar and of each page.
    static func matching(_ query: String) -> [SettingsSearchItem] {
        all.filter { $0.matches(query) }
    }

    /// Every searchable row, in the order of the sidebar and of each page. A new row on a page gets its line here.
    static let all: [SettingsSearchItem] = [
        // General
        .init(section: .general, group: "New tabs", title: "Default profile", keywords: ["profile", "new tab"]),
        .init(section: .general, group: "Pull and fetch", title: "Pull",
              keywords: ["fast-forward", "rebase", "merge", "toolbar"]),
        .init(section: .general, group: "Pull and fetch", title: "Uncommitted changes",
              keywords: ["stash", "autostash", "checkout", "ask", "always", "never"]),
        .init(section: .general, group: "Pull and fetch", title: "Fetch automatically",
              keywords: ["auto fetch", "interval", "minutes", "remotes"]),
        .init(section: .general, group: "Pull and fetch", title: "Prune on fetch",
              keywords: ["prune", "remote branches", "deleted branches"]),
        .init(section: .general, group: "Pull and fetch", title: "Update submodules automatically",
              keywords: ["submodule", "checkout", "rebase", "reset"]),
        .init(section: .general, group: "Notifications", title: "Operation toasts",
              keywords: ["toast", "notification", "push", "pull", "fetch", "commit"]),
        .init(section: .general, group: "Merge tool", title: "External merge tool",
              keywords: ["mergetool", "merge.tool", "opendiff", "vscode", "kdiff3", "conflict"]),
        .init(section: .general, group: "Git", title: "Git executable",
              keywords: ["git path", "binary", "homebrew", "/usr/bin", "version", "command line tools"]),

        // Appearance
        .init(section: .appearance, group: "Tabs", title: "Tab position", keywords: ["top", "left", "tab strip"]),
        .init(section: .appearance, group: "Tabs", title: "Default tab emoji", keywords: ["emoji", "icon", "book"]),
        .init(section: .appearance, group: "Tabs", title: "Default icon color", keywords: ["color", "icon", "book"]),
        .init(section: .appearance, group: "Panels", title: "Layout",
              keywords: ["classic", "stacked", "columns", "focus", "panels"]),
        .init(section: .appearance, group: "Panels", title: "Card borders", keywords: ["border", "edge", "outline"]),
        .init(section: .appearance, group: "Avatars", title: "Commit avatars",
              keywords: ["avatar", "picture", "photo", "generated", "real", "initials"]),
        .init(section: .appearance, group: "Commit list", title: "Date format", keywords: ["date", "time", "24 h"]),
        .init(section: .appearance, group: "Commit list", title: "Row height",
              keywords: ["compact", "regular", "comfortable", "density"]),
        .init(section: .appearance, group: "Commit list", title: "Text size",
              keywords: ["font size", "bigger", "smaller", "zoom"]),
        .init(section: .appearance, group: "Commit list", title: "Commit order",
              keywords: ["by date", "by branch", "sort", "date order"]),
        .init(section: .appearance, group: "Commit list", title: "Fade other worktrees",
              keywords: ["worktree", "dim", "fade", "branch"]),
        .init(section: .appearance, group: "Sidebar",
              keywords: ["sidebar sections", "hide", "reorder", "Branches", "Tags", "Pull requests", "Issues", "Local",
                         "Remote", "Worktrees", "Submodules"]),
        .init(section: .appearance, group: "Graph columns", title: "Commit message", keywords: ["column"]),
        .init(section: .appearance, group: "Graph columns", title: "Author", keywords: ["column"]),
        .init(section: .appearance, group: "Graph columns", title: "Time", keywords: ["column", "date"]),
        .init(section: .appearance, group: "File lists", title: "Layout", keywords: ["tree", "flat", "path", "folders"]),
        .init(section: .appearance, group: "File lists", title: "File sizes",
              keywords: ["size", "large files", "MB", "unstaged"]),
        .init(section: .appearance, group: "WIP panel", title: "Commit box",
              keywords: ["top", "bottom", "commit message", "position"]),
        .init(section: .appearance, group: "WIP panel", title: "Staged", keywords: ["unstaged", "above", "below"]),
        .init(section: .appearance, group: "Diff", title: "Default view",
              keywords: ["split", "side by side", "unified", "file view"]),
        .init(section: .appearance, group: "Diff", title: "Ignore whitespace", keywords: ["whitespace", "spaces"]),
        .init(section: .appearance, group: "Diff", title: "Code font size",
              keywords: ["font", "monospaced", "blame", "conflict editor"]),
        .init(section: .appearance, group: "Diff", title: "Wrap long lines", keywords: ["wrap", "soft wrap"]),

        // Profiles
        .init(section: .profiles, group: "Profiles",
              keywords: ["profile", "add profile", "delete profile", "identity", "account"]),
        .init(section: .profiles, group: "Profile", title: "Name", keywords: ["profile name"]),
        .init(section: .profiles, group: "Profile", title: "Color", keywords: ["profile color", "tab color"]),
        .init(section: .profiles, group: "Profile", title: "Default profile", keywords: ["default", "new tab"]),
        .init(section: .profiles, group: "Commit identity", title: "Name",
              keywords: ["user.name", "author", "identity"]),
        .init(section: .profiles, group: "Commit identity", title: "Email",
              keywords: ["user.email", "author", "identity"]),
        .init(section: .profiles, group: "Commit identity", title: "Global git config",
              keywords: ["gitconfig", "global", "import", "user.name", "user.email"]),
        .init(section: .profiles, group: "Commit signing", title: "Sign with",
              keywords: ["signing", "sign", "gpg", "ssh", "gpg.format"]),
        .init(section: .profiles, group: "Commit signing", title: "GPG key",
              keywords: ["gpg", "signing key", "user.signingkey"]),
        .init(section: .profiles, group: "Commit signing", title: "SSH signing key",
              keywords: ["ssh", "signing key", ".pub", "user.signingkey"]),
        .init(section: .profiles, group: "Commit signing", title: "Sign commits by default",
              keywords: ["commit.gpgsign", "signed", "verified"]),

        // SSH
        .init(section: .ssh, group: "New key", title: "Generate an ed25519 key",
              keywords: ["generate key", "new key", "ssh-keygen", "ed25519"]),
        .init(section: .ssh, group: "Key", title: "Use ssh-agent", keywords: ["agent", "~/.ssh/config", "ssh config"]),
        .init(section: .ssh, group: "Key", title: "Private key",
              keywords: ["key file", "identity file", "id_ed25519", "id_rsa"]),
        .init(section: .ssh, group: "Key", title: "Public key", keywords: [".pub", "copy public key"]),
        .init(section: .ssh, group: "Passphrases", keywords: ["passphrase", "keychain", "ssh-add", "BatchMode"]),

        // Integrations
        .init(section: .integrations, group: "GitHub account",
              keywords: ["GitHub", "account", "sign in", "log in", "connect", "disconnect", "token"]),
        .init(section: .integrations, group: "GitHub account", title: "Organization access",
              keywords: ["organization", "org", "grant", "SSO"]),
        .init(section: .integrations, group: "GitHub account", title: "Method",
              keywords: ["sign in with GitHub", "personal access token", "GitHub CLI"]),
        .init(section: .integrations, group: "GitHub account", title: "Host",
              keywords: ["GitHub Enterprise", "github.com", "server"]),
        .init(section: .integrations, group: "GitHub account", title: "Personal access token",
              keywords: ["PAT", "token", "classic", "fine-grained", "scope"]),
        .init(section: .integrations, group: "GitHub account", title: "GitHub CLI",
              keywords: ["gh", "gh auth", "import"]),
        .init(section: .integrations, group: "GitHub account", title: "Sign in with GitHub",
              keywords: ["device code", "browser", "OAuth"]),

        // AI
        .init(section: .ai, group: nil, title: "Show AI features", keywords: ["hide AI", "AI buttons"]),
        .init(section: .ai, group: "Provider", title: "Active provider", keywords: ["provider"] + providerNames),
        .init(section: .ai, group: nil, title: "API key", keywords: ["key", "token", "Keychain"] + providerNames),
        .init(section: .ai, group: nil, title: "Base URL", keywords: ["endpoint", "server", "custom"] + providerNames),
        .init(section: .ai, group: nil, title: "Model", keywords: ["load models", "LLM"] + providerNames),
        .init(section: .ai, group: nil, title: "Test connection", keywords: ["test", "check"]),
        .init(section: .ai, group: "Language", title: "Explanations",
              keywords: ["language", "output language", "explain"] + languageNames),
        .init(section: .ai, group: "Language", title: "Commit messages",
              keywords: ["language", "output language", "generate message"] + languageNames),
        .init(section: .ai, group: "Commit messages", title: "Summary only",
              keywords: ["summary", "subject", "description", "generate message"]),
        .init(section: .ai, group: "Explanations", title: "Custom instructions",
              keywords: ["prompt", "explain", "instructions"]),
        .init(section: .ai, group: "Conflict resolution", title: "Custom instructions",
              keywords: ["prompt", "suggest resolution", "conflict", "merge", "instructions"]),
        .init(section: .ai, group: "Pull requests", title: "Custom instructions",
              keywords: ["prompt", "pull request", "PR description", "instructions"]),

        // Terminal
        .init(section: .terminal, group: "Display", title: "Font", keywords: ["monospaced", "typeface", "font family"]),
        .init(section: .terminal, group: "Display", title: "Font size", keywords: ["size", "bigger", "smaller"]),
        .init(section: .terminal, group: "Display", title: "Cursor", keywords: ["block", "underline", "bar", "caret"]),
        .init(section: .terminal, group: "Display", title: "Scrollback", keywords: ["lines", "history", "buffer"]),
        .init(section: .terminal, group: "Display", title: "Bold text", keywords: ["bold", "weight"]),
        .init(section: .terminal, group: "New tabs", title: "Open terminal with each new tab",
              keywords: ["drawer", "shell", "new tab"]),
        .init(section: .terminal, group: "Shell", title: "Shell",
              keywords: ["zsh", "bash", "fish", "login shell", "custom shell", "path"]),
    ]

    private static var providerNames: [String] { AIProvider.allCases.map(\.displayName) }

    private static var languageNames: [String] { AIResponseLanguage.allCases.map(\.displayName) }
}

/// The Settings header's search: a magnifier button that grows leftward into a field (with the magnifier at its
/// leading edge and a close button at its trailing one), focused as it opens. Escape or the close button clears the
/// query and shrinks it back into the button.
struct SettingsSearchField: View {
    static let height: CGFloat = 32
    static let openWidth: CGFloat = 320

    @Binding var isOpen: Bool
    @Binding var query: String
    /// Changes with each ⌘F while the modal shows: the field opens, or takes the focus again.
    let focusToken: Int
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(RowIconButtonStyle())
            // Only the button while closed; inside the field, the icon is a label.
            .allowsHitTesting(!isOpen)
            .frame(width: Self.height, height: Self.height)
            .help("Search Settings (⌘F)")
            .accessibilityLabel("Search settings")
            .accessibilityHidden(isOpen)
            if isOpen {
                TextField("Search settings", text: $query, prompt: Text("Search settings"))
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .autocorrectionDisabled()
                    .focused($focused)
                    // Next run-loop turn, once the field is in the window.
                    .onAppear { DispatchQueue.main.async { focused = true } }
                    .onKeyPress(.escape) {
                        close()
                        return .handled
                    }
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(RowIconButtonStyle())
                .padding(.horizontal, 8)
                .help("Close Search (Esc)")
                .accessibilityLabel("Close search")
            }
        }
        .frame(width: isOpen ? Self.openWidth : Self.height, height: Self.height, alignment: .leading)
        .background(Capsule().fill(Palette.inputSurface).opacity(isOpen ? 1 : 0))
        .overlay(Capsule()
            .strokeBorder(focused ? Color.accentColor : Palette.surfaceBorder, lineWidth: focused ? 1.5 : 1)
            .opacity(isOpen ? 1 : 0)
            .allowsHitTesting(false))
        .focusEffectDisabled()
        .onChange(of: focusToken) {
            if isOpen { focused = true } else { open() }
        }
    }

    private func open() {
        withAnimation(reduceMotion ? nil : Motion.sheet) { isOpen = true }
    }

    private func close() {
        query = ""
        withAnimation(reduceMotion ? nil : Motion.sheet) { isOpen = false }
    }
}

/// The rows matching the search, in place of the selected section's page: capsule rows in one card, each with its
/// section's icon and its path; a click opens that section, scrolled to the row (`SettingsSearchReveal`).
struct SettingsSearchResults: View {
    let query: String
    let onOpen: (SettingsSearchItem) -> Void

    var body: some View {
        let items = SettingsSearchItem.matching(query)
        ScrollView {
            Group {
                if items.isEmpty {
                    Text("No settings match \"\(query.trimmingCharacters(in: .whitespacesAndNewlines))\"")
                        .foregroundStyle(.secondary)
                        .padding(SettingsMetrics.cardPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: SidebarItemStyle.spacing) {
                        ForEach(items) { item in
                            Button { onOpen(item) } label: { row(item) }
                                .buttonStyle(SidebarItemStyle(selected: false))
                        }
                    }
                    .padding(SettingsMetrics.sidebarRowsPadding)
                }
            }
            .modifier(GlassCard(cornerRadius: SettingsMetrics.cardRadius))
            // The pages' insets: top-aligned with the sidebar card, 12 pt from it and under the card.
            .padding(.leading, SettingsMetrics.sidebarInset)
            .padding(.bottom, SettingsMetrics.sidebarInset)
        }
    }

    private func row(_ item: SettingsSearchItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.section.label.icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(item.path)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
